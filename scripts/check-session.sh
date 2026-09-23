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
source "$SCRIPT_DIR/lib/git-utils.sh"
source "$SCRIPT_DIR/lib/plugins-client.sh"
source "$SCRIPT_DIR/pn_config.sh"

CODECHAIN_TIMEOUT_SECONDS="${PARADIGM_NETWORKS_CODECHAIN_TIMEOUT:-5}"

# Drain stdin (hook may send payload)
if [[ ! -t 0 ]]; then
  stdin_data=$(cat 2>/dev/null)
fi

# Best-effort Code Chain session-start marker -- see design-ideas/
# Codechain_Plugin_Hooks_Design.md. Never affects this hook's own JSON
# output/exit code (sessionStart is fire-and-forget context injection
# regardless): if this fails, later hooks (check-tool-call-record,
# check-turn-complete) still record fine on their own -- they use the same
# client-supplied session id directly and don't depend on this call.
register_codechain_session() {
  [[ -z "$JQ_BIN" ]] && return 0
  [[ -z "$stdin_data" ]] && return 0
  echo "$stdin_data" | "$JQ_BIN" empty 2>/dev/null || return 0

  local client_session_id cwd
  client_session_id=$(echo "$stdin_data" | "$JQ_BIN" -r '.conversation_id // .session_id // ""')
  cwd=$(echo "$stdin_data" | "$JQ_BIN" -r '.cwd // (.workspace_roots // [])[0] // ""')
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

  pn_register_plugin_session "$base_url" "$access_token" "$CODECHAIN_TIMEOUT_SECONDS" \
    "$client_session_id" "$cwd" "$git_repo_url" "$git_branch"
}
# Backgrounded, not called inline: this must never delay the login-check
# message below, which is this hook's actual job. Genuinely best-effort — if
# the hook's process group is torn down at hooks.json's own timeout before
# this finishes, that is an acceptable, expected loss (later hooks retry
# registration idempotently), not a bug to work around here.
register_codechain_session &

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
