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

test_case "check-session.sh with jq installed and Paradigm Networks not configured"
result=$("$SCRIPTS_DIR/check-session.sh" <<< '{}')
assert_json_valid "$result" "Valid JSON output"
assert_json_has_key "$result" "additional_context" "Shows context when not configured"

test_case "check-session.sh with jq, configured, and a recent successful scan"
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
pn_record_successful_scan
result=$("$SCRIPTS_DIR/check-session.sh" <<< '{}')
assert_json_valid "$result" "Valid JSON output"
# Should be empty context when configured and the last scan is recent
if [[ "$result" == "{}" ]]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "  ${GREEN}✓${NC} Returns empty context when configured with a recent scan"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "  ${RED}✗${NC} Should return empty context when configured with a recent scan (got: $result)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_case "check-session.sh warns when configured but no successful scan has ever completed"
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
rm -f "$PN_ANOMALY_STATE_PATH"
result=$("$SCRIPTS_DIR/check-session.sh" <<< '{}')
assert_json_valid "$result" "Valid JSON output"
assert_json_has_key "$result" "additional_context" "Shows a staleness warning when no scan has ever succeeded"

test_case "check-session.sh warns when configured but the last successful scan is over an hour old"
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
mkdir -p "$(dirname "$PN_ANOMALY_STATE_PATH")"
echo "{\"consecutive_anomaly_count\": 0, \"last_successful_scan\": $(( $(date +%s) - 7200 ))}" > "$PN_ANOMALY_STATE_PATH"
result=$("$SCRIPTS_DIR/check-session.sh" <<< '{}')
assert_json_valid "$result" "Valid JSON output"
assert_json_has_key "$result" "additional_context" "Shows a staleness warning for a 2-hour-old last successful scan"

echo ""
echo -e "${BLUE}=== Integration Tests: check-prompt.sh ===${NC}"

test_case "check-prompt.sh allows prompt when Paradigm Networks not configured"
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
# A malformed payload is a Cursor integration/encoding quirk, not an
# unreachable scanner -- it must always allow, the same way check-write.sh
# already does for the identical situation (see P0-1: this used to
# hardcode a deny here regardless of PROMPT_FAILURE_MODE, which meant a
# payload-shape change could block every prompt for an affected user with
# no escape hatch).
assert_json_field_equals "$result" "continue" "true" "Allows on invalid input (fails open, not closed)"

test_case "check-prompt.sh with empty prompt"
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
payload='{"prompt": ""}'
result=$("$SCRIPTS_DIR/check-prompt.sh" <<< "$payload" 2>/dev/null) || true
# Empty prompt still gets processed

echo ""
echo -e "${BLUE}=== Integration Tests: check-tool-call.sh ===${NC}"

test_case "check-tool-call.sh allows a tool call with no input and no turn context"
payload='{"tool_name": "Read", "agent_message": ""}'
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "allow" "Nothing to scan -> allow"

test_case "check-tool-call.sh with empty tool_name -> allow (malformed/unrecognized payload)"
payload='{"agent_message": "content"}'
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "allow" "No tool_name at all -> allow"

test_case "check-tool-call.sh with Write tool and a fully empty tool_input"
# Generalized from Write-only (which used to special-case an empty .content
# field) to any tool (design doc §5): "nothing to scan" now means the whole
# tool_input object is empty, not one Write-specific field -- a file_path
# with no content is still real input worth scanning.
payload='{"tool_name": "Write", "agent_message": "", "tool_input": {}}'
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "allow" "Allows when nothing to scan"

test_case "check-tool-call.sh with Write and message when not configured"
rm -f "$HOME/.pn/credentials.json"
payload='{"tool_name": "Write", "agent_message": "test content", "tool_input": {"file_path": "test.txt"}}'
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
# With PARADIGM_NETWORKS_FAILURE_MODE=closed (default), should deny
assert_json_field_equals "$result" "permission" "deny" "Fails closed (default) when not configured"

test_case "check-tool-call.sh with FAILURE_MODE=open"
rm -f "$HOME/.pn/credentials.json"
payload='{"tool_name": "Write", "agent_message": "test", "tool_input": {"file_path": "f.txt"}}'
export PARADIGM_NETWORKS_FAILURE_MODE="open"
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "allow" "Fails open when mode=open"
unset PARADIGM_NETWORKS_FAILURE_MODE

