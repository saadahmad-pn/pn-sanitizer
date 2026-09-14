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
    if (Test-PnScanStale) {
      # Built via [char] escapes, not a literal character, so this file
      # stays pure ASCII -- Windows PowerShell 5.1 doesn't reliably assume
      # UTF-8 for a .ps1 with no byte-order mark, and a real multi-byte
      # UTF-8 character here corrupts the parser's token stream for the
      # rest of the file (confirmed directly elsewhere in this codebase).
      # See scripts/check-prompt.ps1 for the fuller comment.
      $warningSign = "$([char]0x26A0)$([char]0xFE0F)"
      $staleMessage = "$warningSign Paradigm Networks security scanning hasn't completed a successful scan in over an hour (or hasn't completed one yet this session). Prompts and file writes may currently be going through unscanned. Check your network connection and Paradigm Networks login status; if this continues, contact your administrator."
      Write-JsonSessionContext -Context $staleMessage
    } else {
      Write-Output "{}"
    }
  } else {
    $message = "Paradigm Networks is not configured for this workspace. Ask the user for their Paradigm Networks base URL (e.g. https://<org>.paradigmnetworks.ai; if they don't have one yet, they can sign up at https://signup.claude-demo.paradigmnetworks.ai/signup), then run the paradigmnetworks-login skill to authenticate before relying on Paradigm Networks-gated prompts or tool calls."
    Write-JsonSessionContext -Context $message
  }
} catch {
  Write-Output "{}"
}
