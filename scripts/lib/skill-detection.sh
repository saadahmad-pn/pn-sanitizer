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

# pn_slash_skill_name <prompt>
# Sets PN_SKILL_NAME and returns 0 when the prompt IS a slash invocation of a
# skill ("/greetings", "/api-documentation some argument"), 1 otherwise.
#
# WHY THIS EXISTS. A slash command never reads the SKILL.md through the agent's
# Read tool, so beforeReadFile — the whole basis of the detection above — never
# fires for it, and the use would go unrecorded. Confirmed live (2026-09-30):
# "/greetings " reached beforeSubmitPrompt verbatim and produced no skill row
# at all, while the same skill invoked in plain English ("now greet me") was
# recorded, because there the agent chose to read the file.
#
# Cursor passes the typed text through UNEXPANDED, so the name is right there
# in the prompt. The skill's own body is not, which is why the caller resolves
# the file from disk (pn_resolve_skill_path) rather than reporting a bare name:
# a name cannot be matched against the registry, and reporting one would file
# every slash-invoked skill as unmatched forever.
#
# Anchored to the start and limited to one token. A prompt that merely MENTIONS
# a path ("fix /etc/hosts") is not an invocation, and neither is a question
# containing a slash. Skill names follow the Agent Skills grammar: lowercase
# letters, digits and hyphens.
pn_slash_skill_name() {
  local prompt="${1:-}"
  PN_SKILL_NAME=""
  # Only the first line matters; a multi-line prompt that happens to start with
  # a command is still one invocation.
  local first_line="${prompt%%$'\n'*}"
  first_line="${first_line#"${first_line%%[![:space:]]*}"}"
  [[ "$first_line" =~ ^/([a-z0-9][a-z0-9-]*)([[:space:]]|$) ]] || return 1
  PN_SKILL_NAME="${BASH_REMATCH[1]}"
  return 0
}

# pn_resolve_skill_path <skill_name> <workspace_root>
# Sets PN_SKILL_PATH to the SKILL.md a slash-invoked skill would load, or
# returns 1 when no such file exists.
#
# Searched in the order Cursor itself resolves them: the workspace's own skills
# win over the user's, which win over a plugin's. Reading the file (rather than
# trusting the name) is what keeps a slash-invoked use indistinguishable from a
# read-invoked one — same bytes, same digest, same registry match.
#
# THE DIRECTORY IS A HINT, NOT THE IDENTITY. A skill is named by the `name:` in
# its own frontmatter; the directory only usually agrees. So a directory hit is
# ACCEPTED ONLY IF the file inside it declares the invoked name — otherwise
# "/greetings" landing on a greetings/ folder whose SKILL.md declares something
# else would report a skill that never ran, and miss the one that did. A file
# declaring no name at all falls back to its directory, which is then the only
# identity it has.
#
# A miss is ordinary, not an error: "/undo" and "/help" are Cursor's built-in
# commands, not skills, and most slash input is one of those.
pn_resolve_skill_path() {
  local name="${1:-}" workspace="${2:-}"
  PN_SKILL_PATH=""
  [[ -n "$name" ]] || return 1

  local candidates=()
  if [[ -n "$workspace" ]]; then
    candidates+=("${workspace%/}/.cursor/skills/${name}/SKILL.md")
    candidates+=("${workspace%/}/.claude/skills/${name}/SKILL.md")
  fi
  candidates+=("${HOME}/.cursor/skills/${name}/SKILL.md")
  candidates+=("${HOME}/.cursor/skills-cursor/${name}/SKILL.md")
  candidates+=("${HOME}/.claude/skills/${name}/SKILL.md")

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -r "$candidate" ]] && pn_skill_declares_name "$candidate" "$name"; then
      PN_SKILL_PATH="$candidate"
      return 0
    fi
  done

  # Plugin caches nest under a publisher/package/commit triple, so the name
  # alone cannot spell the path — glob for it. Newest first, so a re-pulled
  # plugin's current copy wins over a stale one left behind by an earlier
  # commit. Nullglob is scoped and restored: leaving it set would change how
  # every later unmatched glob in the calling hook behaves.
  local had_nullglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  local matches=("${HOME}"/.cursor/plugins/cache/*/*/*/skills/"${name}"/SKILL.md)
  [[ $had_nullglob -eq 1 ]] || shopt -u nullglob

  local newest="" candidate_time newest_time=0
  for candidate in "${matches[@]}"; do
    [[ -r "$candidate" ]] || continue
    pn_skill_declares_name "$candidate" "$name" || continue
    candidate_time=$(stat -f%m "$candidate" 2>/dev/null || stat -c%Y "$candidate" 2>/dev/null || echo 0)
    if [[ "$candidate_time" -ge "$newest_time" ]]; then
      newest_time="$candidate_time"
      newest="$candidate"
    fi
  done
  if [[ -n "$newest" ]]; then
    PN_SKILL_PATH="$newest"
    return 0
  fi
  return 1
}

