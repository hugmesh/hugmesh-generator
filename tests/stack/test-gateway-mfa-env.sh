#!/usr/bin/env bash
# test-gateway-mfa-env.sh — emission gate for the GATEWAY MFA-ENFORCEMENT env trio
# (APP_MFA_ENABLED / APP_MFA_FRESHNESS_WINDOW / APP_MFA_ENFORCE_PRIVILEGED_FLOOR).
#
# WHY THIS GATE EXISTS. The gateway is the component that ENFORCES MFA at route
# level (GatewayRouteAccessFilter.decide() honours gateway_route_access.mfa_required
# plus the privileged floor). Its three properties — app.mfa.enabled,
# app.mfa.freshness-window, app.mfa.enforce-privileged-floor, backed by the three
# env vars above — appeared in ZERO files in this repo, so no deployment the
# generator produced could ever turn enforcement on: the enforcement leg was
# unreachable from GitOps and from the local stack. This test locks the wiring in
# AND locks the DELIBERATELY ASYMMETRIC enablement posture, so neither side can
# silently drift into the other's setting.
#
# ── THE POSTURE THIS GATE PINS (operator decision; do NOT "harmonise" it) ─────
# CLUSTER, all four gateway instances via the one shared chart:  MFA OFF.
#   Turning it on is an explicit, deliberate operator action, because the
#   privileged floor is NOT exempt for SUPERADMIN: enabling it before operators
#   have enrolled a second factor locks them out of the privileged plane. So the
#   chart default is false AND no specs/cluster/apps/*.yaml may flip it — that
#   second half is a REGRESSION THAT HAS ALREADY HAPPENED ONCE and had to be
#   undone by hand, which is why assertion (4b) exists.
# COMPOSE dev stack, tests/stack/compose.local.yaml, all three gateways:  MFA ON.
#   APP_MFA_ENABLED defaults TRUE so the enforcement leg is actually exercisable
#   end-to-end locally. Nothing here can lock anyone out of anything.
# APP_MFA_ENFORCE_PRIVILEGED_FLOOR: OFF on BOTH sides, including compose. It is a
#   separate sub-flag and it fails CLOSED with a 503 for privileged principals
#   during route-access cold start — a hostile dev default. Flip it per-run.
# APP_MFA_FRESHNESS_WINDOW: 600000 (10 min) on both sides.
# The asymmetry is the point: assertion (4) pins the cluster side to false and
# assertion (6) pins the compose side to true, so "fixing" either one to match the
# other fails this gate.
#
# ASSERTS
#   (1) SHARED-CHART premise: all four gateway Applications (be/fe/pki/superadmin)
#       point at specs/cluster/charts/hugmesh-gateway, so ONE chart-level `mfa:`
#       block genuinely reaches every instance (the design depends on this).
#       Compared on the CANONICAL path, and the canonicaliser is itself asserted
#       here in both directions — the spellings ArgoCD treats as one directory must
#       collapse, and paths it treats as different must stay apart. See (4b).
#   (2) The chart's values.yaml declares mfa.enabled / mfa.freshnessWindow /
#       mfa.enforcePrivilegedFloor with the IMAGE defaults (false / 600000 / false),
#       as BOOLEANS/ints rather than strings.
#   (3) EMISSION: evaluating templates/deployment.yaml's container env list against
#       chart values merged with EACH Application's own helm values yields all three
#       vars for all four releases — and for the bare chart defaults.
#   (4) CLUSTER SIDE IS OFF: every one of those renders is false / 600000 / false,
#       and no Application sets an APP_MFA_* var by hand through the raw `extraEnv`
#       escape hatch either (which would bypass (2)).
#  (4b) NO CLUSTER APPLICATION TURNS MFA ON, against container truthiness so
#       `enabled: "true"` counts too. This is the specific regression this gate was
#       written for. Three things make the audit's REACH match ArgoCD's:
#         · FILE DISCOVERY is the root app-of-apps' own: every *.yaml, *.yml and
#           *.json under specs/cluster/apps, RECURSIVELY — what an ArgoCD
#           `directory: {recurse: true}` source reads. (4c) asserts the root app
#           really still is that source, so the model is checked, not assumed. A
#           `-maxdepth 1 -name '*.yaml'` glob used to be the audit's reach, and a
#           gateway committed as `26-gateway-x.yml` or in a subdirectory escaped.
#         · VALUE FORMS are all five an Application can use — values, valuesObject,
#           parameters (== --set), fileParameters, valueFiles (see the extractor's
#           helm_inputs). Reading only the `values` STRING used to be enough for a
#           `valuesObject:` block to switch MFA on with this suite still green.
#         · ApplicationSet TEMPLATES are audited too (spec.template.spec is an
#           Application spec), so a gateway deployed by an ApplicationSet is in
#           scope as well.
#         · The CHART PATH is compared CANONICALLY. ArgoCD resolves source.path
#           against the repo root, so `./specs/…`, `specs/…/`, `.//specs/…` and
#           `specs/cluster/charts/./hugmesh-gateway` are all the SAME chart with
#           the same values — but a raw string compare called them different, and
#           a fifth gateway spelled any of the non-canonical ways was not a
#           "gateway consumer" here at all. It escaped the consumer check, the
#           release check AND the unreadable-input check below, and shipped GREEN
#           carrying a valueFiles entry whose MFA value nothing here can read.
#           norm_chart_path() in the extractor canonicalises once, for every
#           consumer of those rows; (8r)/(8s) pin both directions.
#         · MULTI-SOURCE Applications (spec.sources) are NOT MODELLED, and this
#           says so in those words instead of letting (3)/(5) report env vars as
#           "NOT emitted"/"NOT quoted" for a release the model never resolved.
#       It also asserts that the set of Applications deploying the gateway chart is
#       EXACTLY the four this test knows about, so a fifth gateway instance
#       committed under specs/cluster/apps cannot quietly escape (3)/(4)/(5).
#       AND that no gateway Application feeds helm an input this gate cannot read
#       (a valueFiles/fileParameters entry): an un-auditable input is a FAILURE
#       here, never a pass. WHAT IS STILL OUT OF REACH, by construction: an
#       Application applied out of band (kubectl, another repo, a Helm chart of its
#       own) is not in git under specs/cluster/apps and no file-level gate can see
#       it.
#   (5) `| quote` on all three: an unquoted `value: false` is a YAML BOOLEAN and
#       the API server rejects it (`cannot unmarshal bool into Go value of type
#       string`), so the manifest would not apply at all.
#   (6) COMPOSE DEV STACK IS ON: the three gateway services in compose.local.yaml
#       each carry the trio in the house `${VAR:-default}` style, and resolving with
#       the variables UNSET (what `make stack-up` does when the operator sets
#       nothing) gives true / 600000 / false.
#  (6b) …and those three are ALL of them: the gateway services are re-DISCOVERED
#       from compose.local.yaml itself (build context / image == the hugmesh-gateway
#       repo, or a `*-gateway` service name) and the discovered set must equal the
#       audited set. This is (4b)'s consumer check for the compose half: without it
#       a new gateway service with no APP_MFA_* trio is simply not looked at, and
#       "not looked at" printed as a PASS is how the cluster half went wrong.
#   (7) compose.m2-local.yaml stays `environment:`-FREE — it is a build-args-only
#       override that deep-merges over compose.local.yaml and inherits its env, so
#       duplicating runtime vars there would only create a second place to drift.
#  (7b) every `docs/*.md` path mentioned in the files this gate owns resolves to a
#       file that actually ships. A comment promising a rollout runbook that is not
#       in the tree is a lie the reader only finds by going to look, and this file's
#       own posture comments shipped exactly that.
#   (8) NEGATIVE CONTROLS on STAGED COPIES (the repo tree is never mutated): a
#       values.yaml flipped to true, a deleted env row, a typo'd .Values path, a
#       dropped `| quote`, a compose default flipped to FALSE, a compose service
#       stripped of the trio, an Application that sets mfa.enabled true (as a
#       boolean AND as the string "true"), the same flag arriving via `valuesObject`
#       or via a `parameters` --set entry, a gateway Application handed an opaque
#       `valueFiles`, a FIFTH gateway Application hidden behind a `.yml` extension
#       and another one in a SUBDIRECTORY, a fifth gateway whose chart path is
#       spelled each of the five ways ArgoCD reads as one directory (8r), an
#       Application at a DIFFERENT chart that must NOT be swept into the gateway
#       sets (8s), a multi-source Application (8t), and a fourth compose gateway
#       service with no trio must EACH make the corresponding assertion fail. Every
#       mutation also PROVES IT LANDED (the python mutators exit non-zero if their
#       target text was not found), because a mutator that silently no-ops turns
#       its control into a fake pass — which is exactly what happened to the
#       original (8e). 8r/8s measure their staged tree's gateway sets BEFORE
#       planting and assert the delta, so neither can bite (or fail) merely because
#       the working tree was already in some other state.
#   (9) CROSS-CHECK against real `helm template` when helm is on PATH. The CI job
#       installs a sha256-PINNED helm and sets REQUIRE_HELM=1, which turns the
#       no-helm SKIP into a FAIL — in CI this section is LOAD-BEARING, and an image
#       change that silently loses helm goes RED instead of green-with-less-coverage.
#       Local runs without helm (and without REQUIRE_HELM) keep the loud SKIP.
#
# THE TALLY IS ITSELF GUARDED, at both ends. Up front, every external tool is
# preflighted (and `cp -a` + `mapfile` are additionally proven to WORK, not merely
# to exist) — this runs in `python:3-slim` under `set -uo pipefail` WITHOUT `-e`,
# so a missing binary would not abort the run, it would silently distort it. At the
# end, MIN_CHECKS pins how many assertions must have run: "0 failed" over half the
# checks is indistinguishable from a real pass otherwise.
#
# Cheap: python3 + PyYAML + bash (+ helm for (9): pinned in CI, optional locally).
# No cluster, no docker, no network.
set -uo pipefail

# Builtins only (parameter expansion + cd + pwd). This line runs BEFORE the tool
# preflight below can run — it is what finds the files the preflight checks — so it
# must not depend on any external binary. It used to call `dirname`, and in an image
# without it REPO silently resolved somewhere else and the failure surfaced as a
# baffling "missing input" for a path nobody wrote.
_self="${BASH_SOURCE[0]}"; _selfdir="${_self%/*}"
[ "${_selfdir}" != "${_self}" ] || _selfdir="."
REPO="$(cd "${_selfdir}/../.." && pwd)"
CHART="${REPO}/specs/cluster/charts/hugmesh-gateway"
COMPOSE="${REPO}/tests/stack/compose.local.yaml"
M2_COMPOSE="${REPO}/tests/stack/compose.m2-local.yaml"
EXTRACT="${REPO}/tests/stack/gateway_mfa_env.py"
APPS_DIR="${REPO}/specs/cluster/apps"
ROOT_APP="${REPO}/specs/cluster/app-of-apps.yaml"
GW_APP_FILES=(20-gateway-be.yaml 20-gateway-fe.yaml 20-gateway-pki.yaml 22-gateway-superadmin.yaml)
APPS=()
for f in "${GW_APP_FILES[@]}"; do APPS+=("${APPS_DIR}/${f}"); done
# The cluster gateway RELEASES this file audits. (4b) re-derives the set from the
# manifests, so a fifth release cannot appear without being declared here — not even
# as a second Application inside one of the four files already listed above, which
# the FILE-keyed consumer check alone cannot see.
CLUSTER_RELEASES=(hugmesh-be-gateway hugmesh-fe-gateway hugmesh-pki-gateway hugmesh-superadmin-gateway)
RELEASES=("${CLUSTER_RELEASES[@]}" CHART-DEFAULTS)
# The compose gateway services this file AUDITS. Assertion (6b) re-derives the set
# from compose.local.yaml and fails if the two disagree, so this list cannot go
# stale silently — adding a gateway service to the dev stack and not to this list
# is a FAILURE, not an unnoticed gap.
GW_SERVICES=(hugmesh-pki-gateway hugmesh-be-gateway hugmesh-fe-gateway)
CHART_REL="specs/cluster/charts/hugmesh-gateway"
TRIO=(APP_MFA_ENABLED APP_MFA_FRESHNESS_WINDOW APP_MFA_ENFORCE_PRIVILEGED_FLOOR)

