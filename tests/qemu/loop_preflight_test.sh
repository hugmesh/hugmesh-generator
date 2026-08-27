#!/usr/bin/env bash
# loop_preflight_test.sh — HERMETIC tests for the loop-device preflight, the
# --jobs 0 fan-out gate, and emit_result's JSON escaping. Boots nothing, starts
# no container, attaches no real loop device: functions are sed-extracted from
# run-qemu-docker.sh / docker-entrypoint.sh (the devices_test.sh /
# verdict_test.sh pattern) and driven with stubs on PATH.
#
#   bash tests/qemu/loop_preflight_test.sh
#
# WHY THIS FILE EXISTS — three defects found on 2026-08-26, all silent:
#
#  1. LOOP DEVICES. `--jobs 2` over rpi5 failed backend and frontend in
#     extract_kernel while pki passed. This host boots with max_loop=0, so
#     devtmpfs has only /dev/loop-control until the first LOOP_CTL_GET_FREE
#     materialises /dev/loop0; a container's /dev is a CREATION-TIME SNAPSHOT,
#     so the two containers created before that instant could never see a loop
#     device. Birth times: loop-control 10:02:33 (boot), loop0 11:27:36,
#     backend's image ready 11:27:35.94.
#
#     THE TESTING TRAP, stated plainly: every failing run LEAVES THE NODE
#     BEHIND. After two failures the host had loop0 and loop1 and the matrix
#     "started passing" with nothing fixed — the harness heals itself into
#     green. So every assertion below drives ensure_loop_devices against a SEAM
#     directory (LOOP_DEV_DIR) holding a forced-low number of fake nodes. A test
#     that counted the real /dev on this box would take the "already enough"
#     early return and assert nothing. See the HONEST GAPS note at the bottom.
#
#  2. --jobs 0. Documented in the usage text and implemented in the keep-alive
#     lane as "ungated, everything at once". In the plain fan-out the gate was
#     `[ running -ge JOBS ]`, and 1 >= 0 is TRUE, so --jobs 0 waited after every
#     single row: it FULLY SERIALIZED the matrix. Never red, only slow, which is
#     why it survived.
#
#  3. emit_result interpolated label/platform/board/role/mode/image RAW into its
#     result JSON while write_device_record — the same fields, same file — routed
#     everything through json_str. One double quote in an operator-supplied
#     --label or in an image PATH wrote a row no parser accepts, and the Studio
#     renders an unparseable row as '?'. Its FAILED count was also scraped with
#     an UNANCHORED '[0-9]+ failed' over the whole guest transcript, where
#     `rc-status`'s own "0 failed" line sorts long before the verdict line.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${HERE}/run-qemu-docker.sh"
ENTRYPOINT="${HERE}/docker-entrypoint.sh"
for f in "${RUNNER}" "${ENTRYPOINT}"; do
    [ -f "${f}" ] || { echo "cannot find ${f}" >&2; exit 2; }
done
command -v python3 >/dev/null \
    || { echo "SKIP(LOUD): python3 is required to parse the emitted JSON — refusing to pass vacuously" >&2; exit 2; }

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (got '$1', want '$2')"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

extract() { # extract FILE FUNCNAME OUT — die if the function is not found
    sed -n "/^$2() {/,/^}/p" "$1" >> "$3"
    grep -q "^$2() {" "$3" || { echo "could not extract $2 from $1" >&2; exit 2; }
}

# ══ 1. --jobs 0 is UNGATED ══════════════════════════════════════════════════
# Driven by EXECUTION, not by reading the source: run_row and fan_out_rows are
# extracted and run for real against a stub `docker` on PATH that records its
# argv and then BLOCKS until released. While it blocks, the number of recorded
# starts IS the number of rows the gate let through concurrently.
echo "fan_out_rows — --jobs 0 means ungated, not serialized"

