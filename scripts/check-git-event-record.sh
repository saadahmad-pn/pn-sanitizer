#!/bin/bash
# afterShellExecution hook: records a git push/commit/PR-create command's
# OUTPUT to Code Chain, once it has actually run. Sibling to check-git-
# event.sh (which gates BEFORE execution and cannot see output) -- see that
# script's header for why recording is split out into its own hook here.
# Purely observational: afterShellExecution has no "permission" field to
# honor, so this always returns {} regardless of outcome -- a recording
# failure here must never surface to the user or the agent as anything.
# See design-ideas/Codechain_Plugin_Hooks_Design.md.

set -o pipefail

# Dead code on the hook path -- see check-git-event.sh's identical comment.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo '{}'
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/git-utils.sh"
source "$SCRIPT_DIR/lib/codechain-client.sh"
source "$SCRIPT_DIR/pn_config.sh"

CODECHAIN_TIMEOUT_SECONDS="${PARADIGM_NETWORKS_CODECHAIN_TIMEOUT:-10}"
DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-git-event-record.log"

main() {
  local payload=""
  if [[ ! -t 0 ]]; then
    payload=$(cat 2>/dev/null)
  fi

  # Every early-return below falls through to the unconditional `echo '{}'`
  # after main returns -- this hook never has anything else to say.
  [[ -z "$JQ_BIN" ]] && return 0
  [[ -z "$payload" ]] && return 0
  echo "$payload" | "$JQ_BIN" empty 2>/dev/null || return 0

  local command_text output cwd client_session_id
  command_text=$(echo "$payload" | "$JQ_BIN" -r '.command // ""')
  output=$(echo "$payload" | "$JQ_BIN" -r '.output // ""')
  cwd=$(echo "$payload" | "$JQ_BIN" -r '.cwd // ""')
  client_session_id=$(echo "$payload" | "$JQ_BIN" -r '.conversation_id // .session_id // ""')

  [[ -z "$command_text" ]] && return 0
  [[ -z "$client_session_id" ]] && return 0

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

  pn_get_codechain_session_id "$base_url" "$access_token" "$CODECHAIN_TIMEOUT_SECONDS" \
    "$client_session_id" "$cwd" "$git_repo_url" "$git_branch" "cursor-hooks"
  if [[ -z "$PN_CODECHAIN_SESSION_ID" ]]; then
    log_debug "codechain: no session id available, skipping shell-event recording" "$DEBUG_LOG_PATH"
    return 0
  fi

  pn_record_codechain_shell_event "$base_url" "$access_token" "$CODECHAIN_TIMEOUT_SECONDS" \
    "$PN_CODECHAIN_SESSION_ID" "$command_text" "$output" "$cwd"

  return 0
}

main
echo '{}'
exit 0
