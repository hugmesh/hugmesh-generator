#!/usr/bin/env bash
# golive_emulated_test.sh — HERMETIC tests for tests/qemu/golive-emulated.sh, the
# go-live-on-an-emulated-device proof lane.
#
#   bash tests/qemu/golive_emulated_test.sh
#
# Boots nothing, starts no container, opens no network connection. `ssh` is a shim on
# PATH that records its argv and plays the guest: it runs the remote command with
# bash against a throwaway guest root, where `hugmesh-go-live` is the REAL
# specs/usr/sbin/hugmesh-go-live (its GL_ETC_HUGMESH seam pointed at that root),
# `sudo` strips -n, and `nft` reports the reconcile-owned table from the go-live
# marker the way hugmesh-firewall-reconcile would render it. Without -tt the shim
# gives the remote command NO terminal (stdin /dev/null when ours is a tty), the way
# real ssh does, so the driver's confirmation gate can only be satisfied by a 'y'
# typed on the pty the lane drives — which is the property this file exists to keep.
#
# WHAT IT PINS:
#   * the argv shapes: every destination is <user>@127.0.0.1 on the record's port and
#     key; the plan carries --domain example.invalid --ingress-ip 203.0.113.10
#     --out-dir /var/lib/hugmesh/go-live/out; commit and rollback ride `ssh -tt`;
#   * NO -y / --yes, NO GL_ASSUME_YES and NO token anywhere on any argv;
#   * every refusal happens BEFORE any ssh (record missing, not running, port 0, no
#     key, real domain, slirp/mesh-L2/non-documentation ingress address) or right
#     after the read-only probe (no driver, already public, stale container);
#   * a commit that never converges fails AND is rolled back;
#   * a rollback that never converges fails, writes no verdict, and prints the manual
#     rollback command (round 2, refuter M8);
#   * an absent, truncated or empty nft table is "unknown", never "public" — including
#     real nft's own absent-table error, which echoes "list table inet <name>" on
#     stderr (round 2, refuter M9; the round-1 lane read that echo as public);
#   * status and nft must BOTH say the posture: nft alone is not enough (round 2, M3);
#   * a driver that would accept an onion commit fails the lane, with 'n' typed.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
LANE="${GOLIVE_LANE:-${HERE}/golive-emulated.sh}"
DRIVER="${REPO}/specs/usr/sbin/hugmesh-go-live"
LIB="${REPO}/specs/usr/lib/hugmesh/go-live-providers.sh"
for f in "${LANE}" "${DRIVER}" "${LIB}"; do
    [ -f "${f}" ] || { echo "cannot find ${f}" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (got '$1', want '$2')"; fi; }
has() { case "$1" in *"$2"*) _ok "$3" ;; *) _bad "$3 (missing '$2')" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# ── The fake guest: bin dir that the shim's remote bash runs with ───────────────────
FAKEBIN="${TMP}/guestbin"; mkdir -p "${FAKEBIN}"
cat > "${FAKEBIN}/sudo" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "-n" ] || echo "sudo-without-n" >> "${FAKE_LOG_DIR}/notes"
[ "${1:-}" = "-n" ] && shift
exec "$@"
SH
cat > "${FAKEBIN}/hugmesh-go-live" <<'SH'
#!/usr/bin/env bash
exec env GL_ETC_HUGMESH="${FAKE_GUEST}/etc/hugmesh" GL_PROVIDERS_LIB="${FAKE_LIB}" \
    GL_ONION_EXPORT_DIR="${FAKE_GUEST}/var/lib/hugmesh/tor" \
    GL_OUT_DIR="${FAKE_GUEST}/var/lib/hugmesh/go-live/out" \
    bash "${FAKE_DRIVER}" "$@"
