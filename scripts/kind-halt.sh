#!/usr/bin/env bash
# kind-halt.sh — the DevOps lane's NON-DESTRUCTIVE stop, its resume, and its status.
#
# WHY THIS EXISTS (hugmesh-generator#356, decision 44 = (a), answered 2026-09-17).
# Until now the kind lane had exactly one control — `Delete DevOps lane` -> `make
# kind-down` -> `kind delete cluster`. There was no way to stop the lane without
# destroying it, and `kind` itself has no pause verb. The operator chose the REAL
# halt over the recommended delete-only slice:
#
#     scale the mesh workloads to 0 AND suspend ArgoCD auto-sync.
#
# The "AND" is the whole design. A scale-only halt would LIE: every one of the 98
# files in specs/cluster/apps/ carries `syncPolicy.automated {prune, selfHeal}`
# (measured 2026-09-17: 98 of 98 app files, and 24 of 24 live Applications), so
# ArgoCD scales anything we zero straight back up. And a suspend that is never
# undone is worse than no halt at all, because the cluster then silently stops
# tracking git. So this script is a matched pair, and it RECORDS what it moved so
# `resume` can put back exactly that and nothing else.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT THIS SCRIPT WILL NOT DO, and why each one is measured rather than assumed
# ─────────────────────────────────────────────────────────────────────────────
#
# 1. IT NEVER `docker stop`s THE NODE CONTAINER. `kind get clusters` still NAMES a
#    stopped cluster, so specs/cluster/bootstrap/kind-local/bootstrap-kind.sh:362
#    takes its "already exists — reusing it" branch and then hangs on an API server
#    that is never coming back (scripts/kind-doctor.sh:135-139 carries the same
#    finding). A "stop" implemented that way manufactures a zombie and costs the
#    operator a full bring-up. This script only ever scales workloads.
#
# 2. IT NEVER SWEEPS CONTAINERS BY THE `hugmesh-local` PREFIX. That name means TWO
#    different things on this host: the docker COMPOSE project
#    (studio/hugmesh_studio/core/local_stack_node.py:69 `_COMPOSE_PROJECT`) and the
#    KIND cluster (:111 `KIND_CLUSTER_DEFAULT`), and the kind node container is
#    `hugmesh-local-control-plane`, which begins with it. A prefix sweep would take
#    out the operator's compose mesh. The ONE docker call below names ONE exact
#    container, derived from the resolved cluster name, and only ever INSPECTS it.
#
# 3. IT NEVER READS A FAILED CENSUS AS "NOTHING THERE". tests/scripts/run-ungated-
#    lane.sh:60-91 draws this line and exits 5 for it: *"A census that errors is NOT
#    an empty census: before 2026-09-16 the two were indistinguishable."* A dead
#    docker socket, a broken kubeconfig or an API server that will not answer is
#    exit 5 — REFUSED — never "no cluster, nothing to do".
#
# 4. IT NEVER ACTS ON "WHATEVER CONTEXT IS CURRENT". Every kubectl call is pinned to
#    `--context kind-<cluster>` (the convention scripts/kind-doctor.sh:164 already
#    uses). Without that pin a halt run with a work kubeconfig loaded would scale
#    down someone else's cluster, which is the worst outcome this script could have.
#
# 5. IT NEVER SCALES THE THINGS ITS OWN RESUME DEPENDS ON. See THE MANDATORY FLOOR.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE MANDATORY FLOOR — namespaces this script refuses to scale, at any setting
# ─────────────────────────────────────────────────────────────────────────────
#
# `KIND_HALT_SKIP_NS` can ADD namespaces to the skip list. It cannot remove one of
# these, because each is a way to wedge the cluster so RESUME ITSELF cannot run:
#
#   kyverno            MEASURED on the live cluster 2026-09-17, and the sharpest of
#                      the five. `kyverno-resource-validating-webhook-cfg`'s webhook
#                      `validate.kyverno.svc-fail` has failurePolicy=Fail over
#                          apps/v1  deployments, statefulsets, daemonsets
#                          operations CONNECT, CREATE, DELETE, UPDATE
#                      with a namespaceSelector excluding only kube-system and
#                      kyverno. A scale IS an UPDATE on apps/v1. So the moment
#                      kyverno's own Deployment reaches 0 replicas, every subsequent
#                      scale in every other namespace fails admission — the halt
#                      wedges half-done and the resume can never scale anything back.
#   kube-system        coredns and friends. No in-cluster DNS, no resume.
#   kube-public        cluster-owned, never the mesh's.
#   kube-node-lease    node heartbeats.
#   local-path-storage the PVC provisioner (`local-path-provisioner`). Without it
#                      nothing re-binds when the workloads come back.
#   <ARGOCD_NS>        ArgoCD itself. `resume` un-suspends THROUGH it, and a
#                      suspended Application does not reconcile anyway, so scaling
#                      the control plane buys nothing and risks the only path back.
#
# DAEMONSETS ARE NEVER TOUCHED, in any namespace. A DaemonSet has no replica count
# to zero; halting one means editing its nodeSelector, which is a mutation this
# script would then have to reverse exactly. Out of scope, and said out loud in the
# output rather than quietly skipped. On this cluster that leaves the ingress-nginx
# controller, kindnet, kube-proxy and local-path-provisioner running — four pods.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHERE THE STATE LIVES, and why it is not a file on the host
# ─────────────────────────────────────────────────────────────────────────────
#
# A ConfigMap, `hugmesh-kind-halt` in <ARGOCD_NS>, holding one key `halt.json`.
#
# The requirement is that a halted cluster must be resumable from the SHELL, with no
# Studio running — `make kind-resume` does exactly that, and reads this. A host-side
# file would also satisfy that, so the tie-breaker is staleness: a record inside the
# cluster CANNOT outlive the cluster it describes. Delete and recreate the cluster
# and the record is gone with it, which is correct — there is nothing to resume. A
# host-side file would survive that and describe a cluster that no longer exists.
#
# The one case the in-cluster record does not cover is a node that died (a docker
# daemon restart kills it). Then the whole cluster's state is gone, not just the
# record, and the fix is `make kind-down && make kind-up` — which is what
# kind-doctor.sh already prescribes for that exact state.
#
# ─────────────────────────────────────────────────────────────────────────────
# RESUME RESTORES WHAT WAS HALTED, NOT "EVERYTHING"
# ─────────────────────────────────────────────────────────────────────────────
#
# An Application that was ALREADY suspended before the halt — because someone was
# debugging it — is recorded as `was_automated: false`, is never touched by the
# halt, and is still suspended after the resume. `resume` re-arms an Application
# only when BOTH hold: the record says we suspended it, AND it is still suspended
# now. Same for workloads: a workload someone scaled up by hand while the lane was
# halted is left alone and reported, not stomped back down and up.
#
# THE TWO STANDING REDS get named, not hidden. #352 (`external-secrets-config`,
# Degraded) and #354 (harbor) are exactly the Applications a halt can freeze
# mid-flight, so the record stores each Application's sync AND health status at the
# moment it froze, and every rendering of the record flags any that were not
# Synced/Healthy. A halt must not make a standing red harder to diagnose.
#
# ─────────────────────────────────────────────────────────────────────────────
# EXIT CODES
# ─────────────────────────────────────────────────────────────────────────────
#   0  done
#   2  usage, or a tool this script needs is not installed
#   3  refused: there is no kind cluster of that name — nothing to halt
#   4  refused: precondition (already halted; resume with no halt record)
#   5  refused: THE CENSUS COULD NOT BE TAKEN — the run-ungated-lane.sh:60-91
#      contract. Dead docker socket, broken kubeconfig, API server silent, or the
#      node container is not running while `kind` still names the cluster.
#   6  partial: the census was fine but something did not move. The record is KEPT
#      so a re-run finishes the job; the output names every straggler.
#
# HOST TRAPS this file is written around: bash 5.3 dies on `local a=$1 b=$a` under
# `set -u` (every name is localised BEFORE the assignments run), so every helper
# declares ONE name per `local`. `| grep -q` under pipefail can report failure on a
# match it found (SIGPIPE), so no `grep -q` appears in a pipeline here. `grep` fails
# OPEN on a NUL byte, so every grep is `grep -a`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#: ONE reader of the override, exactly as local_stack_node.py:125 and
#: bootstrap-kind.sh:51 do it, so a probe can never disagree with the verb.
CLUSTER_NAME="${KIND_CLUSTER_NAME:-hugmesh-local}"
NODE="${CLUSTER_NAME}-control-plane"
KCTX="${KIND_HALT_CONTEXT:-kind-${CLUSTER_NAME}}"
ARGOCD_NS="${ARGOCD_NS:-devops}"
STATE_CM="${KIND_HALT_STATE_CONFIGMAP:-hugmesh-kind-halt}"
STATE_KEY="halt.json"
#: How long to let a GitOps parent re-assert a suspend before re-checking. Only a
#: repo-recursing root (HUGMESH_GITOPS_ROOT_RECURSE=1) or an ApplicationSet can do
#: that; on this cluster neither applies. Tests set it to 0.
SETTLE_S="${KIND_HALT_SETTLE_S:-3}"

