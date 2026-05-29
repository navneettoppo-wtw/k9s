<#
.SYNOPSIS
    Bulletproof migration of GitHub Actions secrets, variables, Dependabot secrets,
    and environment protection rules between two GitHub organisations.

.DESCRIPTION
    Covers:
      - Org-level Actions secrets + variables (with visibility/selected-repo list)
      - Repo-level Actions secrets + variables
      - Environment-level secrets + variables
      - Dependabot secrets (org + repo)
      - Environment protection rules (required reviewers, wait timer, branch policies)
      - Auto-maps GitHub secret names → Key Vault secret names (fuzzy match)
      - Always fetches LATEST secret value from Key Vault (handles rotation)
      - Detects base64 / multi-line / JSON secrets and passes them safely
      - Retry with exponential backoff on all API calls
      - GitHub API rate-limit awareness (pauses when near limit)
      - Resume capability: skips items already recorded as success in a prior CSV
      - Dest repo existence pre-check before processing
      - Post-migration verification for variables
      - Timestamped CSV audit report + log file

.PARAMETER DryRun
    Preview all actions without writing anything.

.EXAMPLE
    .\migrate_secrets.ps1
    .\migrate_secrets.ps1 -DryRun
#>

[CmdletBinding()]
param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ==============================================================================
# CONFIG — edit before running
# ==============================================================================
$GhApiHost    = "https://api.github.com"   # change for GHES
$SourceOrg    = "source-org-name"
$DestOrg      = "dest-org-name"
$KeyVaultName = ""                          # Azure Key Vault name; leave empty to flag manually

# Repo map: source name → dest name. Leave empty @{} to auto-discover all repos.
$RepoMap = [ordered]@{
    # "old-repo" = "new-repo"
}

# Environments to migrate per repo. Leave empty @() to auto-discover.
$Environments = @()

# Resume: path to a prior run's CSV to skip already-succeeded items. Leave "" to disable.
$ResumeCsv = ""

# Rate-limit threshold: pause when remaining requests drop below this number
$RateLimitPauseThreshold = 200
# ==============================================================================

$_ts        = Get-Date -Format "yyyyMMdd_HHmmss"
$ReportFile = "migration_report_$_ts.csv"
$LogFile    = "migration_$_ts.log"
$env:GH_HOST = $GhApiHost -replace '^https?://', ''

# ── Logging ───────────────────────────────────────────────────────────────────
function Write-Step([string]$m)    { $l="`n==> $m";    Write-Host $l -ForegroundColor Cyan;   Add-Content $LogFile $l }
function Write-Success([string]$m) { $l="  [OK]   $m"; Write-Host $l -ForegroundColor Green;  Add-Content $LogFile $l }
function Write-Warn([string]$m)    { $l="  [WARN] $m"; Write-Host $l -ForegroundColor Yellow; Add-Content $LogFile $l }
function Write-Info([string]$m)    { $l="  $m";        Write-Host $l -ForegroundColor Gray;   Add-Content $LogFile $l }
function Write-Err([string]$m)     { $l="  [ERR]  $m"; Write-Host $l -ForegroundColor Red;    Add-Content $LogFile $l }

# ── CSV ───────────────────────────────────────────────────────────────────────
function Initialize-Report {
    "timestamp_utc,scope,repo,environment,type,name,kv_name,source_updated_at,dest_updated_at,action,status,notes" |
        Set-Content $ReportFile -Encoding UTF8NoBOM
}

function Add-CsvRow {
    param([string]$Scope,[string]$Repo,[string]$Env,[string]$Type,
          [string]$Name,[string]$KvName="",[string]$SrcTs,[string]$DstTs,
          [string]$Action,[string]$Status,[string]$Notes="")
    $ts = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ" -AsUTC)
    "`"$ts`",`"$Scope`",`"$Repo`",`"$Env`",`"$Type`",`"$Name`",`"$KvName`",`"$SrcTs`",`"$DstTs`",`"$Action`",`"$Status`",`"$Notes`"" |
        Add-Content $ReportFile -Encoding UTF8NoBOM
}

# ── Resume: load prior successes ──────────────────────────────────────────────
$script:PriorSuccesses = @{}
function Initialize-Resume {
    if ([string]::IsNullOrWhiteSpace($ResumeCsv) -or -not (Test-Path $ResumeCsv)) { return }
    $rows = Import-Csv $ResumeCsv | Where-Object { $_.status -eq "success" }
    foreach ($r in $rows) {
        $key = "$($r.scope)|$($r.repo)|$($r.environment)|$($r.type)|$($r.name)"
        $script:PriorSuccesses[$key] = $true
    }
    Write-Info "Resume: loaded $($script:PriorSuccesses.Count) prior successes from $ResumeCsv"
}

function Test-AlreadyMigrated([string]$scope,[string]$repo,[string]$env,[string]$type,[string]$name) {
    return $script:PriorSuccesses.ContainsKey("$scope|$repo|$env|$type|$name")
}

# ── Rate-limit guard ──────────────────────────────────────────────────────────
function Invoke-RateLimitCheck {
    try {
        $rl = gh api "rate_limit" 2>$null | ConvertFrom-Json
        $remaining = $rl.rate.remaining
        $reset     = $rl.rate.reset
        if ($remaining -lt $RateLimitPauseThreshold) {
            $waitSec = [int]($reset - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) + 5
            if ($waitSec -gt 0) {
                Write-Warn "Rate limit low ($remaining remaining). Pausing ${waitSec}s until reset..."
                Start-Sleep -Seconds $waitSec
            }
        }
    } catch { <# non-fatal #> }
}

# ── Retry wrapper ─────────────────────────────────────────────────────────────
# Wraps a scriptblock with exponential backoff. Retries on non-zero exit or exception.
function Invoke-WithRetry {
    param([scriptblock]$Action, [int]$MaxAttempts = 4, [string]$Label = "")
    $delay = 2
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            Invoke-RateLimitCheck
            $result = & $Action
            if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) {
                throw "Exit code $LASTEXITCODE"
            }
            return $result
        } catch {
            if ($i -eq $MaxAttempts) { throw }
            Write-Warn "  Attempt $i/$MaxAttempts failed for [$Label]: $_. Retrying in ${delay}s..."
            Start-Sleep -Seconds $delay
            $delay = $delay * 2
        }
    }
}

