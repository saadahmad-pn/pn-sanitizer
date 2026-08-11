#!/usr/bin/env sh
# Probe whether Cursor passes plugin variables to hook scripts
# POSIX sh only (no bash, no external dependencies)
# Writes report to ${TMPDIR:-/tmp}/pn-variable-probe.txt, prints {} on stdout

set -eu

# Guard: fail gracefully on Windows shells
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    printf '%s\n' '{}'
    exit 0
    ;;
esac

# Guard: fail gracefully if stdin is a TTY (would hang)
if [ -t 0 ]; then
  printf '%s\n' '{}'
  exit 0
fi

# Drain stdin to avoid hang
cat > /dev/null 2>&1 || true

# Report file
PROBE_REPORT="${TMPDIR:-/tmp}/pn-variable-probe.txt"

# Append a probe entry with ISO-8601 timestamp, environment
{
  printf 'PROBE: %s | %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$(uname -s)"
  printf 'CURSOR_PLUGIN_ROOT=%s\n' "${CURSOR_PLUGIN_ROOT:-<not set>}"
  printf 'CURSOR_PROJECT_DIR=%s\n' "${CURSOR_PROJECT_DIR:-<not set>}"

  # Dump all variables starting with PN_, SNANTIZER_, or CURSOR_
  found_vars=0
  env | grep -E '^(PN_|SNANTIZER_|CURSOR_)' | while IFS='=' read -r key value; do
    printf '%s=%s\n' "$key" "$value"
    found_vars=1
  done

  # If no matches, be explicit
  if ! env | grep -qE '^(PN_|SNANTIZER_|CURSOR_)'; then
    printf 'NO PN_* VARIABLES IN ENV\n'
  fi

  printf -- '---\n'
} >> "$PROBE_REPORT" 2>/dev/null || true

# Hook contract: print valid JSON on stdout, exit 0
printf '%s\n' '{}'
exit 0
