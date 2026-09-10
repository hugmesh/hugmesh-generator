#!/usr/bin/env bash
# kind-doctor.sh — answer the only question that matters about a kind cluster:
# CAN THIS CLUSTER ACTUALLY RUN THE MESH?
#
# WHY THIS EXISTS (hugmesh-generator#349). On 2026-09-10 the kind lane had been
# dead for two days and every surface a person would check reported health.
# `kind get clusters` listed it. `kubectl get nodes` said Ready. Meanwhile 19
# pods sat in ImagePullBackOff and the failed-pull counter passed thirteen
# thousand. Two independent causes, either fatal on its own:
#
#   1. The host had lost docker's netfilter rules — `nft list tables` returned
#      only `inet firewalld`, whose filter_FORWARD ends `reject with icmpx
#      admin-prohibited`. Containers could not reach anything. The disguise is
#      cruel: docker's embedded resolver runs in the HOST netns and keeps
#      answering, so every error reads `dial tcp: lookup quay.io on
#      172.18.0.1:53: i/o timeout` and looks exactly like a DNS fault. It is
#      not. Test raw TCP, never resolution.
#   2. No first-party image had ever been loaded. Every app pod references
#      registry.hugmesh.net/hugmesh/<repo>:main, which resolves nowhere BY
#      DESIGN — kind-load-images.sh puts those refs straight into the node's
#      containerd store. `make kind-images` had never run. `make kind-up`
#      exits 0 without ever mentioning it.
#
# Neither is exotic and neither is detected anywhere else, so this script is
# the standing check. It reports and exits non-zero; it never repairs.
#
# THE ONE RULE THIS SCRIPT LIVES BY: it must never report a property it did not
# actually look at. Every check below fails CLOSED — a missing tool, a kubectl
# that cannot answer, a crictl that will not run, an empty pod list — all of
# them are failures, never silent greens. The whole point of this guard is that
# it is the thing you check after two dead days.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-hugmesh-local}"
NODE="${CLUSTER_NAME}-control-plane"
KCTX="kind-${CLUSTER_NAME}"

# shellcheck source=scripts/_tools-path-lib.sh
if [ -r "${SCRIPT_DIR}/_tools-path-lib.sh" ]; then
  . "${SCRIPT_DIR}/_tools-path-lib.sh"; hugmesh_tools_path
fi

FAILURES=0
WARNINGS=0
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
ok()   { printf '  \033[32m ok \033[0m  %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# python3 is as required as docker and kubectl: section 3 — the entire reason
# #349 exists — is two inline `python3 -c` programs. Leaving it out of this
# loop was measured on 2026-09-10 to make the image check vanish silently and
# the script print `kind-doctor: healthy` on a cluster holding no first-party
# image at all. tests/lib/guard-preflight.sh states the rule this obeys: a
# guard that cannot run must say so, because "exiting 0 would report a property
# as verified that was never looked at".
for bin in docker kubectl python3; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "kind-doctor: missing required tool: ${bin}" >&2; exit 2; }
done

# ─────────────────────────────────────────────────────────── 1. does it exist
head_ "1. Cluster"
if docker inspect "${NODE}" >/dev/null 2>&1; then
  node_state="$(docker inspect -f '{{.State.Status}}' "${NODE}" 2>/dev/null)"
  if [ "${node_state}" = "running" ]; then
    ok "node container ${NODE} is running"
  else
    fail "node container ${NODE} exists but is '${node_state}' — 'docker start ${NODE}'"
  fi
else
  fail "no node container ${NODE}. The cluster is gone; rebuild with 'make kind-up'."
  echo
  echo "kind-doctor: nothing further can be checked. ${FAILURES} failure(s)."
  exit 1
fi

