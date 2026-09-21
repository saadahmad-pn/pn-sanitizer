#!/bin/bash
# Unit tests for lib/codechain-client.sh (Code Chain plugin-hooks recording)
# and lib/common.sh's get_current_turn_messages. See
# design-ideas/Codechain_Plugin_Hooks_Design.md for the design this
# implements.

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-utils.sh"

test_init
source_scripts

echo -e "${BLUE}=== Unit Tests: lib/codechain-client.sh ===${NC}"

# SessionId is Cursor's own conversation_id, used as-is on every call --
# there is no server-side minting/lookup and no local cache, so every test
# below just asserts what gets posted for a given session id, not any
# cache-hit/miss behavior (there is none left to test).

test_case "pn_register_codechain_session: posts Platform/SessionId/Cwd/GitRepoUrl/GitBranch as JSON"
captured_body_file="$TEST_TEMP_DIR/captured-register-body.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file"
  echo ""
  echo "200"
}
pn_register_codechain_session "https://acme.example.com" "token" 5 "conv-1" "/repo" "github.com/org/repo" "main"
assert_output_equals "\"\$JQ_BIN\" -r '.Platform' '$captured_body_file'" "cursor-hooks" "Platform is hardcoded"
assert_output_equals "\"\$JQ_BIN\" -r '.SessionId' '$captured_body_file'" "conv-1" "SessionId is the client's own id, used as-is"
assert_output_equals "\"\$JQ_BIN\" -r '.Cwd' '$captured_body_file'" "/repo" "Cwd encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.GitRepoUrl' '$captured_body_file'" "github.com/org/repo" "GitRepoUrl encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.GitBranch' '$captured_body_file'" "main" "GitBranch encoded correctly"

test_case "pn_register_codechain_session: empty SessionId -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_register_codechain_session 'https://acme.example.com' 'token' 5 '' '/repo' '' ''" "returns cleanly without calling http_post_json"

test_case "pn_register_codechain_session: empty base_url -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_register_codechain_session '' 'token' 5 'conv-1' '/repo' '' ''" "not configured -> no-op, not an error"

test_case "pn_record_codechain_turn: posts Cwd/GitRepoUrl/GitBranch/Prompt/Response as JSON"
# http_post_json is invoked as raw=$(http_post_json ...) inside
# pn_record_codechain_turn -- a genuine subshell -- so a variable assignment
# from inside this mock cannot cross back out to this script (the same
# reason this codebase's real multi-value returns use globals set by a
# plain-statement call, never $(...): see CLAUDE.md). A file write does
# survive the subshell boundary, unlike a variable assignment, so the mock
# captures the request body there instead.
captured_body_file="$TEST_TEMP_DIR/captured-turn-body.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file"
  echo ""
  echo "204"
}
pn_record_codechain_turn "https://acme.example.com" "token" 5 "session-1" "/repo" "github.com/org/repo" "main" "do the thing" "done"
assert_output_equals "\"\$JQ_BIN\" -r '.Prompt' '$captured_body_file'" "do the thing" "Prompt encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Response' '$captured_body_file'" "done" "Response encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Cwd' '$captured_body_file'" "/repo" "Cwd encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.GitBranch' '$captured_body_file'" "main" "GitBranch encoded correctly"

test_case "pn_record_codechain_turn: empty SessionId -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_record_codechain_turn 'https://acme.example.com' 'token' 5 '' '/repo' '' '' 'p' 'r'" "returns cleanly without calling http_post_json"

test_case "pn_record_codechain_shell_event: posts Cwd/GitRepoUrl/GitBranch/Command/Output as JSON"
captured_body_file="$TEST_TEMP_DIR/captured-shell-event-body.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file"
  echo ""
  echo "204"
}
pn_record_codechain_shell_event "https://acme.example.com" "token" 5 "session-1" "/repo" "github.com/org/repo" "main" "git commit -m x" "[main abc1234] x"
assert_output_equals "\"\$JQ_BIN\" -r '.Command' '$captured_body_file'" "git commit -m x" "Command encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Output' '$captured_body_file'" "[main abc1234] x" "Output encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Cwd' '$captured_body_file'" "/repo" "Cwd encoded correctly"

test_case "pn_record_codechain_shell_event: empty command -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_record_codechain_shell_event 'https://acme.example.com' 'token' 5 'session-1' '/repo' '' '' '' 'out'" "returns cleanly without calling http_post_json"

test_case "pn_close_codechain_session: posts to the given SessionId directly, no lookup"
http_post_json() {
  echo ""
  echo "204"
}
assert_success "pn_close_codechain_session 'https://acme.example.com' 'token' 5 'conv-1'" "closes using the client-supplied session id directly"

test_case "pn_close_codechain_session: empty SessionId -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_close_codechain_session 'https://acme.example.com' 'token' 5 ''" "returns cleanly without calling http_post_json"

echo -e "${BLUE}=== Unit Tests: get_current_turn_messages (lib/common.sh) ===${NC}"

test_case "get_current_turn_messages: separates prompt and response text by role"
transcript="$TEST_TEMP_DIR/transcript.jsonl"
{
  echo '{"role":"user","message":{"content":[{"type":"text","text":"earlier unrelated turn"}]}}'
  echo '{"role":"assistant","message":{"content":[{"type":"text","text":"earlier unrelated reply"}]}}'
  echo '{"role":"user","message":{"content":[{"type":"text","text":"fix the bug"}]}}'
  echo '{"role":"assistant","message":{"content":[{"type":"text","text":"fixed it"}]}}'
} > "$transcript"
get_current_turn_messages "$transcript" 500
assert_output_equals "echo \"\$PN_TURN_PROMPT\"" "fix the bug" "only the current turn's user text, not the earlier turn"
assert_output_equals "echo \"\$PN_TURN_RESPONSE\"" "fixed it" "only the current turn's assistant text"

test_case "get_current_turn_messages: missing transcript file -> both empty, no error"
get_current_turn_messages "$TEST_TEMP_DIR/does-not-exist.jsonl" 500
assert_output_equals "echo \"\$PN_TURN_PROMPT\"" "" "prompt empty"
assert_output_equals "echo \"\$PN_TURN_RESPONSE\"" "" "response empty"

test_summary
