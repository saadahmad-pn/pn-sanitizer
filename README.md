# Paradigm Networks

Paradigm Networks plugin scans what you send to Cursor. It catches things like destructive commands or unsafe code before
they go through.



## Requirements

Works on macOS, Linux, and Windows — nothing to install beyond Cursor
itself. You'll just need your organization's Paradigm Networks service
reachable from your machine, e.g. `https://acme.paradigmnetworks.ai`.

## Install

This repo is set up as its own Cursor marketplace, so it can be imported
directly. Requires a Cursor Team/Enterprise plan and dashboard admin
access.

1. In the Cursor dashboard, go to **Dashboard → Customize**.
2. Under **Browse Marketplaces**, click **Add Marketplace**, then choose
   **Import from Github**.
3. Enter this repo's URL: `https://github.com/saadahmad-pn/pn-sanitizer`.
   Cursor indexes it and lists **Paradigm Networks** as an available
   plugin.
4. Click **Add to Marketplace**, then under **Marketplace Settings** set
   **Marketplace Access** and save. Set the plugin to **Default On** or
   **Required** so teammates get it automatically instead of installing it
   themselves.


## Configuration

### Log in (one time per machine)

The first time you use Cursor after installing, you'll be asked for your
organization's Paradigm Networks URL. Don't have one yet? Sign up at
https://signup.claude-demo.paradigmnetworks.ai/signup.

Confirm, and your browser opens to sign you in — nothing to copy or paste.
Once you're signed in, Cursor remembers it on this machine.

To switch organizations later, just ask to log in again — it replaces the
old login. To remove your login from this machine entirely, ask to log
out — the **paradigmnetworks-logout** skill handles it.

### Changing the scanning model

Prompts and writes are scanned using a default model out of the box.
Ask "what models are available" any time to see which models your
organization can use and which one is currently active, or to switch to
a different one — the **paradigmnetworks-models** skill handles both.

## Try it

1. Install the plugin and log in (see above).
2. Submit a prompt or make an edit that your organization's Paradigm
   Networks policy blocks — it should be denied with a message explaining
   why.
3. Submit something that's allowed — it should go through normally.
4. Ask the agent to `git push`, `git commit`, or run `gh pr create` in a
   repo containing a policy-violating change — it should be denied before
   the operation runs, with a message explaining why.

Check **Cursor Settings → Hooks** or the Hooks output channel if something
does not fire.

## Limitations

- **File edits made through Cursor's own Write tool, and `git push`/`git
  commit`/`gh pr create` run through the agent's Shell tool, are scanned
  today.** Other commands run in the terminal (e.g. `cat >`, `sed -i`) are
  not — a change made that way goes through unscanned.
- **The git push/commit/PR hooks only fire when the Cursor agent itself
  runs the command.** Typing `git push` (or the others) directly into a
  terminal panel yourself, rather than asking the agent to run it, is
  invisible to these hooks — the same blind spot the existing prompt/write
  hooks already have for anything outside Cursor's own tool calls.
- **If the scanning service can't be reached, prompts are allowed
  through by default; file writes and git push/commit/PR-create are
  blocked by default.** This asymmetry is intentional — it exists so a
  not-yet-logged-in user is never blocked from sending their very first
  message — but it also means someone who can block this machine's
  network access to the scanner can silently disable prompt scanning
  while write and git-event scanning stay in their normal (blocking)
  state.

## More

- [Security policy](SECURITY.md) — how to report a vulnerability
- [Changelog](CHANGELOG.md)
- [License](LICENSE) — MIT
