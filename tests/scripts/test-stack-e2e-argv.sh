#!/usr/bin/env bash
# test-stack-e2e-argv.sh — `make stack-e2e` must forward E2E_ARGS to Playwright,
# and must NOT narrow the suite when E2E_ARGS is unset.
#
# WHY THIS FILE EXISTS. Until 2026-08-26 the stack-e2e target hardcoded
#
#     cd tests/e2e && SNAP_BASE_URL=... npx playwright test -c playwright.config.ts
#
# with no way to name a spec, a --grep or a --repeat-each. Iterating on ONE failing
# spec against the compose stack therefore cost the whole suite — 33 spec files /
# 221 tests — every time. kind-e2e and kind-e2e-mfa had always named their single
# spec inline (specs/27-native-login, specs/29-mfa-privileged-floor), so the
# capability existed in the kind lane and nowhere else, and tests/e2e/run.sh already
# forwarded "$@" correctly to a suite that stack-e2e reached by a different path.
#
# WHY IT IS NOT A `grep E2E_ARGS Makefile` CHECK. Asserting that the Makefile
# CONTAINS the token proves nothing, and in this repo it is actively misleading:
# prose naming a token has inverted exactly this kind of check four times (see the
# comment-stripping note in tests/scripts/test-guard-integrity.sh). The Makefile
# hunk added here is ~45 lines of comment that say "E2E_ARGS" repeatedly, so a
# contains-check stays green even if the recipe itself is reverted, and stays green
# under the nastiest mutation of the three below: mis-spelling the reference in the
# recipe (`$(E2E_ARG)`), which make expands to the EMPTY STRING with no warning and
# no non-zero status. Every assertion here is therefore made against the RENDERED
# RECIPE (`make -n`) or against the ARGV a stub `npx` actually received.
#
# HERMETIC. Nothing here runs Playwright for real (except the last, optional leg),
# starts the stack, or touches the repo working tree: each execution case copies the
# repo Makefile into a fresh mktemp dir, plants a STUB tests/e2e/check-toolchain.sh
# (the readiness probe every e2e recipe runs first — see E2E_READY in the Makefile)
# that exits 0, and puts a stub `npx` on PATH that writes its argv, one argument per
# line, and exits 0. The probe's own behaviour, and the fact that a FAILING probe
# stops each recipe before npx, are tests/scripts/test-e2e-toolchain-readiness.sh's
# business; this file only needs the recipe to get past it.
#
#   bash tests/scripts/test-stack-e2e-argv.sh
#
# Optional leg: E2E_NODE_MODULES=/path/to/tests/e2e/node_modules runs the REAL
# `playwright test --list` enumeration. Without it that leg SKIPS LOUDLY and is
# counted as a skip, never as a pass. Section 5 always runs: it checks statically
# that the scratch copy the leg lists from has every file the specs import.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
MAKEFILE="${REPO}/Makefile"
E2E_RUN_SH="${REPO}/tests/e2e/run.sh"
[ -f "${MAKEFILE}" ] || { echo "cannot find ${MAKEFILE}" >&2; exit 2; }
command -v make >/dev/null 2>&1 || { echo "make is not installed — this suite asserts nothing without it" >&2; exit 2; }

