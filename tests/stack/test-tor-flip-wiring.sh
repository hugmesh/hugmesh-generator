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
# no e2e reached the onion at all. The onion serves :443 too, because https is the
# door (a secure context, the node's :443; docs/TOR-HIDDEN-SERVICE.md "Why :443"),
# and with ANUBIS=1 its http :80 door needs the gate's cookies without Secure
# (T16, #627).
#
# WHAT IS GRADED, AND HOW. tests/stack/tor_flip_wiring.py holds the model — 16
# checks, run against the real tree here and against staged mutants below. It
# executes wherever it can: make expands STACK_ENV/the profile; the entrypoint is
# RUN against a stub tor (publish, stop, crash); both compose healthchecks are
# EXECUTED against a sandbox; run.sh prints its own --via onion plan AND is run
# against a stub npx that records the environment playwright really receives and
# the summary it leaves (a skipped or empty run must FAIL); `make stack-onion` is
# run against served / absent / stale / malformed readouts; the mechanism wrapper
# (test-tor-onion-mechanism.sh) is run against stub harnesses; and the @via:onion
# step file is held to "no unproxied route to the mesh".
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
  ok "the repo tree satisfies the TOR=1 contract (16 checks)"
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
  cp "${REPO}/tests/stack/test-tor-onion-mechanism.sh" "${dst}/tests/stack/test-tor-onion-mechanism.sh"
  mkdir -p "${dst}/tests/e2e/specs" "${dst}/tests/e2e/steps" "${dst}/tests/e2e/features"
  cp "${REPO}/tests/e2e/specs/helpers.ts"        "${dst}/tests/e2e/specs/helpers.ts"
  cp "${REPO}"/tests/e2e/steps/*.ts               "${dst}/tests/e2e/steps/"
  # Only the @via:onion features: T15 grades exactly those scenarios' steps.
  # -a: one NUL byte would make grep skip a file and report it as a miss.
  local f
  while IFS= read -r f; do
    mkdir -p "${dst}/$(dirname "${f#"${REPO}"/}")"
    cp "${f}" "${dst}/${f#"${REPO}"/}"
  done < <(grep -rlaF '@via:onion' "${REPO}/tests/e2e/features" --include='*.feature')
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
sub("Makefile", "\$(if \$(strip \$(ANUBIS)),\$(if \$(strip \$(TOR_ONION_UPSTREAM)),, TOR_ONION_UPSTREAM='\$(STACK_TOR_ANUBIS_UPSTREAM)')\$(STACK_TOR_ANUBIS_COOKIE_ENV),)", "")
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
sub("tests/e2e/run.sh", "then TAGS='@via:onion and @env:docker'; else", "then TAGS=''; else")
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

# ── skeptic round (2026-09-23): each of these SURVIVED the first battery ─────
control N29-onion-env-not-exported T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", '  export SNAP_ONION_BASE_URL="\${ONION_BASE_URL}"\n  export SNAP_PROXY="\${ONION_PROXY}"\n', '')
PY

control N30-no-executed-nothing-backstop T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", 'if [ -n "\${ONION_SUMMARY}" ] && [ "\${rc}" -eq 0 ]; then', 'if false; then')
PY

control N31-stale-summary-vouches T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", '  rm -f "\${ONION_SUMMARY}"\n', '')
PY

control N32-caller-tags-or T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", 'else TAGS="(\${TAGS}) and @via:onion and @env:docker"; fi', 'else TAGS="(\${TAGS}) or @via:onion and @env:docker"; fi')
PY

control N33-caller-tags-unrestricted T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", 'else TAGS="(\${TAGS}) and @via:onion and @env:docker"; fi', 'else TAGS="\${TAGS}"; fi')
PY

control N34-stale-bootstrap-kept T10-readout-lifecycle <<PY
${MUT_LIB}
sub("tests/stack/tor/entrypoint.sh", ': > "\$NOTICE_LOG"\n', '')
PY

control N35-client-listens-loopback T9-socks-client <<PY
${MUT_LIB}
sub("tests/stack/tor/entrypoint.sh", "SocksPort 0.0.0.0:9050\n", "SocksPort 127.0.0.1:9050\n")
PY

control N36-client-accepts-anyone-first T9-socks-client <<PY
${MUT_LIB}
sub("tests/stack/tor/entrypoint.sh", "SocksPolicy accept 127.0.0.0/8\n", "SocksPolicy accept *\nSocksPolicy accept 127.0.0.0/8\n")
PY

control N37-run-stale-check-asks-the-client T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", "label=com.docker.compose.service=hugmesh-tor --filter", "label=com.docker.compose.service=hugmesh-tor-client --filter")
PY

control N38-stack-onion-asks-the-client T13-stack-onion <<PY
${MUT_LIB}
sub("Makefile", "--status running hugmesh-tor 2>/dev/null", "--status running hugmesh-tor-client 2>/dev/null")
PY

control N39-stack-onion-no-charset T13-stack-onion <<PY
${MUT_LIB}
sub("Makefile", "case \"\$\$base\" in *[!a-z2-7]*|'') base=bad ;; esac; ", "")
PY

control N40-run-no-charset T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", "  case \"\${base}\" in *[!a-z2-7]*|'') return 1 ;; esac\n", "")
PY

control N41-run-accepts-http T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", "    ''|https://*.onion) ;;", "    ''|http*://*.onion) ;;")
PY

control N42-apicontext-unguarded T15-onion-steps-proxied <<PY
${MUT_LIB}
sub("tests/e2e/specs/helpers.ts", "  if (process.env.SNAP_PROXY) {\n    throw new Error(", "  if (false) {\n    throw new Error(")
PY

control N43-step-calls-apicontext T15-onion-steps-proxied <<PY
${MUT_LIB}
sub("tests/e2e/steps/tor-onion.steps.ts", "  const page = await ctx.newPage();\n", "  const page = await ctx.newPage();\n  await apiContext(door.baseUrl);\n")
PY

control N44-step-takes-page-fixture T15-onion-steps-proxied <<PY
${MUT_LIB}
sub("tests/e2e/steps/tor-onion.steps.ts", "Then('the onion login page renders', async ({ world, ", "Then('the onion login page renders', async ({ world, page, ")
PY

control N45-onion-context-unproxied T15-onion-steps-proxied <<PY
${MUT_LIB}
sub("tests/e2e/specs/helpers.ts", "    proxy: { server: door.proxy, bypass: '<-loopback>' },\n", "")
PY

control N46-feature-untagged T15-onion-steps-proxied <<PY
${MUT_LIB}
sub("tests/e2e/features/platform/tor-onion-front-door.feature", "@env:docker @via:onion @service:login", "@env:docker @service:login")
PY

# The per-domain lane (#582, `make stack-e2e-tor-domains`) is counted on its own:
# untagging ITS one feature must go red even though the mesh-onion lane's scenario
# is still there, and the other way round (N46 above).
control N46b-domains-feature-untagged T15-onion-steps-proxied <<PY
${MUT_LIB}
sub("tests/e2e/features/platform/tor-onion-domains.feature", "@env:docker @via:onion-domains @service:login", "@env:docker @service:login")
PY

control N47-kind-scenarios-in-the-compose-lane T12-e2e-lane <<PY
${MUT_LIB}
sub("tests/e2e/run.sh", "then TAGS='@via:onion and @env:docker'; else", "then TAGS='@via:onion'; else")
PY

# ── #627: the Anubis gate's cookies on the onion's http door (T16) ───────────
control N48-cookie-flip-unthreaded T16-anubis-onion-cookie <<PY
${MUT_LIB}
sub("Makefile", "TOR_ONION_UPSTREAM='\$(STACK_TOR_ANUBIS_UPSTREAM)')\$(STACK_TOR_ANUBIS_COOKIE_ENV),),)", "TOR_ONION_UPSTREAM='\$(STACK_TOR_ANUBIS_UPSTREAM)'),),)")
PY

control N49-cookie-compose-literal T16-anubis-onion-cookie <<PY
${MUT_LIB}
sub("tests/stack/compose.local.yaml", "      COOKIE_SECURE: \${ANUBIS_COOKIE_SECURE:-true}\n", "      COOKIE_SECURE: \"true\"\n")
PY

control N50-cookie-compose-absent T16-anubis-onion-cookie <<PY
${MUT_LIB}
sub("tests/stack/compose.local.yaml", "      COOKIE_SECURE: \${ANUBIS_COOKIE_SECURE:-true}\n", "")
PY

control N51-cookie-insecure-everywhere T16-anubis-onion-cookie <<PY
${MUT_LIB}
sub("tests/stack/compose.local.yaml", "\${ANUBIS_COOKIE_SECURE:-true}", "\${ANUBIS_COOKIE_SECURE:-false}")
PY

control N52-cookie-caller-overridden T16-anubis-onion-cookie <<PY
${MUT_LIB}
sub("Makefile", "STACK_TOR_ANUBIS_COOKIE_ENV := \$(if \$(strip \$(ANUBIS_COOKIE_SECURE)),, ANUBIS_COOKIE_SECURE='false')", "STACK_TOR_ANUBIS_COOKIE_ENV :=  ANUBIS_COOKIE_SECURE='false'")
PY

control N53-cookie-flip-on-tor-alone T16-anubis-onion-cookie <<PY
${MUT_LIB}
sub("Makefile", "TOR_ONION_UPSTREAM='\$(STACK_TOR_ANUBIS_UPSTREAM)')\$(STACK_TOR_ANUBIS_COOKIE_ENV),),)", "TOR_ONION_UPSTREAM='\$(STACK_TOR_ANUBIS_UPSTREAM)'),)\$(STACK_TOR_ANUBIS_COOKIE_ENV),)")
PY

control N54-cookie-var-renamed-one-side T16-anubis-onion-cookie <<PY
${MUT_LIB}
sub("tests/stack/compose.local.yaml", "\${ANUBIS_COOKIE_SECURE:-true}", "\${ANUBIS_SECURE_COOKIE:-true}")
PY

# ── #624: a sibling module an onion step file imports is held to T15 too ─────
control N55-sibling-module-fetches T15-onion-steps-proxied <<PY
${MUT_LIB}
sub("tests/e2e/steps/onion-session.ts", "/** ROLE_FOO_BAR -> foo_bar", "export const leak = () => fetch('https://localhost:8488/bff/session');\n\n/** ROLE_FOO_BAR -> foo_bar")
PY

control N56-sibling-module-newcontext T15-onion-steps-proxied <<PY
${MUT_LIB}
sub("tests/e2e/steps/onion-session.ts", "/** ROLE_FOO_BAR -> foo_bar", "export const leak = (r: any) => r.newContext({});\n\n/** ROLE_FOO_BAR -> foo_bar")
PY

# The sibling scan reads every spelling of a relative specifier and follows
# siblings of siblings: each of these hid a fetch from the first version of the
# scan (single-quoted, extensionless, one hop only), found by the #633 skeptics.
control N57-sibling-double-quoted-import T15-onion-steps-proxied <<PY
${MUT_LIB}
sub("tests/e2e/steps/tor-onion.steps.ts", "from './onion-session';", 'from "./onion-session";')
sub("tests/e2e/steps/onion-session.ts", "/** ROLE_FOO_BAR -> foo_bar", "export const leak = () => fetch('https://localhost:8488/bff/session');\n\n/** ROLE_FOO_BAR -> foo_bar")
PY

control N58-sibling-js-suffix-import T15-onion-steps-proxied <<PY
${MUT_LIB}
sub("tests/e2e/steps/tor-onion.steps.ts", "from './onion-session';", "from './onion-session.js';")
sub("tests/e2e/steps/onion-session.ts", "/** ROLE_FOO_BAR -> foo_bar", "export const leak = () => fetch('https://localhost:8488/bff/session');\n\n/** ROLE_FOO_BAR -> foo_bar")
PY

control N59-transitive-sibling-fetches T15-onion-steps-proxied <<PY
${MUT_LIB}
open(root + "/tests/e2e/steps/onion-leak2.ts", "w").write("export const leak2 = () => fetch('https://localhost:8488/bff/session');\n")
sub("tests/e2e/steps/onion-session.ts", "import { effectiveRoles } from '../specs/rbac-route-access';", "import { effectiveRoles } from '../specs/rbac-route-access';\nexport { leak2 } from './onion-leak2';")
PY

control N60-dynamic-import-sibling-fetches T15-onion-steps-proxied <<PY
${MUT_LIB}
open(root + "/tests/e2e/steps/onion-leak3.ts", "w").write("export const leak3 = () => fetch('https://localhost:8488/bff/session');\n")
sub("tests/e2e/steps/tor-onion.steps.ts", "from './onion-session';", "from './onion-session';\nconst _leak3 = () => import(\"./onion-leak3.js\");")
PY

control N61-subdirectory-sibling-fetches T15-onion-steps-proxied <<PY
${MUT_LIB}
import os
os.makedirs(root + "/tests/e2e/steps/lib", exist_ok=True)
open(root + "/tests/e2e/steps/lib/leak4.ts", "w").write("export const leak4 = () => fetch('https://localhost:8488/bff/session');\n")
sub("tests/e2e/steps/onion-session.ts", "import { effectiveRoles } from '../specs/rbac-route-access';", "import { effectiveRoles } from '../specs/rbac-route-access';\nimport { leak4 } from '../steps/lib/leak4';")
PY

# ── the mechanism wrapper (#585): its verdict logic, not only its existence ──
control W1-success-line-ignored T14-mechanism-wrapper <<PY
${MUT_LIB}
sub("tests/stack/test-tor-onion-mechanism.sh", '  || fail "the harness exited 0 but never printed', '  || true "the harness exited 0 but never printed')
PY

control W2-rc-ignored T14-mechanism-wrapper <<PY
${MUT_LIB}
sub("tests/stack/test-tor-onion-mechanism.sh", '|| fail "the harness exited \${rc}"', '|| true "the harness exited \${rc}"')
PY

control W3-skip-exits-0 T14-mechanism-wrapper <<PY
${MUT_LIB}
sub("tests/stack/test-tor-onion-mechanism.sh", "  exit 2\n}", "  exit 0\n}")
PY

control W4-timeout-unnamed T14-mechanism-wrapper <<PY
${MUT_LIB}
sub("tests/stack/test-tor-onion-mechanism.sh", 'if [ "\${rc}" -eq 124 ] || [ "\${rc}" -eq 137 ]; then', 'if false; then')
PY

control W5-failure-as-skip T14-mechanism-wrapper <<PY
${MUT_LIB}
sub("tests/stack/test-tor-onion-mechanism.sh", 'echo "FAIL: \$*"\n  exit 1', 'echo "FAIL: \$*"\n  exit 2')
PY

control W6-no-opt-in T14-mechanism-wrapper <<PY
${MUT_LIB}
sub("tests/stack/test-tor-onion-mechanism.sh", '[ "\${HUGMESH_TOR_E2E:-}" = "1" ]', '[ 1 = 1 ]')
PY

control W7-success-unanchored T14-mechanism-wrapper <<PY
${MUT_LIB}
sub("tests/stack/test-tor-onion-mechanism.sh", "grep -a -E '^RESULT: +SUCCESS", "grep -a -E 'RESULT: +SUCCESS")
PY

control W8-no-timeout T14-mechanism-wrapper <<PY
${MUT_LIB}
sub("tests/stack/test-tor-onion-mechanism.sh", 'timeout --kill-after=20 "\${TIMEOUT_S}" bash', 'bash')
PY

control W9-no-tor-not-skipped T14-mechanism-wrapper <<PY
${MUT_LIB}
sub("tests/stack/test-tor-onion-mechanism.sh", '|| skip "no tor binary', '|| true "no tor binary')
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

# ── coexistence: the KIND lane's @via:onion scenario (#577, @env:kind) proxies
# through its own seam (the `page` fixture under a proxied project). It is not a
# compose-lane scenario, so T15 must not grade it — a planted one stays GREEN.
KIND="${WORK}/kind-coexist"; rm -rf "${KIND}"; stage "${KIND}"
mkdir -p "${KIND}/tests/e2e/features/platform"
cat > "${KIND}/tests/e2e/features/platform/tor-onion-kind-probe.feature" <<'FEAT'
@layer:gateway @env:kind @via:onion
Feature: planted kind-lane onion scenario
  @role:e2e-user
  Scenario: kind onion probe
    When I open the planted kind onion door
FEAT
cat > "${KIND}/tests/e2e/steps/planted-kind-onion.steps.ts" <<'STEPS'
When('I open the planted kind onion door', async ({ page }) => { await page.goto('/'); });
STEPS
python3 "${MODEL}" "${KIND}" >/dev/null 2>&1; KIND_RC=$?
if [ "${KIND_RC}" -eq 0 ]; then
  ok "coexistence: a kind-lane @env:kind @via:onion scenario is not graded as a compose-lane one"
else
  bad "coexistence: a planted kind-lane @via:onion scenario turned the model red (rc=${KIND_RC})"
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
