#!/usr/bin/env bash
# test-kind-profile-app-closure.sh — a kind profile's Application list must be
# CLOSED under the dependencies its own Applications declare.
#
# WHY THIS EXISTS. bootstrap-kind.sh's KIND_PROFILE=sso applies a curated subset
# of specs/cluster/apps/ rather than the whole app-of-apps. The list carried
# `00-cassandra.yaml` (the Bitnami Helm chart) but NOT `00b-cassandra-init.yaml`,
# the separate Application that creates the keyspaces, the per-app roles and the
# grants. The chart ships PasswordAuthenticator ON with no application keyspaces
# and exactly one role, so the profile stood up a Cassandra that no gateway could
# ever authenticate against. Live symptom, on a real run:
#
#     DESC KEYSPACES  -> system keyspaces only
#     LIST ROLES      -> 1 row: cassandra
#     fe-gateway      -> CrashLoopBackOff, "Provided username fe_gw_cass and/or
#                        password are incorrect"
#
# That message reads like a rotated password and is really a role that was never
# created — hours of the wrong investigation. apps/00b-cassandra-init.yaml opens
# with "NOT OPTIONAL AND NOT DARK ... until this Job runs there is no combination
# of settings under which a gateway can start". Every fact needed to catch this
# was already written down. Nothing read it.
#
# THE INVARIANT. For each profile list in bootstrap-kind.sh, if a listed
# Application's manifest mentions `apps/<other>.yaml`, then `<other>.yaml` must
# also be in that list — or must be EXEMPT below with a reason.
#
# ON THE EXEMPTION LIST, which is deliberate. An earlier draft tried to be clever
# and counted a mention as a dependency only when a "dependency verb" (after,
# creates, requires...) sat on the same line, so that analogy prose would not
# trip it. An adversarial review destroyed that: verbless but entirely idiomatic
# phrasing ("Wave 2; apps/00b-cassandra-init.yaml must have run first") sailed
# through, and across BOTH profiles the heuristic matched exactly ONE reference
# out of eight — a guard resting on a single comment line. Counting every mention
# and naming the handful of genuine analogies is dumber, unevadable, and it makes
# the eight references load-bearing instead of one.
#
# THE MAP-DRIVEN BLIND SPOT (2026-08-26). This guard discovered profiles with
# `^[A-Z0-9_]+_APPS=\\(` and modelled nothing else. bootstrap-kind.sh then grew a
# THIRD source of applied Applications — KIND_ADDON_MAP, the KIND_ADDONS
# selection channel — which that regex cannot see. An add-on's dependencies would
# have gone unchecked while this file reported "every app ... has its declared
# companion apps applied too", which is the worst kind of green: a specific claim
# about a set the guard was no longer computing. The map is parsed here as a
# first-class profile source, and the vacuity floor below is raised so a map that
# stops parsing cannot hide behind the two literal arrays.
#
# TWO MORE LEGS, both for defects that were LIVE in the file when they were added:
#
#  * WAIT-LIST. An Application a profile applies but that is missing from the
#    script's APP_NAMES wait/status list has its failure rendered INVISIBLE: the
#    bring-up neither waits for it nor prints it in the closing table, so a dead
#    Application looks exactly like a healthy one. The file's own comment records
#    this happening to cassandra-init. It had happened AGAIN, to `kyverno` and
#    `workload-console-rbac` — added to SSO_APPS by PR #167, added to APP_NAMES by
#    nobody — and no test could see it. Now one can.
#
#  * ORDER. Applied standalone (not under an app-of-apps) ArgoCD gives cross-
#    Application sync-waves no meaning at all, so the ORDER OF APPLY is the only
#    ordering lever bootstrap-kind.sh holds. 15-kyverno.yaml MUST be applied
#    before 14-workload-console-rbac.yaml: without kyverno.io/v1 registered ArgoCD
#    cannot even RENDER the ClusterPolicy that Application carries —
#    "failed to discover server resources for group version kyverno.io/v1" — so
#    the admission backstop is absent rather than merely unsynced (PR #167).
#
# Offline: bash + grep + sed only. No cluster, no python, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BOOT="${PROFILE_BOOTSTRAP:-${REPO}/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh}"
APPS="${PROFILE_APPS_DIR:-${REPO}/specs/cluster/apps}"

# Control runs re-enter this script against synthetic trees. The flag is a
# POSITIONAL ARGUMENT, never an environment variable: an inherited env var would
# silently downgrade a real CI run to a control run (and skip the controls), and
# nothing would say so.
CHILD=no
[ "${1:-}" = "--closure-only" ] && CHILD=yes

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# A guard that skips is a guard that never guards; this repo has shipped several.
for t in grep sed; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: ${t} required (refusing to skip)" >&2; exit 1; }
done
[ -r "${BOOT}" ] || { echo "FATAL: cannot read ${BOOT}" >&2; exit 1; }
[ -d "${APPS}" ] || { echo "FATAL: cannot read ${APPS}" >&2; exit 1; }

# ── exemptions ──────────────────────────────────────────────────────────────
# "<listed-app> -> <referenced-app>" pairs that are NOT dependencies. Every entry
# is printed with its reason, and the anti-rot check below FAILS if an entry no
# longer matches a live reference, so an exemption cannot outlive its cause.
# Keyed without the profile name so one analogy needs one entry, not one per
# profile that happens to include the file.
EXEMPT_KEYS=(
  "03a-harbor.yaml -> 03-gitlab.yaml"
  "03a-harbor.yaml -> 12-cloudflared.yaml"
  "03a-harbor.yaml -> 20-gateway-pki.yaml"
  "03a-harbor.yaml -> 22-gateway-superadmin.yaml"
  "15-kyverno.yaml -> 16-reserved-prefixes-policy.yaml"
)
EXEMPT_WHY=(
  "NEGATIVE COUPLING + ANALOGY, in that order, and neither is a bootstrap dependency. 03a's header cites apps/03-gitlab.yaml twice: once because GitLab's bundled registry subchart is disabled there (registry.enabled:false) so that nothing else claims registry.<domain> — a HOSTNAME COLLISION note, which on kind is moot because 03-gitlab is not applied at all, so there is no second claimant — and once as 'Modeled directly on apps/03-gitlab.yaml's shape', which is prose about chart structure. Harbor needs nothing FROM GitLab; the migration exists precisely to stop depending on it. These four exemptions appeared 2026-08-26, when 03a stopped being applied by an unmodelled \`git show\` block and became visible to this gate for the first time."
  "PROD-EDGE REASONING, not a dependency: 03a explains why it takes the nginx-internal class by noting that apps/12-cloudflared.yaml (the public tunnel) maps only the apex + api./matrix./mastodon. hosts, so registry.* is never handed to it. cloudflared is not applied on kind and Harbor does not read anything it creates."
  "ANALOGY: 'This mirrors the pki/superadmin gateways (apps/20-gateway-pki.yaml, apps/22-gateway-superadmin.yaml), the platform's existing convention for every other identity/control-plane-tier hostname.' A naming convention, cited to justify a namespace choice. Neither gateway is applied by any kind profile and Harbor consumes nothing from them."
  "ANALOGY: the second half of the pki/superadmin convention cited above."
  "REVERSE DIRECTION, not a missing bootstrap: kyverno is the policy ENGINE and 16-reserved-prefixes-policy is one CONSUMER of it. The dependency runs 16 -> 15; 15's header names 16 only to explain why the engine was introduced at all. Kyverno needs nothing from it. Verified live 2026-08-22: kyverno runs Synced/Healthy on the kind cluster serving workload-console-rbac's deploy-provenance ClusterPolicy while 16-reserved-prefixes-policy is not applied there at all. NOTE THE REAL CONSEQUENCE, which this exemption does NOT paper over: the reserved-prefix vanity-collision rule is therefore UNENFORCED on kind. That predates this list gaining kyverno — the profile has never applied 16 — and adding it is a separate decision, because it is another Enforce ClusterPolicy whose blast radius on a local cluster has not been measured."
)

