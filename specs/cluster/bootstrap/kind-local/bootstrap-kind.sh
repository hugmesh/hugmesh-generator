#!/bin/bash
# bootstrap-kind.sh — reusable LOCAL kind bring-up for a CURATED slice of the
# HugMesh GitOps tree: Vault + Vault-PKI + Casdoor (+ its dedicated
# casdoor-pg Postgres) + Harbor (+ harbor-provision), and everything those
# transitively need (namespaces, local-path storage, ArgoCD itself, External
# Secrets Operator + its Vault ClusterSecretStore config, ingress-nginx
# (internal)). See README.md in this directory for the full scope rationale —
# in short: the root app-of-apps (specs/cluster/app-of-apps.yaml) syncs ALL 96
# files under specs/cluster/apps (91 Application + 5 ApplicationSet objects, one
# per file, counted 2026-08-26) — the entire platform: GitLab, Cassandra, all 4
# gateways, Matrix/Mastodon, games, media-poisoner, ... — and that is
# deliberately too much for a validation pass of just the identity/registry
# stack. This script applies ONLY the curated subset directly with kubectl
# (skipping the root app-of-apps step entirely).
#
# THAT COUNT SAID "81" UNTIL 2026-08-26, here and in README.md, and had been
# wrong for long enough that nobody re-derived it. Read the number as a
# magnitude, not a checksum: it is prose, nothing enforces it, and the point it
# makes ("far more than this pass needs") survives either way.
#
# THE CURATION IS DELIBERATE — it is not a coverage gap, and "sweep the rest in"
# is the wrong fix. What did not exist was a SELECTION CHANNEL: no way to add an
# infra Application to the curated set without editing this file. KIND_ADDONS
# (below) is that channel.
#
# Idempotent: safe to re-run against the same cluster — skips cluster creation,
# keeps an existing cluster-ca Secret, reuses an already-initialized Vault, keeps
# an already-seeded Vault KV (seed-vault-kv.sh; see below), and re-applies
# everything else via `kubectl apply`.
#
# That KV clause is load-bearing, not decorative. Until it existed the "safe to
# re-run" claim was FALSE and destructive under KIND_PROFILE=sso: the KV step
# re-ran scripts/gen-cluster-secrets.sh, which mints every password
# unconditionally with `openssl rand` and overwrites Vault, while the Postgres
# instances kept the FIRST run's passwords (initdb only runs on an empty PGDATA).
# A second `make kind-up` therefore wedged the cluster it claimed to converge —
# `password authentication failed for user "userbff"`. KIND_KV_RESEED=1 is the
# deliberate, destructive re-mint (fresh cluster / wiped PVCs only).
#
# Targets the CORE reference "hugmesh.net" apps/ tree (specs/cluster/
# apps/*.yaml as committed on the GitOps repo), NOT a brand-templated tenant
# (templates/apps/*.hbs + brands/*.conf render OTHER tenant domains from these
# same core apps — this script intentionally does not touch that templating
# layer; it validates the reference cluster the templates are derived from).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"       # specs/cluster (this dir is specs/cluster/bootstrap/kind-local)
REPO_ROOT="$(cd "${CLUSTER_DIR}/../.." && pwd)"        # repo root (for `git show <branch>:<path>`)

CLUSTER_NAME="${KIND_CLUSTER_NAME:-hugmesh-local}"
# ArgoCD version PIN (issue #394) — see bootstrap.sh (the sibling this script
# reuses the install/re-namespace logic from) for the full rationale and the
# bump procedure. Short version: `stable` silently tracks upstream, and
# argoproj/argo-cd#29103 (merged 2026-09-09) flips the default diff strategy
# to Server-Side Diff for every ServerSideApply=true Application the moment
# `stable` advances past it. Pinned to v3.5.3, MEASURED as what
# kind-hugmesh-local actually runs today (2026-09-18) and confirmed to
# predate #29103.
#
# DECISION 65 = per-app (operator, 2026-09-18, #347): when the pin is bumped
# past #29103, every deployed ServerSideApply=true Application gets the
# per-app `compare-options: ServerSideDiff=true` annotation, NOT the global
# `controller.diff.server.side` controller flag — see bootstrap.sh for the
# full rationale and the current per-profile app list (harbor already
# annotated; ingress-nginx-internal and kyverno are the other two deployed on
# THIS kind profile today). Recorded here, not applied: no live-behaviour
# change from this comment.
#
# Bump: diff the target tag's install.yaml first, then re-run
# tests/scripts/test-argocd-serverside-diff.sh.
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.3}"
ARGOCD_NS="${ARGOCD_NS:-devops}"
GITOPS_REPO_DEFAULT="https://github.com/hugmesh/hugmesh-generator.git"
REPO="${HUGMESH_GITOPS_REPO:-${GITOPS_REPO_DEFAULT}}"
REV="${HUGMESH_GITOPS_REV:-main}"
# Set iff the caller pinned a revision explicitly. The tokenless local sync
# path (step 5b) otherwise retargets REV at HEAD — the branch THIS checkout
# has checked out — because "sync what the operator is running" is the whole
# point of serving the local tree.
REV_EXPLICIT="${HUGMESH_GITOPS_REV:+1}"
# Tokenless local sync (step 5b): the kind node mounts this checkout read-only
# at LOCAL_GITOPS_MOUNT (appended to the kind config at CREATE time — the host
# path is only known at runtime), and an in-cluster read-only `git daemon`
# (gitops-repo-server.yaml) serves it to ArgoCD at LOCAL_GITOPS_URL. No GitHub
# credential and no GitHub reachability needed for a local mesh.
LOCAL_GITOPS_MOUNT="/hugmesh/hugmesh-generator"
LOCAL_GITOPS_URL="git://gitops-repo-server.${ARGOCD_NS}.svc.cluster.local/hugmesh-generator"
# Both former branch overrides (the Harbor migration and the vault-tls-init
# openssl fix) have since MERGED to main — apps/03a+03b and the fixed
# manifests/vault/deployment.yaml are read straight from $REV like everything
# else. The override machinery below is kept so a future not-yet-merged
# Application can be validated the same way, but the defaults are now main.
HARBOR_BRANCH="${HARBOR_BRANCH:-main}"
VAULT_BRANCH="${VAULT_BRANCH:-main}"
SKIP_VAULT_BOOTSTRAP="${SKIP_VAULT_BOOTSTRAP:-0}"
# KIND_PROFILE=core (default) brings up the original curated identity/registry
# slice. KIND_PROFILE=sso ADDITIONALLY brings up the native-login path — the
# fe-gateway + admin/user BFFs (+ their Postgres), route-access seed, Cassandra,
# the Angular host shell and the login/social UI remotes — then seeds Vault KV
# (gen-cluster-secrets.sh ONLINE mode through an exec shim into vault-0) and the
# deterministic e2e identity catalogue (tests/qemu/seed-accounts.sh --roles), so
# tests/e2e/specs/27-native-login.spec.ts can run against this cluster from the
# host (`make kind-e2e` at the repo root drives the whole flow). First-party
# images are NOT pulled from Harbor here — `make kind-images` builds them from
# the sibling repos and `kind load`s them under the exact rendered refs.
KIND_PROFILE="${KIND_PROFILE:-core}"
case "${KIND_PROFILE}" in core|sso) ;; *) echo "KIND_PROFILE must be 'core' or 'sso' (got '${KIND_PROFILE}')" >&2; exit 1 ;; esac

# ── MFA operational flip (issue #47; `make kind-up MFA=1`) ────────────────────
# MFA=1 adds a `mfa.enabled=true` HELM PARAMETER to EVERY gateway Application
# this bootstrap applies (step 6b) — the same runtime-patch mechanism as the
# ingress.className override there, so the committed chart values and
# specs/cluster/apps/*.yaml stay untouched and default-OFF (which
# tests/stack/test-gateway-mfa-env.sh + tests/scripts/test-mfa-required-rules.sh
# keep enforcing). It flips ONLY app.mfa.enabled: the freshness window keeps the
# chart default (600000) and APP_MFA_ENFORCE_PRIVILEGED_FLOOR is DELIBERATELY not
# reachable from this script — the privileged floor fails closed for SUPERADMIN
# too, so it stays a hand-executed step (docs/MFA-ROLLOUT.md §3 step 7).
# Fail-closed value parse: an unrecognised spelling must not silently mean "off".
MFA="${MFA:-}"
case "${MFA}" in
  ""|0|false|off) MFA="" ;;
  1|true|on)      MFA="1" ;;
  *) echo "MFA must be empty/0/false/off or 1/true/on (got '${MFA}')" >&2; exit 1 ;;
esac
# HONESTY (see the kind-honesty gate's rationale): under KIND_PROFILE=core no
# gateway Application is applied at all, so MFA=1 would flip NOTHING while the
# bootstrap exits 0 — report the unperformed work loudly instead of implying it.
if [ -n "${MFA}" ] && [ "${KIND_PROFILE}" != "sso" ]; then
  echo "MFA=1 needs KIND_PROFILE=sso: the core profile applies no gateway Application, so there is nothing to flip and exiting 0 would report work that was not done." >&2
  exit 1
fi

# ── KIND_ADDONS — the infra add-on selection channel (operator ask 2026-08-26) ─
#
# WHAT WAS BROKEN. specs/cluster/apps/01-metrics-server.yaml has existed all
# along (chart 3.12.*, ns kube-system, sync-wave -1) and was in NO profile, while
# KIND_PROFILE=sso applies SEVEN HorizontalPodAutoscaler objects. Measured, not
# assumed, on 2026-08-26: manifests/{admin-bff-api,user-bff-api,frontend}/
# kustomization.yaml each carry one `- hpa.yaml`, and manifests/social-ui/hpa.yaml
# carries FOUR (matrix-ui, mastodon-ui, login-ui, admin-ui) — 1+1+1+4 = 7, all
# plain autoscaling/v2 CPU+memory. (The gateway chart's HPA does not count: its
# values ship autoscaling.enabled=false and this script does not flip it.)
#
# An HPA with no resource-metrics API does not fail. It reports `<unknown>/70%`
# forever and holds its Deployment at the replicas floor — which is
# indistinguishable, from every surface this bring-up prints, from a cluster that
# is simply not under load. So the whole autoscaling story on kind has been dark,
# quietly, for as long as the HPAs have been there.
#
# THE MAP: slug -> the apps/*.yaml files that add-on applies, in apply order.
# Deliberately ONE literal block rather than a bash associative array, so
# tests/scripts/test-kind-profile-app-closure.sh can parse the exact bytes this
# script executes. A map the closure guard cannot read is a map with NO closure
# check and no wait-list check, and this repo has already paid for that shape
# twice (see the cassandra-init and kyverno notes on APP_NAMES below).
#
# WHY ONLY TWO SLUGS. Every slug here must change something OBSERVABLE when
# selected, or it is an inert toggle — the failure this repo's local-services
# catalogue exists to prevent. Two nearby Applications are therefore NOT offered
# yet, on purpose:
#   * apps/01c-autoscaling-latency.yaml — its KEDA ScaledObjects target the same
#     Deployments the seven v2 HPAs above already own, and KEDA will not co-own a
#     Deployment that already has an HPA (the file says so itself). Selecting it
#     on the sso profile would produce a conflict, not autoscaling. It also reads
#     a Prometheus that does not exist in this cluster.
#   * apps/36-observability.yaml — MANUAL-sync by design (no syncPolicy.automated
#     block). Applying the Application object would create an OutOfSync row and
#     deploy nothing: a checkbox that changes no bytes.
# Both belong here the day they gain a story that ends in a running workload.
# AN ADD-ON'S ROW IS ITS FULL CLOSURE, not just its own Application. `keda`
# carries 01-metrics-server.yaml as well because apps/01b-keda.yaml's own header
# says the v2 CPU+memory HPAs it sits beside "only need metrics-server (already
# live at apps/01-metrics-server.yaml)" — an operator who asks for autoscaling
# substrate and gets KEDA over an absent resource-metrics API has the inert HPAs
# back, wearing a different hat. Declaring the dependency HERE, in the row, is
# what tests/scripts/test-kind-profile-app-closure.sh checks: delete
# 01-metrics-server.yaml from that row and the closure gate goes red. Duplicate
# files across selected rows are collapsed by the parse below.
KIND_ADDON_MAP="
metrics-server  01-metrics-server.yaml
keda            01-metrics-server.yaml 01b-keda.yaml
"
# DEFAULT ON — and metrics-server is why the default is not empty. The seven HPAs
# are ALREADY applied and already inert; shipping the add-on opt-in would make
# the broken state the normal one and leave the fix to whoever reads this file.
KIND_ADDONS_DEFAULT="metrics-server"

addon_slugs() {                 # every slug in the map, in map order
  local slug rest
  while read -r slug rest; do
    [ -n "${slug}" ] && printf '%s\n' "${slug}"
  done <<<"${KIND_ADDON_MAP}"
  return 0
}
addon_files() {                 # <slug> -> that add-on's app filenames, one per line
  local want="$1"
  local slug rest
  while read -r slug rest; do
    [ "${slug}" = "${want}" ] || continue
    [ -n "${rest}" ] && printf '%s\n' ${rest}
  done <<<"${KIND_ADDON_MAP}"
  return 0
}
addon_selected() {              # <slug> -> rc 0 iff this run selected it
  case " ${ADDON_SELECTED[*]:-} " in *" $1 "*) return 0 ;; esac
  return 1
}

# Fail-closed parse, for the same reason MFA's is: an unrecognised spelling must
# not silently mean "off".
#
# `none` is the deliberate spelling for "no add-ons". An EMPTY KIND_ADDONS is
# treated as UNSET (i.e. the default), because empty is what every layer this
# value is threaded through produces by accident — make expands an unset variable
# to nothing, a Python dict comprehension emits "" for an empty selection — and
# "the operator turned metrics-server off" must never be reachable by accident.
# SEPARATORS ARE NOT CONTENT. `${x:-default}` only rescues empty-or-unset, so a
# value of "   " (or "," or a stray newline) sailed past it, word-split to ZERO
# slugs, and silently meant `none` — the accidental-off this whole parse exists
# to forbid, reached without anyone typing the word. A `KIND_ADDONS=$(...)`
# threaded through make/Python that returns whitespace is exactly how that
# happens. Strip every separator; if NOTHING is left, the value carried no
# selection at all, which is UNSET.
_ka_content="${KIND_ADDONS-}"
_ka_content="${_ka_content//[$' \t\n\r',]/}"
[ -n "${_ka_content}" ] || KIND_ADDONS=""
unset _ka_content
KIND_ADDONS="${KIND_ADDONS:-${KIND_ADDONS_DEFAULT}}"
case "${KIND_ADDONS}" in none|NONE|None) KIND_ADDONS="" ;; esac
ADDON_SELECTED=()
# NAMED `_FILES`, NOT `_APPS`, DELIBERATELY. tests/scripts/test-kind-profile-app-
# closure.sh discovers the curated profile arrays with `^[A-Z0-9_]+_APPS=\(` and
# then FAILS any profile it parses zero entries from. A runtime accumulator called
# ADDON_APPS=() matches that regex, parses as an empty profile, and takes the whole
# closure gate red for a reason that has nothing to do with closure. The literal
# declarations (CORE_APPS, SSO_APPS) own that suffix; accumulators must not.
ADDON_APP_FILES=()
for _slug in ${KIND_ADDONS//,/ }; do
  _files="$(addon_files "${_slug}")"
  if [ -z "${_files}" ]; then
    echo "unknown KIND_ADDONS entry '${_slug}'. Known add-ons: $(addon_slugs | tr '\n' ' ')" >&2
    echo "  KIND_ADDONS=none disables all of them. An EMPTY value (or one that is nothing but separators) means UNSET and falls back to '${KIND_ADDONS_DEFAULT}'." >&2
    exit 1
  fi
  addon_selected "${_slug}" && continue
  ADDON_SELECTED+=("${_slug}")
  while read -r _f; do
    [ -n "${_f}" ] || continue
    # POST-CONDITION on the map, not on an exit code: a slug that names a file
    # which is not there would otherwise be discovered by kubectl, halfway
    # through a bring-up, as a sed reading a missing path.
    [ -r "${CLUSTER_DIR}/apps/${_f}" ] || {
      echo "FATAL: KIND_ADDONS add-on '${_slug}' maps to specs/cluster/apps/${_f}, which does not exist." >&2; exit 1; }
    # File-level dedupe, not just slug-level: two selected add-ons can share a
    # dependency row (keda carries metrics-server), and a duplicate would be
    # applied twice and land twice in the wait/status table.
    case " ${ADDON_APP_FILES[*]:-} " in *" ${_f} "*) continue ;; esac
    ADDON_APP_FILES+=("${_f}")
  done <<<"${_files}"
