# Pester tests for lib/login-detection.ps1 -- the Windows mirror of
# test/test-login-detection.sh. Exercises the anchored command grammar
# directly; end-to-end gating through check-tool-call.ps1 is covered in
# WindowsHooks.Tests.ps1.
#
# Run with: pwsh -NoProfile -Command "Invoke-Pester -Path test/pester -Output Detailed"

BeforeAll {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  . (Join-Path $RepoRoot "scripts/lib/login-detection.ps1")

  # A real scripts dir (with a space in it, like C:\Users\Jane Doe\...) plus
  # a second, unrelated copy -- the grammar must accept only the first.
  $Script:Root = Join-Path ([System.IO.Path]::GetTempPath()) "pn-pester-login-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
  $Script:Sd = Join-Path $Script:Root "My Plugin/scripts"
  $Script:Od = Join-Path $Script:Root "other"
  New-Item -ItemType Directory -Path $Script:Sd, $Script:Od -Force | Out-Null
  foreach ($f in @("login.ps1", "logout.ps1", "check-configured.ps1")) {
    New-Item -ItemType File -Path (Join-Path $Script:Sd $f) -Force | Out-Null
  }
  New-Item -ItemType File -Path (Join-Path $Script:Od "login.ps1") -Force | Out-Null

  $Script:Ps = '& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File'
  $Script:Url = "https://acme.paradigmnetworks.ai"

  function Get-Reason([string]$Command) {
    return (Get-PnLoginLogoutExemptReason -ToolName "Shell" -Command $Command -ScriptDir $Script:Sd)
  }
}

AfterAll {
  if ($Script:Root -and (Test-Path $Script:Root)) {
    Remove-Item -Recurse -Force $Script:Root -ErrorAction SilentlyContinue
  }
}

Describe "Get-PnLoginLogoutExemptReason: accepted shapes" {
  It "accepts the exact login command the skill and check-session.ps1 give the agent" {
    Get-Reason "$($Script:Ps) `"$($Script:Sd)/login.ps1`" -BaseUrl $($Script:Url)" | Should -Be "login_initiation_exempt"
  }
  It "accepts a quoted base URL with a trailing slash" {
    Get-Reason "$($Script:Ps) `"$($Script:Sd)/login.ps1`" -BaseUrl `"$($Script:Url)/`"" | Should -Be "login_initiation_exempt"
  }
  It "accepts a bare interpreter name" {
    Get-Reason "powershell -NoProfile -File `"$($Script:Sd)/login.ps1`" -BaseUrl $($Script:Url)" | Should -Be "login_initiation_exempt"
  }
  It "accepts pwsh and flags in any order" {
    Get-Reason "pwsh.exe -ExecutionPolicy Bypass -NonInteractive -NoProfile -File `"$($Script:Sd)/login.ps1`" -BaseUrl $($Script:Url)" | Should -Be "login_initiation_exempt"
  }
  It "accepts invoking the script directly" {
    Get-Reason "& `"$($Script:Sd)/login.ps1`" -BaseUrl $($Script:Url)" | Should -Be "login_initiation_exempt"
  }
  It "accepts the logout script with no arguments" {
    Get-Reason "$($Script:Ps) `"$($Script:Sd)/logout.ps1`"" | Should -Be "logout_exempt"
  }
  It "accepts the configuration check with no arguments" {
    Get-Reason "$($Script:Ps) `"$($Script:Sd)/check-configured.ps1`"" | Should -Be "check_configured_exempt"
  }
  It "matches the script name case-insensitively, as Windows paths are" {
    if (-not (Test-Path -LiteralPath (Join-Path $Script:Sd "LOGOUT.ps1"))) {
      Set-ItResult -Skipped -Because "this file system is case-sensitive"
      return
    }
    Get-Reason "$($Script:Ps) `"$($Script:Sd)/LOGOUT.ps1`"" | Should -Be "logout_exempt"
  }
}

