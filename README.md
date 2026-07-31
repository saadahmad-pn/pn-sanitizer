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
│   └── hooks.json          # beforeSubmitPrompt hook config
├── scripts/
│   └── check-prompt.py     # hook script, calls the check API
└── server/                 # companion FastAPI service (not installed by the plugin)
    ├── main.py
    └── requirements.txt
```

Only `hooks/` and `scripts/` are loaded when the plugin is installed.
`server/` is a companion service you run separately — the hook has nothing to
check prompts against without it.

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

The hook script reads these environment variables when Cursor runs it:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SNANTIZER_URL` | `http://127.0.0.1:8000/check` | Check endpoint |
| `SNANTIZER_TIMEOUT` | `5` | HTTP timeout (seconds) |

Point `SNANTIZER_URL` at a shared host if you don't want every developer
running their own instance of `server/`.

`failClosed` is enabled in `hooks/hooks.json`: if the hook script itself
crashes or times out, the prompt is blocked. If the API is merely unreachable
or slow, the hook fails open (allows the prompt) so a down API doesn't block
everyone's work — see `scripts/check-prompt.py`.

## Try it

1. Start the FastAPI server (step 1 above).
2. Install the plugin locally (step 2, option A).
3. In Agent chat, submit `hello` → should be blocked.
4. Submit any other prompt → should proceed.

Check **Cursor Settings → Hooks** or the Hooks output channel if something
does not fire.
