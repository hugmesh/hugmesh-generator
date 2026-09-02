#!/usr/bin/env bash
# qemu-e2e-lane_test.sh — HERMETIC tests for the QEMU *Playwright* lane's two
# non-root verbs and its refusal, added when that lane was finally wired into the
# Studio (2026-08-26).
#
# WHAT IS UNDER TEST, and what deliberately is NOT.
#   * `--list`   — the enumeration a feature tree reads: the boot plan as JSON plus
#                  the Playwright spec tree. Asserted by PARSING the JSON and by the
#                  argv a stub `npx` actually receives, never by grepping the script.
#   * the refusal — non-root must exit non-zero, name the CONTAINERIZED route, and
#                  never tell anyone to sudo (the Studio drives this script and a GUI
#                  cannot answer a password prompt).
#   * `--dry-run` — still resolves artifacts without root.
#   * the Makefile — that `make e2e` / `make e2e-list` render a `--` separator, so
#                  E2E_ARGS reaches Playwright instead of this script's parser
#                  (which hard-errors on any unrecognised word).
# NOTHING here boots a guest, builds an image, needs docker or needs root. The
# real Playwright is never run: `npx` is a stub on PATH, so an assertion about
# "--reporter=json" is an assertion about what a CHILD received.
#
# THERE IS NO SKIP. Running as uid 0 does not disarm this file: the refusal legs go
# through a PROVEN `id -u` PATH shim (see below), and a shim that fails to take is a
# FAILURE, not a skip. The first cut exited 0 with zero assertions under root, and
# check.sh scores exit-0 as PASS — a loud banner on stdout is invisible to it.
#
# Each positive leg has a break-it twin, because an assertion that cannot fail is
# not one.
#
#   bash tests/qemu/qemu-e2e-lane_test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${HERE}/run-qemu-e2e.sh"

