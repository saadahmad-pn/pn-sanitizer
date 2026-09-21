# sessionEnd hook (Windows): finalizes this conversation's Code Chain
# session, if one was ever registered. Mirrors scripts/check-session-end.sh
# -- see that file's header for the full rationale. Fire-and-forget per
# Cursor's hooks contract; cannot affect session teardown.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "lib\codechain-client.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$CodechainTimeoutSec = if ($env:PARADIGM_NETWORKS_CODECHAIN_TIMEOUT) { [int]$env:PARADIGM_NETWORKS_CODECHAIN_TIMEOUT } else { 5 }

$stdinText = Get-StdinText

try {
  if ($stdinText) {
    $payload = $stdinText | ConvertFrom-Json -ErrorAction Stop
    $clientSessionId = Get-JsonProperty -InputObject $payload -Name "conversation_id" -Default ""
    if (-not $clientSessionId) {
      $clientSessionId = Get-JsonProperty -InputObject $payload -Name "session_id" -Default ""
    }
    if ($clientSessionId -and (Test-PnConfigured)) {
      $config = Resolve-PnConfig
      Close-CodechainSession -BaseUrl $config.BaseUrl -AccessToken $config.AccessToken -TimeoutSec $CodechainTimeoutSec -ClientSessionId $clientSessionId
    }
  }
} catch {
  # Never let a recording failure surface -- this hook always returns {}.
}

Write-Output "{}"
