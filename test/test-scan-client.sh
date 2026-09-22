#!/bin/bash
# Unit tests for lib/plugins-client.sh's gating functions --
# pn_plugin_before_prompt (POST .../sessions/{id}/prompts, Action=before_prompt)
# and pn_plugin_before_tool_call (POST .../sessions/{id}/tool-calls,
# Action=before_tool_call) -- which together replaced lib/scan-client.sh's
# single pn_scan_text (the composite PromptGuard+PolicyEngine+CodeDefense
# scan, now split across the standardized domain endpoints). See
# design-ideas/Plugin_API_Standardization_And_Hook_Consolidation_Design.md.

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-utils.sh"

test_init
source_scripts

echo -e "${BLUE}=== Unit Tests: lib/plugins-client.sh (prompts + tool-calls gating) ===${NC}"

# --- pn_plugin_before_prompt ---

test_case "pn_plugin_before_prompt: 2xx + action_to_take=allow -> Status=ok, Action=allow"
http_post_json() {
  echo '{"action_to_take":"allow","message":"","overall_threat_level":"none"}'
  echo "200"
}
pn_plugin_before_prompt "https://acme.example.com" "token" 5 "session-1" "/repo" "github.com/org/repo" "main" "hello world"
assert_output_equals "echo \"\$PN_PROMPT_STATUS\"" "ok" "status is ok"
assert_output_equals "echo \"\$PN_PROMPT_ACTION\"" "allow" "action is allow"
assert_output_equals "echo \"\$PN_PROMPT_THREAT_LEVEL\"" "none" "threat level captured"

test_case "pn_plugin_before_prompt: action_to_take=block -> Action=block, Message carries the finding"
http_post_json() {
  echo '{"action_to_take":"block","message":"Detected a hardcoded credential.","overall_threat_level":"high"}'
  echo "200"
}
pn_plugin_before_prompt "https://acme.example.com" "token" 5 "session-1" "/repo" "" "" "some content"
assert_output_equals "echo \"\$PN_PROMPT_ACTION\"" "block" "action is block"
assert_output_equals "echo \"\$PN_PROMPT_MESSAGE\"" "Detected a hardcoded credential." "message carried through"

test_case "pn_plugin_before_prompt: action_to_take=warn -> Action=warn"
http_post_json() {
  echo '{"action_to_take":"warn","message":"Looks like debug code.","overall_threat_level":"low"}'
  echo "200"
}
pn_plugin_before_prompt "https://acme.example.com" "token" 5 "session-1" "/repo" "" "" "some content"
assert_output_equals "echo \"\$PN_PROMPT_ACTION\"" "warn" "action is warn"

test_case "pn_plugin_before_prompt: valid JSON with no action_to_take -> Status=ok, Action empty (anomaly, not guessed)"
http_post_json() {
  echo '{"something_else":true}'
  echo "200"
}
pn_plugin_before_prompt "https://acme.example.com" "token" 5 "session-1" "/repo" "" "" "some content"
assert_output_equals "echo \"\$PN_PROMPT_STATUS\"" "ok" "status is still ok (valid JSON, valid HTTP)"
assert_output_equals "echo \"\$PN_PROMPT_ACTION\"" "" "action is empty, not guessed as allow or block"

test_case "pn_plugin_before_prompt: HTTP 500 -> Status=http_error, HttpStatus captured"
http_post_json() {
  echo '{"error":"internal"}'
  echo "500"
}
pn_plugin_before_prompt "https://acme.example.com" "token" 5 "session-1" "/repo" "" "" "some content"
assert_output_equals "echo \"\$PN_PROMPT_STATUS\"" "http_error" "status is http_error"
assert_output_equals "echo \"\$PN_PROMPT_HTTP_STATUS\"" "500" "http status captured"

test_case "pn_plugin_before_prompt: invalid JSON body -> Status=invalid_json"
http_post_json() {
  echo 'not json at all'
  echo "200"
}
pn_plugin_before_prompt "https://acme.example.com" "token" 5 "session-1" "/repo" "" "" "some content"
assert_output_equals "echo \"\$PN_PROMPT_STATUS\"" "invalid_json" "status is invalid_json"

