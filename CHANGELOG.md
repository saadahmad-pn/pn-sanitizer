# Changelog

All notable changes to pn-sanitizer are recorded here. This project hasn't had
a public release yet — entries below are dated by when the work happened,
not by version tag.

## 2026-08-14 — Bundled jq fallback

`jq` is no longer a hard requirement for the end user. Every script now
resolves `jq` via a shared `JQ_BIN` (in `scripts/lib/common.sh`): prefer a
system install if present, otherwise fall back to an official, checksum-
verified static `jq` 1.8.2 binary bundled per-platform in `scripts/bin/`
(macOS arm64/amd64, Linux amd64/arm64 — see `scripts/bin/PROVENANCE.md`).
If neither is available, the plugin still fails gracefully with a clear
message, same as before — this change removes the common case of that
happening at all, it doesn't remove the safety net. Windows isn't covered by
the bundle yet.

## 2026-08-13 — Pre-submission hardening pass

Prompted by an internal marketplace-readiness review. Fixes:

- **Security:** `common.sh`'s HTTP helper used `curl -F`, which treats a value
  starting with `@` as a file path to read — a message beginning with
  `@/path/to/file` could cause local file contents to be sent to the scan API
  instead of the literal text. Switched to `--form-string`.
- **Security posture:** split scanner-unreachable behavior into
  `PN_FAILURE_MODE` (file writes, default `block`) and
  `PN_PROMPT_FAILURE_MODE` (prompts, default `allow` — a not-yet-logged-in
  user can never get stuck on their first message).
- **Reliability:** `jq` presence is now checked explicitly in every hook
  script; a missing `jq` used to produce malformed JSON responses instead of
  a clear, deliberate message.
- **Reliability:** `login.sh`'s pure-bash URL-encoding fallback (used when
  `python3` is unavailable) had a bug that replaced every character in a URL
  with `%21`; fixed to encode correctly.
- **Reliability:** hook scripts could hang indefinitely reading stdin when
  invoked without a piped payload; added a TTY guard.
- **Reliability:** malformed/non-numeric expiry values from the API or a
  corrupted credentials file could crash a script outright via bad bash
  arithmetic; added validation with safe fallbacks.
- **Reliability:** a non-2xx HTTP response (expired token, server error) with
  a valid-JSON error body used to be silently treated as an "allow" verdict;
  now checked and routed through the same failure-mode logic as an
  unreachable API.
- **Reliability:** `login.sh` now checks for `openssl` and `nc` up front,
  instead of failing confusingly mid-flow or hanging the full 60-second
  callback window with no explanation.
- Confirmed against Cursor's documentation that there is no separate `Edit`
  tool name — all file modifications arrive as `Write`. Removed the dead
  `Edit` handling from `hooks.json`'s matcher and `check-write.sh`.
- Scan timeouts raised from a 5s default to 20s (with hook-level timeouts
  raised to 25s to preserve script-startup slack), based on real latency
  observed against a live CodeDefense deployment.
- User- and agent-facing messages reworded to drop internal terms ("hook",
  "CodeDefense API") in favor of plain language ("the scanning service").
- Removed the bundled local demo scanning stub (`server/`) and its README
  section — it was never meant to ship, only used for early local testing.
- Manifest (`plugin.json`) description rewritten in plain, customer-facing
  language; added `displayName`, `publisher`, `homepage`, `category`,
  `tags`.
- Fixed the onboarding check in `rules/pn-login-check.mdc` and
  `skills/pn-login/SKILL.md`, which only recognized the legacy
  `SNANTIZER_BASE_URL`/`SNANTIZER_TOKEN` env vars and not the newer
  `PN_BASE_URL`/`PN_TOKEN`.
- Fixed a debug-log timestamp corruption on macOS (`date '+%3N'` is a GNU
  extension; BSD `date` doesn't support it).

## 2026-08-11 — Internal production-readiness audit

An internal audit (`AUDIT.md`, no longer in the tree — see git history prior
to the `fixes/plugin-benchmarking` branch for the full record) reviewed the
plugin for public marketplace submission and flagged it **not ready**,
citing several P0 (blocking) issues — including the `curl -F` exfiltration
path, the broken URL-encoding fallback, and missing stdin/dependency guards
— plus a number of P1/P2 documentation and cross-platform gaps. Nearly all
P0 and P1 findings were addressed in the 2026-08-13 pass above.

## Earlier history

- Converted the plugin's hook scripts from Python to Bash.
- Added OAuth 2.0 PKCE login flow; later fixed for OAuth 2.0 compliance
  (`response_type=code`).
- Added the `preToolUse` write-scanning hook alongside the original
  `beforeSubmitPrompt` prompt hook.
