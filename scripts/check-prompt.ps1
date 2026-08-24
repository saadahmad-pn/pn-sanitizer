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
# 40s (not 20s, matching the bash side): observed directly that
# establishing the HTTPS connection to the scan API from a real Windows
# target can itself take ~20-25s (likely a slow/blocked certificate
# revocation check), before any actual server-side work even starts --
# a stopgap while that root cause is investigated separately.
$TimeoutSeconds = 40
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

Write-DebugLog -Message "===== check-prompt.ps1 invoked ===== HOME=$HOME | USERPROFILE=$env:USERPROFILE | USERNAME=$env:USERNAME | CredPath=$($Script:PnCredPath) | CredFileExists=$(Test-Path $Script:PnCredPath)" -LogPath $DebugLogPath

try {
  $payload = Get-StdinText
  Write-DebugLog -Message "Read stdin | length=$($payload.Length)" -LogPath $DebugLogPath

  $parsedPayload = $null
  try {
    $parsedPayload = $payload | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-DebugLog -Message "Payload failed to parse as JSON | error=$($_.Exception.Message) | raw(first 300 chars)=$($payload.Substring(0, [Math]::Min(300, $payload.Length)))" -LogPath $DebugLogPath
    Write-JsonDeny -Message "Received invalid input. Prompt blocked."
    return
  }

  $prompt = [string](Get-JsonProperty -InputObject $parsedPayload -Name "prompt" -Default "")

  # Temporary, extra-verbose diagnostic: mirrors the manual field-by-field
  # check exactly, from inside this hook's own process, so a mismatch
  # against a manual interactive check points straight at an environment
  # difference (e.g. $HOME) rather than the credentials file's content.
  if (Test-Path $Script:PnCredPath -PathType Leaf) {
    try {
      $diagRaw = Get-Utf8FileText -Path $Script:PnCredPath
      $diagParsed = $diagRaw | ConvertFrom-Json -ErrorAction Stop
      Write-DebugLog -Message "DIAG credentials file | has base_url=$([bool]$diagParsed.base_url) has access_token=$([bool]$diagParsed.access_token) has refresh_token=$([bool]$diagParsed.refresh_token) has expires_at=$([bool]$diagParsed.expires_at)" -LogPath $DebugLogPath
    } catch {
      Write-DebugLog -Message "DIAG credentials file exists but failed to parse | error=$($_.Exception.Message)" -LogPath $DebugLogPath
    }
  } else {
    Write-DebugLog -Message "DIAG credentials file does not exist at $($Script:PnCredPath)" -LogPath $DebugLogPath
  }

  Write-DebugLog -Message "Resolving config (may refresh an expiring token)..." -LogPath $DebugLogPath
  $config = Resolve-PnConfig
  Write-DebugLog -Message "Config resolved | configured=$($null -ne $config)" -LogPath $DebugLogPath
  if ($null -eq $config) {
    Write-JsonAllow -Message "Paradigm Networks is not configured (no login found). Allowing prompt -- run the paradigmnetworks-login skill to authenticate Paradigm Networks. Don't have one yet? Sign up at https://signup.claude-demo.paradigmnetworks.ai/signup."
    return
  }

  $scanUrl = $ScanUrlOverride
  if (-not $scanUrl) {
    $scanUrl = "$($config.BaseUrl.TrimEnd('/'))/api/v1/codedefense/scan"
  }

  Write-DebugLog -Message "Scanning prompt | base_url=$($config.BaseUrl) | scan_url=$scanUrl | prompt_len=$($prompt.Length) | timeout=${TimeoutSeconds}s" -LogPath $DebugLogPath

  $callStart = Get-Date
  Write-DebugLog -Message "POST starting -> $scanUrl" -LogPath $DebugLogPath
  $result = Invoke-ScanHttpPost -Url $scanUrl -TextData $prompt -AuthToken $config.AccessToken -TimeoutSec $TimeoutSeconds
  $elapsedMs = [int]((Get-Date) - $callStart).TotalMilliseconds

  $bodyPreview = ""
  if ($result.Body) {
    $bodyPreview = $result.Body.Substring(0, [Math]::Min(500, $result.Body.Length))
  }
  Write-DebugLog -Message "POST returned after ${elapsedMs}ms | TimedOut=$($result.TimedOut) | ConnectionFailed=$($result.ConnectionFailed) | StatusCode=$($result.StatusCode) | body(first 500 chars)=$bodyPreview" -LogPath $DebugLogPath

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
      # Mirrors scripts/check-prompt.sh's block-message formatting:
      # confirmed on the bash side that newlines and **bold** both render
      # correctly in Cursor's UI, and that wrapping the flagged reason
      # (e.g. "privilege escalation") in `inline code` reads well too.
      # Heuristic, not a structured field from the API response -- matches
      # the two message shapes observed so far ("...security concerns:
      # X." and "...security concerns (X, Y) and..."); falls back to the
      # message unmodified if neither pattern matches.
      $highlightedMessage = $message
      if ($message -match 'security concerns:?\s*\(?([^.)]+)[.\)]') {
        $reason = $Matches[1]
        $highlightedMessage = $message -replace [regex]::Escape($reason), ('`' + $reason + '`')
      }
      Write-JsonDeny -Message "**[Paradigm Networks]**`n`n$highlightedMessage"
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
  Write-DebugLog -Message "UNEXPECTED ERROR | $($_.Exception.GetType().FullName): $($_.Exception.Message)" -LogPath $DebugLogPath
  Write-JsonAllow -Message "The scanning service is unreachable. Allowing prompt."
}
