#!/usr/bin/env python3
"""Shared config/auth module for the PN hook scripts and CLI.

Reads and writes ~/.pn/credentials.json (the on-disk result of the one-time
browser login flow in scripts/login.py) and resolves the (base_url,
access_token) pair the hook scripts need to call the CodeDefense scan API,
refreshing the access token in the background when it is near expiry.

Stdlib only — no `requests` — to match the style of the existing hook
scripts (check-prompt.py, check-response.py), which are invoked directly by
Cursor's hooks runner and shouldn't require a plugin-managed virtualenv.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

CLIENT_ID = "cursor-plugin"

CRED_DIR = os.path.expanduser("~/.pn")
CRED_PATH = os.path.join(CRED_DIR, "credentials.json")

TOKEN_TIMEOUT_SECONDS = 10.0

# If the stored access token expires within this many seconds, treat it as
# expired and refresh proactively rather than racing the real expiry.
EXPIRY_MARGIN_SECONDS = 60

REQUIRED_FIELDS = ("base_url", "access_token", "refresh_token", "expires_at")


def token_url(base_url: str) -> str:
    return f"{base_url.rstrip('/')}/api/v1/plugin/token"


def load_credentials() -> dict | None:
    """Returns the parsed credentials file, or None if missing/unreadable/malformed."""
    try:
        with open(CRED_PATH, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None

    if not isinstance(data, dict) or not all(key in data for key in REQUIRED_FIELDS):
        return None
    return data


def save_credentials(base_url: str, access_token: str, refresh_token: str, expires_at: float) -> None:
    """Writes ~/.pn/credentials.json with 0600 permissions, creating ~/.pn if needed."""
    os.makedirs(CRED_DIR, mode=0o700, exist_ok=True)
    try:
        os.chmod(CRED_DIR, 0o700)
    except OSError:
        pass

    data = {
        "base_url": base_url,
        "access_token": access_token,
        "refresh_token": refresh_token,
        "expires_at": expires_at,
    }

    # Create with 0600 up front (rather than chmod after the fact) so the
    # token is never briefly world/group readable on disk.
    fd = os.open(CRED_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    try:
        os.chmod(CRED_PATH, 0o600)
    except OSError:
        pass


def _refresh(base_url: str, refresh_token: str) -> dict | None:
    """POSTs the refresh_token grant. Returns the parsed JSON response, or None on any failure.

    Never raises — network errors, non-2xx responses, and malformed JSON all
    result in None, matching get_valid_access_token()'s "None means not
    logged in, ask again" contract.
    """
    body = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": CLIENT_ID,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        token_url(base_url),
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=TOKEN_TIMEOUT_SECONDS) as response:
            return json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ValueError, OSError):
        return None


def get_valid_access_token() -> tuple[str, str] | None:
    """Returns (base_url, access_token), refreshing the token first if it's near expiry.

    Returns None if there is no stored config, the file is malformed, or a
    needed refresh fails for any reason. Callers must treat None as "not
    logged in, ask the user to run the pn-login flow again" — this function
    never raises.
    """
    creds = load_credentials()
    if creds is None:
        return None

    try:
        base_url = str(creds["base_url"])
        access_token = str(creds["access_token"])
        refresh_token = str(creds["refresh_token"])
        expires_at = float(creds["expires_at"])
    except (KeyError, TypeError, ValueError):
        return None

    if expires_at - time.time() > EXPIRY_MARGIN_SECONDS:
        return base_url, access_token

    refreshed = _refresh(base_url, refresh_token)
    if not refreshed:
        return None

    new_access_token = refreshed.get("access_token")
    new_refresh_token = refreshed.get("refresh_token")
    expires_in = refreshed.get("expires_in")
    if not new_access_token or not new_refresh_token or expires_in is None:
        return None

    try:
        new_expires_at = time.time() + float(expires_in)
    except (TypeError, ValueError):
        return None

    save_credentials(base_url, new_access_token, new_refresh_token, new_expires_at)
    return base_url, new_access_token


def resolve_config(
    env_base_var: str = "SNANTIZER_BASE_URL",
    env_token_var: str = "SNANTIZER_TOKEN",
) -> tuple[str, str] | None:
    """Resolves (base_url, access_token) for a hook script.

    Explicit env vars (useful for a shared-host setup where they're set once
    for everyone) always take precedence over the stored per-user file. The
    file is only consulted when the env vars aren't both set.
    """
    env_base = os.environ.get(env_base_var)
    env_token = os.environ.get(env_token_var)
    if env_base and env_token:
        return env_base, env_token
    return get_valid_access_token()
