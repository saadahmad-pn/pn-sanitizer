#!/bin/bash
# beforeSubmitPrompt hook: write git repo/branch context into a workspace
# rule file so Cursor folds it into the system prompt of the next real
# model request. That system prompt is what the Paradigm Networks backend
# parses a <GIT>url|branch</GIT> tag out of (control-server's
# GitContext.go) to attribute the request to a repo and inject repo-aware
# context — this hook only needs to produce that tag; nothing else reads it
# on the plugin side, and nothing here calls Paradigm Networks directly.
#
# Trade-off (deliberate): beforeSubmitPrompt can't inject context into the
# agent directly (no field for it — the same constraint that made the
# pn-login-check rule necessary), so writing a rule file Cursor picks up on
# its own is the only reliable channel. There's no persistent background
# process available to watch .git/HEAD for changes, so this re-checks
# before every prompt instead of once per session.
#
# Cost-cutting trade-off: a full repo-tree walk on every single prompt is
# wasteful when nothing has changed, so this keeps a small per-workspace
# cache (workspace root mtime + each known repo's .git/HEAD mtime) and
# skips the walk when that fingerprint is unchanged. This can miss a
# brand-new repo cloned several directories deep inside an otherwise
# unchanged tree — only a new top-level entry or an existing repo's HEAD
# change is guaranteed to invalidate the cache. Accepted: the downstream
# consumer only reads the first <GIT> tag in the file, so a momentarily
# stale later entry has no effect in practice.
#
# This hook has nothing to gate — it never blocks prompt submission.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/git-utils.sh"

CACHE_DIR="${HOME}/.paradigm-scanner/repo-context-cache"

# Fail-open safety net: whatever happens below, always emit
# {"continue": true} exactly once before the process exits.
CONTINUE_EMITTED=0
emit_continue() {
  if [ "$CONTINUE_EMITTED" -eq 0 ]; then
    echo '{"continue": true}'
    CONTINUE_EMITTED=1
  fi
  exit 0
}
trap emit_continue EXIT

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

if [ -z "$JQ_BIN" ]; then
  # No jq available to parse the hook payload — nothing to do, fail open.
  exit 0
fi

INPUT=$(cat)
WORKSPACE_ROOTS=$("$JQ_BIN" -r '.workspace_roots[]?' <<< "$INPUT" 2>/dev/null || true)

if [ -z "$WORKSPACE_ROOTS" ]; then
  exit 0
fi

mkdir -p "$CACHE_DIR" 2>/dev/null || true

while IFS= read -r root; do
  [ -z "$root" ] && continue
  [ -d "$root" ] || continue
  is_safe_workspace_root "$root" || continue

  # Canonicalize so a relative segment or symlink in the reported root
  # can't redirect writes outside the intended workspace directory.
  root="$(cd "$root" 2>/dev/null && pwd -P)" || continue
  is_safe_workspace_root "$root" || continue

  cache_file="$CACHE_DIR/$(cache_key_for_root "$root")"

  if [ -f "$cache_file" ]; then
    last_fingerprint=$(sed -n '1p' "$cache_file")
    last_repos=$(tail -n +2 "$cache_file")
    if [ -n "$last_repos" ]; then
      current_fingerprint=$(root_fingerprint "$root" "$last_repos")
      if [ "$current_fingerprint" == "$last_fingerprint" ]; then
        # Nothing's changed since last check — skip the walk and rewrite.
        continue
      fi
    fi
  fi

  FOUND_REPOS=$(find_git_repos "$root")
  UNIQUE_REPOS=$(echo "$FOUND_REPOS" | grep -v '^$' | dedupe_lines || true)

  if [ -z "$UNIQUE_REPOS" ]; then
    REPO_LIST="- No git repositories detected in this workspace."
  else
    REPO_LIST=""
    i=1
    while IFS= read -r repo_path; do
      [ -z "$repo_path" ] && continue
      remote=$(get_remote_url "$repo_path")
      branch=$(get_current_branch "$repo_path")
      REPO_LIST="${REPO_LIST}${i}. <GIT>${remote}|${branch}</GIT>"$'\n'
      i=$((i + 1))
    done <<< "$UNIQUE_REPOS"
  fi

  RULE_DIR="$root/.cursor/rules"
  RULE_FILE="$RULE_DIR/paradigm-repo-context.mdc"
  mkdir -p "$RULE_DIR" 2>/dev/null || continue

  cat > "$RULE_FILE" << EOF
---
alwaysApply: true
---

### Available Repositories:
${REPO_LIST}
EOF

  ensure_gitignored "$root" ".cursor/rules/paradigm-repo-context.mdc"

  {
    root_fingerprint "$root" "$UNIQUE_REPOS"
    echo ""
    echo "$UNIQUE_REPOS"
  } > "$cache_file"
done <<< "$WORKSPACE_ROOTS"

exit 0