# ── THE TWO EXPECTATION SETS. Separate on purpose; see the posture block above.
# CHART/cluster: enforcement OFF (EXPECT_*, used by assertions 2/3/4/5).
EXPECT_APP_MFA_ENABLED="false"
EXPECT_APP_MFA_FRESHNESS_WINDOW="600000"
EXPECT_APP_MFA_ENFORCE_PRIVILEGED_FLOOR="false"
# COMPOSE dev stack: enforcement ON, floor still off (CEXPECT_*, assertion 6).
CEXPECT_APP_MFA_ENABLED="true"
CEXPECT_APP_MFA_FRESHNESS_WINDOW="600000"
CEXPECT_APP_MFA_ENFORCE_PRIVILEGED_FLOOR="false"
# Guard against a future edit that quietly collapses the asymmetry by editing both
# tables to agree: the whole reason this file has two tables is that these differ.
[ "${EXPECT_APP_MFA_ENABLED}" != "${CEXPECT_APP_MFA_ENABLED}" ] || {
  echo "  FAIL the chart and compose expectation tables agree on APP_MFA_ENABLED"
  echo "       (=${EXPECT_APP_MFA_ENABLED}). The posture is ASYMMETRIC BY DESIGN:"
  echo "       cluster OFF, dev stack ON. One of the two tables was mis-edited."
  exit 2
}

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 missing"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML missing (pip install pyyaml)"; exit 2; }
# ── PREFLIGHT: every external tool, checked BEFORE any assertion runs ─────────
# This gate's CI job runs in `python:3-slim`, which is not a full userland, and the
# script deliberately runs under `set -uo pipefail` WITHOUT `-e` so that one failed
# assertion does not hide the rest. Those two facts together mean a MISSING TOOL
# would not stop the run — it would DISTORT it: an absent `sort` empties a set
# comparison (a "failure" for a plumbing reason), an absent `find` makes discovery
# look broken, an absent `cp` silently produces no mutant at all. A distorted tally
# is worse than no tally, so refuse to produce one.
missing=""
for t in awk find sort tr sed grep wc cut mktemp cp rm mkdir; do
  command -v "${t}" >/dev/null 2>&1 || missing="${missing} ${t}"
done
[ -z "${missing}" ] || {
  echo "  FAIL required tool(s) not on PATH:${missing}"
  echo "       This gate needs them for discovery (find), set comparison (sort/tr/sed),"
  echo "       and staging its negative controls (cp/mkdir/mktemp). Install them in the"
  echo "       CI image (Debian: coreutils findutils gawk sed grep) — running without"
  echo "       them would report a pass/fail count that means nothing."
  exit 2
}
[ -n "${BASH_VERSION:-}" ] || { echo "  FAIL this gate needs bash (arrays, mapfile), not sh"; exit 2; }
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || {
  echo "  FAIL bash >= 4 required (mapfile is a bash-4 builtin); found '${BASH_VERSION}'"; exit 2; }
for f in "${CHART}/values.yaml" "${CHART}/templates/deployment.yaml" "${COMPOSE}" "${M2_COMPOSE}" "${EXTRACT}" "${ROOT_APP}" "${APPS[@]}"; do
  [ -f "${f}" ] || { echo "  FAIL missing input ${f}"; exit 2; }
done
# The chart path every path comparison below comes down to, canonicalised through
# the SAME code the audit rows go through (the extractor's norm_chart_path, exposed
# as `normpath`). An expectation spelled differently from the data it is compared
# against is not a comparison at all — that is precisely how a fifth gateway
# Application spelled `./specs/cluster/charts/hugmesh-gateway` read as "not a
# gateway" and shipped green.
CHART_REL_CANON="$(python3 "${EXTRACT}" normpath "${CHART_REL}")"
[ -n "${CHART_REL_CANON}" ] || { echo "  FAIL could not canonicalise CHART_REL='${CHART_REL}'"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

# …and PROVE the two behaviours a bare `command -v` does NOT prove actually work
# here: `cp -a` on a DIRECTORY (how every negative control stages its mutant) and
# `mapfile` (a builtin, so `command -v` above would not have caught its absence).
mkdir -p "${WORK}/pre/d" && : > "${WORK}/pre/d/f"
{ cp -a "${WORK}/pre/d" "${WORK}/pre/copy" 2>/dev/null && [ -f "${WORK}/pre/copy/f" ]; } || {
  echo "  FAIL 'cp -a <dir> <dir>' does not work here — every negative control stages its"
  echo "       mutant with it, and a control that never got staged is a fake pass"; exit 2; }
mapfile -t _pre < <(printf 'b\na\nb\n' | sort -u)
{ [ "${#_pre[@]}" = "2" ] && [ "${_pre[0]:-}" = "a" ]; } || {
  echo "  FAIL 'mapfile' + 'sort -u' do not behave here (got ${#_pre[@]} line(s): ${_pre[*]:-})"
  echo "       — app discovery and every set comparison in this gate depend on both"; exit 2; }

echo "== gateway MFA-enforcement env trio: emission + default-OFF gate =="

# ── helpers ──────────────────────────────────────────────────────────────────
render_chart() {  # <chart-dir> <app.yaml>... ; TSV to stdout, rc = extractor rc
  python3 "${EXTRACT}" chart "$@"
}
render_compose() { # <compose-file> <service>...
  python3 "${EXTRACT}" compose "$@"
}
# EVERY file ArgoCD's `directory: {recurse: true}` source would read under a dir:
# .yaml, .yml and .json, at ANY depth. Anything narrower is a hole the audit cannot
# see through (assertion 4c pins the root app to that source shape).
discover_apps() { # <dir>
  find "$1" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) | sort
}
# value of <release> <ENV> from a TSV render file ("" when absent)
cell() { awk -F'\t' -v r="$2" -v n="$3" '$1==r && $2==n {print $3}' "$1"; }
qual() { awk -F'\t' -v r="$2" -v n="$3" '$1==r && $2==n {print $4}' "$1"; }
# resolved compose value of <service> <ENV>
cres() { awk -F'\t' -v s="$2" -v n="$3" '$1==s && $2==n {print $4}' "$1"; }
craw() { awk -F'\t' -v s="$2" -v n="$3" '$1==s && $2==n {print $3}' "$1"; }
expect_for()  { eval "printf '%s' \"\${EXPECT_$1}\""; }   # chart/cluster side
cexpect_for() { eval "printf '%s' \"\${CEXPECT_$1}\""; }  # compose dev-stack side

# assertion (3)+(4)+(5) over a render file; echoes nothing, rc 0 iff all hold.
# Used both on the real tree and on the staged mutants (so the negative controls
# exercise the SAME predicate the positive assertions do).
render_all_default_off() { # <tsv>
  local rel n
  for rel in "${RELEASES[@]}"; do
    for n in "${TRIO[@]}"; do
      [ "$(cell "$1" "${rel}" "${n}")" = "$(expect_for "${n}")" ] || return 1
    done
  done
  return 0
}
render_all_emitted() { # <tsv> — the three vars present (any value) for every release
  local rel n
  for rel in "${RELEASES[@]}"; do
    for n in "${TRIO[@]}"; do
      awk -F'\t' -v r="${rel}" -v x="${n}" '$1==r && $2==x {found=1} END{exit !found}' "$1" || return 1
    done
  done
  return 0
}
render_all_quoted() { # <tsv>
  local rel n
  for rel in "${RELEASES[@]}"; do
    for n in "${TRIO[@]}"; do
      [ "$(qual "$1" "${rel}" "${n}")" = "quoted" ] || return 1
    done
  done
  return 0
}

# assertion (6) reduced to ONE per-item predicate, so the positive assertion and
# the negative controls (8e/8f) cannot drift apart: both call this. Echoes the
# empty string when the item is exactly right, else the human reason it is not.
compose_item_problem() { # <tsv> <service> <ENV>
  local raw res want
  raw="$(craw "$1" "$2" "$3")"; res="$(cres "$1" "$2" "$3")"; want="$(cexpect_for "$3")"
  if [ -z "${raw}" ]; then
    echo "NOT SET (the local stack cannot reach gateway MFA enforcement)"
  elif [ "${raw}" != "\${$3:-${want}}" ]; then
    echo "is '${raw}', not the house style \${$3:-${want}}"
  elif [ "${res}" != "${want}" ]; then
    echo "resolves to '${res}' with the var unset (expected ${want}) — DEV-STACK POSTURE BROKEN"
  fi
}
compose_all_expected() { # <tsv> — rc 0 iff every gateway service/var is right
  local svc n
  for svc in "${GW_SERVICES[@]}"; do
    for n in "${TRIO[@]}"; do
      [ -z "$(compose_item_problem "$1" "${svc}" "${n}")" ] || return 1
    done
  done
  return 0
}

# assertion (4b) predicates over an `apps` TSV. Same shape as the render_* ones:
# the positive assertion and the 8g..8m controls share them. `APP|APPSET` on every
# one of them: an ApplicationSet template is an Application spec and gets the same
# treatment (see the extractor's mode_apps).
apps_mfa_on_hits() {  # <tsv> — one "file/release=repr" per Application that is ON
  awk -F'\t' '($1=="APP"||$1=="APPSET") && $4=="MFA_ENABLED" && $5=="ON" {print $2"/"$3"="$6}' "$1"
}
apps_none_on() { [ -z "$(apps_mfa_on_hits "$1")" ]; }
apps_hand_env_hits() { # <tsv> — Applications smuggling an APP_MFA_* var in by hand
  awk -F'\t' '($1=="APP"||$1=="APPSET") && $4=="APP_MFA_ENV" && $5=="SET" {print $2"/"$3"="$6}' "$1"
}
apps_no_hand_env() { [ -z "$(apps_hand_env_hits "$1")" ]; }
# NB every one of the three below keys on the CANONICAL chart path (column 5 of the
# CHART_PATH row; column 6 keeps the raw spelling for the humans). ArgoCD resolves
# source.path against the repo root, so `./x`, `x/`, `.//x` and `x/./y` are ONE
# directory. Keying on the raw string meant a fifth gateway spelled any of the
# non-canonical ways was not a "gateway consumer" here at all, so it escaped this
# check, the release check AND the opaque-input check below — and shipped GREEN
# while carrying a valueFiles entry whose MFA value nothing here can read.
apps_gateway_chart_files() { # <tsv> — sorted paths of apps deploying the chart
  awk -F'\t' -v c="${CHART_REL_CANON}" '($1=="APP"||$1=="APPSET") && $4=="CHART_PATH" && $5==c {print $2}' "$1" \
    | sort -u | tr '\n' ' ' | sed 's/ $//'
}
# …and the RELEASES they deploy, which is the axis (3)/(4)/(5) actually iterate. The
# file-keyed check above cannot see a SECOND Application added inside one of the four
# files it already expects, and such a release would render un-asserted.
apps_gateway_chart_releases() { # <tsv>
  awk -F'\t' -v c="${CHART_REL_CANON}" '($1=="APP"||$1=="APPSET") && $4=="CHART_PATH" && $5==c {print $3}' "$1" \
    | sort -u | tr '\n' ' ' | sed 's/ $//'
}
# Gateway Applications whose helm values this gate CANNOT read (valueFiles /
# fileParameters resolve from the source repo at render time). Such an input is not
# "off", it is UNKNOWN, and an unknown must not be reported as compliance.
apps_opaque_gateway_hits() { # <tsv>
  awk -F'\t' -v c="${CHART_REL_CANON}" '
    ($1=="APP"||$1=="APPSET") && $4=="CHART_PATH"  && $5==c        { gw[$2"/"$3] = 1 }
    ($1=="APP"||$1=="APPSET") && $4=="HELM_OPAQUE" && $5=="OPAQUE" { op[$2"/"$3] = $6 }
    END { for (k in op) if (k in gw) print k"="op[k] }
  ' "$1"
}
apps_no_opaque_gateway() { [ -z "$(apps_opaque_gateway_hits "$1")" ]; }
# MULTI-SOURCE Applications (spec.sources) are NOT MODELLED and must say so. The
# chart path, the release name and the helm values can each live in a different
# entry of that list, so picking one and rendering it attributes an env posture to
# a release the model never actually resolved — which surfaced as a pile of
# "(3) NOT emitted" / "(5) NOT quoted" failures naming env vars that are not
# missing at all. Report the real reason instead.
# SCOPED TO GATEWAY-CHART CONSUMERS. This gate models the gateway chart; a multi-source
# Application for an unrelated service (chart from a Helm repo + values from a git ref — a
# very common ArgoCD shape) is provably NOT a gateway consumer and must not redden the
# gateway MFA gate and block someone else's MR. emit_app_audit already writes a CHART_PATH
# row PER SOURCE, so "does any of this app's sources resolve to the gateway chart" is
# answerable without modelling multi-source at all. A multi-source app that DOES reach the
# gateway chart is still reported — that is the case the assertion exists for.
apps_multisource_hits() { # <tsv>
  awk -F'\t' -v c="${CHART_REL_CANON}" '
    ($1=="APP"||$1=="APPSET") && $4=="CHART_PATH"  && $5==c    { gw[$2"/"$3] = 1 }
    ($1=="APP"||$1=="APPSET") && $4=="SOURCE_FORM" && $5=="MULTI" { ms[$2"/"$3] = $6 }
    END { for (k in ms) if (k in gw) print k"("ms[k]" sources)" }
  ' "$1" | sort
}
apps_no_multisource() { [ -z "$(apps_multisource_hits "$1")" ]; }
# the value-input forms a given file/release actually used (proves the reader looked
# at the right field rather than at nothing at all)
apps_forms() { # <tsv> <file-basename>
  awk -F'\t' -v f="$2" '($1=="APP"||$1=="APPSET") && $2==f && $4=="HELM_FORMS" {print $5}' "$1"
}
# assertion (6b): the gateway services compose.local.yaml itself declares
compose_gw_discovered() { # <compose-file>
  python3 "${EXTRACT}" compose-gateways "$1" | awk -F'\t' '$1=="GWSVC" {print $2}' \
    | sort -u | tr '\n' ' ' | sed 's/ $//'
}
sorted_list() { printf '%s\n' "$@" | sort -u | tr '\n' ' ' | sed 's/ $//'; }

