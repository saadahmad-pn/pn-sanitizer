# Git repository discovery for the repo-context hook (Windows).
# Sourced by scripts/check-repo-context.ps1. Mirrors
# scripts/lib/git-utils.sh function-for-function.
#
# Assumes `git` itself is on PATH -- same assumption the bash version
# makes; this feature is only useful if git is actually installed.

Set-StrictMode -Version Latest

$Script:RepoContextMaxDepth = 5
$Script:RepoContextSkipDirs = @("node_modules", ".next", "dist", "build", ".git")
$Script:RepoContextMaxValueLen = 500

# Hardens raw `git config`/`git branch` output before it is embedded into
# agent-facing context (<GIT>...</GIT> tags in the generated rule file).
# A repo's remote.origin.url or branch name is attacker-controllable data,
# so this:
#   - strips embedded userinfo credentials from URLs (user:token@host -> host)
#   - strips newline/control characters so a value can't break out of its
#     single-line tag or inject extra rule content
#   - caps length so one crafted value can't flood the rule file
function ConvertTo-SanitizedGitValue {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

  $sanitized = [System.Text.RegularExpressions.Regex]::Replace(
    $Value, '(://)[^/@\s]+@', '$1'
  )
  $sanitized = -join ($sanitized.ToCharArray() | Where-Object {
    [char]::IsControl($_) -eq $false
  })

  if ($sanitized.Length -gt $Script:RepoContextMaxValueLen) {
    $sanitized = $sanitized.Substring(0, $Script:RepoContextMaxValueLen) + "...<truncated>"
  }
  return $sanitized
}

# Depth-capped recursive walk that stops descending once it finds a .git
# directory, skips known-noisy directories, and never follows a symlink or
# junction (a reparse point planted anywhere under the scan root could
# otherwise walk the scanner outside the intended workspace).
function Find-GitRepos {
  param(
    [Parameter(Mandatory = $true)][string]$StartPath
  )
  $found = New-Object System.Collections.Generic.List[string]
  Find-GitReposInternal -Dir $StartPath -Depth 0 -Found $found
  return $found
}

function Find-GitReposInternal {
  param(
    [Parameter(Mandatory = $true)][string]$Dir,
    [Parameter(Mandatory = $true)][int]$Depth,
    [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Found
  )

  if ($Depth -gt $Script:RepoContextMaxDepth) { return }

  if (Test-Path (Join-Path $Dir ".git") -PathType Container) {
    $Found.Add($Dir)
    return
  }

  $entries = Get-ChildItem -Path $Dir -Directory -Force -ErrorAction SilentlyContinue
  foreach ($entry in $entries) {
    if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
      continue
    }
    if ($Script:RepoContextSkipDirs -contains $entry.Name) {
      continue
    }
    Find-GitReposInternal -Dir $entry.FullName -Depth ($Depth + 1) -Found $Found
  }
}

function Get-GitRemoteUrl {
  param([Parameter(Mandatory = $true)][string]$RepoPath)
  $url = (git -C $RepoPath config --get remote.origin.url 2>$null)
  if (-not $url) { $url = "No remote" }
  return (ConvertTo-SanitizedGitValue -Value $url)
}

function Get-GitCurrentBranch {
  param([Parameter(Mandatory = $true)][string]$RepoPath)
  $branch = (git -C $RepoPath branch --show-current 2>$null)
  if (-not $branch) { $branch = "detached" }
  return (ConvertTo-SanitizedGitValue -Value $branch)
}

# A cheap "has anything changed" signal: the last-write time of .git/HEAD,
# which changes on checkout/branch-switch and (via the ref update it
# triggers) on commit. Returns 0 if it can't be read.
function Get-RepoHeadFingerprint {
  param([Parameter(Mandatory = $true)][string]$RepoPath)
  $headPath = Join-Path $RepoPath ".git\HEAD"
  if (-not (Test-Path $headPath -PathType Leaf)) { return "0" }
  return (Get-Item $headPath).LastWriteTimeUtc.Ticks.ToString()
}

# Removes duplicates, preserving first-seen order.
function Get-UniqueLines {
  param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Lines)
  return @($Lines | Select-Object -Unique)
}
