#!/bin/bash
# Checks how the sessionStart hook learns its own plugin root, for every
# installed copy of paradigm-networks (dev repo, ~/.cursor/plugins/local,
# ~/.cursor/plugins/cache/<marketplace>/paradigm-networks/<hash>).
#
# For each copy it runs the real `scripts/run-hook.cmd check-session` with a
# Cursor-shaped sessionStart payload and a throwaway HOME (so nothing is
# configured and the hook prints its login instructions, which contain the
# path it resolved). It then checks that the reported path belongs to that
# copy, and compares against the `find` patterns the skills/rules use.
#
# Read-only for installed copies; all writes go to a temp dir.

set -u

DEV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGINS_DIR="$HOME/.cursor/plugins"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
FAKE_WORKSPACE="$TMP/workspace"
mkdir -p "$FAKE_HOME" "$FAKE_WORKSPACE"

PAYLOAD=$(cat <<EOF
{
  "conversation_id": "plugin-root-test",
  "session_id": "plugin-root-test",
  "hook_event_name": "sessionStart",
  "composer_mode": "agent",
  "workspace_roots": ["$FAKE_WORKSPACE"],
  "transcript_path": null
}
EOF
)

pass=0
fail=0
ok()  { echo "  PASS  $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $*"; fail=$((fail + 1)); }

# Collect every copy: dev repo first, then installed ones.
copies=("$DEV_ROOT")
while IFS= read -r d; do
  copies+=("$(cd "$d/.." && pwd)")
done < <(find "$PLUGINS_DIR" -type f -path "*paradigm-networks*/scripts/check-session.sh" 2>/dev/null | xargs -n1 dirname 2>/dev/null)

echo "== Installed copies of paradigm-networks =="
for c in "${copies[@]}"; do echo "  $c"; done
echo

# Pull the login.sh path out of the hook's additional_context.
reported_path() {
  sed -n 's/.*bash \([^ ]*\)\/login\.sh.*/\1/p' | head -1
}

run_hook() {
  # $1 = dir to run from, $2 = command
  (cd "$1" && echo "$PAYLOAD" | HOME="$FAKE_HOME" bash -c "$2" 2>/dev/null)
}

skipped=0
for c in "${copies[@]}"; do
  echo "== $c =="

  # Older builds have no run-hook.cmd dispatcher, or a login message that
  # does not carry the path. Nothing to check there.
  if [[ ! -f "$c/scripts/run-hook.cmd" ]] || ! grep -q 'bash \$SCRIPT_DIR/login.sh' "$c/scripts/check-session.sh"; then
    echo "  SKIP  older build: hook does not report its scripts dir"
    skipped=$((skipped + 1))
    echo
    continue
  fi

  # 1. Relative command (what hooks.json uses), run from the plugin root.
  out=$(run_hook "$c" "scripts/run-hook.cmd check-session")
  got=$(echo "$out" | reported_path)
  if [[ "$got" == "$c/scripts" ]]; then
    ok "from plugin root: hook reports its own scripts dir"
  else
    bad "from plugin root: expected $c/scripts, got '${got:-<nothing>}'"
  fi

  # 2. Same relative command from the user's workspace (if Cursor did not
  #    start hooks in the plugin root). Expected to fail -- shows we rely on it.
  out=$(run_hook "$FAKE_WORKSPACE" "scripts/run-hook.cmd check-session")
  got=$(echo "$out" | reported_path)
  if [[ -z "$got" ]]; then
    ok "from workspace: relative command does not run (we depend on Cursor using the plugin root)"
  else
    bad "from workspace: relative command unexpectedly ran and reported '$got'"
  fi

  # 3. Absolute command from the workspace: script still finds its own copy.
  out=$(run_hook "$FAKE_WORKSPACE" "'$c/scripts/run-hook.cmd' check-session")
  got=$(echo "$out" | reported_path)
  if [[ "$got" == "$c/scripts" ]]; then
    ok "from workspace (absolute path): hook still reports its own scripts dir"
  else
    bad "from workspace (absolute path): expected $c/scripts, got '${got:-<nothing>}'"
  fi
  echo
done

echo "== What the skills' find patterns match =="
echo "Current pattern  */paradigm-networks/scripts/login.sh:"
find "$PLUGINS_DIR" -path "*/paradigm-networks/scripts/login.sh" 2>/dev/null | sed 's/^/  /'
echo "Lead's pattern   */paradigm-networks/*scripts/login.sh:"
find "$PLUGINS_DIR" -path "*/paradigm-networks/*scripts/login.sh" 2>/dev/null | sed 's/^/  /'
echo

echo "Result: $pass passed, $fail failed, $skipped copies skipped (older builds)"
[[ $fail -eq 0 ]]
