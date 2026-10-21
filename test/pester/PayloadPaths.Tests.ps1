# Pester tests for the hook-payload path helpers in lib/common.ps1
# (ConvertTo-PnLocalPath, Get-PnPayloadCwd, Test-PnGitRepo).
#
# Regression: Cursor on Windows reports cwd/workspace_roots as
# "/c:/Users/me/proj". Passed straight to Join-Path, PowerShell treats "/c"
# as a drive name and fails ("Cannot find drive. A drive with the name '/c'
# does not exist"), which made check-tool-call.ps1 fail closed on a real
# Windows machine. macOS/Linux PowerShell has no drives, so the original
# error can't be reproduced here -- these tests pin the conversion instead.
#
# Run with: pwsh -NoProfile -Command "Invoke-Pester -Path test/pester -Output Detailed"

BeforeAll {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  . (Join-Path $RepoRoot "scripts/lib/common.ps1")
}

Describe "ConvertTo-PnLocalPath" {
  It "converts <In> to <Out>" -ForEach @(
    @{ In = "/c:/Users/shoaib/proj";       Out = "c:\Users\shoaib\proj" }
    @{ In = "/C:/Users/Jane Doe/my proj";  Out = "C:\Users\Jane Doe\my proj" }
    @{ In = "/d:";                          Out = "d:" }
    @{ In = "file:///c:/Users/shoaib/proj"; Out = "c:\Users\shoaib\proj" }
    @{ In = "c:/Users/shoaib/proj";        Out = "c:\Users\shoaib\proj" }
    @{ In = "C:\Users\shoaib\proj";        Out = "C:\Users\shoaib\proj" }
  ) {
    ConvertTo-PnLocalPath -Path $In | Should -Be $Out
  }

  It "leaves macOS/Linux paths unchanged" {
    ConvertTo-PnLocalPath -Path "/Users/me/proj" | Should -Be "/Users/me/proj"
    ConvertTo-PnLocalPath -Path "/home/me/c:/odd" | Should -Be "/home/me/c:/odd"
  }

  It "returns an empty string for an empty path" {
    ConvertTo-PnLocalPath -Path "" | Should -Be ""
  }
}

Describe "Get-PnPayloadCwd" {
  It "converts the payload's cwd" {
    $payload = '{"cwd":"/c:/Users/shoaib/proj"}' | ConvertFrom-Json
    Get-PnPayloadCwd -Payload $payload | Should -Be "c:\Users\shoaib\proj"
  }

  It "falls back to the first workspace root" {
    $payload = '{"workspace_roots":["/c:/Users/shoaib/a","/c:/Users/shoaib/b"]}' | ConvertFrom-Json
    Get-PnPayloadCwd -Payload $payload | Should -Be "c:\Users\shoaib\a"
  }

  It "returns an empty string when neither is present" {
    Get-PnPayloadCwd -Payload ('{}' | ConvertFrom-Json) | Should -Be ""
  }
}

Describe "Test-PnGitRepo" {
  It "finds a real repo" {
    $repo = Join-Path ([System.IO.Path]::GetTempPath()) "pn-pester-repo-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path (Join-Path $repo ".git") -Force | Out-Null
    try {
      Test-PnGitRepo -Path $repo | Should -BeTrue
    } finally {
      Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue
    }
  }

  It "returns false, without throwing, for an empty or unusable path" {
    Test-PnGitRepo -Path "" | Should -BeFalse
    { Test-PnGitRepo -Path "/c:/no/such/place" } | Should -Not -Throw
    Test-PnGitRepo -Path "/c:/no/such/place" | Should -BeFalse
    Test-PnGitRepo -Path ("bad" + [char]0 + "path") | Should -BeFalse
  }
}
