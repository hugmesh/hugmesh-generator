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
# 13a NOTE (2026-08-26): a SELECTED slug's 13a element is asserted to STAY
# installed:"false" while its hardcoded apps/30-*/50-* Application exists — see
# the long comment at that assertion in section 3. Selection is proven by the
# surviving Application + the ConfigMap boolean, not by a 13a flip.
#
# WHAT THIS PROVES (WITHOUT a full cross-build) by loading the REAL helper + gate
# functions AS build-rpi5-stage4.sh RESOLVES THEM and running them against a
# realistic sandbox baked tree (seeded from the live specs/cluster files):
#   * every user-level slug is REGISTERED in optional-services.yaml;
#   * for EACH slug: EXCLUDED => its owned apps/*.yaml + manifests/<dir> are gone,
#     its gateway routes + route-access rows are gone, the ConfigMap boolean is
#     "false", and the 13a ApplicationSet element is installed:"false";
#   * INCLUDED => app present, manifests present, ConfigMap "true", and 13a HELD
#     at "false" (the pre-cut-over no-double-management rule);
#   * the EXCLUDE_SERVICES subtractive knob removes a slug from a full positive
#     selection (force-OFF regardless of how it was selected);
#   * the DEFAULT-INCLUSION POLICY (user 2026-06-17): a DEFAULT build (no
#     OPTIONAL_SERVICES) renders akkoma+tuwunel+phpbb and PRUNES games+owncast+tube;
#     OPTIONAL_SERVICES=all renders everything; a default-off slug is included when
#     explicitly added; EXCLUDE_SERVICES removes a default-ON slug. games is now
#     DEFAULT-OFF (registry default: off + ConfigMap baseline "false").
#
# WHERE THE GATE LIVES (changed 2026-08-26). gate_optional_services() and every
# _opt_* helper moved into the SHARED scripts/_optional-services-lib.sh, which BOTH
# stage4 builders source. tests/lib/opt-gate-source.sh walks a given builder's own
# source chain and takes the LAST definition, exactly as bash would, so this suite
# still executes whatever that builder would actually run.
#
# WHAT SECTION 4c IS FOR NOW, AND WHAT IT USED TO BE. 4c used to grep
# build-x86-host-stage4.sh for the selection KNOBS and diff one case body. That was
# green while THREE real divergences shipped in x86 images: no
# _opt_render_appset_flag at all (so a deselected slug stayed installed:"true" in
# the 13a ApplicationSet and a repo-synced ArgoCD re-forced it on), no anubis
# handling at all (so --env prod shipped the public PoW shield off and the
# fe-gateway ingress un-rerouted), and the edge-ai-analysis dependsOn guard running
# BEFORE EXCLUDE_SERVICES (so --exclude-services edge-ai shipped the orphan
# wrapper). Replacing those knob greps with FUNCTION-NAME greps would not have
# caught any of the three — a name is satisfied by a comment, and says nothing
# about the body. Measured: a name-grep parity suite stays GREEN against all three
# defects reproduced verbatim. So 4c now asserts only the STRUCTURAL half — one
# shared gate, sourced by both, no local override, byte-identical resolution — and
# tests/stack/test-optional-services-parity.sh asserts the BEHAVIOURAL half on the
# rendered artefacts.
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

# ── Load the REAL gate + helpers AS THE BUILDER RESOLVES THEM ────────────────
# They live in the SHARED scripts/_optional-services-lib.sh since 2026-08-26; the
# loader walks the builder's own source chain (libs first, builder last, last
# definition winning) so a re-added builder-local override is still what runs here.
#
# _opt_set_cr_enabled / _opt_render_optionalservice_cr are in this list now and were
# NOT before: gate_optional_services calls _opt_render_optionalservice_cr at its very
# last line, so every gate run in this file was printing
#     _opt_render_optionalservice_cr: command not found
# to stderr and carrying on. `set -uo pipefail` does not stop that (no set -e), so
# 164 assertions passed while the OptionalService CR seed — the runtime desired-state
# twin of the ConfigMap boolean — was never exercised at all.
source "${REPO}/tests/lib/opt-gate-source.sh"
opt_gate_load "${BUILDER}" _opt_selected _opt_explicitly_deselected _opt_anubis_installed \
          _opt_drop_kustomize_line _opt_drop_route _opt_drop_extrahost _opt_drop_rows \
          _opt_fix_trailing_comma _opt_wire_anubis_ingress \
          _opt_appset_element_path _opt_appset_cutover_done _opt_render_appset_flag \
          _opt_render_installed_services _opt_set_cr_enabled _opt_render_optionalservice_cr \
          _opt_federation_module _opt_gate_sql_value _opt_render_federation_modules \
          gate_optional_services || exit 1
ok "loaded the real gate + helper functions as build-rpi5-stage4.sh resolves them"
# _opt_render_optionalservice_cr + _opt_render_federation_modules are loaded too,
# not because THIS suite asserts on them (their own gates do — tests/federation/
# test-federation-modules-selection.sh for the federation half), but because
# gate_optional_services CALLS them: without the definitions every run printed
# "command not found" to stderr while still reporting 0 failed, which is the exact
# shape of a suite that looks gateable and is quietly running less code than it
# claims. Both return 0 immediately when their artefact is absent from this
# sandbox tree, so the assertions below are unchanged.

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
           "${tree}/manifests/route-access/initdb" "${tree}/manifests/policy" \
           "${tree}/manifests/optional-services-operator"
  # The OptionalService CR seed. It was NOT seeded before, so
  # _opt_render_optionalservice_cr returned at its `[ -f "${seed}" ] || return 0`
  # line on every single gate run in this file: loading the function silenced a
  # "command not found" on stderr and added ZERO coverage. MEASURED (2026-08-26,
  # adversarial review): stubbing the whole function to `return 0` left this suite
  # at 165/0 and the parity suite at 71/0. §6 below now asserts the rendered
  # `enabled:` values ABSOLUTELY.
  cp "${SRC}/manifests/optional-services-operator/seed-optionalservices.yaml" \
     "${tree}/manifests/optional-services-operator/"
  # The per-slug owned apps + manifest dirs (copy the real ones so the gate's
  # rm -f / rm -rf hit the actual filenames).
  cp "${SRC}/apps/13a-optional-services.yaml" "${tree}/apps/"
  cp "${SRC}/manifests/policy/installed-services-configmap.yaml" "${tree}/manifests/policy/"
  # The OptionalService seed CRs. Without this file _opt_render_optionalservice_cr
  # hits its `[ -f ... ] || return 0` and no-ops at rc 0 -- which is exactly how the
  # CR leg went unexercised: the renderer was never extracted (so it died as
  # `command not found`, swallowed), and even extracted it would have returned
  # immediately because nothing seeded this path.
  mkdir -p "${tree}/manifests/optional-services-operator"
  cp "${SRC}/manifests/optional-services-operator/seed-optionalservices.yaml" \
     "${tree}/manifests/optional-services-operator/"
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
    # Sweep the gate AS THAT BUILDER RESOLVES IT (shared lib since 2026-08-26),
    # not the builder file — which no longer contains a single _opt_drop_rows call
    # and would make this sweep report ZERO parsed calls, i.e. vacuous.
    opt_gate_extract_fn "${_b}" gate_optional_services > "${WORK}/gate-$(basename "${_b}").sh"
    # The sweep itself lives in tests/scripts/route_access_coverage.py — it was an
    # inline heredoc here until 2026-08-27, reading the RAW .sql with a TWO-column
    # regex that parsed COMMENT PROSE as rows (99 paths, one literally named
    # `pattern`, harvested from the row-shape example at 20-schema.sql:863) and
    # counted the four allow=false DENY rows as GRANTS. Comment-stripped and read
    # 4-column, the same scan sees 94 granted + 4 deny. The extracted module also
    # carries two VACUITY GUARDS (rc 3 / rc 4) so a sweep that strips nothing or
    # matches nothing can no longer report "clean". Guarded on its own by
    # tests/scripts/test-route-access-coverage-scanner.sh.
    python3 "${REPO}/tests/scripts/route_access_coverage.py" \
        "${WORK}/gate-$(basename "${_b}").sh" \
        "${REPO}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
    _rc=$?
    _bn="${_b##*/}"
    case "${_rc}" in
      0) ok "${_bn}: every dropped path is cleaned on every gateway that grants it" ;;
      2) bad "${_bn}: the coverage sweep parsed ZERO _opt_drop_rows calls — vacuous, not clean" ;;
      3) bad "${_bn}: the sweep's SQL comment stripper removed NOTHING — comment prose would be parsed as live rows" ;;
      4) bad "${_bn}: the sweep's row regex matched ZERO rows — it would report clean after grading nothing" ;;
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
# ── NON-VACUITY CANARY (added 2026-08-26 after review) ───────────────────────
# The INCLUDED 13a assertion below was INVERTED from installed:"true" to
# installed:"false" when the double-management guard landed. Every element in
# specs/cluster/apps/13a-optional-services.yaml ALREADY ships installed:"false",
# so on the pristine fixture the inverted assertion was satisfied by a file
# NOBODY TOUCHED: stubbing _opt_render_appset_flag() to `return 0` — deleting the
# renderer outright — still gave 164 passed, 0 failed. The "held false" invariant
# is right, but it has to PROVE THE RENDERER RAN, not just observe the scaffold.
# So flip every selected slug's element to "true" FIRST. The gate must rewrite it
# back to "false"; a renderer that stops running leaves the canary at "true" and
# the assertion below goes red.
for slug in ${USER_SERVICES}; do
  sed -i -E "s#(\{[[:space:]]*slug:[[:space:]]*${slug}[[:space:]]*,.*installed:[[:space:]]*\")(true|false)(\")#\1true\3#" \
      "${TREE}/apps/13a-optional-services.yaml"
