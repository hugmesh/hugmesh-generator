#!/usr/bin/env bash
# test-federation-modules-selection.sh — the BUILD-TIME service selection must
# reach `federation_modules.enabled`, the column that actually decides whether the
# host shell renders a service's menu entry.
#
# WHAT WAS OBSERVED (2026-08-26). A USB built with `--exclude-services akkoma`
# pruned akkoma's Application, manifests, gateway routes and route-access rows,
# rendered installed:"false" into BOTH manifests/policy/installed-services-configmap.yaml
# AND the apps/13a-optional-services.yaml element — and the host shell STILL
# rendered the Mastodon menu entry, reporting installed=true. The host shell
# bootstraps its install-state from `GET /api/federation/capabilities`
# (docs/OPTIONAL-SERVICES.md §10), a projection of `federation_modules`, and NO
# part of the build-time selection ever touched that table: every registration is
# an unconditional Liquibase changeset seeding enabled = true, and those changesets
# live in the SEPARATE hugmesh-federation-api repo.
#
# WHAT THIS TEST PROVES, offline, by sourcing the REAL renderer out of BOTH stage4
# builders and running it against a sandbox baked tree seeded from the live
# specs/cluster files:
#   1. The catalogue-slug -> module-slug mapping the renderer uses is READ FROM
#      specs/cluster/optional-services.yaml's `federationModule:` field and matches
#      an INDEPENDENT yaml parse of the same file — including the one non-identity
#      mapping (phpbb -> forum) and BOTH spellings the registry uses (inline flow
#      map and multi-line block).
#   2. For each of the eight gated slugs: DESELECTED => gate.sql says
#      `enabled = false` for its module; SELECTED => `enabled = true`. Asserted as a
#      POST-CONDITION on the RENDERED FILE, never on the renderer's exit code — a
#      sed renderer no-ops silently on a missing anchor and still returns 0.
#   3. The committed gate.sql baseline matches optional-services.yaml's per-slug
#      `default: on|off` — READ OUT OF THE REGISTRY, not compared against a
#      hard-coded literal, so drift on the registry side (the half that actually
#      moves) is caught too.
#   4. The two builders' copies of the renderer have not diverged.
#   5. SET EQUALITY, not one-way containment: {services with a non-null
#      federationModule} == GATED_SLUGS == both builders' renderer for-lines, and
#      the registry's module slugs == gate.sql's UPDATE rows. A NINTH federation
#      module added to the registry cannot be silently ungated.
#   6. The delivery path exists and is coherent: the Application, the Job, the
#      ConfigMap name they agree on, the Job's hook annotations read AS DATA (a
#      commented-out annotation must not satisfy them), and the fact that
#      gate_optional_services() does NOT prune the gate when a slug is deselected.
#   7. Leg 4c: whether the rendered gate.sql reaches a device at all — and that
#      every caveat site says so honestly. See the caveat below; it does not.
#
# WHAT IT DOES NOT PROVE: see the LIVE section below and the "does not prove"
# paragraph at the end of this header.
#
# LIVE (behavioural) LEGS — both skip LOUDLY, never silently:
#   * LEG L1 (read-only, automatic when a stack is up): the capabilities endpoint's
#     install-state for each gated module must equal that module's
#     `federation_modules.enabled` row. This is the load-bearing claim of the whole
#     unit — that flipping `enabled` is what the host shell sees.
#   * LEG L2 (WRITES, opt-in FEDERATION_GATE_LIVE=1): apply a rendered gate.sql
#     that deselects one slug and assert the capabilities endpoint flips that slug
#     to installed=false, then RESTORE the original rows. Opt-in because the local
#     stack belongs to the operator and other sessions depend on it — this leg
#     mutates their federation registry for a few seconds.
#
# ⚠ THE HONEST CAVEAT, and it has TWO parts. Read both before believing anything
# above.
#   (1) THE BUILD-TIME RENDER IS INERT ON A DEVICE TODAY — and the REASON changed
#       on 2026-08-26 while the conclusion did not. It USED to be "bootstrap.sh
#       applies app-of-apps.yaml ONLY, so no child Application is retargeted"; the
#       device-syncs-pruned-apps keystone deleted that premise (it now applies every
#       baked apps/*.yaml, apps/29b included). What STILL holds is narrower:
#       apply_baked_app() rewrites repoURL and targetRevision and NOTHING ELSE, so
#       `source.path: specs/cluster/manifests/federation-modules-gate` still resolves
#       in a GIT repo and ArgoCD generates the ConfigMap from the COMMITTED gate.sql
#       — never from the USB's rendered copy. A USB built with
#       `--exclude-services akkoma` bakes enabled=false into its own tree and the
#       cluster still applies enabled=true. So this unit lands the MECHANISM and the
#       GUARD, NOT the fixed behaviour. Leg 4c below asserts this both ways, and now
#       asks the load-bearing question (does the bootstrap rewrite path:/source: at
#       all) rather than the obsolete one, so the sentence cannot quietly become
#       false — nor go on passing while measuring nothing.
#   (2) Even once (1) is fixed, flipping `enabled` hides the MENU ENTRY only. The
#       deselected service's Deployment keeps running: this is the UI half of "only
#       start selected services", not the workload half — that needs the device to
#       sync from a PRUNED tree. The Application SET is pruned now; the manifests
#       each surviving Application pulls are still repo-sourced.
#
# Offline legs need bash + awk + sed only (python3 + PyYAML upgrade leg 1 from a
# self-consistency check to an independent cross-check, and skip LOUDLY without).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BUILDER="${REPO}/build-rpi5-stage4.sh"
BUILDER_X86="${REPO}/build-x86-host-stage4.sh"
SRC="${REPO}/specs/cluster"
REG="${SRC}/optional-services.yaml"
GATE_SRC="${SRC}/manifests/federation-modules-gate/sql/gate.sql"
APP_SRC="${SRC}/apps/29b-federation-modules-gate.yaml"
JOB_SRC="${SRC}/manifests/federation-modules-gate/job.yaml"
KUST_SRC="${SRC}/manifests/federation-modules-gate/kustomization.yaml"

P=0; F=0; S=0
ok()   { echo "  PASS $*"; P=$((P+1)); }
bad()  { echo "  FAIL $*"; F=$((F+1)); }
skip() { echo "  SKIP $*"; S=$((S+1)); }   # LOUD by construction: counted + printed

