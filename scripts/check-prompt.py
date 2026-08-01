#!/usr/bin/env python3
"""beforeSubmitPrompt hook: ask CodeDefense scan API whether to allow the prompt."""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request

# TODO: staging hardcode — move to config/env once this is stable.
BASE_URL = "https://4053-182-188-110-200.ngrok-free.app"
ACCESS_TOKEN = "z4YVGVOvMK3qDSujRXCBPFy0JpEiit42nATXjQ2WDId6J8Bm8v"

SCAN_URL = f"{BASE_URL}/api/v1/codedefense/scan"
TIMEOUT_SECONDS = 5.0


def allow(message: str | None = None) -> dict:
    out: dict = {"continue": True}
    if message:
        out["user_message"] = message
    return out


def deny(message: str) -> dict:
    return {"continue": False, "user_message": message}


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

    body, content_type = build_multipart_body({"text": prompt})
    request = urllib.request.Request(
        SCAN_URL,
        data=body,
        headers={
            "Content-Type": content_type,
            "Authorization": f"Bearer {ACCESS_TOKEN}",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            result = json.loads(response.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        # Server unreachable (connection refused, DNS failure, host down, etc.)
        # Fail open: don't block prompts just because the guard is offline.
        print(
            json.dumps(
                allow(f"CodeDefense API unreachable ({SCAN_URL}): {exc.reason}. Allowing prompt.")
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