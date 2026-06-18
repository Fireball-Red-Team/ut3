#!/bin/bash
# =============================================================
# EmberNet UT3 — Control Plane 01 Deployment Script
# Node: Trane-UT3-CP-01  |  embernet0 IP: assigned by embernetlite at enrollment
# OS:   Ubuntu 22.04 LTS Jammy (x86_64) — Trane standardises on 22.04
# Run as root: sudo bash deploy-ut3-cp01.sh
#
# CP-01 joins CP-02's existing HA K3s cluster as a second control plane.
# (CP-02 was the seed — `--cluster-init` ran THERE on 2026-06-17. The
# trane-ut3 cluster ID is c-m-dmm27fqs.)
#   - K3s server in JOIN mode on the host: K3S_URL=https://${SEED_EMBERNET_IP}:6443
#     (NOT containerized, NOT `--cluster-init`)
#   - K3s join token MUST be pre-staged at /etc/embernet/k3s-token from
#     CP-02 before Phase 2. The function fails fast with copy
#     instructions if it's missing.
#   - SEED_EMBERNET_IP defaults to 100.64.0.38 (CP-02's actual embernet0
#     IP as of 2026-06-17). Override only if CP-02 was renumbered.
#   - Rancher import is cluster-wide (one CR per cluster) — already in
#     place from CP-02's install; this script's import is idempotent.
#
# Redeploying over a stale --cluster-init install: set K3S_FORCE_WIPE=1
# to nuke /var/lib/rancher + uninstall the old controller before the new
# join. The wedge auto-detector only catches inactive K3s; a stale-but-
# running seed-cluster requires the explicit flag.
#
#   K3S_FORCE_WIPE=1 sudo -E bash trane/deploy-ut3-cp01.sh
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
#   - embernetlite (Quadlet, ghcr.io/embernet-ai/embernetlite:0.0.36)
#       This IS the VPN: ships its own WireGuard driver and brings up
#       `embernet0` post-enrollment. The operator must complete enrollment
#       via AAD device-code (browser) after Phase 1 finishes. Re-run the
#       script to advance to Phase 2 (K3s install on embernet0).
#   - PostgreSQL 16 (host podman, 127.0.0.1:5432)            [Phase 1]
#   - Ignition Cloud Edition 8.3.4 (host podman, host:8088)  [Phase 1]
#   - CODESYS Control SL 4.20 (host podman, host:1217)       [Phase 1]
#   - K3s server v1.34.5+k3s1 (host install, JOIN to CP-02 seed)  [Phase 2]
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

NODE_NAME="${NODE_NAME:-Trane-UT3-CP-01}"
NODE_NAME_LOWER="$(printf '%s' "${NODE_NAME}" | tr '[:upper:]' '[:lower:]')"
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
EMBERNET_IMAGE="ghcr.io/embernet-ai/embernetlite:0.0.43"

# K3s — host install, JOINs CP-02's existing HA cluster (CP-02 is the
# trane-ut3 seed; CP-01 + CP-03 are sibling control planes that join
# its embedded etcd over embernet0).
K3S_VERSION="v1.34.5+k3s1"
K3S_INSTALL_NAME="embernet-server"
K3S_TOKEN_FILE="/etc/embernet/k3s-token"

# Embernet0 IP of the existing CP-02 seed. CP-01 joins K3s at this
# address. Override only if you redeployed CP-02 onto a different
# embernet0 IP (default matches CP-02's actual assignment 2026-06-17).
SEED_EMBERNET_IP="${SEED_EMBERNET_IP:-100.64.0.38}"
SEED_NODE_NAME="${SEED_NODE_NAME:-Trane-UT3-CP-02}"

