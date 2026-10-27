---
name: paradigmnetworks-logout
description: Log this workspace out of Paradigm Networks by revoking its login on the server and removing the locally stored credentials. Use when the user explicitly asks to log out of Paradigm Networks, disconnect it, remove their login, or switch which Paradigm Networks org/account this workspace uses (log out first, then run the paradigmnetworks-login skill to log in again).
---

# Paradigm Networks logout

## When to use this

- The user explicitly asks to log out of Paradigm Networks, disconnect it,
  or remove their Paradigm Networks login from this workspace.
- The user wants to switch to a different Paradigm Networks org/account —
  log out first (this skill), then run the `paradigmnetworks-login` skill
  to log back in under the new org.

Don't use this just because a hook reported "not configured" — that means
there's nothing to log out of. That's the `paradigmnetworks-login` skill's
territory instead.

## What not to do

- **Don't run the logout script without confirming with the user first.**
  Removing the credentials file is a real, if low-stakes, destructive
  action on the user's local machine — confirm intent before running it,
  the same way you would for any other destructive local action. Logging
  back in afterward is quick (one browser click), but that doesn't excuse
  skipping the confirmation.
- **Don't hand-delete `~/.pn/credentials.json` yourself** (e.g. via a raw
  `rm`/`Remove-Item`) — always go through `logout.sh`/`logout.ps1` (step
  2), the same reasoning as the models skill's rule about never
  hand-editing that file directly.
- **Don't claim the login was revoked on the server unless the script says
  so.** The script first asks the server to revoke this login, then always
  removes the local credentials file. The server step can fail (server
  unreachable, or a server version that doesn't support revoking yet), and
  the script's second output line says which happened.

## Workflow

### 1. Confirm with the user

Ask a plain, direct confirmation before proceeding (e.g. "This will sign
you out of Paradigm Networks: it revokes this login on the server and
removes it from this machine — you'll need to log in again afterward to use
Paradigm Networks-gated prompts and writes. Proceed?"). Only continue on a
clear yes.

### 2. Locate the logout script

There's no environment variable that tells you where the plugin is
installed, so don't guess the path. Instead, read it from your context: the
`sessionStart` hook injects this line into every session:

```
Paradigm Networks plugin scripts directory: <scripts-dir>
```

`<scripts-dir>` is this installation's own path, so it is correct even when
several copies of the plugin are installed (a local copy plus marketplace
copies, or several cached marketplace versions). The logout script is
`<scripts-dir>/logout.sh` (macOS/Linux) or `<scripts-dir>\logout.ps1`
(Windows). **Do not search for it when that line is present.**

Only if that line is not in your context, fall back to searching. Use
whichever command matches the shell you're actually running in — a Windows
machine without WSL/Git Bash can't run the bash `find` command, and vice
versa. These patterns match both local installs
(`~/.cursor/plugins/local/paradigm-networks/scripts/`) and marketplace
installs
(`~/.cursor/plugins/cache/<marketplace>/paradigm-networks/<version>/scripts/`):

macOS/Linux:

```bash
find ~/.cursor/plugins -path "*/paradigm-networks/*scripts/logout.sh" 2>/dev/null
```

Windows (PowerShell):

```powershell
Get-ChildItem -Path "$HOME\.cursor\plugins" -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -like "*\paradigm-networks\*scripts\logout.ps1" } |
  Select-Object -ExpandProperty FullName
```

If more than one copy comes back, the search cannot tell which one is
running. Prefer one under `local/`; otherwise use the most recently modified
one.

### 3. Run it

macOS/Linux:

```bash
bash <path-to-logout.sh>
```

Windows:

```
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "<scripts-dir>\logout.ps1"
```

Run this command **exactly as shown above and nothing else** — don't combine
it with `cd`, `&&`, `;`, or any other command, and don't add any flags. This
precise, standalone shape (with no arguments) is what lets Paradigm
Networks' own security scanning recognize it as the logout step and skip
scanning it; anything else about the command line falls back to being
scanned like any other tool call.

### 4. Relay the outcome

Relay what the script printed verbatim — don't paraphrase or summarize it.
It always exits `0` (there's nothing that can meaningfully fail here
short of a filesystem error), and covers these cases on its own:

- Credentials removed — logged out on this machine. A second line reports
  the server side: either the login was revoked there, or it couldn't be
  (server unreachable, revoke not supported yet, or no usable credentials),
  in which case the old login stays valid on the server until it expires.
  Don't retry the logout to "fix" that; just make sure the user saw it.
- No credentials file found — the workspace wasn't logged in to begin with.
- Removed, but `PARADIGM_NETWORKS_URL`/`PARADIGM_NETWORKS_TOKEN` are still
  set in the environment — those env vars take precedence over the file
  (see `pn_config.sh`/`pn_config.ps1`'s `pn_resolve_config`/`Resolve-PnConfig`),
  so Paradigm Networks checks will keep working via them until they're
  unset elsewhere. Don't unset environment variables yourself — that's
  outside this skill's scope; just make sure the user understands why
  they might still appear logged in.
