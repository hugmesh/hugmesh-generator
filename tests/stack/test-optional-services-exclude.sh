#!/usr/bin/env bash
# test-optional-services-exclude.sh — unit test for the BUILD-TIME EXCLUSION of
# ANY user-level OPTIONAL service in the CLUSTER optional-services mechanism.
#
# REQUIREMENT (user): the generated images/cluster must be able to EXCLUDE any
# user-level service (akkoma/tuwunel/phpbb/games/owncast/tube) at build/generation
# time. Excluding a service must OMIT its Application/manifests from the rendered
# build, and the rest must degrade gracefully (installed-services ConfigMap marks
# it absent; the 13a ApplicationSet element flips to installed:"false"; gateway
# routes + route-access rows are removed so no 502/stale-grant).
#
# WHAT THIS PROVES (WITHOUT a full cross-build) by sourcing the REAL helper +
# gate functions from build-rpi5-stage4.sh and running them against a realistic
# sandbox baked tree (seeded from the live specs/cluster files):
#   * every user-level slug is REGISTERED in optional-services.yaml;
#   * for EACH slug: EXCLUDED => its owned apps/*.yaml + manifests/<dir> are gone,
#     its gateway routes + route-access rows are gone, the ConfigMap boolean is
#     "false", and the 13a ApplicationSet element is installed:"false";
#   * INCLUDED => app present, manifests present, ConfigMap "true", 13a "true";
#   * the EXCLUDE_SERVICES subtractive knob removes a slug from a full positive
#     selection (force-OFF regardless of how it was selected);
#   * the DEFAULT-INCLUSION POLICY (user 2026-06-17): a DEFAULT build (no
#     OPTIONAL_SERVICES) renders akkoma+tuwunel+phpbb and PRUNES games+owncast+tube;
#     OPTIONAL_SERVICES=all renders everything; a default-off slug is included when
#     explicitly added; EXCLUDE_SERVICES removes a default-ON slug. games is now
#     DEFAULT-OFF (registry default: off + ConfigMap baseline "false").
#
# Arch-neutral: the gate operates on the shared specs/cluster tree. The rpi5
# builder is the canonical cluster-node builder whose gate/helpers are sourced
# and exercised below; build-x86-host-stage4.sh carries the SAME selection knobs
# (all-sentinel + EXCLUDE_SERVICES, ported from rpi5) and its wiring is
# grep-asserted in section 4c so the two builders cannot silently diverge. 4c
# also extracts BOTH builders' real `games)` case bodies and diffs them for the
# games-instances/games-services control-plane pruning markers, so a games)
# case edited in only one builder (the divergence class that shipped once
# already) fails the test instead of silently drifting.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER="${REPO}/build-rpi5-stage4.sh"
BUILDER_X86="${REPO}/build-x86-host-stage4.sh"
REG="${REPO}/specs/cluster/optional-services.yaml"
SRC="${REPO}/specs/cluster"
[ -f "${BUILDER}" ] || { echo "  FAIL builder missing"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
info(){ :; }; warn(){ :; }; err(){ echo "    ERR $*" >&2; }   # silence the builder logger

echo "== optional-services BUILD-TIME EXCLUSION unit test =="

# ── Extract the REAL gate + helpers from the builder (so the test tracks them) ──
extract_fn() { awk "/^$1\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}" "${BUILDER}"; }
for fn in _opt_selected _opt_explicitly_deselected _opt_anubis_installed \
          _opt_drop_kustomize_line _opt_drop_route _opt_drop_extrahost _opt_drop_rows \
          _opt_fix_trailing_comma _opt_wire_anubis_ingress _opt_render_appset_flag \
          _opt_render_installed_services \
          _opt_set_cr_enabled _opt_render_optionalservice_cr \
          _opt_federation_module _opt_gate_sql_value _opt_render_federation_modules \
          gate_optional_services; do
  eval "$(extract_fn "${fn}")"
  type "${fn}" >/dev/null 2>&1 || { echo "  FAIL could not extract ${fn}"; exit 1; }
done
ok "extracted the real gate + helper functions from build-rpi5-stage4.sh"
# _opt_render_optionalservice_cr + _opt_render_federation_modules are extracted too,
# not because THIS suite asserts on them (their own gates do — tests/federation/
# test-federation-modules-selection.sh for the federation half), but because
# gate_optional_services CALLS them: without the definitions every run printed
# "command not found" to stderr while still reporting 0 failed, which is the exact
# shape of a suite that looks gateable and is quietly running less code than it
# claims. Both return 0 immediately when their artefact is absent from this
# sandbox tree, so the assertions below are unchanged.

# ── The user-level OPTIONAL services this requirement targets ─────────────────
USER_SERVICES="akkoma tuwunel phpbb games owncast tube character-studio character-forge"
# DEFAULT-INCLUSION POLICY (user 2026-06-17): the built-in default when NO
# OPTIONAL_SERVICES is given, and the DEFAULT-OFF set that must be explicitly added.
DEFAULT_ON="akkoma tuwunel phpbb"
DEFAULT_OFF="games owncast tube character-studio character-forge"

# resolve_selection — mirror the BUILDER's OPTIONAL_SERVICES resolution so the test
# tracks it: (1) built-in default when unset, (2) the `all` sentinel expands to the
# full user-level set, (3) EXCLUDE_SERVICES subtracts LAST. Echoes the final list.
# $1 = OPTIONAL_SERVICES (empty => built-in default), $2 = EXCLUDE_SERVICES.
resolve_selection() {
  local opt="$1" excl="${2:-}" _x _s _kept
  [ -n "${opt}" ] || opt="${DEFAULT_ON}"                 # built-in default
  case " ${opt} " in *" all "*) opt="${USER_SERVICES}";; esac   # full-set sentinel
  if [ -n "${excl//[[:space:],]/}" ]; then               # EXCLUDE_SERVICES subtracts
    for _x in ${excl//,/ }; do
      _kept=""
      for _s in ${opt}; do [ "${_s}" = "${_x}" ] || _kept="${_kept} ${_s}"; done
      opt="${_kept# }"
    done
  fi
  echo "${opt}"
}

# ── 1) registry: every user-level slug is registered ─────────────────────────
if command -v python3 >/dev/null; then
  python3 - "${REG}" "${USER_SERVICES}" <<'PY' && ok "all user-level slugs registered in optional-services.yaml" || bad "a user-level slug is missing from the registry"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
slugs = {s["slug"] for s in d["spec"]["services"]}
missing = [s for s in sys.argv[2].split() if s not in slugs]
assert not missing, f"not registered: {missing}"
PY
else
  echo "  SKIP registry assertion (no python3)"
fi

# ── seed a realistic baked tree from the live specs/cluster files ─────────────
# SYSROOT is what the builder expects; the tree lives under it.
seed_tree() {
  SYSROOT="${WORK}/sysroot-$1"; rm -rf "${SYSROOT}"
  local tree="${SYSROOT}/var/lib/hugmesh/cluster"
  mkdir -p "${tree}/apps" "${tree}/manifests/external-secrets" \
           "${tree}/manifests/route-access/initdb" "${tree}/manifests/policy"
  # The per-slug owned apps + manifest dirs (copy the real ones so the gate's
  # rm -f / rm -rf hit the actual filenames).
  cp "${SRC}/apps/13a-optional-services.yaml" "${tree}/apps/"
  cp "${SRC}/manifests/policy/installed-services-configmap.yaml" "${tree}/manifests/policy/"
  cp "${SRC}/manifests/route-access/initdb/20-schema.sql" "${tree}/manifests/route-access/initdb/"
  cp "${SRC}/manifests/external-secrets/kustomization.yaml" "${tree}/manifests/external-secrets/"
  # owned apps
  for a in 30-akkoma 30-tuwunel 30-phpbb 38-forum-bff-db 39-forum-bff-api 49-forum-ui \
           45-social-ui 06-casdoor-games 50-games 13c-games-instances 52-owncast 53-tube \
           49b-character-studio-ui \
           38b-character-forge-bff-db 39b-character-forge-bff-api 49c-character-forge-ui; do
    [ -f "${SRC}/apps/${a}.yaml" ] && cp "${SRC}/apps/${a}.yaml" "${tree}/apps/"
  done
  cp "${SRC}/apps/20-gateway-be.yaml" "${tree}/apps/" 2>/dev/null || :
  cp "${SRC}/apps/20-gateway-fe.yaml" "${tree}/apps/" 2>/dev/null || :
  # owned ESO halves
  for e in akkoma-externalsecrets tuwunel-externalsecrets tube-externalsecrets; do
    [ -f "${SRC}/manifests/external-secrets/${e}.yaml" ] && \
      cp "${SRC}/manifests/external-secrets/${e}.yaml" "${tree}/manifests/external-secrets/"
  done
  # owned manifest dirs
  for m in akkoma tuwunel forum forum-bff-db forum-bff-api forum-ui games casdoor-games \
           games-instances owncast tube character-studio casdoor \
           character-forge character-forge-bff-api character-forge-bff-db; do
    [ -d "${SRC}/manifests/${m}" ] && cp -r "${SRC}/manifests/${m}" "${tree}/manifests/"
  done
  export SYSROOT
  TREE="${tree}"
}

# Map: slug -> the owned apps/*.yaml whose ABSENCE proves exclusion, and a
# manifests/<dir> whose absence proves exclusion.
declare -A OWNED_APP=(
  [akkoma]="30-akkoma.yaml"   [tuwunel]="30-tuwunel.yaml" [phpbb]="30-phpbb.yaml"
  [games]="50-games.yaml"     [owncast]="52-owncast.yaml" [tube]="53-tube.yaml"
  [character-studio]="49b-character-studio-ui.yaml"
  # character-forge is MULTI-APP (BFF db + BFF api + UI); the representative app/dir
  # here + the dedicated spot-check block below covers the other two of each.
  [character-forge]="49c-character-forge-ui.yaml"
)
declare -A OWNED_DIR=(
  [akkoma]="akkoma" [tuwunel]="tuwunel" [phpbb]="forum" [games]="games"
  [owncast]="owncast" [tube]="tube" [character-studio]="character-studio"
  [character-forge]="character-forge"
)

ENV="test"   # the gate's anubis ENV branch reads this

# ── 2) EXCLUDED: each user-level slug omitted from the build ──────────────────
echo "-- EXCLUDED (per-service): app + manifests pruned, ConfigMap+13a 'false' --"
for slug in ${USER_SERVICES}; do
  seed_tree "excl-${slug}"
  # Select EVERYTHING EXCEPT this slug (force-include the others incl games so the
  # exclusion of THIS slug is isolated). The gate prunes any slug NOT selected.
  sel=""; for s in ${USER_SERVICES}; do [ "${s}" = "${slug}" ] || sel="${sel} ${s}"; done
  OPTIONAL_SERVICES="${sel# }"
  gate_optional_services
  app="${OWNED_APP[$slug]}"; dir="${OWNED_DIR[$slug]}"
  [ ! -f "${TREE}/apps/${app}" ]       && ok "${slug}: owned Application ${app} OMITTED"        || bad "${slug}: ${app} survived exclusion"
  [ ! -d "${TREE}/manifests/${dir}" ]  && ok "${slug}: manifests/${dir} OMITTED"                || bad "${slug}: manifests/${dir} survived exclusion"
  grep -qE "^[[:space:]]*${slug}:[[:space:]]*\"false\"" "${TREE}/manifests/policy/installed-services-configmap.yaml" \
      && ok "${slug}: installed-services ConfigMap marks it ABSENT (false)" || bad "${slug}: ConfigMap not false"
  grep -qE "\{[[:space:]]*slug:[[:space:]]*${slug}[[:space:]]*,.*installed:[[:space:]]*\"false\"" "${TREE}/apps/13a-optional-services.yaml" \
      && ok "${slug}: 13a ApplicationSet element installed:\"false\"" || bad "${slug}: 13a element not false"
done

# Slug-specific route/row omission spot-checks (no 502 / no stale-grant).
seed_tree "excl-routes"
OPTIONAL_SERVICES="games owncast tube"   # akkoma+tuwunel+phpbb excluded
gate_optional_services
grep -q 'mastodon-' "${TREE}/apps/20-gateway-be.yaml" && bad "akkoma gateway routes survived" || ok "akkoma: gateway mastodon-* routes removed"
grep -q "'/_matrix/\*\*'" "${TREE}/manifests/route-access/initdb/20-schema.sql" && bad "tuwunel /_matrix row survived" || ok "tuwunel: /_matrix route-access row removed"
grep -q "'/social/forum/\*\*'" "${TREE}/manifests/route-access/initdb/20-schema.sql" && bad "phpbb /social/forum row survived" || ok "phpbb: /social/forum route-access row removed"
# both homeservers gone => shared social-ui pruned.
[ ! -f "${TREE}/apps/45-social-ui.yaml" ] && ok "shared 45-social-ui pruned when BOTH homeservers excluded" || bad "social-ui survived with both homeservers gone"

# ── every drop must cover EVERY gateway that carries the path ─────────────────
# The spot-checks above ask "did this one row go?". They cannot ask "did the row
# go EVERYWHERE it exists", and 20-schema.sql grants several paths on more than
# one gateway: the Matrix surface is granted on hugmesh-be-gateway AND, for the
# front door, on hugmesh-fe-gateway. tuwunel's case dropped only the be-gateway
# leg, so three live ROLE_MATRIX/MOD/ADMIN grants outlived the homeserver (#143).
#
# So sweep the whole table instead of sampling it: for every path any
# _opt_drop_rows call names, the set of gateways that HAVE rows for it must be
# covered by the set of gateways that case actually cleans. Both builders are
# checked, because they carry independent copies of the same case list.
echo "-- route-access drops: whole-table gateway coverage --"
if command -v python3 >/dev/null; then
  for _b in "${BUILDER}" "${BUILDER_X86}"; do
    python3 - "${_b}" "${REPO}/specs/cluster/manifests/route-access/initdb/20-schema.sql" <<'PY'
import collections, re, sys
bld, sql = (open(p, encoding="utf-8").read() for p in sys.argv[1:3])
rows = collections.defaultdict(set)
for gw, path in re.findall(r"\(\s*'([^']+)'\s*,\s*'([^']+)'", sql):
    rows[path].add(gw)
drops = collections.defaultdict(set)
for gw, blob in re.findall(
        r"_opt_drop_rows\s+\"[^\"]+\"\s+(\S+)\s*\\?\s*\n?\s*((?:'[^']*'\s*)+)", bld):
    for p in re.findall(r"'([^']*)'", blob):
        drops[p].add(gw)
if not drops:
    print("         no _opt_drop_rows call parsed — the sweep would be vacuous")
    sys.exit(2)
gaps = {p: sorted(rows.get(p, set()) - g) for p, g in drops.items() if rows.get(p, set()) - g}
for p, gws in sorted(gaps.items()):
    print("         '%s' still granted on %s — that case never cleans it there"
          % (p, ", ".join(gws)))
print("         swept %d dropped path(s) against %d schema path(s)" % (len(drops), len(rows)))
sys.exit(1 if gaps else 0)
PY
    _rc=$?
    _bn="${_b##*/}"
    case "${_rc}" in
      0) ok "${_bn}: every dropped path is cleaned on every gateway that grants it" ;;
      2) bad "${_bn}: the coverage sweep parsed ZERO _opt_drop_rows calls — vacuous, not clean" ;;
      *) bad "${_bn}: a route-access row outlives its service on a gateway the case never cleans (see the paths above)" ;;
    esac
  done
