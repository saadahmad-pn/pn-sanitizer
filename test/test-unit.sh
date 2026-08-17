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
