#!/usr/bin/env python3
"""One-time browser login: OAuth-style loopback-redirect + PKCE against the
PN backend, storing the resulting token in ~/.pn/credentials.json.

Usage:
    python3 scripts/login.py --base-url https://acme.paradigmnetworks.ai

Flow:
    1. Generate a PKCE code_verifier/code_challenge pair and a random state.
    2. Bind an ephemeral local server on 127.0.0.1 to receive exactly one
       GET /callback request.
    3. Open the authorize URL in the user's browser.
    4. Wait (up to a timeout) for the callback, validate `state`, extract
       `code`.
    5. Exchange the code for tokens via POST {base_url}/api/v1/plugin/token.
    6. Persist the tokens via pn_config.save_credentials().
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

import pn_config

CALLBACK_TIMEOUT_SECONDS = 120.0
TOKEN_TIMEOUT_SECONDS = 15.0

SUCCESS_HTML = b"""<!doctype html>
<html><head><title>PN login</title></head>
<body style="font-family: -apple-system, sans-serif; text-align: center; margin-top: 15vh;">
<h2>You're logged in.</h2>
<p>You can close this tab and go back to Cursor.</p>
</body></html>
"""

ERROR_HTML_TEMPLATE = """<!doctype html>
<html><head><title>PN login failed</title></head>
<body style="font-family: -apple-system, sans-serif; text-align: center; margin-top: 15vh;">
<h2>Login failed.</h2>
<p>{message}</p>
<p>You can close this tab and go back to Cursor.</p>
</body></html>
"""


def b64url_no_pad(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def make_pkce_pair() -> tuple[str, str]:
    verifier = b64url_no_pad(secrets.token_bytes(40))
    challenge = b64url_no_pad(hashlib.sha256(verifier.encode("ascii")).digest())
    return verifier, challenge


class CallbackHandler(BaseHTTPRequestHandler):
    # Populated per-instance via server reference (see CallbackServer below).
    result: dict | None = None

    def log_message(self, *args) -> None:  # silence default stderr logging
        pass

    def do_GET(self) -> None:  # noqa: N802 (http.server naming convention)
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/callback":
            self.send_response(404)
            self.end_headers()
            return

        params = {k: v[0] for k, v in urllib.parse.parse_qs(parsed.query).items()}
        self.server.callback_result = params  # type: ignore[attr-defined]

        if params.get("error"):
            message = params.get("error_description") or params.get("error")
            body = ERROR_HTML_TEMPLATE.format(message=message).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(SUCCESS_HTML)))
        self.end_headers()
        self.wfile.write(SUCCESS_HTML)


def wait_for_callback(server: HTTPServer, deadline: float) -> dict | None:
    """Serves requests until /callback is hit or the deadline passes."""
    server.callback_result = None  # type: ignore[attr-defined]
    while time.monotonic() < deadline:
        server.timeout = max(0.1, deadline - time.monotonic())
        server.handle_request()
        result = getattr(server, "callback_result", None)
        if result is not None:
            return result
    return None


def exchange_code(base_url: str, code: str, code_verifier: str, redirect_uri: str) -> dict:
    """POSTs the authorization_code grant. Returns the parsed JSON response.

    Raises RuntimeError with a human-readable message on any failure.
    """
    body = urllib.parse.urlencode(
        {
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": code_verifier,
            "client_id": pn_config.CLIENT_ID,
            "redirect_uri": redirect_uri,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        pn_config.token_url(base_url),
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=TOKEN_TIMEOUT_SECONDS) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw)
            detail = parsed.get("error_description") or parsed.get("error") or raw
        except json.JSONDecodeError:
            detail = raw or f"HTTP {exc.code}"
        raise RuntimeError(f"token exchange failed: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"could not reach {base_url}: {exc.reason}") from exc
    except TimeoutError as exc:
        raise RuntimeError("token exchange timed out") from exc

    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError("token endpoint returned invalid JSON") from exc

    if "access_token" not in parsed:
        detail = parsed.get("error_description") or parsed.get("error") or "no access_token in response"
        raise RuntimeError(f"token exchange failed: {detail}")

    return parsed


def open_browser(url: str) -> bool:
    """Best-effort browser open, returns whether it likely succeeded.

    Prefers the OS's native URL opener (`open` on macOS, `xdg-open` on Linux)
    over Python's `webbrowser` module. On macOS, `webbrowser` drives specific
    browsers via AppleScript/Apple Events (`osascript -e 'tell application
    "Google Chrome" to ...'`), which requires an Automation permission grant
    in System Settings that a non-interactive process (e.g. a script launched
    by an agent's shell tool) has no way to obtain — it fails noisily with
    errAETargetAddressNotPermitted (-10661) for every browser it tries. The
    native opener just asks LaunchServices/xdg to open the URL with the
    default handler, which doesn't send Apple Events to a named app and so
    doesn't hit that restriction.
    """
    native_opener = (
        "open" if sys.platform == "darwin" else "xdg-open" if sys.platform.startswith("linux") else None
    )
    if native_opener and shutil.which(native_opener):
        try:
            result = subprocess.run(
                [native_opener, url],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
            if result.returncode == 0:
                return True
        except (OSError, subprocess.TimeoutExpired):
            pass

    try:
        return webbrowser.open(url)
    except Exception:
        return False


def normalize_base_url(base_url: str) -> str:
    parsed = urllib.parse.urlparse(base_url)
    if not parsed.scheme or not parsed.netloc:
        raise ValueError(f"--base-url must be a full URL like https://acme.paradigmnetworks.ai, got: {base_url!r}")
    return f"{parsed.scheme}://{parsed.netloc}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Log in to PN and store credentials for pn-sanitizer hooks.")
    parser.add_argument("--base-url", required=True, help="Your PN base URL, e.g. https://acme.paradigmnetworks.ai")
    args = parser.parse_args()

    try:
        base_url = normalize_base_url(args.base_url)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    code_verifier, code_challenge = make_pkce_pair()
    state = secrets.token_urlsafe(24)

    server = HTTPServer(("127.0.0.1", 0), CallbackHandler)
    port = server.server_address[1]
    redirect_uri = f"http://127.0.0.1:{port}/callback"

    authorize_url = (
        f"{base_url}/api/v1/plugin/authorize?"
        + urllib.parse.urlencode(
            {
                "client_id": pn_config.CLIENT_ID,
                "code_challenge": code_challenge,
                "code_challenge_method": "S256",
                "redirect_uri": redirect_uri,
                "state": state,
            }
        )
    )

    print(f"Opening your browser to log in to {base_url} ...")
    print(f"If it doesn't open automatically, visit:\n  {authorize_url}")
    opened = open_browser(authorize_url)
    if not opened:
        print("(Could not auto-open a browser — use the URL above.)")

    deadline = time.monotonic() + CALLBACK_TIMEOUT_SECONDS
    result = wait_for_callback(server, deadline)
    server.server_close()

    if result is None:
        print(f"error: timed out waiting for login after {int(CALLBACK_TIMEOUT_SECONDS)}s", file=sys.stderr)
        return 1

    if result.get("error"):
        detail = result.get("error_description") or result.get("error")
        print(f"error: login was denied or failed: {detail}", file=sys.stderr)
        return 1

    if result.get("state") != state:
        print("error: state mismatch on login callback — possible CSRF, aborting", file=sys.stderr)
        return 1

    code = result.get("code")
    if not code:
        print("error: login callback did not include an authorization code", file=sys.stderr)
        return 1

    try:
        token_response = exchange_code(base_url, code, code_verifier, redirect_uri)
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    access_token = token_response["access_token"]
    refresh_token = token_response.get("refresh_token", "")
    expires_in = token_response.get("expires_in", 3600)
    try:
        expires_in = float(expires_in)
    except (TypeError, ValueError):
        expires_in = 3600.0
    expires_at = time.time() + expires_in

    pn_config.save_credentials(base_url, access_token, refresh_token, expires_at)

    print(f"Logged in to {base_url}. Credentials saved to {pn_config.CRED_PATH}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
