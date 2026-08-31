---
name: paradigmnetworks-login
description: Log this workspace in to Paradigm Networks so Paradigm Networks security checks work. Use when Paradigm Networks isn't configured yet — e.g. the sessionStart hook injected a "Paradigm Networks is not configured" notice, or a hook message mentions no login/token was found — or when the user explicitly asks to log in to Paradigm Networks, switch Paradigm Networks orgs, or re-authenticate.
---

# Paradigm Networks login

## When to use this

- The `sessionStart` hook (`scripts/check-session.sh`) injected context saying
  Paradigm Networks is not configured for this workspace.
- `check-prompt.sh` reported "not configured" / "no
  login found" in a `user_message`.
- The user asks to log in, re-authenticate, or switch to a different Paradigm
  Networks organization.

## What not to do

- Don't invent, guess, or reuse a base URL from another project, example, or
  training data. The base URL (e.g. `https://acme.paradigmnetworks.ai`) is
  specific to the user's organization and **must come from the user**.
- Don't fabricate a successful login. Only report success once `login.sh`
  actually exits `0`.
- Don't ask for or accept an access token directly — this is a browser login,
  not manual token entry.
- Don't loop the base-URL question more than once. Validate, correct at most
  one mistake, then move on (see step 2).

## Workflow

### 1. Check whether login is actually needed

Skip this if you already know login is missing (e.g. from a hook message).
Otherwise, confirm with a plain shell check — don't try to locate this
plugin's own `scripts/` directory for this, there's no environment variable
that tells you where the plugin is installed, so path-guessing isn't
reliable:

macOS/Linux:

```bash
if [ -f ~/.pn/credentials.json ] || { [ -n "$PARADIGM_NETWORKS_URL" ] && [ -n "$PARADIGM_NETWORKS_TOKEN" ]; }; then
  echo CONFIGURED
else
  echo NOT_CONFIGURED
fi
```

Windows (PowerShell):

```powershell
if ((Test-Path "$HOME\.pn\credentials.json") -or ($env:PARADIGM_NETWORKS_URL -and $env:PARADIGM_NETWORKS_TOKEN)) {
  Write-Output "CONFIGURED"
} else {
  Write-Output "NOT_CONFIGURED"
}
```

- `CONFIGURED` → tell the user they're already logged in and stop here.
- `NOT_CONFIGURED` → no base URL is known at all; continue to step 2. There
  is no Cursor Settings field or other admin-preconfiguration path for the
  base URL — the user is always the source of it, every time, via step 2.

### 2. Get the base URL

**Actually invoke the `AskQuestion` tool for this — do not ask in a plain
chat message.** Typing the prompt and options into your reply as text (even
as a bulleted list) is not the same thing: it skips the tool entirely, so the
user just sees a paragraph instead of clickable options with a free-text
"Other" field to type their URL into. If you're not making a tool call here,
you're doing it wrong.

Call `AskQuestion` with:

- prompt: `What's your Paradigm Networks base URL? (e.g. https://acme.paradigmnetworks.ai). Don't have one yet? Sign up at https://signup.claude-demo.paradigmnetworks.ai/signup.`
- options: `I'm not sure what my base URL is` and
  `I think I'm already logged in — recheck`
  (two real, non-"Other" options are required by the tool; the user's actual
  URL comes back through "Other", which is the expected path for most users)

If they pick **"I'm not sure what my base URL is"**: they likely don't have a
Paradigm Networks account yet. Point them to https://signup.claude-demo.paradigmnetworks.ai/signup to
sign up and get one, then stop and wait — don't guess a URL or retry the
question in a loop. Once they say they have it, ask again with the same
`AskQuestion` call.

Validate the answer once it comes back: it should start with `http://` or
`https://` and include a host. If it clearly doesn't, ask exactly one
follow-up (also via `AskQuestion`) to correct it. If it still doesn't parse
after that, proceed with it anyway — `login.sh` validates the URL itself and
will report a clear error if it's truly malformed. Don't keep re-asking past
that point.

### 3. Locate the login script

Running the script (unlike the check in step 1) needs its real path, since
it needs `pn_config.sh`/`pn_config.ps1` next to it. On macOS/Linux you need
`login.sh`; on Windows you need `login.ps1` alongside `run-powershell.cmd`:

```bash
find ~/.cursor/plugins -path "*/paradigm-scanner/scripts/login.sh" 2>/dev/null
find ~/.cursor/plugins -path "*/paradigm-scanner/scripts/login.ps1" 2>/dev/null
```

This covers both marketplace installs (`~/.cursor/plugins/cache/`) and local
installs (`~/.cursor/plugins/local/`). If both come back for a platform,
prefer `local/`.

### 4. Run the login script

macOS/Linux:

```bash
bash <path-to-login.sh> --base-url <the-base-url>
```

Windows:

```
<scripts-dir>\run-powershell.cmd <scripts-dir>\login.ps1 -BaseUrl <the-base-url>
```

("the base URL" is whatever the user gave you in step 2.)

Run it in the background rather than blocking the turn on it — it can take
up to a minute, and you need to relay its output as soon as it appears
(the script flushes its output immediately, so read it after a couple of
seconds rather than waiting for the process to exit).

The script already knows whether it's running in a sandboxed agent shell and
adjusts itself accordingly — it will either open a browser for the user or
print a link for them to open manually, and tell you which. Just relay
whatever it printed verbatim; don't add your own caveats about browsers
possibly failing to open, and don't try alternate ways to launch a browser
yourself.

Each run binds a fresh local port and generates a new URL — a URL from an
earlier (timed-out or killed) run will not work. If you retry, always relay
the newest URL.

### 5. Wait for the result

**Poll for completion — do not sleep for a fixed duration and check once.**
Check whether the background process has finished every few seconds,
starting almost immediately, and stop the moment it has — most logins
complete in well under 60 seconds once the user clicks through, and there's
no reason to sit idle after it's already done. 60 seconds is only the
outer bound for giving up, not a wait you should run out every time. Once
it's finished, check the script's actual exit code — don't infer success
just because the user says "done," since the local callback server has to
actually receive the redirect.

### 6. Relay the outcome

- Exit `0` → Paradigm Networks is configured and its checks are active. No
  further action needed. **Also mention, in one line, that prompts and
  writes are scanned using a default model, and that the user can ask
  "what models are available" any time to see or change it** (see the
  `paradigmnetworks-models` skill) — this is the only point in the whole
  flow where a user would have a reason to learn this exists, so don't
  skip it. Keep it to one line; don't explain the mechanism unless asked.
- Non-zero → share the error the script printed (timeout, denied, network
  error, etc.) and offer to retry with a fresh run. If retrying, remind the
  user they'll need to click through within the one-minute window.
