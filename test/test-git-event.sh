#!/bin/bash
# Unit + integration tests for the generic git-event detection surface:
# lib/git-utils.sh's new resolvers, lib/detection-client.sh, and
# check-git-event.sh (design-ideas/Cursor_PrePush_Governance_Enforcement_Plan.md,
# section 0.5).

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-utils.sh"

test_init
source_scripts

echo -e "${BLUE}=== Unit Tests: lib/git-utils.sh (git-event resolvers) ===${NC}"

test_case "get_remote_url_or_empty: no remote configured -> empty"
repo=$(make_test_git_repo "no-remote")
assert_output_equals "get_remote_url_or_empty '$repo'" "" "empty string, not 'No remote'"

test_case "get_current_branch_or_empty: on a named branch -> branch name"
assert_output_equals "get_current_branch_or_empty '$repo'" "main" "returns 'main'"

test_case "resolve_unpushed_changed_files: no remote at all -> every committed file"
assert_output_equals "resolve_unpushed_changed_files '$repo'" "README.md" "lists the one committed file"

test_case "resolve_staged_changed_files: nothing staged -> empty"
assert_output_equals "resolve_staged_changed_files '$repo'" "" "no output"

test_case "resolve_staged_changed_files: one new staged file -> just that file"
echo "new" > "$repo/new.txt"
git -C "$repo" add new.txt
assert_output_equals "resolve_staged_changed_files '$repo'" "new.txt" "only the staged file, not unstaged changes"

test_case "resolve_staged_changed_files: excludes staged deletions"
git -C "$repo" commit -q -m "add new.txt"
git -C "$repo" rm -q --cached new.txt
assert_output_equals "resolve_staged_changed_files '$repo'" "" "a staged deletion is not scanned"
git -C "$repo" reset -q --hard HEAD >/dev/null 2>&1

test_case "resolve_pr_create_changed_files: falls back to resolve_unpushed_changed_files with no remote-tracking info"
result=$(resolve_pr_create_changed_files "$repo" "gh pr create")
assert_output_equals "echo \"\$result\"" "$(resolve_unpushed_changed_files "$repo")" "matches the unpushed-files fallback"

# The scenario resolve_unpushed_changed_files gets wrong on its own: a
# branch already pushed before `gh pr create` runs, where "not reachable
# from any remote" finds nothing even though the PR's diff is real.
test_case "resolve_pr_create_changed_files: correct after the feature branch was already pushed"
remote_dir="$TEST_TEMP_DIR/remote.git"
git init -q --bare "$remote_dir"
work_repo=$(make_test_git_repo "pr-flow")
git -C "$work_repo" remote add origin "$remote_dir"
git -C "$work_repo" push -q -u origin main
git -C "$work_repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$work_repo" checkout -q -b feature
echo "feature work" > "$work_repo/feature.txt"
git -C "$work_repo" add feature.txt
git -C "$work_repo" commit -q -m "feature work"
git -C "$work_repo" push -q -u origin feature

assert_output_equals "resolve_unpushed_changed_files '$work_repo'" "" "sanity check: the naive comparison finds nothing once pushed"
assert_output_equals "resolve_pr_create_changed_files '$work_repo' 'gh pr create --title x --body y'" "feature.txt" "correctly diffs against the default branch instead"

test_case "resolve_pr_create_changed_files: honors an explicit --base flag"
git -C "$work_repo" branch -q release main
assert_output_equals "resolve_pr_create_changed_files '$work_repo' 'gh pr create --base release'" "feature.txt" "diffs against the named base branch"

echo -e "${BLUE}=== Unit Tests: lib/detection-client.sh ===${NC}"

test_case "is_binary_file: plain text file -> false"
text_file="$TEST_TEMP_DIR/plain.txt"
printf 'hello\nworld\n' > "$text_file"
assert_failure "is_binary_file '$text_file'" "reports false (assert_failure = non-zero/false return)"

test_case "is_binary_file: file containing a NUL byte -> true"
bin_file="$TEST_TEMP_DIR/binary.bin"
printf 'abc\000def' > "$bin_file"
assert_success "is_binary_file '$bin_file'" "reports true (assert_success = zero/true return)"

# pn_evaluate_detection bundles its own HTTP call (mirroring how check-
# write.sh's inline curl/status handling is not separately unit-tested
# either -- only its response-body classifier, pn_parse_messages_response,
# is). Overriding http_post_multipart_form here is a deliberate, narrow test
# seam: it lets these cases exercise pn_evaluate_detection's own
# status/response-shape branching without a real network call, while still
# calling pn_evaluate_detection itself (not a copy of its logic).
test_case "pn_evaluate_detection: 2xx + valid JSON -> ok, fields extracted"
http_post_multipart_form() {
  echo '{"Decision":"warn","Message":"a finding","AuditId":"scan-123"}'
  echo "200"
}
pn_evaluate_detection "https://example.invalid/api/v1/detections/evaluate" "tok" "5" \
  "git.push" "cursor-plugin" "/repo" "" "" "" "git push origin main"
assert_output_equals "echo \"\$PN_DETECTION_STATUS\"" "ok" "status is ok"
assert_output_equals "echo \"\$PN_DETECTION_DECISION\"" "warn" "decision extracted"
assert_output_equals "echo \"\$PN_DETECTION_MESSAGE\"" "a finding" "message extracted"
assert_output_equals "echo \"\$PN_DETECTION_AUDIT_ID\"" "scan-123" "audit id extracted"

test_case "pn_evaluate_detection: 2xx + valid JSON but missing Decision -> fails closed to block"
http_post_multipart_form() {
  echo '{"Message":"unexpected shape"}'
  echo "200"
}
pn_evaluate_detection "https://example.invalid/api/v1/detections/evaluate" "tok" "5" \
  "git.push" "cursor-plugin" "/repo" "" "" "" "git push origin main"
