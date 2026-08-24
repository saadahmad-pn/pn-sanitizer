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
