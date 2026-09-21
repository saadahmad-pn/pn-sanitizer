# Common utilities for all Paradigm Networks hook scripts (Windows).
# Provides: JSON helpers, HTTP wrappers, logging.
#
# Mirrors scripts/lib/common.sh function-for-function, but does not need a
# jq equivalent at all -- ConvertTo-Json/ConvertFrom-Json are built into the
# language, so there's nothing to bundle or resolve here.
#
# Written against Windows PowerShell 5.1 (the version that ships on every
# Windows machine by default) -- not PowerShell 7+-only syntax or cmdlet
# parameters. HTTP calls shell out to curl.exe (ships inbox on Windows 10
# build 17063+/Windows 11) rather than Invoke-WebRequest/HttpClient -- see
# Invoke-CurlRequest below for why.

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
# -File, which is exactly how run-hook.cmd invokes every hook here),
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

# Invoke-CurlRequest -CurlArgs <string[]>
# Shared machinery for Invoke-HttpPostRaw/Invoke-HttpGetRaw below: runs
# curl.exe with the given arguments (which must already include -s, the
# URL/method/headers, and a trailing "-w `n%{http_code}"), splits the
# status-code line curl appends off of the response body, and maps
# curl's own exit code onto the same {Body, StatusCode, TimedOut,
# ConnectionFailed} contract this plugin has always used -- so every
# existing caller keeps working unchanged regardless of what HTTP
# transport sits underneath.
#
# Replaces an HttpClient + CancellationToken implementation that had its
# own real, confirmed bug: -TimeoutSec/CancelAfter did not reliably abort
# a hung request on a real Windows PowerShell 5.1 target (a 10s timeout
# ran ~22s anyway), forcing a manual Task.Wait(timeout) workaround just to
# get a hard deadline. curl's own --max-time is mature and already proven
# reliable here -- it's exactly what the bash side has used from day one
# (see http_post/http_get in common.sh) with no equivalent problem. This
# also collapses two parallel HTTP implementations (bash's curl calls,
# PowerShell's HttpClient calls) that had to be kept behaviorally
# identical by hand into one real implementation, mirrored.
#
# curl.exe ships inbox on Windows 10 (build 17063+) and Windows 11 by
# default. A heavily locked-down machine that blocks/removes it is a real
# but separate risk, deliberately not handled here yet (no fallback) --
# revisit if it turns out to matter in practice.
function Invoke-CurlRequest {
  param(
    [Parameter(Mandatory = $true)][string[]]$CurlArgs
  )

  $rawOutput = & curl.exe @CurlArgs 2>$null
  $exitCode = $LASTEXITCODE

  # curl exit codes (https://curl.se/libcurl/c/libcurl-errors.html): 28 is
  # specifically operation-timeout (--max-time exceeded); every other
  # non-zero code (couldn't resolve host, couldn't connect, SSL failure,
  # etc.) is treated as one generic connection failure -- the same
  # coarse-grained split check-write.sh/check-prompt.sh already make on
  # the bash side (curl_exit -eq 28 vs curl_exit -ne 0), nothing finer.
  if ($exitCode -eq 28) {
    return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $true; ConnectionFailed = $false }
  }
  if ($exitCode -ne 0) {
    return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $false; ConnectionFailed = $true }
  }

  # curl's "-w `n%{http_code}" always appends the status code as one more
  # line after the response body. PowerShell splits a native command's
  # multi-line stdout into an array of strings (one per line, newlines
  # already stripped) when capturing it into a variable -- @(...) just
  # guards the pathological case where curl printed only a single line.
  $lines = @($rawOutput)
  if ($lines.Count -lt 1) {
    return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $false; ConnectionFailed = $true }
  }
  $statusText = ([string]$lines[$lines.Count - 1]).Trim()
  $statusCode = 0
  if (-not [int]::TryParse($statusText, [ref]$statusCode)) {
    return [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $false; ConnectionFailed = $true }
  }
  $body = if ($lines.Count -gt 1) { ($lines[0..($lines.Count - 2)]) -join "`n" } else { "" }

  return [PSCustomObject]@{
    Body             = $body
    StatusCode       = $statusCode
    TimedOut         = $false
    ConnectionFailed = $false
  }
}