else
  bad "route-access coverage sweep needs python3 — skipping it would leave the #143 class unguarded"
fi

seed_tree "excl-owncast-tube"
OPTIONAL_SERVICES="akkoma tuwunel phpbb"   # owncast+tube+games excluded (default-off)
gate_optional_services
grep -q "'/bff/owncast/\*\*'" "${TREE}/manifests/route-access/initdb/20-schema.sql" && bad "owncast row survived" || ok "owncast: /bff/owncast route-access row removed"
grep -q "'/bff/tube/\*\*'"   "${TREE}/manifests/route-access/initdb/20-schema.sql" && bad "tube row survived"    || ok "tube: /bff/tube route-access row removed"
grep -q "'/tube/content/\*\*'" "${TREE}/manifests/route-access/initdb/20-schema.sql" && bad "tube media row survived" || ok "tube: /tube/content route-access row removed"
[ ! -f "${TREE}/manifests/external-secrets/tube-externalsecrets.yaml" ] && ok "tube: per-service ESO file pruned" || bad "tube ESO survived exclusion"
# character-studio excluded (default-off): its ONE fe-gateway route + route-access row removed.
grep -q 'id: character-studio-ui' "${TREE}/apps/20-gateway-fe.yaml" && bad "character-studio gateway route survived" || ok "character-studio: fe-gateway character-studio-ui route removed"
grep -q "'/character-studio/\*\*'" "${TREE}/manifests/route-access/initdb/20-schema.sql" && bad "character-studio row survived" || ok "character-studio: /character-studio route-access row removed"
# character-forge excluded (default-off): the MULTI-APP slug's TWO fe-gateway routes,
# TWO route-access rows, and all THREE apps + THREE manifest dirs removed.
grep -q 'id: character-forge-ui' "${TREE}/apps/20-gateway-fe.yaml" && bad "character-forge UI gateway route survived" || ok "character-forge: fe-gateway character-forge-ui route removed"
grep -q 'id: hugmesh-character-forge-bff-api' "${TREE}/apps/20-gateway-fe.yaml" && bad "character-forge BFF gateway route survived" || ok "character-forge: fe-gateway BFF route removed"
grep -q "'/character-forge/\*\*'" "${TREE}/manifests/route-access/initdb/20-schema.sql" && bad "character-forge UI row survived" || ok "character-forge: /character-forge route-access row removed"
grep -q "'/bff/character-forge/\*\*'" "${TREE}/manifests/route-access/initdb/20-schema.sql" && bad "character-forge BFF row survived" || ok "character-forge: /bff/character-forge route-access row removed"
[ ! -f "${TREE}/apps/38b-character-forge-bff-db.yaml" ] && [ ! -f "${TREE}/apps/39b-character-forge-bff-api.yaml" ] \
  && ok "character-forge: BFF db + api Applications OMITTED (multi-app)" || bad "character-forge: a BFF Application survived exclusion"
