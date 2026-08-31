# Credential and config management for Paradigm Networks hook scripts
# (Windows). Handles reading/writing ~/.pn/credentials.json and token
# refresh. Mirrors scripts/pn_config.sh function-for-function.
#
# The ~/.pn directory/filename is intentionally unchanged from the bash
# version -- same reasoning as there: internal, not user-facing, and
# changing it would force every existing login to re-authenticate.

Set-StrictMode -Version Latest

$Script:PnClientId = "cursor-plugin"
$Script:PnCredDir = Join-Path $HOME ".pn"
$Script:PnCredPath = Join-Path $Script:PnCredDir "credentials.json"
# 40s, not 10s: same reasoning as check-prompt.ps1/check-write.ps1 -- this
# hits the same host, and establishing the HTTPS connection alone has been
# observed to take ~20-25s on a real Windows target (likely a slow/blocked
# certificate revocation check). This is the silent, on-the-critical-path
# refresh call, so it needs the same margin, not less.
$Script:PnTokenTimeoutSec = 40
$Script:PnExpiryMarginSeconds = 60

# Restricts a file or directory to the current user only -- the Windows
# ACL equivalent of chmod 600/700. Removes inherited permissions and
# grants Full Control to the current user alone.
function Protect-PathForCurrentUserOnly {
  param([Parameter(Mandatory = $true)][string]$Path)
  try {
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
      $acl.RemoveAccessRule($rule) | Out-Null
    }
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
      $currentUser, "FullControl", "Allow"
    )
    $acl.AddAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
  } catch {
    # Best-effort, same as the bash version's `chmod ... || true` -- a
    # permission-lockdown failure must not block login.
  }
}

# Returns a PSCustomObject with BaseUrl/AccessToken/RefreshToken/ExpiresAt,
# or $null if the file is missing, unreadable, or missing required fields.
function Get-PnCredentials {
  if (-not (Test-Path $Script:PnCredPath -PathType Leaf)) {
    return $null
  }
  try {
    $raw = Get-Utf8FileText -Path $Script:PnCredPath
    $creds = $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
  $baseUrl = Get-JsonProperty -InputObject $creds -Name "base_url"
  $accessToken = Get-JsonProperty -InputObject $creds -Name "access_token"
  $refreshToken = Get-JsonProperty -InputObject $creds -Name "refresh_token"
  $expiresAt = Get-JsonProperty -InputObject $creds -Name "expires_at"
  if (-not ($baseUrl -and $accessToken -and $refreshToken -and $expiresAt)) {
    return $null
  }
  return [PSCustomObject]@{
    BaseUrl      = $baseUrl
    AccessToken  = $accessToken
    RefreshToken = $refreshToken
    ExpiresAt    = $expiresAt
  }
}

function Save-PnCredentials {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$AccessToken,
    [Parameter(Mandatory = $true)][string]$RefreshToken,
    [Parameter(Mandatory = $true)][long]$ExpiresAt
  )

  # Write to a temp file first, lock it down, then move into place --
  # mirrors the bash version's mktemp + chmod-before-move pattern so the
  # credentials file is never briefly world-readable.
  $tempFile = "$($Script:PnCredPath).$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
  try {
    # -ErrorAction Stop on every cmdlet in this block matters, not just
    # style: every caller of this function runs under
    # $ErrorActionPreference = "Continue", which makes a cmdlet's own
    # errors non-terminating by default -- a plain try/catch does not
    # intercept those, so without this, a failed step here could fall
    # through silently and this function would incorrectly return $true.
    if (-not (Test-Path $Script:PnCredDir)) {
      New-Item -ItemType Directory -Path $Script:PnCredDir -Force -ErrorAction Stop | Out-Null
    }
    Protect-PathForCurrentUserOnly -Path $Script:PnCredDir

    # Merge into whatever's already on disk, not a from-scratch rebuild --
    # this function runs automatically and silently on every token
    # refresh (see Get-PnValidAccessToken below), so a naive rebuild
    # would wipe any field this function doesn't itself know about (e.g.
    # a saved PreferredModel, see Save-PnPreferredModel) the very next
    # time a session runs long enough to trigger a refresh.
    $credsObject = [PSCustomObject]@{}
    if (Test-Path $Script:PnCredPath -PathType Leaf) {
      try {
        $existing = (Get-Utf8FileText -Path $Script:PnCredPath) | ConvertFrom-Json -ErrorAction Stop
        if ($existing) { $credsObject = $existing }
      } catch {
        # Corrupt/unreadable existing file -- fall through with an empty
        # object rather than fail the save outright.
      }
    }
    $credsObject | Add-Member -NotePropertyName "base_url" -NotePropertyValue $BaseUrl -Force
    $credsObject | Add-Member -NotePropertyName "access_token" -NotePropertyValue $AccessToken -Force
    $credsObject | Add-Member -NotePropertyName "refresh_token" -NotePropertyValue $RefreshToken -Force
    $credsObject | Add-Member -NotePropertyName "expires_at" -NotePropertyValue $ExpiresAt -Force

    Set-Utf8FileTextNoBom -Path $tempFile -Value ($credsObject | ConvertTo-Json -Compress)
    Protect-PathForCurrentUserOnly -Path $tempFile
    Move-Item -Path $tempFile -Destination $Script:PnCredPath -Force -ErrorAction Stop
    Protect-PathForCurrentUserOnly -Path $Script:PnCredPath
    return $true
  } catch {
    Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    return $false
  }
}

