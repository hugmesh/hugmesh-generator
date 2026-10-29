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
#   3. specs-x86/portage/package.use/gpu hard-coded mesa's cards to the all-free
#      set (video_cards_amdgpu radeonsi intel iris nouveau) while make.conf's
#      VIDEO_CARDS is rendered from --gpu-driver. be+gpu/omnibus default to
#      --gpu-driver all-free and agreed by accident; edge_ai defaults to
#      --gpu-driver nvidia (VIDEO_CARDS="nouveau nvidia"), and libdrm — which has
#      no pin and inherits make.conf — could not satisfy mesa's forced amdgpu. The
#      2026-08-22 fleet run (out/sessions/20260822-225110-80c83a) spent ~40 minutes
#      to report ">=x11-libs/libdrm-2.4.121[video_cards_amdgpu]" unsatisfiable as
#      "stage4 payload incomplete — missing: grub-install dracut parted jq nmcli
#      kubelet kubeadm containerd", i.e. naming nothing GPU-related at all.
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
         | tr ' "' '\n\n' | grep -x 'dbus' >/dev/null; then
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

echo "-- 3) package.use must NOT hard-code a video_cards_* token --"
# The card set is a per-build decision made exactly ONCE, by --gpu-driver, and
# rendered into make.conf's VIDEO_CARDS. Every package with a video_cards_* IUSE
# inherits THAT list, so a package.use file that forces a card make.conf did not
# select drags in the forced card's dependency chain while its deps keep
# inheriting the narrower list — unsatisfiable, and it aborts the whole 'image'
# emerge GROUP. Assertions are DERIVED: the driver→cards matrix is read out of the
# builder, the forced tokens out of the specs; neither is a hardcoded list.
TMP3="$(mktemp -d)"
trap 'rm -rf "${TMP3}"' EXIT

# Forced-ON video_cards tokens in a package.use DIRECTORY, parsed as FIELDS.
# A package.use line is "<atom> <flag>…": an enabled flag is a bare word, a
# disabled one is '-'-prefixed, and the prose ABOUT these flags lives in '#'
# comments — which is why this is not a substring match (the fixed files still
# discuss video_cards_* at length, and a regex over the line matches that prose).
# Emits "<file>|<atom>|<token>" and, on stderr-free stdout, nothing else.
forced_video_cards() { # <package.use dir>
  local f
  for f in "$1"/*; do
    [ -f "${f}" ] || continue
    awk -v fn="$(basename "${f}")" '
      /^[[:space:]]*#/ { next }
      NF > 1 { for (i = 2; i <= NF; i++) if ($i ~ /^video_cards_/) print fn "|" $1 "|" $i }' "${f}"
  done
}
# Every non-comment package.use entry line, for the "did we actually read
# anything?" floor — a parser pointed at the wrong path emits zero offenders too.
count_pu_entries() { # <package.use dir>
  local f n=0
  for f in "$1"/*; do
    [ -f "${f}" ] || continue
    n=$((n + $(awk '/^[[:space:]]*#/ { next } NF > 1 { c++ } END { print c + 0 }' "${f}")))
  done
  echo "${n}"
}
# The driver → VIDEO_CARDS matrix, read out of the builder's gpu_video_cards().
# That function is the builder's OWN single source for @@VIDEO_CARDS@@, so this
# test and the shipped make.conf can never disagree about what a driver means.
gpu_matrix() { # <builder path> -> "<driver>|<cards>" lines
  sed -n '/^gpu_video_cards()/,/^}/p' "$1" \
    | sed -n 's/^[[:space:]]*\([a-z][a-z-]*\))[[:space:]]*echo "\([^"]*\)".*/\1|\2/p'
}
builder_of() { # <platform> -> the builder that owns specs-<platform>
  grep -lF "SPECS_DIR=\"\${SCRIPT_DIR}/specs-$1\"" "${REPO}"/build-*.sh 2>/dev/null | head -1
}

# 3a) the matrix itself: parsed, plural, and covering more than one vendor.
X86_BUILDER="$(builder_of x86)"
if [ -z "${X86_BUILDER}" ]; then
  bad "cannot locate the builder that owns specs-x86 — the whole video_cards check below would be vacuous"
  MATRIX=""
else
  ok "specs-x86 is owned by $(basename "${X86_BUILDER}")"
  MATRIX="$(gpu_matrix "${X86_BUILDER}")"
