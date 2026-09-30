#!/usr/bin/env bash
# clone-all-repos.sh — clone (or update) every hugmesh repo the local
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
#   GIT_BASE    (default https://github.com/hugmesh)  clone base URL.
#               Point at the internal mirror on the VPN, e.g.
#               GIT_BASE=https://gitlab.hugmesh.net/hugmesh
#   GIT_REF     (default main)  branch/tag to check out
#   USE_GH      (default auto)  "1" puts `gh repo clone` FIRST, "0" removes gh
#               from the list entirely. In both cases the mechanism is still
#               PROVED against one repo before the run commits to it — "gh is
#               logged in" has never meant "gh can read these repos".
#   GH_TOKEN / GITHUB_TOKEN     if set, TRIED FIRST for an https token clone
#               (CI / Windows) — and dropped for the next mechanism if it cannot
#               actually read the org.
#   STACK_CLONE_PROBE_REPO      (default: the first entry of REPOS) the one repo
#               the credential probe reads. Nothing else uses it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
STACK_SRC="${STACK_SRC:-${REPO_ROOT}/.stack-src}"
# The GitHub org move LANDED; see docs/ORG-MOVE-TODO.md.
GIT_BASE="${GIT_BASE:-https://github.com/hugmesh}"
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
  # NOTE: the host shell's repo is hugmesh-host-shell — its pre-rename name was
  # domain-shaped rather than `<brand>-<service>`, so it did not follow the
  # mechanical prefix rename. legacy_name() below carries the mapping.
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
  # The phpBB IMAGE repo: official phpBB 3.3 + the `hugmesh/forumapi` headless
  # extension, which is what hugmesh-forum-bff-api actually calls
  # (/api/v1/hugmesh/**). compose.alt-social.yaml builds the `phpbb` service
  # from this context, so the phpbb profile cannot come up without it.
  hugmesh-forum-api
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
  # was created after the org-wide sweep under the pre-rebrand prefix and renamed
  # to hugmesh-character-forge-bff-api by the follow-up rebrand, so the name IS
  # mechanical now (docs/XR-CHAT.md).
  hugmesh-character-forge-bff-api
)

echo "==> Cloning ${#REPOS[@]} HugMesh repos into ${STACK_SRC}"
echo "    base=${GIT_BASE} ref=${GIT_REF}"
mkdir -p "${STACK_SRC}"

# Scratch for per-repo clone stderr, so a failure can be QUOTED instead of
# summarised. Outside ${STACK_SRC}: nothing this script writes there may be
# mistaken for a build context.
CLONE_ERR="$(mktemp "${TMPDIR:-/tmp}/stack-clone-err.XXXXXX")"
trap 'rm -f "${CLONE_ERR}"' EXIT

# ── CREDENTIAL SELECTION: prove it, then use it ──────────────────────────────
#
# #535. `make stack-up` died at this, its FIRST step, with 0 ok / 26 failed and
# the words "auth/VPN?" — on a box whose credentials were fine. Measured twice,
# one minute apart, into two throwaway directories:
#
#     as the operator's login shell has it   ->  0 ok, 26 failed
#     env -u GH_TOKEN -u GITHUB_TOKEN        ->  26 ok,  0 failed
#
# ~/.profile exports a FINE-GRAINED GH_TOKEN. It is a perfectly VALID token — `gh
# auth status` exits 0 under it — it simply has no read grant on this org. Both
# of the old mechanisms preferred it over the credential that works:
#
#   * the old clone_url() injected ${GH_TOKEN:-${GITHUB_TOKEN:-}} into the https
#     URL whenever either was set, so every `git clone` authenticated as it and
#     got `remote: Write access to repository not granted` / HTTP 403 (measured
#     2026-09-18 with ls-remote: rc=128);
#   * the old `USE_GH=auto` resolved to 1 from `gh auth status` exiting 0 — which
#     asks "is gh logged in?", never "can gh read THESE repos?" — and `gh` also
#     prefers an environment token over its keyring.
#
# The fix is not a bigger fallback chain, it is a PROOF. Each candidate mechanism
# is tried against ONE repo with one `ls-remote` before the loop starts; the first
# that can actually READ is the one all 26 clones use; the rest are reported, by
# name, with the reason they were skipped. Nothing here guesses from a login
# state, and the failure text never says "auth/VPN?" when the credential was
# proved — a repo that fails AFTER a proved credential is a repo-specific fact.
#
# NOT FIXED HERE, stated rather than hidden: a successful `env-token` clone still
# leaves the token in that checkout's .git/config origin URL (it always has). The
# update path below does not need it, but removing it would change what a CI box
# whose ONLY credential is GH_TOKEN can do on a second run, so it is left alone
# and out of this issue's scope.
have_gh() { command -v gh >/dev/null 2>&1; }

