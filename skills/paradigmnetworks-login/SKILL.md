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
  one mistake, then move on (see step 3).

## Workflow

### 1. Locate the plugin's scripts directory

Needed for both the configuration check (step 2) and running the login
script (step 4) — there's no environment variable that tells you where the
plugin is installed, so path-guessing isn't reliable; locate it once here
and reuse the result.

**Read the path from your context — do not search when it is there.** The
`sessionStart` hook injects this line into every session, logged in or not:

```
Paradigm Networks plugin scripts directory: <scripts-dir>
```

`<scripts-dir>` is this installation's own path, so it is correct even when
several copies of the plugin are installed (a local copy plus marketplace
copies, or several cached marketplace versions). Use it as given.

When Paradigm Networks is not configured, the hook's notice also contains
the exact login command with that path already filled in:

```
bash <scripts-dir>/login.sh --base-url <their-base-url>
```

If you have that notice, skip straight to step 3 (get the base URL) and then
step 4, using that exact path. Skip step 2 as well: the notice only appears
when Paradigm Networks is not configured, so the answer is already known.

This matters because **while Paradigm Networks is unconfigured, every tool
call except the login/logout/check-configured commands is denied** — so
search commands are themselves blocked, and running them first is the one
way to get stuck. The deny message you receive also repeats the same login
command, so if you have already been blocked, take the path from there
rather than searching again.

Only fall back to searching when neither the injected line, the notice nor
a deny message gave you a path. Use whichever command matches the shell
you're actually running in — a Windows machine without WSL/Git Bash can't
run the bash `find` command, and vice versa. These patterns match both local
installs (`~/.cursor/plugins/local/paradigm-scanner/scripts/`) and
marketplace installs
(`~/.cursor/plugins/cache/<marketplace>/paradigm-scanner/<version>/scripts/`):

macOS/Linux:

```bash
find ~/.cursor/plugins -path "*/paradigm-scanner/*scripts/check-configured.sh" 2>/dev/null
find ~/.cursor/plugins -path "*/paradigm-scanner/*scripts/login.sh" 2>/dev/null
```

Windows (PowerShell):

```powershell
Get-ChildItem -Path "$HOME\.cursor\plugins" -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -like "*\paradigm-scanner\*scripts\check-configured.ps1" -or $_.FullName -like "*\paradigm-scanner\*scripts\login.ps1" } |
  Select-Object -ExpandProperty FullName
```

If more than one copy comes back, the search cannot tell which one is
running. Prefer one under `local/`; otherwise use the most recently modified
one, and take both scripts from the same directory.

### 2. Check whether login is actually needed

