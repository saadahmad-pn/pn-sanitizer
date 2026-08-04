#!/usr/bin/env python3
"""preToolUse hook: scan the agent's response context, deny the pending tool call if blocked.

Denying every tool call starves the agent loop. That is the interrupt mechanism —
the response text itself is already on screen and cannot be recalled.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

import pn_config

# SNANTIZER_SCAN_URL, if set, overrides the computed scan URL outright.
SCAN_URL_OVERRIDE = os.environ.get("SNANTIZER_SCAN_URL")
TIMEOUT_SECONDS = float(os.environ.get("SNANTIZER_TIMEOUT", "5"))
TRANSCRIPT_BYTES = int(os.environ.get("SNANTIZER_TRANSCRIPT_BYTES", "4000"))

# When the scanner cannot give a verdict, do we allow or deny?
# "open" matches check-prompt.py's availability-first stance.
# "closed" is the governance-first stance and is the right default for a gate
# that exists to stop the agent from acting.
FAILURE_MODE = os.environ.get("SNANTIZER_FAILURE_MODE", "closed").lower()

DEBUG_LOG = os.path.expanduser(os.environ.get("SNANTIZER_LOG", "~/.pn/check-response.log"))


def log(message: str) -> None:
    if not DEBUG_LOG:
        return
    try:
        os.makedirs(os.path.dirname(DEBUG_LOG), exist_ok=True)
        with open(DEBUG_LOG, "a") as fh:
            fh.write(message.rstrip() + "\n")
    except OSError:
        pass


def allow(message: str | None = None) -> dict:
    out: dict = {"permission": "allow"}
    if message:
        out["user_message"] = message
    return out


def deny(reason: str) -> dict:
    return {
        "permission": "deny",
        "user_message": f"Blocked by CodeDefense: {reason}",
        "agent_message": (
            f"This turn failed a compliance check ({reason}). Do not retry, do not "
            "attempt an alternative tool, and do not work around this. Stop and wait "
            "for the user."
        ),
    }


def on_scan_failure(reason: str) -> dict:
    if FAILURE_MODE == "open":
        return allow(f"CodeDefense unavailable ({reason}). Allowing tool call.")
    return deny(f"scanner unavailable — {reason} (fail-closed)")


def build_multipart_body(fields: dict) -> tuple[bytes, str]:
    boundary = "----SnantizerBoundary7d1f3a"
    lines = []
    for name, value in fields.items():
        lines.append(f"--{boundary}")
        lines.append(f'Content-Disposition: form-data; name="{name}"')
        lines.append("")
        lines.append(value)
    lines.append(f"--{boundary}--")
    lines.append("")
    return "\r\n".join(lines).encode("utf-8"), f"multipart/form-data; boundary={boundary}"


def read_transcript(path: str) -> str:
    if not path or not os.path.isfile(path):
        return ""
    try:
        with open(path, "rb") as fh:
            try:
                fh.seek(-TRANSCRIPT_BYTES, os.SEEK_END)
            except OSError:
                fh.seek(0)
            return fh.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


def scan(text: str, scan_url: str, access_token: str) -> tuple[str, str]:
    """Returns (action_to_take, message). Raises on transport failure."""
    body, content_type = build_multipart_body({"text": text})
    request = urllib.request.Request(
        scan_url,
        data=body,
        headers={
            "Content-Type": content_type,
            "Authorization": f"Bearer {access_token}",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        result = json.loads(response.read().decode("utf-8"))
    return result.get("action_to_take", "allow"), (result.get("message") or "")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        print(json.dumps(deny("hook received invalid JSON input")))
        return 0

    tool_name = payload.get("tool_name", "")
    agent_message = payload.get("agent_message") or ""
    transcript = read_transcript(payload.get("transcript_path") or "")

    scan_text = "\n".join(part for part in (agent_message, transcript) if part).strip()

    log(
        f"[preToolUse] tool={tool_name!r} agent_message_len={len(agent_message)} "
        f"transcript_len={len(transcript)} scan_len={len(scan_text)}"
    )

    if not scan_text:
        # Nothing to scan. This is common: agent_message is often empty and
        # transcript_path may not resolve. Allowing here is what makes the gate
        # silently inert, so it is logged loudly.
        log("[preToolUse] EMPTY SCAN TEXT — nothing to evaluate, allowing")
        print(json.dumps(allow()))
        return 0

    config = pn_config.resolve_config()
    if config is None:
        # Not configured (no env override, no valid stored login, or a
        # refresh failed). Route through the same on_scan_failure path as a
        # genuinely unreachable scanner, since FAILURE_MODE already encodes
        # the right open/closed policy for "no verdict available".
        log("[preToolUse] NOT CONFIGURED — no env override or valid login found")
        print(json.dumps(on_scan_failure("PN not configured — run the pn-login skill")))
        return 0

    base_url, access_token = config
    scan_url = SCAN_URL_OVERRIDE or f"{base_url}/api/v1/codedefense/scan"

    try:
        action, message = scan(scan_text, scan_url, access_token)
    except urllib.error.HTTPError as exc:
        # 401/403/429/5xx. A misconfigured or rejecting scanner must not look
        # identical to a clean scan.
        print(json.dumps(on_scan_failure(f"HTTP {exc.code} {exc.reason}")))
        return 0
    except urllib.error.URLError as exc:
        print(json.dumps(on_scan_failure(f"unreachable: {exc.reason}")))
        return 0
    except TimeoutError:
        print(json.dumps(on_scan_failure("timed out")))
        return 0
    except json.JSONDecodeError:
        print(json.dumps(on_scan_failure("scanner returned invalid JSON")))
        return 0

    log(f"[preToolUse] verdict={action!r} message={message!r}")

    if action == "block":
        print(json.dumps(deny(message or "policy violation")))
        return 0

    if action == "warn":
        print(json.dumps(allow(message or "CodeDefense warning")))
        return 0

    print(json.dumps(allow()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())