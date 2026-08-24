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

# Get-StdinText
# Reads the whole of stdin as UTF-8 text, or "" if there's nothing there.
# Deliberately does NOT gate on [Console]::IsInputRedirected first -- that
# check (and [Console]::In generally) sits on top of Windows console-mode
# detection that has been observed to misreport when PowerShell is
# launched through an intermediate process (cmd.exe -> powershell.exe
# -File, which is exactly how run-powershell.cmd invokes every hook here),
# silently leaving the payload empty and making a real, piped-in JSON
# payload look like invalid input. Reading the raw standard-input stream
# directly, with an explicit encoding, sidesteps both that and a possible
# leading UTF-8 BOM (which ConvertFrom-Json does not tolerate, and which
# some Windows-side JSON writers include) -- stripped below if present.
function Get-StdinText {
  try {
    $stdin = [Console]::OpenStandardInput()
    $reader = New-Object System.IO.StreamReader($stdin, [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
  } catch {
    return ""
  }
  if ($null -eq $text) { return "" }
  if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) {
    $text = $text.Substring(1)
  }
  return $text
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

Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

# Invoke-HttpPostRaw -Url ... -BodyBytes ... -ContentType ... -AuthToken ... -TimeoutSec ...
# A hard-timeout HTTP POST built directly on HttpClient + a
# CancellationToken, instead of Invoke-WebRequest/-RestMethod's -TimeoutSec.
# Observed directly against a real Windows test environment for this
# plugin: -TimeoutSec did not reliably abort a hung request -- the process
# outlived it and had to be killed from outside by Cursor's own, longer,
# hook-level timeout instead, with the actual HTTP call never returning at
# all. CancellationToken.CancelAfter forces the issue: cancelling it aborts
# the underlying socket operation directly, it does not depend on the HTTP
# stack choosing to honor a timeout value the way -TimeoutSec apparently
# doesn't in that environment.
#
# Returns a PSCustomObject with:
#   Body              - response body string, or $null if unreachable/timed out
#   StatusCode        - HTTP status code (int), or $null if unreachable/timed out
#   TimedOut          - $true if the request exceeded TimeoutSec
#   ConnectionFailed  - $true if the request could not connect at all
function Invoke-HttpPostRaw {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][byte[]]$BodyBytes,
    [Parameter(Mandatory = $true)][string]$ContentType,
    [string]$AuthToken = "",
    [int]$TimeoutSec = 5
  )

  $cts = New-Object System.Threading.CancellationTokenSource
  $client = New-Object System.Net.Http.HttpClient
  try {
    $cts.CancelAfter([TimeSpan]::FromSeconds($TimeoutSec))

    # The leading comma matters: without it, PowerShell unrolls the byte
    # array into one constructor argument per byte instead of passing the
    # array itself as the single argument ByteArrayContent(byte[]) expects
    # -- observed directly: "Cannot find an overload ... argument count: 127".
    $content = New-Object System.Net.Http.ByteArrayContent(, $BodyBytes)
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)
    if ($AuthToken) {
      $client.DefaultRequestHeaders.Authorization =
        New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $AuthToken)
    }

    try {
      $response = $client.PostAsync($Url, $content, $cts.Token).GetAwaiter().GetResult()
    } catch {
      # .GetAwaiter().GetResult() rethrows the original exception directly
      # (unlike .Result/.Wait(), which wrap it in an AggregateException),
      # so the cancellation flag is the reliable signal here regardless of
      # exactly which exception type surfaces.
      if ($cts.IsCancellationRequested) {
        return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $true; ConnectionFailed = $false }
      }
      return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $false; ConnectionFailed = $true }
    }

    $bodyText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    return [PSCustomObject]@{
      Body             = $bodyText
      StatusCode       = [int]$response.StatusCode
      TimedOut         = $false
      ConnectionFailed = $false
    }
  } finally {
    $client.Dispose()
    $cts.Dispose()
  }
}

# Invoke-ScanHttpPost -Url ... -TextData ... -AuthToken ... -TimeoutSec ...
# Mirrors http_post_form + http_post_split_status combined into one call:
# sends TextData as a literal multipart/form-data field named "text" (never
# interpreted as a file path, matching curl --form-string's behavior).
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

  return Invoke-HttpPostRaw -Url $Url -BodyBytes $bodyBytes `
    -ContentType "multipart/form-data; boundary=$boundary" `
    -AuthToken $AuthToken -TimeoutSec $TimeoutSec
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
