#!/usr/bin/env bash
# mesh-cluster.sh — 3-node emulated k8s cluster orchestrator (issue #48, PR B).
# Boot ONE control-plane node (kubeadm init) + TWO joining nodes over a shared
# QEMU socket/mcast L2 (launch-x86.sh --mesh-net), each behind its own per-run
# qcow2 overlay, and gate on the serial-console markers the keys-provision
# engine already emits plus a `kubectl get nodes` count over SSH.
#
# WHAT A RUN DOES, in order:
#   1. mints the cluster secrets OFFLINE: a throwaway kubernetes CA
#      (KEYS/kubernetes/pki -> provision.sh installs it before kubeadm init),
#      a PINNED bootstrap token, and the ca-cert hash computed from that CA —
#      so BOTH joiners' KEYS sticks are written up front, no serial scraping;
#   2. builds three role-accurate KEYS payloads (make-test-keys.sh, the same
#      shape as avc-workout.sh): node1 = control-plane (bootstrap:true,
#      first:true, config_file + pki_dir), node2/3 = workers with the pinned
#      .kubernetes.join block. Every payload carries a network/mesh0.nmconnection
#      binding a static IP to that node's mesh-NIC MAC (the shared L2 has no
#      DHCP), and the CP's kubeadm-config advertises + certSANs the mesh IP so
#      the joiners' TLS bootstrap validates against the address they dial;
#   3. boots node1 through launch-x86.sh --mesh-net/--mesh-mac behind a qcow2
#      overlay and waits on its console for "Running kubeadm init" ->
#      "First control plane initialised" -> "=== keys-provision complete ===";
#   4. boots node2+node3 the same way and waits for "Joined cluster (" on each
#      (fail marker: "kubeadm join failed against");
#   5. asserts REGISTRATION over SSH on the CP: `kubectl get nodes` must list
#      3 nodes (Ready needs a CNI — that is the post-build campaign's phase, so
#      the Ready count is reported, not gated);
#   6. powers everything down. Overlays are throwaway BY DESIGN and are NEVER
#      committed back: `qemu-img commit` against a live device silently rewrites
#      the GOLDEN artifact (learned the hard way — see qemu-device-save). This
#      driver never touches the golden .img at all; only the launchers' per-run
#      overlays are written.
#
# GATING (mirrors run-matrix-e2e.sh):
#   * --dry-run    ALWAYS runs: no root, no boot, no keys, no secrets — prints
#                  the full 3-node plan (L2 spec, MACs, IPs, ports, launcher
#                  argv). This is the CI-green hermetic path.
#   * boot path    runs ONLY when HUGMESH_QEMU_MESH=1 AND qemu is installed;
#                  otherwise SKIP-clean (exit 0) — but LOUDLY: a skipped run
#                  prints a WARN line on stderr AND a machine-readable
#                  'RESULT:  SKIP reason=<no-opt-in|no-qemu> detail=...' line on
#                  stdout, so no consumer can mistake "did not run" for "ran and
#                  passed". The exit code is deliberate policy; the silence was
#                  not (see skip_out below).
#
# Phases (issue #48 design comment): this driver is execution phase 2 — a LAN
# cluster over the shared L2 with a pinned-token join, headscale/tailscale OFF.
# Phase 3 (mesh-faithful: headscale + MagicDNS + reusable preauth key) layers a
# different KEYS payload on the same launch plumbing. This driver boots x86 rows;
# launch-pi.sh and launch-arm.sh now carry the SAME --mesh-net/--mesh-mac flags
# (byte-for-byte the same block), so a mixed-arch cluster is a launcher choice
# rather than a missing feature. The containerized fleet lane —
# run-qemu-docker.sh --keep-alive --mesh-net — puts the same L2 under registry-
# visible devices; both take their addresses from the SAME planner identity file
# (--identities, below).
#
# Hermetic-test seams (mirrors avc-workout.sh's AVC_*_CMD):
#   MESH_LAUNCH_CMD  replaces `bash launch-x86.sh` (argv appended verbatim)
#   MESH_SSH_CMD     replaces `ssh <opts> user@localhost` (remote argv appended,
#                    stdin passed through)
#   MESH_KEYS_CMD    replaces make-test-keys.sh
#
#   tests/qemu/mesh-cluster.sh --dry-run                      # plan only
#   HUGMESH_QEMU_MESH=1 tests/qemu/mesh-cluster.sh -w out     # real 3-node boot
#   make qemu-mesh WORK_DIR=out/sessions/<id>/artifacts
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Defaults ─────────────────────────────────────────────────────────────────
WORK_DIR=""                    # launcher artifact autodetect dir (-w)
RUN_DIR=""                     # per-run artifact dir (default under out/qemu-runs/mesh)
CP_ROLE="pki"                  # image role for the control-plane node
WORKER_ROLE="backend"          # image role for the two joining nodes
IMG=""                         # ONE golden .img for all three nodes (optional)
CP_IMG=""                      # per-kind golden overrides (optional)
WORKER_IMG=""
MEM=""                         # empty = launcher default
SMP=""
MESH_NET="239.118.72.1:47301"  # shared UDP-mcast L2 every node joins (--mesh-net SPEC)
SUBNET_PREFIX="10.87.72"       # static /24 for the mesh NICs; nodes get .11/.12/.13
PREFIX_LEN="24"                # /N for the nmconnection addresses
# ── The identity file (optional; the planner is the ONE source) ──────────────
# With --identities, MACs / IPs / the L2 SPEC come from
# studio/hugmesh_studio/core/mesh_emulation.py's plan instead of the built-in
# table below, so a node this driver boots carries the SAME address the Studio,
# the device registry and run-qemu-docker.sh's fleet lane show for it. WITHOUT
# the flag nothing here changes: the defaults above stand and `make qemu-mesh`
# behaves exactly as it did before the flag existed (pinned in mesh-cluster_test.sh).
IDENTITIES=""
MESH_NET_SET=false             # did the OPERATOR spell --mesh-net? (then it wins)
SUBNET_PREFIX_SET=false
SSH_USER="tester"
TIMEOUT="2700"                 # per-node boot -> console-marker budget (TCG is slow)
JOIN_TIMEOUT="900"             # kubectl node-registration budget after all joins
KEEP=false
DRY_RUN=false

