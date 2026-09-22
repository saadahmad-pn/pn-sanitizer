#!/bin/bash
# Mock Paradigm Networks API server for testing
# Usage: start_mock_server <port> [mode]
# Modes: allow, block, anomaly, timeout, error500, error401,
#        detections_allow, detections_warn, detections_block
#
# The detections_* modes return the standardized plugins domain response
# shape (action_to_take/message/overall_threat_level/triggered_by/ToolUseId
# -- see control-server's ScanOutcome/ToolCallResult/ShellExecutionResult)
# for testing check-prompt.sh/check-tool-call.sh/check-git-event.sh against
# lib/plugins-client.sh. Kept the "detections_*" mode names for minimal
# test-file churn even though the retired /api/v1/detections/evaluate
# endpoint no longer exists -- these now stand in for any of the three
# gating domains' before_* verdict shape, which is identical across all
# three.
#
# The non-detections modes (allow/block/anomaly/timeout/error500/error401)
# return the /v1/messages (Anthropic-compatible) response shape -- LEGACY,
# unused scaffolding from before this plugin called control-server's
# composite scan endpoints at all. Left in place rather than removed
# outright.

PORT=""
MODE="allow"
TEMP_FIFO=""
RUNNING=0

start_mock_server() {
  PORT="${1:-9999}"
  MODE="${2:-allow}"

  TEMP_FIFO=$(mktemp -d)/fifo
  mkfifo "$TEMP_FIFO"

  {
    while true; do
      if read -r line <"$TEMP_FIFO"; then
        # Parse HTTP request
        if [[ "$line" == *"POST"* ]] || [[ "$line" == *"GET"* ]]; then
          # Read headers and body
          read_http_request

          # Generate response based on mode
          case "$MODE" in
            allow)
              send_response "200" '{"content":[{"type":"text","text":"mock allow reply"}],"usage":{"input_tokens":10,"output_tokens":5}}'
              ;;
            block)
              send_response "200" '{"content":[{"type":"text","text":"```\n========================================================================\n  REQUEST BLOCKED\n========================================================================\n\n  The submitted content was flagged because it triggered the following security concerns: mock policy violation.\n\n========================================================================\n```"}],"usage":{"input_tokens":0,"output_tokens":0}}'
              ;;
            anomaly)
              send_response "200" '{"content":[{"type":"text","text":"mock anomaly: zero usage without a block banner"}],"usage":{"input_tokens":0,"output_tokens":0}}'
              ;;
            timeout)
              # Don't respond (causes timeout)
              sleep 10
              ;;
            error500)
              send_response "500" '{"error": "Internal server error"}'
              ;;
            error401)
              send_response "401" '{"error": "Unauthorized"}'
              ;;
            detections_allow)
              send_response "200" '{"action_to_take":"allow","message":"","overall_threat_level":"","ToolUseId":"mock-tool-use-id"}'
              ;;
            detections_warn)
              send_response "200" '{"action_to_take":"warn","message":"mock policy warning","overall_threat_level":"low","triggered_by":["code_defense"],"ToolUseId":"mock-tool-use-id"}'
              ;;
            detections_block)
              send_response "200" '{"action_to_take":"block","message":"mock policy violation","overall_threat_level":"high","triggered_by":["code_defense"],"ToolUseId":"mock-tool-use-id"}'
              ;;
          esac
        fi
      fi
    done
  } &

  sleep 0.1
  RUNNING=1
  echo "$!"
}

read_http_request() {
  local line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == *$'\r' ]] && break
  done <"$TEMP_FIFO"
}

send_response() {
  local status_code="$1"
  local body="$2"

  local response="HTTP/1.1 $status_code OK\r\nContent-Type: application/json\r\nContent-Length: ${#body}\r\n\r\n$body"
  echo -ne "$response" >"$TEMP_FIFO"
}

stop_mock_server() {
  if [[ $RUNNING -eq 1 ]]; then
    if [[ -n "$TEMP_FIFO" ]] && [[ -d "$(dirname "$TEMP_FIFO")" ]]; then
      rm -f "$TEMP_FIFO"
      rmdir "$(dirname "$TEMP_FIFO")" 2>/dev/null || true
    fi
    RUNNING=0
  fi
}

# Simpler approach: use bash TCP redirection
start_simple_mock_server() {
  local port="$1"
  local mode="${2:-allow}"
  local response_file
  response_file=$(mktemp)

  case "$mode" in
    allow)
      echo '{"content":[{"type":"text","text":"mock allow reply"}],"usage":{"input_tokens":10,"output_tokens":5}}' >"$response_file"
      ;;
    block)
      echo '{"content":[{"type":"text","text":"```\n========================================================================\n  REQUEST BLOCKED\n========================================================================\n\n  The submitted content was flagged because it triggered the following security concerns: mock policy violation.\n\n========================================================================\n```"}],"usage":{"input_tokens":0,"output_tokens":0}}' >"$response_file"
      ;;
    anomaly)
      echo '{"content":[{"type":"text","text":"mock anomaly: zero usage without a block banner"}],"usage":{"input_tokens":0,"output_tokens":0}}' >"$response_file"
      ;;
    error500)
      echo 'HTTP/1.1 500 Internal Server Error\r\n\r\n{"error": "server error"}' >"$response_file"
      ;;
    error401)
      echo 'HTTP/1.1 401 Unauthorized\r\n\r\n{"error": "unauthorized"}' >"$response_file"
      ;;
    detections_allow)
      echo '{"Decision":"allow","Message":"","FileAnalyses":[],"LatencyMs":0,"AuditId":"mock-scan-allow"}' >"$response_file"
      ;;
    detections_warn)
      echo '{"Decision":"warn","Message":"mock policy warning","FileAnalyses":[{"Filename":"app.py","ThreatLevel":"low","ActionToTake":"warn","Categories":["mock-category"]}],"LatencyMs":0,"AuditId":"mock-scan-warn"}' >"$response_file"
      ;;
    detections_block)
      echo '{"Decision":"block","Message":"mock policy violation","FileAnalyses":[{"Filename":"app.py","ThreatLevel":"high","ActionToTake":"block","Categories":["mock-category"]}],"LatencyMs":0,"AuditId":"mock-scan-block"}' >"$response_file"
      ;;
  esac

  # Use Python as a lightweight mock server
  python3 <<PYTHON_SCRIPT &
import socket
import time
import json

PORT = $port
MODE = "$mode"

def handle_request(client_socket, response_file):
    try:
        request = client_socket.recv(4096).decode('utf-8', errors='replace')

        if MODE == 'timeout':
            time.sleep(10)  # Cause timeout
        else:
            with open(response_file, 'r') as f:
                body = f.read()

            if 'HTTP/1.1' in body:
                response = body
            else:
                response = f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n{body}"

            client_socket.sendall(response.encode())
    except Exception as e:
        pass
    finally:
        client_socket.close()

server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server_socket.bind(('127.0.0.1', PORT))
server_socket.listen(5)
server_socket.settimeout(15)  # Listen for 15 seconds

try:
    while True:
        try:
            client_socket, address = server_socket.accept()
            handle_request(client_socket, "$response_file")
        except socket.timeout:
            break
except Exception as e:
    pass
finally:
    server_socket.close()
PYTHON_SCRIPT

  echo "$response_file"
}

stop_simple_mock_server() {
  local response_file="$1"
  if [[ -n "$response_file" ]] && [[ -f "$response_file" ]]; then
    rm -f "$response_file"
  fi
}
