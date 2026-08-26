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
# Section 7 EXECUTES this one, so a missing file must abort rather than skip.
[ -f "${BUILDER_X86}" ] || { echo "  FAIL x86 builder missing: ${BUILDER_X86}"; exit 1; }

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
          _opt_render_installed_services gate_optional_services; do
  eval "$(extract_fn "${fn}")"
  type "${fn}" >/dev/null 2>&1 || { echo "  FAIL could not extract ${fn}"; exit 1; }
done
ok "extracted the real gate + helper functions from build-rpi5-stage4.sh"

# ── PREFLIGHT: python3 + PyYAML are MANDATORY here, not optional ─────────────
# This suite used to `echo "  SKIP registry assertion (no python3)"` and carry on.
# Since 2026-08-26 the registry DRIVES the test — the slug set, the tier split and
# the consumer derivation all come out of specs/cluster/optional-services.yaml —
# so a missing parser does not weaken one assertion, it makes the whole file
# vacuous while still printing PASS lines. Fail LOUDLY with a named reason
# instead; exit 2 marks "could not run", distinct from an assertion failure (1).
# (The alpine CI job installs python3 + py3-yaml; see .github/workflows/shell-suites.yml.)
if ! command -v python3 >/dev/null 2>&1; then
  echo "  CANNOT RUN: python3 is missing — this suite derives every slug, tier and" >&2
  echo "              consumer from specs/cluster/optional-services.yaml and would" >&2
  echo "              otherwise pass vacuously. Install python3 + PyYAML." >&2
  exit 2
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "  CANNOT RUN: PyYAML is missing (python3 -c 'import yaml' failed) — same" >&2
  echo "              reason as above. alpine: apk add py3-yaml." >&2
  exit 2
fi

# ── THE REGISTRY IS THE SOURCE; this suite DERIVES from it ───────────────────
# WHAT THIS INVERTS, and why. Until 2026-08-26 the next line read:
#     USER_SERVICES="akkoma tuwunel phpbb games owncast tube character-studio character-forge"
# and section 1 asserted only that every name in it was PRESENT in the registry —
# i.e. registry ⊇ hardcoded-list. That direction proves nothing about registry
# GROWTH: a new row could be added with no consumer anywhere and this suite stayed
# green, because the new slug was not in the hardcoded list to begin with. It is
# the same shape as the incident the registry header records — `headwind` sitting
# in both builders' render loops with no ConfigMap key to rewrite, a silent no-op
# for weeks.
# So the arrow is reversed: the lists below are DERIVED from the registry, every
# later loop iterates the derived set, and the hardcoded copies that remain (the
# two builders' USER_LEVEL_SERVICES strings) are asserted set-EQUAL to it rather
# than merely contained in it. Adding a registry row now changes what this suite
# tests, which is the only way registry growth can prove anything.
REGDUMP="${WORK}/registry.env"
python3 - "${REG}" > "${REGDUMP}" <<'PY' || { echo "  CANNOT RUN: registry parse failed" >&2; exit 2; }
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
svcs = d["spec"]["services"]
def emit(name, vals): print('%s="%s"' % (name, " ".join(vals)))
def on(v):  return v is True  or v == "on"
def off(v): return v is False or v == "off"
emit("REG_SLUGS",        [s["slug"] for s in svcs])
emit("REG_USER_LEVEL",   [s["slug"] for s in svcs if s.get("tier") == "user-level"])
emit("REG_INFRA",        [s["slug"] for s in svcs if s.get("tier") == "infra"])
emit("REG_DEFAULT_ON",   [s["slug"] for s in svcs if s.get("tier") == "user-level" and on(s.get("default"))])
emit("REG_DEFAULT_OFF",  [s["slug"] for s in svcs if s.get("tier") == "user-level" and off(s.get("default"))])
emit("REG_GATE_BUILD",   [s["slug"] for s in svcs if s.get("gate") == "build-time"])
emit("REG_GATE_RUNTIME", [s["slug"] for s in svcs if s.get("gate") == "runtime"])
emit("REG_GATE_NONE",    [s["slug"] for s in svcs if s.get("gate") == "none"])
emit("REG_GATED",        [s["slug"] for s in svcs if s.get("gate") in ("build-time", "runtime")])
# buildGate: the PER-BUILDER column. `gate:` answers "does anything read this row
# anywhere"; buildGate answers "can THIS builder honour --optional-services <slug>",
# which is the only question the slug validators may gate on. The two differ for
# every `gate: runtime` row (no build-time consumer by definition) and they differ
# BETWEEN builders for anubis (rpi5 renders it from the selection, x86 does not).
def bg(builder):
    return [s["slug"] for s in svcs if builder in (s.get("buildGate") or [])]
emit("REG_BUILDGATE_RPI5", bg("rpi5"))
emit("REG_BUILDGATE_X86",  bg("x86"))
emit("REG_NOTREG",       [n["id"] for n in d["spec"].get("notRegistered", [])])
# Schema violations, reported as slug:key tokens so the shell can name them.
bad = []
for s in svcs:
    if s.get("tier") not in ("user-level", "infra"):            bad.append(s["slug"] + ":tier")
    if s.get("gate") not in ("build-time", "runtime", "none"):  bad.append(s["slug"] + ":gate")
    # A `gate: none` row is a promise that NOTHING reads it — it must say why, in
    # prose a human wrote. 40 chars is deliberately low: it rejects "TODO" and
    # "n/a", not a terse-but-real sentence.
    if s.get("gate") == "none" and len((s.get("gateReason") or "").strip()) < 40:
        bad.append(s["slug"] + ":gateReason")
    if s.get("gate") != "none" and (s.get("gateReason") or "").strip():
        bad.append(s["slug"] + ":gateReason-on-gated-row")
    # buildGate must be a list of known builder ids. It is REQUIRED on every row —
    # an absent key would read as "[]" and silently make a slug unselectable, which
    # is the same silent-drop shape from the other side.
    b = s.get("buildGate")
    if not isinstance(b, list) or any(x not in ("rpi5", "x86") for x in b):
        bad.append(s["slug"] + ":buildGate")
    # gate: none is a promise that NOTHING reads the row, so it cannot also claim
    # a builder bakes it; gate: build-time is a claim that a prune arm exists, so
    # at least one builder must list itself. (gate: runtime may go either way:
    # coturn/meshbridge have no build-time consumer at all -> [], while anubis has
    # no PRUNE arm — that is what `runtime` denies — yet rpi5 still renders its
    # ConfigMap key + 13a element from the selection, so it lists rpi5.)
    elif b and s.get("gate") == "none":
        bad.append(s["slug"] + ":buildGate-on-gate-none")
    elif not b and s.get("gate") == "build-time":
        bad.append(s["slug"] + ":buildGate-empty-on-build-time")
emit("REG_BAD_ROWS", bad)
PY
# shellcheck source=/dev/null
. "${REGDUMP}"

# setsort — normalise a whitespace-separated list for SET comparison. The registry
# and the builders legitimately order their slugs differently (the registry has
# tube before owncast, both builders have owncast before tube), so every
# cross-file comparison below is a set comparison, never a string one. No `-q`
# consumer on this pipeline: `set -o pipefail` + a -q short-circuit turns a FOUND
# match into a failure, and sort/tr both drain their input.
setsort() { printf '%s\n' $1 | LC_ALL=C sort | tr '\n' ' '; }
seteq() { [ "$(setsort "$1")" = "$(setsort "$2")" ]; }