# Host-side forwarded ports, one disjoint set per node (a single launch-x86.sh
# defaults ALL FIVE forwards, so three concurrent nodes must not collide).
SSH_BASE=2280; UI_BASE=18440; HTTP_BASE=18470; API_BASE=16440; HS_BASE=18090

usage() {
cat <<EOF
Usage: $0 [OPTIONS]

  Boot a 3-node emulated k8s cluster: control-plane init + two pinned-token
  joins over a shared QEMU mcast L2, all behind qcow2 overlays (the golden
  images are never written). SKIP-clean unless HUGMESH_QEMU_MESH=1.

  -w, --work-dir D   artifact dir the launcher autodetects .imgs from
      --cp-role R    control-plane image role. Default: ${CP_ROLE}
      --worker-role R  joining nodes' image role. Default: ${WORKER_ROLE}
      --img FILE     ONE golden .img for all three nodes (skips autodetect)
      --cp-img FILE / --worker-img FILE   per-kind golden overrides
      --run-dir D    per-run artifact dir. Default: ${REPO_DIR}/out/qemu-runs/mesh/<ts>
  -m, --mem MB / --smp N   forwarded to the launcher when set
      --mesh-net SPEC  shared L2 spec (launch-x86.sh --mesh-net). Default: ${MESH_NET}
      --subnet-prefix P  /24 prefix for the static mesh IPs. Default: ${SUBNET_PREFIX}
      --identities FILE  take the nodes' MAC/IP/L2 from the planner's identity
                       file (the ONE identity source) instead of the built-in
                       table. Mint one with:
                         PYTHONPATH=studio python3 -m \\
                           hugmesh_studio.core.mesh_emulation identities --out FILE
                       An explicit --mesh-net/--subnet-prefix still wins over it.
                       Omitted: every default above stands, unchanged.
      --ssh-user U   login the KEYS payloads create. Default: ${SSH_USER}
  -t, --timeout SEC  per-node boot->marker budget. Default: ${TIMEOUT}
      --join-timeout SEC  kubectl registration budget. Default: ${JOIN_TIMEOUT}
      --dry-run      print the 3-node plan; boot NOTHING (no root, no keys)
      --keep         keep overlays + scratch files in the run dir
  -h, --help         this help
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--work-dir)    WORK_DIR="$2"; shift 2 ;;
        --cp-role)        CP_ROLE="$2"; shift 2 ;;
        --worker-role)    WORKER_ROLE="$2"; shift 2 ;;
        --img)            IMG="$2"; shift 2 ;;
        --cp-img)         CP_IMG="$2"; shift 2 ;;
        --worker-img)     WORKER_IMG="$2"; shift 2 ;;
        --run-dir)        RUN_DIR="$2"; shift 2 ;;
        -m|--mem)         MEM="$2"; shift 2 ;;
        --smp)            SMP="$2"; shift 2 ;;
        --mesh-net)       MESH_NET="$2"; MESH_NET_SET=true; shift 2 ;;
        --subnet-prefix)  SUBNET_PREFIX="$2"; SUBNET_PREFIX_SET=true; shift 2 ;;
        --identities)     IDENTITIES="$2"; shift 2 ;;
        --ssh-user)       SSH_USER="$2"; shift 2 ;;
        -t|--timeout)     TIMEOUT="$2"; shift 2 ;;
        --join-timeout)   JOIN_TIMEOUT="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --keep)           KEEP=true; shift ;;
        -h|--help)        usage 0 ;;
        *) echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; RST=$'\033[0m'
