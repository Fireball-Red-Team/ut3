#!/usr/bin/env bash
# =============================================================================
# upgrade-trane-node.sh — Trane UT3 node -> embernetlite v1.0.7, k3s over Flux
#
#     sudo bash upgrade-trane-node.sh
#
# For: trane-ut3-cp-01, cp-03, en-0001, en-0002, en-0003  (k3s AGENTS)
# NOT for: trane-ut3-cp-02 (k3s server, host mode — already on 1.0.7)
#          ut3-ignition / ut3-cp-em-0001 (Azure — already on 1.0.7)
#
# HOW k3s IS TUNNELED (read before running)
#   Before: k3s agent -> 127.0.0.1:6443 -> flux-edge-tunnel container
#           (a SEPARATE podman container running `proxy trane-ut3-k3s-api:6443`)
#           -> Ziti fabric -> CP-02 apiserver
#   After:  k3s agent -> 127.0.0.1:6443 -> embernetlite (proxy mode)
#           -> Ziti fabric -> CP-02 apiserver
#   The listener moves INTO the endpoint. The path is otherwise unchanged.
#
#   Two things make it work and both are load-bearing:
#     1. EMBERNET_FLUX_TUNNEL_PROXY=trane-ut3-k3s-api:6443 makes embernetlite
#        open a local :6443 listener and forward it over the overlay.
#     2. The apiserver REDIRECT (step 7). k3s agents auto-discover CP-02's
#        ADVERTISED address (100.64.1.3) and their load balancer dials it
#        DIRECTLY, ignoring K3S_URL. Without the redirect the node goes
#        NotReady ~1 min after start even with :6443 bound correctly.
#
# ALIGNED WITH deploy-ut3-en03.sh
#   Container name, mount modes, EMBERNET_TENANT_HINT, HOME,
#   EMBERNET_SAFETY_WATCHDOG_DISABLED, the anchored port poll and the
#   end-to-end reachability gate all match that script. Its obsolete parts
#   (flux-edge-tunnel unit, JWT staging, identity volume) are replaced by the
#   built-in tunneler.
#
# NOT YET RUN END TO END. Each step was executed by hand on trane-ut3-cp-02 and
# the Azure VM; the assembly is untested. Prefer trane-ut3-cp-03 first.
# =============================================================================
set -euo pipefail

# ---- pinned values. Do not guess these. -------------------------------------
EMBERNET_IMAGE="ghcr.io/embernet-ai/embernetlite:1.0.7"
FLUX_SERVICE="trane-ut3-k3s-api"     # Ziti service fronting CP-02's apiserver
FLUX_LOCAL_PORT="6443"               # local listener the k3s agent dials
SEED_IP="100.64.1.3"                 # CP-02's ADVERTISED apiserver (en03:45)
TENANT="tranetech-ut3"               # EMBERNET_TENANT_HINT (en03:40)
CONTAINER="embernet"                 # en03:110 — runbooks key on this name
UNIT="embernet.service"
REDIRECT_UNIT="embernet-k3s-redirect.service"
BK="/root/embernet-migration-backup"
IDENTITY_DIR="/var/lib/embernet/identity"
FLUX_VOL="/var/lib/containers/storage/volumes/embernet-flux-identity/_data"

log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
fail() { printf '\n[x] %s\n' "$*" >&2; exit 1; }

# =============================================================================
# [1/7] PREFLIGHT — cheap checks that can fail the run go first
# =============================================================================
[[ "$EUID" -eq 0 ]] || fail "Run as root: sudo bash $0"
for b in podman nft curl ss; do
  command -v "$b" >/dev/null || fail "Missing '${b}'. Install then re-run: apt-get install -y ${b}"
done

NODE="$(hostname)"
log "[1/7] node=${NODE}  image=${EMBERNET_IMAGE}  podman $(podman --version 2>/dev/null | awk '{print $3}')"

mkdir -p "$BK"
cp -a "$IDENTITY_DIR" "$BK/identity-backup-$(date +%s)" 2>/dev/null || true
podman inspect embernet-flux-edge-tunnel > "$BK/flux-tunnel-inspect.json" 2>/dev/null || true
podman inspect "$CONTAINER"              > "$BK/embernet-inspect.json"    2>/dev/null || true
PREV_IMG="$(podman inspect "$CONTAINER" --format '{{.ImageName}}' 2>/dev/null || echo none)"
log "current endpoint image: ${PREV_IMG}"

