# preToolUse hook (Windows): scan agent response before Write tool calls.
# (Cursor has no separate "Edit" tool_name; all file modifications use
# "Write".) Returns {permission: "allow"/"deny", user_message: "...",
# agent_message: "..."}. Mirrors scripts/check-write.sh.

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
$TranscriptBytes = 4000
if ($env:SNANTIZER_TRANSCRIPT_BYTES) {
  $parsedBytes = 0
  if ([int]::TryParse($env:SNANTIZER_TRANSCRIPT_BYTES, [ref]$parsedBytes)) {
    $TranscriptBytes = $parsedBytes
  }
}

$rawMode = $env:PARADIGM_NETWORKS_FAILURE_MODE
if (-not $rawMode) { $rawMode = $env:SNANTIZER_FAILURE_MODE }
if (-not $rawMode) { $rawMode = "block" }
$rawMode = $rawMode.ToLowerInvariant()
$FailureMode = if ($rawMode -eq "allow" -or $rawMode -eq "open") { "open" } else { "closed" }

$AuditLogPath = Join-Path $HOME ".paradigm-scanner\audit.jsonl"
$DebugLogPath = Join-Path $HOME ".paradigm-scanner\check-write.log"
$StopInstruction = "A security scan blocked this write due to a detected policy violation. Do not retry this write or attempt a workaround (e.g. base64-encoding it, splitting the string, writing it to a different file, or renaming the variable). Stop this task and report the violation to the user."