info() { echo "${GREEN}[mesh-cluster]${RST} $*"; }
step() { echo "${CYAN}==> $*${RST}"; }
warn() { echo "${YEL}[mesh-cluster] WARN:${RST} $*"; }
die()  { echo "${RED}[mesh-cluster] ERROR:${RST} $*" >&2; exit 1; }

# skip_out REASON DETAIL — announce a not-run, LOUDLY and machine-readably.
#
# WHY THIS EXISTS (2026-08-26). Both gates below are legitimately exit-0: this
# driver boots three real x86 guests, so on a CI runner with no qemu and no
# opt-in there is nothing to run and nothing to fail. THAT EXIT CODE IS
# DECLARED POLICY (see the GATING block in this file's header, and the identical
# contract in run-matrix-e2e.sh) and it is NOT what this changes.
#
# What it changes is that the not-run used to be indistinguishable from a run.
# The gates printed one green info() line — the same colour, prefix and stream
# as every ordinary progress message this driver emits — and then exited 0. A
# log scraper looking for the driver's verdict found NO 'RESULT:' line at all,
# which is exactly how it looks when a driver runs and passes quietly, and a
# human skimming a green pipeline saw a green line. This is the failure mode
# that let DAST sit inert for weeks org-wide (four silent-skip paths, fixed in
# PR #139): the danger was never the exit code, it was that nobody could tell
# from the output whether the thing had run.
#
# So a skip now says three things a reader (or a grep) can act on:
#   * a WARN-coloured line on STDERR, because a not-run is not progress;
#   * a machine-readable 'RESULT:  SKIP reason=<slug> ...' line on STDOUT, in
#     the same 'RESULT:' shape as the --dry-run and PASS/FAIL verdicts, so a
#     consumer that scrapes for a verdict now always finds one;
#   * a REASON SLUG, so "not run because nobody opted in" and "not run because
#     the tool is missing" are two different, greppable answers.
# The caller still writes its own `exit 0` — the policy stays visible at the
# gate rather than buried in a helper that could quietly start exiting nonzero.
skip_out() {
    local reason="$1" detail="$2"
    echo "${YEL}[mesh-cluster] SKIP (${reason}):${RST} ${detail}" >&2
    echo "RESULT:  SKIP reason=${reason} detail=${detail}"
}

# ── The node table (index / kind / image role / static mesh identity) ────────
# node1 = control-plane, node2+3 = joiners. MACs match launch-x86.sh's
# --mesh-id derivation (52:54:00:6d:65:NN) and the nmconnection profiles bind
# the static IPs to exactly these MACs, so IP identity survives NIC reordering.
NODE_KIND=(cp worker worker)
node_role()     { [ "$1" -eq 1 ] && echo "${CP_ROLE}" || echo "${WORKER_ROLE}"; }
node_img()      { if [ "$1" -eq 1 ]; then echo "${CP_IMG:-${IMG}}"; else echo "${WORKER_IMG:-${IMG}}"; fi; }
node_hostname() { if [ "$1" -eq 1 ]; then echo "hugmesh-mesh-cp"; else echo "hugmesh-mesh-w$1"; fi; }
node_dir()      { echo "${RUN_DIR}/node$1-${NODE_KIND[$(( $1 - 1 ))]}"; }
node_ssh_port() { echo "$((SSH_BASE + $1))"; }

# ── Identities: the planner's file when given, this table otherwise ──────────
# IDENT_* are EMPTY unless --identities loaded them, and node_mac/node_ip fall
# straight back to the built-in derivation when they are — that fallback is what
# keeps a flagless run byte-identical to the landed driver.
IDENT_LABEL=(); IDENT_MAC=(); IDENT_IP=()
node_mac()      { if [ -n "${IDENT_MAC[$1]:-}" ]; then printf '%s' "${IDENT_MAC[$1]}"
                  else printf '52:54:00:6d:65:%02x' "$1"; fi; }
