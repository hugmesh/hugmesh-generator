#!/usr/bin/env bash
# test-spec-use-parity.sh — cross-platform USE/package.use parity guards.
#
# Both bugs this pins were ONE TOKEN missing from ONE platform's spec while every
# sibling platform had it, and both were invisible until a multi-hour build ended
# with no artifact:
#
#   1. specs-rpi5 disabled `introspection` but NOT `vala`. librsvg enforces
#      `vala? ( introspection )`, so the constraint was unsatisfiable and the
#      2026-07-19 rpi5-desktop build skipped 47 of 64 packages (xorg-server,
#      openbox, lightdm, openssh, sudo, cryptsetup, lvm2, audit, selinux-base, …)
#      and emitted NOTHING. jetson/frite/orangepi5/orangepi-zero2 all had `-vala`.
#
#   2. specs-jetson forced `net-misc/networkmanager wifi` but never pre-seeded
#      `net-wireless/wpa_supplicant dbus` (NM drives wpa_supplicant over D-Bus and
#      dbus is not a default USE). NetworkManager could never merge, so ALL FOUR
#      Jetson roles failed the payload assert with zero artifacts. rpi5 and x86
#      both carried the pre-seed already.
#
# The shared shape: a REQUIRED_USE / forced-USE obligation satisfied on n-1
# platforms. So these assertions are DERIVED from the specs themselves — the rule
# is "if you disable X you must also disable Y" and "if you force X you must
# pre-seed Y", checked per platform, not a hardcoded list of known-good files.
#
# Static only: no emerge, no chroot, no network, no root.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== cross-platform spec USE parity =="

# Every platform spec dir that exists, discovered — a new board added tomorrow is
# covered automatically instead of silently exempt.
PLATFORMS=()
for d in "${REPO}"/specs-*/; do
  [ -f "${d}portage/make.conf.tmpl" ] || continue
  PLATFORMS+=("$(basename "${d}" | sed 's/^specs-//')")
done
[ "${#PLATFORMS[@]}" -gt 0 ] \
  && ok "discovered ${#PLATFORMS[@]} platform spec(s): ${PLATFORMS[*]}" \
  || bad "no platform specs found under ${REPO}/specs-*/"

echo "-- 1) -introspection implies -vala (librsvg REQUIRED_USE: vala? ( introspection )) --"
for p in "${PLATFORMS[@]}"; do
  mk="${REPO}/specs-${p}/portage/make.conf.tmpl"
  # Only USE= assignment lines count; these templates discuss both flags in prose.
  uselines="$(grep -E '^USE=' "${mk}" 2>/dev/null || true)"
  case "${uselines}" in
    *-introspection*)
      case "${uselines}" in
        *-vala*) ok "${p}: disables introspection AND vala" ;;
        *)       bad "${p}: disables introspection but NOT vala — librsvg's 'vala? ( introspection )' is then UNSATISFIABLE and every gtk-chain package cascades to skipped" ;;
      esac ;;
    *) ok "${p}: introspection not disabled — the vala constraint does not apply" ;;
  esac
done

echo "-- 2) networkmanager[wifi] implies a wpa_supplicant[dbus] pre-seed --"
# package.use lines are "<atom> <flag> [<flag>…]", so parse them as FIELDS rather
# than regex-matching the whole line: an enabled flag is a bare word, a disabled
# one is prefixed with '-', and prose about the flag lives in '#' comment lines.
# (A substring/regex form of this check silently passed on the very spec it was
# written to catch — fields are what the file actually means.)
flag_enabled() { # <package.use dir> <atom> <flag>  -> 0 iff enabled
  awk -v atom="$2" -v want="$3" '
    /^[[:space:]]*#/ { next }
    $1 == atom { for (i = 2; i <= NF; i++) if ($i == want) { found = 1 } }
    END { exit(found ? 0 : 1) }' $(find "$1" -maxdepth 1 -type f 2>/dev/null) 2>/dev/null
}
for p in "${PLATFORMS[@]}"; do
  pud="${REPO}/specs-${p}/portage/package.use"
  [ -d "${pud}" ] || { ok "${p}: no package.use dir — nothing forces wifi"; continue; }
  if flag_enabled "${pud}" "net-misc/networkmanager" "wifi"; then
    # The obligation is that wpa_supplicant ENDS UP with dbus — satisfied either
    # by a global USE=dbus (frite/orangepi5/orangepi-zero2 take this route) or by
    # a per-package pre-seed (jetson/rpi5, which have no global dbus). Demanding
    # the pre-seed unconditionally would flag three specs that are already
    # correct — verified: those three carry `dbus` in make.conf.tmpl's USE.
    if grep -hE '^USE=' "${REPO}/specs-${p}/portage/make.conf.tmpl" 2>/dev/null \
         | tr ' "' '\n\n' | grep -qx 'dbus'; then
      ok "${p}: forces networkmanager[wifi]; global USE=dbus already covers wpa_supplicant"
    elif flag_enabled "${pud}" "net-wireless/wpa_supplicant" "dbus"; then
      ok "${p}: forces networkmanager[wifi] and pre-seeds wpa_supplicant[dbus] (no global dbus)"
    else
      bad "${p}: forces networkmanager[wifi] but wpa_supplicant gets dbus from NEITHER a global USE NOR a pre-seed — NetworkManager cannot merge and the payload assert fails with zero artifacts"
    fi
  else
    ok "${p}: does not force networkmanager[wifi] — no pre-seed obligation"
  fi
done

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