done

# READ-ONLY INTROSPECTION. `KIND_ADDONS_PRINT=1` resolves the selection, prints
# it and stops — no cluster, no kubectl, nothing created. It exists because the
# alternative for tests/scripts/test-kind-addon-channel.sh was to RE-IMPLEMENT
# this parse and then assert against its own copy, which measures the copy. This
# way the guard measures the bytes that run.
#
# It exits 0 having done no bring-up work, which in this file is normally the
# cardinal sin — so it says so, on stdout, unmissably. It is reachable only from
# an env var nothing else sets, it runs BEFORE the first mutation of anything, and
# `make kind-up` never sets it.
if [ "${KIND_ADDONS_PRINT:-}" = "1" ]; then
  echo "KIND_ADDONS_PRINT=1 — resolving the add-on selection only. NO cluster work was performed."
  echo "slugs: ${ADDON_SELECTED[*]:-}"
  echo "files: ${ADDON_APP_FILES[*]:-}"
  echo "known: $(addon_slugs | tr '\n' ' ')"
  echo "default: ${KIND_ADDONS_DEFAULT}"
  exit 0
fi

log() { echo "==> $*"; }
# Recreate a completed/failed Job. `kubectl delete job` BLOCKS on the pod's
# grace period, and a Job pod wedged in Terminating never releases it — observed
# hanging 30+ minutes on a clean bring-up, after which the hard wait below can
# never pass because the Job it waits for was never recreated. Force the
# deletion, do not wait on it, and then block until the object is genuinely gone
# so the re-apply cannot race a still-terminating predecessor.
recreate_job() { # <namespace> <job> <kustomize-dir>
  # A Job's spec is immutable, so it must be deleted before re-applying. The
  # delete is asynchronous, and applying into that window is REJECTED with
  #     Warning: Detected changes to resource <job> which is currently being
  #              deleted.
  # leaving no Job at all. That happened live on 2026-08-20 to vault-pki-init:
  # the apply's status was discarded, the script continued, and the failure
  # only surfaced 180s later as a confusing
  #     Error from server (NotFound): jobs.batch "vault-pki-init" not found
  # from the wait — which reads as "the job failed" rather than "the job was
  # never created". So: wait for the object to be genuinely GONE (not merely
  # unreadable), then apply with its exit status CHECKED and retried.
  #
  # THE 4th ARGUMENT IS A CONCURRENCY FIX, not a convenience. `kubectl apply -k`
  # applies the WHOLE kustomization, and kubectl honours no ArgoCD sync-wave: for
  # manifests/casdoor that means re-creating casdoor-init AND the three
  # derived-role sync Jobs at once, the precise race that banned the built-in
  # admin on 2026-09-16 (hugmesh-generator#396). It is only latent because those
  # three usually still exist here — until ttlSecondsAfterFinished: 600 has
  # reaped them, and then this apply recreates them alongside the Job it was
  # asked to restart. Name a single manifest file and only that file is applied;
  # ArgoCD re-creates the rest, in wave order, on its next sync.
  local ns="$1" job="$2" dir="$3" i rc
  local only="${4:-}"
  kubectl -n "${ns}" delete job "${job}" --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1 || true
  kubectl -n "${ns}" delete pods -l "job-name=${job}" --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1 || true
  # `get job` can transiently succeed while the object carries a
  # deletionTimestamp, so absence is asserted on the name listing rather than
  # on a bare get exit status.
  for i in $(seq 1 60); do
    [ -z "$(kubectl -n "${ns}" get job "${job}" -o name 2>/dev/null)" ] && break
    sleep 2
  done
  # Retry: even after the object disappears from the listing the apiserver can
  # briefly refuse the recreate. Three attempts, then fail LOUDLY — a silent
  # miss here takes out every step that depends on this Job.
  for i in 1 2 3; do
    if [ -n "${only}" ]; then
      if kubectl apply -f "${dir}/${only}" >/dev/null 2>&1; then
        return 0
      fi
    elif kubectl apply -k "${dir}" >/dev/null 2>&1; then
      return 0
    fi
    rc=$?
    sleep 5
  done
  echo "FATAL: could not (re)create job ${ns}/${job} from ${dir}${only:+/${only}} after 3 attempts (last kubectl apply rc=${rc:-?}). Everything downstream of this Job would fail with a misleading NotFound." >&2
  return 1
}


# Wait for a Job to reach a TERMINAL state and, when it is not success, PRINT THE
# EVIDENCE while the evidence still exists.
#
# `kubectl wait --for=condition=complete --timeout=Ns` cannot see a FAILED Job. It
# blocks for the entire timeout and then says
#     error: timed out waiting for the condition on jobs/<job>
# which reads as "slow" and can mean "dead ten minutes ago". And every Job in
# manifests/casdoor sets ttlSecondsAfterFinished: 600, so the command the old
# warning told the operator to run — `kubectl -n <ns> logs job/<job>` — returns
# "No resources found" a few minutes later. Both bit on 2026-09-16
# (hugmesh-generator#396): the bring-up died at the 600s mark on a casdoor-init
# that was still running and would succeed 7m37s afterwards, and by the time
# anyone looked, the Job it named was gone.
wait_job() { # <namespace> <job> <timeout-seconds>
  local ns="$1"
  local job="$2"
  local deadline="$3"
  local waited=0
  local succeeded=""
  local failed=""
  local reason=""
  local pod=""
  while [ "${waited}" -lt "${deadline}" ]; do
    succeeded="$(kubectl -n "${ns}" get job "${job}" -o jsonpath='{.status.succeeded}' 2>/dev/null)" || succeeded=""
    case "${succeeded}" in
      ''|0) ;;
      *) return 0 ;;
    esac
    failed="$(kubectl -n "${ns}" get job "${job}" -o jsonpath='{range .status.conditions[?(@.type=="Failed")]}{.status}{end}' 2>/dev/null)" || failed=""
    if [ "${failed}" = "True" ]; then
      reason="$(kubectl -n "${ns}" get job "${job}" -o jsonpath='{range .status.conditions[?(@.type=="Failed")]}{.reason}{" "}{.message}{end}' 2>/dev/null)" || reason=""
      warn "${ns}/${job} FAILED after ${waited}s: ${reason:-no reason reported}"
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done
  if [ "${failed}" != "True" ]; then
    warn "${ns}/${job} did not reach a terminal state within ${deadline}s"
  fi
  warn "dumping ${ns}/${job} now — ttlSecondsAfterFinished reaps it (and its logs) shortly:"
  kubectl -n "${ns}" get job "${job}" -o wide >&2 2>/dev/null || true
  kubectl -n "${ns}" describe job "${job}" 2>/dev/null | sed -n '/^Events:/,$p' >&2 || true
  for pod in $(kubectl -n "${ns}" get pods -l "job-name=${job}" -o name 2>/dev/null); do
    echo "    ---- ${pod} ----" >&2
    kubectl -n "${ns}" logs "${pod}" --all-containers --tail=80 >&2 2>/dev/null || true
  done
  return 1
}


warn() { echo "    WARN: $*" >&2; }

# openssl is not optional: step 3b mints the local-dev CA with it, and the mTLS
# post-condition at the end verifies an issued certificate with it. It used to be
# an undeclared dependency discovered halfway through a bring-up.
# The Studio installs its pinned kind under ~/.local/share/hugmesh-studio; a plain
# terminal does not see it. Appended as a fallback, so a system kind still wins.
_HM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
[ -f "${_HM_ROOT}/scripts/_tools-path-lib.sh" ] && { . "${_HM_ROOT}/scripts/_tools-path-lib.sh"; hugmesh_tools_path; }
for bin in kind kubectl docker git jq openssl base64; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "missing required tool: ${bin}" >&2; exit 1; }
done

# ─────────────────────────────────────────────────────────────────────────
# 0) ONE BRING-UP AT A TIME.
#
# Nothing stopped two of these running against the same cluster, and this script
# is neither atomic nor commutative: it applies Applications, seeds Vault KV,
# seeds the identity catalogue and then READS EACH BACK to verify. Two runs
# interleaved means one's read-back can observe the other's half-written state,
# and the failure surfaces as a verification error naming the thing that IS
# correct — the least useful place to start reading.
#
# It is not a hypothetical: this repo is worked by several sessions sharing one
# checkout, and the Studio button plus a terminal `make kind-up` are two doors to
# the same script with nothing between them. The Studio guards its OWN page
# (one verb at a time), which is exactly why the gap is invisible from there.
#
# Advisory and non-blocking (-n): a second run is REFUSED immediately with a
# sentence, never queued. Queueing would be worse — the operator would watch a
# silent process that is doing nothing.
#
# flock missing is a WARNING, not a failure: it is util-linux and effectively
# always present, but a bring-up that works must not start failing over a lock
# it never had. Say so rather than pretending the protection is there.
KIND_LOCK="${TMPDIR:-/tmp}/hugmesh-kind-${CLUSTER_NAME}.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>>"${KIND_LOCK}"
  if ! flock -n 9; then
    echo "FATAL: another bring-up of kind cluster '${CLUSTER_NAME}' is already running." >&2
    echo "  Two concurrent runs interleave the app applies, the Vault KV seed and the" >&2
    echo "  identity seed against ONE cluster, and each verifies by reading back what it" >&2
    echo "  just wrote — so they corrupt each other's post-conditions." >&2
    echo "  Wait for it to finish. To see who holds it: fuser -v ${KIND_LOCK}" >&2
    echo "  (Studio: its own page also refuses a second verb while one is running.)" >&2
    exit 1
  fi
else
  warn "flock not found — this run is NOT protected against a concurrent bring-up of '${CLUSTER_NAME}'"
fi

# ─────────────────────────────────────────────────────────────────────────
# 1) kind cluster (idempotent)
# ─────────────────────────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -x "${CLUSTER_NAME}" >/dev/null; then
  log "kind cluster '${CLUSTER_NAME}' already exists — reusing it"
else
  log "Creating kind cluster '${CLUSTER_NAME}' (this checkout mounted read-only for the tokenless local sync path)"
  # The repo mount can only exist if it is declared at CREATE time, and its
  # hostPath is this machine's checkout — unknowable to the committed
  # kind-local.yaml — so the config is rendered here: the committed file plus
  # one extraMounts block. READ-ONLY: nothing in the cluster may ever write
  # into the operator's working tree (a mesh image build reads it live).
  KIND_CFG="$(mktemp)"
  cat "${SCRIPT_DIR}/kind-local.yaml" > "${KIND_CFG}"
  cat >> "${KIND_CFG}" <<EOF
    # Appended by bootstrap-kind.sh (step 1): the tokenless local sync path.
    # gitops-repo-server.yaml serves this mount to ArgoCD via git daemon.
    extraMounts:
      - hostPath: ${REPO_ROOT}
        containerPath: ${LOCAL_GITOPS_MOUNT}
        readOnly: true
EOF
  kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CFG}"
  rm -f "${KIND_CFG}"
fi
kind export kubeconfig --name "${CLUSTER_NAME}" >/dev/null
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

