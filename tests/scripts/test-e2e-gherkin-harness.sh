#!/usr/bin/env bash
# test-e2e-gherkin-harness.sh — the ANTI-DECORATION gate for the Gherkin lane.
#
# WHY THIS EXISTS. A .feature file that is never executed is worse than no file:
# it looks like coverage. This repo already carries 229 .feature files under
# .stack-src/, and .stack-src is gitignored and reset by `make stack-clone`, so
# none of them is ours and none of them gates anything here. The moment
# tests/e2e/features/ exists, the only thing standing between "executable Gherkin"
# and "a directory of English prose" is a guard that FAILS when a feature stops
# being compiled and run.
#
# WHAT IT ASSERTS
#   1. Every tests/e2e/features/**/*.feature is picked up by the generator, and
#      the number of GENERATED Playwright tests equals the number of Gherkin
#      scenarios (Scenario Outlines counted per Examples row). Off-by-anything is
#      a feature, an Examples block or a whole file that silently stopped running.
#   2. Every step used in a .feature has a matching step definition. playwright-bdd
#      is configured missingSteps:'fail-on-gen', so an undefined step FAILS
#      generation — this guard proves that configuration is live rather than
#      trusting it, by running the generator over a tree that has one.
#   3. No generated artefact is git-tracked. A committed .features-gen file goes
#      stale the moment a .feature changes and then runs the OLD scenario.
#   4. No stray .feature lives outside the scanned directory (a feature under
#      tests/ but outside tests/e2e/features/ is invisible to the generator and
#      would be pure decoration). .stack-src is excluded: it is a gitignored
#      vendor checkout of OTHER repos' suites.
#
# NEGATIVE CONTROLS. Checks 1-4 are re-run against synthesised copies of the tree
# carrying each defect ON PURPOSE, so a green run cannot be vacuous. The copies
# live under a scratch dir and share the real node_modules by symlink; the real
# tests/e2e tree is never written to.
#
# OFFLINE. No stack, no network, no cluster. Needs node + the installed
# tests/e2e/node_modules only, and says so loudly (exit 2) when they are absent —
# it never exits 0 having checked nothing.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
E2E="${REPO}/tests/e2e"
FEATURES="${E2E}/features"
GEN="${E2E}/.features-gen"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== e2e Gherkin harness: every .feature generates, binds and runs =="

# ── preconditions: refuse to be vacuous ──────────────────────────────────────
for t in node python3 git; do
  command -v "${t}" >/dev/null 2>&1 || {
    echo "SKIPPED-LOUDLY: ${t} is required and absent — this guard checked NOTHING." >&2
    exit 2
  }
done
if [ ! -d "${E2E}/node_modules/playwright-bdd" ]; then
  echo "SKIPPED-LOUDLY: ${E2E}/node_modules/playwright-bdd is missing — run" >&2
  echo "  (cd ${E2E} && npm install)   [or: make playwright-deps]" >&2
  echo "This guard checked NOTHING. Exiting 2 rather than 0." >&2
  exit 2
fi
if [ ! -d "${FEATURES}" ]; then
  bad "tests/e2e/features/ does not exist — the Gherkin lane is gone"
  echo; echo "== e2e Gherkin harness: ${P} passed, ${F} failed =="
  [ "${F}" -eq 0 ]
  exit
fi

SCRATCH="${TMPDIR:-/var/tmp/portage}/gherkin-guard.$$"
mkdir -p "${SCRATCH}"
cleanup() { rm -rf "${SCRATCH}"; }
trap cleanup EXIT

# expected_scenarios <features-dir> — Gherkin scenario count, Outlines expanded
# per Examples data row. Deliberately dumb and deliberately in python: counting
# Examples rows in shell is where an off-by-one hides.
expected_scenarios() {
  FEAT_DIR="$1" python3 - <<'PY'
import os, re, sys
root = os.environ["FEAT_DIR"]
total = 0
SCEN = re.compile(r'^\s*(Scenario|Example|Scenario Outline|Scenario Template)\s*:', re.I)
OUTLINE = re.compile(r'^\s*(Scenario Outline|Scenario Template)\s*:', re.I)
EXAMPLES = re.compile(r'^\s*(Examples|Scenarios)\s*:', re.I)
for dirpath, _dirs, files in os.walk(root):
    for fn in sorted(files):
        if not fn.endswith(".feature"):
            continue
        lines = open(os.path.join(dirpath, fn), encoding="utf-8").read().split("\n")
        i = 0
        while i < len(lines):
            line = lines[i]
            if OUTLINE.match(line):
                # walk forward: every Examples block contributes (rows - header)
                i += 1
                while i < len(lines) and not SCEN.match(lines[i]) and not re.match(r'^\s*Feature\s*:', lines[i], re.I):
                    if EXAMPLES.match(lines[i]):
                        i += 1
                        rows = 0
                        seen_header = False
                        while i < len(lines) and (lines[i].strip().startswith("|")
                                                  or not lines[i].strip()
                                                  or lines[i].strip().startswith("#")
                                                  or lines[i].strip().startswith("@")):
                            s = lines[i].strip()
                            if s.startswith("|"):
                                if seen_header:
                                    rows += 1
                                else:
                                    seen_header = True
                            elif s.startswith("@") or (not s and not seen_header):
                                pass
                            elif not s:
                                pass
                            i += 1
                        total += rows
                        continue
                    i += 1
                continue
            if SCEN.match(line):
                total += 1
            i += 1
print(total)
PY
}

