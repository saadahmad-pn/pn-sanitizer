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

# Windows PowerShell 5.1 defaults stdout to the legacy console codepage, not
# UTF-8 -- any multi-byte character (emoji, non-ASCII text from a server
# response) written past this point gets its bytes reinterpreted under that
# codepage and comes out as mojibake, even though plain ASCII text in the
# same string is unaffected (ASCII bytes are identical across codepages).
# Forcing this here, in the file every hook script dot-sources first,
# covers all of them against any future non-ASCII content, not just one
# literal character in one message. Best-effort: some hosts (e.g. no real
# console attached) throw setting this, and it's not worth failing a hook
# over.
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
}

function ConvertTo-CompactJson {
  param([Parameter(Mandatory = $true)]$InputObject)
  return ($InputObject | ConvertTo-Json -Compress -Depth 10)
}

# Get-Utf8FileText -Path ...
# Reads a file as UTF-8 text with any leading byte-order-mark stripped.
# Windows PowerShell 5.1's Set-Content -Encoding UTF8 always writes a
# UTF-8 BOM (unlike PowerShell 7, which defaults to no BOM) -- observed
# directly against a real Windows target: Get-Content -Encoding UTF8 does
# not reliably strip it back out on that runtime, leaving an invisible
# character before the real content. For a JSON file (credentials.json)
# that made ConvertFrom-Json fail silently on a file that looked completely
# normal when opened and read visually. Read every one of this plugin's
# own files through this instead of a bare Get-Content -Raw.
function Get-Utf8FileText {
  param([Parameter(Mandatory = $true)][string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    if ($bytes.Length -gt 3) {
      $bytes = $bytes[3..($bytes.Length - 1)]
    } else {
      $bytes = @()
    }
  }
  return [System.Text.Encoding]::UTF8.GetString($bytes)
}

# Set-Utf8FileTextNoBom -Path ... -Value ...
# Writes text as UTF-8 with no byte-order-mark, unlike Set-Content
# -Encoding UTF8 on Windows PowerShell 5.1 (which always includes one).
# Stops new BOMs from ever being written, rather than just compensating
# for them on read -- pairs with Get-Utf8FileText above, which still
# tolerates a BOM for files saved before this fix.
function Set-Utf8FileTextNoBom {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
  )
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Value, $utf8NoBom)
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
    # CancelAfter is kept as a best-effort signal, but it is NOT what
    # actually enforces the timeout below -- observed directly against a
    # real Windows PowerShell 5.1 target: a request configured with a 10s
    # timeout ran for ~22s anyway. Windows PowerShell 5.1's HttpClient
    # sits on older machinery than PowerShell 7's and does not reliably
    # honor cancellation the way it does on modern .NET (verified working
    # correctly there in this plugin's own testing). The actual guarantee
    # here comes from Task.Wait(timeout) below: it returns false on timeout
    # without throwing, and without waiting any longer, regardless of
    # whether the underlying request ever actually stops -- an abandoned
    # task left running in the background is fine, since this process
    # prints its result and exits shortly after either way.
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

    $postTask = $client.PostAsync($Url, $content, $cts.Token)
    # Task.Wait(timeout) returns false on a pure timeout (our own wait
    # gave up, the task may still be running) -- but if the task itself
    # transitions to Faulted/Canceled *within* that same window, Wait()
    # throws instead of returning normally. Both outcomes are handled here.
    try {
      $completedInTime = $postTask.Wait([TimeSpan]::FromSeconds($TimeoutSec))
    } catch {
      return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $false; ConnectionFailed = $true }
    }
    if (-not $completedInTime) {
      return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $true; ConnectionFailed = $false }
    }
    if ($postTask.IsFaulted) {
      return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $false; ConnectionFailed = $true }
    }

    $response = $postTask.Result
    $readTask = $response.Content.ReadAsStringAsync()
    try {
      $readCompletedInTime = $readTask.Wait([TimeSpan]::FromSeconds($TimeoutSec))
    } catch {
      return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $false; ConnectionFailed = $true }
    }
    if (-not $readCompletedInTime) {
      return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $true; ConnectionFailed = $false }
    }

    return [PSCustomObject]@{
      Body             = $readTask.Result
      StatusCode       = [int]$response.StatusCode
      TimedOut         = $false
      ConnectionFailed = $false
    }
  } finally {
    $client.Dispose()
    $cts.Dispose()
  }
}

