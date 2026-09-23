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
#   5. Every `@issue:` tag is well-formed (features/README.md §8):
#      ^@issue:[a-z0-9][a-z0-9.-]*-[0-9]+$ — a typo'd issue tag is unsearchable,
#      so the scenario reads as untracked. A @fixme scenario carrying no @issue:
#      is REPORTED with a count, never failed: @fixme predates the convention.
#
# NEGATIVE CONTROLS. Checks 1-5 are re-run against synthesised copies of the tree
# carrying each defect ON PURPOSE, so a green run cannot be vacuous. The copies
# live under a scratch dir and share the real node_modules by symlink; the real
# tests/e2e tree is never written to.
#
# MUTATION BATTERY (2026-09-23, each run sha256-verified to have changed this file
# and restored it byte-identical): regex `-[0-9]+` -> `-[0-9]*` (E: `@issue:generator-`);
# `_` admitted to the repo class (E: `gen_erator-549`); `^[a-z0-9]` widened to a
# leading dash (E: `-generator-549`); verdict `bad` -> `echo` (I); `.lower()`
# dropped from judge (E: `@Issue:`); title tokens not judged (E: title-embedded);
# docstring toggle removed (G); Examples-block tags not scoped (H); fixme scan
# neutered (F) — nine of nine killed by the named control. The tenth, deleting
# the REAL tree's `issue_tag_verdict "${FEATURES}"` call, SURVIVED every control
# (18 passed, 0 failed): controls prove a check CAN fail, not that it RAN. Hence
# EXPECTED_VERDICTS below — the one thing that moved under that mutation.
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
# Every ok/bad call site prints exactly one verdict, so P+F is invariant at this
# number whichever way each check goes (measured 19 on ten battery runs, red and
# green). A deleted check — `issue_tag_verdict "${FEATURES}"` commented out, say —
# is invisible to the negative controls and shows up ONLY here. Adding a check or
# a control moves it: change the number in the same commit, and say so.
EXPECTED_VERDICTS=19
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
# ONE readiness opinion, not a second one: tests/e2e/check-toolchain.sh verifies
# node_modules against the COMMITTED lock (this guard launches no browser, so it
# runs the probe with the ambient browsers path). `[ -d node_modules/playwright-bdd ]`
# used to stand here and accepted any stale install.
if ! bash "${E2E}/check-toolchain.sh"; then
  echo "SKIPPED-LOUDLY: the e2e toolchain is not ready (above). This guard checked NOTHING. Exiting 2 rather than 0." >&2
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
# INT TERM HUP as well as EXIT, because this guard MUTATES production files and
# restores them in the trap. Bash runs no EXIT trap for an untrapped SIGTERM, so
# a `timeout`, a Ctrl-C or a killed CI job could leave the tree MUTATED.
#
# THIS WIDENING IS NOT A COMPLETE FIX AND MUST NOT BE READ AS ONE. It fires on a
# bare `kill -TERM` (verified in isolation), but a `timeout` arriving while the
# script is blocked in a command substitution around `npx playwright test` was
# measured TWICE to leave tests/e2e/steps/coverage-catalogue.ts still carrying
# the M4 always-admit stub after the process was gone. The real protection is
# the preflight below, which makes the NEXT run refuse instead of silently
# trusting a poisoned oracle. Worktrees are shared here; that is the hazard.
trap cleanup EXIT INT TERM HUP

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