function Write-CheckWriteAuditLog {
  param(
    [string]$FilePath,
    [string]$Decision,
    [string]$Reason = "",
    [string]$Detail = "",
    [string]$ScanUrl = "",
    [string]$ScanId = ""
  )
  $entry = [PSCustomObject]@{ file_path = $FilePath; decision = $Decision }
  # -PassThru not used, and piped through Out-Null regardless: Add-Member's
  # pipeline-input behavior around emitting the modified object isn't
  # worth relying on either way here -- this must never leak into stdout.
  if ($Reason) { $entry | Add-Member -NotePropertyName "reason" -NotePropertyValue $Reason | Out-Null }
  if ($Detail) { $entry | Add-Member -NotePropertyName "detail" -NotePropertyValue $Detail | Out-Null }
  if ($ScanUrl) { $entry | Add-Member -NotePropertyName "scan_url" -NotePropertyValue $ScanUrl | Out-Null }
  if ($PSBoundParameters.ContainsKey('ScanId')) { $entry | Add-Member -NotePropertyName "scan_id" -NotePropertyValue $ScanId | Out-Null }
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
    # Deliberately always allow here, unlike the FailureMode-driven
    # branches below: a malformed payload usually signals a Cursor
    # integration/encoding quirk, not an unreachable scanner. Routing it
    # through FailureMode would mean an affected machine gets every
    # single write blocked persistently.
    Write-JsonPermissionAllow -Message "Received invalid input."
    return
  }

  $toolName = Get-JsonProperty -InputObject $parsedPayload -Name "tool_name" -Default ""
  if ($toolName -ne "Write") {
    Write-JsonPermissionAllow
    return
  }

  $agentMessage = ([string](Get-JsonProperty -InputObject $parsedPayload -Name "agent_message" -Default "")).Trim()
  $transcriptPath = Get-JsonProperty -InputObject $parsedPayload -Name "transcript_path" -Default ""
  $toolInput = Get-JsonProperty -InputObject $parsedPayload -Name "tool_input" -Default $null
  $filePath = Get-JsonProperty -InputObject $toolInput -Name "file_path" -Default ""

  $transcriptContent = ""
  if ($transcriptPath -and (Test-Path $transcriptPath -PathType Leaf)) {
    $transcriptContent = Get-FileTail -Path $transcriptPath -MaxBytes $TranscriptBytes
  }

  $scanText = $agentMessage
  if (-not $scanText) {
    $scanText = $transcriptContent
  }

  if (-not $scanText) {
    Write-JsonPermissionAllow
    return
  }

  Write-DebugLog -Message "Resolving config (may refresh an expiring token)..." -LogPath $DebugLogPath
  $config = Resolve-PnConfig
  Write-DebugLog -Message "Config resolved | configured=$($null -ne $config)" -LogPath $DebugLogPath
  if ($null -eq $config) {
    $reason = "Paradigm Networks not configured -- run the paradigmnetworks-login skill"
    Write-CheckWriteAuditLog -FilePath $filePath -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
      -Reason "not_configured" -Detail $reason

    $signupNote = "Don't have one yet? Sign up at https://signup.claude-demo.paradigmnetworks.ai/signup."
    if ($FailureMode -eq "open") {
      Write-JsonPermissionAllow -Message "The scanning service is unavailable ($reason). Write allowed WITHOUT a security scan. $signupNote"
    } else {
      Write-JsonPermissionDeny -UserMessage "The scanning service is unavailable ($reason). Write blocked. $signupNote" `
        -AgentMessage "The scanning service is unavailable ($reason). Do not retry this write."
    }
    return
  }

  $scanUrl = $ScanUrlOverride
  if (-not $scanUrl) {
    $scanUrl = "$($config.BaseUrl.TrimEnd('/'))/api/v1/codedefense/scan"
  }

  $callStart = Get-Date
  Write-DebugLog -Message "POST starting -> $scanUrl | timeout=${TimeoutSeconds}s" -LogPath $DebugLogPath
  $result = Invoke-ScanHttpPost -Url $scanUrl -TextData $scanText -AuthToken $config.AccessToken -TimeoutSec $TimeoutSeconds
  $elapsedMs = [int]((Get-Date) - $callStart).TotalMilliseconds
  Write-DebugLog -Message "POST returned after ${elapsedMs}ms | TimedOut=$($result.TimedOut) | ConnectionFailed=$($result.ConnectionFailed) | StatusCode=$($result.StatusCode)" -LogPath $DebugLogPath

  if ($result.TimedOut) {
    Write-CheckWriteAuditLog -FilePath $filePath -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
      -Reason "api_timeout" -Detail "${TimeoutSeconds}s timeout" -ScanUrl $scanUrl
    if ($FailureMode -eq "open") {
      Write-JsonPermissionAllow -Message "The scanning service is unavailable (timed out after ${TimeoutSeconds}s). Write allowed WITHOUT a security scan."
    } else {
      Write-JsonPermissionDeny -UserMessage "The scanning service is unavailable (timed out after ${TimeoutSeconds}s). Write blocked." `
        -AgentMessage "The scanning service is unavailable (timed out after ${TimeoutSeconds}s). Do not retry this write."
    }
    return
  }
  if ($result.ConnectionFailed) {
    Write-CheckWriteAuditLog -FilePath $filePath -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
      -Reason "api_unreachable" -Detail "connection failed" -ScanUrl $scanUrl
    if ($FailureMode -eq "open") {
      Write-JsonPermissionAllow -Message "The scanning service is unavailable (connection failed). Write allowed WITHOUT a security scan."
    } else {
      Write-JsonPermissionDeny -UserMessage "The scanning service is unavailable (connection failed). Write blocked." `
        -AgentMessage "The scanning service is unavailable (connection failed). Do not retry this write."
    }
    return
  }

  if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
    Write-CheckWriteAuditLog -FilePath $filePath -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
      -Reason "api_http_error" -Detail "HTTP $($result.StatusCode)" -ScanUrl $scanUrl
    if ($FailureMode -eq "open") {
      Write-JsonPermissionAllow -Message "The scanning service returned an error (HTTP $($result.StatusCode)). Write allowed WITHOUT a security scan."
    } else {
      Write-JsonPermissionDeny -UserMessage "The scanning service returned an error (HTTP $($result.StatusCode)). Write blocked." `
        -AgentMessage "The scanning service returned an error (HTTP $($result.StatusCode)). Do not retry this write."
    }
    return
  }

  $responseObject = $null
  try {
    $responseObject = $result.Body | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-CheckWriteAuditLog -FilePath $filePath -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
      -Reason "api_invalid_json" -Detail "scanner returned invalid JSON" -ScanUrl $scanUrl
    if ($FailureMode -eq "open") {
      Write-JsonPermissionAllow -Message "The scanning service returned an invalid response. Write allowed WITHOUT a security scan."
    } else {
      Write-JsonPermissionDeny -UserMessage "The scanning service returned an invalid response. Write blocked." `
        -AgentMessage "The scanning service returned an invalid response. Do not retry this write."
    }
    return
  }

  $action = Get-JsonProperty -InputObject $responseObject -Name "action_to_take" -Default "allow"
  $message = Get-JsonProperty -InputObject $responseObject -Name "message" -Default "Agent response blocked by Paradigm Networks."
  $scanId = Get-JsonProperty -InputObject $responseObject -Name "scan_id" -Default ""

  Write-CheckWriteAuditLog -FilePath $filePath -Decision $action -ScanId $scanId

  switch ($action) {
    "block" {
      Write-JsonPermissionDeny -UserMessage $message -AgentMessage "$message $StopInstruction"
    }
    "warn" {
      Write-JsonPermissionAllow -Message $message
    }
    default {
      Write-JsonPermissionAllow
    }
  }
} catch {
  # Anything unexpected -- match the FailureMode posture for an
  # unreachable scanner rather than crash without a response.
  Write-DebugLog -Message "UNEXPECTED ERROR | $($_.Exception.GetType().FullName): $($_.Exception.Message)" -LogPath $DebugLogPath
  if ($FailureMode -eq "open") {
    Write-JsonPermissionAllow -Message "The scanning service is unavailable. Write allowed WITHOUT a security scan."
  } else {
    Write-JsonPermissionDeny -UserMessage "The scanning service is unavailable. Write blocked." `
      -AgentMessage "The scanning service is unavailable. Do not retry this write."
  }
}
