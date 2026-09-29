#!/bin/bash
# Unit tests for lib/login-detection.sh's pn_is_login_initiation_command
# (PN-12153: exempting the login skill's `bash <path>/login.sh --base-url
# <url>` tool call from the PromptGuard+PolicyEngine+CodeDefense scan).
#
# End-to-end gating behavior (via check-tool-call.sh/check-tool-call-record.sh)
# is covered as integration tests in test-hooks.sh -- this file is unit-level
# only, exercising the matching grammar directly.

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/test-utils.sh"

test_init
source_scripts

echo -e "${BLUE}=== Unit Tests: lib/login-detection.sh (pn_is_login_initiation_command) ===${NC}"

# A real login.sh living where check-tool-call.sh's own SCRIPT_DIR would put
# it -- the function requires the command's path to resolve to exactly
# "$script_dir/login.sh", so the fixture needs a real file at a real path.
FIXTURE_SCRIPT_DIR="$TEST_TEMP_DIR/scripts"
mkdir -p "$FIXTURE_SCRIPT_DIR"
touch "$FIXTURE_SCRIPT_DIR/login.sh"
LOGIN_PATH="$FIXTURE_SCRIPT_DIR/login.sh"

OTHER_DIR="$TEST_TEMP_DIR/elsewhere"
mkdir -p "$OTHER_DIR"
touch "$OTHER_DIR/login.sh"

test_case "Exact skill-documented shape -> matches"
assert_success "pn_is_login_initiation_command Shell 'bash $LOGIN_PATH --base-url https://acme.paradigmnetworks.ai' '$FIXTURE_SCRIPT_DIR'" \
  "bash <path>/login.sh --base-url <url>"

test_case "No interpreter prefix (direct execution) -> matches"
assert_success "pn_is_login_initiation_command Shell '$LOGIN_PATH --base-url https://acme.paradigmnetworks.ai' '$FIXTURE_SCRIPT_DIR'" \
  "<path>/login.sh --base-url <url>"

test_case "Quoted path and quoted URL -> matches"
assert_success "pn_is_login_initiation_command Shell 'bash \"$LOGIN_PATH\" --base-url \"https://acme.paradigmnetworks.ai\"' '$FIXTURE_SCRIPT_DIR'" \
  "quoted tokens still match"

test_case "Base URL with a port -> matches"
assert_success "pn_is_login_initiation_command Shell 'bash $LOGIN_PATH --base-url https://acme.paradigmnetworks.ai:8443' '$FIXTURE_SCRIPT_DIR'" \
  "host:port base URL"

test_case "tool_name is not Shell -> does not match"
assert_failure "pn_is_login_initiation_command MCP:git_commit 'bash $LOGIN_PATH --base-url https://acme.paradigmnetworks.ai' '$FIXTURE_SCRIPT_DIR'" \
  "non-Shell tool_name never qualifies"

test_case "Empty command -> does not match"
assert_failure "pn_is_login_initiation_command Shell '' '$FIXTURE_SCRIPT_DIR'" \
  "empty command"

test_case "Command chaining a second statement (semicolon) -> does not match, falls through to normal scan"
assert_failure "pn_is_login_initiation_command Shell 'bash $LOGIN_PATH --base-url https://acme.paradigmnetworks.ai; rm -rf /' '$FIXTURE_SCRIPT_DIR'" \
  "chained command via ; is rejected, not silently exempted"

test_case "Command chaining via && -> does not match"
assert_failure "pn_is_login_initiation_command Shell 'bash $LOGIN_PATH --base-url https://acme.paradigmnetworks.ai && curl evil.example' '$FIXTURE_SCRIPT_DIR'" \
  "chained command via && is rejected"

test_case "Malicious content smuggled inside the base URL argument -> does not match"
assert_failure "pn_is_login_initiation_command Shell 'bash $LOGIN_PATH --base-url \"https://acme.paradigmnetworks.ai\$(curl evil.example)\"' '$FIXTURE_SCRIPT_DIR'" \
  "command substitution inside the URL token is rejected"

