# End-to-end Pester tests for the Windows hook scripts: each test runs the
# real scripts/<hook>.ps1 as a separate process with a JSON payload on
# stdin, exactly as Cursor does via run-hook.cmd -- the Windows mirror of
# test/test-hooks.sh. No network: logged-out paths need none, and the
# logged-in paths point at a closed local port.
#
# Every child process gets an isolated, disposable home (HOME/USERPROFILE)
# and TEMP, and inherits no PARADIGM_NETWORKS_* variables, so a developer's
# real login is never read or touched. BeforeAll refuses to run if the
# child's $HOME does not resolve to that isolated folder.
#
# Run with: pwsh -NoProfile -Command "Invoke-Pester -Path test/pester -Output Detailed"

BeforeAll {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $Script:ScriptsDir = Join-Path $RepoRoot "scripts"
  $Script:Exe = (Get-Process -Id $PID).Path
  $Script:IsWin = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

  $Script:TestHome = Join-Path ([System.IO.Path]::GetTempPath()) "pn-pester-hooks-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
  New-Item -ItemType Directory -Path $Script:TestHome -Force | Out-Null

  # The scripts call curl.exe (inbox on Windows 10+). Elsewhere, point that
  # name at the system curl for these tests only.
  $Script:ShimDir = Join-Path $Script:TestHome "bin"
  New-Item -ItemType Directory -Path $Script:ShimDir -Force | Out-Null
  if (-not $Script:IsWin) {
    $curl = (Get-Command curl -CommandType Application | Select-Object -First 1).Source
    New-Item -ItemType SymbolicLink -Path (Join-Path $Script:ShimDir "curl.exe") -Target $curl -Force | Out-Null
  }

  function Invoke-Hook {
    param([string]$Name, [string]$Payload, [hashtable]$ExtraEnv = @{}, [string]$Command = "")
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Script:Exe
    if ($Command) {
      $psi.Arguments = "-NoProfile -NonInteractive -Command `"$Command`""
    } else {
      $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $Script:ScriptsDir "$Name.ps1")`""
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($k in @($psi.EnvironmentVariables.Keys)) {
      if ($k -like "PARADIGM_NETWORKS_*") { $psi.EnvironmentVariables.Remove($k) }
    }
    $psi.EnvironmentVariables["HOME"] = $Script:TestHome
    $psi.EnvironmentVariables["USERPROFILE"] = $Script:TestHome
    $psi.EnvironmentVariables["TEMP"] = $Script:TestHome
    $psi.EnvironmentVariables["TMP"] = $Script:TestHome
    $psi.EnvironmentVariables["PATH"] = "$($Script:ShimDir)$([System.IO.Path]::PathSeparator)$($psi.EnvironmentVariables["PATH"])"
    foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = $ExtraEnv[$k] }

    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($Payload)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $Script:LastStderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return $out.Trim()
  }

  function New-Payload([hashtable]$Fields) {
    $base = @{ conversation_id = "sess-1"; agent_message = "test" }
    foreach ($k in $Fields.Keys) { $base[$k] = $Fields[$k] }
    return ($base | ConvertTo-Json -Compress -Depth 10)
  }

  function Set-LoggedIn([string]$BaseUrl) {
    $credDir = Join-Path $Script:TestHome ".pn"
    New-Item -ItemType Directory -Path $credDir -Force | Out-Null
    $expires = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
    $creds = @{ base_url = $BaseUrl; access_token = "tok"; refresh_token = "r"; expires_at = $expires } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText((Join-Path $credDir "credentials.json"), $creds)
  }

  function Set-LoggedOut {
    Remove-Item -Path (Join-Path $Script:TestHome ".pn/credentials.json") -Force -ErrorAction SilentlyContinue
  }

  # Safety: the child process must see the isolated home, or a real
  # credentials file could be read.
  $childHome = Invoke-Hook -Command '$HOME' -Payload ""
  if ([System.IO.Path]::GetFullPath($childHome).TrimEnd('\', '/') -ne [System.IO.Path]::GetFullPath($Script:TestHome).TrimEnd('\', '/')) {
    throw "SAFETY ABORT: child process HOME ($childHome) is not the isolated test home ($($Script:TestHome))."
  }
}

AfterAll {
  if ($Script:TestHome -and (Test-Path $Script:TestHome)) {
    Remove-Item -Recurse -Force $Script:TestHome -ErrorAction SilentlyContinue
  }
}

Describe "check-session.ps1" {
  BeforeEach { Set-LoggedOut }

  It "gives a logged-out agent a login command with -BaseUrl and the scripts directory" {
    $ctx = (Invoke-Hook -Name "check-session" -Payload (New-Payload @{}) | ConvertFrom-Json).additional_context
    $ctx | Should -Match ([regex]::Escape('-File "' + (Join-Path $Script:ScriptsDir "login.ps1") + '" -BaseUrl <their-base-url>'))
    $ctx | Should -Not -Match '--base-url'
    $ctx | Should -Match 'full_network'
    $ctx | Should -Match ([regex]::Escape("Paradigm Networks plugin scripts directory: $($Script:ScriptsDir)"))
  }

  It "carries only the scripts directory when logged in with a recent scan" {
    Set-LoggedIn "https://acme.paradigmnetworks.ai"
    $stateDir = Join-Path $Script:TestHome ".paradigm-networks"
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    [System.IO.File]::WriteAllText((Join-Path $stateDir "anomaly_state.json"), "{`"consecutive_anomaly_count`": 0, `"last_successful_scan`": $now}")
    $ctx = (Invoke-Hook -Name "check-session" -Payload (New-Payload @{}) | ConvertFrom-Json).additional_context
    $ctx | Should -Be "Paradigm Networks plugin scripts directory: $($Script:ScriptsDir)"
  }

  It "writes the local session file, and check-session-end.ps1 removes it" {
    $payload = New-Payload @{ conversation_id = "sess-meta" }
    Invoke-Hook -Name "check-session" -Payload $payload | Out-Null
    $file = Join-Path $Script:TestHome ".paradigm-networks/sessions/sess-meta.json"
    Test-Path $file | Should -BeTrue
    ((Get-Content $file -Raw) | ConvertFrom-Json).SessionId | Should -Be "sess-meta"

    Invoke-Hook -Name "check-session-end" -Payload $payload | Should -Be "{}"
    Test-Path $file | Should -BeFalse
  }

  It "refuses a session id that would escape the sessions folder" {
    Invoke-Hook -Name "check-session" -Payload (New-Payload @{ conversation_id = "../escape" }) | Out-Null
    Test-Path (Join-Path $Script:TestHome ".paradigm-networks/escape.json") | Should -BeFalse
  }
}

Describe "check-tool-call.ps1 while logged out" {
  BeforeEach { Set-LoggedOut }

  It "allows the exact login command the start-up message gives the agent" {
    $ctx = (Invoke-Hook -Name "check-session" -Payload (New-Payload @{}) | ConvertFrom-Json).additional_context
    $loginLine = ($ctx -split "`n" | Where-Object { $_ -match 'login\.ps1' } | Select-Object -First 1).Trim()
    $command = $loginLine -replace '<their-base-url>', 'https://acme.paradigmnetworks.ai'
    $r = Invoke-Hook -Name "check-tool-call" -Payload (New-Payload @{ tool_name = "Shell"; tool_input = @{ command = $command } }) | ConvertFrom-Json
    $r.permission | Should -Be "allow"
  }

  It "blocks the same command with something chained on" {
    $command = '& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "' + (Join-Path $Script:ScriptsDir "login.ps1") + '" -BaseUrl https://acme.paradigmnetworks.ai; Remove-Item x'
    (Invoke-Hook -Name "check-tool-call" -Payload (New-Payload @{ tool_name = "Shell"; tool_input = @{ command = $command } }) | ConvertFrom-Json).permission | Should -Be "deny"
  }

  It "allows the logout and configuration-check commands" {
    foreach ($script in @("logout.ps1", "check-configured.ps1")) {
      $command = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Script:ScriptsDir $script) + '"'
      (Invoke-Hook -Name "check-tool-call" -Payload (New-Payload @{ tool_name = "Shell"; tool_input = @{ command = $command } }) | ConvertFrom-Json).permission | Should -Be "allow"
    }
  }

  It "allows the login skill to wait on its run: <Name>" -ForEach @(
    @{ Name = "AwaitShell"; Tool = "AwaitShell"; In = @{ shellId = "1"; timeoutMs = "15000" } }
    @{ Name = "terminal Read"; Tool = "Read"; In = "TERMINAL" }
    @{ Name = "Start-Sleep"; Tool = "Shell"; In = @{ command = "Start-Sleep -Seconds 5" } }
  ) {
    $toolInput = if ($In -eq "TERMINAL") { @{ file_path = (Join-Path $Script:TestHome ".cursor/projects/p/terminals/42.txt") } } else { $In }
    (Invoke-Hook -Name "check-tool-call" -Payload (New-Payload @{ tool_name = $Tool; tool_input = $toolInput }) | ConvertFrom-Json).permission | Should -Be "allow"
  }

  It "blocks a write and tells the agent the exact Windows login command" {
    $r = Invoke-Hook -Name "check-tool-call" -Payload (New-Payload @{ tool_name = "Write"; tool_input = @{ file_path = "a.txt"; contents = "x" } }) | ConvertFrom-Json
    $r.permission | Should -Be "deny"
    $r.agent_message | Should -Match ([regex]::Escape('-File "' + (Join-Path $Script:ScriptsDir "login.ps1") + '" -BaseUrl <their-base-url>'))
    $r.agent_message | Should -Match 'full_network'
  }

  It "blocks a chained sleep and a read of any other file" {
    (Invoke-Hook -Name "check-tool-call" -Payload (New-Payload @{ tool_name = "Shell"; tool_input = @{ command = "Start-Sleep 5; Get-Content x" } }) | ConvertFrom-Json).permission | Should -Be "deny"
    (Invoke-Hook -Name "check-tool-call" -Payload (New-Payload @{ tool_name = "Read"; tool_input = @{ file_path = (Join-Path $Script:TestHome ".pn/credentials.json") } }) | ConvertFrom-Json).permission | Should -Be "deny"
  }

  It "handles Cursor's Windows-style cwd (/c:/...) without an error" {
    $r = Invoke-Hook -Name "check-tool-call" -Payload (New-Payload @{ tool_name = "AwaitShell"; tool_input = @{ shellId = "1" }; cwd = "/c:/Users/shoaib/proj"; workspace_roots = @("/c:/Users/shoaib/proj") }) | ConvertFrom-Json
    $r.permission | Should -Be "allow"
    $Script:LastStderr | Should -BeNullOrEmpty
  }

  It "allows a payload that is not valid JSON" {
    (Invoke-Hook -Name "check-tool-call" -Payload "not json" | ConvertFrom-Json).permission | Should -Be "allow"
  }

  It "records each decision in the audit log" {
    Invoke-Hook -Name "check-tool-call" -Payload (New-Payload @{ tool_name = "AwaitShell"; tool_input = @{ shellId = "9" } }) | Out-Null
    $last = Get-Content (Join-Path $Script:TestHome ".paradigm-networks/audit.jsonl") | Select-Object -Last 1 | ConvertFrom-Json
    $last.reason | Should -Be "login_wait_unconfigured"
  }
}