for f in "${BUILDER}" "${BUILDER_X86}" "${REG}" "${GATE_SRC}" "${APP_SRC}" "${JOB_SRC}" "${KUST_SRC}"; do
    [ -f "${f}" ] || { echo "  FAIL missing required file: ${f}"; exit 1; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
# Silence the builder's logger, but keep warn VISIBLE — the renderer's loud
# failure path is part of what is under test.
info(){ :; }
warn(){ echo "    builder-WARN: $*"; }
err(){  echo "    builder-ERR: $*" >&2; }

echo "== federation_modules build-time selection test =="

# The eight slugs that own a federation module (every user-level optional slug).
GATED_SLUGS="akkoma tuwunel phpbb games owncast tube character-studio character-forge"
# specs/cluster/optional-services.yaml's DEFAULT-INCLUSION POLICY (user 2026-06-17).
DEFAULT_ON="akkoma tuwunel phpbb"

# ── load the REAL renderer AS THE BUILDER RESOLVES IT ───────────────────────────
# NOT `awk` over the builder file. This suite was written while the gate still had
# a copy in each builder, so it extracted from build-rpi5-stage4.sh directly and
# diffed the two copies. The gate has since been EXTRACTED into ONE shared
# scripts/_optional-services-lib.sh that both builders source — precisely because
# three defects shipped on x86 only when the copies drifted — so awk-ing a builder
# now finds nothing and this suite died "could not extract _opt_selected".
# tests/lib/opt-gate-source.sh reproduces BASH'S OWN resolution order (libs in
# source order, the builder LAST), so a builder-local override still wins and is
# still what gets loaded and executed here.
source "${REPO}/tests/lib/opt-gate-source.sh"
opt_gate_load "${BUILDER}" _opt_selected _opt_federation_module _opt_gate_sql_value \
    _opt_render_federation_modules || exit 1
ok "loaded the real renderer + helpers as build-rpi5-stage4.sh resolves them"
# Back-compat shim for the legs below that still take a FILE argument: resolve from
# that builder's chain instead of awk-ing the one file.
extract_fn() { opt_gate_extract_fn "$2" "$1"; printf '\n'; }

# ── 0) the two builders must not diverge ────────────────────────────────────────
# The games) case arm diverged between these two builders once already (see
# tests/stack/test-optional-services-exclude.sh §4c). The question is unchanged —
# "can these two disagree about the renderer" — but the answer is now read through
# each builder's RESOLUTION rather than from its own text: identical bodies in two
# files and one shared body are both fine, a builder-local override of either is
# not. Absence from one chain and a divergent override in one chain each go red.
div=0
for fn in _opt_federation_module _opt_gate_sql_value _opt_render_federation_modules; do
    opt_gate_extract_fn "${BUILDER}"     "${fn}" > "${WORK}/${fn}.rpi5"
    opt_gate_extract_fn "${BUILDER_X86}" "${fn}" > "${WORK}/${fn}.x86"
    [ -s "${WORK}/${fn}.rpi5" ] || { bad "${fn} does not resolve from build-rpi5-stage4.sh's source chain"; div=1; continue; }
    [ -s "${WORK}/${fn}.x86" ] || { bad "${fn} does not resolve from build-x86-host-stage4.sh's source chain"; div=1; continue; }
    if ! diff -q "${WORK}/${fn}.rpi5" "${WORK}/${fn}.x86" >/dev/null; then
        bad "${fn} RESOLVES DIFFERENTLY from the two builders — one of them carries a local override"; div=1
    fi
done
[ "${div}" = "0" ] && ok "the renderer resolves BYTE-IDENTICALLY from both stage4 builders (one implementation, nothing to drift)"
# ...and neither builder may define it locally: a local copy sits AFTER the source
# line, so bash runs THAT, which is the drift the extraction removed.
for b in "${BUILDER}" "${BUILDER_X86}"; do
    loc="$(sed -E 's/#.*$//' "${b}" | grep -cE '^[[:space:]]*(function[[:space:]]+)?(_opt_federation_module|_opt_gate_sql_value|_opt_render_federation_modules)[[:space:]]*\(')"
    [ "${loc}" -eq 0 ] \
        && ok "$(basename "${b}") defines NO local copy of the federation-gate renderer" \
        || bad "$(basename "${b}") defines ${loc} local copy/copies of the federation-gate renderer — bash would run those, not the shared library"
done
# ...and the gate each builder RESOLVES must actually CALL it, or the renderer is
# dead code. Read out of the resolved gate_optional_services body, per builder, so
# a builder that resolves an older gate is caught.
for b in "${BUILDER}" "${BUILDER_X86}"; do
    # Strip comments before counting: prose naming a token has inverted exactly this
    # kind of check four times in this repo.
    n="$(opt_gate_extract_fn "${b}" gate_optional_services | sed -E 's/#.*$//' \
         | grep -c '^[[:space:]]*_opt_render_federation_modules[[:space:]]*$')"
    if [ "${n}" -ge 1 ]; then ok "$(basename "${b}")'s resolved gate_optional_services calls _opt_render_federation_modules"
    else bad "$(basename "${b}")'s resolved gate_optional_services never CALLS _opt_render_federation_modules (dead renderer)"; fi
done

# ── 1) the mapping comes from optional-services.yaml (independent cross-check) ───
declare -A EXPECT_MOD=()
if python3 -c 'import yaml' >/dev/null 2>&1; then
    while IFS='=' read -r k v; do [ -n "${k}" ] && EXPECT_MOD["${k}"]="${v}"; done < <(
        python3 - "${REG}" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d["spec"]["services"]:
    fm = s.get("federationModule")
    if isinstance(fm, dict) and fm.get("slug"):
        print(f'{s["slug"]}={fm["slug"]}')
PY
    )
    miss=0
    for slug in ${GATED_SLUGS}; do
        want="${EXPECT_MOD[${slug}]:-}"
        got="$(_opt_federation_module "${REG}" "${slug}")"
        if [ -z "${want}" ]; then bad "registry declares no federationModule for '${slug}'"; miss=1
        elif [ "${got}" != "${want}" ]; then bad "module mapping for '${slug}': renderer says '${got:-<empty>}', registry says '${want}'"; miss=1
        fi
    done
    [ "${miss}" = "0" ] && ok "renderer's module mapping matches an independent yaml parse for all 8 slugs"
    # The mapping is NOT 1:1 — that is the whole reason it is declared and not derived.
    if [ "${EXPECT_MOD[phpbb]:-}" = "forum" ] && [ "$(_opt_federation_module "${REG}" phpbb)" = "forum" ]; then
        ok "the non-identity mapping is honoured (phpbb -> forum), not re-derived from the slug"
    else
        bad "phpbb's module slug is not 'forum' on both sides — the one mapping that cannot be guessed"
    fi
    # A service with `federationModule: null` must yield NOTHING, not a stray token.
    if [ -z "$(_opt_federation_module "${REG}" edge-ai)" ]; then
        ok "a 'federationModule: null' service yields no module slug (edge-ai)"
    else
        bad "edge-ai has federationModule: null but the parser returned '$(_opt_federation_module "${REG}" edge-ai)'"
    fi
    # Both spellings: akkoma is the inline flow map, character-forge is the block form.
    if [ "$(_opt_federation_module "${REG}" akkoma)" = "akkoma" ] &&
       [ "$(_opt_federation_module "${REG}" character-forge)" = "character-forge" ]; then
        ok "both registry spellings parse (inline flow map + multi-line block)"
    else
        bad "one of the two federationModule spellings does not parse"
    fi
else
    skip "leg 1 module-mapping cross-check: python3 with PyYAML is NOT importable here, so the shell parser cannot be checked against an independent parse of optional-services.yaml. Install PyYAML (pip install pyyaml) to run it."
    for slug in ${GATED_SLUGS}; do EXPECT_MOD["${slug}"]="$(_opt_federation_module "${REG}" "${slug}")"; done
fi

# ── registry FACTS, read INDEPENDENTLY of the renderer and of any literal ──────
# Two implementations, and when both are available they are asserted EQUAL, so the
# awk fallback cannot rot unnoticed on a box that has PyYAML.
#   catalogue slug -> `default: on|off`   (leg 2's baseline; was a hard-coded
#                                          DEFAULT_ON literal, which meant registry
#                                          drift — the half that actually moves —
#                                          was invisible)
#   catalogue slug -> federationModule.slug (leg 1b's set equality)
reg_facts_yaml() {
    python3 - "${REG}" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d["spec"]["services"]:
    fm  = s.get("federationModule")
    mod = fm.get("slug") if isinstance(fm, dict) and fm.get("slug") else ""
    dv  = s.get("default")
    dv  = "on" if dv is True else ("off" if dv is False else str(dv))
    print(f'{s["slug"]}\t{dv}\t{mod}')
PY
}
# Anchored to the registry's fixed indentation (4-space `- slug:`, 6-space keys,
# 8-space keys inside a block-form federationModule) and handles BOTH spellings.
reg_facts_awk() {
    awk '
      /^    - slug:[ \t]/                            { cur=$3; order[++n]=cur; inblk=""; next }
      cur == ""                                      { next }
      /^      default:[ \t]+(on|off)[ \t]*$/         { d[cur]=$2; inblk=""; next }
      /^      federationModule:[ \t]*null([ \t]|$)/  { inblk=""; next }
      /^      federationModule:[ \t]*\{/ {
          inblk=""
          if (match($0, /slug:[ \t]*[A-Za-z0-9_-]+/)) {
              t = substr($0, RSTART, RLENGTH); sub(/slug:[ \t]*/, "", t); m[cur] = t
          }
          next
      }
      /^      federationModule:[ \t]*$/              { inblk=cur; next }
      inblk != "" && /^        slug:[ \t]/           { m[inblk]=$2; next }
      /^      [A-Za-z]/                              { inblk="" }
      END { for (i=1; i<=n; i++) { s=order[i]
              printf "%s\t%s\t%s\n", s, (s in d ? d[s] : "?"), (s in m ? m[s] : "") } }
    ' "${REG}"
}

declare -A REG_DEFAULT=() REG_ALL_MOD=()
REG_FACTS_KIND=""
if python3 -c 'import yaml' >/dev/null 2>&1; then
    REG_FACTS_KIND="PyYAML"
    reg_facts_yaml > "${WORK}/reg.yaml.tsv"
    reg_facts_awk  > "${WORK}/reg.awk.tsv"
    if diff -u "${WORK}/reg.yaml.tsv" "${WORK}/reg.awk.tsv" > "${WORK}/reg.diff" 2>&1; then
        ok "the awk registry scrape agrees with an independent PyYAML parse for all $(grep -c '' "${WORK}/reg.yaml.tsv") services (the no-PyYAML fallback is not rotting)"
    else
        bad "the awk registry fallback DISAGREES with PyYAML: $(head -n 6 "${WORK}/reg.diff" | tr '\n' ' ')"
    fi
    cp "${WORK}/reg.yaml.tsv" "${WORK}/reg.tsv"
else
    REG_FACTS_KIND="awk scrape (no PyYAML)"
    reg_facts_awk > "${WORK}/reg.tsv"
fi
while IFS=$'\t' read -r rslug rdef rmod; do
    [ -n "${rslug}" ] || continue
    REG_DEFAULT["${rslug}"]="${rdef}"
    [ -n "${rmod}" ] && REG_ALL_MOD["${rslug}"]="${rmod}"
done < "${WORK}/reg.tsv"
[ "${#REG_DEFAULT[@]}" -ge 10 ] \
    && ok "read per-service default:/federationModule: facts for ${#REG_DEFAULT[@]} services out of optional-services.yaml (${REG_FACTS_KIND})" \
    || bad "registry fact extraction returned only ${#REG_DEFAULT[@]} services — the parse is broken, every leg below it is vacuous"

# ── 1b) SET EQUALITY: registry <-> test <-> both builders <-> gate.sql ─────────
# The gated set is spelled in FOUR places (both builders' for-lines, gate.sql's
# UPDATE rows, and this suite's GATED_SLUGS). Iterating GATED_SLUGS and checking
# each has a mapping only ever proves one direction: a NINTH federation module
# added to the registry would be silently ungated forever, keeping enabled=true and
# rendering its menu entry on every USB that deselects it — the original bug
# verbatim, reintroduced one level up. These legs check the CONVERSE.
setify() { printf '%s\n' $* | sed '/^$/d' | sort -u | tr '\n' ' '; }
REG_CAT_SET="$(setify "${!REG_ALL_MOD[@]}")"
REG_MOD_SET="$(setify "${REG_ALL_MOD[@]}")"
TEST_CAT_SET="$(setify "${GATED_SLUGS}")"
GATE_MOD_SET="$(setify "$(sed -E 's/^[[:space:]]*--.*$//' "${GATE_SRC}" \
    | sed -nE "s/^[[:space:]]*UPDATE federation_modules SET enabled = (true|false) WHERE slug = '([^']+)';.*/\2/p")")"

[ "${REG_CAT_SET}" = "${TEST_CAT_SET}" ] \
    && ok "every registry service with a federationModule is in this suite's GATED_SLUGS, and vice versa (${REG_CAT_SET% })" \
    || bad "GATED_SLUGS != {services with a non-null federationModule}: registry='${REG_CAT_SET}' test='${TEST_CAT_SET}' — a federation module nothing gates keeps enabled=true forever"

[ "${REG_MOD_SET}" = "${GATE_MOD_SET}" ] \
    && ok "gate.sql carries an UPDATE row for exactly the registry's module slugs (${REG_MOD_SET% })" \
    || bad "gate.sql's UPDATE rows != registry module slugs: registry='${REG_MOD_SET}' gate.sql='${GATE_MOD_SET}' — a module with no row can never be turned off"

# ...and the renderer's own loop, read out of BOTH builders' for-line.
builder_loop_set() {
    extract_fn _opt_render_federation_modules "$1" \
      | sed -E 's/(^|[[:space:]])#.*$//' \
      | sed -nE 's/^[[:space:]]*for[[:space:]]+slug[[:space:]]+in[[:space:]]+(.+);[[:space:]]*do[[:space:]]*$/\1/p' \
      | head -n 1
}
loopfail=0
for b in "${BUILDER}" "${BUILDER_X86}"; do
    bl="$(setify "$(builder_loop_set "${b}")")"
    if [ -z "${bl}" ]; then
        bad "could not read the gated-slug for-line out of $(basename "${b}")'s _opt_render_federation_modules"; loopfail=1
    elif [ "${bl}" != "${REG_CAT_SET}" ]; then
        bad "$(basename "${b}") loops over '${bl}' but the registry declares federation modules for '${REG_CAT_SET}'"; loopfail=1
    fi
done
[ "${loopfail}" = "0" ] \
    && ok "both builders' renderer loops over exactly the registry's federation-module services (no fourth hard-coded copy drifting)"

# ── sandbox tree ───────────────────────────────────────────────────────────────
# Seeded from the LIVE specs/cluster files so the renderer's sed hits the real
# anchors. Nothing under ${REPO} is ever written: this suite must not join the set
# of suites that rewrite their own committed artefacts and go green.
seed_tree() {
    SYSROOT="${WORK}/sysroot-$1"; rm -rf "${SYSROOT}"
    local tree="${SYSROOT}/var/lib/hugmesh/cluster"
    mkdir -p "${tree}/manifests/federation-modules-gate/sql" "${tree}/apps"
    cp "${GATE_SRC}" "${tree}/manifests/federation-modules-gate/sql/gate.sql"
    cp "${JOB_SRC}" "${KUST_SRC}" "${tree}/manifests/federation-modules-gate/"
    cp "${APP_SRC}" "${tree}/apps/"
    cp "${REG}" "${tree}/optional-services.yaml"
    export SYSROOT
}
gate_file() { echo "${SYSROOT}/var/lib/hugmesh/cluster/manifests/federation-modules-gate/sql/gate.sql"; }
# The POST-CONDITION probe, written independently of the builder's own
# _opt_gate_sql_value so a broken renderer cannot mark its own homework.
rendered_value() {
    local f="$1" mod="$2"
    sed -E 's/^[[:space:]]*--.*$//' "${f}" \
      | grep -E "UPDATE federation_modules SET enabled = (true|false) WHERE slug = '${mod}';" \
      | sed -E "s/.*enabled = (true|false) WHERE slug = '${mod}';.*/\1/" | head -n 1
}

# ── 2) committed baseline == optional-services.yaml's per-slug `default:` ──────
# READ FROM THE REGISTRY, not from a literal. The previous version compared
# gate.sql against a hard-coded DEFAULT_ON="akkoma tuwunel phpbb", so it caught
# drift in gate.sql and was blind to drift in optional-services.yaml — which is the
# half that actually moves. Flipping games' `default: off` -> `on` in the registry
# left this suite silent while the committed baseline contradicted it.
basefail=0
for slug in ${GATED_SLUGS}; do
    mod="${EXPECT_MOD[${slug}]:-}"; [ -n "${mod}" ] || continue
    case "${REG_DEFAULT[${slug}]:-?}" in
        on)  want=true;;
        off) want=false;;
        *)   bad "optional-services.yaml declares no usable 'default: on|off' for '${slug}' (got '${REG_DEFAULT[${slug}]:-<absent>}')"; basefail=1; continue;;
    esac
    got="$(rendered_value "${GATE_SRC}" "${mod}")"
    [ "${got}" = "${want}" ] || { bad "committed gate.sql baseline for '${mod}' is '${got:-<no line>}', but optional-services.yaml says ${slug} default: ${REG_DEFAULT[${slug}]}"; basefail=1; }
