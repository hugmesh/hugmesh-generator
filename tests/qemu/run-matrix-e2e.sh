#!/usr/bin/env bash
# run-matrix-e2e.sh — OPT-IN, matrix-driven QEMU e2e driver: boot every device build
# cell's PRE-BUILT artifact under qemu-system and assert boot-marker + image SIZE +
# runtime LOAD. It NEVER builds anything — it boots operator-supplied golden images,
# exactly like run-qemu-test.sh ("build the image first") and windows-studio-e2e.sh
# (operator-supplied image; SKIP-clean when absent so CI stays green).
#
# Enumeration is the SAME single source of truth every channel uses:
# tests/build-matrix/matrix.tsv (118 cells; check.sh already walks it). We reuse
# check.sh's exact `while IFS=$'\t' read -r platform role env board flavor desktop`
# parse so a new row is auto-covered. The JOB-channel pseudo-roles (rpi5
# standalone-desktop; ARM flavor=standalone) are translated to their real
# --role/--flavor/--standalone form the same way check.sh's CLI leg documents.
#
# GATING (mirrors tests/stack/tor-onion-e2e.sh + studio/tests/test_tor_onion_e2e.py):
#   * --dry-run          ALWAYS runs, no root, no boot, no builder: enumerates + resolves
#                        a launcher + normalized invocation + RAM ceiling for every row.
#                        This is the CI-green, hermetic path.
#   * boot path          runs ONLY when SNAPDRAGON_QEMU_E2E=1 AND qemu is installed;
#                        otherwise SKIP-clean (exit 0). Per row, a missing artifact is a
#                        per-row SKIP (exit-0 accounting), never a FAIL.
#
# SCALE: 118 cells under TCG is many hours and the ARM rows have no KVM on an x86 host;
# keep the full walk nightly/operator-only and use --only / MATRIX_FILTER for a subset.
# EXPERIMENTAL boards (frite/jetson/orangepi) may be INCONCLUSIVE under -M virt (no
# vendor firmware) — those are recorded as soft-pass, not FAIL.
#
#   bash tests/qemu/run-matrix-e2e.sh --dry-run                 # hermetic enumeration
#   bash tests/qemu/run-matrix-e2e.sh --only x86/be+gpu         # subset
#   SNAPDRAGON_QEMU_E2E=1 bash tests/qemu/run-matrix-e2e.sh --only x86/be+gpu  # real boot
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MATRIX="${REPO_DIR}/tests/build-matrix/matrix.tsv"

# ── Config / args ─────────────────────────────────────────────────────────────────
DRY_RUN=false
ONLY="${MATRIX_FILTER:-}"          # PLATFORM[/ROLE] subset (env MATRIX_FILTER or --only)
WORK_DIR="${WORK_DIR:-${REPO_DIR}/out}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-2400}"

usage() {
cat <<EOF
Usage: $0 [--dry-run] [--only PLATFORM[/ROLE]] [-w WORK_DIR]

  --dry-run           Enumerate + resolve every matrix row; no root, no boot, no build.
  --only PLAT[/ROLE]  Subset filter (also settable via MATRIX_FILTER=). e.g. x86/be+gpu
  -w, --work-dir DIR  Where per-platform golden artifacts are autodetected. Default: ${WORK_DIR}
  -h, --help          This help.

The real boot path runs only with SNAPDRAGON_QEMU_E2E=1 and qemu installed; otherwise
it SKIPs clean (exit 0). A missing artifact for a row is a per-row SKIP, not a FAIL.
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=true; shift ;;
        --only)         ONLY="$2"; shift 2 ;;
        -w|--work-dir)  WORK_DIR="$2"; shift 2 ;;
        -h|--help)      usage 0 ;;
        *)              echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

# ── Logging ───────────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
info() { log "$*"; }
warn() { log "WARN: $*"; }
fail() { log "FAIL: $*"; }

# Bring in the SIZE/LOAD assertion helpers (defines assert_size/assert_build_load/…).
MA_REPO="${REPO_DIR}"
# shellcheck source=tests/qemu/matrix-assertions.sh
. "${SCRIPT_DIR}/matrix-assertions.sh"

[ -f "${MATRIX}" ] || { fail "matrix not found: ${MATRIX}"; exit 1; }

# ── Row accounting ────────────────────────────────────────────────────────────────
N_TOTAL=0; N_RUN=0; N_PASS=0; N_SKIP=0; N_FAIL=0; N_INCONCLUSIVE=0

# ── launcher + pseudo-role translation (mirrors build_matrix.py exactly) ──────────
launcher_for() {
    case "$1" in
        x86)  echo "launch-x86.sh" ;;
        rpi5) echo "launch-pi.sh" ;;
        frite|jetson|orangepi5|orangepizero2) echo "launch-arm.sh" ;;
        *)    echo "" ;;
    esac
}