#: Cannot be lowered by KIND_HALT_SKIP_NS — see THE MANDATORY FLOOR above. Each
#: entry is a way to make `resume` itself impossible.
MANDATORY_SKIP_NS="kube-system kube-public kube-node-lease local-path-storage kyverno ${ARGOCD_NS}"
SKIP_NS="${MANDATORY_SKIP_NS} ${KIND_HALT_SKIP_NS:-}"

# shellcheck source=scripts/_tools-path-lib.sh
if [ -r "${SCRIPT_DIR}/_tools-path-lib.sh" ]; then
  . "${SCRIPT_DIR}/_tools-path-lib.sh"; hugmesh_tools_path
fi

TMPDIR_HALT=""
cleanup() { [ -n "${TMPDIR_HALT}" ] && rm -rf "${TMPDIR_HALT}"; return 0; }
trap cleanup EXIT

say()   { printf '%s\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# REFUSED is the word every one of these prints, so an operator grepping a log
# cannot mistake a refusal for a failure to try.
die() {
  local code
  code="$1"
  shift
  printf 'REFUSED (exit %s): %s\n' "${code}" "$*" >&2
  exit "${code}"
}

usage() {
  cat <<'USAGE'
usage: kind-halt.sh <halt|resume|status>

  halt    suspend ArgoCD auto-sync on every Application that has it, then scale the
          mesh's Deployments and StatefulSets to 0. The cluster, its volumes, its
          Vault KV and its Casdoor identities are all KEPT. Records what it moved.
  resume  put back exactly what `halt` recorded — the replica counts it zeroed and
          the auto-sync it suspended. Anything suspended for another reason stays
          suspended.
  status  print the halt record (or say there is none). Read-only.

environment:
  KIND_CLUSTER_NAME        cluster to act on (default hugmesh-local). ONE cluster.
  ARGOCD_NS                where ArgoCD and the halt record live (default devops).
  KIND_HALT_SKIP_NS        EXTRA namespaces to leave running. Additive only: it
                           cannot unset the mandatory floor (see the header).
  KIND_HALT_CONTEXT        override the pinned kubectl context (default kind-<name>).
USAGE
}

# ── the census ───────────────────────────────────────────────────────────────
# READ ONLY, and fail-closed at every step. This is the run-ungated-lane.sh:60-91
# contract in its second form: there the question was "is a footprint present?",
# here it is "is THE cluster present and answering?", but the refusal that matters
# is identical — a census that ERRORS is not a census that found nothing.
require_tools() {
  local bin
  for bin in kind docker kubectl python3; do
    command -v "${bin}" >/dev/null 2>&1 || \
      die 2 "missing required tool: ${bin} (this control cannot act without it, and will not guess)"
  done
}

# Sets CENSUS_ERR on failure. Never echoes a cluster list it could not read.
census() {
  local out
  local errf
  local node_state
  errf="${TMPDIR_HALT}/census.err"

  # (1) does kind know this cluster? A FAILING `kind get clusters` is exit 5, not
  #     "no cluster" — the distinction this whole contract exists for.
  if ! out="$(kind get clusters 2>"${errf}")"; then
    CENSUS_ERR="kind get clusters failed: $(head -n 1 "${errf}" | cut -c1-160)"
    return 5
  fi
  # grep -ax: -a because grep fails OPEN on a NUL byte; -x so `hugmesh-local` never
  # matches `hugmesh-local-2`. Output drained to /dev/null rather than `grep -q`,
  # because -q closes the pipe early and SIGPIPE under pipefail can report failure
  # on a match it DID find.
  if ! printf '%s\n' "${out}" | grep -ax "${CLUSTER_NAME}" >/dev/null; then
    CENSUS_ERR=""
    return 3
  fi

  # (2) is the node container actually running? `kind get clusters` NAMES a stopped
  #     cluster (bootstrap-kind.sh:362 / kind-doctor.sh:135-139), so a cluster that
  #     kind lists but whose node is dead is the zombie, and it is exit 5 — refusing
  #     is the point. ONE exact container name; never a prefix, never `docker ps`.
  if ! node_state="$(docker inspect -f '{{.State.Status}}' "${NODE}" 2>"${errf}")"; then
    CENSUS_ERR="docker inspect ${NODE} failed: $(head -n 1 "${errf}" | cut -c1-160)"
    return 5
  fi
  if [ "${node_state}" != "running" ]; then
    CENSUS_ERR="kind names cluster '${CLUSTER_NAME}' but its node container ${NODE} is '${node_state}'.
    This is the stopped-cluster zombie: kind still lists it, so bootstrap-kind.sh:362 would take its
    'already exists - reusing it' branch and hang on an API server that is never coming back.
    Recover with:  make kind-down && make kind-up"
    return 5
  fi

  # (3) does the API server answer ON THIS CLUSTER'S OWN CONTEXT? A broken kubeconfig
  #     must never read as an empty cluster.
  if ! kubectl --context "${KCTX}" get nodes >"${errf}" 2>&1; then
    CENSUS_ERR="kubectl --context ${KCTX} get nodes failed: $(head -n 1 "${errf}" | cut -c1-160)"
    return 5
  fi

  # (4) is this an ArgoCD cluster at all? Without the CRD there is no auto-sync to
  #     suspend, and a halt that only scaled would be the lie decision 44 rejected.
  if ! kubectl --context "${KCTX}" get crd applications.argoproj.io >"${errf}" 2>&1; then
    CENSUS_ERR="cluster '${CLUSTER_NAME}' has no applications.argoproj.io CRD - this is not an ArgoCD-managed lane.
    Scaling alone would be undone by nothing here, but it is also not what this control claims to do."
    return 5
  fi

  CENSUS_ERR=""
  return 0
}

# Run the census and turn its return into the right refusal. Every verb starts here.
gate() {
  local rc
  CENSUS_ERR=""
  census
  rc=$?
  case "${rc}" in
    0) return 0 ;;
    3) die 3 "no kind cluster named '${CLUSTER_NAME}' - nothing to halt. (\`kind get clusters\` answered, and did not list it.)" ;;
    5) die 5 "the census could not be taken, so this control will not act.
    ${CENSUS_ERR}
    A census that errors is NOT an empty census (tests/scripts/run-ungated-lane.sh:60-91)." ;;
    *) die 5 "census returned an unexpected status ${rc}" ;;
  esac
}

