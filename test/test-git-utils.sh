#!/bin/bash
# Unit tests for lib/git-utils.sh's resolvers and lib/plugins-client.sh's
# pn_build_git_diff_files_json (the changed-file collection a before_tool_call
# gating a detected git push/commit attaches -- folded in from the retired
# check-git-event.sh; see design-ideas/
# Shell_Execution_vs_Tool_Call_Hook_Coverage_Validation.md and design-ideas/
# Plugin_API_Standardization_And_Hook_Consolidation_Design.md §2.1).
#
# The git-command detection itself (regex matching in check-tool-call.sh) and
# the end-to-end gating behavior (FAILURE_MODE, not-configured, etc.) are
# covered as integration tests in test-hooks.sh's check-tool-call.sh section,
# not here -- this file is unit-level only.

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-utils.sh"

test_init
source_scripts

echo -e "${BLUE}=== Unit Tests: lib/git-utils.sh (changed-file resolvers) ===${NC}"

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

echo -e "${BLUE}=== Unit Tests: lib/plugins-client.sh (is_binary_file, pn_build_git_diff_files_json) ===${NC}"

test_case "is_binary_file: plain text file -> false"
text_file="$TEST_TEMP_DIR/plain.txt"
printf 'hello\nworld\n' > "$text_file"
assert_failure "is_binary_file '$text_file'" "reports false (assert_failure = non-zero/false return)"

test_case "is_binary_file: file containing a NUL byte -> true"
bin_file="$TEST_TEMP_DIR/binary.bin"
printf 'abc\000def' > "$bin_file"
assert_success "is_binary_file '$bin_file'" "reports true (assert_success = zero/true return)"

test_case "pn_build_git_diff_files_json: git.push with one committed file -> one entry, base64 content matches"
push_repo=$(make_test_git_repo "build-files-push")
files_json=$(pn_build_git_diff_files_json "$push_repo" "git.push")
assert_output_equals "echo \"\$files_json\" | \"\$JQ_BIN\" 'length'" "1" "one file entry"
assert_output_equals "echo \"\$files_json\" | \"\$JQ_BIN\" -r '.[0].Filename'" "README.md" "Filename is the repo-relative path"
decoded=$(echo "$files_json" | "$JQ_BIN" -r '.[0].ContentBase64' | base64 -d 2>/dev/null)
assert_output_equals "cat '$push_repo/README.md'" "$decoded" "base64 content decodes back to the file's real content"

test_case "pn_build_git_diff_files_json: git.commit with nothing staged -> empty array"
commit_repo=$(make_test_git_repo "build-files-commit-empty")
assert_output_equals "pn_build_git_diff_files_json '$commit_repo' 'git.commit'" "[]" "nothing to attach"

test_case "pn_build_git_diff_files_json: git.commit with one staged file -> one entry"
echo "staged content" > "$commit_repo/staged.txt"
git -C "$commit_repo" add staged.txt
files_json=$(pn_build_git_diff_files_json "$commit_repo" "git.commit")
assert_output_equals "echo \"\$files_json\" | \"\$JQ_BIN\" -r '.[0].Filename'" "staged.txt" "Filename is the staged file"

test_case "pn_build_git_diff_files_json: binary file is skipped"
bin_repo=$(make_test_git_repo "build-files-binary")
printf 'abc\000def' > "$bin_repo/image.bin"
git -C "$bin_repo" add image.bin
files_json=$(pn_build_git_diff_files_json "$bin_repo" "git.commit")
assert_output_equals "echo \"\$files_json\"" "[]" "binary file never attached"

test_case "pn_build_git_diff_files_json: unrecognized event type -> empty array, no resolver called"
assert_output_equals "pn_build_git_diff_files_json '$push_repo' 'git.pr_create'" "[]" "git.pr_create has no file-collection resolver"

test_summary
exit $?