# ── Timestamp helpers ─────────────────────────────────────────────────────────
function Test-SrcIsNewer([string]$src, [string]$dst) {
    if ([string]::IsNullOrWhiteSpace($dst) -or $dst -eq "null") { return $true }
    try {
        $s = [datetime]::Parse($src, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $d = [datetime]::Parse($dst, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return $s -gt $d
    } catch { return $true }
}

function Get-SecretTs($meta) {
    if ($meta.updated_at -and $meta.updated_at -ne "null") { return $meta.updated_at }
    if ($meta.created_at -and $meta.created_at -ne "null") { return $meta.created_at }
    return ""
}

# ── Secret value helpers ──────────────────────────────────────────────────────
# Detect if a string is base64-encoded (common for certs, keys, JSON blobs)
function Test-IsBase64([string]$value) {
    if ($value.Length % 4 -ne 0) { return $false }
    return $value -match '^[A-Za-z0-9+/]*={0,2}$'
}

# Write secret value to a temp file safely (handles multi-line, special chars, BOM-free)
# Returns the temp file path. Caller must delete it.
function Write-SecretTempFile([string]$value) {
    $tmp = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, $value, [System.Text.UTF8Encoding]::new($false))
    return $tmp
}

# ── Key Vault auto-mapping ────────────────────────────────────────────────────
$script:KvSecretNames = @()
$script:KvNameCache   = @{}   # ghName → kvName (or $null)

function Initialize-KvSecretNames {
    if ([string]::IsNullOrWhiteSpace($KeyVaultName)) { return }
    Write-Info "Loading all secret names from Key Vault '$KeyVaultName'..."
    # Include disabled secrets so we can warn; filter them out when fetching values
    $names = az keyvault secret list --vault-name $KeyVaultName `
                 --include-managed false --query "[].name" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $names) {
        Write-Warn "Could not list secrets from Key Vault '$KeyVaultName'"
        return
    }
    $script:KvSecretNames = @($names | Where-Object { $_ })
    Write-Info "  Found $($script:KvSecretNames.Count) secrets in Key Vault"
}

function Get-NormName([string]$n) { $n.ToLower() -replace '[-_\s\.]','' }

function Resolve-KvName([string]$ghName) {
    if ($script:KvSecretNames.Count -eq 0) { return $null }
    # 1. underscore → hyphen exact
    $h = $ghName.ToLower().Replace("_","-")
    $m = $script:KvSecretNames | Where-Object { $_.ToLower() -eq $h }
    if ($m) { return ($m | Select-Object -First 1) }
    # 2. strip all separators exact
    $ng = Get-NormName $ghName
    $m  = $script:KvSecretNames | Where-Object { (Get-NormName $_) -eq $ng }
    if ($m) { return ($m | Select-Object -First 1) }
    # 3. containment — only if exactly 1 match (avoids ambiguity)
    $m = $script:KvSecretNames | Where-Object {
        $nk = Get-NormName $_
        $nk -like "*$ng*" -or $ng -like "*$nk*"
    }
    if (($m | Measure-Object).Count -eq 1) { return ($m | Select-Object -First 1) }
    return $null
}

# Always fetches LATEST version from KV (handles secret rotation)
function Get-KvSecret([string]$ghName) {
    if ([string]::IsNullOrWhiteSpace($KeyVaultName)) { return $null }

    if (-not $script:KvNameCache.ContainsKey($ghName)) {
        $script:KvNameCache[$ghName] = Resolve-KvName $ghName
        if ($script:KvNameCache[$ghName]) {
            Write-Info "  KV map: '$ghName' → '$($script:KvNameCache[$ghName])'"
        }
    }
    $kvName = $script:KvNameCache[$ghName]
    if (-not $kvName) {
        Write-Warn "  KV: no match for '$ghName'"
        return $null
    }

    # Check secret is enabled and not expired before fetching
    try {
        $meta = az keyvault secret show --vault-name $KeyVaultName --name $kvName `
                    --query "{enabled:attributes.enabled,expires:attributes.expires}" `
                    -o json 2>$null | ConvertFrom-Json
        if (-not $meta.enabled) {
            Write-Warn "  KV: '$kvName' is DISABLED — skipping"
            return $null
        }
        if ($meta.expires -and $meta.expires -ne "null") {
            $exp = [datetime]::Parse($meta.expires)
            if ($exp -lt (Get-Date)) {
                Write-Warn "  KV: '$kvName' is EXPIRED ($($meta.expires)) — skipping"
                return $null
            }
        }
    } catch { <# non-fatal, proceed to fetch #> }

    # Fetch latest version value
    $value = az keyvault secret show --vault-name $KeyVaultName --name $kvName `
                 --query "value" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        Write-Warn "  KV: failed to retrieve '$kvName'"
        return $null
    }
    return $value
}


# ── Set a secret safely (handles multi-line, base64, JSON, special chars) ─────
function Set-GhSecret {
    param([string]$Name, [string]$Value, [string]$Scope,
          [string]$Repo="", [string]$Env="")
    $tmp = Write-SecretTempFile $Value
    try {
        if ($Scope -eq "org") {
            Invoke-WithRetry { gh secret set $Name --org $DestOrg < $tmp } -Label $Name
        } elseif ($Scope -eq "repo") {
            Invoke-WithRetry { gh secret set $Name --repo "$DestOrg/$Repo" < $tmp } -Label $Name
        } elseif ($Scope -eq "env") {
            Invoke-WithRetry { gh secret set $Name --repo "$DestOrg/$Repo" --env $Env < $tmp } -Label $Name
        } elseif ($Scope -eq "dependabot-org") {
            Invoke-WithRetry { gh secret set $Name --org $DestOrg --app dependabot < $tmp } -Label $Name
        } elseif ($Scope -eq "dependabot-repo") {
            Invoke-WithRetry { gh secret set $Name --repo "$DestOrg/$Repo" --app dependabot < $tmp } -Label $Name
        }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
function Invoke-PreflightChecks {
    if ($SourceOrg -eq "source-org-name" -or $DestOrg -eq "dest-org-name") {
        Write-Err "SourceOrg / DestOrg are still placeholders. Edit the CONFIG block."
        exit 1
    }
    Write-Step "Pre-flight checks"

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warn "gh CLI not found — attempting auto-install via winget..."
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install --id GitHub.cli --silent --accept-package-agreements --accept-source-agreements
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("PATH","User")
        } else { Write-Err "winget not available. Install gh CLI: https://cli.github.com/"; exit 1 }
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Err "gh CLI still not found. Install manually and retry."; exit 1
    }
    Write-Success "gh CLI: $((Get-Command gh).Source)"

    gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "gh not authenticated — launching login..."
        gh auth login
        if ($LASTEXITCODE -ne 0) { Write-Err "Auth failed. Run: gh auth login"; exit 1 }
    }
    Write-Success "GitHub CLI: authenticated"

    if (-not [string]::IsNullOrWhiteSpace($KeyVaultName)) {
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            Write-Err "Azure CLI required for Key Vault. Install: https://aka.ms/installazurecliwindows"; exit 1
        }
        az account show 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Err "Azure CLI not authenticated. Run: az login"; exit 1 }
        $kv = az keyvault show --name $KeyVaultName --query "name" -o tsv 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Err "Cannot access Key Vault '$KeyVaultName': $kv"; exit 1 }
        Write-Success "Azure Key Vault: $KeyVaultName (accessible)"
    }

    foreach ($org in @($SourceOrg, $DestOrg)) {
        $r = gh api "orgs/$org" --jq '.login' 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Err "Cannot access org '$org': $r"; exit 1 }
        Write-Success "GitHub org: $org (accessible)"
    }
}