# THE TWO HARBOR EXEMPTIONS ARE GONE (2026-08-26), and not because they were
# wrong — they were right, and unnecessary. 00b-cassandra-init's two references to
# apps/03a-harbor.yaml / 03b-harbor-provision.yaml really are an ANALOGY (it cites
# Harbor's Helm-vs-git-path split to explain its own). They needed an exemption
# only because those two Applications were applied by bespoke `git show` blocks
# that this guard could not see, so the references looked unsatisfied. Both blocks
# have merged to main and been folded into CORE_APPS, so the references are now
# satisfied by the modelled base and the anti-rot check below removes the
# exemptions itself if they are ever put back: it FAILS on an exemption that no
# longer matches a live unsatisfied reference. Deleting them was therefore not
# optional — leaving them in makes this suite red.
#
# THE TWO EXEMPTIONS BEFORE THOSE WERE A LIE, AND THE LIE WAS LOAD-BEARING.
# 00b-cassandra-init.yaml -> 03-external-secrets.yaml and -> 04-external-secrets-
# config.yaml were labelled "ANALOGY, not a dependency". They are a hard runtime
# dependency: 04's path renders manifests/external-secrets, whose kustomization
# includes cassandra-externalsecrets.yaml, which materializes the Secret
# `cassandra-app-creds`; cassandra-init's bootstrap-job.yaml mounts all six of its
# keys as REQUIRED env and its bootstrap.sh `require`s each one, exiting 1 on any
# empty value. Without 03/04 the Job cannot run at all.
#
# The exemptions reached the right VERDICT for the wrong REASON — those apps are
# applied, just from CORE_APPS rather than the profile list — and that wrong
# reason permanently whitelisted the exact edge this gate exists to protect.
# Adversarial review proved it: delete both lines from CORE_APPS and the suite
# stayed green at "8 passed, 0 failed". Modelling CORE_APPS as what it actually
# is fixes the verdict AND makes that deletion go red.

# Applications applied for EVERY profile, not just one. bootstrap-kind.sh applies
# CORE_APPS unconditionally before any profile branch, so the effective applied
# set of a profile is CORE_APPS + its own list. Naming it here rather than
# inferring it: inferring "applied unconditionally" from shell text is a
# reachability analysis, and a sibling guard in this repo spent four adversarial
# rounds proving how hard that is to get right.
ALWAYS_APPLIED_ARRAY="CORE_APPS"

exempt_reason() { # <key> -> prints reason, or empty
  local k="$1" i
  for i in "${!EXEMPT_KEYS[@]}"; do
    [ "${EXEMPT_KEYS[$i]}" = "$k" ] && { printf '%s' "${EXEMPT_WHY[$i]}"; return; }
  done
}

# ── discover the profile lists ──────────────────────────────────────────────
profiles="$(grep -oE '^[A-Z0-9_]+_APPS=\(' "${BOOT}" | sed 's/=($//;s/=(//')"
[ -n "${profiles}" ] || { echo "FATAL: no *_APPS profile arrays found in ${BOOT}" >&2; exit 1; }

echo "== kind profile app closure: ${BOOT} =="

