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
# WHAT IS PINNED HERE, and why each one is a refusal that was measured first:
#
#   THE CENSUS CONTRACT (the most important one). tests/scripts/run-ungated-lane.sh
#   :60-91 exits 5 when the footprint CANNOT BE DETERMINED, because *"a census that
#   errors is NOT an empty census: before 2026-09-16 the two were indistinguishable
#   and the lane proceeded on a dead daemon."* A stop control that reads a failed
#   `kind get clusters` or a broken kubeconfig as "no cluster" would report that it
#   halted something it never saw. Scenarios 1, 3, 5, 6, 7.
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
#   prefix would take out the operator's compose mesh. Scenario 8 asserts on the
#   docker call log that the ONLY docker verb ever used is `inspect`, of ONE exact
#   name - no `ps`, no `stop`, no `rm`.
#
#   THE MANDATORY FLOOR. Scaling kyverno to 0 wedges the cluster against its own
#   resume: `kyverno-resource-validating-webhook-cfg` is failurePolicy=Fail over
#   apps/v1 deployments+statefulsets UPDATE outside kube-system/kyverno (measured on
#   the live cluster 2026-09-17), and a scale IS an UPDATE. Same class for
#   kube-system, local-path-storage and the ArgoCD namespace. Scenarios 10, 11
#   prove the floor holds and that KIND_HALT_SKIP_NS cannot lower it.
#
#   RESUME RESTORES WHAT WAS HALTED, NOT EVERYTHING. An Application suspended before
#   the halt must still be suspended after the resume. Scenarios 9, 14, 15, 16.
#
#   THE CONTEXT PIN. Every kubectl call must carry `--context kind-<cluster>`; the
#   fake REFUSES any call without it (exit 90). Without the pin, a halt run with a
#   work kubeconfig loaded would scale down someone else's cluster. Scenario 17.
#
# THE MUTATION BATTERY this suite is measured against — 16 applied to a COPY of
# scripts/kind-halt.sh (never the file itself, and never a file bash is running),
# each verified by sha256 to have CHANGED the copy. 16 applied, 16 killed,
# 2026-09-17:
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
#   M10 census: `grep -ax` -> `grep -a` (hugmesh-local matches hugmesh-local-2)
#   M11 halt: skip the suspend loop entirely (the scale-only halt, i.e. the lie)
#   M12 record: hardcode was_automated True (an already-suspended app becomes ours)
#   M13 render: stop reporting the health each Application froze in
#   M14 halt: report a failed record write as success
#   M15 census: swallow a failed `docker inspect` (a dead socket reads as fine)
#   M16 plan: send the cluster dumps through the ENVIRONMENT again (the E2BIG bug)
#
# M11 SURVIVED the first time this battery ran, and the reason is worth keeping.
# The halt verifies its suspend and re-suspends anything a parent re-asserted — and
# that retry net quietly did the whole job when the primary loop was cut out, so the
# end state was right and no assertion could tell. Two things came out of it: S8 now
# asserts the retry is NOT used on a healthy cluster (a net that is load-bearing is
# a dead primary path nobody can see), and the script gained the pass that actually
# decides — a SECOND verification after the re-suspend, because a `kubectl patch`
# returning 0 has not proved the suspend HELD. Without that, a persistent
# re-asserter produced a green halt with auto-sync still armed, which is exactly the
# lie decision 44 rejected. Scenario 25 is that case.
#
# NOT CLOSED, and stated rather than implied: nothing here proves the ORDER of the
# two phases (suspend before scale) matters against a real ArgoCD, because a fake
# has no reconcile loop. The order is argued from specs/cluster (98 of 98 app files
# carry prune+selfHeal) and pinned only by reading.
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
  cat > "${ROOT}/kubectl_fake.py" <<'FAKE'
import json, os, sys

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

# `get nodes` — API reachability.
if a[:2] == ["get", "nodes"]:
    rc = rc_for("nodes_rc")
    if rc: sys.stderr.write("The connection to the server 127.0.0.1:6443 was refused\n"); sys.exit(rc)
    print("hugmesh-local-control-plane   Ready   control-plane   30h   v1.34.0"); sys.exit(0)

if a[:2] == ["get", "crd"]:
    rc = rc_for("crd_rc")
    if rc: sys.stderr.write('Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "applications.argoproj.io" not found\n'); sys.exit(rc)
    print("applications.argoproj.io   2026-09-16T00:00:00Z"); sys.exit(0)