SH
cat > "${FAKEBIN}/hugmesh-firewall-reconcile" <<'SH'
#!/usr/bin/env bash
exit 0
SH
# nft: the table hugmesh-firewall-reconcile renders, from the marker. FAKE_NFT_STUCK=1
# never converges (a dead cron); FAKE_NFT_LAG=N keeps answering the OLD posture for N
# reads after it changes, so the lane really has to poll. FAKE_NFT_STICKY_PUBLIC=1 goes
# public and never comes back (a rollback the reconcile never acts on).
# FAKE_NFT_ABSENT_WHEN_PUBLIC=1: while the marker is down the table is GONE, and this
# answers exactly what real nft (1.x) does for an absent table — exit 1, and the
# failed command echoed on stderr, which itself contains "table inet <name>":
#     Error: No such file or directory
#     list table inet hugmesh_release_gate
#                     ^^^^^^^^^^^^^^^^^^^^
# FAKE_NFT_TRUNCATED_WHEN_PUBLIC=1: the listing stops after the header and nft exits 1.
# FAKE_NFT_EMPTY_WHEN_PUBLIC=1: nft exits 0 and prints nothing (no table header at all).
cat > "${FAKEBIN}/nft" <<'SH'
#!/usr/bin/env bash
[ "$*" = "list table inet hugmesh_release_gate" ] || { echo "fake nft: unexpected '$*'" >&2; exit 1; }
etc="${FAKE_GUEST}/etc/hugmesh"
want=internal
{ [ -e "${etc}/go-live" ] || [ "$(cat "${etc}/release-state" 2>/dev/null)" = public ]; } && want=public
[ "${FAKE_NFT_STUCK:-0}" = 1 ] && want=internal
if [ "${want}" = public ] && [ "${FAKE_NFT_ABSENT_WHEN_PUBLIC:-0}" = 1 ]; then
    echo "Error: No such file or directory" >&2
    echo "list table inet hugmesh_release_gate" >&2
    echo "                ^^^^^^^^^^^^^^^^^^^^" >&2
    exit 1
fi
if [ "${want}" = public ] && [ "${FAKE_NFT_TRUNCATED_WHEN_PUBLIC:-0}" = 1 ]; then
    echo "table inet hugmesh_release_gate {"
    echo "	chain input {"
    echo "nft: listing interrupted" >&2
    exit 1
fi
if [ "${want}" = public ] && [ "${FAKE_NFT_EMPTY_WHEN_PUBLIC:-0}" = 1 ]; then
    exit 0
fi
state="${FAKE_LOG_DIR}/nft.state"
read -r shown reads < "${state}" 2>/dev/null || { shown=internal; reads=0; }
[ "${FAKE_NFT_STICKY_PUBLIC:-0}" = 1 ] && [ "${shown}" = public ] && want=public
if [ "${want}" != "${shown}" ]; then
    reads=$((reads + 1))
    [ "${reads}" -gt "${FAKE_NFT_LAG:-0}" ] && { shown="${want}"; reads=0; }
