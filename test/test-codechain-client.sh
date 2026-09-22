#!/bin/bash
# Unit tests for lib/plugins-client.sh's session-lifecycle and after_*
# (recording) functions -- pn_register_plugin_session, pn_close_plugin_session,
# pn_plugin_after_prompt, pn_plugin_after_shell_execution,
# pn_plugin_after_tool_call -- which replaced lib/codechain-client.sh's
# pn_register_codechain_session/pn_record_codechain_turn/
# pn_record_codechain_shell_event/pn_close_codechain_session. Also covers
# lib/common.sh's get_current_turn_messages, unaffected by this round. See
# design-ideas/Plugin_API_Standardization_And_Hook_Consolidation_Design.md.

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-utils.sh"

test_init
source_scripts

echo -e "${BLUE}=== Unit Tests: lib/plugins-client.sh (session lifecycle + recording) ===${NC}"

# SessionId is Cursor's own conversation_id, used as-is on every call --
# there is no server-side minting/lookup and no local cache, so every test
# below just asserts what gets posted for a given session id, not any
# cache-hit/miss behavior (there is none left to test).

test_case "pn_register_plugin_session: posts Platform/SessionId/Cwd/GitRepoUrl/GitBranch as JSON"
captured_body_file="$TEST_TEMP_DIR/captured-register-body.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file"
  echo ""
  echo "200"
}
pn_register_plugin_session "https://acme.example.com" "token" 5 "conv-1" "/repo" "github.com/org/repo" "main"
assert_output_equals "\"\$JQ_BIN\" -r '.Platform' '$captured_body_file'" "cursor-hooks" "Platform is hardcoded"
assert_output_equals "\"\$JQ_BIN\" -r '.SessionId' '$captured_body_file'" "conv-1" "SessionId is the client's own id, used as-is"
assert_output_equals "\"\$JQ_BIN\" -r '.Cwd' '$captured_body_file'" "/repo" "Cwd encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.GitRepoUrl' '$captured_body_file'" "github.com/org/repo" "GitRepoUrl encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.GitBranch' '$captured_body_file'" "main" "GitBranch encoded correctly"

test_case "pn_register_plugin_session: empty SessionId -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_register_plugin_session 'https://acme.example.com' 'token' 5 '' '/repo' '' ''" "returns cleanly without calling http_post_json"

test_case "pn_register_plugin_session: empty base_url -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_register_plugin_session '' 'token' 5 'conv-1' '/repo' '' ''" "not configured -> no-op, not an error"

test_case "pn_plugin_after_prompt: posts Action/Cwd/GitRepoUrl/GitBranch/Text/Response as JSON"
# http_post_json is invoked as raw=$(http_post_json ...) inside
# pn_plugin_after_prompt -- a genuine subshell -- so a variable assignment
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
pn_plugin_after_prompt "https://acme.example.com" "token" 5 "session-1" "/repo" "github.com/org/repo" "main" "do the thing" "done" "gen-abc" "claude-sonnet-4-5"
assert_output_equals "\"\$JQ_BIN\" -r '.Action' '$captured_body_file'" "after_prompt" "Action encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Text' '$captured_body_file'" "do the thing" "Text (the prompt, for the no-open-turn fallback) encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Response' '$captured_body_file'" "done" "Response encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Cwd' '$captured_body_file'" "/repo" "Cwd encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.GitBranch' '$captured_body_file'" "main" "GitBranch encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.GenerationId' '$captured_body_file'" "gen-abc" "GenerationId encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Model' '$captured_body_file'" "claude-sonnet-4-5" "Model encoded correctly"

test_case "pn_plugin_after_prompt: generation_id omitted -> GenerationId encoded as empty string"
captured_body_file_no_gen="$TEST_TEMP_DIR/captured-turn-body-no-gen.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file_no_gen"
  echo ""
  echo "204"
}
pn_plugin_after_prompt "https://acme.example.com" "token" 5 "session-1" "/repo" "" "" "do the thing" "done"
assert_output_equals "\"\$JQ_BIN\" -r '.GenerationId' '$captured_body_file_no_gen'" "" "GenerationId defaults to empty"
assert_output_equals "\"\$JQ_BIN\" -r '.Model' '$captured_body_file_no_gen'" "" "Model defaults to empty"

