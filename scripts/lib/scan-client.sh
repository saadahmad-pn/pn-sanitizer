#!/bin/bash
# Composite scan client: calls control-server's
# POST /api/v1/plugin/codechain/sessions/{id}/scan, which runs whichever of
# PromptGuard, PolicyEngine, and Code Defense the org's policy has enabled
# against the given text (in that order, worst-result-wins) and returns one
# allow/warn/block verdict. Replaces the earlier interim design that called
# POST /api/v1/codedefense/scan directly (Code Defense only, no PromptGuard/
# PolicyEngine coverage, and no session join) -- see design-ideas/
# Codechain_Plugin_Hooks_Design.md and CHANGELOG.md for the full history.
#
# SessionId is REQUIRED here, unlike lib/codechain-client.sh's recording
# calls: the composite endpoint also persists a chatapi document tagged
# with it (EventType "scan"), which is how a gating decision ends up joined
# to the same Code Chain session as this session's recorded turns/shell-
# events -- see PluginScan.go's header on control-server.
#
# Multi-value returns are globals, not $(...) captures, matching every other
# helper in this codebase (see CLAUDE.md) -- call as a plain statement.

SCAN_DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/scan-client.log"

# pn_scan_text <base_url> <access_token> <timeout> <session_id> <cwd>
#   <git_repo_url> <git_branch> <text>
# Sets:
#   PN_SCAN_STATUS       ok | no_session | timeout | unreachable |
#                          http_error | invalid_json
#   PN_SCAN_HTTP_STATUS  the raw HTTP status (only meaningful for http_error)
#   PN_SCAN_ACTION        allow | warn | block | "" (only set when STATUS=ok;
#                          empty means the response was valid JSON but didn't
#                          carry a recognized action_to_take -- treat as an
#                          anomaly, not a guessed verdict, same posture
#                          pn_parse_messages_response used to take)
#   PN_SCAN_MESSAGE       the scan's own explanation, if any
#   PN_SCAN_THREAT_LEVEL  overall_threat_level, if any
pn_scan_text() {
  local base_url="$1" access_token="$2" timeout="$3" session_id="$4"
  local cwd="$5" git_repo_url="$6" git_branch="$7" text="$8"

  PN_SCAN_STATUS=""
  PN_SCAN_HTTP_STATUS=""
  PN_SCAN_ACTION=""
  PN_SCAN_MESSAGE=""
  PN_SCAN_THREAT_LEVEL=""

  if [[ -z "$session_id" ]]; then
    PN_SCAN_STATUS="no_session"
    log_debug "scan: no session id available, cannot call the scan endpoint" "$SCAN_DEBUG_LOG_PATH"
    return 0
  fi
  if [[ -z "$JQ_BIN" ]]; then
    PN_SCAN_STATUS="no_session"
    log_debug "scan: jq unavailable, cannot build request body" "$SCAN_DEBUG_LOG_PATH"
    return 0
  fi

  local body
  body=$("$JQ_BIN" -n \
    --arg platform "cursor-hooks" \
    --arg cwd "$cwd" \
    --arg gitRepoUrl "$git_repo_url" \
    --arg gitBranch "$git_branch" \
    --arg text "$text" \
    '{Platform: $platform, Cwd: $cwd, GitRepoUrl: $gitRepoUrl, GitBranch: $gitBranch, Text: $text}')

  local url="${base_url%/}/api/v1/plugin/codechain/sessions/${session_id}/scan"
  local raw
  raw=$(http_post_json "$url" "$body" "$access_token" "$timeout")
  local curl_exit=$?
  http_post_split_status "$raw"

  if [[ $curl_exit -eq 28 ]]; then
    PN_SCAN_STATUS="timeout"
    log_debug "scan: timeout after ${timeout}s | url=$url" "$SCAN_DEBUG_LOG_PATH"
    return 0
  elif [[ $curl_exit -ne 0 ]]; then
    PN_SCAN_STATUS="unreachable"
    log_debug "scan: unreachable (curl exit=$curl_exit) | url=$url" "$SCAN_DEBUG_LOG_PATH"
    return 0
  fi

  PN_SCAN_HTTP_STATUS="$HTTP_POST_STATUS"
  if [[ "$HTTP_POST_STATUS" != 2* ]]; then
    PN_SCAN_STATUS="http_error"
    log_debug "scan: HTTP error status=$HTTP_POST_STATUS | url=$url" "$SCAN_DEBUG_LOG_PATH"
    return 0
  fi

  if ! echo "$HTTP_POST_BODY" | "$JQ_BIN" empty 2>/dev/null; then
    PN_SCAN_STATUS="invalid_json"
    log_debug "scan: invalid JSON response | url=$url" "$SCAN_DEBUG_LOG_PATH"
    return 0
  fi

  PN_SCAN_ACTION=$(echo "$HTTP_POST_BODY" | "$JQ_BIN" -r '.action_to_take // ""')
  PN_SCAN_MESSAGE=$(echo "$HTTP_POST_BODY" | "$JQ_BIN" -r '.message // ""')
  PN_SCAN_THREAT_LEVEL=$(echo "$HTTP_POST_BODY" | "$JQ_BIN" -r '.overall_threat_level // ""')
  PN_SCAN_STATUS="ok"
  log_debug "scan: ok action=$PN_SCAN_ACTION threat_level=$PN_SCAN_THREAT_LEVEL session=$session_id | url=$url" "$SCAN_DEBUG_LOG_PATH"
  return 0
}
