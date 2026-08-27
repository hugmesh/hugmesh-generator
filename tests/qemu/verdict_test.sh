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
# mesh-cluster.sh is here for section 11 only (its LOUD skip gates). The rest of
# that driver has its own suite, tests/qemu/mesh-cluster_test.sh; what lives HERE
# is the same concern every other section of this file covers — a harness that
# reports something other than what actually happened.
MESH="${HERE}/mesh-cluster.sh"
for f in "${ENTRYPOINT}" "${RUNNER}" "${ASSERTIONS}" "${MESH}"; do
    [ -f "${f}" ] || { echo "cannot find ${f}" >&2; exit 2; }
done

# python3 parses the JSON these writers emit. NO SILENT SKIP: without it the most
# valuable assertions in section 9 cannot run at all, and a suite that quietly
# drops them while still exiting 0 is precisely the DAST failure mode.
command -v python3 >/dev/null 2>&1 \
    || { echo "SKIP-FATAL: python3 not on PATH — the emit_result JSON tests cannot verify anything" >&2; exit 2; }

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

# extract_heredoc_fn FILE FUNC OUT — extract(), made heredoc-aware.
#
# emit_result's body is a `cat > ... <<EOF` whose JSON payload closes with a '}'
# at COLUMN 0. The plain sed range above therefore stops INSIDE the heredoc and
# hands bash a truncated function — which shows up not as a missing test but as
# "emit_result: command not found" after the extraction quietly "succeeded".
# This walks the function instead: lines between an unquoted <<TERM and its
# terminator are copied verbatim and never considered for the end, and the
# function ends at the first column-0 '}' OUTSIDE a heredoc.
extract_heredoc_fn() { # FILE FUNC OUT
    awk -v fn="$2" '
        !infn && $0 == fn "() {" { infn = 1; print; next }
        !infn { next }
        inhd  { print; if ($0 == hd) inhd = 0; next }
        match($0, /<<-?"?[A-Za-z_][A-Za-z_0-9]*"?$/) {
            hd = substr($0, RSTART)
            gsub(/^<<-?"?|"$/, "", hd)
            inhd = 1; print; next
        }
        { print; if ($0 == "}") exit }
    ' "$1" >> "$3"
    grep -q "^$2() {" "$3" && grep -q '^}$' "$3" \
        || { echo "could not extract $2 from $1" >&2; exit 2; }
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
echo "${out}" | grep '== RESULT: [0-9]* passed, [0-9]* failed ==' >/dev/null \
    && _ok "RESULT line survives a stdin-draining ausearch (streamed via bash -s)" \
    || _bad "RESULT line was swallowed — the 2026-08-19 false-PASS defect is back"
echo "${out}" | grep -- '-- AVC HARVEST BEGIN --' >/dev/null \
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
echo "${got}" | grep '^FAIL|assertions did not complete (no RESULT line)' >/dev/null \
    && _ok "ARC=0 without a RESULT line is graded FAIL with the named detail" \
    || _bad "ARC=0 without a RESULT line was not FAILed (got: ${got})"
echo "${got}" | grep '^ARC=1$' >/dev/null \
    && _ok "…and the container's exit code turns nonzero" \
    || _bad "…but ARC stayed 0, so the container still exits green"

got="$(run_verdict 0 1 'lines...' '== RESULT: 33 passed, 0 failed ==')"
eq "$(echo "${got}" | head -1)" "PASS|all assertions passed|33|0" \
   "a complete run with rc=0 stays PASS with real counts"

got="$(run_verdict 1 1 'lines...' '== RESULT: 30 passed, 3 failed ==')"
eq "$(echo "${got}" | head -1)" "FAIL|assertions failed|30|3" \
   "rc=1 with a RESULT line is the ordinary FAIL, counts preserved"

got="$(run_verdict 124 1 'partial output only')"
echo "${got}" | grep '^FAIL|assertion ssh exceeded its 900s wall clock; killed' >/dev/null \
    && _ok "rc=124 is reported as the hang it is" \
    || _bad "rc=124 not graded as a timeout (got: ${got})"

got="$(run_verdict 255 3 'Connection timed out during banner exchange')"
echo "${got}" | grep '^FAIL|assertion ssh could not connect (ssh attempts: 3)' >/dev/null \
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

# ══ 9. emit_result: hostile strings must still come out as JSON ════════════
echo
echo "emit_result — every string field is routed through json_str"
# WHY (2026-08-26). emit_result interpolated label/platform/board/role/mode/
# image RAW into its heredoc — only "detail" was escaped, and even that by a sed
# that emits NOTHING for an empty value. One double quote or one backslash
# anywhere in a label or an image path therefore produced a result row that is
# not JSON. Nothing anywhere reports that: the Studio simply drops a record it
# cannot parse and renders the cell as '?', so the row looks UNRUN rather than
# broken. That is the invisible-failure class, not a cosmetic one.
EF="${TMP}/emit-fns.sh"; : > "${EF}"
extract "${ENTRYPOINT}" json_str "${EF}"
extract_heredoc_fn "${ENTRYPOINT}" emit_result "${EF}"

# Every byte here is reachable from argv or from real error text: --label with a
# quoted phrase, a path fragment with a backslash, a pasted newline, a tab. All
# of them are ILLEGAL raw inside a JSON string.
#
# The detail carries all FIVE of json_str's named control escapes (2026-08-26,
# from review): with only \n and \t here, deleting the \r, \b or \f line from
# json_str survived the whole suite. \r is the load-bearing one — the harness's
# own error text is scraped off a guest SERIAL CONSOLE, which is CRLF, so a
# carriage return in a detail string is the likeliest of the five to show up in
# production. Section 9d below drives the whole 0x01-0x1F class as well; this
# row is what proves they survive the real emit_result heredoc end to end.
HOSTILE_LABEL='x86/pki "quoted" \ back'$'\n''second line'$'\t''tabbed'
HOSTILE_DETAIL='ssh said: "no route to host"'$'\r\n''retrying \ once'$'\t''cr'$'\b''bs'$'\f''ff'
RES9="${TMP}/results9"
(
    set -uo pipefail
    RESULT_DIR="${RES9}"; rm -rf "${RESULT_DIR}"
    RESULT_JSON="${RESULT_DIR}/hostile.json"
    LABEL="${HOSTILE_LABEL}"
    PLATFORM='x86"evil'
    BOARD=''                       # the ROUTINE empty case — every non-ARM row
    ROLE='pki\role'
    MODE='golden'
    IMG='/artifacts/hug "quoted"\dir.img'
    STARTED_AT='2026-08-26T00:00:00Z'
    START_S=0
    # shellcheck disable=SC1090
    source "${EF}"
    emit_result FAIL "${HOSTILE_DETAIL}" 12 3
) || _bad "emit_result run failed outright"

# The tool the unit names, used as the unit names it: if json.tool refuses the
# file, the Studio's json.load refuses it too and the row renders as '?'.
if python3 -m json.tool "${RES9}/hostile.json" >/dev/null 2>&1; then
    _ok "a label with a quote, a backslash, a newline and a tab still writes PARSEABLE JSON"
else
    _bad "emit_result wrote unparseable JSON (python3 -m json.tool refused it) — the '?' cell defect is back"
fi
# Parsing is only half of it: an escape that mangles the value is still a lie
# about which row this is, so assert the ROUND TRIP field by field.
if HOSTILE_LABEL="${HOSTILE_LABEL}" HOSTILE_DETAIL="${HOSTILE_DETAIL}" \
   python3 - "${RES9}/hostile.json" <<'PY'
import json, os, sys
rec = json.load(open(sys.argv[1]))
assert rec["label"]    == os.environ["HOSTILE_LABEL"],  ("label",    rec["label"])
assert rec["detail"]   == os.environ["HOSTILE_DETAIL"], ("detail",   rec["detail"])
assert rec["platform"] == 'x86"evil',                   ("platform", rec["platform"])
assert rec["board"]    == "",                           ("board",    rec["board"])
assert rec["role"]     == "pki\\role",                  ("role",     rec["role"])
assert rec["mode"]     == "golden",                     ("mode",     rec["mode"])
assert rec["status"]   == "FAIL",                       ("status",   rec["status"])
assert rec["image"]    == '/artifacts/hug "quoted"\\dir.img', ("image", rec["image"])
assert rec["assertions_passed"] == 12 and rec["assertions_failed"] == 3, rec
PY
then
    _ok "…and every field ROUND-TRIPS byte for byte (label, detail, platform, board, role, mode, status, image)"
else
    _bad "a field did not round-trip — the escaping is lossy, not merely valid"
fi

# The other half of the same bug: a value that is EMPTY. The old sed was fed zero
# lines for "" and emitted a BARE field (`"detail": ,`), which is not JSON
# either — and "" is the NORMAL case for detail on a status-only call and for
# board on every non-ARM row.
(
    set -uo pipefail
    RESULT_DIR="${RES9}"; RESULT_JSON="${RESULT_DIR}/empty.json"
    LABEL="x86/pki"; PLATFORM="x86"; BOARD=""; ROLE="pki"; MODE="golden"
    IMG=""; STARTED_AT="2026-08-26T00:00:00Z"; START_S=0
    # shellcheck disable=SC1090
    source "${EF}"
    emit_result ERROR ""
) || _bad "emit_result run with empty fields failed outright"
python3 -m json.tool "${RES9}/empty.json" >/dev/null 2>&1 \
    && _ok "an EMPTY detail/image/board still writes parseable JSON (the bare-field edge)" \
    || _bad "empty fields produced unparseable JSON"

# An ANSI escape is not hypothetical either: coloured text from a launcher or an
# ssh diagnostic lands in ${detail}, and a raw U+001B is illegal in a JSON string
# exactly like the newline is.
(
    set -uo pipefail
    RESULT_DIR="${RES9}"; RESULT_JSON="${RESULT_DIR}/ansi.json"
    LABEL="x86/pki"; PLATFORM="x86"; BOARD=""; ROLE="pki"; MODE="golden"
    IMG=""; STARTED_AT="2026-08-26T00:00:00Z"; START_S=0
    # shellcheck disable=SC1090
    source "${EF}"
    emit_result FAIL "$(printf 'launcher said \033[0;31mboom\033[0m')"
) || _bad "emit_result run with an ANSI escape failed outright"
if python3 - "${RES9}/ansi.json" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["detail"] == "launcher said \x1b[0;31mboom\x1b[0m", repr(rec["detail"])
PY
then
    _ok "a raw ANSI escape in the detail is spelled \\u001b and round-trips"
else
    _bad "a raw control character reached the JSON (or was mangled on the way)"
fi

# -- 9b. HOSTILE board and mode -- "" and "golden" prove nothing about them --
# WHY THIS ROW EXISTS (2026-08-26, from review). The hostile row above sets
# BOARD='' and MODE='golden', and those are exactly the two values a RAW
# "${BOARD}" interpolation handles perfectly well -- so reverting either field
# to raw SURVIVED the whole suite, and two of the eight fields the fix claims to
# have routed were unpinned. Both are unvalidated argv: --board and --mode
# assign straight from "$2" and there is no whitelist anywhere in the file, so
# `--board 'rpi5"evil'` is exactly as reachable as the hostile ROLE and LABEL.
# The empty-BOARD row above STAYS -- it pins the bare-field edge, which is a
# different defect -- this row pins the escaping.
#
# STATUS and STARTED_AT are in this row at a deliberately lower stake, and it is
# worth being blunt about it: NO CALLER TODAY CAN PRODUCE A HOSTILE ONE. Every
# emit_result call site passes a literal PASS/FAIL/ERROR, and STARTED_AT is
# `date -u +...`. Reverting those two to raw is an EQUIVALENT mutant against
# today's tree. They are pinned anyway so the routing survives a future caller
# that is not a literal -- this is insurance, not a recorded incident.
HOSTILE_BOARD='rpi5"evil\board'$'\r''cr'
HOSTILE_MODE='gol"den\mode'$'\t''tab'
HOSTILE_STATUS='FA"IL\now'
HOSTILE_START='2026-08-26T00:00:00Z "then"\else'
(
    set -uo pipefail
    RESULT_DIR="${RES9}"; RESULT_JSON="${RESULT_DIR}/hostile2.json"
    LABEL="x86/pki"; PLATFORM="x86"; ROLE="pki"; IMG=""
    BOARD="${HOSTILE_BOARD}"
    MODE="${HOSTILE_MODE}"
    STARTED_AT="${HOSTILE_START}"
    START_S=0
    # shellcheck disable=SC1090
    source "${EF}"
    emit_result "${HOSTILE_STATUS}" ""
) || _bad "emit_result run with a hostile board/mode failed outright"
if HOSTILE_BOARD="${HOSTILE_BOARD}" HOSTILE_MODE="${HOSTILE_MODE}" \
   HOSTILE_STATUS="${HOSTILE_STATUS}" HOSTILE_START="${HOSTILE_START}" \
   python3 - "${RES9}/hostile2.json" <<'PYJ'
import json, os, sys
rec = json.load(open(sys.argv[1]))
assert rec["board"]      == os.environ["HOSTILE_BOARD"],  ("board",  rec["board"])
assert rec["mode"]       == os.environ["HOSTILE_MODE"],   ("mode",   rec["mode"])
assert rec["status"]     == os.environ["HOSTILE_STATUS"], ("status", rec["status"])
assert rec["started_at"] == os.environ["HOSTILE_START"],  ("start",  rec["started_at"])
PYJ
then
    _ok "a hostile --board and --mode also parse AND round-trip (all 8 string fields pinned)"
else
    _bad "board/mode/status/started_at did not survive -- a field is still interpolated raw"
fi

# -- 9d. The WHOLE C0 class, not five named spellings -----------------------
# WHY A LOOP (2026-08-26, from review). json_str spells \n \r \t \b \f short and
# everything else \u00XX. A reviewer deleted each short spelling in turn:
# dropping \t went red, but dropping \r, \b or \f left the suite at 78 passed,
# exit 0 -- and they are NOT equivalent mutants, because 0x0D, 0x08 and 0x0C sit
# OUTSIDE the fallback loop's ranges (01-07, 0b, 0e-1f) and so are not picked up
# by it. With the short spelling gone the byte reaches the JSON raw and python
# refuses the file. Rather than chase five spellings with five strings, drive
# every value the class can hold: 0x00 cannot be held in a bash variable at all,
# so 0x01-0x1F IS the whole reachable class.
C0_ARRAY="${TMP}/c0.json"
(
    set -uo pipefail
    # shellcheck disable=SC1090
    source "${EF}"
    printf '['
    for i in $(seq 1 31); do
        # printf -v, NOT $(printf ...): command substitution strips trailing
        # newlines, so 0x0A -- the single most important byte here -- would come
        # back as the empty string and this test would pass vacuously.
        printf -v _c0 '%b' "\\x$(printf '%02x' "${i}")"
        [ "${i}" -gt 1 ] && printf ','
        json_str "${_c0}"
    done
    printf ']'
) > "${C0_ARRAY}"
if python3 - "${C0_ARRAY}" <<'PYJ'
import json, sys
a = json.load(open(sys.argv[1]))
assert len(a) == 31, ("length", len(a))
bad = [(hex(i + 1), repr(a[i])) for i in range(31) if a[i] != chr(i + 1)]
assert not bad, bad
PYJ
then
    _ok "EVERY control character 0x01-0x1F is escaped and round-trips (the whole class)"
else
    _bad "a control character in 0x01-0x1F is left raw or mangled by json_str"
fi

# -- 9e. Every die() SITE really is below emit_result's definition ----------
# WHY THIS IS A TEST AND NOT A COMMENT (2026-08-26, from review). The comment
# above json_str used to justify its position by claiming die() calls
# emit_result "during argument parsing". That was INVENTED: the parse loop calls
# neither helper, emit_result is defined below the loop, and the first die() in
# the file is the --timeout check further down still. A wrong WHY is worse than
# none, because the next reader believes an arg-parse-time die() is handled.
#
# The comment is now corrected, but a comment is not a guard: nothing stopped
# anyone adding a die() up in the parse loop tomorrow, where it would hit
# `emit_result: command not found` and the row would surface as
# run-qemu-docker.sh's "container wrote no result JSON" with no cause recorded.
# So pin the REAL rule the file has always depended on — the one already spelled
# out at the --timeout check — instead of describing it.
#
# COMMENT-STRIPPED source, deliberately: the block above quotes "die()" and
# "emit_result" in prose several times over, and comment-token inversion has
# broken exactly this kind of structural check in this repo before. Stripping
# was verified not to change the die()-call count (22 either way) and no
# die()-call line carries a '#'. That 22 was measured with REAL GNU grep:
# an interactive shell on this box wraps `grep` in a ugrep shim that reports
# 21 for this pattern, which is why the number is pinned here by execution
# rather than trusted from a terminal.
STRIPPED="${TMP}/entry-stripped.sh"
sed -e 's/#.*//' "${ENTRYPOINT}" > "${STRIPPED}"
er_def="$(grep -n '^emit_result() {' "${STRIPPED}" | head -1 | cut -d: -f1)"
js_def="$(grep -n '^json_str() {'   "${STRIPPED}" | head -1 | cut -d: -f1)"
# A die CALL, not the `die() { ... }` definition: the definition line spells
# `die()`, with a paren rather than the space this pattern requires, so it is
# excluded by the pattern itself. DELIBERATELY BROAD (`\bdie ` anywhere on the
# line, not just after `||` or `;`): the first draft of this check anchored on
# `(\|\||;|^)[[:space:]]*die `, and a mutant that added `--boom) die "boom" ;;`
# INSIDE the argument-parsing loop — the exact hole this section exists to
# forbid — slipped straight past it, because the call sat after a `)`. Both
# spellings find the same 22 lines on today's tree; only the broad one is a
# guard.
first_die="$(grep -nE '\bdie ' "${STRIPPED}" | head -1 | cut -d: -f1)"
n_die="$(grep -cE '\bdie ' "${STRIPPED}")"

if [ -n "${er_def}" ] && [ -n "${js_def}" ] && [ -n "${first_die}" ]; then
    _ok "found emit_result (line ${er_def}), json_str (line ${js_def}) and ${n_die} die() call sites (first at ${first_die})"
else
    _bad "could not locate emit_result/json_str/die in the stripped source — this check is inert"
fi
if [ -n "${first_die}" ] && [ -n "${er_def}" ] && [ "${first_die}" -gt "${er_def}" ]; then
    _ok "EVERY die() call site is below emit_result's definition, so die() can actually write its ERROR row"
else
    _bad "a die() call at line ${first_die} runs BEFORE emit_result is defined (line ${er_def}) — that row dies as 'emit_result: command not found' and is filed as NO RESULT"
fi
if [ -n "${js_def}" ] && [ -n "${er_def}" ] && [ "${js_def}" -lt "${er_def}" ]; then
    _ok "…and json_str is defined above emit_result, its first caller (ordering hygiene, which is all that move ever was)"
else
    _bad "json_str is no longer above emit_result"
fi

# ══ 10. The FAILED scrape is anchored to the RESULT line ═══════════════════
echo
echo "assertion counts — 'N failed' anywhere else in the log is not the verdict"
# WHY. PASSED has always been anchored ('RESULT: [0-9]+ passed'); FAILED matched
# a bare '[0-9]+ failed' ANYWHERE in assertions.log — which is the guest's whole
# stdout. The AVC harvest, service logs and the assertion messages themselves all
# flow through it, and `head -1` means the FIRST such phrase won. A clean run
# could be filed with a fabricated failure count, and a real one masked by an
# earlier unrelated phrase. Both numbers must come off the SAME sentence.
got="$(run_verdict 0 1 \
        '  FAIL  gitops tree: 7 failed to sync' \
        '-- AVC harvest (data, not verdicts) --' \
        'kubelet: 4 failed probes in the last hour' \
        '== RESULT: 30 passed, 0 failed ==')"
eq "$(echo "${got}" | head -1)" "PASS|all assertions passed|30|0" \
   "decoy 'N failed' lines BEFORE the RESULT line are not scraped as the row's fail count"

got="$(run_verdict 1 1 \
        'kubelet: 4 failed probes in the last hour' \
        '== RESULT: 30 passed, 3 failed ==')"
eq "$(echo "${got}" | head -1)" "FAIL|assertions failed|30|3" \
   "…and the REAL count is still read off the RESULT line when the row genuinely fails"

# Both scrape SITES, not just the one emit_assertion_verdict owns: the stage4
# delegation path holds an identical twin, and a fix applied to only one of them
# is exactly the asymmetry that survives review. Checked against COMMENT-STRIPPED
# source: this repo writes long WHY comments that quote the very tokens a check
# greps for, and prose naming a token has inverted this kind of check four times
# here already.
NC="${TMP}/entrypoint-nocomment.sh"
grep -vE '^[[:space:]]*#' "${ENTRYPOINT}" > "${NC}"
n_anchor="$(grep -cE "grep -oE 'RESULT: \[0-9\]\+ passed, \[0-9\]\+ failed'" "${NC}" || true)"
eq "${n_anchor}" "2" "both scrape sites (stage4 + golden) anchor the fail count on the RESULT line"
# The DEFECT spelling, precisely: a '[0-9]+ failed' grep handed a FILE to read.
# In the fixed code that grep is only ever fed from a pipe, never given a path.
if grep -qE "grep -oE '\[0-9\]\+ failed'[[:space:]]+\"" "${NC}"; then
    _bad "an unanchored fail scrape still reads the log file directly (line $(grep -nE "grep -oE '\[0-9\]\+ failed'[[:space:]]+\"" "${NC}" | head -1 | cut -d: -f1))"