kubectl version >/dev/null 2>&1 || { echo "cluster not reachable after kind create/export" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────
# 1b) EGRESS PREFLIGHT — can anything inside this node reach the outside?
#
# hugmesh-generator#349. On 2026-09-10 this lane ran for two days with no
# outbound connectivity at all: the host had lost every docker netfilter table
# (`nft list tables` returned only `inet firewalld`, whose filter_FORWARD ends
# `reject with icmpx admin-prohibited`, and the docker bridges belong to no
# firewalld zone). Nineteen pods sat in ImagePullBackOff past thirteen thousand
# attempts while `kubectl get nodes` reported Ready.
#
# The check is RAW TCP and deliberately not a name lookup. Docker's embedded
# resolver runs in the HOST network namespace, so it keeps answering through
# this outage — which is why every error in the logs read
#   dial tcp: lookup quay.io on 172.18.0.1:53: read udp ...: i/o timeout
# and looked exactly like DNS. A resolution-based preflight reports GREEN
# through the precise failure it exists to catch.
#
# TARGETS, in two tiers. Tier 1 is the registries this lane actually pulls
# from, RESOLVED ON THE HOST — the node is only ever handed a literal address,
# so nothing is resolved inside the netns whose resolver lies. Tier 2 is public
# anycast literals, a floor for a host that cannot resolve. Tier 1 exists
# because 1.1.1.1:443 / 8.8.8.8:53 / 9.9.9.9:443 are three PUBLIC DNS
# RESOLVERS, two of them on their DoH port, and none of them a registry: they
# are the single most commonly blocked destination class on a managed network,
# and probing only those turns "this lab forces its own resolver" into a hard
# abort of a bring-up that would have worked.
#
# NOTE ON PLACEMENT: this can only run once the node container exists, so on a
# COLD host `kind create cluster` above already had to pull the node image and
# will have died with its own opaque error first. This preflight covers the far
# commoner case — a host whose docker rules were lost while the node image was
# already cached.
# ─────────────────────────────────────────────────────────────────────────
if [ "${SKIP_EGRESS_PREFLIGHT:-0}" != "1" ]; then
  _egress_node="${CLUSTER_NAME}-control-plane"
  _egress_ok=0
  _egress_targets() {
    for _n in registry.k8s.io ghcr.io quay.io; do
      # `|| true` is not decoration. bootstrap-kind.sh runs under `set -euo
      # pipefail`, and a getent that cannot resolve exits 2, which pipefail
      # promotes to the pipeline's status. Without this the function dies at
      # the FIRST unresolvable name and never emits the anycast fallback, so a
      # host that merely has no DNS aborts its bring-up with no message at
      # all. It survives today only because the call site is a `for` word
      # list, where bash suppresses errexit — an accident, not a design.
      getent ahostsv4 "${_n}" 2>/dev/null | awk '$2 == "STREAM" { print $1 ":443"; exit }' || true
    done
    printf '%s\n' 1.1.1.1:443 8.8.8.8:53 9.9.9.9:443
  }
  for _hp in $(_egress_targets); do
    _h="${_hp%%:*}"; _p="${_hp##*:}"
    if docker exec "${_egress_node}" timeout 4 bash -c "exec 3<>/dev/tcp/${_h}/${_p}" >/dev/null 2>&1; then
      _egress_ok=1; break
    fi
  done
  if [ "${_egress_ok}" -eq 0 ]; then
    cat >&2 <<'EGRESSFAIL'

  ✗ The kind node cannot open a TCP connection to ANY public address.

    This is almost certainly NOT DNS, whatever the error text later says.
    Docker's embedded resolver answers from the host's namespace, so names keep
    resolving while nothing can actually connect.

    Check whether docker still owns any netfilter rules:

      docker run --rm --net=host --privileged alpine:3.20 \
        sh -c 'apk add -q nftables; nft list tables'

    If that prints only `table inet firewalld`, docker's rules are gone. They
    are installed once, at daemon start — `docker network create` does NOT
    reinstall them. Restart the daemon:

      sudo rc-service docker restart      # OpenRC / Gentoo
      sudo systemctl restart docker       # systemd

    Expect the kind node NOT to survive that restart, and REBUILD, do not
    merely re-run:

      make kind-down && make kind-up

    `make kind-up` alone is not enough. `kind get clusters` still NAMES a
    stopped cluster, so this script takes its "already exists - reusing it"
    branch and then hangs on an API server that is never coming back.

    To proceed anyway (an air-gapped host with every image already loaded):
      SKIP_EGRESS_PREFLIGHT=1 make kind-up

EGRESSFAIL
    exit 1
  fi
  log "Egress preflight: the node can reach the internet over raw TCP"
fi

# ─────────────────────────────────────────────────────────────────────────
# 1c) IN-NODE DNS PREFLIGHT — can the node's OWN resolver resolve a registry?
#
# hugmesh-generator#510 (child of #48). On 2026-09-09 argocd-repo-server sat in
# ImagePullBackOff on quay.io/argoproj/argocd with
#   dial tcp: lookup quay.io on 172.18.0.1:53: read udp ...: i/o timeout
# The node's resolver timed out, and every ComparisonError and every
# Init:ImagePullBackOff after it was downstream of that one fact. The bring-up
# kept waiting on a cluster that could never pull anything.
#
# This runs AFTER the raw-TCP egress preflight above and is the complement of
# it, not a duplicate: that probe deliberately avoids names (a host that lost its
# netfilter tables still resolves through docker's host-netns resolver), this one
# is a name lookup run INSIDE the node, so it uses the node's /etc/resolv.conf
# and not the host's.
#
# FAILS CLOSED. The only way past it is SKIP_NODE_DNS_PREFLIGHT=1, and that
# prints a banner on stderr every time it is used.
#   NODE_DNS_PROBE_NAME      name to resolve (default quay.io: the registry whose
#                            pull failed on 2026-09-09)
#   NODE_DNS_PROBE_ATTEMPTS  tries before giving up (default 3)
#   NODE_DNS_PROBE_SLEEP     seconds between tries (default 2)
# ─────────────────────────────────────────────────────────────────────────
if [ "${SKIP_NODE_DNS_PREFLIGHT:-0}" = "1" ]; then
  {
    echo
    echo "  !! SKIP_NODE_DNS_PREFLIGHT=1 — the in-node DNS preflight is DISABLED for this run."
    echo "  !! Nothing has checked that the kind node can resolve a registry name. If it"
    echo "  !! cannot, image pulls will time out and the bring-up will look like"
    echo "  !! ImagePullBackOff / ComparisonError downstream (hugmesh-generator#510)."
    echo
  } >&2
else
  _dns_node="${CLUSTER_NAME}-control-plane"
  _dns_name="${NODE_DNS_PROBE_NAME:-quay.io}"
  _dns_tries="${NODE_DNS_PROBE_ATTEMPTS:-3}"
  _dns_ok=0
  _dns_i=1
  while [ "${_dns_i}" -le "${_dns_tries}" ]; do
    if docker exec "${_dns_node}" timeout 20 getent hosts "${_dns_name}" >/dev/null 2>&1; then
      _dns_ok=1; break
    fi
    if [ "${_dns_i}" -lt "${_dns_tries}" ]; then sleep "${NODE_DNS_PROBE_SLEEP:-2}"; fi
    _dns_i=$((_dns_i + 1))
  done
  if [ "${_dns_ok}" -eq 0 ]; then
    # `|| true`: this only builds the message, and under `set -euo pipefail` an
    # unreadable resolv.conf must not kill the script before it can say why.
    _dns_resolv="$(docker exec "${_dns_node}" cat /etc/resolv.conf 2>/dev/null \
      | awk '$1 == "nameserver" { print $2 }' | paste -sd, - || true)"
    cat >&2 <<DNSFAIL

  ✗ The kind node cannot resolve '${_dns_name}' (${_dns_tries} attempt(s), run inside node '${_dns_node}').

    The node's resolver is: ${_dns_resolv:-<could not read nameserver lines from /etc/resolv.conf in the node>}

    Image pulls use the node's resolver, not the host's, so they will fail with
      dial tcp: lookup ${_dns_name} on <resolver>:53: i/o timeout
    and every ArgoCD Application and Init container behind them will follow.
    This is the 2026-09-09 failure (hugmesh-generator#48 / #510).

    Reproduce it by hand:
      docker exec ${_dns_node} getent hosts ${_dns_name}
      docker exec ${_dns_node} cat /etc/resolv.conf

    Fix DNS for that resolver, then rebuild the cluster:
      make kind-down && make kind-up

    To proceed anyway (an air-gapped host with every image already loaded):
      SKIP_NODE_DNS_PREFLIGHT=1 make kind-up
    That prints a warning banner on every run.

DNSFAIL
    exit 1
  fi
  log "In-node DNS preflight: node '${_dns_node}' resolves '${_dns_name}'"
fi

# ─────────────────────────────────────────────────────────────────────────
# 2) Label the single node with every capability the curated app subset
#    needs. Discovered by grepping the actual manifests (not guessed):
#      - hugmesh.net/pki=true         (vault, vault-pki-init, casdoor +
#        casdoor-pg, harbor + harbor-provision — all pinned to the pki node)
#      - hugmesh.net/local-path=true  (the local-path-provisioner
#        DaemonSet; every PVC above is carved from the hugmesh-local SC)
#    kubernetes.io/arch=amd64 is already correct on a kind/amd64 host. Nothing
#    in this curated subset needs hugmesh.net/backend or a
#    hugmesh.net/role=pki style label (checked — only the two above).
# ─────────────────────────────────────────────────────────────────────────
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
log "Labeling node '${NODE}' (pki=true, local-path=true)"
kubectl label node "${NODE}" \
  hugmesh.net/pki=true \
  hugmesh.net/local-path=true \
  --overwrite >/dev/null
if [ "${KIND_PROFILE}" = "sso" ]; then
  # The SSO slice adds workloads pinned to the backend tier (BFFs, their
  # Postgres) and the frontend tier (host shell, login/social UI remotes) —
  # same single-node collapse as pki/local-path above. Cassandra is the one
  # workload in the slice that pins the ROLE-shaped label
  # (hugmesh.net/role: pki), not a capability=true label — the core
  # profile's "nothing needs role=pki" note holds only for the core subset.
  log "Labeling node '${NODE}' (backend=true, frontend=true, role=pki — KIND_PROFILE=sso)"
  kubectl label node "${NODE}" \
    hugmesh.net/backend=true \
    hugmesh.net/frontend=true \
    hugmesh.net/role=pki \
    --overwrite >/dev/null
fi

# ─────────────────────────────────────────────────────────────────────────
# 3) Namespaces (plain kubectl apply, not an Application)
# ─────────────────────────────────────────────────────────────────────────
log "Namespaces"
kubectl apply -f "${CLUSTER_DIR}/namespaces/namespaces.yaml"

# ─────────────────────────────────────────────────────────────────────────
# 3b) LOCAL-DEV cluster CA. On a real node the `cluster-ca` Secret is
#     provisioned OFFLINE by keys-provision from the KEYS USB
#     (certs/cluster-ca.*); every consumer mounts it optional:true so pods
#     START without it — and then vault-pki-init spins forever ("Error
#     loading CA File: /ca/tls.crt") because its VAULT_CACERT never appears,
#     while vault-tls-init has already fallen back to a self-signed listener
#     cert the missing CA could never verify anyway. There is no USB here:
#     mint a throwaway CA (fresh key material per cluster, like the Vault
#     init below) and create the Secret in every consuming namespace BEFORE
#     the apps sync, so vault-tls-init signs its listener cert from it and
#     the pki-init chain is self-consistent.
# ─────────────────────────────────────────────────────────────────────────
if ! kubectl -n vault get secret cluster-ca >/dev/null 2>&1; then
  log "Minting LOCAL-DEV cluster CA (throwaway, this cluster only) + cluster-ca Secrets"
  CA_DIR="$(mktemp -d)"
  openssl req -x509 -newkey rsa:4096 -nodes -days 825 -sha384 \
    -subj "/CN=hugmesh kind local dev CA" \
    -keyout "${CA_DIR}/tls.key" -out "${CA_DIR}/tls.crt" >/dev/null 2>&1
  for ns in vault hugmesh-pki hugmesh-backend hugmesh-frontend external-secrets devops; do
    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n "${ns}" create secret tls cluster-ca \
      --cert="${CA_DIR}/tls.crt" --key="${CA_DIR}/tls.key" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  rm -rf "${CA_DIR}"
else
  log "cluster-ca Secret already present — keeping it (idempotent re-run)"
fi

# ─────────────────────────────────────────────────────────────────────────
# 4) Local storage. On kind this works AS-IS once the node carries
#    hugmesh.net/local-path=true — the provisioner just mkdir -p's
#    /mnt/data/local-path + /mnt/usb/local-path INSIDE the kind node
#    container's own filesystem; no real block devices needed.
# ─────────────────────────────────────────────────────────────────────────
log "Local storage (hugmesh-local StorageClass)"
kubectl apply -k "${CLUSTER_DIR}/manifests/local-path"

# hugmesh-local sets itself as the cluster-default StorageClass
# (storageclass.kubernetes.io/is-default-class: "true"). kind's own built-in
# class ("standard") is ALSO marked default, and having two default
# StorageClasses makes any unqualified PVC (no storageClassName) ambiguous —
# the PVC admission controller errors instead of picking one. Resolve it by
# stripping the default annotation from kind's "standard" class rather than
# touching hugmesh-local (every real-cluster PVC in this repo already pins
# storageClassName: hugmesh-local explicitly, so this only affects
# hypothetical unqualified PVCs on this dev cluster).
if kubectl get storageclass standard >/dev/null 2>&1; then
  IS_DEFAULT="$(kubectl get storageclass standard -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || true)"
  if [ "${IS_DEFAULT}" = "true" ]; then
    log "Removing default-class annotation from kind's built-in 'standard' StorageClass (avoid two defaults)"
    kubectl patch storageclass standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null
  fi
fi

# ─────────────────────────────────────────────────────────────────────────
# 5) ArgoCD — reuse bootstrap.sh's install + re-namespace + amd64-pin logic.
#    Deliberately do NOT apply bootstrap.sh's root app-of-apps step (that
#    pulls in all 96 Applications); we apply our curated subset directly
#    below instead.
# ─────────────────────────────────────────────────────────────────────────
log "Installing ArgoCD (${ARGOCD_VERSION}) into namespace '${ARGOCD_NS}'"
# --server-side (not plain `apply`): the upstream install.yaml's
# `applicationsets.argoproj.io` CRD has a schema large enough that the
# client-side kubectl.kubernetes.io/last-applied-configuration annotation
# kubectl apply would normally stamp on it overflows the 256KiB annotation
# value limit ("metadata.annotations: Too long"). Server-side apply doesn't
# use that annotation at all, so it doesn't hit the limit; --force-conflicts
# makes re-runs (idempotency) safe even if a previous run used plain apply.
curl -fsSL "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
  | sed "s/namespace: argocd/namespace: ${ARGOCD_NS}/g" \
  | kubectl apply -n "${ARGOCD_NS}" --server-side --force-conflicts -f -

log "Pinning ArgoCD components to kubernetes.io/arch=amd64 (matches the real x86_64-only ArgoCD host)"
PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64"}}}}}'
while read -r kind_ name; do
  [ -n "${name}" ] || continue
  kubectl -n "${ARGOCD_NS}" patch "${kind_}" "${name}" --type merge -p "${PATCH}" >/dev/null 2>&1 || true
done < <(kubectl -n "${ARGOCD_NS}" get deploy,statefulset -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null)

log "Waiting for ArgoCD to be ready"
kubectl -n "${ARGOCD_NS}" rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n "${ARGOCD_NS}" rollout status deploy/argocd-applicationset-controller --timeout=180s || true

# ─────────────────────────────────────────────────────────────────────────
# 5b) Repo access. hugmesh-generator is a PRIVATE GitHub repo — every
#     git-path Application below (Vault, vault-pki, ESO config, Casdoor,
#     harbor-provision, the whole SSO slice) fails to sync with
#     "authentication required: Repository not found" unless ArgoCD's
#     repo-server has SOMETHING it can fetch. Two paths, tried in order:
#
#     DEFAULT — TOKENLESS LOCAL SYNC (issue #48's local-first fix). Step 1
#     mounted this checkout read-only into the kind node at
#     ${LOCAL_GITOPS_MOUNT}; gitops-repo-server.yaml runs a read-only
#     `git daemon` (upload-pack only — receive-pack is off by default, and
#     the mount is read-only twice over) serving it at ${LOCAL_GITOPS_URL},
#     and every Application's repoURL is rewritten there. No GitHub
#     credential, no GitHub reachability: the local mesh syncs the tree the
#     operator is actually running. git daemon serves COMMITTED objects
#     only, so a dirty or mid-build working tree serves its last commit —
#     stale-but-consistent HEAD, which is exactly what a GitOps controller
#     should see. targetRevision defaults to HEAD here (this checkout's
#     current branch) unless HUGMESH_GITOPS_REV pins one.
#
#     OVERRIDE — ARGOCD_REPO_TOKEN (teams pointing at GitHub / the real
#     cluster's flow). The real cluster registers this same credential on
#     its OWN bootstrap path (../bootstrap.sh), token sourced out-of-band
#     from the offline KEYS USB (KEYS/gitops/repo-token) by keys-provision.
#     STRICTLY OPT-IN here: this script never invokes `gh` (or anything
#     else) to obtain a token on its own — silently materializing a live
#     personal credential into cluster storage must stay a deliberate act.
#       export ARGOCD_REPO_TOKEN="$(GH_TOKEN= gh auth token)"   # e.g.
#     A fine-grained PAT with read-only access to just this repo is
#     preferable to a personal `gh` token for anything longer-lived than a
#     throwaway kind cluster.
#
#     FAIL CLOSED under KIND_PROFILE=sso: a cluster with NEITHER path is not
#     a bring-up, it is the #48 outage — every git-path Application sits in
#     ComparisonError, vault-0 is never created, and the old warn-and-continue
#     let make/Studio report success over it. KIND_PROFILE=core keeps the old
#     warn (README documents supplying a token later; ArgoCD retries on its
#     own once the credential exists).
# ─────────────────────────────────────────────────────────────────────────
# Has ArgoCD DEMONSTRABLY fetched ${REPO} with what the cluster ALREADY has?
#
# Re-running against an existing cluster used to ignore this entirely: the two
# paths below only ever asked "$ARGOCD_REPO_TOKEN in *this* environment?" and
# "is the local mount serving?". A cluster bootstrapped once WITH a token, then
# re-run from a shell that no longer exports it, therefore fell through to the
# tokenless path and — under KIND_PROFILE=sso — FATALLED, naming a mount that
# nothing in that cluster reads. Live 2026-08-22: every git-path Application was
# synced to main's HEAD through a working repository Secret while the preflight
# refused to start the lane and prescribed `docker restart` on a healthy node.
#
# Proven by EVIDENCE, never by the Secret's existence. A stored token expires,
# and answering "yes, it is credentialed" over a dead credential would put back
# the exact #48 shape this whole block exists to prevent. Only ArgoCD can say
# whether a fetch SUCCEEDED, and it says it two ways, both required here:
#   * an Application on ${REPO} whose status records a RESOLVED commit (a bare
#     `targetRevision` is what the spec asked for; `.status.sync.revision` is
#     what the repo-server came back with), and
#   * no Application reporting the authentication ComparisonError of #48.
# Evidence also covers the case a credential check would get WRONG in the other
# direction: an anonymously readable repo fetches fine with no Secret at all.
#
# A fresh cluster has no Applications, so this is false and the paths below run
# exactly as before — it cannot weaken a first bootstrap, only a re-run.
ARGOCD_PROVEN_REV=""
argocd_repo_fetch_proven() {
  ARGOCD_PROVEN_REV=""
  local rows repo rev
  rows="$(kubectl -n "${ARGOCD_NS}" get applications --no-headers \
            -o custom-columns='REPO:.spec.source.repoURL,REV:.status.sync.revision' \
            2>/dev/null)" || return 1
  [ -n "${rows}" ] || return 1
  while read -r repo rev; do
    [ "${repo}" = "${REPO}" ] || continue
    # A resolved commit: hex, and long enough to be one. `<none>` (kubectl's
    # empty-field marker) and a branch name both fail this.
    case "${rev}" in
      ""|*[!0-9a-f]*) continue ;;
    esac
    [ "${#rev}" -ge 7 ] || continue
    ARGOCD_PROVEN_REV="${rev}"
    break
  done <<EOF
${rows}
EOF
  [ -n "${ARGOCD_PROVEN_REV}" ] || return 1
  # A credential that WAS working can expire. ArgoCD reports that on the
  # Application, in the words #48 was reported with. Deliberately NOT `grep -q`:
  # under `set -o pipefail` a -q match closes the pipe, kubectl dies of SIGPIPE,
  # and a FOUND error would report 141 — the very inversion this repo just spent
  # a day removing. Plain grep drains, and its exit status is identical.
  if kubectl -n "${ARGOCD_NS}" get applications --no-headers \
       -o custom-columns='MSG:.status.conditions[*].message' 2>/dev/null \
       | grep -Fi 'authentication required' >/dev/null; then
    ARGOCD_PROVEN_REV=""
    return 1
  fi
  return 0
}

ensure_repo_access() {
  if [ -n "${ARGOCD_REPO_TOKEN:-}" ]; then
    log "Registering ArgoCD repo credential for ${REPO} (from \$ARGOCD_REPO_TOKEN, never printed)"
    kubectl -n "${ARGOCD_NS}" create secret generic hugmesh-generator-repo \
      --from-literal=type=git \
      --from-literal=url="${REPO}" \
      --from-literal=username=x-access-token \
      --from-literal=password="${ARGOCD_REPO_TOKEN}" \
      --dry-run=client -o yaml \
      | kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" --dry-run=client -o yaml \
      | kubectl apply -f - >/dev/null
    return 0
  fi
  # An existing cluster that is already fetching ${REPO} needs nothing from
  # this step. Checked AFTER the token override on purpose: an operator who
  # exports ARGOCD_REPO_TOKEN is asking to (re)register that credential, which
  # is also the only way to REPLACE one that has expired.
  if argocd_repo_fetch_proven; then
    log "ArgoCD already fetches ${REPO} with the credential this cluster holds (an Application is synced at ${ARGOCD_PROVEN_REV}) — leaving it alone; export ARGOCD_REPO_TOKEN to replace it"
    return 0
  fi
  if [ "${REPO}" != "${GITOPS_REPO_DEFAULT}" ]; then
    # The caller pointed HUGMESH_GITOPS_REPO somewhere else on purpose (a
    # fork/mirror). Anonymously-readable ones sync fine with no credential;
    # a private one needs ARGOCD_REPO_TOKEN — say so, do not second-guess.
    log "HUGMESH_GITOPS_REPO=${REPO} with no \$ARGOCD_REPO_TOKEN — leaving it as-is (an anonymously readable repo syncs fine; a private one needs the token)"
    return 0
  fi
  # ── TOKENLESS LOCAL SYNC (the default) ──────────────────────────────────
  local missing=""
  if [ ! -e "${REPO_ROOT}/.git" ]; then
    missing="${REPO_ROOT} is not a git checkout (no .git) — there is nothing to serve"
  elif [ ! -d "${REPO_ROOT}/.git" ]; then
    # A linked worktree's .git is a FILE pointing at an object store OUTSIDE
    # this tree; the single read-only mount carries no objects to serve.
    missing="${REPO_ROOT}/.git is a file (a linked git worktree) — the kind mount carries no git object store; run from a full clone, or export ARGOCD_REPO_TOKEN"
  elif ! docker exec "${CLUSTER_NAME}-control-plane" test -d "${LOCAL_GITOPS_MOUNT}/.git" >/dev/null 2>&1; then
    missing="the kind node has no ${LOCAL_GITOPS_MOUNT} mount — cluster '${CLUSTER_NAME}' predates the tokenless local sync path and a mount can only be added at CREATE time; \`kind delete cluster --name ${CLUSTER_NAME}\` and re-run (a fresh cluster mounts it automatically), or export ARGOCD_REPO_TOKEN"
  fi
  if [ -n "${missing}" ]; then
    if [ "${KIND_PROFILE}" = "sso" ]; then
      echo "FATAL: ArgoCD has no way to fetch the GitOps repo, and KIND_PROFILE=sso cannot converge without one (issue #48: every git-path Application sits in 'authentication required', vault-0 is never created, and everything after the app applies is dead on arrival)." >&2
      echo "  missing: ${missing}" >&2
      echo "  remedies: fix the tokenless local sync as named above, or export ARGOCD_REPO_TOKEN=<token with read access to ${GITOPS_REPO_DEFAULT}> and re-run." >&2
      exit 1
    fi
    warn "${missing} — and \$ARGOCD_REPO_TOKEN is not set either, so every git-path Application below will fail to sync with 'authentication required' until one of the two paths is provided (see README.md). Continuing only because KIND_PROFILE=core tolerates supplying a credential later (ArgoCD retries on its own)."
    return 0
  fi
  log "Tokenless local sync: serving this checkout to ArgoCD via an in-cluster read-only git daemon"
  sed "s/namespace: devops/namespace: ${ARGOCD_NS}/g" "${SCRIPT_DIR}/gitops-repo-server.yaml" \
    | kubectl apply -f - >/dev/null
  kubectl -n "${ARGOCD_NS}" rollout status deploy/gitops-repo-server --timeout=180s >/dev/null \
    || { echo "gitops-repo-server never became ready — ArgoCD has nothing to fetch from. Diagnose: kubectl -n ${ARGOCD_NS} describe deploy/gitops-repo-server" >&2; exit 1; }
  REPO="${LOCAL_GITOPS_URL}"
  if [ -z "${REV_EXPLICIT}" ]; then
    REV="HEAD"   # this checkout's current branch, as of its last commit
    # The branch-override machinery must follow, or the vault/harbor apps
    # would track the LOCAL main while everything else tracks HEAD — two
    # different trees whenever the operator works on a branch. Only the
    # defaults are retargeted; an explicit override still wins.
    [ "${VAULT_BRANCH}" = "main" ] && VAULT_BRANCH="HEAD"
    [ "${HARBOR_BRANCH}" = "main" ] && HARBOR_BRANCH="HEAD"
  fi
  log "  repoURL -> ${REPO}"
  log "  targetRevision -> ${REV} (git daemon serves committed objects only: a dirty/mid-build tree syncs its last COMMIT — stale but consistent)"
}
ensure_repo_access

# ─────────────────────────────────────────────────────────────────────────
# 6) The curated Application subset — applied directly with kubectl, NOT via
#    the root app-of-apps. Cross-Application sync-wave ordering (the
#    argocd.argoproj.io/sync-wave annotations on individual Applications) is
#    only enforced by ArgoCD when Applications are children of a common
#    parent app-of-apps; applied standalone like this they sync independently
#    and concurrently. That's fine here: every hook Job below is
#    idempotent/retrying (backoffLimit, PostSync re-run on selfHeal), so the
#    curated set converges even without strict cross-app ordering — it just
#    may take a couple of reconcile loops.
#
#    Non-Harbor apps (Vault, vault-pki, ESO controller + config, Casdoor,
#    ingress-nginx-internal) exist on `main` unmodified — read straight from
#    this checkout so local edits/forks are picked up naturally, and repoint
#    repoURL/targetRevision at $REPO/$REV like bootstrap.sh's own app-of-apps
#    step does (so this also works against a fork).
#
#    Harbor's two Applications (03a-harbor.yaml, 03b-harbor-provision.yaml)
#    do not exist on main at all yet — fetched from $HARBOR_BRANCH via
#    `git show`. 03b's manifests (specs/cluster/manifests/harbor/*) ALSO only
#    exist on $HARBOR_BRANCH, so its targetRevision is overridden from `main`
#    to $HARBOR_BRANCH so ArgoCD's controller fetches the right content live.
#    03a sources a Helm chart (helm.goharbor.io), not a git path in this repo,
#    so it needs no such override — only fetching the Application object
#    itself from the branch that defines it.
# ─────────────────────────────────────────────────────────────────────────
# ONE apply helper for EVERY Application this bootstrap applies — including the
# three that used to carry bespoke `git show` blocks.
#
# WHY THOSE BLOCKS ARE GONE (2026-08-26). 02-vault.yaml, 03a-harbor.yaml and
# 03b-harbor-provision.yaml were read with `git show <branch>:<path>` because
# their manifests only existed on unmerged branches. Both branches merged, and
# the defaults have said `main` here for a while: VAULT_BRANCH=main,
# HARBOR_BRANCH=main, and the tokenless-local-sync path retargets both to HEAD
# alongside REV. So on EVERY default run the `git show` was reading the same
# bytes the working tree already holds — one network fetch and two ref
# resolutions later. Verified before the change, not assumed:
#   * `git show HEAD:specs/cluster/apps/<f>` was byte-identical to the
#     checked-out file for all three;
#   * 03a's sed is a no-op on it — its repoURL is https://helm.goharbor.io and
#     its targetRevision is the chart's `1.16.x`, so neither expression matches;
#   * 02/03b's sed pair is character-for-character the pair below.
#
# It is NOT a cosmetic collapse. Those three were invisible to
# tests/scripts/test-kind-profile-app-closure.sh, which models the applied set
# from the *_APPS arrays: Harbor was applied but not modelled, so the guard had
# to carry two "ANALOGY" exemptions for 00b-cassandra-init's references to it.
# Modelling them retires both exemptions and makes the references load-bearing.
#
# THE OVERRIDE MACHINERY IS KEPT, generalised into app_pin(): point VAULT_BRANCH
# or HARBOR_BRANCH at anything other than the revision the rest of the tree is
# read at and that one file goes back to the `git show` path, so the next
# not-yet-merged Application can still be validated exactly the same way.
app_pin() { # <file> -> the branch this file must be read from, or nothing
  case "$1" in
    02-vault.yaml)
      [ "${VAULT_BRANCH}" != "${REV}" ] && printf '%s' "${VAULT_BRANCH}" ;;
    03a-harbor.yaml|03b-harbor-provision.yaml)
      [ "${HARBOR_BRANCH}" != "${REV}" ] && printf '%s' "${HARBOR_BRANCH}" ;;
  esac
  return 0
}

