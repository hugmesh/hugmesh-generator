#!/usr/bin/env bash
# test-anubis-env-gate.sh — unit test for the Anubis PUBLIC PoW-shield ENV policy
# in build-rpi5-stage4.sh (PR #107).
#
# REQUIREMENT (maintainer): the Anubis PoW shield is ALL-UP + ENABLED BY DEFAULT in
# PROD (ENV=prod) and DISABLED BY DEFAULT in TEST (ENV=test); an explicit operator
# selection/deselection ALWAYS wins. "All shields up" means the public fe-gateway
# Ingress is rerouted THROUGH the Anubis PoW gate (:8923) when installed.
#
# Proves this WITHOUT a full cross-build by sourcing the REAL helper functions
# (_opt_selected, _opt_explicitly_deselected, _opt_anubis_installed,
# _opt_render_installed_services, _opt_wire_anubis_ingress) extracted from the
# builder and exercising them against a sandbox baked tree:
#   * ENV=prod default        => installed-services ConfigMap anubis: "true"
#                                + fe-gateway public Ingress routed THROUGH anubis;
#   * ENV=test default        => anubis: "false" + DIRECT path (no reroute);
#   * explicit "anubis"/"-anubis"/"no-anubis" override either ENV;
#   * the reroute is IDEMPOTENT (re-run adds no duplicates) and REVERSIBLE.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER="${REPO}/build-rpi5-stage4.sh"
[ -f "${BUILDER}" ] || { echo "  FAIL builder missing"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
info(){ :; }   # silence the builder's logger inside the extracted functions

echo "== anubis ENV-policy gate unit test =="

# ── Load the REAL helper functions AS THE BUILDER RESOLVES THEM ───────────────
# These moved out of the builder into the SHARED scripts/_optional-services-lib.sh
# on 2026-08-26 — build-x86-host-stage4.sh had NO anubis handling at ALL (no
# _opt_explicitly_deselected, no _opt_anubis_installed, no _opt_wire_anubis_ingress),
# so every x86 --env prod image shipped the PUBLIC PoW shield off and the fe-gateway
# ingress un-rerouted while this suite was green against rpi5. opt_gate_load walks the
# builder's own source chain (libs first, builder last, last definition winning), so a
# re-added builder-local override is still what this suite would execute.
info(){ :; }; warn(){ :; }
source "${REPO}/tests/lib/opt-gate-source.sh"
opt_gate_load "${BUILDER}" _opt_selected _opt_explicitly_deselected _opt_anubis_installed \
              _opt_render_installed_services _opt_wire_anubis_ingress _opt_render_appset_flag || exit 1
ok "loaded the real builder functions (decision + render + ingress reroute)"

# ── Seed a sandbox baked tree (ConfigMap + fe-gateway app) ────────────────────
seed_tree() {
    SYSROOT="${WORK}/sysroot-$1"; rm -rf "${SYSROOT}"
    local pol="${SYSROOT}/var/lib/hugmesh/cluster/manifests/policy"
    local apps="${SYSROOT}/var/lib/hugmesh/cluster/apps"
    mkdir -p "${pol}" "${apps}"
    cp "${REPO}/specs/cluster/manifests/policy/installed-services-configmap.yaml" \
       "${pol}/installed-services-configmap.yaml"
    cp "${REPO}/specs/cluster/apps/20-gateway-fe.yaml" "${apps}/20-gateway-fe.yaml"
}
cm()  { echo "${SYSROOT}/var/lib/hugmesh/cluster/manifests/policy/installed-services-configmap.yaml"; }
fe()  { echo "${SYSROOT}/var/lib/hugmesh/cluster/apps/20-gateway-fe.yaml"; }
anubis_flag() { grep -E '^[[:space:]]*anubis:[[:space:]]*"(true|false)"' "$(cm)" | head -1 | grep -oE '(true|false)'; }
routed_through_anubis() { grep -qE '^[[:space:]]*backendServiceName:[[:space:]]*anubis' "$(fe)"; }

run_render() {  # $1=ENV  $2=OPTIONAL_SERVICES ; renders into the current SYSROOT
    ENV="$1"; OPTIONAL_SERVICES="$2"
    _opt_render_installed_services
}

# ── 1) ENV=prod default => ON + ingress routed through Anubis ─────────────────
seed_tree prod-default
run_render prod "akkoma tuwunel phpbb games"
[ "$(anubis_flag)" = "true" ] && ok "ENV=prod default: ConfigMap anubis: \"true\" (shields up)" \
                              || bad "ENV=prod default: anubis flag not true (got $(anubis_flag))"
routed_through_anubis && ok "ENV=prod default: public fe-gateway Ingress ROUTED THROUGH anubis (:8923)" \
                       || bad "ENV=prod default: ingress NOT rerouted through anubis"
grep -qE '^[[:space:]]*backendServicePort:[[:space:]]*8923' "$(fe)" \
    && ok "ENV=prod default: reroute targets the PoW gate port :8923" || bad "reroute missing :8923 port"
python3 -c "import yaml,sys; list(yaml.safe_load_all(open('$(fe)'))); list(yaml.safe_load_all(open('$(cm)')))" \
    && ok "ENV=prod: rewritten ConfigMap + fe-gateway app still parse as YAML" || bad "rewrite produced invalid YAML"

# ── 2) ENV=test default => OFF + DIRECT path (no reroute) ─────────────────────
seed_tree test-default
run_render test "akkoma tuwunel phpbb games"
[ "$(anubis_flag)" = "false" ] && ok "ENV=test default: ConfigMap anubis: \"false\" (shield off)" \
                               || bad "ENV=test default: anubis flag not false (got $(anubis_flag))"
routed_through_anubis && bad "ENV=test default: ingress wrongly rerouted through anubis" \
                       || ok "ENV=test default: public ingress DIRECT to fe-gateway (no reroute)"
# the unrelated base slugs still resolve from presence
grep -qE '^[[:space:]]*games:[[:space:]]*"true"' "$(cm)" && ok "ENV=test: unrelated slug (games) rendered from presence" \
                                                          || bad "base slug render regressed"

# ── 3) explicit selection/deselection ALWAYS wins ────────────────────────────
seed_tree prod-deselect
run_render prod "akkoma -anubis"
[ "$(anubis_flag)" = "false" ] && ok "ENV=prod + '-anubis': explicit deselect wins (OFF)" \
                               || bad "explicit '-anubis' did not turn anubis off in prod"
routed_through_anubis && bad "prod -anubis: ingress wrongly rerouted" || ok "prod -anubis: no reroute (direct path)"

seed_tree prod-deselect-noform
run_render prod "akkoma no-anubis"
[ "$(anubis_flag)" = "false" ] && ok "ENV=prod + 'no-anubis': alt deselect token wins (OFF)" \
                               || bad "'no-anubis' did not turn anubis off in prod"

seed_tree test-select
run_render test "akkoma anubis"
[ "$(anubis_flag)" = "true" ] && ok "ENV=test + 'anubis': explicit select wins (ON)" \
                              || bad "explicit 'anubis' did not turn anubis on in test"
routed_through_anubis && ok "test + anubis: reroute wired on explicit select" || bad "explicit select did not wire the reroute"

# ── 4) idempotent + reversible reroute ───────────────────────────────────────
seed_tree idem
run_render prod "akkoma tuwunel phpbb games"     # ON  -> wires reroute
run_render prod "akkoma tuwunel phpbb games"     # ON again -> must NOT duplicate
n="$(grep -cE '^[[:space:]]*backendServiceName:[[:space:]]*anubis' "$(fe)")"
[ "${n}" -eq 1 ] && ok "reroute is IDEMPOTENT (single backendServiceName after re-render)" \
                 || bad "reroute duplicated on re-render (count=${n})"
nc="$(grep -cE 'PoW shield UP: route public ingress THROUGH Anubis' "$(fe)")"
[ "${nc}" -eq 1 ] && ok "reroute marker comment not duplicated" || bad "marker comment duplicated (count=${nc})"
run_render test "akkoma tuwunel phpbb games"     # flip OFF -> must REMOVE the reroute
routed_through_anubis && bad "reroute NOT reversed when anubis flipped off" \
                       || ok "reroute is REVERSIBLE (removed when anubis flips off)"

# ── 5) the wiring is GATED, not hardcoded — asserted on EFFECT, not on grep ──
# This block used to be `grep -q '_opt_wire_anubis_ingress' "${BUILDER}"` and
# `grep -q '_opt_anubis_installed()' "${BUILDER}"`. Both are function-NAME greps,
# which is the weakest possible form: the name is satisfied by a comment, and by a
# present-but-wrong body. So instead: render once with the reroute stripped out of
# the tree beforehand and prove the RENDER PATH puts it back (i.e. the render calls
# the reroute), and prove the decision genuinely varies with ENV alone.
seed_tree wired-by-render
sed -i -E '/backendServiceName:|backendServicePort:|PoW shield UP/d' "$(fe)"
run_render prod "akkoma tuwunel phpbb"
routed_through_anubis \
    && ok "the RENDER path itself wires the reroute (stripped tree came back rerouted)" \
    || bad "render did not wire the reroute — _opt_wire_anubis_ingress is not called by the render"
# ENV is the ONLY thing that differs between these two; the decision must differ too.
ENV=prod; OPTIONAL_SERVICES="akkoma tuwunel phpbb"; _prod="$(_opt_anubis_installed)"
ENV=test; OPTIONAL_SERVICES="akkoma tuwunel phpbb"; _test="$(_opt_anubis_installed)"
[ "${_prod}" = "true" ] && [ "${_test}" = "false" ] \
    && ok "the decision is ENV-CONDITIONAL (prod=>true, test=>false, same selection)" \
    || bad "decision is not ENV-conditional (prod=${_prod} test=${_test} for the same selection)"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