# The ambient token, named ONCE so every message can talk about it and no message
# has to re-read two variables to know which one is in play.
ENV_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if   [ -n "${GH_TOKEN:-}" ];     then ENV_TOKEN_NAME="GH_TOKEN"
elif [ -n "${GITHUB_TOKEN:-}" ]; then ENV_TOKEN_NAME="GITHUB_TOKEN"
else                                  ENV_TOKEN_NAME=""
fi

# A token must never reach a log, a shell trace or a bug report. Every probe's
# output goes through this before anything prints it.
redact() { # <text>
  if [ -n "${ENV_TOKEN}" ]; then
    printf '%s' "${1//${ENV_TOKEN}/<${ENV_TOKEN_NAME}>}"
  else
    printf '%s' "$1"
  fi
}

# No mechanism may park `make stack-up` on "Username for 'https://github.com':".
# A credential that is not there must FAIL, so the next mechanism gets its turn.
export GIT_TERMINAL_PROMPT=0

# The mechanisms, in the order they are tried. `env-token` stays first so an
# explicit CI/Windows token still wins when it works; the two that unset the
# ambient tokens follow, because that is the exact difference #535 measured.
MECH_ORDER=(env-token git-ambient gh-keyring gh-clone)

# gh speaks to github.com. A GIT_BASE pointed at the internal GitLab mirror must
# not silently fall through to `gh repo clone <org>/<repo>` and hand back the
# GITHUB repo of the same name — which the old code would have done.
gh_base_is_github() { [[ "${GIT_BASE}" == https://github.com/* ]]; }

mech_skip_reason() { # <mech> -> "" if usable, else why not
  case "$1" in
    env-token)
      if [ -z "${ENV_TOKEN}" ]; then printf 'no GH_TOKEN/GITHUB_TOKEN in the environment'
      elif [[ "${GIT_BASE}" != https://* ]]; then printf 'GIT_BASE is not https, so a token cannot be injected into the URL'
      fi ;;
    git-ambient) : ;;
    gh-keyring)
      # Only `gh` itself is required. The credential helper is generic: asked for a
      # host it has no credential for, `gh auth git-credential` returns nothing and
      # git carries on — it cannot silently retarget the request the way the clone
      # sub-command below can.
      if ! have_gh; then printf 'the gh CLI is not installed'; fi ;;
    gh-clone)
      if ! have_gh; then printf 'the gh CLI is not installed'
      elif ! gh_base_is_github; then printf 'GIT_BASE is not github.com, and `gh repo clone <org>/<repo>` would fetch the GITHUB repo of that name instead of the one GIT_BASE names'
      fi ;;
  esac
}

mech_desc() { # <mech> -> what an operator should picture
  case "$1" in
    env-token)   printf 'the %s in your environment, injected into the https clone URL' "${ENV_TOKEN_NAME:-token}" ;;
    git-ambient) printf "git's own credential configuration (credential.helper / ~/.netrc / ssh), with %s deliberately unset" "${ENV_TOKEN_NAME:-any ambient token}" ;;
    gh-keyring)  printf "the gh CLI keyring credential via git -c credential.helper='!gh auth git-credential', with %s unset" "${ENV_TOKEN_NAME:-any ambient token}" ;;
    gh-clone)    printf 'gh repo clone, with %s unset so gh uses its keyring' "${ENV_TOKEN_NAME:-any ambient token}" ;;
  esac
}

mech_url() { # <mech> <repo> -> the clone URL that mechanism uses
  case "$1" in
    env-token) printf 'https://oauth2:%s@%s/%s.git' "${ENV_TOKEN}" "${GIT_BASE#https://}" "$2" ;;
    *)         printf '%s/%s.git' "${GIT_BASE}" "$2" ;;
  esac
}

mech_git() { # <mech> <git args...>
  local m
  m="$1"; shift
  case "${m}" in
    env-token)   git "$@" ;;
    git-ambient) env -u GH_TOKEN -u GITHUB_TOKEN git "$@" ;;
    gh-keyring)  env -u GH_TOKEN -u GITHUB_TOKEN git -c credential.helper='!gh auth git-credential' "$@" ;;
    *)           return 127 ;;
  esac
}