test_case "pn_plugin_after_prompt: empty SessionId -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_plugin_after_prompt 'https://acme.example.com' 'token' 5 '' '/repo' '' '' 'p' 'r'" "returns cleanly without calling http_post_json"

test_case "pn_plugin_after_prompt: both prompt and response empty -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_plugin_after_prompt 'https://acme.example.com' 'token' 5 'session-1' '/repo' '' '' '' ''" "nothing to record"

test_case "pn_plugin_after_shell_execution: posts Action/Command/Output/Cwd/GenerationId as multipart form"
# http_post_multipart_form's form args arrive as repeated --form-string
# "Key=value" pairs (see lib/common.sh) -- capture the full arg list and
# grep for the field rather than parsing it as JSON, since it never was one.
captured_args_file="$TEST_TEMP_DIR/captured-shell-event-args.txt"
http_post_multipart_form() {
  shift 3
  printf '%s\n' "$@" > "$captured_args_file"
  echo ""
  echo "204"
}
pn_plugin_after_shell_execution "https://acme.example.com" "token" 5 "session-1" "/repo" "github.com/org/repo" "main" "gen-1" "git commit -m x" "[main abc1234] x"
assert_output_contains "cat '$captured_args_file'" "Action=after_shell_execution" "Action encoded correctly"
assert_output_contains "cat '$captured_args_file'" "Command=git commit -m x" "Command encoded correctly"
assert_output_contains "cat '$captured_args_file'" "Output=[main abc1234] x" "Output encoded correctly"
assert_output_contains "cat '$captured_args_file'" "Cwd=/repo" "Cwd encoded correctly"
assert_output_contains "cat '$captured_args_file'" "GenerationId=gen-1" "GenerationId encoded correctly"

test_case "pn_plugin_after_shell_execution: empty command -> no call attempted"
http_post_multipart_form() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_plugin_after_shell_execution 'https://acme.example.com' 'token' 5 'session-1' '/repo' '' '' '' '' 'out'" "returns cleanly without calling http_post_multipart_form"

test_case "pn_plugin_after_shell_execution: empty session id -> no call attempted"
http_post_multipart_form() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_plugin_after_shell_execution 'https://acme.example.com' 'token' 5 '' '/repo' '' '' '' 'ls -la' 'out'" "returns cleanly without calling http_post_multipart_form"

test_case "pn_plugin_after_tool_call: posts Action/ToolUseId/Output/IsError as JSON"
captured_body_file2="$TEST_TEMP_DIR/captured-after-toolcall-body.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file2"
  echo ""
  echo "204"
}
pn_plugin_after_tool_call "https://acme.example.com" "token" 5 "session-1" "/repo" "github.com/org/repo" "main" "toolu_plugin_abc" "origin/main" "false" "gen-1"
assert_output_equals "\"\$JQ_BIN\" -r '.Action' '$captured_body_file2'" "after_tool_call" "Action encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.ToolUseId' '$captured_body_file2'" "toolu_plugin_abc" "ToolUseId encoded correctly -- must match the id before_tool_call minted/echoed"
assert_output_equals "\"\$JQ_BIN\" -r '.Output' '$captured_body_file2'" "origin/main" "Output encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.IsError' '$captured_body_file2'" "false" "IsError encoded correctly"

test_case "pn_plugin_after_tool_call: is_error=true encoded as JSON boolean, not a string"
captured_body_file3="$TEST_TEMP_DIR/captured-after-toolcall-body-2.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file3"
  echo ""
  echo "204"
}
pn_plugin_after_tool_call "https://acme.example.com" "token" 5 "session-1" "" "" "" "toolu_plugin_def" "command not found" "true"
assert_output_equals "\"\$JQ_BIN\" '.IsError' '$captured_body_file3'" "true" "IsError is a real JSON boolean"

test_case "pn_plugin_after_tool_call: empty tool_use_id -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_plugin_after_tool_call 'https://acme.example.com' 'token' 5 'session-1' '' '' '' '' 'out' 'false'" "nothing to correlate the result to"

test_case "pn_close_plugin_session: posts to the given SessionId directly, no lookup"
http_post_json() {
  echo ""
  echo "204"
}
assert_success "pn_close_plugin_session 'https://acme.example.com' 'token' 5 'conv-1'" "closes using the client-supplied session id directly"

test_case "pn_close_plugin_session: empty SessionId -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_close_plugin_session 'https://acme.example.com' 'token' 5 ''" "returns cleanly without calling http_post_json"

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
