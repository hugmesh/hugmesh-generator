#!/usr/bin/env bash
# test-kind-doctor.sh — EXECUTE scripts/kind-doctor.sh against stubbed docker and
# kubectl and prove it actually detects each of the two failures that let the
# kind lane sit dead for two days (hugmesh-generator#349).
#
# Executed, not read. A guard nobody has run against a synthetic version of the
# outage it is written for is a guard nobody has tested.
#
# It also covers the two classes an earlier round of this suite could not see,
# both found by adversarial review on 2026-09-10:
#
#   NEGATIVE TOOLING. Scenarios 15-20 break the doctor's OWN tooling — python3
#   off PATH, a kubectl whose pod endpoints fail, unparseable JSON, a crictl
#   that will not run, a cluster with zero pods — and require the doctor to go
#   RED on every one. It used to print `kind-doctor: healthy` through all of
#   them. A guard that goes green when it could not run is worse than no guard,
#   because it is the thing you check after two dead days.
#
#   UNEXERCISED PATHS. Every scenario before this round fed section 4 an EMPTY
#   pod list, so `[ -z "${bad}" ] -> ok "all pods Running"` was printed 14
#   times and asserted on zero times; replacing that whole condition with
#   `true` survived the suite. scenario() now supplies a real pod table by
#   default and 19/25 make it a knob.
#
# The bootstrap half is covered too: scenario 26 EXTRACTS the egress preflight
# out of bootstrap-kind.sh and runs it against a stub docker, because that is
# the half of this change that can hard-abort a bring-up and it had no test at
# all.
#
# THE MUTATION BATTERY this suite is measured against — 13 applied, 13 killed,
# each verified to have changed the file and each restored to its exact sha256:
#
#   M1  drop `index($0, want) > 0 &&` from the suffix compare   (the blocker)
#   M2  section 4's pod verdict -> unconditionally ok
#   M3  zero pods -> warn instead of fail
#   M4  drop the leading slash from the suffix candidate
#   M5  drop python3 from the tool preflight
#   M6  restore `except Exception: sys.exit(0)` in the pod-list filter
#   M7  stop checking crictl's exit status
#   M8  let a digest-pinned ref fall back to the bare name:tag
#   M9  a failed `get pods -o json` -> the old "no pods found" shrug
#   M10 bootstrap's preflight condition inverted (default OFF)
#   M11 bootstrap's probe resolves a name INSIDE the node
#   M12 drop `|| true` from the doctor's host-side resolution
#   M13 drop `|| true` from the bootstrap's host-side resolution
#
# FIVE of these survived at first, and the two reasons are worth keeping.
#
#   M3, M5, M6 survived while the assertions were rc-only. All three still
#   produce a non-zero run — through a DIFFERENT fail-closed path — so `rc != 0`
#   cannot distinguish "the guard caught it" from "something else fell over
#   first". Where a mutation is masked that way, assert on the MESSAGE.
#
#   M12, M13 survived while scenario 27 called the target function inside a
#   command substitution. At the real call site the function IS a `for` word
#   list, and bash suppresses errexit for a command substitution in that
#   position, so the guard is invisible there. Testing the shape the code
#   happens to use today proved nothing about the code; testing the BARE call
#   pins the property the guard actually claims.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCTOR="${REPO_ROOT}/scripts/kind-doctor.sh"
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL+1)); }

[ -x "${DOCTOR}" ] || { echo "missing ${DOCTOR}"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin"; mkdir -p "${BIN}"

# ── stub factory ────────────────────────────────────────────────────────────
# Each scenario writes three files the stubs read: node state, egress verdict,
# and the JSON the cluster would answer with.
make_stubs() {
  cat > "${BIN}/docker" <<'DOCKER'
#!/usr/bin/env bash
STATE="${STUB_DIR}"
case "$1" in
  inspect)
    for a in "$@"; do case "$a" in *control-plane) node="$a";; esac; done
    [ "$(cat "${STATE}/node_exists")" = "1" ] || exit 1
    case " $* " in *" -f "*) cat "${STATE}/node_state";; esac
    exit 0 ;;
  exec)
    shift
    # `docker exec NODE timeout N bash -c "exec 3<>/dev/tcp/H/P"`
    case " $* " in
      *"/dev/tcp/"*) [ "$(cat "${STATE}/egress")" = "1" ] && exit 0 || exit 1 ;;
      *"cat /etc/resolv.conf"*) cat "${STATE}/resolv"; exit 0 ;;
      *"crictl images"*)
        [ "$(cat "${STATE}/crictl_rc")" = "0" ] || exit 1
        cat "${STATE}/held.json"; exit 0 ;;
    esac
    exit 0 ;;
  run) exit 0 ;;
esac
exit 0
DOCKER
  cat > "${BIN}/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