done
_canary_n=$(grep -cE '\{[[:space:]]*slug:.*installed:[[:space:]]*"true"' "${TREE}/apps/13a-optional-services.yaml" || true)
if [ "${_canary_n}" -ge 4 ]; then
  ok "13a canary armed: ${_canary_n} element(s) pre-set installed:\"true\" before gating (so 'held false' below proves the renderer RAN)"
else
  bad "13a canary FAILED TO ARM (${_canary_n} elements set true) — every 'held false' assertion below would be vacuous"
fi
OPTIONAL_SERVICES="${USER_SERVICES}"
gate_optional_services
for slug in ${USER_SERVICES}; do
  app="${OWNED_APP[$slug]}"; dir="${OWNED_DIR[$slug]}"
  [ -f "${TREE}/apps/${app}" ]      && ok "${slug}: owned Application ${app} PRESENT" || bad "${slug}: ${app} pruned despite selection"
  [ -d "${TREE}/manifests/${dir}" ] && ok "${slug}: manifests/${dir} PRESENT"         || bad "${slug}: manifests/${dir} pruned despite selection"
  grep -qE "^[[:space:]]*${slug}:[[:space:]]*\"true\"" "${TREE}/manifests/policy/installed-services-configmap.yaml" \
      && ok "${slug}: ConfigMap installed (true)" || bad "${slug}: ConfigMap not true despite selection"
  # 13a stays installed:"false" for a SELECTED slug while its hardcoded
  # apps/30-*/50-* Application still exists — CHANGED 2026-08-26, and the change
  # is the point, not a relaxation. 13a-optional-services.yaml's own header says
  # "keep every element installed:false" until the cut-over, and
  # docs/OPTIONAL-SERVICES.md forbids two owners of one manifest directory: the
  # generated `optional-<slug>` Application and the hardcoded `<slug>` one would
  # BOTH carry automated{prune,selfHeal} over specs/cluster/manifests/<dir>.
  # That flip was harmless only because bootstrap.sh never applied the baked tree
  # at all (it synced specs/cluster/apps from GitHub); now that
  # specs/cluster/bootstrap/bootstrap.sh applies the BAKED tree, the flip is
  # REACHABLE and the double management is real. _opt_appset_cutover_done() in
  # build-rpi5-stage4.sh is the guard, and it is self-maintaining: delete
  # apps/30-<slug>.yaml in a real cut-over and the element starts flipping true
  # again with no edit here. The INSTALL signal for a selected slug is the
  # ConfigMap boolean asserted immediately above plus the surviving Application.
  grep -qE "\{[[:space:]]*slug:[[:space:]]*${slug}[[:space:]]*,.*installed:[[:space:]]*\"false\"" "${TREE}/apps/13a-optional-services.yaml" \
      && ok "${slug}: 13a element held installed:\"false\" (hardcoded ${app} still owns manifests/${dir}; no double management)" \
      || bad "${slug}: 13a element flipped true while ${app} still exists — DOUBLE MANAGEMENT of manifests/${dir}"
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

