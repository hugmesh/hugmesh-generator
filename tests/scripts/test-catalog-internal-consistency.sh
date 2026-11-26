#!/usr/bin/env bash
# test-catalog-internal-consistency.sh — the two generator-owned catalogs (device ->
# role -> platform and role -> package) must name the same platforms and the same
# roles. See tests/scripts/catalog_internal_consistency.py for what each check is and
# why this is not the same thing as admin-bff's ImageCatalogDriftTest (that one
# compares a VENDORED copy against this repo's originals, in admin-bff's own repo;
# this one only holds the originals internally consistent before anyone vendors them
# — see docs/BUILD-MATRIX.md).
#
#   bash tests/scripts/test-catalog-internal-consistency.sh
#
# Needs bash and python3 (stdlib only). No network, no docker.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
CHECK="${HERE}/catalog_internal_consistency.py"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL $*"; fail=$((fail + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is not installed; this suite cannot run (it must not pass vacuously)"; exit 2; }
[ -f "${CHECK}" ] || { echo "FATAL: ${CHECK} missing"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-catalog-internal-consistency.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

echo "== catalog internal consistency: the real tree =="
out="$(python3 -I "${CHECK}" "${REPO}" 2>&1)"; rc=$?
printf '%s\n' "${out}"
if [ "${rc}" = 0 ]; then ok "the real tree passes every check"; else bad "the real tree fails (rc ${rc})"; fi
n_pass="$(printf '%s\n' "${out}" | grep -c '^  PASS \[' || true)"
if [ "${n_pass}" -eq 3 ]; then ok "the checker ran all 3 of its checks"; else bad "${n_pass} PASS lines, not 3: a check stopped running (or one was added without this pin)"; fi

IMG="docs/catalog/image-catalog.json"
PKG="docs/catalog/packages-catalog.json"

fresh() { # fresh NAME -> a copy of both catalogs at $T
  T="${TMP}/$1"
  mkdir -p "${T}/docs/catalog"
  cp "${REPO}/${IMG}" "${T}/${IMG}"
  cp "${REPO}/${PKG}" "${T}/${PKG}"
}

# edit FILE PYTHON-EXPR: rewrite $T/FILE with s = <expr over s>; refuse a no-op. The
# expressions are the literal mutations written in THIS file, never external input.
edit() {
  python3 -I - "${T}/$1" "$2" <<'PY'
import sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p).read()
new = eval(expr, {"s": s, "re": __import__("re")})
if new == s:
    sys.exit("mutation did not change " + p)
open(p, "w").write(new)
PY
}

check_fails() { # check_fails LABEL TAG -> run the checker in $T, require rc=1 and the tag
  local label="$1" tag="$2"
  local o; o="$(python3 -I "${CHECK}" "${T}" 2>&1)"; local r=$?
  if [ "${r}" != 1 ]; then bad "${label}: expected rc 1, got ${r}"; return; fi
  case "${o}" in
    *"FAIL [${tag}]"*) ok "${label}: caught as [${tag}]" ;;
    *) bad "${label}: no FAIL [${tag}] line: ${o}" ;;
  esac
}

echo
echo "== mutation battery (each must be caught, each verified to have changed its file) =="

# [platform-set]: rename a platform key in packages-catalog.json's "platforms" map
# so it no longer matches anything image-catalog.json's devices carry.
fresh platform-set
edit "${PKG}" 's.replace(chr(34) + "x86" + chr(34) + ": {", chr(34) + "x86-renamed" + chr(34) + ": {", 1)'
check_fails "platform renamed only in packages-catalog.json" platform-set

# [role-set]: rename a role id inside packages-catalog.json's "roles" map (not the
# platform key) so one platform's role set carries a name image-catalog.json never
# uses — this moves both role-set and role-per-platform, but role-set alone proves
# the global comparison is wired.
fresh role-set
edit "${PKG}" 's.replace(chr(34) + "pki" + chr(34) + ":", chr(34) + "pki-renamed" + chr(34) + ":", 1)'
check_fails "role 'pki' renamed only in packages-catalog.json" role-set

# [role-per-platform]: drop one platform's role entirely from packages-catalog.json's
# "roles" map for x86 (a role image-catalog.json still offers there), without
# touching any other platform — the global role-set total can still balance if the
# same role name happens to survive elsewhere, so this is the check that catches a
# per-platform drop the global totals might miss.
fresh role-per-platform
edit "${PKG}" '__import__("json").dumps({**(d := __import__("json").loads(s)), "roles": {**d["roles"], "x86": {k: v for k, v in d["roles"]["x86"].items() if k != "laptop"}}})'
check_fails "role 'laptop' dropped from x86 only in packages-catalog.json" role-per-platform

echo
echo "== positive control: an untouched second copy still passes =="
fresh untouched
o="$(python3 -I "${CHECK}" "${T}" 2>&1)"; r=$?
if [ "${r}" = 0 ]; then ok "an unmutated copy of both catalogs still passes"; else bad "an unmutated copy failed: ${o}"; fi

echo
printf '%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
