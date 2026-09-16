#!/usr/bin/env bash
# test-x86-fetchcommand-bound.sh — EXECUTE the x86 spec's bounded distfile fetcher
# (specs-x86/portage/make.conf.tmpl FETCHCOMMAND / RESUMECOMMAND, issue #322)
# against local servers that stall, trickle, 404, ignore Range and honour Range.
#
# WHY THIS EXISTS. On 2026-09-08 the standalone-thick x86 payload sat for over an
# hour at package 3 of 674 with 0.5 % CPU and a log that stopped mid-line: a
# background fetch of media-fonts/noto's 1.02 GB GitHub archive had reached 10.3 %
# and then moved 0 bytes in 22 minutes. Portage's default `wget -t 3 -T 60` never
# aborted it — -T is a READ timeout and fires only when NO byte arrives, and wget
# has no minimum-rate option at all. curl's --speed-limit/--speed-time is one.
#
# EXECUTED, NOT READ. A fetcher string is three layers of quoting deep (make.conf
# parse -> fetch-time ${DISTDIR}/${FILE}/${URI} expansion -> shlex split -> a
# bash -c script with its own quotes), and every layer is a place to get a
# backslash wrong in a way that only shows up as "!!! Couldn't download" hours
# into a build. So this suite renders the template the way the builder does,
# parses it the way portage does (bash's own double-quote rules ARE portage's
# make.conf rules — that contract is what lets make.conf be sourced), expands and
# splits it the way portage/package/ebuild/fetch.py does (varexpand + shlex.split,
# fetch.py:1821-1822), and RUNS the result. Where the real portage python is
# installed (the Gentoo build host) it additionally builds the argv through
# portage's own varexpand/shlex and asserts it is byte-identical to the emulation,
# so the emulation CI runs is proven against the real parser somewhere.
#
# The timing knobs are rewritten for the executed legs (60 s -> 3 s and so on) so
# the suite finishes in seconds; the static legs assert the shipped values, and the
# rewrite is asserted to have actually changed the string, so it cannot no-op.
#
# Legs:
#   static   s1-s7   both commands exist once, are curl, carry a rate floor within a
#                    sane range, name portage's ${DISTDIR}/${FILE} and ${URI}, agree
#                    on their knobs, and RESUMECOMMAND carries the exit-33 fallback
#   dynamic  d1      healthy server: bytes land, identical
#            d2      trickling server (1 byte / 2 s): aborted AND retried, bounded
#            d3      silent server (connects, never answers): bounded
#            d4      404: fails, leaves nothing that could be mistaken for a distfile
#            d5      Range-IGNORING server + partial (GitHub's shape): RESUMECOMMAND
#                    falls back to a fresh fetch, file complete and identical
#            d6      Range-CAPABLE server + partial: RESUMECOMMAND resumes (one
#                    request, Range header sent, only the tail transferred)
#   parity   p1      real portage varexpand+shlex argv == the bash emulation (host
#                    only; a NAMED skip elsewhere, never a silent pass)
#   controls n1-n5   mutate a rendered copy (drop the rate floor / wget / -P instead
#                    of -o / break the exit-33 fallback / a 6000 s window) and
#                    require the static checks to go red on each
#   info     wget    the premise, re-measured on hosts that have GNU wget: the
#                    default fetcher does not abort the same trickle (informational)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
TMPL="${GEN}/specs-x86/portage/make.conf.tmpl"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
info(){ echo "  INFO $*"; }

for t in curl python3 cmp timeout; do
    command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t is not installed — this suite cannot run (it must not pass vacuously)"; exit 2; }
done
[ -f "${TMPL}" ] || { echo "FATAL: ${TMPL} missing"; exit 2; }

TMP="$(mktemp -d)"
SERVER_PIDS=""
cleanup() {
    for p in ${SERVER_PIDS}; do kill "$p" 2>/dev/null || true; done
    rm -rf "${TMP}"
}
trap cleanup EXIT

