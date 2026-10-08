# Paradigm Networks for Cursor

Paradigm Networks checks what happens in your Cursor sessions against your
organization's security policy. It catches things like destructive commands
or unsafe code before they go through.

> **A Paradigm Networks account is required.** The plugin does nothing on its
> own: every check is made by your organization's Paradigm Networks
> deployment (for example `https://acme.paradigmnetworks.ai`). New to
> Paradigm Networks? [Sign up](https://signup.claude-demo.paradigmnetworks.ai/signup).

## What it does

- **Checks prompts** before they are sent to the model.
- **Checks tool calls** before they run: file edits, shell commands and MCP
  tool calls made by the agent.
- **Checks git operations.** When the agent runs `git push`, `git commit` or
  `gh pr create`, the changed files are checked first and the operation is
  denied if they violate policy.
- **Records the conversation** (prompts, agent responses and tool results) in
  your organization's Paradigm Networks deployment, where your team can
  review it.

Blocked actions are denied with a message explaining why.

## Install

### From the Cursor Marketplace

Search for **Paradigm Networks** in the Cursor Marketplace, or run:

```
/add-plugin paradigm-scanner
```

### For team admins

Cursor Team and Enterprise admins can also import this repo as a private
marketplace and make the plugin **Default On** or **Required**, so teammates
get it automatically:

1. In the Cursor dashboard, go to **Dashboard → Customize**.
2. Under **Browse Marketplaces**, click **Add Marketplace**, then choose
   **Import from Github**.
3. Enter this repo's URL: `https://github.com/saadahmad-pn/pn-sanitizer`.
4. Click **Add to Marketplace**, then under **Marketplace Settings** set
   **Marketplace Access** and save.

### Requirements

- macOS, Linux or Windows.
- macOS/Linux: `bash`, `curl`, `openssl` and `nc` (preinstalled on most
  systems). `jq` is bundled for common platforms.
- Windows: PowerShell (built in).
- Your organization's Paradigm Networks service must be reachable from your
  machine.

## Log in (one time per machine)

The first time you use Cursor after installing, you'll be asked for your
organization's Paradigm Networks URL. Confirm, and your browser opens to sign
you in. Nothing to copy or paste. Cursor remembers the login on this machine.

To switch organizations, ask the agent to log in again. It replaces the old
login. To remove your login from this machine, ask the agent to log out (the
**paradigmnetworks-logout** skill handles it).

## What's in the plugin

| Component | Purpose |
| --- | --- |
| `hooks/hooks.json` | Hooks for session start/end, prompt submit, tool calls and agent responses. These do the checking and recording. |
| `skills/paradigmnetworks-login` | Logs this machine in to your Paradigm Networks deployment. |
| `skills/paradigmnetworks-logout` | Removes the stored login from this machine. |
| `rules/pn-login-check.mdc` | Makes the agent confirm you're logged in on the first message of a session. |
| `scripts/` | The scripts the hooks run (Bash for macOS/Linux, PowerShell for Windows). |

## Data handling

The plugin sends data **only to your organization's own Paradigm Networks
deployment**, the URL you log in with. It does not send anything to a
shared or third-party server operated by the plugin.

What is sent, and when:

| Data | When |
| --- | --- |
| Your prompt text | Before each prompt is submitted |
| The agent's response | After each agent response |
| Tool call inputs (file edits, shell commands, MCP arguments) and their results | Before and after each tool call |
| The surrounding conversation for the current turn | With a tool call, so intent can be assessed |
| Contents of changed files | When the agent runs `git push`, `git commit` or `gh pr create` |
| Working directory, git remote URL, branch and model name | With each of the above |

Your login is stored in `~/.pn/credentials.json` (readable only by you).

What the plugin writes on your machine:

- `~/.paradigm-scanner/`: debug logs, an audit log, session metadata and
  caches.
- In each workspace, `.cursor/rules/paradigm-repo-context.mdc`, which lists the
  workspace's git remotes and branches so requests can be attributed to a
  repo. The plugin adds this path to the workspace's `.gitignore`.

Retention and use of the data on the server side is governed by your
organization's agreement with Paradigm Networks. See our
[Privacy Policy](https://paradigmnetworks.ai/privacy-policy/) and
[Terms of Service](https://paradigmnetworks.ai/terms/).

## Try it

1. Install the plugin and log in.
2. Submit a prompt or make an edit that your organization's policy blocks. It
   should be denied with a message explaining why.
3. Submit something that's allowed. It should go through normally.
4. Ask the agent to `git push`, `git commit` or run `gh pr create` in a repo
   containing a policy-violating change. It should be denied before the
   operation runs.

Check **Cursor Settings → Hooks** or the Hooks output channel if something
does not fire.

## Limitations

- **File edits made through Cursor's own Write tool, and `git push`/`git
  commit`/`gh pr create` run through the agent's Shell tool, are scanned
  today.** Other commands run in the terminal (e.g. `cat >`, `sed -i`) are
  not, so a change made that way goes through unscanned.
- **The git push/commit/PR hooks only fire when the Cursor agent itself
  runs the command.** Typing `git push` (or the others) directly into a
  terminal panel yourself is invisible to these hooks.
- **If the scanning service can't be reached, prompts are allowed
  through by default; file writes and git push/commit/PR-create are
  blocked by default.** This is intentional, so a not-yet-logged-in user is
  never blocked from sending their very first message. It also means someone
  who can block this machine's network access to the scanner can silently
  disable prompt scanning while write and git-event scanning stay blocking.

## Support

- Questions and bugs: plugins@paradigmnetworks.ai or open an issue on this
  repo.
- Security issues: see [SECURITY.md](SECURITY.md). Please don't open a public
  issue.

## More

- [Changelog](CHANGELOG.md)
- [License](LICENSE) (MIT)