# pn_collect_skill_content <path>
# Sets PN_SKILL_CONTENT to the file's exact bytes and PN_SKILL_SHA to their
# SHA-256. Returns 1 when the file could not be read.
#
# Shared by both hooks that report a skill: beforeReadFile (the agent read the
# file) and beforeSubmitPrompt (a slash command, where nothing was read). Both
# must produce byte-identical records for the same skill, or the same use would
# match the registry through one path and not the other.
#
# THE FILE ON DISK IS THE SOURCE. beforeReadFile carries a `content` field, but
# Cursor CHUNKS a large file across several events, each holding only its own
# piece — measured 2026-09-30 on a 6748-byte SKILL.md delivered as 4590 + 2163.
# A fragment's digest can never equal the published file's, so a large skill
# would be permanently unmatched and one load would file several uses. A slash
# command carries no content at all. Reading the file answers both.
#
# The trailing newline is preserved deliberately. $(...) strips every trailing
# newline and a SKILL.md almost always ends in one; that single byte is not
# cosmetic when the match is an exact SHA-256. The sentinel is the standard
# fix: append a byte the stripping cannot remove, then remove it by hand.
pn_collect_skill_content() {
  local path="${1:-}"
  PN_SKILL_CONTENT=""
  PN_SKILL_SHA=""
  [[ -r "$path" ]] || return 1

  local out
  out=$(cat "$path" 2>/dev/null; printf 'x')
  PN_SKILL_CONTENT="${out%x}"
  [[ -n "$PN_SKILL_CONTENT" ]] || return 1

  # Hashed from the content itself, never from the file as a separate read, so
  # the digest and the body can never disagree — the server re-hashes what it
  # receives and rejects a mismatch outright.
  #
  # Three tools because no single one is present everywhere: shasum ships with
  # macOS, sha256sum with most Linux distributions, openssl is the fallback.
  # No digest downgrades the report to unmatched rather than dropping it.
  if command_exists shasum; then
    PN_SKILL_SHA=$(printf '%s' "$PN_SKILL_CONTENT" | shasum -a 256 2>/dev/null | awk '{print $1}')
  elif command_exists sha256sum; then
    PN_SKILL_SHA=$(printf '%s' "$PN_SKILL_CONTENT" | sha256sum 2>/dev/null | awk '{print $1}')
  elif command_exists openssl; then
    PN_SKILL_SHA=$(printf '%s' "$PN_SKILL_CONTENT" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')
  fi
  return 0
}

# pn_skill_declared_name <skill_md_path>
# Prints the `name:` declared in a SKILL.md's frontmatter, or nothing.
#
# Only the first lines are read: frontmatter sits at the top, and a skill body
# can be tens of kilobytes that this has no reason to touch.
pn_skill_declared_name() {
  sed -n '1,30p' "${1:-}" 2>/dev/null \
    | grep -m1 '^name:[[:space:]]*' \
    | sed -e 's/^name:[[:space:]]*//' -e 's/^["'"'"']//' -e 's/["'"'"']$//' -e 's/[[:space:]]*$//'
}

# pn_resolve_skill_by_declared_name <skill_name> <workspace_root>
# The fallback for when no DIRECTORY carries the invoked name: scans the same
# locations and matches each SKILL.md's own declared `name:` instead.
#
# The Agent Skills standard expects a skill's directory to be named after it
# (our registry's NormalizeSkillDirName exists for exactly that check, case- and
# underscore-insensitively), and every skill observed on a real machine obeys
# it. But nothing FORCES it, and a skill whose folder was renamed would resolve
# to nothing through the directory path — the use would then go unrecorded
# silently, which is the one failure mode worth spending a directory scan on.
#
# Deliberately the second choice, not the first: reading every skill's
# frontmatter on every slash command would cost a scan for each "/undo" too.
# This runs only once the cheap path has already missed.
pn_resolve_skill_by_declared_name() {
  local name="${1:-}" workspace="${2:-}"
  PN_SKILL_PATH=""
  [[ -n "$name" ]] || return 1

  # Same normalization the registry applies, so "My_Skill" and "my-skill" are
  # one name here too.
  local wanted
  wanted=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

  local had_nullglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  local roots=()
  [[ -n "$workspace" ]] && roots+=("${workspace%/}"/.cursor/skills/*/SKILL.md "${workspace%/}"/.claude/skills/*/SKILL.md)
  roots+=("${HOME}"/.cursor/skills/*/SKILL.md "${HOME}"/.cursor/skills-cursor/*/SKILL.md "${HOME}"/.claude/skills/*/SKILL.md)
  roots+=("${HOME}"/.cursor/plugins/cache/*/*/*/skills/*/SKILL.md)
  [[ $had_nullglob -eq 1 ]] || shopt -u nullglob

  local candidate declared
  for candidate in "${roots[@]}"; do
    [[ -r "$candidate" ]] || continue
    declared=$(pn_skill_declared_name "$candidate")
    [[ -n "$declared" ]] || continue
    declared=$(printf '%s' "$declared" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    if [[ "$declared" == "$wanted" ]]; then
      PN_SKILL_PATH="$candidate"
      return 0
    fi
  done
  return 1
}

# pn_skill_declares_name <skill_md_path> <expected_name>
# True when the file's own frontmatter declares that name, or declares none at
# all (in which case its directory is the only identity it has, so a directory
# match stands).
#
# This is what stops a directory hit from being trusted on its own — see
# pn_resolve_skill_path. Compared with the registry's own normalization
# (NormalizeSkillDirName: lowercased, underscores mapped to hyphens) so one
# skill is never two names.
pn_skill_declares_name() {
  local path="${1:-}" expected="${2:-}"
  local declared
  declared=$(pn_skill_declared_name "$path")
  # No declared name: nothing contradicts the directory, so accept it.
  [[ -n "$declared" ]] || return 0
  declared=$(printf '%s' "$declared" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
  expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
  [[ "$declared" == "$expected" ]]
}
