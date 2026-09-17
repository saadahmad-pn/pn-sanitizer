#!/bin/bash
# beforeShellExecution hook: evaluate a detected git command (push, commit,
# or PR creation) against the generic detections API before letting it run.
# One script, parameterized by EventType ($1), rather than one clone per
# git operation -- push/commit/pr_create are three instances of the same
# generic contract (design-ideas/Cursor_PrePush_Governance_Enforcement_Plan.md,
# section 0.5), so the submit-and-classify logic is shared here (lib/
# detection-client.sh) and only each EventType's file-collection step
# differs.
# Returns {permission: "allow"/"deny", user_message: "...", agent_message: "..."}

set -o pipefail

# Dead code on the hook path: hooks.json dispatches this script through
# scripts/run-hook.cmd (bash here, PowerShell on Windows), so Cursor never
# spawns it under Git Bash/MSYS2/Cygwin in the first place. Left in place
# only so this .sh still behaves correctly if someone invokes it directly
# under one of those -- same convention as check-write.sh.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo '{"permission": "allow"}'
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/git-utils.sh"
source "$SCRIPT_DIR/lib/detection-client.sh"
source "$SCRIPT_DIR/pn_config.sh"

EVENT_TYPE="${1:-}"

DETECTIONS_URL_OVERRIDE="${PARADIGM_NETWORKS_DETECTIONS_URL_OVERRIDE:-}"
TIMEOUT_SECONDS="${PARADIGM_NETWORKS_GIT_EVENT_TIMEOUT:-240}"
# Guardrails from design-ideas/Cursor_PrePush_Governance_Enforcement_Plan.md
# section 10.4: an explicit, user-visible cap rather than silently
# submitting an unbounded fan-out of scanner calls for one push/commit/PR.
# The specific numbers are a starting point, not a measurement (no real
# latency benchmark exists yet -- see that same document's section 9) --
# both are overridable while that measurement is pending.
MAX_FILES="${PARADIGM_NETWORKS_GIT_EVENT_MAX_FILES:-60}"
MAX_TOTAL_BYTES="${PARADIGM_NETWORKS_GIT_EVENT_MAX_BYTES:-8388608}" # 8 MB

RAW_FAILURE_MODE=$(echo "${PARADIGM_NETWORKS_FAILURE_MODE:-block}" | tr '[:upper:]' '[:lower:]')
case "$RAW_FAILURE_MODE" in
  allow|open) FAILURE_MODE="open" ;;
  *)          FAILURE_MODE="closed" ;;
esac
# Defaults closed, matching check-write.sh, not check-prompt.sh's open
# default: a push/commit/PR reaching its destination unscanned is a
# comparable risk to an unscanned file write, not to an unscanned prompt
# (design doc section 4).

AUDIT_LOG_PATH="${HOME}/.paradigm-scanner/audit.jsonl"
DEBUG_LOG_PATH="${HOME}/.paradigm-scanner/check-git-event.log"

# Same "relay in full" rationale as check-write.sh's build_stop_instruction
# -- a vaguer instruction lets the agent paraphrase findings into a vaguer
# summary, dropping specific detail (category/standard names, individual
# issues) in the process.
build_stop_instruction() {
  local action_desc="$1"
  echo "A security scan blocked ${action_desc} due to a detected policy violation. Do not retry ${action_desc} or attempt a workaround (e.g. re-encoding it, splitting it up, or otherwise disguising it to bypass detection). Stop this task and relay the findings above to the user in full, exactly as given -- every issue, category, and finding mentioned. Do not summarize or paraphrase them into a general statement; the user needs the precise details to know what to fix."
}