# ── 5) @issue: tag hygiene ────────────────────────────────────────────────────
#
# WHAT THIS ASSERTS. A scenario written for an issue carries
# `@issue:<repo-without-hugmesh->-<number>` (features/README.md §8). It is
# deliberately NOT a dimension axis — parseDimensionText in steps/dimensions.ts
# iterates only the six axes it knows by name, so an unknown `@x:` prefix like
# `@issue:` (or the pre-existing `@function:`) is inert to the Before hook and
# needs no change there (measured 2026-09-23: a throwaway @issue: scenario
# generated, listed AND ran — 1 passed, its @fixme twin 1 skipped). What DOES
# need a guard is the tag's own SPELLING (a typo'd issue tag is unsearchable —
# `grep -rn "@issue:generator-549"` finds nothing and the scenario reads as
# untracked) and whether a `@fixme` scenario names the issue it is fenced
# against at all.
#
#   FAIL  — any `@issue:` token ON A TAG LINE OR IN A KEYWORD TITLE that does not
#           match ^@issue:[a-z0-9][a-z0-9.-]*-[0-9]+$ (a capitalised `@Issue:`
#           prefix counts as malformed too — the grep above would miss it).
#           A step's quoted argument, a table cell, a docstring and a comment
#           are TEXT, not tags, and are never judged: cli/mesh-cli-surfaces.feature
#           already quotes "@interface:cli" inside a step string, and failing
#           the build on that shape would block unrelated work.
#   REPORT (not FAIL) — a `@fixme` scenario with no `@issue:` tag in its
#           effective tag set: the Feature line, an enclosing Rule: line, the
#           tag block above the Scenario/Outline, the tag block above its OWN
#           Examples: block, and any tag spelled into its title (§2b). Reported
#           because @fixme predates this convention and plenty of it is not
#           issue-shaped; a hard fail here would block unrelated work over a
#           pre-existing tag. The count is printed so growth is visible.
echo
echo "-- 5) @issue: tag hygiene (malformed tags FAIL, untraceable @fixme is REPORTED) --"

# issue_tag_report <features-dir> — one line per finding, prefixed MALFORMED
# (-> FAIL) or FIXME-NO-ISSUE (-> REPORT), tab-separated, so the caller splits
# them with grep and never needs a second process. Deliberately dumb and
# deliberately in python, same reason expected_scenarios() above is: getting
# tag SCOPING right in shell is where an off-by-one hides.
#
# TWO PASSES IN ONE WALK. Tags are collected into `pending` until the next
# keyword line consumes them: Feature: -> feature_tags, Rule: -> rule_tags
# (reset per Rule), Scenario/Outline -> that scenario, Examples: -> the OUTLINE
# ABOVE IT (never the scenario after it — the salvaged first draft got that
# wrong). Verdicts are computed after the walk, so an Examples-block tag still
# lands on the right scenario. Docstrings (""" or ```) are skipped wholesale.
issue_tag_report() {
  FEAT_DIR="$1" python3 - <<'PY'
import os, re
root = os.environ["FEAT_DIR"]

VALID_ISSUE = re.compile(r'^[a-z0-9][a-z0-9.-]*-[0-9]+$')
TAG_TOKEN = re.compile(r'@\S+')
# Every keyword line that carries a title (and so, by §2b, may carry tags spelled
# into it). The trailing `\s*:` disambiguates Example/Examples and Scenario/
# Scenario Outline whatever the alternation order.
KEYWORD = re.compile(
    r'^(Scenario Outline|Scenario Template|Scenarios|Scenario|Examples|Example'
    r'|Feature|Rule|Background)\s*:\s*(.*)$', re.I)
SCENARIO_KW = {'scenario', 'scenario outline', 'scenario template', 'example'}
EXAMPLES_KW = {'examples', 'scenarios'}

malformed = []
fixme_no_issue = []

def judge(toks, rel, lineno):
    for t in toks:
        if not t.lower().startswith('@issue:'):
            continue
        if not t.startswith('@issue:') or not VALID_ISSUE.match(t[len('@issue:'):]):
            malformed.append(f"{rel}:{lineno}: {t}")

for dirpath, _dirs, files in os.walk(root):
    for fn in sorted(files):
        if not fn.endswith(".feature"):
            continue
        path = os.path.join(dirpath, fn)
        rel = os.path.relpath(path, root)
        lines = open(path, encoding="utf-8").read().split("\n")

        feature_tags, rule_tags, pending = set(), set(), set()
        scenarios = []       # [{'head': 'Scenario: ...', 'tags': set()}]
        current = None       # the scenario an Examples: block belongs to
        in_docstring = False
        for lineno, raw in enumerate(lines, 1):
            s = raw.strip()
            if s.startswith('"""') or s.startswith('```'):
                in_docstring = not in_docstring
                continue
            if in_docstring or not s or s.startswith('#'):
                continue
            if s.startswith('@'):
                # a tag line. Gherkin permits a trailing `# comment`; strip it.
                toks = set(TAG_TOKEN.findall(re.split(r'\s#', s, maxsplit=1)[0]))
                judge(toks, rel, lineno)
                pending |= toks
                continue
            m = KEYWORD.match(s)
            if not m:
                continue     # a step or a table row: tags do not live here
            kw = m.group(1).lower()
            title_toks = set(TAG_TOKEN.findall(m.group(2)))
            judge(title_toks, rel, lineno)
            if kw == 'feature':
                feature_tags = pending | title_toks
                rule_tags, pending, current = set(), set(), None
            elif kw == 'rule':
                rule_tags = pending | title_toks
                pending, current = set(), None
            elif kw in SCENARIO_KW:
                current = {'head': m.group(0).strip(),
                           'tags': feature_tags | rule_tags | pending | title_toks}
                scenarios.append(current)
                pending = set()
            elif kw in EXAMPLES_KW:
                if current is not None:
                    current['tags'] |= pending | title_toks
                pending = set()
            else:                # Background: carries no tags
                pending = set()

        for sc in scenarios:
            if '@fixme' in sc['tags'] and not any(t.startswith('@issue:') for t in sc['tags']):
                fixme_no_issue.append(f"{rel}: {sc['head']}")

for row in malformed:
    print(f"MALFORMED\t{row}")
for row in fixme_no_issue:
    print(f"FIXME-NO-ISSUE\t{row}")
PY
}