STATE="${STUB_DIR}"
args="$*"
case "${args}" in
  *"get nodes"*)        exit "$(cat "${STATE}/nodes_rc")" ;;
  *"get pods -A -o json"*)
    [ "$(cat "${STATE}/pods_json_rc")" = "0" ] || exit 1
    cat "${STATE}/pods.json"; exit 0 ;;
  *"get pods -A --no-headers"*)
    [ "$(cat "${STATE}/pods_txt_rc")" = "0" ] || exit 1
    cat "${STATE}/pods.txt"; exit 0 ;;
  *"get crd applications"*) exit 1 ;;
esac
exit 0
KUBECTL
  chmod +x "${BIN}/docker" "${BIN}/kubectl"
}

scenario() {
  s_name="$1"; s_node="$2"; s_state="$3"; s_egress="$4"; s_pods="$5"; s_held="$6"
  STUB_DIR="${WORK}/${s_name}"; mkdir -p "${STUB_DIR}"
  printf '%s' "${s_node}"  > "${STUB_DIR}/node_exists"
  printf '%s' "${s_state}" > "${STUB_DIR}/node_state"
  printf '%s' "${s_egress}"> "${STUB_DIR}/egress"
  printf '%s' "${s_pods}"  > "${STUB_DIR}/pods.json"
  printf '%s' "${s_held}"  > "${STUB_DIR}/held.json"
  # A REAL pod table by default, not an empty one. Every scenario in the first
  # round of this suite left this empty, which meant section 4 always took its
  # `ok "all pods Running"` branch and no assertion ever reached the branch
  # that reports a sick pod. Mutating that condition to `true` survived the
  # whole suite. An empty table is now a deliberate knob (scenario 19), and it
  # is a FAILURE, not health: a reachable API server listing no pods at all,
  # kube-system included, is a cluster running nothing.
  printf 'kube-system   coredns-aaa   1/1   Running   0   2d\n' > "${STUB_DIR}/pods.txt"
  printf '# Generated by Docker Engine.\nnameserver 172.18.0.1\n' > "${STUB_DIR}/resolv"
  # Tooling knobs. Default 0 = the tool answers. Scenarios 16-20 flip them to
  # prove the doctor fails CLOSED when its own tooling cannot run.
  printf '0' > "${STUB_DIR}/nodes_rc"
  printf '0' > "${STUB_DIR}/pods_json_rc"
  printf '0' > "${STUB_DIR}/pods_txt_rc"
  printf '0' > "${STUB_DIR}/crictl_rc"
  export STUB_DIR
}

# Override one knob after scenario() has laid down the defaults.
knob() { printf '%s' "$2" > "${STUB_DIR}/$1"; }

PODS_ONE_APP='{"items":[{"spec":{"containers":[{"image":"registry.hugmesh.net/hugmesh/hugmesh-login-ui:main"}]}}]}'
HELD_NONE='{"images":[]}'
HELD_IT='{"images":[{"repoTags":["registry.hugmesh.net/hugmesh/hugmesh-login-ui:main"]}]}'

run_doctor() { PATH="${BIN}:${PATH}" KIND_CLUSTER_NAME=stub bash "${DOCTOR}" 2>&1; }
# Same, but with a caller-supplied PATH — used to prove the doctor refuses to
# run at all when python3 is absent.
run_doctor_path() { PATH="$1" KIND_CLUSTER_NAME=stub HUGMESH_TOOLS_BIN=/nonexistent bash "${DOCTOR}" 2>&1; }

echo "== 1. a cluster whose node container is gone =="
make_stubs; scenario gone 0 running 1 "${PODS_ONE_APP}" "${HELD_NONE}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "exits non-zero" || bad "exited 0 with no node container"
case "${out}" in *"make kind-up"*) ok "names the rebuild command";; *) bad "does not name 'make kind-up'";; esac

echo "== 2. node up, but zero egress (the netfilter wipe) =="
make_stubs; scenario noegress 1 running 0 "${PODS_ONE_APP}" "${HELD_IT}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "exits non-zero" || bad "reported healthy with no egress"
case "${out}" in *"nft list tables"*) ok "tells you how to check docker's netfilter tables";; *) bad "no nft guidance";; esac
case "${out}" in *"NOT DNS"*|*"not DNS"*|*"almost never DNS"*) ok "says explicitly this is not DNS";; *) bad "does not warn against the DNS misreading";; esac
case "${out}" in *"restart"*) ok "names the daemon restart";; *) bad "does not name the restart";; esac

echo "== 3. egress fine, but no first-party image loaded =="
make_stubs; scenario noimg 1 running 1 "${PODS_ONE_APP}" "${HELD_NONE}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "exits non-zero" || bad "reported healthy with no app image"
case "${out}" in *"make kind-images"*) ok "names 'make kind-images'";; *) bad "does not name the loader";; esac
case "${out}" in *"hugmesh-login-ui:main"*) ok "names the missing ref";; *) bad "does not name which image is missing";; esac

echo "== 4. everything present =="
make_stubs; scenario good 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -eq 0 ] && ok "exits 0 on a healthy cluster" || bad "false alarm on a healthy cluster: ${out}"