else
    _ok "no fail scrape reads a log file directly — every one is fed from the anchored match"
fi

# ══ 11. mesh-cluster.sh: the skips are LOUD, and still exit 0 ══════════════
echo
echo "mesh-cluster.sh — a skip announces itself; the exit code is untouched policy"
# The exit code here is DECLARED POLICY (the GATING block in that file's header):
# a driver that boots three real x86 guests has nothing to fail on a runner with
# no qemu and no opt-in, and these tests PIN that 0 rather than change it. What
# was wrong was the SILENCE — one green info() line, the same colour and stream
# as ordinary progress, and no verdict line at all, which reads identically to
# "ran and passed quietly". That is the shape that let DAST sit inert for weeks
# (four silent-skip paths, PR #139).
#
# A PATH with only the handful of tools mesh-cluster.sh needs to REACH its gates,
# and deliberately WITHOUT qemu-system-x86_64: qemu is installed on this box, so
# without the masking the no-qemu leg would pass vacuously by never being taken.
mkdir -p "${TMP}/nobin"
for t in dirname basename date mkdir sed grep tr cat id; do
    tp="$(command -v "${t}" 2>/dev/null)" && ln -sf "${tp}" "${TMP}/nobin/${t}"
done
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "  note qemu-system-x86_64 IS installed here — the no-qemu leg is reached by PATH masking"
else
    echo "  note qemu-system-x86_64 is not installed here — the no-qemu leg is reached natively"
