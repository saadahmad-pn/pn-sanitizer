#!/bin/bash
# Unit tests for library functions

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-utils.sh"

test_init
source_scripts

echo -e "${BLUE}=== Unit Tests: lib/common.sh ===${NC}"

# Test JSON helpers
test_case "json_allow with no message"
result=$(json_allow)
assert_json_valid "$result" "Valid JSON"
assert_json_field_equals "$result" "continue" "true" "continue is true"

test_case "json_allow with message"
result=$(json_allow "Test message")
assert_json_valid "$result" "Valid JSON"
assert_json_field_equals "$result" "continue" "true" "continue is true"
assert_json_has_key "$result" "user_message" "Has user_message key"

test_case "json_deny"
result=$(json_deny "Access denied")
assert_json_valid "$result" "Valid JSON"
assert_json_field_equals "$result" "continue" "false" "continue is false"
assert_json_has_key "$result" "user_message" "Has user_message key"

test_case "json_permission_allow with no message"
result=$(json_permission_allow)
assert_json_valid "$result" "Valid JSON"
assert_json_field_equals "$result" "permission" "allow" "permission is allow"

test_case "json_permission_allow with message"
result=$(json_permission_allow "All good")
assert_json_valid "$result" "Valid JSON"
assert_json_field_equals "$result" "permission" "allow" "permission is allow"
assert_json_has_key "$result" "user_message" "Has user_message key"

test_case "json_permission_deny"
result=$(json_permission_deny "Access denied" "Stop now")
assert_json_valid "$result" "Valid JSON"
assert_json_field_equals "$result" "permission" "deny" "permission is deny"
assert_json_has_key "$result" "user_message" "Has user_message key"
assert_json_has_key "$result" "agent_message" "Has agent_message key"

test_case "json_session_context"
result=$(json_session_context "Configure Paradigm Networks")
assert_json_valid "$result" "Valid JSON"
assert_json_has_key "$result" "additional_context" "Has additional_context key"

# Test pn_parse_messages_response (the /v1/messages response-classification
# heuristic -- see the function's own comment in lib/common.sh for why each
# of these cases lands where it does)
test_case "pn_parse_messages_response: normal reply, nonzero usage -> allow"
pn_parse_messages_response '{"content":[{"type":"text","text":"Hello there!"}],"usage":{"input_tokens":50,"output_tokens":10}}'
assert_output_equals "echo \"\$PN_MSG_ACTION\"" "allow" "action is allow"

test_case "pn_parse_messages_response: banner + zero usage -> block, reason extracted"
pn_parse_messages_response '{"content":[{"type":"text","text":"```\n========================================================================\n  REQUEST BLOCKED\n========================================================================\n\n  The submitted content was flagged because it triggered the following security concerns: destructive operation.\n\n========================================================================\n```"}],"usage":{"input_tokens":0,"output_tokens":0}}'
assert_output_equals "echo \"\$PN_MSG_ACTION\"" "block" "action is block"
assert_output_equals "echo \"\$PN_MSG_MESSAGE\"" "  The submitted content was flagged because it triggered the following security concerns: destructive operation." "reason extracted cleanly (banner scaffolding stripped, backend's own sentence kept as-is)"

# Regression coverage for the real-world bug this replaced a brittle
# regex with: the backend has at least two banner shapes -- a short
# phrase-in-a-sentence (above) and a long, multi-finding structured
# report (below, an actual example pulled from real hook logs, trimmed
# to two findings). The old "security concerns: X" regex only matched
# the first shape and silently dumped the entire raw banner -- dividers,
# code fences, and all -- into the user-facing message for the second.
# pn_strip_block_banner strips only the confirmed-fixed scaffolding
# (the ==== dividers, the REQUEST BLOCKED line, the code fence) and
# keeps everything else, so it has to handle both shapes correctly.
test_case "pn_parse_messages_response: long structured-report banner -> block, full report kept (not the old regex's silent full-dump-with-double-wrap)"
long_banner='```
========================================================================
  REQUEST BLOCKED
