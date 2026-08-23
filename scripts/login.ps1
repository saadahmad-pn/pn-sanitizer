# OAuth PKCE login flow for Paradigm Networks authentication (Windows).
# Usage: login.ps1 -BaseUrl https://acme.paradigmnetworks.ai
#
# Mirrors scripts/login.sh. The one deliberate behavioral difference: the
# callback listener binds to 127.0.0.1 specifically (never a wildcard
# address) using System.Net.HttpListener -- binding to a specific loopback
# address does not require administrator rights on Windows, whereas
# binding to a wildcard (+/*) does. Every request the listener ever needs
# to receive comes from the browser on this same machine, so there is
# never a reason to bind wider than that -- see the plugin's Windows
# support notes for why this specific line must never change.

param(
  [Parameter(Mandatory = $true)][string]$BaseUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$ClientId = "cursor-plugin"
$CallbackTimeoutSeconds = 60
$TokenTimeoutSeconds = 15

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

# Starts an HttpListener bound to 127.0.0.1 only (see header comment for
# why), trying successive ports starting at 8000 the same way the bash
# version probes with `nc -z` -- catches the "already in use" exception
# and moves on rather than pre-checking.
function Start-CallbackListener {
  $port = 8000
  while ($port -lt 65000) {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    try {
      $listener.Start()
      return [PSCustomObject]@{ Listener = $listener; Port = $port }
    } catch {
      $listener.Close()
      $port++
    }
  }
  throw "no free port found between 8000 and 65000"
}

# Waits for a GET /callback request, with a timeout. Returns a
# PSCustomObject with Code/State/ErrorMessage, or $null on timeout.
function Wait-ForCallback {
  param(
    [Parameter(Mandatory = $true)][System.Net.HttpListener]$Listener,
    [Parameter(Mandatory = $true)][int]$TimeoutSeconds
  )

  $responseBody = '<!doctype html><html><head><title>Paradigm Networks login</title></head><body style="font-family: -apple-system, sans-serif; text-align: center; margin-top: 15vh;"><h2>You''re logged in.</h2></body></html>'
  $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($responseBody)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $remainingMs = [Math]::Max(200, [int](($deadline - (Get-Date)).TotalMilliseconds))
    $contextTask = $Listener.GetContextAsync()
    $completed = [System.Threading.Tasks.Task]::WaitAny(@($contextTask), $remainingMs)
    if ($completed -ne 0) {
      continue
    }

    $context = $contextTask.Result
    $request = $context.Request

    if ($request.Url.AbsolutePath -ne "/callback") {
      $context.Response.StatusCode = 404
      $context.Response.Close()
      continue
    }

    $code = $request.QueryString["code"]
    $state = $request.QueryString["state"]
    $errorParam = $request.QueryString["error"]

    $context.Response.ContentType = "text/html"
    $context.Response.ContentLength64 = $responseBytes.Length
    $context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
    $context.Response.OutputStream.Close()

    if ($code -or $errorParam) {
      return [PSCustomObject]@{ Code = $code; State = $state; ErrorMessage = $errorParam }
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

  try {
    $response = Invoke-RestMethod -Uri $tokenUrl -Method Post `
      -ContentType "application/x-www-form-urlencoded" -Body $body `
      -TimeoutSec $TokenTimeoutSeconds -ErrorAction Stop
  } catch {
    [Console]::Error.WriteLine("error: could not reach $BaseUrl")
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

  if (Test-RunningInCursorSandbox) {
    Write-ConsoleLine "Open this URL to log in:"
    Write-ConsoleLine "  $authorizeUrl"
  } elseif (Open-LoginBrowser -Url $authorizeUrl) {
    Write-ConsoleLine "Opened your browser to log in."
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
    $listenerInfo.Listener.Stop()
    $listenerInfo.Listener.Close()
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