[ ! -d "${TREE}/manifests/character-forge-bff-api" ] && [ ! -d "${TREE}/manifests/character-forge-bff-db" ] \
  && ok "character-forge: BFF api + db manifest dirs OMITTED (multi-app)" || bad "character-forge: a BFF manifest dir survived exclusion"

# ── 3) INCLUDED: each user-level slug kept => present + ConfigMap/13a 'true' ──
echo "-- INCLUDED (all user services): apps + manifests present, ConfigMap+13a 'true' --"
seed_tree "incl-all"
OPTIONAL_SERVICES="${USER_SERVICES}"
gate_optional_services
for slug in ${USER_SERVICES}; do
  app="${OWNED_APP[$slug]}"; dir="${OWNED_DIR[$slug]}"
  [ -f "${TREE}/apps/${app}" ]      && ok "${slug}: owned Application ${app} PRESENT" || bad "${slug}: ${app} pruned despite selection"
  [ -d "${TREE}/manifests/${dir}" ] && ok "${slug}: manifests/${dir} PRESENT"         || bad "${slug}: manifests/${dir} pruned despite selection"
  grep -qE "^[[:space:]]*${slug}:[[:space:]]*\"true\"" "${TREE}/manifests/policy/installed-services-configmap.yaml" \
      && ok "${slug}: ConfigMap installed (true)" || bad "${slug}: ConfigMap not true despite selection"
  grep -qE "\{[[:space:]]*slug:[[:space:]]*${slug}[[:space:]]*,.*installed:[[:space:]]*\"true\"" "${TREE}/apps/13a-optional-services.yaml" \
      && ok "${slug}: 13a element installed:\"true\"" || bad "${slug}: 13a element not true despite selection"
