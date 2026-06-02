#!/bin/bash
# =============================================================
# EmberNet UT3 — Control Plane 01 Deployment Script
# Node: Trane-UT3-CP-01  |  embernet0 IP: assigned by embernetlite at enrollment
# OS:   Ubuntu 24.04 Server (x86_64)
# Run as root: sudo bash deploy-ut3-cp01.sh
#
# CP-01 is the HA seed of the Trane UT3 K3s cluster:
#   - K3s server `--cluster-init` on the host (NOT containerized)
#   - CP-02 + CP-03 + EN-0001 will later join via
#     `--server https://${EMBERNET_IP}:6443` using the token stored at
#     /etc/embernet/k3s-token (operators copy that token + this node's
#     embernet0 IP across to the joiners as CP01_EMBERNET_IP)
#   - Single Rancher import (this script) covers the whole cluster
#
# VPN: embernetlite (EmbernetEndpoint-Linux v0.0.29) replaces the legacy
# linuxserver/wireguard container. Post-enrollment it brings up
# embernet0; K3s rides on that interface. Two-phase: run once for
# Phase 1 (containers + embernetlite Quadlet), complete operator
# enrollment via AAD device-code browser flow, re-run for Phase 2
# (K3s server install on embernet0).
#
# All non-K3s workloads run as host-level podman containers
# (Quadlet or `podman run` + `podman generate systemd`). No K8s
# pods are scheduled by this script — the cluster starts empty and
# receives App Store apps later from the EmberNet dashboard.
#
# Workloads on CP-01:
#   - embernetlite (Quadlet, ghcr.io/embernet-ai/embernetlite:0.0.29)
#       This IS the VPN: ships its own WireGuard driver and brings up
#       `embernet0` post-enrollment. The operator must complete enrollment
#       via AAD device-code (browser) after Phase 1 finishes. Re-run the
#       script to advance to Phase 2 (K3s install on embernet0).
#   - PostgreSQL 16 (host podman, 127.0.0.1:5432)            [Phase 1]
#   - Ignition Cloud Edition 8.3.4 (host podman, host:8088)  [Phase 1]
#   - CODESYS Control SL 4.20 (host podman, host:1217)       [Phase 1]
#   - K3s server v1.34.5+k3s1 (host install, --cluster-init) [Phase 2]
#   - Rancher import (trane-ut3 cluster)                     [Phase 2]
#
# Reference:
#   - .agent/EXECUTION_PLAN.md § Phase 1
#   - .agent/ARCHITECTURE.md  (mandatory labels, crash-loop gotchas table)
#   - fireball/deploy-embernode-arm64-microos.sh  (canonical two-phase
#                              embernetlite-first / K3s-after pattern)
#   - trane/deploy-ut3-cp02.sh  (architectural sibling)
#   - commit 33b6548  (codesys RCA — the .deb dep + cfg path bugs that
#                      took universaltester004 down silently for 9 days)
# =============================================================

set -euo pipefail

# =============================================================
# CONFIGURATION
# =============================================================

NODE_NAME="Trane-UT3-CP-01"
NODE_NAME_LOWER="trane-ut3-cp-01"
# CP-01's embernet0 IPv4 is assigned by the embernetlite provisioner at
# enrollment time. Phase 2 detects it via `ip -4 addr show embernet0` and
# binds K3s to that address; Phase 1 runs before enrollment and exits
# before K3s install.
EMBERNET_IFACE="embernet0"

# Postgres (CP-01 is the DB owner; CP-02 connects across embernet0)
POSTGRES_USER="ut3"
POSTGRES_PASSWORD="TraneTech01"
POSTGRES_DB="ignition_tranetech"
POSTGRES_IMAGE="docker.io/library/postgres:16"

# Ignition Cloud Edition — same digest CP-02 ships.
# Image is mis-built relative to IA's official Dockerfile: ignition.sh
# line 144 hard-sets RUN_AS_USER=ignition which makes `runuser - ignition`
# fail rc=1 inside the container. CP-02 documents the RCA + the
# entrypoint sed-patch in install_ignition_cloud(); this script mirrors
# it verbatim.
IGNITION_CLOUD_VERSION="8.3.4"
IGNITION_CLOUD_IMAGE="ghcr.io/embernet-ai/ignition-cloud@sha256:b1dc0b6ad1dea0cdd59fbf53c0c2a8262487dcbac42a3ca0c3ee444cc34d8de0"
IGNITION_ADMIN_PASSWORD="TraneTech01"

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
EMBERNET_IMAGE="ghcr.io/embernet-ai/embernetlite:0.0.29"

# K3s — host install, cluster-init (HA seed)
K3S_VERSION="v1.34.5+k3s1"
K3S_INSTALL_NAME="embernet-server"

# Rancher import — trane-ut3 cluster in the EmberNet dashboard.
# Same URL as the prior CP-01 script; covers the whole HA cluster
# (CP-01 + CP-03 + EN-0001). CP-02 has its own separate import URL.
RANCHER_IMPORT_URL="https://clusters.embernet.ai/v3/import/j9wmz6fhclx7vhl4wpvs6hgd475282kg69b9plcjt9bfklcmktqc28_trane-ut3.yaml"

