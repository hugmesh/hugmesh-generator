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
#
# ROUND THREE (hugmesh-generator#355, 2026-09-17). Mutation-testing during the
# #353 settle found TWO more survivors, and both are #349's own failure mode —
# a suite green over a surface it never measures:
#
#   * `grep -n "Synced\|Healthy\|argocd\|ArgoCD"` over this file returned ZERO
#     hits. Section 5 of the doctor is the check that surfaces
#     external-secrets-config (#352) and harbor OutOfSync (#354) at all, and
#     neutering its filter left this suite 71/71 green. Every scenario before
#     this round fed the kubectl stub `get crd applications -> exit 1`, so
#     section 5 took its "no ArgoCD Application CRD" branch 27 times and was
#     asserted on zero times — the same unexercised-path shape round two found
#     in section 4. Sections 28a-28f now drive all five branches.
#   * The `make kind-down && make kind-up` assertion at what was line 537 runs
#     on the block EXTRACTED from bootstrap-kind.sh, not on kind-doctor's own
#     copy of the same guidance. The doctor's remedy was unpinned; rewriting it
#     to the dead-end form survived. Scenario 2 now asserts on the DOCTOR's
#     output.
#
# Section 29 is a MUTATION BATTERY inside the suite, so those two never go
# unmeasured again. It mutates COPIES (scripts/kind-doctor.sh is never written
# to — its sha256 is unchanged by a run), verifies each sed actually changed the
# copy, and requires each assertion to hold on the PRISTINE doctor before the
# mutant's verdict is believed. Four mutations, 4 killed:
#
#   355-argocd-filter ....... the #355 survivor, verbatim
#   355-rebuild-prose ....... the #355 survivor, verbatim
#   remedy-drops-kind-down .. the down+up pair deleted outright
#   argocd-warn-deleted ..... section 5's warning reworded to say nothing
#
# Note why 28b's fixture is OutOfSync-but-HEALTHY: the #355 mutation
# `0 && $3 != "Synced" || $4 != "Healthy"` reduces to `$4 != "Healthy"`, so it
# still catches a Degraded row. A battery run against a Degraded fixture would
# report "killed" and prove nothing.
#
# AND A THIRD, found by taking #355's closing hint ("worth checking the other
# kind-doctor sections for the same shape"). Section 2's STALE-RESOLVER check
# (kind-doctor.sh:148-160) was dead code to this suite for the same reason
# section 5 was: the default resolv fixture carries no `# ExtServers:` line, so
# `if [ -n "${ext_line}" ]` was false in all 27 scenarios. MEASURED the way #355
# measured its two — with the warn deleted, the suite printed the same
# 79 passed / 11 failed as the pristine doctor under the same harness, a
# difference of exactly ZERO assertions. Sections 30 and 31 close it, and 31
# carries BOTH directions: the warning deleted, and the membership test neutered
# so an upstream the host DOES use is reported stale.
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
  # ArgoCD (kind-doctor section 5). Two knobs, because the doctor asks two
  # separate questions and each has its own dead branch: does the CRD exist,
  # and what does the Application list say.
  *"get crd applications"*) exit "$(cat "${STATE}/argocd_crd_rc")" ;;
  *"get applications -A --no-headers"*)
    [ "$(cat "${STATE}/apps_rc")" = "0" ] || exit 1
    cat "${STATE}/apps.txt"; exit 0 ;;
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
  # ArgoCD defaults reproduce the behaviour every scenario before #355 got: no
  # Application CRD, so section 5 warns and moves on. Scenarios 28a-28e flip
  # them. rc=1 here is "the CRD does not exist", which is what `kubectl get crd`
  # answers on a profile that never deployed ArgoCD.
  printf '1' > "${STUB_DIR}/argocd_crd_rc"
  printf '0' > "${STUB_DIR}/apps_rc"
  : > "${STUB_DIR}/apps.txt"
  export STUB_DIR
}

# Override one knob after scenario() has laid down the defaults.
knob() { printf '%s' "$2" > "${STUB_DIR}/$1"; }

# The Application table needs its own writer, not knob(): kind-doctor counts the
# rows with `wc -l`, so a fixture written WITHOUT a trailing newline reports one
# row fewer than it holds and the count assertions fail on a correct doctor.
# An empty table must be a genuinely EMPTY file — `printf '%s\n' ''` writes one
# newline, which `wc -l` reports as one Application that does not exist.
set_apps() {
  if [ -z "$1" ]; then : > "${STUB_DIR}/apps.txt"
  else printf '%s\n' "$1" > "${STUB_DIR}/apps.txt"; fi
}

