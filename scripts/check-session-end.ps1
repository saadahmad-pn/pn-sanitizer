# sessionEnd hook (Windows): removes this conversation's local
# session-metadata file (see lib/session-metadata.ps1). Mirrors
# scripts/check-session-end.sh. Fire-and-forget per Cursor's hooks
# contract; cannot affect session teardown.
#
# Previously this recorded a session-end marker with control-server; that
# endpoint was removed (the marker had no consumer).

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "lib\session-metadata.ps1")

$stdinText = Get-StdinText

try {
  if ($stdinText) {
    $payload = $stdinText | ConvertFrom-Json -ErrorAction Stop
    $clientSessionId = [string](Get-JsonProperty -InputObject $payload -Name "conversation_id" -Default "")
    if (-not $clientSessionId) {
      $clientSessionId = [string](Get-JsonProperty -InputObject $payload -Name "session_id" -Default "")
    }
    if ($clientSessionId) {
      Remove-PnSessionMetadata -SessionId $clientSessionId
    }
  }
} catch {
  # Never let a cleanup failure surface -- this hook always returns {}.
}

Write-Output "{}"
