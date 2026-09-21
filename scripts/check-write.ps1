# preToolUse hook (Windows): scan agent response before Write and Shell tool calls.
# (Cursor has no separate "Edit" tool_name; all file modifications use
# "Write".) Returns {permission: "allow"/"deny", user_message: "...",
# agent_message: "..."}. Mirrors scripts/check-write.sh.

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
$TranscriptLines = 500
if ($env:PARADIGM_NETWORKS_TRANSCRIPT_LINES) {
  $parsedLines = 0
  if ([int]::TryParse($env:PARADIGM_NETWORKS_TRANSCRIPT_LINES, [ref]$parsedLines)) {
    $TranscriptLines = $parsedLines
  }
}

$rawMode = $env:PARADIGM_NETWORKS_FAILURE_MODE
if (-not $rawMode) { $rawMode = "block" }
$rawMode = $rawMode.ToLowerInvariant()
$FailureMode = if ($rawMode -eq "allow" -or $rawMode -eq "open") { "open" } else { "closed" }

$AuditLogPath = Join-Path $HOME ".paradigm-scanner\audit.jsonl"
$DebugLogPath = Join-Path $HOME ".paradigm-scanner\check-write.log"
# "relay ... in full, exactly as given" is deliberate, not just "report
# the violation": confirmed directly that a vaguer instruction lets the
# agent paraphrase the findings above into its own short summary, dropping
# specific detail in the process. Deliberately generic here (not "relay
# the OWASP findings," specifically) since the backend's categorization
# scheme isn't guaranteed to always be OWASP-flavored.
function Build-StopInstruction {
  param([string]$ActionDesc)
  return "A security scan blocked $ActionDesc due to a detected policy violation. Do not retry $ActionDesc or attempt a workaround (e.g. re-encoding it, splitting it up, or otherwise disguising it to bypass detection). Stop this task and relay the findings above to the user in full, exactly as given -- every issue, category, code, and standard name mentioned. Do not summarize or paraphrase them into a general statement; the user needs the precise details to know what to fix."
}

function Write-CheckWriteAuditLog {
  param(
    [string]$ToolName = "",
    [string]$FilePath,
    [string]$Command = "",
    [string]$Decision,
    [string]$Reason = "",
    [string]$Detail = "",
    [string]$ThreatLevel = ""
  )
  $entry = [PSCustomObject]@{ tool_name = $ToolName; file_path = $FilePath; command = $Command; decision = $Decision }
  if ($Reason) { $entry | Add-Member -NotePropertyName "reason" -NotePropertyValue $Reason | Out-Null }
  if ($Detail) { $entry | Add-Member -NotePropertyName "detail" -NotePropertyValue $Detail | Out-Null }
  if ($PSBoundParameters.ContainsKey('ThreatLevel')) { $entry | Add-Member -NotePropertyName "threat_level" -NotePropertyValue $ThreatLevel | Out-Null }
  Write-AuditLog -Entry $entry -LogPath $AuditLogPath | Out-Null
}

Write-DebugLog -Message "===== check-write.ps1 invoked =====" -LogPath $DebugLogPath

