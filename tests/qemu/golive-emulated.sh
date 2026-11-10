#!/usr/bin/env bash
# golive-emulated.sh — the FG3 proof lane: go-live on an emulated device that is
# ALREADY RUNNING, with no real publish.
#
#   bash tests/qemu/golive-emulated.sh --work out/qemu-runs --label rpi5/pki
#
# WHAT IT PROVES. "Go live from an emulated mesh" means the Studio host runs only
# `ssh` and the guest's own baked /usr/sbin/hugmesh-go-live does the work. This lane
# drives exactly that path against a keep-alive row and checks the result inside the
# guest:
#
#   1. the keep-alive registry record (<work>/devices/<label>.json) says the device is
#      running and names an ssh port and key — otherwise there is no channel to it;
#   2. one read-only probe: `command -v hugmesh-go-live` (no driver = not a go-live
#      server node), plus nft and hugmesh-firewall-reconcile, and the posture must
#      start INTERNAL;
#   3. `plan --provider byo-domain --domain example.invalid --ingress-ip 203.0.113.10
#      --out-dir /var/lib/hugmesh/go-live/out` writes the zone, the CSV and the
#      record set inside the guest, and the posture does not move;
#   4. `plan --provider tor-onion` succeeds, and `commit --provider tor-onion` is
#      REFUSED by the driver (the refusal text, not some other failure, and no
#      confirmation prompt is ever shown for it);
#   5. `ssh -tt … sudo -n hugmesh-go-live commit --provider byo-domain --domain
#      example.invalid` shows the driver's own confirmation prompt on the ssh pty and
#      this lane TYPES 'y' on it. There is no -y and no GL_ASSUME_YES anywhere: the
#      TTY confirmation is the security boundary, and this lane exercises it rather
#      than stepping around it;
#   6. within --timeout seconds (default 90) `hugmesh-go-live status` says public AND
#      `nft list table inet hugmesh_release_gate` has lost its 80/443 drop rule
#      (hugmesh-firewall-reconcile converged on its 60 s cron);
#   7. `rollback` (same pty pattern, 'y' typed) and, within --timeout again, both say
#      internal and the drop rule is back.
#
# WHAT IT NEVER DOES.
#   * It never boots anything. The one-QEMU-at-a-time rule is kept by construction:
#     this lane acts only on a device somebody already started with --keep-alive.
#   * It never contacts any host but 127.0.0.1. Every ssh destination is
#     <user>@127.0.0.1 on the record's loopback port. byo-domain and tor-onion emit
#     files only (no DNS, registrar, Cloudflare or ACME call), the domain must be a
#     reserved name (*.invalid, *.test, *.example) and the ingress address must be in
#     an RFC 5737 documentation range, so nothing this lane writes could ever resolve.
#   * It never answers a prompt it did not expect, and never answers one for the
#     onion: if the driver ever asks to commit tor-onion this lane types 'n'.
#   * It never leaves the device public. Once a commit has been typed, an EXIT trap
#     rolls back on every failure path and says so loudly if even that fails.
#
# The posture is EPHEMERAL on an emulated row: a restart boots the golden image
# INTERNAL again. That is fine here — the lane rolls back anyway.
#
# Exit status: 0 = every step proved; 1 = a step failed (the device was rolled back);
# 2 = refused before touching the device (bad arguments, no record, not running, no
# port/key, no driver, already public).
set -uo pipefail

PROG="golive-emulated"
WORK=""
LABEL=""
DOMAIN="example.invalid"
INGRESS_IP="203.0.113.10"
TIMEOUT=90
POLL=5
PROMPT_TIMEOUT=60
GUEST_OUT="/var/lib/hugmesh/go-live/out"
TABLE="hugmesh_release_gate"
EVIDENCE=""

usage() {
    cat <<EOF
Usage: $0 --work DIR --label PLATFORM/ROLE [options]

  --work DIR         the runner's --work dir (the registry is DIR/devices/)
  --label L          the keep-alive row, e.g. rpi5/pki
  --domain D         reserved name only (*.invalid|*.test|*.example).
                     Default: ${DOMAIN}
  --ingress-ip IP    RFC 5737 documentation address only (192.0.2.0/24,
                     198.51.100.0/24, 203.0.113.0/24). Default: ${INGRESS_IP}
  --timeout SEC      how long each posture flip may take. Default: ${TIMEOUT}
  --poll SEC         poll interval while waiting. Default: ${POLL}
  --evidence DIR     where the copied plan artifacts go.
                     Default: DIR/golive/<label>/harness-<UTC stamp>/
  -h, --help

Acts only on a device that is ALREADY running; boots nothing. Never publishes.
EOF
    exit "${1:-0}"
}

