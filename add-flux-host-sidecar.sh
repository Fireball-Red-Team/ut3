#!/usr/bin/env bash
# =============================================================
# add-flux-host-sidecar.sh — IN-PLACE, per box. No deploy-script rerun.
#
# Adds a SECOND ziti-edge-tunnel container in `run-host` mode so the node
# HOSTS the Flux GUI services The Reconciler provisions (so the dashboard can
# reach this node's App-Store apps over the overlay when WireGuard can't).
#
# `run-host` is host-ONLY: it binds services the identity is allowed to host,
# and does NOT intercept/tproxy anything — so it CANNOT disturb the existing
# apiserver `proxy` sidecar or the k3s join. It reuses the node's existing
# Embernode identity + volume (read-only), auto-detected from the running
# edge-tunnel unit.
#
#   sudo bash ./add-flux-host-sidecar.sh
#
# Prereqs (one-time, central): the node's Embernode identity carries the
# `#site-<site>` role and a `<site>-hosts-services` bind policy exists
# (the-reconciler `setup_site`), and The Reconciler is creating the services.
# =============================================================
set -euo pipefail

SRC_UNIT="/etc/systemd/system/embernet-flux-edge-tunnel.service"
HOST_UNIT="/etc/systemd/system/embernet-flux-host.service"
CTRL_URL="https://flux.embernet.ai:443"

[[ "$EUID" -eq 0 ]] || { echo "[x] run as root: sudo bash $0" >&2; exit 1; }
command -v podman >/dev/null || { echo "[x] podman not found" >&2; exit 1; }
[[ -f "$SRC_UNIT" ]] || { echo "[x] $SRC_UNIT not found — is the edge tunnel deployed on this box?" >&2; exit 1; }

# --- Auto-detect the node's identity + tunnel image from the running unit ---
FLUX_IDENTITY_NAME="$(grep -oE 'ZITI_IDENTITY_BASENAME=[^ ]+' "$SRC_UNIT" | head -1 | cut -d= -f2)"
FLUX_TUNNEL_IMAGE="$(grep -oE 'ghcr\.io/[^ ]*flux-edge-tunnel[^ ]*' "$SRC_UNIT" | head -1)"
[[ -n "$FLUX_IDENTITY_NAME" ]] || { echo "[x] could not detect ZITI_IDENTITY_BASENAME from $SRC_UNIT" >&2; exit 1; }
[[ -n "$FLUX_TUNNEL_IMAGE" ]]  || { echo "[x] could not detect flux-edge-tunnel image from $SRC_UNIT" >&2; exit 1; }
podman volume inspect embernet-flux-identity >/dev/null 2>&1 || { echo "[x] embernet-flux-identity volume missing" >&2; exit 1; }

echo "[+] identity=${FLUX_IDENTITY_NAME}  image=${FLUX_TUNNEL_IMAGE}"
podman pull "${FLUX_TUNNEL_IMAGE}" 2>/dev/null || true

# --- Write the host-only unit (mirrors the edge-tunnel unit; mode=run-host) ---
cat > "$HOST_UNIT" <<UNIT
[Unit]
Description=Embernet Flux Host Tunnel (hosts GUI services over Flux; host-only, no tproxy)
Wants=network-online.target
After=network-online.target
RequiresMountsFor=%t/containers
[Service]
Environment=PODMAN_SYSTEMD_UNIT=%n
Restart=always
TimeoutStopSec=70
ExecStartPre=/bin/rm -f %t/%n.ctr-id
ExecStart=/usr/bin/podman run --cidfile=%t/%n.ctr-id --cgroups=no-conmon --rm --sdnotify=conmon --replace -d --name embernet-flux-host --network=host --privileged -v embernet-flux-identity:/ziti-identity -e ZITI_IDENTITY_DIR=/ziti-identity -e ZITI_IDENTITY_BASENAME=${FLUX_IDENTITY_NAME} -e ZITI_CONTROLLER_URL=${CTRL_URL} -e PFXLOG_NO_JSON=true ${FLUX_TUNNEL_IMAGE} run-host
ExecStop=/usr/bin/podman stop --ignore --cidfile=%t/%n.ctr-id
ExecStopPost=/usr/bin/podman rm -f --ignore --cidfile=%t/%n.ctr-id
Type=notify
NotifyAccess=all
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now embernet-flux-host.service

echo "[+] Waiting for the host tunnel container to come up..."
w=0
while (( w < 60 )); do
  podman ps --format '{{.Names}}' 2>/dev/null | grep -qx embernet-flux-host && break
  sleep 3; w=$((w+3))
done
if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx embernet-flux-host; then
  echo "[+] embernet-flux-host is running (run-host). It will host every #gui-services"
  echo "    service this identity may bind. Existing apiserver proxy + k3s untouched."
  echo "    Inspect: podman logs embernet-flux-host | tail; systemctl status embernet-flux-host"
else
  echo "[!] host tunnel did not report running — inspect: podman logs embernet-flux-host" >&2
  exit 1
fi