# generated_tests <gen-dir> — count of the test declarations in the generated
# specs. `test(` is the ordinary case; `test.fixme(` / `test.skip(` are what
# playwright-bdd emits for a scenario tagged @fixme / @skip — an explicitly
# PENDING scenario with a named reason (generate/specialTags.js). Those must
# COUNT: they are still generated, still bound (an undefined step in one still
# fails bddgen), still listed, and still reported — as a named skip, never
# silently. Not counting them made every honest pending scenario read to this
# guard as a scenario that generates nothing, i.e. as the decoration it is the
# opposite of. test.describe/test.use/test.beforeEach still do not match: the
# alternation below is anchored on the exact three forms.
generated_tests() {
  GEN_DIR="$1" python3 - <<'PY'
import os, re
root = os.environ["GEN_DIR"]
n = 0
if os.path.isdir(root):
    for dirpath, _d, files in os.walk(root):
        for fn in files:
            if fn.endswith(".spec.js") or fn.endswith(".spec.ts"):
                text = open(os.path.join(dirpath, fn), encoding="utf-8").read()
                n += len(re.findall(r'^\s*test(?:\.fixme|\.skip)?\(', text, re.M))
print(n)
PY
}

count_features() { find "$1" -name '*.feature' -type f 2>/dev/null | wc -l | tr -d ' '; }

# ── 1) the real tree GENERATES ───────────────────────────────────────────────
echo
echo "-- 1) every .feature is compiled by the generator --"
FEAT_N="$(count_features "${FEATURES}")"
if [ "${FEAT_N}" -eq 0 ]; then
  bad "ZERO .feature files under tests/e2e/features — this guard would be vacuous"
else
  ok "found ${FEAT_N} .feature file(s) under tests/e2e/features"
fi

GENLOG="${SCRATCH}/bddgen.log"
( cd "${E2E}" && npx bddgen ) >"${GENLOG}" 2>&1
GENRC=$?
if [ "${GENRC}" -ne 0 ]; then
  bad "npx bddgen FAILED (rc=${GENRC}) over the real tree — an undefined/ambiguous step, or a broken .feature:"
  sed 's/^/         /' "${GENLOG}"
else
  ok "npx bddgen succeeded over the real tree (every step in every .feature is bound)"
fi

GEN_FILES="$(find "${GEN}" -name '*.feature.spec.js' -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "${GEN_FILES}" -ne "${FEAT_N}" ]; then
  bad "generator produced ${GEN_FILES} spec file(s) for ${FEAT_N} .feature file(s) — a feature is NOT being picked up"
  echo "         (check playwright.config.ts defineBddConfig features glob)"
else
  ok "generator produced one spec file per .feature (${GEN_FILES})"
fi

EXP="$(expected_scenarios "${FEATURES}")"
GOT="$(generated_tests "${GEN}")"
if [ "${EXP}" != "${GOT}" ]; then
  bad "scenario count MISMATCH: ${EXP} Gherkin scenario(s)/Examples row(s) but ${GOT} generated test(s)"
  echo "         A scenario that generates nothing is decoration: it reads as coverage and never runs."
else
  ok "scenario count matches: ${EXP} Gherkin scenarios == ${GOT} generated Playwright tests"
fi

# ── 2) Playwright actually COLLECTS the generated tests ──────────────────────
echo
echo "-- 2) Playwright collects the generated tests (binding is real, not just files on disk) --"
LISTLOG="${SCRATCH}/list.log"
( cd "${E2E}" && npx playwright test --list --project=bdd --reporter=line ) >"${LISTLOG}" 2>&1
LISTRC=$?
COLLECTED="$(grep -cE '\[bdd\]' "${LISTLOG}" 2>/dev/null || true)"
if [ "${LISTRC}" -ne 0 ]; then
  bad "playwright test --list --project=bdd failed (rc=${LISTRC}):"
  sed 's/^/         /' "${LISTLOG}" | tail -20