say()  { printf '[%s] %s\n' "${PROG}" "$*"; }
pass() { printf '[%s] PASS %s\n' "${PROG}" "$*"; }
fail() { printf '[%s] FAIL %s\n' "${PROG}" "$*" >&2; exit 1; }
refuse() { printf '[%s] REFUSED: %s\n' "${PROG}" "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --work)        [ $# -ge 2 ] || usage 2; WORK="$2"; shift 2 ;;
        --label)       [ $# -ge 2 ] || usage 2; LABEL="$2"; shift 2 ;;
        --domain)      [ $# -ge 2 ] || usage 2; DOMAIN="$2"; shift 2 ;;
        --ingress-ip)  [ $# -ge 2 ] || usage 2; INGRESS_IP="$2"; shift 2 ;;
        --timeout)     [ $# -ge 2 ] || usage 2; TIMEOUT="$2"; shift 2 ;;
        --poll)        [ $# -ge 2 ] || usage 2; POLL="$2"; shift 2 ;;
        --evidence)    [ $# -ge 2 ] || usage 2; EVIDENCE="$2"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 2 ;;
    esac
done

# ── Arguments: everything that could make this a real publish is refused here ────
[ -n "${WORK}" ]  || refuse "--work is required (the runner's --work dir)"
[ -n "${LABEL}" ] || refuse "--label is required (e.g. rpi5/pki)"
[ -d "${WORK}" ]  || refuse "--work ${WORK} is not a directory"
[[ "${LABEL}" =~ ^[A-Za-z0-9][A-Za-z0-9._+/-]*$ ]] && [[ "${LABEL}" != *..* ]] \
    || refuse "--label '${LABEL}' is not a platform/role label"
[[ "${TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || refuse "--timeout must be a positive whole number of seconds"
[[ "${POLL}" =~ ^[1-9][0-9]*$ ]]    || refuse "--poll must be a positive whole number of seconds"

# The domain lands in a remote command line and in emitted zone files: a strict DNS
# shape first (so it can never carry a shell metacharacter), then a RESERVED name
# (RFC 2606 / RFC 6761), so the records this lane emits can never resolve anywhere.
[[ "${DOMAIN}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
    || refuse "--domain '${DOMAIN}' is not a DNS name"
case "${DOMAIN,,}" in
    *.invalid|*.test|*.example) ;;
    *) refuse "--domain '${DOMAIN}' is a real name; this lane never publishes, so it takes only a reserved one (*.invalid, *.test, *.example)" ;;
esac

# The ingress address: the emulated node's own addresses are the obvious thing to
# type and the wrong one — 10.0.2.0/24 is QEMU's slirp, 10.77.0.0/24 the mesh L2;
# they are private, and no registrar record can use them. Only a documentation
# address (RFC 5737) is accepted, so the zone is well-formed and points nowhere.
[[ "${INGRESS_IP}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
    || refuse "--ingress-ip '${INGRESS_IP}' is not an IPv4 address"
case "${INGRESS_IP}" in
    10.0.2.*)  refuse "--ingress-ip ${INGRESS_IP} is QEMU's slirp network (10.0.2.0/24): a private address no registrar record can use" ;;
    10.77.0.*) refuse "--ingress-ip ${INGRESS_IP} is the emulated mesh L2 (10.77.0.0/24): a private address no registrar record can use" ;;
    192.0.2.*|198.51.100.*|203.0.113.*) ;;
    *) refuse "--ingress-ip ${INGRESS_IP} is not an RFC 5737 documentation address (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24); this lane never publishes a real one" ;;
esac
for octet in "${BASH_REMATCH[@]:1}"; do
    [ "${octet}" -le 255 ] || refuse "--ingress-ip '${INGRESS_IP}' has an octet above 255"
done

# ── The keep-alive record ─────────────────────────────────────────────────────────
SAFE_LABEL="$(printf '%s' "${LABEL}" | tr '/+' '__')"
RECORD="${WORK}/devices/${SAFE_LABEL}.json"
[ -r "${RECORD}" ] || refuse "no keep-alive record for ${LABEL} (${RECORD}); start it with run-qemu-docker.sh --keep-alive --only-exact ${LABEL} first — this lane boots nothing"

command -v python3 >/dev/null 2>&1 || refuse "python3 is required (it reads the record and drives the confirmation pty)"

STATE="" PORT="" SSH_USER="" KEY="" CONTAINER="" STARTED_AT=""
REC_OUT="$(python3 -I - "${RECORD}" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        rec = json.load(fh)
except (OSError, ValueError) as exc:
    print("error=%s" % str(exc).replace("\n", " "))
    sys.exit(0)
if not isinstance(rec, dict):
    print("error=record is not a JSON object")
    sys.exit(0)
for key in ("state", "ssh_host_port", "ssh_user", "ssh_key", "container", "started_at"):
    val = rec.get(key)
    val = "" if val is None else str(val)
    if "\n" in val or "\r" in val:
        val = ""
    print("%s=%s" % (key, val))
PY
)" || refuse "could not read ${RECORD}"
while IFS= read -r line; do
    case "${line}" in
        error=*)         refuse "unreadable keep-alive record ${RECORD}: ${line#error=}" ;;
        state=*)         STATE="${line#state=}" ;;
        ssh_host_port=*) PORT="${line#ssh_host_port=}" ;;
        ssh_user=*)      SSH_USER="${line#ssh_user=}" ;;
        ssh_key=*)       KEY="${line#ssh_key=}" ;;
        container=*)     CONTAINER="${line#container=}" ;;
        started_at=*)    STARTED_AT="${line#started_at=}" ;;
    esac