kc() { kubectl --context "${KCTX}" "$@"; }

# ── the halt record ──────────────────────────────────────────────────────────
read_record() {
  kc -n "${ARGOCD_NS}" get configmap "${STATE_CM}" -o "jsonpath={.data.${STATE_KEY}}" 2>/dev/null
}

write_record() {
  local file
  file="$1"
  kc -n "${ARGOCD_NS}" create configmap "${STATE_CM}" \
     --from-file="${STATE_KEY}=${file}" --dry-run=client -o yaml \
     | kc apply -f - >/dev/null 2>&1
}

# ── JSON helpers ─────────────────────────────────────────────────────────────
# Every one of these is a python heredoc taking its input from the ENVIRONMENT, so
# nothing the cluster returns is ever expanded by the shell. Parsing lives here;
# every MUTATION lives in the verbs below, in plain greppable kubectl calls.

# Build the plan (TSV) and the record (JSON) from two `kubectl get -o json` dumps.
#   APP <TAB> namespace <TAB> name
#   WL  <TAB> namespace <TAB> kind <TAB> name <TAB> replicas
#
# THE DUMPS TRAVEL AS FILE PATHS, NEVER AS ENVIRONMENT VALUES. Measured against the
# operator's live cluster on 2026-09-17: `kubectl get deployments,statefulsets -A -o
# json` there is far past what the environment can carry, and passing it inline died
# with "/usr/bin/python3: Argument list too long" (E2BIG) — which this script then
# correctly refused on, but it could never have halted anything. A 4-Application
# fixture never comes close to that ceiling, so only real data showed it.
plan_from_json() {
  python3 - <<'PY'
import json, os, sys, datetime

def load(name):
    with open(os.environ[name]) as fh:
        raw = fh.read()
    if not raw.strip():
        sys.exit(1)
    return json.loads(raw)

apps = load("HALT_APPS_FILE")
wls = load("HALT_WL_FILE")
skip = set(os.environ["HALT_SKIP_NS"].split())

app_rows, wl_rows = [], []
for a in apps.get("items", []):
    m, s, st = a["metadata"], a.get("spec", {}) or {}, a.get("status", {}) or {}
    auto = ((s.get("syncPolicy") or {}).get("automated"))
    app_rows.append({
        "namespace": m["namespace"],
        "name": m["name"],
        # was_automated is the ONLY thing resume keys off. An Application already
        # suspended when the halt ran is False here and is never re-armed by us.
        "was_automated": auto is not None,
        "automated": auto,
        "sync": (st.get("sync") or {}).get("status", "Unknown"),
        "health": (st.get("health") or {}).get("status", "Unknown"),
        # A parent that can re-assert the suspend. Recorded so a re-assert is a
        # named thing in the output, not a mystery.
        "owned_by": [o.get("kind", "?") + "/" + o.get("name", "?")
                     for o in (m.get("ownerReferences") or [])],
    })

for w in wls.get("items", []):
    m, s = w["metadata"], w.get("spec", {}) or {}
    ns = m["namespace"]
    kind = w.get("kind") or ""
    # `kubectl get deployments,statefulsets -o json` returns a v1.List whose items
    # normally carry their own kind; if a server ever omits it, refuse to guess.
    if kind not in ("Deployment", "StatefulSet"):
        continue
    reps = s.get("replicas")
    row = {"namespace": ns, "kind": kind, "name": m["name"], "replicas": reps,
           "skipped": None}
    if ns in skip:
        row["skipped"] = "namespace on the mandatory floor or KIND_HALT_SKIP_NS"
    elif reps is None:
        row["skipped"] = "no .spec.replicas to restore - not scaled, not recorded"
    elif int(reps) == 0:
        row["skipped"] = "already at 0"
    wl_rows.append(row)

with open(os.environ["HALT_PLAN"], "w") as fh:
    for r in app_rows:
        if r["was_automated"]:
            fh.write("APP\t%s\t%s\n" % (r["namespace"], r["name"]))
    for r in wl_rows:
        if r["skipped"] is None:
            fh.write("WL\t%s\t%s\t%s\t%d\n"
                     % (r["namespace"], r["kind"], r["name"], int(r["replicas"])))

record = {
    "version": 1,
    "cluster": os.environ["HALT_CLUSTER"],
    "context": os.environ["HALT_CTX"],
    "argocd_ns": os.environ["HALT_ARGOCD_NS"],
    "halted_at": datetime.datetime.now(datetime.timezone.utc)
                         .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "skipped_namespaces": sorted(skip),
    "applications": app_rows,
    "workloads": wl_rows,
}
with open(os.environ["HALT_RECORD"], "w") as fh:
    json.dump(record, fh, indent=2, sort_keys=True)
PY
}

