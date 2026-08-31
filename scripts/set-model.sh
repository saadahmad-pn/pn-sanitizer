#!/bin/bash
# Saves the user's preferred AI model for prompt/write scanning.
# Usage: set-model.sh <model-id>
#
# Standalone CLI script (invoked by the paradigmnetworks-models skill),
# not a hook -- so unlike the hook scripts, nothing runs it
# unconditionally on every platform, meaning there's no double-execution
# risk to guard against, only a wrong-script risk if the agent runs this
# on Windows instead of the .ps1 sibling (same reasoning as login.sh's
# guard).
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "error: this is the Unix script. On Windows, run set-model.ps1 instead (via scripts/run-powershell.cmd set-model.ps1)." >&2
    exit 1
    ;;
esac

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/pn_config.sh"

TIMEOUT_SECONDS=20

main() {
  if [[ -z "$JQ_BIN" ]]; then
    echo "error: jq is required but not found, and no bundled copy is available for this platform. Install it (macOS: brew install jq; Linux: apt-get/dnf/pacman install jq), then try again." >&2
    return 1
  fi

  local model_id="${1:-}"
  if [[ -z "$model_id" ]]; then
    echo "error: usage: set-model.sh <model-id>" >&2
    return 1
  fi

  local config
  config=$(pn_resolve_config) || {
    echo "error: Paradigm Networks is not configured on this machine yet -- run the paradigmnetworks-login skill first." >&2
    return 1
  }

  local base_url
  local access_token
  read -r base_url access_token <<<"$config"

  # Best-effort validation against the live catalog before saving --
  # catches a typo'd or unavailable model id up front, rather than
  # letting it silently fail every real scan later. Deliberately not a
  # hard requirement: if the list itself can't be fetched right now
  # (timeout, connection error, invalid response), save what was asked
  # for anyway with a warning, matching this codebase's general posture
  # of not blocking on an unrelated, temporary failure.
  local models_url="${base_url%/}/v1/models?limit=100"
  local raw_response
  raw_response=$(http_get "$models_url" "$access_token" "$TIMEOUT_SECONDS")
  local curl_exit=$?
  http_post_split_status "$raw_response"

  if [[ $curl_exit -eq 0 ]] && [[ "$HTTP_POST_STATUS" == 2* ]] && echo "$HTTP_POST_BODY" | "$JQ_BIN" empty 2>/dev/null; then
    local is_known
    is_known=$(echo "$HTTP_POST_BODY" | "$JQ_BIN" --arg id "$model_id" '[.data[]? | select(.id == $id)] | length > 0')
    if [[ "$is_known" == "false" ]]; then
      echo "error: '$model_id' is not in your organization's available models. Run the paradigmnetworks-models skill to see the exact list, then try again." >&2
      return 1
    fi
  else
    echo "warning: couldn't verify '$model_id' against the live model list right now -- saving it anyway." >&2
  fi

  pn_save_preferred_model "$model_id" || {
    echo "error: failed to save the model preference." >&2
    return 1
  }

  echo "Saved. Prompts and writes will now be scanned using: $model_id"
  return 0
}

main "$@"
exit $?