# The Application object name a manifest declares. Used to build the wait/status
# list for the RUNTIME-selected add-ons, which no hand-maintained list could
# track. Prints nothing for an ApplicationSet (`kind: Application$` is anchored),
# which is correct: `kubectl get application <appset>` does not resolve, and the
# caller treats an empty answer as fatal for an add-on.
app_object_name() { # <file> -> metadata.name, or nothing
  sed -n '/^kind: Application$/,$ { /^  name:/ { s/^  name:[[:space:]]*//; s/[[:space:]]*$//; p; q; } }' \
    "${CLUSTER_DIR}/apps/$1"
}

apply_core_app() {
  local file="$1"
  local pin ref
  pin="$(app_pin "${file}")"
  if [ -z "${pin}" ]; then
    log "Applying (working tree) specs/cluster/apps/${file}"
    sed -e "s#repoURL: https://github.com/hugmesh/hugmesh-generator.git#repoURL: ${REPO}#" \
        -e "s#targetRevision: main#targetRevision: ${REV}#" \
        "${CLUSTER_DIR}/apps/${file}" | kubectl apply -f -
    return
  fi
  # Prefer a local ref if this checkout already has the branch; fall back to
  # origin/<branch>.
  git -C "${REPO_ROOT}" fetch -q origin "${pin}" 2>/dev/null || true
  if git -C "${REPO_ROOT}" rev-parse --verify -q "${pin}" >/dev/null; then
    ref="${pin}"
  else
    ref="origin/${pin}"
  fi
  log "Applying (${ref}) specs/cluster/apps/${file} — BRANCH-PINNED (targetRevision main -> ${pin})"
  git -C "${REPO_ROOT}" show "${ref}:specs/cluster/apps/${file}" \
    | sed -e "s#targetRevision: main#targetRevision: ${pin}#" \
          -e "s#repoURL: https://github.com/hugmesh/hugmesh-generator.git#repoURL: ${REPO}#" \
    | kubectl apply -f -
}

# ── 6a) THE ADD-ONS GO ON FIRST (sync-wave "-1" substrate) ──────────────────
# metrics-server and KEDA both carry argocd.argoproj.io/sync-wave "-1", the same
# early wave as calico/ingress, because the autoscaling substrate has to exist
# before the workloads that autoscale it. Applied STANDALONE (see the note at the
# top of step 6) sync-waves buy no cross-Application ordering at all, so the
# ORDER OF APPLY is the only ordering lever this script actually holds — and it
# spends it here. The same lever is why 15-kyverno.yaml precedes
# 14-workload-console-rbac.yaml in SSO_APPS below (PR #167).
if [ "${#ADDON_APP_FILES[@]}" -gt 0 ]; then
  log "KIND_ADDONS=${ADDON_SELECTED[*]} — ${#ADDON_APP_FILES[@]} add-on Application(s) on top of the curated base"
  for f in "${ADDON_APP_FILES[@]}"; do
    apply_core_app "${f}"
  done
else
  log "KIND_ADDONS=none — no infra add-ons selected"
fi
# HONESTY, same rule as the MFA refusal at the top: name the unperformed work
# rather than letting a green bring-up imply it. Only under sso, because the core
# profile applies no HPA at all and warning there would be noise.
if [ "${KIND_PROFILE}" = "sso" ] && ! addon_selected metrics-server; then
  warn "metrics-server is NOT in KIND_ADDONS. This profile applies SEVEN HorizontalPodAutoscalers (admin-bff-api, user-bff-api, hugmesh-host-shell and four social-ui remotes). With no resource-metrics API every one of them reports <unknown>/70% and pins its Deployment at the replicas floor — a state nothing in this bring-up reports as a failure, and which reads exactly like an idle cluster. Re-run with KIND_ADDONS=metrics-server (the default) to make them real."
fi

CORE_APPS=(
  02-vault.yaml                    # the cluster secret store (branch-pin retired 2026-08-26; see app_pin above)
  06-vault-pki.yaml                # vault-pki-init PostSync hook Job
  03-external-secrets.yaml         # ESO controller + CRDs (Helm chart)
  04-external-secrets-config.yaml  # ClusterSecretStore "hugmesh-vault" + ExternalSecrets
  11-ingress-nginx-internal.yaml   # nginx-internal (LAN/VPN-only) — Harbor's Ingress uses this class
  05-casdoor.yaml                  # Casdoor + its dedicated casdoor-pg Postgres
  03a-harbor.yaml                  # Harbor (Helm chart Application — the sed is a genuine no-op on it)
  03b-harbor-provision.yaml        # Harbor projects/robots/OIDC (git path -> $REV)
)
for f in "${CORE_APPS[@]}"; do
  apply_core_app "${f}"
