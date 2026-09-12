# OAuth PKCE login flow for Paradigm Networks authentication (Windows).
# Usage: login.ps1 -BaseUrl https://acme.paradigmnetworks.ai
#
# Mirrors scripts/login.sh. The callback listener binds a raw
# System.Net.Sockets.TcpListener to 127.0.0.1 (never a wildcard address).
# A plain socket bind needs no HTTP.SYS URL ACL reservation, so it works
# under a standard, non-admin account -- unlike System.Net.HttpListener,
# which requires either an admin-granted `netsh http add urlacl` reservation
# or binding a wildcard address (itself admin-only), neither of which a
# non-admin dev account has. Every request the listener ever needs to
# receive comes from the browser on this same machine, so there is never a
# reason to bind wider than loopback -- see the plugin's Windows support
# notes for why this specific line must never change.

param(
  [Parameter(Mandatory = $true)][string]$BaseUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$ClientId = "cursor-plugin"
$CallbackTimeoutSeconds = 120
# 120s, matching the bash side and pn_config.ps1's refresh timeout -- this
# hits the same host for the token exchange, and establishing the HTTPS
# connection alone has been observed to take ~20-25s on a real Windows
# target (likely a slow/blocked certificate revocation check).
$TokenTimeoutSeconds = 120

function New-PkcePair {
  $verifierBytes = New-Object byte[] 40
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($verifierBytes)
  $verifier = ConvertTo-Base64Url -Bytes $verifierBytes

  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  $challengeBytes = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
  $challenge = ConvertTo-Base64Url -Bytes $challengeBytes

  return [PSCustomObject]@{ Verifier = $verifier; Challenge = $challenge }
}

function ConvertTo-Base64Url {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes)
  return ([Convert]::ToBase64String($Bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-RandomHexState {
  param([int]$ByteLength = 24)
  $bytes = New-Object byte[] $ByteLength
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Test-RunningInCursorSandbox {
  return ([bool]$env:CURSOR_SANDBOX -or $env:CURSOR_AGENT -eq "1")
}

function Open-LoginBrowser {
  param([Parameter(Mandatory = $true)][string]$Url)
  if (Test-RunningInCursorSandbox) { return $false }
  try {
    Start-Process $Url -ErrorAction Stop | Out-Null
    return $true
  } catch {
    return $false
  }
}

function ConvertTo-NormalizedBaseUrl {
  param([Parameter(Mandatory = $true)][string]$Url)
  if ($Url -notmatch '^https?://') {
    [Console]::Error.WriteLine("error: -BaseUrl must be a full URL like https://acme.paradigmnetworks.ai, got: $Url")
    return $null
  }
  $match = [System.Text.RegularExpressions.Regex]::Match($Url, '^(https?://[^/]*)')
  return $match.Groups[1].Value.TrimEnd('/')
}

# Starts a TcpListener bound to 127.0.0.1 only (see header comment for
# why), trying successive ports starting at 8000. Only retries on
# "address already in use" -- an access-denied or other bind failure would
# apply to every port equally, so it's rethrown immediately instead of
# burning through the whole range first.
function Start-CallbackListener {
  $startPort = 8000
  $endPort = 8099
  for ($port = $startPort; $port -le $endPort; $port++) {
    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $port)
    try {
      $listener.Start()
      return [PSCustomObject]@{ Listener = $listener; Port = $port }
    } catch [System.Net.Sockets.SocketException] {
      if ($_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::AddressAlreadyInUse) {
        continue
      }
      throw
    }
  }
  throw "no free port found between $startPort and $endPort"
}

# Waits for a GET /callback request, with a timeout. Returns a
# PSCustomObject with Code/State/ErrorMessage, or $null on timeout.
#
# Hand-rolls the minimal HTTP handling a TcpListener needs (no HttpListener
# available to parse the request for us): reads the request line off the
# raw NetworkStream, matches it against `/callback`, and decodes the query
# string manually. Uses System.Net.WebUtility.UrlDecode (not
# Uri.UnescapeDataString) for code/state/error specifically because it
# decodes '+' as space, matching scripts/login.sh's urldecode_strict
# (Python's urllib.parse.unquote_plus semantics) -- Uri.UnescapeDataString
# does not treat '+' as space and would silently corrupt any value that
# contains one.
function Wait-ForCallback {
  param(
    [Parameter(Mandatory = $true)][System.Net.Sockets.TcpListener]$Listener,
    [Parameter(Mandatory = $true)][int]$TimeoutSeconds
  )

  $responseBody = '<!doctype html><html><head><title>Paradigm Networks login</title></head><body style="font-family: -apple-system, sans-serif; text-align: center; margin-top: 15vh;"><h2>You''re logged in.</h2></body></html>'
  $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($responseBody)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $remainingMs = [Math]::Max(200, [int](($deadline - (Get-Date)).TotalMilliseconds))
    $acceptTask = $Listener.AcceptTcpClientAsync()
    $completed = [System.Threading.Tasks.Task]::WaitAny(@($acceptTask), $remainingMs)
    if ($completed -ne 0) {
      continue
    }

    $client = $acceptTask.Result
    try {
      $stream = $client.GetStream()
      $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)
      $requestLine = $reader.ReadLine()

      if ($null -eq $requestLine -or $requestLine -notmatch '^GET /callback\?(\S*) HTTP') {
        $notFoundBytes = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nConnection: close`r`n`r`n")
        $stream.Write($notFoundBytes, 0, $notFoundBytes.Length)
        continue
      }

      $queryString = $Matches[1]
      $code = $null
      $state = $null
      $errorParam = $null
      foreach ($pair in $queryString -split '&') {
        if (-not $pair) { continue }
        $kv = $pair -split '=', 2
        $key = $kv[0]
        $value = if ($kv.Length -gt 1) { $kv[1] } else { '' }
        switch ($key) {
          'code' { $code = [System.Net.WebUtility]::UrlDecode($value) }
          'state' { $state = [System.Net.WebUtility]::UrlDecode($value) }
          'error' { $errorParam = [System.Net.WebUtility]::UrlDecode($value) }
        }
      }

      $header = "HTTP/1.1 200 OK`r`nContent-Type: text/html`r`nContent-Length: $($responseBytes.Length)`r`nConnection: close`r`n`r`n"
      $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
      $stream.Write($headerBytes, 0, $headerBytes.Length)
      $stream.Write($responseBytes, 0, $responseBytes.Length)
      $stream.Flush()

      if ($code -or $errorParam) {
        return [PSCustomObject]@{ Code = $code; State = $state; ErrorMessage = $errorParam }
      }
    } finally {
      $client.Close()
    }
  }

  return $null
}

function Invoke-CodeExchange {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][string]$CodeVerifier,
    [Parameter(Mandatory = $true)][string]$RedirectUri
  )

  $tokenUrl = "$($BaseUrl.TrimEnd('/'))/api/v1/plugin/token"
  $body = "grant_type=authorization_code" +
          "&code=$([System.Uri]::EscapeDataString($Code))" +
          "&code_verifier=$([System.Uri]::EscapeDataString($CodeVerifier))" +
          "&client_id=$([System.Uri]::EscapeDataString($ClientId))" +
          "&redirect_uri=$([System.Uri]::EscapeDataString($RedirectUri))"
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

  # Invoke-HttpPostRaw (common.ps1), not Invoke-RestMethod -- see that
  # function's comment: -TimeoutSec was observed to not reliably abort a
  # hung request on Windows during this plugin's own testing.
  $result = Invoke-HttpPostRaw -Url $tokenUrl -BodyBytes $bodyBytes `
    -ContentType "application/x-www-form-urlencoded" -TimeoutSec $TokenTimeoutSeconds

  if ($result.TimedOut) {
    [Console]::Error.WriteLine("error: timed out reaching $BaseUrl")
    return $null
  }
  if ($result.ConnectionFailed -or -not $result.Body) {
    [Console]::Error.WriteLine("error: could not reach $BaseUrl")
    return $null
  }

  $response = $null
  try {
    $response = $result.Body | ConvertFrom-Json -ErrorAction Stop
  } catch {
    [Console]::Error.WriteLine("error: token exchange returned an invalid response")
    return $null
  }

  $accessToken = Get-JsonProperty -InputObject $response -Name "access_token"
  if (-not $accessToken) {
    $errorMsg = Get-JsonProperty -InputObject $response -Name "error_description" -Default (Get-JsonProperty -InputObject $response -Name "error" -Default "unknown error")
    [Console]::Error.WriteLine("error: token exchange failed: $errorMsg")
    return $null
  }

  return $response
}

# Writes directly to the console's stdout stream rather than PowerShell's
# own output pipeline. Deliberate: Invoke-Main below uses `exit N` instead
# of `return N` specifically to avoid a real PowerShell gotcha -- a
# function's "return value" is the collection of every unsuppressed output
# in it, so a plain Write-Output for a progress message would silently get
# bundled into the same output stream as the intended integer result. Using
# exit N (terminates the process outright) plus this (bypasses the
# pipeline) keeps them from ever mixing.
function Write-ConsoleLine {
  param([string]$Text = "")
  [Console]::Out.WriteLine($Text)
}

function Invoke-Main {
  $normalizedBaseUrl = ConvertTo-NormalizedBaseUrl -Url $BaseUrl
  if (-not $normalizedBaseUrl) { exit 1 }

  Write-ConsoleLine "Logging in to $normalizedBaseUrl..."

  $pkce = New-PkcePair
  $state = New-RandomHexState

  $listenerInfo = Start-CallbackListener
  $redirectUri = "http://127.0.0.1:$($listenerInfo.Port)/callback"

  $authorizeUrl = "$($normalizedBaseUrl.TrimEnd('/'))/api/v1/plugin/authorize?" +
    "client_id=$([System.Uri]::EscapeDataString($ClientId))" +
    "&response_type=code" +
    "&code_challenge=$([System.Uri]::EscapeDataString($pkce.Challenge))" +
    "&code_challenge_method=S256" +
    "&redirect_uri=$([System.Uri]::EscapeDataString($redirectUri))" +
    "&state=$([System.Uri]::EscapeDataString($state))"

  # The URL is printed in every branch below, including the "opened a
  # browser" one -- Start-Process succeeding only means the OS accepted
  # the request, not that a browser window actually became visible to the
  # user (observed in practice on Windows: RDP sessions, jump boxes,
  # service accounts, or no default browser association all "succeed"
  # here with nothing actually appearing on screen). Relaying the URL
  # must never depend on silently trusting that it worked.
  if (Test-RunningInCursorSandbox) {
    Write-ConsoleLine "Open this URL to log in:"
    Write-ConsoleLine "  $authorizeUrl"
  } elseif (Open-LoginBrowser -Url $authorizeUrl) {
    Write-ConsoleLine "Opened your browser to log in. If it didn't appear, open this URL manually:"
    Write-ConsoleLine "  $authorizeUrl"
  } else {
    Write-ConsoleLine "Couldn't open a browser automatically. Open this URL to log in:"
    Write-ConsoleLine "  $authorizeUrl"
  }

  Write-ConsoleLine ""
  Write-ConsoleLine "If that link takes you to the main Paradigm Networks dashboard instead of a 'You're logged in' confirmation,"
  Write-ConsoleLine "you weren't signed in to Paradigm Networks in that browser yet -- sign in there, then open the exact same link"
  Write-ConsoleLine "again (no need to re-run this command) to finish."
  Write-ConsoleLine ""
  Write-ConsoleLine "Waiting up to ${CallbackTimeoutSeconds}s for you to complete login..."

  $callbackResult = $null
  try {
    $callbackResult = Wait-ForCallback -Listener $listenerInfo.Listener -TimeoutSeconds $CallbackTimeoutSeconds
  } finally {
    # TcpListener has no Close() method (unlike HttpListener) -- Stop()
    # alone closes the underlying socket and releases the resources.
    $listenerInfo.Listener.Stop()
  }

  if ($null -eq $callbackResult) {
    [Console]::Error.WriteLine("error: timed out waiting for login after ${CallbackTimeoutSeconds}s")
    exit 1
  }

  if ($callbackResult.ErrorMessage) {
    [Console]::Error.WriteLine("error: login was denied or failed: $($callbackResult.ErrorMessage)")
    exit 1
  }

  if ($callbackResult.State -ne $state) {
    [Console]::Error.WriteLine("error: state mismatch on login callback -- possible CSRF, aborting")
    exit 1
  }

  if (-not $callbackResult.Code) {
    [Console]::Error.WriteLine("error: login callback did not include an authorization code")
    exit 1
  }

  $tokenResponse = Invoke-CodeExchange -BaseUrl $normalizedBaseUrl -Code $callbackResult.Code `
    -CodeVerifier $pkce.Verifier -RedirectUri $redirectUri
  if ($null -eq $tokenResponse) { exit 1 }

  $accessToken = Get-JsonProperty -InputObject $tokenResponse -Name "access_token"
  $refreshToken = Get-JsonProperty -InputObject $tokenResponse -Name "refresh_token" -Default ""
  $expiresInRaw = Get-JsonProperty -InputObject $tokenResponse -Name "expires_in" -Default 3600

  $expiresIn = 3600L
  [void][long]::TryParse([string]$expiresInRaw, [ref]$expiresIn)
  if ($expiresIn -le 0) { $expiresIn = 3600L }

  $expiresAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $expiresIn

  $saved = Save-PnCredentials -BaseUrl $normalizedBaseUrl -AccessToken $accessToken `
    -RefreshToken $refreshToken -ExpiresAt $expiresAt
  if (-not $saved) {
    [Console]::Error.WriteLine("error: failed to save credentials")
    exit 1
  }

  Write-ConsoleLine "Logged in to $normalizedBaseUrl. Credentials saved to $($Script:PnCredPath)."
  exit 0
}

Invoke-Main