# The DERIVED sets every later loop in this file iterates.
USER_SERVICES="${REG_USER_LEVEL}"
DEFAULT_ON="${REG_DEFAULT_ON}"
DEFAULT_OFF="${REG_DEFAULT_OFF}"

# ── 0) the derivation itself cannot be empty ─────────────────────────────────
# A derived-from-a-file list that silently comes back empty is how a suite goes
# green having asserted nothing at all: every `for slug in ${USER_SERVICES}` below
# would iterate zero times and every ok() would simply never be reached. Pin the
# counts before anything uses them, and ABORT (not just fail) if they are wrong —
# continuing would print a long green run over an empty test.
[ -n "${REG_SLUGS//[[:space:]]/}" ] || { echo "  CANNOT RUN: registry yielded ZERO slugs" >&2; exit 2; }
[ -n "${USER_SERVICES//[[:space:]]/}" ] || { echo "  CANNOT RUN: registry yielded ZERO user-level slugs" >&2; exit 2; }
[ -n "${DEFAULT_ON//[[:space:]]/}" ] || { echo "  CANNOT RUN: registry yielded ZERO default-on slugs" >&2; exit 2; }
ok "registry parsed: $(set -- ${REG_SLUGS}; echo $#) slugs ($(set -- ${USER_SERVICES}; echo $#) user-level, $(set -- ${REG_INFRA}; echo $#) infra)"

# ── 1) registry SCHEMA: every row declares a tier, a gate, and a reason if none ─
if [ -z "${REG_BAD_ROWS//[[:space:]]/}" ]; then
  ok "every registry row carries a valid tier: + gate: (and a written gateReason: iff gate: none)"
else
  bad "registry rows with a missing/invalid tier:, gate: or gateReason: — ${REG_BAD_ROWS}"
fi

# ── 1a) the tier split is TOTAL and DISJOINT ────────────────────────────────
if seteq "${REG_SLUGS}" "${REG_USER_LEVEL} ${REG_INFRA}"; then
  ok "tier: partitions the registry exactly (user-level + infra = every slug, no overlap)"
else
  bad "tier: does not partition the registry (slugs=${REG_SLUGS} / user=${REG_USER_LEVEL} / infra=${REG_INFRA})"
fi

# ── 1b) THE INVERSION: the builders' USER_LEVEL_SERVICES must EQUAL tier: user-level
# These two shell strings were the ONLY machine-readable statement of the
# user-level/infra split before `tier:` existed. They stay (the builders cannot
# parse YAML at build time), but they are now MIRRORS, asserted set-equal to the
# registry — so a row added with the wrong tier, or a builder string edited alone,
# is red here rather than a fourth divergent copy.
for _b in "${BUILDER}" "${BUILDER_X86}"; do
  _bn="$(basename "${_b}")"
  if [ ! -f "${_b}" ]; then bad "${_bn}: missing"; continue; fi
  # Comment-stripped: prose naming these slugs has inverted exactly this kind of
  # check four times in this repo, and both builders discuss the set in comments
  # directly above the assignment.
  _lit="$(grep -v '^[[:space:]]*#' "${_b}" | sed -n 's/^USER_LEVEL_SERVICES="\(.*\)"$/\1/p' | head -1)"
  if [ -z "${_lit}" ]; then
    bad "${_bn}: no USER_LEVEL_SERVICES= assignment found outside comments"
  elif seteq "${_lit}" "${USER_SERVICES}"; then
    ok "${_bn}: USER_LEVEL_SERVICES set-equals registry tier: user-level"
  else
    bad "${_bn}: USER_LEVEL_SERVICES='${_lit}' != registry tier:user-level='${USER_SERVICES}'"
  fi
  # The built-in default (no --optional-services given) must equal the registry's
  # user-level `default: on` rows, for the same reason.
  _def="$(grep -v '^[[:space:]]*#' "${_b}" | sed -n 's/^OPTIONAL_SERVICES="\${OPTIONAL_SERVICES:-\(.*\)}"$/\1/p' | head -1)"
  if [ -z "${_def}" ]; then
    bad "${_bn}: no built-in OPTIONAL_SERVICES default assignment found outside comments"
  elif seteq "${_def}" "${DEFAULT_ON}"; then
    ok "${_bn}: built-in default set-equals registry user-level default: on"
  else
    bad "${_bn}: built-in default='${_def}' != registry default:on='${DEFAULT_ON}'"
  fi
done
unset _b _bn _lit _def

# ── 1c) Studio's catalogue tuple is the third copy — same treatment ──────────
# studio/hugmesh_studio/core/config.py OPTIONAL_SERVICES_CHOICES is what the GUI
# offers. It is NOT allowed to drift from tier: user-level either. (Its sibling
# INFRA_SERVICES_CHOICES is deliberately a SUBSET of tier: infra — the four slugs
# the rpi5 wizard exposes — so it is checked for containment, not equality.)
STUDIO_CFG="${REPO}/studio/hugmesh_studio/core/config.py"
if [ -f "${STUDIO_CFG}" ]; then
  _sc="$(python3 - "${STUDIO_CFG}" <<'PY'
import ast, sys
src = open(sys.argv[1], encoding="utf-8").read()
mod = ast.parse(src)
out = {}
for node in mod.body:
    if isinstance(node, ast.Assign) and len(node.targets) == 1 \
       and isinstance(node.targets[0], ast.Name) \
       and node.targets[0].id in ("OPTIONAL_SERVICES_CHOICES", "INFRA_SERVICES_CHOICES"):
        try:
            out[node.targets[0].id] = list(ast.literal_eval(node.value))
        except Exception:
            pass
print(" ".join(out.get("OPTIONAL_SERVICES_CHOICES", [])))
print(" ".join(out.get("INFRA_SERVICES_CHOICES", [])))
PY
)"
  _sc_user="$(printf '%s\n' "${_sc}" | sed -n 1p)"
  _sc_infra="$(printf '%s\n' "${_sc}" | sed -n 2p)"
  if [ -z "${_sc_user//[[:space:]]/}" ]; then
    bad "studio config.py: could not read OPTIONAL_SERVICES_CHOICES"
  elif seteq "${_sc_user}" "${USER_SERVICES}"; then
    ok "studio config.py: OPTIONAL_SERVICES_CHOICES set-equals registry tier: user-level"
  else
    bad "studio config.py: OPTIONAL_SERVICES_CHOICES='${_sc_user}' != registry tier:user-level"
  fi
  _orphan=""
  for _s in ${_sc_infra}; do
    case " ${REG_INFRA} " in *" ${_s} "*) ;; *) _orphan="${_orphan} ${_s}" ;; esac
  done
  if [ -z "${_orphan//[[:space:]]/}" ]; then
    ok "studio config.py: INFRA_SERVICES_CHOICES is a subset of registry tier: infra"
  else
    bad "studio config.py: INFRA_SERVICES_CHOICES names slug(s) that are not registry tier:infra —${_orphan}"
  fi
  unset _sc _sc_user _sc_infra _orphan _s
else
  bad "studio/hugmesh_studio/core/config.py missing (the third copy of the tier split is unchecked)"
fi