# Save the user's preferred scanning model. Separate from
# Save-PnCredentials -- a model change shouldn't require also supplying
# BaseUrl/AccessToken/RefreshToken/ExpiresAt -- but uses the same
# merge-then-atomic-write pattern. Requires an existing, valid
# credentials file (there's nothing meaningful to merge a model
# preference into otherwise).
function Save-PnPreferredModel {
  param(
    [Parameter(Mandatory = $true)][string]$Model
  )

  if (-not (Test-Path $Script:PnCredPath -PathType Leaf)) {
    return $false
  }

  $tempFile = "$($Script:PnCredPath).$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
  try {
    $existing = (Get-Utf8FileText -Path $Script:PnCredPath) | ConvertFrom-Json -ErrorAction Stop
    $existing | Add-Member -NotePropertyName "preferred_model" -NotePropertyValue $Model -Force

    Set-Utf8FileTextNoBom -Path $tempFile -Value ($existing | ConvertTo-Json -Compress)
    Protect-PathForCurrentUserOnly -Path $tempFile
    Move-Item -Path $tempFile -Destination $Script:PnCredPath -Force -ErrorAction Stop
    Protect-PathForCurrentUserOnly -Path $Script:PnCredPath
    return $true
  } catch {
    Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    return $false
  }
}

# Returns the stored preferred_model, or an empty string if unset or not
# configured. Deliberately independent of Resolve-PnConfig -- this is a
# plain file read, no auth/refresh machinery needed.
function Get-PnPreferredModel {
  if (-not (Test-Path $Script:PnCredPath -PathType Leaf)) {
    return ""
  }
  try {
    $creds = (Get-Utf8FileText -Path $Script:PnCredPath) | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return ""
  }
  return [string](Get-JsonProperty -InputObject $creds -Name "preferred_model" -Default "")
}

# Resolve-PnModel
# Resolves which model to use for a /v1/messages scan. Precedence:
# PARADIGM_NETWORKS_MODEL env var (a manual override -- only takes effect
# if something exports it directly into the process environment, e.g. a
# shared-host setup; there is no Cursor Settings UI for this -- an
# earlier version had one, but it was removed after confirming, against
# a real installed plugin, that Cursor's plugin Settings panel never
# delivers configured values to hook scripts) > the model saved locally
# via the paradigmnetworks-models skill / set-model.ps1
# (Get-PnPreferredModel, above -- this is the real, user-facing way to
# change it) > $Script:PnDefaultModel.
#
# Formerly this exact precedence chain was duplicated by hand across six
# files (check-prompt.sh/.ps1, check-write.sh/.ps1, paradigmnetworks-
# models.sh/.ps1) -- see P2-3, and pn_resolve_model in pn_config.sh for
# the bash mirror.
#
# Returns [PSCustomObject]@{ Model = "..."; IsDefault = $true/$false }
# ($true only when nothing else resolved and the hardcoded default was
# used -- paradigmnetworks-models.ps1 needs this to print "(default)").
$Script:PnDefaultModel = "anthropic/claude-haiku-4-5-20251001"
function Resolve-PnModel {
  $model = $env:PARADIGM_NETWORKS_MODEL
  if (-not $model) { $model = Get-PnPreferredModel }
  if (-not $model) {
    return [PSCustomObject]@{ Model = $Script:PnDefaultModel; IsDefault = $true }
  }
  return [PSCustomObject]@{ Model = $model; IsDefault = $false }
}

