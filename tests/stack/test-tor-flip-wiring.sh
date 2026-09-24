#!/usr/bin/env bash
# test-tor-flip-wiring.sh — the gate for `make stack-up TOR=1` and the Tor e2e lane
# (hugmesh-generator#576, #581, #586).
#
# WHY THIS GATE EXISTS. TOR=1 had the inert-toggle shape this repo keeps shipping
# (see test-anubis-flip-wiring.sh / test-mfa-flip-wiring.sh): the knob was
# CONSUMED by STACK_TOR_PROFILE and never declared, nothing parsed the
# hugmesh-tor service block, the published onion hostname outlived the container
# that served it (the Studio announced a dead .onion after every stack-down), the
# `make stack-onion` the Studio and the docs told people to run did not exist, and
# no e2e reached the onion at all. And a plain-http onion cannot boot the SPA: the
# gateway's CSP upgrade-insecure-requests upgrades every subresource to https
# (measured 2026-09-23 over a live onion), so the onion must serve :443 too.
#
# WHAT IS GRADED, AND HOW. tests/stack/tor_flip_wiring.py holds the model — 13
# checks, run against the real tree here and against staged mutants below. It
# executes wherever it can: make expands STACK_ENV/the profile; the entrypoint is
# RUN against a stub tor (publish, stop, crash); both compose healthchecks are
# EXECUTED against a sandbox; run.sh prints its own --via onion plan; `make
# stack-onion` is run against served / absent / stale / malformed readouts.
#
# NEGATIVE CONTROLS. Every check is exercised by at least one mutant that breaks
# exactly it, staged into a COPY — the repo tree is NEVER mutated, so an
# interrupted run cannot leave a planted defect behind. Each mutator PROVES IT
# LANDED (its anchor must occur exactly once) and the control fails loudly if it
# did not: a no-op mutator reads exactly like an uncaught mutation.
#
# Offline. No docker, no tor, no network, no node. Tools: bash>=4, make, sh,
# cmp, grep, python3 + PyYAML.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODEL="${REPO}/tests/stack/tor_flip_wiring.py"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

# ── preflight: refuse to produce a meaningless tally ─────────────────────────
for t in make python3 sh cmp grep; do
  command -v "${t}" >/dev/null 2>&1 || {
    echo "  FAIL ${t} is required and absent — this guard checked NOTHING" >&2; exit 2; }
done
python3 -c 'import yaml' 2>/dev/null || {
  echo "  FAIL PyYAML missing (pip install pyyaml) — this guard checked NOTHING" >&2; exit 2; }
[ -f "${MODEL}" ] || { echo "  FAIL missing model: ${MODEL}" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "== tor flip wiring: TOR=1 must reach every consumer, and the onion readout must be true =="

# ── positive: the real tree must satisfy the whole contract ──────────────────
REAL_OUT="$(python3 "${MODEL}" "${REPO}" 2>&1)"; REAL_RC=$?
echo "${REAL_OUT}" | sed 's/^/     /'
if [ "${REAL_RC}" -eq 3 ]; then
  echo
  echo "== tor flip wiring: INCOMPLETE — a source the model needs is missing =="
  echo "   A green run without it would be a lie, so this is a FAIL."
  exit 1
fi
if [ "${REAL_RC}" -eq 0 ]; then
  ok "the repo tree satisfies the TOR=1 contract (13 checks)"
else
  bad "the repo tree does NOT satisfy the TOR=1 contract (see above)"
fi

# ── the mutant harness ───────────────────────────────────────────────────────
# stage <dir> — a minimal tree the model can grade: exactly the files it reads.
stage() {
  local dst
  dst="$1"
  mkdir -p "${dst}/tests/stack/tor" "${dst}/tests/e2e" "${dst}/studio/hugmesh_studio/core"
  cp "${REPO}/Makefile"                          "${dst}/Makefile"
  cp "${REPO}/tests/stack/compose.local.yaml"    "${dst}/tests/stack/compose.local.yaml"
  cp "${REPO}/tests/stack/tor/Dockerfile"        "${dst}/tests/stack/tor/Dockerfile"
  cp "${REPO}/tests/stack/tor/entrypoint.sh"     "${dst}/tests/stack/tor/entrypoint.sh"
  cp "${REPO}/tests/e2e/run.sh"                  "${dst}/tests/e2e/run.sh"
  cp "${REPO}/studio/hugmesh_studio/core/local_stack_node.py" \
     "${dst}/studio/hugmesh_studio/core/local_stack_node.py"
}

# control <id> <expected-failing-check> <python mutator on stdin>
#   The mutator gets the staged root as argv[1] and MUST raise when its anchor is
#   not there exactly once, so a mutation that did not land can never be reported
#   as a surviving defect.
control() {
  local cid want dir mout mrc gout grc
  cid="$1"; want="$2"
  dir="${WORK}/${cid}"
  rm -rf "${dir}"; stage "${dir}"
  mout="$(python3 - "${dir}" 2>&1)"; mrc=$?
  if [ "${mrc}" -ne 0 ]; then
    bad "${cid}: the mutator did not land (${mout}) — the control proves nothing"
    return
  fi
  gout="$(python3 "${MODEL}" "${dir}" 2>&1)"; grc=$?
  if [ "${grc}" -eq 0 ]; then
    bad "${cid}: the model stayed GREEN with ${want} broken"
    echo "${gout}" | sed 's/^/       /'
  elif [ "${grc}" -eq 3 ]; then
    bad "${cid}: the model reported INCOMPLETE instead of failing ${want}"
    echo "${gout}" | sed 's/^/       /'
  else
    case "${gout}" in
      *"FAIL ${want}"*) ok "${cid}: ${want} goes RED when its invariant is broken" ;;
      *) bad "${cid}: the model went red but NOT on ${want}"
         echo "${gout}" | sed 's/^/       /' ;;
    esac
  fi
}

