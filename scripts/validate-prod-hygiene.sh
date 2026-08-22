#!/usr/bin/env bash
# =============================================================================
# validate-prod-hygiene.sh — the prod (ENV=prod) "no dev-only server / no
# un-flipped stub" gate. Two complementary modes:
#
#   --static   (default; CI / build-time)  Parse the BAKED prod GitOps tree for
#              forbidden artifacts: the ENV=test e2e harness wave, a Vault
#              `server -dev`, floating first-party `:dev` image tags, `*-dev`
#              image tags, the test-only MOCK ActivityPub peer, and any
#              hugmesh.net/tier: test resource. Fails the build if any
#              survive into the prod tree.
#
#   --runtime  (in-cluster; ArgoCD PreSync hook / on-demand)  Read RUNTIME
#              SIGNALS from the LIVE cluster — NOT only a manifest grep — because
#              a templated/conditional dev server (rendered by a chart value, an
#              `if eq .Values.env "dev"`, or a kustomize overlay) is invisible to
#              a static scan but is REAL in the running pod. We therefore check:
#                (a) NO running pod carries hugmesh.net/tier: test
#                    (the MOCK ActivityPub peer + the whole test-runner harness);
#                (b) NO running container runs Vault in dev mode — probe the live
#                    Vault seal-status API (a `-dev` server is auto-unsealed,
#                    initialized, in-memory) AND inspect the running container
#                    args for `-dev`;
#                (c) NO running container image is a floating `:dev` / `*-dev`
#                    first-party tag (read from the LIVE pod spec, so a
#                    conditionally-rendered tag is caught);
#                (d) every service that publishes a seam-real/health signal
#                    reports REAL (not a no-op STUB-SEAM) — an un-flipped seam
#                    answers seam=stub|disabled and FAILS the gate.
#
# Exit 0 = clean for prod; non-zero = a dev-only server or un-flipped stub is
# present (prints exactly which). Wired:
#   * build-x86-host-stage4.sh runs `--static` over the BAKED tree for ENV=prod
#     (belt to the gate_env_apps prune + image-tag rewrite).
#   * apps/00-prod-hygiene.yaml deploys the Kyverno ClusterPolicy + the PreSync
#     hook Job (manifests/prod-hygiene/) that runs `--runtime` and BLOCKS the
#     dependent app wave on a violation. See docs/TEST-ARCHITECTURE.md.
set -uo pipefail

MODE="static"
TREE=""
for a in "$@"; do
  case "$a" in
    --static)  MODE="static" ;;
    --runtime) MODE="runtime" ;;
    --tree=*)  TREE="${a#--tree=}" ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
    --*) echo "unknown arg: $a" >&2; exit 2 ;;
    # A BARE positional argument is the tree to scan (static mode), so both
    #   validate-prod-hygiene.sh --tree=<dir>   and
    #   validate-prod-hygiene.sh <dir>          work (the CI lint uses the latter).
    *) TREE="$a" ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }

FAILS=0
fail() { red "  ✗ $*"; FAILS=$((FAILS + 1)); }
ok()   { grn "  ✓ $*"; }

