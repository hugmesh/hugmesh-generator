#!/usr/bin/env bash
# avc-workout.sh — boot ONE built image in the existing QEMU harness, drive the
# workloads the hugmesh SELinux node-policy modules confine, harvest every AVC
# the run produced, and emit the narrowing report that makes trimming the
# '# INFERRED-WIDE: narrow after QEMU enforcing AVC pass' rules in
# specs/selinux/*.te mechanical (issue #45).
#
# One image per invocation, per image type — run it once per platform/role row
# you care about:
#
#   sudo tests/qemu/avc-workout.sh --platform x86  --role pki  -w out/sessions/<id>/artifacts
#   sudo tests/qemu/avc-workout.sh --platform rpi5 --role pki  -w out/sessions/<id>/artifacts
#   make avc-workout PLATFORM=x86 ROLE=pki WORK_DIR=out/sessions/<id>/artifacts
#
# WHAT A RUN DOES, in order:
#   1. builds a throwaway login key + FAT32 KEYS payload (same shape as
#      run-qemu-test.sh / docker-entrypoint.sh golden mode, role-accurate
#      headscale intent, .selinux.mode=permissive) and boots the image through
#      its OWN launcher (launch-x86.sh / launch-pi.sh / launch-arm.sh) behind a
#      per-run qcow2 overlay — the golden artifact is never written;
#   2. waits for SSH, performs extra logins (each one exercises sshd's
#      AuthorizedKeysCommand path = hugmesh_authkeys.te's real transition);
#   3. optionally `setenforce 1` (--enforcing) — provisioning still books the
#      node permissive, exactly like the enforce-gate's boot-permissive-
#      flip-later posture, so this tests the flip without baking it;
#   4. streams tests/qemu/avc-workload.sh into the guest: one probe per
#      confined workload (service starts, device-registry sync trigger,
#      tor/vpn starts, kubeadm init --dry-run), presence-gated so the list is
#      role-appropriate by construction;
#   5. harvests `ausearch -m AVC,USER_AVC -ts boot` (dmesg grep fallback when
#      ausearch/auditd is absent) plus the module manifest, `semodule -l`,
#      per-module load status and the provision log into RUN_DIR;
#   6. gates: every manifest module loaded, getenforce == expected mode;
#   7. runs avc-report.sh over the harvest -> RUN_DIR/report.txt, grouping
#      denials by source type -> the owning .te file.
#
# Root is needed for what the harness already needs it for (rpi5
# --kernel-from-img loop mounts; make-test-keys.sh without mtools); x86 with
# mtools installed runs unprivileged. NEVER run this against the golden image
# directly — the launchers' overlay already guarantees that.
#
# Hermetic-test seams (mirrors run-matrix-e2e.sh's SNAP_QEMU_*_CMD):
#   AVC_LAUNCH_CMD  replaces the launcher invocation (argv appended verbatim)
#   AVC_SSH_CMD     replaces `ssh <opts> user@localhost` (remote argv appended,
#                   stdin passed through)
#   AVC_KEYS_CMD    replaces make-test-keys.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Defaults ─────────────────────────────────────────────────────────────────
PLATFORM="x86"
BOARD=""
ROLE="pki"
IMG=""
KERNEL=""
WORK_DIR=""                    # launcher artifact autodetect dir (-w)
RUN_DIR=""                     # per-run artifact dir (default under out/qemu-runs/avc)
MEM=""                         # empty = launcher default
SMP=""
SSH_PORT="2262"                # off the 2222 defaults so a live harness run is not collided with
UI_PORT="8462"
# The launcher also forwards guest 80/6443/8080. Its defaults (8080/6443/8081)
# collide with a RUNNING local compose stack — phpbb binds host 8081 and the
# front door binds 8080 — and QEMU then refuses the whole -netdev:
#   Could not set up host forwarding rule 'tcp::8081-:8080'
# so the boot dies before a single AVC can be produced. These follow the same
# "off the common defaults" rule SSH_PORT/UI_PORT above already state, and are
# overridable for the same reason.
HTTP_PORT="8480"
API_PORT="6543"
HS_PORT="8481"
SSH_USER="tester"
TIMEOUT="2400"                 # boot->SSH budget; TCG ARM first boot is slow
PROBE_TIMEOUT="1800"           # wall clock for the whole in-guest workload run
ENFORCING=false                # setenforce 1 before the workload (the enforcing campaign)
KEEP=false
LOGINS="3"                     # extra ssh logins (hugmesh_authkeys.te workout)

