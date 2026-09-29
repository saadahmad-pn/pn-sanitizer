#!/bin/bash
# beforeReadFile hook: detect when a Cursor Agent Skill is loaded, and report
# it to control-server -- not every file read.
#
# Cursor has no dedicated "skill invoked" hook event, and no hook payload
# carries a skill_name field (confirmed against Cursor's hooks docs and
# the matching, still-open anthropics/claude-code feature request for the
# same gap). What Cursor does when it loads a skill is a plain read of
# that skill's SKILL.md under the plugin cache
# (.../skills/<skill-name>/SKILL.md), which beforeReadFile's top-level
# file_path already gives us directly -- confirmed empirically, including
# against preToolUse (tool_name=Read), which fired on the exact same
# reads with no extra information, so it was dropped from hooks.json to
# avoid double-logging every skill use.
#
# So: pull skill_name out of file_path and only act on entries that actually
# match a SKILL.md read; everything else is ignored.
#
# WHY THE FILE CONTENT IS SENT. beforeReadFile is the one event that carries
# the file's full, unmodified content alongside the path. control-server
# hashes it to decide whether this is a skill published to the Skills
# Registry or one that only exists on this machine -- the name cannot decide
# that, since a local skill and a published one can share a name and be
# different files. The content is what makes the match exact, and it is the
# reason the plugin path can be matched at all: Cursor's chat gateway sends a
# skill as a Read whose result has line numbers glued onto every line, and
# Claude Code's Skill tool call carries the name with no body at all.
#
# NOT A SECURITY CONTROL. It reports, it never blocks, and it always allows
# -- wired with failClosed: false in hooks.json since this hook only
# observes. The POST is detached for the same reason report-tool.sh detaches
# its own: Cursor waits for a hook to return, and nothing here reads the
# reply.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/pn_config.sh"

LOG_PATH="${HOME}/.paradigm-scanner/skill-usage.jsonl"
# The POST's own outcome. Separate from LOG_PATH on purpose: that file is
# written BEFORE the POST and only ever proves the skill was DETECTED, so it
# can never say whether the report actually arrived. Confirmed the hard way
# (2026-09-29) -- a 403 from an unregistered route looked identical to
# success from this side, because the detached curl's status went to
# /dev/null and nothing here logged it. Every other hook in this repo already
# keeps a debug log for exactly this; this one was modelled on
# report-tool.sh, which does not.
DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-skill-usage.log"
mkdir -p "$(dirname "$LOG_PATH")" 2>/dev/null

# Identifies this plugin to the backend's vendor-classification engine --
# same value every other hook here sends.
PN_CLIENT_ID="cursor"
# Detached, so this only bounds a stuck background curl and costs the
# developer nothing.
TIMEOUT_SECONDS="${PARADIGM_NETWORKS_SKILL_TIMEOUT:-30}"

respond_allow() {
  echo '{"permission": "allow"}'
  exit 0
}

# sha256_of_string: the digest control-server matches against the published
# SKILL.md. Hashes the EXACT STRING being sent, never the file on disk -- the
# two are not the same thing, and an earlier version that hashed the file was
# rejected by the server on every single call. Tried in order because no
# single tool is present everywhere: shasum ships with macOS, sha256sum with
# most Linux distributions, openssl is the fallback when a minimal image has
# neither. Prints nothing when none is available, which downgrades the report
# to "unmatched" rather than dropping it -- the server re-hashes what it
# receives anyway, so a missing client digest costs only the mismatch check.
sha256_of_string() {
  if command_exists shasum; then
    printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command_exists sha256sum; then
    printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}'
  elif command_exists openssl; then
    printf '%s' "$1" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  fi
}

# read_preserving_trailing_newline: runs a command and captures its output
# WITHOUT losing trailing newlines.
#
# $(...) strips EVERY trailing newline, and a SKILL.md almost always ends in
# one. That one missing byte is not cosmetic here: the whole match is an exact
# SHA-256 against the published file, so a body one byte short can never match
# anything, ever. Measured against a real skill (2026-09-29): the file was
# 2141 bytes and plain $() produced 2140, whose hash shares no prefix with the
# file's.
#
# The sentinel is the standard fix -- append a byte the stripping cannot
# remove, then remove it by hand.
#
# The caller must use `jq -j`, never `jq -r`, for the same measurement's other
# half: -r appends its OWN newline to the value, so the same file came back as
# 2142 bytes and preserving that faithfully is just as wrong in the other
# direction. -j emits the value raw, which makes it byte-identical to `cat`.
# Sets the global PN_READ_RESULT rather than printing. It HAS to: a caller
# writing `x=$(read_preserving_trailing_newline ...)` would strip the newline
# right back off in that outer substitution, which is precisely the bug this
# function exists to avoid, and it fails silently.
read_preserving_trailing_newline() {
  local out
  out=$("$@"; printf 'x')
  PN_READ_RESULT="${out%x}"
}

payload=""
if [[ ! -t 0 ]]; then
  payload=$(cat 2>/dev/null)
fi
[[ -n "$payload" ]] || respond_allow

# No jq (system or bundled) available on this platform: nothing below can
# safely parse the payload, so skip detection rather than guess with
# string matching -- same "jq is required" stance as check-write.sh.
[[ -n "$JQ_BIN" ]] || respond_allow

