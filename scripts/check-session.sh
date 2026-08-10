#!/bin/bash
# sessionStart hook: check if PN is configured, ask user to login if not
# Per Cursor's hooks contract, this is fire-and-forget — it cannot prevent
# session creation but can inject context into the system prompt.

set -o pipefail

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
  # Check if jq is available
  if ! command_exists jq; then
    local instructions
    read -r -d '' instructions <<'EOF' || true
jq is required but not found. Please install it:

macOS:  brew install jq
Linux:  sudo apt-get install jq  (Debian/Ubuntu)
        sudo dnf install jq      (Fedora/RHEL)
        sudo pacman -S jq        (Arch)

After installation, restart your session.
EOF
    json_session_context "$instructions"
    return 0
  fi

  # Check if PN is configured
  if pn_is_configured; then
    # Configured, return no-op
    echo '{}'
  else
    # Not configured, ask user to login
    local message
    read -r -d '' message <<'EOF' || true
PN is not configured for this workspace. Ask the user for their PN base URL (e.g. https://<org>.paradigmnetworks.ai), then run the pn-login skill to authenticate before relying on CodeDefense-gated prompts or tool calls.
EOF
    json_session_context "$message"
  fi

  return 0
}

main
exit $?