fi
MATRIX_N="$(printf '%s' "${MATRIX}" | grep -c '|' || true)"
if [ "${MATRIX_N}" -ge 7 ]; then
  ok "parsed ${MATRIX_N} --gpu-driver → VIDEO_CARDS rows from gpu_video_cards()"
else
  bad "parsed only ${MATRIX_N} --gpu-driver rows from gpu_video_cards() in ${X86_BUILDER:-<none>} (expected >= 7: all-free/nvidia-free/nvidia/amd-free/amd-pro/intel-free/intel-pro) — every card assertion below would be checked against an empty matrix and pass vacuously"
fi
ALL_CARDS="$(printf '%s\n' "${MATRIX}" | cut -d'|' -f2- | tr ' ' '\n' | grep -v '^$' | sort -u)"
CARDS_N="$(printf '%s' "${ALL_CARDS}" | grep -c . || true)"
[ "${CARDS_N}" -ge 5 ] \
  && ok "the matrix names ${CARDS_N} distinct cards (${ALL_CARDS//$'\n'/ })" \
  || bad "the matrix names only ${CARDS_N} distinct cards — too few for the disagreement check to mean anything"
# The matrix must actually DISAGREE across drivers, otherwise "token absent from
# VIDEO_CARDS" is unreachable by construction and 3c can never fail.
DIVERGENT=0
while IFS='|' read -r drv cards; do
  [ -n "${drv}" ] || continue
  for c in ${ALL_CARDS}; do
    case " ${cards} " in *" ${c} "*) ;; *) DIVERGENT=1 ;; esac
  done
done <<< "${MATRIX}"
[ "${DIVERGENT}" -eq 1 ] \
  && ok "the drivers select DIFFERENT card sets — a hard-coded token can therefore contradict at least one of them" \
  || bad "every --gpu-driver selects the same cards — this check cannot detect anything"

# 3b) floor: the scan actually read the specs.
PU_FILES=0; PU_ENTRIES=0
for p in "${PLATFORMS[@]}"; do
  pud="${REPO}/specs-${p}/portage/package.use"
  [ -d "${pud}" ] || continue
  PU_FILES=$((PU_FILES + $(find "${pud}" -maxdepth 1 -type f | wc -l)))
  PU_ENTRIES=$((PU_ENTRIES + $(count_pu_entries "${pud}")))
done
[ "${PU_FILES}" -ge 13 ] && [ "${PU_ENTRIES}" -ge 100 ] \
  && ok "scanned ${PU_FILES} package.use files / ${PU_ENTRIES} entry lines across ${#PLATFORMS[@]} platform(s)" \
  || bad "only ${PU_FILES} package.use files / ${PU_ENTRIES} entry lines were scanned — the extractor is pointed at the wrong tree, so 'no offenders' means nothing"

# 3c) the assertion: zero hard-coded tokens, per platform, naming the drivers each
#     offender contradicts so the failure is actionable rather than a bare diff.
for p in "${PLATFORMS[@]}"; do
  pud="${REPO}/specs-${p}/portage/package.use"
  [ -d "${pud}" ] || { ok "${p}: no package.use dir"; continue; }
  hits="$(forced_video_cards "${pud}")"
  if [ -z "${hits}" ]; then
    ok "${p}: no package.use file hard-codes a card — every package inherits make.conf VIDEO_CARDS"
    continue
  fi
  while IFS='|' read -r fn atom tok; do
    [ -n "${tok}" ] || continue
    card="${tok#video_cards_}"; against=""
    while IFS='|' read -r drv cards; do
      [ -n "${drv}" ] || continue
      case " ${cards} " in *" ${card} "*) ;; *) against="${against}${against:+ }${drv}" ;; esac
    done <<< "${MATRIX}"
    bad "${p}: package.use/${fn} forces '${atom} ${tok}', but --gpu-driver ${against:-<any>} do NOT select '${card}' — mesa/libdrm-class deps then inherit the narrower make.conf VIDEO_CARDS and the whole 'image' emerge group aborts (2026-08-22 edge_ai run: libdrm-2.4.121[video_cards_amdgpu] unsatisfiable, reported as a missing grub/dracut/kubelet payload)"
  done <<< "${hits}"
done

