#!/bin/bash
# stop hook: records the just-completed turn (user prompt + assistant
# response) to Code Chain. Fires once per turn, after the assistant is done
# responding -- the only point at which both halves of a turn exist, which is
# why recording happens here rather than at beforeSubmitPrompt (which only
# has the prompt) or some other combination requiring cross-process state.
# Purely observational: stop's hook contract has no blocking "permission"
# field to honor here (aside from the unrelated auto-followup mechanism this
# script does not use), so this always returns {}.
# See design-ideas/Codechain_Plugin_Hooks_Design.md.

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
source "$SCRIPT_DIR/lib/codechain-client.sh"
source "$SCRIPT_DIR/pn_config.sh"

CODECHAIN_TIMEOUT_SECONDS="${PARADIGM_NETWORKS_CODECHAIN_TIMEOUT:-10}"
# Same window as check-write.sh's TRANSCRIPT_LINES -- a single turn is never
# remotely close to this many transcript lines in practice (see
# get_current_turn_messages' own doc in lib/common.sh).
TRANSCRIPT_LINES="${PARADIGM_NETWORKS_TRANSCRIPT_LINES:-500}"
DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-turn-complete.log"

main() {
  local payload=""
  if [[ ! -t 0 ]]; then
    payload=$(cat 2>/dev/null)
  fi

  [[ -z "$JQ_BIN" ]] && return 0
  [[ -z "$payload" ]] && return 0
  echo "$payload" | "$JQ_BIN" empty 2>/dev/null || return 0

  local transcript_path cwd client_session_id
  transcript_path=$(echo "$payload" | "$JQ_BIN" -r '.transcript_path // ""')
  cwd=$(echo "$payload" | "$JQ_BIN" -r '.cwd // (.workspace_roots // [])[0] // ""')
  client_session_id=$(echo "$payload" | "$JQ_BIN" -r '.conversation_id // .session_id // ""')

  [[ -z "$transcript_path" ]] && return 0
  [[ -z "$client_session_id" ]] && return 0

  get_current_turn_messages "$transcript_path" "$TRANSCRIPT_LINES"
  if [[ -z "$PN_TURN_PROMPT" ]] && [[ -z "$PN_TURN_RESPONSE" ]]; then
    return 0
  fi

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
    log_debug "codechain: no session id available, skipping turn recording" "$DEBUG_LOG_PATH"
    return 0
  fi

  pn_record_codechain_turn "$base_url" "$access_token" "$CODECHAIN_TIMEOUT_SECONDS" \
    "$PN_CODECHAIN_SESSION_ID" "$PN_TURN_PROMPT" "$PN_TURN_RESPONSE"

  return 0
}

main
echo '{}'
exit 0