if a[:2] == ["get", "applications"] and "-A" in a:
    rc = rc_for("apps_list_rc")
    if rc: sys.stderr.write("the server could not find the requested resource\n"); sys.exit(rc)
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
        if not os.path.exists(p("record.json")): sys.stderr.write("Error from server (NotFound)\n"); sys.exit(1)
        with open(p("record.json")) as fh: sys.stdout.write(fh.read())
        sys.exit(0)

    if rest[:2] == ["delete", "configmap"]:
        if rc_for("cm_delete_rc"): sys.exit(1)
        if os.path.exists(p("record.json")): os.remove(p("record.json"))
        print("configmap deleted"); sys.exit(0)

    if rest[:2] == ["create", "configmap"]:
        if rc_for("cm_write_rc"): sys.stderr.write("forbidden\n"); sys.exit(1)
        src = [x.split("=", 2)[-1] for x in rest if x.startswith("--from-file=")][0]
        with open(src) as fh: body = fh.read()
        # A faithful-enough create|apply pipeline: the payload really travels.
        sys.stdout.write("kind: ConfigMap\n---PAYLOAD---\n" + body)
        sys.exit(0)

    if rest[0] == "patch" and rest[1] == "application":
        name = rest[2]
        patch = json.loads(rest[rest.index("-p") + 1])
        # A named Application whose patch is refused, for the partial-failure path.
        blocked = []
        if os.path.exists(p("unpatchable")):
            with open(p("unpatchable")) as fh: blocked = fh.read().split()
        if name in blocked:
            sys.stderr.write("admission webhook denied the request\n"); sys.exit(1)
        # A parent (a repo-recursing app-of-apps root, an ApplicationSet) that
        # re-asserts the Application the instant it is suspended: the patch is
        # ACCEPTED and changes nothing. A control that trusted rc=0 here would
        # report a halt while auto-sync was still armed.
        reassert = []
        if os.path.exists(p("reassert")):
            with open(p("reassert")) as fh: reassert = fh.read().split()
        if name in reassert:
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
        if rc_for("scale_rc"):
            sys.stderr.write("admission webhook \"validate.kyverno.svc-fail\" denied the request\n"); sys.exit(1)
        wl = load("wl.json")
        for item in wl["items"]:
            if item["metadata"]["name"] == name and item["metadata"]["namespace"] == ns:
                item["spec"]["replicas"] = want
                save("wl.json", wl); print("scaled"); sys.exit(0)
        sys.stderr.write("Error from server (NotFound)\n"); sys.exit(1)

    if rest[0] == "get" and rest[1] in ("Deployment", "StatefulSet", "deployment", "statefulset"):
        name = rest[2]
        wl = load("wl.json")
        for item in wl["items"]:
            if item["metadata"]["name"] == name and item["metadata"]["namespace"] == ns:
                sys.stdout.write(str(item["spec"].get("replicas", ""))); sys.exit(0)
        sys.exit(0)   # absent -> empty, which the script reads as GONE

    if rest[0] == "get" and rest[1] == "application":
        name = rest[2]
        apps = load("apps.json")
        for item in apps["items"]:
            if item["metadata"]["name"] == name and item["metadata"]["namespace"] == ns:
                auto = (item.get("spec", {}).get("syncPolicy", {}) or {}).get("automated")
                sys.stdout.write("" if auto is None else json.dumps(auto))
                sys.exit(0)
        sys.exit(0)

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
#   already-suspended   NO automated block             -> never touched, ever
# and workloads spread across the mandatory floor and the mesh namespaces.
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
 {"kind": "Deployment",  "metadata": {"name": "coredns",   "namespace": "kube-system"},      "spec": {"replicas": 2}},
 {"kind": "Deployment",  "metadata": {"name": "provisioner","namespace": "local-path-storage"}, "spec": {"replicas": 1}},
 {"kind": "Deployment",  "metadata": {"name": "argocd-server","namespace": "devops"},        "spec": {"replicas": 1}},
 {"kind": "Deployment",  "metadata": {"name": "already-zero","namespace": "hugmesh-backend"},"spec": {"replicas": 0}}
]}
JSON
  export SCEN
}

run_halt() {
  env PATH="${ROOT}/bin:${PATH}" SCEN="${SCEN}" KIND_HALT_SETTLE_S=0 \
      "$@" bash "${TARGET}" halt >"${SCEN}/out" 2>"${SCEN}/err"
}
run_verb() {
  local verb
  verb="$1"
  shift
  env PATH="${ROOT}/bin:${PATH}" SCEN="${SCEN}" KIND_HALT_SETTLE_S=0 \
      "$@" bash "${TARGET}" "${verb}" >"${SCEN}/out" 2>"${SCEN}/err"
}
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

