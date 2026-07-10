#!/usr/bin/env bash
# ============================================================================
# publish-tenant-set.sh — the PUBLISH TAIL (Phase 5, the FIRST WRITE).
# ============================================================================
#
#  >>> BUILD-HOST ONLY, TAILNET-INTERNAL. Pushes the render-tenant-set trees to  <<<
#  >>> the in-cluster/tailnet Forgejo. Invokes git/openssl/node-free helpers;    <<<
#  >>> MUST NOT run as root on the mesh-node fail-closed root-cron path (Phase 6).<<<
#  >>> Nothing here is internet-exposed. Replaces the MANUAL ECHO in             <<<
#  >>> generate-brand-repos.sh (which pointed at GITLAB) with a REAL push to      <<<
#  >>> FORGEJO — matching the only working ApplicationSet (13-service-catalog).  <<<
#
# WHAT IT DOES, per rendered repo dir out/<brand>-<repo>/:
#   1. DISCOVERY CONTRACT: ensure the tree ships `snapdragon-deploy.yaml` + a
#      `deploy/` kustomize dir (the 13-catalog / 13d-brand-repos appset filter
#      requires BOTH to discover the repo). The render-tenant-set trees do NOT
#      carry them, so we synthesise a minimal, brand-scoped pair when absent.
#   2. PROVENANCE: write `.snapdragon-provenance.json` (+ detached Ed25519 .sig
#      when a signing key is provided out-of-band) — see scripts/provenance.sh.
#   3. SECRET-SCAN GATE: scripts/secret-scan.sh over the WHOLE tree (incl. the
#      provenance file) — fail-closed BEFORE any network/push.
#   4. git init -b main; add; commit (idempotent — no-op when nothing changed).
#   5. ensure org/repo on Forgejo (REST POST /api/v1/orgs/<org>/repos; 409=exists=OK).
#   6. push to `main` FAST-FORWARD-ONLY (no --force; refuse on non-ff so a re-run
#      never clobbers tenant-side edits).
#
# AUTH — HOUSE WAY (token out-of-band, NEVER committed, NEVER in argv/URL/reflog):
#   * FORGEJO_PUSH_TOKEN         — the PAT (env), OR
#   * FORGEJO_PUSH_TOKEN_FILE    — a file path the token is READ from (preferred;
#                                  never sourced, never echoed). Fail-closed if
#                                  neither is set.
#   * On the wire the token rides as an HTTP `Authorization: token <PAT>` header
#     (Forgejo accepts this form) delivered so it is NEVER on the command line (argv):
#       - git : GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader
#               GIT_CONFIG_VALUE_0="Authorization: token <PAT>" (child ENVIRON, not
#               argv; equivalent to `-c http.extraHeader` but keeps the PAT off
#               /proc/<pid>/cmdline that any co-located `ps auxww` can read).
#       - curl: -H @<0600 tmpfile> (header read from a private temp file).
#     So the PAT is NEVER persisted to .git/config, NEVER in the reflog, NEVER in
#     the remote URL, and NEVER in any process argv.
#
# CONFIG:
#   FORGEJO_BASE_URL  default http://forgejo.snapdragon-pki.svc.cluster.local:3000
#                     (in-cluster svc DNS). From a build host on the tailnet, set
#                     this to the tailnet-reachable Forgejo host (svc.cluster.local
#                     does not resolve off-cluster).
#   FORGEJO_ORG       default Snapdragon-Systems (the working appset's gitea.owner).
#                     For the recommended per-tenant-org isolation model, set this to
#                     the tenant's own Forgejo org (== the 13d appset {{ORG}} owner).
#   FORGEJO_API_MODE  rest (default) — create org/repo via Forgejo REST.
#                     none          — skip REST (repo assumed to pre-exist; used by
#                                     the LOCAL bare-repo dry-run verification).
#   FORGEJO_REMOTE_TEMPLATE  advanced override for the push URL, `%s` = repo name.
#                     Default ${FORGEJO_BASE_URL%/}/${FORGEJO_ORG}/%s.git
#                     The bare-repo dry-run points this at file:///path/%s.git.
#   PROVENANCE_SIGNING_KEY   path to an out-of-band Ed25519 private key. When set,
#                     the manifest is signed; when unset we WARN and ship the
#                     manifest UNSIGNED (production key custody is out-of-band —
#                     signing with the real key is DEFERRED to a live release).
#   SOURCE_DATE_EPOCH override for the deterministic provenance timestamp when the
#                     base is absent (skeleton mode).
#
# Usage:
#   scripts/publish-tenant-set.sh <rendered-set-dir> [--brand-yaml FILE] \
#       [--org ORG] [--only a,b] [--dry-run]
#
# --dry-run   run steps 1-4 (contract + provenance + scan + local commit) but
#             DO NOT create org/repo or push. Fail-closed token check still applies.
#
# Exit 0 iff every selected repo was scanned-clean and pushed (or, --dry-run,
# committed). Any secret finding / non-ff / missing token aborts fail-closed.
set -euo pipefail

