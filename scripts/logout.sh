#!/bin/bash
# Logs this workspace out of Paradigm Networks.
# Usage: logout.sh
#
# There is no server-side session/token to revoke -- login.sh's OAuth flow
# never calls anything resembling a revoke endpoint -- so removing the
# locally stored ~/.pn/credentials.json is the entire mechanism. Doesn't
# source lib/common.sh: nothing here needs $JQ_BIN, since the credentials
# file is removed outright rather than parsed, which also means this
# still works even if the file is corrupted or jq is unavailable.
#
# Standalone CLI script (invoked by the paradigmnetworks-logout skill), not
# a hook -- so unlike the hook scripts, nothing runs it unconditionally on
# every platform, meaning there's no double-execution risk to guard
# against, only a wrong-script risk if the agent runs this on Windows
# instead of the .ps1 sibling (same reasoning as login.sh's guard).
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "error: this is the Unix logout script. On Windows, run logout.ps1 instead (via powershell -File logout.ps1)." >&2
    exit 1
    ;;
esac

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/pn_config.sh"

main() {
  if [[ ! -f "$CRED_PATH" ]]; then
    echo "Not logged in -- no credentials file found at $CRED_PATH."
    return 0
  fi

  rm -f "$CRED_PATH" || {
    echo "error: failed to remove $CRED_PATH" >&2
    return 1
  }

  echo "Logged out of Paradigm Networks. Credentials removed from $CRED_PATH."

  # pn_resolve_config (pn_config.sh) checks these two env vars before ever
  # touching the credentials file -- if both are set, this logout has no
  # visible effect until they're unset, so say so rather than letting the
  # user believe they're fully logged out.
  if [[ -n "${PARADIGM_NETWORKS_URL:-}" ]] && [[ -n "${PARADIGM_NETWORKS_TOKEN:-}" ]]; then
    echo "Note: PARADIGM_NETWORKS_URL and PARADIGM_NETWORKS_TOKEN are still set in this environment and will be used instead of the removed file until unset."
  fi

  return 0
}

main
exit $?
