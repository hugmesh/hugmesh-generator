#!/usr/bin/env bash
# test-optional-services-parity.sh — BEHAVIOURAL parity of the optional-service
# gate across build-rpi5-stage4.sh and build-x86-host-stage4.sh.
#
# WHY THIS SUITE EXISTS (2026-08-26)
# ----------------------------------
# Three defects shipped in x86 images while every existing guard was green:
#
#   D1  build-x86-host-stage4.sh had NO _opt_render_appset_flag at all, while its
#       own comments claimed it did ("renders it installed:\"false\" in BOTH the
#       ConfigMap and the 13a ApplicationSet"; --exclude-services help text:
#       "ConfigMap + 13a ApplicationSet flag renders \"false\""). Observed: a
#       deselected slug got installed:"false" in
#       manifests/policy/installed-services-configmap.yaml but stayed
#       installed:"true" in apps/13a-optional-services.yaml. The 13a generator's
#       selector keeps installed=="true" elements, so a repo-synced ArgoCD
#       RE-FORCED the deselected service back on.
#
#   D2  build-x86-host-stage4.sh had NO anubis handling whatsoever — no
#       _opt_explicitly_deselected, no _opt_anubis_installed, no
#       _opt_wire_anubis_ingress. Observed: an x86 `--env prod` image shipped the
#       PUBLIC proof-of-work shield OFF and the fe-gateway public Ingress backend
#       un-rerouted (straight to fe-gateway, no PoW gate in path).
#
#   D3  build-x86-host-stage4.sh ran the edge-ai-analysis dependsOn-edge-ai guard
#       at TOP LEVEL, BEFORE the EXCLUDE_SERVICES subtraction. Observed:
#       `--optional-services "edge-ai edge-ai-analysis" --exclude-services edge-ai`
#       shipped the analysis wrapper with no model server behind it.
#
# WHY THE OLD GUARDS MISSED ALL THREE, AND WHAT THIS SUITE DOES DIFFERENTLY
# ------------------------------------------------------------------------
# tests/stack/test-optional-services-exclude.sh §4c grepped the x86 file for the
# selection KNOBS and diffed one case body. None of D1/D2/D3 lives in a knob or in
# that case. The obvious "fix" — grep the x86 file for the FUNCTION NAMES — is
# barely better and would NOT have caught them either:
#
#     * a function name is satisfied by a COMMENT that mentions it (prose naming a
#       token has inverted exactly this kind of check four times in this repo), and
#     * a name grep says nothing about the BODY: a present-but-wrong
#       _opt_render_appset_flag passes it, and D1 was in fact a wrong OUTCOME, not
#       a missing string.
#
# So every assertion below is a POST-CONDITION ON A RENDERED ARTEFACT. Each case
# seeds a fixture tree from the checked-in specs/cluster files, runs the REAL
# selection resolution and the REAL gate out of the builder under test, and then
# greps the rendered YAML. The mutation demonstration recorded in the commit
# message shows the name-grep form of this same suite going GREEN against a
# reverted production fix that the post-condition form catches.
#
# HOW "THE REAL GATE OUT OF THE BUILDER UNDER TEST" IS RESOLVED
# ------------------------------------------------------------
# tests/lib/opt-gate-source.sh walks the builder's own `source` chain and takes
# the LAST definition of each function, exactly as bash would. Today both builders
# resolve to scripts/_optional-services-lib.sh. If someone re-adds a local copy to
# one builder, that copy is what bash would run and therefore what this suite
# executes — so these assertions keep their teeth after the shared library lands,
# which a "do both files contain the name" check would not.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${REPO}/specs/cluster"
BUILDERS="${REPO}/build-rpi5-stage4.sh ${REPO}/build-x86-host-stage4.sh"

