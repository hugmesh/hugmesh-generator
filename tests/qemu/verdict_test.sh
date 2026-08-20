#!/usr/bin/env bash
# verdict_test.sh — HERMETIC tests for the harness's VERDICT INTEGRITY and the
# per-device start contract. Boots nothing, starts no container, talks to no
# QEMU: functions are sed-extracted from docker-entrypoint.sh /
# run-qemu-docker.sh (the devices_test.sh pattern) and driven with stubs and a
# fake `docker` on PATH.
#
#   bash tests/qemu/verdict_test.sh
#
# WHY THIS FILE EXISTS. On 2026-08-19 the matrix reported six PASS rows whose
# assertions.log each held 9-12 real FAILs: ausearch, streamed INTO the guest
# as part of `ssh ... 'sudo bash -s' < assertions.sh`, read the REMAINDER OF
# THE SCRIPT as its stdin, so assertions.sh EOF-exited 0 before printing its
# RESULT line — and the harness graded ssh's 0 as PASS. The same night, two
# rows killed during boot (docker stop, exit 143) vanished without any verdict
# at all, and their port claims (22303/22309) leaked. Every test below pins one
# of the fixes; each has a mutation leg that fails if the fix is reverted.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${HERE}/docker-entrypoint.sh"
RUNNER="${HERE}/run-qemu-docker.sh"
ASSERTIONS="${HERE}/assertions.sh"
for f in "${ENTRYPOINT}" "${RUNNER}" "${ASSERTIONS}"; do
    [ -f "${f}" ] || { echo "cannot find ${f}" >&2; exit 2; }