PASS=0; FAIL=0; SKIP=0
_ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
_skip() { SKIP=$((SKIP+1)); printf '  SKIP %s\n' "$1"; }
eq() { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3"$'\n'"         got:  $1"$'\n'"         want: $2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# ── the sandbox ──────────────────────────────────────────────────────────────
# A COPY of the real Makefile, not the real tree. The recipe's own precondition
# (`bash tests/e2e/check-toolchain.sh || exit 2`) means an execution test has to
# run somewhere that script exists and passes; the REAL probe would (rightly)
# refuse a sandbox with no node_modules, so a stub that exits 0 stands in for it.
# The Makefile has no `include` lines and its eight top-level $(shell …) calls are
# read-only, so it parses standalone.
# NOTE: mktemp, not a counter. mk_sandbox is called from inside $( ), so a
# `SBOX_N=$((SBOX_N+1))` global increments in a SUBSHELL and never propagates —
# every caller then got the same directory. That was invisible while the npx stub
# truncated its argv file, and turned into cross-test argv accumulation the moment
# the stub started appending.
mk_sandbox() { # -> prints the sandbox dir
    local d
    d="$(mktemp -d "${TMP}/sbox.XXXXXX")"
    mkdir -p "${d}/tests/e2e" "${d}/bin"
    cp "${MAKEFILE}" "${d}/Makefile"
    printf '#!/bin/sh\nexit 0\n' > "${d}/tests/e2e/check-toolchain.sh"
    # Stub npx. One argument per line so a QUOTED $(E2E_ARGS) — which would arrive
    # as a single argv entry — is distinguishable from an unquoted one.
    cat > "${d}/bin/npx" <<'STUB'
#!/bin/sh
: "${ARGV_OUT:?ARGV_OUT unset — the stub would silently discard the argv}"
# APPEND, never truncate. Truncating here (`: > $ARGV_OUT`) made the execution
# legs blind to everything but the LAST npx of a recipe: a mutation that inserts
# an EARLIER `npx playwright test --grep @nothing` line — which would run the
# suite twice — recorded only the second argv and every assertion stayed green.
# The .calls counter makes "how many times was npx invoked" assertable.
_c=0
[ -f "${ARGV_OUT}.calls" ] && _c="$(cat "${ARGV_OUT}.calls")"
printf '%s\n' "$((_c+1))" > "${ARGV_OUT}.calls"
for a in "$@"; do printf '%s\n' "$a" >> "${ARGV_OUT}"; done
exit 0
STUB
    chmod +x "${d}/bin/npx"
    printf '%s\n' "${d}"
}

# run_target MODE TARGET [E2E_ARGS value] -> prints the captured argv file's contents
#   MODE=unset  E2E_ARGS is scrubbed from the environment entirely
#   MODE=var    passed as a make command-line variable   (make T E2E_ARGS=…)
#   MODE=env    passed as an environment variable        (E2E_ARGS=… make T)
# The env form is the one that matters for the Studio: LocalStackNode._make()
# takes extra_env= and cannot change the argv it builds. make imports the
# environment as make variables, so both forms must land identically.
# _sandbox_run MODE TARGET [value] -> runs the real recipe against the stub and
# prints the sandbox dir. Split out of run_target so a second accessor can read a
# DIFFERENT fact about the same run (the npx invocation count) — run_target is
# always called inside $( ), so it cannot hand anything back through a global.
_sandbox_run() {
    local mode="$1"
    local target="$2"
    local value="${3-}"
    local d out rc
    d="$(mk_sandbox)"
    out="${d}/argv.txt"
    case "${mode}" in
      unset) env -u E2E_ARGS PATH="${d}/bin:${PATH}" ARGV_OUT="${out}" make -s --no-print-directory -C "${d}" "${target}" >/dev/null 2>&1 ;;
      var)   env -u E2E_ARGS PATH="${d}/bin:${PATH}" ARGV_OUT="${out}" make -s --no-print-directory -C "${d}" "${target}" E2E_ARGS="${value}" >/dev/null 2>&1 ;;
      env)   env E2E_ARGS="${value}" PATH="${d}/bin:${PATH}" ARGV_OUT="${out}" make -s --no-print-directory -C "${d}" "${target}" >/dev/null 2>&1 ;;
      *)     echo "_sandbox_run: bad mode ${mode}" >&2; exit 2 ;;
    esac
    rc=$?
    printf '%s\n' "${rc}" > "${d}/rc.txt"
    printf '%s\n' "${d}"
}

run_target() {
    local d rc out
    d="$(_sandbox_run "$@")"
    rc="$(cat "${d}/rc.txt")"
    out="${d}/argv.txt"
    if [ "${rc}" -ne 0 ]; then printf 'MAKE-EXIT-%s\n' "${rc}"; return 0; fi
    if [ ! -f "${out}" ]; then printf 'NPX-NEVER-RAN\n'; return 0; fi
    cat "${out}"
}

# npx_calls MODE TARGET [value] -> how many times the recipe invoked npx.
# One is the only correct answer: a second invocation means the compose suite
# runs twice (minutes of wall clock) or that an unrelated playwright call was
# smuggled into the recipe ahead of the real one.
npx_calls() {
    local d rc
    d="$(_sandbox_run "$@")"
    rc="$(cat "${d}/rc.txt")"
    if [ "${rc}" -ne 0 ]; then printf 'MAKE-EXIT-%s\n' "${rc}"; return 0; fi
    if [ -f "${d}/argv.txt.calls" ]; then cat "${d}/argv.txt.calls"; else printf '0\n'; fi
}

# render MODE TARGET [value] -> the `npx playwright test …` line of `make -n`,
# whitespace-collapsed. `make -n` prints the recipe WITHOUT running it, which is
# how this repo asserts argv with no side effects.
render() {
    local mode="$1"
    local target="$2"
    local value="${3-}"
    local text
    text="$(_render_raw "${mode}" "${target}" "${value}")"
    # Join continuations, keep only the playwright invocation, squeeze whitespace.
    printf '%s\n' "${text}" | tr '\n' ' ' | sed -e 's/.*\(npx playwright test\)/\1/' -e 's/[[:space:]][[:space:]]*/ /g' -e 's/[[:space:]]*$//'
}

