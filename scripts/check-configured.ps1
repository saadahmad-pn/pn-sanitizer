# Reports whether this workspace has a stored Paradigm Networks login
# (Windows). Prints CONFIGURED or NOT_CONFIGURED and always exits 0.
# Usage: check-configured.ps1
# Mirrors scripts/check-configured.sh -- see that file's comment for why
# this exists (avoids a raw Test-Path check on the credentials file
# appearing in the agent's own command string, which a security scan
# flagged as exposing the credentials file's path/naming convention).
# Standalone CLI script (invoked by the paradigmnetworks-login skill), not
# a hook.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "pn_config.ps1")

# Writes directly to the console's stdout stream rather than PowerShell's
# own output pipeline -- same reasoning as login.ps1's identical helper.
function Write-ConsoleLine {
  param([string]$Text = "")
  [Console]::Out.WriteLine($Text)
}

function Invoke-Main {
  # Mirrors the exact semantics of the raw check this replaces: a valid
  # stored credentials file (Test-PnConfigured) OR the
  # PARADIGM_NETWORKS_URL/PARADIGM_NETWORKS_TOKEN env var pair. Deliberately
  # not Resolve-PnConfig -- that also attempts a network token refresh on an
  # expired token, which this quick, cheap check should not do.
  if ((Test-PnConfigured) -or ($env:PARADIGM_NETWORKS_URL -and $env:PARADIGM_NETWORKS_TOKEN)) {
    Write-ConsoleLine "CONFIGURED"
  } else {
    Write-ConsoleLine "NOT_CONFIGURED"
  }

  exit 0
}

Invoke-Main
