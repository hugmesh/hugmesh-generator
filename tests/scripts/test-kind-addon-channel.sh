#!/usr/bin/env bash
# test-kind-addon-channel.sh — the kind (local DevOps) lane's SERVICE-SELECTION
# CHANNEL, end to end and offline: Studio -> Makefile -> bootstrap-kind.sh.
#
# WHY THIS EXISTS. `make kind-up` passed KIND_PROFILE and MFA and nothing else, so
# the curated Application set in bootstrap-kind.sh could only be changed by editing
# that file. The visible consequence, measured 2026-08-26: apps/01-metrics-server.yaml
# had existed all along and was in NO profile, while KIND_PROFILE=sso applied SEVEN
# HorizontalPodAutoscalers (1 admin-bff-api + 1 user-bff-api + 1 frontend + 4
# social-ui). An HPA with no resource-metrics API does not fail — it reports
# `<unknown>/70%` forever and holds its Deployment at the replicas floor, which is
# indistinguishable from an idle cluster. And
# studio/hugmesh_studio/core/local_stack_node.py called self._make("kind-up", ...)
# with NO extra_env, even though _make has always ACCEPTED it: nothing the Studio
# knew could reach the script at all.
#
# WHAT THIS PROVES: that a selection made at any of the three layers arrives at the
# fourth, that the fail-closed and default-ON rules hold, and that the two spellings
# which must never collapse (EMPTY = unset, `none` = none of them) do not.
#
# WHAT IT DOES NOT PROVE: that metrics-server WORKS. Selecting a file into an array
# says nothing about the metrics API. That is a live-cluster property and it has its
# own guard — tests/scripts/test-kind-metrics-api.sh, which asks `kubectl top` and a
# named HPA, and skips LOUDLY when there is no cluster.
#
# The selection legs run the REAL script (KIND_ADDONS_PRINT=1, which resolves and
# stops before touching anything) rather than re-implementing its parse, because a
# guard that re-implements the thing under test measures its own copy.
#
# Offline: bash + sed + grep + make + python3. No cluster, no kind, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BOOT="${REPO}/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"
APPS="${REPO}/specs/cluster/apps"
MAKEFILE="${REPO}/Makefile"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# A guard that skips is a guard that never guards. Name the tool and refuse.
for t in sed grep make python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: ${t} required (refusing to skip)" >&2; exit 1; }
done
[ -r "${BOOT}" ] || { echo "FATAL: cannot read ${BOOT}" >&2; exit 1; }

echo "== kind add-on selection channel =="

# ── 1) the script's own resolution, executed ───────────────────────────────
# TWO SAFETY RAILS, both earned the hard way on 2026-08-26.
#
# (a) `env -u KIND_ADDONS`: an inherited value in the operator's shell would make
#     every "unset" case below assert against something else entirely.
#
# (b) A SANDBOXED PATH WITH NO `kind` AND NO `docker`. This file runs the REAL
#     bring-up script — that is the whole point, a guard that re-implements the
#     parse measures its own copy — and the only thing standing between "resolve
#     the selection and stop" and "create a Kubernetes cluster" is the
#     KIND_ADDONS_PRINT escape a few dozen lines into it. While MUTATION-TESTING
#     this very guard I disabled that escape, and the run walked straight past it
#     and built a kind cluster on the operator's box. bootstrap-kind.sh's own
#     dependency preflight (`for bin in kind kubectl docker …`) sits BEFORE any
#     cluster work and exits 1 when one is missing, so hiding those two binaries
#     turns that accident into a clean early failure. The parse under test needs
#     neither: it runs on sed/grep and bash builtins.
#
#     PATH is set to a directory containing ONLY the handful of tools the parse
#     needs, symlinked in — not merely stripped of a few entries, because the
#     script also prepends the Studio's own tools dir via _tools-path-lib.sh and
#     would find kind there.
SAFE_BIN="$(mktemp -d)"
trap 'rm -rf "${SAFE_BIN}"' EXIT
for b in bash sed grep tr cut head cat printf env dirname basename cp mkdir rm; do
  src="$(command -v "$b" 2>/dev/null)" && ln -sf "${src}" "${SAFE_BIN}/${b}" 2>/dev/null
done
if [ -x "${SAFE_BIN}/bash" ] && [ -x "${SAFE_BIN}/sed" ] && [ -x "${SAFE_BIN}/grep" ]; then
  ok "sandbox: the resolver runs on a PATH with no kind and no docker, so a broken KIND_ADDONS_PRINT escape fails instead of building a cluster"
else
  bad "sandbox: could not stage bash/sed/grep — refusing to run the real bootstrap on the ambient PATH"
  echo "== kind add-on selection channel: aborted (no sandbox) =="
  exit 1