echo "== x86 distfile fetch bound: ${TMPL#"${GEN}/"} =="

# ── layer 0: render exactly as build-x86-host-stage4.sh's render_template does ──
# (sed over @@TOKENS@@; the fetch lines carry none, so the value is irrelevant)
render() { sed -e 's/@@[A-Z_]*@@/x/g' "$1"; }
render "${TMPL}" > "${TMP}/make.conf"

# ── layer 1: read a variable the way portage reads make.conf (bash quoting rules) ─
get_var() { # <make.conf> <VAR> -> value on stdout
    ( set +u; . "$1" >/dev/null 2>&1; printf '%s' "${!2-}" )
}

# ── static checks, as a function so the negative controls can re-run them ─────
# Prints one finding per line; prints nothing when the file is sound.
static_findings() { # <rendered make.conf>
    local f fetch resume n_f n_r
    f="$1"
    n_f="$(grep -c '^FETCHCOMMAND=' "$f" || true)"
    n_r="$(grep -c '^RESUMECOMMAND=' "$f" || true)"
    [ "${n_f}" = 1 ] || echo "expected exactly one FETCHCOMMAND= line, found ${n_f}"
    [ "${n_r}" = 1 ] || echo "expected exactly one RESUMECOMMAND= line, found ${n_r}"
    fetch="$(get_var "$f" FETCHCOMMAND)"
    resume="$(get_var "$f" RESUMECOMMAND)"
    local cmd name limit window
    for name in FETCHCOMMAND RESUMECOMMAND; do
        if [ "${name}" = FETCHCOMMAND ]; then cmd="${fetch}"; else cmd="${resume}"; fi
        case "${cmd}" in
            *wget*) echo "${name} uses wget — wget has no minimum-rate option, so a trickling transfer is unbounded (the #322 defect)";;
        esac
        case "${cmd}" in
            curl\ *|bash\ -c\ \"curl\ *) ;;
            *) echo "${name} is not a curl command (or a bash -c wrapper around one): '${cmd%% *} ...'";;
        esac
        limit="$(printf '%s\n' "${cmd}" | sed -n 's/.*--speed-limit \([0-9][0-9]*\).*/\1/p' | head -1)"
        window="$(printf '%s\n' "${cmd}" | sed -n 's/.*--speed-time \([0-9][0-9]*\).*/\1/p' | head -1)"
        [ -n "${limit}" ]  || echo "${name} has no --speed-limit — no rate floor, a trickle is unbounded"
        [ -n "${window}" ] || echo "${name} has no --speed-time — no rate window, a trickle is unbounded"
        if [ -n "${limit}" ] && [ "${limit}" -lt 1024 ]; then
            echo "${name} --speed-limit ${limit} is below 1 KiB/s — a floor that low does not bound a stall"
        fi
        if [ -n "${window}" ] && [ "${window}" -gt 300 ]; then
            echo "${name} --speed-time ${window} exceeds 300 s — that is not a bound, that is the defect with a number on it"
        fi
        case "${cmd}" in *--connect-timeout\ [0-9]*) ;; *) echo "${name} has no --connect-timeout";; esac
        # portage substitutes exactly these at fetch time (fetch.py: variables =
        # {URI, FILE, DISTDIR, ...}); -P or a bare ${FILE} makes portage report
        # "created a directory instead of a normal file" or write to the CWD.
        case "${cmd}" in *'${DISTDIR}/${FILE}'*) ;; *) echo "${name} does not write to \${DISTDIR}/\${FILE} — portage's output contract";; esac
        case "${cmd}" in *'${URI}'*) ;; *) echo "${name} does not fetch \${URI}";; esac
    done
    # the two must agree on the bound, or a resume is bounded differently from a fetch
    local fl fw rl rw
    fl="$(printf '%s\n' "${fetch}"  | sed -n 's/.*--speed-limit \([0-9]*\).*/\1/p' | head -1)"
    rl="$(printf '%s\n' "${resume}" | sed -n 's/.*--speed-limit \([0-9]*\).*/\1/p' | head -1)"
    fw="$(printf '%s\n' "${fetch}"  | sed -n 's/.*--speed-time \([0-9]*\).*/\1/p' | head -1)"
    rw="$(printf '%s\n' "${resume}" | sed -n 's/.*--speed-time \([0-9]*\).*/\1/p' | head -1)"
    [ "${fl}" = "${rl}" ] && [ "${fw}" = "${rw}" ] || echo "FETCHCOMMAND (${fl}/${fw}) and RESUMECOMMAND (${rl}/${rw}) disagree on the rate bound"
    # the resume must be a real resume AND survive a Range-ignoring host
    case "${resume}" in *'-C -'*) ;; *) echo "RESUMECOMMAND has no -C - — it never resumes";; esac
    case "${resume}" in *'-eq 33'*) ;; *) echo "RESUMECOMMAND has no exit-33 fallback — against a Range-ignoring host (GitHub archives) curl exits 33 without downloading and the partial never completes";; esac
}

