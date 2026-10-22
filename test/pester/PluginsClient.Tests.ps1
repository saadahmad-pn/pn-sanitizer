# Pester tests for lib/plugins-client.ps1 -- the Windows mirror of
# lib/plugins-client.sh. Invoke-HttpPostRaw is mocked, so these check the
# exact request each call would send and how every response/failure shape
# is classified, without a network.
#
# Run with: pwsh -NoProfile -Command "Invoke-Pester -Path test/pester -Output Detailed"

BeforeAll {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

  # Isolated $HOME: the client writes its debug log under it. See
  # PnConfig.Tests.ps1 for why Set-Variable is the only override that works.
  $Script:TestHome = Join-Path ([System.IO.Path]::GetTempPath()) "pn-pester-client-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
  New-Item -ItemType Directory -Path $Script:TestHome -Force | Out-Null
  Set-Variable -Name HOME -Value $Script:TestHome -Scope Global -Force

  . (Join-Path $RepoRoot "scripts/lib/common.ps1")
  . (Join-Path $RepoRoot "scripts/lib/git-utils.ps1")
  . (Join-Path $RepoRoot "scripts/lib/plugins-client.ps1")

  if ($Script:PluginsDebugLogPath -notlike "$($Script:TestHome)*") {
    throw "SAFETY ABORT: PluginsDebugLogPath ($($Script:PluginsDebugLogPath)) is not under the isolated test HOME."
  }

  $Script:Common = @{ BaseUrl = "https://acme.paradigmnetworks.ai/"; AccessToken = "tok"; TimeoutSec = 5; SessionId = "sess-1" }

  function New-Raw([int]$Status, [string]$Body) {
    return [PSCustomObject]@{ Body = $Body; StatusCode = $Status; TimedOut = $false; ConnectionFailed = $false }
  }
}

AfterAll {
  if ($Script:TestHome -and (Test-Path $Script:TestHome)) {
    Remove-Item -Recurse -Force $Script:TestHome -ErrorAction SilentlyContinue
  }
}

Describe "Invoke-PnPluginBeforeToolCall" {
  BeforeEach {
    $Script:Sent = $null
    Mock Invoke-HttpPostRaw {
      $Script:Sent = @{ Url = $Url; Auth = $AuthToken; Body = ([System.Text.Encoding]::UTF8.GetString($BodyBytes) | ConvertFrom-Json) }
      return (New-Raw 200 '{"action_to_take":"block","message":"bad","overall_threat_level":"high","ToolUseId":"srv-1"}')
    }
  }

  It "posts the standardized before_tool_call body to the tool-calls domain" {
    $toolInput = [PSCustomObject]@{ command = "ls -la" }
    $r = Invoke-PnPluginBeforeToolCall @Script:Common -Cwd "C:\repo" -ToolName "Shell" -InputValue $toolInput -GenerationId "g1" -Model "m1" -ToolUseId "cur-1" -ScanContext "ctx"

    $Script:Sent.Url | Should -Be "https://acme.paradigmnetworks.ai/api/v1/plugins/sessions/sess-1/tool-calls"
    $Script:Sent.Auth | Should -Be "tok"
    $b = $Script:Sent.Body
    $b.Action | Should -Be "before_tool_call"
    $b.Platform | Should -Be "cursor-plugin"
    $b.ToolName | Should -Be "Shell"
    $b.Input.command | Should -Be "ls -la"
    $b.ToolUseId | Should -Be "cur-1"
    $b.ScanContext | Should -Be "ctx"
    @($b.Files).Count | Should -Be 0

    $r.Status | Should -Be "ok"
    $r.Action | Should -Be "block"
    $r.Message | Should -Be "bad"
    $r.ThreatLevel | Should -Be "high"
    $r.ToolUseId | Should -Be "srv-1"
  }

  It "sends attached files as a flat array of {Filename, ContentBase64}" {
    $files = @([ordered]@{ Filename = "app.py"; ContentBase64 = "eA==" })
    Invoke-PnPluginBeforeToolCall @Script:Common -ToolName "Shell" -InputValue "x" -Files $files | Out-Null
    $f = @($Script:Sent.Body.Files)
    $f.Count | Should -Be 1
    $f[0].Filename | Should -Be "app.py"
  }

  It "returns no_session without calling the server when there is no session id" {
    $r = Invoke-PnPluginBeforeToolCall -BaseUrl "https://x" -AccessToken "t" -TimeoutSec 5 -SessionId "" -ToolName "Shell"
    $r.Status | Should -Be "no_session"
    Should -Invoke Invoke-HttpPostRaw -Times 0 -Exactly
  }
}

Describe "Response classification" {
  It "classifies <Name>" -ForEach @(
    @{ Name = "a timeout";          Raw = [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $true;  ConnectionFailed = $false }; Status = "timeout" }
    @{ Name = "a connection failure"; Raw = [PSCustomObject]@{ Body = $null; StatusCode = $null; TimedOut = $false; ConnectionFailed = $true }; Status = "unreachable" }
    @{ Name = "an HTTP 500";        Raw = [PSCustomObject]@{ Body = '{}';  StatusCode = 500;   TimedOut = $false; ConnectionFailed = $false }; Status = "http_error" }
    @{ Name = "a non-JSON body";    Raw = [PSCustomObject]@{ Body = '<html>proxy</html>'; StatusCode = 200; TimedOut = $false; ConnectionFailed = $false }; Status = "invalid_json" }
  ) {
    Mock Invoke-HttpPostRaw { return $Raw }
    (Invoke-PnPluginBeforePrompt @Script:Common -Text "hi").Status | Should -Be $Status
  }

  It "keeps the HTTP status for an http_error" {
    Mock Invoke-HttpPostRaw { return (New-Raw 401 '{"error":"unauthorized"}') }
    (Invoke-PnPluginBeforePrompt @Script:Common -Text "hi").HttpStatus | Should -Be 401
  }
}

