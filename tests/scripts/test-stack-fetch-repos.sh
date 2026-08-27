#!/usr/bin/env bash
# test-stack-fetch-repos.sh — the home-seeded stack's fetch-repos.sh must name repos
# that actually exist, its consumers must agree with it, and a fetch that fails
# must FAIL (exit status + a message that says which name), never print "Done.".
#
# WHAT IT IS FOR (measured, not assumed): specs/usr/share/hugmesh/stack/ is staged
# into an x86 image by build-x86-host-stage4.sh when --home-seed-code is
# repos|stack|mesh; specs/usr/sbin/hugmesh-home-setup copies fetch-repos.sh into
# ~/hugmesh-stack on first boot when no code bundle was baked; `./hugmesh-stack
# fetch` runs it; docker-compose.yml then builds from `./<repo>` contexts; and the
# Studio's core/mesh_node.py stages the same file next to docker-compose.mesh.yml.
#
# THE DEFECT THIS PINS (2026-08-27). The REPOS list said `hugmesh.net login-ui
# admin-bff user-bff … auth-core` — 17 of its 20 names did not exist under
# github.com/hugmesh (verified: `gh repo view hugmesh/admin-bff`,
# `hugmesh/auth-core`, `hugmesh/hugmesh.net` all fail to resolve; the repos are
# hugmesh-admin-bff-api, hugmesh-auth-core, hugmesh-host-shell). Every clone died
# behind `2>/dev/null || echo "(could not fetch … private?)"`, the script printed
# "Done." and exited 0, and `hugmesh-stack fetch`'s `[ -x f ] && f || echo` would
# have turned even a real failure into "no fetch-repos.sh". Nothing in tests/ read
# that list. It had been that way since the rename landed (83e15af0, 2026-08-20).
#
# THE GUARD. The org's real repo names are PINNED below (the full `gh repo list
# hugmesh --limit 200` of 2026-08-27, 41 repos). Offline, every run asserts:
#   1. every REPOS entry is in the pinned set (a rename or typo is red, by name);
#   2. every REPOS entry has the org's `hugmesh-<slug>` shape;
#   3. every docker-compose.yml build context is `./<a REPOS entry>`;
#   4. hugmesh-home-setup's "code already bundled" marker dir is a REPOS entry;
#   5. BEHAVIOUR: the real script, against an EMPTY file:// base with gh shimmed
#      out, exits non-zero and names every repo it could not fetch (no "Done.");
#   6. BEHAVIOUR: against a file:// base holding a bare repo for every name, it
#      clones all of them (exit 0), and a second run takes the update path;
#   7. BEHAVIOUR: `hugmesh-stack fetch` propagates a failing fetch-repos.sh
#      (exit status AND no "no fetch-repos.sh" message).
# With LIVE=1 (never in the gate — needs network + gh auth) it ALSO lists the org
# and asserts pinned == live, so the pin itself can be re-verified on demand.
#
# Runs ANYWHERE with bash + git — NO network, NO root, NO docker.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK="${REPO}/specs/usr/share/hugmesh/stack"
FETCH="${STACK}/fetch-repos.sh"
COMPOSE="${STACK}/docker-compose.yml"
RUNNER="${STACK}/hugmesh-stack"
HOMESETUP="${REPO}/specs/usr/sbin/hugmesh-home-setup"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