make_fakes

head_ "1-7  the census contract: an errored census is never an empty census"

scenario census-kind-fails
echo 1 > "${SCEN}/kind_rc"
run_halt; expect_rc 5 "$?" "S1  \`kind get clusters\` FAILS -> refuse"
if saw "census could not be taken"; then ok "S1  says the census could not be taken"; else bad "S1  did not say the census could not be taken"; fi
if saw "kind get clusters failed"; then ok "S1  quotes the tool's own failure"; else bad "S1  did not quote the tool's failure"; fi

scenario census-not-listed
printf 'some-other-cluster\n' > "${SCEN}/clusters"
run_halt; expect_rc 3 "$?" "S2  cluster genuinely absent -> refuse 3, distinct from 5"

# The name match must be WHOLE-LINE. `hugmesh-local` is a prefix of
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

head_ "8-13  the happy path, the floor, and the two names that mean two things"

scenario halt-happy
run_halt; rc=$?
expect_rc 0 "${rc}" "S8  halt succeeds on a healthy cluster"
if [ "$(replicas_of hugmesh-backend api)" = "0" ]; then ok "S8  mesh Deployment scaled to 0"; else bad "S8  mesh Deployment NOT scaled (got $(replicas_of hugmesh-backend api))"; fi
if [ "$(replicas_of vault vault)" = "0" ]; then ok "S8  mesh StatefulSet scaled to 0"; else bad "S8  mesh StatefulSet NOT scaled"; fi
if [ "$(automated_of mesh-a)" = "null" ]; then ok "S8  auto-sync suspended on an automated Application"; else bad "S8  auto-sync NOT suspended (got $(automated_of mesh-a))"; fi
# The verify-and-retry pass is a NET, not the mechanism. On a healthy cluster the
# first suspend must be the one that works; if the retry is silently doing the job
# the primary path could be dead and nothing would say so.
if notsaw "still auto-syncing after the first suspend"; then ok "S8  the first suspend pass is what suspends — the retry net is not doing the work"; else bad "S8  the retry pass had to re-suspend on a cluster with nothing re-asserting"; fi

# THE SHARED NAME. The only docker verb this control may ever use is `inspect`.
if [ -z "$(grep -a -v '^docker inspect ' "${SCEN}/docker.log" 2>/dev/null)" ]; then
  ok "S9  docker was used ONLY for \`inspect\` — no ps sweep, no stop, no rm"
else
  bad "S9  a forbidden docker verb was used: $(grep -a -v '^docker inspect ' "${SCEN}/docker.log" | head -1)"
fi
if [ -z "$(grep -a -F 'hugmesh-local-control-plane' "${SCEN}/docker.log" | grep -a -v -F 'docker inspect -f {{.State.Status}} hugmesh-local-control-plane')" ]; then
  ok "S9  the node container is named exactly, never matched by prefix"
else
  bad "S9  the node container was reached by something other than an exact inspect"
fi

# THE MANDATORY FLOOR — each of these scaled to 0 makes resume itself impossible.
for pair in "kyverno kyverno 1" "kube-system coredns 2" "local-path-storage provisioner 1" "devops argocd-server 1"; do
  set -- ${pair}
  if [ "$(replicas_of "$1" "$2")" = "$3" ]; then
    ok "S10 floor holds: $1/$2 left running at $3"
  else
    bad "S10 FLOOR BREACHED: $1/$2 is now $(replicas_of "$1" "$2"), expected $3"
  fi
done
if saw "already at 0"; then ok "S11 a workload already at 0 is recorded as skipped, not 'restored' later"; else bad "S11 did not account for an already-zero workload"; fi

# The floor is additive-only. KIND_HALT_SKIP_NS must not be able to REMOVE kyverno.
scenario floor-not-lowerable
run_halt KIND_HALT_SKIP_NS="hugmesh-frontend"; rc=$?
expect_rc 0 "${rc}" "S12 halt with an extra skip namespace"
if [ "$(replicas_of kyverno kyverno)" = "1" ]; then ok "S12 KIND_HALT_SKIP_NS ADDS to the floor, it cannot replace it"; else bad "S12 the mandatory floor was lowered by KIND_HALT_SKIP_NS"; fi
if [ "$(replicas_of hugmesh-frontend ui)" = "1" ]; then ok "S12 the extra namespace was honoured"; else bad "S12 the extra namespace was ignored"; fi