# ── 1) the four Applications really do share ONE chart ───────────────────────
echo "-- 1) shared-chart premise --"
if render_chart "${CHART}" "${APPS[@]}" > "${WORK}/render.tsv" 2>"${WORK}/render.err"; then
  ok "(1) chart+apps evaluated (4 Applications + bare chart defaults)"
else
  bad "(1) extractor FAILED: $(tr -d '\n' <"${WORK}/render.err" | cut -c1-300)"
  echo "== RESULT: ${P} passed, ${F} failed =="; exit 1
fi
for rel in "${CLUSTER_RELEASES[@]}"; do
  p="$(awk -F'\t' -v r="${rel}" '$1=="#CHART-PATH" && $2==r {print $3}' "${WORK}/render.tsv")"
  [ "${p}" = "${CHART_REL_CANON}" ] \
    && ok "(1) ${rel} deploys ${CHART_REL_CANON}" \
    || bad "(1) ${rel} chart path is '${p}', not ${CHART_REL_CANON} — the one-place mfa: block would NOT reach it"
done
# (1) THE CANONICALISER ITSELF. Every chart-path comparison in this file — the
# shared-chart premise above, the gateway-consumer set, the release set and the
# opaque-input check — is only as good as norm_chart_path(). If it ever degrades
# to identity (the defect: `./x` != `x`) those comparisons silently stop matching
# real gateways; if it over-normalises (a prefix or basename match) they start
# sweeping in charts ArgoCD treats as separate. Pin BOTH directions here, so the
# fix cannot rot into either failure mode without this line going red.
SAME_SPELLINGS=("${CHART_REL}" "./${CHART_REL}" "${CHART_REL}/" ".//${CHART_REL}" \
                "specs/cluster/charts/./hugmesh-gateway" "/${CHART_REL}" \
                "specs/nope/../cluster/charts/hugmesh-gateway")
DIFF_PATHS=("${CHART_REL}-canary" "${CHART_REL}/subchart" "specs/cluster/charts/hugmesh-gateway2" \
            "specs/cluster/charts/other" "hugmesh-gateway")
mapfile -t NORMED < <(python3 "${EXTRACT}" normpath "${SAME_SPELLINGS[@]}" "${DIFF_PATHS[@]}")
norm_bad=""
if [ "${#NORMED[@]}" -ne "$(( ${#SAME_SPELLINGS[@]} + ${#DIFF_PATHS[@]} ))" ]; then
  norm_bad=" the normpath mode returned ${#NORMED[@]} lines for $(( ${#SAME_SPELLINGS[@]} + ${#DIFF_PATHS[@]} )) paths"
