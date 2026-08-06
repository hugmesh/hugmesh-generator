#!/usr/bin/env bash
# test-container-image-tags.sh — every third-party container image specs/cluster
# pins must still EXIST in its registry.
#
# WHY THIS EXISTS. Bitnami's move to Broadcom retired the free `bitnami/*` Docker
# Hub images and republished them under `bitnamilegacy/*`. Most of this repo was
# migrated; three manifests were missed and still pinned a tag that is now 404:
#
#   docker.io/bitnami/kubectl:1.31        -> HTTP 404   (dead)
#   docker.io/bitnamilegacy/kubectl:1.31  -> HTTP 200
#
#   specs/cluster/manifests/egress-vpn/secret-projector-daemonset.yaml:111
#   specs/cluster/manifests/prod-hygiene/job.yaml:63
#   specs/cluster/manifests/test-runner/orchestrator.yaml:155
#
# A running cluster hides this: the image is already on the node, so the pod
# starts and keeps starting. It only bites on a bring-up from nothing — which is
# the case this repo exists to produce — where it is an ImagePullBackOff with no
# obvious connection to a vendor's registry reorganisation months earlier.
#
# WHY IT MUST TOUCH THE NETWORK. A registry retiring a tag is not visible in the
# source. No offline check can see it. That is the whole justification for this
# being one of the few gates allowed out to the internet.
#
# ON TRANSIENT FAILURES. Docker Hub rate-limits anonymous pulls, and a 429 or a
# DNS blip must NOT be reported as a retired tag — that would train people to
# ignore the gate. Every probe distinguishes three outcomes:
#     ALIVE        manifest returned 200
#     DEAD         registry said 404 / MANIFEST_UNKNOWN  -> hard failure
#     INCONCLUSIVE anything else, after retries          -> ALSO a failure, but
#                  reported separately and worded as "could not determine"
# Inconclusive is deliberately not a pass. A gate that cannot check must never
# report success; that is the single most common way guards in this repo have
# failed. It is loud about which of the two it is, so the fix is obvious.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
ROOT="${IMAGE_TAG_ROOT:-${REPO}/specs/cluster}"
RETRIES="${IMAGE_TAG_RETRIES:-3}"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

for t in curl python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: ${t} required (refusing to skip)" >&2; exit 1; }
done
[ -d "${ROOT}" ] || { echo "FATAL: cannot read ${ROOT}" >&2; exit 1; }

echo "== container image tags: ${ROOT} =="

# Only Docker Hub images are probed; other registries need credentials this gate
# does not have, and a gate that silently skips most of its input is worse than
# no gate. Those are counted and reported so the omission is visible.
# Excluded, each for a stated reason rather than by convenience:
#   {{ }}          templated at render time; the literal is not an image
#   REPLACE_WITH_  an operator-supplied placeholder the manifest documents as such
#   @sha256:       digest-pinned, so the tag cannot rot — the digest either
#                  resolves or the image is gone entirely, and a digest probe
#                  needs a different endpoint; counted as not-probed, not passed
#   no : and no /  not an image reference at all (the grep also catches YAML keys
#                  named `image:` whose value is a bare word, e.g. an API schema)
#   first-party    our OWN images. In the base manifests they appear as bare
#                  `snapdragon-systems/<repo>:dev` / `hugmesh/<repo>` placeholders
#                  which the overlays' kustomize `images:` transformers rewrite to
#                  registry.hugmesh.systems/hugmesh/<repo>:main. They are built and
#                  pushed by our own CI and have never existed on Docker Hub, so
#                  probing them there asks the wrong registry a question it cannot
#                  answer (Docker Hub returns 401, not 404, for a repo an
#                  anonymous client may not see — indistinguishable from a rate
#                  limit). Their freshness is Harbor's problem, covered by
#                  test-eso-target-collisions.sh's pull-secret leg.
FIRST_PARTY_RE='^(snapdragon-systems|hugmesh|snapdragon)/'
images="$(grep -rhoE '^[[:space:]]*image:[[:space:]]*[^[:space:]"]+' "${ROOT}" 2>/dev/null \
          | sed 's/.*image:[[:space:]]*//' \
          | grep -vE '\{\{|REPLACE_WITH_|@sha256:' \
          | grep -E '[:/]' \
          | grep -vE "${FIRST_PARTY_RE}" \
          | grep -v 'registry\.hugmesh\.systems' \
          | sort -u || true)"
images="$(printf '%s\n' "${images}" | grep -v '^$' || true)"

