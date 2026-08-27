#!/usr/bin/env bash
# =============================================================================
# test-federation-module-slugs.sh — unit test for
# scripts/validate-federation-module-slugs.sh (the federation_modules
# registration drift guard).
# =============================================================================
# The guard compares TWO DERIVED SIDES: every federation-module declaration in
# this repo (optional-services.yaml `federationModule:` blocks + every
# `kind: FederationModuleRegistration` descriptor) against the row the named
# Liquibase changeset in hugmesh-federation-api actually inserts.
#
# This test does NOT restate a table of expected pairs — a hardcoded pair table
# would drift exactly the way the registry did. Instead it:
#
#   LEG A (integration, against the REAL sibling checkout when present): runs the
#     gate unmodified. Must PASS. If hugmesh-federation-api is not checked out the
#     leg is reported UNVERIFIED and the run exits 3 — never silently skipped.
#
#   LEG B (hermetic): SYNTHESISES a changelog tree FROM the registry itself, so
#     the two sides agree by construction, and then MUTATES one side at a time to
#     prove each assertion is load-bearing. Every mutation is verified to have
#     actually changed the file before the gate is re-run.
#
# MUTATIONS (each must turn the gate RED, except B2b which must stay GREEN):
#   B1   reintroduce the original defect — registry slug != changeset slug
#   B2a  point a registry row at a changeset that does not exist, on a TAKEN number
#   B2b  ... on a FREE number (a legal forward reference: must stay GREEN)
#   B3a  make the deriver return nothing at all (vacuity guard #1)
#   B3b  declarations derived but NONE resolve to a changeset (vacuity guard #2)
#   B4   mountAt drift between registry and changeset metadata
#   B5   the changeset exists but is not <include>d by db.changelog-master.xml
#   B6   a descriptor forward-references an already-taken changeset number
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="${REPO}/scripts/validate-federation-module-slugs.sh"
REG="${REPO}/specs/cluster/optional-services.yaml"
DESC="${REPO}/specs/cluster/manifests/federation-api/register-superadmin-service-catalog.descriptor.yaml"

for f in "${GATE}" "${REG}" "${DESC}"; do
  [ -r "${f}" ] || { echo "  FAIL missing target: ${f}"; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available"; exit 1; }

P=0; F=0; U=0
ok()   { echo "  PASS $*"; P=$((P+1)); }
bad()  { echo "  FAIL $*"; F=$((F+1)); }
unv()  { echo "  UNVERIFIED $*"; U=$((U+1)); }
W="$(mktemp -d)"; trap 'rm -rf "${W}" 2>/dev/null' EXIT

echo "== federation module slug gate unit test =="

# ── LEG A — the real thing, against a real sibling checkout ────────────────────
REAL=""
REL="hugmesh-federation-api/src/main/resources/db/changelog"
for root in "${FEDERATION_SIBLING_ROOT:-}" "${REPO}/.stack-src" "$(cd "${REPO}/.." && pwd)"; do
  [ -n "${root}" ] || continue
  [ -d "${root}/${REL}" ] && { REAL="${root}/${REL}"; break; }
done
if [ -n "${REAL}" ]; then
  FEDERATION_CHANGELOG_DIR="${REAL}" bash "${GATE}" >"${W}/real.out" 2>&1
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    n="$(sed -n 's/.*compared \([0-9]*\) landed.*/\1/p' "${W}/real.out")"
    if [ "${n:-0}" -ge 1 ]; then
      ok "real changelog (${REAL##*/hugmesh-federation-api/}): PASS, ${n} landed comparison(s)"
    else
      bad "real changelog: PASS but compared 0 landed declarations (vacuous)"
    fi
  else
    bad "real changelog: gate rc=${rc}"; sed 's/^/      | /' "${W}/real.out"
  fi
else
  unv "leg A: hugmesh-federation-api is not checked out — the gate was NOT run against real data"
fi

# ── LEG B — hermetic sandbox synthesised from the registry ─────────────────────
# build_sandbox <dir>: a minimal repo root holding the gate, the registry, the
# descriptors, and a changelog whose changesets are GENERATED from the registry
# (so both sides agree by construction — every RED below is caused by a mutation,
# never by pre-existing drift).
build_sandbox() {
  local d="$1"
  rm -rf "${d}"
  mkdir -p "${d}/scripts" "${d}/specs/cluster/manifests/federation-api" "${d}/changelog"
  cp "${GATE}" "${d}/scripts/"
  cp "${REG}"  "${d}/specs/cluster/optional-services.yaml"
  cp "${DESC}" "${d}/specs/cluster/manifests/federation-api/"
  python3 - "${d}/specs/cluster/optional-services.yaml" "${d}/changelog" <<'PY'
import json, os, sys, yaml
reg, out = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(reg, encoding="utf-8"))
includes = []
for svc in doc["spec"]["services"]:
    fm = svc.get("federationModule")
    if not fm:
        continue
    cs = fm["changeset"]
    meta = {"requiresRole": fm.get("requiresRole", fm["slug"]),
            "mountAt": fm["mountAt"]}
    body = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog">\n'
        '  <changeSet id="%s-1" author="synthetic">\n'
        '    <insert tableName="federation_modules">\n'
        '      <column name="slug" value="%s"/>\n'
        '      <column name="kind" value="remote-shell"/>\n'
        '      <column name="exposed_module" value="%s"/>\n'
        '      <column name="metadata" value=\'%s\'/>\n'
        '    </insert>\n'
        '  </changeSet>\n'
        '</databaseChangeLog>\n'
        % (cs[:3], fm["slug"], fm.get("exposed", "./routes"),
           json.dumps(meta).replace("&", "&amp;").replace("<", "&lt;")))
    open(os.path.join(out, cs), "w", encoding="utf-8").write(body)
    includes.append(cs)