# ────────────────────────────────────────────────── 2. egress, by RAW TCP only
#
# Deliberately NOT a DNS lookup and NOT a name. The failure this catches makes
# name resolution keep working for a while, so a resolution test reports green
# through the exact outage it is supposed to find.
#
# TARGETS, in two tiers, and the order matters:
#   1. the registries this lane actually pulls from, RESOLVED ON THE HOST — the
#      node is only ever handed a literal address, so nothing is resolved
#      inside the netns whose resolver lies;
#   2. public anycast literals, as a floor for a host that cannot resolve.
# Tier 1 was added because 1.1.1.1:443 / 8.8.8.8:53 / 9.9.9.9:443 are three
# PUBLIC DNS RESOLVERS, two of them on their DoH port — the single most
# commonly blocked destination class on a managed network, and none of them a
# registry. Probing only those turns "this lab forces its own resolver" into a
# hard abort of a bring-up that would have worked perfectly.
head_ "2. Node egress (raw TCP — resolution is not tested, on purpose)"
egress_targets() {
  for _name in registry.k8s.io ghcr.io quay.io; do
    # `|| true` is not decoration. bootstrap-kind.sh runs under `set -euo
    # pipefail`, and a getent that cannot resolve exits 2, which pipefail
    # promotes to the pipeline's status. Without this the function dies at
    # the FIRST unresolvable name and never emits the anycast fallback, so a
    # host that merely has no DNS aborts its bring-up with no message at
    # all. It survives today only because the call site is a `for` word
    # list, where bash suppresses errexit — an accident, not a design.
    getent ahostsv4 "${_name}" 2>/dev/null | awk '$2 == "STREAM" { print $1 ":443"; exit }' || true
  done
  printf '%s\n' 1.1.1.1:443 8.8.8.8:53 9.9.9.9:443
}
egress_ok=0
for hostport in $(egress_targets); do
  h="${hostport%%:*}"
  p="${hostport##*:}"
  if docker exec "${NODE}" timeout 4 bash -c "exec 3<>/dev/tcp/${h}/${p}" >/dev/null 2>&1; then
    ok "TCP ${hostport} reachable from the node"
    egress_ok=1
    break
  fi
done
if [ "${egress_ok}" -eq 0 ]; then
  fail "the node cannot open a TCP connection to ANY public address."
  cat <<'DIAG'
        This is almost never DNS, whatever the error text says. Check whether
        docker still owns any netfilter rules:

          docker run --rm --net=host --privileged alpine:3.20 \
            sh -c 'apk add -q nftables; nft list tables'

        If that prints only `table inet firewalld`, docker's rules are gone.
        They are installed once, at daemon start — `docker network create` does
        NOT reinstall them. Restart the daemon (Gentoo: `sudo rc-service docker
        restart`; systemd: `sudo systemctl restart docker`), then REBUILD:

          make kind-down && make kind-up

        `make kind-up` alone is not enough. The node will not survive the
        daemon restart, but `kind get clusters` still NAMES a stopped cluster,
        so bootstrap-kind.sh takes its "already exists — reusing it" branch and
        then hangs on an API server that is never coming back.
DIAG
fi

# Stale embedded-resolver upstreams: captured at container CREATE time, so a
# long-lived node can be forwarding to a VPN resolver that died days ago.
resolv_tmp=""
trap 'rm -f "${resolv_tmp:-}"' EXIT
resolv_tmp="$(mktemp "${TMPDIR:-/tmp}/kind-doctor-resolv.XXXXXX" 2>/dev/null)" || resolv_tmp=""
if [ -n "${resolv_tmp}" ] && docker exec "${NODE}" cat /etc/resolv.conf 2>/dev/null > "${resolv_tmp}"; then
  ext_line="$(grep -a 'ExtServers' "${resolv_tmp}" 2>/dev/null || true)"
  host_ns="$(grep -a '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
  if [ -n "${ext_line}" ]; then
    stale=0
    for srv in $(printf '%s' "${ext_line}" | grep -ao 'host([^)]*)' | sed 's/host(//; s/)//'); do
      case " ${host_ns} " in
        *" ${srv} "*) : ;;
        *) stale=1; warn "node forwards DNS to ${srv}, which is NOT in the host's current resolv.conf (captured when the container was created)" ;;
      esac
    done
    [ "${stale}" -eq 0 ] && ok "node's DNS upstreams match the host's current resolvers"
  fi
fi

# ─────────────────────────────────────────── 3. every image a pod wants, held
head_ "3. Image presence (what pods reference vs what the node holds)"
if ! kubectl --context "${KCTX}" get nodes >/dev/null 2>&1; then
  fail "kubectl cannot reach the API server on context ${KCTX} — image presence was NOT checked"