done

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (got '$1', want '$2')"; fi; }
has_line() { if grep -q "$1" "$2"; then _ok "$3"; else _bad "$3"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

extract() { # extract FILE FUNCNAME OUT — die if the function is not found
    sed -n "/^$2() {/,/^}/p" "$1" >> "$3"
    grep -q "^$2() {" "$3" || { echo "could not extract $2 from $1" >&2; exit 2; }
}

# write_device_record's body holds a JSON heredoc whose closing '}' sits at
# column 0, so the plain sed range above would truncate it mid-heredoc. Its
# real end is the '}' straight after its unconditional 'return 0'.
extract_record_fn() { # FILE OUT
    awk '
        $0 == "write_device_record() {" { infn = 1 }
        infn { print; if ($0 == "}" && prev == "    return 0") exit; prev = $0 }
    ' "$1" >> "$2"
    grep -q '^write_device_record() {' "$2" && grep -q '^}$' "$2" \
        || { echo "could not extract write_device_record from $1" >&2; exit 2; }
}

# ══ 1. assertions.sh: ausearch must not eat the streamed script ═════════════
echo "assertions.sh — ausearch cannot swallow the RESULT line (the six false PASSes)"
# The guest runs this file as `bash -s` with the SCRIPT ITSELF on stdin. Stub
# an ausearch that drains stdin exactly like the real one does on a non-tty:
# without the </dev/null guard it eats everything after the harvest section and
# the RESULT line never prints.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/ausearch" <<'EOF'
#!/bin/sh
cat > /dev/null
exit 0
EOF
chmod +x "${TMP}/bin/ausearch"
out="$(PATH="${TMP}/bin:${PATH}" AVC_REPORT_GUEST="${TMP}/avc-report.txt" \
       KEYS_LABEL="VERDICTTEST-NO-SUCH-LABEL" \
       bash -s < "${ASSERTIONS}" 2>&1 || true)"
echo "${out}" | grep -q '== RESULT: [0-9]* passed, [0-9]* failed ==' \
    && _ok "RESULT line survives a stdin-draining ausearch (streamed via bash -s)" \
    || _bad "RESULT line was swallowed — the 2026-08-19 false-PASS defect is back"
echo "${out}" | grep -q -- '-- AVC HARVEST BEGIN --' \
    && _ok "harvest section still runs (fix redirects stdin, does not skip it)" \
    || _bad "harvest section missing entirely"

# ══ 2. emit_assertion_verdict: no RESULT line => FAIL, plus every branch ════
echo
echo "emit_assertion_verdict — ssh rc alone is never believed"
VF="${TMP}/verdict-fns.sh"; : > "${VF}"
extract "${ENTRYPOINT}" emit_assertion_verdict "${VF}"

run_verdict() { # run_verdict ARC ATTEMPTS LOGCONTENT... -> emits recorded emit_result line
    local arc="$1" attempts="$2"; shift 2
    local rdir="${TMP}/vrun"; rm -rf "${rdir}"; mkdir -p "${rdir}"
    printf '%s\n' "$@" > "${rdir}/assertions.log"
    ( set -uo pipefail
      RUN_DIR="${rdir}"; LABEL="t/row"; GREEN=""; RST=""; ASSERT_TIMEOUT=900
      ARC="${arc}"; ASSERT_ATTEMPTS="${attempts}"
      warn() { :; }; info() { :; }
      emit_result() { printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-0}" "${4:-0}" > "${rdir}/emitted"; }
      # shellcheck disable=SC1090
      source "${VF}"
      set -e                     # the real call site runs with errexit ON
      emit_assertion_verdict
      echo "ARC=${ARC}" >> "${rdir}/emitted"
    )
    cat "${rdir}/emitted" 2>/dev/null
}

# THE defect: ssh exited 0 but the log is truncated mid-run (real FAILs, no
# RESULT line) — must be a FAIL verdict, and ARC must turn nonzero.
got="$(run_verdict 0 1 '  PASS  something' '  FAIL  something else' '-- AVC harvest (data, not verdicts) --')"
echo "${got}" | grep -q '^FAIL|assertions did not complete (no RESULT line)' \
    && _ok "ARC=0 without a RESULT line is graded FAIL with the named detail" \
    || _bad "ARC=0 without a RESULT line was not FAILed (got: ${got})"
echo "${got}" | grep -q '^ARC=1$' \
    && _ok "…and the container's exit code turns nonzero" \
    || _bad "…but ARC stayed 0, so the container still exits green"

got="$(run_verdict 0 1 'lines...' '== RESULT: 33 passed, 0 failed ==')"
eq "$(echo "${got}" | head -1)" "PASS|all assertions passed|33|0" \
   "a complete run with rc=0 stays PASS with real counts"

got="$(run_verdict 1 1 'lines...' '== RESULT: 30 passed, 3 failed ==')"
eq "$(echo "${got}" | head -1)" "FAIL|assertions failed|30|3" \
   "rc=1 with a RESULT line is the ordinary FAIL, counts preserved"

got="$(run_verdict 124 1 'partial output only')"
echo "${got}" | grep -q '^FAIL|assertion ssh exceeded its 900s wall clock; killed' \
    && _ok "rc=124 is reported as the hang it is" \
    || _bad "rc=124 not graded as a timeout (got: ${got})"

got="$(run_verdict 255 3 'Connection timed out during banner exchange')"
echo "${got}" | grep -q '^FAIL|assertion ssh could not connect (ssh attempts: 3)' \
    && _ok "rc=255 after retries names the transport and records the attempt count" \
    || _bad "rc=255 detail wrong (got: ${got})"

# Retry wiring is inline (not a function): pin the two load-bearing spellings.
grep -q 'ssh -o ConnectTimeout=15 "\${SSH_OPTS\[@\]}"' "${ENTRYPOINT}" \
    && _ok "assertion ssh raises ConnectTimeout to 15 BEFORE SSH_OPTS (first -o wins)" \
    || _bad "assertion ssh ConnectTimeout=15 must precede SSH_OPTS or ssh keeps the 5"
grep -q '\[ "\${ARC}" -eq 255 \] || break' "${ENTRYPOINT}" \
    && _ok "only transport failures (255) re-run the assertions" \
    || _bad "the retry loop no longer keys on rc=255"

# ══ 3. SIGTERM during the guest-SSH wait: a verdict is still written ════════
echo
echo "sshwait_on_signal — a docker stop during boot leaves a FAIL row, not silence"
SF="${TMP}/sshwait-fns.sh"; : > "${SF}"
extract "${ENTRYPOINT}" sshwait_on_signal "${SF}"
LOG="${TMP}/sshwait.log"; : > "${LOG}"
printf 'console line 1\nkernel: something\n' > "${TMP}/console.log"
# A CHILD bash (save_test.sh pattern): the handler re-raises at $$, which in a
# subshell would still be THIS test's pid.
cat > "${TMP}/sshwait-run.sh" <<RUNNER_EOF
set -uo pipefail
LOG="${LOG}"
CONSOLE="${TMP}/console.log"
warn() { echo "WARN: \$*" >> "\${LOG}"; }
emit_result() { echo "emit:\$1|\$2" >> "\${LOG}"; }
cleanup() { echo "cleanup-ran" >> "\${LOG}"; }
source "${SF}"
trap 'sshwait_on_signal TERM' TERM
kill -s TERM \$\$
sleep 5
RUNNER_EOF
# Command substitution so the killed child's "Terminated" job notice stays off
# this test's output; the inner echo carries the real exit status out.
rc="$( ( bash "${TMP}/sshwait-run.sh" > "${TMP}/sshwait.out" 2>/dev/null; echo $? ) 2>/dev/null )"
has_line 'emit:FAIL|killed while waiting for guest SSH (SIGTERM)' "${LOG}" \
    "writes the FAIL verdict with the named detail"
has_line 'cleanup-ran' "${LOG}" "still runs the normal cleanup (reown, device record)"
if [ "$(grep -n 'emit:FAIL' "${LOG}" | cut -d: -f1 | head -1)" -lt \
     "$(grep -n 'cleanup-ran' "${LOG}" | cut -d: -f1 | head -1)" ]; then
    _ok "verdict is written BEFORE cleanup, so cleanup cannot lose it"
else
    _bad "cleanup ran before the verdict was written"
fi
grep -q 'console line 1' "${TMP}/sshwait.out" \
    && _ok "console tail is printed on the way out" \
    || _bad "no console tail in the handler's output"
if [ "${rc}" -ne 0 ]; then _ok "exits nonzero (rc=${rc}, signal re-raised)"
else _bad "swallowed the signal (exit 0)"; fi
# The trap must guard the ssh-wait loop and ONLY it: installed before the wait
# step, dropped once SSH is up.
t_on="$(grep -n "trap 'sshwait_on_signal TERM' TERM" "${ENTRYPOINT}" | cut -d: -f1 | head -1)"
t_wait="$(grep -n 'Waiting up to \${TIMEOUT}s for guest SSH' "${ENTRYPOINT}" | cut -d: -f1 | head -1)"
t_off="$(grep -n '^trap - TERM INT$' "${ENTRYPOINT}" | cut -d: -f1 | head -1)"
t_assert="$(grep -n 'Running assertions.sh in the guest' "${ENTRYPOINT}" | cut -d: -f1 | head -1)"
if [ -n "${t_on}" ] && [ -n "${t_off}" ] && [ "${t_on}" -lt "${t_wait}" ] \
   && [ "${t_off}" -gt "${t_wait}" ] && [ "${t_off}" -lt "${t_assert}" ]; then
    _ok "trap is installed before the ssh wait and removed before the assertions"
else
    _bad "trap install/remove does not bracket the ssh-wait loop (on=${t_on} wait=${t_wait} off=${t_off} assert=${t_assert})"
fi

# ══ 4. Device records: the per-device start contract ═══════════════════════
echo
echo "write_device_record — artifacts/image fields + a booting record before ssh"
DF="${TMP}/record-fns.sh"; : > "${DF}"
extract "${ENTRYPOINT}" host_path "${DF}"
extract "${ENTRYPOINT}" json_str "${DF}"
extract_record_fn "${ENTRYPOINT}" "${DF}"
(
    set -uo pipefail
    WORK="/work"; HOST_WORK="/home/op/qemu-runs"
    ARTIFACTS="/artifacts"; HOST_ARTIFACTS="/home/op/sessions/s1"
    DEVICES_DIR="${TMP}/devices"; DEVICE_JSON="${DEVICES_DIR}/x86_pki.json"
    LABEL="x86/pki"; PLATFORM="x86"; ROLE="pki"; BOARD=""
    CONTAINER_NAME="hugmesh-qemu-dev-x86_pki"; SSH_HOST_PORT=22307
    SSH_USER="tester"; GUEST_USERS=(tester alice)
    SSHKEY="/work/runs/x86_pki/id_ed25519"; QMP_SOCK="/work/runs/x86_pki/launch/qmp.sock"
    IMG="/work/images/hugmesh-x86-amd64-pki-test-20260816T000000Z.img"
    STARTED_AT="2026-08-19T00:00:00Z"; HOST_UID=""
    warn() { :; }
    # shellcheck disable=SC1090
    source "${DF}"
    write_device_record booting
) || _bad "write_device_record run failed outright"
python3 - "${TMP}/devices/x86_pki.json" <<'PY' && _ok "booting record parses and carries the start contract" || _bad "record missing/invalid (state, artifacts, image, host paths)"
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["state"] == "booting", rec
assert rec["artifacts"] == "/home/op/sessions/s1", rec        # host_path via HOST_ARTIFACTS
assert rec["image"] == "hugmesh-x86-amd64-pki-test-20260816T000000Z.img", rec
assert rec["ssh_key"] == "/home/op/qemu-runs/runs/x86_pki/id_ed25519", rec
assert rec["qmp"] == "/home/op/qemu-runs/runs/x86_pki/launch/qmp.sock", rec
assert rec["ssh_host_port"] == 22307 and rec["container"] == "hugmesh-qemu-dev-x86_pki", rec
PY
# The booting record must be published BEFORE the ssh wait starts (that is the
# whole point: a row killed during boot still leaves a findable device).
b_line="$(grep -n 'write_device_record booting' "${ENTRYPOINT}" | cut -d: -f1 | head -1)"
w_line="$(grep -n 'Waiting up to \${TIMEOUT}s for guest SSH' "${ENTRYPOINT}" | cut -d: -f1 | head -1)"
if [ -n "${b_line}" ] && [ "${b_line}" -lt "${w_line}" ]; then
    _ok "a booting record is written before the guest-SSH wait begins"
else
    _bad "no booting record before the ssh wait (booting=${b_line:-none}, wait=${w_line})"
fi

# ══ 5. --only-exact vs --only ═══════════════════════════════════════════════
echo
echo "row_matches_filters — --only-exact means ONE row"
FF="${TMP}/filter-fns.sh"; : > "${FF}"
extract "${RUNNER}" row_matches_filters "${FF}"
# shellcheck disable=SC1090
source "${FF}"
PLATFORM_FILTER=""; ROLE_FILTER=""; ONLY=""; ONLY_EXACT="x86/be"
eq "$(row_matches_filters x86 be && echo yes || echo no)"     "yes" "--only-exact x86/be matches x86/be"
eq "$(row_matches_filters x86 be-ha && echo yes || echo no)"  "no"  "--only-exact x86/be does NOT match x86/be-ha"
eq "$(row_matches_filters x86 be+gpu && echo yes || echo no)" "no"  "--only-exact x86/be does NOT match x86/be+gpu"
ONLY_EXACT=""; ONLY="x86/be"
eq "$(row_matches_filters x86 be && echo yes || echo no)"     "yes" "--only stays a substring: x86/be matches"
eq "$(row_matches_filters x86 be-ha && echo yes || echo no)"  "yes" "--only stays a substring: x86/be-ha also matches (why exact exists)"
ONLY=""

# ══ 6. Portlock sweep: only ownerless (container-gone) claims are removed ═══
echo
echo "sweep_stale_portlocks — never steals a live owner's claim"
PF="${TMP}/portlock-fns.sh"; : > "${PF}"
extract "${RUNNER}" sweep_stale_portlocks "${PF}"
extract "${RUNNER}" port_claim_is_stale "${PF}"
mk_claim() { mkdir -p "${PORTLOCK_DIR}/$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" > "${PORTLOCK_DIR}/$1/owner"; }
cat > "${TMP}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "ps --format") echo "hugmesh-qemu-dev-alive" ;;
  "info ") exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "${TMP}/bin/docker"