done

# ── 4) EXCLUDE_SERVICES subtractive knob (force-OFF from a full selection) ─────
echo "-- EXCLUDE_SERVICES subtractive knob --"
# Reproduce the builder's subtraction block (mirrors build-rpi5-stage4.sh).
apply_exclude() {  # $1=OPTIONAL_SERVICES $2=EXCLUDE_SERVICES -> echo final
  local OPTIONAL_SERVICES="$1" EXCLUDE_SERVICES="$2" _x _s _kept
  if [ -n "${EXCLUDE_SERVICES//[[:space:],]/}" ]; then
    for _x in ${EXCLUDE_SERVICES//,/ }; do
      _kept=""
      for _s in ${OPTIONAL_SERVICES}; do [ "${_s}" = "${_x}" ] || _kept="${_kept} ${_s}"; done
      OPTIONAL_SERVICES="${_kept# }"
    done
  fi
  echo "${OPTIONAL_SERVICES}"
}
out="$(apply_exclude "akkoma tuwunel phpbb games owncast tube" "phpbb tuwunel")"
case " ${out} " in
  *" phpbb "*|*" tuwunel "*) bad "EXCLUDE_SERVICES did not remove phpbb/tuwunel (got: ${out})" ;;
  *" akkoma "*) ok "EXCLUDE_SERVICES removed phpbb+tuwunel, kept the rest (got: ${out})" ;;
  *) bad "EXCLUDE_SERVICES produced unexpected result (got: ${out})" ;;
