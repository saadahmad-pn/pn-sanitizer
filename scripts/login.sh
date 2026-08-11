#!/bin/bash
# OAuth PKCE login flow for PN authentication
# Usage: login.sh --base-url https://acme.paradigmnetworks.ai

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
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
    # Fallback: bash-only encoding (not perfect but works for most cases)
    local i="${string//\%/\%25}"
    i="${i//\ /\%20}"
    i="${i//?/\%21}"
    i="${i//:/\%3A}"
    i="${i////\%2F}"
    i="${i//&/\%26}"
    i="${i//=/\%3D}"
    echo -n "$i"
  }
}

# Wait for HTTP callback on localhost
wait_for_callback() {
  local port="$1"
  local deadline="$2"

  local CODE=""
  local STATE=""
  local ERROR=""

  # Use netcat with explicit response handling
  # Accept ONE connection on the port, send response, capture request
  local request_file="/tmp/callback_request_$$.txt"

  # Create response body
  local response_body="<!doctype html><html><head><title>PN login</title></head><body style=\"font-family: -apple-system, sans-serif; text-align: center; margin-top: 15vh;\"><h2>You're logged in.</h2></body></html>"
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

        # Parse query parameters
        IFS='&' read -ra params <<<"$query_string"
        for param in "${params[@]}"; do
          local key="${param%%=*}"
          local value="${param#*=}"
          case "$key" in
            code) CODE="$value" ;;
            state) STATE="$value" ;;
            error) ERROR="$value" ;;
          esac
        done

        # Clean up
        kill $nc_pid 2>/dev/null || true
        wait $nc_pid 2>/dev/null || true
        rm -f "$request_file"

        if [[ -n "$CODE" ]] || [[ -n "$ERROR" ]]; then
          echo "$CODE $STATE $ERROR"
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
  if ! echo "$response" | jq -e '.access_token' >/dev/null 2>&1; then
    local error_msg
    error_msg=$(echo "$response" | jq -r '.error_description // .error // "unknown error"' 2>/dev/null)
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
  echo "If that link takes you to the main PN dashboard instead of a 'You're logged in' confirmation,"
  echo "you weren't signed in to PN in that browser yet — sign in there, then open the exact same link"
  echo "again (no need to re-run this command) to finish."
  echo ""
  echo "Waiting up to ${CALLBACK_TIMEOUT_SECONDS}s for you to complete login..."

  # Wait for callback
  local deadline
  deadline=$(($(date +%s) + CALLBACK_TIMEOUT_SECONDS))

  local callback_result
  callback_result=$(wait_for_callback "$port" "$deadline") || {
    echo "error: timed out waiting for login after ${CALLBACK_TIMEOUT_SECONDS}s" >&2
    return 1
  }

  local code state_got error_msg
  read -r code state_got error_msg <<<"$callback_result"

  if [[ -n "$error_msg" ]]; then
    echo "error: login was denied or failed: $error_msg" >&2
    return 1
  fi

  if [[ "$state_got" != "$state" ]]; then
    echo "error: state mismatch on login callback — possible CSRF, aborting" >&2
    return 1
  fi

  if [[ -z "$code" ]]; then
    echo "error: login callback did not include an authorization code" >&2
    return 1
  fi

  # Exchange code for tokens
  local token_response
  token_response=$(exchange_code "$base_url" "$code" "$code_verifier" "$redirect_uri") || return 1

  local access_token
  local refresh_token
  local expires_in

  access_token=$(echo "$token_response" | jq -r '.access_token')
  refresh_token=$(echo "$token_response" | jq -r '.refresh_token // ""')
  expires_in=$(echo "$token_response" | jq -r '(.expires_in // 3600) | floor')

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

main "$@"
exit $?
