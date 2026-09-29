# beforeReadFile hook (Windows): report that an Agent Skill was loaded.
# Mirrors scripts/check-skill-usage.sh -- see that file's header for the full
# rationale (why beforeReadFile is the event, why the file on disk is the
# source rather than the payload, and why this never blocks).
#
# SELF-CONTAINED ON PURPOSE. The bash side posts through
# lib/plugins-client.sh; there is no PowerShell equivalent of that client on
# this branch (no check-tool-call.ps1 either -- the whole plugins API is
# bash-only on Windows today), so this posts directly rather than inventing
# half a client for one caller. If a plugins-client.ps1 ever lands, this
# should move onto it.
#
# It exists at all because run-hook.cmd dispatches to <name>.ps1: registering
# beforeReadFile with no .ps1 present would spawn a failing PowerShell on
# EVERY file read on Windows.

Set-StrictMode -Version Latest
# "Continue", not "Stop": this hook only observes, and a hiccup reading one
# payload must never become a terminating error. The allow response is
# printed on every path regardless.
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$DebugLogPath = Join-Path $HOME ".paradigm-scanner\check-skill-usage.log"

# Identifies this plugin to the backend's vendor-classification engine, and
# matches PN_PLUGIN_PLATFORM in lib/plugins-client.sh.
$PnPlatform = "cursor-plugin"
$PnClientId = "cursor"
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

# Get-Sha256OfString: hashes the EXACT STRING being sent, never the file as a
# separate read -- the two can differ, and the server rejects the call with a
# 400 when they do.
function Get-Sha256OfString {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
      return [System.BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
    } finally {
      $sha.Dispose()
    }
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

# The same path test lib/skill-detection.sh applies on the bash side. Both
# separators, because a Windows payload can carry either.
# The optional "-cursor" suffix is not cosmetic: Cursor keeps its OWN
# built-in skills in skills-cursor/, so an exact "/skills/" test misses every
# one of them. Kept identical to the bash regex in lib/skill-detection.sh.
$normalized = $filePath -replace '\\', '/'
if ($normalized -notmatch '/skills(-[^/]+)?/([^/]+)/SKILL\.md$') { Write-AllowAndExit }
$skillName = $Matches[2]

# Logged even when we cannot report: from the outside a hook that never
# delivers looks exactly like a working one.
if (-not (Test-PnConfigured)) {
  Write-DebugLog "Skill use NOT reported | skill=$skillName | not signed in" $DebugLogPath
  Write-AllowAndExit
}

$sessionId = Get-JsonProperty -InputObject $hook -Name "session_id" -Default ""
if (-not $sessionId) {
  $sessionId = Get-JsonProperty -InputObject $hook -Name "conversation_id" -Default ""
}
if (-not $sessionId) {
  Write-DebugLog "Skill use NOT reported | skill=$skillName | no session_id in payload" $DebugLogPath
  Write-AllowAndExit
}
$generationId = Get-JsonProperty -InputObject $hook -Name "generation_id" -Default ""

# THE FILE ON DISK IS THE SOURCE, NOT THE PAYLOAD -- Cursor chunks a large
# file across several beforeReadFile events, each carrying only its own
# piece. Hashing a fragment means a large skill can never match the registry,
# and one load files several uses. See the bash twin for the measurement.
$content = ""
try {
  $content = Get-Utf8FileText -Path $filePath
} catch {
  $content = ""
}
if (-not $content) {
  Write-DebugLog "Skill use reported WITHOUT content | skill=$skillName | unreadable: $filePath" $DebugLogPath
}

$contentSha = ""
if ($content) {
  $contentSha = Get-Sha256OfString -Value $content
}

$config = Resolve-PnConfig
if (-not $config -or -not $config.BaseUrl -or -not $config.AccessToken) {
  Write-DebugLog "Skill use NOT reported | skill=$skillName | could not resolve config" $DebugLogPath
  Write-AllowAndExit
}

$cwd = Get-JsonProperty -InputObject $hook -Name "cwd" -Default ""
if (-not $cwd) {
  $roots = Get-JsonProperty -InputObject $hook -Name "workspace_roots" -Default @()
  if ($roots -and $roots.Count -gt 0) { $cwd = $roots[0] }
}

$encodedSession = [System.Uri]::EscapeDataString($sessionId)
$skillUrl = "$($config.BaseUrl.TrimEnd('/'))/api/v1/plugins/sessions/$encodedSession/skill-uses"

$body = [PSCustomObject]@{
  Platform      = $PnPlatform
  GenerationId  = $generationId
  SkillName     = $skillName
  FilePath      = $filePath
  Content       = $content
  ContentSha256 = $contentSha
  Cwd           = $cwd
} | ConvertTo-Json -Depth 5 -Compress
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

Write-DebugLog "Reporting skill use | skill=$skillName | sha=$($contentSha.Substring(0, [Math]::Min(8, $contentSha.Length))) | bytes=$($content.Length) | session=$sessionId gen=$generationId" $DebugLogPath

# DETACHED, like the bash twin -- Cursor waits for a hook to return, and
# nothing here acts on the reply. The outcome is still logged: nothing acting
# on a failure is not a reason to be unable to see one.
try {
  $null = Start-Job -ScriptBlock {
    param($ScriptDir, $Url, $BodyBytes, $Token, $Timeout, $SessionId, $ClientId, $SkillName, $LogPath)
    . (Join-Path $ScriptDir "lib\common.ps1")
    $headers = @{ "X-Claude-Code-Session-Id" = $SessionId; "X-Paradigm-Client" = $ClientId }
    $result = Invoke-HttpPostRaw -Url $Url -BodyBytes $BodyBytes -ContentType "application/json" `
      -AuthToken $Token -TimeoutSec $Timeout -ExtraHeaders $headers
    if ($result.TimedOut) {
      Write-DebugLog "Skill use NOT reported | skill=$SkillName | timed out" $LogPath
    } elseif ($result.ConnectionFailed) {
      Write-DebugLog "Skill use NOT reported | skill=$SkillName | connection failed" $LogPath
    } elseif ("$($result.StatusCode)" -notmatch '^2') {
      # The body, not just the status: a 403 means the route is missing from
      # the backend's permission catalog and a 400 means the digest and the
      # body disagree -- both say so in the message.
      Write-DebugLog "Skill use REJECTED | skill=$SkillName | HTTP $($result.StatusCode) | $($result.Body)" $LogPath
    } else {
      Write-DebugLog "Skill use reported | skill=$SkillName | HTTP $($result.StatusCode) | $($result.Body)" $LogPath
    }
  } -ArgumentList $ScriptDir, $skillUrl, $bodyBytes, $config.AccessToken, $TimeoutSeconds, $sessionId, $PnClientId, $skillName, $DebugLogPath
} catch {
  Write-DebugLog "Skill use NOT reported | skill=$skillName | could not start background job" $DebugLogPath
}

Write-AllowAndExit
