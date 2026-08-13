# Security Policy

pn-sanitizer gates prompts and file writes in Cursor through your
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

## Response

We aim to acknowledge reports within a few business days and to keep the
reporter updated as a fix is developed.
