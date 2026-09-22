#!/bin/bash
# Unit + integration tests for the git-event detection surface:
# lib/git-utils.sh's resolvers, lib/plugins-client.sh's
# pn_plugin_before_shell_execution (which folded in the retired
# lib/detection-client.sh's pn_evaluate_detection), and check-git-event.sh.
# See design-ideas/Plugin_API_Standardization_And_Hook_Consolidation_Design.md
# §2.1: git.push AND git.commit now both get real enforcement (previously
# only git.push did); git.pr_create is a deliberate pass-through, not scanned.

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

echo -e "${BLUE}=== Unit Tests: lib/plugins-client.sh (before_shell_execution gating) ===${NC}"

test_case "is_binary_file: plain text file -> false"
text_file="$TEST_TEMP_DIR/plain.txt"
printf 'hello\nworld\n' > "$text_file"
assert_failure "is_binary_file '$text_file'" "reports false (assert_failure = non-zero/false return)"

test_case "is_binary_file: file containing a NUL byte -> true"
bin_file="$TEST_TEMP_DIR/binary.bin"
printf 'abc\000def' > "$bin_file"
assert_success "is_binary_file '$bin_file'" "reports true (assert_success = zero/true return)"

# pn_plugin_before_shell_execution bundles its own HTTP call (mirroring how
# check-git-event.sh's inline curl/status handling is not separately unit-
# tested either). Overriding http_post_multipart_form here is a deliberate,
# narrow test seam: it lets these cases exercise the function's own
# status/response-shape branching without a real network call.
test_case "pn_plugin_before_shell_execution: 2xx + valid JSON -> ok, fields extracted"
http_post_multipart_form() {
  echo '{"action_to_take":"warn","message":"a finding"}'
  echo "200"
}
pn_plugin_before_shell_execution "https://example.invalid" "tok" "5" "session-1" \
  "git.push" "cursor-plugin" "/repo" "" "" "" "git push origin main"
assert_output_equals "echo \"\$PN_SHELL_STATUS\"" "ok" "status is ok"
assert_output_equals "echo \"\$PN_SHELL_ACTION\"" "warn" "action extracted"
assert_output_equals "echo \"\$PN_SHELL_MESSAGE\"" "a finding" "message extracted"

test_case "pn_plugin_before_shell_execution: non-2xx status -> http_error"
http_post_multipart_form() {
  echo '{"error":"unauthorized"}'
  echo "401"
}
pn_plugin_before_shell_execution "https://example.invalid" "tok" "5" "session-1" \
  "git.push" "cursor-plugin" "/repo" "" "" "" "git push origin main"
assert_output_equals "echo \"\$PN_SHELL_STATUS\"" "http_error" "status is http_error"
assert_output_equals "echo \"\$PN_SHELL_HTTP_STATUS\"" "401" "http status captured"

test_case "pn_plugin_before_shell_execution: invalid JSON body on 2xx -> invalid_json"
http_post_multipart_form() {
  echo 'not json'
  echo "200"
}
pn_plugin_before_shell_execution "https://example.invalid" "tok" "5" "session-1" \
  "git.push" "cursor-plugin" "/repo" "" "" "" "git push origin main"
assert_output_equals "echo \"\$PN_SHELL_STATUS\"" "invalid_json" "status is invalid_json"

test_case "pn_plugin_before_shell_execution: curl timeout (exit 28) -> timeout"
http_post_multipart_form() { return 28; }
pn_plugin_before_shell_execution "https://example.invalid" "tok" "5" "session-1" \
  "git.push" "cursor-plugin" "/repo" "" "" "" "git push origin main"
assert_output_equals "echo \"\$PN_SHELL_STATUS\"" "timeout" "status is timeout"

test_case "pn_plugin_before_shell_execution: curl connection failure -> unreachable"
http_post_multipart_form() { return 7; }
pn_plugin_before_shell_execution "https://example.invalid" "tok" "5" "session-1" \
  "git.push" "cursor-plugin" "/repo" "" "" "" "git push origin main"
assert_output_equals "echo \"\$PN_SHELL_STATUS\"" "unreachable" "status is unreachable"

test_case "pn_plugin_before_shell_execution: posts Action=before_shell_execution/EventType/Command as multipart form"
captured_args_file="$TEST_TEMP_DIR/captured-before-shell-args.txt"
http_post_multipart_form() {
  shift 3
  printf '%s\n' "$@" > "$captured_args_file"
  echo '{"action_to_take":"allow"}'
  echo "200"
}
pn_plugin_before_shell_execution "https://example.invalid" "tok" "5" "session-1" \
  "git.commit" "cursor-plugin" "/repo" "github.com/org/repo" "main" "" "git commit -m x"