try {
  $payload = Get-StdinText
  Write-DebugLog -Message "Read stdin | length=$($payload.Length)" -LogPath $DebugLogPath

  $parsedPayload = $null
  try {
    $parsedPayload = $payload | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-JsonPermissionAllow -Message "Received invalid input."
    return
  }

  $toolName = Get-JsonProperty -InputObject $parsedPayload -Name "tool_name" -Default ""
  if ($toolName -ne "Write" -and $toolName -ne "Shell") {
    Write-JsonPermissionAllow
    return
  }

  $actionNoun = "Write"
  $actionDesc = "this write"
  if ($toolName -eq "Shell") {
    $actionNoun = "Command"
    $actionDesc = "this command"
  }

  $agentMessage = ([string](Get-JsonProperty -InputObject $parsedPayload -Name "agent_message" -Default "")).Trim()
  $transcriptPath = Get-JsonProperty -InputObject $parsedPayload -Name "transcript_path" -Default ""
  $toolInput = Get-JsonProperty -InputObject $parsedPayload -Name "tool_input" -Default $null
  $filePath = Get-JsonProperty -InputObject $toolInput -Name "file_path" -Default ""
  $fileContent = [string](Get-JsonProperty -InputObject $toolInput -Name "content" -Default "")
  $shellCommand = [string](Get-JsonProperty -InputObject $toolInput -Name "command" -Default "")

  $subject = if ($toolName -eq "Write") { $fileContent } else { $shellCommand }

  # Session id + cwd/git context for the scan call's chatapi join -- see
  # lib/scan-client.ps1's header. Same extraction pattern as every other
  # hook here.
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

  $turnText = ""
  if ($transcriptPath) {
    $turnText = Get-CurrentTurnText -TranscriptPath $transcriptPath -MaxLines $TranscriptLines
  }

  Write-DebugLog -Message "tool_input | tool_name=$toolName | file_path=$filePath | command_len=$($shellCommand.Length) | content_len=$($fileContent.Length) | turn_text_len=$($turnText.Length) | agent_message_len=$($agentMessage.Length)" -LogPath $DebugLogPath

  $scanText = ""
  $scanSource = ""
  if ($turnText -and $subject) {
    $scanText = "$turnText`n`n---`n`n$subject"
    $scanSource = "turn+subject"
  } elseif ($subject) {
    $scanText = $subject
    $scanSource = "subject"
  } elseif ($turnText) {
    $scanText = $turnText
    $scanSource = "turn"
  } elseif ($agentMessage) {
    $scanText = $agentMessage
    $scanSource = "agent_message"
  }
  Write-DebugLog -Message "Scan source selected | source=$scanSource | length=$($scanText.Length)" -LogPath $DebugLogPath

  if (-not $scanText) {
    Write-JsonPermissionAllow
    return
  }

  Write-DebugLog -Message "Resolving config (may refresh an expiring token)..." -LogPath $DebugLogPath
  $config = Resolve-PnConfig
  Write-DebugLog -Message "Config resolved | configured=$($null -ne $config)" -LogPath $DebugLogPath
  if ($null -eq $config) {
    $reason = "Paradigm Networks not configured -- run the paradigmnetworks-login skill"
    Write-CheckWriteAuditLog -ToolName $toolName -FilePath $filePath -Command $shellCommand -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
      -Reason "not_configured" -Detail $reason

    $signupNote = "Don't have one yet? Sign up at https://signup.claude-demo.paradigmnetworks.ai/signup."
    if ($FailureMode -eq "open") {
      Write-JsonPermissionAllow -Message "The scanning service is unavailable ($reason). ${actionNoun} allowed WITHOUT a security scan. $signupNote"
    } else {
      Write-JsonPermissionDeny -UserMessage "The scanning service is unavailable ($reason). ${actionNoun} blocked. $signupNote" `
        -AgentMessage "The scanning service is unavailable ($reason). Do not retry ${actionDesc}."
    }
    return
  }

  Write-DebugLog -Message "Scanning write | base_url=$($config.BaseUrl) | scan_text_len=$($scanText.Length) | timeout=${TimeoutSeconds}s" -LogPath $DebugLogPath

  $callStart = Get-Date
  $scanResult = Invoke-PnScanText -BaseUrl $config.BaseUrl -AccessToken $config.AccessToken -TimeoutSec $TimeoutSeconds `
    -SessionId $clientSessionId -Cwd $cwd -GitRepoUrl $gitRepoUrl -GitBranch $gitBranch -Text $scanText
  $elapsedMs = [int]((Get-Date) - $callStart).TotalMilliseconds
  Write-DebugLog -Message "Scan returned after ${elapsedMs}ms | Status=$($scanResult.Status) | Action=$($scanResult.Action)" -LogPath $DebugLogPath

  switch ($scanResult.Status) {
    "no_session" {
      # Every preToolUse payload observed so far has carried conversation_id,
      # so this is not expected in practice.
      Write-CheckWriteAuditLog -ToolName $toolName -FilePath $filePath -Command $shellCommand -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
        -Reason "no_session_id" -Detail "no session id available"
      if ($FailureMode -eq "open") {
        Write-JsonPermissionAllow -Message "The scanning service could not be reached (no session id available). ${actionNoun} allowed WITHOUT a security scan."
      } else {
        Write-JsonPermissionDeny -UserMessage "The scanning service could not be reached (no session id available). ${actionNoun} blocked." `
          -AgentMessage "The scanning service could not be reached (no session id available). Do not retry ${actionDesc}."
      }
      return
    }
    "timeout" {
      Write-CheckWriteAuditLog -ToolName $toolName -FilePath $filePath -Command $shellCommand -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
        -Reason "api_timeout" -Detail "${TimeoutSeconds}s timeout"
      if ($FailureMode -eq "open") {
        Write-JsonPermissionAllow -Message "The scanning service is unavailable (timed out after ${TimeoutSeconds}s). ${actionNoun} allowed WITHOUT a security scan."
      } else {
        Write-JsonPermissionDeny -UserMessage "The scanning service is unavailable (timed out after ${TimeoutSeconds}s). ${actionNoun} blocked." `
          -AgentMessage "The scanning service is unavailable (timed out after ${TimeoutSeconds}s). Do not retry ${actionDesc}."
      }
      return
    }
    "unreachable" {
      Write-CheckWriteAuditLog -ToolName $toolName -FilePath $filePath -Command $shellCommand -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
        -Reason "api_unreachable" -Detail "connection failed"
      if ($FailureMode -eq "open") {
        Write-JsonPermissionAllow -Message "The scanning service is unavailable (connection failed). ${actionNoun} allowed WITHOUT a security scan."
      } else {
        Write-JsonPermissionDeny -UserMessage "The scanning service is unavailable (connection failed). ${actionNoun} blocked." `
          -AgentMessage "The scanning service is unavailable (connection failed). Do not retry ${actionDesc}."
      }
      return
    }
    "http_error" {
      Write-CheckWriteAuditLog -ToolName $toolName -FilePath $filePath -Command $shellCommand -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
        -Reason "api_http_error" -Detail "HTTP $($scanResult.HttpStatus)"
      if ($FailureMode -eq "open") {
        Write-JsonPermissionAllow -Message "The scanning service returned an error (HTTP $($scanResult.HttpStatus)). ${actionNoun} allowed WITHOUT a security scan."
      } else {
        Write-JsonPermissionDeny -UserMessage "The scanning service returned an error (HTTP $($scanResult.HttpStatus)). ${actionNoun} blocked." `
          -AgentMessage "The scanning service returned an error (HTTP $($scanResult.HttpStatus)). Do not retry ${actionDesc}."
      }
      return
    }
    "invalid_json" {
      Write-CheckWriteAuditLog -ToolName $toolName -FilePath $filePath -Command $shellCommand -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
        -Reason "api_invalid_json" -Detail "scanner returned invalid JSON"
      if ($FailureMode -eq "open") {
        Write-JsonPermissionAllow -Message "The scanning service returned an invalid response. ${actionNoun} allowed WITHOUT a security scan."
      } else {
        Write-JsonPermissionDeny -UserMessage "The scanning service returned an invalid response. ${actionNoun} blocked." `
          -AgentMessage "The scanning service returned an invalid response. Do not retry ${actionDesc}."
      }
      return
    }
  }

  Write-CheckWriteAuditLog -ToolName $toolName -FilePath $filePath -Command $shellCommand -Decision $scanResult.Action -ThreatLevel $scanResult.ThreatLevel

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
        if ($FailureMode -eq "open") {
          Write-JsonPermissionAllow -Message "${anomalyPrefix}$($scanResult.Message)"
        } else {
          Write-JsonPermissionDeny -UserMessage "${anomalyPrefix}$($scanResult.Message)" `
            -AgentMessage "$($scanResult.Message) Do not retry ${actionDesc}."
        }
      } else {
        if ($FailureMode -eq "open") {
          Write-JsonPermissionAllow -Message "${anomalyPrefix}The scanning service returned an unexpected response. ${actionNoun} allowed WITHOUT a security scan."
        } else {
          Write-JsonPermissionDeny -UserMessage "${anomalyPrefix}The scanning service returned an unexpected response. ${actionNoun} blocked." `
            -AgentMessage "The scanning service returned an unexpected response. Do not retry ${actionDesc}."
        }
      }
    }
    "block" {
      Set-PnLastSuccessfulScan
      $userMessage = $scanResult.Message
      if (-not $userMessage) { $userMessage = "A policy violation was detected." }
      Write-JsonPermissionDeny -UserMessage $userMessage -AgentMessage "$userMessage $(Build-StopInstruction $actionDesc)"
    }
    "warn" {
      # Non-blocking: surface the scan's own explanation and let it proceed.
      Set-PnLastSuccessfulScan
      if ($scanResult.Message) {
        Write-JsonPermissionAllow -Message $scanResult.Message
      } else {
        Write-JsonPermissionAllow
      }
    }
    default {
      # "allow"
      Set-PnLastSuccessfulScan
      if ($scanResult.Message) {
        Write-JsonPermissionAllow -Message $scanResult.Message
      } else {
        Write-JsonPermissionAllow
      }
    }
  }
} catch {
  # Anything unexpected -- match the FailureMode posture for an
  # unreachable scanner rather than crash without a response.
  Write-DebugLog -Message "UNEXPECTED ERROR | $($_.Exception.GetType().FullName): $($_.Exception.Message)" -LogPath $DebugLogPath
  if ($FailureMode -eq "open") {
    Write-JsonPermissionAllow -Message "The scanning service is unavailable. Allowed WITHOUT a security scan."
  } else {
    Write-JsonPermissionDeny -UserMessage "The scanning service is unavailable. Blocked." `
      -AgentMessage "The scanning service is unavailable. Do not retry this action."
  }
}
