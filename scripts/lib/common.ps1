# Common utilities for all Paradigm Networks hook scripts (Windows).
# Provides: JSON helpers, HTTP wrappers, logging.
#
# Mirrors scripts/lib/common.sh function-for-function, but does not need a
# jq equivalent at all -- ConvertTo-Json/ConvertFrom-Json are built into the
# language, so there's nothing to bundle or resolve here.
#
# Written against Windows PowerShell 5.1 (the version that ships on every
# Windows machine by default) -- not PowerShell 7+-only syntax or cmdlet
# parameters (e.g. Invoke-WebRequest's -Form, added in 6.1+, is deliberately
# not used below; see Invoke-ScanHttpPost).

Set-StrictMode -Version Latest

function ConvertTo-CompactJson {
  param([Parameter(Mandatory = $true)]$InputObject)
  return ($InputObject | ConvertTo-Json -Compress -Depth 10)
}

# Get-JsonProperty -InputObject $obj -Name "field" -Default "fallback"
# The PowerShell equivalent of jq's `.field // "fallback"`. Every script
# here runs under Set-StrictMode -Version Latest, which throws when code
# touches a property a ConvertFrom-Json object doesn't have -- unlike jq,
# which just treats a missing field as null. Any time an externally-
# supplied JSON payload's shape isn't guaranteed (a hook payload, an API
# response), read it through this instead of a bare .property access.
function Get-JsonProperty {
  param(
    $InputObject,
    [Parameter(Mandatory = $true)][string]$Name,
    $Default = $null
  )
  if ($null -eq $InputObject) { return $Default }
  if ($InputObject.PSObject.Properties.Name -contains $Name) {
    $value = $InputObject.$Name
    if ($null -eq $value) { return $Default }
    return $value
  }
  return $Default
}

