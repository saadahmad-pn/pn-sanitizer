# Logs this workspace out of Paradigm Networks (Windows).
# Usage: logout.ps1
# Mirrors scripts/logout.sh -- see that file's comment: a best-effort
# server-side revoke of the stored refresh token (PN-14676), then the local
# credentials file is always removed, whatever the revoke returned.
# Standalone CLI script (invoked by the paradigmnetworks-logout skill), not
# a hook.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# common.ps1 before pn_config.ps1, which depends on it -- see
# check-configured.ps1 (PN-14659).
# common.ps1 for Invoke-HttpPostRaw (same load order as login.ps1).
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$Script:RevokeTimeoutSec = 10

# Returns one line describing the outcome of the server-side revoke. Never
# throws: the local logout must happen regardless.
function Get-RevokeOutcome {
  $unreadable = "Could not revoke the login on the server: the stored credentials are incomplete or unreadable."
  $unreachable = "Could not reach the server to revoke the login, so it stays valid on the server until it expires."

  $creds = $null
  try {
    $creds = Get-Content -Raw -Path $Script:PnCredPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $unreadable
  }
  $names = @($creds.PSObject.Properties.Name)
  $baseUrl = if ($names -contains "base_url") { [string]$creds.base_url } else { "" }
  $refreshToken = if ($names -contains "refresh_token") { [string]$creds.refresh_token } else { "" }
  if (-not $baseUrl -or -not $refreshToken) { return $unreadable }

  $body = "token=$([System.Uri]::EscapeDataString($refreshToken))&token_type_hint=refresh_token&client_id=$([System.Uri]::EscapeDataString($Script:PnClientId))"
  try {
    $result = Invoke-HttpPostRaw -Url "$($baseUrl.TrimEnd('/'))/api/v1/plugin/revoke" `
      -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes($body)) `
      -ContentType "application/x-www-form-urlencoded" -TimeoutSec $Script:RevokeTimeoutSec
  } catch {
    return $unreachable
  }
  if ($result.TimedOut -or $result.ConnectionFailed) { return $unreachable }

  $code = [int]$result.StatusCode
  if ($code -ge 200 -and $code -lt 300) {
    return "Signed out on the server: the login was revoked."
  }
  if (@(404, 405, 501) -contains $code) {
    return "This Paradigm Networks server doesn't support revoking plugin logins yet, so the old login stays valid on the server until it expires."
  }
  return "The server did not confirm the revoke (HTTP $code), so the old login may stay valid on the server until it expires."
}

# Writes directly to the console's stdout stream rather than PowerShell's
# own output pipeline -- same reasoning as login.ps1's identical helper.
function Write-ConsoleLine {
  param([string]$Text = "")
  [Console]::Out.WriteLine($Text)
}

function Invoke-Main {
  if (-not (Test-Path $Script:PnCredPath -PathType Leaf)) {
    Write-ConsoleLine "Not logged in -- no credentials file found at $($Script:PnCredPath)."
    exit 0
  }

  $revokeOutcome = Get-RevokeOutcome

  try {
    Remove-Item -Path $Script:PnCredPath -Force -ErrorAction Stop
  } catch {
    [Console]::Error.WriteLine("error: failed to remove $($Script:PnCredPath): $($_.Exception.Message)")
    exit 1
  }

  Write-ConsoleLine "Logged out of Paradigm Networks. Credentials removed from $($Script:PnCredPath)."
  Write-ConsoleLine $revokeOutcome

  # Resolve-PnConfig (pn_config.ps1) checks these two env vars before ever
  # touching the credentials file -- if both are set, this logout has no
  # visible effect until they're unset, so say so rather than letting the
  # user believe they're fully logged out.
  if ($env:PARADIGM_NETWORKS_URL -and $env:PARADIGM_NETWORKS_TOKEN) {
    Write-ConsoleLine "Note: PARADIGM_NETWORKS_URL and PARADIGM_NETWORKS_TOKEN are still set in this environment and will be used instead of the removed file until unset."
  }

  exit 0
}

Invoke-Main
