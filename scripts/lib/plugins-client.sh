#!/bin/bash
# Client for control-server's standardized plugin API,
# POST /api/v1/plugins/sessions/{id}/*, replacing lib/codechain-client.sh
# (recording), lib/scan-client.sh (gating), and lib/detection-client.sh
# (git.push/git.commit/git.pr_create gating) with one consolidated client
# matching the standardized domains -- see design-ideas/
# Plugin_API_Standardization_And_Hook_Consolidation_Design.md.
#
# Two domains today, each carrying an Action field for its lifecycle stage
# (before_prompt/after_prompt, before_tool_call/after_tool_call). A third,
# before_shell_execution/after_shell_execution, existed briefly but was
# retired -- git push/commit gating is now handled inside the tool-calls
# domain instead (see pn_build_git_diff_files_json below and design-ideas/
# Shell_Execution_vs_Tool_Call_Hook_Coverage_Validation.md). This vocabulary
# is DIFFERENT from Cursor's own hook event names (preToolUse,
# beforeShellExecution, ...) -- see the design doc §0.4 for why the two are
# kept distinct.
#
# session/close and file-events are unchanged in shape from the old
# codechain-client.sh (still their own resources, not folded into a domain)
# -- see design doc §0/item 3 on file-events staying deferred.
#
# Multi-value returns are globals, not $(...) captures, matching every other
# helper in this codebase (see CLAUDE.md) -- call these as plain statements.

PLUGINS_DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/plugins-client.log"