# _render_raw MODE TARGET VALUE -> the untouched `make -n` output.
#
# PUBLIC_HTTPS_PORT is scrubbed alongside E2E_ARGS so the rendered front-door port
# is the Makefile's DEFAULT (`?= 8488`) and not whatever the operator happens to
# export. Without that, the port assertion below would measure the environment.
_render_raw() {
    local mode="$1"
    local target="$2"
    local value="${3-}"
    case "${mode}" in
      unset) env -u E2E_ARGS -u PUBLIC_HTTPS_PORT make -n --no-print-directory -C "${REPO}" "${target}" 2>/dev/null ;;
      var)   env -u E2E_ARGS -u PUBLIC_HTTPS_PORT make -n --no-print-directory -C "${REPO}" "${target}" E2E_ARGS="${value}" 2>/dev/null ;;
      env)   env -u PUBLIC_HTTPS_PORT E2E_ARGS="${value}" make -n --no-print-directory -C "${REPO}" "${target}" 2>/dev/null ;;
    esac
}

# render_full MODE TARGET [value] -> the ENTIRE rendered recipe, one shell command
# per line, continuations joined and whitespace squeezed.
#
# WHY THIS EXISTS (added 2026-08-26 after review). render() above keeps only the
# `npx playwright test …` tail, because its greedy `s/.*\(npx playwright test\)/\1/`
# DISCARDS the whole recipe prefix. Everything before npx was therefore unguarded,
# and this suite is the only test standing over that recipe. Six mutations survived
# a fully green run, three of them real regressions:
#   * deleting SNAP_BASE_URL='https://localhost:$(PUBLIC_HTTPS_PORT)' — the compose
#     run would fall through to playwright.config.ts's own default of
#     https://localhost:8443 while the stack's front door is 8488, so every spec
#     would fail to connect;
#   * hardcoding that URL to the stale 8443, same effect;
#   * changing PUBLIC_HTTPS_PORT's default out from under it;
#   * deleting the readiness-probe precondition (`bash tests/e2e/check-toolchain.sh
#     || exit 2`, formerly `[ -d tests/e2e/node_modules ]`) from either target;
#   * inserting a SECOND, earlier `npx playwright test` line (the suite runs twice).
# Trailing text was always caught — only the prefix was blind.
render_full() {
    local mode="$1"
    local target="$2"
    local value="${3-}"
    _render_raw "${mode}" "${target}" "${value}" | awk '
        { line = $0
          while (line ~ /\\$/) {
              sub(/\\$/, "", line)
              if ((getline nxt) <= 0) break
              sub(/^[[:space:]]+/, "", nxt)
              line = line nxt
          }
          gsub(/[[:space:]]+/, " ", line)
          sub(/[[:space:]]+$/, "", line)
          print line }'
}

echo "== stack-e2e argv passthrough =="
echo
echo "-- 1) the RENDERED recipe (make -n), not the Makefile's text --"

eq "$(render unset stack-e2e)" \
   "npx playwright test -c playwright.config.ts" \
   "E2E_ARGS unset renders the FULL suite — no spec, no --grep, nothing narrowing"

eq "$(render var stack-e2e specs/01-frontpage.spec.ts)" \
   "npx playwright test -c playwright.config.ts specs/01-frontpage.spec.ts" \
   "make stack-e2e E2E_ARGS=specs/01-frontpage.spec.ts renders the spec path"

eq "$(render env stack-e2e specs/01-frontpage.spec.ts)" \
   "npx playwright test -c playwright.config.ts specs/01-frontpage.spec.ts" \
   "E2E_ARGS=… in the ENVIRONMENT renders identically (the Studio's extra_env= path)"

eq "$(render var stack-e2e '--grep @smoke --repeat-each 2')" \
   "npx playwright test -c playwright.config.ts --grep @smoke --repeat-each 2" \
   "a multi-argument E2E_ARGS renders all four words"

echo
echo "-- 1b) the WHOLE recipe, PREFIX INCLUDED (render() above sees only the npx tail) --"
# render() keeps only `npx playwright test …` onward. These legs pin what comes
# BEFORE it, which is where the front-door URL and the node_modules precondition
# live. See the render_full() header for the six mutations that used to survive.
#
# The precondition is the readiness PROBE (tests/e2e/check-toolchain.sh) since
# 2026-08-27: `[ -d tests/e2e/node_modules ]` passed on any stale install and the
# targets then died on "Cannot find module 'playwright-bdd'". This asserts the
# precondition's STRUCTURE (which script, and that a failure stops the recipe with
# a non-zero status) rather than any wording; what the probe itself checks, and
# that a failing probe really stops the recipe before npx, is
# tests/scripts/test-e2e-toolchain-readiness.sh's business.

cmd_line()     { render_full "$@" | sed -n '2p'; }
pre_line()     { render_full "$@" | sed -n '1p'; }
recipe_lines() { render_full "$@" | grep -c . ; }