done

# Explicitly NOT applied under KIND_PROFILE=core (deliberately out of scope
# for the identity/registry validation pass — see README.md): apps/
# 00-cassandra.yaml, apps/03-gitlab.yaml, the gateway apps, Matrix
# (30-tuwunel), Mastodon (30-akkoma), games (50-games, 06-casdoor-games),
# media-poisoner, and every other Application under specs/cluster/apps not
# listed above.

# ─────────────────────────────────────────────────────────────────────────
# 6b) KIND_PROFILE=sso — the native-login slice on top of the core. Everything
#     tests/e2e/specs/27-native-login.spec.ts touches: the fe-gateway front
#     door (chart Ingress), the route-access seed DB (permitAll /bff/login
#     row), admin-bff (bff_ session custody + /bff/internal back-channel) +
#     user-bff (the /bff/login relocation) with their Postgres, Cassandra
#     (gateway revocation list / URL registry), the Angular host shell and the
#     login/social UI remotes. First-party images must ALREADY be loaded into
#     the kind node under their rendered refs (`make kind-images`) — nothing
#     here can pull them from the in-cluster Harbor.
# ─────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────
# 5c) NAMESPACES THE CURATED APPS TARGET BUT NOTHING IN THIS SLICE CREATES.
#
# external-secrets-config's ExternalSecrets and workload-console-rbac's
# per-tier RoleBindings name app tiers whose own Applications are NOT in this
# curated subset, so nothing ever created them and both Applications failed to
# sync — for MONTHS, with an error that names Kubernetes rather than the cause:
#
#   Failed last sync attempt: namespaces "hugmesh-forum" not found,
#   namespaces "observability" not found, namespaces "hugmesh-image-builds"
#   not found, namespaces "velero" not found
#   error running kubectl auth reconcile: error getting namespace
#
# Creating them here is deliberate and is NOT the same as deploying those
# tiers: an empty namespace costs nothing, lets ESO materialize the secrets a
# later tier will need, and lets the console's RoleBindings land. The tier's
# own workloads still only arrive with its own Application.
#
# Idempotent (create --dry-run=client | apply), like the cluster-CA step above.
log "Ensuring the namespaces the curated Applications target"
for ns in hugmesh-forum hugmesh-games hugmesh-games-instances hugmesh-owncast \
          hugmesh-tube hugmesh-image-builds hugmesh-service-catalog-builds \
          observability velero; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

SSO_APPS=(
  00-cassandra.yaml       # gateway backing store (the Bitnami Helm CHART only)
  # 00b-cassandra-init.yaml is NOT optional and NOT a nicety. apps/00-cassandra.yaml
  # installs the Bitnami chart, which ships PasswordAuthenticator ON and with no
  # application keyspaces and no roles but the `cassandra` superuser. The keyspace
  # + least-privilege-role bootstrap lives in a SEPARATE Application because a Helm
  # -sourced Application has no `path:` for extra git-managed manifests.
  #
  # Omitting it here deployed a Cassandra that no gateway could ever authenticate
  # against. Observed live: `DESC KEYSPACES` returned system keyspaces only and
  # `LIST ROLES` returned exactly one row (`cassandra`), so fe-gateway crash-looped
  # on `Provided username fe_gw_cass and/or password are incorrect` — which reads
  # like a rotated-password problem and is really a role that was never created.
  # apps/00b-cassandra-init.yaml says so itself: "until this Job runs there is no
  # combination of settings under which a gateway can start".
  00b-cassandra-init.yaml # keyspaces + per-app roles + grants (sync-wave 1)
  06-route-access-db.yaml # gateway_route_access seed incl. permitAll /bff/login
  20-gateway-fe.yaml      # fe-gateway chart (front door + Ingress)
  30-admin-bff-db.yaml
  31-admin-bff-api.yaml   # session custody + internal-token back-channel
  34-user-bff-db.yaml
  37-user-bff-api.yaml    # POST /bff/login (native-login relocation)
  40-frontend.yaml        # Angular host shell (hugmesh-host-shell)
  45-social-ui.yaml       # login-ui remote (+ matrix/mastodon/admin remotes)
  # ── SELF-SERVICE PROFILE + PASSWORD SURFACE ────────────────────────────────
  # 47-user-ui is the /user/** micro-frontend: profile, preferences, email and
  # PASSWORD CHANGE. It was never in this list, and the consequence was not a
  # missing feature but a LIE: apps/20-gateway-fe.yaml:225-227 applies the route
  #
  #     - id: user-ui
  #       uri: http://hugmesh-user-ui.hugmesh-frontend.svc.cluster.local:80
  #       path: /user/**
  #
  # unconditionally, so on kind GET /user/** hit a live route pointing at a
  # Service with no endpoints. The API behind it (/bff/user/**) was fine — routed
  # at 20-gateway-fe.yaml:276-278 and ALLOWed by the route-access seed — so the
  # endpoint answered a curl and was dead in a browser, and the host shell's
  # remote mount (hugmesh-host-shell app.routes.ts, remoteName 'user') could not
  # fetch its remoteEntry. tests/scripts/test-kind-profile-route-closure.sh now
  # fails a routed-but-undeployed Service, so this cannot recur silently.
  47-user-ui.yaml         # /user/** remote: profile, preferences, PASSWORD CHANGE
  # federation-api is the vanity/public-profile publish target user-bff calls when
  # a profile save turns Public on. Without it that call is a CONNECTION failure,
  # not an HTTP status, and hugmesh-user-bff-api's FederationApiClient.onErrorMap
  # translates only WebClientResponseException — so an unreachable federation-api
  # surfaces to the browser as an untranslated 500 rather than an honest 503.
  # (Widening that onErrorMap is a hugmesh-user-bff-api change and is NOT landable
  # from this repo — see the unit report.)
  #
  # Its DB Application comes with it (wave 1 before wave 2). The ESO Secrets both
  # need (federation-db-auth / federation-db-app-auth) are already created by
  # 04-external-secrets-config in CORE_APPS, and scripts/gen-cluster-secrets.sh
  # already seeds secret/<brand>/federation-db, so nothing else has to move.
  #
  # ⚠ NOT A CLAIM OF PARITY WITH DOCKER: `make kind-images` must build these two
  # images (scripts/kind-load-images.sh now lists hugmesh-user-ui and
  # hugmesh-federation-api). An operator who brings the profile up with a stale
  # image set gets ImagePullBackOff — which is at least a POD saying so, instead
  # of a 503 from a route into the void.
  28-federation-db.yaml   # federation-api's Postgres (sync-wave 1)
  29-federation-api.yaml  # module-federation registry + vanity publish (sync-wave 2)
  # Kyverno MUST precede 14-workload-console-rbac: that Application carries the
  # deploy-provenance ClusterPolicy, and without kyverno.io/v1 registered ArgoCD
  # cannot even render it —
  #   failed to discover server resources for group version kyverno.io/v1
  # — so the Application sat OutOfSync/Missing on every kind cluster ever built,
  # and the admission backstop it exists to install was simply absent. The
  # Application was already in the repo (wave -1, for exactly this ordering); it
  # was only ever missing from THIS curated list.
  #
  # Do NOT "fix" that by applying the CRDs alone: the policy is Enforce with
  # failurePolicy Fail, so CRDs without the controller give a Synced Application
  # over an admission webhook that admits everything.
  15-kyverno.yaml               # policy engine — registers kyverno.io/v1 for the ClusterPolicy below
  14-workload-console-rbac.yaml # workload-console SAs + token Secrets (lights the dual-SA client the committed admin-bff overlay already enables; RoleBindings for app-tier namespaces absent from this slice degrade that Application partially, which is the honest state)
  # casdoor-domains ApplicationSet (issue #47, per-domain own-IdP lane). INERT
  # here: it ships with ZERO list elements, so it generates nothing until a
  # writer supplies an idp=own domain — it is applied in this profile ONLY so
  # apply_core_app's sed retargets the GitHub repoURL/targetRevision literals
  # inside its TEMPLATE at the tokenless local git daemon (the issue-#48
  # contract: a repo-synced ApplicationSet would keep the GitHub literal and
  # generate Applications that cannot fetch on kind).
  05b-casdoor-domains.yaml
)
if [ "${KIND_PROFILE}" = "sso" ]; then
  for f in "${SSO_APPS[@]}"; do
    apply_core_app "${f}"
  done
  # kyverno.io/v1 has to be REGISTERED before ArgoCD can render the ClusterPolicy
  # inside 14-workload-console-rbac. Listing kyverno first is not enough —
  # Applications sync asynchronously, so array order buys nothing on its own.
  # ArgoCD's selfHeal would converge eventually, but "eventually" means this
  # bring-up reports a MISSING admission backstop as the settled state of a
  # cluster that was merely slow, which is the kind of green nobody re-checks.
  #
  # Warn, never FATAL: kyverno pulls from ghcr.io, and a local mesh that cannot
  # reach it still has every other slice working. The warning names the
  # consequence rather than the symptom.
  log "Waiting for Kyverno to register kyverno.io/v1 (the ClusterPolicy needs it)"
  kyverno_ok=""
  for _ in $(seq 1 60); do
    if kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then kyverno_ok=1; break; fi
    sleep 5
  done
  if [ -n "${kyverno_ok}" ]; then
    kubectl wait --for=condition=Established crd/clusterpolicies.kyverno.io --timeout=60s >/dev/null 2>&1 \
      || warn "clusterpolicies.kyverno.io exists but never reached Established"
    # It may have failed its first render before the CRD landed; make it retry now.
    kubectl -n "${ARGOCD_NS}" annotate application workload-console-rbac \
      argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
    log "  kyverno.io/v1 registered"
  else
    warn "Kyverno never registered kyverno.io/v1 after 5m — 14-workload-console-rbac cannot render its deploy-provenance ClusterPolicy, so the digest-pinning admission backstop is ABSENT on this cluster (not merely unsynced). Diagnose: kubectl -n ${ARGOCD_NS} get app kyverno; kubectl -n kyverno get pods"
  fi
  # The fe-gateway chart's Ingress ships className "nginx" (the real cluster's
  # public controller). kind runs ONLY ingress-nginx-internal, which registers
  # class "nginx-internal" — without this override the Ingress is admitted by
  # nothing and the host ports mapped by kind-local.yaml never route. A helm
  # parameter (not a values edit) so the committed chart stays untouched.
  #
  # ⚠ `--type merge` REPLACES spec.source.helm.parameters WHOLESALE, so every
  # parameter a gateway Application needs on kind must ride in ONE patch: a
  # second merge patch of the same list would silently drop the first one's
  # entries (the ingress override would vanish and nothing would route). That is
  # why the MFA flip below APPENDS to this list instead of patching again.
  #
  # MFA=1 (see the parse at the top): flip app.mfa.enabled on the gateway via the
  # same helm-parameter mechanism. ⚠ hugmesh-gateway-fe is the ONLY gateway
  # Application this profile applies (SSO_APPS above) — if another gateway app is
  # ever added there, it needs the same MFA parameter treatment, and
  # tests/stack/test-mfa-flip-wiring.sh fails the build until it gets it.
  #
  # HTTPS-ONLY FRONT DOOR ON KIND. In a real cluster this Ingress is the
  # SECONDARY path and Cloudflare Tunnel terminates TLS at the edge, so the
  # chart leaves `ingress.tls` false and adds no redirect — correct there, and
  # deliberately not changed here (a force-redirect in front of an edge that
  # forwards plaintext with X-Forwarded-Proto: https is how you build a redirect
  # loop). On kind there is no Cloudflare: this Ingress IS the front door, and
  # kind-local.yaml publishes BOTH 80 -> 8080 and 443 -> 8443, so without a
  # redirect the whole application answers 200 in cleartext on :8080 — sessions,
  # bearer tokens and all. Measured before this override: `curl -H 'Host:
  # hugmesh.net' http://127.0.0.1:8080/` returned 200 with the host shell.
  #
  # `force-ssl-redirect` (not `ssl-redirect`) because the plain form only acts
  # when the Ingress carries a TLS block, and this one deliberately does not —
  # the controller serves it under its own default certificate. Harbor's Ingress
  # in this same cluster already redirects, so this also ends an inconsistency
  # where one door on the mesh was strict and the other was open.
  # ⚠ `forceString: true` is LOAD-BEARING, not decoration. It makes ArgoCD use
  # `helm --set-string`, which renders `"true"`; a plain `--set` renders a YAML
  # BOOLEAN, and `metadata.annotations` is map[string]string, so the API server
  # rejects the whole Ingress ("cannot unmarshal bool into string"). The failure
  # lands on the Application as a sync error, not on this script — i.e. the door
  # would simply stop routing with nothing here to blame. Verified both ways
  # with `helm template` before this was committed.
  #
  # The `\\\\.` spelling survives two unescapings: bash double-quotes collapse it
  # to `\\`, then JSON collapses that to the single `\` helm's --set parser needs
  # to read a dot as literal rather than as a path separator.
  GW_FE_PARAMS='{"name":"ingress.className","value":"nginx-internal"}'
  GW_FE_PARAMS="${GW_FE_PARAMS},{\"name\":\"ingress.annotations.nginx\\\\.ingress\\\\.kubernetes\\\\.io/force-ssl-redirect\",\"value\":\"true\",\"forceString\":true}"
  if [ -n "${MFA}" ]; then
    GW_FE_PARAMS="${GW_FE_PARAMS},{\"name\":\"mfa.enabled\",\"value\":\"true\"}"
    log "MFA=1: gateway MFA enforcement ON for this kind run (helm parameter mfa.enabled=true; floor stays off — docs/MFA-ROLLOUT.md §3)"
  fi
  log "Overriding fe-gateway ingress.className -> nginx-internal (kind has no public controller), force-ssl-redirect -> true (this Ingress is the front door here)"
  kubectl -n "${ARGOCD_NS}" patch application hugmesh-gateway-fe --type merge -p \
    "{\"spec\":{\"source\":{\"helm\":{\"parameters\":[${GW_FE_PARAMS}]}}}}" >/dev/null
fi

