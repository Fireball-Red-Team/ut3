#!/bin/bash
# =============================================================
# SCORCHED EARTH TEARDOWN — Embernode-UT3-CP01
# Run as root: sudo bash teardown-ut3-cp01.sh
#
# This does NOT assume deploy-ut3-cp01.sh was used.
# It discovers and removes whatever is actually on the box:
#   - K3s (any install variant)
#   - Ignition (container or native)
#   - PostgreSQL / MySQL / any DB containers
#   - LXC / LXD containers (ALL of them)
#   - OpenVPN server(s)
#   - WireGuard interfaces
#   - Docker containers (if Docker somehow got on here)
#   - Podman containers
#   - Systemd services that look like they don't belong
# =============================================================

set -euo pipefail

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
CYN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GRN}[✓]${NC} $*"; }
warn() { echo -e "${YLW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
hdr()  { echo -e "\n${CYN}=== $* ===${NC}"; }

# =============================================================
# SAFETY CHECK
# =============================================================

if [[ "$EUID" -ne 0 ]]; then
  err "Run as root: sudo bash teardown-ut3-cp01.sh"
  exit 1
fi

echo ""
echo "============================================================"
echo "  SCORCHED EARTH TEARDOWN"
echo "  This will DISCOVER and DESTROY everything on this node."
echo "============================================================"
echo ""

# =============================================================
# PHASE 1: DISCOVERY — Show what's here before touching anything
# =============================================================

hdr "PHASE 1: DISCOVERY"

echo ""
echo "--- Host identity ---"
# Authoritative answer to "what version of Ubuntu is Trane actually
# running?" — discovered live from the box, not assumed from a deploy
# script's comment block. PRETTY_NAME from os-release is the canonical
# Ubuntu display string ("Ubuntu 22.04.5 LTS", "Ubuntu 24.04.1 LTS",
# etc.); the rest gives us kernel + arch + hostname for context.
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "  OS:            ${PRETTY_NAME:-unknown}"
  echo "  ID / VERSION:  ${ID:-?} ${VERSION_ID:-?} (${VERSION_CODENAME:-?})"
else
  echo "  /etc/os-release not present"
fi
if command -v lsb_release &>/dev/null; then
  echo "  lsb_release:   $(lsb_release -ds 2>/dev/null || echo 'failed')"
fi
echo "  Kernel:        $(uname -srm)"
echo "  Hostname:      $(hostnamectl --static 2>/dev/null || hostname)"
echo "  Uptime:        $(uptime -p 2>/dev/null || uptime)"

echo ""
echo "--- Running processes (filtered) ---"
ps aux --no-headers | grep -iE 'ignition|postgres|mysql|mariadb|openvpn|wireguard|k3s|rancher|codesys|ziti|lxc|lxd|docker|podman|nginx|apache|grafana|influx|mosquitto|node_exporter' | grep -v grep || echo "  (none matched)"

echo ""
echo "--- Listening ports ---"
ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "  (ss/netstat not available)"

echo ""
echo "--- Systemd services (non-default, enabled) ---"
systemctl list-unit-files --state=enabled --type=service --no-pager 2>/dev/null | grep -ivE 'accounts-daemon|apparmor|cron|dbus|getty|grub|keyboard|networking|rsyslog|serial|ssh|sshd|snap|systemd|udev|ufw|unattended|cloud|multipathd|pollinate|blk-availability|console-setup|finalrd|fwupd|irqbalance|lvm2|open-iscsi|packagekit|plymouth|power|thermald|ua-|udisk|ModemManager|NetworkManager' || echo "  (none)"

echo ""
echo "--- LXC/LXD containers ---"
if command -v lxc &>/dev/null; then
  lxc list 2>/dev/null || echo "  lxc list failed"
elif command -v lxc-ls &>/dev/null; then
  echo "  LXC containers: $(lxc-ls -f 2>/dev/null || echo 'failed')"
else
  echo "  LXC/LXD not installed"
fi

echo ""
echo "--- Docker containers ---"
if command -v docker &>/dev/null; then
  docker ps -a 2>/dev/null || echo "  docker ps failed"
else
  echo "  Docker not installed"
fi

echo ""
echo "--- Podman containers ---"
if command -v podman &>/dev/null; then
  podman ps -a 2>/dev/null || echo "  podman ps failed"
else
  echo "  Podman not installed"
fi

echo ""
echo "--- Network interfaces (VPN tunnels) ---"
ip -br link show 2>/dev/null | grep -iE 'wg|tun|tap|ovpn|ziti' || echo "  (no VPN interfaces found)"

echo ""
echo "--- WireGuard status ---"
wg show 2>/dev/null || echo "  (no WireGuard interfaces active)"

echo ""
echo "--- /opt contents ---"
ls -la /opt/ 2>/dev/null || echo "  (empty or missing)"

echo ""
echo "--- /etc/openvpn ---"
ls -la /etc/openvpn/ 2>/dev/null || echo "  (not present)"

echo ""
echo "--- K3s check ---"
which k3s 2>/dev/null && echo "  K3s binary found" || echo "  K3s not found"
ls /var/lib/rancher/ 2>/dev/null && echo "  /var/lib/rancher exists" || true
ls /etc/rancher/ 2>/dev/null && echo "  /etc/rancher exists" || true

echo ""
echo "============================================================"
echo "  DISCOVERY COMPLETE — Review the above."
echo "============================================================"
echo ""
read -p "Proceed with FULL TEARDOWN? Type 'BURN' to confirm: " CONFIRM
if [[ "${CONFIRM}" != "BURN" ]]; then
  echo "Aborted. Nothing was changed."
  exit 0
fi

# =============================================================
# PHASE 2: TEARDOWN — Nuke everything
# =============================================================

hdr "PHASE 2: TEARDOWN"

# ----- K3s -----
hdr "K3s / Kubernetes"
if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
  log "Found k3s-uninstall.sh — running it..."
  /usr/local/bin/k3s-uninstall.sh
  log "K3s server uninstalled."
elif [[ -f /usr/local/bin/k3s-agent-uninstall.sh ]]; then
  log "Found k3s-agent-uninstall.sh — running it..."
  /usr/local/bin/k3s-agent-uninstall.sh
  log "K3s agent uninstalled."
else
  warn "No K3s uninstall script. Manual cleanup..."
  for svc in k3s k3s-agent k3s-embernet-server; do
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
  done
  rm -f /etc/systemd/system/k3s*.service
  rm -f /usr/local/bin/k3s /usr/local/bin/kubectl /usr/local/bin/crictl /usr/local/bin/ctr
  rm -rf /var/lib/rancher
  rm -rf /etc/rancher
  systemctl daemon-reload
  log "K3s manually cleaned."
fi
# Clean up CNI and flannel leftovers
rm -rf /var/lib/cni 2>/dev/null || true
rm -rf /etc/cni 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true
ip link delete cni0 2>/dev/null || true

# ----- LXC / LXD CONTAINERS -----
hdr "LXC / LXD Containers"
if command -v lxc &>/dev/null; then
  LXC_CONTAINERS=$(lxc list --format csv -c n 2>/dev/null || true)
  if [[ -n "${LXC_CONTAINERS}" ]]; then
    echo "${LXC_CONTAINERS}" | while read -r cname; do
      warn "Destroying LXC container: ${cname}"
      lxc stop "${cname}" --force 2>/dev/null || true
      lxc delete "${cname}" --force 2>/dev/null || true
    done
    log "All LXC (lxd) containers destroyed."
  else
    log "No LXC (lxd) containers."
  fi
  # Clean storage pools
  for pool in $(lxc storage list --format csv 2>/dev/null | cut -d, -f1); do
    warn "Deleting LXC storage pool: ${pool}"
    lxc storage delete "${pool}" 2>/dev/null || true
  done
  # Clean profiles (except default)
  for prof in $(lxc profile list --format csv 2>/dev/null | cut -d, -f1 | grep -v default); do
    warn "Deleting LXC profile: ${prof}"
    lxc profile delete "${prof}" 2>/dev/null || true
  done
  # Clean networks
  for net in $(lxc network list --format csv 2>/dev/null | cut -d, -f1); do
    warn "Deleting LXC network: ${net}"
    lxc network delete "${net}" 2>/dev/null || true
  done
elif command -v lxc-ls &>/dev/null; then
  LXC_CONTAINERS=$(lxc-ls 2>/dev/null || true)
  if [[ -n "${LXC_CONTAINERS}" ]]; then
    for cname in ${LXC_CONTAINERS}; do
      warn "Destroying LXC container: ${cname}"
      lxc-stop -n "${cname}" -k 2>/dev/null || true
      lxc-destroy -n "${cname}" -f 2>/dev/null || true
    done
    log "All LXC containers destroyed."
  else
    log "No LXC containers."
  fi
else
  log "LXC/LXD not installed."
fi

# ----- DOCKER CONTAINERS -----
hdr "Docker"
if command -v docker &>/dev/null; then
  warn "Docker found — stopping and removing ALL containers..."
  docker stop $(docker ps -aq) 2>/dev/null || true
  docker rm -f $(docker ps -aq) 2>/dev/null || true
  docker system prune -af --volumes 2>/dev/null || true
  log "Docker cleaned."
  warn "Removing Docker itself..."
  systemctl stop docker 2>/dev/null || true
  systemctl stop docker.socket 2>/dev/null || true
  systemctl disable docker 2>/dev/null || true
  systemctl disable docker.socket 2>/dev/null || true
  apt-get remove -y docker docker-engine docker.io containerd runc docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
  rm -rf /var/lib/docker
  rm -rf /etc/docker
  log "Docker uninstalled."
else
  log "Docker not installed."
fi

# ----- PODMAN CONTAINERS -----
hdr "Podman"
if command -v podman &>/dev/null; then
  warn "Stopping ALL Podman containers..."
  podman stop -a 2>/dev/null || true
  podman rm -af 2>/dev/null || true
  podman rmi -af 2>/dev/null || true
  podman volume prune -f 2>/dev/null || true
  podman system prune -af 2>/dev/null || true
  log "Podman cleaned."
else
  log "Podman not installed."
fi

# ----- IGNITION (native install, not just container) -----
hdr "Ignition (native install check)"
if [[ -d /usr/local/bin/ignition ]] || [[ -d /opt/ignition ]] || [[ -d /var/lib/ignition ]]; then
  warn "Found native Ignition install directories..."
  # Stop the service if it exists
  systemctl stop ignition 2>/dev/null || true
  systemctl disable ignition 2>/dev/null || true
  rm -f /etc/systemd/system/ignition.service 2>/dev/null || true
  rm -rf /usr/local/bin/ignition 2>/dev/null || true
  rm -rf /opt/ignition 2>/dev/null || true
  rm -rf /var/lib/ignition 2>/dev/null || true
  systemctl daemon-reload
  log "Native Ignition removed."
else
  log "No native Ignition install found (may have been in a container — already handled)."
fi

# ----- DATABASES (native) -----
hdr "Databases (native install check)"
for db_svc in postgresql mysql mariadb mongod influxdb; do
  if systemctl is-active "${db_svc}" &>/dev/null || systemctl is-enabled "${db_svc}" &>/dev/null; then
    warn "Found native ${db_svc} service — stopping and disabling..."
    systemctl stop "${db_svc}" 2>/dev/null || true
    systemctl disable "${db_svc}" 2>/dev/null || true
    log "${db_svc} stopped and disabled."
  fi
done

# ----- OPENVPN -----
hdr "OpenVPN"
# Check for any openvpn service (could be openvpn@server, openvpn-server@server, etc.)
OVPN_SERVICES=$(systemctl list-units --type=service --all --no-pager 2>/dev/null | grep -i openvpn | awk '{print $1}' || true)
if [[ -n "${OVPN_SERVICES}" ]]; then
  echo "${OVPN_SERVICES}" | while read -r svc; do
    warn "Stopping OpenVPN service: ${svc}"
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
  done
fi
# Check for openvpn process directly
pkill -9 openvpn 2>/dev/null || true
# Remove config and package
rm -rf /etc/openvpn 2>/dev/null || true
apt-get remove -y openvpn 2>/dev/null || true
log "OpenVPN removed (if present)."

# ----- WIREGUARD -----
hdr "WireGuard"
# Find and tear down ALL wg interfaces
for iface in $(ip -br link show 2>/dev/null | awk '{print $1}' | grep -i '^wg'); do
  warn "Bringing down WireGuard interface: ${iface}"
  wg-quick down "${iface}" 2>/dev/null || ip link delete "${iface}" 2>/dev/null || true
done
# Stop any wg-quick or FluxNetworkService systemd units
WG_SERVICES=$(systemctl list-units --type=service --all --no-pager 2>/dev/null | grep -iE 'wg-quick|wireguard|FluxNetwork' | awk '{print $1}' || true)
if [[ -n "${WG_SERVICES}" ]]; then
  echo "${WG_SERVICES}" | while read -r svc; do
    warn "Disabling WireGuard service: ${svc}"
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
  done
fi
rm -f /etc/systemd/system/FluxNetworkService.service 2>/dev/null || true
rm -rf /etc/wireguard 2>/dev/null || true
systemctl daemon-reload
log "WireGuard removed."

# ----- OPENZITI / ZITI -----
hdr "OpenZiti / Flux"
systemctl stop ziti-tunnel 2>/dev/null || true
systemctl stop ziti-edge-tunnel 2>/dev/null || true
systemctl disable ziti-tunnel 2>/dev/null || true
systemctl disable ziti-edge-tunnel 2>/dev/null || true
rm -f /etc/systemd/system/ziti*.service 2>/dev/null || true
pkill -9 ziti 2>/dev/null || true
apt-get remove -y openziti 2>/dev/null || true
rm -rf /etc/embernet/ziti 2>/dev/null || true
systemctl daemon-reload
log "OpenZiti / Flux removed."

# ----- CODESYS -----
hdr "Codesys"
if systemctl is-active codesyscontrol &>/dev/null || [[ -d /opt/codesys ]]; then
  systemctl stop codesyscontrol 2>/dev/null || true
  systemctl disable codesyscontrol 2>/dev/null || true
  rm -rf /opt/codesys 2>/dev/null || true
  rm -rf /var/opt/codesys 2>/dev/null || true
  rm -f /etc/systemd/system/codesyscontrol.service 2>/dev/null || true
  systemctl daemon-reload
  log "Codesys removed."
else
  log "Codesys not found."
fi

# ----- OTHER COMMON INDUSTRIAL JUNK -----
hdr "Other services check"
for svc in grafana-server prometheus node_exporter mosquitto nodered telegraf; do
  if systemctl is-active "${svc}" &>/dev/null || systemctl is-enabled "${svc}" &>/dev/null; then
    warn "Found ${svc} — stopping and disabling..."
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
    log "${svc} stopped."
  fi
done

# ----- CLEANUP DATA DIRECTORIES -----
hdr "Data directory cleanup"
for d in /opt/embernet /etc/embernet /opt/ignition /opt/codesys /var/opt/codesys; do
  if [[ -d "${d}" ]]; then
    warn "Removing ${d}"
    rm -rf "${d}"
  fi
done
log "Data directories cleaned."

# ----- APT AUTOREMOVE -----
hdr "Package cleanup"
apt-get autoremove -y 2>/dev/null || true
apt-get autoclean 2>/dev/null || true
log "Package cache cleaned."

# =============================================================
# PHASE 3: POST-TEARDOWN VERIFICATION
# =============================================================

hdr "PHASE 3: VERIFICATION"

echo ""
echo "--- Remaining listening ports ---"
ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || true

echo ""
echo "--- Remaining non-default services ---"
systemctl list-unit-files --state=enabled --type=service --no-pager 2>/dev/null | grep -ivE 'accounts-daemon|apparmor|cron|dbus|getty|grub|keyboard|networking|rsyslog|serial|ssh|sshd|snap|systemd|udev|ufw|unattended|cloud|multipathd|pollinate|blk-availability|console-setup|finalrd|fwupd|irqbalance|lvm2|open-iscsi|packagekit|plymouth|power|thermald|ua-|udisk|ModemManager|NetworkManager' || echo "  (none — clean)"

echo ""
echo "--- Remaining containers ---"
lxc list 2>/dev/null || lxc-ls -f 2>/dev/null || true
docker ps -a 2>/dev/null || true
podman ps -a 2>/dev/null || true

echo ""
echo "============================================================"
echo "  TEARDOWN COMPLETE — NODE IS CLEAN"
echo "============================================================"
echo ""
echo "  The box should be bare Ubuntu now."
echo "  Run 'reboot' if you want a clean slate before redeploying."
echo "============================================================"
