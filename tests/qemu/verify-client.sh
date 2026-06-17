#!/usr/bin/env bash
# verify-client.sh — NON-ROOT boot + console-assertion verification for CLIENT
# desktop images (--role laptop|chromebook|desktop). The lighter sibling of
# run-qemu-e2e.sh: a client is a person's DESKTOP, not a cluster node, so it runs
# NO BFF/gateway/UI — the Playwright node E2E doesn't apply. Instead we boot the
# .img under launch-x86.sh (self-booting OVMF) with a synthetic KEYS disk + a
# virtio-GPU, and assert the boot + first-boot provisioning milestones on the
# serial console (the same approach that console-proved the Pi fleet).
#
# Non-root: launch-x86.sh uses /dev/kvm (magus in the kvm group) and a qcow2
# overlay; the KEYS disk is built with mtools (mcopy), no loop-mount. Use
# --dry-run to validate args + render the KEYS payload without booting.
#
# Usage:
#   ./verify-client.sh -w /home/magus/x86-client-build [--role laptop] \
#                      [--person-role user|superadmin] [--img FILE] [--keep] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

WORK_DIR="${WORK_DIR:-${REPO_DIR}/x86-client-build}"
ROLE="${ROLE:-laptop}"               # laptop | chromebook | desktop
PERSON_ROLE="${PERSON_ROLE:-user}"   # user | mod | admin | superadmin
DOMAIN="${DOMAIN:-acme.example}"
IMG=""
SSH_USER="${SSH_USER:-tester}"
SSH_PORT="${SSH_PORT:-2222}"
MEM="${MEM:-4096}"; SMP="${SMP:-4}"
TEST_DIR="${TEST_DIR:-}"             # scratch (overlay/KEYS/console); default under WORK_DIR
TIMEOUT="${TIMEOUT:-900}"            # console-milestone deadline (TCG-generous)
SSH_TIMEOUT="${SSH_TIMEOUT:-120}"    # extra wait to try SSH after milestones
KEEP=false; DRY_RUN=false
LAUNCH_X86="${LAUNCH_X86:-${SCRIPT_DIR}/launch-x86.sh}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--work-dir)   WORK_DIR="$2"; shift 2 ;;
        -r|--role)       ROLE="$2"; shift 2 ;;
        --person-role)   PERSON_ROLE="$2"; shift 2 ;;
        --domain)        DOMAIN="$2"; shift 2 ;;
        --img)           IMG="$2"; shift 2 ;;
        --ssh-user)      SSH_USER="$2"; shift 2 ;;
        --ssh-port)      SSH_PORT="$2"; shift 2 ;;
        -m|--mem)        MEM="$2"; shift 2 ;;
        --smp)           SMP="$2"; shift 2 ;;
        --test-dir)      TEST_DIR="$2"; shift 2 ;;
        --timeout)       TIMEOUT="$2"; shift 2 ;;
        --keep)          KEEP=true; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; RST=$'\033[0m'
info() { echo "${GREEN}[verify-client]${RST} $*"; }
step() { echo "${CYAN}==> $*${RST}"; }
warn() { echo "${YEL}[verify-client] WARN:${RST} $*" >&2; }
die()  { echo "${RED}[verify-client] ERROR:${RST} $*" >&2; exit 1; }

case "${ROLE}" in laptop|chromebook|desktop) ;; *) die "client --role must be laptop|chromebook|desktop (got '${ROLE}')";; esac
case "${PERSON_ROLE}" in user|mod|admin|superadmin) ;; *) die "--person-role must be user|mod|admin|superadmin";; esac
command -v mcopy >/dev/null || die "need mtools (mcopy) to build the KEYS disk non-root"
command -v ssh-keygen >/dev/null || die "need ssh-keygen"

# ── Resolve the .img (mirror launch-x86.sh autodetect) ─────────────
if [ -z "${IMG}" ]; then
    for c in "${WORK_DIR}"/snapdragon-x86-*-"${ROLE}"-*.img "${WORK_DIR}"/snapdragon-x86-*.img; do
        c="$(ls -1t ${c} 2>/dev/null | head -1 || true)"
        [ -n "${c}" ] && { IMG="${c}"; break; }
    done
fi
if [ -z "${IMG}" ] || [ ! -f "${IMG}" ]; then
    ${DRY_RUN} || die "no client .img found in ${WORK_DIR} (build one, or pass --img). role=${ROLE}"
    IMG="${IMG:-<none-yet:${WORK_DIR}/snapdragon-x86-amd64-${ROLE}-${PERSON_ROLE}-*.img>}"
    warn "dry-run: no .img resolved — using a placeholder (build it before a real run)"
