#!/bin/bash
# Unit tests for lib/scan-client.sh -- the POST /api/v1/codedefense/scan
# client that replaced check-prompt.sh/check-write.sh's /v1/messages calls.
# See design-ideas/Codechain_Plugin_Hooks_Design.md and CHANGELOG.md.

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-utils.sh"

test_init
source_scripts

echo -e "${BLUE}=== Unit Tests: lib/scan-client.sh ===${NC}"

test_case "pn_scan_text: 2xx + action_to_take=allow -> Status=ok, Action=allow"
http_post_multipart_form() {
  echo '{"action_to_take":"allow","message":"","overall_threat_level":"none"}'
  echo "200"
}
pn_scan_text "https://acme.example.com" "token" 5 "hello world"
assert_output_equals "echo \"\$PN_SCAN_STATUS\"" "ok" "status is ok"
assert_output_equals "echo \"\$PN_SCAN_ACTION\"" "allow" "action is allow"
assert_output_equals "echo \"\$PN_SCAN_THREAT_LEVEL\"" "none" "threat level captured"

test_case "pn_scan_text: action_to_take=block -> Action=block, Message carries the finding"
http_post_multipart_form() {
  echo '{"action_to_take":"block","message":"Detected a hardcoded credential.","overall_threat_level":"high"}'
  echo "200"
}
pn_scan_text "https://acme.example.com" "token" 5 "some content"
assert_output_equals "echo \"\$PN_SCAN_ACTION\"" "block" "action is block"
assert_output_equals "echo \"\$PN_SCAN_MESSAGE\"" "Detected a hardcoded credential." "message carried through"

test_case "pn_scan_text: action_to_take=warn -> Action=warn"
http_post_multipart_form() {
  echo '{"action_to_take":"warn","message":"Looks like debug code.","overall_threat_level":"low"}'
  echo "200"
}
pn_scan_text "https://acme.example.com" "token" 5 "some content"
assert_output_equals "echo \"\$PN_SCAN_ACTION\"" "warn" "action is warn"

test_case "pn_scan_text: valid JSON with no action_to_take -> Status=ok, Action empty (anomaly, not guessed)"
http_post_multipart_form() {
  echo '{"something_else":true}'
  echo "200"
}
pn_scan_text "https://acme.example.com" "token" 5 "some content"
assert_output_equals "echo \"\$PN_SCAN_STATUS\"" "ok" "status is still ok (valid JSON, valid HTTP)"
assert_output_equals "echo \"\$PN_SCAN_ACTION\"" "" "action is empty, not guessed as allow or block"

test_case "pn_scan_text: HTTP 500 -> Status=http_error, HttpStatus captured"
http_post_multipart_form() {
  echo '{"error":"internal"}'
  echo "500"
}
pn_scan_text "https://acme.example.com" "token" 5 "some content"
assert_output_equals "echo \"\$PN_SCAN_STATUS\"" "http_error" "status is http_error"
assert_output_equals "echo \"\$PN_SCAN_HTTP_STATUS\"" "500" "http status captured"

test_case "pn_scan_text: invalid JSON body -> Status=invalid_json"
http_post_multipart_form() {
  echo 'not json at all'
  echo "200"
}
pn_scan_text "https://acme.example.com" "token" 5 "some content"
assert_output_equals "echo \"\$PN_SCAN_STATUS\"" "invalid_json" "status is invalid_json"

test_case "pn_scan_text: curl timeout (exit 28) -> Status=timeout"
http_post_multipart_form() { return 28; }
pn_scan_text "https://acme.example.com" "token" 5 "some content"
assert_output_equals "echo \"\$PN_SCAN_STATUS\"" "timeout" "status is timeout"

test_case "pn_scan_text: curl connection failure (exit 7) -> Status=unreachable"
http_post_multipart_form() { return 7; }
pn_scan_text "https://acme.example.com" "token" 5 "some content"
assert_output_equals "echo \"\$PN_SCAN_STATUS\"" "unreachable" "status is unreachable"

# http_post_multipart_form is invoked as raw=$(http_post_multipart_form ...)
# inside pn_scan_text -- a genuine subshell -- so a variable assignment from
# inside this mock cannot cross back out to this script (same reason this
# codebase's real multi-value returns use globals set by a plain-statement
# call, never $(...): see CLAUDE.md). A file write survives the subshell
# boundary, unlike a variable assignment.
test_case "pn_scan_text: posts to POST /api/v1/codedefense/scan"
captured_url_file="$TEST_TEMP_DIR/captured-scan-url.txt"
http_post_multipart_form() {
  echo -n "$1" > "$captured_url_file"
  echo '{"action_to_take":"allow"}'
  echo "200"
}
pn_scan_text "https://acme.example.com/" "token" 5 "some content"
assert_output_equals "cat '$captured_url_file'" "https://acme.example.com/api/v1/codedefense/scan" "URL built correctly (trailing slash on base_url handled)"

test_summary
