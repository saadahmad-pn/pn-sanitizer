# Changelog

All notable changes to Paradigm Networks (formerly pn-sanitizer) are recorded
here. This project hasn't had a public release yet — entries below are dated
by when the work happened, not by version tag.

## 2026-08-31 — Recorded the per-scan latency/cost tradeoff as a known decision

Not a code change. Every prompt and every file write triggers a real,
billed `/v1/messages` completion whose actual reply is discarded on the
allow path (only the verdict, reverse-engineered from the response
shape, matters — see `pn_parse_messages_response`'s comment). Each call
carries up to a 20s timeout by default (`SNANTIZER_TIMEOUT`), and the
hook entries themselves allow more (25s/45s) — so a prompt can pay up to
that long before it's even sent to the model, and every file write pays
it again, independently.

This wasn't a decision made when this plugin moved to `/v1/messages` —
it's inherited unchanged from the retired `codedefense/scan` endpoint's
timeout defaults. Recording it here explicitly so it's a tradeoff this
project has actually decided to accept for now, not just something that
happened to carry over. Not fixing it in this pass.

Worth raising with whoever owns the backend/control-server side: the
existing code comments already state the platform's guard fires *before*
the requested model actually runs on the block path — if that's also
true on the allow path, a `max_tokens: 1` request or a dedicated
scan-only mode might avoid paying for a full completion that's thrown
away on every single call. That's a backend question, not something
resolvable from this repo alone.

## 2026-08-23 — Windows support

Every hook and the login flow now has a native PowerShell twin
(`check-session.ps1`, `check-prompt.ps1`, `check-write.ps1`,
`check-repo-context.ps1`, `login.ps1`, `pn_config.ps1`, `lib/common.ps1`,
`lib/git-utils.ps1`), targeting Windows PowerShell 5.1 — the version that
ships on every Windows machine by default, not PowerShell 7+-only syntax.
Zero additional installs: `ConvertTo-Json`/`ConvertFrom-Json`,
`Invoke-RestMethod`, `System.Security.Cryptography`, and
`System.Net.HttpListener` replace `jq`/`curl`/`openssl`/`nc` entirely, so
there's nothing to bundle for Windows the way `jq` is bundled for
macOS/Linux.

Cursor runs every hook array entry unconditionally on every platform —
there is no per-entry platform filter (confirmed against Cursor's own
hooks documentation) — so `hooks/hooks.json` now lists a bash command and
a PowerShell command side by side for every event. Added
`scripts/run-powershell.cmd` to bridge the two: its first line is
deliberately both a valid Windows batch label and a valid POSIX no-op, so
when `/bin/sh` (not `cmd.exe`) ends up executing it on macOS/Linux, it
exits `0` silently instead of erroring on every single hook call.
Mirrored the same problem from the other direction: each `.sh` script now
detects a Windows POSIX-emulation layer (Git Bash/MSYS2/Cygwin) and exits
immediately with a neutral response, so a Windows machine that happens to
have `bash` on `PATH` doesn't run both implementations for the same
event.

The OAuth login flow (`login.ps1`) binds its callback listener to
`127.0.0.1` specifically, deliberately never a wildcard address —
binding to a specific loopback address doesn't require administrator
rights on Windows, while a wildcard bind does, and nothing in this flow
ever needs to accept a connection from anywhere but the local browser.

Updated `skills/paradigmnetworks-login/SKILL.md` and
`rules/pn-login-check.mdc` with Windows-equivalent shell snippets
alongside the existing bash ones.

Not yet run end-to-end against a real Windows machine or a live Cursor
session by the people maintaining this repo — reviewed carefully
(including a from-scratch audit for PowerShell's strict-mode property
access and function-return-value pitfalls, both of which caught real
bugs before this shipped) but unverified in practice.

## 2026-08-21 — Git repo context for the Paradigm Networks backend

Added `scripts/check-repo-context.sh` and `scripts/lib/git-utils.sh`,
ported from a separate plugin (`pn-repo-beacon`) and rebranded. Runs as a
second, independent entry on the `beforeSubmitPrompt` hook (alongside, not
merged into, `check-prompt.sh`) and writes a workspace-local
`.cursor/rules/paradigm-repo-context.mdc` (`alwaysApply: true`) containing
a sanitized `<GIT>url|branch</GIT>` tag per git repo found in the
workspace. Cursor folds always-apply rules into the system prompt of the
next real model request, which is what lets the Paradigm Networks
control-server backend parse the tag out (`GitContext.go`) and attribute a
request to a repo — this required zero changes on the control-server side,
since it already handles this exact tag format (including a fallback for
the malformed `<GIT>url|branch<GIT>` tag the original beacon plugin
produces; this port closes the tag correctly).

Deliberately independent of the security-scan hook: no changes to
`check-prompt.sh`/`check-write.sh` or their Paradigm Networks payloads.
The repo/branch tag reaches Paradigm Networks only because it becomes part
of the prompt content Cursor already sends — already covered by
`SECURITY.md`'s existing data-handling disclosure, so no new disclosure
was needed.

Two things ported as-is because they're load-bearing: sanitization
(strips credentials from remote URLs, strips control characters, caps
length) and a workspace-root safety check that refuses to write into
system directories. One deliberate improvement over the original: a
per-workspace cache (root mtime + each known repo's `.git/HEAD` mtime)
skips the full repo-tree walk and rewrite when nothing's changed, instead
of rescanning unconditionally on every prompt.

Added unit tests for `git-utils.sh` (credential stripping, control-char
stripping, length capping, repo discovery, symlink refusal, dedup) and an
integration test for `check-repo-context.sh` (rule file written with a
sanitized tag, `.gitignore` updated, fails open on bad input). Full suite:
87/87 passing.

## 2026-08-18 — "paradigm-scanner" reworded to "Paradigm Networks" in prose

README's title/intro, and the opening line of `SECURITY.md`,
`CONTRIBUTING.md`, this changelog, and `rules/pn-login-check.mdc`, said
"paradigm-scanner" where they meant the product, for naming consistency
with everything else already called Paradigm Networks. Left unchanged
everywhere the literal identifier is load-bearing: `plugin.json`'s `name`
field, the local-install symlink target and marketplace-add step in
README, the directory tree diagram, the `~/.paradigm-scanner/` log
directory paths, the login skill's `find` lookup for `login.sh`, and this
changelog's own historical entry documenting the rename to that literal
identifier.
## 2026-08-18 — Renamed pn-login skill to paradigmnetworks-login

`skills/pn-login/` → `skills/paradigmnetworks-login/`, and its frontmatter
`name` updated to match. Updated every place that told the agent to run
"the pn-login skill" (`README.md`, `rules/pn-login-check.mdc`,
`check-prompt.sh`, `check-session.sh`, `check-write.sh`) to the new name.
Left the `pn-login-check.mdc` rule's own filename unchanged — only the
skill's name was in scope.

## 2026-08-18 — Signup link in raw "not configured" hook messages

The signup URL was previously only reachable through the agent-mediated
onboarding path (README, the `pn-login-check` rule, the `pn-login` skill).
The raw hook messages a user sees directly when Paradigm Networks isn't
configured — `check-prompt.sh`'s "not configured" prompt message,
`check-write.sh`'s "not configured" write message, and
`check-session.sh`'s session context — didn't mention it, so a user who
never gets an agent-driven prompt (e.g. `sessionStart` racing/missing the
first message, per the known limitation this plugin already documents) had
no way to discover signup from the message alone. Added the signup line to
all three. Scoped deliberately to only the "not configured" case — the
separate timeout/unreachable/HTTP-error/invalid-response messages in both
scripts are unrelated and untouched.

## 2026-08-18 — Real signup URL

The signup link shown to a not-yet-registered user (README, the
`pn-login-check` rule, the `pn-login` skill) was a placeholder,
`https://signup.paradigmnetworks.ai/signup`. Replaced with the real one:
`https://signup.claude-demo.paradigmnetworks.ai/signup`.

## 2026-08-18 — Removed unused urlencode() from common.sh

`scripts/lib/common.sh` had a dead `urlencode()` function: unreferenced
anywhere in the codebase, depended on `python3` with a broken space-only
`sed` fallback. The real OAuth flow has always used its own
`urlencode_strict()` in `scripts/login.sh`, a proper self-contained
percent-encoder. Flagged in review; removed.

## 2026-08-17 — Square logo

Replaced `assets/logo.svg` (128×111, non-square) with `assets/logo.png`
(192×192, square) — the marketplace listing image slot expects a square
asset. `plugin.json`'s `logo` field updated accordingly. Also dropped two
redundant standalone `"Paradigm"` entries from `plugin.json`'s
keywords/tags (already covered by `"Paradigm Networks"`) and fixed a
leftover `[Paradigm]` message tag in `check-prompt.sh` to say
`[Paradigm Networks]`.

## 2026-08-17 — Removed dead multipart.sh test references

`scripts/lib/multipart.sh` was deleted at some point in the bash conversion,
but `test-utils.sh` still tried to source it, and 5 tests across
`test-unit.sh`/`test-errors.sh` still called functions
(`multipart_boundary`, `multipart_content_type`, `build_multipart_body`)
that no longer exist anywhere in the codebase — failing on every run since
the file was removed. Removed the source line and all 5 dead tests. The full
suite now runs cleanly end to end: 69/69 passing (was reporting 2 failed
suites before). Also corrected the hardcoded test-count summary in
`run-all-tests.sh`, which had gone stale independently of this cleanup.

## 2026-08-17 — Renamed PN/CodeDefense branding to Paradigm Networks

Every user- and agent-facing mention of "PN"/"pn" and "CodeDefense" is now
"Paradigm Networks," including the plugin's marketplace-configurable
variables:

- `PN_BASE_URL` → `PARADIGM_NETWORKS_URL`
- `PN_TOKEN` → `PARADIGM_NETWORKS_TOKEN`
- `PN_FAILURE_MODE` → `PARADIGM_NETWORKS_FAILURE_MODE`
- `PN_PROMPT_FAILURE_MODE` → `PARADIGM_NETWORKS_PROMPT_FAILURE_MODE`

Deliberately left unchanged: the real API endpoint paths
(`/api/v1/codedefense/scan`, `/api/v1/plugin/authorize`,
`/api/v1/plugin/token` — these are routes on the actual backend, not just
naming), the `~/.pn/credentials.json` credentials directory (avoids forcing
every existing login to re-authenticate), the legacy `SNANTIZER_*`
shared-host variables, and every internal file/directory/function name
(`pn_config.sh`, `skills/pn-login/`, `rules/pn-login-check.mdc`,
`pn_resolve_config`, etc.).

## 2026-08-17 — Added minClientVersions

`plugin.json` now declares `"minClientVersions": {"cursor": "2.5.0"}` —
2.5.0 is when Cursor's Plugin packaging system itself (the thing this
project depends on to exist as an installable plugin at all) shipped,
confirmed against Cursor's own changelog. Also confirmed `logo` and
`assets/logo.svg` are wired in with a real brand asset.

## 2026-08-17 — Renamed to paradigm-scanner

The plugin's `name` field (`.cursor-plugin/plugin.json`) changed from
`pn-sanitizer` to `paradigm-scanner` — `displayName` had already been set to
"Paradigm Networks," but `name` is the internal identifier Cursor uses for
install paths and marketplace URLs, and it must be lowercase kebab-case
(confirmed against Cursor's own official plugins, e.g. `google-drive`).
Updated everywhere this was hardcoded: the `pn-login` skill's `find` lookup
for `login.sh`, the local-install symlink example, and the local log/audit
directory (`~/.pn-sanitizer/` → `~/.paradigm-scanner/`) along with the tests
that check for it. The GitHub repository URL itself (`homepage`/
`repository` in `plugin.json`) is intentionally left unchanged pending a
separate decision on whether to rename the repo too.

## 2026-08-17 — Data handling disclosure

Added a "Data handling" section to `SECURITY.md` documenting what this
plugin actually does with prompt/file-write content: sent over HTTPS,
stored indefinitely per-tenant in the tenant's own CodeDefense database,
already covered under Paradigm Networks' main product customer agreement
(no separate disclosure needed for this plugin specifically). Linked to it
from the top of the README. Closes the data-handling review item from the
marketplace-readiness list.

## 2026-08-16 — Honor an admin-configured PN_BASE_URL during onboarding

`rules/pn-login-check.mdc` and `skills/pn-login/SKILL.md` previously only
recognized two states — fully logged in, or not configured at all — so an
admin who pre-configured `PN_BASE_URL` via the plugin's marketplace variable
still had every teammate asked for that same URL again on their first
message. Added a third state, `NOT_CONFIGURED_URL_KNOWN`: when only
`PN_BASE_URL` is set, the agent skips asking entirely and logs the user in
directly with that value. An explicit request from the user to log into a
different org still always takes priority over the pre-configured value.

## 2026-08-16 — Removed unused variable probe

Removed `scripts/probe-variables.sh` and its `sessionStart` entry in
`hooks/hooks.json`. It was pure diagnostic instrumentation (logged
`$CURSOR_PLUGIN_ROOT`/`$CURSOR_PROJECT_DIR` and other env vars to a local
temp file to check an assumption about what Cursor passes to hook scripts)
— it always returned a no-op `{}` and nothing else in the codebase
referenced it. The open question it was meant to answer remains open; the
login skill's own `find`-based fallback for locating `login.sh` never
depended on it.

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
