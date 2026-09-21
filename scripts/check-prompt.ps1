# beforeSubmitPrompt hook (Windows): scan prompt via Paradigm Networks API
# before submitting. Returns {continue: true/false, user_message: "..."}.
# Mirrors scripts/check-prompt.sh -- see that file's comments for the
# reasoning behind which failures honor PROMPT_FAILURE_MODE and which
# (not-configured) always allow unconditionally.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "lib\git-utils.ps1")
. (Join-Path $ScriptDir "lib\scan-client.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$TimeoutSeconds = 60
if ($env:PARADIGM_NETWORKS_TIMEOUT) {
  $parsedTimeout = 0
  if ([int]::TryParse($env:PARADIGM_NETWORKS_TIMEOUT, [ref]$parsedTimeout)) {
    $TimeoutSeconds = $parsedTimeout
  }
}
$DebugLogPath = Join-Path $HOME ".paradigm-scanner\check-prompt.log"

$rawMode = $env:PARADIGM_NETWORKS_PROMPT_FAILURE_MODE
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
    # Deliberately always allow here, unlike the $PromptFailureMode-driven
    # branches below: a malformed payload usually signals a Cursor
    # integration/encoding quirk, not an unreachable scanner.
    Write-JsonAllow -Message "Received invalid input. Allowing prompt -- it was not scanned."
    return
  }

  $prompt = [string](Get-JsonProperty -InputObject $parsedPayload -Name "prompt" -Default "")

  # Session id + cwd (for the scan call's chatapi join and context -- see
  # lib/scan-client.ps1's header) and derive git context from cwd the same
  # way every other hook here does.
  $clientSessionId = [string](Get-JsonProperty -InputObject $parsedPayload -Name "conversation_id" -Default "")
  if (-not $clientSessionId) {
    $clientSessionId = [string](Get-JsonProperty -InputObject $parsedPayload -Name "session_id" -Default "")
  }
  $cwd = [string](Get-JsonProperty -InputObject $parsedPayload -Name "cwd" -Default "")
  if (-not $cwd) {
    $roots = @(Get-JsonProperty -InputObject $parsedPayload -Name "workspace_roots" -Default @())
    if ($roots.Count -gt 0) { $cwd = $roots[0] }
  }
  $gitRepoUrl = ""
  $gitBranch = ""
  if ($cwd -and (Test-Path (Join-Path $cwd ".git"))) {
    $gitRepoUrl = Get-GitRemoteUrlOrEmpty -RepoPath $cwd
    $gitBranch = Get-GitCurrentBranchOrEmpty -RepoPath $cwd
  }

  Write-DebugLog -Message "Resolving config (may refresh an expiring token)..." -LogPath $DebugLogPath
  $config = Resolve-PnConfig
  Write-DebugLog -Message "Config resolved | configured=$($null -ne $config)" -LogPath $DebugLogPath
  if ($null -eq $config) {
    Write-JsonAllow -Message "Paradigm Networks is not configured (no login found). Allowing prompt -- run the paradigmnetworks-login skill to authenticate Paradigm Networks. Don't have one yet? Sign up at https://signup.claude-demo.paradigmnetworks.ai/signup."
    return
  }

  Write-DebugLog -Message "Scanning prompt | base_url=$($config.BaseUrl) | prompt_len=$($prompt.Length) | timeout=${TimeoutSeconds}s" -LogPath $DebugLogPath

  # Invoke-PnScanText (lib/scan-client.ps1) posts to the composite
  # PromptGuard+PolicyEngine+CodeDefense scan endpoint -- no model
  # invocation, a real structured Action verdict instead of the old
  # /v1/messages zero-usage/banner-text heuristic.
  $callStart = Get-Date
  $scanResult = Invoke-PnScanText -BaseUrl $config.BaseUrl -AccessToken $config.AccessToken -TimeoutSec $TimeoutSeconds `
    -SessionId $clientSessionId -Cwd $cwd -GitRepoUrl $gitRepoUrl -GitBranch $gitBranch -Text $prompt
  $elapsedMs = [int]((Get-Date) - $callStart).TotalMilliseconds
  Write-DebugLog -Message "Scan returned after ${elapsedMs}ms | Status=$($scanResult.Status) | Action=$($scanResult.Action)" -LogPath $DebugLogPath

  switch ($scanResult.Status) {
    "no_session" {
      # Every beforeSubmitPrompt payload observed so far has carried
      # conversation_id, so this is not expected in practice.
      if ($PromptFailureMode -eq "closed") {
        Write-JsonDeny -Message "The scanning service could not be reached (no session id available). Prompt blocked."
      } else {
        Write-JsonAllow -Message "The scanning service could not be reached (no session id available). Allowing prompt."
      }
      return
    }
    "timeout" {
      if ($PromptFailureMode -eq "closed") {
        Write-JsonDeny -Message "The scanning service timed out (${TimeoutSeconds}s). Prompt blocked."
      } else {
        Write-JsonAllow -Message "The scanning service timed out (${TimeoutSeconds}s). Allowing prompt."
      }
      return
    }
    "unreachable" {
      if ($PromptFailureMode -eq "closed") {
        Write-JsonDeny -Message "The scanning service is unreachable. Prompt blocked."
      } else {
        Write-JsonAllow -Message "The scanning service is unreachable. Allowing prompt."
      }
      return
    }
    "http_error" {
      if ($PromptFailureMode -eq "closed") {
        Write-JsonDeny -Message "The scanning service returned an error (HTTP $($scanResult.HttpStatus)). Prompt blocked."
      } else {
        Write-JsonAllow -Message "The scanning service returned an error (HTTP $($scanResult.HttpStatus)). Allowing prompt."
      }
      return
    }
    "invalid_json" {
      if ($PromptFailureMode -eq "closed") {
        Write-JsonDeny -Message "The scanning service returned an invalid response. Prompt blocked."
      } else {
        Write-JsonAllow -Message "The scanning service returned an invalid response. Allowing prompt."
      }
      return
    }
  }

  switch ($scanResult.Action) {
    { [string]::IsNullOrEmpty($_) } {
      # A valid JSON response with no recognized action_to_take -- an
      # unexpected response shape, not a confirmed verdict either way.
      Write-DebugLog -Message "Scan response shape unexpected (no recognized action_to_take)" -LogPath $DebugLogPath
      $anomalyStreak = Add-PnScanAnomaly
      $anomalyPrefix = ""
      if ($anomalyStreak -ge $Script:PnAnomalyWarningThreshold) {
        $warningSign = "$([char]0x26A0)$([char]0xFE0F)"
        $anomalyPrefix = "$warningSign Security scanning has failed $anomalyStreak times in a row and may not be protecting you right now. Contact your administrator. "
      }
      if ($scanResult.Message) {
        if ($PromptFailureMode -eq "closed") {
          Write-JsonDeny -Message "${anomalyPrefix}$($scanResult.Message)"
        } else {
          Write-JsonAllow -Message "${anomalyPrefix}$($scanResult.Message)"
        }
      } else {
        if ($PromptFailureMode -eq "closed") {
          Write-JsonDeny -Message "${anomalyPrefix}The scanning service returned an unexpected response. Prompt blocked."
        } else {
          Write-JsonAllow -Message "${anomalyPrefix}The scanning service returned an unexpected response. Allowing prompt."
        }
      }
    }
    "block" {
      Set-PnLastSuccessfulScan
      # Markdown formatting confirmed rendering correctly in Cursor's UI.
      $reason = $scanResult.Message
      if (-not $reason) { $reason = "A policy violation was detected." }

      # Preview of the actual prompt that got flagged, capped at 60 words.
      $flaggedPreview = ($prompt -replace '\s+', ' ').Trim()
      $words = @($flaggedPreview -split ' ' | Where-Object { $_ -ne '' })
      $wasTruncated = $words.Count -gt 60
      $flaggedPreview = ($words | Select-Object -First 60) -join ' '
      if ($wasTruncated) {
        $flaggedPreview = "$flaggedPreview..."
      }

      if ($reason -match "`n") {
        $concernLine = "**Concern**`n`n$reason"
      } else {
        $concernLine = '**Concern** `' + $reason + '`'
      }
      $quotedContent = '> ' + $flaggedPreview

      $shieldEmoji = [char]::ConvertFromUtf32(0x1F6E1) + [char]::ConvertFromUtf32(0xFE0F)
      $brandedMessage = "### $shieldEmoji Request blocked by Paradigm Networks`n`n" +
        "This message wasn't sent to the model. Your organization's proxy inspects`n" +
        "outbound requests and held this one for review.`n`n" +
        "$concernLine`n`n" +
        "**Flagged content**`n`n" +
        "$quotedContent"
      Write-JsonDeny -Message $brandedMessage
    }
    "warn" {
      # Non-blocking: surface the scan's own explanation and let it proceed.
      Set-PnLastSuccessfulScan
      if ($scanResult.Message) {
        Write-JsonAllow -Message $scanResult.Message
      } else {
        Write-JsonAllow
      }
    }
    default {
      # "allow"
      Set-PnLastSuccessfulScan
      if ($scanResult.Message) {
        Write-JsonAllow -Message $scanResult.Message
      } else {
        Write-JsonAllow
      }
    }
  }
} catch {
  # Anything unexpected -- fail open, same posture as an unreachable API.
  Write-DebugLog -Message "UNEXPECTED ERROR | $($_.Exception.GetType().FullName): $($_.Exception.Message)" -LogPath $DebugLogPath
  Write-JsonAllow -Message "The scanning service is unreachable. Allowing prompt."
}
