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
. (Join-Path $ScriptDir "lib\git-utils.ps1")
. (Join-Path $ScriptDir "lib\codechain-client.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$CodechainTimeoutSec = if ($env:PARADIGM_NETWORKS_CODECHAIN_TIMEOUT) { [int]$env:PARADIGM_NETWORKS_CODECHAIN_TIMEOUT } else { 5 }

$stdinText = Get-StdinText

# Best-effort Code Chain session registration, run as a background job so it
# never delays the login-check message below -- see
# design-ideas/Codechain_Plugin_Hooks_Design.md and check-session.sh's
# identical rationale. If this fails or never completes before the process
# exits, later hooks (check-git-event-record, check-turn-complete) simply
# re-attempt idempotent registration themselves.
try {
  if ($stdinText) {
    $sessionPayload = $stdinText | ConvertFrom-Json -ErrorAction Stop
    $clientSessionId = Get-JsonProperty -InputObject $sessionPayload -Name "conversation_id" -Default ""
    if (-not $clientSessionId) {
      $clientSessionId = Get-JsonProperty -InputObject $sessionPayload -Name "session_id" -Default ""
    }
    $cwd = Get-JsonProperty -InputObject $sessionPayload -Name "cwd" -Default ""
    if (-not $cwd) {
      $roots = @(Get-JsonProperty -InputObject $sessionPayload -Name "workspace_roots" -Default @())
      if ($roots.Count -gt 0) { $cwd = $roots[0] }
    }

    if ($clientSessionId -and (Test-PnConfigured)) {
      $config = Resolve-PnConfig
      $gitRepoUrl = ""
      $gitBranch = ""
      if ($cwd -and (Test-Path (Join-Path $cwd ".git"))) {
        $gitRepoUrl = Get-GitRemoteUrlOrEmpty -RepoPath $cwd
        $gitBranch = Get-GitCurrentBranchOrEmpty -RepoPath $cwd
      }
      Start-Job -ScriptBlock {
        param($ScriptDir, $BaseUrl, $AccessToken, $Timeout, $ClientSessionId, $Cwd, $GitRepoUrl, $GitBranch)
        . (Join-Path $ScriptDir "lib\common.ps1")
        . (Join-Path $ScriptDir "lib\codechain-client.ps1")
        Get-CodechainSessionId -BaseUrl $BaseUrl -AccessToken $AccessToken -TimeoutSec $Timeout `
          -ClientSessionId $ClientSessionId -Cwd $Cwd -GitRepoUrl $GitRepoUrl -GitBranch $GitBranch -Platform "cursor-hooks"
      } -ArgumentList $ScriptDir, $config.BaseUrl, $config.AccessToken, $CodechainTimeoutSec, $clientSessionId, $cwd, $gitRepoUrl, $gitBranch | Out-Null
    }
  }
} catch {
  # Never let this delay or fail the login-check logic below.
}

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