# Extract one array. Tolerates the closing paren on its own line OR trailing the
# last entry (`  45-social-ui.yaml)`), and REFUSES to guess when the array is
# never closed — an unterminated array previously made the extractor run to EOF
# and scoop up unrelated filenames, which inflates the list and makes the whole
# gate pass vacuously.
list_profile() { # <ARRAYNAME> -> one app filename per line; rc 2 if unterminated
  local name="$1" start body
  start="$(grep -nE "^${name}=\(" "${BOOT}" | head -1 | cut -d: -f1)"
  [ -n "${start}" ] || return 1
  body="$(sed -n "$((start+1)),\$p" "${BOOT}" | sed 's/#.*//')"
  grep -qE '\)' <<<"${body}" || return 2
  # stop at the first line containing a closing paren, that line included
  body="$(sed -n '1,/)/p' <<<"${body}")"
  grep -oE '[0-9][0-9a-z-]*\.yaml' <<<"${body}" || true
}

# THE ADD-ON MAP — the third source of applied Applications (KIND_ADDONS).
# One literal block in bootstrap-kind.sh:
#     KIND_ADDON_MAP="
#     <slug>  <file> [<file>...]
#     "
# Parsed with the same refuse-to-guess rule the array extractor uses: an unclosed
# block returns rc 2 rather than running to EOF and scooping up unrelated text.
# Comments are STRIPPED FIRST — the block sits under thirty lines of prose that
# names both slugs and several apps/*.yaml files, and a scan that read the prose
# would report a map far richer than the one the script executes.
list_addon_map() { # -> "<slug> <file>..." per line; rc 1 no block, rc 2 unterminated
  local start body
  start="$(grep -n '^KIND_ADDON_MAP="' "${BOOT}" | head -1 | cut -d: -f1)"
  [ -n "${start}" ] || return 1
  body="$(sed -n "$((start+1)),\$p" "${BOOT}" | sed 's/#.*//')"
  grep -qE '^"' <<<"${body}" || return 2
  sed -n '1,/^"/p' <<<"${body}" | sed -e '/^"/d' -e '/^[[:space:]]*$/d'
}

# ── the wait/status list ───────────────────────────────────────────────────
# Every APP_NAMES literal in the script (the base assignment and the profile
# appends), COMMENTS STRIPPED FIRST. That is not hygiene: the WHY comment above
# the sso append names `kyverno` and `workload-console-rbac` in prose, so a scan
# of the raw file would find them there and certify the exact wiring they were
# missing from. Four checks in this repo have been inverted by prose naming a
# token; this one is not going to be the fifth.
app_names_listing() {
  sed 's/#.*//' "${BOOT}" \
    | grep -oE '^[[:space:]]*APP_NAMES\+?=\([^)]*\)' \
    | sed -e 's/^[^(]*(//' -e 's/)$//' \
    | tr ' ' '\n' | sed '/^[[:space:]]*$/d'
}
# <file> -> the `kind:` it declares (first one), and its Application metadata.name.
# Both pure sed, both anchored: `kind: Application` must not match `ApplicationSet`.
app_manifest_kind() { sed -n '/^kind:/{s/^kind:[[:space:]]*//;s/[[:space:]]*$//;p;q;}' "$1"; }
app_manifest_name() {
  sed -n '/^kind: Application$/,$ { /^  name:/ { s/^  name:[[:space:]]*//; s/[[:space:]]*$//; p; q; } }' "$1"
}
# An applied file with NO wait entry, excused with a reason. Anti-rot'd like the
# closure exemptions: an entry that stops matching an applied file FAILS.
WAIT_EXEMPT_KEYS=(
  "05b-casdoor-domains.yaml"
)
WAIT_EXEMPT_WHY=(
  "NOT an Application: it is an ApplicationSet, so \`kubectl get application casdoor-domains\` never resolves and it cannot appear in a wait list built on that verb. It also ships with ZERO generator list elements, so it produces no child Applications to wait for either — bootstrap-kind.sh applies it ONLY so apply_core_app's sed retargets the GitHub repoURL/targetRevision literals inside its TEMPLATE (the issue-#48 contract). There is nothing here whose failure could be hidden."
)
wait_exempt_reason() { # <file> -> prints reason, or empty
  local k="$1" i
  for i in "${!WAIT_EXEMPT_KEYS[@]}"; do
    [ "${WAIT_EXEMPT_KEYS[$i]}" = "$k" ] && { printf '%s' "${WAIT_EXEMPT_WHY[$i]}"; return; }
  done
}

# ── apply-ORDER constraints ────────────────────────────────────────────────
# "<later> <must-come-first>" pairs. Applied standalone rather than under an
# app-of-apps, ArgoCD gives cross-Application sync-waves NO meaning, so the order
# these files are applied in is the only ordering lever bootstrap-kind.sh holds.
ORDER_PAIRS=(
  "14-workload-console-rbac.yaml 15-kyverno.yaml"
)
ORDER_WHY=(
  "14-workload-console-rbac carries the deploy-provenance ClusterPolicy. Without kyverno.io/v1 REGISTERED, ArgoCD cannot even render it — 'failed to discover server resources for group version kyverno.io/v1' — so the Application sits OutOfSync/Missing and the admission backstop is ABSENT, not merely unsynced. That was the state of every kind cluster ever built until PR #167. Reordering these two lines puts it back, silently."
)

total_apps=0
total_refs=0
declare -a violations=()
used_exemptions=()
# The effective applied set, in APPLY ORDER: add-on files first (bootstrap-kind.sh
# applies them before anything else — they are the sync-wave "-1" substrate), then
# the always-applied base, then each profile's own list.
declare -a applied_order=()
declare -a addon_files_all=()
note_applied() { # <file>
  local f="$1" x
  for x in ${applied_order[@]+"${applied_order[@]}"}; do [ "${x}" = "${f}" ] && return; done
  applied_order+=("${f}")
}

# The always-applied base. Every profile's effective set includes it.
base_listing="$(list_profile "${ALWAYS_APPLIED_ARRAY}")"; base_rc=$?
mapfile -t base_apps <<<"${base_listing}"
tmp=(); for l in ${base_apps[@]+"${base_apps[@]}"}; do [ -n "${l}" ] && tmp+=("${l}"); done
base_apps=(${tmp[@]+"${tmp[@]}"})
if [ "${base_rc}" -ne 0 ] || [ "${#base_apps[@]}" -eq 0 ]; then
  bad "${ALWAYS_APPLIED_ARRAY} could not be parsed (rc=${base_rc}, ${#base_apps[@]} entries) — every profile's effective set depends on it, so this gate cannot run"
fi

# ONE closure body for all THREE sources of applied Applications (the base array,
# each profile array, and each KIND_ADDONS add-on). Factored out when the add-on
# map arrived: a second hand-copied loop is how the map ends up checked slightly
# differently from the arrays, which is a blind spot with extra steps.
check_closure() { # <label> <newline-separated app filenames>
  local prof="$1"
  local listing="$2"
  local -a listed=() tmp=()
  local l app f ref key why hit
  mapfile -t listed <<<"${listing}"
  for l in ${listed[@]+"${listed[@]}"}; do [ -n "${l}" ] && tmp+=("${l}"); done
  listed=(${tmp[@]+"${tmp[@]}"})
  [ "${#listed[@]}" -gt 0 ] || { bad "${prof}: parsed ZERO app entries — the parser is not reading it"; return; }
  total_apps=$((total_apps + ${#listed[@]}))
  [ "${CHILD}" = yes ] || echo "-- ${prof}: ${#listed[@]} application(s) --"

  for app in "${listed[@]}"; do
    note_applied "${app}"
    f="${APPS}/${app}"
    if [ ! -r "${f}" ]; then
      violations+=("${prof}: lists ${app}, which does not exist in ${APPS#${REPO}/}")
      continue
    fi
    for ref in $(grep -ohE 'apps/[0-9][0-9a-z-]*\.yaml' "${f}" | sed 's|apps/||' | sort -u); do
      [ "${ref}" = "${app}" ] && continue           # self-reference is not a dependency
      total_refs=$((total_refs + 1))
      # Satisfied by this set's own list OR by the always-applied base.
      hit=no
      for l in "${listed[@]}"; do [ "${l}" = "${ref}" ] && { hit=yes; break; }; done
      if [ "${hit}" = no ] && [ "${prof}" != "${ALWAYS_APPLIED_ARRAY}" ]; then
        for l in ${base_apps[@]+"${base_apps[@]}"}; do [ "${l}" = "${ref}" ] && { hit=yes; break; }; done
      fi
      [ "${hit}" = yes ] && continue
      key="${app} -> ${ref}"
      why="$(exempt_reason "${key}")"
      if [ -n "${why}" ]; then
        used_exemptions+=("${key}")
        [ "${CHILD}" = yes ] || { echo "     exempt: ${key}"; echo "             ${why}"; }
      else
        violations+=("${prof}: ${key}   (${app} names it, but the set never applies it)")
      fi
    done
  done
}

# ── the KIND_ADDONS map goes FIRST, because bootstrap-kind.sh applies it first ──
# (sync-wave "-1" substrate, ahead of the base and every profile). Order matters
# here only because applied_order is what the ORDER leg below reads.
addon_slug_count=0
addon_file_count=0
addon_listing="$(list_addon_map)"; addon_rc=$?
if [ "${addon_rc}" -eq 2 ]; then
  bad "KIND_ADDON_MAP block is never closed — refusing to guess where it ends"
elif [ "${addon_rc}" -ne 0 ]; then
  bad "no KIND_ADDON_MAP block in ${BOOT} — KIND_ADDONS is a THIRD source of applied Applications and this guard would be blind to every one of them"
else
  while read -r addon_slug addon_rest; do
    [ -n "${addon_slug}" ] || continue
    addon_slug_count=$((addon_slug_count + 1))
    if [ -z "${addon_rest}" ]; then
      bad "KIND_ADDONS add-on '${addon_slug}' maps to NO app file — selecting it would change nothing"
      continue
    fi
    for addon_f in ${addon_rest}; do
      addon_file_count=$((addon_file_count + 1))
      addon_files_all+=("${addon_f}")
    done
    check_closure "KIND_ADDONS:${addon_slug}" "$(printf '%s\n' ${addon_rest})"
  done <<<"${addon_listing}"
fi

for prof in ${profiles}; do
  listing="$(list_profile "${prof}")"; rc=$?
  if [ "${rc}" -eq 2 ]; then
    bad "${prof}: array is never closed — refusing to guess where it ends"
    continue
  fi
  check_closure "${prof}" "${listing}"
done

if [ "${#violations[@]}" -eq 0 ]; then
  ok "every app a curated profile applies has its declared companion apps applied too"
else
  for v in "${violations[@]}"; do echo "     ${v}"; done
  bad "${#violations[@]} unsatisfied cross-reference(s) above — the profile deploys a component without its bootstrap"
fi

# A child run reports the CLOSURE verdict and nothing else. The anti-rot and
# vacuity checks below are properties of the real repository, not of a synthetic
# 7-entry probe: leaving them switched on made every probe fail for reasons
# unrelated to closure, which is precisely what turns a control pair into
# theatre. (The sabotage control caught this while I was writing it.)
if [ "${CHILD}" = yes ]; then
  echo "== control run: ${pass} passed, ${fail} failed =="
  [ "${fail}" -eq 0 ]; exit $?
fi

# ── anti-rot: an exemption must still match a live reference ────────────────
stale=0
for i in "${!EXEMPT_KEYS[@]}"; do
  k="${EXEMPT_KEYS[$i]}"; seen=no
  for u in ${used_exemptions[@]+"${used_exemptions[@]}"}; do [ "${u}" = "${k}" ] && { seen=yes; break; }; done
  [ "${seen}" = no ] && { echo "     stale exemption: ${k}"; stale=$((stale+1)); }
done
if [ "${stale}" -eq 0 ]; then
  ok "anti-rot: no exemption outlives the reference it excuses (${#EXEMPT_KEYS[@]} declared)"
else
  bad "${stale} exemption(s) no longer match any reference — delete them"
fi

# ── WAIT-LIST: an applied Application must be waited for and REPORTED ──────
# THE DEFECT, twice over. bootstrap-kind.sh waits on APP_NAMES and prints exactly
# APP_NAMES in its closing status table. An Application it APPLIES but does not
# NAME there is not merely unwaited-for — it is unreported, so a dead one is
# indistinguishable from a healthy one in the script's own output. That happened
# to cassandra-init (fe-gateway crash-looped on an auth error for hours because
# the role bootstrap had never run, and the bring-up's table said nothing), and it
# had happened AGAIN to kyverno + workload-console-rbac, added to SSO_APPS by
# PR #167 and to APP_NAMES by nobody. Found by this leg on 2026-08-26.
wait_names="$(app_names_listing)"
wait_missing=0
wait_checked=0
used_wait_exemptions=()
for app in ${applied_order[@]+"${applied_order[@]}"}; do
  f="${APPS}/${app}"
  [ -r "${f}" ] || continue          # already a closure violation; do not double-report
  wait_checked=$((wait_checked + 1))
  k="$(app_manifest_kind "${f}")"
  n="$(app_manifest_name "${f}")"
  if [ "${k}" != "Application" ] || [ -z "${n}" ]; then
    why="$(wait_exempt_reason "${app}")"
    if [ -n "${why}" ]; then
      used_wait_exemptions+=("${app}")
      echo "     wait-exempt: ${app} (kind=${k:-none})"
      echo "                  ${why}"
    else
      echo "     ${app}: kind=${k:-none}, no Application metadata.name — it is applied, and nothing can wait on it or report it"
      wait_missing=$((wait_missing + 1))
    fi
    continue
  fi
  # An ADD-ON's wait entry is DERIVED at runtime (the selection is a runtime
  # value, so no literal list could carry it). What is checked here is the
  # precondition that derivation needs — a parseable Application name, asserted
  # just above — plus that the derivation is actually wired, asserted once below.
  hit=no
  for l in ${addon_files_all[@]+"${addon_files_all[@]}"}; do [ "${l}" = "${app}" ] && { hit=yes; break; }; done
  [ "${hit}" = yes ] && continue
  hit=no
  for l in ${wait_names}; do [ "${l}" = "${n}" ] && { hit=yes; break; }; done
  if [ "${hit}" = no ]; then
    echo "     ${app} (Application '${n}') is applied but is NOT in APP_NAMES — the bring-up will neither wait for it nor print it, so its failure is invisible"
    wait_missing=$((wait_missing + 1))
  fi
done
if [ "${wait_missing}" -eq 0 ]; then
  ok "wait-list: every applied Application is waited for and printed in the status table (${wait_checked} files checked, $(printf '%s' "${wait_names}" | grep -c . || true) names declared)"
else
  bad "${wait_missing} applied Application(s) above have no wait/status entry — their failure is rendered invisible"
fi
# The runtime derivation for add-on Applications, asserted on the SCRIPT with
# comments stripped (the prose around it names APP_NAMES repeatedly).
# NOT `| grep -q`: under `set -o pipefail` a matching grep -q exits early, sed
# takes SIGPIPE on a 90KB upstream, and the pipeline reports FAILURE for a FOUND
# match — this repo has been bitten by that exact inversion. Drain it into a
# variable and test emptiness instead.
if [ -n "$(sed 's/#.*//' "${BOOT}" | grep -F 'APP_NAMES+=("${addon_app_name}")' || true)" ]; then
  ok "wait-list: add-on Applications are appended to APP_NAMES from their manifest at runtime"
else
  bad "bootstrap-kind.sh no longer derives add-on Application names into APP_NAMES — every KIND_ADDONS selection would be applied and then never waited for or reported"
fi
# Anti-rot for the wait exemptions, same rule as the closure ones.
wstale=0
for i in "${!WAIT_EXEMPT_KEYS[@]}"; do
  k="${WAIT_EXEMPT_KEYS[$i]}"; seen=no
  for u in ${used_wait_exemptions[@]+"${used_wait_exemptions[@]}"}; do [ "${u}" = "${k}" ] && { seen=yes; break; }; done
  [ "${seen}" = no ] && { echo "     stale wait exemption: ${k}"; wstale=$((wstale+1)); }
done
if [ "${wstale}" -eq 0 ]; then
  ok "anti-rot: no wait exemption outlives the file it excuses (${#WAIT_EXEMPT_KEYS[@]} declared)"
else
  bad "${wstale} wait exemption(s) no longer match an applied file — delete them"
fi

# ── APPLY SITES: the ORDER model must be the script's REAL apply order ─────
# WHAT ADVERSARIAL REVIEW FOUND (2026-08-26) — two holes, not one.
#
#  1. `applied_order` below was built from THIS GUARD'S ASSUMED sequence (add-on
#     map, then the always-applied base, then each `*_APPS` literal in file
#     order) and nothing read bootstrap-kind.sh's actual `for` loops. Rewriting
#     the real SSO loop as `for f in $(printf '%s\n' "${SSO_APPS[@]}" | tac)` —
#     array literal untouched — reproduces the PR #167 defect exactly
#     (14-workload-console-rbac applied BEFORE 15-kyverno, ArgoCD cannot render
#     the ClusterPolicy, the admission backstop is ABSENT) and this file stayed
#     16 passed / 0 failed.
#
#  2. The apply STEP was unguarded outright. Deleting the three-line add-on apply
#     loop leaves the selection parsed, deduped, post-condition-checked, threaded
#     through make, derived into APP_NAMES and reported on stdout — while
#     applying nothing: the inert toggle the local-services catalogue exists to
#     prevent. The channel guard structurally cannot see it (KIND_ADDONS_PRINT=1
#     exits ~530 lines BEFORE the apply), and this file modelled the
#     KIND_ADDON_MAP literal, never the code that consumes it. A wider mutation
#     proved the blind spot was not add-on-specific: neutering `apply_core_app`
#     at BOTH call sites also left both suites at rc=0.
#
# The fix is to read the apply sites themselves. Comments stripped, because the
# prose above and throughout bootstrap-kind.sh names every one of these arrays —
# comment-token inversion has inverted four checks in this repo already.
#
# `pending` is reset at `done` so only a loop whose BODY calls apply_core_app is
# collected; the APP_NAMES derivation loop over ADDON_APP_FILES is not an apply
# site and must not be counted as one.
#
# THE CALL MUST BE ANCHORED AS A LEADING COMMAND. A first cut matched the bare
# token anywhere in the body, and `: apply_core_app "${f}"` — the null command
# swallowing its arguments — survived it at BOTH call sites with both suites
# still at rc=0. Requiring apply_core_app to START the statement kills that.
apply_loop_headers() { # [file] -> one normalised `for` header per apply loop, in FILE order
  sed 's/#.*//' "${1:-${BOOT}}" | awk '
    /^[[:space:]]*for[[:space:]]/ { hdr=$0; sub(/^[[:space:]]+/,"",hdr); sub(/[[:space:]]+$/,"",hdr); pending=1; next }
    pending && /^[[:space:]]*apply_core_app[[:space:]]/ { print hdr; pending=0; next }
    pending && /^[[:space:]]*done/ { pending=0; next }
  '
}
# THE SHAPE IS THE ORDERING GUARANTEE. Only a bare `"${NAME[@]}"` expansion
# applies the array literal in DECLARATION order; any command substitution,
# pipeline, sort, tac or glob between the array and the loop severs the link
# between "the order these files are listed in" and "the order they are applied
# in" — and that link is the only ordering lever this bootstrap holds. Prints the
# array name for an accepted header, nothing for a rejected one. Shared by the
# live leg and by the control pair at the bottom of this file, so a header shape
# the extractor stops recognising cannot pass unnoticed in either direction.
apply_loop_source() { # <normalised for-header> -> array name, or nothing
  [[ "$1" =~ ^for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+\"\$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\}\"[[:space:]]*\;[[:space:]]*do$ ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}
declare -a apply_headers=() apply_sources=()
mapfile -t apply_headers < <(apply_loop_headers)
shape_bad=0
for h in ${apply_headers[@]+"${apply_headers[@]}"}; do
  [ -n "${h}" ] || continue
  src="$(apply_loop_source "${h}")"
  if [ -n "${src}" ]; then
    apply_sources+=("${src}")
  else
    echo "     apply loop is not a bare, in-order array expansion: ${h}"
    shape_bad=$((shape_bad + 1))
  fi
done
if [ "${#apply_headers[@]}" -lt 2 ]; then
  bad "apply-sites: found ${#apply_headers[@]} loop(s) that call apply_core_app — bootstrap-kind.sh applies its Applications from at least two (the add-ons and the always-applied base), so either an apply step was deleted or this extractor has gone blind"
elif [ "${shape_bad}" -ne 0 ]; then
  bad "apply-sites: ${shape_bad} apply loop(s) above do not iterate their array literal directly — apply order no longer follows declaration order, so every ORDER constraint below is modelling a sequence the script does not perform"
else
  ok "apply-sites: all ${#apply_headers[@]} apply loop(s) iterate their array literal directly, in declaration order (${apply_sources[*]})"
fi
# THE ADD-ONS GO FIRST. bootstrap-kind.sh and its README both claim this in prose
# in three places — metrics-server and KEDA are sync-wave "-1" substrate and the
# workloads that autoscale on them come later — and until now no test read it.
# It is also what makes `applied_order` start with the add-on files.
if [ "${#apply_sources[@]}" -gt 0 ] && [ "${apply_sources[0]}" = "ADDON_APP_FILES" ]; then
  ok "apply-sites: the KIND_ADDONS add-ons are applied FIRST (${apply_sources[0]}), ahead of every curated array — the sync-wave \"-1\" substrate claim is load-bearing"
else
  bad "apply-sites: the first thing applied is '${apply_sources[0]:-nothing}', not ADDON_APP_FILES — either the add-on apply loop is gone (the selection would be parsed, threaded and reported while applying NOTHING) or the substrate no longer goes on first"
fi
# A curated array that is DECLARED and never applied is the same inert-toggle
# shape one level up: the closure gate would keep certifying a set nobody deploys.
unapplied=0
for prof in ${profiles}; do
  hit=no
  for s in ${apply_sources[@]+"${apply_sources[@]}"}; do [ "${s}" = "${prof}" ] && { hit=yes; break; }; done
  [ "${hit}" = no ] && { echo "     ${prof} is declared but no loop applies it"; unapplied=$((unapplied + 1)); }
done
if [ "${unapplied}" -eq 0 ]; then
  ok "apply-sites: every curated profile array is actually applied by a loop"
else
  bad "${unapplied} curated array(s) above are declared and never applied — this gate would keep certifying a set the bring-up does not deploy"
fi
# AND THE MODEL ITSELF. `applied_order` is built add-ons -> base -> each profile
# in discovery order; that must be the sequence the script performs, or the ORDER
# leg below is checking a fiction.
real_seq="$(printf '%s ' ${apply_sources[@]+"${apply_sources[@]}"})"
model_seq="$(printf '%s ' ADDON_APP_FILES ${profiles})"
if [ "${real_seq}" = "${model_seq}" ]; then
  ok "apply-sites: the order this guard models is the order the script applies (${real_seq% })"
else
  bad "apply-sites: this guard models the apply order as '${model_seq% }' but bootstrap-kind.sh applies '${real_seq% }' — every ORDER constraint below is being evaluated against a sequence that does not happen"
fi
# apply_core_app must still APPLY. Neutering its body leaves every loop above
# intact and deploys nothing. NOT `| grep -q`: under `set -o pipefail` a matching
# grep -q exits early, sed takes SIGPIPE on a 90KB upstream, and the pipeline
# reports FAILURE for a FOUND match. Drain it and test emptiness instead.
# BOTH BRANCHES, not one. apply_core_app renders through TWO terminal pipelines
# — the working-tree path and the branch-pinned `git show` path — and each ends
# in its own `kubectl apply -f -`. A first cut asserted merely that the token
# appeared somewhere in the function; replacing the branch-pinned apply with
# `| cat >/dev/null` survived it, which would mean every branch-pinned
# Application is rendered, logged as "Applying ... BRANCH-PINNED", and thrown
# away. Count them.
apply_verbs="$(sed 's/#.*//' "${BOOT}" | sed -n '/^apply_core_app()/,/^}/p' | grep -cF 'kubectl apply -f -' || true)"
if [ "${apply_verbs:-0}" -ge 2 ]; then
  ok "apply-sites: both of apply_core_app's render paths (working-tree and branch-pinned) end in \`kubectl apply -f -\` (${apply_verbs} found)"
else
  bad "apply_core_app has ${apply_verbs:-0} \`kubectl apply -f -\` pipeline(s), expected 2 — at least one render path renders a manifest and discards it, so the loops above would iterate the curated set and deploy part or none of it"
fi

# ── ORDER: the only ordering lever this bootstrap actually holds ───────────
order_bad=0
order_checked=0
idx_of() { # <file> -> 0-based index in applied_order, or empty
  local want="$1" i=0 x
  for x in ${applied_order[@]+"${applied_order[@]}"}; do
    [ "${x}" = "${want}" ] && { printf '%s' "${i}"; return; }
    i=$((i+1))
  done
}
for i in "${!ORDER_PAIRS[@]}"; do
  set -- ${ORDER_PAIRS[$i]}
  later="$1"; first="$2"
  li="$(idx_of "${later}")"; fi_="$(idx_of "${first}")"
  if [ -z "${li}" ] || [ -z "${fi_}" ]; then
    # Not a silent pass: a constraint whose files stopped being applied is a
    # constraint nobody is checking, and it must say so out loud.
    echo "     order constraint not exercised: ${first} before ${later} (applied: ${first}=${fi_:-no} ${later}=${li:-no})"
    continue
  fi
  order_checked=$((order_checked + 1))
  if [ "${fi_}" -ge "${li}" ]; then
    echo "     ${first} is applied AFTER ${later} (positions ${fi_} vs ${li})"
    echo "       ${ORDER_WHY[$i]}"
    order_bad=$((order_bad + 1))
  fi
done
if [ "${order_checked}" -eq 0 ]; then
  bad "order: ZERO ordering constraints were exercised — the constraint table no longer matches the applied set"
elif [ "${order_bad}" -eq 0 ]; then
  ok "order: ${order_checked} apply-order constraint(s) hold"
else
  bad "${order_bad} apply-order constraint(s) violated above"
fi

# ── vacuity: a run that inspected nothing must not pass ────────────────────
if [ "${total_apps}" -ge 5 ]; then
  ok "vacuity: profiles really parsed (${total_apps} app entries)"
else
  bad "vacuity: only ${total_apps} app entries parsed — the array parser is broken"
fi
# The add-on map is a THIRD source of applied Applications and gets its own floor:
# without one, a map that stopped parsing would hide behind the two literal
# arrays' 21 entries and this file would still report "profiles really parsed".
if [ "${addon_slug_count}" -ge 1 ] && [ "${addon_file_count}" -ge 1 ]; then
  ok "vacuity: the KIND_ADDONS map really parsed (${addon_slug_count} add-on(s), ${addon_file_count} app entr(ies))"
else
  bad "vacuity: the KIND_ADDONS map parsed ${addon_slug_count} add-on(s)/${addon_file_count} file(s) — the map parser has gone blind and every add-on's dependencies are unchecked"
fi
# Eight references exist today across the two profiles. A collapse to one or two
# means the extractor stopped seeing them; that is how the previous draft died.
if [ "${total_refs}" -ge 5 ]; then
  ok "vacuity: cross-references really extracted (${total_refs} found)"
else
  bad "vacuity: only ${total_refs} cross-reference(s) found — the reference scan has gone blind"
fi

# ── negative controls ──────────────────────────────────────────────────────
# EACH CONTROL IS A PAIR: the defective probe must FAIL and the corrected probe
# must PASS. A lone "the bad probe failed" assertion proves nothing, because a
# probe can fail for a reason that has nothing to do with the property under
# test. That is not hypothetical here: the first version of this file used 2- and
# 3-entry probes, which tripped the total_apps>=5 vacuity floor rather than the
# closure logic — so BOTH controls still reported PASS with the closure detection
# deleted outright. Adversarial review caught it. Every probe below therefore
# carries enough entries and references to clear both vacuity floors, so the only
# thing left that can distinguish the pair is the closure check itself.
echo "-- negative controls (each is a defect/no-defect PAIR) --"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/apps"
cp "${APPS}"/*.yaml "${T}/apps/" 2>/dev/null

# A padding set: real apps, no unsatisfied references between them.
PAD="06-route-access-db.yaml
30-admin-bff-db.yaml
34-user-bff-db.yaml
40-frontend.yaml
45-social-ui.yaml"

# The always-applied base a real bootstrap carries — the REAL CORE_APPS, entry for
# entry. 03/04 are here because 00b-cassandra-init genuinely depends on them (the
# ESO-derived cassandra-app-creds Secret its Job requires), so a fixture lacking
# them would fail for that reason rather than for the closure defect the control
# is meant to isolate.
#
# 02-vault + both Harbor apps joined it on 2026-08-26, when they moved out of
# bespoke `git show` blocks and into CORE_APPS. That was not optional either: the
# two Harbor ANALOGY exemptions were retired in the same change (the real base now
# satisfies those references), so a fixture whose base still lacked Harbor would
# report 00b-cassandra-init's two analogy references as violations and every
# CORRECTED probe would fail — the pair-cannot-distinguish failure this suite
# already learned once. The fixture must mirror production or it measures itself.
BASE_PAD="02-vault.yaml
06-vault-pki.yaml
03-external-secrets.yaml
04-external-secrets-config.yaml
11-ingress-nginx-internal.yaml
05-casdoor.yaml
03a-harbor.yaml
03b-harbor-provision.yaml"

write_probe() { # <file> <addon-map-body> <extra PROBE_APPS entries...>
  local out="$1"
  local mapbody="$2"
  shift 2
  # The fixture must carry the always-applied base, because the real file does.
  # A probe without it fails for a reason that has nothing to do with closure —
  # exactly the fixture-simpler-than-production trap this suite already fell into
  # once, with 2-entry probes tripping a vacuity floor instead of the logic.
  #
  # It must ALSO carry a KIND_ADDON_MAP block, for the same reason: the real file
  # has one, and the child run refuses to proceed without it. A fixture missing it
  # fails for the missing map, not for the defect under test — which is how a
  # control pair quietly stops distinguishing anything.
  { echo "${ALWAYS_APPLIED_ARRAY}=("
    printf '  %s\n' ${BASE_PAD}
    echo ")"
    echo 'KIND_ADDON_MAP="'
    [ -n "${mapbody}" ] && printf '%s\n' "${mapbody}"
    echo '"'
    echo "PROBE_APPS=("
    printf '  %s\n' ${PAD}
    for e in "$@"; do echo "  ${e}"; done
    echo ")"
  } > "${out}"
}
# The original signature, kept so the four pairs that predate the add-on map read
# unchanged: a benign one-entry map that satisfies its own closure.
probe() { # <file> <extra entries...>
  local out="$1"; shift
  write_probe "${out}" "metrics-server 01-metrics-server.yaml" "$@"
}

run_probe() { # <bootstrap> -> rc
  PROFILE_BOOTSTRAP="$1" PROFILE_APPS_DIR="${T}/apps" \
    bash "${BASH_SOURCE[0]}" --closure-only >/dev/null 2>&1
}

pair() { # <name> <bad-bootstrap> <good-bootstrap>
  local name="$1" bad="$2" good="$3"
  if run_probe "${bad}"; then
    bad_ "control '${name}': the DEFECTIVE probe was not caught"
  elif ! run_probe "${good}"; then
    bad_ "control '${name}': the CORRECTED probe also failed — the control cannot distinguish, so it proves nothing"
  else
    ok "control '${name}': defective probe caught, corrected probe clean"
  fi
}
bad_() { bad "$@"; }

# 1. the shipped defect: the chart without its bootstrap Job
probe "${T}/b1.sh" 00-cassandra.yaml 20-gateway-fe.yaml
probe "${T}/g1.sh" 00-cassandra.yaml 20-gateway-fe.yaml 00b-cassandra-init.yaml
pair "cassandra chart without cassandra-init" "${T}/b1.sh" "${T}/g1.sh"

# 2. a profile naming an Application that does not exist
probe "${T}/b2.sh" 00-cassandra.yaml 00b-cassandra-init.yaml 99-does-not-exist.yaml
probe "${T}/g2.sh" 00-cassandra.yaml 00b-cassandra-init.yaml
pair "profile lists a nonexistent Application" "${T}/b2.sh" "${T}/g2.sh"

# 3. an unterminated array must not be silently run past. The fixture carries the
#    base and a map so the ONLY defect in it is the missing closing paren.
{ echo "${ALWAYS_APPLIED_ARRAY}=("; printf '  %s\n' ${BASE_PAD}; echo ")"
  echo 'KIND_ADDON_MAP="'; echo "metrics-server 01-metrics-server.yaml"; echo '"'
  echo "PROBE_APPS=("; printf '  %s\n' ${PAD}; echo "  00-cassandra.yaml"; } > "${T}/b3.sh"
probe "${T}/g3.sh" 00-cassandra.yaml 00b-cassandra-init.yaml
pair "unterminated array" "${T}/b3.sh" "${T}/g3.sh"

# 5. THE MAP-DRIVEN PAIR — the vacuity hazard this refactor introduced. An
#    add-on row whose dependency is missing must be caught exactly like a profile
#    entry's is; if the map parser ever goes blind, the DEFECTIVE probe passes and
#    this pair fails. (00-cassandra.yaml names 00b-cassandra-init.yaml; 00b's own
#    ESO dependencies are satisfied by BASE_PAD, so the only unsatisfied reference
#    left in the bad fixture is the one under test.)
write_probe "${T}/b5.sh" "cassandra 00-cassandra.yaml"
write_probe "${T}/g5.sh" "cassandra 00-cassandra.yaml 00b-cassandra-init.yaml"
pair "add-on row without its bootstrap companion" "${T}/b5.sh" "${T}/g5.sh"

# 6. an add-on row with a slug and NO files is a checkbox that changes nothing.
write_probe "${T}/b6.sh" "metrics-server"
write_probe "${T}/g6.sh" "metrics-server 01-metrics-server.yaml"
pair "add-on row that maps to no app file" "${T}/b6.sh" "${T}/g6.sh"

# 7. an unterminated map block must not be run past to EOF (same rule as the
#    arrays). Written by hand because write_probe always closes the block.
{ echo "${ALWAYS_APPLIED_ARRAY}=("; printf '  %s\n' ${BASE_PAD}; echo ")"
  echo 'KIND_ADDON_MAP="'; echo "metrics-server 01-metrics-server.yaml"
  echo "PROBE_APPS=("; printf '  %s\n' ${PAD}; echo "  00-cassandra.yaml"
  echo "  00b-cassandra-init.yaml"; echo ")"; } > "${T}/b7.sh"
write_probe "${T}/g7.sh" "metrics-server 01-metrics-server.yaml" 00-cassandra.yaml 00b-cassandra-init.yaml
pair "unterminated KIND_ADDON_MAP block" "${T}/b7.sh" "${T}/g7.sh"

# 4. THE SABOTAGE CONTROL. Strip the closure detection out of a copy of this very
#    file and require that at least one pair then fails. If the controls still all
#    pass without the logic they exercise, they are theatre — which is exactly the
#    state adversarial review found this file in.
sed 's|violations+=("${prof}: ${key}   (${app} names it, but the set never applies it)")|true|' \
  "${BASH_SOURCE[0]}" > "${T}/apps/../sabotage.sh"
# CONFIRM THE SABOTAGE ACTUALLY LANDED. A sed whose pattern has drifted from the
# line it targets no-ops and still exits 0, so the "sabotaged" copy is byte-
# identical to this file, the defective probe is caught exactly as it should be,
# and this control reports FAIL for a reason that has nothing to do with the
# property under test. That happened on 2026-08-26 the moment the violation
# message was reworded ("the profile never applies it" -> "the set never applies
# it") — one word, and the only thing that pointed at it was the confusing
# failure text below. Assert the difference instead of assuming it.
if cmp -s "${T}/sabotage.sh" "${BASH_SOURCE[0]}"; then
  bad "sabotage control: the sabotage sed changed NOTHING — its pattern no longer matches the closure line it is supposed to delete, so this control is inert"
fi
cp "${T}/sabotage.sh" "${HERE}/.closure-sabotage.tmp.sh" 2>/dev/null
if PROFILE_BOOTSTRAP="${T}/b1.sh" PROFILE_APPS_DIR="${T}/apps" \
     bash "${HERE}/.closure-sabotage.tmp.sh" --closure-only >/dev/null 2>&1; then
  ok "sabotage control: with the closure check removed, the defective probe is NO LONGER caught — so the controls above really do exercise it"
else
  bad "sabotage control: the defective probe still 'fails' with the closure check removed — the controls are measuring something else"
fi
rm -f "${HERE}/.closure-sabotage.tmp.sh"

# 5. THE APPLY-SITE EXTRACTOR, as a defect/no-defect PAIR on a synthetic script.
#    The legs above rest on two pure functions — apply_loop_headers (which loops
#    actually call apply_core_app) and apply_loop_source (which headers preserve
#    declaration order). If either goes blind the legs report a tidy, wrong
#    answer instead of failing, which is the failure mode this whole file exists
#    to refuse. So feed both a script whose apply order is inverted the way
#    adversarial review inverted the real one, and a clean twin.
cat >"${T}/apply-clean.sh" <<'PROBE'
#!/usr/bin/env bash
apply_core_app() { :; }
for f in "${ADDON_APP_FILES[@]}"; do
  apply_core_app "${f}"
done
for f in "${CORE_APPS[@]}"; do
  apply_core_app "${f}"
done
for f in ${ADDON_APP_FILES[@]+"${ADDON_APP_FILES[@]}"}; do
  APP_NAMES+=("$(app_object_name "${f}")")
done
PROBE
sed -e 's|for f in "${CORE_APPS\[@\]}"; do|for f in $(printf "%s\\n" "${CORE_APPS[@]}" \| tac); do|' \
    "${T}/apply-clean.sh" >"${T}/apply-tac.sh"
if cmp -s "${T}/apply-clean.sh" "${T}/apply-tac.sh"; then
  bad "apply-site control: the tac sabotage changed NOTHING — the probe pair is inert"
else
  clean_hdrs="$(apply_loop_headers "${T}/apply-clean.sh")"
  tac_hdrs="$(apply_loop_headers "${T}/apply-tac.sh")"
  clean_srcs=""; tac_srcs=""; clean_rejected=0; tac_rejected=0
  while IFS= read -r h; do
    [ -n "${h}" ] || continue
    v="$(apply_loop_source "${h}")"
    if [ -n "${v}" ]; then clean_srcs="${clean_srcs}${v} "; else clean_rejected=$((clean_rejected+1)); fi
  done <<<"${clean_hdrs}"
  while IFS= read -r h; do
    [ -n "${h}" ] || continue
    v="$(apply_loop_source "${h}")"
    if [ -n "${v}" ]; then tac_srcs="${tac_srcs}${v} "; else tac_rejected=$((tac_rejected+1)); fi
  done <<<"${tac_hdrs}"
  # The clean twin: exactly the two apply loops, in order, both accepted — and
  # the APP_NAMES derivation loop (same array, no apply_core_app) NOT counted.
  if [ "${clean_srcs}" = "ADDON_APP_FILES CORE_APPS " ] && [ "${clean_rejected}" -eq 0 ]; then
    ok "apply-site control (no defect): the extractor reads both apply loops in order and ignores the non-applying APP_NAMES loop"
  else
    bad "apply-site control (no defect): expected 'ADDON_APP_FILES CORE_APPS ' with 0 rejects, got '${clean_srcs}' with ${clean_rejected} reject(s) — the extractor has gone blind and every apply-site leg above is reporting on a set it is not computing"
  fi
  if [ "${tac_rejected}" -ge 1 ]; then
    ok "apply-site control (defect): an apply loop piped through \`tac\` is REJECTED, so an inverted apply order cannot pass as declaration order"
  else
    bad "apply-site control (defect): the \`tac\` loop was accepted as a bare array expansion — the ORDER legs above would model a sequence the script does not perform"
  fi
fi

echo
echo "== kind profile app closure: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
