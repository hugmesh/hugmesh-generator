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
# THE RECORD IS WRITTEN FIRST. This is the single most important line in the file.
# ─────────────────────────────────────────────────────────────────────────────
#
# The first version of this script wrote the record LAST, after every patch and
# every scale. Two skeptics killed it with the same demonstration, and they were
# right: kill the halt at any point after the first patch and the cluster is halted
# with NO record of how to undo it. That is not hypothetical — the Studio launches
# this verb with `cancellable=True`, which arms a visible Cancel button that
# terminates the whole process GROUP (studio/hugmesh_studio/core/local_stack_node.py
# :749-751). A 900 s timeout, an OOM on a 31 GiB box, or Ctrl-C from `make
# kind-halt` does the same. Pressing Cancel was then MORE destructive than letting
# the halt finish, and nothing said so.
#
# So the order is now:
#
#     census (read-only)  ->  build the record  ->  WRITE THE RECORD  ->  mutate
#
# and if the record cannot be written, THE HALT DOES NOT HAPPEN (exit 5). A halt
# with no undo is the trap #356 exists to remove; refusing to start is strictly
# better than starting and losing the way back.
#
# The first write is `kubectl create` with NO apply fallback, so it is also the
# LOCK: two concurrent halts (a GUI double-click, a shell beside the Studio) cannot
# both proceed — the second loses the create and refuses. The record carries
# `completed: false` until every mutation has been verified; only then is it
# rewritten with `completed: true`.
#
# A record with `completed: false` means an INTERRUPTED halt, and `halt` finishes it
# rather than refusing: it re-drives the suspends and scales from that record's own
# plan and never re-censuses, so the pre-halt replica counts recorded before the
# first mutation are the ones resume restores. `resume` works on an interrupted
# halt too, because the record always describes the PRE-halt world.
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
#    That contract applies to THE HALT RECORD TOO, and in the first version it did
#    not. `read_record` swallowed kubectl's exit status, so "the ConfigMap is not
#    there" and "the API would not answer" were the same empty string — and both
#    skeptics drove that single line to the same terminal state: `halt` re-halts an
#    already-halted cluster, overwrites the good record with one whose every
#    replica count is 0, and the original counts are gone forever. `read_record`
#    below now returns 0 (present), 1 (genuinely NotFound) or 5 (could not read),
#    and every caller refuses on 5.
#
# 4. IT NEVER ACTS ON "WHATEVER CONTEXT IS CURRENT", AND THE CONTEXT CANNOT BE
#    OVERRIDDEN. Every kubectl call is pinned to `--context kind-<cluster>` (the
#    convention scripts/kind-doctor.sh:164 already uses), derived from the SAME
#    cluster name the census validated. The first version accepted a
#    `KIND_HALT_CONTEXT` override, which decoupled the two: the census proved
#    hugmesh-local was alive and every mutation then landed on whatever cluster the
#    override named. Nothing in the repo set it, so it is simply gone.
#
# 5. IT NEVER SCALES THE THINGS ITS OWN RESUME DEPENDS ON, nor the things whose
#    absence would deny admission to resources it never touches. See THE FLOOR.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE FLOOR — namespaces this script refuses to scale, in two tiers
# ─────────────────────────────────────────────────────────────────────────────
#
# `KIND_HALT_SKIP_NS` can ADD namespaces. It cannot remove one from either tier.
#
# TIER 1 — HARDCODED. Each is a way to wedge the cluster so RESUME ITSELF cannot run:
#
#   kube-system        coredns and friends. No in-cluster DNS, no resume.
#   kube-public        cluster-owned, never the mesh's.
#   kube-node-lease    node heartbeats.
#   local-path-storage the PVC provisioner (`local-path-provisioner`). Without it
#                      nothing re-binds when the workloads come back.
#   <ARGOCD_NS>        ArgoCD itself. `resume` un-suspends THROUGH it, and a
#                      suspended Application does not reconcile anyway, so scaling
#                      the control plane buys nothing and risks the only path back.
#
# TIER 2 — DERIVED, at halt time, from the cluster's own admission configuration.
# The namespace of the backing Service of EVERY webhook that is failurePolicy=Fail
# (Validating and Mutating), plus every CRD whose conversion strategy is Webhook.
# Zeroing one of those denies admission — or breaks stored-version conversion — for
# resources in OTHER namespaces that this control never touches.
#
# It is derived rather than listed because the first version hardcoded `kyverno`
# from one cluster's config, and a skeptic's obvious question was "what about a
# profile with a Fail webhook you did not census?". The census answers it. On the
# operator's cluster on 2026-09-17 it yields exactly three namespaces, and only the
# first was in the hardcoded list:
#
#   kyverno                `validate.kyverno.svc-fail` is failurePolicy=Fail over
#                          apps/v1 deployments, statefulsets, daemonsets for
#                          CONNECT, CREATE, DELETE, UPDATE, with a namespaceSelector
#                          excluding only kube-system and kyverno. A SCALE IS AN
#                          UPDATE. So the moment kyverno's own Deployment reaches 0,
#                          every subsequent scale in every other namespace fails
#                          admission — the halt wedges half-done and the resume can
#                          never scale anything back. This one is also tier-1 in
#                          effect; the census just stops it depending on a list.
#   external-secrets       three Fail webhooks (externalsecret / secretstore /
#                          clustersecretstore) AND the conversion webhook for 14
#                          CRDs, all backed by svc external-secrets/external-secrets
#                          -webhook. These gate external-secrets.io resources, not
#                          apps/v1, so they cannot wedge resume — but zeroing them
#                          denies every CREATE/UPDATE/DELETE of an ExternalSecret
#                          cluster-wide and removes the converter that v1alpha1
#                          reads need. The Application #356 names as the standing
#                          red to protect is `external-secrets-config` (#352,
#                          Degraded), and requirement 3 of the issue is that a halt
#                          must not make the standing reds HARDER to diagnose.
#                          Halting its admission controller does exactly that.
#   ingress-nginx-internal `validate.nginx.ingress.kubernetes.io`, Fail, over
#                          networking.k8s.io Ingresses. Its controller happens to be
#                          a DaemonSet here, which this script never touches anyway —
#                          the census does not need to know that to be right.
#
# DAEMONSETS ARE NEVER TOUCHED, in any namespace. A DaemonSet has no replica count
# to zero; halting one means editing its nodeSelector, which is a mutation this
# script would then have to reverse exactly. Out of scope, and said out loud in the
# output rather than quietly skipped. On this cluster that leaves the ingress-nginx
# controller, kindnet, kube-proxy and local-path-provisioner running — four pods.
#
# HORIZONTAL POD AUTOSCALERS ARE CENSUSED AND NAMED, NEVER TOUCHED. The operator's
# cluster has 8, minReplicas=2, targeting exactly the Deployments this halt zeroes.
# Two things follow, and the second is the one that matters:
#   - They do not undo the halt. The HPA controller reports ScalingActive=False
#     ("scaling is disabled since the replica count of the target is zero") once its
#     target is at 0. That is upstream documented behaviour, READ not measured here,
#     and it is stated as such in the output rather than assumed silently.
#   - The replica counts this record captures are the HPA-CHOSEN counts, not git's.
#     hugmesh-admin-bff-api sits at 6 because the HPA put it there. `resume`
#     restores 6 and then re-arms ArgoCD, which is the setup for the HPA-vs-GitOps
#     fight this repo has already measured at ~950 Deployment rewrites in 38 h. So
#     the record lists every HPA whose target it zeroed, and the rendering says it.
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
# RESUME RESTORES WHAT WAS HALTED, NOT "EVERYTHING" — AND VERIFIES IT
# ─────────────────────────────────────────────────────────────────────────────
#
# An Application that was ALREADY suspended before the halt — because someone was
# debugging it — is recorded as `was_automated: false`, is never touched by the
# halt, and is still suspended after the resume. `resume` re-arms an Application
# only when BOTH hold: the record says we suspended it, AND it is still suspended
# now. Same for workloads: a workload someone scaled up by hand while the lane was
# halted is left alone and reported, not stomped back down and up.
#
# An Application whose `automated` block was `{}` — auto-sync on, prune and selfHeal
# OFF, which is valid ArgoCD — is restored as `{}`. The first version tested that
# block for truthiness, so `{}` came back as `{"prune": true, "selfHeal": true}` and
# resume silently turned PRUNE ON. Prune DELETES cluster resources absent from git.
# The test is now `is None`.
#
# BOTH VERBS VERIFY BOTH HALVES. The first version verified the suspend twice and
# took `kubectl scale` returning 0 as proof the scale held — even though the header
# above establishes that a scale is an admission-gated UPDATE that can be denied.
# Now: after the halt, every planned Application is re-read and must be suspended,
# and every planned workload is re-read and must be at 0. After the resume, every
# restored workload must be off 0 and every re-armed Application must carry
# `automated` again. Anything that did not move is a named failure and exit 6, with
# the record KEPT so a re-run can finish the job.
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
#   4  refused: precondition (already halted and complete; resume with no record)
#   5  refused: THE CENSUS COULD NOT BE TAKEN, or the halt record could not be read
#      or written — the run-ungated-lane.sh:60-91 contract. Dead docker socket,
#      broken kubeconfig, API server silent, node container not running while `kind`
#      still names the cluster, or a record whose read errored rather than 404'd.
#      NOTHING HAS BEEN MUTATED when this is the exit from `halt`.
#   6  partial: the census was fine but something did not move, or did not STAY
#      moved. The record is KEPT so a re-run finishes the job; every straggler is
#      named.
#
# HOST TRAPS this file is written around: bash 5.3 dies on `local a=$1 b=$a` under
# `set -u` (every name is localised BEFORE the assignments run), so every helper
# declares ONE name per `local`. `| grep -q` under pipefail can report failure on a
# match it found (SIGPIPE), so no `grep -q` appears in a pipeline here. `grep` fails
# OPEN on a NUL byte, so every grep is `grep -a`, and `-F` where the pattern is data.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#: ONE reader of the override, exactly as local_stack_node.py:125 and
#: bootstrap-kind.sh:51 do it, so a probe can never disagree with the verb.
CLUSTER_NAME="${KIND_CLUSTER_NAME:-hugmesh-local}"
NODE="${CLUSTER_NAME}-control-plane"
#: NOT overridable — see WHAT THIS SCRIPT WILL NOT DO (4). The context is DERIVED
#: from the cluster name the census validates, so the thing proved alive and the
#: thing mutated are the same thing by construction.
KCTX="kind-${CLUSTER_NAME}"
ARGOCD_NS="${ARGOCD_NS:-devops}"
STATE_CM="${KIND_HALT_STATE_CONFIGMAP:-hugmesh-kind-halt}"
STATE_KEY="halt.json"
# kubectl jsonpath treats an unescaped dot as a path separator, so {.data.halt.json}
# resolves .data.halt -> .json and returns EMPTY for a key that is plainly there —
# which read_record then reports as "exists but has no 'halt.json' key" and refuses.
STATE_KEY_JSONPATH="${STATE_KEY//./\\.}"
#: How long to let a GitOps parent re-assert a suspend before re-checking. Only a
#: repo-recursing root (HUGMESH_GITOPS_ROOT_RECURSE=1) or an ApplicationSet can do
#: that; on this cluster neither applies. Tests set it to 0.
SETTLE_S="${KIND_HALT_SETTLE_S:-3}"

