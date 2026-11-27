"""Run with gamdl 4.1.2's Python: python -I tests/test_wrapper_auth.py."""
import runpy
import unittest
from pathlib import Path
from unittest.mock import AsyncMock

import httpx
from gamdl.api import GamdlApiError, WrapperApi


class WrapperAuthTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        bridge = Path(__file__).resolve().parents[1] / "GamdlStudio/Resources/gamdl_bridge.py"
        runpy.run_path(str(bridge))["install_auth_recovery"]()

    async def connect(self, replies):
        self.paths = []
        self.credentials = AsyncMock(return_value=("test-user", "test-password"))
        self.two_factor = AsyncMock(return_value="123456")

        def handle(request):
            self.paths.append((request.method, request.url.path))
            status, body = replies.pop(0)
            return httpx.Response(status, json=body)

        async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
            return await WrapperApi.create(
                client=client, get_credentials=self.credentials, get_2fa_code=self.two_factor
            )

    info = (200, {
        "version": "1.0.1", "protocol_version": 1, "architecture": "x86_64",
        "profile": "apple-music-1109-x86_64", "context_supported": True,
        "context_format": "temari", "decryption": "client_side",
    })
    logged_out = (200, {"state": "logged_out"})
    ready = (200, {"state": "authenticated"})
    challenge = (202, {"kind": "two_factor", "challenge_id": "test-challenge"})

    async def test_fresh_login_after_unusable_restore(self):
        for status, code in ((502, "session_validation_failed"), (403, "session_expired"),
                             (404, "no_cached_session")):
            with self.subTest(code=code):
                result = await self.connect([
                    self.info, self.logged_out, (status, {"error": {"code": code}}),
                    self.logged_out, self.challenge, self.ready, self.ready,
                ])
                self.assertEqual(result.session["state"], "authenticated")
                self.assertEqual(self.paths, [
                    ("GET", "/info"), ("GET", "/session"), ("POST", "/session/restore"),
                    ("GET", "/session"), ("POST", "/session/login"),
                    ("POST", "/session/challenge"), ("GET", "/session"),
                ])
                self.credentials.assert_awaited_once()
                self.two_factor.assert_awaited_once()

    async def test_restore_success_keeps_the_cached_session(self):
        result = await self.connect([self.info, self.logged_out, self.ready, self.ready])
        self.assertEqual(result.session["state"], "authenticated")
        self.credentials.assert_not_awaited()

    async def test_other_restore_errors_remain_errors(self):
        for reply in ((502, {"error": {"code": "worker_timeout"}}),
                      (502, {"error": ["session_validation_failed"]}), (502, []),
                      (503, {"error": {"code": "worker_busy"}})):
            with self.subTest(reply=reply), self.assertRaises(GamdlApiError):
                await self.connect([self.info, self.logged_out, reply])
            self.credentials.assert_not_awaited()

    async def test_login_failure_still_fails(self):
        error = (502, {"error": {"code": "session_validation_failed"}})
        with self.assertRaises(GamdlApiError):
            await self.connect([self.info, self.logged_out, error, self.logged_out, error])
        self.assertEqual(self.paths[-1], ("POST", "/session/login"))


if __name__ == "__main__":
    unittest.main()