echo "== 5. WARN_ONLY downgrades a failure for bring-up only =="
make_stubs; scenario warnonly 1 running 1 "${PODS_ONE_APP}" "${HELD_NONE}"
out="$(PATH="${BIN}:${PATH}" KIND_DOCTOR_WARN_ONLY=1 KIND_CLUSTER_NAME=stub bash "${DOCTOR}" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "WARN_ONLY exits 0" || bad "WARN_ONLY still exited ${rc}"
case "${out}" in *"make kind-images"*) ok "WARN_ONLY still reports the problem";; *) bad "WARN_ONLY went silent";; esac

echo "== 6. BOTH egress probes are raw TCP, and nothing is resolved INSIDE the node =="
# The whole point: docker's embedded resolver runs in the HOST netns and answers
# through this outage, so a probe that resolves a name inside the NODE reports
# green during the exact failure. Host-side resolution is fine and deliberate —
# the host turns a registry name into an A record and hands the node a literal —
# so this pins the `docker exec` command specifically rather than banning the
# word `getent` from the whole block.
#
# Both copies are pinned. bootstrap-kind.sh's probe is the one that can HARD
# ABORT a bring-up, and until this round nothing in tests/ referenced it: it
# could have been rewritten as a name lookup with every suite still green.
BOOTSTRAP="${REPO_ROOT}/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"
[ -r "${BOOTSTRAP}" ] || bad "bootstrap-kind.sh not found at ${BOOTSTRAP}"
probe_pin() {
  pin_label="$1"; pin_block="$2"
  case "${pin_block}" in
    *"/dev/tcp/"*) ok "${pin_label}: probe uses /dev/tcp" ;;
    *) bad "${pin_label}: probe no longer uses /dev/tcp" ;;
  esac
  pin_exec="$(printf '%s\n' "${pin_block}" | grep -a 'docker exec' || true)"
  if [ -z "${pin_exec}" ]; then
    bad "${pin_label}: no 'docker exec' probe found at all"
    return
  fi
  if printf '%s\n' "${pin_exec}" | grep -aE 'getent|nslookup|dig |host |curl|wget' >/dev/null 2>&1; then
    bad "${pin_label}: the node-side command resolves a NAME — it reports green through the outage it exists to catch"
  else
    ok "${pin_label}: the node-side command resolves nothing"
  fi
  case "${pin_exec}" in
    *'/dev/tcp/${'*) ok "${pin_label}: the node connects to an address held in a variable, never a name" ;;
    *) bad "${pin_label}: the node-side /dev/tcp target is not a variable" ;;
  esac
}
probe_pin "kind-doctor"    "$(sed -n '/2. Node egress/,/^fi$/p' "${DOCTOR}")"
probe_pin "bootstrap-kind" "$(sed -n '/SKIP_EGRESS_PREFLIGHT:-0/,/^fi$/p' "${BOOTSTRAP}")"

echo "== 7. digest-pinned refs are not reported missing =="
# Found LIVE on 2026-09-10: three Running pods' images were reported missing by
# a repoTags-only comparison. A pod ref can be name@sha256:..., or
# name:tag@sha256:..., and neither ever appears in repoTags — only repoDigests.
# A guard that cries wolf on a healthy cluster gets ignored, which is the same
# outcome as no guard.
PODS_DIGEST='{"items":[{"spec":{"containers":[
  {"image":"alpine/openssl@sha256:aaaa"},
  {"image":"registry.k8s.io/ingress-nginx/controller:v1.11.8@sha256:bbbb"}],
  "initContainers":[{"image":"alpine/git:v2.45.2@sha256:cccc"}]}}]}'
HELD_DIGEST='{"images":[
  {"repoTags":[],"repoDigests":["alpine/openssl@sha256:aaaa"]},
  {"repoTags":["registry.k8s.io/ingress-nginx/controller:v1.11.8"],"repoDigests":["registry.k8s.io/ingress-nginx/controller@sha256:bbbb"]},
  {"repoTags":[],"repoDigests":["alpine/git@sha256:cccc"]}]}'
make_stubs; scenario digest 1 running 1 "${PODS_DIGEST}" "${HELD_DIGEST}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -eq 0 ] && ok "no false alarm on digest-pinned refs" || bad "false alarm on digest-pinned refs: ${out}"
case "${out}" in *"not yet pulled"*|*"are NOT in the node"*) bad "still reports digest-pinned images as missing";; *) ok "reports none of them missing";; esac

echo "== 8. a digest-pinned ref whose digest is ABSENT is still caught =="
# The inverse of 7, because the fix for a false positive is exactly how a false
# NEGATIVE gets introduced.
HELD_WRONG_DIGEST='{"images":[{"repoTags":[],"repoDigests":["alpine/openssl@sha256:zzzz"]}]}'
PODS_ONE_DIGEST='{"items":[{"spec":{"containers":[{"image":"registry.hugmesh.net/hugmesh/hugmesh-login-ui@sha256:aaaa"}]}}]}'
make_stubs; scenario digestmiss 1 running 1 "${PODS_ONE_DIGEST}" "${HELD_WRONG_DIGEST}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "a missing digest-pinned first-party image is still a FAIL" || bad "went green on a missing digest-pinned image"

