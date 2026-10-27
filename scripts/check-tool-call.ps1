# preToolUse hook (Windows): scan ANY tool call's input before it runs.
# Mirrors scripts/check-tool-call.sh -- see that file's header for the full
# rationale (generic preToolUse coverage, git push/commit detection folded
# in from the retired beforeShellExecution hook, MCP git commit handling,
# and the tool_use_id correlation with check-tool-call-record.ps1).
# Returns {permission: "allow"/"deny", user_message: "...", agent_message: "..."}.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "lib\git-utils.ps1")
. (Join-Path $ScriptDir "lib\plugins-client.ps1")
. (Join-Path $ScriptDir "lib\login-detection.ps1")
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

# PARADIGM_NETWORKS_FAILURE_MODE (block/allow), same default as the bash side.
$rawMode = $env:PARADIGM_NETWORKS_FAILURE_MODE
if (-not $rawMode) { $rawMode = "block" }
$rawMode = $rawMode.ToLowerInvariant()
$FailureMode = if ($rawMode -eq "allow" -or $rawMode -eq "open") { "open" } else { "closed" }

$AuditLogPath = Join-Path $HOME ".paradigm-networks\audit.jsonl"
$DebugLogPath = Join-Path $HOME ".paradigm-networks\check-tool-call.log"

# See build_stop_instruction in check-tool-call.sh for why the wording is
# this specific ("relay ... in full, exactly as given").
function Build-StopInstruction {
  param([string]$ActionDesc)
  return "A security scan blocked $ActionDesc due to a detected policy violation. Do not retry $ActionDesc or attempt a workaround (e.g. re-encoding it, splitting it up, or otherwise disguising it to bypass detection). Stop this task and relay the findings above to the user in full, exactly as given -- every issue, category, code, and standard name mentioned. Do not summarize or paraphrase them into a general statement; the user needs the precise details to know what to fix."
}

function Write-ToolCallAuditLog {
  param(
    [string]$ToolName = "",
    [string]$FilePath = "",
    [string]$Command = "",
    [string]$Decision,
    [string]$Reason = "",
    [string]$Detail = "",
    [string]$ThreatLevel = $null
  )
  $entry = [ordered]@{ tool_name = $ToolName; file_path = $FilePath; command = $Command; decision = $Decision }
  if ($Reason) { $entry["reason"] = $Reason }
  if ($Detail) { $entry["detail"] = $Detail }
  if ($PSBoundParameters.ContainsKey('ThreatLevel')) { $entry["threat_level"] = $ThreatLevel }
  Write-AuditLog -Entry ([PSCustomObject]$entry) -LogPath $AuditLogPath | Out-Null
}

function Get-FailureDecision {
  if ($FailureMode -eq "closed") { return "deny" } else { return "allow" }
}