# ── the pinned org listing ────────────────────────────────────────────────────
# `env -u GH_TOKEN -u GITHUB_TOKEN gh repo list hugmesh --limit 200 --json name`
# on 2026-08-27, sorted. Re-verify with LIVE=1. A repo added to the org is NOT a
# failure here (fetch-repos.sh need not clone everything); a REPOS entry absent
# from this set IS.
ORG_REPOS_PINNED=(
  .github
  .github-private
  hugmesh-actions
  hugmesh-admin-bff-api
  hugmesh-admin-ui
  hugmesh-api-docs
  hugmesh-auth-core
  hugmesh-be-gateway
  hugmesh-build-config
  hugmesh-character-forge-bff-api
  hugmesh-character-studio-ui
  hugmesh-commons
  hugmesh-fe-gateway
  hugmesh-federation-api
  hugmesh-forum-api
  hugmesh-forum-bff-api
  hugmesh-forum-ui
  hugmesh-games
  hugmesh-gateway
  hugmesh-generator
  hugmesh-host-shell
  hugmesh-login-ui
  hugmesh-mastodon-ui
  hugmesh-matrix-ui
  hugmesh-mesh-bff-api
  hugmesh-mod-bff-api
  hugmesh-mod-ui
  hugmesh-owncast-bff-api
  hugmesh-owncast-ui
  hugmesh-parent
  hugmesh-pki-gateway
  hugmesh-remote-fragment
  hugmesh-superadmin-service-catalog-ui
  hugmesh-tube-bff-api
  hugmesh-tube-ui
  hugmesh-user-bff-api
  hugmesh-user-mesh-ui
  hugmesh-user-ui
  hugmesh-wiki-bff-api
  hugmesh-wiki-ui
  hugmesh.github.io
)
in_pinned() { local x; for x in "${ORG_REPOS_PINNED[@]}"; do [ "${x}" = "$1" ] && return 0; done; return 1; }

for f in "${FETCH}" "${COMPOSE}" "${RUNNER}" "${HOMESETUP}"; do
  [ -f "${f}" ] || { bad "missing ${f}"; }
done

# ── the REPOS array, read out of the real script ─────────────────────────────
# Only the `REPOS=( … )` block is evaluated — the script itself clones at top level.
echo "== fetch-repos.sh REPOS list =="
REPOS=()
block="$(sed -n '/^REPOS=(/,/^)/p' "${FETCH}")"
[ -n "${block}" ] && eval "${block}"
[ "${#REPOS[@]}" -gt 0 ] && ok "REPOS declares ${#REPOS[@]} repo(s)" \
  || bad "could not read a non-empty REPOS=( … ) array out of fetch-repos.sh"
in_repos() { local x; for x in "${REPOS[@]}"; do [ "${x}" = "$1" ] && return 0; done; return 1; }

# 1. every entry exists in the org (pinned)
for r in "${REPOS[@]}"; do
  in_pinned "${r}" && ok "org has '${r}'" \
    || bad "'${r}' is NOT a repo under github.com/hugmesh (pinned listing) — a clone of it can only fail"
done
# 2. every entry has the org's naming shape
for r in "${REPOS[@]}"; do
  case "${r}" in
    hugmesh-[a-z0-9]*) ok "'${r}' has the hugmesh-<slug> shape" ;;
    *) bad "'${r}' does not have the org's hugmesh-<slug> shape (a pre-rename or bare service name)" ;;
  esac
done
# no duplicates
dups="$(printf '%s\n' "${REPOS[@]}" | sort | uniq -d)"
[ -z "${dups}" ] && ok "no duplicate REPOS entries" || bad "duplicate REPOS entries: ${dups}"

# 3. compose build contexts are cloned names
echo "== docker-compose.yml build contexts are REPOS entries =="
ctxs="$(sed -n 's/.*build:[[:space:]]*{[[:space:]]*context:[[:space:]]*\.\/\([^ }]*\).*/\1/p' "${COMPOSE}")"
[ -n "${ctxs}" ] && ok "compose declares build context(s): $(echo "${ctxs}" | tr '\n' ' ')" \
  || bad "compose declares NO ./<dir> build contexts — the scaffold lost its app services?"
for c in ${ctxs}; do
  in_repos "${c}" && ok "context ./${c} is a REPOS entry" \
    || bad "context ./${c} is NOT a REPOS entry — compose would fail with 'unable to prepare context'"
done

