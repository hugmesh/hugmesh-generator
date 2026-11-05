#!/usr/bin/env bash
# ── ARM desktop package sets: the governance runtime is DECLARED, not inherited ──
# Every ARM desktop image (rpi5 --role desktop, jetson --role desktop, frite
# --desktop light, orangepi5, orangepi4-lts) runs the SAME lightdm + LXDE-lite
# session as the x86 client, and the SAME keys-provision engine renders the
# desktop-governance `desktop-sudo` gate on any of them that carries the
# templates. The x86 client list declares the two runtimes behind that gate
# (sys-auth/polkit, dev-lang/python — specs-x86/portage/packages-desktop.list,
# pinned by tests/desktop-governance/test-provision-desktop-governance.sh case
# 17). The five ARM lists declared neither: polkit arrived only as
# lxde-base/lxsession's COMMON_DEPEND, so a session-manager swap would have
# silently removed the governed image's sole sudo path, and nothing stated that
# python is a runtime contract rather than portage's own dependency.
#
# Three more things this pins, each a real way for the declaration to be inert:
#
#   * polkit[elogind]. The polkit ebuild falls back to ConsoleKit session
#     tracking unless USE=elogind is on; ConsoleKit is never installed, so a
#     polkit built that way sees no local/active session and can authorize
#     nobody. rpi5/frite/orangepi get elogind globally; jetson's hardened
#     headless globals carry none, so it must be pinned in package.use/desktop.
#   * cronie. The mapper's 60s floor is a root cron: the base list must carry
#     sys-process/cronie and the builder's DEFAULT_SVCS must enable it.
#   * gnome-extra/nm-applet is a resolvability TRAP on these targets: its hard
#     RDEPEND net-libs/libnma needs gui-libs/gtk-4 unconditionally (the chain
#     every ARM package.use already pins libfm[-automount]/pinentry[-gtk] off
#     for, because gtk-4 fails to cross-configure) and its +modemmanager
#     default USE-requires networkmanager[modemmanager], which every ARM spec
#     forces off. The lists say so and do NOT request it; if someone does, the
#     -modemmanager half must at least be pinned or the build dies at depgraph.
#
# And one Frite base-list fact: install-frite.sh --write-uboot-spi gates on
# `command -v flashcp`, which only sys-fs/mtd-utils provides. Without the atom
# that branch always skipped.
#
# Pure static text checks over the specs + builders; no emerge, no network.
# NEGATIVE CONTROLS at the end re-run this same analyser (GEN_ROOT=) against
# synthesised trees carrying each defect on purpose, so a green run over the
# real tree cannot be vacuous.
#
#   bash tests/scripts/test-arm-desktop-package-sets.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
GEN="${GEN_ROOT:-${REPO}}"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

# platform|desktop list (relative to specs-<platform>/portage)|builder
# Kept in lockstep with the ARM desktop set in docs/CLIENT-IMAGES.md; the
# orangepi-zero*/3-lts appliances have no desktop mode and are not here.
PLATFORMS=(
  "rpi5|packages-desktop.list|build-rpi5-stage4.sh"
  "jetson|packages-desktop.list|build-jetson-stage4.sh"
  "frite|packages-light-desktop.list|build-frite-stage4.sh"
  "orangepi5|packages-desktop.list|build-orangepi5-stage4.sh"
  "orangepi4-lts|packages-desktop.list|build-orangepi4-lts-stage4.sh"
)

# An atom is REQUESTED by a list iff it is a whole non-comment line (the
# builders strip '^\s*#' and blank lines and pass the rest to emerge verbatim).
requests() { # <list-file> <atom>
  [ -f "$1" ] && grep -Eq "^[[:space:]]*$2[[:space:]]*$" "$1"
}

