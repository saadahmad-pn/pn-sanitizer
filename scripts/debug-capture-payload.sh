#!/bin/bash
# TEMPORARY. Not part of the product -- delete this file and its hooks.json
# entries once the afterShellExecution/postToolUse payload shape is confirmed.
#
# Writes whatever raw payload Cursor sends for these hook events, verbatim,
# to a log file. Neither event is used anywhere else in this repo yet, and
# the exact field name for a completed shell command's real output is
# unconfirmed -- this exists purely to capture a real example instead of
# guessing at one. Never blocks, never denies, always returns harmlessly.

CAPTURE_LOG="${HOME}/.paradigm-scanner/hook-capture.jsonl"
mkdir -p "$(dirname "$CAPTURE_LOG")" 2>/dev/null

payload=""
if [[ ! -t 0 ]]; then
  payload=$(cat 2>/dev/null)
fi

printf '%s\n' "$payload" >> "$CAPTURE_LOG" 2>/dev/null

echo '{}'
exit 0
