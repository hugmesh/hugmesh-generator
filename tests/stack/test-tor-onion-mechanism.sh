#!/usr/bin/env bash
# test-tor-onion-mechanism.sh — the census-named, opt-in wrapper around
# tests/stack/tor-onion-e2e.sh (hugmesh-generator#585).
#
# WHAT IT PROVES. tor-onion-e2e.sh mints a real v3 onion for a loopback HTTP
# backend with the HOST tor daemon and fetches it back over the PUBLIC Tor network
# through tor's SOCKS5 port (curl --socks5-hostname, the Tor Browser path). That
# is the MECHANISM under every onion this repo publishes — the compose stack's
# hugmesh-tor (TOR=1), the node `tor` optional service and the tor-onion go-live
# provider. It proves the mechanism, not the stack: the stack's onion is the
# @via:onion e2e scenario (`make stack-e2e-tor`, #576).
#
# WHY A WRAPPER. The harness passed live (2026-09-23: bootstrapped 100% in 9 s,
# marker over Tor after 118 s, rc=0) yet nothing invoked it, and its name
# (`*-e2e.sh`) sits outside tests/scripts/test-guard-integrity.sh's census
# (`test-*.sh` / `*_test.sh`), so the "every guard is wired" gate could not see it.
# This file is inside the census and wired by `make stack-tor-mechanism-check`.
#
# EXIT STATUS — never a green that checked nothing:
#   0  the harness exited 0 AND printed its SUCCESS line (both; either alone is a FAIL)
#   1  FAIL: the harness failed, timed out, or claimed success it did not print
#   2  SKIPPED-LOUDLY, verified NOTHING: not opted in (HUGMESH_TOR_E2E=1), no tor
#      binary, a missing tool, or no reachable Tor network (tor never bootstrapped)
#
# NOT pre-merge gated, on purpose: it needs the public Tor network and minutes of
# wall clock, and no shell-suites image carries tor. It is listed in
# test-guard-integrity.sh's PREMERGE_UNGATED with that reason.
#
# Knobs: HUGMESH_TOR_E2E=1 (the opt-in; the make target sets it), TOR_BIN,
# TOR_MECHANISM_TIMEOUT (seconds, default 420 — the harness's own worst case is
# ~120 s boot + 20 fetches x (90 s max + 6 s)), TOR_MECHANISM_HARNESS (the script
# to run; exists so the wrapper's own verdict logic can be exercised against stub
# harnesses). Everything else (SOCKS_PORT, BACKEND_PORT, ...) passes through.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="${TOR_MECHANISM_HARNESS:-${REPO}/tests/stack/tor-onion-e2e.sh}"
TIMEOUT_S="${TOR_MECHANISM_TIMEOUT:-420}"

skip() {
  echo "SKIPPED-LOUDLY: $* — the Tor onion mechanism was verified NOTHING (exit 2, never 0)"
  exit 2
}
fail() {
  echo "FAIL: $*"
  exit 1
}

[ "${HUGMESH_TOR_E2E:-}" = "1" ] \
  || skip "opt-in only: it needs the PUBLIC Tor network and several minutes. Run: make stack-tor-mechanism-check (or HUGMESH_TOR_E2E=1 bash $0)"

tor_bin="${TOR_BIN:-/usr/bin/tor}"
if [ ! -x "${tor_bin}" ]; then tor_bin="$(command -v tor 2>/dev/null || true)"; fi
[ -n "${tor_bin}" ] && [ -x "${tor_bin}" ] \
  || skip "no tor binary on this host (set TOR_BIN=, or install tor)"
for t in curl python3 timeout; do
  command -v "${t}" >/dev/null 2>&1 || skip "${t} is required and absent"
done
[ -f "${HARNESS}" ] || fail "the harness ${HARNESS} is missing"
case "${TIMEOUT_S}" in ''|*[!0-9]*) fail "TOR_MECHANISM_TIMEOUT='${TIMEOUT_S}' is not a number of seconds" ;; esac

echo "== tor onion mechanism: ${HARNESS##"${REPO}"/} with ${tor_bin} ($("${tor_bin}" --version 2>/dev/null | head -n 1)), timeout ${TIMEOUT_S}s =="
out="$(TOR_BIN="${tor_bin}" timeout --kill-after=20 "${TIMEOUT_S}" bash "${HARNESS}" 2>&1)"
rc=$?
printf '%s\n' "${out}" | sed 's/^/   /'

if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
  fail "the harness did not finish within ${TIMEOUT_S}s (rc=${rc}) — a hung onion fetch is a failure, not a skip"
fi
# No route to the Tor network at all is the environment, not the mechanism: the
# harness never got a bootstrapped tor to test with. Anything after bootstrap is
# the mechanism's to answer for.
if [ "${rc}" -ne 0 ] && printf '%s\n' "${out}" | grep -a -F 'did not reach Bootstrapped 100%' >/dev/null; then
  skip "tor never bootstrapped (no reachable Tor network from this host)"
fi
[ "${rc}" -eq 0 ] || fail "the harness exited ${rc}"
printf '%s\n' "${out}" | grep -a -E '^RESULT: +SUCCESS \(marker returned over Tor\)$' >/dev/null \
  || fail "the harness exited 0 but never printed its SUCCESS line — a status without the evidence is not a pass"
echo "PASS: a v3 onion was minted and its marker fetched back over the live Tor network"
exit 0