fi

# THE TWO STREAMS ARE KEPT APART ON PURPOSE (2026-08-26, from review). This
# helper used to collapse rc, stdout and stderr into one "rc|out|err" string and
# the RESULT-line checks pattern-matched the WHOLE string. That pinned the text
# but NOT the stream: redirecting skip_out's RESULT line to stderr left the
# suite at 78 passed, exit 0 — while "on STDOUT, where a log scraper looks" is
# the explicit contract in mesh-cluster.sh's own header comment. A single
# "rc|out|err" string was also one `|` in a detail message away from splitting
# wrong. So each stream now lands in its own global and each check names the one
# it means.
MS_RC=0; MS_OUT=""; MS_ERR=""
mesh_skip() { # mesh_skip ENVVAL normal|noqemu -> sets MS_RC / MS_OUT / MS_ERR
    local envval="$1"
    local pathmode="$2"
    local o="${TMP}/mesh.out"
    local e="${TMP}/mesh.err"
    local p="${PATH}"
    [ "${pathmode}" = "noqemu" ] && p="${TMP}/nobin"
    MS_RC=0
    # env -i so an ambient HUGMESH_QEMU_MESH in the developer's shell cannot
    # decide which gate this test actually exercises.
    env -i PATH="${p}" HOME="${TMP}" TERM=dumb HUGMESH_QEMU_MESH="${envval}" \
        "${BASH}" "${MESH}" > "${o}" 2> "${e}" || MS_RC=$?
    MS_OUT="$(tr '\n' ' ' < "${o}")"
    MS_ERR="$(tr '\n' ' ' < "${e}")"
}

