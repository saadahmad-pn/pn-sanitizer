# Cursor Plugin Marketplace Readiness Audit

**Date:** 2026-08-11  
**Plugin:** pn-sanitizer  
**Status:** NOT READY FOR SUBMISSION  

This audit evaluates the plugin for public Cursor marketplace submission. Findings are ordered by severity (P0 highest). See "Blocking for submission" at the end for go/no-go criteria.

---

## Critical Findings (P0)

### P0-1: jq dependency missing error handling causes invalid JSON output
**File:** scripts/lib/common.sh:151-152, 161, 173, 188, 197  
**Severity:** P0 — Security plugin returns malformed JSON on missing dependency  
**What's wrong:** Functions like `json_permission_allow()` and `json_session_context()` call `jq -Rs .` to escape user-provided text. When jq is unavailable or fails, the piped string is lost and the JSON is malformed.

**Test result:**
```bash
# With jq disabled
$ PATH=/tmp/no-jq-path:/usr/bin:/bin bash -c '
  source scripts/lib/common.sh
  json_permission_allow "test message"'
{"permission": "allow", "user_message": }
```
The output is invalid JSON — missing the closing quote on `user_message`. Cursor will reject this as a hook failure and allow/deny based on `failClosed` setting.

**Consequence:** When users don't have jq installed, hook scripts return invalid JSON. Depending on hook settings, this either silently allows everything through (beforeSubmitPrompt is failClosed: false) or blocks everything (preToolUse has no failClosed, defaults to fail-open). Either way, the security invariant breaks.

**Fix:** 
1. Add a fallback in each json_* function that does NOT depend on jq. For simple cases, use bash's built-in string escaping:
   ```bash
   json_permission_allow() {
     local message="${1:-}"
     if [[ -z "$message" ]]; then
       echo '{"permission": "allow"}'
     else
       # Escape quotes without jq
       message="${message//\\/\\\\}"
       message="${message//\"/\\\"}"
       printf '{"permission": "allow", "user_message": "%s"}\n' "$message"
     fi
   }
   ```
2. Or: require jq explicitly in check-session.sh and fail the hook cleanly if missing (currently it tries to call jq after reporting the missing-jq error).

**Blocking:** YES

---

### P0-2: Broken bash-only URL encoding fallback in login.sh
**File:** scripts/login.sh:38-45  
**Severity:** P0 — Login fails when Python3 is unavailable  
**What's wrong:** The fallback URL encoder at line 40 uses `${i//?/\%21}`, where `?` is a bash glob matching any single character. This replaces **every character** with the literal string `\%21`.

**Test result:**
```bash
string="http://example.com/path?foo=bar"
i="${i//?/\%21}"
# Result: \%21\%21\%21\%21\%21\%21\%21\%21\%21\%21\%21\%21\%21... (37 repetitions)
```

**Consequence:** When Python3 is unavailable and the bash fallback runs, all URLs become completely mangled, e.g. `http://acme.paradigmnetworks.ai` becomes `\%21\%21\%21...`. The OAuth flow fails immediately.

**Fix:** Replace the fallback with a correct implementation:
```bash
# Safe bash-only URL encoding
urlencode_fallback() {
  local string="$1"
  local i=0
  local result=""
  while [ $i -lt ${#string} ]; do
    c="${string:$i:1}"
    case "$c" in
      [a-zA-Z0-9._~-]) result="$result$c" ;;
      *) printf -v result '%s%%%02x' "$result" "'$c" ;;
    esac
    i=$((i+1))
  done
  echo "$result"
}
```

Alternatively, bundle a pre-compiled `jq` binary or use only Python if available (require it explicitly).

**Blocking:** YES

---

### P0-3: Hooks do not guard against TTY stdin or Windows bash before reading stdin
**File:** scripts/check-prompt.sh:19-20, scripts/check-write.sh:25-27  
**Severity:** P0 — Hook hangs indefinitely on Cursor/Windows or broken TTYs  
**What's wrong:** Both `check-prompt.sh` and `check-write.sh` call `payload=$(cat 2>/dev/null)` without checking if stdin is a TTY or if running on Windows. Under git-bash on Windows (MINGW/MSYS), this hangs the hook indefinitely waiting for keyboard input.

**Consequence:** A Windows developer opens Cursor, triggers beforeSubmitPrompt or preToolUse, and the hook times out. The action is allowed through (fail-open) or blocked (fail-closed), but the hook is broken.

