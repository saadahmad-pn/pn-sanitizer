#!/bin/bash
# Writes git repo/branch context into a workspace rule file so Cursor folds
# it into the system prompt of the next real model request. That system
# prompt is what the Paradigm Networks backend parses a <GIT>url|branch</GIT>
# tag out of (control-server's GitContext.go) to attribute the request to a
# repo and inject repo-aware context.
#
# Extracted from the former standalone check-repo-context.sh script so it
# can be called as a function from check-prompt.sh's single beforeSubmitPrompt
# hook entry instead of running as its own separate hooks.json registration
# -- see design-ideas/Plugin_API_Standardization_And_Hook_Consolidation_Design.md
# §5 (beforeSubmitPrompt collapses to one hook). This function never talks to
# control-server -- nothing here calls Paradigm Networks directly, and it has
# nothing to gate, so it's safe to run in the background from the caller.
#
# Cost-cutting trade-off (unchanged from the original): a full repo-tree walk
# on every single prompt is wasteful when nothing has changed, so this keeps
# a small per-workspace cache (workspace root mtime + each known repo's
# .git/HEAD mtime) and skips the walk when that fingerprint is unchanged.
# This can miss a brand-new repo cloned several directories deep inside an
# otherwise unchanged tree -- only a new top-level entry or an existing
# repo's HEAD change is guaranteed to invalidate the cache. Accepted: the
# downstream consumer only reads the first <GIT> tag in the file, so a
# momentarily stale later entry has no effect in practice.

REPO_CONTEXT_CACHE_DIR="${HOME}/.paradigm-scanner/repo-context-cache"

# is_safe_workspace_root <root>
# Defense-in-depth: guards against ever writing a rule file or appending to
# .gitignore in a root-level system directory if a malformed/unexpected
# path shows up in the hook payload.
is_safe_workspace_root() {
  local root="$1"
  case "$root" in
    /|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/var|/var/*|/System|/System/*|/Library|/Library/*|/root|/root/*)
      return 1
      ;;
  esac
  [[ "$root" == /* ]] || return 1
  return 0
}

# ensure_gitignored <workspace_root> <relative_path>
# Adds the given path to the workspace's .gitignore if not already covered,
# so the generated rule file never risks being accidentally committed.
ensure_gitignored() {
  local workspace_root="$1"
  local rel_path="$2"
  local gitignore="$workspace_root/.gitignore"

  if [ -f "$gitignore" ] && grep -qxF "$rel_path" "$gitignore" 2>/dev/null; then
    return 0
  fi

  {
    echo ""
    echo "# Added by paradigm-scanner — generated, workspace-local agent context"
    echo "$rel_path"
  } >> "$gitignore"
}

# root_fingerprint <root> <newline-separated repo paths>
# A cheap "has anything changed" signal: the root's own mtime (catches new
# top-level repos being added/removed) plus each known repo's HEAD mtime
# (catches checkouts/commits). Not exhaustive — see the trade-off note above.
root_fingerprint() {
  local root="$1"
  local repos="$2"
  local fp
  fp="$(stat -f '%m' "$root" 2>/dev/null || stat -c '%Y' "$root" 2>/dev/null || echo 0)"
  local repo_path
  while IFS= read -r repo_path; do
    [ -z "$repo_path" ] && continue
    fp="${fp}:$(repo_head_fingerprint "$repo_path")"
  done <<< "$repos"
  printf '%s' "$fp"
}

cache_key_for_root() {
  printf '%s' "$1" | cksum | awk '{print $1}'
}

# write_repo_context_rules <newline-separated workspace_roots>
# No return value used by the caller -- best-effort, side-effect only (rule
# files on disk). Requires JQ_BIN/lib/git-utils.sh already sourced by the
# caller.
write_repo_context_rules() {
  local workspace_roots="$1"
  [ -z "$workspace_roots" ] && return 0
  [ -z "$JQ_BIN" ] && return 0

  mkdir -p "$REPO_CONTEXT_CACHE_DIR" 2>/dev/null || true

  local root
  while IFS= read -r root; do
    [ -z "$root" ] && continue
    [ -d "$root" ] || continue
    is_safe_workspace_root "$root" || continue

    # Canonicalize so a relative segment or symlink in the reported root
    # can't redirect writes outside the intended workspace directory.
    root="$(cd "$root" 2>/dev/null && pwd -P)" || continue
    is_safe_workspace_root "$root" || continue

    local cache_file
    cache_file="$REPO_CONTEXT_CACHE_DIR/$(cache_key_for_root "$root")"

    if [ -f "$cache_file" ]; then
      local last_fingerprint last_repos
      last_fingerprint=$(sed -n '1p' "$cache_file")
      last_repos=$(tail -n +2 "$cache_file")
      if [ -n "$last_repos" ]; then
        local current_fingerprint
        current_fingerprint=$(root_fingerprint "$root" "$last_repos")
        if [ "$current_fingerprint" == "$last_fingerprint" ]; then
          # Nothing's changed since last check — skip the walk and rewrite.
          continue
        fi
      fi
    fi

    local found_repos unique_repos
    found_repos=$(find_git_repos "$root")
    unique_repos=$(echo "$found_repos" | grep -v '^$' | dedupe_lines || true)

    local repo_list
    if [ -z "$unique_repos" ]; then
      repo_list="- No git repositories detected in this workspace."
    else
      repo_list=""
      local i=1
      local repo_path
      while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        local remote branch
        remote=$(get_remote_url "$repo_path")
        branch=$(get_current_branch "$repo_path")
        repo_list="${repo_list}${i}. <GIT>${remote}|${branch}</GIT>"$'\n'
        i=$((i + 1))
      done <<< "$unique_repos"
    fi

    local rule_dir="$root/.cursor/rules"
    local rule_file="$rule_dir/paradigm-repo-context.mdc"
    mkdir -p "$rule_dir" 2>/dev/null || continue

    cat > "$rule_file" << EOF
---
alwaysApply: true
---

### Available Repositories:
${repo_list}
EOF

    ensure_gitignored "$root" ".cursor/rules/paradigm-repo-context.mdc"

    {
      root_fingerprint "$root" "$unique_repos"
      echo ""
      echo "$unique_repos"
    } > "$cache_file"
  done <<< "$workspace_roots"
}
