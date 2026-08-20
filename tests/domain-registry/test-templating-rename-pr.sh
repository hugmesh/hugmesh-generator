#!/usr/bin/env bash
# ============================================================================
# test-templating-rename-pr.sh — I5 exit gate: renames[] op + generator
# archetype + --ref versioning + publish --pr delivery.
# ============================================================================
#
# HERMETIC, BUILD-HOST RUNNABLE: normal user, NO root, NO network. Every remote
# is local: the Forgejo REST API is a PATH-shadowed RECORDING `curl` stub, the
# push remote is a local bare repo (file://), and the versioned base pull runs
# against a local file:// upstream. The generator-archetype render runs over a
# FABRICATED tiny fixture base — never a real clone.
#
# Sections:
#   [A] renames[] unit tests — happy path, edits-before-renames ordering, and
#       EVERY refusal class: required-missing, absolute (both sides), '..'
#       (both sides), contract denylist (the pinned descriptor/provenance/stamp
#       names AND the theme delivery chain, both sides),
#       destination-clobber, directory rename, symlinked-parent tree escape,
#       denylisted/unknown token in a rename path.
#   [B] generator archetype over the fixture base — anchors land (README brand,
#       CI include), the renames[] demo lands (docs/BRANDING-<org-slug>.md),
#       STACK-CRITICAL files (Makefile, tests/stack/compose.local.yaml) are
#       BYTE-UNTOUCHED, zero residual {{TOKEN}}s; render-tenant-set.js admits
#       archetype 'generator' and its residual sweep stays green.
#   [C] --ref plumbing — pull-repo-base.sh --ref (fresh clone at a tag, cached
#       re-pin, fail-closed bogus ref, --foreign refusal), render-repo-tree.sh
#       --ref (tag content rendered, .hugmesh-base-ref marker written).
#   [D] publish --pr — branch templating/update-<ref> pushed (main NEVER),
#       Forgejo POST /pulls recorded, 409 -> open-list -> PATCH leg, provenance
#       base.ref stamp, PAT never on any argv, marker/--ref mismatch refusal,
#       --pr-without-version refusal; default (no --pr) mode still pushes main
#       ff-only with no /pulls call.
#
# SKIPs (exit 0) only if a required tool is genuinely absent.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECIPE_JS="${REPO}/scripts/tooling/render-recipe.js"
RRT="${REPO}/scripts/render-repo-tree.sh"
PRB="${REPO}/scripts/pull-repo-base.sh"
PUB="${REPO}/scripts/publish-tenant-set.sh"
RTS_JS="${REPO}/scripts/tooling/render-tenant-set.js"

for t in node jq git tar realpath sha256sum; do
  command -v "$t" >/dev/null || { echo "SKIP: need $t"; exit 0; }
