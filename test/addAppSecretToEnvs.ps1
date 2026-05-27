<#
.SYNOPSIS
    Creates client secrets on 5 existing app registrations and stores them as
    APP_CLIENT_SECRET environment secrets in one or more GitHub repositories.

.DESCRIPTION
    - Accepts 5 SPN display names (one per environment: DEV, QA, RC, IAT, PROD).
    - For each SPN, generates a new client secret valid for 24 months using the
      Azure CLI (the current user must be an owner of each app registration).
    - If the same SPN appears more than once, the secret is created once and
      reused across all matching environments.
    - Creates the GitHub environment inside each target repo if it does not
      already exist.
    - Stores the secret as APP_CLIENT_SECRET on the matching GitHub environment
      in every supplied repo using the GitHub CLI.

.PARAMETER RepoNames
    One or more GitHub repository names (organisation is always wtw-RiskTechnology).
    Example: @("rna-forge","rna-platform")

.PARAMETER SpnNames
    Ordered array of exactly 5 SPN display names.
    The order maps to environments: DEV, QA, RC, IAT, PROD.
    Example: @("SPN-DEV","SPN-QA","SPN-RC","SPN-IAT","SPN-PROD")

.EXAMPLE
    .\addAppSecretToEnvs.ps1 -RepoNames @("rna-sdk-localisation-api") -SpnNames @("CRBRA SDK Localisation DEV-QA","CRBRA SDK Localisation DEV-QA","CRBRA-SDK-Localisation-RC","CRBRA SDK Localisation IAT","CRBRA SDK Localisation PROD")
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateCount(1, 100)]
    [string[]] $RepoNames,

    [Parameter(Mandatory)]
    [ValidateCount(5, 5)]
    [string[]] $SpnNames
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------
$RepoOrg        = "wtw-RiskTechnology"
$Environments   = @("DEV", "QA", "RC", "IAT", "PROD")
$SecretName     = "APP_CLIENT_SECRET"
$SecretValidity = 24   # months
$CredLabel      = "github-actions-$SecretName"

# -----------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Pre-flight checks" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor DarkCyan

# Verify Azure CLI is logged in
$azAccount = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Not logged in to Azure CLI. Run 'az login' first." -ForegroundColor Red
    exit 1
}
$tenantId = ($azAccount | ConvertFrom-Json).tenantId
Write-Host "Azure CLI: authenticated (tenant: $tenantId)" -ForegroundColor Green

# Verify GitHub CLI is logged in
$ghStatus = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Not logged in to GitHub CLI. Run 'gh auth login' first." -ForegroundColor Red
    exit 1
}
Write-Host "GitHub CLI: authenticated" -ForegroundColor Green

# Verify all target repos are reachable before making any changes
foreach ($repoName in $RepoNames) {
    $repoCheck = gh repo view "$RepoOrg/$repoName" --json name 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Cannot access repo '$RepoOrg/$repoName': $repoCheck" -ForegroundColor Red
        exit 1
    }
    Write-Host "GitHub repo:  $RepoOrg/$repoName  (accessible)" -ForegroundColor Green
}

# -----------------------------------------------------------------------
# Process each SPN / environment pair
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Processing SPNs and GitHub environments" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor DarkCyan

$endDate = (Get-Date).AddMonths($SecretValidity).ToString("yyyy-MM-dd")

# Cache of SPN name -> secret value so duplicate SPNs reuse the same secret
$spnSecretCache = @{}

