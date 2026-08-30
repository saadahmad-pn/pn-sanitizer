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
assert_output_equals "echo \"\$PN_MSG_MESSAGE\"" "destructive operation" "reason extracted cleanly"

test_case "pn_parse_messages_response: zero usage, no banner -> anomaly (not guessed either way)"
pn_parse_messages_response '{"content":[{"type":"text","text":"just a normal-looking short reply"}],"usage":{"input_tokens":0,"output_tokens":0}}'
assert_output_equals "echo \"\$PN_MSG_ACTION\"" "anomaly" "action is anomaly"

test_case "pn_parse_messages_response: empty content array -> anomaly"
pn_parse_messages_response '{"content":[],"usage":{"input_tokens":10,"output_tokens":5}}'
assert_output_equals "echo \"\$PN_MSG_ACTION\"" "anomaly" "action is anomaly"

test_case "pn_parse_messages_response: leading thinking block -> still finds block signal in the text block after it"
pn_parse_messages_response '{"content":[{"type":"thinking","thinking":"reasoning..."},{"type":"text","text":"```\n===\n  REQUEST BLOCKED\n===\n\n  The submitted content was flagged because it triggered the following security concerns: prompt injection.\n\n===\n```"}],"usage":{"input_tokens":0,"output_tokens":0}}'
assert_output_equals "echo \"\$PN_MSG_ACTION\"" "block" "action is block (not derailed by the leading thinking block)"
assert_output_equals "echo \"\$PN_MSG_MESSAGE\"" "prompt injection" "reason extracted from the correct block"

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

test_case "pn_resolve_config uses env vars first"
export SNANTIZER_BASE_URL="https://env.example.com"
export SNANTIZER_TOKEN="env-token"
result=$(pn_resolve_config)
assert_output_contains "echo '$result'" "https://env.example.com" "Uses env base_url"
assert_output_contains "echo '$result'" "env-token" "Uses env token"
unset SNANTIZER_BASE_URL SNANTIZER_TOKEN

test_case "pn_resolve_config falls back to file"
rm -f "$HOME/.pn/credentials.json"
# Use a future expiry time (current time + 7200 seconds)
future_expiry=$(($(date +%s) + 7200))
pn_save_credentials "https://file.example.com" "file-token" "refresh" "$future_expiry"
result=$(pn_resolve_config)
assert_output_contains "echo '$result'" "https://file.example.com" "Uses file base_url"
assert_output_contains "echo '$result'" "file-token" "Uses file token"

echo ""
test_summary
FINAL_RESULT=$?

test_cleanup
exit $FINAL_RESULT
