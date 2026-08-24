#!/bin/bash
# Test utilities and assertion helpers

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
SCRIPTS_DIR="$PROJECT_DIR/scripts"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Temp directory for test artifacts
TEST_TEMP_DIR=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize test environment
test_init() {
  TEST_TEMP_DIR=$(mktemp -d) || exit 1
  export HOME="$TEST_TEMP_DIR/home"
  mkdir -p "$HOME/.pn" "$HOME/.paradigm-scanner" "$HOME/Desktop"
}

# Cleanup test environment
test_cleanup() {
  if [[ -n "$TEST_TEMP_DIR" ]] && [[ -d "$TEST_TEMP_DIR" ]]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
}

# Test case wrapper
test_case() {
  local name="$1"
  echo -e "${BLUE}[TEST]${NC} $name"
}

# Assert: command returns exit code 0
assert_success() {
  local cmd="$1"
  local name="${2:-Command: $cmd}"

  TESTS_RUN=$((TESTS_RUN + 1))

  if eval "$cmd" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "  ${RED}✗${NC} $name (exit code: $?)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

# Assert: command returns non-zero exit code
assert_failure() {
  local cmd="$1"
  local name="${2:-Command should fail: $cmd}"

  TESTS_RUN=$((TESTS_RUN + 1))

  if ! eval "$cmd" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "  ${RED}✗${NC} $name"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

# Assert: output equals expected string
assert_output_equals() {
  local cmd="$1"
  local expected="$2"
  local name="${3:-Output equals: $expected}"

  TESTS_RUN=$((TESTS_RUN + 1))

  local actual
  actual=$(eval "$cmd" 2>/dev/null)

  if [[ "$actual" == "$expected" ]]; then
    echo -e "  ${GREEN}✓${NC} $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "  ${RED}✗${NC} $name"
    echo "    Expected: $expected"
    echo "    Got:      $actual"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

# Assert: output contains substring
assert_output_contains() {
  local cmd="$1"
  local substring="$2"
  local name="${3:-Output contains: $substring}"

  TESTS_RUN=$((TESTS_RUN + 1))

  local actual
  actual=$(eval "$cmd" 2>/dev/null)

  if [[ "$actual" == *"$substring"* ]]; then
    echo -e "  ${GREEN}✓${NC} $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "  ${RED}✗${NC} $name"
    echo "    Output: $actual"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

# Assert: file exists
assert_file_exists() {
  local file="$1"
  local name="${2:-File exists: $file}"

  TESTS_RUN=$((TESTS_RUN + 1))

  if [[ -f "$file" ]]; then
    echo -e "  ${GREEN}✓${NC} $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "  ${RED}✗${NC} $name"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

# Assert: file does not exist
assert_file_not_exists() {
  local file="$1"
  local name="${2:-File does not exist: $file}"

  TESTS_RUN=$((TESTS_RUN + 1))

  if [[ ! -f "$file" ]]; then
    echo -e "  ${GREEN}✓${NC} $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "  ${RED}✗${NC} $name"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

# Assert: file has specific permissions
assert_file_permissions() {
  local file="$1"
  local expected_perms="$2"
  local name="${3:-File permissions: $expected_perms}"

  TESTS_RUN=$((TESTS_RUN + 1))

  local actual_perms
  actual_perms=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%A' "$file" 2>/dev/null)

  if [[ "$actual_perms" == "$expected_perms" ]]; then
    echo -e "  ${GREEN}✓${NC} $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "  ${RED}✗${NC} $name (got: $actual_perms)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

# Assert: JSON is valid
assert_json_valid() {
  local json="$1"
  local name="${2:-Valid JSON}"

  TESTS_RUN=$((TESTS_RUN + 1))

  if echo "$json" | jq empty 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "  ${RED}✗${NC} $name"
    echo "    JSON: $json"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

# Assert: JSON contains specific key
assert_json_has_key() {
  local json="$1"
  local key="$2"
  local name="${3:-JSON has key: $key}"

  TESTS_RUN=$((TESTS_RUN + 1))

  if echo "$json" | jq -e ".$key" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "  ${RED}✗${NC} $name"
    echo "    JSON: $json"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

# Assert: JSON field equals value
assert_json_field_equals() {
  local json="$1"
  local field="$2"
  local expected="$3"
  local name="${4:-JSON $field equals $expected}"

  TESTS_RUN=$((TESTS_RUN + 1))

  local actual
  actual=$(echo "$json" | jq -r ".$field" 2>/dev/null)

  if [[ "$actual" == "$expected" ]]; then
    echo -e "  ${GREEN}✓${NC} $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "  ${RED}✗${NC} $name"
    echo "    Expected: $expected"
    echo "    Got:      $actual"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

# Print test summary
test_summary() {
  echo ""
  echo "========================================"
  echo "Test Summary"
  echo "========================================"
  echo -e "Total:  ${TESTS_RUN}"
  echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
  echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
  echo "========================================"

  if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    return 0
  else
    echo -e "${RED}✗ Some tests failed${NC}"
    return 1
  fi
}

# Create mock credentials file
mock_credentials() {
  local base_url="${1:-https://test.example.com}"
  local access_token="${2:-test-access-token}"
  local refresh_token="${3:-test-refresh-token}"
  local expires_at="${4:-$(($(date +%s) + 3600))}"

  mkdir -p "$HOME/.pn"
  jq -n \
    --arg base_url "$base_url" \
    --arg access_token "$access_token" \
    --arg refresh_token "$refresh_token" \
    --arg expires_at "$expires_at" \
    '{base_url: $base_url, access_token: $access_token, refresh_token: $refresh_token, expires_at: $expires_at}' > "$HOME/.pn/credentials.json"

  chmod 600 "$HOME/.pn/credentials.json"
}

# Source common and config scripts
source_scripts() {
  source "$SCRIPTS_DIR/lib/common.sh"
  source "$SCRIPTS_DIR/lib/git-utils.sh"
  source "$SCRIPTS_DIR/pn_config.sh"
}