# ── 4c) x86 builder parity ────────────────────────────────────────────────────
# WHAT THIS BLOCK USED TO BE, AND WHY IT FAILED (2026-08-26).
# It grepped build-x86-host-stage4.sh for the selection KNOBS (built-in default,
# USER_LEVEL_SERVICES, --all-services, --exclude-services, the `all` expansion,
# EXCLUDE_SERVICES) and diffed the two builders' `games)` case bodies for a list
# of prune markers. All of that was green while THREE real divergences shipped in
# x86 images, because none of them lived in a knob or in the games) case:
#   1. x86 had NO _opt_render_appset_flag at all, so a deselected slug's
#      apps/13a-optional-services.yaml element stayed installed:"true" and a
#      repo-synced ArgoCD re-forced the service on;
#   2. x86 had NO anubis handling at all, so an --env prod image shipped the
#      public PoW shield off and the fe-gateway ingress un-rerouted;
#   3. x86 ran the edge-ai-analysis dependsOn guard BEFORE EXCLUDE_SERVICES, so
#      --exclude-services edge-ai shipped the orphan analysis wrapper.
# A parity test that greps for a FUNCTION NAME would not have caught any of them
# either: a name is satisfied by a comment, and by a present-but-wrong body.
#
# The knob greps are gone from here. tests/stack/test-optional-services-parity.sh
# now asserts the three post-conditions ON THE RENDERED ARTEFACT, per builder,
# through each builder's own source-chain resolution. What remains here is the
# STRUCTURAL half that the parity suite cannot state as a post-condition: both
# builders must resolve their gate to the SAME file, so there is no second copy
# to drift, and the shared file must actually be sourced by both.
echo "-- x86 builder parity (structural: ONE gate, resolved from both builders) --"
if [ -f "${BUILDER_X86}" ]; then
  OPTLIB="${REPO}/scripts/_optional-services-lib.sh"
  [ -f "${OPTLIB}" ] && ok "the shared optional-service gate library exists" \
                     || bad "scripts/_optional-services-lib.sh missing"
  # Both builders must SOURCE it (comment-stripped: prose naming the path is not a source).
  for _b in "${BUILDER}" "${BUILDER_X86}"; do
    sed -e 's/#.*$//' "${_b}" | grep -E '^[[:space:]]*source[[:space:]]+"\$\{SCRIPT_DIR\}/scripts/_optional-services-lib\.sh"' >/dev/null \
      && ok "$(basename "${_b}"): sources the shared optional-service gate library" \
      || bad "$(basename "${_b}"): does NOT source scripts/_optional-services-lib.sh"
  done
  # And neither may carry a LOCAL redefinition of any gate function: a local copy
  # is defined AFTER the source line, so bash would run it, and the drift is back.
  #
  # EVERY BASH SPELLING, NOT JUST `name() {` AT COLUMN 1. The first version of this
  # check anchored on `^(gate_optional_services|_opt_[a-z_]+)\(\)`. MEASURED
  # (2026-08-26, adversarial review): a builder-local override written as
  # `_opt_render_appset_flag ()  {`, as `function _opt_render_appset_flag {`, or
  # indented, is run by bash and was invisible here AND to the resolver — all seven
  # suites stayed green with D1 reproduced verbatim. The ERE below takes
  #     NAME()   NAME ()   function NAME   function NAME()   …indented,
  # which is the full set bash accepts.
  for _b in "${BUILDER}" "${BUILDER_X86}"; do
    _dupes="$(sed -e 's/#.*$//' "${_b}" \
      | grep -oE '^[[:space:]]*(function[[:space:]]+(gate_optional_services|_opt_[a-z_]+)[[:space:]]*(\([[:space:]]*\))?[[:space:]]*\{|(gate_optional_services|_opt_[a-z_]+)[[:space:]]*\([[:space:]]*\))' \
      | grep -oE '(gate_optional_services|_opt_[a-z_]+)' | sort -u | tr '\n' ' ')"
    [ -z "${_dupes// /}" ] && ok "$(basename "${_b}"): defines NO local copy of any gate function" \
      || bad "$(basename "${_b}"): re-defines gate function(s) locally, overriding the shared lib: ${_dupes}"
  done
  # Every gate function must resolve IDENTICALLY from both builders. This is the
  # assertion the old games)-case diff was reaching for, generalised to the whole
  # gate instead of one arm, and it is byte-exact rather than marker-sampled.
  _fns="gate_optional_services _opt_selected _opt_explicitly_deselected _opt_anubis_installed
        _opt_render_appset_flag _opt_render_installed_services _opt_wire_anubis_ingress
        _opt_set_cr_enabled _opt_render_optionalservice_cr _opt_fix_trailing_comma
        _opt_drop_kustomize_line _opt_drop_route _opt_drop_extrahost _opt_drop_rows"
  _div=""; _absent=""
  for _fn in ${_fns}; do
    _a="$(opt_gate_extract_fn "${BUILDER}"     "${_fn}")"
    _x="$(opt_gate_extract_fn "${BUILDER_X86}" "${_fn}")"
    if [ -z "${_a}" ] || [ -z "${_x}" ]; then _absent="${_absent} ${_fn}"
    elif [ "${_a}" != "${_x}" ];            then _div="${_div} ${_fn}"; fi
  done
  [ -z "${_absent// /}" ] && ok "all 14 gate functions resolve from BOTH builders (none absent on either)" \
    || bad "gate function(s) absent from a builder's source chain:${_absent}"
  [ -z "${_div// /}" ] && ok "all 14 gate functions resolve BYTE-IDENTICALLY from both builders" \
    || bad "gate function(s) DIVERGE between the builders:${_div}"
  bash -n "${BUILDER_X86}" && ok "build-x86-host-stage4.sh: bash -n clean" || bad "x86 builder failed bash -n"
  bash -n "${OPTLIB}"      && ok "scripts/_optional-services-lib.sh: bash -n clean" || bad "shared gate lib failed bash -n"

  # ── games-instances (app-store control-plane) prune parity ─────────────────
  # The games) case must ALSO prune the games-instances/games-services control
  # plane (13c ApplicationSet, manifests/games-instances, the two casdoor sync
  # Jobs, the games-servers-console route, and the games-services route-access
  # rows) when games itself is deselected — that control plane rides the games
  # slug and cannot be left orphaned. Resolved per builder, so a builder-local
  # override of the case would be what is checked.
  RPI5_GAMES_CASE="$(opt_gate_case_body "${BUILDER}" games)"
  X86_GAMES_CASE="$(opt_gate_case_body "${BUILDER_X86}" games)"
  [ -n "${RPI5_GAMES_CASE}" ] && ok "resolved rpi5 games) case body" || bad "could not resolve rpi5 games) case body"
  [ -n "${X86_GAMES_CASE}" ] && ok "resolved x86 games) case body" || bad "could not resolve x86 games) case body"
  for marker in '13c-games-instances.yaml' 'manifests/games-instances' \
                'games-services-admin-sync-job.yaml' 'games-services-runner-sync-job.yaml' \
                'games-servers-console' 'games-services/instances' 'admin/games-services'; do
    rpi5_has=1; printf '%s' "${RPI5_GAMES_CASE}" | grep -F -- "${marker}" >/dev/null && rpi5_has=0
    x86_has=1;  printf '%s' "${X86_GAMES_CASE}"  | grep -F -- "${marker}" >/dev/null && x86_has=0
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

# ── 4e) OptionalService CR seeding — the runtime override the operator reconciles ──
#
# WHY THIS SECTION EXISTS. Everything above asserts the installed-services ConfigMap
# and the 13a element list. NOTHING asserted the OptionalService CRs, even though the
# CRD header calls them "the authoritative runtime override" — the lever a superadmin
# moves to add a service to a LIVE mesh. The gap was three-deep and every layer was
# silent:
#   1. `_opt_render_optionalservice_cr` was never in the extraction list above, so
#      gate_optional_services called it and bash printed `command not found` ELEVEN
#      times per run — to stderr, unchecked, and the suite still reported 164/0;
#   2. `_opt_set_cr_enabled` (which it calls) was not extracted either;
#   3. seed_tree never laid down seed-optionalservices.yaml, so even a correctly
#      extracted renderer would have hit `[ -f ... ] || return 0` and no-opped at rc 0.
# Fixing only (1) silences the noise and changes NO assertion count — which would be
# strictly worse than the bug, because the error message was the only visible signal.
# So the fix is (1)+(2)+(3) plus these assertions.
echo "-- OptionalService CR seeding (the runtime override) --"

CR_SEED_REL="manifests/optional-services-operator/seed-optionalservices.yaml"

# Read one CR's enabled flag by slug. Deliberately keyed on `slug:` inside spec (the
# field the operator reconciles on), NOT metadata.name.
cr_enabled() {  # $1 = tree, $2 = slug -> "true" | "false" | "" (absent)
  awk -v want="$2" '
    /^[[:space:]]*slug:[[:space:]]/ {
      s=$0; sub(/^[[:space:]]*slug:[[:space:]]*/,"",s); sub(/[[:space:]]*$/,"",s); arm=(s==want); next
    }
    arm && /^[[:space:]]*enabled:[[:space:]]*(true|false)[[:space:]]*$/ {
      v=$0; sub(/^[[:space:]]*enabled:[[:space:]]*/,"",v); sub(/[[:space:]]*$/,"",v); print v; exit
    }
  ' "$1/${CR_SEED_REL}"
}

expect_cr() {  # $1 = tree, $2 = slug, $3 = expected, $4 = scenario label
  local got; got="$(cr_enabled "$1" "$2")"
  if [ -z "${got}" ]; then
    bad "$4: ${2} has NO OptionalService CR (the operator has nothing to reconcile)"
  elif [ "${got}" = "$3" ]; then
    ok "$4: ${2} CR enabled=$3"
  else
    bad "$4: ${2} CR enabled=${got}, expected $3"
  fi
}

# VACUITY FLOOR. Every assertion below reads this one file; if it is absent or holds
# no CRs the whole section would pass by comparing nothing. Fail loudly instead.
seed_tree "cr-floor"
gate_optional_services
CR_COUNT="$(grep -cE '^[[:space:]]*kind:[[:space:]]*OptionalService[[:space:]]*$' "${TREE}/${CR_SEED_REL}" 2>/dev/null || echo 0)"
if [ "${CR_COUNT}" -ge 8 ]; then
  ok "CR seed present with ${CR_COUNT} OptionalService document(s)"
else
  bad "CR seed derivation is vacuous (${CR_COUNT} OptionalService docs) — every CR assertion below would compare nothing"
fi

