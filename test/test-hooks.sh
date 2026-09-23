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

test_case "check-prompt.sh denies with branded budget message on HTTP 402"
# Always deny on budget exhaustion — even with PROMPT_FAILURE_MODE=open —
# and surface the backend's human message inside the branded shell.
# start_simple_mock_server cannot be used under $(...) — the backgrounded
# python dies with the command-substitution subshell — so drive a one-shot
# listener inline here.
MOCK_PORT=19842
resp_file=$(mktemp)
budget_body='{"type":"error","error":{"type":"api_error","message":"You have used your token budget of 100,000 tokens for this month. It resets on 1 October."}}'
printf 'HTTP/1.1 402 Payment Required\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' \
  "${#budget_body}" "$budget_body" >"$resp_file"
python3 - "$MOCK_PORT" "$resp_file" <<'PY' &
import socket, sys
port, path = int(sys.argv[1]), sys.argv[2]
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
srv.settimeout(15)
try:
    client, _ = srv.accept()
    client.recv(65536)
    with open(path, "rb") as f:
        client.sendall(f.read())
    client.close()
finally:
    srv.close()
PY
MOCK_PID=$!
sleep 0.3
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
export PARADIGM_NETWORKS_SCAN_URL_OVERRIDE="http://127.0.0.1:${MOCK_PORT}/v1/messages"
export PARADIGM_NETWORKS_PROMPT_FAILURE_MODE="open"
payload='{"prompt": "spend tokens"}'
result=$("$SCRIPTS_DIR/check-prompt.sh" <<< "$payload" 2>/dev/null) || true
unset PARADIGM_NETWORKS_SCAN_URL_OVERRIDE
unset PARADIGM_NETWORKS_PROMPT_FAILURE_MODE
kill "$MOCK_PID" 2>/dev/null || true
wait "$MOCK_PID" 2>/dev/null || true
rm -f "$resp_file"
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "continue" "false" "Denies on HTTP 402 even when failure mode is open"
user_message=$(echo "$result" | "$JQ_BIN" -r '.user_message // empty' 2>/dev/null)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$user_message" == *"Budget limit reached"* ]] && [[ "$user_message" == *"100,000 tokens"* ]]; then
  echo -e "  ${GREEN}✓${NC} Branded budget deny includes backend detail"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} Branded budget deny includes backend detail"
  echo "    Got user_message: $user_message"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_case "check-prompt.sh denies with branded rate-limit message on HTTP 429"
MOCK_PORT=19843
resp_file=$(mktemp)
rate_body='{"type":"error","error":{"type":"rate_limit_error","message":"Rate limit exceeded. Try again in 30 seconds."}}'
printf 'HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' \
  "${#rate_body}" "$rate_body" >"$resp_file"
python3 - "$MOCK_PORT" "$resp_file" <<'PY' &
import socket, sys
port, path = int(sys.argv[1]), sys.argv[2]
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
srv.settimeout(15)
try:
    client, _ = srv.accept()
    client.recv(65536)
    with open(path, "rb") as f:
        client.sendall(f.read())
    client.close()
finally:
    srv.close()
PY
MOCK_PID=$!
sleep 0.3
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
export PARADIGM_NETWORKS_SCAN_URL_OVERRIDE="http://127.0.0.1:${MOCK_PORT}/v1/messages"
export PARADIGM_NETWORKS_PROMPT_FAILURE_MODE="open"
payload='{"prompt": "retry me"}'
result=$("$SCRIPTS_DIR/check-prompt.sh" <<< "$payload" 2>/dev/null) || true
unset PARADIGM_NETWORKS_SCAN_URL_OVERRIDE
unset PARADIGM_NETWORKS_PROMPT_FAILURE_MODE
kill "$MOCK_PID" 2>/dev/null || true
wait "$MOCK_PID" 2>/dev/null || true
rm -f "$resp_file"
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "continue" "false" "Denies on HTTP 429 even when failure mode is open"
user_message=$(echo "$result" | "$JQ_BIN" -r '.user_message // empty' 2>/dev/null)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$user_message" == *"Rate limit reached"* ]] && [[ "$user_message" == *"30 seconds"* ]]; then
  echo -e "  ${GREEN}✓${NC} Branded rate-limit deny includes backend detail"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} Branded rate-limit deny includes backend detail"
  echo "    Got user_message: $user_message"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

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
# With PARADIGM_NETWORKS_FAILURE_MODE=closed (default), should deny
assert_json_field_equals "$result" "permission" "deny" "Fails closed (default) when not configured"