# Invoke-HttpGetRaw -Url ... -AuthToken ... -TimeoutSec ...
# Same hard-timeout design as Invoke-HttpPostRaw above (Task.Wait-based, not
# CancelAfter alone -- see that function's comment for why), for GET
# requests -- used for GET /v1/models.
function Invoke-HttpGetRaw {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$AuthToken = "",
    [int]$TimeoutSec = 5
  )

  $cts = New-Object System.Threading.CancellationTokenSource
  $client = New-Object System.Net.Http.HttpClient
  try {
    $cts.CancelAfter([TimeSpan]::FromSeconds($TimeoutSec))
    if ($AuthToken) {
      $client.DefaultRequestHeaders.Authorization =
        New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $AuthToken)
    }

    $getTask = $client.GetAsync($Url, $cts.Token)
    try {
      $completedInTime = $getTask.Wait([TimeSpan]::FromSeconds($TimeoutSec))
    } catch {
      return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $false; ConnectionFailed = $true }
    }
    if (-not $completedInTime) {
      return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $true; ConnectionFailed = $false }
    }
    if ($getTask.IsFaulted) {
      return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $false; ConnectionFailed = $true }
    }

    $response = $getTask.Result
    $readTask = $response.Content.ReadAsStringAsync()
    try {
      $readCompletedInTime = $readTask.Wait([TimeSpan]::FromSeconds($TimeoutSec))
    } catch {
      return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $false; ConnectionFailed = $true }
    }
    if (-not $readCompletedInTime) {
      return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $true; ConnectionFailed = $false }
    }

    return [PSCustomObject]@{
      Body             = $readTask.Result
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

# Invoke-MessagesHttpPost -Url ... -TextData ... -Model ... -MaxTokens ... -AuthToken ... -TimeoutSec ...
# Same pairing pattern as Invoke-ScanHttpPost above, but for the Anthropic-
# compatible /v1/messages endpoint: builds a proper JSON request body via
# ConvertTo-Json (not hand-built string interpolation -- TextData can
# contain quotes/backslashes/newlines that must be escaped correctly) and
# posts it through the same generic Invoke-HttpPostRaw.
function Invoke-MessagesHttpPost {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$TextData,
    [Parameter(Mandatory = $true)][string]$Model,
    [int]$MaxTokens = 150,
    [string]$AuthToken = "",
    [int]$TimeoutSec = 5
  )

  $requestBody = [PSCustomObject]@{
    model      = $Model
    max_tokens = $MaxTokens
    stream     = $false
    messages   = @(
      [PSCustomObject]@{ role = "user"; content = $TextData }
    )
  }
  # -Depth 5 matters: the default depth (2) would silently truncate the
  # nested messages[0] object down to its string representation instead of
  # a real JSON object.
  $bodyJson = $requestBody | ConvertTo-Json -Depth 5 -Compress
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)

  return Invoke-HttpPostRaw -Url $Url -BodyBytes $bodyBytes `
    -ContentType "application/json" `
    -AuthToken $AuthToken -TimeoutSec $TimeoutSec
}

