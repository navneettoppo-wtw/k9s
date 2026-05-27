<#
.SYNOPSIS
    Queries Azure Entra for app registrations matching one or more prefixes and
    generates ready-to-run addAppSecretToEnvs.ps1 commands, written to an output file.

.DESCRIPTION
    Supports two input modes:

    SINGLE mode  (-SpnPrefix + -RepoNames)
        Looks up one prefix, maps it to DEV/QA/RC/IAT/PROD, and emits one command.

    CSV mode  (-CsvPath)
        Reads a CSV with columns 'repo' and 'spnPrefix'.
        Rows are grouped by spnPrefix; all repos that share a prefix are combined
        into a single addAppSecretToEnvs.ps1 call.
        CSV example:
            repo,spnPrefix
            rna-sdk-currency-api,CRBRA SDK Currency
            rna-sdk-currency-web,CRBRA SDK Currency

    In both modes:
    - Owned-app registrations are fetched once from the signed-in user.
    - Both the space variant and dash variant of a prefix are matched locally,
      avoiding the OData hyphen-filter bug.
    - Generated commands are written to -OutputFile (default: .\addAppSecretCommands.ps1).
    - A SPN ending in "DEV-QA" / "DEV QA" is assigned to both DEV and QA.
    - Assumes the caller is already logged in to the Azure CLI.

.PARAMETER SpnPrefix
    [Single mode] Prefix shared by all target app registrations.
    Example: "CRBRA SDK Localisation"  -or-  "CRBRA-SDK-Localisation"

.PARAMETER RepoNames
    [Single mode] One or more GitHub repository names.
    Example: @("rna-sdk-localisation-api")

.PARAMETER CsvPath
    [CSV mode] Path to a CSV file with columns 'repo' and 'spnPrefix'.

.PARAMETER OutputFile
    Path for the generated commands file.
    Defaults to .\addAppSecretCommands.ps1 in the same directory as this script.

.EXAMPLE
    # Single mode
    .\findSpnsAndBuildCommand.ps1 -SpnPrefix "CRBRA SDK Localisation" -RepoNames @("rna-sdk-localisation-api")

.EXAMPLE
    # CSV mode
    .\findSpnsAndBuildCommand.ps1 -CsvPath .\findSpns.csv
#>