# 4. hugmesh-home-setup's bundled-code marker is a REPOS entry
echo "== hugmesh-home-setup marker =="
marker="$(sed -n 's/.*\[ ! -d "\${DST}\/\([^"]*\)" \].*fetch-repos\.sh.*/\1/p' "${HOMESETUP}" | awk 'NR==1')"
[ -n "${marker}" ] && ok "home-setup decides 'code already bundled' on ${marker}/" \
  || bad "could not find home-setup's '[ ! -d \${DST}/<repo> ]' marker next to fetch-repos.sh"
[ -n "${marker}" ] && { in_repos "${marker}" && ok "marker '${marker}' is a REPOS entry" \
  || bad "marker '${marker}' is not a REPOS entry — a fetched tree would never satisfy home-setup"; }

# ── behaviour ────────────────────────────────────────────────────────────────
# A PATH that hides `gh` (so the script takes the plain-git branch) and a git
# identity for the fixture commits.
SCRATCH="$(mktemp -d)"
mkdir -p "${SCRATCH}/bin"
printf '#!/bin/sh\nexit 1\n' > "${SCRATCH}/bin/gh"; chmod +x "${SCRATCH}/bin/gh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

echo "== 5. an unreachable base: exit non-zero, every repo NAMED, no 'Done.' =="
W="${SCRATCH}/neg"; mkdir -p "${W}/base"; cp "${FETCH}" "${W}/fetch-repos.sh"; chmod +x "${W}/fetch-repos.sh"
out="$(cd "${W}" && PATH="${SCRATCH}/bin:${PATH}" HUGMESH_GIT_BASE="file://${W}/base" ./fetch-repos.sh 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && ok "exits non-zero (rc=${rc}) when nothing can be fetched" \
  || bad "exited 0 with nothing fetched — the silent strand"
printf '%s\n' "${out}" | grep -F "Done." >/dev/null && bad "still prints 'Done.' after failing" || ok "does not print 'Done.'"
printf '%s\n' "${out}" | grep -E "^ERROR: could not fetch ${#REPOS[@]} of ${#REPOS[@]} repo" >/dev/null \
  && ok "reports 'could not fetch ${#REPOS[@]} of ${#REPOS[@]}'" \
  || bad "does not report the failed count (got: $(printf '%s\n' "${out}" | grep ERROR | awk 'NR==1'))"
for r in "${REPOS[@]}"; do
  printf '%s\n' "${out}" | grep -E "^ERROR:.* ${r}( |$)" >/dev/null && ok "names '${r}' as unfetched" \
    || bad "does not name '${r}' as unfetched"
done
printf '%s\n' "${out}" | grep -F "gh repo list" >/dev/null && ok "points at the org listing to check the NAME" \
  || bad "does not tell the user how to check the name"

echo "== 6. a base holding every repo: all cloned (exit 0), second run updates =="
W="${SCRATCH}/pos"; mkdir -p "${W}/base"; cp "${FETCH}" "${W}/fetch-repos.sh"; chmod +x "${W}/fetch-repos.sh"
seed="${SCRATCH}/seed"; git init -q "${seed}" && ( cd "${seed}" && echo x > f && git add f && git -c commit.gpgsign=false commit -q -m init )
for r in "${REPOS[@]}"; do git clone -q --bare "${seed}" "${W}/base/${r}.git"; done
out="$(cd "${W}" && PATH="${SCRATCH}/bin:${PATH}" HUGMESH_GIT_BASE="file://${W}/base" ./fetch-repos.sh 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "exits 0 when every repo resolves" || bad "rc=${rc} with every repo present: ${out}"
missing=""; for r in "${REPOS[@]}"; do [ -d "${W}/${r}/.git" ] || missing="${missing} ${r}"; done
[ -z "${missing}" ] && ok "all ${#REPOS[@]} repos cloned next to the script" || bad "not cloned:${missing}"
printf '%s\n' "${out}" | grep -F "Done." >/dev/null && ok "prints 'Done.' on success" || bad "no 'Done.' on success"
out="$(cd "${W}" && PATH="${SCRATCH}/bin:${PATH}" HUGMESH_GIT_BASE="file://${W}/base" ./fetch-repos.sh 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "second run exits 0" || bad "second run rc=${rc}: ${out}"
n_upd="$(printf '%s\n' "${out}" | grep -c '^  update ')"
[ "${n_upd}" -eq "${#REPOS[@]}" ] && ok "second run takes the update path for all ${#REPOS[@]}" \
  || bad "second run updated ${n_upd} of ${#REPOS[@]}"

echo "== 6b. ONE wrong name among real ones: that name, and only that name, is reported =="
W="${SCRATCH}/one"; mkdir -p "${W}/base"
sed 's/^REPOS=(/REPOS=(\n    not-a-real-repo/' "${FETCH}" > "${W}/fetch-repos.sh"; chmod +x "${W}/fetch-repos.sh"
for r in "${REPOS[@]}"; do git clone -q --bare "${seed}" "${W}/base/${r}.git"; done
out="$(cd "${W}" && PATH="${SCRATCH}/bin:${PATH}" HUGMESH_GIT_BASE="file://${W}/base" ./fetch-repos.sh 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && ok "one bad name makes the run fail (rc=${rc})" || bad "one bad name was swallowed (rc=0)"
printf '%s\n' "${out}" | grep -E "^ERROR: could not fetch 1 of $(( ${#REPOS[@]} + 1 )) repo\(s\): not-a-real-repo$" >/dev/null \
  && ok "reports exactly 'not-a-real-repo'" || bad "report line wrong: $(printf '%s\n' "${out}" | grep ERROR | awk 'NR==1')"

echo "== 7. hugmesh-stack fetch propagates a failing fetch-repos.sh =="
W="${SCRATCH}/runner"; mkdir -p "${W}"; cp "${RUNNER}" "${W}/hugmesh-stack"; chmod +x "${W}/hugmesh-stack"
printf '#!/bin/sh\necho fetch-stub-ran\nexit 7\n' > "${W}/fetch-repos.sh"; chmod +x "${W}/fetch-repos.sh"
out="$(cd "${W}" && PATH="${SCRATCH}/bin:${PATH}" ./hugmesh-stack fetch 2>&1)"; rc=$?
printf '%s\n' "${out}" | grep -F "fetch-stub-ran" >/dev/null && ok "runner invoked fetch-repos.sh" || bad "runner did not invoke fetch-repos.sh"
[ "${rc}" -eq 7 ] && ok "runner exits with fetch-repos.sh's status (7)" || bad "runner exited ${rc}, not 7 — the failure was swallowed"
printf '%s\n' "${out}" | grep -F "no fetch-repos.sh" >/dev/null && bad "runner claims 'no fetch-repos.sh' on a FAILED fetch" \
  || ok "runner does not misreport a failed fetch as a missing script"
rm -f "${W}/fetch-repos.sh"
out="$(cd "${W}" && ./hugmesh-stack fetch 2>&1)"; rc=$?
printf '%s\n' "${out}" | grep -F "no fetch-repos.sh" >/dev/null && [ "${rc}" -eq 0 ] \
  && ok "runner still reports a genuinely missing fetch-repos.sh (rc=0)" || bad "missing-script path broke: rc=${rc} '${out}'"

rm -rf "${SCRATCH}"

# ── LIVE (opt-in, network): the pin itself vs the org ────────────────────────
if [ "${LIVE:-0}" = "1" ]; then
  echo "== LIVE: pinned listing == gh repo list =="
  live="$(env -u GH_TOKEN -u GITHUB_TOKEN gh repo list hugmesh --limit 200 --json name --jq '.[].name' 2>/dev/null | sort)"
  if [ -z "${live}" ]; then bad "LIVE=1 but 'gh repo list hugmesh' returned nothing (auth? network?)"
  else
    pinned="$(printf '%s\n' "${ORG_REPOS_PINNED[@]}" | sort)"
    if [ "${live}" = "${pinned}" ]; then ok "pinned listing matches the live org ($(printf '%s\n' "${live}" | wc -l) repos)"
    else bad "pinned listing differs from the live org:"; diff <(printf '%s\n' "${pinned}") <(printf '%s\n' "${live}") | sed 's/^/         /'; fi
  fi
fi

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
