"""Resolve an Apple Music playlist into its tracks, using gamdl's own API client.

gamdl's URL parser only accepts catalog playlists (pl.<32 hex>) and user playlists
(pl.u-...). Personalized playlists such as Replay or "Favorites Mix" (pl.pm-...) are
served by the same AMP endpoint once the request carries the subscriber's
media-user-token, so we fetch them here and hand gamdl one song URL per track.

Works with gamdl 3.9+ and gamdl 4, whose API client was rewritten (see
open_api and next_page below).

Usage: python resolve_playlist.py <cookies.txt> <storefront> <playlist id>
Prints a JSON object on stdout; errors go to stderr with a non-zero exit code.
"""

import asyncio
import json
import sys
from contextlib import asynccontextmanager

from gamdl.api.apple_music import AppleMusicApi


@asynccontextmanager
async def open_api(cookies_path: str):
    if hasattr(AppleMusicApi, "create_from_netscape_cookies"):  # gamdl 3
        yield await AppleMusicApi.create_from_netscape_cookies(cookies_path=cookies_path)
        return
    # gamdl 4 owns an HTTP connection that must be closed.
    async with await AppleMusicApi.from_cookies(cookies_path) as api:
        yield api


async def next_page(api, url: str) -> dict:
    if hasattr(api, "get_extended_api_data"):  # gamdl 4
        return await api.get_extended_api_data(url)
    return await api._amp_request(url)  # gamdl 3


async def resolve(cookies_path: str, storefront: str, playlist_id: str) -> dict:
    async with open_api(cookies_path) as api:
        return await read_playlist(api, storefront, playlist_id)


async def read_playlist(api, storefront: str, playlist_id: str) -> dict:
    # The account storefront wins, but personalized mixes are tied to the URL's.
    api.storefront = storefront or api.storefront

    response = await api.get_playlist(playlist_id)
    playlist = response["data"][0]
    attributes = playlist.get("attributes", {})
    tracks_rel = playlist.get("relationships", {}).get("tracks", {})
    items = list(tracks_rel.get("data", []))

    next_url = tracks_rel.get("next")
    while next_url:
        page = await next_page(api, next_url)
        items.extend(page.get("data", []))
        next_url = page.get("next")

    tracks = []
    for item in items:
        track_attributes = item.get("attributes", {})
        tracks.append(
            {
                "id": item.get("id"),
                "type": item.get("type"),
                "name": track_attributes.get("name"),
                "artist": track_attributes.get("artistName"),
                "album": track_attributes.get("albumName"),
                "durationMs": track_attributes.get("durationInMillis"),
            }
        )

    artwork = attributes.get("artwork", {}).get("url")
    return {
        "id": playlist.get("id"),
        "name": attributes.get("name"),
        "curator": attributes.get("curatorName"),
        "artworkURL": artwork.replace("{w}", "1200").replace("{h}", "1200") if artwork else None,
        "storefront": api.storefront,
        "tracks": tracks,
    }


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: resolve_playlist.py <cookies.txt> <storefront> <playlist id>", file=sys.stderr)
        return 2
    # gamdl logs to stdout; keep stdout for the JSON result only.
    out = sys.stdout
    sys.stdout = sys.stderr
    try:
        result = asyncio.run(resolve(*sys.argv[1:]))
    except Exception as error:  # surfaced verbatim in the app's log
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        return 1
    json.dump(result, out, ensure_ascii=False)
    out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
