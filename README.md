# Paradigm Networks

A Cursor plugin that gates every submitted prompt (`beforeSubmitPrompt`) and
every file write (`preToolUse`), sending each to your organization's
Paradigm Networks API to decide whether it's allowed through. It also keeps
the agent aware of the git repo(s) and branch(es) in the workspace, so
Paradigm Networks can attribute a request to a repo.

Since that means prompt text and file-write content leave your machine, see
[SECURITY.md](SECURITY.md#data-handling) for exactly what's sent, where it's
stored, and how — worth reading before installing.

## What's in this plugin

```text
paradigm-scanner/
├── .cursor-plugin/
│   └── plugin.json        # plugin manifest
├── hooks/
│   └── hooks.json          # sessionStart / beforeSubmitPrompt / preToolUse hook config
├── scripts/
│   ├── check-session.sh          # sessionStart hook (macOS/Linux)
│   ├── check-prompt.sh           # beforeSubmitPrompt hook, calls the Paradigm Networks API (macOS/Linux)
│   ├── check-write.sh            # preToolUse hook, calls the Paradigm Networks API (macOS/Linux)
│   ├── check-repo-context.sh     # beforeSubmitPrompt hook, writes workspace git context (macOS/Linux)
│   ├── pn_config.sh              # shared credentials store + token refresh (macOS/Linux)
│   ├── login.sh                  # one-time browser login CLI, PKCE (macOS/Linux)
│   ├── lib/common.sh             # shared JSON/HTTP/logging helpers (macOS/Linux)
│   ├── lib/git-utils.sh          # git repo discovery + sanitization (macOS/Linux)
│   ├── bin/                      # bundled jq fallback binaries — see Dependencies below
│   ├── check-session.ps1         # sessionStart hook (Windows)
│   ├── check-prompt.ps1          # beforeSubmitPrompt hook (Windows)
│   ├── check-write.ps1           # preToolUse hook (Windows)
│   ├── check-repo-context.ps1    # beforeSubmitPrompt hook, writes workspace git context (Windows)
│   ├── pn_config.ps1             # shared credentials store + token refresh (Windows)
│   ├── login.ps1                 # one-time browser login CLI, PKCE (Windows)
│   ├── lib/common.ps1            # shared JSON/HTTP/logging helpers (Windows)
│   ├── lib/git-utils.ps1         # git repo discovery + sanitization (Windows)
│   └── run-powershell.cmd        # launches the .ps1 hooks; see Windows support below
├── skills/
│   └── paradigmnetworks-login/
│       └── SKILL.md       # tells the agent how to run the login script
└── rules/
    └── pn-login-check.mdc # always-on backstop that asks for the base URL
```

Only `hooks/`, `scripts/`, `skills/`, and `rules/` are loaded when the plugin
is installed.

## Dependencies

**macOS/Linux:** `jq`, `curl`, `openssl`, and `nc` are required. You
almost certainly don't need to think about `jq` specifically, though:
every script prefers a system install if you have one, but falls back
automatically to a copy bundled in `scripts/bin/` (macOS arm64/amd64,
Linux amd64/arm64 — see `scripts/bin/PROVENANCE.md` for exact versions
and checksums). If neither is available — an unsupported
platform/architecture — the plugin fails gracefully with a clear message
instead of producing broken output.

**Windows:** nothing to install. The `.ps1` scripts use only what ships
with Windows PowerShell 5.1 by default — no bundled `jq`/`curl`/`openssl`/
`nc` equivalent needed, since `ConvertTo-Json`/`Invoke-RestMethod`/
`System.Security.Cryptography`/`System.Net.HttpListener` cover the same
ground natively. See "Windows support" below for how this actually runs.

## Windows support

Cursor has no way to run a hook entry on only one platform — every entry
in a hook's array runs on every OS unconditionally (confirmed against
Cursor's own hooks documentation). So each hook event lists both a bash
command and a PowerShell one; whichever one doesn't apply exits
immediately and silently:

- On macOS/Linux, the PowerShell entry runs through `run-powershell.cmd`,
  whose first line is deliberately readable both as a Windows batch label
  and as a POSIX shell no-op — so when `/bin/sh` (not `cmd.exe`) ends up
  executing it, it just exits `0` instead of erroring.
- On Windows, if `bash` happens to be available anyway (Git Bash, MSYS2,
  Cygwin), the `.sh` scripts detect that environment and exit immediately
  with a neutral response instead of doing the real work a second time.

`run-powershell.cmd` launches PowerShell from an absolute,
`%SystemRoot%`-expanded path (not a bare `powershell.exe`, which could be
hijacked by a same-named binary earlier in `PATH`) with
`-ExecutionPolicy Bypass` scoped to that one invocation — no system or
user execution-policy setting needs to change.

The Windows login flow (`login.ps1`) binds its OAuth callback listener to
`127.0.0.1` specifically, never a wildcard address — binding to a
specific loopback address doesn't require administrator rights on
Windows, while binding wider does, and there's never a reason to bind
wider here since the browser completing the redirect always runs on the
same machine.

This has been reviewed carefully but not run end-to-end on a real Windows
machine by the people maintaining this repo — if you hit something that
doesn't work as described, that's the part most likely to have a real bug.

## 1. Point it at your Paradigm Networks deployment

Each developer (or a shared host) needs your organization's Paradigm
Networks API reachable at the base URL you'll log in with, e.g.
`https://acme.paradigmnetworks.ai`. This plugin doesn't ship a scanning
backend — it's a client for your org's own Paradigm Networks deployment.

## 2. Install the plugin

### Option A: Local install (for testing before sharing)

```bash
ln -s /path/to/pn-sanitizer ~/.cursor/plugins/local/paradigm-scanner
```

Restart Cursor (or run **Developer: Reload Window**).

### Option B: Team marketplace (for sharing with your team)

1. Push this repo to GitHub.
2. In the Cursor dashboard, go to **Dashboard → Plugins → Team Marketplaces → Add Marketplace**.
3. Import the repo URL and add `paradigm-scanner` to the marketplace.
4. Set it to **Default On** or **Required** so teammates get the hook automatically.

Teammates still need the check API reachable (see step 1) — the plugin only
ships the hook, not the server.

## Configuration

### One-time login (default)

The plugin authenticates against the Paradigm Networks backend with a
one-time browser login instead of any hardcoded or manually-pasted token:

1. Open a chat in Cursor. The `sessionStart` hook (`scripts/check-session.sh`)
   checks whether this machine already has a valid stored login
   (`~/.pn/credentials.json`). If not, it tells the agent to ask you for your
   Paradigm Networks base URL. `sessionStart` is fire-and-forget per Cursor's
   hooks contract (it can race with — or miss — your very first message), and
   `beforeSubmitPrompt` has no way to inject context into the agent at all,
   so `rules/pn-login-check.mdc` (always-on) is the reliable backstop that
   actually guarantees the agent checks and asks on turn one.
2. Give the agent your Paradigm Networks base URL, e.g. `https://acme.paradigmnetworks.ai`.
   Don't have one yet? Sign up at https://signup.claude-demo.paradigmnetworks.ai/signup.
   The agent runs the `paradigmnetworks-login` skill, which invokes (macOS/Linux):
   ```bash
   bash scripts/login.sh --base-url https://acme.paradigmnetworks.ai
   ```
   or, on Windows:
   ```
   scripts\run-powershell.cmd scripts\login.ps1 -BaseUrl https://acme.paradigmnetworks.ai
   ```
3. This opens your browser to log in via an OAuth-style loopback-redirect +
   PKCE flow against `{base_url}/api/v1/plugin/authorize` and
   `/api/v1/plugin/token`. On success, credentials (`base_url`,
   `access_token`, `refresh_token`, `expires_at`) are saved to
   `~/.pn/credentials.json` — restricted to your user only (mode `0600` on
   macOS/Linux, an equivalent owner-only ACL on Windows).

From then on, `check-prompt.sh`, `check-write.sh`, and `check-session.sh`
all read from that file via `scripts/pn_config.sh`, transparently refreshing
the access token in the background shortly before it expires. You only log
in once per machine — there's nothing to paste and nothing hardcoded in the
scripts.

To log in again (e.g. to switch Paradigm Networks orgs), just re-run `scripts/login.sh`
with a different `--base-url`; it overwrites the stored credentials.

### Shared-host override (optional)

For a shared-host setup where you'd rather set config once for every
developer instead of everyone logging in individually, these environment
variables — read by `check-prompt.sh` and `check-write.sh` — take
**precedence over** the stored `~/.pn/credentials.json` login whenever both
`SNANTIZER_BASE_URL` and `SNANTIZER_TOKEN` are set:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SNANTIZER_BASE_URL` | _(none — falls back to stored login)_ | Paradigm Networks base URL |
| `SNANTIZER_TOKEN` | _(none — falls back to stored login)_ | Bearer access token |
| `SNANTIZER_SCAN_URL` | `{base_url}/api/v1/codedefense/scan` | Full scan endpoint override |
| `SNANTIZER_TIMEOUT` | `5` | HTTP timeout (seconds) |
| `SNANTIZER_FAILURE_MODE` | `closed` | `open`/`closed` — legacy name for the write-guard failure mode below |

`check-write.sh` also reads `PARADIGM_NETWORKS_FAILURE_MODE` — the setting
exposed in Cursor's plugin configuration UI — taking precedence over
`SNANTIZER_FAILURE_MODE` when both are set. It accepts `block` (default;
deny writes when the scanner is unreachable or not configured) or `allow`
(let writes through unscanned in that case).

`check-prompt.sh` has its own, separate `PARADIGM_NETWORKS_PROMPT_FAILURE_MODE`
(or legacy `SNANTIZER_PROMPT_FAILURE_MODE`), accepting `allow` (default) or
`block`. It
only governs scanner errors that happen *after* you're already logged in
(timeout, unreachable, invalid response) — a not-yet-configured workspace
always allows the prompt through unconditionally regardless of this setting,
since `beforeSubmitPrompt` has no way to hand the agent context to explain a
block, and blocking here could strand a new user before they ever reach the
login flow. The same is true if `jq` itself is missing.

If only one of `SNANTIZER_BASE_URL` / `SNANTIZER_TOKEN` is set, it's ignored
and the stored login is used instead — set both, or neither.

`beforeSubmitPrompt` has no `failClosed` set in `hooks/hooks.json`, so it
follows Cursor's default (fail-open) if the hook script itself crashes or
times out. If the Paradigm Networks API is merely unreachable, slow, or not
yet configured, `check-prompt.sh` also fails open on purpose — see
`PARADIGM_NETWORKS_PROMPT_FAILURE_MODE` above for how to change that once
your team is fully onboarded. `sessionStart` (`check-session.sh`) explicitly sets
`failClosed: false` and always fails open, since it must never block a
session from starting.

### Git repo context

`check-repo-context.sh` runs on the same `beforeSubmitPrompt` event as
`check-prompt.sh`, independently — it has nothing to do with the security
scan and never blocks a prompt. Before each prompt, it looks for git repos
in the workspace and (re)writes `.cursor/rules/paradigm-repo-context.mdc`
with a sanitized `<GIT>url|branch</GIT>` tag per repo found (credentials in
the remote URL are stripped first). That file is `alwaysApply: true`, so
Cursor folds it into the system prompt of the next real model request —
which is what lets your Paradigm Networks deployment attribute a request to
a repo. It also adds that generated file's path to the workspace's own
`.gitignore` the first time it runs, so it never risks getting committed.
Nothing here sends anything to Paradigm Networks directly; the repo/branch
tag just rides along as part of the prompt content already covered in
[SECURITY.md](SECURITY.md#data-handling).

## Try it

1. Install the plugin locally (step 2, option A) and log in to your
   organization's Paradigm Networks deployment (see "One-time login" above).
2. In Agent chat, submit a prompt or make an edit that your organization's
   Paradigm Networks policy blocks — it should be denied with a message from
   the plugin.
3. Submit anything Paradigm Networks allows — it should proceed normally.

Check **Cursor Settings → Hooks** or the Hooks output channel if something
does not fire.
