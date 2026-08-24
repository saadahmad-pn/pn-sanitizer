# sessionStart hook (Windows): check if Paradigm Networks is configured,
# ask user to login if not. Per Cursor's hooks contract, this is
# fire-and-forget -- it cannot prevent session creation but can inject
# context into the system prompt. Mirrors scripts/check-session.sh.
#
# No jq-missing branch here, unlike the bash version -- ConvertTo-Json/
# ConvertFrom-Json are part of the language, so there's nothing to be
# missing.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

Get-StdinText | Out-Null

try {
  if (Test-PnConfigured) {
    Write-Output "{}"
  } else {
    $message = "Paradigm Networks is not configured for this workspace. Ask the user for their Paradigm Networks base URL (e.g. https://<org>.paradigmnetworks.ai; if they don't have one yet, they can sign up at https://signup.claude-demo.paradigmnetworks.ai/signup), then run the paradigmnetworks-login skill to authenticate before relying on Paradigm Networks-gated prompts or tool calls."
    Write-JsonSessionContext -Context $message
  }
} catch {
  Write-Output "{}"
}