done <<<"${REC_OUT}"

[ "${STATE}" = "running" ] \
    || refuse "${LABEL} is not running (record state '${STATE:-<none>}'): no channel to the device"
[[ "${PORT}" =~ ^[1-9][0-9]{0,4}$ ]] && [ "${PORT}" -le 65535 ] \
    || refuse "${LABEL} has no ssh port in its record (ssh_host_port '${PORT:-0}'): no channel to the device"
[ -n "${KEY}" ] && [ -f "${KEY}" ] && [ -r "${KEY}" ] \
    || refuse "${LABEL} has no readable ssh key (record ssh_key '${KEY:-<none>}'): no channel to the device"
[[ "${SSH_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || refuse "${LABEL} has no usable ssh user in its record ('${SSH_USER}')"

# A record survives its container (a host reboot, a kill -9): when docker can answer,
# a "running" record whose container is gone is stale and refused rather than probed.
if [ -n "${CONTAINER}" ] && command -v docker >/dev/null 2>&1; then
    if live="$(docker ps --filter "name=^${CONTAINER}\$" --format '{{.Names}}' 2>/dev/null)"; then
        [ "${live}" = "${CONTAINER}" ] \
            || refuse "${LABEL}'s record says running but container ${CONTAINER} is not up (stale record): no channel to the device"
    else
        say "WARN: docker did not answer; relying on the ssh probe alone for ${CONTAINER}"
    fi
fi

say "target ${LABEL}: ${SSH_USER}@127.0.0.1:${PORT} (container ${CONTAINER:-?}, started ${STARTED_AT:-?})"

# ── The channel: ssh to loopback, nothing else ─────────────────────────────────────
DEST="${SSH_USER}@127.0.0.1"
SSH_OPTS=(-i "${KEY}" -p "${PORT}"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=15
          -o ServerAliveInterval=10 -o ServerAliveCountMax=6)

# guest CMD — one non-interactive round trip. stdin is /dev/null so the remote side
# never has a terminal (a confirmation gate there must REFUSE, never read).
guest() { ssh "${SSH_OPTS[@]}" "${DEST}" "$1" </dev/null; }

# The pty driver: runs argv under a fresh local pty, waits for EXPECT in the output,
# then types ANSWER and Enter, exactly as a person would. ANSWER '-' means "this must
# NOT prompt": if it does anyway, 'n' is typed (never consent) and the result is 4.
# Exit: the command's own status; 3 = the expected prompt never appeared;
# 4 = a prompt appeared that must not; 124 = timed out.
PTY_DRIVER="$(cat <<'PY'
import os, pty, select, signal, sys, time
expect, answer, limit = sys.argv[1].encode(), sys.argv[2], float(sys.argv[3])
argv = sys.argv[4:]
pid, fd = pty.fork()
if pid == 0:
    try:
        os.execvp(argv[0], argv)
    finally:
        os._exit(127)
seen = b""
prompted = timed_out = False
deadline = time.monotonic() + limit
while True:
    left = deadline - time.monotonic()
    if left <= 0:
        timed_out = True
        os.kill(pid, signal.SIGTERM)
        break
    ready, _, _ = select.select([fd], [], [], min(left, 1.0))
    if not ready:
        continue
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    sys.stdout.buffer.write(chunk)
    sys.stdout.flush()
    seen = (seen + chunk)[-8192:]
    if not prompted and expect in seen:
        prompted = True
        os.write(fd, b"n\r" if answer == "-" else answer.encode() + b"\r")
_, status = os.waitpid(pid, 0)
rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)
sys.stdout.write("\n")
if timed_out:
    sys.exit(124)
if answer == "-":
    sys.exit(4 if prompted else rc)
sys.exit(rc if prompted else 3)
PY
)"

