#!/usr/bin/env bash
# ── per-image builder log-path guard ─────────────────────────────────────────
# Session 20260716-160638-f8c153 left 8 of its 9 images with NO usable on-disk
# log: build-x86-host-stage4.sh had no log redirect at all (5 x86 runs, ~16min
# each, nothing persisted), 3 rpi5 runs refused before their redirect line, and
# the one jetson run then owned the whole shared build.log. The fix keeps the
# session-shared ${WORK_DIR}/build.log (unchanged name — every existing reader
# keeps working: studio build_sessions.log_path, sessions_widget, build-menu.sh)
# and ALSO tees each run into its own ${WORK_DIR}/build-${BUILD_SUBDIR#wl-}.log
# (wl-<entry-id> -> build-<entry-id>.log for Studio worklist runs), derived
# from the EXISTING --build-subdir argv (no new flags, argv unchanged).
#
# This guard bites when: a builder loses its IMAGE_LOG_FILE derivation, a tee
# stops writing both files, build-x86 loses its (new) redirect entirely, or the
# python-side basename derivation in studio drifts from the shell derivation.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== builder log-paths guard =="

ALL=(build-frite-stage4.sh build-rpi5-stage4.sh build-orangepi5-stage4.sh
     build-orangepi-zero2-stage4.sh build-jetson-stage4.sh build-x86-host-stage4.sh)

# 1+2. every builder: exact IMAGE_LOG_FILE derivation + a tee naming BOTH files.
for s in "${ALL[@]}"; do
    f="${GEN}/${s}"
    if [ ! -f "${f}" ]; then bad "${s}: script missing"; continue; fi
    # NOTE: every pattern below is ^-anchored to a LIVE line (BRE: '$'/'{' are
    # literal mid-regex). An unanchored -F substring match would also accept a
    # COMMENTED-OUT '#IMAGE_LOG_FILE=...' line — i.e. the guard would pass while
    # the builder silently reverted to clobbering sibling logs.
    grep -q '^IMAGE_LOG_FILE="${WORK_DIR}/build-${BUILD_SUBDIR#wl-}\.log"$' "${f}" \
        && ok "${s}: derives IMAGE_LOG_FILE from the existing --build-subdir argv" \
        || bad "${s}: IMAGE_LOG_FILE derivation missing/drifted/commented out"
    grep -q '^exec > >(tee -a "${LOG_FILE}" "${IMAGE_LOG_FILE}") 2>&1$' "${f}" \
        && ok "${s}: tee appends to BOTH the shared and the per-image log" \
        || bad "${s}: log tee no longer writes both files"
    # the shared session log must keep its exact name (readers depend on it).
    grep -q '^LOG_FILE="${WORK_DIR}/build\.log"$' "${f}" \
        && ok "${s}: shared LOG_FILE is still \${WORK_DIR}/build.log" \
        || bad "${s}: shared build.log name changed (breaks studio/build-menu readers)"
done

# 3. regression pin: build-x86 HAS an exec redirect (it historically had none —
#    that is exactly why the 5 x86 failures left no on-disk log).
if grep -qE '^exec > >\(tee -a ' "${GEN}/build-x86-host-stage4.sh"; then
    ok "build-x86-host-stage4.sh: has an exec log redirect (regression pin)"
else
    bad "build-x86-host-stage4.sh: lost its exec log redirect (back to persisting nothing)"
fi

# 4. cross-language derivation parity: studio's image_log_name must mint the
#    same 'build-' + <entry-id> + '.log' basename the shell derives.
BS="${GEN}/studio/snapdragon_studio/core/build_sessions.py"
if [ -f "${BS}" ]; then
    grep -qE 'def image_log_name\(' "${BS}" \
        && ok "studio build_sessions.py: image_log_name helper present" \
        || bad "studio build_sessions.py: image_log_name helper missing"
    grep -qF 'f"build-{entry_id}.log"' "${BS}" \
        && ok "studio build_sessions.py: python derivation is build-<entry-id>.log" \
        || bad "studio build_sessions.py: python log-name derivation drifted from the shell's"
    grep -qF 'LOG_NAME = "build.log"' "${BS}" \
        && ok "studio build_sessions.py: shared LOG_NAME unchanged (build.log)" \
        || bad "studio build_sessions.py: shared LOG_NAME changed"
else
    bad "studio build_sessions.py missing"
fi

echo "== builder-log-paths: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
