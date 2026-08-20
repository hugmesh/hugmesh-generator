#!/usr/bin/env bash
# avc-workout_test.sh — HERMETIC tests for the SELinux AVC-workout lane
# (issue #45): avc-report.sh's denial->owning-.te grouping, the NEW SELinux
# sections of assertions.sh EXECUTED for real against fixtures + PATH stubs,
# and avc-workout.sh's driver wiring via stub launcher/ssh/keys — so NOTHING
# is booted, built, or run as root.
#
# Every new assertion is MUTATION-TESTED here: each positive leg has a
# break-it twin (module missing from semodule -l, a 'failed' status verdict,
# a mode mismatch) that must FAIL — an assertion that cannot fail is not one.
#
#   bash tests/qemu/avc-workout_test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); }
_bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1" >&2; }
ok_if()  { if "$@" >/dev/null 2>&1; then _ok; else _bad "expected success: $*"; fi; }
bad_if() { if "$@" >/dev/null 2>&1; then _bad "expected failure: $*"; else _ok; fi; }

work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT

echo "── all lane scripts parse (bash -n) ──"
for f in "${HERE}/avc-workout.sh" "${HERE}/avc-workload.sh" "${HERE}/avc-report.sh" \
         "${HERE}/assertions.sh" "${REPO}/specs/etc/keys-provision/provision.sh"; do
    ok_if bash -n "${f}"
done

echo "── avc-report.sh: grouping against the REAL specs/selinux modules ──"
cat > "${work}/avc.txt" <<'EOF'
type=AVC msg=audit(1.0:1): avc:  denied  { read open } for  pid=1 comm="curl" path="/etc/hugmesh/vpn.conf" scontext=system_u:system_r:hugmesh_vpn_reconcile_t:s0 tcontext=system_u:object_r:etc_t:s0 tclass=file permissive=1
type=AVC msg=audit(1.0:2): avc:  denied  { read open } for  pid=1 comm="curl" path="/etc/hugmesh/vpn.conf" scontext=system_u:system_r:hugmesh_vpn_reconcile_t:s0 tcontext=system_u:object_r:etc_t:s0 tclass=file permissive=1
[   12.3] audit: type=1400 audit(2.0:3): avc:  denied  { name_connect } for  pid=9 comm="helper" scontext=system_u:system_r:localpath_provisioner_helper_t:s0 tcontext=system_u:object_r:http_port_t:s0 tclass=tcp_socket permissive=1
type=USER_AVC msg=audit(3.0:4): pid=1 uid=0 msg='avc:  denied  { status } for scontext=system_u:system_r:mystery_domain_t:s0 tcontext=system_u:object_r:init_t:s0 tclass=service permissive=1'
type=AVC msg=audit(4.0:5): avc:  denied  { write } for  pid=7 comm="tor-rec" name="torrc" scontext=system_u:system_r:hugmesh_tor_reconcile_t:s0 tcontext=system_u:object_r:hugmesh_tor_etc_t:s0 tclass=file permissive=1
EOF
rep="$(bash "${HERE}/avc-report.sh" "${work}/avc.txt" "${REPO}/specs/selinux")" || _bad "avc-report.sh exited non-zero"
# declared-type ownership (hugmesh_vpn_reconcile_t is a `type` line in hugmesh_vpn.te)
echo "${rep}" | grep -q 'hugmesh_vpn.te : 2 denial' && _ok || _bad "vpn denials not grouped under hugmesh_vpn.te"
echo "${rep}" | grep -q '2x  hugmesh_vpn_reconcile_t -> etc_t:file { read open }' && _ok || _bad "vpn tuple not aggregated with count 2"
# prefix ownership (localpath_provisioner_helper_t is template-minted — no `type` line)
echo "${rep}" | grep -q 'localpath_provisioner.te : 1 denial' && _ok || _bad "helper denial (dmesg-format line) not owned by localpath_provisioner.te"
# tor line groups by declared type
echo "${rep}" | grep -q 'hugmesh_tor.te : 1 denial' && _ok || _bad "tor denial not grouped under hugmesh_tor.te"
# unknown source type lands in (unowned), never misattributed
echo "${rep}" | grep -q '(unowned) : 1 denial' && _ok || _bad "mystery domain not reported as (unowned)"
echo "${rep}" | grep -q 'mystery_domain_t -> init_t:service' && _ok || _bad "unowned tuple missing"
# the INFERRED-WIDE narrowing pointer names the owning file
echo "${rep}" | grep -q 'INFERRED-WIDE.*hugmesh_vpn.te' && _ok || _bad "no INFERRED-WIDE pointer for hugmesh_vpn.te"

echo "── avc-report.sh: empty harvest + longest-prefix disambiguation ──"
: > "${work}/empty.txt"
rep2="$(bash "${HERE}/avc-report.sh" "${work}/empty.txt" "${REPO}/specs/selinux")" && _ok || _bad "empty harvest should exit 0"
echo "${rep2}" | grep -q 'No denials in the harvest' && _ok || _bad "empty harvest not reported honestly"
# synthetic specs dir: module 'foo' vs 'foo_bar' — foo_bar_baz_t must go to the LONGER
mkdir -p "${work}/specs"
printf 'policy_module(foo, 1.0.0)\n'     > "${work}/specs/foo.te"
printf 'policy_module(foo_bar, 1.0.0)\n' > "${work}/specs/foo_bar.te"
printf 'type=AVC msg=audit(1.0:1): avc:  denied  { read } for pid=1 comm="x" scontext=u:r:foo_bar_baz_t:s0 tcontext=u:r:bin_t:s0 tclass=file permissive=1\n' > "${work}/one.txt"
rep3="$(bash "${HERE}/avc-report.sh" "${work}/one.txt" "${work}/specs")"
echo "${rep3}" | grep -q 'foo_bar.te : 1 denial' && _ok || _bad "longest-prefix owner lost to the shorter module"

echo "── assertions.sh SELinux sections: EXECUTED against fixtures + PATH stubs ──"
# Stub the two SELinux userland tools + ausearch on PATH; point every marker
# path at a fixture via the enforce-gate-style env seams. Everything else in
# assertions.sh runs (and mostly fails) against this host — irrelevant here: we
# grep for the specific PASS/FAIL lines of the NEW checks only.
stub="${work}/stub"; mkdir -p "${stub}"
cat > "${stub}/getenforce" <<'EOF'
#!/bin/sh
echo "${STUB_MODE:-Permissive}"
EOF
cat > "${stub}/semodule" <<'EOF'
#!/bin/sh
cat "${STUB_SEMODULE_L:?}"
EOF
cat > "${stub}/ausearch" <<'EOF'
#!/bin/sh
cat "${STUB_AVC:?}"
EOF
chmod +x "${stub}/getenforce" "${stub}/semodule" "${stub}/ausearch"

printf '# manifest fixture\nhugmesh_vpn\nhugmesh_authkeys\n' > "${work}/manifest.list"
printf 'hugmesh_vpn\t1.0\nhugmesh_authkeys\t1.0\nbase\t1.0\n' > "${work}/semodule-all.txt"
printf 'hugmesh_vpn\t1.0\nbase\t1.0\n'                        > "${work}/semodule-partial.txt"
printf '# status fixture\nhugmesh_vpn loaded\nhugmesh_authkeys loaded\n' > "${work}/status-clean.txt"
printf 'hugmesh_vpn loaded\nhugmesh_authkeys failed\n'                   > "${work}/status-broken.txt"
printf 'SELINUX=permissive\nSELINUXTYPE=mcs\n' > "${work}/selinux-config"
: > "${work}/built-marker"

run_assertions() {
    # run_assertions <semodule-fixture> <status-fixture> <expected-mode> <live-mode> [<load-failed-marker>]
    PATH="${stub}:${PATH}" \
    STUB_SEMODULE_L="$1" STUB_AVC="${work}/avc.txt" STUB_MODE="$4" \
    SELINUX_MODULES_LIST="${work}/manifest.list" \
    SELINUX_MODULES_STATUS="$2" \
    SELINUX_CONFIG="${work}/selinux-config" \
    SELINUX_BUILT_MARKER="${work}/built-marker" \
    SELINUX_LOAD_FAILED_MARKER="${5:-${work}/no-such-marker}" \
    SELINUX_EXPECTED_MODE="$3" \
    AVC_REPORT_GUEST="${work}/guest-avc-report.txt" \
    KEYS_LABEL="AVCTEST-NO-SUCH-LABEL" \
        bash "${HERE}/assertions.sh" 2>&1 || true
}

out="$(run_assertions "${work}/semodule-all.txt" "${work}/status-clean.txt" permissive Permissive)"
echo "${out}" | grep -q "PASS  node-policy module 'hugmesh_vpn' loaded"      && _ok || _bad "module hugmesh_vpn PASS line missing"
echo "${out}" | grep -q "PASS  node-policy module 'hugmesh_authkeys' loaded" && _ok || _bad "module hugmesh_authkeys PASS line missing"
echo "${out}" | grep -q "PASS  provision recorded every manifest module as loaded" && _ok || _bad "clean status PASS line missing"
echo "${out}" | grep -q "PASS  getenforce matches the expected mode 'permissive'"  && _ok || _bad "mode-match PASS line missing"
echo "${out}" | grep -q "PASS  no selinux-load-failed marker" && _ok || _bad "load-failed-marker PASS line missing"
echo "${out}" | grep -q -- "-- AVC HARVEST BEGIN --" && _ok || _bad "AVC harvest markers missing"
echo "${out}" | grep -q "hugmesh_vpn_reconcile_t" && _ok || _bad "harvest did not carry the stubbed ausearch lines"
[ -s "${work}/guest-avc-report.txt" ] && _ok || _bad "guest AVC report artifact not written"

echo "── assertions.sh MUTATIONS: every new check must be able to FAIL ──"
out="$(run_assertions "${work}/semodule-partial.txt" "${work}/status-clean.txt" permissive Permissive)"
echo "${out}" | grep -q "FAIL  node-policy module 'hugmesh_authkeys' loaded" && _ok || _bad "MUTATION missed: module absent from semodule -l did not FAIL"
echo "${out}" | grep -q "PASS  node-policy module 'hugmesh_vpn' loaded" && _ok || _bad "mutation leg lost the still-loaded module's PASS"

out="$(run_assertions "${work}/semodule-all.txt" "${work}/status-broken.txt" permissive Permissive)"
echo "${out}" | grep -q "FAIL  provision recorded every manifest module as loaded" && _ok || _bad "MUTATION missed: a 'failed' status verdict did not FAIL"

out="$(run_assertions "${work}/semodule-all.txt" "${work}/status-clean.txt" enforcing Permissive)"
echo "${out}" | grep -q "FAIL  getenforce matches the expected mode 'enforcing'" && _ok || _bad "MUTATION missed: mode mismatch did not FAIL"

: > "${work}/load-failed-marker"
out="$(run_assertions "${work}/semodule-all.txt" "${work}/status-clean.txt" permissive Permissive "${work}/load-failed-marker")"
echo "${out}" | grep -q "FAIL  no selinux-load-failed marker" && _ok || _bad "MUTATION missed: standing selinux-load-failed marker did not FAIL"

echo "── DRIVER WIRING: avc-workout.sh end-to-end via stub launcher/ssh/keys ──"
cat > "${work}/launch-stub.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${work}/keys-stub.sh" <<'EOF'
#!/usr/bin/env bash
: > "$2"
EOF
# The ssh stub answers by REMOTE ARGV (one string arg), consuming stdin like a
# real `bash -s` and switching on what the streamed script is.
cat > "${work}/ssh-stub.sh" <<'EOF'
#!/usr/bin/env bash
argv="$*"
case "${argv}" in
    *"bash -s"*)
        body="$(cat)"
        if printf '%s' "${body}" | grep -q 'avc-workload'; then
            echo "[avc-workload] PROBE stub-service: rc=0"
        elif printf '%s' "${body}" | grep -q 'ausearch'; then
            cat "${STUB_AVC:?}"
        elif printf '%s' "${body}" | grep -q 'SELINUXTYPE'; then
            cat "${STUB_SEMODULE_L:?}"
        fi
        exit 0 ;;
    *selinux-modules.list*)   cat "${STUB_MANIFEST:?}"; exit 0 ;;
    *selinux-modules.status*) cat "${STUB_STATUS:?}";   exit 0 ;;
    *keys-provision.log*)     echo "stub provision log"; exit 0 ;;
    *getenforce*)             echo "${STUB_MODE:-Permissive}"; exit 0 ;;
    *poweroff*|*setenforce*|true|*"login-probe"*|*"id &&"*|*"post-workout"*) exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "${work}/launch-stub.sh" "${work}/keys-stub.sh" "${work}/ssh-stub.sh"

run_driver() {
    # run_driver <run-subdir> <semodule-fixture> <status-fixture> <mode>
    AVC_LAUNCH_CMD="bash ${work}/launch-stub.sh" \
    AVC_SSH_CMD="bash ${work}/ssh-stub.sh" \
    AVC_KEYS_CMD="bash ${work}/keys-stub.sh" \
    STUB_MANIFEST="${work}/manifest.list" \
    STUB_SEMODULE_L="$2" STUB_STATUS="$3" STUB_MODE="$4" STUB_AVC="${work}/avc.txt" \
        bash "${HERE}/avc-workout.sh" --platform x86 --role pki \
            --run-dir "${work}/$1" --timeout 30 --logins 1 --probe-timeout 60 2>&1
}
export STUB_MANIFEST="" STUB_SEMODULE_L="" STUB_STATUS="" STUB_MODE="" STUB_AVC=""

out="$(run_driver run-pass "${work}/semodule-all.txt" "${work}/status-clean.txt" Permissive)"; rc=$?
[ "${rc}" -eq 0 ] && _ok || { _bad "driver PASS leg exited ${rc}"; echo "${out}" | tail -20 | sed 's/^/    | /' >&2; }
echo "${out}" | grep -q 'AVC-WORKOUT RESULT: PASS' && _ok || _bad "driver did not report PASS"
[ -s "${work}/run-pass/report.txt" ] && _ok || _bad "driver wrote no report.txt"
grep -q 'hugmesh_vpn.te' "${work}/run-pass/report.txt" 2>/dev/null && _ok || _bad "report.txt lost the vpn grouping"
grep -q 'avc-workload' "${work}/run-pass/probes.log" 2>/dev/null && _ok || _bad "probes.log did not capture the workload run"
[ -s "${work}/run-pass/avc-raw.txt" ] && _ok || _bad "avc-raw.txt harvest artifact missing"

echo "── DRIVER MUTATIONS: each gate must be able to FAIL the run ──"
out="$(run_driver run-mod "${work}/semodule-partial.txt" "${work}/status-clean.txt" Permissive)"; rc=$?
[ "${rc}" -ne 0 ] && _ok || _bad "MUTATION missed: unloaded module did not fail the driver"
echo "${out}" | grep -q 'module-not-loaded:hugmesh_authkeys' && _ok || _bad "driver did not NAME the unloaded module"

out="$(run_driver run-status "${work}/semodule-all.txt" "${work}/status-broken.txt" Permissive)"; rc=$?
[ "${rc}" -ne 0 ] && _ok || _bad "MUTATION missed: provision-recorded failure did not fail the driver"
echo "${out}" | grep -q 'provision-recorded-failure' && _ok || _bad "driver did not flag the status verdict"

out="$(run_driver run-mode "${work}/semodule-all.txt" "${work}/status-clean.txt" Enforcing)"; rc=$?
[ "${rc}" -ne 0 ] && _ok || _bad "MUTATION missed: mode mismatch did not fail the driver"
echo "${out}" | grep -q 'mode-mismatch' && _ok || _bad "driver did not flag the mode mismatch"

echo
printf 'avc-workout_test: %d passed, %d failed\n' "${PASS}" "${FAIL}" >&2
[ "${FAIL}" -eq 0 ] || exit 1
