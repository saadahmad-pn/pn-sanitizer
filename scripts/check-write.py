#!/usr/bin/env python3
"""preToolUse hook: scan the agent's response message via the CodeDefense API
before a Write or Edit tool call is allowed to execute.

If the agent's response is flagged as malicious, the tool call is denied and
the agent is instructed to stop — ending the loop before anything touches disk.
If agent_message is empty, the hook passes silently (nothing to scan).
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.request

# TODO: staging hardcode — move to config/env once this is stable.
BASE_URL = "https://ed4d-182-188-110-200.ngrok-free.app"
ACCESS_TOKEN = "qq7RGA3VmrbJ33HKmuC5139ZFMtoMaAOh6jGvOfCIJ6APV3qwk"

SCAN_URL = f"{BASE_URL}/api/v1/codedefense/scan"
TIMEOUT_SECONDS = 17.0  # 3s headroom before hooks.json timeout=20 fires (failClosed)

AUDIT_LOG_PATH = os.path.expanduser("~/.pn-sanitizer/audit.jsonl")
DESKTOP_LOG_PATH = os.path.expanduser("~/Desktop/pn-sanitizer-hook.log")
TRANSCRIPT_BYTES = 4000

# If the scan API is unreachable/times out/returns bad JSON: True = allow the
# write through (loudly flagged as unscanned). False = deny the write outright.
FAIL_OPEN = True

STOP_INSTRUCTION = (
    "A security scan blocked this write due to a detected policy violation. "
    "Do not retry this write or attempt a workaround (e.g. base64-encoding it, "
    "splitting the string, writing it to a different file, or renaming the "
    "variable). Stop this task and report the violation to the user."
)


def allow(message: str | None = None) -> dict:
    out: dict = {"permission": "allow"}
    if message:
        out["user_message"] = message
    return out


def deny(user_message: str, agent_message: str) -> dict:
    return {
        "permission": "deny",
        "user_message": user_message,
        "agent_message": agent_message,
    }


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
    body = "\r\n".join(lines).encode("utf-8")
    return body, f"multipart/form-data; boundary={boundary}"


def audit_log(entry: dict) -> None:
    try:
        os.makedirs(os.path.dirname(AUDIT_LOG_PATH), exist_ok=True)
        entry = {"timestamp": time.time(), **entry}
        with open(AUDIT_LOG_PATH, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except OSError:
        pass


def desktop_log(payload: dict, extra: dict) -> None:
    try:
        now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(DESKTOP_LOG_PATH, "a") as f:
            f.write(f"\n{'='*60}\n")
            f.write(f"hook: preToolUse  |  {now}\n")
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


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        print(json.dumps(allow("Write-guard hook received invalid JSON input.")))
        return 0

    tool_name = payload.get("tool_name") or ""
    if tool_name not in ("Write", "Edit"):
        print(json.dumps(allow()))
        return 0

    agent_message = (payload.get("agent_message") or "").strip()
    transcript_path = payload.get("transcript_path") or ""
    file_path = (payload.get("tool_input") or {}).get("file_path") or ""

    scan_text = agent_message or read_transcript(transcript_path)

    desktop_log(payload, {
        "tool_name": tool_name,
        "file_path": file_path,
        "agent_message_len": len(agent_message),
        "transcript_path": transcript_path,
        "transcript_path_exists": os.path.isfile(transcript_path) if transcript_path else False,
        "scan_text_len": len(scan_text),
    })

    if not scan_text:
        print(json.dumps(allow()))
        return 0

    body, content_type = build_multipart_body({"text": scan_text})
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
    except urllib.error.HTTPError as exc:
        # Server is reachable but returned an error status (e.g. 401, 500).
        # Treat as fail-closed regardless of FAIL_OPEN \u2014 this is a misconfiguration,
        # not transient unavailability.
        reason = f"HTTP {exc.code} {exc.reason}"
        msg = f"\u26a0\ufe0f CodeDefense API returned {reason} \u2014 write blocked until the API error is resolved."
        audit_log({"file_path": file_path, "decision": "deny", "reason": "http_error", "detail": reason})
        print(json.dumps(deny(msg, f"{msg} Do not retry. Report this API error to the user.")))
        return 0
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        reason = getattr(exc, "reason", None) or str(exc) or "unknown error"
        warning = f"\u26a0\ufe0f CodeDefense API unreachable ({reason}). Write allowed WITHOUT a security scan."
        audit_log(
            {
                "file_path": file_path,
                "decision": "allow" if FAIL_OPEN else "deny",
                "reason": "api_error",
                "detail": str(reason),
            }
        )
        if FAIL_OPEN:
            print(json.dumps(allow(warning)))
        else:
            print(
                json.dumps(
                    deny(
                        warning.replace("allowed WITHOUT", "denied — no"),
                        "The security scan API is unreachable and this workspace is "
                        "configured to fail closed. Stop this task and report the "
                        "API error to the user; do not retry.",
                    )
                )
            )
        return 0

    desktop_log_response(result)

    action = result.get("action_to_take", "allow")
    message = result.get("message") or "Agent response blocked by CodeDefense."

    audit_log(
        {
            "file_path": file_path,
            "decision": action,
            "scan_id": result.get("scan_id"),
        }
    )

    if action == "block":
        print(json.dumps(deny(message, f"{message} {STOP_INSTRUCTION}")))
        return 0

    if action == "warn":
        print(json.dumps(allow(message)))
        return 0

    print(json.dumps(allow()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
