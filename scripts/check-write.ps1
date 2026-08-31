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
$TranscriptLines = 500
if ($env:SNANTIZER_TRANSCRIPT_LINES) {
  $parsedLines = 0
  if ([int]::TryParse($env:SNANTIZER_TRANSCRIPT_LINES, [ref]$parsedLines)) {
    $TranscriptLines = $parsedLines
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

# codedefense/scan is retired; this now calls the Anthropic-compatible
# /v1/messages endpoint on the same backend, which requires a model.
# $DefaultModel is the last-resort fallback: cheap/fast tier, chosen
# because testing showed the block/allow verdict is identical across
# models and max_tokens values -- the platform's guard fires before the
# requested model ever runs, so model choice only affects cost/latency on
# the (always-discarded) allow-path reply, not detection accuracy.
$DefaultModel = "anthropic/claude-haiku-4-5-20251001"
# Precedence: PARADIGM_NETWORKS_MODEL env var (a manual override -- only
# takes effect if something exports it directly into the process
# environment, e.g. a shared-host setup; there is no Cursor Settings UI
# for this -- an earlier version had one, but it was removed after
# confirming, against a real installed plugin, that Cursor's plugin
# Settings panel never delivers configured values to hook scripts) > the
# model saved locally via the paradigmnetworks-models skill /
# set-model.ps1 (Get-PnPreferredModel, in pn_config.ps1) > hardcoded
# default.
$Model = $env:PARADIGM_NETWORKS_MODEL
if (-not $Model) { $Model = Get-PnPreferredModel }
if (-not $Model) { $Model = $DefaultModel }
# 150 comfortably covers the block banner + reason sentence; confirmed via
# live testing that the banner is injected by the guard without ever being
# subject to max_tokens (output_tokens is 0 even for the full banner), so
# this only trades off cost/latency on the allow path, not truncation risk.
$MaxTokens = 150

function Write-CheckWriteAuditLog {
  param(
    [string]$FilePath,
    [string]$Decision,
    [string]$Reason = "",
    [string]$Detail = "",
    [string]$ScanUrl = "",
    [string]$MessageId = ""
  )
  $entry = [PSCustomObject]@{ file_path = $FilePath; decision = $Decision }
  # -PassThru not used, and piped through Out-Null regardless: Add-Member's
  # pipeline-input behavior around emitting the modified object isn't
  # worth relying on either way here -- this must never leak into stdout.
  if ($Reason) { $entry | Add-Member -NotePropertyName "reason" -NotePropertyValue $Reason | Out-Null }
  if ($Detail) { $entry | Add-Member -NotePropertyName "detail" -NotePropertyValue $Detail | Out-Null }
  if ($ScanUrl) { $entry | Add-Member -NotePropertyName "scan_url" -NotePropertyValue $ScanUrl | Out-Null }
  # "message_id" (the /v1/messages response's own "id" field) replaces the
  # old scan_id -- different endpoint, same purpose: a value to correlate
  # this decision against backend logs.
  if ($PSBoundParameters.ContainsKey('MessageId')) { $entry | Add-Member -NotePropertyName "message_id" -NotePropertyValue $MessageId | Out-Null }
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
  $fileContent = [string](Get-JsonProperty -InputObject $toolInput -Name "content" -Default "")

  $turnText = ""
  if ($transcriptPath) {
    $turnText = Get-CurrentTurnText -TranscriptPath $transcriptPath -MaxLines $TranscriptLines
  }

  Write-DebugLog -Message "tool_input | file_path=$filePath | content_len=$($fileContent.Length) | turn_text_len=$($turnText.Length) | agent_message_len=$($agentMessage.Length)" -LogPath $DebugLogPath

  # Scan the current turn's conversation together with the file content --
  # neither alone is enough. File-content-only can miss malicious *intent*
  # that doesn't show up in code that looks ordinary on its own (e.g. the
  # user's actual ask was the problem, not the resulting file). A raw
  # transcript tail on its own can drag in stale context from an earlier,
  # unrelated turn (confirmed directly: a trivial follow-up write was
  # blocked purely because recent transcript text mentioned a security
  # topic from a previous, unrelated prompt). Get-CurrentTurnText above
  # scopes to the most recent user message onward, so it can't repeat that
  # -- combining it with the actual file content covers both what was
  # asked for and what's actually about to be written.
  $scanText = ""
  $scanSource = ""
  if ($turnText -and $fileContent) {
    $scanText = "$turnText`n`n---`n`n$fileContent"
    $scanSource = "turn+content"
  } elseif ($fileContent) {
    $scanText = $fileContent
    $scanSource = "content"
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
    $scanUrl = "$($config.BaseUrl.TrimEnd('/'))/v1/messages"
  }

  $callStart = Get-Date
  Write-DebugLog -Message "POST starting -> $scanUrl | model=$Model | timeout=${TimeoutSeconds}s" -LogPath $DebugLogPath
  $result = Invoke-MessagesHttpPost -Url $scanUrl -TextData $scanText -Model $Model -MaxTokens $MaxTokens -AuthToken $config.AccessToken -TimeoutSec $TimeoutSeconds
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

  # ConvertFrom-PnMessagesResponse (lib/common.ps1) classifies this
  # response -- see that function's (and its bash sibling
  # pn_parse_messages_response's) comment for the full detection-rule
  # rationale.
  $parsedVerdict = ConvertFrom-PnMessagesResponse -ResponseBody $result.Body
  $action = $parsedVerdict.Action
  $messageId = Get-JsonProperty -InputObject $responseObject -Name "id" -Default ""

  Write-CheckWriteAuditLog -FilePath $filePath -Decision $action -MessageId $messageId

  switch ($action) {
    "anomaly" {
      # Zero usage without the block banner -- an unrecognized response
      # shape, not a confirmed verdict either way. Same posture as an
      # invalid-JSON or non-2xx response above: don't guess allow or block.
      Write-DebugLog -Message "API response shape unexpected (zero usage, no block banner) | url=$scanUrl" -LogPath $DebugLogPath
      $anomalyStreak = Add-PnScanAnomaly
      $anomalyPrefix = ""
      if ($anomalyStreak -ge $Script:PnAnomalyWarningThreshold) {
        $anomalyPrefix = "⚠️ Security scanning has failed $anomalyStreak times in a row and may not be protecting you right now. Contact your administrator. "
      }
      if ($FailureMode -eq "open") {
        Write-JsonPermissionAllow -Message "${anomalyPrefix}The scanning service returned an unexpected response. Write allowed WITHOUT a security scan."
      } else {
        Write-JsonPermissionDeny -UserMessage "${anomalyPrefix}The scanning service returned an unexpected response. Write blocked." `
          -AgentMessage "The scanning service returned an unexpected response. Do not retry this write."
      }
    }
    "block" {
      Reset-PnScanAnomaly
      # $parsedVerdict.Message is only the short extracted reason (e.g.
      # "destructive operation"), not a full sentence -- wrap it into the
      # same phrasing the platform's own block banner uses, rather than
      # showing the bare phrase or (worse) the raw ASCII-art banner text
      # verbatim to the user.
      $userMessage = "The submitted content was flagged because it triggered the following security concerns: $($parsedVerdict.Message)."
      Write-JsonPermissionDeny -UserMessage $userMessage -AgentMessage "$userMessage $StopInstruction"
    }
    default {
      # "allow" is the only other action ConvertFrom-PnMessagesResponse
      # produces -- there is no "warn" state on this endpoint (see that
      # function's comment); the model's actual reply is discarded either
      # way, only the verdict matters.
      Reset-PnScanAnomaly
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