fi
# HUGMESH_TOOLS_PATH_SKIP is not a thing; the sandbox PATH is the whole guard, and
# the assertion below proves it: `kind` must NOT be findable from it.
if PATH="${SAFE_BIN}" command -v kind >/dev/null 2>&1 || PATH="${SAFE_BIN}" command -v docker >/dev/null 2>&1; then
  bad "sandbox: kind or docker is still reachable from the staged PATH — the rail is not in place"
else
  ok "sandbox: neither kind nor docker is reachable from the staged PATH"
fi

resolve() { # <field> [KIND_ADDONS value or the literal __unset__] -> the field's value
  local field="$1"
  # `${2:-...}` HERE WAS A VACUITY BUG, found by adversarial review. `:-`
  # substitutes on empty OR unset, so `resolve slugs ""` collapsed the
  # DELIBERATE empty-string argument into the sentinel and re-ran the unset
  # case — the "empty means unset, not none" assertion below compared the
  # unset answer to the unset answer and was green either way. `${2-...}`
  # substitutes on UNSET ONLY, which is the whole distinction under test.
  local val="${2-__unset__}"
  local out
  if [ "${val}" = "__unset__" ]; then
    out="$(env -u KIND_ADDONS -i PATH="${SAFE_BIN}" HOME="${HOME}" KIND_ADDONS_PRINT=1 \
             "${SAFE_BIN}/bash" "${BOOT}" 2>&1)"
  else
    out="$(env -i PATH="${SAFE_BIN}" HOME="${HOME}" KIND_ADDONS="${val}" KIND_ADDONS_PRINT=1 \
             "${SAFE_BIN}/bash" "${BOOT}" 2>&1)"
  fi
  printf '%s' "${out}" | sed -n "s/^${field}: //p" | sed -e 's/[[:space:]]*$//'
}
run_boot() { # <KIND_ADDONS value|__unset__> -> raw output; rc preserved
  if [ "${1}" = "__unset__" ]; then
    env -u KIND_ADDONS -i PATH="${SAFE_BIN}" HOME="${HOME}" KIND_ADDONS_PRINT=1 \
      "${SAFE_BIN}/bash" "${BOOT}" 2>&1
  else
    env -i PATH="${SAFE_BIN}" HOME="${HOME}" KIND_ADDONS="${1}" KIND_ADDONS_PRINT=1 \
      "${SAFE_BIN}/bash" "${BOOT}" 2>&1
  fi
}
eq() { # <what> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1 -> '$3'"; else bad "$1: expected '$2', got '$3'"; fi
}

eq "unset KIND_ADDONS selects the lane default" "metrics-server" "$(resolve slugs)"
eq "unset KIND_ADDONS applies the metrics-server Application" \
   "01-metrics-server.yaml" "$(resolve files)"
# THE TRAP THIS PAIR PINS. An empty KIND_ADDONS is what every layer in between
# produces by accident — make expands an unset variable to nothing — so the script
# reads empty as UNSET. If that ever flipped to "none", a plain `make kind-up`
# would silently stop deploying metrics-server and the seven HPAs would go inert
# again with nothing to show for it.
eq "an EMPTY KIND_ADDONS means UNSET, not none" "metrics-server" "$(resolve slugs "")"
eq "an EMPTY KIND_ADDONS still applies the metrics-server Application" \
   "01-metrics-server.yaml" "$(resolve files "")"
# SEPARATORS ARE NOT CONTENT — the same trap one layer out, and it was LIVE.
# `${KIND_ADDONS:-default}` rescues empty-or-unset only, so "   " sailed past
# it and then word-split to ZERO slugs: a whitespace-only value silently meant
# `none`. Measured on the pre-fix script: `slugs:` came back empty. Any layer
# that builds this value by joining a list can emit exactly that.
eq "a WHITESPACE-ONLY KIND_ADDONS means UNSET, not none" "metrics-server" "$(resolve slugs "   ")"
eq "a TAB-ONLY KIND_ADDONS means UNSET, not none" "metrics-server" "$(resolve slugs "	")"
eq "a SEPARATOR-ONLY KIND_ADDONS (bare comma) means UNSET, not none" "metrics-server" "$(resolve slugs ",")"
# THE `none` LEG NEEDS ITS EXIT STATUS, and a mutation proved it: delete the
# lowercase spelling from the parse's `case` and `none` becomes an UNKNOWN SLUG,
# refused with rc 1 and no `slugs:` line at all. An assertion that only compares
# the (absent) field to "" cannot tell "none means none" from "none is rejected"
# — it passed the mutation. Assert the run SUCCEEDED first.
none_out="$(run_boot none)"; none_rc=$?
if [ "${none_rc}" -eq 0 ]; then ok "the literal 'none' is ACCEPTED (rc=0), not refused as an unknown slug"
else bad "'none' was refused (rc=${none_rc}) — the only spelling for 'no add-ons' does not parse: ${none_out}"; fi
case "${none_out}" in
  *"slugs:"*) ok "the 'none' run reports its (empty) selection" ;;
  *) bad "the 'none' run printed no selection at all: ${none_out}" ;;