# Invoke-HttpPostRaw -Url ... -BodyBytes ... -ContentType ... -AuthToken ... -TimeoutSec ...
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

  # The request body is written to a temp file and sent via
  # --data-binary @file, never inlined on the command line. PowerShell
  # does not reliably preserve embedded double quotes (which JSON is full
  # of) when marshaling a string argument into the one flat command-line
  # string a native process actually receives on Windows -- confirmed
  # directly: an inline JSON body produced a real "Unable to parse
  # request data" from the backend even though the PowerShell string
  # itself looked completely correct. A uniquely-named temp file (Cursor
  # can fire multiple hook invocations in parallel -- confirmed directly
  # in real logs) avoids that whole class of problem.
  $tempFile = Join-Path $env:TEMP "pn-http-body-$([System.Guid]::NewGuid().ToString('N')).tmp"
  try {
    [System.IO.File]::WriteAllBytes($tempFile, $BodyBytes)

    $curlArgs = @(
      "-s", "-X", "POST", $Url,
      "-H", "Content-Type: $ContentType",
      "--data-binary", "@$tempFile",
      "--max-time", "$TimeoutSec",
      "-w", "`n%{http_code}"
    )
    if ($AuthToken) {
      $curlArgs += @("-H", "Authorization: Bearer $AuthToken")
    }

    return Invoke-CurlRequest -CurlArgs $curlArgs
  } finally {
    Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
  }
}

# Invoke-HttpGetRaw -Url ... -AuthToken ... -TimeoutSec ...
# Same contract as Invoke-HttpPostRaw above -- used for GET /v1/models.
function Invoke-HttpGetRaw {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$AuthToken = "",
    [int]$TimeoutSec = 5
  )

  $curlArgs = @(
    "-s", "-X", "GET", $Url,
    "--max-time", "$TimeoutSec",
    "-w", "`n%{http_code}"
  )
  if ($AuthToken) {
    $curlArgs += @("-H", "Authorization: Bearer $AuthToken")
  }

  return Invoke-CurlRequest -CurlArgs $curlArgs
}

# Invoke-HttpPostMultipart -Url ... -FormArgs <string[]> -AuthToken ... -TimeoutSec ...
# Generic multipart/form-data POST for the detections API (lib/detection-
# client.ps1) -- mirrors http_post_multipart_form in common.sh. FormArgs is
# the full, flat list of curl --form-string/-F flag/value tokens the caller
# wants sent (e.g. "--form-string", "EventType=git.push", ..., "-F",
# "Files=@C:\path\to\file;filename=rel/path"), passed straight through to
# curl.exe via Invoke-CurlRequest. Unlike Invoke-HttpPostRaw's JSON body,
# there's no quote-escaping problem here needing a temp-file workaround --
# Invoke-CurlRequest already preserves each array element's own boundaries
# when invoking curl.exe as a native process.
function Invoke-HttpPostMultipart {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$FormArgs,
    [string]$AuthToken = "",
    [int]$TimeoutSec = 5
  )

  $curlArgs = @("-s", "-X", "POST", $Url) + $FormArgs + @("--max-time", "$TimeoutSec", "-w", "`n%{http_code}")
  if ($AuthToken) {
    $curlArgs += @("-H", "Authorization: Bearer $AuthToken")
  }

  return Invoke-CurlRequest -CurlArgs $curlArgs
}

