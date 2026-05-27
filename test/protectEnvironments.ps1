<#
.SYNOPSIS
    Applies required-reviewer protection to RC, IAT, and PROD environments
    across all repos in the wtw-RiskTechnology GitHub org.

.DESCRIPTION
    For every non-archived repo in the org this script will:
      - Create the environment if it does not already exist
      - Set the wtw-RiskTechnology/release-approvers team as a required reviewer

    Requires: GitHub CLI (gh) authenticated as an org owner or admin.

.PARAMETER Environments
    Comma-separated list of environment names to protect.
    Defaults to RC, IAT, PROD.

.PARAMETER DryRun
    Print what would be done without making any API calls.

.EXAMPLE
    .\protectEnvironments.ps1

.EXAMPLE
    .\protectEnvironments.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string[]]$Environments = @("RC", "IAT", "PROD"),
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$org      = "wtw-RiskTechnology"
$teamSlug = "release-approvers"

# ── Validate gh auth ──────────────────────────────────────────────────────────
Write-Host "Checking gh authentication..." -ForegroundColor Cyan
gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "gh is not authenticated. Run 'gh auth login' first."
    exit 1
}

# ── Resolve team ID ───────────────────────────────────────────────────────────
Write-Host "Resolving team '$teamSlug'..." -ForegroundColor Cyan
$teamJson = gh api "/orgs/$org/teams/$teamSlug" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Could not find team '$org/$teamSlug'. Response: $teamJson"
    exit 1
}
$team   = $teamJson | ConvertFrom-Json
$teamId = $team.id
Write-Host "  Team ID: $teamId" -ForegroundColor Gray

# ── Collect all non-archived repos ───────────────────────────────────────────
Write-Host "Fetching all repos in '$org'..." -ForegroundColor Cyan
$repos = @()
$page  = 1
do {
    $batch = gh api "/orgs/$org/repos?per_page=100&page=$page&type=all" | ConvertFrom-Json
    $active = $batch | Where-Object { -not $_.archived -and $_.name -ne ".github" -and $_.name -notlike "Risk.Analytics.*" }
    $repos += $active
    Write-Host "  Page ${page}: $($batch.Count) repos ($($batch.Count - $active.Count) archived, skipped)" -ForegroundColor Gray
    $page++
} while ($batch.Count -eq 100)

Write-Host "Found $($repos.Count) active repos to process.`n" -ForegroundColor Cyan

# ── Build the reviewer payload ────────────────────────────────────────────────
$reviewerPayload = @{
    reviewers = @(
        @{ type = "Team"; id = $teamId }
    )
} | ConvertTo-Json -Depth 5 -Compress

# ── Process each repo / environment ──────────────────────────────────────────
$success = 0
$failed  = 0
$errors  = [System.Collections.Generic.List[string]]::new()

foreach ($repo in $repos) {
    $repoName = $repo.name

    # Grant the release-approvers team at least pull access so members can see
    # and action pending deployment approvals (GitHub requirement).
    if ($DryRun) {
        Write-Host "[DRY RUN] Would grant '$teamSlug' pull access to: $repoName" -ForegroundColor Yellow
    }
    else {
        $grantResponse = gh api --method PUT `
            "/orgs/$org/teams/$teamSlug/repos/$org/$repoName" `
            --field permission=pull 2>&1

        if ($LASTEXITCODE -ne 0) {
            $msg = "  ✗ $repoName — could not grant team repo access: $grantResponse"
            Write-Host $msg -ForegroundColor Red
            $errors.Add($msg)
            $failed++
            continue
        }

        Write-Host "  ✓ Granted '$teamSlug' pull access to $repoName" -ForegroundColor DarkGreen
    }

    foreach ($env in $Environments) {
        $label = "$repoName / $env"
        if ($DryRun) {
            Write-Host "[DRY RUN] Would protect: $label" -ForegroundColor Yellow
            $success++
            continue
        }

        try {
            $response = $reviewerPayload | gh api --method PUT `
                "/repos/$org/$repoName/environments/$env" `
                --input - 2>&1

            if ($LASTEXITCODE -ne 0) {
                throw $response
            }

            Write-Host "  ✓ $label" -ForegroundColor Green
            $success++
        }
        catch {
            $msg = "  ✗ $label — $_"
            Write-Host $msg -ForegroundColor Red
            $errors.Add($msg)
            $failed++
        }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "Results: $success succeeded, $failed failed" -ForegroundColor $(if ($failed -gt 0) { "Yellow" } else { "Green" })

if ($errors.Count -gt 0) {
    Write-Host "`nFailed items:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
}