#: TIER 1 of THE FLOOR. Cannot be lowered by KIND_HALT_SKIP_NS. Each entry is a way
#: to make `resume` itself impossible. Tier 2 is censused in admission_floor().
MANDATORY_SKIP_NS="kube-system kube-public kube-node-lease local-path-storage ${ARGOCD_NS}"

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
          Vault KV and its Casdoor identities are all KEPT. The record of what it
          will move is WRITTEN BEFORE the first mutation: if it cannot be written,
          nothing is halted.
  resume  put back exactly what `halt` recorded — the replica counts it zeroed and
          the auto-sync it suspended. Anything suspended for another reason stays
          suspended. Verifies both halves before clearing the record.
  status  print the halt record (or say there is none). Read-only.

environment:
  KIND_CLUSTER_NAME        cluster to act on (default hugmesh-local). ONE cluster.
                           The kubectl context is DERIVED from it and cannot be
                           overridden: the cluster the census proves alive and the
                           cluster the mutations land on are the same by construction.
  ARGOCD_NS                where ArgoCD and the halt record live (default devops).
  KIND_HALT_SKIP_NS        EXTRA namespaces to leave running. Additive only: it
                           cannot unset either tier of the floor (see the header).
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
  # grep -aFx: -a because grep fails OPEN on a NUL byte; -F so a cluster name
  # carrying a regex metacharacter is matched as the literal it is; -x so
  # `hugmesh-local` never matches `hugmesh-local-2`. Output drained to /dev/null
  # rather than `grep -q`, because -q closes the pipe early and SIGPIPE under
  # pipefail can report failure on a match it DID find.
  if ! printf '%s\n' "${out}" | grep -aFx "${CLUSTER_NAME}" >/dev/null; then
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
# read_record applies the census contract to the ONE read that guards everything:
#   0  the record is present, and is on stdout
#   1  there is genuinely no record — kubectl said NotFound
#   5  THE READ FAILED. Not "no record". RECORD_ERR carries the first line.
# The first version returned an empty string for all three, and both skeptics drove
# that single conflation to the same terminal state: a second halt overwrites the
# good record with an all-zero one and the pre-halt replica counts are gone.
RECORD_ERR=""
read_record() {
  local out
  local rc
  local errf
  errf="${TMPDIR_HALT}/record.err"
  RECORD_ERR=""
  out="$(kc -n "${ARGOCD_NS}" get configmap "${STATE_CM}" \
           -o "jsonpath={.data.${STATE_KEY_JSONPATH}}" 2>"${errf}")"
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    if [ -z "${out}" ]; then
      # The ConfigMap exists but carries no `halt.json`. Something wrote a ConfigMap
      # under this name; treating that as "not halted" would let a halt proceed and
      # then fail to create its own. Refuse and say what is there.
      RECORD_ERR="${ARGOCD_NS}/${STATE_CM} exists but has no '${STATE_KEY}' key - this control did not write it, and will not overwrite it"
      return 5
    fi
    printf '%s' "${out}"
    return 0
  fi
  # NotFound is the ONLY failure that means "there is no record".
  if grep -aF -e 'NotFound' -e 'not found' "${errf}" >/dev/null 2>&1; then
    return 1
  fi
  RECORD_ERR="$(head -n 1 "${errf}" | cut -c1-200)"
  return 5
}

