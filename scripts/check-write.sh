#!/bin/bash
# preToolUse hook: scan agent response before Write tool calls
# (Cursor has no separate "Edit" tool_name; all file modifications use "Write".)
# Returns {permission: "allow"/"deny", user_message: "...", agent_message: "..."}

set -o pipefail

# On Windows, this same hook event also has a PowerShell entry (run via
# scripts/run-powershell.cmd) that does the real work -- Cursor has no way
# to run only one entry per platform per event (confirmed against Cursor's
# own hooks documentation), so both are always present in hooks.json. If
# bash happens to be available anyway (Git Bash, MSYS2, Cygwin), this would
# otherwise run a second time for the same event. Defer to the PowerShell
# entry instead.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo '{"permission": "allow"}'
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/pn_config.sh"

# Configuration from environment
SCAN_URL_OVERRIDE="${SNANTIZER_SCAN_URL:-}"
TIMEOUT_SECONDS="${SNANTIZER_TIMEOUT:-20}"
TRANSCRIPT_LINES="${SNANTIZER_TRANSCRIPT_LINES:-500}"
# PARADIGM_NETWORKS_FAILURE_MODE (marketplace setting: block/allow) takes
# precedence; SNANTIZER_FAILURE_MODE (legacy shared-host override:
# closed/open) is the fallback.
RAW_FAILURE_MODE=$(echo "${PARADIGM_NETWORKS_FAILURE_MODE:-${SNANTIZER_FAILURE_MODE:-block}}" | tr '[:upper:]' '[:lower:]')
case "$RAW_FAILURE_MODE" in
  allow|open) FAILURE_MODE="open" ;;
  *)          FAILURE_MODE="closed" ;;
esac

AUDIT_LOG_PATH="${HOME}/.paradigm-scanner/audit.jsonl"
DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-write.log"

STOP_INSTRUCTION="A security scan blocked this write due to a detected policy violation. Do not retry this write or attempt a workaround (e.g. base64-encoding it, splitting the string, writing it to a different file, or renaming the variable). Stop this task and report the violation to the user."

# codedefense/scan is retired; this now calls the Anthropic-compatible
# /v1/messages endpoint on the same backend, which requires a model. No
# per-user model preference exists yet (that's a separate, later addition
# -- see PARADIGM_NETWORKS_MODEL below for the only override that exists
# today), so this is a hardcoded default: cheap/fast tier, chosen because
# testing showed the block/allow verdict is identical across models and
# max_tokens values -- the platform's guard fires before the requested
# model ever runs, so model choice only affects cost/latency on the
# (always-discarded) allow-path reply, not detection accuracy.
DEFAULT_MODEL="anthropic/claude-haiku-4-5-20251001"
# Precedence: PARADIGM_NETWORKS_MODEL env var (works if it's ever actually
# set -- e.g. a shared-host setup exporting it directly; Cursor's own
# plugin Settings panel does NOT deliver this to hook scripts, confirmed
# directly against a real installed plugin -- there is no live channel
# from that settings field to here) > the model saved locally via the
# paradigmnetworks-models skill / set-model.sh (pn_get_preferred_model,
# in pn_config.sh) > hardcoded default.
MODEL="${PARADIGM_NETWORKS_MODEL:-}"
if [[ -z "$MODEL" ]]; then
  MODEL="$(pn_get_preferred_model)"
fi
if [[ -z "$MODEL" ]]; then
  MODEL="$DEFAULT_MODEL"
