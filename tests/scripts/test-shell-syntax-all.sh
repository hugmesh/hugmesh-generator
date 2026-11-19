#!/usr/bin/env bash
# test-shell-syntax-all.sh — every tracked shell script parses (`bash -n`).
#
# hugmesh-generator#946: two pull requests that are each green alone can merge into a
# script that no longer parses. One afternoon left scripts/launch-arm.sh with an unclosed
# `if` and a duplicated drive block, and nothing ran it, so main stayed "green". A suite
# that EXECUTES a script catches that only if some lane runs that suite; this one parses
# every script in the tree in a few seconds, so a broken merge is red on its first run on
# main (shell-suites.yml runs on every push to main).
#
# WHICH FILES: every file git tracks that ends in .sh, plus every tracked file whose
# first line is a bash or sh shebang. Files under node_modules/ and third-party vendor
# trees are git-ignored, so they are not seen. A script that is not meant to parse on
# its own is listed in NOT_STANDALONE with the reason.
#
# Negative controls at the bottom build throw-away git repos: an unclosed `if` (the
# #946 collision, replayed), a missing `fi` in a shebang-only file, and a clean file.
set -uo pipefail

ROOT="${SYNTAX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
NOT_STANDALONE=(
)

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }

# shell_files <repo> — NUL-separated list of tracked shell scripts.
shell_files() {
  git -C "$1" ls-files -z | while IFS= read -r -d '' f; do
    [ -f "$1/$f" ] || continue
    case "$f" in
      *.sh) printf '%s\0' "$f"; continue ;;
    esac
    local first=""
    IFS= read -r first < "$1/$f" 2>/dev/null || true
    [[ "${first}" =~ ^\#\!\ *(/usr)?/bin/(env\ +)?(ba)?sh(\ |$) ]] && printf '%s\0' "$f"
  done
}

# check_tree <repo> — prints one line per script that does not parse; rc 0 always.
check_tree() {
  local f err
  while IFS= read -r -d '' f; do
    local skip=""
    for s in "${NOT_STANDALONE[@]}"; do [ "$f" = "$s" ] && skip=1; done
    [ -n "${skip}" ] && continue
    if ! err="$(bash -n "$1/$f" 2>&1)"; then
      printf '%s: %s\n' "$f" "$(printf '%s' "${err}" | head -n 2 | tr '\n' ' ')"
    fi
  done < <(shell_files "$1")
}

echo "== every tracked shell script parses"
if ! git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
  bad "${ROOT} is not a git checkout; nothing can be listed"
else
  n="$(shell_files "${ROOT}" | tr -cd '\0' | wc -c)"
  if [ "${n}" -lt 100 ]; then
    bad "only ${n} shell scripts found — the listing is broken, not the tree"
  fi
  broken="$(check_tree "${ROOT}")"
  if [ -z "${broken}" ]; then ok "${n} scripts parse with bash -n"
  else
    bad "script(s) that do not parse (a merge may have joined two edits badly):"
    printf '%s\n' "${broken}" | sed 's/^/         /'
  fi
  for s in "${NOT_STANDALONE[@]}"; do
    [ -e "${ROOT}/${s}" ] || bad "NOT_STANDALONE names ${s}, which does not exist"
  done
fi

echo "== negative controls"
T="$(mktemp -d "${TMPDIR:-/tmp}/shell-syntax.XXXXXX")"; trap 'rm -rf "${T}"' EXIT
git -C "${T}" init -q
printf '#!/usr/bin/env bash\nif [ -n "$1" ]; then\n  echo one\nfi\n' > "${T}/clean.sh"
# the #946 shape: two edits each closed the `if`, the merge kept one opener twice
printf '#!/usr/bin/env bash\nif [ -n "$1" ]; then\n  QEMU_ARGS+=(-kernel k)\nif [ -n "$2" ]; then\n  QEMU_ARGS+=(-kernel k)\nfi\n' > "${T}/launch-arm.sh"
printf '#!/bin/sh\ncase "$1" in\n  a) echo a ;;\n' > "${T}/no-extension"
printf 'just text, not a script\n' > "${T}/README"
git -C "${T}" add -A
out="$(check_tree "${T}")"
if printf '%s\n' "${out}" | grep -F "launch-arm.sh:" >/dev/null; then
  ok "fires: an unclosed if left by a merge (the #946 collision, replayed)"
else bad "did not fire on an unclosed if: ${out}"; fi
if printf '%s\n' "${out}" | grep -F "no-extension:" >/dev/null; then
  ok "fires: a shebang script without the .sh extension"
else bad "did not fire on a shebang-only script: ${out}"; fi
if printf '%s\n' "${out}" | grep -E "^(clean\.sh|README):" >/dev/null; then
  bad "fired on a clean script or a non-script: ${out}"
else ok "quiet: a clean script and a text file"; fi
printf 'untracked\nif\n' > "${T}/untracked.sh"
if check_tree "${T}" | grep -F "untracked.sh" >/dev/null; then
  bad "read an untracked file (only what git tracks is the tree)"
else ok "quiet: an untracked file"; fi

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