# ─────────────────────────────────────────────────────────────────────────
# 7) Wait (best-effort) for the curated Applications to reach Synced/Healthy.
#    Not fatal on timeout — full end-to-end convergence (esp. Harbor, which
#    is missing its Vault-issued TLS secret until the migration branch's ESO
#    config also lands) is a separate validation pass; this just gives
#    visibility into how far things got.
# ─────────────────────────────────────────────────────────────────────────
APP_NAMES=(vault vault-pki external-secrets external-secrets-config ingress-nginx-internal casdoor harbor harbor-provision)
if [ "${KIND_PROFILE}" = "sso" ]; then
  # cassandra-init belongs here, not just in SSO_APPS. It is what actually makes
  # Cassandra usable (keyspaces + per-app roles + grants); the `cassandra` entry
  # above only covers the Bitnami chart. Omitting it from the wait list meant the
  # bring-up neither waited for the bootstrap Job nor listed it in the closing
  # status table — so a Cassandra with no roles looked, from the bootstrap's own
  # output, exactly like a healthy one, and the failure surfaced much later as an
  # unrelated-looking gateway auth error.
  #
  # kyverno and workload-console-rbac are the SAME DEFECT, found 2026-08-26 by
  # the wait-list leg of tests/scripts/test-kind-profile-app-closure.sh. PR #167
  # added both to SSO_APPS and neither to this list, so for every kind bring-up
  # since, the script neither waited for them nor printed them in the closing
  # status table. A Kyverno that never came up — and therefore a deploy-provenance
  # ClusterPolicy that never rendered, which is the exact admission backstop
  # 14-workload-console-rbac exists to install — was indistinguishable from a
  # healthy one in this script's own output. The kyverno CRD wait further down
  # only warns; it is not the status table, and warnings scroll.
  #
  # THIRD RECURRENCE, 2026-08-27: hugmesh-user-ui (47-user-ui.yaml), federation-db
  # (28-federation-db.yaml) and hugmesh-federation-api (29-federation-api.yaml) all
  # joined SSO_APPS in this integration and none joined this list, so the guard
  # caught the identical shape a third time. Added below.
  #
  # A DERIVATION WAS TRIED AND DELIBERATELY BACKED OUT. Looping over SSO_APPS with
  # app_object_name would end this rot at the source -- but the closure guard reads
  # this list STATICALLY (it greps the `APP_NAMES+=(...)` literals out of the script
  # text), so a runtime loop is invisible to it and EVERY SSO app immediately reported
  # as unwaited. The guard already special-cases exactly one derived form, matched by
  # the literal string `APP_NAMES+=("${addon_app_name}")`. Teaching it a second one is
  # the right fix, but it means editing the guard to accept the very change it would
  # then be checking, so it belongs in its own change with its own negative controls --
  # not smuggled into an integration merge. Until then the list stays explicit and the
  # guard stays fully strict: the list rots, and the gate catches it every time.
  APP_NAMES+=(cassandra cassandra-init route-access-db hugmesh-gateway-fe admin-bff-db admin-bff-api user-bff-db user-bff-api hugmesh-host-shell hugmesh-social-ui kyverno workload-console-rbac hugmesh-user-ui federation-db hugmesh-federation-api)
  # 05b-casdoor-domains.yaml is deliberately NOT here: it is an ApplicationSet,
  # not an Application, so `kubectl get application casdoor-domains` never
  # resolves — and it generates zero children until a writer supplies an idp=own
  # domain. The closure guard carries that as a NAMED exemption rather than
  # letting the absence look like the oversight above.
fi
# Add-on Applications join the wait/status list too — DERIVED from the manifest,
# never hand-listed. The selection is a runtime value, so a second literal list
# could not track it, and a hand-listed name that drifts from the file's
# metadata.name is precisely how an Application becomes invisible here.
for f in ${ADDON_APP_FILES[@]+"${ADDON_APP_FILES[@]}"}; do
  addon_app_name="$(app_object_name "${f}")"
  [ -n "${addon_app_name}" ] || {
    echo "FATAL: add-on manifest specs/cluster/apps/${f} declares no Application metadata.name — it would be applied and then never waited for, never reported, and its failure would be invisible." >&2
    exit 1; }
  APP_NAMES+=("${addon_app_name}")
done
log "Waiting up to 5m for curated Applications to reach Synced/Healthy (best-effort)"
deadline=$((SECONDS + 300))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  all_done=1
  for a in "${APP_NAMES[@]}"; do
    sync="$(kubectl -n "${ARGOCD_NS}" get application "${a}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl -n "${ARGOCD_NS}" get application "${a}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ] || all_done=0
  done
  [ "${all_done}" -eq 1 ] && break
  sleep 5
done
log "Application status:"
kubectl -n "${ARGOCD_NS}" get applications.argoproj.io "${APP_NAMES[@]}" \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null || true

if [ "${SKIP_VAULT_BOOTSTRAP}" = "1" ]; then
  if [ "${KIND_PROFILE}" = "sso" ]; then
    echo "KIND_PROFILE=sso needs the Vault bootstrap (KV seeding feeds every ESO Secret the login path reads) — unset SKIP_VAULT_BOOTSTRAP" >&2
    exit 1
  fi
  log "SKIP_VAULT_BOOTSTRAP=1 — skipping the Vault init/unseal/PKI sequence. Done."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────
# 8) LOCAL-DEV-ONLY: Vault init + unseal + PKI bootstrap.
#
#    The real Vault (manifests/vault) is a persistent Raft StatefulSet, NOT
#    dev-mode and NOT auto-initialized — `vault operator init` is documented
#    as a one-time, by-hand OPERATOR step in keys-template/vault/README.md,
#    normally followed by writing the unseal key + root token to the offline
#    KEYS USB stick. There is no USB stick here, so this step replicates the
#    SAME manual sequence programmatically, generating FRESH key material
#    every time it runs against a cluster that isn't already initialized —
#    nothing is hardcoded, nothing is persisted outside this cluster's own
#    Secrets. This does NOT touch the real KEYS-USB provisioning flow; it is
#    local-dev-only plumbing to get PKI issuing roles usable for validation.
# ─────────────────────────────────────────────────────────────────────────
log "Waiting for vault-0 pod to be Running"
kubectl -n vault wait --for=condition=PodScheduled pod/vault-0 --timeout=180s >/dev/null 2>&1 || true
# FAIL CLOSED (issue #48). This used to warn and `exit 0`, so `make kind-up`
# and the Studio reported SUCCESS over a cluster whose Vault pod was never
# even created — the live #48 outage sat behind exactly this exit. The Vault
# bootstrap below is not optional decoration: the script itself refuses
# SKIP_VAULT_BOOTSTRAP=1 under sso as mandatory, and nothing after this point
# (PKI, KV seed, identity seed, the mTLS post-condition) can happen without
# vault-0. A bring-up that cannot produce vault-0 is a FAILED bring-up.
wait_for_vault_pod() {
  local i phase="" cond
  for i in $(seq 1 "${VAULT_POD_WAIT_TRIES:-60}"); do
    phase="$(kubectl -n vault get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "${phase}" = "Running" ] && return 0
    sleep "${VAULT_POD_WAIT_SLEEP:-5}"
  done
  echo "FATAL: vault-0 never reached Running (phase='${phase:-not created}'). The Vault init/unseal/PKI bootstrap is mandatory — refusing to report a successful bring-up without it." >&2
  # Name the likeliest cause instead of leaving a dead cluster to spelunk: on
  # the #48 cluster vault-0 was 'not created' because the vault Application
  # had never synced — ArgoCD had no repo access.
  cond="$(kubectl -n "${ARGOCD_NS}" get application vault -o jsonpath='{.status.conditions[*].message}' 2>/dev/null || true)"
  [ -n "${cond}" ] && echo "  Application vault condition: ${cond}" >&2
  case "${cond}" in
    *"authentication required"*|*"Repository not found"*)
      echo "  That is the missing-repo-access signature (issue #48): re-run this script — the default tokenless local sync serves this checkout to ArgoCD — or export ARGOCD_REPO_TOKEN=<read token> first." >&2 ;;
  esac
  echo "  Diagnose: kubectl -n ${ARGOCD_NS} get applications; kubectl -n vault get events --sort-by=.lastTimestamp | tail -20" >&2
  return 1
}
wait_for_vault_pod || exit 1

VEXEC=(kubectl -n vault exec vault-0 -c vault --)

STATUS_JSON="$("${VEXEC[@]}" vault status -format=json 2>/dev/null || true)"
INITIALIZED="$(printf '%s' "${STATUS_JSON}" | jq -r '.initialized // false' 2>/dev/null || echo false)"

if [ "${INITIALIZED}" = "true" ]; then
  log "Vault already initialized (idempotent re-run) — checking seal status only"
  SEALED="$(printf '%s' "${STATUS_JSON}" | jq -r '.sealed // true')"
  if [ "${SEALED}" = "true" ]; then
    if kubectl -n vault get secret vault-unseal >/dev/null 2>&1; then
      log "Vault sealed — resubmitting the unseal key from the existing vault-unseal Secret"
      KEY="$(kubectl -n vault get secret vault-unseal -o jsonpath='{.data.unseal-key}' | base64 -d)"
      "${VEXEC[@]}" vault operator unseal "${KEY}" >/dev/null
    else
      warn "Vault is sealed and initialized but no local vault-unseal Secret exists (state from a previous run/cluster) — unseal it by hand (see keys-template/vault/README.md)."
    fi
  else
    log "Vault already unsealed"
  fi
else
  log "Vault not initialized — running the one-time 'vault operator init -key-shares=1 -key-threshold=1' (LOCAL DEV ONLY: single Shamir share, no HA custody)"
  INIT_JSON="$("${VEXEC[@]}" vault operator init -key-shares=1 -key-threshold=1 -format=json)"
  UNSEAL_KEY="$(printf '%s' "${INIT_JSON}" | jq -r '.unseal_keys_b64[0]')"
  ROOT_TOKEN="$(printf '%s' "${INIT_JSON}" | jq -r '.root_token')"

  log "Unsealing Vault"
  "${VEXEC[@]}" vault operator unseal "${UNSEAL_KEY}" >/dev/null

  log "Seeding LOCAL-DEV Secrets (fresh key material, generated just now — never committed anywhere)"
  # vault-unseal (ns vault): the auto-unseal sidecar's key, so a pod restart
  # comes back unattended exactly like the real USB-KEYS-seeded flow.
  kubectl -n vault create secret generic vault-unseal \
    --from-literal=unseal-key="${UNSEAL_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # vault-bootstrap (ns vault): the token vault-pki-init's PostSync hook Job
  # reads (VAULT_TOKEN, optional:true).
  # eso-provider-refs: conditional-ok a root token exists exactly once, at `vault operator init`, and cannot be re-derived afterwards. Whoever initialized this Vault wrote it here (this branch, or the KEYS custody on the real-node path), so on the already-initialized branch it is a precondition rather than something to create. If it is genuinely gone the root token is gone with it, and the read-back at the KV seed below stops the run with that exact message instead of guessing.
  kubectl -n vault create secret generic vault-bootstrap \
    --from-literal=token="${ROOT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # vault-token (ns external-secrets): the ClusterSecretStore "hugmesh-vault"
  # auth Secret, so ESO can actually reach Vault (KV + the PKI issue paths the
  # per-app mTLS ExternalSecrets use) instead of just having Vault up unused.
  kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n external-secrets create secret generic vault-token \
    --from-literal=token="${ROOT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  echo
  echo "    LOCAL-DEV Vault root token (also stored in Secret vault/vault-bootstrap): ${ROOT_TOKEN}"
  echo "    LOCAL-DEV Vault unseal key (also stored in Secret vault/vault-unseal):    ${UNSEAL_KEY}"
  echo "    These are throwaway, freshly-generated for THIS kind cluster only — never reuse them anywhere real."
  echo
fi

# ─────────────────────────────────────────────────────────────────────────
# 8b) PER-NAMESPACE GENERATOR CREDENTIALS (vault-ca + vault-token).
#
#     The 29 VaultDynamicSecret generators in specs/cluster/manifests (23 in
#     hugmesh-backend, 5 in hugmesh-pki, 1 in hugmesh-frontend) are what mint
#     EVERY mTLS identity in the mesh. Each one declares
#
#         provider:
#           caProvider: { type: Secret, name: vault-ca, key: ca.crt }
#           auth: { tokenSecretRef: { name: vault-token, key: token } }
#
#     BOTH of those resolve in the GENERATOR'S OWN NAMESPACE and nowhere else.
#     ESO passes resolvers.EmptyStoreKind for generators, and
#     pkg/utils/resolvers/secret_ref.go only honours a cross-namespace
#     ref.Namespace when storeKind == ClusterSecretStoreKind — the constant is
#     documented upstream as "not cluster-scoped, hence resources cannot be
#     resolved across namespaces". So the ClusterSecretStore's own
#     external-secrets/vault-token does NOT serve them, and there is no way to
#     point them at one central copy: the Secrets must exist per namespace.
#
#     Neither existed. This bootstrap minted cluster-ca (below, step 3b) and one
#     external-secrets/vault-token (above) and stopped there, so all 26
#     generator-backed ExternalSecrets sat in SecretSyncedError with
#     `cannot get Kubernetes secret "vault-ca": secrets "vault-ca" not found`,
#     no *-mtls Secret was ever created, and every pod mounting one (both
#     gateways, every BFF, the DB TLS sidecars, harbor, coturn) hung in Init:0/1
#     on `MountVolume.SetUp failed for volume "pki"`. Not one certificate had
#     ever been issued in a kind cluster.
#
#     The offline/real-node path (specs/etc/keys-provision/provision.sh) already
#     seeds both into exactly these namespaces from the USB KEYS stick; only the
#     kind path was missing them. This block closes that gap so the two delivery
#     paths agree.
#
#     vault-ca carries ONLY the PUBLIC CA certificate (cluster-ca's tls.crt
#     republished under the key name `ca.crt` that caProvider asks for). Nothing
#     here is committed to git — both values are read back from the live cluster,
#     so this is correct whether the CA was minted by step 3b or provisioned
#     offline. Derived, not hardcoded: a checked-in certificate would be wrong
#     for every freshly bootstrapped cluster, which fails TLS verification
#     instead — the same outage wearing a different error message.
#
#     On the PRIVATE key: this block does not move it, and does not need to —
#     caProvider only ever wants the public cert. That is a property of THIS
#     block and not of the cluster, and it would be false to claim more: step 3b
#     above deliberately creates the FULL `cluster-ca` kubernetes.io/tls Secret
#     (tls.crt AND tls.key) in six namespaces — vault, hugmesh-pki,
#     hugmesh-backend, hugmesh-frontend, external-secrets, devops — because
#     vault-pki-init imports the CA key into Vault's pki_int and vault-tls-init
#     signs the listener cert with it. That is a throwaway local-dev CA whose key
#     material is generated fresh per cluster and never leaves it, but "the CA
#     private key stays in the vault namespace" is simply not true here, and a
#     design rationale resting on it would be resting on nothing.
# ─────────────────────────────────────────────────────────────────────────
log "Seeding per-namespace generator credentials (vault-ca + vault-token)"

GEN_NAMESPACES="hugmesh-pki hugmesh-backend hugmesh-frontend"

# The CA that actually signs Vault's listener cert. vault-tls-init copies this
# very file to /vault/tls/ca.crt when it signs, so trusting it is trusting the
# real chain rather than an assumption about one.
GEN_CA_CRT="$(kubectl -n vault get secret cluster-ca -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
# The token the generators authenticate to Vault with — the same one the
# ClusterSecretStore already uses.
GEN_TOKEN="$(kubectl -n external-secrets get secret vault-token -o jsonpath='{.data.token}' 2>/dev/null || true)"

if [ -z "${GEN_CA_CRT}" ]; then
  echo "vault/cluster-ca has no tls.crt — the mTLS generators cannot verify Vault's TLS and no certificate would ever be issued. Refusing to continue with a half-provisioned PKI." >&2
  exit 1
fi

