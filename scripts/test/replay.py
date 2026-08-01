#!/usr/bin/env python3
"""Replay synthetic preToolUse payloads into check-response.py — no Cursor needed.

Usage:
  python3 scripts/test/mock-codedefense.py &          # terminal 1
  python3 scripts/test/replay.py                      # terminal 2

Exercises the cases that matter: clean, tripwire in agent_message, tripwire only
in the transcript, empty payload, and each scanner failure mode under both
fail-open and fail-closed.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOOK = os.path.join(REPO, "scripts", "check-response.py")
MOCK = os.environ.get("MOCK_BASE", "http://127.0.0.1:8000")
SCAN_URL = f"{MOCK}/api/v1/codedefense/scan"

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"


def set_fail(mode: str) -> None:
    req = urllib.request.Request(f"{MOCK}/fail/{mode}", data=b"", method="POST")
    urllib.request.urlopen(req, timeout=5).read()


def make_transcript(content: str) -> str:
    fh = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False)
    fh.write(content)
    fh.close()
    return fh.name


def run(payload: dict, env_extra: dict | None = None) -> dict:
    env = dict(os.environ)
    env["SNANTIZER_SCAN_URL"] = SCAN_URL
    env.setdefault("SNANTIZER_TOKEN", "test-token")
    env.setdefault("SNANTIZER_TIMEOUT", "3")
    env.update(env_extra or {})
    proc = subprocess.run(
        [sys.executable, HOOK],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        timeout=45,
    )
    if proc.returncode != 0:
        return {"_error": f"exit {proc.returncode}", "_stderr": proc.stderr.strip()[:300]}
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"_error": "non-JSON stdout", "_stdout": proc.stdout.strip()[:300]}


CASES = []


def case(name, payload, expect, env_extra=None, fail_mode="off"):
    CASES.append((name, payload, expect, env_extra, fail_mode))


base_tool = {"tool_name": "Write", "tool_input": {"path": "x.txt"}, "conversation_id": "c1"}

case(
    "clean agent_message",
    {**base_tool, "agent_message": "Creating the config file now."},
    "allow",
)
case(
    "TRIPWIRE in agent_message",
    {**base_tool, "agent_message": "Okay, TRIPWIRE, writing the file."},
    "deny",
)
case(
    "CAUTION in agent_message (warn tier)",
    {**base_tool, "agent_message": "CAUTION this touches prod."},
    "allow",
)
case(
    "TRIPWIRE only in transcript",
    {
        **base_tool,
        "agent_message": "",
        "transcript_path": make_transcript("earlier turn\nassistant: TRIPWIRE here\n"),
    },
    "deny",
)
case(
    "empty agent_message, no transcript_path",
    {**base_tool, "agent_message": ""},
    "allow",
)
case(
    "empty agent_message, transcript_path missing on disk",
    {**base_tool, "agent_message": "", "transcript_path": "/nonexistent/transcript.txt"},
    "allow",
)
case(
    "scanner 401, fail-closed (default)",
    {**base_tool, "agent_message": "harmless"},
    "deny",
    fail_mode="401",
)
case(
    "scanner 401, fail-open",
    {**base_tool, "agent_message": "harmless"},
    "allow",
    {"SNANTIZER_FAILURE_MODE": "open"},
    fail_mode="401",
)
case(
    "scanner 500, fail-closed",
    {**base_tool, "agent_message": "harmless"},
    "deny",
    fail_mode="500",
)
case(
    "empty token -> 401, fail-closed",
    {**base_tool, "agent_message": "harmless"},
    "deny",
    {"SNANTIZER_TOKEN": ""},
)
case(
    "scanner timeout, fail-closed",
    {**base_tool, "agent_message": "harmless"},
    "deny",
    {"SNANTIZER_TIMEOUT": "2"},
    fail_mode="hang",
)


def main() -> int:
    try:
        urllib.request.urlopen(f"{MOCK}/health", timeout=3).read()
    except Exception:
        print(f"{RED}mock server not reachable at {MOCK}{RESET}")
        print("start it first:  python3 scripts/test/mock-codedefense.py")
        return 1

    passed = failed = 0
    print(f"\n{DIM}replaying {len(CASES)} preToolUse payloads into check-response.py{RESET}\n")

    for name, payload, expect, env_extra, fail_mode in CASES:
        set_fail(fail_mode)
        result = run(payload, env_extra)
        set_fail("off")

        got = result.get("permission", result.get("_error", "?"))
        ok = got == expect
        passed, failed = (passed + 1, failed) if ok else (passed, failed + 1)
        mark = f"{GREEN}PASS{RESET}" if ok else f"{RED}FAIL{RESET}"
        print(f"  {mark}  {name}")
        print(f"        expected={expect} got={got}")
        note = result.get("user_message") or result.get("_stderr") or result.get("_stdout")
        if note:
            print(f"        {DIM}{str(note)[:110]}{RESET}")

    total = passed + failed
    color = GREEN if failed == 0 else YELLOW
    print(f"\n{color}{passed}/{total} passed{RESET}\n")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())