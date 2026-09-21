# Composite scan client (Windows) -- mirrors scripts/lib/scan-client.sh.
# See that file's header for the full design rationale: calls
# POST /api/v1/plugin/codechain/sessions/{id}/scan, which runs whichever of
# PromptGuard, PolicyEngine, and Code Defense the org's policy has enabled
# against the given text and returns one allow/warn/block verdict.
# SessionId is required -- the endpoint also persists a chatapi document
# tagged with it, joining the gating decision to the session's other
# recorded events.

$Script:ScanDebugLogPath = Join-Path $HOME ".paradigm-scanner\scan-client.log"

# Invoke-PnScanText -BaseUrl ... -AccessToken ... -TimeoutSec ...
#   -SessionId ... -Cwd ... -GitRepoUrl ... -GitBranch ... -Text ...
# Returns [PSCustomObject]@{
#   Status      = "ok" | "no_session" | "timeout" | "unreachable" | "http_error" | "invalid_json"
#   HttpStatus  = raw HTTP status (only meaningful for http_error)
#   Action      = "allow" | "warn" | "block" | "" (only set when Status=ok;
#                 empty means valid JSON with no recognized action_to_take --
#                 treat as an anomaly, not a guessed verdict)
#   Message     = the scan's own explanation, if any
#   ThreatLevel = overall_threat_level, if any
# }
function Invoke-PnScanText {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$AccessToken,
    [Parameter(Mandatory = $true)][int]$TimeoutSec,
    [Parameter(Mandatory = $true)][string]$SessionId,
    [string]$Cwd = "",
    [string]$GitRepoUrl = "",
    [string]$GitBranch = "",
    [Parameter(Mandatory = $true)][string]$Text
  )

  $result = [PSCustomObject]@{
    Status      = ""
    HttpStatus  = $null
    Action      = ""
    Message     = ""
    ThreatLevel = ""
  }

  if (-not $SessionId) {
    $result.Status = "no_session"
    Write-DebugLog -Message "scan: no session id available, cannot call the scan endpoint" -LogPath $Script:ScanDebugLogPath
    return $result
  }

  $bodyObj = [PSCustomObject]@{
    Platform   = "cursor-hooks"
    Cwd        = $Cwd
    GitRepoUrl = $GitRepoUrl
    GitBranch  = $GitBranch
    Text       = $Text
  }
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-CompactJson -InputObject $bodyObj))
  $url = "$($BaseUrl.TrimEnd('/'))/api/v1/plugin/codechain/sessions/$SessionId/scan"
  $raw = Invoke-HttpPostRaw -Url $url -BodyBytes $bodyBytes -ContentType "application/json" -AuthToken $AccessToken -TimeoutSec $TimeoutSec

  if ($raw.TimedOut) {
    $result.Status = "timeout"
    Write-DebugLog -Message "scan: timeout after ${TimeoutSec}s | url=$url" -LogPath $Script:ScanDebugLogPath
    return $result
  }
  if ($raw.ConnectionFailed) {
    $result.Status = "unreachable"
    Write-DebugLog -Message "scan: unreachable | url=$url" -LogPath $Script:ScanDebugLogPath
    return $result
  }

  $result.HttpStatus = $raw.StatusCode
  if ($raw.StatusCode -lt 200 -or $raw.StatusCode -ge 300) {
    $result.Status = "http_error"
    Write-DebugLog -Message "scan: HTTP error status=$($raw.StatusCode) | url=$url" -LogPath $Script:ScanDebugLogPath
    return $result
  }

  $parsed = $null
  try {
    $parsed = $raw.Body | ConvertFrom-Json -ErrorAction Stop
  } catch {
    $result.Status = "invalid_json"
    Write-DebugLog -Message "scan: invalid JSON response | url=$url" -LogPath $Script:ScanDebugLogPath
    return $result
  }

  $result.Action = [string](Get-JsonProperty -InputObject $parsed -Name "action_to_take" -Default "")
  $result.Message = [string](Get-JsonProperty -InputObject $parsed -Name "message" -Default "")
  $result.ThreatLevel = [string](Get-JsonProperty -InputObject $parsed -Name "overall_threat_level" -Default "")
  $result.Status = "ok"
  Write-DebugLog -Message "scan: ok action=$($result.Action) threat_level=$($result.ThreatLevel) session=$SessionId | url=$url" -LogPath $Script:ScanDebugLogPath
  return $result
}
