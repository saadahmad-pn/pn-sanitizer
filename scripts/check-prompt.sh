#!/bin/bash
# beforeSubmitPrompt hook: scan prompt via Paradigm Networks API before submitting
# Returns {continue: true/false, user_message: "..."} to allow/block the prompt

set -o pipefail

# Dead code on the hook path: hooks.json now registers exactly one entry
# per event, dispatched by scripts/run-hook.cmd (bash here, PowerShell on
# Windows), so Cursor never spawns this script under Git Bash/MSYS2/Cygwin
# in the first place. Left in place only so this .sh still behaves
# correctly if someone invokes it directly under one of those.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo '{"continue": true}'
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/scan-client.sh"
source "$SCRIPT_DIR/pn_config.sh"

# Configuration from environment
TIMEOUT_SECONDS="${PARADIGM_NETWORKS_TIMEOUT:-60}"
DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-prompt.log"

# PARADIGM_NETWORKS_PROMPT_FAILURE_MODE (manual env var override:
# block/allow — no Cursor Settings UI for this, must be set directly in
# the environment). Defaults to "open" (unlike check-write.sh's
# PARADIGM_NETWORKS_FAILURE_MODE, which defaults to "closed"). This only
# governs failures below that happen *after* pn_resolve_config succeeds
# -- i.e. the user is already logged in. "Paradigm Networks not
# configured" and "jq missing" always allow unconditionally, regardless
# of this setting, so a not-yet-logged-in user (or a machine without jq)
# can never get stuck on their first message.
RAW_PROMPT_FAILURE_MODE=$(echo "${PARADIGM_NETWORKS_PROMPT_FAILURE_MODE:-allow}" | tr '[:upper:]' '[:lower:]')
case "$RAW_PROMPT_FAILURE_MODE" in
  block|closed) PROMPT_FAILURE_MODE="closed" ;;
  *)            PROMPT_FAILURE_MODE="open" ;;
esac