# ConvertFrom-PnMessagesResponse -ResponseBody ...
# Mirrors pn_parse_messages_response (common.sh) exactly -- see that
# function's comment for the full detection-rule rationale (why zero usage
# alone is treated as "anomaly" rather than guessed as allow/block, why
# content[] is scanned by type instead of indexed at [0], etc).
# Returns [PSCustomObject]@{ Action = "allow"|"block"|"anomaly"; Message = "..." }
# (block: the extracted block reason; allow: the backend's actual reply
# text, in full; anomaly: a truncated raw preview.)
#
# This whole function is a stopgap, not a permanent design (P2-1) --
# mirrors pn_parse_messages_response in common.sh, see that function's
# comment for the full rationale. The real fix is a backend change (an
# explicit verdict field or response header); Add-PnScanAnomaly /
# Reset-PnScanAnomaly (below) are a mitigation for the silent-failure
# risk in the meantime, not a fix for the underlying fragility.
function ConvertFrom-PnMessagesResponse {
  param(
    [Parameter(Mandatory = $true)][string]$ResponseBody
  )

  $result = [PSCustomObject]@{ Action = "allow"; Message = "" }

  $parsed = $null
  try {
    $parsed = $ResponseBody | ConvertFrom-Json -ErrorAction Stop
  } catch {
    $result.Action = "anomaly"
    return $result
  }

  $usage = Get-JsonProperty -InputObject $parsed -Name "usage" -Default $null
  $inputTokens = $null
  $outputTokens = $null
  if ($usage) {
    $inputTokens = Get-JsonProperty -InputObject $usage -Name "input_tokens" -Default $null
    $outputTokens = Get-JsonProperty -InputObject $usage -Name "output_tokens" -Default $null
  }

  # @(...) matters: Get-JsonProperty returning a single content block would
  # otherwise unwrap to a bare object instead of a one-element array, and
  # the foreach below would iterate its properties instead of the block.
  $contentBlocks = @(Get-JsonProperty -InputObject $parsed -Name "content" -Default @())
  $textBlock = $null
  foreach ($block in $contentBlocks) {
    $blockType = Get-JsonProperty -InputObject $block -Name "type" -Default ""
    if ($blockType -eq "text") {
      $textBlock = Get-JsonProperty -InputObject $block -Name "text" -Default ""
      break
    }
  }

  if ($null -eq $inputTokens -or $null -eq $outputTokens -or $null -eq $textBlock) {
    $result.Action = "anomaly"
    # Best-effort: a missing text block means there's nothing to preview,
    # but missing/malformed usage numbers can still come with real text
    # content worth showing.
    if ($textBlock) {
      $result.Message = ConvertTo-PnPreviewText -Text $textBlock
    }
    return $result
  }

  if ([int]$inputTokens -eq 0 -and [int]$outputTokens -eq 0) {
    if ($textBlock -like "*REQUEST BLOCKED*") {
      $result.Action = "block"
      $result.Message = ConvertTo-PnStrippedBlockBanner -Text $textBlock
    } else {
      $result.Action = "anomaly"
      # Unlike a block, there's no known scaffolding to strip here -- an
      # anomaly is by definition a shape we don't recognize. A raw,
      # truncated preview at least tells the caller what the backend
      # actually said, instead of a canned "unexpected response" sentence
      # that reveals nothing about what actually happened.
      $result.Message = ConvertTo-PnPreviewText -Text $textBlock
    }
  } else {
    # Real allow (non-zero usage): the backend is also a coding assistant,
    # not just a scanner -- on this path its reply can be genuinely useful
    # content (e.g. working code plus an explanation), not throwaway
    # filler. Surfaced in full, not truncated via ConvertTo-PnPreviewText,
    # the same way the block banner's own explanation is used verbatim
    # rather than clipped -- clipping a real, useful answer would defeat
    # the point of surfacing it at all.
    $result.Message = $textBlock
  }

  return $result
}

# ConvertTo-PnPreviewText <raw_text> [-MaxChars 200]
# Collapses whitespace/newlines to single spaces and truncates, for
# surfacing a raw, unrecognized response as a one-line diagnostic
# snippet. Not validated or trusted content -- shown so a human can see
# what the backend actually returned, nothing more structured than that.
function ConvertTo-PnPreviewText {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [int]$MaxChars = 200
  )
  $collapsed = (($Text -replace '[\r\n\t]+', ' ') -replace ' {2,}', ' ').Trim()
  if ($collapsed.Length -gt $MaxChars) {
    return $collapsed.Substring(0, $MaxChars) + "..."
  }
  return $collapsed
}

