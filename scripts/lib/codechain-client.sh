#!/bin/bash
# Code Chain plugin-hooks recording client: records session-start/turns/
# shell-events/session-end for the current Cursor conversation against
# control-server's POST /api/v1/plugin/codechain/* API.
#
# See design-ideas/Codechain_Plugin_Hooks_Design.md for the full design.
# This is a DIFFERENT concern from lib/detection-client.sh's
# POST /api/v1/detections/evaluate: that call gates (returns an allow/warn/
# block verdict a hook must act on); every function here only RECORDS, is
# best-effort, and must never affect a hook's returned JSON or exit code --
# a caller must never let a recording failure change what it was already
# about to return. All failures here are logged (log_debug) and swallowed,
# same "must never be the reason a hook errors" contract as
# pn_record_successful_scan/pn_record_scan_anomaly.
#
# SessionId is Cursor's own conversation_id, used as-is on every call --
# there is no server-side minting or lookup, so there is nothing to cache
# locally either. Every write call below carries Cwd/GitRepoUrl/GitBranch
# directly since the server no longer looks them up from a prior
# registration; each caller already recomputes these locally per hook
# invocation anyway (see check-turn-complete.sh/check-git-event-record.sh).
#
# Multi-value returns are globals, not $(...) captures, matching every other
# helper in this codebase (see CLAUDE.md) -- call these as plain statements.

CODECHAIN_DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/codechain-client.log"

# pn_register_codechain_session <base_url> <access_token> <timeout>
#   <session_id> <cwd> <git_repo_url> <git_branch>
# Fire-and-forget session-start marker. Best-effort: nothing else here
# depends on this call having succeeded (or even having been made) --
# turns/shell-events/close all carry the same session_id directly.
pn_register_codechain_session() {
  local base_url="$1" access_token="$2" timeout="$3" session_id="$4"
  local cwd="$5" git_repo_url="$6" git_branch="$7"

  [[ -z "$session_id" ]] && return 0
  [[ -z "$base_url" ]] && return 0
  [[ -z "$JQ_BIN" ]] && return 0

  local body
  body=$("$JQ_BIN" -n \
    --arg platform "cursor-hooks" \
    --arg sessionId "$session_id" \
    --arg cwd "$cwd" \
    --arg gitRepoUrl "$git_repo_url" \
    --arg gitBranch "$git_branch" \
    '{Platform: $platform, SessionId: $sessionId, Cwd: $cwd, GitRepoUrl: $gitRepoUrl, GitBranch: $gitBranch}')

  local url="${base_url%/}/api/v1/plugin/codechain/sessions"
  local raw
  raw=$(http_post_json "$url" "$body" "$access_token" "$timeout")
  http_post_split_status "$raw"
  if [[ "$HTTP_POST_STATUS" != "200" ]]; then
    log_debug "codechain: session-start recording failed (HTTP ${HTTP_POST_STATUS:-none}) session=$session_id" "$CODECHAIN_DEBUG_LOG_PATH"
  else
    log_debug "codechain: session-start recorded successfully (session=$session_id)" "$CODECHAIN_DEBUG_LOG_PATH"
  fi
}

# pn_record_codechain_turn <base_url> <access_token> <timeout> <session_id>
#   <cwd> <git_repo_url> <git_branch> <prompt> <response> [generation_id] [model]
#
# generation_id is Cursor's own generation_id, when the hook payload carried
# one -- lets control-server match this response to the EXACT prompt-scan
# document it belongs to (see lib/scan-client.sh's header) instead of
# guessing from insertion order. Omit for callers that don't have one; the
# server falls back to its own heuristic.
#
# model is Cursor's own hook-reported model name (the hook payload's
# `.model` field) -- the model that actually produced this response. Stored
# on both RequestPayload and ResponsePayload server-side. Omit when
# unavailable.
pn_record_codechain_turn() {
  local base_url="$1" access_token="$2" timeout="$3" session_id="$4"
  local cwd="$5" git_repo_url="$6" git_branch="$7" prompt="$8" response="$9"
  local generation_id="${10:-}" model="${11:-}"

  [[ -z "$session_id" ]] && return 0
  [[ -z "$base_url" ]] && return 0
  [[ -z "$JQ_BIN" ]] && return 0
  if [[ -z "$prompt" ]] && [[ -z "$response" ]]; then
    return 0
  fi

  local body
  body=$("$JQ_BIN" -n \
    --arg platform "cursor-hooks" \
    --arg cwd "$cwd" \
    --arg gitRepoUrl "$git_repo_url" \
    --arg gitBranch "$git_branch" \
    --arg prompt "$prompt" \
    --arg response "$response" \
    --arg generationId "$generation_id" \
    --arg model "$model" \
    '{Platform: $platform, Cwd: $cwd, GitRepoUrl: $gitRepoUrl, GitBranch: $gitBranch, Prompt: $prompt, Response: $response, GenerationId: $generationId, Model: $model}')

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
#   <session_id> <cwd> <git_repo_url> <git_branch> <command> <output>
#   [generation_id]
#
# generation_id is Cursor's own generation_id, when the hook payload carried
# one -- same correlator pn_record_codechain_turn already documents: lets
# control-server find the EXACT open turn this command's tool_use/tool_result
# pair belongs to, instead of relying solely on its session-scoped "most
# recent open" fallback. Omit for callers that don't have one.
pn_record_codechain_shell_event() {
  local base_url="$1" access_token="$2" timeout="$3" session_id="$4"
  local cwd="$5" git_repo_url="$6" git_branch="$7" command_text="$8" output="$9"
  local generation_id="${10:-}"

  [[ -z "$session_id" ]] && return 0
  [[ -z "$base_url" ]] && return 0
  [[ -z "$JQ_BIN" ]] && return 0
  [[ -z "$command_text" ]] && return 0

  local body
  body=$("$JQ_BIN" -n \
    --arg platform "cursor-hooks" \
    --arg cwd "$cwd" \
    --arg gitRepoUrl "$git_repo_url" \
    --arg gitBranch "$git_branch" \
    --arg command "$command_text" \
    --arg output "$output" \
    --arg generationId "$generation_id" \
    '{Platform: $platform, Cwd: $cwd, GitRepoUrl: $gitRepoUrl, GitBranch: $gitBranch, Command: $command, Output: $output, GenerationId: $generationId}')

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

# pn_close_codechain_session <base_url> <access_token> <timeout> <session_id>
# Fired from sessionEnd. There is no server-side session state to look up
# first -- session_id is Cursor's own conversation_id, so this always has
# something valid to close even if no prior call for this session ever
# succeeded (each write endpoint is independent, per the design above).
pn_close_codechain_session() {
  local base_url="$1" access_token="$2" timeout="$3" session_id="$4"

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
}