elif [ "${COLLECTED}" -lt "${GOT}" ]; then
  bad "Playwright collected ${COLLECTED} bdd test(s) but the generator wrote ${GOT}"
else
  ok "Playwright collected ${COLLECTED} test(s) in the bdd project"
fi

# ── 3) no generated artefact is git-tracked ──────────────────────────────────
echo
echo "-- 3) generated artefacts are NEVER committed --"
TRACKED="$( cd "${REPO}" && git ls-files -- 'tests/e2e/.features-gen' 'tests/e2e/**/*.feature.spec.js' 2>/dev/null )"
if [ -n "${TRACKED}" ]; then
  bad "generated artefact(s) are git-tracked — they go stale and then run the OLD scenario:"
  printf '         %s\n' ${TRACKED}
else
  ok "nothing under tests/e2e/.features-gen (and no *.feature.spec.js) is git-tracked"
fi
IGNORED="$( cd "${REPO}" && git check-ignore -q tests/e2e/.features-gen && echo yes || echo no )"
if [ "${IGNORED}" != yes ]; then
  bad "tests/e2e/.features-gen is NOT gitignored — the next 'git add' commits it"
else
  ok "tests/e2e/.features-gen is gitignored"
fi

# ── 4) no stray .feature outside the scanned dir ─────────────────────────────
#
# NON-EXECUTED GHERKIN, WITH A RECORDED COMPANION. Three .feature files predate
# this lane and are deliberately NOT compiled: they are the human-readable
# companion to a shell suite that DOES execute the same matrix. That is the one
# acceptable form of un-run Gherkin, and it is acceptable only while the
# companion exists — so each entry names its companion and the guard fails if
# that file disappears. Nothing may be added here because it is inconvenient to
# port; port it to tests/e2e/features/ instead.
#
#   <feature path>|<companion suite that actually executes it>
ALLOW_UNCOMPILED=(
  "tests/device-registry/registry-allow-deny.feature|tests/device-registry/test-registry-allow-deny.sh"
  "tests/device-registry/layer-a-headscale-ssh-acl.feature|tests/device-registry/test-layer-a-headscale-acl.sh"
  "tests/pentest/nuclei/template-fixtures.feature|tests/pentest/nuclei/test-templates.sh"
)

echo
echo "-- 4) no .feature hides outside tests/e2e/features --"
allow_reason() {   # allow_reason <path> -> companion, or empty
  local entry
  for entry in "${ALLOW_UNCOMPILED[@]}"; do
    case "${entry}" in
      "$1|"*) printf '%s' "${entry#*|}"; return 0 ;;
    esac
  done
  return 1
}

STRAY_ALL="$( cd "${REPO}" && find tests -name '*.feature' -type f 2>/dev/null \
          | grep -v '^tests/e2e/features/' || true )"
UNLISTED=""
for f in ${STRAY_ALL}; do
  allow_reason "${f}" >/dev/null || UNLISTED="${UNLISTED} ${f}"
done
if [ -n "${UNLISTED// /}" ]; then
  bad ".feature file(s) outside the generator's scan path and off the allowlist —"
  bad "  invisible to bddgen, so they read as coverage and never run:"
  printf '         %s\n' ${UNLISTED}
  echo "         (move them under tests/e2e/features/, or add an ALLOW_UNCOMPILED entry"
  echo "          naming the shell suite that executes the same matrix)"
else
  ok "every un-allowlisted .feature under tests/ lives in tests/e2e/features/"
fi

# The allowlist itself must not rot: a named feature or its companion vanishing
# turns the entry into blanket amnesty.
ROT=""
for entry in "${ALLOW_UNCOMPILED[@]}"; do
  feat="${entry%%|*}"; comp="${entry#*|}"
  [ -f "${REPO}/${feat}" ] || ROT="${ROT} missing-feature:${feat}"
  [ -f "${REPO}/${comp}" ] || ROT="${ROT} missing-companion:${comp}(for ${feat})"
done
if [ -n "${ROT// /}" ]; then
  bad "ALLOW_UNCOMPILED has rotted:"
  printf '         %s\n' ${ROT}
else
  ok "all ${#ALLOW_UNCOMPILED[@]} allowlisted un-compiled .feature files still have an executing companion suite"
fi

# ── negative controls ────────────────────────────────────────────────────────
# Synthesise a copy of tests/e2e carrying each defect and re-run the SAME logic
# over it. A control that does not go red means the check above is asleep.
echo
echo "-- 5) negative controls: each check is proven able to FAIL --"

