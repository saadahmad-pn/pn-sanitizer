#!/bin/bash
# Code Chain plugin-hooks recording client: registers/reuses a Code Chain
# session for the current Cursor conversation_id, then records
# turns/shell-events/close against it via control-server's
# POST /api/v1/plugin/codechain/* API.
#
# See design-ideas/Codechain_Plugin_Hooks_Design.md for the full design.
# This is a DIFFERENT concern from lib/detection-client.sh's
# POST /api/v1/detections/evaluate: that call gates (returns an allow/warn/
# block verdict a hook must act on); every function here only RECORDS, is
# best-effort, and must never affect a hook's returned JSON or exit code —
# a caller must never let a recording failure change what it was already
# about to return. All failures here are logged (log_debug) and swallowed,
# same "must never be the reason a hook errors" contract as
# pn_record_successful_scan/pn_record_scan_anomaly.
#
# Multi-value returns are globals, not $(...) captures, matching every other
# helper in this codebase (see CLAUDE.md) — call these as plain statements.

CODECHAIN_SESSION_CACHE_DIR="${HOME}/.paradigm-scanner/codechain-sessions"
CODECHAIN_DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/codechain-client.log"

# sanitize_client_session_id keeps only characters safe as a bare filename --
# ClientSessionId is Cursor's own conversation_id (a UUID) in practice, but
# this is defense in depth against anything else ever landing here, same
# spirit as git-utils.sh's sanitize_git_value.
sanitize_client_session_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

_codechain_cache_path() {
  local client_session_id
  client_session_id=$(sanitize_client_session_id "$1")
  echo "${CODECHAIN_SESSION_CACHE_DIR}/${client_session_id}.txt"
}

_codechain_cache_read() {
  local cache_path
  cache_path=$(_codechain_cache_path "$1")
  [[ -f "$cache_path" ]] && cat "$cache_path" 2>/dev/null
}

# Atomic write, same mktemp+chmod+mv pattern as pn_save_credentials.
_codechain_cache_write() {
  local client_session_id="$1"
  local session_id="$2"
  mkdir -p "$CODECHAIN_SESSION_CACHE_DIR" 2>/dev/null
  local cache_path tmp_path
  cache_path=$(_codechain_cache_path "$client_session_id")
  tmp_path=$(mktemp "${cache_path}.XXXXXX" 2>/dev/null) || return 1
  echo -n "$session_id" > "$tmp_path"
  chmod 600 "$tmp_path" 2>/dev/null
  mv "$tmp_path" "$cache_path"
}

# pn_get_codechain_session_id <base_url> <access_token> <timeout>
#   <client_session_id> <cwd> <git_repo_url> <git_branch> <platform>
# Sets PN_CODECHAIN_SESSION_ID to the server-minted SessionId, or "" on any
# failure (missing config, network error, non-2xx, malformed response) --
# every caller must treat an empty result as "recording unavailable this
# call" and proceed with whatever it was already doing, never block on it.
# Idempotent: checks a local cache keyed on client_session_id first, so a
# session already registered this run costs no network call on subsequent
# hook invocations (each hook is a separate process).
pn_get_codechain_session_id() {
  local base_url="$1" access_token="$2" timeout="$3" client_session_id="$4"
  local cwd="$5" git_repo_url="$6" git_branch="$7" platform="${8:-cursor-hooks}"

  PN_CODECHAIN_SESSION_ID=""
  [[ -z "$client_session_id" ]] && return 0

  local cached
  cached=$(_codechain_cache_read "$client_session_id")
  if [[ -n "$cached" ]]; then
    PN_CODECHAIN_SESSION_ID="$cached"
    log_debug "codechain: reusing cached session id (client=$client_session_id session=$cached)" "$CODECHAIN_DEBUG_LOG_PATH"
    return 0
  fi

  [[ -z "$base_url" ]] && return 0
  [[ -z "$JQ_BIN" ]] && return 0

  local body
  body=$("$JQ_BIN" -n \
    --arg platform "$platform" \
    --arg clientSessionId "$client_session_id" \
    --arg cwd "$cwd" \
    --arg gitRepoUrl "$git_repo_url" \
    --arg gitBranch "$git_branch" \
    '{Platform: $platform, ClientSessionId: $clientSessionId, Cwd: $cwd, GitRepoUrl: $gitRepoUrl, GitBranch: $gitBranch}')

  local url="${base_url%/}/api/v1/plugin/codechain/sessions"
  local raw
  raw=$(http_post_json "$url" "$body" "$access_token" "$timeout")
  http_post_split_status "$raw"

  if [[ "$HTTP_POST_STATUS" != "200" ]]; then
    log_debug "codechain: session registration failed (HTTP ${HTTP_POST_STATUS:-none}) url=$url" "$CODECHAIN_DEBUG_LOG_PATH"
    return 0
  fi

  local session_id
  session_id=$(echo "$HTTP_POST_BODY" | "$JQ_BIN" -r '.SessionId // ""' 2>/dev/null)
  [[ -z "$session_id" ]] && return 0

  _codechain_cache_write "$client_session_id" "$session_id"
  PN_CODECHAIN_SESSION_ID="$session_id"
  log_debug "codechain: registered new session (client=$client_session_id session=$session_id)" "$CODECHAIN_DEBUG_LOG_PATH"
  return 0
}