# Every mutator below is `sub(path, old, new)`: old must occur EXACTLY once.
MUT_LIB='
import re, sys
root = sys.argv[1]
def sub(rel, old, new, block=None):
    p = root + "/" + rel
    s = open(p).read()
    if block:
        head, sep, tail = s.partition(block)
        assert sep, "block anchor %r absent" % block
        body, sep2, rest = tail.partition("\n\n")
        assert body.count(old) == 1, "anchor %r occurs %d times in %s" % (old, body.count(old), block)
        s = head + sep + body.replace(old, new) + sep2 + rest
    else:
        assert s.count(old) == 1, "anchor %r occurs %d times" % (old, s.count(old))
        s = s.replace(old, new)
    open(p, "w").write(s)
'

echo
echo "-- negative controls: break the wiring, prove the model notices --"

control N1-undeclared T1-declared <<PY
${MUT_LIB}
s = open(root + "/Makefile").read()
new = re.sub(r"^TOR\s*\?=\s*\$", "# (declaration removed by N1)", s, count=1, flags=re.M)
assert new != s, "N1 did not land"
open(root + "/Makefile", "w").write(new)
PY

control N2-ungated-profile T2-profile-gated <<PY
${MUT_LIB}
sub("Makefile", "STACK_TOR_PROFILE := \$(if \$(strip \$(TOR)),--profile tor,)", "STACK_TOR_PROFILE := --profile tor")
PY

control N3-unthreaded-env T4-env <<PY
${MUT_LIB}
sub("Makefile", "\$(STACK_ANUBIS_ENV)\$(STACK_TOR_ENV) \\\\", "\$(STACK_ANUBIS_ENV) \\\\")
PY

control N4-anubis-ignored T4-env <<PY
${MUT_LIB}
sub("Makefile", "\$(if \$(strip \$(ANUBIS)),\$(if \$(strip \$(TOR_ONION_UPSTREAM)),, TOR_ONION_UPSTREAM='\$(STACK_TOR_ANUBIS_UPSTREAM)'),)", "")
PY

control N5-caller-overridden T4-env <<PY
${MUT_LIB}
sub("Makefile", "\$(if \$(strip \$(TOR_ONION_UPSTREAM)),, TOR_ONION_UPSTREAM='\$(STACK_TOR_ANUBIS_UPSTREAM)')", " TOR_ONION_UPSTREAM='\$(STACK_TOR_ANUBIS_UPSTREAM)'")
PY

control N6-gate-wrong-port T4-env <<PY
${MUT_LIB}
sub("Makefile", "STACK_TOR_ANUBIS_UPSTREAM := hugmesh-anubis:8923", "STACK_TOR_ANUBIS_UPSTREAM := hugmesh-anubis:9090")
PY

control N7-onion-unprofiled T5-onion-service <<PY
${MUT_LIB}
sub("tests/stack/compose.local.yaml", '  hugmesh-tor:\n    profiles: ["tor"]\n', '  hugmesh-tor:\n')
PY

control N8-tls-wrong-port T5-onion-service <<PY
${MUT_LIB}
sub("tests/stack/compose.local.yaml", "\${TOR_ONION_TLS_UPSTREAM:-hugmesh-https-front:8443}", "\${TOR_ONION_TLS_UPSTREAM:-hugmesh-https-front:8488}")
PY

control N9-no-wait-for-tls T6-depends-on-upstreams <<PY
${MUT_LIB}
sub("tests/stack/compose.local.yaml", "      hugmesh-https-front:\n        condition: service_started\n", "", block="\n  hugmesh-tor:\n")
PY

control N10-key-not-persisted T7-custody-and-readout <<PY
${MUT_LIB}
sub("tests/stack/compose.local.yaml", "      - tor-onion-keys:/var/lib/tor/hugmesh-onion\n", "      - tor-onion-keys:/var/lib/tor/keys\n")
PY

control N11-readout-moved T7-custody-and-readout <<PY
${MUT_LIB}
sub("tests/stack/compose.local.yaml", "      - ./tor-onion:/onion-out\n", "      - ./onion:/onion-out\n")
PY

