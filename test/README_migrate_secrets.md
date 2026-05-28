# GitHub Secrets & Variables Migration

Migrates GitHub Actions secrets, variables, and environment secrets/variables between two GitHub organisations. Production-grade, idempotent, non-destructive.

| File | Platform |
|---|---|
| `migrate_secrets.sh` | Linux / macOS (bash) |
| `migrate_secrets.ps1` | Windows (PowerShell) |

---

## What it migrates

| Scope | Secrets | Variables |
|---|---|---|
| Organisation | ✅ auto-migrated via Key Vault | ✅ auto-migrated |
| Repository | ✅ auto-migrated via Key Vault | ✅ auto-migrated |
| Environment | ✅ auto-migrated via Key Vault | ✅ auto-migrated |

> If a secret name is not found in Key Vault, it is flagged in the CSV report for manual entry rather than silently skipped.

---

## How secret values are migrated

GitHub's API **never exposes secret values** — this is an intentional security design. The script works around this by reading values directly from Azure Key Vault.

```
Source GitHub org          Azure Key Vault           Dest GitHub org
──────────────────         ───────────────           ───────────────
MY_DATABASE_PASSWORD  →→→  my-database-password  →→→  MY_DATABASE_PASSWORD
API_KEY               →→→  api-key               →→→  API_KEY
JWT_SECRET            →→→  jwt-secret            →→→  JWT_SECRET
```

**No manual export needed.** The script:
1. Reads the secret **name** from the source GitHub org/repo/environment
2. Looks up the **value** from Key Vault using the normalised name (`MY_SECRET` → `my-secret`)
3. Sets the secret with that value in the destination

### What if a secret is not in Key Vault?

If a secret exists in GitHub but has no matching entry in Key Vault, it is flagged as `manual_required` in the CSV report and skipped. This means the secret was originally set directly in GitHub without being stored in Key Vault.

Fix: add it to Key Vault, then re-run. The script is idempotent and will only process what is missing or newer.

```bash
az keyvault secret set \
  --vault-name my-keyvault \
  --name my-database-password \
  --value "actual-secret-value"

./migrate_secrets.sh   # re-run — only processes flagged items
```

---



If a secret or variable already exists in the destination and its `updated_at` timestamp is **equal to or newer** than the source, it is skipped. Nothing is ever deleted.

---

## Prerequisites

### Tools

