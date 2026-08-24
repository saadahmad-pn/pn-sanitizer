#!/bin/bash
# sessionStart hook: check if Paradigm Networks is configured, ask user to login if not
# Per Cursor's hooks contract, this is fire-and-forget — it cannot prevent
# session creation but can inject context into the system prompt.

set -o pipefail

# On Windows, this same hook event also has a PowerShell entry (run via
# scripts/run-powershell.cmd) that does the real work -- Cursor has no way
# to run only one entry per platform per event (confirmed against Cursor's
# own hooks documentation), so both are always present in hooks.json. If
# bash happens to be available anyway (Git Bash, MSYS2, Cygwin), this would
# otherwise run a second time for the same event. Defer to the PowerShell
# entry instead.
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
    # Configured, return no-op
    echo '{}'
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