else
  # Both halves below FAIL CLOSED. The first version swallowed every error
  # (`2>/dev/null` on kubectl, `except Exception: sys.exit(0)` in python) and an
  # empty result read as "no pods found — nothing to check yet". Measured
  # 2026-09-10: python3 off PATH, a kubectl whose pod endpoint times out, and
  # truncated JSON each made the whole of section 3 disappear while the script
  # printed `kind-doctor: healthy` and exited 0.
  wanted=""; held=""; inputs_ok=1

  pods_json="$(kubectl --context "${KCTX}" get pods -A -o json 2>/dev/null)"
  if [ $? -ne 0 ] || [ -z "${pods_json}" ]; then
    fail "\`kubectl get pods -A -o json\` did not answer — image presence was NOT checked"
    inputs_ok=0
  else
    wanted="$(printf '%s' "${pods_json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("kind-doctor: cannot parse the pod list: %s\n" % e)
    sys.exit(1)
if not isinstance(d, dict):
    sys.stderr.write("kind-doctor: the pod list is not a JSON object\n")
    sys.exit(1)
seen = set()
for p in d.get("items") or []:
    spec = p.get("spec") or {}
    for key in ("containers", "initContainers"):
        for c in spec.get(key) or []:
            if c.get("image"):
                seen.add(c["image"])
for i in sorted(seen):
    print(i)
' 2>&1)" || { fail "could not read image references out of the pod list — image presence was NOT checked: ${wanted}"; inputs_ok=0; wanted=""; }
  fi

  # repoDigests as well as repoTags. A pod may reference a DIGEST-PINNED ref
  # (name@sha256:... or name:tag@sha256:...), and those never appear in
  # repoTags — measured live 2026-09-10, where three running pods' images were
  # reported missing by a tags-only comparison while the pods were Running.
  if [ "${inputs_ok}" -eq 1 ]; then
    held_json="$(docker exec "${NODE}" crictl images -o json 2>/dev/null)"
    if [ $? -ne 0 ] || [ -z "${held_json}" ]; then
      # An empty held set is NOT "the node holds nothing". It is far more often
      # "crictl could not run", and the two produce identical output while the
      # second deserves a completely different instruction than `make
      # kind-images`.
      fail "\`crictl images\` did not answer on ${NODE} — the node's image store was NOT read"
      inputs_ok=0
    else
      held="$(printf '%s' "${held_json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("kind-doctor: cannot parse the node image list: %s\n" % e)
    sys.exit(1)
if not isinstance(d, dict):
    sys.stderr.write("kind-doctor: the node image list is not a JSON object\n")
    sys.exit(1)
for img in d.get("images") or []:
    for t in (img.get("repoTags") or []) + (img.get("repoDigests") or []):
        print(t)
' 2>&1)" || { fail "could not read the node's image store — image presence was NOT checked: ${held}"; inputs_ok=0; held=""; }
    fi
  fi

  if [ "${inputs_ok}" -eq 0 ]; then
    :
  elif [ -z "${wanted}" ]; then
    # The API server answered and named no image anywhere, kube-system
    # included. That is not "nothing to check yet"; that is a cluster running
    # nothing at all, which is precisely what this script exists to say out
    # loud. The old WARN here also made a mutation of section 4 survive the
    # whole suite, because every scenario reached it.
    fail "the API server lists NO pod referencing any image, in any namespace — nothing is running on this cluster"
  else
    missing=""
    while IFS= read -r ref; do
      [ -n "${ref}" ] || continue
      # A ref can be `name:tag`, `name@sha256:...`, or `name:tag@sha256:...`,
      # and the node reports repoTags (name:tag) and repoDigests (name@digest)
      # as separate lists — a digest-pinned ref appears in NEITHER as written.
      ref_name="${ref%%@*}"
      ref_digest=""
      case "${ref}" in *@*) ref_digest="${ref##*@}" ;; esac
      # Strip a tag only when the colon is AFTER the last slash — `localhost:5001/x`
      # is a registry port, not a tag.
      ref_repo="${ref_name}"
      ref_tag=""
      case "${ref_name##*/}" in *:*) ref_repo="${ref_name%:*}"; ref_tag="${ref_name##*:}" ;; esac

      # The spellings this ref may LEGITIMATELY wear in the node's store, and
      # nothing else. Every comparison below is EXACT: a whole line, or a whole
      # line's tail on a slash boundary.
      #
      # A digest-pinned ref is satisfied ONLY by that digest. It deliberately
      # does NOT fall back to the bare `name:tag`, because the node can hold
      # that tag pointing at a DIFFERENT digest — which the kubelet refuses and
      # ImagePullBackOffs on, while a tag-only compare calls it present.
      if [ -n "${ref_digest}" ]; then
        candidates="${ref} ${ref_repo}@${ref_digest}"
      elif [ -n "${ref_tag}" ]; then
        candidates="${ref_name}"
      else
        # No tag and no digest means :latest, which containerd always records
        # explicitly. Untagged refs are real in this repo (local-path's
        # `image: busybox`, owncast, tube, edge-ai).
        candidates="${ref_name} ${ref_name}:latest"
      fi

      matched=0
      for candidate in ${candidates}; do
        [ -n "${candidate}" ] || continue
        if printf '%s\n' "${held}" | grep -aFx -- "${candidate}" >/dev/null 2>&1; then
          matched=1; break
        fi
        # Registry normalisation, and ONLY that: a pod that says `alpine:3.20`
        # is satisfied by a held `docker.io/library/alpine:3.20`. An exact
        # SUFFIX on a slash boundary — never a substring.
        #
        # `index($0, want) > 0 &&` is load-bearing, not belt-and-braces. awk's
        # index() returns 0 when the needle is ABSENT, and when the held line
        # happens to be exactly length(want)-1 characters long the right-hand
        # side is ALSO 0 — so `0 == 0` declared any unrelated image of the
        # right LENGTH a match. Measured 2026-09-10 by replaying #349 against
        # the live cluster: 4 of 10 absent first-party images were reported
        # present, rescued by pure length twins (local-path-provisioner:v0.0.30,
        # kube-controller-manager-amd64:v1.34.0, and two more).
        if printf '%s\n' "${held}" | awk -v want="/${candidate}" \
             'index($0, want) > 0 && index($0, want) == length($0) - length(want) + 1 { found = 1 } END { exit !found }'; then
          matched=1; break
        fi
      done
      [ "${matched}" -eq 1 ] && continue
      missing="${missing}${ref}"$'\n'
    done <<< "${wanted}"
    if [ -z "${missing}" ]; then
      ok "every referenced image is present in the node ($(printf '%s\n' "${wanted}" | grep -ac . ) refs)"
    else
      # "First-party" is the registry.hugmesh.net/ prefix, because that is what
      # this repo's kustomize images: blocks render and what kind-load-images.sh
      # side-loads. A miss there is FATAL (those refs never pull). A miss on
      # anything else is a WARN (it can still be pulled). A cluster wired to a
      # different local registry would have its side-loaded images classified as
      # third-party and so only warned about — worth revisiting if that ever
      # ships; today no profile in this repo does it.
      first_party="$(printf '%s' "${missing}" | grep -a 'registry.hugmesh.net/' || true)"
      other="$(printf '%s' "${missing}" | grep -av 'registry.hugmesh.net/' || true)"
      if [ -n "${first_party}" ]; then
        fail "$(printf '%s' "${first_party}" | grep -ac .) first-party image(s) are NOT in the node — these NEVER pull, they are side-loaded. Run: make kind-images"
        printf '%s\n' "${first_party}" | sed 's/^/           /'
      fi
      if [ -n "${other}" ]; then
        warn "$(printf '%s' "${other}" | grep -ac .) third-party image(s) not yet pulled (may simply be in flight)"
        printf '%s\n' "${other}" | sed 's/^/           /'
      fi
    fi
  fi
