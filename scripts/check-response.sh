#!/bin/bash
# preToolUse hook: scan agent response context before allowing tool execution
# Similar to check-write.sh but for response scanning with configurable failure mode

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/pn_config.sh"

# Configuration from environment
SCAN_URL_OVERRIDE="${SNANTIZER_SCAN_URL:-}"
TIMEOUT_SECONDS="${SNANTIZER_TIMEOUT:-5}"
TRANSCRIPT_BYTES="${SNANTIZER_TRANSCRIPT_BYTES:-4000}"
FAILURE_MODE="${SNANTIZER_FAILURE_MODE:-closed}"
FAILURE_MODE=$(echo "$FAILURE_MODE" | tr '[:upper:]' '[:lower:]')

DEBUG_LOG="${SNANTIZER_LOG:-${HOME}/.pn/check-response.log}"

main() {
  # Read and validate JSON from stdin
  local payload
  payload=$(cat 2>/dev/null)

  if ! echo "$payload" | jq empty 2>/dev/null; then
    echo '{"permission": "deny", "user_message": "Blocked by CodeDefense: hook received invalid JSON input", "agent_message": "This turn failed a compliance check (invalid input). Do not retry, do not attempt an alternative tool, and do not work around this. Stop and wait for the user."}'
    return 0
  fi

  # Extract context
  local tool_name
  local agent_message
  local transcript_path

  tool_name=$(echo "$payload" | jq -r '.tool_name // ""')
  agent_message=$(echo "$payload" | jq -r '.agent_message // ""')
  transcript_path=$(echo "$payload" | jq -r '.transcript_path // ""')

  # Read transcript if available
  local transcript=""
  if [[ -n "$transcript_path" ]] && [[ -f "$transcript_path" ]]; then
    transcript=$(file_read_tail "$transcript_path" "$TRANSCRIPT_BYTES")
  fi

  # Build scan text
  local scan_text=""
  if [[ -n "$agent_message" ]]; then
    scan_text="$agent_message"
    if [[ -n "$transcript" ]]; then
      scan_text="$scan_text"$'\n'"$transcript"
    fi
  else
    scan_text="$transcript"
  fi

  scan_text=$(echo "$scan_text" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

  # Log
  log_debug "[preToolUse] tool=${tool_name} agent_message_len=${#agent_message} transcript_len=${#transcript} scan_len=${#scan_text}" "$DEBUG_LOG"

  # If nothing to scan, allow
  if [[ -z "$scan_text" ]]; then
    log_debug "[preToolUse] EMPTY SCAN TEXT — nothing to evaluate, allowing" "$DEBUG_LOG"
    echo '{"permission": "allow"}'
    return 0
  fi

  # Resolve config
  local config
  config=$(pn_resolve_config) || {
    log_debug "[preToolUse] NOT CONFIGURED — no env override or valid login found" "$DEBUG_LOG"
    if [[ "$FAILURE_MODE" == "open" ]]; then
      echo '{"permission": "allow", "user_message": "CodeDefense unavailable (PN not configured). Allowing tool call."}'
    else
      echo '{"permission": "deny", "user_message": "Blocked by CodeDefense: scanner unavailable — PN not configured (fail-closed)", "agent_message": "This turn failed a compliance check (scanner unavailable). Do not retry, do not attempt an alternative tool, and do not work around this. Stop and wait for the user."}'
    fi
    return 0
  }

  local base_url
  local access_token
  read -r base_url access_token <<<"$config"

  local scan_url="${SCAN_URL_OVERRIDE}"
  if [[ -z "$scan_url" ]]; then
    scan_url="${base_url%/}/api/v1/codedefense/scan"
  fi

  log_debug "[preToolUse] Scanning response | base_url=$base_url" "$DEBUG_LOG"
  log_debug "[preToolUse] scan_url=$scan_url | scan_text_len=${#scan_text}" "$DEBUG_LOG"
  log_debug "[preToolUse] Request preview: ${scan_text:0:200}$([ ${#scan_text} -gt 200 ] && echo '...' || true)" "$DEBUG_LOG"
  log_debug "[preToolUse] Timeout: ${TIMEOUT_SECONDS}s" "$DEBUG_LOG"

  log_debug "[preToolUse] Sending POST request to $scan_url" "$DEBUG_LOG"

  # POST to API (curl -F handles multipart encoding automatically)
  local response
  response=$(http_post_form "$scan_url" "$scan_text" "$access_token" "$TIMEOUT_SECONDS")
  local curl_exit=$?

  # Handle curl errors
  if [[ $curl_exit -eq 28 ]]; then
    # Timeout
    log_debug "[preToolUse] API timeout | after ${TIMEOUT_SECONDS}s | url=$scan_url" "$DEBUG_LOG"
    if [[ "$FAILURE_MODE" == "open" ]]; then
      echo '{"permission": "allow", "user_message": "CodeDefense unavailable (timeout). Allowing tool call."}'
    else
      echo '{"permission": "deny", "user_message": "Blocked by CodeDefense: scanner unavailable — timed out (fail-closed)", "agent_message": "This turn failed a compliance check (scanner timeout). Do not retry, do not attempt an alternative tool, and do not work around this. Stop and wait for the user."}'
    fi
    return 0
  elif [[ $curl_exit -ne 0 ]]; then
    # Connection error
    log_debug "[preToolUse] API unreachable | curl exit=$curl_exit | url=$scan_url" "$DEBUG_LOG"
    if [[ "$FAILURE_MODE" == "open" ]]; then
      echo '{"permission": "allow", "user_message": "CodeDefense unavailable (unreachable). Allowing tool call."}'
    else
      echo '{"permission": "deny", "user_message": "Blocked by CodeDefense: scanner unavailable — unreachable (fail-closed)", "agent_message": "This turn failed a compliance check (scanner unavailable). Do not retry, do not attempt an alternative tool, and do not work around this. Stop and wait for the user."}'
    fi
    return 0
  fi

  # Validate response is JSON
  if ! echo "$response" | jq empty 2>/dev/null; then
    log_debug "[preToolUse] API invalid JSON | url=$scan_url" "$DEBUG_LOG"
    if [[ "$FAILURE_MODE" == "open" ]]; then
      echo '{"permission": "allow", "user_message": "CodeDefense unavailable (invalid JSON). Allowing tool call."}'
    else
      echo '{"permission": "deny", "user_message": "Blocked by CodeDefense: scanner unavailable — invalid JSON (fail-closed)", "agent_message": "This turn failed a compliance check (scanner error). Do not retry, do not attempt an alternative tool, and do not work around this. Stop and wait for the user."}'
    fi
    return 0
  fi

  local action
  local message

  action=$(echo "$response" | jq -r '.action_to_take // "allow"')
  message=$(echo "$response" | jq -r '.message // "Agent response blocked by CodeDefense."')

  log_debug "[preToolUse] API response received | action=$action" "$DEBUG_LOG"
  log_debug "[preToolUse] verdict=$action message=$message" "$DEBUG_LOG"

  # Return verdict
  case "$action" in
    block)
      local user_msg
      user_msg=$(echo "Blocked by CodeDefense: $message" | jq -Rs .)
      echo "{\"permission\": \"deny\", \"user_message\": $user_msg, \"agent_message\": \"This turn failed a compliance check (policy violation). Do not retry, do not attempt an alternative tool, and do not work around this. Stop and wait for the user.\"}"
      ;;
    warn)
      local warn_msg
      warn_msg=$(echo "$message" | jq -Rs .)
      echo "{\"permission\": \"allow\", \"user_message\": $warn_msg}"
      ;;
    *)
      echo '{"permission": "allow"}'
      ;;
  esac

  return 0
}

main
exit $?
