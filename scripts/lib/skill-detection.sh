#!/bin/bash
# Recognises an Agent Skill being loaded, from the path of the file being
# read. Shared by three hooks, which is the whole reason it is a library:
#
#   check-skill-usage.sh      (beforeReadFile)  -- reports the skill use
#   check-tool-call.sh        (preToolUse)      -- must NOT also scan it
#   check-tool-call-record.sh (postToolUse)     -- must NOT also record it
#
# Cursor has no dedicated "skill invoked" hook event, and no hook payload
# carries a skill name (confirmed against Cursor's hooks docs and the
# matching, still-open anthropics/claude-code feature request for the same
# gap). What Cursor actually does when it loads a skill is a plain read of
# that skill's SKILL.md, so the path is the only signal there is.
#
# The consequence, and why the last two callers exist: that same read also
# reaches preToolUse/postToolUse as an ordinary Read tool call. Without the
# skip, one skill load is recorded twice -- once as a skill use, once as a
# file read of a path the user never asked for -- and the transcript shows
# both. The two tool-call hooks each call this independently, needing no
# state handed between the two separate hook processes, exactly as
# lib/login-detection.sh already does for the login/logout exemption.

# pn_skill_name_from_path <file_path>
# Sets PN_SKILL_NAME and returns 0 when the path is a skill's SKILL.md,
# clears it and returns 1 otherwise.
#
# Matched on the ".../skills*/<name>/SKILL.md" shape rather than one vendor's
# exact layout, because the four real sources agree on nothing else:
#
#   ~/.cursor/skills-cursor/<name>/SKILL.md                      Cursor's own
#   ~/.cursor/plugins/cache/<pub>/<plugin>/<sha>/skills/<name>/  marketplace
#   <workspace>/.cursor/skills/<name>/                           project
#   <workspace>/.claude/skills/<name>/                           Agent Skills
#
# The "-cursor" suffix is why this is not a plain /skills/ test. Cursor keeps
# its OWN built-in skills (canvas, review, create-skill, ...) in
# skills-cursor/, so an exact match on "skills" silently misses every one of
# them -- caught by test-skill-detection.sh, not by inspection.
#
# The suffix group is optional and bounded to one segment, so "/skills/" and
# "/skills-cursor/" both match while an unrelated "/my-skills/" does not (it
# has no "/skills" segment at all). Both separators are accepted so a Windows
# payload matches too.
pn_skill_name_from_path() {
  local path="${1:-}"
  PN_SKILL_NAME=""
  [[ -n "$path" ]] || return 1
  local normalized="${path//\\//}"
  [[ "$normalized" =~ /skills(-[^/]+)?/([^/]+)/SKILL\.md$ ]] || return 1
  PN_SKILL_NAME="${BASH_REMATCH[2]}"
  return 0
}

# pn_is_skill_file_read <tool_name> <file_path>
# True when this tool call is the read that loads a skill -- the thing
# check-skill-usage.sh already reports, so the tool-call hooks skip it.
#
# Scoped to Read specifically: a Write to a SKILL.md is somebody EDITING a
# skill, which is ordinary work that must still be scanned and recorded. Only
# the read is the duplicate.
pn_is_skill_file_read() {
  local tool_name="${1:-}" file_path="${2:-}"
  [[ "$tool_name" == "Read" ]] || return 1
  pn_skill_name_from_path "$file_path"
}