# The FIRST write. `create` with no apply fallback, deliberately: it fails if the
# ConfigMap already exists, which makes it the lock as well as the record. Two
# concurrent halts cannot both proceed.
create_record() {
  local file
  file="$1"
  kc -n "${ARGOCD_NS}" create configmap "${STATE_CM}" \
     --from-file="${STATE_KEY}=${file}" >/dev/null 2>&1
}

# Rewrite an EXISTING record (the `completed: true` flip, and nothing else). The
# `-n` on the apply is not decoration: without it the apply relies on the dry-run
# YAML carrying `namespace:`, which is true of today's kubectl and is not a
# behaviour this repo's fakes pin.
replace_record() {
  local file
  file="$1"
  kc -n "${ARGOCD_NS}" create configmap "${STATE_CM}" \
     --from-file="${STATE_KEY}=${file}" --dry-run=client -o yaml \
     | kc -n "${ARGOCD_NS}" apply -f - >/dev/null 2>&1
}

# ── JSON helpers ─────────────────────────────────────────────────────────────
# Every one of these is a python heredoc taking its input from FILE PATHS in the
# environment, so nothing the cluster returns is ever expanded by the shell, and
# nothing travels as an environment VALUE. Measured against the operator's live
# cluster on 2026-09-17: `kubectl get deployments,statefulsets -A -o json` there is
# far past what the environment can carry, and passing it inline died with
# "/usr/bin/python3: Argument list too long" (E2BIG) — which this script then
# correctly refused on, but it could never have halted anything. A 4-Application
# fixture never comes close to that ceiling, so only real data showed it.
#
# Parsing lives here; every MUTATION lives in the verbs below, in plain greppable
# kubectl calls.

# TIER 2 OF THE FLOOR, censused from the cluster's own admission configuration.
# Emits one namespace per line, each with the reason, TAB-separated:
#   <namespace> <TAB> <why>
admission_floor() {
  python3 - <<'PY'
import json, os, sys

def load(name):
    with open(os.environ[name]) as fh:
        raw = fh.read()
    if not raw.strip():
        sys.exit(1)
    return json.loads(raw)

why = {}

def note(ns, text):
    if not ns:
        return
    why.setdefault(ns, set()).add(text)

for cfg in load("HALT_WEBHOOKS_FILE").get("items", []):
    for w in cfg.get("webhooks", []) or []:
        if w.get("failurePolicy") != "Fail":
            continue
        svc = ((w.get("clientConfig") or {}).get("service") or {})
        note(svc.get("namespace"),
             "backs failurePolicy=Fail webhook %s/%s" % (cfg["metadata"]["name"],
                                                         w.get("name", "?")))

for crd in load("HALT_CRDS_FILE").get("items", []):
    conv = (crd.get("spec", {}) or {}).get("conversion") or {}
    if conv.get("strategy") != "Webhook":
        continue
    svc = (((conv.get("webhook") or {}).get("clientConfig") or {}).get("service") or {})
    note(svc.get("namespace"),
         "serves the conversion webhook for CRD %s" % crd["metadata"]["name"])

for ns in sorted(why):
    reasons = sorted(why[ns])
    head = reasons[0]
    if len(reasons) > 1:
        head += " (and %d more)" % (len(reasons) - 1)
    sys.stdout.write("%s\t%s\n" % (ns, head))
PY
}

# Build the plan (TSV) and the record (JSON) from the census dumps.
#   APP <TAB> namespace <TAB> name <TAB> <the automated block, as JSON>
#   WL  <TAB> namespace <TAB> kind <TAB> name <TAB> replicas
# ONE plan format, used by `halt` (which ignores the APP blob) and produced again
# by replay_record for `resume` (which needs it). Two formats is how the two verbs
# would drift apart.
plan_from_json() {
  python3 - <<'PY'
import json, os, sys, datetime

def load(name):
    with open(os.environ[name]) as fh:
        raw = fh.read()
    if not raw.strip():
        sys.exit(1)
    return json.loads(raw)

def load_optional(name):
    path = os.environ.get(name, "")
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path) as fh:
            raw = fh.read()
        if not raw.strip():
            return None
        return json.loads(raw)
    except ValueError:
        return None

apps = load("HALT_APPS_FILE")
wls = load("HALT_WL_FILE")
skip = set(os.environ["HALT_SKIP_NS"].split())
floor_why = {}
# A FILE PATH, never the text itself: nothing the cluster produced travels as an
# environment VALUE anywhere in this script (the E2BIG lesson above).
with open(os.environ["HALT_FLOOR_FILE"]) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if "\t" in line:
            ns, text = line.split("\t", 1)
            floor_why[ns] = text