# The probe. ONE `ls-remote` against ONE repo — cheap, read-only, and it asks the
# question the run actually depends on.
PROBE_OUT=""
probe_mech() { # <mech> <repo>
  local m
  local repo
  local url
  local out
  local rc
  m="$1"; repo="$2"; rc=0
  if [ "${m}" = "gh-clone" ]; then
    out="$(env -u GH_TOKEN -u GITHUB_TOKEN gh repo view "${GIT_BASE##*/}/${repo}" --json name 2>&1)" || rc=$?
    PROBE_OUT="$(redact "${out}")"
    if [ "${rc}" -eq 0 ] && [ -n "${out}" ]; then return 0; fi
    return 1
  fi
  url="$(mech_url "${m}" "${repo}")"
  out="$(mech_git "${m}" ls-remote --heads "${url}" 2>&1)" || rc=$?
  PROBE_OUT="$(redact "${out}")"
  # An EMPTY listing is a FAILURE here, not a success. A credential that cannot
  # see a private repo has been measured to make fetch/ls-remote print NOTHING and
  # exit 0 rather than error — the shape that reads as "my branch is gone" instead
  # of "the token is wrong". Requiring a ref back closes that.
  if [ "${rc}" -eq 0 ] && [ -n "${out}" ]; then return 0; fi
  return 1
}

PROBE_REPO="${STACK_CLONE_PROBE_REPO:-${REPOS[0]}}"
CRED_MECH=""
CRED_REPORT=()
for _m in "${MECH_ORDER[@]}"; do
  case "${USE_GH}" in
    0) case "${_m}" in gh-keyring|gh-clone) CRED_REPORT+=("  - ${_m}: skipped (USE_GH=0)"); continue ;; esac ;;
  esac
  _skip="$(mech_skip_reason "${_m}")"
  if [ -n "${_skip}" ]; then
    CRED_REPORT+=("  - ${_m}: not available — ${_skip}")
    continue
  fi
  if probe_mech "${_m}" "${PROBE_REPO}"; then
    CRED_REPORT+=("  - ${_m}: OK — read ${PROBE_REPO}")
    CRED_MECH="${_m}"
    break
  fi
  CRED_REPORT+=("  - ${_m}: FAILED — $(printf '%s' "${PROBE_OUT}" | tail -2 | tr '\n' ' ')")
done
# USE_GH=1 used to mean "force gh". It still puts gh first, but it can no longer
# force a credential that has been PROVED unable to read: that is the whole defect.
if [ "${USE_GH}" = "1" ] && [ -n "${CRED_MECH}" ] && [ "${CRED_MECH}" != "gh-clone" ]; then
  if [ -z "$(mech_skip_reason gh-clone)" ] && probe_mech gh-clone "${PROBE_REPO}"; then
    CRED_MECH="gh-clone"
    CRED_REPORT+=("  - gh-clone: OK — read ${PROBE_REPO} (USE_GH=1 asked for it, so it wins)")
  else
    CRED_REPORT+=("  - gh-clone: USE_GH=1 asked for gh, but it could NOT read ${PROBE_REPO} — using ${CRED_MECH} instead")
  fi
fi

echo "==> Credential probe against ${PROBE_REPO}:"
printf '%s\n' ${CRED_REPORT[@]+"${CRED_REPORT[@]}"}
if [ -z "${CRED_MECH}" ]; then
  echo "" >&2
  echo "==> NOTHING could read ${GIT_BASE}/${PROBE_REPO}.git." >&2
  echo "    Every mechanism and its EXACT failure is listed above — read those lines" >&2
  echo "    rather than this one: 'Repository not found' means the org/repo name (or" >&2
  echo "    GIT_BASE) is wrong; a 403 means the credential is; a connection error means" >&2
  echo "    the network is. This script does not guess between them." >&2
  if [ -n "${ENV_TOKEN_NAME}" ]; then
    echo "" >&2
    echo "    ${ENV_TOKEN_NAME} IS set in your environment. If it is a fine-grained token" >&2
    echo "    (github_pat_...), it needs 'Contents: read' granted on ${GIT_BASE##*/} — a" >&2
    echo "    fine-grained token WITHOUT that grant is still a valid token, so 'gh auth" >&2
    echo "    status' exits 0 while every clone 403s. Quickest check:" >&2
    echo "        env -u GH_TOKEN -u GITHUB_TOKEN make stack-up" >&2
  else
    echo "" >&2
    echo "    No GH_TOKEN/GITHUB_TOKEN is set. Log in with 'gh auth login', configure a" >&2
    echo "    git credential helper, or point GIT_BASE at the internal mirror on the VPN." >&2
  fi
  echo "" >&2
  echo "    To build the trees already in ${STACK_SRC} without cloning: STACK_NO_CLONE=1 make stack-up" >&2
  exit 1