mesh_skip '' normal
eq "${MS_RC}" "0" "no opt-in: still exits 0 (DECLARED POLICY — this fix does not touch the exit code)"
case "${MS_OUT}" in
    *'RESULT:  SKIP reason=no-opt-in'*) _ok "no opt-in: the machine-readable RESULT SKIP line is on STDOUT, where a scraper looks" ;;
    *) _bad "no opt-in: no 'RESULT:  SKIP reason=no-opt-in' line ON STDOUT (stdout was: ${MS_OUT})" ;;
esac
case "${MS_ERR}" in
    *SKIP*) _ok "no opt-in: the reason also reaches STDERR, so a skip is not ordinary progress" ;;
    *) _bad "no opt-in: nothing on stderr — the skip still reads as a quiet pass" ;;
esac
case "${MS_OUT}${MS_ERR}" in
    *'NOTHING WAS BOOTED OR ASSERTED'*) _ok "no opt-in: says in words that nothing was verified" ;;
    *) _bad "no opt-in: the message never states that nothing ran" ;;
esac

mesh_skip '1' noqemu
eq "${MS_RC}" "0" "opted in but no qemu: still exits 0 (same declared policy)"
case "${MS_OUT}" in
    *'RESULT:  SKIP reason=no-qemu'*) _ok "opted in but no qemu: a DIFFERENT, greppable reason slug, also on STDOUT" ;;
    *) _bad "opted in but no qemu: reason slug missing, not distinct, or not on stdout (stdout was: ${MS_OUT})" ;;