# split_report <prefix> <report> — the rows of one kind, or empty. grep's rc=1
# on no match is the empty case, not an error.
split_report() { printf '%s\n' "$2" | grep "^$1"$'\t' | cut -f2- || true; }

# issue_tag_verdict <features-dir> — the VERDICT: scanner rows -> ok/bad/REPORT.
# A function rather than inline so control I below can prove the wiring: the
# controls E-H read issue_tag_report's rows directly and would stay green if
# this block were edited to `echo` instead of `bad` — which is precisely the
# edit someone makes when a malformed tag blocks their PR.
issue_tag_verdict() {
  local report malformed_rows fixme_rows fixme_n
  report="$(issue_tag_report "$1")"
  malformed_rows="$(split_report MALFORMED "${report}")"
  fixme_rows="$(split_report FIXME-NO-ISSUE "${report}")"

  if [ -n "${malformed_rows}" ]; then
    bad "malformed @issue: tag(s) — must match ^@issue:[a-z0-9][a-z0-9.-]*-[0-9]+$ (features/README.md §8):"
    printf '%s\n' "${malformed_rows}" | sed 's/^/         /'
  else
    ok "every @issue: tag under tests/e2e/features matches ^@issue:[a-z0-9][a-z0-9.-]*-[0-9]+\$"
  fi

  if [ -n "${fixme_rows}" ]; then
    fixme_n="$(printf '%s\n' "${fixme_rows}" | grep -c . || true)"
    echo "  REPORT ${fixme_n} @fixme scenario(s) with no @issue: tag (not a failure; see features/README.md §8):"
    printf '%s\n' "${fixme_rows}" | sed 's/^/         /'
  else
    echo "  REPORT every @fixme scenario under tests/e2e/features carries an @issue: tag"
  fi
}

issue_tag_verdict "${FEATURES}"

# ── negative controls ────────────────────────────────────────────────────────
# Synthesise a copy of tests/e2e carrying each defect and re-run the SAME logic
# over it. A control that does not go red means the check above is asleep.
echo
echo "-- 6) negative controls: each check is proven able to FAIL --"

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