PORTLOCK_DIR="${TMP}/locks"; rm -rf "${PORTLOCK_DIR}"
mk_claim 22303 "hugmesh-qemu-dev-alive"     # owner still running: KEEP
mk_claim 22309 "hugmesh-qemu-dev-gone"      # owner gone: SWEEP (tonight's leak)
mk_claim 22311 ""                           # ownerless but FRESH (<5min): KEEP
( PATH="${TMP}/bin:${PATH}"; PORTLOCK_DIR="${PORTLOCK_DIR}"
  info() { :; }; warn() { :; }
  # shellcheck disable=SC1090
  source "${PF}"; sweep_stale_portlocks )
eq "$( [ -d "${PORTLOCK_DIR}/22303" ] && echo held || echo swept)" "held" \
   "a claim whose owner container is RUNNING is kept"
eq "$( [ -d "${PORTLOCK_DIR}/22309" ] && echo held || echo swept)" "swept" \
   "a claim whose owner container is GONE is released (the 22303/22309 leak)"
eq "$( [ -d "${PORTLOCK_DIR}/22311" ] && echo held || echo swept)" "held" \
   "a fresh ownerless claim (mkdir->docker-run window) is left alone"
# When docker does not answer, nothing may be swept — never steal blind.
cat > "${TMP}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
( PATH="${TMP}/bin:${PATH}"; PORTLOCK_DIR="${PORTLOCK_DIR}"
  info() { :; }; warn() { :; }
  # shellcheck disable=SC1090
  source "${PF}"; sweep_stale_portlocks )
