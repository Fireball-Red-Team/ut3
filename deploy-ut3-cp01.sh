#!/usr/bin/env bash
# =============================================================
# Trane UT3 — CP-01  K3s install (JOIN the Trane Rancher cluster)
#
# The EmbernetEndpoint-Linux endpoint is installed + enrolled SEPARATELY
# (podman container 'embernet' + `sudo podman exec -it embernet embernetlite
# enroll`). This script does ONLY the k3s step: join CP-01 as an HA
# control-plane member of the EXISTING Trane cluster seeded by CP-02
# (node trane-ut3-cp-02 = the trane-ut3 cluster in Rancher). It is a JOIN
# (--server), NOT a fresh --cluster-init.
#
# Prereqs on this box (already satisfied by the endpoint step):
#   - embernet0 is up with a 100.64.1.x address (endpoint enrolled)
#   - CP-02's shared cluster token is present:
#       sudo scp user@100.64.1.3:/etc/embernet/k3s-token /etc/embernet/k3s-token
#       sudo chmod 600 /etc/embernet/k3s-token
#
#   sudo bash deploy-ut3-cp01.sh
# =============================================================
set -euo pipefail

NODE_NAME_LOWER="trane-ut3-cp-01"
NODE_ROLE="control-plane"
TENANT="tranetech-ut3"
SEED_URL="https://100.64.1.3:6443"     # CP-02 apiserver over the mesh
SEED_IP="100.64.1.3"
TRANE_SUBNET_PREFIX="100.64.1."
K3S_VERSION="v1.34.5+k3s1"
K3S_INSTALL_NAME="embernet-server"     # -> unit k3s-embernet-server.service
K3S_TOKEN_FILE="/etc/embernet/k3s-token"

log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
fail() { printf '\n[x] %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || fail "Run as root: sudo bash deploy-ut3-cp01.sh"
command -v curl >/dev/null || { apt-get update -y; apt-get install -y curl; }

# --- 1) endpoint must be enrolled: embernet0 up in the Trane /24 -------------
NODE_IP="$(ip -4 -o addr show embernet0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep "^${TRANE_SUBNET_PREFIX}" | head -1 || true)"
[[ -n "$NODE_IP" ]] || fail "embernet0 has no ${TRANE_SUBNET_PREFIX}x address — enroll the endpoint first:
      sudo podman exec -it embernet embernetlite enroll"
[[ "$NODE_IP" != "$SEED_IP" ]] || fail "This box's embernet0 (${NODE_IP}) is CP-02's seed IP — wrong box."
log "Endpoint enrolled — CP-01 mesh IP: ${NODE_IP}"

# --- 2) reachability to the Trane cluster apiserver on CP-02 -----------------
log "Checking CP-02 apiserver ${SEED_IP}:6443 over the mesh..."
(echo >"/dev/tcp/${SEED_IP}/6443") 2>/dev/null \
  && log "CP-02 apiserver reachable." \
  || warn "Cannot reach ${SEED_IP}:6443 yet — the join will retry; verify the mesh if it hangs."

# --- 3) shared cluster join token -------------------------------------------
[[ -s "$K3S_TOKEN_FILE" ]] || fail "Missing cluster join token at ${K3S_TOKEN_FILE}.
      sudo scp user@${SEED_IP}:/etc/embernet/k3s-token ${K3S_TOKEN_FILE}
      sudo chmod 600 ${K3S_TOKEN_FILE}"
TOKEN="$(tr -d '[:space:]' < "$K3S_TOKEN_FILE")"

# --- 4) join CP-02's k3s cluster as an HA control-plane server --------------
if [[ -x /usr/local/bin/k3s ]] && systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}" 2>/dev/null; then
  log "k3s-${K3S_INSTALL_NAME} already active — nothing to install."
else
  mkdir -p /etc/rancher/k3s
  printf 'disable-network-policy: true\n' > /etc/rancher/k3s/config.yaml
  log "Installing k3s server, JOINING the Trane cluster at ${SEED_URL}..."
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_NAME="${K3S_INSTALL_NAME}" \
    K3S_TOKEN="${TOKEN}" \
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
fi

# --- 5) verify it joined and went Ready -------------------------------------
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
log "Waiting for ${NODE_NAME_LOWER} to register Ready (max 180s)..."
w=0
while (( w < 180 )); do
  if /usr/local/bin/k3s kubectl get node "${NODE_NAME_LOWER}" 2>/dev/null | grep -q ' Ready'; then
    log "${NODE_NAME_LOWER} is Ready — joined the Trane cluster."
    /usr/local/bin/k3s kubectl get nodes -o wide 2>/dev/null | grep -E "NAME|trane-ut3" || true
    exit 0
  fi
  sleep 5; w=$((w+5))
done
warn "${NODE_NAME_LOWER} not Ready yet. Inspect: journalctl -xeu k3s-${K3S_INSTALL_NAME} --no-pager -n 60"
