#!/bin/bash
# postToolUse hook: records a tool call's actual result once it has run.
# Makes MCP tool calls (e.g. a Jira-update workflow) and non-git Write/Shell
# calls visible in Code Chain. Pairs with check-tool-call.sh's preToolUse
# gate: correlated by Cursor's own stable .tool_use_id, present on both hook
# payloads, so no relay between the two separate hook-process invocations is
# needed -- see design-ideas/Plugin_API_Standardization_And_Hook_Consolidation_Design.md §5.
#
# Also now fires git/PR detection for Shell tool calls -- folded in from the
# retired afterShellExecution hook (see design-ideas/
# Shell_Execution_vs_Tool_Call_Hook_Coverage_Validation.md): forwards
# tool_name + tool_input so control-server can run the same detection
# pipeline when tool_name=="Shell", regardless of whether the command was a
# git command or not (control-server decides that from the command text).
#
# Also now feeds tool_output into control-server's own composite policy
# scan (PromptGuard+PolicyEngine+CodeDefense) -- server-side only, no
# client change needed for the scan itself; see design-ideas/
# Tool_Call_Policy_Enforcement_Assessment.md.
#
# Purely observational: postToolUse has no blocking "permission" field to
# honor, so this always returns {}, and this script does not read the scan
# verdict back from the response -- even a "block" verdict cannot undo a
# tool call that has already run. Best-effort -- a recording (or scanning)
# failure here must never surface to Cursor.

set -o pipefail

# Dead code on the hook path -- see check-session.sh's identical comment.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo '{}'
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/git-utils.sh"
source "$SCRIPT_DIR/lib/plugins-client.sh"
source "$SCRIPT_DIR/pn_config.sh"

# 60s (was 10s) -- control-server's after_tool_call now runs the same
# PromptGuard+PolicyEngine+CodeDefense composite scan before_tool_call
# does (see design-ideas/Tool_Call_Policy_Enforcement_Assessment.md),
# which can take up to ~65s worst case (30s CDS + 30s PromptGuard + 5s
# PolicyEngine, sequential) -- matches check-tool-call.sh's own
# TIMEOUT_SECONDS default for the same reason. hooks/hooks.json's
# postToolUse timeout was raised to 250s to match; this is the script's
# own HTTP client timeout, which must also be raised or it would cut the
# call off long before that budget is ever reached.
CODECHAIN_TIMEOUT_SECONDS="${PARADIGM_NETWORKS_CODECHAIN_TIMEOUT:-60}"
DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-tool-call-record.log"

main() {
  local payload=""
  if [[ ! -t 0 ]]; then
    payload=$(cat 2>/dev/null)
  fi

  [[ -z "$JQ_BIN" ]] && return 0
  [[ -z "$payload" ]] && return 0
  echo "$payload" | "$JQ_BIN" empty 2>/dev/null || return 0

  local tool_use_id client_session_id cwd generation_id tool_name tool_input_raw
  tool_use_id=$(echo "$payload" | "$JQ_BIN" -r '.tool_use_id // ""')
  client_session_id=$(echo "$payload" | "$JQ_BIN" -r '.conversation_id // .session_id // ""')
  cwd=$(echo "$payload" | "$JQ_BIN" -r '.cwd // (.workspace_roots // [])[0] // ""')
  generation_id=$(echo "$payload" | "$JQ_BIN" -r '.generation_id // ""')
  # tool_name/tool_input: only used server-side to detect a Shell command and
  # run git/PR detection against it (see this file's header) -- absent for
  # any tool call Cursor's postToolUse payload doesn't carry them for.
  tool_name=$(echo "$payload" | "$JQ_BIN" -r '.tool_name // ""')
  tool_input_raw=$(echo "$payload" | "$JQ_BIN" -c '.tool_input // {}')

  # Nothing to correlate this result to without the id preToolUse's call
  # would have used -- best-effort, not an error.
  if [[ -z "$tool_use_id" ]]; then
    log_debug "No tool_use_id on postToolUse payload; nothing to record against." "$DEBUG_LOG_PATH"
    return 0
  fi
  [[ -z "$client_session_id" ]] && return 0

  # tool_output's shape varies by tool -- a Shell/Write call's output is
  # typically a plain string, but an MCP tool's result can be a structured
  # object. Serialize whatever is there as text so there's always something
  # to record, rather than silently dropping a non-string result.
  local tool_output
  tool_output=$(echo "$payload" | "$JQ_BIN" -r 'if (.tool_output | type) == "string" then .tool_output else (.tool_output | tostring) end // ""')

  pn_is_configured || return 0
  local config
  config=$(pn_resolve_config) || return 0
  local base_url access_token
  read -r base_url access_token <<<"$config"

  local git_repo_url="" git_branch=""
  if [[ -n "$cwd" ]] && [[ -d "$cwd/.git" ]]; then
    git_repo_url=$(get_remote_url_or_empty "$cwd")
    git_branch=$(get_current_branch_or_empty "$cwd")
  fi

  pn_plugin_after_tool_call "$base_url" "$access_token" "$CODECHAIN_TIMEOUT_SECONDS" \
    "$client_session_id" "$cwd" "$git_repo_url" "$git_branch" "$tool_use_id" "$tool_output" "false" "$generation_id" \
    "$tool_name" "$tool_input_raw"

  return 0
}

main
echo '{}'
exit 0
