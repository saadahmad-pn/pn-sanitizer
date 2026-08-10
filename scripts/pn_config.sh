#!/bin/bash
# Credential and config management for PN hook scripts
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

  jq -e '.base_url and .access_token and .refresh_token and .expires_at' "$CRED_PATH" >/dev/null 2>&1 || {
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

  local creds_json
  creds_json=$(jq -n \
    --arg base_url "$base_url" \
    --arg access_token "$access_token" \
    --arg refresh_token "$refresh_token" \
    --argjson expires_at "$expires_at" \
    '{base_url: $base_url, access_token: $access_token, refresh_token: $refresh_token, expires_at: $expires_at}')

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

# Refresh an expired access token
pn_refresh_token() {
  local base_url="$1"
  local refresh_token="$2"

  local token_url="${base_url%/}/api/v1/plugin/token"

  local body
  body=$(cat <<EOF
grant_type=refresh_token&refresh_token=${refresh_token}&client_id=${CLIENT_ID}
EOF
)

  local response
  response=$(curl -s -X POST "$token_url" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-raw "$body" \
    --max-time "$TOKEN_TIMEOUT_SECONDS" 2>/dev/null)

  if [[ -z "$response" ]]; then
    return 1
  fi

  # Validate response has required fields
  jq -e '.access_token and .refresh_token and .expires_in' <<<"$response" >/dev/null 2>&1 || {
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

  base_url=$(echo "$creds" | jq -r '.base_url')
  access_token=$(echo "$creds" | jq -r '.access_token')
  refresh_token=$(echo "$creds" | jq -r '.refresh_token')
  expires_at=$(echo "$creds" | jq -r '.expires_at | floor')

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

  new_access_token=$(echo "$refreshed" | jq -r '.access_token')
  new_refresh_token=$(echo "$refreshed" | jq -r '.refresh_token')
  expires_in=$(echo "$refreshed" | jq -r '.expires_in | floor')

  if [[ -z "$new_access_token" ]] || [[ -z "$new_refresh_token" ]]; then
    return 1
  fi

  local new_expires_at
  new_expires_at=$((now + ${expires_in%.*}))

  pn_save_credentials "$base_url" "$new_access_token" "$new_refresh_token" "$new_expires_at" || return 1

  echo "$base_url $new_access_token"
  return 0
}

# Resolve config: env vars take precedence, then file
pn_resolve_config() {
  local env_base_var="${1:-SNANTIZER_BASE_URL}"
  local env_token_var="${2:-SNANTIZER_TOKEN}"

  local env_base
  local env_token

  env_base="${!env_base_var:-}"
  env_token="${!env_token_var:-}"

  # Env vars take precedence
  if [[ -n "$env_base" ]] && [[ -n "$env_token" ]]; then
    echo "$env_base $env_token"
    return 0
  fi

  # Fall back to file-based config with refresh
  pn_get_valid_access_token
}

# Check if PN is configured (simplified, just checks if credentials exist)
pn_is_configured() {
  pn_load_credentials >/dev/null 2>&1
}