# ── 1d) DELIBERATELY-NOT-REGISTERED ids must NOT also be slugs ───────────────
# spec.notRegistered records image-builder / harbor / velero and WHY each is out
# (always-on-and-CI-enforced; already selectable on the MANAGED-vs-SELF-HOSTED
# axis). The hazard it guards is one service acquiring two independent spellings
# that can disagree, so the machine check is simply: no id here is also a slug.
if [ -n "${REG_NOTREG//[[:space:]]/}" ]; then
  _dup=""
  for _s in ${REG_NOTREG}; do
    case " ${REG_SLUGS} " in *" ${_s} "*) _dup="${_dup} ${_s}" ;; esac
  done
  if [ -z "${_dup//[[:space:]]/}" ]; then
    ok "spec.notRegistered (${REG_NOTREG}) — none of them is also a spec.services slug"
  else
    bad "one-service-two-spellings: notRegistered id(s) also registered as slugs —${_dup}"
  fi
  unset _dup _s
else
  bad "spec.notRegistered is empty/absent — the harbor/velero/image-builder exclusions are unrecorded"
fi

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


# ═════════════════════════════════════════════════════════════════════════════
# 6) THE VACUITY GUARD: every registry row must have a CONSUMER, or say it has none
# ═════════════════════════════════════════════════════════════════════════════
# WHY THIS SECTION EXISTS. specs/cluster/optional-services.yaml calls itself "the
# SINGLE source-of-truth registry", but a row in it is inert YAML: it does nothing
# unless some file elsewhere reads the slug. That gap has already bitten. `headwind`
# was listed in BOTH builders' _opt_render_installed_services() render loops while
# manifests/policy/installed-services-configmap.yaml had NO `headwind:` key — and
# that renderer is a `sed -i -E "s#^(\s*)<slug>: \"(true|false)\"#...#"`, which
# matches nothing, changes nothing and exits 0 when the key is absent. It was a
# silent no-op for weeks; the backfill comment is still above that key today.
#
# So this section does NOT restate a list of slugs — restating is what failed. It
# DERIVES the consumer set from the shipped files:
#   * a BUILD-TIME arm  = the slug appears in gate_optional_services()' `for slug in`
#                         loop AND has a matching `<slug>)` case arm, in either builder
#   * a ConfigMap key   = a `<slug>: "true|false"` data key in installed-services-configmap.yaml
#   * a 13a element     = a `- { slug: <slug>, ...}` element in apps/13a-optional-services.yaml
# and then checks each row's declared `gate:` against what was actually found,
# IN BOTH DIRECTIONS. Claiming a gate you do not have fails; having a gate you did
# not declare fails; and a `gate: none` row must genuinely be read by nothing.
#
# Comment-stripping: every file is scanned with full-line comments removed first.
# All three of these files discuss their own slugs in prose directly above the
# lines being matched, and a check that counts a token has been inverted by exactly
# that four times in this repo.
echo "-- registry rows vs. their DERIVED consumers (the vacuity guard) --"
CONSDUMP="${WORK}/consumers.env"
printf '%s\n' ${REG_SLUGS} > "${WORK}/reg-slugs.txt"
python3 - "${SRC}/manifests/policy/installed-services-configmap.yaml" \
           "${SRC}/apps/13a-optional-services.yaml" \
           "${SRC}/manifests/optional-services-operator/seed-optionalservices.yaml" \
           "${WORK}/reg-slugs.txt" \
           "${BUILDER}" "${BUILDER_X86}" > "${CONSDUMP}" <<'PY' || { echo "  CANNOT RUN: consumer derivation failed" >&2; exit 2; }
import re, sys
CM, A13, SEED, REGSLUGS = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
BUILDERS = sys.argv[5:]

def nocomment(text):
    # FULL-LINE comments only. A trailing `# ...` is left alone deliberately: in
    # shell a '#' can sit inside a quoted string, and every pattern below is
    # structurally anchored (a case arm alone on its line, a `for slug in` header,
    # a ConfigMap data key at exactly two spaces), so a slug merely NAMED in a
    # trailing comment cannot satisfy one.
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))

def gate_body(path):
    src = open(path, encoding="utf-8").read()
    m = re.search(r"^gate_optional_services\(\) \{\n(.*?)^\}$", src, re.S | re.M)
    return nocomment(m.group(1)) if m else None

loop, arms, nogate = set(), set(), []
for b in BUILDERS:
    body = gate_body(b)
    if body is None:
        nogate.append(b)
        continue
    for m in re.finditer(r"^\s*for slug in (.+?); do\s*$", body, re.M):
        loop |= set(m.group(1).split())
    for m in re.finditer(r"^\s*([A-Za-z0-9|_-]+)\)\s*$", body, re.M):
        arms |= set(m.group(1).split("|"))

cm = nocomment(open(CM, encoding="utf-8").read())
cm_keys = set(re.findall(r'^  ([A-Za-z0-9][A-Za-z0-9._-]*): "(?:true|false)"\s*$', cm, re.M))
a13 = nocomment(open(A13, encoding="utf-8").read())
a13_slugs = set(re.findall(r'^\s*-\s*\{\s*slug:\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*,', a13, re.M))
seed = nocomment(open(SEED, encoding="utf-8").read())
seed_slugs = set(re.findall(r'^\s*slug:\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*$', seed, re.M))

# The RENDER loops. These are the two sed/awk renderers that rewrite an EXISTING
# line in a shipped file — and a `sed -i -E "s#^(\s*)<slug>: ..."` over a file with
# no such line matches nothing, rewrites nothing, and exits 0. That is the exact
# mechanism of the headwind incident, so the loops are derived and each target is
# checked for a line the renderer could actually hit.
def render_loop(path, fn):
    src = open(path, encoding="utf-8").read()
    m = re.search(r"^%s\(\) \{\n(.*?)^\}$" % re.escape(fn), src, re.S | re.M)
    if not m:
        return set()
    body = nocomment(m.group(1))
    out = set()
    for mm in re.finditer(r"^\s*for slug in (.+?); do\s*$", body, re.M):
        out |= set(mm.group(1).split())
    return out

cm_render, cr_render = set(), set()
for b in BUILDERS:
    cm_render |= render_loop(b, "_opt_render_installed_services")
    cr_render |= render_loop(b, "_opt_render_optionalservice_cr")

# ── PER-BUILDER consumers. The sets above are a UNION over both builders, and a
# union is exactly what hid the defect this section exists to catch: anubis has a
# build-time consumer in build-rpi5-stage4.sh (_opt_render_installed_services
# renders its ConfigMap key + 13a element from _opt_anubis_installed) and NONE in
# build-x86-host-stage4.sh, so the union reports "gated" for a slug x86 drops on
# the floor. A slug validator must gate on ITS OWN builder's column.
#
# "This builder reads slug S out of the build-time selection" =
#   S has a gate_optional_services case arm here (loop AND arm), OR
#   S appears as a whole word inside this builder's _opt_render_installed_services
#   / _opt_render_optionalservice_cr body — which covers the loop slugs AND the
#   hand-written literal renders (rpi5's `anubis:` sed + _opt_render_appset_flag
#   anubis + _opt_set_cr_enabled ... anubis).
# The word boundary excludes '/' and '-' on both sides so a slug inside a PATH
# (manifests/coturn, manifests/optional-services-operator/...) is not mistaken for
# a consumer, and edge-ai does not match inside edge-ai-analysis.
SLUG_B = r"[A-Za-z0-9_./-]"
def fn_body(path, fn):
    m = re.search(r"^%s\(\) \{\n(.*?)^\}$" % re.escape(fn), open(path, encoding="utf-8").read(), re.S | re.M)
    return nocomment(m.group(1)) if m else ""