test_case "Extra unexpected flag -> does not match"
assert_failure "pn_is_login_initiation_command Shell 'bash $LOGIN_PATH --base-url https://acme.paradigmnetworks.ai --extra-flag x' '$FIXTURE_SCRIPT_DIR'" \
  "an extra flag beyond --base-url is rejected"

test_case "A file named login.sh outside this installation's own scripts dir -> does not match"
assert_failure "pn_is_login_initiation_command Shell 'bash $OTHER_DIR/login.sh --base-url https://acme.paradigmnetworks.ai' '$FIXTURE_SCRIPT_DIR'" \
  "path must resolve to THIS installation's own login.sh, not a same-named file elsewhere"

test_case "logout.sh -- out of scope for pn_is_login_initiation_command specifically (it's handled by pn_is_logout_command instead)"
touch "$FIXTURE_SCRIPT_DIR/logout.sh"
assert_failure "pn_is_login_initiation_command Shell 'bash $FIXTURE_SCRIPT_DIR/logout.sh --base-url https://acme.paradigmnetworks.ai' '$FIXTURE_SCRIPT_DIR'" \
  "the login-shaped matcher never accepts a logout.sh path"

test_case "Nonexistent script path -> does not match"
assert_failure "pn_is_login_initiation_command Shell 'bash $FIXTURE_SCRIPT_DIR/nope/login.sh --base-url https://acme.paradigmnetworks.ai' '$FIXTURE_SCRIPT_DIR'" \
  "a path that doesn't exist on disk is rejected"

test_case "Ordinary unrelated Shell command -> does not match"
assert_failure "pn_is_login_initiation_command Shell 'npm test' '$FIXTURE_SCRIPT_DIR'" \
  "unrelated commands are unaffected"

echo -e "${BLUE}=== Unit Tests: lib/login-detection.sh (pn_is_logout_command) ===${NC}"

LOGOUT_PATH="$FIXTURE_SCRIPT_DIR/logout.sh"

test_case "Exact skill-documented shape (no arguments) -> matches"
assert_success "pn_is_logout_command Shell 'bash $LOGOUT_PATH' '$FIXTURE_SCRIPT_DIR'" \
  "bash <path>/logout.sh"

test_case "No interpreter prefix (direct execution) -> matches"
assert_success "pn_is_logout_command Shell '$LOGOUT_PATH' '$FIXTURE_SCRIPT_DIR'" \
  "<path>/logout.sh"

test_case "Quoted path -> matches"
assert_success "pn_is_logout_command Shell 'bash \"$LOGOUT_PATH\"' '$FIXTURE_SCRIPT_DIR'" \
  "quoted path still matches"

test_case "tool_name is not Shell -> does not match"
assert_failure "pn_is_logout_command MCP:git_commit 'bash $LOGOUT_PATH' '$FIXTURE_SCRIPT_DIR'" \
  "non-Shell tool_name never qualifies"

test_case "Empty command -> does not match"
assert_failure "pn_is_logout_command Shell '' '$FIXTURE_SCRIPT_DIR'" \
  "empty command"

test_case "logout.sh given an argument -> does not match (it takes none)"
assert_failure "pn_is_logout_command Shell 'bash $LOGOUT_PATH --base-url https://acme.paradigmnetworks.ai' '$FIXTURE_SCRIPT_DIR'" \
  "logout.sh's documented invocation takes no arguments at all"

test_case "Command chaining a second statement (semicolon) -> does not match"
assert_failure "pn_is_logout_command Shell 'bash $LOGOUT_PATH; rm -rf /' '$FIXTURE_SCRIPT_DIR'" \
  "chained command via ; is rejected, not silently exempted"

