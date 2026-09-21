#!/bin/bash
# preToolUse hook: scan agent response before Write and Shell tool calls
# (Cursor has no separate "Edit" tool_name; all file modifications use "Write".)
# Returns {permission: "allow"/"deny", user_message: "...", agent_message: "..."}

set -o pipefail

# Dead code on the hook path: hooks.json now registers exactly one entry
# per event, dispatched by scripts/run-hook.cmd (bash here, PowerShell on
# Windows), so Cursor never spawns this script under Git Bash/MSYS2/Cygwin
# in the first place. Left in place only so this .sh still behaves
# correctly if someone invokes it directly under one of those.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo '{"permission": "allow"}'
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/git-utils.sh"
source "$SCRIPT_DIR/lib/scan-client.sh"
source "$SCRIPT_DIR/pn_config.sh"

# Configuration from environment
TIMEOUT_SECONDS="${PARADIGM_NETWORKS_TIMEOUT:-60}"
TRANSCRIPT_LINES="${PARADIGM_NETWORKS_TRANSCRIPT_LINES:-500}"
# PARADIGM_NETWORKS_FAILURE_MODE (manual env var override: block/allow —
# no Cursor Settings UI for this, must be set directly in the
# environment).
RAW_FAILURE_MODE=$(echo "${PARADIGM_NETWORKS_FAILURE_MODE:-block}" | tr '[:upper:]' '[:lower:]')
case "$RAW_FAILURE_MODE" in
  allow|open) FAILURE_MODE="open" ;;
  *)          FAILURE_MODE="closed" ;;
esac

AUDIT_LOG_PATH="${HOME}/.paradigm-scanner/audit.jsonl"
DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-write.log"