_die() { echo "[publish] FATAL: $*" >&2; exit 1; }
_log() { echo "[publish] $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

command -v git >/dev/null 2>&1 || _die "git not found (build-host tool)"

# ── args ─────────────────────────────────────────────────────────────────────
[[ $# -ge 1 ]] || _die "usage: $0 <rendered-set-dir> [--brand-yaml FILE] [--org ORG] [--only a,b] [--dry-run]"
SET_DIR="$1"; shift
BRAND_YAML="" ONLY="" DRY_RUN=0 ORG_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --brand-yaml) BRAND_YAML="$2"; shift 2 ;;
    --org)        ORG_OVERRIDE="$2"; shift 2 ;;
    --only)       ONLY="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    *) _die "unknown argument: $1" ;;
  esac
done
[[ -d "$SET_DIR" ]] || _die "rendered-set-dir '$SET_DIR' is not a directory"
SET_DIR="$(cd "$SET_DIR" && pwd)"

# ── config ───────────────────────────────────────────────────────────────────
FORGEJO_BASE_URL="${FORGEJO_BASE_URL:-http://forgejo.snapdragon-pki.svc.cluster.local:3000}"
FORGEJO_ORG="${ORG_OVERRIDE:-${FORGEJO_ORG:-Snapdragon-Systems}}"
FORGEJO_API_MODE="${FORGEJO_API_MODE:-rest}"
FORGEJO_REMOTE_TEMPLATE="${FORGEJO_REMOTE_TEMPLATE:-${FORGEJO_BASE_URL%/}/${FORGEJO_ORG}/%s.git}"
# Org name shape guard (used in the REST URL + remote path).
[[ "$FORGEJO_ORG" =~ ^[A-Za-z0-9._-]{1,63}$ ]] || _die "invalid FORGEJO_ORG '$FORGEJO_ORG'"

# ── FAIL-CLOSED token resolution (env or file; NEVER argv/committed) ─────────
# Resolve BEFORE any repo/network op so a missing token aborts up front.
PUSH_TOKEN=""
if [[ -n "${FORGEJO_PUSH_TOKEN_FILE:-}" ]]; then
  [[ -f "${FORGEJO_PUSH_TOKEN_FILE}" ]] || _die "FORGEJO_PUSH_TOKEN_FILE='${FORGEJO_PUSH_TOKEN_FILE}' not readable"
  # Read the FIRST line only; strip trailing whitespace. Never echoed.
  PUSH_TOKEN="$(head -n1 "${FORGEJO_PUSH_TOKEN_FILE}" | tr -d '\r\n')"
elif [[ -n "${FORGEJO_PUSH_TOKEN:-}" ]]; then
  PUSH_TOKEN="${FORGEJO_PUSH_TOKEN}"
fi
[[ -n "$PUSH_TOKEN" ]] || _die "no Forgejo push token — set FORGEJO_PUSH_TOKEN or FORGEJO_PUSH_TOKEN_FILE (out-of-band; fail-closed)"
# Never allow the token to leak via xtrace / env dump.
export -n FORGEJO_PUSH_TOKEN 2>/dev/null || true

