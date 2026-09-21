# afterShellExecution hook (Windows): records a git push/commit/PR-create
# command's OUTPUT to Code Chain, once it has actually run. Mirrors
# scripts/check-git-event-record.sh -- see that file's header for why
# recording is split out from check-git-event.ps1 (which gates BEFORE
# execution and cannot see output).
# Purely observational: always returns {} regardless of outcome.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "lib\git-utils.ps1")
. (Join-Path $ScriptDir "lib\codechain-client.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$CodechainTimeoutSec = if ($env:PARADIGM_NETWORKS_CODECHAIN_TIMEOUT) { [int]$env:PARADIGM_NETWORKS_CODECHAIN_TIMEOUT } else { 10 }
$DebugLogPath = Join-Path $env:USERPROFILE ".paradigm-scanner\check-git-event-record.log"

$stdinText = Get-StdinText

try {
  if ($stdinText) {
    $payload = $stdinText | ConvertFrom-Json -ErrorAction Stop

    $commandText = Get-JsonProperty -InputObject $payload -Name "command" -Default ""
    $output = Get-JsonProperty -InputObject $payload -Name "output" -Default ""
    $cwd = Get-JsonProperty -InputObject $payload -Name "cwd" -Default ""
    $clientSessionId = Get-JsonProperty -InputObject $payload -Name "conversation_id" -Default ""
    if (-not $clientSessionId) {
      $clientSessionId = Get-JsonProperty -InputObject $payload -Name "session_id" -Default ""
    }

    if ($commandText -and $clientSessionId -and (Test-PnConfigured)) {
      $config = Resolve-PnConfig

      $gitRepoUrl = ""
      $gitBranch = ""
      if ($cwd -and (Test-Path (Join-Path $cwd ".git"))) {
        $gitRepoUrl = Get-GitRemoteUrlOrEmpty -RepoPath $cwd
        $gitBranch = Get-GitCurrentBranchOrEmpty -RepoPath $cwd
      }

      Get-CodechainSessionId -BaseUrl $config.BaseUrl -AccessToken $config.AccessToken -TimeoutSec $CodechainTimeoutSec `
        -ClientSessionId $clientSessionId -Cwd $cwd -GitRepoUrl $gitRepoUrl -GitBranch $gitBranch -Platform "cursor-hooks"

      if ($Script:PnCodechainSessionId) {
        Send-CodechainShellEvent -BaseUrl $config.BaseUrl -AccessToken $config.AccessToken -TimeoutSec $CodechainTimeoutSec `
          -SessionId $Script:PnCodechainSessionId -CommandText $commandText -Output $output -Cwd $cwd
      } else {
        Write-DebugLog -Message "codechain: no session id available, skipping shell-event recording" -LogPath $DebugLogPath
      }
    }
  }
} catch {
  # Never let a recording failure surface -- this hook always returns {}.
}

Write-Output "{}"
