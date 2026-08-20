#!/usr/bin/env bash
# test-fetch-retry-hardening.sh — gate for the #60 item 6 fetch hardening.
#
# THE INCIDENT THIS PINS. The 08-19 mesh run (7 images) died after image 1
# because a ~5-minute host DNS outage (15:02–15:07 PDT) outlived every fetch
# retry span in the tree: pki.rpi5's headscale download and be.x86's stage3
# fetch burned their FIXED-delay curl retries (8×8s inline, 5×5s in dlv_fetch —
# ~64s and ~25s of total patience) against "curl: (6) Could not resolve host"
# and the builds declared fetch death for artifacts that were perfectly
# fetchable five minutes later.
#
# The fix lives in ONE place — scripts/_download-lib.sh:
#   * dlv_fetch_retry — outer exponential backoff (default 8 attempts,
#     8s→240s-capped doubling ≈ 12 min of patience vs the old ~1 min);
#   * dlv_dns_ok — a resolver sanity probe (`getent hosts`) consulted on every
#     failure: while the resolver itself is down the loop STALLS (bounded by
#     DLV_DNS_STALL_MAX) WITHOUT consuming attempts, so a transient DNS outage
#     stalls-and-retries instead of aborting the build;
# and every artifact/distfile fetch path routes through it: the builders'
# headscale/tailscale/u-boot/stage3-index curls, dlv_fetch (checksums/DIGESTS
# sidecars) and _shared-assets-lib.sh's sa_fetch_default (the stage3 seed).
#
# Both halves are proven HERMETICALLY: curl/getent/sleep are PATH stubs driven
# by a control dir (sleep never sleeps — it logs the requested duration and can
# "end the outage", so the whole gate runs in seconds with zero network). Then
# the call-site wiring is grep-asserted across all ten stage4 builders, with a
# detector SELF-TEST (synthetic old/new fixtures) so the detector can never rot
# into a vacuous green.
#
# Run: bash tests/scripts/test-fetch-retry-hardening.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/scripts/_download-lib.sh"
SA_LIB="${REPO}/scripts/_shared-assets-lib.sh"
[ -f "${LIB}" ]    || { echo "  FAIL helper missing: ${LIB}"; exit 1; }
[ -f "${SA_LIB}" ] || { echo "  FAIL helper missing: ${SA_LIB}"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

echo "== fetch-retry hardening gate (#60 item 6) =="

# ── stubs: curl / getent / sleep driven by ${FETCH_TEST_CTRL} ────────────────
STUB="${WORK}/stub"; mkdir -p "${STUB}"
CTRL="${WORK}/ctrl"

cat > "${STUB}/curl" <<'EOS'
#!/usr/bin/env bash
c="${FETCH_TEST_CTRL:?}"
echo x >> "${c}/curl.calls"
out=""; prev=""
for a in "$@"; do [ "${prev}" = "-o" ] && out="${a}"; prev="${a}"; done
if [ -f "${c}/net-down" ]; then
    [ -n "${out}" ] && printf 'PARTIAL' > "${out}"   # truncated transfer
    echo "curl: (6) Could not resolve host: github.com" >&2
    exit 6
fi
fails=0; [ -f "${c}/fail-times" ] && fails="$(cat "${c}/fail-times")"
calls="$(wc -l < "${c}/curl.calls")"
if [ "${calls}" -le "${fails}" ]; then
    [ -n "${out}" ] && printf 'PARTIAL' > "${out}"
    exit 22
fi
[ -n "${out}" ] && cat "${c}/payload" > "${out}"
exit 0
EOS

cat > "${STUB}/getent" <<'EOS'
#!/usr/bin/env bash
c="${FETCH_TEST_CTRL:?}"
[ -f "${c}/net-down" ] && exit 2
exit 0
EOS

cat > "${STUB}/sleep" <<'EOS'
#!/usr/bin/env bash
c="${FETCH_TEST_CTRL:?}"
echo "$1" >> "${c}/sleep.log"
# world-advancer: the resolver outage "ends" after N logged sleeps
if [ -f "${c}/net-down" ] && [ -f "${c}/outage-ends-after" ]; then
    n="$(cat "${c}/outage-ends-after")"
    s="$(wc -l < "${c}/sleep.log")"
    [ "${s}" -ge "${n}" ] && rm -f "${c}/net-down"
fi
exit 0
EOS
chmod +x "${STUB}/curl" "${STUB}/getent" "${STUB}/sleep"

reset_ctrl() { rm -rf "${CTRL}"; mkdir -p "${CTRL}"; printf 'the-artifact-bytes' > "${CTRL}/payload"; }
curl_calls()  { [ -f "${CTRL}/curl.calls" ] && wc -l < "${CTRL}/curl.calls" || echo 0; }
sleep_log()   { [ -f "${CTRL}/sleep.log" ] && tr '\n' ' ' < "${CTRL}/sleep.log" | sed 's/ $//' || true; }

# Source the lib with a clean tunable slate, then drive it through the stubs.
unset DLV_FETCH_ATTEMPTS DLV_FETCH_BACKOFF DLV_FETCH_BACKOFF_CAP DLV_FETCH_INNER_RETRY \
      DLV_DNS_STALL_INTERVAL DLV_DNS_STALL_MAX DLV_DNS_PROBE_NAMES 2>/dev/null || true
# shellcheck source=/dev/null
DLV_QUIET=1 source "${LIB}"
export FETCH_TEST_CTRL="${CTRL}"
PATH="${STUB}:${PATH}"

echo "── behavioral: the hardened loop (stubbed curl/getent/sleep — no network) ──"

# ── 1. defaults give MORE patience than the outage that killed the 08-19 run ──
span=0; d="${DLV_FETCH_BACKOFF}"; i=1
while [ "${i}" -lt "${DLV_FETCH_ATTEMPTS}" ]; do
    span=$((span + d)); d=$((d * 2))
    [ "${d}" -gt "${DLV_FETCH_BACKOFF_CAP}" ] && d="${DLV_FETCH_BACKOFF_CAP}"
    i=$((i + 1))
done
if [ "${DLV_FETCH_ATTEMPTS}" -ge 6 ] && [ "${span}" -gt 300 ]; then
    ok "default backoff budget: ${DLV_FETCH_ATTEMPTS} attempts, ${span}s of sleeps — outlives the 5-min outage class (old spans: ~64s/~25s)"
else
    bad "default backoff budget too small: ${DLV_FETCH_ATTEMPTS} attempts / ${span}s of sleeps (need >=6 attempts and >300s — the 08-19 outage was ~300s)"
fi
if [ "${DLV_DNS_STALL_MAX}" -ge 600 ]; then
    ok "default resolver-stall budget DLV_DNS_STALL_MAX=${DLV_DNS_STALL_MAX}s (>=600s)"
else
    bad "default DLV_DNS_STALL_MAX=${DLV_DNS_STALL_MAX}s cannot ride out a multi-minute resolver outage"
fi

# ── 2. clean first-try success ───────────────────────────────────────────────
reset_ctrl
if dlv_fetch_retry "https://x.test/a" "${WORK}/a" 2>/dev/null \
   && [ "$(cat "${WORK}/a")" = "the-artifact-bytes" ] && [ "$(curl_calls)" -eq 1 ]; then
    ok "first-try success: rc=0, dest written, exactly 1 curl call"
else
    bad "first-try success broke (rc/content/call-count)"
fi

# ── 3. transient non-DNS failures back off EXPONENTIALLY, then succeed ───────
reset_ctrl; echo 2 > "${CTRL}/fail-times"
if dlv_fetch_retry "https://x.test/b" "${WORK}/b" 2>/dev/null \
   && [ "$(cat "${WORK}/b")" = "the-artifact-bytes" ]; then
    if [ "$(sleep_log)" = "8 16" ]; then
        ok "2 transient failures → sleeps '8 16' (doubling backoff), 3rd attempt succeeds"
    else
        bad "expected exponential sleeps '8 16', got '$(sleep_log)'"
    fi
else
    bad "fetch should survive 2 transient failures under the default 8-attempt budget"
fi

# ── 4. THE 08-19 SCENARIO: resolver outage stalls WITHOUT consuming attempts ──
# Attempts budget of 2 would die on the 2nd failure under the old semantics;
# the outage spans 4 failed fetches and the build must still come back alive.
reset_ctrl; : > "${CTRL}/net-down"; echo 4 > "${CTRL}/outage-ends-after"
DLV_FETCH_ATTEMPTS=2
if dlv_fetch_retry "https://x.test/c" "${WORK}/c" 2>"${WORK}/c.err" \
   && [ "$(cat "${WORK}/c")" = "the-artifact-bytes" ]; then
    ok "resolver outage spanning 4 failed fetches: stalled + recovered with only DLV_FETCH_ATTEMPTS=2 (stalls consume NO attempts)"
else
    bad "a transient resolver outage must stall-and-retry, not declare fetch death (rc=$?)"
fi
if [ "$(sleep_log)" = "30 30 30 30" ]; then
    ok "outage stalls used DLV_DNS_STALL_INTERVAL (30s each), not the attempt backoff"
else
    bad "expected stall sleeps '30 30 30 30', got '$(sleep_log)'"
fi
grep -q "stalling" "${WORK}/c.err" \
    && ok "stall path says so on stderr (operator can see WHY the build is waiting)" \
    || bad "stall path is silent — the operator cannot tell a stall from a hang"

# ── 5. a PERSISTENT resolver outage is still fetch death (bounded stall) ─────
reset_ctrl; : > "${CTRL}/net-down"
DLV_FETCH_ATTEMPTS=8 DLV_DNS_STALL_MAX=90
if dlv_fetch_retry "https://x.test/d" "${WORK}/d" 2>"${WORK}/d.err"; then
    bad "a permanent resolver outage must eventually fail (rc=0?!)"
else
    if [ "$(sleep_log)" = "30 30 30" ] && grep -q "resolver still down" "${WORK}/d.err"; then
        ok "permanent outage: exactly DLV_DNS_STALL_MAX/INTERVAL stalls, then a resolver-naming fetch death"
    else
        bad "bounded-stall death wrong (sleeps '$(sleep_log)', err: $(head -c200 "${WORK}/d.err"))"
    fi
fi
DLV_DNS_STALL_MAX=1800

# ── 6. resolver-OK hard failure: exactly DLV_FETCH_ATTEMPTS attempts ─────────
reset_ctrl; echo 99 > "${CTRL}/fail-times"
DLV_FETCH_ATTEMPTS=3
if dlv_fetch_retry "https://x.test/e" "${WORK}/e" 2>"${WORK}/e.err"; then
    bad "an always-failing fetch with a healthy resolver must fail"
else
    [ "$(curl_calls)" -eq 3 ] && grep -q "after 3 attempts" "${WORK}/e.err" \
        && ok "resolver-OK failure consumed exactly 3 attempts then died" \
        || bad "expected exactly 3 attempts (got $(curl_calls); err: $(head -c200 "${WORK}/e.err"))"
    [ ! -f "${WORK}/e" ] \
        && ok "truncated dest removed on failure (no garbage for a later cache check)" \
        || bad "a failed fetch left a truncated dest behind"
fi
DLV_FETCH_ATTEMPTS=8

# ── 7. stdout mode ('-' dest) buffers — a failed attempt leaks NO partial bytes ─
reset_ctrl; echo 1 > "${CTRL}/fail-times"
outbytes="$(dlv_fetch_retry "https://x.test/f" - 2>/dev/null)"; rc=$?
if [ "${rc}" -eq 0 ] && [ "${outbytes}" = "the-artifact-bytes" ]; then
    ok "stdout mode: 1 failed attempt (partial bytes written) leaks nothing — stdout is the full body exactly once"
else
    bad "stdout mode broke (rc=${rc}, got '${outbytes}')"
fi

# ── 8. dlv_dns_ok semantics ───────────────────────────────────────────────────
reset_ctrl
dlv_dns_ok && ok "dlv_dns_ok: 0 while the resolver answers" || bad "dlv_dns_ok should pass with a healthy resolver"
: > "${CTRL}/net-down"
dlv_dns_ok && bad "dlv_dns_ok should FAIL during a resolver outage" || ok "dlv_dns_ok: non-zero during a resolver outage"
rm -f "${CTRL}/net-down"

echo "── static: every artifact fetch path is wired through the hardened loop ──"

# Detector: the pre-hardening call-site classes. Any of these reappearing in a
# builder resurrects a fixed-short-patience fetch that dies on a DNS blip.
PAT_OLD='curl[^#|]*--retry-delay|curl -sL "\$\{SEED_STAGE3_URL\}"|curl -fL -o'

# ── 9. detector SELF-TEST (mutation guard) ────────────────────────────────────
printf '%s\n' '    if curl -fL --retry 8 --retry-delay 8 --retry-max-time 600 --retry-connrefused --retry-all-errors -o "${HS_BIN}" "${HS_URL}"; then' > "${WORK}/fix.bad1"
printf '%s\n' 'STAGE3_FILE=$(curl -sL "${SEED_STAGE3_URL}" | awk '"'"'/stage3/{print $1; exit}'"'"')' > "${WORK}/fix.bad2"
printf '%s\n' '        if curl -fL -o "${STAGE_DIR}/uboot/u-boot.bin" "${FRITE_UBOOT_URL}"; then' > "${WORK}/fix.bad3"
printf '%s\n' '    if dlv_fetch_retry "${HS_URL}" "${HS_BIN}"; then' > "${WORK}/fix.good1"
printf '%s\n' 'STAGE3_FILE=$(dlv_fetch_retry "${SEED_STAGE3_URL}" - -s | awk '"'"'/stage3/{print $1; exit}'"'"')' > "${WORK}/fix.good2"
for fx in bad1 bad2 bad3; do
    grep -qE "${PAT_OLD}" "${WORK}/fix.${fx}" \
        && ok "detector self-test: synthetic OLD call-site '${fx}' is caught" \
        || bad "detector self-test: synthetic OLD call-site '${fx}' NOT caught — the detector is blind"
done
for fx in good1 good2; do
    grep -qE "${PAT_OLD}" "${WORK}/fix.${fx}" \
        && bad "detector self-test: hardened call-site '${fx}' falsely flagged" \
        || ok "detector self-test: hardened call-site '${fx}' passes clean"
done

# ── 10. all ten stage4 builders: no old-class fetch, hardened sites present ──
BUILDERS=(build-rpi5-stage4.sh build-jetson-stage4.sh build-x86-host-stage4.sh
          build-frite-stage4.sh build-orangepi5-stage4.sh build-orangepi-zero2-stage4.sh
          build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh
          build-orangepi3-lts-stage4.sh build-orangepi4-lts-stage4.sh)
for b in "${BUILDERS[@]}"; do
    BF="${REPO}/${b}"
    [ -f "${BF}" ] || { bad "${b}: builder missing"; continue; }
    hits="$(grep -nE "${PAT_OLD}" "${BF}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    if [ -z "${hits}" ]; then
        ok "${b}: no fixed-short-patience inline artifact curl"
    else
        bad "${b}: old-class fetch call-site(s) present: $(printf '%s' "${hits}" | head -n1)"
    fi
    n="$(grep -c 'dlv_fetch_retry ' "${BF}" || true)"
    if [ "${n}" -ge 3 ]; then
        ok "${b}: ${n} artifact fetches route through dlv_fetch_retry"
    else
        bad "${b}: expected >=3 dlv_fetch_retry call sites (stage3 index + headscale + tailscale), found ${n}"
    fi
    grep -q 'dlv_fetch_retry "\${SEED_STAGE3_URL}" -' "${BF}" \
        && ok "${b}: stage3 index fetch is hardened (stdout mode)" \
        || bad "${b}: stage3 index fetch does not route through dlv_fetch_retry"
done

# ── 11. the shared libs route through the hardened loop too ──────────────────
grep -q 'dlv_fetch_retry "\${url}" "\${dest}"' "${LIB}" \
    && ok "_download-lib.sh: dlv_fetch (checksums/DIGESTS sidecars) routes through dlv_fetch_retry" \
    || bad "_download-lib.sh: dlv_fetch no longer routes through dlv_fetch_retry"
grep -q 'getent hosts' "${LIB}" \
    && ok "_download-lib.sh: resolver probe uses getent hosts" \
    || bad "_download-lib.sh: dlv_dns_ok lost its getent probe"
grep -q 'dlv_fetch_retry "\$1" "\$2"' "${SA_LIB}" \
    && ok "_shared-assets-lib.sh: sa_fetch_default (stage3 seed) routes through dlv_fetch_retry" \
    || bad "_shared-assets-lib.sh: sa_fetch_default does not route through dlv_fetch_retry — the be.x86 stage3 death path is back"

echo "== done: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
