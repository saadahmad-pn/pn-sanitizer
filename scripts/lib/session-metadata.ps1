# Windows mirror of lib/session-metadata.sh: local session-lifecycle
# metadata, written on sessionStart and removed on sessionEnd. Purely
# local -- nothing here talks to control-server (the session_start/
# session_end API calls it replaces were removed server-side). See
# session-metadata.sh's header for the full rationale.
#
# One file per session: <HOME>\.paradigm-networks\sessions\<session_id>.json

Set-StrictMode -Version Latest

$Script:SessionMetadataDir = Join-Path $HOME ".paradigm-networks\sessions"

# Get-PnSessionMetadataPath -SessionId
# Rejects a session id containing a path separator or a leading dot rather
# than trusting Cursor's conversation_id blind. Returns "" on rejection.
function Get-PnSessionMetadataPath {
  param([string]$SessionId)
  if (-not $SessionId) { return "" }
  if ($SessionId.Contains('/') -or $SessionId.Contains('\') -or $SessionId.StartsWith('.')) { return "" }
  return (Join-Path $Script:SessionMetadataDir "$SessionId.json")
}

# Write-PnSessionMetadata -SessionId -Cwd -GitRepoUrl -GitBranch
# Best-effort and atomic (temp file + move). Never throws.
function Write-PnSessionMetadata {
  param(
    [string]$SessionId,
    [string]$Cwd = "",
    [string]$GitRepoUrl = "",
    [string]$GitBranch = ""
  )
  $path = Get-PnSessionMetadataPath -SessionId $SessionId
  if (-not $path) { return }

  $tempFile = ""
  try {
    if (-not (Test-Path $Script:SessionMetadataDir)) {
      New-Item -ItemType Directory -Path $Script:SessionMetadataDir -Force -ErrorAction Stop | Out-Null
    }
    $metadata = [ordered]@{
      SessionId  = $SessionId
      Cwd        = $Cwd
      GitRepoUrl = $GitRepoUrl
      GitBranch  = $GitBranch
      StartedAt  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    $tempFile = "$path.$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
    Set-Utf8FileTextNoBom -Path $tempFile -Value (ConvertTo-CompactJson ([PSCustomObject]$metadata))
    Move-Item -LiteralPath $tempFile -Destination $path -Force -ErrorAction Stop
  } catch {
    if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
      Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
    return
  }

  Remove-PnStaleSessionMetadata
}

# Remove-PnSessionMetadata -SessionId
# Best-effort cleanup on sessionEnd; a missing file is not an error.
function Remove-PnSessionMetadata {
  param([string]$SessionId)
  $path = Get-PnSessionMetadataPath -SessionId $SessionId
  if (-not $path) { return }
  Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

# Read-PnSessionMetadata -SessionId
# Returns the stored metadata JSON text, or "" if none exists. Not called by
# any hook yet -- see session-metadata.sh's header.
function Read-PnSessionMetadata {
  param([string]$SessionId)
  $path = Get-PnSessionMetadataPath -SessionId $SessionId
  if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return "" }
  return (Get-Utf8FileText -Path $path)
}

# Remove-PnStaleSessionMetadata
# Removes session files older than 24h (a session that never got a matching
# sessionEnd). Never throws.
function Remove-PnStaleSessionMetadata {
  try {
    if (-not (Test-Path $Script:SessionMetadataDir)) { return }
    $cutoff = (Get-Date).AddDays(-1)
    Get-ChildItem -Path $Script:SessionMetadataDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt $cutoff } |
      Remove-Item -Force -ErrorAction SilentlyContinue
  } catch {
  }
}
