#!/usr/bin/env bash
# clone-all-repos.sh — clone (or update) every Snapdragon-Systems repo the local
# docker-compose stack builds from, into a single source dir (default ./.stack-src).
#
# Assumes you are authenticated to GitHub (gh CLI logged in, or a git credential
# helper / token), OR on the internal VPN with the GitLab mirror reachable.
# Idempotent: pulls (fast-forward) a repo that is already present, clones a fresh
# one otherwise. Safe to re-run.
#
# Used by `make stack-up` (Linux) and the Windows orchestrator
# (scripts/stack-up.ps1 / the bootstrap container) before `docker compose build`.
#
# Env knobs:
#   STACK_SRC   (default ./.stack-src)  where to clone the repos
#   GIT_BASE    (default https://github.com/Snapdragon-Systems)  clone base URL.
#               Point at the internal mirror on the VPN, e.g.
#               GIT_BASE=https://gitlab.hugmesh.systems/hugmesh
#   GIT_REF     (default main)  branch/tag to check out
#   USE_GH      (default auto)  "1" forces `gh repo clone`, "0" forces git clone
#   GH_TOKEN / GITHUB_TOKEN     if set, used for an https token clone (CI / Windows)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
STACK_SRC="${STACK_SRC:-${REPO_ROOT}/.stack-src}"
GIT_BASE="${GIT_BASE:-https://github.com/Snapdragon-Systems}"
GIT_REF="${GIT_REF:-main}"
USE_GH="${USE_GH:-auto}"

# The full first-party repo set the compose stack builds. hugmesh-generator
# itself is the repo this script ships in — it carries the cluster manifests but
# is NOT a built container, so it is intentionally absent here.
#
# These names are BOTH the remote repo name AND the directory name compose
# resolves as a build context (${STACK_SRC}/<name> in tests/stack/compose.local.yaml
# + compose.m2-local.yaml), so the two must agree exactly — a mismatch fails the
# build with "unable to prepare context: path ... not found" before a single
# image starts. studio/tests/test_local_mesh_source_axis.py pins that agreement.
REPOS=(
  # ── Gateways (ONE image, run 3x as pki/be/fe via SPRING_APPLICATION_NAME) ──
  hugmesh-gateway
  # ── Spring backend services ──
  hugmesh-federation-api
  hugmesh-admin-bff-api
  hugmesh-mod-bff-api
  hugmesh-user-bff-api
  hugmesh-actions
  # ── Static fragment fleet (sync image; the nginx image is public upstream) ──
  hugmesh-remote-fragment
  # ── Angular host + federated remotes (each Dockerfile -> nginx) ──
  # NOTE: the host shell's repo is hugmesh-host-shell — it did NOT follow the
  # mechanical snapdragon-* -> hugmesh-* rename (it was `snapdragon.systems`, a
  # domain-shaped name, and there is no `hugmesh.systems` repo).
  hugmesh-host-shell
  hugmesh-admin-ui
  hugmesh-mod-ui
  hugmesh-user-ui
  hugmesh-login-ui
  hugmesh-mastodon-ui
  hugmesh-matrix-ui
  hugmesh-api-docs
  # ── forum/wiki/owncast/tube/character-studio UI+BFF pairs ──
  hugmesh-forum-ui
  hugmesh-forum-bff-api
  hugmesh-wiki-ui
  hugmesh-wiki-bff-api
  hugmesh-owncast-ui
  hugmesh-owncast-bff-api
  hugmesh-tube-ui
  hugmesh-tube-bff-api
  hugmesh-character-studio-ui
  # character-forge is ONE multi-surface repo (Spring BFF at the root + godot/ +
  # frontend/): the compose stack builds the BFF image from the repo root and the
  # UI image from its frontend/ subdir — no separate -ui repo to clone. The repo
  # was CREATED after the org-wide sweep as snapdragon-character-forge-bff-api and
  # was renamed to hugmesh-character-forge-bff-api by the follow-up rebrand, so the
  # name IS mechanical now (docs/XR-CHAT.md).
  hugmesh-character-forge-bff-api
)

echo "==> Cloning ${#REPOS[@]} HugMesh repos into ${STACK_SRC}"
echo "    base=${GIT_BASE} ref=${GIT_REF}"
mkdir -p "${STACK_SRC}"

# Decide the clone mechanism once.
have_gh() { command -v gh >/dev/null 2>&1; }
if [ "${USE_GH}" = "auto" ]; then
  if have_gh && gh auth status >/dev/null 2>&1; then USE_GH=1; else USE_GH=0; fi