open(os.path.join(out, "db.changelog-master.xml"), "w", encoding="utf-8").write(
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog">\n'
    + "".join('  <include file="db/changelog/%s"/>\n' % c for c in includes)
    + '</databaseChangeLog>\n')
print("synthesised %d changesets" % len(includes))
PY
}

# run_sandbox <dir> -> RC in $RC, output in <dir>/out
run_sandbox() {
  FEDERATION_CHANGELOG_DIR="$1/changelog" bash "$1/scripts/validate-federation-module-slugs.sh" \
    >"$1/out" 2>&1
  RC=$?
}

# mutated <file> <before-copy> — proves a mutation actually changed bytes.
mutated() {
  if cmp -s "$1" "$2"; then bad "mutation did not change $(basename "$1") — RED below would be meaningless"; return 1; fi
  return 0
}

# expect <label> <want-rc> <needle>
expect() {
  local label="$1" want="$2" needle="$3"
  if [ "${RC}" -ne "${want}" ]; then
    bad "${label}: rc=${RC}, wanted ${want}"; sed 's/^/      | /' "${SB}/out"; return
  fi
  if [ -n "${needle}" ] && ! grep -F "${needle}" "${SB}/out" >/dev/null; then
    bad "${label}: rc ok but reason not reported (wanted ${needle@Q})"
    sed 's/^/      | /' "${SB}/out"; return
  fi
  ok "${label}"
}

SB="${W}/sb"
build_sandbox "${SB}" >/dev/null
run_sandbox "${SB}"
if [ "${RC}" -eq 0 ]; then
  ok "B0 baseline: synthesised sandbox is GREEN (mutations below start from green)"
else
  bad "B0 baseline sandbox is not green — every mutation result is unreadable"
  sed 's/^/      | /' "${SB}/out"
fi

# ── B1: reintroduce the original defect (registry slug != changeset slug) ──────
build_sandbox "${SB}" >/dev/null
cp "${SB}/specs/cluster/optional-services.yaml" "${W}/b1.before"
python3 - "${SB}/specs/cluster/optional-services.yaml" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
# Undo the fix for whichever registry row names 023-register-akkoma-module.xml,
# found by its changeset (not by a hardcoded line number).
s2 = re.sub(r"(federationModule: \{ slug: )[A-Za-z0-9-]+(, mountAt: [^,]+, "
            r'changeset: "023-register-akkoma-module\.xml" \})',
            r"\1akkoma\2", s)
open(p, "w", encoding="utf-8").write(s2)
PY
if mutated "${SB}/specs/cluster/optional-services.yaml" "${W}/b1.before"; then
  run_sandbox "${SB}"; expect "B1 slug mismatch (the original defect) is RED" 1 "declared slug='akkoma'"
fi

# ── B2a: changeset that does not exist, on an ALREADY-TAKEN number ─────────────
build_sandbox "${SB}" >/dev/null
cp "${SB}/specs/cluster/optional-services.yaml" "${W}/b2a.before"
sed -i 's|changeset: "025-register-games-module.xml"|changeset: "022-register-games-module.xml"|' \
  "${SB}/specs/cluster/optional-services.yaml"