file_path=$(printf '%s' "$payload" | "$JQ_BIN" -r '.file_path // empty' 2>/dev/null)
[[ "$file_path" =~ /skills/([^/]+)/SKILL\.md$ ]] || respond_allow
skill_name="${BASH_REMATCH[1]}"

timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')

# The local trail is kept even when the POST below cannot run (not signed
# in, no network): it is the only record a developer working offline has of
# which skills ran.
log_line=$("$JQ_BIN" -nc \
  --arg received_at "$timestamp" \
  --arg skill_name "$skill_name" \
  --arg file_path "$file_path" \
  '{received_at: $received_at, skill_name: $skill_name, file_path: $file_path}') \
  && printf '%s\n' "$log_line" >> "$LOG_PATH"

# Not signed in -- nothing to report to, and this hook must not nag. Logged
# anyway: from the outside this looks exactly like a working hook that never
# delivers, and that ambiguity is what made the first real failure here hard
# to see.
if ! pn_is_configured; then
  log_debug "Skill use NOT reported | skill=$skill_name | not signed in" "$DEBUG_LOG_PATH"
  respond_allow
fi

# session_id/conversation_id are the same value in practice; generation_id
# changes per user turn and is what control-server merges this use onto the
# right turn with. Without a session id there is no turn to attach to, so
# there is nothing worth sending.
session_id=$(printf '%s' "$payload" | "$JQ_BIN" -r '.session_id // .conversation_id // ""' 2>/dev/null)
if [[ -z "$session_id" ]]; then
  log_debug "Skill use NOT reported | skill=$skill_name | no session_id in payload" "$DEBUG_LOG_PATH"
  respond_allow
fi
generation_id=$(printf '%s' "$payload" | "$JQ_BIN" -r '.generation_id // ""' 2>/dev/null)

# The payload carries the file's full content. Falling back to reading it off
# disk keeps this working if a future Cursor version drops the field -- the
# path is right there, and an unreadable file just means an unmatched use.
extract_content() { printf '%s' "$payload" | "$JQ_BIN" -j '.content // ""' 2>/dev/null; }
read_preserving_trailing_newline extract_content
content="$PN_READ_RESULT"
if [[ -z "$content" && -r "$file_path" ]]; then
  read_preserving_trailing_newline cat "$file_path"
  content="$PN_READ_RESULT"
fi

# Hashed from $content itself, so the digest and the body can never disagree
# -- whatever we send is what we hashed, whether it came from the payload or
# off disk.
content_sha=""
if [[ -n "$content" ]]; then
  content_sha=$(sha256_of_string "$content")
fi

config=$(pn_resolve_config) || {
  log_debug "Skill use NOT reported | skill=$skill_name | could not resolve config (token refresh failed?)" "$DEBUG_LOG_PATH"
  respond_allow
}
read -r base_url access_token <<<"$config"
if [[ -z "$base_url" || -z "$access_token" ]]; then
  log_debug "Skill use NOT reported | skill=$skill_name | config resolved but base_url/token empty" "$DEBUG_LOG_PATH"
  respond_allow
fi

encoded_session=$(urlencode_strict "$session_id")
skill_url="${base_url%/}/api/v1/plugins/sessions/${encoded_session}/skill-uses"

# Built via jq -n --arg, not string interpolation: a SKILL.md is markdown
# full of quotes, backslashes and newlines that must be escaped correctly.
json_body=$("$JQ_BIN" -n \
  --arg generation_id "$generation_id" \
  --arg skill_name "$skill_name" \
  --arg file_path "$file_path" \
  --arg content "$content" \
  --arg sha "$content_sha" \
  --arg cwd "$PWD" \
  '{Platform: "cursor", GenerationId: $generation_id, SkillName: $skill_name, FilePath: $file_path, Content: $content, ContentSha256: $sha, Cwd: $cwd}')

log_debug "Reporting skill use | skill=$skill_name | url=$skill_url | sha=${content_sha:0:8} | content_len=${#content}" "$DEBUG_LOG_PATH"

# DETACHED, like report-tool.sh -- Cursor waits for a hook to return, and
# nothing here acts on the reply. The outcome is still logged inside the
# subshell rather than discarded: nothing acting on a failure is not a reason
# to be unable to SEE one.
(
  raw_response=$(http_post_json "$skill_url" "$json_body" "$access_token" "$TIMEOUT_SECONDS" "$session_id" "$PN_CLIENT_ID" 2>/dev/null)
  curl_exit=$?
  if [[ $curl_exit -eq 28 ]]; then
    log_debug "Skill use NOT reported | skill=$skill_name | timed out after ${TIMEOUT_SECONDS}s" "$DEBUG_LOG_PATH"
  elif [[ $curl_exit -ne 0 ]]; then
    log_debug "Skill use NOT reported | skill=$skill_name | connection failed (curl exit=$curl_exit)" "$DEBUG_LOG_PATH"
  else
    http_post_split_status "$raw_response"
    if [[ "$HTTP_POST_STATUS" == 2* ]]; then
      log_debug "Skill use reported | skill=$skill_name | HTTP $HTTP_POST_STATUS | $HTTP_POST_BODY" "$DEBUG_LOG_PATH"
    else
      # The body matters as much as the status: a 403 here means the route is
      # missing from the backend's permission catalog, and the message says so.
      log_debug "Skill use REJECTED | skill=$skill_name | HTTP $HTTP_POST_STATUS | $HTTP_POST_BODY" "$DEBUG_LOG_PATH"
    fi
  fi
) >/dev/null 2>&1 &

respond_allow