| Tool | Bash | PowerShell | Auto-install via |
|---|---|---|---|
| [`gh` CLI](https://cli.github.com/) | ✅ required | ✅ required | `apt/brew/yum` · `winget` |
| [`az` CLI](https://aka.ms/installazurecli) | ✅ required (Key Vault) | ✅ required (Key Vault) | manual |
| `jq` | ✅ required | ❌ not needed | `apt/brew/yum` |
| `python3` | ✅ required | ❌ not needed | `apt/brew/yum` |

`gh`, `jq`, and `python3` are auto-installed by the script if missing. `az` CLI must be installed manually if using Key Vault.

### Azure Key Vault access

The `az` CLI must be authenticated and the identity must have at least the **Key Vault Secrets User** role on the vault.

```bash
az login
az keyvault show --name my-keyvault --query "name"   # verify access
```

Secret names in Key Vault must match GitHub secret names with this normalisation:
- Uppercase → lowercase
- Underscores `_` → hyphens `-`

Example: GitHub secret `MY_DATABASE_PASSWORD` → Key Vault secret `my-database-password`

### gh CLI — authenticated to both organisations

**Same GitHub account (both orgs):**
```bash
gh auth login   # one login covers both orgs
```

**Different GitHub accounts:**
```bash
gh auth login --hostname github.com   # first account (default)
gh auth login --hostname github.com   # second account
gh auth switch --user <username>      # switch between them
```

**Recommended for production — single PAT with access to both orgs:**
```bash
export GITHUB_TOKEN="ghp_your_token_here"
```

### Required token scopes

| Scope | Why |
|---|---|
| `repo` | Read/write repo secrets and variables |
| `admin:org` | Read/write org secrets and variables |
| `read:org` | Discover repos and environments |

For a fine-grained PAT, grant on both orgs: `Secrets: Read & Write`, `Variables: Read & Write`, `Environments: Read & Write`.

### Pre-run verification

```bash
gh auth status
gh api orgs/source-org-name --jq '.login'
gh api orgs/dest-org-name   --jq '.login'
gh api orgs/source-org-name/actions/secrets --jq '.total_count'  # 403 = missing admin:org
az keyvault secret list --vault-name my-keyvault --query "[].name" -o tsv
```

---

## Configuration

All settings live in the `CONFIG` block at the top of each script. Edit before running — no command-line arguments needed.

### Bash (`migrate_secrets.sh`)

```bash
GH_API_HOST="https://api.github.com"   # change for GitHub Enterprise Server

SOURCE_ORG="source-org-name"           # org to migrate FROM
DEST_ORG="dest-org-name"               # org to migrate TO
KEY_VAULT_NAME="my-keyvault"           # leave empty to flag secrets for manual entry
DRY_RUN="false"                        # set to "true" to preview without writing

# Single repo — same name in both orgs:
declare -A REPO_MAP=(["my-api"]="my-api")

# Single repo — renamed in destination:
declare -A REPO_MAP=(["old-service"]="new-service")

# Multiple repos:
declare -A REPO_MAP=(
  ["repo-one"]="repo-one"
  ["repo-two"]="repo-two"
  ["legacy-api"]="modern-api"
)

# Leave empty to auto-discover ALL repos (same name assumed in dest org):
declare -A REPO_MAP=()

# Environments (leave empty to auto-discover all):
ENVIRONMENTS=("production" "staging")
```

### PowerShell (`migrate_secrets.ps1`)

```powershell
$GhApiHost    = "https://api.github.com"   # change for GitHub Enterprise Server

$SourceOrg    = "source-org-name"
$DestOrg      = "dest-org-name"
$KeyVaultName = "my-keyvault"              # leave empty to flag secrets for manual entry

# Single repo — same name:
$RepoMap = @{ "my-api" = "my-api" }

# Single repo — renamed:
$RepoMap = @{ "old-service" = "new-service" }

# Multiple repos:
$RepoMap = [ordered]@{
    "repo-one"   = "repo-one"
    "repo-two"   = "repo-two"
    "legacy-api" = "modern-api"
}

# Leave empty to auto-discover ALL repos:
$RepoMap = @{}

# Environments (leave empty to auto-discover all):
$Environments = @("production", "staging")
```

---

## Startup sequence

When the script starts it runs **all pre-flight checks first**, before creating any files or making any API calls. If any check fails the script exits immediately with a clear error.

```
╔══════════════════════════════════════════════════════════════╗
║   GitHub Secrets & Variables Migration — 2026 Edition       ║
╚══════════════════════════════════════════════════════════════╝

    GitHub API : https://api.github.com
    Source org : source-org
    Dest org   : dest-org
    Key Vault  : my-keyvault
    Dry run    : false

==> Pre-flight checks
    [OK]   gh CLI: found
    [OK]   GitHub CLI: authenticated
    [OK]   Azure Key Vault: my-keyvault (accessible)
    [OK]   GitHub org: source-org (accessible)
    [OK]   GitHub org: dest-org (accessible)

  ✔ All pre-flight checks passed — starting migration

==> Org-level migration
...
```

Pre-flight checks (in order):

1. Config placeholders replaced (fails immediately if `source-org-name` / `dest-org-name` still set)
2. `gh` CLI installed (auto-installs if missing)
3. `gh` CLI authenticated to GitHub
4. `az` CLI installed and authenticated *(only when Key Vault name is set)*
5. Key Vault accessible *(only when Key Vault name is set)*
6. Source org reachable via API
7. Destination org reachable via API

**Nothing is written — no CSV, no secrets, no variables — until all checks pass.**

---

## Usage

### Bash

```bash
# Always dry-run first
DRY_RUN=true ./migrate_secrets.sh

# Real run
./migrate_secrets.sh
```

### PowerShell

```powershell
# Always dry-run first
.\migrate_secrets.ps1 -DryRun

# Real run
.\migrate_secrets.ps1
```

---

## Output files

Both files are timestamped so previous runs are never overwritten.

| File | Contents |
|---|---|
| `migration_report_YYYYMMDD_HHMMSS.csv` | Full audit trail — open in Excel or Google Sheets |
| `migration_YYYYMMDD_HHMMSS.log` | Terminal output log |

### CSV columns

```
timestamp_utc, scope, repo, environment, type, name,
source_updated_at, dest_updated_at, action, status, notes
```

### Status values

| Status | Meaning |
|---|---|
| `success` | Migrated and verified |
| `skipped` | Dest is newer or equal — no action taken |
| `flagged` | Secret not found in Key Vault — set manually |
| `would_migrate` | Dry-run preview |
| `unverified` | Set but re-read check failed |
| `failed` | API error — check log for details |

---

## Known limitations

| Limitation | Impact | Mitigation |
|---|---|---|
| GitHub API rate limit (5000 req/hr) | Large orgs with 100s of repos may hit the limit mid-run | Re-run — idempotency means it resumes safely |
| Org secret visibility (`selected` repos) | Visibility is copied but the selected-repo list is not — migrated org secrets default to `all` | Manually restrict visibility in dest org after migration |
| Key Vault naming mismatch | `MY_SECRET` → `my-secret` normalisation may not match your KV convention | Check KV names before running; mismatches appear as `flagged` in CSV |

---

## After the migration

1. Open the CSV report and filter `status = flagged`
2. For each flagged secret, either add it to Key Vault and re-run, or set manually:
   - **Org secrets:** `https://github.com/orgs/<DEST_ORG>/settings/secrets/actions`
   - **Repo secrets:** `https://github.com/<DEST_ORG>/<repo>/settings/secrets/actions`
   - **Env secrets:** `https://github.com/<DEST_ORG>/<repo>/settings/environments`

---

## Design principles

### Files

| File | Purpose |
|---|---|
| `migrate_secrets.sh` | Migration script — Linux / macOS (bash) |
| `migrate_secrets.ps1` | Migration script — Windows (PowerShell) |
| `README_migrate_secrets.md` | This documentation |

### What the scripts do

- Migrate org-level, repo-level, and environment secrets and variables between two GitHub organisations
- Read secret values directly from Azure Key Vault — no manual export needed
- Idempotent — skip anything where the destination is newer; never delete anything
- Run all pre-flight checks before touching anything — abort immediately on any failure
- Produce a timestamped CSV audit report and log file on every run

### Quick start

```bash
# 1. Edit the CONFIG block — set SOURCE_ORG, DEST_ORG, KEY_VAULT_NAME, REPO_MAP
# 2. Dry run first
DRY_RUN=true ./migrate_secrets.sh
# 3. Review the CSV report, then run for real
./migrate_secrets.sh
```

```powershell
# PowerShell
.\migrate_secrets.ps1 -DryRun   # preview
.\migrate_secrets.ps1            # real run
```

- **No deletions** — never removes anything from source or destination
- **Placeholder guard** — fails immediately if config values are still set to defaults
- **Idempotent** — safe to re-run; skips up-to-date items
- **Key Vault integration** — secret values resolved automatically; falls back to flagging if not found
- **Fail-safe** — per-item errors use `continue`, not `exit`; the full run always completes
- **Verify after write** — environment variables are re-read after setting to confirm
- **GitHub Enterprise Server support** — set `GH_API_HOST` / `$GhApiHost` to your GHES URL

---

## Summary

### Files

| File | Purpose |
|---|---|
| `migrate_secrets.sh` | Migration script — Linux / macOS (bash) |
| `migrate_secrets.ps1` | Migration script — Windows (PowerShell) |
| `README_migrate_secrets.md` | This documentation |

### What the scripts do

- Migrate org-level, repo-level, and environment secrets and variables between two GitHub organisations
- Read secret values directly from Azure Key Vault — no manual export needed
- Idempotent — skip anything where the destination is newer; never delete anything
- Run all pre-flight checks before touching anything — abort immediately on any failure
- Produce a timestamped CSV audit report and log file on every run

### Quick start

```bash
# 1. Edit the CONFIG block — set SOURCE_ORG, DEST_ORG, KEY_VAULT_NAME, REPO_MAP
# 2. Dry run first
DRY_RUN=true ./migrate_secrets.sh
# 3. Review the CSV report, then run for real
./migrate_secrets.sh
```

```powershell
# PowerShell
.\migrate_secrets.ps1 -DryRun   # preview
.\migrate_secrets.ps1            # real run
```