FANOUT="${TMP}/fanout.sh"; : > "${FANOUT}"
extract "${RUNNER}" run_row "${FANOUT}"
extract "${RUNNER}" fan_out_rows "${FANOUT}"

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
# Records argv, announces a start, blocks until ${RELEASE} appears, announces
# the end. Blocking is the point: it holds the row "running" so the gate's
# concurrency is observable from outside.
lbl=""; prev=""
for a in "$@"; do [ "${prev}" = "--label" ] && lbl="${a}"; prev="${a}"; done
printf '%s\n' "$*" >> "${ARGV_LOG}"
printf 'start %s\n' "${lbl}" >> "${EVENTS}"
while [ ! -e "${RELEASE}" ]; do sleep 0.05; done
printf 'end %s\n' "${lbl}" >> "${EVENTS}"
exit 0
FAKE
chmod +x "${TMP}/bin/docker"
PATH="${TMP}/bin:${PATH}"

# Globals run_row reads. None of them is touched — no container is created.
WORK="${TMP}/work"; mkdir -p "${WORK}"
REPO_DIR="${TMP}/repo"; ARTIFACTS="${TMP}/artifacts"; mkdir -p "${REPO_DIR}" "${ARTIFACTS}"
IMAGE_TAG="stub-image:latest"; MODE="golden"; MEM=2048; SMP=2; TIMEOUT=900
ASSERT_TIMEOUT=""; KEEP=false; KVM_ARGS=(); GREEN=""; RED=""; RST=""
ROWS=("1|rpi5|pki|env|a.img" "2|rpi5|backend|env|b.img" "3|rpi5|frontend|env|c.img" "4|x86|be|env|d.img")
export ARGV_LOG="${TMP}/argv.log" EVENTS="${TMP}/events" RELEASE="${TMP}/release"
# shellcheck disable=SC1090
source "${FANOUT}"

starts() { grep -c '^start ' "${EVENTS}" 2>/dev/null || true; }
ends()   { grep -c '^end '   "${EVENTS}" 2>/dev/null || true; }

# run_fanout JOBS WANT_CONCURRENT -> prints "<peak starts while blocked>|<FAILED>"
run_fanout() {
    local jobs want
    jobs="$1"; want="$2"
    rm -f "${EVENTS}" "${ARGV_LOG}" "${RELEASE}"; : > "${EVENTS}"
    JOBS="${jobs}"
    # run_row prints a [PASS]/[FAIL] line per row; it must not land in this
    # function's own stdout, which the caller parses.
    ( fan_out_rows >"${TMP}/rowout" 2>&1; printf '%s\n' "${FAILED}" > "${TMP}/failed" ) &
    local fpid peak i
    fpid=$!
    # Wait for the gate to settle: poll until the wanted count is reached, then
    # keep watching a little longer so an OVER-shoot is caught too (a gate that
    # admits 4 when it should admit 1 must not pass by being sampled early).
    peak=0
    for i in $(seq 60); do
        local n; n="$(starts)"
        [ "${n}" -gt "${peak}" ] && peak="${n}"
        [ "${peak}" -ge "${want}" ] && [ "${i}" -ge 20 ] && break
        sleep 0.1
    done
    : > "${RELEASE}"
    wait "${fpid}" 2>/dev/null
    printf '%s|%s\n' "${peak}" "$(cat "${TMP}/failed" 2>/dev/null || echo '?')"
}

got="$(run_fanout 0 4)"
eq "${got%%|*}" "4" "--jobs 0 starts all 4 rows at once (the bare 'running >= JOBS' gate serialized to 1)"
eq "${got##*|}" "0" "--jobs 0: every row is still waited for and none is reported failed"

# Controls. Without these, an 'ungated' assertion also passes for a gate that
# was deleted outright, which would silently un-fix the 2026-08-19 ten-VMs-at-
# once defect --jobs exists to prevent.
got="$(run_fanout 1 1)"
eq "${got%%|*}" "1" "control: --jobs 1 holds at exactly one row in flight"
eq "$(ends)" "4" "control: --jobs 1 still runs all 4 rows to completion"
got="$(run_fanout 2 2)"
eq "${got%%|*}" "2" "control: --jobs 2 holds at exactly two rows in flight"

