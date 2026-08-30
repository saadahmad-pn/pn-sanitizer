#!/bin/bash
# Common utilities for all Paradigm Networks hook scripts
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

# Resolve jq: prefer a system install (respects whatever version the user
# already has), fall back to the binary bundled in scripts/bin/ so jq is
# never a hard requirement. JQ_BIN is empty only if neither is available
# (e.g. an unsupported platform/arch) — callers must check for that.
resolve_jq() {
  if command -v jq &>/dev/null; then
    printf '%s' "jq"
    return 0
  fi

  local os arch bin_dir bundled
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Darwin) os="macos" ;;
    Linux) os="linux" ;;
    *) return 1 ;;
  esac
  case "$arch" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64) arch="amd64" ;;
    *) return 1 ;;
  esac

  bin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" 2>/dev/null && pwd)"
  bundled="${bin_dir}/jq-${os}-${arch}"
  if [[ -n "$bin_dir" ]] && [[ -x "$bundled" ]]; then
    printf '%s' "$bundled"
    return 0
  fi

  return 1
}

JQ_BIN="$(resolve_jq)" || JQ_BIN=""

# JSON helpers

json_string() {
  local value="$1"
  echo "$value" | "$JQ_BIN" -Rs .
}

json_object() {
  local key="$1"
  local value="$2"
  echo "{\"$key\": $value}"
}

