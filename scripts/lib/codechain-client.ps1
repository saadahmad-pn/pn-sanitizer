# Code Chain plugin-hooks recording client (Windows) -- mirrors
# scripts/lib/codechain-client.sh. See that file's header for the full
# design rationale: this is a DIFFERENT concern from lib/detection-
# client.ps1 (which gates), every function here only RECORDS, is
# best-effort, and must never affect a hook's returned JSON or exit code.

$Script:CodechainSessionCacheDir = Join-Path $env:USERPROFILE ".paradigm-scanner\codechain-sessions"
$Script:CodechainDebugLogPath = Join-Path $env:USERPROFILE ".paradigm-scanner\codechain-client.log"

function Get-SanitizedClientSessionId {
  param([Parameter(Mandatory = $true)][string]$ClientSessionId)
  return ($ClientSessionId -replace '[^A-Za-z0-9_.-]', '_')
}

function Get-CodechainCachePath {
  param([Parameter(Mandatory = $true)][string]$ClientSessionId)
  $safe = Get-SanitizedClientSessionId -ClientSessionId $ClientSessionId
  return (Join-Path $Script:CodechainSessionCacheDir "$safe.txt")
}

function Get-CodechainCachedSessionId {
  param([Parameter(Mandatory = $true)][string]$ClientSessionId)
  $path = Get-CodechainCachePath -ClientSessionId $ClientSessionId
  if (Test-Path $path -PathType Leaf) {
    try { return (Get-Utf8FileText -Path $path).Trim() } catch { return "" }
  }
  return ""
}

# Atomic write (temp file + Move-Item), same rationale as this codebase's
# other persisted local state (credentials.json).
function Set-CodechainCachedSessionId {
  param(
    [Parameter(Mandatory = $true)][string]$ClientSessionId,
    [Parameter(Mandatory = $true)][string]$SessionId
  )
  try {
    if (-not (Test-Path $Script:CodechainSessionCacheDir)) {
      New-Item -ItemType Directory -Path $Script:CodechainSessionCacheDir -Force -ErrorAction Stop | Out-Null
    }
    $path = Get-CodechainCachePath -ClientSessionId $ClientSessionId
    $tempFile = "$path.$([System.Guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($tempFile, $SessionId, [System.Text.Encoding]::UTF8)
    Move-Item -Path $tempFile -Destination $path -Force
  } catch {
    # Best-effort cache write -- a failure here just means the next hook
    # call re-registers (idempotent server-side), not a real error.
  }
}

# Sets $Script:PnCodechainSessionId to the server-minted SessionId, or ""
# on any failure -- mirrors codechain-client.sh's PN_CODECHAIN_SESSION_ID
# global-return convention. Idempotent via the local cache.
function Get-CodechainSessionId {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$AccessToken,
    [Parameter(Mandatory = $true)][int]$TimeoutSec,
    [Parameter(Mandatory = $true)][string]$ClientSessionId,
    [string]$Cwd = "",
    [string]$GitRepoUrl = "",
    [string]$GitBranch = "",
    [string]$Platform = "cursor-hooks"
  )

  $Script:PnCodechainSessionId = ""
  if (-not $ClientSessionId) { return }

  $cached = Get-CodechainCachedSessionId -ClientSessionId $ClientSessionId
  if ($cached) {
    $Script:PnCodechainSessionId = $cached
    return
  }
  if (-not $BaseUrl) { return }

  $bodyObj = [PSCustomObject]@{
    Platform        = $Platform
    ClientSessionId = $ClientSessionId
    Cwd             = $Cwd
    GitRepoUrl      = $GitRepoUrl
    GitBranch       = $GitBranch
  }
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-CompactJson -InputObject $bodyObj))
  $url = "$($BaseUrl.TrimEnd('/'))/api/v1/plugin/codechain/sessions"
  $result = Invoke-HttpPostRaw -Url $url -BodyBytes $bodyBytes -ContentType "application/json" -AuthToken $AccessToken -TimeoutSec $TimeoutSec

  if ($result.TimedOut -or $result.ConnectionFailed -or -not $result.Body -or $result.StatusCode -ne 200) {
    Write-DebugLog -Message "codechain: session registration failed (status=$($result.StatusCode))" -LogPath $Script:CodechainDebugLogPath
    return
  }

  try {
    $parsed = $result.Body | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return
  }
  $sessionId = Get-JsonProperty -InputObject $parsed -Name "SessionId" -Default ""
  if (-not $sessionId) { return }

  Set-CodechainCachedSessionId -ClientSessionId $ClientSessionId -SessionId $sessionId
  $Script:PnCodechainSessionId = $sessionId
}

