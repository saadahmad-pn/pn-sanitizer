#!/bin/bash
# TEMPORARY SPIKE -- not part of the shipped plugin.
#
# Purpose: figure out empirically whether a Cursor Agent Skill invocation
# (e.g. running the paradigmnetworks-login skill) shows up as a hookable
# event at all, and if so which one -- preToolUse (tool_name=Read/Grep/Task)
# or beforeReadFile (file_path+content) -- since Cursor's docs don't specify
# the loading mechanism and no hook payload carries a skill_name field
# (confirmed against Cursor's hooks docs and the matching, still-open
# anthropics/claude-code feature request for the same gap).
#
# Wired to BOTH preToolUse (all tools, matcher "") and beforeReadFile in
# hooks/hooks.json for the duration of this spike. Dumps every payload it
# receives, verbatim, to a local log so we can grep it after manually
# triggering a skill in a live Cursor session.
#
# Delete this script and its hooks.json entries once the spike is done.

set -o pipefail

LOG_PATH="${HOME}/.paradigm-scanner/spike-skill-detection.jsonl"
mkdir -p "$(dirname "$LOG_PATH")" 2>/dev/null

payload=""
if [[ ! -t 0 ]]; then
  payload=$(cat 2>/dev/null)
fi

timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')

# Hand-written wrapper, not jq -- this script must never fail or block a
# real hook event even if jq/payload parsing has a problem, and the raw
# payload is exactly what we want to inspect anyway.
printf '{"received_at": "%s", "raw_payload": %s}\n' "$timestamp" "${payload:-null}" >> "$LOG_PATH"

echo '{"permission": "allow"}'
exit 0
