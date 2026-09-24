#!/usr/bin/env bash
# test-studio-tor-domain-pins.sh — run the Studio's Tor / per-domain pytest pins as ONE
# suite with ONE verdict (hugmesh-generator#591).
#
# WHY. Every Tor and per-domain pin in the Studio is a pytest file — the with_tor ->
# TOR=1 threading, the package preview's net-vpn/tor, the saved-mesh -> node-image
# bridge (#579), the stale-onion refusal (#581), the per-domain services scope — and
# on 2026-09-23 none of them ran before a merge on this account: the local lane ran
# three Studio files, and GitHub Actions dies on a billing annotation here. A
# regression in any of them merged green. This wrapper is the one command that runs
# them all, on the box that has the Studio venv, and fails when any of them fails.
#
# WHAT IT RUNS. The named files below — explicit names for the Tor/saved-mesh pins,
# and the two per-domain FAMILIES by glob (test_domain_services*.py,
# test_pages_domains_*.py), because another lane adds files to them. Every name and
# every glob must match at least one file, or the suite is RED: a renamed pin file
# must not silently drop out of the only place it runs.
#
# THE INTERPRETER, in this order:
#   $HUGMESH_STUDIO_PYTHON            explicit (the CI step sets it; so can you)
#   <repo>/studio/.venv/bin/python    the documented dev venv
#   $SNAP_STUDIO_PYTHON               the e2e Studio lane's knob, honoured here too
# It must import pytest. None found -> SKIPPED-LOUDLY, exit 2 (NEVER 0: a suite that
# ran nothing must not read as a pass).
#
# QT. The GUI pins (the localcloud gate, the saved-meshes widget, the Domains pages)
# build the REAL PyQt/PySide wizard offscreen, and `pytest.importorskip` them without
# a binding — so on a Qt-less interpreter half of this set SKIPS and pytest still
# exits 0. That is not allowed to read as green:
#   * interpreter HAS a Qt binding  -> ZERO skips are allowed (measured 2026-09-23:
#                                      379 passed, 0 skipped); any skip is RED.
#   * interpreter has NO Qt binding -> SKIPPED-LOUDLY exit 2, unless
#                                      HUGMESH_PINS_ALLOW_NO_QT=1 — set ONLY by the
#                                      Qt-free GitHub job, where the Qt-free half is
#                                      still a real gate and the skip count is printed.
#
# SAFETY. Studio tests have spawned REAL `sudo -A` build launchers that wedge on the
# askpass dialog (60 found once, 0 authenticated). So: HUGMESH_STUDIO_NO_ELEVATION=1,
# QT_QPA_PLATFORM=offscreen, and DISPLAY/WAYLAND_DISPLAY/XDG_SESSION_TYPE unset so the
# askpass helper cannot open an invisible dialog. -p no:cacheprovider keeps the tree
# clean. No stack, no docker, no network, no root.
#
# EXIT: 0 green | 1 a pin failed / the file set drifted / a skip where none may be |
#       2 SKIPPED-LOUDLY (no usable interpreter, or no Qt without the CI opt-in).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
STUDIO="${REPO}/studio"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
skipped_loudly(){ echo "  SKIPPED-LOUDLY $* — checked NOTHING"; exit 2; }

echo "== Studio Tor / per-domain pytest pins (#591) =="

# ── the file set: explicit names + the two per-domain families ─────────────────
NAMED=(
  tests/test_local_mesh_tor.py
  tests/test_package_catalog.py
  tests/test_localcloud_nodes.py
  tests/test_tui_localcloud.py
  tests/test_saved_meshes.py
  tests/test_localmesh_saved_meshes.py
  tests/test_local_mesh_bootstrap_config_roundtrip.py
  tests/test_worklist_infra_services.py
  tests/test_worklist_tor_fold.py
  tests/test_fleet_tor.py
  tests/test_tui_domain_services.py
)
FAMILIES=(
  "tests/test_domain_services*.py"
  "tests/test_pages_domains_*.py"
)
FILES=()
for f in "${NAMED[@]}"; do
  if [ -f "${STUDIO}/${f}" ]; then FILES+=("${f}"); else bad "named pin file is gone: studio/${f}"; fi