# FALLBACK, not an abort. external-secrets/vault-token is created in exactly ONE
# place — the not-initialized `else` branch of step 8 above — so a run against an
# ALREADY-INITIALIZED Vault never creates it. The first cut of this block simply
# `exit 1`-ed there, which killed the whole bring-up (vault-pki-init, casdoor-init
# and the entire SSO slice, all of which follow) over a Secret the script is
# perfectly able to reconstruct: vault/vault-bootstrap holds the SAME root token
# and this script already reads it 60 lines below to seed Vault KV. Verified on
# kind-hugmesh-local: vault/vault-bootstrap.token, external-secrets/vault-token
# .token and hugmesh-backend/vault-token.token are byte-identical.
#
# The recovery is deliberately FLAT — read, fail hard on the spot if there is
# genuinely no token anywhere, then create — rather than nesting the create
# inside a second `if [ -n … ]`. Nested, the only statement that creates
# external-secrets/vault-token would still sit two branches deep and
# tests/scripts/eso_provider_refs.py would still, correctly, report that nothing
# creates it on the default path.
if [ -z "${GEN_TOKEN}" ]; then
  GEN_TOKEN="$(kubectl -n vault get secret vault-bootstrap -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [ -n "${GEN_TOKEN}" ] || { echo "neither external-secrets/vault-token nor vault/vault-bootstrap carries a Vault token — the mTLS generators cannot authenticate to Vault and nothing below can seed KV either. This means no run has ever initialized this Vault (or its Secrets were deleted): tear the cluster down and re-bootstrap, or restore vault/vault-bootstrap from the KEYS custody." >&2; exit 1; }
  log "  external-secrets/vault-token absent (Vault was already initialized, so the branch that creates it did not run) — recovering the same root token from vault/vault-bootstrap"
  # Backfill it too. Without it the ClusterSecretStore "hugmesh-vault" cannot
  # authenticate either, so every KV-backed ExternalSecret is as dead as the
  # generators were — the same outage one layer over.
  kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-token
  namespace: external-secrets
type: Opaque
data:
  token: ${GEN_TOKEN}
EOF
  log "  external-secrets/vault-token restored for the ClusterSecretStore"
fi

for ns in ${GEN_NAMESPACES}; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # Built as literal Secret manifests so the base64 values move across without
  # ever being written to disk or echoed to the log.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-ca
  namespace: ${ns}
type: Opaque
data:
  ca.crt: ${GEN_CA_CRT}
---
apiVersion: v1
kind: Secret
metadata:
  name: vault-token
  namespace: ${ns}
type: Opaque
data:
  token: ${GEN_TOKEN}
EOF
  log "  ${ns}: vault-ca (public CA cert) + vault-token ready"
done
unset GEN_TOKEN

# vault-pki-init: WAIT FOR THE EFFECT, NEVER RECREATE THE JOB.
#
# The old code here recreated the Job imperatively and then waited on
# `job/vault-pki-init`, on the stated assumption that "a plain re-apply of its
# manifests recreates+reruns it directly". That assumption is FALSE, and it cost a
# whole bring-up on 2026-08-27:
#
#   vault-pki-init never completed — cannot seed KV
#   Error from server (NotFound): jobs.batch "vault-pki-init" not found
#
# MEASURED, not inferred. Applying the manifests exactly as this script did creates
# the Job and it is GONE within 5 seconds, every time. The ArgoCD controller log says
# why, in its own words:
#     PostSync/0 hook batch/Job:vault/vault-pki-init ... waiting for completion of hook
# The Job carries `argocd.argoproj.io/hook: PostSync` and
# `hook-delete-policy: BeforeHookCreation`, so ArgoCD OWNS its lifecycle and deletes
# the previous instance before creating the next. Two writers, one object: whichever
# `kubectl wait` lands in the delete window reports NotFound, which reads as "the job
# failed" when the job is in fact fine. Its pod on that very run reached Completed
# with "==> Vault PKI bootstrap complete".
#
# So stop racing the owner. Wait for what the Job is FOR -- pki_int mounted with at
# least one issuing role -- which is true regardless of which Job instance produced it,
# survives ArgoCD deleting and recreating the hook mid-check, and is exactly the
# precondition the KV seed below actually needs. Waiting on an actor you do not own is
# a race; waiting on the effect is not.
log "Waiting for vault-pki-init's EFFECT (pki_int + issuing roles), not for the Job object"
pki_ready() {
  local tok
  tok="$(kubectl -n vault get secret vault-bootstrap -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)"
  [ -n "${tok}" ] || return 1
  kubectl -n vault exec vault-0 -c vault -- env \
      VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="${tok}" \
      vault list -format=json pki_int/roles 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1
}
PKI_DEADLINE=$((SECONDS + 600))
until pki_ready; do
  if [ "${SECONDS}" -ge "${PKI_DEADLINE}" ]; then
    echo "FATAL: pki_int has no issuing roles after 600s — the vault-pki PostSync hook never succeeded." >&2
    echo "       This is a HARD gate: every per-app TLS Secret below is ESO-materialized from" >&2
    echo "       pki_int/issue/<app>, so seeding KV now would produce a cluster that looks seeded" >&2
    echo "       and cannot issue a single certificate." >&2
    echo "       The hook Job is deleted and recreated by ArgoCD, so it may not exist right now;" >&2
    echo "       read the POD by label instead of the job by name:" >&2
    echo "         kubectl -n vault logs -l job-name=vault-pki-init --tail=50" >&2
    echo "         kubectl -n devops get application vault-pki -o jsonpath='{.status.operationState.message}'" >&2
    exit 1
  fi
  sleep 5
done
log "  pki_int is bootstrapped and has issuing roles"

if [ "${KIND_PROFILE}" = "sso" ]; then
  # ───────────────────────────────────────────────────────────────────────
  # 9) Vault KV seeding (SSO profile). Every Secret the login path consumes
  #    (casdoor admin/db creds, the per-app client secrets — casdoor-init and
  #    user-bff read the SAME hugmesh/casdoor-apps path, so one write aligns
  #    both sides — the BFF DB creds, the AES custody key, the internal
  #    back-channel token) is ESO-materialized from Vault KV. scripts/
  #    gen-cluster-secrets.sh already writes exactly these paths in its ONLINE
  #    mode; the only kind-specific part is reaching Vault: no host `vault`
  #    CLI or cert plumbing needed — a PATH shim execs the CLI already inside
  #    vault-0 (VAULT_SKIP_VERIFY because the in-pod loopback hostname is not
  #    a SAN on the vault-tls-init cert; the token never leaves kubectl exec).
  # ───────────────────────────────────────────────────────────────────────
  # HARD gate on vault-pki-init: the KV seed below is useless until Vault is
  # reachable over the cluster-ca chain, and 403s taught us the soft 180s
  # warn above is not enough — a still-running pki-init means the engine
  # setup (and any policy work) hasn't happened yet.
  # The hard gate is now the EFFECT check above, which has already run and already
  # exits 1 on failure. Re-waiting on job/vault-pki-init here would reintroduce the
  # exact race it was written to close: ArgoCD can delete the hook between the two
  # waits, and the second one would then fail on a cluster whose PKI is perfectly fine.
  log "pki_int verified above (effect, not Job object) — proceeding to KV seed"

  log "Seeding Vault KV for the SSO slice (seed-vault-kv.sh -> gen-cluster-secrets.sh ONLINE via vault-0 exec shim)"
  ROOT_TOKEN="$(kubectl -n vault get secret vault-bootstrap -o jsonpath='{.data.token}' | base64 -d)"
  [ -n "${ROOT_TOKEN}" ] || { echo "vault-bootstrap Secret missing/empty — cannot seed KV" >&2; exit 1; }
  # KV v2 at mount "secret" is a FIXED contract (keys-template/vault/README.md:
  # the ESO ClusterSecretStore reads provider vault, KV v2, mount `secret`) —
  # but NOTHING in-tree mounts it; on a real cluster that is part of the
  # by-hand `vault operator init` sequence. Mount it here, idempotently.
  if ! kubectl -n vault exec vault-0 -c vault -- env \
        VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="${ROOT_TOKEN}" \
        vault secrets list -format=json 2>/dev/null | jq -e '."secret/"' >/dev/null; then
    log "Mounting KV v2 at secret/ (the ESO ClusterSecretStore's fixed contract)"
    kubectl -n vault exec vault-0 -c vault -- env \
      VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="${ROOT_TOKEN}" \
      vault secrets enable -path=secret -version=2 kv
  fi
  SHIM_DIR="$(mktemp -d)"
  cat > "${SHIM_DIR}/vault" <<'SHIM'
#!/bin/bash
exec kubectl -n vault exec -i vault-0 -c vault -- env \
  VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  VAULT_TOKEN="${VAULT_TOKEN}" vault "$@"
SHIM
  chmod +x "${SHIM_DIR}/vault"
  # VAULT_ADDR only gates the script's online mode — the shim always talks to
  # the in-pod loopback listener regardless of its value.
  #
  # NOT gen-cluster-secrets.sh directly: it mints EVERY password unconditionally
  # (`openssl rand` + `vault kv put`), so a second run rotates credentials that
  # the already-initialized Postgres volumes will never re-read (initdb only runs
  # on an empty PGDATA) and the BFFs come back with
  # `password authentication failed for user "userbff"`. seed-vault-kv.sh adds
  # the already-done guard its neighbours here (cluster-CA, Vault init, KV mount)
  # all have; KIND_KV_RESEED=1 is the deliberate, destructive override.
  PATH="${SHIM_DIR}:${PATH}" VAULT_ADDR="https://in-cluster-via-exec-shim" VAULT_TOKEN="${ROOT_TOKEN}" \
    REPO_ROOT="${REPO_ROOT}" BRAND="${BRAND:-hugmesh}" \
    bash "${SCRIPT_DIR}/seed-vault-kv.sh" --out "${SHIM_DIR}/bundle"
  rm -rf "${SHIM_DIR}"

  # ───────────────────────────────────────────────────────────────────────
  # 10) Wait for the casdoor-init seed Job (same gate the in-cluster
  #     test-runner orchestrator enforces), then seed the deterministic e2e
  #     identity catalogue against the live Casdoor: seed-accounts.sh --roles
  #     renders apply-systems-roles.sh (idempotent add-user/update-role over
  #     the Casdoor API) — run it through a short-lived port-forward.
  #     casdoor-init may have already run and failed before the KV seed above
  #     landed its Secrets — retrigger it once, same recreate idiom as
  #     vault-pki-init.
  # ───────────────────────────────────────────────────────────────────────
  #     ONE MANIFEST, NOT THE DIRECTORY. manifests/casdoor holds four PostSync
  #     hook Jobs that all log in as the same built-in/admin account, ordered by
  #     argocd.argoproj.io/sync-wave — and `kubectl apply -k` honours no wave. Re-
  #     applying the whole directory therefore re-creates the three wave-1 sync
  #     Jobs alongside casdoor-init whenever ttlSecondsAfterFinished has already
  #     reaped them, which is the exact four-way race that tripped casdoor's
  #     sign-in throttle and killed a bring-up on 2026-09-16
  #     (hugmesh-generator#396). ArgoCD re-creates the other three itself, in
  #     wave order, on its next sync.
  #     THE TIMEOUT IS 20 MINUTES, and that is not padding: casdoor's sign-in
  #     lockout is 15 minutes, so any wait shorter than that can — and did —
  #     expire while the cluster is merely serving out a ban it will recover from
  #     on its own. The old 600s expired 7m37s before the Job succeeded.
  log "Re-running casdoor-init now that Vault KV + ESO secrets exist"
  recreate_job hugmesh-pki casdoor-init "${CLUSTER_DIR}/manifests/casdoor" init-job.yaml
  wait_job hugmesh-pki casdoor-init 1200 \
    || { warn "casdoor-init did not complete (evidence dumped above)"; exit 1; }

  # THIS IS WHERE A KIND RUN STARTS (tests/stack/e2e-password.sh, "WHERE A RUN
  # STARTS"): mint a NEW shared e2e password BEFORE seed-accounts.sh runs (below)
  # and BEFORE the test-seed-passwords Secret is created (further down), unless
  # $E2E_PASSWORD is set (kept) or E2E_PASSWORD_KEEP=1 (reuse the file's value).
  # Starting it HERE, in this process, means the seed-accounts.sh subprocess
  # below inherits it via plain env (E2E_PASSWORD is exported) and does not
  # rotate again, the apply hook reconciles every persona already in a
  # persisted Casdoor to it (set-password), and the Secret creation later in
  # this same function sees the same value too.
  # shellcheck source=../../../../tests/stack/e2e-password.sh
  . "${REPO_ROOT}/tests/stack/e2e-password.sh"
  e2e_password_start_run \
    || { warn "could not start this run's E2E_PASSWORD (see tests/stack/e2e-password.sh)"; exit 1; }

  log "Seeding e2e identities (seed-accounts.sh --roles) against the kind Casdoor"
  SEED_DIR="$(mktemp -d)"
  # THE EXTRAS ARE NOT OPTIONAL. seed-accounts.sh's built-in catalogue covers the
  # base role matrix only; the personas specs 13/15/17/29 and the ad-hoc UI suite
  # sign in as (e2e-fleet, e2e-superadmin, e2e-banned, the @gmail.com handles,
  # dragoneer, rbac-*) live in tests/e2e-extra-personas.sh. The compose lane had
  # always applied them and this lane never had, so a fully working cluster still
  # answered spec 29 with "native login e2e-fleet -> 401" — a persona that had
  # simply never been created, reading exactly like a broken login.
  # shellcheck source=../../../../tests/e2e-extra-personas.sh
  . "${REPO_ROOT}/tests/e2e-extra-personas.sh"
  EXTRA_ROLE_USERS="${E2E_EXTRA_PERSONAS}" \
    bash "${REPO_ROOT}/tests/qemu/seed-accounts.sh" --roles "${SEED_DIR}"
  kubectl -n hugmesh-pki port-forward svc/casdoor 18000:8000 >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT
  for i in $(seq 1 20); do
    curl -sf http://127.0.0.1:18000/api/health >/dev/null 2>&1 && break
    sleep 2
  done
  # apply-systems-roles.sh logs in as the Casdoor built-in admin. That password
  # is NOT a fixed dev constant — gen-cluster-secrets.sh generated it into
  # secret/<brand>/casdoor during the KV seed above (property
  # admin_password_plain; the sibling admin_password is the hashed form Casdoor
  # stores). Read it back from Vault rather than re-deriving it, so the seed
  # always uses the password this cluster actually has.
  CASDOOR_ADMIN_PASS="$(kubectl -n vault exec vault-0 -c vault -- env \
      VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="${ROOT_TOKEN}" \
      vault kv get -field=admin_password_plain "secret/${BRAND:-hugmesh}/casdoor" 2>/dev/null)"
  [ -n "${CASDOOR_ADMIN_PASS}" ] || { echo "could not read the Casdoor admin password from Vault — cannot seed identities" >&2; exit 1; }
  # apply-systems-roles.sh checks every Casdoor response ENVELOPE (.status), not
  # just the HTTP code — Casdoor answers a DENIED call with HTTP 200 +
  # {"status":"error"}, so the previous `curl -sf` hook could (and did) run the
  # entire seed unauthenticated and still exit 0. A WRONG admin password is the
  # documented fresh-cluster state, so this must fail loudly rather than
  # "succeed" against nothing.
  CASDOOR_URL="http://127.0.0.1:18000" CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS}" \
    bash "${SEED_DIR}/roles/apply-systems-roles.sh"
  # POSITIVE POST-CONDITION: re-authenticate from scratch and read the catalogue
  # back. The hook reporting on its own work is not evidence; this is. Without
  # it the bootstrap can print "SSO slice seeded." over an empty Casdoor.
  log "Verifying the identity seed actually landed (independent read-back)"
  CASDOOR_URL="http://127.0.0.1:18000" CASDOOR_ADMIN_PASS="${CASDOOR_ADMIN_PASS}" \
    bash "${SCRIPT_DIR}/verify-seeded-identities.sh" "${SEED_DIR}/roles"
  kill "${PF_PID}" 2>/dev/null || true
  trap - EXIT
  # test-seed-passwords: the same deterministic-password Secret the in-cluster
  # test Jobs envFrom (optional). Host-side playwright reads the E2E_* env
  # directly, but create it anyway so a later in-cluster runner finds it.
  # E2E_PASSWORD is the ACTUAL value e2e_password_start_run minted (or kept)
  # above (and seed-accounts.sh --roles just seeded into Casdoor with) — never
  # a literal, so this Secret cannot drift from what personas can really log in
  # with.
  kubectl -n hugmesh-frontend create secret generic test-seed-passwords \
    --from-literal=E2E_PASSWORD="${E2E_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -rf "${SEED_DIR}"

  echo
  # Reached only after apply-systems-roles.sh AND verify-seeded-identities.sh
  # both succeeded, so this line is a claim the script has evidence for.
  log "SSO slice seeded (identity catalogue read back and verified). Host entry: https://hugmesh.net via 127.0.0.1:8443 (kind-local.yaml port map)"
  echo "    e2e:  make kind-e2e   (repo root — resolver-maps hugmesh.net -> 127.0.0.1, runs spec 27)"