app_rows, wl_rows = [], []
for a in apps.get("items", []):
    m, s, st = a["metadata"], a.get("spec", {}) or {}, a.get("status", {}) or {}
    auto = ((s.get("syncPolicy") or {}).get("automated"))
    app_rows.append({
        "namespace": m["namespace"],
        "name": m["name"],
        # was_automated is the ONLY thing resume keys off. An Application already
        # suspended when the halt ran is False here and is never re-armed by us.
        # `automated: {}` is auto-sync with prune and selfHeal OFF - valid ArgoCD,
        # falsy in python, and the reason every test below is `is not None`.
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
           "skipped": None, "floor_unbacked": False}
    if ns in skip:
        # #544. "On the floor" and "actually running" are DIFFERENT facts, and the
        # first version printed only the first one. On the operator's cluster today
        # all three external-secrets Deployments were at 0 when a halt ran, and the
        # record called them "Left RUNNING on purpose … backs failurePolicy=Fail
        # webhook (and 16 more)" — a sentence that is false in the only direction
        # that matters: 17 Fail webhooks with no endpoints behind them, described
        # as held. The floor cannot hold what is already down. Say so, and mark it
        # machine-readably so the render can shout about it.
        if reps is not None and int(reps) == 0 and ns in floor_why:
            row["skipped"] = ("ALREADY AT 0 - the admission floor did NOT hold it (nothing "
                              "here scaled it; it was down before this halt): " + floor_why[ns])
            row["floor_unbacked"] = True
        elif reps is not None and int(reps) == 0:
            row["skipped"] = ("already at 0, and on the hardcoded floor (resume itself "
                              "depends on it) or KIND_HALT_SKIP_NS")
        else:
            row["skipped"] = floor_why.get(
                ns, "on the hardcoded floor (resume itself depends on it) or KIND_HALT_SKIP_NS")
    elif reps is None:
        row["skipped"] = "no .spec.replicas to restore - not scaled, not recorded"
    elif int(reps) == 0:
        row["skipped"] = "already at 0"
    wl_rows.append(row)

zeroed = {(r["namespace"], r["kind"], r["name"])
          for r in wl_rows if r["skipped"] is None}

hpa_rows = []
hpas = load_optional("HALT_HPA_FILE")
for h in (hpas or {}).get("items", []):
    m, s = h["metadata"], h.get("spec", {}) or {}
    ref = s.get("scaleTargetRef") or {}
    hpa_rows.append({
        "namespace": m["namespace"],
        "name": m["name"],
        "target": "%s/%s" % (ref.get("kind", "?"), ref.get("name", "?")),
        "min_replicas": s.get("minReplicas"),
        "max_replicas": s.get("maxReplicas"),
        "targets_halted_workload": (m["namespace"], ref.get("kind"),
                                    ref.get("name")) in zeroed,
    })

with open(os.environ["HALT_PLAN"], "w") as fh:
    for r in app_rows:
        if r["was_automated"]:
            blob = json.dumps(r["automated"], sort_keys=True)
            if "\t" in blob or "\n" in blob:
                sys.exit(1)
            fh.write("APP\t%s\t%s\t%s\n" % (r["namespace"], r["name"], blob))
    for r in wl_rows:
        if r["skipped"] is None:
            fh.write("WL\t%s\t%s\t%s\t%d\n"
                     % (r["namespace"], r["kind"], r["name"], int(r["replicas"])))

record = {
    "version": 2,
    # false until every mutation has been made AND verified. A record with
    # completed=false is an INTERRUPTED halt: `halt` finishes it from this plan
    # rather than re-censusing, so these pre-halt counts survive.
    "completed": False,
    "cluster": os.environ["HALT_CLUSTER"],
    "context": os.environ["HALT_CTX"],
    "argocd_ns": os.environ["HALT_ARGOCD_NS"],
    "halted_at": datetime.datetime.now(datetime.timezone.utc)
                         .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "skipped_namespaces": sorted(skip),
    "admission_floor": floor_why,
    # #544. `workloads` is EVERY workload censused, scaled or not, each carrying its
    # own `skipped` reason - so `len(workloads)` is not the number this halt moved,
    # and reading it as one is how "the design says 24 of 27, the record says 39"
    # was arrived at. The counts the halt actually acted on are stated here rather
    # than left to be derived, and `workloads_scaled` is by construction the number
    # of WL rows in the plan resume replays.
    "counts": {
        "workloads_censused": len(wl_rows),
        "workloads_scaled": len(zeroed),
        "workloads_left_running": len(wl_rows) - len(zeroed),
        "workloads_on_unbacked_floor": len([r for r in wl_rows if r["floor_unbacked"]]),
        "applications_censused": len(app_rows),
        "applications_suspended": len([r for r in app_rows if r["was_automated"]]),
    },
    "applications": app_rows,
    "workloads": wl_rows,
    "hpas": hpa_rows,
    # false means the HPA read FAILED, not that there are none - the census
    # contract applied to the informational half too.
    "hpas_censused": hpas is not None,
}
with open(os.environ["HALT_RECORD"], "w") as fh:
    json.dump(record, fh, indent=2, sort_keys=True)
PY
}

# The cluster's CURRENT state, for the verification passes. Emits:
#   APP <TAB> ns/name        <TAB> 1 when syncPolicy.automated is present, else 0
#   WL  <TAB> ns/kind/name   <TAB> .spec.replicas
# A workload that is GONE simply does not appear, which is how the callers tell
# "deleted while halted" from "still at 0".
current_state() {
  python3 - <<'PY'
import json, os, sys

def load(name):
    with open(os.environ[name]) as fh:
        raw = fh.read()
    if not raw.strip():
        sys.exit(1)
    return json.loads(raw)

for a in load("HALT_APPS_FILE").get("items", []):
    m, s = a["metadata"], a.get("spec", {}) or {}
    armed = 1 if ((s.get("syncPolicy") or {}).get("automated")) is not None else 0
    sys.stdout.write("APP\t%s/%s\t%d\n" % (m["namespace"], m["name"], armed))

for w in load("HALT_WL_FILE").get("items", []):
    m, s = w["metadata"], w.get("spec", {}) or {}
    kind = w.get("kind") or ""
    if kind not in ("Deployment", "StatefulSet"):
        continue
    reps = s.get("replicas")
    sys.stdout.write("WL\t%s/%s/%s\t%s\n"
                     % (m["namespace"], kind, m["name"],
                        "-" if reps is None else int(reps)))
PY
}

