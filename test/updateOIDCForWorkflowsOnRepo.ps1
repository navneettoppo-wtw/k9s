param(
    [Parameter(Mandatory = $true)]
    [string]$RepoName,

    [string]$RepoOrg = "wtw-RiskTechnology"
)

Write-Host "" 
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Set repo-level OIDC subject customization" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor DarkCyan

$repoOidcBody = '{"use_default":false,"include_claim_keys":["repository_owner","environment"]}'

Write-Host "Updating OIDC subject customization for $RepoOrg/$RepoName..." -ForegroundColor Cyan
$result = $repoOidcBody | gh api "repos/$RepoOrg/$RepoName/actions/oidc/customization/sub" --method PUT --input - 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed: $result" -ForegroundColor Red
    exit 1
}

Write-Host "✅ OIDC subject set to [repository_owner, environment] for $RepoOrg/$RepoName" -ForegroundColor Green