# (a) DEFAULT build: default-on slugs enabled, default-off slugs disabled.
seed_tree "cr-default"
OPTIONAL_SERVICES="$(resolve_selection "" "")"
gate_optional_services
for slug in ${DEFAULT_ON};  do expect_cr "${TREE}" "${slug}" true  "CR/DEFAULT"; done
for slug in ${DEFAULT_OFF}; do expect_cr "${TREE}" "${slug}" false "CR/DEFAULT"; done

# (b) EXPLICIT selection: exactly the named slugs are enabled and nothing else is.
seed_tree "cr-explicit"
OPTIONAL_SERVICES="$(resolve_selection "games tube" "")"
gate_optional_services
for slug in games tube; do expect_cr "${TREE}" "${slug}" true "CR/EXPLICIT"; done
for slug in akkoma tuwunel phpbb owncast character-studio character-forge; do
  expect_cr "${TREE}" "${slug}" false "CR/EXPLICIT"
done

# (c) The CR and the ConfigMap must not disagree. They are two projections of one
#     decision, written by two different renderers; a mesh where they diverge has a
#     console that reports one thing and an operator that reconciles another.
seed_tree "cr-configmap-parity"
OPTIONAL_SERVICES="$(resolve_selection "owncast" "")"
gate_optional_services
CR_PARITY_CHECKED=0
for slug in akkoma tuwunel phpbb games owncast tube character-studio character-forge; do
  crv="$(cr_enabled "${TREE}" "${slug}")"
  if grep -qE "^[[:space:]]*${slug}:[[:space:]]*\"true\"" \
       "${TREE}/manifests/policy/installed-services-configmap.yaml"; then cmv=true; else cmv=false; fi
  [ -n "${crv}" ] || continue
  CR_PARITY_CHECKED=$((CR_PARITY_CHECKED+1))
  [ "${crv}" = "${cmv}" ] \
    || bad "CR/PARITY: ${slug} CR enabled=${crv} but ConfigMap says ${cmv}"
done
if [ "${CR_PARITY_CHECKED}" -ge 8 ]; then
  ok "CR/PARITY: CR and ConfigMap agree on all ${CR_PARITY_CHECKED} compared slug(s)"
else
  bad "CR/PARITY compared only ${CR_PARITY_CHECKED} slug(s) — too few to mean anything"
fi

# (d) NEGATIVE CONTROLS. Each plants a way the CR leg silently stops working and
#     proves these assertions go RED. Without these, the section above is just more
#     green text of the kind that hid the original bug.
cr_control() {  # $1 = label, $2 = mutated renderer body (a shell function definition)
  local label="$1" body="$2" saved out
  saved="$(declare -f _opt_render_optionalservice_cr)"
  eval "${body}"
  seed_tree "cr-ctl"
  OPTIONAL_SERVICES="$(resolve_selection "games" "")"
  gate_optional_services
  # games selected => must be true; a broken renderer leaves the seed's baked default.
  out="$(cr_enabled "${TREE}" games)"
  eval "${saved}"          # restore the real renderer before judging
  [ "${out}" = "true" ] \
    && bad "negative control '${label}': the CR still read true — these assertions do not bite" \
    || ok "negative control '${label}': caught (games CR read '${out:-absent}', not true)"
}

cr_control "renderer no-ops at rc 0 (the shipped shape when the seed is missing)" \
  '_opt_render_optionalservice_cr() { return 0; }'

cr_control "renderer writes every slug false regardless of selection" \
  '_opt_render_optionalservice_cr() {
     local seed="${SYSROOT}/var/lib/hugmesh/cluster/'"${CR_SEED_REL}"'"
     [ -f "${seed}" ] || return 0
     local slug
     for slug in akkoma tuwunel phpbb games owncast tube character-studio character-forge; do
       _opt_set_cr_enabled "${seed}" "${slug}" false
     done
   }'

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
# gate_optional_services() was EXTRACTED into one shared library so the rpi5/x86
# drift cannot recur (that extraction is the real fix behind three defects that
# shipped only on x86). The derivation below reads the function body wherever it
# actually lives: pass the library too when it exists, and let the nogate check
# fail only if the function is found in NO file at all. Hard-coding the two
# builders here is what made this guard report "gate_optional_services() not
# found" against a tree where the gate was present and shared.
OPT_GATE_LIB=""
for _cand in "${REPO}/scripts/_optional-services-lib.sh" "${REPO}/tests/lib/opt-gate-source.sh"; do
  [ -f "${_cand}" ] && { OPT_GATE_LIB="${_cand}"; break; }
done
unset _cand
CONSDUMP="${WORK}/consumers.env"
printf '%s\n' ${REG_SLUGS} > "${WORK}/reg-slugs.txt"
python3 - "${SRC}/manifests/policy/installed-services-configmap.yaml" \
           "${SRC}/apps/13a-optional-services.yaml" \
           "${SRC}/manifests/optional-services-operator/seed-optionalservices.yaml" \
           "${WORK}/reg-slugs.txt" \
           "${OPT_GATE_LIB:-/dev/null}" "${BUILDER}" "${BUILDER_X86}" > "${CONSDUMP}" <<'PY' || { echo "  CANNOT RUN: consumer derivation failed" >&2; exit 2; }
import re, sys
CM, A13, SEED, REGSLUGS = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
GATE_LIB  = sys.argv[5]          # the extracted shared gate library ("" / /dev/null when absent)
BUILDERS  = sys.argv[6:]

def nocomment(text):
    # FULL-LINE comments only. A trailing `# ...` is left alone deliberately: in
    # shell a '#' can sit inside a quoted string, and every pattern below is
    # structurally anchored (a case arm alone on its line, a `for slug in` header,
    # a ConfigMap data key at exactly two spaces), so a slug merely NAMED in a
    # trailing comment cannot satisfy one.
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))

def _body_of(path, fn):
    try:
        src = open(path, encoding="utf-8").read()
    except OSError:
        return None
    m = re.search(r"^%s\(\) \{\n(.*?)^\}$" % re.escape(fn), src, re.S | re.M)
    return nocomment(m.group(1)) if m else None

