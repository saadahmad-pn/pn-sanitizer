# TEMPORARY. Not part of the product -- delete this file and its hooks.json
# entries once the afterShellExecution/postToolUse payload shape is confirmed.
# Mirrors scripts/debug-capture-payload.sh -- see that file's comment.

$CaptureLog = Join-Path $HOME ".paradigm-scanner\hook-capture.jsonl"
$dir = Split-Path -Parent $CaptureLog
if ($dir -and -not (Test-Path $dir)) {
  New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
}

$payload = ""
try {
  $stdin = [Console]::OpenStandardInput()
  $reader = New-Object System.IO.StreamReader($stdin, [System.Text.Encoding]::UTF8)
  $payload = $reader.ReadToEnd()
} catch {
  $payload = ""
}

try {
  Add-Content -Path $CaptureLog -Value $payload -Encoding UTF8 -ErrorAction SilentlyContinue
} catch {
  # Non-fatal -- this hook must never fail a real tool call.
}

Write-Output "{}"
