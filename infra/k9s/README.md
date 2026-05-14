# K9s Team Setup

K9s is the team's standard CLI for Kubernetes cluster management. This directory contains everything needed to get a consistent, working K9s setup from scratch.

---

## Prerequisites

| Tool | Minimum version | Install |
|---|---|---|
| `kubectl` | v1.28+ | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| `k9s` | v0.32.7 (pinned) | handled by `setup.sh` |
| Docker Desktop / Engine | v24+ | [docs.docker.com](https://docs.docker.com/get-docker/) — only needed for local cluster |
| Cloud CLI | AWS CLI v2 / `az` / `gcloud` | only needed to fetch remote kubeconfigs |

---

## Quick Start

```bash
# 1. Clone the repo (if not already done)
git clone <repo-url> && cd <repo>

# 2. Run the setup script
bash infra/k9s/setup.sh

# 3. Launch K9s
k9s
```

`setup.sh` is idempotent — safe to re-run at any time.

---

## What `setup.sh` Does

1. Detects OS (macOS or Linux)
2. Installs K9s `v0.32.7` if not already present at that version
   - macOS: `brew install derailed/k9s/k9s`
   - Linux: downloads binary from GitHub releases
3. Symlinks shared config files from `infra/k9s/config/` into `~/.config/k9s/`
   - Backs up any pre-existing user config with a timestamp suffix
4. Verifies `kubectl` is in `$PATH`
5. Prints available kubeconfig contexts and warns on non-standard names
6. Optionally prompts you to set a default context

---

## Directory Structure

```
infra/k9s/
├── README.md                   ← you are here
├── setup.sh                    ← one-shot install + configure script
├── config/
│   ├── config.yaml             ← shared K9s base config (refresh rate, log tail, thresholds)
│   ├── aliases.yaml            ← shared resource aliases (e.g. :dp → deployments)
│   └── hotkeys.yaml            ← shared hotkey bindings (Shift-1 → pods, etc.)
└── local-cluster/
    ├── docker-compose.yml      ← k3s single-node cluster in Docker
    └── bootstrap.sh            ← start cluster, merge kubeconfig, set context
```

---

## Kubeconfig & Context Naming Convention

### Standard kubeconfig location

All team members use a single merged kubeconfig file:

```
~/.kube/config
```

Do **not** use `KUBECONFIG` pointing to multiple files unless you have a specific reason — it makes context switching harder to reason about.

### Context naming convention

```
<env>-<cluster-name>
```

| Environment | Example context name |
|---|---|
| Production | `prod-eu-west-1` |
| Staging | `staging-us-east-1` |
| Development | `dev-eu-west-1` |
| Local (k3s) | `local` |

Rules:
- All lowercase, hyphen-separated
- Always prefix with the environment (`prod`, `staging`, `dev`, `local`)
- For cloud clusters, append the region: `prod-eu-west-1`, `staging-ap-southeast-1`
- Never use generic names like `default`, `kubernetes`, or `my-cluster`

`setup.sh` will warn you if any context in your kubeconfig does not match this pattern.

### Adding a new cluster context

**AWS EKS:**
```bash
aws eks update-kubeconfig \
  --region eu-west-1 \
  --name my-cluster \
  --alias prod-eu-west-1
```

**Azure AKS:**
```bash
az aks get-credentials \
  --resource-group my-rg \
  --name my-cluster \
  --context staging-eu-west-1
```

**GKE:**
```bash
gcloud container clusters get-credentials my-cluster \
  --region eu-west1 \
  --project my-project
# Then rename:
kubectl config rename-context gke_my-project_eu-west1_my-cluster prod-eu-west1
```

---

## Local Cluster (Optional)

For members who need a local Kubernetes environment without access to a remote cluster.

### Start

```bash
bash infra/k9s/local-cluster/bootstrap.sh
```

This will:
1. Start a single-node k3s cluster in Docker
2. Extract the generated kubeconfig
3. Merge it into `~/.kube/config` under context name `local`
4. Set `local` as the current context
5. Wait for the node to be Ready

### Teardown

```bash
bash infra/k9s/local-cluster/bootstrap.sh --down
```

Stops the container, removes the Docker volume, and deletes the `local` context from your kubeconfig.

---

## Using K9s

### Launch

```bash
k9s                          # uses current kubectl context
k9s --context prod-eu-west-1 # override context
k9s -n kube-system           # start in a specific namespace
```

### Context switching inside K9s

Press `:` then type `ctx` and hit Enter — or use the hotkey `Shift-9` (configured in `hotkeys.yaml`).

### Useful commands

| Command | What it does |
|---|---|
| `:pods` or `Shift-1` | View all pods |
| `:dp` | View deployments (alias) |
| `:svc` | View services (alias) |
| `:ns` | Switch namespace |
| `:ctx` or `Shift-9` | Switch context |
| `l` on a pod | View logs |
| `s` on a pod | Shell into pod |
| `f` on a pod | Port-forward |
| `d` on any resource | Describe |
| `e` on any resource | Edit YAML |
| `ctrl-d` | Delete resource |
| `?` | Help / all keybindings |

### Logs

- Press `l` on any pod to tail logs
- Press `w` to toggle text wrap
- Press `t` to toggle timestamps
- Full-screen logs: press `f`

### Port-forwarding

1. Navigate to the pod
2. Press `f` — K9s opens a port-forward dialog
3. Enter local port and container port
4. K9s manages the tunnel; press `ctrl-c` to stop

### Shell into a pod

1. Navigate to the pod
2. Press `s` — K9s opens a shell using the first container
3. For a specific container, press `e` first to see container names

---

## Shared Config Reference

### `config.yaml` defaults

| Setting | Value | Notes |
|---|---|---|
| Refresh rate | 2s | How often K9s polls the API |
| Log tail | 200 lines | Increase if debugging |
| CPU warn / critical | 70% / 90% | Highlights in node/pod views |
| Memory warn / critical | 70% / 90% | |
| Shell pod image | `busybox:1.36` | Used for debug shells |

### `aliases.yaml` shortcuts

Type `:dp`, `:svc`, `:sec`, etc. in the K9s command bar. Full list in `config/aliases.yaml`.

### `hotkeys.yaml` bindings

| Key | Action |
|---|---|
| `Shift-1` | Pods |
| `Shift-2` | Deployments |
| `Shift-3` | Services |
| `Shift-4` | ConfigMaps |
| `Shift-5` | Secrets |
| `Shift-6` | Nodes |
| `Shift-7` | Events |
| `Shift-8` | Ingresses |
| `Shift-9` | Context switcher |
| `Shift-0` | Namespaces |

---

## Onboarding Checklist

- [ ] Install prerequisites: `kubectl`, Docker
- [ ] Run `bash infra/k9s/setup.sh`
- [ ] Obtain kubeconfig for your target cluster (ask team lead)
- [ ] Rename context to match convention: `<env>-<cluster-name>`
- [ ] Run `k9s` and verify you can see cluster resources
- [ ] (Optional) Start local cluster: `bash infra/k9s/local-cluster/bootstrap.sh`

---

## References

- [K9s official docs](https://k9scli.io/)
- [K9s keyboard shortcuts](https://k9scli.io/topics/commands/)
- [K9s GitHub releases](https://github.com/derailed/k9s/releases)
- [kubectl cheatsheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/)