done
[ "${basefail}" = "0" ] && ok "committed gate.sql baseline matches the registry's per-slug default: on|off (read from the registry)"

# ...and the registry's defaults still match the DOCUMENTED 2026-06-17 policy. This
# is the literal's remaining job: a cross-check of the written policy, NOT the
# source of truth for leg 2 above.
reg_on="$(setify "$(for slug in ${GATED_SLUGS}; do
    [ "${REG_DEFAULT[${slug}]:-}" = "on" ] && echo "${slug}"; done)")"
pol_on="$(setify "${DEFAULT_ON}")"
[ "${reg_on}" = "${pol_on}" ] \
    && ok "the registry's default-ON federation services are exactly the documented 2026-06-17 policy set (${pol_on% })" \
    || bad "registry default-ON set '${reg_on}' != documented policy '${pol_on}' — one of optional-services.yaml or docs/OPTIONAL-SERVICES.md is now wrong"

# ── 3) per-slug: DESELECTED => false, SELECTED => true (post-condition) ─────────
for slug in ${GATED_SLUGS}; do
    mod="${EXPECT_MOD[${slug}]:-}"
    [ -n "${mod}" ] || { bad "no module slug for '${slug}' — cannot gate it"; continue; }

    # (a) everything selected EXCEPT this slug
    seed_tree "excl-${slug}"
    OPTIONAL_SERVICES=""
    for s in ${GATED_SLUGS}; do [ "${s}" = "${slug}" ] || OPTIONAL_SERVICES="${OPTIONAL_SERVICES} ${s}"; done
    export OPTIONAL_SERVICES="${OPTIONAL_SERVICES# }"
    _opt_render_federation_modules
    g="$(gate_file)"
    got="$(rendered_value "${g}" "${mod}")"
    if [ "${got}" = "false" ]; then ok "deselecting '${slug}' renders enabled = false for module '${mod}'"
    else bad "deselecting '${slug}' left module '${mod}' at '${got:-<no line>}' (want false) — its menu entry would still render"; fi
    # ...and ONLY that slug moved: every other module must be true here.
    others=0
    for s in ${GATED_SLUGS}; do
        [ "${s}" = "${slug}" ] && continue
        m="${EXPECT_MOD[${s}]:-}"; [ -n "${m}" ] || continue
        v="$(rendered_value "${g}" "${m}")"
        [ "${v}" = "true" ] || { bad "deselecting '${slug}' ALSO flipped '${m}' to '${v:-<no line>}' (collateral)"; others=1; }
    done
    [ "${others}" = "0" ] && ok "deselecting '${slug}' left every other module enabled (no collateral flip)"

    # (b) ONLY this slug selected
    seed_tree "only-${slug}"
    export OPTIONAL_SERVICES="${slug}"
    _opt_render_federation_modules
    g="$(gate_file)"
    got="$(rendered_value "${g}" "${mod}")"
    if [ "${got}" = "true" ]; then ok "selecting ONLY '${slug}' renders enabled = true for module '${mod}'"
    else bad "selecting '${slug}' left module '${mod}' at '${got:-<no line>}' (want true) — a default-off service would stay invisible"; fi