echo "== 9. a digest that is only a PREFIX of a held digest does not count =="
# Both of these survived a mutation round on 2026-09-10: dropping the "@" anchor
# on the digest compare, and dropping -x from the name:tag compare. Each turns
# an exact-match into a substring match, and a substring match is how a guard
# quietly starts passing on the wrong image.
PODS_PFX='{"items":[{"spec":{"containers":[{"image":"registry.hugmesh.net/hugmesh/hugmesh-login-ui@sha256:aaaa"}]}}]}'
HELD_PFX='{"images":[{"repoTags":[],"repoDigests":["registry.hugmesh.net/hugmesh/hugmesh-other@sha256:aaaabbbb"]}]}'
make_stubs; scenario digestpfx 1 running 1 "${PODS_PFX}" "${HELD_PFX}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "a prefix-only digest match is still reported missing" || bad "accepted a digest that is merely a prefix of a held one"

echo "== 10. a tag that is a PREFIX of a held tag does not count =="
PODS_TAGPFX='{"items":[{"spec":{"containers":[{"image":"registry.hugmesh.net/hugmesh/hugmesh-login-ui:v1"}]}}]}'
HELD_TAGPFX='{"images":[{"repoTags":["registry.hugmesh.net/hugmesh/hugmesh-login-ui:v10"],"repoDigests":[]}]}'
make_stubs; scenario tagpfx 1 running 1 "${PODS_TAGPFX}" "${HELD_TAGPFX}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok ":v1 is not satisfied by a held :v10" || bad "accepted :v10 as a match for :v1"

echo "== 11. same repo, digest is only a prefix of the held digest =="
# Test 9 used a DIFFERENT repo, so it could not tell an exact compare from a
# substring one. This one shares the repo and differs only in the digest tail,
# which is what actually distinguishes the two.
PODS_SAMEREPO='{"items":[{"spec":{"containers":[{"image":"registry.hugmesh.net/hugmesh/hugmesh-login-ui@sha256:aaaa"}]}}]}'
HELD_SAMEREPO='{"images":[{"repoTags":[],"repoDigests":["registry.hugmesh.net/hugmesh/hugmesh-login-ui@sha256:aaaabbbb"]}]}'
make_stubs; scenario samerepo 1 running 1 "${PODS_SAMEREPO}" "${HELD_SAMEREPO}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "same-repo prefix digest is still missing" || bad "accepted @sha256:aaaabbbb as @sha256:aaaa on the same repo"

echo "== 12. the registry-normalisation fallback is a SUFFIX, not a substring =="
# The fallback exists so a pod saying `alpine:3.20` is satisfied by a held
# `docker.io/library/alpine:3.20`. It must not also accept a held
# `docker.io/library/alpine:3.20-alternate`.
PODS_SUFFIX='{"items":[{"spec":{"containers":[{"image":"alpine:3.20"}]}}]}'
HELD_SUFFIX_OK='{"images":[{"repoTags":["docker.io/library/alpine:3.20"],"repoDigests":[]}]}'
HELD_SUFFIX_BAD='{"images":[{"repoTags":["docker.io/library/alpine:3.20-alternate"],"repoDigests":[]}]}'
make_stubs; scenario sfxok 1 running 1 "${PODS_SUFFIX}" "${HELD_SUFFIX_OK}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -eq 0 ] && ok "docker.io/library/alpine:3.20 satisfies alpine:3.20" || bad "registry normalisation broke: ${out}"
make_stubs; scenario sfxbad 1 running 1 "${PODS_SUFFIX}" "${HELD_SUFFIX_BAD}"
out="$(run_doctor)"; rc=$?
case "${out}" in *"not yet pulled"*|*"NOT in the node"*) ok ":3.20-alternate does not satisfy :3.20";; *) bad "substring fallback accepted :3.20-alternate for :3.20";; esac

echo "== 13. a registry PORT is not mistaken for a tag =="
# `localhost:5001/foo:v1@sha256:...` — the colon after the last slash is the
# tag; the one before it is a port. Splitting on the first colon yields
# `localhost`, and every digest-pinned image on a ported registry is then
# reported missing on a perfectly healthy cluster.
PODS_PORT='{"items":[{"spec":{"containers":[{"image":"localhost:5001/hugmesh/login-ui:v1@sha256:aaaa"}]}}]}'
HELD_PORT='{"images":[{"repoTags":["localhost:5001/hugmesh/login-ui:v1"],"repoDigests":["localhost:5001/hugmesh/login-ui@sha256:aaaa"]}]}'
make_stubs; scenario port 1 running 1 "${PODS_PORT}" "${HELD_PORT}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -eq 0 ] && ok "a ported registry with a digest pin resolves" || bad "registry port treated as a tag: ${out}"

