# Pester tests for pn_config.ps1's credential round-trip -- mirrors the
# equivalent bash coverage in test/test-unit.sh's "Unit Tests: pn_config.sh"
# section so the two implementations can't quietly drift apart. See P3-3.
#
# Uses an isolated, disposable $HOME for every test. PowerShell's $HOME is
# a read-only automatic variable -- Set-Variable -Scope Global -Force is
# the only way to actually override what pn_config.ps1 reads (setting
# $env:HOME does NOT work; that mistake happened twice already earlier in
# this project's history and is exactly why the explicit guard below
# exists, not just the override itself).
#
# Run with: pwsh -NoProfile -Command "Invoke-Pester -Path test/pester -Output Detailed"

BeforeAll {
  $ScriptDir = Split-Path -Parent $PSScriptRoot
  $RepoRoot = Split-Path -Parent $ScriptDir

  $Script:TestHome = Join-Path ([System.IO.Path]::GetTempPath()) "pn-pester-test-home-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
  New-Item -ItemType Directory -Path $Script:TestHome -Force | Out-Null
  Set-Variable -Name HOME -Value $Script:TestHome -Scope Global -Force

  . (Join-Path $RepoRoot "scripts\lib\common.ps1")
  . (Join-Path $RepoRoot "scripts\pn_config.ps1")

  # Refuse to run a single test if PnCredPath doesn't actually resolve
  # under the isolated test HOME -- would mean a real file is at risk.
  if ($Script:PnCredPath -notlike "$($Script:TestHome)*") {
    throw "SAFETY ABORT: PnCredPath ($($Script:PnCredPath)) is not under the isolated test HOME ($($Script:TestHome)) -- refusing to run credential tests that could touch a real file."
  }
}

AfterAll {
  if ($Script:TestHome -and (Test-Path $Script:TestHome)) {
    Remove-Item -Recurse -Force $Script:TestHome -ErrorAction SilentlyContinue
  }
}

Describe "Save-PnCredentials / Get-PnCredentials round-trip" {
  BeforeEach {
    Remove-Item -Path $Script:PnCredPath -Force -ErrorAction SilentlyContinue
  }

  It "creates the file and Get-PnCredentials reads back the same values" {
    $expiresAt = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
    $saved = Save-PnCredentials -BaseUrl "https://acme.example.com" -AccessToken "tok-1" -RefreshToken "ref-1" -ExpiresAt $expiresAt
    $saved | Should -Be $true

    $creds = Get-PnCredentials
    $creds | Should -Not -BeNullOrEmpty
    $creds.BaseUrl | Should -Be "https://acme.example.com"
    $creds.AccessToken | Should -Be "tok-1"
    $creds.RefreshToken | Should -Be "ref-1"
  }

  It "returns null when the credentials file doesn't exist" {
    Get-PnCredentials | Should -BeNullOrEmpty
  }

  It "returns null for a malformed (non-JSON) credentials file" {
    New-Item -ItemType Directory -Path $Script:PnCredDir -Force | Out-Null
    Set-Content -Path $Script:PnCredPath -Value "not valid json" -Encoding UTF8
    Get-PnCredentials | Should -BeNullOrEmpty
  }

  It "returns null when required fields are missing" {
    New-Item -ItemType Directory -Path $Script:PnCredDir -Force | Out-Null
    Set-Content -Path $Script:PnCredPath -Value '{"base_url":"https://acme.example.com"}' -Encoding UTF8
    Get-PnCredentials | Should -BeNullOrEmpty
  }
}

