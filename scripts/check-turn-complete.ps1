# afterAgentResponse hook (Windows): records the just-completed turn (user
# prompt + assistant response) to Code Chain. Mirrors
# scripts/check-turn-complete.sh -- see that file's header for the full
# rationale, including why this is wired to afterAgentResponse and not
# "stop" (stop fires at agent-loop end, not per turn, and never carries the
# response text directly). Purely observational: always returns {}.

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
    $responseText = Get-JsonProperty -InputObject $payload -Name "text" -Default ""
    # Cursor's own generation_id -- changes per user turn, unlike
    # conversation_id (stable for the whole chat). See lib/codechain-client.ps1's
    # header. Not confirmed present on every hook payload in every Cursor
    # build; the server degrades gracefully when empty.
    $generationId = Get-JsonProperty -InputObject $payload -Name "generation_id" -Default ""
    # Cursor's own hook-reported model name -- see lib/codechain-client.ps1's header.
    # ModelId ("Structured ID for the selected model, when available", per
    # Cursor's hooks docs) is preferred over the legacy model slug (confirmed
    # sending the literal "unknown" placeholder on this hook's payload,
    # 2026-09-22) -- see Resolve-HookModel's header comment in lib/common.ps1.
    $modelId = Get-JsonProperty -InputObject $payload -Name "model_id" -Default ""
    $modelLegacy = Get-JsonProperty -InputObject $payload -Name "model" -Default ""
    $model = Resolve-HookModel -ModelId $modelId -LegacyModel $modelLegacy

    if ($clientSessionId) {
      # The prompt has no field of its own on this hook's payload -- only
      # transcript_path can recover it. The response prefers
      # afterAgentResponse's own "text" (the authoritative final assistant
      # text) and only falls back to the transcript-derived guess if "text"
      # is somehow empty.
      $promptText = ""
      $responseFromTranscript = ""
      if ($transcriptPath) {
        Get-CurrentTurnMessages -TranscriptPath $transcriptPath -MaxLines $TranscriptLines
        $promptText = $Script:PnTurnPrompt
        $responseFromTranscript = $Script:PnTurnResponse
      }
      if (-not $responseText) { $responseText = $responseFromTranscript }

      if ($promptText -or $responseText) {
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
            -Prompt $promptText -Response $responseText -GenerationId $generationId -Model $model
        }
      }
    }
  }
} catch {
  # Never let a recording failure surface -- this hook always returns {}.
}

Write-Output "{}"