# Final state of a global USE flag across a spec's make.conf.tmpl USE= lines
# (appended via USE="${USE} ...", last token wins). Echoes +, - or "".
global_flag_state() { # <make.conf.tmpl> <flag>
  local mk="$1" state="" tok
  [ -f "${mk}" ] || { echo ""; return 0; }
  while read -r tok; do
    case "${tok}" in
      "$2")  state="+" ;;
      "-$2") state="-" ;;
    esac
  done < <(grep -E '^[[:space:]]*USE=' "${mk}" | tr '"' ' ' | tr ' ' '\n')
  echo "${state}"
}

# Is <flag> pinned ON for <pkg> in any file of <package.use dir>? Echoes +, -
# or "" (a later -flag on the same package line wins over an earlier +flag).
pkguse_state() { # <package.use dir> <pkg> <flag>
  local f line tok state=""
  [ -d "$1" ] || { echo ""; return 0; }
  for f in "$1"/*; do
    [ -f "${f}" ] || continue
    while read -r line; do
      case "${line}" in \#*|"") continue ;; esac
      [ "${line%% *}" = "$2" ] || continue
      for tok in ${line#* }; do
        case "${tok}" in
          "$3")  state="+" ;;
          "-$3") state="-" ;;
        esac
      done
    done < "${f}"
  done
  echo "${state}"
}

echo "== ARM desktop package sets: governance runtime declared =="
for entry in "${PLATFORMS[@]}"; do
  IFS='|' read -r plat dlist builder <<<"${entry}"
  spec="${GEN}/specs-${plat}/portage"
  desk="${spec}/${dlist}"
  base="${spec}/packages.list"
  bld="${GEN}/${builder}"
  echo "-- ${plat}"

  [ -f "${desk}" ] && ok "${plat}: desktop list present (${dlist})" \
                   || { bad "${plat}: desktop list missing: ${desk}"; continue; }

  # 1. the two governance runtimes are declared in the DESKTOP list
  requests "${desk}" 'sys-auth/polkit' \
    && ok "${plat}: sys-auth/polkit declared in the desktop list" \
    || bad "${plat}: sys-auth/polkit not declared in ${dlist} (sole sudo path is transitive-only)"
  requests "${desk}" 'dev-lang/python' \
    && ok "${plat}: dev-lang/python declared in the desktop list" \
    || bad "${plat}: dev-lang/python not declared in ${dlist}"

  # 2. and stay CLIENT-scoped: the base list feeds the headless roles too
  ! requests "${base}" 'sys-auth/polkit' \
    && ok "${plat}: polkit stays desktop-scoped (not in packages.list)" \
    || bad "${plat}: sys-auth/polkit leaked into the base (headless) packages.list"

  # 3. the mapper's cron floor actually runs: cronie in base + DEFAULT_SVCS
  requests "${base}" 'sys-process/cronie' \
    && ok "${plat}: sys-process/cronie in the base list" \
    || bad "${plat}: sys-process/cronie missing from packages.list"
  if [ -f "${bld}" ] && grep -Eq '^DEFAULT_SVCS=\([^)]*[[:space:](]cronie[[:space:])]' "${bld}"; then
    ok "${plat}: builder DEFAULT_SVCS enables cronie"
  else
    bad "${plat}: ${builder} DEFAULT_SVCS does not enable cronie (mapper floor never runs)"
  fi

  # 4. polkit is built with elogind session tracking, by SOME route
  g="$(global_flag_state "${spec}/make.conf.tmpl" elogind)"
  pu="$(pkguse_state "${spec}/package.use" sys-auth/polkit elogind)"
  cu=""
  if [ -f "${bld}" ] && grep -Eq '^[[:space:]]*CLIENT_USE="[^"]*[[:space:]"]elogind[[:space:]"]' "${bld}"; then
    cu="+"
  fi
  if [ "${pu}" = "-" ]; then
    bad "${plat}: package.use pins sys-auth/polkit -elogind (ConsoleKit fallback sees no sessions)"
  elif [ "${pu}" = "+" ]; then
    ok "${plat}: polkit[elogind] via package.use pin"
  elif [ "${g}" = "+" ]; then
    ok "${plat}: polkit[elogind] via global USE=elogind in make.conf.tmpl"
  elif [ "${cu}" = "+" ]; then
    ok "${plat}: polkit[elogind] via the builder's CLIENT_USE append"
  else
    bad "${plat}: no route turns on polkit[elogind] (global USE, CLIENT_USE, package.use) — gate would authorize nobody"
  fi

  # 5. the nm-applet trap: not requested; if ever requested, at least the
  #    -modemmanager half of the wall must be pinned
  nma=false
  for lst in "${spec}"/packages*.list; do
    requests "${lst}" 'gnome-extra/nm-applet' && nma=true
  done
  if ${nma}; then
    if [ "$(pkguse_state "${spec}/package.use" gnome-extra/nm-applet modemmanager)" = "-" ]; then
      ok "${plat}: nm-applet requested WITH the -modemmanager pin (gtk-4 cross-build still unproven — see the list's note)"
    else
      bad "${plat}: gnome-extra/nm-applet requested without 'gnome-extra/nm-applet -modemmanager' — unresolvable against networkmanager[-modemmanager]"
    fi
  else
    ok "${plat}: gnome-extra/nm-applet not requested (libnma -> gtk-4 cross wall)"
  fi
done

# 6. Frite: flashcp for the SPI u-boot write
echo "-- frite installer"
FB="${GEN}/specs-frite/portage/packages.list"
FI="${GEN}/specs-frite/installer/install-frite.sh"
requests "${FB}" 'sys-fs/mtd-utils' \
  && ok "frite: sys-fs/mtd-utils (flashcp) in the base list" \
  || bad "frite: sys-fs/mtd-utils missing from packages.list — install-frite.sh --write-uboot-spi always skips"
if [ -f "${FI}" ] && grep -Eq 'command -v flashcp([[:space:]]|$)' "${FI}"; then
  ok "frite: install-frite.sh still gates the SPI write on flashcp (guard is live)"
else
  bad "frite: install-frite.sh no longer gates on flashcp — retire or re-anchor this check"
fi

# 7. the x86 list this mirrors is still the live contract
X86="${GEN}/specs-x86/portage/packages-desktop.list"
if requests "${X86}" 'sys-auth/polkit' && requests "${X86}" 'dev-lang/python'; then
  ok "x86 client list still declares polkit + python (the ARM lists mirror a live contract)"
else
  bad "x86 client list no longer declares polkit + python — reconcile the ARM mirror"
fi

# ── Negative controls ─────────────────────────────────────────────────────────
# Re-run this analyser on synthesised trees that each carry ONE defect. Each
# must turn RED with a FAIL line naming the defect, or the green run above is
# not evidence of anything. Skipped inside a child run (ARM_PKGSETS_CHILD=1).
if [ -z "${ARM_PKGSETS_CHILD:-}" ]; then
  echo "-- negative controls"
  TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

  # The minimal file set the analyser reads, copied once as the pristine tree.
  mk_tree() { # <dir>
    local d="$1" plat
    mkdir -p "${d}"
    for plat in rpi5 jetson frite orangepi5 orangepi4-lts x86; do
      mkdir -p "${d}/specs-${plat}/portage"
      cp "${GEN}/specs-${plat}/portage/"packages*.list "${d}/specs-${plat}/portage/" 2>/dev/null || true
      cp "${GEN}/specs-${plat}/portage/make.conf.tmpl" "${d}/specs-${plat}/portage/" 2>/dev/null || true
      [ -d "${GEN}/specs-${plat}/portage/package.use" ] \
        && cp -r "${GEN}/specs-${plat}/portage/package.use" "${d}/specs-${plat}/portage/"
    done
    mkdir -p "${d}/specs-frite/installer"
    cp "${GEN}/specs-frite/installer/install-frite.sh" "${d}/specs-frite/installer/"
    for b in build-rpi5-stage4.sh build-jetson-stage4.sh build-frite-stage4.sh \
             build-orangepi5-stage4.sh build-orangepi4-lts-stage4.sh; do
      # only the lines the analyser reads; the builders are large
      grep -E '^DEFAULT_SVCS=\(|^[[:space:]]*CLIENT_USE=' "${GEN}/${b}" > "${d}/${b}"
    done
  }
  PRISTINE="${TMP}/pristine"; mk_tree "${PRISTINE}"

  # Sanity: the pristine synthesised tree must itself be GREEN, or every
  # negative below would be red for the wrong reason.
  if ARM_PKGSETS_CHILD=1 GEN_ROOT="${PRISTINE}" bash "${BASH_SOURCE[0]}" > "${TMP}/pristine.out" 2>&1; then
    ok "negative-control baseline: the synthesised pristine tree is green"
  else
    bad "negative-control baseline: synthesised pristine tree is RED (copy set incomplete?)"
    sed 's/^/      /' "${TMP}/pristine.out" | grep FAIL || true
  fi

  neg_case() { # <name> <expected-FAIL-substring> <mutation shell snippet, run with T=<tree>>
    local name="$1" expect="$2" mut="$3" t="${TMP}/${1}"
    cp -r "${PRISTINE}" "${t}"
    # the mutation must CHANGE the tree, or the case proves nothing
    ( cd "${t}" && T="${t}" bash -c "${mut}" )
    if diff -rq "${PRISTINE}" "${t}" > /dev/null; then
      bad "neg ${name}: mutation did not change the tree"
      return
    fi
    if ARM_PKGSETS_CHILD=1 GEN_ROOT="${t}" bash "${BASH_SOURCE[0]}" > "${t}.out" 2>&1; then
      bad "neg ${name}: analyser stayed GREEN on a tree carrying the defect"
    elif grep -Fq "${expect}" "${t}.out"; then
      ok "neg ${name}: analyser RED, names the defect"
    else
      bad "neg ${name}: analyser red but not for the expected reason (wanted '${expect}')"
      grep FAIL "${t}.out" | sed 's/^/      /' || true
    fi
  }

  neg_case drop-polkit-frite "sys-auth/polkit not declared" \
    "sed -i '/^sys-auth\/polkit\$/d' \$T/specs-frite/portage/packages-light-desktop.list"
  neg_case drop-python-jetson "dev-lang/python not declared" \
    "sed -i '/^dev-lang\/python\$/d' \$T/specs-jetson/portage/packages-desktop.list"
  neg_case leak-polkit-rpi5-base "leaked into the base" \
    "echo sys-auth/polkit >> \$T/specs-rpi5/portage/packages.list"
  neg_case drop-cronie-orangepi5 "sys-process/cronie missing" \
    "sed -i '/^sys-process\/cronie\$/d' \$T/specs-orangepi5/portage/packages.list"
  neg_case drop-cronie-svc-jetson "does not enable cronie" \
    "sed -i 's/ cronie / /' \$T/build-jetson-stage4.sh"
  neg_case drop-jetson-polkit-elogind "no route turns on polkit[elogind]" \
    "sed -i '/^sys-auth\/polkit elogind\$/d' \$T/specs-jetson/portage/package.use/desktop"
  neg_case pin-polkit-minus-elogind-frite "pins sys-auth/polkit -elogind" \
    "echo 'sys-auth/polkit -elogind' >> \$T/specs-frite/portage/package.use/frite"
  neg_case global-minus-elogind-orangepi4 "no route turns on polkit[elogind]" \
    "printf 'USE=\"\${USE} -elogind\"\n' >> \$T/specs-orangepi4-lts/portage/make.conf.tmpl"
  neg_case request-nm-applet-orangepi5 "requested without 'gnome-extra/nm-applet -modemmanager'" \
    "echo gnome-extra/nm-applet >> \$T/specs-orangepi5/portage/packages-desktop.list"
  neg_case drop-mtd-utils-frite "sys-fs/mtd-utils missing" \
    "sed -i '/^sys-fs\/mtd-utils\$/d' \$T/specs-frite/portage/packages.list"
  neg_case x86-contract-gone "x86 client list no longer declares" \
    "sed -i '/^sys-auth\/polkit\$/d' \$T/specs-x86/portage/packages-desktop.list"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
