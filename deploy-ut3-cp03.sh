#!/usr/bin/env bash
# =============================================================
# Trane UT3 — CP-03 deploy  (IN SPEC, 2026-07-06 rewrite)
#
# CP-03 is a VIRGIN box. It joins the EXISTING trane-ut3 cluster
# seeded by CP-02 as an HA control-plane member. Two things only:
#
#   1. EmbernetEndpoint-Linux  (native mesh, embernet0 in 100.64.1.0/24)
#   2. K3s server  — HA control-plane member joined to CP-02
#      (--server https://100.64.1.3:6443, NOT --cluster-init)
#
# CP-02 (100.64.1.3, node trane-ut3-cp-02) is the live seed and is
# LEFT UNTOUCHED. (The old CP-03 script pinned NODE_IP=100.64.1.3 —
# a collision with CP-02 — and seeded off CP-01; both are gone. The
# mesh IP now comes from enrollment.)
#
#   sudo bash trane/deploy-ut3-cp03.sh
#
# Prereq — shared cluster join token from CP-02:
#   sudo mkdir -p /etc/embernet
#   sudo scp user@100.64.1.3:/etc/embernet/k3s-token /etc/embernet/k3s-token
#   sudo chmod 600 /etc/embernet/k3s-token
# =============================================================

set -euo pipefail

# ---------------- CONFIGURATION ----------------
NODE_NAME_LOWER="trane-ut3-cp-03"
NODE_ROLE="control-plane"

TENANT="tranetech-ut3"
SEED_URL="https://100.64.1.3:6443"
SEED_IP="100.64.1.3"
TRANE_SUBNET_PREFIX="100.64.1."

EMBERNET_IMAGE="ghcr.io/embernet-ai/embernetlite:0.0.47"
K3S_VERSION="v1.34.5+k3s1"
K3S_INSTALL_NAME="embernet-server"
K3S_TOKEN_FILE="/etc/embernet/k3s-token"

NODE_IP="${NODE_IP:-}"   # auto-detected from embernet0 after enrollment