# Returns a PSCustomObject with AccessToken/RefreshToken/ExpiresIn, or
# $null on any failure (unreachable, non-2xx, missing fields).
function Invoke-PnTokenRefresh {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$RefreshToken
  )

  $tokenUrl = "$($BaseUrl.TrimEnd('/'))/api/v1/plugin/token"
  $body = "grant_type=refresh_token&refresh_token=$([System.Uri]::EscapeDataString($RefreshToken))&client_id=$([System.Uri]::EscapeDataString($Script:PnClientId))"
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

  # Invoke-HttpPostRaw (common.ps1), not Invoke-RestMethod: -TimeoutSec was
  # observed to not reliably abort a hung request on Windows in this
  # plugin's own testing -- see that function's comment for detail. This
  # refresh call sits on the critical path of every scan while a token is
  # expiring, so a silent hang here is exactly what previously showed up
  # as check-prompt.ps1 hanging with no error and no log past "Read stdin".
  $result = Invoke-HttpPostRaw -Url $tokenUrl -BodyBytes $bodyBytes `
    -ContentType "application/x-www-form-urlencoded" -TimeoutSec $Script:PnTokenTimeoutSec

  if ($result.TimedOut -or $result.ConnectionFailed -or -not $result.Body) {
    return $null
  }
  if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
    return $null
  }

  $response = $null
  try {
    $response = $result.Body | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }

  $newAccessToken = Get-JsonProperty -InputObject $response -Name "access_token"
  $newRefreshToken = Get-JsonProperty -InputObject $response -Name "refresh_token"
  $expiresIn = Get-JsonProperty -InputObject $response -Name "expires_in"
  if (-not ($newAccessToken -and $newRefreshToken -and $expiresIn)) {
    return $null
  }

  return [PSCustomObject]@{
    AccessToken  = $newAccessToken
    RefreshToken = $newRefreshToken
    ExpiresIn    = $expiresIn
  }
}

# Returns a PSCustomObject with BaseUrl/AccessToken, or $null on failure.
function Get-PnValidAccessToken {
  $creds = Get-PnCredentials
  if ($null -eq $creds) { return $null }

  $expiresAt = 0L
  [void][long]::TryParse([string]$creds.ExpiresAt, [ref]$expiresAt)

  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $timeUntilExpiry = $expiresAt - $now

  if ($timeUntilExpiry -gt $Script:PnExpiryMarginSeconds) {
    return [PSCustomObject]@{ BaseUrl = $creds.BaseUrl; AccessToken = $creds.AccessToken }
  }

  $refreshed = Invoke-PnTokenRefresh -BaseUrl $creds.BaseUrl -RefreshToken $creds.RefreshToken
  if ($null -eq $refreshed) { return $null }

  $expiresIn = 0L
  if (-not [long]::TryParse([string]$refreshed.ExpiresIn, [ref]$expiresIn)) {
    return $null
  }

  $newExpiresAt = $now + $expiresIn
  $saved = Save-PnCredentials -BaseUrl $creds.BaseUrl -AccessToken $refreshed.AccessToken `
    -RefreshToken $refreshed.RefreshToken -ExpiresAt $newExpiresAt
  if (-not $saved) { return $null }

  return [PSCustomObject]@{ BaseUrl = $creds.BaseUrl; AccessToken = $refreshed.AccessToken }
}

# Resolve config: PARADIGM_NETWORKS_URL/PARADIGM_NETWORKS_TOKEN env vars
# take precedence, then the stored file (with refresh).
function Resolve-PnConfig {
  $envBase = $env:PARADIGM_NETWORKS_URL
  $envToken = $env:PARADIGM_NETWORKS_TOKEN
  if ($envBase -and $envToken) {
    return [PSCustomObject]@{ BaseUrl = $envBase; AccessToken = $envToken }
  }

  return Get-PnValidAccessToken
}

function Test-PnConfigured {
  return ($null -ne (Get-PnCredentials))
}
