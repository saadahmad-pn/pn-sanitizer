# Fetches and displays the AI models available to the logged-in user's
# Paradigm Networks org, via GET {base_url}/v1/models -- shows the exact
# model IDs a user can paste into the "AI model used for scanning"
# setting (Cursor Settings -> Plugins -> Paradigm Networks,
# PARADIGM_NETWORKS_MODEL) to override the default model used for
# scanning prompts and writes. Standalone CLI script (invoked by the
# paradigmnetworks-models skill), not a hook. Mirrors
# scripts/paradigmnetworks-models.sh.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

# 40s, not 20s: same reasoning as check-prompt.ps1/check-write.ps1 -- this
# hits the same host, and establishing the HTTPS connection alone has been
# observed to take ~20-25s on a real Windows target (likely a slow/blocked
# certificate revocation check).
$TimeoutSeconds = 40

# Writes directly to the console's stdout stream rather than PowerShell's
# own output pipeline -- same reasoning as login.ps1's identical helper:
# keeps progress text from silently mixing into a function's return value.
function Write-ConsoleLine {
  param([string]$Text = "")
  [Console]::Out.WriteLine($Text)
}

function Invoke-Main {
  $config = Resolve-PnConfig
  if ($null -eq $config) {
    [Console]::Error.WriteLine("error: Paradigm Networks is not configured on this machine yet -- run the paradigmnetworks-login skill first.")
    exit 1
  }

  $modelsUrl = "$($config.BaseUrl.TrimEnd('/'))/v1/models?limit=100"

  $result = Invoke-HttpGetRaw -Url $modelsUrl -AuthToken $config.AccessToken -TimeoutSec $TimeoutSeconds

  if ($result.TimedOut) {
    [Console]::Error.WriteLine("error: timed out after ${TimeoutSeconds}s reaching $modelsUrl")
    exit 1
  }
  if ($result.ConnectionFailed) {
    [Console]::Error.WriteLine("error: could not reach $modelsUrl")
    exit 1
  }
  if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
    [Console]::Error.WriteLine("error: $modelsUrl returned HTTP $($result.StatusCode)")
    exit 1
  }

  $parsed = $null
  try {
    $parsed = $result.Body | ConvertFrom-Json -ErrorAction Stop
  } catch {
    [Console]::Error.WriteLine("error: $modelsUrl returned an invalid response")
    exit 1
  }

  # @(...) matters: a response with exactly one model would otherwise
  # unwrap to a bare object instead of a one-element array, the same
  # single-item-collection gotcha seen elsewhere in this codebase.
  $models = @(Get-JsonProperty -InputObject $parsed -Name "data" -Default @())
  if ($models.Count -eq 0) {
    Write-ConsoleLine "No models are available for this account."
    exit 0
  }

  Write-ConsoleLine "Available models -- paste the ID (not the name) into the `"AI model used for scanning`" setting to change it:"
  Write-ConsoleLine ""
  foreach ($model in $models) {
    $id = Get-JsonProperty -InputObject $model -Name "id" -Default ""
    $displayName = Get-JsonProperty -InputObject $model -Name "display_name" -Default ""
    Write-ConsoleLine "  $id  --  $displayName"
  }

  $hasMore = Get-JsonProperty -InputObject $parsed -Name "has_more" -Default $false
  if ($hasMore) {
    Write-ConsoleLine ""
    Write-ConsoleLine "(more models exist beyond this list)"
  }

  exit 0
}

Invoke-Main