echo "-- static --"
findings="$(static_findings "${TMP}/make.conf")"
if [ -z "${findings}" ]; then
    ok "s1-s7: one FETCHCOMMAND + one RESUMECOMMAND, both curl, rate floor >= 1 KiB/s within <= 300 s, --connect-timeout, \${DISTDIR}/\${FILE} + \${URI}, knobs agree, resume has -C - and the exit-33 fallback"
else
    while IFS= read -r line; do bad "static: ${line}"; done <<< "${findings}"
fi

FETCH="$(get_var "${TMP}/make.conf" FETCHCOMMAND)"
RESUME="$(get_var "${TMP}/make.conf" RESUMECOMMAND)"

# ── the executed legs run with the knobs shrunk; the shrink must actually bite ──
fast_knobs() {
    sed -e 's/--speed-time 60/--speed-time 3/g' \
        -e 's/--retry-delay 15/--retry-delay 1/g' \
        -e 's/--retry 3 /--retry 1 /g' \
        -e 's/--connect-timeout 30/--connect-timeout 5/g'
}
FETCH_FAST="$(printf '%s' "${FETCH}" | fast_knobs)"
RESUME_FAST="$(printf '%s' "${RESUME}" | fast_knobs)"
if [ "${FETCH_FAST}" != "${FETCH}" ] && [ "${RESUME_FAST}" != "${RESUME}" ] \
   && [ "$(printf '%s' "${FETCH_FAST}" | grep -o -- '--speed-time 3' | wc -l)" -ge 1 ] \
   && [ "$(printf '%s' "${RESUME_FAST}" | grep -o -- '--speed-time 3' | wc -l)" -ge 2 ]; then
    ok "knob shrink for the executed legs applied (60 s window -> 3 s, retry 3 -> 1, delay 15 -> 1)"
else
    bad "knob shrink did not apply — the shipped knob spellings changed; the executed legs below would run at full duration or not at all"
fi

# ── layer 2: expand + split the way fetch.py does, then run ──────────────────
# portage: shlex.split(varexpand(cmd, {URI, FILE, DISTDIR})). In bash, eval of
# the same string inside an array literal performs the identical expansion and
# word split (double-quote rules; \" -> ", \$ -> $, ${VAR} expanded).
build_argv() { # <cmdstring>; DISTDIR FILE URI exported -> ARGV[]
    ARGV=()
    eval "ARGV=( $1 )"
}
run_fetch() { # <cmdstring> <DISTDIR> <FILE> <URI> -> rc; sets ELAPSED
    local start
    export DISTDIR="$2" FILE="$3" URI="$4"
    build_argv "$1"
    start=$(date +%s)
    "${ARGV[@]}" >"${TMP}/run.out" 2>&1
    local rc=$?
    ELAPSED=$(( $(date +%s) - start ))
    return "${rc}"
}

