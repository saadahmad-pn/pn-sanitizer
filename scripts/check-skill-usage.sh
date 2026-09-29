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

# sha256_of_string: the digest control-server matches against the published
# SKILL.md. Hashes the EXACT STRING being sent, never the file on disk as a
# separate read -- the two can differ, and when they do the server rejects
# the call outright. Tried in order because no single tool is present
# everywhere: shasum ships with macOS, sha256sum with most Linux
# distributions, openssl is the fallback when a minimal image has neither.
# Empty output downgrades the report to unmatched rather than dropping it;
# the server re-hashes what it receives anyway.
sha256_of_string() {
  if command_exists shasum; then
    printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command_exists sha256sum; then
    printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}'
  elif command_exists openssl; then
    printf '%s' "$1" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  fi
}

# read_file_preserving_trailing_newline <path>
# Sets PN_SKILL_CONTENT to the file's exact bytes.
#
# It HAS to set a global rather than print: a caller writing x=$(...) would
# strip the trailing newline right back off in that outer substitution, which
# is the very thing this exists to prevent, and it fails silently.
#
# $(...) strips EVERY trailing newline and a SKILL.md almost always ends in
# one. That single byte is not cosmetic: the match is an exact SHA-256
# against the published file, so a body one byte short can never match
# anything. Measured 2026-09-29 -- a 2141-byte skill came out as 2140, and
# the two digests share no prefix. The sentinel is the standard fix: append
# a byte the stripping cannot remove, then remove it by hand.
read_file_preserving_trailing_newline() {
  local out
  out=$(cat "$1" 2>/dev/null; printf 'x')
  PN_SKILL_CONTENT="${out%x}"
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

# THE FILE ON DISK IS THE SOURCE, NOT THE PAYLOAD.
#
# beforeReadFile carries a `content` field, but Cursor CHUNKS a large file:
# it fires the hook once per piece, each carrying only that piece. Measured
# 2026-09-29 on a 6748-byte SKILL.md, which arrived as two events of 4590 and
# 2163 bytes, the second starting mid-word where the first ended.
#
# Hashing that is useless twice over: a fragment can never equal the
# published file's digest, so a large skill would be permanently unmatched,
# and one skill load would file two separate uses. Reading the file here
# gives the whole thing and makes both events hash identically -- which the
# server's unique (SessionId, GenerationId, ContentSha256) index then
# collapses into the one use it actually was.
#
# The hook fires BEFORE the agent's read, so the file is on disk and readable
# right now.
PN_SKILL_CONTENT=""
read_file_preserving_trailing_newline "$file_path"
content="$PN_SKILL_CONTENT"
if [[ -z "$content" ]]; then
  log_debug "Skill use reported WITHOUT content | skill=$skill_name | unreadable: $file_path" "$DEBUG_LOG_PATH"
fi

content_sha=""
if [[ -n "$content" ]]; then
  content_sha=$(sha256_of_string "$content")
fi

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