scenario already-halted
run_halt >/dev/null 2>&1
run_halt; expect_rc 4 "$?" "S13 halting an already-halted cluster -> refuse 4 (the pre-halt replica counts are not overwritten)"

head_ "14-18  resume restores what was halted, and only that"

scenario resume-round-trip
run_halt >/dev/null 2>&1
run_verb resume; rc=$?
expect_rc 0 "${rc}" "S14 resume succeeds"
if [ "$(replicas_of hugmesh-backend api)" = "2" ]; then ok "S14 replicas restored to the EXACT recorded count (2, not 1)"; else bad "S14 replicas wrong after resume: $(replicas_of hugmesh-backend api)"; fi
if [ "$(automated_of mesh-b)" = '{"prune": false, "selfHeal": true}' ]; then ok "S14 the exact automated block is restored, prune:false and all"; else bad "S14 automated block not restored verbatim: $(automated_of mesh-b)"; fi
if [ "$(automated_of already-suspended)" = "null" ]; then ok "S15 an Application suspended BEFORE the halt is still suspended after the resume"; else bad "S15 resume re-armed something it never suspended: $(automated_of already-suspended)"; fi
if [ "$(replicas_of hugmesh-backend already-zero)" = "0" ]; then ok "S15 a workload already at 0 before the halt is not 'restored' to something"; else bad "S15 an already-zero workload was changed"; fi

scenario resume-no-record
run_verb resume; expect_rc 4 "$?" "S16 resume with no halt record -> refuse 4, re-arming 'everything' is never guessed"
if saw "re-arming 'everything' would silently undo a deliberate suspend"; then ok "S16 says why it will not guess"; else bad "S16 gave no reason"; fi

scenario resume-left-alone
run_halt >/dev/null 2>&1
# Someone scales a workload up, and re-arms one Application, while the lane is halted.
SCEN="${SCEN}" python3 -c '
import json, os
p = os.path.join(os.environ["SCEN"], "wl.json"); d = json.load(open(p))
for i in d["items"]:
    if i["metadata"]["name"] == "api": i["spec"]["replicas"] = 5
json.dump(d, open(p, "w"))
p = os.path.join(os.environ["SCEN"], "apps.json"); d = json.load(open(p))
for i in d["items"]:
    if i["metadata"]["name"] == "mesh-a":
        i["spec"]["syncPolicy"]["automated"] = {"prune": True, "selfHeal": True}
json.dump(d, open(p, "w"))'
run_verb resume; rc=$?
expect_rc 0 "${rc}" "S17 resume over hand-made changes"
if [ "$(replicas_of hugmesh-backend api)" = "5" ]; then ok "S17 a workload scaled up by hand is LEFT ALONE, not stomped back to the recorded count"; else bad "S17 resume stomped a hand-made scale: $(replicas_of hugmesh-backend api)"; fi
if saw "left alone"; then ok "S17 says which items it left alone"; else bad "S17 did not report what it left alone"; fi

scenario resume-context-pin
run_halt >/dev/null 2>&1
run_verb resume >/dev/null 2>&1
if [ -z "$(grep -a -F 'MISSING-CONTEXT' "${SCEN}/kubectl.log" 2>/dev/null)" ]; then
  ok "S18 every kubectl call in a full halt+resume round trip carries --context"
else
  bad "S18 a kubectl call ran with no --context pin: $(grep -a -F 'MISSING-CONTEXT' "${SCEN}/kubectl.log" | head -1)"
fi
if [ -n "$(grep -a -F -- '--context kind-hugmesh-local' "${SCEN}/kubectl.log" 2>/dev/null)" ]; then
  ok "S18 the context is the cluster's own, kind-hugmesh-local"
else
  bad "S18 the pinned context was not kind-<cluster>"
fi

head_ "19-22  what the control SAYS — the halt must not hide a standing red"

scenario says-what-it-suspended
run_halt >/dev/null 2>&1
run_verb status; rc=$?
expect_rc 0 "${rc}" "S19 status reads the record back"
for app in mesh-a mesh-b frozen-red; do
  if saw "${app}"; then ok "S19 names ${app} as suspended"; else bad "S19 did not name ${app}"; fi
done
if saw "health=Degraded"; then ok "S20 records the HEALTH each Application was in when it froze (#352's shape)"; else bad "S20 did not record health at freeze time"; fi
if saw "NOT healthy/synced when frozen"; then ok "S20 flags the ones frozen mid-flight instead of burying them"; else bad "S20 did not flag a mid-flight freeze"; fi
if saw "already suspended before the halt"; then ok "S21 distinguishes what it suspended from what was already suspended"; else bad "S21 did not distinguish the two"; fi
if saw "DaemonSets are never touched"; then ok "S22 says out loud that DaemonSets are out of scope"; else bad "S22 silently skipped DaemonSets"; fi