# Pull BEFORE tearing anything down: a registry failure then changes nothing.
log "[2/7] Pulling ${EMBERNET_IMAGE}..."
podman pull "$EMBERNET_IMAGE" >/dev/null \
  || fail "Pull failed — check egress to ghcr.io. Nothing changed; safe to re-run."

# =============================================================================
# [3/7] IDENTITY
#
# Each node's own Trane-UT3-* identity was granted the 'trane-ut3' role
# attribute centrally, which authorizes dialing trane-ut3-k3s-api. That alone
# is enough for the k3s API path.
#
# The Embernode-UT3-* identity in the flux volume additionally BINDS this
# node's services (kubelet, codesys, postgres, ut3-cloud, ut3-edge). If present
# we hand it over so those binds survive the tunnel container going away.
# Filename differs per node — glob it, never hardcode.
# =============================================================================
SRC="$(ls "${FLUX_VOL}"/Embernode-UT3-*.json 2>/dev/null | head -1 || true)"
if [[ -n "$SRC" ]]; then
  log "[3/7] Identity handover: $(basename "$SRC") (preserves this node's service binds)"
  install -m 0600 "$SRC" "${IDENTITY_DIR}/$(basename "$SRC")"
  ln -sfn "$(basename "$SRC")" "${IDENTITY_DIR}/embernet.json"
  log "embernet.json -> $(readlink "${IDENTITY_DIR}/embernet.json")"
else
  log "[3/7] No Embernode identity in the flux volume — keeping the endpoint's own."
  log "      Dial auth comes from the 'trane-ut3' role attribute; binds will not carry over."
fi

# Container runs as uid 987. A node migrated off the .deb has these owned by
# the HOST embernet user (997) and the daemon dies with
#   read token at /var/lib/embernet/auth.token: permission denied
# -R, not just the dirs: the files already exist.
mkdir -p /etc/embernet /var/lib/embernet /var/log/embernet /run/embernet
chown -R 987:987 /var/lib/embernet /var/log/embernet /run/embernet 2>/dev/null || true

# =============================================================================
# [4/7] RETIRE THE OLD FLUX TUNNEL CONTAINER
#
# Two unit names exist in the field. Disabling only one leaves the container
# running and holding :6443, so the endpoint cannot bind its proxy.
#
# NOTE: the en03 unit's ExecStopPost DELETES the iptables apiserver redirect on
# stop. Step 7 installs an equivalent nft rule; do not skip it.
# =============================================================================
for u in embernet-flux-edge-tunnel.service container-embernet-flux-edge-tunnel.service; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${u}"; then
    log "[4/7] Retiring ${u}"
    cp "/etc/systemd/system/${u}" "$BK/" 2>/dev/null || true
    systemctl disable --now "$u" >/dev/null 2>&1 || true
  fi
done
podman rm -f embernet-flux-edge-tunnel >/dev/null 2>&1 || true
systemctl daemon-reload

if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${FLUX_LOCAL_PORT}\$"; then
  ss -lntp 2>/dev/null | grep ":${FLUX_LOCAL_PORT}" >&2 || true
  fail "Port ${FLUX_LOCAL_PORT} still held (above). Stop that unit, then re-run."
fi
log "Port ${FLUX_LOCAL_PORT} free."

# =============================================================================
# [5/7] RUN EMBERNETLITE IN PROXY MODE
#
# Flags match deploy-ut3-en03.sh:110-115 plus CAP_NET_BIND_SERVICE and the
# proxy env var.
#
# NO trailing 'daemon': the image declares
#   ENTRYPOINT ["/sbin/tini","--"]  CMD ["/usr/bin/embernetlite","daemon"]
# Appending it overrides CMD, tini execs a binary named "daemon", exit 127.
#
# /etc/embernet is READ-WRITE, matching en03. Do not add :ro.
# EMBERNET_SAFETY_WATCHDOG_DISABLED=1 matches en03:112 — the watchdog pings the
# pre-tunnel gateway and rolls back every tunnel if it never answers.
# =============================================================================
log "[5/7] Starting ${CONTAINER} (proxy ${FLUX_SERVICE}:${FLUX_LOCAL_PORT})..."
podman rm -f "$CONTAINER" systemd-embernet >/dev/null 2>&1 || true
podman run -d \
  --name "$CONTAINER" \
  --restart=always \
  --network=host \
  --cap-add=CAP_NET_ADMIN \
  --cap-add=CAP_NET_RAW \
  --cap-add=CAP_NET_BIND_SERVICE \
  --device=/dev/net/tun \
  -e "EMBERNET_TENANT_HINT=${TENANT}" \
  -e EMBERNET_SAFETY_WATCHDOG_DISABLED=1 \
  -e HOME=/var/lib/embernet \
  -e "EMBERNET_FLUX_TUNNEL_PROXY=${FLUX_SERVICE}:${FLUX_LOCAL_PORT}" \
  -v /etc/embernet:/etc/embernet \
  -v /etc/os-release:/etc/os-release:ro \
  -v /var/lib/embernet:/var/lib/embernet \
  -v /var/log/embernet:/var/log/embernet \
  -v /run/embernet:/run/embernet \
  "$EMBERNET_IMAGE" >/dev/null \
  || fail "podman run failed. Inspect: podman logs ${CONTAINER}"