fi
echo "    using: ${CRED_MECH} — $(mech_desc "${CRED_MECH}")"

# ── pre-rename checkout migration (LEGACY_COMPAT) ────────────────────────────
# The org renamed every service repo to hugmesh-* during the HugMesh rebrand. A
# ./.stack-src populated before that holds the old DIRECTORY names, which compose
# no longer resolves. Rename in place rather than re-clone: same git objects, no
# multi-GB re-download, and the stale dirs don't linger as dead weight. Only ever
# renames INTO a free name, so a tree that already has both is left untouched.
#
# The pre-rename spellings below are LEGACY_COMPAT READ-ONLY inputs — the only
# thing that can identify an existing multi-GB checkout on the operator's disk.
# They are never written and never emitted; deleting them does not migrate those
# directories, it just makes the migration silently stop finding them. Retire when
# no ./.stack-src can predate the rebrand.
legacy_name() { # canonical name -> pre-rename name ("" if there is none)
  case "$1" in
    # The host shell's pre-rename repo was domain-shaped, not <brand>-<service>.
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

# Fetch, falling back to the gh-CLI credential helper.
#
# WHY THE FALLBACK: an ambient FINE-GRAINED `GH_TOKEN` in the environment takes
# precedence over the gh keyring credential and 403s ("Write access to
# repository not granted") on this org — on FETCH, not just push, because git
# authenticates the whole exchange. The keyring token is a CLASSIC one with full
# `repo` scope and works. Without this fallback every repo fails, `stack-clone`
# exits 1, and `make stack-up` aborts before building anything — which reads as
# "the local mesh is broken" when in fact only the credential is wrong.
# The UPDATE path cannot use env-token (the remote URL lives in .git/config and
# carries whatever the clone put there), so it drives the PROVED mechanism first
# and then the other git-capable ones — a checkout cloned under one credential on
# a machine that has since changed credentials still updates.
git_try() { # git <args...>
  local m
  if [ -n "${CRED_MECH}" ] && [ "${CRED_MECH}" != "gh-clone" ]; then
    mech_git "${CRED_MECH}" "$@" 2>/dev/null && return 0
  fi
  for m in git-ambient gh-keyring; do
    [ "${m}" = "${CRED_MECH}" ] && continue
    [ -n "$(mech_skip_reason "${m}")" ] && continue
    mech_git "${m}" "$@" 2>/dev/null && return 0
  done
  return 1
}

fetch_ref() { # <checkout-dir> <ref>
  local d="$1" ref="$2"
  # NOT `--depth 1` on the update path. A shallow fetch truncates origin/${ref}
  # to a single commit, which destroys the merge base — `rev-list origin/ref..HEAD`
  # then reports every commit in the checkout's history as "local work"
  # (measured: admin-ui 171, mastodon-ui 82, matrix-ui 3, all of them actually
  # in sync). checkout_is_disposable below is only as trustworthy as the
  # ancestry it can see, so the update path fetches REAL history and unshallows
  # a checkout left shallow by an earlier clone. One-time cost per repo, and it
  # only applies to persistent developer checkouts — CI takes the clone path.
  if [ "$(git -C "${d}" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    git_try -C "${d}" fetch --quiet --unshallow origin "${ref}" && return 0
  fi
  git_try -C "${d}" fetch --quiet origin "${ref}"
}

# Is this checkout safe to `reset --hard` over?
#
# The reset below is a DATA-LOSS operation, and it has already silently eaten
# work on a developer machine: it discards local commits AND tracked-file edits
# with no prompt. That is fine in CI (every checkout is a fresh shallow clone,
# so this always returns true and behaviour is unchanged) but wrong on a working
# tree carrying un-merged fix branches — you lose them and the stack then builds
# a DIFFERENT tree than the one you were testing.
#
# Only COMMITTED local work counts. Working-tree edits are deliberately NOT
# counted, because patch-stack-src.sh edits tracked files (Dockerfiles) on every
# run BY DESIGN and the reset is what gives it a clean base to re-apply onto —
# treating those edits as precious would freeze every patched checkout at its
# current commit and silently stop pulling ${GIT_REF} forever. Untracked files
# survive a reset anyway.
checkout_is_disposable() { # <checkout-dir> <ref>
  local ahead
  ahead="$(git -C "$1" rev-list --count "origin/$2..HEAD" 2>/dev/null || echo 0)"
  [ "${ahead:-0}" -eq 0 ]
}

ok=0 fail=0 kept=0
for repo in "${REPOS[@]}"; do
  migrate_legacy_dir "${repo}"
  dest="${STACK_SRC}/${repo}"
  if [ -d "${dest}/.git" ]; then
    echo "  -- ${repo}: present, updating (${GIT_REF})"
    if ! fetch_ref "${dest}" "${GIT_REF}"; then
      echo "     WARN: could not fetch ${repo} (kept existing checkout)" >&2
      fail=$((fail+1))
      continue
    fi
    if ! checkout_is_disposable "${dest}" "${GIT_REF}"; then
      echo "     KEPT: ${repo} has local work not in ${GIT_REF} — NOT resetting." >&2
      echo "           Land it, or build this tree as-is with STACK_NO_CLONE=1." >&2
      kept=$((kept+1))
      continue
    fi
    # --force is safe HERE and only here: checkout_is_disposable has already
    # established there are no local commits to lose, so the only thing being
    # discarded is patch-stack-src.sh's working-tree edits — which the pass at
    # the end of this script re-applies. Without it, a checkout sitting on a
    # local branch with a patched Dockerfile fails with "local changes would be
    # overwritten" and is reported as an update FAILURE (exit 1) rather than
    # being refreshed.
    if git -C "${dest}" checkout --quiet --force "${GIT_REF}" 2>/dev/null \
       && git -C "${dest}" reset --hard --quiet "origin/${GIT_REF}" 2>/dev/null; then
      ok=$((ok+1))
    else
      echo "     WARN: could not update ${repo} (kept existing checkout)" >&2
      fail=$((fail+1))
    fi
    continue
  fi

  echo "  ++ ${repo}: cloning"
  clone_rc=0
  if [ "${CRED_MECH}" = "gh-clone" ]; then
    org="${GIT_BASE##*/}"
    env -u GH_TOKEN -u GITHUB_TOKEN \
      gh repo clone "${org}/${repo}" "${dest}" -- --depth 1 --branch "${GIT_REF}" \
      >/dev/null 2>"${CLONE_ERR}" || clone_rc=$?
  else
    mech_git "${CRED_MECH}" clone --depth 1 --branch "${GIT_REF}" \
      "$(mech_url "${CRED_MECH}" "${repo}")" "${dest}" \
      >/dev/null 2>"${CLONE_ERR}" || clone_rc=$?
  fi
  if [ "${clone_rc}" -eq 0 ]; then
    ok=$((ok+1))
  else
    # NOT "auth/VPN?". The credential was PROVED against ${PROBE_REPO} before this
    # loop started, so a failure here is a fact about THIS repo — it does not
    # exist, it has no ${GIT_REF} branch, or this one repo is not granted — and
    # saying "auth/VPN?" 26 times is what sent #535 looking at the network.
    echo "     ERROR: clone failed for ${repo} via ${CRED_MECH} (which DID read ${PROBE_REPO})." >&2
    echo "            So this is about ${repo} itself: missing repo, missing '${GIT_REF}' branch," >&2
    echo "            or a per-repo grant. git said:" >&2
    redact "$(sed -n '1,3p' "${CLONE_ERR}" 2>/dev/null || true)" >&2
    echo "" >&2
    fail=$((fail+1))
  fi
done

# Post-clone patch pass — the COMMITTED, general mechanism for the small source
# tweaks the LOCAL stack needs on the cloned trees (idempotent + CRLF-tolerant;
# see scripts/patch-stack-src.sh). Runs EVERY time because the update path
# above `reset --hard`s each checkout, wiping any previously applied patch.
bash "${HERE}/patch-stack-src.sh" "${STACK_SRC}"

echo "==> Done: ${ok} ok, ${fail} failed/skipped, ${kept} kept (local work), in ${STACK_SRC}"
if [ "${kept}" -gt 0 ]; then
  # NOT an error: the checkouts are intact and buildable, they just were not
  # reset onto ${GIT_REF}. Exiting non-zero here would block `make stack-up` on
  # exactly the machines doing active development.
  echo "    ${kept} checkout(s) kept local work and were left alone (see KEPT above)."
  echo "    The stack will build THOSE trees, not ${GIT_REF}."
fi
if [ "${fail}" -gt 0 ]; then
  echo "    ${fail} repo(s) failed, using ${CRED_MECH} — $(mech_desc "${CRED_MECH}")." >&2
  echo "    That credential was PROVED able to read ${GIT_BASE}/${PROBE_REPO}.git before" >&2
  echo "    this run started, so these are per-repo failures (see each ERROR above)," >&2
  echo "    NOT a blanket auth or VPN problem. Existing checkouts were kept." >&2
  echo "    To build the trees already in ${STACK_SRC} as they are: STACK_NO_CLONE=1 make stack-up" >&2
  exit 1
fi
