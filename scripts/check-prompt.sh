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
SCAN_URL_OVERRIDE="${SNANTIZER_SCAN_URL:-}"
TIMEOUT_SECONDS="${SNANTIZER_TIMEOUT:-20}"
DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-prompt.log"

# codedefense/scan is retired; this now calls the Anthropic-compatible
# /v1/messages endpoint on the same backend, which requires a model.
# DEFAULT_MODEL is the last-resort fallback: cheap/fast tier, chosen
# because testing showed the block/allow verdict is identical across
# models and max_tokens values -- the platform's guard fires before the
# requested model ever runs, so model choice only affects cost/latency on
# the (always-discarded) allow-path reply, not detection accuracy.
DEFAULT_MODEL="anthropic/claude-haiku-4-5-20251001"
# Precedence: PARADIGM_NETWORKS_MODEL env var (a manual override -- only
# takes effect if something exports it directly into the process
# environment, e.g. a shared-host setup; there is no Cursor Settings UI
# for this -- an earlier version had one, but it was removed after
# confirming, against a real installed plugin, that Cursor's plugin
# Settings panel never delivers configured values to hook scripts) > the
# model saved locally via the paradigmnetworks-models skill / set-model.sh
# (pn_get_preferred_model, in pn_config.sh -- this is the real,
# user-facing way to change it) > hardcoded default.
MODEL="${PARADIGM_NETWORKS_MODEL:-}"
if [[ -z "$MODEL" ]]; then
  MODEL="$(pn_get_preferred_model)"
fi
if [[ -z "$MODEL" ]]; then
  MODEL="$DEFAULT_MODEL"
fi
# 150 comfortably covers the block banner + reason sentence; confirmed via
# live testing that the banner is injected by the guard without ever being
# subject to max_tokens (output_tokens is 0 even for the full banner), so
# this only trades off cost/latency on the allow path, not truncation risk.
MAX_TOKENS=150

# PARADIGM_NETWORKS_PROMPT_FAILURE_MODE (manual env var override:
# block/allow — no Cursor Settings UI for this, must be set directly in
# the environment) takes precedence; SNANTIZER_PROMPT_FAILURE_MODE (legacy
# shared-host override: closed/open) is the fallback. Defaults to "open" (unlike
# check-write.sh's PARADIGM_NETWORKS_FAILURE_MODE, which defaults to
# "closed"). This only governs failures below that happen *after*
# pn_resolve_config succeeds — i.e. the user is already logged in.
# "Paradigm Networks not configured" and "jq missing" always allow
# unconditionally, regardless of this setting, so a not-yet-logged-in user
# (or a machine without jq) can never get stuck on their first message.
RAW_PROMPT_FAILURE_MODE=$(echo "${PARADIGM_NETWORKS_PROMPT_FAILURE_MODE:-${SNANTIZER_PROMPT_FAILURE_MODE:-allow}}" | tr '[:upper:]' '[:lower:]')
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
      if [[ "$PROMPT_FAILURE_MODE" == "closed" ]]; then
        json_deny "${anomaly_prefix}The scanning service returned an unexpected response. Prompt blocked."
      else
        json_allow "${anomaly_prefix}The scanning service returned an unexpected response. Allowing prompt."
      fi
      ;;
    block)
      pn_reset_scan_anomaly
      # EXPERIMENT (revert to the plain "[Paradigm Networks] $message"
      # form if this doesn't render as intended): confirmed **bold**,
      # blank-line breaks, and `inline code` all render correctly in
      # Cursor's UI. `### heading` and `> blockquote` below are new,
      # untested here -- worth checking specifically.
      #
      # PN_MSG_MESSAGE is already the extracted reason (pn_parse_messages_
      # response applies the same "security concerns: X" pattern before
      # returning it) -- no second extraction pass needed here.
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

      local branded_message="### 🛡️ Request blocked by Paradigm Networks

This message wasn't sent to the model. Your organization's proxy inspects
outbound requests and held this one for review.

**Concern** \`$reason\`

**Flagged content**

> $flagged_preview"
      json_deny "$branded_message"
      ;;
    *)
      # "allow" is the only other action pn_parse_messages_response
      # produces -- there is no "warn" state on this endpoint (see that
      # function's comment); the model's actual reply is discarded either
      # way, only the verdict matters.
      pn_reset_scan_anomaly
      json_allow
      ;;
  esac

  return 0
}

main
exit $?
