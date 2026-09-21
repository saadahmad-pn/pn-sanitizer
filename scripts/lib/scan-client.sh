#!/bin/bash
# Code Defense Service scan client: replaces /v1/messages-based prompt/write
# scanning with a direct call to POST /api/v1/codedefense/scan -- no model
# invocation (the whole point of this change: /v1/messages required one,
# duplicating whatever real response Cursor itself already produced, and
# whatever it returned got recorded in Observability instead of Cursor's
# real answer). Returns a real, structured allow/warn/block verdict instead
# of pn_parse_messages_response's zero-usage/banner-text heuristic.
#
# Interim step, not the final design: this calls Code Defense Service only,
# so PromptGuard (jailbreak) and PolicyEngine (DLP/PII) coverage that
# /v1/messages's full pipeline previously ran are NOT replicated here yet.
# A composite backend endpoint that triggers PromptGuard + PolicyEngine +
# CDS together, based on the org's policy configuration, is planned to
# replace this call later (PN-11847) -- this is deliberately scoped to reuse
# the one endpoint that already exists today rather than the plugin calling
# three separate policy endpoints itself.
#
# Multi-value returns are globals, not $(...) captures, matching every other
# helper in this codebase (see CLAUDE.md) -- call as a plain statement.

SCAN_DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/scan-client.log"

# pn_scan_text <base_url> <access_token> <timeout> <text>
# Sets:
#   PN_SCAN_STATUS       ok | timeout | unreachable | http_error | invalid_json
#   PN_SCAN_HTTP_STATUS  the raw HTTP status (only meaningful for http_error)
#   PN_SCAN_ACTION        allow | warn | block | "" (only set when STATUS=ok;
#                          empty means the response was valid JSON but didn't
#                          carry a recognized action_to_take -- treat as an
#                          anomaly, not a guessed verdict, same posture
#                          pn_parse_messages_response used to take)
#   PN_SCAN_MESSAGE       the scan's own explanation, if any
#   PN_SCAN_THREAT_LEVEL  overall_threat_level, if any
pn_scan_text() {
  local base_url="$1" access_token="$2" timeout="$3" text="$4"

  PN_SCAN_STATUS=""
  PN_SCAN_HTTP_STATUS=""
  PN_SCAN_ACTION=""
  PN_SCAN_MESSAGE=""
  PN_SCAN_THREAT_LEVEL=""

  local url="${base_url%/}/api/v1/codedefense/scan"
  local raw
  raw=$(http_post_multipart_form "$url" "$access_token" "$timeout" --form-string "text=${text}")
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
  log_debug "scan: ok action=$PN_SCAN_ACTION threat_level=$PN_SCAN_THREAT_LEVEL | url=$url" "$SCAN_DEBUG_LOG_PATH"
  return 0
}