def gate_body(path):
    """The gate as this builder EFFECTIVELY runs it.

    Since the extraction, neither builder defines gate_optional_services itself —
    both source it from one shared library, which is the whole point (the drift it
    removes is why three defects shipped on x86 only). So a builder with no body of
    its own inherits the library's. Reading only the builder files here reported an
    EMPTY consumer set for rpi5 and, worse, silently attributed the library's slugs
    to x86, which would have made every per-builder assertion below meaningless."""
    own = _body_of(path, "gate_optional_services")
    return own if own is not None else _body_of(GATE_LIB, "gate_optional_services")

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
    # RESOLVE LIKE BASH, exactly as gate_body() above does. The renderers moved
    # into the shared library in the same extraction that moved the gate, so
    # reading only the builder files returned EMPTY for both — and an empty loop
    # set makes the headwind check below announce itself vacuous instead of
    # silently passing, which is how this was caught. The check's POWER is
    # unchanged: the loops are still DERIVED from the shipped implementation
    # rather than restated here, and a builder-local override of a renderer still
    # wins (it is last in resolution order), so a builder that regresses one is
    # still what gets measured.
    body = _body_of(path, fn)
    if body is None:
        body = _body_of(GATE_LIB, fn)
    if body is None:
        return set()
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
    own = _body_of(path, fn)
    if own is None:
        own = _body_of(GATE_LIB, fn)      # sourced from the shared library
    return own or ""

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
# Report "no gate" ONLY when the function was found in NO passed file. Since the
# extraction, the two builders SOURCE gate_optional_services from the shared
# library instead of each defining it, so both legitimately have no body of their
# own — listing them would make this guard refuse to run against a tree where the
# gate is present, shared, and working. What must never happen is the function
# existing nowhere; that is still fatal.
emit("CONS_NOGATE_FN", [] if len(nogate) < len(BUILDERS) else [b.rsplit("/", 1)[-1] for b in nogate])
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
# RESOLVED, not awk'd out of the builder. The _opt_svc_* primitives live in
# scripts/_optional-services-lib.sh since the integration — a builder that defines
# an `_opt_*` name locally is a hard FAIL further up (it would shadow the library
# at run time), so awk-ing the builder for them found nothing and this whole
# section died "CANNOT RUN". opt_gate_extract_fn reproduces bash's own resolution
# order (libs in source order, builder LAST), so a builder-local override is still
# what gets extracted and executed here — the shadowing check and this one now
# agree about which copy is real. validate_optional_services stays x86's own: the
# POLICY is per-builder (its four columns differ), only the primitives are shared.
# opt_gate_extract_fn printf's the body with NO trailing newline (it is built to be
# eval'd, not concatenated), so the bodies must be newline-separated here or the
# next definition line is glued onto the previous closing brace and the assembled
# file fails `bash -n` — which this suite reports as "CANNOT RUN", loudly, rather
# than silently skipping the section.
x86_fn() { opt_gate_extract_fn "${BUILDER_X86}" "$1"; printf '\n'; }
VALFILE="${WORK}/validate-optional-services.sh"
{
  echo "set -u"
  # The four mirrored constants, comment-stripped so a slug named in the long WHY
  # comment above them cannot end up in the list.
  grep -v '^[[:space:]]*#' "${BUILDER_X86}" | grep -E '^(KNOWN|GATED|SELECTABLE|DESELECTABLE)_OPTIONAL_SERVICES='
  for _f in _opt_svc_die _opt_svc_known _opt_svc_gated _opt_svc_selectable _opt_svc_deselectable validate_optional_services; do x86_fn "${_f}"; done
  echo ': "${OPTIONAL_SERVICES:=}"'
  echo ': "${EXCLUDE_SERVICES:=}"'
  echo 'validate_optional_services'
  echo 'echo VALIDATE_OK'
} > "${VALFILE}"
unset _f
for _f in KNOWN_OPTIONAL_SERVICES= GATED_OPTIONAL_SERVICES= SELECTABLE_OPTIONAL_SERVICES= DESELECTABLE_OPTIONAL_SERVICES= \
          '_opt_svc_die()' '_opt_svc_known()' '_opt_svc_gated()' '_opt_svc_selectable()' '_opt_svc_deselectable()' 'validate_optional_services()'; do
  grep -F "${_f}" "${VALFILE}" >/dev/null \
    || { echo "  CANNOT RUN: could not extract '${_f}' from build-x86-host-stage4.sh's source chain" >&2; exit 2; }
done
unset _f
bash -n "${VALFILE}" || { echo "  CANNOT RUN: extracted validator does not parse" >&2; exit 2; }
ok "extracted the REAL validate_optional_services + the shared _opt_svc_* primitives + all four slug constants, as build-x86-host-stage4.sh resolves them"

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

# ── DESELECTABLE_OPTIONAL_SERVICES: derived, not restated ────────────────────
# The '-<slug>'/'no-<slug>' spelling is honoured for a slug ONLY if some function
# in the shared library actually passes that slug to _opt_explicitly_deselected().
# Today exactly one does (_opt_anubis_installed, because anubis is the only slug
# whose install decision is ENV-conditional rather than plain presence). Restating
# "anubis" here is what would rot, so DERIVE the set from the library and assert
# the builder's constant set-equals it. Wiring the spelling to a second slug, or
# dropping the anubis call, then turns this red instead of minting a flag that is
# accepted and ignored.
# Comment-stripped: the library's long WHY block names _opt_explicitly_deselected
# and anubis in prose directly above the code, and counting prose is the single
# defect shape this repo has shipped most often.
X86_DESELECTABLE="$(grep -v '^[[:space:]]*#' "${BUILDER_X86}" | sed -n 's/^DESELECTABLE_OPTIONAL_SERVICES="\(.*\)"$/\1/p' | head -1)"
LIB_DESELECT_SLUGS="$(grep -v '^[[:space:]]*#' "${OPTLIB}" \
  | grep -oE '_opt_explicitly_deselected[[:space:]]+[A-Za-z0-9][A-Za-z0-9._-]*' \
  | awk '{print $2}' | sort -u | tr '\n' ' ')"
if [ -z "${LIB_DESELECT_SLUGS//[[:space:]]/}" ]; then
  bad "no slug is passed to _opt_explicitly_deselected anywhere in the shared library — the deselect spelling is inert on BOTH builders and DESELECTABLE_OPTIONAL_SERVICES claims otherwise"
elif seteq "${X86_DESELECTABLE}" "${LIB_DESELECT_SLUGS}"; then
  ok "x86: DESELECTABLE_OPTIONAL_SERVICES ('${X86_DESELECTABLE}') set-equals the slugs the shared library really passes to _opt_explicitly_deselected"
else
  bad "x86: DESELECTABLE_OPTIONAL_SERVICES='${X86_DESELECTABLE}' but the library deselect-checks='${LIB_DESELECT_SLUGS}' — the validator would accept-and-ignore, or refuse, a spelling the gate really honours"
fi
# ...and every deselectable slug must ALSO be selectable here, or the validator
# would accept '-anubis' and then refuse the very slug it names.
for _s in ${X86_DESELECTABLE}; do
  _in "${_s}" "${X86_SELECTABLE}" \
    && ok "x86: deselectable slug '${_s}' is also in SELECTABLE_OPTIONAL_SERVICES (the '-${_s}' spelling names a slug this builder bakes)" \
    || bad "x86: '${_s}' is DESELECTABLE but not SELECTABLE — '-${_s}' would be accepted for a slug this builder honours nowhere"
done
unset _s

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
# The abort anchor. Pinned FIRST, and against the builder's whole SOURCE CHAIN:
# if the string is gone, every leg below fails with a confusing message, so name
# the real cause once and up front rather than letting six legs blame the
# validator.
#
# CHAIN-SCOPED, NOT FILE-SCOPED (2026-09-04). This used to be a plain
# `grep -F -- "${X86_ROLE_ERR}" "${BUILDER_X86}"`, and it went red on main for a
# defect that does not exist. cce3cc18 ("role vocabulary: one spelling for the
# token after the device platform", 2026-08-27) did not reword the message — it
# RELOCATED it, out of an inline `case` in build-x86-host-stage4.sh and into
# hugmesh_role_validate() in scripts/_roles-lib.sh, which the builder sources at
# line 33 and calls at top level. Measured: 1 occurrence in the builder at
# cce3cc18^, 0 at cce3cc18. Nothing the builder PRINTS changed — `--role bogus`
# still aborts with this exact string — which is why the five legs below that
# match X86_ROLE_ERR against real builder OUTPUT all stayed green while only this
# static presence check failed: 298 passed, 1 failed, identically on a GNU host
# and in alpine:3. The relocation is the stated design, spelled out in the sibling
# guard that same commit DID update, tests/build-image-spec-guards.sh — "the
# builder no longer carries a private '--role must be one of' string". This file
# was missed.
#
# The old failure text ("message reworded — update X86_ROLE_ERR in this file")
# was then worse than no message at all: the needle was right and the HAYSTACK was
# wrong, so it pointed the next reader at the one edit that would have made this
# guard lie. X86_ROLE_ERR is the same variable the five legs below match against
# live builder output, and one of those legs (leg 1) is NEGATIVE — it asserts the
# anchor is ABSENT. Retuning the needle to a string the builder never prints would
# have turned that leg unfalsifiable and left this line green while doing it.
#
# So ask the question at the scope the design actually promises — the string must
# live in code this builder RUNS — and DERIVE that scope from the builder instead
# of naming scripts/_roles-lib.sh here, so the next relocation into some other
# sourced lib cannot break it again. opt_gate_sources() (tests/lib/opt-gate-source.sh,
# already sourced at the top of this file) reproduces bash's own resolution order,
# every `source "${SCRIPT_DIR}/scripts/*"` first and the builder last, and derives
# it comment-stripped so prose naming a lib cannot add a phantom file.
#
# THE HAYSTACK IS COMMENT-STRIPPED TOO, and that is not decoration. Widening the
# search without stripping would have re-opened this repo's most-shipped defect
# shape at a new address: the relocation above is exactly the kind of change that
# leaves an explanatory comment behind ("role validation moved to _roles-lib.sh —
# it prints '--role must be one of'"), and a comment like that in ANY of the 13
# chain files would satisfy a raw grep forever, including after the real printf
# was deleted. Only FULL-LINE comments are dropped, with the same `grep -v` idiom
# the four ordering anchors above use: a `#` can legally sit inside a shell string,
# so `sed 's/#.*$//'` could truncate a real match and turn this pin into a false
# RED. A trailing comment on a code line is therefore still able to satisfy this
# pin — that residual is stated rather than papered over, and legs 2/3 below,
# which require the anchor in live builder OUTPUT, are what close it.
X86_ROLE_ERR="--role must be one of"
X86_ANCHOR_CHAIN=()
while IFS= read -r _f; do
  [ -n "${_f}" ] && X86_ANCHOR_CHAIN+=("${_f}")
