#!/bin/bash
# sessionEnd hook: removes this conversation's local session-metadata file
# (see lib/session-metadata.sh). SessionId is Cursor's own conversation_id,
# used as-is. Per Cursor's hooks contract this is fire-and-forget; it cannot
# affect session teardown.
#
# Previously this recorded a session-end marker with control-server via the
# plugins API; that call was removed -- the marker had no processing/
# governance/observability/reporting consumer. See design-ideas/
# Session_Lifecycle_Simplification_And_Contract_Updates.md.

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
source "$SCRIPT_DIR/lib/session-metadata.sh"

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

  pn_remove_session_metadata "$client_session_id"
  return 0
}

main
echo '{}'
exit 0
