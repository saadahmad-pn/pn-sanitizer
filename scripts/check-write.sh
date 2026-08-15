#!/bin/bash
# preToolUse hook: scan agent response before Write tool calls
# (Cursor has no separate "Edit" tool_name; all file modifications use "Write".)
# Returns {permission: "allow"/"deny", user_message: "...", agent_message: "..."}

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/pn_config.sh"

# Configuration from environment
SCAN_URL_OVERRIDE="${SNANTIZER_SCAN_URL:-}"
TIMEOUT_SECONDS="${SNANTIZER_TIMEOUT:-20}"
TRANSCRIPT_BYTES="${SNANTIZER_TRANSCRIPT_BYTES:-4000}"
# PN_FAILURE_MODE (marketplace setting: block/allow) takes precedence;
# SNANTIZER_FAILURE_MODE (legacy shared-host override: closed/open) is the fallback.
RAW_FAILURE_MODE=$(echo "${PN_FAILURE_MODE:-${SNANTIZER_FAILURE_MODE:-block}}" | tr '[:upper:]' '[:lower:]')
case "$RAW_FAILURE_MODE" in
  allow|open) FAILURE_MODE="open" ;;
  *)          FAILURE_MODE="closed" ;;
esac

AUDIT_LOG_PATH="${HOME}/.pn-sanitizer/audit.jsonl"

STOP_INSTRUCTION="A security scan blocked this write due to a detected policy violation. Do not retry this write or attempt a workaround (e.g. base64-encoding it, splitting the string, writing it to a different file, or renaming the variable). Stop this task and report the violation to the user."

