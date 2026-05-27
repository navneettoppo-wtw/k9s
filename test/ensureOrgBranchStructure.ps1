<#
.SYNOPSIS
    Ensures every active repo in the wtw-RiskTechnology org has develop and
    release branches, and that develop is the default branch.

.DESCRIPTION
    For each non-archived repo in the org this script will:
      1. Identify the current default branch (source for new branches).
      2. Create 'develop' from the default branch if it does not exist.
      3. Create 'release' from the default branch if it does not exist.
      4. Set 'develop' as the default branch if it is not already.

    A dry-run plan is shown first. You must confirm before any changes are made.
    Requires: GitHub CLI (gh) authenticated as an org admin.

.PARAMETER Org
    GitHub organisation name. Defaults to wtw-RiskTechnology.

.PARAMETER DevelopBranch
    Name of the develop branch. Defaults to 'develop'.

.PARAMETER ReleaseBranch
    Name of the release branch. Defaults to 'release'.

.PARAMETER RepoFilter
    Optional wildcard pattern to restrict which repos are processed.
    Example: "rna-sdk-*"

.PARAMETER SkipSetDefault
    If set, the default branch will NOT be changed to develop.

.EXAMPLE
    .\ensureOrgBranchStructure.ps1

.EXAMPLE
    .\ensureOrgBranchStructure.ps1 -RepoFilter "rna-sdk-*" -DryRun

.EXAMPLE
    .\ensureOrgBranchStructure.ps1 -SkipSetDefault
#>

[CmdletBinding()]
param (
    [string] $Org           = "wtw-RiskTechnology",
    [string] $DevelopBranch = "develop",
    [string] $ReleaseBranch = "release",
    [string] $RepoFilter    = "*",
    [switch] $SkipSetDefault
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Auth check
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Pre-flight" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor DarkCyan

gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Not authenticated. Run 'gh auth login' first." -ForegroundColor Red
    exit 1
}
Write-Host "  GitHub CLI: authenticated" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Fetch all non-archived repos
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  Fetching repos in '$Org'..." -ForegroundColor Yellow

$repos = @()
$page  = 1
do {
    $batch = @(gh api "/orgs/$Org/repos?per_page=100&page=$page&type=all" | ConvertFrom-Json)
    $active = @($batch | Where-Object { -not $_.archived })
    $repos += $active
    $page++
} while ($batch.Count -eq 100)

# Apply optional name filter
$repos = @($repos | Where-Object { $_.name -like $RepoFilter })

Write-Host "  $($repos.Count) active repo(s) matched (filter: '$RepoFilter')." -ForegroundColor Green

if ($repos.Count -eq 0) {
    Write-Host "  Nothing to do." -ForegroundColor DarkGray
    exit 0
}

# ---------------------------------------------------------------------------
# Inspect each repo and build a plan
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Inspecting repos..." -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor DarkCyan

# Each plan entry: { Repo; SourceBranch; CreateDevelop; CreateRelease; SetDefault }
$plan = [System.Collections.Generic.List[hashtable]]::new()