scenario status-not-halted
run_verb status; rc=$?
expect_rc 0 "${rc}" "S22 status on a running cluster"
if saw "is NOT halted by this control"; then ok "S22 says 'not halted by this control', not 'everything is auto-syncing'"; else bad "S22 overclaimed on an un-halted cluster"; fi

head_ "23  partial failure is exit 6, and the record survives it"

scenario partial-scale-failure
echo 1 > "${SCEN}/scale_rc"
run_halt; expect_rc 6 "$?" "S23 a scale that is denied -> exit 6, not a false green"
if saw "did not move"; then ok "S23 names the stragglers"; else bad "S23 went quiet about the failures"; fi
if [ -f "${SCEN}/record.json" ]; then ok "S23 the halt record is KEPT so a re-run can finish"; else bad "S23 lost the record on a partial failure"; fi

# A parent that keeps re-asserting the suspend. `kubectl patch` returns 0 every
# time and changes nothing, which is exactly how a repo-recursing app-of-apps root
# behaves. Reporting a halt here would be the lie decision 44 rejected: the
# workloads get zeroed and selfHeal scales them straight back up.
scenario persistent-reassert
printf 'mesh-a\n' > "${SCEN}/reassert"
run_halt; expect_rc 6 "$?" "S25 a parent that keeps re-asserting -> exit 6, never a green halt"
if saw "STILL auto-syncing after two suspends"; then ok "S25 says the suspend did not hold"; else bad "S25 claimed a halt that did not hold"; fi
if saw "halt is NOT complete"; then ok "S25 says plainly the halt is incomplete"; else bad "S25 did not say the halt was incomplete"; fi
if saw "mesh-a"; then ok "S25 names the Application that would not stay suspended"; else bad "S25 did not name the straggler"; fi

# THE E2BIG REGRESSION, and the reason a fixture suite needs one big fixture.
#
# The first version of kind-halt.sh passed both `kubectl get -o json` dumps to its
# python helpers through the ENVIRONMENT. Against the four-Application fixture above
# that works forever. Against the operator's real cluster it died on
#     /usr/bin/python3: Argument list too long
# and the control refused every time — it could never have halted anything. It was
# found only by running the real thing against real cluster data with writes blocked,
# never by this suite. The dumps now travel as FILE PATHS; this scenario is what
# stops that from coming back, by making the fixture itself exceed what the
# environment can carry.
scenario oversized-cluster-json
SCEN="${SCEN}" python3 -c '
import json, os
p = os.path.join(os.environ["SCEN"], "wl.json")
d = json.load(open(p))
# ~4 MB of annotations on a workload that is on the mandatory floor, so the bulk
# costs one parse and no extra writes. ARG_MAX on this class of host is ~2 MB for
# the whole environment plus argv, so this is comfortably past it.
for i in d["items"]:
    if i["metadata"]["name"] == "coredns":
        i["metadata"]["annotations"] = {"kubectl.kubernetes.io/last-applied": "x" * 4_000_000}
json.dump(d, open(p, "w"))
print("wl.json is now %.1f MB" % (os.path.getsize(p) / 1e6))'
run_halt; rc=$?
expect_rc 0 "${rc}" "S26 a cluster whose JSON exceeds ARG_MAX still halts (the E2BIG regression)"
if [ "$(replicas_of hugmesh-backend api)" = "0" ]; then ok "S26 the plan was still built and applied from the oversized dump"; else bad "S26 the oversized dump broke the plan: api is $(replicas_of hugmesh-backend api)"; fi
if notsaw "Argument list too long"; then ok "S26 no E2BIG"; else bad "S26 E2BIG: the dumps are travelling through the environment again"; fi

scenario record-write-fails
echo 1 > "${SCEN}/cm_write_rc"
run_halt; expect_rc 6 "$?" "S24 the record cannot be written -> exit 6, never a green halt with no way back"
if saw "Resume cannot be automatic"; then ok "S24 says resume cannot be automatic"; else bad "S24 did not warn that resume is now manual"; fi
if saw "mesh-a"; then ok "S24 still prints the halted set, so it is not lost with the record"; else bad "S24 printed no halted set"; fi

head_ "summary"
printf '  %d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -gt 0 ]; then exit 1; fi
exit 0