# The node's /etc/resolv.conf, as `docker exec NODE cat` would print it.
set_resolv() { printf '%s\n' "$1" > "${STUB_DIR}/resolv"; }

PODS_ONE_APP='{"items":[{"spec":{"containers":[{"image":"registry.hugmesh.net/hugmesh/hugmesh-login-ui:main"}]}}]}'
HELD_NONE='{"images":[]}'
HELD_IT='{"images":[{"repoTags":["registry.hugmesh.net/hugmesh/hugmesh-login-ui:main"]}]}'

run_doctor() { PATH="${BIN}:${PATH}" KIND_CLUSTER_NAME=stub bash "${DOCTOR}" 2>&1; }
# Same, against an arbitrary copy of the doctor — the mutation battery (section
# 29) runs mutated COPIES so the tracked file is never written to.
run_doctor_file() { PATH="${BIN}:${PATH}" KIND_CLUSTER_NAME=stub bash "$1" 2>&1; }
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
# #355 gap 2: the REBUILD assertion in section 26 runs on the block EXTRACTED
# from bootstrap-kind.sh, not on kind-doctor's own copy of the same guidance.
# kind-doctor's remedy was therefore unpinned, and rewriting it to the dead-end
# form left the suite 71/71. These three assert on THIS output — the doctor's.
case "${out}" in *"make kind-down && make kind-up"*) ok "kind-doctor's own remedy names the REBUILD pair";; *) bad "kind-doctor's remedy does not name 'make kind-down && make kind-up' — 'make kind-up' alone reuses a stopped cluster and hangs";; esac
case "${out}" in *REBUILD*) ok "kind-doctor's own remedy says REBUILD, not merely re-run";; *) bad "kind-doctor's remedy no longer says REBUILD — the word is what stops a reader running 'make kind-up' and waiting on an API server that is never coming back";; esac
case "${out}" in *"alone is not enough"*) ok "kind-doctor explains WHY re-running is not enough";; *) bad "kind-doctor dropped the explanation of the dead end";; esac

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

echo "== 28. section 5 (ArgoCD) actually measures something =="
# hugmesh-generator#355: `grep -n "Synced\|Healthy\|argocd\|ArgoCD"` over this
# file returned ZERO hits. Section 5 is the check that surfaces
# external-secrets-config (#352) and harbor OutOfSync (#354) at all, and
# neutering its filter so every Application reports healthy left the suite
# 71/71 green. Every branch of section 5 is exercised below.
#
# The column order is what `kubectl get applications -A --no-headers` emits:
#   $1 NAMESPACE   $2 NAME   $3 SYNC-STATUS   $4 HEALTH-STATUS
# kind-doctor:373 keys on $3/$4 and names $2.
APPS_ALL_GOOD='argocd  platform       Synced     Healthy
argocd  monitoring     Synced     Healthy'
# OutOfSync-but-Healthy is the case that kills the #355 mutation. That mutation
# (`0 && $3 != "Synced" || $4 != "Healthy"`) still catches an unhealthy app, so
# a scenario with only a Degraded row would report "caught" and prove nothing.
APPS_OUT_OF_SYNC='argocd  platform       Synced     Healthy
argocd  harbor         OutOfSync  Healthy'
APPS_DEGRADED='argocd  platform                 Synced  Healthy
argocd  external-secrets-config  Synced  Degraded'

echo "-- 28a. all Applications Synced+Healthy --"
make_stubs; scenario argo_ok 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
knob argocd_crd_rc 0; set_apps "${APPS_ALL_GOOD}"
out="$(run_doctor)"; rc=$?
[ "${rc}" -eq 0 ] && ok "healthy GitOps does not fail the doctor" || bad "false alarm on all-Synced+Healthy (rc=${rc}): ${out}"
case "${out}" in *"2 Application(s), all Synced and Healthy"*) ok "reports the Application COUNT, so an empty list cannot read as health";; *) bad "does not report 'N Application(s), all Synced and Healthy'";; esac

