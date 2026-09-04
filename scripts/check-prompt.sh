#!/bin/bash
# beforeSubmitPrompt hook: scan prompt via Paradigm Networks API before submitting
# Returns {continue: true/false, user_message: "..."} to allow/block the prompt

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
    echo '{"continue": true}'
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/pn_config.sh"

# Configuration from environment
SCAN_URL_OVERRIDE="${PARADIGM_NETWORKS_SCAN_URL_OVERRIDE:-}"
TIMEOUT_SECONDS="${PARADIGM_NETWORKS_TIMEOUT:-240}"
DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-prompt.log"

# codedefense/scan is retired; this now calls the Anthropic-compatible
# /v1/messages endpoint on the same backend, which requires a model.
# pn_resolve_model (pn_config.sh) is the shared precedence chain (env var
# override > saved preference > hardcoded default) -- see its own
# comment for the full rationale. The hardcoded default is a cheap/fast
# tier, chosen because testing showed the block/allow verdict is
# identical across models and max_tokens values -- the platform's guard
# fires before the requested model ever runs, so model choice only
# affects cost/latency on the allow-path reply, not detection accuracy.
pn_resolve_model
MODEL="$PN_RESOLVED_MODEL"
# The block banner itself is never subject to max_tokens (confirmed via
# live testing: output_tokens is 0 even for the full banner, since the
# platform's guard injects it before the requested model runs at all), so
# this budget only governs the allow-path reply's length. Raised from an
# earlier 150 (which comfortably covered the banner but wasn't meant to
# cover anything else, back when that reply was discarded) now that the
# reply is surfaced to the user as user_message -- 150 would truncate most
# real answers (a plain "write me hello.py" reply alone ran ~224 output
# tokens in testing).
MAX_TOKENS=1024

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

  local scan_url="${SCAN_URL_OVERRIDE}"
  if [[ -z "$scan_url" ]]; then
    scan_url="${base_url%/}/v1/messages"
  fi

  # Log debug info
  log_debug "Scanning prompt | base_url=$base_url | scan_url=$scan_url | model=$MODEL | prompt_len=${#prompt}" "$DEBUG_LOG_PATH"
  log_debug "Request body: ${prompt:0:200}$([ ${#prompt} -gt 200 ] && echo '...' || true)" "$DEBUG_LOG_PATH"
  log_debug "Timeout: ${TIMEOUT_SECONDS}s" "$DEBUG_LOG_PATH"

  # Log request details
  log_debug "Sending POST request to $scan_url" "$DEBUG_LOG_PATH"

  # Built via jq -n --arg, not string interpolation: the prompt can contain
  # quotes/backslashes/newlines that must be escaped correctly, and jq
  # handles that safely where hand-built JSON would not.
  local json_body
  json_body=$("$JQ_BIN" -n \
    --arg model "$MODEL" \
    --argjson max_tokens "$MAX_TOKENS" \
    --arg content "$prompt" \
    '{model: $model, max_tokens: $max_tokens, stream: false, messages: [{role: "user", content: $content}]}')

  local response
  local raw_response
  raw_response=$(http_post_json "$scan_url" "$json_body" "$access_token" "$TIMEOUT_SECONDS")
  local curl_exit=$?
  http_post_split_status "$raw_response"
  response="$HTTP_POST_BODY"

  # Handle curl errors. These three branches run only after pn_resolve_config
  # already succeeded (the user is logged in), so it's safe to honor
  # PROMPT_FAILURE_MODE here — no onboarding deadlock risk.
  if [[ $curl_exit -eq 28 ]]; then
    # Timeout
    log_debug "API timeout | after ${TIMEOUT_SECONDS}s | url=$scan_url" "$DEBUG_LOG_PATH"
    if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
      json_deny "The scanning service timed out (${TIMEOUT_SECONDS}s). Prompt blocked."
    else
      json_allow "The scanning service timed out (${TIMEOUT_SECONDS}s). Allowing prompt."
    fi
    return 0
  elif [[ $curl_exit -ne 0 ]]; then
    # Connection error
    log_debug "API unreachable | curl exit=$curl_exit | url=$scan_url" "$DEBUG_LOG_PATH"
    if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
      json_deny "The scanning service is unreachable. Prompt blocked."
    else
      json_allow "The scanning service is unreachable. Allowing prompt."
    fi
    return 0
  fi

  # Reject non-2xx responses (expired/invalid token, server error, etc.)
  # before treating the body as a real verdict — a valid-JSON error body
  # (e.g. {"error": "unauthorized"}) would otherwise default to "allow" via
  # the // fallback below and silently mask the actual failure.
  if [[ "$HTTP_POST_STATUS" != 2* ]]; then
    log_debug "API HTTP error | status=$HTTP_POST_STATUS | url=$scan_url" "$DEBUG_LOG_PATH"
    if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
      json_deny "The scanning service returned an error (HTTP ${HTTP_POST_STATUS}). Prompt blocked."
    else
      json_allow "The scanning service returned an error (HTTP ${HTTP_POST_STATUS}). Allowing prompt."
    fi
    return 0
  fi

  # Validate response is JSON
  if ! echo "$response" | "$JQ_BIN" empty 2>/dev/null; then
    log_debug "API invalid JSON response | url=$scan_url" "$DEBUG_LOG_PATH"
    if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
      json_deny "The scanning service returned an invalid response. Prompt blocked."
    else
      json_allow "The scanning service returned an invalid response. Allowing prompt."
    fi
    return 0
  fi

  # pn_parse_messages_response (lib/common.sh) classifies this response --
  # see that function's comment for the full detection-rule rationale.
  # Called as a plain statement, not $(...): it sets PN_MSG_ACTION /
  # PN_MSG_MESSAGE as globals in this shell, same contract as
  # http_post_split_status above.
  pn_parse_messages_response "$response"
  local action="$PN_MSG_ACTION"

  log_debug "API response received | action=$action" "$DEBUG_LOG_PATH"

  # Return verdict
  case "$action" in
    anomaly)
      # Zero usage without the block banner -- an unrecognized response
      # shape, not a confirmed verdict either way. Same posture as an
      # invalid-JSON or non-2xx response above: don't guess allow or block.
      log_debug "API response shape unexpected (zero usage, no block banner) | url=$scan_url" "$DEBUG_LOG_PATH"
      local anomaly_streak
      anomaly_streak=$(pn_record_scan_anomaly)
      local anomaly_prefix=""
      if [[ "$anomaly_streak" -ge "$PN_ANOMALY_WARNING_THRESHOLD" ]]; then
        anomaly_prefix="⚠️ Security scanning has failed ${anomaly_streak} times in a row and may not be protecting you right now. Contact your administrator. "
      fi
      # PN_MSG_MESSAGE is a raw, truncated preview of whatever the backend
      # actually returned (see pn_preview_text) -- may be empty if there
      # was no text content at all to preview. Surfacing it beats a canned
      # sentence that reveals nothing about what actually happened.
      local anomaly_detail=""
      if [[ -n "$PN_MSG_MESSAGE" ]]; then
        anomaly_detail=" Raw response: \"$PN_MSG_MESSAGE\""
      fi
      if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
        json_deny "${anomaly_prefix}The scanning service returned an unexpected response.${anomaly_detail} Prompt blocked."
      else
        json_allow "${anomaly_prefix}The scanning service returned an unexpected response.${anomaly_detail} Allowing prompt."
      fi
      ;;
    block)
      pn_reset_scan_anomaly
      # Markdown formatting (**bold**, blank-line breaks, `inline code`,
      # `### heading`, and `> blockquote`) confirmed rendering correctly
      # in Cursor's UI.
      #
      # PN_MSG_MESSAGE is the block banner's own explanation, with only
      # the confirmed-fixed scaffolding stripped (pn_strip_block_banner
      # in lib/common.sh) -- no second extraction pass needed here. It's
      # already a complete explanation in the backend's own words, and
      # can be either a short phrase-in-a-sentence or a long multi-line
      # structured report, so the "Concern" section below has to handle
      # both shapes rather than assuming a short one-liner.
      local reason="$PN_MSG_MESSAGE"

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
    *)
      # "allow" is the only other action pn_parse_messages_response
      # produces -- there is no "warn" state on this endpoint (see that
      # function's comment). The backend is also a coding assistant, not
      # just a scanner, so its reply (PN_MSG_MESSAGE, full text on this
      # path) is surfaced as user_message rather than discarded -- may be
      # empty if there was no text content to show. Cursor's own hooks
      # docs describe user_message as shown "when blocked"; whether it's
      # actually rendered on an allow too is unconfirmed and being tested
      # live rather than assumed either way.
      pn_reset_scan_anomaly
      if [[ -n "$PN_MSG_MESSAGE" ]]; then
        json_allow "$PN_MSG_MESSAGE"
      else
        json_allow
      fi
      ;;
  esac

  return 0
}

main
exit $?