esac
case "${MS_ERR}" in
    *SKIP*) _ok "opted in but no qemu: the reason reaches stderr too" ;;
    *) _bad "opted in but no qemu: nothing on stderr" ;;
esac

# ══ 12. Payload + ownership hygiene: three things that used to pass in silence ══
echo
echo "KEYS payload + reown — no silent no-ops"

# ── 12a. A missing headscale config must SAY SO ────────────────────────────
# It was a bare `[ -f ... ] && cp ...`: with /src mounted from a tree that has no
# specs/etc/headscale/config.yaml the test simply evaluated false, nothing was
# copied, NOTHING WAS PRINTED, and provision.json below still declared
# "config_file": "headscale/config.yaml". The row then failed its headscale
# assertions with a guest-side symptom whose cause was a file missing on the HOST.
HSB="${TMP}/hs-block.sh"
sed -n '/^if \[ -f "${SRC}\/specs\/etc\/headscale\/config.yaml" \]; then$/,/^fi$/p' \
    "${ENTRYPOINT}" > "${HSB}"
grep -q '^fi$' "${HSB}" \
    || { echo "could not extract the headscale-config block from ${ENTRYPOINT}" >&2; exit 2; }

hs_run() { # hs_run present|absent -> the warn text (empty when it said nothing)
    local mode="$1"
    local src="${TMP}/hs-src" keys="${TMP}/hs-keys"
    rm -rf "${src}" "${keys}"; mkdir -p "${src}" "${keys}/headscale"
    if [ "${mode}" = "present" ]; then
        mkdir -p "${src}/specs/etc/headscale"
        echo "server_url: http://example" > "${src}/specs/etc/headscale/config.yaml"
    fi
    ( set -uo pipefail
      SRC="${src}"; KEYS_SRC="${keys}"
      warn() { printf 'WARN:%s\n' "$*"; }
      # shellcheck disable=SC1090
      source "${HSB}" ) 2>&1
}
out="$(hs_run absent)"
case "${out}" in
    *WARN:*headscale*) _ok "a MISSING specs/etc/headscale/config.yaml warns by name instead of passing in silence" ;;
    *) _bad "a missing headscale config still says nothing at all (got: '${out}')" ;;
