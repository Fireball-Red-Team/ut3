#!/usr/bin/env bash
# =============================================================
# Trane UT3 — CP-03 : join CP-02's trane-ut3 cluster as a k3s AGENT,
#   with the apiserver dial riding Flux/Ziti (TCP 443) instead of
#   WireGuard (UDP, blocked on the 10.200.32.x segment).
#
# Three things, in order:
#   1. EmbernetEndpoint-Linux — endpoint container + enroll AS
#      "Trane-UT3-CP-03" (mesh/dashboard identity; gives embernet0 a
#      100.64.1.x address used as the k3s --node-ip).
#   2. flux-edge-tunnel — Ziti dial in 'proxy' mode: binds a local
#      127.0.0.1:6443 listener and tunnels to CP-02's apiserver over
#      Flux. (embernetlite's own Flux driver is a stub — the real
#      overlay data plane is this ziti-edge-tunnel container.)
#   3. K3s AGENT — joins CP-02 via K3S_URL=https://127.0.0.1:6443
#      (the LOCAL Flux proxy; 127.0.0.1 is a SAN on CP-02's apiserver
#      cert, so TLS verifies). NOT a server; NOT --cluster-init.
#
# CP-02 (100.64.1.3, node trane-ut3-cp-02) is the live control plane
# and is LEFT UNTOUCHED.
#
# Prereqs:
#   1. CP-02 shared cluster token on this box:
#        sudo scp user@100.64.1.3:/etc/embernet/k3s-token /etc/embernet/k3s-token
#        sudo chmod 600 /etc/embernet/k3s-token
#   2. A one-time Flux enrollment JWT for identity "Embernode-UT3-CP03"
#      (roleAttribute 'trane-ut3'), UNLESS it is already enrolled in the
#      embernet-flux-identity volume. Provide via env or file:
#        FLUX_ENROLLMENT_JWT='<jwt>' sudo bash deploy-ut3-cp03.sh
#        # or: place it at /etc/embernet/flux-cp03.jwt and re-run
#
#   sudo bash deploy-ut3-cp03.sh
# =============================================================
set -euo pipefail

NODE_NAME_LOWER="trane-ut3-cp-03"        # k3s node name (preserved)
DEVICE_NAME="Trane-UT3-CP-03"            # embernetlite endpoint identity (mesh/dashboard)
FLUX_IDENTITY_NAME="Embernode-UT3-CP03"  # flux-edge-tunnel Ziti identity (apiserver dial)
NODE_ROLE="edge"                         # was 'control-plane' — CP-03 now joins as an agent/worker
TENANT="tranetech-ut3"

# The apiserver is dialed through the LOCAL Flux proxy (see install_flux_tunnel).
# 127.0.0.1 is a SAN on CP-02's apiserver cert, so the agent's TLS verifies.
APISERVER_URL="https://127.0.0.1:6443"
SEED_IP="100.64.1.3"                     # CP-02 mesh IP (kept only for the node-ip collision guard)
TRANE_SUBNET_PREFIX="100.64.1."

EMBERNET_IMAGE="ghcr.io/embernet-ai/embernetlite:0.0.47"
FLUX_TUNNEL_IMAGE="ghcr.io/embernet-ai/flux-edge-tunnel:latest"
FLUX_SERVICE="trane-ut3-k3s-api"         # Ziti service; its bind is hosted by CP-02
FLUX_LOCAL_PORT="6443"                   # local port the Flux proxy binds
FLUX_JWT_FILE="/etc/embernet/flux-cp03.jwt"

K3S_VERSION="v1.34.5+k3s1"
K3S_INSTALL_NAME="embernet-agent"        # was embernet-server -> unit k3s-embernet-agent.service
K3S_TOKEN_FILE="/etc/embernet/k3s-token"