node_ip()       { if [ -n "${IDENT_IP[$1]:-}" ]; then printf '%s' "${IDENT_IP[$1]}"
                  else echo "${SUBNET_PREFIX}.$((10 + $1))"; fi; }
node_label()    { printf '%s' "${IDENT_LABEL[$1]:-node$1}"; }

# Read the planner's identity file into IDENT_*, through the reader BOTH mesh
# lanes share (tests/qemu/mesh-identities.sh — it also documents the file's
# shape and the two spellings it accepts). What stays here is this driver's own
# policy: exactly three nodes, all on one wire, all with one mask.
# Spelled as an `if`, not `[ -f ] && . || die`: that list would also fire the die
# when the sourced file's LAST command returned non-zero, i.e. blame a missing
# file for something else entirely.
if [ -f "${SCRIPT_DIR}/mesh-identities.sh" ]; then
    # shellcheck source=tests/qemu/mesh-identities.sh
    . "${SCRIPT_DIR}/mesh-identities.sh"
else
    die "missing ${SCRIPT_DIR}/mesh-identities.sh (the identity-file reader)"
fi

load_identities() { # <file>
    local f="$1" i=0 label mac ip plen net first_net="" first_plen="" why lines
    # Read the whole file before believing any of it, and NOT through a pipe:
    # a pipe would hide the reader's exit status and run this loop in a subshell,
    # where every IDENT_* assignment would vanish.
    lines="$(mesh_identity_lines "${f}")" \
        || die "--identities ${f} is not usable (see the reason above)"
    [ -n "${lines}" ] || die "--identities ${f}: no usable rows"
    while IFS='|' read -r label mac ip plen net; do
        [ -n "${label}${mac}" ] || continue
        i=$((i + 1))
        why="$(mesh_identity_check_row "${label}" "${mac}" "${ip}" "${plen}")" \
            || die "identities row ${i}: ${why}"
        [ -n "${first_net}" ]  || first_net="${net}"
        [ -n "${first_plen}" ] || first_plen="${plen}"
        [ "${net}" = "${first_net}" ] \
            || die "identities row ${i} (${label}): mesh_net '${net}' differs from '${first_net}' — the nodes would not share one L2"
        [ "${plen}" = "${first_plen}" ] \
            || die "identities row ${i} (${label}): prefix_len ${plen} differs from ${first_plen} — one subnet, one mask"
        IDENT_LABEL[${i}]="${label}"; IDENT_MAC[${i}]="${mac}"; IDENT_IP[${i}]="${ip}"
        [ "${i}" -ge 3 ] && break      # this driver is a 3-node cluster
    done <<< "${lines}"
    [ "${i}" -ge 3 ] || die "--identities ${f} describes ${i} device(s); this driver boots 3"
    # The file's L2 and prefix win over the built-in defaults, but never over an
    # operator who spelled the flag on THIS command line.
    if ! ${MESH_NET_SET} && [ -n "${first_net}" ]; then MESH_NET="${first_net}"; fi
    PREFIX_LEN="${first_plen}"
    if ! ${SUBNET_PREFIX_SET}; then SUBNET_PREFIX="${IDENT_IP[1]%.*}"; fi
    info "identities: ${f} — $(node_label 1), $(node_label 2), $(node_label 3) on ${MESH_NET}"
}
[ -z "${IDENTITIES}" ] || load_identities "${IDENTITIES}"

CP_IP=""        # resolved below once (node_ip 1)
CP_IP="$(node_ip 1)"

