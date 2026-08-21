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
#       archetype 'generator' and its residual sweep stays green; plus the
#       ALL-archetype drift sweep (validate-repo-templates-all.sh) grading every
#       archetype on disk, failing closed on a base it cannot resolve, EXITING
#       NON-ZERO ON A REAL INJECTED DRIFT (the negative control — without it the
#       sweep's RC can be switched off with this suite still green), and being
#       actually WIRED into an un-waivable .gitlab-ci.yml job.
#   [C] --ref plumbing — pull-repo-base.sh --ref (fresh clone at a tag, cached
#       re-pin, fail-closed bogus ref, --foreign refusal), render-repo-tree.sh
#       --ref (tag content rendered, .hugmesh-base-ref marker written).
#   [D] publish --pr — branch templating/update-<ref> pushed (main NEVER),
#       Forgejo POST /pulls recorded, 409 -> open-list -> PATCH leg, provenance
#       base.ref stamp, PAT never on any argv, marker/--ref mismatch refusal,
#       --pr-without-version refusal; default (no --pr) mode still pushes main
#       ff-only with no /pulls call.
#
# A MISSING TOOL IS INCOMPLETE (exit 3), NEVER A GREEN SKIP. This suite used to
# print one SKIP line and exit 0 when node/jq/handlebars were absent, so an
# unprovisioned host reported success for a run that checked NOTHING — and
# handlebars is not installed by anything in a fresh checkout, so a "61 passed"
# sweep could be a skip nobody read. Same disease, same cure as
# scripts/validate-reserved-prefixes.sh's INCOMPLETE exit: fail loudly, and make
# the opt-out explicit. ALLOW_SKIP=1 downgrades it to exit 0 for a developer who
# knowingly lacks the toolchain. NEVER set that in CI — templating-rename-verify
# installs handlebars precisely so the suite runs.
set -uo pipefail

ALLOW_SKIP="${ALLOW_SKIP:-0}"
_skip() {
  echo "SKIP: $*"
  [ "${ALLOW_SKIP}" = "1" ] && exit 0
  echo "INCOMPLETE: this suite checked nothing — install the missing tool, or re-run" >&2
  echo "with ALLOW_SKIP=1 to accept an unchecked run. Refusing to exit 0." >&2
  exit 3
}

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECIPE_JS="${REPO}/scripts/tooling/render-recipe.js"
RRT="${REPO}/scripts/render-repo-tree.sh"
PRB="${REPO}/scripts/pull-repo-base.sh"
PUB="${REPO}/scripts/publish-tenant-set.sh"
RTS_JS="${REPO}/scripts/tooling/render-tenant-set.js"

# python3 + PyYAML are for the [B] CI-wiring case (B11) and for the drift-injection
# in B10: both READ .gitlab-ci.yml / a recipe.yaml as YAML rather than grepping it,
# the same way tests/scripts/test-reserved-prefix-copy-gate.sh case (f) does. They go
# through _skip like every other tool here — an unparseable-because-untooled run is
# INCOMPLETE (exit 3), never a green one.
for t in node jq git tar realpath sha256sum python3; do
  command -v "$t" >/dev/null || _skip "need $t"
done
python3 -c 'import yaml' 2>/dev/null || _skip "need PyYAML (python3 -c 'import yaml')"
[ -d "${REPO}/scripts/tooling/node_modules/handlebars" ] \
  || _skip "handlebars not installed (cd scripts/tooling && npm install)"

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