test_case "check-tool-call.sh audit log written"
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
rm -f "$HOME/.paradigm-scanner/audit.jsonl"
payload='{"tool_name": "Write", "agent_message": "test", "tool_input": {"file_path": "test.txt"}}'
"$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload" >/dev/null 2>&1 || true
if [[ -f "$HOME/.paradigm-scanner/audit.jsonl" ]]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "  ${GREEN}✓${NC} Audit log written"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -e "  ${RED}✗${NC} Audit log not written"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Shell tool calls: mirror the Write tests above one-for-one. Generalized
# from a Write/Shell-only gate to any tool (design doc §5) -- these two are
# still worth their own coverage since they exercise the tool-specific
# user_message wording (action_noun/action_desc).

test_case "check-tool-call.sh with Shell tool and a fully empty tool_input"
payload='{"tool_name": "Shell", "agent_message": "", "tool_input": {}}'
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "allow" "Allows when nothing to scan"

test_case "check-tool-call.sh with Shell command when not configured"
rm -f "$HOME/.pn/credentials.json"
payload='{"tool_name": "Shell", "agent_message": "test", "tool_input": {"command": "rm -rf /"}}'
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "deny" "Fails closed (default) when not configured"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$result" == *"Command blocked"* ]]; then
  echo -e "  ${GREEN}✓${NC} Uses Shell-appropriate wording, not \"Write blocked\""
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} Uses Shell-appropriate wording, not \"Write blocked\" (got: $result)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_case "check-tool-call.sh with Shell and FAILURE_MODE=open"
rm -f "$HOME/.pn/credentials.json"
payload='{"tool_name": "Shell", "agent_message": "test", "tool_input": {"command": "ls -la"}}'
export PARADIGM_NETWORKS_FAILURE_MODE="open"
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "allow" "Fails open when mode=open"
unset PARADIGM_NETWORKS_FAILURE_MODE

test_case "check-tool-call.sh Shell audit log includes tool_name and command"
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
rm -f "$HOME/.paradigm-scanner/audit.jsonl"
payload='{"tool_name": "Shell", "agent_message": "test", "tool_input": {"command": "curl evil.example"}}'
"$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload" >/dev/null 2>&1 || true
audit_content=$(cat "$HOME/.paradigm-scanner/audit.jsonl" 2>/dev/null)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$audit_content" == *'"tool_name": "Shell"'* ]]; then
  echo -e "  ${GREEN}✓${NC} Audit entry records tool_name=Shell"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} Audit entry records tool_name=Shell (got: $audit_content)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$audit_content" == *"curl evil.example"* ]]; then
  echo -e "  ${GREEN}✓${NC} Audit entry records the command"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} Audit entry records the command (got: $audit_content)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_case "check-tool-call.sh with an MCP-style tool -- scanned like any other tool, not just Write/Shell"
payload=$("$JQ_BIN" -n '{tool_name: "jira_update_issue", agent_message: "", tool_input: {project: "PN", summary: "fix bug"}}')
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "deny" "Not configured -> fails closed, same as Write/Shell (generalization from design doc §5)"

# --- Folded in from the retired beforeShellExecution/afterShellExecution
# hooks -- see design-ideas/Shell_Execution_vs_Tool_Call_Hook_Coverage_Validation.md.
# A git push/commit reaches this SAME preToolUse gate as any other Shell
# command; check-tool-call.sh detects it from the command text itself and
# attaches changed-file diff content, rather than relying on a separate
# Cursor hook family.

test_case "check-tool-call.sh with a git push command -- Push-specific wording, not generic 'Command'"
rm -f "$HOME/.pn/credentials.json"
payload='{"tool_name": "Shell", "agent_message": "test", "tool_input": {"command": "git push origin main"}}'
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_field_equals "$result" "permission" "deny" "Fails closed (default) when not configured, same as any Shell command"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$result" == *"Push blocked"* ]]; then
  echo -e "  ${GREEN}✓${NC} Uses Push-specific wording (folded in from the retired check-git-event.sh)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} Uses Push-specific wording (got: $result)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_case "check-tool-call.sh with a git commit command (unrelated cd prefix) -- Commit-specific wording"