esac
# excluding a not-selected slug is a harmless no-op.
out="$(apply_exclude "akkoma" "owncast")"
[ "${out}" = "akkoma" ] && ok "EXCLUDE_SERVICES of a non-selected slug is a no-op" || bad "no-op exclude changed the selection (got: ${out})"
# the builder actually wires the knob (regex-anchored to the source line).
grep -q 'EXCLUDE_SERVICES' "${BUILDER}" && ok "builder defines/reads EXCLUDE_SERVICES" || bad "builder missing EXCLUDE_SERVICES"
grep -q -- '--exclude-services' "${BUILDER}" && ok "builder accepts --exclude-services CLI flag" || bad "builder missing --exclude-services flag"

# ── 4b) DEFAULT-INCLUSION POLICY (user 2026-06-17) ────────────────────────────
echo "-- DEFAULT-INCLUSION POLICY: default set / 'all' sentinel / opt-in / default-on exclude --"

# resolve_selection must agree with the REAL builder's resolution (built-in default
# < all-sentinel < EXCLUDE last). Spot-check the builder actually wires each leg.
grep -q 'OPTIONAL_SERVICES="${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}"' "${BUILDER}" \
  && ok "builder built-in default is 'akkoma tuwunel phpbb' (games/owncast/tube OFF)" \
  || bad "builder built-in default is not 'akkoma tuwunel phpbb'"