done
[ -d "${REPO}/scripts/tooling/node_modules/handlebars" ] \
  || { echo "SKIP: handlebars not installed (cd scripts/tooling && npm install)"; exit 0; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

echo "== I5 templating suite: renames[] + generator archetype + --ref + --pr (hermetic) =="

# ── Shared brand token env for direct render-recipe.js drives ──────────────────
# (render-repo-tree.sh derives these from the .conf itself; the unit section
# feeds them directly, matching the values the .conf below produces.)
export BRAND="acme" BRAND_TITLE="Acme" ORG="Acme-Inc" CLUSTER_DOMAIN="acme.test"
export HARBOR_PROJECT="" HEADSCALE_URL="" MESH_TAG="" NS_PREFIX=""
export NPM_SCOPE="acme-inc" HOST_NAME="acme-host" ORG_SLUG="acme-inc"
export GENERATOR_ORG_GROUP="acme-inc/hugmesh-generator" REPO_NAME="generator"
XTOK="NPM_SCOPE,HOST_NAME,GENERATOR_ORG_GROUP,REPO_NAME,ORG_SLUG"

# run_recipe CASEID RECIPE_BODY TARGET [extra render-recipe args...] — writes the
# recipe, drives the engine as a subprocess, captures rc + stderr.
RC=0
run_recipe() {
  local cid="$1" body="$2" target="$3"; shift 3
  local rf="${WORK}/recipes/${cid}.yaml"; mkdir -p "${WORK}/recipes"
  printf '%s\n' "$body" > "$rf"
  node "$RECIPE_JS" --recipe "$rf" --target "$target" --extra-tokens "$XTOK" "$@" \
    2>"${WORK}/recipe-${cid}.err"; RC=$?
}
mktree() { # mktree DIR — a minimal target tree with the rename-demo source
  local d="$1"; mkdir -p "${d}/docs" "${d}/sub"
  printf '# HugMesh tenant branding — fixture\nOLDLINE\n' > "${d}/docs/BRANDING.md"
  printf 'x\n' > "${d}/sub/keep.txt"
}

echo "-- [A] renames[] unit tests --"

T="${WORK}/A1"; mktree "$T"
run_recipe A1 'edits: []
renames:
  - { from: docs/BRANDING.md, to: "docs/BRANDING-{{ORG_SLUG}}.md", required: true }' "$T" --report "${WORK}/A1-report.json"
if [ $RC -eq 0 ] && [ -f "${T}/docs/BRANDING-acme-inc.md" ] && [ ! -e "${T}/docs/BRANDING.md" ]; then
  ok "A1 happy path: rendered rename applied (docs/BRANDING-acme-inc.md)"
else bad "A1 happy path (rc=$RC)"; fi
if jq -e '.renames[0].applied == true and (.renames[0].to == "docs/BRANDING-acme-inc.md")' "${WORK}/A1-report.json" >/dev/null 2>&1; then
  ok "A1 report records the applied rename"
else bad "A1 report"; fi

T="${WORK}/A2"; mktree "$T"
run_recipe A2 'edits:
  - file: docs/BRANDING.md
    anchors:
      - { id: e, find: "OLDLINE", replace: "NEWLINE-{{BRAND}}", required: true }
renames:
  - { from: docs/BRANDING.md, to: "docs/BRANDING-{{ORG_SLUG}}.md", required: true }' "$T"
if [ $RC -eq 0 ] && grep -q "NEWLINE-acme" "${T}/docs/BRANDING-acme-inc.md" 2>/dev/null; then
  ok "A2 edits run BEFORE renames (edit addressed the pre-rename path, landed in the renamed file)"
else bad "A2 edit/rename ordering (rc=$RC)"; fi

T="${WORK}/A3"; mkdir -p "$T"
run_recipe A3 'edits: []
renames:
  - { from: docs/NOPE.md, to: "docs/NOPE2.md" }' "$T" --report "${WORK}/A3-report.json"
if [ $RC -eq 0 ] && jq -e '.renames[0].applied == false' "${WORK}/A3-report.json" >/dev/null 2>&1; then
  ok "A3 optional missing source is a presence-tolerant no-op"
else bad "A3 optional no-op (rc=$RC)"; fi

T="${WORK}/A4"; mkdir -p "$T"
run_recipe A4 'edits: []
renames:
  - { from: docs/NOPE.md, to: "docs/NOPE2.md", required: true }' "$T"
[ $RC -ne 0 ] && ok "A4 REQUIRED missing source refuses" || bad "A4 required-missing accepted"

T="${WORK}/A5"; mktree "$T"
run_recipe A5 'edits: []
renames:
  - { from: /etc/passwd, to: "docs/x.md" }' "$T"
[ $RC -ne 0 ] && ok "A5 absolute FROM refused" || bad "A5 absolute from accepted"

run_recipe A6 'edits: []
renames:
  - { from: docs/BRANDING.md, to: "/tmp/evil.md" }' "$T"
if [ $RC -ne 0 ] && [ ! -e /tmp/evil.md ]; then ok "A6 absolute TO refused (nothing written)"; else bad "A6 absolute to"; fi

run_recipe A7 'edits: []
renames:
  - { from: ../outside.md, to: "docs/x.md" }' "$T"
[ $RC -ne 0 ] && ok "A7 '..' FROM refused" || bad "A7 dotdot from accepted"

run_recipe A8 'edits: []
renames:
  - { from: docs/BRANDING.md, to: "sub/../../escape.md" }' "$T"
if [ $RC -ne 0 ] && [ ! -e "${WORK}/escape.md" ]; then ok "A8 '..' TO (outside-tree) refused"; else bad "A8 dotdot to"; fi

# Contract denylist — the PINNED names, exercised on BOTH sides.
run_recipe A9 'edits: []
renames:
  - { from: docs/BRANDING.md, to: "snapdragon-deploy.yaml" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9.err" && ok "A9 contract denylist TO=snapdragon-deploy.yaml refused" || bad "A9 deploy-descriptor rename accepted"

# The post-rebrand spelling of the SAME contract. 3 org repos ship this name and
# both catalog generators filter on it (specs/cluster/catalog/adopters.yaml), so
# renaming it un-discovers the repo exactly as renaming the legacy name does. This
# is the only place the denylist is exercised behaviourally — the discovery gate
# only string-greps the JS source — so the entry needs its own case on BOTH sides.
run_recipe A9b 'edits: []
renames:
  - { from: docs/BRANDING.md, to: "hugmesh-deploy.yaml" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9b.err" && ok "A9b contract denylist TO=hugmesh-deploy.yaml refused" || bad "A9b rebranded deploy-descriptor rename accepted"

run_recipe A9c 'edits: []
renames:
  - { from: hugmesh-deploy.yaml, to: "docs/d.yaml" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9c.err" && ok "A9c contract denylist FROM=hugmesh-deploy.yaml refused" || bad "A9c rebranded deploy-descriptor rename-away accepted"

run_recipe A9d 'edits: []
renames:
  - { from: snapdragon-deploy.yaml, to: "docs/d.yaml" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9d.err" && ok "A9d contract denylist FROM=snapdragon-deploy.yaml refused" || bad "A9d legacy deploy-descriptor rename-away accepted"

# THE THEME CONTRACT (scripts/tooling/tokens.json `theme_contract_constants`).
# Unlike the deploy descriptor, a moved theme link fails SILENTLY: the emitted repo
# still builds, the container still boots, nginx still serves 200 — the page is just
# unthemed, because the SNAP_THEME_CSS env var -> 50-snap-theme.sh hook ->
# snap-theme.css file -> index.html <link href> -> --sd-* custom property chain is
# joined by NAME ALONE across five processes in different repos. Nothing else in the
# tree would notice, so these four cases are the entire behavioural guard. A9e/A9f
# cover the file half on BOTH sides (A9f also proves the BASENAME match survives a
# subdirectory, the laundering shape A12 pins for the stamps); A9g/A9h cover the
# identifier half through the SAME classifier gate the anchors ride.
run_recipe A9e 'edits: []
renames:
  - { from: docs/BRANDING.md, to: "snap-theme.css" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9e.err" && ok "A9e theme contract TO=snap-theme.css refused" || bad "A9e theme css rename accepted"

run_recipe A9f 'edits: []
renames:
  - { from: docs/BRANDING.md, to: "sub/50-snap-theme.sh" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9f.err" && ok "A9f theme contract TO=sub/50-snap-theme.sh refused (basename match)" || bad "A9f theme entrypoint-hook rename accepted"

# The persistence end of the chain. The Makefile finds this by a `wildcard` on the
# EXACT path (STACK_THEME_FILE), so a rename does not error — the wildcard simply
# misses, STACK_THEME_ENV expands empty, and every later `make stack-up` quietly
# serves the shipped brand instead of the operator's theme.
run_recipe A9i 'edits: []
renames:
  - { from: docs/BRANDING.md, to: ".theme.css" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9i.err" && ok "A9i theme contract TO=.theme.css refused (Makefile STACK_THEME_FILE wildcard)" || bad "A9i theme persistence file rename accepted"

# FROM side: renaming the contract AWAY breaks the same handshake as renaming
# something onto it, and the refusal must leave the source where it was.
# Its own tree (a real snap-theme.css to move), in a SEPARATE variable: $T is the
# shared A5 tree that cases A6-A12b all reuse, and clobbering it here would
# silently retarget every later case.
TJ="${WORK}/A9j"; mktree "$TJ"; printf '/* theme */\n' > "${TJ}/snap-theme.css"
run_recipe A9j 'edits: []
renames:
  - { from: snap-theme.css, to: "docs/theme.css" }' "$TJ"
if [ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9j.err" && [ -f "${TJ}/snap-theme.css" ]; then
  ok "A9j theme contract FROM=snap-theme.css refused (source intact)"
else bad "A9j theme stylesheet rename-away accepted"; fi

# The env/ARG key the css text travels under. Already fail-closed as an UNKNOWN
# token before it was registered, so assert the CONTRACT wording — that is the only
# thing that distinguishes "pinned on purpose" from "nobody has allowlisted it yet".
run_recipe A9g 'edits:
  - file: docs/BRANDING.md
    anchors:
      - { id: env, find: "{{SNAP_THEME_CSS}}", replace: "x" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9g.err" && ok "A9g theme contract identifier {{SNAP_THEME_CSS}} refused" || bad "A9g theme env key templated"

# The LIVE spelling of the locale-set key, and the same argument A9k makes for
# --hug-*: rename phase 3c moved every producer (Makefile STACK_WEB_LOCALES,
# LocalStackNode._build_env, the compose build arg) onto HUG_WEB_LOCALES, so that
# is now the name that decides which translation catalogs the login-ui image
# ships. A guard registered against only the retired SNAP_ spelling would pass its
# own test while leaving the load-bearing name open to the next rebrand sweep —
# and the failure is silent: the chain still builds, still boots, still exits 0,
# and serves a UI with no translations. Both spellings stay pinned until phase 4
# proves nothing reads the old one (the login-ui Dockerfile still does).
run_recipe A9m 'edits:
  - file: docs/BRANDING.md
    anchors:
      - { id: env, find: "{{HUG_WEB_LOCALES}}", replace: "x" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9m.err" && ok "A9m theme contract identifier {{HUG_WEB_LOCALES}} refused (LIVE locale key)" || bad "A9m live web-locales env key templated"

run_recipe A9n 'edits:
  - file: docs/BRANDING.md
    anchors:
      - { id: env, find: "{{SNAP_WEB_LOCALES}}", replace: "x" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9n.err" && ok "A9n theme contract identifier {{SNAP_WEB_LOCALES}} refused (retired locale key still read)" || bad "A9n retired web-locales env key templated"

# The custom-property half is NOT a Handlebars identifier (leading dashes), so
# TOKEN_RE never captured it and the identifier loop's fail-closed allowlist check
# was unreachable: this recipe used to exit 0 and render `var()`, silently DELETING
# the property it named. Only the raw-mustache scan catches it.
#
# BOTH prefixes get a case, and A9k is the one that matters most. --hug-* is the
# LIVE palette (measured 2026-08-20: 3119 reads across the built fleet remotes vs 9
# for --sd-*); --sd-* is the retired spelling the angular archetypes scaffolded onto
# until PR #104. A guard registered against only the dying prefix would pass its own
# test while leaving the contract that is actually load-bearing wide open, so the
# case for the live one is not redundant with the case for the legacy one.
run_recipe A9h 'edits:
  - file: docs/BRANDING.md
    anchors:
      - { id: sd, find: "OLDLINE", replace: "var({{--sd-accent}})" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9h.err" && ok "A9h theme contract raw body {{--sd-accent}} refused (retired prefix)" || bad "A9h --sd-* custom property templated"

run_recipe A9k 'edits:
  - file: docs/BRANDING.md
    anchors:
      - { id: hug, find: "OLDLINE", replace: "var({{--hug-accent}})" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9k.err" && ok "A9k theme contract raw body {{--hug-accent}} refused (LIVE prefix)" || bad "A9k --hug-* custom property templated"

# Not a blanket refusal of leading-dash mustaches: an unrelated one must still fall
# through to the ordinary fail-closed path, so A9h/A9k prove the PREFIX matched and
# not merely that render-recipe.js dislikes dashes.
run_recipe A9l 'edits:
  - file: docs/BRANDING.md
    anchors:
      - { id: other, find: "OLDLINE", replace: "var({{--mui-accent}})" }' "$T"
if [ $RC -eq 0 ] && ! grep -q "CONTRACT" "${WORK}/recipe-A9l.err"; then
  ok "A9l control: an unrelated --mui-* custom property is NOT theme-contract refused"
else bad "A9l theme-contract guard over-fires on unrelated --* properties (rc=$RC)"; fi

run_recipe A10 'edits: []
renames:
  - { from: .hugmesh-provenance.json, to: "docs/p.json" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A10.err" && ok "A10 contract denylist FROM=.hugmesh-provenance.json refused" || bad "A10 provenance rename accepted"

# LEGACY_COMPAT half of the SAME contract. provenance.sh verify / ingest-foreign-
# base.sh still dual-READ the pre-rebrand envelope off other meshes' disks, so a
# recipe that renames it away is exactly as breaking as renaming the new name.
run_recipe A10b 'edits: []
renames:
  - { from: .snapdragon-provenance.json, to: "docs/p.json" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A10b.err" && ok "A10b contract denylist FROM=.snapdragon-provenance.json (LEGACY_COMPAT) refused" || bad "A10b legacy provenance rename accepted"

run_recipe A11 'edits: []
renames:
  - { from: .hugmesh-mesh-admitted, to: "docs/stamp" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A11.err" && ok "A11 contract denylist FROM=.hugmesh-mesh-admitted refused" || bad "A11 admission-stamp rename accepted"

run_recipe A11b 'edits: []
renames:
  - { from: .snapdragon-mesh-admitted, to: "docs/stamp" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A11b.err" && ok "A11b contract denylist FROM=.snapdragon-mesh-admitted (LEGACY_COMPAT) refused" || bad "A11b legacy admission-stamp rename accepted"

run_recipe A12 'edits: []
renames:
  - { from: docs/BRANDING.md, to: "sub/.hugmesh-mesh-admitted" }' "$T"
[ $RC -ne 0 ] && ok "A12 contract denylist fires on the BASENAME even in a subdir (laundering guard)" || bad "A12 subdir contract name accepted"

run_recipe A12b 'edits: []
renames:
  - { from: docs/BRANDING.md, to: "sub/.snapdragon-mesh-admitted" }' "$T"
[ $RC -ne 0 ] && ok "A12b BASENAME guard also fires on the LEGACY_COMPAT stamp name" || bad "A12b subdir legacy contract name accepted"

T="${WORK}/A13"; mktree "$T"; printf 'y\n' > "${T}/docs/EXISTS.md"
run_recipe A13 'edits: []
renames:
  - { from: docs/BRANDING.md, to: "docs/EXISTS.md" }' "$T"
if [ $RC -ne 0 ] && grep -q "OLDLINE" "${T}/docs/BRANDING.md" && [ "$(cat "${T}/docs/EXISTS.md")" = "y" ]; then
  ok "A13 destination-exists refused (no clobber, source intact)"
else bad "A13 clobber guard"; fi

run_recipe A14 'edits: []
renames:
  - { from: "{{ROOT_PASS}}.md", to: "docs/x.md" }' "$T"
[ $RC -ne 0 ] && ok "A14 denylisted secret token in a rename path refused (shared classifier gate)" || bad "A14 secret token accepted"

run_recipe A14b 'edits: []
renames:
  - { from: docs/BRANDING.md, to: "docs/{{NOT_A_TOKEN}}.md" }' "$T"
[ $RC -ne 0 ] && ok "A14b UNKNOWN token in a rename path refused (fail-closed)" || bad "A14b unknown token accepted"

T="${WORK}/A15"; mktree "$T"
run_recipe A15 'edits: []
renames:
  - { from: docs, to: "docs2" }' "$T"
if [ $RC -ne 0 ] && [ -d "${T}/docs" ]; then ok "A15 DIRECTORY rename refused (files only)"; else bad "A15 dir rename accepted"; fi

T="${WORK}/A16"; mkdir -p "$T" "${WORK}/outside-A16"
printf 'z\n' > "${WORK}/outside-A16/f.txt"
ln -s "${WORK}/outside-A16" "${T}/sub"
run_recipe A16 'edits: []
renames:
  - { from: sub/f.txt, to: "docs/in.txt" }' "$T"
if [ $RC -ne 0 ] && [ -f "${WORK}/outside-A16/f.txt" ]; then
  ok "A16 symlinked-parent tree ESCAPE refused (realpath containment)"
else bad "A16 symlink escape"; fi

# ── [B] generator archetype over a FABRICATED fixture base ─────────────────────
echo "-- [B] generator archetype (fixture base, never a real clone) --"

CONF="${WORK}/acme.conf"
cat > "$CONF" <<'EOF'
BRAND="acme"
BRAND_TITLE="Acme"
ORG="Acme-Inc"
CLUSTER_DOMAIN="acme.test"
EOF

FIX="${WORK}/fixture-base"
mkfixture() { # mkfixture DIR — the tiny fabricated generator base
  local d="$1"; rm -rf "$d"; mkdir -p "${d}/docs" "${d}/tests/stack"
  cat > "${d}/README.md" <<'EOF'
# hugmesh-generator

Fixture build scripts that produce hardened images for the
HugMesh cluster — fabricated tiny base for the archetype test.
EOF
  cat > "${d}/.gitlab-ci.yml" <<'EOF'
include:
  - project: hugmesh/hugmesh-generator
    file: ci/pentest-stage.yml
stages: [verify]
EOF
  printf '# HugMesh tenant branding — fixture\nfixture branding body\n' > "${d}/docs/BRANDING.md"
  printf 'stack-up:\n\t@echo local mesh up\n.PHONY: stack-up\n' > "${d}/Makefile"
  printf '# local mesh compose fixture\nservices: {}\n' > "${d}/tests/stack/compose.local.yaml"
  printf '#!/usr/bin/env bash\n# fixture generate-brand-repos.sh (archetype marker)\n' > "${d}/generate-brand-repos.sh"
}
mkfixture "$FIX"

OUTB="${WORK}/outB"
if ( cd "$REPO" && env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
      bash "$RRT" "$CONF" --enable-repo-tree --repo generator --archetype generator \
        --base "$FIX" --out-dir "$OUTB" ) >"${WORK}/B1.out" 2>"${WORK}/B1.err"; then
  ok "B1 generator-archetype render over the fixture base (overlay mode)"
else bad "B1 render failed: $(tail -n3 "${WORK}/B1.err" | tr '\n' ' ')"; fi
BT="${OUTB}/acme-generator"
grep -q "Acme cluster" "${BT}/README.md" 2>/dev/null \
  && ! grep -q "HugMesh cluster" "${BT}/README.md" 2>/dev/null \
  && ok "B2 README title brand anchor landed (Acme cluster)" || bad "B2 README anchor"
grep -q "acme-inc/hugmesh-generator" "${BT}/.gitlab-ci.yml" 2>/dev/null \
  && ok "B3 ci-include-org anchor landed" || bad "B3 ci include"
if [ -f "${BT}/docs/BRANDING-acme-inc.md" ] && [ ! -e "${BT}/docs/BRANDING.md" ] \
   && grep -q "Acme tenant branding" "${BT}/docs/BRANDING-acme-inc.md"; then
  ok "B4 renames[] demo landed (docs/BRANDING-acme-inc.md, title edit applied pre-rename)"
else bad "B4 rename demo"; fi
cmp -s "${FIX}/Makefile" "${BT}/Makefile" \
  && ok "B5a Makefile BYTE-UNTOUCHED (make stack-up stays intact)" || bad "B5a Makefile mutated"
cmp -s "${FIX}/tests/stack/compose.local.yaml" "${BT}/tests/stack/compose.local.yaml" \
  && ok "B5b tests/stack/compose.local.yaml BYTE-UNTOUCHED" || bad "B5b compose.local.yaml mutated"
if ! grep -rEq '\{\{[A-Z_][A-Z0-9_]*\}\}' "$BT" 2>/dev/null; then
  ok "B6 zero residual {{TOKEN}}s in the emitted tree"
else bad "B6 residual tokens: $(grep -rEl '\{\{[A-Z_][A-Z0-9_]*\}\}' "$BT" | head -n3 | tr '\n' ' ')"; fi

BYAML="${WORK}/acme.yaml"
cat > "$BYAML" <<'EOF'
brand: acme
title: Acme
org: Acme-Inc
domains: [acme.test]
repos:
  - { name: generator, archetype: generator, installed: true }
EOF
if ( cd "$REPO" && env -i PATH="$PATH" HOME="${HOME:-/tmp}" OFFLINE=1 \
      GENERATOR_BASE_DIR="$FIX" \
      node "$RTS_JS" "$BYAML" --out-dir "${WORK}/outB7" ) >"${WORK}/B7.out" 2>"${WORK}/B7.err"; then
  grep -q "0 residual" "${WORK}/B7.err" \
    && ok "B7 render-tenant-set.js admits archetype 'generator'; residual sweep green" \
    || ok "B7 render-tenant-set.js admits archetype 'generator' (exit 0; sweep enforced by exit code)"
else bad "B7 tenant-set render: $(tail -n3 "${WORK}/B7.err" | tr '\n' ' ')"; fi

# Drift oracle against the REAL base (this repo IS the generator): the archetype
# must be GREEN on an in-sync upstream — incl. the presence-tolerant ci-include
# anchor (the generator's own CI has no self-include today; a required anchor
# there would be a standing false DRIFT).
if ( cd "$REPO" && bash scripts/validate-repo-templates.sh --archetype generator --base "$REPO" ) \
     >"${WORK}/B8.out" 2>"${WORK}/B8.err"; then
  ok "B8 drift oracle GREEN on the real generator base (validate-repo-templates)"
else bad "B8 drift oracle: $(grep DRIFT "${WORK}/B8.out" | head -n2 | tr '\n' ' ')"; fi

# ── [C] --ref plumbing against a LOCAL file:// upstream ────────────────────────
echo "-- [C] --ref versioned pull (local file:// upstream, no network) --"

SRC="${WORK}/src-upstream"; mkfixture "$SRC"
( cd "$SRC" && git init -q -b main && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm base \
  && git tag v1.2.3 \
  && printf '\nDRIFT-AFTER-TAG\n' >> README.md \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm drift ) \
  || bad "C0 upstream fixture repo build"
GITROOT="${WORK}/git"; mkdir -p "$GITROOT"
git clone -q --bare "$SRC" "${GITROOT}/hugmesh-generator.git" 2>/dev/null || bad "C0 bare upstream"

CACHE="${WORK}/cache"
BASE_OUT="$(env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    GIT_BASE="file://${GITROOT}" REPO_BASE_CACHE="$CACHE" \
    bash "$PRB" --ref v1.2.3 generator 2>"${WORK}/C1.err")"; rc=$?
if [ $rc -eq 0 ] && [ -d "$BASE_OUT" ] && ! grep -q "DRIFT-AFTER-TAG" "${BASE_OUT}/README.md"; then
  ok "C1 pull-repo-base --ref v1.2.3: fresh clone pinned to the TAG (drift commit absent)"
else bad "C1 pinned clone (rc=$rc)"; fi

BASE_OUT2="$(env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    GIT_BASE="file://${GITROOT}" REPO_BASE_CACHE="$CACHE" \
    bash "$PRB" --ref v1.2.3 generator 2>"${WORK}/C2.err")"; rc=$?
[ $rc -eq 0 ] && ! grep -q "DRIFT-AFTER-TAG" "${BASE_OUT2}/README.md" \
  && ok "C2 cached re-pin at the same --ref (FETCH_HEAD detach path)" || bad "C2 cached re-pin (rc=$rc)"

env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    GIT_BASE="file://${GITROOT}" REPO_BASE_CACHE="$CACHE" \
    bash "$PRB" --ref no-such-tag generator >/dev/null 2>&1 \
  && bad "C3 bogus --ref accepted" || ok "C3 unresolvable --ref FAILS CLOSED (no silent stale-cache fallback)"

env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    bash "$PRB" --ref v1 --foreign --mesh acme-mesh generator >/dev/null 2>&1 \
  && bad "C4 --ref+--foreign accepted" || ok "C4 --ref refused with --foreign (immutable digest only)"

env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    bash "$PRB" --ref 'v1;rm -rf' generator >/dev/null 2>&1 \
  && bad "C5 metachar ref accepted" || ok "C5 metachar/bogus-shape --ref refused"

OUTC="${WORK}/outC"
if ( cd "$REPO" && env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
      GIT_BASE="file://${GITROOT}" REPO_BASE_CACHE="$CACHE" \
      bash "$RRT" "$CONF" --enable-repo-tree --repo generator --archetype generator \
        --ref v1.2.3 --out-dir "$OUTC" ) >"${WORK}/C6.out" 2>"${WORK}/C6.err"; then
  CT="${OUTC}/acme-generator"
  if [ "$(cat "${CT}/.hugmesh-base-ref" 2>/dev/null)" = "v1.2.3" ] \
     && ! grep -q "DRIFT-AFTER-TAG" "${CT}/README.md" && grep -q "Acme cluster" "${CT}/README.md"; then
    ok "C6 render --ref: tag content rendered + .hugmesh-base-ref marker written"
  else bad "C6 marker/content"; fi
else bad "C6 render --ref failed: $(tail -n3 "${WORK}/C6.err" | tr '\n' ' ')"; fi

( cd "$REPO" && env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    bash "$RRT" "$CONF" --enable-repo-tree --repo generator --archetype generator \
      --ref v1 --foreign-mesh acme-mesh --pinned-digest "$(printf 'x%.0s' {1..40})" \
      --out-dir "${WORK}/outC7" ) >/dev/null 2>&1 \
  && bad "C7 render --ref+--foreign-mesh accepted" \
  || ok "C7 render refuses --ref with --foreign-mesh"

# ── [D] publish --pr: stubbed Forgejo REST + local bare push remote ────────────
echo "-- [D] publish --pr (PATH-stubbed curl, file:// bare remote) --"

STUB="${WORK}/stubbin"; mkdir -p "$STUB"
cat > "${STUB}/curl" <<'EOF'
#!/usr/bin/env bash
# RECORDING curl stub (hermetic Forgejo REST). Argv is logged VERBATIM so the
# suite can assert the PAT never rides on a command line. Behavior is keyed on
# URL shape + method, tunable via STUB_* env.
LOG="${CURL_LOG:?CURL_LOG unset}"
printf 'ARGV:' >> "$LOG"; for a in "$@"; do printf ' %q' "$a" >> "$LOG"; done; printf '\n' >> "$LOG"
OUT=""; METHOD="GET"; URL=""; DATA=""; WANT_CODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -w) WANT_CODE=1; shift 2 ;;
    -X) METHOD="$2"; shift 2 ;;
    -d) DATA="$2"; shift 2 ;;
    -H) shift 2 ;;
    -m) shift 2 ;;
    -sS|-s) shift ;;
    *) URL="$1"; shift ;;
  esac
done
printf 'REQ: %s %s %s\n' "$METHOD" "$URL" "$DATA" >> "$LOG"
code=200; body=""
case "$URL" in
  */api/v1/orgs/*/repos)          code="${STUB_REPO_CODE:-201}" ;;
  */pulls\?state=open*)           code=200; body="${STUB_PULLS_JSON:-[]}" ;;
  */pulls/[0-9]*)                 code="${STUB_PATCH_CODE:-200}" ;;
  */pulls)                        code="${STUB_PR_CODE:-201}" ;;
esac
if [ -n "$OUT" ]; then printf '%s' "$body" > "$OUT"; elif [ -n "$body" ]; then printf '%s' "$body"; fi
[ "$WANT_CODE" -eq 1 ] && printf '%s' "$code"
exit 0
EOF
chmod +x "${STUB}/curl"

PAT="TESTPAT-MUST-NEVER-APPEAR-ON-ARGV-4242"
TOKF="${WORK}/pat.txt"; ( umask 077 && printf '%s\n' "$PAT" > "$TOKF" )
FORGE="${WORK}/forge"; mkdir -p "$FORGE"; git init -q --bare "${FORGE}/acme-generator.git"

# run_pub CASEID SETDIR [publish args...] (stub curl first on PATH)
PUB_RC=0
run_pub() {
  local cid="$1" set_dir="$2"; shift 2
  CURL_LOG="${WORK}/curl-${cid}.log"; : > "$CURL_LOG"
  ( cd "$REPO" && env PATH="${STUB}:$PATH" CURL_LOG="$CURL_LOG" \
      FORGEJO_PUSH_TOKEN_FILE="$TOKF" FORGEJO_API_MODE=rest \
      FORGEJO_BASE_URL="http://forgejo.test:3000" \
      FORGEJO_REMOTE_TEMPLATE="file://${FORGE}/%s.git" \
      REPO_BASE_CACHE="$CACHE" \
      STUB_REPO_CODE="${STUB_REPO_CODE:-201}" STUB_PR_CODE="${STUB_PR_CODE:-201}" \
      STUB_PATCH_CODE="${STUB_PATCH_CODE:-200}" STUB_PULLS_JSON="${STUB_PULLS_JSON:-[]}" \
      bash "$PUB" "$set_dir" --org Acme-Inc "$@" ) \
    >"${WORK}/pub-${cid}.out" 2>"${WORK}/pub-${cid}.err"
  PUB_RC=$?
}

run_pub D1 "$OUTC" --pr
if [ $PUB_RC -eq 0 ] \
   && git -C "${FORGE}/acme-generator.git" show-ref --verify -q refs/heads/templating/update-v1.2.3 \
   && ! git -C "${FORGE}/acme-generator.git" show-ref --verify -q refs/heads/main; then
  ok "D1 --pr pushed templating/update-v1.2.3 and NEVER main"
else bad "D1 pr push (rc=$PUB_RC): $(tail -n3 "${WORK}/pub-D1.err" | tr '\n' ' ')"; fi
grep -q "POST http://forgejo.test:3000/api/v1/repos/Acme-Inc/acme-generator/pulls" "${WORK}/curl-D1.log" \
  && ok "D2 Forgejo PR endpoint hit (POST /repos/{owner}/{repo}/pulls)" || bad "D2 PR endpoint"
grep -q "/api/v1/orgs/Acme-Inc/repos" "${WORK}/curl-D1.log" \
  && ok "D2b repo-ensure endpoint hit" || bad "D2b repo ensure"
if ! grep -q "$PAT" "${WORK}/curl-D1.log" && ! grep -q "$PAT" "${WORK}/pub-D1.out" "${WORK}/pub-D1.err"; then
  ok "D3 PAT never on any curl argv / output (header-file custody held)"
else bad "D3 PAT LEAKED to argv/output"; fi
grep -q '"ref": "v1.2.3"' "${OUTC}/acme-generator/.hugmesh-provenance.json" 2>/dev/null \
  && ok "D4 provenance stamped base.ref=v1.2.3" || bad "D4 provenance base.ref"

# 409 leg: repo + PR already exist -> open-list lookup -> PATCH /pulls/7.
STUB_REPO_CODE=409 STUB_PR_CODE=409 STUB_PATCH_CODE=200 \
STUB_PULLS_JSON='[{"number":7,"head":{"ref":"templating/update-v1.2.3"}}]' \
run_pub D5 "$OUTC" --pr
if [ $PUB_RC -eq 0 ] && grep -q "PATCH http://forgejo.test:3000/api/v1/repos/Acme-Inc/acme-generator/pulls/7" "${WORK}/curl-D5.log"; then
  ok "D5 create-or-update: 409 -> open-PR lookup -> PATCH /pulls/7"
else bad "D5 update leg (rc=$PUB_RC): $(tail -n3 "${WORK}/pub-D5.err" | tr '\n' ' ')"; fi
unset STUB_REPO_CODE STUB_PR_CODE STUB_PATCH_CODE STUB_PULLS_JSON

# 409 with NO matching open PR -> fail-closed.
STUB_REPO_CODE=409 STUB_PR_CODE=409 STUB_PULLS_JSON='[]' run_pub D6 "$OUTC" --pr
[ $PUB_RC -ne 0 ] && ok "D6 409-but-no-open-PR fails closed" || bad "D6 phantom-PR accepted"
unset STUB_REPO_CODE STUB_PR_CODE STUB_PULLS_JSON

# marker/--ref disagreement -> refuse.
run_pub D7 "$OUTC" --pr --ref v9.9.9
[ $PUB_RC -ne 0 ] && grep -q "version drift" "${WORK}/pub-D7.err" \
  && ok "D7 --ref vs in-tree marker mismatch refused (render/publish drift)" || bad "D7 drift accepted"

# --pr with NO version anywhere (tree rendered without --ref) -> refuse.
run_pub D8 "$OUTB" --pr
[ $PUB_RC -ne 0 ] && ok "D8 --pr without a base version refused" || bad "D8 versionless --pr accepted"

# Default (no --pr) delivery unchanged: main ff-only push, ZERO /pulls calls.
FORGE2="${WORK}/forge2"; mkdir -p "$FORGE2"; git init -q --bare "${FORGE2}/acme-generator.git"
OUTD="${WORK}/outD"; mkdir -p "$OUTD"; cp -a "${OUTB}/acme-generator" "${OUTD}/acme-generator"
CURL_LOG="${WORK}/curl-D9.log"; : > "$CURL_LOG"
( cd "$REPO" && env PATH="${STUB}:$PATH" CURL_LOG="$CURL_LOG" \
    FORGEJO_PUSH_TOKEN_FILE="$TOKF" FORGEJO_API_MODE=rest \
    FORGEJO_BASE_URL="http://forgejo.test:3000" \
    FORGEJO_REMOTE_TEMPLATE="file://${FORGE2}/%s.git" \
    REPO_BASE_CACHE="$CACHE" \
    bash "$PUB" "$OUTD" --org Acme-Inc ) >"${WORK}/pub-D9.out" 2>"${WORK}/pub-D9.err"
rc=$?
if [ $rc -eq 0 ] && git -C "${FORGE2}/acme-generator.git" show-ref --verify -q refs/heads/main \
   && ! grep -q "/pulls" "${WORK}/curl-D9.log"; then
  ok "D9 default mode unchanged: main pushed ff-only, no PR API calls"
else bad "D9 default mode (rc=$rc): $(tail -n3 "${WORK}/pub-D9.err" | tr '\n' ' ')"; fi

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "$F" -eq 0 ] || exit 1
exit 0