[CmdletBinding(DefaultParameterSetName = 'Single')]
param (
    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [string] $SpnPrefix,

    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [ValidateCount(1, 100)]
    [string[]] $RepoNames,

    [Parameter(Mandatory, ParameterSetName = 'Csv')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $CsvPath,

    [Parameter()]
    [string] $OutputFile = (Join-Path $PSScriptRoot "addAppSecretCommands.ps1")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Environments = @("DEV", "QA", "RC", "IAT", "PROD")

# ---------------------------------------------------------------------------
# Helper — map a list of SPNs to the 5 environments
# ---------------------------------------------------------------------------
function Find-SpnForEnv {
    param(
        [string]   $Env,
        [string[]] $Apps
    )

    # Exact suffix: "...PROD" or "...-PROD"
    $exactMatch = $Apps |
        Where-Object { $_ -match "(?i)[- ]$([regex]::Escape($Env))\s*$" } |
        Select-Object -First 1

    if ($exactMatch) { return $exactMatch }

    # DEV / QA may be covered by a combined "DEV-QA" or "DEV QA" SPN
    if ($Env -eq 'DEV' -or $Env -eq 'QA') {
        $devQaMatch = $Apps |
            Where-Object { $_ -match '(?i)[- ]DEV[-\s]QA\s*$' } |
            Select-Object -First 1

        if ($devQaMatch) { return $devQaMatch }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Helper — given a prefix and repos, build one command block
# Returns: @{ Command=string; AllFound=bool; Warnings=string[]; Apps=string[] }
# ---------------------------------------------------------------------------
function Build-Command {
    param(
        [string]   $Prefix,
        [string[]] $Repos,
        [string[]] $OwnedApps
    )

    $prefixSpaces = $Prefix -replace '-', ' ' -replace '\s+', ' '
    $prefixDashes = $Prefix -replace '\s+', '-'

    $matchedApps = @($OwnedApps |
        Where-Object { $_.StartsWith($prefixSpaces, [System.StringComparison]::OrdinalIgnoreCase) -or
                       $_.StartsWith($prefixDashes,  [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object -Unique)

    $warnings = [System.Collections.Generic.List[string]]::new()

    if ($matchedApps.Count -eq 0) {
        return @{
            Command  = $null
            AllFound = $false
            Warnings = @("No app registrations found for prefix '$Prefix'.")
            Apps     = @()
        }
    }

    $spnMap   = @{}
    $allFound = $true

    foreach ($env in $Environments) {
        $spn = Find-SpnForEnv -Env $env -Apps $matchedApps
        $spnMap[$env] = $spn
        if (-not $spn) {
            $allFound = $false
            $warnings.Add("[$env] SPN not found for prefix '$Prefix'.")
        }
    }

    $spnArgs  = $Environments | ForEach-Object {
        $v = $spnMap[$_]
        if ($v) { "`"$v`"" } else { "`"<<$_ SPN NOT FOUND>>`"" }
    }
    $repoArgs = $Repos | ForEach-Object { "`"$_`"" }

    $cmd = ".\addAppSecretToEnvs.ps1 ``
    -RepoNames @($($repoArgs -join ', ')) ``
    -SpnNames  @($($spnArgs  -join ', '))"

    return @{
        Command  = $cmd
        AllFound = $allFound
        Warnings = $warnings
        Apps     = $matchedApps
    }
}

# ---------------------------------------------------------------------------
# Build the list of jobs: each job = { Prefix; Repos[] }
# ---------------------------------------------------------------------------
$jobs = [System.Collections.Generic.List[hashtable]]::new()

if ($PSCmdlet.ParameterSetName -eq 'Csv') {
    Write-Host ""
    Write-Host "===================================================================" -ForegroundColor DarkCyan
    Write-Host " Reading CSV: $CsvPath" -ForegroundColor Cyan
    Write-Host "===================================================================" -ForegroundColor DarkCyan

    $csvRows = Import-Csv -Path $CsvPath

    # Validate columns
    $cols = ($csvRows | Select-Object -First 1).PSObject.Properties.Name
    if ('repo' -notin $cols -or 'spnPrefix' -notin $cols) {
        Write-Host "ERROR: CSV must contain columns 'repo' and 'spnPrefix'." -ForegroundColor Red
        exit 1
    }

    # Group by spnPrefix (preserves original casing)
    $grouped = $csvRows | Group-Object spnPrefix

    foreach ($group in $grouped) {
        $repos = @($group.Group | ForEach-Object { $_.repo.Trim() } | Sort-Object -Unique)
        Write-Host ("  Prefix: {0}  ({1} repo(s))" -f $group.Name, $repos.Count) -ForegroundColor Gray
        $repos | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkGray }
        $jobs.Add(@{ Prefix = $group.Name.Trim(); Repos = $repos })
    }

    Write-Host ""
    Write-Host "  $($jobs.Count) unique prefix group(s) to process." -ForegroundColor Cyan
} else {
    $jobs.Add(@{ Prefix = $SpnPrefix; Repos = $RepoNames })
}

# ---------------------------------------------------------------------------
# Fetch owned app registrations once
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Fetching owned app registrations from Azure Entra" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor DarkCyan

$ownedRaw = az ad signed-in-user list-owned-objects --type application --query "[].displayName" -o tsv 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to list owned app registrations: $ownedRaw" -ForegroundColor Red
    exit 1
}

$ownedApps = @($ownedRaw -split "`n" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' })

Write-Host "  $($ownedApps.Count) owned app registration(s) retrieved." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Process each job and collect output lines
# ---------------------------------------------------------------------------
$outputLines = [System.Collections.Generic.List[string]]::new()
$totalJobs   = $jobs.Count
$successJobs = 0
$warningJobs = 0

$outputLines.Add("# Generated by findSpnsAndBuildCommand.ps1")
$outputLines.Add("# $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$outputLines.Add("# Review and run each block. Lines starting with # are comments.")
$outputLines.Add("")

foreach ($job in $jobs) {

    Write-Host ""
    Write-Host "===================================================================" -ForegroundColor DarkCyan
    Write-Host " Prefix: $($job.Prefix)" -ForegroundColor Cyan
    Write-Host " Repos : $($job.Repos -join ', ')" -ForegroundColor Cyan
    Write-Host "===================================================================" -ForegroundColor DarkCyan

    $result = Build-Command -Prefix $job.Prefix -Repos $job.Repos -OwnedApps $ownedApps

    if ($result.Apps.Count -gt 0) {
        Write-Host "  Matched SPNs:" -ForegroundColor Gray
        foreach ($a in $result.Apps) { Write-Host "    - $a" -ForegroundColor White }
        Write-Host ""

        foreach ($env in $Environments) {
            $spn = Find-SpnForEnv -Env $env -Apps $result.Apps
            if ($spn) {
                Write-Host ("  {0,-6} -> {1}" -f $env, $spn) -ForegroundColor Green
            } else {
                Write-Host ("  {0,-6} -> *** NOT FOUND ***" -f $env) -ForegroundColor Red
            }
        }
    }

    # Output file block
    $outputLines.Add("# ------------------------------------------------------------------")
    $outputLines.Add("# Prefix : $($job.Prefix)")
    $outputLines.Add("# Repos  : $($job.Repos -join ', ')")

    if (-not $result.Command) {
        foreach ($w in $result.Warnings) {
            Write-Host "  WARNING: $w" -ForegroundColor Red
            $outputLines.Add("# WARNING: $w")
        }
        $outputLines.Add("# *** COMMAND COULD NOT BE GENERATED — see warnings above ***")
        $warningJobs++
    } elseif (-not $result.AllFound) {
        foreach ($w in $result.Warnings) {
            Write-Host "  WARNING: $w" -ForegroundColor DarkYellow
            $outputLines.Add("# WARNING: $w")
        }
        $outputLines.Add("# STATUS: INCOMPLETE — replace <<ENV SPN NOT FOUND>> placeholders")
        $outputLines.Add($result.Command)
        $warningJobs++
    } else {
        $outputLines.Add("# STATUS: OK")
        $outputLines.Add($result.Command)
        $successJobs++
        Write-Host ""
        Write-Host "  All 5 environments mapped successfully." -ForegroundColor Green
    }

    $outputLines.Add("")
}

# ---------------------------------------------------------------------------
# Write output file
# ---------------------------------------------------------------------------
$outputLines | Set-Content -Path $OutputFile -Encoding UTF8

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor DarkCyan
Write-Host ("  Total   : {0}" -f $totalJobs)   -ForegroundColor White
Write-Host ("  OK      : {0}" -f $successJobs)  -ForegroundColor Green
Write-Host ("  Warnings: {0}" -f $warningJobs)  -ForegroundColor $(if ($warningJobs -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ""
Write-Host "  Output written to:" -ForegroundColor Cyan
Write-Host "  $OutputFile" -ForegroundColor White
Write-Host ""

if ($PSCmdlet.ParameterSetName -eq 'Single' -and $successJobs -eq 1) {
    # Single mode — also copy to clipboard for convenience
    $result.Command | Set-Clipboard
    Write-Host "  (Command also copied to clipboard)" -ForegroundColor DarkGray
    Write-Host ""
}