**Current guard in check-session.sh (lines 14-16):**
```bash
if [[ ! -t 0 ]]; then
  stdin_data=$(cat 2>/dev/null)
fi
```
This is only a partial guard — it only drains stdin if it's NOT a TTY, but doesn't detect Windows or skip the read on Windows.

**Fix:** Add at the top of both scripts:
```bash
# Fail gracefully on Windows or when stdin is a TTY (would hang)
if [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]] || [[ "$(uname -s)" == CYGWIN* ]] || [ -t 0 ]; then
  json_deny "Hook not supported in this environment (Windows or broken TTY)"
  exit 0
fi

# Safe stdin read
payload=$(cat 2>/dev/null)
```

**Blocking:** YES

---

### P0-4: curl -F with untrusted content allows arbitrary file exfiltration
**File:** scripts/lib/common.sh:77, scripts/check-prompt.sh:58, scripts/check-write.sh:103  
**Severity:** P0 — An agent response containing `@/etc/passwd` reads and sends that file  
**What's wrong:** The `http_post_form()` function uses `curl -s -X POST "$url" -F "text=$text_data"`. In curl, the `-F` flag interprets values starting with `@` as file references and reads them. An agent's response beginning with `@/etc/passwd` would cause curl to read and exfiltrate that file to the scan API.

**Example:**
```bash
agent_message="@/etc/passwd - here's a file I want to write"
curl -F "text=$agent_message" ...
# Curl reads and sends /etc/passwd contents
```

**Consequence:** A malicious or confused agent that outputs `@<filename>` causes local file contents to be sent to the scan API without the user's knowledge.

**Fix:** Use `--form-string` instead of `-F`:
```bash
http_post_form() {
  local url="$1"
  local text_data="$2"
  local auth_token="$3"
  local timeout="${4:-5}"

  curl -s -X POST "$url" \
    ${auth_token:+-H "Authorization: Bearer $auth_token"} \
    --form-string "text=$text_data" \
    --max-time "$timeout" \
    2>/dev/null
}
```
`--form-string` treats the value as literal and does not interpret `@` prefixes.

**Blocking:** YES

---

## Major Findings (P1)

### P1-1: No .gitattributes file; scripts get CRLF on Windows checkout
**File:** Repository root — no .gitattributes  
**Severity:** P1 — All scripts break on Windows  
**What's wrong:** A user on Windows who clones the repo via git gets CRLF line endings (Windows default). Every `#!/bin/bash` shebang becomes `#!/bin/bash\r\n`, which is not recognized as a valid shebang. Bash tries to find an executable named `bash\r` and fails.

**Consequence:** Plugin is completely non-functional on Windows.

**Fix:** Create `.gitattributes` at the repo root:
```
*.sh text eol=lf
*.mdc text eol=lf
```
Then commit with `git add -A && git commit`, and future Windows clones will get LF endings.

**Blocking:** YES

---

### P1-2: date command %3N produces invalid output on macOS
**File:** scripts/lib/common.sh:95  
**Severity:** P1 — Timestamps are corrupted on macOS  
**What's wrong:** The log_debug function uses `date '+%Y-%m-%d %H:%M:%S.%3N'`, where `%3N` should produce 3-digit milliseconds. On macOS (BSD date), `%3N` is not recognized and outputs literally: `2026-08-11 03:29:17.3N`.

**Test result:**
```bash
$ date '+%Y-%m-%d %H:%M:%S.%3N'
2026-08-11 03:29:17.3N
```

**Consequence:** Debug logs have malformed timestamps. If logs are later used for forensics, they are unreliable.

**Fix:** Use a format that works on both Linux (GNU date) and macOS (BSD date):
```bash
log_debug() {
  local message="$1"
  local log_path="${2:-}"
  [[ -z "$log_path" ]] && return 0

  # GNU/BSD compatible timestamp
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  # Add milliseconds if available (GNU date only)
  if date '+%3N' &>/dev/null | grep -qv 'N'; then
    timestamp="$timestamp.$(date '+%3N')"
  fi

  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
  echo "[$timestamp] $message" >> "$log_path"
}
```
Or use `date '+%s%N'` (epoch nanoseconds) on both platforms.

**Blocking:** YES (for macOS users)

---

### P1-3: Documentation still references non-existent .py files
**File:** README.md, rules/pn-login-check.mdc, skills/pn-login/SKILL.md  
**Severity:** P1 — Agent-facing instructions break the login flow  
**What's wrong:** After the Python-to-Bash conversion, documentation was not fully updated. Multiple agent-facing instructions still reference files that no longer exist:

