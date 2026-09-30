#!/bin/bash
# beforeReadFile hook: report that an Agent Skill was loaded. Only that --
# not every file read.
#
# Cursor has no dedicated "skill invoked" hook event, and no hook payload
# carries a skill name. What Cursor does when it loads a skill is a plain
# read of that skill's SKILL.md, which beforeReadFile's own file_path gives
# us directly. lib/skill-detection.sh holds the path test, shared with
# check-tool-call.sh / check-tool-call-record.sh so the same read is not ALSO
# recorded as an ordinary Read tool call.
#
# NOT A SECURITY CONTROL. It reports, never blocks, and always allows --
# wired failClosed:false in hooks.json. The POST is detached: Cursor waits
# for a hook to return, and nothing here acts on the reply.

set -o pipefail

# Dead code on the hook path: hooks.json registers exactly one entry per
# event, dispatched by scripts/run-hook.cmd (bash here, PowerShell on
# Windows). Left in place only so this .sh behaves correctly if someone
# invokes it directly under Git Bash/MSYS2/Cygwin.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo '{"permission": "allow"}'
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/git-utils.sh"
source "$SCRIPT_DIR/lib/skill-detection.sh"
source "$SCRIPT_DIR/lib/plugins-client.sh"
source "$SCRIPT_DIR/pn_config.sh"

DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-skill-usage.log"
# Detached, so this only ever bounds a stuck background curl.
TIMEOUT_SECONDS="${PARADIGM_NETWORKS_SKILL_TIMEOUT:-30}"

respond_allow() {
  echo '{"permission": "allow"}'
  exit 0
}

payload=""
if [[ ! -t 0 ]]; then
  payload=$(cat 2>/dev/null)
fi
[[ -n "$payload" ]] || respond_allow

# No jq (system or bundled): nothing below can safely parse the payload, so
# skip detection rather than guess with string matching -- the same "jq is
# required" stance every other hook here takes.
[[ -n "$JQ_BIN" ]] || respond_allow

file_path=$(printf '%s' "$payload" | "$JQ_BIN" -r '.file_path // empty' 2>/dev/null)
pn_skill_name_from_path "$file_path" || respond_allow
skill_name="$PN_SKILL_NAME"

# Not signed in -- nothing to report to, and this hook must not nag. Logged
# even so: from the outside a hook that never delivers looks exactly like a
# working one, and that ambiguity is what made the first real failure here
# invisible.
if ! pn_is_configured; then
  log_debug "Skill use NOT reported | skill=$skill_name | not signed in" "$DEBUG_LOG_PATH"
  respond_allow
fi

# session_id/conversation_id are the same value in practice; generation_id
# changes per user turn and is what control-server attaches this use to the
# right turn with. No session id means no turn to attach to.
session_id=$(printf '%s' "$payload" | "$JQ_BIN" -r '.session_id // .conversation_id // ""' 2>/dev/null)
if [[ -z "$session_id" ]]; then
  log_debug "Skill use NOT reported | skill=$skill_name | no session_id in payload" "$DEBUG_LOG_PATH"
  respond_allow
fi
generation_id=$(printf '%s' "$payload" | "$JQ_BIN" -r '.generation_id // ""' 2>/dev/null)

# Content and digest both come off the file on disk, never the payload — see
# pn_collect_skill_content in lib/skill-detection.sh for why that matters.
pn_collect_skill_content "$file_path" || log_debug "Skill use reported WITHOUT content | skill=$skill_name | unreadable: $file_path" "$DEBUG_LOG_PATH"
content="$PN_SKILL_CONTENT"
content_sha="$PN_SKILL_SHA"

config=$(pn_resolve_config) || {
  log_debug "Skill use NOT reported | skill=$skill_name | could not resolve config" "$DEBUG_LOG_PATH"
  respond_allow
}
read -r base_url access_token <<<"$config"
if [[ -z "$base_url" || -z "$access_token" ]]; then
  log_debug "Skill use NOT reported | skill=$skill_name | config resolved but base_url/token empty" "$DEBUG_LOG_PATH"
  respond_allow
fi

# cwd/git context for the chatapi join -- same extraction every other hook
# here uses (check-tool-call.sh et al). beforeReadFile carries no .cwd of its
# own, so workspace_roots[0] is the only source.
cwd=$(printf '%s' "$payload" | "$JQ_BIN" -r '.cwd // (.workspace_roots // [])[0] // ""' 2>/dev/null)
git_repo_url=""
git_branch=""
if [[ -n "$cwd" && -d "$cwd/.git" ]]; then
  git_repo_url=$(get_remote_url_or_empty "$cwd")
  git_branch=$(get_current_branch_or_empty "$cwd")
fi

log_debug "Reporting skill use | skill=$skill_name | sha=${content_sha:0:8} | bytes=${#content} | session=$session_id gen=$generation_id" "$DEBUG_LOG_PATH"

# DETACHED. Cursor waits for a hook to return, and nothing here acts on the
# reply. The outcome is still logged inside the subshell rather than
# discarded: nothing acting on a failure is not a reason to be unable to SEE
# one -- a 403 and a success were indistinguishable from this side until the
# logging existed.
(
  pn_plugin_skill_use "$base_url" "$access_token" "$TIMEOUT_SECONDS" "$session_id" \
    "$cwd" "$git_repo_url" "$git_branch" \
    "$skill_name" "$file_path" "$content" "$content_sha" "$generation_id"
  log_debug "Skill use outcome | skill=$skill_name | status=$PN_SKILL_USE_STATUS | http=$PN_SKILL_USE_HTTP_STATUS | match=$PN_SKILL_USE_MATCH_METHOD" "$DEBUG_LOG_PATH"
) >/dev/null 2>&1 &

respond_allow
