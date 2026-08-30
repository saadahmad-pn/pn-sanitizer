---
name: paradigmnetworks-models
description: Show which AI models are available to the user's Paradigm Networks org, or tell them how to change which model is used for scanning prompts and writes. Use when the user asks what models are available, which model is scanning their code, how to switch models, or mentions the "AI model used for scanning" plugin setting.
---

# Paradigm Networks models

## When to use this

- The user asks what AI models are available to them, or to their
  organization.
- The user asks which model is currently used to scan their prompts/writes.
- The user wants to change or switch the scanning model.

## What not to do

- Don't guess or list models from memory/training data. The real list is
  different per organization and changes over time (new models ship,
  others get deprecated) — always fetch it live via the script below.
- Don't try to set the model yourself by writing to a file, environment
  variable, or credentials.json. There is nowhere in this plugin's local
  files to persist this — it's a native Cursor setting
  (`PARADIGM_NETWORKS_MODEL`), and only the user (or their admin) can set
  it, through Cursor's own Settings UI. Your job is to show the options and
  tell them where to paste the one they want, not to change it for them.
- Don't fabricate a current-model answer. If `PARADIGM_NETWORKS_MODEL`
  isn't set in the environment, say plainly that the default is in use
  (see step 1) rather than guessing which one.

## Workflow

### 1. Check whether Paradigm Networks is configured, and what model is set

```bash
echo "PARADIGM_NETWORKS_MODEL=${PARADIGM_NETWORKS_MODEL:-<not set, using the default>}"
```

Windows (PowerShell):

```powershell
Write-Output "PARADIGM_NETWORKS_MODEL=$(if ($env:PARADIGM_NETWORKS_MODEL) { $env:PARADIGM_NETWORKS_MODEL } else { '<not set, using the default>' })"
```

If Paradigm Networks isn't configured at all yet (no login), the models
script below will fail with a clear "not configured" error — if you already
know that's the case (e.g. from a recent hook message), just say so and
point the user to the `paradigmnetworks-login` skill instead of running the
script.

### 2. Locate the models script

Same reasoning as the login skill: there's no environment variable that
tells you where the plugin is installed, so don't guess the path.

```bash
find ~/.cursor/plugins -path "*/paradigm-scanner/scripts/paradigmnetworks-models.sh" 2>/dev/null
find ~/.cursor/plugins -path "*/paradigm-scanner/scripts/paradigmnetworks-models.ps1" 2>/dev/null
```

This covers both marketplace installs (`~/.cursor/plugins/cache/`) and local
installs (`~/.cursor/plugins/local/`). If both come back for a platform,
prefer `local/`.

### 3. Run it and relay the output verbatim

macOS/Linux:

```bash
bash <path-to-paradigmnetworks-models.sh>
```

Windows:

```
<scripts-dir>\run-powershell.cmd <scripts-dir>\paradigmnetworks-models.ps1
```

This hits the live API, so it reflects exactly what this org actually has
access to right now — just show the user what it printed, don't summarize
or trim the list.

If it fails with a "not configured" error, tell the user to run the
`paradigmnetworks-login` skill first, then try again.

### 4. If the user wants to change the model

Tell them, in plain terms, where to do it — you cannot set this for them:

> Go to **Cursor Settings → Plugins → Paradigm Networks**, and paste the
> model ID (not the display name — the exact string from the list above,
> e.g. `anthropic/claude-sonnet-4-6`) into **"AI model used for scanning"**.
> Leave it blank to use the default.

There's nothing further for you to do after telling them this — the change
takes effect immediately once they save it, no restart or re-login needed.
