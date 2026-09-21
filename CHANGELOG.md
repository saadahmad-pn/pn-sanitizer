# Changelog

All notable changes to Paradigm Networks (formerly pn-sanitizer) are recorded
here. This project hasn't had a public release yet — entries below are dated
by when the work happened, not by version tag.

## 2026-09-21 — Stop minting a separate SessionId for Code Chain recording

`lib/codechain-client.sh`/`.ps1` no longer register-and-cache a
server-minted `SessionId` before recording turns/shell-events. The control-
server side dropped its `plugin_codechain_sessions` collection (which
existed only to mint an id and look up `Platform`/`Cwd`/`GitRepoUrl`/
`GitBranch` on every write) in favor of using Cursor's own
`conversation_id` directly as the SessionId — the same pattern every other
vendor here already used (Claude Code's `X-Claude-Code-Session-Id` header,
Cursor gateway mode's `cursorConversationId`). There was nothing left for a
dedicated session collection, or a client-side local cache mapping
conversation id → minted id, to do.

What changed:
- `pn_get_codechain_session_id`/`Get-CodechainSessionId` (the mint-or-reuse
  call, backed by a `~/.paradigm-scanner/codechain-sessions/*.txt` file
  cache) is gone, along with `sanitize_client_session_id`/
  `_codechain_cache_*`/`Get-SanitizedClientSessionId`/`Get-CodechainCache*`.
- New `pn_register_codechain_session`/`Register-CodechainSession` records a
  session-start marker directly against the client's own session id — it
  is independent of every other call below, not a prerequisite for them.
- `pn_record_codechain_turn`/`Send-CodechainTurn` and
  `pn_record_codechain_shell_event`/`Send-CodechainShellEvent` now take
  `Cwd`/`GitRepoUrl`/`GitBranch` directly as parameters (previously looked
  up server-side from the registered session) — the callers already
  compute these locally on every hook invocation, so nothing new had to be
  threaded through.
- `pn_close_codechain_session`/`Close-CodechainSession` posts to the given
  session id directly; no more cache lookup to find what to close.
- `check-session.sh`/`.ps1`, `check-turn-complete.sh`/`.ps1`,
  `check-git-event-record.sh`/`.ps1` updated to call these directly instead
  of a lookup-then-record two-step. `check-session-end.sh`/`.ps1` barely
  changed (it already passed the client's own session id through).

Verified: `bash test/run-all-tests.sh` — 198/199 passing (Code Chain
Recording Tests 22/22; the one failure, `check-repo-context.sh`'s
sanitized-GIT-tag assertion, reproduces identically without this change —
confirmed unrelated, pre-existing). `test/test-codechain-client.sh`
rewritten to match (no more cache-hit/miss cases — there is no cache left).
`shellcheck -S warning -x scripts/*.sh scripts/lib/*.sh` reports only the
same pre-existing SC2034 pattern already established for this codebase's
global-return convention, none of it in `codechain-client.sh`.

Also updated `design-ideas/Codechain_Plugin_Hooks_Design.md`'s `POST
/sessions` section to match — it previously documented a server-minted
`SessionId` returned from a `ClientSessionId` idempotency key.

## 2026-09-21 — Move prompt/write scanning off /v1/messages onto POST /api/v1/codedefense/scan

`check-prompt.sh`/`check-write.sh` (+ `.ps1` twins) no longer call
`/v1/messages` at all. That route required invoking a real, billed model
completion just to get a scan verdict — every scanned prompt was answered
twice (once for real by Cursor, once more by the Paradigm-configured model
purely to produce something to classify), and the reverse-engineered
verdict heuristic (`pn_parse_messages_response`, "zero usage + a
`REQUEST BLOCKED` banner") was an admitted stopgap with no real structured
field behind it. They now call the existing `POST /api/v1/codedefense/scan`
(via new `lib/scan-client.sh`/`.ps1`) — no model invocation, and a real
`action_to_take: allow|warn|block` field instead of a heuristic.

**Interim step, not the final design**: this calls Code Defense Service
only. The full `/v1/messages` pipeline also ran PromptGuard (jailbreak) and
PolicyEngine (DLP/PII) — those are *not* replicated by this change yet.
A composite backend endpoint that triggers PromptGuard + PolicyEngine + CDS
together, based on the org's policy configuration, is the planned follow-up
(PN-11847) — deliberately scoped to reuse the one endpoint that already
exists today rather than the plugin calling three separate policy
endpoints itself.

What changed:
- New `lib/scan-client.sh`/`.ps1` (`pn_scan_text`/`Invoke-PnScanText`):
  posts `text` as multipart form data, returns a real `Status`/`Action`
  pair instead of a parsed heuristic.
- `check-prompt.sh`/`check-write.sh` (+ `.ps1`) rewritten to call it.
  FAILURE_MODE/PROMPT_FAILURE_MODE semantics, audit logging, the
  anomaly-streak staleness tracking, and all user-facing message branding
  are unchanged — only the transport and verdict source changed. Dropped
  the `/v1/messages`-specific HTTP-403 "complete your setup" special case
  (tied to that route's own error behavior, not confirmed to apply to the
  new endpoint) and the `MODEL`/`MAX_TOKENS` request parameters (CDS
  resolves the org's configured scanning model server-side; the caller
  doesn't choose one).
- Removed the now-fully-dead `pn_parse_messages_response`/
  `pn_strip_block_banner` (`lib/common.sh`) and their PowerShell mirrors
  (`ConvertFrom-PnMessagesResponse`/`ConvertTo-PnStrippedBlockBanner`,
  `Invoke-MessagesHttpPost`), plus their ~14 dedicated unit tests — these
  had no other callers once check-prompt/check-write stopped using them.
- `PARADIGM_NETWORKS_SCAN_URL_OVERRIDE` is gone — there was no equivalent
  override wired for the new endpoint; nothing else referenced it.

**Discovered, not fixed by this change**: `pn_resolve_model`/
`Resolve-PnModel` and the two skills built on it
(`paradigmnetworks-models`/`set-model`) are now orphaned — nothing consumes
the saved "preferred model" for scanning anymore, since CDS takes no model
parameter from the caller. Left in place pending a decision on whether to
remove them.

Verified: `bash test/run-all-tests.sh` — 197/198 passing (the one failure,
`check-repo-context.sh`'s sanitized-GIT-tag assertion, reproduces
identically on a version of this branch without this change — confirmed
unrelated). New `test/test-scan-client.sh` (14 tests) covers `pn_scan_text`
directly (allow/warn/block/anomaly/timeout/unreachable/http-error/
invalid-json, and URL construction). `shellcheck -S warning -x scripts/*.sh
scripts/lib/*.sh` reports only the same pre-existing SC2034 pattern already
established for this codebase's global-return convention — the new
`PN_SCAN_*` globals follow it, not a new problem.

## 2026-09-21 — Record Code Chain sessions/turns/commits from Cursor Hooks (PN-11880)

Adds a second, independent concern alongside the existing gating pipeline
(`/api/v1/detections/evaluate`): recording plugin-mode activity into Code
Chain, control-server's session/commit/PR traceability system. Until now,
plugin-mode Cursor sessions produced zero Code Chain visibility — confirmed
directly during this design work: `lib/detection-client.sh` always sends an
empty `SessionId`, and control-server's `committranscripts.ProcessPersistedRequest`
bails on an empty `SessionId` before any detection runs, regardless of scan
outcome. See `design-ideas/Codechain_Plugin_Hooks_Design.md` for the full
design and control-server's matching `PN-11880` branch.

Four new hook wirings in `hooks/hooks.json`, each calling a new shared
client, `lib/codechain-client.sh`/`.ps1`:

- `sessionStart` (extended `check-session.sh`/`.ps1`): best-effort registers
  a Code Chain session against control-server's new
  `POST /api/v1/plugin/codechain/sessions`, keyed on Cursor's own
  `conversation_id`. Backgrounded (a PowerShell `Start-Job`, a bash `&`) so
  it never delays the existing login-check message, this hook's real job.
- `sessionEnd` (new `check-session-end.sh`/`.ps1`, a hook event this plugin
  did not previously use at all): finalizes the session via
  `POST .../sessions/{id}/close`.
- `afterShellExecution` (new `check-git-event-record.sh`/`.ps1`, three new
  matchers mirroring the existing `beforeShellExecution` ones): records the
  git push/commit/`gh pr create` command's OUTPUT once it has actually run.
  Deliberately NOT added to `check-git-event.sh` itself — that hook fires
  BEFORE execution and only ever sees the command text, never the commit
  SHA/push confirmation/PR URL control-server's detection regex needs, so
  recording needed its own `afterShellExecution` hook rather than piggy-
  backing on the existing gate.
- `stop` (new `check-turn-complete.sh`/`.ps1`, another previously-unused
  hook event): records the completed turn (prompt + response) via
  `POST .../sessions/{id}/turns`. Reads Cursor's own `transcript.jsonl`
  through a new role-separating extractor, `get_current_turn_messages`/
  `Get-CurrentTurnMessages` (`lib/common.sh`/`.ps1`) — a sibling to the
  existing `get_current_turn_text`, which blends prompt and response into
  one string; Code Chain's turn payload needs them kept separate.

Session identity is cached locally per `conversation_id`
(`~/.paradigm-scanner/codechain-sessions/`, atomic writes) so only the
first hook of a session pays the registration round-trip — every later
hook call for the same conversation reads the cached, server-minted
`SessionId`. Registration is itself idempotent server-side, so a cache miss
racing a concurrent hook call is harmless.

Every function in `lib/codechain-client.sh`/`.ps1` is unconditionally
best-effort: a registration/recording failure is logged
(`~/.paradigm-scanner/codechain-client.log`) and swallowed, never surfaced
in a hook's returned JSON or exit code — this is a genuinely different
contract from the existing gating hooks (`check-prompt.sh`, `check-write.sh`,
`check-git-event.sh`), which must return a real allow/deny verdict. Recording
and gating are deliberately kept as separate calls from
`check-git-event-record.sh`/`check-git-event.sh` rather than merged into one,
so a recording failure can never affect a gating decision and vice versa.

Verified: `bash test/run-all-tests.sh` — 183/184 passing (the one failure,
`check-repo-context.sh`'s sanitized-GIT-tag assertion, reproduces identically
on the unmodified baseline via `git stash`, confirmed unrelated to this
change). `shellcheck -S warning -x scripts/*.sh scripts/lib/*.sh` reports the
same pre-existing SC2034 warning pattern already present on the baseline for
this codebase's established global-return convention (`PN_MSG_ACTION`,
`HTTP_POST_BODY`, etc.) — the three new globals this change adds
(`PN_CODECHAIN_SESSION_ID`, `PN_TURN_PROMPT`, `PN_TURN_RESPONSE`) follow the
same, already-tolerated pattern, not a new regression. PowerShell side
written to mirror the bash implementation function-for-function but not yet
run under a live Windows target or Pester — flagged as a follow-up
verification step, consistent with this repo's existing, thinner Pester
coverage (see `CLAUDE.md`).

## 2026-09-17 — Added git push/commit/PR-create governance via a new `beforeShellExecution` hook

Adds `scripts/check-git-event.sh`/`.ps1`, wired into three new
`beforeShellExecution` matchers in `hooks/hooks.json` (`git push`, `git
commit`, `gh pr create`). Unlike the existing prompt/write hooks, this calls
a new backend endpoint, `POST /api/v1/detections/evaluate` (control-server),
a generic command/event detection contract designed to be extensible to a
future non-git command source without a contract change (see
`design-ideas/Cursor_PrePush_Governance_Enforcement_Plan.md`, section 0.5,
for the full design). One script is parameterized by `EventType`
(`git.push`/`git.commit`/`git.pr_create`) rather than three near-duplicate
scripts, since only the file-collection step differs per event:

- `git.push`/`git.pr_create` diff against, respectively, "everything not
  reachable from any remote branch" and "the PR's base branch" -- these are
  genuinely different comparisons, not interchangeable: a branch already
  pushed before `gh pr create` runs (the common flow) has every commit
  already on a remote branch, so the push-style "not on any remote"
  comparison finds nothing to scan at exactly the moment a PR is about to
  open. Confirmed directly with a real push-then-create-PR scenario before
  landing on the base-branch-diff approach for PR creation.
- `git.commit` scans the git index (staged changes), since
  `beforeShellExecution` fires before the commit exists to diff against.
- Binary files are filtered out before submission (`is_binary_file` in the
  new `lib/detection-client.sh`) -- an LLM-based scanner has no meaningful
  use for one. The first implementation of this check compared a
  `head -c`-captured sample against a NUL-stripped copy of itself as bash
  string variables; caught by the new unit test suite before it shipped,
  since bash strings are NUL-terminated C strings internally and command
  substitution silently truncates at the first NUL -- both copies came out
  identically truncated and the check never actually detected a NUL.
  Rewritten to use `grep -I` (present in both BSD and GNU grep), which
  operates on the file directly rather than routing bytes through a shell
  variable.
- A file-count/total-size guardrail (`PARADIGM_NETWORKS_GIT_EVENT_MAX_FILES`/
  `_MAX_BYTES`, default 60 files / 8 MB) caps the fan-out submitted for one
  push/commit/PR, since no measured latency benchmark exists yet for how
  many parallel scanner calls one submission can trigger -- see the design
  doc's section 9. Content sent is each file's current working-tree state,
  not an exact historical/staged blob -- a deliberate simplification (the
  two coincide in the common case, and the alternative adds real complexity
  for a race that exists regardless of which content source is picked).
- Defaults fail-**closed** (`PARADIGM_NETWORKS_FAILURE_MODE=block`), matching
  `check-write.sh`'s posture, not `check-prompt.sh`'s fail-open default: a
  push/commit/PR reaching its destination unscanned is a comparable risk to
  an unscanned file write.
- `GitRepoUrl`/`GitBranch` sent with each request reuse the existing
  `sanitize_git_value` (credential-stripping) treatment from
  `lib/git-utils.sh`; two new `_or_empty` variants were added there since the
  existing `get_remote_url`/`get_current_branch` intentionally return
  human-readable placeholder text ("No remote"/"detached") for a different
  caller (`check-repo-context.sh`)'s context injection, which the API
  contract's "empty means not applicable" requirement does not want.
- `scripts/run-hook.cmd`'s `/bin/sh` line was fixed to forward extra
  arguments (`shift; exec bash "$d/$n.sh" "$@"`, previously just
  `exec bash "$d/$1.sh"` with no forwarding at all) -- needed so
  `run-hook.cmd check-git-event git.push` actually delivers the event-type
  argument through on macOS/Linux; the Windows batch side already forwarded
  `%2..%9` and needed no change.
- Verified: 34 new tests in `test/test-git-event.sh` (git-utils resolvers
  against real throwaway git repos, `pn_evaluate_detection`'s HTTP-status/
  response-shape classification via a narrow test-only override of
  `http_post_multipart_form`, and `check-git-event.sh`'s allow/deny paths),
  wired into `test/run-all-tests.sh`. `test/mock-server.sh` gained
  `detections_allow`/`detections_warn`/`detections_block` response modes
  for the new endpoint's response shape, alongside its existing
  `/v1/messages`-shaped modes.

## 2026-09-14 — Two real bugs found testing on an actual Windows dev-account machine

- **`.ps1` files with a literal non-ASCII character (emoji, em dash) failed
  to parse on real Windows PowerShell 5.1** with cascading, misleading
  errors ("string is missing the terminator", "missing closing brace") on
  lines far from the actual offending character. Root cause: none of
  `scripts/check-prompt.ps1`, `scripts/check-write.ps1`,
  `scripts/check-session.ps1`, or `scripts/paradigmnetworks-models.ps1`
  have a byte-order mark, and Windows PowerShell 5.1 (unlike PS7+ or bash)
  doesn't reliably assume UTF-8 for a BOM-less script file -- it fell back
  to the system codepage and misread the multi-byte UTF-8 bytes, which
  threw off token boundaries for the rest of the file. Fixed by building
  each character via `[char]`/`ConvertFromUtf32` escapes instead of a
  literal, so the `.ps1` source itself is pure ASCII and immune to this
  regardless of what encoding any future edit saves the file with -- the
  visible output to the user is unchanged (verified byte-for-byte
  identical). This would have hit any Windows PowerShell 5.1 user running
  these scripts, not just a restricted dev account.
- **The Windows invocation lines in the `paradigmnetworks-login`,
  `paradigmnetworks-logout`, and `paradigmnetworks-models` skills were
  cmd.exe syntax, run in a PowerShell-native context.** `"%SystemRoot%\...\powershell.exe" -NoProfile ...`
  is valid for `cmd.exe` (which is what the now-deleted
  `run-powershell.cmd` shim always guaranteed), but PowerShell parses a
  bare quoted string at the start of a line as a string expression, not a
  command to invoke -- it needs the call operator (`& "path" -args`).
  `%SystemRoot%` is also cmd.exe/batch syntax that PowerShell doesn't
  expand; the PowerShell equivalent is `$env:SystemRoot`. Fixed all three
  skill files to `& "$env:SystemRoot\...\powershell.exe" ...`.

## 2026-09-13 — Scan-call timeout and hooks.json ceiling raised back to 240s/250s

The 2026-09-12 entry below lowered `PARADIGM_NETWORKS_TIMEOUT` to 25s and
the `hooks.json` timeout for `beforeSubmitPrompt`/`preToolUse` to 30s,
specifically because `failClosed: true` had just been turned on for those
two hooks -- a long timeout there means a slow/dead backend freezes the
IDE before denying, so failing fast seemed like the safer default.

Reverted back to 240s/250s, deliberately keeping `failClosed: true` as-is.
This explicitly accepts the tradeoff the previous entry was trying to
avoid: a genuinely slow or unreachable backend can now freeze prompt
submission or a Write for up to ~4 minutes before it finally denies,
in exchange for enough headroom that real (slow-but-legitimate) scan
latency doesn't get mistaken for a dead backend and start denying
prompts/writes that would have succeeded. `PARADIGM_NETWORKS_TIMEOUT` is
still env-overridable per-machine if a shorter fail-fast window is wanted
on a specific box; `hooks.json`'s own ceiling is a static value and would
need a direct edit to shorten again.

## 2026-09-12 — Windows non-admin fixes: TcpListener login, single hook dispatcher, fail-closed gate, lowered timeouts again

Four fixes needed to make the plugin usable on a Windows account without
admin rights:

- **Login (`login.ps1`)**: `Start-CallbackListener` now binds a raw
  `System.Net.Sockets.TcpListener` on `127.0.0.1` instead of
  `System.Net.HttpListener`. `HttpListener` registers through HTTP.SYS and
  needs a `netsh http add urlacl` reservation a standard user can't grant
  themselves, so login was completely broken on any non-admin account. A
  plain socket bind needs no such reservation. `Wait-ForCallback` now
  hand-rolls the minimal HTTP parsing this requires (previously provided by
  `HttpListener`), decoding `code`/`state`/`error` with
  `System.Net.WebUtility.UrlDecode` to match `login.sh`'s `+`-as-space
  `urldecode_strict` semantics.
- **Port-scan retry**: the old loop caught every exception from
  `.Start()` and just moved on, scanning 8000-64999 -- on an account
  where the bind fails for every port, that meant ~57,000 useless
  iterations before a misleading "no free port" message. Now only retries
  on `SocketException` with `SocketErrorCode -eq AddressAlreadyInUse`;
  anything else rethrows immediately. Range capped at 8000-8099.
- **Hooks (`hooks/hooks.json`)**: replaced the bash+PowerShell entry pair
  on every event with a single entry per event pointing at a new polyglot
  dispatcher, `scripts/run-hook.cmd` (deletes `scripts/run-powershell.cmd`).
  The old setup had two confirmed defects on Windows: `run-powershell.cmd`'s
  `-File %*` was unquoted, breaking any install path with a space (hits the
  login skill directly); and on a Windows box with no Git Bash, the bash
  entries failed to spawn on every single event. `run-hook.cmd` is a
  polyglot file -- its first line is a no-op label to `cmd.exe` and a real
  `exec bash ".../$1.sh"` to `/bin/sh` -- so one command now works
  correctly on both platforms.
- **Fail-closed gate**: `beforeSubmitPrompt` (`check-prompt`) and
  `preToolUse` (`check-write`) now set `failClosed: true`. This wasn't
  safe before today's hooks.json change -- with two entries per event, the
  entry that failed to spawn on the wrong platform would have blocked
  everything. With exactly one entry per event that genuinely runs, a
  broken dispatcher now correctly blocks instead of Cursor silently
  failing open.
- **Timeouts lowered again**: the 2026-09-01 entry below raised
  `PARADIGM_NETWORKS_TIMEOUT` to 240s and the `hooks.json` per-hook
  timeout to 250s, deliberately, for latency headroom. That's no longer
  safe now that `check-prompt`/`check-write` fail closed: a 250s ceiling
  means a slow or unreachable backend now freezes the IDE for over four
  minutes before denying, instead of failing fast. Both come back down:
  `PARADIGM_NETWORKS_TIMEOUT` 240s → **25s**, `hooks.json` timeout for
  `beforeSubmitPrompt`/`preToolUse` 250s → **30s**. `check-session` and
  `check-repo-context` are untouched (10s, `failClosed: false`, neither
  gates anything).
- **Scan-staleness warning**: `~/.paradigm-scanner/anomaly_state.json`
  gained a `last_successful_scan` epoch field, written on every
  allow/block verdict (repurposing the existing
  `pn_reset_scan_anomaly`/`Reset-PnScanAnomaly` call sites, renamed to
  `pn_record_successful_scan`/`Set-PnLastSuccessfulScan`). `check-session`
  now warns via `additional_context` when that timestamp is absent or
  over an hour old while credentials exist -- covering the case
  `failClosed` can't: the hook runs fine, but the backend has been
  degraded for a while.

## 2026-09-01 — Raised default timeouts across the board

Real-world testing showed the previous defaults left too little margin,
especially for the scan call, which had already been flagged as prone
to real backend latency variance (see the 2026-08-31 latency/cost
entry above). Raised, both platforms now unified on the same value:

- Scan call (`check-prompt`/`check-write`, `PARADIGM_NETWORKS_TIMEOUT`):
  20s (mac/Linux) / 40s (Windows) → **240s** both. Also raised
  `hooks/hooks.json`'s own per-hook `timeout` for `beforeSubmitPrompt`
  and `preToolUse` (Write) from 25s/45s to **250s** -- Cursor enforces
  that as a hard ceiling independent of the script's own HTTP timeout,
  so leaving it at 25s/45s would have silently capped this change and
  made it a no-op.
- Token refresh (`pn_config`, silent, on the critical path of every
  scan once a token is close to expiring): 10s / 40s → **60s** both.
- Login (`login.sh`/`.ps1`): browser click-through wait and token
  exchange, previously 60s/15s (mac/Linux) and 60s/40s (Windows) →
  **120s** both, for both. Updated the `paradigmnetworks-login` skill's
  hardcoded "60 seconds" / "one-minute window" wording to match.
- Model list fetch (`paradigmnetworks-models`): 20s / 40s → **60s** both.

Verified beyond syntax: traced the new 240s scan-call timeout through
both check-prompt.sh's and check-prompt.ps1's own debug logs
(`Timeout: 240s` / `timeout=240s`) against a real invocation. Full
suite (100%) and Pester suite (16/16) still pass.

## 2026-08-31 — Dropped the legacy SNANTIZER_* env var names entirely

`SNANTIZER_*` was a misspelling of "sanitizer" left over from before this
project's `PARADIGM_NETWORKS_*` rename (2026-08-17, below). With no
tagged release and no installed base to be compatible with, every day it
stayed made it more likely to become permanent public API surface with a
typo in it. Removed the fallback entirely everywhere it appeared:

- `PARADIGM_NETWORKS_URL`/`PARADIGM_NETWORKS_TOKEN`,
  `PARADIGM_NETWORKS_FAILURE_MODE`,
  `PARADIGM_NETWORKS_PROMPT_FAILURE_MODE` no longer fall back to their
  `SNANTIZER_*` equivalents (`pn_config.sh`/`.ps1`, `check-prompt.sh/.ps1`,
  `check-write.sh/.ps1`).
- Three advanced/test-only override knobs that never had a
  `PARADIGM_NETWORKS_*` equivalent in the first place — `SNANTIZER_SCAN_URL`,
  `SNANTIZER_TIMEOUT`, `SNANTIZER_TRANSCRIPT_LINES` — were renamed rather
  than deleted, since the functionality itself (pointing at a different
  scan URL, overriding the timeout, capping transcript read length) is
  still real and used by this project's own test suite:
  `PARADIGM_NETWORKS_SCAN_URL_OVERRIDE`, `PARADIGM_NETWORKS_TIMEOUT`,
  `PARADIGM_NETWORKS_TRANSCRIPT_LINES`.
- `rules/pn-login-check.mdc` and `skills/paradigmnetworks-login/SKILL.md`'s
  onboarding checks no longer treat a `SNANTIZER_BASE_URL`/`SNANTIZER_TOKEN`
  pair as evidence of being configured.

Also removed two stale `TEMPORARY diagnostic`/`Remove once that's
settled` blocks from `check-prompt.ps1` left over from investigating
whether Cursor delivers plugin Settings variables to hook subprocesses —
that question was already settled (it doesn't; see
`skills/paradigmnetworks-models/SKILL.md`'s "What not to do") and the
diagnostic code was never cleaned up afterward.

Confirmed via the user directly that nothing depends on the old names
before removing them, per this repo's own remediation-brief instruction
not to assume that.

## 2026-08-31 — Recorded the per-scan latency/cost tradeoff as a known decision

Not a code change. Every prompt and every file write triggers a real,
billed `/v1/messages` completion whose actual reply is discarded on the
allow path (only the verdict, reverse-engineered from the response
shape, matters — see `pn_parse_messages_response`'s comment). Each call
carries up to a 20s timeout by default (`PARADIGM_NETWORKS_TIMEOUT`), and the
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
