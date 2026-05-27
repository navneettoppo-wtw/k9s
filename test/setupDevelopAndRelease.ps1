# Script to set up develop and release branches on a new GitHub repository
# Assumes: GitHub repo exists, main branch exists, repo cloned to current working directory
# Structure: main -> develop -> release

param(
    [string]$DevelopBranchName = "develop",
    [string]$ReleaseBranchName = "release"
)

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "GitHub Branch Setup Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Verify we're in a git repository
Write-Host "`nVerifying git repository..." -ForegroundColor Yellow
try {
    $gitStatus = git status 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Not in a git repository. Please run this script from the root of your cloned repository."
    }
    Write-Host "✓ Git repository detected" -ForegroundColor Green
}
catch {
    Write-Error "Failed to verify git repository: $_"
    exit 1
}

# Get current branch
$currentBranch = git branch --show-current
Write-Host "Current branch: $currentBranch" -ForegroundColor Gray

# Ensure we're on main branch
if ($currentBranch -ne "main") {
    Write-Host "`nSwitching to main branch..." -ForegroundColor Yellow
    try {
        git checkout main
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to checkout main branch"
        }
        Write-Host "✓ Switched to main branch" -ForegroundColor Green
    }
    catch {
        Write-Error "Main branch does not exist or cannot be checked out: $_"
        exit 1
    }
}
else {
    Write-Host "✓ Already on main branch" -ForegroundColor Green
}

# Pull latest from main
Write-Host "`nPulling latest changes from origin/main..." -ForegroundColor Yellow
try {
    git pull origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not pull from origin/main. Continuing with local main..."
    }
    else {
        Write-Host "✓ Pulled latest changes" -ForegroundColor Green
    }
}
catch {
    Write-Warning "Could not pull from origin/main: $_"
}

# Check if develop branch already exists locally or remotely
Write-Host "`nChecking for existing develop branch..." -ForegroundColor Yellow
$developExists = git branch --list $DevelopBranchName
$developRemoteExists = git ls-remote --heads origin $DevelopBranchName

if ($developExists -or $developRemoteExists) {
    Write-Host "⚠ Develop branch '$DevelopBranchName' already exists" -ForegroundColor Yellow
    
    if ($developExists) {
        Write-Host "  - Found locally" -ForegroundColor Gray
        git checkout $DevelopBranchName
    }
    elseif ($developRemoteExists) {
        Write-Host "  - Found remotely, checking out..." -ForegroundColor Gray
        git checkout -b $DevelopBranchName origin/$DevelopBranchName
    }
}
else {
    # Create develop branch from main
    Write-Host "Creating '$DevelopBranchName' branch from main..." -ForegroundColor Yellow
    try {
        git checkout -b $DevelopBranchName
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create develop branch"
        }
        Write-Host "✓ Created '$DevelopBranchName' branch" -ForegroundColor Green
        
        # Push develop branch to remote
        Write-Host "Pushing '$DevelopBranchName' branch to origin..." -ForegroundColor Yellow
        git push -u origin $DevelopBranchName
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to push develop branch"
        }
        Write-Host "✓ Pushed '$DevelopBranchName' to remote" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to create/push develop branch: $_"
        exit 1
    }
}

# Check if release branch already exists locally or remotely
Write-Host "`nChecking for existing release branch..." -ForegroundColor Yellow
$releaseExists = git branch --list $ReleaseBranchName
$releaseRemoteExists = git ls-remote --heads origin $ReleaseBranchName

if ($releaseExists -or $releaseRemoteExists) {
    Write-Host "⚠ Release branch '$ReleaseBranchName' already exists" -ForegroundColor Yellow
    
    if ($releaseExists) {
        Write-Host "  - Found locally" -ForegroundColor Gray
    }
    if ($releaseRemoteExists) {
        Write-Host "  - Found remotely" -ForegroundColor Gray
    }
}
else {
    # Create release branch from develop
    Write-Host "Creating '$ReleaseBranchName' branch from $DevelopBranchName..." -ForegroundColor Yellow
    try {
        # Ensure we're on develop
        git checkout $DevelopBranchName
        
        # Create release branch
        git checkout -b $ReleaseBranchName
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create release branch"
        }
        Write-Host "✓ Created '$ReleaseBranchName' branch" -ForegroundColor Green
        
        # Push release branch to remote
        Write-Host "Pushing '$ReleaseBranchName' branch to origin..." -ForegroundColor Yellow
        git push -u origin $ReleaseBranchName
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to push release branch"
        }
        Write-Host "✓ Pushed '$ReleaseBranchName' to remote" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to create/push release branch: $_"
        exit 1
    }
}

# Set default branch to develop
Write-Host "`nSetting default branch to '$DevelopBranchName'..." -ForegroundColor Yellow
try {
    # Check if GitHub CLI is available
    $ghInstalled = Get-Command gh -ErrorAction SilentlyContinue
    
    if ($ghInstalled) {
        # Get the repository name
        $remoteUrl = git remote get-url origin
        
        # Extract owner/repo from the URL
        if ($remoteUrl -match 'github\.com[:/](.+/.+?)(\.git)?$') {
            $repoPath = $matches[1] -replace '\.git$', ''
            
            Write-Host "Updating default branch for repository: $repoPath" -ForegroundColor Gray
            
            # Set default branch using GitHub CLI
            gh repo edit $repoPath --default-branch $DevelopBranchName 2>&1 | Out-Null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Default branch set to '$DevelopBranchName'" -ForegroundColor Green
            }
            else {
                Write-Warning "Failed to set default branch. You may need to set it manually in GitHub settings."
            }
        }
        else {
            Write-Warning "Could not parse repository name from remote URL: $remoteUrl"
        }
    }
    else {
        Write-Warning "GitHub CLI (gh) not found. Please install it to automatically set the default branch."
        Write-Host "  Install from: https://cli.github.com/" -ForegroundColor Gray
        Write-Host "  Or manually set the default branch in GitHub repository settings." -ForegroundColor Gray
    }
}
catch {
    Write-Warning "Could not set default branch: $_"
    Write-Host "  You can manually set the default branch in GitHub repository settings." -ForegroundColor Gray
}

# Return to main branch
Write-Host "`nReturning to main branch..." -ForegroundColor Yellow
git checkout main

# Display branch structure
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Branch Setup Complete!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`nLocal branches:" -ForegroundColor Yellow
git branch

Write-Host "`nRemote branches:" -ForegroundColor Yellow
git branch -r | Select-String -Pattern "(main|$DevelopBranchName|$ReleaseBranchName)"

Write-Host "`nBranch Structure:" -ForegroundColor Cyan
Write-Host "  main" -ForegroundColor Green
Write-Host "   └─> $DevelopBranchName" -ForegroundColor Green
Write-Host "        └─> $ReleaseBranchName" -ForegroundColor Green

Write-Host "`n✓ All branches created successfully!" -ForegroundColor Green
Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host "  1. Consider setting up branch protection rules in GitHub" -ForegroundColor Gray
Write-Host "  2. Configure required reviewers for pull requests" -ForegroundColor Gray
Write-Host "  3. Set up CI/CD workflows for each branch" -ForegroundColor Gray
Write-Host ""