========================================================================

  The submitted content was flagged because it contains OWASP Top 10 and OWASP ASVS compliance violations.

  OWASP Top 10 Findings (1 issue)
  ----------------------------------------------------------------------

  [1] [HIGH] Debug Mode Enabled in Production
      Category : A02:2025 - Security Misconfiguration
      Snippet  : debug=True

========================================================================
```'
long_banner_json=$("$JQ_BIN" -n --arg text "$long_banner" '{content:[{type:"text",text:$text}],usage:{input_tokens:0,output_tokens:0}}')
pn_parse_messages_response "$long_banner_json"
assert_output_equals "echo \"\$PN_MSG_ACTION\"" "block" "action is block"
assert_output_contains "echo \"\$PN_MSG_MESSAGE\"" "OWASP Top 10 and OWASP ASVS compliance violations" "kept the backend's own explanation"
assert_output_contains "echo \"\$PN_MSG_MESSAGE\"" "Debug Mode Enabled in Production" "kept the structured finding detail"
result="$PN_MSG_MESSAGE"
if [[ "$result" == *"===="* ]] || [[ "$result" == *'```'* ]] || [[ "$result" == *"REQUEST BLOCKED"* ]]; then
  echo -e "  \033[0;31m✗\033[0m Banner scaffolding (dividers/fence/REQUEST BLOCKED) was stripped, not leaked into the message"
  echo "    Got: $result"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo -e "  \033[0;32m✓\033[0m Banner scaffolding (dividers/fence/REQUEST BLOCKED) was stripped, not leaked into the message"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi
TESTS_RUN=$((TESTS_RUN + 1))

test_case "pn_parse_messages_response: zero usage, no banner -> anomaly (not guessed either way)"
pn_parse_messages_response '{"content":[{"type":"text","text":"just a normal-looking short reply"}],"usage":{"input_tokens":0,"output_tokens":0}}'
assert_output_equals "echo \"\$PN_MSG_ACTION\"" "anomaly" "action is anomaly"

test_case "pn_parse_messages_response: empty content array -> anomaly"
pn_parse_messages_response '{"content":[],"usage":{"input_tokens":10,"output_tokens":5}}'
assert_output_equals "echo \"\$PN_MSG_ACTION\"" "anomaly" "action is anomaly"

test_case "pn_parse_messages_response: leading thinking block -> still finds block signal in the text block after it"
pn_parse_messages_response '{"content":[{"type":"thinking","thinking":"reasoning..."},{"type":"text","text":"```\n===\n  REQUEST BLOCKED\n===\n\n  The submitted content was flagged because it triggered the following security concerns: prompt injection.\n\n===\n```"}],"usage":{"input_tokens":0,"output_tokens":0}}'
assert_output_equals "echo \"\$PN_MSG_ACTION\"" "block" "action is block (not derailed by the leading thinking block)"
assert_output_equals "echo \"\$PN_MSG_MESSAGE\"" "  The submitted content was flagged because it triggered the following security concerns: prompt injection." "reason extracted from the correct block (also confirms a 3-char '===' divider strips the same as a 72-char one)"

test_case "pn_parse_messages_response: usage entirely missing -> anomaly"
pn_parse_messages_response '{"content":[{"type":"text","text":"some reply"}]}'
assert_output_equals "echo \"\$PN_MSG_ACTION\"" "anomaly" "action is anomaly"

# Test command checking
test_case "command_exists with available command"
assert_success "command_exists bash" "bash command exists"

test_case "command_exists with unavailable command"
assert_failure "command_exists nonexistent_command_xyz" "nonexistent command does not exist"

# Test file operations
test_case "file_read_tail with existing file"
test_file="$TEST_TEMP_DIR/test.txt"
echo -e "line1\nline2\nline3\nline4\nline5" > "$test_file"
result=$(file_read_tail "$test_file" 100)
assert_output_contains "echo '$result'" "line1" "Content read correctly"

test_case "file_read_tail with nonexistent file"
result=$(file_read_tail "$TEST_TEMP_DIR/nonexistent.txt")
assert_output_equals "echo '$result'" "" "Returns empty for missing file"

# Test logging
test_case "log_debug writes to log file"
log_file="$TEST_TEMP_DIR/test.log"
log_debug "Test message" "$log_file"
assert_file_exists "$log_file" "Log file created"
assert_output_contains "cat $log_file" "Test message" "Message written to log"

test_case "audit_log writes JSONL with timestamp"
audit_file="$TEST_TEMP_DIR/audit.jsonl"
entry='{"event": "test"}'
audit_log "$entry" "$audit_file"
assert_file_exists "$audit_file" "Audit file created"
result=$(cat "$audit_file")
assert_json_valid "$result" "Valid JSON line"
assert_json_has_key "$result" "timestamp" "Has timestamp"

# Regression coverage for P2-1: pn_parse_messages_response's block/allow
# verdict is a reverse-engineered heuristic with no real structured field
# from the backend -- if an upstream change ever turns every scan into
# "anomaly", that's a silent, complete loss of enforcement under the
# prompt hook's fail-open default. These functions track consecutive
# anomalies so callers can escalate to a visible warning past a
# threshold instead of staying silent indefinitely.
test_case "pn_record_scan_anomaly counts consecutive calls and persists across them"
rm -f "$PN_ANOMALY_STATE_PATH"
assert_output_equals "pn_record_scan_anomaly" "1" "First call returns 1"
assert_output_equals "pn_record_scan_anomaly" "2" "Second call returns 2"
assert_output_equals "pn_record_scan_anomaly" "3" "Third call returns 3, meeting PN_ANOMALY_WARNING_THRESHOLD"
assert_file_exists "$PN_ANOMALY_STATE_PATH" "State file persisted to disk"

test_case "pn_reset_scan_anomaly clears the streak"
pn_reset_scan_anomaly
assert_file_not_exists "$PN_ANOMALY_STATE_PATH" "State file removed"
assert_output_equals "pn_record_scan_anomaly" "1" "Next call after a reset starts back at 1, not 4"

echo ""
echo -e "${BLUE}=== Unit Tests: lib/git-utils.sh ===${NC}"

test_case "sanitize_git_value strips embedded credentials from a URL"
result=$(sanitize_git_value "https://x-token-abc123@github.com/acme/repo.git")
assert_output_equals "echo '$result'" "https://github.com/acme/repo.git" "Credentials stripped"

test_case "sanitize_git_value strips control characters"
result=$(sanitize_git_value "$(printf 'branch\tname\r\n')")
assert_output_equals "echo '$result'" "branchname" "Control characters removed"

test_case "sanitize_git_value caps length"
long_value=$(printf 'x%.0s' {1..600})
result=$(sanitize_git_value "$long_value")
assert_output_contains "echo '$result'" "...<truncated>" "Long value truncated"

test_case "find_git_repos discovers a repo and skips node_modules"
repo_root="$TEST_TEMP_DIR/repo-scan"
mkdir -p "$repo_root/real-repo" "$repo_root/node_modules/fake-repo"
(cd "$repo_root/real-repo" && git init -q)
(cd "$repo_root/node_modules/fake-repo" && git init -q)
result=$(find_git_repos "$repo_root")
assert_output_contains "echo '$result'" "$repo_root/real-repo" "Finds real repo"
if [[ "$result" != *"node_modules"* ]]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "  ${GREEN}✓${NC} Skips node_modules"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "  ${RED}✗${NC} Should skip node_modules"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_case "find_git_repos does not follow symlinked directories"
symlink_root="$TEST_TEMP_DIR/repo-scan-symlink"
mkdir -p "$symlink_root/outside-repo"
(cd "$symlink_root/outside-repo" && git init -q)
mkdir -p "$symlink_root/workspace"
ln -s "$symlink_root/outside-repo" "$symlink_root/workspace/linked-repo"
result=$(find_git_repos "$symlink_root/workspace")
assert_output_equals "echo '$result'" "" "Does not descend into a symlinked directory"

