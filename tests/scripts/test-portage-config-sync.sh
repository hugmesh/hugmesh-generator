#!/usr/bin/env bash
# test-portage-config-sync.sh — spec DELETIONS must reach resumed sysroots.
#
# The incident this pins (2026-08-05): the builders' bare
#   cp specs/.../package.use/* sysroot/etc/portage/package.use/
# propagated additions but never deletions, so #513's retirement of
# package.use/firewalld-introspection left a stale copy in every RESUMED
# sysroot — and the very next resumed build retried the broken
# glib[introspection] cross rebuild and died. Fresh builds can never see this
# class (the sysroot starts from the seed), which is exactly why no build gate
# had ever caught it. This test pins (A) the lib's sync semantics behaviourally
# and (B) that every builder actually routes the three portage config dirs
# through the lib rather than a bare cp.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
P=0; F=0
ok()  { P=$((P+1)); printf '  PASS %s\n' "$1"; }
bad() { F=$((F+1)); printf '  FAIL %s\n' "$1" >&2; }

echo "-- A) pcs_sync_dir semantics (executed, fixture dirs) --"
# shellcheck source=../../scripts/_portage-config-lib.sh
source "${REPO}/scripts/_portage-config-lib.sh"
S="$(mktemp -d)"; D="$(mktemp -d)"
echo new > "${S}/kept"; echo old > "${D}/kept"; echo stale > "${D}/retired-file"
if pcs_sync_dir "${S}" "${D}" >/dev/null; then ok "sync run succeeds"; else bad "sync run failed"; fi
[ "$(cat "${D}/kept" 2>/dev/null)" = "new" ] && ok "existing file updated from specs" || bad "existing file not updated"
[ ! -e "${D}/retired-file" ] && ok "file deleted from specs is PRUNED from dest (the #513 stale-override class)" \
                             || bad "stale dest file survived the sync — spec deletions still do not propagate"
E="$(mktemp -d)"
pcs_sync_dir "${E}" "${D}" >/dev/null
[ -z "$(ls -A "${D}")" ] && ok "empty spec dir empties dest" || bad "empty spec dir left dest files behind"
pcs_sync_dir "${REPO}/no-such-dir-$$" "${D}" >/dev/null 2>&1 && bad "missing spec dir silently passed" \
                                                             || ok "missing spec dir fails loudly"
rm -rf "${S}" "${D}" "${E}"

echo "-- B) every builder routes the three config dirs through the lib --"
for b in "${REPO}"/build-*-stage4.sh; do
  base="$(basename "${b}")"
  grep -q '_portage-config-lib.sh' "${b}" \
    && ok "${base}: sources _portage-config-lib.sh" \
    || bad "${base}: does not source _portage-config-lib.sh"
  # a bare recursive/glob cp into any of the three dirs is the regression shape
  if grep -nE 'cp .*portage/package\.(use|accept_keywords|env)/"?\*' "${b}" >/dev/null; then
    bad "${base}: bare glob-cp into a portage config dir is back (deletions will not propagate to resumed sysroots)"
  else
    ok "${base}: no bare glob-cp into package.use/accept_keywords/env"
  fi
  n="$(grep -c 'pcs_sync_dir ' "${b}")"
  [ "${n}" -ge 3 ] && ok "${base}: >=3 pcs_sync_dir call sites (${n})" \
                   || bad "${base}: only ${n} pcs_sync_dir call sites (want the three config dirs)"
done

echo
echo "== portage-config-sync: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
