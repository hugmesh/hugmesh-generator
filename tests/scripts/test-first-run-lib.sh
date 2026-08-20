#!/usr/bin/env bash
# test-first-run-lib.sh — hermetic checks for scripts/_first-run-lib.sh +
# studio/hugmesh_studio/core/first_run.py, the first-run bootstrap pair
# (issue #49): ~/.local/bin symlinks, a versioned properties.json, an
# advisory doctor pass, and a stamp that makes reruns no-ops.
#
# NOTHING here touches the real $HOME, PATH-installs anything, or runs the
# real docker CLI:
#   * $HUGMESH_STUDIO_STATE_DIR and $HUGMESH_BIN_DIR point every write at a
#     mktemp scratch tree,
#   * a PATH SHIM provides a fake `docker` (always "image missing"), so the
#     doctor's builder-image probe never reaches a real daemon,
#   * the no-op/redo proofs run against a RECORDING fake venv python, so a
#     rerun that wrongly re-invokes python is caught without side effects.
#
#   bash tests/scripts/test-first-run-lib.sh
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/../.." && pwd)"
LIB="${REPO_DIR}/scripts/_first-run-lib.sh"
SH_BIN="$(command -v sh)"

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); }
_bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1" >&2; }
assert_eq()   { [ "$2" = "$3" ] && _ok || _bad "$1: got '$2' want '$3'"; }
assert_grep() { printf '%s\n' "$2" | grep -Eq -- "$3" && _ok || _bad "$1: missing /$3/"; }
assert_nogrep() { printf '%s\n' "$2" | grep -Eq -- "$3" && _bad "$1: unexpected /$3/" || _ok; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── the hermetic sandbox ─────────────────────────────────────────────────────────
# A fake checkout whose studio/hugmesh_studio is the REAL package (symlink), so
# `python3 -m hugmesh_studio.core.first_run` runs the code under test while every
# resolved path stays inside ${WORK}.
FAKE_REPO="${WORK}/repo"
mkdir -p "${FAKE_REPO}/scripts" "${FAKE_REPO}/studio"
ln -s "${REPO_DIR}/studio/hugmesh_studio" "${FAKE_REPO}/studio/hugmesh_studio"
printf '#!/bin/sh\nexit 0\n' > "${FAKE_REPO}/scripts/studio-launch.sh"
printf '#!/bin/sh\nexit 0\n' > "${FAKE_REPO}/scripts/build-menu.sh"
chmod +x "${FAKE_REPO}/scripts/studio-launch.sh" "${FAKE_REPO}/scripts/build-menu.sh"

# PATH shim: the doctor must see a docker CLI but must NEVER reach a real daemon.
SHIMS="${WORK}/shims"
mkdir -p "${SHIMS}"
printf '#!/bin/sh\nexit 1\n' > "${SHIMS}/docker"   # every inspect: "missing"
chmod +x "${SHIMS}/docker"

STATE="${WORK}/state"
BIN="${WORK}/bin"

# Run a snippet under PLAIN sh with the lib sourced and the sandbox env applied.
# ($1 = snippet; stdin/stdout/stderr merged so callers can grep everything.)
run_lib() {
    env -u PYTHONPATH -u IMAGE -u HUGMESH_REDO_FIRST_RUN \
        HUGMESH_STUDIO_STATE_DIR="${STATE}" HUGMESH_BIN_DIR="${BIN}" \
        PATH="${SHIMS}:${PATH}" \
        "${SH_BIN}" -c ". '${LIB}'; $1" 2>&1
}

# ── 1. static: POSIX syntax + the no-bashism gate ────────────────────────────────
"${SH_BIN}" -n "${LIB}" && _ok || _bad "sh -n: syntax error"
# STRICT POSIX contract (fix/posix-and-portability gates sh-sourced libs):
# no arrays, no double-bracket tests, no local/declare may ever creep in.
# (Comments are stripped first — the lib's own header NAMES these constructs.)
bashisms="$(sed 's/#.*$//' "${LIB}" | grep -En '\[\[|(^|[^A-Za-z_])local |(^|[^A-Za-z_])declare |\+=\(' || true)"
assert_eq "posix: no bashisms in the lib" "${bashisms}" ""
# The two halves of the pair must agree on the stamp version, or the shell gate
# would loop (always stale) or rot (never re-trigger).
py_ver="$(sed -n 's/^FIRST_RUN_VERSION = \([0-9][0-9]*\)$/\1/p' \
    "${REPO_DIR}/studio/hugmesh_studio/core/first_run.py")"
sh_ver="$(sed -n 's/^FIRST_RUN_LIB_VERSION=\([0-9][0-9]*\)$/\1/p' "${LIB}")"
assert_eq "version: shell half matches python half" "${sh_ver}" "${py_ver}"

# ── 2. every CLI entrypoint sources the lib and calls the bootstrap ─────────────
for entry in scripts/studio-launch.sh scripts/build-menu.sh scripts/hugmesh-mesh-node; do
    grep -q '_first-run-lib\.sh' "${REPO_DIR}/${entry}" \
        && _ok || _bad "${entry}: does not source _first-run-lib.sh"
    grep -q 'first_run_bootstrap' "${REPO_DIR}/${entry}" \
        && _ok || _bad "${entry}: never calls first_run_bootstrap"
done

# ── 3. first_run_wants_redo: flag, env, neither ──────────────────────────────────
assert_eq "wants_redo: flag"    "$(run_lib 'first_run_wants_redo up --redo-first-run')" 1
assert_eq "wants_redo: neither" "$(run_lib 'first_run_wants_redo up --keys x')" 0
assert_eq "wants_redo: env" \
    "$(env HUGMESH_REDO_FIRST_RUN=1 "${SH_BIN}" -c ". '${LIB}'; first_run_wants_redo")" 1

# ── 4. the first bootstrap: stamp + properties + symlinks + advisory doctor ─────
out="$(run_lib "first_run_bootstrap '${FAKE_REPO}' 0")"; rc=$?
assert_eq   "bootstrap: rc 0"              "${rc}" 0
assert_grep "bootstrap: start line"        "${out}" '^FIRSTRUN bootstrap=start version=1'
assert_grep "bootstrap: properties line"   "${out}" '^FIRSTRUN properties=written'
assert_grep "bootstrap: studio link"       "${out}" '^FIRSTRUN link=hugmesh-studio status=created'
assert_grep "bootstrap: menu link"         "${out}" '^FIRSTRUN link=hugmesh-build-menu status=created'
assert_grep "bootstrap: doctor git"        "${out}" '^DOCTOR git='
assert_grep "bootstrap: doctor venv"       "${out}" '^DOCTOR venv=absent'
assert_grep "bootstrap: doctor image miss" "${out}" '^DOCTOR builder_image=missing name=hugmesh-builder'
assert_grep "bootstrap: one-line hint"     "${out}" 'make docker-image'
assert_grep "bootstrap: doctor kvm"        "${out}" '^DOCTOR kvm='
assert_grep "bootstrap: done line"         "${out}" '^FIRSTRUN bootstrap=done'
assert_eq   "bootstrap: stamp records v1"  "$(cat "${STATE}/first-run.stamp" 2>/dev/null)" 1
[ -f "${STATE}/properties.json" ] && _ok || _bad "bootstrap: properties.json missing"
[ -L "${BIN}/hugmesh-studio" ] && _ok || _bad "bootstrap: hugmesh-studio symlink missing"
[ -L "${BIN}/hugmesh-build-menu" ] && _ok || _bad "bootstrap: hugmesh-build-menu symlink missing"
assert_eq "bootstrap: studio link target" \
    "$(readlink "${BIN}/hugmesh-studio")" "${FAKE_REPO}/scripts/studio-launch.sh"
# The reserved appliance name must never be created by the generator's bootstrap.
[ -e "${BIN}/hugmesh-mesh-node" ] && _bad "bootstrap: created the RESERVED hugmesh-mesh-node name" || _ok

# ── 5. properties: readable back through the shell accessor ─────────────────────
assert_eq "property: builder_image" "$(run_lib 'first_run_property builder_image')" hugmesh-builder
assert_eq "property: generator_dir" "$(run_lib 'first_run_property generator_dir')" "${FAKE_REPO}"
run_lib 'first_run_property no_such_key' >/dev/null && _bad "property: missing key must rc!=0" || _ok

# ── 6. rerun is a NO-OP: python is never re-invoked once stamped ─────────────────
# A recording fake venv python would be PREFERRED by the lib if it ran python at
# all — so an empty call-log after a rerun PROVES the one-`cat` fast path.
PYCALLS="${WORK}/pycalls"
mkdir -p "${FAKE_REPO}/studio/.venv-studio/bin"
printf '#!/bin/sh\necho "$@" >> "%s"\nexit 0\n' "${PYCALLS}" \
    > "${FAKE_REPO}/studio/.venv-studio/bin/python"
chmod +x "${FAKE_REPO}/studio/.venv-studio/bin/python"
out="$(run_lib "first_run_bootstrap '${FAKE_REPO}' 0")"; rc=$?
assert_eq "noop: rc 0"            "${rc}" 0
assert_eq "noop: prints nothing"  "${out}" ""
[ -e "${PYCALLS}" ] && _bad "noop: python was re-invoked despite a current stamp" || _ok

# ── 7. --redo-first-run forces a rerun (and reaches python with the flag) ───────
out="$(run_lib "first_run_bootstrap '${FAKE_REPO}' 1")"; rc=$?
assert_eq   "redo: rc 0"                 "${rc}" 0
assert_grep "redo: python re-invoked with the flag" "$(cat "${PYCALLS}" 2>/dev/null)" 'redo-first-run'
rm -rf "${FAKE_REPO}/studio/.venv-studio" "${PYCALLS}"

# ── 8. a stale stamp version re-triggers the bootstrap ──────────────────────────
printf '0\n' > "${STATE}/first-run.stamp"
out="$(run_lib "first_run_bootstrap '${FAKE_REPO}' 0")"
assert_grep "stale stamp: bootstrap reran" "${out}" '^FIRSTRUN bootstrap=done'
assert_eq   "stale stamp: restamped to v1" "$(cat "${STATE}/first-run.stamp")" 1

# ── 9. foreign files in the bin dir are NEVER clobbered ─────────────────────────
STATE="${WORK}/state2"; BIN="${WORK}/bin2"
mkdir -p "${BIN}"
printf 'not ours\n' > "${BIN}/hugmesh-studio"
out="$(run_lib "first_run_bootstrap '${FAKE_REPO}' 0")"; rc=$?
assert_eq   "foreign: rc 0"                "${rc}" 0
assert_grep "foreign: reported"            "${out}" 'link=hugmesh-studio status=skipped-foreign-file'
assert_eq   "foreign: file untouched"      "$(cat "${BIN}/hugmesh-studio")" "not ours"
assert_grep "foreign: other link created"  "${out}" 'link=hugmesh-build-menu status=created'
assert_eq   "foreign: still stamped"       "$(cat "${STATE}/first-run.stamp")" 1

# ── 10. no python3 anywhere: one advisory line, rc 0, launch never blocked ──────
STATE="${WORK}/state3"; BIN="${WORK}/bin3"
noby="${WORK}/nobin"; mkdir -p "${noby}"
for t in sh cat grep sed; do ln -s "$(command -v ${t})" "${noby}/${t}" 2>/dev/null; done
out="$(env -u PYTHONPATH HUGMESH_STUDIO_STATE_DIR="${STATE}" HUGMESH_BIN_DIR="${BIN}" \
    PATH="${noby}" "${SH_BIN}" -c ". '${LIB}'; first_run_bootstrap '${FAKE_REPO}' 0" 2>&1)"; rc=$?
assert_eq   "no-python: rc 0"          "${rc}" 0
assert_grep "no-python: advisory line" "${out}" 'python3 not found'
[ -e "${STATE}/first-run.stamp" ] && _bad "no-python: must not stamp" || _ok

# ── 11. a FAILING python bootstrap is advisory: rc stays 0 ───────────────────────
STATE="${WORK}/state4"; BIN="${WORK}/bin4"
BADREPO="${WORK}/badrepo"; mkdir -p "${BADREPO}/studio"   # no hugmesh_studio package
out="$(run_lib "first_run_bootstrap '${BADREPO}' 0")"; rc=$?
assert_eq   "bad-repo: rc 0"           "${rc}" 0
assert_grep "bad-repo: advisory line"  "${out}" 'advisory only'
[ -e "${STATE}/first-run.stamp" ] && _bad "bad-repo: must not stamp a failed bootstrap" || _ok

# ── 12. the launcher's HEADLESS channel stays pure: no installs, ever ────────────
# --print-command (headless automation) with an EMPTY state dir must neither
# stamp nor create symlinks — its documented contract is "no prompts, no installs".
STATE="${WORK}/state5"; BIN="${WORK}/bin5"
env HUGMESH_STUDIO_STATE_DIR="${STATE}" HUGMESH_BIN_DIR="${BIN}" \
    bash "${REPO_DIR}/scripts/studio-launch.sh" --print-command --backend native >/dev/null 2>&1
[ -e "${STATE}/first-run.stamp" ] && _bad "headless: stamped (installed) on the automation channel" || _ok
[ -e "${BIN}/hugmesh-studio" ] && _bad "headless: created a symlink on the automation channel" || _ok

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
