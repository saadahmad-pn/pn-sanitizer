# Local Build, Packaging & Cursor Install Guide

This is a consolidated, task-oriented walkthrough for getting a working copy
of this repo's changes running inside a real Cursor session. It cross-references
and summarizes `README.md` and `CONTRIBUTING.md` rather than replacing them —
see those files for the canonical, user-facing install steps and contribution
conventions.

## What this project actually is

There is **no compiled build artifact**. This repo *is* the plugin: a Cursor
Plugin Marketplace (`.cursor-plugin/marketplace.json` + `.cursor-plugin/plugin.json`)
wrapping a single plugin (`paradigm-scanner`) whose entire implementation is
a set of plain Bash scripts (macOS/Linux) with hand-mirrored PowerShell
twins (Windows), wired to Cursor's hook events via `hooks/hooks.json`. There
is no compile, transpile, bundle, or package-manager install step for the
plugin itself — "packaging" is just committing the script changes.

## Prerequisites

From `CONTRIBUTING.md` and `test/run-all-tests.sh`'s dependency check:

| Tool | Required? | Notes |
|---|---|---|
| `bash` | Yes (macOS/Linux) | Scripts are plain Bash, no special version needed |
| `curl` | Yes (macOS/Linux) | All backend HTTP calls |
| `openssl` | Yes (macOS/Linux) | PKCE login flow (code verifier/challenge) |
| `nc` (netcat) | Yes (macOS/Linux) | Local OAuth callback listener during login |
| `jq` | Preferred, not required | Falls back to a bundled static binary in `scripts/bin/` for macOS/Linux, amd64/arm64 — see `scripts/bin/PROVENANCE.md`. No bundled Windows binary. |
| `python3` | Optional | `login.sh`'s URL encode/decode falls back to a pure-Bash implementation if absent |
| PowerShell 5.1+ | Yes (Windows) | The Windows scripts target the version that ships by default on every Windows machine (not PowerShell 7-only syntax); no extra installs needed — `ConvertTo-Json`/`ConvertFrom-Json`, `Invoke-RestMethod`, `System.Security.Cryptography`, and raw `System.Net.Sockets.TcpListener` replace jq/curl/openssl/nc |
| Cursor | Yes | Team/Enterprise plan **only** needed for the marketplace-import install path below; not needed for local-plugin testing |

Optional, for running the full contributor-facing check suite locally:
- `shellcheck` — lints `scripts/*.sh` and `scripts/lib/*.sh`
- PowerShell + the `PSScriptAnalyzer` and `Pester` modules — lint/test the `.ps1` side

## Running the test suite

```bash
bash test/run-all-tests.sh
```

This is the single entry point (per `CONTRIBUTING.md`) and runs, in order:
1. **Unit tests** (`test/test-unit.sh`) — `lib/common.sh`, `lib/git-utils.sh`, `pn_config.sh` functions in isolation.
2. **Integration tests** (`test/test-hooks.sh`) — the hook scripts end-to-end against `test/mock-server.sh`, a fake Paradigm Networks backend that can simulate `allow`/`block`/`anomaly`/`timeout`/`error500`/`error401` responses.
3. **Error-scenario tests** (`test/test-errors.sh`) — malformed input, missing files, etc.
4. **Dependency check** — verifies `bash`, `curl`, `jq`, `openssl`, `nc` are all present on the machine running the suite.

It prints a consolidated pass/fail summary and writes per-suite logs to `/tmp/{unit,integration,error}-test.log`.

For the Windows side, there's no single local entry point script — mirror what CI does:
```powershell
Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser
Get-ChildItem -Path ./scripts -Filter *.ps1 -Recurse | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Severity Warning,Error }

Install-Module -Name Pester -Force -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester -Path test/pester -Output Detailed
```

Note: `test/pester/` currently only covers `ConvertFrom-PnMessagesResponse` and `PnConfig` — much narrower than the four bash test files. Don't assume Pester passing means the same coverage as the bash suite.

CI (`.github/workflows/ci.yml`) runs shellcheck, the bash test suite (against both a system-`jq` and a bundled-binary-`jq` matrix leg), PSScriptAnalyzer, Pester, JSON validity checks on the three JSON config files, and a SHA-256 provenance check of the bundled `jq` binaries — but **it currently only runs manually** (`workflow_dispatch`), not on push/PR, while the project is in active development (see the comment at the top of `ci.yml`). Running these locally before opening a PR is the only way they actually gate anything right now.

## Installing into Cursor for local testing

Cursor supports two distinct install paths, and only one of them is useful for testing local, uncommitted changes.

### Path A — Marketplace import (production-like, requires a push to GitHub)

This is what `README.md` documents and is how real users/orgs install the shipped plugin. It always pulls from the GitHub repo's default branch, so it **cannot** be used to test local changes without pushing them first:

1. Cursor Dashboard → **Customize** → **Browse Marketplaces** → **Add Marketplace** → **Import from GitHub**.
2. Enter `https://github.com/saadahmad-pn/pn-sanitizer`.
3. **Add to Marketplace**, then set **Marketplace Access** and turn the plugin **Default On** or **Required**.

Requires a Cursor Team/Enterprise plan and dashboard admin access.

### Path B — Local plugin install (for testing uncommitted changes)

This repo's own skill docs (`skills/*/SKILL.md`) reference `~/.cursor/plugins/local/` directly as a real, supported install location, alongside the marketplace's own cache at `~/.cursor/plugins/cache/` — confirming Cursor supports loading a plugin straight from a local directory without going through GitHub at all. To test a working copy of this repo:

1. Make your changes in this cloned working copy.
2. Symlink (preferred, so edits take effect immediately) or copy this directory into Cursor's local plugin directory:
   ```bash
   mkdir -p ~/.cursor/plugins/local
   ln -s "$(pwd)" ~/.cursor/plugins/local/paradigm-scanner
   ```
3. Restart Cursor (or use its "reload window"/extension-host-restart command if available) so it picks up the new local plugin. Cursor's own plugin-loading UI and exact refresh behavior aren't documented in this repo — if hooks don't seem to fire after a restart, check **Cursor Settings → Hooks** and the **Hooks output channel**, per the Limitations section of `README.md`, to confirm the plugin was actually detected and its hooks registered.
4. Confirm both install-path variants aren't active at once for the same plugin name (`paradigm-scanner`) — a stale marketplace import can otherwise coexist with a local install and cause confusing double-firing or the wrong version running.

### Verifying it's working

Follow the "Try it" section of `README.md`:
1. Log in (see `skills/paradigmnetworks-login/SKILL.md`, or run `bash scripts/login.sh --base-url <your-org-url>` directly).
2. Submit a prompt or file edit your org's policy should block — it should be denied with an explanation.
3. Submit something that should be allowed — it should proceed normally.
4. Debug logs land under `~/.paradigm-scanner/` (`check-prompt.log`, `check-write.log`, `audit.jsonl`) if something isn't behaving as expected — check these before assuming a hook silently failed.

## "Packaging" a change for release

There's no packaging step beyond normal git hygiene:
1. Keep `.sh` and `.ps1` implementations in sync for any behavior change (see `CLAUDE.md` for the parity convention).
2. Bump `.cursor-plugin/plugin.json`'s `"version"` field if the change is user-facing.
3. Add a dated entry to `CHANGELOG.md` describing the change and, where relevant, the *why* (this repo's changelog is written as an incident/decision log, not a terse bullet list — match that style).
4. Run the test suite (both bash and Pester) and `shellcheck`/`PSScriptAnalyzer` locally before opening a PR, since CI won't run automatically.
