#!/usr/bin/env python3
"""ECNU CAS login and aTrust handoff over HTTPS, without a browser engine."""

import argparse
import base64
import http.cookiejar
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
from html.parser import HTMLParser
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urljoin, urlsplit
from urllib.request import (
    HTTPCookieProcessor, HTTPRedirectHandler, ProxyHandler, Request, build_opener,
)

VPN = "https://vpn.ecnu.edu.cn"
SSO = "https://sso.ecnu.edu.cn"
PORTAL = VPN + "/portal/?redirectid=0.2764565404044155#/app_center"
ROOT = Path(__file__).resolve().parent
SECURITY = "/usr/bin/security"  # macOS Keychain CLI; absent on Linux.
# Optional VPN_PASS from .env, used when the Keychain is unavailable or the
# lookup fails.
# main() moves it out of os.environ so child processes never inherit it.
PASSWORD_FALLBACK = ""


class LoginError(Exception):
    pass


def trusted_url(url):
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or parsed.hostname not in
            {"vpn.ecnu.edu.cn", "sso.ecnu.edu.cn"} or
            parsed.port not in (None, 443) or parsed.username or parsed.password):
        raise LoginError("认证跳转到了预期以外的地址，已停止。")
    return url


class SafeRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        trusted_url(newurl)
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None and redirected.get_method() == "GET":
            # urllib otherwise forwards the SSO form's POST Origin into the
            # cross-origin CAS GET callback, unlike a browser navigation.
            redirected.remove_header("Origin")
            if urlsplit(req.full_url).hostname != urlsplit(newurl).hostname:
                previous = urlsplit(req.full_url)
                redirected.remove_header("Referer")
                redirected.add_header("Referer", f"{previous.scheme}://{previous.netloc}/")
        return redirected


class LoginPage(HTMLParser):
    """Read server-rendered CAS flow fields; do not execute remote JavaScript."""

    def __init__(self, html):
        super().__init__()
        self.values = {}
        self.capture = None
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "p" and attrs.get("id"):
            self.capture = attrs["id"]
            self.values[self.capture] = ""
        if tag == "input" and attrs.get("name"):
            self.values.setdefault(attrs["name"], attrs.get("value", ""))

    def handle_data(self, data):
        if self.capture:
            self.values[self.capture] += data

    def handle_endtag(self, tag):
        if tag == "p":
            self.capture = None


def aes_encrypt(key, plaintext):
    try:
        decoded = base64.b64decode(key, validate=True)
    except ValueError:
        raise LoginError("SSO 返回了无效的密码加密参数。") from None
    if len(decoded) not in (16, 24, 32):
        raise LoginError("SSO 密码加密参数长度发生变化。")
    # Only the per-page public encryption key is an argument. Passwords enter
    # OpenSSL through stdin; its default block padding matches CryptoJS Pkcs7.
    result = subprocess.run(
        ["/usr/bin/openssl", "enc", f"-aes-{len(decoded) * 8}-ecb",
         "-K", decoded.hex(), "-nosalt"],
        input=plaintext.encode(), capture_output=True, timeout=10,
    )
    if result.returncode:
        raise LoginError("无法使用 OpenSSL 加密登录表单。")
    return base64.b64encode(result.stdout).decode()


def keychain_password(account):
    """Return the macOS Keychain password, or None when unavailable."""
    if not os.path.isfile(SECURITY):
        return None
    try:
        result = subprocess.run(
            [SECURITY, "find-generic-password", "-a", account,
             "-s", os.environ.get("KEYCHAIN_LABEL", "ECNU_VPN"), "-w"],
            capture_output=True, text=True, timeout=60,
        )
    except OSError:
        return None
    if result.returncode:
        return None
    # security appends one newline. Preserve whitespace belonging to a password.
    return result.stdout.removesuffix("\n")