assert_output_contains "cat '$captured_args_file'" "Action=before_shell_execution" "Action encoded correctly"
assert_output_contains "cat '$captured_args_file'" "EventType=git.commit" "EventType encoded correctly"
assert_output_contains "cat '$captured_args_file'" "Command=git commit -m x" "Command encoded correctly"
assert_output_contains "cat '$captured_args_file'" "GitRepoUrl=github.com/org/repo" "GitRepoUrl encoded correctly"

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

test_case "check-git-event.sh: git.pr_create -> allow, short-circuits before any file-collection or network work"
pr_repo=$(make_test_git_repo "pr-create-shortcircuit")
payload=$("$JQ_BIN" -n --arg cwd "$pr_repo" --arg command "gh pr create --title x" '{command: $command, cwd: $cwd}')
result=$(echo "$payload" | "$SCRIPTS_DIR/check-git-event.sh" git.pr_create)
assert_json_field_equals "$result" "permission" "allow" "permission is allow -- git.pr_create is never scanned pre-execution (design doc §2.1)"

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

test_case "check-git-event.sh: no session id on payload -> allow (nothing to scope the call to server-side)"
commit_repo=$(make_test_git_repo "no-session-commit")
echo "staged" > "$commit_repo/staged.txt"
git -C "$commit_repo" add staged.txt
payload=$("$JQ_BIN" -n --arg cwd "$commit_repo" --arg command "git commit -m x" '{command: $command, cwd: $cwd}')
result=$(echo "$payload" | "$SCRIPTS_DIR/check-git-event.sh" git.commit)
assert_json_field_equals "$result" "permission" "allow" "permission is allow"

test_case "check-git-event.sh: git.commit with nothing staged -> allow (nothing to scan)"
nothing_staged_repo=$(make_test_git_repo "nothing-staged")
payload=$("$JQ_BIN" -n --arg cwd "$nothing_staged_repo" --arg session "session-1" --arg command "git commit -m x" '{command: $command, cwd: $cwd, conversation_id: $session}')
result=$(echo "$payload" | "$SCRIPTS_DIR/check-git-event.sh" git.commit)
assert_json_field_equals "$result" "permission" "allow" "permission is allow"

test_case "check-git-event.sh: git.push not configured, default FAILURE_MODE -> deny"
push_repo=$(make_test_git_repo "not-configured-push")
echo "change" > "$push_repo/change.txt"
git -C "$push_repo" add change.txt
git -C "$push_repo" commit -q -m "change"
payload=$("$JQ_BIN" -n --arg cwd "$push_repo" --arg session "session-1" --arg command "git push origin main" '{command: $command, cwd: $cwd, conversation_id: $session}')
result=$(echo "$payload" | "$SCRIPTS_DIR/check-git-event.sh" git.push)
assert_json_field_equals "$result" "permission" "deny" "permission is deny (fail-closed default, matching check-write.sh)"
assert_json_has_key "$result" "agent_message" "has agent_message"

test_case "check-git-event.sh: git.push not configured, FAILURE_MODE=open -> allow"
result=$(PARADIGM_NETWORKS_FAILURE_MODE=open bash -c "echo '$payload' | '$SCRIPTS_DIR/check-git-event.sh' git.push")
assert_json_field_equals "$result" "permission" "allow" "permission is allow"
assert_json_has_key "$result" "user_message" "has user_message"

test_case "check-git-event.sh: git.commit not configured, default FAILURE_MODE -> deny (git.commit is now enforced, not a stub)"
commit_enforce_repo=$(make_test_git_repo "not-configured-commit")
echo "change" > "$commit_enforce_repo/change.txt"
git -C "$commit_enforce_repo" add change.txt
payload=$("$JQ_BIN" -n --arg cwd "$commit_enforce_repo" --arg session "session-1" --arg command "git commit -m x" '{command: $command, cwd: $cwd, conversation_id: $session}')
result=$(echo "$payload" | "$SCRIPTS_DIR/check-git-event.sh" git.commit)
assert_json_field_equals "$result" "permission" "deny" "permission is deny -- git.commit now gets real enforcement, same as git.push (design doc §0/item 8, §2.1)"

test_summary
exit $?
