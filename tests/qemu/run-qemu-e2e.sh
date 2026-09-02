#!/usr/bin/env bash
# run-qemu-e2e.sh — the QEMU analogue of tests/e2e/run-all.sh: validate a REAL
# booted HugMesh image with the EXISTING Playwright suite, instead of the
# rootless mock stack (tests/stack).
#
# Pipeline (mirrors run-all.sh's 5 phases):
#   [1/5] boot the role VM(s):  x86 host (.img, KVM-fast, self-booting OVMF) via
#         launch-x86.sh, and/or the Pi role via launch-pi.sh (-M virt + kernel).
#         The launchers forward guest :22 -> --ssh-port and the guest UI/gateway
#         HTTPS port -> --ui-port on the host.
#   [2/5] wait for in-VM readiness: SSH up, then the forwarded UI answers HTTPS.
#   [3/5] seed accounts: seed-accounts.sh pushes the e2e identities into the
#         booted node's BFF allowlist over SSH (admin@, 5 gmail users, dragoneer).
#   [4/5] run the UNCHANGED specs: tests/e2e/run.sh with SNAP_BASE_URL pointed at
#         the forwarded UI port (same playwright.config.ts, specs, accounts).
#   [5/5] capture screenshots + tear down the VM(s).
#
# Requires root for the launchers (loop-mount / KVM disk prep). Arg parsing +
# artifact autodetect are testable without root (use --dry-run).
#
# LAUNCHER CONTRACT (launch-x86.sh / launch-pi.sh, Phase 0 siblings):
#   launch-x86.sh --img FILE --keys-img FILE --ssh-port N --ui-port N \
#                 [--mem MB --smp N --accel kvm|tcg] --run-dir DIR --keep
#   launch-pi.sh  -w DIR -r ROLE --kernel FILE --keys-img FILE \
#                 --ssh-port N --ui-port N --run-dir DIR --keep
#   Both: daemonize BY DEFAULT (--foreground is the opt-in), and write qemu.pid +
#   console.log INSIDE --run-dir — there is no --pidfile/--console/--daemonize flag,
#   and an unknown flag is a hard error, so this block is load-bearing. --keep stops
#   the launcher's EXIT trap from deleting that dir out from under this driver.
#   Both forward 22->ssh-port and the guest UI HTTPS port -> ui-port. Neither takes
#   --stage4: fabricating a rootfs from a stage4 is run-qemu-test.sh's job, a
#   different harness; these launchers boot the golden .img.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
E2E_DIR="${REPO_DIR}/tests/e2e"

# ── Defaults ───────────────────────────────────────────────────────
WORK_DIR="${WORK_DIR:-${REPO_DIR}/rpi5-stage4-build}"
TARGET="x86"                 # x86 | pi | both
ROLE="frontend"              # role whose UI/gateway the specs drive
IMG=""                       # x86 .img (autodetected if empty)
KERNEL=""                    # pi kernel Image (autodetected if empty)
STAGE4=""                    # pi stage4 (autodetected if empty)
TEST_DIR=""                  # scratch dir
SSH_PORT="${SSH_PORT:-2222}"
UI_PORT="${UI_PORT:-8443}"   # host port the launcher forwards the guest UI to
SSH_USER="${SSH_USER:-tester}"
MEM="${MEM:-4096}"
SMP="${SMP:-4}"
ACCEL="${ACCEL:-auto}"       # auto -> kvm for x86 if /dev/kvm usable, else tcg
TIMEOUT="${TIMEOUT:-1800}"   # seconds to wait for SSH (slow under TCG)
UI_TIMEOUT="${UI_TIMEOUT:-300}"
KEEP=false
DRY_RUN=false
LIST_ONLY=false
LAUNCH_X86="${LAUNCH_X86:-${SCRIPT_DIR}/launch-x86.sh}"
LAUNCH_PI="${LAUNCH_PI:-${SCRIPT_DIR}/launch-pi.sh}"
KERNEL_IMG_NAME="kernel_2712.img"