# is_binary_file <path>
# An empty file is never binary. Relies on grep's own binary-file detection
# (-I) against a pattern that matches any line, including blank ones --
# present in both BSD grep (macOS) and GNU grep (Linux), so nothing
# GNU-only or an external `file` binary is needed.
#
# Deliberately NOT a bash-variable NUL-byte comparison: bash strings are
# NUL-terminated C strings internally, so command substitution silently
# truncates output at the first NUL byte, making that approach misclassify
# every real binary file as text (confirmed live against the original
# implementation this replaced).
is_binary_file() {
  local path="$1"
  [[ -s "$path" ]] || return 1
  ! grep -Iq '' "$path" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Session lifecycle
# ---------------------------------------------------------------------------

# pn_register_plugin_session <base_url> <access_token> <timeout> <session_id>
#   <cwd> <git_repo_url> <git_branch>
# Fire-and-forget session-start marker.
pn_register_plugin_session() {
  local base_url="$1" access_token="$2" timeout="$3" session_id="$4"
  local cwd="$5" git_repo_url="$6" git_branch="$7"

  [[ -z "$session_id" || -z "$base_url" || -z "$JQ_BIN" ]] && return 0

  local body
  body=$("$JQ_BIN" -n \
    --arg platform "cursor-hooks" \
    --arg sessionId "$session_id" \
    --arg cwd "$cwd" \
    --arg gitRepoUrl "$git_repo_url" \
    --arg gitBranch "$git_branch" \
    '{Platform: $platform, SessionId: $sessionId, Cwd: $cwd, GitRepoUrl: $gitRepoUrl, GitBranch: $gitBranch}')

  local url="${base_url%/}/api/v1/plugins/sessions"
  local raw
  raw=$(http_post_json "$url" "$body" "$access_token" "$timeout")
  http_post_split_status "$raw"
  if [[ "$HTTP_POST_STATUS" != "200" ]]; then
    log_debug "plugins: session-start recording failed (HTTP ${HTTP_POST_STATUS:-none}) session=$session_id" "$PLUGINS_DEBUG_LOG_PATH"
  else
    log_debug "plugins: session-start recorded successfully (session=$session_id)" "$PLUGINS_DEBUG_LOG_PATH"
  fi
}

# pn_close_plugin_session <base_url> <access_token> <timeout> <session_id>
pn_close_plugin_session() {
  local base_url="$1" access_token="$2" timeout="$3" session_id="$4"
  [[ -z "$session_id" || -z "$base_url" ]] && return 0

  local url="${base_url%/}/api/v1/plugins/sessions/${session_id}/close"
  local raw
  raw=$(http_post_json "$url" "{}" "$access_token" "$timeout")
  http_post_split_status "$raw"
  if [[ "$HTTP_POST_STATUS" != "204" ]]; then
    log_debug "plugins: session close failed (HTTP ${HTTP_POST_STATUS:-none}) session=$session_id" "$PLUGINS_DEBUG_LOG_PATH"
  else
    log_debug "plugins: session closed successfully (session=$session_id)" "$PLUGINS_DEBUG_LOG_PATH"
  fi
}

# _pn_reset_plugin_result <prefix>
# Clears the PN_<PREFIX>_* globals every domain call below sets, so a
# caller never accidentally reads a stale value from a previous call.
_pn_reset_plugin_result() {
  local p="$1"
  eval "PN_${p}_STATUS=''; PN_${p}_HTTP_STATUS=''; PN_${p}_ACTION=''; PN_${p}_MESSAGE=''; PN_${p}_THREAT_LEVEL=''; PN_${p}_TOOL_USE_ID=''"
}

# _pn_parse_plugin_response <prefix>
# Shared response-parsing tail for the gating domains (prompts, tool-calls,
# shell-executions): all three return the same {action_to_take, message,
# overall_threat_level, triggered_by, ToolUseId?} shape. Reads
# $HTTP_POST_STATUS/$HTTP_POST_BODY (already split) and $curl_exit, $url.
_pn_parse_plugin_response() {
  local p="$1" curl_exit="$2" url="$3"

  if [[ $curl_exit -eq 28 ]]; then
    eval "PN_${p}_STATUS=timeout"
    log_debug "plugins: timeout after call to $url" "$PLUGINS_DEBUG_LOG_PATH"
    return 0
  elif [[ $curl_exit -ne 0 ]]; then
    eval "PN_${p}_STATUS=unreachable"
    log_debug "plugins: unreachable (curl exit=$curl_exit) | url=$url" "$PLUGINS_DEBUG_LOG_PATH"
    return 0
  fi

  eval "PN_${p}_HTTP_STATUS=\$HTTP_POST_STATUS"
  if [[ "$HTTP_POST_STATUS" != 2* ]]; then
    eval "PN_${p}_STATUS=http_error"
    log_debug "plugins: HTTP error status=$HTTP_POST_STATUS | url=$url" "$PLUGINS_DEBUG_LOG_PATH"
    return 0
  fi

  if ! echo "$HTTP_POST_BODY" | "$JQ_BIN" empty 2>/dev/null; then
    eval "PN_${p}_STATUS=invalid_json"
    log_debug "plugins: invalid JSON response | url=$url" "$PLUGINS_DEBUG_LOG_PATH"
    return 0
  fi

  local action message threat tool_use_id
  action=$(echo "$HTTP_POST_BODY" | "$JQ_BIN" -r '.action_to_take // ""')
  message=$(echo "$HTTP_POST_BODY" | "$JQ_BIN" -r '.message // ""')
  threat=$(echo "$HTTP_POST_BODY" | "$JQ_BIN" -r '.overall_threat_level // ""')
  tool_use_id=$(echo "$HTTP_POST_BODY" | "$JQ_BIN" -r '.ToolUseId // ""')
  eval "PN_${p}_ACTION=\$action; PN_${p}_MESSAGE=\$message; PN_${p}_THREAT_LEVEL=\$threat; PN_${p}_TOOL_USE_ID=\$tool_use_id; PN_${p}_STATUS=ok"
  log_debug "plugins: ok action=$action threat_level=$threat | url=$url" "$PLUGINS_DEBUG_LOG_PATH"
}

# ---------------------------------------------------------------------------
# Prompts domain
# ---------------------------------------------------------------------------

# pn_plugin_before_prompt <base_url> <access_token> <timeout> <session_id>
#   <cwd> <git_repo_url> <git_branch> <text> [generation_id] [model]
#
# Sets PN_PROMPT_STATUS/HTTP_STATUS/ACTION/MESSAGE/THREAT_LEVEL -- same
# contract lib/scan-client.sh's pn_scan_text used to.
pn_plugin_before_prompt() {
  local base_url="$1" access_token="$2" timeout="$3" session_id="$4"
  local cwd="$5" git_repo_url="$6" git_branch="$7" text="$8"
  local generation_id="${9:-}" model="${10:-}"

  _pn_reset_plugin_result PROMPT
  if [[ -z "$session_id" || -z "$JQ_BIN" ]]; then
    PN_PROMPT_STATUS="no_session"
    return 0
  fi

  local body
  body=$("$JQ_BIN" -n \
    --arg action "before_prompt" \
    --arg platform "cursor-hooks" \
    --arg cwd "$cwd" --arg gitRepoUrl "$git_repo_url" --arg gitBranch "$git_branch" \
    --arg text "$text" --arg generationId "$generation_id" --arg model "$model" \
    '{Action: $action, Platform: $platform, Cwd: $cwd, GitRepoUrl: $gitRepoUrl, GitBranch: $gitBranch, Text: $text, GenerationId: $generationId, Model: $model}')

  local url="${base_url%/}/api/v1/plugins/sessions/${session_id}/prompts"
  local raw
  raw=$(http_post_json "$url" "$body" "$access_token" "$timeout")
  local curl_exit=$?
  http_post_split_status "$raw"
  _pn_parse_plugin_response PROMPT "$curl_exit" "$url"
}

# pn_plugin_after_prompt <base_url> <access_token> <timeout> <session_id>
#   <cwd> <git_repo_url> <git_branch> <prompt> <response> [generation_id] [model]
#
# prompt is only used server-side when there's no open before_prompt turn to
# merge into (scanning disabled, or this call arrived before any before_prompt
# call for this turn) -- a fresh, self-contained turn document needs both
# halves. When an open turn IS found, only the response is applied; the
# already-persisted prompt is left untouched.
pn_plugin_after_prompt() {
  local base_url="$1" access_token="$2" timeout="$3" session_id="$4"
  local cwd="$5" git_repo_url="$6" git_branch="$7" prompt_text="$8" response_text="$9"
  local generation_id="${10:-}" model="${11:-}"

  [[ -z "$session_id" || -z "$base_url" || -z "$JQ_BIN" ]] && return 0
  [[ -z "$prompt_text" && -z "$response_text" ]] && return 0

  local body
  body=$("$JQ_BIN" -n \
    --arg action "after_prompt" \
    --arg platform "cursor-hooks" \
    --arg cwd "$cwd" --arg gitRepoUrl "$git_repo_url" --arg gitBranch "$git_branch" \
    --arg text "$prompt_text" --arg response "$response_text" --arg generationId "$generation_id" --arg model "$model" \
    '{Action: $action, Platform: $platform, Cwd: $cwd, GitRepoUrl: $gitRepoUrl, GitBranch: $gitBranch, Text: $text, Response: $response, GenerationId: $generationId, Model: $model}')

  local url="${base_url%/}/api/v1/plugins/sessions/${session_id}/prompts"
  local raw
  raw=$(http_post_json "$url" "$body" "$access_token" "$timeout")
  http_post_split_status "$raw"
  if [[ "$HTTP_POST_STATUS" != 2* ]]; then
    log_debug "plugins: after_prompt failed (HTTP ${HTTP_POST_STATUS:-none}) session=$session_id" "$PLUGINS_DEBUG_LOG_PATH"
  else
    log_debug "plugins: after_prompt recorded (session=$session_id, response_len=${#response_text})" "$PLUGINS_DEBUG_LOG_PATH"
  fi
}

# ---------------------------------------------------------------------------
# Tool-calls domain
# ---------------------------------------------------------------------------

# pn_plugin_before_tool_call <base_url> <access_token> <timeout> <session_id>
#   <cwd> <git_repo_url> <git_branch> <tool_name> <input_json> [generation_id]
#   [model] [tool_use_id] [scan_context] [files_json]
#
# input_json must already be a valid JSON value (a quoted string for plain
# text, or an object for structured MCP tool args) -- passed through as-is
# via --argjson, not re-quoted. This is what gets STORED as the tool_use
# block, so it must be the tool's real, faithful input -- never blended
# with turn context or anything else.
#
# scan_context, when the caller has one (the current turn's surrounding
# conversation -- see check-tool-call.sh), is prepended to input_json
# server-side ONLY for what gets scanned; it is never itself stored. Neither
# the raw input nor the surrounding conversation alone is reliably enough
# context for the scan to catch malicious intent that doesn't show up in
# code/commands that look ordinary on their own.
#
# tool_use_id, when the caller has one (Cursor's preToolUse payload carries
# its OWN stable .tool_use_id already -- see check-tool-call.sh), is sent
# through as-is and control-server uses it directly instead of minting one.
# This is what lets check-tool-call-record.sh (postToolUse) correlate its
# result WITHOUT any relay between the two hook invocations: postToolUse's
# payload carries the SAME .tool_use_id from Cursor directly.
#
# files_json, when non-empty, must already be a valid JSON array of
# {Filename, ContentBase64} objects -- check-tool-call.sh builds this when it
# detects a git push/commit in a Shell command, attaching the same
# changed-file diff content the old before_shell_execution gate used to (see
# design-ideas/Shell_Execution_vs_Tool_Call_Hook_Coverage_Validation.md).
# Defaults to an empty array -- every non-git tool call has nothing to attach.
#
# Sets PN_TOOLCALL_STATUS/HTTP_STATUS/ACTION/MESSAGE/THREAT_LEVEL/
# TOOL_USE_ID (the id actually used, echoing tool_use_id when one was given).
pn_plugin_before_tool_call() {
  local base_url="$1" access_token="$2" timeout="$3" session_id="$4"
  local cwd="$5" git_repo_url="$6" git_branch="$7" tool_name="$8" input_json="$9"
  local generation_id="${10:-}" model="${11:-}" tool_use_id="${12:-}" scan_context="${13:-}"
  local files_json="${14:-[]}"

  _pn_reset_plugin_result TOOLCALL
  if [[ -z "$session_id" || -z "$JQ_BIN" ]]; then
    PN_TOOLCALL_STATUS="no_session"
    return 0
  fi
  [[ -z "$input_json" ]] && input_json='""'
  [[ -z "$files_json" ]] && files_json='[]'

  local body
  body=$("$JQ_BIN" -n \
    --arg action "before_tool_call" \
    --arg platform "cursor-hooks" \
    --arg cwd "$cwd" --arg gitRepoUrl "$git_repo_url" --arg gitBranch "$git_branch" \
    --arg toolName "$tool_name" --argjson input "$input_json" \
    --arg generationId "$generation_id" --arg model "$model" --arg toolUseId "$tool_use_id" \
    --arg scanContext "$scan_context" --argjson files "$files_json" \
    '{Action: $action, Platform: $platform, Cwd: $cwd, GitRepoUrl: $gitRepoUrl, GitBranch: $gitBranch, ToolName: $toolName, Input: $input, GenerationId: $generationId, Model: $model, ToolUseId: $toolUseId, ScanContext: $scanContext, Files: $files}')

  local url="${base_url%/}/api/v1/plugins/sessions/${session_id}/tool-calls"
  local raw
  raw=$(http_post_json "$url" "$body" "$access_token" "$timeout")
  local curl_exit=$?
  http_post_split_status "$raw"
  _pn_parse_plugin_response TOOLCALL "$curl_exit" "$url"
}

# pn_plugin_after_tool_call <base_url> <access_token> <timeout> <session_id>
#   <cwd> <git_repo_url> <git_branch> <tool_use_id> <output> <is_error>
#   [generation_id] [tool_name] [input_json]
#
# tool_use_id MUST be the value pn_plugin_before_tool_call returned in
# PN_TOOLCALL_TOOL_USE_ID for the matching call -- this is what lets
# control-server (and, downstream, the webapp's existing transcript
# tool_use_id pairing) attach this result to the right tool_use block.
#
# tool_name/input_json, when the caller has them (see
# check-tool-call-record.sh), let control-server run git/PR detection when
# tool_name=="Shell" -- the same detection the old after_shell_execution hook
# used to fire, now folded into this domain (see design-ideas/
# Shell_Execution_vs_Tool_Call_Hook_Coverage_Validation.md). Omit for any
# tool call this isn't relevant to; control-server only acts on ToolName=="Shell".
pn_plugin_after_tool_call() {
  local base_url="$1" access_token="$2" timeout="$3" session_id="$4"
  local cwd="$5" git_repo_url="$6" git_branch="$7" tool_use_id="$8" output="$9"
  local is_error="${10:-false}" generation_id="${11:-}" tool_name="${12:-}" input_json="${13:-}"

  [[ -z "$session_id" || -z "$base_url" || -z "$JQ_BIN" ]] && return 0
  [[ -z "$tool_use_id" ]] && return 0
  [[ -z "$input_json" ]] && input_json='""'

  local body
  body=$("$JQ_BIN" -n \
    --arg action "after_tool_call" \
    --arg platform "cursor-hooks" \
    --arg cwd "$cwd" --arg gitRepoUrl "$git_repo_url" --arg gitBranch "$git_branch" \
    --arg toolUseId "$tool_use_id" --arg output "$output" \
    --argjson isError "$([[ "$is_error" == "true" ]] && echo true || echo false)" \
    --arg generationId "$generation_id" --arg toolName "$tool_name" --argjson input "$input_json" \
    '{Action: $action, Platform: $platform, Cwd: $cwd, GitRepoUrl: $gitRepoUrl, GitBranch: $gitBranch, ToolUseId: $toolUseId, Output: $output, IsError: $isError, GenerationId: $generationId, ToolName: $toolName, Input: $input}')

  local url="${base_url%/}/api/v1/plugins/sessions/${session_id}/tool-calls"
  local raw
  raw=$(http_post_json "$url" "$body" "$access_token" "$timeout")
  http_post_split_status "$raw"
  if [[ "$HTTP_POST_STATUS" != 2* ]]; then
    log_debug "plugins: after_tool_call failed (HTTP ${HTTP_POST_STATUS:-none}) session=$session_id tool_use_id=$tool_use_id" "$PLUGINS_DEBUG_LOG_PATH"
  else
    log_debug "plugins: after_tool_call recorded (session=$session_id, tool_use_id=$tool_use_id)" "$PLUGINS_DEBUG_LOG_PATH"
  fi
}

# ---------------------------------------------------------------------------
# Git-diff file collection for a before_tool_call gating a git push/commit
# (folded in from the old before_shell_execution gate -- see design-ideas/
# Shell_Execution_vs_Tool_Call_Hook_Coverage_Validation.md; this is the
# capability that made a bare removal of the shell-execution domain unsafe).
# ---------------------------------------------------------------------------

# pn_build_git_diff_files_json <cwd> <git_event_type>
# Prints a JSON array of {Filename, ContentBase64} for the file set relevant
# to git_event_type ("git.push" -> resolve_unpushed_changed_files,
# "git.commit" -> resolve_staged_changed_files; see lib/git-utils.sh),
# skipping binary files and anything missing from the working tree, and
# capped by PARADIGM_NETWORKS_GIT_EVENT_MAX_FILES/_MAX_BYTES (same env vars
# and defaults the old check-git-event.sh guardrail used). Prints "[]" when
# there's nothing to attach -- never fails the caller's gate on its own.
pn_build_git_diff_files_json() {
  local cwd="$1" git_event_type="$2"
  local changed_files=""
  case "$git_event_type" in
    git.push)   changed_files=$(resolve_unpushed_changed_files "$cwd") ;;
    git.commit) changed_files=$(resolve_staged_changed_files "$cwd") ;;
    *) echo "[]"; return 0 ;;
  esac
  if [[ -z "$changed_files" ]]; then
    echo "[]"
    return 0
  fi

  local max_files="${PARADIGM_NETWORKS_GIT_EVENT_MAX_FILES:-60}"
  local max_total_bytes="${PARADIGM_NETWORKS_GIT_EVENT_MAX_BYTES:-8388608}" # 8 MB
  local total_bytes=0 count=0 capped=0
  local entries="[]"
  local rel_path abs_path file_size b64

  while IFS= read -r rel_path; do
    [[ -z "$rel_path" ]] && continue
    abs_path="$cwd/$rel_path"
    [[ -f "$abs_path" ]] || continue
    is_binary_file "$abs_path" && continue

    if [[ "$count" -ge "$max_files" ]]; then
      capped=1
      continue
    fi
    file_size=$(stat -f%z "$abs_path" 2>/dev/null || stat -c%s "$abs_path" 2>/dev/null || echo 0)
    if [[ $((total_bytes + file_size)) -gt "$max_total_bytes" ]]; then
      capped=1
      continue
    fi
    total_bytes=$((total_bytes + file_size))
    count=$((count + 1))

    b64=$(base64 < "$abs_path" 2>/dev/null | tr -d '\n')
    entries=$(echo "$entries" | "$JQ_BIN" --arg fn "$rel_path" --arg c "$b64" '. + [{Filename: $fn, ContentBase64: $c}]')
  done <<< "$changed_files"

  if [[ "$capped" -eq 1 ]]; then
    log_debug "git-diff file set for $git_event_type exceeded the ${max_files}-file/${max_total_bytes}-byte guardrail; remaining files were not attached" "$PLUGINS_DEBUG_LOG_PATH"
  fi
  echo "$entries"
}
