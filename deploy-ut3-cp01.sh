#!/usr/bin/env bash
# =============================================================
# Trane UT3 — CP-01 : EmbernetEndpoint (as Trane-UT3-CP-01) + K3s
#
# Does the two things, in order:
#   1. EmbernetEndpoint-Linux  — endpoint container + enroll AS
#      "Trane-UT3-CP-01" (NOT the hostname), giving embernet0 a
#      100.64.1.x address in the Trane mesh.
#   2. K3s server — JOIN the existing Trane cluster seeded by CP-02
#      (node trane-ut3-cp-02 = the trane-ut3 cluster in Rancher),
#      via --server https://100.64.1.3:6443. NOT a fresh cluster.
#
# Prereq — CP-02's shared cluster token on this box:
#   sudo scp user@100.64.1.3:/etc/embernet/k3s-token /etc/embernet/k3s-token
#   sudo chmod 600 /etc/embernet/k3s-token
#
#   sudo bash deploy-ut3-cp01.sh
# =============================================================
set -euo pipefail

NODE_NAME_LOWER="trane-ut3-cp-01"     # k3s node name
DEVICE_NAME="Trane-UT3-CP-01"         # endpoint identity (dashboard/Flux/mesh)
NODE_ROLE="control-plane"
TENANT="tranetech-ut3"
SEED_URL="https://100.64.1.3:6443"
SEED_IP="100.64.1.3"
TRANE_SUBNET_PREFIX="100.64.1."
EMBERNET_IMAGE="ghcr.io/embernet-ai/embernetlite:0.0.47"
K3S_VERSION="v1.34.5+k3s1"
K3S_INSTALL_NAME="embernet-server"
K3S_TOKEN_FILE="/etc/embernet/k3s-token"