try {
  $payload = Get-StdinText

  # Deliberately always allow on a malformed payload -- see the bash side.
  $parsedPayload = $null
  try {
    $parsedPayload = $payload | ConvertFrom-Json -ErrorAction Stop
  } catch {
    $parsedPayload = $null
  }
  if ($null -eq $parsedPayload) {
    Write-JsonPermissionAllow -Message "Received invalid input."
    return
  }

  $toolName = [string](Get-JsonProperty -InputObject $parsedPayload -Name "tool_name" -Default "")
  if (-not $toolName) {
    Write-JsonPermissionAllow
    return
  }

  $toolInput = Get-JsonProperty -InputObject $parsedPayload -Name "tool_input" -Default $null
  $command = ""
  $filePath = ""
  if ($toolInput -is [System.Management.Automation.PSCustomObject]) {
    $command = [string](Get-JsonProperty -InputObject $toolInput -Name "command" -Default "")
    $filePath = [string](Get-JsonProperty -InputObject $toolInput -Name "file_path" -Default "")
  }

  # PN-12153: the login/logout/check-configured skills' own invocations are
  # exempt from the scan entirely, checked before config resolution -- see
  # check-tool-call.sh and lib/login-detection.ps1.
  $exemptReason = Get-PnLoginLogoutExemptReason -ToolName $toolName -Command $command -ScriptDir $ScriptDir
  if ($exemptReason) {
    Write-AuditLog -Entry ([PSCustomObject][ordered]@{ tool_name = $toolName; command = $command; decision = "allow"; reason = $exemptReason }) -LogPath $AuditLogPath | Out-Null
    Write-JsonPermissionAllow
    return
  }

  # Tool-appropriate wording for the messages below.
  $actionNoun = "Tool call"
  $actionDesc = "this tool call"
  switch ($toolName) {
    "Write" { $actionNoun = "Write"; $actionDesc = "this write" }
    "Shell" { $actionNoun = "Command"; $actionDesc = "this command" }
  }

  # git push/commit detection -- same unanchored, whitespace-bounded match
  # as the bash side.
  $gitEventType = ""
  if ($toolName -eq "Shell") {
    if ($command -match '(^|\s)git\s+push(\s|$)') {
      $gitEventType = "git.push"; $actionNoun = "Push"; $actionDesc = "this push"
    } elseif ($command -match '(^|\s)git\s+commit(\s|$)') {
      $gitEventType = "git.commit"; $actionNoun = "Commit"; $actionDesc = "this commit"
    }
  } elseif ($toolName -eq "MCP:git_commit") {
    $gitEventType = "git.commit"; $actionNoun = "Commit"; $actionDesc = "this commit"
  }

  $cursorToolUseId = [string](Get-JsonProperty -InputObject $parsedPayload -Name "tool_use_id" -Default "")
  $agentMessage = ([string](Get-JsonProperty -InputObject $parsedPayload -Name "agent_message" -Default "")).Trim()
  $transcriptPath = [string](Get-JsonProperty -InputObject $parsedPayload -Name "transcript_path" -Default "")

  # The tool's actual input, verbatim -- what gets STORED as the tool_use
  # block, so never a Write/Shell-specific extraction.
  $toolInputValue = if ($null -eq $toolInput) { [PSCustomObject]@{} } else { $toolInput }
  $toolInputJson = $toolInputValue | ConvertTo-Json -Compress -Depth 64

  $clientSessionId = [string](Get-JsonProperty -InputObject $parsedPayload -Name "conversation_id" -Default "")
  if (-not $clientSessionId) {
    $clientSessionId = [string](Get-JsonProperty -InputObject $parsedPayload -Name "session_id" -Default "")
  }
  $cwd = Get-PnPayloadCwd -Payload $parsedPayload
  $generationId = [string](Get-JsonProperty -InputObject $parsedPayload -Name "generation_id" -Default "")
  $modelId = [string](Get-JsonProperty -InputObject $parsedPayload -Name "model_id" -Default "")
  $modelLegacy = [string](Get-JsonProperty -InputObject $parsedPayload -Name "model" -Default "")
  $model = Resolve-HookModel -ModelId $modelId -LegacyModel $modelLegacy

  $gitRepoUrl = ""
  $gitBranch = ""
  $files = @()
  if ($cwd -and (Test-PnGitRepo -Path $cwd)) {
    $gitRepoUrl = Get-GitRemoteUrlOrEmpty -RepoPath $cwd
    $gitBranch = Get-GitCurrentBranchOrEmpty -RepoPath $cwd
    if ($gitEventType) {
      if ($toolName -eq "MCP:git_commit") {
        $mcpFiles = @()
        if ($toolInput -is [System.Management.Automation.PSCustomObject]) {
          $mcpFiles = @(Get-JsonProperty -InputObject $toolInput -Name "files" -Default @() | ForEach-Object { [string]$_ })
        }
        $files = @(Get-PnFilesFromPaths -Cwd $cwd -RelativePaths $mcpFiles)
      } else {
        $files = @(Get-PnGitDiffFiles -Cwd $cwd -GitEventType $gitEventType)
      }
    }
  }

  $turnText = ""
  if ($transcriptPath) {
    $turnText = Get-CurrentTurnText -TranscriptPath $transcriptPath -MaxLines $TranscriptLines
  }
  if (-not $turnText) { $turnText = $agentMessage }

  Write-DebugLog -Message "tool_input | tool_name=$toolName | file_path=$filePath | tool_input_len=$($toolInputJson.Length) | turn_text_len=$($turnText.Length) | tool_use_id=$cursorToolUseId" -LogPath $DebugLogPath

  # Nothing to scan: no input and no turn context.
  if (($toolInputJson -eq "{}" -or -not $toolInputJson) -and -not $turnText) {
    Write-JsonPermissionAllow
    return
  }

  $config = Resolve-PnConfig
  if ($null -eq $config) {
    # Let the login skill follow its own background login run while
    # unconfigured -- see Test-PnLoginWaitCall. Not-configured path only.
    if (Test-PnLoginWaitCall -ToolName $toolName -Command $command -FilePath $filePath) {
      Write-ToolCallAuditLog -ToolName $toolName -FilePath $filePath -Command $toolInputJson -Decision "allow" -Reason "login_wait_unconfigured"
      Write-JsonPermissionAllow
      return
    }

    $reason = "Paradigm Networks not configured -- run the paradigmnetworks-login skill"
    Write-ToolCallAuditLog -ToolName $toolName -FilePath $filePath -Command $toolInputJson -Decision (Get-FailureDecision) -Reason "not_configured" -Detail $reason

    $signupNote = "Don't have one yet? Sign up at https://signup.claude-demo.paradigmnetworks.ai/signup."
    if ($FailureMode -eq "open") {
      Write-JsonPermissionAllow -Message "The scanning service is unavailable ($reason). $actionNoun allowed WITHOUT a security scan. $signupNote"
    } else {
      # Carry the literal login command in agent_message -- see the bash
      # side. Same shape as check-session.ps1's notice and the login skill.
      $loginScript = Join-Path $ScriptDir "login.ps1"
      $loginCommand = '& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "' + $loginScript + '" -BaseUrl <their-base-url>'
      $recovery = "Paradigm Networks is not logged in, so $actionDesc was blocked. Ask the user for their Paradigm Networks base URL, then run EXACTLY: $loginCommand -- verbatim, with nothing chained onto it, and outside the sandbox (required_permissions [`"all`"]): it must reach the Paradigm Networks server and save the login in the home folder. Do not retry $actionDesc, and do not search for the script: every other tool call stays blocked until login completes."
      Write-JsonPermissionDeny -UserMessage "The scanning service is unavailable ($reason). $actionNoun blocked. $signupNote" -AgentMessage $recovery
    }
    return
  }

  Write-DebugLog -Message "Scanning tool call | base_url=$($config.BaseUrl) | tool_input_len=$($toolInputJson.Length) | turn_text_len=$($turnText.Length)" -LogPath $DebugLogPath

  $scan = Invoke-PnPluginBeforeToolCall -BaseUrl $config.BaseUrl -AccessToken $config.AccessToken -TimeoutSec $TimeoutSeconds `
    -SessionId $clientSessionId -Cwd $cwd -GitRepoUrl $gitRepoUrl -GitBranch $gitBranch -ToolName $toolName -InputValue $toolInputValue `
    -GenerationId $generationId -Model $model -ToolUseId $cursorToolUseId -ScanContext $turnText -Files $files

  # Closes out the tool_use block before_tool_call opened when the call is
  # denied here: postToolUse never fires for a denied tool call.
  function Close-DeniedToolCall {
    param([string]$Outcome)
    Invoke-PnPluginAfterToolCall -BaseUrl $config.BaseUrl -AccessToken $config.AccessToken -TimeoutSec $TimeoutSeconds `
      -SessionId $clientSessionId -Cwd $cwd -GitRepoUrl $gitRepoUrl -GitBranch $gitBranch -ToolUseId $scan.ToolUseId `
      -Output $Outcome -IsError $true -GenerationId $generationId -ToolName $toolName -InputValue $toolInputValue
  }

  $failure = $null
  switch ($scan.Status) {
    "no_session"   { $failure = @{ Reason = "no_session_id";   Detail = "no session id available";       Text = "The scanning service could not be reached (no session id available)." } }
    "timeout"      { $failure = @{ Reason = "api_timeout";     Detail = "${TimeoutSeconds}s timeout";     Text = "The scanning service is unavailable (timed out after ${TimeoutSeconds}s)." } }
    "unreachable"  { $failure = @{ Reason = "api_unreachable"; Detail = "connection failed";              Text = "The scanning service is unavailable (connection failed)." } }
    "http_error"   { $failure = @{ Reason = "api_http_error";  Detail = "HTTP $($scan.HttpStatus)";       Text = "The scanning service returned an error (HTTP $($scan.HttpStatus))." } }
    "invalid_json" { $failure = @{ Reason = "api_invalid_json"; Detail = "scanner returned invalid JSON"; Text = "The scanning service returned an invalid response." } }
  }
  if ($null -ne $failure) {
    Write-ToolCallAuditLog -ToolName $toolName -FilePath $filePath -Command $toolInputJson -Decision (Get-FailureDecision) -Reason $failure.Reason -Detail $failure.Detail
    if ($FailureMode -eq "open") {
      Write-JsonPermissionAllow -Message "$($failure.Text) $actionNoun allowed WITHOUT a security scan."
    } else {
      Write-JsonPermissionDeny -UserMessage "$($failure.Text) $actionNoun blocked." -AgentMessage "$($failure.Text) Do not retry $actionDesc."
    }
    return
  }

  Write-ToolCallAuditLog -ToolName $toolName -FilePath $filePath -Command $toolInputJson -Decision $scan.Action -ThreatLevel $scan.ThreatLevel

  switch ($scan.Action) {
    { [string]::IsNullOrEmpty($_) } {
      # A valid JSON response with no recognized action_to_take.
      Write-DebugLog -Message "Scan response shape unexpected (no recognized action_to_take)" -LogPath $DebugLogPath
      $anomalyStreak = Add-PnScanAnomaly
      $anomalyPrefix = ""
      if ($anomalyStreak -ge $Script:PnAnomalyWarningThreshold) {
        $warningSign = "$([char]0x26A0)$([char]0xFE0F)"
        $anomalyPrefix = "$warningSign Security scanning has failed $anomalyStreak times in a row and may not be protecting you right now. Contact your administrator. "
      }
      if ($scan.Message) {
        if ($FailureMode -eq "open") {
          Write-JsonPermissionAllow -Message "${anomalyPrefix}$($scan.Message)"
        } else {
          Close-DeniedToolCall -Outcome "[BLOCKED] ${anomalyPrefix}$($scan.Message)"
          Write-JsonPermissionDeny -UserMessage "${anomalyPrefix}$($scan.Message)" -AgentMessage "$($scan.Message) Do not retry $actionDesc."
        }
      } else {
        if ($FailureMode -eq "open") {
          Write-JsonPermissionAllow -Message "${anomalyPrefix}The scanning service returned an unexpected response. $actionNoun allowed WITHOUT a security scan."
        } else {
          Close-DeniedToolCall -Outcome "[BLOCKED] ${anomalyPrefix}The scanning service returned an unexpected response. $actionNoun blocked."
          Write-JsonPermissionDeny -UserMessage "${anomalyPrefix}The scanning service returned an unexpected response. $actionNoun blocked." -AgentMessage "The scanning service returned an unexpected response. Do not retry $actionDesc."
        }
      }
    }
    "block" {
      Set-PnLastSuccessfulScan
      $userMessage = $scan.Message
      if (-not $userMessage) { $userMessage = "A policy violation was detected." }
      Close-DeniedToolCall -Outcome "[BLOCKED] $userMessage"
      Write-JsonPermissionDeny -UserMessage $userMessage -AgentMessage "$userMessage $(Build-StopInstruction -ActionDesc $actionDesc)"
    }
    default {
      # "warn" and "allow": surface the scan's own explanation, if any.
      Set-PnLastSuccessfulScan
      if ($scan.Message) {
        Write-JsonPermissionAllow -Message $scan.Message
      } else {
        Write-JsonPermissionAllow
      }
    }
  }
} catch {
  # Anything unexpected -- same FailureMode posture as an unreachable scanner.
  Write-DebugLog -Message "UNEXPECTED ERROR | $($_.Exception.GetType().FullName): $($_.Exception.Message)" -LogPath $DebugLogPath
  if ($FailureMode -eq "open") {
    Write-JsonPermissionAllow -Message "The scanning service is unavailable (unexpected error). Tool call allowed WITHOUT a security scan."
  } else {
    Write-JsonPermissionDeny -UserMessage "The scanning service is unavailable (unexpected error). Tool call blocked." -AgentMessage "The scanning service is unavailable (unexpected error). Do not retry this tool call."
  }
}