esac
case "${out}" in
    *pki*|*generic*|*omnibus*) _ok "…and the warning names the roles whose assertions this will bend" ;;
    *) _bad "the warning does not say which rows are affected (got: '${out}')" ;;
esac
out="$(hs_run present)"
eq "${out}" "" "a PRESENT config still copies quietly — this adds noise only where there was a real gap"
[ -s "${TMP}/hs-keys/headscale/config.yaml" ] \
    && _ok "…and the file really lands on the KEYS payload" \
    || _bad "the config was not copied onto the KEYS payload"

# ── 12b. kubernetes.role is DERIVED, not the constant "control-plane" ───────
# Every row used to be handed "control-plane", so provision.sh logged
# `Kubernetes role: control-plane` on a frontend, a worker and a client desktop
# alike. The expectations below are copied from the builders' own ROLE_K8S
# tables (build-rpi5-stage4.sh:2822, build-x86-host-stage4.sh:1245-1325) — this
# test fails if THIS file and the builders ever disagree about what a role is.
KRB="${TMP}/k8srole-block.sh"
sed -n '/^K8S_ROLE="worker"$/,/^esac$/p' "${ENTRYPOINT}" > "${KRB}"
grep -q '^esac$' "${KRB}" \
    || { echo "could not extract the K8S_ROLE derivation from ${ENTRYPOINT}" >&2; exit 2; }
