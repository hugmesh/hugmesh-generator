#!/usr/bin/env bash
# kind-mfa-posture.sh — print the kind lane's LIVE gateway MFA posture as an
# `APP_MFA_ENABLED=<true|false>` assignment, read back off the RUNNING pod spec.
#
# WHY THIS EXISTS. tests/e2e/specs/29-mfa-privileged-floor.spec.ts SELECTS which of
# its two stack blocks runs on `process.env.APP_MFA_ENABLED`: `false` runs the
# OFF-posture block (the cluster default — mfa_required rows inert, role wall intact),
# anything else runs the per-row enforcement block. Both lanes of `make kind-up` are
# real postures (`MFA=1` flips gateway `mfa.enabled` to true, plain `kind-up` leaves
# the chart default false), so a caller who exports the value by hand is guessing at
# the state of a cluster that can tell them. Guessing wrong runs the wrong block and
# fails for a reason that has nothing to do with the defect.
#
# The kind bring-up flips MFA through an ArgoCD helm PARAMETER, not a committed value,
# so the repo cannot answer this question either: the chart's values.yaml says `false`
# on a cluster that is enforcing. The only honest source is the rendered pod spec.
#
# FAIL-CLOSED, never a default. An unreachable cluster, a missing Deployment, a
# container whose env the chart did not render, or a value that is neither `true` nor
# `false` all exit non-zero with the reason on stderr. "Assume off" would be the
# friendlier behaviour and the wrong one — it would hand spec 29 the OFF block against
# a cluster that is enforcing, and report a clean pass for the posture the cluster is
# NOT holding, which is precisely the failure this whole file is here to remove.
#
# Usage:  eval "$(scripts/kind-mfa-posture.sh)"   # exports nothing; prints the pair
#         APP_MFA_ENABLED="$(scripts/kind-mfa-posture.sh --value)"
#
# Env (all optional):
#   MFA_GW_NAMESPACE  namespace holding the gateway Deployment (default hugmesh-frontend)
#   MFA_GW_DEPLOY     the Deployment name                      (default hugmesh-fe-gateway)
#   MFA_GW_CONTAINER  the container carrying the env trio      (default gateway)
set -uo pipefail

NS="${MFA_GW_NAMESPACE:-hugmesh-frontend}"
DEPLOY="${MFA_GW_DEPLOY:-hugmesh-fe-gateway}"
CONTAINER="${MFA_GW_CONTAINER:-gateway}"
VALUE_ONLY=""
case "${1:-}" in
  --value) VALUE_ONLY=1 ;;
  "")      ;;
  *)       echo "kind-mfa-posture.sh: unknown argument '$1' (expected --value or nothing)" >&2; exit 2 ;;
esac

die() { echo "kind-mfa-posture.sh: $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 \
  || die "kubectl not on PATH — the live posture cannot be read, and it must not be guessed"

# One read of the rendered container env. `-o jsonpath` with a filter on BOTH the
# container name and the variable name, so a chart that renames either fails here
# rather than silently matching some other container's variable.
raw="$(kubectl -n "${NS}" get deploy "${DEPLOY}" -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER}')].env[?(@.name=='APP_MFA_ENABLED')].value}" 2>/dev/null)" \
  || die "kubectl could not read deploy/${DEPLOY} in namespace ${NS} (is the kind cluster up, and is the context right?)"

[ -n "${raw}" ] \
  || die "deploy/${DEPLOY} container '${CONTAINER}' in ${NS} renders no APP_MFA_ENABLED value. Either the gateway chart stopped emitting the MFA env trio (tests/stack/test-gateway-mfa-env.sh assertion 3 covers that), or the value comes from a valueFrom reference this script deliberately does not follow — an indirected posture is not a readable one"

# Normalise exactly the two spellings the chart can produce (`| quote` renders the
# boolean as a quoted string). Anything else is a posture nobody has reasoned about.
case "${raw}" in
  true|True|TRUE)    posture=true ;;
  false|False|FALSE) posture=false ;;
  *) die "deploy/${DEPLOY} renders APP_MFA_ENABLED='${raw}', which is neither true nor false. Spring parses an unrecognised value as false, so the pod is NOT enforcing — but nothing in the chart should be able to produce this, so it is reported rather than coerced" ;;
esac

if [ -n "${VALUE_ONLY}" ]; then
  printf '%s\n' "${posture}"
else
  printf 'APP_MFA_ENABLED=%s\n' "${posture}"
fi