# on_pty EXPECT ANSWER REMOTE_CMD — the remote command on an ssh -tt pty.
on_pty() {
    python3 -I -c "${PTY_DRIVER}" "$1" "$2" "${PROMPT_TIMEOUT}" \
        ssh -tt "${SSH_OPTS[@]}" "${DEST}" "$3"
}

COMMIT_PROMPT="Proceed and trip go-live?"
ROLLBACK_PROMPT="Proceed and re-close to internal?"

# posture — one round trip, BOTH witnesses: what the driver says (status) and what
# netfilter enforces (the reconcile-owned table). Prints "<status> <nft>", each
# public|internal|unknown. nft is public only when OUR table is loaded and has no
# 80/443 drop rule — an absent table is "unknown", never "public".
posture() {
    local out st nf
    out="$(guest "sudo -n sh -c 'hugmesh-go-live status; echo @@nft@@; nft list table inet ${TABLE}'" 2>&1)"
    st="$(printf '%s\n' "${out}" | sed -n 's/^effective posture:[[:space:]]*\([a-z]*\).*/\1/p' | head -n1)"
    case "${st}" in public|internal) ;; *) st="unknown" ;; esac
    nf="$(printf '%s\n' "${out}" | sed -n '/^@@nft@@$/,$p')"
    if ! printf '%s\n' "${nf}" | grep -E "table inet ${TABLE}" >/dev/null; then
        nf="unknown"
    elif printf '%s\n' "${nf}" | grep -E 'tcp dport \{ ?80, ?443 ?\} drop' >/dev/null; then
        nf="internal"
    else
        nf="public"
    fi
    printf '%s %s\n' "${st}" "${nf}"
}

# wait_posture WANT — poll until both witnesses say WANT, or --timeout.
wait_posture() {
    local want="$1" got="" start=${SECONDS}
    while :; do
        got="$(posture)"
        say "  posture after $((SECONDS - start))s: status=${got% *} nft=${got#* }"
        [ "${got}" = "${want} ${want}" ] && return 0
        [ $((SECONDS - start)) -ge "${TIMEOUT}" ] && break
        sleep "${POLL}"
    done
    say "posture did not reach '${want}' within ${TIMEOUT}s (last: status=${got% *} nft=${got#* })"
    return 1
}

# ── Rollback safety net: armed the moment a commit is typed ────────────────────────
COMMITTED=0
ROLLED_BACK=0
safety_net() {
    local rc=$?
    [ "${COMMITTED}" = 1 ] && [ "${ROLLED_BACK}" = 0 ] || return "${rc}"
    say "rolling ${LABEL} back to internal before exiting (a step after the commit failed)"
    on_pty "${ROLLBACK_PROMPT}" y "sudo -n hugmesh-go-live rollback" >/dev/null 2>&1
    if wait_posture internal; then
        say "${LABEL} is internal again"
    else
        printf '[%s] DEVICE LEFT PUBLIC: run  ssh -t -i %s -p %s %s sudo hugmesh-go-live rollback\n' \
            "${PROG}" "${KEY}" "${PORT}" "${DEST}" >&2
    fi
    [ "${rc}" = 0 ] && rc=1
    exit "${rc}"
}
trap safety_net EXIT