# 3d) POSITIVE CONTROL for the extractor. 3c passes over an EMPTY offender list by
#     design once the specs are clean, so prove the detector still detects: replay
#     the exact line the 2026-08-22 build died on into a throwaway copy.
CTL="${TMP3}/pu"; mkdir -p "${CTL}"
cp "${REPO}"/specs-x86/portage/package.use/* "${CTL}/" 2>/dev/null || true
CTL_BASE="$(forced_video_cards "${CTL}" | grep -c . || true)"     # 0 once 3c is clean
printf 'media-libs/mesa vulkan vaapi vdpau gles2 gbm egl llvm video_cards_amdgpu video_cards_radeonsi video_cards_intel video_cards_iris video_cards_nouveau\n' >> "${CTL}/gpu"
CTL_HITS="$(forced_video_cards "${CTL}" | grep -c . || true)"
CTL_DELTA=$((CTL_HITS - CTL_BASE))
# The DELTA, not the total: measured against whatever the tree already carries, so
# this control reports on the EXTRACTOR alone and cannot be confused with 3c's verdict.
[ "${CTL_DELTA}" -eq 5 ] \
  && ok "positive control: injecting the historical mesa line adds exactly 5 detected tokens (baseline ${CTL_BASE}) — the extractor sees the defect this test exists for" \
  || bad "positive control: injecting the historical mesa line changed the detected-token count by ${CTL_DELTA} (${CTL_BASE} → ${CTL_HITS}), expected +5 — the extractor cannot reliably see the very defect this test exists for, so 3c's result means nothing"
# …and the matrix comparison must judge the injected cards as contradicting the
# driver edge_ai actually defaults to. Only the 4 non-nouveau cards may count.
CTL_NV="$(printf '%s\n' "${MATRIX}" | sed -n 's/^nvidia|//p')"
CTL_NVIDIA=0
while IFS='|' read -r fn atom tok; do
  [ -n "${tok}" ] || continue
  card="${tok#video_cards_}"
  case " ${CTL_NV} " in *" ${card} "*) ;; *) CTL_NVIDIA=$((CTL_NVIDIA + 1)) ;; esac
done <<< "$(printf 'gpu|media-libs/mesa|video_cards_amdgpu\ngpu|media-libs/mesa|video_cards_radeonsi\ngpu|media-libs/mesa|video_cards_intel\ngpu|media-libs/mesa|video_cards_iris\ngpu|media-libs/mesa|video_cards_nouveau')"
[ "${CTL_NVIDIA}" -eq 4 ] \
  && ok "positive control: 4 of the 5 injected cards contradict --gpu-driver nvidia (nouveau is the one it does select) — the exact 2026-08-22 wall"  \
  || bad "positive control: ${CTL_NVIDIA} of the 5 injected cards were judged to contradict --gpu-driver nvidia, expected exactly 4 (all but nouveau) — the matrix/offender comparison is broken, so 3c cannot classify a real offender either"

# 3e) the BUILDER-side guard: the spec fix alone is a snapshot, the assert is what
#     keeps it true. Both halves must be wired, and the copy loop must share the
#     assert's role predicate (an inline copy of that case is how they drifted).
if [ -n "${X86_BUILDER}" ]; then
  grep -qF 'assert_spec_video_cards() {' "${X86_BUILDER}" \
    && grep -qE '^assert_spec_video_cards$' "${X86_BUILDER}" \
    && ok "$(basename "${X86_BUILDER}"): assert_spec_video_cards is defined AND invoked" \
    || bad "$(basename "${X86_BUILDER}"): assert_spec_video_cards is not both defined and invoked — a contradicting spec would again be discovered ~40min into the merge"
  grep -qF 'pu_copied_for_role "$(basename "${puf}")"' "${X86_BUILDER}" \
    && ok "$(basename "${X86_BUILDER}"): the package.use copy loop uses the same role predicate the assert checks" \
    || bad "$(basename "${X86_BUILDER}"): the package.use copy loop no longer uses pu_copied_for_role — the assert can check a different set of files than the build installs"
  grep -qF 'VIDEO_CARDS="$(gpu_video_cards "${GPU_DRIVER}")"' "${X86_BUILDER}" \
    && ok "$(basename "${X86_BUILDER}"): make.conf's VIDEO_CARDS comes from the same gpu_video_cards() matrix this test parsed" \
    || bad "$(basename "${X86_BUILDER}"): make.conf's VIDEO_CARDS is derived somewhere other than gpu_video_cards() — this test is checking a matrix the build does not use"
  grep -qF 'VIDEO_CARDS="@@VIDEO_CARDS@@"' "${REPO}/specs-x86/portage/make.conf.tmpl" \
    && ok "specs-x86/portage/make.conf.tmpl still renders VIDEO_CARDS from the builder" \
    || bad "specs-x86/portage/make.conf.tmpl no longer carries VIDEO_CARDS=\"@@VIDEO_CARDS@@\" — the inheritance the fixed package.use files rely on is gone"
fi

# 3f) END-TO-END, through the REAL builder's argv path (--print-plan: no root, no
#     network, no writes). Positive: the shipped specs + edge_ai's default
#     --gpu-driver nvidia resolve. Negative: the same builder over a specs tree
#     carrying the historical mesa line must REFUSE, at argv time.
if [ -n "${X86_BUILDER}" ]; then
  if ( cd "${TMP3}" && bash "${X86_BUILDER}" --role edge-ai --env test -w "${TMP3}/work" --print-plan ) >"${TMP3}/pos.out" 2>&1; then
    ok "end-to-end: the real builder ACCEPTS --role edge-ai (default --gpu-driver nvidia) against the shipped specs"
  else
    bad "end-to-end: the real builder REFUSES --role edge-ai --print-plan against the shipped specs: $(tail -3 "${TMP3}/pos.out" | tr '\n' ' ')"
  fi
  # Symlink farm: SCRIPT_DIR is dirname($0), so a farm of symlinks with ONE real
  # (mutated) specs-x86 runs the real builder against a doctored spec tree.
  FARM="${TMP3}/farm"; mkdir -p "${FARM}"
  ln -s "${REPO}"/* "${FARM}/" 2>/dev/null || true
  rm -f "${FARM}/specs-x86"; cp -r "${REPO}/specs-x86" "${FARM}/specs-x86"
  cp "${CTL}/gpu" "${FARM}/specs-x86/portage/package.use/gpu"
  if ( cd "${FARM}" && bash "${FARM}/$(basename "${X86_BUILDER}")" --role edge-ai --env test -w "${TMP3}/work" --print-plan ) >"${TMP3}/neg.out" 2>&1; then
    bad "end-to-end NEGATIVE control: the builder ACCEPTED a specs tree whose package.use/gpu forces amdgpu/radeonsi/intel/iris while --gpu-driver nvidia selects only 'nouveau nvidia' — that is exactly the 2026-08-22 edge_ai argv, and it must be refused before the merge, not 40 minutes into it"
  elif grep -qF 'spec/argv disagree about VIDEO_CARDS' "${TMP3}/neg.out"; then
    ok "end-to-end NEGATIVE control: the builder refuses the contradicting spec tree at argv time, naming VIDEO_CARDS"
  else
    bad "end-to-end NEGATIVE control: the builder failed on the contradicting spec tree but never mentioned VIDEO_CARDS — the operator is sent hunting: $(tail -3 "${TMP3}/neg.out" | tr '\n' ' ')"
  fi
fi

echo "-- 4) qtdeclarative carries the SAME qtbase-matched USE as qtbase (wayland=, opengl=, ...) --"
# dev-qt/qtdeclarative-6.11.2-r1 (stable amd64 in the 2026-09-24 builder tree, and
# 6.12.0 the same) depends UNCONDITIONALLY on
#   ~dev-qt/qtbase-${PV}:6[accessibility=,gui,network=,opengl=,sql?,ssl?,vulkan=,wayland=,widgets=]
# Each '=' flag must be set the same way on both packages. The x86 specs turned
# wayland on for qtbase but not for qtdeclarative, so no pair could satisfy the
# dependency: the 2026-10-21 standalone-unaffiliated build stopped its payload
# emerge at "Calculating dependencies" with
#   there are no ebuilds built with USE flags to satisfy
#   "~dev-qt/qtbase-6.11.2:6[...,wayland=,...]"
# and reported eight "missing" binaries (grub-install ... openbox). Every x86
# desktop role ships that chain (keditfiletype -> kcmutils -> kio -> kwallet ->
# qca -> qt5compat[qml] -> qtdeclarative).
# Rule, per package.use FILE (each file must be right on its own, because which
# files a role installs differs by role): a qtbase-matched flag that a file turns
# on (or off) for dev-qt/qtbase must be turned on (or off) for
# dev-qt/qtdeclarative in that same file. Fields, not a regex over the line.
QTDECL_EQ_FLAGS="accessibility network opengl vulkan wayland widgets"
# Optional: derive the '=' set from a real gentoo tree too, so a Qt bump that adds
# a flag (the way 6.11.2-r1 added wayland=) trips this before a build does.
# HUGMESH_GENTOO_TREE=/var/db/repos/gentoo bash tests/scripts/test-spec-use-parity.sh
if [ -n "${HUGMESH_GENTOO_TREE:-}" ]; then
  if [ -d "${HUGMESH_GENTOO_TREE}/dev-qt/qtdeclarative" ]; then
    derived="$(cat "${HUGMESH_GENTOO_TREE}"/dev-qt/qtdeclarative/qtdeclarative-*.ebuild 2>/dev/null \
      | grep -aoE 'dev-qt/qtbase-\$\{PV\}:6\[[^]]*\]' \
      | grep -aoE '[a-z0-9_-]+=' | tr -d '=' | sort -u | tr '\n' ' ')"
    if [ -n "${derived}" ]; then
      ok "derived qtdeclarative's qtbase '=' flags from ${HUGMESH_GENTOO_TREE}: ${derived}"
      for f in ${derived}; do
        case " ${QTDECL_EQ_FLAGS} " in *" ${f} "*) ;; *) QTDECL_EQ_FLAGS="${QTDECL_EQ_FLAGS} ${f}" ;; esac
      done
    else
      bad "HUGMESH_GENTOO_TREE=${HUGMESH_GENTOO_TREE} has qtdeclarative ebuilds but no qtbase '=' dependency could be parsed — the derivation is blind"
    fi
  else
    bad "HUGMESH_GENTOO_TREE=${HUGMESH_GENTOO_TREE} has no dev-qt/qtdeclarative — wrong path"
  fi
fi
pu_flag_state() { # <file> <atom> <flag> -> on | off | unset (last mention wins)
  awk -v atom="$2" -v want="$3" '
    /^[[:space:]]*#/ { next }
    $1 == atom { for (i = 2; i <= NF; i++) { if ($i == want) s = "on"; else if ($i == "-" want) s = "off" } }
    END { print (s == "" ? "unset" : s) }' "$1" 2>/dev/null
}
qt_pairs_checked=0
for p in "${PLATFORMS[@]}"; do
  pud="${REPO}/specs-${p}/portage/package.use"
  [ -d "${pud}" ] || continue
  for puf in "${pud}"/*; do
    [ -f "${puf}" ] || continue
    for f in ${QTDECL_EQ_FLAGS}; do
      base_state="$(pu_flag_state "${puf}" dev-qt/qtbase "${f}")"
      [ "${base_state}" = "unset" ] && continue
      qt_pairs_checked=$((qt_pairs_checked + 1))
      decl_state="$(pu_flag_state "${puf}" dev-qt/qtdeclarative "${f}")"
      if [ "${decl_state}" = "${base_state}" ]; then
        ok "${p}: package.use/$(basename "${puf}") sets '${f}'=${base_state} on BOTH qtbase and qtdeclarative"
      else
        bad "${p}: package.use/$(basename "${puf}") sets '${f}'=${base_state} on dev-qt/qtbase but '${f}'=${decl_state} on dev-qt/qtdeclarative — qtdeclarative depends on qtbase[${f}=], so the pair cannot resolve and the whole payload emerge stops before merging anything (2026-10-21 desktop build: wayland)"
      fi
    done
  done
done
# Floor: the shipped x86 specs set at least qtbase opengl + wayland in desktop AND
# capable, so fewer than 4 checked pairs means the parser read nothing.
[ "${qt_pairs_checked}" -ge 4 ] \
  && ok "checked ${qt_pairs_checked} qtbase/qtdeclarative flag pair(s)" \
  || bad "checked only ${qt_pairs_checked} qtbase/qtdeclarative flag pair(s) (expected >= 4: opengl+wayland in x86 desktop and capable) — section 4 is reading the wrong files and would pass vacuously"
# Positive control: replay the 2026-10-21 shape (qtbase wayland, qtdeclarative
# without it) into a throwaway file; the rule must call it a mismatch.
QCTL="${TMP3}/qtctl"; mkdir -p "${QCTL}"
printf 'dev-qt/qtbase opengl libproxy icu wayland\ndev-qt/qtdeclarative opengl vulkan\n' > "${QCTL}/desktop"
if [ "$(pu_flag_state "${QCTL}/desktop" dev-qt/qtbase wayland)" = "on" ] \
   && [ "$(pu_flag_state "${QCTL}/desktop" dev-qt/qtdeclarative wayland)" = "unset" ]; then
  ok "positive control: the 2026-10-21 line pair reads as qtbase wayland=on, qtdeclarative wayland=unset (a mismatch)"
else
  bad "positive control: the parser does not see the 2026-10-21 qtbase/qtdeclarative wayland mismatch — section 4 cannot detect the defect it exists for"
fi

echo "-- 5) every --gpu-driver card list closes over the xorg DDX -> libdrm card it pulls --"
# On a client role x11-base/xorg-drivers turns each VIDEO_CARDS entry into an X
# driver (DDX), and some DDXs need libdrm built for a card of their own. libdrm
# inherits make.conf's VIDEO_CARDS (section 3 forbids pinning it), so that card
# MUST be in the same --gpu-driver list or the payload emerge cannot resolve.
# From xorg-drivers-21.1-r2.ebuild (2026-09-24 builder tree) and the
# x11-drivers/xf86-video-* ebuilds it names:
#   radeonsi -> xf86-video-ati      -> libdrm[video_cards_radeon]   (line 81)
#   radeon   -> xf86-video-ati      -> libdrm[video_cards_radeon]   (line 80)
#   amdgpu   -> xf86-video-amdgpu   -> libdrm[video_cards_amdgpu]
#   nouveau  -> xf86-video-nouveau  -> libdrm[video_cards_nouveau]
#   i915     -> xf86-video-intel    -> libdrm[video_cards_intel]
# The 2026-10-21 all-free build (amdgpu radeonsi intel iris nouveau) walled on
#   ">=x11-libs/libdrm-2.4.89[video_cards_radeon]" required by xf86-video-ati
# once the Qt wall in section 4 was out of the way (replayed in its own sysroot).
DDX_LIBDRM="radeonsi:radeon radeon:radeon amdgpu:amdgpu nouveau:nouveau i915:intel"
# Optional: derive the same map from a gentoo tree (newest xorg-drivers ebuild's
# 'video_cards_X? ( ...x11-drivers/xf86-video-Y... )' plus Y's libdrm[video_cards_Z]).
if [ -n "${HUGMESH_GENTOO_TREE:-}" ] && [ -d "${HUGMESH_GENTOO_TREE}/x11-base/xorg-drivers" ]; then
  for xd in "${HUGMESH_GENTOO_TREE}"/x11-base/xorg-drivers/xorg-drivers-[0-9]*.ebuild; do
    [ -f "${xd}" ] || continue
    while read -r card ddx; do
      [ -n "${ddx}" ] || continue
      for need in $(cat "${HUGMESH_GENTOO_TREE}/x11-drivers/xf86-video-${ddx}"/*.ebuild 2>/dev/null \
                     | grep -aoE 'x11-libs/libdrm[^ ]*\[video_cards_[a-z0-9]+\]' \
                     | sed -E 's/.*video_cards_([a-z0-9]+)\].*/\1/' | sort -u); do
        case " ${DDX_LIBDRM} " in *" ${card}:${need} "*) ;; *) DDX_LIBDRM="${DDX_LIBDRM} ${card}:${need}" ;; esac
      done
    done < <(grep -aoE 'video_cards_[a-z0-9]+\?[[:space:]]*\([[:space:]]*[^)]*x11-drivers/xf86-video-[a-z0-9]+' "${xd}" \
               | sed -E 's/^video_cards_([a-z0-9]+)\?.*xf86-video-([a-z0-9]+)$/\1 \2/')
  done
  ok "card -> libdrm map after reading ${HUGMESH_GENTOO_TREE}: ${DDX_LIBDRM}"
