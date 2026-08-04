---
name: pn-login
description: Log this workspace in to PN (Paradigm Networks) so CodeDefense-gated hooks (check-prompt.py, check-response.py) work. Use when PN isn't configured yet — e.g. the sessionStart hook injected a "PN is not configured" notice, or a hook message mentions no login/token was found — or when the user explicitly asks to log in to PN, switch PN orgs, or re-authenticate.
---

# PN login

## When to use this

- The `sessionStart` hook (`scripts/check-session.py`) injected context saying
  PN is not configured for this workspace.
- `check-prompt.py` or `check-response.py` reported "not configured" / "no
  login found" in a `user_message`.
- The user asks to log in, re-authenticate, or switch to a different PN
  organization.

## What NOT to do

- Do not invent, guess, or reuse a base URL from another project, example, or
  training data. The base URL (e.g. `https://acme.paradigmnetworks.ai`) is
  specific to the user's organization and **must come from the user**.
- Do not fabricate a successful login. Only report success if the CLI script
  below exits 0.
- Do not paste or ask for access tokens directly — this flow is a browser
  login, not manual token entry.

## Workflow

1. **Check if this is actually needed.** If you already know login is
   missing (from a hook message), skip straight to step 2. Otherwise,
   sanity-check with a plain shell command — don't try to locate this
   plugin's own `scripts/` directory for this check, there's no environment
   variable that tells you where the plugin is installed:
   ```bash
   if [ -f ~/.pn/credentials.json ] || { [ -n "$SNANTIZER_BASE_URL" ] && [ -n "$SNANTIZER_TOKEN" ]; }; then echo CONFIGURED; else echo NOT_CONFIGURED; fi
   ```
   If this prints `CONFIGURED`, PN is already set up — tell the user they're
   already logged in and stop here.

2. **Ask the user for their PN base URL**, conversationally, e.g.:
   > "I need your PN base URL to log in — something like
   > `https://acme.paradigmnetworks.ai`. What's yours?"

3. **Validate the answer looks like a URL** before proceeding: it should
   start with `http://` or `https://` and have a host. If it doesn't, ask
   again rather than guessing what they meant.

4. **Locate `login.py`.** Unlike the check above, running the login script
   does require its actual path, since it needs `pn_config.py` next to it.
   Find it rather than guessing:
   ```bash
   find ~/.cursor/plugins -path "*/pn-sanitizer/scripts/login.py" 2>/dev/null
   ```
   (covers both marketplace installs under `~/.cursor/plugins/cache/` and
   local installs under `~/.cursor/plugins/local/`). If more than one match
   comes back, prefer the one under `local/` if present.

5. **Run the login script in the background** — do not block the whole
   turn on it, since it can take up to 2 minutes and you need to relay the
   authorize URL to the user right away:
   ```bash
   python3 <path-from-step-4> --base-url <the-url-the-user-gave-you>
   ```
   Launch this as a backgrounded/non-blocking command, then read its output
   after a couple of seconds — it prints the authorize URL immediately (it's
   line-buffered specifically so this works even when not attached to a
   TTY).

   **Do not assume the browser will auto-open.** In a sandboxed/headless
   shell environment (which is what's running this command), automatic
   browser launching commonly fails — on macOS this shows up as `osascript`
   / `errAETargetAddressNotPermitted (-10661)` noise, which is expected and
   harmless, not something to debug. Treat manual opening as the normal
   path, not a fallback: as soon as you see the authorize URL in the output,
   give it to the user immediately and ask them to open it now, rather than
   waiting to see whether auto-open worked first.

   Each run binds a fresh local port and generates a new URL/state — a URL
   from a previous (timed-out or killed) run will not work. If you have to
   retry, always relay the newest URL, not one from an earlier attempt.

6. **Wait for the result** (up to ~2 minutes) and check the script's actual
   exit code — don't infer success from the user saying "I logged in" alone,
   since the local callback server has to actually receive the redirect.

7. **Relay the outcome in plain language**:
   - Exit code 0 → tell the user they're logged in and PN hooks are now
     active; no further action needed.
   - Non-zero exit → tell the user login failed, share the error message the
     script printed (timeout, denied, network error, etc.), and offer to
     retry with a fresh run (new URL) — they'll need to click through
     promptly this time, since the window is fixed at ~2 minutes per run.
