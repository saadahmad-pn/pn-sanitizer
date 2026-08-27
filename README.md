# Paradigm Networks

Paradigm Networks scans what you send to the AI and what it writes to your
files, catching things like destructive commands or unsafe code before
they go through — using your organization's own Paradigm Networks
deployment. It also tags each request with the git repo and branch you're
working in, so findings in your Paradigm Networks dashboard show which
project they came from.

This plugin doesn't ship a scanning backend of its own — it's a client for
your organization's existing Paradigm Networks deployment.

## Privacy and data handling

Since prompt text and file-write content leave your machine to be scanned,
read [SECURITY.md](SECURITY.md#data-handling) before installing — it covers
exactly what's sent, where it's stored, and who can see it.

## Requirements

Works on macOS, Linux, and Windows — nothing to install beyond Cursor
itself. You'll just need your organization's Paradigm Networks deployment
reachable from your machine, e.g. `https://acme.paradigmnetworks.ai`.

## Install

This repo is set up as its own Cursor marketplace, so it can be imported
directly. Requires a Cursor Team/Enterprise plan and dashboard admin
access.

1. In the Cursor dashboard, go to **Dashboard → Plugins**.
2. Under **Team Marketplaces**, click **Add Marketplace**, then choose
   **Import from Repo**.
3. Enter this repo's URL: `https://github.com/saadahmad-pn/pn-sanitizer`.
   Cursor indexes it and lists **Paradigm Networks** as an available
   plugin.
4. Click **Add to Marketplace**, then under **Marketplace Settings** set
   **Marketplace Access** and save. Set the plugin to **Default On** or
   **Required** so teammates get it automatically instead of installing it
   themselves.
5. Optional: enable **Auto Refresh** (requires the Cursor GitHub App
   installed on this repo) so future updates roll out automatically.
   Otherwise, click **Refresh** after each update.

## Configuration

### Log in (one time per machine)

The first time you use Cursor after installing, you'll be asked for your
organization's Paradigm Networks URL. Don't have one yet? Sign up at
https://signup.claude-demo.paradigmnetworks.ai/signup.

Confirm, and your browser opens to sign you in — nothing to copy or paste.
Once you're signed in, Cursor remembers it on this machine.

To switch organizations later, just ask to log in again — it replaces the
old login.

## Try it

1. Install the plugin and log in (see above).
2. Submit a prompt or make an edit that your organization's Paradigm
   Networks policy blocks — it should be denied with a message explaining
   why.
3. Submit something that's allowed — it should go through normally.

If something doesn't fire as expected, check **Cursor Settings → Hooks** or
the Hooks output channel.

## Support

Found a bug or have a question? Open an issue on this repository, or reach
out to your Paradigm Networks contact. Security issues should be reported
privately — see [SECURITY.md](SECURITY.md).

For contributing changes to this plugin itself, see
[CONTRIBUTING.md](CONTRIBUTING.md).