done < <(opt_gate_sources "${BUILDER_X86}")
_x86_anchor_in=""
for _f in "${X86_ANCHOR_CHAIN[@]+"${X86_ANCHOR_CHAIN[@]}"}"; do
  # Drained into /dev/null, never `| grep -q`: a -q consumer closes the pipe and
  # SIGPIPEs the producer, and under this file's `set -o pipefail` that turns a
  # FOUND match into rc=1 — a coin flip on GNU grep at this file size and a
  # certainty under busybox, which is the userland the alpine lane runs.
  if grep -v '^[[:space:]]*#' "${_f}" | grep -F -- "${X86_ROLE_ERR}" >/dev/null; then
    _x86_anchor_in="${_x86_anchor_in}${_x86_anchor_in:+ }${_f#"${REPO}/"}"
  fi
done
if [ -n "${_x86_anchor_in}" ]; then
  ok "x86: the post-validator abort anchor ('${X86_ROLE_ERR}') is live code in ${BUILDER_X86##*/}'s own source chain (carried by: ${_x86_anchor_in}; chain = ${#X86_ANCHOR_CHAIN[@]} files) — the execution legs below can prove they got past validate_optional_services"
else
  bad "x86: the post-validator abort anchor ('${X86_ROLE_ERR}') is in NO non-comment line of any of the ${#X86_ANCHOR_CHAIN[@]} files build-x86-host-stage4.sh sources (a chain of 0 or 1 means the SEARCH PATH broke, not the message). If role validation moved again, fix the search path — do NOT retune X86_ROLE_ERR unless the builder's message itself really changed, because the five legs below match this same string against live builder output and leg 1 asserts its ABSENCE, so a needle the builder never prints goes quietly unfalsifiable."
fi
unset _f _x86_anchor_in
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

# (6) the EXPLICIT-DESELECT spelling, per slug. It is honoured for exactly the
# slugs the shared library deselect-checks (derived above); for every other slug
# absence already means off, so the token is inert on BOTH builders and is refused
# with a pointer to the knob that does work.
run_x86 --optional-services "akkoma -games" --role bogus
if [ "${X86_RC}" -ne 0 ] && _has "EXPLICIT-DESELECT spelling" "${X86_OUT}" && _has "--exclude-services 'games'" "${X86_OUT}"; then
  ok "REAL build-x86-host-stage4.sh: REFUSES '-games' (not deselectable — inert on both builders) and names --exclude-services as the knob that works"
else
  bad "REAL build-x86-host-stage4.sh: '-games' was not refused with the deselect message (rc=${X86_RC}): ${X86_OUT}"
fi
# ...and the mirror leg, which is the one the integration added: a slug the shared
# gate REALLY deselect-checks must be ACCEPTED here, or x86 has no way at all to
# turn the ENV-conditional PoW shield off in a prod build (--exclude-services
# cannot: _opt_anubis_installed never reads EXCLUDE_SERVICES, so it falls through
# to the ENV default and prod stays ON, silently).
for _n in ${X86_DESELECTABLE}; do
  run_x86 --optional-services "akkoma -${_n}" --role bogus
  if ! _has 'command not found' "${X86_OUT}" && ! _has 'FATAL(optional-services)' "${X86_OUT}" \
     && _has "${X86_ROLE_ERR}" "${X86_OUT}"; then
    ok "REAL build-x86-host-stage4.sh: ACCEPTS '-${_n}' — the shared gate genuinely honours it, so refusing it would leave no lever at all"
  else
    bad "REAL build-x86-host-stage4.sh: '-${_n}' was REFUSED (rc=${X86_RC}) even though the shared library deselect-checks it: ${X86_OUT}"
  fi
  # and it must SURVIVE the 'all' sentinel, which replaces the whole token list.
  run_x86 --optional-services "all -${_n}" --role bogus
  if _has "sentinel expanded" "${X86_OUT}" && _has "-${_n}" "${X86_OUT}" && _has "${X86_ROLE_ERR}" "${X86_OUT}"; then
    ok "REAL build-x86-host-stage4.sh: '-${_n}' SURVIVES the 'all' sentinel expansion (it is not a member of the positive allow-list and must not be discarded)"
  else
    bad "REAL build-x86-host-stage4.sh: 'all -${_n}' lost the deselect token in the sentinel expansion — accepted and then discarded (rc=${X86_RC}): ${X86_OUT}"
  fi
done
unset _n
# The ENV-conditional slug must NOT be accepted in --exclude-services: subtraction
# removes the token from the selection and the ENV default then puts it back, so a
# prod build would ship it ON having been told it was excluded.
for _n in ${X86_DESELECTABLE}; do
  run_x86 --optional-services akkoma --exclude-services "${_n}" --role bogus
  if [ "${X86_RC}" -ne 0 ] && _has "ENV-CONDITIONAL" "${X86_OUT}" && _has "'-${_n}'" "${X86_OUT}"; then
    ok "REAL build-x86-host-stage4.sh: REFUSES '--exclude-services ${_n}' (subtraction cannot beat the ENV default) and names '-${_n}' instead"
  else
    bad "REAL build-x86-host-stage4.sh: '--exclude-services ${_n}' was accepted (rc=${X86_RC}) — in prod the slug ships ON anyway: ${X86_OUT}"
  fi
done
unset _n