foreach ($repo in $repos) {
    $repoName   = $repo.name
    $defaultBranch = $repo.default_branch

    Write-Host ("  {0,-50} default: {1}" -f $repoName, $defaultBranch) -ForegroundColor Gray

    # Check which branches exist
    $branchesRaw = gh api "repos/$Org/$repoName/branches?per_page=100" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    WARNING: Could not fetch branches — skipping. ($branchesRaw)" -ForegroundColor DarkYellow
        continue
    }
    $existingBranches = @($branchesRaw | ConvertFrom-Json | ForEach-Object { $_.name })

    $needDevelop   = $existingBranches -notcontains $DevelopBranch
    $needRelease   = $existingBranches -notcontains $ReleaseBranch
    $needDefault   = (-not $SkipSetDefault) -and ($defaultBranch -ne $DevelopBranch)

    # Source branch to create from:
    # If develop is already there and we only need release, branch from develop.
    # Otherwise branch from whatever the current default is.
    $sourceBranch = if (-not $needDevelop) { $DevelopBranch } else { $defaultBranch }

    if ($needDevelop -or $needRelease -or $needDefault) {
        $plan.Add(@{
            Repo          = $repoName
            SourceBranch  = $sourceBranch
            DefaultBranch = $defaultBranch
            CreateDevelop = $needDevelop
            CreateRelease = $needRelease
            SetDefault    = $needDefault
        })
    } else {
        Write-Host "    -> already OK (develop + release exist, develop is default)" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# Show plan
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Planned changes ($($plan.Count) repo(s) need work)" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor DarkCyan

if ($plan.Count -eq 0) {
    Write-Host "  All repos are already in the desired state. Nothing to do." -ForegroundColor Green
    exit 0
}

foreach ($item in $plan) {
    Write-Host ""
    Write-Host "  $($item.Repo)" -ForegroundColor White
    if ($item.CreateDevelop) {
        Write-Host ("    + Create '{0}' from '{1}'" -f $DevelopBranch, $item.SourceBranch) -ForegroundColor Yellow
    }
    if ($item.CreateRelease) {
        # Release is always branched from develop (once it exists) or the source
        $releaseSource = if ($item.CreateDevelop) { $item.SourceBranch } else { $DevelopBranch }
        Write-Host ("    + Create '{0}' from '{1}'" -f $ReleaseBranch, $releaseSource) -ForegroundColor Yellow
    }
    if ($item.SetDefault) {
        Write-Host ("    * Set default branch to '{0}' (currently '{1}')" -f $DevelopBranch, $item.DefaultBranch) -ForegroundColor Cyan
    }
}

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host ""
$confirm = Read-Host "  Proceed with the above changes? (yes/no)"
if ($confirm -notmatch '^y(es)?$') {
    Write-Host ""
    Write-Host "  Aborted. No changes made." -ForegroundColor DarkYellow
    exit 0
}

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Applying changes" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor DarkCyan

$successCount = 0
$failCount    = 0

foreach ($item in $plan) {
    $repoName = $item.Repo
    $repoFull = "$Org/$repoName"

    Write-Host ""
    Write-Host "  $repoName" -ForegroundColor White

    # Resolve SHA for the source branch once
    $shaJson = gh api "repos/$repoFull/git/ref/heads/$($item.SourceBranch)" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    ERROR: Could not resolve SHA for '$($item.SourceBranch)': $shaJson" -ForegroundColor Red
        $failCount++
        continue
    }
    $sourceSha = ($shaJson | ConvertFrom-Json).object.sha

    $repoOk = $true

    # -- Create develop -------------------------------------------------------
    if ($item.CreateDevelop) {
        $result = gh api "repos/$repoFull/git/refs" `
            --method POST `
            -f ref="refs/heads/$DevelopBranch" `
            -f sha="$sourceSha" 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Host ("    ERROR: Could not create '{0}': {1}" -f $DevelopBranch, $result) -ForegroundColor Red
            $repoOk = $false
        } else {
            Write-Host ("    + Created '{0}'" -f $DevelopBranch) -ForegroundColor Green
            # Re-resolve SHA from develop for release (they share the same SHA here but be explicit)
            $sourceSha = ($result | ConvertFrom-Json).object.sha
        }
    }

    # -- Create release -------------------------------------------------------
    if ($item.CreateRelease -and $repoOk) {
        # Always branch release from develop (which now exists after step above)
        $developShaJson = gh api "repos/$repoFull/git/ref/heads/$DevelopBranch" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("    ERROR: Could not resolve SHA for '{0}': {1}" -f $DevelopBranch, $developShaJson) -ForegroundColor Red
            $repoOk = $false
        } else {
            $developSha = ($developShaJson | ConvertFrom-Json).object.sha

            $result = gh api "repos/$repoFull/git/refs" `
                --method POST `
                -f ref="refs/heads/$ReleaseBranch" `
                -f sha="$developSha" 2>&1

            if ($LASTEXITCODE -ne 0) {
                Write-Host ("    ERROR: Could not create '{0}': {1}" -f $ReleaseBranch, $result) -ForegroundColor Red
                $repoOk = $false
            } else {
                Write-Host ("    + Created '{0}'" -f $ReleaseBranch) -ForegroundColor Green
            }
        }
    }

    # -- Set default branch ---------------------------------------------------
    if ($item.SetDefault -and $repoOk) {
        $result = gh api "repos/$repoFull" `
            --method PATCH `
            -f default_branch="$DevelopBranch" 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Host ("    ERROR: Could not set default branch: {0}" -f $result) -ForegroundColor Red
            $repoOk = $false
        } else {
            Write-Host ("    * Default branch set to '{0}'" -f $DevelopBranch) -ForegroundColor Green
        }
    }

    if ($repoOk) { $successCount++ } else { $failCount++ }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host ("  Total repos processed : {0}" -f $plan.Count)   -ForegroundColor White
Write-Host ("  Succeeded             : {0}" -f $successCount)  -ForegroundColor Green
Write-Host ("  Failed / partial      : {0}" -f $failCount)     -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Green' })
Write-Host ""
if ($failCount -gt 0) {
    Write-Host "  Tip: 422 errors are usually caused by a branch ruleset." -ForegroundColor DarkYellow
    Write-Host "  Check rulesets at: https://github.com/organizations/$Org/settings/rules" -ForegroundColor DarkYellow
}
Write-Host ""