grep -q -- '--all-services' "${BUILDER}" && ok "builder accepts --all-services CLI flag" || bad "builder missing --all-services flag"
grep -qE 'OPTIONAL_SERVICES="\$\{USER_LEVEL_SERVICES\}"' "${BUILDER}" \
  && ok "builder expands the 'all' sentinel to USER_LEVEL_SERVICES" || bad "builder missing 'all' sentinel expansion"

# (a) DEFAULT build — NO OPTIONAL_SERVICES given: renders akkoma+tuwunel+phpbb and
#     PRUNES games+owncast+tube (Applications/manifests/ConfigMap=false/13a=false).
seed_tree "default-set"
OPTIONAL_SERVICES="$(resolve_selection "" "")"
[ "${OPTIONAL_SERVICES}" = "${DEFAULT_ON}" ] \
  && ok "DEFAULT resolution = '${DEFAULT_ON}' (no OPTIONAL_SERVICES given)" \
  || bad "DEFAULT resolution wrong (got: ${OPTIONAL_SERVICES})"
gate_optional_services
for slug in ${DEFAULT_ON}; do
  app="${OWNED_APP[$slug]}"; dir="${OWNED_DIR[$slug]}"
  [ -f "${TREE}/apps/${app}" ] && [ -d "${TREE}/manifests/${dir}" ] \
    && ok "DEFAULT: ${slug} PRESENT (app + manifests)" || bad "DEFAULT: ${slug} pruned despite default-on"
  grep -qE "^[[:space:]]*${slug}:[[:space:]]*\"true\"" "${TREE}/manifests/policy/installed-services-configmap.yaml" \
    && ok "DEFAULT: ${slug} ConfigMap true" || bad "DEFAULT: ${slug} ConfigMap not true"
done
for slug in ${DEFAULT_OFF}; do
  app="${OWNED_APP[$slug]}"; dir="${OWNED_DIR[$slug]}"
  [ ! -f "${TREE}/apps/${app}" ] && ok "DEFAULT: ${slug} Application PRUNED (default-off)" || bad "DEFAULT: ${slug} app survived (should be default-off)"
  [ ! -d "${TREE}/manifests/${dir}" ] && ok "DEFAULT: ${slug} manifests PRUNED (default-off)" || bad "DEFAULT: ${slug} manifests survived (should be default-off)"
  grep -qE "^[[:space:]]*${slug}:[[:space:]]*\"false\"" "${TREE}/manifests/policy/installed-services-configmap.yaml" \
    && ok "DEFAULT: ${slug} ConfigMap false" || bad "DEFAULT: ${slug} ConfigMap not false"
  grep -qE "\{[[:space:]]*slug:[[:space:]]*${slug}[[:space:]]*,.*installed:[[:space:]]*\"false\"" "${TREE}/apps/13a-optional-services.yaml" \
    && ok "DEFAULT: ${slug} 13a element absent (installed:\"false\")" || bad "DEFAULT: ${slug} 13a not false"
done
# games is the headline policy move: DEFAULT-OFF.
case " ${DEFAULT_ON} " in *" games "*) bad "POLICY REGRESSION: games is in the default-on set" ;; *) ok "POLICY: games is DEFAULT-OFF (not in built-in default)" ;; esac

