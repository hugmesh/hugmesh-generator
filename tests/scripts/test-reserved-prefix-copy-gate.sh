#!/usr/bin/env bash
# test-reserved-prefix-copy-gate.sh — regression test for the honesty of
# scripts/validate-reserved-prefixes.sh stage 7 (the ReservedNames.java code-copy
# assertion).
#
# WHY THIS EXISTS. Stage 7 is the gate's most valuable stage: it is the only thing
# that mechanically proves the app-repo ReservedNames.java copies still EQUAL the
# canonical specs/cluster/reserved-prefixes.yaml. Until 2026-07-29 an absent
# sibling checkout printed `[SKIP] … (not checked out)` and the run still ended
# `RESULT: PASS`, exit 0 — and the repo's own CI job checked out no siblings, so
# the assertion had literally never run in a pipeline while advertising green.
# That is not hypothetical: hugmesh-actions sat on main missing five canonical
# labels (character-forge, hmdm, attest, games-character-forge,
# games-shadows-of-the-net) through exactly this hole, and the copies' own javadoc
# records an earlier instance ("happened once already; fixed in #42").
#
# The contract this test pins, in one line: A RUN THAT DID NOT CHECK THE COPIES
# MUST NOT LOOK LIKE A RUN THAT DID.
#
#   (a) copies ABSENT            -> exit 3, `RESULT: INCOMPLETE`, never a clean PASS
#   (b) copies PRESENT + equal   -> exit 0, `RESULT: PASS`, and it says it checked
#                                   all declared copies
#   (c) copies PRESENT + drifted -> exit 1, `RESULT: FAIL` naming the label
#                                   (the NEGATIVE CONTROL: without it, (b) could be
#                                   green because the comparison is a no-op)
#   (d) PARTIAL (2 of 3 present) -> still INCOMPLETE, not PASS. The old
#                                   `any_checked` boolean got this wrong: one
#                                   present copy made the whole stage "checked",
#                                   so the copy that drifted could be the very one
#                                   silently skipped.
#   (e) explicit opt-out         -> exit 0 is allowed, but the verdict line must
#                                   still be the distinct `PASS (INCOMPLETE …)`.
#   (f) CI wiring                -> .gitlab-ci.yml's lint:reserved-prefixes must
#                                   actually provide the copies, else the job is
#                                   just the (a) failure on every pipeline.
#
# The sibling trees are SYNTHESISED from the canonical YAML into a temp dir, so
# this test needs no network, no sibling checkouts and no cluster — and it can
# construct the drift case, which a real checkout cannot be made to do on demand.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="${REPO}/scripts/validate-reserved-prefixes.sh"
CANON="${REPO}/specs/cluster/reserved-prefixes.yaml"
CI="${REPO}/.gitlab-ci.yml"