test_case "check-write.sh with FAILURE_MODE=open"
rm -f "$HOME/.pn/credentials.json"
payload='{"tool_name": "Write", "agent_message": "test", "tool_input": {"file_path": "f.txt"}}'
export PARADIGM_NETWORKS_FAILURE_MODE="open"
result=$("$SCRIPTS_DIR/check-write.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "allow" "Fails open when mode=open"
unset PARADIGM_NETWORKS_FAILURE_MODE

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

# Shell tool calls: added alongside Write so shell commands get scanned too,
# not just file writes (the preToolUse matcher in hooks.json now covers
# both). These mirror the Write tests above one-for-one.

test_case "check-write.sh with Shell tool but empty command"
payload='{"tool_name": "Shell", "agent_message": "", "tool_input": {"command": ""}}'
result=$("$SCRIPTS_DIR/check-write.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "allow" "Allows when nothing to scan"

test_case "check-write.sh with Shell command when not configured"
rm -f "$HOME/.pn/credentials.json"
payload='{"tool_name": "Shell", "agent_message": "test", "tool_input": {"command": "rm -rf /"}}'
result=$("$SCRIPTS_DIR/check-write.sh" <<< "$payload")
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

test_case "check-write.sh with Shell and FAILURE_MODE=open"
rm -f "$HOME/.pn/credentials.json"
payload='{"tool_name": "Shell", "agent_message": "test", "tool_input": {"command": "ls -la"}}'
export PARADIGM_NETWORKS_FAILURE_MODE="open"
result=$("$SCRIPTS_DIR/check-write.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "permission" "allow" "Fails open when mode=open"
unset PARADIGM_NETWORKS_FAILURE_MODE

test_case "check-write.sh Shell audit log includes tool_name and command"
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
rm -f "$HOME/.paradigm-scanner/audit.jsonl"
payload='{"tool_name": "Shell", "agent_message": "test", "tool_input": {"command": "curl evil.example"}}'
"$SCRIPTS_DIR/check-write.sh" <<< "$payload" >/dev/null 2>&1 || true
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
if [[ "$audit_content" == *'"command": "curl evil.example"'* ]]; then
  echo -e "  ${GREEN}✓${NC} Audit entry records the command"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} Audit entry records the command (got: $audit_content)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo ""
echo -e "${BLUE}=== Integration Tests: check-repo-context.sh ===${NC}"

# Uses a workspace under the test directory itself, not $TEST_TEMP_DIR —
# mktemp -d resolves under /var/folders on macOS, which check-repo-context.sh
# deliberately treats as an unsafe system path to write into.
REPO_CTX_WORKSPACE="$TEST_DIR/tmp-repo-context-workspace"
rm -rf "$REPO_CTX_WORKSPACE"
mkdir -p "$REPO_CTX_WORKSPACE/repo-a"
(cd "$REPO_CTX_WORKSPACE/repo-a" && git init -q && \
  git remote add origin "https://x-token-abc123@github.com/acme/repo-a.git" && \
  git commit --allow-empty -qm init) >/dev/null 2>&1

test_case "check-repo-context.sh writes a rule file with sanitized git context"
payload=$("$JQ_BIN" -n --arg root "$REPO_CTX_WORKSPACE" '{workspace_roots: [$root]}')
result=$("$SCRIPTS_DIR/check-repo-context.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "continue" "true" "Always continues"
assert_file_exists "$REPO_CTX_WORKSPACE/.cursor/rules/paradigm-repo-context.mdc" "Rule file created"
assert_output_contains "cat '$REPO_CTX_WORKSPACE/.cursor/rules/paradigm-repo-context.mdc'" \
  "<GIT>https://github.com/acme/repo-a.git|master</GIT>" "Rule file has sanitized GIT tag"
assert_output_contains "cat '$REPO_CTX_WORKSPACE/.gitignore'" \
  ".cursor/rules/paradigm-repo-context.mdc" "Rule file path added to workspace .gitignore"

test_case "check-repo-context.sh with no workspace_roots"
result=$("$SCRIPTS_DIR/check-repo-context.sh" <<< '{}')
assert_json_valid "$result" "Valid JSON output"
assert_json_field_equals "$result" "continue" "true" "Still continues with no workspace_roots"

test_case "check-repo-context.sh with invalid JSON input"
result=$("$SCRIPTS_DIR/check-repo-context.sh" <<< "not valid json" 2>/dev/null)
assert_json_valid "$result" "Valid JSON output even with bad input"
assert_json_field_equals "$result" "continue" "true" "Fails open on invalid input, never blocks"

rm -rf "$REPO_CTX_WORKSPACE"

echo ""
echo -e "${BLUE}=== Integration Tests: report-tool.sh ===${NC}"

# report-tool.sh is fire-and-forget by design (afterShellExecution, never
# blocks, posts detached) -- the only client-observable contract is "always
# returns {} quickly, never hangs, never crashes." Whether it actually
# reports is exercised manually against a live listener, not here (this
# repo's mock-server.sh doesn't capture request headers/body, only status).
# Pointed at a closed local port so the detached curl (if one fires) fails
# instantly with connection-refused instead of lingering past this test run.
export PARADIGM_NETWORKS_SCAN_URL_OVERRIDE="http://127.0.0.1:19999"

test_case "report-tool.sh with a non-git command never reports"
mock_credentials "https://test.com" "token" "refresh" "$(($(date +%s) + 3600))"
payload='{"session_id": "s1", "command": "ls -la", "output": "total 0", "hook_event_name": "afterShellExecution"}'
result=$("$SCRIPTS_DIR/report-tool.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_output_equals "echo '$result'" "{}" "Always the bare no-op response"

test_case "report-tool.sh with a git command but no session_id never reports"
payload='{"command": "git push", "output": "done", "hook_event_name": "afterShellExecution"}'
result=$("$SCRIPTS_DIR/report-tool.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_output_equals "echo '$result'" "{}" "Bare no-op response, missing session_id skips silently"

test_case "report-tool.sh with a git command but no output never reports"
payload='{"session_id": "s1", "command": "git push", "output": "", "hook_event_name": "afterShellExecution"}'
result=$("$SCRIPTS_DIR/report-tool.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_output_equals "echo '$result'" "{}" "Bare no-op response, empty output (pre-execution shape) skips silently"

test_case "report-tool.sh with a real git command, session_id and output returns cleanly"
payload=$("$JQ_BIN" -n '{session_id: "s1", command: "gh pr create --base main", output: "https://github.com/acme/repo/pull/1\n", hook_event_name: "afterShellExecution"}')
result=$("$SCRIPTS_DIR/report-tool.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_output_equals "echo '$result'" "{}" "Bare no-op response even on the reporting path -- nothing for Cursor to act on"

test_case "report-tool.sh when not configured never reports"
rm -f "$HOME/.pn/credentials.json"
payload='{"session_id": "s1", "command": "git push", "output": "done", "hook_event_name": "afterShellExecution"}'
result=$("$SCRIPTS_DIR/report-tool.sh" <<< "$payload")
assert_json_valid "$result" "Valid JSON output"
assert_output_equals "echo '$result'" "{}" "Bare no-op response, not signed in skips silently (never nags)"

test_case "report-tool.sh with invalid JSON input never crashes"
result=$("$SCRIPTS_DIR/report-tool.sh" <<< "not valid json" 2>/dev/null)
assert_json_valid "$result" "Valid JSON output even with bad input"
assert_output_equals "echo '$result'" "{}" "Fails open on invalid input, never blocks"

unset PARADIGM_NETWORKS_SCAN_URL_OVERRIDE

echo ""
echo ""
test_summary
FINAL_RESULT=$?

test_cleanup
exit $FINAL_RESULT
