#!/bin/bash
# Git repository discovery for the repo-context hook.
# Sourced by scripts/check-repo-context.sh. Kept separate from common.sh
# since this is a distinct concern (git introspection) from the JSON/HTTP/
# logging helpers there.

REPO_CONTEXT_MAX_DEPTH=5
REPO_CONTEXT_SKIP_DIRS=("node_modules" ".next" "dist" "build" ".git")
REPO_CONTEXT_MAX_VALUE_LEN=500

# sanitize_git_value <raw_value>
# Hardens raw `git config`/`git branch` output before it is embedded into
# agent-facing context (<GIT>...</GIT> tags in the generated rule file).
# A repo's remote.origin.url or branch name is attacker-controllable data
# (anyone can set it to an arbitrary string), so this:
#   - strips embedded userinfo credentials from URLs (user:token@host -> host)
#   - strips newline/control characters so a value can't break out of its
#     single-line tag or inject extra rule content
#   - caps length so one crafted value can't flood the rule file
sanitize_git_value() {
  local value="$1"
  value=$(printf '%s' "$value" | sed -E 's#(://)[^/@[:space:]]+@#\1#')
  value=$(printf '%s' "$value" | tr -d '\r\n\t' | tr -cd '[:print:]')
  if [ "${#value}" -gt "$REPO_CONTEXT_MAX_VALUE_LEN" ]; then
    value="${value:0:$REPO_CONTEXT_MAX_VALUE_LEN}...<truncated>"
  fi
  printf '%s' "$value"
}

# find_git_repos <start_path>
# Prints one absolute repo path per line: a depth-capped recursive walk that
# stops descending once it finds a .git directory, skipping known-noisy
# directories.
find_git_repos() {
  local start_path="$1"
  _repo_context_search "$start_path" 0
}