assert_output_equals "echo \"\$PN_DETECTION_STATUS\"" "ok" "status is still ok (valid JSON, valid HTTP)"
assert_output_equals "echo \"\$PN_DETECTION_DECISION\"" "block" "an unrecognized shape defaults to block, not allow"

test_case "pn_evaluate_detection: non-2xx status -> http_error"
http_post_multipart_form() {
  echo '{"error":"unauthorized"}'
  echo "401"
}
pn_evaluate_detection "https://example.invalid/api/v1/detections/evaluate" "tok" "5" \
  "git.push" "cursor-plugin" "/repo" "" "" "" "git push origin main"
assert_output_equals "echo \"\$PN_DETECTION_STATUS\"" "http_error" "status is http_error"
assert_output_equals "echo \"\$PN_DETECTION_HTTP_STATUS\"" "401" "http status captured"

test_case "pn_evaluate_detection: invalid JSON body on 2xx -> invalid_json"
http_post_multipart_form() {
  echo 'not json'
  echo "200"
}
pn_evaluate_detection "https://example.invalid/api/v1/detections/evaluate" "tok" "5" \
  "git.push" "cursor-plugin" "/repo" "" "" "" "git push origin main"
assert_output_equals "echo \"\$PN_DETECTION_STATUS\"" "invalid_json" "status is invalid_json"

test_case "pn_evaluate_detection: curl timeout (exit 28) -> timeout"
http_post_multipart_form() { return 28; }
pn_evaluate_detection "https://example.invalid/api/v1/detections/evaluate" "tok" "5" \
  "git.push" "cursor-plugin" "/repo" "" "" "" "git push origin main"
assert_output_equals "echo \"\$PN_DETECTION_STATUS\"" "timeout" "status is timeout"

test_case "pn_evaluate_detection: curl connection failure -> unreachable"
http_post_multipart_form() { return 7; }
pn_evaluate_detection "https://example.invalid/api/v1/detections/evaluate" "tok" "5" \
  "git.push" "cursor-plugin" "/repo" "" "" "" "git push origin main"
assert_output_equals "echo \"\$PN_DETECTION_STATUS\"" "unreachable" "status is unreachable"

unset -f http_post_multipart_form
source "$SCRIPTS_DIR/lib/common.sh"

echo -e "${BLUE}=== Integration Tests: check-git-event.sh ===${NC}"

test_case "check-git-event.sh: empty EventType arg -> allow"
result=$(echo '{}' | "$SCRIPTS_DIR/check-git-event.sh")
assert_json_valid "$result" "Valid JSON"
assert_json_field_equals "$result" "permission" "allow" "permission is allow"

test_case "check-git-event.sh: malformed payload -> allow with message"
result=$(echo 'not json' | "$SCRIPTS_DIR/check-git-event.sh" git.push)
assert_json_field_equals "$result" "permission" "allow" "permission is allow"
assert_json_has_key "$result" "user_message" "has user_message"

test_case "check-git-event.sh: unrecognized EventType -> allow"
git_repo=$(make_test_git_repo "unrecognized-event")
payload=$("$JQ_BIN" -n --arg cwd "$git_repo" --arg command "aws s3 cp x s3://y" '{command: $command, cwd: $cwd}')
result=$(echo "$payload" | "$SCRIPTS_DIR/check-git-event.sh" aws.s3.cp)
assert_json_field_equals "$result" "permission" "allow" "permission is allow (not this hook's remit yet)"

test_case "check-git-event.sh: cwd is not a git repo -> allow"
non_repo="$TEST_TEMP_DIR/not-a-repo"
mkdir -p "$non_repo"
payload=$("$JQ_BIN" -n --arg cwd "$non_repo" --arg command "git push origin main" '{command: $command, cwd: $cwd}')
result=$(echo "$payload" | "$SCRIPTS_DIR/check-git-event.sh" git.push)
assert_json_field_equals "$result" "permission" "allow" "permission is allow"

test_case "check-git-event.sh: git.commit with nothing staged -> allow (nothing to scan)"
commit_repo=$(make_test_git_repo "nothing-staged")
payload=$("$JQ_BIN" -n --arg cwd "$commit_repo" --arg command "git commit -m x" '{command: $command, cwd: $cwd}')
result=$(echo "$payload" | "$SCRIPTS_DIR/check-git-event.sh" git.commit)
assert_json_field_equals "$result" "permission" "allow" "permission is allow"

test_case "check-git-event.sh: git.push not configured, default FAILURE_MODE -> deny"
push_repo=$(make_test_git_repo "not-configured-push")
echo "change" > "$push_repo/change.txt"
git -C "$push_repo" add change.txt
git -C "$push_repo" commit -q -m "change"
payload=$("$JQ_BIN" -n --arg cwd "$push_repo" --arg command "git push origin main" '{command: $command, cwd: $cwd}')
result=$(echo "$payload" | "$SCRIPTS_DIR/check-git-event.sh" git.push)
assert_json_field_equals "$result" "permission" "deny" "permission is deny (fail-closed default, matching check-write.sh)"
assert_json_has_key "$result" "agent_message" "has agent_message"

test_case "check-git-event.sh: git.push not configured, FAILURE_MODE=open -> allow"
result=$(PARADIGM_NETWORKS_FAILURE_MODE=open bash -c "echo '$payload' | '$SCRIPTS_DIR/check-git-event.sh' git.push")
assert_json_field_equals "$result" "permission" "allow" "permission is allow"
assert_json_has_key "$result" "user_message" "has user_message"

test_summary
exit $?
