<#
.SYNOPSIS
    Migrates a local git repository (previously cloned from Azure DevOps) to an existing GitHub Enterprise org repo.

.DESCRIPTION
    Run this script from the root of the locally checked-out Azure DevOps repository.
    The script re-points the remote origin to the specified GitHub Enterprise repository
    and pushes all history to both the 'develop' and 'release' branches.

.PARAMETER RepoName
    The name of the existing GitHub repository to push to.

.PARAMETER Org
    The GitHub Enterprise organisation. Defaults to 'wtw-RiskTechnology'.

.PARAMETER Branches
    The branches to push. Defaults to @('develop', 'release').

.EXAMPLE
    .\migrateRepoFromAzDevOps.ps1 -RepoName "my-service"

.EXAMPLE
    .\migrateRepoFromAzDevOps.ps1 -RepoName "my-service" -Org "wtw-RiskTechnology"

.EXAMPLE
    .\migrateRepoFromAzDevOps.ps1 -RepoName "my-service" -Branches @('develop','release','main')
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "The name of the existing GitHub repository.")]
    [string]$RepoName,

    [Parameter(Mandatory = $false)]
    [string]$Org = "wtw-RiskTechnology",

    [Parameter(Mandatory = $false)]
    [string[]]$Branches = @("develop", "release")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Success([string]$Message) {
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "    [WARN] $Message" -ForegroundColor Yellow
}

function Push-Branch([string]$BranchName, [string]$TargetOrg, [string]$TargetRepo) {
    Write-Step "Ensuring local branch '$BranchName' exists..."

    $localBranch = git branch --list $BranchName
    if ($localBranch) {
        Write-Success "Branch '$BranchName' already exists locally."
        git checkout $BranchName
    } else {
        $currentBranch = git rev-parse --abbrev-ref HEAD
        Write-Warn "Branch '$BranchName' not found locally. Creating from '$currentBranch'..."
        git checkout -b $BranchName
        Write-Success "Created and switched to branch '$BranchName'."
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to switch to branch '$BranchName'."
        exit 1
    }

    Write-Step "Pushing branch '$BranchName' to GitHub ($TargetOrg/$TargetRepo)..."

    git push --set-upstream origin $BranchName

    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Initial push was rejected. The remote branch may already contain commits."
        Write-Host ""
        Write-Host "    This is a migration — force-pushing will OVERWRITE the remote branch with local history." -ForegroundColor Yellow
        $confirmForce = Read-Host "    Force-push '$BranchName' to '$TargetOrg/$TargetRepo'? (y/N)"

        if ($confirmForce -notmatch '^[yY]$') {
            Write-Host "    Skipped force-push for '$BranchName'." -ForegroundColor Yellow
            return
        }

        Write-Step "Force-pushing branch '$BranchName' to GitHub ($TargetOrg/$TargetRepo)..."
        git push --force --set-upstream origin $BranchName

        if ($LASTEXITCODE -ne 0) {
            Write-Error "Force-push of '$BranchName' failed. Check your credentials and that the repository '$TargetOrg/$TargetRepo' exists on GitHub."
            exit 1
        }
    }

    Write-Success "Branch '$BranchName' pushed successfully."
}

# ---------------------------------------------------------------------------
# Validate we are inside a git repository
# ---------------------------------------------------------------------------
Write-Step "Validating local git repository..."

if (-not (Test-Path ".git" -PathType Container)) {
    Write-Error "No .git directory found in '$PWD'. Run this script from the root of the locally cloned Azure DevOps repository."
    exit 1
}

$gitStatus = git status --short 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "git status failed. Ensure git is installed and this is a valid git repository."
    exit 1
}

if ($gitStatus) {
    Write-Warn "There are uncommitted changes in the working directory:"
    git status --short
    $confirm = Read-Host "`n    Proceed anyway? Uncommitted changes will NOT be pushed. (y/N)"
    if ($confirm -notmatch '^[yY]$') {
        Write-Host "Aborted." -ForegroundColor Red
        exit 0
    }
}

Write-Success "Local repository looks good."

# ---------------------------------------------------------------------------
# Build target URL
# ---------------------------------------------------------------------------
$githubUrl = "https://github.com/$Org/$RepoName.git"

Write-Step "Target GitHub repository: $githubUrl"
Write-Host "    Org      : $Org"
Write-Host "    Repo     : $RepoName"
Write-Host "    Branches : $($Branches -join ', ')"

# ---------------------------------------------------------------------------
# Configure remote
# ---------------------------------------------------------------------------
Write-Step "Configuring git remote 'origin'..."

$existingRemote = git remote get-url origin 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Warn "Remote 'origin' currently points to: $existingRemote"
    git remote set-url origin $githubUrl
    Write-Success "Remote 'origin' updated to: $githubUrl"
} else {
    git remote add origin $githubUrl
    Write-Success "Remote 'origin' added: $githubUrl"
}

# ---------------------------------------------------------------------------
# Push each branch
# ---------------------------------------------------------------------------
Write-Warn "You may be prompted for GitHub credentials if not using a credential helper or PAT."

foreach ($b in $Branches) {
    Push-Branch -BranchName $b -TargetOrg $Org -TargetRepo $RepoName
}

# ---------------------------------------------------------------------------
# Post-migration repo setup
# ---------------------------------------------------------------------------
Write-Step "Configuring repository labels..."

$repoArg = "$Org/$RepoName"

# --force updates the label if it already exists, so this step is safe to re-run
gh label create "copilot-ready" `
    --color "0075ca" `
    --description "Issue is fully specified; safe to assign to Copilot" `
    --repo $repoArg `
    --force

if ($LASTEXITCODE -ne 0) {
    Write-Warn "Failed to create 'copilot-ready' label. Ensure 'gh' is authenticated and has write access to '$repoArg'."
} else {
    Write-Success "Label 'copilot-ready' is present on '$repoArg'."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host "  Migration complete!" -ForegroundColor Green
Write-Host "  Repository : https://github.com/$Org/$RepoName" -ForegroundColor Green
Write-Host "  Branches   : $($Branches -join ', ')" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan
