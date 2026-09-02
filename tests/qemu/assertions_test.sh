#!/usr/bin/env bash
# assertions_test.sh — HERMETIC unit + wiring tests for the matrix QEMU e2e harness.
# Proves the SIZE / LOAD / boot-marker assertion helpers actually work AND that the
# driver really invokes them (resolve → assert_size → boot → assert_runtime_load →
# tally) — via a STUB launcher + STUB --print-plan, so NOTHING is booted or built.
# This is what catches a regression back to an "always-skip" boot stub.
#
#   bash tests/qemu/assertions_test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
DRIVER="${HERE}/run-matrix-e2e.sh"

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); }
_bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1" >&2; }
ok_if()  { if "$@"; then _ok; else _bad "expected success: $*"; fi; }
bad_if() { if "$@"; then _bad "expected failure: $*"; else _ok; fi; }

work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT

# Source the library directly for the unit checks (it defines functions only).
# shellcheck disable=SC1091
. "${HERE}/matrix-assertions.sh"

echo "── assert_size: stat-based ceiling (1+512+ROOT_MiB+1 MiB) ──"
# ROOT_MiB=1 → expected = 515 MiB. Sparse files: apparent size only, no real disk.
truncate -s 1M        "${work}/small.img"
truncate -s $((600*1024*1024)) "${work}/big.img"   # 600 MiB apparent > 515 MiB
ok_if  assert_size "${work}/small.img" 1 0     # 1 MiB  <= 515 MiB  -> PASS
bad_if assert_size "${work}/big.img"   1 0     # 600 MiB > 515 MiB  -> FAIL
bad_if assert_size "${work}/nope.img"  1 0     # missing artifact   -> FAIL

echo "── boot_marker_verdict: userspace / panic / inconclusive ──"
printf 'booting\n[  OK  ] reached target Multi-User System\nlogin:\n' > "${work}/c_ok.log"
printf 'booting\nKernel panic - not syncing: VFS: Unable to mount root\n'      > "${work}/c_panic.log"
printf 'booting\n... nothing interesting ...\n'                                 > "${work}/c_blank.log"
boot_marker_verdict "${work}/c_ok.log";    [ $? -eq 0 ] && _ok || _bad "marker=userspace"
boot_marker_verdict "${work}/c_panic.log"; [ $? -eq 1 ] && _ok || _bad "marker=panic"
boot_marker_verdict "${work}/c_blank.log"; [ $? -eq 2 ] && _ok || _bad "marker=inconclusive"

echo "── assert_runtime_load: oom fires FAIL, marker PASS, blank soft-pass ──"
printf 'booting\nOut of memory: Killed process 123\n' > "${work}/c_oom.log"
bad_if assert_runtime_load "${work}/c_oom.log" 512     # oom-killer -> FAIL
ok_if  assert_runtime_load "${work}/c_ok.log"  512     # marker, no oom -> PASS
ok_if  assert_runtime_load "${work}/c_blank.log" 512   # no marker, no oom -> soft-pass (0)

echo "── resolve_artifact: newest match, blobs excluded, empty when none ──"
rdir="${work}/wd"; mkdir -p "${rdir}"
: > "${rdir}/hugmesh-x86-be+gpu-prod-ts.img"
: > "${rdir}/hugmesh-x86-vmlinuz-kernel.img"   # a kernel blob — must NOT be picked
got="$(resolve_artifact x86 '' be+gpu "${rdir}")"
[ "$(basename "${got}")" = "hugmesh-x86-be+gpu-prod-ts.img" ] && _ok || _bad "resolve picked '${got}'"
[ -z "$(resolve_artifact rpi5 rpi5 backend "${work}/empty")" ] && _ok || _bad "resolve should be empty for a missing dir"

echo "── assert_build_load: reads the real host_resources caps (no boot) ──"
ok_if assert_build_load

echo "── DRIVER WIRING: a present artifact really boots+asserts (stub launcher/plan) ──"
# Stub --print-plan: emit a plan line the size parser reads (img_size=9216).
cat > "${work}/plan-stub.sh" <<'STUB'
#!/usr/bin/env bash
echo "FLAGS_EFFECTIVE: role=$2 env=$3 img_size=9216 board=$4"
STUB
# Stub launcher: write a console.log with the boot marker into --run-dir, like a real boot.
cat > "${work}/launch-stub.sh" <<'STUB'
#!/usr/bin/env bash
rundir=""
while [ $# -gt 0 ]; do case "$1" in --run-dir) rundir="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "${rundir}" ] && printf 'boot\n[  OK  ] reached target Graphical Interface\nlogin:\n' > "${rundir}/console.log"
exit 0
STUB
chmod +x "${work}/plan-stub.sh" "${work}/launch-stub.sh"

# A resolvable, within-limit artifact for the x86/backend-gpu row (1 MiB << 9730 MiB
# ceiling). The row id follows tests/build-matrix/matrix.tsv's role column, which is
# the ONE role vocabulary (scripts/_roles-lib.sh) — `x86/be+gpu` names no matrix cell
# any more, and --only on a non-existent cell selects ZERO rows, which reads exactly
# like a driver that stopped working.
bdir="${work}/boot-wd"; mkdir -p "${bdir}"; truncate -s 1M "${bdir}/hugmesh-x86-backend-gpu-prod-ts.img"

out="$(HUGMESH_QEMU_E2E=1 \
      SNAP_QEMU_PLAN_CMD="bash ${work}/plan-stub.sh" \
      SNAP_QEMU_LAUNCH_CMD="bash ${work}/launch-stub.sh" \
      bash "${DRIVER}" --only x86/backend-gpu -w "${bdir}" 2>&1)"
echo "${out}" | grep -qE 'x86/backend-gpu.*PASS|PASS.*x86/backend-gpu' && _ok || { _bad "row did not PASS"; echo "${out}" | sed 's/^/    | /'; }
# ran must be >= 2 (the build-load invariant + the booted row) and fail must be 0.
res="$(echo "${out}" | grep -E '^RESULT:')"
echo "${res}" | grep -qE 'ran=[2-9]' && _ok || _bad "ran did not increment (${res})"
echo "${res}" | grep -qE 'fail=0'    && _ok || _bad "unexpected failure (${res})"
echo "${res}" | grep -qE 'pass=[2-9]' && _ok || _bad "pass did not increment (${res})"

echo "── DRIVER WIRING: an OVERSIZE artifact FAILS the row (assertion really runs) ──"
odir="${work}/over-wd"; mkdir -p "${odir}"; truncate -s $((600*1024*1024)) "${odir}/hugmesh-x86-backend-gpu-prod-ts.img"
# plan stub says img_size=1 → ceiling 515 MiB, so the 600 MiB artifact must FAIL.
cat > "${work}/plan-tiny.sh" <<'STUB'
#!/usr/bin/env bash
echo "FLAGS_EFFECTIVE: role=$2 img_size=1"
STUB
chmod +x "${work}/plan-tiny.sh"
out2="$(HUGMESH_QEMU_E2E=1 \
       SNAP_QEMU_PLAN_CMD="bash ${work}/plan-tiny.sh" \
       SNAP_QEMU_LAUNCH_CMD="bash ${work}/launch-stub.sh" \
       bash "${DRIVER}" --only x86/backend-gpu -w "${odir}" 2>&1)"
echo "${out2}" | grep -E '^RESULT:' | grep -qE 'fail=[1-9]' && _ok || { _bad "oversize row should FAIL"; echo "${out2}" | grep -E 'RESULT|size'; }

echo
printf 'assertions_test: %d passed, %d failed\n' "${PASS}" "${FAIL}" >&2
[ "${FAIL}" -eq 0 ] || exit 1
