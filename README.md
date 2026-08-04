# pn-sanitizer (Snantizer)

A Cursor plugin that gates every submitted prompt through a `beforeSubmitPrompt`
hook. The hook calls a small local API, which decides whether the prompt is
allowed to reach the agent.

**Base case:** block the exact prompt `hello` (after trim); allow everything else.

## What's in this plugin

```text
pn-sanitizer/
├── .cursor-plugin/
│   └── plugin.json        # plugin manifest
├── hooks/
│   └── hooks.json          # sessionStart / beforeSubmitPrompt hook config
├── scripts/
│   ├── check-session.py   # sessionStart hook, flags missing PN login
│   ├── check-prompt.py    # beforeSubmitPrompt hook, calls the check API
│   ├── check-response.py  # preToolUse hook, calls the check API
│   ├── pn_config.py       # shared credentials store + token refresh
│   └── login.py           # one-time browser login CLI (PKCE)
├── skills/
│   └── pn-login/
│       └── SKILL.md       # tells the agent how to run login.py
├── rules/
│   └── pn-login-check.mdc # always-on backstop that asks for the base URL
└── server/                 # companion FastAPI service (not installed by the plugin)
    ├── main.py
    └── requirements.txt
```

Only `hooks/`, `scripts/`, `skills/`, and `rules/` are loaded when the plugin
is installed. `server/` is a companion service you run separately — the hook
has nothing to check prompts against without it.

## 1. Run the check API

Each developer (or a shared host) needs the API reachable at the URL the hook
points to.

```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --reload --host 127.0.0.1 --port 8000
```

Health check: `GET http://127.0.0.1:8000/health`
Check prompt: `POST http://127.0.0.1:8000/check` with `{"prompt":"..."}`.

## 2. Install the plugin

### Option A: Local install (for testing before sharing)

```bash
ln -s /path/to/pn-sanitizer ~/.cursor/plugins/local/pn-sanitizer
```

Restart Cursor (or run **Developer: Reload Window**).

### Option B: Team marketplace (for sharing with your team)

1. Push this repo to GitHub.
2. In the Cursor dashboard, go to **Dashboard → Plugins → Team Marketplaces → Add Marketplace**.
3. Import the repo URL and add `pn-sanitizer` to the marketplace.
4. Set it to **Default On** or **Required** so teammates get the hook automatically.

Teammates still need the check API reachable (see step 1) — the plugin only
ships the hook, not the server.

## Configuration

### One-time login (default)

The plugin authenticates against the PN backend with a one-time browser
login instead of any hardcoded or manually-pasted token:

1. Open a chat in Cursor. The `sessionStart` hook (`scripts/check-session.py`)
   checks whether this machine already has a valid stored login
   (`~/.pn/credentials.json`). If not, it tells the agent to ask you for your
   PN base URL. `sessionStart` is fire-and-forget per Cursor's hooks contract
   (it can race with — or miss — your very first message), and
   `beforeSubmitPrompt` has no way to inject context into the agent at all,
   so `rules/pn-login-check.mdc` (always-on) is the reliable backstop that
   actually guarantees the agent checks and asks on turn one.
2. Give the agent your PN base URL, e.g. `https://acme.paradigmnetworks.ai`.
   The agent runs the `pn-login` skill, which invokes:
   ```bash
   python3 scripts/login.py --base-url https://acme.paradigmnetworks.ai
   ```
3. This opens your browser to log in via an OAuth-style loopback-redirect +
   PKCE flow against `{base_url}/api/v1/plugin/authorize` and
   `/api/v1/plugin/token`. On success, credentials (`base_url`,
   `access_token`, `refresh_token`, `expires_at`) are saved to
   `~/.pn/credentials.json` (mode `0600`).

From then on, `check-prompt.py`, `check-response.py`, and `check-session.py`
all read from that file via `scripts/pn_config.py`, transparently refreshing
the access token in the background shortly before it expires. You only log
in once per machine — there's nothing to paste and nothing hardcoded in the
scripts.

To log in again (e.g. to switch PN orgs), just re-run `scripts/login.py`
with a different `--base-url`; it overwrites the stored credentials.

### Shared-host override (optional)

For a shared-host setup where you'd rather set config once for every
developer instead of everyone logging in individually, these environment
variables — read by `check-prompt.py` and `check-response.py` — take
**precedence over** the stored `~/.pn/credentials.json` login whenever both
`SNANTIZER_BASE_URL` and `SNANTIZER_TOKEN` are set:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SNANTIZER_BASE_URL` | _(none — falls back to stored login)_ | PN base URL |
| `SNANTIZER_TOKEN` | _(none — falls back to stored login)_ | Bearer access token |
| `SNANTIZER_SCAN_URL` | `{base_url}/api/v1/codedefense/scan` | Full scan endpoint override |
| `SNANTIZER_TIMEOUT` | `5` | HTTP timeout (seconds) |
| `SNANTIZER_TRANSCRIPT_BYTES` | `4000` | Bytes of transcript tail scanned by `check-response.py` |
| `SNANTIZER_FAILURE_MODE` | `closed` | `open`/`closed` — verdict when the scanner is unreachable or not configured (`check-response.py` only) |
| `SNANTIZER_LOG` | `~/.pn/check-response.log` | Debug log path for `check-response.py` |

If only one of `SNANTIZER_BASE_URL` / `SNANTIZER_TOKEN` is set, it's ignored
and the stored login is used instead — set both, or neither.

`failClosed` is enabled for `beforeSubmitPrompt` in `hooks/hooks.json`: if the
hook script itself crashes or times out, the prompt is blocked. If the API is
merely unreachable, slow, or not yet configured, the hook fails open (allows
the prompt) so a down API or a fresh, not-yet-logged-in checkout doesn't block
everyone's work — see `scripts/check-prompt.py`. `check-response.py`'s
`SNANTIZER_FAILURE_MODE` defaults to fail-closed instead, since it's the gate
that stops the agent from acting. `sessionStart` (`check-session.py`) is
`failClosed: false` and fails open on any error, since it must never block a
session from starting.

## Try it

1. Start the FastAPI server (step 1 above).
2. Install the plugin locally (step 2, option A).
3. In Agent chat, submit `hello` → should be blocked.
4. Submit any other prompt → should proceed.

Check **Cursor Settings → Hooks** or the Hooks output channel if something
does not fire.