# Replay a record as the SAME TSV the plan uses, for `resume` and for finishing an
# interrupted halt. Only rows this control actually MOVED are emitted; everything
# else is history.
replay_record() {
  python3 - <<'PY'
import json, os, sys

with open(os.environ["HALT_RECORD_IN"]) as fh:
    rec = json.load(fh)

for a in rec.get("applications", []):
    if not a.get("was_automated"):
        continue                      # never ours to re-arm
    auto = a.get("automated")
    # `is None`, NOT truthiness. `automated: {}` is auto-sync with prune=false and
    # selfHeal=false; re-arming it as {"prune": true, "selfHeal": true} would turn
    # PRUNE on, and prune DELETES resources absent from git. The only case that
    # needs a default is a record that lost the block entirely.
    if auto is None:
        auto = {"prune": True, "selfHeal": True}
    blob = json.dumps(auto, sort_keys=True)
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
if not rec.get("completed", False):
    print("")
    print("  THIS HALT DID NOT FINISH. The record was written BEFORE the first mutation,")
    print("  so everything below is the PRE-halt world and resume can still restore it")
    print("  exactly. Run `make kind-halt` again to finish the halt, or `make kind-resume`")
    print("  to undo whatever part of it landed.")

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

counts = rec.get("counts") or {}
print("")
print("  Workloads: %d censused, %d scaled to 0 by this halt, %d left running."
      % (counts.get("workloads_censused", len(wls)),
         counts.get("workloads_scaled", len(scaled)),
         counts.get("workloads_left_running", len(skipped))))
print("  (The list below is the SCALED half. Everything censused is recorded, each with")
print("   its own reason, so the length of the record is not the number this halt moved.)")
print("")
print("  Workloads scaled to 0 by this halt (%d), with the replica count resume restores:" % len(scaled))
for w in sorted(scaled, key=lambda x: (x["namespace"], x["kind"], x["name"])):
    print("    %-22s %-12s %-34s %d -> 0" % (w["namespace"], w["kind"], w["name"], w["replicas"]))

if skipped:
    print("")
    print("  Left RUNNING on purpose (%d) - the floor, and anything already at 0:" % len(skipped))
    for w in sorted(skipped, key=lambda x: (x["namespace"], x["kind"], x["name"])):
        print("    %-22s %-12s %-30s %s" % (w["namespace"], w["kind"], w["name"], w["skipped"]))
    print("    DaemonSets are never touched in any namespace (no replica count to restore).")

floor = rec.get("admission_floor") or {}
if floor:
    print("")
    print("  Held on the DERIVED admission floor (%d namespace(s)) - censused from this" % len(floor))
    print("  cluster's own webhook configuration, not from a hardcoded list:")
    for ns in sorted(floor):
        print("    %-24s %s" % (ns, floor[ns]))

# #544. The floor is a claim about what is still RUNNING. When a workload on it is
# already at 0, that claim is false, and it is false in the direction that hides a
# broken admission path: a failurePolicy=Fail webhook whose Service has no
# endpoints REJECTS the resources it guards. This block exists because the previous
# render described exactly that state as "Left RUNNING on purpose".
def _unbacked(w):
    # A record written by this version carries the flag either way. A record
    # written BEFORE #544 has no such key at all, and that is precisely the record
    # sitting on the operator's cluster today — so derive it rather than let
    # `status` stay silent about the state the issue was filed for.
    if "floor_unbacked" in w:
        return bool(w["floor_unbacked"])
    return (w.get("namespace") in floor
            and w.get("replicas") is not None and int(w["replicas"]) == 0)

unbacked = [w for w in wls if _unbacked(w)]
if unbacked:
    by_ns = {}
    for w in unbacked:
        by_ns.setdefault(w["namespace"], []).append(w)
    print("")
    print("  *** THE ADMISSION FLOOR IS NOT BACKED ***")
    print("  %d workload(s) in %d floor namespace(s) are at 0 REPLICAS. The floor kept this"
          % (len(unbacked), len(by_ns)))
    print("  halt from scaling them, and that is all it can do - they were already down:")
    for ns in sorted(by_ns):
        print("    %s   %s" % (ns, floor.get(ns, "on the derived admission floor")))
        for w in sorted(by_ns[ns], key=lambda x: (x["kind"], x["name"])):
            print("      %-12s %-34s replicas=0" % (w["kind"], w["name"]))
    print("  Consequences, stated rather than implied:")
    print("    - every failurePolicy=Fail webhook backed by those namespaces is UNBACKED")
    print("      right now, so creating or updating a resource it guards is REJECTED;")
    print("    - `make kind-resume` will NOT fix it. These were at 0 when the record was")
    print("      written, so 0 is the count it would restore. Scale them back by hand, or")
    print("      let their ArgoCD Application reconcile once auto-sync is re-armed;")
    print("    - this halt did not cause it. Something zeroed them BEFORE the record was")
    print("      written; this control only refused to make it worse.")

hpas = rec.get("hpas")
if not rec.get("hpas_censused", True):
    print("")
    print("  HorizontalPodAutoscalers COULD NOT BE CENSUSED. That is not the same as 'there")
    print("  are none' - this halt cannot tell you whether an autoscaler targets anything it")
    print("  zeroed. `kubectl get hpa -A` is the authority.")
elif hpas:
    hit = [h for h in hpas if h.get("targets_halted_workload")]
    print("")
    print("  HorizontalPodAutoscalers: %d on this cluster, %d targeting a workload this halt"
          % (len(hpas), len(hit)))
    print("  zeroed. NONE is touched - an HPA has no halted state to record.")
    for h in sorted(hit, key=lambda x: (x["namespace"], x["name"])):
        print("    %-22s %-30s -> %-34s min=%s max=%s"
              % (h["namespace"], h["name"], h["target"],
                 h.get("min_replicas"), h.get("max_replicas")))
    if hit:
        print("    Two consequences, and the second is the one that bites:")
        print("      - They do not undo the halt: the HPA controller reports ScalingActive=False")
        print("        once its target is at 0. That is upstream DOCUMENTED behaviour, read and")
        print("        not measured by this control.")
        print("      - The replica counts above are the HPA-CHOSEN counts, not git's. Resume puts")
        print("        those back and then re-arms ArgoCD, which is the HPA-vs-GitOps fight this")
        print("        repo has already measured at ~950 Deployment rewrites in 38 h.")
PY
}

print_record_file() {
  HALT_RECORD_IN="$1" render_record || \
    say "  (the halt record could not be rendered; raw JSON is in ${ARGOCD_NS}/${STATE_CM} key ${STATE_KEY})"
}

# ── the verification passes ──────────────────────────────────────────────────
# CUR_APP["ns/name"] = 1 armed / 0 suspended.  CUR_WL["ns/kind/name"] = replicas.
# Absent from CUR_WL means the object is GONE, which is a different answer from 0.
declare -A CUR_APP
declare -A CUR_WL