# Given the plan's APP lines and a fresh Applications dump, name any that regained
# `syncPolicy.automated` — i.e. a parent re-asserted them. Emits `ns <TAB> name`.
reasserted_apps() {
  python3 - <<'PY'
import json, os, sys

want = set()
with open(os.environ["HALT_PLAN"]) as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if parts and parts[0] == "APP":
            want.add((parts[1], parts[2]))

with open(os.environ["HALT_APPS_FILE"]) as fh:
    raw = fh.read()
if not raw.strip():
    sys.exit(1)
for a in json.loads(raw).get("items", []):
    m, s = a["metadata"], a.get("spec", {}) or {}
    key = (m["namespace"], m["name"])
    if key in want and ((s.get("syncPolicy") or {}).get("automated")) is not None:
        sys.stdout.write("%s\t%s\n" % key)
PY
}

# Replay a record as TSV for `resume`.
#   APP <TAB> namespace <TAB> name <TAB> <the automated block, as JSON>
#   WL  <TAB> namespace <TAB> kind <TAB> name <TAB> replicas
# Only rows this control actually MOVED are emitted; everything else is history.
replay_record() {
  python3 - <<'PY'
import json, os, sys

with open(os.environ["HALT_RECORD_IN"]) as fh:
    rec = json.load(fh)

for a in rec.get("applications", []):
    if not a.get("was_automated"):
        continue                      # never ours to re-arm
    blob = json.dumps(a.get("automated") or {"prune": True, "selfHeal": True},
                      sort_keys=True)
    if "\t" in blob or "\n" in blob:  # cannot happen from json.dumps; refuse anyway
        sys.exit(1)
    sys.stdout.write("APP\t%s\t%s\t%s\n" % (a["namespace"], a["name"], blob))

for w in rec.get("workloads", []):
    if w.get("skipped") is not None:
        continue                      # never scaled, so never restored
    sys.stdout.write("WL\t%s\t%s\t%s\t%d\n"
                     % (w["namespace"], w["kind"], w["name"], int(w["replicas"])))
PY
}

