# Logs this workspace out of Paradigm Networks (Windows).
# Usage: logout.ps1
# Mirrors scripts/logout.sh -- see that file's comment for why a plain file
# removal is the entire mechanism (no server-side session/token to revoke).
# Standalone CLI script (invoked by the paradigmnetworks-logout skill), not
# a hook.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "pn_config.ps1")

# Writes directly to the console's stdout stream rather than PowerShell's
# own output pipeline -- same reasoning as login.ps1/set-model.ps1's
# identical helper.
function Write-ConsoleLine {
  param([string]$Text = "")
  [Console]::Out.WriteLine($Text)
}

function Invoke-Main {
  if (-not (Test-Path $Script:PnCredPath -PathType Leaf)) {
    Write-ConsoleLine "Not logged in -- no credentials file found at $($Script:PnCredPath)."
    exit 0
  }

  try {
    Remove-Item -Path $Script:PnCredPath -Force -ErrorAction Stop
  } catch {
    [Console]::Error.WriteLine("error: failed to remove $($Script:PnCredPath): $($_.Exception.Message)")
    exit 1
  }

  Write-ConsoleLine "Logged out of Paradigm Networks. Credentials removed from $($Script:PnCredPath)."

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