_repo_context_search() {
  local dir="$1"
  local depth="$2"

  if [ "$depth" -gt "$REPO_CONTEXT_MAX_DEPTH" ]; then
    return
  fi

  if [ -d "$dir/.git" ]; then
    echo "$dir"
    return
  fi

  local entry name
  for entry in "$dir"/*/; do
    [ -d "$entry" ] || continue
    # Don't follow symlinked directories: a symlink planted anywhere under
    # the scan root could otherwise walk the scanner outside the intended
    # workspace and surface unrelated repos' remote URLs.
    [ -L "${entry%/}" ] && continue
    name=$(basename "$entry")

    local skip=0
    for skip_name in "${REPO_CONTEXT_SKIP_DIRS[@]}"; do
      if [ "$name" == "$skip_name" ]; then
        skip=1
        break
      fi
    done
    [ "$skip" -eq 1 ] && continue

    _repo_context_search "${entry%/}" $((depth + 1))
  done
}

# get_remote_url <repo_path>
get_remote_url() {
  local repo_path="$1"
  local url
  url=$(git -C "$repo_path" config --get remote.origin.url 2>/dev/null)
  sanitize_git_value "${url:-No remote}"
}

# get_current_branch <repo_path>
get_current_branch() {
  local repo_path="$1"
  local branch
  branch=$(git -C "$repo_path" branch --show-current 2>/dev/null)
  sanitize_git_value "${branch:-detached}"
}

# get_remote_url_or_empty <repo_path>
# Same as get_remote_url, but returns an empty string (not the "No remote"
# placeholder) when there's no configured origin. get_remote_url's fallback
# text is meant for human-readable <GIT>...</GIT> context injection
# (check-repo-context.sh); the detections API contract (design-ideas/
# Cursor_PrePush_Governance_Enforcement_Plan.md §0.5.3) instead requires
# GitRepoUrl to be a genuinely empty field when Cwd isn't a git repo or has
# no remote, so a placeholder string would misrepresent that case to the
# backend.
get_remote_url_or_empty() {
  local repo_path="$1"
  local url
  url=$(git -C "$repo_path" config --get remote.origin.url 2>/dev/null)
  [[ -z "$url" ]] && return 0
  sanitize_git_value "$url"
}

# get_current_branch_or_empty <repo_path>
# Same rationale as get_remote_url_or_empty above, for GitBranch.
get_current_branch_or_empty() {
  local repo_path="$1"
  local branch
  branch=$(git -C "$repo_path" branch --show-current 2>/dev/null)
  [[ -z "$branch" ]] && return 0
  sanitize_git_value "$branch"
}

# resolve_unpushed_changed_files <repo_path>
# Prints repo-relative paths (one per line, deduped) of every file touched
# by a commit reachable from the current branch's HEAD but not reachable
# from ANY remote-tracking branch -- i.e. what a `git push` of the current
# branch would actually send to the remote, and (for the common case where
# a PR is raised on a branch that either was just pushed or is about to be)
# also a reasonable proxy for what a `gh pr create` would diff.
#
# Deliberately not based on the upstream tracking ref (`@{u}`) or on parsing
# a destination branch out of the raw push/PR command text: `@{u}` is unset
# on a brand-new branch's first push (nothing to diff against), and parsing
# "git push <remote> <refspec>" out of free-form command text is a much
# larger surface to get wrong (custom refspecs, --force-with-lease, `gh pr
# create --base <branch>`, etc.) for an answer git's own object graph
# already gives directly. Known limitation: a commit that happens to already
# exist on some *other* remote branch (e.g. cherry-picked) won't show here
# even though it's new to the branch being pushed -- acceptable for a
# governance scan, since that content already passed through this same
# check when it was first pushed elsewhere.
resolve_unpushed_changed_files() {
  local repo_path="$1"
  git -C "$repo_path" log HEAD --not --remotes --name-only --pretty=format: 2>/dev/null \
    | sed '/^$/d' \
    | sort -u
}

# resolve_staged_changed_files <repo_path>
# Prints repo-relative paths of every file staged for the next commit
# (excluding deletions, --diff-filter=d -- nothing to scan for a file being
# removed). The right file set for a git.commit event: the gate runs
# before `git commit` itself runs, so there is no new commit yet to
# diff against -- the index is the only place "what's about to be
# committed" already exists.
resolve_staged_changed_files() {
  local repo_path="$1"
  git -C "$repo_path" diff --cached --name-only --diff-filter=d 2>/dev/null
}

# resolve_pr_create_changed_files <repo_path> <command_text>
# Prints repo-relative paths of every file that differs between the current
# branch and the PR's base branch -- the right file set for a git.pr_create
# event. Unlike resolve_unpushed_changed_files (used for git.push), a "not
# reachable from any remote" comparison is wrong here in the common flow
# where the branch was already pushed before `gh pr create` runs: every one
# of its commits is then already on a remote branch, so that comparison
# would find nothing to scan at exactly the moment a PR (and its
# review/merge consequences) is about to be opened.
#
# Base-branch resolution order:
#   1. --base/-B <branch> parsed directly out of the raw `gh pr create`
#      command text, if present.
#   2. The remote's recorded default branch (`git symbolic-ref
#      refs/remotes/<remote>/HEAD`), if set locally (populated by a normal
#      clone, or by `git remote set-head`).
#   3. A conventional default branch name (main, then master) that exists
#      as a remote-tracking ref.
# If none of these resolve (e.g. no remote-tracking info exists at all
# yet), falls back to resolve_unpushed_changed_files's heuristic -- an
# imperfect but strictly-better-than-nothing answer for that edge case.
resolve_pr_create_changed_files() {
  local repo_path="$1"
  local command_text="$2"
  local remote="origin"

  local base_branch
  base_branch=$(printf '%s' "$command_text" | sed -nE 's/.*(--base|-B)[[:space:]]+([^ ]+).*/\2/p' | head -1)

  local base_ref=""
  if [[ -n "$base_branch" ]]; then
    if git -C "$repo_path" rev-parse --verify -q "${remote}/${base_branch}" >/dev/null 2>&1; then
      base_ref="${remote}/${base_branch}"
    elif git -C "$repo_path" rev-parse --verify -q "${base_branch}" >/dev/null 2>&1; then
      base_ref="$base_branch"
    fi
  fi

  if [[ -z "$base_ref" ]]; then
    local symbolic
    symbolic=$(git -C "$repo_path" symbolic-ref -q "refs/remotes/${remote}/HEAD" 2>/dev/null)
    if [[ -n "$symbolic" ]]; then
      base_ref="${symbolic#refs/remotes/}"
    fi
  fi

  if [[ -z "$base_ref" ]]; then
    local candidate
    for candidate in main master; do
      if git -C "$repo_path" rev-parse --verify -q "${remote}/${candidate}" >/dev/null 2>&1; then
        base_ref="${remote}/${candidate}"
        break
      fi
    done
  fi

  if [[ -z "$base_ref" ]]; then
    resolve_unpushed_changed_files "$repo_path"
    return 0
  fi

  local merge_base
  merge_base=$(git -C "$repo_path" merge-base "$base_ref" HEAD 2>/dev/null)
  if [[ -z "$merge_base" ]]; then
    resolve_unpushed_changed_files "$repo_path"
    return 0
  fi

  git -C "$repo_path" diff --name-only --diff-filter=d "${merge_base}..HEAD" 2>/dev/null | sort -u
}

# repo_head_fingerprint <repo_path>
# A cheap stand-in for "has anything changed since last check" — the mtime
# of .git/HEAD changes on checkout/branch-switch and (via the packed-refs/
# loose-ref update it triggers) on commit. Not a perfect signal, but cheap
# enough to check on every prompt without doing a real git call.
repo_head_fingerprint() {
  local repo_path="$1"
  stat -f '%m' "$repo_path/.git/HEAD" 2>/dev/null || \
  stat -c '%Y' "$repo_path/.git/HEAD" 2>/dev/null || \
  echo "0"
}

# dedupe_lines
# Reads paths on stdin, prints unique paths, preserving first-seen order.
dedupe_lines() {
  awk '!seen[$0]++'
}
