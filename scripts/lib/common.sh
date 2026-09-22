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

# URL encoding helpers. Shared here (rather than living only in login.sh,
# where this originated) because pn_config.sh's token refresh needs it too
# -- a refresh token is just as capable of containing a URL-reserved
# character as an authorization code is, and a raw, unencoded token in a
# form body is corrupted by the receiving server exactly the same way.
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

# normalize_hook_model strips Cursor's own "unknown" placeholder (sent
# verbatim on its .model hook field when the model hasn't resolved yet at
# hook-fire time -- e.g. Auto model mode) down to an empty string, so it
# reads as genuinely absent rather than being sent to control-server and
# persisted in the chatapi collection as if "unknown" were a real model
# identifier. Case-insensitive since Cursor's own casing for this value is
# not documented/guaranteed. Confirmed via control-server's raw-payload debug
# logging (2026-09-22): a real afterAgentResponse payload carried
# "model":"unknown" -- this is Cursor's own value, not something introduced
# by this plugin's extraction, so the fix belongs at the point where we read
# it, not on the server.
normalize_hook_model() {
  local model="$1"
  case "$model" in
    [Uu][Nn][Kk][Nn][Oo][Ww][Nn])
      printf ''
      ;;
    *)
      printf '%s' "$model"
      ;;
  esac
}