# ── Dry-run: the ALWAYS-green plan (no root, no boot, no keys, no secrets) ───
if ${DRY_RUN}; then
    echo "mesh-cluster PLAN (3 nodes, shared L2 ${MESH_NET}, subnet ${SUBNET_PREFIX}.0/${PREFIX_LEN}) — no boot, no build, no keys"
    if [ -n "${IDENTITIES}" ]; then
        echo "identities: ${IDENTITIES} (the planner's file — one identity source)"
    else
        echo "identities: built-in table (pass --identities FILE for the planner's)"
    fi
    for i in 1 2 3; do
        kind="${NODE_KIND[$((i - 1))]}"
        printf 'NODE %d %-6s role=%-8s hostname=%-16s mac=%s ip=%s/'"${PREFIX_LEN}"' ssh=%s ui=%s http=%s api=%s hs=%s\n' \
            "${i}" "${kind}" "$(node_role "${i}")" "$(node_hostname "${i}")" \
            "$(node_mac "${i}")" "$(node_ip "${i}")" \
            "$(node_ssh_port "${i}")" "$((UI_BASE + i))" "$((HTTP_BASE + i))" \
            "$((API_BASE + i))" "$((HS_BASE + i))"
        printf '       launch-x86.sh -r %s --mesh-net %s --mesh-mac %s --keys-img <node%d>/keys.img --run-dir <node%d>/launch\n' \
            "$(node_role "${i}")" "${MESH_NET}" "$(node_mac "${i}")" "${i}" "${i}"
    done
    echo "markers: cp='Running kubeadm init' -> 'First control plane initialised' -> '=== keys-provision complete ==='"
    echo "         workers='Joined cluster (' (fail: 'kubeadm join failed against')"
    echo "gate   : kubectl get nodes lists 3 registered nodes (Ready needs a CNI — reported, not gated)"
    echo "RESULT:  DRY-RUN planned 3 nodes (nothing booted)"
    exit 0
fi

# ── Opt-in gate for the boot path (mirrors run-matrix-e2e.sh) ────────────────
if [ "${HUGMESH_QEMU_MESH:-}" != "1" ]; then
    skip_out no-opt-in \
        "the 3-node QEMU mesh cluster is opt-in and HUGMESH_QEMU_MESH is not 1 — set HUGMESH_QEMU_MESH=1 (with qemu) to boot it, or pass --dry-run for the hermetic plan. NOTHING WAS BOOTED OR ASSERTED."
    exit 0    # DECLARED POLICY (see the GATING block in the header) — a skip is not a failure.
fi
# The stub-launcher seam (MESH_LAUNCH_CMD) replaces qemu for the hermetic
# wiring test, so the real qemu binary is only required on the genuine boot path.
if [ -z "${MESH_LAUNCH_CMD:-}" ] && ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    skip_out no-qemu \
        "qemu-system-x86_64 is not on PATH, so the boot path cannot run on this host even though HUGMESH_QEMU_MESH=1 asked for it. NOTHING WAS BOOTED OR ASSERTED."
    exit 0    # DECLARED POLICY (see the GATING block in the header) — a skip is not a failure.
fi
command -v openssl >/dev/null 2>&1 || die "missing openssl (needed to mint the offline cluster CA)"

[ -n "${RUN_DIR}" ] || RUN_DIR="${REPO_DIR}/out/qemu-runs/mesh/$(date -u '+%Y%m%dT%H%M%SZ')"
mkdir -p "${RUN_DIR}" || die "cannot create run dir ${RUN_DIR}"
info "run dir : ${RUN_DIR}"
info "mesh L2 : ${MESH_NET} (subnet ${SUBNET_PREFIX}.0/${PREFIX_LEN}; cp=${CP_IP})"

# ── 1. Offline cluster secrets: CA + pinned token + ca-cert hash ─────────────
# The CA is installed on the CP via KEYS/kubernetes/pki (provision.sh copies it
# into /etc/kubernetes/pki BEFORE kubeadm init, which then signs everything
# else off it), so the joiners' discovery hash is computable HERE, offline —
# no scraping join material off a live serial console.
rand_az09() { tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c "$1"; }
step "Minting offline cluster secrets (throwaway CA + pinned bootstrap token)"
PKI_SRC="${RUN_DIR}/cluster-pki"
mkdir -p "${PKI_SRC}"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "${PKI_SRC}/ca.key" -out "${PKI_SRC}/ca.crt" \
    -subj "/CN=kubernetes" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign" \
    >/dev/null 2>&1 || die "openssl CA generation failed"
chmod 0600 "${PKI_SRC}/ca.key"
CA_HASH="sha256:$(openssl x509 -pubkey -noout -in "${PKI_SRC}/ca.crt" 2>/dev/null \
    | openssl pkey -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
