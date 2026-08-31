#!/bin/bash
# OAuth PKCE login flow for Paradigm Networks authentication
# Usage: login.sh --base-url https://acme.paradigmnetworks.ai

set -o pipefail

# Unlike the hook scripts, this is invoked directly (by the login skill),
# not run unconditionally by Cursor on every platform -- so there's no
# double-execution risk to guard against here, only a wrong-script risk:
# if the agent runs this instead of login.ps1 on Windows (Git Bash, MSYS2,
# Cygwin all provide a real bash), point it at the right one instead of
# attempting a login that depends on openssl/nc, which may not be present.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "error: this is the Unix login script. On Windows, run login.ps1 instead (via scripts/run-powershell.cmd login.ps1 -BaseUrl <url>)." >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/pn_config.sh"

# Ensure line-buffering for non-TTY stdout
export PYTHONUNBUFFERED=1

CALLBACK_TIMEOUT_SECONDS=60
TOKEN_TIMEOUT_SECONDS=15

# Generate PKCE code challenge and verifier
make_pkce_pair() {
  # Generate a 40-byte random string, base64url encoded without padding
  local verifier
  verifier=$(openssl rand -base64 40 | tr -d '\n' | tr '+/' '-_' | tr -d '=')

  # Create SHA256 hash of verifier
  local challenge
  challenge=$(echo -n "$verifier" | openssl dgst -sha256 -binary | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')

  echo "$verifier" "$challenge"
}

# URL encode a string
urlencode_strict() {
  local string="$1"
  echo -n "$string" | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().rstrip()))" 2>/dev/null || \
  echo -n "$string" | python3 -c "import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.stdin.read()))" 2>/dev/null || \
  {
    # Fallback: pure-bash percent-encoding (used when python3 is unavailable)
    local result="" c hex i
    for (( i = 0; i < ${#string}; i++ )); do
      c="${string:i:1}"
      case "$c" in
        [a-zA-Z0-9.~_-]) result+="$c" ;;
        *) printf -v hex '%%%02X' "'$c"; result+="$hex" ;;
      esac
    done
    echo -n "$result"
  }
}

# URL decode a string (the inverse of urlencode_strict): '+' -> space, then
# %XX -> byte. Used on raw query-string values pulled straight off the
# callback request line, which are still percent-encoded exactly as the
# browser sent them.
urldecode_strict() {
  local string="$1"
  echo -n "$string" | python3 -c "import sys, urllib.parse; print(urllib.parse.unquote_plus(sys.stdin.read().rstrip()))" 2>/dev/null || \
  echo -n "$string" | python3 -c "import sys, urllib.parse; sys.stdout.write(urllib.parse.unquote_plus(sys.stdin.read()))" 2>/dev/null || \
  {
    # Fallback: pure-bash percent-decoding (used when python3 is unavailable)
    local plus_decoded="${string//+/ }"
    printf '%b' "${plus_decoded//%/\\x}"
  }
}

# Wait for HTTP callback on localhost. Deliberately does NOT return
# code/state/error via a space-joined `echo` string read back with `read -r`
# -- when CODE is empty (e.g. the user denied consent, so there's no code,
# only state+error), positional fields shift left and error_msg silently
# lands empty, so the real error is lost and the (now-misaligned) state
# comparison fails instead, misreporting a denied login as a CSRF attack.
# Sets these three globals directly instead (same pattern as
# http_post_split_status in lib/common.sh) -- call this as a plain
# statement, not via $(...), or the globals won't escape a subshell.
CALLBACK_CODE=""
CALLBACK_STATE=""
CALLBACK_ERROR=""
wait_for_callback() {
  local port="$1"
  local deadline="$2"

  CALLBACK_CODE=""
  CALLBACK_STATE=""
  CALLBACK_ERROR=""

  # Use netcat with explicit response handling
  # Accept ONE connection on the port, send response, capture request
  local request_file="/tmp/callback_request_$$.txt"

  # Create response body
  local response_body="<!doctype html><html><head><title>Paradigm Networks login</title></head><body style=\"font-family: -apple-system, sans-serif; text-align: center; margin-top: 15vh;\"><h2>You're logged in.</h2></body></html>"
  local response_len=${#response_body}

  # Build full HTTP response
  {
    echo -ne "HTTP/1.1 200 OK\r\n"
    echo -ne "Content-Type: text/html\r\n"
    echo -ne "Content-Length: $response_len\r\n"
    echo -ne "Connection: close\r\n"
    echo -ne "\r\n"
    echo -ne "$response_body"
  } | nc -l 127.0.0.1 "$port" > "$request_file" 2>&1 &

  local nc_pid=$!
  sleep 0.2

  # Wait for request to arrive
  while [[ $(date +%s) -lt $deadline ]]; do
    if [[ -s "$request_file" ]]; then
      # Parse request
      local request_line
      request_line=$(head -1 "$request_file")

      if [[ "$request_line" =~ ^GET\ /callback\?(.*)\ HTTP ]]; then
        local query_string="${BASH_REMATCH[1]}"

        # Parse query parameters. Values are decoded immediately here, as
        # soon as they're split out of the query string -- CODE/STATE must
        # hold their true, decoded form from this point on. exchange_code
        # re-encodes CODE before sending it back over the wire; decoding it
        # here first (rather than leaving it percent-encoded and skipping
        # the decode there) avoids double-encoding a code that itself
        # contains a character outside [a-zA-Z0-9.~_-] (e.g. "/", "+").
        IFS='&' read -ra params <<<"$query_string"
        for param in "${params[@]}"; do
          local key="${param%%=*}"
          local value="${param#*=}"
          case "$key" in
            code) CALLBACK_CODE="$(urldecode_strict "$value")" ;;
            state) CALLBACK_STATE="$(urldecode_strict "$value")" ;;
            error) CALLBACK_ERROR="$(urldecode_strict "$value")" ;;
          esac
        done

        # Clean up
        kill $nc_pid 2>/dev/null || true
        wait $nc_pid 2>/dev/null || true
        rm -f "$request_file"

        if [[ -n "$CALLBACK_CODE" ]] || [[ -n "$CALLBACK_ERROR" ]]; then
          return 0
        fi
      fi
    fi
    sleep 0.1
  done

  # Timeout
  kill $nc_pid 2>/dev/null || true
  wait $nc_pid 2>/dev/null || true
  rm -f "$request_file"
  return 1
}

