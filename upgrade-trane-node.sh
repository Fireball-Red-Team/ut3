#!/usr/bin/env bash
# =============================================================================
# upgrade-trane-node.sh — Trane UT3 node -> embernetlite v1.0.7, k3s over Flux
#
# Run ON the target node as root:
#     sudo bash upgrade-trane-node.sh
#
# For: trane-ut3-cp-01, cp-03, en-0001, en-0002, en-0003
#      (k3s AGENTS that join CP-02)
# NOT for: trane-ut3-cp-02 (k3s server, host mode — already done, v1.0.7)
#          ut3-ignition / ut3-cp-em-0001 (Azure — already done, v1.0.7)
#
# WHAT THIS REPLACES
#   deploy-ut3-en03.sh stands up a SEPARATE flux-edge-tunnel container in
#   `proxy trane-ut3-k3s-api:6443` mode, then iptables-REDIRECTs CP-02's
#   apiserver IP into it. Since v1.0.6 embernetlite does that itself
#   (EMBERNET_FLUX_TUNNEL_PROXY). This script retires that container and moves
#   the k3s API path inside the endpoint.
#
# HONESTY NOTE — READ THIS
#   This script has NEVER been run end to end. It could not be: all five
#   target nodes are NotReady with no WireGuard presence.
#   Every INDIVIDUAL step below was executed and verified by hand today on
#   trane-ut3-cp-02 and the Azure VM, and each one exists because something
#   failed first. Their ASSEMBLY is untested.
#   Run it on trane-ut3-cp-03 before a node that matters.
#
# ROLLBACK
#   Prints an exact rollback command at the end. The old tunnel unit is backed
#   up to /root/embernet-migration-backup/ and only DISABLED, never deleted.
# =============================================================================
set -euo pipefail

# ---- pinned values. Do not guess these. -------------------------------------
EMBERNET_IMAGE="ghcr.io/embernet-ai/embernetlite:1.0.7"
FLUX_SERVICE="trane-ut3-k3s-api"     # Ziti service that fronts CP-02's apiserver
FLUX_LOCAL_PORT="6443"               # local listener the k3s agent dials
SEED_IP="100.64.1.3"                 # CP-02's ADVERTISED apiserver (WG IP)
CONTAINER="systemd-embernet"
UNIT="embernet.service"
REDIRECT_UNIT="embernet-k3s-redirect.service"
BK="/root/embernet-migration-backup"
IDENTITY_DIR="/var/lib/embernet/identity"
FLUX_VOL="/var/lib/containers/storage/volumes/embernet-flux-identity/_data"

log()  { echo -e "[+] $*"; }
warn() { echo -e "[!] $*" >&2; }
fail() { echo -e "[x] $*" >&2; exit 1; }

# =============================================================================
# 1. PREFLIGHT
# =============================================================================
[[ "$EUID" -eq 0 ]] || fail "run as root: sudo bash $0"
command -v podman >/dev/null || fail "podman not found"
command -v nft    >/dev/null || fail "nft not found (nftables required)"

NODE="$(hostname)"
log "node=${NODE}  image=${EMBERNET_IMAGE}"
log "podman $(podman --version 2>/dev/null | awk '{print $3}')"

mkdir -p "$BK"
cp -a "$IDENTITY_DIR" "$BK/identity-backup-$(date +%s)" 2>/dev/null || true
podman inspect embernet-flux-edge-tunnel > "$BK/flux-tunnel-inspect.json" 2>/dev/null || true
podman inspect "$CONTAINER"              > "$BK/embernet-inspect.json"    2>/dev/null || true
PREV_IMG="$(podman inspect "$CONTAINER" --format '{{.ImageName}}' 2>/dev/null || echo none)"
log "current endpoint image: ${PREV_IMG}"

# Pull BEFORE tearing anything down, so a registry failure changes nothing.
log "pulling ${EMBERNET_IMAGE}"
podman pull "$EMBERNET_IMAGE" >/dev/null || fail "pull failed — check egress to ghcr.io. Nothing changed."

# =============================================================================
# 2. IDENTITY HANDOVER
#
# The node's OWN Trane-UT3-* identity has no role attributes and binds NOTHING.
# The flux-edge-tunnel volume holds the Embernode-UT3-* identity that carries
# this node's service grants. Hand that one to embernetlite or the binds are
# lost. Filename differs per node (Embernode-UT3-CP02.json vs
# Embernode-UT3-CP-EM-0001.json) — glob it, never hardcode.
# =============================================================================
SRC="$(ls "${FLUX_VOL}"/Embernode-UT3-*.json 2>/dev/null | head -1 || true)"
if [[ -n "$SRC" ]]; then
  log "identity handover: $(basename "$SRC")"
  install -m 0600 "$SRC" "${IDENTITY_DIR}/$(basename "$SRC")"
  ln -sfn "$(basename "$SRC")" "${IDENTITY_DIR}/embernet.json"
  log "embernet.json -> $(readlink "${IDENTITY_DIR}/embernet.json")"
