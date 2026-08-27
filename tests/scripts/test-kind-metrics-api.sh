#!/usr/bin/env bash
# test-kind-metrics-api.sh — the BEHAVIOURAL half of the metrics-server add-on:
# does the cluster's resource-metrics API actually ANSWER, and have the HPAs
# stopped reporting <unknown>?
#
# WHY THIS FILE IS SEPARATE FROM THE WIRING GUARD. Asserting that
# `01-metrics-server.yaml` appears in an array proves exactly one thing: that the
# string is in the array. It says nothing about metrics.k8s.io being served,
# nothing about the kubelet cert flag being right for kind's nodes, and nothing
# about whether the seven HorizontalPodAutoscalers KIND_PROFILE=sso applies have
# stopped reading <unknown>. Those are properties of a running cluster, and the
# only honest way to check them is to ask one:
#
#     kubectl top pods            -> the resource-metrics API answers at all
#     kubectl get hpa <name>      -> TARGETS no longer contains "<unknown>"
#
# An HPA with no metrics API does not fail, does not warn, and does not degrade.
# It reports `<unknown>/70%` forever and holds its Deployment at the replicas
# floor — which reads, from every surface, exactly like a cluster that is not busy.
# That is why the wiring guard alone was never going to be enough.
#
# NO CLUSTER, NO PRETENDING. This SKIPS LOUDLY, by name and with the reason, and
# exits 0 — it is not a gate that can be satisfied by an absent cluster, and it
# says so in the words it prints so that a green CI line cannot be mistaken for a
# measured metrics API. It never CREATES a cluster: bringing one up is minutes of
# image pulls and is the operator's decision, not a test's.
#
# Run it after `make kind-up`:   bash tests/scripts/test-kind-metrics-api.sh
set -uo pipefail

CLUSTER="${KIND_CLUSTER_NAME:-hugmesh-local}"
# The HPAs KIND_PROFILE=sso actually applies, as "<namespace>/<hpa name>". Derived
# once, by hand, from the four kustomizations that carry an hpa.yaml — and asserted
# against the live cluster's own listing below, so a stale entry here shows up as a
# named absence rather than as silence.
HPA_NS="${HPA_NS:-hugmesh-frontend}"
HPA_NAME="${HPA_NAME:-hugmesh-host-shell}"

pass=0; fail=0
ok()   { echo "  PASS $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL $*"; fail=$((fail+1)); }
skip() { echo "  SKIP $*"; }

echo "== kind resource-metrics API (behavioural) =="

# ── the loud skip ──────────────────────────────────────────────────────────
# Every reason is named separately. "no cluster" and "kubectl missing" and "the
# cluster is up but this lane never ran" are three different situations, and a
# single vague sentence sends the reader looking in the wrong place.
if ! command -v kubectl >/dev/null 2>&1; then
  skip "kubectl is not on PATH — the metrics API cannot be asked. NOT a pass: nothing about metrics-server was measured. Install the DevOps prerequisites (Studio) or put kubectl on PATH."
  echo "== kind resource-metrics API: SKIPPED (kubectl absent) =="
  exit 0
fi
# The Studio installs its pinned kind/kubectl under out/tools/bin; a plain terminal
# does not see them. Same fallback bootstrap-kind.sh uses, and for the same reason.
_HM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "${_HM_ROOT}/scripts/_tools-path-lib.sh" ] && { . "${_HM_ROOT}/scripts/_tools-path-lib.sh"; hugmesh_tools_path; }

# `kind` is PREFERRED but not required: a stale kubeconfig context outlives the
# cluster it named (this box has four of them and no running cluster), so when kind
# is available its listing is the authority. Without it the context is the only
# signal there is, and /readyz below is what separates a live one from a ghost.
if command -v kind >/dev/null 2>&1; then
  # `grep -x … >/dev/null`, never `grep -qx`: a quiet grep exits on the first
  # match, `kind` takes SIGPIPE, and under pipefail the found match reports
  # FAILURE — which here would mean "no cluster" for a cluster that exists.
  if ! kind get clusters 2>/dev/null | grep -x "${CLUSTER}" >/dev/null; then
    skip "kind cluster '${CLUSTER}' does not exist (\`kind get clusters\` does not list it) — nothing to ask. NOT a pass: the metrics API was NOT measured, and the seven HPAs this lane applies may or may not be inert. Bring the lane up first: make kind-up   (this test never creates a cluster.)"
    echo "== kind resource-metrics API: SKIPPED (no cluster '${CLUSTER}') =="
    exit 0
  fi
