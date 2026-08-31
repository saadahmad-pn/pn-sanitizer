#!/bin/bash
# Error scenario and edge case tests

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
SCRIPTS_DIR="$PROJECT_DIR/scripts"

source "$TEST_DIR/test-utils.sh"

test_init
source_scripts

echo -e "${BLUE}=== Error Scenario Tests ===${NC}"

echo ""
echo -e "${BLUE}--- File System Errors ---${NC}"

test_case "Cannot read credentials file (permission denied)"
mkdir -p "$HOME/.pn"
future_expiry=$(($(date +%s) + 7200))
pn_save_credentials "https://test.com" "token" "refresh" "$future_expiry"
chmod 000 "$HOME/.pn/credentials.json"
result=$(pn_resolve_config 2>/dev/null) || true
# Should fail gracefully
chmod 600 "$HOME/.pn/credentials.json"
if [[ -z "$result" ]]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "  ${GREEN}✓${NC} Graceful failure with permission denied"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "  ${RED}✗${NC} Should handle permission denied"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_case "Cannot create log directory (readonly parent)"
readonly_dir="$TEST_TEMP_DIR/readonly"
mkdir -p "$readonly_dir"
chmod 555 "$readonly_dir"
log_path="$readonly_dir/logs/test.log"
log_debug "test" "$log_path" 2>/dev/null || true
chmod 755 "$readonly_dir"
# Should not crash, just silently fail to log

test_case "Transcript file doesn't exist"
payload='{"tool_name": "Write", "agent_message": "", "transcript_path": "/nonexistent/path", "tool_input": {"file_path": "f.txt"}}'
export SNANTIZER_FAILURE_MODE="open"
result=$("$SCRIPTS_DIR/check-write.sh" <<< "$payload" 2>/dev/null)
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "allow" "Allows when transcript missing"
unset SNANTIZER_FAILURE_MODE

echo ""
echo -e "${BLUE}--- Malformed Input Tests ---${NC}"

test_case "Invalid JSON in hook payload"
result=$("$SCRIPTS_DIR/check-prompt.sh" <<< "not json" 2>/dev/null)
assert_json_valid "$result" "Returns valid JSON"
# See P0-1: malformed input must fail open (like check-write.sh already
# does), not hard-block every prompt with no PROMPT_FAILURE_MODE escape.
assert_json_field_equals "$result" "continue" "true" "Allows malformed input (fails open, not closed)"

test_case "Missing required fields in JSON"
payload='{"other_field": "value"}'
result=$("$SCRIPTS_DIR/check-prompt.sh" <<< "$payload" 2>/dev/null)
assert_json_valid "$result" "Returns valid JSON"
# Should handle gracefully

test_case "Null/empty values in payload"
payload='{"prompt": null, "agent_message": ""}'
result=$("$SCRIPTS_DIR/check-prompt.sh" <<< "$payload" 2>/dev/null) || true
# Should not crash

test_case "Very large prompt (10KB)"
large_prompt=$(python3 -c "print('x' * 10000)")
payload=$("$JQ_BIN" -n --arg p "$large_prompt" '{prompt: $p}')
result=$("$SCRIPTS_DIR/check-prompt.sh" <<< "$payload" 2>/dev/null) || true
# Should not crash or timeout

echo ""
echo -e "${BLUE}--- Edge Cases ---${NC}"

test_case "Token expiring in exactly 60 seconds"
future_expiry=$(($(date +%s) + 60))
mkdir -p "$HOME/.pn"
"$JQ_BIN" -n \
  --arg base_url "https://test.com" \
  --arg access_token "old-token" \
  --arg refresh_token "refresh-token" \
  --arg expires_at "$future_expiry" \
  '{base_url: $base_url, access_token: $access_token, refresh_token: $refresh_token, expires_at: $expires_at}' \
  > "$HOME/.pn/credentials.json"
# This should attempt refresh, but we don't have a real API so it will fail gracefully
pn_resolve_config 2>/dev/null || true

test_case "Token already expired"
past_expiry=$(($(date +%s) - 3600))
mkdir -p "$HOME/.pn"
"$JQ_BIN" -n \
  --arg base_url "https://test.com" \
  --arg access_token "old-token" \
  --arg refresh_token "refresh-token" \
  --arg expires_at "$past_expiry" \
  '{base_url: $base_url, access_token: $access_token, refresh_token: $refresh_token, expires_at: $expires_at}' \
  > "$HOME/.pn/credentials.json"
# Should attempt refresh
pn_resolve_config 2>/dev/null || true

test_case "Base URL with trailing slash"
mkdir -p "$HOME/.pn"
pn_save_credentials "https://test.com/" "token" "refresh" "$(($(date +%s) + 3600))"
result=$(pn_load_credentials)
assert_json_field_equals "$result" "base_url" "https://test.com/" "Preserves trailing slash"

test_case "Base URL without trailing slash"
mkdir -p "$HOME/.pn"
pn_save_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
result=$(pn_load_credentials)
assert_json_field_equals "$result" "base_url" "https://test.com" "Preserves without trailing slash"

test_case "Empty agent message with valid transcript"
test_file="$TEST_TEMP_DIR/transcript.txt"
echo "line1
line2
line3" > "$test_file"
payload=$("$JQ_BIN" -n --arg path "$test_file" '{tool_name: "Write", agent_message: "", transcript_path: $path, tool_input: {file_path: "f.txt"}}')
export SNANTIZER_FAILURE_MODE="open"
result=$("$SCRIPTS_DIR/check-write.sh" <<< "$payload" 2>/dev/null)
assert_json_field_equals "$result" "permission" "allow" "Reads transcript when message empty"
unset SNANTIZER_FAILURE_MODE

echo ""
test_summary
FINAL_RESULT=$?

test_cleanup
exit $FINAL_RESULT