P=0; F=0
ok(){  echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# NO SILENT SKIPS: a missing tool is a FAILURE naming what is missing. (DAST sat
# inert for weeks in this repo behind exactly this kind of quiet exit 0.)
for _t in awk sed grep diff; do
  command -v "${_t}" >/dev/null || { echo "  FAIL required tool '${_t}' is missing — refusing to report a vacuous pass"; exit 1; }
done
for _b in ${BUILDERS}; do
  [ -f "${_b}" ] || { echo "  FAIL builder missing: ${_b}"; exit 1; }
done
# shellcheck source=tests/lib/opt-gate-source.sh
source "${REPO}/tests/lib/opt-gate-source.sh"

echo "== optional-service gate: CROSS-BUILDER BEHAVIOURAL parity =="

# ── fixture tree ─────────────────────────────────────────────────────────────
# Seeded from the live specs/cluster files so the gate's rm -f / sed / awk hit the
# real filenames and the real YAML shapes. Never writes back into specs/.
seed_tree() {  # $1 = destination SYSROOT
    local root="$1"; rm -rf "${root}"
    local tree="${root}/var/lib/hugmesh/cluster"
    mkdir -p "${tree}/apps" "${tree}/manifests/external-secrets" \
             "${tree}/manifests/route-access/initdb" "${tree}/manifests/policy" \
             "${tree}/manifests/networkpolicy" "${tree}/manifests/optional-services-operator"
    cp "${SRC}/apps/13a-optional-services.yaml"                            "${tree}/apps/"
    cp "${SRC}/apps/20-gateway-be.yaml" "${SRC}/apps/20-gateway-fe.yaml"   "${tree}/apps/"
    cp "${SRC}/manifests/policy/installed-services-configmap.yaml"         "${tree}/manifests/policy/"
    cp "${SRC}/manifests/route-access/initdb/20-schema.sql"                "${tree}/manifests/route-access/initdb/"
    cp "${SRC}/manifests/external-secrets/kustomization.yaml"              "${tree}/manifests/external-secrets/"
    cp "${SRC}/manifests/optional-services-operator/seed-optionalservices.yaml" \
       "${tree}/manifests/optional-services-operator/"
    local a m
    for a in 30-akkoma 30-tuwunel 30-phpbb 38-forum-bff-db 39-forum-bff-api 49-forum-ui \
             45-social-ui 06-casdoor-games 50-games 13c-games-instances 52-owncast 53-tube \
             49b-character-studio-ui 38b-character-forge-bff-db 39b-character-forge-bff-api \
             49c-character-forge-ui 54-edge-ai 55-edge-ai-analysis 55b-edge-ai-tts 13e-egress-vpn; do
        [ -f "${SRC}/apps/${a}.yaml" ] && cp "${SRC}/apps/${a}.yaml" "${tree}/apps/"
    done
    for m in akkoma tuwunel forum games casdoor-games games-instances owncast tube \
             character-studio character-forge character-forge-bff-api character-forge-bff-db \
             edge-ai edge-ai-analysis edge-ai-tts egress-vpn; do
        [ -d "${SRC}/manifests/${m}" ] && cp -r "${SRC}/manifests/${m}" "${tree}/manifests/"
    done
    for e in akkoma-externalsecrets tuwunel-externalsecrets tube-externalsecrets; do
        [ -f "${SRC}/manifests/external-secrets/${e}.yaml" ] && \
            cp "${SRC}/manifests/external-secrets/${e}.yaml" "${tree}/manifests/external-secrets/"
    done
    [ -f "${SRC}/manifests/networkpolicy/kustomization.yaml" ] && \
        cp -r "${SRC}/manifests/networkpolicy/." "${tree}/manifests/networkpolicy/"
    return 0
}

# ── run ONE builder's REAL selection resolution + REAL gate against a tree ────
# Everything that decides the outcome comes out of the builder under test:
#   * its own USER_LEVEL_SERVICES literal;
#   * its own selection region, VERBATIM — from the comma-normalisation line
#     through the closing `fi` of the EXCLUDE_SERVICES subtraction. That region is
#     where D3 lived: the ORDER of the dependsOn guard relative to EXCLUDE is a
#     property of this text, so it must be executed, not paraphrased;
#   * its own resolution of gate_optional_services + every _opt_* helper.
# Runs in a SUBSHELL so two builders' resolutions can never contaminate each other.
run_builder() {  # $1=builder $2=OPTIONAL_SERVICES $3=EXCLUDE_SERVICES $4=ENV $5=SYSROOT [$6=extra shell assignments]
    local builder="$1" opt="$2" excl="$3" env="$4" root="$5" extra="${6:-}"
    local region; region="$(_selection_region "${builder}")"
    if [ -z "${region}" ]; then
        echo "    ERR could not extract the selection region from $(basename "${builder}")" >&2
        return 2
    fi
    (
        set -uo pipefail
        info(){ :; }; warn(){ :; }; err(){ :; }
        # The builder's OWN user-level set literal (not a copy kept here).
        eval "$(grep -E '^USER_LEVEL_SERVICES=' "${builder}")"
        # Stubs for the opt-in fold flags the region reads. All default-off, so the
        # region's behaviour is driven purely by OPTIONAL_SERVICES/EXCLUDE_SERVICES —
        # which is what parity is being asserted about. ROLE_CLIENT is invoked as a
        # COMMAND (`${ROLE_CLIENT} && ...`), hence `false`, i.e. a cluster node.
        ROLE_CLIENT=false
        ENABLE_GAMES=false
        WANT_CHARACTER_STUDIO=false; WANT_CHARACTER_FORGE=false
        WANT_EDGE_AI=false; WANT_EDGE_AI_ANALYSIS=false; WANT_EDGE_AI_TTS=false
        WANT_TOR=false; EDGE_AI=false; EDGE_AI_WANT=false
        # THE THREE --edge-ai-* KNOBS ARE **NOT** INVENTED HERE. This harness used to
        # pre-seed EDGE_AI_RUNTIME/EDGE_AI_MODELS/EDGE_AI_MODEL_DEFAULT="" for BOTH
        # legs. build-x86-host-stage4.sh really does define all three (its CLI
        # exposes --edge-ai-runtime/--edge-ai-models/--edge-ai-model-default);
        # build-rpi5-stage4.sh defines NONE of them and runs under `set -euo
        # pipefail`. So pre-seeding them made the `${VAR:-}` guard in the shared
        # lib's edge-ai models-ConfigMap block untestable: MEASURED (2026-08-26,
        # adversarial review) reverting those three reads to bare ${VAR} left all
        # seven suites green while a real rpi5 build aborted with
        #   _optional-services-lib.sh: line 348: EDGE_AI_RUNTIME: unbound variable
        # That is exactly the harness-invents-the-variable pattern that hid the
        # adminbff_app GRANT role for weeks.
        #
        # Instead: take each builder's OWN definitions, comment-stripped (prose
        # naming a token has inverted checks in this repo four times), and NOTHING
        # for a builder that has none — so the rpi5 leg runs the gate with all three
        # genuinely unbound, under `set -u`, where an unguarded read is fatal.
        eval "$(sed -e 's/#.*$//' "${builder}" \
                | grep -E '^EDGE_AI_(RUNTIME|MODELS|MODEL_DEFAULT)=' || :)"
        OPTIONAL_SERVICES="${opt}"; EXCLUDE_SERVICES="${excl}"
        ENV="${env}"; SYSROOT="${root}"
        # Per-case overrides (the --edge-ai-* flags a real invocation would set).
        # Applied AFTER the builder's own defaults, exactly as argv parsing does.
        [ -z "${extra}" ] || eval "${extra}"
        # DERIVED, never listed by hand. This was a hand-written list of 14 names
        # until 2026-08-26, and it rotted the first time the gate grew: two merged
        # branches added _opt_appset_cutover_done (called from
        # _opt_render_appset_flag) and _opt_render_federation_modules (called from
        # gate_optional_services), neither was in the list, and EVERY builder run
        # here died rc=127 "command not found" — 71 passed/0 failed became 9/26.
        # opt_gate_load_all derives the whole set from the builder's own resolution
        # chain, so a gate that grows a leaf cannot leave this suite running less
        # code than it claims.
        opt_gate_load_all "${builder}" || exit 3
        eval "${region}"          # the builder's REAL resolution, in its REAL order
        gate_optional_services
    )
}

# The builder's selection region, verbatim: the comma-normalisation line through
# the `fi` that closes the EXCLUDE_SERVICES subtraction. Anchored on two literal
# source lines that both builders carry; if either anchor ever moves, this returns
# empty and run_builder reports it — it does not silently test a shorter region.
_selection_region() {
    awk 'index($0, "OPTIONAL_SERVICES=\"${OPTIONAL_SERVICES//,/ }\"")==1 { p=1 }
         p { print; if (seen && $0=="fi") exit; if ($0 ~ /unset _excl_x _x _s _kept/) seen=1 }' "$1"
}

# ── post-condition probes (all read RENDERED artefacts, never source) ────────
tree_of()   { echo "$1/var/lib/hugmesh/cluster"; }
cm_of()     { echo "$(tree_of "$1")/manifests/policy/installed-services-configmap.yaml"; }
appset_of() { echo "$(tree_of "$1")/apps/13a-optional-services.yaml"; }
fe_of()     { echo "$(tree_of "$1")/apps/20-gateway-fe.yaml"; }
cr_of()     { echo "$(tree_of "$1")/manifests/optional-services-operator/seed-optionalservices.yaml"; }
models_of() { echo "$(tree_of "$1")/manifests/edge-ai/models-configmap.yaml"; }

cm_flag() {     # $1=root $2=slug -> true|false|MISSING
    local v; v="$(grep -E "^[[:space:]]*$2:[[:space:]]*\"(true|false)\"" "$(cm_of "$1")" 2>/dev/null | head -1 | grep -oE '(true|false)')"
    echo "${v:-MISSING}"
}
appset_flag() { # $1=root $2=slug -> true|false|MISSING  (the 13a generator element)
    local v; v="$(grep -oE "\{[[:space:]]*slug:[[:space:]]*$2[[:space:]]*,.*installed:[[:space:]]*\"(true|false)\"" "$(appset_of "$1")" 2>/dev/null \
                  | head -1 | grep -oE 'installed:[[:space:]]*"(true|false)"' | grep -oE '(true|false)')"
    echo "${v:-MISSING}"
}
# expected_appset_flag <root> <slug> — what installed: SHOULD read for a SELECTED
# slug, under the pre-cut-over no-double-management rule.
#
# 13a-optional-services.yaml's own header says "keep every element
# installed:false" while the legacy hardcoded apps/30-<slug>.yaml still exists,
# and docs/OPTIONAL-SERVICES.md forbids two owners of one manifest directory: the
# generated `optional-<slug>` Application and the hardcoded `<slug>` one would BOTH
# carry automated{prune,selfHeal} over specs/cluster/manifests/<dir>. That flip was
# harmless only while bootstrap.sh never applied the baked tree; now that it does,
# the flip is REACHABLE and the double management is real.
#
# DERIVED, not hardcoded — and derived INDEPENDENTLY of production's
# _opt_appset_cutover_done(), so this stays an oracle rather than a tautology: read
# the element's own `path:` out of the BAKED 13a file and ask whether any OTHER
# baked apps/*.yaml still declares it. Comments stripped first (several apps files
# name a manifests/<dir> in prose). Self-maintaining: delete apps/30-akkoma.yaml in
# a real cut-over and this starts expecting "true" with no edit here.
expected_appset_flag() { # $1=root $2=slug -> true|false
    local appset apps p f
    appset="$(appset_of "$1")"; apps="$(dirname "${appset}")"
    p="$(sed -n -E "s#^[[:space:]]*-[[:space:]]*\{[[:space:]]*slug:[[:space:]]*$2[[:space:]]*,.*[[:space:]]path:[[:space:]]*([^,[:space:]]+).*#\1#p" "${appset}" 2>/dev/null | sed -n '1p')"
    [ -n "${p}" ] || { echo true; return 0; }
    for f in "${apps}"/*.yaml; do
        [ -e "${f}" ] || continue
        case "$(basename "${f}")" in 13a-optional-services.yaml) continue ;; esac
        if sed -e 's/#.*$//' "${f}" | grep -E "^[[:space:]]*path:[[:space:]]*${p}[[:space:]]*\$" >/dev/null; then
            echo false; return 0
        fi
    done
    echo true
}
ingress_backend() { # $1=root -> anubis|direct
    grep -qE '^[[:space:]]*backendServiceName:[[:space:]]*anubis' "$(fe_of "$1")" 2>/dev/null && echo anubis || echo direct
}

bn(){ basename "$1"; }

# ═════════════════════════════════════════════════════════════════════════════
# 1) D1 — the 13a ApplicationSet install flag RENDERS on BOTH builders.
#    Post-condition: for a deselected slug the 13a element must read
#    installed:"false", not just the ConfigMap. A rendered "true" here is the
#    exact byte that let a repo-synced ArgoCD re-force the service back on.
# ═════════════════════════════════════════════════════════════════════════════
echo "-- D1: 13a ApplicationSet installed flag renders (both builders) --"
for b in ${BUILDERS}; do
    root="${WORK}/appset-$(bn "${b}")"; seed_tree "${root}"
    run_builder "${b}" "akkoma tuwunel" "" test "${root}"
    rc=$?
    [ "${rc}" -eq 0 ] || { bad "$(bn "${b}"): selection+gate did not run (rc=${rc})"; continue; }
    # Selected slug: the ConfigMap is the INSTALL signal and is unconditionally
    # true. The 13a element follows the pre-cut-over no-double-management rule —
    # see expected_appset_flag(). It reads "false" while apps/30-akkoma.yaml still
    # owns manifests/akkoma, and that is the invariant, not a relaxation.
    _want13a="$(expected_appset_flag "${root}" akkoma)"
    [ "$(cm_flag "${root}" akkoma)" = "true" ] \
        && ok "$(bn "${b}"): SELECTED akkoma renders ConfigMap installed \"true\"" \
        || bad "$(bn "${b}"): SELECTED akkoma — ConfigMap=$(cm_flag "${root}" akkoma), expected true"
    [ "$(appset_flag "${root}" akkoma)" = "${_want13a}" ] \
        && ok "$(bn "${b}"): SELECTED akkoma — 13a element \"${_want13a}\", which is what the no-double-management rule requires here" \
        || bad "$(bn "${b}"): SELECTED akkoma — 13a element is $(appset_flag "${root}" akkoma), expected \"${_want13a}\" (a hardcoded Application still owning the manifest dir must NOT be joined by the 13a-generated one)"
    # Deselected slugs: the ConfigMap alone was ALREADY right on x86 before the
    # fix, so assert the 13a element SEPARATELY — that is the byte that was wrong.
    for slug in games owncast tube; do
        [ "$(cm_flag "${root}" "${slug}")" = "false" ] \
            && ok "$(bn "${b}"): DESELECTED ${slug} — ConfigMap installed \"false\"" \
            || bad "$(bn "${b}"): DESELECTED ${slug} — ConfigMap is $(cm_flag "${root}" "${slug}"), expected false"
        [ "$(appset_flag "${root}" "${slug}")" = "false" ] \
            && ok "$(bn "${b}"): DESELECTED ${slug} — 13a ApplicationSet element installed \"false\"" \
            || bad "$(bn "${b}"): DESELECTED ${slug} — 13a element is $(appset_flag "${root}" "${slug}"), expected false (a repo-synced ArgoCD would re-force it ON)"
    done
done
# The two rendered 13a files must be byte-identical — the strongest form of the
# parity claim, and it cannot be satisfied by a comment or a function name.
_a="${WORK}/appset-build-rpi5-stage4.sh"; _x="${WORK}/appset-build-x86-host-stage4.sh"
diff -q "$(appset_of "${_a}")" "$(appset_of "${_x}")" >/dev/null 2>&1 \
    && ok "rendered 13a-optional-services.yaml is BYTE-IDENTICAL across both builders" \
    || bad "rendered 13a-optional-services.yaml DIFFERS between the builders"

# ═════════════════════════════════════════════════════════════════════════════
# 2) D2 — anubis: ENV policy + explicit deselection render the same on BOTH.
#    Three post-conditions per case: the ConfigMap flag, the OptionalService CR
#    enabled flag, and whether the PUBLIC fe-gateway Ingress backend is the anubis
#    Service. The last one is the one that actually decides whether a PoW gate is
#    in path; x86 rendered "direct" for every prod image.
# ═════════════════════════════════════════════════════════════════════════════
echo "-- D2: anubis ENV policy + explicit deselect (both builders) --"
# case = "<label>|<ENV>|<OPTIONAL_SERVICES>|<expected flag>|<expected ingress>"
ANUBIS_CASES="prod-default|prod|akkoma tuwunel phpbb|true|anubis
test-default|test|akkoma tuwunel phpbb|false|direct
prod-deselected|prod|akkoma tuwunel phpbb -anubis|false|direct
prod-deselected-no|prod|akkoma tuwunel phpbb no-anubis|false|direct
test-selected|test|akkoma tuwunel phpbb anubis|true|anubis"
while IFS='|' read -r label env sel want_flag want_ing; do
    [ -n "${label}" ] || continue
    for b in ${BUILDERS}; do
        root="${WORK}/anubis-${label}-$(bn "${b}")"; seed_tree "${root}"
        run_builder "${b}" "${sel}" "" "${env}" "${root}"
        rc=$?
        [ "${rc}" -eq 0 ] || { bad "$(bn "${b}") [${label}]: selection+gate did not run (rc=${rc})"; continue; }
        [ "$(cm_flag "${root}" anubis)" = "${want_flag}" ] \
            && ok "$(bn "${b}") [${label}]: ConfigMap anubis \"${want_flag}\"" \
            || bad "$(bn "${b}") [${label}]: ConfigMap anubis is $(cm_flag "${root}" anubis), expected ${want_flag}"
        [ "$(ingress_backend "${root}")" = "${want_ing}" ] \
            && ok "$(bn "${b}") [${label}]: public fe-gateway Ingress backend = ${want_ing}" \
            || bad "$(bn "${b}") [${label}]: public Ingress backend is $(ingress_backend "${root}"), expected ${want_ing} (PoW shield NOT in path)"
    done
    # THE parity assertion the unit asks for, stated as an artefact comparison:
    # anubis handling on x86 must produce the SAME rendered result as on rpi5.
    _ra="${WORK}/anubis-${label}-build-rpi5-stage4.sh"; _rx="${WORK}/anubis-${label}-build-x86-host-stage4.sh"
    if diff -q "$(cm_of "${_ra}")" "$(cm_of "${_rx}")" >/dev/null 2>&1 \
       && diff -q "$(fe_of "${_ra}")" "$(fe_of "${_rx}")" >/dev/null 2>&1 \
       && diff -q "$(cr_of "${_ra}")" "$(cr_of "${_rx}")" >/dev/null 2>&1; then
        ok "[${label}]: x86 renders the SAME ConfigMap + fe-gateway + OptionalService CR as rpi5"
    else
        bad "[${label}]: x86's rendered anubis result DIFFERS from rpi5's"
    fi
done <<< "${ANUBIS_CASES}"

# ═════════════════════════════════════════════════════════════════════════════
# 3) D3 — --exclude-services edge-ai removes the ORPHAN WRAPPER on BOTH.
#    The wrapper (edge-ai-analysis) dependsOn the model server (edge-ai). With
#    edge-ai excluded, the wrapper must be gone from the tree, from the ConfigMap
#    and from the 13a element — even though it was NAMED in --optional-services.
#    This is an ORDERING property of the builder's selection region, which is why
#    that region is executed verbatim rather than paraphrased.
# ═════════════════════════════════════════════════════════════════════════════
echo "-- D3: --exclude-services edge-ai drops the orphan analysis wrapper (both builders) --"
for b in ${BUILDERS}; do
    root="${WORK}/depguard-$(bn "${b}")"; seed_tree "${root}"
    run_builder "${b}" "akkoma edge-ai edge-ai-analysis" "edge-ai" test "${root}"
    rc=$?
    [ "${rc}" -eq 0 ] || { bad "$(bn "${b}"): selection+gate did not run (rc=${rc})"; continue; }
    t="$(tree_of "${root}")"
    [ ! -f "${t}/apps/54-edge-ai.yaml" ] \
        && ok "$(bn "${b}"): excluded edge-ai — 54-edge-ai.yaml pruned" \
        || bad "$(bn "${b}"): excluded edge-ai — 54-edge-ai.yaml survived"
    [ ! -f "${t}/apps/55-edge-ai-analysis.yaml" ] \
        && ok "$(bn "${b}"): ORPHAN WRAPPER 55-edge-ai-analysis.yaml pruned (no model server)" \
        || bad "$(bn "${b}"): ORPHAN WRAPPER 55-edge-ai-analysis.yaml SHIPPED with no edge-ai behind it"
    [ ! -d "${t}/manifests/edge-ai-analysis" ] \
        && ok "$(bn "${b}"): manifests/edge-ai-analysis pruned" \
        || bad "$(bn "${b}"): manifests/edge-ai-analysis survived with no upstream"
    [ "$(cm_flag "${root}" edge-ai-analysis)" = "false" ] \
        && ok "$(bn "${b}"): ConfigMap edge-ai-analysis \"false\"" \
        || bad "$(bn "${b}"): ConfigMap edge-ai-analysis is $(cm_flag "${root}" edge-ai-analysis), expected false"
    [ "$(appset_flag "${root}" edge-ai-analysis)" = "false" ] \
        && ok "$(bn "${b}"): 13a element edge-ai-analysis \"false\"" \
        || bad "$(bn "${b}"): 13a element edge-ai-analysis is $(appset_flag "${root}" edge-ai-analysis), expected false"
    grep -qE "'/v1/analyze/\*\*'" "${t}/manifests/route-access/initdb/20-schema.sql" \
        && bad "$(bn "${b}"): /v1/analyze/** route-access row outlived the wrapper (stale grant)" \
        || ok "$(bn "${b}"): /v1/analyze/** route-access row removed"
done
_da="${WORK}/depguard-build-rpi5-stage4.sh"; _dx="${WORK}/depguard-build-x86-host-stage4.sh"
diff -r "$(tree_of "${_da}")" "$(tree_of "${_dx}")" >/dev/null 2>&1 \
    && ok "--exclude-services edge-ai: both builders bake an IDENTICAL tree" \
    || bad "--exclude-services edge-ai: the two builders bake DIFFERENT trees"

# CONTROL — the guard must not be a blanket drop. With edge-ai actually selected,
# the wrapper must SURVIVE on both. (Without this, "delete edge-ai-analysis
# always" would pass every assertion above.)
echo "-- D3 control: wrapper SURVIVES when edge-ai is genuinely selected --"
for b in ${BUILDERS}; do
    root="${WORK}/depkeep-$(bn "${b}")"; seed_tree "${root}"
    run_builder "${b}" "akkoma edge-ai edge-ai-analysis" "" test "${root}"
    t="$(tree_of "${root}")"
    # SPLIT into its two halves. The CONTROL is the surviving Application: that is
    # what proves the dependsOn guard is a guard and not "delete edge-ai-analysis
    # always". The 13a flag is a SEPARATE invariant and follows the same
    # no-double-management rule as akkoma above — conflating them into one `&&`
    # meant C1's guard read as "the wrapper was dropped anyway", which it was not.
    [ -f "${t}/apps/55-edge-ai-analysis.yaml" ] \
        && ok "$(bn "${b}"): edge-ai selected — wrapper 55-edge-ai-analysis.yaml KEPT (the guard is a dependency guard, not a blanket prune)" \
        || bad "$(bn "${b}"): edge-ai selected but the wrapper was dropped anyway (blanket prune, not a dependency guard)"
    _want13a="$(expected_appset_flag "${root}" edge-ai-analysis)"
    [ "$(appset_flag "${root}" edge-ai-analysis)" = "${_want13a}" ] \
        && ok "$(bn "${b}"): edge-ai selected — edge-ai-analysis 13a element \"${_want13a}\" per the no-double-management rule" \
        || bad "$(bn "${b}"): edge-ai selected — edge-ai-analysis 13a element is $(appset_flag "${root}" edge-ai-analysis), expected \"${_want13a}\""
done

# ═════════════════════════════════════════════════════════════════════════════
# 3b) THE X86-ONLY BLOCK THE EXTRACTION FOLDED IN — asserted ABSOLUTELY.
#     The edge-ai models-ConfigMap patch (runtime/preload/default-model from the
#     --edge-ai-* flags) is the ONE piece of behaviour that existed on x86 and
#     never on rpi5, so the shared library is its only home now.
#
#     RELATIVE PARITY CANNOT SEE IT. MEASURED (2026-08-26, adversarial review):
#     deleting the whole `if _opt_selected edge-ai; then … models-configmap.yaml …`
#     block from the lib left ALL SEVEN suites green — the sweep's edge-ai-full
#     case ran with all three knobs empty, so the block was a no-op on both sides
#     and every diff -r still matched. The extraction could have DROPPED the block
#     with nothing noticing, which is the same class of defect this unit exists to
#     close. tests/build-matrix/check.sh only asserts the flag reaches argv.
#
#     So: run the x86 leg with NON-EMPTY values and grep the rendered ConfigMap for
#     each of the three, and run the rpi5 leg (which defines NONE of the three, and
#     runs under set -u) and require that file byte-identical to the fixture — which
#     is what the `${VAR:-}` guard buys, and what an unguarded ${VAR} read would
#     turn into an unbound-variable abort.
# ═════════════════════════════════════════════════════════════════════════════
echo "-- edge-ai model library: ABSOLUTE rendered values (x86 knobs) + rpi5 no-op --"
FIXTURE_MODELS="${SRC}/manifests/edge-ai/models-configmap.yaml"
if [ ! -f "${FIXTURE_MODELS}" ]; then
    bad "specs/cluster/manifests/edge-ai/models-configmap.yaml missing — the edge-ai knob assertions would be vacuous"
else
    # (a) x86 WITH flags: every one of the three values must appear, rendered.
    root="${WORK}/edge-ai-knobs-x86"; seed_tree "${root}"
    run_builder "${REPO}/build-x86-host-stage4.sh" "akkoma edge-ai" "" prod "${root}" \
        'EDGE_AI_RUNTIME=vllm; EDGE_AI_MODELS="qwen2.5:7b,nomic-embed-text"; EDGE_AI_MODEL_DEFAULT="qwen2.5:7b"'
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        bad "x86 [edge-ai knobs]: selection+gate did not run (rc=${rc})"
    else
        mc="$(models_of "${root}")"
        if [ ! -f "${mc}" ]; then
            bad "x86 [edge-ai knobs]: manifests/edge-ai/models-configmap.yaml is gone though edge-ai was selected"
        else
            grep -E '^  runtime: "vllm"$' "${mc}" >/dev/null \
                && ok "x86 [edge-ai knobs]: rendered runtime: \"vllm\" (--edge-ai-runtime)" \
                || bad "x86 [edge-ai knobs]: runtime line is [$(grep -E '^  runtime:' "${mc}" | head -1)], expected vllm"
            grep -E '^  preload: "qwen2\.5:7b,nomic-embed-text"$' "${mc}" >/dev/null \
                && ok "x86 [edge-ai knobs]: rendered preload list (--edge-ai-models)" \
                || bad "x86 [edge-ai knobs]: preload line is [$(grep -E '^  preload:' "${mc}" | head -1)], expected the flag value"
            grep -E '^  default-model: "qwen2\.5:7b"$' "${mc}" >/dev/null \
                && ok "x86 [edge-ai knobs]: rendered default-model (--edge-ai-model-default)" \
                || bad "x86 [edge-ai knobs]: default-model line is [$(grep -E '^  default-model:' "${mc}" | head -1)], expected the flag value"
            # NON-VACUITY: the rendered file must actually DIFFER from the fixture,
            # or the three greps above could be reading the checked-in defaults.
            cmp -s "${mc}" "${FIXTURE_MODELS}" \
                && bad "x86 [edge-ai knobs]: the ConfigMap is byte-identical to the fixture — the patch block never ran" \
                || ok "x86 [edge-ai knobs]: the ConfigMap was genuinely rewritten (not the checked-in default)"
        fi
    fi
    # (b) rpi5 defines NONE of the three knobs and the gate runs under set -u. It
    #     must complete, and leave the ConfigMap byte-identical to the fixture.
    root="${WORK}/edge-ai-noknobs-rpi5"; seed_tree "${root}"
    run_builder "${REPO}/build-rpi5-stage4.sh" "akkoma edge-ai" "" prod "${root}"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        bad "rpi5 [no edge-ai knobs]: the gate ABORTED (rc=${rc}) — an unguarded \${EDGE_AI_*} read under set -u"
    else
        ok "rpi5 [no edge-ai knobs]: the gate completes with all three knobs UNBOUND under set -u"
        cmp -s "$(models_of "${root}")" "${FIXTURE_MODELS}" \
            && ok "rpi5 [no edge-ai knobs]: models-configmap.yaml left BYTE-IDENTICAL to the fixture" \
            || bad "rpi5 [no edge-ai knobs]: models-configmap.yaml was rewritten though rpi5 has no --edge-ai-* flags"
    fi
    # (c) x86 with its OWN defaults (runtime=ollama, the other two empty) must ALSO
    #     leave the file byte-identical — that is why the whole-tree sweep below can
    #     still expect the two builders to bake identical trees for edge-ai-full.
    root="${WORK}/edge-ai-defaults-x86"; seed_tree "${root}"
    run_builder "${REPO}/build-x86-host-stage4.sh" "akkoma edge-ai" "" prod "${root}"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        bad "x86 [builder defaults]: selection+gate did not run (rc=${rc})"
    else
        cmp -s "$(models_of "${root}")" "${FIXTURE_MODELS}" \
            && ok "x86 [builder defaults]: no --edge-ai-* flags given — ConfigMap byte-identical to the fixture" \
            || bad "x86 [builder defaults]: the ConfigMap changed with no flags given ($(diff "${FIXTURE_MODELS}" "$(models_of "${root}")" | head -2 | tr '\n' ';'))"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# 4) WHOLE-TREE parity sweep over a spread of selections. Any divergence between
#    the two builders' baked trees — in ANY file, not just the three above — is a
#    failure. This is what would have caught D1/D2/D3 on the day they landed.
# ═════════════════════════════════════════════════════════════════════════════
echo "-- whole-tree parity across a spread of selections --"
SWEEP="default|akkoma tuwunel phpbb||test
default-prod|akkoma tuwunel phpbb||prod
all-user|akkoma tuwunel phpbb games owncast tube character-studio character-forge||prod
exclude-two|akkoma tuwunel phpbb games owncast tube|phpbb tuwunel|prod
none|||prod
anubis-off-prod|akkoma tuwunel phpbb -anubis||prod
edge-ai-full|akkoma edge-ai edge-ai-analysis edge-ai-tts||prod"
while IFS='|' read -r label sel excl env; do
    [ -n "${label}" ] || continue
    ra="${WORK}/sweep-${label}-rpi5"; rx="${WORK}/sweep-${label}-x86"
    seed_tree "${ra}"; seed_tree "${rx}"
    run_builder "${REPO}/build-rpi5-stage4.sh"     "${sel}" "${excl}" "${env}" "${ra}"; rca=$?
    run_builder "${REPO}/build-x86-host-stage4.sh" "${sel}" "${excl}" "${env}" "${rx}"; rcx=$?
    if [ "${rca}" -ne 0 ] || [ "${rcx}" -ne 0 ]; then
        bad "[${label}]: a builder's selection+gate did not run (rpi5=${rca} x86=${rcx})"
        continue
    fi
    if diff -r "$(tree_of "${ra}")" "$(tree_of "${rx}")" >/dev/null 2>&1; then
        ok "[${label}]: rpi5 and x86 bake an IDENTICAL cluster tree"
    else
        bad "[${label}]: the two builders bake DIFFERENT trees — $(diff -rq "$(tree_of "${ra}")" "$(tree_of "${rx}")" 2>&1 | head -3 | tr '\n' ';')"
    fi
done <<< "${SWEEP}"

# ═════════════════════════════════════════════════════════════════════════════
# 5) The suite must not be vacuous: prove the fixture actually CHANGES, so a
#    "both builders did nothing" bug cannot read as parity. (An empty gate would
#    make every diff -r above pass.)
# ═════════════════════════════════════════════════════════════════════════════
echo "-- non-vacuity: the gate demonstrably rewrites the fixture --"
pristine="${WORK}/pristine"; seed_tree "${pristine}"
diff -r "$(tree_of "${pristine}")" "$(tree_of "${WORK}/sweep-default-rpi5")" >/dev/null 2>&1 \
    && bad "the gate changed NOTHING — every parity diff above is vacuous" \
    || ok "the gate demonstrably rewrites the fixture (parity diffs are meaningful)"
# ...and that a DIFFERENT selection produces a DIFFERENT tree (so the assertions
# are sensitive to the selection at all).
diff -r "$(tree_of "${WORK}/sweep-default-rpi5")" "$(tree_of "${WORK}/sweep-all-user-rpi5")" >/dev/null 2>&1 \
    && bad "two different selections baked the SAME tree — the gate ignores the selection" \
    || ok "different selections bake different trees (the gate is selection-sensitive)"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