# Rancher import — trane-ut3 cluster in the EmberNet dashboard.
# Same URL as the prior CP-01 script; covers the whole HA cluster
# (CP-01 + CP-03 + EN-0001). CP-02 has its own separate import URL.
RANCHER_IMPORT_URL="https://clusters.embernet.ai/v3/import/fzd6plf5sdprk7mkgcs924x99g685mgrfl94qbswgrpbgc8t9cq28x_c-m-dmm27fqs.yaml"

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
  apt-get install -y curl wget openssl podman dnsutils jq iproute2 ufw wireguard-tools

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
  #
  # IMPORTANT: connect to `-d postgres` (the always-present admin DB),
  # not the default DB which matches the username. Without -d, psql
  # tries to connect to a DB named '${POSTGRES_USER}' which doesn't
  # exist for our 'ut3' user — the SELECT then errored silently and
  # we fell through to createdb, which itself failed because the DB
  # actually DID exist. The user saw a misleading
  # "createdb failed — already exists" warning on re-runs.
  if [[ ${data_dir_was_fresh} -eq 0 ]]; then
    log "Ensuring '${POSTGRES_DB}' database exists (pre-existing data dir)..."
    if podman exec postgres psql -U "${POSTGRES_USER}" -d postgres -tAc \
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
      warn "[6/11] Codesys container build failed — skipping"
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
# ─── self-heal: detect stale embernet enrollment + wipe ──────
# On a RE-RUN of this script (operator bumps NODE_NAME, hub rotates the
# stale peer entry, a prior enrollment never fully registered, etc.),
# the daemon may come up against persisted state from /var/lib/embernet
# but the kernel WireGuard handshake against the hub never completes —
# the public key on disk is no longer in the hub's peer table.
#
# Live signature seen on ark-3533 during EN-0001 install 2026-06-04:
#   sudo wg show embernet0
#   peer: <hub-pubkey>
#     transfer: 0 B received, 9.25 KiB sent      <- outbound only, hub silent
#     (NO "latest handshake:" line at all)
#
# This function probes that exact state and, when it sees it, wipes the
# stale state files + removes the container so install_embernetlite
# re-creates a fresh daemon that runs through AAD device-code enrollment
# from scratch — minting a fresh keypair the provisioner registers
# cleanly with the hub.
#
# Idempotent: on a TRULY fresh box (no embernet0, no container, no
# auth.token), this is a no-op. Only fires when the symptom matches.
heal_stale_embernet_enrollment() {
  # No prior enrollment state → nothing to heal
  if [[ ! -f /var/lib/embernet/auth.token ]] && [[ ! -f /var/lib/embernet/endpoint.id ]]; then
    return 0
  fi
  # No embernet0 interface → daemon hasn't tried to come up yet, let
  # install_embernetlite handle the cold start
  if ! ip link show embernet0 >/dev/null 2>&1; then
    return 0
  fi
  # No container → already torn down; install_embernetlite will rebuild
  if ! podman container exists systemd-embernet 2>/dev/null; then
    return 0
  fi

  log "Probing existing embernet0 for stale-enrollment signature..."

  # Settle window: a freshly started daemon may need ~10-20 s for the
  # first handshake to complete on a healthy registration. Give it 30 s.
  local attempt=0
  local healthy=0
  local rx_bytes
  while [[ ${attempt} -lt 6 ]]; do
    # `wg show embernet0 transfer` prints: <peer-pubkey> <rx> <tx>
    rx_bytes=$(wg show embernet0 transfer 2>/dev/null | awk 'NR==1 {print $2}')
    if [[ -n "${rx_bytes}" && "${rx_bytes}" != "0" ]]; then
      healthy=1
      break
    fi
    sleep 5
    attempt=$((attempt + 1))
  done

  if [[ ${healthy} -eq 1 ]]; then
    log "embernet0 WG handshake healthy (rx=${rx_bytes} B) — keeping enrollment"
    return 0
  fi

  warn "embernet0 up but WG handshake has NEVER completed after 30 s (rx=0). \
Stale enrollment detected — wiping daemon state to force fresh AAD device-code re-enroll."
  warn "  Preserved: /etc/embernet/k3s-token (K3s join token survives)"

  # Stop + remove the container so install_embernetlite below recreates it
  systemctl stop embernet 2>/dev/null || true
  podman stop -t 5 systemd-embernet >/dev/null 2>&1 || true
  podman rm -f systemd-embernet >/dev/null 2>&1 || true

  # Wipe enrollment state. Preserve /etc/embernet/k3s-token (cluster
  # join token; lives in /etc not /var/lib).
  rm -f /var/lib/embernet/auth.token \
        /var/lib/embernet/device.token \
        /var/lib/embernet/refresh.token \
        /var/lib/embernet/endpoint.id \
        /var/lib/embernet/pretunnel-state.json
  rm -rf /var/lib/embernet/identity /var/lib/embernet/wireguard

  # Bring down the (now-orphan) embernet0 interface so install_embernetlite
  # + the daemon recreate it fresh
  ip link delete embernet0 2>/dev/null || true

  log "Stale state cleared. install_embernetlite will recreate the daemon and gate_on_embernet0 will drive fresh AAD device-code enrollment."
}

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

  # v0.0.43 BUG-272 migration: persist tenant_id + device_name so the
  # daemon's register-on-startup path can refresh os_version +
  # client_version on the dashboard every boot. Before this, the
  # dashboard's row showed whatever the original interactive
  # enrollment wrote ("Alpine v3.20 / v0.0.24-dev" on Trane CP-02
  # through three daemon upgrades) because the /heartbeat handler
  # doesn't touch those two columns. Files are mode 0644 — public
  # data, no secrets. tenant_id is constant for all UT3 boxes (one
  # site, one tenant). Idempotent — daemon only reads at startup, so
  # an in-flight write is harmless.
  echo "tranetech-ut3" > /var/lib/embernet/tenant.id
  echo "${NODE_NAME}"  > /var/lib/embernet/device.name
  chmod 0644 /var/lib/embernet/tenant.id /var/lib/embernet/device.name
  log "Wrote /var/lib/embernet/{tenant.id,device.name} for v0.0.43+ register-on-startup"

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
      log "[7/11] embernetlite already running on ${EMBERNET_IMAGE} — skipping"
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
    -v /etc/os-release:/etc/os-release:ro,Z \
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
    log "[7/11] embernetlite running (systemd unit: embernet.service, enabled for boot)"
  else
    fail "embernetlite container not running after podman run — inspect: podman logs systemd-embernet"
  fi
}

