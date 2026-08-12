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
#   1. DISCOVERY CONTRACT: ensure the tree ships a deploy descriptor
#      (`snapdragon-deploy.yaml` OR `hugmesh-deploy.yaml` — the appsets filter on
#      both) + a `deploy/` kustomize dir (the 13-catalog / 13d-brand-repos appset
#      filter requires BOTH a descriptor and deploy/ to discover the repo). The
#      render-tenant-set trees do NOT carry them, so we synthesise a minimal,
#      brand-scoped pair when NEITHER descriptor spelling is present.
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
#   FORGEJO_BASE_URL  default http://forgejo.hugmesh-pki.svc.cluster.local:3000
#                     (in-cluster svc DNS). From a build host on the tailnet, set
#                     this to the tailnet-reachable Forgejo host (svc.cluster.local
#                     does not resolve off-cluster).
#   FORGEJO_ORG       default hugmesh (the working appset's gitea.owner).
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
#       [--org ORG] [--only a,b] [--dry-run] [--pr] [--ref TAG|SHA]
#
# --dry-run   run steps 1-4 (contract + provenance + scan + local commit) but
#             DO NOT create org/repo or push. Fail-closed token check still applies.
#
# --pr        PR DELIVERY MODE (I5). Instead of the ff-only push to `main`, push
#             the tree to the generator-owned branch `templating/update-<version>`
#             (NEVER main) and create-or-update a Forgejo PR (POST
#             /api/v1/repos/{org}/{repo}/pulls; on 409 the existing open PR for
#             that head branch is PATCHed). <version> = the base ref the tree was
#             rendered at — read from the in-tree `.hugmesh-base-ref` marker
#             (render-repo-tree.sh --ref writes it) or passed with --ref; both
#             present and disagreeing is a fail-closed refusal. The PR branch is
#             REGENERATION OUTPUT: each re-render replaces it (forced refspec on
#             that one branch), which is exactly the "update the PR" semantics —
#             main custody is UNCHANGED (ff-only, never --force, still the
#             default no---pr behavior; tenant-side edits reconcile via the PR).
#             PAT custody unchanged: header via GIT_CONFIG_* env / curl -H @file,
#             never argv/URL/persisted.
#
# --ref TAG|SHA  explicit base-version label for the provenance base.ref stamp +
#             the --pr branch name, when the tree carries no marker (or to
#             cross-check the marker — mismatch refuses).
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
BRAND_YAML="" ONLY="" DRY_RUN=0 ORG_OVERRIDE="" PR_MODE=0 REF_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --brand-yaml) BRAND_YAML="$2"; shift 2 ;;
    --org)        ORG_OVERRIDE="$2"; shift 2 ;;
    --only)       ONLY="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --pr)         PR_MODE=1; shift ;;
    --ref)        REF_OVERRIDE="$2"; shift 2 ;;
    *) _die "unknown argument: $1" ;;
  esac
done
# Same ref shape rule as render-repo-tree.sh/pull-repo-base.sh --ref.
if [[ -n "$REF_OVERRIDE" ]]; then
  [[ "$REF_OVERRIDE" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,120}$ && "$REF_OVERRIDE" != *..* ]] \
    || _die "invalid --ref '${REF_OVERRIDE}' (want a tag/branch/sha: [A-Za-z0-9._/-], no '..')"
fi
# --pr needs jq up front (PR JSON payload build + open-PR lookup) — fail-closed
# before any network/push, same posture as the token check below.
if [[ "$PR_MODE" -eq 1 ]]; then
  command -v jq >/dev/null 2>&1 || _die "jq required for --pr (PR payload build / open-PR lookup) — fail-closed"
fi
[[ -d "$SET_DIR" ]] || _die "rendered-set-dir '$SET_DIR' is not a directory"
SET_DIR="$(cd "$SET_DIR" && pwd)"

# ── config ───────────────────────────────────────────────────────────────────
FORGEJO_BASE_URL="${FORGEJO_BASE_URL:-http://forgejo.hugmesh-pki.svc.cluster.local:3000}"
FORGEJO_ORG="${ORG_OVERRIDE:-${FORGEJO_ORG:-hugmesh}}"
FORGEJO_API_MODE="${FORGEJO_API_MODE:-rest}"
FORGEJO_REMOTE_TEMPLATE="${FORGEJO_REMOTE_TEMPLATE:-${FORGEJO_BASE_URL%/}/${FORGEJO_ORG}/%s.git}"
# Org name shape guard (used in the REST URL + remote path).
[[ "$FORGEJO_ORG" =~ ^[A-Za-z0-9._-]{1,63}$ ]] || _die "invalid FORGEJO_ORG '$FORGEJO_ORG'"