Describe "check-tool-call.ps1 while logged in, scanner unreachable" {
  BeforeAll { Set-LoggedIn "http://127.0.0.1:9" }
  AfterAll { Set-LoggedOut }

  It "blocks by default (failure mode closed)" {
    $r = Invoke-Hook -Name "check-tool-call" -Payload (New-Payload @{ tool_name = "Shell"; tool_input = @{ command = "dir" } }) | ConvertFrom-Json
    $r.permission | Should -Be "deny"
    $r.user_message | Should -Match "connection failed"
  }

  It "allows with a warning when PARADIGM_NETWORKS_FAILURE_MODE=allow" {
    $r = Invoke-Hook -Name "check-tool-call" -Payload (New-Payload @{ tool_name = "Shell"; tool_input = @{ command = "dir" } }) -ExtraEnv @{ PARADIGM_NETWORKS_FAILURE_MODE = "allow" } | ConvertFrom-Json
    $r.permission | Should -Be "allow"
    $r.user_message | Should -Match "WITHOUT a security scan"
  }

  It "still lets the waiting steps through only when logged out (they are scanned when logged in)" {
    $r = Invoke-Hook -Name "check-tool-call" -Payload (New-Payload @{ tool_name = "Shell"; tool_input = @{ command = "Start-Sleep 1" } }) | ConvertFrom-Json
    $r.permission | Should -Be "deny"
  }
}

Describe "Observational hooks always answer {}" {
  It "<Name>" -ForEach @(
    @{ Name = "check-tool-call-record"; Payload = '{"tool_name":"Shell","tool_input":{"command":"dir"},"tool_output":"x","tool_use_id":"t1","conversation_id":"s"}' }
    @{ Name = "check-turn-complete";    Payload = '{"text":"answer","conversation_id":"s"}' }
    @{ Name = "check-session-end";      Payload = 'not json' }
  ) {
    Invoke-Hook -Name $Name -Payload $Payload | Should -Be "{}"
  }
}

Describe "check-prompt.ps1 while logged out" {
  BeforeAll { Set-LoggedOut }

  It "lets the prompt through with a login hint" {
    $r = Invoke-Hook -Name "check-prompt" -Payload (New-Payload @{ prompt = "hello" }) | ConvertFrom-Json
    $r.continue | Should -BeTrue
    $r.user_message | Should -Match "not configured"
  }
}