control N12-healthcheck-trusts-any-file T8-healthchecks <<PY
${MUT_LIB}
sub("tests/stack/compose.local.yaml", "[ -s /onion-out/hostname ] && cmp -s /onion-out/hostname /var/lib/tor/hugmesh-onion/hostname && ", "[ -s /onion-out/hostname ] && ")
PY

control N13-client-on-every-interface T9-socks-client <<PY
${MUT_LIB}
sub("tests/stack/compose.local.yaml", '"127.0.0.1:\${TOR_SOCKS_HOST_PORT:-9050}:9050"', '"\${TOR_SOCKS_HOST_PORT:-9050}:9050"')
PY

control N14-client-open-proxy T9-socks-client <<PY
${MUT_LIB}
sub("tests/stack/tor/entrypoint.sh", "SocksPolicy reject *\n", "")
PY

control N15-stale-readout-survives-start T10-readout-lifecycle <<PY
${MUT_LIB}
sub("tests/stack/tor/entrypoint.sh", 'rm -f "\$OUT_DIR/hostname"\n# tor REFUSES', '# tor REFUSES')
PY

control N16-exec-tor-no-unpublish T10-readout-lifecycle <<PY
${MUT_LIB}
sub("tests/stack/tor/entrypoint.sh", '"\$TOR_BIN" -f "\$TORRC" &\nTOR_PID=\$!', 'exec "\$TOR_BIN" -f "\$TORRC"\nTOR_PID=\$!')
PY

control N17-no-https-port T10-readout-lifecycle <<PY
${MUT_LIB}
sub("tests/stack/tor/entrypoint.sh", "HiddenServicePort 443 \$TLS_UPSTREAM\n", "")
PY

control N18-crash-status-swallowed T10-readout-lifecycle <<PY
${MUT_LIB}
sub("tests/stack/tor/entrypoint.sh", 'unpublish\nexit "\$rc"', 'unpublish\nexit 0')
PY

control N19-down-leaves-tor T11-teardown-reaps <<PY
${MUT_LIB}
sub("Makefile", "--profile social --profile tor --profile anubis", "--profile social --profile anubis", block="\nstack-down:")
PY

control N20-probe-pointed-at-onion T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", '  export SNAP_PROXY="\${ONION_PROXY}"\n', '  export SNAP_PROXY="\${ONION_PROXY}"\n  export SNAP_BASE_URL="\${ONION_BASE_URL}"\n')
PY

control N21-http-onion T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", 'echo "https://\${raw}"', 'echo "http://\${raw}"')
PY

control N22-unrestricted-tags T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", "then TAGS='@via:onion'; else", "then TAGS=''; else")
PY

control N23-lane-without-via T12-e2e-lane <<PY
${MUT_LIB}
sub("Makefile", "bash tests/e2e/run.sh --bdd --env docker --via onion", "bash tests/e2e/run.sh --bdd --env docker")
PY

control N24-proxy-port-drift T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", 'ONION_PROXY="\${SNAP_PROXY:-socks5://127.0.0.1:\${TOR_SOCKS_HOST_PORT:-9050}}"', 'ONION_PROXY="\${SNAP_PROXY:-socks5://127.0.0.1:\${TOR_SOCKS_HOST_PORT:-9150}}"')
PY

control N25-stack-onion-trusts-stale T13-stack-onion <<PY
${MUT_LIB}
sub("Makefile", '	  if [ -z "\$\$running" ]; then \\\\', '	  if false; then \\\\')
PY

control N26-stack-onion-trusts-malformed T13-stack-onion <<PY
${MUT_LIB}
sub("Makefile", '	if [ "\$\$base" = "\$\$onion" ] || [ "\$\${#base}" -ne 56 ]; then \\\\', '	if false; then \\\\')
PY

control N27-run-trusts-stale-readout T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", '      die "--via onion: \${ONION_FILE} names', '      echo "--via onion: \${ONION_FILE} names')
PY

# ── the sources going missing must be INCOMPLETE, never green ────────────────
INC="${WORK}/incomplete"; rm -rf "${INC}"; stage "${INC}"
rm -f "${INC}/tests/stack/tor/entrypoint.sh"
python3 "${MODEL}" "${INC}" >/dev/null 2>&1; INC_RC=$?
if [ "${INC_RC}" -eq 3 ]; then
  ok "N28: a missing source is INCOMPLETE (exit 3), not a silent pass"
else
  bad "N28: a missing source exited ${INC_RC} — it must be 3 (INCOMPLETE)"
fi

# ── positive control: the harness is not just always-red ─────────────────────
CLEAN="${WORK}/clean"; rm -rf "${CLEAN}"; stage "${CLEAN}"
python3 "${MODEL}" "${CLEAN}" >/dev/null 2>&1; CLEAN_RC=$?
if [ "${CLEAN_RC}" -eq 0 ]; then
  ok "positive control: an UNMUTATED staged copy passes (the mutants are what bite)"
else
  bad "positive control: an unmutated staged copy failed (rc=${CLEAN_RC}) — staging is wrong, every control above is meaningless"
fi

echo
echo "== tor flip wiring: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