# The argv the gate fanned out is the real docker argv, not a paraphrase.
# argv_has WORD… — do those words appear as CONSECUTIVE, WHOLE argv words on
# some line of the log? Exact string comparison, not a substring grep, because a
# substring grep only ever catches a flag being DELETED — the one mutation nobody
# makes by accident. `-v /dev:/dev-host` and `--privileged=false-not-really` both
# contain the flag as a substring, both sail past an unanchored grep, and both
# completely destroy the fix: the nodes land where the container cannot open them.
# Comparing words also sidesteps regex metacharacters in a flag value entirely.
argv_has() {
    local -a want
    want=("$@")
    local line ok i j
    local -a got
    while IFS= read -r line; do
        # shellcheck disable=SC2206
        got=(${line})
        i=0
        while [ "${i}" -lt "${#got[@]}" ]; do
            ok=true; j=0
            while [ "${j}" -lt "${#want[@]}" ]; do
                [ "${got[$((i+j))]:-}" = "${want[${j}]}" ] || { ok=false; break; }
                j=$((j + 1))
            done
            ${ok} && return 0
            i=$((i + 1))
        done
    done < "${ARGV_LOG}"
    return 1
}

argv_has '--privileged' \
    && _ok "fanned-out argv still carries --privileged (losetup -P inside)" \
    || _bad "fanned-out argv lost --privileged"
argv_has '--rm' \
    && _ok "fanned-out argv still carries --rm (no stopped container left per row)" \
    || _bad "fanned-out argv lost --rm — every row leaks a stopped container"
eq "$(grep -c -- '--label' "${ARGV_LOG}")" "4" "one docker run per row, each with its --label"

# ══ 2. ensure_loop_devices ══════════════════════════════════════════════════
echo
echo "ensure_loop_devices — nodes forced onto the host BEFORE any container exists"

LOOPFNS="${TMP}/loopfns.sh"; : > "${LOOPFNS}"
extract "${RUNNER}" loop_node_count "${LOOPFNS}"
extract "${RUNNER}" ensure_loop_devices "${LOOPFNS}"
info() { printf 'INFO %s\n' "$*"; }
step() { printf 'STEP %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
# shellcheck disable=SC1090
source "${LOOPFNS}"
LOOP_PREFLIGHT_MAX=8

# A fake devtmpfs. THE POINT OF THE SEAM: this host already healed itself into
# having /dev/loop0 and /dev/loop1, so counting the real /dev would take the
# early return and prove nothing.
seed_dev() { # seed_dev N
    LOOP_DEV_DIR="${TMP}/dev"; rm -rf "${LOOP_DEV_DIR}"; mkdir -p "${LOOP_DEV_DIR}"
    touch "${LOOP_DEV_DIR}/loop-control"          # never counted: no digit suffix
    local i
    for i in $(seq 0 $(( $1 - 1 ))); do [ "$1" -gt 0 ] && touch "${LOOP_DEV_DIR}/loop${i}"; done
    rm -rf "${TMP}/held"; mkdir -p "${TMP}/held"
    : > "${TMP}/loop-events"
}

# A devtmpfs that also carries PARTITION nodes. seed_dev alone cannot represent
# one, which is exactly how the over-count survived: `loop[0-9]*` is loop + a
# digit + ANYTHING, so /dev/loop0p1 matches it. Those nodes are not hypothetical
# for this harness — extract_kernel's whole job is `losetup -P` on a
# multi-partition golden image, -P materialises loop0p1..pN on the HOST
# devtmpfs, and the script documents concurrent runs against one --work, so run
# B really does see run A's partition nodes.
seed_dev_parts() { # seed_dev_parts NDEV NPARTS
    seed_dev "$1"
    local d
    local q
    for d in $(seq 0 $(( $1 - 1 ))); do
        for q in $(seq 1 "$2"); do touch "${LOOP_DEV_DIR}/loop${d}p${q}"; done
    done
}

seed_dev 4
eq "$(loop_node_count)" "4" "loop_node_count counts loopN and ignores loop-control"
seed_dev 0
eq "$(loop_node_count)" "0" "a devtmpfs with no loop node at all counts 0 (this host at boot)"
seed_dev_parts 1 3
eq "$(loop_node_count)" "1" "loop0 + loop0p1..p3 is ONE loop device, not four (partition nodes are not devices)"
seed_dev 11
eq "$(loop_node_count)" "11" "control: loop10 still counts — the fix rejects a non-digit, not a long name"

# A docker stub that behaves like the real privileged container: it EXECUTES the
# -c script it was handed, with a stub losetup that models the kernel — every
# LOOP_CTL_GET_FREE creates a node that PERSISTS after detach, which is exactly
# why a failing run leaves the harness looking fixed.
cat > "${TMP}/bin/losetup" <<'FAKE'
#!/usr/bin/env bash
# Models LOOP_CTL_GET_FREE the way the kernel actually behaves, because the
# difference IS the defect: an attach REUSES the lowest-numbered node that is
# free and only materialises a NEW one when every existing node is held. That is
# precisely why `losetup -f` on its own creates nothing, and why N nodes require
# N simultaneous attaches. A node, once created, SURVIVES detach — which is how
# the failing runs healed this host into looking fixed.
n=0
case "${1:-}" in
  -f) while :; do
          if [ ! -e "${LOOP_DEV_DIR}/loop${n}" ] || [ ! -e "${STUB_HELD}/${n}" ]; then break; fi
          n=$((n + 1))
      done
      mkdir -p "${STUB_HELD}"
      touch "${LOOP_DEV_DIR}/loop${n}" "${STUB_HELD}/${n}"
      printf 'attach %s\n' "${n}" >> "${LOOP_EVENTS}"
      printf '/dev/loop%s\n' "${n}" ;;
  -d) n="${2##*/loop}"
      rm -f "${STUB_HELD}/${n}"                  # released, but the NODE remains
      printf 'detach %s\n' "${n}" >> "${LOOP_EVENTS}" ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin/losetup"
