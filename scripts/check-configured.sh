#!/bin/bash
# Reports whether this workspace has a stored Paradigm Networks login --
# prints CONFIGURED or NOT_CONFIGURED and always exits 0.
# Usage: check-configured.sh (no arguments)
#
# Exists so the paradigmnetworks-login skill's step 1 never has to
# hand-write its own file-existence check (`test -f ~/.pn/credentials.json`)
# as a raw Shell tool call -- a security scan flagged that literal command
# as an OWASP ASVS V14.2 finding ("Credentials file path exposed in
# command"): the hardcoded path reveals the credential store's location and
# naming convention. This script takes no arguments and its own invocation
# names no path at all, so there is nothing in the agent's command string
# for that finding to point at -- same shape as logout.sh (no arguments),
# and exempted from scanning the same way; see lib/login-detection.sh's
# pn_is_logout_command / pn_login_logout_exempt_reason.
#
# Mirrors the exact semantics of the raw check it replaces: a valid stored
# credentials file (pn_is_configured, which validates JSON shape, not just
# bare existence -- a strict improvement over a bare `-f` test) OR the
# PARADIGM_NETWORKS_URL/PARADIGM_NETWORKS_TOKEN env var pair. Deliberately
# NOT pn_resolve_config -- that also attempts a network token refresh on an
# expired token, which this quick, cheap check should not do.

set -o pipefail

# Unlike the hook scripts, this is invoked directly (by the login skill),
# not run unconditionally by Cursor on every platform -- so there's no
# double-execution risk to guard against here, only a wrong-script risk:
# same reasoning as login.sh's/logout.sh's identical guard.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "error: this is the Unix check script. On Windows, run check-configured.ps1 instead." >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/pn_config.sh"

main() {
  # No usable jq (system or bundled) means pn_is_configured can't actually
  # parse the credentials file -- report NOT_CONFIGURED rather than let a
  # bare empty-command error leak onto stdout/stderr. The env var pair is
  # still checked either way -- that path never touches jq.
  if [[ -z "$JQ_BIN" ]]; then
    if [[ -n "${PARADIGM_NETWORKS_URL:-}" ]] && [[ -n "${PARADIGM_NETWORKS_TOKEN:-}" ]]; then
      echo "CONFIGURED"
    else
      echo "NOT_CONFIGURED"
    fi
    return 0
  fi

  if pn_is_configured || { [[ -n "${PARADIGM_NETWORKS_URL:-}" ]] && [[ -n "${PARADIGM_NETWORKS_TOKEN:-}" ]]; }; then
    echo "CONFIGURED"
  else
    echo "NOT_CONFIGURED"
  fi
}

main
exit 0