make_copy() {   # make_copy <dest>
  local dest
  dest="$1"
  mkdir -p "${dest}"
  ( cd "${E2E}" && tar -cf - \
      --exclude=node_modules --exclude=.features-gen --exclude=test-results \
      --exclude=screenshots . ) | ( cd "${dest}" && tar -xf - )
  ln -s "${E2E}/node_modules" "${dest}/node_modules"
}

# control A — a .feature using a step nobody defined must FAIL generation.
CA="${SCRATCH}/ctrl-undefined-step"
make_copy "${CA}"
cat > "${CA}/features/onboarding/zz-control-undefined.feature" <<'CTRL'
Feature: negative control
  Scenario: a step nobody ever defined
    When I perform an action that has no step definition whatsoever
CTRL
( cd "${CA}" && npx bddgen ) >"${SCRATCH}/ctrlA.log" 2>&1
if [ $? -eq 0 ]; then
  bad "CONTROL A: bddgen SUCCEEDED on a feature with an undefined step — missingSteps is not 'fail-on-gen', so undefined steps are being SKIPPED"
else
  if grep -F 'I perform an action that has no step definition whatsoever' "${SCRATCH}/ctrlA.log" >/dev/null 2>&1; then
    ok "CONTROL A: an undefined step fails generation, naming the step"
  else
    ok "CONTROL A: an undefined step fails generation"
  fi
fi

# control B — a .feature outside the scanned dir must be REPORTED by check 4.
CB="${SCRATCH}/ctrl-stray"
mkdir -p "${CB}/tests/e2e/features" "${CB}/tests/somewhere-else"
: > "${CB}/tests/e2e/features/real.feature"
: > "${CB}/tests/somewhere-else/orphan.feature"
CB_STRAY="$( cd "${CB}" && find tests -name '*.feature' -type f | grep -v '^tests/e2e/features/' || true )"
if [ -z "${CB_STRAY}" ]; then
  bad "CONTROL B: a .feature outside tests/e2e/features was NOT reported — check 4 is asleep"
else
  ok "CONTROL B: a stray .feature outside the scan path is reported (${CB_STRAY})"
fi

# control C — a GENERATED file that IS git-tracked must be reported by check 3.
# Uses a throwaway git repo so the real index is never touched.
CC="${SCRATCH}/ctrl-tracked"
mkdir -p "${CC}/tests/e2e/.features-gen/features"
( cd "${CC}" && git init -q . \
  && git -c user.email=guard@local -c user.name=guard commit -q --allow-empty -m init ) >/dev/null 2>&1
echo "// generated" > "${CC}/tests/e2e/.features-gen/features/x.feature.spec.js"
( cd "${CC}" && git add -f tests/e2e/.features-gen ) >/dev/null 2>&1
CC_TRACKED="$( cd "${CC}" && git ls-files -- 'tests/e2e/.features-gen' 'tests/e2e/**/*.feature.spec.js' 2>/dev/null )"
if [ -z "${CC_TRACKED}" ]; then
  bad "CONTROL C: a committed generated artefact was NOT reported — check 3 is asleep"
else
  ok "CONTROL C: a git-tracked generated artefact is reported (${CC_TRACKED})"
fi

# control D — a feature that generates FEWER tests than it declares scenarios
# must trip the count check. Built by deleting one Examples row from a copy's
# GENERATED output while leaving the .feature alone.
CD="${SCRATCH}/ctrl-count"
make_copy "${CD}"
( cd "${CD}" && npx bddgen ) >/dev/null 2>&1
CD_EXP="$(expected_scenarios "${CD}/features")"
CD_GOT_BEFORE="$(generated_tests "${CD}/.features-gen")"
CD_VICTIM="$(find "${CD}/.features-gen" -name '*.feature.spec.js' -type f | head -1)"
if [ -z "${CD_VICTIM}" ] || [ "${CD_EXP}" != "${CD_GOT_BEFORE}" ]; then
  bad "CONTROL D: could not build the baseline (exp=${CD_EXP} got=${CD_GOT_BEFORE}) — control is inconclusive"
else
  rm -f "${CD_VICTIM}"
  CD_GOT_AFTER="$(generated_tests "${CD}/.features-gen")"
  if [ "${CD_GOT_AFTER}" = "${CD_EXP}" ]; then
    bad "CONTROL D: deleting a whole generated spec did NOT change the count — the count check is asleep"
  else
    ok "CONTROL D: a feature that stops generating changes the count (${CD_EXP} declared vs ${CD_GOT_AFTER} generated)"
  fi
fi

echo
echo "== e2e Gherkin harness: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
