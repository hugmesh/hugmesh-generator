#!/usr/bin/env bash
# posix-sh-no-arrays.sh — a '#!/bin/sh' file must never use bash arrays.
#
# The incident this pins: docker/build-image.sh claimed '#!/bin/sh' (and IS run
# as `/bin/sh /builder/build-image.sh` by the admin-bff-api image-gen k8s Job)
# while carrying a bash array (IDP_EXTRA_ARGS=() / "${IDP_EXTRA_ARGS[@]}").
# That is a HARD PARSE ERROR under dash/ash/busybox sh — `busybox ash -n`
# refuses the pre-fix file at the array line — masked only because the Gentoo
# builder hosts link /bin/sh -> bash. Any base image whose /bin/sh is dash
# (debian) or ash (alpine/busybox) would kill every Job at parse time, before
# a single line ran. The fix routes the argv through `set --` positional
# params (dispatch_node_builder); this gate keeps the whole class out.
#
# Scope: every git-tracked file whose FIRST line is a sh shebang
# ('#!/bin/sh' or '#!/usr/bin/env sh', optional trailing args). Bash-shebang
# files are deliberately out of scope — arrays are fine there.
#
# Detected (outside full-line comments):
#   * array assignment            NAME=( ... )        NAME+=( ... )
#   * array element expansion     ${NAME[@]} ${NAME[*]} ${NAME[i]} ${#NAME[@]}
#   * array builtins              declare -a/-A, typeset -a/-A, mapfile, readarray
# NOT flagged (POSIX): x=$(cmd), $((arith)), case arms `x)`, f() { :; }.
#
# Pure static text checks. No network, no root. Style of
# tests/requested-atoms-resolvable.sh: PASS/FAIL per section + a detector
# SELF-TEST section (synthetic bad/good fixtures) so the detector can never
# rot into a vacuous green — a change that blinds any pattern fails here.
#
#   bash tests/posix-sh-no-arrays.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# One pattern per array construct. ERE, applied line-by-line after full-line
# comments are dropped. `=\(` cannot match `=$(` (the `$` breaks adjacency),
# so plain command substitution never trips it.
PAT_ASSIGN='(^|[^[:alnum:]_])[A-Za-z_][A-Za-z0-9_]*(\+=|=)\('
PAT_EXPAND='\$\{#?[A-Za-z_][A-Za-z0-9_]*\['
PAT_BUILTIN='(^|[[:space:];&|{(])(declare|typeset)[[:space:]]+-[aA]|(^|[[:space:];&|{(])(mapfile|readarray)([[:space:]]|$)'

# is_sh_shebang FILE — first line is a POSIX-sh shebang (not bash/zsh/...).
is_sh_shebang() {
  head -n1 -- "$1" 2>/dev/null | grep -E '^#![[:space:]]*(/bin/sh|/usr/bin/env[[:space:]]+sh)([[:space:]]|$)' >/dev/null
}

# scan_one FILE — echo offending "line:content" hits with REAL file line numbers
# (grep -n first, THEN drop full-line comments); empty output = clean.
scan_one() {
  grep -nE "${PAT_ASSIGN}|${PAT_EXPAND}|${PAT_BUILTIN}" -- "$1" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

# ── section 1: detector SELF-TEST (mutation guard — never allow a vacuous pass) ──
echo "── detector self-test: each array construct is caught, POSIX sh is not ──"
selftest="$(mktemp -d)"
trap 'rm -rf "${selftest}"' EXIT

# Every mutant re-creates one construct of the historical defect (or a sibling).
printf '%s\n' '#!/bin/sh' 'ARR=()'                                  > "${selftest}/m1-assign-empty.sh"
printf '%s\n' '#!/bin/sh' 'ARR=("--idp" "$IDP")'                    > "${selftest}/m2-assign-values.sh"
printf '%s\n' '#!/bin/sh' '[ -n "$J" ] && ARR+=("--idp-jwks" "$J")' > "${selftest}/m3-append-midline.sh"
printf '%s\n' '#!/bin/sh' 'dispatch "$@" "${ARR[@]}"'               > "${selftest}/m4-expand-at.sh"
printf '%s\n' '#!/bin/sh' 'echo "${ARR[*]}" "${ARR[1]}"'            > "${selftest}/m5-expand-star-idx.sh"
printf '%s\n' '#!/bin/sh' 'n=${#ARR[@]}'                            > "${selftest}/m6-count.sh"
printf '%s\n' '#!/bin/sh' 'declare -a ARR'                          > "${selftest}/m7-declare.sh"
printf '%s\n' '#!/bin/sh' 'readarray -t ARR < f'                    > "${selftest}/m8-readarray.sh"
for m in "${selftest}"/m*.sh; do
  if is_sh_shebang "${m}" && [ -n "$(scan_one "${m}")" ]; then
    ok "mutant caught: $(basename "${m}")"
  else
    bad "mutant NOT caught (detector is blind): $(basename "${m}")"
  fi
done

# Negative controls: legitimate POSIX sh (the idioms build-image.sh actually
# uses) must scan clean, and a bash-shebang file with arrays is out of scope.
printf '%s\n' '#!/bin/sh' \
  'x=$(date)' \
  'set -- "$@" --idp "$IDP"' \
  'case "$1" in a|b) : ;; *) : ;; esac' \
  'f() { :; }' \
  'i=$((i+1))' \
  'v="${x%/*}${y#a}"'                                    > "${selftest}/good-posix.sh"
printf '%s\n' '#!/bin/bash' 'ARR=()' 'echo "${ARR[@]}"'  > "${selftest}/good-bash-scope.sh"
if [ -z "$(scan_one "${selftest}/good-posix.sh")" ]; then
  ok "negative control: POSIX idioms (set --, \$(cmd), case, \$((..)) ) scan clean"
else
  bad "negative control: detector false-positives on plain POSIX sh: $(scan_one "${selftest}/good-posix.sh" | head -3)"
fi
if ! is_sh_shebang "${selftest}/good-bash-scope.sh"; then
  ok "negative control: '#!/bin/bash' files are out of scope"
else
  bad "negative control: shebang gate wrongly claims a bash file"
fi

# ── section 2: the repo — every tracked '#!/bin/sh' file is array-free ──────────
echo "── repo scan: git-tracked '#!/bin/sh' files carry no bash arrays ──"
scanned=0
while IFS= read -r rel; do
  f="${REPO}/${rel}"
  [ -f "${f}" ] || continue
  is_sh_shebang "${f}" || continue
  scanned=$((scanned+1))
  hits="$(scan_one "${f}")"
  if [ -z "${hits}" ]; then
    ok "${rel}"
  else
    bad "${rel}: bash array in a '#!/bin/sh' file (dash/ash parse error at /bin/sh run time):"
    printf '%s\n' "${hits}" | sed 's/^/        /'
  fi
done < <(git -C "${REPO}" ls-files)

# The worker entrypoint is the file the incident was about — if it ever stops
# being scanned (shebang change, rename, ls-files miss) this gate must say so
# rather than go green on an empty set.
if [ "${scanned}" -ge 1 ] && is_sh_shebang "${REPO}/docker/build-image.sh"; then
  ok "scan set is non-empty and includes docker/build-image.sh (${scanned} files)"
else
  bad "scan set lost docker/build-image.sh — gate would be vacuous (scanned=${scanned})"
fi

echo
if [ "${F}" -eq 0 ]; then
  echo "posix-sh-no-arrays: ALL PASS (${P})"
else
  echo "posix-sh-no-arrays: ${F} FAILURE(S)"
  exit 1
fi
