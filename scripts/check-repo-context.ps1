# beforeSubmitPrompt hook (Windows): write git repo/branch context into a
# workspace rule file so Cursor folds it into the system prompt of the
# next real model request. Mirrors scripts/check-repo-context.sh -- see
# that file's header comment for the full design rationale (why a rule
# file instead of injecting context directly, why the cache, why the
# consumer only needs the first <GIT> tag).
#
# This hook has nothing to gate -- it never blocks prompt submission.

Set-StrictMode -Version Latest
# "Continue" (not "Stop"): a hiccup on one repo/root should not abort
# processing of the rest -- mirrors the bash version's per-step
# `2>/dev/null || true` tolerance. The `finally` block below is what
# actually guarantees {"continue": true} always gets printed, regardless
# of this setting.
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "lib\common.ps1")
. (Join-Path $ScriptDir "lib\git-utils.ps1")

$CacheDir = Join-Path $HOME ".paradigm-scanner\repo-context-cache"

# Windows equivalent of the bash version's is_safe_workspace_root: refuses
# to write a rule file or touch .gitignore inside a system directory, or
# at the bare root of a drive.
function Test-SafeWorkspaceRoot {
  param([Parameter(Mandatory = $true)][string]$RootPath)

  if ($RootPath -match '^[A-Za-z]:\\?$') {
    return $false
  }
  if ($RootPath -match '^[A-Za-z]:\\(Windows|Program Files|Program Files \(x86\)|ProgramData)(\\|$)') {
    return $false
  }
  return $true
}

function Confirm-Gitignored {
  param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$RelativePath
  )
  $gitignorePath = Join-Path $WorkspaceRoot ".gitignore"
  if (Test-Path $gitignorePath -PathType Leaf) {
    $existing = Get-Content -Path $gitignorePath -ErrorAction SilentlyContinue
    if ($existing -contains $RelativePath) {
      return
    }
  }
  # SilentlyContinue, not Stop: a failure updating one root's .gitignore
  # (e.g. a transient AV file lock, observed as this exact class of issue
  # elsewhere in this plugin) must not turn into a terminating error that
  # escapes this function and aborts the whole workspace_roots loop in
  # check-repo-context.ps1, skipping every remaining root.
  Add-Content -Path $gitignorePath -Value "`n# Added by paradigm-scanner -- generated, workspace-local agent context`n$RelativePath" -Encoding UTF8 -ErrorAction SilentlyContinue
}

# A cheap "has anything changed" signal: the root's own last-write time
# (catches new top-level repos being added/removed) plus each known
# repo's HEAD fingerprint (catches checkouts/commits). Not exhaustive --
# see the trade-off note in check-repo-context.sh.
function Get-RootFingerprint {
  param(
    [Parameter(Mandatory = $true)][string]$RootPath,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$RepoPaths
  )
  $fp = (Get-Item $RootPath).LastWriteTimeUtc.Ticks.ToString()
  foreach ($repoPath in $RepoPaths) {
    if (-not $repoPath) { continue }
    $fp = "$fp`:$(Get-RepoHeadFingerprint -RepoPath $repoPath)"
  }
  return $fp
}

function Get-CacheKeyForRoot {
  param([Parameter(Mandatory = $true)][string]$RootPath)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($RootPath)
  $hash = [System.Security.Cryptography.MD5]::Create().ComputeHash($bytes)
  return ([System.BitConverter]::ToString($hash) -replace '-', '')
}