log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
fail() { printf '\n[x] %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || fail "Run as root: sudo bash deploy-ut3-cp03.sh"

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

# --- [1/5] EmbernetEndpoint container (mesh IP + dashboard) ------------------
install_endpoint() {
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx embernet; then
    log "[1/5] Endpoint container already running."
    return 0
  fi
  log "[1/5] Installing EmbernetEndpoint-Linux (${EMBERNET_IMAGE})..."
  mkdir -p /etc/embernet /var/lib/embernet /var/log/embernet /run/embernet
  chown 987:987 /var/lib/embernet /var/log/embernet /run/embernet
  # Plain `podman run` (NOT a Quadlet .container) so it works on ANY podman
  # version — Quadlet's systemd generator needs podman 4.4+.
  podman pull "${EMBERNET_IMAGE}"
  podman rm -f embernet 2>/dev/null || true
  podman run -d --name embernet --restart=always --network host \
    --cap-add CAP_NET_ADMIN --cap-add CAP_NET_RAW --device /dev/net/tun \
    -e EMBERNET_TENANT_HINT="${TENANT}" -e EMBERNET_SAFETY_WATCHDOG_DISABLED=1 -e HOME=/var/lib/embernet \
    -v /etc/embernet:/etc/embernet -v /etc/os-release:/etc/os-release:ro \
    -v /var/lib/embernet:/var/lib/embernet -v /var/log/embernet:/var/log/embernet -v /run/embernet:/run/embernet \
    "${EMBERNET_IMAGE}"
  systemctl enable podman-restart.service 2>/dev/null || true
  log "[1/5] Endpoint container 'embernet' running."
}

# --- [2/5] Enroll AS Trane-UT3-CP-03 ----------------------------------------
enroll_endpoint() {
  local current; current="$(cat /var/lib/embernet/device.name 2>/dev/null || true)"
  if [[ "$current" == "$DEVICE_NAME" ]] && ip -4 -o addr show embernet0 2>/dev/null | grep -q "${TRANE_SUBNET_PREFIX}"; then
    log "[2/5] Already enrolled as ${DEVICE_NAME} (embernet0 up) — skipping."
    return 0
  fi
  echo
  log "[2/5] Enrolling endpoint as ${DEVICE_NAME}. A device code prints below —"
  log "open https://microsoft.com/devicelogin in a browser and enter it:"
  echo
  podman exec -it embernet embernetlite enroll --device-name "${DEVICE_NAME}" \
    || warn "enroll exited non-zero; re-run if needed: sudo podman exec -it embernet embernetlite enroll --device-name ${DEVICE_NAME}"
  echo
  log "Restarting endpoint so the daemon applies the enrollment..."
  podman restart embernet >/dev/null 2>&1 || true
  log "Waiting for embernet0 to obtain a ${TRANE_SUBNET_PREFIX}x address..."
  local w=0
  while (( w < 300 )); do
    ip -4 -o addr show embernet0 2>/dev/null | grep -q "${TRANE_SUBNET_PREFIX}" && break
    sleep 5; w=$((w+5))
  done
}

# --- [3/5] flux-edge-tunnel: the Ziti dial (proxy mode, no TUN, no DNS) ------
install_flux_tunnel() {
  log "[3/5] Deploying flux-edge-tunnel (Ziti dial, 'proxy' mode)..."
  podman pull "${FLUX_TUNNEL_IMAGE}" 2>/dev/null || true
  podman volume inspect embernet-flux-identity >/dev/null 2>&1 || podman volume create embernet-flux-identity >/dev/null
  local vol; vol="$(podman volume inspect embernet-flux-identity --format '{{.Mountpoint}}')"

  if [[ -s "${vol}/${FLUX_IDENTITY_NAME}.json" ]]; then
    log "Flux identity ${FLUX_IDENTITY_NAME} already enrolled — reusing (no JWT needed)."
  else
    local jwt="${FLUX_ENROLLMENT_JWT:-}"
    [[ -z "$jwt" && -s "$FLUX_JWT_FILE" ]] && jwt="$(cat "$FLUX_JWT_FILE")"
    [[ -n "$jwt" ]] || fail "flux-edge-tunnel needs a one-time enrollment JWT for ${FLUX_IDENTITY_NAME}.
      Mint it at the Flux controller (identity ${FLUX_IDENTITY_NAME}, roleAttribute 'trane-ut3'), then:
        FLUX_ENROLLMENT_JWT='<jwt>' sudo bash $(basename "$0")
      or place the JWT at ${FLUX_JWT_FILE} and re-run."
    printf '%s' "$jwt" > "${vol}/${FLUX_IDENTITY_NAME}.jwt"
    chmod 600 "${vol}/${FLUX_IDENTITY_NAME}.jwt"
    log "Staged one-time enrollment JWT (consumed on first boot; identity then persists in the volume)."
  fi

  cat > /etc/systemd/system/embernet-flux-edge-tunnel.service <<UNIT
[Unit]
Description=Embernet Flux Edge Tunnel (proxy ${FLUX_SERVICE} -> 127.0.0.1:${FLUX_LOCAL_PORT})
Wants=network-online.target
After=network-online.target
RequiresMountsFor=%t/containers
[Service]
Environment=PODMAN_SYSTEMD_UNIT=%n
Restart=always
TimeoutStopSec=70
ExecStartPre=/bin/rm -f %t/%n.ctr-id
ExecStart=/usr/bin/podman run --cidfile=%t/%n.ctr-id --cgroups=no-conmon --rm --sdnotify=conmon --replace -d --name embernet-flux-edge-tunnel --network=host --privileged -v embernet-flux-identity:/ziti-identity -e ZITI_IDENTITY_DIR=/ziti-identity -e ZITI_IDENTITY_BASENAME=${FLUX_IDENTITY_NAME} -e ZITI_CONTROLLER_URL=https://flux.embernet.ai:443 -e PFXLOG_NO_JSON=true ${FLUX_TUNNEL_IMAGE} proxy ${FLUX_SERVICE}:${FLUX_LOCAL_PORT}
ExecStartPost=/bin/sh -c 'iptables -t nat -C OUTPUT -p tcp -d ${SEED_IP} --dport 6443 -j REDIRECT --to-ports ${FLUX_LOCAL_PORT} 2>/dev/null || iptables -t nat -A OUTPUT -p tcp -d ${SEED_IP} --dport 6443 -j REDIRECT --to-ports ${FLUX_LOCAL_PORT}'
ExecStop=/usr/bin/podman stop --ignore --cidfile=%t/%n.ctr-id
ExecStopPost=/usr/bin/podman rm -f --ignore --cidfile=%t/%n.ctr-id
ExecStopPost=/bin/sh -c 'iptables -t nat -D OUTPUT -p tcp -d ${SEED_IP} --dport 6443 -j REDIRECT --to-ports ${FLUX_LOCAL_PORT} 2>/dev/null || true'
Type=notify
NotifyAccess=all
[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now embernet-flux-edge-tunnel.service >/dev/null 2>&1 || true

  # apiserver-IP redirect: k3s agents auto-discover CP-02's ADVERTISED apiserver
  # (${SEED_IP}:6443) and switch their load balancer to dial it directly — which
  # is dead over WireGuard, so the node goes NotReady ~1 min after joining.
  # Route that IP into the local Flux proxy. (The unit's ExecStartPost makes this
  # reboot-durable; this handles the already-running / re-run case.)
  if command -v iptables >/dev/null; then
    iptables -t nat -C OUTPUT -p tcp -d "${SEED_IP}" --dport 6443 -j REDIRECT --to-ports "${FLUX_LOCAL_PORT}" 2>/dev/null \
      || iptables -t nat -A OUTPUT -p tcp -d "${SEED_IP}" --dport 6443 -j REDIRECT --to-ports "${FLUX_LOCAL_PORT}"
    log "apiserver redirect installed: ${SEED_IP}:6443 -> local Flux proxy :${FLUX_LOCAL_PORT}."
  else
    warn "iptables not found — install it, else k3s dials ${SEED_IP}:6443 directly and the node goes NotReady."
  fi

  log "Waiting for the Flux proxy to bind :${FLUX_LOCAL_PORT}..."
  local w=0
  while (( w < 150 )); do
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${FLUX_LOCAL_PORT}\$" && break
    sleep 3; w=$((w+3))
  done
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${FLUX_LOCAL_PORT}\$" \
    || fail "flux-edge-tunnel proxy never bound :${FLUX_LOCAL_PORT}. Inspect: podman logs embernet-flux-edge-tunnel"
  local code; code="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://127.0.0.1:${FLUX_LOCAL_PORT}/healthz" 2>/dev/null || true)"
  if [[ "$code" =~ ^(200|401|403)$ ]]; then
    log "[3/5] Flux proxy up — CP-02 apiserver reachable over Ziti (HTTP ${code})."
  else
    warn "Proxy bound but apiserver not answering yet (HTTP '${code}'); k3s agent will retry."
  fi
}

# --- [4a] Tear down any prior k3s SERVER install (A6) -----------------------
teardown_server_remnants() {
  # CP-03 previously had a (failed/partial) k3s SERVER install. Remove it
  # before installing the agent. GUARD: never tear down a HEALTHY control
  # plane (protects against running this edge script on CP-02 by mistake).
  if systemctl is-active --quiet k3s-embernet-server 2>/dev/null \
     && [[ -f /etc/rancher/k3s/k3s.yaml ]] \
     && /usr/local/bin/k3s kubectl get nodes 2>/dev/null | grep -qiE 'control-plane.*ready|ready.*control-plane'; then
    fail "A healthy k3s control-plane server is running on this box — refusing to uninstall.
      This edge script must NOT be run on a live control plane (CP-02?)."
  fi
  local did=0 u
  for u in /usr/local/bin/k3s-embernet-server-uninstall.sh /usr/local/bin/k3s-server-uninstall.sh; do
    if [[ -x "$u" ]]; then warn "Removing prior k3s server install via ${u} ..."; "$u" || true; did=1; fi
  done
  (( did )) && log "[4/5] Prior k3s server remnants removed." || true
}

# --- [4b] K3s AGENT — join CP-02 over the local Flux proxy -------------------
install_k3s() {
  if [[ -x /usr/local/bin/k3s ]] && systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}" 2>/dev/null; then
    log "[4/5] k3s-${K3S_INSTALL_NAME} already active — nothing to install."
    return 0
  fi
  local node_ip flannel_flag=""
  node_ip="$(ip -4 -o addr show embernet0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep "^${TRANE_SUBNET_PREFIX}" | head -1 || true)"
  [[ -n "$node_ip" ]] || node_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -n "$node_ip" ]] || fail "Could not determine a node IP for ${NODE_NAME_LOWER}."
  [[ "$node_ip" != "$SEED_IP" ]] || fail "This box's node IP (${node_ip}) is CP-02's seed IP — wrong box."
  ip link show embernet0 >/dev/null 2>&1 && flannel_flag="--flannel-iface=embernet0"

  log "[4/5] CP-03 node IP: ${node_ip}; dialing apiserver via local Flux proxy ${APISERVER_URL}"
  (echo >"/dev/tcp/127.0.0.1/${FLUX_LOCAL_PORT}") 2>/dev/null \
    && log "Local Flux proxy :${FLUX_LOCAL_PORT} reachable." \
    || warn "Local Flux proxy :${FLUX_LOCAL_PORT} not reachable yet — join will retry."

  # CP-02 shared cluster token, baked in for the ephemeral demo cluster.
  # Override with K3S_TOKEN env or a /etc/embernet/k3s-token file if it rotates.
  local token="${K3S_TOKEN:-72d6bbbe257a0ac028cde59d4c1ab413cb5694f3cec2a37b411efcdd936172a3}"
  [[ -s "$K3S_TOKEN_FILE" ]] && token="$(tr -d '[:space:]' < "$K3S_TOKEN_FILE")"

  log "Installing k3s agent, joining the Trane cluster via ${APISERVER_URL}..."
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" INSTALL_K3S_NAME="${K3S_INSTALL_NAME}" \
    K3S_URL="${APISERVER_URL}" K3S_TOKEN="${token}" \
    sh -s - agent \
      --node-name="${NODE_NAME_LOWER}" \
      --node-ip="${node_ip}" \
      ${flannel_flag} \
      --node-label="embernet.ai/tenant=${TENANT}" \
      --node-label="embernet.ai/site=ut3" \
      --node-label="embernet.ai/role=${NODE_ROLE}" \
      --node-label="embernet.ai/node-name=${NODE_NAME_LOWER}"
  log "[4/5] K3s agent installed (unit: k3s-${K3S_INSTALL_NAME}.service)."
}

# --- [5/5] Verify — agents have no local kubeconfig ------------------------
verify() {
  log "[5/5] Verifying k3s-${K3S_INSTALL_NAME}.service..."
  local w=0
  while (( w < 120 )); do
    systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}" && break
    sleep 5; w=$((w+5))
  done
  if systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}"; then
    log "[5/5] k3s-${K3S_INSTALL_NAME}.service is active."
    cat <<EOF

  Confirm the join from CP-02:
      k3s kubectl get node ${NODE_NAME_LOWER} -o wide

EOF
  else
    warn "k3s-${K3S_INSTALL_NAME} not active. Inspect: journalctl -xeu k3s-${K3S_INSTALL_NAME} --no-pager -n 60"
  fi
}

# ---------------- MAIN ----------------
log "=== Trane UT3 CP-03 — endpoint (${DEVICE_NAME}) + Flux dial + join CP-02 as agent ==="
install_endpoint
enroll_endpoint
install_flux_tunnel
teardown_server_remnants
install_k3s
verify
log "=== CP-03 done. ==="