# ConvertTo-PnStrippedBlockBanner <raw_block_banner_text>
# Mirrors pn_strip_block_banner in common.sh -- see that function's
# comment for the full rationale: the block banner has one confirmed-
# fixed part (the "====" divider lines, the "REQUEST BLOCKED" line, and
# the wrapping ``` code fence) and one part that varies and cannot be
# predicted (the actual explanation -- observed as both a short phrase
# and a long, multi-finding structured report). Stripping only the
# confirmed-fixed scaffolding and keeping whatever's left works
# regardless of which shape the backend sends.
function ConvertTo-PnStrippedBlockBanner {
  param([Parameter(Mandatory = $true)][string]$Text)

  $lines = @($Text -split '\r?\n' | Where-Object {
    $_ -notmatch '^```' -and
    $_ -notmatch '^[ \t]*=+[ \t]*$' -and
    $_ -notmatch '^[ \t]*REQUEST BLOCKED[ \t]*$'
  })

  $startIndex = 0
  while ($startIndex -lt $lines.Count -and $lines[$startIndex] -match '^[ \t]*$') { $startIndex++ }
  $endIndex = $lines.Count - 1
  while ($endIndex -ge $startIndex -and $lines[$endIndex] -match '^[ \t]*$') { $endIndex-- }

  if ($startIndex -gt $endIndex) { return "" }
  return ($lines[$startIndex..$endIndex] -join "`n")
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
      New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    # -ErrorAction Stop matters here, not just style: with
    # $ErrorActionPreference = "Continue" set by every caller of this
    # function, Add-Content's own errors are non-terminating by default,
    # and a plain try/catch does not intercept non-terminating errors --
    # they would otherwise leak straight through to Cursor's error output
    # instead of being swallowed the way this function promises. Observed
    # directly: a transient "Stream was not readable" (most likely an AV
    # product briefly locking the file) leaked through exactly this way.
    Add-Content -Path $LogPath -Value "[$timestamp] $Message" -Encoding UTF8 -ErrorAction Stop
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
      New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $withTimestamp = $Entry | Select-Object *, @{ Name = "timestamp"; Expression = { $timestamp } }
    # -ErrorAction Stop matters here, not just style -- see the identical
    # note in Write-DebugLog above: without it, a non-terminating
    # Add-Content error is not actually caught by this try/catch under
    # $ErrorActionPreference = "Continue", and leaks through instead of
    # being swallowed the way this function promises.
    Add-Content -Path $LogPath -Value (ConvertTo-CompactJson $withTimestamp) -Encoding UTF8 -ErrorAction Stop
  } catch {
    # Audit logging must never be the reason a hook fails.
  }
}

# Anomaly-streak tracking. Mirrors pn_record_scan_anomaly/
# pn_reset_scan_anomaly in common.sh -- see that comment for the full
# rationale: ConvertFrom-PnMessagesResponse's block/allow verdict is a
# reverse-engineered heuristic with no real structured field from the
# backend yet, so a silent, complete loss of enforcement (every scan
# landing on "anomaly") needs a loud signal past a threshold instead of
# staying invisible. Scoped narrowly to that classification, not
# transport-level failures, same as the bash side.
$Script:PnAnomalyStatePath = Join-Path $HOME ".paradigm-scanner\anomaly_state.json"
$Script:PnAnomalyWarningThreshold = 3

