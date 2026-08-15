#!/usr/bin/env bash
# save_test.sh — HERMETIC tests for run-qemu-docker.sh's device-save logic.
# Boots nothing, starts no container, talks to no QEMU: the functions under test are
# extracted from the runner and driven with recording stubs.
#
#   bash tests/qemu/save_test.sh
#
# WHY THIS FILE EXISTS. The save path shipped as ~650 lines of shell with no test of
# any kind, and review found three defects in it that only showed up when someone
# ran the thing by hand:
#
#   * a SIGTERM mid-save left the operator's guest PAUSED indefinitely, the copy
#     root-owned, and --list-saves offering the unverified file as a good save;
#   * the failure path fired `block-job-cancel` and `blockdev-del` back to back, but
#     the cancel is ASYNCHRONOUS, so the delete met a busy node, failed silently, and
#     the NEXT save died on "Duplicate nodes" — self-healing only on the third try;
#   * --overwrite and --list-saves disagreed about which file was "the existing
#     copy", so a save made with --save-to <name> was listed but never overwritable,
#     and device x/y could claim x/y-z's saves.
#
# All three are fixed. Each test below fails if its fix is reverted — that is the
# whole point of the file, and mutation was used to confirm it rather than assumed.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${HERE}/run-qemu-docker.sh"
[ -f "${RUNNER}" ] || { echo "cannot find ${RUNNER}" >&2; exit 2; }

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq() { # eq GOT WANT NAME
    if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (got '$1', want '$2')"; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# ── newest_save_for: which file --overwrite replaces ────────────────────────────
echo "newest_save_for — the file --overwrite replaces"
SAVES_DIR="${TMP}/saves"; mkdir -p "${SAVES_DIR}"
sed -n '/^newest_save_for() {/,/^}/p' "${RUNNER}" > "${TMP}/nsf.sh"
grep -q '^newest_save_for() {' "${TMP}/nsf.sh" \
    || { echo "could not extract newest_save_for" >&2; exit 2; }
# shellcheck disable=SC1090
source "${TMP}/nsf.sh"

mk() { # mk FILENAME LABEL_OR_EMPTY AGE_SECONDS
    local f="${SAVES_DIR}/$1"
    : > "${f}"
    [ -n "$2" ] && printf '{"label": "%s"}\n' "$2" > "${f}.json"
    touch -d "@$(( $(date +%s) - $3 ))" "${f}"
}

# A --save-to custom name belongs to the device by its SIDECAR, not by its name.
# Round 1 globbed names only, so this file was listed but could never be overwritten.
mk "rpi5_pki-20260101T000000Z.qcow2" "rpi5/pki" 300
mk "before-upgrade.qcow2"            "rpi5/pki"  60
eq "$(basename "$(newest_save_for rpi5_pki 'rpi5/pki')")" "before-upgrade.qcow2" \
   "picks the newest save the sidecars say is this device's"

# A sibling label must not be swept up by the name glob.
rm -f "${SAVES_DIR:?}"/*
mk "rpi5_pki-20260101T000000Z.qcow2"   "rpi5/pki"   300
mk "rpi5_pki-z-20260102T000000Z.qcow2" "rpi5/pki-z"  60
eq "$(basename "$(newest_save_for rpi5_pki 'rpi5/pki')")" \
   "rpi5_pki-20260101T000000Z.qcow2" \
   "does not steal a sibling device's newer save"

# Saves written before sidecars existed still resolve, by anchored name.
rm -f "${SAVES_DIR:?}"/*
mk "rpi5_pki-20251201T000000Z.qcow2" "" 300
eq "$(basename "$(newest_save_for rpi5_pki 'rpi5/pki')")" \
   "rpi5_pki-20251201T000000Z.qcow2" "still finds a sidecar-less save by name"

# ...but the name fallback is anchored, so x_y cannot claim x_y-z's.
rm -f "${SAVES_DIR:?}"/*
mk "rpi5_pki-z-20260101T000000Z.qcow2" "" 60
eq "$(newest_save_for rpi5_pki 'rpi5/pki')" "" \
   "the name fallback does not match a sibling label"

rm -f "${SAVES_DIR:?}"/*
eq "$(newest_save_for rpi5_pki 'rpi5/pki')" "" "empty when nothing is saved"

# ── save_on_signal: an interrupted save must put the device back ────────────────
echo
echo "save_on_signal — a SIGTERM mid-save"
LOG="${TMP}/actions.log"; : > "${LOG}"
sed -n '/^    save_on_signal() {/,/^    }$/p' "${RUNNER}" | sed 's/^    //' \
    > "${TMP}/handler.sh"
grep -q '^save_on_signal() {' "${TMP}/handler.sh" \
    || { echo "could not extract save_on_signal" >&2; exit 2; }

# A CHILD bash, not a subshell: `$$` stays the parent's PID inside a subshell, so the
# handler's re-raise would kill this test run instead of the process under test.
cat > "${TMP}/run.sh" <<RUNNER_EOF
set -uo pipefail
LOG="${LOG}"
warn() { echo "WARN: \$*" >> "\${LOG}"; }
info() { echo "INFO: \$*" >> "\${LOG}"; }
id()   { echo "1002"; }
qmp_exec() { echo "qmp:\$4 event=\${6:--}" >> "\${LOG}"; return 0; }
docker()   { echo "docker:rename-partial" >> "\${LOG}"; return 0; }
save_restore_state() { echo "restore:prior=\$3" >> "\${LOG}"; return 0; }
label="rpi5/pki"; name="c1"; csock="/work/q.sock"; prior="running"
target="/w/saves/rpi5_pki.qcow2"; ctarget="/work/saves/rpi5_pki.qcow2"
QMP_TIMEOUT=15; SAVE_JOB="hugmesh-save"; SAVE_NODE="hugmesh-save-tgt"
source "${TMP}/handler.sh"
trap 'save_on_signal TERM' TERM
kill -s TERM \$\$
sleep 5
RUNNER_EOF
# The subshell keeps bash's own "Terminated" job notice off this test's output;
# the child really is killed by the handler's re-raise, which is asserted below.
( bash "${TMP}/run.sh" 2>/dev/null ) 2>/dev/null
rc=$?

has() { if grep -q "$1" "${LOG}"; then _ok "$2"; else _bad "$2"; fi; }
# The cancel must be WAITED for. block-job-cancel returns before the job unwinds, so
# a delete fired straight after it meets a busy node and leaks it into the next save.
has 'qmp:block-job-cancel event=BLOCK_JOB_CANCELLED' "waits for BLOCK_JOB_CANCELLED"
has 'qmp:blockdev-del'                               "detaches the save node"
has 'docker:rename-partial'                          "moves the half-written copy aside"
has 'restore:prior=running'                          "restores the PRIOR run state"
if [ "$(grep -n 'restore:' "${LOG}" | cut -d: -f1)" -gt \
     "$(grep -n 'qmp:blockdev-del' "${LOG}" | cut -d: -f1)" ]; then
    _ok "restores only after the node is detached"
else
    _bad "restores before the node is detached"
fi
if [ "${rc}" -ne 0 ]; then _ok "re-raises rather than exiting 0"
else _bad "swallowed the signal (exit ${rc})"; fi

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