for f in "${GATE}" "${CANON}" "${CI}"; do
  [ -r "${f}" ] || { echo "  FAIL missing target: ${f}"; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
W="$(mktemp -d)"; trap 'rm -rf "${W}" 2>/dev/null' EXIT

# The three copies the gate declares in CODE_COPIES. Kept here as data so a
# mismatch with the script is visible (checked in section (f) below).
COPY_REPOS=(hugmesh-federation-api hugmesh-actions hugmesh-auth-core)
COPY_RELS=(
  src/main/java/net/hugmesh/federation/controller/ReservedNames.java
  src/main/java/net/hugmesh/actions/registration/ReservedNames.java
  src/main/java/net/hugmesh/authcore/reserved/ReservedNames.java
)
COPY_FIELDS=(RESERVED_LABELS RESERVED RESERVED)   # both field names are in use

# synth_root <dir> <n-copies-to-write> [label-to-drop]
# Writes the first N ReservedNames.java copies into <dir>, each carrying the
# canonical label set (minus [label-to-drop] if given, which manufactures drift).
synth_root() {
  local root="$1" n="$2" drop="${3:-}"
  local i
  for ((i = 0; i < n; i++)); do
    local dest="${root}/${COPY_REPOS[$i]}/${COPY_RELS[$i]}"
    mkdir -p "$(dirname "${dest}")"
    DROP="${drop}" FIELD="${COPY_FIELDS[$i]}" python3 - "${CANON}" "${dest}" <<'PY'
import os, sys, yaml
canon, dest = sys.argv[1], sys.argv[2]
drop = os.environ.get("DROP", "")
field = os.environ["FIELD"]
labels = [l for l in yaml.safe_load(open(canon))["spec"]["reserved"]
          if l.lower() != drop.lower()]
body = ",\n      ".join('"%s"' % l.lower() for l in labels)
open(dest, "w", encoding="utf-8").write(
    "package synthetic;\n"
    "import java.util.Set;\n"
    "public final class ReservedNames {\n"
    "  public static final Set<String> %s = Set.of(\n      %s\n  );\n"
    "}\n" % (field, body))
PY
  done
}

# run_gate <sibling-root> [env assignments…] -> RC in $RC, output in ${W}/out
run_gate() {
  local root="$1"; shift
  env "$@" RESERVED_SIBLING_ROOT="${root}" bash "${GATE}" >"${W}/out" 2>&1
  RC=$?
}

echo "== reserved-prefix code-copy gate: skip-honesty regression =="

# ── (a) copies ABSENT: must NOT report a clean PASS ──────────────────────────
echo "-- (a) sibling copies absent --"
mkdir -p "${W}/empty"
run_gate "${W}/empty"
[ "${RC}" -eq 3 ] \
  && ok "absent copies exit 3 (INCOMPLETE), not 0" \
  || bad "absent copies exited ${RC} — a run that skipped its own code-copy assertion must not exit 0"
grep -q "RESULT: INCOMPLETE" "${W}/out" \
  && ok "absent copies print the distinct 'RESULT: INCOMPLETE' verdict" \
  || bad "absent copies did not print 'RESULT: INCOMPLETE' (got: $(grep -c . "${W}/out") lines, last: $(tail -1 "${W}/out"))"
# The load-bearing assertion: the old behaviour printed exactly this line.
grep -q "^RESULT: PASS — canonical reserved set is consistent across all stages\.$" "${W}/out" \
  && bad "absent copies STILL print the clean 'RESULT: PASS' line — the silent-skip regression is back" \
  || ok "absent copies never print the clean 'RESULT: PASS' line"
grep -q "\[MISSING\]" "${W}/out" \
  && ok "each unchecked copy is reported [MISSING] with its resolved path" \
  || bad "unchecked copies are not individually reported as [MISSING]"
grep -q "\[SKIP\]" "${W}/out" \
  && bad "still emitting the old quiet [SKIP] marker" \
  || ok "the old quiet [SKIP] marker is gone"

# ── (b) copies PRESENT and equal: real PASS ──────────────────────────────────
echo "-- (b) all sibling copies present and matching canonical --"
synth_root "${W}/full" 3
run_gate "${W}/full"
[ "${RC}" -eq 0 ] \
  && ok "all copies present + matching exits 0" \
  || bad "all copies present + matching exited ${RC}: $(tail -3 "${W}/out")"
grep -q "^RESULT: PASS — canonical" "${W}/out" \
  && ok "all copies present + matching prints the clean PASS verdict" \
  || bad "all copies present + matching did not print the clean PASS verdict"
grep -q "all 3 declared copies were present and checked" "${W}/out" \
  && ok "the PASS states how many copies were actually checked" \
  || bad "the PASS does not state that every declared copy was checked"

# ── (c) NEGATIVE CONTROL: a drifted copy must FAIL ───────────────────────────
# Without this, (b) proves nothing: a comparison that always succeeds is green too.
echo "-- (c) negative control: a drifted copy must be caught --"
synth_root "${W}/drift" 3 "character-forge"
run_gate "${W}/drift"
[ "${RC}" -eq 1 ] \
  && ok "a copy missing 'character-forge' exits 1 (FAIL), not 0/3" \
  || bad "a copy missing 'character-forge' exited ${RC} — the code-copy comparison is vacuous"
grep -q "DRIFTED from canonical" "${W}/out" && grep -q "character-forge" "${W}/out" \
  && ok "the FAIL names the drifted copy and the missing label" \
  || bad "the FAIL does not name the drifted copy / label"

# ── (d) PARTIAL coverage must not count as checked ───────────────────────────
echo "-- (d) partial coverage (2 of 3 present) --"
synth_root "${W}/partial" 2
run_gate "${W}/partial"
[ "${RC}" -eq 3 ] \
  && ok "2-of-3 copies present is INCOMPLETE (exit 3), not PASS" \
  || bad "2-of-3 copies present exited ${RC} — one present copy must not certify the absent ones"
grep -q "could NOT run for 1 of 3" "${W}/out" \
  && ok "the INCOMPLETE report counts exactly the 1 unchecked copy" \
  || bad "the INCOMPLETE report does not count the unchecked copies correctly"
grep -q "\[OK\]   federation-api" "${W}/out" \
  && ok "the 2 present copies are still genuinely checked (partial != skip-all)" \
  || bad "the present copies were not checked in the partial case"

# ── (e) explicit opt-out: exit 0 allowed, clean PASS still forbidden ─────────
echo "-- (e) deliberate RESERVED_ALLOW_MISSING_COPIES=1 opt-out --"
run_gate "${W}/empty" RESERVED_ALLOW_MISSING_COPIES=1
[ "${RC}" -eq 0 ] \
  && ok "opt-out exits 0 (a local run without siblings is still usable)" \
  || bad "opt-out exited ${RC}, expected 0"
grep -q "RESULT: PASS (INCOMPLETE" "${W}/out" \
  && ok "opt-out still prints the distinct 'PASS (INCOMPLETE …)' verdict" \
  || bad "opt-out prints an indistinguishable verdict — a skipped run must stay labelled"
grep -q "^RESULT: PASS — canonical reserved set is consistent across all stages\.$" "${W}/out" \
  && bad "opt-out prints the clean PASS line — indistinguishable from a complete run" \
  || ok "opt-out never prints the clean PASS line"

# ── (f) CI must actually supply the copies ───────────────────────────────────
# Otherwise the gate is honest but permanently red: the job would hit (a) on every
# pipeline. Also pins the clone list to the script's CODE_COPIES, so adding a
# fourth copy to the script without cloning it in CI is caught here rather than by
# a surprise INCOMPLETE.
echo "-- (f) .gitlab-ci.yml lint:reserved-prefixes genuinely provides the copies --"
CI="${CI}" GATE="${GATE}" python3 - <<'PY' >"${W}/ci.out" 2>&1
import os, re, sys, yaml
ci = yaml.safe_load(open(os.environ["CI"]))
job = ci.get("lint:reserved-prefixes")
if not job:
    print("MISSING_JOB"); sys.exit(0)
blob = yaml.safe_dump(job)
# CODE_COPIES declared by the script (repo names, 2nd tuple element).
src = open(os.environ["GATE"], encoding="utf-8").read()
m = re.search(r"CODE_COPIES = \[(.*?)\n\]", src, re.S)
declared = re.findall(r'\(\s*"[^"]+",\s*"([^"]+)"', m.group(1)) if m else []
print("DECLARED", " ".join(declared))
missing = [r for r in declared if r not in blob]
print("NOT_CLONED", " ".join(missing) if missing else "-")
print("SETS_ROOT", "yes" if "RESERVED_SIBLING_ROOT" in blob else "no")
print("OPTS_OUT", "yes" if "RESERVED_ALLOW_MISSING_COPIES" in blob else "no")
print("HAS_PYYAML", "yes" if "pyyaml" in blob else "no")
PY
if grep -q MISSING_JOB "${W}/ci.out"; then
  bad "no lint:reserved-prefixes job in .gitlab-ci.yml"
else
  declared="$(sed -n 's/^DECLARED //p' "${W}/ci.out")"
  [ -n "${declared}" ] \
    && ok "parsed the script's CODE_COPIES repo list: ${declared}" \
    || bad "could not parse CODE_COPIES out of the gate script"
  grep -q "^NOT_CLONED -$" "${W}/ci.out" \
    && ok "CI clones every repo the script declares a copy in" \
    || bad "CI does not clone: $(sed -n 's/^NOT_CLONED //p' "${W}/ci.out") — the job would be INCOMPLETE every run"
  grep -q "^SETS_ROOT yes$" "${W}/ci.out" \
    && ok "CI points RESERVED_SIBLING_ROOT at the clone dir" \
    || bad "CI never sets RESERVED_SIBLING_ROOT — the clones would not be found"
  grep -q "^OPTS_OUT no$" "${W}/ci.out" \
    && ok "CI does NOT set the RESERVED_ALLOW_MISSING_COPIES escape hatch" \
    || bad "CI sets RESERVED_ALLOW_MISSING_COPIES — that re-opens the exact hole this gate closes"
  grep -q "^HAS_PYYAML yes$" "${W}/ci.out" \
    && ok "CI installs PyYAML (the script FATALs exit 2 without it)" \
    || bad "CI does not install PyYAML — the gate cannot even parse the canonical YAML"
fi

echo ""
echo "== reserved-prefix code-copy gate regression: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
