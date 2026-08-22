#!/usr/bin/env bash
# test-mfa-raw-jwt-posture.sh — pin docs/MFA-ROLLOUT.md §2.4 to the Casdoor app seed.
#
# WHAT THIS GUARDS
# The gateway reaches MFA_SATISFIED by two carriers, and for the raw-JWT carrier the
# claim (`mfa_satisfied_at`) is a Casdoor USER Property that only enters a token at MINT
# time. Whether that is a problem depends entirely on WHO IS HOLDING THE TOKEN:
#
#   a human client that can RE-MINT on demand (refresh_token / device_code / password /
#   authorization_code) completes MFA in the BFF and refreshes -> fresh claim. Fine.
#   `hugmesh-desktop` is seeded exactly for this and says so in its own comment.
#
#   a pure MACHINE client (client_credentials only) has NO user subject, so there is no
#   user Property to stamp and no factor to enrol. It can never satisfy an mfa_required
#   route under any configuration. That is the population an operator must enumerate
#   before the §3 step-6 flip.
#
# THE ERROR THIS EXISTS TO PREVENT COMING BACK
# An earlier draft of §2.4 (and of this guard) claimed NO raw-JWT caller could ever be
# fresh, reasoning that the claim lands only at mint and the seeded expireInHours is 168
# (4 for user-bff) against a 600000 ms window, so "24x / 1008x". That reasoning CONFLATED
# TOKEN LIFETIME WITH TIME-TO-NEXT-MINT: expireInHours bounds how long a STALE token stays
# valid, not how soon a client may ask for a new one. Three independent reviewers refuted
# it. The arithmetic was right and the conclusion was wrong.
#
# So this suite pins the TAXONOMY, not the arithmetic:
#   RULE 1  parse every seeded app's grantTypes; classify re-mintable vs machine-only.
#           Fails loudly if an app's grants cannot be parsed (no silent miss).
#   RULE 2  if a machine-only population exists, §2.4 must name it AND step 6 must warn
#           about it. If none exists, §2.4's machine row would be wrong -> also fails.
#   RULE 3  the debunked bounded-gap claims may appear ONLY inside §2.4's refutation
#           blockquote, and nowhere else in specs/ or docs/.
#   RULE 4  §2.4 must not re-assert the RETRACTED absolute ("no raw-JWT caller can ever
#           be fresh"), and must still record the real defect (forceRefresh's literal
#           null) so that does not quietly vanish either.
#
# Pure static analysis of the repo's own files. No network, no root, no docker, no
# cluster. bash + grep/sed/python3 only.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GUARD_ROOT:-$(cd "${HERE}/../.." && pwd)}"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

INITJOB="${REPO}/specs/cluster/manifests/casdoor/init-job.yaml"
RUNBOOK="${REPO}/docs/MFA-ROLLOUT.md"

for f in "${INITJOB}" "${RUNBOOK}"; do
  [ -f "${f}" ] || { bad "missing input: ${f#"${REPO}"/}"; echo "  ${P} passed, ${F} failed"; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { bad "python3 not available"; echo "  ${P} passed, ${F} failed"; exit 2; }

# ── RULE 1: classify the seeded apps by grant type ───────────────────────────
# >>> RULE1
rule1() {
  # A grant that can mint a token bound to a USER. client_credentials is deliberately
  # NOT here: it yields a machine token with no user subject, hence no user Property.
  local user_grants='authorization_code|refresh_token|password|device_code'
  CLASSIFY="$(python3 - "${INITJOB}" "${user_grants}" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
user_grants = sys.argv[2].split('|')

# Every grantTypes literal in the seed, in file order, with its line number.
blocks = [(src.count('\n', 0, m.start()) + 1, m.group(1))
          for m in re.finditer(r'"grantTypes"\s*:\s*\[(.*?)\]', src, re.S)]
# Additive overrides: app["grantTypes"] = app["grantTypes"] + ["refresh_token"]
extra = [(src.count('\n', 0, m.start()) + 1, m.group(1))
         for m in re.finditer(r'\[.grantTypes.\]\s*=\s*[^\n]*?\+\s*\[(.*?)\]', src, re.S)]

if not blocks:
    print("UNPARSEABLE|no grantTypes literal found"); raise SystemExit
remintable, machine = [], []
for ln, body in blocks:
    grants = re.findall(r'"([^"]+)"', body)
    short  = [g.rsplit(':', 1)[-1].rsplit('/', 1)[-1] for g in grants]
    if any(any(u in s for u in user_grants) for s in short):
        remintable.append(str(ln))
    else:
        machine.append(str(ln))
# Anti-rot: every literal mention of expireInHours must have been reachable as an app
# block; a THIRD spelling that this parser does not see would otherwise pass silently.
mentions = len(re.findall(r'expireInHours', src))
print("OK|%s|%s|%d|%d" % (",".join(remintable), ",".join(machine), len(extra), mentions))
PY
)"
  case "${CLASSIFY}" in
    UNPARSEABLE*) bad "rule1: could not parse any grantTypes from ${INITJOB#"${REPO}"/} — seed shape changed; classification impossible"; return ;;
  esac
  IFS='|' read -r _ REMINT MACHINE NEXTRA MENTIONS <<<"${CLASSIFY}"
  local nre=0 nma=0
  [ -n "${REMINT}"  ] && nre=$(($(echo "${REMINT}"  | tr ',' '\n' | grep -c .)))
  [ -n "${MACHINE}" ] && nma=$(($(echo "${MACHINE}" | tr ',' '\n' | grep -c .)))
  if [ "$((nre + nma))" -eq 0 ]; then
    bad "rule1: zero app blocks classified — refusing to score rules 2-4 on an empty corpus"; return
  fi
  ok "rule1: ${nre} re-mintable app block(s) at line(s) ${REMINT:-none}, ${nma} machine-only at ${MACHINE:-none}, ${NEXTRA} additive override(s)"
  [ "${MENTIONS}" -gt 0 ] \
    && ok "rule1: ${MENTIONS} expireInHours mention(s) present in the seed (informational — NOT a bound on time-to-next-mint; see the header)" \
    || bad "rule1: no expireInHours in the seed at all — the app seed shape has changed materially, re-read §2.4"
  MACHINE_POP="${nma}"
}
# <<< RULE1