# Embernet-overlay IP that resolves `clusters.embernet.ai` from inside
# the cluster — fallback for cattle-cluster-agent when DNS fails to reach
# Rancher over the public path. Documented in trane/TRANE-UT3-STATUS.md.
RANCHER_EMBERNET_FALLBACK_IP="100.64.0.5"

# =============================================================
# HELPERS — structured logging (matches CP-02 conventions)
# =============================================================

log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
fail() { printf '\n[x] %s\n' "$*" >&2; exit 1; }

# Quadlet generator runs ASYNC off daemon-reload. systemctl restart
# fired immediately can race the generator. This helper retries once
# after a settle. Pattern lifted from CP-02 / deploy-embernet-node-microos.sh.
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

# ─── [1/11] Pre-flight checks ────────────────────────────────
preflight_checks() {
  log "[1/11] Running pre-flight checks..."

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

  # --- Backup resolv.conf ---
  cp /etc/resolv.conf /etc/resolv.conf.embernet-backup 2>/dev/null || true

  # --- DNS validation (gotchas table: empty/symlinked resolv.conf) ---
  log "Verifying host DNS resolves before network-dependent steps"
  if ! getent hosts github.com >/dev/null 2>&1; then
    warn "Host DNS broken — github.com unresolvable. Resetting /etc/resolv.conf."
    if [[ -e /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
      rm -f /etc/resolv.conf
    fi
    printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
    if ! getent hosts github.com >/dev/null 2>&1; then
      fail "Host DNS still broken after reset. Manually fix: echo 'nameserver 8.8.8.8' > /etc/resolv.conf"
    fi
    log "DNS recovered — github.com now resolves"
  else
    log "DNS OK"
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

# ─── [2/11] Firewall (UFW) ───────────────────────────────────
configure_firewall() {
  log "[2/11] Configuring UFW & Network Routing..."

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

  # K3s API server (rides on embernet0 once enrollment completes)
  ufw allow 6443/tcp || true

  # Ignition Cloud (host-side port 8088)
  ufw allow 8088/tcp || true

  # CODESYS gateway
  ufw allow 1217/tcp || true

  # embernet0 (embernetlite-managed WireGuard) is the trusted overlay —
  # K3s API, flannel, kubelet, and inter-controlplane etcd all ride on it.
  ufw allow in on embernet0 || true
  # K3s internal interfaces (cni0, flannel.1) trust-pattern from CP-02
  ufw allow in on cni0 || true
  ufw allow in on flannel.1 || true
  ufw route allow in on cni0 out on "${WAN}" || true

  ufw reload || true

  log "[2/11] Firewall configured"
}

# ─── [3/11] Crash-reboot hardening ───────────────────────────
# Gotchas table: PID-1 systemd crash on a headless host = manual
# power-cycle. CrashAction=reboot makes recovery automatic.
configure_crash_reboot() {
  log "[3/11] Configuring systemd PID 1 crash-reboot hardening..."

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
# embernet0 in the host netns and Phase 2 of this script binds K3s to it.)

# ─── [4/11] PostgreSQL 16 (host podman) ──────────────────────
# CP-01 is the DB owner for the Trane UT3 fleet. CP-02 reaches this
# DB over embernet0 (jdbc:postgresql://${CP01_EMBERNET_IP}:5432/ignition_tranetech).
# Bound to all-host-net via --network=host so embernet0 peers reach 5432;
# UFW still enforces source-IP gating.
install_postgres() {
  log "[4/11] Starting PostgreSQL..."

  # Detect fresh data dir — the entrypoint creates POSTGRES_DB on first
  # init only; subsequent runs silently ignore POSTGRES_DB env. (Same
  # detection pattern as CP-02 install_postgres.)
  local data_dir_was_fresh=1
  if [[ -s /opt/embernet/postgres/data/PG_VERSION ]]; then
    data_dir_was_fresh=0
  fi

  if container_already_running postgres; then
    log "[4/11] PostgreSQL already running — skipping"
    return 0
  fi

  # Tear down orphan Quadlet from a prior failed iteration
  if [[ -f /etc/containers/systemd/ut3-postgres.container ]]; then
    log "Removing leftover ut3-postgres.container Quadlet"
    rm -f /etc/containers/systemd/ut3-postgres.container
    systemctl daemon-reload 2>/dev/null || true
  fi

  podman run -d \
    --name postgres \
    --restart=always \
    --network=host \
    -e POSTGRES_USER="${POSTGRES_USER}" \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    -e POSTGRES_DB="${POSTGRES_DB}" \
    -v /opt/embernet/postgres/data:/var/lib/postgresql/data \
    "${POSTGRES_IMAGE}"

  # Wait until the REAL server is up AND POSTGRES_DB authenticates.
  # pg_isready returns OK against the temp init server (no POSTGRES_DB
  # yet) and races docker_setup_db. `psql -d POSTGRES_DB SELECT 1`
  # only succeeds post-init. (Same pattern as CP-02.)
  local pg_wait=0
  while [[ ${pg_wait} -lt 60 ]]; do
    if podman exec postgres psql -U "${POSTGRES_USER}" \
         -d "${POSTGRES_DB}" -tAc 'SELECT 1' >/dev/null 2>&1; then
      break
    fi
    sleep 1
    pg_wait=$((pg_wait + 1))
  done

  log "[4/11] PostgreSQL: $(podman ps --filter name=postgres --format '{{.Status}}')"

  # Legacy-data-dir fallback: if data dir existed before but POSTGRES_DB
  # was missing (e.g. operator changed the DB name), create it.
  if [[ ${data_dir_was_fresh} -eq 0 ]]; then
    log "Ensuring '${POSTGRES_DB}' database exists (pre-existing data dir)..."
    if podman exec postgres psql -U "${POSTGRES_USER}" -tAc \
         "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'" 2>/dev/null | grep -q 1; then
      log "  database '${POSTGRES_DB}' already exists"
    else
      log "  database '${POSTGRES_DB}' missing — creating now..."
      podman exec postgres createdb -U "${POSTGRES_USER}" -O "${POSTGRES_USER}" "${POSTGRES_DB}" \
        || warn "createdb failed — diagnose with: podman exec postgres psql -U postgres -c '\\l'"
    fi
  else
    log "  database '${POSTGRES_DB}' created by postgres entrypoint on first init"
  fi

  podman generate systemd --name postgres --new --restart-policy=always \
    > /etc/systemd/system/container-postgres.service 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable container-postgres.service 2>/dev/null || true
}

# ─── [5/11] Ignition Cloud Edition (host podman, host:8088) ──
# Same image digest CP-02 uses; same RUN_AS_USER entrypoint patch.
# Bound to host:8088 (no port remap — CP-01 doesn't co-host Edge).
install_ignition_cloud() {
  log "[5/11] Starting Ignition Cloud Edition ${IGNITION_CLOUD_VERSION}..."

  # Stream full pull output so layer download progress is visible
  if ! podman pull "${IGNITION_CLOUD_IMAGE}"; then
    warn "[5/11] Cloud image ${IGNITION_CLOUD_IMAGE} not available —"
    warn "  check status: gh run list --repo Embernet-ai/ignition-packages --workflow build-cloud.yml"
    warn "  re-run this script when the image is published."
    return 0
  fi

  if container_already_running ignition-cloud; then
    log "[5/11] Ignition Cloud already running — skipping"
    return 0
  fi

  if [[ -f /etc/containers/systemd/ut3-ignition-cloud.container ]]; then
    rm -f /etc/containers/systemd/ut3-ignition-cloud.container
    systemctl daemon-reload 2>/dev/null || true
  fi

  # First-run seed of data dir from image. Empty bind-mount masks the
  # in-image /usr/local/bin/ignition/data tree (IA forum 111259 / staff
  # Kevin Collins). --network=none on the seed container — no network
  # needed, avoids `CNI network "podman" not found` on Ubuntu 24.04.
  if [[ ! -f /opt/embernet/ignition-cloud/data/.embernet-seeded ]]; then
    log "First-run: seeding /opt/embernet/ignition-cloud/data from image..."
    if podman run --rm \
         --network=none \
         --entrypoint /bin/bash \
         -v /opt/embernet/ignition-cloud/data:/seed \
         "${IGNITION_CLOUD_IMAGE}" \
         -c 'cp -an /usr/local/bin/ignition/data/. /seed/ 2>/dev/null && chmod +x /seed/*.sh /seed/**/*.sh 2>/dev/null; touch /seed/.embernet-seeded'; then
      find /opt/embernet/ignition-cloud/data -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
      log "  seeded $(du -sh /opt/embernet/ignition-cloud/data 2>/dev/null | cut -f1)"
    else
      warn "Seed step failed — first start may crash. Manually seed with:"
      warn "  podman run --rm --network=none -v /opt/embernet/ignition-cloud/data:/seed --entrypoint /bin/bash ${IGNITION_CLOUD_IMAGE} -c 'cp -an /usr/local/bin/ignition/data/. /seed/'"
    fi
  else
    log "Cloud data dir already seeded — preserving operator state"
  fi

  # Entrypoint sed-patch: the ghcr image hard-sets RUN_AS_USER=ignition
  # at line 144 of ignition.sh which makes `runuser - ignition` fail
  # rc=1 in the container. Override entrypoint to flip it to the IA
  # standard `#RUN_AS_USER=` (commented), then exec ignition.sh as
  # root. (Same patch as CP-02 install_ignition_cloud.)
  podman run -d \
    --name ignition-cloud \
    --restart=always \
    --network=host \
    -e ACCEPT_IGNITION_EULA=Y \
    -e GATEWAY_ADMIN_PASSWORD="${IGNITION_ADMIN_PASSWORD}" \
    -e GATEWAY_HTTP_PORT=8088 \
    -e GATEWAY_HTTPS_PORT=8043 \
    -e GATEWAY_GAN_PORT=8060 \
    -v /opt/embernet/ignition-cloud/data:/usr/local/bin/ignition/data \
    --entrypoint /usr/bin/tini \
    "${IGNITION_CLOUD_IMAGE}" \
    -- /bin/bash -c 'set -e; sed -i "s/^RUN_AS_USER=ignition/#RUN_AS_USER=/" /usr/local/bin/ignition/ignition.sh; cd /usr/local/bin/ignition; ./ignition.sh start; sleep 8; mkdir -p logs; touch logs/wrapper.log; exec tail -F logs/wrapper.log'

  podman generate systemd --name ignition-cloud --new --restart-policy=always \
    > /etc/systemd/system/container-ignition-cloud.service 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable container-ignition-cloud.service 2>/dev/null || true

  # Wait for gateway to bind 8088
  local cloud_wait=0
  while [[ ${cloud_wait} -lt 60 ]]; do
    if curl -sf http://localhost:8088/ >/dev/null 2>&1 \
       || ss -tlnp 2>/dev/null | grep -q ':8088'; then
      log "[5/11] Ignition Cloud: active — http://localhost:8088"
      return 0
    fi
    sleep 2
    cloud_wait=$((cloud_wait + 2))
  done

  warn "[5/11] Ignition Cloud started but not responding after 60s — check: podman logs ignition-cloud"
}

# ─── [6/11] CODESYS Control SL 4.20 (host podman, host:1217) ─
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
# 33b6548 — these are dearly-bought lessons.
install_codesys() {
  log "[6/11] Starting CODESYS Control SL ${CODESYS_VERSION}..."

  if container_already_running codesys; then
    # Verify it's NOT running `sleep infinity` (the 33b6548 RCA signature)
    local pid1
    pid1=$(podman top codesys 2>/dev/null | awk 'NR==2 {print $NF}' || true)
    if [[ "${pid1}" == *"sleep"* ]]; then
      warn "Codesys is Up but PID 1 = '${pid1}' — recreating (33b6548 signature)"
      podman rm -f codesys >/dev/null 2>&1 || true
    else
      log "[6/11] Codesys already running (PID 1: ${pid1}) — skipping rebuild"
      return 0
    fi
  fi

  # Tear down legacy host-install artifacts from the pre-rewrite CP-01
  # script (idempotent — silent if absent).
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
      warn "[6/11] Codesys download failed — skipping"
      rm -rf "${BUILD_DIR}"
      return 0
    fi

    local pkg_size
    pkg_size=$(stat -c%s "${BUILD_DIR}/codesys.pkg" 2>/dev/null || echo 0)
    if [[ ${pkg_size} -lt 1024 ]]; then
      warn "[6/11] Codesys download truncated (${pkg_size} bytes) — skipping"
      rm -rf "${BUILD_DIR}"
      return 0
    fi

    # ──────────────────────────────────────────────────────────────
    # Containerfile — POST-33b6548 hardened pattern. See function
    # header comment for the full RCA.
    # ──────────────────────────────────────────────────────────────
    cat > "${BUILD_DIR}/Containerfile" <<'DOCKERFILE'
FROM docker.io/library/debian:bookworm-slim
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
RUN set -eo pipefail \
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
RUN set -eo pipefail; \
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
      warn "[6/11] Codesys container build failed — skipping"
      rm -rf "${BUILD_DIR}"
      return 0
    fi
    rm -rf "${BUILD_DIR}"
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

  log "[6/11] Codesys: $(podman ps --filter name=codesys --format '{{.Status}}' 2>/dev/null || echo 'starting')"
}

# ─── [7/11] embernetlite (EmbernetEndpoint-Linux, Quadlet) ───
# embernetlite IS the VPN at v0.0.29 — it ships its own WireGuard driver
# and brings up `embernet0` in the host netns post-enrollment. K3s
# `--flannel-iface=embernet0` rides on that interface (Phase 2).
# Quadlet body taken verbatim from embernetlite-linux/packaging/
# quadlet/embernet.container (the v0.0.29 fix-set: Pull=newer NOT
# PullPolicy=newer, NO EnvironmentFile=).
#
# Two-phase semantics (mirrors fireball/deploy-embernode-arm64-microos.sh):
#   Phase 1 (this function + workload containers): drop the Quadlet,
#     start embernet.service. If embernet0 is NOT up yet,
#     gate_on_embernet0 prints enrollment instructions and exit 0s.
#   Phase 2 (re-run after operator completes AAD device-code login):
#     embernet0 detected with an IPv4 → K3s installs against it.
install_embernetlite() {
  log "[7/11] Installing embernetlite (Quadlet, ${EMBERNET_IMAGE})..."

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

  # Idempotency gate — Quadlet generator names the unit `embernet`;
  # the container itself is `systemd-embernet`.
  if container_already_running systemd-embernet; then
    log "[7/11] embernetlite already running — skipping"
    return 0
  fi

  # Drop the Quadlet. Body matches embernetlite-linux/packaging/quadlet/
  # embernet.container at v0.0.29 with one change: Image pinned to
  # ${EMBERNET_IMAGE} (vs :stable) for reproducible deploys.
  cat > /etc/containers/systemd/embernet.container <<QUADLET
# Quadlet — embernetlite v0.0.29
# Generated by trane/deploy-ut3-cp01.sh
# DO NOT edit in place — re-run the deploy script to update.

[Unit]
Description=EmberNET Endpoint (embernetlite)
Documentation=https://embernet.ai/docs/endpoint
After=network.target

StartLimitIntervalSec=300
StartLimitBurst=20

[Container]
Image=${EMBERNET_IMAGE}

# --network=host: embernetlite IS the host's overlay networking.
Network=host

AddCapability=CAP_NET_ADMIN
AddCapability=CAP_NET_RAW
DropCapability=all

AddDevice=/dev/net/tun

Volume=/etc/embernet:/etc/embernet:ro,Z
Volume=/var/lib/embernet:/var/lib/embernet:Z
Volume=/var/log/embernet:/var/log/embernet:Z
Volume=/run/embernet:/run/embernet:Z

# Key is Pull=, NOT PullPolicy= — Quadlet rename in podman 5.x.
# (Older spelling is rejected; the .service unit never gets generated.)
Pull=newer

# (No EnvironmentFile= at v0.0.29 — podman exits 125 on missing
# file. Restore once a required env var lands.)

HealthCmd=embernetctl status
HealthInterval=30s
HealthTimeout=5s
HealthStartPeriod=15s
HealthRetries=3

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
QUADLET

  # Quadlet generator races daemon-reload. Use the helper.
  quadlet_restart embernet.service

  # Don't fail if the container is still starting — it can take a
  # minute on first pull. verify_deployment() is the gate.
  log "[7/11] embernetlite Quadlet installed (systemd unit: embernet.service)"
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
  log "[8/11] Gating on ${EMBERNET_IFACE} (Phase 1 → Phase 2 transition)..."

  if ip -4 addr show "${EMBERNET_IFACE}" 2>/dev/null | grep -q 'inet '; then
    EMBERNET_IP="$(ip -4 -o addr show "${EMBERNET_IFACE}" \
                   | awk '{print $4}' | cut -d/ -f1 | head -1)"
    if [[ -z "${EMBERNET_IP}" ]]; then
      fail "${EMBERNET_IFACE} is up but no IPv4 address parsed — investigate: ip -4 addr show ${EMBERNET_IFACE}"
    fi
    log "[8/11] ${EMBERNET_IFACE} is up — IPv4 ${EMBERNET_IP}. Proceeding with Phase 2 (K3s)."
    return 0
  fi

  local AUTH_TOKEN=""
  if [[ -s /var/lib/embernet/auth.token ]]; then
    AUTH_TOKEN="$(cat /var/lib/embernet/auth.token 2>/dev/null || true)"
  fi

  echo ""
  echo "============================================================"
  echo "  PHASE 1 COMPLETE — ${NODE_NAME} is NOT YET enrolled"
  echo "============================================================"
  cat <<INSTRUCTIONS

  The host containers (Postgres, Ignition Cloud, CODESYS) are up and
  embernetlite is running, but ${EMBERNET_IFACE} is not present yet —
  embernetlite is waiting for the operator to complete enrollment.

  Complete the AAD device-code enrollment from this box:

      podman exec systemd-embernet embernetlite enroll \\
          --device-code-only --device-name ${NODE_NAME}

  Follow the device-code link in a browser, sign in, pick the tenant.
  When enrollment finishes, embernetlite will bring up ${EMBERNET_IFACE}.

  Then re-run this script to advance to Phase 2 (K3s install on
  ${EMBERNET_IFACE} + Rancher import):

      sudo bash trane/deploy-ut3-cp01.sh

  auth.token (for the loopback API on 127.0.0.1:8765):
      ${AUTH_TOKEN:-<not yet written — daemon still starting>}

INSTRUCTIONS
  echo "============================================================"
  exit 0
}

# ─── [9/11] K3s server (host install, --cluster-init) ────────
# CP-01 is the HA seed of the trane-ut3 cluster. CP-02 + CP-03 + EN-0001
# join later via `--server https://${EMBERNET_IP}:6443` (this node's
# embernet0 IP) using the token this function writes to
# /etc/embernet/k3s-token. Operators copy both the token AND
# ${EMBERNET_IP} (as CP01_EMBERNET_IP) onto the joiner boxes.
install_k3s_server() {
  log "[9/11] Initializing EmberNet UT3 cluster (K3s host install, --cluster-init)..."

  # --- Resolve host LAN IP for --tls-san so kubeconfig users on the
  # same subnet — operator laptop, EIP, etc. — can talk to the API
  # without going over embernet0.
  #
  # Auto-detect first global non-embernet0 IPv4. On AWS this is the VPC
  # private IP; if you need the EIP (or any other address) in the
  # SAN list, set HOST_TLS_SAN before running the script.
  #
  #   HOST_TLS_SAN=<addr>  sudo -E bash trane/deploy-ut3-cp01.sh
  local HOST_LAN_IP
  if [[ -n "${HOST_TLS_SAN:-}" ]]; then
    HOST_LAN_IP="${HOST_TLS_SAN}"
    log "Using HOST_TLS_SAN override: ${HOST_LAN_IP}"
  else
    HOST_LAN_IP=$(ip -4 -o addr show scope global \
                  | awk '$2 != "embernet0" {print $4}' \
                  | cut -d/ -f1 \
                  | head -1)
    if [[ -z "${HOST_LAN_IP}" ]]; then
      HOST_LAN_IP="${EMBERNET_IP}"
    fi
    log "Auto-detected HOST_LAN_IP for --tls-san: ${HOST_LAN_IP} (override via HOST_TLS_SAN env var)"
  fi

  # --- Pre-flight: clean up wedged K3s state if present ---
  local needs_wipe=0
  if [[ -x /usr/local/bin/k3s ]] \
     && ! systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}" 2>/dev/null \
     && ! systemctl is-active --quiet k3s 2>/dev/null; then
    needs_wipe=1
    log "Detected wedged K3s: /usr/local/bin/k3s present but no active k3s unit"
  fi
  if [[ "${K3S_FORCE_WIPE:-0}" == "1" ]]; then
    needs_wipe=1
    log "K3S_FORCE_WIPE=1 — wiping K3s state regardless of current health"
  fi
  if [[ ${needs_wipe} -eq 1 ]]; then
    log "Running canonical K3s uninstall + state wipe..."
    if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
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

  # --- Reuse or generate the shared cluster token ---
  if [[ -f /etc/embernet/k3s-token ]]; then
    K3S_TOKEN="$(cat /etc/embernet/k3s-token)"
    log "Reusing existing K3s token from /etc/embernet/k3s-token"
  else
    K3S_TOKEN="$(openssl rand -hex 32)"
    echo "${K3S_TOKEN}" > /etc/embernet/k3s-token
    chmod 600 /etc/embernet/k3s-token
    log "Generated new K3s token at /etc/embernet/k3s-token"
  fi

  # --- Install K3s server if not already healthy ---
  if [[ -x /usr/local/bin/k3s ]] \
     && systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}" 2>/dev/null; then
    log "K3s already installed and active — skipping reinstall"
  else
    log "Installing K3s server (host binary + systemd service)"
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="${K3S_VERSION}" \
      INSTALL_K3S_NAME="${K3S_INSTALL_NAME}" \
      K3S_TOKEN="${K3S_TOKEN}" \
      sh -s - server \
        --cluster-init \
        --node-name="${NODE_NAME_LOWER}" \
        --node-ip="${EMBERNET_IP}" \
        --flannel-iface=embernet0 \
        --tls-san="${EMBERNET_IP}" \
        --tls-san="${HOST_LAN_IP}" \
        --disable=traefik \
        --node-label="embernet.ai/tenant=tranetech-ut3" \
        --node-label="embernet.ai/site=ut3" \
        --node-label="embernet.ai/role=control-plane" \
        --node-label="embernet.ai/node-name=${NODE_NAME_LOWER}"
  fi

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  log "Waiting for K3s to be Ready (max 180s)..."
  local k3s_wait=0
  local k3s_max=180
  while [[ ${k3s_wait} -lt ${k3s_max} ]]; do
    if /usr/local/bin/k3s kubectl get nodes 2>/dev/null | grep -q "Ready"; then
      break
    fi
    sleep 5
    k3s_wait=$((k3s_wait + 5))
  done

  if /usr/local/bin/k3s kubectl get nodes 2>/dev/null | grep -q "Ready"; then
    log "[9/11] K3s server: Ready (systemd unit: k3s-${K3S_INSTALL_NAME}.service)"
  else
    warn "[9/11] K3s server: not yet Ready"
    warn "Check: journalctl -xeu k3s-${K3S_INSTALL_NAME} --no-pager -n 50"
  fi
}

# ─── [10/11] Rancher import ──────────────────────────────────
# Single import for the whole HA cluster (CP-01 + CP-03 + EN-0001).
# CP-02 has its own separate import. Patches STRICT_VERIFY=false and
# hostAliases for clusters.embernet.ai via the WG fallback IP — both
# per ARCHITECTURE.md § Rancher import.
import_rancher() {
  log "[10/11] Registering with EmberNet dashboard (Rancher import)..."

  # Idempotency gate
  if /usr/local/bin/k3s kubectl get namespace cattle-system >/dev/null 2>&1 \
     && /usr/local/bin/k3s kubectl -n cattle-system get deployment cattle-cluster-agent >/dev/null 2>&1; then
    log "Rancher: cattle-cluster-agent already deployed in cattle-system — skipping re-apply"
    # Still ensure the STRICT_VERIFY + hostAliases patches are in place
    # (operator may have wiped & re-imported).
  else
    local rancher_ok=false
    for attempt in 1 2 3; do
      if /usr/local/bin/k3s kubectl apply -f "${RANCHER_IMPORT_URL}" 2>/dev/null; then
        rancher_ok=true
        break
      fi
      if [[ ${attempt} -eq 2 ]]; then
        if /usr/local/bin/k3s kubectl apply -f "${RANCHER_IMPORT_URL}" --insecure-skip-tls-verify 2>/dev/null; then
          rancher_ok=true
          break
        fi
      fi
      warn "Rancher import attempt ${attempt}/3 failed — retrying in 10s..."
      sleep 10
    done

    if [[ "${rancher_ok}" == true ]]; then
      log "Rancher import: applied"
    else
      warn "Rancher import: all attempts failed — register manually later:"
      warn "  sudo /usr/local/bin/k3s kubectl apply -f ${RANCHER_IMPORT_URL}"
      return 0
    fi
  fi

  # --- Patch: STRICT_VERIFY=false (LE cert path) ---
  log "Rancher: patching cattle-cluster-agent STRICT_VERIFY=false..."
  local patched=false
  for attempt in 1 2 3; do
    if /usr/local/bin/k3s kubectl -n cattle-system get deploy cattle-cluster-agent >/dev/null 2>&1; then
      if /usr/local/bin/k3s kubectl -n cattle-system set env deploy/cattle-cluster-agent STRICT_VERIFY=false >/dev/null 2>&1; then
        patched=true
        break
      fi
    fi
    warn "  STRICT_VERIFY patch attempt ${attempt}/3 — cattle-cluster-agent not yet deployed, retrying in 10s..."
    sleep 10
  done
  if [[ "${patched}" == true ]]; then
    log "Rancher: STRICT_VERIFY=false applied"
  else
    warn "Rancher: could not patch STRICT_VERIFY — run manually:"
    warn "  sudo /usr/local/bin/k3s kubectl -n cattle-system set env deploy/cattle-cluster-agent STRICT_VERIFY=false"
  fi

  # --- Patch: hostAliases for clusters.embernet.ai → ${RANCHER_EMBERNET_FALLBACK_IP} ---
  # The agent needs to resolve clusters.embernet.ai even when public
  # DNS is unreachable from inside the cluster. hostAliases injects
  # /etc/hosts entries into the pod.
  log "Rancher: patching cattle-cluster-agent hostAliases (clusters.embernet.ai → ${RANCHER_EMBERNET_FALLBACK_IP})..."
  local ha_patched=false
  local ha_json
  ha_json=$(cat <<EOF
{"spec":{"template":{"spec":{"hostAliases":[{"ip":"${RANCHER_EMBERNET_FALLBACK_IP}","hostnames":["clusters.embernet.ai"]}]}}}}
EOF
  )
  for attempt in 1 2 3; do
    if /usr/local/bin/k3s kubectl -n cattle-system get deploy cattle-cluster-agent >/dev/null 2>&1; then
      if /usr/local/bin/k3s kubectl -n cattle-system patch deploy cattle-cluster-agent \
            --type=strategic --patch "${ha_json}" >/dev/null 2>&1; then
        ha_patched=true
        break
      fi
    fi
    warn "  hostAliases patch attempt ${attempt}/3 — retrying in 10s..."
    sleep 10
  done
  if [[ "${ha_patched}" == true ]]; then
    log "Rancher: hostAliases applied"
  else
    warn "Rancher: could not patch hostAliases — run manually:"
    warn "  sudo /usr/local/bin/k3s kubectl -n cattle-system patch deploy cattle-cluster-agent --type=strategic --patch '${ha_json}'"
  fi
}

# ─── [11/11] verify_deployment — the gate ────────────────────
# Each check prints `[PASS]` or `[FAIL]` followed by the check name.
# Returns 0 if ALL pass, exits 1 otherwise. This is the Phase 1
# exit-criteria gate.
verify_deployment() {
  log "[11/11] Verifying deployment..."

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
      _check "embernetlite API /api/v1/health responding — FAILED (pre-enrollment? complete AAD device-code login at https://login.microsoftonline.com/device using the user_code from \`podman exec systemd-embernet embernetlite enroll --device-code-only --device-name ${NODE_NAME}\`)" FAIL
    fi
  else
    _check "embernetlite API /api/v1/health responding — FAILED (auth.token not generated yet; daemon not started or pre-enrollment; complete enrollment via \`podman exec systemd-embernet embernetlite enroll --device-code-only --device-name ${NODE_NAME}\`)" FAIL
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

  # 8. K3s node Ready
  local node_ready
  node_ready=$(/usr/local/bin/k3s kubectl get node "${NODE_NAME_LOWER}" \
               -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [[ "${node_ready}" == "True" ]]; then
    _check "K3s node ${NODE_NAME_LOWER} Ready=True" PASS
  else
    _check "K3s node ${NODE_NAME_LOWER} Ready=${node_ready}" FAIL
  fi

  # 9. K3s node carries all four embernet.ai/* labels
  local labels_ok=1
  local label_json
  label_json=$(/usr/local/bin/k3s kubectl get node "${NODE_NAME_LOWER}" -o json 2>/dev/null \
              | jq -r '.metadata.labels // {}' 2>/dev/null || echo '{}')
  for kv in \
    'embernet.ai/tenant=tranetech-ut3' \
    'embernet.ai/site=ut3' \
    'embernet.ai/role=control-plane' \
    "embernet.ai/node-name=${NODE_NAME_LOWER}"; do
    local k v
    k="${kv%%=*}"
    v="${kv##*=}"
    local actual
    actual=$(echo "${label_json}" | jq -r --arg k "${k}" '.[$k] // ""' 2>/dev/null)
    if [[ "${actual}" != "${v}" ]]; then
      labels_ok=0
      warn "  label mismatch: ${k} expected=${v} actual='${actual}'"
    fi
  done
  if [[ ${labels_ok} -eq 1 ]]; then
    _check "K3s node carries all four embernet.ai/* labels (tenant=tranetech-ut3, site=ut3, role=control-plane, node-name=${NODE_NAME_LOWER})" PASS
  else
    _check "K3s node carries all four embernet.ai/* labels" FAIL
  fi

  # 10. Rancher cattle-cluster-agent Running
  if /usr/local/bin/k3s kubectl -n cattle-system get pods \
       -l app=cattle-cluster-agent \
       --field-selector=status.phase=Running \
       -o name 2>/dev/null | grep -q .; then
    _check "Rancher cattle-cluster-agent pod Running (tenant=tranetech-ut3)" PASS
  else
    _check "Rancher cattle-cluster-agent pod Running (tenant=tranetech-ut3)" FAIL
  fi

  # --- Summary table ---
  echo ""
  echo "============================================================"
  echo "  verify_deployment — Trane-UT3-CP-01 (tenant=tranetech-ut3)"
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
  for svc in embernet container-postgres container-ignition-cloud container-codesys "k3s-${K3S_INSTALL_NAME}"; do
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
  echo "  Tenant / Site:             tranetech-ut3 / ut3"
  echo "  K3s API:                   https://${EMBERNET_IP:-<embernet0 not up>}:6443 (trane-ut3 HA cluster)"
  echo "  K3s token (CP-02 / CP-03 / EN-0001 joiners):"
  echo "    $(cat /etc/embernet/k3s-token 2>/dev/null || echo '  not generated')"
  echo "  Ignition Cloud UI:         http://localhost:8088   (admin / ${IGNITION_ADMIN_PASSWORD})"
  echo "  CODESYS gateway:           localhost:1217"
  echo "  Postgres (host):           localhost:5432  (user=${POSTGRES_USER}, db=${POSTGRES_DB})"
  echo "  Dashboard:                 https://dashboard.embernet.ai"
  echo ""
  echo "  --- Next: bring up CP-02 + CP-03 + EN-0001 (HA join) ---"
  echo "  On each joiner: grab /etc/embernet/k3s-token from this node,"
  echo "  set CP01_EMBERNET_IP=${EMBERNET_IP:-<this-cp01-embernet0-ip>}, then run the matching"
  echo "  trane/deploy-ut3-cp0X.sh (or deploy-ut3-en01.sh)."
  echo ""
  echo "  --- embernetlite enrollment (manual operator step) ---"
  echo "  v0.0.29 uses AAD device-code enrollment. Complete via browser:"
  echo "    podman exec -it systemd-embernet embernetlite enroll \\"
  echo "        --device-code-only --device-name ${NODE_NAME}"
  echo "  Until enrollment completes, embernet0 is NOT up and K3s install"
  echo "  is gated off (Phase 1 / Phase 2 split — re-run after enrolling)."
  echo "============================================================"
}

# =============================================================
# MAIN — ordered execution
# =============================================================

echo ""
echo "============================================================"
echo "  EmberNet UT3 — Control Plane 01 Deployment (HA seed)"
echo "  Node: ${NODE_NAME}"
echo "  Tenant: tranetech-ut3  |  Site: ut3"
echo "  VPN: embernetlite (EmbernetEndpoint-Linux v0.0.29) → embernet0"
echo "============================================================"
echo ""

# Phase 1 — host containers + embernetlite Quadlet (no K3s yet):
preflight_checks
configure_firewall
configure_crash_reboot
install_postgres
install_ignition_cloud
install_codesys
install_embernetlite

# Phase 1 → Phase 2 gate — exit 0 here if operator hasn't completed
# AAD device-code enrollment yet (embernet0 is the gate).
gate_on_embernet0

# Phase 2 — K3s on embernet0, then Rancher import:
install_k3s_server
import_rancher
print_summary
verify_deployment
