# afterShellExecution hook (Windows): records EVERY shell command's
# (command, output) pair to Code Chain, once it has actually run -- not just
# git push/commit/PR-create (matcher is "" in hooks.json, catch-all).
# Mirrors scripts/check-git-event-record.sh -- see that file's header for
# why recording is split out from check-git-event.ps1 (which gates BEFORE
# execution, only for those three git commands, and cannot see output), and
# for why sending every command here is still safe (control-server's own
# git/PR-detection regex decides what's actually worth recording as a
# commit/push/PR, regardless of what this hook sends).
# Purely observational: always returns {} regardless of outcome.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "lib\git-utils.ps1")
. (Join-Path $ScriptDir "lib\codechain-client.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$CodechainTimeoutSec = if ($env:PARADIGM_NETWORKS_CODECHAIN_TIMEOUT) { [int]$env:PARADIGM_NETWORKS_CODECHAIN_TIMEOUT } else { 10 }
$DebugLogPath = Join-Path $HOME ".paradigm-scanner\check-git-event-record.log"

$stdinText = Get-StdinText

try {
  Write-DebugLog -Message "raw payload received | length=$($stdinText.Length)" -LogPath $DebugLogPath

  if ($stdinText) {
    $payload = $stdinText | ConvertFrom-Json -ErrorAction Stop

    $commandText = Get-JsonProperty -InputObject $payload -Name "command" -Default ""
    $output = Get-JsonProperty -InputObject $payload -Name "output" -Default ""
    $cwd = Get-JsonProperty -InputObject $payload -Name "cwd" -Default ""
    $clientSessionId = Get-JsonProperty -InputObject $payload -Name "conversation_id" -Default ""
    if (-not $clientSessionId) {
      $clientSessionId = Get-JsonProperty -InputObject $payload -Name "session_id" -Default ""
    }
    $generationId = Get-JsonProperty -InputObject $payload -Name "generation_id" -Default ""

    Write-DebugLog -Message "extracted | session=$clientSessionId | generation_id=$generationId | command_len=$($commandText.Length) | output_len=$($output.Length) | cwd=$cwd" -LogPath $DebugLogPath

    if ($commandText -and $clientSessionId -and (Test-PnConfigured)) {
      $config = Resolve-PnConfig

      $gitRepoUrl = ""
      $gitBranch = ""
      if ($cwd -and (Test-Path (Join-Path $cwd ".git"))) {
        $gitRepoUrl = Get-GitRemoteUrlOrEmpty -RepoPath $cwd
        $gitBranch = Get-GitCurrentBranchOrEmpty -RepoPath $cwd
      }

      Send-CodechainShellEvent -BaseUrl $config.BaseUrl -AccessToken $config.AccessToken -TimeoutSec $CodechainTimeoutSec `
        -SessionId $clientSessionId -Cwd $cwd -GitRepoUrl $gitRepoUrl -GitBranch $gitBranch `
        -CommandText $commandText -Output $output -GenerationId $generationId
    }
  }
} catch {
  # Never let a recording failure surface -- this hook always returns {}.
}

Write-Output "{}"