test_case "get_remote_url returns fallback text when no remote is set"
no_remote_repo="$TEST_TEMP_DIR/no-remote-repo"
mkdir -p "$no_remote_repo"
(cd "$no_remote_repo" && git init -q)
result=$(get_remote_url "$no_remote_repo")
assert_output_equals "echo '$result'" "No remote" "Falls back to 'No remote'"

test_case "get_current_branch returns the current branch name"
branch_repo="$TEST_TEMP_DIR/branch-repo"
mkdir -p "$branch_repo"
(cd "$branch_repo" && git init -q -b main-test && git commit --allow-empty -qm init)
result=$(get_current_branch "$branch_repo")
assert_output_equals "echo '$result'" "main-test" "Reports checked-out branch"

test_case "dedupe_lines removes duplicates, preserving first-seen order"
result=$(printf 'a\nb\na\nc\nb\n' | dedupe_lines)
assert_output_equals "echo '$result'" "$(printf 'a\nb\nc')" "Duplicates removed, order preserved"

echo ""
echo -e "${BLUE}=== Unit Tests: pn_config.sh ===${NC}"

test_case "pn_save_credentials creates file with correct permissions"
future_expiry=$(($(date +%s) + 7200))
pn_save_credentials "https://test.example.com" "token123" "refresh456" "$future_expiry"
assert_file_exists "$HOME/.pn/credentials.json" "Credentials file created"
assert_file_permissions "$HOME/.pn/credentials.json" "600" "File has 0600 permissions"

test_case "pn_load_credentials reads saved file"
result=$(pn_load_credentials)
assert_json_valid "$result" "Credentials are valid JSON"
assert_json_field_equals "$result" "base_url" "https://test.example.com" "base_url correct"
assert_json_field_equals "$result" "access_token" "token123" "access_token correct"

test_case "pn_is_configured returns true with valid creds"
future_expiry=$(($(date +%s) + 7200))
pn_save_credentials "https://test.example.com" "token" "refresh" "$future_expiry"
assert_success "pn_is_configured" "pn_is_configured returns success"

test_case "pn_is_configured returns false with no creds"
rm -f "$HOME/.pn/credentials.json"
assert_failure "pn_is_configured" "pn_is_configured returns failure when not configured"

test_case "pn_load_credentials returns error for missing file"
rm -f "$HOME/.pn/credentials.json"
assert_failure "pn_load_credentials" "pn_load_credentials fails for missing file"

test_case "pn_load_credentials returns error for malformed JSON"
mkdir -p "$HOME/.pn"
echo "not valid json" > "$HOME/.pn/credentials.json"
assert_failure "pn_load_credentials" "pn_load_credentials fails for invalid JSON"

test_case "pn_load_credentials returns error for missing fields"
mkdir -p "$HOME/.pn"
echo '{"base_url": "https://test.com"}' > "$HOME/.pn/credentials.json"
assert_failure "pn_load_credentials" "pn_load_credentials fails for missing required fields"

test_case "pn_refresh_token URL-encodes the refresh token and client_id in its form body"
# Regression test for P0-4: the body used to be built by raw
# interpolation (grant_type=refresh_token&refresh_token=${refresh_token}&
# client_id=${CLIENT_ID}), so a refresh token containing "+", "&", or "="
# corrupted the request -- "+" decodes server-side as a space, and both
# "&" and "=" are the form format's own delimiter characters. Stubs curl
# to capture the actual --data-raw body instead of hitting the network.
curl() {
  local args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--data-raw" ]]; then
      echo "${args[$((i + 1))]}" > "$TEST_TEMP_DIR/captured_refresh_body.txt"
    fi
  done
  echo '{"access_token":"a","refresh_token":"b","expires_in":3600}'
}
pn_refresh_token "https://test.example.com" "abc+def=ghi&jkl" >/dev/null
unset -f curl
captured_body=$(cat "$TEST_TEMP_DIR/captured_refresh_body.txt" 2>/dev/null)
assert_output_contains "echo '$captured_body'" "refresh_token=abc%2Bdef%3Dghi%26jkl" "Refresh token is fully percent-encoded, not raw-interpolated"
assert_output_contains "echo '$captured_body'" "client_id=cursor-plugin" "client_id present and unaffected (no reserved characters to encode)"