# =============================================================================
# [6/7] SYSTEMD UNIT + WAIT FOR THE LISTENER
#
# `podman generate systemd`, NOT Quadlet: Ubuntu 22.04 ships podman 3.4.4 and
# Quadlet needs >= 4.4 — it silently produces no unit and the failure reads
# "Unit embernet.service not found".
# =============================================================================
sleep 5
log "[6/7] Generating ${UNIT}..."
( cd /etc/systemd/system && podman generate systemd \
    --name "$CONTAINER" --new --restart-policy=always \
    --container-prefix='' --separator='' > "$UNIT" ) \
  || fail "podman generate systemd failed."
systemctl daemon-reload
systemctl enable "$UNIT" >/dev/null 2>&1 || true

log "Waiting for the Flux proxy to bind :${FLUX_LOCAL_PORT}..."
w=0
while (( w < 150 )); do
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${FLUX_LOCAL_PORT}\$" && break
  sleep 3; w=$((w+3))
done
ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${FLUX_LOCAL_PORT}\$" \
  || fail "Proxy never bound :${FLUX_LOCAL_PORT}. Inspect: podman logs --tail 50 ${CONTAINER}"
log "Listener up after ${w}s."

# =============================================================================
# [7/7] APISERVER REDIRECT, REBOOT-DURABLE
#
# k3s agents auto-discover CP-02's ADVERTISED apiserver (${SEED_IP}:6443) and
# switch their load balancer to dial it DIRECTLY, bypassing K3S_URL. Send it to
# the local Flux proxy instead. Without this the node goes NotReady ~1 min
# after start even with a healthy listener (deploy-ut3-en03.sh:190-194).
#
# In OUR nft table, not system iptables, so FACILITY_SAFETY.md §1.3 (never
# touch system-managed tables) and §1.7 (`nft delete table` is the whole
# teardown) hold. PartOf=embernet.service replaces the ExecStartPost the
# retired unit used to carry.
#
# nft comments must not contain ':' unless quoted — bash strips the quotes
# before nft sees them. Hence the hyphenated comment.
# =============================================================================
cat > /etc/embernet/k3s-apiserver-redirect.nft <<NFT
table inet embernet_k3s {
	chain apiserver_redirect {
		type nat hook output priority dstnat; policy accept;
		ip daddr ${SEED_IP} tcp dport ${FLUX_LOCAL_PORT} redirect to :${FLUX_LOCAL_PORT} comment "embernet-k3s-apiserver-via-flux"
	}
}
NFT

cat > "/etc/systemd/system/${REDIRECT_UNIT}" <<UNITFILE
[Unit]
Description=Route the k3s apiserver address through the EmberNET Flux proxy
After=network-online.target ${UNIT}
Wants=network-online.target
PartOf=${UNIT}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/usr/sbin/nft delete table inet embernet_k3s 2>/dev/null; /usr/sbin/nft -f /etc/embernet/k3s-apiserver-redirect.nft'
ExecStop=/bin/sh -c '/usr/sbin/nft delete table inet embernet_k3s 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
UNITFILE

systemctl daemon-reload
systemctl enable --now "$REDIRECT_UNIT" >/dev/null 2>&1 \
  || warn "${REDIRECT_UNIT} failed to start — k3s will dial ${SEED_IP} directly and go NotReady."
if nft list table inet embernet_k3s >/dev/null 2>&1; then
  log "[7/7] Apiserver redirect installed: ${SEED_IP}:${FLUX_LOCAL_PORT} -> local Flux proxy."
else
  warn "Redirect table missing. Check: nft list table inet embernet_k3s"
fi