echo "== 14. ported registry, digest-only: the port is not the tag =="
# Test 13 could not tell a correct tag-strip from a broken one, because the
# name:tag branch rescued the broken version. This one removes that rescue:
# repoTags is EMPTY, which is exactly what containerd reports for an image
# pulled by digest. Now the only route to a match is `repo@digest`, and getting
# `repo` wrong (splitting on the first colon, i.e. treating the registry PORT as
# a tag) reports a healthy cluster as broken.
PODS_PORT_D='{"items":[{"spec":{"containers":[{"image":"localhost:5001/hugmesh/login-ui:v1@sha256:aaaa"}]}}]}'
HELD_PORT_D='{"images":[{"repoTags":[],"repoDigests":["localhost:5001/hugmesh/login-ui@sha256:aaaa"]}]}'
make_stubs; scenario portdigest 1 running 1 "${PODS_PORT_D}" "${HELD_PORT_D}"
out="$(run_doctor)"; rc=$?
# Assert on the OUTPUT, not the exit code: a localhost:5001 ref is not
# first-party by the registry.hugmesh.net test, so a miss there is only a WARN
# and rc stays 0. An rc-only assertion cannot see this failure at all — which is
# how the first version of this test passed against a broken tag-strip.
case "${out}" in
  *"localhost:5001/hugmesh/login-ui"*) bad "registry port treated as a tag: the image was reported missing";;
  *) ok "digest-only match on a ported registry resolves";;
esac

echo "== 15. python3 absent — the doctor REFUSES to run instead of going green =="
# The image check — the entire reason #349 exists — is two inline `python3 -c`
# programs, but the preflight used to require only docker and kubectl. Measured
# on the live cluster 2026-09-10: with python3 off PATH the whole of section 3
# vanished and the script printed `kind-doctor: healthy` and exited 0 on a
# cluster holding no first-party image at all. tests/lib/guard-preflight.sh
# states the rule: exiting 0 there "would report a property as verified that was
# never looked at".
NOPY="${WORK}/nopy"; mkdir -p "${NOPY}"
for t in bash sh mktemp grep awk sed tr cat wc rm getent env timeout head sort; do
  src="$(command -v "${t}" 2>/dev/null)" || continue
  [ -n "${src}" ] && ln -sf "${src}" "${NOPY}/${t}"
done
make_stubs; scenario nopy 1 running 1 "${PODS_ONE_APP}" "${HELD_NONE}"
out="$(run_doctor_path "${BIN}:${NOPY}")"; rc=$?
[ "${rc}" -ne 0 ] && ok "exits non-zero with python3 absent" || bad "reported success with python3 absent (rc=${rc})"
case "${out}" in *healthy*) bad "printed 'healthy' with python3 absent";; *) ok "never prints 'healthy'";; esac
# Assert the PREFLIGHT caught it, not merely that something downstream fell
# over. The downstream handling also fails closed — that is deliberate depth —
# but it means an rc-only assertion cannot tell whether the preflight still
# lists python3 at all. Removing python3 from that loop SURVIVED an rc-only
# version of this test.
case "${out}" in
  *"missing required tool: python3"*) ok "the tool preflight names python3 and refuses to start";;
  *) bad "python3 is not in the tool preflight — the failure came from further downstream: ${out}";;
esac
[ "${rc}" -eq 2 ] && ok "exits 2, the preflight's own code" || bad "exit ${rc} is not the preflight's code (2)"

echo "== 16. kubectl cannot list pods as JSON — that is a FAILURE, not a shrug =="
# The old code read a failed `kubectl get pods -A -o json` as an empty wanted
# set and printed "no pods found — nothing to check yet", then exited 0. An API
# server that has stopped answering is the ordinary way a kind cluster dies.
make_stubs; scenario podsjsonfail 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
knob pods_json_rc 1
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "exits non-zero when the pod list cannot be read" || bad "reported healthy when the pod list could not be read"
case "${out}" in *"NOT checked"*) ok "says out loud that the image check did not run";; *) bad "did not say the check was skipped: ${out}";; esac
case "${out}" in *"no pods found"*) bad "still degrades to 'no pods found — nothing to check yet'";; *) ok "does not pretend there are simply no pods";; esac

echo "== 17. the pod list is unparseable but kubectl exits 0 =="
make_stubs; scenario podsjunk 1 running 1 '{"items":[{"spec":{"containers"' "${HELD_IT}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "truncated JSON with rc=0 is still a failure" || bad "went green on truncated pod JSON"
# And assert it is reported AS a parse failure. `except Exception: sys.exit(0)`
# also produces a non-zero run — via the empty-wanted branch below — so an
# rc-only assertion cannot tell the two apart, and restoring that `exit(0)`
# SURVIVED an rc-only version of this test. The distinction matters to the
# reader: "I could not read your pod list" and "your cluster is running
# nothing" call for different next steps.
case "${out}" in
  *"could not read image references out of the pod list"*) ok "reports it as a parse failure, not as an empty cluster";;
  *) bad "an unparseable pod list is not reported as one: ${out}";;
esac
make_stubs; scenario podserr 1 running 1 'error: the server doesn'"'"'t have a resource type "pods"' "${HELD_IT}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "an error string printed with rc=0 is still a failure" || bad "went green on an error string in place of the pod list"