k8s_role_of() { ( set -u; ROLE="$1"; source "${KRB}"; printf '%s' "${K8S_ROLE}" ); }
eq "$(k8s_role_of pki)"      "control-plane" "role pki      -> control-plane (the identity node inits the cluster)"
eq "$(k8s_role_of omnibus)"  "control-plane" "role omnibus  -> control-plane (ROLE_K8S=single-node; provision.sh knows no such spelling)"
eq "$(k8s_role_of generic)"  "worker"        "role generic  -> worker (headscale runs on it, but it is NOT a control plane)"
eq "$(k8s_role_of backend)"  "worker"        "role backend  -> worker"
eq "$(k8s_role_of frontend)" "worker"        "role frontend -> worker"
eq "$(k8s_role_of be)"       "worker"        "role be       -> worker"
eq "$(k8s_role_of 'be+gpu')" "worker"        "role be+gpu   -> worker"
eq "$(k8s_role_of edge_ai)"  "worker"        "role edge_ai  -> worker"
eq "$(k8s_role_of desktop)"  "none"          "role desktop  -> none (the sysroot has no kubeadm/kubelet at all)"
eq "$(k8s_role_of laptop)"   "none"          "role laptop   -> none (client device, not a cluster node)"
eq "$(k8s_role_of standalone-thick)" "none"  "role standalone-* -> none"
# …and the manifest must actually USE it. Checked comment-stripped: the WHY block
# above the derivation quotes "control-plane" repeatedly, and a raw grep would
# read that prose as the code still being hardcoded.
NC12="${TMP}/entrypoint-nocomment-12.sh"
grep -vE '^[[:space:]]*#' "${ENTRYPOINT}" > "${NC12}"
grep -q '"kubernetes": { "role": "\${K8S_ROLE}"' "${NC12}" \
    && _ok "provision.json interpolates \${K8S_ROLE}, not a constant" \
    || _bad "provision.json does not use the derived role (still hardcoded?)"