fi
# 150 comfortably covers the block banner + reason sentence; confirmed via
# live testing that the banner is injected by the guard without ever being
# subject to max_tokens (output_tokens is 0 even for the full banner), so
# this only trades off cost/latency on the allow path, not truncation risk.
MAX_TOKENS=150

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
  local file_content

  agent_message=$(echo "$payload" | "$JQ_BIN" -r '.agent_message // ""' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  transcript_path=$(echo "$payload" | "$JQ_BIN" -r '.transcript_path // ""')
  file_path=$(echo "$payload" | "$JQ_BIN" -r '.tool_input.file_path // ""')
  file_content=$(echo "$payload" | "$JQ_BIN" -r '.tool_input.content // ""')

  # Determine what to scan
  local turn_text=""
  if [[ -n "$transcript_path" ]]; then
    turn_text=$(get_current_turn_text "$transcript_path" "$TRANSCRIPT_LINES")
  fi

  log_debug "tool_input | file_path=$file_path | content_len=${#file_content} | turn_text_len=${#turn_text} | agent_message_len=${#agent_message}" "$DEBUG_LOG_PATH"

  # Scan the current turn's conversation together with the file content --
  # neither alone is enough. File-content-only can miss malicious *intent*
  # that doesn't show up in code that looks ordinary on its own (e.g. the
  # user's actual ask was the problem, not the resulting file). A raw
  # transcript tail on its own can drag in stale context from an earlier,
  # unrelated turn (confirmed directly: a trivial follow-up write was
  # blocked purely because recent transcript text mentioned a security
  # topic from a previous, unrelated prompt). get_current_turn_text() above
  # scopes to the most recent user message onward, so it can't repeat that
  # -- combining it with the actual file content covers both what was
  # asked for and what's actually about to be written.
  local scan_text=""
  local scan_source=""
  if [[ -n "$turn_text" ]] && [[ -n "$file_content" ]]; then
    scan_text="${turn_text}"$'\n\n---\n\n'"${file_content}"
    scan_source="turn+content"
  elif [[ -n "$file_content" ]]; then
    scan_text="$file_content"
    scan_source="content"
  elif [[ -n "$turn_text" ]]; then
    scan_text="$turn_text"
    scan_source="turn"
  elif [[ -n "$agent_message" ]]; then
    scan_text="$agent_message"
    scan_source="agent_message"
  fi
  log_debug "Scan source selected | source=$scan_source | length=${#scan_text}" "$DEBUG_LOG_PATH"

  # If nothing to scan, allow
  if [[ -z "$scan_text" ]]; then
    json_permission_allow
    return 0
  fi

  # Resolve config
  local config
  config=$(pn_resolve_config) || {
    local reason="Paradigm Networks not configured — run the paradigmnetworks-login skill"
    audit_log_entry=$("$JQ_BIN" -n \
      --arg file_path "$file_path" \
      --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
      --arg reason "not_configured" \
      --arg detail "$reason" \
      '{file_path: $file_path, decision: $decision, reason: $reason, detail: $detail}')
    audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

    local signup_note="Don't have one yet? Sign up at https://signup.claude-demo.paradigmnetworks.ai/signup."
    if [[ "$FAILURE_MODE" == "open" ]]; then
      json_permission_allow "The scanning service is unavailable ($reason). Write allowed WITHOUT a security scan. $signup_note"
    else
      json_permission_deny "The scanning service is unavailable ($reason). Write blocked. $signup_note" "The scanning service is unavailable ($reason). Do not retry this write."
    fi
    return 0
  }

  local base_url
  local access_token
  read -r base_url access_token <<<"$config"

  local scan_url="${SCAN_URL_OVERRIDE}"
  if [[ -z "$scan_url" ]]; then
    scan_url="${base_url%/}/v1/messages"
  fi

  log_debug "Scanning write | scan_url=$scan_url | model=$MODEL | scan_text_len=${#scan_text}" "$DEBUG_LOG_PATH"

  # Built via jq -n --arg, not string interpolation: scan_text can contain
  # quotes/backslashes/newlines that must be escaped correctly, and jq
  # handles that safely where hand-built JSON would not.
  local json_body
  json_body=$("$JQ_BIN" -n \
    --arg model "$MODEL" \
    --argjson max_tokens "$MAX_TOKENS" \
    --arg content "$scan_text" \
    '{model: $model, max_tokens: $max_tokens, stream: false, messages: [{role: "user", content: $content}]}')

  local response
  local raw_response
  raw_response=$(http_post_json "$scan_url" "$json_body" "$access_token" "$TIMEOUT_SECONDS")
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

  # pn_parse_messages_response (lib/common.sh) classifies this response --
  # see that function's comment for the full detection-rule rationale.
  # Called as a plain statement, not $(...): it sets PN_MSG_ACTION /
  # PN_MSG_MESSAGE as globals in this shell, same contract as
  # http_post_split_status above.
  pn_parse_messages_response "$response"
  local action="$PN_MSG_ACTION"

  # Audit log the decision. "message_id" (the /v1/messages response's own
  # "id" field) replaces the old scan_id -- different endpoint, same
  # purpose: a value to correlate this decision against backend logs.
  local message_id
  message_id=$(echo "$response" | "$JQ_BIN" -r '.id // ""')
  audit_log_entry=$("$JQ_BIN" -n \
    --arg file_path "$file_path" \
    --arg decision "$action" \
    --arg message_id "$message_id" \
    '{file_path: $file_path, decision: $decision, message_id: $message_id}')
  audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

  # Return verdict
  case "$action" in
    anomaly)
      # Zero usage without the block banner -- an unrecognized response
      # shape, not a confirmed verdict either way. Same posture as an
      # invalid-JSON or non-2xx response above: don't guess allow or block.
      log_debug "API response shape unexpected (zero usage, no block banner) | url=$scan_url" "$DEBUG_LOG_PATH"
      if [[ "$FAILURE_MODE" == "open" ]]; then
        json_permission_allow "The scanning service returned an unexpected response. Write allowed WITHOUT a security scan."
      else
        json_permission_deny "The scanning service returned an unexpected response. Write blocked." "The scanning service returned an unexpected response. Do not retry this write."
      fi
      ;;
    block)
      # PN_MSG_MESSAGE is only the short extracted reason (e.g.
      # "destructive operation"), not a full sentence -- wrap it into the
      # same phrasing the platform's own block banner uses, rather than
      # showing the bare phrase or (worse) the raw ASCII-art banner text
      # verbatim to the user.
      local user_message="The submitted content was flagged because it triggered the following security concerns: ${PN_MSG_MESSAGE}."
      json_permission_deny "$user_message" "$user_message $STOP_INSTRUCTION"
      ;;
    *)
      # "allow" is the only other action pn_parse_messages_response
      # produces -- there is no "warn" state on this endpoint (see that
      # function's comment); the model's actual reply is discarded either
      # way, only the verdict matters.
      json_permission_allow
      ;;
  esac

  return 0
}

main
exit $?
