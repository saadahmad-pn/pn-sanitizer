# beforeSubmitPrompt hook (Windows): scan prompt via Paradigm Networks API
# before submitting. Returns {continue: true/false, user_message: "..."}.
# Mirrors scripts/check-prompt.sh -- see that file's comments for the
# reasoning behind which failures honor PROMPT_FAILURE_MODE and which
# (not-configured) always allow unconditionally.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$ScanUrlOverride = $env:SNANTIZER_SCAN_URL
$TimeoutSeconds = 20
if ($env:SNANTIZER_TIMEOUT) {
  $parsedTimeout = 0
  if ([int]::TryParse($env:SNANTIZER_TIMEOUT, [ref]$parsedTimeout)) {
    $TimeoutSeconds = $parsedTimeout
  }
}
$DebugLogPath = Join-Path $HOME ".paradigm-scanner\check-prompt.log"

$rawMode = $env:PARADIGM_NETWORKS_PROMPT_FAILURE_MODE
if (-not $rawMode) { $rawMode = $env:SNANTIZER_PROMPT_FAILURE_MODE }
if (-not $rawMode) { $rawMode = "allow" }
$rawMode = $rawMode.ToLowerInvariant()
$PromptFailureMode = if ($rawMode -eq "block" -or $rawMode -eq "closed") { "closed" } else { "open" }

try {
  $payload = Get-StdinText

  $parsedPayload = $null
  try {
    $parsedPayload = $payload | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-JsonDeny -Message "Received invalid input. Prompt blocked."
    return
  }

  $prompt = [string](Get-JsonProperty -InputObject $parsedPayload -Name "prompt" -Default "")

  $config = Resolve-PnConfig
  if ($null -eq $config) {
    Write-JsonAllow -Message "Paradigm Networks is not configured (no login found). Allowing prompt -- run the paradigmnetworks-login skill to authenticate Paradigm Networks. Don't have one yet? Sign up at https://signup.claude-demo.paradigmnetworks.ai/signup."
    return
  }

  $scanUrl = $ScanUrlOverride
  if (-not $scanUrl) {
    $scanUrl = "$($config.BaseUrl.TrimEnd('/'))/api/v1/codedefense/scan"
  }

  Write-DebugLog -Message "Scanning prompt | base_url=$($config.BaseUrl) | scan_url=$scanUrl | prompt_len=$($prompt.Length)" -LogPath $DebugLogPath
  Write-DebugLog -Message "Timeout: ${TimeoutSeconds}s" -LogPath $DebugLogPath

  $result = Invoke-ScanHttpPost -Url $scanUrl -TextData $prompt -AuthToken $config.AccessToken -TimeoutSec $TimeoutSeconds

  if ($result.TimedOut) {
    Write-DebugLog -Message "API timeout | after ${TimeoutSeconds}s | url=$scanUrl" -LogPath $DebugLogPath
    if ($PromptFailureMode -eq "closed") {
      Write-JsonDeny -Message "The scanning service timed out (${TimeoutSeconds}s). Prompt blocked."
    } else {
      Write-JsonAllow -Message "The scanning service timed out (${TimeoutSeconds}s). Allowing prompt."
    }
    return
  }
  if ($result.ConnectionFailed) {
    Write-DebugLog -Message "API unreachable | url=$scanUrl" -LogPath $DebugLogPath
    if ($PromptFailureMode -eq "closed") {
      Write-JsonDeny -Message "The scanning service is unreachable. Prompt blocked."
    } else {
      Write-JsonAllow -Message "The scanning service is unreachable. Allowing prompt."
    }
    return
  }

  if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
    Write-DebugLog -Message "API HTTP error | status=$($result.StatusCode) | url=$scanUrl" -LogPath $DebugLogPath
    if ($PromptFailureMode -eq "closed") {
      Write-JsonDeny -Message "The scanning service returned an error (HTTP $($result.StatusCode)). Prompt blocked."
    } else {
      Write-JsonAllow -Message "The scanning service returned an error (HTTP $($result.StatusCode)). Allowing prompt."
    }
    return
  }

  $responseObject = $null
  try {
    $responseObject = $result.Body | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-DebugLog -Message "API invalid JSON response | url=$scanUrl" -LogPath $DebugLogPath
    if ($PromptFailureMode -eq "closed") {
      Write-JsonDeny -Message "The scanning service returned an invalid response. Prompt blocked."
    } else {
      Write-JsonAllow -Message "The scanning service returned an invalid response. Allowing prompt."
    }
    return
  }

  $action = Get-JsonProperty -InputObject $responseObject -Name "action_to_take" -Default "allow"
  $message = Get-JsonProperty -InputObject $responseObject -Name "message" -Default "Prompt blocked by Paradigm Networks."

  Write-DebugLog -Message "API response received | action=$action" -LogPath $DebugLogPath

  switch ($action) {
    "block" {
      Write-JsonDeny -Message "[Paradigm Networks] $message"
    }
    "warn" {
      Write-JsonAllow -Message $message
    }
    default {
      Write-JsonAllow
    }
  }
} catch {
  # Anything unexpected -- fail open, same posture as an unreachable API.
  Write-JsonAllow -Message "The scanning service is unreachable. Allowing prompt."
}
