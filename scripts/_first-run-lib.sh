#!/bin/sh
# _first-run-lib.sh — SOURCED helper (STRICT POSIX sh): the first-run bootstrap
# gate for every CLI entry (issue #49). The shell half of the pair; the work
# itself lives in studio/hugmesh_studio/core/first_run.py (symlinks into
# ~/.local/bin, a versioned ~/.hugmesh/studio/properties.json, an advisory
# doctor pass).
#
# CONTRACT
#   * first_run_bootstrap ALWAYS returns 0 — a broken bootstrap may never
#     break a launch (callers run under set -e). Everything it prints is
#     advisory and goes to STDERR (stdout belongs to the caller's machine
#     channels, e.g. --print-command).
#   * Reruns are no-ops: when ~/.hugmesh/studio/first-run.stamp records the
#     current FIRST_RUN_LIB_VERSION the gate costs one `cat` and python is
#     never started. `--redo-first-run` (or HUGMESH_REDO_FIRST_RUN=1) forces
#     a rerun.
#   * NEVER prompts, NEVER installs packages, NEVER sudo. The only writes are
#     per-user: ~/.local/bin symlinks + the state dir (both overridable:
#     $HUGMESH_BIN_DIR, $HUGMESH_STUDIO_STATE_DIR).
#
# POSIX ONLY in this file: no arrays, no [[ ]], no `local`, no bashisms — it is
# sourced by both bash entrypoints and plain-sh ones, and the repo gates
# scripts on sh-compatibility (fix/posix-and-portability).
#
# Callers:
#   scripts/studio-launch.sh     guided + --menu paths (headless stays pure)
#   scripts/build-menu.sh        direct `make menu` / ./scripts/build-menu.sh
#   scripts/hugmesh-mesh-node    the local-mesh CLI face
#
#   . "${SCRIPT_DIR}/_first-run-lib.sh"
#   first_run_bootstrap "${REPO_DIR}" "$(first_run_wants_redo "$@")"

# Must match hugmesh_studio.core.first_run.FIRST_RUN_VERSION (the python half
# writes the stamp; this constant only SHORT-CIRCUITS when already current, so
# a mismatch merely re-invokes python, which is harmless).
FIRST_RUN_LIB_VERSION=1

first_run_state_dir() {
    printf '%s' "${HUGMESH_STUDIO_STATE_DIR:-${HOME}/.hugmesh/studio}"
}

first_run_stamp_path() {
    printf '%s/first-run.stamp' "$(first_run_state_dir)"
}

first_run_properties_path() {
    printf '%s/properties.json' "$(first_run_state_dir)"
}

# 0 iff the stamp records exactly the current version (the no-op fast path).
first_run_is_current() {
    [ "$(cat "$(first_run_stamp_path)" 2>/dev/null)" = "${FIRST_RUN_LIB_VERSION}" ]
}

# Echo 1 when a rerun is forced (--redo-first-run in the given args, or
# HUGMESH_REDO_FIRST_RUN=1 in the environment), else 0. Never fails, so it is
# safe in $(...) under set -e. Callers that forward argv must STRIP the flag
# themselves (it is launcher-local, not a hugmesh_studio argument).
first_run_wants_redo() {
    for _fr_arg in "$@"; do
        if [ "${_fr_arg}" = "--redo-first-run" ]; then echo 1; return 0; fi
    done
    if [ "${HUGMESH_REDO_FIRST_RUN:-0}" = 1 ]; then echo 1; return 0; fi
    echo 0
}

# Read one top-level key out of the recorded properties.json (empty + rc 1
# when unrecorded) — so shell scripts can stop re-deriving resolved paths.
#   first_run_property builder_image
first_run_property() {
    _fr_props="$(first_run_properties_path)"
    [ -r "${_fr_props}" ] || return 1
    _fr_prop_py="$(command -v python3 2>/dev/null)" || return 1
    "${_fr_prop_py}" -c 'import json,sys
v = json.load(open(sys.argv[1])).get(sys.argv[2])
if v is None: raise SystemExit(1)
print(v)' "${_fr_props}" "$1" 2>/dev/null
}

# first_run_bootstrap REPO_DIR [REDO]
#   REPO_DIR  the generator checkout root
#   REDO      1 forces a rerun (default 0)
# Always returns 0 (see CONTRACT above).
first_run_bootstrap() {
    _fr_repo="$1"
    _fr_redo="${2:-0}"
    if [ "${_fr_redo}" != 1 ] && first_run_is_current; then
        return 0
    fi
    # Pick a python: the project-local venv first (it exists exactly when the
    # launcher bootstrapped one), then PATH. No python is NOT an error — the
    # guided launcher handles that story; we just skip with one advisory line.
    _fr_py="${_fr_repo}/studio/.venv-studio/bin/python"
    if [ ! -x "${_fr_py}" ]; then
        _fr_py="$(command -v python3 2>/dev/null)" || _fr_py=""
    fi
    if [ -z "${_fr_py}" ]; then
        echo "[first-run] python3 not found — skipped the first-run bootstrap (symlinks/properties/doctor). It reruns automatically once python3 exists, or force it with --redo-first-run." >&2
        return 0
    fi
    if [ "${_fr_redo}" = 1 ]; then
        PYTHONPATH="${_fr_repo}/studio${PYTHONPATH:+:${PYTHONPATH}}" \
            "${_fr_py}" -m hugmesh_studio.core.first_run \
            --repo "${_fr_repo}" --redo-first-run >&2 \
            || echo "[first-run] bootstrap failed (advisory only — launch continues)." >&2
    else
        PYTHONPATH="${_fr_repo}/studio${PYTHONPATH:+:${PYTHONPATH}}" \
            "${_fr_py}" -m hugmesh_studio.core.first_run \
            --repo "${_fr_repo}" >&2 \
            || echo "[first-run] bootstrap failed (advisory only — launch continues)." >&2
    fi
    return 0
}