ALL_SLUGS = [s.strip() for s in open(REGSLUGS, encoding="utf-8").read().split()]
for b in BUILDERS:
    body = gate_body(b) or ""
    bloop, barms = set(), set()
    for m in re.finditer(r"^\s*for slug in (.+?); do\s*$", body, re.M):
        bloop |= set(m.group(1).split())
    for m in re.finditer(r"^\s*([A-Za-z0-9|_-]+)\)\s*$", body, re.M):
        barms |= set(m.group(1).split("|"))
    # Logger calls are dropped first. rpi5's renderer ends with
    #   info "... ConfigMap (selected: ${OPTIONAL_SERVICES:-none}; ENV=${ENV}; anubis=${val})"
    # and a bare token-in-prose test would count THAT as anubis's consumer — the
    # comment-token defect one layer in, inside a string instead of a comment.
    # Measured: without this strip, deleting every real anubis render from rpi5
    # left the suite green. A logger line is never a consumer, so remove the whole
    # statement rather than trying to tell prose from code inside it.
    ren = "\n".join(
        l for l in (fn_body(b, "_opt_render_installed_services") + "\n" + fn_body(b, "_opt_render_optionalservice_cr")).split("\n")
        if l.strip().split(" ")[0] not in ("info", "warn", "err", "echo", "printf", "log")
    )
    hon = set()
    for s in ALL_SLUGS:
        if s in (bloop & barms):
            hon.add(s)
        elif re.search(r"(?<!%s)%s(?!%s)" % (SLUG_B, re.escape(s), SLUG_B), ren):
            hon.add(s)
    tag = "RPI5" if "rpi5" in b.rsplit("/", 1)[-1] else "X86"
    print('CONS_HONOURS_%s="%s"' % (tag, " ".join(sorted(hon))))

def emit(n, v): print('%s="%s"' % (n, " ".join(sorted(v))))
emit("CONS_BUILD_ARM", loop & arms)   # BOTH: listed in the loop AND has a case arm
emit("CONS_CM_KEY", cm_keys)
emit("CONS_13A", a13_slugs)
emit("CONS_CM_RENDER", cm_render)
emit("CONS_CR_RENDER", cr_render)
emit("CONS_SEED_CR", seed_slugs)
emit("CONS_NOGATE_FN", [b.rsplit("/", 1)[-1] for b in nogate])
PY
# shellcheck source=/dev/null
. "${CONSDUMP}"

# The derivation must not come back empty — an empty consumer set would turn every
# "gate: none" assertion below into a vacuous PASS and silently invert this whole
# section's meaning.
[ -z "${CONS_NOGATE_FN//[[:space:]]/}" ] \
  || { echo "  CANNOT RUN: gate_optional_services() not found in: ${CONS_NOGATE_FN}" >&2; exit 2; }
[ -n "${CONS_BUILD_ARM//[[:space:]]/}" ] \
  || { echo "  CANNOT RUN: derived ZERO build-time gate arms — the extraction is broken" >&2; exit 2; }
[ -n "${CONS_CM_KEY//[[:space:]]/}" ] \
  || { echo "  CANNOT RUN: derived ZERO installed-services ConfigMap keys" >&2; exit 2; }
[ -n "${CONS_13A//[[:space:]]/}" ] \
  || { echo "  CANNOT RUN: derived ZERO 13a ApplicationSet elements" >&2; exit 2; }
ok "consumers derived from the shipped files: $(set -- ${CONS_BUILD_ARM}; echo $#) build-time arm(s), $(set -- ${CONS_CM_KEY}; echo $#) ConfigMap key(s), $(set -- ${CONS_13A}; echo $#) 13a element(s)"

_in() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── 6a) forward: every registry slug's declared gate: matches what exists ────
for slug in ${REG_SLUGS}; do
  _g=""
  _in "${slug}" "${REG_GATE_BUILD}"   && _g="build-time"
  _in "${slug}" "${REG_GATE_RUNTIME}" && _g="runtime"
  _in "${slug}" "${REG_GATE_NONE}"    && _g="none"
  case "${_g}" in
    build-time)
      if _in "${slug}" "${CONS_BUILD_ARM}"; then
        ok "${slug}: gate: build-time — a gate_optional_services case arm really exists"
      else
        bad "${slug}: registry says gate: build-time but NO builder has a gate_optional_services arm for it (this is the headwind shape: a row nothing reads)"
      fi
      ;;
    runtime)
      # runtime means "no bootstrap Application to prune, so there is deliberately
      # no build arm" — assert the ABSENCE too, or the value degrades into a
      # synonym for build-time and stops meaning anything.
      if _in "${slug}" "${CONS_BUILD_ARM}"; then
        bad "${slug}: registry says gate: runtime but a build-time gate arm EXISTS — one of the two is wrong"
      elif _in "${slug}" "${CONS_CM_KEY}" && _in "${slug}" "${CONS_13A}"; then
        ok "${slug}: gate: runtime — ConfigMap key + 13a element exist, no build arm (as declared)"
      else
        bad "${slug}: registry says gate: runtime but it is missing a ConfigMap key and/or a 13a element (ConfigMap=$(_in "${slug}" "${CONS_CM_KEY}" && echo yes || echo NO), 13a=$(_in "${slug}" "${CONS_13A}" && echo yes || echo NO))"
      fi
      ;;
    none)
      # `gate: none` is a claim that NOTHING reads this row. Verify the claim
      # rather than trusting it: a row that quietly acquired a consumer while
      # still declaring `none` would make the builders refuse a slug they can
      # actually honour.
      _found=""
      _in "${slug}" "${CONS_BUILD_ARM}" && _found="${_found} build-arm"
      _in "${slug}" "${CONS_CM_KEY}"    && _found="${_found} configmap-key"
      _in "${slug}" "${CONS_13A}"       && _found="${_found} 13a-element"
      if [ -z "${_found//[[:space:]]/}" ]; then
        ok "${slug}: gate: none — confirmed unread (no build arm, no ConfigMap key, no 13a element) and carries a written gateReason"
      else
        bad "${slug}: registry says gate: none but a consumer EXISTS —${_found}. Update the row's gate: instead of leaving the builders refusing a slug they can honour."
      fi
      ;;
    *)
      bad "${slug}: no recognised gate: value (schema check above should have caught this)"
      ;;
  esac
done
unset _g _found


# ── 6c) THE HEADWIND CHECK ITSELF: a renderer whose target line does not exist ─
# 6a asks "does this row have a consumer at all". This asks the narrower question
# that actually bit: given a slug the builders DO render, is there a line in the
# rendered file for the renderer to hit? Both renderers rewrite an EXISTING line:
#   _opt_render_installed_services  sed -i -E "s#^(\s*)<slug>: \"(true|false)\"#...#"
#   _opt_render_optionalservice_cr  awk, anchored on `slug: <slug>` then `enabled:`
# On a missing target line each one matches nothing, writes nothing and returns 0.
# `headwind` sat in BOTH builders' first loop with no `headwind:` key in the
# ConfigMap for exactly that reason, and every build reported success. The loops
# are DERIVED from the builders (comment-stripped) rather than restated here.
if [ -z "${CONS_CM_RENDER//[[:space:]]/}" ] || [ -z "${CONS_CR_RENDER//[[:space:]]/}" ]; then
  bad "could not derive the _opt_render_* slug loops from either builder (the headwind check would be vacuous)"