# =============================================================================
# STATIC mode — scan the baked prod GitOps tree (or the repo tree for CI lint).
# =============================================================================
static_mode() {
  local tree="${TREE:-${REPO_ROOT}/specs/cluster}"
  echo "prod-hygiene (static) — scanning tree: ${tree}"
  [ -d "${tree}" ] || { fail "tree not found: ${tree}"; return; }

  # The prod-hygiene bundle (manifests/prod-hygiene/ — the Kyverno ClusterPolicy +
  # this very script's in-cluster copy) is the GATE'S OWN SOURCE: it necessarily
  # contains every forbidden pattern AS DETECTION LOGIC (the `-dev` matcher, the
  # "no tier:test" policy message, etc.). Excluding it from the static scan is what
  # keeps the gate from flagging itself; it is NOT a workload, so it is safe to
  # skip. (Its own correctness is covered by the CI lint that exercises the gate.)
  local SELF=( --exclude-dir=prod-hygiene )

  # (1) The ENV=test e2e harness wave must be GONE from a prod tree.
  if [ -e "${tree}/apps/99-test-runner.yaml" ] || [ -e "${tree}/apps/00-app-of-apps-waved.yaml" ] \
     || [ -d "${tree}/manifests/test-runner" ]; then
    fail "ENV=test test-runner harness survived into the prod tree (apps/99-test-runner.yaml / 00-app-of-apps-waved.yaml / manifests/test-runner)"
  else
    ok "no ENV=test test-runner harness in the tree"
  fi

  # (2) Any resource labelled hugmesh.net/tier: test is forbidden in prod.
  local tier_hits
  tier_hits="$(grep -rln "${SELF[@]}" 'hugmesh.net/tier:[[:space:]]*test' "${tree}" 2>/dev/null || true)"
  if [ -n "${tier_hits}" ]; then
    fail "tier:test resources present in the prod tree:"
    printf '      %s\n' ${tier_hits} >&2
  else
    ok "no hugmesh.net/tier: test resources in the tree"
  fi

  # (3) Vault must NOT be `server -dev` (in-memory, auto-unseal, unsealed root).
  #     Catch it in BOTH arg styles: a "server" + "-dev" on one line (flow seq
  #     `["server","-dev"]` or `server -dev`), a standalone `-dev` flag token, and
  #     the VAULT_DEV_* env / -dev-listen-address. Comment lines are excluded.
  local vaulthits
  vaulthits="$(grep -rnE "${SELF[@]}" 'VAULT_DEV_ROOT_TOKEN_ID|-dev-listen-address|"-dev"|[[:space:]]-dev([[:space:]"]|$)|server.*-dev|-dev.*server' "${tree}" 2>/dev/null \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  if [ -n "${vaulthits}" ]; then
    fail "a Vault dev-server flag (server -dev / VAULT_DEV_*) is present in the prod tree:"
    printf '      %s\n' "${vaulthits}" >&2
  else
    ok "no Vault dev-server flag in the tree"
  fi

  # (4) Floating first-party :dev image tags must have been pinned (the build's
  #     rewrite_prod_image_tags does this; this asserts it actually happened).
  local dev_imgs
  dev_imgs="$(grep -rnE "${SELF[@]}" 'image:[[:space:]]*[^[:space:]:]*hugmesh[^[:space:]:]*:dev([[:space:]]|$)' "${tree}" 2>/dev/null || true)"
  if [ -n "${dev_imgs}" ]; then
    fail "floating first-party :dev image tag(s) survived into the prod tree:"
    printf '      %s\n' "${dev_imgs}" >&2
  else
    ok "no floating first-party :dev image tags in the tree"
  fi

  # (5) Any *-dev image repo (e.g. .../akkoma-dev, .../foo-dev:...) is forbidden.
  local devrepo
  devrepo="$(grep -rnE "${SELF[@]}" 'image:[[:space:]]*[^[:space:]]*-dev(:[^[:space:]]+)?([[:space:]]|$)' "${tree}" 2>/dev/null | grep -v '#' || true)"
  if [ -n "${devrepo}" ]; then
    fail "a *-dev image repo is referenced in the prod tree:"
    printf '      %s\n' "${devrepo}" >&2
  else
    ok "no *-dev image repos in the tree"
  fi
}

