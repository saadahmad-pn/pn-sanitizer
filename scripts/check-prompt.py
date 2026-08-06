#!/usr/bin/env python3
"""beforeSubmitPrompt hook: ask CodeDefense scan API whether to allow the prompt."""

from __future__ import annotations

import datetime
import json
import os
import sys
import urllib.error
import urllib.request

import pn_config

# SNANTIZER_SCAN_URL, if set, overrides the computed scan URL outright.
SCAN_URL_OVERRIDE = os.environ.get("SNANTIZER_SCAN_URL")
TIMEOUT_SECONDS = float(os.environ.get("SNANTIZER_TIMEOUT", "5"))


def allow(message: str | None = None) -> dict:
    out: dict = {"continue": True}
    if message:
        out["user_message"] = message
    return out


def deny(message: str) -> dict:
    return {"continue": False, "user_message": message}


def desktop_log(payload: dict, extra: dict) -> None:
    try:
        now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(DESKTOP_LOG_PATH, "a") as f:
            f.write(f"\n{'='*60}\n")
            f.write(f"hook: beforeSubmitPrompt  |  {now}\n")
            f.write(f"{'='*60}\n")
            f.write(json.dumps({**extra, "payload": payload}, indent=2))
            f.write("\n")
    except OSError:
        pass


def desktop_log_response(response: dict) -> None:
    try:
        now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(DESKTOP_LOG_PATH, "a") as f:
            f.write(f"--- API Response  |  {now} ---\n")
            f.write(json.dumps(response, indent=2))
            f.write("\n")
    except OSError:
        pass


def build_multipart_body(fields: dict) -> tuple[bytes, str]:
    """Builds a simple multipart/form-data body for text-only fields."""
    boundary = "----SnantizerBoundary7d1f3a"
    lines = []
    for name, value in fields.items():
        lines.append(f"--{boundary}")
        lines.append(f'Content-Disposition: form-data; name="{name}"')
        lines.append("")
        lines.append(value)
    lines.append(f"--{boundary}--")
    lines.append("")
    body = "\r\n".join(lines).encode("utf-8")
    content_type = f"multipart/form-data; boundary={boundary}"
    return body, content_type


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        print(json.dumps(deny("CodeDefense hook received invalid JSON input.")))
        return 0

    prompt = payload.get("prompt") or ""

    config = pn_config.resolve_config()
    if config is None:
        # Not configured (no env override, no valid stored login, or a
        # refresh failed). Treat this exactly like "scanner unreachable":
        # fail open so a not-yet-logged-in developer isn't blocked.
        print(
            json.dumps(
                allow(
                    "PN is not configured (no login found). Allowing prompt — run the "
                    "pn-login skill to authenticate CodeDefense."
                )
            )
        )
        return 0

    base_url, access_token = config
    scan_url = SCAN_URL_OVERRIDE or f"{base_url}/api/v1/codedefense/scan"

    body, content_type = build_multipart_body({"text": prompt})
    request = urllib.request.Request(
        scan_url,
        data=body,
        headers={
            "Content-Type": content_type,
            "Authorization": f"Bearer {access_token}",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            result = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        # Server is reachable but returned an error status (e.g. 401, 500).
        # Fail closed — this is a misconfiguration, not transient unavailability.
        print(json.dumps(deny(f"CodeDefense API returned HTTP {exc.code}: {exc.reason}. Prompt blocked.")))
        return 0
    except urllib.error.URLError as exc:
        # Server unreachable (connection refused, DNS failure, host down, etc.)
        # Fail open: don't block prompts just because the guard is offline.
        print(
            json.dumps(
                allow(f"CodeDefense API unreachable ({scan_url}): {exc.reason}. Allowing prompt.")
            )
        )
        return 0
    except TimeoutError:
        # Server didn't respond within TIMEOUT_SECONDS. Fail open.
        print(json.dumps(allow("CodeDefense API timed out. Allowing prompt.")))
        return 0
    except json.JSONDecodeError:
        # Server responded but body wasn't valid JSON. Fail open.
        print(json.dumps(allow("CodeDefense API returned invalid JSON. Allowing prompt.")))
        return 0

    desktop_log_response(result)

    action = result.get("action_to_take", "allow")
    message = result.get("message") or "Prompt blocked by CodeDefense."

    if action == "block":
        print(json.dumps(deny(message)))
        return 0

    if action == "warn":
        # Warn: allow through, but surface the message to the user.
        print(json.dumps(allow(message)))
        return 0

    print(json.dumps(allow()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