# Base-clone cache root for the Phase-7 foreign-base launder gate + provenance
# base-sha derivation. Honors the SAME knob the resolver (pull-repo-base.sh) uses,
# so publish keys off the exact cache the render consumed — the old hardcoded
# ${REPO_ROOT}/.repo-base peek silently attested a stale/unrelated sha whenever
# REPO_BASE_CACHE (or a *_BASE_DIR override) pointed elsewhere.
REPO_BASE_CACHE="${REPO_BASE_CACHE:-${REPO_ROOT}/.repo-base}"

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
_cleanup() {
  [[ -n "${AUTH_HDR_FILE:-}" ]] && rm -f "${AUTH_HDR_FILE}" 2>/dev/null
  [[ -n "${PR_RESP_FILE:-}" ]] && rm -f "${PR_RESP_FILE}" 2>/dev/null
  return 0
}
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

# ── Forgejo REST: create-or-update the PR for a templating/update-* branch ───
# POST /repos/{org}/{repo}/pulls; a 409 means a PR for that head branch already
# exists — look it up in the open list and PATCH title/body (the branch push that
# preceded this call already updated the PR's CONTENT). Auth rides the SAME
# 0600-header-file custody as forgejo_ensure_repo: never argv, never the URL.
forgejo_ensure_pr() {
  local repo="$1" branch="$2" ver="$3"
  [[ "$FORGEJO_API_MODE" == "rest" ]] || { _log "API_MODE=${FORGEJO_API_MODE}: skipping Forgejo PR ensure for '${repo}'"; return 0; }
  command -v curl >/dev/null 2>&1 || _die "curl required for FORGEJO_API_MODE=rest"
  local api="${FORGEJO_BASE_URL%/}/api/v1/repos/${FORGEJO_ORG}/${repo}/pulls"
  local title="templating: update ${repo} to base ${ver}"
  local body="Automated tenant-set re-render at base ref \`${ver}\` (hugmesh-generator ${GEN_COMMIT}). The head branch is regenerated whole on every re-render at this ref; review and merge into main (main stays fast-forward-only, direct-push default unchanged)."
  local payload; payload="$(jq -n --arg t "$title" --arg h "$branch" --arg b "$body" \
      '{title: $t, head: $h, base: "main", body: $b}')"
  PR_RESP_FILE="${PR_RESP_FILE:-$(umask 077 && mktemp)}"
  local code
  code="$(curl -sS -o "$PR_RESP_FILE" -w '%{http_code}' -m 15 \
      -H @"${AUTH_HDR_FILE}" -H 'Content-Type: application/json' \
      -X POST "$api" -d "$payload" 2>/dev/null || echo 000)"
  case "$code" in
    201) _log "  created Forgejo PR (${branch} -> main) for ${FORGEJO_ORG}/${repo}" ;;
    409)
      # Paginate the open-PR list (busy repos can hold >50 open PRs; a first-page
      # miss must not masquerade as the phantom-409 case). Bounded at 10 pages.
      local idx="" page pg_json
      for page in 1 2 3 4 5 6 7 8 9 10; do
        pg_json="$(curl -sS -m 15 -H @"${AUTH_HDR_FILE}" \
              "${api}?state=open&limit=50&page=${page}" 2>/dev/null)" || pg_json=""
        [[ -z "$pg_json" || "$pg_json" == "[]" ]] && break
        idx="$(jq -r --arg h "$branch" \
              '[ .[] | select(.head.ref == $h) ][0].number // empty' <<<"$pg_json")"
        [[ -n "$idx" ]] && break
        # short page = last page
        [[ "$(jq 'length' <<<"$pg_json")" -lt 50 ]] && break
      done
      [[ -n "$idx" && "$idx" =~ ^[0-9]+$ ]] \
        || _die "Forgejo says a PR for head '${branch}' exists (409) but the open-PR list has none — cannot update, resolve manually (fail-closed)"
      local pcode
      pcode="$(curl -sS -o "$PR_RESP_FILE" -w '%{http_code}' -m 15 \
          -H @"${AUTH_HDR_FILE}" -H 'Content-Type: application/json' \
          -X PATCH "${api}/${idx}" \
          -d "$(jq -n --arg t "$title" --arg b "$body" '{title: $t, body: $b}')" 2>/dev/null || echo 000)"
      case "$pcode" in
        200|201) _log "  updated existing Forgejo PR #${idx} (${branch} -> main) for ${FORGEJO_ORG}/${repo} (content already refreshed by the branch push)" ;;
        *) _die "Forgejo PR update (PATCH ${api}/${idx}) returned HTTP ${pcode} — fail-closed" ;;
      esac ;;
    000) _die "Forgejo REST unreachable at ${api} (tailnet/base-url/TLS?) — fail-closed" ;;
    *)   _die "Forgejo PR create returned HTTP ${code} for ${FORGEJO_ORG}/${repo} (branch ${branch})" ;;
  esac
}