grep -q '"kubernetes": { "role": "control-plane"' "${NC12}" \
    && _bad "provision.json still hardcodes control-plane" \
    || _ok "…and the hardcoded control-plane spelling is gone from the code"

# ── 12c. reown() hands the flock file back too ─────────────────────────────
# extract_kernel's fallback pass opens ${WORK}/.loop-mount.lock with `exec 9>>`,
# which CREATES it root-owned. Everything else this container writes was already
# reowned; the lock was not — so a later UNPRIVILEGED run got EACCES on the
# append, `exec 9>>` failed, and with no fd 9 the flock serialization silently
# degraded to the sleep-retry backstop: the host-wide loop-device race the flock
# exists to remove, re-armed by a file mode, reported as "could not extract kernel".
RF="${TMP}/reown-fns.sh"; : > "${RF}"
extract "${ENTRYPOINT}" reown "${RF}"
cat > "${TMP}/bin/chown" <<'CHOWN'
#!/bin/sh
printf '%s\n' "$*" >> "${CHOWN_LOG}"
exit 0
CHOWN
chmod +x "${TMP}/bin/chown"
CHOWN_LOG="${TMP}/chown.args"; : > "${CHOWN_LOG}"
( set -uo pipefail
  PATH="${TMP}/bin:${PATH}"; export CHOWN_LOG
  HOST_UID="1000"; HOST_GID="1000"
  WORK="/work"; RUN_DIR="/work/runs/x86_pki"; RESULT_DIR="/work/results"
  # shellcheck disable=SC1090
  source "${RF}"; reown )
grep -q '/work/.loop-mount.lock' "${CHOWN_LOG}" \
    && _ok "reown() chowns \${WORK}/.loop-mount.lock, so a later unprivileged run can still take it" \
    || _bad "the flock file is never chowned — the next unprivileged run loses fd 9 silently"
grep -q '/work/results' "${CHOWN_LOG}" \
    && _ok "…without dropping any of the paths reown already handed back" \
    || _bad "reown stopped chowning the result dir"
# The no-HOST_UID case must stay a complete no-op: the dockerized build passes
# HOST_UID, a bare `docker run` does not, and chowning to nothing would be worse
# than leaving it root-owned.
: > "${CHOWN_LOG}"
( set -uo pipefail
  PATH="${TMP}/bin:${PATH}"; export CHOWN_LOG
  HOST_UID=""; HOST_GID=""
  WORK="/work"; RUN_DIR="/work/runs/x86_pki"; RESULT_DIR="/work/results"
  # shellcheck disable=SC1090
  source "${RF}"; reown )
eq "$(wc -c < "${CHOWN_LOG}" | tr -d ' ')" "0" \
   "with no HOST_UID, reown() still chowns nothing at all"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
