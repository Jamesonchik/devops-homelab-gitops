#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config (override via env)
# =========================
REGISTRY="${REGISTRY:-192.168.126.130:5000}"  # host:port of your local registry
TEST_IMAGE="${TEST_IMAGE:-registry.k8s.io/ingress-nginx/controller:v1.12.0}"
CONTAINERD_CFG="${CONTAINERD_CFG:-/etc/containerd/config.toml}"

# ==========
# Helpers
# ==========
log() { echo -e "\033[1;32m[apply]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*" >&2; }
die() { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root (sudo). Example: sudo REGISTRY=${REGISTRY} $0"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

check_registry_reachable() {
  # Bypass proxies explicitly (important if you have VPN proxy env vars)
  log "Checking registry reachability: http://${REGISTRY}/v2/ (no proxy)"
  if ! curl --noproxy '*' -m 3 -fsS "http://${REGISTRY}/v2/" >/dev/null; then
    die "Registry is not reachable: http://${REGISTRY}/v2/ . Check network/firewall/registry container."
  fi
}

ensure_containerd_config() {
  if [[ ! -f "${CONTAINERD_CFG}" ]]; then
    log "containerd config not found (${CONTAINERD_CFG}), generating default config"
    mkdir -p "$(dirname "${CONTAINERD_CFG}")"
    containerd config default > "${CONTAINERD_CFG}"
  fi
}

backup_config() {
  local ts
  ts="$(date +%s)"
  cp -a "${CONTAINERD_CFG}" "${CONTAINERD_CFG}.bak.${ts}"
  log "Backup created: ${CONTAINERD_CFG}.bak.${ts}"
}

toml_validate_or_regen() {
  # Validate TOML using Python's tomllib (Python 3.11+ on Ubuntu 24.04 has it)
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 - <<'PY' "${CONTAINERD_CFG}" >/dev/null 2>&1
import sys
try:
    import tomllib
except Exception:
    sys.exit(0)  # can't validate; skip
p=sys.argv[1]
with open(p,'rb') as f:
    tomllib.load(f)
PY
    then
      warn "TOML validation failed: ${CONTAINERD_CFG}. Regenerating from containerd default (keeps only our changes)."
      mv "${CONTAINERD_CFG}" "${CONTAINERD_CFG}.bad.$(date +%s)"
      containerd config default > "${CONTAINERD_CFG}"
    fi
  fi
}

remove_existing_mirror_blocks() {
  # Remove any existing mirror blocks for registry.k8s.io to avoid "duplicated tables"
  # Handles multiple occurrences.
  local tmp
  tmp="$(mktemp)"
  awk '
    BEGIN { skip=0 }
    /^\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\.mirrors\."registry\.k8s\.io"\]$/ { skip=1; next }
    skip==1 && /^\[/ { skip=0 }
    skip==0 { print }
  ' "${CONTAINERD_CFG}" > "${tmp}"
  mv "${tmp}" "${CONTAINERD_CFG}"
}

ensure_mirror_block() {
  log "Ensuring mirror for registry.k8s.io -> http://${REGISTRY}"
  cat >> "${CONTAINERD_CFG}" <<EOF

[plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]
  endpoint = ["http://${REGISTRY}"]
EOF
}

ensure_crictl_config() {
  log "Ensuring /etc/crictl.yaml (remove warnings, pin endpoint to containerd)"
  cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 30
debug: false
EOF
}

restart_containerd() {
  log "Restarting containerd"
  systemctl restart containerd
  systemctl is-active --quiet containerd || (journalctl -u containerd -b --no-pager -n 120 && die "containerd is not active")
  log "containerd is active"
}

test_pull() {
  log "Testing pull via mirror: ${TEST_IMAGE}"
  # Give it some time but not infinite
  if ! timeout 180 crictl pull "${TEST_IMAGE}"; then
    warn "Test pull failed. Showing recent containerd logs:"
    journalctl -u containerd --since "5 min ago" --no-pager | tail -n 200 || true
    die "crictl pull failed for ${TEST_IMAGE}"
  fi
  log "OK: ${TEST_IMAGE} pulled successfully"
}

# ==========
# Main
# ==========
main() {
  require_root
  need_cmd curl
  need_cmd containerd
  need_cmd systemctl
  need_cmd crictl
  need_cmd awk
  need_cmd timeout

  check_registry_reachable
  ensure_containerd_config
  backup_config
  toml_validate_or_regen

  # Idempotent patching
  remove_existing_mirror_blocks
  ensure_mirror_block

  ensure_crictl_config
  restart_containerd
  test_pull

  log "Done. registry.k8s.io is mirrored to http://${REGISTRY}"
}

main "$@"
