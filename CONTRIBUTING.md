# Contributing

paradigm-scanner's hooks are plain Bash, deliberately kept simple since they run
on every prompt and file write in Cursor. A few things to know before making
changes:

## Requirements

- Bash, `curl`, `openssl`, and `nc` — the hook scripts check for these
  explicitly and fail with a clear message if one is missing.
- `jq` is preferred but not strictly required — every script falls back to a
  bundled binary in `scripts/bin/` for macOS/Linux on amd64/arm64. See
  `scripts/bin/PROVENANCE.md` before touching anything jq-related, and update
  those binaries (with verified checksums) if you ever bump the bundled
  version.
- `python3` is optional — `login.sh` falls back to a pure-Bash URL encoder if
  it's unavailable.

## Running the tests

```bash
bash test/run-all-tests.sh
```

This runs unit tests, integration tests, and error-scenario tests against
the hook scripts using a mock server (`test/mock-server.sh`).

## Conventions this codebase relies on

- **Portability first.** Scripts need to work on both BSD tools (macOS) and
  GNU tools (Linux) — e.g. `date`, `sed`, and `stat` behave differently
  between the two. Test on both before assuming a one-liner is portable.
- **Fail deliberately, not accidentally.** Every hook must always emit valid
  JSON on stdout, even when something goes wrong (missing dependency,
  network error, malformed input). Prefer an explicit, documented
  allow/deny decision over letting a script crash or hang.
- **User- and agent-facing messages use plain language.** Avoid internal
  terms like "hook" or naming internal API paths — someone using this
  plugin day-to-day shouldn't need to know Cursor's or CodeDefense's
  internals to understand a message.

## Pull requests

Keep changes scoped and explain the *why*, not just the *what* — especially
for anything touching the failure-mode logic (`PN_FAILURE_MODE`,
`PN_PROMPT_FAILURE_MODE`) or the login flow, where a subtle behavior change
can affect every user of the plugin.
