#!/bin/bash
# Common utilities for all PN hook scripts
# Provides: JSON helpers, HTTP wrappers, logging, error handling

set -o pipefail

# Colors for logging (optional, disabled if not a TTY)
if [[ -t 2 ]]; then
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  GREEN='\033[0;32m'
  NC='\033[0m'
else
  RED=''
  YELLOW=''
  GREEN=''
  NC=''
fi

# JSON helpers

json_string() {
  local value="$1"
  echo "$value" | jq -Rs .
}

json_object() {
  local key="$1"
  local value="$2"
  echo "{\"$key\": $value}"
}

json_merge() {
  local json1="$1"
  local json2="$2"
  echo "$json1" "$json2" | jq -s '.[0] * .[1]'
}

# HTTP helpers

http_post() {
  local url="$1"
  local data="$2"
  local auth_token="$3"
  local content_type="${4:-application/json}"
  local timeout="${5:-5}"

  local headers=()
  headers+=(-H "Content-Type: $content_type")

  if [[ -n "$auth_token" ]]; then
    headers+=(-H "Authorization: Bearer $auth_token")
  fi

  curl -s -X POST "$url" \
    "${headers[@]}" \
    --data-binary "$data" \
    --max-time "$timeout" \
    2>/dev/null

  return $?
}

http_post_form() {
  local url="$1"
  local text_data="$2"
  local auth_token="$3"
  local timeout="${4:-5}"

  local headers=()
  if [[ -n "$auth_token" ]]; then
    headers+=(-H "Authorization: Bearer $auth_token")
  fi

  # Appends the HTTP status as a trailing line (curl's -w token); the
  # caller must split it off the captured output — see http_post_split_status().
  # A global set here would NOT reach the caller: this function always runs
  # inside a $(...) subshell, and subshell variable assignments don't persist
  # past it. curl is the last command, so its own exit status becomes this
  # function's return value automatically.
  curl -s -X POST "$url" \
    "${headers[@]}" \
    --form-string "text=$text_data" \
    --max-time "$timeout" \
    -w $'\n%{http_code}' \
    2>/dev/null
}

# Splits the combined body+status output of http_post_form. Must be called
# as a plain function call (never via $(...)) so HTTP_POST_BODY/HTTP_POST_STATUS
# persist in the caller's own shell instead of vanishing with a subshell.
http_post_split_status() {
  local raw="$1"
  HTTP_POST_BODY="${raw%$'\n'*}"
  HTTP_POST_STATUS="${raw##*$'\n'}"
}

# Logging helpers

log_debug() {
  local message="$1"
  local log_path="${2:-}"

  if [[ -z "$log_path" ]]; then
    return 0
  fi

  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  # %3N (milliseconds) is a GNU date extension; BSD date (macOS) just echoes
  # the literal text back instead of erroring, so only append it if it
  # actually produced 3 digits.
  local ms
  ms=$(date '+%3N' 2>/dev/null)
  if [[ "$ms" =~ ^[0-9]{3}$ ]]; then
    timestamp="${timestamp}.${ms}"
  fi

  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
  echo "[$timestamp] $message" >> "$log_path"
}

log_json() {
  local json="$1"
  local log_path="$2"

  if [[ -z "$log_path" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
  echo "$json" >> "$log_path"
}

audit_log() {
  local entry="$1"
  local log_path="$2"

  if [[ -z "$log_path" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true

  local timestamp
  timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

  entry=$(echo "$entry" | jq ". + {timestamp: \"$timestamp\"}")
  echo "$entry" >> "$log_path"
}

# Timestamp helpers

current_epoch() {
  date +%s
}

epoch_to_date() {
  local epoch="$1"
  date -u -d "@$epoch" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
  date -u -r "$epoch" +'%Y-%m-%dT%H:%M:%SZ'
}

# Error response helpers (for hook scripts)

json_allow() {
  local message="${1:-}"

  if [[ -z "$message" ]]; then
    echo '{"continue": true}'
  else
    local msg_json
    msg_json=$(echo "$message" | jq -Rs .)
    echo "{\"continue\": true, \"user_message\": $msg_json}"
  fi
}

json_deny() {
  local message="$1"

  local msg_json
  msg_json=$(echo "$message" | jq -Rs .)
  echo "{\"continue\": false, \"user_message\": $msg_json}"
}

json_permission_allow() {
  local message="${1:-}"

  if [[ -z "$message" ]]; then
    echo '{"permission": "allow"}'
  else
    local msg_json
    msg_json=$(echo "$message" | jq -Rs .)
    echo "{\"permission\": \"allow\", \"user_message\": $msg_json}"
  fi
}

json_permission_deny() {
  local user_message="$1"
  local agent_message="${2:-}"

  local user_msg_json
  user_msg_json=$(echo "$user_message" | jq -Rs .)

  if [[ -z "$agent_message" ]]; then
    echo "{\"permission\": \"deny\", \"user_message\": $user_msg_json}"
  else
    local agent_msg_json
    agent_msg_json=$(echo "$agent_message" | jq -Rs .)
    echo "{\"permission\": \"deny\", \"user_message\": $user_msg_json, \"agent_message\": $agent_msg_json}"
  fi
}

json_session_context() {
  local context="$1"

  local ctx_json
  ctx_json=$(echo "$context" | jq -Rs .)
  echo "{\"additional_context\": $ctx_json}"
}

# Utility functions

file_read_tail() {
  local file_path="$1"
  local max_bytes="${2:-4000}"

  if [[ ! -f "$file_path" ]]; then
    echo ""
    return 0
  fi

  local file_size
  file_size=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null)

  if [[ $file_size -le $max_bytes ]]; then
    cat "$file_path"
  else
    tail -c "$max_bytes" "$file_path"
  fi
}

command_exists() {
  command -v "$1" &>/dev/null
}

# URL encoding
urlencode() {
  local string="$1"
  python3 -c "import urllib.parse; print(urllib.parse.quote('$string'))" 2>/dev/null || \
  echo "$string" | sed 's/ /%20/g'
}