echo "== 18. crictl will not run — say THAT, do not blame make kind-images =="
# An empty held set is far more often "crictl could not run" than "the node
# holds nothing", and the two used to produce identical output while deserving
# completely different instructions.
make_stubs; scenario crictlfail 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
knob crictl_rc 1
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "exits non-zero when the node image store cannot be read" || bad "reported healthy when crictl could not run"
case "${out}" in *crictl*) ok "names crictl";; *) bad "does not name crictl: ${out}";; esac
case "${out}" in *"make kind-images"*) bad "misdiagnoses a dead crictl as a missing side-load";; *) ok "does not give the side-load remediation for a tooling failure";; esac

echo "== 19. a reachable API server with ZERO pods is not health =="
# Maximally broken: the API answers and nothing at all is scheduled, kube-system
# included. The old section 4 printed "all pods Running or Completed" here.
make_stubs; scenario nopods 1 running 1 '{"items":[]}' "${HELD_IT}"

: > "${STUB_DIR}/pods.txt"
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "an empty cluster is a failure" || bad "reported healthy on a cluster running nothing"
case "${out}" in *"all pods Running"*) bad "claimed 'all pods Running' about zero pods";; *) ok "does not claim all pods are Running";; esac
# Section 4 has its OWN zero-pods verdict, and the case above cannot reach it:
# section 3 fails first on the same emptiness, so downgrading section 4's
# verdict to a warning SURVIVES. Isolate it — a populated section 3, an empty
# section 4 — so the branch is asserted on directly.
make_stubs; scenario nopods4 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
: > "${STUB_DIR}/pods.txt"
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "section 4 alone fails on an empty pod table" || bad "section 4 called an empty pod table healthy"
case "${out}" in *"all pods Running"*) bad "section 4 claimed 'all pods Running' about zero pods";; *) ok "section 4 does not claim all pods are Running";; esac

echo "== 20. kubectl cannot list pods for section 4 — pod health is a FAILURE =="
make_stubs; scenario podstxtfail 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
knob pods_txt_rc 1
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "exits non-zero when pod health cannot be read" || bad "reported healthy when pod health could not be read"
case "${out}" in *"pod health was NOT checked"*) ok "says pod health did not run";; *) bad "silently skipped section 4: ${out}";; esac

