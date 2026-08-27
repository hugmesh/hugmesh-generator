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
# repo Makefile into a fresh mktemp dir, creates the `tests/e2e/node_modules`
# directory the recipe's precondition looks for, and puts a stub `npx` on PATH that
# writes its argv, one argument per line, and exits 0.
#
#   bash tests/scripts/test-stack-e2e-argv.sh
#
# Optional leg: E2E_NODE_MODULES=/path/to/tests/e2e/node_modules runs the REAL
# `playwright test --list` enumeration. Without it that leg SKIPS LOUDLY and is
# counted as a skip, never as a pass.
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
# (`[ -d tests/e2e/node_modules ] || exit 2`) means an execution test has to run
# somewhere that directory exists; creating it inside the repo would dirty a
# checkout that other sessions share. The Makefile has no `include` lines and its
# eight top-level $(shell …) calls are read-only, so it parses standalone.
# NOTE: mktemp, not a counter. mk_sandbox is called from inside $( ), so a
# `SBOX_N=$((SBOX_N+1))` global increments in a SUBSHELL and never propagates —
# every caller then got the same directory. That was invisible while the npx stub
# truncated its argv file, and turned into cross-test argv accumulation the moment
# the stub started appending.
mk_sandbox() { # -> prints the sandbox dir
    local d
    d="$(mktemp -d "${TMP}/sbox.XXXXXX")"
    mkdir -p "${d}/tests/e2e/node_modules" "${d}/bin"
    cp "${MAKEFILE}" "${d}/Makefile"
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
#   * deleting the `[ -d tests/e2e/node_modules ]` precondition from either target;
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
# The echo's PROSE is deliberately NOT pinned — the Makefile is a shared file and
# several sibling branches touch it, so this asserts the precondition's STRUCTURE
# (which directory, and that it fails non-zero) rather than its wording.

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
    cfg_default="$(grep -e 'baseURL:' "${CFG}" | grep -v -e '^[[:space:]]*//' | sed -n -e "1s/.*||[[:space:]]*'\([^']*\)'.*/\1/p")"
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
      *"[ -d tests/e2e/node_modules ]"*"exit 2"*)
          _ok "${t} still refuses to run when tests/e2e/node_modules is absent" ;;
      *)  _bad "${t} lost its 'tests/e2e/node_modules missing' precondition: it will now run npx against an uninstalled tree"$'\n'"         got:  $(pre_line unset "${t}")" ;;
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

echo
echo "-- 5) OPTIONAL: the real 'playwright test --list' really does enumerate offline --"
# The claim in the Makefile comment is that --list needs no stack and no network.
# It was verified by hand on 2026-08-26 (under `unshare -rn`: rc=0, 1.1s, 33 spec
# files / 221 tests). Re-verifying it here needs an INSTALLED node_modules, which
# CI's shell-suite images do not carry — so this leg SKIPS LOUDLY and is counted as
# a skip, never as a pass. Point E2E_NODE_MODULES at an installed tree to run it.
NM="${E2E_NODE_MODULES:-${REPO}/tests/e2e/node_modules}"
if [ ! -x "${NM}/.bin/playwright" ]; then
    _skip "no Playwright at ${NM}/.bin/playwright — set E2E_NODE_MODULES=<installed tests/e2e/node_modules> to run the real --list leg (nothing in section 5 was asserted)"
else
    # Run against a COPY so a listing can never touch the repo's tests/e2e.
    LIVE="${TMP}/live"
    mkdir -p "${LIVE}"
    cp -r "${REPO}/tests/e2e/specs" "${REPO}/tests/e2e/reporters" \
          "${REPO}/tests/e2e/playwright.config.ts" "${REPO}/tests/e2e/package.json" "${LIVE}/" 2>/dev/null
    ln -snf "${NM}" "${LIVE}/node_modules"
    REPDIR="${TMP}/reportdir"; mkdir -p "${REPDIR}"
    listing="${TMP}/listing.json"
    ( cd "${LIVE}" && SNAP_REPORT_DIR="${REPDIR}" SNAP_BASE_URL='https://127.0.0.1:1/' \
        ./node_modules/.bin/playwright test -c playwright.config.ts --list --reporter=json ) >"${listing}" 2>"${TMP}/listing.err"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        _bad "playwright --list exited ${rc} with the stack down; see ${TMP}/listing.err"
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