# ── 4c) x86 builder parity: the SAME selection knobs are wired there too ──────
# build-x86-host-stage4.sh ports the rpi5 resolution (env-respecting built-in
# default -> `all` sentinel -> opt-in folds -> EXCLUDE_SERVICES LAST). Grep-anchor
# each leg so a refactor of either builder cannot silently drop the parity.
echo "-- x86 builder parity (build-x86-host-stage4.sh selection knobs) --"
if [ -f "${BUILDER_X86}" ]; then
  grep -q 'OPTIONAL_SERVICES="${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}"' "${BUILDER_X86}" \
    && ok "x86: built-in default is 'akkoma tuwunel phpbb' (env/brand.conf-respecting)" \
    || bad "x86: built-in default is not the env-respecting 'akkoma tuwunel phpbb'"
  grep -q 'USER_LEVEL_SERVICES="akkoma tuwunel phpbb games owncast tube character-studio character-forge"' "${BUILDER_X86}" \
    && ok "x86: USER_LEVEL_SERVICES matches the rpi5 user-level set" \
    || bad "x86: USER_LEVEL_SERVICES missing or diverged from rpi5"
  grep -q -- '--all-services' "${BUILDER_X86}" && ok "x86: accepts --all-services CLI flag" || bad "x86: missing --all-services flag"
  grep -q -- '--exclude-services' "${BUILDER_X86}" && ok "x86: accepts --exclude-services CLI flag" || bad "x86: missing --exclude-services flag"
  grep -qE 'OPTIONAL_SERVICES="\$\{USER_LEVEL_SERVICES\}"' "${BUILDER_X86}" \
    && ok "x86: expands the 'all' sentinel to USER_LEVEL_SERVICES" || bad "x86: missing 'all' sentinel expansion"
  grep -q 'EXCLUDE_SERVICES="${EXCLUDE_SERVICES:-}"' "${BUILDER_X86}" \
    && ok "x86: EXCLUDE_SERVICES knob (env/brand.conf) defined" || bad "x86: EXCLUDE_SERVICES knob missing"
  grep -q 'EXCLUDE_SERVICES removed' "${BUILDER_X86}" \
    && ok "x86: applies the EXCLUDE_SERVICES subtraction pass" || bad "x86: EXCLUDE_SERVICES subtraction pass missing"
  bash -n "${BUILDER_X86}" && ok "build-x86-host-stage4.sh: bash -n clean" || bad "x86 builder failed bash -n"

  # ── games-instances (app-store control-plane) prune parity ─────────────────
  # The games) case in EACH builder must ALSO prune the games-instances/
  # games-services control plane (13c ApplicationSet, manifests/games-instances,
  # the two casdoor sync Jobs, the games-servers-console route, and the
  # games-services route-access rows) when games itself is deselected — that
  # control plane rides the games slug and cannot be left orphaned. Extract the
  # REAL `games)` case body from each builder (not a hand-copied excerpt) so a
  # future refactor of either file is caught here, not just at audit time.
  extract_case_block() {  # $1 = builder file -> the games) ... ;; block, verbatim
    awk '/^            games\)$/{p=1} p{print; if(/^                ;;$/){exit}}' "$1"
  }
  RPI5_GAMES_CASE="$(extract_case_block "${BUILDER}")"
  X86_GAMES_CASE="$(extract_case_block "${BUILDER_X86}")"
  [ -n "${RPI5_GAMES_CASE}" ] && ok "extracted rpi5 games) case body" || bad "could not extract rpi5 games) case body"
  [ -n "${X86_GAMES_CASE}" ] && ok "extracted x86 games) case body" || bad "could not extract x86 games) case body"
  for marker in '13c-games-instances.yaml' 'manifests/games-instances' \
                'games-services-admin-sync-job.yaml' 'games-services-runner-sync-job.yaml' \
                'games-servers-console' 'games-services/instances' 'admin/games-services'; do
    rpi5_has=1; echo "${RPI5_GAMES_CASE}" | grep -F -- "${marker}" >/dev/null && rpi5_has=0
    x86_has=1;  echo "${X86_GAMES_CASE}"  | grep -F -- "${marker}" >/dev/null && x86_has=0
    if [ "${rpi5_has}" -eq 0 ] && [ "${x86_has}" -eq 0 ]; then
      ok "games-instances parity: both builders prune '${marker}' in the games) case"
    elif [ "${rpi5_has}" -eq 0 ] && [ "${x86_has}" -ne 0 ]; then
      bad "games-instances DIVERGENCE: rpi5 games) prunes '${marker}' but x86 games) does NOT"
    elif [ "${x86_has}" -eq 0 ] && [ "${rpi5_has}" -ne 0 ]; then
      bad "games-instances DIVERGENCE: x86 games) prunes '${marker}' but rpi5 games) does NOT"
    else
      bad "games-instances marker '${marker}' missing from BOTH builders' games) case (control plane no longer pruned anywhere)"
    fi
  done
else
  bad "build-x86-host-stage4.sh missing"
fi

# (b) OPTIONAL_SERVICES=all — renders EVERYTHING.
seed_tree "all-sentinel"
OPTIONAL_SERVICES="$(resolve_selection "all" "")"
[ "${OPTIONAL_SERVICES}" = "${USER_SERVICES}" ] \
  && ok "'all' sentinel resolved to every user-level slug" || bad "'all' resolution wrong (got: ${OPTIONAL_SERVICES})"
gate_optional_services
for slug in ${USER_SERVICES}; do
  app="${OWNED_APP[$slug]}"
  [ -f "${TREE}/apps/${app}" ] && ok "all: ${slug} PRESENT" || bad "all: ${slug} pruned despite 'all'"
  grep -qE "^[[:space:]]*${slug}:[[:space:]]*\"true\"" "${TREE}/manifests/policy/installed-services-configmap.yaml" \
    && ok "all: ${slug} ConfigMap true" || bad "all: ${slug} ConfigMap not true under 'all'"
