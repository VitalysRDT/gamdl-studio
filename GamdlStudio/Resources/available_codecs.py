"""List common song codecs from playback metadata and HLS master playlists only."""
import asyncio
import json
import sys
from contextlib import AsyncExitStack, redirect_stdout

import httpx
import m3u8
from gamdl.api.apple_music import AppleMusicApi


async def open_catalog(stack, mode, source, storefront):
    legacy = hasattr(AppleMusicApi, "create_from_netscape_cookies")
    authenticated = False
    try:
        if mode == "cookies":
            create = AppleMusicApi.create_from_netscape_cookies if legacy else AppleMusicApi.from_cookies
            api = await create(source)
        elif mode == "wrapper" and not legacy:
            from gamdl.api import WrapperApi

            wrapper = await stack.enter_async_context(await asyncio.wait_for(WrapperApi.create(base_url=source), 6))
            api = await AppleMusicApi.from_wrapper(wrapper)
        else:
            api = None
        authenticated = api is not None
    except Exception:
        api = None
    if api is None:
        api = await AppleMusicApi.create(storefront=storefront or "us")
    if legacy:
        stack.push_async_callback(api.client.aclose)
    else:
        await stack.enter_async_context(api)
    if storefront:
        api.storefront = storefront
    return api, authenticated, legacy


async def track_codecs(item, api, client, authenticated, legacy):
    if item["type"] == "library-songs":
        catalog_id = item.get("attributes", {}).get("playParams", {}).get("catalogId")
        if not catalog_id:
            library = (await api.get_library_song(item["id"]))["data"][0]
            catalog = library.get("relationships", {}).get("catalog", {}).get("data", [])
            if not catalog:
                return set()
            catalog_id = catalog[0]["id"]
        item = (await api.get_song(catalog_id, include=""))["data"][0]
    elif not item.get("attributes"):
        # A relationship page can contain just resource IDs.
        item = (await api.get_song(item["id"], include=""))["data"][0]

    attrs = item["attributes"]
    if not attrs.get("playParams"):
        return None  # Unreleased tracks do not participate in the intersection.
    codecs = set()
    lookup_failed = False
    if authenticated:
        try:
            playback = await api.get_webplayback(item["id"])
            flavors = {asset.get("flavor") for song in playback.get("songList", [])
                       for asset in song.get("assets", []) if asset.get("URL")}
            if "28:ctrp256" in flavors:
                codecs.add("aac-web")
            if "32:ctrp64" in flavors:
                codecs.add("aac-he-web")
        except Exception:
            lookup_failed = True  # The catalog master can still confirm other formats.
    if legacy:
        if not authenticated or lookup_failed:
            raise ValueError("Web formats could not be verified")
        return codecs

    from gamdl.media.song.stream import match_hls_codec

    url = (attrs.get("extendedAssetUrls") or {}).get("enhancedHls")
    if not url and attrs.get("playParams") and "extendedAssetUrls" not in attrs:
        attrs = (await api.get_song(item["id"], include=""))["data"][0]["attributes"]
        url = (attrs.get("extendedAssetUrls") or {}).get("enhancedHls")
    if url:
        try:
            response = await client.get(url)
            response.raise_for_status()
            for variant in m3u8.loads(response.text).playlists:
                info = variant.stream_info
                codec = match_hls_codec(info.audio, info.codecs)
                if codec:
                    codecs.add(codec.value)
        except (httpx.HTTPError, ValueError):
            lookup_failed = True
    if lookup_failed and not codecs:
        raise ValueError("Formats could not be verified")
    if codecs.intersection({"alac-lossless", "alac-hires"}):
        codecs.add("alac")  # gamdl's choice of the best advertised ALAC tier.
    return codecs


async def available(kind, identifier, library, storefront, mode, source):
    async with AsyncExitStack() as stack:
        api, authenticated, legacy = await open_catalog(stack, mode, source, storefront)
        # Catalog master URLs are fetched without account headers or cookies.
        client = await stack.enter_async_context(httpx.AsyncClient(follow_redirects=True, timeout=10))
        getter = getattr(api, ("get_library_" if library else "get_") + kind)
        kwargs = {}
        if library and kind in ("album", "playlist"):
            kwargs["include"] = "tracks"
        elif not library and kind == "song":
            kwargs["include"] = ""
        resource = (await getter(identifier, **kwargs))["data"][0]
        if kind == "song":
            formats = await track_codecs(resource, api, client, authenticated, legacy)
            return sorted(formats or ())

        page = resource["relationships"]["tracks"]
        common = None
        while True:
            # Videos use a separate codec setting.
            songs = [item for item in page["data"] if item["type"] in ("songs", "library-songs")]
            for start in range(0, len(songs), 4):
                group = songs[start:start + 4]
                results = await asyncio.gather(*(track_codecs(song, api, client, authenticated, legacy) for song in group))
                for formats in results:
                    if formats is not None:
                        common = formats if common is None else common & formats
                if common == set():
                    return []
            if not page.get("next"):
                return sorted(common or ())
            if legacy:
                page = await api._amp_request(page["next"])
            else:
                page = await api.get_extended_api_data(page["next"])


if __name__ == "__main__":
    kind, identifier, scope, storefront, mode, source = sys.argv[1:]
    if kind not in ("song", "album", "playlist"):
        sys.exit(1)
    try:
        with redirect_stdout(sys.stderr):
            check = available(kind, identifier, scope == "library", storefront, mode, source)
            result = asyncio.run(asyncio.wait_for(check, timeout=30 if kind == "song" else 120))
        print(json.dumps(result))
    except Exception:
        sys.exit(1)  # SDK exceptions can contain private URLs. Only codec names leave the process.