else
  for i in "${!SAME_SPELLINGS[@]}"; do
    [ "${NORMED[$i]}" = "${CHART_REL_CANON}" ] \
      || norm_bad="${norm_bad} SAME('${SAME_SPELLINGS[$i]}')->'${NORMED[$i]}'"
  done
  for j in "${!DIFF_PATHS[@]}"; do
    k=$(( ${#SAME_SPELLINGS[@]} + j ))
    [ "${NORMED[$k]}" != "${CHART_REL_CANON}" ] \
      || norm_bad="${norm_bad} DISTINCT('${DIFF_PATHS[$j]}')->'${NORMED[$k]}'"
  done
fi
[ -z "${norm_bad}" ] \
  && ok "(1) chart-path canonicaliser: ${#SAME_SPELLINGS[@]} ArgoCD-equivalent spellings all collapse to ${CHART_REL_CANON}, and ${#DIFF_PATHS[@]} genuinely different charts stay distinct" \
  || bad "(1) chart-path canonicaliser is WRONG:${norm_bad} — every gateway-consumer comparison keys on it; see norm_chart_path in the extractor"
n_charts="$(find "${REPO}/specs/cluster/charts" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[ "${n_charts}" = "1" ] \
  && ok "(1) specs/cluster/charts holds exactly one chart (no sibling gateway chart to keep in sync)" \
  || bad "(1) specs/cluster/charts now holds ${n_charts} charts — re-check that all four gateways still share one"

# ── 2) chart values declare the trio with the image defaults ─────────────────
echo "-- 2) chart values.yaml mfa: block --"
python3 - "$CHART/values.yaml" <<'PY' > "${WORK}/values.txt" 2>"${WORK}/values.err"
import sys, yaml
v = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
m = v.get("mfa")
if not isinstance(m, dict):
    print("NO-MFA-BLOCK"); raise SystemExit(0)
print("enabled=%r" % (m.get("enabled", "MISSING"),))
print("freshnessWindow=%r" % (m.get("freshnessWindow", "MISSING"),))
print("enforcePrivilegedFloor=%r" % (m.get("enforcePrivilegedFloor", "MISSING"),))
PY
grep -qx 'enabled=False' "${WORK}/values.txt" \
  && ok "(2) values.yaml mfa.enabled: false (boolean, not the string \"false\")" \
  || bad "(2) values.yaml mfa.enabled is not boolean false: $(grep '^enabled=' "${WORK}/values.txt" || cat "${WORK}/values.txt")"
grep -qx 'freshnessWindow=600000' "${WORK}/values.txt" \
  && ok "(2) values.yaml mfa.freshnessWindow: 600000 (the image default, 10 min)" \
  || bad "(2) values.yaml mfa.freshnessWindow wrong: $(grep '^freshnessWindow=' "${WORK}/values.txt" || echo absent)"
grep -qx 'enforcePrivilegedFloor=False' "${WORK}/values.txt" \
  && ok "(2) values.yaml mfa.enforcePrivilegedFloor: false" \
  || bad "(2) values.yaml mfa.enforcePrivilegedFloor wrong: $(grep '^enforcePrivilegedFloor=' "${WORK}/values.txt" || echo absent)"

# ── 3/4/5) emission, default-OFF, quoting ────────────────────────────────────
echo "-- 3) emission: all three vars for all four releases + chart defaults --"
for rel in "${RELEASES[@]}"; do
  miss=""
  for n in "${TRIO[@]}"; do
    awk -F'\t' -v r="${rel}" -v x="${n}" '$1==r && $2==x {found=1} END{exit !found}' "${WORK}/render.tsv" \
      || miss="${miss} ${n}"
  done
  [ -z "${miss}" ] && ok "(3) ${rel}: all 3 APP_MFA_* env vars emitted" \
                   || bad "(3) ${rel}: NOT emitted:${miss}"
done

# SCOPE: this section is the CLUSTER side ONLY — it reads render.tsv, which is
# chart values deep-merged with each Application's helm values. The compose dev
# stack is asserted separately (and to the OPPOSITE value) in (6).
echo "-- 4) cluster side is OFF: false / 600000 / false for all four instances --"
for rel in "${RELEASES[@]}"; do
  for n in "${TRIO[@]}"; do
    got="$(cell "${WORK}/render.tsv" "${rel}" "${n}")"; want="$(expect_for "${n}")"
    [ "${got}" = "${want}" ] && ok "(4) ${rel} ${n}=${got}" \
                             || bad "(4) ${rel} ${n}=${got:-<absent>} (expected ${want}) — CLUSTER DEFAULT-OFF BROKEN"
  done
done
# ── 4b) NO cluster Application may turn MFA on — the regression this gate is for
# Widened past the four gateway files on purpose: an mfa: block in ANY app is a
# posture change worth failing on, and a FIFTH gateway instance added elsewhere
# would otherwise dodge (3)/(4)/(5) entirely. DISCOVERY IS ARGOCD'S, not a glob of
# convenience: recursive, .yaml + .yml + .json (see discover_apps and 4c).
echo "-- 4b) nothing ArgoCD syncs from specs/cluster/apps turns MFA on --"
mapfile -t ALL_APPS < <(discover_apps "${APPS_DIR}")
if [ "${#ALL_APPS[@]}" -lt "${#GW_APP_FILES[@]}" ]; then
  bad "(4b) only ${#ALL_APPS[@]} files under ${APPS_DIR} — discovery broken, audit would be vacuous"
elif python3 "${EXTRACT}" apps --root "${APPS_DIR}" "${ALL_APPS[@]}" > "${WORK}/apps.tsv" 2>"${WORK}/apps.err"; then
  n_app_docs="$(awk -F'\t' '($1=="APP"||$1=="APPSET") && $4=="MFA_ENABLED"' "${WORK}/apps.tsv" | wc -l | tr -d ' ')"
  # NON-VACUITY: the audit is only meaningful if it actually parsed Applications.
  [ "${n_app_docs}" -ge "${#GW_APP_FILES[@]}" ] \
    && ok "(4b) audited ${n_app_docs} Application/ApplicationSet specs across ${#ALL_APPS[@]} discovered files" \
    || bad "(4b) only ${n_app_docs} Applications parsed out of ${#ALL_APPS[@]} files — audit is vacuous"

  apps_none_on "${WORK}/apps.tsv" \
    && ok "(4b) NO Application sets mfa.enabled ON (cluster enablement stays an explicit operator action)" \
    || bad "(4b) an Application TURNS MFA ON: $(apps_mfa_on_hits "${WORK}/apps.tsv" | tr '\n' ' ') — this is the exact regression (4b) exists to catch; cluster MFA must be flipped by an operator, never committed"

  apps_no_hand_env "${WORK}/apps.tsv" \
    && ok "(4b) no Application hand-sets an APP_MFA_* var (the chart's mfa: block is the only source)" \
    || bad "(4b) an Application hand-sets APP_MFA_*: $(apps_hand_env_hits "${WORK}/apps.tsv" | tr '\n' ' ') — that bypasses the chart block"

  # the set of gateway-chart consumers must be EXACTLY the four this test asserts
  want_files="$(sorted_list "${GW_APP_FILES[@]}")"
  got_files="$(apps_gateway_chart_files "${WORK}/apps.tsv")"
  [ "${got_files}" = "${want_files}" ] \
    && ok "(4b) exactly these apps deploy ${CHART_REL}: ${got_files}" \
    || bad "(4b) gateway-chart consumers changed: got '${got_files}', asserted '${want_files}' — add the new instance to GW_APP_FILES or it escapes assertions 3/4/5"

  # …and the same on the RELEASE axis, which is the one (3)/(4)/(5) iterate. A second
  # Application inside an already-expected FILE passes the check above untouched.
  want_rels="$(sorted_list "${CLUSTER_RELEASES[@]}")"
  got_rels="$(apps_gateway_chart_releases "${WORK}/apps.tsv")"
  [ "${got_rels}" = "${want_rels}" ] \
    && ok "(4b) exactly these releases deploy ${CHART_REL}: ${got_rels}" \
    || bad "(4b) gateway-chart releases changed: got '${got_rels}', asserted '${want_rels}' — add it to CLUSTER_RELEASES or it renders with nothing asserting its APP_MFA_* values"

  # NO OPAQUE INPUT on a gateway Application. valueFiles/fileParameters resolve
  # from the source repo when the repo-server renders, so this file cannot know
  # what they say — and "cannot know" must read as a failure, not as default-off.
  apps_no_opaque_gateway "${WORK}/apps.tsv" \
    && ok "(4b) every gateway Application's helm values are fully readable here (no valueFiles/fileParameters)" \
    || bad "(4b) a gateway Application feeds helm an input this gate CANNOT read: $(apps_opaque_gateway_hits "${WORK}/apps.tsv" | tr '\n' ' ') — resolve it inline or extend the extractor; an un-auditable input must not pass as default-off"

  # MULTI-SOURCE IS OUT OF SCOPE AND SAYS SO. `spec.sources` can put the chart
  # path in one entry and the helm values in another, so this model cannot say
  # which source is the gateway — and it will not guess. Before this assertion
  # existed such an Application still failed the suite, but through assertions
  # (3)/(5) complaining that env vars were "NOT emitted"/"NOT quoted", which sends
  # the reader looking for a missing env var that is not missing.
  apps_no_multisource "${WORK}/apps.tsv" \
    && ok "(4b) every audited Application uses the single spec.source form this gate models" \
    || bad "(4b) MULTI-SOURCE APPLICATION (spec.sources) — NOT MODELLED BY THIS GATE: $(apps_multisource_hits "${WORK}/apps.tsv" | tr '\n' ' ')— the chart path and the helm values may live in different sources, so nothing here can say what MFA value this Application renders. Give it a single spec.source, or extend gateway_mfa_env.py to model spec.sources. Multi-source support is deliberately NOT implemented; any (3)/(5) 'NOT emitted'/'NOT quoted' failures alongside this line are a CONSEQUENCE of it, not a missing env var"

  # READER NON-VACUITY: all four gateway apps must be seen to use `values`. If the
  # extractor ever stopped finding the field (renamed key, changed nesting) every
  # posture row above would read UNSET and the whole audit would pass on nothing.
  forms_bad=""
  for f in "${GW_APP_FILES[@]}"; do
    # apps_forms emits ONE LINE PER Application in the file; EVERY one of them has
    # to have a readable input, so this greps for a line that does NOT (-qv), which
    # also covers "no lines at all". A `case` over the joined output would silently
    # stop matching the moment a file grew a second Application.
    forms_got="$(apps_forms "${WORK}/apps.tsv" "${f}")"
    if [ -z "${forms_got}" ] || printf '%s\n' "${forms_got}" | grep -qvE '(^|,)values(,|$)'; then
      forms_bad="${forms_bad} ${f}:[$(printf '%s' "${forms_got}" | tr '\n' '|')]"
    fi
  done
  [ -z "${forms_bad}" ] \
    && ok "(4b) the reader really does see each gateway Application's helm values input" \
    || bad "(4b) no readable helm value input found for:${forms_bad} — the audit would report UNSET for everything and pass vacuously"
else
  bad "(4b) apps audit FAILED: $(tr -d '\n' <"${WORK}/apps.err" | cut -c1-300)"
fi

# ── 4c) the DISCOVERY MODEL matches the root app-of-apps ─────────────────────
# (4b) claims to see everything ArgoCD syncs. That is only true while the root app
# really is a recursive directory source over specs/cluster/apps with no
# include/exclude filter. Assert it instead of assuming it.
echo "-- 4c) the app-of-apps source shape (4b)'s discovery models --"
python3 - "${ROOT_APP}" <<'PY' >"${WORK}/root.txt" 2>&1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if isinstance(d, dict)]
app = next((d for d in docs if d.get("kind") == "Application"), None)
if app is None:
    print("NO-APPLICATION"); raise SystemExit(0)
src = (app.get("spec") or {}).get("source") or {}
d = src.get("directory") or {}
print("path=%s" % src.get("path"))
print("recurse=%r" % (d.get("recurse"),))
narrowing = [k for k in ("include", "exclude", "jsonnet") if k in d]
print("filters=%s" % (",".join(narrowing) if narrowing else "NONE"))
PY
grep -qx 'path=specs/cluster/apps' "${WORK}/root.txt" \
  && ok "(4c) app-of-apps syncs specs/cluster/apps (the directory (4b) walks)" \
  || bad "(4c) app-of-apps path is not specs/cluster/apps: $(grep '^path=' "${WORK}/root.txt" || cat "${WORK}/root.txt") — (4b) is auditing the wrong directory"
grep -qx 'recurse=True' "${WORK}/root.txt" \
  && ok "(4c) it recurses, so (4b) must too (and does — subdirectories are walked)" \
  || bad "(4c) app-of-apps recurse is $(grep '^recurse=' "${WORK}/root.txt") — re-check discover_apps against the new shape"
grep -qx 'filters=NONE' "${WORK}/root.txt" \
  && ok "(4c) no include/exclude/jsonnet filter narrows what ArgoCD reads" \
  || bad "(4c) app-of-apps now filters what it reads ($(grep '^filters=' "${WORK}/root.txt")) — discover_apps no longer models it"

echo "-- 5) | quote on all three (an unquoted bool makes the manifest un-appliable) --"
for rel in "${RELEASES[@]}"; do
  for n in "${TRIO[@]}"; do
    [ "$(qual "${WORK}/render.tsv" "${rel}" "${n}")" = "quoted" ] \
      && ok "(5) ${rel} ${n} rendered through | quote" \
      || bad "(5) ${rel} ${n} is NOT quoted — API server would reject a YAML boolean here"
  done
done

# ── 6) compose.local.yaml ────────────────────────────────────────────────────
echo "-- 6) compose.local.yaml gateway services --"
if render_compose "${COMPOSE}" "${GW_SERVICES[@]}" > "${WORK}/compose.tsv" 2>"${WORK}/compose.err"; then
  ok "(6) compose.local.yaml parsed (anchors + merge keys resolved)"
else
  bad "(6) compose extraction FAILED: $(tr -d '\n' <"${WORK}/compose.err" | cut -c1-300)"
fi
for svc in "${GW_SERVICES[@]}"; do
  for n in "${TRIO[@]}"; do
    why="$(compose_item_problem "${WORK}/compose.tsv" "${svc}" "${n}")"
    if [ -z "${why}" ]; then
      ok "(6) ${svc}: ${n}=$(craw "${WORK}/compose.tsv" "${svc}" "${n}") -> $(cres "${WORK}/compose.tsv" "${svc}" "${n}") when unset"
    else
      bad "(6) ${svc}: ${n} ${why}"
    fi
  done
done
# ── 6b) the audited gateway list IS the whole gateway list ───────────────────
# (4b)'s consumer check, for compose. GW_SERVICES above is hand-written; re-derive
# it from the compose file and fail if a gateway exists that (6) never looked at.
gw_want="$(sorted_list "${GW_SERVICES[@]}")"
gw_got="$(compose_gw_discovered "${COMPOSE}")"
if [ -z "${gw_got}" ]; then
  bad "(6b) gateway-service DISCOVERY found nothing in ${COMPOSE##*/} — the check is vacuous; see mode_compose_gateways (build context / image slug / *-gateway name)"
elif [ "${gw_got}" = "${gw_want}" ]; then
  ok "(6b) the gateway services compose declares are exactly the ones audited: ${gw_got}"
else
  bad "(6b) compose gateway services are '${gw_got}' but this test audits '${gw_want}' — a dev-stack gateway with no APP_MFA_* trio cannot reach the enforcement leg; add it to GW_SERVICES (and give it the trio)"
fi

# and state the asymmetry as its own assertion, so the intent is in the output and
# not only in a comment somebody can delete.
if [ "$(cres "${WORK}/compose.tsv" hugmesh-fe-gateway APP_MFA_ENABLED)" = "true" ] \
   && [ "$(cell "${WORK}/render.tsv" hugmesh-fe-gateway APP_MFA_ENABLED)" = "false" ]; then
  ok "(6) ASYMMETRY HELD: dev stack ON (compose true) while cluster stays OFF (chart false)"
else
  bad "(6) ASYMMETRY LOST: compose='$(cres "${WORK}/compose.tsv" hugmesh-fe-gateway APP_MFA_ENABLED)' cluster='$(cell "${WORK}/render.tsv" hugmesh-fe-gateway APP_MFA_ENABLED)' — must be true/false respectively"
fi

# ── 7) the m2 build-args override stays env-free ─────────────────────────────
echo "-- 7) compose.m2-local.yaml is a build-args-only override --"
python3 - "${M2_COMPOSE}" <<'PY' >"${WORK}/m2.txt" 2>&1
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
bad = [n for n, s in (d.get("services") or {}).items() if (s or {}).get("environment") is not None]
print("ENV-FREE" if not bad else "HAS-ENV: " + ",".join(sorted(bad)))
PY
grep -qx 'ENV-FREE' "${WORK}/m2.txt" \
  && ok "(7) no service in compose.m2-local.yaml declares environment: (it inherits compose.local.yaml's on merge)" \
  || bad "(7) compose.m2-local.yaml grew runtime env — a second place to drift: $(cat "${WORK}/m2.txt")"

# ── 7b) no dangling docs/ reference in the files this gate owns ──────────────
# A comment promising `docs/MFA-ROLLOUT.md` when no such file ships is a lie the
# reader only discovers by going to look — and the MFA posture is exactly the kind
# of decision a reader follows a link to understand. That reference really did ship
# here pointing at nothing. Nothing else in this repo gates doc links, so this gate
# checks the handful of files it owns.
echo "-- 7b) no dangling docs/*.md reference in the files this gate owns --"
# The deployable files this gate is responsible for. NOT this script and NOT the
# extractor: both name non-existent doc paths ON PURPOSE — the defect being
# described above and (8p)'s sentinel — so scanning them would be self-defeating.
OWNED=("${CHART}/values.yaml" "${CHART}/templates/deployment.yaml" "${COMPOSE}" \
       "${M2_COMPOSE}" "${ROOT_APP}" "${APPS[@]}")
doc_refs() { # <file>... -> "<basename>\t<docs/path>" per distinct reference
  local f d
  for f in "$@"; do
    grep -oE 'docs/[A-Za-z0-9._/-]+\.md' "${f}" 2>/dev/null | sort -u | while read -r d; do
      printf '%s\t%s\n' "${f##*/}" "${d}"
    done
  done
}
docs_dangling() { # <file>... -> the references that resolve to nothing
  doc_refs "$@" | while IFS=$'\t' read -r f d; do
    [ -f "${REPO}/${d}" ] || printf '%s->%s ' "${f}" "${d}"
  done
}
n_refs="$(doc_refs "${OWNED[@]}" | wc -l | tr -d ' ')"
dangling="$(docs_dangling "${OWNED[@]}")"
if [ "${n_refs}" = "0" ]; then
  bad "(7b) not one docs/*.md reference found across the ${#OWNED[@]} owned files — the scan is vacuous, check doc_refs"
elif [ -z "${dangling}" ]; then
  ok "(7b) all ${n_refs} docs/*.md references in the ${#OWNED[@]} owned files resolve to a file that ships"
else
  bad "(7b) dangling doc reference(s): ${dangling}— name the flags and the precondition inline instead of promising a document this branch does not ship"
fi

# ── 8) NEGATIVE CONTROLS (staged copies; the repo tree is NEVER mutated) ─────
echo "-- 8) negative controls: every assertion must bite --"
stage_chart() { # <name> -> echoes the staged chart dir
  local d="${WORK}/chart-$1"; rm -rf "${d}"; cp -a "${CHART}" "${d}"; echo "${d}"
}
stage_apps() { # <name> -> echoes a staged copy of the WHOLE apps dir
  local d="${WORK}/apps-$1"; rm -rf "${d}"; mkdir -p "${d}"
  cp -a "${APPS_DIR}/." "${d}/"; echo "${d}"
}
# A mutator that silently fails to find its target turns its control into a FAKE
# PASS — which is exactly what happened to the old (8e): it searched for
# `${APP_MFA_ENABLED:-false}`, the file said `:-true`, the replace was a no-op, and
# the "mutant" was a byte-identical copy that "passed" for the wrong reason. So
# EVERY mutator below exits non-zero when it cannot find its target, and every
# control checks that rc before drawing any conclusion.
mut_ok() { # <rc> <label> ; rc 0 iff the mutation landed
  [ "$1" -eq 0 ] && return 0
  bad "($2) MUTATOR DID NOT LAND (target text absent) — control NOT exercised, so the assertion it guards is unproven"
  return 1
}

# 8a) values.yaml flipped ON -> cluster default-OFF must fail (emission still pass)
D="$(stage_chart on)"
python3 - "${D}/values.yaml" <<'PY'
import sys
# Anchored INSIDE the top-level `mfa:` block, not "the first 2-space enabled: false
# in the file" — values.yaml has five such rows (keystore/ingress/autoscaling/...)
# and an unanchored count=1 replace would silently mutate whichever came first.
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().splitlines(keepends=True)
start = next((i for i, l in enumerate(lines) if l.rstrip("\n") == "mfa:"), None)
if start is None:
    raise SystemExit("mutation 8a: no top-level `mfa:` key in values.yaml")
hit = None
for i in range(start + 1, len(lines)):
    bare = lines[i].rstrip("\n")
    if bare and not bare[0].isspace() and not bare.startswith("#"):
        break  # left the mfa block
    if bare == "  enabled: false":
        hit = i
        break
if hit is None:
    raise SystemExit("mutation 8a: no `  enabled: false` inside the mfa: block")
lines[hit] = "  enabled: true\n"
open(p, "w", encoding="utf-8").writelines(lines)
PY
MRC=$?
if mut_ok ${MRC} 8a; then
if render_chart "${D}" "${APPS[@]}" > "${WORK}/on.tsv" 2>/dev/null; then
  render_all_emitted "${WORK}/on.tsv" \
    && ok "(8a) mutant still EMITS the trio (the mutation is narrow: value only)" \
    || bad "(8a) mutant broke emission too — control not isolating default-OFF"
  render_all_default_off "${WORK}/on.tsv" \
    && bad "(8a) CLUSTER DEFAULT-OFF CHECK VACUOUS: it passed on a values.yaml with mfa.enabled: true" \
    || ok "(8a) cluster default-OFF check bites: mfa.enabled: true mutant FAILS it"
else
  bad "(8a) staged on-mutant failed to render (control not exercised)"
fi
fi

# 8b) delete the APP_MFA_ENABLED env row -> emission must fail
D="$(stage_chart norow)"
python3 - "${D}/templates/deployment.yaml" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
row = ("            - name: APP_MFA_ENABLED\n"
       "              value: {{ .Values.mfa.enabled | quote }}\n")
if row not in s:
    raise SystemExit("mutation 8b: the APP_MFA_ENABLED env row is not where expected")
open(p, "w", encoding="utf-8").write(s.replace(row, "", 1))
PY
MRC=$?
if mut_ok ${MRC} 8b; then
if render_chart "${D}" "${APPS[@]}" > "${WORK}/norow.tsv" 2>/dev/null; then
  render_all_emitted "${WORK}/norow.tsv" \
    && bad "(8b) EMISSION CHECK VACUOUS: it passed with the APP_MFA_ENABLED row deleted" \
    || ok "(8b) emission check bites: deleting the APP_MFA_ENABLED row FAILS it"
else
  bad "(8b) staged norow-mutant failed to render (control not exercised)"
fi
fi

# 8c) typo the .Values path -> the extractor must FAIL LOUD (proves the render
#     really resolves against values.yaml instead of matching template text)
D="$(stage_chart typo)"
python3 - "${D}/templates/deployment.yaml" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
old = ".Values.mfa.enabled | quote"
if old not in s:
    raise SystemExit("mutation 8c: '" + old + "' not in deployment.yaml")
open(p, "w", encoding="utf-8").write(s.replace(old, ".Values.mfa.enabledd | quote", 1))
PY
MRC=$?
if mut_ok ${MRC} 8c; then
if render_chart "${D}" "${APPS[@]}" > "${WORK}/typo.tsv" 2>"${WORK}/typo.err"; then
  bad "(8c) RENDER IS A STRING MATCH: a .Values.mfa.enabledd typo still rendered rc=0"
else
  grep -q 'does not resolve' "${WORK}/typo.err" \
    && ok "(8c) render resolves against values.yaml: a typo'd .Values path fails loud" \
    || bad "(8c) typo failed but for the wrong reason: $(tr -d '\n' <"${WORK}/typo.err" | cut -c1-200)"
fi
fi

# 8d) drop `| quote` -> the quoting check must fail
D="$(stage_chart noquote)"
python3 - "${D}/templates/deployment.yaml" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
old = "{{ .Values.mfa.enabled | quote }}"
if old not in s:
    raise SystemExit("mutation 8d: '" + old + "' not in deployment.yaml")
open(p, "w", encoding="utf-8").write(s.replace(old, "{{ .Values.mfa.enabled }}", 1))
PY
MRC=$?
if mut_ok ${MRC} 8d; then
if render_chart "${D}" "${APPS[@]}" > "${WORK}/noquote.tsv" 2>/dev/null; then
  render_all_quoted "${WORK}/noquote.tsv" \
    && bad "(8d) QUOTING CHECK VACUOUS: it passed with | quote removed" \
    || ok "(8d) quoting check bites: removing | quote FAILS it"
else
  bad "(8d) staged noquote-mutant failed to render (control not exercised)"
fi
fi

# 8e) compose default flipped to FALSE -> the DEV-STACK-ON check must fail.
#     INVERTED from the original, which flipped :-false -> :-true back when the dev
#     stack was also default-off. `true` is the real state now, so mutating TOWARDS
#     it mutates nothing; the meaningful mutation is turning the dev stack OFF.
cp "${COMPOSE}" "${WORK}/compose-off.yaml"
python3 - "${WORK}/compose-off.yaml" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
old = "${APP_MFA_ENABLED:-true}"
n = s.count(old)
if n != 3:
    raise SystemExit("mutation 8e: expected 3 occurrences of %r (one per gateway "
                     "service), found %d" % (old, n))
open(p, "w", encoding="utf-8").write(s.replace(old, "${APP_MFA_ENABLED:-false}"))
PY
MRC=$?
if mut_ok ${MRC} 8e; then
  if render_compose "${WORK}/compose-off.yaml" "${GW_SERVICES[@]}" > "${WORK}/compose-off.tsv" 2>/dev/null; then
    res="$(cres "${WORK}/compose-off.tsv" hugmesh-fe-gateway APP_MFA_ENABLED)"
    # exercise the SAME predicate assertion (6) uses, not a lookalike
    if compose_all_expected "${WORK}/compose-off.tsv"; then
      bad "(8e) DEV-STACK-ON CHECK VACUOUS: assertion 6's predicate passed on a compose with APP_MFA_ENABLED defaulting to '${res}'"
    else
      ok "(8e) dev-stack-ON check bites: flipping the compose default to '${res}' FAILS assertion 6's predicate"
    fi
  else
    bad "(8e) staged compose-off mutant failed to parse (control not exercised)"
  fi
fi

# 8f) strip the trio from one compose service -> that service's check must fail
cp "${COMPOSE}" "${WORK}/compose-strip.yaml"
python3 - "${WORK}/compose-strip.yaml" <<'PY'
import re
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
# Remove ONLY the fe-gateway stanza's three rows: the LAST occurrence of each trio
# row belongs to fe-gateway, the third and final gateway service in the file. The
# default is matched with a regex rather than hard-coded, so this control keeps
# working when the dev-stack defaults change (a hard-coded `:-false` here is what
# silently broke it the last time the posture moved).
for var in ("APP_MFA_ENABLED", "APP_MFA_FRESHNESS_WINDOW", "APP_MFA_ENFORCE_PRIVILEGED_FLOOR"):
    pat = re.compile(r"(?m)^[ \t]*%s:[ \t]*\$\{%s:-[^}\n]*\}[ \t]*\n" % (var, var))
    hits = list(pat.finditer(s))
    if len(hits) != 3:
        raise SystemExit("mutation 8f: expected 3 %s rows (one per gateway service), "
                         "found %d" % (var, len(hits)))
    last = hits[-1]
    s = s[:last.start()] + s[last.end():]
open(p, "w", encoding="utf-8").write(s)
PY
MRC=$?
if mut_ok ${MRC} 8f; then
  render_compose "${WORK}/compose-strip.yaml" "${GW_SERVICES[@]}" > "${WORK}/compose-strip.tsv" 2>/dev/null
  n_rows="$(awk -F'\t' '$1=="hugmesh-fe-gateway"' "${WORK}/compose-strip.tsv" | wc -l | tr -d ' ')"
  if [ "${n_rows}" != "0" ]; then
    bad "(8f) fe-gateway still reports ${n_rows} APP_MFA_* rows after stripping them"
  elif compose_all_expected "${WORK}/compose-strip.tsv"; then
    bad "(8f) COMPOSE EMISSION CHECK VACUOUS: assertion 6's predicate passed with fe-gateway's trio deleted"
  else
    ok "(8f) compose emission check bites: stripping fe-gateway's trio FAILS assertion 6's predicate"
  fi
fi

# 8g) an Application that flips mfa.enabled -> (4b) must fail. TWO variants,
#     because the bare boolean and the QUOTED STRING both reach the JVM as
#     enabling once the template's `| quote` has run, and a check that only
#     recognises the boolean would wave `enabled: "true"` straight through.
for variant in bool str; do
  case "${variant}" in
    bool) inject="mfa:\n  enabled: true\n"   ; label="8g" ; shown="true"   ;;
    str)  inject="mfa:\n  enabled: \"true\"\n"; label="8h" ; shown='"true"' ;;
  esac
  AD="$(stage_apps "${variant}")"
  INJECT="${inject}" python3 - "${AD}/22-gateway-superadmin.yaml" <<'PY'