test_case "pn_plugin_before_prompt: curl timeout (exit 28) -> Status=timeout"
http_post_json() { return 28; }
pn_plugin_before_prompt "https://acme.example.com" "token" 5 "session-1" "/repo" "" "" "some content"
assert_output_equals "echo \"\$PN_PROMPT_STATUS\"" "timeout" "status is timeout"

test_case "pn_plugin_before_prompt: curl connection failure (exit 7) -> Status=unreachable"
http_post_json() { return 7; }
pn_plugin_before_prompt "https://acme.example.com" "token" 5 "session-1" "/repo" "" "" "some content"
assert_output_equals "echo \"\$PN_PROMPT_STATUS\"" "unreachable" "status is unreachable"

test_case "pn_plugin_before_prompt: empty session id -> Status=no_session, no call attempted"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
pn_plugin_before_prompt "https://acme.example.com" "token" 5 "" "/repo" "" "" "some content"
assert_output_equals "echo \"\$PN_PROMPT_STATUS\"" "no_session" "status is no_session"

# http_post_json is invoked as raw=$(http_post_json ...) inside
# pn_plugin_before_prompt -- a genuine subshell -- so a variable assignment
# from inside this mock cannot cross back out to this script (same reason
# this codebase's real multi-value returns use globals set by a
# plain-statement call, never $(...): see CLAUDE.md). A file write survives
# the subshell boundary, unlike a variable assignment.
test_case "pn_plugin_before_prompt: posts to the standardized prompts endpoint with Action/Text/Cwd/GitRepoUrl/GitBranch"
captured_url_file="$TEST_TEMP_DIR/captured-prompt-url.txt"
captured_body_file="$TEST_TEMP_DIR/captured-prompt-body.json"
http_post_json() {
  echo -n "$1" > "$captured_url_file"
  echo -n "$2" > "$captured_body_file"
  echo '{"action_to_take":"allow"}'
  echo "200"
}
pn_plugin_before_prompt "https://acme.example.com/" "token" 5 "session-1" "/repo" "github.com/org/repo" "main" "some content"
assert_output_equals "cat '$captured_url_file'" "https://acme.example.com/api/v1/plugins/sessions/session-1/prompts" "URL built correctly (trailing slash on base_url handled, session id in path)"
assert_output_equals "\"\$JQ_BIN\" -r '.Action' '$captured_body_file'" "before_prompt" "Action encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Text' '$captured_body_file'" "some content" "Text encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Cwd' '$captured_body_file'" "/repo" "Cwd encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.GitRepoUrl' '$captured_body_file'" "github.com/org/repo" "GitRepoUrl encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.GitBranch' '$captured_body_file'" "main" "GitBranch encoded correctly"

test_case "pn_plugin_before_prompt: generation_id/model passed through"
captured_body_file2="$TEST_TEMP_DIR/captured-prompt-body-2.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file2"
  echo '{"action_to_take":"allow"}'
  echo "200"
}
pn_plugin_before_prompt "https://acme.example.com" "token" 5 "session-1" "/repo" "" "" "hello" "gen-abc" "claude-sonnet-4-5"
assert_output_equals "\"\$JQ_BIN\" -r '.GenerationId' '$captured_body_file2'" "gen-abc" "GenerationId encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Model' '$captured_body_file2'" "claude-sonnet-4-5" "Model encoded correctly"

# --- pn_plugin_before_tool_call ---

