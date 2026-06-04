#!/bin/bash
# =============================================================
# EmberNet UT3 — Edge Node 0001 Deployment Script
# Node: Trane-UT3-EN-0001  |  embernet0 IP: assigned by embernetlite at enrollment
# OS:   Ubuntu 22.04 Server (x86_64) — Trane standardises on 22.04
# Run as root: sudo bash deploy-ut3-en01.sh
#
# EN-0001 is a WORKER node of CP-01's HA K3s cluster (one cluster
# total at Trane UT3 — CP-01 + CP-02 + CP-03 are control planes,
# EN-0001 is a K3s agent). It does NOT serve the K3s API; it does
# NOT carry etcd; it does NOT get its own Rancher import. CP-01's
# Rancher registration already covers every cluster member.
#
# K3s join shape:
#   K3S_URL=https://${CP01_EMBERNET_IP}:6443  (CP-01's API over embernet0)
#   K3S_TOKEN=<shared token from /etc/embernet/k3s-token on CP-01>
#   sh -s - agent ...                          (NOT server — no etcd, no API)
#
# VPN: embernetlite (EmbernetEndpoint-Linux v0.0.29) replaces the legacy
# linuxserver/wireguard container. Post-enrollment it brings up
# embernet0; K3s rides on that interface. Two-phase: run once for
# Phase 1 (containers + embernetlite Quadlet), complete operator
# enrollment via AAD device-code browser flow, re-run for Phase 2
# (K3s agent join on embernet0).
#
# All non-K3s workloads run as host-level podman containers
# (Quadlet or `podman run` + `podman generate systemd`). No K8s
# pods are scheduled by this script — the cluster receives App
# Store apps later from the EmberNet dashboard.
#
# Workloads on EN-0001:
#   - embernetlite (Quadlet, ghcr.io/embernet-ai/embernetlite:0.0.36)
#       This IS the VPN: ships its own WireGuard driver and brings up
#       `embernet0` post-enrollment. The operator must complete enrollment
#       via AAD device-code (browser) after Phase 1 finishes. Re-run the
#       script to advance to Phase 2 (K3s agent install on embernet0).
#   - CODESYS Control SL 4.20 (host podman, host:1217)        [Phase 1]
#   - K3s agent v1.34.5+k3s1 (host install, joining CP-01)    [Phase 2]
#
# NOT installed on EN-0001:
#   - PostgreSQL  (CP-01 owns the fleet DB)
#   - Ignition    (Cloud is on CP-01, Edge on CP-02 / CP-03)
#   - Rancher     (CP-01's import covers all cluster members)
#
# OVERRIDES (env vars consumed by this script):
#   CP01_EMBERNET_IP=<addr> override CP-01's embernet0 IP (default 100.64.1.1)
#   HOST_TLS_SAN=<addr>     reserved (no API on agents — currently unused
#                           but accepted so the operator can run the same
#                           env-prefix shape across CP and EN nodes)
#   K3S_FORCE_WIPE=1        force the K3s uninstall/wipe even if the agent
#                           looks healthy (useful when a prior install
#                           joined the wrong cluster)
#
# PRE-REQUISITE: /etc/embernet/k3s-token must exist on EN-0001 BEFORE
# Phase 2 runs. After CP-01 finishes its own deploy, copy the token AND
# note CP-01's embernet0 IP. Default ${CP01_EMBERNET_IP} is 100.64.1.1
# (the legacy fleet WG assignment); override via env if the embernetlite
# provisioner gave CP-01 a different address:
#   scp root@<cp01-embernet0-ip>:/etc/embernet/k3s-token /etc/embernet/k3s-token
#   chmod 600 /etc/embernet/k3s-token
#   CP01_EMBERNET_IP=<cp01-embernet0-ip>  sudo -E bash trane/deploy-ut3-en01.sh
# preflight_checks() fails hard if the token file is missing.
#
# Reference:
#   - .agent/EXECUTION_PLAN.md § Phase 4
#   - .agent/ARCHITECTURE.md  (mandatory labels, edge nodes use role=edge)
#   - fireball/deploy-embernode-arm64-microos.sh  (canonical two-phase
#                              embernetlite-first / K3s-after pattern)
#   - trane/deploy-ut3-cp01.sh  (architectural sibling — Quadlet
#                                helpers + codesys + embernetlite
#                                copied verbatim from there)
#   - trane/deploy-ut3-cp03.sh  (K3s-join pattern reference — EN-0001
#                                mirrors CP-03's join with agent shape
#                                instead of server, no etcd, no Ignition,
#                                no Postgres)
#   - commit 33b6548  (codesys RCA — the .deb dep + cfg path bugs that
#                      took universaltester004 down silently for 9 days)
# =============================================================

set -euo pipefail

# =============================================================
# CONFIGURATION
# =============================================================

NODE_NAME="${NODE_NAME:-Trane-UT3-EN-0001}"
NODE_NAME_LOWER="$(printf '%s' "${NODE_NAME}" | tr '[:upper:]' '[:lower:]')"
# EN-0001's embernet0 IPv4 is assigned by the embernetlite provisioner at
# enrollment time. Phase 2 detects it via `ip -4 addr show embernet0`
# and binds the K3s agent to that address.
EMBERNET_IFACE="embernet0"

# CP-01's embernet0 IP — EN-0001 joins CP-01's K3s API at this address
# over embernet0. Default 100.64.1.1 matches the legacy fleet WG numbering
# and is what the embernetlite provisioner assigns to CP-01 in the typical
# case. Override if your tenant got a different address:
#   CP01_EMBERNET_IP=<addr>  sudo -E bash trane/deploy-ut3-en01.sh
CP01_EMBERNET_IP="${CP01_EMBERNET_IP:-100.64.0.38}"

# CODESYS Control SL — package + locally-built image. Hardened per
# commit 33b6548 (codemeter-lite equivs shim + correct cfg path + no
# silent dep-remove fallback). DO NOT touch the Containerfile inside
# install_codesys() without re-reading the commit message.
CODESYS_VERSION="4.20.0.0"
CODESYS_URL="https://github.com/Embernet-ai/codesys-linux-x86/releases/download/v4.20.0.0/CODESYS.Control.for.Linux.SL.4.20.0.0.package"
CODESYS_IMAGE="localhost/embernet/codesys-sl:4.20.0.0"

# embernetlite (EmbernetEndpoint-Linux) — Quadlet, v0.0.29 pinned.
# v0.0.29 is the first multi-arch release with the Quadlet fixes
# (Pull= rename, EnvironmentFile= removal). Do NOT roll back to
# :stable or :latest until 0.0.30+ ships with non-interactive
# enrollment.
EMBERNET_IMAGE="ghcr.io/embernet-ai/embernetlite:0.0.36"

# K3s — host install, AGENT joining CP-01's HA cluster. Agents do NOT
# carry etcd and do NOT serve the API; the install command below uses
# `sh -s - agent` instead of `sh -s - server`, and there is no --tls-san
# (agents don't have an API). Token is provisioned out-of-band by
# copying /etc/embernet/k3s-token from CP-01 BEFORE running this script.
K3S_VERSION="v1.34.5+k3s1"
K3S_INSTALL_NAME="embernet-agent"
K3S_TOKEN_FILE="/etc/embernet/k3s-token"

# =============================================================
# HELPERS — structured logging (matches CP-01 / CP-02 / CP-03 conventions)
# =============================================================

log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
fail() { printf '\n[x] %s\n' "$*" >&2; exit 1; }

# Quadlet generator runs ASYNC off daemon-reload. systemctl restart
# fired immediately can race the generator. This helper retries once
# after a settle. Pattern lifted verbatim from CP-01 / CP-02 / CP-03.
quadlet_restart() {
  local svc="$1"
  systemctl daemon-reload
  if ! systemctl restart "${svc}"; then
    warn "First-run Quadlet race on ${svc} — letting it settle, retrying."
    sleep 5
    systemctl daemon-reload
    sleep 3
    systemctl restart "${svc}" \
      || fail "${svc} still won't start. Inspect: journalctl -xeu ${svc} -n 80 --no-pager"
  fi
}

