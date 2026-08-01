#!/usr/bin/env python3
"""Mock CodeDefense scan API — mimics /api/v1/codedefense/scan for local testing.

Accepts multipart/form-data with a `text` field and a Bearer token, and returns
the same shape the real scanner does: {"action_to_take": ..., "message": ...}.

Run:  python3 scripts/test/mock-codedefense.py
Then: export SNANTIZER_SCAN_URL=http://127.0.0.1:8000/api/v1/codedefense/scan
      export SNANTIZER_TOKEN=test-token

Verdict rules (priority order):
  1. Forced mode set via /mode/<block|warn|allow|keyword>
  2. Keyword: "TRIPWIRE" in text -> block, "CAUTION" -> warn
  3. Otherwise allow

Failure simulation, for testing the fail-open/fail-closed path:
  curl -X POST localhost:8000/fail/401   -> every scan returns 401
  curl -X POST localhost:8000/fail/500   -> every scan returns 500
  curl -X POST localhost:8000/fail/hang  -> every scan sleeps 20s
  curl -X POST localhost:8000/fail/off   -> back to normal
"""

import json
import os
import re
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("MOCK_PORT", "8000"))
STATE = {"mode": "keyword", "fail": "off", "calls": 0, "blocks": 0}


def log(msg: str) -> None:
    stamp = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"{stamp} {msg}", flush=True)


def extract_field(raw: bytes, name: str) -> str:
    text = raw.decode("utf-8", errors="replace")
    pattern = (
        r'Content-Disposition: form-data; name="' + re.escape(name) + r'"\r?\n\r?\n(.*?)\r?\n--'
    )
    match = re.search(pattern, text, re.DOTALL)
    return match.group(1) if match else ""


def decide(text: str) -> tuple[str, str]:
    mode = STATE["mode"]
    if mode in ("block", "warn", "allow"):
        return mode, f"forced {mode} mode"
    lowered = text.lower()
    if "tripwire" in lowered:
        return "block", "tripwire keyword detected in agent response"
    if "caution" in lowered:
        return "warn", "caution keyword detected"
    return "allow", ""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/health", "/state"):
            self._send(200, STATE)
        else:
            self._send(404, {"detail": "not found"})

    def do_POST(self):
        if self.path.startswith("/mode/"):
            mode = self.path.rsplit("/", 1)[-1]
            if mode in ("block", "warn", "allow", "keyword"):
                STATE["mode"] = mode
                log(f"MODE -> {mode}")
                self._send(200, STATE)
            else:
                self._send(400, {"detail": "bad mode"})
            return

        if self.path.startswith("/fail/"):
            mode = self.path.rsplit("/", 1)[-1]
            if mode in ("401", "500", "hang", "off"):
                STATE["fail"] = mode
                log(f"FAIL -> {mode}")
                self._send(200, STATE)
            else:
                self._send(400, {"detail": "bad fail mode"})
            return

        if not self.path.endswith("/scan"):
            self._send(404, {"detail": "not found"})
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""

        auth = self.headers.get("Authorization", "")
        if STATE["fail"] == "401" or not auth.startswith("Bearer ") or auth == "Bearer ":
            log(f"SCAN -> 401 (auth={auth[:24]!r})")
            self._send(401, {"detail": "Unauthorized"})
            return
        if STATE["fail"] == "500":
            log("SCAN -> 500")
            self._send(500, {"detail": "Internal Server Error"})
            return
        if STATE["fail"] == "hang":
            log("SCAN -> hanging 20s")
            time.sleep(20)

        text = extract_field(raw, "text")
        action, message = decide(text)
        STATE["calls"] += 1
        if action == "block":
            STATE["blocks"] += 1

        log(f"SCAN #{STATE['calls']} len={len(text)} -> {action} {message!r}")
        log(f"        text[:160]={text[:160]!r}")
        self._send(200, {"action_to_take": action, "message": message})


if __name__ == "__main__":
    log(f"mock CodeDefense on http://127.0.0.1:{PORT}/api/v1/codedefense/scan")
    try:
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        log(f"done. calls={STATE['calls']} blocks={STATE['blocks']}")