# controls E-H exercise check 5's scanner. Pure python logic, no bddgen needed,
# so each runs against a throwaway features dir rather than a full make_copy.

# control E — EVERY malformed shape must be flagged, and nothing else. Eleven
# shapes, eleven rows: an uppercase repo, a missing number, a bare prefix, a
# leading dash, trailing garbage, an underscore, a capitalised `@Issue:` prefix,
# one spelled into a Scenario title, and three added 2026-09-23 after a
# mutation battery loosened the regex three ways and the first eight shapes
# caught NONE of them: a dash with no digits after it (`-[0-9]+` -> `-[0-9]*`),
# an underscore INSIDE the repo segment followed by a valid `-<n>` (`_` admitted
# to the class), and a repo segment that starts with a dash (`^[a-z0-9]` widened).
# Each shape exists to kill exactly one of those three. A well-formed tag in the
# same file proves the regex is not simply rejecting everything.
CE="${SCRATCH}/ctrl-issue-malformed/features"
mkdir -p "${CE}/onboarding"
cat > "${CE}/onboarding/zz-control-issue.feature" <<'CTRL'
@issue:Generator-549
Feature: negative control E
  @issue:generator
  Scenario: missing number
    Given nothing
  @issue:
  Scenario: bare prefix
    Given nothing
  @issue:-549
  Scenario: leading dash
    Given nothing
  @issue:generator-549x
  Scenario: trailing garbage
    Given nothing
  @issue:generator_549
  Scenario: underscore
    Given nothing
  @Issue:generator-549
  Scenario: capitalised prefix
    Given nothing
  Scenario: title-embedded @issue:GENERATOR-549
    Given nothing
  @issue:generator-
  Scenario: dash but no number
    Given nothing
  @issue:gen_erator-549
  Scenario: underscore inside the repo segment, valid number
    Given nothing
  @issue:-generator-549
  Scenario: repo segment starting with a dash
    Given nothing
  @issue:github.io-15 @issue:user-bff-api-19
  Scenario: two well-formed tags, dots and dashes in the repo segment
    Given nothing
CTRL
CE_REPORT="$(issue_tag_report "${CE}")"
CE_MALFORMED="$(split_report MALFORMED "${CE_REPORT}")"
CE_N="$(printf '%s\n' "${CE_MALFORMED}" | grep -c . || true)"
CE_MISSING=""
# each row ends in ": <tag>", so match the tag anchored at end of line — a bare
# substring match would let `@issue:generator` be satisfied by `@issue:generator-549x`.
for shape in '@issue:Generator-549' '@issue:generator' '@issue:' '@issue:-549' \
             '@issue:generator-549x' '@issue:generator_549' '@Issue:generator-549' \
             '@issue:GENERATOR-549' '@issue:generator-' '@issue:gen_erator-549' \
             '@issue:-generator-549'; do
  esc="$(printf '%s' "${shape}" | sed 's/\./\\./g')"
  printf '%s\n' "${CE_MALFORMED}" | grep -E -- ": ${esc}\$" >/dev/null 2>&1 \
    || CE_MISSING="${CE_MISSING} ${shape}"
done
if [ -n "${CE_MISSING// /}" ]; then
  bad "CONTROL E: malformed @issue: shape(s) NOT flagged — check 5's regex is asleep for:${CE_MISSING}"
elif printf '%s\n' "${CE_MALFORMED}" | grep -F -e 'github.io-15' -e 'user-bff-api-19' >/dev/null 2>&1; then
  bad "CONTROL E: a WELL-FORMED @issue: tag was flagged as malformed — the regex rejects everything"
elif [ "${CE_N}" -ne 11 ]; then
  bad "CONTROL E: expected exactly 11 malformed rows, got ${CE_N}:"
  printf '%s\n' "${CE_MALFORMED}" | sed 's/^/         /'
