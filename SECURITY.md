# Security Policy

paradigm-scanner gates prompts and file writes in Cursor through your
organization's CodeDefense scanning backend. Because it sits in that path,
we treat vulnerability reports in this repository seriously and want to
hear about them.

## Reporting a vulnerability

Please report security issues privately using
[GitHub's private security advisory feature](../../security/advisories/new)
on this repository, rather than opening a public issue. This lets us assess
and fix the problem before it's publicly disclosed.

Include, where possible:

- A description of the issue and its potential impact.
- Steps to reproduce it, or a proof of concept.
- The plugin version and platform (macOS/Linux/Windows) you tested on.

## Scope

In scope: the hook scripts (`scripts/`), the plugin manifest and hook
configuration (`.cursor-plugin/`, `hooks/`), and the login/credential flow.

Out of scope: the CodeDefense scanning backend itself (a separate,
organization-hosted service this plugin talks to, not part of this
repository).

## Data handling

This plugin sends the text of submitted prompts and the content of file
writes to your organization's CodeDefense deployment so it can be scanned
before being allowed through.

- **Transport:** all traffic to CodeDefense is sent over HTTPS.
- **Storage:** CodeDefense is a tenant-based product — scanned content is
  stored indefinitely in your organization's own tenant database (provided
  by Paradigm Networks) and is visible on your tenant's dashboard. Data from
  different tenants isn't shared or mixed.
- **Disclosure:** this data flow is already covered under Paradigm Networks'
  main product customer agreement — installing this plugin doesn't introduce
  a separate or additional disclosure.

If your organization has its own data-handling or compliance review process
for tools that send code to an external service, this section should cover
what it needs — reach out to Paradigm Networks if you need more detail than
what's here.

## Response

We aim to acknowledge reports within a few business days and to keep the
reporter updated as a fix is developed.