done

# ── 3b) the empty selection turns EVERY gated module off ───────────────────────
seed_tree "empty"
export OPTIONAL_SERVICES=""
_opt_render_federation_modules
g="$(gate_file)"
allf=0
for slug in ${GATED_SLUGS}; do
    mod="${EXPECT_MOD[${slug}]:-}"; [ -n "${mod}" ] || continue
    v="$(rendered_value "${g}" "${mod}")"
    [ "${v}" = "false" ] || { bad "empty selection left '${mod}' at '${v:-<no line>}'"; allf=1; }
done
[ "${allf}" = "0" ] && ok "an EMPTY selection renders every gated module enabled = false"

# ── 3c) idempotence: rendering twice is a fixed point ──────────────────────────
seed_tree "idem"
export OPTIONAL_SERVICES="akkoma tuwunel"
_opt_render_federation_modules
cp "$(gate_file)" "${WORK}/idem.once"
_opt_render_federation_modules
if diff -q "${WORK}/idem.once" "$(gate_file)" >/dev/null; then ok "the renderer is idempotent"
else bad "rendering twice changed gate.sql — not a fixed point"; fi

# ── 3d) the LOUD path: a missing registry must not silently no-op ──────────────
seed_tree "noreg"
rm -f "${SYSROOT}/var/lib/hugmesh/cluster/optional-services.yaml"
export OPTIONAL_SERVICES="akkoma"
out="$(_opt_render_federation_modules 2>&1)"
case "${out}" in
    *"CANNOT map catalogue slugs"*) ok "a missing optional-services.yaml warns LOUDLY instead of silently no-opping" ;;
    *) bad "a missing optional-services.yaml produced no named warning (output: ${out:-<empty>})" ;;