done

# (c) adding a default-OFF service (default set + games) — games is now INCLUDED.
seed_tree "add-games"
OPTIONAL_SERVICES="$(resolve_selection "akkoma tuwunel phpbb games" "")"
gate_optional_services
[ -f "${TREE}/apps/${OWNED_APP[games]}" ] && ok "opt-in: explicitly-added 'games' is INCLUDED (50-games.yaml present)" || bad "opt-in: games pruned despite explicit selection"
grep -qE "^[[:space:]]*games:[[:space:]]*\"true\"" "${TREE}/manifests/policy/installed-services-configmap.yaml" \
  && ok "opt-in: games ConfigMap true when added" || bad "opt-in: games ConfigMap not true when added"
[ ! -f "${TREE}/apps/${OWNED_APP[owncast]}" ] && ok "opt-in: still-unlisted owncast PRUNED" || bad "opt-in: owncast survived without selection"

# (d) EXCLUDE_SERVICES=phpbb removes a DEFAULT-ON service from the default set.
seed_tree "exclude-default-on"
OPTIONAL_SERVICES="$(resolve_selection "" "phpbb")"   # default set minus phpbb
case " ${OPTIONAL_SERVICES} " in *" phpbb "*) bad "EXCLUDE_SERVICES=phpbb did not drop the default-on phpbb (got: ${OPTIONAL_SERVICES})" ;; *" akkoma "*) ok "EXCLUDE_SERVICES=phpbb removed the DEFAULT-ON phpbb, kept akkoma+tuwunel (got: ${OPTIONAL_SERVICES})" ;; *) bad "EXCLUDE on default set produced unexpected result (got: ${OPTIONAL_SERVICES})" ;; esac
gate_optional_services
[ ! -f "${TREE}/apps/${OWNED_APP[phpbb]}" ] && ok "EXCLUDE phpbb: 30-phpbb.yaml PRUNED" || bad "EXCLUDE phpbb: app survived"
grep -qE "^[[:space:]]*phpbb:[[:space:]]*\"false\"" "${TREE}/manifests/policy/installed-services-configmap.yaml" \
  && ok "EXCLUDE phpbb: ConfigMap false" || bad "EXCLUDE phpbb: ConfigMap not false"
# 'all' + EXCLUDE still subtracts.
out="$(resolve_selection "all" "games owncast")"
case " ${out} " in *" games "*|*" owncast "*) bad "'all' + EXCLUDE_SERVICES did not subtract (got: ${out})" ;; *" tube "*) ok "'all' + EXCLUDE_SERVICES='games owncast' = all-but-those (got: ${out})" ;; *) bad "'all'+EXCLUDE unexpected (got: ${out})" ;; esac

# Registry + ConfigMap literal baselines record the DEFAULT-OFF policy for games
# (so a render-less repo-synced cluster ships games dark, never re-forcing it on).
if command -v python3 >/dev/null; then
  python3 - "${REG}" <<'PY' && ok "registry: games default: off (DEFAULT-OFF policy)" || bad "registry: games is not default: off"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
g = next(s for s in d["spec"]["services"] if s["slug"] == "games")
assert g["default"] in (False, "off"), f"games default={g['default']!r}"
PY
fi
grep -qE '^[[:space:]]*games:[[:space:]]*"false"' "${SRC}/manifests/policy/installed-services-configmap.yaml" \
  && ok "ConfigMap baseline: games \"false\" (safe default for render-less repo sync)" || bad "ConfigMap baseline games not \"false\""

# ── 5) the surviving baked artefacts still parse (YAML + JSON + bash) ─────────
echo "-- artefact integrity after pruning --"
bash -n "${BUILDER}" && ok "build-rpi5-stage4.sh: bash -n clean" || bad "builder failed bash -n"
if command -v python3 >/dev/null; then
  python3 - "${TREE}" <<'PY' && ok "post-prune ConfigMap + 13a + ESO-kustomization parse as YAML; services.json parses as JSON" || bad "a post-prune artefact failed to parse"
import sys, yaml, json
t = sys.argv[1]
cm = yaml.safe_load(open(f"{t}/manifests/policy/installed-services-configmap.yaml"))
json.loads(cm["data"]["services.json"])
yaml.safe_load(open(f"{t}/apps/13a-optional-services.yaml"))
yaml.safe_load(open(f"{t}/manifests/external-secrets/kustomization.yaml"))
PY
else
  echo "  SKIP YAML/JSON parse (no python3)"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