function Add-PnScanAnomaly {
  $count = 0
  if (Test-Path $Script:PnAnomalyStatePath -PathType Leaf) {
    try {
      $existing = Get-Content -Path $Script:PnAnomalyStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      $existingCount = Get-JsonProperty -InputObject $existing -Name "consecutive_anomaly_count" -Default 0
      if ($existingCount -match '^\d+$') { $count = [int]$existingCount }
    } catch {
      $count = 0
    }
  }
  $count++

  # Best-effort persistence, same posture as Write-DebugLog/Write-AuditLog
  # above: if this fails, the count returned for this one call is still
  # correct, it just won't be remembered for the next invocation.
  try {
    $dir = Split-Path -Parent $Script:PnAnomalyStatePath
    if ($dir -and -not (Test-Path $dir)) {
      New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $tempFile = "$($Script:PnAnomalyStatePath).$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
    (ConvertTo-CompactJson @{ consecutive_anomaly_count = $count }) | Set-Content -Path $tempFile -Encoding UTF8 -ErrorAction Stop
    Move-Item -Path $tempFile -Destination $Script:PnAnomalyStatePath -Force -ErrorAction Stop
  } catch {
    # Non-fatal -- see comment above.
  }

  return $count
}

function Reset-PnScanAnomaly {
  Remove-Item -Path $Script:PnAnomalyStatePath -Force -ErrorAction SilentlyContinue
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
    return (Get-Utf8FileText -Path $Path)
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

# Extracts the text of the current conversation turn from a Cursor
# transcript.jsonl -- everything from the most recent user message to the
# end of the file (the assistant's own turn-in-progress). Scoped this way
# rather than a raw byte-count tail (Get-FileTail above): a byte cut can
# straddle multiple unrelated previous turns and drag stale context into an
# unrelated write's scan (confirmed directly as the cause of a false
# positive -- a trivial follow-up write inherited a flagged verdict from
# leftover text in an earlier, unrelated request). Each transcript line is
# either {"role": "user"|"assistant", "message": {"content": [...]}} or a
# turn-status marker with no "role" at all; finding the last "user" line
# gives an exact turn boundary instead of guessing one.
# Bounded to the last MaxLines lines first (before parsing) so a
# pathologically large transcript can't make this expensive; a single turn
# is never remotely close to that many lines in practice.
function Get-CurrentTurnText {
  param(
    [Parameter(Mandatory = $true)][string]$TranscriptPath,
    [int]$MaxLines = 500
  )
  if (-not (Test-Path $TranscriptPath -PathType Leaf)) {
    return ""
  }

  try {
    $lines = @(Get-Content -Path $TranscriptPath -Tail $MaxLines -ErrorAction Stop)
  } catch {
    return ""
  }

  $parsed = New-Object System.Collections.Generic.List[object]
  foreach ($line in $lines) {
    if (-not $line) { continue }
    try {
      $parsed.Add(($line | ConvertFrom-Json -ErrorAction Stop))
    } catch {
      # Skip a malformed/partial line -- e.g. the last line while Cursor
      # is still actively appending to this file.
    }
  }
  if ($parsed.Count -eq 0) {
    return ""
  }

  $startIndex = 0
  for ($i = $parsed.Count - 1; $i -ge 0; $i--) {
    $role = Get-JsonProperty -InputObject $parsed[$i] -Name "role" -Default ""
    if ($role -eq "user") {
      $startIndex = $i
      break
    }
  }

  $textParts = New-Object System.Collections.Generic.List[string]
  for ($i = $startIndex; $i -lt $parsed.Count; $i++) {
    $message = Get-JsonProperty -InputObject $parsed[$i] -Name "message" -Default $null
    if ($null -eq $message) { continue }
    # @(...) matters here the same way it has elsewhere in this codebase:
    # a message with exactly one content block would otherwise unwrap to a
    # bare object instead of a one-element array, and the foreach below
    # would iterate its properties instead of the (single) block itself.
    $content = @(Get-JsonProperty -InputObject $message -Name "content" -Default @())
    foreach ($block in $content) {
      $blockType = Get-JsonProperty -InputObject $block -Name "type" -Default ""
      if ($blockType -eq "text") {
        $text = Get-JsonProperty -InputObject $block -Name "text" -Default ""
        if ($text) { $textParts.Add($text) }
      }
    }
  }
  return ($textParts -join "`n`n")
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
