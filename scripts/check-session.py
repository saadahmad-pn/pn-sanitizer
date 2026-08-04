#!/usr/bin/env python3
"""sessionStart hook: if PN isn't configured yet, tell the agent to ask the
user for their base URL and run the pn-login skill.

Per Cursor's hooks contract (cursor.com/docs/hooks), sessionStart is
fire-and-forget — the agent loop does not block on or enforce this hook's
response, and it cannot prevent session creation. It should print JSON like
{"additional_context": "..."} to inject text into the session's initial
system context, or {} when there's nothing to add.

This never blocks session start: any unexpected error is swallowed and we
fall back to the no-op response, mirroring how check-prompt.py fails open on
transport errors.
"""

from __future__ import annotations

import json
import sys

import pn_config

NOT_CONFIGURED_CONTEXT = (
    "PN is not configured for this workspace. Ask the user for their PN base URL "
    "(e.g. https://<org>.paradigmnetworks.ai), then run the pn-login skill to "
    "authenticate before relying on CodeDefense-gated prompts or tool calls."
)


def noop() -> dict:
    return {}


def not_configured() -> dict:
    return {"additional_context": NOT_CONFIGURED_CONTEXT}


def main() -> int:
    try:
        # sessionStart's input isn't used by this hook, but read/discard it
        # the same way the other hooks do in case stdin isn't drained.
        if not sys.stdin.isatty():
            raw = sys.stdin.read()
            if raw.strip():
                try:
                    json.loads(raw)
                except json.JSONDecodeError:
                    pass

        config = pn_config.resolve_config()
        if config is None:
            print(json.dumps(not_configured()))
        else:
            print(json.dumps(noop()))
        return 0
    except Exception:
        # Fail open: never block a session from starting because this hook
        # errored. Emit the minimal no-op response.
        print(json.dumps(noop()))
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
