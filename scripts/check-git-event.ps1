# beforeShellExecution hook (Windows): evaluate a detected git command
# (push, commit, or PR creation) against the generic detections API before
# letting it run. Mirrors scripts/check-git-event.sh. One script,
# parameterized by EventType, rather than one clone per git operation --
# see that file's header comment for the full rationale.
# Returns {permission: "allow"/"deny", user_message: "...", agent_message: "..."}

param(
  [string]$EventType = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "lib\git-utils.ps1")
. (Join-Path $ScriptDir "lib\detection-client.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$DetectionsUrlOverride = $env:PARADIGM_NETWORKS_DETECTIONS_URL_OVERRIDE
$TimeoutSeconds = 240
if ($env:PARADIGM_NETWORKS_GIT_EVENT_TIMEOUT) {
  $parsedTimeout = 0
  if ([int]::TryParse($env:PARADIGM_NETWORKS_GIT_EVENT_TIMEOUT, [ref]$parsedTimeout)) {
    $TimeoutSeconds = $parsedTimeout
  }
}
# Guardrails from design-ideas/Cursor_PrePush_Governance_Enforcement_Plan.md
# section 10.4 -- see check-git-event.sh's identical comment for the
# rationale (an explicit cap, not a measured optimum).
$MaxFiles = 60
if ($env:PARADIGM_NETWORKS_GIT_EVENT_MAX_FILES) {
  $parsedMaxFiles = 0
  if ([int]::TryParse($env:PARADIGM_NETWORKS_GIT_EVENT_MAX_FILES, [ref]$parsedMaxFiles)) {
    $MaxFiles = $parsedMaxFiles
  }
}
$MaxTotalBytes = 8388608
if ($env:PARADIGM_NETWORKS_GIT_EVENT_MAX_BYTES) {
  $parsedMaxBytes = 0
  if ([int]::TryParse($env:PARADIGM_NETWORKS_GIT_EVENT_MAX_BYTES, [ref]$parsedMaxBytes)) {
    $MaxTotalBytes = $parsedMaxBytes
  }
}

$rawMode = $env:PARADIGM_NETWORKS_FAILURE_MODE
if (-not $rawMode) { $rawMode = "block" }
$rawMode = $rawMode.ToLowerInvariant()
$FailureMode = if ($rawMode -eq "allow" -or $rawMode -eq "open") { "open" } else { "closed" }
# Defaults closed, matching check-write.ps1, not check-prompt.ps1's open
# default -- see check-git-event.sh's identical comment (design doc section 4).

$AuditLogPath = Join-Path $HOME ".paradigm-scanner\audit.jsonl"
$DebugLogPath = Join-Path $HOME ".paradigm-scanner\check-git-event.log"

function Build-StopInstruction {
  param([string]$ActionDesc)
  return "A security scan blocked $ActionDesc due to a detected policy violation. Do not retry $ActionDesc or attempt a workaround (e.g. re-encoding it, splitting it up, or otherwise disguising it to bypass detection). Stop this task and relay the findings above to the user in full, exactly as given -- every issue, category, and finding mentioned. Do not summarize or paraphrase them into a general statement; the user needs the precise details to know what to fix."
}

function Write-CheckGitEventAuditLog {
  param(
    [string]$EventType,
    [string]$Command = "",
    [string]$Decision,
    [string]$Reason = "",
    [string]$Detail = "",
    [string]$Url = "",
    [string]$AuditId = "",
    [int]$FileCount = -1
  )
  $entry = [PSCustomObject]@{ event_type = $EventType; command = $Command; decision = $Decision }
  if ($Reason) { $entry | Add-Member -NotePropertyName "reason" -NotePropertyValue $Reason | Out-Null }
  if ($Detail) { $entry | Add-Member -NotePropertyName "detail" -NotePropertyValue $Detail | Out-Null }
  if ($Url) { $entry | Add-Member -NotePropertyName "url" -NotePropertyValue $Url | Out-Null }
  if ($AuditId) { $entry | Add-Member -NotePropertyName "audit_id" -NotePropertyValue $AuditId | Out-Null }
  if ($FileCount -ge 0) { $entry | Add-Member -NotePropertyName "file_count" -NotePropertyValue $FileCount | Out-Null }
  Write-AuditLog -Entry $entry -LogPath $AuditLogPath | Out-Null
}

Write-DebugLog -Message "===== check-git-event.ps1 invoked | EventType=$EventType =====" -LogPath $DebugLogPath

try {
  $payload = Get-StdinText

  # An empty/unrecognized EventType means hooks.json wiring is broken (a
  # matcher pointing at this script without a valid argument) -- not
  # something this hook can meaningfully judge.
  if (-not $EventType) {
    Write-JsonPermissionAllow
    return
  }

  $parsedPayload = $null
  try {
    $parsedPayload = $payload | ConvertFrom-Json -ErrorAction Stop
  } catch {
    # Deliberately always allow on malformed payload -- same reasoning as
    # check-write.ps1: this usually signals a Cursor integration/encoding
    # quirk, not an unreachable scanner.
    Write-JsonPermissionAllow -Message "Received invalid input."
    return
  }

  $commandText = [string](Get-JsonProperty -InputObject $parsedPayload -Name "command" -Default "")
  $cwd = [string](Get-JsonProperty -InputObject $parsedPayload -Name "cwd" -Default "")

  if ((-not $cwd) -or (-not (Test-Path (Join-Path $cwd ".git")))) {
    # Not a git repo (or cwd missing/inaccessible) -- nothing this hook is
    # designed to evaluate.
    Write-JsonPermissionAllow
    return
  }

  $actionNoun = "Push"
  $actionDesc = "this push"
  switch ($EventType) {
    "git.commit"    { $actionNoun = "Commit"; $actionDesc = "this commit" }
    "git.pr_create" { $actionNoun = "Pull request creation"; $actionDesc = "this pull request creation" }
  }

  $changedFiles = @()
  switch ($EventType) {
    "git.push"      { $changedFiles = Get-UnpushedChangedFiles -RepoPath $cwd }
    "git.commit"    { $changedFiles = Get-StagedChangedFiles -RepoPath $cwd }
    "git.pr_create" { $changedFiles = Get-PrCreateChangedFiles -RepoPath $cwd -CommandText $commandText }
    default {
      # An EventType this script doesn't recognize is a hooks.json wiring
      # bug, not a signal about the command itself.
      Write-JsonPermissionAllow
      return
    }
  }

  $gitRepoUrl = Get-GitRemoteUrlOrEmpty -RepoPath $cwd
  $gitBranch = Get-GitCurrentBranchOrEmpty -RepoPath $cwd

  Write-DebugLog -Message "event=$EventType cwd=$cwd branch=$gitBranch changed_file_count=$($changedFiles.Count)" -LogPath $DebugLogPath

  # Build the file list to submit: skip binary files and anything missing
  # from the working tree, and enforce the size/count guardrail rather
  # than silently submitting an unbounded fan-out. Content is read from the
  # current working-tree state of each path -- see check-git-event.sh's
  # identical comment for why that's a deliberate, documented
  # simplification rather than reading an exact historical/staged blob.
  $fileFormEntries = New-Object System.Collections.Generic.List[string]
  $totalBytes = 0
  $capped = $false

  foreach ($relPath in $changedFiles) {
    if (-not $relPath) { continue }
    $absPath = Join-Path $cwd $relPath
    if (-not (Test-Path $absPath -PathType Leaf)) { continue }
    if (Test-BinaryFile -Path $absPath) { continue }

    if ($fileFormEntries.Count -ge $MaxFiles) {
      $capped = $true
      continue
    }
    $fileSize = (Get-Item $absPath).Length
    if (($totalBytes + $fileSize) -gt $MaxTotalBytes) {
      $capped = $true
      continue
    }
    $totalBytes += $fileSize
    $fileFormEntries.Add("Files=@${absPath};filename=$relPath")
  }

  if ($capped) {
    Write-DebugLog -Message "File set exceeded the $MaxFiles-file/$MaxTotalBytes-byte guardrail; remaining files were not submitted for scanning" -LogPath $DebugLogPath
  }

  # Nothing left to scan -- allow, same "nothing to scan" posture as
  # check-write.ps1.
  if ($fileFormEntries.Count -eq 0) {
    Write-JsonPermissionAllow
    return
  }

  $config = Resolve-PnConfig
  if ($null -eq $config) {
    $reason = "Paradigm Networks not configured -- run the paradigmnetworks-login skill"
    Write-CheckGitEventAuditLog -EventType $EventType -Command $commandText `
      -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
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

  $detectionsUrl = $DetectionsUrlOverride
  if (-not $detectionsUrl) {
    $detectionsUrl = "$($config.BaseUrl.TrimEnd('/'))/api/v1/detections/evaluate"
  }

  Write-DebugLog -Message "Evaluating $EventType | url=$detectionsUrl | file_count=$($fileFormEntries.Count) | total_bytes=$totalBytes" -LogPath $DebugLogPath

  # SessionId is always empty: this plugin has no Cursor session identity
  # to send (design doc section 0 -- a legitimate, expected value).
  $verdict = Invoke-PnDetectionEvaluate -Url $detectionsUrl -AuthToken $config.AccessToken -TimeoutSec $TimeoutSeconds `
    -EventType $EventType -Tool "cursor-plugin" -Cwd $cwd -SessionId "" `
    -GitRepoUrl $gitRepoUrl -GitBranch $gitBranch -CommandText $commandText `
    -FileFormEntries $fileFormEntries.ToArray()

  switch ($verdict.Status) {
    "timeout" {
      Write-CheckGitEventAuditLog -EventType $EventType -Command $commandText `
        -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
        -Reason "api_timeout" -Detail "${TimeoutSeconds}s timeout" -Url $detectionsUrl
      if ($FailureMode -eq "open") {
        Write-JsonPermissionAllow -Message "The scanning service is unavailable (timed out after ${TimeoutSeconds}s). ${actionNoun} allowed WITHOUT a security scan."
      } else {
        Write-JsonPermissionDeny -UserMessage "The scanning service is unavailable (timed out after ${TimeoutSeconds}s). ${actionNoun} blocked." `
          -AgentMessage "The scanning service is unavailable (timed out after ${TimeoutSeconds}s). Do not retry ${actionDesc}."
      }
    }
    "unreachable" {
      Write-CheckGitEventAuditLog -EventType $EventType -Command $commandText `
        -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
        -Reason "api_unreachable" -Detail "connection failed" -Url $detectionsUrl
      if ($FailureMode -eq "open") {
        Write-JsonPermissionAllow -Message "The scanning service is unavailable (connection failed). ${actionNoun} allowed WITHOUT a security scan."
      } else {
        Write-JsonPermissionDeny -UserMessage "The scanning service is unavailable (connection failed). ${actionNoun} blocked." `
          -AgentMessage "The scanning service is unavailable (connection failed). Do not retry ${actionDesc}."
      }
    }
    "http_error" {
      Write-CheckGitEventAuditLog -EventType $EventType -Command $commandText `
        -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
        -Reason "api_http_error" -Detail "HTTP $($verdict.HttpStatus)" -Url $detectionsUrl
      if ($FailureMode -eq "open") {
        Write-JsonPermissionAllow -Message "The scanning service returned an error (HTTP $($verdict.HttpStatus)). ${actionNoun} allowed WITHOUT a security scan."
      } else {
        Write-JsonPermissionDeny -UserMessage "The scanning service returned an error (HTTP $($verdict.HttpStatus)). ${actionNoun} blocked." `
          -AgentMessage "The scanning service returned an error (HTTP $($verdict.HttpStatus)). Do not retry ${actionDesc}."
      }
    }
    "invalid_json" {
      Write-CheckGitEventAuditLog -EventType $EventType -Command $commandText `
        -Decision $(if ($FailureMode -eq "closed") { "deny" } else { "allow" }) `
        -Reason "api_invalid_json" -Detail "scanner returned invalid JSON" -Url $detectionsUrl
      if ($FailureMode -eq "open") {
        Write-JsonPermissionAllow -Message "The scanning service returned an invalid response. ${actionNoun} allowed WITHOUT a security scan."
      } else {
        Write-JsonPermissionDeny -UserMessage "The scanning service returned an invalid response. ${actionNoun} blocked." `
          -AgentMessage "The scanning service returned an invalid response. Do not retry ${actionDesc}."
      }
    }
    default {
      # "ok" -- Invoke-PnDetectionEvaluate has no other Status value.
      Set-PnLastSuccessfulScan
      Write-CheckGitEventAuditLog -EventType $EventType -Command $commandText `
        -Decision $verdict.Decision -AuditId $verdict.AuditId -FileCount $fileFormEntries.Count

      if ($verdict.Decision -eq "block") {
        $userMessage = $verdict.Message
        if (-not $userMessage) { $userMessage = "A policy violation was detected." }
        Write-JsonPermissionDeny -UserMessage $userMessage -AgentMessage "$userMessage $(Build-StopInstruction $actionDesc)"
      } else {
        # "warn" and "allow" both let the operation proceed -- see
        # check-git-event.sh's identical comment (design doc section 4).
        if ($verdict.Message) {
          Write-JsonPermissionAllow -Message $verdict.Message
        } else {
          Write-JsonPermissionAllow
        }
      }
    }
  }
} catch {
  # Anything unexpected -- match the FailureMode posture for an
  # unreachable scanner rather than crash without a response, same as
  # check-write.ps1's outer catch.
  Write-DebugLog -Message "UNEXPECTED ERROR | $($_.Exception.GetType().FullName): $($_.Exception.Message)" -LogPath $DebugLogPath
  if ($FailureMode -eq "open") {
    Write-JsonPermissionAllow -Message "The scanning service is unavailable. Allowed WITHOUT a security scan."
  } else {
    Write-JsonPermissionDeny -UserMessage "The scanning service is unavailable. Blocked." `
      -AgentMessage "The scanning service is unavailable. Do not retry this action."
  }
}
