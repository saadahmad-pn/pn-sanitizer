---
name: paradigmnetworks-logout
description: Log this workspace out of Paradigm Networks by removing the locally stored credentials. Use when the user explicitly asks to log out of Paradigm Networks, disconnect it, remove their login, or switch which Paradigm Networks org/account this workspace uses (log out first, then run the paradigmnetworks-login skill to log in again).
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
- There is no server-side session or token to revoke here — Paradigm
  Networks' login flow never issues anything like that, so don't imply to
  the user that this contacts a server or invalidates anything remotely.
  This only clears the local credentials file.

## Workflow

### 1. Confirm with the user

Ask a plain, direct confirmation before proceeding (e.g. "This will remove
your locally stored Paradigm Networks login for this workspace — you'll
need to log in again afterward to use Paradigm Networks-gated prompts and
writes. Proceed?"). Only continue on a clear yes.

### 2. Locate the logout script

Same reasoning as the login/models skills: there's no environment variable
that tells you where the plugin is installed, so don't guess the path. Use
whichever command matches the shell you're actually running in — a Windows
machine without WSL/Git Bash can't run the bash `find` command, and vice
versa:

macOS/Linux:

```bash
find ~/.cursor/plugins -path "*/paradigm-scanner/scripts/logout.sh" 2>/dev/null
```

Windows (PowerShell):

```powershell
Get-ChildItem -Path "$HOME\.cursor\plugins" -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -like "*\paradigm-scanner\scripts\logout.ps1" } |
  Select-Object -ExpandProperty FullName
```

This covers both marketplace installs (`~/.cursor/plugins/cache/`) and local
installs (`~/.cursor/plugins/local/`). If both come back for a platform,
prefer `local/`.

### 3. Run it

macOS/Linux:

```bash
bash <path-to-logout.sh>
```

Windows:

```
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "<scripts-dir>\logout.ps1"
```

### 4. Relay the outcome

Relay what the script printed verbatim — don't paraphrase or summarize it.
It always exits `0` (there's nothing that can meaningfully fail here
short of a filesystem error), and covers three cases on its own:

- Credentials removed — logout succeeded.
- No credentials file found — the workspace wasn't logged in to begin with.
- Removed, but `PARADIGM_NETWORKS_URL`/`PARADIGM_NETWORKS_TOKEN` are still
  set in the environment — those env vars take precedence over the file
  (see `pn_config.sh`/`pn_config.ps1`'s `pn_resolve_config`/`Resolve-PnConfig`),
  so Paradigm Networks checks will keep working via them until they're
  unset elsewhere. Don't unset environment variables yourself — that's
  outside this skill's scope; just make sure the user understands why
  they might still appear logged in.