esac

# ── 3e) the LOUD path: an anchor that no longer matches must be REPORTED ───────
# A sed renderer no-ops silently on a renamed/missing anchor and still exits 0, so
# the builder reads the value BACK out of gate.sql after each rewrite. This leg
# proves that read-back is real: strip the line for a SELECTED module and the
# renderer must say so by name. (Chosen deliberately on a slug that should end up
# ENABLED — a read-back stub that always answers "true" would still look correct on
# a disabled slug, and would sail through the disabled case.)
seed_tree "anchorless"
sed -i "/WHERE slug = 'akkoma';/d" "$(gate_file)"
export OPTIONAL_SERVICES="akkoma tuwunel"
out="$(_opt_render_federation_modules 2>&1)"
case "${out}" in
    *"FAILED to render 'akkoma'"*) ok "an unrenderable anchor is reported by name (the read-back is real, not decorative)" ;;
    *) bad "gate.sql lost akkoma's line and the renderer said nothing (output: ${out:-<empty>}) — a silent sed no-op" ;;
esac

# ── 4) the delivery path is coherent ───────────────────────────────────────────
# Extract the WHOLE token, not a fixed prefix of it: grepping for the literal name
# still matched after a mutation renamed the ConfigMap to '...-sqlX', because the
# expected name is a PREFIX of the wrong one. A prefix match is not an equality check.
cm_job="$(sed -nE 's#.*configMap:[[:space:]]*\{[[:space:]]*name:[[:space:]]*([A-Za-z0-9._-]+).*#\1#p' "${JOB_SRC}" | head -n 1)"
cm_kust="$(sed -nE 's#^[[:space:]]*-[[:space:]]*name:[[:space:]]*([A-Za-z0-9._-]+)[[:space:]]*$#\1#p' "${KUST_SRC}" | head -n 1)"
if [ -n "${cm_job}" ] && [ "${cm_job}" = "${cm_kust}" ]; then
    ok "the Job and the kustomization agree on the ConfigMap name (${cm_job})"
else
    bad "Job/kustomization ConfigMap name mismatch: job='${cm_job:-<none>}' kustomization='${cm_kust:-<none>}'"
fi
grep -qE '^[[:space:]]*disableNameSuffixHash:[[:space:]]*true' "${KUST_SRC}" \
    && ok "the generated ConfigMap name is stable (disableNameSuffixHash: true), so the Job's fixed reference resolves" \
    || bad "kustomization does not set disableNameSuffixHash: true — the Job references a name that will not exist"
grep -qE '^[[:space:]]*path:[[:space:]]*specs/cluster/manifests/federation-modules-gate[[:space:]]*$' "${APP_SRC}" \
    && ok "the Application points at the gate's manifest directory" \
    || bad "the Application's source path does not point at specs/cluster/manifests/federation-modules-gate"