for ($i = 0; $i -lt $Environments.Count; $i++) {

    $envName = $Environments[$i]
    $spnName = $SpnNames[$i]

    Write-Host ""
    Write-Host "-------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " [$envName]  SPN: $spnName" -ForegroundColor Cyan
    Write-Host "-------------------------------------------------------------------" -ForegroundColor DarkGray

    # ------------------------------------------------------------------
    # Step A: Resolve the app registration
    # ------------------------------------------------------------------
    Write-Host "  Looking up app registration..." -ForegroundColor Yellow
    $appId = az ad app list --display-name $spnName --query "[0].appId" -o tsv 2>&1

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($appId)) {
        Write-Host "  ERROR: Could not find app registration '$spnName'. Skipping." -ForegroundColor Red
        continue
    }
    Write-Host "  App ID: $appId" -ForegroundColor Green

    $objectId = az ad app show --id $appId --query id -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($objectId)) {
        Write-Host "  ERROR: Could not retrieve object ID for app '$spnName'. Skipping." -ForegroundColor Red
        continue
    }

    # ------------------------------------------------------------------
    # Step B+C: Create client secret — or reuse if this SPN was already
    #           processed earlier in the run (same SPN, multiple envs)
    # ------------------------------------------------------------------
    if ($spnSecretCache.ContainsKey($spnName)) {
        $clientSecret = $spnSecretCache[$spnName]
        Write-Host "  SPN already processed this run — reusing existing secret value." -ForegroundColor DarkGray
    } else {
        # Step B: Remove any existing credential with the same label to
        #         avoid accumulating stale secrets on the app registration
        Write-Host "  Checking for existing '$CredLabel' credential..." -ForegroundColor Yellow
        $existingCreds = az ad app credential list --id $objectId --query "[?displayName=='$CredLabel']" | ConvertFrom-Json

        foreach ($cred in $existingCreds) {
            Write-Host "  Removing stale credential (keyId: $($cred.keyId))..." -ForegroundColor DarkYellow
            az ad app credential delete --id $objectId --key-id $cred.keyId | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  WARNING: Failed to remove credential $($cred.keyId) — continuing." -ForegroundColor Yellow
            }
        }

        # Step C: Create the new client secret (24 months)
        Write-Host "  Creating new client secret (valid until $endDate)..." -ForegroundColor Yellow

        $credResult = az ad app credential reset `
            --id $objectId `
            --display-name $CredLabel `
            --end-date $endDate `
            --append `
            | ConvertFrom-Json

        if ($LASTEXITCODE -ne 0 -or -not $credResult) {
            Write-Host "  ERROR: Failed to create secret for '$spnName'. Skipping." -ForegroundColor Red
            continue
        }

        $clientSecret = $credResult.password
        $spnSecretCache[$spnName] = $clientSecret
        Write-Host "  Secret created (expires: $endDate)" -ForegroundColor Green
        Write-Host "  Secret value: $clientSecret" -ForegroundColor DarkMagenta
    }

    # ------------------------------------------------------------------
    # Steps D + E: For every repo — ensure environment exists, set secret
    # ------------------------------------------------------------------
    foreach ($repoName in $RepoNames) {
        $repoFull = "$RepoOrg/$repoName"

        # Step D: Ensure the GitHub environment exists
        Write-Host "  [$repoName] Ensuring environment '$envName' exists..." -ForegroundColor Yellow

        $envCheck = gh api "repos/$repoFull/environments/$envName" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [$repoName] Environment not found — creating '$envName'..." -ForegroundColor Yellow
            $createResult = gh api "repos/$repoFull/environments/$envName" --method PUT 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  [$repoName] ERROR: Could not create environment '$envName': $createResult" -ForegroundColor Red
                Write-Host "  The secret was created on the SPN but NOT stored in GitHub." -ForegroundColor Red
                continue
            }
            Write-Host "  [$repoName] Environment '$envName' created." -ForegroundColor Green
        } else {
            Write-Host "  [$repoName] Environment '$envName' already exists." -ForegroundColor Green
        }

        # Step E: Store the secret in the GitHub environment

        # Check whether the secret already exists (it will be overwritten if so)
        $existingGhSecret = gh secret list --repo $repoFull --env $envName --json name 2>$null | ConvertFrom-Json | Where-Object { $_.name -eq $SecretName }
        if ($existingGhSecret) {
            Write-Host "  [$repoName] WARNING: '$SecretName' already exists on '$envName' — it will be overwritten." -ForegroundColor DarkYellow
        }

        Write-Host "  [$repoName] Setting '$SecretName' on environment '$envName'..." -ForegroundColor Yellow
        Write-Host "  [$repoName] Secret value: $clientSecret" -ForegroundColor DarkMagenta

        gh secret set $SecretName `
            --repo $repoFull `
            --env $envName `
            --body $clientSecret

        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [$repoName] ERROR: Failed to set GitHub secret for environment '$envName'." -ForegroundColor Red
            continue
        }

        # Verify the secret is now present
        $verifiedSecret = gh secret list --repo $repoFull --env $envName --json name 2>$null | ConvertFrom-Json | Where-Object { $_.name -eq $SecretName }
        if ($verifiedSecret) {
            Write-Host "  ✅ $SecretName stored and verified in [$repoFull] / [$envName]" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️  WARNING: $SecretName was sent but could not be verified in [$repoFull] / [$envName]" -ForegroundColor Yellow
        }
    }

    # Clear plaintext secret from memory after all repos are done for this env
    $clientSecret = $null
}

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Done" -ForegroundColor Green
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
foreach ($repoName in $RepoNames) {
    Write-Host "  - Verify secrets: https://github.com/$RepoOrg/$repoName/settings/environments"
}
Write-Host "  - Confirm app registrations in Entra ID have the new credential"
Write-Host "    (valid for 24 months from today, $endDate)."
Write-Host "  - Set a reminder to rotate these secrets before $endDate."
Write-Host ""