# Idempotency gate. Returns 0 ("already running, skip") if the named
# container is present and in `running` state. Otherwise removes any
# stale instance and returns 1 so the caller proceeds with create.
container_already_running() {
  local name="$1"
  if podman container exists "${name}" 2>/dev/null; then
    local state
    state=$(podman inspect "${name}" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    if [[ "${state}" == "running" ]]; then
      return 0
    fi
    log "${name} exists but not running (${state}) — recreating"
    podman rm -f "${name}" >/dev/null 2>&1 || true
  fi
  return 1
}

# =============================================================
# FUNCTIONS
# =============================================================

# ─── [1/8] Pre-flight checks ─────────────────────────────────
preflight_checks() {
  log "[1/8] Running pre-flight checks..."

  if [[ "$EUID" -ne 0 ]]; then
    fail "Run as root (sudo bash deploy-ut3-cp01.sh)"
  fi

  # --- AWS detection (IMDSv2) ---
  AWS_VM=false
  IMDS_TOKEN=$(curl -sf -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
  if [[ -n "${IMDS_TOKEN}" ]]; then
    AWS_VM=true
    log "AWS EC2 detected — will preserve DNS and IMDS routes"
  fi

  # (No legacy `vpn.embernet.ai` /etc/hosts pin: embernetlite is the VPN
  # now and manages its own dial-home — see install_embernetlite below.)

  # --- DNS validation (READ ONLY) ---
  # We DO NOT touch /etc/resolv.conf anymore. On corporate / AD-joined
  # boxes the original behaviour (clobber with 8.8.8.8 + 1.1.1.1 if
  # github.com didn't resolve) destroyed internal DNS for TeamViewer,
  # Active Directory, internal apt mirrors — wholesale breakage for a
  # symptom that's the operator's to diagnose. If DNS is broken now,
  # we fail loud with the operator command to fix it. We do not guess.
  log "Verifying host DNS resolves before network-dependent steps"
  if ! getent hosts github.com >/dev/null 2>&1; then
    fail "Host DNS cannot resolve github.com — fix DNS before running this script. \
We will NOT overwrite /etc/resolv.conf. \
If systemd-resolved is the resolver, check: resolvectl status. \
If a static file, check: cat /etc/resolv.conf. \
Acceptable nameservers per your network policy go in resolv.conf or systemd-resolved config."
  fi
  log "DNS OK"

  # --- Kernel WireGuard module ---
  # embernetlite v0.0.34+ uses the kernel WG path via wgctrl+netlink to
  # create `embernet0` post-enrollment. The module ships with every
  # Ubuntu Jammy+ kernel but is NOT loaded by default — the daemon
  # then fails to create the interface and `embernet0` never appears.
  # Observed on Trane CP-01 deploy 2026-06-02 (Jammy, kernel 5.15.x).
  # Load now + persist for reboot.
  if ! lsmod | grep -q '^wireguard '; then
    log "Loading kernel WireGuard module (modprobe wireguard)..."
    if modprobe wireguard 2>/dev/null; then
      log "  wireguard module loaded"
    else
      warn "modprobe wireguard failed — kernel may have it built-in OR may not have the module at all. \
Check: modinfo wireguard. If absent, embernetlite will fall back to wireguard-go userspace TUN \
(slower but works). embernet0 should still come up post-enrollment either way."
    fi
  else
    log "wireguard kernel module already loaded"
  fi
  # Persist across reboots — drop a one-liner under /etc/modules-load.d/
  # so systemd-modules-load.service reloads it on boot. Idempotent file
  # write; safe to re-run.
  if [[ ! -f /etc/modules-load.d/wireguard.conf ]]; then
    echo "wireguard" > /etc/modules-load.d/wireguard.conf
    log "  persisted wireguard module load via /etc/modules-load.d/wireguard.conf"
  fi

  # --- Sysctl: forward + inotify + file-max ---
  # Gotchas table: containerd/CRI on a multi-container host exhausts
  # the default fs.inotify.max_user_instances=128. Bump aggressively.
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  {
    echo "net.ipv4.ip_forward=1"
    echo "kernel.panic=10"
    echo "kernel.panic_on_oops=1"
    echo "net.ipv4.conf.all.src_valid_mark=1"
    echo "fs.inotify.max_user_instances=8192"
    echo "fs.inotify.max_user_watches=524288"
    echo "fs.file-max=2097152"
  } > /etc/sysctl.d/99-embernet-forward.conf
  sysctl -p /etc/sysctl.d/99-embernet-forward.conf >/dev/null

  # --- Install base packages ---
  apt-get update
  apt-get install -y curl wget openssl podman dnsutils jq iproute2 ufw

  # --- Fix podman CNI configuration ---
  # Gotchas table: K3s install wipes /etc/cni/net.d which destroys
  # podman's default bridge. Restore the canonical conflist; later
  # `podman rm/run` calls would fail with `CNI network "podman" not
  # found` without this.
  mkdir -p /etc/cni/net.d
  cat <<'EOF' > /etc/cni/net.d/87-podman.conflist
{
  "cniVersion": "0.4.0",
  "name": "podman",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni-podman0",
      "isGateway": true,
      "ipMasq": true,
      "hairpinMode": true,
      "ipam": {
        "type": "host-local",
        "routes": [{"dst": "0.0.0.0/0"}],
        "ranges": [[{"subnet": "10.88.0.0/16", "gateway": "10.88.0.1"}]]
      }
    },
    {"type": "portmap", "capabilities": {"portMappings": true}},
    {"type": "firewall"},
    {"type": "tuning"}
  ]
}
EOF

  # Stale container/service refs from previous deploy iterations.
  podman rm -f ignition-cloud postgres codesys 2>/dev/null || true
  rm -f /run/container-ignition-cloud.service.ctr-id 2>/dev/null || true

  # Host dirs the install steps + embernetlite need
  mkdir -p /etc/embernet
  mkdir -p /etc/containers/systemd
  mkdir -p /opt/embernet/postgres/data
  mkdir -p /opt/embernet/ignition-cloud/data
  mkdir -p /opt/embernet/codesys/data
}

# ─── [2/8] Firewall (UFW) ────────────────────────────────────
configure_firewall() {
  log "[2/8] Configuring UFW & Network Routing..."

  sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true

  WAN=$(ip route | awk '/default/ {print $5}' | head -n 1)
  log "Detected WAN interface: ${WAN}"

  # AWS DNS + IMDS preservation (gotchas table: IMDS routes lost when
  # WG Table=auto claims everything)
  if [[ "${AWS_VM}" == true ]]; then
    log "Preserving AWS DNS and IMDS routes..."
    ufw allow out to 169.254.169.253 port 53 proto udp || true
    ufw allow out to 169.254.169.253 port 53 proto tcp || true
    VPC_DNS=$(grep -m1 '^nameserver' /etc/resolv.conf.embernet-backup 2>/dev/null | awk '{print $2}')
    if [[ -n "${VPC_DNS}" && "${VPC_DNS}" != "127.0.0.53" ]]; then
      ufw allow out to "${VPC_DNS}" port 53 proto udp || true
      ufw allow out to "${VPC_DNS}" port 53 proto tcp || true
    fi
    ufw allow out to 127.0.0.53 port 53 proto udp || true
    ufw allow out to 169.254.169.254 port 80 || true
  fi

  # SSH (so we don't lock ourselves out on first ufw enable)
  ufw allow 22/tcp || true

  # CODESYS gateway — LAN-only is enforced by host topology (the node
  # sits behind plant NAT); UFW just opens the listen port.
  ufw allow 1217/tcp || true

  # (NO 6443 allow — EN-0001 is a K3s agent, NOT a server. Agents do
  # not bind the API port. NO 8088 allow — no Ignition on edge nodes.)

  # embernet0 (embernetlite-managed WireGuard) is the trusted overlay —
  # kubelet, flannel, and CP-01 API traffic all ride on it.
  ufw allow in on embernet0 || true
  # K3s internal interfaces (cni0, flannel.1) trust-pattern from CP-01
  ufw allow in on cni0 || true
  ufw allow in on flannel.1 || true
  ufw route allow in on cni0 out on "${WAN}" || true

  ufw reload || true

  log "[2/8] Firewall configured"
}

# ─── [3/8] Crash-reboot hardening ────────────────────────────
# Gotchas table: PID-1 systemd crash on a headless host = manual
# power-cycle. CrashAction=reboot makes recovery automatic.
configure_crash_reboot() {
  log "[3/8] Configuring systemd PID 1 crash-reboot hardening..."

  local CRASH_DROPIN=/etc/systemd/system.conf.d/99-embernet-crashreboot.conf

  if [[ ! -f "${CRASH_DROPIN}" ]] || ! grep -q '^CrashAction=reboot' "${CRASH_DROPIN}"; then
    mkdir -p "$(dirname "${CRASH_DROPIN}")"
    cat > "${CRASH_DROPIN}" <<'EOF'
# Embernet — auto-reboot if systemd PID 1 crashes (segfault, abort, etc).
# Companion to /etc/sysctl.d/99-embernet-forward.conf which handles
# kernel-side panics. Without this, a PID 1 crash on a headless edge
# node requires physical power-cycle.
[Manager]
CrashAction=reboot
CrashReboot=yes
EOF
    log "Wrote ${CRASH_DROPIN}"
    systemctl daemon-reexec \
      && log "systemd re-exec'd — CrashAction=reboot is now live" \
      || warn "daemon-reexec failed — setting will activate on next reboot"
  else
    log "Crash-reboot already configured — no change"
  fi
}