esac
eq "the literal 'none' really means none" "" "$(resolve slugs none)"
eq "'none' applies no add-on files at all" "" "$(resolve files none)"
# The map declares keda's closure, not just keda: an operator who asks for
# autoscaling substrate over an absent metrics API has the inert HPAs back.
eq "the keda row carries its declared metrics-server dependency" \
   "01-metrics-server.yaml 01b-keda.yaml" "$(resolve files keda)"
eq "comma-separated selections parse" \
   "metrics-server keda" "$(resolve slugs metrics-server,keda)"
eq "space-separated selections parse" \
   "metrics-server keda" "$(resolve slugs "metrics-server keda")"
eq "a file shared by two selected rows is applied ONCE" \
   "01-metrics-server.yaml 01b-keda.yaml" "$(resolve files metrics-server,keda)"
eq "a repeated slug is collapsed" "keda" "$(resolve slugs keda,keda)"

# Fail-closed, exactly like the MFA parse: an unrecognised spelling must not mean
# "no add-on" while the bring-up exits 0.
out="$(run_boot bogus)"; rc=$?
if [ "${rc}" -ne 0 ]; then ok "an unknown add-on slug is REFUSED (rc=${rc})"
else bad "an unknown add-on slug was accepted — the channel silently drops it"; fi
case "${out}" in
  *"metrics-server"*|*"keda"*) ok "the refusal names the add-ons that DO exist" ;;
  *) bad "the refusal does not name the known add-ons: ${out}" ;;
esac

# ── 2) POST-CONDITION on the map: every file it names must exist ───────────
missing=0; mapped=0
while read -r f; do
  [ -n "${f}" ] || continue
  mapped=$((mapped+1))
  [ -r "${APPS}/${f}" ] || { echo "     ${f} is mapped but absent from specs/cluster/apps"; missing=$((missing+1)); }
done <<< "$(resolve files "metrics-server keda" | tr ' ' '\n')"
if [ "${mapped}" -lt 2 ]; then
  bad "vacuity: only ${mapped} mapped file(s) resolved — the resolver is not reading the map"
elif [ "${missing}" -eq 0 ]; then
  ok "every file the add-on map names exists in specs/cluster/apps (${mapped} checked)"
else
  bad "${missing} mapped file(s) do not exist"
fi

# ── 3) the Makefile leg ────────────────────────────────────────────────────
# Read the RECIPE, not the file: `make -n` expands the conditional, which is the
# whole point — a `KIND_ADDONS='$(KIND_ADDONS)'` written unconditionally would
# hand the script an EMPTY value on every plain run and put the default in two
# places, one of them silent.
recipe_plain="$(env -u KIND_ADDONS make -C "${REPO}" -n kind-up 2>/dev/null | grep bootstrap-kind.sh)"
recipe_sel="$(env -u KIND_ADDONS make -C "${REPO}" -n kind-up KIND_ADDONS=metrics-server,keda 2>/dev/null | grep bootstrap-kind.sh)"
case "${recipe_plain}" in
  *KIND_ADDONS*) bad "make kind-up sets KIND_ADDONS even when the operator set nothing — that overrides the script's own default with an empty string" ;;
  *bootstrap-kind.sh*) ok "make kind-up passes NO KIND_ADDONS when none was given (the script's default stands)" ;;
  *) bad "could not read the kind-up recipe at all: '${recipe_plain}'" ;;
esac
case "${recipe_sel}" in
  *"KIND_ADDONS='metrics-server,keda'"*) ok "make kind-up threads a selection into bootstrap-kind.sh verbatim" ;;
  *) bad "make kind-up does not thread KIND_ADDONS: '${recipe_sel}'" ;;
esac
# The MFA thread must survive alongside it (tests/stack/test-mfa-flip-wiring.sh
# reads the same line; this is a cheap early warning if the recipe is reshaped).
case "${recipe_sel}" in
  *"KIND_PROFILE=sso"*"MFA="*) ok "the kind-up recipe still carries KIND_PROFILE + MFA" ;;
  *) bad "the kind-up recipe lost KIND_PROFILE/MFA: '${recipe_sel}'" ;;