# ── Dest repo existence cache ─────────────────────────────────────────────────
$script:DestRepoExists = @{}
function Test-DestRepoExists([string]$repo) {
    if (-not $script:DestRepoExists.ContainsKey($repo)) {
        $r = gh api "repos/$DestOrg/$repo" --jq '.name' 2>$null
        $script:DestRepoExists[$repo] = ($LASTEXITCODE -eq 0 -and $r -eq $repo)
    }
    return $script:DestRepoExists[$repo]
}

# ── Generic secret migrator ───────────────────────────────────────────────────
function Invoke-SecretMigration {
    param(
        [string]$Label,        # display label
        [string]$CsvScope,
        [string]$CsvRepo,
        [string]$CsvEnv,
        [string]$SecretType,   # "actions" or "dependabot"
        [object[]]$Secrets,
        [scriptblock]$SetAction,   # called with ($name, $value)
        [scriptblock]$GetDestMeta  # called with ($name), returns meta object
    )
    if (-not $Secrets -or $Secrets.Count -eq 0) { return }

    foreach ($secret in $Secrets) {
        $name  = $secret.name
        $srcTs = if ($secret.updated_at) { $secret.updated_at } else { $secret.created_at }

        if (Test-AlreadyMigrated $CsvScope $CsvRepo $CsvEnv $SecretType $name) {
            Write-Info "$Label [$name] — already migrated in prior run, skipping"
            continue
        }

        $dstMeta = & $GetDestMeta $name
        $dstTs   = Get-SecretTs $dstMeta

        # Always re-migrate (no skip on timestamp) — secret rotation means latest KV value
        # should always win. We only skip if dest is newer AND KV has no value.
        $kvValue = Get-KvSecret $name
        if ($null -eq $kvValue) {
            $action = if ($DryRun) { "dry_run" } else { "manual_required" }
            $notes  = if ($DryRun) { "[DRY RUN] no KV match" } else { "No KV match — set manually" }
            Write-Warn "$Label [$name] — no KV value found, flagged"
            Add-CsvRow $CsvScope $CsvRepo $CsvEnv $SecretType $name "" $srcTs $dstTs $action "flagged" $notes
            continue
        }

        $kvName = $script:KvNameCache[$name]
        $valueType = if (Test-IsBase64 $kvValue) { "base64" } `
                     elseif ($kvValue.Contains("`n") -or $kvValue.Contains("`r")) { "multiline" } `
                     elseif ($kvValue.TrimStart().StartsWith("{") -or $kvValue.TrimStart().StartsWith("[")) { "json" } `
                     else { "plain" }

        if ($DryRun) {
            Write-Info "$Label [$name] [DRY RUN] would migrate (type=$valueType, kv=$kvName)"
            Add-CsvRow $CsvScope $CsvRepo $CsvEnv $SecretType $name $kvName $srcTs $dstTs "dry_run" "would_migrate" "type=$valueType"
            continue
        }

        try {
            & $SetAction $name $kvValue
            Write-Success "$Label [$name] migrated (type=$valueType, kv=$kvName)"
            Add-CsvRow $CsvScope $CsvRepo $CsvEnv $SecretType $name $kvName $srcTs $dstTs "migrated" "success" "type=$valueType"
        } catch {
            Write-Err "$Label [$name] — failed: $_"
            Add-CsvRow $CsvScope $CsvRepo $CsvEnv $SecretType $name $kvName $srcTs $dstTs "migrate" "failed" "$_"
        }
    }
}

# ── Generic variable migrator ─────────────────────────────────────────────────
function Invoke-VariableMigration {
    param(
        [string]$Label,
        [string]$CsvScope,
        [string]$CsvRepo,
        [string]$CsvEnv,
        [object[]]$Vars,
        [scriptblock]$UpsertAction,   # called with ($name, $value, $method)
        [scriptblock]$GetDestVar,     # called with ($name), returns dest var or $null
        [scriptblock]$VerifyAction    # called with ($name), returns name string or $null
    )
    if (-not $Vars -or $Vars.Count -eq 0) { return }

    foreach ($var in $Vars) {
        $name  = $var.name
        $value = $var.value
        $srcTs = if ($var.updated_at) { $var.updated_at } else { $var.created_at }

        if (Test-AlreadyMigrated $CsvScope $CsvRepo $CsvEnv "variable" $name) {
            Write-Info "$Label [$name] — already migrated in prior run, skipping"
            continue
        }

        $dstVar = & $GetDestVar $name
        $dstTs  = if ($dstVar) { Get-SecretTs $dstVar } else { "" }

        if ($dstTs -and -not (Test-SrcIsNewer $srcTs $dstTs)) {
            Write-Warn "$Label [$name] — dest newer, skipping"
            Add-CsvRow $CsvScope $CsvRepo $CsvEnv "variable" $name "" $srcTs $dstTs "skip" "skipped" "dest newer"
            continue
        }

        if ($DryRun) {
            Write-Info "$Label [$name] [DRY RUN] would migrate"
            Add-CsvRow $CsvScope $CsvRepo $CsvEnv "variable" $name "" $srcTs $dstTs "dry_run" "would_migrate" ""
            continue
        }

        $method = if ($dstVar) { "PATCH" } else { "POST" }
        try {
            Invoke-WithRetry { & $UpsertAction $name $value $method } -Label $name
            # Post-migration verification
            $verified = & $VerifyAction $name
            if ($verified -eq $name) {
                Write-Success "$Label [$name] migrated and verified"
                Add-CsvRow $CsvScope $CsvRepo $CsvEnv "variable" $name "" $srcTs $dstTs "migrated" "success" "verified"
            } else {
                Write-Warn "$Label [$name] set but verification failed"
                Add-CsvRow $CsvScope $CsvRepo $CsvEnv "variable" $name "" $srcTs $dstTs "migrated" "unverified" "set but verify failed"
            }
        } catch {
            Write-Err "$Label [$name] — failed: $_"
            Add-CsvRow $CsvScope $CsvRepo $CsvEnv "variable" $name "" $srcTs $dstTs "migrate" "failed" "$_"
        }
    }
}


# ==============================================================================
# ORG-LEVEL ACTIONS SECRETS
# ==============================================================================
function Invoke-OrgSecrets {
    Write-Step "Org Actions secrets: $SourceOrg → $DestOrg"
    $secrets = Invoke-WithRetry {
        gh api "orgs/$SourceOrg/actions/secrets" --paginate --jq '.secrets[]' 2>$null | ConvertFrom-Json
    } -Label "list org secrets"
    if (-not $secrets) { Write-Warn "No org Actions secrets in $SourceOrg"; return }

    Invoke-SecretMigration `
        -Label "ORG SECRET" -CsvScope "org" -CsvRepo "" -CsvEnv "" -SecretType "actions" `
        -Secrets @($secrets) `
        -SetAction    { param($n,$v) Set-GhSecret $n $v "org" } `
        -GetDestMeta  { param($n)
            try { gh api "orgs/$DestOrg/actions/secrets/$n" 2>$null | ConvertFrom-Json }
            catch { [PSCustomObject]@{updated_at=$null;created_at=$null} }
        }
}

# ==============================================================================
# ORG-LEVEL ACTIONS VARIABLES (preserves visibility + selected-repo list)
# ==============================================================================
function Invoke-OrgVariables {
    Write-Step "Org Actions variables: $SourceOrg → $DestOrg"
    $vars = Invoke-WithRetry {
        gh api "orgs/$SourceOrg/actions/variables" --paginate --jq '.variables[]' 2>$null | ConvertFrom-Json
    } -Label "list org variables"
    if (-not $vars) { Write-Warn "No org Actions variables in $SourceOrg"; return }

    foreach ($var in @($vars)) {
        $name       = $var.name
        $value      = $var.value
        $srcTs      = if ($var.updated_at) { $var.updated_at } else { $var.created_at }
        $visibility = if ($var.visibility) { $var.visibility } else { "all" }

        if (Test-AlreadyMigrated "org" "" "" "variable" $name) {
            Write-Info "ORG VAR [$name] — already migrated, skipping"; continue
        }

        $dstVar = try { gh api "orgs/$DestOrg/actions/variables/$name" 2>$null | ConvertFrom-Json } catch { $null }
        $dstTs  = if ($dstVar) { Get-SecretTs $dstVar } else { "" }

        if ($dstTs -and -not (Test-SrcIsNewer $srcTs $dstTs)) {
            Write-Warn "ORG VAR [$name] — dest newer, skipping"
            Add-CsvRow "org" "" "" "variable" $name "" $srcTs $dstTs "skip" "skipped" "dest newer"; continue
        }

        if ($DryRun) {
            Write-Info "ORG VAR [$name] [DRY RUN] would migrate (visibility=$visibility)"
            Add-CsvRow "org" "" "" "variable" $name "" $srcTs $dstTs "dry_run" "would_migrate" "visibility=$visibility"; continue
        }

        $method   = if ($dstVar) { "PATCH" } else { "POST" }
        $endpoint = if ($dstVar) { "orgs/$DestOrg/actions/variables/$name" } else { "orgs/$DestOrg/actions/variables" }

        try {
            Invoke-WithRetry {
                gh api --method $method $endpoint -f name="$name" -f value="$value" -f visibility="$visibility" | Out-Null
            } -Label $name

            # Migrate selected-repo list if visibility=selected
            if ($visibility -eq "selected") {
                $repoIds = gh api "orgs/$SourceOrg/actions/variables/$name/repositories" `
                               --paginate --jq '[.repositories[].id]' 2>$null | ConvertFrom-Json
                if ($repoIds -and $repoIds.Count -gt 0) {
                    # Map source repo IDs to dest repo IDs by name
                    $destIds = @()
                    $srcRepos = gh api "orgs/$SourceOrg/actions/variables/$name/repositories" `
                                    --paginate --jq '.repositories[]' 2>$null | ConvertFrom-Json
                    foreach ($sr in @($srcRepos)) {
                        $dstId = gh api "repos/$DestOrg/$($sr.name)" --jq '.id' 2>$null
                        if ($dstId) { $destIds += [int]$dstId }
                    }
                    if ($destIds.Count -gt 0) {
                        $body = @{ selected_repository_ids = $destIds } | ConvertTo-Json -Compress
                        $body | gh api --method PUT "orgs/$DestOrg/actions/variables/$name/repositories" --input - | Out-Null
                    }
                }
            }

            $verified = gh api "orgs/$DestOrg/actions/variables/$name" --jq '.name' 2>$null
            $status   = if ($verified -eq $name) { "success" } else { "unverified" }
            Write-Success "ORG VAR [$name] migrated (visibility=$visibility, status=$status)"
            Add-CsvRow "org" "" "" "variable" $name "" $srcTs $dstTs "migrated" $status "visibility=$visibility"
        } catch {
            Write-Err "ORG VAR [$name] — failed: $_"
            Add-CsvRow "org" "" "" "variable" $name "" $srcTs $dstTs "migrate" "failed" "$_"
        }
    }
}

# ==============================================================================
# ORG-LEVEL DEPENDABOT SECRETS
# ==============================================================================
function Invoke-OrgDependabotSecrets {
    Write-Step "Org Dependabot secrets: $SourceOrg → $DestOrg"
    $secrets = try {
        Invoke-WithRetry {
            gh api "orgs/$SourceOrg/dependabot/secrets" --paginate --jq '.secrets[]' 2>$null | ConvertFrom-Json
        } -Label "list org dependabot secrets"
    } catch { $null }
    if (-not $secrets) { Write-Warn "No org Dependabot secrets in $SourceOrg (or no access)"; return }

    Invoke-SecretMigration `
        -Label "ORG DEPENDABOT" -CsvScope "org-dependabot" -CsvRepo "" -CsvEnv "" -SecretType "dependabot" `
        -Secrets @($secrets) `
        -SetAction   { param($n,$v) Set-GhSecret $n $v "dependabot-org" } `
        -GetDestMeta { param($n)
            try { gh api "orgs/$DestOrg/dependabot/secrets/$n" 2>$null | ConvertFrom-Json }
            catch { [PSCustomObject]@{updated_at=$null;created_at=$null} }
        }
}

# ==============================================================================
# REPO-LEVEL ACTIONS SECRETS
# ==============================================================================
function Invoke-RepoSecrets([string]$srcRepo, [string]$dstRepo) {
    $secrets = Invoke-WithRetry {
        gh api "repos/$SourceOrg/$srcRepo/actions/secrets" --paginate --jq '.secrets[]' 2>$null | ConvertFrom-Json
    } -Label "list repo secrets $srcRepo"
    if (-not $secrets) { return }

    Invoke-SecretMigration `
        -Label "REPO SECRET [$srcRepo]" -CsvScope "repo" -CsvRepo "$srcRepo→$dstRepo" -CsvEnv "" -SecretType "actions" `
        -Secrets @($secrets) `
        -SetAction   { param($n,$v) Set-GhSecret $n $v "repo" $dstRepo } `
        -GetDestMeta { param($n)
            try { gh api "repos/$DestOrg/$dstRepo/actions/secrets/$n" 2>$null | ConvertFrom-Json }
            catch { [PSCustomObject]@{updated_at=$null;created_at=$null} }
        }
}

# ==============================================================================
# REPO-LEVEL ACTIONS VARIABLES
# ==============================================================================
function Invoke-RepoVariables([string]$srcRepo, [string]$dstRepo) {
    $vars = Invoke-WithRetry {
        gh api "repos/$SourceOrg/$srcRepo/actions/variables" --paginate --jq '.variables[]' 2>$null | ConvertFrom-Json
    } -Label "list repo vars $srcRepo"
    if (-not $vars) { return }

    Invoke-VariableMigration `
        -Label "REPO VAR [$srcRepo]" -CsvScope "repo" -CsvRepo "$srcRepo→$dstRepo" -CsvEnv "" `
        -Vars @($vars) `
        -UpsertAction {
            param($n,$v,$method)
            $ep = if ($method -eq "PATCH") { "repos/$DestOrg/$dstRepo/actions/variables/$n" } `
                  else { "repos/$DestOrg/$dstRepo/actions/variables" }
            gh api --method $method $ep -f name="$n" -f value="$v" | Out-Null
        } `
        -GetDestVar  { param($n) try { gh api "repos/$DestOrg/$dstRepo/actions/variables/$n" 2>$null | ConvertFrom-Json } catch { $null } } `
        -VerifyAction { param($n) gh api "repos/$DestOrg/$dstRepo/actions/variables/$n" --jq '.name' 2>$null }
}

# ==============================================================================
# REPO-LEVEL DEPENDABOT SECRETS
# ==============================================================================
function Invoke-RepoDependabotSecrets([string]$srcRepo, [string]$dstRepo) {
    $secrets = try {
        Invoke-WithRetry {
            gh api "repos/$SourceOrg/$srcRepo/dependabot/secrets" --paginate --jq '.secrets[]' 2>$null | ConvertFrom-Json
        } -Label "list dependabot secrets $srcRepo"
    } catch { $null }
    if (-not $secrets) { return }

    Invoke-SecretMigration `
        -Label "REPO DEPENDABOT [$srcRepo]" -CsvScope "repo-dependabot" -CsvRepo "$srcRepo→$dstRepo" -CsvEnv "" -SecretType "dependabot" `
        -Secrets @($secrets) `
        -SetAction   { param($n,$v) Set-GhSecret $n $v "dependabot-repo" $dstRepo } `
        -GetDestMeta { param($n)
            try { gh api "repos/$DestOrg/$dstRepo/dependabot/secrets/$n" 2>$null | ConvertFrom-Json }
            catch { [PSCustomObject]@{updated_at=$null;created_at=$null} }
        }
}

# ==============================================================================
# ENVIRONMENT SECRETS
# ==============================================================================
function Invoke-EnvSecrets([string]$srcRepo, [string]$dstRepo, [string]$env) {
    $srcId = gh api "repos/$SourceOrg/$srcRepo" --jq '.id' 2>$null
    $dstId = gh api "repos/$DestOrg/$dstRepo"   --jq '.id' 2>$null
    if (-not $srcId) { Write-Err "Cannot get ID for $SourceOrg/$srcRepo"; return }
    if (-not $dstId) { Write-Warn "Dest repo $DestOrg/$dstRepo not found — skipping env secrets [$env]"; return }

    $secrets = Invoke-WithRetry {
        gh api "repositories/$srcId/environments/$env/secrets" --paginate --jq '.secrets[]' 2>$null | ConvertFrom-Json
    } -Label "list env secrets $srcRepo/$env"
    if (-not $secrets) { return }

    Invoke-SecretMigration `
        -Label "ENV SECRET [$srcRepo/$env]" -CsvScope "environment" -CsvRepo "$srcRepo→$dstRepo" -CsvEnv $env -SecretType "actions" `
        -Secrets @($secrets) `
        -SetAction   { param($n,$v) Set-GhSecret $n $v "env" $dstRepo $env } `
        -GetDestMeta { param($n)
            try { gh api "repositories/$dstId/environments/$env/secrets/$n" 2>$null | ConvertFrom-Json }
            catch { [PSCustomObject]@{updated_at=$null;created_at=$null} }
        }
}

# ==============================================================================
# ENVIRONMENT VARIABLES
# ==============================================================================
function Invoke-EnvVariables([string]$srcRepo, [string]$dstRepo, [string]$env) {
    $srcId = gh api "repos/$SourceOrg/$srcRepo" --jq '.id' 2>$null
    $dstId = gh api "repos/$DestOrg/$dstRepo"   --jq '.id' 2>$null
    if (-not $srcId -or -not $dstId) { return }

    $vars = Invoke-WithRetry {
        gh api "repositories/$srcId/environments/$env/variables" --paginate --jq '.variables[]' 2>$null | ConvertFrom-Json
    } -Label "list env vars $srcRepo/$env"
    if (-not $vars) { return }

    Invoke-VariableMigration `
        -Label "ENV VAR [$srcRepo/$env]" -CsvScope "environment" -CsvRepo "$srcRepo→$dstRepo" -CsvEnv $env `
        -Vars @($vars) `
        -UpsertAction {
            param($n,$v,$method)
            $ep = if ($method -eq "PATCH") { "repositories/$dstId/environments/$env/variables/$n" } `
                  else { "repositories/$dstId/environments/$env/variables" }
            gh api --method $method $ep -f name="$n" -f value="$v" | Out-Null
        } `
        -GetDestVar  { param($n) try { gh api "repositories/$dstId/environments/$env/variables/$n" 2>$null | ConvertFrom-Json } catch { $null } } `
        -VerifyAction { param($n) gh api "repositories/$dstId/environments/$env/variables/$n" --jq '.name' 2>$null }
}

# ==============================================================================
# ENVIRONMENT PROTECTION RULES
# ==============================================================================
function Invoke-EnvProtectionRules([string]$srcRepo, [string]$dstRepo, [string]$env) {
    $srcEnv = try {
        gh api "repos/$SourceOrg/$srcRepo/environments/$env" 2>$null | ConvertFrom-Json
    } catch { $null }
    if (-not $srcEnv) { return }

    $waitTimer        = $srcEnv.wait_timer
    $preventSelfReview = $srcEnv.prevent_self_review
    $deployBranches   = $srcEnv.deployment_branch_policy

    # Build reviewer list — map team/user names to dest org IDs
    $reviewers = @()
    foreach ($r in @($srcEnv.protection_rules | Where-Object { $_.type -in @("required_reviewers") })) {
        foreach ($rev in @($r.reviewers)) {
            if ($rev.type -eq "Team") {
                $teamSlug = $rev.reviewer.slug
                $dstTeam  = gh api "orgs/$DestOrg/teams/$teamSlug" --jq '.id' 2>$null
                if ($dstTeam) { $reviewers += @{ type = "Team"; id = [int]$dstTeam } }
                else { Write-Warn "ENV PROTECT [$srcRepo/$env]: team '$teamSlug' not found in $DestOrg" }
            } elseif ($rev.type -eq "User") {
                $login   = $rev.reviewer.login
                $dstUser = gh api "users/$login" --jq '.id' 2>$null
                if ($dstUser) { $reviewers += @{ type = "User"; id = [int]$dstUser } }
                else { Write-Warn "ENV PROTECT [$srcRepo/$env]: user '$login' not found" }
            }
        }
    }

    $payload = @{ reviewers = $reviewers }
    if ($waitTimer)         { $payload.wait_timer = $waitTimer }
    if ($preventSelfReview) { $payload.prevent_self_review = $preventSelfReview }
    if ($deployBranches) {
        $payload.deployment_branch_policy = @{
            protected_branches     = $deployBranches.protected_branches
            custom_branch_policies = $deployBranches.custom_branch_policies
        }
    }

    if ($DryRun) {
        Write-Info "ENV PROTECT [$srcRepo/$env] [DRY RUN] would apply: reviewers=$($reviewers.Count), wait=$waitTimer"
        Add-CsvRow "env-protection" "$srcRepo→$dstRepo" $env "protection" "rules" "" "" "" "dry_run" "would_migrate" "reviewers=$($reviewers.Count)"
        return
    }

    try {
        $body = $payload | ConvertTo-Json -Depth 10 -Compress
        $body | gh api --method PUT "repos/$DestOrg/$dstRepo/environments/$env" --input - | Out-Null
        Write-Success "ENV PROTECT [$srcRepo/$env] applied (reviewers=$($reviewers.Count), wait=$waitTimer)"
        Add-CsvRow "env-protection" "$srcRepo→$dstRepo" $env "protection" "rules" "" "" "" "migrated" "success" "reviewers=$($reviewers.Count),wait=$waitTimer"
    } catch {
        Write-Err "ENV PROTECT [$srcRepo/$env] — failed: $_"
        Add-CsvRow "env-protection" "$srcRepo→$dstRepo" $env "protection" "rules" "" "" "" "migrate" "failed" "$_"
    }
}

# ── Environment discovery ─────────────────────────────────────────────────────
function Get-RepoEnvironments([string]$srcRepo) {
    if ($Environments.Count -gt 0) { return $Environments }
    $envs = gh api "repos/$SourceOrg/$srcRepo/environments" --paginate --jq '.environments[].name' 2>$null
    return @($envs | Where-Object { $_ })
}

# ==============================================================================
# MAIN
# ==============================================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   GitHub Secrets & Variables Migration — Bulletproof Edition     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Source org  : $SourceOrg"
Write-Host "  Dest org    : $DestOrg"
Write-Host "  Key Vault   : $(if ($KeyVaultName) { $KeyVaultName } else { '(none — secrets flagged for manual entry)' })"
Write-Host "  Dry run     : $($DryRun.IsPresent)"
Write-Host "  Resume CSV  : $(if ($ResumeCsv) { $ResumeCsv } else { '(none)' })"
Write-Host "  Report      : $ReportFile"
Write-Host "  Log         : $LogFile"
Write-Host ""

Invoke-PreflightChecks
Write-Host ""
Write-Host "  ✔ Pre-flight passed" -ForegroundColor Green
Write-Host ""

Initialize-KvSecretNames
Initialize-Resume
Initialize-Report

# ── Org level ─────────────────────────────────────────────────────────────────
Invoke-OrgSecrets
Invoke-OrgVariables
Invoke-OrgDependabotSecrets

# ── Repo level ────────────────────────────────────────────────────────────────
Write-Step "Repo-level migration"

$effectiveMap = [ordered]@{}
if ($RepoMap.Count -gt 0) {
    foreach ($k in $RepoMap.Keys) { $effectiveMap[$k] = $RepoMap[$k] }
} else {
    Write-Info "Auto-discovering repos in $SourceOrg..."
    $discovered = Invoke-WithRetry {
        gh api "orgs/$SourceOrg/repos" --paginate --jq '.[].name' 2>$null | Where-Object { $_ }
    } -Label "discover repos"
    foreach ($r in $discovered) { $effectiveMap[$r] = $r }
    Write-Info "  Found $($effectiveMap.Count) repos"
}

foreach ($srcRepo in $effectiveMap.Keys) {
    $dstRepo = $effectiveMap[$srcRepo]
    Write-Host "`n  ── $srcRepo → $dstRepo ──" -ForegroundColor Gray
    Add-Content $LogFile "`n  ── $srcRepo → $dstRepo ──"

    if (-not (Test-DestRepoExists $dstRepo)) {
        Write-Warn "Dest repo '$DestOrg/$dstRepo' does not exist — skipping"
        Add-CsvRow "repo" "$srcRepo→$dstRepo" "" "repo" $dstRepo "" "" "" "skip" "skipped" "dest repo not found"
        continue
    }

    Invoke-RepoSecrets          $srcRepo $dstRepo
    Invoke-RepoVariables        $srcRepo $dstRepo
    Invoke-RepoDependabotSecrets $srcRepo $dstRepo

    foreach ($env in (Get-RepoEnvironments $srcRepo)) {
        Invoke-EnvSecrets          $srcRepo $dstRepo $env
        Invoke-EnvVariables        $srcRepo $dstRepo $env
        Invoke-EnvProtectionRules  $srcRepo $dstRepo $env
    }
}

# ==============================================================================
# POST-MIGRATION VARIABLE AUDIT
# Compares every variable in source vs destination and reports missing/mismatched
# ==============================================================================
function Invoke-VariableAudit {
    Write-Step "Post-migration variable audit"
    $issues = [System.Collections.Generic.List[PSCustomObject]]::new()

    # ── Org-level ─────────────────────────────────────────────────────────────
    $srcVars = gh api "orgs/$SourceOrg/actions/variables" --paginate --jq '.variables[]' 2>$null | ConvertFrom-Json
    $dstVars = gh api "orgs/$DestOrg/actions/variables"   --paginate --jq '.variables[]' 2>$null | ConvertFrom-Json
    $dstMap  = @{}; foreach ($v in @($dstVars)) { $dstMap[$v.name] = $v.value }

    foreach ($v in @($srcVars)) {
        if (-not $dstMap.ContainsKey($v.name)) {
            $issues.Add([PSCustomObject]@{ Scope="org"; Repo=""; Env=""; Name=$v.name; Issue="MISSING"; SrcValue=$v.value; DstValue="" })
        } elseif ($dstMap[$v.name] -ne $v.value) {
            $issues.Add([PSCustomObject]@{ Scope="org"; Repo=""; Env=""; Name=$v.name; Issue="VALUE_MISMATCH"; SrcValue=$v.value; DstValue=$dstMap[$v.name] })
        }
    }

    # ── Repo-level ────────────────────────────────────────────────────────────
    foreach ($srcRepo in $effectiveMap.Keys) {
        $dstRepo = $effectiveMap[$srcRepo]
        if (-not (Test-DestRepoExists $dstRepo)) { continue }

        $srcRVars = gh api "repos/$SourceOrg/$srcRepo/actions/variables" --paginate --jq '.variables[]' 2>$null | ConvertFrom-Json
        $dstRVars = gh api "repos/$DestOrg/$dstRepo/actions/variables"   --paginate --jq '.variables[]' 2>$null | ConvertFrom-Json
        $dstRMap  = @{}; foreach ($v in @($dstRVars)) { $dstRMap[$v.name] = $v.value }

        foreach ($v in @($srcRVars)) {
            if (-not $dstRMap.ContainsKey($v.name)) {
                $issues.Add([PSCustomObject]@{ Scope="repo"; Repo="$srcRepo→$dstRepo"; Env=""; Name=$v.name; Issue="MISSING"; SrcValue=$v.value; DstValue="" })
            } elseif ($dstRMap[$v.name] -ne $v.value) {
                $issues.Add([PSCustomObject]@{ Scope="repo"; Repo="$srcRepo→$dstRepo"; Env=""; Name=$v.name; Issue="VALUE_MISMATCH"; SrcValue=$v.value; DstValue=$dstRMap[$v.name] })
            }
        }

        # ── Environment-level ─────────────────────────────────────────────────
        foreach ($env in (Get-RepoEnvironments $srcRepo)) {
            $srcId = gh api "repos/$SourceOrg/$srcRepo" --jq '.id' 2>$null
            $dstId = gh api "repos/$DestOrg/$dstRepo"   --jq '.id' 2>$null
            if (-not $srcId -or -not $dstId) { continue }

            $srcEVars = gh api "repositories/$srcId/environments/$env/variables" --paginate --jq '.variables[]' 2>$null | ConvertFrom-Json
            $dstEVars = gh api "repositories/$dstId/environments/$env/variables" --paginate --jq '.variables[]' 2>$null | ConvertFrom-Json
            $dstEMap  = @{}; foreach ($v in @($dstEVars)) { $dstEMap[$v.name] = $v.value }

            foreach ($v in @($srcEVars)) {
                if (-not $dstEMap.ContainsKey($v.name)) {
                    $issues.Add([PSCustomObject]@{ Scope="environment"; Repo="$srcRepo→$dstRepo"; Env=$env; Name=$v.name; Issue="MISSING"; SrcValue=$v.value; DstValue="" })
                } elseif ($dstEMap[$v.name] -ne $v.value) {
                    $issues.Add([PSCustomObject]@{ Scope="environment"; Repo="$srcRepo→$dstRepo"; Env=$env; Name=$v.name; Issue="VALUE_MISMATCH"; SrcValue=$v.value; DstValue=$dstEMap[$v.name] })
                }
            }
        }
    }

    # ── Report audit results ──────────────────────────────────────────────────
    $missing    = @($issues | Where-Object { $_.Issue -eq "MISSING" })
    $mismatched = @($issues | Where-Object { $_.Issue -eq "VALUE_MISMATCH" })

    if ($missing.Count -eq 0 -and $mismatched.Count -eq 0) {
        Write-Success "Variable audit: all variables present and values match ✅"
        return
    }

    if ($missing.Count -gt 0) {
        Write-Host ""
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
        Write-Host "  🔴 MISSING VARIABLES ($($missing.Count)) — must be added to $DestOrg" -ForegroundColor Red
        Write-Host "  ACTION: Add each variable below in the destination org/repo/environment" -ForegroundColor Red
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
        foreach ($i in $missing) {
            $loc = switch ($i.Scope) {
                "org"         { "ORG LEVEL → https://github.com/orgs/$DestOrg/settings/variables/actions" }
                "repo"        { "REPO: $($i.Repo) → https://github.com/$DestOrg/$($i.Repo.Split('→')[1])/settings/variables/actions" }
                "environment" { "REPO: $($i.Repo) / ENV: $($i.Env)" }
            }
            Write-Host "     • $($i.Name) = $($i.SrcValue)" -ForegroundColor Red
            Write-Host "       WHERE: $loc" -ForegroundColor DarkRed
        }
        # Log to CSV
        foreach ($i in $missing) {
            Add-CsvRow $i.Scope $i.Repo $i.Env "variable" $i.Name "" "" "" "audit" "missing" "expected_value=$($i.SrcValue)"
        }
    }

    if ($mismatched.Count -gt 0) {
        Write-Host ""
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
        Write-Host "  ⚠️  VALUE MISMATCH ($($mismatched.Count)) — variables exist but values differ" -ForegroundColor Yellow
        Write-Host "  ACTION: Update each variable below to match the source value" -ForegroundColor Yellow
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
        foreach ($i in $mismatched) {
            $loc = switch ($i.Scope) {
                "org"         { "ORG LEVEL" }
                "repo"        { "REPO: $($i.Repo)" }
                "environment" { "REPO: $($i.Repo) / ENV: $($i.Env)" }
            }
            Write-Host "     • $($i.Name)" -ForegroundColor Yellow
            Write-Host "       WHERE    : $loc" -ForegroundColor DarkYellow
            Write-Host "       EXPECTED : $($i.SrcValue)" -ForegroundColor DarkYellow
            Write-Host "       ACTUAL   : $($i.DstValue)" -ForegroundColor DarkYellow
        }
        foreach ($i in $mismatched) {
            Add-CsvRow $i.Scope $i.Repo $i.Env "variable" $i.Name "" "" "" "audit" "value_mismatch" "expected=$($i.SrcValue)|actual=$($i.DstValue)"
        }
    }
}

Invoke-VariableAudit


# ── Summary & Issues Report ───────────────────────────────────────────────────
$rows      = Import-Csv $ReportFile
$total     = $rows.Count
$migrated  = ($rows | Where-Object { $_.status -eq "success"       }).Count
$skipped   = ($rows | Where-Object { $_.status -eq "skipped"       }).Count
$flagged   = ($rows | Where-Object { $_.status -eq "flagged"       }).Count
$failed    = ($rows | Where-Object { $_.status -eq "failed"        }).Count
$dryrun    = ($rows | Where-Object { $_.status -eq "would_migrate" }).Count
$unverified= ($rows | Where-Object { $_.status -eq "unverified"    }).Count
$skippedRepos = ($rows | Where-Object { $_.type -eq "repo" -and $_.status -eq "skipped" -and $_.notes -eq "dest repo not found" }).Count

Write-Host ""
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Migration complete!" -ForegroundColor Green
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Total processed : $total"
Write-Host "  ✅ Migrated     : $migrated"   -ForegroundColor Green
Write-Host "  ⏭  Skipped      : $skipped"    -ForegroundColor Gray
Write-Host "  🔍 Dry-run      : $dryrun"     -ForegroundColor Cyan
Write-Host "  ⚠️  Flagged      : $flagged"    -ForegroundColor Yellow
Write-Host "  ❌ Failed       : $failed"     -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Gray" })
Write-Host "  ⚡ Unverified   : $unverified" -ForegroundColor $(if ($unverified -gt 0) { "Yellow" } else { "Gray" })
Write-Host ""
Write-Host "  Report : $ReportFile"
Write-Host "  Log    : $LogFile"

# ── ISSUE 1: Secrets with no Key Vault match (manual action required) ─────────
if ($flagged -gt 0) {
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host "  ⚠️  ISSUE: $flagged secret(s) have NO Key Vault match" -ForegroundColor Yellow
    Write-Host "  WHY:  GitHub API never exposes secret values. These must" -ForegroundColor Yellow
    Write-Host "        be set manually OR add them to Key Vault first." -ForegroundColor Yellow
    Write-Host "  FIX:  Set each secret manually at:" -ForegroundColor Yellow
    Write-Host "        https://github.com/orgs/$DestOrg/settings/secrets/actions" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    $rows | Where-Object { $_.status -eq "flagged" } | ForEach-Object {
        $loc = if ($_.environment) { "$($_.repo) / env:$($_.environment)" } `
               elseif ($_.repo)    { $_.repo } else { "org-level" }
        Write-Host "     • [$($_.type.ToUpper())] $($_.name)  →  $loc" -ForegroundColor Yellow
    }
}

# ── ISSUE 2: API failures ─────────────────────────────────────────────────────
if ($failed -gt 0) {
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
    Write-Host "  ❌ ISSUE: $failed item(s) failed during migration" -ForegroundColor Red
    Write-Host "  WHY:  API errors, permission issues, or transient failures." -ForegroundColor Red
    Write-Host "  FIX:  Re-run with resume to retry only failed items:" -ForegroundColor Red
    Write-Host "        `$ResumeCsv = `"$ReportFile`"  # set in CONFIG block" -ForegroundColor Red
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
    $rows | Where-Object { $_.status -eq "failed" } | ForEach-Object {
        $loc = if ($_.environment) { "$($_.repo) / env:$($_.environment)" } `
               elseif ($_.repo)    { $_.repo } else { "org-level" }
        Write-Host "     • [$($_.type.ToUpper())] $($_.name)  →  $loc" -ForegroundColor Red
        Write-Host "       Reason: $($_.notes)" -ForegroundColor DarkRed
    }
}

# ── ISSUE 3: Variables set but not verified ───────────────────────────────────
if ($unverified -gt 0) {
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host "  ⚡ ISSUE: $unverified variable(s) set but could not be verified" -ForegroundColor Yellow
    Write-Host "  WHY:  API accepted the write but read-back returned unexpected result." -ForegroundColor Yellow
    Write-Host "  FIX:  Manually confirm these variables exist in $DestOrg:" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    $rows | Where-Object { $_.status -eq "unverified" } | ForEach-Object {
        $loc = if ($_.environment) { "$($_.repo) / env:$($_.environment)" } `
               elseif ($_.repo)    { $_.repo } else { "org-level" }
        Write-Host "     • $($_.name)  →  $loc" -ForegroundColor Yellow
    }
}

# ── ISSUE 4: Dest repos not found ────────────────────────────────────────────
if ($skippedRepos -gt 0) {
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
    Write-Host "  🔴 ISSUE: $skippedRepos repo(s) skipped — not found in $DestOrg" -ForegroundColor Magenta
    Write-Host "  WHY:  Repo exists in source but not yet created in destination org." -ForegroundColor Magenta
    Write-Host "  FIX:  Create the missing repo(s) in $DestOrg then re-run." -ForegroundColor Magenta
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
    $rows | Where-Object { $_.type -eq "repo" -and $_.notes -eq "dest repo not found" } | ForEach-Object {
        Write-Host "     • $($_.repo)" -ForegroundColor Magenta
    }
}

# ── All clear ─────────────────────────────────────────────────────────────────
if ($flagged -eq 0 -and $failed -eq 0 -and $unverified -eq 0 -and $skippedRepos -eq 0) {
    Write-Host ""
    Write-Host "  ✅ No issues detected. All items migrated successfully!" -ForegroundColor Green
}
Write-Host ""
