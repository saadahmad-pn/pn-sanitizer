#!/bin/bash
# Logs this workspace out of Paradigm Networks.
# Usage: logout.sh
#
# Two steps (PN-14676):
#   1. Best-effort revoke of the stored refresh token on the server, via
#      POST <base_url>/api/v1/plugin/revoke (RFC 7009 form fields: token,
#      token_type_hint=refresh_token, client_id). Without this, a copied
#      refresh token kept minting new tokens after logout.
#   2. Remove ~/.pn/credentials.json -- always, whatever step 1 returned.
#      A missing jq, a corrupted file, an unreachable server or a server
#      that doesn't support revoke yet must never leave the user logged in
#      locally; the outcome of step 1 is reported instead.
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

# lib/common.sh for $JQ_BIN, $JQ_INSTALL_HINT and urlencode_strict. Sourcing
# it never fails when jq is missing -- JQ_BIN is just left empty.
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/pn_config.sh"

REVOKE_TIMEOUT_SECONDS=10

# revoke_on_server
# Prints one line describing the outcome. Never fails the logout.
revoke_on_server() {
  if [[ -z "$JQ_BIN" ]]; then
    echo "Could not revoke the login on the server: jq is not installed. $JQ_INSTALL_HINT"
    return 0
  fi

  local base_url refresh_token
  base_url=$("$JQ_BIN" -r '.base_url // empty' "$CRED_PATH" 2>/dev/null)
  refresh_token=$("$JQ_BIN" -r '.refresh_token // empty' "$CRED_PATH" 2>/dev/null)
  if [[ -z "$base_url" || -z "$refresh_token" ]]; then
    echo "Could not revoke the login on the server: the stored credentials are incomplete or unreadable."
    return 0
  fi

  local body status
  body="token=$(urlencode_strict "$refresh_token")&token_type_hint=refresh_token&client_id=$(urlencode_strict "$CLIENT_ID")"
  # -o /dev/null -w http_code: only the status matters. curl prints 000 when
  # it gets no response at all (unreachable, timeout).
  status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${base_url%/}/api/v1/plugin/revoke" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-raw "$body" \
    --max-time "$REVOKE_TIMEOUT_SECONDS" 2>/dev/null)
  [[ -z "$status" ]] && status="000"

  case "$status" in
    2??) echo "Signed out on the server: the login was revoked." ;;
    404|405|501) echo "This Paradigm Networks server doesn't support revoking plugin logins yet, so the old login stays valid on the server until it expires." ;;
    000) echo "Could not reach the server to revoke the login, so it stays valid on the server until it expires." ;;
    *) echo "The server did not confirm the revoke (HTTP $status), so the old login may stay valid on the server until it expires." ;;
  esac
  return 0
}

main() {
  if [[ ! -f "$CRED_PATH" ]]; then
    echo "Not logged in -- no credentials file found at $CRED_PATH."
    return 0
  fi

  local revoke_result
  revoke_result=$(revoke_on_server)

  rm -f "$CRED_PATH" || {
    echo "error: failed to remove $CRED_PATH" >&2
    return 1
  }

  echo "Logged out of Paradigm Networks. Credentials removed from $CRED_PATH."
  echo "$revoke_result"

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
