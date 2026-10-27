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
. (Join-Path $ScriptDir "lib\session-metadata.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$stdinText = Get-StdinText

# Writes this session's local metadata file (SessionId/Cwd/GitRepoUrl/
# GitBranch) -- see lib/session-metadata.ps1. Replaces the Code Chain
# session-start marker this used to send, whose endpoint control-server no
# longer serves (see check-session.sh). Purely local, no login needed, and
# never affects this hook's own output. Run inline rather than as a
# background job: it is a small local write, and a Start-Job child is
# killed when this process exits anyway.
try {
  if ($stdinText) {
    $sessionPayload = $stdinText | ConvertFrom-Json -ErrorAction Stop
    $clientSessionId = [string](Get-JsonProperty -InputObject $sessionPayload -Name "conversation_id" -Default "")
    if (-not $clientSessionId) {
      $clientSessionId = [string](Get-JsonProperty -InputObject $sessionPayload -Name "session_id" -Default "")
    }
    $cwd = Get-PnPayloadCwd -Payload $sessionPayload

    if ($clientSessionId) {
      $gitRepoUrl = ""
      $gitBranch = ""
      if ($cwd -and (Test-PnGitRepo -Path $cwd)) {
        $gitRepoUrl = Get-GitRemoteUrlOrEmpty -RepoPath $cwd
        $gitBranch = Get-GitCurrentBranchOrEmpty -RepoPath $cwd
      }
      Write-PnSessionMetadata -SessionId $clientSessionId -Cwd $cwd -GitRepoUrl $gitRepoUrl -GitBranch $gitBranch
    }
  }
} catch {
  # Never let this delay or fail the login-check logic below.
}

# Sent in every session, configured or not -- same rationale as
# check-session.sh: the agent has no other reliable way to learn this
# install's path. The login/logout skills and pn-login-check rule read it.
$scriptsDirLine = "Paradigm Networks plugin scripts directory: $ScriptDir"

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
      Write-JsonSessionContext -Context "$staleMessage`n`n$scriptsDirLine"
    } else {
      Write-JsonSessionContext -Context $scriptsDirLine
    }
  } else {
    # $ScriptDir is interpolated for the same reason as check-session.sh: the
    # agent cannot discover the plugin's install path, and every command it
    # would use to look is blocked while unconfigured.
    $loginScript = Join-Path $ScriptDir "login.ps1"
    $message = "Paradigm Networks is not configured for this workspace, so tool calls are currently blocked until login completes.`n`nTo fix this: ask the user for their Paradigm Networks base URL (e.g. https://<org>.paradigmnetworks.ai; if they don't have one yet, they can sign up at https://signup.claude-demo.paradigmnetworks.ai/signup), then run EXACTLY this via the Shell tool with their URL substituted in, outside the sandbox (required_permissions [`"all`"]) since it must reach the Paradigm Networks server and save the login in the home folder:`n`n& `"`$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"$loginScript`" -BaseUrl <their-base-url>`n`nRun it verbatim. Do NOT search for the script, list directories, read files, or chain anything onto the command -- that path is this plugin's own install directory and is the only one accepted, and every other tool call is blocked until login finishes, so trying to locate it yourself will fail. See the paradigmnetworks-login skill for the rest of the flow."
    Write-JsonSessionContext -Context "$message`n`n$scriptsDirLine"
  }
} catch {
  Write-Output "{}"
}