done
for g in "${FAMILIES[@]}"; do
  n=0
  for f in "${STUDIO}"/${g}; do
    [ -f "${f}" ] || continue
    FILES+=("tests/$(basename "${f}")"); n=$((n+1))
  done
  if [ "${n}" -gt 0 ]; then ok "family studio/${g} matched ${n} file(s)"
  else bad "family studio/${g} matched NOTHING — the per-domain pins are no longer here"; fi
done
if [ "${F}" -gt 0 ]; then
  echo "== studio tor/domain pins: ${P} passed, ${F} failed (the file set drifted) =="
  exit 1
fi
ok "${#FILES[@]} pin files resolved (${#NAMED[@]} named + the domain families)"

# ── the interpreter ─────────────────────────────────────────────────────────────
PY=""
for cand in "${HUGMESH_STUDIO_PYTHON:-}" "${STUDIO}/.venv/bin/python" "${SNAP_STUDIO_PYTHON:-}"; do
  [ -n "${cand}" ] || continue
  if command -v "${cand}" >/dev/null 2>&1 \
     && (cd "${STUDIO}" && "${cand}" -c 'import pytest' >/dev/null 2>&1); then
    PY="${cand}"; break
  fi
done
[ -n "${PY}" ] || skipped_loudly "no Studio interpreter with pytest (set HUGMESH_STUDIO_PYTHON, or create studio/.venv)"
ok "interpreter: ${PY}"

STRICT_QT=1
if (cd "${STUDIO}" && env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen \
      "${PY}" -c 'import hugmesh_studio.gui.qt' >/dev/null 2>&1); then
  ok "a Qt binding imports — the GUI pins run, and NO skip is allowed"
elif [ "${HUGMESH_PINS_ALLOW_NO_QT:-0}" = "1" ]; then
  STRICT_QT=0
  echo "  NOTE no Qt binding: HUGMESH_PINS_ALLOW_NO_QT=1, so only the Qt-free pins gate this run"
else
  skipped_loudly "no Qt binding for ${PY} (the GUI pins would skip; HUGMESH_PINS_ALLOW_NO_QT=1 accepts a Qt-free run)"
fi

# ── the run ─────────────────────────────────────────────────────────────────────
LOG="$(mktemp "${TMPDIR:-/tmp}/studio-pins.XXXXXX")"
trap 'rm -f "${LOG}"' EXIT
(cd "${STUDIO}" && env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE \
    QT_QPA_PLATFORM=offscreen HUGMESH_STUDIO_NO_ELEVATION=1 PYTHONDONTWRITEBYTECODE=1 \
    "${PY}" -m pytest -q -p no:cacheprovider -rs "${FILES[@]}") >"${LOG}" 2>&1
rc=$?
tail -n 25 "${LOG}" | sed 's/^/    | /'

summary="$(grep -aE '^(=+ )?[0-9]+ (passed|failed|error|skipped)' "${LOG}" | tail -n 1)"
passed="$(sed -n 's/.*\b\([0-9][0-9]*\) passed.*/\1/p' <<<"${summary}")"
skips="$(sed -n 's/.*\b\([0-9][0-9]*\) skipped.*/\1/p' <<<"${summary}")"
passed="${passed:-0}"; skips="${skips:-0}"

case "${rc}" in
  0) ok "pytest exited 0 (${passed} passed, ${skips} skipped)" ;;
  5) bad "pytest collected NOTHING (exit 5) — a pin set that runs no test is not a pass" ;;
  *) bad "pytest exited ${rc} — a Tor / per-domain pin is red (log tail above)" ;;
esac
if [ "${rc}" -eq 0 ] && [ "${passed}" -eq 0 ]; then
  bad "0 tests passed — refusing a vacuous green"
fi
if [ "${STRICT_QT}" = "1" ] && [ "${skips}" -gt 0 ]; then
  bad "${skips} test(s) SKIPPED with a Qt binding present — every pin here must run (see -rs above)"
elif [ "${STRICT_QT}" = "0" ] && [ "${skips}" -gt 0 ]; then
  echo "  NOTE ${skips} Qt-bound test(s) skipped on this Qt-free interpreter — run locally with the venv for the full set"
fi

echo "== studio tor/domain pins: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
exit $?