# ---------------- HELPERS ----------------
log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
fail() { printf '\n[x] %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || fail "Run as root: sudo bash trane/deploy-ut3-cp03.sh"
# Ensure prerequisites. A virgin box may lack podman; it's in Ubuntu's
# official repos (apt-get install podman) — https://podman.io/docs/installation
ensure_prereqs() {
  local missing=()
  command -v podman >/dev/null || missing+=(podman)
  command -v curl   >/dev/null || missing+=(curl)
  (( ${#missing[@]} == 0 )) && return 0
  command -v apt-get >/dev/null || fail "Missing: ${missing[*]} and apt-get not found — install them manually."
  log "Installing missing prerequisites: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "${missing[@]}"
  command -v podman >/dev/null || fail "podman still missing after apt install."
  command -v curl   >/dev/null || fail "curl still missing after apt install."
}
ensure_prereqs

# Virgin-box guard — refuse to clobber an existing k3s silently.
if [[ -x /usr/local/bin/k3s ]]; then
  fail "K3s already present on this box. CP-03 is meant to be virgin.
      If this is a re-run, uninstall first:  /usr/local/bin/k3s-embernet-server-uninstall.sh"
fi

# =============================================================
# [1/4] EmbernetEndpoint-Linux  (Quadlet container, 0.0.47)
# =============================================================
install_endpoint() {
  log "[1/4] Installing EmbernetEndpoint-Linux (${EMBERNET_IMAGE})..."
  mkdir -p /etc/embernet /var/lib/embernet /var/log/embernet /run/embernet
  chown 987:987 /var/lib/embernet /var/log/embernet /run/embernet
  # Pull the public image and run it detached with restart=always. Plain
  # `podman run` (NOT a Quadlet .container) so it works on ANY podman
  # version — Quadlet's systemd generator needs podman 4.4+ and silently
  # emits no embernet.service on older builds.
  podman pull "${EMBERNET_IMAGE}"
  podman rm -f embernet 2>/dev/null || true
  podman run -d --name embernet \
    --restart=always \
    --network host \
    --cap-add CAP_NET_ADMIN --cap-add CAP_NET_RAW \
    --device /dev/net/tun \
    -e EMBERNET_TENANT_HINT="${TENANT}" \
    -e EMBERNET_SAFETY_WATCHDOG_DISABLED=1 \
    -e HOME=/var/lib/embernet \
    -v /etc/embernet:/etc/embernet \
    -v /etc/os-release:/etc/os-release:ro \
    -v /var/lib/embernet:/var/lib/embernet \
    -v /var/log/embernet:/var/log/embernet \
    -v /run/embernet:/run/embernet \
    "${EMBERNET_IMAGE}"

  # Replay restart=always containers across reboot.
  systemctl enable podman-restart.service 2>/dev/null || true
  log "[1/4] Endpoint container 'embernet' running."
}

# =============================================================
# [2/4] Enrollment gate
# =============================================================
wait_for_enrollment() {
  log "[2/4] Waiting for EmbernetEndpoint enrollment (embernet0 -> ${TRANE_SUBNET_PREFIX}x)..."
  cat <<EOF

  The endpoint daemon auto-issues an Azure AD device code on first start
  (tenant = ${TENANT}). Watch for it in the container log:

      sudo podman logs -f embernet

  Take the value from the "user_code" line, open https://microsoft.com/devicelogin
  in a browser, and enter it. Do NOT run a separate 'embernetlite enroll' —
  the daemon already runs the wizard. This script continues automatically
  once embernet0 comes up inside ${TRANE_SUBNET_PREFIX}0/24.

EOF
  local waited=0 max=1800 ip=""
  while (( waited < max )); do
    ip="$(ip -4 -o addr show embernet0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep "^${TRANE_SUBNET_PREFIX}" || true)"
    [[ -n "$ip" ]] && break
    sleep 5; waited=$((waited+5))
  done
  [[ -n "$ip" ]] || fail "embernet0 never obtained a ${TRANE_SUBNET_PREFIX}x address. Re-run after enrolling."

  if [[ -n "$NODE_IP" && "$NODE_IP" != "$ip" ]]; then
    warn "NODE_IP override (${NODE_IP}) differs from enrolled embernet0 IP (${ip}); using the override."
  else
    NODE_IP="$ip"
  fi
  [[ "$NODE_IP" == "$SEED_IP" ]] && fail "Enrolled IP ${NODE_IP} collides with the CP-02 seed. Re-enroll for a distinct address."
  log "[2/4] Endpoint enrolled — CP-03 mesh IP: ${NODE_IP}"

  log "Checking reachability to the CP-02 apiserver (${SEED_IP}:6443)..."
  (echo >"/dev/tcp/${SEED_IP}/6443") 2>/dev/null \
    && log "CP-02 apiserver reachable over the mesh." \
    || warn "Cannot reach ${SEED_IP}:6443 yet — the join will retry, but verify the mesh if it hangs."
}

# =============================================================
# [3/4] K3s server — join CP-02 as an HA control-plane member
# =============================================================
install_k3s_server() {
  log "[3/4] Installing K3s server (HA join to CP-02)..."
  [[ -s "$K3S_TOKEN_FILE" ]] || fail "Missing cluster join token at ${K3S_TOKEN_FILE}.
      Fetch it from CP-02:
        sudo scp user@${SEED_IP}:/etc/embernet/k3s-token ${K3S_TOKEN_FILE}
        sudo chmod 600 ${K3S_TOKEN_FILE}"
  local token; token="$(tr -d '[:space:]' < "$K3S_TOKEN_FILE")"

  mkdir -p /etc/rancher/k3s
  printf 'disable-network-policy: true\n' > /etc/rancher/k3s/config.yaml

  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_NAME="${K3S_INSTALL_NAME}" \
    K3S_TOKEN="${token}" \
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

  log "[3/4] K3s server installed (unit: k3s-${K3S_INSTALL_NAME}.service)."
}

# =============================================================
# [4/4] Verify
# =============================================================
verify() {
  log "[4/4] Waiting for ${NODE_NAME_LOWER} to register Ready (max 180s)..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  local waited=0
  while (( waited < 180 )); do
    if /usr/local/bin/k3s kubectl get node "${NODE_NAME_LOWER}" 2>/dev/null | grep -q ' Ready'; then
      log "[4/4] ${NODE_NAME_LOWER} is Ready and joined to the trane-ut3 cluster."
      /usr/local/bin/k3s kubectl get nodes -o wide 2>/dev/null | grep -E "NAME|trane-ut3" || true
      return 0
    fi
    sleep 5; waited=$((waited+5))
  done
  warn "${NODE_NAME_LOWER} not Ready yet. Inspect: journalctl -xeu k3s-${K3S_INSTALL_NAME} --no-pager -n 60"
}

# ---------------- MAIN ----------------
log "=== Trane UT3 CP-03 — join CP-02 control plane (${NODE_NAME_LOWER}) ==="
install_endpoint
wait_for_enrollment
install_k3s_server
verify
log "=== CP-03 done. ==="