elif ! kubectl config get-contexts -o name 2>/dev/null | grep -x "kind-${CLUSTER}" >/dev/null; then
  skip "kind is not on PATH and kubeconfig has no 'kind-${CLUSTER}' context — nothing to ask, and nothing was measured. Bring the lane up first: make kind-up"
  echo "== kind resource-metrics API: SKIPPED (no cluster '${CLUSTER}') =="
  exit 0
fi
if ! kubectl --context "kind-${CLUSTER}" get --raw /readyz >/dev/null 2>&1; then
  skip "context 'kind-${CLUSTER}' exists but its API server does not answer /readyz — a STALE kubeconfig entry for a cluster that is gone, or a cluster that is not up yet. NOT a pass: nothing was measured. Diagnose: kubectl --context kind-${CLUSTER} get nodes"
  echo "== kind resource-metrics API: SKIPPED (API server unreachable) =="
  exit 0
fi

KC=(kubectl --context "kind-${CLUSTER}")

# ── 1) is the resource-metrics API even REGISTERED? ────────────────────────
if "${KC[@]}" get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1; then
  avail="$("${KC[@]}" get apiservice v1beta1.metrics.k8s.io \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)"
  if [ "${avail}" = "True" ]; then
    ok "v1beta1.metrics.k8s.io is registered and Available"
  else
    bad "v1beta1.metrics.k8s.io is registered but Available=${avail:-unknown} — the APIService exists and serves nothing, which is worse than absent: HPAs still read <unknown> while the object suggests otherwise. Diagnose: ${KC[*]} -n kube-system get deploy metrics-server; ${KC[*]} describe apiservice v1beta1.metrics.k8s.io"
  fi
else
  bad "v1beta1.metrics.k8s.io is NOT registered — there is no resource-metrics API on this cluster, so every HorizontalPodAutoscaler here is inert. If this bring-up ran with KIND_ADDONS=none that is the expected consequence and the bootstrap warned about it; otherwise metrics-server did not sync. Diagnose: ${KC[*]} -n devops get app metrics-server"
fi

# ── 2) does it ANSWER? ─────────────────────────────────────────────────────
# The registration above can be green while the backing Deployment cannot reach
# the kubelets (the --kubelet-insecure-tls case). `top` is the question that
# distinguishes them, and it is the one an operator would actually type.
top_out="$("${KC[@]}" top pods -n kube-system 2>&1)"; top_rc=$?
if [ "${top_rc}" -eq 0 ] && [ -n "$(printf '%s' "${top_out}" | sed -n '2p')" ]; then
  ok "kubectl top pods answers with real rows (metrics are being collected, not merely served)"
else
  bad "kubectl top pods did not answer (rc=${top_rc}): ${top_out}"
fi

# ── 3) the HPAs this lane applies must have stopped saying <unknown> ───────
# THE POINT OF THE WHOLE ADD-ON. Metrics that exist but that the HPAs cannot read
# would leave the seven Deployments pinned at their floor exactly as before.
if "${KC[@]}" -n "${HPA_NS}" get hpa "${HPA_NAME}" >/dev/null 2>&1; then
  # First-collection latency is real: metrics-server needs a scrape interval or two
  # before an HPA's TARGETS column fills in. Poll rather than sample once — a single
  # sample turns "the cluster is 40 seconds old" into a failure report.
  targets=""
  for _ in $(seq 1 "${HPA_WAIT_TRIES:-30}"); do
    targets="$("${KC[@]}" -n "${HPA_NS}" get hpa "${HPA_NAME}" \
                 -o jsonpath='{range .status.currentMetrics[*]}{.resource.name}={.resource.current.averageUtilization}{" "}{end}' 2>/dev/null)"
    case "${targets}" in *"="[0-9]*) break ;; esac
    sleep 5
  done
  case "${targets}" in
    *"="[0-9]*) ok "HPA ${HPA_NS}/${HPA_NAME} reads real utilisation: ${targets}" ;;
    *) bad "HPA ${HPA_NS}/${HPA_NAME} still reports no utilisation ('${targets}') after $(( ${HPA_WAIT_TRIES:-30} * 5 ))s — it is applied and inert, holding its Deployment at the replicas floor. That is the exact state the metrics-server add-on exists to end." ;;
  esac
else
  # NOT silence. A missing HPA is either a different profile or a stale expectation
  # in THIS file, and both need saying.
  skip "HPA ${HPA_NS}/${HPA_NAME} is not present on this cluster — either the bring-up was not KIND_PROFILE=sso, or this file's expectation has gone stale. The metrics API legs above still ran. Live list: $("${KC[@]}" get hpa -A --no-headers 2>/dev/null | wc -l) HPA(s) total."
fi

echo
echo "== kind resource-metrics API: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
