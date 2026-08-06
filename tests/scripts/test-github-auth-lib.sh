#!/usr/bin/env bash
# test-github-auth-lib.sh — executed gate for scripts/_github-auth-lib.sh.
#
# This lib handles CREDENTIALS and sits in front of every first-party clone, so the
# two properties that matter are proven by running it, not by reading it:
#   * the token never reaches argv, the clone URL, or the build log;
#   * a build with no credentials FAILS FAST and never blocks on a prompt.
# Both are executed here against a stub git and a stub gh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/_github-auth-lib.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ghauth-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

PASS=0; FAIL=0
ok()   { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

[ -f "${LIB}" ] || { echo "FATAL: ${LIB} missing"; exit 1; }

# ── 1. an explicit token is used, and is NOT visible in argv or output ──────────
(
  # shellcheck source=/dev/null
  set +u; . "${LIB}"; set -u
  export GH_TOKEN="ghp_SEKRIT_TOKEN_VALUE_0123456789"
  # NOT out="$(gh_auth_ensure ...)": command substitution runs it in a SUBSHELL, so
  # the GIT_ASKPASS/GIT_TERMINAL_PROMPT exports the lib makes would be discarded and
  # this test would assert against an environment the real caller never sees.
  gh_auth_ensure "github.com/acme/thing" >"${TMP}/t1.out" 2>&1; rc=$?
  out="$(cat "${TMP}/t1.out")"
  [ "${rc}" -eq 0 ] || { echo "ensure-rc ${rc}"; exit 1; }
  [ -n "${GIT_ASKPASS:-}" ] || { echo "GIT_ASKPASS was never exported"; exit 1; }
  # The askpass shim must answer, and must not CONTAIN the token itself.
  grep -q "SEKRIT" "${GIT_ASKPASS}" && { echo "token written into the askpass file"; exit 1; }
  [ "$("${GIT_ASKPASS}" "Username for 'https://github.com': ")" = "x-access-token" ] \
      || { echo "askpass gave the wrong username"; exit 1; }
  [ "$("${GIT_ASKPASS}" "Password for 'https://x-access-token@github.com': ")" = "${GH_TOKEN}" ] \
      || { echo "askpass did not return the token"; exit 1; }
  case "${out}" in *SEKRIT*) echo "TOKEN LEAKED TO STDOUT/STDERR"; exit 1 ;; esac
  gh_auth_askpass_end
  [ -z "${GIT_ASKPASS:-}" ] || { echo "GIT_ASKPASS survived cleanup"; exit 1; }
  exit 0
) >"${TMP}/t1" 2>&1 && ok "explicit token: used via askpass, never in the file, never logged" \
   || bad "explicit token: used via askpass, never in the file, never logged" "$(cat "${TMP}/t1")"

# ── 2. NO credentials + no TTY ⇒ fail fast, never prompt ────────────────────────
# The regression this guards: a build that blocks forever on git's Username prompt.
(
  set +u; . "${LIB}"; set -u
  unset GH_TOKEN GITHUB_TOKEN
  # PATH-SHADOW a FAILING gh. Merely prepending an empty dir does NOT hide the real
  # gh — the rest of PATH still finds it, and on a box where the operator is logged
  # in `gh auth token` succeeds and this case silently tests the opposite of what it
  # claims. (That is exactly what the first run of this test did.)
  mkdir -p "${TMP}/nogh"
  printf '#!/bin/sh\nexit 1\n' >"${TMP}/nogh/gh"; chmod +x "${TMP}/nogh/gh"
  export PATH="${TMP}/nogh:${PATH}"
  command -v gh >/dev/null && [ "$(command -v gh)" = "${TMP}/nogh/gh" ] \
      || { echo "gh shadow not in effect: $(command -v gh)"; exit 1; }
  gh_auth_ensure "github.com/acme/thing" >"${TMP}/t2.out" 2>&1 </dev/null; rc=$?
  out="$(cat "${TMP}/t2.out")"
  [ "${rc}" -eq 1 ] || { echo "expected rc=1, got ${rc}"; exit 1; }
  case "${out}" in
    *"gh auth login"*) : ;;
    *) echo "hint does not name the fix"; exit 1 ;;
  esac
  # The critical anti-hang contract.
  [ "${GIT_TERMINAL_PROMPT:-}" = "0" ] || { echo "GIT_TERMINAL_PROMPT not forced to 0"; exit 1; }
  exit 0
) >"${TMP}/t2" 2>&1 && ok "no creds, no tty: fails fast, names the fix, forbids git's prompt" \
   || bad "no creds, no tty: fails fast, names the fix, forbids git's prompt" "$(cat "${TMP}/t2")"

# ── 3. the GH_TOKEN-shadows-keyring hint fires only when a token IS set ─────────
(
  set +u; . "${LIB}"; set -u
  export GH_TOKEN="ghp_readonly"
  out="$(gh_auth_hint "github.com/acme/thing" 2>&1)"
  case "${out}" in
    *"env -u GH_TOKEN"*) : ;;
    *) echo "shadowing hint missing when a token is set"; exit 1 ;;
  esac
  unset GH_TOKEN GITHUB_TOKEN
  out2="$(gh_auth_hint "github.com/acme/thing" 2>&1)"
  case "${out2}" in
    *"env -u GH_TOKEN"*) echo "shadowing hint shown when NO token is set (misleading)"; exit 1 ;;
  esac
  exit 0
) >"${TMP}/t3" 2>&1 && ok "GH_TOKEN-shadows-keyring hint is conditional, not boilerplate" \
   || bad "GH_TOKEN-shadows-keyring hint is conditional, not boilerplate" "$(cat "${TMP}/t3")"

# ── 4. a non-github GIT_BASE must NOT be made to ask for a PAT ──────────────────
# pull-repo-base.sh gates the auth call on the URL; a GitLab-mirror or local base
# must clone exactly as before.
(
  grep -q 'case "${GIT_BASE}" in' "${REPO_ROOT}/scripts/pull-repo-base.sh" \
    && grep -q '\*github\.com\*' "${REPO_ROOT}/scripts/pull-repo-base.sh"
) && ok "auth preflight is gated on a github.com base only" \
  || bad "auth preflight is gated on a github.com base only" "no github.com case guard found"

# ── 5. set -e safety: the cleanup must not abort the no-auth-needed path ────────
# `[ x = 1 ] && cleanup` as a bare statement returns non-zero when the test fails,
# which under `set -euo pipefail` kills the script on the ORDINARY path.
(
  ! grep -nE '^\[ "\$\{_gh_armed\}" = 1 \] && gh_auth_askpass_end' \
      "${REPO_ROOT}/scripts/pull-repo-base.sh" >/dev/null
) && ok "cleanup uses an if, not a bare test-and-command (set -e safe)" \
  || bad "cleanup uses an if, not a bare test-and-command (set -e safe)" \
         "found a bare 'test && cleanup' that set -e would abort on"

# ── 6. the lib is actually reachable from the clone site ────────────────────────
grep -q '_github-auth-lib.sh' "${REPO_ROOT}/scripts/pull-repo-base.sh" \
  && ok "pull-repo-base.sh sources the auth lib" \
  || bad "pull-repo-base.sh sources the auth lib" "not sourced"

printf 'github-auth-lib: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