import os
import sys
import yaml

p = sys.argv[1]
docs = list(yaml.safe_load_all(open(p, encoding="utf-8")))
apps = [d for d in docs if isinstance(d, dict) and d.get("kind") == "Application"]
if not apps:
    raise SystemExit("mutation 8g/8h: no kind:Application in " + p)
helm = apps[0].setdefault("spec", {}).setdefault("source", {}).setdefault("helm", {})
before = helm.get("values") or ""
if "mfa:" in yaml.safe_dump(yaml.safe_load(before) or {}):
    raise SystemExit("mutation 8g/8h: this Application ALREADY declares mfa: — the "
                     "staged tree is not the clean baseline the control assumes")
helm["values"] = before + os.environ["INJECT"].replace("\\n", "\n")
with open(p, "w", encoding="utf-8") as fh:
    yaml.safe_dump_all(docs, fh, default_flow_style=False, sort_keys=False)
PY
  MRC=$?
  if mut_ok ${MRC} "${label}"; then
    mapfile -t MUT_APPS < <(discover_apps "${AD}")
    if python3 "${EXTRACT}" apps --root "${AD}" "${MUT_APPS[@]}" > "${WORK}/apps-${variant}.tsv" 2>"${WORK}/apps-${variant}.err"; then
      if apps_none_on "${WORK}/apps-${variant}.tsv"; then
        bad "(${label}) CLUSTER-APPS CHECK VACUOUS: it passed with an Application setting mfa.enabled: ${shown}"
      else
        ok "(${label}) cluster-apps check bites: mfa.enabled: ${shown} in an Application FAILS it ($(apps_mfa_on_hits "${WORK}/apps-${variant}.tsv" | tr '\n' ' '))"
      fi
    else
      bad "(${label}) staged apps mutant failed to audit: $(tr -d '\n' <"${WORK}/apps-${variant}.err" | cut -c1-200)"
    fi
  fi