# Render a record for a human. This is the "SAY what it suspended, by name,
# including the state each Application was in when it froze" half of decision 44.
render_record() {
  python3 - <<'PY'
import json, os

with open(os.environ["HALT_RECORD_IN"]) as fh:
    rec = json.load(fh)

apps = rec.get("applications", [])
wls = rec.get("workloads", [])
ours = [a for a in apps if a.get("was_automated")]
theirs = [a for a in apps if not a.get("was_automated")]
scaled = [w for w in wls if w.get("skipped") is None]
skipped = [w for w in wls if w.get("skipped") is not None]

print("")
print("  halted at %s   cluster %s   context %s"
      % (rec.get("halted_at", "?"), rec.get("cluster", "?"), rec.get("context", "?")))

print("")
print("  ArgoCD auto-sync SUSPENDED by this halt (%d) - state at the moment it froze:" % len(ours))
for a in sorted(ours, key=lambda x: (x["namespace"], x["name"])):
    flag = "" if (a["sync"] == "Synced" and a["health"] == "Healthy") else "   <-- NOT healthy/synced when frozen"
    print("    %-28s sync=%-12s health=%-12s%s" % (a["name"], a["sync"], a["health"], flag))
    if a.get("owned_by"):
        print("      owned by %s - a parent that may re-assert the suspend" % ", ".join(a["owned_by"]))

unhealthy = [a for a in ours if not (a["sync"] == "Synced" and a["health"] == "Healthy")]
if unhealthy:
    print("")
    print("  %d Application(s) above were frozen MID-FLIGHT. Their status will now stay" % len(unhealthy))
    print("  exactly as shown until the lane is resumed - that is the halt holding them, not a")
    print("  new fault. hugmesh-generator#352 (external-secrets-config Degraded) and #354")
    print("  (harbor) are the two standing reds this is expected to catch.")

if theirs:
    print("")
    print("  NOT touched - already suspended before the halt (%d). Resume leaves these suspended:" % len(theirs))
    for a in sorted(theirs, key=lambda x: (x["namespace"], x["name"])):
        print("    %-28s sync=%-12s health=%s" % (a["name"], a["sync"], a["health"]))

print("")
print("  Workloads scaled to 0 by this halt (%d), with the replica count resume restores:" % len(scaled))
for w in sorted(scaled, key=lambda x: (x["namespace"], x["kind"], x["name"])):
    print("    %-22s %-12s %-34s %d -> 0" % (w["namespace"], w["kind"], w["name"], w["replicas"]))

if skipped:
    print("")
    print("  Left RUNNING on purpose (%d) - the mandatory floor and anything already at 0:" % len(skipped))
    for w in sorted(skipped, key=lambda x: (x["namespace"], x["kind"], x["name"])):
        print("    %-22s %-12s %-30s %s" % (w["namespace"], w["kind"], w["name"], w["skipped"]))
    print("    DaemonSets are never touched in any namespace (no replica count to restore).")
PY
}

