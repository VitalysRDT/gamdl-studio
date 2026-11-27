"""Run with gamdl 4's Python. All catalog, playback and master responses are local."""
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

import httpx

spec = importlib.util.spec_from_file_location(
    "available_codecs", Path(__file__).resolve().parents[1] / "GamdlStudio/Resources/available_codecs.py"
)
lookup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lookup)


def song(identifier, playable=True):
    return {"type": "songs", "id": identifier, "attributes": {
        "playParams": {"id": identifier} if playable else {},
        "extendedAssetUrls": {"enhancedHls": "https://catalog.test/" + identifier},
    }}


def master(*groups):
    return "#EXTM3U\n" + "".join(
        f'#EXT-X-STREAM-INF:BANDWIDTH=256000,AUDIO="{group}"\nstream.m3u8\n' for group in groups
    )


class CodecLookupTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        def respond(request):
            groups = ["audio-stereo-256", "audio-alac-44-16"]
            if request.url.path == "/1":
                groups += ["audio-atmos-768", "audio-alac-96-24"]
            return httpx.Response(200, text=master(*groups))
        self.client = httpx.AsyncClient(transport=httpx.MockTransport(respond))
        self.addAsyncCleanup(self.client.aclose)
        self.api = AsyncMock()
        self.api.get_webplayback.return_value = {"songList": [{"assets": [
            {"flavor": "28:ctrp256", "URL": "https://media.test/a"},
            {"flavor": "32:ctrp64"},  # Unplayable entry.
        ]}]}

    async def test_announced_variants_and_alac_tiers(self):
        codecs = await lookup.track_codecs(song("2"), self.api, self.client, True, False)
        self.assertEqual(codecs, {"aac-web", "aac", "alac-lossless", "alac"})
        richer = await lookup.track_codecs(song("1"), self.api, self.client, False, False)
        self.assertEqual(richer, {"aac", "alac-lossless", "alac-hires", "alac", "atmos"})

    async def test_gamdl3_only_offers_verified_web_streams(self):
        codecs = await lookup.track_codecs(song("1"), self.api, self.client, True, True)
        self.assertEqual(codecs, {"aac-web"})

    async def test_unreleased_track_and_unreachable_metadata_are_distinct(self):
        self.assertIsNone(await lookup.track_codecs(song("1", playable=False), self.api, self.client, True, False))
        self.api.get_webplayback.assert_not_awaited()
        self.api.get_webplayback.side_effect = OSError("offline")
        with self.assertRaises(ValueError):
            await lookup.track_codecs(song("1"), self.api, self.client, True, True)

    async def test_common_formats_include_later_pages_and_skip_unreleased_tracks(self):
        page = {"data": [song("1"), song("3", playable=False), {"type": "music-videos"}], "next": "/page2"}
        self.api.get_playlist.return_value = {"data": [{"relationships": {"tracks": page}}]}
        self.api.get_extended_api_data.return_value = {"data": [{"type": "songs", "id": "2"}]}
        self.api.get_song.return_value = {"data": [song("2")]}
        with patch.object(lookup, "open_catalog", AsyncMock(return_value=(self.api, True, False))), \
             patch.object(lookup.httpx, "AsyncClient", return_value=self.client):
            codecs = await lookup.available("playlist", "pl.test", False, "fr", "public", "")
        self.assertEqual(set(codecs), {"aac-web", "aac", "alac-lossless", "alac"})
        self.api.get_extended_api_data.assert_awaited_once_with("/page2")
        self.assertEqual(self.api.get_webplayback.await_count, 2)


if __name__ == "__main__":
    unittest.main()
