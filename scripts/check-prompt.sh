#!/bin/bash
# beforeSubmitPrompt hook: scan prompt via CodeDefense API before submitting
# Returns {continue: true/false, user_message: "..."} to allow/block the prompt

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/multipart.sh"
source "$SCRIPT_DIR/pn_config.sh"

# Configuration from environment
SCAN_URL_OVERRIDE="${SNANTIZER_SCAN_URL:-}"
TIMEOUT_SECONDS="${SNANTIZER_TIMEOUT:-5}"
DESKTOP_LOG_PATH="${HOME}/Desktop/pn-sanitizer-hook.log"
DEBUG_LOG_PATH="${HOME}/.pn-sanitizer/check-prompt.log"

main() {
  # Read and validate JSON from stdin
  local payload
  payload=$(cat 2>/dev/null)

  if ! echo "$payload" | jq empty 2>/dev/null; then
    json_deny "CodeDefense hook received invalid JSON input."
    return 0
  fi

  # Extract prompt
  local prompt
  prompt=$(echo "$payload" | jq -r '.prompt // ""')

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

  # POST to API (curl -F handles multipart encoding automatically)
  local response
  response=$(http_post_form "$scan_url" "$prompt" "$access_token" "$TIMEOUT_SECONDS")
  local curl_exit=$?

  # Handle curl errors
  if [[ $curl_exit -eq 28 ]]; then
    # Timeout
    log_debug "API timeout | after ${TIMEOUT_SECONDS}s | url=$scan_url" "$DEBUG_LOG_PATH"
    json_allow "CodeDefense API timed out (${TIMEOUT_SECONDS}s). Allowing prompt."
    return 0
  elif [[ $curl_exit -ne 0 ]]; then
    # Connection error
    log_debug "API unreachable | curl exit=$curl_exit | url=$scan_url" "$DEBUG_LOG_PATH"
    json_allow "CodeDefense API unreachable. Allowing prompt."
    return 0
  fi

  # Validate response is JSON
  if ! echo "$response" | jq empty 2>/dev/null; then
    log_debug "API invalid JSON response | url=$scan_url" "$DEBUG_LOG_PATH"
    json_allow "CodeDefense API returned invalid JSON. Allowing prompt."
    return 0
  fi

  local action
  local message

  action=$(echo "$response" | jq -r '.action_to_take // "allow"')
  message=$(echo "$response" | jq -r '.message // "Prompt blocked by CodeDefense."')

  log_debug "API response received | action=$action" "$DEBUG_LOG_PATH"

  # Log response for desktop
  mkdir -p "$(dirname "$DESKTOP_LOG_PATH")" 2>/dev/null || true
  {
    echo "$(date '+%Y-%m-%d %H:%M:%S') --- API Response ---"
    echo "$response" | jq . 2>/dev/null || echo "$response"
    echo ""
  } >> "$DESKTOP_LOG_PATH" 2>/dev/null || true

  # Return verdict
  case "$action" in
    block)
      local branded_message="[Paradigm CodeDefense] $message"
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
