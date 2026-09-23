#!/bin/bash
# preToolUse hook: scan ANY tool call's input before it runs -- generalized
# from an earlier version scoped to only Write and Shell (Cursor has no
# separate "Edit" tool_name; all file modifications use "Write"). Now covers
# every tool type, including MCP tools (e.g. a Jira-update workflow), via
# Cursor's generic preToolUse hook (matcher "", catch-all) -- see
# design-ideas/Plugin_API_Standardization_And_Hook_Consolidation_Design.md §5.
# Returns {permission: "allow"/"deny", user_message: "...", agent_message: "..."}
#
# Paired with check-tool-call-record.sh (postToolUse), which records this
# call's actual result once the tool has run -- the two are correlated by
# Cursor's own stable .tool_use_id, present on both hook payloads, so no
# relay between the two separate hook-process invocations is needed.
#
# Also now absorbs what used to be the separate beforeShellExecution hook
# (retired, along with afterShellExecution): a git push/commit is detected
# from a Shell tool call's own command text (see the git_event_type block
# below) and its changed-file diff content is collected and attached the same
# way before_shell_execution used to -- see design-ideas/
# Shell_Execution_vs_Tool_Call_Hook_Coverage_Validation.md for why that
# domain couldn't simply be deleted (this file/check-tool-call-record.sh are
# what replace it).
#
# A git MCP server's own commit tool (tool_name "MCP:git_commit") is detected
# the same way and gets the same file-attachment treatment, sourced from the
# tool's own tool_input.files rather than local git-plumbing discovery -- see
# design-ideas/MCP_Git_Tool_Call_Detection_Gap_Analysis.md.

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
source "$SCRIPT_DIR/lib/plugins-client.sh"
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
DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-tool-call.log"

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

  # Extract tool name -- generalized to ANY tool, not just Write/Shell (see
  # this file's header). MCP tools arrive in the "MCP:<tool_name>" matcher
  # form when a matcher scopes to them specifically; this hook's own
  # hooks.json entry uses the catch-all matcher "", so tool_name here is
  # whatever Cursor reports verbatim (e.g. "Write", "Shell", or an MCP tool's
  # own name).
  local tool_name
  tool_name=$(echo "$payload" | "$JQ_BIN" -r '.tool_name // ""')
  if [[ -z "$tool_name" ]]; then
    json_permission_allow
    return 0
  fi

  # Tool-appropriate wording for user_message/agent_message below -- a
  # message that says "Write blocked" for a blocked shell command (or an MCP
  # tool call) would be actively misleading about what actually happened.
  local action_noun="Tool call"
  local action_desc="this tool call"
  case "$tool_name" in
    Write)
      action_noun="Write"
      action_desc="this write"
      ;;
    Shell)
      action_noun="Command"
      action_desc="this command"
      ;;
  esac

  # Detect a git push/commit inside a Shell command -- folded in from the old
  # beforeShellExecution hook (retired; see design-ideas/
  # Shell_Execution_vs_Tool_Call_Hook_Coverage_Validation.md). Unanchored,
  # whitespace-bounded rather than \b (not universally supported by bash's
  # regex engine across BSD/GNU) -- matches "git push", "cd repo && git
  # commit -m x", etc., mirroring Cursor's own former (also unanchored)
  # beforeShellExecution matchers. git.pr_create has no equivalent here: it
  # was never scanned pre-execution (no artifact to scan before a PR exists)
  # and needs no file attachment.
  #
  # An MCP git server's own commit tool names the action directly via
  # tool_name -- no command-string regex needed the way Shell requires (see
  # design-ideas/MCP_Git_Tool_Call_Detection_Gap_Analysis.md). No MCP push
  # equivalent is handled here: unlike commit, push never attaches file
  # content in either path (nothing new to scan -- a push moves
  # already-committed content). control-server's after_tool_call handles MCP
  # push detection separately, from SessionContext, not from anything this
  # script sends.
  local git_event_type="" files_json="[]"
  if [[ "$tool_name" == "Shell" ]]; then
    local shell_command
    shell_command=$(echo "$payload" | "$JQ_BIN" -r '.tool_input.command // ""')
    if [[ "$shell_command" =~ (^|[[:space:]])git[[:space:]]+push([[:space:]]|$) ]]; then
      git_event_type="git.push"
      action_noun="Push"
      action_desc="this push"
    elif [[ "$shell_command" =~ (^|[[:space:]])git[[:space:]]+commit([[:space:]]|$) ]]; then
      git_event_type="git.commit"
      action_noun="Commit"
      action_desc="this commit"
    fi
  elif [[ "$tool_name" == "MCP:git_commit" ]]; then
    git_event_type="git.commit"
    action_noun="Commit"
    action_desc="this commit"
  fi

  # Cursor's own stable correlator, present on both preToolUse and
  # postToolUse payloads -- see check-tool-call-record.sh, which reads the
  # SAME field from its own (separate-process) invocation to attach this
  # call's result with no relay needed between the two.
  local cursor_tool_use_id
  cursor_tool_use_id=$(echo "$payload" | "$JQ_BIN" -r '.tool_use_id // ""')

  # Extract scan context
  local agent_message
  local transcript_path
  local file_path
  local tool_input_raw

  agent_message=$(echo "$payload" | "$JQ_BIN" -r '.agent_message // ""' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  transcript_path=$(echo "$payload" | "$JQ_BIN" -r '.transcript_path // ""')
  file_path=$(echo "$payload" | "$JQ_BIN" -r '.tool_input.file_path // ""')
  # The tool's actual input, as JSON, verbatim -- this is what gets STORED
  # as the tool_use block (see lib/plugins-client.sh's pn_plugin_before_tool_call),
  # so it must be the real input, not a Write/Shell-specific extraction that
  # would silently drop everything an MCP tool's structured args carry.
  tool_input_raw=$(echo "$payload" | "$JQ_BIN" -c '.tool_input // {}')

  # Session id + cwd/git context for the scan call's chatapi join -- see
  # lib/plugins-client.sh's header. Same extraction pattern as every other
  # hook here (check-turn-complete.sh et al).
  local client_session_id cwd git_repo_url="" git_branch="" generation_id model
  client_session_id=$(echo "$payload" | "$JQ_BIN" -r '.conversation_id // .session_id // ""')
  cwd=$(echo "$payload" | "$JQ_BIN" -r '.cwd // (.workspace_roots // [])[0] // ""')
  # Cursor's own generation_id -- changes per user turn, unlike
  # conversation_id. Lets control-server fold this tool-call scan into the
  # SAME turn document as the prompt it belongs to -- see
  # lib/plugins-client.sh's header.
  generation_id=$(echo "$payload" | "$JQ_BIN" -r '.generation_id // ""')
  # model_id ("Structured ID for the selected model, when available", per
  # Cursor's hooks docs) is preferred over the legacy model slug -- see
  # resolve_hook_model's header comment in lib/common.sh.
  model_id=$(echo "$payload" | "$JQ_BIN" -r '.model_id // ""')
  model_legacy=$(echo "$payload" | "$JQ_BIN" -r '.model // ""')
  model=$(resolve_hook_model "$model_id" "$model_legacy")
  if [[ -n "$cwd" ]] && [[ -d "$cwd/.git" ]]; then
    git_repo_url=$(get_remote_url_or_empty "$cwd")
    git_branch=$(get_current_branch_or_empty "$cwd")
    # A detected git push/commit (see git_event_type above) with no git repo
    # at cwd has nothing to collect -- files_json stays "[]", same as any
    # other Shell command.
    if [[ -n "$git_event_type" ]]; then
      if [[ "$tool_name" == "MCP:git_commit" ]]; then
        # tool_input_raw (extracted above) already names exactly which files
        # the MCP tool committed -- see pn_build_files_json_from_paths's doc.
        local mcp_commit_files
        mcp_commit_files=$(echo "$tool_input_raw" | "$JQ_BIN" -r '.files // [] | .[]' 2>/dev/null)
        files_json=$(pn_build_files_json_from_paths "$cwd" "$mcp_commit_files")
      else
        files_json=$(pn_build_git_diff_files_json "$cwd" "$git_event_type")
      fi
    fi
  fi

  # Determine what to scan
  local turn_text=""
  if [[ -n "$transcript_path" ]]; then
    turn_text=$(get_current_turn_text "$transcript_path" "$TRANSCRIPT_LINES")
  fi
  [[ -z "$turn_text" ]] && turn_text="$agent_message"

  log_debug "tool_input | tool_name=$tool_name | file_path=$file_path | tool_input_len=${#tool_input_raw} | turn_text_len=${#turn_text} | tool_use_id=$cursor_tool_use_id" "$DEBUG_LOG_PATH"

  # If the tool call has no input at all AND no turn context either, there's
  # nothing to scan.
  if [[ -z "$tool_input_raw" || "$tool_input_raw" == "{}" ]] && [[ -z "$turn_text" ]]; then
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
      --arg command "$tool_input_raw" \
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

  log_debug "Scanning tool call | base_url=$base_url | tool_input_len=${#tool_input_raw} | turn_text_len=${#turn_text}" "$DEBUG_LOG_PATH"

  # pn_plugin_before_tool_call (lib/plugins-client.sh) posts to the
  # standardized tool-calls domain (Action=before_tool_call) -- runs the
  # composite PromptGuard+PolicyEngine+CodeDefense scan against turn_text
  # (ScanContext) + tool_input_raw (Input) together (plus files_json's
  # changed-file content, when a git push/commit was detected above),
  # appends a tool_use block onto the session's open turn, and returns a
  # ToolUseId. Called as a plain statement, not $(...): it sets PN_TOOLCALL_*
  # as globals in this shell. cursor_tool_use_id is passed through so
  # control-server uses Cursor's OWN id rather than minting one -- see this
  # file's header and lib/plugins-client.sh's doc comment.
  pn_plugin_before_tool_call "$base_url" "$access_token" "$TIMEOUT_SECONDS" "$client_session_id" "$cwd" "$git_repo_url" "$git_branch" "$tool_name" "$tool_input_raw" "$generation_id" "$model" "$cursor_tool_use_id" "$turn_text" "$files_json"

  case "$PN_TOOLCALL_STATUS" in
    no_session)
      # Every preToolUse payload observed so far has carried conversation_id,
      # so this is not expected in practice.
      audit_log_entry=$("$JQ_BIN" -n \
        --arg tool_name "$tool_name" \
        --arg file_path "$file_path" \
        --arg command "$tool_input_raw" \
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
        --arg command "$tool_input_raw" \
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
        --arg command "$tool_input_raw" \
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
        --arg command "$tool_input_raw" \
        --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
        --arg reason "api_http_error" \
        --arg detail "HTTP ${PN_TOOLCALL_HTTP_STATUS}" \
        '{tool_name: $tool_name, file_path: $file_path, command: $command, decision: $decision, reason: $reason, detail: $detail}')
      audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

      if [[ "$FAILURE_MODE" == "open" ]]; then
        json_permission_allow "The scanning service returned an error (HTTP ${PN_TOOLCALL_HTTP_STATUS}). ${action_noun} allowed WITHOUT a security scan."
      else
        json_permission_deny "The scanning service returned an error (HTTP ${PN_TOOLCALL_HTTP_STATUS}). ${action_noun} blocked." "The scanning service returned an error (HTTP ${PN_TOOLCALL_HTTP_STATUS}). Do not retry ${action_desc}."
      fi
      return 0
      ;;
    invalid_json)
      audit_log_entry=$("$JQ_BIN" -n \
        --arg tool_name "$tool_name" \
        --arg file_path "$file_path" \
        --arg command "$tool_input_raw" \
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
    --arg command "$tool_input_raw" \
    --arg decision "$PN_TOOLCALL_ACTION" \
    --arg threat_level "$PN_TOOLCALL_THREAT_LEVEL" \
    '{tool_name: $tool_name, file_path: $file_path, command: $command, decision: $decision, threat_level: $threat_level}')
  audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

  # Return verdict
  case "$PN_TOOLCALL_ACTION" in
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
      if [[ -n "$PN_TOOLCALL_MESSAGE" ]]; then
        if [[ "$FAILURE_MODE" == "open" ]]; then
          json_permission_allow "${anomaly_prefix}${PN_TOOLCALL_MESSAGE}"
        else
          json_permission_deny "${anomaly_prefix}${PN_TOOLCALL_MESSAGE}" "$PN_TOOLCALL_MESSAGE Do not retry ${action_desc}."
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
      local user_message="$PN_TOOLCALL_MESSAGE"
      [[ -z "$user_message" ]] && user_message="A policy violation was detected."
      json_permission_deny "$user_message" "$user_message $(build_stop_instruction "$action_desc")"
      ;;
    warn)
      # Non-blocking: surface the scan's own explanation and let it proceed.
      pn_record_successful_scan
      if [[ -n "$PN_TOOLCALL_MESSAGE" ]]; then
        json_permission_allow "$PN_TOOLCALL_MESSAGE"
      else
        json_permission_allow
      fi
      ;;
    *)
      # "allow"
      pn_record_successful_scan
      if [[ -n "$PN_TOOLCALL_MESSAGE" ]]; then
        json_permission_allow "$PN_TOOLCALL_MESSAGE"
      else
        json_permission_allow
      fi
      ;;
  esac

  return 0
}

main
exit $?
