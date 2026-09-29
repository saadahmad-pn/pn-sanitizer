#!/bin/bash
# Unit tests for lib/skill-detection.sh -- the path test that recognises an
# Agent Skill being loaded, shared by check-skill-usage.sh (which reports the
# use) and check-tool-call.sh/check-tool-call-record.sh (which must NOT also
# record the same read as an ordinary Read tool call).
#
# Unit-level only: the layouts below are the real ones the four skill sources
# actually use, since the whole detection rests on that one path shape and a
# missed layout means a skill silently goes unrecorded.

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-utils.sh"

test_init
source_scripts

echo -e "${BLUE}=== Unit Tests: lib/skill-detection.sh ===${NC}"

# --- pn_skill_name_from_path: the real layouts ---

test_case "Cursor's own skills (~/.cursor/skills-cursor) -> matches"
assert_success "pn_skill_name_from_path '/Users/dev/.cursor/skills-cursor/canvas/SKILL.md'" \
  "a Cursor built-in skill is detected"

test_case "Marketplace plugin cache layout -> matches"
assert_success "pn_skill_name_from_path '/Users/dev/.cursor/plugins/cache/cursor-public/postman/caa7cfcd/skills/api-documentation/SKILL.md'" \
  "a plugin-provided skill is detected"

test_case "Project-local .cursor/skills -> matches"
assert_success "pn_skill_name_from_path '/Users/dev/Work/app/.cursor/skills/deploy/SKILL.md'" \
  "a workspace skill is detected"

test_case "Claude Code's .claude/skills -> matches"
assert_success "pn_skill_name_from_path '/Users/dev/Work/app/.claude/skills/deploy/SKILL.md'" \
  "the Agent Skills standard layout is detected"

test_case "Windows separators -> matches"
assert_success "pn_skill_name_from_path 'C:\\Users\\dev\\.cursor\\skills\\deploy\\SKILL.md'" \
  "a Windows payload path is detected"

# --- the extracted name ---

test_case "Skill name is the directory, not the file"
pn_skill_name_from_path '/Users/dev/.cursor/skills-cursor/api-documentation/SKILL.md'
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$PN_SKILL_NAME" == "api-documentation" ]]; then
  echo -e "  ${GREEN}✓${NC} PN_SKILL_NAME is the skill directory name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} PN_SKILL_NAME is the skill directory name (got: $PN_SKILL_NAME)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_case "A non-match clears PN_SKILL_NAME rather than leaving it stale"
pn_skill_name_from_path '/Users/dev/.cursor/skills/deploy/SKILL.md' || true
pn_skill_name_from_path '/Users/dev/notes.md' || true
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -z "$PN_SKILL_NAME" ]]; then
  echo -e "  ${GREEN}✓${NC} PN_SKILL_NAME cleared, not left over from the previous call"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} PN_SKILL_NAME cleared (got: $PN_SKILL_NAME)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# --- what must NOT match ---

test_case "An ordinary file read -> no match"
assert_failure "pn_skill_name_from_path '/Users/dev/Work/app/src/main.go'" \
  "a normal source file is not a skill load"

test_case "A supporting file inside a skill directory -> no match"
assert_failure "pn_skill_name_from_path '/Users/dev/.cursor/skills/deploy/reference.md'" \
  "only SKILL.md itself is the skill load"

test_case "A file merely named SKILL.md outside a skills/ directory -> no match"
assert_failure "pn_skill_name_from_path '/Users/dev/Work/app/docs/SKILL.md'" \
  "the skills/<name>/ shape is required, not the filename alone"

test_case "A nested path ending in skills/ with no skill name -> no match"
assert_failure "pn_skill_name_from_path '/Users/dev/.cursor/skills/SKILL.md'" \
  "a SKILL.md directly under skills/ has no skill directory"

test_case "Case matters: skill.md is not SKILL.md"
assert_failure "pn_skill_name_from_path '/Users/dev/.cursor/skills/deploy/skill.md'" \
  "the filename is matched exactly, as Cursor writes it"

test_case "Empty path -> no match"
assert_failure "pn_skill_name_from_path ''" \
  "an absent file_path is not a skill load"

# --- pn_is_skill_file_read: the tool-call exemption ---

SKILL_PATH='/Users/dev/.cursor/skills/deploy/SKILL.md'

test_case "Read of a SKILL.md -> exempt from tool-call recording"
assert_success "pn_is_skill_file_read Read '$SKILL_PATH'" \
  "the duplicate of what check-skill-usage.sh already reports"

test_case "WRITE to a SKILL.md -> NOT exempt"
assert_failure "pn_is_skill_file_read Write '$SKILL_PATH'" \
  "editing a skill is ordinary work and must still be scanned and recorded"

test_case "Read of an ordinary file -> NOT exempt"
assert_failure "pn_is_skill_file_read Read '/Users/dev/Work/app/src/main.go'" \
  "a normal file read is still recorded"

test_case "Shell tool with a SKILL.md path -> NOT exempt"
assert_failure "pn_is_skill_file_read Shell '$SKILL_PATH'" \
  "only the Read tool loads a skill; a shell command touching one is not that"

test_case "Read with no file path -> NOT exempt"
assert_failure "pn_is_skill_file_read Read ''" \
  "an unidentifiable read is recorded rather than silently dropped"

test_summary
exit $?