echo "-- 28b. an OutOfSync Application is reported, by name --"
# THE #355 REGRESSION CASE. Nothing here asserted on sync state, so a filter
# that only ever looked at health was indistinguishable from the real one.
make_stubs; scenario argo_oos 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
knob argocd_crd_rc 0; set_apps "${APPS_OUT_OF_SYNC}"
out="$(run_doctor)"
case "${out}" in *"not Synced+Healthy"*) ok "warns that an Application is not Synced+Healthy";; *) bad "an OutOfSync Application was NOT reported — this is #355's survivor";; esac
case "${out}" in *harbor*) ok "names the offending Application (harbor)";; *) bad "does not NAME the Application — 'something is wrong' is not actionable on a 20-app cluster";; esac
case "${out}" in *"sync=OutOfSync"*) ok "prints the sync status it objected to";; *) bad "does not print the sync status";; esac
case "${out}" in *"1 of 2 Application(s)"*) ok "counts offenders against the total";; *) bad "does not report 'n of N'";; esac

echo "-- 28c. a Degraded Application is reported, by name --"
make_stubs; scenario argo_deg 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
knob argocd_crd_rc 0; set_apps "${APPS_DEGRADED}"
out="$(run_doctor)"
case "${out}" in *"not Synced+Healthy"*) ok "warns on a Degraded Application";; *) bad "a Degraded Application was NOT reported";; esac
case "${out}" in *external-secrets-config*) ok "names the offending Application (external-secrets-config)";; *) bad "does not name the Degraded Application";; esac
case "${out}" in *"health=Degraded"*) ok "prints the health status it objected to";; *) bad "does not print the health status";; esac

echo "-- 28d. the CRD exists but nothing is registered --"
# A real state after a failed bootstrap: ArgoCD is installed, the AppProject
# never synced, and `all Synced and Healthy` over zero rows would be the most
# misleading line the doctor could print.
make_stubs; scenario argo_none 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
knob argocd_crd_rc 0; set_apps ''
out="$(run_doctor)"
case "${out}" in *"no Applications are registered"*) ok "zero Applications is a WARNING, never 'all Synced and Healthy'";; *) bad "zero registered Applications did not warn: ${out}";; esac
case "${out}" in *"all Synced and Healthy"*) bad "an EMPTY Application list printed the all-healthy line";; *) ok "the all-healthy line is not printed over an empty list";; esac

echo "-- 28e. no ArgoCD CRD at all --"
make_stubs; scenario argo_nocrd 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
out="$(run_doctor)"
case "${out}" in *"no ArgoCD Application CRD"*) ok "a profile without ArgoCD says so rather than claiming health";; *) bad "no CRD did not produce the documented warning: ${out}";; esac

echo "-- 28f. the API server is unreachable --"
# The section must not claim anything about GitOps it could not measure. This
# is the fail-closed shape sections 15-20 pin elsewhere.
make_stubs; scenario argo_noapi 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
knob nodes_rc 1
out="$(run_doctor)"
case "${out}" in *"ArgoCD was NOT checked"*) ok "an unreachable API server makes section 5 say it checked NOTHING";; *) bad "section 5 did not admit it could not run";; esac

echo "== 29. mutation battery: the two #355 survivors must now be killed =="
# Every assertion above is a claim about a guard. A guard is only worth what a
# planted defect proves, so both mutations #355 recorded as SURVIVORS are
# replayed here against a COPY (the tracked file is never written to), and each
# is verified to have actually changed the copy before its verdict is believed.
# A sed that silently matched nothing is the classic way a battery reports
# strength it does not have.
MUTDIR="${WORK}/mutants"; mkdir -p "${MUTDIR}"

# $1 label  $2 sed expression  $3 scenario setup fn  $4 assertion fn
# The assertion fn must return 0 when the guard is SATISFIED. It is run against
# the pristine doctor (must return 0) and the mutant (must return non-zero).
mutation() {
  local m_label
  local m_sed
  local m_setup
  local m_assert
  m_label="$1"; m_sed="$2"; m_setup="$3"; m_assert="$4"
  local m_file="${MUTDIR}/${m_label}.sh"
  cp "${DOCTOR}" "${m_file}"
  sed -i "${m_sed}" "${m_file}"
  if cmp -s "${m_file}" "${DOCTOR}"; then
    bad "M:${m_label} — the sed changed NOTHING (kind-doctor.sh drifted?); this leg proved nothing"
    return
  fi
  "${m_setup}"
  local m_base
  m_base="$(run_doctor)"
  if ! "${m_assert}" "${m_base}"; then
    bad "M:${m_label} — the assertion does not even hold on the PRISTINE doctor; the battery is measuring itself, not the guard"
    return
  fi
  local m_out
  m_out="$(run_doctor_file "${m_file}")"
  if "${m_assert}" "${m_out}"; then
    bad "M:${m_label} — SURVIVED. The guard above is blind to it, exactly as #355 measured."
  else
    ok "M:${m_label} — killed (the pristine doctor satisfies the assertion, the mutant does not)"
  fi
}