# ── a LONE deselect token keeps the built-in default selection (#384, option B) ──
# `--optional-services "-anubis"` is all a caller that never touched the service
# picker can say to force the PoW shield off. --optional-services REPLACES the
# default, so before this a veto silently deleted akkoma/tuwunel/phpbb as well. Both
# builders run for real (the arg-parse expansion is top-level code, so the REAL
# script is the only honest oracle), and the resulting list is fed to the real
# anubis decision so the token is proved to reach the gate, not just to be printed.
echo "-- a lone deselect token keeps the built-in defaults, on BOTH builders --"
_plain() { sed -e 's/\x1b\[[0-9;]*m//g'; }
_kept_list() {   # echo the list the builder reports it kept, or nothing
  printf '%s\n' "$1" | _plain | sed -n 's/.*kept the built-in default selection: //p' | head -1
}
_dflt_lib="$(sed -n 's/^_OPT_BUILTIN_DEFAULT_SERVICES="\(.*\)"$/\1/p' "${OPTLIB}")"
for _b in "${BUILDER}" "${BUILDER_X86}"; do
  _bn="${_b##*/}"
  _dflt_b="$(sed -n 's/^OPTIONAL_SERVICES="${OPTIONAL_SERVICES:-\(.*\)}"$/\1/p' "${_b}")"
  if [ -n "${_dflt_lib}" ] && [ "${_dflt_lib}" = "${_dflt_b}" ]; then
    ok "${_bn}: its built-in default ('${_dflt_b}') is the one the lone-deselect rule restores"
  else
    bad "${_bn}: built-in default '${_dflt_b}' != the library's _OPT_BUILTIN_DEFAULT_SERVICES '${_dflt_lib}' — the veto would restore the wrong set"
  fi
  for _tok in -anubis no-anubis; do
    _out="$(env -u OPTIONAL_SERVICES -u EXCLUDE_SERVICES timeout 60 bash "${_b}" --optional-services "${_tok}" --role bogus 2>&1)" || true
    _kept="$(_kept_list "${_out}")"
    if [ "${_kept}" = "${_dflt_b} ${_tok}" ]; then
      ok "${_bn}: '--optional-services ${_tok}' alone keeps the defaults -> '${_kept}'"
    else
      bad "${_bn}: '--optional-services ${_tok}' alone resolved to '${_kept:-<no keep line>}', expected '${_dflt_b} ${_tok}': ${_out}"
    fi
    if _has 'command not found' "${_out}" || _has 'FATAL(optional-services)' "${_out}"; then
      bad "${_bn}: '${_tok}' alone was refused or hit a missing function: ${_out}"
    fi
    # The kept list must reach the gate: prod would install anubis on its own, the
    # token must turn it off, and the three defaults must still be selected.
    if [ -n "${_kept}" ]; then
      OPTIONAL_SERVICES="${_kept}"; ENV="prod"
      [ "$(_opt_anubis_installed)" = "false" ] \
        && ok "${_bn}: '${_tok}' reaches the gate -> anubis OFF under ENV=prod" \
        || bad "${_bn}: '${_tok}' did not turn anubis off under ENV=prod"
      for _d in ${_dflt_b}; do
        _opt_selected "${_d}" || bad "${_bn}: default '${_d}' is NOT selected after '${_tok}' alone"
      done
      ENV="test"; OPTIONAL_SERVICES=""
    fi
  done
  # What must NOT change: explicit none, an allow-list, and the `all` sentinel.
  _out="$(env -u OPTIONAL_SERVICES -u EXCLUDE_SERVICES timeout 60 bash "${_b}" --optional-services "" --role bogus 2>&1)" || true
  [ -z "$(_kept_list "${_out}")" ] \
    && ok "${_bn}: an EXPLICIT empty list stays none (the rule does not fire)" \
    || bad "${_bn}: an explicit empty --optional-services was given the defaults back: ${_out}"
  _out="$(env -u OPTIONAL_SERVICES -u EXCLUDE_SERVICES timeout 60 bash "${_b}" --optional-services "owncast -anubis" --role bogus 2>&1)" || true
  [ -z "$(_kept_list "${_out}")" ] \
    && ok "${_bn}: an allow-list carrying a veto ('owncast -anubis') is left alone" \
    || bad "${_bn}: 'owncast -anubis' had the defaults added to it: ${_out}"
  _out="$(env -u OPTIONAL_SERVICES -u EXCLUDE_SERVICES timeout 60 bash "${_b}" --optional-services "all -anubis" --role bogus 2>&1)" || true
  if [ -z "$(_kept_list "${_out}")" ] && _has "sentinel expanded" "$(printf '%s' "${_out}" | _plain)"; then
    ok "${_bn}: 'all -anubis' still goes through the sentinel expansion, not the lone-veto rule"
  else
    bad "${_bn}: 'all -anubis' took the wrong arm: ${_out}"
  fi
done
unset -f _plain _kept_list
unset _b _bn _tok _out _kept _d _dflt_b _dflt_lib
ENV="test"; OPTIONAL_SERVICES=""

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

# ── the '-<slug>' / 'no-<slug>' deselect spelling is PER-SLUG, not per-builder ─
# THIS SUITE HAS NOW BEEN WRONG ABOUT THIS TWICE, IN OPPOSITE DIRECTIONS, so the
# rule is derived rather than asserted from memory:
#   v1 pinned "x86 accepts the spelling" — false: nothing consumed it there.
#   v2 pinned "the spelling is RPI5-ONLY"  — true only while x86 carried no anubis
#      handling. The shared-gate extraction gave x86 the identical
#      _opt_explicitly_deselected/_opt_anubis_installed, so "rpi5-only" became a
#      message that LIED and, worse, left an x86 --env prod build with no lever to
#      turn the public PoW shield off at all.
# THE ACTUAL RULE, and it is a property of the SLUG, not the builder: the spelling
# is read only by _opt_anubis_installed(), because anubis is the only slug whose
# install decision is ENV-conditional instead of plain presence. For every other
# slug absence already means off, so '-games' is inert on BOTH builders. The
# deselectable set is derived from the library above and both halves are asserted
# here, so neither direction can rot back into folklore.
for _spell in "-games" "no-games"; do
  val_refuses "akkoma ${_spell}" "" "EXPLICIT-DESELECT spelling" \
    "REFUSES '${_spell}' — not deselect-checked anywhere, so the token is inert on BOTH builders"
done
unset _spell
for _n in ${X86_DESELECTABLE}; do
  val_accepts "akkoma -${_n}" "" "ACCEPTS '-${_n}' — the shared gate deselect-checks it, so this is the ONLY lever that turns it off"
  val_accepts "akkoma no-${_n}" "" "ACCEPTS the 'no-${_n}' spelling too (both forms are compared in _opt_explicitly_deselected)"
  val_refuses "akkoma" "${_n}" "ENV-CONDITIONAL" \
    "REFUSES '${_n}' in EXCLUDE_SERVICES — subtraction loses to the ENV default, so a prod build would ship it ON regardless"
done
unset _n
val_refuses "akkoma" "-games" "double negative" \
  "REFUSES the deselect spelling inside EXCLUDE_SERVICES too (double-negative, honoured by nothing)"
val_refuses "-akoma" "" "EXPLICIT-DESELECT spelling" \
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

