#!/bin/bash
# afterAgentResponse hook: records the just-completed turn (user prompt +
# assistant response) to Code Chain. Fires once per completed assistant
# message -- NOT the "stop" hook, which per Cursor's docs
# (cursor.com/docs/agent/hooks) fires when "the agent loop ends" (a
# session/conversation-level signal, payload only {status, loop_count}), not
# per turn. That mismatch was a real bug: recording was wired to "stop" in
# an earlier version of this file and never fired for ordinary prompts in
# practice. afterAgentResponse's own payload directly carries the final
# assistant text (`.text`), used here as the authoritative Response --
# `.text` is preferred over anything parsed out of the transcript file, and
# only the Prompt half still needs to be recovered from transcript_path
# (afterAgentResponse's payload has no prompt field of its own).
# Purely observational: this hook contract has no blocking "permission"
# field to honor here, so this always returns {}.
# Known limitation, not fully resolved: Cursor's own docs describe
# afterAgentResponse as firing "after the agent has completed an assistant
# message" -- if a single user turn produces more than one assistant
# message (e.g. multiple tool-call round-trips before a final answer), this
# could record more than one turn per user prompt. Not reproduced or ruled
# out here; revisit if duplicate/fragmented turns show up in chatapi.
# See design-ideas/Codechain_Plugin_Hooks_Design.md.

set -o pipefail

# Dead code on the hook path -- see check-session.sh's identical comment.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo '{}'
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/git-utils.sh"
source "$SCRIPT_DIR/lib/plugins-client.sh"
source "$SCRIPT_DIR/pn_config.sh"

CODECHAIN_TIMEOUT_SECONDS="${PARADIGM_NETWORKS_CODECHAIN_TIMEOUT:-10}"
# Same window as check-write.sh's TRANSCRIPT_LINES -- a single turn is never
# remotely close to this many transcript lines in practice (see
# get_current_turn_messages' own doc in lib/common.sh).
TRANSCRIPT_LINES="${PARADIGM_NETWORKS_TRANSCRIPT_LINES:-500}"

main() {
  local payload=""
  if [[ ! -t 0 ]]; then
    payload=$(cat 2>/dev/null)
  fi

  [[ -z "$JQ_BIN" ]] && return 0
  [[ -z "$payload" ]] && return 0
  echo "$payload" | "$JQ_BIN" empty 2>/dev/null || return 0

  local transcript_path cwd client_session_id response_text generation_id model
  transcript_path=$(echo "$payload" | "$JQ_BIN" -r '.transcript_path // ""')
  cwd=$(echo "$payload" | "$JQ_BIN" -r '.cwd // (.workspace_roots // [])[0] // ""')
  client_session_id=$(echo "$payload" | "$JQ_BIN" -r '.conversation_id // .session_id // ""')
  response_text=$(echo "$payload" | "$JQ_BIN" -r '.text // ""')
  # Cursor's own generation_id -- changes per user turn, unlike
  # conversation_id (stable for the whole chat). Lets control-server match
  # this response to the exact prompt-scan it belongs to instead of guessing
  # from insertion order. Not confirmed present on every hook payload in
  # every Cursor build; the server degrades gracefully when empty.
  generation_id=$(echo "$payload" | "$JQ_BIN" -r '.generation_id // ""')
  # Cursor's own hook-reported model name -- the model that actually
  # produced this response. Stored on both RequestPayload and
  # ResponsePayload server-side. model_id ("Structured ID for the selected
  # model, when available", per Cursor's hooks docs) is preferred over the
  # legacy model slug (confirmed sending the literal "unknown" placeholder
  # on this hook's payload, 2026-09-22) -- see resolve_hook_model's header
  # comment in lib/common.sh.
  model_id=$(echo "$payload" | "$JQ_BIN" -r '.model_id // ""')
  model_legacy=$(echo "$payload" | "$JQ_BIN" -r '.model // ""')
  model=$(resolve_hook_model "$model_id" "$model_legacy")

  [[ -z "$client_session_id" ]] && return 0

  # The prompt has no field of its own on this hook's payload -- only
  # transcript_path can recover it. The response, by contrast, prefers
  # afterAgentResponse's own `.text` (the authoritative final assistant
  # text) and only falls back to the transcript-derived guess if `.text`
  # is somehow empty.
  local prompt_text="" response_from_transcript=""
  if [[ -n "$transcript_path" ]]; then
    get_current_turn_messages "$transcript_path" "$TRANSCRIPT_LINES"
    prompt_text="$PN_TURN_PROMPT"
    response_from_transcript="$PN_TURN_RESPONSE"
  fi
  [[ -z "$response_text" ]] && response_text="$response_from_transcript"

  if [[ -z "$prompt_text" ]] && [[ -z "$response_text" ]]; then
    return 0
  fi

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

  pn_plugin_after_agent_response "$base_url" "$access_token" "$CODECHAIN_TIMEOUT_SECONDS" \
    "$client_session_id" "$cwd" "$git_repo_url" "$git_branch" "$prompt_text" "$response_text" "$generation_id" "$model"

  return 0
}

main
echo '{}'
exit 0