# ─── [8/11] Gate on embernet0 — Phase 1 / Phase 2 split ──────
# Drives the AAD device-code enrollment IN THE SCRIPT so the operator
# only ever interacts with a browser. Replaces the older "print instructions
# and exit" flow.
#
# Sequence:
#   (a) embernet0 already up         → set EMBERNET_IP, return 0 (Phase 2)
#   (b) embernet0 not up + daemon
#       reachable on 127.0.0.1:8765  → enroll_interactively, then wait for
#                                       embernet0, then return 0
#   (c) anything fails               → fail loud with the operator command
#                                       to recover manually
#
# enroll_interactively handles every wizard phase: resumes mid-flight,
# auto-binds single-tenant accounts (the daemon does this internally),
# prompts for multi-tenant accounts (or honours TENANT_ID env override
# for non-interactive runs).
#
# Inherited from fireball/deploy-embernode-arm64-microos.sh's two-phase
# pattern but with the manual `exit 0` replaced by a real flow.
gate_on_embernet0() {
  log "[8/11] Gating on ${EMBERNET_IFACE} (Phase 1 → Phase 2 transition)..."

  if _embernet0_up; then
    log "[8/11] ${EMBERNET_IFACE} is up — IPv4 ${EMBERNET_IP}. Proceeding with Phase 2 (K3s)."
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
  log "[8/11] ${EMBERNET_IFACE} up — IPv4 ${EMBERNET_IP}. Proceeding with Phase 2 (K3s)."
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
# Selection priority (no operator interaction unless ALL of the
# explicit / inferable signals fail):
#
#   1. TENANT_ID env override (operator passed an explicit id).
#   2. count == 1 (daemon should already have auto-bound, but defence
#      in depth on resume).
#   3. NODE_NAME heuristic — Trane-UT3-* maps to tranetech-ut3,
#      Fragua-* maps to fragua, EmberNode-* / Fireball-* maps to
#      fireball. If we find the inferred tenant in the available
#      list, AUTO-PICK silently. Operator override via TENANT_ID env
#      var (logged so override is auditable).
#   4. Multiple tenants + no NODE_NAME match + TTY attached → prompt.
#   5. Multiple tenants + no NODE_NAME match + no TTY → fail loud.
#
# Goal: a fresh operator running `sudo bash trane/deploy-ut3-cp01.sh`
# with no env vars does zero terminal interaction. The browser AAD
# sign-in is the only human-in-the-loop step.
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

# ─── [9/11] K3s server (host install, JOIN to CP-02 seed) ────────
# CP-01 joins the existing trane-ut3 HA cluster as a second control
# plane. CP-02 is the seed (cluster-init was run there 2026-06-17;
# K3s embedded etcd lives at https://${SEED_EMBERNET_IP}:6443).
#
# Pre-req: /etc/embernet/k3s-token MUST exist on this box before
# Phase 2 starts. The seed (CP-02) wrote it at its own install
# time; copy it across:
#
#   on CP-02:  sudo cat /etc/embernet/k3s-token
#   on this CP-01 box:
#     sudo mkdir -p /etc/embernet
#     sudo install -m 600 /dev/stdin /etc/embernet/k3s-token <<'TOKEN'
#     <paste-the-token-value>
#     TOKEN
#
# Redeploying a CP-01 box that previously ran the legacy --cluster-init
# code (stale seed-cluster state on disk that will conflict with CP-02's
# etcd): set K3S_FORCE_WIPE=1 to nuke /var/lib/rancher + reinstall
# clean. The pre-flight wedge detector ONLY catches inactive K3s — if
# the stale cluster is still running, the wipe must be forced.
#
#   K3S_FORCE_WIPE=1 sudo -E bash trane/deploy-ut3-cp01.sh
install_k3s_server_join() {
  log "[9/11] Joining EmberNet UT3 cluster as second control plane (K3s host install)..."

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

  # --- Require pre-staged cluster token (joiners CONSUME, never generate) ---
  if [[ ! -s "${K3S_TOKEN_FILE}" ]]; then
    fail "${K3S_TOKEN_FILE} is missing or empty.
       CP-01 JOINS CP-02's existing trane-ut3 cluster — it cannot mint its
       own cluster token. Copy CP-02's token onto this box first:
         on CP-02:  sudo cat ${K3S_TOKEN_FILE}
         on this box:
           sudo mkdir -p /etc/embernet
           sudo install -m 600 /dev/stdin ${K3S_TOKEN_FILE} <<TOKEN
           <paste-the-token-value>
           TOKEN
         then re-run this script."
  fi
  K3S_TOKEN="$(cat "${K3S_TOKEN_FILE}")"
  log "Using pre-staged K3s join token from ${K3S_TOKEN_FILE}"

  # --- Verify CP-02 seed API reachable over embernet0 before installing ---
  if ! curl -sk -o /dev/null --max-time 5 "https://${SEED_EMBERNET_IP}:6443/healthz" 2>/dev/null \
     && ! nc -z -w 5 "${SEED_EMBERNET_IP}" 6443 2>/dev/null; then
    fail "CP-02 K3s API at https://${SEED_EMBERNET_IP}:6443 is unreachable.
       Check: embernet0 routing, ${SEED_NODE_NAME}'s k3s-${K3S_INSTALL_NAME}.service status,
       and SEED_EMBERNET_IP env var (currently '${SEED_EMBERNET_IP}')."
  fi
  log "CP-02 K3s API reachable at https://${SEED_EMBERNET_IP}:6443"

  # --- Install K3s server in JOIN mode if not already healthy ---
  if [[ -x /usr/local/bin/k3s ]] \
     && systemctl is-active --quiet "k3s-${K3S_INSTALL_NAME}" 2>/dev/null; then
    log "K3s server already installed and active — skipping reinstall"
    log "    (if this is the legacy --cluster-init install pointing at the WRONG cluster,"
    log "    re-run with K3S_FORCE_WIPE=1 to wipe and re-join CP-02's cluster.)"
  else
    log "Installing K3s server in JOIN mode (host binary + systemd service, joining ${SEED_EMBERNET_IP}:6443)"
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="${K3S_VERSION}" \
      INSTALL_K3S_NAME="${K3S_INSTALL_NAME}" \
      K3S_TOKEN="${K3S_TOKEN}" \
      K3S_URL="https://${SEED_EMBERNET_IP}:6443" \
      sh -s - server \
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
      _check "embernetlite API /api/v1/health responding — FAILED (pre-enrollment? re-run \`sudo bash trane/deploy-ut3-cp01.sh\` and complete the AAD device-code flow when prompted)" FAIL
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
  echo "  --- embernetlite enrollment ---"
  echo "  Driven by the script's interactive flow (no manual commands)."
  echo "  Re-run \`sudo bash trane/deploy-ut3-cp01.sh\` — the script will"
  echo "  prompt with a device code + URL, walk you through tenant pick if"
  echo "  needed, and wait for ${EMBERNET_IFACE} to come up before K3s."
  echo ""
  echo "  --- REQUIRED: Patch cluster CR agentEnvVars (one-time, mgmt-side) ---"
  echo "  Without this, Rancher will show this cluster as Unavailable forever"
  echo "  even though the agent pod is healthy. See trane/docs/TRANE-UT3-DEPLOY.md"
  echo "  Step 4.5 + industrial-dashboard/.agent/workflows/rancher-cluster-join-pattern.md."
  echo ""
  echo "  Patrick (or whoever has embernet-005 kubectl access) must run:"
  echo ""
  echo "    ssh embernet-005"
  echo "    sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get cluster.management.cattle.io"
  echo "    # find this cluster's c-XXXX ID, then:"
  echo "    sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl patch cluster.management.cattle.io <CLUSTER_ID> \\"
  echo "      --type=merge -p '{\"spec\":{\"agentEnvVars\":[{\"name\":\"CATTLE_AGENT_STRICT_VERIFY\",\"value\":\"false\"},{\"name\":\"STRICT_VERIFY\",\"value\":\"false\"}]}}'"
  echo ""
  echo "  Then bounce the agent on this node:"
  echo "    sudo k3s kubectl -n cattle-system delete pod -l app=cattle-cluster-agent"
  echo ""
  echo "  Within ~60s the cluster's Connected condition flips to True."
  echo "  Skip this and the cluster will appear Unavailable in Rancher + the dashboard."
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
# Self-heal a stale embernet enrollment from a prior run (rx=0 / no
# handshake against the hub) BEFORE install_embernetlite so the
# fresh-container path takes over. No-op on a truly fresh box.
heal_stale_embernet_enrollment
install_embernetlite

# Phase 1 → Phase 2 gate — exit 0 here if operator hasn't completed
# AAD device-code enrollment yet (embernet0 is the gate).
gate_on_embernet0

# Phase 2 — K3s on embernet0 (JOIN CP-02's existing HA cluster), then Rancher import:
install_k3s_server_join
import_rancher
print_summary
verify_deployment
