#!/bin/bash
# postToolUse hook: records a tool call's actual result once it has run --
# NEW, did not exist in any form before this round. This is the mechanism
# that makes MCP tool calls (e.g. a Jira-update workflow) and non-git
# Write/Shell calls visible in Code Chain for the first time. Pairs with
# check-tool-call.sh's preToolUse gate: correlated by Cursor's own stable
# .tool_use_id, present on both hook payloads, so no relay between the two
# separate hook-process invocations is needed -- see
# design-ideas/Plugin_API_Standardization_And_Hook_Consolidation_Design.md §5.
#
# Purely observational: postToolUse has no blocking "permission" field to
# honor, so this always returns {}. Best-effort -- a recording failure here
# must never surface to Cursor.

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

CODECHAIN_TIMEOUT_SECONDS="${PARADIGM_NETWORKS_CODECHAIN_TIMEOUT:-10}"
DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-tool-call-record.log"

main() {
  local payload=""
  if [[ ! -t 0 ]]; then
    payload=$(cat 2>/dev/null)
  fi

  [[ -z "$JQ_BIN" ]] && return 0
  [[ -z "$payload" ]] && return 0
  echo "$payload" | "$JQ_BIN" empty 2>/dev/null || return 0

  local tool_use_id client_session_id cwd generation_id
  tool_use_id=$(echo "$payload" | "$JQ_BIN" -r '.tool_use_id // ""')
  client_session_id=$(echo "$payload" | "$JQ_BIN" -r '.conversation_id // .session_id // ""')
  cwd=$(echo "$payload" | "$JQ_BIN" -r '.cwd // (.workspace_roots // [])[0] // ""')
  generation_id=$(echo "$payload" | "$JQ_BIN" -r '.generation_id // ""')

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
    "$client_session_id" "$cwd" "$git_repo_url" "$git_branch" "$tool_use_id" "$tool_output" "false" "$generation_id"

  return 0
}

main
echo '{}'
exit 0