# resolve_hook_model picks the best available model identifier from a
# Cursor hook payload: model_id (Cursor's docs: "Structured ID for the
# selected model, when available" -- optional, newer) when present, falling
# back to model (Cursor's docs: "Legacy model slug configured for the
# composer") when model_id is absent -- e.g. an older Cursor build that
# doesn't send it yet. Whichever value is chosen is passed through
# normalize_hook_model, since either field could in principle carry the
# "unknown" placeholder.
resolve_hook_model() {
  local model_id="$1"
  local legacy_model="$2"
  local chosen="$model_id"
  [[ -z "$chosen" ]] && chosen="$legacy_model"
  normalize_hook_model "$chosen"
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

# http_post_multipart_form <url> <auth_token> <timeout> <curl_form_arg>...
# Generic multipart/form-data POST for the detections API (lib/detection-
# client.sh) -- unlike http_post_form above (which always sends exactly one
# "text" field), the field set here varies per caller (flat form fields plus
# zero or more repeated file parts), so the caller builds the full list of
# curl --form-string/-F arguments itself and this function just adds
# auth/timeout/status-capture around it. Same body+status-via-trailing-line
# contract as http_post_form/http_post_json (split off with
# http_post_split_status).
http_post_multipart_form() {
  local url="$1"
  local auth_token="$2"
  local timeout="$3"
  shift 3

  local headers=()
  if [[ -n "$auth_token" ]]; then
    headers+=(-H "Authorization: Bearer $auth_token")
  fi

  curl -s -X POST "$url" \
    "${headers[@]}" \
    "$@" \
    --max-time "$timeout" \
    -w $'\n%{http_code}' \
    2>/dev/null
}

# Splits the combined body+status output of http_post_form / http_post_json /
# http_post_multipart_form. Must be called as a plain function call (never
# via $(...)) so HTTP_POST_BODY/HTTP_POST_STATUS persist in the caller's own
# shell instead of vanishing with a subshell.
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

# Anomaly-streak tracking. pn_parse_messages_response's block/allow
# verdict is a reverse-engineered heuristic (see that function's own
# comment) -- there is no real structured verdict field from the backend
# yet. If an upstream change to usage accounting or the block banner's
# wording ever turns every scan into "anomaly", that's a silent, complete
# loss of enforcement under the prompt hook's fail-open default -- nothing
# would surface it except a debug log line, and that's opt-in. These two
# functions track how many scans *in a row* have landed on "anomaly" so a
# caller can escalate to a loud, visible warning past a threshold instead
# of staying silent indefinitely. Call pn_record_scan_anomaly on every
# anomaly verdict, pn_record_successful_scan on every allow/block verdict --
# scoped narrowly to that classification, not to transport-level failures
# (timeouts, non-2xx, invalid JSON) which already have their own,
# well-understood handling and aren't part of what this tracks.
PN_ANOMALY_STATE_PATH="${HOME}/.paradigm-scanner/anomaly_state.json"
PN_ANOMALY_WARNING_THRESHOLD=3
PN_SCAN_STALENESS_THRESHOLD_SECONDS=3600

pn_record_scan_anomaly() {
  mkdir -p "$(dirname "$PN_ANOMALY_STATE_PATH")" 2>/dev/null

  local count=0
  local last_successful_scan=""
  if [[ -f "$PN_ANOMALY_STATE_PATH" ]]; then
    count=$("$JQ_BIN" -r '.consecutive_anomaly_count // 0' "$PN_ANOMALY_STATE_PATH" 2>/dev/null)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    # Preserve whatever was there -- an anomaly verdict must not erase the
    # last confirmed-good scan's timestamp, only bump the streak counter.
    last_successful_scan=$("$JQ_BIN" -r '.last_successful_scan // empty' "$PN_ANOMALY_STATE_PATH" 2>/dev/null)
  fi
  count=$((count + 1))

  # Best-effort persistence: if this fails, the count returned for this
  # one call is still correct, it just won't be remembered for the next
  # invocation -- same posture as this codebase's debug/audit logging,
  # which already treats a failed write as non-fatal rather than an error
  # worth surfacing to the user over.
  local temp_file
  temp_file=$(mktemp "${PN_ANOMALY_STATE_PATH}.XXXXXX" 2>/dev/null) && {
    if [[ -n "$last_successful_scan" ]]; then
      echo "{\"consecutive_anomaly_count\": $count, \"last_successful_scan\": $last_successful_scan}" > "$temp_file"
    else
      echo "{\"consecutive_anomaly_count\": $count}" > "$temp_file"
    fi
    mv "$temp_file" "$PN_ANOMALY_STATE_PATH" 2>/dev/null || rm -f "$temp_file"
  }

  echo "$count"
}

# Called on every allow/block verdict -- i.e. every scan whose response was
# a real, recognized shape -- never on anomaly/timeout/connection-error/
# HTTP-error/invalid-JSON, since those are exactly the failure modes
# staleness tracking exists to catch. Replaces the old pn_reset_scan_anomaly
# (which just did rm -f): the anomaly streak still needs clearing, but that
# now happens alongside writing a fresh timestamp, so a bare file delete no
# longer fits. This is a blind write (no read-modify-write) -- the count is
# always reset to 0 regardless of its previous value, the same net effect
# the old rm -f had -- so there's nothing to lose in a race against a
# concurrent pn_record_scan_anomaly call.
pn_record_successful_scan() {
  mkdir -p "$(dirname "$PN_ANOMALY_STATE_PATH")" 2>/dev/null

  local temp_file
  temp_file=$(mktemp "${PN_ANOMALY_STATE_PATH}.XXXXXX" 2>/dev/null) && {
    echo "{\"consecutive_anomaly_count\": 0, \"last_successful_scan\": $(current_epoch)}" > "$temp_file"
    mv "$temp_file" "$PN_ANOMALY_STATE_PATH" 2>/dev/null || rm -f "$temp_file"
  }
  return 0
}

# Sets PN_SCAN_STALE to "true" or "false". Absent state file, absent field,
# or age past PN_SCAN_STALENESS_THRESHOLD_SECONDS are all "true" -- not
# distinguished from each other, since to a user they all mean the same
# thing: no confirmed-recent successful scan. Must be called as a plain
# statement, not via $(...), same convention as pn_parse_messages_response.
pn_check_scan_staleness() {
  PN_SCAN_STALE="true"

  local last_successful_scan=""
  if [[ -f "$PN_ANOMALY_STATE_PATH" ]]; then
    last_successful_scan=$("$JQ_BIN" -r '.last_successful_scan // empty' "$PN_ANOMALY_STATE_PATH" 2>/dev/null)
  fi

  if [[ -n "$last_successful_scan" ]] && [[ "$last_successful_scan" =~ ^[0-9]+$ ]]; then
    local age=$(( $(current_epoch) - last_successful_scan ))
    # A negative age (timestamp in the future) means clock skew, not
    # genuine freshness -- treated as not-stale rather than a bogus huge
    # staleness value, since a skewed local clock is far more likely than
    # a corrupted timestamp, and erring toward not-stale avoids a false
    # warning firing on every session start on an affected machine.
    if [[ "$age" -le "$PN_SCAN_STALENESS_THRESHOLD_SECONDS" ]]; then
      PN_SCAN_STALE="false"
    fi
  fi
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

# Same scoping as get_current_turn_text (last user message to end of file),
# but role-separated into PN_TURN_PROMPT/PN_TURN_RESPONSE instead of one
# blended blob -- for Code Chain's turn-recording payload (lib/codechain-
# client.sh), which has distinct Prompt/Response fields. Must be called as a
# plain statement (see the multi-value-return convention above), never
# $(...). Both globals are reset to "" up front so a missing/unreadable
# transcript leaves neither stale from a previous call in the same process.
get_current_turn_messages() {
  local transcript_path="$1"
  local max_lines="${2:-500}"

  PN_TURN_PROMPT=""
  PN_TURN_RESPONSE=""

  if [[ ! -f "$transcript_path" ]]; then
    return 0
  fi

  local combined
  combined=$(tail -n "$max_lines" "$transcript_path" 2>/dev/null \
    | "$JQ_BIN" -R -r 'fromjson? | @json' 2>/dev/null \
    | "$JQ_BIN" -s -r '
      . as $lines
      | ([range(0; ($lines | length)) | select($lines[.].role == "user")] | last) as $start
      | $lines[($start // 0):]
      | {
          prompt: ([.[] | select(.role == "user") | (.message.content // [])[]? | select(.type == "text") | .text] | join("\n\n")),
          response: ([.[] | select(.role == "assistant") | (.message.content // [])[]? | select(.type == "text") | .text] | join("\n\n"))
        }
      | @json
    ' 2>/dev/null)

  [[ -z "$combined" ]] && return 0
  PN_TURN_PROMPT=$(echo "$combined" | "$JQ_BIN" -r '.prompt // ""' 2>/dev/null)
  PN_TURN_RESPONSE=$(echo "$combined" | "$JQ_BIN" -r '.response // ""' 2>/dev/null)
}
