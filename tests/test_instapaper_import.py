import contextlib
import importlib.util
import io
import os
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "instapaper_import",
    Path(__file__).resolve().parents[1] / "scripts" / "instapaper_import.py",
)
importer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(importer)


class ImporterPrivacyTests(unittest.TestCase):
    def test_invalid_configuration_fails_before_password_or_network(self):
        for value in ("", "REDACTED", "   "):
            with self.subTest(value=value), \
                    patch.dict(os.environ, {
                        "INSTAPAPER_USERNAME": value,
                        "INSTAPAPER_CONSUMER_KEY": "test-key",
                        "INSTAPAPER_CONSUMER_SECRET": "test-secret",
                    }, clear=True), \
                    patch("sys.argv", ["importer", "unused.html"]), \
                    patch.object(importer.getpass, "getpass") as password, \
                    patch.object(importer.urllib.request, "urlopen") as network, \
                    contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    importer.main()
                self.assertEqual(error.exception.code, 2)
                password.assert_not_called()
                network.assert_not_called()

    def test_environment_credentials_and_command_line_precedence(self):
        for override in (False, True):
            with self.subTest(override=override):
                argv = ["importer", "unused.html"]
                expected = ("env-key", "env-secret", "env-user")
                if override:
                    argv += [
                        "--username", "cli-user",
                        "--consumer-key", "cli-key",
                        "--consumer-secret", "cli-secret",
                    ]
                    expected = ("cli-key", "cli-secret", "cli-user")
                with patch.dict(os.environ, {
                    "INSTAPAPER_USERNAME": "env-user",
                    "INSTAPAPER_CONSUMER_KEY": "env-key",
                    "INSTAPAPER_CONSUMER_SECRET": "env-secret",
                }, clear=True), \
                        patch("sys.argv", argv), \
                        patch.object(importer.getpass, "getpass", return_value="test-password"), \
                        patch.object(importer, "parse_bookmarks", return_value=[
                            ("https://example.invalid/bookmark", "Example", "tag"),
                        ]), \
                        patch.object(importer, "xauth_login", return_value=("token", "secret")) as login, \
                        patch.object(importer, "add_bookmark", return_value=(True, 200, "", "")) as add, \
                        contextlib.redirect_stdout(io.StringIO()):
                    importer.main()
                login.assert_called_once_with(*expected, "test-password")
                self.assertEqual(add.call_args.args[3:5], expected[:2])

    def test_verbose_request_withholds_secrets_but_preserves_transport(self):
        response = unittest.mock.MagicMock()
        response.status = 200
        response.reason = "OK"
        response.read.return_value = b"oauth_token=access-token&oauth_token_secret=access-secret"
        response.getheaders.return_value = [("Set-Cookie", "private-cookie")]
        output = io.StringIO()
        with patch.object(importer, "VERBOSE", True), \
                patch.object(importer.urllib.request, "urlopen", return_value=response) as network, \
                contextlib.redirect_stdout(output):
            status, headers, body = importer.oauth_request(
                "POST", importer.XAUTH_URL,
                {"x_auth_username": "private-user", "x_auth_password": "private-password"},
                "consumer-key", "consumer-secret",
            )
        self.assertEqual(status, 200)
        self.assertIn("access-token", body)
        self.assertEqual(headers["Set-Cookie"], "private-cookie")
        request = network.call_args.args[0]
        self.assertIn("consumer-key", request.get_header("Authorization"))
        self.assertIn(b"private-password", request.data)
        for value in (
            "private-user", "private-password", "consumer-key", "consumer-secret",
            "access-token", "access-secret", "private-cookie",
        ):
            self.assertNotIn(value, output.getvalue())

    def test_authentication_errors_withhold_response_body(self):
        for status, body in (
            (403, "private-password"),
            (200, "oauth_token=access-token"),
        ):
            output = io.StringIO()
            with self.subTest(status=status), \
                    patch.object(importer, "oauth_request", return_value=(status, {}, body)), \
                    contextlib.redirect_stdout(output):
                with self.assertRaises(SystemExit):
                    importer.xauth_login("key", "secret", "user", "password")
                self.assertNotIn(body, output.getvalue())

    def test_verbose_http_error_withholds_sensitive_response(self):
        body = b"oauth_token=access-token&oauth_token_secret=access-secret"
        error = importer.urllib.error.HTTPError(
            importer.XAUTH_URL, 403, "Forbidden",
            {"Set-Cookie": "private-cookie"}, io.BytesIO(body),
        )
        output = io.StringIO()
        with patch.object(importer, "VERBOSE", True), \
                patch.object(importer.urllib.request, "urlopen", side_effect=error), \
                contextlib.redirect_stdout(output):
            status, headers, response = importer.oauth_request(
                "POST", importer.XAUTH_URL,
                {"x_auth_password": "private-password"}, "key", "secret",
            )
        self.assertEqual(status, 403)
        self.assertEqual(response, body.decode())
        self.assertEqual(headers["Set-Cookie"], "private-cookie")
        for value in ("access-token", "access-secret", "private-cookie", "private-password"):
            self.assertNotIn(value, output.getvalue())


if __name__ == "__main__":
    unittest.main()