Describe "Prompts domain" {
  BeforeEach {
    $Script:Sent = $null
    Mock Invoke-HttpPostRaw {
      $Script:Sent = @{ Url = $Url; Body = ([System.Text.Encoding]::UTF8.GetString($BodyBytes) | ConvertFrom-Json) }
      return (New-Raw 200 '{"action_to_take":"allow"}')
    }
  }

  It "posts before_prompt to the prompts domain" {
    Invoke-PnPluginBeforePrompt @Script:Common -Text "hello" -GenerationId "g" -Model "m" | Out-Null
    $Script:Sent.Url | Should -BeLike "*/api/v1/plugins/sessions/sess-1/prompts"
    $Script:Sent.Body.Action | Should -Be "before_prompt"
    $Script:Sent.Body.Text | Should -Be "hello"
  }

  It "posts after_agent_response with both halves of the turn" {
    Invoke-PnPluginAfterAgentResponse @Script:Common -Prompt "q" -Response "a"
    $Script:Sent.Body.Action | Should -Be "after_agent_response"
    $Script:Sent.Body.Text | Should -Be "q"
    $Script:Sent.Body.Response | Should -Be "a"
  }

  It "skips after_agent_response when there is nothing to record" {
    Invoke-PnPluginAfterAgentResponse @Script:Common -Prompt "" -Response ""
    Should -Invoke Invoke-HttpPostRaw -Times 0 -Exactly
  }
}

Describe "Invoke-PnPluginAfterToolCall" {
  BeforeEach {
    $Script:Sent = $null
    Mock Invoke-HttpPostRaw {
      $Script:Sent = @{ Body = ([System.Text.Encoding]::UTF8.GetString($BodyBytes) | ConvertFrom-Json) }
      return (New-Raw 200 '{}')
    }
  }

  It "sends IsError as a JSON boolean" {
    Invoke-PnPluginAfterToolCall @Script:Common -ToolUseId "srv-1" -Output "[BLOCKED] x" -IsError $true -ToolName "Shell" -InputValue "x"
    $Script:Sent.Body.Action | Should -Be "after_tool_call"
    $Script:Sent.Body.IsError | Should -BeOfType [bool]
    $Script:Sent.Body.IsError | Should -BeTrue
  }

  It "does nothing without a tool_use id" {
    Invoke-PnPluginAfterToolCall @Script:Common -ToolUseId "" -Output "x"
    Should -Invoke Invoke-HttpPostRaw -Times 0 -Exactly
  }
}

Describe "Get-PnGitDiffFiles / Get-PnFilesFromList" {
  BeforeAll {
    $Script:Repo = Join-Path $Script:TestHome "repo"
    New-Item -ItemType Directory -Path $Script:Repo -Force | Out-Null
    & git -C $Script:Repo init -q 2>$null
    Set-Content -Path (Join-Path $Script:Repo "one.py") -Value "print(1)" -NoNewline
    [System.IO.File]::WriteAllBytes((Join-Path $Script:Repo "blob.bin"), [byte[]](0x50, 0x00, 0x51))
    & git -C $Script:Repo add one.py blob.bin 2>$null
  }

  It "returns a flat array for a single staged file (no extra nesting)" {
    $files = @(Get-PnGitDiffFiles -Cwd $Script:Repo -GitEventType "git.commit")
    $files.Count | Should -Be 1
    $json = ConvertTo-Json -InputObject ([ordered]@{ Files = $files }) -Compress -Depth 10
    $json | Should -Match '^\{"Files":\[\{"Filename":"one.py",'
  }

  It "skips binary files" {
    $names = @(Get-PnGitDiffFiles -Cwd $Script:Repo -GitEventType "git.commit" | ForEach-Object { $_.Filename })
    $names | Should -Not -Contain "blob.bin"
  }

  It "base64-encodes the file content" {
    $f = @(Get-PnGitDiffFiles -Cwd $Script:Repo -GitEventType "git.commit")[0]
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($f.ContentBase64)) | Should -Be "print(1)"
  }

  It "honours the max-files cap" {
    $env:PARADIGM_NETWORKS_GIT_EVENT_MAX_FILES = "0"
    try {
      @(Get-PnFilesFromList -Cwd $Script:Repo -RelativePaths @("one.py")).Count | Should -Be 0
    } finally {
      Remove-Item Env:\PARADIGM_NETWORKS_GIT_EVENT_MAX_FILES -ErrorAction SilentlyContinue
    }
  }

  It "returns an empty array for an event type it does not handle" {
    @(Get-PnGitDiffFiles -Cwd $Script:Repo -GitEventType "git.pr_create").Count | Should -Be 0
  }
}