# ── 1. Probe (read-only) ────────────────────────────────────────────────────────────
say "probe: command -v hugmesh-go-live"
PROBE="$(guest "sudo -n sh -c 'command -v hugmesh-go-live || echo @@no-driver@@; command -v nft || echo @@no-nft@@; command -v hugmesh-firewall-reconcile || echo @@no-reconcile@@'" 2>&1)"
PROBE_RC=$?
[ "${PROBE_RC}" = 0 ] || refuse "ssh to ${DEST} -p ${PORT} failed (rc ${PROBE_RC}): ${PROBE}"
case "${PROBE}" in
    *@@no-driver@@*) refuse "${LABEL} has no hugmesh-go-live driver: not a go-live server node (client roles, Frite, Jetson and Orange Pi images do not bake one)" ;;
esac
case "${PROBE}" in
    *@@no-nft@@*|*@@no-reconcile@@*) refuse "${LABEL} lacks nft or hugmesh-firewall-reconcile: the posture flip cannot be observed on it" ;;
esac
pass "probe: the guest carries its own driver, nft and the firewall reconcile"

BEFORE="$(posture)"
[ "${BEFORE}" = "internal internal" ] \
    || refuse "${LABEL} does not start INTERNAL (status=${BEFORE% *} nft=${BEFORE#* }); roll it back by hand first — this lane only flips a device it can return to where it found it"
pass "starting posture is internal (status and nft agree)"

# ── 2. Plan byo-domain: files only, posture untouched ────────────────────────────
ZONE="${GUEST_OUT}/${DOMAIN}.zone"
# Remove the three files this plan must create, so a stale copy from an earlier run
# can never satisfy the "files exist" assertion below.
guest "sudo -n rm -f '${ZONE}' '${GUEST_OUT}/records.csv' '${GUEST_OUT}/records.txt'" >/dev/null 2>&1
say "plan: byo-domain for ${DOMAIN} at ${INGRESS_IP}"
PLAN_OUT="$(guest "sudo -n hugmesh-go-live plan --provider byo-domain --domain ${DOMAIN} --ingress-ip ${INGRESS_IP} --out-dir ${GUEST_OUT}" 2>&1)" \
    || fail "byo-domain plan failed: ${PLAN_OUT}"
printf '%s\n' "${PLAN_OUT}" | sed 's/^/    /'
case "${PLAN_OUT}" in
    *"==> Rendering provider artifacts"*"==> Plan summary ready"*) ;;
    *) fail "byo-domain plan did not print its two progress banners" ;;
esac
guest "sudo -n sh -c 'test -s ${ZONE} && test -s ${GUEST_OUT}/records.csv && test -s ${GUEST_OUT}/records.txt'" >/dev/null 2>&1 \
    || fail "byo-domain plan did not leave ${ZONE}, records.csv and records.txt in the guest"
ZONE_TEXT="$(guest "sudo -n cat ${ZONE}" 2>/dev/null)"
case "${ZONE_TEXT}" in
    *"${INGRESS_IP}"*) ;;
    *) fail "the emitted zone does not carry the ingress address ${INGRESS_IP}" ;;
esac
pass "byo-domain plan: zone, CSV and record set exist in the guest"

# ── 3. Plan tor-onion, and its commit is refused ─────────────────────────────────
say "plan: tor-onion"
ONION_OUT="$(guest "sudo -n hugmesh-go-live plan --provider tor-onion --out-dir ${GUEST_OUT}" 2>&1)" \
    || fail "tor-onion plan failed: ${ONION_OUT}"
guest "sudo -n test -s ${GUEST_OUT}/onion.txt" >/dev/null 2>&1 \
    || fail "tor-onion plan did not leave ${GUEST_OUT}/onion.txt in the guest"
pass "tor-onion plan: onion.txt exists in the guest"

AFTER_PLAN="$(posture)"
[ "${AFTER_PLAN}" = "internal internal" ] \
    || fail "planning moved the posture (status=${AFTER_PLAN% *} nft=${AFTER_PLAN#* }); plan must never flip"
pass "both plans left the posture internal"

