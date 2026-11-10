import base64
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "atrust_login", Path(__file__).resolve().parents[1] / "atrust-login.py"
)
login = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(login)


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = patch.object(login, "ROOT", Path(self.directory.name))
        root.start()
        self.addCleanup(root.stop)

    def test_session_cookies_are_private_runtime_files(self):
        session = login.Session()
        session.save_cookies()
        self.assertEqual(session.cookie_file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(session.cookie_file.parent.stat().st_mode & 0o777, 0o700)

    def test_credentials_cannot_follow_untrusted_redirects(self):
        for url in ["http://sso.ecnu.edu.cn/login", "https://sso.ecnu.edu.cn.evil.test/",
                    "https://evil.test/", "https://user@sso.ecnu.edu.cn/",
                    "https://sso.ecnu.edu.cn:8443/login"]:
            with self.subTest(url=url), self.assertRaises(login.LoginError):
                login.SafeRedirect().redirect_request(None, None, 302, "", {}, url)
        self.assertEqual(login.trusted_url(login.SSO + "/login"), login.SSO + "/login")

    def test_aes_matches_known_vector_and_pkcs7_padding(self):
        key = base64.b64encode(b"Thats my Kung Fu").decode()
        encrypted = base64.b64decode(login.aes_encrypt(key, "Two One Nine Two"))
        self.assertEqual(encrypted[:16].hex(), "29c3505f571420f6402299b31a02d73a")
        self.assertEqual(len(encrypted), 32)  # Full block still receives padding.

    def test_post_origin_is_not_forwarded_into_cas_get_callback(self):
        request = login.Request(login.SSO + "/login", data=b"fixture", headers={
            "Origin": login.SSO, "Referer": login.SSO + "/login?service=fixture"})
        redirected = login.SafeRedirect().redirect_request(
            request, None, 302, "", {}, login.VPN + "/passport/v1/public/casLogin")
        self.assertEqual(redirected.get_method(), "GET")
        self.assertIsNone(redirected.get_header("Origin"))
        self.assertEqual(redirected.get_header("Referer"), login.SSO + "/")

    def test_password_whitespace_is_preserved(self):
        with patch.dict(login.os.environ, {"VPN_USER": "fixture"}), patch.object(
            login.os.path, "isfile", return_value=True
        ), patch.object(
            login.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, " secret \n", "")
        ):
            self.assertEqual(login.get_password(), ("fixture", " secret "))

    def test_keychain_takes_precedence_over_vpn_pass(self):
        found = subprocess.CompletedProcess([], 0, "keychain\n", "")
        with patch.dict(login.os.environ, {"VPN_USER": "fixture"}), patch.object(
            login, "PASSWORD_FALLBACK", "fallback"
        ), patch.object(login.os.path, "isfile", return_value=True), patch.object(
            login.subprocess, "run", return_value=found
        ):
            self.assertEqual(login.get_password(), ("fixture", "keychain"))

    def test_vpn_pass_used_only_when_keychain_missing(self):
        missing = subprocess.CompletedProcess([], 44, "", "not found")
        with patch.dict(login.os.environ, {"VPN_USER": "fixture"}), patch.object(
            login.os.path, "isfile", return_value=True
        ), patch.object(
            login.subprocess, "run", return_value=missing
        ), patch("sys.stderr", io.StringIO()) as stderr:
            with patch.object(login, "PASSWORD_FALLBACK", ""), self.assertRaises(login.LoginError):
                login.get_password()
            with patch.object(login, "PASSWORD_FALLBACK", "fallback"):
                self.assertEqual(login.get_password(), ("fixture", "fallback"))
        self.assertNotIn("fallback", stderr.getvalue())

    def test_without_keychain_cli_vpn_pass_is_used_directly(self):
        with patch.dict(login.os.environ, {"VPN_USER": "fixture"}), patch.object(
            login.os.path, "isfile", return_value=False
        ), patch.object(login.subprocess, "run") as run, patch("sys.stderr", io.StringIO()) as stderr:
            with patch.object(login, "PASSWORD_FALLBACK", "fallback"):
                self.assertEqual(login.get_password(), ("fixture", "fallback"))
            with patch.object(login, "PASSWORD_FALLBACK", ""), \
                    self.assertRaisesRegex(login.LoginError, "VPN_PASS"):
                login.get_password()
        run.assert_not_called()
        self.assertEqual(stderr.getvalue(), "")

    def test_keychain_cli_launch_failure_falls_back(self):
        with patch.dict(login.os.environ, {"VPN_USER": "fixture"}), patch.object(
            login.os.path, "isfile", return_value=True
        ), patch.object(login.subprocess, "run", side_effect=FileNotFoundError), patch.object(
            login, "PASSWORD_FALLBACK", "fallback"
        ), patch("sys.stderr", io.StringIO()):
            self.assertEqual(login.get_password(), ("fixture", "fallback"))

    def test_browser_opener_matches_platform(self):
        ok = subprocess.CompletedProcess([], 0, b"", b"")
        with patch.object(login.sys, "platform", "darwin"), \
                patch.object(login.subprocess, "run", return_value=ok) as run:
            self.assertTrue(login.open_browser(login.PORTAL))
        self.assertEqual(run.call_args.args[0], ["/usr/bin/open", login.PORTAL])
        with patch.object(login.sys, "platform", "linux"), \
                patch.object(login.shutil, "which", return_value="/usr/bin/xdg-open"), \
                patch.object(login.subprocess, "run", return_value=ok) as run:
            self.assertTrue(login.open_browser(login.PORTAL))
        self.assertEqual(run.call_args.args[0], ["/usr/bin/xdg-open", login.PORTAL])
        with patch.object(login.sys, "platform", "linux"), \
                patch.object(login.shutil, "which", return_value=None), \
                patch.object(login.subprocess, "run") as run:
            self.assertFalse(login.open_browser(login.PORTAL))
        run.assert_not_called()

    def test_browser_fallback_without_opener_still_waits_for_manual_login(self):
        with patch("sys.argv", ["atrust-login.py", "up"]), \
                patch.object(login, "is_connected", return_value=False), \
                patch.object(login.Session, "login", side_effect=login.LoginError("fixture failure")), \
                patch.object(login, "open_browser", return_value=False), \
                patch.object(login, "wait_connected", return_value=True) as wait, \
                patch("sys.stdout", new_callable=io.StringIO) as stdout, \
                patch("sys.stderr", new_callable=io.StringIO):
            self.assertEqual(login.main(), 0)
        wait.assert_called_once_with(180)
        self.assertIn(login.PORTAL, stdout.getvalue())

    def test_vpn_pass_is_removed_from_child_environment(self):
        with patch.dict(login.os.environ, {"VPN_PASS": "fallback"}), patch.object(
            login.sys, "argv", ["atrust-login.py", "status"]
        ), patch.object(login, "local_api", return_value={}), patch("sys.stdout", io.StringIO()):
            login.main()
            self.assertNotIn("VPN_PASS", login.os.environ)
            self.assertEqual(login.PASSWORD_FALLBACK, "fallback")
        login.PASSWORD_FALLBACK = ""

    def test_status_requires_matching_server_and_available_tunnel(self):
        response = {"code": 0, "data": {"status": "online", "data": {
            "addr": login.VPN, "tunnelStatus": "tunnelAvailable"}}}
        self.assertTrue(login.connected(response))
        response["data"]["status"] = "offline"
        self.assertFalse(login.connected(response))
        response["data"]["status"] = "online"
        response["data"]["data"]["tunnelStatus"] = "tunnelUnavailable"
        self.assertFalse(login.connected(response))
        response["data"]["data"]["tunnelStatus"] = "tunnelAvailable"
        response["data"]["data"]["addr"] = "https://other.test"
        self.assertFalse(login.connected(response))
        self.assertFalse(login.connected({"code": 10000000, "data": None}))

    def test_local_https_keeps_verification_and_tickets_off_argv(self):
        result = subprocess.CompletedProcess([], 0, '{"code":0,"data":{}}', "")
        with patch.object(login.subprocess, "run", return_value=result) as run:
            login.local_api("/v1/service/start", {"sidTicket": "fixture-ticket"})
        argv = run.call_args.args[0]
        self.assertNotIn("fixture-ticket", " ".join(argv))
        self.assertNotIn("--insecure", argv)
        self.assertNotIn("-k", argv)
        self.assertIn("--disable", argv)
        self.assertIn("localhost.sangfor.com.cn:54631:127.0.0.1", argv)
        self.assertIn("fixture-ticket", run.call_args.kwargs["input"])

    def test_portal_requests_include_required_metadata(self):
        session = login.Session()
        with patch.object(session, "request", return_value=(login.VPN, '{"code":0,"data":{}}')) as request:
            session.api("/passport/v1/auth/authCheck")
        url = request.call_args.args[0]
        self.assertIn("clientType=SDPBrowserClient", url)
        self.assertIn("platform=Mac", url)

    def test_sso_challenge_stops_after_one_submission(self):
        session = login.Session()
        session.config = {"firstAuth": ["/passport/v1/public/casLogin?sfDomain=fixture"]}
        html = '<p id="login-croypto">' + base64.b64encode(b"0" * 16).decode() + '</p>'
        html += '<p id="login-page-flowkey">fixture-execution</p>'
        with patch.object(session, "configure"), patch.object(
            session, "request", side_effect=[(login.SSO + "/login?service=fixture", html),
                                             (login.SSO + "/login", "challenge")]
        ) as request, patch.object(login, "get_password", return_value=("fixture", "fixture-secret")), \
                patch("sys.stdout", new_callable=io.StringIO), self.assertRaises(login.LoginError):
            session.login()
        self.assertEqual(request.call_count, 2)
        self.assertEqual(request.call_args.args[0], login.SSO + "/login")
        self.assertNotIn(b"fixture-secret", request.call_args.args[1])

    def test_successful_sso_exchanges_ticket_and_starts_client(self):
        session = login.Session()
        session.config = {"firstAuth": ["/passport/v1/public/casLogin?sfDomain=fixture"], "guid": "fixture-guid"}
        html = '<p id="login-croypto">' + base64.b64encode(b"0" * 16).decode() + '</p>'
        html += '<p id="login-page-flowkey">fixture-execution</p>'
        callback = login.VPN + "/portal/shortcut.html?" + login.urlencode({
            "nextService": "auth/authCheck", "data": login.json.dumps({
                "ticket": "fixture-env-ticket", "env": {"need": True, "timing": "fixture"}})})
        with patch.object(session, "configure") as configure, patch.object(
            session, "request", side_effect=[(login.SSO + "/login?service=fixture", html),
                                             (callback, "")]
        ), patch.object(login, "get_password", return_value=("fixture", "fixture-secret")), \
                patch.object(session, "api", side_effect=[{"nextService": "auth/accessCheck"},
                                                          {}, {"sidTicket": "fixture-ticket"}]) as api, \
                patch.object(login, "local_api", return_value={"code": 0}) as local, \
                patch("sys.stdout", new_callable=io.StringIO):
            session.login()
        self.assertEqual(api.call_args.args, ("/passport/v1/public/ticketExchange", {}))
        configure.assert_called_once()  # A second config fetch invalidates CAS.
        self.assertEqual([call.args[0] for call in local.call_args_list], [
            "/v1/service/init", "/v1/service/reportEnvBeforeLogin", "/v1/service/start"])
        self.assertEqual(local.call_args_list[1].args[1]["ticket"], "fixture-env-ticket")
        self.assertEqual(local.call_args.args, (
            "/v1/service/start", {"sidTicket": "fixture-ticket"}, "fixture-guid"))

    def test_cached_sso_callback_needs_no_password_or_post(self):
        session = login.Session()
        session.config = {"firstAuth": ["/passport/v1/public/casLogin?sfDomain=fixture"]}
        callback = login.VPN + "/portal/shortcut.html?nextService=auth%2FauthCheck"
        with patch.object(session, "configure"), \
                patch.object(session, "request", return_value=(callback, "")) as request, \
                patch.object(session, "finish_login") as finish, \
                patch.object(login, "get_password") as password:
            session.login()
        request.assert_called_once()
        password.assert_not_called()
        finish.assert_called_once_with(callback)

    def test_http_only_failure_never_opens_browser(self):
        with patch("sys.argv", ["atrust-login.py", "login", "--http-only"]), \
                patch.object(login, "is_connected", return_value=False), \
                patch.object(login.Session, "login", side_effect=login.LoginError("fixture failure")), \
                patch.object(login.subprocess, "run") as run, \
                patch("sys.stderr", new_callable=io.StringIO):
            self.assertEqual(login.main(), 2)
        run.assert_not_called()

    def test_online_connection_is_not_authenticated_again(self):
        for command, expected in [("up", 0), ("login", 2)]:
            with self.subTest(command=command), patch("sys.argv", ["atrust-login.py", command]), \
                    patch.object(login, "is_connected", return_value=True), \
                    patch.object(login.Session, "login") as authenticate, \
                    patch("sys.stdout", new_callable=io.StringIO), \
                    patch("sys.stderr", new_callable=io.StringIO):
                self.assertEqual(login.main(), expected)
                authenticate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