eq "$(cmd_line unset stack-e2e)" \
   "cd tests/e2e && SNAP_BASE_URL='https://localhost:8488' npx playwright test -c playwright.config.ts" \
   "the FULL stack-e2e command line, incl. SNAP_BASE_URL on PUBLIC_HTTPS_PORT's default 8488"

eq "$(cmd_line var stack-e2e specs/01-frontpage.spec.ts)" \
   "cd tests/e2e && SNAP_BASE_URL='https://localhost:8488' npx playwright test -c playwright.config.ts specs/01-frontpage.spec.ts" \
   "narrowing with E2E_ARGS does not disturb the cd or the SNAP_BASE_URL prefix"

eq "$(cmd_line unset stack-e2e-list)" \
   "cd tests/e2e && npx playwright test -c playwright.config.ts --list --reporter=json" \
   "the FULL stack-e2e-list command line"

# WHY THE PORT IS PINNED AND NOT JUST 'SNAP_BASE_URL IS PRESENT'. Makefile
# PUBLIC_HTTPS_PORT ?= 8488, but tests/e2e/playwright.config.ts falls back to
# https://localhost:8443 when SNAP_BASE_URL is unset. The two disagree, so losing
# the assignment — or letting either number drift — silently points the compose run
# at a door nothing is listening on and every spec fails to connect. Asserting the
# divergence exists keeps the pin above honest about WHY it is load-bearing.
CFG="${REPO}/tests/e2e/playwright.config.ts"
if [ ! -f "${CFG}" ]; then
    _bad "tests/e2e/playwright.config.ts is missing — cannot check the SNAP_BASE_URL fallback"
else
    # Do NOT strip `//` comments here: the value being extracted is a URL and
    # `s://.*::` eats the `https://`. Comment lines are dropped by shape instead.
    # The fallback is `process.env.SNAP_BASE_URL || \`https://localhost:${...PUBLIC_HTTPS_PORT || '8488'}\``
    # since e91e6572 — a template literal on the CONTINUATION line — so read the
    # `baseURL:` line plus the lines up to the one carrying `||`, and take either a
    # literal `https://localhost:NNNN` or the port default inside the `${...}`.
    cfg_block="$(awk '/^[[:space:]]*\/\//{next} /baseURL:/{on=1} on{printf "%s ", $0; if ($0 ~ /\|\|/) exit}' "${CFG}")"
    cfg_default="$(printf '%s\n' "${cfg_block}" | sed -n -e "s/.*||[[:space:]]*'\(https:[^']*\)'.*/\1/p")"
    if [ -z "${cfg_default}" ]; then
        cfg_port="$(printf '%s\n' "${cfg_block}" | sed -n -e "s/.*https:\/\/localhost:\${[^}]*||[[:space:]]*'\([0-9][0-9]*\)'}.*/\1/p")"
        [ -n "${cfg_port}" ] && cfg_default="https://localhost:${cfg_port}"
    fi
    if [ "${cfg_default}" = "https://localhost:8488" ]; then
        _ok "playwright.config.ts's own fallback already matches 8488 (SNAP_BASE_URL is belt-and-braces here)"
    elif [ -n "${cfg_default}" ]; then
        _ok "playwright.config.ts falls back to ${cfg_default}, which is NOT the stack's 8488 — SNAP_BASE_URL is load-bearing, and the pin above guards it"
    else
        _bad "could not read playwright.config.ts's baseURL fallback — the SNAP_BASE_URL pin's rationale is unverified"
    fi
fi

for t in stack-e2e stack-e2e-list; do
    eq "$(recipe_lines unset "${t}")" "2" \
       "${t} renders exactly TWO commands — no extra playwright run smuggled in ahead of the real one"
    case "$(pre_line unset "${t}")" in
      *"bash tests/e2e/check-toolchain.sh"*"|| exit 2"*)
          _ok "${t} still runs the readiness probe first and stops on its failure" ;;
      *)  _bad "${t} lost its 'tests/e2e/check-toolchain.sh || exit 2' precondition: it will now run npx against a stale or uninstalled tree"$'\n'"         got:  $(pre_line unset "${t}")" ;;
    esac
done

echo
echo "-- 2) the argv a stub npx ACTUALLY received --"
# `make -n` renders the recipe make WOULD run; it does not prove the shell then
# splits it the way we think. These legs run the real recipe against a stub.

eq "$(run_target unset stack-e2e)" \
   "$(printf 'playwright\ntest\n-c\nplaywright.config.ts')" \
   "unset: npx is invoked with exactly 4 arguments — the suite is not narrowed"

eq "$(run_target var stack-e2e specs/01-frontpage.spec.ts)" \
   "$(printf 'playwright\ntest\n-c\nplaywright.config.ts\nspecs/01-frontpage.spec.ts')" \
   "make-variable form: the spec path arrives as its own 5th argument"