**Occurrences:**
- README.md:25 — "tells the agent how to run login.py"
- rules/pn-login-check.mdc:13 — "check-session.py (sessionStart)"
- rules/pn-login-check.mdc:16 — "check-prompt.py (beforeSubmitPrompt)"
- rules/pn-login-check.mdc:26 — "pn_config.py"
- rules/pn-login-check.mdc:38-39 — "check-prompt.py and check-response.py fail open"
- rules/pn-login-check.mdc:59 — "check-prompt.py and check-response.py fail open"
- skills/pn-login/SKILL.md:10 — (same reference pattern)

**Consequence:** When the agent reads the rule or skill, it receives instructions to import or reference Python files that don't exist. If the agent tries to follow the instructions (e.g., "import pn_config.py" or "run check-prompt.py"), the login flow fails with a "file not found" error.

**Fix:** Update all references from `.py` to `.sh`:
```markdown
- `check-session.sh` (`sessionStart`) injects context asking...
- `check-prompt.sh` (`beforeSubmitPrompt`) ...
- `pn_config.sh` ...
- `check-prompt.sh`/`check-response.sh` fail open...
```

**Blocking:** YES (agent-facing instructions are broken)

---

### P1-4: Inconsistent failure posture between hooks
**File:** scripts/check-prompt.sh, scripts/check-write.sh, hooks/hooks.json  
**Severity:** P1 — Security model is unclear and inconsistent  
**What's wrong:**
- **check-prompt.sh:** Fails open on all errors (timeout, unreachable, not configured, invalid JSON). Line 35, 65, 70, 77.
- **check-write.sh:** Has `FAILURE_MODE=closed` by default (line 17), which blocks writes when the API is unreachable or PN is not configured.
- **hooks/hooks.json:** Only `sessionStart` has `failClosed: false`. `beforeSubmitPrompt` has no `failClosed` (defaults fail-open). `preToolUse` has no `failClosed` (defaults fail-open per Cursor contract).

**Consequence:** A user without PN configured:
- Submitting a prompt → hook fails open, prompt goes through (safe)
- Writing a file → hook fails closed (per FAILURE_MODE=closed), write is blocked (conservative)

This is confusing and inconsistent. Is the plugin meant to "fail safe" (allow when unsure) or "fail secure" (block when unsure)?

**Fix:** Clarify and document the intended posture in README.md. Options:
1. **Fail-safe (current implicit):** Allow everything when PN is not configured or API is unreachable. Requires explicit configuration to enable blocking.
2. **Fail-secure (safer for a security plugin):** Block everything when PN is not configured. Require explicit opt-in to "fail open."

Choose one and apply it consistently across all three hooks.

**Blocking:** YES (security posture must be explicit)

---

### P1-5: check-write.sh tool name validation is unverified
**File:** scripts/check-write.sh:37-42  
**Severity:** P1 — Silent total security bypass if tool names are wrong  
**What's wrong:** The script checks:
```bash
if [[ "$tool_name" != "Write" ]] && [[ "$tool_name" != "Edit" ]]; then
  json_permission_allow
  return 0
fi
```
The tool names "Write" and "Edit" are **unverified**. They are assumed to match Cursor's actual tool names in the hook payload, but:
1. Cursor's documentation is not provided.
2. No test verifies what the actual tool_name values are.
3. If Cursor uses different casing (e.g., "write", "WRITE") or different names (e.g., "FileWrite", "EditFile"), the bypass is silent and total.

**Consequence:** If tool names don't match, every Write/Edit call is silently allowed without scanning, completely defeating the security model.

**Fix:** 
1. Add a debug log line showing the actual tool_name received.
2. Test against a live Cursor instance to verify actual tool names.
3. In Phase 2, add an explicit validation/logging step that flags unexpected tool names.

**Blocking:** YES (UNVERIFIED assumption in security logic)

---

### P1-6: Response field names (snake_case vs camelCase) are unverified
**File:** Multiple  
**Severity:** P1 — Silently dropped messages if field names are wrong  
**What's wrong:** Hook scripts emit `user_message` and `agent_message` in snake_case:
```bash
json_permission_deny "$user_message" "$agent_message"
# Output: {"permission": "deny", "user_message": "...", "agent_message": "..."}
```
Some documentation or comments reference `userMessage` and `agentMessage` in camelCase, suggesting uncertainty about the correct format.