else
  _miss=""
  for _s in ${CONS_CM_RENDER}; do
    _in "${_s}" "${CONS_CM_KEY}" || _miss="${_miss} ${_s}"
  done
  if [ -z "${_miss//[[:space:]]/}" ]; then
    ok "every slug in _opt_render_installed_services' loop has a rewritable key in installed-services-configmap.yaml (the headwind no-op cannot recur)"
  else
    bad "THE HEADWIND DEFECT: slug(s) rendered by _opt_render_installed_services with NO matching ConfigMap key — the sed is a silent no-op for:${_miss}"
  fi
  _miss=""
  for _s in ${CONS_CR_RENDER}; do
    _in "${_s}" "${CONS_SEED_CR}" || _miss="${_miss} ${_s}"
  done
  if [ -z "${_miss//[[:space:]]/}" ]; then
    ok "every slug in _opt_render_optionalservice_cr's loop has a seed OptionalService CR to rewrite"
  else
    bad "same defect shape in the CR renderer: slug(s) rendered with no seed CR to rewrite —${_miss}"
  fi
  unset _miss _s
fi

# ── 6b) reverse: a CONSUMER with no registry row is the same defect, mirrored ─
# headwind was in the render loops with no ConfigMap key; the mirror image — a
# ConfigMap key, a 13a element or a gate arm for a slug NOBODY registered — is
# just as invisible, and this is the only check that would see it.
_orphans=""
for _c in ${CONS_BUILD_ARM} ${CONS_CM_KEY} ${CONS_13A}; do
  _in "${_c}" "${REG_SLUGS}" || case " ${_orphans} " in *" ${_c} "*) ;; *) _orphans="${_orphans} ${_c}" ;; esac
done
if [ -z "${_orphans//[[:space:]]/}" ]; then
  ok "no orphaned consumer: every gate arm / ConfigMap key / 13a element names a registered slug"
else
  bad "consumer(s) gating a slug that is NOT in the registry —${_orphans}"
fi
unset _orphans _c

# ── 6c) PER-BUILDER: what EACH builder honours vs. its registry buildGate column ─
# 6a/6b work off a set UNIONED over both builders, and that union is precisely
# what hid the defect the fail-closed validator was supposed to abolish: `gate:`
# says "something reads this row SOMEWHERE", which is not the question
# --optional-services asks. Three registered, non-`gate: none` slugs are honoured
# by build-x86-host-stage4.sh NOWHERE — coturn and meshbridge have no build-time
# consumer in EITHER builder (runtime-only: flip the ConfigMap key + 13a element
# on a live cluster), and anubis has one in rpi5 (_opt_anubis_installed) and none
# in x86. A validator gating on the union ACCEPTED all three and returned an
# affirmative signal for a flag nothing would honour.
# So each builder's consumer set is derived SEPARATELY above and asserted
# set-equal to that builder's registry `buildGate:` column here. Porting anubis to
# x86, or losing a case arm in one builder, is now a red test either way.
[ -n "${CONS_HONOURS_RPI5//[[:space:]]/}" ] && [ -n "${CONS_HONOURS_X86//[[:space:]]/}" ] \
  || { echo "  CANNOT RUN: per-builder consumer derivation came back EMPTY (rpi5='${CONS_HONOURS_RPI5}' x86='${CONS_HONOURS_X86}')" >&2; exit 2; }
if seteq "${CONS_HONOURS_RPI5}" "${REG_BUILDGATE_RPI5}"; then
  ok "rpi5: the slugs build-rpi5-stage4.sh reads out of the selection set-equal its registry buildGate: column ($(set -- ${CONS_HONOURS_RPI5}; echo $#))"
else
  bad "rpi5: honoured='${CONS_HONOURS_RPI5}' != registry buildGate:[rpi5]='${REG_BUILDGATE_RPI5}'"
fi
if seteq "${CONS_HONOURS_X86}" "${REG_BUILDGATE_X86}"; then
  ok "x86: the slugs build-x86-host-stage4.sh reads out of the selection set-equal its registry buildGate: column ($(set -- ${CONS_HONOURS_X86}; echo $#))"
else
  bad "x86: honoured='${CONS_HONOURS_X86}' != registry buildGate:[x86]='${REG_BUILDGATE_X86}'"
fi
# The gap itself, stated as an assertion rather than left as folklore: there ARE
# gated slugs x86 cannot honour, and they are exactly the ones its validator must
# refuse. If someone ports them, this flips to the empty case and says so.
RUNTIME_ONLY_X86=""
for _s in ${REG_GATED}; do
  _in "${_s}" "${REG_BUILDGATE_X86}" || RUNTIME_ONLY_X86="${RUNTIME_ONLY_X86} ${_s}"
done
unset _s
if [ -n "${RUNTIME_ONLY_X86//[[:space:]]/}" ]; then
  ok "x86: gated-but-not-bakeable slugs identified (must be REFUSED, not accepted):${RUNTIME_ONLY_X86}"
else
  ok "x86: every gated registry slug is in x86's buildGate: column — the runtime-only refusal leg is inapplicable"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 7) THE x86 BUILDER FAILS CLOSED ON AN UNKNOWN / UNGATED SLUG
# ═════════════════════════════════════════════════════════════════════════════
# WHAT WAS OBSERVED: --optional-services took any string. OPTIONAL_SERVICES is
# consumed only by _opt_selected() — a bare `[ "${s}" = "$1" ]` compare driven by
# gate_optional_services()' own slug loop — so a token that matches no arm is
# simply dropped. `--optional-services akoma` built an image with no Akkoma and
# said nothing. Its sibling knob MANAGED_SERVICES has failed closed on an unknown
# id since it shipped (validate_managed_services -> _mgd_die). This section pins
# the same posture on the optional-services path, BY EXECUTION: the real functions
# are extracted from the builder and run in a child bash, not grepped for.
echo "-- x86 builder: --optional-services / --exclude-services fail closed --"
x86_fn() { awk "/^$1\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}" "${BUILDER_X86}"; }
VALFILE="${WORK}/validate-optional-services.sh"
{
  echo "set -u"
  # The three mirrored constants, comment-stripped so a slug named in the long WHY
  # comment above them cannot end up in the list.
  grep -v '^[[:space:]]*#' "${BUILDER_X86}" | grep -E '^(KNOWN|GATED|SELECTABLE)_OPTIONAL_SERVICES='
  for _f in _opt_svc_die _opt_svc_known _opt_svc_gated _opt_svc_selectable validate_optional_services; do x86_fn "${_f}"; done
  echo ': "${OPTIONAL_SERVICES:=}"'
  echo ': "${EXCLUDE_SERVICES:=}"'
  echo 'validate_optional_services'
  echo 'echo VALIDATE_OK'
} > "${VALFILE}"
unset _f
for _f in KNOWN_OPTIONAL_SERVICES= GATED_OPTIONAL_SERVICES= SELECTABLE_OPTIONAL_SERVICES= \
          '_opt_svc_die()' '_opt_svc_known()' '_opt_svc_gated()' '_opt_svc_selectable()' 'validate_optional_services()'; do
  grep -F "${_f}" "${VALFILE}" >/dev/null \
    || { echo "  CANNOT RUN: could not extract '${_f}' from build-x86-host-stage4.sh" >&2; exit 2; }
done
unset _f
bash -n "${VALFILE}" || { echo "  CANNOT RUN: extracted validator does not parse" >&2; exit 2; }
ok "extracted the REAL validate_optional_services + its two slug constants from build-x86-host-stage4.sh"

# The constants are the builder's mirror of the registry (it cannot parse YAML at
# build time). Assert set-equality in BOTH directions so neither can rot.
X86_KNOWN="$(grep -v '^[[:space:]]*#' "${BUILDER_X86}" | sed -n 's/^KNOWN_OPTIONAL_SERVICES="\(.*\)"$/\1/p' | head -1)"
X86_GATED="$(grep -v '^[[:space:]]*#' "${BUILDER_X86}" | sed -n 's/^GATED_OPTIONAL_SERVICES="\(.*\)"$/\1/p' | head -1)"
if seteq "${X86_KNOWN}" "${REG_SLUGS}"; then
  ok "x86: KNOWN_OPTIONAL_SERVICES set-equals every registry slug"