print_record_file() {
  HALT_RECORD_IN="$1" render_record || \
    say "  (the halt record could not be rendered; raw JSON is in ${ARGOCD_NS}/${STATE_CM} key ${STATE_KEY})"
}

# ── verbs ────────────────────────────────────────────────────────────────────

verb_halt() {
  local apps_json
  local wl_json
  local plan
  local record
  local existing
  local tag
  local ns
  local name
  local kind_
  local reps
  local failures
  local suspended_n
  local scaled_n
  local leftover

  gate

  existing="$(read_record)"
  if [ -n "${existing}" ]; then
    die 4 "cluster '${CLUSTER_NAME}' is ALREADY halted - ${ARGOCD_NS}/${STATE_CM} holds a halt record.
    Run \`make kind-halt-status\` to see it, or \`make kind-resume\` to undo it.
    Halting twice would record a zeroed cluster as its own 'before', and the original replica counts would be lost."
  fi

  # Straight to a FILE. On a real cluster these dumps are far too big to travel in
  # the environment (see plan_from_json's note), and a command substitution would
  # also swallow a partial read as if it were a whole one.
  apps_json="${TMPDIR_HALT}/apps.json"
  wl_json="${TMPDIR_HALT}/wl.json"
  kc get applications -A -o json >"${apps_json}" 2>/dev/null || \
    die 5 "could not list ArgoCD Applications - refusing rather than halting blind"
  [ -s "${apps_json}" ] || die 5 "empty answer listing ArgoCD Applications - refusing rather than halting blind"
  kc get deployments,statefulsets -A -o json >"${wl_json}" 2>/dev/null || \
    die 5 "could not list Deployments/StatefulSets - refusing rather than halting blind"
  [ -s "${wl_json}" ] || die 5 "empty answer listing Deployments/StatefulSets - refusing rather than halting blind"

  plan="${TMPDIR_HALT}/plan.tsv"
  record="${TMPDIR_HALT}/record.json"

  if ! HALT_APPS_FILE="${apps_json}" HALT_WL_FILE="${wl_json}" \
       HALT_CLUSTER="${CLUSTER_NAME}" HALT_CTX="${KCTX}" HALT_ARGOCD_NS="${ARGOCD_NS}" \
       HALT_SKIP_NS="${SKIP_NS}" HALT_PLAN="${plan}" HALT_RECORD="${record}" \
       plan_from_json; then
    die 5 "could not build the halt plan from the cluster's own JSON - refusing to act on a reading it could not parse"
  fi

  head_ "Halting the DevOps lane - cluster '${CLUSTER_NAME}' (context ${KCTX})"
  say "The cluster, its volumes, its Vault KV and its Casdoor identities are KEPT."
  say "Nothing is deleted. \`make kind-resume\` puts back exactly what is listed below."

  failures=0
  suspended_n=0
  scaled_n=0

  # ── (1) suspend auto-sync FIRST. Scaling first would be a race the GitOps side
  #        wins: selfHeal is what makes a scale-only halt a lie.
  while IFS=$'\t' read -r tag ns name; do
    [ "${tag}" = "APP" ] || continue
    if kc -n "${ns}" patch application "${name}" --type=merge \
         -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1; then
      suspended_n=$((suspended_n + 1))
    else
      info "FAILED to suspend ${ns}/${name}"
      failures=$((failures + 1))
    fi
  done < "${plan}"

  # A generated or app-of-apps-owned Application can be re-asserted the moment we
  # suspend it. This cluster has neither today (measured 2026-09-17: zero
  # ownerReferences, and the only ApplicationSet generates an empty list), but
  # HUGMESH_GITOPS_ROOT_RECURSE=1 restores a repo-recursing root, so VERIFY instead
  # of assuming. One settle pass, then re-suspend and SAY it happened.
  if [ "${SETTLE_S}" != "0" ]; then sleep "${SETTLE_S}"; fi
  kc get applications -A -o json >"${apps_json}" 2>/dev/null
  leftover=""
  if [ -s "${apps_json}" ]; then
    leftover="$(HALT_PLAN="${plan}" HALT_APPS_FILE="${apps_json}" reasserted_apps)"
  else
    info "could not re-read Applications to verify the suspend held - it is NOT confirmed"
    failures=$((failures + 1))
  fi
  if [ -n "${leftover}" ]; then
    # Stated as what was OBSERVED, not as a diagnosis. "Still automated" has two
    # causes — the patch was refused, or a parent re-asserted it — and this pass
    # cannot tell them apart. Naming one of them here would send the reader to the
    # wrong layer, which is the cost this repo has already paid for a confident
    # wrong message (kind-doctor's whole preamble is about that).
    info "still auto-syncing after the first suspend; suspending again:"
    while IFS=$'\t' read -r ns name; do
      [ -n "${ns}" ] || continue
      info "  ${ns}/${name}"
      if ! kc -n "${ns}" patch application "${name}" --type=merge \
             -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1; then
        info "  the second patch of ${ns}/${name} was REFUSED by the API"
        failures=$((failures + 1))
      fi
    done <<< "${leftover}"

    # THE PASS THAT DECIDES. A `kubectl patch` that returns 0 has not proved the
    # suspend HELD: a parent can re-assert it again a second later, and then this
    # control would report a halt while ArgoCD was still armed to scale the
    # workloads we are about to zero straight back up — precisely the lie decision
    # 44 rejected. So the second attempt is verified too, and anything still
    # automated is a FAILURE, named, not a retry we shrug at.
    if [ "${SETTLE_S}" != "0" ]; then sleep "${SETTLE_S}"; fi
    kc get applications -A -o json >"${apps_json}" 2>/dev/null
    if [ ! -s "${apps_json}" ]; then
      info "could not re-read Applications a second time - the suspend is NOT confirmed"
      failures=$((failures + 1))
    else
      leftover="$(HALT_PLAN="${plan}" HALT_APPS_FILE="${apps_json}" reasserted_apps)"
      if [ -n "${leftover}" ]; then
        info "STILL auto-syncing after two suspends:"
        while IFS=$'\t' read -r ns name; do
          [ -n "${ns}" ] || continue
          info "  ${ns}/${name}"
          failures=$((failures + 1))
        done <<< "${leftover}"
        info "Either the patches were refused (the lines above say so) or a parent keeps"
        info "re-asserting them. Whichever it is: these Applications will scale their"
        info "workloads back up, so this halt is NOT complete."
      fi
    fi
  fi

  # ── (2) scale the mesh workloads to 0.
  while IFS=$'\t' read -r tag ns kind_ name reps; do
    [ "${tag}" = "WL" ] || continue
    if kc -n "${ns}" scale "${kind_}" "${name}" --replicas=0 >/dev/null 2>&1; then
      scaled_n=$((scaled_n + 1))
    else
      info "FAILED to scale ${ns}/${kind_}/${name} (was ${reps})"
      failures=$((failures + 1))
    fi
  done < "${plan}"

  # ── (3) persist the record. Built BEFORE the moves, so it describes the pre-halt
  #        world; written after them. A failure here is exit 6, never a silent loss.
  if ! write_record "${record}"; then
    print_record_file "${record}"
    say ""
    say "The lane was halted but the record could NOT be written to ${ARGOCD_NS}/${STATE_CM}."
    say "Resume cannot be automatic. The halted set is printed above - keep it."
    exit 6
  fi

  print_record_file "${record}"
  say ""
  say "Suspended ${suspended_n} Application(s); scaled ${scaled_n} workload(s) to 0."
  say "Resume with:  make kind-resume   (the record lives in the cluster, so this works with no Studio running)"
  if [ "${failures}" -gt 0 ]; then
    say ""
    say "${failures} item(s) did not move. The record is KEPT; the failures are named above."
    exit 6
  fi
  return 0
}

verb_resume() {
  local record
  local rec_file
  local tag
  local ns
  local name
  local kind_
  local reps
  local auto
  local failures
  local restored_n
  local rearmed_n
  local cur

  gate

  record="$(read_record)"
  if [ -z "${record}" ]; then
    die 4 "cluster '${CLUSTER_NAME}' has no halt record (${ARGOCD_NS}/${STATE_CM}) - it was not halted by this control.
    Nothing was changed. If auto-sync is suspended on this cluster it was suspended by something else, and this
    control will not guess which Applications to re-arm: re-arming 'everything' would silently undo a deliberate suspend."
  fi

  rec_file="${TMPDIR_HALT}/resume.json"
  printf '%s' "${record}" > "${rec_file}"

  head_ "Resuming the DevOps lane - cluster '${CLUSTER_NAME}' (context ${KCTX})"
  print_record_file "${rec_file}"

  failures=0
  restored_n=0
  rearmed_n=0

  # ── (1) scale workloads back up BEFORE re-arming auto-sync. The other order works
  #        too (selfHeal would restore the replicas) but it hands the cluster back to
  #        ArgoCD in a state ArgoCD must correct, and on this cluster that means a
  #        burst of reconciles; the HPA-vs-GitOps fight rewrote 7 Deployments ~950
  #        times in 38 h. Put reality back first, then re-arm.
  head_ "Restoring replica counts"
  while IFS=$'\t' read -r tag ns kind_ name reps; do
    [ "${tag}" = "WL" ] || continue
    cur="$(kc -n "${ns}" get "${kind_}" "${name}" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
    if [ -z "${cur}" ]; then
      info "GONE: ${ns}/${kind_}/${name} no longer exists - not recreated (that is ArgoCD's job once re-armed)"
      continue
    fi
    if [ "${cur}" != "0" ]; then
      info "left alone: ${ns}/${kind_}/${name} is already at ${cur} (scaled up by something else while halted)"
      continue
    fi
    if kc -n "${ns}" scale "${kind_}" "${name}" --replicas="${reps}" >/dev/null 2>&1; then
      restored_n=$((restored_n + 1))
    else
      info "FAILED to restore ${ns}/${kind_}/${name} to ${reps}"
      failures=$((failures + 1))
    fi
  done < <(HALT_RECORD_IN="${rec_file}" replay_record)

  # ── (2) re-arm auto-sync on EXACTLY what we suspended, and only while it is still
  #        suspended. An Application already re-armed by hand is left alone; one that
  #        was suspended before the halt was never recorded as ours and is not here.
  head_ "Re-arming ArgoCD auto-sync"
  while IFS=$'\t' read -r tag ns name auto; do
    [ "${tag}" = "APP" ] || continue
    cur="$(kc -n "${ns}" get application "${name}" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null)"
    if [ -n "${cur}" ]; then
      info "left alone: ${ns}/${name} is already re-armed"
      continue
    fi
    if kc -n "${ns}" patch application "${name}" --type=merge \
         -p "{\"spec\":{\"syncPolicy\":{\"automated\":${auto}}}}" >/dev/null 2>&1; then
      rearmed_n=$((rearmed_n + 1))
    else
      info "FAILED to re-arm ${ns}/${name}"
      failures=$((failures + 1))
    fi
  done < <(HALT_RECORD_IN="${rec_file}" replay_record)

  say ""
  say "Restored ${restored_n} workload(s); re-armed ${rearmed_n} Application(s)."

  if [ "${failures}" -gt 0 ]; then
    say "${failures} item(s) did not move - the halt record is KEPT so a re-run can finish the job."
    exit 6
  fi

  if kc -n "${ARGOCD_NS}" delete configmap "${STATE_CM}" >/dev/null 2>&1; then
    say "Halt record cleared. The lane is running again."
  else
    say "The lane is running again, but the halt record ${ARGOCD_NS}/${STATE_CM} could not be deleted."
    say "Delete it by hand or the next \`make kind-halt\` will refuse as 'already halted'."
    exit 6
  fi
  return 0
}

verb_status() {
  local record
  local rec_file

  gate
  record="$(read_record)"
  if [ -z "${record}" ]; then
    say "Cluster '${CLUSTER_NAME}' is NOT halted by this control - no ${ARGOCD_NS}/${STATE_CM} record."
    say "(That is a statement about this control only. It does not claim every Application is auto-syncing;"
    say " \`kubectl --context ${KCTX} get applications -A\` is the authority on that.)"
    return 0
  fi
  rec_file="${TMPDIR_HALT}/status.json"
  printf '%s' "${record}" > "${rec_file}"
  head_ "Cluster '${CLUSTER_NAME}' is HALTED"
  print_record_file "${rec_file}"
  say ""
  say "Resume with:  make kind-resume"
  return 0
}

main() {
  local verb
  verb="${1:-}"
  case "${verb}" in
    -h|--help|help) usage; exit 0 ;;
    "")     usage >&2; exit 2 ;;
    halt|resume|status)
      require_tools
      TMPDIR_HALT="$(mktemp -d -t kind-halt.XXXXXX)" || die 2 "could not create a temporary directory"
      "verb_${verb}"
      ;;
    *)      printf 'kind-halt.sh: unknown verb %s\n\n' "${verb}" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