fi

# Scratch defaults under WORK_DIR, but WORK_DIR is often root-owned (a sudo build
# made it), so allow --test-dir to point at a magus-writable location for non-root runs.
[ -n "${TEST_DIR}" ] || TEST_DIR="${WORK_DIR}/qemu-verify-client"
RUN_DIR="${TEST_DIR}/run"
KEYS_DIR="${TEST_DIR}/keys"
KEYS_IMG="${TEST_DIR}/keys.img"
CONSOLE="${RUN_DIR}/console.log"
SSHKEY="${TEST_DIR}/id_ed25519"
HOSTNAME_E2E="snap-${ROLE}-${PERSON_ROLE}-e2e"

info "img        : ${IMG}"
info "role       : ${ROLE}  person-role=${PERSON_ROLE}  domain=${DOMAIN}"
info "work/test  : ${WORK_DIR}  ->  ${TEST_DIR}"

# ── Render the synthetic KEYS payload ──────────────────────────────
rm -rf "${TEST_DIR}"; mkdir -p "${RUN_DIR}" "${KEYS_DIR}"
ssh-keygen -t ed25519 -N '' -C verify-client -f "${SSHKEY}" >/dev/null
PUB="$(cat "${SSHKEY}.pub")"

# superadmin device images require a crypt(3) device-password hash on the KEYS media.
DEVPW_JSON=""
if [ "${PERSON_ROLE}" = "superadmin" ]; then
    if command -v openssl >/dev/null; then
        DPW_HASH="$(openssl passwd -6 'verify-devpass' 2>/dev/null || true)"
    fi
    [ -z "${DPW_HASH:-}" ] && command -v mkpasswd >/dev/null && DPW_HASH="$(mkpasswd -m sha512crypt 'verify-devpass')"
    [ -n "${DPW_HASH:-}" ] || warn "no openssl/mkpasswd — can't make a device-password hash; the superadmin device-password assertion will be skipped"
    [ -n "${DPW_HASH:-}" ] && DEVPW_JSON=", \"client\": { \"device_password_hash\": \"${DPW_HASH}\" }"
fi

cat > "${KEYS_DIR}/provision.json" <<EOF
{
  "version": 1,
  "hostname": "${HOSTNAME_E2E}",
  "timezone": "UTC",
  "users": [
    { "name": "${SSH_USER}", "comment": "verify-client", "sudo": true, "sudo_nopasswd": true,
      "groups": ["wheel","audio","video","usb"], "password": "${SSH_USER}",
      "ssh_authorized_keys": ["${PUB}"] }
  ],
  "root": { "locked": true }${DEVPW_JSON}
}
EOF
info "KEYS payload: hostname=${HOSTNAME_E2E} user=${SSH_USER} (sudo,nopasswd) + ssh key${DEVPW_JSON:+ + device_password_hash}"

if ${DRY_RUN}; then
    step "dry-run: KEYS payload rendered at ${KEYS_DIR}; not booting."
    echo "  provision.json:"; sed 's/^/    /' "${KEYS_DIR}/provision.json"
    echo "  would run: ${LAUNCH_X86} --img ${IMG} --role ${ROLE} --gpu --keys-img <keys.img> --run-dir ${RUN_DIR} --keep"
    exit 0
fi

[ -x "${LAUNCH_X86}" ] || die "launcher not executable: ${LAUNCH_X86}"
"${SCRIPT_DIR}/make-test-keys.sh" "${KEYS_DIR}" "${KEYS_IMG}" 64 >/dev/null
info "KEYS disk  : ${KEYS_IMG}"

# ── Boot (daemonized; launch-x86.sh persists console.log + qemu.pid) ─
step "Booting ${ROLE} image under QEMU (virtio-gpu + KEYS disk)"
"${LAUNCH_X86}" --img "${IMG}" --role "${ROLE}" --gpu --keys-img "${KEYS_IMG}" \
    --run-dir "${RUN_DIR}" --ssh-port "${SSH_PORT}" --mem "${MEM}" --smp "${SMP}" --keep
PIDFILE="${RUN_DIR}/qemu.pid"

teardown() {
    [ -f "${PIDFILE}" ] && kill "$(cat "${PIDFILE}")" 2>/dev/null || true
    ${KEEP} || rm -rf "${TEST_DIR}"
}
trap teardown EXIT