fi

# ───────────────────────────────────────────────────────── 4. are pods living
head_ "4. Pod health"
if ! kubectl --context "${KCTX}" get nodes >/dev/null 2>&1; then
  fail "kubectl cannot reach the API server on context ${KCTX} — pod health was NOT checked"
else
  pods_txt="$(kubectl --context "${KCTX}" get pods -A --no-headers 2>/dev/null)"
  if [ $? -ne 0 ]; then
    fail "\`kubectl get pods -A --no-headers\` did not answer — pod health was NOT checked"
  elif [ -z "${pods_txt}" ]; then
    fail "the API server lists NO pods in any namespace — nothing is running on this cluster"
  else
    # Columns: NAMESPACE NAME READY STATUS RESTARTS AGE.
    # READY ($3) is read as well as STATUS ($4). A pod sitting at 0/1 Running
    # serves nothing, and this script's header claims to answer whether the
    # mesh can RUN — which readiness, not phase, decides. Completed pods are
    # legitimately 0/1, hence the `status == "Running"` qualifier.
    bad="$(printf '%s\n' "${pods_txt}" \
          | awk '{
              split($3, r, "/")
              if ($4 != "Running" && $4 != "Completed")
                print "           " $1 "/" $2 "  " $4
              else if ($4 == "Running" && r[1] != r[2])
                print "           " $1 "/" $2 "  Running but only " $3 " ready"
            }')"
    if [ -z "${bad}" ]; then
      ok "all pods Running and ready, or Completed ($(printf '%s\n' "${pods_txt}" | grep -ac .) pods)"
    else
      n="$(printf '%s\n' "${bad}" | grep -ac .)"
      stuck="$(printf '%s\n' "${bad}" | grep -aE 'ImagePullBackOff|ErrImagePull|CrashLoopBackOff' || true)"
      if [ -n "${stuck}" ]; then
        fail "${n} pod(s) not healthy, including image-pull or crash-loop failures"
      else
        warn "${n} pod(s) not Running-and-ready (may be starting)"
      fi
      printf '%s\n' "${bad}"
    fi
  fi