eq "$(run_target env stack-e2e specs/01-frontpage.spec.ts)" \
   "$(printf 'playwright\ntest\n-c\nplaywright.config.ts\nspecs/01-frontpage.spec.ts')" \
   "environment form: the spec path arrives identically"

# WORD SPLITTING IS LOAD-BEARING and is the reason $(E2E_ARGS) is unquoted in the
# recipe. If it were quoted, "--grep @smoke" would reach Playwright as ONE argv
# entry and Playwright would reject it — a failure mode `make -n` cannot show,
# because the rendered text looks identical either way.
eq "$(run_target var stack-e2e '--grep @smoke')" \
   "$(printf 'playwright\ntest\n-c\nplaywright.config.ts\n--grep\n@smoke')" \
   "'--grep @smoke' splits into TWO argv entries, not one quoted blob"

# HOW MANY TIMES npx RAN. The stub used to truncate its argv file on every call,
# so a recipe that invoked npx twice recorded only the LAST argv and all the
# assertions above stayed green — while `make stack-e2e` quietly ran the whole
# 221-test suite twice. The stub now appends and keeps a counter.
eq "$(npx_calls unset stack-e2e)"     "1" "stack-e2e invokes npx EXACTLY once"
eq "$(npx_calls var stack-e2e specs/01-frontpage.spec.ts)" "1" "…once when narrowed too"
eq "$(npx_calls unset stack-e2e-list)" "1" "stack-e2e-list invokes npx EXACTLY once"

echo
echo "-- 3) stack-e2e-list enumerates without running --"

eq "$(run_target unset stack-e2e-list)" \
   "$(printf 'playwright\ntest\n-c\nplaywright.config.ts\n--list\n--reporter=json')" \
   "stack-e2e-list passes --list and forces --reporter=json"

eq "$(run_target var stack-e2e-list specs/01-frontpage.spec.ts)" \
   "$(printf 'playwright\ntest\n-c\nplaywright.config.ts\n--list\n--reporter=json\nspecs/01-frontpage.spec.ts')" \
   "stack-e2e-list narrows on E2E_ARGS too"

# MEASURED 2026-08-26: `playwright test --list` under this config's own reporter
# array still fires every FILE writer — SNAP_REPORT_DIR/ came out holding
# junit.xml, report.json AND the hugmesh reporter's summary.json, each describing
# zero tests. A mere enumeration would therefore overwrite the durable artifacts of
# the last real run. A CLI --reporter replaces the whole array and the directory
# stays empty. So the override is not cosmetic and must not be "simplified" away.
case "$(run_target unset stack-e2e-list)" in
  *--reporter=*) _ok "the --reporter override is present — a bare --list would clobber junit/report/summary.json" ;;
  *)             _bad "stack-e2e-list runs --list with NO --reporter override: it will overwrite the last real run's junit.xml/report.json/summary.json with a zero-test listing" ;;
esac

# The mirror image: stack-e2e must NOT force a reporter, or it silently drops the
# junit/json/hugmesh-summary artifacts the admin-bff TestReportsController serves.
case "$(run_target unset stack-e2e)" in
  *--reporter*) _bad "stack-e2e now forces a --reporter — a CLI --reporter REPLACES the config array, dropping junit.xml/report.json/summary.json" ;;
  *)            _ok  "stack-e2e forces no --reporter, so playwright.config.ts's durable reporters stay armed" ;;
esac

echo
echo "-- 4) the recorded reason for NOT delegating to tests/e2e/run.sh stays true --"
# stack-e2e deliberately does not call tests/e2e/run.sh even though run.sh already
# forwards "$@": run.sh hardcodes --reporter=list (which replaces the config's
# reporter array) and picks its engine from whether $PW_IMAGE exists on the box.
# That decision is written up above the target. This check makes it ENFORCEABLE
# rather than merely documented — it is conditional, so a future commit that DOES
# unify the two paths is free to, as long as it fixes the reporter half first.
if [ ! -f "${E2E_RUN_SH}" ]; then
    _bad "tests/e2e/run.sh is missing — the divergence note above stack-e2e names a file that no longer exists"
else
    delegates=no
    case "$(env -u E2E_ARGS make -n --no-print-directory -C "${REPO}" stack-e2e 2>/dev/null)" in
      *run.sh*) delegates=yes ;;
    esac
    forces_list=no
    if grep -e '--reporter=list' "${E2E_RUN_SH}" >/dev/null 2>&1; then forces_list=yes; fi
    if [ "${delegates}" = yes ] && [ "${forces_list}" = yes ]; then
        _bad "stack-e2e now delegates to run.sh while run.sh still hardcodes --reporter=list — the compose lane just lost junit.xml/report.json/summary.json"
    elif [ "${delegates}" = yes ]; then
        _ok "stack-e2e delegates to run.sh, and run.sh no longer forces a reporter — the two paths are safely unified"
    else
        _ok "stack-e2e keeps its own invocation (run.sh still forces --reporter=list=${forces_list}), as the Makefile comment records"
    fi
