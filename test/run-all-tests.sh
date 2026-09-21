#!/bin/bash
# Master test runner - runs all test suites and generates report

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Phase 3: Comprehensive Test Suite                          ║${NC}"
echo -e "${BLUE}║  Python → Bash Conversion Validation                        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
FAILED_SUITES=()

# Test Suite 1: Unit Tests
echo -e "${BLUE}[1/7]${NC} Running Unit Tests..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
"$TEST_DIR/test-unit.sh" > /tmp/unit-test.log 2>&1
unit_status=$?
unit_passed=$(grep "Passed:" /tmp/unit-test.log | awk '{print $2}')
unit_total=$(grep "Total:" /tmp/unit-test.log | awk '{print $2}')
unit_failed=$(grep "Failed:" /tmp/unit-test.log | awk '{print $2}')
# Always accumulate real assertion counts from the log, whether the suite
# passed or not -- test_summary prints Total/Passed/Failed either way, so
# a failing suite's actual counts are available and shouldn't be replaced
# with a flat "1 suite failed" that hides how many assertions ran.
TOTAL_TESTS=$((TOTAL_TESTS + ${unit_total:-0}))
TOTAL_PASSED=$((TOTAL_PASSED + ${unit_passed:-0}))
TOTAL_FAILED=$((TOTAL_FAILED + ${unit_failed:-0}))
if [[ $unit_status -eq 0 ]]; then
  echo -e "${GREEN}✓ Unit Tests: $unit_passed/$unit_total passed${NC}"
else
  echo -e "${RED}✗ Unit Tests failed ($unit_passed/$unit_total passed)${NC}"
  FAILED_SUITES+=("Unit Tests")
fi
echo ""

# Test Suite 2: Integration Tests
echo -e "${BLUE}[2/7]${NC} Running Integration Tests..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
"$TEST_DIR/test-hooks.sh" > /tmp/integration-test.log 2>&1
int_status=$?
int_passed=$(grep "Passed:" /tmp/integration-test.log | awk '{print $2}')
int_total=$(grep "Total:" /tmp/integration-test.log | awk '{print $2}')
int_failed=$(grep "Failed:" /tmp/integration-test.log | awk '{print $2}')
TOTAL_TESTS=$((TOTAL_TESTS + ${int_total:-0}))
TOTAL_PASSED=$((TOTAL_PASSED + ${int_passed:-0}))
TOTAL_FAILED=$((TOTAL_FAILED + ${int_failed:-0}))
if [[ $int_status -eq 0 ]]; then
  echo -e "${GREEN}✓ Integration Tests: $int_passed/$int_total passed${NC}"
else
  echo -e "${RED}✗ Integration Tests failed ($int_passed/$int_total passed)${NC}"
  FAILED_SUITES+=("Integration Tests")
fi
echo ""

# Test Suite 2b: Git Event Detection Tests (lib/git-utils.sh resolvers,
# lib/detection-client.sh, check-git-event.sh)
echo -e "${BLUE}[3/7]${NC} Running Git Event Detection Tests..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
"$TEST_DIR/test-git-event.sh" > /tmp/git-event-test.log 2>&1
gitevent_status=$?
gitevent_passed=$(grep "Passed:" /tmp/git-event-test.log | awk '{print $2}')
gitevent_total=$(grep "Total:" /tmp/git-event-test.log | awk '{print $2}')
gitevent_failed=$(grep "Failed:" /tmp/git-event-test.log | awk '{print $2}')
TOTAL_TESTS=$((TOTAL_TESTS + ${gitevent_total:-0}))
TOTAL_PASSED=$((TOTAL_PASSED + ${gitevent_passed:-0}))
TOTAL_FAILED=$((TOTAL_FAILED + ${gitevent_failed:-0}))
if [[ $gitevent_status -eq 0 ]]; then
  echo -e "${GREEN}✓ Git Event Detection Tests: $gitevent_passed/$gitevent_total passed${NC}"
else
  echo -e "${RED}✗ Git Event Detection Tests failed ($gitevent_passed/$gitevent_total passed)${NC}"
  FAILED_SUITES+=("Git Event Detection Tests")
fi
echo ""

# Test Suite 3b: Code Chain Recording Tests (lib/codechain-client.sh,
# get_current_turn_messages)
echo -e "${BLUE}[4/7]${NC} Running Code Chain Recording Tests..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
"$TEST_DIR/test-codechain-client.sh" > /tmp/codechain-client-test.log 2>&1
codechain_status=$?
codechain_passed=$(grep "Passed:" /tmp/codechain-client-test.log | awk '{print $2}')
codechain_total=$(grep "Total:" /tmp/codechain-client-test.log | awk '{print $2}')
codechain_failed=$(grep "Failed:" /tmp/codechain-client-test.log | awk '{print $2}')
TOTAL_TESTS=$((TOTAL_TESTS + ${codechain_total:-0}))
TOTAL_PASSED=$((TOTAL_PASSED + ${codechain_passed:-0}))
TOTAL_FAILED=$((TOTAL_FAILED + ${codechain_failed:-0}))
if [[ $codechain_status -eq 0 ]]; then
  echo -e "${GREEN}✓ Code Chain Recording Tests: $codechain_passed/$codechain_total passed${NC}"
else
  echo -e "${RED}✗ Code Chain Recording Tests failed ($codechain_passed/$codechain_total passed)${NC}"
  FAILED_SUITES+=("Code Chain Recording Tests")
fi
echo ""

