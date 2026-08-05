#!/usr/bin/env bash
# requested-atoms-resolvable.sh — a GLOBAL USE mask in a platform spec must never
# silently make a REQUESTED atom unresolvable.
#
# The incident this pins: the 2026-07-30 21:04 mesh build died on all three rpi5
# roles at hour N of a real build —
#   emerge: there are no ebuilds built with USE flags to satisfy
#   ">=dev-libs/glib-2.82.0:2[introspection]" for /out/wl-pki.rpi5/sysroot/.
# because specs-rpi5/portage/make.conf.tmpl's global USE="-introspection"
# (added for a real cross-compile failure, see that file) contradicted a hard
# dependency chain of a REQUESTED atom:
#   net-firewall/firewalld -> dev-python/pygobject:3
#     -> dev-libs/gobject-introspection -> dev-libs/glib[introspection]
# The requested-atom completeness gate then (correctly) refused the images —
# but only AFTER hours of compile. This gate moves that discovery to gate time.
# The fix is the scoped specs-rpi5/portage/package.use/firewalld-introspection
# override; this test fails the moment the override is dropped while the wall
# stands, on ANY platform that requests the atom (the table is walked against
# all ten specs, so a future platform adding firewalld under -introspection
# fails here too).
#
# WHY STATIC, not host-side resolution (the design call, made explicitly): a
# REAL resolution proof needs app-portage tooling on the gate host, the same
# /var/db/repos/gentoo snapshot the builders bind-mount, and minutes of
# fresh-root depgraph CPU per platform — the CI verify jobs run in python:3
# containers with none of those, and this gate must be cheap enough to run on
# every branch. So gate time proves a CURATED chain table statically (packages
# lists x known hard USE-dep chains x package.use overrides), and the deep
# proof — real `emerge --pretend` closure on the actual failed sysroots,
# baseline error verbatim + fixed rc=0 with zero new walls — is recorded in the
# fix branch's FINDINGS.md (fix/arm-firewalld-installable). The price of
# static: only KNOWN chains are caught. Grow CHAINS below with each incident;
# the completeness gate (scripts/_payload-gate-lib.sh) remains the runtime
# backstop for the unknown ones.
#
# Pure static text checks. No emerge, no chroot, no network, no root.
#
#   bash tests/requested-atoms-resolvable.sh   # or via: make matrix-check
#   (wired as the RAR bucket of tests/build-matrix/check.sh)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# Every platform spec dir (specs/ itself is the shared rootfs overlay, not a
# platform). Keep in lockstep with the builder set in tests/build-arm-payload-gates.sh.
PLATFORMS=(rpi5 frite jetson orangepi-zero2 orangepi-zero2w orangepi-zero3
           orangepi3-lts orangepi4-lts orangepi5 x86)

# The curated hard-chain table: requested-atom|prerequisite-pkg|prerequisite-flag|chain.
# An entry means: "REQUESTED-ATOM is unresolvable unless PREREQUISITE-PKG has
# PREREQUISITE-FLAG enabled" — an unconditional USE dep somewhere in the atom's
# dependency chain, verified against the real tree when the entry was added.
CHAINS=(
  "net-firewall/firewalld|dev-libs/glib|introspection|firewalld -> pygobject:3 -> gobject-introspection -> glib[introspection] (unconditional at EVERY firewalld version in the tree — it is a python daemon)"
)

# Final state of <flag> across a spec's accumulated global USE= lines
# (make.conf.tmpl appends via USE="${USE} ...", last token wins; @@TOKENS@@ are
# build-time role extras and never carry the flags in CHAINS). Echoes +, - or "".
global_flag_state() { # <specdir> <flag>
  local mk="$1/portage/make.conf.tmpl" state="" tok
  [ -f "${mk}" ] || { echo "MISSING"; return 0; }
  while read -r tok; do
    case "${tok}" in
      "$2")  state="+" ;;
      "-$2") state="-" ;;
    esac
  done < <(grep -E '^[[:space:]]*USE=' "${mk}" | tr '"' ' ' | tr ' ' '\n')
  echo "${state}"
}

# Is <atom> requested by any of the spec's packages*.list?
is_requested() { # <specdir> <atom>
  local f
  for f in "$1"/portage/packages*.list; do
    [ -f "${f}" ] || continue
    grep -qE "^[[:space:]]*$2[[:space:]]*$" "${f}" && return 0
  done
  return 1
}

# Final state of <flag> for <pkg> across the spec's package.use (portage reads
# the dir's files in sorted order; later files and later tokens win). Echoes
# "+ <file>", "- <file>" or "".
pkguse_flag_state() { # <specdir> <pkg> <flag>
  local pu="$1/portage/package.use" state="" statefile="" f line tok first
  local files=()
  if [ -d "${pu}" ]; then
    while IFS= read -r f; do files+=("${f}"); done < <(find "${pu}" -maxdepth 1 -type f | sort)
  elif [ -f "${pu}" ]; then
    files=("${pu}")
  fi
  for f in "${files[@]}"; do
    while IFS= read -r line; do
      line="${line%%#*}"
      [ -z "${line//[[:space:]]/}" ] && continue
      read -r first _ <<<"${line}"
      # normalize the atom: strip version operators, any -<version> tail, any :slot
      first="${first#"${first%%[!<>=~]*}"}"   # leading < > = ~
      first="${first%%:*}"
      first="$(echo "${first}" | sed -E 's/-[0-9][0-9a-z._-]*(\*)?$//')"
      [ "${first}" = "$2" ] || continue
      for tok in ${line#* }; do
        case "${tok}" in
          "$3")  state="+"; statefile="${f##*/}" ;;
          "-$3") state="-"; statefile="${f##*/}" ;;
        esac
      done
    done < "${f}"
  done
  [ -n "${state}" ] && echo "${state} ${statefile}" || echo ""
}

