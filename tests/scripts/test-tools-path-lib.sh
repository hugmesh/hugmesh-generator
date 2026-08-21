#!/usr/bin/env bash
# test-tools-path-lib.sh — scripts/_tools-path-lib.sh.
#
# The lib exists because `make kind-up` from a terminal died with
#     missing required tool: kind
# on a box where kind was installed — the Studio pins it under
# ~/.local/share/hugmesh-studio/tools/bin and puts that on PATH for its own
# children only. The message reads as "not installed" and sends the reader to
# install a second copy at a different version.
#
# FULLY HERMETIC. Every case builds its own fake tools dir and drives the lib with
# HUGMESH_TOOLS_BIN, so this asserts the same thing on a CI runner with no Studio
# installed as on the operator's workstation. A test that only passed where the
# Studio happens to exist would be testing the machine, not the lib.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
LIB="${REPO}/scripts/_tools-path-lib.sh"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

[ -f "${LIB}" ] || { echo "  FAIL missing ${LIB}"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/toolspath.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/studio" "${TMP}/system" "${TMP}/empty-parent"
printf '#!/bin/sh\necho studio-copy\n' > "${TMP}/studio/faketool"
printf '#!/bin/sh\necho system-copy\n' > "${TMP}/system/faketool"
chmod +x "${TMP}/studio/faketool" "${TMP}/system/faketool"

# 1) the whole point: a tool that exists ONLY in the studio dir becomes findable.
out="$(HUGMESH_TOOLS_BIN="${TMP}/studio" PATH="/usr/bin:/bin" \
       bash -c '. "$1"; hugmesh_tools_path; command -v faketool' _ "${LIB}" 2>&1)"
case "${out}" in
  "${TMP}/studio/faketool") ok "a studio-only tool is on PATH after hugmesh_tools_path" ;;
  *) bad "studio-only tool not found (got: ${out:-<nothing>})" ;;
esac

# 2) APPEND, not prepend: an operator's own copy earlier in PATH must still win.
#    Prepending would silently override a deliberate system install with whatever
#    version the Studio pinned — a worse failure than the one this lib fixes,
#    because nothing would report it.
out="$(HUGMESH_TOOLS_BIN="${TMP}/studio" PATH="${TMP}/system:/usr/bin:/bin" \
       bash -c '. "$1"; hugmesh_tools_path; faketool' _ "${LIB}" 2>&1)"
[ "${out}" = "system-copy" ] \
  && ok "a system copy earlier in PATH still wins (the lib appends, never prepends)" \
  || bad "the studio copy shadowed the system one — got '${out}', wanted 'system-copy'"

# 3) idempotent: re-sourcing must not grow PATH. A lib that appends on every call
#    turns a long-lived shell's PATH into a repeating list.
out="$(HUGMESH_TOOLS_BIN="${TMP}/studio" PATH="/usr/bin:/bin" \
       bash -c '. "$1"; hugmesh_tools_path; hugmesh_tools_path; hugmesh_tools_path
                printf "%s" "$PATH" | tr ":" "\n" | grep -c "^$2\$"' _ "${LIB}" "${TMP}/studio" 2>&1)"
[ "${out}" = "1" ] \
  && ok "three calls add the directory exactly once (idempotent)" \
  || bad "PATH gained the tools dir ${out} time(s), expected 1"

# 4) a machine with no studio install is left completely alone.
out="$(HUGMESH_TOOLS_BIN="${TMP}/empty-parent/does-not-exist" PATH="/usr/bin:/bin" \
       bash -c '. "$1"; hugmesh_tools_path; printf "%s" "$PATH"' _ "${LIB}" 2>&1)"
[ "${out}" = "/usr/bin:/bin" ] \
  && ok "a non-existent tools dir leaves PATH untouched" \
  || bad "PATH was modified for a missing tools dir: ${out}"

# 5) the two callers must actually SOURCE it — the lib helps nobody unsourced, and
#    this is exactly the shape guard-integrity case (h) exists to catch elsewhere.
for c in scripts/kind-load-images.sh specs/cluster/bootstrap/kind-local/bootstrap-kind.sh; do
  if grep -q '_tools-path-lib.sh' "${REPO}/${c}" && grep -q 'hugmesh_tools_path' "${REPO}/${c}"; then
    ok "${c} sources the lib and calls hugmesh_tools_path"
  else
    bad "${c} requires kind but never calls hugmesh_tools_path"
  fi
done

echo
echo "== tools-path lib: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
