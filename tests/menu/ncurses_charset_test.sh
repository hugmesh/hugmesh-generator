#!/usr/bin/env bash
# ncurses_charset_test.sh — unit checks for scripts/build-menu.sh's non-UTF-8 glyph
# transliteration (_u / _u_items). Sources the menu script (its execute-guard keeps
# it non-interactive when sourced), then drives _u/_u_items directly with UTF8 forced
# both ways. Needs NO TTY, NO whiptail, runs in milliseconds — safe for CI.
#
#   bash tests/menu/ncurses_charset_test.sh
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/../.." && pwd)"

SNAP_MENU_STATE="$(mktemp -d)"; export SNAP_MENU_STATE
trap 'rm -rf "${SNAP_MENU_STATE}"' EXIT
export NO_TUI=1

# shellcheck disable=SC1091
source "${REPO_DIR}/scripts/build-menu.sh"

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); }
_bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n  got: %q\n  want: %q\n' "$1" "${2:-}" "${3:-}" >&2; }
eq()   { if [ "$2" = "$3" ]; then _ok; else _bad "$1" "$2" "$3"; fi; }

# A string exercising every glyph the menu labels use.
RICH='top ── star ★ dash — en – ellip … ‹back› arrow → box ═ ║ ╔╗╚╝ bullet ● play ▶ gear ⚙ “q” ‘r’'

# 1) UTF-8 locale: pass through byte-for-byte.
UTF8=1
eq "utf8-passthrough" "$(_u "${RICH}")" "${RICH}"

# 2) non-UTF-8: every glyph folded to ASCII → result must be pure 7-bit ASCII.
UTF8=0
out="$(_u "${RICH}")"
if printf '%s' "${out}" | LC_ALL=C grep -qP '[^\x00-\x7F]'; then
    _bad "non-utf8-all-ascii (residual non-ASCII)" "${out}" "<pure ASCII>"
else
    _ok
fi
# spot-check specific mappings
eq "dash"    "$(_u '— x')"      "- x"
eq "star"    "$(_u '★ standalone')" "* standalone"
eq "ellipsis" "$(_u 'done…')"   "done..."
eq "guillemet" "$(_u '‹ back')" "< back"
eq "arrow"   "$(_u 'a → b')"    "a -> b"
eq "box"     "$(_u '══─║')"     "==-|"

# 3) _u_items transliterates ONLY labels, never tags (return values).
UTF8=0
_U_STRIDE=2 _u_items "tag—A" "label — ★" "tagB" "plain"
eq "items-tag-untouched"   "${_U_OUT[0]}" "tag—A"      # tag keeps its bytes (it's a return value)
eq "items-label-folded"    "${_U_OUT[1]}" "label - *"
eq "items-tag2-untouched"  "${_U_OUT[2]}" "tagB"
eq "items-label2-plain"    "${_U_OUT[3]}" "plain"

# checklist stride: (tag,label,state) — only the label (index%3==1) folds.
_U_STRIDE=3 _u_items "t1" "lbl — x" "on" "t2" "y" "off"
eq "checklist-label-folded" "${_U_OUT[1]}" "lbl - x"
eq "checklist-state-kept"   "${_U_OUT[2]}" "on"

# 4) anti-revert: the ui_* choke points must call _u.
for fn in ui_menu ui_checklist ui_yesno ui_input ui_password ui_msg; do
    body="$(declare -f "${fn}")"
    case "${body}" in *'_u '*|*'_u_items'*) _ok ;; *) _bad "${fn} does not call _u" "" "" ;; esac
done

printf '\nncurses_charset_test: %d passed, %d failed\n' "${PASS}" "${FAIL}" >&2
[ "${FAIL}" -eq 0 ] || exit 1