def get_password():
    account = os.environ.get("VPN_USER", "")
    if not account:
        raise LoginError("请先在 .env 中配置 VPN_USER（学号 / 工号）。")
    password = keychain_password(account)
    if password is not None:
        return account, password
    has_keychain = os.path.isfile(SECURITY)
    if PASSWORD_FALLBACK:
        if has_keychain:
            print("未读取到钥匙串条目，改用 .env 中的 VPN_PASS。", file=sys.stderr, flush=True)
        return account, PASSWORD_FALLBACK
    if has_keychain:
        raise LoginError("无法读取 ECNU 钥匙串条目，且 .env 未设置 VPN_PASS；"
                         "请检查 VPN_USER、KEYCHAIN_LABEL 或授权提示。")
    raise LoginError("当前系统没有 macOS 钥匙串，请在 .env 中设置 VPN_PASS。")


def local_api(path, data=None, guid=""):
    envelope = {"addr": VPN, "type": "web", "guid": guid, "lang": "zh-CN",
                "token": "", "data": data or {}}
    result = subprocess.run(
        ["/usr/bin/curl", "--disable", "--noproxy", "*", "--silent",
         "--show-error", "--connect-timeout", "3", "--max-time", "15",
         "--resolve", "localhost.sangfor.com.cn:54631:127.0.0.1",
         "https://localhost.sangfor.com.cn:54631" + path,
         "-H", "Content-Type: text/plain;charset=UTF-8;application/json",
         "-H", "Origin: " + VPN, "--data-binary", "@-"],
        input=json.dumps(envelope), capture_output=True, text=True, timeout=20,
    )
    # Resolve only the local endpoint to loopback. TLS certificate verification
    # stays enabled, including for every remote school request.
    if result.returncode:
        raise LoginError("aTrust 本地 HTTPS 接口尚未就绪或证书验证失败。")
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise LoginError("aTrust 本地接口返回了无法识别的数据。") from None


def connected(response):
    data = response.get("data") or {}
    if not isinstance(data, dict):
        return False
    info = data.get("data") or {}
    if not isinstance(info, dict):
        return False
    return (response.get("code") == 0 and data.get("status") == "online" and
            info.get("addr", "").rstrip("/") == VPN and
            info.get("tunnelStatus") == "tunnelAvailable")


def is_connected():
    return connected(local_api("/v1/service/status"))