esac

# ── 4) the Studio leg ──────────────────────────────────────────────────────
# The wire that was missing: LocalStackNode.devops_up called _make("kind-up") with
# no extra_env. Asserted by CAPTURING the env a fake _make receives — reading the
# source for the word `extra_env` would pass on a call that passes {}.
STUDIO_OUT="$(cd "${REPO}" && PYTHONPATH=studio python3 - <<'PY' 2>&1
from hugmesh_studio.core import local_services as ls
from hugmesh_studio.core.local_stack_node import LocalStackNode

fails = []
ran = 0
def check(cond, msg):
    global ran
    ran += 1
    if not cond:
        fails.append(msg)

# Anti-drift: the Studio's default-ON row and bootstrap-kind.sh's
# KIND_ADDONS_DEFAULT are two spellings of one fact, and a surface that starts in
# a state the lane does not ship is a surface that lies about the lane.
import re, pathlib
boot = pathlib.Path("specs/cluster/bootstrap/kind-local/bootstrap-kind.sh").read_text()
boot_nc = "\n".join(re.sub(r"#.*", "", ln) for ln in boot.splitlines())
m = re.search(r'^KIND_ADDONS_DEFAULT="([^"]*)"', boot_nc, re.M)
check(m is not None, "bootstrap-kind.sh has no KIND_ADDONS_DEFAULT")
if m:
    script_default = tuple(x for x in m.group(1).replace(",", " ").split() if x)
    check(script_default == ls.kind_addon_default_selection(),
          "default drift: script says %r, Studio says %r"
          % (script_default, ls.kind_addon_default_selection()))

# Every Studio slug must be a slug the script's map actually knows.
mm = re.search(r'^KIND_ADDON_MAP="\n(.*?)^"', boot_nc, re.M | re.S)
check(mm is not None, "bootstrap-kind.sh has no KIND_ADDON_MAP block")
if mm:
    map_slugs = tuple(ln.split()[0] for ln in mm.group(1).splitlines() if ln.split())
    check(set(ls.kind_addon_slugs()) == set(map_slugs),
          "catalogue drift: Studio offers %r, the script maps %r"
          % (ls.kind_addon_slugs(), map_slugs))

# The two spellings that must never collapse.
check(ls.kind_addon_env(None) == {}, "no picker must export nothing")
check(ls.kind_addon_env(ls.kind_addon_default_selection()) == {},
      "a selection equal to the lane default must export nothing (byte-identical env)")
check(ls.kind_addon_env(()) == {ls.KIND_ADDONS_ENV: ls.KIND_ADDONS_NONE},
      "an EMPTY selection must export the literal 'none', never '' — '' is read as UNSET "
      "and would silently switch metrics-server back on")
check(ls.kind_addon_env(("keda",)) == {ls.KIND_ADDONS_ENV: "keda"},
      "a real selection must export itself")
try:
    ls.kind_addon_env(("bogus",))
    check(False, "an unknown slug must be refused, not exported")
except ValueError:
    pass

# THE WIRE. Capture what devops_up actually hands to make.
seen = {}
node = LocalStackNode(".", kind_addons=("keda",))
node.devops_available = lambda: []
node.devops_repo_access = lambda: []
node._make = lambda target, timeout, extra_env=None, on_line=None, cancel=None: (
    seen.update({"target": target, "env": extra_env}) or (True, ""))
node.devops_up(on_line=lambda s: None)
check(seen.get("target") == "kind-up", "devops_up no longer runs `make kind-up`")
check(seen.get("env") == {"KIND_ADDONS": "keda"},
      "devops_up did not thread the selection into make's env: %r" % (seen.get("env"),))

seen.clear()
node2 = LocalStackNode(".")
node2.devops_available = lambda: []
node2.devops_repo_access = lambda: []
node2._make = lambda target, timeout, extra_env=None, on_line=None, cancel=None: (
    seen.update({"env": extra_env}) or (True, ""))
node2.devops_up(on_line=lambda s: None)
check(seen.get("env") == {},
      "an unselected node must add NOTHING to make's env, got %r" % (seen.get("env"),))

# The GUI's collector must exist and be catalogue-ordered; the page keeps the
# boxes, but the tuple it produces is what reaches the config.
import inspect
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
check("kind_addons" in LocalMeshBootstrapConfig.__dataclass_fields__,
      "LocalMeshBootstrapConfig has no kind_addons field — the GUI's selection cannot reach the node")
check(LocalMeshBootstrapConfig().kind_addons is None,
      "kind_addons must default to None (no picker used), not to a tuple")