setup_oos()  { make_stubs; scenario mut_oos 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
               knob argocd_crd_rc 0; set_apps "${APPS_OUT_OF_SYNC}"; }
assert_oos() { case "$1" in *harbor*"sync=OutOfSync"*) return 0;; esac; return 1; }

setup_egress()  { make_stubs; scenario mut_egress 1 running 0 "${PODS_ONE_APP}" "${HELD_IT}"; }
assert_rebuild(){ case "$1" in *"make kind-down && make kind-up"*) : ;; *) return 1;; esac
                  case "$1" in *REBUILD*) return 0;; esac; return 1; }

# #355 mutation 1, verbatim: neuter the unhealthy-app filter so a not-Synced
# Application is reported healthy. `0 && A || B` is `B`, so it still catches a
# Degraded row — which is why 28b uses an OutOfSync-but-Healthy fixture.
mutation "355-argocd-filter" \
  "s/awk '\\\$3 != \"Synced\" || \\\$4 != \"Healthy\"/awk '0 \&\& \\\$3 != \"Synced\" || \\\$4 != \"Healthy\"/" \
  setup_oos assert_oos

# #355 mutation 2, verbatim: rewrite kind-doctor's netfilter remedy to the
# dead-end form. `make kind-up` alone reuses a stopped cluster and hangs.
mutation "355-rebuild-prose" \
  "s/then REBUILD:/then re-run:/" \
  setup_egress assert_rebuild

# A stronger third, because the two above are minimal demonstrators: delete the
# down+up pair outright. Nothing before this round would have noticed.
mutation "remedy-drops-kind-down" \
  "s/make kind-down \&\& make kind-up/make kind-up/" \
  setup_egress assert_rebuild

# And the ArgoCD section deleted wholesale — the shape #349 is named for.
setup_del()  { setup_oos; }
assert_del() { case "$1" in *"not Synced+Healthy"*) return 0;; esac; return 1; }
mutation "argocd-warn-deleted" \
  "s/not Synced+Healthy/Applications checked/" \
  setup_del assert_del

echo "== 30. section 2's stale-resolver check (the same #355 shape, found by taking the hint) =="
# #355 closes with "worth checking the other kind-doctor sections for the same
# shape". This is one. kind-doctor.sh:148-160 reads the node's /etc/resolv.conf,
# pulls docker's `# ExtServers: [host(...)]` annotation out of it and warns when
# the node is still forwarding DNS to a resolver the HOST no longer uses —
# captured at container CREATE time, so a long-lived node can be pointing at a
# VPN resolver that died days ago.
#
# MEASURED, exactly as #355 measured its two: the default resolv fixture every
# scenario got carries no ExtServers line, so `if [ -n "${ext_line}" ]` was
# false in all 27 scenarios and the whole block was dead code to this suite.
# Deleting the warning outright changed the result by ZERO assertions.
#
# NOTE ON LEG B: kind-doctor reads the HOST's /etc/resolv.conf directly, with no
# indirection to stub, so the matching case has to be built from whatever this
# machine actually uses. That is stated rather than hidden, and a machine with
# no nameserver at all is reported as a leg that could not run — never as a pass.
RESOLV_NO_EXT='# Generated by Docker Engine.
nameserver 127.0.0.11
options ndots:0'
# 192.0.2.0/24 is TEST-NET-1 (RFC 5737): reserved for documentation and never a
# real resolver, so "this is not one of the host's nameservers" is true on every
# machine this can run on.
RESOLV_STALE='# Generated by Docker Engine.
nameserver 127.0.0.11
options ndots:0

# Based on host file: '"'"'/etc/resolv.conf'"'"' (internal resolver)
# ExtServers: [host(192.0.2.123)]
# Overrides: []'