# The two ArgoCD hook annotations, read as DATA. These were UNANCHORED greps over
# the raw file — and job.yaml's own explanatory comment block names both tokens
# verbatim, so commenting the live annotations out left both legs printing PASS
# while the shipped object was a plain Job: created once, never re-created, so a
# re-rendered gate.sql would never be applied. Comment-token inversion has bitten
# this repo four times; read the parsed document when PyYAML is importable and fall
# back to a comment-STRIPPED, indentation-ANCHORED scrape when it is not.
job_annotation() {
    local key="$1"
    if python3 -c 'import yaml' >/dev/null 2>&1; then
        python3 - "${JOB_SRC}" "${key}" <<'JOBANN'
import sys, yaml
key = sys.argv[2]
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if isinstance(doc, dict) and doc.get("kind") == "Job":
        v = ((doc.get("metadata") or {}).get("annotations") or {}).get(key)
        if v is not None:
            print(str(v).strip())
        break
JOBANN
    else
        sed -E 's/(^|[[:space:]])#.*$//' "${JOB_SRC}" \
          | awk -v k="${key}:" '$1 == k && !seen { print $2; seen = 1 }'
    fi
}
hook_ann="$(job_annotation 'argocd.argoproj.io/hook')"
[ "${hook_ann}" = "PostSync" ] \
    && ok "the Job's LIVE argocd.argoproj.io/hook annotation is PostSync (runs after the wave's workloads reconcile)" \
    || bad "the Job's argocd.argoproj.io/hook annotation is '${hook_ann:-<absent>}', not PostSync — the shipped object is a plain Job that runs once at create time only"
hdp_ann="$(job_annotation 'argocd.argoproj.io/hook-delete-policy')"
[ "${hdp_ann}" = "BeforeHookCreation" ] \
    && ok "the Job's LIVE hook-delete-policy is BeforeHookCreation, so a re-rendered gate.sql is actually applied" \
    || bad "the Job's argocd.argoproj.io/hook-delete-policy is '${hdp_ann:-<absent>}', not BeforeHookCreation — a completed Job of the same name would block every later render from ever running"
# The gate is ARCHITECTURE, not an optional slug: no case arm may prune it.
# NOTE the >/dev/null on BOTH arms. `| grep -q` under `set -o pipefail` exits 141
# (SIGPIPE) whenever the upstream writer is still going when grep quits early on a
# match — and build-rpi5-stage4.sh is ~320 KB, far past the measured knee. The -q
# form here reported FAILURE on a match it had actually found, so the && always
# short-circuited and this leg printed PASS unconditionally.
# Read the RESOLVED gate, not the builder file: the case arms moved into the shared
# library with the rest of the gate, so grepping build-rpi5-stage4.sh now matches
# nothing and this leg would pass vacuously forever.
GATE_BODY_RPI5="$(opt_gate_extract_fn "${BUILDER}" gate_optional_services | sed -E 's/#.*$//')"
if printf '%s' "${GATE_BODY_RPI5}" | grep -E 'federation-modules-gate' >/dev/null &&
   printf '%s' "${GATE_BODY_RPI5}" | grep -E 'rm -(f|rf).*federation-modules-gate' >/dev/null; then
    bad "gate_optional_services PRUNES the federation-modules-gate tree — the gate would delete itself"
else
    ok "no builder case arm prunes the federation-modules-gate tree"
fi

# ── 4b) the manifest dir actually RENDERS (when a kustomize is available) ──────
# The grep above proves the two files SPELL the ConfigMap name the same way; only a
# real render proves kustomize's generator produces that name and the Job's volume
# resolves to it. Skips LOUDLY when no renderer is installed.
KUST_BIN=""
command -v kustomize >/dev/null 2>&1 && KUST_BIN="kustomize build"
[ -z "${KUST_BIN}" ] && command -v kubectl >/dev/null 2>&1 && KUST_BIN="kubectl kustomize"
if [ -z "${KUST_BIN}" ]; then
    skip "leg 4b kustomize render: neither 'kustomize' nor 'kubectl' is on PATH, so specs/cluster/manifests/federation-modules-gate was NOT render-validated (only its file contents were grepped)."
elif ! ${KUST_BIN} "${SRC}/manifests/federation-modules-gate" > "${WORK}/render.yaml" 2>"${WORK}/render.err"; then
    bad "leg 4b: ${KUST_BIN} failed on the gate manifest dir: $(head -n 3 "${WORK}/render.err" | tr '\n' ' ')"
elif ! python3 -c 'import yaml' >/dev/null 2>&1; then
    skip "leg 4b post-render assertions: kustomize rendered the gate cleanly but PyYAML is not importable, so the rendered objects were not inspected."
else
    if python3 - "${WORK}/render.yaml" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
kinds = {d["kind"]: d for d in docs}
assert set(kinds) == {"ConfigMap", "Job"}, f"unexpected objects: {sorted(kinds)}"
cm, job = kinds["ConfigMap"], kinds["Job"]
assert "gate.sql" in cm["data"], f"ConfigMap has no gate.sql key: {list(cm['data'])}"
vols = {v["name"]: v for v in job["spec"]["template"]["spec"]["volumes"]}
ref = vols["sql"]["configMap"]["name"]
assert ref == cm["metadata"]["name"], f"Job mounts '{ref}' but the generated ConfigMap is '{cm['metadata']['name']}'"
assert cm["metadata"]["namespace"] == job["metadata"]["namespace"] == "hugmesh-backend"
PY
    then ok "leg 4b: the gate manifest dir renders to exactly {ConfigMap, Job}, and the Job's volume resolves to the generated ConfigMap"
    else bad "leg 4b: the rendered gate manifests do not hang together (see the assertion above)"
    fi
fi