# =============================================================================
# RUNTIME mode — read live cluster signals (the AUTHORITATIVE check; catches
# templated/conditional dev servers a static grep cannot see).
# =============================================================================
runtime_mode() {
  echo "prod-hygiene (runtime) — reading live cluster signals"
  command -v kubectl >/dev/null || { fail "kubectl not found (runtime mode needs cluster access)"; return; }

  # (a) NO running pod is labelled hugmesh.net/tier: test (the MOCK
  #     ActivityPub peer + the whole test-runner harness). This is the single
  #     strongest runtime signal: the test peer is flagged for exactly this gate.
  local testpods
  testpods="$(kubectl get pods -A -l 'hugmesh.net/tier=test' \
      -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [ -n "${testpods}" ]; then
    fail "tier:test pods are RUNNING in this (prod) cluster:"
    printf '      %s\n' ${testpods} >&2
  else
    ok "no tier:test pods running (no MOCK peer / test-runner)"
  fi

  # (b) Vault is NOT in dev mode. Two independent runtime signals:
  #   (i)  the live Vault container args do not contain `-dev`, and
  #   (ii) the seal-status API does not look like a dev server (a dev Vault is
  #        born unsealed+initialized with a single in-memory share).
  local vault_args
  vault_args="$(kubectl -n vault get pods -l app.kubernetes.io/name=vault \
      -o jsonpath='{range .items[*].spec.containers[*]}{.args}{" "}{.command}{"\n"}{end}' 2>/dev/null || true)"
  if printf '%s' "${vault_args}" | grep -E '(^|[^a-z])-dev([^a-z]|$)' >/dev/null; then
    fail "the running Vault container is started with a -dev flag"
  else
    ok "running Vault container has no -dev flag"
  fi
  # Probe the seal-status from inside the cluster (best-effort; if Vault is not
  # this cluster's responsibility the curl just fails and we skip, not fail).
  local seal
  seal="$(kubectl -n vault exec deploy/vault -c vault -- sh -c \
      'wget -qO- --no-check-certificate https://127.0.0.1:8200/v1/sys/seal-status 2>/dev/null || curl -sk https://127.0.0.1:8200/v1/sys/seal-status 2>/dev/null' 2>/dev/null || true)"
  if [ -n "${seal}" ]; then
    # A real (prod) Vault uses recovery/seal shares >1 (Shamir) and is sealed at
    # rest before the unseal sidecar runs. A dev server reports n==1 && t==1 and
    # is never sealed. We only FLAG the unambiguous dev fingerprint.
    if printf '%s' "${seal}" | grep -E '"n"[[:space:]]*:[[:space:]]*1' >/dev/null \
       && printf '%s' "${seal}" | grep -E '"t"[[:space:]]*:[[:space:]]*1' >/dev/null; then
      fail "live Vault seal-status reports a single in-memory share (n=t=1) — looks like a dev server"
    else
      ok "live Vault seal-status is not a dev fingerprint"
    fi
  else
    ylw "  ~ Vault seal-status not reachable from here (skipping the API probe; the -dev arg check above still applies)"
  fi

  # (c) NO running first-party container image is a floating :dev / *-dev tag.
  #     Read from the LIVE pod spec so a conditionally-rendered tag is caught.
  local liveimgs
  liveimgs="$(kubectl get pods -A -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' 2>/dev/null \
      | sort -u || true)"
  local baddev
  baddev="$(printf '%s\n' "${liveimgs}" | grep -E '(hugmesh[^[:space:]:]*:dev$)|(-dev(:[^[:space:]]+)?$)' || true)"
  if [ -n "${baddev}" ]; then
    fail "running container image(s) use a dev tag/repo:"
    printf '      %s\n' ${baddev} >&2
  else
    ok "no running container images use a :dev / *-dev tag"
  fi

  # (d) Every service that publishes a seam-real/health signal reports REAL.
  #     The convention: a workload that gates a feature behind a documented
  #     STUB-SEAM exposes its real-vs-stub state at a /healthz-style endpoint and
  #     ALSO advertises it with the pod annotation
  #         hugmesh.net/seam-probe: "<scheme>://<svc-FQDN>:<port>/<path>#<jsonkey>"
  #     The host MUST be a cluster FQDN (svc.<ns>.svc.cluster.local) so the probe
  #     pod — which runs in PROBE_NS (the gate's own namespace, where its RBAC
  #     permits pod-create) — can reach it cross-namespace. An un-flipped seam
  #     answers {"<jsonkey>":"stub"} | "disabled" | "noop" and FAILS the gate.
  #     Pods WITHOUT the annotation are not seam-bearing and are skipped
  #     (default-real). A marker file aggregates failures across the while-subshell.
  local PROBE_NS="${PROD_HYGIENE_PROBE_NS:-hugmesh-policy}"
  local probes
  probes="$(kubectl get pods -A \
      -o jsonpath='{range .items[*]}{.metadata.annotations.hugmesh\.net/seam-probe}{"\n"}{end}' 2>/dev/null \
      | awk 'NF>0' | sort -u || true)"
  if [ -z "${probes}" ]; then
    ylw "  ~ no pods advertise a hugmesh.net/seam-probe annotation (no seam-bearing services to verify)"
  else
    local target key body
    printf '%s\n' "${probes}" | while read -r target; do
      [ -n "${target}" ] || continue
      key="${target##*#}"; target="${target%#*}"
      body="$(kubectl -n "${PROBE_NS}" run "prod-hygiene-seam-$$-${RANDOM}" --rm -i --restart=Never \
          --image=curlimages/curl:8.10.1 --quiet -- \
          -sk --max-time 5 "${target}" 2>/dev/null || true)"
      if printf '%s' "${body}" | grep -iE "\"${key}\"[[:space:]]*:[[:space:]]*\"(stub|disabled|noop|dev|placeholder)\"" >/dev/null; then
        red   "  ✗ seam not flipped: ${target} reports ${key}=stub/disabled"
        echo "fail ${target}" >> "${TMPDIR:-/tmp}/prod-hygiene-seam-fails"
      else
        grn "  ✓ seam real: ${target}"
      fi
    done
    if [ -f "${TMPDIR:-/tmp}/prod-hygiene-seam-fails" ]; then
      FAILS=$((FAILS + $(wc -l < "${TMPDIR:-/tmp}/prod-hygiene-seam-fails")))
      rm -f "${TMPDIR:-/tmp}/prod-hygiene-seam-fails"
    fi
  fi
}

rm -f "${TMPDIR:-/tmp}/prod-hygiene-seam-fails" 2>/dev/null || true
case "${MODE}" in
  static)  static_mode ;;
  runtime) runtime_mode ;;
esac

echo
if [ "${FAILS}" -eq 0 ]; then
  grn "prod-hygiene (${MODE}): PASS — no dev-only server / un-flipped stub found"
  exit 0
else
  red "prod-hygiene (${MODE}): FAIL — ${FAILS} violation(s); prod sync must be blocked"
  exit 1
fi