done

# 8i/8j/8k) THE OTHER HELM VALUE INPUTS. 8g/8h prove the check bites on the
#   `values` STRING; on its own that proved nothing about the four OTHER ways an
#   ArgoCD Application can hand helm the same flag, and a `valuesObject:` block
#   really did switch MFA on for a gateway with the whole suite green. One control
#   per form, so no form can quietly stop being covered:
#     8i valuesObject (structured values, deep-merged over `values`)
#     8j parameters   (== helm --set, applied last, beats everything)
#     8k valueFiles   (content lives in the source repo — UNREADABLE from here, so
#                      the assertion under test is the OPAQUE one, not mfa-on)
for form in valuesObject parameters valueFiles; do
  case "${form}" in
    valuesObject) label="8i"; shown='valuesObject: {mfa: {enabled: true}}' ;;
    parameters)   label="8j"; shown='parameters: [{name: mfa.enabled, value: "true"}]' ;;
    valueFiles)   label="8k"; shown='valueFiles: [mfa-on.yaml]' ;;
  esac
  AD="$(stage_apps "${form}")"
  FORM="${form}" python3 - "${AD}/20-gateway-pki.yaml" <<'PY'
import os
import sys
import yaml

p = sys.argv[1]
form = os.environ["FORM"]
docs = list(yaml.safe_load_all(open(p, encoding="utf-8")))
apps = [d for d in docs if isinstance(d, dict) and d.get("kind") == "Application"]
if not apps:
    raise SystemExit("mutation 8i/8j/8k: no kind:Application in " + p)
helm = apps[0].setdefault("spec", {}).setdefault("source", {}).setdefault("helm", {})
if form in helm:
    raise SystemExit("mutation 8i/8j/8k: this Application ALREADY declares %s — the "
                     "staged tree is not the clean baseline the control assumes" % form)
if form == "valuesObject":
    helm["valuesObject"] = {"mfa": {"enabled": True}}
elif form == "parameters":
    helm["parameters"] = [{"name": "mfa.enabled", "value": "true"}]
else:
    helm["valueFiles"] = ["mfa-on.yaml"]
with open(p, "w", encoding="utf-8") as fh:
    yaml.safe_dump_all(docs, fh, default_flow_style=False, sort_keys=False)
PY
  MRC=$?
  if mut_ok ${MRC} "${label}"; then
    mapfile -t MUT_APPS < <(discover_apps "${AD}")
    MUT_GW=(); for f in "${GW_APP_FILES[@]}"; do MUT_GW+=("${AD}/${f}"); done
    if ! python3 "${EXTRACT}" apps --root "${AD}" "${MUT_APPS[@]}" > "${WORK}/apps-${form}.tsv" 2>"${WORK}/apps-${form}.err"; then
      bad "(${label}) staged apps mutant failed to audit: $(tr -d '\n' <"${WORK}/apps-${form}.err" | cut -c1-200)"
    elif [ "${form}" = "valueFiles" ]; then
      if apps_no_opaque_gateway "${WORK}/apps-${form}.tsv"; then
        bad "(${label}) OPAQUE-INPUT CHECK VACUOUS: a gateway Application with ${shown} read as compliant"
      else
        ok "(${label}) opaque-input check bites: ${shown} on a gateway Application FAILS it ($(apps_opaque_gateway_hits "${WORK}/apps-${form}.tsv" | tr '\n' ' ')) — mfa.enabled itself is UNSET there, so without this assertion it was a silent pass"
      fi
    else
      # (4b): the posture audit must see the flag whatever form it arrives in
      if apps_none_on "${WORK}/apps-${form}.tsv"; then
        bad "(${label}) CLUSTER-APPS CHECK BLIND TO ${form}: it passed with an Application setting ${shown}"
      else
        ok "(${label}) cluster-apps check bites through ${form}: ${shown} FAILS it ($(apps_mfa_on_hits "${WORK}/apps-${form}.tsv" | tr '\n' ' '))"
      fi
      # (4)/(3): and the RENDER must resolve the same override, or the emission
      # section would report the posture it wishes were true.
      if render_chart "${CHART}" "${MUT_GW[@]}" > "${WORK}/render-${form}.tsv" 2>/dev/null; then
        render_all_default_off "${WORK}/render-${form}.tsv" \
          && bad "(${label}) CLUSTER DEFAULT-OFF CHECK BLIND TO ${form}: assertion 4's predicate passed on a render overridden via ${form}" \
          || ok "(${label}) assertion 4's predicate bites through ${form}: hugmesh-pki-gateway renders APP_MFA_ENABLED=$(cell "${WORK}/render-${form}.tsv" hugmesh-pki-gateway APP_MFA_ENABLED)"
      else
        bad "(${label}) staged ${form} mutant failed to render (control not exercised)"
      fi
    fi
  fi
done

# 8l/8m) A FIFTH GATEWAY INSTANCE, hidden where the old `-maxdepth 1 -name '*.yaml'`
#   discovery could not look. ArgoCD's directory source reads .yaml, .yml AND .json,
#   RECURSIVELY (4c pins that the root app really is such a source), so both of
#   these are files ArgoCD would sync with MFA ON:
#     8l  a `.yml` extension in the same directory
#     8m  a `.yaml` in a SUBdirectory
#     8o  a subdirectory file wearing a DECLARED gateway's basename — the case a
#         basename-keyed label would report as the legitimate root-level file, which
#         is why the audit labels rows with the path relative to the apps dir
#   The header used to claim a fifth gateway "cannot be added and quietly escape".
#   It could, three ways over, until these controls existed.
for hidden in ext subdir shadow; do
  case "${hidden}" in
    ext)    label="8l"; rel="26-gateway-rogue.yml"        ;;
    subdir) label="8m"; rel="extra/27-gateway-rogue.yaml" ;;
    shadow) label="8o"; rel="extra/20-gateway-be.yaml"    ;;
  esac
  AD="$(stage_apps "${hidden}")"
  python3 - "${AD}/20-gateway-pki.yaml" "${AD}/${rel}" <<'PY'
import os
import sys
import yaml

src, dst = sys.argv[1], sys.argv[2]
docs = list(yaml.safe_load_all(open(src, encoding="utf-8")))
apps = [d for d in docs if isinstance(d, dict) and d.get("kind") == "Application"]
if not apps:
    raise SystemExit("mutation 8l/8m: no kind:Application in " + src)
app = apps[0]
app.setdefault("metadata", {})["name"] = "hugmesh-gateway-rogue"
helm = app.setdefault("spec", {}).setdefault("source", {}).setdefault("helm", {})
helm["releaseName"] = "hugmesh-rogue-gateway"
before = helm.get("values") or ""
if "mfa:" in yaml.safe_dump(yaml.safe_load(before) or {}):
    raise SystemExit("mutation 8l/8m: the model Application ALREADY declares mfa: — "
                     "the staged tree is not the clean baseline the control assumes")
helm["values"] = before + "mfa:\n  enabled: true\n"
os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
with open(dst, "w", encoding="utf-8") as fh:
    yaml.safe_dump_all([app], fh, default_flow_style=False, sort_keys=False)
if not os.path.isfile(dst):
    raise SystemExit("mutation 8l/8m: did not create " + dst)
PY
  MRC=$?
  if mut_ok ${MRC} "${label}"; then
    mapfile -t MUT_APPS < <(discover_apps "${AD}")
    # the mutation only counts if DISCOVERY actually reached the planted file
    if ! printf '%s\n' "${MUT_APPS[@]}" | grep -qx -- "${AD}/${rel}"; then
      bad "(${label}) discovery did NOT reach the planted ${rel} — that is the bug this control exists for; discover_apps must match ArgoCD (recursive, .yaml/.yml/.json)"
    elif ! python3 "${EXTRACT}" apps --root "${AD}" "${MUT_APPS[@]}" > "${WORK}/apps-${hidden}.tsv" 2>"${WORK}/apps-${hidden}.err"; then
      bad "(${label}) staged apps mutant failed to audit: $(tr -d '\n' <"${WORK}/apps-${hidden}.err" | cut -c1-200)"
    else
      apps_none_on "${WORK}/apps-${hidden}.tsv" \
        && bad "(${label}) CLUSTER-APPS CHECK ESCAPED: a fifth gateway at ${rel} turned MFA on and the audit passed" \
        || ok "(${label}) a fifth gateway at ${rel} is caught: $(apps_mfa_on_hits "${WORK}/apps-${hidden}.tsv" | tr '\n' ' ')"
      [ "$(apps_gateway_chart_files "${WORK}/apps-${hidden}.tsv")" = "$(sorted_list "${GW_APP_FILES[@]}")" ] \
        && bad "(${label}) CONSUMER-SET CHECK ESCAPED: ${rel} deploys ${CHART_REL} but the consumer set still read as the asserted four" \
        || ok "(${label}) consumer-set check bites: ${rel} shows up as an undeclared gateway-chart consumer"
    fi
  fi
done

# 8n) A NEW COMPOSE GATEWAY SERVICE with no APP_MFA_* trio. Assertion (6) iterates
#   the hand-written GW_SERVICES list, so this service is not merely non-compliant,
#   it is NOT LOOKED AT — the compose twin of the hole (4b)'s consumer check closes.
#   (6b) is what has to bite here.
cp "${COMPOSE}" "${WORK}/compose-newgw.yaml"
python3 - "${WORK}/compose-newgw.yaml" <<'PY'
import sys
import yaml

p = sys.argv[1]
doc = yaml.safe_load(open(p, encoding="utf-8")) or {}
svcs = doc.get("services") or {}
name = "hugmesh-superadmin-gateway"
if name in svcs:
    raise SystemExit("mutation 8n: %s is already a compose service — pick a name the "
                     "file does not use, or the control proves nothing" % name)
model = svcs.get("hugmesh-pki-gateway")
if not isinstance(model, dict) or not model.get("build"):
    raise SystemExit("mutation 8n: no hugmesh-pki-gateway service to model the new "
                     "gateway on")
# A gateway by construction (same build context = the hugmesh-gateway repo) that
# declares NO APP_MFA_* var at all.
svcs[name] = {"build": dict(model["build"]),
              "environment": {"SPRING_APPLICATION_NAME": name, "PORT": "8080"}}