probe() { # <repo> <tag> -> prints ALIVE|DEAD|INCONCLUSIVE
  local repo="$1" tag="$2" i tok code
  for i in $(seq 1 "${RETRIES}"); do
    tok="$(curl -s --max-time 30 \
      "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
      2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")' 2>/dev/null)"
    if [ -z "${tok}" ]; then sleep "${i}"; continue; fi
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
      -H "Authorization: Bearer ${tok}" \
      -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json' \
      "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" 2>/dev/null)"
    case "${code}" in
      200) echo ALIVE; return ;;
      404) echo DEAD;  return ;;
      *)   sleep "${i}" ;;
    esac
  done
  echo INCONCLUSIVE
}

checked=0; dead=0; incon=0; skipped=0
declare -a dead_list=() incon_list=()

while read -r ref; do
  [ -n "${ref}" ] || continue
  case "${ref}" in
    docker.io/*) short="${ref#docker.io/}" ;;
    *.*/*)       skipped=$((skipped+1)); continue ;;   # a real registry host
    *)           short="${ref}" ;;                      # bare -> Docker Hub
  esac
  case "${short}" in *:*) tag="${short##*:}"; repo="${short%:*}" ;; *) tag=latest; repo="${short}" ;; esac
  case "${repo}" in */*) : ;; *) repo="library/${repo}" ;; esac
  checked=$((checked+1))
  verdict="$(probe "${repo}" "${tag}")"
  case "${verdict}" in
    ALIVE)        printf '     ok           %s\n' "${ref}" ;;
    DEAD)         printf '     DEAD         %s\n' "${ref}"; dead=$((dead+1));  dead_list+=("${ref}") ;;
    INCONCLUSIVE) printf '     INCONCLUSIVE %s\n' "${ref}"; incon=$((incon+1)); incon_list+=("${ref}") ;;
  esac
done <<< "${images}"

echo "     (${checked} Docker Hub image(s) probed, ${skipped} on other registries not probed)"

# ── the result, cross-checked against the printed lines ────────────────────
# The counter is not trusted on its own: a previous gate in this repo shipped
# with a sabotaged accumulator that still printed its findings while reporting
# success, and nothing noticed. Assert the two agree.
if [ "${dead}" -ne "${#dead_list[@]}" ] || [ "${incon}" -ne "${#incon_list[@]}" ]; then
  bad "internal: the counters disagree with the recorded findings (dead ${dead}/${#dead_list[@]}, inconclusive ${incon}/${#incon_list[@]}) — the accumulator is not carrying the result"
else
  ok "internal: counters agree with the recorded findings"
fi

if [ "${#dead_list[@]}" -eq 0 ]; then
  ok "every probed image tag still exists in its registry"
else
  for d in "${dead_list[@]}"; do echo "       retired: ${d}"; done
  bad "${#dead_list[@]} image tag(s) no longer exist — a bring-up from nothing ImagePullBackOffs here, while a warm node keeps working"
fi

if [ "${#incon_list[@]}" -eq 0 ]; then
  ok "no probe was inconclusive"
else
  for d in "${incon_list[@]}"; do echo "       undetermined: ${d}"; done
  bad "${#incon_list[@]} probe(s) could not be determined after ${RETRIES} tries (rate limit? network?) — this is NOT a pass; re-run, and if it persists the gate cannot see the registry"
fi

# ── vacuity ────────────────────────────────────────────────────────────────
if [ "${checked}" -ge 5 ]; then
  ok "vacuity: the scan really walked the tree (${checked} probed)"
else
  bad "vacuity: only ${checked} image(s) probed — the extractor is not reading ${ROOT}"
fi

# ── negative controls ──────────────────────────────────────────────────────
echo "-- negative controls --"
v="$(probe bitnami/kubectl 1.31)"
if [ "${v}" = "DEAD" ]; then
  ok "negative control: the shipped defect (bitnami/kubectl:1.31) is detected as retired"
else
  bad "negative control: bitnami/kubectl:1.31 probed as '${v}', expected DEAD — if Broadcom restored it, re-check whether this gate still models reality"
fi
v="$(probe bitnamilegacy/kubectl 1.31)"
if [ "${v}" = "ALIVE" ]; then
  ok "negative control: the replacement (bitnamilegacy/kubectl:1.31) is detected as alive"
else
  bad "negative control: bitnamilegacy/kubectl:1.31 probed as '${v}', expected ALIVE — a probe that cannot see a live tag would call everything dead"
fi
v="$(probe library/alpine this-tag-does-not-exist-9z9z)"
if [ "${v}" = "DEAD" ]; then
  ok "negative control: a nonexistent tag on a live repository is detected"
else
  bad "negative control: a nonexistent tag probed as '${v}', expected DEAD"
fi

echo
echo "== container image tags: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