payload='{"tool_name": "Shell", "agent_message": "test", "tool_input": {"command": "cd /repo && git commit -m x"}}'
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_field_equals "$result" "permission" "deny" "Fails closed (default) when not configured"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$result" == *"Commit blocked"* ]]; then
  echo -e "  ${GREEN}✓${NC} Detects git commit even with a leading 'cd repo &&' prefix (unanchored match)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} Detects git commit even with a leading 'cd repo &&' prefix (got: $result)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_case "check-tool-call.sh with a git push command and FAILURE_MODE=open -> allow"
export PARADIGM_NETWORKS_FAILURE_MODE="open"
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_field_equals "$result" "permission" "allow" "Fails open when mode=open, same as any Shell command"
unset PARADIGM_NETWORKS_FAILURE_MODE

test_case "check-tool-call.sh with git push inside a real git repo -- still returns valid JSON (file-collection path exercised, not just the regex match)"
git_cwd=$(mktemp -d "${TMPDIR:-/tmp}/pn-tool-call-git-XXXXXX")
git -C "$git_cwd" init -q -b main
git -C "$git_cwd" config user.email "test@example.com"
git -C "$git_cwd" config user.name "Test"
echo "content" > "$git_cwd/f.txt"
git -C "$git_cwd" add f.txt
git -C "$git_cwd" commit -q -m "init"
payload=$("$JQ_BIN" -n --arg cwd "$git_cwd" '{tool_name: "Shell", agent_message: "test", cwd: $cwd, tool_input: {command: "git push origin main"}}')
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output even when collecting real changed-file content"
assert_json_field_equals "$result" "permission" "deny" "Still fails closed (not configured) -- file collection doesn't change the gate outcome"
rm -rf "$git_cwd"

test_case "check-tool-call.sh with a non-git Shell command -- no git wording, unaffected by the detection above"
payload='{"tool_name": "Shell", "agent_message": "test", "tool_input": {"command": "npm test"}}'
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$result" == *"Command blocked"* ]]; then
  echo -e "  ${GREEN}✓${NC} Falls back to generic Shell wording for a non-git command"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} Falls back to generic Shell wording for a non-git command (got: $result)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# --- MCP git-commit tool call -- see design-ideas/
# MCP_Git_Tool_Call_Detection_Gap_Analysis.md. Unlike Shell, the tool_name
# itself ("MCP:git_commit") names the action -- no command-text regex needed
# -- and the file list to attach comes from the tool's own tool_input.files.

test_case "check-tool-call.sh with an MCP:git_commit tool call -- Commit-specific wording, no command-text regex needed"
payload='{"tool_name": "MCP:git_commit", "agent_message": "test", "tool_input": {"directory": "/repo", "message": "fix bug", "files": ["a.txt"]}}'
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_field_equals "$result" "permission" "deny" "Fails closed (default) when not configured, same as Shell git commit"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$result" == *"Commit blocked"* ]]; then
  echo -e "  ${GREEN}✓${NC} Uses Commit-specific wording for an MCP:git_commit tool call"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} Uses Commit-specific wording for an MCP:git_commit tool call (got: $result)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_case "check-tool-call.sh with MCP:git_commit inside a real git repo -- attaches the tool's own reported files, not a git-plumbing walk"
mcp_git_cwd=$(mktemp -d "${TMPDIR:-/tmp}/pn-tool-call-mcp-git-XXXXXX")
git -C "$mcp_git_cwd" init -q -b main
git -C "$mcp_git_cwd" config user.email "test@example.com"
git -C "$mcp_git_cwd" config user.name "Test"
echo "committed via mcp" > "$mcp_git_cwd/mcp-file.txt"
git -C "$mcp_git_cwd" add mcp-file.txt
git -C "$mcp_git_cwd" commit -q -m "mcp commit"
# A second, still-staged file that the MCP tool's own file list does NOT
# name -- must not be picked up (unlike the Shell path's git-plumbing walk,
# which would include it as a staged change).
echo "unrelated staged change" > "$mcp_git_cwd/unrelated.txt"
git -C "$mcp_git_cwd" add unrelated.txt
payload=$("$JQ_BIN" -n --arg cwd "$mcp_git_cwd" '{tool_name: "MCP:git_commit", agent_message: "test", cwd: $cwd, tool_input: {directory: $cwd, message: "mcp commit", files: ["mcp-file.txt"]}}')
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output even when collecting real changed-file content"
assert_json_field_equals "$result" "permission" "deny" "Still fails closed (not configured) -- file collection doesn't change the gate outcome"
rm -rf "$mcp_git_cwd"