usage() {
cat <<EOF
Usage: $0 [OPTIONS] [-- <extra playwright args>]

Booting needs uid 0 (the launchers loop-mount the golden image). Run it from a
root shell or from the privileged hugmesh-qemu-runner container — this script
never invokes sudo, because the Studio drives it and a GUI cannot answer a
password prompt. --list and --dry-run need no root at all.

  -t, --target T       Which VM(s): x86 | pi | both. Default: ${TARGET}
  -r, --role ROLE      Image role to boot/test. Default: ${ROLE}
      --img FILE       x86 .img artifact (default: newest in <work>).
      --kernel FILE    Pi kernel Image (default: <work>/.../${KERNEL_IMG_NAME}).
      --stage4 FILE    Pi stage4 tarball (default: newest matching role in <work>).
  -w, --work-dir DIR   Artifact dir. Default: ${WORK_DIR}
      --test-dir DIR   Scratch dir for disks/logs. Default: <work>/qemu-e2e
      --ssh-port PORT  Host port forwarded to guest :22. Default: ${SSH_PORT}
      --ui-port PORT   Host port forwarded to the guest UI (HTTPS). Default: ${UI_PORT}
      --ssh-user USER  Login user seeded onto the image. Default: ${SSH_USER}
  -m, --mem MB         Guest RAM. Default: ${MEM}
      --smp N          Guest vCPUs. Default: ${SMP}
      --accel A        auto | kvm | tcg. Default: ${ACCEL}
      --timeout SEC    Max wait for SSH. Default: ${TIMEOUT}
      --ui-timeout SEC Max wait for the forwarded UI. Default: ${UI_TIMEOUT}
      --keep           Don't tear down / delete scratch on exit.
      --dry-run        Resolve artifacts + print the plan; don't boot (no root).
      --list           Enumerate the boot plan AND the Playwright specs that would
                       run, as JSON; boots nothing, needs no root and no network.
  -h, --help           Show this help.

Everything after -- is passed through to Playwright (e.g. -- 01-frontpage).
EOF
exit "${1:-0}"
}

PW_ARGS=()
# The invocation as typed, kept so the non-root refusal can echo back the SAME
# command with --list/--dry-run appended instead of a generic stub. `$*` inside the
# loop below is already empty (every arm shifts), which is what made the first cut
# of that hint print a bare flag.
ORIG_ARGV=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)   TARGET="$2"; shift 2 ;;
        -r|--role)     ROLE="$2"; shift 2 ;;
        --img)         IMG="$2"; shift 2 ;;
        --kernel)      KERNEL="$2"; shift 2 ;;
        --stage4)      STAGE4="$2"; shift 2 ;;
        -w|--work-dir) WORK_DIR="$2"; shift 2 ;;
        --test-dir)    TEST_DIR="$2"; shift 2 ;;
        --ssh-port)    SSH_PORT="$2"; shift 2 ;;
        --ui-port)     UI_PORT="$2"; shift 2 ;;
        --ssh-user)    SSH_USER="$2"; shift 2 ;;
        -m|--mem)      MEM="$2"; shift 2 ;;
        --smp)         SMP="$2"; shift 2 ;;
        --accel)       ACCEL="$2"; shift 2 ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        --ui-timeout)  UI_TIMEOUT="$2"; shift 2 ;;
        --keep)        KEEP=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --list)        LIST_ONLY=true; shift ;;
        -h|--help)     usage 0 ;;
        --)            shift; PW_ARGS=("$@"); break ;;
        *)             echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YEL=$'\033[0;33m'; RST=$'\033[0m'
info() { echo "${GREEN}[qemu-e2e]${RST} $*"; }
step() { echo "${CYAN}==> $*${RST}"; }
warn() { echo "${YEL}[qemu-e2e] WARN:${RST} $*"; }
die()  { echo "${RED}[qemu-e2e] ERROR:${RST} $*" >&2; exit 1; }