# ── DISCOVERY CONTRACT: ensure a deploy descriptor + deploy/ exist ───────────
# The 13d appset filter requires a descriptor AND deploy/. render-tenant-set trees
# do not carry them, so synthesise a minimal, brand-scoped pair when absent.
# Idempotent: only writes when missing, and the content is a pure function of
# (brand, repo) so re-runs are byte-stable. These are DISCOVERY SCAFFOLDS — a live
# tenant replaces deploy/ with the repo's real kustomize overlay; the descriptor
# marks the repo as catalog-opted-in.
#
# EITHER descriptor spelling satisfies the contract (13d filters on both since the
# HugMesh rebrand left `hugmesh-deploy.yaml` in some org repos and
# `snapdragon-deploy.yaml` in others). A tree that already ships EITHER name is
# left alone — synthesising a second descriptor next to an existing one would put
# two conflicting contracts in one repo, and the appset would still emit exactly
# one Application, so the extra file is pure drift. New scaffolds keep the legacy
# spelling: it is the name templates/archetypes/generator/recipe.yaml records as
# frozen and the one catalog/snapdragon-deploy.example.yaml documents.
ensure_discovery_contract() {
  local dir="$1" brand="$2" repo="$3"
  if [[ ! -f "${dir}/snapdragon-deploy.yaml" && ! -f "${dir}/hugmesh-deploy.yaml" ]]; then
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
  app.kubernetes.io/part-of: hugmesh.systems
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
  # ORDER-SAFE: the two SPECIFIC markers below must fire BEFORE the broader
  # class rules they would otherwise be swallowed by.
  #   * a HOST tree carries federation-base.js at root exactly like an MFE, so
  #     its unambiguous marker (the static remote-manifest floor) is tested
  #     BEFORE the angular-mfe rule;
  #   * the remote-fragment tree is a Maven build (pom.xml) exactly like a BFF,
  #     so its unambiguous marker (the systems.hugmesh.fragment source
  #     package) is tested BEFORE the pom.xml spring-bff rule.
  if [[ -f "${dir}/src/assets/federation.manifest.json" ]]; then echo "angular-host"; return; fi
  if [[ -d "${dir}/src/main/java/systems/hugmesh/fragment" ]]; then echo "remote-fragment"; return; fi
  if [[ -f "${dir}/federation-base.js" || -f "${dir}/package.json" && -f "${dir}/build.js" ]]; then echo "angular-mfe"; return; fi
  if [[ -f "${dir}/pom.xml" || -f "${dir}/build.gradle" || -f "${dir}/build.gradle.kts" ]]; then echo "spring-bff"; return; fi
  if [[ -d "${dir}/deploy" && -f "${dir}/deploy/ingress.yaml" ]]; then echo "gateway"; return; fi
  # The generator itself (I5): its sed-CRD entrypoint is the unambiguous marker.
  if [[ -f "${dir}/generate-brand-repos.sh" ]]; then echo "generator"; return; fi
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

  # ── VERSIONED-RENDER ref (I5) ───────────────────────────────────────────────
  # render-repo-tree.sh --ref writes a one-line `.hugmesh-base-ref` marker into
  # the tree (same travels-with-the-tree idiom as the base-origin marker). It
  # feeds the provenance base.ref stamp and the --pr branch name. An explicit
  # --ref here must AGREE with a present marker — a disagreement means the
  # operator is publishing a tree rendered at a different version (fail-closed).
  local base_ref=""
  if [[ -f "${dir}/.hugmesh-base-ref" ]]; then
    base_ref="$(head -n1 "${dir}/.hugmesh-base-ref" | tr -d '\r')"
    [[ "$base_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,120}$ && "$base_ref" != *..* ]] \
      || _die "in-tree .hugmesh-base-ref marker in ${base} is not a tag/branch/sha shape — refusing (fail-closed)"
  fi
  if [[ -n "$REF_OVERRIDE" ]]; then
    if [[ -n "$base_ref" && "$base_ref" != "$REF_OVERRIDE" ]]; then
      _die "--ref '${REF_OVERRIDE}' disagrees with ${base}'s own base-ref marker '${base_ref}' — render/publish version drift, refusing"
    fi
    # A tree with NO marker was not rendered at any pinned ref — stamping the
    # operator's --ref into provenance base.ref would be an unverified claim.
    # Fail closed: re-render with --ref so the marker travels with the tree.
    [[ -n "$base_ref" ]] \
      || _die "--ref '${REF_OVERRIDE}' but ${base} carries no .hugmesh-base-ref marker (tree was rendered unpinned) — re-render with 'render-repo-tree.sh --ref ${REF_OVERRIDE}' so provenance base.ref is fetch-proven, not claimed"
  fi

  # provenance: capture the base commit sha + mode from the rendered tree's own
  # git base if a cache clone is present; else skeleton (no base).
  local arch base_sha="" base_mode="skeleton" rsha="" origin_mesh=""
  arch="$(infer_archetype "$dir")"
  rsha="$(recipe_sha "$arch")"

  # ── Phase 7 LAUNDER-REFUSAL: never push a FOREIGN base that A's inbound gate
  #    did not admit ────────────────────────────────────────────────────────────
  # Foreign origin is detected by TWO signals, in priority order:
  #   (1) DURABLE, PRIMARY — the in-tree base-origin marker (.hugmesh-base-origin.json)
  #       render-repo-tree.sh --foreign-mesh writes into a foreign-overlay BRAND_OUT.
  #       It TRAVELS WITH THE TREE, so it SURVIVES a REPO_BASE_CACHE purge — closing
  #       the residual medium where deleting the foreign cache dir after render but
  #       before publish made this tail treat foreign-DERIVED bytes as own-mesh and
  #       re-sign+push them with NO stamp re-verify.
  #   (2) CORROBORATING, SECONDARY — a foreign cache clone at
  #       ${REPO_BASE_CACHE}/foreign/<mesh>/hugmesh-<repo> (pull-repo-base.sh
  #       --foreign). It can be removed; the marker cannot (it is inside the tree we
  #       are about to publish).
  # If EITHER fires, publishing REQUIRES the base's inbound admission STAMP — the
  # '.snapdragon-mesh-admitted' receipt scripts/ingest-foreign-base.sh promotes into
  # its quarantine snapshot — present for this mesh AND re-verified RIGHT NOW:
  # verified=1, mesh-id match, well-formed immutable pin, and a recomputed canonical
  # tree digest of the admitted snapshot == the stamped tree-sha256 (so a snapshot
  # mutated after admission is caught). A missing / stale / forged / mutated stamp is
  # _die — unverified foreign code is NEVER re-pushed to tenant Forgejo wearing OUR
  # fresh provenance. A tree carrying the marker can NEVER be published without a valid
  # re-verified stamp, even if the cache is gone. A planted marker only makes publish
  # MORE strict (it forces the stamp requirement), never less. This is a fail-closed
  # belt on top of the render-time gate (render-repo-tree.sh --foreign-mesh runs the
  # SAME gate before it emits BRAND_OUT); the publish tail refuses independently.
  #
  # DURABLE marker (primary): parse + shape-validate our own outbound base-origin
  # provenance. Present ONLY on a foreign-overlay tree; absent for own-mesh/skeleton.
  local marker="${dir}/.hugmesh-base-origin.json"
  local marker_mesh="" marker_pin="" marker_tree=""
  if [[ -f "$marker" ]]; then
    command -v jq >/dev/null 2>&1 || _die "jq required to parse foreign base-origin marker ${marker} — fail-closed"
    jq -e . "$marker" >/dev/null 2>&1 || _die "base-origin marker ${marker} is not valid JSON — refusing (launder-refusal)"
    marker_mesh="$(jq -r '.originMesh   // empty' "$marker" 2>/dev/null)"
    marker_pin="$( jq -r '.pinnedDigest // empty' "$marker" 2>/dev/null)"
    marker_tree="$(jq -r '.treeSha256   // empty' "$marker" 2>/dev/null)"
    [[ "$marker_mesh" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
      || _die "base-origin marker originMesh '${marker_mesh}' is not a DNS label — refusing (launder-refusal)"
    [[ "$marker_pin" =~ ^[0-9a-f]{40}$ || "$marker_pin" =~ ^[0-9a-f]{64}$ ]] \
      || _die "base-origin marker pinnedDigest '${marker_pin}' is not a 40/64-hex immutable digest — refusing (launder-refusal)"
    [[ "$marker_tree" =~ ^[0-9a-f]{64}$ ]] \
      || _die "base-origin marker treeSha256 '${marker_tree}' is not a 64-hex tree digest — refusing (launder-refusal)"
  fi
  # CORROBORATING foreign cache clone (secondary) — same ambiguity guards as before.
  local fd foreign_dir=""
  for fd in "${REPO_BASE_CACHE}"/foreign/*/"hugmesh-${repo}"; do
    [[ -d "$fd" ]] || continue
    [[ -z "$foreign_dir" ]] \
      || _die "multiple foreign cache entries for hugmesh-${repo} (${foreign_dir}, ${fd}) — ambiguous base origin; purge the stale one before publishing"
    foreign_dir="$fd"
  done
  local cache_clone="${REPO_BASE_CACHE}/hugmesh-${repo}"
  local foreign_cache_mesh=""
  [[ -n "$foreign_dir" ]] && foreign_cache_mesh="$(basename "$(dirname "$foreign_dir")")"

  # Resolve the foreign origin mesh from the DURABLE marker FIRST, corroborated by the
  # cache; else fall back to the cache alone (pre-marker trees). Any own-mesh cache
  # clone co-existing with a foreign signal is ambiguous -> refuse.
  if [[ -n "$marker_mesh" ]]; then
    origin_mesh="$marker_mesh"
    [[ -d "${cache_clone}/.git" ]] \
      && _die "foreign base-origin marker present AND an own-mesh cache clone exists for hugmesh-${repo} — ambiguous base origin (provenance would lie); purge one before publishing"
    if [[ -n "$foreign_cache_mesh" && "$foreign_cache_mesh" != "$origin_mesh" ]]; then
      _die "base-origin marker mesh '${origin_mesh}' != foreign cache mesh '${foreign_cache_mesh}' for hugmesh-${repo} — ambiguous base origin; refusing (launder-refusal)"
    fi
  elif [[ -n "$foreign_dir" ]]; then
    [[ -d "${cache_clone}/.git" ]] \
      && _die "BOTH an own-mesh and a foreign base cache entry exist for hugmesh-${repo} — ambiguous base origin (provenance would lie); purge one before publishing"
    origin_mesh="$foreign_cache_mesh"
    [[ "$origin_mesh" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
      || _die "foreign cache mesh dir '${origin_mesh}' is not a DNS label"
  fi

  if [[ -n "$origin_mesh" ]]; then
    # Locate THIS mesh's inbound admission stamp — the '.snapdragon-mesh-admitted'
    # receipt scripts/ingest-foreign-base.sh promotes into its per-run quarantine
    # snapshot (pull-repo-base.sh --foreign leaves it under
    # ${REPO_BASE_CACHE}/.mesh-quarantine/<repo>/<mesh>-<digest16>/). The marker (in
    # the tree) and/or the foreign clone is the DURABLE origin signal; THIS stamp is
    # the receipt that must accompany it. Read the pin FROM the stamp (git-independent
    # — the practical foreign path pins a synthetic immutable digest via *_BASE_DIR,
    # not a git HEAD). If the cache (incl. this quarantine) was purged, no stamp is
    # found and we _die below — a marker-bearing tree is NEVER laundered stamp-less.
    local stamp="" s
    for s in "${REPO_BASE_CACHE}/.mesh-quarantine/${repo}/${origin_mesh}"-*/.snapdragon-mesh-admitted; do
      [[ -f "$s" ]] || continue
      [[ -z "$stamp" ]] \
        || _die "multiple admission stamps for mesh '${origin_mesh}' repo '${repo}' — ambiguous; purge the stale quarantine snapshot before publishing"
      stamp="$s"
    done
    [[ -n "$stamp" ]] \
      || _die "foreign base for mesh '${origin_mesh}' repo '${repo}' has NO .snapdragon-mesh-admitted stamp from ingest-foreign-base.sh under ${REPO_BASE_CACHE}/.mesh-quarantine/${repo}/ — REFUSING to publish ${base} (unverified foreign code is never pushed onward)"
    local admit_snap; admit_snap="$(dirname "$stamp")"
    local s_mesh s_pin s_tree s_ver
    s_mesh="$(sed -n 's/^mesh-id=//p'       "$stamp" | head -n1)"
    s_pin="$( sed -n 's/^pinned-digest=//p' "$stamp" | head -n1)"
    s_tree="$(sed -n 's/^tree-sha256=//p'   "$stamp" | head -n1)"
    s_ver="$( sed -n 's/^verified=//p'      "$stamp" | head -n1)"
    [[ "$s_ver" == "1" ]] \
      || _die "admission stamp for ${origin_mesh} is not verified=1 — refusing to publish (launder-refusal)"
    [[ "$s_mesh" == "$origin_mesh" ]] \
      || _die "admission stamp mesh-id '${s_mesh}' != foreign cache mesh '${origin_mesh}' — refusing (launder-refusal)"
    [[ "$s_pin" =~ ^[0-9a-f]{40}$ || "$s_pin" =~ ^[0-9a-f]{64}$ ]] \
      || _die "admission stamp pinned-digest '${s_pin}' is not a 40/64-hex immutable digest — refusing (launder-refusal)"
    # DURABLE-MARKER CROSS-BIND: when the in-tree marker is present it MUST AGREE with
    # the re-verified stamp (same pin + same admitted tree digest), so a planted marker
    # can never point publish at an unrelated mesh's stamp — it only ever tightens.
    if [[ -n "$marker_mesh" ]]; then
      [[ "$marker_pin" == "$s_pin" ]] \
        || _die "base-origin marker pinnedDigest '${marker_pin}' != admission stamp pinned-digest '${s_pin}' — refusing (launder-refusal)"
      [[ "$marker_tree" == "$s_tree" ]] \
        || _die "base-origin marker treeSha256 '${marker_tree}' != admission stamp tree-sha256 '${s_tree}' — refusing (launder-refusal)"
    fi
    # Recompute the admitted snapshot's canonical tree digest with the gate's OWN
    # helper (sourced in a subshell so the gate's 'set -uo pipefail' can NEVER leak
    # in and disable our errexit). Must equal the stamped tree-sha256 or the snapshot
    # was mutated after admission -> refuse.
    local recomputed
    recomputed="$( ( . "${SCRIPT_DIR}/ingest-foreign-base.sh" >/dev/null 2>&1; _fib_tree_digest "$admit_snap" ) 2>/dev/null || echo "")"
    [[ -n "$recomputed" && "$recomputed" == "$s_tree" ]] \
      || _die "admitted snapshot ${admit_snap} tree digest (${recomputed:-<none>}) != stamped tree-sha256 (${s_tree}) — snapshot mutated after admission, refusing (launder-refusal)"
    base_sha="$s_pin"
    base_mode="foreign-overlay"
    _log "  foreign base admission re-verified (mesh=${origin_mesh} sha=${base_sha}, stamp tree-digest OK, in-tree marker=${marker_mesh:+present}) — provenance records base.originMesh"
  elif [[ -d "${cache_clone}/.git" ]]; then
    base_sha="$(git -C "$cache_clone" rev-parse HEAD 2>/dev/null || echo "")"
    base_mode="overlay"
  fi

  # base.originMesh is emitted ONLY for a foreign-overlay base (empty otherwise, so
  # own-mesh/skeleton manifests stay byte-identical to pre-Phase-7). base.ref is
  # likewise emitted ONLY when a versioned render recorded one (I5).
  local -a origin_args=()
  [[ -n "$origin_mesh" ]] && origin_args=(--origin-mesh "$origin_mesh")
  local -a base_ref_args=()
  [[ -n "$base_ref" ]] && base_ref_args=(--base-ref "$base_ref")
  "${SCRIPT_DIR}/provenance.sh" write --repo-dir "$dir" \
      --brand "$brand" --org "$FORGEJO_ORG" --cluster-domain "${CLUSTER_DOMAIN:-}" \
      --repo "$repo" --archetype "$arch" \
      --base-sha "$base_sha" --base-mode "$base_mode" \
      "${origin_args[@]}" \
      ${base_ref_args[@]+"${base_ref_args[@]}"} \
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
  git -C "$dir" config user.email "generator@hugmesh.systems" >/dev/null 2>&1 || true
  git -C "$dir" config user.name  "hugmesh-generator" >/dev/null 2>&1 || true
  git -C "$dir" add -A
  if git -C "$dir" diff --cached --quiet 2>/dev/null; then
    _log "  nothing to commit (idempotent — tree already committed)"
  else
    # Deterministic commit env so re-render of the same inputs is stable-ish.
    GIT_AUTHOR_DATE="${SOURCE_DATE_EPOCH:+@${SOURCE_DATE_EPOCH}}" \
    GIT_COMMITTER_DATE="${SOURCE_DATE_EPOCH:+@${SOURCE_DATE_EPOCH}}" \
      git -C "$dir" commit -q -m "publish ${brand}-${repo} tenant tree (hugmesh-generator ${GEN_COMMIT})"
    _log "  committed tenant tree"
  fi

  if [[ "$DRY_RUN" -eq 1 && "$FORGEJO_API_MODE" == "rest" ]]; then
    _log "  --dry-run: skipping org/repo create + push"
    return 0
  fi

  # Create/push under the FULL <brand>-<repo> dir name ($base), NOT the brand-
  # stripped $repo: the 13d brand-repo ApplicationSet filters repositoryMatch
  # "^<BRAND>-" (and the default 13-service-catalog filters "^hugmesh-"), so a
  # repo named "admin-bff-api" would never match "^acme-"/"^hugmesh-" and ArgoCD
  # would discover ZERO Applications. $base == "acme-admin-bff-api" matches. (#3)
  forgejo_ensure_repo "$base"

  local remote; printf -v remote "$FORGEJO_REMOTE_TEMPLATE" "$base"
  git -C "$dir" remote remove origin >/dev/null 2>&1 || true
  git -C "$dir" remote add origin "$remote"

  if [[ "$PR_MODE" -eq 1 ]]; then
    # ── PR DELIVERY (I5): branch push + create-or-update PR — NEVER main ──────
    [[ -n "$base_ref" ]] \
      || _die "--pr for ${base} needs a base version: render with --ref (writes the in-tree .hugmesh-base-ref marker) or pass --ref here — the PR branch name embeds it (templating/update-<version>)"
    local ver="${base_ref//\//-}"           # branch-name-safe version component
    local pr_branch="templating/update-${ver}"
    # Namespace hard-guard: the forced refspec below may ONLY ever target the
    # generator-owned templating/update-* namespace — main is unreachable here.
    case "$pr_branch" in
      templating/update-?*) : ;;
      *) _die "internal: PR branch '${pr_branch}' escaped the templating/update-* namespace — refusing" ;;
    esac
    # FORCED refspec on the PR branch only (the '+'): each publish run commits a
    # FRESH regeneration history (git init above), so consecutive updates of the
    # same-version branch are non-ff BY CONSTRUCTION — "replace the branch" IS
    # the PR-update semantics. This does NOT touch main custody: main is never
    # pushed in --pr mode, and the default (no --pr) path below stays ff-only
    # with no --force, exactly as before. Token custody identical (env header).
    _log "  pushing PR branch ${pr_branch} -> ${remote} (generator-owned regeneration branch; main untouched)"
    if GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="${_AUTH_HEADER}" \
         git -C "$dir" push origin "+HEAD:refs/heads/${pr_branch}" 2>&1 | sed 's/^/[publish]   git: /' >&2; then
      _log "  pushed ${base} -> ${FORGEJO_ORG}/${base}@${pr_branch}"
    else
      _die "PR-branch push failed for ${base} (transport error) — nothing merged, main untouched"
    fi
    forgejo_ensure_pr "$base" "$pr_branch" "$base_ref"
  else
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
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────
_log "publish tail: set=${SET_DIR} forgejo=${FORGEJO_BASE_URL} org=${FORGEJO_ORG} api-mode=${FORGEJO_API_MODE} dry-run=${DRY_RUN} pr=${PR_MODE}${REF_OVERRIDE:+ ref=${REF_OVERRIDE}}"
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