# ── fixture servers ──────────────────────────────────────────────────────────
cat > "${TMP}/srv.py" <<'PY'
import http.server, socketserver, sys, time, re
MODE, LOG = sys.argv[1], sys.argv[2]
BODY = bytes(range(256)) * 64            # 16 KiB, every byte value, incompressible-ish
def log(line):
    with open(LOG, "a") as fh: fh.write(line + "\n")
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        rng = self.headers.get("Range", "-")
        if MODE == "ok" or MODE == "norange":       # norange: a Range request gets 200 + the whole body (GitHub archives)
            self.send_response(200); self.send_header("Content-Length", str(len(BODY))); self.end_headers()
            self.wfile.write(BODY); log(f"GET {self.path} RANGE={rng} SENT={len(BODY)} STATUS=200")
        elif MODE == "range":
            m = re.match(r"bytes=(\d+)-$", rng)
            if m:
                start = int(m.group(1)); tail = BODY[start:]
                self.send_response(206); self.send_header("Content-Range", f"bytes {start}-{len(BODY)-1}/{len(BODY)}")
                self.send_header("Content-Length", str(len(tail))); self.end_headers(); self.wfile.write(tail)
                log(f"GET {self.path} RANGE={rng} SENT={len(tail)} STATUS=206")
            else:
                self.send_response(200); self.send_header("Content-Length", str(len(BODY))); self.end_headers()
                self.wfile.write(BODY); log(f"GET {self.path} RANGE={rng} SENT={len(BODY)} STATUS=200")
        elif MODE == "trickle":                     # data IS arriving, so a read timeout never fires
            log(f"GET {self.path} RANGE={rng} TRICKLE")
            self.send_response(200); self.send_header("Content-Length", "1000000"); self.end_headers()
            try:
                while True:
                    self.wfile.write(b"x"); self.wfile.flush(); time.sleep(2)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif MODE == "silent":                      # connected, headers never come (0 bytes for 22 minutes)
            log(f"GET {self.path} RANGE={rng} SILENT")
            try: time.sleep(3600)
            except Exception: pass
        elif MODE == "notfound":
            body = b"<html><title>404 Not Found</title></html>"
            self.send_response(404); self.send_header("Content-Length", str(len(body))); self.end_headers()
            self.wfile.write(body); log(f"GET {self.path} RANGE={rng} STATUS=404")
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True; allow_reuse_address = True
srv = S(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
python3 -c 'import sys; sys.exit(0)' || { echo "FATAL: python3 unusable"; exit 2; }
# the body the servers serve, for byte comparison
python3 -c 'import sys; sys.stdout.buffer.write(bytes(range(256))*64)' > "${TMP}/body.bin"

start_server() { # <mode> -> PORT on stdout; appends pid to SERVER_PIDS
    local mode="$1" log="${TMP}/log.$1" fifo
    : > "${log}"
    python3 "${TMP}/srv.py" "${mode}" "${log}" > "${TMP}/port.${mode}" 2>"${TMP}/srv.${mode}.err" &
    SERVER_PIDS="${SERVER_PIDS} $!"
    local i=0
    while [ ! -s "${TMP}/port.${mode}" ] && [ "${i}" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
    [ -s "${TMP}/port.${mode}" ] || { echo "FATAL: fixture server (${mode}) did not start: $(cat "${TMP}/srv.${mode}.err")"; exit 2; }
    cat "${TMP}/port.${mode}"
}
P_OK="$(start_server ok)"; P_TRICKLE="$(start_server trickle)"; P_SILENT="$(start_server silent)"
P_NORANGE="$(start_server norange)"; P_RANGE="$(start_server range)"; P_404="$(start_server notfound)"

echo "-- dynamic --"
DD="${TMP}/distdir"; mkdir -p "${DD}"

# (d1) healthy
if run_fetch "${FETCH_FAST}" "${DD}" "ok.tar" "http://127.0.0.1:${P_OK}/ok.tar" && cmp -s "${DD}/ok.tar" "${TMP}/body.bin"; then
    ok "d1: FETCHCOMMAND against a healthy server lands the file at \${DISTDIR}/\${FILE}, byte-identical (${ELAPSED}s)"
else
    bad "d1: healthy fetch failed or bytes differ: $(head -c 300 "${TMP}/run.out" | tr '\n' ' ')"
fi

# (d2) trickle: the defect. Must abort (curl 28), must have RETRIED (2 requests
# logged: --retry treats the speed-limit abort as transient), must stay bounded.
if run_fetch "${FETCH_FAST}" "${DD}" "trickle.tar" "http://127.0.0.1:${P_TRICKLE}/trickle.tar"; then
    bad "d2: FETCHCOMMAND returned 0 against a server that trickles 1 byte / 2 s"
else
    rc=$?
    reqs="$(grep -c TRICKLE "${TMP}/log.trickle" || true)"
    if [ "${ELAPSED}" -le 25 ] && [ "${reqs}" -ge 2 ]; then
        ok "d2: a 1-byte/2-s trickle is ABORTED (rc=${rc}) and RETRIED (${reqs} requests) inside ${ELAPSED}s — bounded, where wget -T never fires"
    else
        bad "d2: trickle abort took ${ELAPSED}s with ${reqs} request(s) (rc=${rc}) — expected <= 25s and >= 2 requests: $(head -c 200 "${TMP}/run.out" | tr '\n' ' ')"
    fi
fi

# (d3) silent: connected, no headers ever (the 0-bytes-for-22-minutes shape)
if run_fetch "${FETCH_FAST}" "${DD}" "silent.tar" "http://127.0.0.1:${P_SILENT}/silent.tar"; then
    bad "d3: FETCHCOMMAND returned 0 against a server that never answers"
else
    rc=$?
    if [ "${ELAPSED}" -le 25 ]; then
        ok "d3: a connected-but-silent server is abandoned in ${ELAPSED}s (rc=${rc}) — bounded"
    else
        bad "d3: silent server held the fetch for ${ELAPSED}s (rc=${rc})"
    fi
fi

# (d4) 404: must fail and must not leave an HTML body wearing the distfile name
run_fetch "${FETCH_FAST}" "${DD}" "missing.tar" "http://127.0.0.1:${P_404}/missing.tar"
rc=$?
if [ "${rc}" -ne 0 ] && { [ ! -e "${DD}/missing.tar" ] || [ ! -s "${DD}/missing.tar" ]; }; then
    ok "d4: a 404 fails (rc=${rc}) and leaves no non-empty file under the distfile name"
else
    bad "d4: 404 handling — rc=${rc}, file: $(ls -la "${DD}/missing.tar" 2>&1 | tr '\n' ' ')"
fi

# (d5) Range-IGNORING host + partial (GitHub's archive endpoint). A plain curl -C -
# exits 33 here and downloads nothing; the wrapper must fall back to a fresh fetch.
head -c 4096 "${TMP}/body.bin" > "${DD}/norange.tar"
if run_fetch "${RESUME_FAST}" "${DD}" "norange.tar" "http://127.0.0.1:${P_NORANGE}/norange.tar" && cmp -s "${DD}/norange.tar" "${TMP}/body.bin"; then
    reqs="$(grep -c '^GET' "${TMP}/log.norange" || true)"
    ranged="$(grep -c 'RANGE=bytes=4096-' "${TMP}/log.norange" || true)"
    if [ "${reqs}" -eq 2 ] && [ "${ranged}" -eq 1 ]; then
        ok "d5: RESUMECOMMAND against a Range-ignoring host: resume attempted (Range: bytes=4096-), exit 33 caught, fresh fetch completed the file byte-identical (2 requests)"
    else
        bad "d5: file completed but the request pattern is not resume-then-fallback: ${reqs} request(s), ${ranged} ranged: $(cat "${TMP}/log.norange" | tr '\n' '|')"
    fi
else
    bad "d5: RESUMECOMMAND against a Range-ignoring host did not complete the file: $(head -c 300 "${TMP}/run.out" | tr '\n' ' ') log=$(cat "${TMP}/log.norange" | tr '\n' '|')"
fi

# (d6) Range-CAPABLE host + partial: a real resume — ONE request, Range sent,
# only the tail transferred, file identical.
head -c 4096 "${TMP}/body.bin" > "${DD}/range.tar"
if run_fetch "${RESUME_FAST}" "${DD}" "range.tar" "http://127.0.0.1:${P_RANGE}/range.tar" && cmp -s "${DD}/range.tar" "${TMP}/body.bin"; then
    reqs="$(grep -c '^GET' "${TMP}/log.range" || true)"
    if [ "${reqs}" -eq 1 ] && grep 'RANGE=bytes=4096- SENT=12288 STATUS=206' "${TMP}/log.range" >/dev/null; then
        ok "d6: RESUMECOMMAND against a Range-capable host resumes: one request, Range: bytes=4096-, 12288-byte tail (206), file byte-identical"
    else
        bad "d6: file completed but not by resuming: $(cat "${TMP}/log.range" | tr '\n' '|')"
    fi
else
    bad "d6: RESUMECOMMAND against a Range-capable host failed: $(head -c 300 "${TMP}/run.out" | tr '\n' ' ')"
fi

# ── parity with the REAL portage parser, where it exists ─────────────────────
echo "-- parity --"
if python3 -c 'import portage' 2>/dev/null; then
    export DISTDIR="${DD}" FILE="parity.tar" URI="http://127.0.0.1:${P_OK}/parity.tar"
    MAKE_CONF="${TMP}/make.conf" python3 - > "${TMP}/portage.argv" <<'PY'
import os, shlex, sys
from portage.util import getconfig, varexpand
cfg = getconfig(os.environ["MAKE_CONF"], tolerant=True, expand=True)
variables = {"URI": os.environ["URI"], "FILE": os.environ["FILE"], "DISTDIR": os.environ["DISTDIR"]}
for k in ("FETCHCOMMAND", "RESUMECOMMAND"):
    argv = shlex.split(varexpand(cfg[k], mydict=variables))     # fetch.py:1821-1822 verbatim
    for a in argv: sys.stdout.write(a + "\0")
    sys.stdout.write("\0")
PY
    {
        build_argv "${FETCH}";  for a in "${ARGV[@]}"; do printf '%s\0' "$a"; done; printf '\0'
        build_argv "${RESUME}"; for a in "${ARGV[@]}"; do printf '%s\0' "$a"; done; printf '\0'
    } > "${TMP}/bash.argv"
    if cmp -s "${TMP}/portage.argv" "${TMP}/bash.argv"; then
        ok "p1: portage's own varexpand+shlex.split argv (portage $(python3 -c 'import portage; print(portage.VERSION)')) is byte-identical to the bash emulation, for both commands"
    else
        bad "p1: argv from portage's parser differs from the bash emulation — the executed legs above tested the wrong command: $(tr '\0' '|' < "${TMP}/portage.argv" | head -c 400) VS $(tr '\0' '|' < "${TMP}/bash.argv" | head -c 400)"
    fi
    # and run the healthy fetch through portage's argv, not only the emulation's
    mapfile -d '' PARGV < <(MAKE_CONF="${TMP}/make.conf" python3 - <<'PY'
import os, shlex, sys
from portage.util import getconfig, varexpand
cfg = getconfig(os.environ["MAKE_CONF"], tolerant=True, expand=True)
v = {"URI": os.environ["URI"], "FILE": os.environ["FILE"], "DISTDIR": os.environ["DISTDIR"]}
for a in shlex.split(varexpand(cfg["FETCHCOMMAND"], mydict=v)): sys.stdout.write(a + "\0")
PY
    )
    if [ "${#PARGV[@]}" -gt 0 ] && "${PARGV[@]}" >/dev/null 2>&1 && cmp -s "${DD}/parity.tar" "${TMP}/body.bin"; then
        ok "p2: the argv portage would spawn fetches a healthy file byte-identical"
    else
        bad "p2: portage-derived argv (${#PARGV[@]} words) did not fetch: ${PARGV[*]:0:3} ..."
    fi
else
    info "p1/p2 SKIPPED: no portage python on this box — the bash emulation is the only executed parser here (it is proven identical to portage's on the Gentoo build host)"
fi

# ── negative controls: the static checks must bite ───────────────────────────
echo "-- negative controls --"
mutate() { # <name> <sed-expr...> -> path of the mutated rendered copy; asserts it changed
    local name="$1"; shift
    sed "$@" "${TMP}/make.conf" > "${TMP}/mut.${name}"
    if cmp -s "${TMP}/make.conf" "${TMP}/mut.${name}"; then
        echo "MUTATION_NOOP"
    else
        echo "${TMP}/mut.${name}"
    fi
}
control() { # <label> <mutated-path> <expected-substring>
    local label="$1" path="$2" want="$3" out
    if [ "${path}" = MUTATION_NOOP ]; then bad "${label}: the mutation did not change the file — the control proves nothing"; return; fi
    out="$(static_findings "${path}")"
    if printf '%s\n' "${out}" | grep -F -- "${want}" >/dev/null; then
        ok "${label}: caught — '$(printf '%s\n' "${out}" | grep -F -- "${want}" | head -1 | cut -c1-90)'"
    else
        bad "${label}: NOT caught (expected a finding containing '${want}'): $(printf '%s' "${out}" | tr '\n' '|' | cut -c1-200)"
    fi
}
control "n1: rate floor dropped from FETCHCOMMAND" \
    "$(mutate n1 -e '/^FETCHCOMMAND=/s/--speed-limit 10240 //')" "no --speed-limit"
control "n2: FETCHCOMMAND back to wget" \
    "$(mutate n2 -e 's/^FETCHCOMMAND="curl /FETCHCOMMAND="wget /')" "uses wget"
control "n3: -P DISTDIR instead of -o DISTDIR/FILE (portage's 'created a directory' class)" \
    "$(mutate n3 -e '/^FETCHCOMMAND=/s|-o \\"\\${DISTDIR}/\\${FILE}\\"|-P \\"\\${DISTDIR}\\"|')" 'does not write to ${DISTDIR}/${FILE}'
control "n4: exit-33 fallback broken in RESUMECOMMAND" \
    "$(mutate n4 -e '/^RESUMECOMMAND=/s/-eq 33/-eq 99/')" "exit-33 fallback"
control "n5: a 6000 s window is not a bound" \
    "$(mutate n5 -e 's/--speed-time 60/--speed-time 6000/g')" "exceeds 300 s"

# ── the premise, re-measured where GNU wget exists (informational) ───────────
if wget --version 2>/dev/null | head -1 | grep GNU >/dev/null; then
    start=$(date +%s)
    timeout 8 wget -q -t 1 -T 3 --read-timeout=3 -O "${TMP}/wget.bin" "http://127.0.0.1:${P_TRICKLE}/wget.tar" 2>/dev/null
    rc=$?
    info "premise: GNU wget -T 3 --read-timeout=3 against the same trickle: rc=${rc} after $(( $(date +%s) - start ))s (124 = still running when killed from outside: the read timeout does not bound a trickle)"
fi

echo
echo "== x86 fetch bound: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