cat > "${TMP}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ARGV_LOG}"
[ -e "${DOCKER_NOOP:-/nonexistent}" ] && exit 0        # green, and did nothing
[ -e "${DOCKER_MUST_FAIL:-/nonexistent}" ] && exit 125
script=""; take=false; args=()
for a in "$@"; do
    if ${take}; then script="${a}"; take=false; continue; fi
    case "${a}" in -c) take=true ;; esac
done
# Everything after the image is the -c script's argv; the runner passes `_ WANT`.
want="${!#}"
STUB_HELD="${STUB_HELD}" LOOP_EVENTS="${LOOP_EVENTS}" LOOP_DEV_DIR="${LOOP_DEV_DIR}" \
    bash -c "${script}" _ "${want}"
FAKE
chmod +x "${TMP}/bin/docker"
export STUB_HELD="${TMP}/held" LOOP_EVENTS="${TMP}/loop-events"

# (a) already enough => no container at all.
seed_dev 4; : > "${ARGV_LOG}"
export LOOP_DEV_DIR
out="$(ensure_loop_devices 2)"
eq "$(grep -c . "${ARGV_LOG}")" "0" "with enough nodes already present, no container is started"
printf '%s' "${out}" | grep 'already on the host' >/dev/null \
    && _ok "…and it says so" || _bad "…but said '${out}'"

# (b) short => one privileged container with the HOST devtmpfs bind-mounted in.
seed_dev 1; : > "${ARGV_LOG}"
out="$(ensure_loop_devices 4 2>&1)"
eq "$(loop_node_count)" "4" "4 nodes wanted, 4 nodes exist on the (fake) host devtmpfs afterwards"
argv_has '--privileged' \
    && _ok "the attach runs privileged (LOOP_CTL_GET_FREE needs CAP_SYS_ADMIN)" \
    || _bad "the attach container is not privileged"
argv_has '-v' '/dev:/dev' \
    && _ok "the host /dev is bind-mounted in, so the nodes land on the HOST devtmpfs" \
    || _bad "no -v /dev:/dev — nodes would be created in a container-private tmpfs"
argv_has '--rm' \
    && _ok "the throwaway attach container is --rm (a short-count run leaks nothing)" \
    || _bad "the preflight container is not --rm — every short-count run leaks one"
printf '%s' "${out}" | grep 'WARN' >/dev/null \
    && _bad "a successful preflight must not warn" || _ok "a successful preflight does not warn"