# "relay ... in full, exactly as given" is deliberate, not just "report
# the violation": confirmed directly that a vaguer instruction lets the
# agent paraphrase the findings above into its own short summary,
# dropping specific detail in the process -- observed losing an entire
# second finding and every category/standard name (e.g. "OWASP", "ASVS")
# it was quoting from. Deliberately generic here (not "relay the OWASP
# findings," specifically) since the backend's categorization scheme
# isn't guaranteed to always be OWASP-flavored.
# Takes "this write" or "this command" (see action_desc, set once tool_name
# is known) since the same instruction now covers both Write and Shell.
build_stop_instruction() {
  local action_desc="$1"
  echo "A security scan blocked ${action_desc} due to a detected policy violation. Do not retry ${action_desc} or attempt a workaround (e.g. re-encoding it, splitting it up, or otherwise disguising it to bypass detection). Stop this task and relay the findings above to the user in full, exactly as given -- every issue, category, code, and standard name mentioned. Do not summarize or paraphrase them into a general statement; the user needs the precise details to know what to fix."
}

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
      echo '{"permission": "allow", "user_message": "No usable jq was found on this machine or bundled for this platform. Allowed WITHOUT a security scan. Install jq to enable scanning (see the plugin README)."}'
    else
      echo '{"permission": "deny", "user_message": "No usable jq was found on this machine or bundled for this platform. Blocked.", "agent_message": "No usable jq was found on this machine or bundled for this platform. Do not retry this action. Ask the user to install jq (see the plugin README), then try again."}'
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

  # Scan Write (file modification) and Shell (command execution) tool calls.
  if [[ "$tool_name" != "Write" ]] && [[ "$tool_name" != "Shell" ]]; then
    json_permission_allow
    return 0
  fi

  # Tool-appropriate wording for user_message/agent_message below -- a
  # message that says "Write blocked" for a blocked shell command would be
  # actively misleading about what actually happened.
  local action_noun="Write"
  local action_desc="this write"
  if [[ "$tool_name" == "Shell" ]]; then
    action_noun="Command"
    action_desc="this command"
  fi

  # Extract scan context
  local agent_message
  local transcript_path
  local file_path
  local file_content
  local shell_command

  agent_message=$(echo "$payload" | "$JQ_BIN" -r '.agent_message // ""' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  transcript_path=$(echo "$payload" | "$JQ_BIN" -r '.transcript_path // ""')
  file_path=$(echo "$payload" | "$JQ_BIN" -r '.tool_input.file_path // ""')
  file_content=$(echo "$payload" | "$JQ_BIN" -r '.tool_input.content // ""')
  shell_command=$(echo "$payload" | "$JQ_BIN" -r '.tool_input.command // ""')

  # Session id + cwd/git context for the scan call's chatapi join -- see
  # lib/scan-client.sh's header. Same extraction pattern as every other
  # hook here (check-turn-complete.sh et al).
  local client_session_id cwd git_repo_url="" git_branch=""
  client_session_id=$(echo "$payload" | "$JQ_BIN" -r '.conversation_id // .session_id // ""')
  cwd=$(echo "$payload" | "$JQ_BIN" -r '.cwd // (.workspace_roots // [])[0] // ""')
  if [[ -n "$cwd" ]] && [[ -d "$cwd/.git" ]]; then
    git_repo_url=$(get_remote_url_or_empty "$cwd")
    git_branch=$(get_current_branch_or_empty "$cwd")
  fi

  # "subject" is what's actually about to happen -- the file content being
  # written for a Write call, or the command about to run for a Shell call.
  local subject=""
  if [[ "$tool_name" == "Write" ]]; then
    subject="$file_content"
  else
    subject="$shell_command"
  fi

  # Determine what to scan
  local turn_text=""
  if [[ -n "$transcript_path" ]]; then
    turn_text=$(get_current_turn_text "$transcript_path" "$TRANSCRIPT_LINES")
  fi

  log_debug "tool_input | tool_name=$tool_name | file_path=$file_path | command_len=${#shell_command} | content_len=${#file_content} | turn_text_len=${#turn_text} | agent_message_len=${#agent_message}" "$DEBUG_LOG_PATH"

  # Scan the current turn's conversation together with the write/command
  # subject -- neither alone is enough. The subject alone can miss malicious
  # *intent* that doesn't show up in code/commands that look ordinary on
  # their own. A raw transcript tail on its own can drag in stale context
  # from an earlier, unrelated turn. get_current_turn_text() scopes to the
  # most recent user message onward, so combining it with the actual subject
  # covers both what was asked for and what's actually about to happen.
  local scan_text=""
  local scan_source=""
  if [[ -n "$turn_text" ]] && [[ -n "$subject" ]]; then
    scan_text="${turn_text}"$'\n\n---\n\n'"${subject}"
    scan_source="turn+subject"
  elif [[ -n "$subject" ]]; then
    scan_text="$subject"
    scan_source="subject"
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
      --arg tool_name "$tool_name" \
      --arg file_path "$file_path" \
      --arg command "$shell_command" \
      --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
      --arg reason "not_configured" \
      --arg detail "$reason" \
      '{tool_name: $tool_name, file_path: $file_path, command: $command, decision: $decision, reason: $reason, detail: $detail}')
    audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

    local signup_note="Don't have one yet? Sign up at https://signup.claude-demo.paradigmnetworks.ai/signup."
    if [[ "$FAILURE_MODE" == "open" ]]; then
      json_permission_allow "The scanning service is unavailable ($reason). ${action_noun} allowed WITHOUT a security scan. $signup_note"
    else
      json_permission_deny "The scanning service is unavailable ($reason). ${action_noun} blocked. $signup_note" "The scanning service is unavailable ($reason). Do not retry ${action_desc}."
    fi
    return 0
  }

  local base_url
  local access_token
  read -r base_url access_token <<<"$config"

  log_debug "Scanning write | base_url=$base_url | scan_text_len=${#scan_text}" "$DEBUG_LOG_PATH"

  # pn_scan_text (lib/scan-client.sh) posts to the composite
  # PromptGuard+PolicyEngine+CodeDefense scan endpoint -- no model
  # invocation, a real structured action_to_take verdict instead of the old
  # /v1/messages zero-usage/banner-text heuristic. Called as a plain
  # statement, not $(...): it sets PN_SCAN_* as globals in this shell.
  pn_scan_text "$base_url" "$access_token" "$TIMEOUT_SECONDS" "$client_session_id" "$cwd" "$git_repo_url" "$git_branch" "$scan_text"

  case "$PN_SCAN_STATUS" in
    no_session)
      # Every preToolUse payload observed so far has carried conversation_id,
      # so this is not expected in practice.
      audit_log_entry=$("$JQ_BIN" -n \
        --arg tool_name "$tool_name" \
        --arg file_path "$file_path" \
        --arg command "$shell_command" \
        --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
        --arg reason "no_session_id" \
        --arg detail "no session id available" \
        '{tool_name: $tool_name, file_path: $file_path, command: $command, decision: $decision, reason: $reason, detail: $detail}')
      audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

      if [[ "$FAILURE_MODE" == "open" ]]; then
        json_permission_allow "The scanning service could not be reached (no session id available). ${action_noun} allowed WITHOUT a security scan."
      else
        json_permission_deny "The scanning service could not be reached (no session id available). ${action_noun} blocked." "The scanning service could not be reached (no session id available). Do not retry ${action_desc}."
      fi
      return 0
      ;;
    timeout)
      audit_log_entry=$("$JQ_BIN" -n \
        --arg tool_name "$tool_name" \
        --arg file_path "$file_path" \
        --arg command "$shell_command" \
        --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
        --arg reason "api_timeout" \
        --arg detail "${TIMEOUT_SECONDS}s timeout" \
        '{tool_name: $tool_name, file_path: $file_path, command: $command, decision: $decision, reason: $reason, detail: $detail}')
      audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

      if [[ "$FAILURE_MODE" == "open" ]]; then
        json_permission_allow "The scanning service is unavailable (timed out after ${TIMEOUT_SECONDS}s). ${action_noun} allowed WITHOUT a security scan."
      else
        json_permission_deny "The scanning service is unavailable (timed out after ${TIMEOUT_SECONDS}s). ${action_noun} blocked." "The scanning service is unavailable (timed out after ${TIMEOUT_SECONDS}s). Do not retry ${action_desc}."
      fi
      return 0
      ;;
    unreachable)
      audit_log_entry=$("$JQ_BIN" -n \
        --arg tool_name "$tool_name" \
        --arg file_path "$file_path" \
        --arg command "$shell_command" \
        --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
        --arg reason "api_unreachable" \
        --arg detail "connection failed" \
        '{tool_name: $tool_name, file_path: $file_path, command: $command, decision: $decision, reason: $reason, detail: $detail}')
      audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

      if [[ "$FAILURE_MODE" == "open" ]]; then
        json_permission_allow "The scanning service is unavailable (connection failed). ${action_noun} allowed WITHOUT a security scan."
      else
        json_permission_deny "The scanning service is unavailable (connection failed). ${action_noun} blocked." "The scanning service is unavailable (connection failed). Do not retry ${action_desc}."
      fi
      return 0
      ;;
    http_error)
      audit_log_entry=$("$JQ_BIN" -n \
        --arg tool_name "$tool_name" \
        --arg file_path "$file_path" \
        --arg command "$shell_command" \
        --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
        --arg reason "api_http_error" \
        --arg detail "HTTP ${PN_SCAN_HTTP_STATUS}" \
        '{tool_name: $tool_name, file_path: $file_path, command: $command, decision: $decision, reason: $reason, detail: $detail}')
      audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

      if [[ "$FAILURE_MODE" == "open" ]]; then
        json_permission_allow "The scanning service returned an error (HTTP ${PN_SCAN_HTTP_STATUS}). ${action_noun} allowed WITHOUT a security scan."
      else
        json_permission_deny "The scanning service returned an error (HTTP ${PN_SCAN_HTTP_STATUS}). ${action_noun} blocked." "The scanning service returned an error (HTTP ${PN_SCAN_HTTP_STATUS}). Do not retry ${action_desc}."
      fi
      return 0
      ;;
    invalid_json)
      audit_log_entry=$("$JQ_BIN" -n \
        --arg tool_name "$tool_name" \
        --arg file_path "$file_path" \
        --arg command "$shell_command" \
        --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
        --arg reason "api_invalid_json" \
        --arg detail "scanner returned invalid JSON" \
        '{tool_name: $tool_name, file_path: $file_path, command: $command, decision: $decision, reason: $reason, detail: $detail}')
      audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

      if [[ "$FAILURE_MODE" == "open" ]]; then
        json_permission_allow "The scanning service returned an invalid response. ${action_noun} allowed WITHOUT a security scan."
      else
        json_permission_deny "The scanning service returned an invalid response. ${action_noun} blocked." "The scanning service returned an invalid response. Do not retry ${action_desc}."
      fi
      return 0
      ;;
  esac

  # Audit log the decision.
  audit_log_entry=$("$JQ_BIN" -n \
    --arg tool_name "$tool_name" \
    --arg file_path "$file_path" \
    --arg command "$shell_command" \
    --arg decision "$PN_SCAN_ACTION" \
    --arg threat_level "$PN_SCAN_THREAT_LEVEL" \
    '{tool_name: $tool_name, file_path: $file_path, command: $command, decision: $decision, threat_level: $threat_level}')
  audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

  # Return verdict
  case "$PN_SCAN_ACTION" in
    ""|null)
      # A valid JSON response with no recognized action_to_take -- an
      # unexpected response shape, not a confirmed verdict either way.
      log_debug "Scan response shape unexpected (no recognized action_to_take)" "$DEBUG_LOG_PATH"
      local anomaly_streak
      anomaly_streak=$(pn_record_scan_anomaly)
      local anomaly_prefix=""
      if [[ "$anomaly_streak" -ge "$PN_ANOMALY_WARNING_THRESHOLD" ]]; then
        anomaly_prefix="⚠️ Security scanning has failed ${anomaly_streak} times in a row and may not be protecting you right now. Contact your administrator. "
      fi
      if [[ -n "$PN_SCAN_MESSAGE" ]]; then
        if [[ "$FAILURE_MODE" == "open" ]]; then
          json_permission_allow "${anomaly_prefix}${PN_SCAN_MESSAGE}"
        else
          json_permission_deny "${anomaly_prefix}${PN_SCAN_MESSAGE}" "$PN_SCAN_MESSAGE Do not retry ${action_desc}."
        fi
      else
        if [[ "$FAILURE_MODE" == "open" ]]; then
          json_permission_allow "${anomaly_prefix}The scanning service returned an unexpected response. ${action_noun} allowed WITHOUT a security scan."
        else
          json_permission_deny "${anomaly_prefix}The scanning service returned an unexpected response. ${action_noun} blocked." "The scanning service returned an unexpected response. Do not retry ${action_desc}."
        fi
      fi
      ;;
    block)
      pn_record_successful_scan
      local user_message="$PN_SCAN_MESSAGE"
      [[ -z "$user_message" ]] && user_message="A policy violation was detected."
      json_permission_deny "$user_message" "$user_message $(build_stop_instruction "$action_desc")"
      ;;
    warn)
      # Non-blocking: surface the scan's own explanation and let it proceed.
      pn_record_successful_scan
      if [[ -n "$PN_SCAN_MESSAGE" ]]; then
        json_permission_allow "$PN_SCAN_MESSAGE"
      else
        json_permission_allow
      fi
      ;;
    *)
      # "allow"
      pn_record_successful_scan
      if [[ -n "$PN_SCAN_MESSAGE" ]]; then
        json_permission_allow "$PN_SCAN_MESSAGE"
      else
        json_permission_allow
      fi
      ;;
  esac

  return 0
}

main
exit $?