[[ "${CA_HASH}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "could not compute the CA discovery hash"
JOIN_TOKEN="$(rand_az09 6).$(rand_az09 16)"
[[ "${JOIN_TOKEN}" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]] || die "could not mint a kubeadm bootstrap token"
info "token   : ${JOIN_TOKEN%%.*}.**************** hash: ${CA_HASH:0:14}..."

SSHKEY="${RUN_DIR}/id_ed25519"
rm -f "${SSHKEY}" "${SSHKEY}.pub"
ssh-keygen -t ed25519 -N '' -C "mesh-cluster@qemu" -f "${SSHKEY}" >/dev/null \
    || die "ssh-keygen failed"
PUBKEY="$(cat "${SSHKEY}.pub")"

# ── 2. KEYS payloads (same shape as avc-workout.sh / docker-entrypoint.sh) ───
write_users_json() { # <dest>
    cat > "$1" <<EOF
{
  "users": [
    {
      "name": "${SSH_USER}",
      "comment": "QEMU mesh-cluster login",
      "groups": ["wheel"],
      "shell": "/bin/bash",
      "uid": 1000,
      "sudo": true,
      "sudo_nopasswd": true,
      "ssh_authorized_keys": ["${PUBKEY}"]
    }
  ],
  "root": { "ssh_authorized_keys": ["${PUBKEY}"] }
}
EOF
}

write_mesh_nmconnection() { # <dest> <mac> <ip>
    # provision_network() copies KEYS/network/*.nmconnection verbatim. The
    # shared L2 has no DHCP, so bind a static IP to the mesh NIC by MAC.
    # never-default keeps the slirp NIC's default route (hostfwd SSH intact).
    cat > "$1" <<EOF
[connection]
id=mesh0
type=ethernet
autoconnect=true
autoconnect-priority=20

[802-3-ethernet]
mac-address=$2

[ipv4]
method=manual
address1=$3/${PREFIX_LEN}
never-default=true

[ipv6]
method=disabled
EOF
}

write_cp_kubeadm_config() { # <dest>
    # Mirrors the baked specs/etc/kubernetes/kubeadm-config.yaml, re-pointed at
    # the mesh L2: advertise + controlPlaneEndpoint + certSAN the CP's static
    # mesh IP (the address the joiners dial, so their TLS bootstrap validates),
    # and PIN the bootstrap token so both joiners' KEYS sticks are mintable
    # offline. The encryption-provider extraArgs/extraVolumes stay: provision.sh
    # writes /etc/kubernetes/encryption-config.yaml before kubeadm init runs.
    cat > "$1" <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
bootstrapTokens:
  - token: "${JOIN_TOKEN}"
    ttl: "24h0m0s"
    usages: [signing, authentication]
    groups: [system:bootstrappers:kubeadm:default-node-token]
localAPIEndpoint:
  advertiseAddress: ${CP_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: stable
controlPlaneEndpoint: "${CP_IP}:6443"
apiServer:
  certSANs:
    - kube-api.headnet.internal
    - $(node_hostname 1)
    - ${CP_IP}
    - 127.0.0.1
  extraArgs:
    encryption-provider-config: /etc/kubernetes/encryption-config.yaml
  extraVolumes:
    - name: encryption-config
      hostPath: /etc/kubernetes/encryption-config.yaml
      mountPath: /etc/kubernetes/encryption-config.yaml
      readOnly: true
      pathType: File
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: cgroupfs
EOF
}

write_provision_json() { # <dest> <idx> <kind>
    local dest="$1" idx="$2" kind="$3" k8s
    if [ "${kind}" = "cp" ]; then
        # first:true is load-bearing: with no reachable CP endpoint the engine
        # falls back to .kubernetes.first, and 'true' selects kubeadm init.
        k8s='{
    "role": "control-plane",
    "bootstrap": true,
    "first": true,
    "config_file": "kubernetes/kubeadm-config.yaml",
    "pki_dir": "kubernetes/pki"
  }'
    else
        k8s='{
    "role": "worker",
    "bootstrap": true,
    "join": {
      "api_server": "'"${CP_IP}"':6443",
      "token": "'"${JOIN_TOKEN}"'",
      "ca_cert_hash": "'"${CA_HASH}"'"
    }
  }'
    fi
    # Phase 2 = LAN cluster: headscale/tailscale OFF (phase 3, the mesh-faithful
    # variant, flips them on with a reusable preauth key on this same plumbing).
    cat > "${dest}" <<EOF
{
  "version": 1,
  "hostname": "$(node_hostname "${idx}")",
  "timezone": "UTC",
  "selinux": { "mode": "permissive" },
  "headscale": { "enabled": false },
  "tailscale": { "enabled": false },
  "kubernetes": ${k8s},
  "hugmesh": { "role": "$(node_role "${idx}")", "cluster_domain": "hugmesh.local",
               "gitops": { "enabled": false } }
}
EOF
}

build_keys_payload() { # <idx>
    local idx="$1" kind nd src
    kind="${NODE_KIND[$((idx - 1))]}"
    nd="$(node_dir "${idx}")"; src="${nd}/keys"
    rm -rf "${src}"; mkdir -p "${src}/network"
    write_users_json "${src}/users.json"
    write_provision_json "${src}/provision.json" "${idx}" "${kind}"
    write_mesh_nmconnection "${src}/network/mesh0.nmconnection" \
        "$(node_mac "${idx}")" "$(node_ip "${idx}")"
    if [ "${kind}" = "cp" ]; then
        mkdir -p "${src}/kubernetes/pki"
        cp "${PKI_SRC}/ca.crt" "${PKI_SRC}/ca.key" "${src}/kubernetes/pki/"
        write_cp_kubeadm_config "${src}/kubernetes/kubeadm-config.yaml"
    fi
    ${MESH_KEYS_CMD:-bash "${SCRIPT_DIR}/make-test-keys.sh"} "${src}" "${nd}/keys.img" 64 \
        || die "KEYS image build failed for node${idx}"
}

step "Building the three KEYS provisioning payloads"
for i in 1 2 3; do
    mkdir -p "$(node_dir "${i}")/launch"
    build_keys_payload "${i}"
done

# ── Launch plumbing ──────────────────────────────────────────────────────────
launch_node() { # <idx>
    local idx="$1" nd img role
    nd="$(node_dir "${idx}")"
    img="$(node_img "${idx}")"
    role="$(node_role "${idx}")"
    local args=(
        --keys-img "${nd}/keys.img" --run-dir "${nd}/launch" --keep
        --mesh-net "${MESH_NET}" --mesh-mac "$(node_mac "${idx}")"
        --ssh-port "$(node_ssh_port "${idx}")" --ui-port "$((UI_BASE + idx))"
        --http-port "$((HTTP_BASE + idx))" --api-port "$((API_BASE + idx))"
        --hs-port "$((HS_BASE + idx))"
        --timeout "${TIMEOUT}"
    )
    [ -n "${img}" ]      && args+=(--img "${img}")
    [ -n "${WORK_DIR}" ] && args+=(-w "${WORK_DIR}")
    [ -n "${MEM}" ]      && args+=(--mem "${MEM}")
    [ -n "${SMP}" ]      && args+=(--smp "${SMP}")
    if [ -n "${MESH_LAUNCH_CMD:-}" ]; then
        ${MESH_LAUNCH_CMD} -r "${role}" "${args[@]}"
    else
        bash "${SCRIPT_DIR}/launch-x86.sh" -r "${role}" "${args[@]}"
    fi
}

cleanup() {
    local f d
    for d in "${RUN_DIR}"/node*/launch; do
        f="${d}/qemu.pid"
        [ -f "${f}" ] && kill "$(cat "${f}")" 2>/dev/null || true
    done
    # The overlays are throwaway; NEVER commit them back into the backing file
    # (`qemu-img commit` would silently rewrite the GOLDEN image). Delete only.
    if ! ${KEEP}; then
        rm -f "${RUN_DIR}"/node*/launch/*.qcow2 2>/dev/null || true
    fi
}
trap cleanup EXIT

wait_console() { # <console> <ok-regex> <fail-regex> <budget-secs> <label>
    local console="$1" okre="$2" failre="$3" budget="$4" label="$5"
    local deadline=$((SECONDS + budget))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if [ -f "${console}" ]; then
            if grep -qE "${failre}" "${console}"; then
                warn "${label}: FAILURE marker (${failre}) on the console"
                tail -n 40 "${console}" | sed 's/^/    | /' >&2 || true
                return 1
            fi
            grep -qE "${okre}" "${console}" && return 0
        fi
        sleep "${MESH_POLL_INTERVAL:-5}"
    done
    warn "${label}: marker /${okre}/ not seen within ${budget}s"
    [ -f "${console}" ] && tail -n 40 "${console}" | sed 's/^/    | /' >&2
    return 1
}

# gssh <idx> <wall-secs> <remote argv...>  (stdin flows through)
SSH_OPTS=(-i "${SSHKEY}"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o LogLevel=ERROR)
gssh() {
    local idx="$1" secs="$2"; shift 2
    if [ -n "${MESH_SSH_CMD:-}" ]; then
        timeout "${secs}" ${MESH_SSH_CMD} "$@"
    else
        timeout "${secs}" ssh "${SSH_OPTS[@]}" -p "$(node_ssh_port "${idx}")" \
            "${SSH_USER}@localhost" "$@"
    fi
}

FAILED=""

# ── 3. Control plane first: kubeadm init must complete before any join ───────
step "Booting node1 (control-plane, role=${CP_ROLE}) on the shared L2"
launch_node 1 2>&1 | tee "$(node_dir 1)/launch.log"
lrc=${PIPESTATUS[0]}
[ "${lrc}" -eq 0 ] || die "node1 launcher exited ${lrc} (see $(node_dir 1)/launch.log)"

CP_CONSOLE="$(node_dir 1)/launch/console.log"
step "Waiting for kubeadm init on the CP console (budget ${TIMEOUT}s)"
if wait_console "${CP_CONSOLE}" 'Running kubeadm init' \
        'kubeadm init failed|kubeadm join failed against' "${TIMEOUT}" "node1"; then
    info "node1: kubeadm init started"
else
    FAILED="${FAILED} cp-init-not-started"
fi
if [ -z "${FAILED}" ] && wait_console "${CP_CONSOLE}" \
        'First control plane initialised|admin.conf present' \
        'kubeadm init failed' "${TIMEOUT}" "node1"; then
    info "node1: control plane initialised"
else
    [ -z "${FAILED}" ] && FAILED="${FAILED} cp-init-failed"
fi
if [ -z "${FAILED}" ] && wait_console "${CP_CONSOLE}" \
        '=== keys-provision complete ===' 'kubeadm init failed' "${TIMEOUT}" "node1"; then
    info "node1: keys-provision complete"
else
    [ -z "${FAILED}" ] && FAILED="${FAILED} cp-provision-incomplete"
fi

# ── 4. The two joiners (only once the CP is actually up) ─────────────────────
if [ -z "${FAILED}" ]; then
    for i in 2 3; do
        step "Booting node${i} (worker, role=${WORKER_ROLE}) on the shared L2"
        launch_node "${i}" 2>&1 | tee "$(node_dir "${i}")/launch.log"
        lrc=${PIPESTATUS[0]}
        [ "${lrc}" -eq 0 ] || { FAILED="${FAILED} node${i}-launch"; break; }
    done
fi
if [ -z "${FAILED}" ]; then
    for i in 2 3; do
        step "Waiting for node${i} to join (budget ${TIMEOUT}s)"
        if wait_console "$(node_dir "${i}")/launch/console.log" \
                'Joined cluster \(' \
                'kubeadm join failed against|Incomplete kubernetes.join' \
                "${TIMEOUT}" "node${i}"; then
            info "node${i}: joined the cluster"
        else
            FAILED="${FAILED} node${i}-join"
        fi
    done
fi

# ── 5. Registration gate: kubectl get nodes on the CP must list 3 nodes ──────
NODES_SEEN=0
if [ -z "${FAILED}" ]; then
    step "Asserting registration: kubectl get nodes on the CP (budget ${JOIN_TIMEOUT}s)"
    deadline=$((SECONDS + JOIN_TIMEOUT))
    out=""
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        out="$(gssh 1 60 'sudo env KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes --no-headers 2>/dev/null' \
                </dev/null 2>/dev/null || true)"
        NODES_SEEN="$(printf '%s\n' "${out}" | grep -cE '^[[:alnum:]]' || true)"
        [ "${NODES_SEEN}" -ge 3 ] && break
        sleep "${MESH_VERIFY_INTERVAL:-10}"
    done
    printf '%s\n' "${out}" > "${RUN_DIR}/kubectl-get-nodes.txt"
    if [ "${NODES_SEEN}" -ge 3 ]; then
        info "kubectl sees ${NODES_SEEN} registered nodes:"
        printf '%s\n' "${out}" | sed 's/^/    | /'
        ready="$(printf '%s\n' "${out}" | grep -cw 'Ready' || true)"
        info "Ready: ${ready}/3 (Ready needs a CNI — the post-build campaign's phase, reported not gated)"
    else
        warn "kubectl sees only ${NODES_SEEN}/3 registered nodes"
        FAILED="${FAILED} node-count:${NODES_SEEN}"
    fi
fi

# ── 6. Polite teardown (overlays are throwaway; goldens untouched) ───────────
step "Powering the cluster down"
for i in 3 2 1; do
    gssh "${i}" 65 'sudo poweroff' </dev/null >/dev/null 2>&1 || true
done
sleep 3

echo
if [ -z "${FAILED}" ]; then
    info "${GREEN}MESH-CLUSTER RESULT: PASS${RST} (3 nodes registered over the shared L2) — artifacts: ${RUN_DIR}"
    exit 0
else
    warn "MESH-CLUSTER RESULT: FAIL —${FAILED}"
    warn "artifacts: ${RUN_DIR} (per-node consoles under node*/launch/console.log)"
    exit 1
fi
