#!/bin/bash
# preToolUse hook: scan agent response before Write/Edit tool calls
# Returns {permission: "allow"/"deny", user_message: "...", agent_message: "..."}

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

AUDIT_LOG_PATH="${HOME}/.pn-sanitizer/audit.jsonl"
DESKTOP_LOG_PATH="${HOME}/Desktop/pn-sanitizer-hook.log"

STOP_INSTRUCTION="A security scan blocked this write due to a detected policy violation. Do not retry this write or attempt a workaround (e.g. base64-encoding it, splitting the string, writing it to a different file, or renaming the variable). Stop this task and report the violation to the user."

main() {
  # Read and validate JSON from stdin
  local payload
  payload=$(cat 2>/dev/null)

  if ! echo "$payload" | jq empty 2>/dev/null; then
    json_permission_allow "Write-guard hook received invalid JSON input."
    return 0
  fi

  # Extract tool name
  local tool_name
  tool_name=$(echo "$payload" | jq -r '.tool_name // ""')

  # Only scan Write and Edit tools
  if [[ "$tool_name" != "Write" ]] && [[ "$tool_name" != "Edit" ]]; then
    json_permission_allow
    return 0
  fi

  # Extract scan context
  local agent_message
  local transcript_path
  local file_path

  agent_message=$(echo "$payload" | jq -r '.agent_message // ""' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  transcript_path=$(echo "$payload" | jq -r '.transcript_path // ""')
  file_path=$(echo "$payload" | jq -r '.tool_input.file_path // ""')

  # Determine what to scan
  local transcript_content=""
  if [[ -n "$transcript_path" ]] && [[ -f "$transcript_path" ]]; then
    transcript_content=$(file_read_tail "$transcript_path" "$TRANSCRIPT_BYTES")
  fi

  local scan_text="$agent_message"
  if [[ -z "$scan_text" ]]; then
    scan_text="$transcript_content"
  fi

  # Log desktop details
  {
    echo "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "hook: preToolUse"
    echo "tool: $tool_name, file_path: $file_path"
    echo "agent_message_len: ${#agent_message}, transcript_len: ${#transcript_content}, scan_len: ${#scan_text}"
    echo ""
  } >> "$DESKTOP_LOG_PATH" 2>/dev/null || true

  # If nothing to scan, allow
  if [[ -z "$scan_text" ]]; then
    json_permission_allow
    return 0
  fi

  # Resolve config
  local config
  config=$(pn_resolve_config) || {
    local reason="PN not configured — run the pn-login skill"
    audit_log_entry=$(jq -n \
      --arg file_path "$file_path" \
      --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
      --arg reason "not_configured" \
      --arg detail "$reason" \
      '{file_path: $file_path, decision: $decision, reason: $reason, detail: $detail}')
    audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

    if [[ "$FAILURE_MODE" == "open" ]]; then
      json_permission_allow "CodeDefense unavailable ($reason). Write allowed WITHOUT a security scan."
    else
      json_permission_deny "CodeDefense unavailable ($reason). Write blocked." "The security scan API is unavailable ($reason). Do not retry this write."
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

  # Log request details
  {
    echo "scan_url: $scan_url"
    echo "scan_text_len: ${#scan_text}"
    echo "timeout: ${TIMEOUT_SECONDS}s"
    echo "failure_mode: $FAILURE_MODE"
    echo ""
  } >> "$DESKTOP_LOG_PATH" 2>/dev/null || true

  # POST to API (curl -F handles multipart encoding automatically)
  local response
  response=$(http_post_form "$scan_url" "$scan_text" "$access_token" "$TIMEOUT_SECONDS")
  local curl_exit=$?

  # Handle curl errors
  if [[ $curl_exit -eq 28 ]]; then
    # Timeout
    audit_log_entry=$(jq -n \
      --arg file_path "$file_path" \
      --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
      --arg reason "api_timeout" \
      --arg detail "${TIMEOUT_SECONDS}s timeout" \
      --arg scan_url "$scan_url" \
      '{file_path: $file_path, decision: $decision, reason: $reason, detail: $detail, scan_url: $scan_url}')
    audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

    if [[ "$FAILURE_MODE" == "open" ]]; then
      json_permission_allow "CodeDefense unavailable (timed out after ${TIMEOUT_SECONDS}s). Write allowed WITHOUT a security scan."
    else
      json_permission_deny "CodeDefense unavailable (timed out after ${TIMEOUT_SECONDS}s). Write blocked." "The security scan API is unavailable (timed out after ${TIMEOUT_SECONDS}s). Do not retry this write."
    fi
    return 0
  elif [[ $curl_exit -ne 0 ]]; then
    # Connection error
    audit_log_entry=$(jq -n \
      --arg file_path "$file_path" \
      --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
      --arg reason "api_unreachable" \
      --arg detail "connection failed" \
      --arg scan_url "$scan_url" \
      '{file_path: $file_path, decision: $decision, reason: $reason, detail: $detail, scan_url: $scan_url}')
    audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

    if [[ "$FAILURE_MODE" == "open" ]]; then
      json_permission_allow "CodeDefense unavailable (connection failed). Write allowed WITHOUT a security scan."
    else
      json_permission_deny "CodeDefense unavailable (connection failed). Write blocked." "The security scan API is unavailable (connection failed). Do not retry this write."
    fi
    return 0
  fi

  # Validate response is JSON
  if ! echo "$response" | jq empty 2>/dev/null; then
    audit_log_entry=$(jq -n \
      --arg file_path "$file_path" \
      --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
      --arg reason "api_invalid_json" \
      --arg detail "scanner returned invalid JSON" \
      --arg scan_url "$scan_url" \
      '{file_path: $file_path, decision: $decision, reason: $reason, detail: $detail, scan_url: $scan_url}')
    audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

    if [[ "$FAILURE_MODE" == "open" ]]; then
      json_permission_allow "CodeDefense unavailable (invalid JSON response). Write allowed WITHOUT a security scan."
    else
      json_permission_deny "CodeDefense unavailable (invalid JSON response). Write blocked." "The security scan API is unavailable (invalid JSON response). Do not retry this write."
    fi
    return 0
  fi

  local action
  local message
  local scan_id

  action=$(echo "$response" | jq -r '.action_to_take // "allow"')
  message=$(echo "$response" | jq -r '.message // "Agent response blocked by CodeDefense."')
  scan_id=$(echo "$response" | jq -r '.scan_id // ""')

  # Log response for desktop
  {
    echo "--- API Response ---"
    echo "$response" | jq . 2>/dev/null || echo "$response"
    echo ""
  } >> "$DESKTOP_LOG_PATH" 2>/dev/null || true

  # Audit log the decision
  audit_log_entry=$(jq -n \
    --arg file_path "$file_path" \
    --arg decision "$action" \
    --arg scan_id "$scan_id" \
    '{file_path: $file_path, decision: $decision, scan_id: $scan_id}')
  audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

  # Return verdict
  case "$action" in
    block)
      json_permission_deny "$message" "$message $STOP_INSTRUCTION"
      ;;
    warn)
      json_permission_allow "$message"
      ;;
    *)
      json_permission_allow
      ;;
  esac

  return 0
}

main
exit $?