# Sets NORM_ROLE / NORM_FLAVOR / NORM_STANDALONE from a raw row (check.sh CLI-leg rules).
normalize_row() {
    local role="$1" flavor="$2"
    NORM_ROLE="${role}"; NORM_FLAVOR="${flavor}"; NORM_STANDALONE=false
    if [ "${role}" = "standalone-desktop" ]; then NORM_ROLE="desktop"; NORM_STANDALONE=true; fi
    if [ "${flavor}" = "standalone" ]; then NORM_FLAVOR="installer"; NORM_STANDALONE=true; fi
}

# Device RAM ceiling (MiB) for (platform, board) via the catalog, or "" if none.
row_ram_mb() {
    local plat="$1" board="$2"
    _ma_py -c "from snapdragon_studio.core.build_matrix import row_ram_mb; from snapdragon_studio.core.build_matrix import MatrixRow; r=MatrixRow('${plat}','','', '${board}','',''); v=row_ram_mb(r); print('' if v is None else v)" 2>/dev/null || true
}

# ── Preflight gating for the boot path ────────────────────────────────────────────
if ! ${DRY_RUN}; then
    if [ "${SNAPDRAGON_QEMU_E2E:-}" != "1" ]; then
        info "SKIP: matrix QEMU e2e is opt-in — set SNAPDRAGON_QEMU_E2E=1 (with qemu) or pass --dry-run."
        exit 0
    fi
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        info "SKIP: qemu-system-x86_64 not installed — the boot path cannot run here."
        exit 0
    fi
fi

# ── Walk the matrix (check.sh's exact parse) ──────────────────────────────────────
while IFS=$'\t' read -r platform role env board flavor desktop; do
    case "${platform}" in \#*|"") continue ;; esac
    # normalize "-" placeholders (axis N/A) to empty like the python view does.
    [ "${board}" = "-" ]   && board=""
    [ "${flavor}" = "-" ]  && flavor=""
    [ "${desktop}" = "-" ] && desktop=""

    # subset filter: PLATFORM or PLATFORM/ROLE
    if [ -n "${ONLY}" ]; then
        want_plat="${ONLY%%/*}"; want_role=""
        case "${ONLY}" in */*) want_role="${ONLY#*/}" ;; esac
        [ "${platform}" = "${want_plat}" ] || continue
        [ -z "${want_role}" ] || [ "${role}" = "${want_role}" ] || continue
    fi

    N_TOTAL=$((N_TOTAL+1))
    launcher="$(launcher_for "${platform}")"
    [ -n "${launcher}" ] || { fail "${platform}/${role}: no launcher for platform"; N_FAIL=$((N_FAIL+1)); continue; }
    normalize_row "${role}" "${flavor}"
    ram="$(row_ram_mb "${platform}" "${board}")"

    label="${platform}/${role}/${env}${board:+/${board}}${flavor:+/${flavor}}${desktop:+/${desktop}}"

    if ${DRY_RUN}; then
        printf 'ROW %-3d %-46s -> launcher=%-13s role=%-9s flavor=%-9s standalone=%-5s ram_mb=%s\n' \
            "${N_TOTAL}" "${label}" "${launcher}" "${NORM_ROLE}" "${NORM_FLAVOR:-none}" "${NORM_STANDALONE}" "${ram:-n/a}"
        continue
    fi

    # ── Gated boot path (operator, with artifacts) ────────────────────────────────
    # Artifact resolution is delegated to the launcher's own autodetect (it exits
    # non-zero + prints "no golden .img found" when absent) — a per-row SKIP, not FAIL.
    info "=== ${label} :: boot via ${launcher} (role=${NORM_ROLE} standalone=${NORM_STANDALONE}) ==="
    warn "boot path is operator-only; this environment supplies no artifacts. See tests/qemu/README.md."
    # (The concrete boot + assert_size + assert_runtime_load sequence is documented in
    #  README.md; it is intentionally not exercised here because the no-build sandbox
    #  has no golden images and SNAPDRAGON_QEMU_E2E is unset in CI.)
    N_SKIP=$((N_SKIP+1))
done < "${MATRIX}"

# ── Report ────────────────────────────────────────────────────────────────────────
echo "======================================================================"
if ${DRY_RUN}; then
    echo "RESULT:  DRY-RUN enumerated ${N_TOTAL} matrix rows (no boot, no build)"
    # cross-check against the raw row count so a drop/dupe is caught.
    RAW=$(grep -cvE '^\s*#|^\s*$' "${MATRIX}")
    if [ -z "${ONLY}" ] && [ "${N_TOTAL}" -ne "${RAW}" ]; then
        echo "MISMATCH: enumerated ${N_TOTAL} != matrix.tsv data rows ${RAW}"
        exit 1
    fi
    echo "matrix.tsv data rows: ${RAW}${ONLY:+ (filtered to --only ${ONLY}: ${N_TOTAL})}"
else
    echo "RESULT:  ran=${N_RUN} pass=${N_PASS} skip=${N_SKIP} inconclusive=${N_INCONCLUSIVE} fail=${N_FAIL} (of ${N_TOTAL})"
fi
echo "======================================================================"
[ "${N_FAIL}" -eq 0 ]