if mutated "${SB}/specs/cluster/optional-services.yaml" "${W}/b2a.before"; then
  # 025 is now unreferenced, so it stays on disk and 022 is taken by forum.
  run_sandbox "${SB}"; expect "B2a forward reference to a TAKEN number is RED" 1 "ALREADY TAKEN"
fi

# ── B2b: changeset that does not exist, on a FREE number — legal, stays GREEN ──
build_sandbox "${SB}" >/dev/null
sed -i 's|changeset: "025-register-games-module.xml"|changeset: "099-register-games-module.xml"|' \
  "${SB}/specs/cluster/optional-services.yaml"
rm -f "${SB}/changelog/025-register-games-module.xml"
run_sandbox "${SB}"
if [ "${RC}" -eq 0 ] && grep -F "PENDING 099" "${SB}/out" >/dev/null; then
  ok "B2b forward reference to a FREE number is GREEN and reported PENDING"
else
  bad "B2b: rc=${RC} (wanted 0 + a PENDING line)"; sed 's/^/      | /' "${SB}/out"
fi

# ── B3a: deriver returns nothing — an empty comparison must NOT pass ───────────
build_sandbox "${SB}" >/dev/null
cp "${SB}/scripts/validate-federation-module-slugs.sh" "${W}/b3a.before"
sed -i 's|svc.get("federationModule")|svc.get("federationModuleXXX")|' \
  "${SB}/scripts/validate-federation-module-slugs.sh"
sed -i 's|!= "FederationModuleRegistration"|!= "FederationModuleRegistrationXXX"|' \
  "${SB}/scripts/validate-federation-module-slugs.sh"
if mutated "${SB}/scripts/validate-federation-module-slugs.sh" "${W}/b3a.before"; then
  run_sandbox "${SB}"; expect "B3a deriver yields NOTHING is RED (not a vacuous pass)" 1 "VACUOUS"
fi

# ── B3b: declarations derived, but none resolve to a changeset ────────────────
build_sandbox "${SB}" >/dev/null
# Deleting the register-changesets leaves every declared number FREE, so B3b
# isolates the "nothing landed" guard from B2a's collision guard: each declaration
# degrades to a LEGAL pending forward reference — precisely the shape that would
# otherwise pass while comparing nothing.
rm -f "${SB}"/changelog/0*-register-*.xml
run_sandbox "${SB}"; expect "B3b all-PENDING (0 landed) is RED, not a vacuous pass" 1 "NONE resolved"

# ── B4: mountAt drift ─────────────────────────────────────────────────────────
build_sandbox "${SB}" >/dev/null
cp "${SB}/specs/cluster/optional-services.yaml" "${W}/b4.before"
sed -i 's|mountAt: /social/matrix, changeset: "024|mountAt: /social/mtrx, changeset: "024|' \
  "${SB}/specs/cluster/optional-services.yaml"
if mutated "${SB}/specs/cluster/optional-services.yaml" "${W}/b4.before"; then
  run_sandbox "${SB}"; expect "B4 mountAt drift is RED" 1 "declared mountAt="
fi

# ── B5: the changeset exists but master never <include>s it ───────────────────
build_sandbox "${SB}" >/dev/null
cp "${SB}/changelog/db.changelog-master.xml" "${W}/b5.before"
sed -i '/024-register-tuwunel-module.xml/d' "${SB}/changelog/db.changelog-master.xml"
if mutated "${SB}/changelog/db.changelog-master.xml" "${W}/b5.before"; then
  run_sandbox "${SB}"; expect "B5 changeset not <include>d by master is RED" 1 "never run"
fi

# ── B6: a DESCRIPTOR forward-references an already-taken number ───────────────
build_sandbox "${SB}" >/dev/null
D="${SB}/specs/cluster/manifests/federation-api/register-superadmin-service-catalog.descriptor.yaml"
cp "${D}" "${W}/b6.before"
sed -i 's|changeset: "042-register-superadmin-service-catalog-module.xml"|changeset: "023-register-superadmin-service-catalog-module.xml"|' "${D}"
if mutated "${D}" "${W}/b6.before"; then
  run_sandbox "${SB}"; expect "B6 descriptor collides with a taken number is RED" 1 "ALREADY TAKEN"
fi

echo "== ${P} passed, ${F} failed, ${U} unverified =="
[ "${F}" -eq 0 ] || exit 1
[ "${U}" -eq 0 ] || exit 3
exit 0