else
  bad "x86: KNOWN_OPTIONAL_SERVICES='${X86_KNOWN}' != registry slugs='${REG_SLUGS}'"
fi
if seteq "${X86_GATED}" "${REG_GATED}"; then
  ok "x86: GATED_OPTIONAL_SERVICES set-equals the registry rows whose gate: is not none"
else
  bad "x86: GATED_OPTIONAL_SERVICES='${X86_GATED}' != registry gate!=none='${REG_GATED}'"
fi
# The constant the validator ACCEPTS on must be x86's own buildGate: column, not
# the gate!=none union — see 6c. Pinning it here is what keeps a re-widening back
# to ${GATED_OPTIONAL_SERVICES} from passing.
X86_SELECTABLE="$(grep -v '^[[:space:]]*#' "${BUILDER_X86}" | sed -n 's/^SELECTABLE_OPTIONAL_SERVICES="\(.*\)"$/\1/p' | head -1)"
if seteq "${X86_SELECTABLE}" "${REG_BUILDGATE_X86}"; then
  ok "x86: SELECTABLE_OPTIONAL_SERVICES set-equals the registry rows whose buildGate: lists x86"
else
  bad "x86: SELECTABLE_OPTIONAL_SERVICES='${X86_SELECTABLE}' != registry buildGate:[x86]='${REG_BUILDGATE_X86}'"
fi
# ...and while the registry still HAS gated-but-unbakeable rows (6c derives them),
# the two constants must not be equal — that equality is exactly the regression of
# gating on `gate: != none` again. Guarded on RUNTIME_ONLY_X86 so that porting
# every one of them to x86 makes this leg inapplicable rather than falsely red.
if [ -n "${RUNTIME_ONLY_X86//[[:space:]]/}" ]; then
  if seteq "${X86_SELECTABLE}" "${REG_GATED}"; then
    bad "x86: SELECTABLE_OPTIONAL_SERVICES has been widened back to the gate!=none union — that re-accepts${RUNTIME_ONLY_X86}, which this builder honours nowhere"
  else
    ok "x86: SELECTABLE_OPTIONAL_SERVICES is strictly narrower than the gate!=none union (it excludes${RUNTIME_ONLY_X86})"
  fi
else
  ok "x86: every gated registry slug is in x86's buildGate: column, so SELECTABLE == GATED is the correct state"
fi

