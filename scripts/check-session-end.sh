#!/bin/bash
# sessionEnd hook: finalizes this conversation's Code Chain session, if one
# was ever registered (check-session.sh's sessionStart, or lazily by
# check-git-event-record.sh/check-turn-complete.sh). A session that never
# touched git or produced a recorded turn has no cache entry -- a normal
# no-op, not an error. Per Cursor's hooks contract this is fire-and-forget;
# it cannot affect session teardown.
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
source "$SCRIPT_DIR/lib/codechain-client.sh"
source "$SCRIPT_DIR/pn_config.sh"

CODECHAIN_TIMEOUT_SECONDS="${PARADIGM_NETWORKS_CODECHAIN_TIMEOUT:-5}"

main() {
  local payload=""
  if [[ ! -t 0 ]]; then
    payload=$(cat 2>/dev/null)
  fi

  [[ -z "$JQ_BIN" ]] && return 0
  [[ -z "$payload" ]] && return 0
  echo "$payload" | "$JQ_BIN" empty 2>/dev/null || return 0

  local client_session_id
  client_session_id=$(echo "$payload" | "$JQ_BIN" -r '.conversation_id // .session_id // ""')
  [[ -z "$client_session_id" ]] && return 0

  pn_is_configured || return 0
  local config
  config=$(pn_resolve_config) || return 0
  local base_url access_token
  read -r base_url access_token <<<"$config"

  pn_close_codechain_session "$base_url" "$access_token" "$CODECHAIN_TIMEOUT_SECONDS" "$client_session_id"
  return 0
}

main
echo '{}'
exit 0