eq "$( [ -d "${PORTLOCK_DIR}/22303" ] && echo held || echo swept)" "held" \
   "with docker unreachable, nothing is swept"

# ══ 7. Cache sweep: LRU with hard protections, 0 = off ══════════════════════
echo
echo "cache_sweep — protected files survive, 0 means untouched"
CF="${TMP}/cache-fns.sh"; : > "${CF}"
extract "${RUNNER}" cache_protected_names "${CF}"
extract "${RUNNER}" cache_sweep "${CF}"
cat > "${TMP}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "ps -a")       echo "hugmesh-qemu-dev-referenced" ;;
  "ps --format") echo "" ;;
  "info ")       exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "${TMP}/bin/docker"

setup_cache() {
    CWORK="${TMP}/work"; rm -rf "${CWORK}"; mkdir -p "${CWORK}/images" "${CWORK}/devices"
    # Sparse 600MiB each; apparent size is what stat %s (and the sweep) sees.
    for n in run-row.img referenced.img newer-loser.img older-loser.img; do
        truncate -s $((600*1024*1024)) "${CWORK}/images/${n}"
    done
    # mtimes: run-row/referenced old (protection must not depend on age),
    # newer-loser newer than older-loser (LRU decides between the two losers).
    touch -d '@1000000000' "${CWORK}/images/run-row.img" "${CWORK}/images/referenced.img"
    touch -d '@1000000300' "${CWORK}/images/older-loser.img"
    touch -d '@1000000600' "${CWORK}/images/newer-loser.img"
    # .part files: one mid-decompress (fresh), one leaked (2h stale — the probe.part).
    truncate -s $((100*1024*1024)) "${CWORK}/images/fresh.part"
    truncate -s $((100*1024*1024)) "${CWORK}/images/stale.part"
    touch -d "@$(( $(date +%s) - 7200 ))" "${CWORK}/images/stale.part"
    # A device record referencing referenced.img, container present in `docker ps -a`.
    cat > "${CWORK}/devices/x86_ref.json" <<'REC'
{
  "label": "x86/ref",
  "container": "hugmesh-qemu-dev-referenced",
  "image": "referenced.img",
  "state": "stopped"
}
REC
}

run_sweep() { # run_sweep CAP_GB
    ( set -uo pipefail
      PATH="${TMP}/bin:${PATH}"
      WORK="${CWORK}"; DEVICES_DIR="${CWORK}/devices"; CACHE_MAX_GB="$1"
      ROWS=("0|x86|pki|test|/artifacts/run-row.img.xz")
      info() { :; }; warn() { :; }
      # shellcheck disable=SC1090
      source "${CF}"; cache_sweep )
}

setup_cache; run_sweep 0
eq "$(ls "${CWORK}/images" | sort | tr '\n' ' ')" \
   "fresh.part newer-loser.img older-loser.img referenced.img run-row.img stale.part " \
   "--cache-max-gb 0: the historical behaviour, nothing deleted (stale .part included)"

# Cap 2 GiB: protected run-row+referenced charge 1.2G; newest loser fits
# (1.8G <= 2G), oldest loser is evicted; stale .part goes, fresh .part stays.
setup_cache; run_sweep 2
eq "$( [ -e "${CWORK}/images/run-row.img" ] && echo kept || echo evicted)" "kept" \
   "this run's own row is never evicted (whatever its age)"
eq "$( [ -e "${CWORK}/images/referenced.img" ] && echo kept || echo evicted)" "kept" \
   "an image referenced by a record whose container exists is never evicted"
eq "$( [ -e "${CWORK}/images/newer-loser.img" ] && echo kept || echo evicted)" "kept" \
   "the most recently touched unprotected image fits under the cap"
eq "$( [ -e "${CWORK}/images/older-loser.img" ] && echo kept || echo evicted)" "evicted" \
   "the LRU unprotected image is evicted once the cap is passed"