case "${TARGET}" in x86|pi|both) ;; *) die "invalid --target '${TARGET}' (x86|pi|both)";; esac

# ── Artifact autodetect (testable without root) ────────────────────
[ -n "${TEST_DIR}" ] || TEST_DIR="${WORK_DIR}/qemu-e2e"

autodetect_x86() {
    [ -n "${IMG}" ] && return 0
    for c in "${WORK_DIR}"/*-x86-*.img "${WORK_DIR}"/hugmesh-host*.img "${WORK_DIR}"/*.img; do
        [ -f "${c}" ] && { IMG="${c}"; return 0; }
    done
    return 1
}
autodetect_pi() {
    if [ -z "${KERNEL}" ]; then
        # Per-arch build subdir first (snap-build-pi5); bare paths kept as a
        # fallback for trees built before the per-arch split.
        PI_BUILD_SUBDIR="${PI_BUILD_SUBDIR:-snap-build-pi5}"
        for c in "${WORK_DIR}/${PI_BUILD_SUBDIR}/isoroot/boot/${KERNEL_IMG_NAME}" \
                 "${WORK_DIR}/${PI_BUILD_SUBDIR}/sysroot/boot/${KERNEL_IMG_NAME}" \
                 "${WORK_DIR}/isoroot/boot/${KERNEL_IMG_NAME}" \
                 "${WORK_DIR}/sysroot/boot/${KERNEL_IMG_NAME}"; do
            [ -f "${c}" ] && { KERNEL="${c}"; break; }
        done
    fi
    if [ -z "${STAGE4}" ]; then
        # newest-by-mtime match (mirrors run-qemu-test.sh); ls -t for the time sort.
        # shellcheck disable=SC2012
        STAGE4="$(ls -1t "${WORK_DIR}"/stage4-*-"${ROLE}"-k8s-*.tar.xz 2>/dev/null | head -1 || true)"
        # shellcheck disable=SC2012
        [ -n "${STAGE4}" ] || STAGE4="$(ls -1t "${WORK_DIR}"/stage4-*.tar.xz 2>/dev/null | head -1 || true)"
    fi
    [ -n "${KERNEL}" ] || return 1
    # launch-pi.sh boots the golden .img — it has no --stage4 at all (that is
    # run-qemu-test.sh's input, a different harness) — so kernel + a bootable
    # golden image IS a complete boot set. Requiring a stage4 alongside one
    # turned a perfectly bootable work dir into "pi kernel+stage4 not found".
    # The stage4 is only the LAST resort signal that the tree at least built
    # this role, kept for work dirs that hold no golden image yet.
    # The leading `*-` is the ${BRAND} field; `-rpi5-` stays the literal anchor.
    if compgen -G "${WORK_DIR}/"*"-rpi5-*-${ROLE}-*.img*" >/dev/null 2>&1 \
       || compgen -G "${WORK_DIR}/"*"-rpi5-*.img*" >/dev/null 2>&1; then
        return 0
    fi
    [ -n "${STAGE4}" ]
}

# Resolve accel for x86 (auto -> kvm if usable).
resolve_accel() {
    if [ "${ACCEL}" = "auto" ]; then
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL="kvm"; else ACCEL="tcg"; fi
    fi
}

# ── --list: enumerate what this lane WOULD run, boot nothing ───────────────
# Added 2026-08-26 so the feature tree (and the Studio's QEMU page) can answer
# "what does the QEMU Playwright lane actually run?" without root, without an
# image and without a network. It runs BEFORE the autodetect-or-die block below
# on purpose: a tree with no artifacts yet must still be able to enumerate the
# lane, so here a missing image is a REPORTED null, not a fatal.
#
# The spec half is `playwright test --list`, which resolves and loads every spec
# file, prints the tree and exits — no browser, no request.
#
# --reporter=json is FORCED, and that is not cosmetic (measured for `make
# stack-e2e-list` on 2026-08-26): under this config's own reporter array a bare
# --list still fires every FILE writer, leaving junit.xml, report.json and the
# hugmesh reporter's summary.json in SNAP_REPORT_DIR describing zero tests — an
# enumeration would clobber the durable artifacts of the last real run. A CLI
# --reporter REPLACES the array, so the one flag both makes this machine-readable
# and disarms the writers.
#
# It deliberately does NOT go through tests/e2e/run.sh: run.sh hardcodes
# --reporter=list (which would re-arm nothing but also RUN nothing useful here)
# and picks a docker engine from whether PW_IMAGE happens to exist on the box.
json_str() {   # escape one value for JSON: backslash, quote, then control chars
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\n'/\\n}"
    v="${v//$'\t'/\\t}"
    printf '"%s"' "${v}"
}
json_or_null() { if [ -n "$1" ]; then json_str "$1"; else printf 'null'; fi; }

if ${LIST_ONLY}; then
    # Non-fatal resolution: report what IS on disk, blank what is not.
    if [[ "${TARGET}" == "x86" || "${TARGET}" == "both" ]]; then
        autodetect_x86 || IMG=""
        resolve_accel
    fi
    if [[ "${TARGET}" == "pi" || "${TARGET}" == "both" ]]; then
        autodetect_pi || true
    fi
    pw_json="null"
    pw_skip="null"
    if [ ! -d "${E2E_DIR}/node_modules" ]; then
        # LOUD, NAMED skip — never a silent empty list that reads as "no specs".
        pw_skip="$(json_str "tests/e2e/node_modules is missing: run 'make playwright-deps' once to enumerate the specs")"
        echo "[qemu-e2e --list] SKIPPING the spec enumeration: ${E2E_DIR}/node_modules is missing (run 'make playwright-deps')." >&2
    elif ! command -v npx >/dev/null 2>&1; then
        pw_skip="$(json_str "npx is not on PATH: install Node to enumerate the specs")"
        echo "[qemu-e2e --list] SKIPPING the spec enumeration: npx is not on PATH." >&2
    else
        # `cd` in a subshell so the enumeration cannot leave this script somewhere
        # else, and `|| true` so a Playwright parse error degrades to a reported
        # null instead of taking the boot-plan half down with it.
        pw_out="$( (cd "${E2E_DIR}" && npx playwright test -c playwright.config.ts \
                        --list --reporter=json "${PW_ARGS[@]}") 2>/dev/null || true)"
        if [ -n "${pw_out}" ]; then
            pw_json="${pw_out}"
        else
            pw_skip="$(json_str "playwright test --list produced no output (see stderr)")"
            echo "[qemu-e2e --list] the spec enumeration produced no output." >&2
        fi
    fi
    cat <<EOF
{
  "lane": "qemu-playwright",
  "script": $(json_str "${BASH_SOURCE[0]}"),
  "what_it_does": "boot ONE role VM through launch-x86.sh/launch-pi.sh, seed the e2e identities over SSH, run the UNCHANGED tests/e2e Playwright specs against the guest's forwarded UI",
  "needs_root": true,
  "target": $(json_str "${TARGET}"),
  "role": $(json_str "${ROLE}"),
  "work_dir": $(json_str "${WORK_DIR}"),
  "test_dir": $(json_str "${TEST_DIR}"),
  "ssh_port": ${SSH_PORT},
  "ui_port": ${UI_PORT},
  "ssh_user": $(json_str "${SSH_USER}"),
  "accel": $(json_str "${ACCEL}"),
  "base_url": $(json_str "https://localhost:${UI_PORT}"),
  "artifacts": {
    "x86_img": $(json_or_null "${IMG}"),
    "pi_kernel": $(json_or_null "${KERNEL}"),
    "pi_stage4": $(json_or_null "${STAGE4}")
  },
  "phases": [
    "[1/5] boot the role VM(s) via launch-x86.sh / launch-pi.sh",
    "[2/5] wait for SSH, then for the forwarded UI over HTTPS",
    "[3/5] seed the e2e accounts into the booted node's BFF (seed-accounts.sh)",
    "[4/5] run tests/e2e/run.sh against the forwarded UI",
    "[5/5] power the guest down and capture screenshots"
  ],
  "playwright_args": [$(if [ ${#PW_ARGS[@]} -gt 0 ]; then for a in "${PW_ARGS[@]}"; do printf '%s,' "$(json_str "${a}")"; done | sed 's/,$//'; fi)],
  "playwright": ${pw_json},
  "playwright_skipped": ${pw_skip}
}
EOF
    exit 0
fi

if [[ "${TARGET}" == "x86" || "${TARGET}" == "both" ]]; then
    autodetect_x86 || die "x86 .img not found in ${WORK_DIR} (pass --img). Build the .img first."
    resolve_accel
fi
if [[ "${TARGET}" == "pi" || "${TARGET}" == "both" ]]; then
    autodetect_pi || die "pi kernel + bootable golden .img (or stage4) not found in ${WORK_DIR} (pass --kernel, and build the image first)."
fi

# Which launchers do we need, and do they exist?
need_launcher() { # path label
    [ -x "$1" ] || die "launcher not found/executable: $1 ($2). It is a Phase 0 sibling; see the LAUNCHER CONTRACT in this script's header."
}

info "target  : ${TARGET}  role=${ROLE}"
[ -n "${IMG}" ]    && info "x86 img : ${IMG} (accel=${ACCEL})"
[ -n "${KERNEL}" ] && info "pi kern : ${KERNEL}"
[ -n "${STAGE4}" ] && info "pi s4   : ${STAGE4}"
info "ssh port: ${SSH_PORT}   ui port: ${UI_PORT}   test dir: ${TEST_DIR}"
info "baseURL : https://localhost:${UI_PORT}"

if ${DRY_RUN}; then
    step "dry-run: artifacts resolved, plan printed; not booting."
    [[ "${TARGET}" == "x86" || "${TARGET}" == "both" ]] && echo "  would run: ${LAUNCH_X86} --img ${IMG} --ssh-port ${SSH_PORT} --ui-port ${UI_PORT} --accel ${ACCEL} ..."
    # No --stage4 here: launch-pi.sh REJECTS that flag (unknown args are a hard
    # error in its loop) — the printed plan must be the exact argv the boot
    # phase below really uses, or the dry run advertises a command that dies.
    [[ "${TARGET}" == "pi"  || "${TARGET}" == "both" ]] && echo "  would run: ${LAUNCH_PI} -w ${WORK_DIR} -r ${ROLE} --kernel ${KERNEL} --keys-img <keys.img> --ssh-port ${SSH_PORT} --ui-port ${UI_PORT} ..."
    exit 0
fi

# ── the root requirement, and the container that answers it ────────────────
# launch-x86.sh / launch-pi.sh loop-mount the golden .img to lift its kernel out of
# the boot partition (losetup -P), so this lane genuinely needs uid 0. That is the
# SAME constraint tests/qemu/run-qemu-docker.sh already solved WITHOUT sudo, by
# running the whole harness inside a --privileged container: a privileged container
# is root for anyone in the `docker` group, which is why the Studio can drive the
# device-test lane unattended and could not drive this one at all.
#
# This refusal therefore NAMES that route instead of only saying "run as root" —
# a GUI cannot answer an interactive sudo prompt, and telling an operator to sudo
# is telling them to do the one thing the Studio must not.
#
# WHAT IS NOT DONE HERE, said plainly: this script does not yet RE-EXEC itself into
# that container. Doing so is more than a wrapper — Dockerfile.qemu-runner keeps the
# guest's port forwards INSIDE the container on purpose (its NETWORKING NOTE), and it
# ships no Node/Playwright, so the browser half would have to run on the host against
# a PUBLISHED --ui-port while phases 1-3 run inside. That is a new entrypoint, and it
# cannot be verified without booting a guest. Until it exists, --list and --dry-run
# are the non-root verbs, and the recipe below is the working root-free path.
if [ "$(id -u)" -ne 0 ]; then
    cat >&2 <<EOF
${RED}[qemu-e2e] ERROR:${RST} this lane needs root: the launchers loop-mount the golden
image (losetup -P) to lift its kernel out of the boot partition, and prep the KVM disk.

Three ways forward, in the order you probably want them:

  1. NO ROOT NEEDED — enumerate or preview instead of booting:
       $0 ${ORIG_ARGV[*]:+${ORIG_ARGV[*]} }--list
       $0 ${ORIG_ARGV[*]:+${ORIG_ARGV[*]} }--dry-run

  2. CONTAINERIZED, the way the device-test lane already solves this exact problem.
     A --privileged container is root for anyone in the \`docker\` group, so no sudo
     and no password are involved:
       make qemu-docker-image        # builds hugmesh-qemu-runner:latest
       docker run --rm --privileged \\
           \$( [ -r /dev/kvm ] && [ -w /dev/kvm ] && echo --device /dev/kvm ) \\
           -p ${UI_PORT}:${UI_PORT} -p ${SSH_PORT}:${SSH_PORT} \\
           -v "${REPO_DIR}":/src -v "${WORK_DIR}":/work \\
           --entrypoint /src/tests/qemu/run-qemu-e2e.sh \\
           hugmesh-qemu-runner:latest -w /work --target ${TARGET} --role ${ROLE} \\
           --ssh-port ${SSH_PORT} --ui-port ${UI_PORT}
     NOTE: that image ships qemu + ssh + curl but NOT Node, so phase [4/5] needs a
     Playwright it can reach — run tests/e2e against the PUBLISHED :${UI_PORT} from the
     host (\`make stack-e2e\`-style, SNAP_BASE_URL=https://localhost:${UI_PORT}), or add
     Node to docker/Dockerfile.qemu-runner. This is why the re-exec is not automatic.

  3. From a shell that is ALREADY root (a root login, a CI runner). This script does
     not invoke sudo and never will: the Studio drives it, and a GUI cannot answer an
     interactive password prompt.
EOF
    exit 1
fi
for t in ssh ssh-keygen curl; do command -v "$t" >/dev/null || die "missing tool: $t"; done

rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
SSHKEY="${TEST_DIR}/id_ed25519"
# The launchers do NOT take --pidfile/--console: they take ONE --run-dir and write
# qemu.pid + console.log inside it (launch-x86.sh / launch-pi.sh "--run-dir DIR
# Scratch dir for overlay/vars/pidfile/console"). Deriving both paths from the run
# dir here is what keeps this driver and the launchers agreeing on where they are.
RUN_DIR_X86="${TEST_DIR}/qemu-x86"
RUN_DIR_PI="${TEST_DIR}/qemu-pi"
PIDFILE_X86="${RUN_DIR_X86}/qemu.pid"
PIDFILE_PI="${RUN_DIR_PI}/qemu.pid"
CONSOLE_X86="${RUN_DIR_X86}/console.log"
CONSOLE_PI="${RUN_DIR_PI}/console.log"
KEYS_DIR="${TEST_DIR}/keys"
KEYS_IMG="${TEST_DIR}/keys.img"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() {
    for pf in "${PIDFILE_X86}" "${PIDFILE_PI}"; do
        [ -f "${pf}" ] && kill "$(cat "${pf}")" 2>/dev/null || true
    done
    if ! ${KEEP}; then rm -rf "${TEST_DIR}"; fi
}
trap cleanup EXIT

# ── [1/5] Generate login key + KEYS seed, boot the VM(s) ───────────
step "[1/5] Generating login SSH key + KEYS seed payload"
ssh-keygen -t ed25519 -N '' -C qemu-e2e -f "${SSHKEY}" >/dev/null

# Render the e2e KEYS payload (login user + accounts.json + boot seed hook).
"${SCRIPT_DIR}/seed-accounts.sh" --emit "${KEYS_DIR}" --pubkey "${SSHKEY}.pub" \
    --ssh-user "${SSH_USER}"

# Render the FULL Casdoor RBAC role matrix (systems + games) into the KEYS payload
# so the rbac-*.spec.ts JWT-role assertions have a seeded Casdoor to log into.
# casdoor-systems-roles.json / casdoor-games-users.json + apply-systems-roles.sh
# land under ${KEYS_DIR}/roles/ — the node's casdoor-init consumes them (or
# apply-systems-roles.sh can be run over SSH against the booted Casdoor). The
# games-admin-sync Job then materializes ROLE_GAMES_ADMIN from the seeded grants.
"${SCRIPT_DIR}/seed-accounts.sh" --roles "${KEYS_DIR}"

# Wire the seed hook into provision.json so it runs on first boot.
if command -v jq >/dev/null 2>&1; then
    PJ="${KEYS_DIR}/provision.json"
    if [ -f "${PJ}" ]; then
        tmp="$(mktemp)"; jq '.run = ((.run // []) + ["seed/seed-bff.sh"] | unique)' "${PJ}" > "${tmp}" && mv "${tmp}" "${PJ}"
    else
        cat > "${PJ}" <<EOF
{ "version": 1, "hostname": "hugmesh-e2e", "timezone": "UTC",
  "hugmesh": { "role": "${ROLE}", "cluster_domain": "hugmesh.net" },
  "run": ["seed/seed-bff.sh"] }
EOF
    fi
fi

# Pi needs the KEYS as a FAT32 disk image; x86 .img carries its own ESP+root but
# we still pass the KEYS image so the boot seed hook has accounts.json.
"${SCRIPT_DIR}/make-test-keys.sh" "${KEYS_DIR}" "${KEYS_IMG}" 64

booted=()
if [[ "${TARGET}" == "x86" || "${TARGET}" == "both" ]]; then
    need_launcher "${LAUNCH_X86}" "x86 launcher"
    step "[1/5] Booting x86 host VM (accel=${ACCEL}, mem=${MEM}M)"
    # --keep: without it the launcher's EXIT trap deletes the run dir (and with it the
    # pidfile/console this driver is about to read) the moment it daemonizes.
    "${LAUNCH_X86}" --img "${IMG}" --keys-img "${KEYS_IMG}" \
        --ssh-port "${SSH_PORT}" --ui-port "${UI_PORT}" \
        --mem "${MEM}" --smp "${SMP}" --accel "${ACCEL}" \
        --run-dir "${RUN_DIR_X86}" --keep
    booted+=("x86")
fi
if [[ "${TARGET}" == "pi" || "${TARGET}" == "both" ]]; then
    need_launcher "${LAUNCH_PI}" "pi launcher"
    # If x86 already took SSH_PORT/UI_PORT, the Pi gets +1 (both targets is rare).
    PI_SSH=$([[ "${TARGET}" == both ]] && echo $((SSH_PORT+1)) || echo "${SSH_PORT}")
    PI_UI=$([[ "${TARGET}" == both ]] && echo $((UI_PORT+1)) || echo "${UI_PORT}")
    step "[1/5] Booting Pi role VM (-M virt, mem=${MEM}M)"
    # launch-pi.sh boots the golden .img (with --kernel loaded directly, since QEMU has
    # no BCM2712 firmware chain) — it has no --stage4 at all; that is run-qemu-test.sh's
    # input, a different harness. Point it at the work dir + role and let its own
    # autodetect pick the .img, exactly as `make qemu-rpi` does.
    "${LAUNCH_PI}" -w "${WORK_DIR}" -r "${ROLE}" \
        --kernel "${KERNEL}" --keys-img "${KEYS_IMG}" \
        --ssh-port "${PI_SSH}" --ui-port "${PI_UI}" \
        --mem "${MEM}" --smp "${SMP}" \
        --run-dir "${RUN_DIR_PI}" --keep
    booted+=("pi")
    # The primary target the specs drive: prefer x86 if both, else pi's ports.
    [[ "${TARGET}" == "pi" ]] && { SSH_PORT="${PI_SSH}"; UI_PORT="${PI_UI}"; }
fi

# ── [2/5] Wait for SSH, then the forwarded UI ──────────────────────
SSH_OPTS=(-i "${SSHKEY}" -p "${SSH_PORT}"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o LogLevel=ERROR)
PRIMARY_PIDFILE="${PIDFILE_X86}"; [[ "${TARGET}" == "pi" ]] && PRIMARY_PIDFILE="${PIDFILE_PI}"
PRIMARY_CONSOLE="${CONSOLE_X86}"; [[ "${TARGET}" == "pi" ]] && PRIMARY_CONSOLE="${CONSOLE_PI}"

step "[2/5] Waiting up to ${TIMEOUT}s for SSH (${SSH_USER}@localhost:${SSH_PORT})"
deadline=$((SECONDS + TIMEOUT)); up=false
while [ "${SECONDS}" -lt "${deadline}" ]; do
    if [ -f "${PRIMARY_PIDFILE}" ] && ! kill -0 "$(cat "${PRIMARY_PIDFILE}")" 2>/dev/null; then
        warn "primary VM exited early — see console below"; break
    fi
    if ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" true 2>/dev/null; then up=true; break; fi
    sleep 5
done
if ! ${up}; then
    echo "----- last 60 lines of console -----"; tail -n 60 "${PRIMARY_CONSOLE}" 2>/dev/null || true
    die "guest did not become reachable over SSH within ${TIMEOUT}s"
fi
info "SSH is up."

step "[2/5] Waiting up to ${UI_TIMEOUT}s for the forwarded UI (https://localhost:${UI_PORT}/)"
ui_up=false; ui_deadline=$((SECONDS + UI_TIMEOUT))
while [ "${SECONDS}" -lt "${ui_deadline}" ]; do
    if curl -ksf "https://localhost:${UI_PORT}/" >/dev/null 2>&1; then ui_up=true; break; fi
    sleep 3
done
${ui_up} || warn "forwarded UI did not answer in ${UI_TIMEOUT}s; running specs anyway (some will fail with diagnostics)"

# ── [3/5] Seed accounts into the booted node's BFF ─────────────────
# The boot hook already seeds at first boot; do an idempotent SSH push too, so
# a node that came up before accounts.json was readable still gets seeded.
step "[3/5] Seeding e2e accounts into the booted node's BFF (idempotent)"
"${SCRIPT_DIR}/seed-accounts.sh" --ssh localhost --ssh-user "${SSH_USER}" \
    --ssh-port "${SSH_PORT}" --ssh-key "${SSHKEY}" || warn "SSH seed returned non-zero (boot hook may have already seeded)"

# ── [4/5] Run the EXISTING Playwright specs against the forwarded UI ──
step "[4/5] Running Playwright specs against https://localhost:${UI_PORT}"
set +e
SNAP_BASE_URL="https://localhost:${UI_PORT}" SNAP_SHOTS="${E2E_DIR}/screenshots" \
    bash "${E2E_DIR}/run.sh" "${PW_ARGS[@]}"
rc=$?
set -e

# ── [5/5] Teardown ─────────────────────────────────────────────────
step "[5/5] Powering down guest(s) + tearing down"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" 'sudo poweroff' 2>/dev/null || true
sleep 3
echo "screenshots: ${E2E_DIR}/screenshots"
echo "consoles   : ${PRIMARY_CONSOLE}${booted[*]:+ (booted: ${booted[*]})}"
if [ "${rc}" -eq 0 ]; then info "${GREEN}QEMU E2E PASSED${RST}"; else warn "QEMU E2E FAILED (rc=${rc})"; fi
exit "${rc}"
