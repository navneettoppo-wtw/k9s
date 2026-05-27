$repoOrg = "wtw-RiskTechnology"

# Org-level OIDC subject customization
# -----------------------------------------------------------------------
# By customising the OIDC subject to use [repository_owner, environment]
# the emitted subject becomes:
#   repository_owner:wtw-RiskTechnology:environment:DEV
# instead of the default:
#   repo:wtw-RiskTechnology/rna-forge:environment:DEV
#
# This means a SINGLE set of federated credentials covers every repo in
# the org — so we go back to the original two shared SPNs:
#   CRBRA-GITHUB-ACTIONS-DEV  -> DEV + QA
#   CRBRA-GITHUB-ACTIONS-PROD -> DEV + QA + RC + IAT + PROD
# -----------------------------------------------------------------------

# Two shared org-wide SPNs (not per-repo)
$spnConfig = @(
    @{
        SpnName      = "CRBRA-GITHUB-ACTIONS-DEV"
        Environments = @("DEV", "QA")
    }
    @{
        SpnName      = "CRBRA-GITHUB-ACTIONS-PROD"
        Environments = @("DEV", "QA", "RC", "IAT", "PROD")
    }
)

# -----------------------------------------------------------------------
# Step 1: Configure org-level OIDC subject customization
# This only needs to be run once per org; safe to re-run.
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Step 1: Configure org OIDC subject customization" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host "Setting org OIDC subject to [repository_owner, environment]..." -ForegroundColor Cyan

$oidcBody = '{"include_claim_keys":["repository_owner","environment"]}'
$result = $oidcBody | gh api "orgs/$repoOrg/actions/oidc/customization/sub" --method PUT --input - 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ⚠️  Org-level OIDC customization failed (may need org owner permissions): $result" -ForegroundColor Yellow
    Write-Host "  Continuing — repo-level customization in Step 3 will still apply correctly." -ForegroundColor Yellow
} else {
    Write-Host "✅ Org OIDC subject customization set." -ForegroundColor Green
}

# -----------------------------------------------------------------------
# Step 2: Create/update the two shared SPNs with org-scoped subjects
# Subject format: repository_owner:<org>:environment:<ENV>
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Step 2: Configure shared SPNs" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor DarkCyan

foreach ($spn in $spnConfig) {
    Write-Host ""
    Write-Host " SPN: $($spn.SpnName)  [$($spn.Environments -join ', ')]" -ForegroundColor Cyan

    $appId = az ad app list --display-name $spn.SpnName --query "[0].appId" -o tsv
    if (-not $appId) {
        Write-Host "  Creating app registration..." -ForegroundColor Yellow
        $appId = az ad app create --display-name $spn.SpnName --query appId -o tsv
        Write-Host "  App created: $appId" -ForegroundColor Green
        az ad sp create --id $appId | Out-Null
        Write-Host "  Service principal created." -ForegroundColor Green
    } else {
        Write-Host "  Found existing: $appId" -ForegroundColor Green
    }

    $objectId = az ad app show --id $appId --query id -o tsv

    # Only create credentials that don't already exist with the correct subject
    $existingCreds = az ad app federated-credential list --id $objectId | ConvertFrom-Json
    Write-Host "  Existing credentials: $($existingCreds.Count) / 20" -ForegroundColor Yellow

    foreach ($env in $spn.Environments) {
        $credName      = "org-$($env.ToLower())"
        $subject       = "repository_owner:${repoOrg}:environment:${env}"
        $existingMatch = $existingCreds | Where-Object { $_.name -eq $credName -and $_.subject -eq $subject }

        if ($existingMatch) {
            Write-Host "  = $credName  (already correct, skipping)" -ForegroundColor DarkGray
        } else {
            # Remove stale entry with same name but wrong subject, if present
            $stale = $existingCreds | Where-Object { $_.name -eq $credName }
            if ($stale) {
                Write-Host "  ~ $credName  (subject mismatch, replacing)" -ForegroundColor DarkYellow
                az ad app federated-credential delete --id $objectId --federated-credential-id $stale.id
            }
            Write-Host "  + $credName  -->  $subject" -ForegroundColor White
            $tempFile = ".\cred-$credName.json"
            @{
                name      = $credName
                issuer    = "https://token.actions.githubusercontent.com"
                subject   = $subject
                audiences = @("api://AzureADTokenExchange")
            } | ConvertTo-Json | Out-File -FilePath $tempFile -Encoding utf8
            az ad app federated-credential create --id $objectId --parameters "@$tempFile" | Out-Null
            Remove-Item $tempFile -Force
        }
    }

    Write-Host "  ✅ App ID: $appId" -ForegroundColor Green
}

# -----------------------------------------------------------------------
# Step 3: Set OIDC subject customization at repo level
# Repo-level overrides guarantee the correct subject format even if the
# org-level setting didn't apply or was overridden.
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Step 3: Set repo-level OIDC subject customization" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor DarkCyan

Write-Host "Fetching all repos in $repoOrg..." -ForegroundColor Cyan
$repoNames = gh repo list $repoOrg --limit 1000 --json name --jq ".[].name" | Sort-Object
Write-Host "Found $($repoNames.Count) repos." -ForegroundColor Yellow

foreach ($repoName in $repoNames) {
    Write-Host " Repo: $repoName" -ForegroundColor Cyan
    $repoOidcBody = '{"use_default":false,"include_claim_keys":["repository_owner","environment"]}'
    $result = $repoOidcBody | gh api "repos/$repoOrg/$repoName/actions/oidc/customization/sub" --method PUT --input - 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ❌ Failed: $result" -ForegroundColor Red
    } else {
        Write-Host "  ✅ OIDC subject set to [repository_owner, environment]" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "✅ All done!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Assign RBAC roles:"
Write-Host "   - CRBRA-GITHUB-ACTIONS-DEV  -> DEV/QA subscription(s)"
Write-Host "   - CRBRA-GITHUB-ACTIONS-PROD -> RC/IAT/PROD subscription(s)"
Write-Host "2. Ensure these GitHub repo/org variables are also set:"
Write-Host "   - AZURE_TENANT_ID"
Write-Host "   - DEV_QA_AZURE_SUBSCRIPTION_ID"
Write-Host "   - RC_IAT_PROD_AZURE_SUBSCRIPTION_ID"
Write-Host "3. Go to each GitHub repo Settings → Environments"
Write-Host "4. Create environments: DEV, QA, RC, IAT, PROD"
Write-Host "5. For each environment, configure:"
Write-Host "   - Required reviewers (approvers)"
Write-Host "   - Optional wait timer (e.g., 5 minutes)"
Write-Host "   - Deployment branches (optional: limit to develop/release/* branches)"