echo "== 21. a held image of the SAME LENGTH does not satisfy an absent one =="
# THE blocker of this round, and it fired on the operator's live cluster.
# The registry-normalisation fallback compared
#     index($0, want) == length($0) - length(want) + 1
# with no `index() > 0` guard. awk's index() returns 0 when the needle is
# ABSENT, and when the held line is exactly length(want)-1 characters long the
# right-hand side is ALSO 0 — so `0 == 0` declared any unrelated image of the
# right LENGTH a match. Replaying #349 against the live cluster, 4 of the 10
# absent first-party images went silently green, rescued by pure length twins
# (local-path-provisioner:v0.0.30, kube-controller-manager-amd64:v1.34.0, ...).
LEN_WANT='registry.hugmesh.net/hugmesh/aaa:main'
LEN_HELD='docker.io/library/'
while [ $(( ${#LEN_HELD} + 4 )) -lt ${#LEN_WANT} ]; do LEN_HELD="${LEN_HELD}z"; done
LEN_HELD="${LEN_HELD}:1.0"
if [ ${#LEN_HELD} -eq ${#LEN_WANT} ]; then
  ok "the trap is armed: held and wanted refs are both ${#LEN_WANT} characters"
else
  bad "test is not exercising the trap: ${#LEN_HELD} vs ${#LEN_WANT} characters"
fi
PODS_LEN="{\"items\":[{\"spec\":{\"containers\":[{\"image\":\"${LEN_WANT}\"}]}}]}"
HELD_LEN="{\"images\":[{\"repoTags\":[\"${LEN_HELD}\"],\"repoDigests\":[]}]}"
make_stubs; scenario lentwin 1 running 1 "${PODS_LEN}" "${HELD_LEN}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "an absent first-party image is still reported missing" || bad "a same-length unrelated image satisfied an absent one"
case "${out}" in *"${LEN_WANT}"*) ok "names the image that is actually missing";; *) bad "does not name the missing image";; esac

echo "== 22. the normalisation fallback matches on a SLASH boundary, not any tail =="
# `want="/${candidate}"` is what makes the suffix compare land on a path
# segment. Dropping that leading slash survived the previous round of this
# suite, because test 12's negative case differs at the TAIL and so cannot tell
# a slash-anchored suffix from a bare one.
PODS_SLASH='{"items":[{"spec":{"containers":[{"image":"alpine:3.20"}]}}]}'
HELD_SLASH='{"images":[{"repoTags":["docker.io/library/notalpine:3.20"],"repoDigests":[]}]}'
make_stubs; scenario slashbound 1 running 1 "${PODS_SLASH}" "${HELD_SLASH}"
out="$(run_doctor)"; rc=$?
case "${out}" in
  *"not yet pulled"*|*"NOT in the node"*) ok "notalpine:3.20 does not satisfy alpine:3.20";; 
  *) bad "the fallback matched across a name boundary: notalpine:3.20 accepted for alpine:3.20";;
esac

echo "== 23. a digest-pinned ref is NOT satisfied by the tag alone =="
# For `repo:tag@sha256:X` the node can hold `repo:tag` pointing at a DIFFERENT
# digest. The kubelet needs the exact digest and ImagePullBackOffs; a tag-only
# rescue branch called it present. Deleting that branch costs nothing, because
# for a ref with no digest it was character-for-character the exact compare
# above it.
PODS_DIGTAG='{"items":[{"spec":{"containers":[{"image":"registry.hugmesh.net/hugmesh/hugmesh-login-ui:main@sha256:aaaa"}]}}]}'
HELD_DIGTAG='{"images":[{"repoTags":["registry.hugmesh.net/hugmesh/hugmesh-login-ui:main"],"repoDigests":["registry.hugmesh.net/hugmesh/hugmesh-login-ui@sha256:zzzz"]}]}'
make_stubs; scenario digtag 1 running 1 "${PODS_DIGTAG}" "${HELD_DIGTAG}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -ne 0 ] && ok "the right tag at the WRONG digest is still missing" || bad "a digest pin was satisfied by the bare tag"

echo "== 24. an untagged ref is satisfied by the held :latest =="
# The repo carries untagged refs (local-path's `image: busybox`, owncast, tube,
# edge-ai). containerd always records them explicitly as :latest, so a doctor
# that does not expand the implicit tag cries wolf on a healthy cluster.
PODS_LATEST='{"items":[{"spec":{"containers":[{"image":"registry.hugmesh.net/hugmesh/hugmesh-login-ui"}]}}]}'
HELD_LATEST='{"images":[{"repoTags":["registry.hugmesh.net/hugmesh/hugmesh-login-ui:latest"],"repoDigests":[]}]}'
make_stubs; scenario latest 1 running 1 "${PODS_LATEST}" "${HELD_LATEST}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -eq 0 ] && ok "an untagged ref resolves against the held :latest" || bad "false alarm on an implicit :latest: ${out}"

echo "== 25. a Running pod that never becomes READY is not healthy =="
# Section 4 read only STATUS ($4). A mesh whose services sit at 0/1 Running
# serves nothing, which is exactly the question this script's header claims to
# answer. Completed pods are legitimately 0/1 and must NOT be flagged.
make_stubs; scenario notready 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
knob pods.txt 'kube-system   coredns-aaa      1/1   Running     0   2d
hugmesh       login-ui-bbb     0/1   Running     44  2d
hugmesh       seed-job-ccc     0/1   Completed   0   2d
'
out="$(run_doctor)"; rc=$?
case "${out}" in *login-ui-bbb*) ok "names the pod that is Running but not ready";; *) bad "0/1 Running went unreported: ${out}";; esac
case "${out}" in *"all pods Running and ready"*) bad "claimed every pod ready while one is 0/1";; *) ok "does not claim every pod is ready";; esac
case "${out}" in *seed-job-ccc*) bad "flagged a Completed pod for being 0/1";; *) ok "a Completed 0/1 pod is not flagged";; esac

echo "== 26. bootstrap-kind.sh's egress preflight, EXTRACTED and EXECUTED =="
# The half of this change that can HARD ABORT a bring-up had no coverage at all:
# `grep -rn SKIP_EGRESS_PREFLIGHT .` returned two hits, both inside
# bootstrap-kind.sh itself. Flipping its `!=` to `=` makes the preflight
# default-OFF, and by construction no suite in the repo could notice, because
# none executed the block.
EGRESS_BLOCK="${WORK}/egress-block.sh"
{
  echo 'set -uo pipefail'
  echo 'CLUSTER_NAME=stub'
  echo 'log() { printf "LOG: %s\n" "$*"; }'
  sed -n '/SKIP_EGRESS_PREFLIGHT:-0/,/^fi$/p' "${BOOTSTRAP}"
  echo 'echo REACHED_END'
} > "${EGRESS_BLOCK}"
eb_lines="$(grep -ac . "${EGRESS_BLOCK}")"
if [ "${eb_lines}" -ge 15 ]; then
  ok "extracted the bootstrap egress preflight (${eb_lines} lines)"
else
  bad "could not extract the bootstrap egress preflight (${eb_lines} lines)"
fi
EGBIN="${WORK}/egbin"; mkdir -p "${EGBIN}"
cat > "${EGBIN}/docker" <<'EGDOCKER'
#!/usr/bin/env bash
[ "${STUB_EGRESS:-0}" = "1" ] && exit 0
exit 1
EGDOCKER
chmod +x "${EGBIN}/docker"

out="$(PATH="${EGBIN}:${PATH}" STUB_EGRESS=1 bash "${EGRESS_BLOCK}" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "preflight passes when the node has egress" || bad "preflight aborted a healthy host (rc=${rc}): ${out}"
case "${out}" in *REACHED_END*) ok "bring-up continues past a passing preflight";; *) bad "block did not run to completion";; esac
case "${out}" in *"LOG: Egress preflight"*) ok "logs the passing preflight";; *) bad "no log line on the happy path";; esac