# Invoke-MessagesHttpPost -Url ... -TextData ... -Model ... -MaxTokens ... -AuthToken ... -TimeoutSec ...
# Builds a request body for the Anthropic-compatible /v1/messages
# endpoint via ConvertTo-Json (not hand-built string interpolation --
# TextData can contain quotes/backslashes/newlines that must be escaped
# correctly) and
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
# text; anomaly: the raw text content, if any -- all three in full, never
# truncated: max_tokens already bounds how large this can get, and
# clipping a real block/anomaly finding to hide it behind a canned
# sentence defeats the point of showing it at all.)
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
    # Best-effort: a missing text block means there's nothing to show
    # (textBlock is already empty in that case), but missing/malformed
    # usage numbers can still come with real text content worth showing,
    # in full -- not guessed or trimmed, same reasoning as the zero-usage
    # anomaly branch below.
    if ($textBlock) {
      $result.Message = $textBlock
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
      # anomaly is by definition a shape we don't recognize (e.g. a real,
      # legitimate block banner variant this heuristic doesn't know about
      # yet -- confirmed to happen in practice: a "RESPONSE BLOCKED"
      # post-generation banner, not just "REQUEST BLOCKED"). The raw text
      # is shown in full rather than guessed at, hidden, or clipped --
      # the caller decides how to present it, this function just refuses
      # to throw away real content behind a canned "unexpected response"
      # sentence.
      $result.Message = $textBlock
    }
  } else {
    # Real allow (non-zero usage): the backend is also a coding assistant,
    # not just a scanner -- on this path its reply can be genuinely useful
    # content (e.g. working code plus an explanation), not throwaway
    # filler. Surfaced in full, the same way the block banner's own
    # explanation is used verbatim rather than clipped -- clipping a
    # real, useful answer would defeat the point of surfacing it at all.
    $result.Message = $textBlock
  }

  return $result
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
# pn_record_successful_scan in common.sh -- see that comment for the full
# rationale: ConvertFrom-PnMessagesResponse's block/allow verdict is a
# reverse-engineered heuristic with no real structured field from the
# backend yet, so a silent, complete loss of enforcement (every scan
# landing on "anomaly") needs a loud signal past a threshold instead of
# staying invisible. Scoped narrowly to that classification, not
# transport-level failures, same as the bash side.
$Script:PnAnomalyStatePath = Join-Path $HOME ".paradigm-scanner\anomaly_state.json"
$Script:PnAnomalyWarningThreshold = 3
$Script:PnScanStalenessThresholdSeconds = 3600