# The token rides as an HTTP `Authorization: token …` header, kept OUT of the
# process command line (argv) so a co-located `ps auxww` / /proc/<pid>/cmdline
# cannot harvest it (the .git/config-and-reflog claim was true; the argv claim
# was not — see review finding #1). Delivery:
#   * git  → GIT_CONFIG_COUNT/KEY_0/VALUE_0 env (git reads these exactly like -c
#            http.extraHeader, but the value stays in the child ENVIRON — only
#            owner/root-readable — never in argv).
#   * curl → -H @<0600 tmpfile> (the house pattern from scripts/go-live.sh); the
#            header text is read from the file, never placed on the argv.
# The header VALUE lives only in this shell's memory + a 0600 tmpfile removed on EXIT.
_AUTH_HEADER="Authorization: token ${PUSH_TOKEN}"
AUTH_HDR_FILE="$(umask 077 && mktemp)" || _die "mktemp failed for auth header file"
printf '%s\n' "${_AUTH_HEADER}" > "${AUTH_HDR_FILE}"
chmod 600 "${AUTH_HDR_FILE}" 2>/dev/null || true
_cleanup() { [[ -n "${AUTH_HDR_FILE:-}" ]] && rm -f "${AUTH_HDR_FILE}" 2>/dev/null; return 0; }
trap _cleanup EXIT
# Drop the plaintext token variable now the header is captured (defence-in-depth;
# nothing below needs the bare token — only _AUTH_HEADER / AUTH_HDR_FILE).
unset PUSH_TOKEN

# ── generator identity for provenance (deterministic per generator checkout) ──
GEN_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

# ── Forgejo REST: idempotent org/repo ensure (409 = exists = OK) ─────────────
# Uses curl if present; the LOCAL dry-run uses FORGEJO_API_MODE=none so this is
# never invoked off-cluster. The token rides as the Authorization header, NOT the URL.
forgejo_ensure_repo() {
  local repo="$1"
  [[ "$FORGEJO_API_MODE" == "rest" ]] || { _log "API_MODE=${FORGEJO_API_MODE}: skipping REST org/repo ensure for '${repo}'"; return 0; }
  command -v curl >/dev/null 2>&1 || _die "curl required for FORGEJO_API_MODE=rest"
  local api="${FORGEJO_BASE_URL%/}/api/v1/orgs/${FORGEJO_ORG}/repos"
  local code
  # Auth header via -H @file (0600 tmpfile) so the token never appears in curl's
  # argv. Body is not sensitive and may stay on the command line.
  code="$(curl -sS -o /dev/null -w '%{http_code}' -m 15 \
      -H @"${AUTH_HDR_FILE}" -H 'Content-Type: application/json' \
      -X POST "$api" \
      -d "{\"name\":\"${repo}\",\"private\":true,\"default_branch\":\"main\"}" 2>/dev/null || echo 000)"
  case "$code" in
    201) _log "created Forgejo repo ${FORGEJO_ORG}/${repo}" ;;
    409) _log "Forgejo repo ${FORGEJO_ORG}/${repo} already exists (409) — OK" ;;
    000) _die "Forgejo REST unreachable at ${api} (tailnet/base-url/TLS?) — fail-closed" ;;
    *)   _die "Forgejo repo-create returned HTTP ${code} for ${FORGEJO_ORG}/${repo}" ;;
  esac
}

# ── DISCOVERY CONTRACT: ensure snapdragon-deploy.yaml + deploy/ exist ────────
# The 13d appset filter requires BOTH. render-tenant-set trees do not carry them,
# so synthesise a minimal, brand-scoped pair when absent. Idempotent: only writes
# when missing, and the content is a pure function of (brand, repo) so re-runs are
# byte-stable. These are DISCOVERY SCAFFOLDS — a live tenant replaces deploy/ with
# the repo's real kustomize overlay; the descriptor marks the repo as catalog-opted-in.
ensure_discovery_contract() {
  local dir="$1" brand="$2" repo="$3"
  if [[ ! -f "${dir}/snapdragon-deploy.yaml" ]]; then
    cat > "${dir}/snapdragon-deploy.yaml" <<EOF
# snapdragon-deploy.yaml — catalog opt-in descriptor (Phase 5 discovery contract).
# Presence of THIS file + a deploy/ kustomize dir is what the brand-repo
# ApplicationSet (specs/cluster/apps/13d-brand-repos.yaml[.hbs]) filters on to
# auto-discover this repo. Synthesised by publish-tenant-set.sh when the rendered
# tree did not already ship one; replace with the repo's real descriptor.
apiVersion: snapdragon.systems/v1
kind: ServiceCatalogEntry
metadata:
  name: ${brand}-${repo}
spec:
  brand: ${brand}
  repo: ${repo}
  deployPath: deploy
EOF
    _log "  + synthesised snapdragon-deploy.yaml (discovery contract)"
  fi
  if [[ ! -d "${dir}/deploy" ]]; then
    mkdir -p "${dir}/deploy"
    cat > "${dir}/deploy/kustomization.yaml" <<EOF
# Minimal discovery-contract kustomize overlay synthesised by publish-tenant-set.sh.
# The brand-repo ApplicationSet points source.path=deploy at this dir. A live tenant
# replaces this with the repo's real manifests (Deployment/Service/etc).
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
commonLabels:
  app.kubernetes.io/part-of: snapdragon.systems
  snapdragon.systems/brand: ${brand}
  snapdragon.systems/repo: ${repo}
EOF
    _log "  + synthesised deploy/kustomization.yaml (discovery contract)"
  fi
}