K3SU="$(systemctl list-unit-files 2>/dev/null | grep -oE '^k3s-[a-z-]+\.service' | head -1 || true)"
if [[ -n "$K3SU" ]]; then
  log "Restarting ${K3SU} so the agent picks up the new path..."
  systemctl restart "$K3SU" || warn "${K3SU} restart failed. Inspect: journalctl -xeu ${K3SU} -n 60"
fi

# =============================================================================
# VERIFICATION
# =============================================================================
sleep 20
printf '\n──────── verification ────────\n'
printf '  container   : %s\n' "$(podman ps --format '{{.Names}} {{.Image}} {{.Status}}' 2>/dev/null | grep -E "^${CONTAINER} " || echo MISSING)"

TOK="$(cat /var/lib/embernet/auth.token 2>/dev/null || true)"
HEALTH="$(curl -s -m 5 -H "Authorization: Bearer ${TOK}" http://127.0.0.1:8765/api/v1/health 2>/dev/null || true)"
printf '  health      : %s\n' "${HEALTH:-<no response>}"
printf '  identity    : %s\n' "$(readlink -f "${IDENTITY_DIR}/embernet.json" 2>/dev/null || echo none)"
printf '  :%s owner : %s\n' "$FLUX_LOCAL_PORT" \
  "$(ss -lntp 2>/dev/null | grep ":${FLUX_LOCAL_PORT}" | grep -oE 'users:\(\("[^"]+' | cut -d'"' -f2 | head -1 || echo NONE)"
printf '  mesh iface  : %s\n' "$(ip -4 -o addr show embernet0 2>/dev/null | awk '{print $4}' || echo 'embernet0 ABSENT')"
printf '  watchdog    : %s event(s)\n' "$(podman logs --tail 300 "$CONTAINER" 2>&1 | grep -c watchdog_event || echo 0)"

# The gate that actually matters: does the far-end apiserver answer THROUGH the
# overlay? A bound socket proves nothing about fabric authorization.
# 401/403 are success — an unauthenticated probe of a healthy apiserver.
API_CODE="$(curl -sk -m 15 -o /dev/null -w '%{http_code}' "https://127.0.0.1:${FLUX_LOCAL_PORT}/version" 2>/dev/null || echo 000)"
printf '  apiserver   : http_code=%s\n' "$API_CODE"

echo
if [[ "$API_CODE" =~ ^(200|401|403)$ ]] && [[ "$HEALTH" == *1.0.7* ]]; then
  log "OK — ${NODE} on 1.0.7, CP-02 apiserver reachable over Flux (HTTP ${API_CODE})."
  printf '\n  Confirm the join from CP-02:\n      k3s kubectl get node %s -o wide\n\n' "$NODE"
elif [[ "$API_CODE" =~ ^(200|401|403)$ ]]; then
  warn "Apiserver reachable but health did not report 1.0.7. Inspect: podman logs --tail 50 ${CONTAINER}"
else
  warn "Listener bound but the apiserver did NOT answer through the overlay (HTTP '${API_CODE}')."
  warn "Most likely this node's identity is not authorized to dial ${FLUX_SERVICE}."
  warn "Confirm its identity carries roleAttribute 'trane-ut3' at the controller, then:"
  warn "  podman logs --tail 80 ${CONTAINER} | grep -iE 'dial|NO_EDGE_ROUTERS|tunnel failed'"
fi

cat <<EOF

TROUBLESHOOTING
  :${FLUX_LOCAL_PORT} still owned by 'flux'
      the old tunnel unit is still enabled — check BOTH names:
        systemctl status embernet-flux-edge-tunnel.service
        systemctl status container-embernet-flux-edge-tunnel.service

  container exits 127
      a trailing 'daemon' argument crept into the podman run. Remove it.

  permission denied on auth.token
      chown -R 987:987 /var/lib/embernet /var/log/embernet /run/embernet

  node goes NotReady ~1 min after this finishes
      the apiserver redirect is missing:
        nft list table inet embernet_k3s
        systemctl status ${REDIRECT_UNIT}

ROLLBACK
  systemctl disable --now ${UNIT} ${REDIRECT_UNIT}
  nft delete table inet embernet_k3s 2>/dev/null
  cp ${BK}/embernet-flux-edge-tunnel.service /etc/systemd/system/ 2>/dev/null
  systemctl daemon-reload && systemctl enable --now embernet-flux-edge-tunnel.service
  podman rm -f ${CONTAINER}
$( [[ "$PREV_IMG" != "none" ]] && echo "  # previous endpoint image: ${PREV_IMG}" )
EOF