# pn_record_codechain_turn <base_url> <access_token> <timeout> <session_id>
#   <prompt> <response>
# Best-effort, no return value consulted by callers beyond nothing-to-do-on-
# failure — see file header.
pn_record_codechain_turn() {
  local base_url="$1" access_token="$2" timeout="$3" session_id="$4"
  local prompt="$5" response="$6"

  [[ -z "$session_id" ]] && return 0
  [[ -z "$JQ_BIN" ]] && return 0
  if [[ -z "$prompt" ]] && [[ -z "$response" ]]; then
    return 0
  fi

  local body
  body=$("$JQ_BIN" -n --arg prompt "$prompt" --arg response "$response" \
    '{Prompt: $prompt, Response: $response}')

  local url="${base_url%/}/api/v1/plugin/codechain/sessions/${session_id}/turns"
  local raw
  raw=$(http_post_json "$url" "$body" "$access_token" "$timeout")
  http_post_split_status "$raw"
  if [[ "$HTTP_POST_STATUS" != "204" ]]; then
    log_debug "codechain: turn recording failed (HTTP ${HTTP_POST_STATUS:-none}) session=$session_id" "$CODECHAIN_DEBUG_LOG_PATH"
  else
    log_debug "codechain: turn recorded successfully (session=$session_id, prompt_len=${#prompt}, response_len=${#response})" "$CODECHAIN_DEBUG_LOG_PATH"
  fi
}

# pn_record_codechain_shell_event <base_url> <access_token> <timeout>
#   <session_id> <command> <output> <cwd>
pn_record_codechain_shell_event() {
  local base_url="$1" access_token="$2" timeout="$3" session_id="$4"
  local command_text="$5" output="$6" cwd="$7"

  [[ -z "$session_id" ]] && return 0
  [[ -z "$JQ_BIN" ]] && return 0
  [[ -z "$command_text" ]] && return 0

  local body
  body=$("$JQ_BIN" -n --arg command "$command_text" --arg output "$output" --arg cwd "$cwd" \
    '{Command: $command, Output: $output, Cwd: $cwd}')

  local url="${base_url%/}/api/v1/plugin/codechain/sessions/${session_id}/shell-events"
  local raw
  raw=$(http_post_json "$url" "$body" "$access_token" "$timeout")
  http_post_split_status "$raw"
  if [[ "$HTTP_POST_STATUS" != "204" ]]; then
    log_debug "codechain: shell-event recording failed (HTTP ${HTTP_POST_STATUS:-none}) session=$session_id" "$CODECHAIN_DEBUG_LOG_PATH"
  else
    log_debug "codechain: shell-event recorded successfully (session=$session_id, command=${command_text:0:80})" "$CODECHAIN_DEBUG_LOG_PATH"
  fi
}

# pn_close_codechain_session <base_url> <access_token> <timeout> <client_session_id>
# Fired from sessionEnd. Looks up the cached SessionId for client_session_id
# itself (sessionEnd's own payload carries no guarantee the caller already
# resolved one) -- a session that never touched git/prompts has no cache
# entry, which is a normal no-op, not an error.
pn_close_codechain_session() {
  local base_url="$1" access_token="$2" timeout="$3" client_session_id="$4"

  [[ -z "$client_session_id" ]] && return 0
  local session_id
  session_id=$(_codechain_cache_read "$client_session_id")
  [[ -z "$session_id" ]] && return 0
  [[ -z "$base_url" ]] && return 0

  local url="${base_url%/}/api/v1/plugin/codechain/sessions/${session_id}/close"
  local raw
  raw=$(http_post_json "$url" "{}" "$access_token" "$timeout")
  http_post_split_status "$raw"
  if [[ "$HTTP_POST_STATUS" != "204" ]]; then
    log_debug "codechain: session close failed (HTTP ${HTTP_POST_STATUS:-none}) session=$session_id" "$CODECHAIN_DEBUG_LOG_PATH"
  else
    log_debug "codechain: session closed successfully (session=$session_id)" "$CODECHAIN_DEBUG_LOG_PATH"
  fi

  rm -f "$(_codechain_cache_path "$client_session_id")" 2>/dev/null
}