doc["services"] = svcs
with open(p, "w", encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh, default_flow_style=False, sort_keys=False)
PY
MRC=$?
if mut_ok ${MRC} 8n; then
  mut_got="$(compose_gw_discovered "${WORK}/compose-newgw.yaml")"
  # A REAL FILE, not a process substitution: compose_item_problem reads the render
  # twice (craw + cres) and a <(…) FIFO is consumed by the first read, which would
  # make (6)'s predicate "fail" for a plumbing reason and hide the point below.
  render_compose "${WORK}/compose-newgw.yaml" "${GW_SERVICES[@]}" \
    > "${WORK}/compose-newgw.tsv" 2>/dev/null
  if [ "${mut_got}" = "$(sorted_list "${GW_SERVICES[@]}")" ]; then
    bad "(8n) COMPOSE CONSUMER-SET CHECK VACUOUS: a fourth gateway service was added and discovery still returned '${mut_got}'"
  elif compose_all_expected "${WORK}/compose-newgw.tsv"; then
    ok "(8n) compose consumer-set check bites: discovery returns '${mut_got}' while (6) audits only '$(sorted_list "${GW_SERVICES[@]}")' — and (6)'s own predicate still PASSED on this mutant, which is exactly why (6b) exists"
  else
    bad "(8n) the 8n mutant also broke assertion (6) ($(for n in "${TRIO[@]}"; do compose_item_problem "${WORK}/compose-newgw.tsv" hugmesh-fe-gateway "${n}"; done | tr '\n' ' ')) — the control is no longer isolating the CONSUMER-SET hole it exists for"
  fi
fi

# 8q) a SECOND gateway Application inside a file the test already expects. The
#     file-keyed consumer check cannot see this (the file is on the list), the render
#     assertions iterate CLUSTER_RELEASES so they never touch the new release, and
#     (4b)'s mfa-on scan only fires if the new instance also flips the flag — so
#     until the release-axis check existed, a fifth gateway added this way rendered
#     with nothing asserting its APP_MFA_* values at all. Verified by mutation: this
#     mutant scored a clean 89/0 before that assertion was added.
AD="$(stage_apps second-app)"
python3 - "${AD}/20-gateway-be.yaml" <<'PY'
import copy
import sys
import yaml

p = sys.argv[1]
docs = [d for d in yaml.safe_load_all(open(p, encoding="utf-8")) if isinstance(d, dict)]
apps = [d for d in docs if d.get("kind") == "Application"]
if len(apps) != 1:
    raise SystemExit("mutation 8q: expected exactly 1 Application in %s, found %d — the "
                     "staged tree is not the clean baseline the control assumes"
                     % (p, len(apps)))
second = copy.deepcopy(apps[0])
second["metadata"]["name"] = "hugmesh-gateway-be-companion"
second["spec"]["source"]["helm"]["releaseName"] = "hugmesh-be-gateway-companion"
docs.append(second)
with open(p, "w", encoding="utf-8") as fh:
    yaml.safe_dump_all(docs, fh, default_flow_style=False, sort_keys=False)
PY
MRC=$?
if mut_ok ${MRC} 8q; then
  mapfile -t MUT_APPS < <(discover_apps "${AD}")
  if ! python3 "${EXTRACT}" apps --root "${AD}" "${MUT_APPS[@]}" > "${WORK}/apps-2nd.tsv" 2>"${WORK}/apps-2nd.err"; then
    bad "(8q) staged apps mutant failed to audit: $(tr -d '\n' <"${WORK}/apps-2nd.err" | cut -c1-200)"
  elif [ "$(apps_gateway_chart_files "${WORK}/apps-2nd.tsv")" != "$(sorted_list "${GW_APP_FILES[@]}")" ]; then
    bad "(8q) the 8q mutant changed the FILE set too — it is no longer isolating the RELEASE axis it exists for"
  elif [ "$(apps_gateway_chart_releases "${WORK}/apps-2nd.tsv")" = "$(sorted_list "${CLUSTER_RELEASES[@]}")" ]; then
    bad "(8q) RELEASE-AXIS CHECK VACUOUS: a second gateway Application in 20-gateway-be.yaml left the release set unchanged"
  else
    ok "(8q) release-axis check bites: a second Application in an already-expected file shows up as the undeclared release(s) '$(apps_gateway_chart_releases "${WORK}/apps-2nd.tsv")' while the FILE set is unchanged"
  fi
fi

# 8r) THE SAME CHART, SPELLED DIFFERENTLY. ArgoCD resolves source.path against the
#   repo root, so `specs/…/hugmesh-gateway`, `./specs/…`, `specs/…/`, `.//specs/…`
#   and `specs/cluster/charts/./hugmesh-gateway` are ONE directory — the identical
#   chart, the identical MFA values. The consumer/release/opaque checks used to
#   compare that path as a RAW STRING, so four of those five spellings were not
#   "gateway" here at all: a fifth gateway Application carrying an UNREADABLE
#   valueFiles value scored a clean 91/0. Each spelling gets its own control, and
#   each plants the escape in its strongest form — mfa.enabled is set NOWHERE the
#   audit can see it, so the chart-agnostic mfa-on scan cannot save the gate; only
#   recognising the app as a gateway consumer can.
#   Each control measures the gateway sets on its OWN staged tree BEFORE planting
#   and again after, and asserts the delta. Comparing against the hard-coded
#   GW_APP_FILES/CLUSTER_RELEASES instead would make the control depend on the real
#   tree being pristine — it would "bite" merely because the working tree already
#   had a fifth gateway in it, which proves nothing about path spelling.
audit_staged() { # <staged-apps-dir> <tsv-out> ; rc = extractor rc
  local ad="$2" out="$3"
  mapfile -t _AS_APPS < <(discover_apps "$1")
  python3 "${EXTRACT}" apps --root "$1" "${_AS_APPS[@]}" > "${ad}" 2>"${out}"
}
spell_i=0
for spell in "${CHART_REL}" "./${CHART_REL}" "${CHART_REL}/" ".//${CHART_REL}" \
             "specs/cluster/charts/./hugmesh-gateway"; do
  spell_i=$((spell_i+1)); label="8r.${spell_i}"
  AD="$(stage_apps "spell${spell_i}")"
  # BASELINE first, from this staged tree, before anything is planted in it.
  if ! audit_staged "${AD}" "${WORK}/apps-spell${spell_i}-base.tsv" "${WORK}/apps-spell${spell_i}.err"; then
    bad "(${label}) baseline audit of the staged apps dir FAILED: $(tr -d '\n' <"${WORK}/apps-spell${spell_i}.err" | cut -c1-200)"
    continue
  fi
  base_files="$(apps_gateway_chart_files "${WORK}/apps-spell${spell_i}-base.tsv")"
  base_rels="$(apps_gateway_chart_releases "${WORK}/apps-spell${spell_i}-base.tsv")"
  base_on="$(apps_mfa_on_hits "${WORK}/apps-spell${spell_i}-base.tsv" | sort | tr '\n' ' ')"
  # The planted names carry the control's own id so they cannot collide with
  # anything already in the tree — a collision on releaseName would leave the
  # release set unchanged and this control would fail for a reason that has
  # nothing to do with path spelling.
  SPELL="${spell}" CANON="${CHART_REL_CANON}" EXTRACT="${EXTRACT}" PYTHONDONTWRITEBYTECODE=1 REL="hugmesh-8r${spell_i}-probe-gateway" \
  python3 - "${AD}/20-gateway-pki.yaml" "${AD}/26-gateway-8r${spell_i}-probe.yaml" <<'PY'
import os
import sys
import yaml

src, dst = sys.argv[1], sys.argv[2]
docs = list(yaml.safe_load_all(open(src, encoding="utf-8")))
apps = [d for d in docs if isinstance(d, dict) and d.get("kind") == "Application"]
if not apps:
    raise SystemExit("mutation 8r: no kind:Application in " + src)
app = apps[0]
app.setdefault("metadata", {})["name"] = os.environ["REL"]
source = app.setdefault("spec", {}).setdefault("source", {})
# Canonicalise BOTH sides through the extractor's one implementation. Comparing the
# model app's path as a RAW STRING is the exact defect this gate exists to catch, and
# having it here meant a maintainer spelling the DECLARED path any blessed-equivalent
# way (./specs/…, trailing slash, …) made six controls refuse to plant and reddened a
# perfectly good tree. Fail-closed, so never an escape — but a self-inflicted false RED.
sys.path.insert(0, os.path.dirname(os.environ["EXTRACT"]))
from gateway_mfa_env import norm_chart_path
if norm_chart_path(source.get("path") or "") != os.environ["CANON"]:
    raise SystemExit("mutation 8r: the model Application points at %r, not the gateway chart "
                     "%r — the staged tree is not the baseline this control assumes"
                     % (source.get("path"), os.environ["CANON"]))
source["path"] = os.environ["SPELL"]
helm = source.setdefault("helm", {})
helm["releaseName"] = os.environ["REL"]
if "valueFiles" in helm:
    raise SystemExit("mutation 8r: the model Application ALREADY declares valueFiles")
# THE UNREADABLE VALUE. mfa.enabled appears nowhere the audit can read, so this
# rogue is invisible to the mfa-on scan by construction: the ONLY things that can
# catch it are the gateway-consumer sets and the opaque-input check, all three of
# which key on the chart path.
helm["valueFiles"] = ["../../overlays/mfa-on.yaml"]
with open(dst, "w", encoding="utf-8") as fh:
    yaml.safe_dump_all([app], fh, default_flow_style=False, sort_keys=False)
if not os.path.isfile(dst):
    raise SystemExit("mutation 8r: did not create " + dst)
PY
  MRC=$?
  if mut_ok ${MRC} "${label}"; then
    if ! audit_staged "${AD}" "${WORK}/apps-spell${spell_i}.tsv" "${WORK}/apps-spell${spell_i}.err"; then
      bad "(${label}) staged apps mutant failed to audit: $(tr -d '\n' <"${WORK}/apps-spell${spell_i}.err" | cut -c1-200)"
    else
      escaped=""
      [ "$(apps_gateway_chart_files "${WORK}/apps-spell${spell_i}.tsv")" != "${base_files}" ] \
        || escaped="${escaped} consumer-FILE-set-unchanged"
      [ "$(apps_gateway_chart_releases "${WORK}/apps-spell${spell_i}.tsv")" != "${base_rels}" ] \
        || escaped="${escaped} consumer-RELEASE-set-unchanged"
      apps_no_opaque_gateway "${WORK}/apps-spell${spell_i}.tsv" && escaped="${escaped} opaque-input-check-silent"
      # …and the mfa-on scan must NOT be what caught it, or this control would be
      # proving something other than path canonicalisation. (Compared to the same
      # staged tree's own baseline, so a pre-existing hit elsewhere is not read as
      # this plant being caught.)
      [ "$(apps_mfa_on_hits "${WORK}/apps-spell${spell_i}.tsv" | sort | tr '\n' ' ')" = "${base_on}" ] \
        || escaped="${escaped} caught-by-mfa-on-instead(control-not-isolating)"
      [ -z "${escaped}" ] \
        && ok "(${label}) a fifth gateway whose chart path is spelled '${spell}' is still recognised as a gateway-chart consumer, and its unreadable valueFiles FAILS the audit" \
        || bad "(${label}) PATH-SPELLING ESCAPE: a fifth gateway at path '${spell}' with an UNREADABLE MFA value slipped past —${escaped}; canonicalise source.path (norm_chart_path) on BOTH sides before comparing"
    fi
  fi
done

# 8s) …and the OPPOSITE direction, so the fix for 8r cannot be "call everything a
#   gateway". A rogue pointing at a DIFFERENT chart directory — one ArgoCD would
#   render from a different chart entirely — must stay OUT of the gateway sets. A
#   canonicaliser that degraded into a prefix/substring/basename match would pass
#   8r and fail here.
AD="$(stage_apps other-chart)"
OTHER_CHART="${CHART_REL}-canary"
other_ok=1
if ! audit_staged "${AD}" "${WORK}/apps-other-base.tsv" "${WORK}/apps-other.err"; then
  bad "(8s) baseline audit of the staged apps dir FAILED: $(tr -d '\n' <"${WORK}/apps-other.err" | cut -c1-200)"
  other_ok=0