# Exchange authorization code for tokens
exchange_code() {
  local base_url="$1"
  local code="$2"
  local code_verifier="$3"
  local redirect_uri="$4"

  local token_url="${base_url%/}/api/v1/plugin/token"

  local body
  body="grant_type=authorization_code&code=$(urlencode_strict "$code")&code_verifier=$(urlencode_strict "$code_verifier")&client_id=$(urlencode_strict "$CLIENT_ID")&redirect_uri=$(urlencode_strict "$redirect_uri")"

  local response
  response=$(curl -s -X POST "$token_url" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-raw "$body" \
    --max-time "$TOKEN_TIMEOUT_SECONDS" 2>/dev/null)

  if [[ -z "$response" ]]; then
    echo "error: could not reach $base_url" >&2
    return 1
  fi

  # Validate response is JSON and has access_token
  if ! echo "$response" | "$JQ_BIN" -e '.access_token' >/dev/null 2>&1; then
    local error_msg
    error_msg=$(echo "$response" | "$JQ_BIN" -r '.error_description // .error // "unknown error"' 2>/dev/null)
    echo "error: token exchange failed: $error_msg" >&2
    return 1
  fi

  echo "$response"
}

# Check if running in Cursor sandbox
running_in_cursor_sandbox() {
  [[ -n "${CURSOR_SANDBOX:-}" ]] || [[ "${CURSOR_AGENT:-}" == "1" ]]
}

# Try to open browser
open_browser() {
  local url="$1"

  # Skip in Cursor sandbox (IPC blocked)
  if running_in_cursor_sandbox; then
    return 1
  fi

  # Try native opener first (macOS: open, Linux: xdg-open)
  if [[ "$(uname)" == "Darwin" ]] && command -v open &>/dev/null; then
    open "$url" 2>/dev/null && return 0
  elif [[ "$(uname)" == "Linux" ]] && command -v xdg-open &>/dev/null; then
    xdg-open "$url" 2>/dev/null && return 0
  fi

  return 1
}