test_case "pn_resolve_config uses env vars first"
export PARADIGM_NETWORKS_URL="https://env.example.com"
export PARADIGM_NETWORKS_TOKEN="env-token"
result=$(pn_resolve_config)
assert_output_contains "echo '$result'" "https://env.example.com" "Uses env base_url"
assert_output_contains "echo '$result'" "env-token" "Uses env token"
unset PARADIGM_NETWORKS_URL PARADIGM_NETWORKS_TOKEN

test_case "pn_resolve_config falls back to file"
rm -f "$HOME/.pn/credentials.json"
# Use a future expiry time (current time + 7200 seconds)
future_expiry=$(($(date +%s) + 7200))
pn_save_credentials "https://file.example.com" "file-token" "refresh" "$future_expiry"
result=$(pn_resolve_config)
assert_output_contains "echo '$result'" "https://file.example.com" "Uses file base_url"
assert_output_contains "echo '$result'" "file-token" "Uses file token"

test_case "pn_get_preferred_model returns empty when never set"
rm -f "$HOME/.pn/credentials.json"
future_expiry=$(($(date +%s) + 7200))
pn_save_credentials "https://model-test.example.com" "token" "refresh" "$future_expiry"
result=$(pn_get_preferred_model)
assert_output_equals "echo '$result'" "" "Empty string, not an error, when unset"

test_case "pn_save_preferred_model then pn_get_preferred_model round-trips"
pn_save_preferred_model "anthropic/claude-opus-4-7"
result=$(pn_get_preferred_model)
assert_output_equals "echo '$result'" "anthropic/claude-opus-4-7" "Round-trips the saved model id"

test_case "pn_save_credentials (simulating a token refresh) does not wipe a saved preferred_model"
new_expiry=$(($(date +%s) + 3600))
pn_save_credentials "https://model-test.example.com" "refreshed-token" "refreshed-refresh" "$new_expiry"
result=$(pn_get_preferred_model)
assert_output_equals "echo '$result'" "anthropic/claude-opus-4-7" "Survives a credentials refresh unchanged"
result=$(pn_load_credentials | "$JQ_BIN" -r '.access_token')
assert_output_equals "echo '$result'" "refreshed-token" "The refreshed fields themselves still updated correctly"

test_case "pn_save_preferred_model fails when not configured"
rm -f "$HOME/.pn/credentials.json"
assert_failure "pn_save_preferred_model 'some-model'" "Returns failure with no credentials file to merge into"

# Regression coverage for P2-3: pn_resolve_model is the shared
# precedence chain (env var > saved preference > default) that used to
# be duplicated by hand across six files -- covering every tier here is
# what actually catches a future drift, not just that the function
# exists.
test_case "pn_resolve_model: tier 3, nothing set, falls back to the default"
rm -f "$HOME/.pn/credentials.json"
unset PARADIGM_NETWORKS_MODEL
pn_resolve_model
assert_output_equals "echo '$PN_RESOLVED_MODEL'" "$PN_DEFAULT_MODEL" "Resolves to PN_DEFAULT_MODEL"
assert_output_equals "echo '$PN_RESOLVED_MODEL_IS_DEFAULT'" "true" "Flags it as the default"

test_case "pn_resolve_model: tier 2, saved preference wins over the default"
pn_save_credentials "https://model-resolve-test.example.com" "tok" "reftok" "$(($(date +%s) + 3600))"
pn_save_preferred_model "anthropic/claude-opus-4-7"
pn_resolve_model
assert_output_equals "echo '$PN_RESOLVED_MODEL'" "anthropic/claude-opus-4-7" "Resolves to the saved preference"
assert_output_equals "echo '$PN_RESOLVED_MODEL_IS_DEFAULT'" "false" "Not flagged as the default"

