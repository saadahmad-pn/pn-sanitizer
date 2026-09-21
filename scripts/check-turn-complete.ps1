# stop hook (Windows): records the just-completed turn (user prompt +
# assistant response) to Code Chain. Mirrors scripts/check-turn-complete.sh
# -- see that file's header for the full rationale. Purely observational:
# always returns {}.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "lib\git-utils.ps1")
. (Join-Path $ScriptDir "lib\codechain-client.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$CodechainTimeoutSec = if ($env:PARADIGM_NETWORKS_CODECHAIN_TIMEOUT) { [int]$env:PARADIGM_NETWORKS_CODECHAIN_TIMEOUT } else { 10 }
$TranscriptLines = if ($env:PARADIGM_NETWORKS_TRANSCRIPT_LINES) { [int]$env:PARADIGM_NETWORKS_TRANSCRIPT_LINES } else { 500 }

$stdinText = Get-StdinText

try {
  if ($stdinText) {
    $payload = $stdinText | ConvertFrom-Json -ErrorAction Stop

    $transcriptPath = Get-JsonProperty -InputObject $payload -Name "transcript_path" -Default ""
    $cwd = Get-JsonProperty -InputObject $payload -Name "cwd" -Default ""
    $clientSessionId = Get-JsonProperty -InputObject $payload -Name "conversation_id" -Default ""
    if (-not $clientSessionId) {
      $clientSessionId = Get-JsonProperty -InputObject $payload -Name "session_id" -Default ""
    }

    if ($transcriptPath -and $clientSessionId) {
      Get-CurrentTurnMessages -TranscriptPath $transcriptPath -MaxLines $TranscriptLines

      if ($Script:PnTurnPrompt -or $Script:PnTurnResponse) {
        if (Test-PnConfigured) {
          $config = Resolve-PnConfig

          $gitRepoUrl = ""
          $gitBranch = ""
          if ($cwd -and (Test-Path (Join-Path $cwd ".git"))) {
            $gitRepoUrl = Get-GitRemoteUrlOrEmpty -RepoPath $cwd
            $gitBranch = Get-GitCurrentBranchOrEmpty -RepoPath $cwd
          }

          Send-CodechainTurn -BaseUrl $config.BaseUrl -AccessToken $config.AccessToken -TimeoutSec $CodechainTimeoutSec `
            -SessionId $clientSessionId -Cwd $cwd -GitRepoUrl $gitRepoUrl -GitBranch $gitBranch `
            -Prompt $Script:PnTurnPrompt -Response $Script:PnTurnResponse
        }
      }
    }
  }
} catch {
  # Never let a recording failure surface -- this hook always returns {}.
}

Write-Output "{}"