fi

# ─────────────────────────────────────────────────────── 5. is GitOps alive
head_ "5. ArgoCD"
if ! kubectl --context "${KCTX}" get nodes >/dev/null 2>&1; then
  fail "kubectl cannot reach the API server on context ${KCTX} — ArgoCD was NOT checked"
elif kubectl --context "${KCTX}" get crd applications.argoproj.io >/dev/null 2>&1; then
  apps="$(kubectl --context "${KCTX}" get applications -A --no-headers 2>/dev/null | wc -l)"
  unhealthy="$(kubectl --context "${KCTX}" get applications -A --no-headers 2>/dev/null \
              | awk '$3 != "Synced" || $4 != "Healthy" {print "           " $2 "  sync=" $3 " health=" $4}')"
  if [ "${apps}" -eq 0 ]; then
    warn "the Application CRD exists but no Applications are registered"
  elif [ -z "${unhealthy}" ]; then
    ok "${apps} Application(s), all Synced and Healthy"
  else
    warn "$(printf '%s\n' "${unhealthy}" | grep -ac .) of ${apps} Application(s) not Synced+Healthy"
    printf '%s\n' "${unhealthy}"
  fi
else
  warn "no ArgoCD Application CRD — this profile may not deploy it"
fi

# ───────────────────────────────────────────────────────────────── verdict
echo
if [ "${FAILURES}" -gt 0 ]; then
  # WARN_ONLY exists for ONE caller: bootstrap-kind.sh's closing summary. The
  # documented order is `make kind-up` THEN `make kind-images`, so a fresh
  # cluster legitimately has no first-party image yet and bring-up must not
  # fail on it. It is read from the environment, so `make kind-doctor` pins it
  # to 0 explicitly — otherwise an exported value in the caller's shell would
  # quietly disarm the standing check.
  if [ "${KIND_DOCTOR_WARN_ONLY:-0}" = "1" ]; then
    printf '\033[33mkind-doctor: not runnable yet — %d unmet requirement(s), %d warning(s).\033[0m\n' "${FAILURES}" "${WARNINGS}"
    printf '\033[33m            (bring-up is not failed on this; run the command(s) named above, then `make kind-doctor`)\033[0m\n'
    exit 0
  fi
  printf '\033[31mkind-doctor: %d failure(s), %d warning(s) — this cluster cannot run the mesh.\033[0m\n' "${FAILURES}" "${WARNINGS}"
  exit 1
fi
printf '\033[32mkind-doctor: healthy (%d warning(s)).\033[0m\n' "${WARNINGS}"
exit 0
