# Shared client for POST /api/v1/detections/evaluate (Windows). Mirrors
# scripts/lib/detection-client.sh function-for-function.

Set-StrictMode -Version Latest

# Test-BinaryFile -Path ...
# Classic NUL-byte heuristic over the first 8KB, mirroring is_binary_file in
# detection-client.sh -- see that function's comment for the portability
# rationale (this is the Windows side, so the constraint is different --
# .NET stream APIs, not a dependency on GNU/BSD tool availability -- but the
# same heuristic).
function Test-BinaryFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  try {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  } catch {
    return $false
  }
  try {
    $len = [Math]::Min(8000, $stream.Length)
    if ($len -eq 0) { return $false }
    $bytes = New-Object byte[] $len
    $stream.Read($bytes, 0, $len) | Out-Null
  } finally {
    $stream.Close()
  }

  foreach ($b in $bytes) {
    if ($b -eq 0) { return $true }
  }
  return $false
}

# Invoke-PnDetectionEvaluate -Url ... -AuthToken ... -TimeoutSec ... -EventType ...
#   -Tool ... -Cwd ... -SessionId ... -GitRepoUrl ... -GitBranch ... -CommandText ...
#   -FileFormEntries <string[]>
# Mirrors pn_evaluate_detection in detection-client.sh. Each entry in
# FileFormEntries is a pre-formatted curl -F value, e.g.
# "Files=@C:\abs\path\to\file;filename=relative/path" -- built by the caller
# (see check-git-event.ps1), since only it knows which absolute path each
# repo-relative display name maps to.
#
# Returns [PSCustomObject]@{
#   Status      -- "ok" | "timeout" | "unreachable" | "http_error" | "invalid_json"
#   HttpStatus  -- set when Status = "http_error"
#   Decision    -- "allow" | "warn" | "block", set when Status = "ok"
#   Message     -- set when Status = "ok"
#   AuditId     -- set when Status = "ok"
# }
function Invoke-PnDetectionEvaluate {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$AuthToken = "",
    [int]$TimeoutSec = 240,
    [Parameter(Mandatory = $true)][string]$EventType,
    [Parameter(Mandatory = $true)][string]$Tool,
    [Parameter(Mandatory = $true)][string]$Cwd,
    [string]$SessionId = "",
    [string]$GitRepoUrl = "",
    [string]$GitBranch = "",
    [Parameter(Mandatory = $true)][string]$CommandText,
    [AllowEmptyCollection()][string[]]$FileFormEntries = @()
  )

  $formArgs = @(
    "--form-string", "EventType=$EventType",
    "--form-string", "Tool=$Tool",
    "--form-string", "Cwd=$Cwd",
    "--form-string", "SessionId=$SessionId",
    "--form-string", "GitRepoUrl=$GitRepoUrl",
    "--form-string", "GitBranch=$GitBranch",
    "--form-string", "CommandText=$CommandText"
  )
  foreach ($entry in $FileFormEntries) {
    $formArgs += @("-F", $entry)
  }

  $result = Invoke-HttpPostMultipart -Url $Url -FormArgs $formArgs -AuthToken $AuthToken -TimeoutSec $TimeoutSec

  if ($result.TimedOut) {
    return [PSCustomObject]@{ Status = "timeout" }
  }
  if ($result.ConnectionFailed) {
    return [PSCustomObject]@{ Status = "unreachable" }
  }
  if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
    return [PSCustomObject]@{ Status = "http_error"; HttpStatus = $result.StatusCode }
  }

  $parsed = $null
  try {
    $parsed = $result.Body | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return [PSCustomObject]@{ Status = "invalid_json" }
  }

  # A missing/null Decision on an otherwise-valid 2xx response is treated as
  # "block" -- see pn_evaluate_detection's identical comment in
  # detection-client.sh for the fail-closed rationale (never silently guess
  # allow on a response shape we don't understand).
  $decision = Get-JsonProperty -InputObject $parsed -Name "Decision" -Default "block"
  $message = Get-JsonProperty -InputObject $parsed -Name "Message" -Default ""
  $auditId = Get-JsonProperty -InputObject $parsed -Name "AuditId" -Default ""

  return [PSCustomObject]@{
    Status   = "ok"
    Decision = $decision
    Message  = $message
    AuditId  = $auditId
  }
}