main() {
  local payload=""
  if [[ ! -t 0 ]]; then
    payload=$(cat 2>/dev/null)
  fi

  # jq is required for everything below -- same unconditional-allow
  # posture as check-write.sh: this is deliberate onboarding-deadlock
  # avoidance, not routed through FAILURE_MODE.
  if [[ -z "$JQ_BIN" ]]; then
    if [[ "$FAILURE_MODE" == "open" ]]; then
      json_permission_allow "No usable jq was found on this machine or bundled for this platform. Allowed WITHOUT a security scan. Install jq to enable scanning (see the plugin README)."
    else
      json_permission_deny "No usable jq was found on this machine or bundled for this platform. Blocked." "No usable jq was found on this machine or bundled for this platform. Do not retry this action. Ask the user to install jq (see the plugin README), then try again."
    fi
    return 0
  fi

  # An empty/unrecognized EventType means hooks.json wiring is broken (a
  # matcher pointing at this script without a valid argument) -- not
  # something this hook can meaningfully judge, so allow rather than block
  # on a case this script has no business deciding.
  if [[ -z "$EVENT_TYPE" ]]; then
    json_permission_allow
    return 0
  fi

  # Deliberately always allow on malformed payload, unlike the
  # FAILURE_MODE-driven branches below -- same reasoning as check-write.sh:
  # this usually signals a Cursor integration/encoding quirk, not an
  # unreachable scanner.
  if ! echo "$payload" | "$JQ_BIN" empty 2>/dev/null; then
    json_permission_allow "Received invalid input."
    return 0
  fi

  local command_text cwd
  command_text=$(echo "$payload" | "$JQ_BIN" -r '.command // ""')
  cwd=$(echo "$payload" | "$JQ_BIN" -r '.cwd // ""')

  if [[ -z "$cwd" ]] || [[ ! -d "$cwd/.git" ]]; then
    # Not a git repo (or cwd missing/inaccessible) -- nothing this hook is
    # designed to evaluate. Allow rather than block on a case outside its
    # remit.
    json_permission_allow
    return 0
  fi

  local action_noun="Push"
  local action_desc="this push"
  case "$EVENT_TYPE" in
    git.commit)    action_noun="Commit";             action_desc="this commit" ;;
    git.pr_create) action_noun="Pull request creation"; action_desc="this pull request creation" ;;
  esac

  # Collect the file set relevant to this EventType. Each resolver prints
  # newline-separated repo-relative paths; empty output means "nothing to
  # scan," handled uniformly below regardless of which resolver ran.
  local changed_files=""
  case "$EVENT_TYPE" in
    git.push)
      changed_files=$(resolve_unpushed_changed_files "$cwd")
      ;;
    git.commit)
      changed_files=$(resolve_staged_changed_files "$cwd")
      ;;
    git.pr_create)
      changed_files=$(resolve_pr_create_changed_files "$cwd" "$command_text")
      ;;
    *)
      # An EventType this script doesn't recognize is a hooks.json wiring
      # bug (see file header), not a signal about the command itself --
      # same "allow, not this hook's business" posture as the empty-
      # EventType/non-git-repo branches above.
      json_permission_allow
      return 0
      ;;
  esac

  local git_repo_url git_branch
  git_repo_url=$(get_remote_url_or_empty "$cwd")
  git_branch=$(get_current_branch_or_empty "$cwd")

  local changed_file_count=0
  [[ -n "$changed_files" ]] && changed_file_count=$(printf '%s\n' "$changed_files" | grep -c .)
  log_debug "event=$EVENT_TYPE cwd=$cwd branch=$git_branch changed_file_count=$changed_file_count" "$DEBUG_LOG_PATH"

  # Build the file list to submit: skip binary files and anything missing
  # from the working tree (e.g. deleted since staged/committed -- nothing
  # to scan), and enforce the size/count guardrail above rather than
  # silently submitting an unbounded fan-out to the scanner. Content is
  # read from the current working-tree state of each path, not a specific
  # historical/staged blob -- a deliberate simplification (design doc
  # section 2): the two coincide in the overwhelmingly common case (commit
  # and push happen back-to-back with no further edits in between), and the
  # alternative (extracting exact historical/index blobs via `git show`)
  # adds real complexity for a race that exists regardless of which content
  # source is picked -- the file can change again a moment later either way.
  local -a submit_file_entries=()
  local total_bytes=0
  local capped=0
  local rel_path abs_path file_size

  while IFS= read -r rel_path; do
    [[ -z "$rel_path" ]] && continue
    abs_path="$cwd/$rel_path"
    [[ -f "$abs_path" ]] || continue
    is_binary_file "$abs_path" && continue

    if [[ "${#submit_file_entries[@]}" -ge "$MAX_FILES" ]]; then
      capped=1
      continue
    fi
    file_size=$(stat -f%z "$abs_path" 2>/dev/null || stat -c%s "$abs_path" 2>/dev/null || echo 0)
    if [[ $((total_bytes + file_size)) -gt "$MAX_TOTAL_BYTES" ]]; then
      capped=1
      continue
    fi
    total_bytes=$((total_bytes + file_size))
    submit_file_entries+=("Files=@${abs_path};filename=${rel_path}")
  done <<< "$changed_files"

  if [[ "$capped" -eq 1 ]]; then
    log_debug "File set exceeded the ${MAX_FILES}-file/${MAX_TOTAL_BYTES}-byte guardrail; remaining files were not submitted for scanning" "$DEBUG_LOG_PATH"
  fi

  # Nothing left to scan (no tracked changes, everything binary, or a
  # command that touched no files at all) -- allow, same "nothing to scan"
  # posture as check-write.sh.
  if [[ "${#submit_file_entries[@]}" -eq 0 ]]; then
    json_permission_allow
    return 0
  fi

  local config
  config=$(pn_resolve_config) || {
    local reason="Paradigm Networks not configured — run the paradigmnetworks-login skill"
    audit_log_entry=$("$JQ_BIN" -n \
      --arg event_type "$EVENT_TYPE" \
      --arg command "$command_text" \
      --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
      --arg reason "not_configured" \
      --arg detail "$reason" \
      '{event_type: $event_type, command: $command, decision: $decision, reason: $reason, detail: $detail}')
    audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

    local signup_note="Don't have one yet? Sign up at https://signup.claude-demo.paradigmnetworks.ai/signup."
    if [[ "$FAILURE_MODE" == "open" ]]; then
      json_permission_allow "The scanning service is unavailable ($reason). ${action_noun} allowed WITHOUT a security scan. $signup_note"
    else
      json_permission_deny "The scanning service is unavailable ($reason). ${action_noun} blocked. $signup_note" "The scanning service is unavailable ($reason). Do not retry ${action_desc}."
    fi
    return 0
  }

  local base_url access_token
  read -r base_url access_token <<<"$config"

  local detections_url="${DETECTIONS_URL_OVERRIDE}"
  if [[ -z "$detections_url" ]]; then
    detections_url="${base_url%/}/api/v1/detections/evaluate"
  fi

  log_debug "Evaluating $EVENT_TYPE | url=$detections_url | file_count=${#submit_file_entries[@]} | total_bytes=$total_bytes" "$DEBUG_LOG_PATH"

  # pn_evaluate_detection (lib/detection-client.sh) submits and classifies
  # the response -- called as a plain statement (not $(...)), same
  # multi-value-return convention as pn_parse_messages_response/
  # http_post_split_status elsewhere in this codebase. SessionId is always
  # empty: this plugin has no Cursor session identity to send (see the
  # design doc's section 0 -- a legitimate, expected value, not an error).
  pn_evaluate_detection "$detections_url" "$access_token" "$TIMEOUT_SECONDS" \
    "$EVENT_TYPE" "cursor-plugin" "$cwd" "" "$git_repo_url" "$git_branch" "$command_text" \
    "${submit_file_entries[@]}"

  case "$PN_DETECTION_STATUS" in
    timeout)
      audit_log_entry=$("$JQ_BIN" -n \
        --arg event_type "$EVENT_TYPE" --arg command "$command_text" \
        --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
        --arg reason "api_timeout" --arg detail "${TIMEOUT_SECONDS}s timeout" --arg url "$detections_url" \
        '{event_type: $event_type, command: $command, decision: $decision, reason: $reason, detail: $detail, url: $url}')
      audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"
      if [[ "$FAILURE_MODE" == "open" ]]; then
        json_permission_allow "The scanning service is unavailable (timed out after ${TIMEOUT_SECONDS}s). ${action_noun} allowed WITHOUT a security scan."
      else
        json_permission_deny "The scanning service is unavailable (timed out after ${TIMEOUT_SECONDS}s). ${action_noun} blocked." "The scanning service is unavailable (timed out after ${TIMEOUT_SECONDS}s). Do not retry ${action_desc}."
      fi
      ;;
    unreachable)
      audit_log_entry=$("$JQ_BIN" -n \
        --arg event_type "$EVENT_TYPE" --arg command "$command_text" \
        --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
        --arg reason "api_unreachable" --arg detail "connection failed" --arg url "$detections_url" \
        '{event_type: $event_type, command: $command, decision: $decision, reason: $reason, detail: $detail, url: $url}')
      audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"
      if [[ "$FAILURE_MODE" == "open" ]]; then
        json_permission_allow "The scanning service is unavailable (connection failed). ${action_noun} allowed WITHOUT a security scan."
      else
        json_permission_deny "The scanning service is unavailable (connection failed). ${action_noun} blocked." "The scanning service is unavailable (connection failed). Do not retry ${action_desc}."
      fi
      ;;
    http_error)
      audit_log_entry=$("$JQ_BIN" -n \
        --arg event_type "$EVENT_TYPE" --arg command "$command_text" \
        --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
        --arg reason "api_http_error" --arg detail "HTTP ${PN_DETECTION_HTTP_STATUS}" --arg url "$detections_url" \
        '{event_type: $event_type, command: $command, decision: $decision, reason: $reason, detail: $detail, url: $url}')
      audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"
      if [[ "$FAILURE_MODE" == "open" ]]; then
        json_permission_allow "The scanning service returned an error (HTTP ${PN_DETECTION_HTTP_STATUS}). ${action_noun} allowed WITHOUT a security scan."
      else
        json_permission_deny "The scanning service returned an error (HTTP ${PN_DETECTION_HTTP_STATUS}). ${action_noun} blocked." "The scanning service returned an error (HTTP ${PN_DETECTION_HTTP_STATUS}). Do not retry ${action_desc}."
      fi
      ;;
    invalid_json)
      audit_log_entry=$("$JQ_BIN" -n \
        --arg event_type "$EVENT_TYPE" --arg command "$command_text" \
        --arg decision "$([[ "$FAILURE_MODE" == "closed" ]] && echo "deny" || echo "allow")" \
        --arg reason "api_invalid_json" --arg detail "scanner returned invalid JSON" --arg url "$detections_url" \
        '{event_type: $event_type, command: $command, decision: $decision, reason: $reason, detail: $detail, url: $url}')
      audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"
      if [[ "$FAILURE_MODE" == "open" ]]; then
        json_permission_allow "The scanning service returned an invalid response. ${action_noun} allowed WITHOUT a security scan."
      else
        json_permission_deny "The scanning service returned an invalid response. ${action_noun} blocked." "The scanning service returned an invalid response. Do not retry ${action_desc}."
      fi
      ;;
    ok)
      pn_record_successful_scan
      audit_log_entry=$("$JQ_BIN" -n \
        --arg event_type "$EVENT_TYPE" --arg command "$command_text" \
        --arg decision "$PN_DETECTION_DECISION" --arg audit_id "$PN_DETECTION_AUDIT_ID" \
        --argjson file_count "${#submit_file_entries[@]}" \
        '{event_type: $event_type, command: $command, decision: $decision, audit_id: $audit_id, file_count: $file_count}')
      audit_log "$audit_log_entry" "$AUDIT_LOG_PATH"

      case "$PN_DETECTION_DECISION" in
        block)
          local user_message="$PN_DETECTION_MESSAGE"
          [[ -z "$user_message" ]] && user_message="A policy violation was detected."
          json_permission_deny "$user_message" "$user_message $(build_stop_instruction "$action_desc")"
          ;;
        *)
          # "warn" and "allow" both let the operation proceed -- "warn"
          # surfaces PN_DETECTION_MESSAGE as a non-blocking notice, "allow"
          # surfaces it only if the backend actually sent one (design doc
          # section 4).
          if [[ -n "$PN_DETECTION_MESSAGE" ]]; then
            json_permission_allow "$PN_DETECTION_MESSAGE"
          else
            json_permission_allow
          fi
          ;;
      esac
      ;;
  esac

  return 0
}

main
exit $?