function Add-PnScanAnomaly {
  $count = 0
  $lastSuccessfulScan = $null
  if (Test-Path $Script:PnAnomalyStatePath -PathType Leaf) {
    try {
      $existing = Get-Content -Path $Script:PnAnomalyStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      $existingCount = Get-JsonProperty -InputObject $existing -Name "consecutive_anomaly_count" -Default 0
      if ($existingCount -match '^\d+$') { $count = [int]$existingCount }
      # Preserve whatever was there -- an anomaly verdict must not erase
      # the last confirmed-good scan's timestamp, only bump the streak.
      $lastSuccessfulScan = Get-JsonProperty -InputObject $existing -Name "last_successful_scan" -Default $null
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
    $stateObject = @{ consecutive_anomaly_count = $count }
    if ($null -ne $lastSuccessfulScan) { $stateObject["last_successful_scan"] = $lastSuccessfulScan }
    $tempFile = "$($Script:PnAnomalyStatePath).$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
    (ConvertTo-CompactJson $stateObject) | Set-Content -Path $tempFile -Encoding UTF8 -ErrorAction Stop
    Move-Item -Path $tempFile -Destination $Script:PnAnomalyStatePath -Force -ErrorAction Stop
  } catch {
    # Non-fatal -- see comment above.
  }

  return $count
}

# Called on every allow/block verdict -- never on anomaly/timeout/
# connection-error/HTTP-error/invalid-JSON, since those are exactly the
# failure modes staleness tracking exists to catch. Replaces the old
# Reset-PnScanAnomaly (Remove-Item only): the anomaly streak still needs
# clearing, but that now happens alongside writing a fresh timestamp, so a
# bare file delete no longer fits. This is a blind write (no read step) --
# see pn_record_successful_scan's comment in common.sh for why that's safe
# under a concurrent Add-PnScanAnomaly call.
function Set-PnLastSuccessfulScan {
  try {
    $dir = Split-Path -Parent $Script:PnAnomalyStatePath
    if ($dir -and -not (Test-Path $dir)) {
      New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $tempFile = "$($Script:PnAnomalyStatePath).$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
    (ConvertTo-CompactJson @{ consecutive_anomaly_count = 0; last_successful_scan = $nowEpoch }) |
      Set-Content -Path $tempFile -Encoding UTF8 -ErrorAction Stop
    Move-Item -Path $tempFile -Destination $Script:PnAnomalyStatePath -Force -ErrorAction Stop
  } catch {
    # Non-fatal -- same posture as Add-PnScanAnomaly.
  }
}

# Mirrors pn_check_scan_staleness, but returns $true/$false directly since
# a PowerShell function can return a single value cleanly (bash's global-
# variable convention there works around $(...) subshells stripping state).
function Test-PnScanStale {
  $lastSuccessfulScan = $null
  if (Test-Path $Script:PnAnomalyStatePath -PathType Leaf) {
    try {
      $existing = Get-Content -Path $Script:PnAnomalyStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      $lastSuccessfulScan = Get-JsonProperty -InputObject $existing -Name "last_successful_scan" -Default $null
    } catch {
      $lastSuccessfulScan = $null
    }
  }

  if ($null -eq $lastSuccessfulScan) { return $true }

  $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $age = $nowEpoch - [int64]$lastSuccessfulScan
  # Clock skew -- see Set-PnLastSuccessfulScan's bash mirror comment.
  if ($age -lt 0) { return $false }
  return ($age -gt $Script:PnScanStalenessThresholdSeconds)
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

# Same scoping as Get-CurrentTurnText (last user message to end of file),
# but role-separated into $Script:PnTurnPrompt/$Script:PnTurnResponse
# instead of one blended string -- for Code Chain's turn-recording payload
# (lib/codechain-client.ps1), which has distinct Prompt/Response fields.
# Both globals are reset to "" up front so a missing/unreadable transcript
# leaves neither stale from a previous call in the same process.
function Get-CurrentTurnMessages {
  param(
    [Parameter(Mandatory = $true)][string]$TranscriptPath,
    [int]$MaxLines = 500
  )

  $Script:PnTurnPrompt = ""
  $Script:PnTurnResponse = ""

  if (-not (Test-Path $TranscriptPath -PathType Leaf)) {
    return
  }

  try {
    $lines = @(Get-Content -Path $TranscriptPath -Tail $MaxLines -ErrorAction Stop)
  } catch {
    return
  }

  $parsed = New-Object System.Collections.Generic.List[object]
  foreach ($line in $lines) {
    if (-not $line) { continue }
    try {
      $parsed.Add(($line | ConvertFrom-Json -ErrorAction Stop))
    } catch {
      # Skip a malformed/partial line -- see Get-CurrentTurnText's identical comment.
    }
  }
  if ($parsed.Count -eq 0) {
    return
  }

  $startIndex = 0
  for ($i = $parsed.Count - 1; $i -ge 0; $i--) {
    $role = Get-JsonProperty -InputObject $parsed[$i] -Name "role" -Default ""
    if ($role -eq "user") {
      $startIndex = $i
      break
    }
  }

  $promptParts = New-Object System.Collections.Generic.List[string]
  $responseParts = New-Object System.Collections.Generic.List[string]
  for ($i = $startIndex; $i -lt $parsed.Count; $i++) {
    $role = Get-JsonProperty -InputObject $parsed[$i] -Name "role" -Default ""
    $message = Get-JsonProperty -InputObject $parsed[$i] -Name "message" -Default $null
    if ($null -eq $message) { continue }
    $content = @(Get-JsonProperty -InputObject $message -Name "content" -Default @())
    foreach ($block in $content) {
      $blockType = Get-JsonProperty -InputObject $block -Name "type" -Default ""
      if ($blockType -ne "text") { continue }
      $text = Get-JsonProperty -InputObject $block -Name "text" -Default ""
      if (-not $text) { continue }
      if ($role -eq "user") { $promptParts.Add($text) }
      elseif ($role -eq "assistant") { $responseParts.Add($text) }
    }
  }
  $Script:PnTurnPrompt = ($promptParts -join "`n`n")
  $Script:PnTurnResponse = ($responseParts -join "`n`n")
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