# A validator nothing calls is the vacuity bug wearing a different hat, so pin the
# CALL as well as the definition — and its POSITION: it must run AFTER the `all`
# sentinel expands and AFTER the EXCLUDE_SERVICES block, or it would reject `all`
# and miss a typo folded in later. It must ALSO be DEFINED above the call: the
# call is a top-level statement, so definitions moved below it leave `bash -n`
# happy and make every invocation die rc=127 — and the extracted-validator legs
# further down structurally cannot see that, because re-assembling the function
# bodies into a scratch file re-orders them.
#
# ALL FOUR anchors are comment-stripped with the SAME `grep -vn` (which keeps the
# ORIGINAL line numbers while dropping full-line comments). Two of them used a
# plain `grep -n` until 2026-08-26, so prose naming the token satisfied the
# ordering check and the call could be moved above the `all` expansion with two
# decoy comment lines — measured green, builder dead rc=127. Comment-token
# inversion is the single defect shape this repo has shipped most often.
# Each anchor must also match EXACTLY ONE line: with `head -1` a second match
# (comment, copy-paste or a real second call site) silently picks the first and
# the check goes back to working by luck.
_nc="${WORK}/x86-nocomment.txt"
grep -vn '^[[:space:]]*#' "${BUILDER_X86}" > "${_nc}"
_anchor_lines() { sed -n "s/^\\([0-9]*\\):$1\$/\\1/p" "${_nc}"; }
_l_all="$(_anchor_lines '[[:space:]]*OPTIONAL_SERVICES="\${USER_LEVEL_SERVICES}"')"
_l_excl="$(_anchor_lines '.*EXCLUDE_SERVICES removed.*')"
_l_call="$(_anchor_lines 'validate_optional_services')"
_l_def="$(_anchor_lines 'validate_optional_services() {')"
# EXACTLY-ONE, checked OUTSIDE any command substitution: a bad() inside `$( )`
# runs in a subshell, so its FAIL line would be swallowed into the variable and
# the counter would never move — a green test reporting a failure to nobody.
_count_lines() { printf '%s\n' "$1" | grep -c '^[0-9][0-9]*$'; }
_amb=""
for _a in all:"${_l_all}" excl:"${_l_excl}" call:"${_l_call}" def:"${_l_def}"; do
  [ "$(_count_lines "${_a#*:}")" -eq 1 ] || _amb="${_amb} ${_a%%:*}=[$(printf '%s' "${_a#*:}" | tr '\n' ',')]"
done
unset _a
if [ -z "${_amb//[[:space:]]/}" ]; then
  ok "x86: each of the four ordering anchors matches EXACTLY ONE non-comment line (no head -1 coin flip)"
else
  bad "x86: ordering anchor(s) did not match exactly one non-comment line —${_amb}"
  _l_all=""; _l_excl=""; _l_call=""; _l_def=""
fi
unset _amb
if [ -n "${_l_call}" ] && [ -n "${_l_all}" ] && [ -n "${_l_excl}" ] && [ -n "${_l_def}" ] \
   && [ "${_l_all}" -lt "${_l_call}" ] && [ "${_l_excl}" -lt "${_l_call}" ]; then
  ok "x86: validate_optional_services is CALLED at top level, after the 'all' expansion and the EXCLUDE_SERVICES block"
else
  bad "x86: validate_optional_services call missing or mis-ordered (all=${_l_all:-none} exclude=${_l_excl:-none} call=${_l_call:-none})"
fi
if [ -n "${_l_def}" ] && [ -n "${_l_call}" ] && [ "${_l_def}" -lt "${_l_call}" ]; then
  ok "x86: validate_optional_services is DEFINED (line ${_l_def}) before it is CALLED (line ${_l_call})"
else
  bad "x86: validate_optional_services is defined AFTER its call site (def=${_l_def:-none} call=${_l_call:-none}) — bash -n parses, every run dies rc=127"
fi
unset _l_all _l_excl _l_call _l_def _nc

# ── THE REAL BUILDER, EXECUTED ───────────────────────────────────────────────
# Everything above this line is either a line-number check or a behaviour check
# against a RE-ASSEMBLED copy of the validator. Neither can see a defect in how
# the real file is ordered or wired — the reassembly is order-insensitive by
# construction, and three line numbers are not evidence that a 7000-line script
# runs. So run it.
#
# WHY THIS IS SAFE, AND CHEAP, AND CANNOT BUILD ANYTHING: every invocation below
# passes `--role bogus`. Role validation sits AFTER validate_optional_services and
# BEFORE the `[ "$(id -u)" -eq 0 ] || err "Run as root"` gate and before any
# emerge/chroot/loop-device work, so each run aborts in ~25 ms having touched
# nothing — at ANY privilege level, which matters because a leg that is safe only
# for an unprivileged runner would have to be skipped for a root one, and a
# skipped guard is the defect this suite is about.
# That also makes the "reached the role check" assertion load-bearing rather than
# decorative: it is positive proof the script got PAST the slug validator.
# The abort anchor. Pinned against the builder source FIRST: if it is reworded,
# every leg below would fail with a confusing message, so name the real cause once
# and up front rather than letting six legs blame the validator.
X86_ROLE_ERR="--role must be one of"
if grep -F -- "${X86_ROLE_ERR}" "${BUILDER_X86}" >/dev/null; then
  ok "x86: the post-validator abort anchor ('${X86_ROLE_ERR}') is still in the builder — the execution legs below can prove they got past validate_optional_services"
else
  bad "x86: role-validation message reworded — update X86_ROLE_ERR in this file; the execution legs below cannot tell 'reached role validation' from 'died earlier' without it"
fi
run_x86() {   # run_x86 <args...> -> X86_RC / X86_OUT
  # OPTIONAL_SERVICES/EXCLUDE_SERVICES are cleared from the CHILD's environment:
  # this file sets both as shell variables while exercising the rpi5 gate, and an
  # inherited value would silently redefine what "the built-in default selection"
  # leg below is actually measuring.
  X86_RC=0
  X86_OUT="$(env -u OPTIONAL_SERVICES -u EXCLUDE_SERVICES timeout 60 bash "${BUILDER_X86}" "$@" 2>&1)" || X86_RC=$?
}
_has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# (1) the real script REFUSES a typo, from argv, at the top level.
run_x86 --optional-services akoma --role bogus
if [ "${X86_RC}" -ne 0 ] && _has 'FATAL(optional-services)' "${X86_OUT}" \
   && ! _has "${X86_ROLE_ERR}" "${X86_OUT}"; then
  ok "REAL build-x86-host-stage4.sh: '--optional-services akoma' aborts (rc=${X86_RC}) with FATAL(optional-services), before role validation"
else
  bad "REAL build-x86-host-stage4.sh: '--optional-services akoma' did not abort at the slug validator (rc=${X86_RC}): ${X86_OUT}"
fi

# (2) the WIRING leg, and the one that catches definition-after-use: a VALID
# invocation must get PAST the validator with no 'command not found' and reach
# role validation. Moving the four function definitions below the call keeps
# `bash -n` green and every extracted-validator leg green; this goes red.
run_x86 --all-services --role bogus
if ! _has 'command not found' "${X86_OUT}" && ! _has 'FATAL(optional-services)' "${X86_OUT}" \
   && _has "${X86_ROLE_ERR}" "${X86_OUT}"; then
  ok "REAL build-x86-host-stage4.sh: '--all-services' runs THROUGH validate_optional_services (no 'command not found', no FATAL) and reaches role validation"
else
  bad "REAL build-x86-host-stage4.sh: '--all-services' did not run cleanly through the validator (rc=${X86_RC}): ${X86_OUT}"
fi

# (3) same for the built-in default selection — `all` is one code path, no
# selection at all is the other, and the default list is what most builds use.
run_x86 --role bogus
if ! _has 'command not found' "${X86_OUT}" && ! _has 'FATAL(optional-services)' "${X86_OUT}" \
   && _has "${X86_ROLE_ERR}" "${X86_OUT}"; then
  ok "REAL build-x86-host-stage4.sh: the DEFAULT selection (no --optional-services) runs through the validator and reaches role validation"
else
  bad "REAL build-x86-host-stage4.sh: the default selection did not run cleanly through the validator (rc=${X86_RC}): ${X86_OUT}"
fi

# (4) EXCLUDE_SERVICES is validated by the same call, from argv, for real.
run_x86 --optional-services akkoma --exclude-services phpb --role bogus
if [ "${X86_RC}" -ne 0 ] && _has "unknown optional-service slug 'phpb'" "${X86_OUT}"; then
  ok "REAL build-x86-host-stage4.sh: '--exclude-services phpb' aborts with the unknown-slug FATAL naming 'phpb'"
else
  bad "REAL build-x86-host-stage4.sh: a typo in --exclude-services was not refused (rc=${X86_RC}): ${X86_OUT}"
fi

# (5) the runtime-only refusal, on the real script, for every gated slug x86's
# buildGate: column does not claim. Derived, so porting one to x86 moves it out
# of this loop instead of leaving a stale name here.
if [ -n "${RUNTIME_ONLY_X86//[[:space:]]/}" ]; then
  for _n in ${RUNTIME_ONLY_X86}; do
    run_x86 --optional-services "${_n}" --role bogus
    if [ "${X86_RC}" -ne 0 ] && _has "RUNTIME-ONLY on this builder" "${X86_OUT}" && _has "'${_n}'" "${X86_OUT}"; then
      ok "REAL build-x86-host-stage4.sh: REFUSES '${_n}' as runtime-only instead of accepting a flag it honours nowhere"
    else
      bad "REAL build-x86-host-stage4.sh: '${_n}' was ACCEPTED (rc=${X86_RC}) — gated somewhere, baked by nothing here: ${X86_OUT}"
    fi
  done
  unset _n
fi

# (6) the rpi5-only deselect spelling, refused here with a pointer to the knob
# that does work. See the rpi5-side legs at the end of this section for proof
# that the spelling is genuinely honoured THERE.
run_x86 --optional-services "akkoma -games" --role bogus
if [ "${X86_RC}" -ne 0 ] && _has "rpi5-only spelling" "${X86_OUT}" && _has "--exclude-services 'games'" "${X86_OUT}"; then
  ok "REAL build-x86-host-stage4.sh: REFUSES the rpi5-only '-<slug>' spelling and names --exclude-services as the x86 knob"
else
  bad "REAL build-x86-host-stage4.sh: '-games' was not refused with the rpi5-only message (rc=${X86_RC}): ${X86_OUT}"
fi

# ── the behavioural legs: run the real validator ─────────────────────────────
VAL_OUT=""; VAL_RC=0
run_val() {   # run_val "<OPTIONAL_SERVICES>" "<EXCLUDE_SERVICES>"
  VAL_RC=0
  VAL_OUT="$(OPTIONAL_SERVICES="$1" EXCLUDE_SERVICES="$2" bash "${VALFILE}" 2>&1)" || VAL_RC=$?
}
val_accepts() {  # val_accepts OPT EXCL LABEL
  run_val "$1" "$2"
  case "${VAL_OUT}" in
    *VALIDATE_OK*) [ "${VAL_RC}" -eq 0 ] && ok "$3" || bad "$3 (printed OK but exited ${VAL_RC})" ;;
    *) bad "$3 — REJECTED (rc=${VAL_RC}): ${VAL_OUT}" ;;
  esac
}
val_refuses() {  # val_refuses OPT EXCL NEEDLE LABEL
  run_val "$1" "$2"
  if [ "${VAL_RC}" -eq 0 ]; then
    bad "$4 — was ACCEPTED (the silent-ignore bug is back)"
  elif case "${VAL_OUT}" in *"$3"*) false ;; *) true ;; esac; then
    bad "$4 — refused (rc=${VAL_RC}) but the message never says '$3': ${VAL_OUT}"
  else
    ok "$4"
  fi
}

val_accepts "${DEFAULT_ON}" "" "accepts the built-in default selection (${DEFAULT_ON})"
val_accepts "${REG_BUILDGATE_X86}" "" "accepts EVERY slug x86's buildGate: column claims, at once"
val_accepts "" "" "accepts an EXPLICITLY EMPTY selection (--optional-services \"\")"
val_accepts "akkoma" "games,owncast" "accepts the comma spelling of EXCLUDE_SERVICES"