for f in fails:
    print("FAILED: " + f)
# Vacuity floor on the leg itself: a leg that asserted nothing must not report
# clean. The count is the number of check() calls that actually executed, not a
# constant — a constant is a number that agrees with itself.
if ran < 12:
    print("FAILED: only %d Studio checks ran — this leg has gone vacuous" % ran)
print("STUDIO_CHECKS_RUN=%d" % ran)
PY
)"
echo "${STUDIO_OUT}" | sed -n 's/^FAILED: /     /p'
# `case`, not `| grep -q`: a matching quiet grep exits before its writer is done
# and, under `set -o pipefail`, reports FAILURE for a match it actually found.
studio_failed="$(printf '%s\n' "${STUDIO_OUT}" | grep -c '^FAILED: ')"
case "${STUDIO_OUT}" in
  *STUDIO_CHECKS_RUN*)
  if [ "${studio_failed}" -gt 0 ]; then
    bad "${studio_failed} Studio wiring check(s) failed above"
  else
    ok "Studio: the selection reaches make's env, the defaults do not drift, and '' never collapses into 'none'"
  fi
  ;;
  *) bad "the Studio leg did not run to completion: ${STUDIO_OUT}" ;;
esac

# ── 4b) the GUI leg, STATICALLY — and this is the weak leg, said plainly ───
# The local-mesh page's add-on checkboxes cannot be exercised here: the three Qt
# test files that would cover them (studio/tests/test_local_mesh.py,
# test_local_mesh_stages.py, test_services_section.py) abort in Qt teardown on
# this box — at HEAD, identically, with no change of mine involved — because the
# environment has PyQt6 where the Studio expects PySide6. So what follows is a
# WIRING check on the source with comments stripped, not a behavioural one: it
# proves the page's collector is CALLED into the config, and it does NOT prove
# that a click on a box changes the tuple. The behavioural half of the surface
# stays uncovered until the Qt suite can run.
PAGE="${REPO}/studio/hugmesh_studio/gui/pages/localmesh.py"
page_nc="$(sed 's/#.*//' "${PAGE}")"
for needle in 'kind_addons=self.collect_kind_addons()' 'def collect_kind_addons' 'self.kind_addon_boxes'; do
  case "${page_nc}" in
    *"${needle}"*) ok "local-mesh page (comments stripped) carries: ${needle}" ;;
    *) bad "local-mesh page has lost '${needle}' — the DevOps add-on boxes would be inert" ;;
  esac
done
# The page must rebuild the config from the live widgets before starting the lane,
# or it starts with whatever selection self.boot happened to be holding.
case "${page_nc}" in
  *"def _devops_up"*) : ;;
  *) bad "local-mesh page has no _devops_up handler" ;;
esac
if [ -n "$(printf '%s\n' "${page_nc}" | sed -n '/def _devops_up/,/def _devops_down/p' | grep -F 'self.collect_bootstrap()' || true)" ]; then
  ok "_devops_up rebuilds the config from the live widgets before starting the lane"
else
  bad "_devops_up does not re-collect the widgets — the lane would start with a STALE add-on selection"
fi

# ── 5) negative control: an emptied map row must be REFUSED ────────────────
# A defect/no-defect PAIR. A lone "the bad copy failed" assertion proves nothing —
# a copy can fail for a reason unrelated to the property under test.
T="$(mktemp -d)"; trap 'rm -rf "${T}" "${SAFE_BIN}"' EXIT
sed 's|^metrics-server  01-metrics-server.yaml$|metrics-server|' "${BOOT}" > "${T}/empty-row.sh"
if cmp -s "${T}/empty-row.sh" "${BOOT}"; then
  bad "control: the map-row sabotage changed NOTHING — its pattern no longer matches, so this control is inert"
else
  bad_out="$(env -u KIND_ADDONS -i PATH="${SAFE_BIN}" HOME="${HOME}" KIND_ADDONS_PRINT=1 \
               "${SAFE_BIN}/bash" "${T}/empty-row.sh" 2>&1)"; bad_rc=$?
  good_out="$(run_boot __unset__)"; good_rc=$?
  if [ "${bad_rc}" -eq 0 ] && [ "$(printf '%s' "${bad_out}" | sed -n 's/^files: //p')" != "" ]; then
    bad "control: a map row with no files still resolved to files — the parse is reading something else"
  elif [ "${good_rc}" -ne 0 ]; then
    bad "control: the UNMODIFIED script also failed — the control cannot distinguish"
  else
    ok "control: emptying a map row really empties the selection (and the intact script still resolves)"
  fi
fi

echo
echo "== kind add-on selection channel: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