echo "-- 30a. no ExtServers annotation: neither verdict is printed --"
# The positive control for the two below. Without it, an UNCONDITIONAL ok line
# would satisfy leg B and an unconditional warn would satisfy leg A.
make_stubs; scenario resolv_none 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
set_resolv "${RESOLV_NO_EXT}"
out="$(run_doctor)"
case "${out}" in *"NOT in the host's current resolv.conf"*) bad "warned about a stale resolver with no ExtServers annotation to read";; *) ok "no ExtServers annotation, no stale warning";; esac
case "${out}" in *"match the host's current resolvers"*) bad "claimed the upstreams match when it read no upstreams at all";; *) ok "no ExtServers annotation, no all-clear claim either";; esac

echo "-- 30b. a stale upstream is reported, by address --"
make_stubs; scenario resolv_stale 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
set_resolv "${RESOLV_STALE}"
out="$(run_doctor)"
case "${out}" in *"NOT in the host's current resolv.conf"*) ok "warns when the node forwards to a resolver the host no longer uses";; *) bad "a stale DNS upstream was NOT reported — this is the #355 shape in section 2";; esac
case "${out}" in *192.0.2.123*) ok "names the stale resolver (192.0.2.123)";; *) bad "does not NAME the stale resolver";; esac
case "${out}" in *"container was created"*) ok "explains WHY it is stale (captured at container create time)";; *) bad "does not explain that the value was captured at create time";; esac

echo "-- 30c. upstreams that DO match the host are not reported --"
HOST_NS="$(grep -a '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | head -n1)"
if [ -z "${HOST_NS}" ]; then
  bad "this machine's /etc/resolv.conf names no nameserver, so the matching leg could NOT run — it is not being counted as a pass"
else
  make_stubs; scenario resolv_match 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
  set_resolv "# Generated by Docker Engine.
nameserver 127.0.0.11

# ExtServers: [host(${HOST_NS})]"
  out="$(run_doctor)"
  case "${out}" in *"NOT in the host's current resolv.conf"*) bad "cried wolf on ${HOST_NS}, which IS one of this host's resolvers";; *) ok "an upstream matching the host (${HOST_NS}) is not reported stale";; esac
  case "${out}" in *"match the host's current resolvers"*) ok "says so explicitly when they match";; *) bad "no all-clear line when the upstreams match: ${out}";; esac
fi

echo "== 31. mutation battery for section 2's resolver check =="
setup_resolv_stale() { make_stubs; scenario mut_rstale 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
                       set_resolv "${RESOLV_STALE}"; }
assert_rstale()      { case "$1" in *192.0.2.123*"NOT in the host's current resolv.conf"*) return 0;; esac
                       case "$1" in *"NOT in the host's current resolv.conf"*192.0.2.123*) return 0;; esac; return 1; }

# THE SURVIVOR, measured on this tree before this section existed: with the warn
# removed the suite printed the same 79 passed / 11 failed as the pristine doctor
# under the same relocated harness — a difference of exactly zero assertions.
mutation "resolv-stale-warning-deleted" \
  's/stale=1; warn "node forwards DNS/stale=0; : "node forwards DNS/' \
  setup_resolv_stale assert_rstale

# The other direction, which only leg 30c can see: neuter the membership test so
# an upstream the host DOES use is reported stale. A guard that flags everything
# is as useless as one that flags nothing, and gets silenced the same way.
if [ -n "${HOST_NS:-}" ]; then
  setup_resolv_match() { make_stubs; scenario mut_rmatch 1 running 1 "${PODS_ONE_APP}" "${HELD_IT}"
                         set_resolv "# Generated by Docker Engine.
nameserver 127.0.0.11

# ExtServers: [host(${HOST_NS})]"; }
  assert_rmatch()      { case "$1" in *"NOT in the host's current resolv.conf"*) return 1;; esac
                         case "$1" in *"match the host's current resolvers"*) return 0;; esac; return 1; }
  mutation "resolv-membership-neutered" \
    's/\*" \${srv} "\*)/*"no-such-server-ever")/' \
    setup_resolv_match assert_rmatch
else
  bad "no host nameserver, so the false-positive mutation could NOT be applied — not counted as a pass"
fi

echo
echo "kind-doctor: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ] || exit 1