# Re-read the cluster into CUR_APP/CUR_WL. Returns non-zero when the read or the
# PARSE failed — the caller must treat that as "not confirmed", never as "nothing
# left to do". The first version ran the check through a helper whose exit status
# was discarded, so truncated JSON read as "nothing re-asserted" and the halt
# reported success without ever confirming the suspend.
load_current() {
  local apps_json
  local wl_json
  local state
  local key
  local val
  local kind_
  apps_json="${TMPDIR_HALT}/cur_apps.json"
  wl_json="${TMPDIR_HALT}/cur_wl.json"
  state="${TMPDIR_HALT}/cur_state.tsv"
  CUR_APP=()
  CUR_WL=()
  kc get applications -A -o json >"${apps_json}" 2>/dev/null || return 1
  [ -s "${apps_json}" ] || return 1
  kc get deployments,statefulsets -A -o json >"${wl_json}" 2>/dev/null || return 1
  [ -s "${wl_json}" ] || return 1
  HALT_APPS_FILE="${apps_json}" HALT_WL_FILE="${wl_json}" current_state >"${state}" || return 1
  while IFS=$'\t' read -r kind_ key val; do
    case "${kind_}" in
      APP) CUR_APP["${key}"]="${val}" ;;
      WL)  CUR_WL["${key}"]="${val}" ;;
    esac
  done < "${state}"
  return 0
}

# ── verbs ────────────────────────────────────────────────────────────────────

verb_halt() {
  local apps_json
  local wl_json
  local hpa_json
  local wh_json
  local crd_json
  local floor_file
  local plan
  local record
  local existing
  local rc
  local tag
  local ns
  local name
  local kind_
  local reps
  local auto
  local failures
  local suspended_n
  local scaled_n
  local leftover
  local skip_ns
  local key

  gate

  plan="${TMPDIR_HALT}/plan.tsv"
  record="${TMPDIR_HALT}/record.json"

  existing=""
  read_record >"${TMPDIR_HALT}/existing.json"
  rc=$?
  case "${rc}" in
    0) existing="present" ;;
    1) existing="" ;;
    *) die 5 "could not read the halt record ${ARGOCD_NS}/${STATE_CM}, so this control will not act.
    ${RECORD_ERR}
    An errored read is NOT an absent record. Halting on that mistake would overwrite a good record
    with one whose every replica count is 0, and the pre-halt counts would be gone for good." ;;
  esac

  if [ -n "${existing}" ]; then
    # A record exists. Complete -> refuse. Incomplete -> FINISH IT from that record,
    # never from a fresh census: the counts in it are the pre-halt world.
    if HALT_RECORD_IN="${TMPDIR_HALT}/existing.json" python3 -c '
import json, os, sys
with open(os.environ["HALT_RECORD_IN"]) as fh:
    sys.exit(0 if json.load(fh).get("completed", False) else 1)
