#!/bin/bash
# Unit tests for lib/plugins-client.sh's after_* (recording) functions --
# pn_plugin_after_agent_response, pn_plugin_after_tool_call -- which
# replaced lib/codechain-client.sh's pn_record_codechain_turn/
# pn_record_codechain_shell_event. Also covers lib/common.sh's
# get_current_turn_messages, unaffected by this round. See design-ideas/
# Plugin_API_Standardization_And_Hook_Consolidation_Design.md.
#
# pn_plugin_after_shell_execution (and the shell-executions domain generally)
# is retired -- see design-ideas/
# Shell_Execution_vs_Tool_Call_Hook_Coverage_Validation.md. Its git/PR
# detection now fires from pn_plugin_after_tool_call when ToolName=="Shell",
# tested below.
#
# pn_register_plugin_session/pn_close_plugin_session (session-lifecycle API
# calls) and pn_plugin_after_prompt (renamed to pn_plugin_after_agent_response)
# are retired/renamed -- see design-ideas/
# Session_Lifecycle_Simplification_And_Contract_Updates.md. Session-lifecycle
# coverage now lives in test-session-metadata.sh, for the local-file
# mechanism that replaced the API calls.

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-utils.sh"

test_init
source_scripts

echo -e "${BLUE}=== Unit Tests: lib/plugins-client.sh (after_* recording) ===${NC}"

# SessionId is Cursor's own conversation_id, used as-is on every call --
# there is no server-side minting/lookup and no local cache, so every test
# below just asserts what gets posted for a given session id, not any
# cache-hit/miss behavior (there is none left to test).

test_case "pn_plugin_after_agent_response: posts Action/Cwd/GitRepoUrl/GitBranch/Text/Response as JSON"
# http_post_json is invoked as raw=$(http_post_json ...) inside
# pn_plugin_after_agent_response -- a genuine subshell -- so a variable
# assignment from inside this mock cannot cross back out to this script (the
# same reason this codebase's real multi-value returns use globals set by a
# plain-statement call, never $(...): see CLAUDE.md). A file write does
# survive the subshell boundary, unlike a variable assignment, so the mock
# captures the request body there instead.
captured_body_file="$TEST_TEMP_DIR/captured-turn-body.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file"
  echo ""
  echo "204"
}
pn_plugin_after_agent_response "https://acme.example.com" "token" 5 "session-1" "/repo" "github.com/org/repo" "main" "do the thing" "done" "gen-abc" "claude-sonnet-4-5"
assert_output_equals "\"\$JQ_BIN\" -r '.Action' '$captured_body_file'" "after_agent_response" "Action encoded correctly -- renamed from after_prompt"
assert_output_equals "\"\$JQ_BIN\" -r '.Platform' '$captured_body_file'" "cursor-plugin" "Platform encoded correctly -- renamed from cursor-hooks"
assert_output_equals "\"\$JQ_BIN\" -r '.Text' '$captured_body_file'" "do the thing" "Text (the prompt, for the no-open-turn fallback) encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Response' '$captured_body_file'" "done" "Response encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Cwd' '$captured_body_file'" "/repo" "Cwd encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.GitBranch' '$captured_body_file'" "main" "GitBranch encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.GenerationId' '$captured_body_file'" "gen-abc" "GenerationId encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Model' '$captured_body_file'" "claude-sonnet-4-5" "Model encoded correctly"

test_case "pn_plugin_after_agent_response: generation_id omitted -> GenerationId encoded as empty string"
captured_body_file_no_gen="$TEST_TEMP_DIR/captured-turn-body-no-gen.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file_no_gen"
  echo ""
  echo "204"
}
pn_plugin_after_agent_response "https://acme.example.com" "token" 5 "session-1" "/repo" "" "" "do the thing" "done"
assert_output_equals "\"\$JQ_BIN\" -r '.GenerationId' '$captured_body_file_no_gen'" "" "GenerationId defaults to empty"
assert_output_equals "\"\$JQ_BIN\" -r '.Model' '$captured_body_file_no_gen'" "" "Model defaults to empty"

test_case "pn_plugin_after_agent_response: empty SessionId -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_plugin_after_agent_response 'https://acme.example.com' 'token' 5 '' '/repo' '' '' 'p' 'r'" "returns cleanly without calling http_post_json"

test_case "pn_plugin_after_agent_response: both prompt and response empty -> no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
assert_success "pn_plugin_after_agent_response 'https://acme.example.com' 'token' 5 'session-1' '/repo' '' '' '' ''" "nothing to record"

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

test_case "pn_plugin_after_tool_call: forwards ToolName/Input so control-server can detect a Shell git command"
# Folded in from the retired pn_plugin_after_shell_execution -- see
# design-ideas/Shell_Execution_vs_Tool_Call_Hook_Coverage_Validation.md.
captured_body_file4="$TEST_TEMP_DIR/captured-after-toolcall-shell-body.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file4"
  echo ""
  echo "204"
}
pn_plugin_after_tool_call "https://acme.example.com" "token" 5 "session-1" "/repo" "github.com/org/repo" "main" \
  "toolu_plugin_shell" "[main abc1234] x" "false" "gen-1" "Shell" '{"command":"git commit -m x"}'
assert_output_equals "\"\$JQ_BIN\" -r '.ToolName' '$captured_body_file4'" "Shell" "ToolName encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Input.command' '$captured_body_file4'" "git commit -m x" "Input (raw tool_input JSON) encoded correctly"

test_case "pn_plugin_after_tool_call: tool_name/input omitted -> ToolName empty, Input empty string"
captured_body_file5="$TEST_TEMP_DIR/captured-after-toolcall-no-tool-body.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file5"
  echo ""
  echo "204"
}
pn_plugin_after_tool_call "https://acme.example.com" "token" 5 "session-1" "" "" "" "toolu_plugin_mcp" "ok" "false"
assert_output_equals "\"\$JQ_BIN\" -r '.ToolName' '$captured_body_file5'" "" "ToolName defaults to empty for a non-Shell caller that never passes it"
assert_output_equals "\"\$JQ_BIN\" -r '.Input' '$captured_body_file5'" "" "Input defaults to an empty string, not null"

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