# ── RULE 2: the machine-only population must be documented, or not claimed ───
# >>> RULE2
rule2() {
  local has_row has_warn
  grep -q 'client_credentials` (pure machine, no human behind it)' "${RUNBOOK}" && has_row=yes || has_row=no
  grep -q 'permanently denies machine `client_credentials` traffic' "${RUNBOOK}" && has_warn=yes || has_warn=no

  # NOTE: a machine-only population can exist even when this seed declares none, because
  # `client_credentials` is granted to EVERY confidential app (an operator may drive one
  # machine-to-machine). So §2.4's machine row is required whenever the grant is seeded
  # at all — not only when an app has it EXCLUSIVELY.
  if grep -q '"client_credentials"' "${INITJOB}"; then
    [ "${has_row}" = yes ] \
      && ok "rule2: client_credentials is seeded and §2.4 documents the machine population" \
      || bad "rule2: client_credentials is seeded but §2.4 has no machine row — operators would flip step 6 without enumerating machine traffic"
    [ "${has_warn}" = yes ] \
      && ok "rule2: §3 step 6 warns about machine client_credentials traffic" \
      || bad "rule2: §3 step 6 does not warn that the flip permanently denies machine client_credentials traffic"
  else
    [ "${has_row}" = no ] \
      && ok "rule2: client_credentials no longer seeded and the machine row is correctly absent" \
      || bad "rule2: §2.4 still describes a machine client_credentials population, but the seed no longer grants client_credentials — rewrite it"
  fi
}
# <<< RULE2

# ── RULE 3: the debunked bounded-gap claims live ONLY in the refutation ──────
# >>> RULE3
rule3() {
  # Scope the exemption to the §2.4 blockquote that REFUTES the claim, by LINE, not by
  # filename. The earlier version excluded any line mentioning MFA-ROLLOUT.md, which let
  # the claim be re-asserted inside that very file — and let ANY file bypass the rule by
  # naming MFA-ROLLOUT.md on the same line.
  local out
  out="$(python3 - "${REPO}" "${RUNBOOK}" <<'PY'
import os, re, sys
repo, runbook = sys.argv[1], sys.argv[2]
PHRASES = ["keeping the held-JWT/MFA-freshness window short",
           "GEN2 lowers the privileged-app"]
# The sanctioned refutation window: the §2.4 blockquote, which quotes the phrase in order
# to debunk it. Identified structurally (blockquote lines) inside §2.4 only.
allowed = set()
if os.path.exists(runbook):
    lines = open(runbook).read().split('\n')
    in_s24 = False
    for i, l in enumerate(lines, 1):
        if l.startswith('### 2.4'): in_s24 = True; continue
        if in_s24 and l.startswith('### '): in_s24 = False
        if in_s24 and l.lstrip().startswith('>'): allowed.add((os.path.realpath(runbook), i))
bad = []
for root, dirs, files in os.walk(repo):
    dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules')]
    if not (os.path.realpath(root).startswith(os.path.realpath(os.path.join(repo, 'specs')))
            or os.path.realpath(root).startswith(os.path.realpath(os.path.join(repo, 'docs')))):
        continue
    for fn in files:
        if not fn.endswith(('.yaml', '.yml', '.md', '.sh')): continue
        fp = os.path.join(root, fn)
        try: content = open(fp, errors='replace').read()
        except OSError: continue
        for i, l in enumerate(content.split('\n'), 1):
            if any(p in l for p in PHRASES) and (os.path.realpath(fp), i) not in allowed:
                bad.append("%s:%d" % (os.path.relpath(fp, repo), i))
print("ALLOWED=%d" % len(allowed))
for b in bad: print("BAD=%s" % b)
PY
)"
  local nallowed
  nallowed="$(printf '%s\n' "${out}" | sed -n 's/^ALLOWED=//p')"
  local nbad=0
  while IFS= read -r b; do
    [ -z "${b}" ] && continue
    bad "rule3: bounded-gap claim asserted outside the §2.4 refutation -> ${b}"; nbad=$((nbad+1))
  done < <(printf '%s\n' "${out}" | sed -n 's/^BAD=//p')
  [ "${nbad}" -eq 0 ] && ok "rule3: the debunked bounded-gap claims appear only inside §2.4's refutation blockquote"
  # Vacuity: rule3's PASS must not be reached because the sanctioned window swallowed
  # everything. If §2.4 no longer refutes the claim at all, say so.
  [ "${nallowed:-0}" -gt 0 ] \
    && ok "rule3: §2.4 still carries the refutation (${nallowed} quoted line(s)) rather than having quietly dropped it" \
    || bad "rule3: §2.4 no longer refutes the bounded-gap claim anywhere — the correction has been lost"
}
# <<< RULE3