# ── 7b) the deselect spelling is implemented ONCE, and resolves from BOTH ─────
# WHAT THIS USED TO ASSERT, AND WHY THAT PREMISE IS GONE. Until the integration
# this leg counted non-comment references and demanded
# "_opt_explicitly_deselected: >0 in build-rpi5-stage4.sh, ZERO in
# build-x86-host-stage4.sh", because the x86 refusal message asserted exactly that
# about another file. Both functions have since moved into
# scripts/_optional-services-lib.sh — the whole point of the extraction — so the
# counts are 0 and 0 and the old assertion could only be satisfied by putting a
# copy back in rpi5, i.e. by RE-CREATING the drift it was written to police.
#
# WHAT REPLACES IT, KEEPING THE SAME POWER. The question was never "which file
# holds the text"; it was "can these two builders disagree about the spelling".
# Three legs, and a one-builder-only regression still trips at least one:
#   (i)  the implementation exists in EXACTLY ONE file — the shared library — and
#        in NEITHER builder. A local copy in either is defined AFTER the source
#        line, so bash runs it; that is the drift, and this is where it shows up.
#        (The shadowing check further up covers the whole _opt_* namespace; this
#        one is specific and names the two functions the message depends on.)
#   (ii) the function RESOLVES from BOTH builders' source chains, byte-identically
#        (opt_gate_extract_fn reproduces bash's resolution order). "Absent from
#        rpi5" and "shadowed in x86" both go red here.
#   (iii) it still WORKS when executed — exercised below, unchanged.
echo "-- the '-<slug>' deselect spelling: ONE implementation, resolved from BOTH builders --"
# Comment-stripped AND string-literal-stripped: the x86 FATAL messages NAME
# _opt_explicitly_deselected and _opt_anubis_installed (they tell the operator
# where the spelling lives), and counting that mention as a definition would
# invert this check — the same comment-token shape, one layer in. `sed
# 's/"[^"]*"//g'` is not a shell parser, but every occurrence in these files is
# either a bare statement or a single double-quoted message on one line.
_decode() { grep -v '^[[:space:]]*#' "$1" | sed 's/"[^"]*"//g'; }
for _fn in _opt_explicitly_deselected _opt_anubis_installed; do
  # (i) defined in the library, defined in NEITHER builder.
  _d_lib="$(_decode "${OPTLIB}"      | grep -cE "^[[:space:]]*(function[[:space:]]+)?${_fn}[[:space:]]*\(?")"
  _d_r="$(  _decode "${BUILDER}"     | grep -cE "^[[:space:]]*(function[[:space:]]+)?${_fn}[[:space:]]*\(")"
  _d_x="$(  _decode "${BUILDER_X86}" | grep -cE "^[[:space:]]*(function[[:space:]]+)?${_fn}[[:space:]]*\(")"
  if [ "${_d_lib}" -gt 0 ] && [ "${_d_r}" -eq 0 ] && [ "${_d_x}" -eq 0 ]; then
    ok "${_fn}: defined in scripts/_optional-services-lib.sh and in NEITHER builder — one implementation, nothing to drift"
  else
    bad "${_fn}: lib=${_d_lib} rpi5-local=${_d_r} x86-local=${_d_x} — it must be defined in the shared library and in neither builder (a builder-local copy is defined after the source line, so bash runs THAT)"
  fi
  # (ii) and it resolves, byte-identically, from BOTH builders' chains.
  _r_body="$(opt_gate_extract_fn "${BUILDER}"     "${_fn}")"
  _x_body="$(opt_gate_extract_fn "${BUILDER_X86}" "${_fn}")"
  if [ -z "${_r_body}" ] || [ -z "${_x_body}" ]; then
    bad "${_fn}: does NOT resolve from $( [ -z "${_r_body}" ] && printf 'rpi5 '; [ -z "${_x_body}" ] && printf 'x86 ')— that builder would drop the spelling on the floor"
  elif [ "${_r_body}" != "${_x_body}" ]; then
    bad "${_fn}: resolves DIFFERENTLY from the two builders — one of them carries an override and the spelling means two different things"
  else
    ok "${_fn}: resolves BYTE-IDENTICALLY from both builders' source chains (so the x86 validator and the rpi5 gate agree about what '-<slug>' means)"
  fi
done
unset _fn _d_lib _d_r _d_x _r_body _x_body; unset -f _decode
if command -v _opt_explicitly_deselected >/dev/null 2>&1; then
  OPTIONAL_SERVICES="akkoma -anubis"
  _opt_explicitly_deselected anubis \
    && ok "_opt_explicitly_deselected: '-anubis' IS honoured (the spelling has a real consumer — and, since the extraction, the same one on both builders)" \
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

# ── 8) OptionalService CR seed: ABSOLUTE per-slug `enabled:` values ──────────
# WHY ABSOLUTE, AND WHY HERE. The CR is the runtime desired-state twin of the
# installed-services ConfigMap boolean; the admin-bff reconciler reads it. The
# parity suite can only ever diff rpi5's rendered CR against x86's — if the SHARED
# gate is wrong, both are wrong together and every diff still passes. That is the
# parity suite's own stated limitation, so the absolute oracle has to live on this
# (rpi5-side, correctness) suite. MEASURED (2026-08-26, adversarial review) before
# this section existed: stubbing _opt_render_optionalservice_cr to `return 0`, and
# separately deleting the `_opt_set_cr_enabled "${seed}" anubis "${val}"` line, each
# left ALL SEVEN suites green.
echo "-- OptionalService CR seed: absolute enabled: per slug --"
CR="manifests/optional-services-operator/seed-optionalservices.yaml"
# Read the rendered CR INDEPENDENTLY of the production awk (document-scoped scan of
# the baked file, not a re-use of _opt_set_cr_enabled).
cr_flag() {  # $1 = slug -> true|false|MISSING
  local v; v="$(awk -v want="$1" '
      $1=="---" { sl=""; en=""; next }
      /^[[:space:]]*slug:[[:space:]]/    { sl=$2 }
      /^[[:space:]]*enabled:[[:space:]]/ { en=$2 }
      sl==want && en!="" { print en; exit }
    ' "${TREE}/${CR}")"
  echo "${v:-MISSING}"
}
if [ ! -f "${SRC}/${CR}" ]; then
  bad "specs/cluster/${CR} missing — every CR assertion below would be vacuous"
else
  # (a) plain selection: selected slugs true, unselected false.
  seed_tree "cr-selection"
  ENV="test"
  OPTIONAL_SERVICES="akkoma tuwunel games"
  gate_optional_services
  for slug in akkoma tuwunel games; do
    [ "$(cr_flag "${slug}")" = "true" ] \
      && ok "CR: SELECTED ${slug} -> enabled: true" \
      || bad "CR: SELECTED ${slug} is enabled: $(cr_flag "${slug}"), expected true"
  done
  for slug in phpbb owncast tube character-studio character-forge edge-ai edge-ai-analysis edge-ai-tts; do
    [ "$(cr_flag "${slug}")" = "false" ] \
      && ok "CR: DESELECTED ${slug} -> enabled: false" \
      || bad "CR: DESELECTED ${slug} is enabled: $(cr_flag "${slug}"), expected false"
  done
  # NON-VACUITY: the rendered CR must differ from the checked-in seed, or every
  # assertion above could be reading the fixture's own baseline. akkoma/tuwunel/phpbb
  # ship true in the seed and phpbb is deselected here, so a real render must change it.
  cmp -s "${TREE}/${CR}" "${SRC}/${CR}" \
    && bad "CR: the rendered seed is BYTE-IDENTICAL to specs/ — _opt_render_optionalservice_cr never ran" \
    || ok "CR: the seed was genuinely rewritten by the gate (assertions are not reading the fixture)"

  # (b) anubis is ENV-CONDITIONAL in the CR exactly as in the ConfigMap. These three
  #     cases are the ones the deleted `_opt_set_cr_enabled ... anubis` line broke.
  #     case = "<label>|<ENV>|<OPTIONAL_SERVICES>|<expected CR enabled>"
  while IFS='|' read -r _lbl _env _sel _want; do
    [ -n "${_lbl}" ] || continue
    seed_tree "cr-anubis-${_lbl}"
    ENV="${_env}"
    OPTIONAL_SERVICES="${_sel}"
    gate_optional_services
    [ "$(cr_flag anubis)" = "${_want}" ] \
      && ok "CR [${_lbl}]: anubis enabled: ${_want} (ENV=${_env})" \
      || bad "CR [${_lbl}]: anubis is enabled: $(cr_flag anubis), expected ${_want} (ENV=${_env})"
    # and the ConfigMap boolean it mirrors must agree — a CR that silently disagrees
    # with the install flag is its own defect.
    _cm="$(grep -E '^[[:space:]]*anubis:[[:space:]]*"(true|false)"' \
           "${TREE}/manifests/policy/installed-services-configmap.yaml" | head -1 | grep -oE '(true|false)')"
    [ "${_cm:-MISSING}" = "${_want}" ] \
      && ok "CR [${_lbl}]: the installed-services ConfigMap anubis flag AGREES (${_want})" \
      || bad "CR [${_lbl}]: ConfigMap anubis is ${_cm:-MISSING} but the CR is ${_want} — the twins disagree"
  done <<'CRCASES'
prod-default|prod|akkoma tuwunel phpbb|true
test-default|test|akkoma tuwunel phpbb|false
prod-deselected|prod|akkoma tuwunel phpbb -anubis|false
test-selected|test|akkoma tuwunel phpbb anubis|true
CRCASES
  ENV="test"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