fi

# ─────────────────────────────────────────────────────────────────────────
# 12) POSITIVE POST-CONDITION FOR mTLS ISSUANCE.
#
#     Step 8b seeds vault-ca and vault-token and then says "ready". That is the
#     hook reporting on its own work. It is not evidence that a certificate was
#     issued, and until this block existed the script printed "Done." over a
#     cluster in which NOT ONE mTLS certificate had ever been minted — which is
#     precisely the outage 8b was written for. A bring-up that cannot detect its
#     own headline failure is a bring-up that will ship it again.
#
#     Same posture as the identity read-back above: enumerate what the REPO says
#     should exist, wait for it, then verify the RESULT independently — a real
#     X.509 leaf, in date, whose private key matches it, chaining to the cluster
#     CA the truststores use. Secret existence alone would pass on an empty file.
#
#     THE DENOMINATOR COMES FROM THE REPO, NOT THE CLUSTER.
#     The first cut of this block enumerated the generator-backed ExternalSecrets
#     the LIVE CLUSTER declared and verified those. That makes the one failure
#     mode it most needs to see invisible: if the ExternalSecret ITSELF never
#     lands, it is absent from the enumeration too, so the denominator shrinks
#     with the failure and the check only fails at exactly zero. Measured on the
#     live kind cluster: the repo declares 29 VaultDynamicSecret generators under
#     specs/cluster, the cluster carried 26, and the block cheerfully reported
#     "mTLS verified: 26/26" and printed Done. A post-condition whose denominator
#     is supplied by the thing under test is not a post-condition.
#
#     So: the expected set is read out of the manifests. A generator the repo
#     declares and the cluster does not carry is a FAILURE — unless the manifest
#     that declares it says, in the source and with a reason, that it is not
#     delivered by default. That marker is itself checked: it may not sit on a
#     generator that IS live (a stale exemption would mask the next regression),
#     and a marker with no usable reason is not an exemption.
# ─────────────────────────────────────────────────────────────────────────
verify_mtls_issuance() {
  local deadline_s="${MTLS_VERIFY_TIMEOUT:-600}"
  local spec_dir="${MTLS_SPEC_DIR:-${CLUSTER_DIR:-}}"
  local targets n_targets i tmp ca_file ns sec es subject issuer
  local missing="" rc=0 verified=0 sample=""
  local declared n_declared live_keys gen file reason key live
  local undelivered="" stale="" badreason="" n_expected=0 n_exempt=0

  # ── what the REPO declares must be issued ─────────────────────────────
  # Both metadata spellings in use are handled (flow `metadata: { name: x,
  # namespace: y }` — 27 of them — and the block form the two dark overlays
  # use). The opt-out marker is scoped to the YAML DOCUMENT it appears in, so it
  # cannot drift onto a neighbouring generator in the same file.
  if [ -z "${spec_dir}" ] || [ ! -d "${spec_dir}" ]; then
    echo "mTLS post-condition FAILED: cannot read the manifest tree (MTLS_SPEC_DIR/CLUSTER_DIR='${spec_dir}'), so the set of generators that OUGHT to be issued is unknown. An unverifiable post-condition is a failure, not a pass." >&2
    return 1
  fi
  declared="$(find "${spec_dir}" -type f \( -name '*.yaml' -o -name '*.yml' \) -exec awk '
      function emit() {
        if (ingen && nm != "" && ns != "") {
          printf "%s\t%s\t%s\t%s\n", ns, nm, FILENAME, doc_reason
          ingen = 0; inmeta = 0; nm = ""; ns = ""
        }
      }
      FNR == 1 { doc_reason = ""; ingen = 0; inmeta = 0; nm = ""; ns = "" }
      /^---[ \t]*$/ { doc_reason = ""; ingen = 0; inmeta = 0; nm = ""; ns = ""; next }
      /^[ \t]*#[ \t]*mtls-issuance:[ \t]*not-delivered/ {
        i = index($0, "not-delivered") + 13
        doc_reason = substr($0, i)
        gsub(/^[ \t]+|[ \t]+$/, "", doc_reason)
        next
      }
      /^kind:[ \t]*VaultDynamicSecret[ \t]*$/ { ingen = 1; nm = ""; ns = ""; next }
      ingen && /^metadata:[ \t]*\{/ {
        line = $0
        if (match(line, /[{,][ \t]*name:[ \t]*[A-Za-z0-9._-]+/)) {
          nm = substr(line, RSTART, RLENGTH); sub(/^[{,][ \t]*name:[ \t]*/, "", nm)
        }
        if (match(line, /[{,][ \t]*namespace:[ \t]*[A-Za-z0-9._-]+/)) {
          ns = substr(line, RSTART, RLENGTH); sub(/^[{,][ \t]*namespace:[ \t]*/, "", ns)
        }
        emit(); next
      }
      ingen && /^metadata:[ \t]*$/ { inmeta = 1; next }
      inmeta && /^[ \t]+name:[ \t]*[A-Za-z0-9._-]+[ \t]*$/ { nm = $2; emit(); next }
      inmeta && /^[ \t]+namespace:[ \t]*[A-Za-z0-9._-]+[ \t]*$/ { ns = $2; emit(); next }
      inmeta && /^[^ \t#]/ { inmeta = 0; ingen = 0 }
    ' {} + 2>/dev/null | sort -u)"
  n_declared="$(printf '%s' "${declared}" | grep -c . || true)"
  if [ "${n_declared}" -eq 0 ]; then
    echo "mTLS post-condition FAILED: not one VaultDynamicSecret generator was found under ${spec_dir}. Either the manifests moved or this scan is broken; either way the expected set is empty and everything would pass vacuously." >&2
    return 1
  fi

  # ── what the CLUSTER actually carries ─────────────────────────────────
  # Keyed by <namespace>/<generator name> so it can be matched against the repo
  # declaration above, not merely counted against itself.
  targets="$(kubectl get externalsecrets.external-secrets.io -A -o json 2>/dev/null \
    | jq -r '.items[]
             | . as $es
             | [ $es.spec.dataFrom[]? | select(.sourceRef.generatorRef != null)
                 | .sourceRef.generatorRef.name ] as $g
             | select(($g | length) > 0)
             | "\($es.metadata.namespace) \($es.spec.target.name // $es.metadata.name) \($es.metadata.name) \($g[0])"' \
    2>/dev/null || true)"
  n_targets="$(printf '%s' "${targets}" | grep -c . || true)"
  if [ "${n_targets}" -eq 0 ]; then
    echo "mTLS post-condition: NOT ONE generator-backed ExternalSecret exists in this cluster, while the repo declares ${n_declared}. Either the external-secrets CRDs never installed or 04-external-secrets-config.yaml never synced — so the vault-ca/vault-token seeding above served nothing and this check verified nothing. That is a failure, not a pass." >&2
    return 1
  fi
  live_keys=" $(printf '%s\n' "${targets}" | awk 'NF {print $1 "/" $4}' | tr '\n' ' ')"

  # ── repo vs cluster ───────────────────────────────────────────────────
  while IFS="$(printf '\t')" read -r ns gen file reason; do
    [ -n "${ns}" ] || continue
    key="${ns}/${gen}"
    case "${live_keys}" in
      *" ${key} "*) live=1 ;;
      *)            live=0 ;;
    esac
    if [ -n "${reason}" ]; then
      # An exemption is a reviewed claim: it must state one, and it may not sit
      # on a generator the cluster DOES carry — that would silently absorb the
      # next delivery regression instead of reporting it.
      if [ "${#reason}" -lt 24 ]; then
        badreason="${badreason}
      ${key} (${file}): ${reason}"
      elif [ "${live}" -eq 1 ]; then
        stale="${stale}
      ${key} (${file})"
      else
        n_exempt=$(( n_exempt + 1 ))
        log "  not-delivered by declaration: ${key} — ${reason}"
      fi
      continue
    fi
    n_expected=$(( n_expected + 1 ))
    [ "${live}" -eq 1 ] || undelivered="${undelivered}
      ${key} declared in ${file}"
  done <<< "${declared}"

  if [ -n "${badreason}" ]; then
    echo "mTLS post-condition FAILED: an \`mtls-issuance: not-delivered\` marker with no usable reason (needs >=24 characters):${badreason}" >&2
    return 1
  fi
  if [ -n "${stale}" ]; then
    echo "mTLS post-condition FAILED: these generators carry an \`mtls-issuance: not-delivered\` marker but the cluster DOES carry them, so the marker is stale and would mask the next delivery failure:${stale}" >&2
    return 1
  fi
  if [ -n "${undelivered}" ]; then
    echo "mTLS post-condition FAILED: the repo declares generators that never reached the cluster, so no ExternalSecret and no certificate exists for them:${undelivered}" >&2
    echo "    This is invisible to any check that counts what the CLUSTER declares — the denominator shrinks with the failure. Diagnose with:" >&2
    echo "      kubectl -n devops get applications -o wide      # a SyncError leaves resources untracked" >&2
    echo "      grep -n resources -A40 ${spec_dir}/manifests/external-secrets/kustomization.yaml" >&2
    echo "    A manifest that is genuinely not delivered by default must say so where it is declared:" >&2
    echo "      # mtls-issuance: not-delivered <why, and where the design says so>" >&2
    return 1
  fi

  log "Verifying mTLS issuance (${n_declared} generator(s) declared in ${spec_dir##*/}: ${n_expected} expected, ${n_exempt} declared not-delivered; ${n_targets} generator-backed ExternalSecret(s) live) — independent read-back"

  # Wait for the target Secrets to materialize.
  for i in $(seq 1 $(( deadline_s / 5 ))); do
    missing=""
    while read -r ns sec es gen; do
      [ -n "${ns}" ] || continue
      kubectl -n "${ns}" get secret "${sec}" >/dev/null 2>&1 || missing="${missing} ${ns}/${sec}"
    done <<< "${targets}"
    [ -z "${missing}" ] && break
    sleep 5
  done
  if [ -n "${missing}" ]; then
    echo "mTLS post-condition FAILED: after ${deadline_s}s these generator-backed Secrets were never issued:${missing}" >&2
    echo "    This is the exact shape of the outage step 8b exists to prevent. Diagnose with:" >&2
    echo "      kubectl get externalsecrets -A | grep -v SecretSynced\$" >&2
    echo "      kubectl -n external-secrets logs deploy/external-secrets | tail -50" >&2
    return 1
  fi

  # The anchor the truststores use — read back from the cluster, not assumed.
  tmp="$(mktemp -d)"; ca_file="${tmp}/ca.crt"
  kubectl -n vault get secret cluster-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "${ca_file}"
  [ -s "${ca_file}" ] || { echo "mTLS post-condition FAILED: vault/cluster-ca carries no tls.crt to verify against" >&2; rm -rf "${tmp}"; return 1; }

  while read -r ns sec es gen; do
    [ -n "${ns}" ] || continue
    kubectl -n "${ns}" get secret "${sec}" -o jsonpath='{.data.tls\.crt}' | base64 -d > "${tmp}/leaf.crt" 2>/dev/null || true
    kubectl -n "${ns}" get secret "${sec}" -o jsonpath='{.data.tls\.key}' | base64 -d > "${tmp}/leaf.key" 2>/dev/null || true
    if [ ! -s "${tmp}/leaf.crt" ]; then
      echo "    ${ns}/${sec}: EXISTS BUT CARRIES NO tls.crt — an empty Secret is not an issued certificate" >&2
      rc=1; continue
    fi
    subject="$(openssl x509 -in "${tmp}/leaf.crt" -noout -subject 2>/dev/null || true)"
    if [ -z "${subject}" ]; then
      echo "    ${ns}/${sec}: tls.crt is not a parseable X.509 certificate" >&2
      rc=1; continue
    fi
    if ! openssl x509 -in "${tmp}/leaf.crt" -noout -checkend 0 >/dev/null 2>&1; then
      echo "    ${ns}/${sec}: certificate is already expired" >&2
      rc=1; continue
    fi
    # The key must belong to the cert: a leaf paired with someone else's key
    # mounts fine and then fails every handshake.
    if [ ! -s "${tmp}/leaf.key" ] || \
       [ "$(openssl x509 -in "${tmp}/leaf.crt" -noout -pubkey 2>/dev/null)" != \
         "$(openssl pkey -in "${tmp}/leaf.key" -pubout 2>/dev/null)" ]; then
      echo "    ${ns}/${sec}: tls.key does not match tls.crt" >&2
      rc=1; continue
    fi
    if ! openssl verify -CAfile "${ca_file}" "${tmp}/leaf.crt" >/dev/null 2>&1; then
      issuer="$(openssl x509 -in "${tmp}/leaf.crt" -noout -issuer 2>/dev/null || true)"
      echo "    ${ns}/${sec}: does NOT chain to vault/cluster-ca (${issuer}) — the workloads' truststore will reject it" >&2
      rc=1; continue
    fi
    verified=$(( verified + 1 ))
    [ -n "${sample}" ] || sample="${ns}/${sec}: ${subject} / $(openssl x509 -in "${tmp}/leaf.crt" -noout -issuer 2>/dev/null)"
  done <<< "${targets}"
  rm -rf "${tmp}"

  if [ "${rc}" -ne 0 ] || [ "${verified}" -ne "${n_targets}" ]; then
    echo "mTLS post-condition FAILED: ${verified}/${n_targets} generator-issued certificates verified." >&2
    return 1
  fi
  log "  mTLS verified: ${verified}/${n_targets} certificates issued, in date, key-matched and chaining to vault/cluster-ca"
  echo "    e.g. ${sample}"
}

verify_mtls_issuance || {
  echo "Refusing to report a successful bring-up: no verified mTLS certificate. Every pod that mounts a *-mtls Secret will hang in Init:0/1 on 'MountVolume.SetUp failed for volume \"pki\"'." >&2
  exit 1
}

# Reached only after verify_mtls_issuance() proved a real, chaining certificate
# exists — so, like the SSO line above, this is a claim with evidence behind it.
# hugmesh-generator#349: say plainly, here, whether this cluster can actually
# run anything. A bring-up that exits 0 while every app image is absent is how
# this lane stayed dead for two days. Report-only — the documented order is
# `make kind-up` THEN `make kind-images`, so a missing first-party image at
# this exact moment is expected, not an error. `make kind-doctor` is the same
# check with teeth.
if [ -r "${REPO_ROOT}/scripts/kind-doctor.sh" ]; then
  echo
  KIND_DOCTOR_WARN_ONLY=1 KIND_CLUSTER_NAME="${CLUSTER_NAME}" \
    bash "${REPO_ROOT}/scripts/kind-doctor.sh" || true
  echo
fi

log "Done. Cluster '${CLUSTER_NAME}' is left running for the next validation step."
echo "    kubeconfig context: kind-${CLUSTER_NAME}"
echo "    ArgoCD admin password: kubectl -n ${ARGOCD_NS} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "    Tear down: kind delete cluster --name ${CLUSTER_NAME}"