else
  warn "no Embernode-UT3-*.json in ${FLUX_VOL}"
  warn "leaving the existing identity in place: $(readlink -f "${IDENTITY_DIR}/embernet.json" 2>/dev/null || echo none)"
  warn "if this node ends up hosting nothing, that is why — check the volume."
fi

# Container runs as uid 987. A node migrated off the .deb has these owned by
# the HOST embernet user (997) and the daemon dies with
#   read token at /var/lib/embernet/auth.token: permission denied
# chown -R, not just the dirs: the files already exist.
chown -R 987:987 /var/lib/embernet /var/log/embernet /run/embernet 2>/dev/null || true

# =============================================================================
# 3. RETIRE THE OLD FLUX TUNNEL CONTAINER
#
# Two unit names exist in the field. Disabling only one leaves the container
# running and holding :6443, and the endpoint then cannot bind its proxy.
# =============================================================================
for u in embernet-flux-edge-tunnel.service container-embernet-flux-edge-tunnel.service; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${u}"; then
    log "retiring ${u}"
    cp "/etc/systemd/system/${u}" "$BK/" 2>/dev/null || true
    systemctl disable --now "$u" >/dev/null 2>&1 || true
  fi
done
podman rm -f embernet-flux-edge-tunnel >/dev/null 2>&1 || true
systemctl daemon-reload

if ss -lnt 2>/dev/null | grep -q ":${FLUX_LOCAL_PORT} "; then
  warn ":${FLUX_LOCAL_PORT} is still held by:"
  ss -lntp 2>/dev/null | grep ":${FLUX_LOCAL_PORT} " >&2 || true
  fail "port still in use — find and stop that unit, then re-run"
fi
log ":${FLUX_LOCAL_PORT} free"

# =============================================================================
# 4. RUN EMBERNETLITE IN PROXY MODE
#
# NO trailing 'daemon'. The image declares
#   ENTRYPOINT ["/sbin/tini","--"]  CMD ["/usr/bin/embernetlite","daemon"]
# Appending 'daemon' overrides CMD, tini execs a binary called "daemon" and the
# container exits 127.
#
# CAP_NET_BIND_SERVICE is required for the tunneler's DNS resolver in intercept
# mode. Proxy mode does not use it, but it is granted for consistency and costs
# nothing.
# =============================================================================
log "starting ${CONTAINER} (proxy ${FLUX_SERVICE}:${FLUX_LOCAL_PORT})"
podman rm -f "$CONTAINER" embernet >/dev/null 2>&1 || true
podman run -d \
  --name "$CONTAINER" \
  --restart=always \
  --network=host \
  --cap-add=CAP_NET_ADMIN \
  --cap-add=CAP_NET_RAW \
  --cap-add=CAP_NET_BIND_SERVICE \
  --device=/dev/net/tun \
  -v /etc/embernet:/etc/embernet:ro,Z \
  -v /etc/os-release:/etc/os-release:ro,Z \
  -v /var/lib/embernet:/var/lib/embernet:Z \
  -v /var/log/embernet:/var/log/embernet:Z \
  -v /run/embernet:/run/embernet:Z \
  -e "EMBERNET_FLUX_TUNNEL_PROXY=${FLUX_SERVICE}:${FLUX_LOCAL_PORT}" \
  "$EMBERNET_IMAGE" >/dev/null \
  || fail "podman run failed — inspect: podman logs ${CONTAINER}"

# =============================================================================
# 5. SYSTEMD UNIT
#
# `podman generate systemd`, NOT Quadlet. These nodes are Ubuntu 22.04 with
# podman 3.4.4; Quadlet needs >= 4.4 and silently produces no unit — the
# failure reads "Unit embernet.service not found".
# --container-prefix='' --separator='' gives embernet.service, not
# container-embernet.service.
# =============================================================================
sleep 8
log "generating ${UNIT}"
( cd /etc/systemd/system && podman generate systemd \
    --name "$CONTAINER" --new --restart-policy=always \
    --container-prefix='' --separator='' > "$UNIT" ) \
  || fail "podman generate systemd failed"
systemctl daemon-reload
systemctl enable "$UNIT" >/dev/null 2>&1 || true

# =============================================================================
# 6. WAIT FOR THE PROXY LISTENER
# =============================================================================
log "waiting for :${FLUX_LOCAL_PORT} to bind..."
w=0
while (( w < 150 )); do
  ss -lnt 2>/dev/null | grep -q ":${FLUX_LOCAL_PORT} " && break
  sleep 3; w=$((w+3))
done
ss -lnt 2>/dev/null | grep -q ":${FLUX_LOCAL_PORT} " \
  || fail "proxy never bound :${FLUX_LOCAL_PORT}. Inspect: podman logs --tail 50 ${CONTAINER}"
log "listener up after ${w}s"