function Send-CodechainTurn {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$AccessToken,
    [Parameter(Mandatory = $true)][int]$TimeoutSec,
    [Parameter(Mandatory = $true)][string]$SessionId,
    [string]$Prompt = "",
    [string]$Response = ""
  )
  if (-not $SessionId) { return }
  if (-not $Prompt -and -not $Response) { return }

  $bodyObj = [PSCustomObject]@{ Prompt = $Prompt; Response = $Response }
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-CompactJson -InputObject $bodyObj))
  $url = "$($BaseUrl.TrimEnd('/'))/api/v1/plugin/codechain/sessions/$SessionId/turns"
  $result = Invoke-HttpPostRaw -Url $url -BodyBytes $bodyBytes -ContentType "application/json" -AuthToken $AccessToken -TimeoutSec $TimeoutSec
  if ($result.StatusCode -ne 204) {
    Write-DebugLog -Message "codechain: turn recording failed (status=$($result.StatusCode)) session=$SessionId" -LogPath $Script:CodechainDebugLogPath
  }
}

function Send-CodechainShellEvent {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$AccessToken,
    [Parameter(Mandatory = $true)][int]$TimeoutSec,
    [Parameter(Mandatory = $true)][string]$SessionId,
    [Parameter(Mandatory = $true)][string]$CommandText,
    [string]$Output = "",
    [string]$Cwd = ""
  )
  if (-not $SessionId) { return }
  if (-not $CommandText) { return }

  $bodyObj = [PSCustomObject]@{ Command = $CommandText; Output = $Output; Cwd = $Cwd }
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-CompactJson -InputObject $bodyObj))
  $url = "$($BaseUrl.TrimEnd('/'))/api/v1/plugin/codechain/sessions/$SessionId/shell-events"
  $result = Invoke-HttpPostRaw -Url $url -BodyBytes $bodyBytes -ContentType "application/json" -AuthToken $AccessToken -TimeoutSec $TimeoutSec
  if ($result.StatusCode -ne 204) {
    Write-DebugLog -Message "codechain: shell-event recording failed (status=$($result.StatusCode)) session=$SessionId" -LogPath $Script:CodechainDebugLogPath
  }
}

# Fired from sessionEnd -- resolves the cached SessionId for
# ClientSessionId itself, same rationale as codechain-client.sh's
# Close-CodechainSession sibling.
function Close-CodechainSession {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$AccessToken,
    [Parameter(Mandatory = $true)][int]$TimeoutSec,
    [Parameter(Mandatory = $true)][string]$ClientSessionId
  )
  if (-not $ClientSessionId) { return }
  $sessionId = Get-CodechainCachedSessionId -ClientSessionId $ClientSessionId
  if (-not $sessionId) { return }
  if (-not $BaseUrl) { return }

  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes("{}")
  $url = "$($BaseUrl.TrimEnd('/'))/api/v1/plugin/codechain/sessions/$sessionId/close"
  $result = Invoke-HttpPostRaw -Url $url -BodyBytes $bodyBytes -ContentType "application/json" -AuthToken $AccessToken -TimeoutSec $TimeoutSec
  if ($result.StatusCode -ne 204) {
    Write-DebugLog -Message "codechain: session close failed (status=$($result.StatusCode)) session=$sessionId" -LogPath $Script:CodechainDebugLogPath
  }

  $path = Get-CodechainCachePath -ClientSessionId $ClientSessionId
  Remove-Item -Path $path -ErrorAction SilentlyContinue
}