fi

# stage_e2e_copy SRC DST: build the scratch copy of tests/e2e that section 6's real
# `playwright test --list` runs in. Section 5 scans the same copy. Both sections call
# this ONE function, so the guard checks the copy the leg really makes, not a
# description of it.
#
# It copies the WHOLE directory, minus the generated output that tests/e2e/.gitignore
# lists. Until 2026-11-11 the leg copied four named paths instead (specs/, reporters/,
# playwright.config.ts, package.json). Then spec 34 began to import
# '../steps/governance', and --list exited 1 ("Cannot find module
# '../steps/governance'") on every box that had node_modules. CI has none, so it
# skipped the leg and stayed green. A list of directories to copy breaks again the
# next time a spec imports from a new one; a list of directories to leave out only
# has to follow .gitignore.
#   node_modules            the leg symlinks E2E_NODE_MODULES into its place
#   .features-gen           bddgen output; a stale local copy would add the bdd
#                           lane's generated specs to the listing
#   test-results, playwright-report, shots   per-run artefacts; nothing imports them
# features/ IS copied. With no .features-gen beside it, playwright.config.ts prints
# its "GHERKIN LANE NOT GENERATED" banner to stderr on every listing. That banner is
# expected here, and it is not the reason when the leg fails.
stage_e2e_copy() {
    local src dst e name rc
    src="$1"; dst="$2"; rc=0
    mkdir -p "${dst}" || return 1
    for e in "${src}"/* "${src}"/.[!.]*; do
        # An unmatched glob stays literal; skip it, but keep a dangling symlink.
        [ -e "${e}" ] || [ -L "${e}" ] || continue
        name="${e##*/}"
        case "${name}" in
          node_modules|.features-gen|test-results|playwright-report|shots) continue ;;
        esac
        cp -R "${e}" "${dst}/" || rc=1
    done
    return "${rc}"
}

# scan_imports STAGED SRC: print one "PROBLEM <file> imports <spec>: <why>" line for
# each relative import reachable from STAGED/playwright.config.ts, STAGED/specs/ and
# STAGED/reporters/ that does not resolve inside STAGED. Then print
# "SUMMARY <files> <edges> <staged specs> <SRC specs>". Section 5 runs it on a
# fixture with known answers before it trusts it on the real copy.
scan_imports() {
    python3 - "$1" "$2" <<'PY' 2>&1
import os, re, sys

root = os.path.realpath(sys.argv[1])
src = os.path.realpath(sys.argv[2])
SRC_EXT = ('.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs')
# Playwright's default testMatch: **/*.@(spec|test).?(c|m)[jt]s?(x)
SPEC_RE = re.compile(r'\.(spec|test)\.[cm]?[jt]sx?$')
# The relative specifier of every `from '…'` (import and export-from), bare
# `import '…'`, `import('…')` and `require('…')`. Bare package names resolve
# from node_modules, which the leg symlinks in whole, so only ./ and ../ count.
IMPORT_RE = re.compile(r'''\b(?:from|import|require)\s*\(?\s*(['"])(\.{1,2}/[^'"\r\n]*)\1''')

def sources_under(d):
    out = []
    for dp, dns, fns in os.walk(d):
        dns[:] = [n for n in dns if n != 'node_modules']
        out += [os.path.join(dp, f) for f in fns if f.endswith(SRC_EXT)]
    return sorted(out)

def n_specs(d):
    return sum(1 for f in sources_under(d) if SPEC_RE.search(f))

def resolve(base, spec):
    p = os.path.normpath(os.path.join(base, spec))
    cands = [p + e for e in ('',) + SRC_EXT + ('.json',)]
    cands += [os.path.join(p, 'index' + e) for e in SRC_EXT]
    stem, ext = os.path.splitext(p)
    if ext in ('.js', '.jsx', '.mjs', '.cjs'):  # TS-style './x.js' naming x.ts
        cands += [stem + e for e in ('.ts', '.tsx', '.mts', '.cts')]
    for c in cands:
        if os.path.isfile(c):
            return c
    return None

def rel(p):
    return os.path.relpath(p, root)

roots = [os.path.join(root, 'playwright.config.ts')]
roots += sources_under(os.path.join(root, 'specs'))
roots += sources_under(os.path.join(root, 'reporters'))
seen, todo, edges = set(), list(roots), 0
for r in roots:
    if not os.path.isfile(r):
        print('PROBLEM missing entry point ' + rel(r))
while todo:
    f = todo.pop()
    if f in seen or not os.path.isfile(f):
        continue
    seen.add(f)
    with open(f, encoding='utf-8', errors='replace') as fh:
        text = fh.read()
    for m in IMPORT_RE.finditer(text):
        edges += 1
        spec = m.group(2)
        t = resolve(os.path.dirname(f), spec)
        if t is None:
            print('PROBLEM %s imports %r: not in the staged copy' % (rel(f), spec))
        elif not os.path.realpath(t).startswith(root + os.sep):
            print('PROBLEM %s imports %r: resolves OUTSIDE the staged copy' % (rel(f), spec))
        elif t.endswith(SRC_EXT):
            todo.append(t)
print('SUMMARY %d %d %d %d' % (len(seen), edges,
      n_specs(os.path.join(root, 'specs')), n_specs(os.path.join(src, 'specs'))))
PY
}