# The env key's LIVE spelling, and it earns its own case for exactly the reason
# A9k does one prefix down. On 2026-08-20 the producers flipped: compose.local.yaml,
# the Makefile's STACK_THEME_ENV, the Studio's _build_env and the login-theme
# ConfigMap now travel under HUG_THEME_CSS, and SNAP_THEME_CSS became the legacy
# twin the entrypoint hooks still fall back to. A9g alone would from that day on
# have been guarding only the DYING name while the load-bearing one went
# unregistered — a guard that passes its own test and protects nothing, which is
# the failure A9k was added to prevent for --hug-* vs --sd-*. Both names stay
# pinned: the legacy one is still read by every 50-snap-theme.sh in the fleet, so
# templating it breaks the hand-off just as silently.
run_recipe A9m 'edits:
  - file: docs/BRANDING.md
    anchors:
      - { id: env, find: "{{HUG_THEME_CSS}}", replace: "x" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9m.err" && ok "A9m theme contract identifier {{HUG_THEME_CSS}} refused (LIVE env key)" || bad "A9m live theme env key templated"

# The LIVE spelling of the locale-set key, and the same argument A9k makes for
# --hug-*: rename phase 3c moved every producer (Makefile STACK_WEB_LOCALES,
# LocalStackNode._build_env, the compose build arg) onto HUG_WEB_LOCALES, so that
# is now the name that decides which translation catalogs the login-ui image
# ships. A guard registered against only the retired SNAP_ spelling would pass its
# own test while leaving the load-bearing name open to the next rebrand sweep —
# and the failure is silent: the chain still builds, still boots, still exits 0,
# and serves a UI with no translations. Both spellings stay pinned until phase 4
# proves nothing reads the old one (the login-ui Dockerfile still does).
run_recipe A9n 'edits:
  - file: docs/BRANDING.md
    anchors:
      - { id: env, find: "{{HUG_WEB_LOCALES}}", replace: "x" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9n.err" && ok "A9n theme contract identifier {{HUG_WEB_LOCALES}} refused (LIVE locale key)" || bad "A9n live web-locales env key templated"

run_recipe A9o 'edits:
  - file: docs/BRANDING.md
    anchors:
      - { id: env, find: "{{SNAP_WEB_LOCALES}}", replace: "x" }' "$T"
[ $RC -ne 0 ] && grep -q "CONTRACT" "${WORK}/recipe-A9o.err" && ok "A9o theme contract identifier {{SNAP_WEB_LOCALES}} refused (retired locale key still read)" || bad "A9o retired web-locales env key templated"

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

# B9 guards the SWEEP the B8 gate is wired into. B8 grades ONE archetype and was, for
# most of this gate's life, its ONLY automated caller — the other five overlays rotted
# behind it, three of them carrying a drift no pipeline could see. scripts/validate-
# repo-templates-all.sh ENUMERATES templates/archetypes/*, so this asserts (a) every
# archetype directory on disk shows up in the summary — a hardcoded list is how the
# coverage hole happened in the first place — and (b) an archetype whose base cannot
# be resolved is reported ERROR and FAILS the sweep, because an unrunnable gate is the
# same vacuous green as a missing one. Hermetic: OFFLINE=1 over an EMPTY base cache, so
# the five exemplar members are deliberately unreachable and only `generator` (whose
# base is this checkout) can grade.
#
# HERMETIC MEANS env -i. This case originally inherited the developer's shell, and
# this repo's own documented offline workflow is to EXPORT <NAME>_BASE_DIR at a local
# clone of each exemplar — so a developer following the docs handed the sweep five
# resolvable bases, the sweep passed, and B9's "exited 0 with every base unreachable"
# assertion fired as a FALSE FAILURE. It did not show up when the sweep landed only
# because three overlays were drifting at the time, so the sweep was red either way;
# the moment those drifts were fixed (#116, admin-bff-api#39, remote-fragment#12) the
# same suite passed from a bare shell and failed from a configured one. A case whose
# verdict depends on the caller's environment is not a test. env -i, and the sweep's
# own REPO_ROOT default is what still gives `generator` a base.
ALL_ARCH="$(for d in "${REPO}"/templates/archetypes/*/; do basename "$d"; done | sort)"
if ( cd "$REPO" && env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
      OFFLINE=1 REPO_BASE_CACHE="${WORK}/empty-base-cache" \
      bash scripts/validate-repo-templates-all.sh ) >"${WORK}/B9.out" 2>"${WORK}/B9.err"; then
  bad "B9 archetype sweep exited 0 with every exemplar base unreachable — vacuous green"
else
  SEEN="$(sed -n 's/^  \(PASS\|DRIFT\|ERROR\)  *\([a-z0-9-]*\).*/\2/p' "${WORK}/B9.out" | sort)"
  [ "$SEEN" = "$ALL_ARCH" ] \
    && ok "B9 archetype sweep grades EVERY archetype on disk ($(echo $ALL_ARCH | tr '\n' ' '))" \
    || bad "B9 sweep covered [$(echo $SEEN | tr '\n' ' ')] of [$(echo $ALL_ARCH | tr '\n' ' ')]"
  grep -q "^  ERROR " "${WORK}/B9.out" \
    && ok "B9b an unresolvable base is reported ERROR and fails the sweep (not skipped green)" \
    || bad "B9b unreachable bases did not surface as ERROR"
  grep -qE "^  PASS  +generator( |$)" "${WORK}/B9.out" \
    && ok "B9c the sweep still grades 'generator' against this checkout (B8's base, offline)" \
    || bad "B9c generator archetype was not graded against this checkout"
fi

# ── B10 THE NEGATIVE CONTROL: A REAL DRIFT MUST MAKE THE SWEEP EXIT NON-ZERO ───
# B9/B9b/B9c all run the sweep with every exemplar base deliberately UNREACHABLE, so
# every archetype but `generator` lands in the ERROR arm and NOTHING there ever grades
# a drifted overlay. That leaves the one property the gate exists for unasserted, and
# it is not a theoretical gap: moving the shared `RC=1` into the ERROR arm of the
# sweep's `case` — a one-line edit — leaves this suite at 64 passed / 0 failed, exit 0,
# while the sweep prints `DRIFT generator` AND `RESULT: PASS`, and exits 0. A gate that
# can be switched off with the suite still green is not a gate.
#
# So: grade a REAL drift, hermetically. `generator` is the archetype that can be graded
# offline (its base is a local checkout), so the sweep runs in a scratch tree holding
# ONLY that archetype, against THIS repo as the base:
#   1. IN SYNC   -> rc 0 and the clean PASS verdict          (vacuity control: the lab
#                                                             is capable of passing, so
#                                                             step 2's red is the drift)
#   2. DRIFTED   -> rc NON-ZERO, `DRIFT generator` in the summary, and NO clean PASS.
# BOTH HALVES ARE ASSERTED — exit status AND verdict line — because the mutation above
# produced exactly the contradictory pair (`DRIFT generator` + `RESULT: PASS`): checking
# only the summary, or only the status, misses half of it.
#
# The injected drift is the SAME SHAPE the three live ones had: a required anchor whose
# `find` literal no longer occurs in the base. Appending a marker to find AND replace
# keeps the replace==find round-trip a no-op, so it is the presence check — and only the
# presence check — that bites.
echo "-- [B] drift negative control: a real drift must fail the sweep --"
LAB="${WORK}/driftlab"
mkdir -p "${LAB}/templates"
tar -c -C "$REPO" --exclude='scripts/tooling/node_modules' scripts | tar -x -C "$LAB"
# node_modules is 10MB of unchanging vendor tree; the gate only ever reads it.
ln -s "${REPO}/scripts/tooling/node_modules" "${LAB}/scripts/tooling/node_modules"
cp -a "${REPO}/templates/archetypes" "${LAB}/templates/archetypes"
for d in "${LAB}"/templates/archetypes/*/; do
  [ "$(basename "$d")" = generator ] || rm -rf "$d"
done

_sweep_lab() { # <outfile> -> rc of the sweep in the lab tree
  ( cd "$LAB" && env -i PATH="$PATH" HOME="${HOME:-/tmp}" OFFLINE=1 \
      GENERATOR_BASE_DIR="$REPO" bash scripts/validate-repo-templates-all.sh ) \
    >"$1" 2>&1
}
CLEAN_PASS='^RESULT: PASS — every archetype overlay is in sync'

if _sweep_lab "${WORK}/B10a.out" && grep -qE "$CLEAN_PASS" "${WORK}/B10a.out"; then
  ok "B10 vacuity control: the one-archetype lab is GREEN in sync (rc 0 + clean PASS)"
else
  bad "B10 lab is not green before the drift is injected — the control below proves nothing: $(tail -n3 "${WORK}/B10a.out" | tr '\n' ' ')"
fi

RECIPE="${LAB}/templates/archetypes/generator/recipe.yaml" \
python3 - >"${WORK}/B10.inject" 2>&1 <<'PY'
import os, sys, yaml
p = os.environ["RECIPE"]
doc = yaml.safe_load(open(p))
MARK = " NO-SUCH-LITERAL-IN-ANY-UPSTREAM-BASE"
hit = None
for e in doc.get("edits") or []:
    for a in e.get("anchors") or []:
        if a.get("required") is True:
            a["find"] += MARK
            a["replace"] += MARK        # keep replace==find: only PRESENCE breaks
            hit = "%s#%s" % (e.get("file"), a.get("id"))
            break
    if hit:
        break
if not hit:
    print("NO_REQUIRED_ANCHOR")
    sys.exit(1)
yaml.safe_dump(doc, open(p, "w"), sort_keys=False, default_flow_style=False, width=4096)
print("INJECTED", hit)
PY
if grep -q '^INJECTED ' "${WORK}/B10.inject"; then
  ok "B10 injected a real drift ($(sed -n 's/^INJECTED //p' "${WORK}/B10.inject") — required anchor, find absent from base)"
else
  bad "B10 could not inject a drift: $(tr '\n' ' ' <"${WORK}/B10.inject") — the control below is vacuous"
fi

_sweep_lab "${WORK}/B10b.out"; DRIFT_RC=$?
[ "$DRIFT_RC" -ne 0 ] \
  && ok "B10 A REAL DRIFT FAILS THE SWEEP (exit ${DRIFT_RC})" \
  || bad "B10 the sweep EXITED 0 on a genuinely drifted overlay — the gate is off"
grep -qE "$CLEAN_PASS" "${WORK}/B10b.out" \
  && bad "B10b the sweep still printed the clean PASS verdict over a drifted overlay — a reader is told the tree is in sync" \
  || ok "B10b the drifted sweep never prints the clean PASS verdict"
grep -qE '^  DRIFT  *generator( |$)' "${WORK}/B10b.out" \
  && ok "B10c the drifted archetype is reported DRIFT (graded and bit), not ERROR (never graded)" \
  || bad "B10c drifted overlay not summarised as DRIFT: $(grep -E '^  (PASS|DRIFT|ERROR)' "${WORK}/B10b.out" | tr '\n' ' ')"

# ── B11 THE CI WIRING IS PART OF THE GATE ─────────────────────────────────────
# The original defect was not "the sweep is wrong", it was "no pipeline ever ran the
# single-archetype gate", and three overlays rotted behind that. The sweep and its CI
# job landed together — but NOTHING asserted the job. Deleting the whole
# template-drift-verify block from .gitlab-ci.yml leaves valid YAML, and every suite
# stays exactly as green as before: this file 64/0, test-gitlab-ci-wellformed.sh 9/0,
# test-guard-integrity.sh byte-identical. So the original defect could be restored in
# full, silently — as could `allow_failure: true`, which is the same thing with extra
# steps. tests/scripts/test-reserved-prefix-copy-gate.sh case (f) already solved this
# shape for the sibling gate; this is that check for this one.
echo "-- [B] CI wiring: template-drift-verify must exist and must be able to fail --"
CI_FILE="${REPO}/.gitlab-ci.yml"
if [ ! -r "$CI_FILE" ]; then
  bad "B11 no .gitlab-ci.yml at ${CI_FILE}"
else
CI="$CI_FILE" python3 - >"${WORK}/B11.out" 2>&1 <<'PY'
import os, yaml
ci = yaml.safe_load(open(os.environ["CI"])) or {}
job = ci.get("template-drift-verify")
if not isinstance(job, dict):
    print("MISSING_JOB")
    raise SystemExit(0)
script = job.get("script") or []
if isinstance(script, str):
    script = [script]
before = job.get("before_script") or []
if isinstance(before, str):
    before = [before]
allsh = " ".join(str(x) for x in list(script) + list(before))
rules = job.get("rules") if isinstance(job.get("rules"), list) else []
changes = [c for r in rules if isinstance(r, dict) for c in (r.get("changes") or [])]

print("RUNS_SWEEP", "yes" if "validate-repo-templates-all.sh" in allsh else "no")
print("STAGE", job.get("stage"))
print("ON_DEFAULT_BRANCH", "yes" if any(
    isinstance(r, dict) and "CI_DEFAULT_BRANCH" in str(r.get("if", "")) for r in rules) else "no")
# allow_failure: true (or an exit_codes form) makes a red gate a green pipeline.
print("ALLOW_FAILURE", "yes" if job.get("allow_failure") not in (None, False) else "no")
print("HAS_HANDLEBARS", "yes" if ("npm ci" in allsh and "node_modules/handlebars" in allsh) else "no")
print("SETS_GIT_BASE", "yes" if "GIT_BASE" in allsh else "no")
# The job must re-run when an overlay OR the sweep itself changes.
for label, want in (("WATCHES_OVERLAYS", "templates/archetypes/**/*"),
                    ("WATCHES_SWEEP", "scripts/validate-repo-templates-all.sh")):
    print(label, "yes" if (not changes or want in changes) else "no")

# DEFECT 4: the suite that GUARDS the sweep must itself re-run when the sweep changes.
guard = ci.get("templating-rename-verify")
if not isinstance(guard, dict):
    print("MISSING_GUARD_JOB")
else:
    grules = guard.get("rules") if isinstance(guard.get("rules"), list) else []
    gchanges = [c for r in grules if isinstance(r, dict) for c in (r.get("changes") or [])]
    missing = [w for w in ("scripts/validate-repo-templates.sh",
                           "scripts/validate-repo-templates-all.sh")
               if gchanges and w not in gchanges]
    print("GUARD_WATCHES_SWEEP", "-" if not missing else " ".join(missing))
PY
  if grep -q '^MISSING_JOB$' "${WORK}/B11.out"; then
    bad "B11 no template-drift-verify job in .gitlab-ci.yml — the archetype gate is wired into no CI, which is the defect it was added to fix"
  else
    _b11() { grep -q "^$1 $2\$" "${WORK}/B11.out" && ok "B11 $3" || bad "B11 $4"; }
    _b11 RUNS_SWEEP yes \
      "template-drift-verify runs scripts/validate-repo-templates-all.sh" \
      "template-drift-verify never runs the sweep — the job is decoration"
    _b11 STAGE verify \
      "template-drift-verify is in the 'verify' stage" \
      "template-drift-verify stage is '$(sed -n 's/^STAGE //p' "${WORK}/B11.out")', expected 'verify'"
    _b11 ON_DEFAULT_BRANCH yes \
      "template-drift-verify runs on the default branch (drift is re-checked on main)" \
      "template-drift-verify has no \$CI_DEFAULT_BRANCH rule — merged drift is never re-checked"
    _b11 ALLOW_FAILURE no \
      "template-drift-verify does NOT carry allow_failure — a drift stops the pipeline" \
      "template-drift-verify sets allow_failure — a red gate would leave the pipeline green"
    _b11 HAS_HANDLEBARS yes \
      "template-drift-verify installs handlebars AND fail-closes if the install no-ops" \
      "template-drift-verify does not npm ci + assert node_modules/handlebars — the gate would exit 2 environmentally"
    _b11 SETS_GIT_BASE yes \
      "template-drift-verify exports GIT_BASE so the exemplar bases actually resolve" \
      "template-drift-verify never sets GIT_BASE — every archetype would be ERROR (unresolvable base)"
    _b11 WATCHES_OVERLAYS yes \
      "template-drift-verify re-runs when an archetype overlay changes" \
      "template-drift-verify's rules:changes does not cover templates/archetypes/**/* — editing an overlay cannot run the gate"
    _b11 WATCHES_SWEEP yes \
      "template-drift-verify re-runs when the sweep script changes" \
      "template-drift-verify's rules:changes does not cover the sweep script"
    if grep -q '^MISSING_GUARD_JOB$' "${WORK}/B11.out"; then
      bad "B11 no templating-rename-verify job — nothing runs this suite"
    else
      _b11 GUARD_WATCHES_SWEEP - \
        "templating-rename-verify re-runs this suite when validate-repo-templates*.sh changes" \
        "templating-rename-verify's rules:changes omits $(sed -n 's/^GUARD_WATCHES_SWEEP //p' "${WORK}/B11.out") — an MR touching only the sweep skips the suite that guards it"
    fi
  fi
fi

# ── [C] --ref plumbing against a LOCAL file:// upstream ────────────────────────
# ── B12/B13 AN UNRUNNABLE SWEEP MUST BE RED, NOT A CLEAN PASS ─────────────────
# The sweep's own header states the rule: "an unrunnable gate is the same vacuous
# green as a missing one". B10 proves a DRIFTED overlay fails and B11 proves the CI
# job exists — but nothing asserted that rule itself, and two one-line mutations walk
# straight through both:
#
#   * drop `[[ ${#ARCHETYPES[@]} -gt 0 ]] || _die` and point the sweep at an EMPTY
#     templates/archetypes/. The for-loop runs zero times, RC stays 0, and the sweep
#     prints — verbatim —
#         == archetype drift summary (0 archetype(s)) ==
#         RESULT: PASS — every archetype overlay is in sync with its exemplar base.
#     and exits 0. Zero overlays checked, every overlay declared in sync. That is the
#     exact disease this whole gate exists to cure, reproduced inside the gate.
#
#   * change `_die`'s `exit 2` to `exit 0`. Every FATAL — missing single-archetype
#     gate, absent templates/archetypes — then prints to stderr and exits 0, so CI
#     goes green on a gate that never graded a single archetype.
#
# Both left this suite at 78 passed / 0 failed. They are asserted here as BEHAVIOUR
# (run the sweep in a scratch tree and read its exit status), never as a grep for the
# guard's source text — a test that greps for the line it wants would be satisfied by
# a commented-out one.
echo "-- [B] an unrunnable sweep must be RED (empty set / fatal) --"

# B12: templates/archetypes exists and is EMPTY. Nothing to grade => must NOT pass.
B12LAB="${WORK}/emptylab"
mkdir -p "${B12LAB}/templates/archetypes"
tar -c -C "$REPO" --exclude='scripts/tooling/node_modules' scripts | tar -x -C "$B12LAB"
ln -s "${REPO}/scripts/tooling/node_modules" "${B12LAB}/scripts/tooling/node_modules"
( cd "$B12LAB" && env -i PATH="$PATH" HOME="${HOME:-/tmp}" OFFLINE=1 \
    bash scripts/validate-repo-templates-all.sh ) >"${WORK}/B12.out" 2>&1
B12_RC=$?
[ "$B12_RC" -ne 0 ] \
  && ok "B12 an EMPTY archetype set fails the sweep (exit ${B12_RC}) — zero graded is not a pass" \
  || bad "B12 the sweep EXITED 0 having graded ZERO archetypes — vacuous green inside the drift gate itself"
grep -qE "$CLEAN_PASS" "${WORK}/B12.out" \
  && bad "B12b the sweep printed 'every archetype overlay is in sync' after grading NOTHING — a reader is told the tree is clean" \
  || ok "B12b the empty sweep never claims every overlay is in sync"

# B13: the single-archetype gate is MISSING. _die must be fatal, not advisory.
B13LAB="${WORK}/nogatelab"
mkdir -p "${B13LAB}/scripts" "${B13LAB}/templates/archetypes/generator"
cp "${REPO}/scripts/validate-repo-templates-all.sh" "${B13LAB}/scripts/"
# validate-repo-templates.sh is deliberately NOT copied.
( cd "$B13LAB" && env -i PATH="$PATH" HOME="${HOME:-/tmp}" OFFLINE=1 \
    bash scripts/validate-repo-templates-all.sh ) >"${WORK}/B13.out" 2>&1
B13_RC=$?
[ "$B13_RC" -ne 0 ] \
  && ok "B13 a missing single-archetype gate is FATAL (exit ${B13_RC}), not a silent pass" \
  || bad "B13 the sweep EXITED 0 with the gate binary absent — it graded nothing and reported success"
grep -qE "$CLEAN_PASS" "${WORK}/B13.out" \
  && bad "B13b the sweep claimed every overlay is in sync while its own gate was missing" \
  || ok "B13b the fatal sweep never claims every overlay is in sync"

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
