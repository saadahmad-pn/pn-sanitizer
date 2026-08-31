#!/bin/bash
# Credential and config management for Paradigm Networks hook scripts
# Handles reading/writing ~/.pn/credentials.json and token refresh

CLIENT_ID="cursor-plugin"
CRED_DIR="${HOME}/.pn"
CRED_PATH="${CRED_DIR}/credentials.json"
TOKEN_TIMEOUT_SECONDS=10
EXPIRY_MARGIN_SECONDS=60

# Load credentials from disk
pn_load_credentials() {
  if [[ ! -f "$CRED_PATH" ]]; then
    return 1
  fi

  "$JQ_BIN" -e '.base_url and .access_token and .refresh_token and .expires_at' "$CRED_PATH" >/dev/null 2>&1 || {
    return 1
  }

  cat "$CRED_PATH"
}

# Save credentials to disk with 0600 permissions
pn_save_credentials() {
  local base_url="$1"
  local access_token="$2"
  local refresh_token="$3"
  local expires_at="$4"

  mkdir -p "$CRED_DIR" 2>/dev/null
  chmod 700 "$CRED_DIR" 2>/dev/null || true

  # Merge into whatever's already on disk, not a from-scratch rebuild --
  # this function runs automatically and silently on every token refresh
  # (see pn_get_valid_access_token below), so a naive rebuild would wipe
  # any field this function doesn't itself know about (e.g. a saved
  # preferred_model, see pn_save_preferred_model) the very next time a
  # session runs long enough to trigger a refresh.
  local existing_json="{}"
  if [[ -f "$CRED_PATH" ]]; then
    existing_json=$(cat "$CRED_PATH" 2>/dev/null)
    echo "$existing_json" | "$JQ_BIN" empty 2>/dev/null || existing_json="{}"
  fi

  local creds_json
  creds_json=$(echo "$existing_json" | "$JQ_BIN" \
    --arg base_url "$base_url" \
    --arg access_token "$access_token" \
    --arg refresh_token "$refresh_token" \
    --argjson expires_at "$expires_at" \
    '. + {base_url: $base_url, access_token: $access_token, refresh_token: $refresh_token, expires_at: $expires_at}')

  # Write with secure temp file to avoid race conditions
  local temp_file
  temp_file=$(mktemp "$CRED_PATH.XXXXXX") || return 1

  # Write with restricted permissions from the start
  echo "$creds_json" > "$temp_file"
  chmod 600 "$temp_file"

  mv "$temp_file" "$CRED_PATH" || {
    rm -f "$temp_file"
    return 1
  }

  chmod 600 "$CRED_PATH" 2>/dev/null || true
}

# Save (or clear, if model_id is empty) the user's preferred scanning
# model. Separate from pn_save_credentials -- a model change shouldn't
# require also supplying base_url/access_token/refresh_token/expires_at --
# but uses the same merge-then-atomic-write pattern. Requires an existing,
# valid credentials file (there's nothing meaningful to merge a model
# preference into otherwise).
pn_save_preferred_model() {
  local model_id="$1"

  if [[ ! -f "$CRED_PATH" ]]; then
    return 1
  fi

  local existing_json
  existing_json=$(cat "$CRED_PATH" 2>/dev/null)
  echo "$existing_json" | "$JQ_BIN" empty 2>/dev/null || return 1

  local creds_json
  creds_json=$(echo "$existing_json" | "$JQ_BIN" \
    --arg model_id "$model_id" \
    '. + {preferred_model: $model_id}')

  local temp_file
  temp_file=$(mktemp "$CRED_PATH.XXXXXX") || return 1

  echo "$creds_json" > "$temp_file"
  chmod 600 "$temp_file"

  mv "$temp_file" "$CRED_PATH" || {
    rm -f "$temp_file"
    return 1
  }

  chmod 600 "$CRED_PATH" 2>/dev/null || true
}

# Returns the stored preferred_model, or an empty string if unset or not
# configured. Deliberately independent of pn_resolve_config -- this is a
# plain file read, no auth/refresh machinery needed.
pn_get_preferred_model() {
  if [[ ! -f "$CRED_PATH" ]]; then
    echo ""
    return 0
  fi
  "$JQ_BIN" -r '.preferred_model // ""' "$CRED_PATH" 2>/dev/null
}