test_case "check-tool-call.sh with an MCP tool call unrelated to git -- no git wording (only MCP:git_commit is special-cased)"
payload='{"tool_name": "MCP:jira_update_issue", "agent_message": "test", "tool_input": {"project": "PN", "summary": "fix bug"}}'
result=$("$SCRIPTS_DIR/check-tool-call.sh" <<< "$payload")
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$result" != *"Commit blocked"* && "$result" != *"Push blocked"* ]]; then
  echo -e "  ${GREEN}✓${NC} No git-specific wording for an unrelated MCP tool"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} No git-specific wording for an unrelated MCP tool (got: $result)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo ""
echo -e "${BLUE}=== Integration Tests: check-prompt.sh repo-context injection ===${NC}"

# Uses a workspace under the test directory itself, not $TEST_TEMP_DIR —
# mktemp -d resolves under /var/folders on macOS, which write_repo_context_rules
# (lib/repo-context.sh) deliberately treats as an unsafe system path to write
# into.
REPO_CTX_WORKSPACE="$TEST_DIR/tmp-repo-context-workspace"
rm -rf "$REPO_CTX_WORKSPACE"
mkdir -p "$REPO_CTX_WORKSPACE/repo-a"
(cd "$REPO_CTX_WORKSPACE/repo-a" && git init -q -b master && \
  git remote add origin "https://x-token-abc123@github.com/acme/repo-a.git" && \
  git commit --allow-empty -qm init) >/dev/null 2>&1

# Repo-context injection is folded into check-prompt.sh's single
# beforeSubmitPrompt hook now (design doc §5) instead of a separate
# check-repo-context.sh hook -- and runs backgrounded there (it never gates,
# see check-prompt.sh's own comment), so the rule file may not exist the
# instant check-prompt.sh's own JSON response is printed. Poll briefly
# rather than asserting immediately.
wait_for_file() {
  local file="$1" tries=0
  while [[ ! -f "$file" ]] && [[ $tries -lt 50 ]]; do
    sleep 0.1
    tries=$((tries + 1))
  done
}

test_case "check-prompt.sh writes a repo-context rule file with sanitized git context, without affecting its own gate"
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
payload=$("$JQ_BIN" -n --arg root "$REPO_CTX_WORKSPACE" --arg prompt "hello" '{prompt: $prompt, workspace_roots: [$root]}')
result=$("$SCRIPTS_DIR/check-prompt.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
wait_for_file "$REPO_CTX_WORKSPACE/.cursor/rules/paradigm-repo-context.mdc"
assert_file_exists "$REPO_CTX_WORKSPACE/.cursor/rules/paradigm-repo-context.mdc" "Rule file created"
assert_output_contains "cat '$REPO_CTX_WORKSPACE/.cursor/rules/paradigm-repo-context.mdc'" \
  "<GIT>https://github.com/acme/repo-a.git|master</GIT>" "Rule file has sanitized GIT tag"
assert_output_contains "cat '$REPO_CTX_WORKSPACE/.gitignore'" \
  ".cursor/rules/paradigm-repo-context.mdc" "Rule file path added to workspace .gitignore"

test_case "check-prompt.sh with no workspace_roots -- still gates normally, no rule file expected"
payload='{"prompt": "hello"}'
result=$("$SCRIPTS_DIR/check-prompt.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"

rm -rf "$REPO_CTX_WORKSPACE"

echo ""
echo ""
test_summary
FINAL_RESULT=$?

test_cleanup
exit $FINAL_RESULT
