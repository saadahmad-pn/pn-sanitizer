# Windows mirror of lib/login-detection.sh: detects the Shell tool calls
# that drive the Paradigm Networks login/logout flows and the login skill's
# own configuration check, so check-tool-call.ps1/check-tool-call-record.ps1
# can exempt just those commands from the scan (PN-12153), and the tool
# calls the login skill needs to follow its own background login run while
# Paradigm Networks is still unconfigured. See login-detection.sh's header
# for the full rationale; the security posture is identical.
#
# Matching is a fully anchored grammar over the whole command string, never
# a substring check: any chaining (`;`, `&&`, `|`, a second statement,
# extra parameters) fails the match and falls through to the normal scan. A
# false negative only means the command gets scanned like anything else; a
# false positive would skip scanning attacker-controlled content, which the
# grammar is built to make structurally impossible.
#
# The Windows command shape the skill, check-session.ps1 and
# check-tool-call.ps1 all hand the agent is:
#
#   & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "<scripts-dir>\login.ps1" -BaseUrl <url>
#
# Accepted variations: the interpreter as a bare name (powershell,
# powershell.exe, pwsh, pwsh.exe) or that exact Windows PowerShell path
# (literal $env:SystemRoot or its expanded value); any of -NoProfile,
# -NonInteractive, -ExecutionPolicy Bypass, in any order; or no interpreter
# at all (`& "<path>\login.ps1" -BaseUrl <url>`). The interpreter is never
# an arbitrary path, so a planted powershell.exe can't qualify.

Set-StrictMode -Version Latest

# Same contract as login-detection.sh's PN_LOGIN_INIT_BASE_URL_RE: scheme +
# host (+ optional port), no path/query/fragment, and none of the
# characters that are also shell metacharacters.
$Script:PnLoginInitBaseUrlPattern = '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$'

# A script path token: quoted (double or single) or bare. Excludes every
# character PowerShell would expand or treat as syntax inside a
# double-quoted string ($, backtick) or between statements, so the path is
# always taken literally. Quoted paths may contain spaces
# (C:\Users\Jane Doe\...); bare ones may not.
$Script:PnScriptPathToken = '(?:"(?<path>[^"''`$;|&<>()\r\n]+)"|''(?<path>[^"''`$;|&<>()\r\n]+)''|(?<path>[^\s"''`$;|&<>()]+))'

$Script:PnInterpreterFlags = '(?:\s+(?:-NoProfile|-NonInteractive|-ExecutionPolicy\s+Bypass))*'

