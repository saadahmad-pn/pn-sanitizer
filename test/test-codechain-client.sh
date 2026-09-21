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

test_case "sanitize_client_session_id: keeps a UUID unchanged"
assert_output_equals "sanitize_client_session_id 'abc-123-DEF'" "abc-123-DEF" "UUID-shaped input passes through"

test_case "sanitize_client_session_id: replaces unsafe characters"
assert_output_equals "sanitize_client_session_id 'a/b c.d'" "a_b_c.d" "slash and space replaced, dot kept"

test_case "pn_get_codechain_session_id: cache hit -> no network call, returns cached id"
_codechain_cache_write "conv-cached" "session-from-cache"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
pn_get_codechain_session_id "https://acme.example.com" "token" 5 "conv-cached" "/repo" "github.com/org/repo" "main"
assert_output_equals "echo \"\$PN_CODECHAIN_SESSION_ID\"" "session-from-cache" "returns the cached SessionId"

test_case "pn_get_codechain_session_id: cache miss + 200 -> registers, caches, returns SessionId"
rm -rf "${HOME}/.paradigm-scanner/codechain-sessions"
http_post_json() {
  echo '{"SessionId":"minted-abc"}'
  echo "200"
}
pn_get_codechain_session_id "https://acme.example.com" "token" 5 "conv-new" "/repo" "github.com/org/repo" "main"
assert_output_equals "echo \"\$PN_CODECHAIN_SESSION_ID\"" "minted-abc" "returns the server-minted SessionId"
assert_output_equals "_codechain_cache_read 'conv-new'" "minted-abc" "caches it locally for the next call"

test_case "pn_get_codechain_session_id: non-200 response -> empty result, no cache written"
rm -rf "${HOME}/.paradigm-scanner/codechain-sessions"
http_post_json() {
  echo '{"error":"forbidden"}'
  echo "403"
}
pn_get_codechain_session_id "https://acme.example.com" "token" 5 "conv-forbidden" "/repo" "" ""
assert_output_equals "echo \"\$PN_CODECHAIN_SESSION_ID\"" "" "empty on non-200"
assert_output_equals "_codechain_cache_read 'conv-forbidden'" "" "nothing cached on failure"

test_case "pn_get_codechain_session_id: empty ClientSessionId -> empty result, no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
pn_get_codechain_session_id "https://acme.example.com" "token" 5 "" "/repo" "" ""
assert_output_equals "echo \"\$PN_CODECHAIN_SESSION_ID\"" "" "empty ClientSessionId short-circuits"

test_case "pn_get_codechain_session_id: empty base_url on cache miss -> empty result"
rm -rf "${HOME}/.paradigm-scanner/codechain-sessions"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
pn_get_codechain_session_id "" "token" 5 "conv-no-url" "/repo" "" ""
assert_output_equals "echo \"\$PN_CODECHAIN_SESSION_ID\"" "" "not configured -> empty, not an error"

test_case "pn_record_codechain_turn: posts Prompt/Response as JSON"
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
pn_record_codechain_turn "https://acme.example.com" "token" 5 "session-1" "do the thing" "done"
assert_output_equals "\"\$JQ_BIN\" -r '.Prompt' '$captured_body_file'" "do the thing" "Prompt encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Response' '$captured_body_file'" "done" "Response encoded correctly"

test_case "pn_record_codechain_turn: empty SessionId -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_record_codechain_turn 'https://acme.example.com' 'token' 5 '' 'p' 'r'" "returns cleanly without calling http_post_json"

test_case "pn_record_codechain_shell_event: posts Command/Output/Cwd as JSON"
captured_body_file="$TEST_TEMP_DIR/captured-shell-event-body.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file"
  echo ""
  echo "204"
}
pn_record_codechain_shell_event "https://acme.example.com" "token" 5 "session-1" "git commit -m x" "[main abc1234] x" "/repo"
assert_output_equals "\"\$JQ_BIN\" -r '.Command' '$captured_body_file'" "git commit -m x" "Command encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Output' '$captured_body_file'" "[main abc1234] x" "Output encoded correctly"

test_case "pn_record_codechain_shell_event: empty command -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_record_codechain_shell_event 'https://acme.example.com' 'token' 5 'session-1' '' 'out' '/repo'" "returns cleanly without calling http_post_json"

test_case "pn_close_codechain_session: no cached session -> no call attempted, no error"
rm -rf "${HOME}/.paradigm-scanner/codechain-sessions"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_close_codechain_session 'https://acme.example.com' 'token' 5 'conv-never-registered'" "returns cleanly with nothing to close"

test_case "pn_close_codechain_session: cached session -> closes and clears the cache entry"
_codechain_cache_write "conv-to-close" "session-to-close"
http_post_json() {
  echo ""
  echo "204"
}
pn_close_codechain_session "https://acme.example.com" "token" 5 "conv-to-close"
assert_output_equals "_codechain_cache_read 'conv-to-close'" "" "cache entry removed after close"

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
