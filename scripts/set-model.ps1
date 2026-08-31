# Saves the user's preferred AI model for prompt/write scanning (Windows).
# Usage: set-model.ps1 -Model <model-id>
# Mirrors scripts/set-model.sh. Standalone CLI script (invoked by the
# paradigmnetworks-models skill), not a hook.

param(
  [Parameter(Mandatory = $true)][string]$Model
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

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

  # Best-effort validation against the live catalog before saving -- catches
  # a typo'd or unavailable model id up front, rather than letting it
  # silently fail every real scan later. Deliberately not a hard
  # requirement: if the list itself can't be fetched right now (timeout,
  # connection error, invalid response), save what was asked for anyway
  # with a warning, matching this codebase's general posture of not
  # blocking on an unrelated, temporary failure.
  $modelsUrl = "$($config.BaseUrl.TrimEnd('/'))/v1/models?limit=100"
  $result = Invoke-HttpGetRaw -Url $modelsUrl -AuthToken $config.AccessToken -TimeoutSec $TimeoutSeconds

  $verified = $false
  if (-not $result.TimedOut -and -not $result.ConnectionFailed -and $result.StatusCode -ge 200 -and $result.StatusCode -lt 300) {
    try {
      $parsed = $result.Body | ConvertFrom-Json -ErrorAction Stop
      $models = @(Get-JsonProperty -InputObject $parsed -Name "data" -Default @())
      $isKnown = $false
      foreach ($m in $models) {
        $id = Get-JsonProperty -InputObject $m -Name "id" -Default ""
        if ($id -eq $Model) { $isKnown = $true; break }
      }
      if (-not $isKnown) {
        [Console]::Error.WriteLine("error: '$Model' is not in your organization's available models. Run the paradigmnetworks-models skill to see the exact list, then try again.")
        exit 1
      }
      $verified = $true
    } catch {
      # Invalid JSON from the models endpoint -- fall through to the
      # unverified warning below rather than fail the save outright.
    }
  }
  if (-not $verified) {
    [Console]::Error.WriteLine("warning: couldn't verify '$Model' against the live model list right now -- saving it anyway.")
  }

  $saved = Save-PnPreferredModel -Model $Model
  if (-not $saved) {
    [Console]::Error.WriteLine("error: failed to save the model preference.")
    exit 1
  }

  Write-ConsoleLine "Saved. Prompts and writes will now be scanned using: $Model"
  exit 0
}

Invoke-Main