# Get-PnPowerShellInterpreterPattern
# Built per call (not cached) so tests can vary $env:SystemRoot.
function Get-PnPowerShellInterpreterPattern {
  $names = @('powershell', 'powershell\.exe', 'pwsh', 'pwsh\.exe')
  $fullPaths = New-Object System.Collections.Generic.List[string]
  $fullPaths.Add([regex]::Escape('$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe'))
  if ($env:SystemRoot) {
    $fullPaths.Add([regex]::Escape((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')))
  }
  $quoted = ($fullPaths | ForEach-Object { "`"$_`"|'$_'|$_" }) -join '|'
  return "(?:&\s*)?(?:$($names -join '|')|$quoted)"
}

# Resolve-PnOwnScript -Path <path> -ScriptDir <dir> -Basename <name>
# The command's script path must resolve to exactly <ScriptDir>\<Basename>
# -- THIS installed plugin instance's own script, not any same-named file
# planted elsewhere. Case-insensitive: Windows paths are.
function Resolve-PnOwnScript {
  param(
    [string]$Path,
    [string]$ScriptDir,
    [string]$Basename
  )
  if (-not $Path -or -not $ScriptDir) { return $false }

  $leaf = ($Path -split '[\\/]')[-1]
  if (-not [string]::Equals($leaf, $Basename, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

  try {
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $expected = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir $Basename))
  } catch {
    return $false
  }
  return [string]::Equals($resolved, $expected, [System.StringComparison]::OrdinalIgnoreCase)
}

# Get-PnScriptInvocationPath -Command <cmd> -ArgsPattern <regex>
# Matches (interpreter flags -File)? <path> <args>, anchored end to end.
# Returns @{ Path; Url } on a match (Url only when ArgsPattern captures
# one), $null otherwise.
function Get-PnScriptInvocationPath {
  param(
    [string]$Command,
    [string]$ArgsPattern
  )
  if (-not $Command) { return $null }

  $interpreter = Get-PnPowerShellInterpreterPattern
  $viaInterpreter = "^\s*$interpreter$($Script:PnInterpreterFlags)\s+-File\s+$($Script:PnScriptPathToken)$ArgsPattern\s*$"
  $direct = "^\s*(?:&\s*)?$($Script:PnScriptPathToken)$ArgsPattern\s*$"

  foreach ($pattern in @($viaInterpreter, $direct)) {
    $m = [regex]::Match($Command, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $url = ""
      if ($m.Groups['url'].Success) { $url = $m.Groups['url'].Value }
      return @{ Path = $m.Groups['path'].Value; Url = $url }
    }
  }
  return $null
}

# Test-PnLoginInitiationCommand -ToolName -Command -ScriptDir
# See skills/paradigmnetworks-login/SKILL.md step 4 (Windows).
function Test-PnLoginInitiationCommand {
  param([string]$ToolName, [string]$Command, [string]$ScriptDir)
  if ($ToolName -ne "Shell") { return $false }

  $urlArg = '\s+-BaseUrl\s+(?:"(?<url>[^"\s]+)"|''(?<url>[^''\s]+)''|(?<url>[^\s"'']+))'
  $match = Get-PnScriptInvocationPath -Command $Command -ArgsPattern $urlArg
  if ($null -eq $match) { return $false }
  if ($match.Url -notmatch $Script:PnLoginInitBaseUrlPattern) { return $false }
  return (Resolve-PnOwnScript -Path $match.Path -ScriptDir $ScriptDir -Basename "login.ps1")
}

# Test-PnBareScriptInvocation -ToolName -Command -ScriptDir -Basename
# logout.ps1 and check-configured.ps1 take no arguments at all.
function Test-PnBareScriptInvocation {
  param([string]$ToolName, [string]$Command, [string]$ScriptDir, [string]$Basename)
  if ($ToolName -ne "Shell") { return $false }

  $match = Get-PnScriptInvocationPath -Command $Command -ArgsPattern ''
  if ($null -eq $match) { return $false }
  return (Resolve-PnOwnScript -Path $match.Path -ScriptDir $ScriptDir -Basename $Basename)
}

# Get-PnLoginLogoutExemptReason -ToolName -Command -ScriptDir
# Returns the exemption label ("login_initiation_exempt", "logout_exempt",
# "check_configured_exempt") or "" -- same labels as the bash side, so the
# audit log reads the same on both platforms.
function Get-PnLoginLogoutExemptReason {
  param([string]$ToolName, [string]$Command, [string]$ScriptDir)

  if (Test-PnLoginInitiationCommand -ToolName $ToolName -Command $Command -ScriptDir $ScriptDir) {
    return "login_initiation_exempt"
  }
  if (Test-PnBareScriptInvocation -ToolName $ToolName -Command $Command -ScriptDir $ScriptDir -Basename "logout.ps1") {
    return "logout_exempt"
  }
  if (Test-PnBareScriptInvocation -ToolName $ToolName -Command $Command -ScriptDir $ScriptDir -Basename "check-configured.ps1") {
    return "check_configured_exempt"
  }
  return ""
}

# Test-PnLoginWaitCall -ToolName -Command -FilePath
# Mirrors pn_is_login_wait_call: Cursor's AwaitShell, a Read of a Cursor
# terminal output file (<HOME>\.cursor\projects\<project>\terminals\<id>.txt),
# and a bare sleep between checks. Consulted only on check-tool-call.ps1's
# not-configured path.
function Test-PnLoginWaitCall {
  param([string]$ToolName, [string]$Command, [string]$FilePath)

  switch ($ToolName) {
    "AwaitShell" { return $true }
    "Read" {
      if (-not $FilePath -or -not $HOME) { return $false }
      if ($FilePath.Contains("..")) { return $false }
      $normalized = $FilePath -replace '\\', '/'
      $prefix = ((Join-Path $HOME ".cursor/projects") -replace '\\', '/').TrimEnd('/') + '/'
      if (-not $normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
      $rest = $normalized.Substring($prefix.Length)
      return ($rest -match '^[A-Za-z0-9._-]+/terminals/[0-9]+\.txt$')
    }
    "Shell" {
      if (-not $Command) { return $false }
      return ($Command -match '^\s*(?:Start-Sleep|sleep)(?:\s+-(?:Seconds|s|Milliseconds|ms))?\s+[0-9]{1,6}(?:\.[0-9]+)?\s*$')
    }
    default { return $false }
  }
}
