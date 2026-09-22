# Code Chain plugin-hooks recording client (Windows) -- mirrors
# scripts/lib/codechain-client.sh. See that file's header for the full
# design rationale: this is a DIFFERENT concern from lib/detection-
# client.ps1 (which gates), every function here only RECORDS, is
# best-effort, and must never affect a hook's returned JSON or exit code.
#
# SessionId is Cursor's own conversation_id, used as-is on every call --
# there is no server-side minting or lookup, so there is no local cache
# either. Every write call carries Cwd/GitRepoUrl/GitBranch directly.

$Script:CodechainDebugLogPath = Join-Path $env:USERPROFILE ".paradigm-scanner\codechain-client.log"

# Fire-and-forget session-start marker. Best-effort: nothing else here
# depends on this call having succeeded.
function Register-CodechainSession {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$AccessToken,
    [Parameter(Mandatory = $true)][int]$TimeoutSec,
    [Parameter(Mandatory = $true)][string]$SessionId,
    [string]$Cwd = "",
    [string]$GitRepoUrl = "",
    [string]$GitBranch = ""
  )
  if (-not $SessionId) { return }
  if (-not $BaseUrl) { return }

  $bodyObj = [PSCustomObject]@{
    Platform   = "cursor-hooks"
    SessionId  = $SessionId
    Cwd        = $Cwd
    GitRepoUrl = $GitRepoUrl
    GitBranch  = $GitBranch
  }
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-CompactJson -InputObject $bodyObj))
  $url = "$($BaseUrl.TrimEnd('/'))/api/v1/plugin/codechain/sessions"
  $result = Invoke-HttpPostRaw -Url $url -BodyBytes $bodyBytes -ContentType "application/json" -AuthToken $AccessToken -TimeoutSec $TimeoutSec
  if ($result.StatusCode -ne 200) {
    Write-DebugLog -Message "codechain: session-start recording failed (status=$($result.StatusCode)) session=$SessionId" -LogPath $Script:CodechainDebugLogPath
  } else {
    Write-DebugLog -Message "codechain: session-start recorded successfully (session=$SessionId)" -LogPath $Script:CodechainDebugLogPath
  }
}

function Send-CodechainTurn {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$AccessToken,
    [Parameter(Mandatory = $true)][int]$TimeoutSec,
    [Parameter(Mandatory = $true)][string]$SessionId,
    [string]$Cwd = "",
    [string]$GitRepoUrl = "",
    [string]$GitBranch = "",
    [string]$Prompt = "",
    [string]$Response = "",
    # Cursor's own generation_id, when the hook payload carried one -- see
    # lib/codechain-client.sh's header.
    [string]$GenerationId = "",
    # Cursor's own hook-reported model name -- see lib/codechain-client.sh's header.
    [string]$Model = ""
  )
  if (-not $SessionId) { return }
  if (-not $BaseUrl) { return }
  if (-not $Prompt -and -not $Response) { return }

  $bodyObj = [PSCustomObject]@{
    Platform     = "cursor-hooks"
    Cwd          = $Cwd
    GitRepoUrl   = $GitRepoUrl
    GitBranch    = $GitBranch
    Prompt       = $Prompt
    Response     = $Response
    GenerationId = $GenerationId
    Model        = $Model
  }
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-CompactJson -InputObject $bodyObj))
  $url = "$($BaseUrl.TrimEnd('/'))/api/v1/plugin/codechain/sessions/$SessionId/turns"
  $result = Invoke-HttpPostRaw -Url $url -BodyBytes $bodyBytes -ContentType "application/json" -AuthToken $AccessToken -TimeoutSec $TimeoutSec
  if ($result.StatusCode -ne 204) {
    Write-DebugLog -Message "codechain: turn recording failed (status=$($result.StatusCode)) session=$SessionId" -LogPath $Script:CodechainDebugLogPath
  } else {
    Write-DebugLog -Message "codechain: turn recorded successfully (session=$SessionId, prompt_len=$($Prompt.Length), response_len=$($Response.Length))" -LogPath $Script:CodechainDebugLogPath
  }
}

function Send-CodechainShellEvent {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$AccessToken,
    [Parameter(Mandatory = $true)][int]$TimeoutSec,
    [Parameter(Mandatory = $true)][string]$SessionId,
    [string]$Cwd = "",
    [string]$GitRepoUrl = "",
    [string]$GitBranch = "",
    [Parameter(Mandatory = $true)][string]$CommandText,
    [string]$Output = ""
  )
  if (-not $SessionId) { return }
  if (-not $BaseUrl) { return }
  if (-not $CommandText) { return }

  $bodyObj = [PSCustomObject]@{
    Platform   = "cursor-hooks"
    Cwd        = $Cwd
    GitRepoUrl = $GitRepoUrl
    GitBranch  = $GitBranch
    Command    = $CommandText
    Output     = $Output
  }
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-CompactJson -InputObject $bodyObj))
  $url = "$($BaseUrl.TrimEnd('/'))/api/v1/plugin/codechain/sessions/$SessionId/shell-events"
  $result = Invoke-HttpPostRaw -Url $url -BodyBytes $bodyBytes -ContentType "application/json" -AuthToken $AccessToken -TimeoutSec $TimeoutSec
  if ($result.StatusCode -ne 204) {
    Write-DebugLog -Message "codechain: shell-event recording failed (status=$($result.StatusCode)) session=$SessionId" -LogPath $Script:CodechainDebugLogPath
  } else {
    $commandPreview = if ($CommandText.Length -gt 80) { $CommandText.Substring(0, 80) } else { $CommandText }
    Write-DebugLog -Message "codechain: shell-event recorded successfully (session=$SessionId, command=$commandPreview)" -LogPath $Script:CodechainDebugLogPath
  }
}

# Fired from sessionEnd. There is no server-side session state to look up
# first -- SessionId is Cursor's own conversation_id, so this always has
# something valid to close.
function Close-CodechainSession {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$AccessToken,
    [Parameter(Mandatory = $true)][int]$TimeoutSec,
    [Parameter(Mandatory = $true)][string]$SessionId
  )
  if (-not $SessionId) { return }
  if (-not $BaseUrl) { return }

  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes("{}")
  $url = "$($BaseUrl.TrimEnd('/'))/api/v1/plugin/codechain/sessions/$SessionId/close"
  $result = Invoke-HttpPostRaw -Url $url -BodyBytes $bodyBytes -ContentType "application/json" -AuthToken $AccessToken -TimeoutSec $TimeoutSec
  if ($result.StatusCode -ne 204) {
    Write-DebugLog -Message "codechain: session close failed (status=$($result.StatusCode)) session=$SessionId" -LogPath $Script:CodechainDebugLogPath
  } else {
    Write-DebugLog -Message "codechain: session closed successfully (session=$SessionId)" -LogPath $Script:CodechainDebugLogPath
  }
}