test_case "Command chaining via && -> does not match"
assert_failure "pn_is_logout_command Shell 'bash $LOGOUT_PATH && curl evil.example' '$FIXTURE_SCRIPT_DIR'" \
  "chained command via && is rejected"

test_case "A file named logout.sh outside this installation's own scripts dir -> does not match"
assert_failure "pn_is_logout_command Shell 'bash $OTHER_DIR/logout.sh' '$FIXTURE_SCRIPT_DIR'" \
  "path must resolve to THIS installation's own logout.sh, not a same-named file elsewhere"

test_case "login.sh -- out of scope for pn_is_logout_command specifically"
assert_failure "pn_is_logout_command Shell 'bash $LOGIN_PATH' '$FIXTURE_SCRIPT_DIR'" \
  "the logout-shaped matcher never accepts a login.sh path"

test_case "Nonexistent script path -> does not match"
assert_failure "pn_is_logout_command Shell 'bash $FIXTURE_SCRIPT_DIR/nope/logout.sh' '$FIXTURE_SCRIPT_DIR'" \
  "a path that doesn't exist on disk is rejected"

test_case "Ordinary unrelated Shell command -> does not match"
assert_failure "pn_is_logout_command Shell 'npm test' '$FIXTURE_SCRIPT_DIR'" \
  "unrelated commands are unaffected"

echo -e "${BLUE}=== Unit Tests: lib/login-detection.sh (pn_login_logout_exempt_reason) ===${NC}"

test_case "Combined check: login.sh invocation -> matches, reason=login_initiation_exempt"
PN_LOGIN_EXEMPT_REASON=""
assert_success "pn_login_logout_exempt_reason Shell 'bash $LOGIN_PATH --base-url https://acme.paradigmnetworks.ai' '$FIXTURE_SCRIPT_DIR'" \
  "wrapper matches the login shape"
pn_login_logout_exempt_reason Shell "bash $LOGIN_PATH --base-url https://acme.paradigmnetworks.ai" "$FIXTURE_SCRIPT_DIR"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$PN_LOGIN_EXEMPT_REASON" == "login_initiation_exempt" ]]; then
  echo -e "  ${GREEN}✓${NC} PN_LOGIN_EXEMPT_REASON=login_initiation_exempt"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} PN_LOGIN_EXEMPT_REASON=login_initiation_exempt (got: $PN_LOGIN_EXEMPT_REASON)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_case "Combined check: logout.sh invocation -> matches, reason=logout_exempt"
assert_success "pn_login_logout_exempt_reason Shell 'bash $LOGOUT_PATH' '$FIXTURE_SCRIPT_DIR'" \
  "wrapper matches the logout shape"
pn_login_logout_exempt_reason Shell "bash $LOGOUT_PATH" "$FIXTURE_SCRIPT_DIR"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$PN_LOGIN_EXEMPT_REASON" == "logout_exempt" ]]; then
  echo -e "  ${GREEN}✓${NC} PN_LOGIN_EXEMPT_REASON=logout_exempt"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} PN_LOGIN_EXEMPT_REASON=logout_exempt (got: $PN_LOGIN_EXEMPT_REASON)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_case "Combined check: unrelated command -> does not match, reason left empty"
PN_LOGIN_EXEMPT_REASON="stale-from-a-previous-call"
assert_failure "pn_login_logout_exempt_reason Shell 'npm test' '$FIXTURE_SCRIPT_DIR'" \
  "wrapper rejects an unrelated command"
pn_login_logout_exempt_reason Shell "npm test" "$FIXTURE_SCRIPT_DIR" || true
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -z "$PN_LOGIN_EXEMPT_REASON" ]]; then
  echo -e "  ${GREEN}✓${NC} PN_LOGIN_EXEMPT_REASON cleared, not left stale from a prior call"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo -e "  ${RED}✗${NC} PN_LOGIN_EXEMPT_REASON cleared (got: $PN_LOGIN_EXEMPT_REASON)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_summary
exit $?