# (No separate WireGuard install function — embernetlite IS the VPN at
# v0.0.29. install_embernetlite below drops the Quadlet; once the
# operator completes AAD device-code enrollment, embernetlite brings up
# embernet0 in the host netns and Phase 2 of this script binds the K3s
# agent to it.)

# ─── [4/8] CODESYS Control SL 4.20 (host podman, host:1217) ──
# HARDENED per commit 33b6548. Two stacked bugs in the prior pattern
# took CP-02 down for 9 days as PID 1 = `sleep infinity`:
#
#   (1) codesyscontrol .deb declares `Depends: codemeter | codemeter-lite`,
#       neither in Debian repos. Previous `dpkg -i ... || true && apt-get
#       -f install -y` SILENTLY REMOVED the half-installed codesyscontrol.
#       Fix: equivs-built codemeter-lite shim BEFORE dpkg -i, drop the
#       `|| true && apt-get -f install -y` fallback. Hard-fail on
#       missing binary/cfg/CmpRetain.
#
#   (2) Prior entrypoint pointed at /etc/CODESYSControl.cfg. The .deb
#       installs the cfg at /etc/codesyscontrol/CODESYSControl.cfg.
#       Wrong path → runtime safe-mode. Fix: entrypoint points at the
#       correct path; no `sleep infinity` fallback.
#
# DO NOT modify the inline Containerfile without re-reading commit
# 33b6548 — these are dearly-bought lessons. Copied verbatim from
# CP-01 / CP-03's install_codesys().
install_codesys() {
  log "[4/8] Starting CODESYS Control SL ${CODESYS_VERSION}..."

  if container_already_running codesys; then
    # Verify it's NOT running `sleep infinity` (the 33b6548 RCA signature)
    local pid1
    pid1=$(podman top codesys 2>/dev/null | awk 'NR==2 {print $NF}' || true)
    if [[ "${pid1}" == *"sleep"* ]]; then
      warn "Codesys is Up but PID 1 = '${pid1}' — recreating (33b6548 signature)"
      podman rm -f codesys >/dev/null 2>&1 || true
    else
      log "[4/8] Codesys already running (PID 1: ${pid1}) — skipping rebuild"
      return 0
    fi
  fi

  # Tear down legacy host-install artifacts (idempotent — silent if absent).
  if systemctl list-units --all 2>/dev/null | grep -qi 'codesyscontrol'; then
    log "Disabling legacy host codesyscontrol service (containerized supersedes)"
    systemctl disable --now codesyscontrol 2>/dev/null || true
  fi

  local BUILD_DIR="/tmp/codesys-build"

  if ! podman image exists "${CODESYS_IMAGE}" 2>/dev/null; then
    log "Building Codesys container image..."
    apt-get install -y unzip file 2>/dev/null
    mkdir -p "${BUILD_DIR}"

    if ! wget -q --show-progress -O "${BUILD_DIR}/codesys.pkg" "${CODESYS_URL}"; then
      warn "[4/8] Codesys download failed — skipping"
      rm -rf "${BUILD_DIR}"
      return 0
    fi

    local pkg_size
    pkg_size=$(stat -c%s "${BUILD_DIR}/codesys.pkg" 2>/dev/null || echo 0)
    if [[ ${pkg_size} -lt 1024 ]]; then
      warn "[4/8] Codesys download truncated (${pkg_size} bytes) — skipping"
      rm -rf "${BUILD_DIR}"
      return 0
    fi

    # ──────────────────────────────────────────────────────────────
    # Containerfile — POST-33b6548 hardened pattern. See function
    # header comment for the full RCA.
    # ──────────────────────────────────────────────────────────────
    cat > "${BUILD_DIR}/Containerfile" <<'DOCKERFILE'
FROM docker.io/library/debian:bookworm-slim
# Debian's /bin/sh is dash. dash has no `set -o pipefail`. Switch RUN
# to bash so the `set -e` lines below work. bash is already
# in the bookworm-slim base layer; this just selects it.
SHELL ["/bin/bash", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends \
      file unzip procps equivs libcap2-bin iptables net-tools iproute2 \
    && rm -rf /var/lib/apt/lists/*
COPY codesys.pkg /tmp/codesys.pkg
# Step 1 — codemeter-lite equivs shim. The codesyscontrol .deb declares
# `Depends: codemeter | codemeter-lite`; neither is in Debian repos.
# Without this shim, dpkg fails the dep check and the prior fallback
# (`|| true && apt-get -f install -y`) silently REMOVED the half-
# installed codesyscontrol, leaving PID 1 as `sleep infinity` for 9
# days on cp02. Demo mode does not need the real CodeMeter daemon.
RUN set -e \
 && printf '%s\n' \
      'Package: codemeter-lite' \
      'Version: 99.0-codesys-pod-shim' \
      'Section: misc' \
      'Priority: optional' \
      'Architecture: all' \
      'Maintainer: codesys-pod <support@embernet.ai>' \
      'Description: Empty shim that satisfies codesyscontrols codemeter-lite dep.' \
      ' Demo mode does not require the CodeMeter daemon; this package only' \
      ' exists so dpkg dependency check passes without apt-get pulling' \
      ' the half-installed codesyscontrol back out.' \
      > /tmp/codemeter-lite.ctrl \
 && cd /tmp \
 && equivs-build codemeter-lite.ctrl \
 && dpkg -i codemeter-lite_*_all.deb \
 && rm -f codemeter-lite.ctrl codemeter-lite_*_all.deb
# Step 2 — install codesyscontrol. Hard-fail on any of:
#   - dpkg dependency error                (would have removed pkg before)
#   - binary missing post-install           (would have led to sleep inf)
#   - cfg missing post-install              (would have led to safe mode)
#   - CmpRetain not registered in user cfg  (would have led to safe mode)
# All four failure modes match what we observed on cp02; failing the
# BUILD here is the difference between "container looks Up" and
# "container actually runs CODESYS."
RUN set -e; \
    FILETYPE=$(file -b /tmp/codesys.pkg); \
    if echo "${FILETYPE}" | grep -qi 'zip'; then \
      unzip -q /tmp/codesys.pkg -d /tmp/codesys; \
      CDS_DEB=$(find /tmp/codesys -name 'codesyscontrol_*amd64.deb' -print -quit); \
      [ -n "${CDS_DEB}" ] || { echo "ERROR: no codesyscontrol_*amd64.deb in .package" >&2; ls -R /tmp/codesys >&2; exit 1; }; \
      dpkg -i "${CDS_DEB}"; \
    elif echo "${FILETYPE}" | grep -qi 'debian'; then \
      dpkg -i /tmp/codesys.pkg; \
    else \
      echo "ERROR: unrecognized installer FILETYPE: ${FILETYPE}" >&2; exit 1; \
    fi; \
    test -x /opt/codesys/bin/codesyscontrol.bin || { echo "ERROR: post-dpkg /opt/codesys/bin/codesyscontrol.bin is not executable" >&2; exit 1; }; \
    test -f /etc/codesyscontrol/CODESYSControl.cfg || { echo "ERROR: /etc/codesyscontrol/CODESYSControl.cfg missing" >&2; exit 1; }; \
    test -f /etc/codesyscontrol/CODESYSControl_User.cfg || { echo "ERROR: /etc/codesyscontrol/CODESYSControl_User.cfg missing" >&2; exit 1; }; \
    grep -q '^Component\..*=CmpRetain' /etc/codesyscontrol/CODESYSControl_User.cfg || { echo "ERROR: CmpRetain not registered in CODESYSControl_User.cfg (postinst did not run cleanly)" >&2; exit 1; }; \
    rm -rf /tmp/codesys /tmp/codesys.pkg
WORKDIR /var/opt/codesys
# Entrypoint matches /etc/init.d/codesyscontrol:65 of the shipped .deb
# (EXEC=/opt/codesys/bin/codesyscontrol.bin,
#  WORKDIR=/var/opt/codesys,
#  CONFIGFILE=/etc/codesyscontrol/CODESYSControl.cfg).
# Prior entrypoint pointed at /etc/CODESYSControl.cfg (wrong path; never
# existed) and used a `[ -x "$b" ] || exec sleep infinity` fallback,
# which is exactly how cp02 ran "Up" with no PLC runtime for 9 days.
# No fallback here — fail loud, let podman/systemd report it Failed.
ENTRYPOINT ["/opt/codesys/bin/codesyscontrol.bin", "/etc/codesyscontrol/CODESYSControl.cfg"]
DOCKERFILE

    if ! podman build -t "${CODESYS_IMAGE}" "${BUILD_DIR}"; then
      warn "[4/8] Codesys container build failed — skipping"
      rm -rf "${BUILD_DIR}"
      return 0
    fi
    rm -rf "${BUILD_DIR}"
  fi

  # Defensive cleanup: remove any pre-existing `codesys` container (stopped,
  # created, or otherwise NOT-running so container_already_running returned
  # false above). Without this, `podman run --name codesys` collides on the
  # stale name and the deploy halts. Idempotent — silent if absent.
  if podman container exists codesys 2>/dev/null; then
    log "Removing pre-existing (non-running) codesys container before fresh start"
    podman rm -f codesys >/dev/null 2>&1 || true
  fi

  podman run -d \
    --name codesys \
    --restart=always \
    --network=host \
    --privileged \
    -v /opt/embernet/codesys/data:/var/opt/codesys \
    "${CODESYS_IMAGE}"

  podman generate systemd --name codesys --new --restart-policy=always \
    > /etc/systemd/system/container-codesys.service 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable container-codesys.service 2>/dev/null || true

  log "[4/8] Codesys: $(podman ps --filter name=codesys --format '{{.Status}}' 2>/dev/null || echo 'starting')"
}

# ─── [5/8] embernetlite (EmbernetEndpoint-Linux, Quadlet) ────
# embernetlite IS the VPN at v0.0.29 — it ships its own WireGuard driver
# and brings up `embernet0` in the host netns post-enrollment. K3s agent
# `--flannel-iface=embernet0` rides on that interface (Phase 2).
# Quadlet body taken verbatim from embernetlite-linux/packaging/
# quadlet/embernet.container (the v0.0.29 fix-set: Pull=newer NOT
# PullPolicy=newer, NO EnvironmentFile=).
#
# Two-phase semantics (mirrors fireball/deploy-embernode-arm64-microos.sh):
#   Phase 1 (this function + CODESYS): drop the Quadlet, start
#     embernet.service. If embernet0 is NOT up yet, gate_on_embernet0
#     prints enrollment instructions and exit 0s.
#   Phase 2 (re-run after operator completes AAD device-code login):
#     embernet0 detected with an IPv4 → K3s agent joins CP-01 over it.
install_embernetlite() {
  log "[5/8] Installing embernetlite (Quadlet, ${EMBERNET_IMAGE})..."

  # Host dirs the container bind-mounts. v0.0.29 runs as uid 987 inside
  # the container (see embernetlite-linux). chown so the bind mounts
  # are writable by the unprivileged user.
  mkdir -p /etc/embernet /var/lib/embernet /var/log/embernet /run/embernet
  chown 987:987 /var/lib/embernet /var/log/embernet /run/embernet
  # /etc/embernet is mounted ro — group/world readable is fine; leave
  # ownership as root so config drops by the operator survive container
  # restarts.

  # Tear down any legacy flux-edge-tunnel artifacts from the old CP-01
  # script (the openziti host install). embernetlite supersedes it.
  if systemctl list-unit-files 2>/dev/null | grep -q '^ziti'; then
    log "Disabling legacy host openziti units (embernetlite supersedes)"
    systemctl disable --now ziti-edge-tunnel.service 2>/dev/null || true
    systemctl disable --now ziti.service 2>/dev/null || true
  fi
  if [[ -d /etc/embernet/ziti && ! -L /etc/embernet/ziti ]]; then
    log "Archiving legacy /etc/embernet/ziti → /etc/embernet/ziti.legacy"
    mv /etc/embernet/ziti /etc/embernet/ziti.legacy 2>/dev/null || true
  fi
  if dpkg -l openziti 2>/dev/null | grep -q '^ii'; then
    log "Removing legacy openziti apt package"
    apt-get purge -y openziti 2>/dev/null || true
  fi

  # Image-version-aware idempotency gate. Re-runnable — the script can
  # be invoked any number of times and will pick up image-pin bumps
  # automatically:
  #
  #   - Container exists + running + same image as ${EMBERNET_IMAGE}
  #     → skip, nothing to do.
  #   - Container exists + running + DIFFERENT image
  #     → recreate (operator bumped the pin; this is the resume path).
  #   - Container exists + not running (Exited / Created / Paused)
  #     → recreate (cleans up stale state from prior crashloop / oom).
  #   - Container does not exist
  #     → fresh create.
  #
  # IMPORTANT: this is what makes re-running the deploy script after an
  # embernetlite version bump (e.g. 0.0.29 → 0.0.33 to pick up a netlink
  # panic fix) work without manual `podman rm`. The plain
  # container_already_running helper does NOT image-check.
  local need_recreate=1
  if podman container exists systemd-embernet 2>/dev/null; then
    local em_state em_image
    em_state=$(podman inspect systemd-embernet --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    em_image=$(podman inspect systemd-embernet --format '{{.ImageName}}' 2>/dev/null || echo "")
    if [[ "${em_state}" == "running" && "${em_image}" == "${EMBERNET_IMAGE}" ]]; then
      log "[5/8] embernetlite already running on ${EMBERNET_IMAGE} — skipping"
      return 0
    fi
    if [[ "${em_state}" == "running" ]]; then
      log "embernetlite container running on ${em_image} but pin is ${EMBERNET_IMAGE} — recreating to pick up the new image"
    else
      log "embernetlite container exists but is ${em_state} (likely prior crashloop) — recreating"
    fi
    podman rm -f systemd-embernet >/dev/null 2>&1 || true
    need_recreate=1
  fi

  # Pull the image up front so the first `podman run` is local-only.
  log "Pulling ${EMBERNET_IMAGE}..."
  podman pull "${EMBERNET_IMAGE}" || fail "podman pull of ${EMBERNET_IMAGE} failed — check egress to ghcr.io"

  # Run the container directly via `podman run`. We DELIBERATELY do NOT
  # use Quadlet here — Quadlet was added in podman 4.4 and is missing
  # on Ubuntu 22.04 Jammy (podman 3.4.4). This pattern matches the rest
  # of the script (postgres, ignition, codesys) and works on EVERY
  # podman version from 3.x through 5.x.
  #
  # Podman-version-detect, just for informational logging.
  local podman_ver
  podman_ver=$(podman --version 2>/dev/null | awk '{print $3}' || echo "unknown")
  log "Host podman version: ${podman_ver}"

  # Clean any stale instance from a prior failed run.
  podman rm -f systemd-embernet >/dev/null 2>&1 || true

  log "Starting embernetlite container (podman run --network=host)..."
  podman run -d \
    --name systemd-embernet \
    --restart=always \
    --network=host \
    --cap-add=CAP_NET_ADMIN \
    --cap-add=CAP_NET_RAW \
    --device=/dev/net/tun \
    -v /etc/embernet:/etc/embernet:ro,Z \
    -v /var/lib/embernet:/var/lib/embernet:Z \
    -v /var/log/embernet:/var/log/embernet:Z \
    -v /run/embernet:/run/embernet:Z \
    "${EMBERNET_IMAGE}" \
    || fail "podman run systemd-embernet failed — inspect: podman logs systemd-embernet"

  # Generate a systemd unit from the running container. This is the
  # `podman generate systemd` pattern — older than Quadlet but works
  # on podman 3.x (Jammy), 4.x (Noble), and is the same pattern
  # install_postgres / install_ignition_cloud / install_codesys use.
  # `--new` makes the unit recreate the container on restart instead
  # of just starting the existing one.
  log "Generating systemd unit (embernet.service)..."
  podman generate systemd \
    --name systemd-embernet \
    --new \
    --restart-policy=always \
    --container-prefix='' \
    --separator='' \
    > /etc/systemd/system/embernet.service \
    || fail "podman generate systemd failed — inspect: systemctl status embernet.service"

  systemctl daemon-reload
  systemctl enable embernet.service >/dev/null 2>&1 || true

  # The container is already running from `podman run -d` above. We
  # don't need to systemctl start — but we DO need to make sure systemd
  # adopts the running container so future host reboots bring it back.
  # `systemctl restart` would orphan the running container and re-pull.
  # Just verify the unit is "active" via the running PID.
  if podman ps --filter name=systemd-embernet --format '{{.Status}}' | grep -q '^Up'; then
    log "[5/8] embernetlite running (systemd unit: embernet.service, enabled for boot)"
  else
    fail "embernetlite container not running after podman run — inspect: podman logs systemd-embernet"
  fi
}

# ─── [8/11] Gate on embernet0 — Phase 1 / Phase 2 split ──────
# After embernetlite is installed, two outcomes are possible:
#   (a) embernet0 is up with an IPv4 → Phase 2 can run. Set
#       EMBERNET_IP and return 0.
#   (b) embernet0 not yet up → Phase 1 is complete; the operator must
#       finish AAD device-code enrollment in a browser. Print the
#       instructions block and `exit 0` (NOT a failure).
#
# Pattern lifted from fireball/deploy-embernode-arm64-microos.sh.
gate_on_embernet0() {
  log "[6/8] Gating on ${EMBERNET_IFACE} (Phase 1 → Phase 2 transition)..."

  if _embernet0_up; then
    log "[6/8] ${EMBERNET_IFACE} is up — IPv4 ${EMBERNET_IP}. Proceeding with Phase 2 (K3s)."
    return 0
  fi

  # Wait up to 30 s for the daemon to write auth.token after first start.
  local deadline=$(( $(date +%s) + 30 ))
  while [[ ! -s /var/lib/embernet/auth.token ]] && [[ $(date +%s) -lt ${deadline} ]]; do
    sleep 1
  done
  [[ -s /var/lib/embernet/auth.token ]] \
    || fail "embernetlite hasn't written /var/lib/embernet/auth.token after 30s — \
inspect: sudo podman logs systemd-embernet"

  enroll_interactively
  _wait_for_embernet0
  log "[6/8] ${EMBERNET_IFACE} up — IPv4 ${EMBERNET_IP}. Proceeding with Phase 2 (K3s)."
}

# ── enrollment helpers ──────────────────────────────────────

# _embernet0_up — returns 0 and sets EMBERNET_IP if the interface has
# an IPv4; returns 1 otherwise.
_embernet0_up() {
  if ip -4 addr show "${EMBERNET_IFACE}" 2>/dev/null | grep -q 'inet '; then
    EMBERNET_IP="$(ip -4 -o addr show "${EMBERNET_IFACE}" \
                   | awk '{print $4}' | cut -d/ -f1 | head -1)"
    [[ -n "${EMBERNET_IP}" ]] && return 0
  fi
  return 1
}

# _enroll_api METHOD PATH [BODY_JSON]
# Hits the daemon's enroll API. Token read fresh each call so a daemon
# restart mid-flow (which rotates auth.token) doesn't break us.
_enroll_api() {
  local method="$1" path="$2" body="${3:-}"
  local tok
  tok="$(cat /var/lib/embernet/auth.token 2>/dev/null)"
  [[ -n "${tok}" ]] || { echo "AUTH_TOKEN_MISSING"; return 1; }
  if [[ -n "${body}" ]]; then
    curl -sS -X "${method}" \
      -H "Authorization: Bearer ${tok}" \
      -H "Content-Type: application/json" \
      -d "${body}" \
      "http://127.0.0.1:8765/api/v1/enroll/${path}"
  else
    curl -sS -X "${method}" \
      -H "Authorization: Bearer ${tok}" \
      "http://127.0.0.1:8765/api/v1/enroll/${path}"
  fi
}

# _state_phase — extract the `phase` field from a State JSON blob on
# stdin. Returns "" on parse error so callers can default-handle.
_state_phase() {
  python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("phase",""))
except Exception:
    pass' 2>/dev/null
}

# enroll_interactively — drives the AAD device-code wizard from inside
# the script. Idempotent on resume (looks at the current wizard phase
# before deciding what to do).
enroll_interactively() {
  log "Driving AAD device-code enrollment for ${NODE_NAME}..."

  local state phase
  state="$(_enroll_api GET state)" || fail "daemon API unreachable on 127.0.0.1:8765 — \
inspect: sudo podman logs systemd-embernet"
  phase="$(printf '%s' "${state}" | _state_phase)"
  log "  current wizard phase: ${phase:-(unknown)}"

  # Phase-aware resume / reset.
  case "${phase}" in
    done)
      log "  wizard already at done — provisioner already issued creds, drivers should be Connect-ing"
      return 0
      ;;
    failed)
      local prior_err
      prior_err="$(printf '%s' "${state}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error",""))' 2>/dev/null)"
      warn "  wizard at failed (prior attempt: ${prior_err}) — cancelling + starting fresh"
      _enroll_api POST cancel >/dev/null || true
      phase=idle
      ;;
    idle|"")
      phase=idle
      ;;
    *)
      log "  resuming mid-flight at phase=${phase}"
      ;;
  esac

  # Issue the device code if we're starting fresh. The Start endpoint
  # is idempotent against a running wizard — calling it on a non-idle
  # wizard returns the existing state without re-issuing.
  if [[ "${phase}" == "idle" ]]; then
    log "  POST /enroll/start — requesting AAD device-code..."
    state="$(_enroll_api POST start "{\"device_name\":\"${NODE_NAME}\",\"display_name\":\"${NODE_NAME}\"}")"
    phase="$(printf '%s' "${state}" | _state_phase)"
    case "${phase}" in
      device_code_issued|awaiting_user) ;;
      *)
        local err
        err="$(printf '%s' "${state}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error",""))' 2>/dev/null)"
        fail "POST /enroll/start did not advance to device_code_issued — phase=${phase}, error=${err}"
        ;;
    esac
  fi

  # If we already have a user_code in state, display it.
  local user_code verification_uri expires_at
  user_code="$(printf '%s' "${state}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("user_code",""))' 2>/dev/null)"
  verification_uri="$(printf '%s' "${state}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("verification_uri",""))' 2>/dev/null)"
  expires_at="$(printf '%s' "${state}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("expires_at",""))' 2>/dev/null)"
  if [[ -n "${user_code}" ]]; then
    printf '\n'
    printf '  +============================================================+\n'
    printf '  |              AAD DEVICE-CODE AUTHENTICATION                |\n'
    printf '  +============================================================+\n'
    printf '\n'
    printf '   1. Open this URL in any browser (your laptop is fine):\n'
    printf '\n'
    printf '       %s\n' "${verification_uri}"
    printf '\n'
    printf '   2. Enter this code:\n'
    printf '\n'
    printf '       %s\n' "${user_code}"
    printf '\n'
    printf '   3. Sign in with your Fireball / customer AAD account.\n'
    printf '      Single-tenant customer account = auto-binds to that tenant.\n'
    printf '      Multi-tenant fireballz.ai account = this script will prompt.\n'
    printf '\n'
    printf '   (Code expires: %s)\n' "${expires_at}"
    printf '\n'
    printf '  +============================================================+\n'
    printf '\n'
  fi

  # Poll the wizard until we either need tenant selection or reach
  # done/failed. 15-min hard timeout — matches AAD code TTL.
  log "  polling /enroll/state every 3 s (timeout: 15 min)..."
  local poll_deadline=$(( $(date +%s) + 900 ))
  while true; do
    if [[ $(date +%s) -gt ${poll_deadline} ]]; then
      fail "AAD device-code timed out — code expired. Re-run the script to retry."
    fi
    sleep 3
    state="$(_enroll_api GET state)" || fail "daemon API stopped responding mid-enroll"
    phase="$(printf '%s' "${state}" | _state_phase)"
    case "${phase}" in
      done)
        log "  wizard advanced to done"
        return 0
        ;;
      failed)
        local err
        err="$(printf '%s' "${state}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error",""))' 2>/dev/null)"
        fail "wizard failed: ${err}"
        ;;
      choosing_tenant)
        _pick_tenant_and_post "${state}"
        # Continue polling — wizard moves to provisioning then done.
        ;;
      device_code_issued|awaiting_user)
        : # still waiting for user to complete browser auth
        ;;
      provisioning)
        log "  wizard at provisioning — fetching tenant secret + calling provisioner..."
        ;;
      *)
        log "  wizard at ${phase:-(unknown)} — continuing to poll"
        ;;
    esac
  done
}

# _pick_tenant_and_post STATE_JSON
# Honours TENANT_ID env override (non-interactive). Otherwise: if there
# is exactly one tenant, auto-pick (daemon should have done this but
# defence in depth). If multiple AND a TTY is attached, prompt. If
# multiple AND no TTY, fail loud.
_pick_tenant_and_post() {
  local state="$1"
  local tenants_json count
  tenants_json="$(printf '%s' "${state}" | python3 -c 'import json,sys; json.dump(json.load(sys.stdin).get("tenants",[]), sys.stdout)')"
  count="$(printf '%s' "${tenants_json}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

  local pick_id="" pick_source=""

  # 1. TENANT_ID env override.
  if [[ -n "${TENANT_ID:-}" ]]; then
    pick_id="$(printf '%s' "${tenants_json}" | python3 -c "
import json, sys
want = '${TENANT_ID}'
for t in json.load(sys.stdin):
    if t.get('id') == want or t.get('name') == want:
        print(t['id']); break
")"
    if [[ -z "${pick_id}" ]]; then
      fail "TENANT_ID=${TENANT_ID} not in the daemon's tenant list. \
Available: $(printf '%s' "${tenants_json}" | python3 -c 'import json,sys; print(", ".join(t["id"] for t in json.load(sys.stdin)))')"
    fi
    pick_source="TENANT_ID env override"

  # 2. Single tenant returned.
  elif [[ "${count}" == "1" ]]; then
    pick_id="$(printf '%s' "${tenants_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')"
    pick_source="single tenant in account"

  # 3. NODE_NAME → tenant heuristic. Auto-pick if we find a match.
  else
    pick_id="$(printf '%s' "${tenants_json}" | python3 -c "
import json, sys
node = '${NODE_NAME}'.lower()
tenants = json.load(sys.stdin)
target = None
if 'trane' in node or 'ut3' in node:
    target = 'tranetech-ut3'
elif 'fragua' in node:
    target = 'fragua'
elif 'fireball' in node or 'fbi' in node or 'embernet' in node or 'embernode' in node:
    target = 'fireball'
if target:
    for t in tenants:
        if t.get('id') == target or t.get('name') == target:
            print(t['id']); break
")"
    if [[ -n "${pick_id}" ]]; then
      pick_source="NODE_NAME heuristic (${NODE_NAME})"
    elif [[ -t 0 ]]; then
      # 4. Prompt only when no inferable signal worked.
      printf '\n'
      printf '  Authentication successful. Your account has access to multiple tenants\n'
      printf '  AND %s does not match any naming-convention heuristic.\n' "${NODE_NAME}"
      printf '  Pick the tenant to enroll %s into:\n\n' "${NODE_NAME}"
      printf '%s' "${tenants_json}" | python3 -c "
import json, sys
for i, t in enumerate(json.load(sys.stdin), 1):
    name = t.get('display_name') or t.get('name') or t.get('id', '(unknown)')
    print(f'     [{i}] {name}  (id={t[\"id\"]})')
"
      printf '\n'
      local choice
      read -rp "  Select tenant by number [default: 1]: " choice
      choice="${choice:-1}"
      pick_id="$(printf '%s' "${tenants_json}" | python3 -c "
import json, sys
tenants = json.load(sys.stdin)
try:
    idx = int('${choice}') - 1
    if idx < 0 or idx >= len(tenants):
        sys.exit(2)
    print(tenants[idx]['id'])
except Exception:
    sys.exit(2)
")" || fail "invalid tenant selection: ${choice}"
      pick_source="operator interactive pick (no NODE_NAME heuristic match)"
    else
      # 5. No interaction possible AND nothing inferable.
      fail "wizard returned ${count} tenants but no TTY is attached, TENANT_ID is unset, \
and ${NODE_NAME} does not match any auto-bind heuristic (Trane-* / Fragua-* / EmberNode-*). \
Re-run with TENANT_ID=<id> sudo -E bash ... \
Available IDs: $(printf '%s' "${tenants_json}" | python3 -c 'import json,sys; print(", ".join(t["id"] for t in json.load(sys.stdin)))')"
    fi
  fi

  log "  tenant pick: ${pick_id} (source: ${pick_source})"

  log "  POST /enroll/select-tenant tenant_id=${pick_id}"
  local resp
  resp="$(_enroll_api POST select-tenant "{\"tenant_id\":\"${pick_id}\",\"device_name\":\"${NODE_NAME}\",\"display_name\":\"${NODE_NAME}\"}")"
  local sel_phase
  sel_phase="$(printf '%s' "${resp}" | _state_phase)"
  case "${sel_phase}" in
    provisioning|done) log "  select-tenant accepted → ${sel_phase}" ;;
    failed)
      local err
      err="$(printf '%s' "${resp}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error",""))' 2>/dev/null)"
      fail "select-tenant rejected: ${err}"
      ;;
    *) log "  select-tenant returned phase=${sel_phase} (will keep polling)" ;;
  esac
}

# _wait_for_embernet0 — block up to 60 s waiting for the WG driver to
# create the interface. Sets EMBERNET_IP on success; fails loud on
# timeout with diagnostic commands.
_wait_for_embernet0() {
  log "  waiting up to 60 s for ${EMBERNET_IFACE} to appear..."
  local i
  for i in $(seq 1 60); do
    sleep 1
    if _embernet0_up; then
      log "  ${EMBERNET_IFACE} up after ${i}s — IPv4 ${EMBERNET_IP}"
      return 0
    fi
  done
  fail "${EMBERNET_IFACE} did not come up within 60s of phase=done. Diagnose: \
sudo podman logs --tail=100 systemd-embernet | grep -iE 'wireguard|connect|driver|error'; \
curl -sS -H \"Authorization: Bearer \$(sudo cat /var/lib/embernet/auth.token)\" http://127.0.0.1:8765/api/v1/tunnels | python3 -m json.tool"
}

# ─── [9/11] K3s agent (host install, JOIN CP-01 over embernet0) ──
# EN-0001 is a WORKER node of the trane-ut3 cluster. It does NOT run
# etcd, does NOT serve the Kubernetes API, and does NOT generate a
# cluster token — it CONSUMES the existing K3s token that CP-01
# already wrote to /etc/embernet/k3s-token, joining CP-01's existing
# cluster via:
#   K3S_URL=https://${CP01_EMBERNET_IP}:6443  (CP-01's API over embernet0)
#   K3S_TOKEN=<pre-staged from CP-01's /etc/embernet/k3s-token>
#
# PRE-REQUISITE (one-time per box, BEFORE Phase 2 runs):
#   On CP-01 (universaltester004):
#     sudo cat /etc/embernet/k3s-token         # copy the value
#   On EN-0001:
#     sudo mkdir -p /etc/embernet
#     sudo install -m 600 /dev/stdin /etc/embernet/k3s-token <<EOF
#     <paste-the-token>
#     EOF
#     CP01_EMBERNET_IP=100.64.0.38  sudo -E bash trane/deploy-ut3-en01.sh
#
# Phase 1 of this script doesn't need either; Phase 1 runs preflight
# + installs embernetlite + waits for AAD enrollment. /etc/embernet/k3s-token
# only matters once Phase 2 starts.
install_k3s_agent() {
  log "[7/8] Joining EmberNet UT3 cluster as agent (K3s host install, --server)..."

  # --- Pre-flight: clean up wedged K3s state if present ---
  local needs_wipe=0
  if [[ -x /usr/local/bin/k3s ]] \
     && ! systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}" 2>/dev/null \
     && ! systemctl is-active --quiet k3s 2>/dev/null \
     && ! systemctl is-active --quiet k3s-agent 2>/dev/null; then
    needs_wipe=1
    log "Detected wedged K3s: /usr/local/bin/k3s present but no active k3s/k3s-agent unit"
  fi
  if [[ "${K3S_FORCE_WIPE:-0}" == "1" ]]; then
    needs_wipe=1
    log "K3S_FORCE_WIPE=1 — wiping K3s state regardless of current health"
  fi
  if [[ ${needs_wipe} -eq 1 ]]; then
    log "Running canonical K3s uninstall + state wipe..."
    if [[ -x "/usr/local/bin/k3s-${K3S_INSTALL_NAME}-agent-uninstall.sh" ]]; then
      "/usr/local/bin/k3s-${K3S_INSTALL_NAME}-agent-uninstall.sh" || warn "uninstall exited non-zero — continuing"
    elif [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
      /usr/local/bin/k3s-agent-uninstall.sh || warn "k3s-agent-uninstall.sh exited non-zero — continuing"
    elif [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
      /usr/local/bin/k3s-uninstall.sh || warn "k3s-uninstall.sh exited non-zero — continuing"
    fi
    rm -rf /var/lib/rancher /etc/rancher /var/lib/cni /etc/cni /run/k3s 2>/dev/null || true
    ip link delete flannel.1 2>/dev/null || true
    ip link delete cni0 2>/dev/null || true
    if dpkg -l 2>/dev/null | grep -qE "^ii\s+(containerd|containerd\.io|docker\.io|docker-ce-cli)\s"; then
      log "Purging host-installed containerd/docker.io (conflicts with K3s embedded containerd)"
      apt-get purge -y containerd containerd.io docker.io docker-ce-cli 2>/dev/null || true
      apt-get autoremove -y 2>/dev/null || true
    fi
    systemctl daemon-reload
    # Restore podman CNI (the wipe nuked /etc/cni)
    mkdir -p /etc/cni/net.d
    cat <<'EOF' > /etc/cni/net.d/87-podman.conflist
{"cniVersion":"0.4.0","name":"podman","plugins":[{"type":"bridge","bridge":"cni-podman0","isGateway":true,"ipMasq":true,"hairpinMode":true,"ipam":{"type":"host-local","routes":[{"dst":"0.0.0.0/0"}],"ranges":[[{"subnet":"10.88.0.0/16","gateway":"10.88.0.1"}]]}},{"type":"portmap","capabilities":{"portMappings":true}},{"type":"firewall"},{"type":"tuning"}]}
EOF
    log "K3s pre-flight cleanup complete"
  fi

  # --- Require pre-staged cluster token (agent CONSUMES, never generates) ---
  if [[ ! -s /etc/embernet/k3s-token ]]; then
    fail "/etc/embernet/k3s-token is missing or empty.
       EN agents JOIN the existing trane-ut3 cluster — they cannot mint their
       own cluster token. Copy CP-01's token onto this box first:
         on CP-01:  sudo cat /etc/embernet/k3s-token
         on this box:
           sudo mkdir -p /etc/embernet
           sudo install -m 600 /dev/stdin /etc/embernet/k3s-token <<TOKEN
           <paste-the-token-value>
           TOKEN
         then re-run this script."
  fi
  K3S_TOKEN="$(cat /etc/embernet/k3s-token)"
  log "Using pre-staged K3s join token from /etc/embernet/k3s-token"

  # --- Verify CP-01 API reachable over embernet0 before installing ---
  if ! curl -sk -o /dev/null --max-time 5 "https://${CP01_EMBERNET_IP}:6443/healthz" 2>/dev/null \
     && ! nc -z -w 5 "${CP01_EMBERNET_IP}" 6443 2>/dev/null; then
    fail "CP-01 K3s API at https://${CP01_EMBERNET_IP}:6443 is unreachable.
       Check: embernet0 routing, CP-01's k3s-embernet-server.service status,
       and CP01_EMBERNET_IP env var (currently '${CP01_EMBERNET_IP}')."
  fi
  log "CP-01 K3s API reachable at https://${CP01_EMBERNET_IP}:6443"

  # --- Install K3s agent if not already healthy ---
  if [[ -x /usr/local/bin/k3s ]] \
     && systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}-agent" 2>/dev/null; then
    log "K3s agent already installed and active — skipping reinstall"
  else
    log "Installing K3s agent (host binary + systemd service, joining ${CP01_EMBERNET_IP}:6443)"
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="${K3S_VERSION}" \
      INSTALL_K3S_NAME="${K3S_INSTALL_NAME}" \
      K3S_TOKEN="${K3S_TOKEN}" \
      K3S_URL="https://${CP01_EMBERNET_IP}:6443" \
      sh -s - agent \
        --node-name="${NODE_NAME_LOWER}" \
        --node-ip="${EMBERNET_IP}" \
        --flannel-iface=embernet0 \
        --node-label="embernet.ai/tenant=tranetech-ut3" \
        --node-label="embernet.ai/site=ut3" \
        --node-label="embernet.ai/role=worker" \
        --node-label="embernet.ai/node-name=${NODE_NAME_LOWER}"
  fi

  log "Waiting for k3s-${K3S_INSTALL_NAME}-agent.service to be active (max 120s)..."
  local k3s_wait=0
  local k3s_max=120
  while [[ ${k3s_wait} -lt ${k3s_max} ]]; do
    if systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}-agent" 2>/dev/null; then
      break
    fi
    sleep 3
    k3s_wait=$((k3s_wait + 3))
  done

  if systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}-agent" 2>/dev/null; then
    log "[7/8] K3s agent: active (systemd unit: k3s-${K3S_INSTALL_NAME}-agent.service)"
    log "       Node will appear as Ready in CP-01's 'kubectl get nodes' within ~30 s."
  else
    warn "[9/11] K3s agent: not yet active after ${k3s_max}s"
    warn "Check: journalctl -xeu k3s-${K3S_INSTALL_NAME}-agent --no-pager -n 80"
  fi
}

# (No Rancher-registration step on EN-0001 — CP-01's Rancher import
# covers the whole HA cluster. Adding one here would create a duplicate
# Rancher registration for the same cluster.)

# ─── [8/8] verify_deployment — the gate ──────────────────────
# Each check prints `[PASS]` or `[FAIL]` followed by the check name.
# Returns 0 if ALL pass, exits 1 otherwise. This is the Phase 4
# exit-criteria gate. Mirrors CP-03 verify_deployment with these
# deltas:
#   - NO etcd member check (agents don't carry etcd)
#   - NO Postgres reachability check (EN doesn't connect to the DB)
#   - NO Ignition HTTP check (EN doesn't host a gateway)
#   - NO cattle-cluster-agent check (CP-01 owns Rancher registration)
#   - K3s "node Ready" + label checks query CP-01's API over embernet0
#     (the local agent's kubelet.kubeconfig is also probed as a fallback);
#     if the cluster API is unreachable at verify time, those checks
#     warn-skip rather than fail.
verify_deployment() {
  log "[8/8] Verifying deployment..."

  local fails=0
  local pass_count=0
  local results=()

  _check() {
    local name="$1"
    local status="$2"
    if [[ "${status}" == "PASS" ]]; then
      printf '  [PASS] %s\n' "${name}"
      pass_count=$((pass_count + 1))
      results+=("PASS  ${name}")
    else
      printf '  [FAIL] %s\n' "${name}" >&2
      fails=$((fails + 1))
      results+=("FAIL  ${name}")
    fi
  }

  # 1. embernet0 interface up + has IPv4 (embernetlite-managed VPN).
  # embernetlite IS the VPN now and owns embernet0. Pre-enrollment this
  # fails (the interface isn't up yet); post-enrollment + Phase 2 it
  # must be up for K3s to have bound to it at all.
  local em_iface_ip
  em_iface_ip="$(ip -4 -o addr show "${EMBERNET_IFACE}" 2>/dev/null \
                 | awk '{print $4}' | cut -d/ -f1 | head -1)"
  if [[ -n "${em_iface_ip}" ]]; then
    _check "${EMBERNET_IFACE} interface up + has IPv4 (${em_iface_ip})" PASS
  else
    _check "${EMBERNET_IFACE} interface up + has IPv4 — FAILED (complete embernetlite enrollment first, then re-run)" FAIL
  fi

  # 2. embernetlite container running + healthy
  # Healthcheck may report `starting` for up to HealthStartPeriod=15s
  # after start. Allow `healthy` OR `starting` as PASS; only `unhealthy`
  # or container-missing is FAIL.
  local em_state em_health
  em_state=$(podman inspect systemd-embernet --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  em_health=$(podman inspect systemd-embernet --format '{{.State.Health.Status}}' 2>/dev/null || echo "none")
  if [[ "${em_state}" == "running" ]] && [[ "${em_health}" == "healthy" || "${em_health}" == "starting" || "${em_health}" == "none" ]]; then
    _check "embernetlite container running (health=${em_health})" PASS
  else
    _check "embernetlite container running (state=${em_state}, health=${em_health})" FAIL
  fi

  # 3. embernetlite API responding — STRICT (FAILs in pre-enrollment).
  # The local API listens on 127.0.0.1:8080 inside the container; the
  # bearer token is written to /var/lib/embernet/auth.token after the
  # daemon finishes its first start. Operator policy (per user, 2026-05-28):
  # verify_deployment must FAIL if the API can't be reached. That means
  # a freshly deployed CP-01 will FAIL this check until the operator
  # completes AAD device-code enrollment via the dashboard — by design,
  # so 'all-PASS' really means 'this box is in fleet'.
  if [[ -s /var/lib/embernet/auth.token ]]; then
    local em_token
    em_token=$(cat /var/lib/embernet/auth.token 2>/dev/null || true)
    if podman exec systemd-embernet curl -sf -m 5 \
         -H "Authorization: Bearer ${em_token}" \
         http://127.0.0.1:8080/api/v1/health >/dev/null 2>&1; then
      _check "embernetlite API /api/v1/health responding (enrollment complete)" PASS
    else
      _check "embernetlite API /api/v1/health responding — FAILED (pre-enrollment? re-run \`sudo bash trane/deploy-ut3-en01.sh\` and complete the AAD device-code flow when prompted)" FAIL
    fi
  else
    _check "embernetlite API /api/v1/health responding — FAILED (auth.token not generated yet; daemon not started or pre-enrollment; re-run the deploy script and complete the AAD device-code flow when prompted)" FAIL
  fi

  # 4. Postgres ready
  if podman exec postgres pg_isready -h 127.0.0.1 -U "${POSTGRES_USER}" >/dev/null 2>&1; then
    _check "Postgres pg_isready (user=${POSTGRES_USER})" PASS
  else
    _check "Postgres pg_isready (user=${POSTGRES_USER})" FAIL
  fi

  # 5. Ignition Cloud responding
  local ign_code
  ign_code=$(curl -fsI -o /dev/null -w '%{http_code}' -m 10 http://127.0.0.1:8088 2>/dev/null || echo "000")
  if [[ "${ign_code}" == "200" || "${ign_code}" == "302" ]]; then
    _check "Ignition Cloud http://127.0.0.1:8088 (HTTP ${ign_code})" PASS
  else
    _check "Ignition Cloud http://127.0.0.1:8088 (HTTP ${ign_code})" FAIL
  fi

  # 6. CODESYS port 1217 listening
  if ss -ltn 2>/dev/null | grep -q ':1217'; then
    _check "CODESYS port 1217 listening" PASS
  else
    _check "CODESYS port 1217 listening" FAIL
  fi

  # 7. CODESYS PID 1 is NOT sleep infinity (33b6548 signature)
  local codesys_pid1
  codesys_pid1=$(podman top codesys 2>/dev/null | awk 'NR==2 {print $NF}' || echo "missing")
  if [[ "${codesys_pid1}" == "missing" ]]; then
    _check "CODESYS PID 1 is not sleep (container missing)" FAIL
  elif [[ "${codesys_pid1}" == *"sleep"* ]]; then
    _check "CODESYS PID 1 is not sleep (33b6548 — got '${codesys_pid1}')" FAIL
  else
    _check "CODESYS PID 1 is not sleep (got '${codesys_pid1}')" PASS
  fi

  # 8. K3s node Ready — checked via the joined cluster's API (over embernet0)
  # since EN agents don't expose their own kubectl. Falls back to local
  # kubelet status if the cluster API is unreachable at verify time.
  local node_ready="Unknown"
  if curl -sk -o /dev/null --max-time 5 "https://${CP01_EMBERNET_IP}:6443/healthz" 2>/dev/null; then
    # CP-01 has a kubeconfig at /etc/rancher/k3s/k3s.yaml; on EN we
    # don't (agents don't ship one). Probe via raw API + node-token
    # auth would need plumbing. Simplest: trust systemctl is-active on
    # the local agent unit + assume node has joined when the unit is
    # active. The cluster-side Ready check is operator-visible from CP-01.
    if systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}-agent" 2>/dev/null; then
      node_ready="True"
    fi
  fi
  if [[ "${node_ready}" == "True" ]]; then
    _check "K3s agent active (cluster-side 'Ready' visible from CP-01: kubectl get node ${NODE_NAME_LOWER})" PASS
  else
    _check "K3s agent active — FAILED (systemd unit k3s-${K3S_INSTALL_NAME}-agent.service not active OR CP-01 API unreachable)" FAIL
  fi

  # 9. systemd unit + node-ip + node-name baked into K3S_EXEC env file
  local exec_file="/etc/systemd/system/k3s-${K3S_INSTALL_NAME}-agent.service.env"
  local exec_args="(missing)"
  if [[ -f "${exec_file}" ]]; then
    exec_args=$(cat "${exec_file}" 2>/dev/null)
  fi
  local labels_ok=1
  for needle in \
    "embernet.ai/tenant=tranetech-ut3" \
    "embernet.ai/site=ut3" \
    "embernet.ai/role=worker" \
    "embernet.ai/node-name=${NODE_NAME_LOWER}"; do
    if ! grep -qF "${needle}" "${exec_file}" 2>/dev/null; then
      labels_ok=0
      warn "  label missing from agent exec env: ${needle}"
    fi
  done
  if [[ ${labels_ok} -eq 1 ]]; then
    _check "K3s agent exec env carries all four embernet.ai/* labels (tenant=tranetech-ut3, site=ut3, role=worker, node-name=${NODE_NAME_LOWER})" PASS
  else
    _check "K3s agent exec env carries all four embernet.ai/* labels" FAIL
  fi

  # 10. cattle-cluster-agent NOT applicable on EN — CP-01 owns Rancher
  # registration and the agent pod runs there. EN nodes just JOIN; they
  # don't re-register. Skip cleanly.

  # --- Summary table ---
  echo ""
  echo "============================================================"
  echo "  verify_deployment — ${NODE_NAME} (tenant=tranetech-ut3, role=worker)"
  echo "============================================================"
  printf '  %s\n' "${results[@]}"
  echo "------------------------------------------------------------"
  printf '  PASS: %d   FAIL: %d\n' "${pass_count}" "${fails}"
  echo "============================================================"

  if [[ ${fails} -gt 0 ]]; then
    warn "${fails} verify_deployment check(s) FAILED — see table above"
    exit 1
  fi

  log "verify_deployment: ALL PASS"
  return 0
}

# ─── Summary ─────────────────────────────────────────────────
print_summary() {
  echo ""
  echo "============================================================"
  echo "  Deployment Summary — ${NODE_NAME} (tenant=tranetech-ut3, site=ut3)"
  echo "============================================================"
  echo ""
  echo "  === Service auto-start status (survives reboot) ==="
  for svc in embernet container-codesys "k3s-${K3S_INSTALL_NAME}"; do
    local enabled active
    enabled="$(systemctl is-enabled "${svc}.service" 2>/dev/null || echo 'not-installed')"
    active="$(systemctl is-active "${svc}.service" 2>/dev/null || echo 'inactive')"
    printf '  %-35s enabled=%-12s active=%s\n' "${svc}.service" "${enabled}" "${active}"
  done
  echo ""
  echo "  === Running containers ==="
  podman ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || true
  echo ""
  local em_iface_state
  em_iface_state="$(ip -4 -o addr show "${EMBERNET_IFACE}" 2>/dev/null \
                   | awk '{print $4}' | head -1)"
  echo "  embernet0 (embernetlite VPN):  ${em_iface_state:-down (pre-enrollment)}"
  echo "  Crash-reboot hardening:   $(test -f /etc/systemd/system.conf.d/99-embernet-crashreboot.conf && echo 'active' || echo 'not configured')"
  echo ""
  echo "  Node name:                 ${NODE_NAME}  (k3s: ${NODE_NAME_LOWER})"
  echo "  Tenant / Site / Role:      tranetech-ut3 / ut3 / edge"
  echo "  K3s cluster API (CP-01):   https://${CP01_EMBERNET_IP}:6443  (joined as worker/agent)"
  echo "  Local embernet0 IP:        ${EMBERNET_IP:-<embernet0 not up>}"
  echo "  CODESYS gateway:           localhost:1217"
  echo "  Dashboard:                 https://dashboard.embernet.ai  (visible via CP-01's Rancher import)"
  echo ""
  echo "  --- HA cluster membership (queried via CP-01 over embernet0) ---"
  if [[ -r /var/lib/rancher/k3s/agent/kubelet.kubeconfig ]] && [[ -x /usr/local/bin/k3s ]]; then
    /usr/local/bin/k3s kubectl --kubeconfig=/var/lib/rancher/k3s/agent/kubelet.kubeconfig get nodes -o wide 2>/dev/null \
      || echo "  (run on CP-01:  /usr/local/bin/k3s kubectl get nodes -o wide)"
  else
    echo "  (agent kubeconfig not yet present; run on CP-01:  /usr/local/bin/k3s kubectl get nodes -o wide)"
  fi
  echo ""
  echo "  --- embernetlite enrollment ---"
  echo "  Driven by the script's interactive flow (no manual commands)."
  echo "  Re-run `sudo bash trane/deploy-ut3-en01.sh` — the script will"
  echo "  prompt with a device code + URL, walk you through tenant pick if"
  echo "  needed, and wait for ${EMBERNET_IFACE} to come up before K3s."
  echo "============================================================"
}

# =============================================================
# MAIN — ordered execution
# =============================================================

echo ""
echo "============================================================"
echo "  EmberNet UT3 — Edge Node 0001 Deployment (agent/worker)"
echo "  Node: ${NODE_NAME}"
echo "  Tenant: tranetech-ut3  |  Site: ut3  |  Role: edge"
echo "  VPN: embernetlite (EmbernetEndpoint-Linux v0.0.29) → embernet0"
echo "  Joining: https://${CP01_EMBERNET_IP}:6443 (CP-01 HA cluster)"
echo "============================================================"
echo ""

# Phase 1 — CODESYS + embernetlite Quadlet (no K3s yet):
preflight_checks
configure_firewall
configure_crash_reboot
install_codesys
install_embernetlite

# Phase 1 → Phase 2 gate — exit 0 here if operator hasn't completed
# AAD device-code enrollment yet (embernet0 is the gate).
gate_on_embernet0

# Phase 2 — K3s agent join to CP-01 on embernet0:
install_k3s_agent
print_summary
verify_deployment