out="$(PATH="${EGBIN}:${PATH}" STUB_EGRESS=0 bash "${EGRESS_BLOCK}" 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && ok "preflight aborts on a host with no egress" || bad "preflight let a dead host through (rc=${rc})"
case "${out}" in *REACHED_END*) bad "bring-up continued past a FAILED preflight";; *) ok "nothing after a failed preflight runs";; esac
case "${out}" in *"nft list tables"*) ok "names the netfilter check";; *) bad "no nft guidance";; esac
case "${out}" in *"make kind-down && make kind-up"*) ok "tells you to REBUILD, not merely re-run";; *) bad "remediation dead-ends: 'make kind-up' alone reuses a stopped cluster and hangs";; esac
case "${out}" in *SKIP_EGRESS_PREFLIGHT=1*) ok "names the escape hatch at the moment you need it";; *) bad "does not name the escape hatch";; esac

out="$(PATH="${EGBIN}:${PATH}" STUB_EGRESS=0 SKIP_EGRESS_PREFLIGHT=1 bash "${EGRESS_BLOCK}" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "SKIP_EGRESS_PREFLIGHT=1 bypasses a failing probe" || bad "the escape hatch does not work (rc=${rc}): ${out}"
case "${out}" in *REACHED_END*) ok "the bypass continues the bring-up";; *) bad "the bypass did not continue";; esac

echo "== 27. the probe target list survives total resolution failure =="
# Tier 1 of the probe list resolves registry names ON THE HOST. bootstrap-kind.sh
# runs under `set -euo pipefail`, and a getent that cannot resolve exits 2 —
# which pipefail promotes to the pipeline's status. Without an explicit guard the
# target function dies at the FIRST unresolvable name and never reaches the
# anycast fallback, so a host that merely has no DNS aborts its bring-up with no
# message at all. Measured: the same function called outside a `for` word list
# exits 2 and prints nothing.
#
# This is exactly the class this PR exists to kill — a preflight that fails on a
# host whose actual problem is not the one being probed.
for tgt_src in "${DOCTOR}" "${BOOTSTRAP}"; do
  tgt_label="$(basename "${tgt_src}")"
  TGT_BLOCK="${WORK}/targets-${tgt_label}.sh"
  # The two files spell the function differently (the bootstrap prefixes its
  # locals with _ to avoid colliding with the 1800 lines around it), and the
  # bootstrap's copy is indented, so find the name and its indentation rather
  # than assuming either.
  tgt_fn="$(grep -aoE '_?egress_targets\(\) \{' "${tgt_src}" | head -1 | sed 's/() {//')"
  if [ -z "${tgt_fn}" ]; then
    bad "${tgt_label}: no egress target function found at all"
    continue
  fi
  # Call it BARE, with its output redirected to a file. That is the sensitive
  # form and the whole reason this scenario exists: at the real call site the
  # function is a `for` word list, `for _hp in $(_egress_targets)`, and bash
  # suppresses errexit for a command substitution in that position — so both
  # files survive a getent failure there whether or not the pipeline is
  # guarded, and a test written against `$(...)` cannot see the guard at all.
  # Measured: a BARE call to the unguarded function exits 2 and emits nothing.
  # Pinning the bare form pins the property the code claims, which is that this
  # function is safe to call from anywhere, not merely from where it happens to
  # be called today.
  TGT_OUT="${WORK}/targets-${tgt_label}.out"
  {
    echo 'set -euo pipefail'
    sed -n "/^ *${tgt_fn}() {\$/,/^ *}\$/p" "${tgt_src}"
    echo "${tgt_fn} > \"\$1\""
  } > "${TGT_BLOCK}"
  NORES="${WORK}/nores-${tgt_label}"; mkdir -p "${NORES}"
  printf '#!/usr/bin/env bash\nexit 2\n' > "${NORES}/getent"; chmod +x "${NORES}/getent"
  : > "${TGT_OUT}"
  out="$(PATH="${NORES}:${PATH}" bash "${TGT_BLOCK}" "${TGT_OUT}" 2>&1)"; rc=$?
  tgt_n="$(grep -ac . "${TGT_OUT}" 2>/dev/null || true)"
  [ -n "${tgt_n}" ] || tgt_n=0
  if [ "${rc}" -eq 0 ]; then
    ok "${tgt_label}: the target function survives a getent that resolves nothing"
  else
    bad "${tgt_label}: the target function died (rc=${rc}) when resolution failed — a host with no DNS would abort its bring-up with no message: ${out}"
  fi
  if [ "${tgt_n}" -gt 0 ]; then
    ok "${tgt_label}: falls back to ${tgt_n} literal target(s)"
  else
    bad "${tgt_label}: no probe targets at all when resolution fails"
  fi
done

echo
echo "kind-doctor: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ] || exit 1
