#!/bin/bash
# Local, session-lifecycle metadata -- written on sessionStart, removed on
# sessionEnd. Purely local: nothing here talks to control-server (see
# check-session.sh/check-session-end.sh's own headers for why the
# session-lifecycle API calls that used to live here were removed --
# session_start/session_end markers had no processing/governance/
# observability/reporting consumer). See design-ideas/
# Session_Lifecycle_Simplification_And_Contract_Updates.md.
#
# One file per session, keyed by SessionId, under
# ~/.paradigm-scanner/sessions/<session_id>.json -- SessionId is Cursor's own
# conversation_id, which is already filesystem-safe (no path separators
# observed in practice), but is still not trusted blind: see
# _pn_session_metadata_path's sanitization.
#
# Evaluated as a potential lookup mechanism for other scripts/workflows that
# need session context (cwd/git branch/remote) without re-deriving it from
# Cursor's own hook payload: every current hook already receives its own
# cwd/session id directly on stdin, so there is no existing consumer for
# this today. It's retained as a foundation for a future one (e.g. a skill
# or CLI helper run OUTSIDE a hook invocation, which has no Cursor payload
# to read from) -- pn_read_session_metadata below exists for that purpose,
# not called anywhere yet.

SESSION_METADATA_DIR="${HOME}/.paradigm-scanner/sessions"

# _pn_session_metadata_path <session_id>
# Rejects a session id containing a path separator or leading dot rather
# than trusting Cursor's conversation_id blind -- defense-in-depth against a
# malformed/unexpected payload redirecting the write outside
# SESSION_METADATA_DIR. Prints nothing and returns non-zero on rejection.
_pn_session_metadata_path() {
  local session_id="$1"
  [[ -z "$session_id" ]] && return 1
  case "$session_id" in
    */*|.*) return 1 ;;
  esac
  printf '%s/%s.json' "$SESSION_METADATA_DIR" "$session_id"
}

# pn_write_session_metadata <session_id> <cwd> <git_repo_url> <git_branch>
# Best-effort, atomic (mktemp+chmod+mv, same pattern as
# pn_config.sh's credential writes). Never fails loudly -- sessionStart is
# fire-and-forget context injection regardless of whether this succeeds.
pn_write_session_metadata() {
  local session_id="$1" cwd="$2" git_repo_url="$3" git_branch="$4"
  [[ -z "$JQ_BIN" ]] && return 0
  local path
  path=$(_pn_session_metadata_path "$session_id") || return 0

  mkdir -p "$SESSION_METADATA_DIR" 2>/dev/null || return 0
  chmod 700 "$SESSION_METADATA_DIR" 2>/dev/null || true

  local metadata
  metadata=$("$JQ_BIN" -n \
    --arg sessionId "$session_id" \
    --arg cwd "$cwd" \
    --arg gitRepoUrl "$git_repo_url" \
    --arg gitBranch "$git_branch" \
    --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
    '{SessionId: $sessionId, Cwd: $cwd, GitRepoUrl: $gitRepoUrl, GitBranch: $gitBranch, StartedAt: $startedAt}')

  local temp_file
  temp_file=$(mktemp "${path}.XXXXXX") || return 0
  echo "$metadata" > "$temp_file"
  chmod 600 "$temp_file" 2>/dev/null || true
  mv "$temp_file" "$path" 2>/dev/null || rm -f "$temp_file"

  _pn_prune_stale_session_metadata
}

# pn_remove_session_metadata <session_id>
# Best-effort cleanup on sessionEnd. A missing file (never written, or
# already pruned) is not an error.
pn_remove_session_metadata() {
  local session_id="$1"
  local path
  path=$(_pn_session_metadata_path "$session_id") || return 0
  rm -f "$path" 2>/dev/null || true
}

# pn_read_session_metadata <session_id>
# Prints the stored metadata JSON to stdout, or nothing if none exists.
# Not currently called by any hook -- see this file's header. Provided so a
# future consumer (a skill, a standalone CLI invocation) has something to
# call rather than reinventing the read path.
pn_read_session_metadata() {
  local session_id="$1"
  local path
  path=$(_pn_session_metadata_path "$session_id") || return 0
  [[ -f "$path" ]] && cat "$path" 2>/dev/null
}

# _pn_prune_stale_session_metadata
# Best-effort removal of session files older than 24h -- a session that
# never got a matching sessionEnd (Cursor crash, force-quit) would otherwise
# accumulate here forever. Runs on every write, same "opportunistic cleanup"
# pattern as lib/repo-context.sh's cache. Never fails the caller.
_pn_prune_stale_session_metadata() {
  [[ -d "$SESSION_METADATA_DIR" ]] || return 0
  find "$SESSION_METADATA_DIR" -maxdepth 1 -name '*.json' -mtime +1 -exec rm -f {} + 2>/dev/null || true
}