fi
obase_files="$(apps_gateway_chart_files "${WORK}/apps-other-base.tsv" 2>/dev/null)"
obase_rels="$(apps_gateway_chart_releases "${WORK}/apps-other-base.tsv" 2>/dev/null)"
obase_opaque="$(apps_opaque_gateway_hits "${WORK}/apps-other-base.tsv" 2>/dev/null | sort | tr '\n' ' ')"
SPELL="${OTHER_CHART}" CANON="${CHART_REL_CANON}" EXTRACT="${EXTRACT}" PYTHONDONTWRITEBYTECODE=1 REL="hugmesh-8s-probe-gateway" \
python3 - "${AD}/20-gateway-pki.yaml" "${AD}/26-gateway-8s-probe.yaml" <<'PY'
import os
import sys
import yaml

src, dst = sys.argv[1], sys.argv[2]
docs = list(yaml.safe_load_all(open(src, encoding="utf-8")))
apps = [d for d in docs if isinstance(d, dict) and d.get("kind") == "Application"]
if not apps:
    raise SystemExit("mutation 8s: no kind:Application in " + src)
app = apps[0]
app.setdefault("metadata", {})["name"] = os.environ["REL"]
source = app.setdefault("spec", {}).setdefault("source", {})
# Same canonicalisation as 8r — raw-string comparison here was a self-inflicted false RED.
sys.path.insert(0, os.path.dirname(os.environ["EXTRACT"]))
from gateway_mfa_env import norm_chart_path
if norm_chart_path(source.get("path") or "") != os.environ["CANON"]:
    raise SystemExit("mutation 8s: the model Application points at %r, not the gateway chart"
                     % (source.get("path"),))
source["path"] = os.environ["SPELL"]
helm = source.setdefault("helm", {})
helm["releaseName"] = os.environ["REL"]
helm["valueFiles"] = ["../../overlays/mfa-on.yaml"]
with open(dst, "w", encoding="utf-8") as fh:
    yaml.safe_dump_all([app], fh, default_flow_style=False, sort_keys=False)
PY
MRC=$?
if [ "${other_ok}" = "1" ] && mut_ok ${MRC} 8s; then
  if ! audit_staged "${AD}" "${WORK}/apps-other.tsv" "${WORK}/apps-other.err"; then
    bad "(8s) staged apps mutant failed to audit: $(tr -d '\n' <"${WORK}/apps-other.err" | cut -c1-200)"
  else
    swept=""
    [ "$(apps_gateway_chart_files "${WORK}/apps-other.tsv")" = "${obase_files}" ] \
      || swept="${swept} FILE-set:'$(apps_gateway_chart_files "${WORK}/apps-other.tsv")'"
    [ "$(apps_gateway_chart_releases "${WORK}/apps-other.tsv")" = "${obase_rels}" ] \
      || swept="${swept} RELEASE-set:'$(apps_gateway_chart_releases "${WORK}/apps-other.tsv")'"
    [ "$(apps_opaque_gateway_hits "${WORK}/apps-other.tsv" | sort | tr '\n' ' ')" = "${obase_opaque}" ] \
      || swept="${swept} opaque:'$(apps_opaque_gateway_hits "${WORK}/apps-other.tsv" | tr '\n' ' ')'"
    [ -z "${swept}" ] \
      && ok "(8s) canonicalisation is not over-broad: an Application at ${OTHER_CHART} is NOT counted as a ${CHART_REL_CANON} consumer" \
      || bad "(8s) OVER-NORMALISED: an Application deploying ${OTHER_CHART} was swept into the gateway-chart sets —${swept}; norm_chart_path must canonicalise spelling only, never match on prefix or basename"
  fi
fi

# 8t) A MULTI-SOURCE Application (spec.sources). Deliberately NOT modelled: the
#   chart path, the releaseName and the helm values can each sit in a different
#   entry of that list, so any render this model produced for it would describe a
#   source it picked arbitrarily. What this control pins is the MESSAGE — the
#   failure has to say "multi-source is not modelled", because what it used to say
#   was a pile of "(3) NOT emitted" / "(5) NOT quoted" naming env vars that were
#   never missing, which is a false trail through the chart and deployment.yaml.
AD="$(stage_apps multisource)"
python3 - "${AD}/20-gateway-pki.yaml" <<'PY'
import sys
import yaml

p = sys.argv[1]
docs = list(yaml.safe_load_all(open(p, encoding="utf-8")))
apps = [d for d in docs if isinstance(d, dict) and d.get("kind") == "Application"]
if not apps:
    raise SystemExit("mutation 8t: no kind:Application in " + p)
spec = apps[0].setdefault("spec", {})
if "sources" in spec:
    raise SystemExit("mutation 8t: this Application is ALREADY multi-source — the staged "
                     "tree is not the clean baseline the control assumes")
source = spec.pop("source", None)
if not isinstance(source, dict) or not source:
    raise SystemExit("mutation 8t: no spec.source to convert into spec.sources")
# The realistic shape: a values-only `ref` source alongside the chart source, which
# is what makes "which source is the gateway?" unanswerable by position.
spec["sources"] = [
    {"repoURL": source.get("repoURL"), "targetRevision": source.get("targetRevision"), "ref": "vals"},
    source,
]
with open(p, "w", encoding="utf-8") as fh:
    yaml.safe_dump_all(docs, fh, default_flow_style=False, sort_keys=False)
PY
MRC=$?
if mut_ok ${MRC} 8t; then
  mapfile -t MUT_APPS < <(discover_apps "${AD}")
  if ! python3 "${EXTRACT}" apps --root "${AD}" "${MUT_APPS[@]}" > "${WORK}/apps-ms.tsv" 2>"${WORK}/apps-ms.err"; then
    bad "(8t) staged apps mutant failed to audit: $(tr -d '\n' <"${WORK}/apps-ms.err" | cut -c1-200)"
  elif apps_no_multisource "${WORK}/apps-ms.tsv"; then
    bad "(8t) MULTI-SOURCE CHECK VACUOUS: a spec.sources Application read as the single-source form this gate models"
  else
    ok "(8t) multi-source is REPORTED, not guessed at: $(apps_multisource_hits "${WORK}/apps-ms.tsv" | tr '\n' ' ')"
  fi
  MUT_GW=(); for f in "${GW_APP_FILES[@]}"; do MUT_GW+=("${AD}/${f}"); done
  if render_chart "${CHART}" "${MUT_GW[@]}" > "${WORK}/render-ms.tsv" 2>"${WORK}/render-ms.err"; then
    bad "(8t) the chart render ACCEPTED a multi-source Application and emitted rows for it — those rows describe whichever source the model happened to pick first"
  elif grep -q 'MULTI-SOURCE APPLICATIONS ARE NOT MODELLED' "${WORK}/render-ms.err"; then
    ok "(8t) the chart render refuses a multi-source Application by NAME: $(tr -d '\n' <"${WORK}/render-ms.err" | cut -c1-150)…"
  else
    bad "(8t) the chart render failed on a multi-source Application but never SAID it was multi-source — that is the confusing failure mode this control exists to prevent: $(tr -d '\n' <"${WORK}/render-ms.err" | cut -c1-200)"
  fi
fi

# 8p) a dangling docs/ reference -> (7b) must bite. Same predicate (7b) uses, on a
#     staged copy, so the two cannot drift apart.
cp "${COMPOSE}" "${WORK}/compose-dangling.yaml"
python3 - "${WORK}/compose-dangling.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
ref = "docs/THIS-DOC-DOES-NOT-EXIST.md"
if ref in s:
    raise SystemExit("mutation 8p: %s is somehow already referenced" % ref)
open(p, "a", encoding="utf-8").write("\n# See %s for the rollout runbook.\n" % ref)
PY
MRC=$?
if mut_ok ${MRC} 8p; then
  if [ -z "$(docs_dangling "${WORK}/compose-dangling.yaml")" ]; then
    bad "(8p) DOC-REFERENCE CHECK VACUOUS: a reference to docs/THIS-DOC-DOES-NOT-EXIST.md read as resolving"
  else
    ok "(8p) doc-reference check bites: $(docs_dangling "${WORK}/compose-dangling.yaml")FAILS assertion 7b's predicate"
  fi
fi

# ── 9) cross-check the model against real helm, when helm exists ─────────────
echo "-- 9) cross-check vs real 'helm template' --"
if command -v helm >/dev/null 2>&1; then
  hfail=0
  for i in 0 1 2 3; do
    app="${APPS[$i]}"
    rel="$(python3 -c "
import sys,yaml
for d in yaml.safe_load_all(open(sys.argv[1],encoding='utf-8')):
    if isinstance(d,dict) and d.get('kind')=='Application':
        print(d['spec']['source']['helm']['releaseName']); break
" "${app}")"
    python3 -c "
import sys,yaml
for d in yaml.safe_load_all(open(sys.argv[1],encoding='utf-8')):
    if isinstance(d,dict) and d.get('kind')=='Application':
        sys.stdout.write(d['spec']['source']['helm']['values'] or ''); break
" "${app}" > "${WORK}/vals-${rel}.yaml"
    if ! helm template "${rel}" "${CHART}" -f "${WORK}/vals-${rel}.yaml" \
         > "${WORK}/helm-${rel}.yaml" 2>"${WORK}/helm-${rel}.err"; then
      bad "(9) helm template ${rel} failed: $(tr -d '\n' <"${WORK}/helm-${rel}.err" | cut -c1-200)"
      hfail=1; continue
    fi
    for n in "${TRIO[@]}"; do
      want="$(cell "${WORK}/render.tsv" "${rel}" "${n}")"
      got="$(grep -A1 -- "- name: ${n}$" "${WORK}/helm-${rel}.yaml" | awk '/value:/{gsub(/^[ \t]*value:[ \t]*"?|"?$/,""); print; exit}')"
      [ "${got}" = "${want}" ] \
        && ok "(9) helm agrees for ${rel} ${n}=${got}" \
        || { bad "(9) MODEL DIVERGES from helm for ${rel} ${n}: model='${want}' helm='${got}'"; hfail=1; }
    done
  done
  [ "${hfail}" = "0" ] && ok "(9) the python model reproduces real helm output for all four releases"
elif [ "${REQUIRE_HELM:-0}" = "1" ]; then
  # Strict mode, set by the CI job: it installs a sha256-pinned helm precisely so
  # this cross-check RUNS, which makes helm's absence a regression of the image or
  # of the install step — not a skippable condition. Without this, a future image
  # change that lost helm would re-enter SKIP-mode and stay green with less
  # coverage; that silent degrade is the exact failure mode this flag closes.
  bad "(9) REQUIRE_HELM=1 but helm is NOT on PATH — this run declared the helm cross-check load-bearing, so the model-only SKIP is not available. Restore the pinned-helm install (or drop REQUIRE_HELM deliberately, accepting that the model runs unchecked)."
else
  echo "  SKIP (9) helm not on PATH — the python model above is the authority here."
  echo "        Install helm and re-run to cross-check it against a real render."
  echo "        (CI sets REQUIRE_HELM=1, which turns this SKIP into a FAIL.)"
fi

# ── the tally itself has to be trustworthy ───────────────────────────────────
# `set -uo pipefail` WITHOUT `-e` is deliberate (one red assertion must not hide
# the other ninety), but it also means a section that stops running stops being
# COUNTED rather than failing: "0 failed" over half the checks looks exactly like
# "0 failed" over all of them. So state the floor and enforce it. The preflight at
# the top covers the missing-tool cause; this covers every other one.
# MIN_CHECKS is the count with helm ABSENT (a local model-only run); assertion (9)
# adds 13 more when helm is on PATH (114 total in CI, which installs a pinned helm
# and sets REQUIRE_HELM=1 so a helm-less run there FAILS outright in (9)), hence a
# floor and not an equality. Adding assertions? Raise it. Removing one? Lower it
# ON PURPOSE, in the same commit.
MIN_CHECKS=101
total=$(( P + F ))
if [ "${total}" -lt "${MIN_CHECKS}" ]; then
  bad "only ${total} assertions ran, but this file declares a floor of ${MIN_CHECKS} — checks stopped running rather than failing, so the count above means nothing. Find what exited early (or lower MIN_CHECKS deliberately if the removal was intended)."
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