fi

clone_url() { # repo -> full clone URL (token-injected if a token is present)
  local repo="$1" url="${GIT_BASE}/$1.git"
  local tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -n "${tok}" ] && [[ "${url}" == https://* ]]; then
    # https://oauth2:<token>@host/... — works for GitHub and GitLab https.
    printf 'https://oauth2:%s@%s' "${tok}" "${url#https://}"
  else
    printf '%s' "${url}"
  fi
}

# ── pre-rename checkout migration ─────────────────────────────────────────────
# The org renamed every service repo snapdragon-* -> hugmesh-* (and
# snapdragon.systems -> hugmesh-host-shell). A ./.stack-src populated before that
# holds the old DIRECTORY names, which compose no longer resolves. Rename in
# place rather than re-clone: same git objects, no multi-GB re-download, and the
# stale dirs don't linger as dead weight. Only ever renames INTO a free name, so
# a tree that already has both is left untouched.
legacy_name() { # canonical name -> pre-rename name ("" if there is none)
  case "$1" in
    hugmesh-host-shell) printf 'snapdragon.systems' ;;
    hugmesh-*)          printf 'snapdragon-%s' "${1#hugmesh-}" ;;
    *)                  printf '' ;;
  esac
}

migrate_legacy_dir() { # canonical name
  local new="$1" old
  old="$(legacy_name "${new}")"
  [ -n "${old}" ]                       || return 0
  [ -d "${STACK_SRC}/${old}/.git" ]     || return 0
  [ ! -e "${STACK_SRC}/${new}" ]        || return 0
  echo "  ~~ ${old} -> ${new}: renaming pre-rename checkout in place"
  mv "${STACK_SRC}/${old}" "${STACK_SRC}/${new}"
  # Re-point at the canonical URL (the old one only resolves via GitHub's rename
  # redirect). Deliberately NOT the token-injecting helper above: that would
  # persist a credential into .git/config.
  git -C "${STACK_SRC}/${new}" remote set-url origin "${GIT_BASE}/${new}.git" 2>/dev/null || true
}

ok=0 fail=0
for repo in "${REPOS[@]}"; do
  migrate_legacy_dir "${repo}"
  dest="${STACK_SRC}/${repo}"
  if [ -d "${dest}/.git" ]; then
    echo "  -- ${repo}: present, updating (${GIT_REF})"
    if git -C "${dest}" fetch --quiet --depth 1 origin "${GIT_REF}" 2>/dev/null \
       && git -C "${dest}" checkout --quiet "${GIT_REF}" 2>/dev/null \
       && git -C "${dest}" reset --hard --quiet "origin/${GIT_REF}" 2>/dev/null; then
      ok=$((ok+1))
    else
      echo "     WARN: could not update ${repo} (kept existing checkout)" >&2
      fail=$((fail+1))
    fi
    continue
  fi

  echo "  ++ ${repo}: cloning"
  if [ "${USE_GH}" = 1 ] && [ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
    # gh honours the logged-in auth; honour a non-default GIT_BASE org too.
    org="${GIT_BASE##*/}"
    if gh repo clone "${org}/${repo}" "${dest}" -- --depth 1 --branch "${GIT_REF}" >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      echo "     ERROR: gh clone failed for ${repo}" >&2; fail=$((fail+1))
    fi
  else
    if git clone --depth 1 --branch "${GIT_REF}" "$(clone_url "${repo}")" "${dest}" >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      echo "     ERROR: git clone failed for ${repo} (auth/VPN? GIT_BASE=${GIT_BASE})" >&2
      fail=$((fail+1))
    fi
  fi
done

# Post-clone patch pass — the COMMITTED, general mechanism for the small source
# tweaks the LOCAL stack needs on the cloned trees (idempotent + CRLF-tolerant;
# see scripts/patch-stack-src.sh). Runs EVERY time because the update path
# above `reset --hard`s each checkout, wiping any previously applied patch.
bash "${HERE}/patch-stack-src.sh" "${STACK_SRC}"

echo "==> Done: ${ok} ok, ${fail} failed/skipped, in ${STACK_SRC}"
if [ "${fail}" -gt 0 ]; then
  echo "    Some repos did not clone. Check GitHub auth (gh auth login) or the"
  echo "    internal VPN + GIT_BASE, then re-run. Existing checkouts were kept." >&2
  exit 1
fi
