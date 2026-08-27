#!/usr/bin/env bash
# test-kind-profile-route-closure.sh — a curated kind profile must DEPLOY every
# in-cluster Service its own applied gateway ROUTES point at.
#
# THE DEFECT THIS CATCHES, verbatim. KIND_PROFILE=sso applied
# apps/20-gateway-fe.yaml — the front door, route table and all — but never
# apps/47-user-ui.yaml. So this route was live on every kind cluster:
#
#     - id: user-ui
#       uri: http://hugmesh-user-ui.hugmesh-frontend.svc.cluster.local:80
#       path: /user/**
#
# pointing at a Service nothing created. The profile/password API on the same
# surface (/bff/user/**) WAS routed and WAS allowed by the route-access seed, so
# `curl` proved the endpoint healthy while a browser got a 503 from a route into
# the void and the host shell's `user` remote could not fetch its remoteEntry.
# ArgoCD reported Healthy throughout: a route to nowhere is not a sync error.
#
# The sibling gate (test-kind-profile-app-closure.sh) could not see this — it
# checks that an Application's declared COMPANION apps are applied, and the
# gateway does not "declare" its route targets anywhere except the route table.
#
# The exemption list inside kind_route_closure.py is the deliberate half of this:
# the sso slice really does route ~14 tiers it does not deploy, and writing them
# down turns "what does this profile actually serve?" from folklore into a
# reviewable list with an anti-rot check behind it.
#
# Offline: python3 + PyYAML. No cluster, no kubectl, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
CHECKER="${HERE}/kind_route_closure.py"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# A guard that skips is a guard that never guards.
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required (refusing to skip)" >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: PyYAML required (pip install pyyaml) — refusing to skip" >&2; exit 1; }
[ -r "${CHECKER}" ] || { echo "FATAL: cannot read ${CHECKER}" >&2; exit 1; }

echo "== kind profile route closure =="
echo "-- positive: this repo's own bootstrap must be closed --"
if python3 "${CHECKER}" --repo "${REPO}"; then
  ok "the committed bootstrap profiles are route-closed"
else
  bad "the committed bootstrap profiles route to a Service they do not deploy (see above)"
fi

# ── NEGATIVE CONTROLS ───────────────────────────────────────────────────────
# Each is a PAIR: the defective bootstrap must FAIL and the pristine one must
# PASS. A lone "the bad one failed" proves nothing — a probe can fail for a
# reason unrelated to the property, which is how this repo's sibling closure gate
# spent a revision reporting theatre.
echo
echo "-- negative controls (each is a defect/no-defect PAIR) --"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT

probe() { # <out> <app-to-remove-or-empty>
  local out="$1" drop="${2:-}"
  if [ -n "${drop}" ]; then
    grep -v "^  ${drop}" "${REPO}/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh" > "${out}"
  else
    cp "${REPO}/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh" "${out}"
  fi
}

run_probe() { python3 "${CHECKER}" --repo "${REPO}" --bootstrap "$1" --quiet >/dev/null 2>&1; }

pair() { # <name> <bad> <good>
  if run_probe "$2"; then
    bad "control '$1': the DEFECTIVE probe was not caught"
  elif ! run_probe "$3"; then
    bad "control '$1': the CORRECTED probe also failed — the control cannot distinguish"
  else
    ok "control '$1': defective probe caught, corrected probe clean"
  fi
}

# 1. THE SHIPPED DEFECT: drop 47-user-ui.yaml and the /user/** route dangles.
probe "${T}/g1.sh"
probe "${T}/b1.sh" "47-user-ui.yaml"
if diff -q "${T}/g1.sh" "${T}/b1.sh" >/dev/null; then
  bad "control 'user-ui dropped': the fixture edit did not change the bootstrap — the control proves nothing"
else
  pair "user-ui dropped (the shipped defect)" "${T}/b1.sh" "${T}/g1.sh"
  # ...and it must name the RIGHT host, not fail for some unrelated reason.
  # NB: capture to a FILE first. `python3 … | grep -q` under `set -o pipefail`
  # reports the pipeline as failed because the checker legitimately exits 1 — the
  # grep's verdict would be thrown away. This repo has been bitten by that shape
  # more than once.
  python3 "${CHECKER}" --repo "${REPO}" --bootstrap "${T}/b1.sh" >"${T}/b1.out" 2>&1
  if grep -F 'hugmesh-user-ui.hugmesh-frontend' "${T}/b1.out" >/dev/null; then
    ok "control 'user-ui dropped': the failure names hugmesh-user-ui.hugmesh-frontend specifically"
  else
    bad "control 'user-ui dropped': the failure does not name the dangling host — it is failing for another reason"
  fi
fi

# 2. NO FALSE POSITIVE. Drop an Application whose Service is NOT a gateway route
#    target — 34-user-bff-db creates `user-bff-db`, which only user-bff dials
#    directly. The gate must stay clean. A gate that fails on every edit is
#    indistinguishable from a gate that works, and this is the half that tells
#    them apart.
#
#    (29-federation-api was the obvious candidate and is the WRONG one: it IS a
#    route target — 20-gateway-fe.yaml's `vanity-subdomain` route dials
#    hugmesh-federation-api directly — which the first run of this control
#    discovered by going red. Left recorded here so nobody "simplifies" it back.)
probe "${T}/b2.sh" "34-user-bff-db.yaml"
if run_probe "${T}/b2.sh"; then
  ok "control 'no false positive': removing a non-routed Application does NOT trip the route gate"
else
  bad "control 'no false positive': the gate fired for an app that is not a route target"
fi

# 3. a bootstrap with no *_APPS arrays at all must ABORT, not pass vacuously.
echo "# no arrays here" > "${T}/b3.sh"
if run_probe "${T}/b3.sh"; then
  bad "control 'empty bootstrap': a bootstrap with no profiles PASSED — vacuous green"
else
  ok "control 'empty bootstrap': a bootstrap with no profiles ABORTS instead of passing vacuously"
fi

# 4. SABOTAGE CONTROL. Strip the violation-recording line out of a copy of the
#    checker and require that control 1 then stops failing. If the controls still
#    "work" without the logic they exercise, they are theatre.
sed 's|^                violations.append($|                violations.append(  # sabotaged\n                    "") if False else None\n                _ = (|' \
  "${CHECKER}" > "${T}/sabotage.py" 2>/dev/null || true
python3 - "${CHECKER}" "${T}/sabotage.py" <<'PY'
import sys, pathlib, re
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
s = src.read_text()
# Remove the recording of a violation entirely; everything else stays identical.
s2 = re.sub(r"\n                violations\.append\(\n(?:.*\n)*?.*has no endpoints\"\)\n",
            "\n                continue\n", s, count=1)
assert s2 != s, "SABOTAGE TARGET NOT FOUND — the control cannot be built"
dst.write_text(s2)
PY
if [ $? -ne 0 ]; then
  bad "sabotage control: could not build the sabotaged checker (target line moved) — fix the control, do not delete it"
elif python3 "${T}/sabotage.py" --repo "${REPO}" --bootstrap "${T}/b1.sh" --quiet >/dev/null 2>&1; then
  ok "sabotage control: with the closure recording removed, the defective probe is NO LONGER caught"
else
  bad "sabotage control: the defective probe still fails with the closure logic removed — the controls measure something else"
fi

echo
echo "== kind profile route closure: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