class Session:
    def __init__(self, fresh=False):
        self.cookie_file = ROOT / "tmp" / "atrust-auth" / "cookies.txt"
        self.jar = http.cookiejar.LWPCookieJar(str(self.cookie_file))
        if not fresh and self.cookie_file.exists():
            try:
                self.jar.load(ignore_discard=True)
            except (OSError, http.cookiejar.LoadError):
                self.jar.clear()
        # Authentication goes directly to ECNU, independent of shell proxy vars.
        self.http = build_opener(ProxyHandler({}), HTTPCookieProcessor(self.jar), SafeRedirect())
        self.config = {}

    def save_cookies(self):
        # These are session credentials, stored only in ignored runtime output.
        directory = self.cookie_file.parent
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        directory.chmod(0o700)
        fd, name = tempfile.mkstemp(dir=directory)
        os.close(fd)
        try:
            self.jar.save(name, ignore_discard=True)
            os.replace(name, self.cookie_file)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def request(self, url, data=None, headers=None):
        request = Request(trusted_url(url), data=data, headers={
            "User-Agent": "ECNU-VPN-HTTP/1.0",
            **(headers or {}),
        })
        try:
            with self.http.open(request, timeout=20) as response:
                return response.url, response.read(4 * 1024 * 1024).decode("utf-8")
        except HTTPError as error:
            location = urlsplit(error.url)
            # Keep only location and a short machine-readable CAS error code.
            # Response pages may contain credentials or session material.
            details = LoginPage(error.read(4 * 1024 * 1024).decode("utf-8", errors="replace")).values
            code = details.get("login-error-code", "").strip()
            suffix = f"（SSO 错误码 {code}）" if code.isdecimal() else ""
            raise LoginError(f"{location.hostname}{location.path} 返回 HTTP {error.code}{suffix}。") from None
        except (URLError, TimeoutError, ssl.SSLError):
            raise LoginError("无法通过 HTTPS 访问学校认证服务。") from None

    def api(self, path, data=None, params=None):
        headers = {"Origin": VPN, "Referer": VPN + "/portal/"}
        body = None
        if data is not None:
            headers["Content-Type"] = "application/json;charset=utf-8"
            headers["x-csrf-token"] = self.config.get("security", {}).get("csrfToken", "")
            body = json.dumps(data).encode()
        # These query fields are required by several passport endpoints, even
        # when the JSON body is empty (the portal adds them to every request).
        query = urlencode({"clientType": "SDPBrowserClient", "platform": "Mac", "lang": "zh-CN",
                           **(params or {})})
        _, text = self.request(VPN + path + "?" + query, body, headers)
        try:
            result = json.loads(text)
        except ValueError:
            raise LoginError("VPN 门户接口返回了无法识别的数据。") from None
        if result.get("code") != 0:
            raise LoginError(f"VPN 门户要求进一步认证（错误码 {result.get('code')}）。")
        return result.get("data", {})

    def configure(self):
        self.config = self.api("/passport/v1/public/authConfig")

    def login(self):
        self.configure()
        # firstAuth contains the current CAS domain and initializes the VPN
        # session's CAS state. Opening a saved /casLogin URL alone loses it.
        choices = self.config.get("firstAuth", [])
        entry = next((path for path in choices
                      if urlsplit(path).path == "/passport/v1/public/casLogin"), None)
        if not entry:
            raise LoginError("VPN 门户未提供预期的 CAS 登录入口。")
        url, html = self.request(urljoin(VPN, entry))
        if urlsplit(url).hostname != "sso.ecnu.edu.cn":
            # An existing SSO cookie may complete CAS without a password POST.
            self.finish_login(url)
            return
        fields = LoginPage(html).values
        key = fields.get("login-croypto", "").strip()
        execution = fields.get("login-page-flowkey", "").strip()
        if not key or not execution:
            raise LoginError("SSO 登录表单发生变化，无法提取动态字段。")
        account, password = get_password()
        form = {
            "username": account, "password": aes_encrypt(key, password),
            "type": "UsernamePassword", "_eventId": "submit", "geolocation": "",
            "execution": execution, "croypto": key, "captcha_code": "",
            # No fabricated CAPTCHA proof: the server decides whether an empty
            # challenge payload is permitted for this session.
            "captcha_payload": aes_encrypt(key, "{}"),
        }
        del password
        print("正在通过 HTTPS 提交学校 SSO（仅尝试一次）…", flush=True)
        # The actual Angular form uses action="login", dropping the GET service
        # query. CAS keeps its callback in execution's server-side flow state.
        final_url, result = self.request(urljoin(url, "login"), urlencode(form).encode(), {
            "Content-Type": "application/x-www-form-urlencoded",
            "Origin": SSO, "Referer": url,
        })
        self.save_cookies()
        if urlsplit(final_url).hostname == "sso.ecnu.edu.cn":
            # Do not print the page, credentials, cookies, execution or tickets.
            raise LoginError("SSO 未放行：可能需要验证码、二次认证，或账号密码有误；不会自动重试。")
        self.finish_login(final_url)

    def finish_login(self, callback_url):
        # Keep the configuration from before CAS. Re-fetching authConfig here
        # invalidates the callback ticket before the client can report env.
        callback = {key: values[0] for key, values in parse_qs(urlsplit(callback_url).query).items()}
        try:
            callback_data = json.loads(callback.get("data", "{}"))
            env = callback_data.get("env", {})
        except (ValueError, AttributeError):
            raise LoginError("CAS 回调数据发生变化，无法继续。") from None
        # A successful CAS callback first reports the real aTrust client's
        # environment. Skipping this leaves the portal session unauthenticated.
        initialized = local_api("/v1/service/init", {
            "verifyCode": self.config.get("clientVerifyCode", ""),
            "pubKey": self.config.get("pubKey", ""),
            "disAllowSecurityRiskPopup": 1, "disAllowAntiUninstallPopup": 1,
        }, self.config.get("guid", ""))
        if initialized.get("code") != 0:
            raise LoginError(f"aTrust 初始化失败（错误码 {initialized.get('code')}）。")
        if env.get("need"):
            reported = local_api("/v1/service/reportEnvBeforeLogin", {
                "ticket": callback_data.get("ticket", ""), "timing": env.get("timing", ""),
                "antiMITMAttackData": self.config.get("antiMITMAttackData", {}),
            }, self.config.get("guid", ""))
            if reported.get("code") != 0:
                raise LoginError(f"aTrust 环境上报失败（错误码 {reported.get('code')}）。")
        auth = self.api("/passport/v1/auth/authCheck", params=callback)
        if auth.get("nextService") == "auth/accessCheck":
            auth = self.api("/passport/v1/auth/accessCheck", {})
        if auth.get("nextService"):
            raise LoginError("VPN 门户要求额外认证，请在浏览器中完成。")
        ticket = self.api("/passport/v1/public/ticketExchange", {}).get("sidTicket")
        if not ticket:
            raise LoginError("SSO 已返回门户，但未取得客户端登录票据。")
        result = local_api("/v1/service/start", {"sidTicket": ticket}, self.config.get("guid", ""))
        if result.get("code") != 0 and not is_connected():
            raise LoginError(f"aTrust 未接受登录票据（错误码 {result.get('code')}）。")
        self.save_cookies()


