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
old login.

## Try it

1. Install the plugin and log in (see above).
2. Submit a prompt or make an edit that your organization's Paradigm
   Networks policy blocks — it should be denied with a message explaining
   why.
3. Submit something that's allowed — it should go through normally.

Check **Cursor Settings → Hooks** or the Hooks output channel if something
does not fire.
