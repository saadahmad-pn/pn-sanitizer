#!/bin/bash
# Unit tests for lib/session-metadata.sh -- the local, purely-client-side
# session-lifecycle mechanism that replaced the session-start/session-end
# plugins API calls (pn_register_plugin_session/pn_close_plugin_session,
# both removed). See design-ideas/
# Session_Lifecycle_Simplification_And_Contract_Updates.md.
#
# Also covers check-session.sh/check-session-end.sh's integration with
# these functions -- see test-hooks.sh for the full hook-level integration
# tests (login-prompt/staleness messaging is unaffected and stays there).

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-utils.sh"

test_init
source_scripts

echo -e "${BLUE}=== Unit Tests: lib/session-metadata.sh ===${NC}"

test_case "pn_write_session_metadata: writes SessionId/Cwd/GitRepoUrl/GitBranch/StartedAt as JSON"
pn_write_session_metadata "sess-1" "/repo" "github.com/org/repo" "main"
metadata=$(pn_read_session_metadata "sess-1")
assert_json_valid "$metadata" "Valid JSON"
assert_json_field_equals "$metadata" "SessionId" "sess-1" "SessionId encoded correctly"
assert_json_field_equals "$metadata" "Cwd" "/repo" "Cwd encoded correctly"
assert_json_field_equals "$metadata" "GitRepoUrl" "github.com/org/repo" "GitRepoUrl encoded correctly"
assert_json_field_equals "$metadata" "GitBranch" "main" "GitBranch encoded correctly"
assert_json_has_key "$metadata" "StartedAt" "has a StartedAt timestamp"

test_case "pn_write_session_metadata: file is written with 600 permissions"
perms=$(stat -f '%Lp' "$SESSION_METADATA_DIR/sess-1.json" 2>/dev/null || stat -c '%a' "$SESSION_METADATA_DIR/sess-1.json" 2>/dev/null)
assert_output_equals "echo \"$perms\"" "600" "restricted file permissions"

test_case "pn_write_session_metadata: two sessions get two independent files"
pn_write_session_metadata "sess-2" "/other-repo" "" ""
sess1_after=$(pn_read_session_metadata "sess-1")
sess2=$(pn_read_session_metadata "sess-2")
assert_json_field_equals "$sess1_after" "Cwd" "/repo" "sess-1 unaffected by writing sess-2"
assert_json_field_equals "$sess2" "Cwd" "/other-repo" "sess-2 has its own Cwd"

test_case "pn_write_session_metadata: empty session_id -> no file written"
before_count=$(find "$SESSION_METADATA_DIR" -name '*.json' | wc -l | tr -d ' ')
pn_write_session_metadata "" "/repo" "" ""
after_count=$(find "$SESSION_METADATA_DIR" -name '*.json' | wc -l | tr -d ' ')
assert_output_equals "echo \"$before_count-$after_count\"" "$before_count-$before_count" "no new file created"

test_case "pn_write_session_metadata: path-traversal session_id is rejected"
pn_write_session_metadata "../../etc/evil" "/repo" "" ""
assert_output_equals "test -f '$HOME/../../etc/evil.json' && echo exists || echo absent" "absent" "never writes outside SESSION_METADATA_DIR"

test_case "pn_remove_session_metadata: removes the file"
pn_remove_session_metadata "sess-1"
result=$(pn_read_session_metadata "sess-1")
assert_output_equals "echo \"$result\"" "" "file no longer readable after removal"

test_case "pn_remove_session_metadata: missing file -> no error"
assert_success "pn_remove_session_metadata 'never-existed'" "removing a file that was never written is not an error"

test_case "pn_read_session_metadata: unknown session -> empty output"
assert_output_equals "pn_read_session_metadata 'unknown-session'" "" "nothing to read"

test_case "_pn_prune_stale_session_metadata: removes files older than 24h, keeps recent ones"
pn_write_session_metadata "sess-fresh" "/repo" "" ""
pn_write_session_metadata "sess-old" "/repo" "" ""
# Backdate sess-old's mtime past the 24h prune window.
old_file="$SESSION_METADATA_DIR/sess-old.json"
touch -t "$(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M)" "$old_file" 2>/dev/null || true
pn_write_session_metadata "sess-trigger" "/repo" "" ""
assert_output_equals "test -f '$old_file' && echo exists || echo absent" "absent" "stale file pruned on next write"
fresh=$(pn_read_session_metadata "sess-fresh")
assert_json_field_equals "$fresh" "SessionId" "sess-fresh" "recent file survives pruning"

echo -e "${BLUE}=== Integration: check-session.sh writes metadata; check-session-end.sh removes it ===${NC}"

test_case "check-session.sh: writes session metadata for a valid payload"
# write_session_metadata runs backgrounded inside check-session.sh's own
# process (so it never delays the login-check response) -- that background
# job isn't in THIS shell's job table, so `wait` can't block on it. Poll for
# the file instead of a single immediate read.
payload='{"conversation_id": "hook-sess-1", "cwd": "/hookrepo"}'
echo "$payload" | "$SCRIPTS_DIR/check-session.sh" > /dev/null
metadata=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  metadata=$(pn_read_session_metadata "hook-sess-1")
  [[ -n "$metadata" ]] && break
  sleep 0.2
done
assert_json_field_equals "$metadata" "SessionId" "hook-sess-1" "metadata written by the hook"
assert_json_field_equals "$metadata" "Cwd" "/hookrepo" "Cwd from the hook payload"

test_case "check-session-end.sh: removes session metadata for a valid payload"
payload='{"conversation_id": "hook-sess-1"}'
echo "$payload" | "$SCRIPTS_DIR/check-session-end.sh" > /dev/null
result=$(pn_read_session_metadata "hook-sess-1")
assert_output_equals "echo \"$result\"" "" "metadata removed by sessionEnd"

test_summary
FINAL_RESULT=$?
test_cleanup
exit $FINAL_RESULT