def wait_connected(timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if is_connected():
                return True
        except LoginError:
            pass
        time.sleep(2)
    return False


def open_browser(url):
    """Open url in the default browser (macOS open / Linux xdg-open)."""
    opener = "/usr/bin/open" if sys.platform == "darwin" else shutil.which("xdg-open")
    if not opener:
        return False
    try:
        return subprocess.run([opener, url], capture_output=True, timeout=15).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def main():
    global PASSWORD_FALLBACK
    PASSWORD_FALLBACK = os.environ.pop("VPN_PASS", "")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["up", "login", "status", "logout"])
    parser.add_argument("--http-only", action="store_true", help="失败时不打开浏览器")
    args = parser.parse_args()
    if args.command == "logout":
        result = local_api("/v1/service/logout")
        if result.get("code") not in (0, 11119052):
            raise LoginError(f"aTrust 注销失败（错误码 {result.get('code')}）。")
        print("○ OFF  ECNU aTrust 已注销")
        return 0
    if args.command == "status":
        online = is_connected()
        print("● ON  ECNU aTrust" if online else "○ OFF  ECNU aTrust")
        return 0 if online else 1
    # A published Docker TCP port can accept connections before aTrust's HTTPS
    # service has started. Wait for an actual API response after compose start.
    deadline = time.monotonic() + 30
    while True:
        try:
            already_online = is_connected()
            break
        except LoginError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(1)
    if already_online:
        if args.command == "up":
            print("● ON  ECNU aTrust 已连接")
            return 0
        print("当前 VPN 已连接，无需重新认证。请先 down 再 login，以免触发并发登录拒绝。", file=sys.stderr)
        return 2
    try:
        Session(fresh=args.command == "login").login()
        if not wait_connected(30):
            raise LoginError("认证已提交，但 aTrust 隧道未在 30 秒内就绪。")
        print("● ON  ECNU aTrust 已连接（HTTP 登录）")
        return 0
    except LoginError as error:
        print(str(error), file=sys.stderr, flush=True)
        if args.http_only:
            return 2
        # Keep browser fallback in the user's regular browser, which can reuse
        # saved passwords and existing SSO cookies. No browser engine is bundled.
        # The portal talks to the local aTrust API, so it must be opened on
        # this machine.
        if open_browser(PORTAL):
            print("已打开浏览器，请完成页面上的认证；正在等待 aTrust 连接…", flush=True)
        else:
            print(f"无法自动打开浏览器，请在本机浏览器访问 {PORTAL} 完成认证；"
                  "正在等待 aTrust 连接…", flush=True)
        if wait_connected(180):
            print("● ON  ECNU aTrust 已连接（浏览器认证）")
            return 0
        raise LoginError("等待浏览器认证超时；容器仍在运行，可继续手动登录。")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (LoginError, subprocess.TimeoutExpired) as error:
        print(str(error) if isinstance(error, LoginError) else "本地操作超时。", file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(130)
