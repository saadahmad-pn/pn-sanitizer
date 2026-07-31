#!/usr/bin/env python3
"""beforeSubmitPrompt hook: ask Snantizer API whether to allow the prompt."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

CHECK_URL = os.environ.get("SNANTIZER_URL", "http://127.0.0.1:8000/check")
TIMEOUT_SECONDS = float(os.environ.get("SNANTIZER_TIMEOUT", "5"))


def allow(message: str | None = None) -> dict:
    out: dict = {"continue": True}
    if message:
        out["user_message"] = message
    return out


def deny(message: str) -> dict:
    return {"continue": False, "user_message": message}


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        print(json.dumps(deny("Snantizer hook received invalid JSON input.")))
        return 0

    prompt = payload.get("prompt") or ""
    body = json.dumps({"prompt": prompt}).encode("utf-8")
    request = urllib.request.Request(
        CHECK_URL,
        data=body,
        headers={"Content-Type": "application/json"},
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
                allow(f"Snantizer API unreachable ({CHECK_URL}): {exc.reason}. Allowing prompt.")
            )
        )
        return 0
    except TimeoutError:
        # Server didn't respond within TIMEOUT_SECONDS. Fail open.
        print(json.dumps(allow("Snantizer API timed out. Allowing prompt.")))
        return 0
    except json.JSONDecodeError:
        # Server responded but body wasn't valid JSON. Fail open.
        print(json.dumps(allow("Snantizer API returned invalid JSON. Allowing prompt.")))
        return 0

    if result.get("malicious"):
        reason = result.get("reason") or "Prompt blocked by Snantizer."
        print(json.dumps(deny(reason)))
        return 0

    print(json.dumps(allow()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
