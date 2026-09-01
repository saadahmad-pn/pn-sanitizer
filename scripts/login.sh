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

CALLBACK_TIMEOUT_SECONDS=120
TOKEN_TIMEOUT_SECONDS=120

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

# urlencode_strict now lives in lib/common.sh (already sourced above) --
# pn_config.sh's token refresh needs it too, see that file's comment.

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
# Builds the nc listen-mode argument array for a given style + port, into
# the NC_LISTEN_ARGS global (arrays can't survive a plain return value,
# same reasoning as CALLBACK_CODE/etc above). Used both to probe which
# style actually works (detect_nc_listen_style) and to start the real
# listener (wait_for_callback), so the two can never drift apart --
# OpenBSD nc (macOS default, most Linux distros' netcat-openbsd) takes
# the port positionally ("nc -l HOST PORT"); GNU netcat / netcat-
# traditional require it after -p, with the bind address via -s instead
# of positionally ("nc -l -p PORT -s HOST"). Verified directly against
# GNU netcat 0.7.1 -- busybox nc was not available to test and may
# differ again, but the failure mode if so (nc exits immediately on an
# unrecognized flag) is a loud, immediate error, not another silent hang.
NC_LISTEN_ARGS=()
_nc_listen_args() {
  local style="$1" port="$2"
  case "$style" in
    openbsd)     NC_LISTEN_ARGS=(-l 127.0.0.1 "$port") ;;
    traditional) NC_LISTEN_ARGS=(-l -p "$port" -s 127.0.0.1) ;;
    *)           NC_LISTEN_ARGS=() ;;
  esac
}

# Detect which nc listen-mode flag syntax actually binds on this system.
# Passing the wrong style to GNU netcat does not error or exit --
# confirmed directly: it silently accepts the arguments and binds
# nothing usable, which otherwise means the real listener spins for the
# full login timeout with no hint why (this is not a hypothetical: it
# reproduces on a stock Mac the moment something else on PATH shadows
# the system `nc`, e.g. `brew install netcat`).
#
# Tests against a disposable, unrelated port picked fresh per attempt --
# deliberately never the real callback port. A plain `nc -l` (without
# -k) accepts exactly one connection and then exits; verifying via a
# real connect would consume that one-shot accept, so if this probed the
# real port, the actual browser redirect would arrive to find nc already
# gone. Confirmed this failure mode directly before settling on this
# design -- an earlier draft probed the real listener this way and broke
# the real callback.
detect_nc_listen_style() {
  local style probe_port probe_pid connected

  for style in openbsd traditional; do
    probe_port=$((20000 + RANDOM % 20000))
    _nc_listen_args "$style" "$probe_port"
    nc "${NC_LISTEN_ARGS[@]}" >/dev/null 2>&1 &
    probe_pid=$!
    sleep 0.2

    connected=1
    if (exec 3<>"/dev/tcp/127.0.0.1/$probe_port") 2>/dev/null; then
      connected=0
      exec 3<&- 2>/dev/null
      exec 3>&- 2>/dev/null
    fi
    kill "$probe_pid" 2>/dev/null
    wait "$probe_pid" 2>/dev/null

    if [[ $connected -eq 0 ]]; then
      echo "$style"
      return 0
    fi
  done

  return 1
}

wait_for_callback() {
  local port="$1"
  local deadline="$2"

  CALLBACK_CODE=""
  CALLBACK_STATE=""
  CALLBACK_ERROR=""

  # Use netcat with explicit response handling
  # Accept ONE connection on the port, send response, capture request
  local request_file="/tmp/callback_request_$$.txt"
  # Separate from request_file -- previously nc's own stderr was merged
  # straight into the file being parsed as an HTTP request (2>&1), so a
  # startup error (e.g. address already in use) tripped the `-s
  # request_file` non-empty check, failed the GET-line regex, and just
  # spun silently until the full timeout with no hint that nc never
  # bound at all.
  local nc_stderr_file="/tmp/callback_nc_stderr_$$.txt"

  local nc_listen_style
  nc_listen_style=$(detect_nc_listen_style) || {
    echo "error: could not start the local login callback listener -- nc on this system doesn't support either of the listen syntaxes this script tries (OpenBSD-style or GNU/traditional-style). Install a compatible netcat (e.g. OpenBSD netcat or GNU netcat) and try again." >&2
    return 1
  }
  _nc_listen_args "$nc_listen_style" "$port"

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
  } | nc "${NC_LISTEN_ARGS[@]}" > "$request_file" 2>"$nc_stderr_file" &

  local nc_pid=$!
  sleep 0.2

  # Best-effort: catch an outright bind failure (e.g. the port got taken
  # between selection and now -- the TOCTOU race in the port-selection
  # loop above) immediately rather than waiting out the full deadline.
  # Not exhaustive: some nc builds tolerate a duplicate bind silently
  # rather than erroring (confirmed directly: macOS's bundled nc does
  # this), so this can't catch every case -- but it catches the ones
  # that do report cleanly, which previously were guaranteed to be
  # swallowed into $request_file regardless.
  #
  # The $request_file check matters: a real client that connects and
  # completes within this 0.2s window makes nc exit on its own, normally,
  # having already done its job -- confirmed directly (a fast local test
  # request beat this check often enough to be a real, not theoretical,
  # race). Without it, that success would be misreported as the listener
  # having failed to start.
  if ! kill -0 "$nc_pid" 2>/dev/null && [[ ! -s "$request_file" ]]; then
    local nc_error
    nc_error=$(cat "$nc_stderr_file" 2>/dev/null)
    rm -f "$request_file" "$nc_stderr_file"
    echo "error: the local login callback listener exited immediately after starting.${nc_error:+ nc said: $nc_error}" >&2
    return 1
  fi

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
        rm -f "$request_file" "$nc_stderr_file"

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
  rm -f "$request_file" "$nc_stderr_file"
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
