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
  "00b-cassandra-init.yaml -> 03a-harbor.yaml"
  "00b-cassandra-init.yaml -> 03b-harbor-provision.yaml"
  "15-kyverno.yaml -> 16-reserved-prefixes-policy.yaml"
)
EXEMPT_WHY=(
  "ANALOGY, not a dependency: 00b explains its own Helm-vs-git-path split with 'the same split as apps/03a-harbor.yaml (Helm) vs apps/03b-harbor-provision.yaml (git path)'. Cassandra's init needs nothing from Harbor."
  "ANALOGY, not a dependency: the second half of the Harbor split cited above."
  "REVERSE DIRECTION, not a missing bootstrap: kyverno is the policy ENGINE and 16-reserved-prefixes-policy is one CONSUMER of it. The dependency runs 16 -> 15; 15's header names 16 only to explain why the engine was introduced at all. Kyverno needs nothing from it. Verified live 2026-08-22: kyverno runs Synced/Healthy on the kind cluster serving workload-console-rbac's deploy-provenance ClusterPolicy while 16-reserved-prefixes-policy is not applied there at all. NOTE THE REAL CONSEQUENCE, which this exemption does NOT paper over: the reserved-prefix vanity-collision rule is therefore UNENFORCED on kind. That predates this list gaining kyverno — the profile has never applied 16 — and adding it is a separate decision, because it is another Enforce ClusterPolicy whose blast radius on a local cluster has not been measured."
)

# THE TWO EXEMPTIONS THAT USED TO BE HERE WERE A LIE, AND THE LIE WAS LOAD-BEARING.
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

total_apps=0
total_refs=0
declare -a violations=()
used_exemptions=()

# The always-applied base. Every profile's effective set includes it.
base_listing="$(list_profile "${ALWAYS_APPLIED_ARRAY}")"; base_rc=$?
mapfile -t base_apps <<<"${base_listing}"
tmp=(); for l in ${base_apps[@]+"${base_apps[@]}"}; do [ -n "${l}" ] && tmp+=("${l}"); done
base_apps=(${tmp[@]+"${tmp[@]}"})
if [ "${base_rc}" -ne 0 ] || [ "${#base_apps[@]}" -eq 0 ]; then
  bad "${ALWAYS_APPLIED_ARRAY} could not be parsed (rc=${base_rc}, ${#base_apps[@]} entries) — every profile's effective set depends on it, so this gate cannot run"
fi

for prof in ${profiles}; do
  listing="$(list_profile "${prof}")"; rc=$?
  if [ "${rc}" -eq 2 ]; then
    bad "${prof}: array is never closed — refusing to guess where it ends"
    continue
  fi
  mapfile -t listed <<<"${listing}"
  # drop empties
  tmp=(); for l in ${listed[@]+"${listed[@]}"}; do [ -n "${l}" ] && tmp+=("${l}"); done
  listed=(${tmp[@]+"${tmp[@]}"})
  [ "${#listed[@]}" -gt 0 ] || { bad "${prof}: parsed ZERO app entries — the parser is not reading the array"; continue; }
  total_apps=$((total_apps + ${#listed[@]}))
  [ "${CHILD}" = yes ] || echo "-- ${prof}: ${#listed[@]} application(s) --"

  for app in "${listed[@]}"; do
    f="${APPS}/${app}"
    if [ ! -r "${f}" ]; then
      violations+=("${prof}: lists ${app}, which does not exist in ${APPS#${REPO}/}")
      continue
    fi
    for ref in $(grep -ohE 'apps/[0-9][0-9a-z-]*\.yaml' "${f}" | sed 's|apps/||' | sort -u); do
      [ "${ref}" = "${app}" ] && continue           # self-reference is not a dependency
      total_refs=$((total_refs + 1))
      # Satisfied by this profile's own list OR by the always-applied base.
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
        violations+=("${prof}: ${key}   (${app} names it, but the profile never applies it)")
      fi
    done
  done
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

# ── vacuity: a run that inspected nothing must not pass ────────────────────
if [ "${total_apps}" -ge 5 ]; then
  ok "vacuity: profiles really parsed (${total_apps} app entries)"
else
  bad "vacuity: only ${total_apps} app entries parsed — the array parser is broken"
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

# The always-applied base a real bootstrap carries. 03/04 are here because
# 00b-cassandra-init genuinely depends on them (the ESO-derived cassandra-app-creds
# Secret its Job requires), so a fixture lacking them would fail for that reason
# rather than for the closure defect the control is meant to isolate.
BASE_PAD="06-vault-pki.yaml
03-external-secrets.yaml
04-external-secrets-config.yaml
11-ingress-nginx-internal.yaml
05-casdoor.yaml"

probe() { # <file> <extra entries...> -> writes a bootstrap with CORE_APPS + PROBE_APPS
  local out="$1"; shift
  # The fixture must carry the always-applied base, because the real file does.
  # A probe without it fails for a reason that has nothing to do with closure —
  # exactly the fixture-simpler-than-production trap this suite already fell into
  # once, with 2-entry probes tripping a vacuity floor instead of the logic.
  { echo "${ALWAYS_APPLIED_ARRAY}=("
    printf '  %s\n' ${BASE_PAD}
    echo ")"
    echo "PROBE_APPS=("
    printf '  %s\n' ${PAD}
    for e in "$@"; do echo "  ${e}"; done
    echo ")"
  } > "${out}"
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

# 3. an unterminated array must not be silently run past
{ echo "PROBE_APPS=("; printf '  %s\n' ${PAD}; echo "  00-cassandra.yaml"; } > "${T}/b3.sh"
probe "${T}/g3.sh" 00-cassandra.yaml 00b-cassandra-init.yaml
pair "unterminated array" "${T}/b3.sh" "${T}/g3.sh"

# 4. THE SABOTAGE CONTROL. Strip the closure detection out of a copy of this very
#    file and require that at least one pair then fails. If the controls still all
#    pass without the logic they exercise, they are theatre — which is exactly the
#    state adversarial review found this file in.
sed 's|violations+=("${prof}: ${key}   (${app} names it, but the profile never applies it)")|true|' \
  "${BASH_SOURCE[0]}" > "${T}/apps/../sabotage.sh"
cp "${T}/sabotage.sh" "${HERE}/.closure-sabotage.tmp.sh" 2>/dev/null
if PROFILE_BOOTSTRAP="${T}/b1.sh" PROFILE_APPS_DIR="${T}/apps" \
     bash "${HERE}/.closure-sabotage.tmp.sh" --closure-only >/dev/null 2>&1; then
  ok "sabotage control: with the closure check removed, the defective probe is NO LONGER caught — so the controls above really do exercise it"
else
  bad "sabotage control: the defective probe still 'fails' with the closure check removed — the controls are measuring something else"
fi
rm -f "${HERE}/.closure-sabotage.tmp.sh"

echo
echo "== kind profile app closure: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