echo
echo "-- 5) the scratch copy the --list leg runs in is import-complete (no node_modules needed) --"
# Section 6 is the only leg that loads the specs, and CI always skips it because CI
# has no node_modules. So this section checks the one thing that leg depends on and
# CI CAN see: every relative import reachable from playwright.config.ts, specs/ and
# reporters/ must resolve to a file INSIDE the staged copy. The scan is static
# (python3, which the alpine shell job installs). It cannot see a module that reads
# a repo file through __dirname/../../.. while it loads; only section 6 can.
if ! command -v python3 >/dev/null 2>&1; then
    _bad "python3 is not installed — the import-closure check below asserted NOTHING"
else
    # Staging must keep what it should and drop what it should. A fixture checks
    # this, because a CI checkout has no node_modules or .features-gen to drop.
    FX="${TMP}/fx-src"
    mkdir -p "${FX}/specs" "${FX}/steps" "${FX}/node_modules/pkg" "${FX}/.features-gen" "${FX}/test-results"
    # Three imports with known answers: one resolves, one names a directory that
    # does not exist, and one names a file that exists but OUTSIDE the copy
    # (fx-dst/specs/../../fx-outside.ts is ${TMP}/fx-outside.ts).
    printf '%s\n' "import { b } from '../steps/b';" "import { gone } from '../gone/x';" \
        "import { far } from '../../fx-outside';" "export const all = [b, gone, far];" > "${FX}/specs/a.spec.ts"
    printf 'export const b = 1;\n' > "${FX}/steps/b.ts"
    printf 'export const far = 1;\n' > "${TMP}/fx-outside.ts"
    : > "${FX}/playwright.config.ts"; : > "${FX}/.gitignore"
    : > "${FX}/node_modules/pkg/index.js"; : > "${FX}/.features-gen/x.spec.js"; : > "${FX}/test-results/junit.xml"
    stage_e2e_copy "${FX}" "${TMP}/fx-dst"; fx_rc=$?
    fx_wrong=""
    for p in specs/a.spec.ts steps/b.ts .gitignore; do
        [ -f "${TMP}/fx-dst/${p}" ] || fx_wrong="${fx_wrong} dropped:${p}"
    done
    for p in node_modules .features-gen test-results; do
        [ -e "${TMP}/fx-dst/${p}" ] && fx_wrong="${fx_wrong} copied:${p}"
    done
    if [ "${fx_rc}" -eq 0 ] && [ -z "${fx_wrong}" ]; then
        _ok "staging copies every source dir and dotfile, and leaves out node_modules, .features-gen and test-results"
    else
        _bad "stage_e2e_copy on a fixture: rc=${fx_rc}${fx_wrong}"
    fi
    # A scanner that reports nothing would pass the real copy below whatever it
    # holds. So it must first find exactly the two bad imports in the fixture.
    fx_got="$(scan_imports "${TMP}/fx-dst" "${FX}" | sed -n 's/^PROBLEM //p' | LC_ALL=C sort)"
    fx_want="$(printf '%s\n' \
        "specs/a.spec.ts imports '../gone/x': not in the staged copy" \
        "specs/a.spec.ts imports '../../fx-outside': resolves OUTSIDE the staged copy" | LC_ALL=C sort)"
    eq "${fx_got}" "${fx_want}" "the import scan flags a missing import and an escaping one in a fixture, and passes the one that resolves"

    STAGED="${TMP}/staged"
    stage_e2e_copy "${REPO}/tests/e2e" "${STAGED}" \
        || _bad "staging ${REPO}/tests/e2e into a scratch dir failed — the --list leg would run against a partial copy"
    closure="$(scan_imports "${STAGED}" "${REPO}/tests/e2e")"
    scanned=""; edges=""; n_staged=""; n_src=""
    read -r scanned edges n_staged n_src <<EOF
