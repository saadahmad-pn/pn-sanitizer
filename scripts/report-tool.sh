#!/bin/bash
# afterShellExecution hook: reports a completed git/gh command, and its
# REAL output, so control-server's Code Chain feature can record commits,
# pushes and pull requests.
#
# WHY THIS EXISTS. Code Chain recognises a commit/push/PR from what the
# command PRINTED, never from the command alone -- a push's remote, a PR's
# URL, all come from the command's own real output. Every other hook in
# this repo runs on preToolUse/beforeSubmitPrompt, which fire BEFORE a
# command executes, so none of them ever has anything to report.
# afterShellExecution is the one event that fires with the command already
# run and its real output available -- confirmed directly against a real
# Cursor payload:
#   {"command": "gh pr create --base main ...", "session_id": "...",
#    "output": "https://github.com/acme/repo/pull/1\n",
#    "hook_event_name": "afterShellExecution", ...}
# (postToolUse fires for the same command too, but buries the same output
# one JSON-string-of-JSON deeper -- tool_output is itself a JSON string
# containing {"output": ..., "exitCode": ...} -- so afterShellExecution is
# used here, not postToolUse.)
#
# NOT A SECURITY CONTROL. It reports, it never blocks, and it always exits
# 0. It also always prints a bare "{}" and nothing else -- Cursor's hook
# contract has no notion of acting on a command that already finished, so
# there is nothing a richer response could do here, only risk of it being
# misread as an instruction on some future Cursor version.
#
# ONLY GIT/GH COMMANDS ARE SENT. A session runs many shell commands, of
# which only a handful are git/gh -- filtering here keeps report volume
# proportional to what Code Chain can actually use. The filter matches any
# git/gh invocation, not just commit/push/pr-create specifically, so a
# command shape control-server's detector learns to read later does not
# need a client change to start arriving.
#
# BACKEND DEPENDENCY NOT VERIFIABLE FROM THIS REPO: this envelope shape
# (a JSON object embedded as plain text inside one user message, tagged
# with X-Paradigm-Client) mirrors a sibling Paradigm Networks integration
# whose traffic control-server has a dedicated reader for. Whether
# control-server also reads this shape for the "cursor" vendor tag is a
# backend-side question this script cannot confirm on its own.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/git-utils.sh"
source "$SCRIPT_DIR/pn_config.sh"

# Identifies this plugin to the backend's vendor-classification engine --
# same value check-prompt.sh/check-write.sh send. Distinct from
# pn_config.sh's own CLIENT_ID ("cursor-plugin"), an unrelated OAuth value.
PN_CLIENT_ID="cursor"

# Small on purpose: control-server reads the git facts out of the request
# payload itself; the model's own reply is discarded, so paying for a long
# one is pure waste.
MODEL="${PARADIGM_NETWORKS_MODEL:-${PN_DEFAULT_MODEL:-}}"
MAX_TOKENS="${PARADIGM_NETWORKS_REPORT_MAX_TOKENS:-64}"
# Generous on purpose: the POST is DETACHED (see the dispatch in main), so
# this timeout only bounds a stuck background curl and costs the developer
# nothing. A real report call runs a full scan plus a model generation
# server-side -- a short timeout here would just mean the report never
# arrives, not that anything waits on it.
TIMEOUT_SECONDS="${PARADIGM_NETWORKS_REPORT_TIMEOUT:-120}"

# is_git_command: true for git/gh invocations anywhere in the command
# line, so `cd foo && git commit ...` and `git add x && git commit -m y`
# both match. Held in a variable, not written inline: bash's [[ ]] parser
# treats a bare `|`/`(` in the pattern position as shell syntax rather than
# regex if the pattern isn't quoted into a variable first.
is_git_command() {
  local cmd="$1"
  local re='(^|[^[:alnum:]_])(git|gh)([[:space:]]|$)'
  [[ "$cmd" =~ $re ]]
}

main() {
  # No jq, no parsing. This hook never explains itself either way.
  [[ -z "$JQ_BIN" ]] && return 0
  # Not signed in -- nothing to report to, and this hook must not nag.
  pn_is_configured || return 0

  local payload=""
  if [[ ! -t 0 ]]; then
    payload=$(cat 2>/dev/null)
  fi
  [[ -z "$payload" ]] && return 0

  # session_id is not optional: control-server reads it only from
  # X-Claude-Code-Session-Id and drops a report before doing anything if
  # it's absent. A real afterShellExecution payload already carries
  # session_id directly; conversation_id is kept as a fallback only for
  # parity with check-prompt.sh/check-write.sh's own extraction.
  local session_id
  session_id=$(printf '%s' "$payload" | "$JQ_BIN" -r '.session_id // .conversation_id // ""' 2>/dev/null)
  [[ -z "$session_id" ]] && return 0

  local hook_event_name command output
  hook_event_name=$(printf '%s' "$payload" | "$JQ_BIN" -r '.hook_event_name // "afterShellExecution"' 2>/dev/null)
  command=$(printf '%s' "$payload" | "$JQ_BIN" -r '.command // ""' 2>/dev/null)
  output=$(printf '%s' "$payload" | "$JQ_BIN" -r '.output // ""' 2>/dev/null)

  # No command or no output means this fired before the command actually
  # ran, or produced nothing -- either way there is no git event to
  # recognise.
  [[ -z "$command" || -z "$output" ]] && return 0
  is_git_command "$command" || return 0

  # Strip credentials out of any URL the command's real output happens to
  # contain (e.g. a remote URL with an embedded token) before it ever
  # leaves this machine -- same helper check-repo-context.sh already
  # relies on for the same reason.
  output="$(sanitize_git_value "$output")"

  local config base_url access_token
  config=$(pn_resolve_config) || return 0
  read -r base_url access_token <<<"$config"
  [[ -z "$base_url" || -z "$access_token" ]] && return 0
  local scan_url="${PARADIGM_NETWORKS_SCAN_URL_OVERRIDE:-${base_url%/}/v1/messages}"

  # hook_event_name is forwarded as whatever control-server's own field
  # said it was, rather than hardcoded, so this still reports correctly if
  # Cursor ever delivers the same real output through a differently-named
  # event.
  local envelope json_body
  envelope=$("$JQ_BIN" -n \
    --arg event "$hook_event_name" \
    --arg cmd "$command" \
    --arg out "$output" \
    '{hook_event_name: $event, tool_name: "Shell", tool_input: {command: $cmd}, tool_response: $out}')

  json_body=$("$JQ_BIN" -n \
    --arg model "$MODEL" \
    --argjson max_tokens "$MAX_TOKENS" \
    --arg content "$envelope" \
    '{model: $model, max_tokens: $max_tokens, stream: false, messages: [{role: "user", content: $content}]}')

  # DETACHED. Cursor waits for a hook to return before continuing, and a
  # real report call runs a full scan server-side -- posting inline would
  # stall the developer's next action on every single git command, for a
  # call whose reply nothing here ever reads. The subshell inherits the
  # functions/variables it needs, backgrounds the work, and this function
  # returns immediately; the curl is reparented and runs to completion on
  # its own.
  (
    http_post_json "$scan_url" "$json_body" "$access_token" "$TIMEOUT_SECONDS" "$session_id" "$PN_CLIENT_ID" >/dev/null 2>&1
  ) >/dev/null 2>&1 &

  return 0
}

main
# Unconditional: whatever path main took, the hook's own response is
# always this -- there is nothing for Cursor to act on either way, and
# main's exit status is never a reason to fail a tool call that has
# already succeeded and already returned.
echo '{}'
exit 0