PASS=0; FAIL=0; SKIP=0
_ok()  { PASS=$((PASS+1)); }
_bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1" >&2; }
say()  { printf '%s\n' "$1"; }
# contains/not-contains. `grep -q` is avoided on purpose: under `set -o pipefail`
# its SIGPIPE-on-first-match turns a FOUND match into a failed pipeline. These
# drain into /dev/null instead.
has()    { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
ok_has() { if has "$1" "$2"; then _ok; else _bad "expected to contain: $1"; fi; }
ok_not() { if has "$1" "$2"; then _bad "expected NOT to contain: $1"; else _ok; fi; }
ok_eq()  { if [ "$1" = "$2" ]; then _ok; else _bad "expected '$2', got '$1'"; fi; }

work="$(mktemp -d)"
export TMPDIR="${work}"

# ── the structural anti-vacuum latch ───────────────────────────────────────────
# tests/build-matrix/check.sh's run_nongating_smokes scores `bash <suite>` exiting 0
# as PASS and prints the suite's output ONLY on failure. So a suite that decides to
# skip itself — for uid 0, a missing tool, anything — is scored a pass no matter how
# loudly it says otherwise on stdout. The exit code is the only channel there is.
# This trap closes that for good: reaching ANY exit with fewer than MIN_ASSERTIONS
# executed turns a 0 into a 1. There is no arrangement of this file that reports
# success without having asserted something.
# 50, not the ~69 a full run makes: the `make -n` render legs at the bottom
# legitimately skip on a box with no make (≈12 assertions), and the floor exists
# to catch a suite that asserted NOTHING, not to pin an exact count.
MIN_ASSERTIONS=50
_at_exit() {
    local rc=$?
    rm -rf "${work}" 2>/dev/null || true
    if [ "${rc}" -eq 0 ] && [ "${PASS}" -lt "${MIN_ASSERTIONS}" ]; then
        printf 'FAIL only %d assertion(s) ran (floor %d) — an exit-0 that asserted nothing is NOT a pass\n' \
            "${PASS}" "${MIN_ASSERTIONS}" >&2
        exit 1
    fi
    exit "${rc}"
}
trap _at_exit EXIT

# ── running as uid 0 must NOT make this suite vacuous ───────────────────────
# The first cut exited 0 here with ZERO assertions executed, and tests/build-matrix/
# check.sh's run_nongating_smokes scores `bash <suite>` exiting 0 as PASS, showing
# stdout only on FAILURE — so the loud banner was invisible in exactly the place it
# mattered (root CI runner, container). Skipping was also all-or-nothing: the --list
# JSON legs, the npx-stub argv proof, the loud-skip leg, --dry-run, the help legs and
# the Makefile-rendering legs all run perfectly well as root and were thrown away too.
#
# So nothing is skipped. run-qemu-e2e.sh decides with ONE `id -u` (line ~333), which
# is an external command, so a PATH shim reaches it — the refusal branch is exercised
# under uid 0 against a uid the script believes. The shim is PROVEN to take effect
# before it is trusted, and if it does not, this is a hard FAIL, never a skip: there
# is no path through this file that reports success without asserting.
REFUSAL_PATH="${PATH}"
idshim="${work}/idshim"; mkdir -p "${idshim}"
cat > "${idshim}/id" <<'IDSTUB'
#!/usr/bin/env bash
# Answer ONLY the `id -u` this lane branches on; defer anything else to the real id.
if [ "${1:-}" = "-u" ] && [ "$#" -eq 1 ]; then echo 1000; exit 0; fi
command -p id "$@"
IDSTUB
chmod +x "${idshim}/id"
if [ "$(id -u)" -eq 0 ]; then
    say "── uid 0: the refusal legs run against a PROVEN \`id -u\` shim ──"
    if [ "$(PATH="${idshim}:${PATH}" id -u)" = "1000" ]; then
        _ok
        REFUSAL_PATH="${idshim}:${PATH}"
    else
        _bad "running as uid 0 and the id shim did not take — refusal legs CANNOT be trusted"
        say "  (refusing to run a real boot attempt as root; this is a FAILURE, not a skip)"
        REFUSAL_PATH=""
    fi
fi

# A throwaway repo the script can live in, so tests/e2e/node_modules and a stub
# npx can be arranged without touching the real checkout.
fakerepo="${work}/repo"
mkdir -p "${fakerepo}/tests/qemu" "${fakerepo}/tests/e2e"
cp "${SCRIPT}" "${fakerepo}/tests/qemu/run-qemu-e2e.sh"
FAKE="${fakerepo}/tests/qemu/run-qemu-e2e.sh"

# An artifacts dir holding one x86 image, and an empty one.
art="${work}/art"; mkdir -p "${art}"
: > "${art}/hugmesh-host-x86-be-test-20260101T000000Z.img"
empty="${work}/empty"; mkdir -p "${empty}"

# Read one value out of the emitted JSON. The expression is evaluated with the
# document bound to `d`, so both `d["lane"]` and `len(d["phases"])` are legal.
json_get() { python3 -c 'import json,sys;d=json.load(sys.stdin);print(json.dumps(eval(sys.argv[1],{"len":len,"d":d})))' "$1"; }

say "── the lane scripts parse ──"
if bash -n "${SCRIPT}" 2>/dev/null; then _ok; else _bad "run-qemu-e2e.sh does not parse"; fi

say "── --list: valid JSON, needs no root, boots nothing ──"
out="$(bash "${SCRIPT}" -w "${art}" --role backend --list 2>/dev/null)"
rc=$?
ok_eq "${rc}" "0"
if printf '%s' "${out}" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    _ok
else
    _bad "--list did not emit parseable JSON"
fi
ok_eq "$(printf '%s' "${out}" | json_get 'd["lane"]')" '"qemu-playwright"'
ok_eq "$(printf '%s' "${out}" | json_get 'd["needs_root"]')" 'true'
ok_eq "$(printf '%s' "${out}" | json_get 'd["target"]')" '"x86"'
ok_eq "$(printf '%s' "${out}" | json_get 'd["role"]')" '"backend"'
ok_eq "$(printf '%s' "${out}" | json_get 'd["ui_port"]')" '8443'
ok_eq "$(printf '%s' "${out}" | json_get 'd["base_url"]')" '"https://localhost:8443"'
ok_eq "$(printf '%s' "${out}" | json_get 'len(d["phases"])')" '5'
ok_has "hugmesh-host-x86-be-test" "$(printf '%s' "${out}" | json_get 'd["artifacts"]["x86_img"]')"
# NEGATIVE CONTROL: the enumeration must not have booted or seeded anything.
ok_not "Booting" "${out}"
ok_not "Seeding" "${out}"

say "── --list on a work dir with NO artifacts still enumerates ──"
# The old autodetect block DIES here ("x86 .img not found"); a feature tree must be
# able to describe the lane before anything is built.
out2="$(bash "${SCRIPT}" -w "${empty}" --list 2>/dev/null)"
ok_eq "$?" "0"
ok_eq "$(printf '%s' "${out2}" | json_get 'd["artifacts"]["x86_img"]')" 'null'
ok_not "not found" "${out2}"

say "── --list carries the -- passthrough as SEPARATE arguments ──"
out3="$(bash "${SCRIPT}" -w "${art}" --list -- --grep @smoke specs/01.spec.ts 2>/dev/null)"
ok_eq "$(printf '%s' "${out3}" | json_get 'd["playwright_args"]')" \
      '["--grep", "@smoke", "specs/01.spec.ts"]'
# NEGATIVE CONTROL: a quoting regression that passed it as ONE argument would give
# a single-element list, which the assertion above already discriminates.
ok_eq "$(printf '%s' "${out3}" | json_get 'len(d["playwright_args"])')" '3'

say '── --list drives: playwright test --list --reporter=json, and RUNS nothing ──'
mkdir -p "${fakerepo}/tests/e2e/node_modules"
bin="${work}/bin"; mkdir -p "${bin}"
cat > "${bin}/npx" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${NPX_ARGV_LOG}"
# Emit something that parses as the Playwright --list JSON shape.
echo '{"suites": [], "stub": true}'
STUB
chmod +x "${bin}/npx"
export NPX_ARGV_LOG="${work}/npx-argv.txt"
out4="$(PATH="${bin}:${PATH}" bash "${FAKE}" -w "${art}" --list -- --grep @smoke 2>/dev/null)"
ok_eq "$?" "0"
argv="$(cat "${NPX_ARGV_LOG}" 2>/dev/null || echo MISSING)"
ok_has "playwright test" "${argv}"
ok_has "--list" "${argv}"
ok_has "--reporter=json" "${argv}"        # forced: a bare --list fires the FILE writers
ok_has "--grep @smoke" "${argv}"          # the passthrough narrows the LISTING too
ok_eq "$(printf '%s' "${out4}" | json_get 'd["playwright"]["stub"]')" 'true'
ok_eq "$(printf '%s' "${out4}" | json_get 'd["playwright_skipped"]')" 'null'
# NEGATIVE CONTROL: it must not have gone through tests/e2e/run.sh, which hardcodes
# --reporter=list and would both RUN the suite and re-arm the file writers.
ok_not "--reporter=list" "${argv}"

say "── --list SKIPS LOUDLY, by name, when the specs cannot be enumerated ──"
rm -rf "${fakerepo}/tests/e2e/node_modules"
err="$(PATH="${bin}:${PATH}" bash "${FAKE}" -w "${art}" --list 2>&1 >/dev/null)"
out5="$(PATH="${bin}:${PATH}" bash "${FAKE}" -w "${art}" --list 2>/dev/null)"
ok_has "SKIPPING the spec enumeration" "${err}"
ok_has "node_modules" "${err}"
ok_has "playwright-deps" "${err}"
ok_has "node_modules" "$(printf '%s' "${out5}" | json_get 'd["playwright_skipped"]')"
ok_eq "$(printf '%s' "${out5}" | json_get 'd["playwright"]')" 'null'
# ...and the boot-plan half still answers, so a skip is never an empty document.
ok_eq "$(printf '%s' "${out5}" | json_get 'len(d["phases"])')" '5'

say "── --dry-run needs no root either ──"
dry="$(bash "${SCRIPT}" -w "${art}" --role backend --dry-run 2>&1)"
ok_eq "$?" "0"
ok_has "dry-run" "${dry}"
ok_has "would run" "${dry}"

say "── the non-root refusal: containerized route, and NEVER sudo ──"
# LAUNCH_X86/LAUNCH_PI are pointed at /bin/false as a second belt: if the shim ever
# stopped taking under uid 0, the script could not boot anything, and `ok_not "[1/5]"`
# below turns that into a RED assertion instead of a real VM.
if [ -n "${REFUSAL_PATH}" ]; then
    ref="$(PATH="${REFUSAL_PATH}" LAUNCH_X86=/bin/false LAUNCH_PI=/bin/false \
           bash "${SCRIPT}" -w "${art}" --role backend 2>&1)"
    rc=$?
    if [ "${rc}" -ne 0 ]; then _ok; else _bad "a non-root boot attempt exited 0"; fi
    ok_has "--privileged" "${ref}"
    ok_has "hugmesh-qemu-runner" "${ref}"
    ok_has "make qemu-docker-image" "${ref}"
    ok_has "docker" "${ref}"
    # The one instruction this harness must never give. The old message was literally
    # `run as root (...): sudo $0 ...`.
    ok_not "sudo tests/qemu/run-qemu-e2e.sh" "${ref}"
    ok_not "sudo ${SCRIPT}" "${ref}"
    # It offers the two verbs that DO work, echoing back what was actually typed.
    ok_has "--list" "${ref}"
    ok_has "--dry-run" "${ref}"
    ok_has "-w ${art} --role backend --list" "${ref}"
    # NEGATIVE CONTROL: the refusal must not claim to have booted anything.
    ok_not "[1/5]" "${ref}"
    ok_not "Powering down" "${ref}"
else
    SKIP=$((SKIP+1))
    say "  SKIPPED the refusal legs (already counted as a FAILURE above)"
fi

say "── the script's own help does not lead with sudo ──"
help="$(bash "${SCRIPT}" --help 2>&1)"
ok_not "Usage: sudo" "${help}"
ok_has "--list" "${help}"
ok_has "hugmesh-qemu-runner" "${help}"

say "── every Makefile lane that passes E2E_ARGS to this script uses the -- separator ──"
# WHY THIS EXISTS. `make e2e E2E_ARGS=...` shipped on 2026-08-26 appending the args
# BARE. This script's parser ends in `*) echo "Unknown arg: $1"; usage 1`, so every
# value was a hard error — a flag, a bare spec path, anything. e2e-list one line
# below already had it right, which is precisely what made the omission invisible.
# The name is the trap: for `make stack-e2e`, `npx playwright test` is the DIRECT
# consumer and bare argv is correct; this lane interposes a shell script.
#
# The scan looks at EVERY site rather than the one line that was wrong, and STRIPS
# FULL-LINE COMMENTS first: a token that appears only in a comment has passed for
# real in this repo more than once, and the comment right above the `e2e` recipe now
# contains the exact string `-- $(E2E_ARGS)`. Both properties get a break-it twin.
MK="${REPO}/Makefile"
mk_strip()    { sed -e 's/^[[:space:]]*#.*$//' "$1"; }
mk_sites()    { mk_strip "$1" | grep 'run-qemu-e2e\.sh' | grep 'E2E_ARGS' || true; }
mk_n_sites()  { mk_sites "$1" | grep -c . || true; }
mk_bad()      { mk_sites "$1" | grep -v -- '-- $(E2E_ARGS)' || true; }

# Two lanes hand E2E_ARGS to run-qemu-e2e.sh today: e2e and e2e-list. Pinning the
# COUNT is what makes a future third lane that forgets the separator visible here.
ok_eq "$(mk_n_sites "${MK}")" "2"
ok_eq "$(mk_bad "${MK}" | tr -d '[:space:]')" ""

# BREAK-IT TWIN #1: a recipe that drops the separator must be caught. Built by
# mutating the REAL Makefile, and the mutation is proven to have changed the file
# (a no-op sed that silently matched nothing would make this twin prove nothing).
mkmut="${work}/Makefile.mut"
sed -e 's/--role $(ROLE) $(if $(E2E_ARGS),-- $(E2E_ARGS))/--role $(ROLE) $(E2E_ARGS)/' \
    "${MK}" > "${mkmut}"
if cmp -s "${MK}" "${mkmut}"; then _bad "mutant Makefile is IDENTICAL to the real one — the twin proves nothing"; else _ok; fi
if [ -n "$(mk_bad "${mkmut}")" ]; then _ok; else _bad "a recipe with NO -- separator was judged clean"; fi

# BREAK-IT TWIN #2 — COMMENT-TOKEN INVERSION, the defect that has shipped green in
# this repo more than once. Take the broken mutant and add ONE comment line naming
# both the script and the separator. A guard written the obvious way ("the Makefile
# must contain `-- $(E2E_ARGS)` next to run-qemu-e2e.sh") is now satisfied BY THE
# COMMENT while the recipe is still broken. Both halves are asserted: the naive form
# really is fooled, and the comment-stripping form really does stay RED.
printf '%s\n' '# NOTE: tests/qemu/run-qemu-e2e.sh wants -- $(E2E_ARGS), see above.' >> "${mkmut}"
naive="$(grep 'run-qemu-e2e\.sh' "${mkmut}" | grep 'E2E_ARGS' | grep -- '-- $(E2E_ARGS)' || true)"
if [ -n "${naive}" ]; then _ok; else _bad "the naive comment-blind check was NOT fooled — this twin no longer models the defect"; fi
if [ -n "$(mk_bad "${mkmut}")" ]; then _ok; else _bad "COMMENT-TOKEN INVERSION: a comment satisfied the separator assertion"; fi
# ...and the comment must not inflate the site COUNT either (the other half of the
# same defect: a comment masquerading as a wiring site).
ok_eq "$(mk_n_sites "${mkmut}")" "2"

say "── the argv make ACTUALLY renders survives this script's parser ──"
if command -v make >/dev/null 2>&1; then
    rendered="$(cd "${REPO}" && make -n e2e E2E_ARGS='--grep @smoke specs/01-frontpage.spec.ts' 2>/dev/null | grep 'run-qemu-e2e\.sh' || true)"
    ok_has " -- --grep @smoke specs/01-frontpage.spec.ts" "${rendered}"
    # Feed the REAL rendered argv to the REAL parser. `sudo` is dropped with the
    # command name (it is never run), and --list goes FIRST because everything after
    # the `--` belongs to Playwright by definition.
    argv_line="${rendered#*run-qemu-e2e.sh}"
    ok_not '$(' "${argv_line}"        # make must have expanded everything already
    mapfile -t MK_ARGV < <(printf '%s' "${argv_line}" \
        | python3 -c 'import shlex,sys;print("\n".join(shlex.split(sys.stdin.read())))')
    # stdout is the JSON document and NOTHING else; stderr carries the loud
    # node_modules skip (this checkout has none), so they are captured apart —
    # merging them is what made the first cut of this leg feed a banner to json.load.
    mkerr="${work}/mk.err"
    mk="$(bash "${SCRIPT}" --list "${MK_ARGV[@]}" 2>"${mkerr}")"
    ok_eq "$?" "0"
    ok_not "Unknown arg" "$(cat "${mkerr}")"
    ok_not "Usage:" "$(cat "${mkerr}")"
    ok_not "Unknown arg" "${mk}"
    ok_eq "$(printf '%s' "${mk}" | json_get 'd["playwright_args"]')" \
          '["--grep", "@smoke", "specs/01-frontpage.spec.ts"]'
    ok_eq "$(printf '%s' "${mk}" | json_get 'd["role"]')" '"backend-gpu"'

    # ...and unset E2E_ARGS must NOT emit a dangling separator (M18's twin, at the
    # Makefile layer this time): the default is still the whole suite.
    plain="$(cd "${REPO}" && make -n e2e 2>/dev/null | grep 'run-qemu-e2e\.sh' || true)"
    ok_not " -- " "${plain}"
    ok_has "--role backend-gpu" "${plain}"

    # NEGATIVE CONTROL — the bug exactly as it shipped. Both of these are what the
    # reviewer ran, and both must still be hard errors, or the separator is theatre.
    b1="$(bash "${SCRIPT}" --list -w "${art}" --role backend --grep @smoke 2>&1 || true)"
    ok_has "Unknown arg: --grep" "${b1}"
    b2="$(bash "${SCRIPT}" --list -w "${art}" --role backend 01-frontpage 2>&1 || true)"
    ok_has "Unknown arg: 01-frontpage" "${b2}"
else
    SKIP=$((SKIP+1))
    say "  SKIP: no make on PATH — the rendered-argv legs did not run (the static scan above did)"
fi

printf 'qemu-e2e-lane_test: %d passed, %d failed, %d skipped\n' \
    "${PASS}" "${FAIL}" "${SKIP}" >&2
[ "${FAIL}" -eq 0 ]
