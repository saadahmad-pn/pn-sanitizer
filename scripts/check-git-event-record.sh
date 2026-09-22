#!/bin/bash
# afterShellExecution hook: records EVERY shell command's (command, output)
# pair to Code Chain, once it has actually run -- not just git push/commit/
# PR-create (matcher is "" in hooks.json, catch-all). Sibling to check-git-
# event.sh (which gates BEFORE execution, only for those three git commands,
# and cannot see output) -- see that script's header for why recording is
# split out into its own hook here. Purely observational: afterShellExecution
# has no "permission" field to honor, so this always returns {} regardless of
# outcome -- a recording failure here must never surface to the user or the
# agent as anything.
#
# Server-side (control-server's recordShellEventHandler), this command+output
# pair is folded into the currently-open turn's own RequestPayload as a
# tool_use/tool_result block pair -- not persisted as a document of its own --
# and control-server's existing git/PR-detection regex still runs against it
# unconditionally, so a commit/push/PR is still recognized and recorded to
# Code Chain's commit history regardless of what else this hook now sends.
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

  log_debug "raw payload received (len=${#payload})" "$DEBUG_LOG_PATH"

  # Every early-return below falls through to the unconditional `echo '{}'`
  # after main returns -- this hook never has anything else to say.
  [[ -z "$JQ_BIN" ]] && return 0
  [[ -z "$payload" ]] && return 0
  echo "$payload" | "$JQ_BIN" empty 2>/dev/null || return 0

  local command_text output cwd client_session_id generation_id
  command_text=$(echo "$payload" | "$JQ_BIN" -r '.command // ""')
  output=$(echo "$payload" | "$JQ_BIN" -r '.output // ""')
  cwd=$(echo "$payload" | "$JQ_BIN" -r '.cwd // ""')
  client_session_id=$(echo "$payload" | "$JQ_BIN" -r '.conversation_id // .session_id // ""')
  generation_id=$(echo "$payload" | "$JQ_BIN" -r '.generation_id // ""')

  log_debug "extracted | session=$client_session_id | generation_id=$generation_id | command_len=${#command_text} | output_len=${#output} | cwd=$cwd" "$DEBUG_LOG_PATH"

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

  pn_record_codechain_shell_event "$base_url" "$access_token" "$CODECHAIN_TIMEOUT_SECONDS" \
    "$client_session_id" "$cwd" "$git_repo_url" "$git_branch" "$command_text" "$output" "$generation_id"

  return 0
}

main
echo '{}'
exit 0
