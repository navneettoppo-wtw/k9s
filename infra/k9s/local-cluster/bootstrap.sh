#!/usr/bin/env bash
# infra/k9s/local-cluster/bootstrap.sh
# Starts the local k3s cluster, extracts kubeconfig, merges into ~/.kube/config
# Usage:
#   Start:    bash bootstrap.sh
#   Teardown: bash bootstrap.sh --down

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT_NAME="local"
KUBECONFIG_OUT="${SCRIPT_DIR}/kubeconfig/kubeconfig.yaml"
KUBE_DIR="${HOME}/.kube"
MERGED_CONFIG="${KUBE_DIR}/config"

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
die()     { echo "[ERROR] $*" >&2; exit 1; }

require() { command -v "$1" &>/dev/null || die "$1 is required but not found in \$PATH."; }

# ── Teardown ──────────────────────────────────────────────────────────────────
teardown() {
  info "Stopping local k3s cluster..."
  docker compose -f "${SCRIPT_DIR}/docker-compose.yml" down -v
  # Remove context from kubeconfig
  if kubectl config get-contexts "${CONTEXT_NAME}" &>/dev/null; then
    kubectl config delete-context "${CONTEXT_NAME}" && success "Removed context '${CONTEXT_NAME}' from kubeconfig."
  fi
  success "Teardown complete."
  exit 0
}

[[ "${1:-}" == "--down" ]] && teardown

# ── Prerequisites ─────────────────────────────────────────────────────────────
require docker
require kubectl

# ── Start cluster ─────────────────────────────────────────────────────────────
info "Starting local k3s cluster..."
mkdir -p "${SCRIPT_DIR}/kubeconfig"
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d

# ── Wait for kubeconfig to be written ────────────────────────────────────────
info "Waiting for k3s to write kubeconfig..."
for i in $(seq 1 30); do
  [[ -f "${KUBECONFIG_OUT}" ]] && break
  sleep 2
  echo -n "."
done
echo ""
[[ -f "${KUBECONFIG_OUT}" ]] || die "Kubeconfig not generated after 60s. Check: docker logs k3s-local"

# ── Patch server address to localhost ────────────────────────────────────────
# k3s writes 127.0.0.1 but the TLS SAN is set, so this is safe
sed -i.bak 's|https://127.0.0.1:6443|https://127.0.0.1:6443|g' "${KUBECONFIG_OUT}"

# ── Rename context to 'local' ─────────────────────────────────────────────────
KUBECONFIG="${KUBECONFIG_OUT}" kubectl config rename-context default "${CONTEXT_NAME}" 2>/dev/null || true

# ── Merge into ~/.kube/config ─────────────────────────────────────────────────
mkdir -p "${KUBE_DIR}"

if [[ -f "${MERGED_CONFIG}" ]]; then
  info "Merging into existing ${MERGED_CONFIG}..."
  KUBECONFIG="${MERGED_CONFIG}:${KUBECONFIG_OUT}" \
    kubectl config view --flatten > "${MERGED_CONFIG}.tmp"
  mv "${MERGED_CONFIG}.tmp" "${MERGED_CONFIG}"
else
  cp "${KUBECONFIG_OUT}" "${MERGED_CONFIG}"
fi

chmod 600 "${MERGED_CONFIG}"
success "Kubeconfig merged. Context '${CONTEXT_NAME}' available."

# ── Set local as current context ──────────────────────────────────────────────
kubectl config use-context "${CONTEXT_NAME}"
success "Current context set to '${CONTEXT_NAME}'."

# ── Wait for node ready ───────────────────────────────────────────────────────
info "Waiting for node to be Ready..."
kubectl wait --for=condition=Ready node/local-node --timeout=90s
success "Local k3s cluster is ready. Run: k9s"
