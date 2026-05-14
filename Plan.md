# K9s Standardisation Plan

## Objective

K9s is already in use across the team for Kubernetes cluster management via CLI. However, the current setup is manual and inconsistent between users, creating friction during onboarding and day-to-day operations.

This plan covers:

- Standardising K9s configuration across all team members
- Providing a shared initialisation script to connect to the Kubernetes environment
- Optionally supporting a Docker-based / k3s local cluster for consistent local development

---

## Current State

| Area | Problem |
|---|---|
| K9s version | Each member installs independently — versions vary |
| Kubeconfig location | No agreed path or naming convention |
| K9s config (`config.yaml`) | No shared defaults — views, aliases, hotkeys differ |
| Cluster context names | Named inconsistently across machines |
| Local dev clusters | Some use k3s, some use kind, some have none |
| Onboarding | No documented setup steps; relies on tribal knowledge |

---

## Goals

1. **Consistent K9s version** pinned and distributed via a setup script or package manager
2. **Shared base config** (`~/.config/k9s/config.yaml`) committed to the repo and symlinked on setup
3. **Standard kubeconfig location** and context naming convention
4. **Init script** that handles installation, config setup, and cluster connection in one step
5. **Optional local cluster** using k3s (via Docker) for members who need to develop or test locally without access to a remote cluster

---

## Proposed Directory Structure (in repo)

```
infra/k9s/
├── README.md               # Setup instructions
├── setup.sh                # Init script (install + configure + connect)
├── config/
│   ├── config.yaml         # Shared K9s base config
│   ├── aliases.yaml        # Shared command aliases
│   └── hotkeys.yaml        # Shared hotkey bindings
└── local-cluster/
    ├── docker-compose.yml  # k3s cluster via Docker (optional)
    └── bootstrap.sh        # Script to start local cluster + load kubeconfig
```

---

## Task Breakdown

### Phase 1 — Shared K9s Configuration

**Tasks:**

- [ ] Agree on a K9s version to pin (e.g. `v0.32.x`) — document in `README.md`
- [ ] Create `infra/k9s/config/config.yaml` with agreed defaults:
  - Default namespace view
  - Log tail line count
  - Refresh rate
  - UI skin / colour theme
- [ ] Create `infra/k9s/config/aliases.yaml` for common resource shortcuts
- [ ] Create `infra/k9s/config/hotkeys.yaml` for team-agreed bindings
- [ ] Document the target config location: `~/.config/k9s/` (Linux/macOS)

**Owner:** Platform / DevOps  
**Effort:** Small (1–2 days)

---

### Phase 2 — Init Script (`setup.sh`)

The script should be idempotent — safe to re-run at any time.

**Script responsibilities:**

1. Detect OS (macOS / Linux)
2. Check if K9s is installed; if not, install the pinned version
3. Symlink (or copy) shared config files from the repo into `~/.config/k9s/`
4. Verify `kubectl` is present and in `$PATH`
5. Check for a valid kubeconfig at `~/.kube/config` and print context list
6. Optionally prompt the user to select or set a default context
7. Print a success summary with current context

**Tasks:**

- [ ] Write `infra/k9s/setup.sh`
- [ ] Handle macOS (`brew install derailed/k9s/k9s`) and Linux (binary download from GitHub releases)
- [ ] Add config symlinking with backup of any pre-existing user config
- [ ] Add `kubectl config get-contexts` output so the user can confirm their context
- [ ] Test on macOS and Ubuntu
- [ ] Document usage in `README.md`

**Owner:** Platform / DevOps  
**Effort:** Medium (2–3 days)

---

### Phase 3 — Kubeconfig & Context Naming Convention

**Tasks:**

- [ ] Define the standard kubeconfig file path: `~/.kube/config`
- [ ] Agree on context naming convention, e.g.:
  - `<env>-<cluster-name>` → `prod-eu-west-1`, `staging-us-east-1`, `local`
- [ ] Document how to add a new cluster context (link to cloud provider CLI steps)
- [ ] Update `setup.sh` to validate context names against the convention and warn if non-standard names are detected

**Owner:** Platform / DevOps + team leads  
**Effort:** Small (1 day)

---

### Phase 4 — Optional Local Cluster (k3s via Docker)

For members who need a local cluster without access to remote environments.

**Tasks:**

- [ ] Create `infra/k9s/local-cluster/docker-compose.yml` running k3s in Docker
- [ ] Write `infra/k9s/local-cluster/bootstrap.sh` that:
  1. Starts the k3s container
  2. Extracts the generated kubeconfig
  3. Merges it into `~/.kube/config` under context name `local`
  4. Sets `local` as the current context
- [ ] Document prerequisites: Docker Desktop or Docker Engine installed
- [ ] Add teardown instructions (stop cluster, remove context)

**Owner:** Platform / DevOps  
**Effort:** Medium (2–3 days)

---

### Phase 5 — Documentation & Onboarding

**Tasks:**

- [ ] Write `infra/k9s/README.md` covering:
  - Prerequisites (kubectl, Docker, cloud CLI)
  - How to run `setup.sh`
  - How to use the local cluster (optional)
  - Context switching in K9s (`:ctx` command)
  - Where to find logs, port-forward, shell into pods
  - Link to K9s official docs and keyboard shortcuts reference
- [ ] Add K9s setup step to team onboarding checklist
- [ ] Record a short walkthrough (optional but recommended for async teams)

**Owner:** Platform / DevOps + whoever owns onboarding docs  
**Effort:** Small (1 day)

---

## Timeline

| Phase | Description | Effort | Target |
|---|---|---|---|
| 1 | Shared K9s config | 1–2 days | Week 1 |
| 2 | Init script | 2–3 days | Week 1–2 |
| 3 | Kubeconfig conventions | 1 day | Week 2 |
| 4 | Local k3s cluster (optional) | 2–3 days | Week 2–3 |
| 5 | Docs & onboarding | 1 day | Week 3 |

Total estimated effort: **~7–10 days** (can be parallelised across two engineers)

---

## Decisions Needed

1. **K9s version to pin** — latest stable or a specific tag?
2. **Config delivery method** — symlink from repo (preferred) or copy on setup?
3. **Local cluster tool** — k3s (via Docker) confirmed, or prefer `kind`?
4. **Kubeconfig merging** — single `~/.kube/config` file, or `KUBECONFIG` env var pointing to multiple files?
5. **Script distribution** — run directly from repo clone, or publish a one-liner (`curl | bash`)?

---

## Success Criteria

- Any new team member can go from zero to a working K9s session against the correct cluster by running a single script
- All team members are on the same K9s version and share the same base config
- Context names are consistent and documented
- Local cluster option works on macOS and Linux with Docker installed
 