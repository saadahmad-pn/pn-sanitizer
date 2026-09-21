# Code Defense Service scan client (Windows) -- mirrors scripts/lib/scan-
# client.sh. See that file's header for the full design rationale: replaces
# /v1/messages-based prompt/write scanning with a direct call to
# POST /api/v1/codedefense/scan (no model invocation), and is an interim
# step -- PromptGuard/PolicyEngine coverage is not replicated here yet.

$Script:ScanDebugLogPath = Join-Path $HOME ".paradigm-scanner\scan-client.log"

# Invoke-PnScanText -BaseUrl ... -AccessToken ... -TimeoutSec ... -Text ...
# Returns [PSCustomObject]@{
#   Status      = "ok" | "timeout" | "unreachable" | "http_error" | "invalid_json"
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
    [Parameter(Mandatory = $true)][string]$Text
  )

  $result = [PSCustomObject]@{
    Status      = ""
    HttpStatus  = $null
    Action      = ""
    Message     = ""
    ThreatLevel = ""
  }

  $url = "$($BaseUrl.TrimEnd('/'))/api/v1/codedefense/scan"
  $formArgs = @("--form-string", "text=$Text")
  $raw = Invoke-HttpPostMultipart -Url $url -FormArgs $formArgs -AuthToken $AccessToken -TimeoutSec $TimeoutSec

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
  Write-DebugLog -Message "scan: ok action=$($result.Action) threat_level=$($result.ThreatLevel) | url=$url" -LogPath $Script:ScanDebugLogPath
  return $result
}
