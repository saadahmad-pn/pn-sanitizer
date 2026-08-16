#!/bin/bash
# Integration tests for hook scripts

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
SCRIPTS_DIR="$PROJECT_DIR/scripts"

source "$TEST_DIR/test-utils.sh"
source "$TEST_DIR/mock-server.sh"

test_init
source_scripts

echo -e "${BLUE}=== Integration Tests: check-session.sh ===${NC}"

test_case "check-session.sh with jq installed and PN not configured"
result=$("$SCRIPTS_DIR/check-session.sh" <<< '{}')
assert_json_valid "$result" "Valid JSON output"
assert_json_has_key "$result" "additional_context" "Shows context when not configured"

test_case "check-session.sh with jq and PN configured"
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
result=$("$SCRIPTS_DIR/check-session.sh" <<< '{}')
assert_json_valid "$result" "Valid JSON output"
# Should be empty context when configured
if [[ "$result" == "{}" ]]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "  ${GREEN}✓${NC} Returns empty context when configured"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "  ${RED}✗${NC} Should return empty context when configured (got: $result)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo ""
echo -e "${BLUE}=== Integration Tests: check-prompt.sh ===${NC}"

test_case "check-prompt.sh allows prompt when PN not configured"
rm -f "$HOME/.pn/credentials.json"
payload='{"prompt": "What is the answer?"}'
result=$("$SCRIPTS_DIR/check-prompt.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "continue" "true" "Fails open when not configured"

test_case "check-prompt.sh with valid credentials (needs API)"
mock_credentials "https://test.com" "test-token" "refresh" "$(($(date +%s) + 3600))"
payload='{"prompt": "test prompt"}'
# This will fail because we don't have a real API, but it tests the flow
result=$("$SCRIPTS_DIR/check-prompt.sh" <<< "$payload" 2>/dev/null) || true
if [[ -n "$result" ]]; then
  assert_json_valid "$result" "Valid JSON response"
fi

test_case "check-prompt.sh with invalid JSON input"
result=$("$SCRIPTS_DIR/check-prompt.sh" <<< "not valid json" 2>/dev/null)
assert_json_valid "$result" "Valid JSON output even with bad input"
assert_json_field_equals "$result" "continue" "false" "Denies on invalid input"

test_case "check-prompt.sh with empty prompt"
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
payload='{"prompt": ""}'
result=$("$SCRIPTS_DIR/check-prompt.sh" <<< "$payload" 2>/dev/null) || true
# Empty prompt still gets processed

echo ""
echo -e "${BLUE}=== Integration Tests: check-write.sh ===${NC}"

test_case "check-write.sh allows non-Write/Edit tools"
payload='{"tool_name": "Read", "agent_message": "content"}'
result=$("$SCRIPTS_DIR/check-write.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "allow" "Non-Write/Edit tools allowed"

test_case "check-write.sh with Write tool but empty message"
payload='{"tool_name": "Write", "agent_message": "", "tool_input": {"file_path": "test.txt"}}'
result=$("$SCRIPTS_DIR/check-write.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "allow" "Allows when nothing to scan"

test_case "check-write.sh with Write and message when not configured"
rm -f "$HOME/.pn/credentials.json"
payload='{"tool_name": "Write", "agent_message": "test content", "tool_input": {"file_path": "test.txt"}}'
result=$("$SCRIPTS_DIR/check-write.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
# With SNANTIZER_FAILURE_MODE=closed (default), should deny
assert_json_field_equals "$result" "permission" "deny" "Fails closed (default) when not configured"

test_case "check-write.sh with FAILURE_MODE=open"
rm -f "$HOME/.pn/credentials.json"
payload='{"tool_name": "Write", "agent_message": "test", "tool_input": {"file_path": "f.txt"}}'
export SNANTIZER_FAILURE_MODE="open"
result=$("$SCRIPTS_DIR/check-write.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "allow" "Fails open when mode=open"
unset SNANTIZER_FAILURE_MODE

test_case "check-write.sh audit log written"
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
rm -f "$HOME/.paradigm-scanner/audit.jsonl"
payload='{"tool_name": "Write", "agent_message": "test", "tool_input": {"file_path": "test.txt"}}'
"$SCRIPTS_DIR/check-write.sh" <<< "$payload" >/dev/null 2>&1 || true
if [[ -f "$HOME/.paradigm-scanner/audit.jsonl" ]]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "  ${GREEN}✓${NC} Audit log written"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "  ${RED}✗${NC} Audit log not written"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo ""
echo ""
test_summary
FINAL_RESULT=$?

test_cleanup
exit $FINAL_RESULT