fi
ddx_rows=0
while IFS='|' read -r drv cards; do
  [ -n "${drv}" ] || continue
  [ -n "${cards}" ] || continue
  ddx_rows=$((ddx_rows + 1))
  missing=""
  for pair in ${DDX_LIBDRM}; do
    c="${pair%%:*}"; need="${pair##*:}"
    case " ${cards} " in
      *" ${c} "*) case " ${cards} " in *" ${need} "*) ;; *) missing="${missing}${missing:+, }${c} needs ${need}" ;; esac ;;
    esac
  done
  if [ -z "${missing}" ]; then
    ok "--gpu-driver ${drv} (${cards}): every X driver it pulls finds its libdrm card in the same list"
  else
    bad "--gpu-driver ${drv} (${cards}): ${missing} — xorg-drivers pulls the X driver for the first card and that driver needs x11-libs/libdrm[video_cards_<second>], which libdrm cannot have because it inherits this list; the client payload emerge stops before merging anything (2026-10-21 all-free build)"
  fi
done <<< "${MATRIX}"
[ "${ddx_rows}" -ge 6 ] \
  && ok "checked ${ddx_rows} non-empty --gpu-driver card lists against the X driver -> libdrm map" \
  || bad "checked only ${ddx_rows} card lists (expected >= 6) — section 5 read an empty matrix and would pass vacuously"

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