try {
  $rawInput = Get-StdinText
  if (-not $rawInput) { throw "no input" }
  $payload = $rawInput | ConvertFrom-Json -ErrorAction Stop
  $workspaceRoots = @(Get-JsonProperty -InputObject $payload -Name "workspace_roots" -Default @())
  if ($workspaceRoots.Count -eq 0) { throw "no workspace_roots" }

  if (-not (Test-Path $CacheDir)) {
    # SilentlyContinue: if this fails, the cache-skip optimization below
    # just won't apply this run (falls through to a full walk every time)
    # -- not ideal, but not worth letting it abort the whole script when
    # the fallback behavior is already safe.
    New-Item -ItemType Directory -Path $CacheDir -Force -ErrorAction SilentlyContinue | Out-Null
  }

  foreach ($root in $workspaceRoots) {
    if (-not $root) { continue }
    if (-not (Test-Path $root -PathType Container)) { continue }
    if (-not (Test-SafeWorkspaceRoot -RootPath $root)) { continue }

    $root = (Resolve-Path $root -ErrorAction SilentlyContinue).Path
    if (-not $root) { continue }
    if (-not (Test-SafeWorkspaceRoot -RootPath $root)) { continue }

    $cacheFile = Join-Path $CacheDir (Get-CacheKeyForRoot -RootPath $root)

    $skip = $false
    if (Test-Path $cacheFile -PathType Leaf) {
      # @() here too: Get-Content returns a bare scalar, not a one-element
      # array, when the file has exactly one line -- a cache file recording
      # zero repos for a root produces exactly that (just the fingerprint
      # line), and .Count on a scalar throws the same way it did above.
      $cacheLines = @(Get-Content -Path $cacheFile -ErrorAction SilentlyContinue)
      if ($cacheLines -and $cacheLines.Count -gt 1) {
        $lastFingerprint = $cacheLines[0]
        $lastRepos = @($cacheLines | Select-Object -Skip 1)
        if ($lastRepos.Count -gt 0) {
          $currentFingerprint = Get-RootFingerprint -RootPath $root -RepoPaths $lastRepos
          if ($currentFingerprint -eq $lastFingerprint) {
            $skip = $true
          }
        }
      }
    }
    if ($skip) { continue }

    # @(...) at the call site matters, not just inside the functions: a
    # single-item PowerShell array/List crossing a function-return boundary
    # gets silently unwrapped into a bare scalar unless the caller also
    # forces array-ness -- observed directly: a workspace with exactly one
    # repo turned $uniqueRepos into a plain string, and "$uniqueRepos.Count"
    # then threw (a string has no .Count), silently caught by the fail-open
    # trap below, with the rule file never getting written at all.
    $foundRepos = @(Find-GitRepos -StartPath $root)
    $uniqueRepos = @(Get-UniqueLines -Lines $foundRepos)

    if ($uniqueRepos.Count -eq 0) {
      $repoList = "- No git repositories detected in this workspace."
    } else {
      $lines = New-Object System.Collections.Generic.List[string]
      $i = 1
      foreach ($repoPath in $uniqueRepos) {
        $remote = Get-GitRemoteUrl -RepoPath $repoPath
        $branch = Get-GitCurrentBranch -RepoPath $repoPath
        $lines.Add("$i. <GIT>$remote|$branch</GIT>")
        $i++
      }
      $repoList = ($lines -join "`n")
    }

    $ruleDir = Join-Path $root ".cursor\rules"
    $ruleFile = Join-Path $ruleDir "paradigm-repo-context.mdc"
    $ruleContent = "---`nalwaysApply: true`n---`n`n### Available Repositories:`n$repoList`n"

    # Explicit -ErrorAction Stop + continue, not SilentlyContinue: unlike
    # the .gitignore update, this write is the actual point of this
    # script. If it fails (e.g. a transient AV file lock, the same class
    # of issue seen elsewhere in this plugin), the cache entry written
    # below must not claim this root succeeded -- so skip straight to the
    # next root instead of silently treating a failed write as done.
    try {
      if (-not (Test-Path $ruleDir)) {
        New-Item -ItemType Directory -Path $ruleDir -Force -ErrorAction Stop | Out-Null
      }
      Set-Content -Path $ruleFile -Value $ruleContent -Encoding UTF8 -NoNewline -ErrorAction Stop
    } catch {
      continue
    }

    Confirm-Gitignored -WorkspaceRoot $root -RelativePath ".cursor/rules/paradigm-repo-context.mdc" | Out-Null

    # SilentlyContinue: this is purely a "skip the next full walk" cache --
    # the rule file itself is already written by this point, so a failure
    # here just means the next run redoes a full scan instead of skipping
    # it. Not worth letting it abort processing of any remaining roots.
    $newFingerprint = Get-RootFingerprint -RootPath $root -RepoPaths $uniqueRepos
    @($newFingerprint) + $uniqueRepos | Set-Content -Path $cacheFile -Encoding UTF8 -ErrorAction SilentlyContinue
  }
} catch {
  # Fail open, always -- this hook has nothing to gate.
} finally {
  Write-Output '{"continue": true}'
}