eq "$( [ -e "${CWORK}/images/fresh.part" ] && echo kept || echo evicted)" "kept" \
   "a fresh .part (another run mid-decompress) is never touched"
eq "$( [ -e "${CWORK}/images/stale.part" ] && echo kept || echo evicted)" "evicted" \
   "an hour-stale orphaned .part is reclaimed (the leaked 16.5G probe.part)"

# Tight cap, docker NOT answering: record-referenced images are protected blind.
setup_cache
cat > "${TMP}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
run_sweep 1
eq "$( [ -e "${CWORK}/images/referenced.img" ] && echo kept || echo evicted)" "kept" \
   "docker unreachable => every record-referenced image is protected, never stolen blind"
cat > "${TMP}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "ps -a")       echo "hugmesh-qemu-dev-referenced" ;;
  "info ")       exit 0 ;;
  *) exit 0 ;;
esac
FAKE

# ══ 8. Keep-alive boot admission ═════════════════════════════════════════════
echo
echo "admission_poll — --jobs gates boots; record-appeared or stagger admits"
AF="${TMP}/admit-fns.sh"; : > "${AF}"
extract "${RUNNER}" admission_poll "${AF}"
extract "${RUNNER}" admission_wait "${AF}"
# shellcheck disable=SC1090
source "${AF}"
declare -A PENDING_SINCE=()
JOBS=1; ADMIT_STAGGER=9999
REC="${TMP}/admit-rec.json"; rm -f "${REC}"

# Polls run in THIS shell (no command substitution): admission_poll mutates
# PENDING_SINCE, and a subshell would throw the mutation away.
poll() { if admission_poll; then echo go; else echo hold; fi; }

eq "$(poll)" "go" "empty pending set admits immediately"

PENDING_SINCE["${REC}"]="$(date +%s)"
eq "$(poll)" "hold" "jobs=1 with one mid-boot row holds the next start"

: > "${REC}"     # the row's registry record appears (entrypoint wrote 'booting')
if admission_poll; then r=go; else r=hold; fi
eq "${r}" "go" "the record appearing admits the next row"
eq "${#PENDING_SINCE[@]}" "0" "…and the resolved row leaves the pending set"

rm -f "${REC}"; ADMIT_STAGGER=1
PENDING_SINCE["${REC}"]="$(( $(date +%s) - 5 ))"
eq "$(poll)" "go" "a row pending past the stagger admits the next even with no record"

PENDING_SINCE=(); PENDING_SINCE["${REC}"]="$(date +%s)"; ADMIT_STAGGER=9999; JOBS=0
eq "$(admission_wait && echo go || echo hold)" "go" \
   "--jobs 0 is the ungated all-at-once fan-out"
JOBS=2; PENDING_SINCE=()

# Ordering: the keep-alive loop must gate BEFORE each start, and each start
# must register as pending; the stale record is cleared before docker run so
# "record appeared" can only mean THIS boot.
l_wait="$(grep -n '^        admission_wait$' "${RUNNER}" | cut -d: -f1 | head -1)"
l_start="$(grep -n 'if start_device_row "\${platform}"' "${RUNNER}" | cut -d: -f1 | head -1)"
l_pend="$(grep -n 'PENDING_SINCE\["\${DEVICES_DIR}/' "${RUNNER}" | cut -d: -f1 | head -1)"
if [ -n "${l_wait}" ] && [ -n "${l_start}" ] && [ -n "${l_pend}" ] \
   && [ "${l_wait}" -lt "${l_start}" ] && [ "${l_start}" -lt "${l_pend}" ]; then
    _ok "keep-alive loop: admission_wait -> start_device_row -> register pending"
else
    _bad "keep-alive admission ordering broken (wait=${l_wait:-none} start=${l_start:-none} pending=${l_pend:-none})"
fi
l_rm="$(grep -n 'rm -f "\${DEVICES_DIR}/\${safe}.json"' "${RUNNER}" | cut -d: -f1 | head -1)"
l_run="$(grep -n 'docker run -d --privileged' "${RUNNER}" | cut -d: -f1 | head -1)"
if [ -n "${l_rm}" ] && [ "${l_rm}" -lt "${l_run}" ]; then
    _ok "the stale registry record is cleared before the new container starts"
else
    _bad "stale record not cleared before docker run (rm=${l_rm:-none} run=${l_run})"
fi

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