else
  ok "CONTROL E: all 11 malformed @issue: shapes are flagged, the 2 well-formed ones are not"
fi

# control F — a @fixme scenario with no @issue: tag must be REPORTED (not
# failed) by check 5. A well-formed sibling with a matching @issue: proves the
# scoping does not over-report every @fixme in the file, and a plain sibling
# proves a scenario with no @fixme is never reported.
CF="${SCRATCH}/ctrl-issue-fixme/features"
mkdir -p "${CF}/onboarding"
cat > "${CF}/onboarding/zz-control-fixme.feature" <<'CTRL'
Feature: negative control F

  @fixme
  Scenario: a fixme scenario naming no issue at all
    Given nothing

  @fixme @issue:generator-1
  Scenario: a fixme scenario that DOES name its issue
    Given nothing

  Scenario: a plain scenario with no fixme
    Given nothing
CTRL
CF_REPORT="$(issue_tag_report "${CF}")"
CF_FIXME="$(split_report FIXME-NO-ISSUE "${CF_REPORT}")"
CF_MALFORMED="$(split_report MALFORMED "${CF_REPORT}")"
if [ -n "${CF_MALFORMED}" ]; then
  bad "CONTROL F: a well-formed @issue:generator-1 was flagged as malformed — control is inconclusive (${CF_MALFORMED})"
elif ! printf '%s\n' "${CF_FIXME}" | grep -F 'naming no issue at all' >/dev/null 2>&1; then
  bad "CONTROL F: a @fixme scenario with no @issue: tag was NOT reported — check 5's fixme scan is asleep"
elif printf '%s\n' "${CF_FIXME}" | grep -F 'DOES name its issue' >/dev/null 2>&1; then
  bad "CONTROL F: the @fixme scenario that DOES carry @issue:generator-1 was reported anyway — tag scoping bleeds across scenarios"
elif printf '%s\n' "${CF_FIXME}" | grep -F 'plain scenario' >/dev/null 2>&1; then
  bad "CONTROL F: a scenario with NO @fixme was reported — the fixme test is not reading the tag"
else
  ok "CONTROL F: an untraceable @fixme is reported, its @issue-carrying sibling and its plain sibling are not"
fi

# control G — PRECISION. Text that is not a tag must never be judged: a quoted
# step argument, a table cell, a docstring and a comment all carry a malformed
# `@issue:` here, and the docstring also carries a fake `@fixme` + `Scenario:`
# pair that a scanner ignoring docstrings would report as a scenario.
CG="${SCRATCH}/ctrl-issue-precision/features"
mkdir -p "${CG}/onboarding"
cat > "${CG}/onboarding/zz-control-precision.feature" <<'CTRL'
Feature: negative control G
  # @issue:Foo @fixme  (a comment is not a tag)
  Scenario: a step string, a table cell and a docstring mention a malformed tag
    Given the output contains "@issue:Foo"
    And the table holds:
      | @issue:Bar | @fixme |
    And the docstring holds:
      """
      @issue:Baz
      @fixme
      Scenario: not a scenario @issue:Qux
      """
    Then nothing
CTRL
CG_REPORT="$(issue_tag_report "${CG}")"
CG_MALFORMED="$(split_report MALFORMED "${CG_REPORT}")"
CG_FIXME="$(split_report FIXME-NO-ISSUE "${CG_REPORT}")"
if [ -n "${CG_MALFORMED}" ]; then
  bad "CONTROL G: a malformed @issue: inside step text / a table / a docstring / a comment was flagged — check 5 judges TEXT, and would fail the build on cli/mesh-cli-surfaces.feature's quoted \"@interface:cli\":"
  printf '%s\n' "${CG_MALFORMED}" | sed 's/^/         /'
elif [ -n "${CG_FIXME}" ]; then
  bad "CONTROL G: a @fixme/Scenario: pair INSIDE A DOCSTRING was reported as a scenario — docstrings are not being skipped (${CG_FIXME})"