# On a pty, so the refusal is proven to be the onion refusal and not the TTY gate.
say "commit: tor-onion (must be refused)"
ONION_COMMIT="$(on_pty "[y/N]" - "sudo -n hugmesh-go-live commit --provider tor-onion" 2>&1)"
ONION_RC=$?
printf '%s\n' "${ONION_COMMIT}" | sed 's/^/    /'
case "${ONION_RC}" in
    0) fail "commit --provider tor-onion SUCCEEDED; the driver must refuse it" ;;
    4) COMMITTED=1   # it asked; 'n' was typed — still make sure nothing flipped
       fail "commit --provider tor-onion reached a confirmation prompt; the driver must refuse it before asking" ;;
    124) fail "commit --provider tor-onion hung" ;;
esac
case "${ONION_COMMIT}" in
    *"A Tor address needs no public flip"*) ;;
    *) fail "commit --provider tor-onion failed for another reason (rc ${ONION_RC}): ${ONION_COMMIT}" ;;
esac
AFTER_ONION="$(posture)"
[ "${AFTER_ONION}" = "internal internal" ] \
    || { COMMITTED=1; fail "the refused onion commit moved the posture (status=${AFTER_ONION% *} nft=${AFTER_ONION#* })"; }
pass "commit --provider tor-onion is refused by the driver; posture still internal"

# ── 4. Commit byo-domain: the real confirmation prompt, answered on the pty ──────
say "commit: byo-domain — typing 'y' at the driver's own prompt over ssh -tt"
COMMITTED=1
COMMIT_OUT="$(on_pty "${COMMIT_PROMPT}" y "sudo -n hugmesh-go-live commit --provider byo-domain --domain ${DOMAIN}" 2>&1)"
COMMIT_RC=$?
printf '%s\n' "${COMMIT_OUT}" | sed 's/^/    /'
case "${COMMIT_RC}" in
    0) ;;
    3) fail "the commit never showed its confirmation prompt ('${COMMIT_PROMPT}')" ;;
    124) fail "the commit hung at or after its confirmation prompt" ;;
    *) fail "commit --provider byo-domain failed (rc ${COMMIT_RC})" ;;
esac
case "${COMMIT_OUT}" in
    *"GO LIVE tripped"*) ;;
    *) fail "the commit returned 0 but never said 'GO LIVE tripped'" ;;
esac
pass "commit: the driver asked on the pty, 'y' was typed, the marker is written"

say "waiting up to ${TIMEOUT}s for status AND nft to say public"
wait_posture public || fail "the device did not go public within ${TIMEOUT}s"
pass "public: hugmesh-go-live status and table inet ${TABLE} agree"

# ── 5. Rollback ───────────────────────────────────────────────────────────────────
say "rollback — typing 'y' at the driver's own prompt over ssh -tt"
RB_OUT="$(on_pty "${ROLLBACK_PROMPT}" y "sudo -n hugmesh-go-live rollback" 2>&1)"
RB_RC=$?
printf '%s\n' "${RB_OUT}" | sed 's/^/    /'
[ "${RB_RC}" = 0 ] || fail "rollback failed (rc ${RB_RC})"
say "waiting up to ${TIMEOUT}s for status AND nft to say internal"
wait_posture internal || fail "the device did not return to internal within ${TIMEOUT}s"
ROLLED_BACK=1
pass "internal again: the drop rule is back"

# ── 6. Evidence: the plan artifacts, copied back with ssh cat ────────────────────
[ -n "${EVIDENCE}" ] || EVIDENCE="${WORK}/golive/${SAFE_LABEL}/harness-$(date -u +%Y%m%dT%H%M%SZ)"
if mkdir -p "${EVIDENCE}" 2>/dev/null; then
    for f in "${DOMAIN}.zone" records.csv records.txt onion.txt; do
        guest "sudo -n cat ${GUEST_OUT}/${f}" > "${EVIDENCE}/${f}" 2>/dev/null || rm -f "${EVIDENCE}/${f}"
    done
    {
        echo "label=${LABEL}"
        echo "started_at=${STARTED_AT}"
        echo "domain=${DOMAIN}"
        echo "ingress_ip=${INGRESS_IP}"
        echo "proved_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "verdict=PASS"
    } > "${EVIDENCE}/verdict.txt"
    say "evidence: ${EVIDENCE}"
fi

say "PASS: ${LABEL} planned, refused the onion commit, went public on a typed 'y', and rolled back to internal"
exit 0
