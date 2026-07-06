#!/usr/bin/env bash
# =============================================================
# Trane UT3 — EN-0001 (embernode) deploy  (IN SPEC, 2026-07-06 rewrite)
#
# EN-0001 is a VIRGIN box. It joins the EXISTING trane-ut3 cluster
# seeded by CP-02 as a worker / edge node. Two things only:
#
#   1. EmbernetEndpoint-Linux  (native mesh, embernet0 in 100.64.1.0/24)
#   2. K3s AGENT  — joined to CP-02 (K3S_URL=https://100.64.1.3:6443)
#
# CP-02 (100.64.1.3, node trane-ut3-cp-02) is the live seed and is
# LEFT UNTOUCHED. (The old EN-0001 script joined CP-01 at 100.64.1.1
# and hardcoded a static wg0 — both are gone; the mesh IP now comes
# from enrollment.)
#
#   sudo bash trane/deploy-ut3-en01.sh
#
# Prereq — shared cluster join token from CP-02:
#   sudo mkdir -p /etc/embernet
#   sudo scp user@100.64.1.3:/etc/embernet/k3s-token /etc/embernet/k3s-token
#   sudo chmod 600 /etc/embernet/k3s-token
# =============================================================

set -euo pipefail

# ---------------- CONFIGURATION ----------------
NODE_NAME_LOWER="trane-ut3-en-0001"
NODE_ROLE="edge"

TENANT="tranetech-ut3"
SEED_URL="https://100.64.1.3:6443"           # CP-02 apiserver over the mesh
SEED_IP="100.64.1.3"
TRANE_SUBNET_PREFIX="100.64.1."

EMBERNET_IMAGE="ghcr.io/embernet-ai/embernetlite:0.0.47"
K3S_VERSION="v1.34.5+k3s1"
K3S_INSTALL_NAME="embernet-agent"            # -> unit k3s-embernet-agent.service
K3S_TOKEN_FILE="/etc/embernet/k3s-token"

NODE_IP="${NODE_IP:-}"   # auto-detected from embernet0 after enrollment

# ---------------- HELPERS ----------------
log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
fail() { printf '\n[x] %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || fail "Run as root: sudo bash trane/deploy-ut3-en01.sh"
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

if [[ -x /usr/local/bin/k3s ]]; then
  fail "K3s already present on this box. EN-0001 is meant to be virgin.
      If this is a re-run, uninstall first:  /usr/local/bin/k3s-embernet-agent-uninstall.sh"
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
  # The endpoint daemon does NOT auto-issue a device code — the enroll
  # wizard does, and it prints the code to THIS terminal. Run it inline
  # (skip if embernet0 is already up from a prior enrollment). The wizard
  # blocks until the operator completes the browser device-login.
  if [[ "$(cat /var/lib/embernet/device.name 2>/dev/null || true)" == "Trane-UT3-EN-0001" ]] \
     && ip -4 -o addr show embernet0 2>/dev/null | grep -q "${TRANE_SUBNET_PREFIX}"; then
    log "Already enrolled as Trane-UT3-EN-0001 (embernet0 up) — skipping enroll."
  else
    echo
    log "Enrolling endpoint as Trane-UT3-EN-0001. A device code prints below —"
    log "open https://microsoft.com/devicelogin in a browser and enter it:"
    echo
    podman exec -it embernet embernetlite enroll --device-name "Trane-UT3-EN-0001" \
      || warn "enroll exited non-zero; re-run if needed: sudo podman exec -it embernet embernetlite enroll --device-name Trane-UT3-EN-0001"
    echo
    log "Restarting endpoint so the daemon applies the enrollment..."
    podman restart embernet >/dev/null 2>&1 || true
  fi
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
  log "[2/4] Endpoint enrolled — EN-0001 mesh IP: ${NODE_IP}"

  log "Checking reachability to the CP-02 apiserver (${SEED_IP}:6443)..."
  (echo >"/dev/tcp/${SEED_IP}/6443") 2>/dev/null \
    && log "CP-02 apiserver reachable over the mesh." \
    || warn "Cannot reach ${SEED_IP}:6443 yet — the join will retry, but verify the mesh if it hangs."
}

# =============================================================
# [3/4] K3s agent — join CP-02
# =============================================================
install_k3s_agent() {
  log "[3/4] Installing K3s agent (join to CP-02)..."
  # CP-02 shared cluster token, baked in for the ephemeral demo cluster.
  # Override with K3S_TOKEN env or a /etc/embernet/k3s-token file if it rotates.
  local token="${K3S_TOKEN:-72d6bbbe257a0ac028cde59d4c1ab413cb5694f3cec2a37b411efcdd936172a3}"
  [[ -s "$K3S_TOKEN_FILE" ]] && token="$(tr -d '[:space:]' < "$K3S_TOKEN_FILE")"

  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_NAME="${K3S_INSTALL_NAME}" \
    K3S_URL="${SEED_URL}" \
    K3S_TOKEN="${token}" \
    sh -s - agent \
      --node-name="${NODE_NAME_LOWER}" \
      --node-ip="${NODE_IP}" \
      --flannel-iface=embernet0 \
      --node-label="embernet.ai/tenant=${TENANT}" \
      --node-label="embernet.ai/site=ut3" \
      --node-label="embernet.ai/role=${NODE_ROLE}" \
      --node-label="embernet.ai/node-name=${NODE_NAME_LOWER}"

  log "[3/4] K3s agent installed (unit: k3s-${K3S_INSTALL_NAME}.service)."
}

# =============================================================
# [4/4] Verify — agents have no local kubeconfig, so check the unit
#       and point the operator at a control plane to confirm the join.
# =============================================================
verify() {
  log "[4/4] Verifying k3s-${K3S_INSTALL_NAME}.service..."
  local waited=0
  while (( waited < 120 )); do
    systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}" && break
    sleep 5; waited=$((waited+5))
  done
  if systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}"; then
    log "[4/4] k3s-${K3S_INSTALL_NAME}.service is active."
    cat <<EOF

  Confirm the join from a control-plane node (e.g. CP-02):
      k3s kubectl get node ${NODE_NAME_LOWER} -o wide

EOF
  else
    warn "k3s-${K3S_INSTALL_NAME} not active. Inspect: journalctl -xeu k3s-${K3S_INSTALL_NAME} --no-pager -n 60"
  fi
}

# ---------------- MAIN ----------------
log "=== Trane UT3 EN-0001 — join CP-02 as edge node (${NODE_NAME_LOWER}) ==="
install_endpoint
wait_for_enrollment
install_k3s_agent
verify
log "=== EN-0001 done. ==="