Describe "Get-PnLoginLogoutExemptReason: rejected shapes" {
  It "rejects anything chained with ;" {
    Get-Reason "$($Script:Ps) `"$($Script:Sd)/login.ps1`" -BaseUrl $($Script:Url); Remove-Item x" | Should -Be ""
  }
  It "rejects anything chained with |" {
    Get-Reason "$($Script:Ps) `"$($Script:Sd)/logout.ps1`" | Out-File x" | Should -Be ""
  }
  It "rejects a same-named script from another install" {
    Get-Reason "$($Script:Ps) `"$($Script:Od)/login.ps1`" -BaseUrl $($Script:Url)" | Should -Be ""
  }
  It "rejects a base URL with a path" {
    Get-Reason "$($Script:Ps) `"$($Script:Sd)/login.ps1`" -BaseUrl https://evil.example/x" | Should -Be ""
  }
  It "rejects a subexpression in place of the base URL" {
    Get-Reason "$($Script:Ps) `"$($Script:Sd)/login.ps1`" -BaseUrl `$(whoami)" | Should -Be ""
  }
  It "rejects a planted powershell.exe at another path" {
    Get-Reason "& `"C:\temp\powershell.exe`" -File `"$($Script:Sd)/login.ps1`" -BaseUrl $($Script:Url)" | Should -Be ""
  }
  It "rejects an unknown interpreter flag" {
    Get-Reason "powershell -Command x -File `"$($Script:Sd)/logout.ps1`"" | Should -Be ""
  }
  It "rejects extra arguments to logout" {
    Get-Reason "$($Script:Ps) `"$($Script:Sd)/logout.ps1`" -Force" | Should -Be ""
  }
  It "rejects the old --base-url spelling, which login.ps1 does not accept" {
    Get-Reason "$($Script:Ps) `"$($Script:Sd)/login.ps1`" --base-url $($Script:Url)" | Should -Be ""
  }
  It "rejects a path containing a variable" {
    Get-Reason "$($Script:Ps) `"`$env:TEMP/login.ps1`" -BaseUrl $($Script:Url)" | Should -Be ""
  }
  It "rejects non-Shell tools" {
    Get-PnLoginLogoutExemptReason -ToolName "Write" -Command "$($Script:Ps) `"$($Script:Sd)/logout.ps1`"" -ScriptDir $Script:Sd | Should -Be ""
  }
}

Describe "Test-PnLoginWaitCall" {
  It "allows AwaitShell" {
    Test-PnLoginWaitCall -ToolName "AwaitShell" -Command "" -FilePath "" | Should -BeTrue
  }
  It "allows reading a Cursor terminal output file (either slash style)" {
    Test-PnLoginWaitCall -ToolName "Read" -Command "" -FilePath (Join-Path $HOME ".cursor/projects/c-Users-x-proj/terminals/123.txt") | Should -BeTrue
    Test-PnLoginWaitCall -ToolName "Read" -Command "" -FilePath ("$HOME\.cursor\projects\c-Users-x-proj\terminals\123.txt") | Should -BeTrue
  }
  It "refuses reading any other file" {
    Test-PnLoginWaitCall -ToolName "Read" -Command "" -FilePath (Join-Path $HOME ".pn/credentials.json") | Should -BeFalse
    Test-PnLoginWaitCall -ToolName "Read" -Command "" -FilePath (Join-Path $HOME ".cursor/projects/p/terminals/1.txt.bak") | Should -BeFalse
    Test-PnLoginWaitCall -ToolName "Read" -Command "" -FilePath (Join-Path $HOME ".cursor/projects/../../.pn/terminals/1.txt") | Should -BeFalse
  }
  It "allows a bare sleep in PowerShell or bash form" {
    Test-PnLoginWaitCall -ToolName "Shell" -Command "Start-Sleep -Seconds 5" -FilePath "" | Should -BeTrue
    Test-PnLoginWaitCall -ToolName "Shell" -Command "Start-Sleep 2" -FilePath "" | Should -BeTrue
    Test-PnLoginWaitCall -ToolName "Shell" -Command "sleep 5" -FilePath "" | Should -BeTrue
  }
  It "refuses a sleep with anything chained on" {
    Test-PnLoginWaitCall -ToolName "Shell" -Command "Start-Sleep 5; Remove-Item x" -FilePath "" | Should -BeFalse
    Test-PnLoginWaitCall -ToolName "Shell" -Command "Start-Sleep `$(whoami)" -FilePath "" | Should -BeFalse
  }
  It "refuses other tools" {
    Test-PnLoginWaitCall -ToolName "Write" -Command "" -FilePath (Join-Path $HOME ".cursor/projects/p/terminals/1.txt") | Should -BeFalse
  }
}
