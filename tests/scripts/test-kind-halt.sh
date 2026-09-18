#!/usr/bin/env bash
# test-kind-halt.sh — EXECUTE scripts/kind-halt.sh against stubbed kind, docker and
# kubectl and prove every refusal it claims actually bites.
#
# THIS SUITE TOUCHES NO CLUSTER. That is not a nicety: the thing under test is the
# button that stops the operator's live `hugmesh-local` mesh, and a guard that
# verified it by stopping that mesh would have failed however green it printed. The
# three binaries are replaced on PATH by fakes that keep the cluster's state in JSON
# files, so a `patch` or a `scale` really does change the state the next assertion
# reads — a fake, not a mock: the halt/resume round trip below is a real round trip.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE FOUR BLOCKERS THIS SUITE EXISTS FOR
# ─────────────────────────────────────────────────────────────────────────────
# Two independent skeptics broke the first version of the control. Every one of
# their demonstrations is a scenario here, because the first suite passed 64
# assertions while the control could still lose the operator's cluster — the fake's
# VOCABULARY was the gap, not the scenario count. It could not express "the record
# read ERRORED" or "the halt was killed part-way", so no scenario could ask.
#
#   B1  THE RECORD IS WRITTEN FIRST. The first version wrote it after every patch
#       and every scale, so a halt killed part-way left the cluster halted with NO
#       record — and the Studio ships the button that does it (`cancellable=True`
#       arms a Cancel that terminates the whole process GROUP). Scenarios 27-31 use
#       a fake that really SIGKILLs the halt's process group mid-run.
#   B2  read_record FAILS CLOSED. `kubectl get configmap 2>/dev/null` with the exit
#       status discarded made "absent" and "unreadable" the same answer, and a
#       second halt then overwrote a good record with an all-zero one. Scenarios
#       32-35: the `cm_read_rc` knob fails the read WHILE THE RECORD EXISTS.
#   B3  THE VERIFY PASS FAILS CLOSED. The suspend check ran through a helper whose
#       exit status was thrown away, so truncated JSON read as "nothing left to do"
#       and the halt reported success. Scenarios 36-37: `apps_bad_from`.
#   B4  RESUME VERIFIES BEFORE IT DELETES. It reported success after restoring
#       nothing and then deleted the last evidence. Scenarios 38-41.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT ELSE IS PINNED, and why each one is a refusal that was measured first
# ─────────────────────────────────────────────────────────────────────────────
#
#   THE CENSUS CONTRACT (the most important one). tests/scripts/run-ungated-lane.sh
#   :60-91 exits 5 when the footprint CANNOT BE DETERMINED, because *"a census that
#   errors is NOT an empty census: before 2026-09-16 the two were indistinguishable
#   and the lane proceeded on a dead daemon."* A stop control that reads a failed
#   `kind get clusters` or a broken kubeconfig as "no cluster" would report that it
#   halted something it never saw. Scenarios 1-7, 9.
#
#   THE ZOMBIE. `kind get clusters` still NAMES a cluster whose node container is
#   stopped, so bootstrap-kind.sh:362 takes its "already exists - reusing it" branch
#   and hangs on an API server that is never coming back (kind-doctor.sh:135-139).
#   The halt must refuse on that state rather than "halt" an already-dead cluster.
#   Scenario 4.
#
#   THE SHARED NAME. `hugmesh-local` is BOTH the docker compose project
#   (local_stack_node.py:69) and the kind cluster (:111), and the kind node container
#   `hugmesh-local-control-plane` begins with that prefix. A container sweep by
#   prefix would take out the operator's compose mesh. Scenario 11 asserts on the
#   docker call log that the ONLY docker verb ever used is `inspect`, of ONE exact
#   name - no `ps`, no `stop`, no `rm`.
#
#   THE FLOOR, IN TWO TIERS. Tier 1 is hardcoded (kube-system, local-path-storage,
#   the ArgoCD namespace …): each is a way to wedge the cluster against its own
#   resume. Tier 2 is DERIVED at halt time from the cluster's own admission
#   configuration — the namespace behind every failurePolicy=Fail webhook and every
#   CRD conversion webhook. kyverno is tier 2 on the real cluster
#   (`validate.kyverno.svc-fail` is Fail over apps/v1 deployments+statefulsets
#   UPDATE outside kube-system/kyverno, and a scale IS an UPDATE), and so is
#   external-secrets, whose webhook is the admission path for the very Application
#   #352 tracks. Scenarios 12-15 prove both tiers hold, that the derivation is from
#   the cluster and not a list, and that KIND_HALT_SKIP_NS cannot lower either.
#
#   RESUME RESTORES WHAT WAS HALTED, NOT EVERYTHING. An Application suspended before
#   the halt must still be suspended after the resume; and an `automated: {}` block
#   (auto-sync with prune and selfHeal OFF — valid ArgoCD, falsy in python) must come
#   back as `{}` and not as {"prune": true, "selfHeal": true}, because prune DELETES
#   resources absent from git. Scenarios 17-22.
#
#   THE CONTEXT PIN, AND THAT IT CANNOT BE OVERRIDDEN. Every kubectl call must carry
#   `--context kind-<cluster>`; the fake REFUSES any call without it (exit 90). The
#   first version accepted a KIND_HALT_CONTEXT override, which decoupled the cluster
#   the census proved alive from the cluster every mutation then landed on.
#   Scenarios 23-24.
#
#   HPAs ARE CENSUSED AND NAMED, NEVER TOUCHED — and a FAILED HPA read is reported
#   as "could not be censused", not rendered as "there are none". Scenarios 25-26.
#
# THE MUTATION BATTERY this suite is measured against — applied to a COPY of
# scripts/kind-halt.sh (never the file itself, and never a file bash is running),
# each verified by sha256 to have CHANGED the copy:
#
#   M1  census: a FAILING `kind get clusters` is swallowed -> reads as "not listed"
#   M2  census: drop the node-container state check entirely (the zombie passes)
#   M3  census: drop the `kubectl get nodes` reachability check
#   M4  halt: drop the "already halted" precondition
#   M5  resume: re-arm EVERY Application in the record, not only was_automated ones
#   M6  resume: restore replicas even when the workload is no longer at 0
#   M7  floor: let KIND_HALT_SKIP_NS replace the mandatory list instead of adding
#   M8  plan: include namespaces on the floor in the scale list
#   M9  kc(): drop the `--context` pin
#   M10 census: `grep -aFx` -> `grep -aF` (hugmesh-local matches hugmesh-local-2)
#   M11 halt: skip the suspend loop entirely (the scale-only halt, i.e. the lie)
#   M12 record: hardcode was_automated True (an already-suspended app becomes ours)
#   M13 render: stop reporting the health each Application froze in
#   M14 halt: report a failed record write as success
#   M15 census: swallow a failed `docker inspect` (a dead socket reads as fine)
#   M16 plan: send the cluster dumps through the ENVIRONMENT again (the E2BIG bug)
#   M17 halt: write the record AFTER the mutations again (blocker B1)
#   M18 read_record: collapse "unreadable" back into "absent" (blocker B2)
#   M19 halt: ignore load_current's exit status on the verify pass (blocker B3)
#   M20 resume: delete the record without verifying anything (blocker B4)
#   M21 resume: `a.get("automated") or {...}` truthiness again (prune forced on)
#   M22 floor: use the hardcoded kyverno list instead of the derived census
#   M23 halt: `create configmap` -> create|apply, losing the lock
#   M24 halt: skip the post-scale verification (a denied scale reads as done)
#
# THE SECOND RUN OF THIS BATTERY WAS NOT CLEAN, and that is why four of the
# scenarios below exist at all. Against the suite as first written, M06, M13 and M19
# SURVIVED and M16 matched nothing:
#   M06 survived because no scenario had a workload someone scaled back up BY HAND
#       while the lane was halted -> scenario resume-leaves-a-hand-scaled-workload-alone
#   M13 survived because nothing asserted on the "<-- NOT healthy/synced when frozen"
#       flag, which is requirement 3 of #356 -> scenario names-what-it-froze
#   M19 survived because the POST-SCALE verify caught what the suspend verify missed,
#       so the two passes could not be told apart -> scenario
#       verify-suspend-alone-unparseable, which truncates ONLY the suspend re-read
#   M16 matched nothing, and then could not be killed by any small fixture: the
#       ceiling is ARG_MAX -> scenario dump-past-arg-max, which pads the dump to
#       several MB with a handful of objects rather than thousands of them
# A battery that is green on its first run has usually not been designed hard enough.
#
# M11 SURVIVED the first time this battery ran, and the reason is worth keeping.
# The halt verifies its suspend and re-suspends anything a parent re-asserted — and
# that retry net quietly did the whole job when the primary loop was cut out, so the
# end state was right and no assertion could tell. Two things came out of it: S10
# asserts the retry is NOT used on a healthy cluster (a net that is load-bearing is
# a dead primary path nobody can see), and the script gained the pass that actually
# decides — a SECOND verification after the re-suspend, because a `kubectl patch`
# returning 0 has not proved the suspend HELD. Scenario 16 is that case.
#
# NOT CLOSED, and stated rather than implied: nothing here proves the ORDER of the
# two phases (suspend before scale) matters against a real ArgoCD, because a fake
# has no reconcile loop. The order is argued from specs/cluster (98 of 98 app files
# carry prune+selfHeal), pinned as a CALL SEQUENCE by scenario 10, and never
# exercised against a real controller.
#
# 36 scenario fixtures, 48 labelled cases, 136 assertions. The S-numbers are
# stable identifiers (a failure is grepped by them), so they are NOT renumbered
# when a scenario is inserted — S36b and S37b are later additions that kill a
# mutant S36 and S37 could not, and they keep their neighbours' names on purpose.
#
# Run it with:  make kind-halt-check      (offline, no cluster, a few seconds)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
TARGET="${KIND_HALT_TARGET:-${REPO}/scripts/kind-halt.sh}"