# THE MECHANISM, asserted rather than assumed: `losetup -f` on a host with one
# free device returns it WITHOUT allocating anything new, so N nodes only appear
# if N attaches are held SIMULTANEOUSLY. Every attach must therefore precede
# every detach.
first_detach="$(grep -n '^detach' "${LOOP_EVENTS}" | head -1 | cut -d: -f1)"
last_attach="$(grep -n '^attach' "${LOOP_EVENTS}" | tail -1 | cut -d: -f1)"
n_attach="$(grep -c '^attach' "${LOOP_EVENTS}")"
eq "${n_attach}" "4" "it attaches 4 times, not once — a single attach would reuse free loop0 and create nothing"
if [ -n "${first_detach}" ] && [ "${last_attach}" -lt "${first_detach}" ]; then
    _ok "all attaches are held SIMULTANEOUSLY, then detached (a lone 'losetup -f' creates nothing)"
else
    _bad "attach/detach interleaved (attach@${last_attach} detach@${first_detach:-none}) — this allocates ONE node, not N"
fi
eq "$(grep -c '^detach' "${LOOP_EVENTS}")" "4" "every throwaway attach is detached again (nothing left claiming a device)"

# (b2) END TO END on a partitioned seam. ONE loop device plus its partition
# nodes must NOT satisfy `want 3`: over-counting them takes the "already enough"
# early return, creates nothing, and prints a reassuring line on exactly the host
# that needed the preflight most — the guard succeeding at the moment it matters.
seed_dev_parts 1 3; : > "${ARGV_LOG}"
out="$(ensure_loop_devices 3 2>&1)"
# Non-empty, not a line count: the recorded argv contains the multi-line `-c`
# script, so one container is many lines in the log.
started="no"; [ -s "${ARGV_LOG}" ] && started="yes"
eq "${started}" "yes" "1 device + 3 partition nodes does NOT satisfy want=3 — the container still runs"
eq "$(loop_node_count)" "3" "…and 3 real loop devices exist afterwards (partition nodes still not counted)"
printf '%s' "${out}" | grep 'already on the host' >/dev/null \
    && _bad "took the 'already enough' early return off partition nodes" \
    || _ok "…and it never claimed the partition nodes were already enough"

# (c) it cannot => LOUD warning, never fatal, and it believes the NODE COUNT.
seed_dev 1; : > "${ARGV_LOG}"
touch "${TMP}/docker-must-fail"; export DOCKER_MUST_FAIL="${TMP}/docker-must-fail"
out="$(ensure_loop_devices 4 2>&1; printf 'rc=%s' "$?")"
rm -f "${TMP}/docker-must-fail"; unset DOCKER_MUST_FAIL
printf '%s' "${out}" | grep 'rc=0$' >/dev/null \
    && _ok "a host that refuses the preflight does not kill the run" \
    || _bad "ensure_loop_devices returned nonzero (got: ${out})"
printf '%s' "${out}" | grep 'LOOP PREFLIGHT INCOMPLETE' >/dev/null \
    && _ok "…it skips LOUDLY, naming what it could not do (no silent exit 0)" \
    || _bad "…silently: no LOOP PREFLIGHT INCOMPLETE warning (got: ${out})"

# (e) NO VACUOUS PASS: a container that exits 0 having created nothing is still
# a failed preflight. The verdict has to come from the node count on the host,
# never from docker's exit code — this is the same class of defect as grading a
# truncated assertion run by ssh's rc.
seed_dev 1; : > "${ARGV_LOG}"
touch "${TMP}/docker-noop"; export DOCKER_NOOP="${TMP}/docker-noop"
out="$(ensure_loop_devices 4 2>&1; printf 'rc=%s' "$?")"
rm -f "${TMP}/docker-noop"; unset DOCKER_NOOP
printf '%s' "${out}" | grep 'LOOP PREFLIGHT INCOMPLETE' >/dev/null \
    && _ok "a green container that created NO node is still reported as incomplete" \
    || _bad "exit code 0 was believed over the node count (got: ${out})"