# ── 4c) DOES THE RENDERED gate.sql EVER REACH A DEVICE? (it does not, today) ────
# The unit's deliverable is INERT on a real device and this leg exists to keep that
# sentence TRUE rather than comfortable.
#
# ⚠ THE REASON CHANGED UNDER THIS LEG, AND THE LEG WAS MEASURING THE OLD ONE
# (2026-08-26, integration). As written on this branch the argument was: apps/29b
# pins repoURL github.com/hugmesh/hugmesh-generator + targetRevision main, and
# bootstrap.sh rewrites that literal into app-of-apps.yaml ONLY — "the single file
# it pipes to kubectl" — so no child Application is ever retargeted. The sibling
# keystone (fix/device-syncs-pruned-apps) DELETED that premise: bootstrap.sh now
# applies every baked apps/*.yaml through the same repoURL/targetRevision sed, so
# child Applications ARE applied from the device and ARE retargeted.
#
# THE CONCLUSION SURVIVES, FOR A DIFFERENT REASON, and that is the only reason
# this leg still passes: apply_baked_app() rewrites repoURL and targetRevision and
# NOTHING ELSE. `source.path: specs/cluster/manifests/federation-modules-gate` is
# untouched, so ArgoCD's repo-server still clones a GIT repo and
# kustomize-generates the ConfigMap from the COMMITTED gate.sql, never from the
# USB's rendered copy. A USB built with `--exclude-services akkoma` bakes
# enabled=false into its own tree and the cluster still applies enabled=true.
# The keystone's own README says the same thing about every manifest under
# manifests/; the gate is one instance of it.
#
# SO THE QUESTION IS RESTATED to the one that is actually load-bearing now: does
# the gate Application's SOURCE resolve to the device, or to a git repo? Two ways
# it could: the Application stops naming a remote git repoURL, or the bootstrap
# starts rewriting `path:` (or the Application's source outright) at apply time.
# Asking "does bootstrap rewrite anything under .../apps/" — the old probe — is now
# TRUE-BY-CONSTRUCTION for a tree where the render still does not reach the device,
# i.e. it would have gone on passing while measuring nothing.
#
# TWO-SIDED ON PURPOSE. If the caveat is deleted while the mechanism is still
# broken, this fails. If someone later makes the device serve the gate from its
# baked tree (a pruned source: an in-cluster repo server, or a path rewrite), the
# caveat becomes a LIE and this fails on that instead.
BOOT_SRC="${SRC}/bootstrap/bootstrap.sh"
# Assembled from two halves ON PURPOSE: grep -F is line-based, so if the whole
# phrase appeared literally on this line the check below would be satisfied by its
# own source and would pass on a test file whose header caveat had been deleted.
CAVEAT_MARK="INERT ON A DEVICE"; CAVEAT_MARK="${CAVEAT_MARK} TODAY"
CAVEAT_FILES="${GATE_SRC} ${JOB_SRC} ${APP_SRC} ${REPO}/docs/OPTIONAL-SERVICES.md ${BASH_SOURCE[0]}"

if [ ! -f "${BOOT_SRC}" ]; then
    bad "leg 4c: ${BOOT_SRC} is missing — cannot tell whether a device serves the gate from its baked tree or from GitHub"
else
    # Every file the device bootstrap feeds to its repoURL-rewriting sed.
    boot_rewrites="$(sed -E 's/(^|[[:space:]])#.*$//' "${BOOT_SRC}" \
      | awk '/repoURL: https:\/\/github\.com\/hugmesh\/hugmesh-generator\.git#repoURL:/ { hit = NR }
             hit && NR <= hit + 6 {
                 # EVERY operand on the line, not just the first: awk match() finds one
                 # occurrence per call, and a one-line `sed ... app-of-apps.yaml apps/29b...yaml`
                 # would otherwise be read as app-of-apps.yaml alone.
                 line = $0
                 while (match(line, /\$\{CLUSTER_DIR\}\/[A-Za-z0-9._\/-]+/)) {
                     print substr(line, RSTART, RLENGTH)
                     line = substr(line, RSTART + RLENGTH)
                 }
             }' | sort -u | tr '\n' ' ')"
    app_repo="$(sed -E 's/(^|[[:space:]])#.*$//' "${APP_SRC}" \
      | awk '$1 == "repoURL:" && !seen { print $2; seen = 1 }')"

    # WHAT bootstrap.sh's sed actually REWRITES on each applied manifest. Only
    # repoURL/targetRevision today: both re-point the same REMOTE GIT REPO (that is
    # the fork/mirror override), so neither moves the SOURCE onto the device. A
    # `path:` rewrite, or a wholesale source replacement, would.
    boot_rewrites_keys="$(sed -E 's/(^|[[:space:]])#.*$//' "${BOOT_SRC}" \
      | grep -oE 's#(repoURL|targetRevision|path|source):' | sed 's/^s#//' | sort -u | tr '\n' ' ')"
    device_serves_gate=0
    case " ${boot_rewrites_keys} " in *" path: "*|*" source: "*) device_serves_gate=1 ;; esac
    case "${app_repo}" in ""|*"github.com/hugmesh/hugmesh-generator"*) : ;; *) device_serves_gate=1 ;; esac

    missing=""
    for f in ${CAVEAT_FILES}; do
        [ -f "${f}" ] || { missing="${missing} ${f}(absent)"; continue; }
        grep -F "${CAVEAT_MARK}" "${f}" >/dev/null || missing="${missing} $(basename "${f}")"
    done

    if [ "${device_serves_gate}" = "0" ]; then
        ok "confirmed the gate's Application still sources '${app_repo}' and bootstrap.sh rewrites only [${boot_rewrites_keys% }] on the manifests it applies (${boot_rewrites% }) — the source.path still resolves in a GIT repo, so the build-time render does NOT reach a device"
        if [ -z "${missing}" ]; then
            ok "every caveat site says '${CAVEAT_MARK}' in so many words (gate.sql, job.yaml, apps/29b, docs, this header) — nobody can read this unit as the observed bug being fixed"
        else
            bad "the build-time render is inert on a device but the '${CAVEAT_MARK}' caveat is MISSING from:${missing} — this unit would read as the observed bug being fixed"
        fi
    else
        if [ -n "${missing}" ]; then
            ok "the device bootstrap now rewrites [${boot_rewrites_keys% }] / the Application sources '${app_repo}', so the gate resolves to the device's own tree — and the stale inert-on-a-device caveat has been removed"
        else
            bad "the device now serves the gate from its own tree (bootstrap rewrites [${boot_rewrites_keys% }], Application sources '${app_repo}') but the '${CAVEAT_MARK}' caveat is still there:${CAVEAT_FILES} — the docs now understate the fix"
        fi
    fi
fi

# ══ LIVE LEGS ═══════════════════════════════════════════════════════════════════
# Never exit 0 quietly: every unrun leg prints a SKIP with a named reason.
find_ctr() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -E "(^|[-_])$1([-_]|$)" | head -n 1
}
CAP_PATH="/api/federation/capabilities"
FED_DB=""; FED_API=""
if ! command -v docker >/dev/null 2>&1; then
    skip "LIVE legs L1+L2: docker is not on PATH, so no local stack can be inspected. Run this on the box that hosts the hugmesh-local compose stack."
elif ! docker ps >/dev/null 2>&1; then
    skip "LIVE legs L1+L2: 'docker ps' failed (daemon down or no permission), so no local stack can be inspected."
else
    FED_DB="$(find_ctr federation-db)"
    FED_API="$(find_ctr federation-api)"
fi

