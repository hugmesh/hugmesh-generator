#!/usr/bin/env bash
# test-anubis-flip-wiring.sh — the INERT-TOGGLE gate for `make stack-up ANUBIS=1`.
#
# WHY THIS GATE EXISTS. Before the change it ships with, ANUBIS=1 was HALF a
# switch. `STACK_EGRESS_FLAGS` already read `$(ANUBIS)` to select compose's
# `anubis` profile, so the gate container came up and answered on :8923 — but:
#   * the knob was never DECLARED (`ANUBIS ?=` did not exist), so make expanded an
#     undefined variable to empty and the knob was invisible in the knob block;
#   * it threaded NO env, so admin-bff kept application.yml's defaults —
#     `hugmesh.anubis.enabled=false` and a management-url of
#     http://localhost:9090, which INSIDE that container is admin-bff itself and
#     not the gate. The superadmin Anubis console could therefore only ever
#     report "not enabled", with the gate running two containers away.
# Nothing failed. That is the shape this repo has shipped three times now (the
# gateway MFA trio, the AI-cloak lane needing BOTH the worker and the BFF flag,
# and this) — see tests/stack/test-mfa-flip-wiring.sh, whose structure this
# follows deliberately.
#
# WHAT IS GRADED, AND HOW. tests/stack/anubis_flip_wiring.py holds the model; it
# is run against the real tree here and against staged mutants below. Two rules
# it follows are the whole point:
#   * BEHAVIOUR, not source text. C3/C4 expand STACK_ENV with `make --eval` and
#     read what a bring-up would actually export. A grep for STACK_ANUBIS_ENV is
#     satisfied by a definition nothing threads — the exact defect.
#   * DERIVED, not listed. C6 finds the gate by looking for the compose service
#     that declares METRICS_BIND and takes the expected host AND port from it, so
#     renaming the service or moving its port cannot leave a stale constant green.
#
# NEGATIVE CONTROLS. Every check is exercised against a mutant that breaks
# exactly it, staged into a COPY — the repo tree is NEVER mutated, so an
# interrupted run cannot leave a planted defect behind (a hazard this repo has
# measured: see the mutation-testing notes on killed batteries). Each mutator
# PROVES IT LANDED and the control fails loudly if it did not: a no-op mutator
# reads exactly like an uncaught mutation and would send someone hardening a
# guard that was already fine.
#
# Offline. No docker, no cluster, no network. Tools: bash>=4, make, python3 +
# PyYAML.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODEL="${REPO}/tests/stack/anubis_flip_wiring.py"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

# ── preflight: refuse to produce a meaningless tally ─────────────────────────
for t in make python3; do
  command -v "${t}" >/dev/null 2>&1 || {
    echo "  FAIL ${t} is required and absent — this guard checked NOTHING" >&2; exit 2; }
done
python3 -c 'import yaml' 2>/dev/null || {
  echo "  FAIL PyYAML missing (pip install pyyaml) — this guard checked NOTHING" >&2; exit 2; }
[ -f "${MODEL}" ] || { echo "  FAIL missing model: ${MODEL}" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "== anubis flip wiring: ANUBIS=1 must reach every consumer =="

# ── positive: the real tree must satisfy the whole contract ──────────────────
REAL_OUT="$(python3 "${MODEL}" "${REPO}" 2>&1)"; REAL_RC=$?
echo "${REAL_OUT}" | sed 's/^/     /'
if [ "${REAL_RC}" -eq 3 ]; then
  echo
  echo "== anubis flip wiring: INCOMPLETE — a source the model needs is missing =="
  echo "   A green run without it would be a lie, so this is a FAIL."
  exit 1
fi
if [ "${REAL_RC}" -eq 0 ]; then
  ok "the repo tree satisfies the ANUBIS=1 wiring contract (8 checks)"
else
  bad "the repo tree does NOT satisfy the ANUBIS=1 wiring contract (see above)"
fi

# ── the mutant harness ───────────────────────────────────────────────────────
# stage <dir>  — a minimal tree the model can grade: the three files it reads.
stage() {
  local dst
  dst="$1"
  mkdir -p "${dst}/tests/stack" "${dst}/specs/cluster/manifests/admin-bff-api"
  cp "${REPO}/Makefile"                        "${dst}/Makefile"
  cp "${REPO}/tests/stack/compose.local.yaml"  "${dst}/tests/stack/compose.local.yaml"
  cp "${REPO}/specs/cluster/manifests/admin-bff-api/deployment.yaml" \
     "${dst}/specs/cluster/manifests/admin-bff-api/deployment.yaml"
}

# control <id> <expected-failing-check> <python mutator on stdin>
#   The mutator receives the staged root as argv[1]. It MUST raise if its anchor
#   is absent, so a mutation that did not land can never be reported as a
#   surviving defect.
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
  else
    case "${gout}" in
      *"FAIL ${want}"*) ok "${cid}: ${want} goes RED when its invariant is broken" ;;
      *) bad "${cid}: the model went red but NOT on ${want}"
         echo "${gout}" | sed 's/^/       /' ;;
    esac
  fi
}

