# beforeReadFile hook (Windows): detect when a Cursor Agent Skill is loaded,
# and report it to control-server -- not every file read. Mirrors
# scripts/check-skill-usage.sh; see that file's header for the full design
# rationale (why beforeReadFile is the event, why the file content is sent,
# and why this never blocks).
#
# Until this file existed the hook was wired in hooks.json as a bare
# `bash ./scripts/check-skill-usage.sh`, so on Windows -- where every other
# hook dispatches through scripts/run-hook.cmd -- skill uses were never
# detected at all.

Set-StrictMode -Version Latest
# "Continue", not "Stop": this hook only observes, and a hiccup reading one
# payload must never turn into a terminating error. The allow response below
# is printed on every path regardless.
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$LogPath = Join-Path $HOME ".paradigm-scanner\skill-usage.jsonl"

# Identifies this plugin to the backend's vendor-classification engine --
# same value every other hook here sends.
$PnClientId = "cursor"
# Detached, so this only bounds a stuck background curl.
$TimeoutSeconds = 30
if ($env:PARADIGM_NETWORKS_SKILL_TIMEOUT) {
  $parsed = 0
  if ([int]::TryParse($env:PARADIGM_NETWORKS_SKILL_TIMEOUT, [ref]$parsed) -and $parsed -gt 0) {
    $TimeoutSeconds = $parsed
  }
}

function Write-AllowAndExit {
  Write-Output '{"permission": "allow"}'
  exit 0
}

# Get-Sha256OfFile: the digest control-server matches against the published
# SKILL.md. Returns "" when the file cannot be read -- that downgrades the
# report to "unmatched" rather than dropping it, since the server re-hashes
# the content it receives anyway.
function Get-Sha256OfFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
  } catch {
    return ""
  }
}

$payload = Get-StdinText
if (-not $payload) { Write-AllowAndExit }

try {
  $hook = $payload | ConvertFrom-Json -ErrorAction Stop
} catch {
  Write-AllowAndExit
}

$filePath = Get-JsonProperty -InputObject $hook -Name "file_path" -Default ""
if (-not $filePath) { Write-AllowAndExit }

# Both separators, because a hook payload on Windows can carry either
# depending on how the skill directory was resolved.
$normalized = $filePath -replace '\\', '/'
if ($normalized -notmatch '/skills/([^/]+)/SKILL\.md$') { Write-AllowAndExit }
$skillName = $Matches[1]

# The local trail is kept even when the POST below cannot run (not signed
# in, no network): it is the only record a developer working offline has of
# which skills ran.
try {
  $logDir = Split-Path -Parent $LogPath
  if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
  }
  $entry = [PSCustomObject]@{
    received_at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    skill_name  = $skillName
    file_path   = $filePath
  } | ConvertTo-Json -Compress
  Add-Content -Path $LogPath -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
} catch {
  # A log write failure must never cost the report below.
}

if (-not (Test-PnConfigured)) { Write-AllowAndExit }

# session_id/conversation_id are the same value in practice; generation_id
# changes per user turn and is what control-server merges this use onto the
# right turn with. Without a session id there is no turn to attach to.
$sessionId = Get-JsonProperty -InputObject $hook -Name "session_id" -Default ""
if (-not $sessionId) {
  $sessionId = Get-JsonProperty -InputObject $hook -Name "conversation_id" -Default ""
}
if (-not $sessionId) { Write-AllowAndExit }
$generationId = Get-JsonProperty -InputObject $hook -Name "generation_id" -Default ""

# The payload carries the file's full content. Falling back to reading it off
# disk keeps this working if a future Cursor version drops the field.
$content = Get-JsonProperty -InputObject $hook -Name "content" -Default ""
if (-not $content) {
  try {
    $content = Get-Utf8FileText -Path $filePath
  } catch {
    $content = ""
  }
}
$contentSha = Get-Sha256OfFile -Path $filePath

$config = Resolve-PnConfig
if (-not $config -or -not $config.BaseUrl -or -not $config.AccessToken) { Write-AllowAndExit }

$encodedSession = [System.Uri]::EscapeDataString($sessionId)
$skillUrl = "$($config.BaseUrl.TrimEnd('/'))/api/v1/plugins/sessions/$encodedSession/skill-uses"

$body = [PSCustomObject]@{
  Platform      = "cursor"
  GenerationId  = $generationId
  SkillName     = $skillName
  FilePath      = $filePath
  Content       = $content
  ContentSha256 = $contentSha
  Cwd           = (Get-Location).Path
} | ConvertTo-Json -Depth 5 -Compress
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

# DETACHED, like the bash version and report-tool.sh -- Cursor waits for a
# hook to return, and nothing here reads the reply. Start-Job is the
# PowerShell equivalent of backgrounding a subshell; its own failure is
# swallowed because a report that cannot be sent must not surface to the
# developer as a hook error.
try {
  $null = Start-Job -ScriptBlock {
    param($ScriptDir, $Url, $BodyBytes, $Token, $Timeout, $SessionId, $ClientId)
    . (Join-Path $ScriptDir "lib\common.ps1")
    $headers = @{ "X-Claude-Code-Session-Id" = $SessionId; "X-Paradigm-Client" = $ClientId }
    Invoke-HttpPostRaw -Url $Url -BodyBytes $BodyBytes -ContentType "application/json" `
      -AuthToken $Token -TimeoutSec $Timeout -ExtraHeaders $headers | Out-Null
  } -ArgumentList $ScriptDir, $skillUrl, $bodyBytes, $config.AccessToken, $TimeoutSeconds, $sessionId, $PnClientId
} catch {
  # Nothing to do -- the use is still in the local trail above.
}

Write-AllowAndExit