# Normalize and validate base URL
normalize_base_url() {
  local url="$1"

  if [[ ! "$url" =~ ^https?:// ]]; then
    echo "error: --base-url must be a full URL like https://acme.paradigmnetworks.ai, got: $url" >&2
    return 1
  fi

  # Extract scheme://host, removing trailing path
  local normalized
  normalized=$(echo "$url" | sed 's|^\(https\?://[^/]*\)/.*$|\1|; s|/$||')
  echo "$normalized"
}

main() {
  if [[ -z "$JQ_BIN" ]]; then
    echo "error: jq is required but not found, and no bundled copy is available for this platform. Install it (macOS: brew install jq; Linux: apt-get/dnf/pacman install jq), then try again." >&2
    return 1
  fi
  if ! command -v openssl &>/dev/null; then
    echo "error: openssl is required but not found. It's needed to generate the login's PKCE challenge. Install it, then try again." >&2
    return 1
  fi
  if ! command -v nc &>/dev/null; then
    echo "error: nc (netcat) is required but not found. It's needed to receive the login callback. Install it, then try again." >&2
    return 1
  fi

  # Parse arguments
  local base_url=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base-url)
        base_url="$2"
        shift 2
        ;;
      *)
        echo "error: unknown option: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$base_url" ]]; then
    echo "error: --base-url is required" >&2
    return 1
  fi

  # Normalize base URL
  base_url=$(normalize_base_url "$base_url") || return 1

  echo "Logging in to $base_url..."

  # Generate PKCE pair
  read -r code_verifier code_challenge <<<"$(make_pkce_pair)"
  local state
  state=$(openssl rand -hex 24)

  # Find available port (start from 8000, skip system ports)
  local port
  port=8000

  # Try to find a free port by attempting to connect to it
  # If connection fails, port is free
  while [[ $port -lt 65000 ]]; do
    # Try to connect; if it fails, port is available
    if ! nc -z 127.0.0.1 "$port" 2>/dev/null; then
      break
    fi
    port=$((port + 1))
  done

  local redirect_uri="http://127.0.0.1:${port}/callback"

  # Build authorization URL
  local authorize_url="${base_url%/}/api/v1/plugin/authorize?"
  authorize_url+="client_id=$(urlencode_strict "$CLIENT_ID")"
  authorize_url+="&response_type=code"
  authorize_url+="&code_challenge=$(urlencode_strict "$code_challenge")"
  authorize_url+="&code_challenge_method=S256"
  authorize_url+="&redirect_uri=$(urlencode_strict "$redirect_uri")"
  authorize_url+="&state=$(urlencode_strict "$state")"

  # Print instructions and try to open browser
  if running_in_cursor_sandbox; then
    echo "Open this URL to log in:"
    echo "  $authorize_url"
  elif open_browser "$authorize_url"; then
    echo "Opened your browser to log in."
  else
    echo "Couldn't open a browser automatically. Open this URL to log in:"
    echo "  $authorize_url"
  fi

  echo ""
  echo "If that link takes you to the main Paradigm Networks dashboard instead of a 'You're logged in' confirmation,"
  echo "you weren't signed in to Paradigm Networks in that browser yet — sign in there, then open the exact same link"
  echo "again (no need to re-run this command) to finish."
  echo ""
  echo "Waiting up to ${CALLBACK_TIMEOUT_SECONDS}s for you to complete login..."

  # Wait for callback
  local deadline
  deadline=$(($(date +%s) + CALLBACK_TIMEOUT_SECONDS))

  # Called as a plain statement, not $(...) -- wait_for_callback sets
  # CALLBACK_CODE/CALLBACK_STATE/CALLBACK_ERROR directly (see its own
  # comment for why a space-joined echo/read was wrong: a denied login has
  # no code, and that empty field used to shift the real error message out
  # of place, misreporting a denial as a CSRF state mismatch instead).
  wait_for_callback "$port" "$deadline" || {
    echo "error: timed out waiting for login after ${CALLBACK_TIMEOUT_SECONDS}s" >&2
    return 1
  }

  if [[ -n "$CALLBACK_ERROR" ]]; then
    echo "error: login was denied or failed: $CALLBACK_ERROR" >&2
    return 1
  fi

  if [[ "$CALLBACK_STATE" != "$state" ]]; then
    echo "error: state mismatch on login callback — possible CSRF, aborting" >&2
    return 1
  fi

  if [[ -z "$CALLBACK_CODE" ]]; then
    echo "error: login callback did not include an authorization code" >&2
    return 1
  fi

  # Exchange code for tokens
  local token_response
  token_response=$(exchange_code "$base_url" "$CALLBACK_CODE" "$code_verifier" "$redirect_uri") || return 1

  local access_token
  local refresh_token
  local expires_in

  access_token=$(echo "$token_response" | "$JQ_BIN" -r '.access_token')
  refresh_token=$(echo "$token_response" | "$JQ_BIN" -r '.refresh_token // ""')
  expires_in=$(echo "$token_response" | "$JQ_BIN" -r '(.expires_in // 3600) | floor' 2>/dev/null)

  # Guard against a non-numeric expires_in (malformed/unexpected API response)
  # crashing the arithmetic below outright.
  if ! [[ "$expires_in" =~ ^[0-9]+$ ]]; then
    expires_in=3600
  fi

  # Calculate expiry timestamp
  local expires_at
  expires_at=$(($(date +%s) + expires_in))

  # Save credentials
  pn_save_credentials "$base_url" "$access_token" "$refresh_token" "$expires_at" || {
    echo "error: failed to save credentials" >&2
    return 1
  }

  echo "Logged in to $base_url. Credentials saved to $CRED_PATH."
  return 0
}

# Only run when executed directly, not when sourced (e.g. by a test that
# wants to call wait_for_callback/urlencode_strict/urldecode_strict in
# isolation without going through the full login flow). No behavior change
# for normal use: bash login.sh / ./login.sh still runs main exactly as
# before, since BASH_SOURCE[0] equals $0 in that case.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
  exit $?
fi