echo
echo "-- negative controls: break the wiring, prove the model notices --"

control N1-unthreaded C3-env-on <<'PY'
import sys
p = sys.argv[1] + "/Makefile"; s = open(p).read()
# The classic shipped-dark shape: the variable is DEFINED and never threaded.
old = "$(STACK_MFA_ENV)$(STACK_ANUBIS_ENV)"
assert s.count(old) == 1, "N1 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, "$(STACK_MFA_ENV)"))
PY

control N2-undeclared C1-declared <<'PY'
import re, sys
p = sys.argv[1] + "/Makefile"; s = open(p).read()
new = re.sub(r"^ANUBIS\s*\?=\s*$", "# (declaration removed by N2)", s, count=1, flags=re.M)
assert new != s, "N2 did not land: no `ANUBIS ?=` line to remove"
open(p, "w").write(new)
PY

control N3-default-on C4-default-off <<'PY'
import sys
p = sys.argv[1] + "/Makefile"; s = open(p).read()
old = "STACK_ANUBIS_ENV := $(if $(strip $(ANUBIS)), ANUBIS_ENABLED='true',)"
assert s.count(old) == 1, "N3 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, "STACK_ANUBIS_ENV := ANUBIS_ENABLED='true'"))
PY

control N4-ungated-profile C2-profile <<'PY'
import sys
p = sys.argv[1] + "/Makefile"; s = open(p).read()
old = "$(if $(strip $(ANUBIS)),--profile anubis,)"
assert s.count(old) == 1, "N4 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, "--profile anubis"))
PY

control N5-hardcoded C5-interpolated <<'PY'
import sys
p = sys.argv[1] + "/tests/stack/compose.local.yaml"; s = open(p).read()
old = "      ANUBIS_ENABLED: ${ANUBIS_ENABLED:-false}\n"
assert s.count(old) == 1, "N5 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, '      ANUBIS_ENABLED: "true"\n'))
PY

control N6-shipped-default C6-target <<'PY'
import sys
p = sys.argv[1] + "/tests/stack/compose.local.yaml"; s = open(p).read()
# application.yml's own default: inside this container that is admin-bff itself.
old = "${ANUBIS_MANAGEMENT_URL:-http://hugmesh-anubis:9090}"
assert s.count(old) == 1, "N6 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, "${ANUBIS_MANAGEMENT_URL:-http://localhost:9090}"))
PY

control N7-wrong-port C6-target <<'PY'
import sys
p = sys.argv[1] + "/tests/stack/compose.local.yaml"; s = open(p).read()
# Right service, wrong listener — the PoW door, not the management one.
old = "${ANUBIS_MANAGEMENT_URL:-http://hugmesh-anubis:9090}"
assert s.count(old) == 1, "N7 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, "${ANUBIS_MANAGEMENT_URL:-http://hugmesh-anubis:8923}"))
PY

control N8-mgmt-published C7-mgmt-unpublished <<'PY'
import sys
p = sys.argv[1] + "/tests/stack/compose.local.yaml"; s = open(p).read()
old = '      - "${ANUBIS_HOST_PORT:-8923}:8923"\n'
assert s.count(old) == 1, "N8 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, old + '      - "9090:9090"\n'))
PY

control N9-cluster-drift C8-cluster-parity <<'PY'
import sys
p = sys.argv[1] + "/specs/cluster/manifests/admin-bff-api/deployment.yaml"
s = open(p).read()
assert "ANUBIS_ENABLED" in s, "N9 did not land: the cluster manifest never set it"
open(p, "w").write(s.replace("ANUBIS_ENABLED", "ANUBIS_DISABLED_BY_N9"))
PY

# ── the sources going missing must be INCOMPLETE, never green ────────────────
INC="${WORK}/incomplete"; rm -rf "${INC}"; stage "${INC}"
rm -f "${INC}/tests/stack/compose.local.yaml"
python3 "${MODEL}" "${INC}" >/dev/null 2>&1; INC_RC=$?
if [ "${INC_RC}" -eq 3 ]; then
  ok "N10: a missing source is INCOMPLETE (exit 3), not a silent pass"
else
  bad "N10: a missing source exited ${INC_RC} — it must be 3 (INCOMPLETE)"
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
echo "== anubis flip wiring: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