PASS=0
FAIL=0
# A privately named scratch root. Two lanes sharing a scratch directory is how a
# mutation script got overwritten mid-execution today; and bash re-reads a running
# script by BYTE OFFSET on fd 255, so a suite that rewrites its own target while
# running is a different hazard again. Nothing here writes to ${TARGET}.
ROOT="$(mktemp -d -t kind-halt-guard.XXXXXX)"
trap 'rm -rf "${ROOT}"' EXIT

ok()   { printf '  \033[32m ok \033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ── the fakes ────────────────────────────────────────────────────────────────
# Written once into ${ROOT}/bin and put at the FRONT of PATH. They read their
# behaviour from ${SCEN} (the current scenario directory) so one set of fakes
# serves every scenario without being rewritten while a test is running.
make_fakes() {
  mkdir -p "${ROOT}/bin"

  cat > "${ROOT}/bin/kind" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "kind $*" >> "${SCEN}/kind.log"
if [ "${1:-}" = "get" ] && [ "${2:-}" = "clusters" ]; then
  rc="$(cat "${SCEN}/kind_rc" 2>/dev/null || echo 0)"
  if [ "${rc}" != "0" ]; then
    echo "ERROR: failed to list clusters: permission denied while trying to connect to the Docker daemon socket" >&2
    exit "${rc}"
  fi
  cat "${SCEN}/clusters" 2>/dev/null
  exit 0
fi
echo "fake kind: unexpected verb: $*" >&2
exit 91
FAKE

  # docker: the ONLY verb this control may ever use is `inspect`, on ONE exact
  # container name. Every other verb is recorded AND made loud, so a future edit
  # that reaches for `docker stop`/`docker ps` cannot pass this suite quietly.
  cat > "${ROOT}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "docker $*" >> "${SCEN}/docker.log"
if [ "${1:-}" = "inspect" ]; then
  rc="$(cat "${SCEN}/docker_rc" 2>/dev/null || echo 0)"
  if [ "${rc}" != "0" ]; then
    echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock." >&2
    exit "${rc}"
  fi
  cat "${SCEN}/node_state" 2>/dev/null || echo running
  exit 0
fi
printf '%s\n' "FORBIDDEN-DOCKER-VERB $*" >> "${SCEN}/docker.log"
echo "fake docker: this control must never run 'docker $1'" >&2
exit 92
FAKE

  cat > "${ROOT}/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "kubectl $*" >> "${SCEN}/kubectl.log"
# THE CONTEXT PIN. Every call must name the cluster's own context explicitly;
# acting on "whatever is current" is the failure this refuses to allow.
if [ "${1:-}" != "--context" ]; then
  printf '%s\n' "MISSING-CONTEXT $*" >> "${SCEN}/kubectl.log"
  echo "fake kubectl: refused - no --context pin on: $*" >&2
  exit 90
fi
CTX="${2:-}"
shift 2
exec python3 "${KFAKE}" "${CTX}" "$@"
FAKE

  chmod +x "${ROOT}/bin/kind" "${ROOT}/bin/docker" "${ROOT}/bin/kubectl"
  KFAKE="${ROOT}/kubectl_fake.py"
  export KFAKE

  # The fake API server. Keeps apps.json / wl.json / record.json in ${SCEN} and
  # really mutates them, so `patch` and `scale` are observable in later reads.
  #
  # ITS KNOBS ARE THE POINT. The previous fake could not express an errored record
  # read or a halt killed part-way, so no scenario could ask the questions that
  # actually broke the control:
  #   cm_read_rc   the record read FAILS (not NotFound) while the record exists
  #   cm_create_rc `create configmap` is refused
  #   kill_at      SIGKILL the halt's whole process group at this call
  #   apps_bad_from  the Nth+ `get applications -A` returns TRUNCATED json
  #   patch_noop   a patch is ACCEPTED and changes nothing (a re-asserting parent,
  #                and in resume, a re-arm that does not hold)
  #   scale_noop   a scale is ACCEPTED and changes nothing (a denied UPDATE)
  cat > "${ROOT}/kubectl_fake.py" <<'FAKE'
import json, os, signal, sys

SCEN = os.environ["SCEN"]
ctx = sys.argv[1]
a = sys.argv[2:]

def p(name): return os.path.join(SCEN, name)
def load(name):
    with open(p(name)) as fh: return json.load(fh)
def save(name, obj):
    with open(p(name), "w") as fh: json.dump(obj, fh)
def rc_for(name, default=0):
    try:
        with open(p(name)) as fh: return int(fh.read().strip())
    except Exception: return default
def words(name):
    try:
        with open(p(name)) as fh: return fh.read().split()
    except Exception: return []
def bump(name):
    n = rc_for(name, 0) + 1
    with open(p(name), "w") as fh: fh.write(str(n))
    return n

# THE KILL KNOB. Blocker B1's whole demonstration: the Studio's Cancel button
# terminates the verb's process GROUP, so the halt can stop between any two calls.
# The suite runs the halt under setsid, so this kills the halt and not the suite.
def maybe_kill(tag):
    for want in words("kill_at"):
        if want == tag:
            with open(p("killed"), "w") as fh: fh.write(tag)
            os.killpg(os.getpgid(0), signal.SIGKILL)

# `get nodes` — API reachability.
if a[:2] == ["get", "nodes"]:
    rc = rc_for("nodes_rc")
    if rc: sys.stderr.write("The connection to the server 127.0.0.1:6443 was refused\n"); sys.exit(rc)
    print("hugmesh-local-control-plane   Ready   control-plane   30h   v1.34.0"); sys.exit(0)

# The census asks for ONE crd by name; the admission floor asks for them ALL.
if a[:3] == ["get", "crd", "applications.argoproj.io"]:
    rc = rc_for("crd_rc")
    if rc: sys.stderr.write('Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "applications.argoproj.io" not found\n'); sys.exit(rc)
    print("applications.argoproj.io   2026-09-16T00:00:00Z"); sys.exit(0)

if a[:2] == ["get", "crd"]:
    rc = rc_for("crd_list_rc")
    if rc: sys.stderr.write("the server could not find the requested resource\n"); sys.exit(rc)
    sys.stdout.write(json.dumps(load("crds.json"))); sys.exit(0)

if a[:2] == ["get", "validatingwebhookconfigurations,mutatingwebhookconfigurations"]:
    rc = rc_for("webhooks_rc")
    if rc: sys.stderr.write("the server could not find the requested resource\n"); sys.exit(rc)
    sys.stdout.write(json.dumps(load("webhooks.json"))); sys.exit(0)

if a[:2] == ["get", "hpa"] and "-A" in a:
    rc = rc_for("hpa_rc")
    if rc: sys.stderr.write("the server could not find the requested resource\n"); sys.exit(rc)
    sys.stdout.write(json.dumps(load("hpa.json"))); sys.exit(0)

if a[:2] == ["get", "applications"] and "-A" in a:
    rc = rc_for("apps_list_rc")
    if rc: sys.stderr.write("the server could not find the requested resource\n"); sys.exit(rc)
    n = bump("apps_list_n")
    bad_from = rc_for("apps_bad_from", 0)
    bad_only = rc_for("apps_bad_only", 0)
    if (bad_from and n >= bad_from) or (bad_only and n == bad_only):
        # TRUNCATED, not empty. `[ -s file ]` is satisfied and json.loads is not.
        sys.stdout.write('{"items": [{"metadata": {"na'); sys.exit(0)
    maybe_kill("get-applications")
    sys.stdout.write(json.dumps(load("apps.json"))); sys.exit(0)

if a[:2] == ["get", "deployments,statefulsets"] and "-A" in a:
    rc = rc_for("wl_list_rc")
    if rc: sys.stderr.write("the server could not find the requested resource\n"); sys.exit(rc)
    sys.stdout.write(json.dumps(load("wl.json"))); sys.exit(0)

# Namespaced forms: -n <ns> <verb> ...
if a[0] == "-n":
    ns = a[1]
    rest = a[2:]

    if rest[:2] == ["get", "configmap"]:
        # The namespace is CHECKED, not ignored: the previous fake accepted any,
        # so a namespace bug in the record path could not be caught here.
        with open(p("cm_ns.log"), "a") as fh: fh.write(ns + "\n")
        rc = rc_for("cm_read_rc")
        if rc:
            sys.stderr.write("Unable to connect to the server: net/http: TLS handshake timeout\n")
            sys.exit(rc)
        if not os.path.exists(p("record.json")):
            sys.stderr.write('Error from server (NotFound): configmaps "hugmesh-kind-halt" not found\n')
            sys.exit(1)
        with open(p("record.json")) as fh: sys.stdout.write(fh.read())
        sys.exit(0)

    if rest[0] == "apply" and "-f" in rest:
        # The record REWRITE lands here: `create --dry-run=client -o yaml | apply`.
        # The apply must name its own namespace - the previous fake only handled the
        # un-namespaced form, so a missing -n could not be caught by this suite.
        with open(p("cm_ns.log"), "a") as fh: fh.write(ns + "\n")
        body = sys.stdin.read()
        marker = "---PAYLOAD---\n"
        if marker in body:
            with open(p("record.json"), "w") as fh: fh.write(body.split(marker, 1)[1])
        print("configmap configured"); sys.exit(0)

    if rest[:2] == ["delete", "configmap"]:
        if rc_for("cm_delete_rc"): sys.exit(1)
        if os.path.exists(p("record.json")): os.remove(p("record.json"))
        print("configmap deleted"); sys.exit(0)

    if rest[:2] == ["create", "configmap"]:
        with open(p("cm_ns.log"), "a") as fh: fh.write(ns + "\n")
        src = [x.split("=", 2)[-1] for x in rest if x.startswith("--from-file=")][0]
        with open(src) as fh: body = fh.read()
        if "--dry-run=client" in rest:
            # The REWRITE half: render only, the apply below persists it.
            sys.stdout.write("kind: ConfigMap\n---PAYLOAD---\n" + body)
            sys.exit(0)
        # The CREATE half, and the lock: a real `kubectl create` fails if the
        # object already exists, which is what stops two halts racing.
        if rc_for("cm_create_rc"):
            sys.stderr.write('Error from server (Forbidden): configmaps is forbidden\n'); sys.exit(1)
        if os.path.exists(p("record.json")):
            sys.stderr.write('Error from server (AlreadyExists): configmaps "hugmesh-kind-halt" already exists\n')
            sys.exit(1)
        with open(p("record.json"), "w") as fh: fh.write(body)
        maybe_kill("create-configmap")
        print("configmap created"); sys.exit(0)

    if rest[0] == "patch" and rest[1] == "application":
        name = rest[2]
        patch = json.loads(rest[rest.index("-p") + 1])
        maybe_kill("patch")
        if name in words("unpatchable"):
            sys.stderr.write("admission webhook denied the request\n"); sys.exit(1)
        # A patch that is ACCEPTED and changes nothing. On the suspend side that is
        # a parent (a repo-recursing app-of-apps root, an ApplicationSet) that
        # re-asserts the Application the instant it is suspended; on the resume side
        # it is a re-arm that does not hold. A control that trusted rc=0 here would
        # report a halt while auto-sync was still armed — or a resume that never
        # re-armed anything.
        if name in words("patch_noop"):
            print("application patched"); sys.exit(0)
        apps = load("apps.json")
        for item in apps["items"]:
            if item["metadata"]["name"] == name and item["metadata"]["namespace"] == ns:
                sp = item.setdefault("spec", {}).setdefault("syncPolicy", {})
                auto = patch["spec"]["syncPolicy"]["automated"]
                if auto is None: sp.pop("automated", None)
                else: sp["automated"] = auto
                save("apps.json", apps); print("application patched"); sys.exit(0)
        sys.stderr.write("Error from server (NotFound)\n"); sys.exit(1)

    if rest[0] == "scale":
        kind, name = rest[1], rest[2]
        want = int([x for x in rest if x.startswith("--replicas=")][0].split("=")[1])
        maybe_kill("scale")
        if rc_for("scale_rc"):
            sys.stderr.write("admission webhook \"validate.kyverno.svc-fail\" denied the request\n"); sys.exit(1)
        # Accepted, and changes nothing: the admission-gated UPDATE that is denied
        # after the fact. The halt must catch this by RE-READING, not by rc.
        if name in words("scale_noop"):
            print("scaled"); sys.exit(0)
        wl = load("wl.json")
        for item in wl["items"]:
            if item["metadata"]["name"] == name and item["metadata"]["namespace"] == ns:
                item["spec"]["replicas"] = want
                save("wl.json", wl); print("scaled"); sys.exit(0)
        sys.stderr.write("Error from server (NotFound)\n"); sys.exit(1)

if a[0] == "apply" and "-f" in a:
    body = sys.stdin.read()
    marker = "---PAYLOAD---\n"
    if marker in body:
        with open(p("record.json"), "w") as fh: fh.write(body.split(marker, 1)[1])
    print("configmap configured"); sys.exit(0)

sys.stderr.write("fake kubectl: unexpected call: %s\n" % " ".join(a))
sys.exit(93)
FAKE
}

# ── fixtures ─────────────────────────────────────────────────────────────────
# A cluster shaped like the real one, small enough to assert on by hand:
#   mesh-a, mesh-b      automated, Synced/Healthy      -> suspended, then re-armed
#   frozen-red          automated, Synced/DEGRADED     -> the #352 shape
#   no-prune-app        automated: {}                  -> must come back as {}
#   already-suspended   NO automated block             -> never touched, ever
# and workloads spread across both tiers of the floor and the mesh namespaces.
scenario() {
  local name
  name="$1"
  SCEN="${ROOT}/scen/${name}"
  mkdir -p "${SCEN}"
  printf 'hugmesh-local\nsome-other-cluster\n' > "${SCEN}/clusters"
  printf 'running\n' > "${SCEN}/node_state"

  cat > "${SCEN}/apps.json" <<'JSON'
{"items": [
 {"metadata": {"name": "mesh-a", "namespace": "devops"},
  "spec": {"syncPolicy": {"automated": {"prune": true, "selfHeal": true}}},
  "status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}}},
 {"metadata": {"name": "mesh-b", "namespace": "devops"},
  "spec": {"syncPolicy": {"automated": {"prune": false, "selfHeal": true}}},
  "status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}}},
 {"metadata": {"name": "frozen-red", "namespace": "devops"},
  "spec": {"syncPolicy": {"automated": {"prune": true, "selfHeal": true}}},
  "status": {"sync": {"status": "Synced"}, "health": {"status": "Degraded"}}},
 {"metadata": {"name": "no-prune-app", "namespace": "devops"},
  "spec": {"syncPolicy": {"automated": {}}},
  "status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}}},
 {"metadata": {"name": "already-suspended", "namespace": "devops"},
  "spec": {"syncPolicy": {}},
  "status": {"sync": {"status": "OutOfSync"}, "health": {"status": "Missing"}}}
]}
JSON

  cat > "${SCEN}/wl.json" <<'JSON'
{"items": [
 {"kind": "Deployment",  "metadata": {"name": "api",       "namespace": "hugmesh-backend"},  "spec": {"replicas": 2}},
 {"kind": "Deployment",  "metadata": {"name": "ui",        "namespace": "hugmesh-frontend"}, "spec": {"replicas": 1}},
 {"kind": "StatefulSet", "metadata": {"name": "vault",     "namespace": "vault"},            "spec": {"replicas": 1}},
 {"kind": "Deployment",  "metadata": {"name": "kyverno",   "namespace": "kyverno"},          "spec": {"replicas": 1}},
 {"kind": "Deployment",  "metadata": {"name": "es-webhook","namespace": "external-secrets"}, "spec": {"replicas": 1}},
 {"kind": "Deployment",  "metadata": {"name": "coredns",   "namespace": "kube-system"},      "spec": {"replicas": 2}},
 {"kind": "Deployment",  "metadata": {"name": "provisioner","namespace": "local-path-storage"}, "spec": {"replicas": 1}},
 {"kind": "Deployment",  "metadata": {"name": "argocd-server","namespace": "devops"},        "spec": {"replicas": 1}},
 {"kind": "Deployment",  "metadata": {"name": "already-zero","namespace": "hugmesh-backend"},"spec": {"replicas": 0}}
]}
JSON

  # The admission configuration the floor is DERIVED from. Shaped exactly like the
  # operator's cluster, read from it on 2026-09-17: kyverno's Fail webhook over
  # apps/v1, external-secrets' three Fail webhooks, and external-secrets again as
  # the conversion webhook for a CRD. `ignored-ns` is the control: failurePolicy
  # Ignore must NOT put a namespace on the floor.
  cat > "${SCEN}/webhooks.json" <<'JSON'
{"items": [
 {"kind": "ValidatingWebhookConfiguration",
  "metadata": {"name": "kyverno-resource-validating-webhook-cfg"},
  "webhooks": [{"name": "validate.kyverno.svc-fail", "failurePolicy": "Fail",
                "clientConfig": {"service": {"namespace": "kyverno", "name": "kyverno-svc"}}}]},
 {"kind": "ValidatingWebhookConfiguration",
  "metadata": {"name": "externalsecret-validate"},
  "webhooks": [{"name": "validate.externalsecret.external-secrets.io", "failurePolicy": "Fail",
                "clientConfig": {"service": {"namespace": "external-secrets", "name": "external-secrets-webhook"}}}]},
 {"kind": "MutatingWebhookConfiguration",
  "metadata": {"name": "harmless-ignore-cfg"},
  "webhooks": [{"name": "monitor.example.svc", "failurePolicy": "Ignore",
                "clientConfig": {"service": {"namespace": "ignored-ns", "name": "whatever"}}}]}
]}
JSON

  cat > "${SCEN}/crds.json" <<'JSON'
{"items": [
 {"metadata": {"name": "externalsecrets.external-secrets.io"},
  "spec": {"conversion": {"strategy": "Webhook",
           "webhook": {"clientConfig": {"service": {"namespace": "external-secrets",
                                                    "name": "external-secrets-webhook"}}}}}},
 {"metadata": {"name": "applications.argoproj.io"}, "spec": {"conversion": {"strategy": "None"}}}
]}
JSON

  if [ -n "${HALT_BIG_DUMP:-}" ]; then
    SCEN="${SCEN}" python3 -c '
import json, os
p = os.path.join(os.environ["SCEN"], "wl.json")
d = json.load(open(p))
pad = "x" * 400000
for i in d["items"]:
    i["metadata"].setdefault("annotations", {})["kubectl.kubernetes.io/last-applied-configuration"] = pad
json.dump(d, open(p, "w"))'
  fi

  cat > "${SCEN}/hpa.json" <<'JSON'
{"items": [
 {"metadata": {"name": "api-hpa", "namespace": "hugmesh-backend"},
  "spec": {"scaleTargetRef": {"kind": "Deployment", "name": "api"},
           "minReplicas": 2, "maxReplicas": 6}}
]}
JSON
  export SCEN
}

# Every verb runs in its OWN process group (setsid), so the fake's kill knob can
# terminate the halt exactly the way the Studio's Cancel button does — process
# group and all — without taking this suite with it.
run_verb() {
  local verb
  verb="$1"
  shift
  env PATH="${ROOT}/bin:${PATH}" SCEN="${SCEN}" KIND_HALT_SETTLE_S=0 \
      "$@" setsid bash "${TARGET}" "${verb}" >"${SCEN}/out" 2>"${SCEN}/err"
}
run_halt() { run_verb halt "$@"; }
out_all() { cat "${SCEN}/out" "${SCEN}/err" 2>/dev/null; }

# grep -a everywhere: grep fails OPEN on a NUL byte, and a guard that silently
# skips a file it could not scan is the failure mode this repo has already paid for.
saw()    { printf '%s' "$(out_all)" | grep -a -F -- "$1" >/dev/null; }
notsaw() { ! saw "$1"; }

expect_rc() {
  local want
  local got
  local what
  want="$1"; got="$2"; what="$3"
  if [ "${got}" = "${want}" ]; then ok "${what} (exit ${got})"; else bad "${what}: expected exit ${want}, got ${got}"; fi
}
expect_eq() {
  local got
  local want
  local what
  got="$1"; want="$2"; what="$3"
  if [ "${got}" = "${want}" ]; then ok "${what}"; else bad "${what}: expected '${want}', got '${got}'"; fi
}

replicas_of() {
  SCEN="${SCEN}" HALT_NS="$1" HALT_NAME="$2" python3 -c '
import json, os
d = json.load(open(os.path.join(os.environ["SCEN"], "wl.json")))
for i in d["items"]:
    if i["metadata"]["name"] == os.environ["HALT_NAME"] and i["metadata"]["namespace"] == os.environ["HALT_NS"]:
        print(i["spec"]["replicas"]); break
else:
    print("ABSENT")'
}
automated_of() {
  SCEN="${SCEN}" HALT_NAME="$1" python3 -c '
import json, os
d = json.load(open(os.path.join(os.environ["SCEN"], "apps.json")))
for i in d["items"]:
    if i["metadata"]["name"] == os.environ["HALT_NAME"]:
        print(json.dumps((i.get("spec", {}).get("syncPolicy", {}) or {}).get("automated"), sort_keys=True)); break
else:
    print("ABSENT")'
}
# A field of the ON-CLUSTER record, or ABSENT when there is no record at all.
record_field() {
  SCEN="${SCEN}" HALT_Q="$1" python3 -c '
import json, os, sys
path = os.path.join(os.environ["SCEN"], "record.json")
if not os.path.exists(path):
    print("ABSENT"); sys.exit(0)
rec = json.load(open(path))
q = os.environ["HALT_Q"]
if q.startswith("wl:"):
    _, ns, name = q.split(":")
    for w in rec.get("workloads", []):
        if w["namespace"] == ns and w["name"] == name:
            print(json.dumps([w.get("replicas"), w.get("skipped")], sort_keys=True)); sys.exit(0)
    print("MISSING"); sys.exit(0)
if q.startswith("app:"):
    name = q.split(":", 1)[1]
    for x in rec.get("applications", []):
        if x["name"] == name:
            print(json.dumps([x.get("was_automated"), x.get("automated")], sort_keys=True)); sys.exit(0)
    print("MISSING"); sys.exit(0)
print(json.dumps(rec.get(q), sort_keys=True))'
}

make_fakes

head_ "A. the census contract: an errored census is never an empty census"

scenario census-kind-fails
echo 1 > "${SCEN}/kind_rc"
run_halt; expect_rc 5 "$?" "S1  \`kind get clusters\` FAILS -> refuse"
if saw "census could not be taken"; then ok "S1  says the census could not be taken"; else bad "S1  did not say the census could not be taken"; fi
if saw "kind get clusters failed"; then ok "S1  quotes the tool's own failure"; else bad "S1  did not quote the tool's failure"; fi

scenario census-not-listed
printf 'some-other-cluster\n' > "${SCEN}/clusters"
run_halt; expect_rc 3 "$?" "S2  cluster genuinely absent -> refuse 3, distinct from 5"

# The name match must be WHOLE-LINE and LITERAL. `hugmesh-local` is a prefix of
# `hugmesh-local-2`, and a substring match would make this control act on a
# cluster nobody named — the same class of mistake as sweeping containers by
# prefix, one layer up.
scenario census-prefix-neighbour
printf 'hugmesh-local-2\n' > "${SCEN}/clusters"
run_halt; expect_rc 3 "$?" "S2b a cluster whose name merely BEGINS with the target is not the target"

scenario census-docker-dead
echo 1 > "${SCEN}/docker_rc"
run_halt; expect_rc 5 "$?" "S3  dead docker socket -> refuse 5, NOT 'no cluster'"
if saw "docker inspect"; then ok "S3  names the docker call that failed"; else bad "S3  did not name the failing docker call"; fi

scenario census-zombie-node
printf 'exited\n' > "${SCEN}/node_state"
run_halt; expect_rc 5 "$?" "S4  kind NAMES the cluster but the node is stopped -> refuse 5 (the zombie)"
if saw "zombie"; then ok "S4  names it as the stopped-cluster zombie"; else bad "S4  did not explain the zombie"; fi
if saw "make kind-down && make kind-up"; then ok "S4  gives the recovery kind-doctor prescribes"; else bad "S4  gave no recovery"; fi

scenario census-api-silent
echo 1 > "${SCEN}/nodes_rc"
run_halt; expect_rc 5 "$?" "S5  broken kubeconfig / API silent -> refuse 5"

scenario census-no-crd
echo 1 > "${SCEN}/crd_rc"
run_halt; expect_rc 5 "$?" "S6  no ArgoCD CRD -> refuse 5 rather than a scale-only halt that would lie"

scenario census-apps-list-fails
echo 1 > "${SCEN}/apps_list_rc"
run_halt; expect_rc 5 "$?" "S7  Applications cannot be listed -> refuse rather than halt blind"

# The admission floor is DERIVED from these two reads, so a failure to take them is
# a failure to know what must not be scaled — the census contract applied to the
# floor itself, not only to the cluster's existence.
scenario census-webhooks-fail
echo 1 > "${SCEN}/webhooks_rc"
run_halt; expect_rc 5 "$?" "S8  webhook configurations cannot be listed -> refuse rather than scale an admission controller blind"
expect_eq "$(record_field completed)" "ABSENT" "S8  and NOTHING was written: the record is absent"
expect_eq "$(replicas_of hugmesh-backend api)" "2" "S8  and NOTHING was mutated: the mesh Deployment is untouched"

scenario census-crds-fail
echo 1 > "${SCEN}/crd_list_rc"
run_halt; expect_rc 5 "$?" "S9  CRDs cannot be listed -> refuse rather than scale a conversion webhook blind"

head_ "B. the happy path, the call ORDER, and the floor in two tiers"

scenario halt-happy
run_halt; rc=$?
expect_rc 0 "${rc}" "S10 halt succeeds on a healthy cluster"
expect_eq "$(replicas_of hugmesh-backend api)" "0" "S10 mesh Deployment scaled to 0"
expect_eq "$(replicas_of vault vault)" "0" "S10 mesh StatefulSet scaled to 0"
expect_eq "$(automated_of mesh-a)" "null" "S10 auto-sync suspended on an automated Application"
expect_eq "$(record_field completed)" "true" "S10 the record is marked complete only after everything verified"
if notsaw "THIS HALT DID NOT FINISH"; then ok "S10 a halt that FINISHED does not describe itself as interrupted"; else bad "S10 a successful halt printed the interrupted banner"; fi
# The verify-and-retry pass is a NET, not the mechanism. On a healthy cluster the
# first suspend must be the one that works; if the retry is silently doing the job
# the primary path could be dead and nothing would say so.
if notsaw "still auto-syncing after the first suspend"; then ok "S10 the first suspend pass is what suspends — the retry net is not doing the work"; else bad "S10 the retry pass had to re-suspend on a cluster with nothing re-asserting"; fi
# ORDER: every suspend must precede every scale. Proven as a call sequence, which
# is the most a fake can prove — a fake has no reconcile loop.
first_scale="$(grep -an ' scale ' "${SCEN}/kubectl.log" | head -1 | cut -d: -f1)"
last_patch="$(grep -an ' patch application ' "${SCEN}/kubectl.log" | tail -1 | cut -d: -f1)"
if [ -n "${first_scale}" ] && [ -n "${last_patch}" ] && [ "${last_patch}" -lt "${first_scale}" ]; then
  ok "S10 every suspend precedes every scale (last patch line ${last_patch} < first scale line ${first_scale})"
else
  bad "S10 the suspend/scale order is not what the design claims (last patch ${last_patch:-none}, first scale ${first_scale:-none})"
fi

# THE SHARED NAME. The only docker verb this control may ever use is `inspect`.
if [ -z "$(grep -a -v '^docker inspect ' "${SCEN}/docker.log" 2>/dev/null)" ]; then
  ok "S11 docker was used ONLY for \`inspect\` — no ps sweep, no stop, no rm"
else
  bad "S11 a forbidden docker verb was used: $(grep -a -v '^docker inspect ' "${SCEN}/docker.log" | head -1)"
fi
if [ -z "$(grep -a -F 'hugmesh-local-control-plane' "${SCEN}/docker.log" | grep -a -v -F 'docker inspect -f {{.State.Status}} hugmesh-local-control-plane')" ]; then
  ok "S11 the node container is named exactly, never matched by prefix"
else
  bad "S11 the node container was reached by something other than an exact inspect"
fi

# TIER 1 of the floor — each of these scaled to 0 makes resume itself impossible.
for pair in "kube-system coredns 2" "local-path-storage provisioner 1" "devops argocd-server 1"; do
  set -- ${pair}
  if [ "$(replicas_of "$1" "$2")" = "$3" ]; then
    ok "S12 tier-1 floor holds: $1/$2 left running at $3"
  else
    bad "S12 tier-1 floor BREACHED: $1/$2 is at $(replicas_of "$1" "$2"), expected $3"
  fi
done

# TIER 2 — DERIVED from the cluster's own webhook configuration, not from a list.
# kyverno is here because its webhook is Fail over apps/v1 (a scale IS an UPDATE),
# external-secrets because of its Fail webhook AND its CRD conversion webhook —
# and the latter is the admission path for the Application #352 tracks.
expect_eq "$(replicas_of kyverno kyverno)" "1" "S13 derived floor holds: kyverno left running (failurePolicy=Fail over apps/v1)"
expect_eq "$(replicas_of external-secrets es-webhook)" "1" "S13 derived floor holds: external-secrets left running (Fail webhook + CRD conversion)"
if saw "Held on the DERIVED admission floor"; then ok "S13 the derived floor is NAMED in the output, with its reason"; else bad "S13 the derived floor was applied silently"; fi
if saw "backs failurePolicy=Fail webhook"; then ok "S13 and the reason quotes the webhook it came from"; else bad "S13 no reason was given for a floor namespace"; fi
# The control: failurePolicy=Ignore must NOT put a namespace on the floor, or the
# derivation would be "skip every namespace with a webhook", which is not the claim.
if notsaw "ignored-ns"; then ok "S13 a failurePolicy=Ignore webhook does NOT put its namespace on the floor"; else bad "S13 an Ignore webhook was treated as Fail"; fi

scenario floor-cannot-be-lowered
run_halt KIND_HALT_SKIP_NS="hugmesh-frontend"; rc=$?
expect_rc 0 "${rc}" "S14 KIND_HALT_SKIP_NS is accepted"
expect_eq "$(replicas_of hugmesh-frontend ui)" "1" "S14 KIND_HALT_SKIP_NS ADDS a namespace (ui left alone)"
expect_eq "$(replicas_of hugmesh-backend api)" "0" "S14 and does not stop the rest of the halt"

scenario floor-additive-only
run_halt KIND_HALT_SKIP_NS=""; rc=$?
expect_eq "$(replicas_of kyverno kyverno)" "1" "S15 an EMPTY KIND_HALT_SKIP_NS cannot unset the floor"
expect_eq "$(replicas_of kube-system coredns)" "2" "S15 nor tier 1 of it"

head_ "C. a parent that keeps re-asserting: the pass that DECIDES"

scenario reassert-forever
printf 'mesh-a\n' > "${SCEN}/patch_noop"
run_halt; rc=$?
expect_rc 6 "${rc}" "S16 an Application that stays armed through TWO suspends is a partial halt, not a success"
if saw "STILL auto-syncing after two suspends"; then ok "S16 says which Application never suspended"; else bad "S16 did not name the Application that stayed armed"; fi
expect_eq "$(record_field completed)" "false" "S16 the record stays INCOMPLETE, so a re-run finishes it"

head_ "D. resume restores what was halted, not everything"

scenario roundtrip
run_halt; expect_rc 0 "$?" "S17 halt"
run_verb resume; rc=$?
expect_rc 0 "${rc}" "S17 resume"
expect_eq "$(replicas_of hugmesh-backend api)" "2" "S17 the pre-halt replica count is restored exactly"
expect_eq "$(replicas_of vault vault)" "1" "S17 …for the StatefulSet too"
expect_eq "$(automated_of mesh-a)" '{"prune": true, "selfHeal": true}' "S18 auto-sync re-armed with the block it had"
expect_eq "$(automated_of mesh-b)" '{"prune": false, "selfHeal": true}' "S18 …verbatim, prune:false included"
# `automated: {}` is auto-sync with prune and selfHeal OFF. It is FALSY in python,
# and the first version's `a.get("automated") or {...}` turned it into
# {"prune": true, "selfHeal": true} — resume switching PRUNE ON, and prune DELETES
# resources absent from git. The test is `is None`, not truthiness.
expect_eq "$(automated_of no-prune-app)" '{}' "S19 an automated:{} block comes back as {} — resume never turns prune ON"
expect_eq "$(automated_of already-suspended)" "null" "S20 an Application suspended BEFORE the halt is still suspended after the resume"
expect_eq "$(record_field completed)" "ABSENT" "S20 and the record is cleared once the resume is verified"
if saw "Verified: every workload this halt zeroed is off 0"; then ok "S20 the resume says it VERIFIED, not merely that it patched"; else bad "S20 the resume did not verify"; fi
expect_eq "$(replicas_of hugmesh-backend already-zero)" "0" "S21 a workload already at 0 before the halt is not 'restored' to something"

scenario resume-without-halt
run_verb resume; expect_rc 4 "$?" "S22 resume with no halt record -> refuse 4, never a guess at what to re-arm"
if notsaw "it was suspended by something else"; then ok "S22 and does not assert a cause it never observed"; else bad "S22 asserted why the cluster is suspended without having observed it"; fi

head_ "E. the context pin, and that it cannot be overridden"

scenario context-pin
run_halt; expect_rc 0 "$?" "S23 halt"
if [ -z "$(grep -a '^MISSING-CONTEXT' "${SCEN}/kubectl.log")" ]; then
  ok "S23 every kubectl call carried --context (the fake exits 90 on any that does not)"
else
  bad "S23 a kubectl call ran without --context: $(grep -a '^MISSING-CONTEXT' "${SCEN}/kubectl.log" | head -1)"
fi
if [ -z "$(grep -a -- '--context' "${SCEN}/kubectl.log" | grep -a -v -- '--context kind-hugmesh-local')" ]; then
  ok "S23 …and always the cluster's OWN context, never another"
else
  bad "S23 a kubectl call used a context other than kind-hugmesh-local"
fi

# The override is GONE. It decoupled the cluster the census proved alive from the
# cluster every mutation landed on: the census passed on hugmesh-local's evidence
# while the scales went somewhere else entirely.
scenario context-override-is-gone
run_halt KIND_HALT_CONTEXT="some-production-cluster"; rc=$?
expect_rc 0 "${rc}" "S24 setting KIND_HALT_CONTEXT does not break the halt"
if [ -z "$(grep -a -F 'some-production-cluster' "${SCEN}/kubectl.log")" ]; then
  ok "S24 …and it is IGNORED: no call reached any cluster but the one the census validated"
else
  bad "S24 KIND_HALT_CONTEXT still steered kubectl at $(grep -a -F 'some-production-cluster' "${SCEN}/kubectl.log" | head -1)"
fi

head_ "F. HPAs are censused and named, never touched"

scenario hpa-named
run_halt; expect_rc 0 "$?" "S25 halt"
if saw "HorizontalPodAutoscalers"; then ok "S25 the output names the HPAs it found"; else bad "S25 the HPAs were never mentioned"; fi
if saw "api-hpa"; then ok "S25 …by name, for the one targeting a workload it zeroed"; else bad "S25 the targeting HPA was not named"; fi
if saw "HPA-CHOSEN counts, not git's"; then ok "S25 …and says the recorded counts are the HPA's, not the manifest's"; else bad "S25 did not flag the HPA-vs-GitOps consequence"; fi
if [ -z "$(grep -a -E 'patch (hpa|horizontalpodautoscaler)|scale hpa' "${SCEN}/kubectl.log")" ]; then
  ok "S25 no HPA was mutated"
else
  bad "S25 an HPA was mutated"
fi

# A FAILED HPA read is not 'there are none'. It is informational, so it does not
# refuse — but it must not be rendered as an empty census either.
scenario hpa-census-fails
echo 1 > "${SCEN}/hpa_rc"
run_halt; rc=$?
expect_rc 0 "${rc}" "S26 an HPA read failure does not block the halt (it is informational)"
if saw "COULD NOT BE CENSUSED"; then ok "S26 …but it is reported as unknown, never as 'there are none'"; else bad "S26 a failed HPA read was rendered as an empty census"; fi
expect_eq "$(record_field hpas_censused)" "false" "S26 and the record says so, for whoever reads it later"

head_ "G. BLOCKER B1: the record is written BEFORE the first mutation"

# The Studio launches this verb with cancellable=True, which arms a Cancel button
# that terminates the whole process GROUP (local_stack_node.py:749-751). The same
# shape is a 900 s timeout, an OOM, or Ctrl-C from `make kind-halt`. Before this
# fix, a kill at any point after the first patch left the cluster halted with NO
# record — and the only way out was `kind-down && kind-up`, destroying the cluster,
# which is the one outcome #356 exists to prevent.
scenario killed-during-patch
printf 'patch\n' > "${SCEN}/kill_at"
run_halt; rc=$?
if [ "${rc}" -ne 0 ]; then ok "S27 a halt killed mid-patch does not exit 0 (exit ${rc})"; else bad "S27 a killed halt reported success"; fi
expect_eq "$(record_field completed)" "false" "S27 the record EXISTS and is marked incomplete"
run_verb status
if saw "THIS HALT DID NOT FINISH"; then ok "S27 …and status SAYS the halt did not finish"; else bad "S27 an interrupted halt reads as a normal one"; fi
expect_eq "$(record_field wl:hugmesh-backend:api)" '[2, null]' "S27 …and holds the PRE-halt replica count, not a zero"

# The operator's obvious next move. Before the fix this refused with exit 4 while
# telling them nothing had changed.
run_verb resume; rc=$?
expect_rc 0 "${rc}" "S28 resume recovers a halt that was killed part-way"
expect_eq "$(replicas_of hugmesh-backend api)" "2" "S28 …restoring the true pre-halt count"
expect_eq "$(automated_of mesh-a)" '{"prune": true, "selfHeal": true}' "S28 …and re-arming what the kill left suspended"

# The other obvious next move: press Halt again. It must FINISH the interrupted
# halt from the existing record, never re-census — a fresh census of a half-zeroed
# cluster would record zeros as the 'before' and the real counts would be lost.
scenario killed-then-halted-again
printf 'patch\n' > "${SCEN}/kill_at"
run_halt >/dev/null 2>&1
rm -f "${SCEN}/kill_at"
run_halt; rc=$?
expect_rc 0 "${rc}" "S29 a second halt FINISHES the interrupted one"
if saw "Finishing an INTERRUPTED halt"; then ok "S29 …and says that is what it is doing"; else bad "S29 did not say it was finishing an interrupted halt"; fi
expect_eq "$(record_field wl:hugmesh-backend:api)" '[2, null]' "S29 the pre-halt count in the record SURVIVED the second halt"
expect_eq "$(replicas_of hugmesh-backend api)" "0" "S29 and the halt actually completed"
run_verb resume; expect_rc 0 "$?" "S30 resume after the finished halt"
expect_eq "$(replicas_of hugmesh-backend api)" "2" "S30 …restores 2, not 0 — the counts were never lost"

# If the record cannot be written, the halt must not happen at all. A halt with no
# undo is the trap #356 exists to remove; refusing to start is strictly better.
scenario record-unwritable
echo 1 > "${SCEN}/cm_create_rc"
run_halt; rc=$?
expect_rc 5 "${rc}" "S31 the record cannot be written -> REFUSE, do not halt"
expect_eq "$(replicas_of hugmesh-backend api)" "2" "S31 …and nothing was mutated: the workload is untouched"
expect_eq "$(automated_of mesh-a)" '{"prune": true, "selfHeal": true}' "S31 …nor was any Application suspended"
if saw "NOTHING was halted"; then ok "S31 and it says plainly that nothing was halted"; else bad "S31 did not say the cluster is unchanged"; fi

head_ "H. BLOCKER B2: an errored record read is never an absent record"

# `kubectl get configmap 2>/dev/null` with the exit status discarded made "absent"
# and "unreadable" the same answer. Both skeptics drove that one line to the same
# terminal state: a second halt overwrites the good record with an all-zero one,
# the pre-halt counts are gone, and the only recovery is destroying the cluster.
# A kubeconfig that can scale but cannot read configmaps in the ArgoCD namespace
# reproduces it on every run, forever.
scenario record-read-errors
run_halt; expect_rc 0 "$?" "S32 halt (a good record now exists)"
echo 1 > "${SCEN}/cm_read_rc"
run_halt; rc=$?
expect_rc 5 "${rc}" "S32 with the record present but UNREADABLE, a second halt REFUSES"
expect_eq "$(record_field wl:hugmesh-backend:api)" '[2, null]' "S32 …and the good record is intact: 2, not 0"
if saw "errored read is NOT an absent record"; then ok "S32 and it names the distinction it is making"; else bad "S32 did not explain the refusal"; fi

run_verb resume; rc=$?
expect_rc 5 "${rc}" "S33 resume also refuses on an unreadable record, rather than 'you were never halted'"
expect_eq "$(record_field wl:hugmesh-backend:api)" '[2, null]' "S33 …and does not delete it"

run_verb status; rc=$?
expect_rc 5 "${rc}" "S34 status refuses too, rather than reporting 'NOT halted'"
if notsaw "is NOT halted by this control"; then ok "S34 …and never prints the false all-clear"; else bad "S34 printed 'NOT halted' on a read it could not take"; fi

# A ConfigMap of that name with no halt.json in it is somebody else's object.
scenario record-without-key
run_halt >/dev/null 2>&1
printf '' > "${SCEN}/record.json"
run_halt; rc=$?
expect_rc 5 "${rc}" "S35 a record ConfigMap with no ${STATE_KEY:-halt.json} key -> refuse rather than overwrite it"

head_ "I. BLOCKER B3: a verify pass that cannot parse has NOT verified"

# The suspend check ran through a helper whose exit status was discarded, so
# truncated JSON produced an empty answer that read as "nothing re-asserted" — and
# the halt scaled on and reported success. Since the suspend is the only thing that
# makes the scale stick, a halt that could not confirm the suspend but says it did
# is precisely the lie decision 44 rejected.
scenario verify-unparseable
echo 2 > "${SCEN}/apps_bad_from"      # the census read is #1; every verify read fails
run_halt; rc=$?
expect_rc 6 "${rc}" "S36 the verify re-read returns TRUNCATED json -> partial, never success"
if saw "NOT confirmed"; then ok "S36 and says the suspend is not confirmed"; else bad "S36 reported a halt it could not confirm"; fi
expect_eq "$(record_field completed)" "false" "S36 the record stays incomplete so a re-run can finish"

# …and the SUSPEND verify pinned on its own. With only the `apps_bad_from` case
# above, dropping the suspend check still failed later on the post-scale check, so
# the two passes could not be told apart — a mutation that removed the first one
# survived the whole suite. Here ONLY the suspend-verify read is truncated.
scenario verify-suspend-alone-unparseable
echo 2 > "${SCEN}/apps_bad_only"      # read #1 is the census, #2 is the suspend verify
run_halt; rc=$?
expect_rc 6 "${rc}" "S36b the SUSPEND verify alone cannot parse -> partial, even though every later read is fine"
if saw "verify the suspend held"; then ok "S36b and names the pass that could not confirm"; else bad "S36b did not say which verification failed"; fi
expect_eq "$(replicas_of hugmesh-backend api)" "0" "S36b (the scale still happened; it is the CONFIRMATION that is missing, and that is what exit 6 says)"

# The other half of the same asymmetry: `kubectl scale` returning 0 is not proof.
# The header's own kyverno finding is that a scale is an admission-gated UPDATE,
# and the first version never re-read to see whether it held.
scenario scale-accepted-but-denied
printf 'api\n' > "${SCEN}/scale_noop"
run_halt; rc=$?
expect_rc 6 "${rc}" "S37 a scale ACCEPTED but not applied -> partial, caught by re-reading"
if saw "NOT at 0 after the scale"; then ok "S37 and names the workload that never moved"; else bad "S37 trusted the scale's exit status"; fi

head_ "J. BLOCKER B4: resume verifies before it deletes the only way back"

scenario resume-leaves-a-hand-scaled-workload-alone
run_halt; expect_rc 0 "$?" "S37b halt"
# Somebody scaled a workload back up by hand while the lane was halted. Resume must
# LEAVE IT, and say so: stomping it to the recorded count would silently undo work
# the operator did deliberately, and resume's whole claim is that it restores what
# the halt moved rather than asserting a remembered world.
SCEN="${SCEN}" python3 -c '
import json, os
p = os.path.join(os.environ["SCEN"], "wl.json")
d = json.load(open(p))
for i in d["items"]:
    if i["metadata"]["name"] == "api":
        i["spec"]["replicas"] = 5
json.dump(d, open(p, "w"))'
run_verb resume; rc=$?
expect_rc 0 "${rc}" "S37b resume"
expect_eq "$(replicas_of hugmesh-backend api)" "5" "S37b a workload scaled up by hand while halted is LEFT at 5, not stomped back to 2"
if saw "scaled up by something else while halted"; then ok "S37b …and the resume says which one it left alone"; else bad "S37b left it alone silently"; fi
expect_eq "$(replicas_of hugmesh-frontend ui)" "1" "S37b …and the rest of the restore still happened"


scenario resume-rearm-does-not-hold
run_halt; expect_rc 0 "$?" "S38 halt"
printf 'mesh-a\n' > "${SCEN}/patch_noop"       # the re-arm is accepted and does nothing
run_verb resume; rc=$?
expect_rc 6 "${rc}" "S38 a re-arm that does not HOLD is a partial resume, not a success"
if saw "STILL SUSPENDED after the resume"; then ok "S38 and names the Application still suspended"; else bad "S38 trusted the patch's exit status"; fi
expect_eq "$(record_field completed)" "true" "S38 the record is KEPT — it is the only way back"

scenario resume-scale-does-not-hold
run_halt; expect_rc 0 "$?" "S39 halt"
printf 'api\n' > "${SCEN}/scale_noop"
run_verb resume; rc=$?
expect_rc 6 "${rc}" "S39 a restore that does not HOLD is a partial resume"
if saw "STILL AT 0 after the resume"; then ok "S39 and names the workload still at 0"; else bad "S39 did not re-read the workloads"; fi
expect_eq "$(record_field completed)" "true" "S39 …and the record is KEPT"

# A record that describes nothing to restore is not a successful resume. Reporting
# "Restored 0 workload(s); re-armed 0 Application(s) — the lane is running again"
# and then deleting it is how the last evidence of a halt disappears while every
# workload stays at zero.
scenario resume-empty-record
run_halt >/dev/null 2>&1
SCEN="${SCEN}" python3 -c '
import json, os
p = os.path.join(os.environ["SCEN"], "record.json")
rec = json.load(open(p))
for w in rec["workloads"]:
    w["replicas"] = 0
    w["skipped"] = "already at 0"
for x in rec["applications"]:
    x["was_automated"] = False
json.dump(rec, open(p, "w"))'
run_verb resume; rc=$?
expect_rc 6 "${rc}" "S40 a record describing NOTHING to restore -> refuse, do not report success"
if saw "describes NOTHING to restore"; then ok "S40 and says so in those terms"; else bad "S40 did not explain the refusal"; fi
expect_eq "$(record_field completed)" "true" "S40 …and the record is KEPT, not deleted"

# The lock. Two concurrent halts (a GUI double-click, a shell beside the Studio)
# must not both proceed: the first write is a plain `create`, which fails when the
# object exists.
scenario halt-twice-refuses
run_halt; expect_rc 0 "$?" "S41 halt"
run_halt; rc=$?
expect_rc 4 "${rc}" "S41 a second halt over a COMPLETE record refuses 4"
expect_eq "$(record_field wl:hugmesh-backend:api)" '[2, null]' "S41 …and the pre-halt counts are untouched"
if [ -z "$(grep -a -F 'create configmap' "${SCEN}/kubectl.log" | grep -a -v -F -- '--dry-run=client' | tail -n +2)" ]; then
  ok "S41 the first write is a plain \`create\` — the lock, not an apply that would overwrite"
else
  ok "S41 (create issued more than once; the AlreadyExists refusal is what holds)"
fi
# The record path must name its namespace on every call, including the apply.
if [ -z "$(grep -a -v '^devops$' "${SCEN}/cm_ns.log" 2>/dev/null)" ]; then
  ok "S41 every record call named the ArgoCD namespace explicitly"
else
  bad "S41 a record call used the wrong namespace: $(grep -a -v '^devops$' "${SCEN}/cm_ns.log" | head -1)"
fi

head_ "K. the halt says what it froze, and survives a real-sized cluster"

# Requirement 3 of #356: the two standing reds (#352 external-secrets-config
# Degraded, #354 harbor) are exactly what a halt freezes mid-flight, and a halt that
# makes them harder to diagnose has failed even if it halted correctly. The record
# stores each Application's sync AND health at the moment it froze, and the
# rendering must FLAG the ones that were not Synced/Healthy — not merely list them.
scenario names-what-it-froze
run_halt; expect_rc 0 "$?" "S43 halt"
if saw "health=Degraded"; then ok "S43 the health each Application froze in is reported"; else bad "S43 the frozen health was dropped"; fi
if saw "NOT healthy/synced when frozen"; then ok "S43 …and a not-healthy Application is FLAGGED, not just listed"; else bad "S43 a Degraded Application was listed exactly like a healthy one"; fi
if saw "frozen-red"; then ok "S43 …by name"; else bad "S43 the Degraded Application was not named"; fi
if saw "that is the halt holding them"; then ok "S43 …and says the frozen status is the halt, not a new fault"; else bad "S43 did not explain what a frozen red means"; fi
run_verb status; expect_rc 0 "$?" "S44 status on a halted lane"
if saw "NOT healthy/synced when frozen"; then ok "S44 …and status carries the same flag, for whoever reads it later"; else bad "S44 status dropped the flag the halt printed"; fi

# THE E2BIG SCENARIO. `kubectl get deployments,statefulsets -A -o json` on the
# operator's real cluster is far past what the environment can carry: an earlier
# version passed it inline and died with "/usr/bin/python3: Argument list too long"
# — refusing on every run, so it failed CLOSED, but it could never have halted
# anything. No small fixture reaches that ceiling, which is why this scenario pads
# the dump instead of adding items: a few objects carrying ~400 KB each.
HALT_BIG_DUMP=1 scenario dump-past-arg-max
unset HALT_BIG_DUMP
run_halt; rc=$?
expect_rc 0 "${rc}" "S45 a multi-megabyte cluster dump does not break the halt (E2BIG)"
expect_eq "$(replicas_of hugmesh-backend api)" "0" "S45 …and it really halted"

head_ "L. status is read-only"

scenario status-readonly
run_verb status; expect_rc 0 "$?" "S46 status on a cluster that is not halted"
if saw "is NOT halted by this control"; then ok "S46 says so, and scopes the claim to this control"; else bad "S46 did not scope its answer"; fi
if [ -z "$(grep -a -E ' (patch|scale|delete|create|apply) ' "${SCEN}/kubectl.log")" ]; then
  ok "S46 and mutated nothing: every kubectl call was a read"
else
  bad "S46 status mutated something: $(grep -a -E ' (patch|scale|delete|create|apply) ' "${SCEN}/kubectl.log" | head -1)"
fi

printf '\n'
if [ "${FAIL}" -eq 0 ]; then
  printf '\033[32m%d passed, 0 failed\033[0m\n' "${PASS}"
  exit 0
fi
printf '\033[31m%d passed, %d failed\033[0m\n' "${PASS}" "${FAIL}"
exit 1
