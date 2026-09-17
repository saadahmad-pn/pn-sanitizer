#!/bin/bash
# Shared client for POST /api/v1/detections/evaluate -- the generic
# command/event detection API (design-ideas/
# Cursor_PrePush_Governance_Enforcement_Plan.md, section 0.5.3). Used by
# check-git-event.sh for git.push/git.commit/git.pr_create today; a future
# non-git command source would call pn_evaluate_detection below with a
# different EventType and file set, unchanged otherwise.

# is_binary_file <path>
# An empty file is never binary -- nothing to filter out, and there is no
# content for the NUL-byte check below to inspect anyway. Otherwise, relies
# on grep's own binary-file detection (-I: treat a file grep considers
# binary as non-matching, rather than searching it) against a pattern that
# matches any line, including blank ones -- present in both macOS's BSD
# grep and Linux's GNU grep, so nothing GNU-only (`grep -P '\x00'`) or an
# external `file` binary (not guaranteed installed) is needed.
#
# Deliberately NOT a bash-variable NUL-byte comparison (an earlier version
# of this function did `sample=$(head -c ... "$path")` then compared it
# against a NUL-stripped copy): bash strings are NUL-terminated C strings
# internally, so command substitution silently truncates output at the
# first NUL byte -- both copies come out identically truncated and always
# compare equal, so that approach never actually detects a NUL at all.
# Confirmed directly: it misclassified every real binary file as text.
is_binary_file() {
  local path="$1"
  [[ -s "$path" ]] || return 1
  ! grep -Iq '' "$path" 2>/dev/null
}

# pn_evaluate_detection <url> <auth_token> <timeout> <event_type> <tool> <cwd>
#                        <session_id> <git_repo_url> <git_branch> <command_text>
#                        [file_form_entry ...]
#
# Each file_form_entry is a pre-formatted curl -F value, e.g.
# "Files=@/abs/path/to/file;filename=relative/path" -- built by the caller
# (see check-git-event.sh) since only it knows which absolute path each
# repo-relative display name maps to.
#
# Sets globals (must be called as a plain statement, never via $(...), same
# convention as pn_parse_messages_response / http_post_split_status
# elsewhere in this codebase):
#   PN_DETECTION_STATUS      -- "ok" | "timeout" | "unreachable" | "http_error" | "invalid_json"
#   PN_DETECTION_HTTP_STATUS -- set when STATUS=http_error
#   PN_DETECTION_DECISION    -- "allow" | "warn" | "block", set when STATUS=ok
#   PN_DETECTION_MESSAGE     -- set when STATUS=ok
#   PN_DETECTION_AUDIT_ID    -- set when STATUS=ok
pn_evaluate_detection() {
  local url="$1" auth_token="$2" timeout="$3"
  local event_type="$4" tool="$5" cwd="$6" session_id="$7"
  local git_repo_url="$8" git_branch="$9" command_text="${10}"
  shift 10

  local -a form_args=(
    --form-string "EventType=${event_type}"
    --form-string "Tool=${tool}"
    --form-string "Cwd=${cwd}"
    --form-string "SessionId=${session_id}"
    --form-string "GitRepoUrl=${git_repo_url}"
    --form-string "GitBranch=${git_branch}"
    --form-string "CommandText=${command_text}"
  )
  local file_entry
  for file_entry in "$@"; do
    form_args+=(-F "$file_entry")
  done

  local raw_response
  raw_response=$(http_post_multipart_form "$url" "$auth_token" "$timeout" "${form_args[@]}")
  local curl_exit=$?
  http_post_split_status "$raw_response"
  local response="$HTTP_POST_BODY"

  if [[ $curl_exit -eq 28 ]]; then
    PN_DETECTION_STATUS="timeout"
    return 0
  elif [[ $curl_exit -ne 0 ]]; then
    PN_DETECTION_STATUS="unreachable"
    return 0
  fi

  if [[ "$HTTP_POST_STATUS" != 2* ]]; then
    PN_DETECTION_STATUS="http_error"
    PN_DETECTION_HTTP_STATUS="$HTTP_POST_STATUS"
    return 0
  fi

  if ! echo "$response" | "$JQ_BIN" empty 2>/dev/null; then
    PN_DETECTION_STATUS="invalid_json"
    return 0
  fi

  PN_DETECTION_STATUS="ok"
  # A missing/null Decision on an otherwise-valid 2xx response is treated as
  # "block", not "allow" -- an unrecognized shape here must fail closed, the
  # same posture pn_parse_messages_response takes for its own "anomaly"
  # case (never silently guess allow on a shape we don't understand).
  PN_DETECTION_DECISION=$(echo "$response" | "$JQ_BIN" -r '.Decision // "block"')
  PN_DETECTION_MESSAGE=$(echo "$response" | "$JQ_BIN" -r '.Message // ""')
  PN_DETECTION_AUDIT_ID=$(echo "$response" | "$JQ_BIN" -r '.AuditId // ""')
}
