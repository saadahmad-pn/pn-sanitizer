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

# sha256_of_file: the digest control-server matches against the published
# SKILL.md. Tried in order because no single tool is present everywhere --
# shasum ships with macOS, sha256sum with most Linux distributions, and
# openssl is the fallback when a minimal image has neither. Prints nothing
# when none is available, which downgrades the report to "unmatched" rather
# than dropping it: the server re-hashes the content it receives anyway, so a
# missing client-side digest costs nothing but the mismatch check.
sha256_of_file() {
  local path="$1"
  if command_exists shasum; then
    shasum -a 256 "$path" 2>/dev/null | awk '{print $1}'
  elif command_exists sha256sum; then
    sha256sum "$path" 2>/dev/null | awk '{print $1}'
  elif command_exists openssl; then
    openssl dgst -sha256 "$path" 2>/dev/null | awk '{print $NF}'
  fi
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

# Not signed in -- nothing to report to, and this hook must not nag.
pn_is_configured || respond_allow

# session_id/conversation_id are the same value in practice; generation_id
# changes per user turn and is what control-server merges this use onto the
# right turn with. Without a session id there is no turn to attach to, so
# there is nothing worth sending.
session_id=$(printf '%s' "$payload" | "$JQ_BIN" -r '.session_id // .conversation_id // ""' 2>/dev/null)
[[ -n "$session_id" ]] || respond_allow
generation_id=$(printf '%s' "$payload" | "$JQ_BIN" -r '.generation_id // ""' 2>/dev/null)

# The payload carries the file's full content. Falling back to reading it off
# disk keeps this working if a future Cursor version drops the field -- the
# path is right there, and an unreadable file just means an unmatched use.
content=$(printf '%s' "$payload" | "$JQ_BIN" -r '.content // ""' 2>/dev/null)
if [[ -z "$content" && -r "$file_path" ]]; then
  content=$(cat "$file_path" 2>/dev/null)
fi

content_sha=""
if [[ -r "$file_path" ]]; then
  content_sha=$(sha256_of_file "$file_path")
fi

config=$(pn_resolve_config) || respond_allow
read -r base_url access_token <<<"$config"
[[ -n "$base_url" && -n "$access_token" ]] || respond_allow

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

# DETACHED, like report-tool.sh -- Cursor waits for a hook to return, and
# nothing here reads the reply.
(
  http_post_json "$skill_url" "$json_body" "$access_token" "$TIMEOUT_SECONDS" "$session_id" "$PN_CLIENT_ID" >/dev/null 2>&1
) >/dev/null 2>&1 &

respond_allow
