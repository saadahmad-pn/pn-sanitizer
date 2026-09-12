#!/bin/bash
# sessionStart hook: check if Paradigm Networks is configured, ask user to login if not
# Per Cursor's hooks contract, this is fire-and-forget — it cannot prevent
# session creation but can inject context into the system prompt.

set -o pipefail

# Dead code on the hook path: hooks.json now registers exactly one entry
# per event, dispatched by scripts/run-hook.cmd (bash here, PowerShell on
# Windows), so Cursor never spawns this script under Git Bash/MSYS2/Cygwin
# in the first place. Left in place only so this .sh still behaves
# correctly if someone invokes it directly under one of those.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo '{}'
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/pn_config.sh"

# Drain stdin (hook may send payload)
if [[ ! -t 0 ]]; then
  stdin_data=$(cat 2>/dev/null)
fi

# Fail open: any error just returns empty context
main() {
  # Check whether jq is available — a system install or the bundled fallback
  # in scripts/bin/ (see JQ_BIN in lib/common.sh). Build this message by hand
  # (no json_session_context) since that helper — and every jq_* helper —
  # itself depends on jq.
  if [[ -z "$JQ_BIN" ]]; then
    local instructions
    read -r -d '' instructions <<'EOF' || true
No usable jq was found on this machine, and no bundled copy is available for
this platform. Please install jq:

macOS:  brew install jq
Linux:  sudo apt-get install jq  (Debian/Ubuntu)
        sudo dnf install jq      (Fedora/RHEL)
        sudo pacman -S jq        (Arch)

After installation, restart your session.
EOF
    echo "{\"additional_context\": \"${instructions//$'\n'/\\n}\"}"
    return 0
  fi

  # Check if Paradigm Networks is configured
  if pn_is_configured; then
    pn_check_scan_staleness
    if [[ "$PN_SCAN_STALE" == "true" ]]; then
      local stale_message
      read -r -d '' stale_message <<'EOF' || true
⚠️ Paradigm Networks security scanning hasn't completed a successful scan in over an hour (or hasn't completed one yet this session). Prompts and file writes may currently be going through unscanned. Check your network connection and Paradigm Networks login status; if this continues, contact your administrator.
EOF
      json_session_context "$stale_message"
    else
      echo '{}'
    fi
  else
    # Not configured, ask user to login
    local message
    read -r -d '' message <<'EOF' || true
Paradigm Networks is not configured for this workspace. Ask the user for their Paradigm Networks base URL (e.g. https://<org>.paradigmnetworks.ai; if they don't have one yet, they can sign up at https://signup.claude-demo.paradigmnetworks.ai/signup), then run the paradigmnetworks-login skill to authenticate before relying on Paradigm Networks-gated prompts or tool calls.
EOF
    json_session_context "$message"
  fi

  return 0
}

main
exit $?