echo "== requested-atoms-resolvable (global USE mask vs requested-atom hard chains) =="

echo "-- A) chain table x every platform --"
for plat in "${PLATFORMS[@]}"; do
  sd="${REPO}/specs-${plat}"
  for entry in "${CHAINS[@]}"; do
    IFS='|' read -r atom pkg flag chain <<<"${entry}"
    gstate="$(global_flag_state "${sd}" "${flag}")"
    if [ "${gstate}" = "MISSING" ]; then
      bad "[${plat}] specs-${plat}/portage/make.conf.tmpl MISSING — cannot prove ${atom} resolvable"
      continue
    fi
    if ! is_requested "${sd}" "${atom}"; then
      ok "[${plat}] ${atom} not requested — chain N/A"
      continue
    fi
    if [ "${gstate}" != "-" ]; then
      ok "[${plat}] ${atom} requested; no global -${flag} wall in make.conf.tmpl"
      continue
    fi
    pstate="$(pkguse_flag_state "${sd}" "${pkg}" "${flag}")"
    case "${pstate}" in
      "+ "*)
        ok "[${plat}] ${atom} requested + global -${flag} wall + scoped '${pkg} ${flag}' override present (package.use/${pstate#+ })" ;;
      *)
        bad "[${plat}] requested atom ${atom} is UNRESOLVABLE: global USE=-${flag} (make.conf.tmpl) with no scoped package.use '${pkg} ${flag}' override — chain: ${chain}. Either restore the scoped override or make a LOUD per-platform exclusion (drop the atom from the list AND update this gate — paper trail required, never a silent skip)." ;;
    esac
  done
done

echo "-- B) the live instance is pinned (rpi5 firewalld) --"
RPI5="${REPO}/specs-rpi5"
if is_requested "${RPI5}" "net-firewall/firewalld"; then
  ok "specs-rpi5 packages.list still requests net-firewall/firewalld (dropping it silently is the exact hole that shipped firewalld-less rpi5 images — a deliberate exclusion must update this gate too)"
else
  bad "net-firewall/firewalld is GONE from specs-rpi5 packages lists — if this is a deliberate per-platform exclusion it must be loud: builder comment + this gate updated; if not, the silently-shipped-firewalld-less-image hole is back"
fi
OVR="${RPI5}/portage/package.use/firewalld-introspection"
if [ -f "${OVR}" ] && grep -qE '^dev-libs/glib[[:space:]]+introspection[[:space:]]*$' "${OVR}"; then
  ok "package.use/firewalld-introspection carries the uncommented 'dev-libs/glib introspection' line"
else
  bad "specs-rpi5/portage/package.use/firewalld-introspection missing or its 'dev-libs/glib introspection' line is gone/commented — firewalld resolution is walled again"
fi
if grep -qF 'cp "${SPECS_DIR}/portage/package.use/"*' "${REPO}/build-rpi5-stage4.sh"; then
  ok "build-rpi5-stage4.sh still copies portage/package.use/* verbatim into the sysroot (the override actually reaches the resolver)"
else
  bad "build-rpi5-stage4.sh no longer copies portage/package.use/* into the sysroot — the scoped override never reaches the resolver (vacuous-pass hazard)"
fi
if grep -q 'package.use/firewalld-introspection' "${RPI5}/portage/make.conf.tmpl"; then
  ok "make.conf.tmpl's -introspection comment cross-references the scoped exception (a reader of the wall learns about the door)"
else
  bad "make.conf.tmpl's -introspection block lost the cross-reference to package.use/firewalld-introspection — the wall reads as absolute again"
fi

echo "-- C) the runtime backstop this gate's compile-side bet relies on --"
# The scoped override bets that glib[introspection] now COMPILES cross (see the
# override file's header). If that bet loses, the loud failure is the
# completeness gate — so its arming is part of THIS gate's contract.
if grep -q 'source "${SCRIPT_DIR}/scripts/_payload-gate-lib.sh"' "${REPO}/build-rpi5-stage4.sh"; then
  ok "build-rpi5-stage4.sh sources scripts/_payload-gate-lib.sh (completeness gate armed)"
else
  bad "build-rpi5-stage4.sh no longer sources _payload-gate-lib.sh — the compile-side bet has no runtime backstop"
fi
if grep -q '^ALLOW_MISSING_PACKAGES=false' "${REPO}/build-rpi5-stage4.sh"; then
  ok "completeness gate defaults to FAILING on a degraded image (ALLOW_MISSING_PACKAGES=false)"
else
  bad "ALLOW_MISSING_PACKAGES no longer defaults to false — a firewalld-less image could ship again"
fi

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
