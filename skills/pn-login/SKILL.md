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
   missing (from a hook message), skip straight to step 2. Otherwise, you can
   sanity-check by running:
   ```bash
   python3 -c "import sys; sys.path.insert(0, '<plugin-root>/scripts'); import pn_config; print(pn_config.get_valid_access_token())"
   ```
   If this prints a tuple (not `None`), PN is already configured — tell the
   user they're already logged in and stop here.

2. **Ask the user for their PN base URL**, conversationally, e.g.:
   > "I need your PN base URL to log in — something like
   > `https://acme.paradigmnetworks.ai`. What's yours?"

3. **Validate the answer looks like a URL** before proceeding: it should
   start with `http://` or `https://` and have a host. If it doesn't, ask
   again rather than guessing what they meant.

4. **Run the login script** via the terminal tool, substituting the actual
   plugin root path and the URL the user gave you:
   ```bash
   python3 <plugin-root>/scripts/login.py --base-url <the-url-the-user-gave-you>
   ```
   This opens the user's browser to log in and blocks (up to ~2 minutes)
   until the browser redirects back or it times out. Let it run — don't
   cancel it early.

5. **Relay the outcome in plain language**:
   - Exit code 0 → tell the user they're logged in and PN hooks are now
     active; no further action needed.
   - Non-zero exit → tell the user login failed, share the error message the
     script printed (timeout, denied, network error, etc.), and offer to
     retry — they may need to complete the login in the browser tab that
     opened, or double-check the base URL.
