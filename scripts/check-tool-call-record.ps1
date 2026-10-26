# postToolUse hook (Windows): records a tool call's actual result against
# the tool_use block check-tool-call.ps1's before_tool_call opened.
# Mirrors scripts/check-tool-call-record.sh -- see that file's header for
# the full rationale (correlation via Cursor's own tool_use_id, why the
# login/logout exemptions skip recording, and the 60s timeout).
# Purely observational: always returns {}.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "lib\git-utils.ps1")
. (Join-Path $ScriptDir "lib\plugins-client.ps1")
. (Join-Path $ScriptDir "lib\login-detection.ps1")
. (Join-Path $ScriptDir "pn_config.ps1")

$CodechainTimeoutSec = 60
if ($env:PARADIGM_NETWORKS_CODECHAIN_TIMEOUT) {
  $parsedTimeout = 0
  if ([int]::TryParse($env:PARADIGM_NETWORKS_CODECHAIN_TIMEOUT, [ref]$parsedTimeout)) {
    $CodechainTimeoutSec = $parsedTimeout
  }
}
$DebugLogPath = Join-Path $HOME ".paradigm-networks\check-tool-call-record.log"

try {
  $stdinText = Get-StdinText
  if ($stdinText) {
    $payload = $null
    try {
      $payload = $stdinText | ConvertFrom-Json -ErrorAction Stop
    } catch {
      $payload = $null
    }

    if ($null -ne $payload) {
      $toolUseId = [string](Get-JsonProperty -InputObject $payload -Name "tool_use_id" -Default "")
      $clientSessionId = [string](Get-JsonProperty -InputObject $payload -Name "conversation_id" -Default "")
      if (-not $clientSessionId) {
        $clientSessionId = [string](Get-JsonProperty -InputObject $payload -Name "session_id" -Default "")
      }
      $cwd = Get-PnPayloadCwd -Payload $payload
      $generationId = [string](Get-JsonProperty -InputObject $payload -Name "generation_id" -Default "")
      $toolName = [string](Get-JsonProperty -InputObject $payload -Name "tool_name" -Default "")
      $toolInput = Get-JsonProperty -InputObject $payload -Name "tool_input" -Default $null
      $toolInputValue = if ($null -eq $toolInput) { [PSCustomObject]@{} } else { $toolInput }
      $command = ""
      if ($toolInput -is [System.Management.Automation.PSCustomObject]) {
        $command = [string](Get-JsonProperty -InputObject $toolInput -Name "command" -Default "")
      }

      # PN-12153: before_tool_call never ran for an exempted command, so
      # there is no tool_use block to close out -- see the bash side.
      $exemptReason = Get-PnLoginLogoutExemptReason -ToolName $toolName -Command $command -ScriptDir $ScriptDir
      if ($exemptReason) {
        Write-DebugLog -Message "Skipping after_tool_call recording for the exempted command (reason: $exemptReason)." -LogPath $DebugLogPath
      } elseif (-not $toolUseId) {
        Write-DebugLog -Message "No tool_use_id on postToolUse payload; nothing to record against." -LogPath $DebugLogPath
      } elseif ($clientSessionId -and (Test-PnConfigured)) {
        $config = Resolve-PnConfig
        if ($null -ne $config) {
          # tool_output varies by tool: a plain string for Shell/Write, an
          # object for some MCP tools. Record it as text either way.
          $rawOutput = Get-JsonProperty -InputObject $payload -Name "tool_output" -Default ""
          $toolOutput = if ($rawOutput -is [string]) { $rawOutput } else { $rawOutput | ConvertTo-Json -Compress -Depth 64 }

          $gitRepoUrl = ""
          $gitBranch = ""
          if ($cwd -and (Test-PnGitRepo -Path $cwd)) {
            $gitRepoUrl = Get-GitRemoteUrlOrEmpty -RepoPath $cwd
            $gitBranch = Get-GitCurrentBranchOrEmpty -RepoPath $cwd
          }

          Invoke-PnPluginAfterToolCall -BaseUrl $config.BaseUrl -AccessToken $config.AccessToken -TimeoutSec $CodechainTimeoutSec `
            -SessionId $clientSessionId -Cwd $cwd -GitRepoUrl $gitRepoUrl -GitBranch $gitBranch -ToolUseId $toolUseId `
            -Output $toolOutput -IsError $false -GenerationId $generationId -ToolName $toolName -InputValue $toolInputValue
        }
      }
    }
  }
} catch {
  Write-DebugLog -Message "UNEXPECTED ERROR | $($_.Exception.GetType().FullName): $($_.Exception.Message)" -LogPath $DebugLogPath
}

Write-Output "{}"