# Invoke-ScanHttpPost -Url ... -TextData ... -AuthToken ... -TimeoutSec ...
# Mirrors http_post_form + http_post_split_status combined into one call:
# sends TextData as a literal multipart/form-data field named "text" (never
# interpreted as a file path, matching curl --form-string's behavior) and
# returns an object describing exactly what happened, so callers don't have
# to unpick a curl exit code the way the bash version does.
#
# Deliberately builds the multipart body by hand instead of using
# Invoke-WebRequest's -Form parameter: -Form was added in PowerShell 6.1,
# so relying on it would silently fail on stock Windows PowerShell 5.1,
# which is the actual "nothing extra to install" baseline this is written
# against.
#
# Returns a PSCustomObject with:
#   Body              - response body string, or $null if unreachable/timed out
#   StatusCode        - HTTP status code (int), or $null if unreachable/timed out
#   TimedOut          - $true if the request exceeded TimeoutSec
#   ConnectionFailed  - $true if the request could not connect at all
function Invoke-ScanHttpPost {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$TextData,
    [string]$AuthToken = "",
    [int]$TimeoutSec = 5
  )

  $boundary = [System.Guid]::NewGuid().ToString()
  $bodyLines = @(
    "--$boundary",
    'Content-Disposition: form-data; name="text"',
    "",
    $TextData,
    "--$boundary--",
    ""
  )
  $bodyString = $bodyLines -join "`r`n"
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyString)

  $headers = @{}
  if ($AuthToken) {
    $headers["Authorization"] = "Bearer $AuthToken"
  }

  try {
    $response = Invoke-WebRequest -Uri $Url -Method Post `
      -ContentType "multipart/form-data; boundary=$boundary" `
      -Headers $headers -Body $bodyBytes -TimeoutSec $TimeoutSec `
      -UseBasicParsing -ErrorAction Stop

    return [PSCustomObject]@{
      Body             = $response.Content
      StatusCode       = [int]$response.StatusCode
      TimedOut         = $false
      ConnectionFailed = $false
    }
  } catch [System.Net.WebException] {
    $webEx = $_.Exception
    if ($webEx.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
      return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $true; ConnectionFailed = $false }
    }
    if ($webEx.Response) {
      # A real HTTP response came back, just with a non-2xx status --
      # read it the same way curl would, rather than treating it as
      # unreachable.
      $stream = $webEx.Response.GetResponseStream()
      $reader = New-Object System.IO.StreamReader($stream)
      $body = $reader.ReadToEnd()
      $reader.Close()
      return [PSCustomObject]@{
        Body             = $body
        StatusCode       = [int]$webEx.Response.StatusCode
        TimedOut         = $false
        ConnectionFailed = $false
      }
    }
    return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $false; ConnectionFailed = $true }
  } catch {
    # Anything else (DNS failure, TLS error, etc.) -- treat the same as
    # "unreachable" rather than letting the script crash.
    return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $false; ConnectionFailed = $true }
  }
}

# Write-DebugLog -Message ... -LogPath ...
function Write-DebugLog {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [string]$LogPath = ""
  )
  if (-not $LogPath) { return }

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
  try {
    $dir = Split-Path -Parent $LogPath
    if ($dir -and -not (Test-Path $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Add-Content -Path $LogPath -Value "[$timestamp] $Message" -Encoding UTF8
  } catch {
    # Logging must never be the reason a hook fails.
  }
}

# Write-AuditLog -Entry <hashtable/PSCustomObject> -LogPath ...
# Adds a timestamp field and appends one JSON line, mirroring audit_log in
# common.sh.
function Write-AuditLog {
  param(
    [Parameter(Mandatory = $true)]$Entry,
    [string]$LogPath = ""
  )
  if (-not $LogPath) { return }

  try {
    $dir = Split-Path -Parent $LogPath
    if ($dir -and -not (Test-Path $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $withTimestamp = $Entry | Select-Object *, @{ Name = "timestamp"; Expression = { $timestamp } }
    Add-Content -Path $LogPath -Value (ConvertTo-CompactJson $withTimestamp) -Encoding UTF8
  } catch {
    # Audit logging must never be the reason a hook fails.
  }
}

# Get-FileTail -Path ... -MaxBytes ...
# Mirrors file_read_tail: returns the whole file if it's small, otherwise
# just the last MaxBytes bytes, read directly from the end of the file
# rather than loading the whole thing into memory first.
function Get-FileTail {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$MaxBytes = 4000
  )
  if (-not (Test-Path $Path -PathType Leaf)) {
    return ""
  }

  $fileInfo = Get-Item $Path
  if ($fileInfo.Length -le $MaxBytes) {
    return (Get-Content -Path $Path -Raw -Encoding UTF8)
  }

  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $stream.Seek(-$MaxBytes, [System.IO.SeekOrigin]::End) | Out-Null
    $buffer = New-Object byte[] $MaxBytes
    $stream.Read($buffer, 0, $MaxBytes) | Out-Null
    return [System.Text.Encoding]::UTF8.GetString($buffer)
  } finally {
    $stream.Close()
  }
}

function Test-CommandExists {
  param([Parameter(Mandatory = $true)][string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# --- Hook response helpers (for beforeSubmitPrompt / preToolUse) ---

function Write-JsonAllow {
  param([string]$Message = "")
  if (-not $Message) {
    Write-Output (ConvertTo-CompactJson @{ continue = $true })
  } else {
    Write-Output (ConvertTo-CompactJson @{ continue = $true; user_message = $Message })
  }
}

function Write-JsonDeny {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Output (ConvertTo-CompactJson @{ continue = $false; user_message = $Message })
}

function Write-JsonPermissionAllow {
  param([string]$Message = "")
  if (-not $Message) {
    Write-Output (ConvertTo-CompactJson @{ permission = "allow" })
  } else {
    Write-Output (ConvertTo-CompactJson @{ permission = "allow"; user_message = $Message })
  }
}

function Write-JsonPermissionDeny {
  param(
    [Parameter(Mandatory = $true)][string]$UserMessage,
    [string]$AgentMessage = ""
  )
  if (-not $AgentMessage) {
    Write-Output (ConvertTo-CompactJson @{ permission = "deny"; user_message = $UserMessage })
  } else {
    Write-Output (ConvertTo-CompactJson @{ permission = "deny"; user_message = $UserMessage; agent_message = $AgentMessage })
  }
}

function Write-JsonSessionContext {
  param([Parameter(Mandatory = $true)][string]$Context)
  Write-Output (ConvertTo-CompactJson @{ additional_context = $Context })
}
