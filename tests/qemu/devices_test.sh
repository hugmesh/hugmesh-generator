#!/usr/bin/env bash
# devices_test.sh — HERMETIC tests for run-qemu-docker.sh's --keep-alive device
# machinery. Boots nothing and starts no container: the functions under test are
# extracted from the runner and driven with a fake `docker` on PATH.
#
#   bash tests/qemu/devices_test.sh
#
# WHY THIS FILE EXISTS. The first cut of the device console handed THE SAME host port
# (22300) to three different devices: two of the three exclusions were not actually
# consulted, so every row after the first published nothing usable and the Studio's
# Shell button pointed at a port no guest was behind. Nothing in the repo would have
# caught that. The allocator now applies three independent exclusions plus an atomic
# claim, and this file is what keeps them applied.
#
# The claim is a DIRECTORY on purpose: mkdir(2) either creates it or fails, with no
# window between test and create, so two runs starting in the same second cannot both
# believe they own a port.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${HERE}/run-qemu-docker.sh"
[ -f "${RUNNER}" ] || { echo "cannot find ${RUNNER}" >&2; exit 2; }

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (got '$1', want '$2')"; fi; }

TMP="$(mktemp -d)"; trap 'cleanup' EXIT
cleanup() {
    [ -n "${LPID:-}" ] && kill "${LPID}" 2>/dev/null
    rm -rf "${TMP}"
}

# Extract the allocator. Never `pkill -f` anything in here: the pattern would also
# match this script's own command line and kill the test run (observed).
for fn in docker_published_ports claim_port port_claim_is_stale release_port \
          port_free candidate_ports; do
    sed -n "/^${fn}() {/,/^}/p" "${RUNNER}" >> "${TMP}/f.sh"
    grep -q "^${fn}() {" "${TMP}/f.sh" || { echo "could not extract ${fn}" >&2; exit 2; }
done

DEV_PORT_MIN=22300
DEV_PORT_MAX=22399
PORTLOCK_DIR="${TMP}/locks"

# A fake docker that reports 22301 published by somebody else, and answers `docker ps`
# and `docker info` the way the real one would.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "ps --format")
     if [[ "${3:-}" == *Ports* ]]; then
        echo "127.0.0.1:22301->2222/tcp, 0.0.0.0:8080->80/tcp"
     else
        echo "some-other-container"
     fi ;;
  "info ") exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "${TMP}/bin/docker"
PATH="${TMP}/bin:${PATH}"
# shellcheck disable=SC1091
source "${TMP}/f.sh"

echo "candidate_ports — three independent exclusions"

# Occupy 22302 with a REAL listener, so the connect probe has something to reject.
python3 - "${TMP}/listening" <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 22302)); s.listen(1)
open(sys.argv[1], "w").close()
time.sleep(30)
PY
LPID=$!
for _ in $(seq 40); do [ -e "${TMP}/listening" ] && break; sleep 0.1; done

# One port blocked by EACH mechanism at once. If any single exclusion is skipped, the
# first candidate is that port rather than 22303 — which is exactly how three devices
# came to share 22300.
DEV_PORTS_TAKEN=(22300)                       # this process already handed it out
eq "$(candidate_ports | head -1)" "22303" \
   "skips in-process (22300), docker-published (22301) and listening (22302)"

# Negative control: with nothing excluded the allocator must return the bottom of the
# range. Without this, the assertion above would also pass for an allocator that
# simply never offered the first few ports.
DEV_PORTS_TAKEN=()
rm -rf "${PORTLOCK_DIR}"
kill "${LPID}" 2>/dev/null; LPID=""
sleep 0.3
cat > "${TMP}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "ps --format") [[ "${3:-}" == *Ports* ]] && echo "" || echo "" ;;
  "info ") exit 0 ;;
  *) exit 0 ;;
esac
FAKE
eq "$(candidate_ports | head -1)" "22300" \
   "control: with nothing excluded the range starts at 22300"

echo
echo "claim_port — three devices, three distinct ports"
DEV_PORTS_TAKEN=()
rm -rf "${PORTLOCK_DIR}"
got=()
for row in rpi5_pki rpi5_node x86_gateway; do
    while IFS= read -r p; do
        if claim_port "${p}" "hugmesh-qemu-${row}"; then
            got+=("${p}"); DEV_PORTS_TAKEN+=("${p}"); break
        fi
    done < <(candidate_ports)
done
eq "$(printf '%s\n' "${got[@]}" | sort -u | wc -l)" "3" \
   "three rows get three DISTINCT ports (the round-1 defect)"

# A claim is held for as long as its container RUNS — not just for the instant of
# choosing — because the port stays bound for exactly that long. So the daemon has to
# say the owner is alive; with the previous fake (which reported nothing running) the
# claim is correctly stale and reclaimable, which is the case below.
cat > "${TMP}/bin/docker" <<FAKE
#!/usr/bin/env bash
case "\$1 \${2:-}" in
  "ps --format") echo "hugmesh-qemu-rpi5_pki" ;;
  "info ") exit 0 ;;
  *) exit 0 ;;
esac
FAKE
eq "$(claim_port "${got[0]}" "someone-else" && echo took || echo refused)" "refused" \
   "a port claimed by a RUNNING container cannot be re-claimed"

# ...but a claim whose container is gone is reclaimable, or a crashed run would burn
# a port until someone deleted the work dir by hand.
cat > "${TMP}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "ps --format") echo "nothing-is-running" ;;
  "info ") exit 0 ;;
  *) exit 0 ;;
esac
FAKE
eq "$(claim_port "${got[0]}" "a-new-run" && echo took || echo refused)" "took" \
   "a stale claim (its container gone) is reclaimed"

# release_port must not hand away a port someone else holds.
eq "$(release_port "${got[1]}" "not-the-owner"; [ -d "${PORTLOCK_DIR}/${got[1]}" ] \
      && echo held || echo released)" "held" \
   "release_port refuses to drop another owner's claim"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