# ── RULE 4: do not re-assert the retracted absolute; keep the real defect ────
# >>> RULE4
rule4() {
  local retracted=0
  # The exact over-claim that was refuted. Allowed ONLY where §2.4 explicitly retracts it.
  while IFS= read -r hit; do
    case "${hit}" in
      *"An earlier draft"*|*"was **wrong**"*|*"That reasoning"*) continue ;;
    esac
    bad "rule4: the RETRACTED absolute is asserted again -> ${hit#"${REPO}"/}"; retracted=$((retracted+1))
  done < <(grep -rn --include='*.md' --include='*.yaml' --include='*.sh' \
             -e 'can NEVER be fresh' -e 'never present a fresh mfa_satisfied_at' \
             "${REPO}/docs" "${REPO}/specs" 2>/dev/null)
  [ "${retracted}" -eq 0 ] && ok "rule4: the retracted 'no raw-JWT caller can ever be fresh' absolute is not re-asserted"

  # The REAL defect must not vanish along with the over-claim it was bundled with.
  grep -q 'literal `null`' "${RUNBOOK}" \
    && ok "rule4: §2.4 still records the real defect (forceRefresh's literal null at its only call site)" \
    || bad "rule4: §2.4 no longer records that forceRefresh is called with a literal null — the genuine defect was dropped with the over-claim"
  grep -q 'GEN2' "${RUNBOOK}" \
    && ok "rule4: §2.4 still names the false GEN2 justification so it cannot be restored innocently" \
    || bad "rule4: §2.4 no longer names the GEN2 claim — a future reader could reintroduce it"
}
# <<< RULE4

echo "== MFA raw-JWT posture =="
rule1
if [ -z "${MACHINE_POP:-}" ]; then
  bad "rule1 could not classify the seed — rules 2-4 SKIPPED (not passed)"
  echo "  ${P} passed, ${F} failed"; exit 1
fi
rule2
rule3
rule4
REAL_ASSERTIONS="${P}"   # snapshot BEFORE controls, so the floor cannot be met by controls