# pn_resolve_model
# Resolves which model to use for a /v1/messages scan. Precedence:
# PARADIGM_NETWORKS_MODEL env var (a manual override -- only takes effect
# if something exports it directly into the process environment, e.g. a
# shared-host setup; there is no Cursor Settings UI for this -- an
# earlier version had one, but it was removed after confirming, against
# a real installed plugin, that Cursor's plugin Settings panel never
# delivers configured values to hook scripts) > the model saved locally
# via the paradigmnetworks-models skill / set-model.sh
# (pn_get_preferred_model, above -- this is the real, user-facing way to
# change it) > PN_DEFAULT_MODEL.
#
# Formerly this exact precedence chain (constant + three-way if/fi) was
# duplicated by hand across six files (check-prompt.sh/.ps1, check-
# write.sh/.ps1, paradigmnetworks-models.sh/.ps1) -- a stale default in
# one file would mean prompts and writes get scanned by a different model
# than the one paradigmnetworks-models reports as current, exactly the
# kind of drift nobody notices until it matters (P2-3).
#
# Sets PN_RESOLVED_MODEL and PN_RESOLVED_MODEL_IS_DEFAULT ("true"/"false"
# -- paradigmnetworks-models.sh needs to know this to print "(default)")
# as globals, same "plain statement call, not $(...)" contract as
# CALLBACK_CODE/etc in login.sh, since a second value can't ride along a
# plain return.
PN_DEFAULT_MODEL="anthropic/claude-haiku-4-5-20251001"
PN_RESOLVED_MODEL=""
PN_RESOLVED_MODEL_IS_DEFAULT="false"
pn_resolve_model() {
  PN_RESOLVED_MODEL="${PARADIGM_NETWORKS_MODEL:-}"
  if [[ -z "$PN_RESOLVED_MODEL" ]]; then
    PN_RESOLVED_MODEL="$(pn_get_preferred_model)"
  fi
  if [[ -z "$PN_RESOLVED_MODEL" ]]; then
    PN_RESOLVED_MODEL="$PN_DEFAULT_MODEL"
    PN_RESOLVED_MODEL_IS_DEFAULT="true"
  else
    PN_RESOLVED_MODEL_IS_DEFAULT="false"
  fi
}

# Refresh an expired access token
pn_refresh_token() {
  local base_url="$1"
  local refresh_token="$2"

  local token_url="${base_url%/}/api/v1/plugin/token"

  # urlencode_strict (lib/common.sh): a refresh token is just as capable of
  # containing a URL-reserved character as an authorization code is (see
  # login.sh's exchange_code, which already encodes every field it sends).
  # An unencoded "+" in particular is common in base64-ish tokens and
  # decodes server-side as a space, so an affected refresh silently
  # corrupts the token instead of erroring clearly -- the failure mode is
  # "user is mysteriously logged out" on whichever refresh first hits one.
  local body
  body="grant_type=refresh_token&refresh_token=$(urlencode_strict "$refresh_token")&client_id=$(urlencode_strict "$CLIENT_ID")"

  local response
  response=$(curl -s -X POST "$token_url" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-raw "$body" \
    --max-time "$TOKEN_TIMEOUT_SECONDS" 2>/dev/null)

  if [[ -z "$response" ]]; then
    return 1
  fi

  # Validate response has required fields
  "$JQ_BIN" -e '.access_token and .refresh_token and .expires_in' <<<"$response" >/dev/null 2>&1 || {
    return 1
  }

  echo "$response"
}

# Get valid access token, refreshing if needed
pn_get_valid_access_token() {
  local creds
  creds=$(pn_load_credentials) || return 1

  local base_url
  local access_token
  local refresh_token
  local expires_at

  base_url=$(echo "$creds" | "$JQ_BIN" -r '.base_url')
  access_token=$(echo "$creds" | "$JQ_BIN" -r '.access_token')
  refresh_token=$(echo "$creds" | "$JQ_BIN" -r '.refresh_token')
  expires_at=$(echo "$creds" | "$JQ_BIN" -r '.expires_at | floor' 2>/dev/null)

  # Guard against a corrupted/malformed credentials file crashing the
  # arithmetic below outright — treat an unparseable value as already
  # expired so it forces a refresh rather than blindly trusting it.
  if ! [[ "$expires_at" =~ ^[0-9]+$ ]]; then
    expires_at=0
  fi

  local now
  now=$(date +%s)

  local time_until_expiry
  time_until_expiry=$((expires_at - now))

  # If token is still valid for > 60 seconds, use it as-is
  if [[ $time_until_expiry -gt $EXPIRY_MARGIN_SECONDS ]]; then
    echo "$base_url $access_token"
    return 0
  fi

  # Token is expiring soon, refresh it
  local refreshed
  refreshed=$(pn_refresh_token "$base_url" "$refresh_token") || return 1

  local new_access_token
  local new_refresh_token
  local expires_in

  new_access_token=$(echo "$refreshed" | "$JQ_BIN" -r '.access_token')
  new_refresh_token=$(echo "$refreshed" | "$JQ_BIN" -r '.refresh_token')
  expires_in=$(echo "$refreshed" | "$JQ_BIN" -r '.expires_in | floor' 2>/dev/null)

  # A non-numeric expires_in means the refresh response itself is malformed —
  # treat this the same as a failed refresh rather than crash on arithmetic
  # or persist a bogus expiry to disk.
  if [[ -z "$new_access_token" ]] || [[ -z "$new_refresh_token" ]] || ! [[ "$expires_in" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  local new_expires_at
  new_expires_at=$((now + expires_in))

  pn_save_credentials "$base_url" "$new_access_token" "$new_refresh_token" "$new_expires_at" || return 1

  echo "$base_url $new_access_token"
  return 0
}

# Resolve config: PARADIGM_NETWORKS_URL/PARADIGM_NETWORKS_TOKEN env vars
# take precedence, then the stored file (with refresh).
pn_resolve_config() {
  local env_base
  local env_token

  env_base="${PARADIGM_NETWORKS_URL:-}"
  env_token="${PARADIGM_NETWORKS_TOKEN:-}"

  if [[ -n "$env_base" ]] && [[ -n "$env_token" ]]; then
    echo "$env_base $env_token"
    return 0
  fi

  # Fall back to file-based config with refresh
  pn_get_valid_access_token
}

# Check if Paradigm Networks is configured (simplified, just checks if credentials exist)
pn_is_configured() {
  pn_load_credentials >/dev/null 2>&1
}