# Test Suite 4b: Scan Client Tests (lib/scan-client.sh, the
# POST /api/v1/codedefense/scan client used by check-prompt.sh/check-write.sh)
echo -e "${BLUE}[5/7]${NC} Running Scan Client Tests..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
"$TEST_DIR/test-scan-client.sh" > /tmp/scan-client-test.log 2>&1
scan_status=$?
scan_passed=$(grep "Passed:" /tmp/scan-client-test.log | awk '{print $2}')
scan_total=$(grep "Total:" /tmp/scan-client-test.log | awk '{print $2}')
scan_failed=$(grep "Failed:" /tmp/scan-client-test.log | awk '{print $2}')
TOTAL_TESTS=$((TOTAL_TESTS + ${scan_total:-0}))
TOTAL_PASSED=$((TOTAL_PASSED + ${scan_passed:-0}))
TOTAL_FAILED=$((TOTAL_FAILED + ${scan_failed:-0}))
if [[ $scan_status -eq 0 ]]; then
  echo -e "${GREEN}✓ Scan Client Tests: $scan_passed/$scan_total passed${NC}"
else
  echo -e "${RED}✗ Scan Client Tests failed ($scan_passed/$scan_total passed)${NC}"
  FAILED_SUITES+=("Scan Client Tests")
fi
echo ""

# Test Suite 5: Error Scenario Tests
echo -e "${BLUE}[6/7]${NC} Running Error Scenario Tests..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
"$TEST_DIR/test-errors.sh" > /tmp/error-test.log 2>&1
err_status=$?
err_passed=$(grep "Passed:" /tmp/error-test.log | awk '{print $2}')
err_total=$(grep "Total:" /tmp/error-test.log | awk '{print $2}')
err_failed=$(grep "Failed:" /tmp/error-test.log | awk '{print $2}')
TOTAL_TESTS=$((TOTAL_TESTS + ${err_total:-0}))
TOTAL_PASSED=$((TOTAL_PASSED + ${err_passed:-0}))
TOTAL_FAILED=$((TOTAL_FAILED + ${err_failed:-0}))
if [[ $err_status -eq 0 ]]; then
  echo -e "${GREEN}✓ Error Scenario Tests: $err_passed/$err_total passed${NC}"
else
  echo -e "${RED}✗ Error Scenario Tests failed ($err_passed/$err_total passed)${NC}"
  FAILED_SUITES+=("Error Scenario Tests")
fi
echo ""

# Suite 6: Dependency Check
echo -e "${BLUE}[7/7]${NC} Checking Dependencies..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
DEPS_OK=true
DEPS_FOUND=()
DEPS_MISSING=()

for cmd in bash curl jq openssl nc; do
  if command -v "$cmd" &>/dev/null; then
    DEPS_FOUND+=("$cmd")
    echo -e "  ${GREEN}✓${NC} $cmd"
  else
    DEPS_MISSING+=("$cmd")
    echo -e "  ${RED}✗${NC} $cmd (missing)"
    DEPS_OK=false
  fi
done

if $DEPS_OK; then
  echo -e "${GREEN}✓ All dependencies available${NC}"
else
  echo -e "${YELLOW}⚠ Some optional dependencies missing (see above)${NC}"
fi
echo ""

# Generate comprehensive report
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Phase 3 Summary                                           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ $TOTAL_FAILED -eq 0 ]]; then
  echo -e "${GREEN}✓ All test suites passed!${NC}"
  echo ""
  echo "Test Results:"
  echo "  Total Tests:  ${TOTAL_TESTS}"
  echo -e "  Passed:       ${GREEN}${TOTAL_PASSED}${NC}"
  echo -e "  Failed:       ${GREEN}0${NC}"
  echo ""
  echo "Test Coverage:"
  echo "  • Unit Tests:              ${unit_total} assertions (lib/common.sh, lib/git-utils.sh, pn_config.sh)"
  echo "  • Integration Tests:       ${int_total} tests (check-session.sh, check-prompt.sh, check-write.sh, check-repo-context.sh)"
  echo "  • Git Event Detection:     ${gitevent_total} tests (git-utils resolvers, detection-client.sh, check-git-event.sh)"
  echo "  • Code Chain Recording:    ${codechain_total} tests (codechain-client.sh, get_current_turn_messages)"
  echo "  • Scan Client:             ${scan_total} tests (scan-client.sh, POST /api/v1/codedefense/scan)"
  echo "  • Error Scenarios:         ${err_total} tests (edge cases, malformed input, file system errors)"
  echo ""
  echo "Dependencies:"
  echo "  Found:   ${#DEPS_FOUND[@]} (${DEPS_FOUND[*]})"
  if [[ ${#DEPS_MISSING[@]} -gt 0 ]]; then
    echo "  Missing: ${#DEPS_MISSING[@]} (${DEPS_MISSING[*]})"
  else
    echo "  Missing: 0"
  fi
  echo ""
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}Phase 3 COMPLETE: All validations passed ✓${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  exit 0
else
  echo -e "${RED}✗ Some test suites failed!${NC}"
  echo ""
  echo "Failed Suites:"
  for suite in "${FAILED_SUITES[@]}"; do
    echo "  • $suite"
  done
  echo ""
  echo "Test Results:"
  echo "  Total Tests:  ${TOTAL_TESTS}"
  echo -e "  Passed:       ${GREEN}${TOTAL_PASSED}${NC}"
  echo -e "  Failed:       ${RED}${TOTAL_FAILED}${NC}"
  echo ""
  echo "Check test logs:"
  echo "  /tmp/unit-test.log"
  echo "  /tmp/integration-test.log"
  echo "  /tmp/git-event-test.log"
  echo "  /tmp/codechain-client-test.log"
  echo "  /tmp/scan-client-test.log"
  echo "  /tmp/error-test.log"
  echo ""
  exit 1
fi
