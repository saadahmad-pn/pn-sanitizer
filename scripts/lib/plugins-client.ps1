# Windows mirror of lib/plugins-client.sh: client for control-server's
# standardized plugin API, POST /api/v1/plugins/sessions/{id}/*. Replaces
# lib/scan-client.ps1, lib/codechain-client.ps1 and lib/detection-client.ps1,
# whose endpoints control-server no longer serves. See plugins-client.sh's
# header for the domain/Action vocabulary and the design doc it cites.
#
# Each gating call returns a result object instead of setting globals:
#   Status      "ok" | "no_session" | "timeout" | "unreachable" | "http_error" | "invalid_json"
#   HttpStatus  HTTP status code, when one was received
#   Action      action_to_take ("allow" | "warn" | "block" | "")
#   Message     the scan's own explanation, if any
#   ThreatLevel overall_threat_level, if any
#   ToolUseId   the id the server used (tool-calls domain only)

Set-StrictMode -Version Latest

$Script:PluginsDebugLogPath = Join-Path $HOME ".paradigm-networks\plugins-client.log"

# Same Platform identifier as plugins-client.sh's PN_PLUGIN_PLATFORM.
$Script:PnPluginPlatform = "cursor-plugin"

# Test-BinaryFile -Path ...
# NUL-byte heuristic over the first 8KB. An empty file is never binary --
# same contract as is_binary_file in plugins-client.sh.
function Test-BinaryFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  try {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  } catch {
    return $false
  }
  try {
    $len = [int][Math]::Min(8000, $stream.Length)
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

function New-PnPluginResult {
  return [PSCustomObject]@{
    Status      = ""
    HttpStatus  = $null
    Action      = ""
    Message     = ""
    ThreatLevel = ""
    ToolUseId   = ""
  }
}

# Invoke-PnPluginPost -BaseUrl -AccessToken -TimeoutSec -SessionId -Domain -Body
# Serializes Body (an ordered hashtable) and posts it to
# <base>/api/v1/plugins/sessions/<id>/<domain>. Depth 64, not
# ConvertTo-CompactJson's 10: Body.Input carries an MCP tool's structured
# arguments verbatim, which can nest deeper than that.
function Invoke-PnPluginPost {
  param(
    [string]$BaseUrl,
    [string]$AccessToken,
    [int]$TimeoutSec,
    [string]$SessionId,
    [string]$Domain,
    [Parameter(Mandatory = $true)]$Body
  )
  $json = $Body | ConvertTo-Json -Compress -Depth 64
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $url = "$($BaseUrl.TrimEnd('/'))/api/v1/plugins/sessions/$SessionId/$Domain"
  $raw = Invoke-HttpPostRaw -Url $url -BodyBytes $bodyBytes -ContentType "application/json" -AuthToken $AccessToken -TimeoutSec $TimeoutSec
  return [PSCustomObject]@{ Url = $url; Raw = $raw }
}

# ConvertFrom-PnPluginResponse -Url -Raw
# Shared response-parsing tail for the gating domains (prompts,
# tool-calls), mirroring _pn_parse_plugin_response.
function ConvertFrom-PnPluginResponse {
  param([string]$Url, $Raw)

  $result = New-PnPluginResult
  if ($Raw.TimedOut) {
    $result.Status = "timeout"
    Write-DebugLog -Message "plugins: timeout after call to $Url" -LogPath $Script:PluginsDebugLogPath
    return $result
  }
  if ($Raw.ConnectionFailed) {
    $result.Status = "unreachable"
    Write-DebugLog -Message "plugins: unreachable | url=$Url" -LogPath $Script:PluginsDebugLogPath
    return $result
  }

  $result.HttpStatus = $Raw.StatusCode
  if ($Raw.StatusCode -lt 200 -or $Raw.StatusCode -ge 300) {
    $result.Status = "http_error"
    Write-DebugLog -Message "plugins: HTTP error status=$($Raw.StatusCode) | url=$Url" -LogPath $Script:PluginsDebugLogPath
    return $result
  }

  $parsed = $null
  try {
    $parsed = $Raw.Body | ConvertFrom-Json -ErrorAction Stop
  } catch {
    $parsed = $null
  }
  if ($null -eq $parsed) {
    $result.Status = "invalid_json"
    Write-DebugLog -Message "plugins: invalid JSON response | url=$Url" -LogPath $Script:PluginsDebugLogPath
    return $result
  }

  $result.Action = [string](Get-JsonProperty -InputObject $parsed -Name "action_to_take" -Default "")
  $result.Message = [string](Get-JsonProperty -InputObject $parsed -Name "message" -Default "")
  $result.ThreatLevel = [string](Get-JsonProperty -InputObject $parsed -Name "overall_threat_level" -Default "")
  $result.ToolUseId = [string](Get-JsonProperty -InputObject $parsed -Name "ToolUseId" -Default "")
  $result.Status = "ok"
  Write-DebugLog -Message "plugins: ok action=$($result.Action) threat_level=$($result.ThreatLevel) | url=$Url" -LogPath $Script:PluginsDebugLogPath
  return $result
}

# ---------------------------------------------------------------------------
# Prompts domain
# ---------------------------------------------------------------------------

# Invoke-PnPluginBeforePrompt -- mirrors pn_plugin_before_prompt.
function Invoke-PnPluginBeforePrompt {
  param(
    [string]$BaseUrl,
    [string]$AccessToken,
    [int]$TimeoutSec,
    [string]$SessionId,
    [string]$Cwd = "",
    [string]$GitRepoUrl = "",
    [string]$GitBranch = "",
    [string]$Text = "",
    [string]$GenerationId = "",
    [string]$Model = ""
  )
  if (-not $SessionId) {
    $result = New-PnPluginResult
    $result.Status = "no_session"
    return $result
  }

  $body = [ordered]@{
    Action       = "before_prompt"
    Platform     = $Script:PnPluginPlatform
    Cwd          = $Cwd
    GitRepoUrl   = $GitRepoUrl
    GitBranch    = $GitBranch
    Text         = $Text
    GenerationId = $GenerationId
    Model        = $Model
  }
  $post = Invoke-PnPluginPost -BaseUrl $BaseUrl -AccessToken $AccessToken -TimeoutSec $TimeoutSec -SessionId $SessionId -Domain "prompts" -Body $body
  return (ConvertFrom-PnPluginResponse -Url $post.Url -Raw $post.Raw)
}

# Invoke-PnPluginAfterAgentResponse -- mirrors pn_plugin_after_agent_response.
# Best-effort recording; never returns anything the caller acts on.
function Invoke-PnPluginAfterAgentResponse {
  param(
    [string]$BaseUrl,
    [string]$AccessToken,
    [int]$TimeoutSec,
    [string]$SessionId,
    [string]$Cwd = "",
    [string]$GitRepoUrl = "",
    [string]$GitBranch = "",
    [string]$Prompt = "",
    [string]$Response = "",
    [string]$GenerationId = "",
    [string]$Model = ""
  )
  if (-not $SessionId -or -not $BaseUrl) { return }
  if (-not $Prompt -and -not $Response) { return }

  $body = [ordered]@{
    Action       = "after_agent_response"
    Platform     = $Script:PnPluginPlatform
    Cwd          = $Cwd
    GitRepoUrl   = $GitRepoUrl
    GitBranch    = $GitBranch
    Text         = $Prompt
    Response     = $Response
    GenerationId = $GenerationId
    Model        = $Model
  }
  $post = Invoke-PnPluginPost -BaseUrl $BaseUrl -AccessToken $AccessToken -TimeoutSec $TimeoutSec -SessionId $SessionId -Domain "prompts" -Body $body
  $status = $post.Raw.StatusCode
  if ($null -eq $status -or $status -lt 200 -or $status -ge 300) {
    Write-DebugLog -Message "plugins: after_agent_response failed (HTTP $status) session=$SessionId" -LogPath $Script:PluginsDebugLogPath
  } else {
    Write-DebugLog -Message "plugins: after_agent_response recorded (session=$SessionId, response_len=$($Response.Length))" -LogPath $Script:PluginsDebugLogPath
  }
}

# ---------------------------------------------------------------------------
# Tool-calls domain
# ---------------------------------------------------------------------------

# Invoke-PnPluginBeforeToolCall -- mirrors pn_plugin_before_tool_call.
# Input is the tool's real input as parsed from the hook payload (an object
# for structured args, or a string) and is sent through as-is; it is what
# gets STORED as the tool_use block. ScanContext is only scanned, never
# stored. Files is an array of @{ Filename; ContentBase64 }.
function Invoke-PnPluginBeforeToolCall {
  param(
    [string]$BaseUrl,
    [string]$AccessToken,
    [int]$TimeoutSec,
    [string]$SessionId,
    [string]$Cwd = "",
    [string]$GitRepoUrl = "",
    [string]$GitBranch = "",
    [string]$ToolName = "",
    $InputValue = "",
    [string]$GenerationId = "",
    [string]$Model = "",
    [string]$ToolUseId = "",
    [string]$ScanContext = "",
    [AllowEmptyCollection()][object[]]$Files = @()
  )
  if (-not $SessionId) {
    $result = New-PnPluginResult
    $result.Status = "no_session"
    return $result
  }
  if ($null -eq $InputValue) { $InputValue = "" }

  $body = [ordered]@{
    Action       = "before_tool_call"
    Platform     = $Script:PnPluginPlatform
    Cwd          = $Cwd
    GitRepoUrl   = $GitRepoUrl
    GitBranch    = $GitBranch
    ToolName     = $ToolName
    Input        = $InputValue
    GenerationId = $GenerationId
    Model        = $Model
    ToolUseId    = $ToolUseId
    ScanContext  = $ScanContext
    Files        = @($Files)
  }
  $post = Invoke-PnPluginPost -BaseUrl $BaseUrl -AccessToken $AccessToken -TimeoutSec $TimeoutSec -SessionId $SessionId -Domain "tool-calls" -Body $body
  return (ConvertFrom-PnPluginResponse -Url $post.Url -Raw $post.Raw)
}

# Invoke-PnPluginAfterToolCall -- mirrors pn_plugin_after_tool_call.
# ToolUseId MUST be the id Invoke-PnPluginBeforeToolCall's call used.
function Invoke-PnPluginAfterToolCall {
  param(
    [string]$BaseUrl,
    [string]$AccessToken,
    [int]$TimeoutSec,
    [string]$SessionId,
    [string]$Cwd = "",
    [string]$GitRepoUrl = "",
    [string]$GitBranch = "",
    [string]$ToolUseId = "",
    [string]$Output = "",
    [bool]$IsError = $false,
    [string]$GenerationId = "",
    [string]$ToolName = "",
    $InputValue = ""
  )
  if (-not $SessionId -or -not $BaseUrl) { return }
  if (-not $ToolUseId) { return }
  if ($null -eq $InputValue) { $InputValue = "" }

  $body = [ordered]@{
    Action       = "after_tool_call"
    Platform     = $Script:PnPluginPlatform
    Cwd          = $Cwd
    GitRepoUrl   = $GitRepoUrl
    GitBranch    = $GitBranch
    ToolUseId    = $ToolUseId
    Output       = $Output
    IsError      = $IsError
    GenerationId = $GenerationId
    ToolName     = $ToolName
    Input        = $InputValue
  }
  $post = Invoke-PnPluginPost -BaseUrl $BaseUrl -AccessToken $AccessToken -TimeoutSec $TimeoutSec -SessionId $SessionId -Domain "tool-calls" -Body $body
  $status = $post.Raw.StatusCode
  if ($null -eq $status -or $status -lt 200 -or $status -ge 300) {
    Write-DebugLog -Message "plugins: after_tool_call failed (HTTP $status) session=$SessionId tool_use_id=$ToolUseId" -LogPath $Script:PluginsDebugLogPath
  } else {
    Write-DebugLog -Message "plugins: after_tool_call recorded (session=$SessionId, tool_use_id=$ToolUseId)" -LogPath $Script:PluginsDebugLogPath
  }
}

# ---------------------------------------------------------------------------
# Git-diff file collection for a before_tool_call gating a git push/commit.
# ---------------------------------------------------------------------------

# Get-PnGitDiffFiles -Cwd -GitEventType
# Mirrors pn_build_git_diff_files_json: "git.push" -> unpushed changed
# files, "git.commit" -> staged files. Emits zero or more
# @{ Filename; ContentBase64 } entries; never throws. Callers wrap the call
# in @(...) to always get an array -- these helpers deliberately do not use
# the `return ,$array` trick, which makes @(...) at the call site nest the
# result one level deeper ([[...]]).
function Get-PnGitDiffFiles {
  param([string]$Cwd, [string]$GitEventType)
  $changed = @()
  try {
    switch ($GitEventType) {
      "git.push"   { $changed = @(Get-UnpushedChangedFiles -RepoPath $Cwd) }
      "git.commit" { $changed = @(Get-StagedChangedFiles -RepoPath $Cwd) }
      default      { return }
    }
  } catch {
    return
  }
  return (Get-PnFilesFromList -Cwd $Cwd -RelativePaths $changed -Label $GitEventType)
}

# Get-PnFilesFromPaths -Cwd -RelativePaths
# Mirrors pn_build_files_json_from_paths: for an MCP git-commit tool call,
# whose own tool_input names the files it committed.
function Get-PnFilesFromPaths {
  param([string]$Cwd, [AllowEmptyCollection()][string[]]$RelativePaths = @())
  return (Get-PnFilesFromList -Cwd $Cwd -RelativePaths $RelativePaths -Label "mcp git commit")
}

# Get-PnFilesFromList -Cwd -RelativePaths -Label
# Shared encode/cap body, mirroring _pn_build_files_json_from_list: skips
# binary and missing files, capped by PARADIGM_NETWORKS_GIT_EVENT_MAX_FILES
# (default 60) / _MAX_BYTES (default 8 MB).
function Get-PnFilesFromList {
  param([string]$Cwd, [AllowEmptyCollection()][string[]]$RelativePaths = @(), [string]$Label = "")

  $entries = New-Object System.Collections.Generic.List[object]
  if (-not $Cwd -or $RelativePaths.Count -eq 0) { return }

  $maxFiles = 60
  $maxBytes = [long]8388608
  $parsed = 0
  if ($env:PARADIGM_NETWORKS_GIT_EVENT_MAX_FILES -and [int]::TryParse($env:PARADIGM_NETWORKS_GIT_EVENT_MAX_FILES, [ref]$parsed)) { $maxFiles = $parsed }
  $parsedLong = [long]0
  if ($env:PARADIGM_NETWORKS_GIT_EVENT_MAX_BYTES -and [long]::TryParse($env:PARADIGM_NETWORKS_GIT_EVENT_MAX_BYTES, [ref]$parsedLong)) { $maxBytes = $parsedLong }

  $totalBytes = [long]0
  $capped = $false
  foreach ($rel in $RelativePaths) {
    if (-not $rel) { continue }
    $abs = Join-Path $Cwd $rel
    if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }
    if (Test-BinaryFile -Path $abs) { continue }

    if ($entries.Count -ge $maxFiles) { $capped = $true; continue }
    $size = (Get-Item -LiteralPath $abs).Length
    if ($totalBytes + $size -gt $maxBytes) { $capped = $true; continue }
    $totalBytes += $size

    try {
      $b64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($abs))
    } catch {
      continue
    }
    $entries.Add([ordered]@{ Filename = $rel; ContentBase64 = $b64 })
  }

  if ($capped) {
    Write-DebugLog -Message "git-diff file set for $Label exceeded the $maxFiles-file/$maxBytes-byte guardrail; remaining files were not attached" -LogPath $Script:PluginsDebugLogPath
  }
  return $entries.ToArray()
}
