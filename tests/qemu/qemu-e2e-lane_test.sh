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
# NOTHING here boots a guest, builds an image, needs docker or needs root. The
# real Playwright is never run: `npx` is a stub on PATH, so an assertion about
# "--reporter=json" is an assertion about what a CHILD received.
#
# Each positive leg has a break-it twin, because an assertion that cannot fail is
# not one.
#
#   bash tests/qemu/qemu-e2e-lane_test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${HERE}/run-qemu-e2e.sh"

PASS=0; FAIL=0
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

if [ "$(id -u)" -eq 0 ]; then
    say "SKIP (LOUD, NAMED): this suite asserts the NON-ROOT refusal and is running"
    say "                    as uid 0, where that refusal cannot happen. Re-run as a"
    say "                    normal user. Counted as a skip, never as a pass."
    exit 0
fi

work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
export TMPDIR="${work}"

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
out="$(bash "${SCRIPT}" -w "${art}" --role be --list 2>/dev/null)"
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
ok_eq "$(printf '%s' "${out}" | json_get 'd["role"]')" '"be"'
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
dry="$(bash "${SCRIPT}" -w "${art}" --role be --dry-run 2>&1)"
ok_eq "$?" "0"
ok_has "dry-run" "${dry}"
ok_has "would run" "${dry}"

say "── the non-root refusal: containerized route, and NEVER sudo ──"
ref="$(bash "${SCRIPT}" -w "${art}" --role be 2>&1)"
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
ok_has "-w ${art} --role be --list" "${ref}"
# NEGATIVE CONTROL: the refusal must not claim to have booted anything.
ok_not "[1/5]" "${ref}"
ok_not "Powering down" "${ref}"

say "── the script's own help does not lead with sudo ──"
help="$(bash "${SCRIPT}" --help 2>&1)"
ok_not "Usage: sudo" "${help}"
ok_has "--list" "${help}"
ok_has "hugmesh-qemu-runner" "${help}"

printf 'qemu-e2e-lane_test: %d passed, %d failed\n' "${PASS}" "${FAIL}" >&2
[ "${FAIL}" -eq 0 ]