test_case "pn_plugin_before_tool_call: 2xx + action_to_take=allow -> Status=ok, ToolUseId captured"
http_post_json() {
  echo '{"action_to_take":"allow","ToolUseId":"toolu_plugin_abc"}'
  echo "200"
}
pn_plugin_before_tool_call "https://acme.example.com" "token" 5 "session-1" "/repo" "" "" "Shell" '"ls -la"'
assert_output_equals "echo \"\$PN_TOOLCALL_STATUS\"" "ok" "status is ok"
assert_output_equals "echo \"\$PN_TOOLCALL_ACTION\"" "allow" "action is allow"
assert_output_equals "echo \"\$PN_TOOLCALL_TOOL_USE_ID\"" "toolu_plugin_abc" "server-returned ToolUseId captured when no preferred id was sent"

test_case "pn_plugin_before_tool_call: action_to_take=block"
http_post_json() {
  echo '{"action_to_take":"block","message":"Detected a secret.","ToolUseId":"toolu_plugin_def"}'
  echo "200"
}
pn_plugin_before_tool_call "https://acme.example.com" "token" 5 "session-1" "/repo" "" "" "Write" '"content"'
assert_output_equals "echo \"\$PN_TOOLCALL_ACTION\"" "block" "action is block"
assert_output_equals "echo \"\$PN_TOOLCALL_MESSAGE\"" "Detected a secret." "message carried through"

test_case "pn_plugin_before_tool_call: empty session id -> Status=no_session"
http_post_json() { echo "SHOULD_NOT_BE_CALLED"; }
pn_plugin_before_tool_call "https://acme.example.com" "token" 5 "" "/repo" "" "" "Shell" '"ls"'
assert_output_equals "echo \"\$PN_TOOLCALL_STATUS\"" "no_session" "status is no_session"

test_case "pn_plugin_before_tool_call: posts ToolName/Input/ScanContext/ToolUseId to the tool-calls endpoint"
captured_url_file2="$TEST_TEMP_DIR/captured-toolcall-url.txt"
captured_body_file3="$TEST_TEMP_DIR/captured-toolcall-body.json"
http_post_json() {
  echo -n "$1" > "$captured_url_file2"
  echo -n "$2" > "$captured_body_file3"
  echo '{"action_to_take":"allow","ToolUseId":"cursor-native-id"}'
  echo "200"
}
pn_plugin_before_tool_call "https://acme.example.com/" "token" 5 "session-1" "/repo" "github.com/org/repo" "main" "Shell" '"git branch -r"' "gen-1" "claude-sonnet-4-5" "cursor-native-id" "user asked to list branches"
assert_output_equals "cat '$captured_url_file2'" "https://acme.example.com/api/v1/plugins/sessions/session-1/tool-calls" "URL built correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Action' '$captured_body_file3'" "before_tool_call" "Action encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.ToolName' '$captured_body_file3'" "Shell" "ToolName encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Input' '$captured_body_file3'" "git branch -r" "Input (a plain-text tool call) round-trips through --argjson as the quoted string it was given"
assert_output_equals "\"\$JQ_BIN\" -r '.GenerationId' '$captured_body_file3'" "gen-1" "GenerationId encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.Model' '$captured_body_file3'" "claude-sonnet-4-5" "Model encoded correctly"
assert_output_equals "\"\$JQ_BIN\" -r '.ToolUseId' '$captured_body_file3'" "cursor-native-id" "ToolUseId (Cursor's own id) is sent through, not left for the server to mint"
assert_output_equals "\"\$JQ_BIN\" -r '.ScanContext' '$captured_body_file3'" "user asked to list branches" "ScanContext encoded correctly"

test_case "pn_plugin_before_tool_call: structured MCP-style input encoded as an object, not a string"
captured_body_file4="$TEST_TEMP_DIR/captured-toolcall-body-2.json"
http_post_json() {
  echo -n "$2" > "$captured_body_file4"
  echo '{"action_to_take":"allow"}'
  echo "200"
}
pn_plugin_before_tool_call "https://acme.example.com" "token" 5 "session-1" "" "" "" "jira_update_issue" '{"project":"PN","summary":"fix bug"}'
assert_output_equals "\"\$JQ_BIN\" -r '.Input.project' '$captured_body_file4'" "PN" "structured Input decodes as a real JSON object server-side, not a stringified blob"

test_summary