else
  ok "CONTROL G: @issue:/@fixme text in a step string, a table cell, a docstring and a comment is never judged"
fi

# control H — SCOPING. A tag block above an Examples: block belongs to the
# OUTLINE above it, not to the scenario after it; a tag on a Rule: line reaches
# every scenario under that rule; a tag on the Feature line reaches all of them.
CH="${SCRATCH}/ctrl-issue-scoping/features"
mkdir -p "${CH}/onboarding"
cat > "${CH}/onboarding/zz-control-scoping.feature" <<'CTRL'
Feature: negative control H

  Scenario Outline: an outline whose Examples block carries the fixme <x>
    Given nothing
    @fixme
    Examples:
      | x |
      | 1 |

  Scenario: the scenario AFTER a tagged Examples block must not inherit it
    Given nothing

  @fixme
  Rule: every scenario under a fixme rule is pending
    @issue:generator-2
    Scenario: under the rule, but traceable
      Given nothing
    Scenario: under the rule, untraceable
      Given nothing
CTRL
CH_REPORT="$(issue_tag_report "${CH}")"
CH_FIXME="$(split_report FIXME-NO-ISSUE "${CH_REPORT}")"
CH_BAD=""
printf '%s\n' "${CH_FIXME}" | grep -F 'an outline whose Examples block' >/dev/null 2>&1 || CH_BAD="${CH_BAD} examples-tag-not-on-outline"
printf '%s\n' "${CH_FIXME}" | grep -F 'AFTER a tagged Examples block' >/dev/null 2>&1 && CH_BAD="${CH_BAD} examples-tag-bled-to-next-scenario"
printf '%s\n' "${CH_FIXME}" | grep -F 'under the rule, untraceable' >/dev/null 2>&1 || CH_BAD="${CH_BAD} rule-tag-not-inherited"
printf '%s\n' "${CH_FIXME}" | grep -F 'under the rule, but traceable' >/dev/null 2>&1 && CH_BAD="${CH_BAD} rule-scenario-with-issue-reported"
if [ -n "${CH_BAD// /}" ]; then
  bad "CONTROL H: tag scoping is wrong —${CH_BAD}:"
  printf '%s\n' "${CH_FIXME}" | sed 's/^/         /'
else
  ok "CONTROL H: Examples-block tags scope to their outline, Rule tags inherit, neither bleeds"
fi

# control I — VERDICT WIRING. Controls E-H prove the SCANNER can see a defect;
# none of them proves the defect reaches `bad`. Run the real verdict over the
# control-E tree (11 malformed rows) and require F to move by exactly one —
# then put F back, because this is a control, not a finding. A verdict edited
# to `echo`/`ok` (turning FAIL into REPORT) stays green under E-H and goes red
# here. Output is swallowed: the eleven rows already printed under control E.
F_BEFORE="${F}"; P_BEFORE="${P}"
issue_tag_verdict "${CE}" >/dev/null
CI_DELTA=$((F - F_BEFORE))
F="${F_BEFORE}"; P="${P_BEFORE}"
if [ "${CI_DELTA}" -eq 1 ]; then
  ok "CONTROL I: a malformed @issue: tag reaches the verdict as a FAIL (F moved by exactly 1)"
else
  bad "CONTROL I: the verdict did NOT fail on 11 malformed @issue: tags (F moved by ${CI_DELTA}, expected 1) — check 5 has become a report"
fi

# ── verdict census: a check that was DELETED never fails ─────────────────────
echo
echo "-- 7) verdict census: every check above actually ran --"
if [ "$((P + F))" -eq "${EXPECTED_VERDICTS}" ]; then
  ok "all ${EXPECTED_VERDICTS} verdicts were reached (a deleted check would drop this count)"
else
  bad "expected ${EXPECTED_VERDICTS} verdicts, counted $((P + F)) — a check was deleted or added; if added, bump EXPECTED_VERDICTS in the same commit"
fi

echo
echo "== e2e Gherkin harness: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