main() {
  # Read and validate JSON from stdin (skip if nothing is piped in — avoids
  # hanging when invoked without a payload, e.g. manual testing)
  local payload=""
  if [[ ! -t 0 ]]; then
    payload=$(cat 2>/dev/null)
  fi

  # jq is required for everything below (a system install or the bundled
  # fallback in scripts/bin/ — see JQ_BIN in lib/common.sh). Always fail open
  # here regardless of PROMPT_FAILURE_MODE — this could trip before the user
  # has ever logged in, so it must stay unconditional for the same reason
  # "not configured" does below. Uses a hand-written literal since the JSON
  # helpers themselves depend on jq.
  if [[ -z "$JQ_BIN" ]]; then
    echo '{"continue": true, "user_message": "No usable jq was found on this machine or bundled for this platform. Allowing prompt. Install jq to enable scanning (see the plugin README)."}'
    return 0
  fi

  # Deliberately always allow here, unlike the PROMPT_FAILURE_MODE-driven
  # branches below: a malformed payload usually signals a Cursor
  # integration/encoding quirk, not an unreachable scanner. Routing it
  # through PROMPT_FAILURE_MODE would mean an affected machine gets every
  # single prompt blocked persistently, which is worse than a transient
  # scanner outage -- and here the blast radius is the whole product, not
  # just file writes (see check-write.sh's identical handling of this
  # same situation for the write side).
  if ! echo "$payload" | "$JQ_BIN" empty 2>/dev/null; then
    log_debug "Received invalid/unparseable stdin payload; allowing prompt unscanned." "$DEBUG_LOG_PATH"
    json_allow "Received invalid input. Allowing prompt — it was not scanned."
    return 0
  fi

  # Extract prompt
  local prompt
  prompt=$(echo "$payload" | "$JQ_BIN" -r '.prompt // ""')

  # Resolve config
  local config
  config=$(pn_resolve_config) || {
    json_allow "Paradigm Networks is not configured (no login found). Allowing prompt — run the paradigmnetworks-login skill to authenticate Paradigm Networks. Don't have one yet? Sign up at https://signup.claude-demo.paradigmnetworks.ai/signup."
    return 0
  }

  local base_url
  local access_token
  read -r base_url access_token <<<"$config"

  log_debug "Scanning prompt | base_url=$base_url | prompt_len=${#prompt}" "$DEBUG_LOG_PATH"
  log_debug "Prompt preview: ${prompt:0:200}$([ ${#prompt} -gt 200 ] && echo '...' || true)" "$DEBUG_LOG_PATH"
  log_debug "Timeout: ${TIMEOUT_SECONDS}s" "$DEBUG_LOG_PATH"

  # pn_scan_text (lib/scan-client.sh) posts to POST /api/v1/codedefense/scan
  # -- no model invocation, a real structured action_to_take verdict instead
  # of the old /v1/messages zero-usage/banner-text heuristic. Called as a
  # plain statement, not $(...): it sets PN_SCAN_* as globals in this shell,
  # same contract as http_post_split_status above.
  pn_scan_text "$base_url" "$access_token" "$TIMEOUT_SECONDS" "$prompt"

  # These three failure states happen only after pn_resolve_config already
  # succeeded (the user is logged in), so it's safe to honor
  # PROMPT_FAILURE_MODE here — no onboarding deadlock risk.
  case "$PN_SCAN_STATUS" in
    timeout)
      if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
        json_deny "The scanning service timed out (${TIMEOUT_SECONDS}s). Prompt blocked."
      else
        json_allow "The scanning service timed out (${TIMEOUT_SECONDS}s). Allowing prompt."
      fi
      return 0
      ;;
    unreachable)
      if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
        json_deny "The scanning service is unreachable. Prompt blocked."
      else
        json_allow "The scanning service is unreachable. Allowing prompt."
      fi
      return 0
      ;;
    http_error)
      if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
        json_deny "The scanning service returned an error (HTTP ${PN_SCAN_HTTP_STATUS}). Prompt blocked."
      else
        json_allow "The scanning service returned an error (HTTP ${PN_SCAN_HTTP_STATUS}). Allowing prompt."
      fi
      return 0
      ;;
    invalid_json)
      if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
        json_deny "The scanning service returned an invalid response. Prompt blocked."
      else
        json_allow "The scanning service returned an invalid response. Allowing prompt."
      fi
      return 0
      ;;
  esac

  log_debug "Scan response received | action=$PN_SCAN_ACTION" "$DEBUG_LOG_PATH"

  # Return verdict
  case "$PN_SCAN_ACTION" in
    ""|null)
      # A valid JSON response with no recognized action_to_take -- an
      # unexpected response shape, not a confirmed verdict either way. Same
      # posture as an invalid-JSON or non-2xx response above: don't guess
      # allow or block.
      log_debug "Scan response shape unexpected (no recognized action_to_take)" "$DEBUG_LOG_PATH"
      local anomaly_streak
      anomaly_streak=$(pn_record_scan_anomaly)
      local anomaly_prefix=""
      if [[ "$anomaly_streak" -ge "$PN_ANOMALY_WARNING_THRESHOLD" ]]; then
        anomaly_prefix="⚠️ Security scanning has failed ${anomaly_streak} times in a row and may not be protecting you right now. Contact your administrator. "
      fi
      if [[ -n "$PN_SCAN_MESSAGE" ]]; then
        if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
          json_deny "${anomaly_prefix}${PN_SCAN_MESSAGE}"
        else
          json_allow "${anomaly_prefix}${PN_SCAN_MESSAGE}"
        fi
      else
        if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
          json_deny "${anomaly_prefix}The scanning service returned an unexpected response. Prompt blocked."
        else
          json_allow "${anomaly_prefix}The scanning service returned an unexpected response. Allowing prompt."
        fi
      fi
      ;;
    block)
      pn_record_successful_scan
      # Markdown formatting (**bold**, blank-line breaks, `inline code`,
      # `### heading`, and `> blockquote`) confirmed rendering correctly
      # in Cursor's UI.
      local reason="$PN_SCAN_MESSAGE"
      [[ -z "$reason" ]] && reason="A policy violation was detected."

      # Preview of the actual prompt that got flagged, capped at 60 words
      # so a long prompt doesn't blow up the message. Collapsed to a
      # single line first: markdown's ">" blockquote syntax only quotes
      # the line it's on, so a multi-line prompt would otherwise break out
      # of the quote after the first line.
      local flagged_preview
      flagged_preview=$(echo "$prompt" | tr '\n' ' ' | tr -s ' ')
      local prompt_word_count
      prompt_word_count=$(echo "$flagged_preview" | wc -w | tr -d ' ')
      flagged_preview=$(echo "$flagged_preview" | cut -d' ' -f1-60)
      if [[ "$prompt_word_count" -gt 60 ]]; then
        flagged_preview="${flagged_preview}..."
      fi

      # A single-line reason reads fine as an inline-code label; a
      # multi-line one (e.g. a structured findings report) does not --
      # markdown inline code spans aren't meant to carry embedded line
      # breaks, so a long reason gets its own section instead.
      local concern_section
      if [[ "$reason" == *$'\n'* ]]; then
        concern_section="**Concern**

$reason"
      else
        concern_section="**Concern** \`$reason\`"
      fi

      local branded_message="### 🛡️ Request blocked by Paradigm Networks

This message wasn't sent to the model. Your organization's proxy inspects
outbound requests and held this one for review.

$concern_section

**Flagged content**

> $flagged_preview"
      json_deny "$branded_message"
      ;;
    warn)
      # Non-blocking: surface the scan's own explanation as a notice and
      # let the prompt proceed.
      pn_record_successful_scan
      if [[ -n "$PN_SCAN_MESSAGE" ]]; then
        json_allow "$PN_SCAN_MESSAGE"
      else
        json_allow
      fi
      ;;
    *)
      # "allow"
      pn_record_successful_scan
      if [[ -n "$PN_SCAN_MESSAGE" ]]; then
        json_allow "$PN_SCAN_MESSAGE"
      else
        json_allow
      fi
      ;;
  esac

  return 0
}

main
exit $?