main() {
  # Read and validate JSON from stdin (skip if nothing is piped in — avoids
  # hanging when invoked without a payload, e.g. manual testing)
  local payload=""
  if [[ ! -t 0 ]]; then
    payload=$(cat 2>/dev/null)
  fi

  # jq is required for everything below (a system install or the bundled
  # fallback in scripts/bin/ — see JQ_BIN in lib/common.sh); route through the
  # same FAILURE_MODE decision as an unreachable scanner, using hand-written
  # literals since the JSON helpers (and audit_log) themselves depend on jq.
  if [[ -z "$JQ_BIN" ]]; then
    if [[ "$FAILURE_MODE" == "open" ]]; then
      echo '{"permission": "allow", "user_message": "No usable jq was found on this machine or bundled for this platform. Write allowed WITHOUT a security scan. Install jq to enable scanning (see the plugin README)."}'
    else
      echo '{"permission": "deny", "user_message": "No usable jq was found on this machine or bundled for this platform. Write blocked.", "agent_message": "No usable jq was found on this machine or bundled for this platform. Do not retry this write. Ask the user to install jq (see the plugin README), then try again."}'
    fi
    return 0
  fi

  # Deliberately always allow here, unlike the FAILURE_MODE-driven branches
  # below: a malformed payload usually signals a Cursor integration/encoding
  # quirk, not an unreachable scanner. Routing it through FAILURE_MODE would
  # mean an affected machine gets every single write blocked persistently,
  # which is worse than a transient scanner outage.
  if ! echo "$payload" | "$JQ_BIN" empty 2>/dev/null; then
    json_permission_allow "Received invalid input."
    return 0
  fi

  # Extract tool name
  local tool_name
  tool_name=$(echo "$payload" | "$JQ_BIN" -r '.tool_name // ""')

  # Only scan Write tool calls
  if [[ "$tool_name" != "Write" ]]; then
    json_permission_allow
    return 0
  fi

  # Extract scan context
  local agent_message
  local transcript_path
  local file_path

  agent_message=$(echo "$payload" | "$JQ_BIN" -r '.agent_message // ""' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  transcript_path=$(echo "$payload" | "$JQ_BIN" -r '.transcript_path // ""')
  file_path=$(echo "$payload" | "$JQ_BIN" -r '.tool_input.file_path // ""')

  # Determine what to scan
  local transcript_content=""
  if [[ -n "$transcript_path" ]] && [[ -f "$transcript_path" ]]; then
    transcript_content=$(file_read_tail "$transcript_path" "$TRANSCRIPT_BYTES")
  fi

  local scan_text="$agent_message"
  if [[ -z "$scan_text" ]]; then
    scan_text="$transcript_content"
  fi


  # If nothing to scan, allow
  if [[ -z "$scan_text" ]]; then
    json_permission_allow
    return 0
  fi

  # Resolve config
  local config
  config=$(pn_resolve_config) || {
    local reason="PN not configured — run the pn-login skill"
    audit_log_entry=$("$JQ_BIN" -n \
      --arg file_path "$file_path" \
      --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
      --arg reason "not_configured" \
      --arg detail "$reason" \
      '{file_path: $file_path, decision: $decision, reason: $reason, detail: $detail}')
    audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

    if [[ "$FAILURE_MODE" == "open" ]]; then
      json_permission_allow "The scanning service is unavailable ($reason). Write allowed WITHOUT a security scan."
    else
      json_permission_deny "The scanning service is unavailable ($reason). Write blocked." "The scanning service is unavailable ($reason). Do not retry this write."
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


  # POST to API (--form-string sends this as a literal value, not a file
  # reference, even if it happens to start with "@")
  local response
  local raw_response
  raw_response=$(http_post_form "$scan_url" "$scan_text" "$access_token" "$TIMEOUT_SECONDS")
  local curl_exit=$?
  http_post_split_status "$raw_response"
  response="$HTTP_POST_BODY"

  # Handle curl errors
  if [[ $curl_exit -eq 28 ]]; then
    # Timeout
    audit_log_entry=$("$JQ_BIN" -n \
      --arg file_path "$file_path" \
      --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
      --arg reason "api_timeout" \
      --arg detail "${TIMEOUT_SECONDS}s timeout" \
      --arg scan_url "$scan_url" \
      '{file_path: $file_path, decision: $decision, reason: $reason, detail: $detail, scan_url: $scan_url}')
    audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

    if [[ "$FAILURE_MODE" == "open" ]]; then
      json_permission_allow "The scanning service is unavailable (timed out after ${TIMEOUT_SECONDS}s). Write allowed WITHOUT a security scan."
    else
      json_permission_deny "The scanning service is unavailable (timed out after ${TIMEOUT_SECONDS}s). Write blocked." "The scanning service is unavailable (timed out after ${TIMEOUT_SECONDS}s). Do not retry this write."
    fi
    return 0
  elif [[ $curl_exit -ne 0 ]]; then
    # Connection error
    audit_log_entry=$("$JQ_BIN" -n \
      --arg file_path "$file_path" \
      --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
      --arg reason "api_unreachable" \
      --arg detail "connection failed" \
      --arg scan_url "$scan_url" \
      '{file_path: $file_path, decision: $decision, reason: $reason, detail: $detail, scan_url: $scan_url}')
    audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

    if [[ "$FAILURE_MODE" == "open" ]]; then
      json_permission_allow "The scanning service is unavailable (connection failed). Write allowed WITHOUT a security scan."
    else
      json_permission_deny "The scanning service is unavailable (connection failed). Write blocked." "The scanning service is unavailable (connection failed). Do not retry this write."
    fi
    return 0
  fi

  # Reject non-2xx responses (expired/invalid token, server error, etc.)
  # before treating the body as a real verdict — a valid-JSON error body
  # would otherwise default to "allow" via the // fallback below and
  # silently mask the actual failure.
  if [[ "$HTTP_POST_STATUS" != 2* ]]; then
    audit_log_entry=$("$JQ_BIN" -n \
      --arg file_path "$file_path" \
      --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
      --arg reason "api_http_error" \
      --arg detail "HTTP ${HTTP_POST_STATUS}" \
      --arg scan_url "$scan_url" \
      '{file_path: $file_path, decision: $decision, reason: $reason, detail: $detail, scan_url: $scan_url}')
    audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

    if [[ "$FAILURE_MODE" == "open" ]]; then
      json_permission_allow "The scanning service returned an error (HTTP ${HTTP_POST_STATUS}). Write allowed WITHOUT a security scan."
    else
      json_permission_deny "The scanning service returned an error (HTTP ${HTTP_POST_STATUS}). Write blocked." "The scanning service returned an error (HTTP ${HTTP_POST_STATUS}). Do not retry this write."
    fi
    return 0
  fi

  # Validate response is JSON
  if ! echo "$response" | "$JQ_BIN" empty 2>/dev/null; then
    audit_log_entry=$("$JQ_BIN" -n \
      --arg file_path "$file_path" \
      --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
      --arg reason "api_invalid_json" \
      --arg detail "scanner returned invalid JSON" \
      --arg scan_url "$scan_url" \
      '{file_path: $file_path, decision: $decision, reason: $reason, detail: $detail, scan_url: $scan_url}')
    audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

    if [[ "$FAILURE_MODE" == "open" ]]; then
      json_permission_allow "The scanning service returned an invalid response. Write allowed WITHOUT a security scan."
    else
      json_permission_deny "The scanning service returned an invalid response. Write blocked." "The scanning service returned an invalid response. Do not retry this write."
    fi
    return 0
  fi

  local action
  local message
  local scan_id

  action=$(echo "$response" | "$JQ_BIN" -r '.action_to_take // "allow"')
  message=$(echo "$response" | "$JQ_BIN" -r '.message // "Agent response blocked by CodeDefense."')
  scan_id=$(echo "$response" | "$JQ_BIN" -r '.scan_id // ""')


  # Audit log the decision
  audit_log_entry=$("$JQ_BIN" -n \
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
