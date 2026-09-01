#!/bin/bash
# Fetches and displays the AI models available to the logged-in user's
# Paradigm Networks org, via GET {base_url}/v1/models -- shows the exact
# model IDs that can be passed to set-model.sh to change which model is
# used for scanning prompts and writes (an earlier version had a Cursor
# plugin Settings field for this, but it was removed -- it never actually
# reached hook scripts -- see check-prompt.sh's comment on its own MODEL
# resolution for how that was confirmed; set-model.sh/pn_save_preferred_model
# is the real mechanism).
# Standalone CLI script (invoked by the paradigmnetworks-models skill),
# not a hook -- so unlike the hook scripts, nothing runs it
# unconditionally on every platform, meaning there's no
# double-execution risk to guard against, only a wrong-script risk if
# the agent runs this on Windows instead of the .ps1 sibling (same
# reasoning as login.sh's guard).
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "error: this is the Unix script. On Windows, run paradigmnetworks-models.ps1 instead (via scripts/run-powershell.cmd paradigmnetworks-models.ps1)." >&2
    exit 1
    ;;
esac

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/pn_config.sh"

TIMEOUT_SECONDS=60

main() {
  if [[ -z "$JQ_BIN" ]]; then
    echo "error: jq is required but not found, and no bundled copy is available for this platform. Install it (macOS: brew install jq; Linux: apt-get/dnf/pacman install jq), then try again." >&2
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

  local models_url="${base_url%/}/v1/models?limit=100"

  local raw_response
  raw_response=$(http_get "$models_url" "$access_token" "$TIMEOUT_SECONDS")
  local curl_exit=$?
  http_post_split_status "$raw_response"

  if [[ $curl_exit -eq 28 ]]; then
    echo "error: timed out after ${TIMEOUT_SECONDS}s reaching $models_url" >&2
    return 1
  elif [[ $curl_exit -ne 0 ]]; then
    echo "error: could not reach $models_url" >&2
    return 1
  fi

  if [[ "$HTTP_POST_STATUS" != 2* ]]; then
    echo "error: $models_url returned HTTP $HTTP_POST_STATUS" >&2
    return 1
  fi

  if ! echo "$HTTP_POST_BODY" | "$JQ_BIN" empty 2>/dev/null; then
    echo "error: $models_url returned an invalid response" >&2
    return 1
  fi

  # Markdown on purpose, not plain text: this output is meant to be
  # relayed verbatim into a chat UI (see the paradigmnetworks-models
  # skill), which renders markdown -- backticked ids and real bullets
  # read far better there than the plain-indented text this used to
  # print. pn_resolve_model (pn_config.sh) is the same shared precedence
  # chain check-prompt.sh/check-write.sh use for their own MODEL, so this
  # can never drift from what's actually scanning prompts/writes.
  pn_resolve_model
  if [[ "$PN_RESOLVED_MODEL_IS_DEFAULT" == "true" ]]; then
    echo "**Currently scanning with:** \`$PN_RESOLVED_MODEL\` (default)"
  else
    echo "**Currently scanning with:** \`$PN_RESOLVED_MODEL\`"
  fi
  echo ""

  local count
  count=$(echo "$HTTP_POST_BODY" | "$JQ_BIN" '.data | length')
  if [[ "$count" -eq 0 ]]; then
    echo "No models are available for this account."
    return 0
  fi

  echo "**Available models:**"
  echo ""
  echo "$HTTP_POST_BODY" | "$JQ_BIN" -r '.data[] | "- `\(.id)` — \(.display_name)"'

  local has_more
  has_more=$(echo "$HTTP_POST_BODY" | "$JQ_BIN" -r '.has_more // false')
  if [[ "$has_more" == "true" ]]; then
    echo ""
    echo "_(more models exist beyond this list)_"
  fi

  return 0
}

main
exit $?
