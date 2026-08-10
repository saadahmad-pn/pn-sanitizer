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
echo -e "${BLUE}[1/4]${NC} Running Unit Tests..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if "$TEST_DIR/test-unit.sh" > /tmp/unit-test.log 2>&1; then
  unit_passed=$(grep "Passed:" /tmp/unit-test.log | awk '{print $2}')
  unit_total=$(grep "Total:" /tmp/unit-test.log | awk '{print $2}')
  echo -e "${GREEN}✓ Unit Tests: $unit_passed/$unit_total passed${NC}"
  TOTAL_TESTS=$((TOTAL_TESTS + unit_total))
  TOTAL_PASSED=$((TOTAL_PASSED + unit_passed))
else
  echo -e "${RED}✗ Unit Tests failed${NC}"
  FAILED_SUITES+=("Unit Tests")
  TOTAL_FAILED=$((TOTAL_FAILED + 1))
fi
echo ""

# Test Suite 2: Integration Tests
echo -e "${BLUE}[2/4]${NC} Running Integration Tests..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if "$TEST_DIR/test-hooks.sh" > /tmp/integration-test.log 2>&1; then
  int_passed=$(grep "Passed:" /tmp/integration-test.log | awk '{print $2}')
  int_total=$(grep "Total:" /tmp/integration-test.log | awk '{print $2}')
  echo -e "${GREEN}✓ Integration Tests: $int_passed/$int_total passed${NC}"
  TOTAL_TESTS=$((TOTAL_TESTS + int_total))
  TOTAL_PASSED=$((TOTAL_PASSED + int_passed))
else
  echo -e "${RED}✗ Integration Tests failed${NC}"
  FAILED_SUITES+=("Integration Tests")
  TOTAL_FAILED=$((TOTAL_FAILED + 1))
fi
echo ""

# Test Suite 3: Error Scenario Tests
echo -e "${BLUE}[3/4]${NC} Running Error Scenario Tests..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if "$TEST_DIR/test-errors.sh" > /tmp/error-test.log 2>&1; then
  err_passed=$(grep "Passed:" /tmp/error-test.log | awk '{print $2}')
  err_total=$(grep "Total:" /tmp/error-test.log | awk '{print $2}')
  echo -e "${GREEN}✓ Error Scenario Tests: $err_passed/$err_total passed${NC}"
  TOTAL_TESTS=$((TOTAL_TESTS + err_total))
  TOTAL_PASSED=$((TOTAL_PASSED + err_passed))
else
  echo -e "${RED}✗ Error Scenario Tests failed${NC}"
  FAILED_SUITES+=("Error Scenario Tests")
  TOTAL_FAILED=$((TOTAL_FAILED + 1))
fi
echo ""

# Suite 4: Dependency Check
echo -e "${BLUE}[4/4]${NC} Checking Dependencies..."
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
  echo "  • Unit Tests:           48 assertions (lib/common.sh, pn_config.sh)"
  echo "  • Integration Tests:    21 tests (check-session.sh, check-prompt.sh, check-write.sh)"
  echo "  • Error Scenarios:      11 tests (edge cases, malformed input, file system errors)"
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
  echo "  /tmp/error-test.log"
  echo ""
  exit 1
fi