fi
echo "${shown} ${reads}" > "${state}"
echo "table inet hugmesh_release_gate {"
echo "	chain input {"
echo "		type filter hook input priority filter + 10; policy accept;"
echo "		ip saddr 100.64.0.0/10 tcp dport { 80, 443 } accept"
echo "		iifname \"lo\" accept"
[ "${shown}" = internal ] && echo "		tcp dport { 80, 443 } drop"
echo "	}"
echo "}"
SH
chmod +x "${FAKEBIN}"/*

# ── The ssh shim ───────────────────────────────────────────────────────────────────
SHIMBIN="${TMP}/shimbin"; mkdir -p "${SHIMBIN}"
cat > "${SHIMBIN}/ssh" <<'SH'
#!/usr/bin/env bash
# One record per call: argv joined by US (0x1f), one call per line.
n=$(( $(cat "${FAKE_LOG_DIR}/count" 2>/dev/null || echo 0) + 1 ))
echo "${n}" > "${FAKE_LOG_DIR}/count"
( IFS=$'\x1f'; printf '%s\n' "$*" ) >> "${FAKE_LOG_DIR}/ssh.argv"
[ "${FAKE_SSH_DOWN:-0}" = 1 ] && { echo "ssh: connect to host 127.0.0.1 port 22399: Connection refused" >&2; exit 255; }
tty=0
while [ $# -gt 0 ]; do
    case "$1" in
        -tt|-t) tty=1; shift ;;
        -i|-p|-o|-l|-F) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
dest="$1"; shift
cmd="$*"
# Point the guest's absolute paths at the throwaway guest root.
cmd="${cmd//\/var\/lib\/hugmesh\//${FAKE_GUEST}/var/lib/hugmesh/}"
cmd="${cmd//\/etc\/hugmesh/${FAKE_GUEST}/etc/hugmesh}"
export PATH="${FAKE_BIN}:/usr/local/bin:/usr/bin:/bin"
if [ "${tty}" = 1 ]; then
    # -tt: the remote command gets a terminal. It can only be OUR stdin; if that is
    # not a tty the lane did not drive a pty, and the driver must see no terminal.
    [ -t 0 ] || echo "tt-without-local-pty" >> "${FAKE_LOG_DIR}/notes"
    exec bash -c "${cmd}"
fi
if [ -t 0 ]; then exec bash -c "${cmd}" </dev/null; fi
exec bash -c "${cmd}"
SH
chmod +x "${SHIMBIN}/ssh"
# docker: answers `docker ps` with the container unless FAKE_DOCKER_STALE=1.
cat > "${SHIMBIN}/docker" <<'SH'
#!/usr/bin/env bash
[ "$1" = ps ] || exit 1
[ "${FAKE_DOCKER_STALE:-0}" = 1 ] && exit 0
echo "hugmesh-qemu-dev-rpi5_pki"
SH
chmod +x "${SHIMBIN}/docker"

for d in /usr/local/bin /usr/bin /bin; do
    [ -x "${d}/hugmesh-go-live" ] && { echo "a real hugmesh-go-live is installed at ${d}; this test cannot fake its absence" >&2; exit 2; }
done

# ── Fixture: a work dir with one record, a guest root, a key ───────────────────────
# new_case NAME [record-json-overrides as python dict literal]
new_case() {
    CASE="${TMP}/case-$1"; rm -rf "${CASE}"
    mkdir -p "${CASE}/work/devices" "${CASE}/guest/etc/hugmesh" "${CASE}/guest/var/lib/hugmesh/tor" "${CASE}/log"
    echo internal > "${CASE}/guest/etc/hugmesh/release-state"
    echo "mesh.example" > "${CASE}/guest/etc/hugmesh/cluster-domain"
    : > "${CASE}/key"; chmod 600 "${CASE}/key"
    python3 - "${CASE}/work/devices/rpi5_pki.json" "${CASE}/key" "${2:-{\}}" <<'PY'
import ast, json, sys
rec = {"label": "rpi5/pki", "state": "running", "ssh_host_port": 22399,
       "ssh_user": "tester", "ssh_key": sys.argv[2],
       "container": "hugmesh-qemu-dev-rpi5_pki", "started_at": "2026-11-09T10:00:00Z"}
rec.update(ast.literal_eval(sys.argv[3]))
json.dump(rec, open(sys.argv[1], "w"))
PY
}

# run_lane [lane args…] — runs the lane under the shims; sets RC and OUT.
run_lane() {
    OUT="$(env PATH="${SHIMBIN}:${PATH}" FAKE_LOG_DIR="${CASE}/log" FAKE_GUEST="${CASE}/guest" \
        FAKE_BIN="${FAKEBIN}" FAKE_LIB="${LIB}" FAKE_DRIVER="${FAKE_DRIVER_PATH:-${DRIVER}}" \
        bash "${LANE}" --work "${CASE}/work" --label rpi5/pki --timeout 6 --poll 1 \
        --evidence "${CASE}/evidence" "$@" </dev/null 2>&1)"
    RC=$?
}
ssh_calls() { cat "${CASE}/log/count" 2>/dev/null || echo 0; }
# calls matching a substring (argv joined with US)
calls_with() { grep -F -- "$1" "${CASE}/log/ssh.argv" 2>/dev/null | wc -l | tr -d ' '; }

# ── Happy path ─────────────────────────────────────────────────────────────────────
echo "happy path — plan, onion refused, commit on the pty, public, rollback, internal"
new_case happy
FAKE_NFT_LAG=2 run_lane
[ "${GOLIVE_TEST_VERBOSE:-0}" = 1 ] && printf '%s\n' "${OUT}" | sed 's/^/  | /'
eq "${RC}" 0 "lane exits 0"
has "${OUT}" "PASS: rpi5/pki planned" "lane prints its PASS line"
US=$'\x1f'
KEY="${CASE}/key"
bad_dest=0; bad_key=0
while IFS= read -r line; do
    case "${line}" in *"${US}tester@127.0.0.1${US}"*) ;; *) bad_dest=$((bad_dest+1)) ;; esac
    case "${line}" in *"-i${US}${KEY}${US}-p${US}22399${US}"*) ;; *) bad_key=$((bad_key+1)) ;; esac
done < "${CASE}/log/ssh.argv"
eq "${bad_dest}" 0 "every ssh destination is tester@127.0.0.1 (no other host, ever)"
eq "${bad_key}" 0 "every ssh uses the record's key and port"
eq "$(grep -Eic -- "(^|${US})(-y|--yes)(${US}|\$)| -y( |\$)| --yes( |\$)|GL_ASSUME_YES|token" "${CASE}/log/ssh.argv")" 0 \
   "no -y/--yes, no GL_ASSUME_YES and no token on any argv"
eq "$(calls_with "${US}sudo -n hugmesh-go-live plan --provider byo-domain --domain example.invalid --ingress-ip 203.0.113.10 --out-dir /var/lib/hugmesh/go-live/out")" 1 \
   "byo-domain plan argv shape (domain, documentation ingress, out-dir)"
eq "$(calls_with "${US}sudo -n hugmesh-go-live plan --provider tor-onion --out-dir /var/lib/hugmesh/go-live/out")" 1 \
   "tor-onion plan argv shape"
eq "$(grep -c -- "^-tt${US}.*${US}sudo -n hugmesh-go-live commit --provider byo-domain --domain example.invalid\$" "${CASE}/log/ssh.argv")" 1 \
   "byo-domain commit rides ssh -tt with no -y"
eq "$(grep -c -- "^-tt${US}.*${US}sudo -n hugmesh-go-live commit --provider tor-onion\$" "${CASE}/log/ssh.argv")" 1 \
   "tor-onion commit is attempted on a pty (so the refusal is the driver's, not the TTY gate's)"
eq "$(grep -c -- "^-tt${US}.*${US}sudo -n hugmesh-go-live rollback\$" "${CASE}/log/ssh.argv")" 1 \
   "rollback rides ssh -tt"
eq "$(grep -c -- "commit\|rollback" "${CASE}/log/ssh.argv" | tr -d ' ')" "$(grep -c -- "^-tt${US}" "${CASE}/log/ssh.argv" | tr -d ' ')" \
   "every commit/rollback call, and only those, uses -tt"
eq "$(cat "${CASE}/log/notes" 2>/dev/null)" "" "no -tt without a local pty, no sudo without -n"
has "${OUT}" "Proceed and trip go-live? [y/N]" "the driver's own commit prompt was shown on the pty"
has "${OUT}" "A Tor address needs no public flip" "the onion refusal came from the driver"
has "${OUT}" "GO LIVE tripped" "the commit wrote the marker"
has "${OUT}" "posture after" "the lane polled"
has "${OUT}" "status=public nft=public" "both witnesses reached public"
eq "$([ -e "${CASE}/guest/etc/hugmesh/go-live" ] && echo present || echo absent)" absent "the marker is gone after rollback"
eq "$(cat "${CASE}/guest/etc/hugmesh/release-state")" internal "release-state was never persisted public"
for f in example.invalid.zone records.csv records.txt; do
    eq "$([ -s "${CASE}/guest/var/lib/hugmesh/go-live/out/${f}" ] && echo yes)" yes "guest has ${f}"
done
has "$(cat "${CASE}/evidence/example.invalid.zone" 2>/dev/null)" "203.0.113.10" "evidence: the zone was copied back and carries the documentation address"
has "$(cat "${CASE}/evidence/verdict.txt" 2>/dev/null)" "verdict=PASS" "evidence: verdict.txt"

# ── Refusals before any ssh ────────────────────────────────────────────────────────
echo "refusals before any ssh"
refused_before_ssh() { # NAME OVERRIDES EXPECTED_TEXT [lane args…]
    local name="$1" ov="$2" want="$3"; shift 3
    new_case "${name}" "${ov}"
    run_lane "$@"
    eq "${RC}" 2 "${name}: exit 2"
    has "${OUT}" "${want}" "${name}: says why"
    eq "$(ssh_calls)" 0 "${name}: no ssh at all"
}
refused_before_ssh stopped     "{'state': 'stopped'}"        "is not running"
refused_before_ssh assertions  "{'state': 'assertions'}"     "is not running"
refused_before_ssh noport      "{'ssh_host_port': 0}"        "no ssh port"
refused_before_ssh nokey       "{'ssh_key': '/nonexistent/id'}" "no readable ssh key"
refused_before_ssh realdomain  "{}" "is a real name" --domain hugmesh.net
refused_before_ssh baddomain   "{}" "is not a DNS name" --domain 'x;reboot.invalid'
refused_before_ssh slirp       "{}" "QEMU's slirp network" --ingress-ip 10.0.2.15
refused_before_ssh meshl2      "{}" "emulated mesh L2" --ingress-ip 10.77.0.5
refused_before_ssh realip      "{}" "not an RFC 5737 documentation address" --ingress-ip 8.8.8.8
refused_before_ssh octet       "{}" "octet above 255" --ingress-ip 203.0.113.999
new_case norecord; rm -f "${CASE}/work/devices/rpi5_pki.json"; run_lane
eq "${RC}" 2 "no record: exit 2"; has "${OUT}" "boots nothing" "no record: says it boots nothing"
eq "$(ssh_calls)" 0 "no record: no ssh at all"
new_case stale; FAKE_DOCKER_STALE=1 run_lane
eq "${RC}" 2 "stale container: exit 2"; has "${OUT}" "stale record" "stale container: says so"
eq "$(ssh_calls)" 0 "stale container: no ssh at all"

# ── Refusals after the read-only probe ─────────────────────────────────────────────
echo "refusals after the read-only probe"
new_case nodriver; FAKE_DRIVER_PATH=/nonexistent; mv "${FAKEBIN}/hugmesh-go-live" "${TMP}/hgl.off"
run_lane; mv "${TMP}/hgl.off" "${FAKEBIN}/hugmesh-go-live"; unset FAKE_DRIVER_PATH
eq "${RC}" 2 "no driver: exit 2"
has "${OUT}" "not a go-live server node" "no driver: the B8 sentence"
eq "$(calls_with "hugmesh-go-live plan")$(calls_with "hugmesh-go-live commit")" 00 "no driver: no plan, no commit"
new_case public; : > "${CASE}/guest/etc/hugmesh/go-live"; echo "public 0" > "${CASE}/log/nft.state"
run_lane
eq "${RC}" 2 "already public: exit 2"; has "${OUT}" "does not start INTERNAL" "already public: says so"
eq "$(calls_with "hugmesh-go-live commit")$(calls_with "hugmesh-go-live rollback")" 00 "already public: never commits or rolls back"
new_case down; FAKE_SSH_DOWN=1 run_lane
eq "${RC}" 2 "ssh down: exit 2"; has "${OUT}" "Connection refused" "ssh down: shows ssh's error"

# ── Failures after the commit: rolled back ─────────────────────────────────────────
echo "a commit that never converges fails and is rolled back"
new_case stuck; FAKE_NFT_STUCK=1 run_lane
eq "${RC}" 1 "stuck reconcile: exit 1"
has "${OUT}" "did not go public within 6s" "stuck reconcile: says it timed out"
has "${OUT}" "rolling rpi5/pki back to internal" "stuck reconcile: the safety net ran"
eq "$([ -e "${CASE}/guest/etc/hugmesh/go-live" ] && echo present || echo absent)" absent "stuck reconcile: the marker was removed again"

# Round 2 (refuter M8): the ROLLBACK wait must be real. Once public, nft never shows
# the drop rule again; the lane must not print "internal again" or write a PASS verdict.
echo "a rollback that never converges fails, and says the device was left public"
new_case rbstuck; FAKE_NFT_STICKY_PUBLIC=1 run_lane
eq "${RC}" 1 "rollback stall: exit 1"
has "${OUT}" "status=public nft=public" "rollback stall: it did go public first"
has "${OUT}" "did not return to internal within 6s" "rollback stall: says the rollback timed out"
has "${OUT}" "DEVICE LEFT PUBLIC: run  ssh -t" "rollback stall: the safety net prints the manual rollback"
eq "$(printf '%s\n' "${OUT}" | grep -c 'internal again' | tr -d ' ')" 0 "rollback stall: never claims 'internal again'"
eq "$([ -e "${CASE}/evidence/verdict.txt" ] && echo present || echo absent)" absent "rollback stall: no verdict.txt"
eq "$([ -e "${CASE}/guest/etc/hugmesh/go-live" ] && echo present || echo absent)" absent "rollback stall: the driver did delete the marker"

# Round 2 (refuter M9, and a real defect): an ABSENT table is "unknown", never "public".
# The table vanishes as soon as the marker is written; real nft then exits 1 and echoes
# "list table inet hugmesh_release_gate" on stderr. Before round 2 the lane's unanchored
# grep matched that echo and read the missing table as public.
echo "a table that is absent while the marker is down is unknown, never public"
new_case notable; FAKE_NFT_ABSENT_WHEN_PUBLIC=1 run_lane
eq "${RC}" 1 "absent table: exit 1"
has "${OUT}" "status=public nft=unknown" "absent table: nft reads unknown"
eq "$(printf '%s\n' "${OUT}" | grep -c 'nft=public' | tr -d ' ')" 0 "absent table: nft never reads public"
has "${OUT}" "did not go public within 6s" "absent table: the public wait times out"
has "${OUT}" "rolling rpi5/pki back to internal" "absent table: the safety net ran"
has "${OUT}" "rpi5/pki is internal again" "absent table: and the device is back (the table returns with the drop rule)"
eq "$([ -e "${CASE}/evidence/verdict.txt" ] && echo present || echo absent)" absent "absent table: no verdict.txt"

echo "a listing cut off after the table header (nft exit 1) is unknown, never public"
new_case truncated; FAKE_NFT_TRUNCATED_WHEN_PUBLIC=1 run_lane
eq "${RC}" 1 "truncated listing: exit 1"
has "${OUT}" "status=public nft=unknown" "truncated listing: nft reads unknown"
eq "$(printf '%s\n' "${OUT}" | grep -c 'nft=public' | tr -d ' ')" 0 "truncated listing: nft never reads public"
has "${OUT}" "did not go public within 6s" "truncated listing: the public wait times out"

echo "a successful nft that lists no table header is unknown, never public"
new_case emptyok; FAKE_NFT_EMPTY_WHEN_PUBLIC=1 run_lane
eq "${RC}" 1 "empty listing: exit 1"
has "${OUT}" "status=public nft=unknown" "empty listing: nft reads unknown"
eq "$(printf '%s\n' "${OUT}" | grep -c 'nft=public' | tr -d ' ')" 0 "empty listing: nft never reads public"

echo "a table that is absent from the start is refused, not treated as public or internal"
new_case notable0; echo "public 0" > "${CASE}/log/nft.state"
: > "${CASE}/guest/etc/hugmesh/go-live"; FAKE_NFT_ABSENT_WHEN_PUBLIC=1 run_lane
eq "${RC}" 2 "absent at start: exit 2"
has "${OUT}" "status=public nft=unknown" "absent at start: names nft as unknown"
eq "$(calls_with "hugmesh-go-live commit")$(calls_with "hugmesh-go-live rollback")" 00 "absent at start: never commits or rolls back"

# Round 2 (refuter M3): BOTH witnesses must agree. A driver whose status line never
# leaves 'internal' while nft goes public must fail the public wait, not pass on nft.
echo "status and nft disagree: nft alone is not enough"
sed 's/^\(    echo "effective posture:   \)\$(effective_posture)"$/\1internal"/' "${DRIVER}" > "${TMP}/driver-status-internal"
if cmp -s "${DRIVER}" "${TMP}/driver-status-internal"; then
    _bad "could not plant the stuck-status mutation (the driver's 'effective posture:' line moved)"
else
    new_case disagree; FAKE_DRIVER_PATH="${TMP}/driver-status-internal" run_lane
    eq "${RC}" 1 "disagreement: exit 1"
    has "${OUT}" "status=internal nft=public" "disagreement: the witnesses really disagreed"
    has "${OUT}" "did not go public within 6s" "disagreement: the public wait times out"
    eq "$(printf '%s\n' "${OUT}" | grep -c 'PASS public' | tr -d ' ')" 0 "disagreement: never claims public"
    eq "$([ -e "${CASE}/evidence/verdict.txt" ] && echo present || echo absent)" absent "disagreement: no verdict.txt"
    eq "$([ -e "${CASE}/guest/etc/hugmesh/go-live" ] && echo present || echo absent)" absent "disagreement: rolled back, marker gone"
fi

echo "a driver that would commit an onion fails the lane, and 'n' is typed"
sed '/^    refuse_onion_commit "\${provider}"$/d' "${DRIVER}" > "${TMP}/driver-no-onion-refusal"
if cmp -s "${DRIVER}" "${TMP}/driver-no-onion-refusal"; then
    _bad "could not plant the onion mutation (the driver's refuse_onion_commit call moved)"
else
    new_case onion; FAKE_DRIVER_PATH="${TMP}/driver-no-onion-refusal" run_lane
    eq "${RC}" 1 "onion accepted: exit 1"
    has "${OUT}" "reached a confirmation prompt" "onion accepted: says the driver asked"
    eq "$([ -e "${CASE}/guest/etc/hugmesh/go-live" ] && echo present || echo absent)" absent "onion accepted: 'n' was typed, nothing written"
    eq "$(calls_with "commit --provider byo-domain")" 0 "onion accepted: the lane stops before the byo commit"
fi

echo "a plan that writes nothing fails the lane even when stale files are already there"
sed 's/^    glp_emit "\${provider}" "\${out}" || die .*$/    true/' "${DRIVER}" > "${TMP}/driver-no-emit"
if cmp -s "${DRIVER}" "${TMP}/driver-no-emit"; then
    _bad "could not plant the no-emit mutation (the driver's glp_emit call moved)"
else
    new_case stalefiles
    mkdir -p "${CASE}/guest/var/lib/hugmesh/go-live/out"
    for f in example.invalid.zone records.csv records.txt; do
        echo "stale 203.0.113.10" > "${CASE}/guest/var/lib/hugmesh/go-live/out/${f}"
    done
    FAKE_DRIVER_PATH="${TMP}/driver-no-emit" run_lane
    [ "${GOLIVE_TEST_VERBOSE:-0}" = 1 ] && printf '%s\n' "${OUT}" | sed 's/^/  | /'
    eq "${RC}" 1 "plan wrote nothing: exit 1"
    has "${OUT}" "byo-domain plan did not leave" "plan wrote nothing: stale files do not count"
    eq "$(calls_with "provider tor-onion")$(calls_with "hugmesh-go-live commit")" 00 \
       "plan wrote nothing: the lane stops there (no onion plan, no commit)"
fi

echo "a zone without the ingress address fails the lane"
sed 's/^\( *--ingress-ip) *\)GL_INGRESS_IP="\$2"; shift 2 ;;$/\1GL_INGRESS_IP=""; shift 2 ;;/' "${DRIVER}" > "${TMP}/driver-drops-ip"
if cmp -s "${DRIVER}" "${TMP}/driver-drops-ip"; then
    _bad "could not plant the dropped-ingress mutation (the driver's --ingress-ip parse moved)"
else
    new_case dropsip; FAKE_DRIVER_PATH="${TMP}/driver-drops-ip" run_lane
    eq "${RC}" 1 "zone without the address: exit 1"
    has "${OUT}" "does not carry the ingress address 203.0.113.10" "zone without the address: says so"
    eq "$(calls_with "hugmesh-go-live commit")" 0 "zone without the address: no commit"
fi

echo "an onion commit that fails for some OTHER reason is not taken as the refusal"
sed 's/^    refuse_onion_commit "\${provider}"$/    die "provider registry unreadable"/' "${DRIVER}" > "${TMP}/driver-other-failure"
if cmp -s "${DRIVER}" "${TMP}/driver-other-failure"; then
    _bad "could not plant the other-failure mutation (the driver's refuse_onion_commit call moved)"
else
    new_case otherfail; FAKE_DRIVER_PATH="${TMP}/driver-other-failure" run_lane
    eq "${RC}" 1 "other failure: exit 1"
    has "${OUT}" "failed for another reason" "other failure: says the refusal was not the driver's onion refusal"
    eq "$(calls_with "commit --provider byo-domain")" 0 "other failure: no byo commit"
fi

echo
echo "== golive_emulated_test: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]
