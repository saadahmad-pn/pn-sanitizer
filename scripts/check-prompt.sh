#!/bin/bash
# beforeSubmitPrompt hook: scan prompt via CodeDefense API before submitting
# Returns {continue: true/false, user_message: "..."} to allow/block the prompt

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/pn_config.sh"

# Configuration from environment
SCAN_URL_OVERRIDE="${SNANTIZER_SCAN_URL:-}"
TIMEOUT_SECONDS="${SNANTIZER_TIMEOUT:-20}"
DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-prompt.log"

# PN_PROMPT_FAILURE_MODE (marketplace setting: block/allow) takes precedence;
# SNANTIZER_PROMPT_FAILURE_MODE (legacy shared-host override: closed/open) is
# the fallback. Defaults to "open" (unlike check-write.sh's PN_FAILURE_MODE,
# which defaults to "closed"). This only governs failures below that happen
# *after* pn_resolve_config succeeds — i.e. the user is already logged in.
# "PN not configured" and "jq missing" always allow unconditionally,
# regardless of this setting, so a not-yet-logged-in user (or a machine
# without jq) can never get stuck on their first message.
RAW_PROMPT_FAILURE_MODE=$(echo "${PN_PROMPT_FAILURE_MODE:-${SNANTIZER_PROMPT_FAILURE_MODE:-allow}}" | tr '[:upper:]' '[:lower:]')
case "$RAW_PROMPT_FAILURE_MODE" in
  block|closed) PROMPT_FAILURE_MODE="closed" ;;
  *)            PROMPT_FAILURE_MODE="open" ;;
esac

main() {
  # Read and validate JSON from stdin (skip if nothing is piped in — avoids
  # hanging when invoked without a payload, e.g. manual testing)
  local payload=""
  if [[ ! -t 0 ]]; then
    payload=$(cat 2>/dev/null)
  fi

  # jq is required for everything below (a system install or the bundled
  # fallback in scripts/bin/ — see JQ_BIN in lib/common.sh). Always fail open
  # here regardless of PROMPT_FAILURE_MODE — this could trip before the user
  # has ever logged in, so it must stay unconditional for the same reason
  # "not configured" does below. Uses a hand-written literal since the JSON
  # helpers themselves depend on jq.
  if [[ -z "$JQ_BIN" ]]; then
    echo '{"continue": true, "user_message": "No usable jq was found on this machine or bundled for this platform. Allowing prompt. Install jq to enable scanning (see the plugin README)."}'
    return 0
  fi

  if ! echo "$payload" | "$JQ_BIN" empty 2>/dev/null; then
    json_deny "Received invalid input. Prompt blocked."
    return 0
  fi

  # Extract prompt
  local prompt
  prompt=$(echo "$payload" | "$JQ_BIN" -r '.prompt // ""')

  # Resolve config
  local config
  config=$(pn_resolve_config) || {
    json_allow "PN is not configured (no login found). Allowing prompt — run the pn-login skill to authenticate CodeDefense."
    return 0
  }

  local base_url
  local access_token
  read -r base_url access_token <<<"$config"

  local scan_url="${SCAN_URL_OVERRIDE}"
  if [[ -z "$scan_url" ]]; then
    scan_url="${base_url%/}/api/v1/codedefense/scan"
  fi

  # Log debug info
  log_debug "Scanning prompt | base_url=$base_url | scan_url=$scan_url | prompt_len=${#prompt}" "$DEBUG_LOG_PATH"
  log_debug "Request body: ${prompt:0:200}$([ ${#prompt} -gt 200 ] && echo '...' || true)" "$DEBUG_LOG_PATH"
  log_debug "Timeout: ${TIMEOUT_SECONDS}s" "$DEBUG_LOG_PATH"

  # Log request details
  log_debug "Sending POST request to $scan_url" "$DEBUG_LOG_PATH"

  # POST to API (--form-string sends this as a literal value, not a file
  # reference, even if it happens to start with "@")
  local response
  local raw_response
  raw_response=$(http_post_form "$scan_url" "$prompt" "$access_token" "$TIMEOUT_SECONDS")
  local curl_exit=$?
  http_post_split_status "$raw_response"
  response="$HTTP_POST_BODY"

  # Handle curl errors. These three branches run only after pn_resolve_config
  # already succeeded (the user is logged in), so it's safe to honor
  # PROMPT_FAILURE_MODE here — no onboarding deadlock risk.
  if [[ $curl_exit -eq 28 ]]; then
    # Timeout
    log_debug "API timeout | after ${TIMEOUT_SECONDS}s | url=$scan_url" "$DEBUG_LOG_PATH"
    if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
      json_deny "The scanning service timed out (${TIMEOUT_SECONDS}s). Prompt blocked."
    else
      json_allow "The scanning service timed out (${TIMEOUT_SECONDS}s). Allowing prompt."
    fi
    return 0
  elif [[ $curl_exit -ne 0 ]]; then
    # Connection error
    log_debug "API unreachable | curl exit=$curl_exit | url=$scan_url" "$DEBUG_LOG_PATH"
    if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
      json_deny "The scanning service is unreachable. Prompt blocked."
    else
      json_allow "The scanning service is unreachable. Allowing prompt."
    fi
    return 0
  fi

  # Reject non-2xx responses (expired/invalid token, server error, etc.)
  # before treating the body as a real verdict — a valid-JSON error body
  # (e.g. {"error": "unauthorized"}) would otherwise default to "allow" via
  # the // fallback below and silently mask the actual failure.
  if [[ "$HTTP_POST_STATUS" != 2* ]]; then
    log_debug "API HTTP error | status=$HTTP_POST_STATUS | url=$scan_url" "$DEBUG_LOG_PATH"
    if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
      json_deny "The scanning service returned an error (HTTP ${HTTP_POST_STATUS}). Prompt blocked."
    else
      json_allow "The scanning service returned an error (HTTP ${HTTP_POST_STATUS}). Allowing prompt."
    fi
    return 0
  fi

  # Validate response is JSON
  if ! echo "$response" | "$JQ_BIN" empty 2>/dev/null; then
    log_debug "API invalid JSON response | url=$scan_url" "$DEBUG_LOG_PATH"
    if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
      json_deny "The scanning service returned an invalid response. Prompt blocked."
    else
      json_allow "The scanning service returned an invalid response. Allowing prompt."
    fi
    return 0
  fi

  local action
  local message

  action=$(echo "$response" | "$JQ_BIN" -r '.action_to_take // "allow"')
  message=$(echo "$response" | "$JQ_BIN" -r '.message // "Prompt blocked by CodeDefense."')

  log_debug "API response received | action=$action" "$DEBUG_LOG_PATH"


  # Return verdict
  case "$action" in
    block)
      local branded_message="[Paradigm] $message"
      json_deny "$branded_message"
      ;;
    warn)
      json_allow "$message"
      ;;
    *)
      json_allow
      ;;
  esac

  return 0
}

main
exit $?
