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

for bin in docker kubectl; do
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
head_ "2. Node egress (raw TCP — resolution is not tested, on purpose)"
egress_ok=0
for hostport in 1.1.1.1:443 8.8.8.8:53 9.9.9.9:443; do
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
        restart`; systemd: `sudo systemctl restart docker`) and expect the kind
        node NOT to survive it: rebuild with `make kind-up` afterwards.
DIAG
fi

# Stale embedded-resolver upstreams: captured at container CREATE time, so a
# long-lived node can be forwarding to a VPN resolver that died days ago.
if docker exec "${NODE}" cat /etc/resolv.conf 2>/dev/null > /tmp/kind-doctor-resolv.$$; then
  ext_line="$(grep -a 'ExtServers' /tmp/kind-doctor-resolv.$$ 2>/dev/null || true)"
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
  rm -f /tmp/kind-doctor-resolv.$$
fi

# ─────────────────────────────────────────── 3. every image a pod wants, held
head_ "3. Image presence (what pods reference vs what the node holds)"
if ! kubectl --context "${KCTX}" get nodes >/dev/null 2>&1; then
  fail "kubectl cannot reach the API server on context ${KCTX}"
else
  wanted="$(kubectl --context "${KCTX}" get pods -A -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
seen = set()
for p in d.get("items", []):
    spec = p.get("spec", {})
    for key in ("containers", "initContainers"):
        for c in spec.get(key) or []:
            if c.get("image"):
                seen.add(c["image"])
for i in sorted(seen):
    print(i)
')"
  # repoDigests as well as repoTags. A pod may reference a DIGEST-PINNED ref
  # (name@sha256:... or name:tag@sha256:...), and those never appear in
  # repoTags — measured live 2026-09-10, where three running pods' images were
  # reported missing by a tags-only comparison while the pods were Running.
  held="$(docker exec "${NODE}" crictl images -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for img in d.get("images", []):
    for t in (img.get("repoTags") or []) + (img.get("repoDigests") or []):
        print(t)
')"
  if [ -z "${wanted}" ]; then
    warn "no pods found — nothing to check yet"
  else
    missing=""
    while IFS= read -r ref; do
      [ -n "${ref}" ] || continue
      # A ref can be `name:tag`, `name@sha256:...`, or `name:tag@sha256:...`,
      # and the node reports repoTags (name:tag) and repoDigests (name@digest)
      # as separate lists — a digest-pinned ref appears in NEITHER as written.
      #
      # Every comparison below is EXACT. Two mutations on 2026-09-10 survived
      # an earlier version of this block, and each was a substring match: an
      # unanchored digest compare accepted `other@sha256:aaaabbbb` for
      # `login-ui@sha256:aaaa`, and an unanchored tail compare accepted
      # `:v10` for `:v1`. A guard that matches the wrong image is a guard that
      # reports green on a cluster that cannot run.
      ref_name="${ref%%@*}"
      ref_digest=""
      case "${ref}" in *@*) ref_digest="${ref##*@}" ;; esac
      # Strip a tag only when the colon is AFTER the last slash — `localhost:5001/x`
      # is a registry port, not a tag.
      ref_repo="${ref_name}"
      case "${ref_name##*/}" in *:*) ref_repo="${ref_name%:*}" ;; esac

      matched=0
      if printf '%s\n' "${held}" | grep -aFx -- "${ref}" >/dev/null 2>&1; then
        matched=1
      elif [ -n "${ref_digest}" ] && printf '%s\n' "${held}" | grep -aFx -- "${ref_repo}@${ref_digest}" >/dev/null 2>&1; then
        matched=1
      elif printf '%s\n' "${held}" | grep -aFx -- "${ref_name}" >/dev/null 2>&1; then
        matched=1
      else
        # Last resort, and only for registry normalisation: a pod that says
        # `alpine:3.20` is satisfied by a held `docker.io/library/alpine:3.20`.
        # An exact SUFFIX on a slash boundary — never a substring.
        for candidate in "${ref}" "${ref_name}"; do
          [ -n "${candidate}" ] || continue
          if printf '%s\n' "${held}" | awk -v want="/${candidate}" \
               'index($0, want) == length($0) - length(want) + 1 { found = 1 } END { exit !found }'; then
            matched=1; break
          fi
        done
      fi
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
        printf '%s' "${first_party}" | sed 's/^/           /'
      fi
      if [ -n "${other}" ]; then
        warn "$(printf '%s' "${other}" | grep -ac .) third-party image(s) not yet pulled (may simply be in flight)"
        printf '%s' "${other}" | sed 's/^/           /'
      fi
    fi
  fi
fi

# ───────────────────────────────────────────────────────── 4. are pods living
head_ "4. Pod health"
if kubectl --context "${KCTX}" get nodes >/dev/null 2>&1; then
  bad="$(kubectl --context "${KCTX}" get pods -A --no-headers 2>/dev/null \
        | awk '$4 != "Running" && $4 != "Completed" {print "           " $1 "/" $2 "  " $4}')"
  if [ -z "${bad}" ]; then
    ok "all pods Running or Completed"
  else
    n="$(printf '%s\n' "${bad}" | grep -ac .)"
    stuck="$(printf '%s\n' "${bad}" | grep -aE 'ImagePullBackOff|ErrImagePull|CrashLoopBackOff' || true)"
    if [ -n "${stuck}" ]; then
      fail "${n} pod(s) not healthy, including image-pull or crash-loop failures"
    else
      warn "${n} pod(s) not Running (may be starting)"
    fi
    printf '%s\n' "${bad}"
  fi
fi

# ─────────────────────────────────────────────────────── 5. is GitOps alive
head_ "5. ArgoCD"
if kubectl --context "${KCTX}" get crd applications.argoproj.io >/dev/null 2>&1; then
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
  printf '\033[31mkind-doctor: %d failure(s), %d warning(s) — this cluster cannot run the mesh.\033[0m\n' "${FAILURES}" "${WARNINGS}"
  # WARN_ONLY exists for ONE caller: bootstrap-kind.sh's closing summary. The
  # documented order is `make kind-up` THEN `make kind-images`, so a fresh
  # cluster legitimately has no first-party image yet and bring-up must not
  # fail on it. Every other caller gets the exit code.
  if [ "${KIND_DOCTOR_WARN_ONLY:-0}" = "1" ]; then
    printf '\033[33m            (reported only — bring-up is not failed on this)\033[0m\n'
    exit 0
  fi
  exit 1
fi
printf '\033[32mkind-doctor: healthy (%d warning(s)).\033[0m\n' "${WARNINGS}"
exit 0