# ── derive an archetype for a rendered repo dir (best-effort, provenance only) ─
# The rendered tree does not restate its archetype; infer from marker files so the
# provenance manifest can record it. Falls back to "unknown".
infer_archetype() {
  local dir="$1"
  if [[ -f "${dir}/federation-base.js" || -f "${dir}/package.json" && -f "${dir}/build.js" ]]; then echo "angular-mfe"; return; fi
  if [[ -f "${dir}/pom.xml" || -f "${dir}/build.gradle" || -f "${dir}/build.gradle.kts" ]]; then echo "spring-bff"; return; fi
  if [[ -d "${dir}/deploy" && -f "${dir}/deploy/ingress.yaml" ]]; then echo "gateway"; return; fi
  echo "unknown"
}

# recipe sha for an archetype (deterministic; empty if archetype unknown).
recipe_sha() {
  local arch="$1" f="${REPO_ROOT}/templates/archetypes/${arch}/recipe.yaml"
  [[ -f "$f" ]] || { echo ""; return; }
  sha256sum "$f" 2>/dev/null | awk '{print $1}'
}

# ── one repo ─────────────────────────────────────────────────────────────────
publish_one() {
  local dir="$1"
  local base; base="$(basename "$dir")"          # <brand>-<repo>
  # Split brand off the front: brand is a single DNS label; repo is the remainder.
  local brand="${base%%-*}" repo="${base#*-}"
  [[ -n "$brand" && -n "$repo" && "$brand" != "$repo" ]] || { _log "skip '${base}': not a <brand>-<repo> dir"; return 0; }
  if [[ -n "$ONLY" ]]; then
    case ",${ONLY}," in *",${repo},"*) : ;; *) return 0 ;; esac
  fi

  _log "── ${FORGEJO_ORG}/${base} ──"
  ensure_discovery_contract "$dir" "$brand" "$repo"

  # provenance: capture the base commit sha + mode from the rendered tree's own
  # git base if a cache clone is present; else skeleton (no base).
  local arch base_sha="" base_mode="skeleton" rsha=""
  arch="$(infer_archetype "$dir")"
  rsha="$(recipe_sha "$arch")"
  local cache_clone="${REPO_ROOT}/.repo-base/snapdragon-${repo}"
  if [[ -d "${cache_clone}/.git" ]]; then
    base_sha="$(git -C "$cache_clone" rev-parse HEAD 2>/dev/null || echo "")"
    base_mode="overlay"
  fi
  "${SCRIPT_DIR}/provenance.sh" write --repo-dir "$dir" \
      --brand "$brand" --org "$FORGEJO_ORG" --cluster-domain "${CLUSTER_DOMAIN:-}" \
      --repo "$repo" --archetype "$arch" \
      --base-sha "$base_sha" --base-mode "$base_mode" \
      --recipe-sha "$rsha" --generator-commit "$GEN_COMMIT" --engine handlebars

  if [[ -n "${PROVENANCE_SIGNING_KEY:-}" ]]; then
    "${SCRIPT_DIR}/provenance.sh" sign --repo-dir "$dir" --key "${PROVENANCE_SIGNING_KEY}"
  else
    _log "  provenance UNSIGNED (PROVENANCE_SIGNING_KEY unset — production key custody is out-of-band; signing DEFERRED)"
  fi

  # SECRET-SCAN GATE over the whole tree (incl. provenance) BEFORE any push.
  if ! "${SCRIPT_DIR}/secret-scan.sh" "$dir" >&2; then
    _die "secret scanner flagged ${dir} — refusing to publish"
  fi

  # git init/commit (idempotent). Reuse an existing .git so a re-run is a no-op.
  if [[ ! -d "${dir}/.git" ]]; then
    git -C "$dir" init -q -b main
  fi
  git -C "$dir" config user.email "generator@snapdragon.systems" >/dev/null 2>&1 || true
  git -C "$dir" config user.name  "snapdragon-generator" >/dev/null 2>&1 || true
  git -C "$dir" add -A
  if git -C "$dir" diff --cached --quiet 2>/dev/null; then
    _log "  nothing to commit (idempotent — tree already committed)"
  else
    # Deterministic commit env so re-render of the same inputs is stable-ish.
    GIT_AUTHOR_DATE="${SOURCE_DATE_EPOCH:+@${SOURCE_DATE_EPOCH}}" \
    GIT_COMMITTER_DATE="${SOURCE_DATE_EPOCH:+@${SOURCE_DATE_EPOCH}}" \
      git -C "$dir" commit -q -m "publish ${brand}-${repo} tenant tree (snapdragon-generator ${GEN_COMMIT})"
    _log "  committed tenant tree"
  fi

  if [[ "$DRY_RUN" -eq 1 && "$FORGEJO_API_MODE" == "rest" ]]; then
    _log "  --dry-run: skipping org/repo create + push"
    return 0
  fi

  # Create/push under the FULL <brand>-<repo> dir name ($base), NOT the brand-
  # stripped $repo: the 13d brand-repo ApplicationSet filters repositoryMatch
  # "^<BRAND>-" (and the default 13-service-catalog filters "^snapdragon-"), so a
  # repo named "admin-bff-api" would never match "^acme-"/"^snapdragon-" and ArgoCD
  # would discover ZERO Applications. $base == "acme-admin-bff-api" matches. (#3)
  forgejo_ensure_repo "$base"

  local remote; printf -v remote "$FORGEJO_REMOTE_TEMPLATE" "$base"
  git -C "$dir" remote remove origin >/dev/null 2>&1 || true
  git -C "$dir" remote add origin "$remote"

  # FAST-FORWARD-ONLY push. No --force, ever. The token rides as an http header via
  # the GIT_CONFIG_* env (never in argv, never persisted to .git/config or reflog).
  # A non-ff (someone edited tenant-side) fails the push, which we surface fail-
  # closed rather than clobbering.
  _log "  pushing to ${remote} (fast-forward-only)"
  if GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="${_AUTH_HEADER}" \
       git -C "$dir" push origin main 2>&1 | sed 's/^/[publish]   git: /' >&2; then
    _log "  pushed ${base} -> ${FORGEJO_ORG}/${base}@main"
  else
    _die "push refused for ${base} (non-fast-forward or transport error) — NOT force-pushing; reconcile tenant-side edits first"
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────
_log "publish tail: set=${SET_DIR} forgejo=${FORGEJO_BASE_URL} org=${FORGEJO_ORG} api-mode=${FORGEJO_API_MODE} dry-run=${DRY_RUN}"
# Optional CLUSTER_DOMAIN for provenance.tenant.clusterDomain (from the brand YAML
# if given, else env). Best-effort: never fatal.
if [[ -n "$BRAND_YAML" && -f "$BRAND_YAML" ]]; then
  CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(awk '/^domains:/{f=1;next} f&&/^[[:space:]]*-/{gsub(/[[:space:]-]/,"");print;exit}' "$BRAND_YAML" 2>/dev/null || true)}"
fi

n=0
shopt -s nullglob
for d in "${SET_DIR}"/*/; do
  [[ -d "$d" ]] || continue
  d="${d%/}"
  publish_one "$d"
  n=$((n+1))
done
shopt -u nullglob
[[ "$n" -gt 0 ]] || _die "no <brand>-<repo> dirs under ${SET_DIR} (did you run render-tenant-set first?)"
_log "OK: processed ${n} repo dir(s)."