' 2>/dev/null; then
      die 4 "cluster '${CLUSTER_NAME}' is ALREADY halted - ${ARGOCD_NS}/${STATE_CM} holds a completed halt record.
    Run \`make kind-halt-status\` to see it, or \`make kind-resume\` to undo it.
    Halting twice would record a zeroed cluster as its own 'before', and the original replica counts would be lost."
    fi
    cp "${TMPDIR_HALT}/existing.json" "${record}"
    if ! HALT_RECORD_IN="${record}" replay_record >"${plan}"; then
      die 5 "the existing halt record in ${ARGOCD_NS}/${STATE_CM} could not be parsed, so this control will not act.
    It was written by an INTERRUPTED halt and is the only description of the pre-halt world.
    Read it with:  kubectl --context ${KCTX} -n ${ARGOCD_NS} get configmap ${STATE_CM} -o jsonpath='{.data.${STATE_KEY}}'"
    fi
    head_ "Finishing an INTERRUPTED halt - cluster '${CLUSTER_NAME}' (context ${KCTX})"
    say "A halt record exists but is marked incomplete, so a previous run was killed"
    say "part-way through. Re-driving it from that record, NOT from a fresh census:"
    say "the counts recorded before the first mutation are the ones resume must restore."
  else
    # Straight to FILES. On a real cluster these dumps are far too big to travel in
    # the environment (see the JSON helpers' note), and a command substitution would
    # also swallow a partial read as if it were a whole one.
    apps_json="${TMPDIR_HALT}/apps.json"
    wl_json="${TMPDIR_HALT}/wl.json"
    hpa_json="${TMPDIR_HALT}/hpa.json"
    wh_json="${TMPDIR_HALT}/webhooks.json"
    crd_json="${TMPDIR_HALT}/crds.json"
    floor_file="${TMPDIR_HALT}/floor.tsv"

    kc get applications -A -o json >"${apps_json}" 2>/dev/null || \
      die 5 "could not list ArgoCD Applications - refusing rather than halting blind"
    [ -s "${apps_json}" ] || die 5 "empty answer listing ArgoCD Applications - refusing rather than halting blind"
    kc get deployments,statefulsets -A -o json >"${wl_json}" 2>/dev/null || \
      die 5 "could not list Deployments/StatefulSets - refusing rather than halting blind"
    [ -s "${wl_json}" ] || die 5 "empty answer listing Deployments/StatefulSets - refusing rather than halting blind"

    # TIER 2 of the floor. This one IS load-bearing - it decides what not to scale -
    # so a failed read is a refusal, not an empty floor.
    kc get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json >"${wh_json}" 2>/dev/null || \
      die 5 "could not list admission webhook configurations - refusing rather than scaling an admission controller blind"
    [ -s "${wh_json}" ] || die 5 "empty answer listing admission webhook configurations - refusing rather than halting blind"
    kc get crd -o json >"${crd_json}" 2>/dev/null || \
      die 5 "could not list CustomResourceDefinitions - refusing rather than scaling a conversion webhook blind"
    [ -s "${crd_json}" ] || die 5 "empty answer listing CustomResourceDefinitions - refusing rather than halting blind"
    if ! HALT_WEBHOOKS_FILE="${wh_json}" HALT_CRDS_FILE="${crd_json}" \
         admission_floor >"${floor_file}"; then
      die 5 "could not derive the admission floor from this cluster's webhook configuration - refusing rather than guessing it"
    fi

    # HPAs are INFORMATIONAL: they are named, never touched. A failed read is
    # recorded as 'not censused' rather than rendered as 'there are none'.
    if ! kc get hpa -A -o json >"${hpa_json}" 2>/dev/null || [ ! -s "${hpa_json}" ]; then
      rm -f "${hpa_json}"
    fi

    skip_ns="${MANDATORY_SKIP_NS} ${KIND_HALT_SKIP_NS:-}"
    while IFS=$'\t' read -r ns name; do
      [ -n "${ns}" ] || continue
      skip_ns="${skip_ns} ${ns}"
    done < "${floor_file}"

    if ! HALT_APPS_FILE="${apps_json}" HALT_WL_FILE="${wl_json}" \
         HALT_HPA_FILE="${hpa_json}" \
         HALT_CLUSTER="${CLUSTER_NAME}" HALT_CTX="${KCTX}" HALT_ARGOCD_NS="${ARGOCD_NS}" \
         HALT_SKIP_NS="${skip_ns}" HALT_FLOOR_FILE="${floor_file}" \
         HALT_PLAN="${plan}" HALT_RECORD="${record}" \
         plan_from_json; then
      die 5 "could not build the halt plan from the cluster's own JSON - refusing to act on a reading it could not parse"
    fi

    # ── THE RECORD GOES FIRST. Nothing above this line mutated anything, and if
    #    this write fails nothing below it runs. A halt with no undo is the trap
    #    #356 exists to remove.
    if ! create_record "${record}"; then
      die 5 "the halt record could not be written to ${ARGOCD_NS}/${STATE_CM}, so NOTHING was halted.
    Every step so far was read-only; the cluster is exactly as it was.
    Either the API refused the create, or another halt created the record first (this create is also the lock).
    Check with:  kubectl --context ${KCTX} -n ${ARGOCD_NS} get configmap ${STATE_CM}"
    fi

    head_ "Halting the DevOps lane - cluster '${CLUSTER_NAME}' (context ${KCTX})"
    say "The cluster, its volumes, its Vault KV and its Casdoor identities are KEPT."
    say "Nothing is deleted. \`make kind-resume\` puts back exactly what is listed below."
    say "The record of what follows is ALREADY written, so an interrupted halt is still undoable."
  fi

  failures=0
  suspended_n=0
  scaled_n=0

  # ── (1) suspend auto-sync FIRST. Scaling first would be a race the GitOps side
  #        wins: selfHeal is what makes a scale-only halt a lie.
  while IFS=$'\t' read -r tag ns name auto; do
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
  # of assuming — and treat a failed or unparseable re-read as NOT CONFIRMED.
  if [ "${SETTLE_S}" != "0" ]; then sleep "${SETTLE_S}"; fi
  leftover=""
  if ! load_current; then
    info "could not re-read the cluster to verify the suspend held - it is NOT confirmed"
    failures=$((failures + 1))
  else
    while IFS=$'\t' read -r tag ns name auto; do
      [ "${tag}" = "APP" ] || continue
      key="${ns}/${name}"
      if [ "${CUR_APP[${key}]:-0}" = "1" ]; then
        leftover="${leftover}${ns}"$'\t'"${name}"$'\n'
      fi
    done < "${plan}"
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
    if ! load_current; then
      info "could not re-read the cluster a second time - the suspend is NOT confirmed"
      failures=$((failures + 1))
    else
      leftover=""
      while IFS=$'\t' read -r tag ns name auto; do
        [ "${tag}" = "APP" ] || continue
        key="${ns}/${name}"
        if [ "${CUR_APP[${key}]:-0}" = "1" ]; then
          info "STILL auto-syncing after two suspends: ${key}"
          failures=$((failures + 1))
        fi
      done < "${plan}"
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

  # ── (3) VERIFY THE SCALES. `kubectl scale` returning 0 is not proof: the header's
  #        own kyverno finding is that a scale is an admission-gated UPDATE, and an
  #        admission controller can deny it. This is the half the operator can
  #        actually see, and the first version never re-read it.
  if ! load_current; then
    info "could not re-read the cluster to verify the scales held - they are NOT confirmed"
    failures=$((failures + 1))
  else
    while IFS=$'\t' read -r tag ns kind_ name reps; do
      [ "${tag}" = "WL" ] || continue
      key="${ns}/${kind_}/${name}"
      case "${CUR_WL[${key}]:-}" in
        0)  : ;;
        "") info "GONE after the scale: ${key} no longer exists - not counted as halted"
            failures=$((failures + 1)) ;;
        *)  info "NOT at 0 after the scale: ${key} is at ${CUR_WL[${key}]:-?}"
            failures=$((failures + 1)) ;;
      esac
    done < "${plan}"
  fi

  if [ "${failures}" -gt 0 ]; then
    print_record_file "${record}"
    say ""
    say "Suspended ${suspended_n} Application(s); scaled ${scaled_n} workload(s) to 0."
    say ""
    say "${failures} item(s) did not move, or did not STAY moved. The record is KEPT and is"
    say "still marked incomplete, so \`make kind-halt\` will finish the job and \`make kind-resume\`"
    say "will undo whatever landed. The failures are named above."
    exit 6
  fi

  # ── (4) only now is the halt complete. The flag is flipped BEFORE the record is
  #        rendered, so a halt that finished does not print "THIS HALT DID NOT
  #        FINISH" about itself; and it is only ever a REWRITE of a record that
  #        already exists on the cluster, never a second create.
  if ! HALT_RECORD_IN="${record}" HALT_RECORD_OUT="${record}.done" python3 - <<'PY'
import json, os
with open(os.environ["HALT_RECORD_IN"]) as fh:
    rec = json.load(fh)
rec["completed"] = True
with open(os.environ["HALT_RECORD_OUT"], "w") as fh:
    json.dump(rec, fh, indent=2, sort_keys=True)
PY
  then
    print_record_file "${record}"
    say ""
    say "The lane is halted, but the record could not be marked complete."
    say "Resume still works - the record describes the pre-halt world either way."
    exit 6
  fi
  if ! replace_record "${record}.done"; then
    print_record_file "${record}"
    say ""
    say "The lane is halted and the record is intact, but it could not be marked complete."
    say "\`make kind-resume\` still restores exactly what is listed above; a second"
    say "\`make kind-halt\` would re-drive the same (idempotent) suspends and scales."
    exit 6
  fi

  print_record_file "${record}.done"
  say ""
  say "Suspended ${suspended_n} Application(s); scaled ${scaled_n} workload(s) to 0."
  say "Resume with:  make kind-resume   (the record lives in the cluster, so this works with no Studio running)"
  return 0
}

verb_resume() {
  local record
  local rec_file
  local plan
  local rc
  local tag
  local ns
  local name
  local kind_
  local reps
  local auto
  local failures
  local restored_n
  local rearmed_n
  local planned_n
  local key

  gate

  rec_file="${TMPDIR_HALT}/resume.json"
  read_record >"${rec_file}"
  rc=$?
  case "${rc}" in
    0) : ;;
    1) die 4 "cluster '${CLUSTER_NAME}' has no halt record (${ARGOCD_NS}/${STATE_CM}) - this control did not halt it.
    Nothing was changed. This says nothing about WHY any Application on this cluster may be suspended: without a
    record this control cannot know which ones were its doing, and re-arming 'everything' would silently undo a
    deliberate suspend. \`kubectl --context ${KCTX} get applications -A\` is the authority on what is suspended." ;;
    *) die 5 "could not read the halt record ${ARGOCD_NS}/${STATE_CM}, so this control will not act.
    ${RECORD_ERR}
    An errored read is NOT an absent record: refusing here is what stops a genuinely halted cluster from being
    reported as 'not halted by this control'." ;;
  esac

  plan="${TMPDIR_HALT}/resume-plan.tsv"
  if ! HALT_RECORD_IN="${rec_file}" replay_record >"${plan}"; then
    die 5 "the halt record in ${ARGOCD_NS}/${STATE_CM} could not be parsed, so this control will not act.
    It is the only description of the pre-halt world; it is NOT deleted.
    Read it with:  kubectl --context ${KCTX} -n ${ARGOCD_NS} get configmap ${STATE_CM} -o jsonpath='{.data.${STATE_KEY}}'"
  fi

  planned_n=0
  while IFS= read -r tag; do
    [ -n "${tag}" ] && planned_n=$((planned_n + 1))
  done < "${plan}"

  head_ "Resuming the DevOps lane - cluster '${CLUSTER_NAME}' (context ${KCTX})"
  print_record_file "${rec_file}"

  if [ "${planned_n}" -eq 0 ]; then
    # A record that describes NOTHING to restore is not a successful resume, it is a
    # record that should never have been written. Saying "restored 0, re-armed 0,
    # the lane is running again" and deleting it is how the last evidence of a halt
    # disappears while the cluster stays at zero.
    say ""
    die 6 "the halt record describes NOTHING to restore - no Application this control suspended and no workload it scaled.
    That is not a resume, and the record is KEPT rather than deleted. Either this cluster was already at rest when it
    was halted, or the record was overwritten. Check the real state with:
      kubectl --context ${KCTX} get applications -A
      kubectl --context ${KCTX} get deployments,statefulsets -A
    and delete ${ARGOCD_NS}/${STATE_CM} by hand once you are satisfied there is nothing to put back."
  fi

  if ! load_current; then
    die 5 "could not read the cluster's current state, so this control will not act.
    Restoring blind would stomp a workload someone scaled up by hand while the lane was halted."
  fi

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
    key="${ns}/${kind_}/${name}"
    case "${CUR_WL[${key}]:-}" in
      "") info "GONE: ${key} no longer exists - not recreated (that is ArgoCD's job once re-armed)"
          continue ;;
      0)  : ;;
      *)  info "left alone: ${key} is already at ${CUR_WL[${key}]:-?} (scaled up by something else while halted)"
          continue ;;
    esac
    if kc -n "${ns}" scale "${kind_}" "${name}" --replicas="${reps}" >/dev/null 2>&1; then
      restored_n=$((restored_n + 1))
    else
      info "FAILED to restore ${key} to ${reps}"
      failures=$((failures + 1))
    fi
  done < "${plan}"

  # ── (2) re-arm auto-sync on EXACTLY what we suspended, and only while it is still
  #        suspended. An Application already re-armed by hand is left alone; one that
  #        was suspended before the halt was never recorded as ours and is not here.
  head_ "Re-arming ArgoCD auto-sync"
  while IFS=$'\t' read -r tag ns name auto; do
    [ "${tag}" = "APP" ] || continue
    key="${ns}/${name}"
    if [ "${CUR_APP[${key}]:-0}" = "1" ]; then
      info "left alone: ${key} is already re-armed"
      continue
    fi
    if kc -n "${ns}" patch application "${name}" --type=merge \
         -p "{\"spec\":{\"syncPolicy\":{\"automated\":${auto}}}}" >/dev/null 2>&1; then
      rearmed_n=$((rearmed_n + 1))
    else
      info "FAILED to re-arm ${key}"
      failures=$((failures + 1))
    fi
  done < "${plan}"

  # ── (3) VERIFY BOTH HALVES before clearing the record. A patch returning 0 is not
  #        proof it held, and the record is the only way back: it is deleted only
  #        once the cluster itself says the resume landed.
  head_ "Verifying the resume landed"
  if ! load_current; then
    say ""
    say "The cluster could not be re-read, so the resume is NOT confirmed. The halt record is KEPT."
    say "Re-run \`make kind-resume\` once the API server answers; it is idempotent."
    exit 6
  fi
  # Two passes, one per row shape, so each reads its own line with its own field
  # names. One combined loop would have to reinterpret the same positional variables
  # for two different record layouts, which is exactly how an off-by-one reads a
  # JSON blob as a workload name and verifies nothing.
  while IFS=$'\t' read -r tag ns kind_ name reps; do
    [ "${tag}" = "WL" ] || continue
    key="${ns}/${kind_}/${name}"
    case "${CUR_WL[${key}]:-}" in
      "") : ;;                                      # gone; already reported above
      0)  info "STILL AT 0 after the resume: ${key} (wanted ${reps})"
          failures=$((failures + 1)) ;;
      *)  : ;;
    esac
  done < "${plan}"
  while IFS=$'\t' read -r tag ns name auto; do
    [ "${tag}" = "APP" ] || continue
    key="${ns}/${name}"
    if [ "${CUR_APP[${key}]:-0}" != "1" ]; then
      info "STILL SUSPENDED after the resume: ${key}"
      failures=$((failures + 1))
    fi
  done < "${plan}"

  say ""
  say "Restored ${restored_n} workload(s); re-armed ${rearmed_n} Application(s)."

  if [ "${failures}" -gt 0 ]; then
    say "${failures} item(s) did not move, or did not STAY moved - the halt record is KEPT so a re-run can finish the job."
    exit 6
  fi
  say "Verified: every workload this halt zeroed is off 0, and every Application it suspended is armed again."

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
  local rec_file
  local rc

  gate
  rec_file="${TMPDIR_HALT}/status.json"
  read_record >"${rec_file}"
  rc=$?
  case "${rc}" in
    1)
      say "Cluster '${CLUSTER_NAME}' is NOT halted by this control - no ${ARGOCD_NS}/${STATE_CM} record."
      say "(That is a statement about this control only. It does not claim every Application is auto-syncing;"
      say " \`kubectl --context ${KCTX} get applications -A\` is the authority on that.)"
      return 0 ;;
    5)
      die 5 "could not read the halt record ${ARGOCD_NS}/${STATE_CM}, so this control cannot say whether the lane is halted.
    ${RECORD_ERR}
    An errored read is NOT an absent record, and reporting 'not halted' here is how a genuinely halted cluster
    gets halted a second time and loses its original replica counts." ;;
  esac
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