val_refuses "akkoma akoma phpbb" "" "unknown optional-service slug" \
  "REFUSES a typo'd slug ('akoma') instead of silently building without Akkoma"
val_refuses "akkoma" "phpb" "unknown optional-service slug" \
  "REFUSES a typo in EXCLUDE_SERVICES ('phpb') instead of shipping the service the operator asked to remove"
# Substring safety: the membership test is an exact-token compare, so a PREFIX of
# a real slug must not sneak through (a `case " $list " in *"$tok"*)` glob would
# have let 'edge-ai' match inside 'edge-ai-analysis', and 'edge-a' inside both).
val_refuses "edge-a" "" "unknown optional-service slug" \
  "REFUSES a PREFIX of a real slug ('edge-a') — membership is an exact-token compare"

# ── the '-<slug>' / 'no-<slug>' deselect spelling is RPI5-ONLY, and refused here ─
# This suite used to PIN the opposite ("accepts the '-<slug>' explicit-deselect
# spelling") — and that pin was wrong, which made the mistake load-bearing. The
# spelling is implemented by _opt_explicitly_deselected(), which is DEFINED IN
# build-rpi5-stage4.sh AND HAS NO DEFINITION AND NO CALLER IN build-x86-host-stage4.sh
# (asserted below, so this is not folklore either). On x86 the token therefore
# matched no arm and did nothing — a brand-new silently-inert flag minted by the
# very change that was meant to abolish them, and worse than inert under the `all`
# sentinel, which replaces the whole token list so `all -games` ships games.
for _spell in "-games" "no-games" "-anubis" "no-anubis"; do
  val_refuses "akkoma ${_spell}" "" "rpi5-only spelling" \
    "REFUSES the rpi5-only deselect spelling '${_spell}' on x86 instead of accepting an inert token"
done
unset _spell
val_refuses "akkoma" "-games" "rpi5-only spelling" \
  "REFUSES the deselect spelling inside EXCLUDE_SERVICES too (double-negative, honoured by nothing)"
val_refuses "-akoma" "" "rpi5-only spelling" \
  "REFUSES the deselect spelling even when the base slug is itself a typo"

# ── the RUNTIME-ONLY refusal: gated somewhere, bakeable here by nothing ────────
# The three slugs (coturn/meshbridge/anubis) that `gate: != none` accepted and
# this builder honours nowhere. Driven off RUNTIME_ONLY_X86 (derived in 6c), so
# porting one to x86 removes its leg instead of leaving a stale name here.
if [ -n "${RUNTIME_ONLY_X86//[[:space:]]/}" ]; then
  for _n in ${RUNTIME_ONLY_X86}; do
    val_refuses "${_n}" "" "RUNTIME-ONLY on this builder" \
      "REFUSES '${_n}' — registered and gated at RUNTIME, but nothing in build-x86-host-stage4.sh reads it from the selection"
    val_refuses "akkoma" "${_n}" "RUNTIME-ONLY on this builder" \
      "REFUSES '${_n}' in EXCLUDE_SERVICES too — excluding what was never bakeable is the same empty promise"
  done
  unset _n
else
  ok "no gated-but-unbakeable slugs on x86 — the runtime-only refusal leg is inapplicable"
fi

# The registered-but-ungated leg: this is the whole reason unit A3's new infra
# rows may not be quietly accepted. Driven off the registry, so it exercises
# whatever is currently `gate: none` rather than a name baked into this file.
if [ -n "${REG_GATE_NONE//[[:space:]]/}" ]; then
  for _n in ${REG_GATE_NONE}; do
    val_refuses "${_n}" "" "not GATED ANYWHERE" \
      "REFUSES '${_n}' — registered with gate: none, so selecting it would gate nothing"
  done
  unset _n
else
  # Not a skip: if every row is gated this leg is genuinely inapplicable, and the
  # forward check in 6a already proves the gates exist. Say so out loud.
  ok "no gate: none rows in the registry — the registered-but-ungated leg is inapplicable (every row has a consumer)"
fi

# ── 7b) the deselect spelling REALLY IS rpi5-only, and really works THERE ─────
# The x86 refusal message says "_opt_explicitly_deselected exists in
# build-rpi5-stage4.sh; this builder has no definition and no caller for it". A
# message asserting a fact about another file is only as good as a check on that
# fact, so check both halves — and then exercise the rpi5 function so the
# spelling is pinned where it is implemented rather than where it is not. The
# rpi5 helpers are already sourced into this shell at the top of this file.
echo "-- the '-<slug>' deselect spelling is implemented in rpi5, absent in x86 --"
# Comment-stripped AND string-literal-stripped: the x86 FATAL message NAMES
# _opt_explicitly_deselected (it tells the operator where the spelling lives), and
# counting that mention as a reference would invert this check — the same
# comment-token shape, one layer in. `sed 's/"[^"]*"//g'` is not a shell parser,
# but every occurrence in both files is either a bare statement or a single
# double-quoted message on one line, so it separates "code that calls it" from
# "prose that names it" exactly where it matters.
_decode() { grep -v '^[[:space:]]*#' "$1" | sed 's/"[^"]*"//g'; }
_x86_nc="${WORK}/x86-nc-fn.txt"
_decode "${BUILDER_X86}" > "${_x86_nc}"
_rpi5_nc="${WORK}/rpi5-nc-fn.txt"
_decode "${BUILDER}" > "${_rpi5_nc}"
for _fn in _opt_explicitly_deselected _opt_anubis_installed; do
  _n_r="$(grep -c "${_fn}" "${_rpi5_nc}")"
  _n_x="$(grep -c "${_fn}" "${_x86_nc}")"
  if [ "${_n_r}" -gt 0 ] && [ "${_n_x}" -eq 0 ]; then
    ok "${_fn}: ${_n_r} non-comment reference(s) in build-rpi5-stage4.sh, ZERO in build-x86-host-stage4.sh — the x86 refusal message states the truth"
  else
    bad "${_fn}: rpi5=${_n_r} x86=${_n_x} — the x86 fail-closed message and the buildGate: column both assume rpi5-only; one of them is now wrong"
  fi
done
unset _fn _n_r _n_x _x86_nc _rpi5_nc; unset -f _decode
if command -v _opt_explicitly_deselected >/dev/null 2>&1; then
  OPTIONAL_SERVICES="akkoma -anubis"
  _opt_explicitly_deselected anubis \
    && ok "rpi5 _opt_explicitly_deselected: '-anubis' IS honoured there (the spelling has a real consumer, on the other builder)" \
    || bad "rpi5 _opt_explicitly_deselected: '-anubis' not recognised — then the spelling is inert on BOTH builders"
  OPTIONAL_SERVICES="akkoma no-anubis"
  _opt_explicitly_deselected anubis \
    && ok "rpi5 _opt_explicitly_deselected: 'no-anubis' IS honoured there" \
    || bad "rpi5 _opt_explicitly_deselected: 'no-anubis' not recognised"
  OPTIONAL_SERVICES="akkoma anubis"
  if _opt_explicitly_deselected anubis; then
    bad "rpi5 _opt_explicitly_deselected: a POSITIVE 'anubis' was read as a deselection"
  else
    ok "rpi5 _opt_explicitly_deselected: a positive 'anubis' is NOT a deselection (the negative token only suppresses an implicit default)"
  fi
  OPTIONAL_SERVICES=""
else
  bad "rpi5 _opt_explicitly_deselected was not sourced — cannot prove the deselect spelling works anywhere"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
