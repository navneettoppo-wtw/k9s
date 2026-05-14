#!/usr/bin/env bash
# infra/k9s/setup.sh
# Idempotent K9s setup script — macOS and Linux
# Usage: bash infra/k9s/setup.sh

set -euo pipefail

K9S_VERSION="v0.32.7"
K9S_CONFIG_DIR="${HOME}/.config/k9s"
REPO_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/config" && pwd)"
BACKUP_SUFFIX=".bak.$(date +%Y%m%d%H%M%S)"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
die()     { echo "[ERROR] $*" >&2; exit 1; }

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      die "Unsupported OS: $(uname -s)" ;;
  esac
}

# ── Step 1: Install K9s ───────────────────────────────────────────────────────
install_k9s() {
  local os; os=$(detect_os)

  if command -v k9s &>/dev/null; then
    local installed; installed=$(k9s version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ "${installed}" == "${K9S_VERSION}" ]]; then
      success "K9s ${K9S_VERSION} already installed."
      return
    fi
    warn "K9s ${installed} found — expected ${K9S_VERSION}. Reinstalling..."
  fi

  info "Installing K9s ${K9S_VERSION} on ${os}..."

  if [[ "${os}" == "macos" ]]; then
    if ! command -v brew &>/dev/null; then
      die "Homebrew not found. Install it from https://brew.sh then re-run this script."
    fi
    brew install derailed/k9s/k9s 2>/dev/null || brew upgrade derailed/k9s/k9s
  else
    # Linux — download binary from GitHub releases
    local arch; arch=$(uname -m)
    case "${arch}" in
      x86_64)  arch="amd64" ;;
      aarch64) arch="arm64" ;;
      *)        die "Unsupported architecture: ${arch}" ;;
    esac

    local url="https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${arch}.tar.gz"
    local tmp; tmp=$(mktemp -d)
    trap 'rm -rf "${tmp}"' EXIT

    info "Downloading ${url}..."
    curl -fsSL "${url}" -o "${tmp}/k9s.tar.gz"
    tar -xzf "${tmp}/k9s.tar.gz" -C "${tmp}"
    sudo install -m 0755 "${tmp}/k9s" /usr/local/bin/k9s
  fi

  success "K9s $(k9s version --short 2>/dev/null | head -1) installed."
}

# ── Step 2: Symlink config files ──────────────────────────────────────────────
setup_config() {
  mkdir -p "${K9S_CONFIG_DIR}"

  for file in config.yaml aliases.yaml hotkeys.yaml; do
    local src="${REPO_CONFIG_DIR}/${file}"
    local dst="${K9S_CONFIG_DIR}/${file}"

    [[ -f "${src}" ]] || die "Source config not found: ${src}"

    # Backup existing non-symlink file
    if [[ -f "${dst}" && ! -L "${dst}" ]]; then
      warn "Backing up existing ${dst} → ${dst}${BACKUP_SUFFIX}"
      mv "${dst}" "${dst}${BACKUP_SUFFIX}"
    fi

    # Remove stale symlink pointing elsewhere
    if [[ -L "${dst}" && "$(readlink "${dst}")" != "${src}" ]]; then
      rm "${dst}"
    fi

    if [[ ! -L "${dst}" ]]; then
      ln -s "${src}" "${dst}"
      success "Symlinked ${file} → ${dst}"
    else
      success "${file} symlink already in place."
    fi
  done
}

# ── Step 3: Verify kubectl ────────────────────────────────────────────────────
check_kubectl() {
  if ! command -v kubectl &>/dev/null; then
    warn "kubectl not found in \$PATH. Install it: https://kubernetes.io/docs/tasks/tools/"
    return
  fi
  success "kubectl $(kubectl version --client --short 2>/dev/null | head -1) found."
}

# ── Step 4: Check kubeconfig & contexts ──────────────────────────────────────
check_kubeconfig() {
  local kubeconfig="${KUBECONFIG:-${HOME}/.kube/config}"

  if [[ ! -f "${kubeconfig}" ]]; then
    warn "No kubeconfig found at ${kubeconfig}. Add a cluster context before running K9s."
    return
  fi

  success "Kubeconfig found: ${kubeconfig}"
  echo ""
  echo "Available contexts:"
  kubectl config get-contexts 2>/dev/null || warn "Could not list contexts."

  echo ""
  local current; current=$(kubectl config current-context 2>/dev/null || echo "none")
  info "Current context: ${current}"

  # Warn on non-standard context names (expected: <env>-<cluster>)
  while IFS= read -r ctx; do
    if ! echo "${ctx}" | grep -qE '^(prod|staging|dev|local)(-[a-z0-9-]+)?$'; then
      warn "Non-standard context name detected: '${ctx}' (expected: <env>-<cluster>, e.g. prod-eu-west-1)"
    fi
  done < <(kubectl config get-contexts -o name 2>/dev/null || true)
}

# ── Step 5: Optional context selection ───────────────────────────────────────
select_context() {
  if ! command -v kubectl &>/dev/null; then return; fi

  echo ""
  read -rp "Set a default context? Enter context name (or press Enter to skip): " chosen
  if [[ -n "${chosen}" ]]; then
    kubectl config use-context "${chosen}" && success "Default context set to: ${chosen}"
  else
    info "Skipped context selection."
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo "================================================"
  echo "  K9s Team Setup — ${K9S_VERSION}"
  echo "================================================"
  echo ""

  install_k9s
  setup_config
  check_kubectl
  check_kubeconfig
  select_context

  echo ""
  echo "================================================"
  success "Setup complete. Run: k9s"
  echo "================================================"
}

main "$@"