json_merge() {
  local json1="$1"
  local json2="$2"
  echo "$json1" "$json2" | "$JQ_BIN" -s '.[0] * .[1]'
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

# Same body+status-via-trailing-line contract as http_post_form/
# http_post_json below (split off with http_post_split_status, which works
# for any of the three despite its name) -- used for GET /v1/models.
http_get() {
  local url="$1"
  local auth_token="$2"
  local timeout="${3:-5}"

  local headers=()
  if [[ -n "$auth_token" ]]; then
    headers+=(-H "Authorization: Bearer $auth_token")
  fi

  curl -s -X GET "$url" \
    "${headers[@]}" \
    --max-time "$timeout" \
    -w $'\n%{http_code}' \
    2>/dev/null
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

# Same contract as http_post_form (body+status via the trailing \n%{http_code}
# line, split off by http_post_split_status below) but posts a raw JSON body
# instead of a multipart form field -- used for the Anthropic-compatible
# /v1/messages endpoint. Deliberately mirrors http_post_form exactly rather
# than reusing http_post() (which already sends raw JSON via --data-binary,
# but has no status-code capture, and every caller of http_post_form's
# result depends on HTTP_POST_STATUS being set).
http_post_json() {
  local url="$1"
  local json_body="$2"
  local auth_token="$3"
  local timeout="${4:-5}"

  local headers=()
  headers+=(-H "Content-Type: application/json")
  if [[ -n "$auth_token" ]]; then
    headers+=(-H "Authorization: Bearer $auth_token")
  fi

  curl -s -X POST "$url" \
    "${headers[@]}" \
    --data-binary "$json_body" \
    --max-time "$timeout" \
    -w $'\n%{http_code}' \
    2>/dev/null
}

# Splits the combined body+status output of http_post_form / http_post_json.
# Must be called as a plain function call (never via $(...)) so
# HTTP_POST_BODY/HTTP_POST_STATUS persist in the caller's own shell instead
# of vanishing with a subshell.
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

  entry=$(echo "$entry" | "$JQ_BIN" ". + {timestamp: \"$timestamp\"}")
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
    msg_json=$(echo "$message" | "$JQ_BIN" -Rs .)
    echo "{\"continue\": true, \"user_message\": $msg_json}"
  fi
}

json_deny() {
  local message="$1"

  local msg_json
  msg_json=$(echo "$message" | "$JQ_BIN" -Rs .)
  echo "{\"continue\": false, \"user_message\": $msg_json}"
}

json_permission_allow() {
  local message="${1:-}"

  if [[ -z "$message" ]]; then
    echo '{"permission": "allow"}'
  else
    local msg_json
    msg_json=$(echo "$message" | "$JQ_BIN" -Rs .)
    echo "{\"permission\": \"allow\", \"user_message\": $msg_json}"
  fi
}

json_permission_deny() {
  local user_message="$1"
  local agent_message="${2:-}"

  local user_msg_json
  user_msg_json=$(echo "$user_message" | "$JQ_BIN" -Rs .)

  if [[ -z "$agent_message" ]]; then
    echo "{\"permission\": \"deny\", \"user_message\": $user_msg_json}"
  else
    local agent_msg_json
    agent_msg_json=$(echo "$agent_message" | "$JQ_BIN" -Rs .)
    echo "{\"permission\": \"deny\", \"user_message\": $user_msg_json, \"agent_message\": $agent_msg_json}"
  fi
}

json_session_context() {
  local context="$1"

  local ctx_json
  ctx_json=$(echo "$context" | "$JQ_BIN" -Rs .)
  echo "{\"additional_context\": $ctx_json}"
}

# pn_parse_messages_response <raw_json_response>
# Classifies a /v1/messages (Anthropic-compatible) response as
# "allow"/"block"/"anomaly" -- there is no purpose-built status field on
# this endpoint, only a chat-completion shape, so this is reverse-engineered
# from observed behavior: a request the platform's guard blocks comes back
# as a normal 200 with usage.input_tokens/output_tokens both exactly 0 (a
# real completion is never 0/0) and a "REQUEST BLOCKED" banner injected
# into a text content block in place of an actual model reply.
#
# Deliberately NOT a simple "banner text AND zero usage" check: that fails
# OPEN (the wrong direction for a security gate) if the banner wording ever
# changes upstream -- zero usage would still be true, but a text match
# alone would then read as "allow". Zero usage without the banner text is
# instead treated as "anomaly", the same posture as an invalid-JSON or
# non-2xx response: an unrecognized shape must not be silently guessed as
# "allow" or "block", it needs to fail through the caller's existing
# FAILURE_MODE/PROMPT_FAILURE_MODE branching. Missing usage numbers or no
# text content block at all are anomalies for the same reason.
#
# Sets globals PN_MSG_ACTION ("allow"|"block"|"anomaly") and
# PN_MSG_MESSAGE (the extracted block reason -- only meaningful when
# PN_MSG_ACTION is "block"). Must be called as a plain function call
# (never via $(...)), same requirement as http_post_split_status above.
pn_parse_messages_response() {
  local response="$1"

  PN_MSG_ACTION="allow"
  PN_MSG_MESSAGE=""

  local input_tokens output_tokens has_text_block text_content
  input_tokens=$(echo "$response" | "$JQ_BIN" -r '.usage.input_tokens // "missing"')
  output_tokens=$(echo "$response" | "$JQ_BIN" -r '.usage.output_tokens // "missing"')
  # Never assume content[0] is the text block -- a thinking-capable model
  # could put a non-text block first, silently degrading the reason to
  # empty if indexed positionally instead of by type.
  has_text_block=$(echo "$response" | "$JQ_BIN" -r '[.content[]? | select(.type == "text")] | length > 0')
  text_content=$(echo "$response" | "$JQ_BIN" -r '[.content[]? | select(.type == "text") | .text][0] // ""')

  if [[ "$input_tokens" == "missing" ]] || [[ "$output_tokens" == "missing" ]] || [[ "$has_text_block" != "true" ]]; then
    PN_MSG_ACTION="anomaly"
    return 0
  fi

  if [[ "$input_tokens" == "0" ]] && [[ "$output_tokens" == "0" ]]; then
    if [[ "$text_content" == *"REQUEST BLOCKED"* ]]; then
      PN_MSG_ACTION="block"
      # Same reason-extraction pattern used in check-prompt.sh's block-
      # message formatting -- kept in a variable, not inline in [[ =~ ]]:
      # bash's own conditional-expression parser trips on unquoted
      # parentheses when the pattern is written directly inside [[ ]].
      local reason="$text_content"
      local reason_pattern="security concerns:? \(?([^.)]+)[.)]"
      if [[ "$text_content" =~ $reason_pattern ]]; then
        reason="${BASH_REMATCH[1]}"
      fi
      PN_MSG_MESSAGE="$reason"
    else
      PN_MSG_ACTION="anomaly"
    fi
  fi
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

# Extracts the text of the current conversation turn from a Cursor
# transcript.jsonl -- everything from the most recent user message to the
# end of the file (the assistant's own turn-in-progress). Scoped this way
# rather than a raw byte-count tail: a byte cut can straddle multiple
# unrelated previous turns and drag stale context into an unrelated write's
# scan (confirmed directly as the cause of a false positive -- a trivial
# follow-up write inherited a flagged verdict from leftover text in an
# earlier, unrelated request). Each transcript line is either
# {"role": "user"|"assistant", "message": {"content": [...]}} or a
# turn-status marker with no "role" at all; finding the last "user" line
# gives an exact turn boundary instead of guessing one.
# Bounded to the last max_lines lines first (tail, before parsing) so a
# pathologically large transcript can't make this expensive; a single
# turn is never remotely close to that many lines in practice.
get_current_turn_text() {
  local transcript_path="$1"
  local max_lines="${2:-500}"

  if [[ ! -f "$transcript_path" ]]; then
    echo ""
    return 0
  fi

  # Two jq passes, not one -s (slurp): slurp mode fails its ENTIRE input if
  # even a single line isn't valid JSON, which a naive one-pass version
  # hit immediately -- Cursor can still be appending to this file while
  # this hook reads it, so a truncated/partial last line is a real,
  # expected case, not a hypothetical one. The first pass reads line by
  # line (-R) and drops anything that doesn't parse (`fromjson?`, the `?`
  # suppresses a per-line failure instead of aborting); only the survivors
  # reach the second pass's -s slurp.
  tail -n "$max_lines" "$transcript_path" 2>/dev/null \
    | "$JQ_BIN" -R -r 'fromjson? | @json' 2>/dev/null \
    | "$JQ_BIN" -s -r '
      . as $lines
      | ([range(0; ($lines | length)) | select($lines[.].role == "user")] | last) as $start
      | $lines[($start // 0):]
      | [.[] | (.message.content // [])[]? | select(.type == "text") | .text]
      | join("\n\n")
    ' 2>/dev/null
}
