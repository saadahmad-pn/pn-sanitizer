#!/usr/bin/env python3
"""preToolUse hook: scan Write-tool content via the CodeDefense scan API
before the agent is allowed to write it to disk.

Decision logic:
  action_to_take == "block" -> permission: deny, with an agent_message that
      instructs the agent to stop and report rather than retry/work around it.
  action_to_take == "warn"  -> permission: allow, but surface the message.
  anything else / missing   -> permission: allow, silently.

The API's action_to_take is treated as authoritative — this hook does not
re-derive its own threshold from threat_level or categories, since that
would create a second source of truth that can disagree with the server's
own policy engine.

disabled_categories_captured and compliance.owasp findings do not affect
the permission decision (a category the org has disabled stays disabled;
compliance findings are informational). Both are written to a local audit
log so nothing is silently lost, without overriding server-side policy.

Fail-open-but-loud on any API error (unreachable, timeout, bad JSON): the
write proceeds, but the user_message makes it clear no scan actually
happened, rather than allowing silently. This is a security/availability
tradeoff — flip FAIL_OPEN to False below if your team decides writes should
be blocked outright whenever the scanner is unreachable.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

# TODO: staging hardcode — move to config/env once this is stable.
BASE_URL = "https://pn.staging.paradigmnetworks.ai"
ACCESS_TOKEN = "YOUR_ACCESS_TOKEN"

SCAN_URL = f"{BASE_URL}/api/v1/codedefense/scan"
TIMEOUT_SECONDS = 20.0  # scan API observed ~840ms; generous headroom for staging variance

SKIP_PATH_FRAGMENTS = ("/node_modules/", "/.git/", "/dist/", "/.venv/", "/venv/")
MAX_SCAN_BYTES = 200_000

AUDIT_LOG_PATH = os.path.expanduser("~/.pn-sanitizer/audit.jsonl")

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


def build_multipart_body(filename: str, content: str) -> tuple[bytes, str]:
    boundary = "----CodeDefenseBoundary4f2a7d"
    parts = [
        f"--{boundary}",
        f'Content-Disposition: form-data; name="files"; filename="{filename}"',
        "Content-Type: text/plain",
        "",
        content,
        f"--{boundary}--",
        "",
    ]
    body = "\r\n".join(parts).encode("utf-8")
    return body, f"multipart/form-data; boundary={boundary}"


def audit_log(entry: dict) -> None:
    """Best-effort append to a local audit log. Never raises — a logging
    failure must not affect the permission decision."""
    try:
        os.makedirs(os.path.dirname(AUDIT_LOG_PATH), exist_ok=True)
        entry = {"timestamp": time.time(), **entry}
        with open(AUDIT_LOG_PATH, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except OSError:
        pass


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        print(json.dumps(allow("Write-guard hook received invalid JSON input.")))
        return 0

    if payload.get("tool_name") != "Write":
        print(json.dumps(allow()))
        return 0

    tool_input = payload.get("tool_input") or {}
    file_path = tool_input.get("file_path") or ""
    content = tool_input.get("content") or ""
    filename = os.path.basename(file_path) or "file"

    if any(fragment in file_path for fragment in SKIP_PATH_FRAGMENTS):
        print(json.dumps(allow()))
        return 0

    if not content or len(content.encode("utf-8")) > MAX_SCAN_BYTES:
        # Nothing to scan, or too large — allow rather than block on size alone.
        print(json.dumps(allow()))
        return 0

    body, content_type = build_multipart_body(filename, content)
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
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        reason = getattr(exc, "reason", None) or str(exc) or "unknown error"
        warning = f"\u26a0\ufe0f CodeDefense API error ({reason}). Write allowed WITHOUT a security scan."
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

    # Prefer the per-file result; fall back to the top-level analysis if absent.
    file_analyses = result.get("file_analyses") or []
    analysis = file_analyses[0] if file_analyses else result.get("analysis") or result

    action = analysis.get("action_to_take", result.get("action_to_take", "allow"))
    message = (
        analysis.get("message")
        or result.get("message")
        or f"Write to '{filename}' blocked by CodeDefense."
    )

    # Informational only — never affects the permission decision.
    audit_log(
        {
            "file_path": file_path,
            "decision": action,
            "threat_level": analysis.get("threat_level", result.get("overall_threat_level")),
            "categories": analysis.get("categories", []),
            "disabled_categories_captured": analysis.get("disabled_categories_captured", []),
            "compliance": analysis.get("compliance", {}),
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