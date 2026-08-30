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

- **Never guess or list models from memory/training data — always fetch
  the list live via the script in step 2.** The real list is different per
  organization and changes over time (new models ship, others get
  deprecated), so anything from memory is likely wrong.
- **Never write to `credentials.json` (or anywhere else) directly.** Always
  go through `set-model.sh`/`.ps1` (step 4) to actually change the model —
  it validates the id against the live list and writes the file atomically.
  Hand-editing it risks corrupting the file or silently saving an id the
  org doesn't actually have access to.
- Don't fabricate a current-model answer — the script in step 2 always
  prints the real one first (`Currently scanning with: ...`); relay that
  line, don't guess from memory or from a stale answer given earlier in
  the conversation.
- **A Cursor plugin Settings field named "AI model used for scanning" also
  exists, but do not tell users to use it.** It looks like the obvious way
  to do this, but it doesn't actually work — Cursor does not deliver
  plugin Settings values to hook scripts (confirmed directly, see
  `check-prompt.sh`'s comment on its own model-resolution logic for how).
  If a user mentions that field, tell them plainly it doesn't do anything
  right now and that this skill is the real way to change it.

## Workflow

### 1. Locate the scripts

Same reasoning as the login skill: there's no environment variable that
tells you where the plugin is installed, so don't guess the path. Locate
both now — you'll need `paradigmnetworks-models` for step 2 regardless of
what the user asked for, and `set-model` only if they end up wanting to
change it (step 4), but there's no harm finding both up front.

```bash
find ~/.cursor/plugins -path "*/paradigm-scanner/scripts/paradigmnetworks-models.sh" 2>/dev/null
find ~/.cursor/plugins -path "*/paradigm-scanner/scripts/paradigmnetworks-models.ps1" 2>/dev/null
find ~/.cursor/plugins -path "*/paradigm-scanner/scripts/set-model.sh" 2>/dev/null
find ~/.cursor/plugins -path "*/paradigm-scanner/scripts/set-model.ps1" 2>/dev/null
```

This covers both marketplace installs (`~/.cursor/plugins/cache/`) and local
installs (`~/.cursor/plugins/local/`). If both come back for a platform,
prefer `local/`.

### 2. Run the models script and relay the output verbatim

macOS/Linux:

```bash
bash <path-to-paradigmnetworks-models.sh>
```

Windows:

```
<scripts-dir>\run-powershell.cmd <scripts-dir>\paradigmnetworks-models.ps1
```

This hits the live API, so it reflects exactly what this org actually has
access to right now — the first line is the real current model
(`Currently scanning with: ...`), followed by the full list. **Relay
everything it printed, don't summarize, trim, or cherry-pick which models
to show.**

If it fails with a "not configured" error, tell the user to run the
`paradigmnetworks-login` skill first, then try again — don't run
`set-model` in this state either, it will fail the same way.

If the user only wanted to know what's available or currently active,
you're done here — steps 3-4 are only for an actual change request.

### 3. Confirm exactly which model they want

Get the model **id** (the first column from step 2's output, e.g.
`anthropic/claude-sonnet-4-6`), not the display name (e.g. "Claude Sonnet
4.6") — those are two different strings and only the id is valid input to
`set-model`. If the user names a model by its display name or something
close to one, match it against the list from step 2 and confirm the id
with them before proceeding, rather than guessing which one they meant.

### 4. Run set-model to actually save it

macOS/Linux:

```bash
bash <path-to-set-model.sh> "<model-id>"
```

Windows:

```
<scripts-dir>\run-powershell.cmd <scripts-dir>\set-model.ps1 -Model "<model-id>"
```

Relay its output verbatim. It re-validates the id against the live list
itself before saving (a second check is fine — cheap, and it's the last
line of defense against a typo actually getting saved), and it's what
Cursor Settings → Plugins → Paradigm Networks → "AI model used for
scanning" *looks* like it should do but doesn't (see "What not to do"
above). On success, the new model takes effect on the very next prompt or
write — no restart or re-login needed. On failure, relay the actual error
(e.g. an unrecognized model id, or not configured) rather than assuming it
worked.
