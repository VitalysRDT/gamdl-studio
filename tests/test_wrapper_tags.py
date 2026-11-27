"""Exercise the tag resolver shipped with gamdl 4.1.2 without contacting Apple."""
import runpy
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

from gamdl.api import GamdlApiResponseError
from gamdl.download.tag_resolver import TagResolver
from gamdl.media import Song, SongCodec


class WrapperTagTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.addClassCleanup(setattr, TagResolver, "_song_tags", TagResolver._song_tags)
        bridge = Path(__file__).resolve().parents[1] / "GamdlStudio/Resources/gamdl_bridge.py"
        runpy.run_path(str(bridge))["install_tag_recovery"]()

    def setUp(self):
        self.wrapper = AsyncMock()
        self.api = AsyncMock()
        self.resolver = TagResolver(wrapper_api=self.wrapper)
        self.song = Song.from_metadata(
            {"type": "songs", "id": "123", "attributes": {"playParams": {"id": "123"}}}, api=self.api
        )
        def playback(title):
            return {"songList": [{"assets": [{"metadata": {"itemName": title}}]}]}
        self.api.get_webplayback.return_value = playback("Web title")
        self.wrapper.get_playback.return_value = playback("Wrapper title")

    async def test_wrapper_502_reads_web_tags_and_caches_the_result(self):
        self.wrapper.get_playback.side_effect = GamdlApiResponseError("failed", service="wrapper", status_code=502)
        for _ in range(2):
            tags = await self.resolver.get_tags(self.song, codec=SongCodec.ATMOS)
            self.assertEqual(tags.title, "Web title")
        self.wrapper.get_playback.assert_awaited_once()
        self.api.get_webplayback.assert_awaited_once()

    async def test_working_wrapper_stays_preferred(self):
        tags = await self.resolver.get_tags(self.song, codec=SongCodec.ATMOS)
        self.assertEqual(tags.title, "Wrapper title")
        self.api.get_webplayback.assert_not_awaited()

    async def test_other_failures_do_not_switch_source(self):
        for service, status in (("wrapper", 403), ("wrapper", 429), ("apple_music", 502)):
            error = GamdlApiResponseError("failed", service=service, status_code=status)
            with self.subTest(service=service, status=status), patch.object(self.wrapper, "get_playback", side_effect=error):
                with self.assertRaises(GamdlApiResponseError) as caught:
                    await self.resolver.get_tags(self.song, codec=SongCodec.ATMOS)
                self.assertIs(caught.exception, error)
        self.api.get_webplayback.assert_not_awaited()

    async def test_web_error_is_not_retried_by_the_hook(self):
        self.api.get_webplayback.side_effect = GamdlApiResponseError("failed", service="apple_music", status_code=502)
        with self.assertRaises(GamdlApiResponseError):
            await self.resolver.get_tags(self.song, codec=SongCodec.AAC_WEB)
        self.api.get_webplayback.assert_awaited_once()
        self.wrapper.get_playback.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