# =============================================================================
# 7. APISERVER REDIRECT, REBOOT-DURABLE
#
# k3s agents auto-discover CP-02's ADVERTISED apiserver (${SEED_IP}:6443) and
# switch their load balancer to dial it DIRECTLY — bypassing K3S_URL. Over
# WireGuard that is exactly what we are moving away from, so send it to the
# local Flux proxy instead.
#
# In OUR nft table, not system iptables, so FACILITY_SAFETY.md §1.3 (never
# touch system-managed tables) and §1.7 (`nft delete table` is the whole
# teardown) still hold. PartOf=embernet.service so it lifts and drops with the
# endpoint.
#
# NOTE: nft comments must not contain ':' unless quoted — bash strips the
# quotes before nft sees them. Hence the hyphenated comment below.
# =============================================================================
mkdir -p /etc/embernet
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
  || warn "${REDIRECT_UNIT} failed to start — k3s may dial ${SEED_IP} directly"
nft list table inet embernet_k3s >/dev/null 2>&1 \
  && log "apiserver redirect installed: ${SEED_IP}:${FLUX_LOCAL_PORT} -> local Flux proxy" \
  || warn "redirect table not present — check: nft list table inet embernet_k3s"

# Nudge the agent onto the new path.
if systemctl list-unit-files 2>/dev/null | grep -qE '^k3s-(agent|embernet-agent)\.service'; then
  K3SU="$(systemctl list-unit-files 2>/dev/null | grep -oE '^k3s-[a-z-]*\.service' | head -1)"
  log "restarting ${K3SU}"
  systemctl restart "$K3SU" || warn "${K3SU} restart failed — check journalctl -u ${K3SU}"
fi

# =============================================================================
# 8. VERIFY
# =============================================================================
echo
log "──────── verification ────────"
sleep 20
printf '  container   : %s\n' "$(podman ps --filter "name=${CONTAINER}" --format '{{.Image}} {{.Status}}' 2>/dev/null || echo MISSING)"

TOK="$(cat /var/lib/embernet/auth.token 2>/dev/null || true)"
HEALTH="$(curl -s -m 5 -H "Authorization: Bearer ${TOK}" http://127.0.0.1:8765/api/v1/health 2>/dev/null || true)"
printf '  health      : %s\n' "${HEALTH:-<no response>}"

printf '  identity    : %s\n' "$(readlink -f "${IDENTITY_DIR}/embernet.json" 2>/dev/null || echo none)"
printf '  :%s owner : %s\n' "$FLUX_LOCAL_PORT" "$(ss -lntp 2>/dev/null | grep ":${FLUX_LOCAL_PORT} " | grep -oE 'users:\(\("[^"]+' | cut -d'"' -f2 | head -1 || echo NONE)"

API_CODE="$(curl -sk -m 15 -o /dev/null -w '%{http_code}' "https://127.0.0.1:${FLUX_LOCAL_PORT}/version" 2>/dev/null || echo 000)"
printf '  apiserver   : http_code=%s %s\n' "$API_CODE" \
  "$( [[ "$API_CODE" =~ ^(200|401|403)$ ]] && echo '(reachable through Flux)' || echo '(NOT reachable)' )"

printf '  hosting     : %s service(s)\n' "$(podman logs --tail 300 "$CONTAINER" 2>&1 | grep -c 'hosting service, waiting' || echo 0)"
printf '  watchdog    : %s event(s)\n' "$(podman logs --tail 300 "$CONTAINER" 2>&1 | grep -c 'watchdog_event' || echo 0)"

echo
case "$HEALTH" in
  *1.0.7*) log "OK — ${NODE} on 1.0.7, k3s API through Flux" ;;
  *)       warn "health did not report 1.0.7. Inspect: podman logs --tail 50 ${CONTAINER}" ;;
esac

cat <<EOF

TROUBLESHOOTING
  :${FLUX_LOCAL_PORT} still owned by 'flux'
      the old tunnel unit is still enabled — check BOTH names:
        systemctl status embernet-flux-edge-tunnel.service
        systemctl status container-embernet-flux-edge-tunnel.service

  listener appears then dies after ~1 min, watchdog events > 0
      the watchdog is escalating to rollback because the gateway drops ICMP.
      CP-02 does not need this, but if it happens here, add to the podman run:
        -e EMBERNET_SAFETY_WATCHDOG_DISABLED=1

  container exits 127
      a trailing 'daemon' argument crept into the podman run. Remove it.

  permission denied on auth.token
      re-run:  chown -R 987:987 /var/lib/embernet /var/log/embernet /run/embernet

ROLLBACK
  systemctl disable --now ${UNIT} ${REDIRECT_UNIT}
  nft delete table inet embernet_k3s 2>/dev/null
  cp ${BK}/embernet-flux-edge-tunnel.service /etc/systemd/system/ 2>/dev/null
  systemctl daemon-reload && systemctl enable --now embernet-flux-edge-tunnel.service
  podman rm -f ${CONTAINER}
$( [[ "$PREV_IMG" != "none" ]] && echo "  # previous endpoint image was: ${PREV_IMG}" )
EOF