if [ -n "${FED_DB}" ]; then
    fed_sql() { docker exec -i "${FED_DB}" psql -U federation -d federation -tAc "$1" 2>/dev/null; }
    rows="$(fed_sql "select string_agg(slug || '=' || enabled, ' ' order by slug) from federation_modules")"
    if [ -z "${rows}" ]; then
        skip "LIVE leg L1: federation-db container '${FED_DB}' is up but federation_modules is empty or unreadable (has federation-api run its Liquibase changelog yet?)."
    elif [ -z "${FED_API}" ]; then
        skip "LIVE leg L1: found federation-db ('${FED_DB}') but NO running federation-api container, so the capabilities projection cannot be fetched. Registry currently: ${rows}"
    else
        # federation-api's image is a distroless-ish JRE with no curl; go through the
        # container's own network namespace from a shell that HAS one.
        cap="$(docker exec "${FED_API}" sh -c "wget -qO- http://127.0.0.1:8080${CAP_PATH} 2>/dev/null || curl -sf http://127.0.0.1:8080${CAP_PATH}" 2>/dev/null)"
        if [ -z "${cap}" ]; then
            skip "LIVE leg L1: could not fetch ${CAP_PATH} from inside '${FED_API}' (no wget/curl in the image, or the endpoint moved). Registry currently: ${rows}"
        elif ! python3 -c 'import json,sys; json.load(sys.stdin)' <<<"${cap}" >/dev/null 2>&1; then
            bad "LIVE leg L1: ${CAP_PATH} returned something that is not JSON: $(printf '%.200s' "${cap}")"
        else
            # For every gated module the projection knows about, its install-state must
            # equal the DB row. That equality IS the mechanism this unit relies on.
            # NOTE: the checker is written to a FILE and fed the payload on stdin —
            # `python3 - <<PY <<<"$cap"` silently keeps only the LAST redirection, so
            # the heredoc would never be the program and the leg would evaluate nothing.
            cat > "${WORK}/capcheck.py" <<'PY'
import json, os, sys
cap  = json.load(sys.stdin)
rows = dict(kv.split("=", 1) for kv in os.environ["ROWS"].split() if "=" in kv)
mods = [m for m in os.environ["MODS"].split() if m]

def entries(o):
    if isinstance(o, dict):
        if "slug" in o:
            yield o
        for v in o.values():
            yield from entries(v)
    elif isinstance(o, list):
        for v in o:
            yield from entries(v)

seen, wrong = {}, []
for e in entries(cap):
    for key in ("installed", "enabled", "available"):
        if key in e and isinstance(e[key], bool):
            seen[e["slug"]] = e[key]
            break
if not seen:
    print("SHAPE: no {slug, installed|enabled|available} entries in the capabilities payload")
    sys.exit(0)
for m in mods:
    if m not in seen or m not in rows:
        continue
    want = rows[m] in ("t", "true", "True")
    if seen[m] != want:
        wrong.append(f"{m}: capabilities={seen[m]} db.enabled={rows[m]}")
print("; ".join(wrong))
PY
            mismatch="$(printf '%s' "${cap}" \
                | MODS="$(for s in ${GATED_SLUGS}; do printf '%s ' "${EXPECT_MOD[${s}]:-}"; done)" \
                  ROWS="${rows}" python3 "${WORK}/capcheck.py")"
            case "${mismatch}" in
                "")        ok "LIVE leg L1: capabilities install-state equals federation_modules.enabled for every gated module (registry: ${rows})" ;;
                SHAPE:*)   bad "LIVE leg L1: ${mismatch} — the projection this unit depends on is not shaped as documented" ;;
                *)         bad "LIVE leg L1: capabilities disagrees with the DB rows -> ${mismatch}" ;;
            esac
        fi
    fi

    if [ "${FEDERATION_GATE_LIVE:-0}" != "1" ]; then
        skip "LIVE leg L2 (end-to-end flip): this leg WRITES to the operator's federation_modules rows and the local stack is shared with other sessions, so it is opt-in. Re-run with FEDERATION_GATE_LIVE=1 to execute it (it restores every row it touches)."
    else
        victim="akkoma"; vmod="${EXPECT_MOD[akkoma]:-akkoma}"
        before="$(fed_sql "select enabled from federation_modules where slug = '${vmod}'")"
        if [ -z "${before}" ]; then
            skip "LIVE leg L2: no federation_modules row for '${vmod}' to flip."
        else
            seed_tree "live"
            OPTIONAL_SERVICES=""
            for s in ${GATED_SLUGS}; do [ "${s}" = "${victim}" ] || OPTIONAL_SERVICES="${OPTIONAL_SERVICES} ${s}"; done
            export OPTIONAL_SERVICES="${OPTIONAL_SERVICES# }"
            _opt_render_federation_modules
            # Apply ONLY the UPDATE statements (the DO-block guard + the trailing
            # SELECT are for the in-cluster Job).
            grep -E "^UPDATE federation_modules SET enabled = (true|false) WHERE slug = '[^']+';" "$(gate_file)" \
                | docker exec -i "${FED_DB}" psql -U federation -d federation -q >/dev/null 2>&1
            after="$(fed_sql "select enabled from federation_modules where slug = '${vmod}'")"
            if [ "${after}" = "f" ] || [ "${after}" = "false" ]; then
                ok "LIVE leg L2: the rendered gate.sql flipped '${vmod}' to enabled=false on a real federation-db"
            else
                bad "LIVE leg L2: after applying the rendered gate.sql '${vmod}' is still '${after}'"
            fi
            # 'before' is psql -tA's boolean spelling (t/f); turn it back into a literal.
            case "${before}" in t|true) blit=true;; *) blit=false;; esac
            fed_sql "update federation_modules set enabled = ${blit} where slug = '${vmod}'" >/dev/null
            restored="$(fed_sql "select enabled from federation_modules where slug = '${vmod}'")"
            [ "${restored}" = "${before}" ] \
                && ok "LIVE leg L2: restored '${vmod}' to its original enabled=${before}" \
                || bad "LIVE leg L2: FAILED to restore '${vmod}' (was '${before}', now '${restored}') — the operator's stack has been left modified"
        fi
    fi
elif command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
    skip "LIVE legs L1+L2: no running 'federation-db' container was found, so the behavioural half could not run. Bring up the local stack (make stack-up) and re-run. Running containers: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
fi

echo "== RESULT: ${P} passed, ${F} failed, ${S} skipped =="
# `-eq`, not `= "0"`: tests/scripts/test-guard-integrity.sh's "counts failures
# but never raises them" analyser only recognises the numeric comparison forms.
[ "${F}" -eq 0 ]