usage() {
cat <<EOF
Usage: $0 --platform PLAT --role ROLE [OPTIONS]

  Boot ONE image, drive the workloads specs/selinux/*.te confine, harvest AVCs,
  and emit a narrowing report (denials grouped by source type -> owning .te).

  --platform PLAT   x86 | rpi5 | frite | jetson | orangepi5 | ... (launch-arm platforms)
  --board BOARD     board id for multi-board ARM platforms (launch-arm.sh -b)
  -r, --role ROLE   image role row to boot. Default: ${ROLE}
  -w, --work-dir D  artifact dir the launcher autodetects the .img from
      --img FILE    explicit golden .img (skips autodetect)
      --kernel FILE explicit kernel (ARM; rpi5 defaults to --kernel-from-img)
      --run-dir D   per-run artifact dir. Default: ${REPO_DIR}/out/qemu-runs/avc/<plat>_<role>_<ts>
  -m, --mem MB / --smp N        forwarded to the launcher when set
      --ssh-port P  host->guest 22 forward. Default: ${SSH_PORT}
      --ui-port P   host->guest 443 forward. Default: ${UI_PORT}
      --http-port P host->guest 80 forward. Default: ${HTTP_PORT}
      --api-port P  host->guest 6443 forward. Default: ${API_PORT}
      --hs-port P   host->guest 8080 forward. Default: ${HS_PORT}
      --ssh-user U  login the KEYS payload creates. Default: ${SSH_USER}
  -t, --timeout SEC boot->SSH budget. Default: ${TIMEOUT}
      --probe-timeout SEC  in-guest workload wall clock. Default: ${PROBE_TIMEOUT}
      --logins N    extra ssh logins (AuthorizedKeysCommand workout). Default: ${LOGINS}
      --enforcing   setenforce 1 before the workload (provisioning stays
                    permissive — this rehearses the enforce-gate flip)
      --keep        keep the qcow2 overlay + scratch files in the run dir
  -h, --help        this help

Artifacts land in RUN_DIR: report.txt (the narrowing worksheet), avc-raw.txt,
probes.log, logins.log, semodule-l.txt, selinux-modules.status, manifest.txt,
keys-provision.log, launch/console.log.
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)      PLATFORM="$2"; shift 2 ;;
        --board)         BOARD="$2"; shift 2 ;;
        -r|--role)       ROLE="$2"; shift 2 ;;
        -w|--work-dir)   WORK_DIR="$2"; shift 2 ;;
        # Absolutised: qemu-img resolves a RELATIVE backing file against the
        # OVERLAY's directory, not the cwd, so `--img out/x.img` became
        # <run-dir>/launch/out/x.img and died with "Could not open backing image"
        # — naming a path the caller never typed.
        --img)           IMG="$(cd "$(dirname "$2")" 2>/dev/null && pwd)/$(basename "$2")"; shift 2 ;;
        --kernel)        KERNEL="$2"; shift 2 ;;
        --run-dir)       RUN_DIR="$2"; shift 2 ;;
        -m|--mem)        MEM="$2"; shift 2 ;;
        --smp)           SMP="$2"; shift 2 ;;
        --ssh-port)      SSH_PORT="$2"; shift 2 ;;
        --ui-port)       UI_PORT="$2"; shift 2 ;;
        --http-port)     HTTP_PORT="$2"; shift 2 ;;
        --api-port)      API_PORT="$2"; shift 2 ;;
        --hs-port)       HS_PORT="$2"; shift 2 ;;
        --ssh-user)      SSH_USER="$2"; shift 2 ;;
        -t|--timeout)    TIMEOUT="$2"; shift 2 ;;
        --probe-timeout) PROBE_TIMEOUT="$2"; shift 2 ;;
        --logins)        LOGINS="$2"; shift 2 ;;
        --enforcing)     ENFORCING=true; shift ;;
        --keep)          KEEP=true; shift ;;
        -h|--help)       usage 0 ;;
        *) echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; RST=$'\033[0m'
info() { echo "${GREEN}[avc-workout]${RST} $*"; }
step() { echo "${CYAN}==> $*${RST}"; }
warn() { echo "${YEL}[avc-workout] WARN:${RST} $*"; }
die()  { echo "${RED}[avc-workout] ERROR:${RST} $*" >&2; exit 1; }

EXPECTED_MODE=permissive; ${ENFORCING} && EXPECTED_MODE=enforcing
LABEL="${PLATFORM}${BOARD:+-${BOARD}}_${ROLE}"
[ -n "${RUN_DIR}" ] || RUN_DIR="${REPO_DIR}/out/qemu-runs/avc/${LABEL}_$(date -u '+%Y%m%dT%H%M%SZ')"
mkdir -p "${RUN_DIR}" || die "cannot create run dir ${RUN_DIR}"
LAUNCH_DIR="${RUN_DIR}/launch"; mkdir -p "${LAUNCH_DIR}"
PIDFILE="${LAUNCH_DIR}/qemu.pid"
info "run dir : ${RUN_DIR}"
info "mode    : boot permissive, workout ${EXPECTED_MODE}"

# ── KEYS payload (same shape as docker-entrypoint.sh golden mode) ────────────
step "Generating login key + KEYS provisioning payload"
SSHKEY="${RUN_DIR}/id_ed25519"
rm -f "${SSHKEY}" "${SSHKEY}.pub"
ssh-keygen -t ed25519 -N '' -C "avc-workout@${LABEL}" -f "${SSHKEY}" >/dev/null \
    || die "ssh-keygen failed"
PUBKEY="$(cat "${SSHKEY}.pub")"

KEYS_SRC="${RUN_DIR}/keys"; rm -rf "${KEYS_SRC}"; mkdir -p "${KEYS_SRC}/headscale"
[ -f "${REPO_DIR}/specs/etc/headscale/config.yaml" ] \
    && cp "${REPO_DIR}/specs/etc/headscale/config.yaml" "${KEYS_SRC}/headscale/config.yaml"

cat > "${KEYS_SRC}/users.json" <<EOF
{
  "users": [
    {
      "name": "${SSH_USER}",
      "comment": "SELinux AVC workout login",
      "groups": ["wheel", "audio", "video", "usb"],
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

# Role-accurate headscale intent (the builders only run it on identity/control
# roles) — same map as docker-entrypoint.sh, so assertions stay truthful here.
HS_ENABLED=false
case "${ROLE}" in pki|generic|omnibus) HS_ENABLED=true ;; esac

# .selinux.mode stays permissive even for --enforcing: the shipped posture is
# boot-permissive + flip-later (enforce-gate), and the workout rehearses
# exactly that with a runtime setenforce — never a baked enforcing boot.
cat > "${KEYS_SRC}/provision.json" <<EOF
{
  "version": 1,
  "hostname": "hugmesh-avc-${ROLE}",
  "timezone": "UTC",
  "selinux": { "mode": "permissive" },
  "headscale": { "enabled": ${HS_ENABLED}, "config_file": "headscale/config.yaml" },
  "tailscale": { "enabled": false },
  "kubernetes": { "role": "control-plane", "bootstrap": false },
  "hugmesh": { "role": "${ROLE}", "cluster_domain": "hugmesh.local",
               "gitops": { "enabled": false } }
}
EOF

KEYS_IMG="${RUN_DIR}/keys.img"
${AVC_KEYS_CMD:-bash "${SCRIPT_DIR}/make-test-keys.sh"} "${KEYS_SRC}" "${KEYS_IMG}" 64 \
    || die "KEYS image build failed"

# ── Boot through the platform's own launcher ─────────────────────────────────
step "Booting ${LABEL} (expected getenforce after workout setup: ${EXPECTED_MODE})"
launch() {
    local common=(--keys-img "${KEYS_IMG}" --run-dir "${LAUNCH_DIR}" --keep
                  --ssh-port "${SSH_PORT}" --ui-port "${UI_PORT}" --timeout "${TIMEOUT}"
                  --http-port "${HTTP_PORT}" --api-port "${API_PORT}" --hs-port "${HS_PORT}")
    [ -n "${IMG}" ]      && common+=(--img "${IMG}")
    [ -n "${WORK_DIR}" ] && common+=(-w "${WORK_DIR}")
    [ -n "${MEM}" ]      && common+=(--mem "${MEM}")
    [ -n "${SMP}" ]      && common+=(--smp "${SMP}")
    if [ -n "${AVC_LAUNCH_CMD:-}" ]; then
        ${AVC_LAUNCH_CMD} "${common[@]}"; return $?
    fi
    case "${PLATFORM}" in
        x86)
            bash "${SCRIPT_DIR}/launch-x86.sh" -r "${ROLE}" "${common[@]}" ;;
        rpi5)
            if [ -n "${KERNEL}" ]; then
                bash "${SCRIPT_DIR}/launch-pi.sh" -r "${ROLE}" --kernel "${KERNEL}" "${common[@]}"
            else
                # The golden image carries its own kernel — extracting it is
                # always version-correct (needs root for the loop mount).
                bash "${SCRIPT_DIR}/launch-pi.sh" -r "${ROLE}" --kernel-from-img "${common[@]}"
            fi ;;
        *)
            bash "${SCRIPT_DIR}/launch-arm.sh" --platform "${PLATFORM}" \
                ${BOARD:+--board "${BOARD}"} -r "${ROLE}" \
                ${KERNEL:+--kernel "${KERNEL}"} "${common[@]}" ;;
    esac
}
launch 2>&1 | tee "${RUN_DIR}/launch.log"
lrc=${PIPESTATUS[0]}
[ "${lrc}" -eq 0 ] || die "launcher exited ${lrc} (see ${RUN_DIR}/launch.log)"

cleanup() {
    [ -f "${PIDFILE}" ] && kill "$(cat "${PIDFILE}")" 2>/dev/null || true
    ${KEEP} || rm -f "${LAUNCH_DIR}/run.qcow2" "${LAUNCH_DIR}"/*.qcow2 2>/dev/null || true
}
trap cleanup EXIT

# ── SSH plumbing (every remote call timeout-bounded) ─────────────────────────
SSH_OPTS=(-i "${SSHKEY}" -p "${SSH_PORT}"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o LogLevel=ERROR)
gssh() {
    # gssh <wall-secs> <remote argv...>  (stdin flows through)
    local secs="$1"; shift
    if [ -n "${AVC_SSH_CMD:-}" ]; then
        timeout -k 30 "${secs}" ${AVC_SSH_CMD} "$@"
    else
        timeout -k 30 "${secs}" ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" "$@"
    fi
}

step "Waiting up to ${TIMEOUT}s for guest SSH (${SSH_USER}@localhost:${SSH_PORT})"
deadline=$((SECONDS + TIMEOUT)); up=false
while [ "${SECONDS}" -lt "${deadline}" ]; do
    if [ -z "${AVC_SSH_CMD:-}" ] && [ -f "${PIDFILE}" ] && ! kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
        warn "QEMU exited early"; break
    fi
    if gssh 20 true </dev/null 2>/dev/null; then up=true; break; fi
    sleep 5
done
if ! ${up}; then
    echo "----- last 80 lines of console -----"
    tail -n 80 "${LAUNCH_DIR}/console.log" 2>/dev/null || true
    die "guest did not reach SSH within ${TIMEOUT}s"
fi
info "SSH is up"

# ── hugmesh_authkeys.te workout: real logins THROUGH sshd ───────────────────
# Every ssh here goes sshd -> AuthorizedKeysCommand, the one path that runs
# hugmesh-authorized-keys-lookup in its own domain on registry-enforced nodes.
step "Driving ${LOGINS} extra ssh login(s) (AuthorizedKeysCommand / hugmesh_authkeys.te)"
: > "${RUN_DIR}/logins.log"
for _i in $(seq 1 "${LOGINS}"); do
    gssh 60 'id && echo "login-probe ok"' </dev/null >> "${RUN_DIR}/logins.log" 2>&1 \
        || warn "login probe ${_i} failed (rc=$?)"
done

# ── optional enforcing flip (the campaign this harness exists for) ───────────
if ${ENFORCING}; then
    step "setenforce 1 (workout runs ENFORCING; provisioning stayed permissive)"
    gssh 60 'sudo setenforce 1 && getenforce' </dev/null \
        || die "setenforce 1 failed — is a policy actually loaded on this image?"
fi

# ── the workload probes ──────────────────────────────────────────────────────
step "Running workload probes in the guest (wall clock: ${PROBE_TIMEOUT}s)"
gssh "${PROBE_TIMEOUT}" 'sudo bash -s' < "${SCRIPT_DIR}/avc-workload.sh" 2>&1 \
    | tee "${RUN_DIR}/probes.log"
prc=${PIPESTATUS[0]}
[ "${prc}" -eq 0 ] || warn "workload probe run exited ${prc} (124/137 = wall clock hit) — continuing to harvest what it produced"

# One more login AFTER the probes so the authkeys path is exercised under the
# workout mode too (matters for --enforcing).
gssh 60 'echo "post-workout login ok"' </dev/null >> "${RUN_DIR}/logins.log" 2>&1 || true

# ── harvest ──────────────────────────────────────────────────────────────────
step "Harvesting AVCs + policy state from the guest"
gssh 300 'sudo bash -s' > "${RUN_DIR}/avc-raw.txt" 2>/dev/null <<'HARVEST' || warn "AVC harvest ssh failed — report will be empty"
# Prefer ausearch (structured, survives ring-buffer wrap); fall back to dmesg
# when ausearch/auditd is absent or there is no audit log to search.
if command -v ausearch >/dev/null 2>&1 && out="$(ausearch -m AVC,USER_AVC -ts boot 2>/dev/null)"; then
    printf '%s\n' "${out}"
else
    dmesg 2>/dev/null | grep -E 'type=1400|type=1107|avc: *denied' || true
fi
HARVEST

gssh 60 'sudo cat /usr/share/hugmesh/selinux-modules.list 2>/dev/null || true' \
    </dev/null > "${RUN_DIR}/manifest.txt" 2>/dev/null || true
gssh 120 'sudo bash -s' > "${RUN_DIR}/semodule-l.txt" 2>/dev/null <<'SEML' || true
type="$(sed -n 's/^SELINUXTYPE=//p' /etc/selinux/config 2>/dev/null | tail -1)"
semodule -s "${type:-mcs}" -l 2>/dev/null || true
SEML
gssh 60 'getenforce 2>/dev/null || echo unknown' </dev/null > "${RUN_DIR}/getenforce.txt" 2>/dev/null || true
gssh 60 'sudo cat /var/lib/keys-provision/selinux-modules.status 2>/dev/null || true' \
    </dev/null > "${RUN_DIR}/selinux-modules.status" 2>/dev/null || true
gssh 120 'sudo cat /var/log/keys-provision.log 2>/dev/null || true' \
    </dev/null > "${RUN_DIR}/keys-provision.log" 2>/dev/null || true

# ── polite teardown (the overlay is throwaway, but leave a clean corpse) ─────
${ENFORCING} && { gssh 60 'sudo setenforce 0' </dev/null >/dev/null 2>&1 || true; }
step "Powering down guest"
gssh 65 'sudo poweroff' </dev/null >/dev/null 2>&1 || true
sleep 3

# ── gates ────────────────────────────────────────────────────────────────────
step "Gating: manifest modules loaded + mode as expected"
FAILED=""
MODCOUNT=0
if [ ! -s "${RUN_DIR}/manifest.txt" ]; then
    FAILED="${FAILED} no-module-manifest"
    warn "no /usr/share/hugmesh/selinux-modules.list on the guest — this image never staged"
    warn "node policy (predates the lib, or HUGMESH_SELINUX_MODULES=0); nothing to work out."
else
    while read -r _m; do
        case "${_m}" in ''|'#'*) continue ;; esac
        MODCOUNT=$((MODCOUNT + 1))
        if grep -q "^${_m}\b" "${RUN_DIR}/semodule-l.txt" 2>/dev/null; then
            info "  module ${_m}: loaded"
        else
            warn "  module ${_m}: NOT in semodule -l"
            FAILED="${FAILED} module-not-loaded:${_m}"
        fi
    done < "${RUN_DIR}/manifest.txt"
    [ "${MODCOUNT}" -gt 0 ] || FAILED="${FAILED} manifest-empty"
fi
if grep -qE " (failed|missing-pp)$" "${RUN_DIR}/selinux-modules.status" 2>/dev/null; then
    warn "provision recorded per-module load failures (selinux-modules.status):"
    grep -E " (failed|missing-pp)$" "${RUN_DIR}/selinux-modules.status" | sed 's/^/    | /' >&2
    FAILED="${FAILED} provision-recorded-failure"
fi
LIVE_MODE="$(tr '[:upper:]' '[:lower:]' < "${RUN_DIR}/getenforce.txt" 2>/dev/null | head -1)"
if [ "${LIVE_MODE}" = "${EXPECTED_MODE}" ]; then
    info "  getenforce: ${LIVE_MODE} (expected ${EXPECTED_MODE})"
else
    warn "  getenforce: '${LIVE_MODE:-<none>}' != expected '${EXPECTED_MODE}'"
    FAILED="${FAILED} mode-mismatch"
fi

# ── the narrowing report ─────────────────────────────────────────────────────
step "Generating the narrowing report"
bash "${SCRIPT_DIR}/avc-report.sh" "${RUN_DIR}/avc-raw.txt" "${REPO_DIR}/specs/selinux" \
    > "${RUN_DIR}/report.txt" \
    || { warn "avc-report.sh failed"; FAILED="${FAILED} report-generation"; }
cat "${RUN_DIR}/report.txt" 2>/dev/null || true

echo
if [ -z "${FAILED}" ]; then
    info "${GREEN}AVC-WORKOUT RESULT: PASS${RST} (${MODCOUNT} module(s) loaded, mode=${EXPECTED_MODE}) — report: ${RUN_DIR}/report.txt"
    exit 0
else
    warn "AVC-WORKOUT RESULT: FAIL —${FAILED}"
    warn "artifacts: ${RUN_DIR}"
    exit 1
fi