test_case "pn_resolve_model: tier 1, env var wins over the saved preference"
export PARADIGM_NETWORKS_MODEL="anthropic/claude-sonnet-4-6"
pn_resolve_model
assert_output_equals "echo '$PN_RESOLVED_MODEL'" "anthropic/claude-sonnet-4-6" "Resolves to the env var, not the saved preference"
assert_output_equals "echo '$PN_RESOLVED_MODEL_IS_DEFAULT'" "false" "Not flagged as the default"
unset PARADIGM_NETWORKS_MODEL

echo ""
echo -e "${BLUE}=== Unit Tests: login.sh ===${NC}"

# Safe to source directly (rather than sed-extracting functions): login.sh
# guards its own `main "$@"` call behind a BASH_SOURCE-vs-$0 check
# specifically so it can be sourced like this for testing.
source "$SCRIPTS_DIR/login.sh"

test_case "wait_for_callback: a denied-consent callback is reported as a denial, not a false CSRF alarm"
# Regression test for P0-3: wait_for_callback used to return code/state/
# error as a single space-joined string (`echo "$CODE $STATE $ERROR"`),
# read back with `read -r code state_got error_msg`. A denied consent has
# no code, so that leading empty field shifted STATE into error_msg's
# slot and ERROR out of the string entirely -- error_msg silently landed
# empty, the (now-misaligned) state comparison failed instead, and the
# user saw "possible CSRF, aborting" for what was actually a normal
# denial. Drives the real function end-to-end via a real local HTTP
# request, the same mechanism a real browser redirect uses.
callback_port=18765
callback_deadline=$(($(date +%s) + 10))
(
  sleep 0.5
  curl -s -o /dev/null "http://127.0.0.1:${callback_port}/callback?state=abc123&error=access_denied"
) &
curl_pid=$!
wait_for_callback "$callback_port" "$callback_deadline"
wait_for_callback_status=$?
wait "$curl_pid" 2>/dev/null

assert_output_equals "echo '$wait_for_callback_status'" "0" "wait_for_callback received the request (didn't time out)"
assert_output_equals "echo '$CALLBACK_CODE'" "" "CALLBACK_CODE is empty (denied consent has no code)"
assert_output_equals "echo '$CALLBACK_STATE'" "abc123" "CALLBACK_STATE is correctly the real state, not shifted"
assert_output_equals "echo '$CALLBACK_ERROR'" "access_denied" "CALLBACK_ERROR is correctly the real error, not lost"

# Replicate main()'s own decision sequence (error check, then state check,
# then code check) to prove the fix end-to-end -- this used to fall
# through to the state-mismatch branch instead.
expected_state="abc123"
login_outcome=""
if [[ -n "$CALLBACK_ERROR" ]]; then
  login_outcome="denied:$CALLBACK_ERROR"
elif [[ "$CALLBACK_STATE" != "$expected_state" ]]; then
  login_outcome="csrf_mismatch"
elif [[ -z "$CALLBACK_CODE" ]]; then
  login_outcome="no_code"
else
  login_outcome="proceed"
fi
assert_output_equals "echo '$login_outcome'" "denied:access_denied" "Reports as a denial, not a CSRF mismatch"

test_case "urlencode_strict/urldecode_strict round-trip a code containing a reserved character"
# Regression test for P0-2: the callback used to skip decoding entirely,
# so a code re-encoded on the way to the token exchange (double-encoding
# any character outside [a-zA-Z0-9.~_-]).
wire_value=$(urlencode_strict "AB+CD")
decoded_value=$(urldecode_strict "$wire_value")
reencoded_value=$(urlencode_strict "$decoded_value")
assert_output_equals "echo '$decoded_value'" "AB+CD" "Decodes back to the true value"
assert_output_equals "echo '$reencoded_value'" "$wire_value" "Re-encoding the decoded value matches the original wire value (single encoding, not double)"

echo ""
test_summary
FINAL_RESULT=$?

test_cleanup
exit $FINAL_RESULT