log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
fail() { printf '\n[x] %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || fail "Run as root: sudo bash deploy-ut3-cp01.sh"

ensure_prereqs() {
  local missing=()
  command -v podman >/dev/null || missing+=(podman)
  command -v curl   >/dev/null || missing+=(curl)
  (( ${#missing[@]} == 0 )) && return 0
  command -v apt-get >/dev/null || fail "Missing: ${missing[*]} and apt-get not found."
  log "Installing prerequisites: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y; apt-get install -y "${missing[@]}"
}
ensure_prereqs

# --- [1/4] EmbernetEndpoint container ---------------------------------------
install_endpoint() {
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx embernet; then
    log "[1/4] Endpoint container already running."
    return 0
  fi
  log "[1/4] Installing EmbernetEndpoint-Linux (${EMBERNET_IMAGE})..."
  mkdir -p /etc/embernet /var/lib/embernet /var/log/embernet /run/embernet
  chown 987:987 /var/lib/embernet /var/log/embernet /run/embernet
  podman pull "${EMBERNET_IMAGE}"
  podman rm -f embernet 2>/dev/null || true
  podman run -d --name embernet --restart=always --network host \
    --cap-add CAP_NET_ADMIN --cap-add CAP_NET_RAW --device /dev/net/tun \
    -e EMBERNET_TENANT_HINT="${TENANT}" -e EMBERNET_SAFETY_WATCHDOG_DISABLED=1 -e HOME=/var/lib/embernet \
    -v /etc/embernet:/etc/embernet -v /etc/os-release:/etc/os-release:ro \
    -v /var/lib/embernet:/var/lib/embernet -v /var/log/embernet:/var/log/embernet -v /run/embernet:/run/embernet \
    "${EMBERNET_IMAGE}"
  systemctl enable podman-restart.service 2>/dev/null || true
}

# --- [2/4] Enroll AS Trane-UT3-CP-01 ----------------------------------------
enroll_endpoint() {
  local current; current="$(cat /var/lib/embernet/device.name 2>/dev/null || true)"
  if [[ "$current" == "$DEVICE_NAME" ]] && ip -4 -o addr show embernet0 2>/dev/null | grep -q "${TRANE_SUBNET_PREFIX}"; then
    log "[2/4] Already enrolled as ${DEVICE_NAME} (embernet0 up) — skipping."
    return 0
  fi
  echo
  log "[2/4] Enrolling endpoint as ${DEVICE_NAME}. A device code prints below —"
  log "open https://microsoft.com/devicelogin in a browser and enter it:"
  echo
  podman exec -it embernet embernetlite enroll --device-name "${DEVICE_NAME}" \
    || warn "enroll exited non-zero; re-run if needed: sudo podman exec -it embernet embernetlite enroll --device-name ${DEVICE_NAME}"
  echo
  # The running daemon does not hot-reload a re-enrollment; restart so it
  # applies the new WireGuard config and brings embernet0 up on the new IP.
  log "Restarting endpoint so the daemon applies the enrollment..."
  podman restart embernet >/dev/null 2>&1 || true
  log "Waiting for embernet0 to obtain a ${TRANE_SUBNET_PREFIX}x address..."
  local w=0
  while (( w < 300 )); do
    ip -4 -o addr show embernet0 2>/dev/null | grep -q "${TRANE_SUBNET_PREFIX}" && break
    sleep 5; w=$((w+5))
  done
}

# --- [3/4] K3s server — JOIN CP-02's Trane cluster --------------------------
install_k3s() {
  NODE_IP="$(ip -4 -o addr show embernet0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep "^${TRANE_SUBNET_PREFIX}" | head -1 || true)"
  [[ -n "$NODE_IP" ]] || fail "embernet0 has no ${TRANE_SUBNET_PREFIX}x address — enrollment incomplete."
  [[ "$NODE_IP" != "$SEED_IP" ]] || fail "This box's embernet0 (${NODE_IP}) is CP-02's seed IP — wrong box."
  log "[3/4] CP-01 mesh IP: ${NODE_IP}"

  (echo >"/dev/tcp/${SEED_IP}/6443") 2>/dev/null \
    && log "CP-02 apiserver ${SEED_IP}:6443 reachable." \
    || warn "Cannot reach ${SEED_IP}:6443 yet — join will retry."

  # CP-02 shared cluster token, baked in for the ephemeral demo cluster.
  # Override with K3S_TOKEN env or a /etc/embernet/k3s-token file if it rotates.
  local token="${K3S_TOKEN:-72d6bbbe257a0ac028cde59d4c1ab413cb5694f3cec2a37b411efcdd936172a3}"
  [[ -s "$K3S_TOKEN_FILE" ]] && token="$(tr -d '[:space:]' < "$K3S_TOKEN_FILE")"

  if [[ -x /usr/local/bin/k3s ]] && systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}" 2>/dev/null; then
    log "k3s-${K3S_INSTALL_NAME} already active — nothing to install."
    return 0
  fi
  mkdir -p /etc/rancher/k3s
  printf 'disable-network-policy: true\n' > /etc/rancher/k3s/config.yaml
  log "Installing k3s server, JOINING the Trane cluster at ${SEED_URL}..."
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" INSTALL_K3S_NAME="${K3S_INSTALL_NAME}" K3S_TOKEN="${token}" \
    sh -s - server \
      --server "${SEED_URL}" \
      --node-name="${NODE_NAME_LOWER}" \
      --node-ip="${NODE_IP}" \
      --flannel-iface=embernet0 \
      --tls-san="${NODE_IP}" \
      --disable=traefik \
      --node-label="embernet.ai/tenant=${TENANT}" \
      --node-label="embernet.ai/site=ut3" \
      --node-label="embernet.ai/role=${NODE_ROLE}" \
      --node-label="embernet.ai/node-name=${NODE_NAME_LOWER}"
}

# --- [4/4] Verify -----------------------------------------------------------
verify() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  log "[4/4] Waiting for ${NODE_NAME_LOWER} to register Ready (max 180s)..."
  local w=0
  while (( w < 180 )); do
    if /usr/local/bin/k3s kubectl get node "${NODE_NAME_LOWER}" 2>/dev/null | grep -q ' Ready'; then
      log "[4/4] ${NODE_NAME_LOWER} is Ready — joined the Trane cluster."
      /usr/local/bin/k3s kubectl get nodes -o wide 2>/dev/null | grep -E "NAME|trane-ut3" || true
      return 0
    fi
    sleep 5; w=$((w+5))
  done
  warn "${NODE_NAME_LOWER} not Ready yet. Inspect: journalctl -xeu k3s-${K3S_INSTALL_NAME} --no-pager -n 60"
}

log "=== Trane UT3 CP-01 — endpoint (${DEVICE_NAME}) + join CP-02 cluster ==="
install_endpoint
enroll_endpoint
install_k3s
verify
log "=== CP-01 done. ==="