# ── Console milestone assertions ───────────────────────────────────
# name | extended-regex matched against the growing console.log
ASSERTS=(
    "kernel boot|Linux version"
    "OpenRC init|OpenRC [0-9]|sysinit runlevel|Starting sysinit"
    "keys-provision ran|\[keys-provision"
    "KEYS disk read|(KEYS|provision\.json|Applying|Provisioning)"
    "user created|Created user ${SSH_USER}|User ${SSH_USER} already exists"
    "ssh key installed|authorized key.* for ${SSH_USER}"
    "sshd up|Starting sshd|service sshd|sshd .* start"
    "tailscaled present|tailscaled"
    "display-manager/lightdm|display-manager|lightdm|Light Display Manager"
)
[ "${PERSON_ROLE}" = "superadmin" ] && [ -n "${DEVPW_JSON}" ] && \
    ASSERTS+=("superadmin device pw|DEVICE password for")

declare -A HIT=()
step "Watching console for milestones (up to ${TIMEOUT}s): ${CONSOLE}"
deadline=$((SECONDS + TIMEOUT)); all_ok=false
while [ "${SECONDS}" -lt "${deadline}" ]; do
    if [ -f "${PIDFILE}" ] && ! kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
        warn "QEMU exited early."; break
    fi
    [ -f "${CONSOLE}" ] || { sleep 3; continue; }
    pending=0
    for a in "${ASSERTS[@]}"; do
        name="${a%%|*}"; rx="${a#*|}"
        if [ -z "${HIT[$name]:-}" ]; then
            if grep -qiE -- "${rx}" "${CONSOLE}" 2>/dev/null; then
                HIT[$name]=1; info "  ✓ ${name}"
            else
                pending=$((pending+1))
            fi
        fi
    done
    [ "${pending}" -eq 0 ] && { all_ok=true; break; }
    sleep 5
done

# ── Best-effort SSH deepening (x86 NetworkManager usually leases) ───
SSH_OK=false
SSH_OPTS=(-i "${SSHKEY}" -p "${SSH_PORT}" -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
step "Trying SSH (${SSH_USER}@localhost:${SSH_PORT}) for ${SSH_TIMEOUT}s (best-effort)"
ssh_deadline=$((SECONDS + SSH_TIMEOUT))
while [ "${SECONDS}" -lt "${ssh_deadline}" ]; do
    if ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" true 2>/dev/null; then SSH_OK=true; break; fi
    sleep 5
done
if ${SSH_OK}; then
    info "SSH up — deep assertions:"
    got_role="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" 'cat /etc/snapdragon/identity-role 2>/dev/null' || true)"
    got_dom="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" 'head -1 /etc/snapdragon/domains 2>/dev/null' || true)"
    got_dm="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" 'rc-service display-manager status 2>/dev/null | head -1' || true)"
    [ "${got_role}" = "${PERSON_ROLE}" ] && info "  ✓ identity-role=${got_role}" || warn "  identity-role='${got_role}' (expected ${PERSON_ROLE})"
    [ -n "${got_dom}" ] && info "  ✓ domain marker='${got_dom}'" || warn "  domains marker empty"
    echo "${got_dm}" | grep -qi 'start' && info "  ✓ display-manager: ${got_dm}" || warn "  display-manager status: ${got_dm:-<none>}"
else
    warn "SSH not reachable (known qemu user-net/DHCP limitation on some hosts) — relying on console assertions."
fi

# ── Report ─────────────────────────────────────────────────────────
echo; step "RESULT"
fail=0
for a in "${ASSERTS[@]}"; do
    name="${a%%|*}"
    if [ -n "${HIT[$name]:-}" ]; then echo "  ${GREEN}PASS${RST} ${name}"; else echo "  ${RED}FAIL${RST} ${name}"; fail=$((fail+1)); fi
done
echo "  console: ${CONSOLE}"
${KEEP} && echo "  (kept ${TEST_DIR})"
if ${all_ok} && [ "${fail}" -eq 0 ]; then
    info "${GREEN}CLIENT VERIFY PASSED${RST} (${ROLE}/${PERSON_ROLE})"; exit 0
else
    warn "CLIENT VERIFY: ${fail} milestone(s) missing — last 50 console lines:"
    tail -n 50 "${CONSOLE}" 2>/dev/null || true
    exit 1
fi