**Consequence:** If Cursor's hook contract expects camelCase, the messages are silently dropped and the user sees no error message or agent guidance.

**Fix:** Verify the correct field names by:
1. Testing against a live Cursor instance with a known message.
2. Checking Cursor's official hook documentation (not included here).
3. Committing the result to a comment in the scripts.

**Blocking:** YES (UNVERIFIED contract)

---

### P1-7: PHASE3-REPORT.md is internal documentation that should not ship
**File:** test/PHASE3-REPORT.md  
**Severity:** P1 — Non-production artifact in published code  
**What's wrong:** The test directory contains `PHASE3-REPORT.md`, which is internal documentation from the Python-to-Bash conversion effort. It should not be included in the marketplace plugin.

**Consequence:** Marketplace reviewers see internal engineering notes and conclude the codebase is not production-ready.

**Fix:** Delete the file or add it to `.gitignore` if it's useful for local development.

**Blocking:** YES

---

### P1-8: Test script permissions are not executable
**File:** test/test-utils.sh, test/mock-server.sh  
**Severity:** P1 — Tests cannot be run from CI/CD  
**What's wrong:** Both files are world-readable but not executable:
```
-rw-r--r-- test-utils.sh
-rw-r--r-- mock-server.sh
```

**Consequence:** A CI/CD pipeline or user running `bash test/run-all-tests.sh` will fail when trying to source or execute these files (if they're meant to be executable).

**Fix:** Commit the executable bit:
```bash
git update-index --chmod=+x test/test-utils.sh test/mock-server.sh
git commit -m "Add executable bit to test utilities"
```

**Blocking:** NO (low impact if tests are sourced via `source`, but good practice)

---

### P1-9: urlencode() in common.sh still depends on python3
**File:** scripts/lib/common.sh:226-230  
**Severity:** P1 — Fallback is incomplete; Python 3 dependency remains  
**What's wrong:** The `urlencode()` function tries Python first and falls back to a sed hack:
```bash
urlencode() {
  python3 -c "import urllib.parse; print(urllib.parse.quote('$string'))" 2>/dev/null || \
  echo "$string" | sed 's/ /%20/g'
}
```
The sed fallback only handles spaces, not other characters. If Python 3 is unavailable and the string contains `&`, `=`, `+`, etc., those are not encoded.

**Consequence:** While `login.sh` has its own `urlencode_strict()` function (which we've already flagged for the bash fallback bug), `common.sh`'s `urlencode()` is a liability. It's currently unused, but if it were called with untrusted input, it would produce incorrect output.

**Fix:** 
1. Delete `urlencode()` if it's unused (check with `grep -r "urlencode[^_]"` to exclude `urlencode_strict`).
2. If it must exist, fix the fallback to handle all URL-unsafe characters correctly, or require Python.

**Blocking:** NO (low severity if unused)

---

## Documentation and Structure (P2)

### P2-1: Incomplete manifest
**File:** .cursor-plugin/plugin.json  
**Severity:** P2 — Marketplace submission incomplete  
**What's wrong:** The manifest is missing standard metadata fields:
- `displayName` — What users see in the marketplace (currently only `name` "pn-sanitizer")
- `logo` — Icon for the marketplace listing
- `homepage` — Link to project or docs
- `category` — e.g., "security", "productivity"
- `tags` — Searchable keywords
- `publisher` — Organization name (currently author.name is a GitHub handle "saadahmad-pn", not an organization)
- `minClientVersions` — Minimum Cursor version supported
- `description` starts with "Snantizer:" (typo, should be "Paradigm")

**Consequence:** Plugin looks unprofessional and is hard to discover on the marketplace.

**Fix:** Expand the manifest:
```json
{
  "name": "pn-sanitizer",
  "displayName": "Paradigm Networks Security Scanner",
  "description": "Gates prompts and file writes through the Paradigm Networks security scanner API.",
  "version": "0.1.0",
  "author": {
    "name": "Paradigm Networks"
  },
  "publisher": "Paradigm Networks",
  "homepage": "https://github.com/saadahmad-pn/pn-sanitizer",
  "repository": "https://github.com/saadahmad-pn/pn-sanitizer",
  "license": "MIT",
  "keywords": ["security", "code-scanning", "prompt-guard"],
  "category": "security",
  "tags": ["CodeDefense", "policy", "compliance"],
  "minClientVersions": {
    "desktop": "0.1.0"
  },
  ...
}
```

**Blocking:** NO (marketplace review can flag, but not a code issue)

---

### P2-2: "Snantizer" typo appears in description and README title
**File:** .cursor-plugin/plugin.json:3, README.md:1  
**Severity:** P2 — Unprofessional branding  
**What's wrong:** The plugin is called "pn-sanitizer" (correct) but referred to as "Snantizer" in the manifest and README, which appears to be a typo or acronym mistake. The brand name should be "Paradigm Networks" or "PN Scanner", not "Snantizer".

**Fix:** Replace "Snantizer" with "Paradigm Networks" or "PN Scanner" throughout.

**Blocking:** NO (branding, not functionality)

---

### P2-3: Rules and skills may reference incorrect $CURSOR_PLUGIN_ROOT variable
**File:** rules/pn-login-check.mdc:25-26, skills/pn-login/SKILL.md:36  
**Severity:** P2 — UNVERIFIED instructions; may not work as documented  
**What's wrong:** Both the rule and skill instruct the agent:
> "there is no environment variable that tells you where [the plugin] is installed, so path-guessing isn't reliable"

They then recommend finding the plugin by searching `~/.cursor/plugins/`. However, according to the ground-truth section above, `$CURSOR_PLUGIN_ROOT` **is** an available environment variable that identifies the plugin install location.

**Consequence:** 
1. If `$CURSOR_PLUGIN_ROOT` is available, the instructions are unnecessarily complicated.
2. If it's not available, the instructions are correct, but this is UNVERIFIED.

**Fix:** Test whether `$CURSOR_PLUGIN_ROOT` is available in a live hook script. If it is, simplify the instructions. If not, document that fact.

**Blocking:** UNVERIFIED (requires testing against real Cursor)

---

### P2-4: Skills and rules invoke "AskQuestion" tool; tool name unverified
**File:** rules/pn-login-check.mdc:41, skills/pn-login/SKILL.md:41  
**Severity:** P2 — UNVERIFIED tool name; instructions may fail  
**What's wrong:** Both documents instruct the agent to call the `AskQuestion` tool:
```markdown
**Actually invoke the `AskQuestion` tool for this**
```
This tool name is not verified against Cursor's actual tool registry.

**Consequence:** If the correct tool name is different (e.g., `AskUserQuestion`, `ShowOptions`), the agent's instructions fail and the login flow breaks.

**Fix:** Verify the correct tool name in Cursor's documentation or test it live.

**Blocking:** UNVERIFIED (requires testing)

---

### P2-5: Default branch is develop; marketplace uses default branch
**File:** .git (repository)  
**Severity:** P2 — Published plugin may not be the intended version  
**What's wrong:** The repository's default branch is `develop`, not `main`. When the Cursor marketplace indexes this repo, it will pull from `develop`, not `main`. If `develop` is not production-ready, the marketplace version will be broken.

**Consequence:** Marketplace users get an unstable version if changes are not merged to `develop` before publishing.

**Fix:** Either:
1. Set `main` as the default branch and merge `develop` → `main` before publishing.
2. Create a `release` or `published` branch for marketplace versions.
3. Document that `develop` is the stable branch (non-standard).

**Blocking:** NO (workflow choice, but important to clarify)

---

## Dependency and Cross-Platform Analysis (P3)

### P3-1: jq is the single hard dependency; installation burden
**File:** All hook scripts, test scripts  
**Severity:** P3 — Required dependency not provided or bundled  
**What's wrong:** Every hook script and test depends on `jq`, which is not pre-installed on:
- macOS (requires Homebrew or manual installation)
- Windows (requires WSL or git-bash with MSYS2 package)
- Linux (varies by distro, often requires `apt-get install jq`, etc.)

**Consequence:** Users who don't have `jq` get unclear error messages and hooks fail. First-time setup is slower.

**Options:**
1. **Require jq**: Document it prominently in README with installation instructions per platform. Accept that some users will skip the plugin if installing dependencies is too cumbersome.
2. **Bundle jq**: Include a pre-compiled jq binary in `scripts/bin/jq` and reference it by full path. Adds ~5-10 MB to the plugin but eliminates the dependency.
3. **Replace jq**: Rewrite JSON parsing and generation in pure bash (very complex, error-prone).
4. **MCP daemon approach**: Move JSON parsing to a local daemon written in Go or Python that can bundle its own dependencies.

**Current state:** Requires jq; no fallback.

**Blocking:** NO (dependency management is a design choice)

---

### P3-2: alwaysApply: true on rules adds context cost to every request
**File:** rules/pn-login-check.mdc:3  
**Severity:** P3 — Performance impact  
**What's wrong:** The rule uses `alwaysApply: true`, which means Cursor injects the entire rule (~2.5 KB) into the system prompt for every single request in every workspace where this plugin is installed.

**Consequence:** Every request's context is reduced by ~2.5 KB, which may impact quality for long-context conversations. This adds up across all users.

**Fix:** Either:
1. Remove `alwaysApply: true` and let the agent/user explicitly request login help when needed.
2. Add a glob pattern to limit when the rule applies (e.g., only on the first message of a session, or only when a certain hook has failed).
3. Reduce the rule size by moving detailed instructions to the skill/agent documentation instead.

**Blocking:** NO (optimization, not a blocker)

---

## Unverified Assumptions

These cannot be resolved in Phase 1 audit without testing against a live Cursor instance:

1. **Tool names in hook payloads**: Is the tool name really "Write" and "Edit"? (check-write.sh:37)
2. **Hook response field names**: Are they `user_message`/`agent_message` (snake_case) or `userMessage`/`agentMessage` (camelCase)?
3. **`$CURSOR_PLUGIN_ROOT` availability**: Is this variable actually available to hook scripts? (rules/pn-login-check.mdc:25)
4. **AskQuestion tool name**: What is the correct tool name to invoke a dialog? (rules/pn-login-check.mdc:41)
5. **Cursor Windows support**: Do Cursor's hooks on Windows work with git-bash, WSL, or native bash?
6. **Cursor macOS netcat compatibility**: Does `nc -z` and `nc -l` work correctly on macOS as written in login.sh?

---

## Manifest and Metadata Gaps

### Missing files that are standard for published projects
- `CHANGELOG.md` — Version history
- `SECURITY.md` — Security policy (important for a security plugin)
- `CONTRIBUTING.md` — How to contribute
- `CODEOWNERS` — Maintenance responsibilities

**Not blocking but expected by marketplace reviewers.**

---

---

## Blocking for Submission

The following **must** be fixed before marketplace submission:

1. **P0-1:** jq missing error handling — functions output invalid JSON when jq unavailable
2. **P0-2:** bash fallback urlencode_strict completely broken — mangles all URLs when Python3 absent
3. **P0-3:** No Windows/TTY guards in check-prompt.sh and check-write.sh — hooks hang on Windows
4. **P0-4:** curl -F allows arbitrary file exfiltration with @ prefix — use --form-string
5. **P1-1:** No .gitattributes — scripts get CRLF on Windows, breaking shebangs
6. **P1-2:** date %3N doesn't work on macOS — timestamps corrupted on Apple hardware
7. **P1-3:** Documentation references non-existent .py files — agent-facing instructions fail
8. **P1-4:** Inconsistent failure posture — security model unclear (fail-safe vs fail-secure)
9. **P1-5:** Tool name validation unverified — silent bypass if tool names don't match
10. **P1-6:** Response field names unverified — messages silently dropped if format wrong
11. **P1-7:** PHASE3-REPORT.md should not ship — internal documentation
12. **P1-8:** Test script permissions missing — test/test-utils.sh and mock-server.sh not executable

---

## Open Questions to Verify Empirically

1. **What are the actual tool names in Cursor's hook payloads?** Symlink the plugin into `~/.cursor/plugins/local/`, trigger a Write tool, and capture the payload in check-write.sh to verify tool_name value.

2. **What are the actual field names Cursor expects in hook responses?** Send a hook response with both snake_case and camelCase fields and verify which one Cursor reads.

3. **Is `$CURSOR_PLUGIN_ROOT` available to hook scripts?** Check whether the variable is set when hooks run; if so, simplify rule/skill instructions.

4. **What is the correct tool name to invoke a dialog from the agent?** Verify in Cursor documentation or test a skill that calls it.

5. **Does login.sh work on macOS with the current nc implementation?** Test the full OAuth flow on macOS to verify port detection and callback handling.

6. **Does Cursor run hooks on Windows, and if so, with what shell?** Test on Cursor/Windows to verify whether git-bash, WSL, or native Windows bash is used.

7. **Does `$CURSOR_PLUGIN_ROOT` point to the right location in both local and marketplace installs?** Verify the variable contents in `.cursor/plugins/local/` vs `.cursor/plugins/cache/`.

---