Skip this if you already know login is missing (e.g. from a hook message).
Otherwise, run `check-configured.sh`/`check-configured.ps1` (located in step
1) — **don't hand-write your own file-existence check** (e.g. `test -f
~/.pn/credentials.json`) as a raw Shell tool call instead of running this
script: doing so puts the credentials file's path directly in the tool
call's command text, which security scanning flags as a credential-path
exposure finding and can block the check outright. This script takes no
arguments and its own invocation names no path, so there's nothing for that
finding to point at:

macOS/Linux:

```bash
bash <path-to-check-configured.sh>
```

Windows:

```
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "<scripts-dir>\check-configured.ps1"
```

Run this command **exactly as shown above and nothing else** — don't
combine it with `cd`, `&&`, `;`, or any other command, and don't add any
arguments. This precise, standalone, argument-free shape is what lets
Paradigm Networks' own security scanning recognize it as this check and
skip scanning it, the same way `login.sh` is recognized in step 4 below
(and `logout.sh` in the separate `paradigmnetworks-logout` skill).

- Output `CONFIGURED` → tell the user they're already logged in and stop
  here.
- Output `NOT_CONFIGURED` → no base URL is known at all; continue to step 3.
  There is no Cursor Settings field or other admin-preconfiguration path for
  the base URL — the user is always the source of it, every time, via
  step 3.

### 3. Get the base URL

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

### 4. Run the login script

Uses the `login.sh`/`login.ps1` path already located in step 1.

macOS/Linux:

```bash
bash <path-to-login.sh> --base-url <the-base-url>
```

Windows:

```
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "<scripts-dir>\login.ps1" -BaseUrl <the-base-url>
```

("the base URL" is whatever the user gave you in step 3.)

Run this command **exactly as shown above and nothing else** — don't combine
it with `cd`, `&&`, `;`, or any other command, and don't add extra flags.
This precise, standalone shape is what lets Paradigm Networks' own security
scanning recognize it as the login step and skip scanning it (it carries no
user-authored content, only the base URL); anything else about the command
line falls back to being scanned like any other tool call.

**Run it with network access.** In Cursor's Shell tool, pass
`required_permissions: ["full_network"]` on this call. After the browser
step, the script itself must reach the Paradigm Networks server to collect
the login token. Cursor's agent sandbox blocks network access by default,
so without this the browser sign-in succeeds but the script then fails with
`could not reach <base-url>` or `unexpected non-JSON response`, and the
user is never logged in. This only changes how Cursor runs the command, not
the command text, so the shape rule above still holds.

Run it in the background rather than blocking the turn on it — it can take
up to five minutes. **Poll its output every second or two, specifically
looking for the URL/browser-opened line, rather than checking once and
moving on.** The script starts its local callback server before it prints
that line, so a single early check can land in the narrow window after
the server is already up but before the line has actually been written —
confirmed directly as the cause of the URL inconsistently failing to
reach the user even though the script itself always prints it. Keep
checking (this is normally a matter of seconds, not the full five-minute
budget) until you actually see it before relaying anything.

The script always tries to open the user's browser itself, and falls back to
copying the link to their clipboard, then to printing it — it reports which
of those happened. Just relay whatever it printed verbatim; don't add your
own caveats about browsers possibly failing to open, and don't try alternate
ways to launch a browser yourself.

Each run generates a new URL, and every run listens on the same local port,
so a URL from an earlier (finished, failed or killed) run will not work: if
the user opens one, the current run rejects it with a state mismatch. If you
retry, relay only the newest URL and tell the user not to use earlier ones.

### 5. Wait for the result

**Poll for completion — do not sleep for a fixed duration and check once.**
Check whether the background process has finished every few seconds,
starting almost immediately, and stop the moment it has — most logins
complete in well under five minutes once the user clicks through, and
there's no reason to sit idle after it's already done. Five minutes is only
the outer bound for giving up, not a wait you should run out every time.

While Paradigm Networks is unconfigured, every tool call except the
login/logout/check-configured scripts is denied, apart from the three you
need here: waiting on the login's background shell (`AwaitShell`), reading
its terminal output file, and a bare `sleep <seconds>` between checks. Use
those. Don't run anything else in between, and don't rely on
`check-configured.sh` alone: it only says `NOT_CONFIGURED`, which is also
what it says after the login has already failed.

**Judge the result from the script's own output and exit code**, not from
`check-configured.sh`, and not from what the user says ("done", or "the
browser says I'm signed in"): the browser page appears before the script
collects the token, so it can show sign-in complete even when the login
then fails.

### 6. Relay the outcome

- Exit `0` → Paradigm Networks is configured and its checks are active. No
  further action needed.
- Non-zero → quote the script's own `error:` line to the user. Don't
  replace it with your own guess (e.g. "you didn't finish in the browser"
  or "it timed out") unless that is what the script printed.
- If the error says `could not reach`, `unexpected non-JSON response`, or
  mentions the sandbox, the script had no network access. If you ran it
  without `required_permissions: ["full_network"]`, run it once more with
  it, as a fresh run (new URL). If it still fails that way, give the user
  the exact command from step 4 to run in their own terminal, and stop.
- Any other error (timeout, denied, state mismatch) → offer to retry with a
  fresh run. If retrying, remind the user they'll need to click through the
  new link within the five-minute window.
