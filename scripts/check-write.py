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
import urllib.error
import urllib.request

import pn_config

# SNANTIZER_SCAN_URL, if set, overrides the computed scan URL outright.
SCAN_URL_OVERRIDE = os.environ.get("SNANTIZER_SCAN_URL")
TIMEOUT_SECONDS = float(os.environ.get("SNANTIZER_TIMEOUT", "5"))
TRANSCRIPT_BYTES = int(os.environ.get("SNANTIZER_TRANSCRIPT_BYTES", "4000"))

# When the scanner cannot give a verdict, do we allow or deny?
# "open" allows writes if API is unreachable (availability-first).
# "closed" denies writes if API unreachable (governance-first, more secure).
FAILURE_MODE = os.environ.get("SNANTIZER_FAILURE_MODE", "closed").lower()

AUDIT_LOG_PATH = os.path.expanduser("~/.pn-sanitizer/audit.jsonl")
DESKTOP_LOG_PATH = os.path.expanduser("~/Desktop/pn-sanitizer-hook.log")

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
        entry = {"timestamp": datetime.datetime.now().isoformat(), **entry}
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


def on_scan_failure(reason: str) -> dict:
    if FAILURE_MODE == "open":
        return allow(f"CodeDefense unavailable ({reason}). Write allowed WITHOUT a security scan.")
    return deny(
        f"CodeDefense unavailable ({reason}). Write blocked.",
        f"The security scan API is unavailable ({reason}). Do not retry this write."
    )


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

    config = pn_config.resolve_config()
    if config is None:
        reason = "PN not configured — run the pn-login skill"
        audit_log({"file_path": file_path, "decision": "deny" if FAILURE_MODE == "closed" else "allow", "reason": "not_configured", "detail": reason})
        print(json.dumps(on_scan_failure(reason)))
        return 0

    base_url, access_token = config
    scan_url = SCAN_URL_OVERRIDE or f"{base_url}/api/v1/codedefense/scan"

    body, content_type = build_multipart_body({"text": scan_text})
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
        reason = f"HTTP {exc.code} {exc.reason}"
        msg = f"CodeDefense API returned {reason} — write blocked until the API error is resolved."
        audit_log({"file_path": file_path, "decision": "deny", "reason": "http_error", "detail": reason})
        print(json.dumps(deny(msg, f"{msg} Do not retry. Report this API error to the user.")))
        return 0
    except urllib.error.URLError as exc:
        reason = str(getattr(exc, "reason", None) or exc) or "connection failed"
        audit_log({
            "file_path": file_path,
            "decision": "allow" if FAILURE_MODE == "open" else "deny",
            "reason": "api_unreachable",
            "detail": reason,
        })
        print(json.dumps(on_scan_failure(reason)))
        return 0
    except TimeoutError:
        audit_log({
            "file_path": file_path,
            "decision": "allow" if FAILURE_MODE == "open" else "deny",
            "reason": "api_timeout",
            "detail": f"{TIMEOUT_SECONDS}s timeout",
        })
        print(json.dumps(on_scan_failure("timed out")))
        return 0
    except json.JSONDecodeError:
        audit_log({
            "file_path": file_path,
            "decision": "allow" if FAILURE_MODE == "open" else "deny",
            "reason": "api_invalid_json",
            "detail": "scanner returned invalid JSON",
        })
        print(json.dumps(on_scan_failure("invalid JSON response")))
        return 0

    desktop_log_response(result)

    action = result.get("action_to_take", "allow")
    message = result.get("message") or "Agent response blocked by CodeDefense."

    audit_log({
        "file_path": file_path,
        "decision": action,
        "scan_id": result.get("scan_id"),
    })

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
