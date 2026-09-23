#!/bin/bash
# beforeReadFile hook: detect when a Cursor Agent Skill is loaded, and log
# only that -- not every file read.
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
# So: pull skill_name out of file_path and only log entries that actually
# match a SKILL.md read; everything else is ignored.
#
# Never blocks -- wired with failClosed: false in hooks.json since this
# hook only observes.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

LOG_PATH="${HOME}/.paradigm-scanner/skill-usage.jsonl"
mkdir -p "$(dirname "$LOG_PATH")" 2>/dev/null

respond_allow() {
  echo '{"permission": "allow"}'
  exit 0
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

log_line=$("$JQ_BIN" -n \
  --arg received_at "$timestamp" \
  --arg skill_name "$skill_name" \
  --arg file_path "$file_path" \
  '{received_at: $received_at, skill_name: $skill_name, file_path: $file_path}') \
  && printf '%s\n' "$log_line" >> "$LOG_PATH"

respond_allow