$(printf '%s\n' "${closure}" | sed -n 's/^SUMMARY //p')
EOF
    problems="$(printf '%s\n' "${closure}" | sed -n 's/^PROBLEM /         /p')"
    if [ -z "${n_src}" ]; then
        _bad "the import-closure scan printed no SUMMARY line, so it asserted nothing:"$'\n'"${closure}"
    else
        if [ "${n_src}" -gt 0 ] && [ "${n_staged}" = "${n_src}" ]; then
            _ok "the staged copy carries all ${n_src} spec file(s) of tests/e2e/specs"
        else
            _bad "the staged copy carries ${n_staged} spec file(s); tests/e2e/specs has ${n_src}"
        fi
        if [ "${edges}" -eq 0 ]; then
            _bad "the scan followed ZERO relative imports across ${scanned} file(s). The specs have dozens, so the pattern is broken and 'all resolved' would mean nothing"
        elif [ -z "${problems}" ]; then
            _ok "all ${edges} relative imports reachable from playwright.config.ts, specs/ and reporters/ resolve inside the staged copy (${scanned} files)"
        else
            _bad "relative imports that the --list leg's scratch copy cannot satisfy (playwright --list exits 1 on any that is loaded at run time):"$'\n'"${problems}"
        fi
    fi
fi

echo
echo "-- 6) OPTIONAL: the real 'playwright test --list' really does enumerate offline --"
# The claim in the Makefile comment is that --list needs no stack and no network.
# It was verified by hand on 2026-08-26 (under `unshare -rn`: rc=0, 1.1s, 33 spec
# files / 221 tests). Re-verifying it here needs an INSTALLED node_modules, which
# CI's shell-suite images do not carry — so this leg SKIPS LOUDLY and is counted as
# a skip, never as a pass. Point E2E_NODE_MODULES at an installed tree to run it.
NM="${E2E_NODE_MODULES:-${REPO}/tests/e2e/node_modules}"
if [ ! -x "${NM}/.bin/playwright" ]; then
    _skip "no Playwright at ${NM}/.bin/playwright — set E2E_NODE_MODULES=<installed tests/e2e/node_modules> to run the real --list leg (nothing in section 6 was asserted)"
else
    # Run against a COPY so a listing can never touch the repo's tests/e2e.
    LIVE="${TMP}/live"
    stage_e2e_copy "${REPO}/tests/e2e" "${LIVE}" \
        || _bad "staging ${REPO}/tests/e2e into ${LIVE} failed — the listing below runs against a partial copy"
    ln -snf "${NM}" "${LIVE}/node_modules"
    REPDIR="${TMP}/reportdir"; mkdir -p "${REPDIR}"
    listing="${TMP}/listing.json"
    ( cd "${LIVE}" && SNAP_REPORT_DIR="${REPDIR}" SNAP_BASE_URL='https://127.0.0.1:1/' \
        ./node_modules/.bin/playwright test -c playwright.config.ts --list --reporter=json ) >"${listing}" 2>"${TMP}/listing.err"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        # Quote the reason here. ${TMP} is removed on EXIT, so a path to
        # listing.err points nowhere. A load failure ("Cannot find module …") is
        # in the JSON report's errors[] on stdout, not on stderr, and stderr
        # always carries the expected Gherkin banner (see stage_e2e_copy).
        why="$(python3 - "${listing}" "${TMP}/listing.err" <<'PY' 2>/dev/null
import json, sys
msgs = []
try:
    for e in json.load(open(sys.argv[1])).get("errors", []):
        lines = [l for l in (e.get("message") or "").splitlines() if l.strip()]
        if lines:
            msgs.append(" / ".join(lines[:2]))
except Exception:
    pass
if not msgs:
    try:
        msgs = ["stderr: " + l for l in open(sys.argv[2]).read().splitlines() if l.strip()][-3:]
    except Exception:
        pass
print(" | ".join(msgs[:3]) or "no error text captured")
PY
)"
        _bad "playwright --list exited ${rc} with the stack down: ${why:-no error text captured}"
    else
        n="$(python3 - "${listing}" <<'PY' 2>/dev/null
import json, sys
try:
    print(len(json.load(open(sys.argv[1]))["suites"]))
except Exception:
    print(-1)
PY
)"
        if [ "${n:-0}" -gt 0 ]; then
            _ok "playwright --list enumerated ${n} spec file(s) with the stack down and no browser launched"
        else
            _bad "playwright --list exited 0 but enumerated nothing (${n}) — an empty listing must not read as success"
        fi
    fi
    # The forced --reporter=json must leave SNAP_REPORT_DIR untouched.
    left="$(find "${REPDIR}" -type f 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${left}" = "0" ]; then
        _ok "--list --reporter=json wrote NO files into SNAP_REPORT_DIR — an enumeration cannot clobber a real run's artifacts"
    else
        _bad "--list --reporter=json wrote ${left} file(s) into SNAP_REPORT_DIR — enumeration is overwriting run artifacts"
    fi
fi

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped =="
[ "${FAIL}" -eq 0 ]
