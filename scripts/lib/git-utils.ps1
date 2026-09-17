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
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Found
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

# Same as Get-GitRemoteUrl, but returns an empty string (not the "No
# remote" placeholder) when there's no configured origin. Get-GitRemoteUrl's
# fallback text is meant for human-readable <GIT>...</GIT> context injection
# (check-repo-context.ps1); the detections API contract (design-ideas/
# Cursor_PrePush_Governance_Enforcement_Plan.md 0.5.3) instead requires
# GitRepoUrl to be a genuinely empty field when RepoPath isn't a git repo or
# has no remote.
function Get-GitRemoteUrlOrEmpty {
  param([Parameter(Mandatory = $true)][string]$RepoPath)
  $url = (git -C $RepoPath config --get remote.origin.url 2>$null)
  if (-not $url) { return "" }
  return (ConvertTo-SanitizedGitValue -Value $url)
}

# Same rationale as Get-GitRemoteUrlOrEmpty above, for GitBranch.
function Get-GitCurrentBranchOrEmpty {
  param([Parameter(Mandatory = $true)][string]$RepoPath)
  $branch = (git -C $RepoPath branch --show-current 2>$null)
  if (-not $branch) { return "" }
  return (ConvertTo-SanitizedGitValue -Value $branch)
}

# Returns repo-relative paths (string array) of every file touched by a
# commit reachable from the current branch's HEAD but not reachable from
# ANY remote-tracking branch. Mirrors resolve_unpushed_changed_files in
# git-utils.sh -- see that function's comment for the full rationale (why
# this is used for both git.push and git.pr_create, and its one known
# limitation around cherry-picked commits).
function Get-UnpushedChangedFiles {
  param([Parameter(Mandatory = $true)][string]$RepoPath)
  $output = & git -C $RepoPath log HEAD --not --remotes --name-only --pretty=format: 2>$null
  $paths = @($output | Where-Object { $_ }) | Select-Object -Unique
  return @($paths)
}

# Returns repo-relative paths (string array) of every file staged for the
# next commit (excluding deletions). Mirrors resolve_staged_changed_files
# in git-utils.sh -- see that function's comment for why this is the right
# file set for a git.commit event.
function Get-StagedChangedFiles {
  param([Parameter(Mandatory = $true)][string]$RepoPath)
  $output = & git -C $RepoPath diff --cached --name-only --diff-filter=d 2>$null
  return @($output | Where-Object { $_ })
}

# Returns repo-relative paths (string array) of every file that differs
# between the current branch and the PR's base branch. Mirrors
# resolve_pr_create_changed_files in git-utils.sh -- see that function's
# comment for the full base-branch resolution order and why
# Get-UnpushedChangedFiles is the wrong comparison once the branch has
# already been pushed (the common flow immediately before `gh pr create`).
function Get-PrCreateChangedFiles {
  param(
    [Parameter(Mandatory = $true)][string]$RepoPath,
    [Parameter(Mandatory = $true)][string]$CommandText
  )
  $remote = "origin"

  $baseBranch = ""
  if ($CommandText -match '(--base|-B)\s+(\S+)') {
    $baseBranch = $Matches[2]
  }

  $baseRef = ""
  if ($baseBranch) {
    & git -C $RepoPath rev-parse --verify -q "$remote/$baseBranch" *> $null
    if ($LASTEXITCODE -eq 0) {
      $baseRef = "$remote/$baseBranch"
    } else {
      & git -C $RepoPath rev-parse --verify -q $baseBranch *> $null
      if ($LASTEXITCODE -eq 0) {
        $baseRef = $baseBranch
      }
    }
  }

  if (-not $baseRef) {
    $symbolic = (& git -C $RepoPath symbolic-ref -q "refs/remotes/$remote/HEAD" 2>$null)
    if ($symbolic) {
      $baseRef = $symbolic -replace '^refs/remotes/', ''
    }
  }

  if (-not $baseRef) {
    foreach ($candidate in @("main", "master")) {
      & git -C $RepoPath rev-parse --verify -q "$remote/$candidate" *> $null
      if ($LASTEXITCODE -eq 0) {
        $baseRef = "$remote/$candidate"
        break
      }
    }
  }

  if (-not $baseRef) {
    return Get-UnpushedChangedFiles -RepoPath $RepoPath
  }

  $mergeBase = (& git -C $RepoPath merge-base $baseRef HEAD 2>$null)
  if (-not $mergeBase) {
    return Get-UnpushedChangedFiles -RepoPath $RepoPath
  }

  $output = & git -C $RepoPath diff --name-only --diff-filter=d "$mergeBase..HEAD" 2>$null
  $paths = @($output | Where-Object { $_ }) | Select-Object -Unique
  return @($paths)
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