# (d) it is wired in AHEAD of every container this run creates. Line order, not
# reading: the call has to precede both fan-outs or it is decoration.
# Both fan-outs are compared at their CALL SITES, not at the definitions of the
# functions they call: start_device_row and run_row are defined hundreds of
# lines earlier and say nothing about when a container is actually created.
l_call="$(grep -n '^ensure_loop_devices "\${#ROWS\[@\]}"' "${RUNNER}" | cut -d: -f1 | head -1)"
l_keep="$(grep -n '^        if start_device_row "\${platform}"' "${RUNNER}" | cut -d: -f1 | head -1)"
l_fan="$(grep -n '^fan_out_rows$' "${RUNNER}" | cut -d: -f1 | head -1)"
if [ -n "${l_call}" ] && [ -n "${l_keep}" ] && [ -n "${l_fan}" ] \
   && [ "${l_call}" -lt "${l_keep}" ] && [ "${l_call}" -lt "${l_fan}" ]; then
    _ok "ensure_loop_devices is called before BOTH fan-outs (keep-alive and plain)"
else
    _bad "preflight not ahead of the fan-outs (call=${l_call:-none} keepalive=${l_keep:-none} fanout=${l_fan:-none})"
fi

# ══ 3. emit_result: an operator-supplied label cannot break the row ══════════
echo
echo "emit_result — every string field survives quotes and backslashes"

EF="${TMP}/emit.sh"; : > "${EF}"
extract "${ENTRYPOINT}" json_str "${EF}"
# emit_result's body is a JSON heredoc whose closing '}' sits at column 0, so the
# plain sed range would truncate it mid-heredoc (verdict_test.sh has the same
# problem with write_device_record). Its real end is the '}' after the heredoc's
# own EOF terminator.
awk '
    $0 == "emit_result() {" { infn = 1 }
    infn { print; if ($0 == "}" && prev == "EOF") exit; prev = $0 }
' "${ENTRYPOINT}" >> "${EF}"
grep -q '^emit_result() {' "${EF}" && [ "$(tail -1 "${EF}")" = "}" ] \
    || { echo "could not extract emit_result from ${ENTRYPOINT}" >&2; exit 2; }

NASTY='rpi5/say "hi"\back'
run_emit() { # run_emit LABEL IMG DETAIL -> path to the emitted JSON
    local rdir; rdir="${TMP}/emit"; rm -rf "${rdir}"; mkdir -p "${rdir}"
    ( set -uo pipefail
      RESULT_DIR="${rdir}"; RESULT_JSON="${rdir}/row.json"
      LABEL="$1"; PLATFORM="rpi5"; BOARD=""; ROLE='be"gpu'; MODE="golden"
      IMG="$2"; STARTED_AT="2026-08-26T12:00:00Z"; START_S=0
      # shellcheck disable=SC1090
      source "${EF}"
      emit_result "PASS" "$3" 33 0 )
    printf '%s\n' "${TMP}/emit/row.json"
}

j="$(run_emit "${NASTY}" '/artifacts/we"ird\path.img' 'all assertions passed')"
if python3 -m json.tool < "${j}" > /dev/null 2>&1; then
    _ok "a label holding a double quote AND a backslash still emits parseable JSON"
else
    _bad "emitted JSON is unparseable: $(tr '\n' ' ' < "${j}")"
fi
# Parseable is not enough — the value has to come back INTACT, or a "strip the
# quotes" implementation would pass the test above while corrupting the row.
got="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["label"])' "${j}" 2>/dev/null || echo PARSE_ERROR)"
eq "${got}" "${NASTY}" "…and the label round-trips byte-for-byte"
got="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["image"])' "${j}" 2>/dev/null || echo PARSE_ERROR)"
eq "${got}" '/artifacts/we"ird\path.img' "…so does an image PATH with a quote in it"
got="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["role"])' "${j}" 2>/dev/null || echo PARSE_ERROR)"
eq "${got}" 'be"gpu' "…so does the role"

# The empty-value hole json_str was written for: piping "" into sed feeds it
# ZERO lines, `s/^/"/` never fires, and the field lands bare as `"detail": ,`.
j="$(run_emit "rpi5/pki" "/artifacts/plain.img" "")"
if python3 -m json.tool < "${j}" > /dev/null 2>&1; then
    _ok "an EMPTY detail still emits parseable JSON (the sed-escaper's blind spot)"
else
    _bad "empty detail produced unparseable JSON: $(tr '\n' ' ' < "${j}")"
fi

# ══ 4. the FAILED scrape is anchored to the verdict line ════════════════════
echo
echo "emit_assertion_verdict — FAILED comes from the RESULT line, not from anywhere"

VF="${TMP}/verdict.sh"; : > "${VF}"
extract "${ENTRYPOINT}" emit_assertion_verdict "${VF}"
run_verdict() { # run_verdict ARC LOGLINE... -> "STATUS|DETAIL|PASSED|FAILED"
    local arc; arc="$1"; shift
    local rdir; rdir="${TMP}/vrun"; rm -rf "${rdir}"; mkdir -p "${rdir}"
    printf '%s\n' "$@" > "${rdir}/assertions.log"
    ( set -uo pipefail
      RUN_DIR="${rdir}"; LABEL="t/row"; GREEN=""; RST=""; ASSERT_TIMEOUT=900
      ARC="${arc}"; ASSERT_ATTEMPTS=1
      warn() { :; }; info() { :; }
      emit_result() { printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-0}" "${4:-0}"; }
      # shellcheck disable=SC1090
      source "${VF}"
      emit_assertion_verdict )
}

# A REAL golden transcript: `rc-status` prints "0 failed" long before the
# verdict line. The unanchored scrape took that 0 and reported a 12-failure run
# as "FAIL, 0 assertions failed".
got="$(run_verdict 1 \
    ' * status: started' \
    'Dynamic Runlevel: manual — 0 failed' \
    '  FAIL  selinux enforcing' \
    '== RESULT: 21 passed, 12 failed ==')"
eq "${got##*|}" "12" "FAILED is scraped from the RESULT line, not from rc-status's '0 failed'"
eq "$(printf '%s' "${got}" | cut -d'|' -f3)" "21" "control: PASSED still reads 21 from the same line"

# Negative control: a log with NO verdict line must report nothing rather than
# inventing a count from the noise.
got="$(run_verdict 1 'Dynamic Runlevel: manual — 7 failed' 'ssh died')"
eq "${got##*|}" "0" "a log with no RESULT line scrapes 0, not the transcript's '7 failed'"

echo
# ══ HONEST GAPS ═════════════════════════════════════════════════════════════
# Printed, not buried in a comment, because the next person to read a green run
# of this file needs to know what it did NOT prove:
#
#  * ensure_loop_devices is driven against LOOP_DEV_DIR, a directory of ordinary
#    files, with stub docker/losetup. It proves the CONTROL FLOW: early return
#    when the nodes are already there, privileged + -v /dev:/dev, N attaches held
#    SIMULTANEOUSLY, the verdict taken from the node count rather than from
#    docker's exit code, and a loud non-fatal failure. It does NOT prove that a
#    privileged container actually materialises nodes on a real kernel's
#    devtmpfs — and it CANNOT be made to, here: this host already has /dev/loop0
#    and /dev/loop1 (left behind by the very runs that failed), so the real /dev
#    takes the early return. That half was verified by hand ONCE, 2026-08-26 on
#    this workstation: 2 nodes before, `ensure_loop_devices 4`, 4 nodes after
#    (loop2 and loop3 newly created), none left attached. One observation, not a
#    regression test — nothing re-checks it on the next run.
#  * Nothing here boots a guest. That --jobs 2 over rpi5 now passes end to end is
#    NOT established by this file, and cannot be re-established on this box
#    either: the nodes now exist, so the original failure no longer reproduces
#    here. A true end-to-end proof needs a host booted with max_loop=0 and no
#    prior run.
echo "NOTE: ensure_loop_devices is proven only against the LOOP_DEV_DIR seam; the real"
echo "NOTE: privileged attach was verified by hand once (2026-08-26: 2 nodes -> 4), not here."
echo "NOTE: this host already carries loop0+loop1, so the real /dev takes the early return, and"
echo "NOTE: the original --jobs 2 failure can no longer be reproduced on it at all."

printf '%s: %d passed, %d failed\n' "$(basename "$0")" "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
