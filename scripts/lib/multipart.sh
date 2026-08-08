#!/bin/bash
# Multipart form-data body builder
# Used by API scanning hooks to POST text fields to CodeDefense

# Generate a stable boundary (matches Python's boundary format)
multipart_boundary() {
  echo "----SnantizerBoundary7d1f3a"
}

# Build a multipart/form-data body from key-value pairs
# Usage: build_multipart_body field_name field_value [field_name field_value ...]
# Returns: raw binary body (with \r\n line endings as per HTTP spec)
build_multipart_body() {
  local boundary
  boundary=$(multipart_boundary)

  local body=""

  while [[ $# -gt 0 ]]; do
    local field_name="$1"
    local field_value="$2"
    shift 2

    body="${body}--${boundary}"$'\r\n'
    body="${body}Content-Disposition: form-data; name=\"${field_name}\""$'\r\n'
    body="${body}"$'\r\n'
    body="${body}${field_value}"$'\r\n'
  done

  body="${body}--${boundary}--"$'\r\n'

  echo -n "$body"
}

# Get the Content-Type header value for a boundary
multipart_content_type() {
  local boundary
  boundary=$(multipart_boundary)
  echo "multipart/form-data; boundary=$boundary"
}