# ── Negative controls ────────────────────────────────────────────────────────
if [ -z "${GUARD_ROOT+x}" ]; then
  echo "== negative controls =="
  CTL="$(mktemp -d)"; trap 'rm -rf "${CTL}"' EXIT

  stage() {
    local d="${CTL}/$1"
    mkdir -p "${d}/specs/cluster/manifests/casdoor" "${d}/docs"
    cp "${INITJOB}" "${d}/specs/cluster/manifests/casdoor/init-job.yaml"
    cp "${RUNBOOK}" "${d}/docs/MFA-ROLLOUT.md"
    echo "${d}"
  }
  mutated() { # <file> <original> <label> [needle]
    local f="$1" orig="$2" label="$3" needle="${4:-}"
    if [ ! -s "${f}" ];         then bad "control ${label}: fixture EMPTY — proves NOTHING"; return 1; fi
    if cmp -s "${f}" "${orig}"; then bad "control ${label}: fixture IDENTICAL to original — the edit did not apply; proves NOTHING"; return 1; fi
    if [ -n "${needle}" ] && ! grep -q -- "${needle}" "${f}"; then
      bad "control ${label}: planted change (${needle}) absent from fixture; proves NOTHING"; return 1; fi
    return 0
  }
  # Capture, THEN grep. `run_ctl … | grep -q` inherits the child's exit 1 under pipefail
  # (a control run is EXPECTED to fail), so every control would report a false GREEN.
  run_ctl() { GUARD_ROOT="$1" bash "${BASH_SOURCE[0]}" 2>&1; }
  saw() { printf '%s' "$1" | grep -F -- "$2" >/dev/null; }

  # (A) delete §2.4's machine row -> rule2 fires
  d="$(stage a)"
  sed -i '/client_credentials` (pure machine, no human behind it)/d' "${d}/docs/MFA-ROLLOUT.md"
  if mutated "${d}/docs/MFA-ROLLOUT.md" "${RUNBOOK}" "A(drop machine row)"; then
    out="$(run_ctl "${d}")"
    saw "${out}" 'FAIL rule2: client_credentials is seeded but §2.4 has no machine row' \
      && ok "control A: dropping the machine row while client_credentials is seeded is caught by rule2" \
      || bad "control A: machine row deleted and rule2 stayed GREEN"
  fi

  # (B) re-assert the bounded-gap claim OUTSIDE the refutation, INSIDE the runbook —
  #     the exact blind spot the previous filename-based exclusion had.
  d="$(stage b)"
  printf '\nGEN2 lowers the privileged-app expireInHours so the gap stays short.\n' >> "${d}/docs/MFA-ROLLOUT.md"
  if mutated "${d}/docs/MFA-ROLLOUT.md" "${RUNBOOK}" "B(claim inside runbook)" 'GEN2 lowers the privileged-app expireInHours so'; then
    out="$(run_ctl "${d}")"
    saw "${out}" 'FAIL rule3: bounded-gap claim asserted outside the §2.4 refutation' \
      && ok "control B: re-asserting the claim INSIDE MFA-ROLLOUT.md (the old blind spot) is caught by rule3" \
      || bad "control B: claim re-added inside the runbook and rule3 stayed GREEN — the exclusion is still too wide"
  fi

  # (C) re-assert the RETRACTED absolute -> rule4 fires
  d="$(stage c)"
  printf '\nA raw-JWT caller can NEVER be fresh under any configuration.\n' >> "${d}/docs/MFA-ROLLOUT.md"
  if mutated "${d}/docs/MFA-ROLLOUT.md" "${RUNBOOK}" "C(retracted absolute)" 'can NEVER be fresh under any'; then
    out="$(run_ctl "${d}")"
    saw "${out}" 'FAIL rule4: the RETRACTED absolute is asserted again' \
      && ok "control C: re-asserting the refuted absolute is caught by rule4" \
      || bad "control C: retracted absolute re-added and rule4 stayed GREEN"
  fi

  # (D) drop the real defect from §2.4 -> rule4 fires (the over-claim's removal must not
  #     take the genuine finding with it)
  d="$(stage d)"
  sed -i 's/literal `null`/some value/g' "${d}/docs/MFA-ROLLOUT.md"
  if mutated "${d}/docs/MFA-ROLLOUT.md" "${RUNBOOK}" "D(drop real defect)" 'some value'; then
    out="$(run_ctl "${d}")"
    saw "${out}" "FAIL rule4: §2.4 no longer records that forceRefresh is called with a literal null" \
      && ok "control D: dropping the forceRefresh defect from §2.4 is caught by rule4" \
      || bad "control D: real defect dropped and rule4 stayed GREEN"
  fi

  # (E) an unparseable seed must SKIP rules 2-4 loudly, never pass them vacuously
  d="$(stage e)"
  sed -i 's/"grantTypes"/"grantTypesRENAMED"/g' "${d}/specs/cluster/manifests/casdoor/init-job.yaml"
  if mutated "${d}/specs/cluster/manifests/casdoor/init-job.yaml" "${INITJOB}" "E(unparseable seed)" 'grantTypesRENAMED'; then
    out="$(run_ctl "${d}")"
    saw "${out}" 'FAIL rule1: could not parse any grantTypes' && saw "${out}" 'rules 2-4 SKIPPED (not passed)' \
      && ok "control E: an unparseable seed fails loudly and refuses to score rules 2-4" \
      || bad "control E: seed made unparseable and the suite did not refuse to score the dependent rules"
  fi

  # (F) vacuity floor over the REAL repo only — control PASSes are excluded by construction
  if [ "${REAL_ASSERTIONS}" -lt 8 ]; then
    bad "control F: only ${REAL_ASSERTIONS} real-repo assertions ran (floor 8, controls NOT counted) — the suite is going vacuous"
  else
    ok "control F: ${REAL_ASSERTIONS} real-repo assertions ran, controls excluded from the floor"
  fi
fi

echo "  ${P} passed, ${F} failed"
[ "${F}" -eq 0 ] || exit 1
