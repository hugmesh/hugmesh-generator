#!/usr/bin/env bash
# test-desktop-config-lib.sh — the Studio Desktop step's builder half.
#
# Pins, with no root and no network:
#   1. scripts/_desktop-config-lib.sh dc_validate: what it accepts and every refusal
#      (node role, unknown session/card, picom on Plasma alone, Wayland without a
#      Mesa card or with the proprietary NVIDIA driver, a default session that is not
#      installed, root/duplicate accounts, accounts without a password file, a remote
#      without a URL, wildcard/foreign-arch/video_cards/python overlay lines);
#   2. dc_fold_packages_add / dc_effective_video_cards (radeonsi closure);
#   3. dc_apply_portage_overlay writes zz-hugmesh-studio AFTER a pcs_sync_dir (which
#      prunes it — the order the builders keep) and removes it when no line is given;
#   4. dc_bake_desktop: default session, extra accounts (0600, hashed, never the
#      plaintext, admin only with :admin), Flatpak list + service + runlevel, and the
#      neutral names on an --unaffiliated image;
#   5. _python-targets-lib.sh: the Desktop step's targets WIDEN the seed set and the
#      single target must be in it;
#   6. scripts/_pretend-lib.sh against a stub `emerge`: needs (USE + keyword), clean,
#      fails CLOSED on timeout / empty / slot conflict / a NUL byte in the log;
#   7. the six builders' wiring (static): flags parsed, overlay before
#      pt_apply_seed_targets, bake after the lightdm.conf heredoc, --pretend-only
#      before the payload chroot, the PRETEND heredoc free of backticks/dollar-parens.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# Run a snippet with the lib sourced in a clean subshell; prints its stdout+stderr.
lib() {
    ( set +u
      # shellcheck source=/dev/null
      . "${REPO}/scripts/_passhash-lib.sh"
      # shellcheck source=/dev/null
      . "${REPO}/scripts/_portage-config-lib.sh"
      # shellcheck source=/dev/null
      . "${REPO}/scripts/_python-targets-lib.sh"
      # shellcheck source=/dev/null
      . "${REPO}/scripts/_desktop-config-lib.sh"
      eval "$1" ) 2>&1
}
accepts() { # LABEL SNIPPET
    if out="$(lib "$2")"; then ok "$1"; else bad "$1 — refused: ${out}"; fi
}
refuses() { # LABEL SNIPPET EXPECTED-TEXT
    if out="$(lib "$2")"; then bad "$1 — accepted"; return; fi
    case "${out}" in *"$3"*) ok "$1";; *) bad "$1 — refused, but not with '$3': ${out}";; esac
}

echo "== 1. dc_validate"
accepts "nothing set is accepted on a node role" 'dc_validate t amd64 false true LXDE none bob'
refuses "any flag on a node role" 'DC_DEFAULT_SESSION=openbox; dc_validate t amd64 false true LXDE all-free bob' "need a desktop image"
accepts "a full good x86 set" 'DC_SESSIONS="i3 picom sway"; DC_DEFAULT_SESSION=sway; DC_VIDEO_CARDS="intel radeonsi"
    DC_FLATPAK_APPS="flathub:org.mozilla.firefox"; DC_PACKAGE_USE=">=media-video/ffmpeg-7.1.5 opus x264;media-libs/mesa vulkan"
    DC_ACCEPT_KEYWORDS="=media-video/obs-studio-32.2.2 ~amd64;gui-wm/labwc"; PT_EXTRA_TARGETS=python3_13; PT_SINGLE_TARGET=python3_13
    dc_validate t amd64 true true LXDE all-free bob'
refuses "unknown session" 'DC_SESSIONS=hyprland; dc_validate t amd64 true true LXDE all-free bob' "unknown session 'hyprland'"
refuses "sessions on ARM" 'DC_SESSIONS=i3; dc_validate t arm64 true false LXDE "" bob' "x86-only"
refuses "picom with Plasma alone" 'DC_SESSIONS=picom; dc_validate t amd64 true true plasmax11 all-free bob' "kwin already composites"
accepts "picom with Plasma + i3" 'DC_SESSIONS="i3 picom"; dc_validate t amd64 true true plasmax11 all-free bob'
refuses "Wayland with no Mesa card" 'DC_SESSIONS=sway; dc_validate t amd64 true true LXDE none bob' "needs at least one Mesa video card"
refuses "Wayland with proprietary NVIDIA" 'DC_SESSIONS=sway; DC_VIDEO_CARDS="nouveau nvidia"; dc_validate t amd64 true true LXDE nvidia bob' "nvidia-drivers[wayland]"
refuses "default session not installed" 'DC_DEFAULT_SESSION=sway; dc_validate t amd64 true true LXDE all-free bob' "not a session this image installs"
accepts "default session = an added WM" 'DC_SESSIONS=i3; DC_DEFAULT_SESSION=i3; dc_validate t amd64 true true xfce all-free bob'
refuses "picom is not a session" 'DC_SESSIONS=picom; DC_DEFAULT_SESSION=picom; dc_validate t amd64 true true LXDE all-free bob' "not a session this image installs"
refuses "unknown video card" 'DC_VIDEO_CARDS=iris; dc_validate t amd64 true true LXDE all-free bob' "unknown card 'iris'"
refuses "nvidia card without the nvidia driver" 'DC_VIDEO_CARDS=nvidia; dc_validate t amd64 true true LXDE all-free bob' "needs --gpu-driver nvidia"
refuses "video cards on ARM" 'DC_VIDEO_CARDS=intel; dc_validate t arm64 true false LXDE "" bob' "x86-only"
refuses "root as an extra account" 'DC_EXTRA_USERS=root; DC_EXTRA_PASS_FILE=/dev/null; dc_validate t amd64 true true LXDE all-free bob' "root, the primary account"
refuses "the primary account again" 'DC_EXTRA_USERS=bob; dc_validate t amd64 true true LXDE all-free bob' "root, the primary account"
refuses "an account without a password file" 'DC_EXTRA_USERS=ann; dc_validate t amd64 true true LXDE all-free bob' "needs --extra-local-pass-file"
printf 'ann:pw1\n' > "${TMP}/pass"
refuses "an account missing from the password file" "DC_EXTRA_USERS='ann carl'; DC_EXTRA_PASS_FILE=${TMP}/pass; dc_validate t amd64 true true LXDE all-free bob" "no password for 'carl'"
refuses "a bad account suffix" "DC_EXTRA_USERS='ann:root'; DC_EXTRA_PASS_FILE=${TMP}/pass; dc_validate t amd64 true true LXDE all-free bob" "only suffix is ':admin'"
refuses "a Flatpak remote with no URL" 'DC_FLATPAK_APPS="mine:org.example.App"; dc_validate t amd64 true true LXDE all-free bob' "not defined by --flatpak-remotes"
refuses "an http remote" 'DC_FLATPAK_REMOTES="mine=http://x/y.flatpakrepo"; dc_validate t amd64 true true LXDE all-free bob' "not NAME=https://URL"
refuses "a wildcard package.use line" 'DC_PACKAGE_USE="*/* -X"; dc_validate t amd64 true true LXDE all-free bob' "not a plain package atom"
accepts "the X USE flag (PMS allows upper case; portage asks for it by name)" 'DC_PACKAGE_USE="x11-libs/gtk+:3 X -X"; dc_validate t amd64 true true LXDE all-free bob'
refuses "a category-wildcard package.use line" 'DC_PACKAGE_USE="*/labwc -X"; dc_validate t amd64 true true LXDE all-free bob' "not a plain package atom"
refuses "a name-wildcard package.use line" 'DC_PACKAGE_USE="gui-wm/* -X"; dc_validate t amd64 true true LXDE all-free bob' "not a plain package atom"
refuses "a category-wildcard accept_keywords line" 'DC_ACCEPT_KEYWORDS="*/labwc ~amd64"; dc_validate t amd64 true true LXDE all-free bob' "not a plain package atom"
refuses "a name-wildcard accept_keywords line" 'DC_ACCEPT_KEYWORDS="gui-wm/*"; dc_validate t amd64 true true LXDE all-free bob' "not a plain package atom"
refuses "a video_cards flag in package.use" 'DC_PACKAGE_USE="media-libs/mesa video_cards_intel"; dc_validate t amd64 true true LXDE all-free bob' "Video section"
refuses "a python target in package.use" 'DC_PACKAGE_USE="dev-lang/foo python_targets_python3_12"; dc_validate t amd64 true true LXDE all-free bob' "Python section"
refuses "a USE_EXPAND spelling" 'DC_PACKAGE_USE="media-libs/mesa VIDEO_CARDS: intel"; dc_validate t amd64 true true LXDE all-free bob' "is not a USE flag"
refuses "a version with no operator" 'DC_PACKAGE_USE="media-video/ffmpeg-7.1.5 opus"; dc_validate t amd64 true true LXDE all-free bob' "not a plain package atom"
refuses "** keywords" 'DC_ACCEPT_KEYWORDS="gui-wm/labwc **"; dc_validate t amd64 true true LXDE all-free bob' "only the testing keyword ~amd64"
refuses "a foreign-arch keyword" 'DC_ACCEPT_KEYWORDS="gui-wm/labwc ~arm64"; dc_validate t amd64 true true LXDE all-free bob' "only the testing keyword ~amd64"
refuses "a free-threading single target" 'PT_SINGLE_TARGET=python3_14t; dc_validate t amd64 true true LXDE all-free bob' "cannot be the single target"

echo "== 2. fold + effective VIDEO_CARDS"
got="$(lib 'DC_SESSIONS="i3 picom sway"; DC_FLATPAK_APPS="flathub:org.a.b"; dc_fold_packages_add "app-editors/vim x11-wm/i3"')"
[ "${got}" = "app-editors/vim x11-wm/i3 x11-misc/picom gui-wm/sway sys-apps/flatpak" ] && ok "fold adds session atoms + flatpak once, keeps order" || bad "fold: '${got}'"
got="$(lib 'dc_fold_packages_add ""')"
[ -z "${got}" ] && ok "fold of nothing is nothing" || bad "fold of nothing: '${got}'"
got="$(lib 'dc_effective_video_cards "amdgpu radeonsi radeon intel iris nouveau"')"
[ "${got}" = "amdgpu radeonsi radeon intel iris nouveau" ] && ok "no override keeps the --gpu-driver matrix list" || bad "no override: '${got}'"
got="$(lib 'DC_VIDEO_CARDS="radeonsi virgl"; dc_effective_video_cards "nouveau"')"
[ "${got}" = "radeonsi radeon amdgpu virgl" ] && ok "radeonsi closes over radeon + amdgpu" || bad "closure: '${got}'"
got="$(lib 'DC_SESSIONS="i3 wayfire"; dc_client_use_extra')"
[ "${got}" = "wayland" ] && ok "a Wayland compositor adds USE=wayland" || bad "wayland use: '${got}'"
got="$(lib 'DC_SESSIONS="i3 picom"; dc_client_use_extra')"
[ -z "${got}" ] && ok "X11-only sessions add no USE" || bad "x11 use: '${got}'"

echo "== 3. portage overlay"
SR="${TMP}/sr"; SPEC="${TMP}/specs-pu"
mkdir -p "${SR}/etc/portage/package.use" "${SR}/etc/portage/package.accept_keywords" "${SPEC}"
echo "app-misc/x foo" > "${SPEC}/desktop"
lib "pcs_sync_dir '${SPEC}' '${SR}/etc/portage/package.use'
     DC_PACKAGE_USE='>=media-video/ffmpeg-7.1.5 opus x264 ; media-libs/mesa  vulkan'
     DC_ACCEPT_KEYWORDS='=media-video/obs-studio-32.2.2 ~amd64'
     dc_apply_portage_overlay '${SR}' t" >/dev/null
pu="${SR}/etc/portage/package.use/zz-hugmesh-studio"
if [ -f "${pu}" ] && grep -x '>=media-video/ffmpeg-7.1.5 opus x264' "${pu}" >/dev/null && grep -x 'media-libs/mesa vulkan' "${pu}" >/dev/null; then
    ok "package.use/zz-hugmesh-studio carries both lines, whitespace normalised"
else bad "package.use overlay: $(cat "${pu}" 2>&1)"; fi
grep -x '=media-video/obs-studio-32.2.2 ~amd64' "${SR}/etc/portage/package.accept_keywords/zz-hugmesh-studio" >/dev/null \
    && ok "package.accept_keywords/zz-hugmesh-studio carries the keyword line" || bad "keyword overlay missing"
lib "pcs_sync_dir '${SPEC}' '${SR}/etc/portage/package.use'" >/dev/null
[ ! -e "${pu}" ] && ok "a later pcs_sync_dir PRUNES the overlay (why the builders write it after the last sync)" || bad "pcs_sync_dir kept the overlay"
lib "DC_PACKAGE_USE='media-libs/mesa vulkan'; dc_apply_portage_overlay '${SR}' t; DC_PACKAGE_USE=''; DC_ACCEPT_KEYWORDS=''; dc_apply_portage_overlay '${SR}' t" >/dev/null
[ ! -e "${pu}" ] && [ ! -e "${SR}/etc/portage/package.accept_keywords/zz-hugmesh-studio" ] \
    && ok "no lines -> no overlay files (a resumed sysroot's stale copy is removed)" || bad "empty overlay left files behind"

echo "== 4. dc_bake_desktop"
SR="${TMP}/bake"; mkdir -p "${SR}/etc/lightdm"
printf '[Seat:*]\ngreeter-session=lightdm-gtk-greeter\nuser-session=LXDE\n' > "${SR}/etc/lightdm/lightdm.conf"
printf 'ann:first-Secret-1\nbob:second-Secret-2\n' > "${TMP}/pass2"
if out="$(lib "DC_DEFAULT_SESSION=i3; DC_EXTRA_USERS='ann bob:admin'; DC_EXTRA_PASS_FILE='${TMP}/pass2'
          DC_FLATPAK_APPS='flathub:org.mozilla.firefox mine:org.example.App'; DC_FLATPAK_REMOTES='mine=https://example.org/mine.flatpakrepo'
          dc_bake_desktop '${SR}' t")"; then ok "bake ran"; else bad "bake failed: ${out}"; fi
grep -x 'user-session=i3' "${SR}/etc/lightdm/lightdm.conf" >/dev/null && ok "default session rewritten" || bad "user-session not rewritten"
list="${SR}/etc/hugmesh/extra-local-users"
[ "$(stat -c %a "${list}" 2>/dev/null)" = "600" ] && ok "extra-local-users is 0600" || bad "extra-local-users mode: $(stat -c %a "${list}" 2>&1)"
if grep -a 'Secret' "${list}" >/dev/null; then bad "a plaintext password reached the image"; else ok "no plaintext password on the image"; fi
awk '$1=="ann" && $2=="false" && $3 ~ /^\$(y|6)\$/' "${list}" | grep . >/dev/null && ok "ann: not an administrator, crypt hash" || bad "ann line: $(cat "${list}")"
awk '$1=="bob" && $2=="true" && $3 ~ /^\$(y|6)\$/' "${list}" | grep . >/dev/null && ok "bob:admin -> administrator" || bad "bob line: $(cat "${list}")"
[ -x "${SR}/etc/local.d/02-extra-local-users.start" ] && ok "firstboot account script installed" || bad "firstboot script missing"
grep -E 'chage -d 0' "${SR}/etc/local.d/02-extra-local-users.start" >/dev/null && ok "first login must change the password" || bad "no chage -d 0"
grep -x 'flathub org.mozilla.firefox' "${SR}/etc/hugmesh/flatpak-apps.list" >/dev/null && grep -x 'mine org.example.App' "${SR}/etc/hugmesh/flatpak-apps.list" >/dev/null \
    && ok "flatpak-apps.list" || bad "flatpak-apps.list: $(cat "${SR}/etc/hugmesh/flatpak-apps.list" 2>&1)"
grep -x "flathub https://dl.flathub.org/repo/flathub.flatpakrepo" "${SR}/etc/hugmesh/flatpak-remotes.list" >/dev/null && grep -x 'mine https://example.org/mine.flatpakrepo' "${SR}/etc/hugmesh/flatpak-remotes.list" >/dev/null \
    && ok "flatpak-remotes.list adds flathub implicitly + the named remote" || bad "remotes: $(cat "${SR}/etc/hugmesh/flatpak-remotes.list" 2>&1)"
[ -x "${SR}/etc/init.d/hugmesh-flatpak-apps" ] && [ "$(readlink "${SR}/etc/runlevels/default/hugmesh-flatpak-apps")" = "/etc/init.d/hugmesh-flatpak-apps" ] \
    && ok "hugmesh-flatpak-apps service + default runlevel" || bad "flatpak service not installed/enabled"
SR2="${TMP}/bake-unaff"; mkdir -p "${SR2}/etc/lightdm"; cp "${SR}/etc/lightdm/lightdm.conf" "${SR2}/etc/lightdm/"
lib "DC_FLATPAK_APPS='flathub:org.mozilla.firefox'; DC_EXTRA_USERS=ann; DC_EXTRA_PASS_FILE='${TMP}/pass2'; dc_bake_desktop '${SR2}' t gentoo" >/dev/null
if [ -x "${SR2}/etc/init.d/gentoo-flatpak-apps" ] && [ -f "${SR2}/etc/gentoo/flatpak-apps.list" ] && [ ! -e "${SR2}/etc/hugmesh" ] \
    && ! grep -ai 'hugmesh' "${SR2}/etc/init.d/gentoo-flatpak-apps" "${SR2}/etc/local.d/02-extra-local-users.start" >/dev/null; then
    ok "--unaffiliated: neutral names, no HugMesh name in what it installs"
else bad "unaffiliated bake leaks the hugmesh name"; fi
SR3="${TMP}/bake-none"; mkdir -p "${SR3}/etc/lightdm"; cp "${SR}/etc/lightdm/lightdm.conf" "${SR3}/etc/lightdm/"
before="$(cd "${SR3}" && find . -type f -exec md5sum {} + | sort)"
lib "dc_bake_desktop '${SR3}' t" >/dev/null
after="$(cd "${SR3}" && find . | sort; cd "${SR3}" && find . -type f -exec md5sum {} + | sort)"
[ "$(cd "${SR3}" && find . | wc -l)" -eq 4 ] && [ "${before}" = "$(cd "${SR3}" && find . -type f -exec md5sum {} + | sort)" ] \
    && ok "no Desktop flags -> the sysroot is untouched" || bad "bake with nothing set changed the sysroot: ${after}"

echo "== 4b. first boot: the real 01-firstboot, then 02-extra-local-users, on one root"
# The EFFECT, per image shape: can an extra ':admin' account sudo (sudoers.d line, or
# wheel WITH an active %wheel line), and can a plain one not? 01 runs first in the same
# boot and touches users.created for its own account, which 02 used to read as "KEYS made
# the users" and withhold wheel on every standalone and --local-pass image.
# shellcheck source=tests/scripts/lib/firstboot-harness.sh
. "${REPO}/tests/scripts/lib/firstboot-harness.sh"
TMPL="${REPO}/specs/etc/local.d/01-firstboot.start.tmpl"
EXTRA_SRC="${EXTRA_SRC:-${REPO}/scripts/desktop-config/02-extra-local-users.start}"
FB_HASH='$y$j9T$abcdefghijklmnop$0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef'
# boot_shape NAME STANDALONE HASH KEYS(no|ungoverned|governed) BAKED_GOV(yes|no)
boot_shape() {
    local r="${TMP}/fb-$1"
    rm -rf "${r}"; make_root "${r}"
    [ "$4" != no ] && keys_provisioned "${r}" alice "$4"
    [ "$5" = yes ] && mkdir -p "${r}/etc/hugmesh/desktop-governance"
    mkdir -p "${r}/etc/hugmesh"
    printf 'ann true %s\ncarl false %s\n' "${FB_HASH}" "${FB_HASH}" > "${r}/etc/hugmesh/extra-local-users"
    render "${r}" "$3" "$2" false
    run_fb "${r}"
    render_extra "${r}"
    run_extra "${r}"
    echo "${r}"
}
# expect NAME ROOT ANN(y|n) HOW(wheel|sudoers.d|-)
expect() {
    local n="$1" r="$2" want="$3" how="$4" got
    got="$(can_sudo "${r}" ann)"
    [ "${got}" = "${want}" ] && ok "${n}: ann:admin can sudo = ${want}" \
        || bad "${n}: ann:admin can sudo = ${got}, want ${want} (groups: $(cat "${r}/groups.ann" 2>&1); out: $(tr '\n' ' ' < "${r}/extra.out"))"
    [ "$(can_sudo "${r}" carl)" = n ] && ok "${n}: carl (no :admin) cannot sudo" || bad "${n}: carl can sudo"
    case "${how}" in
        wheel)     grep -qE '(^|[:,])wheel(,|$)' "${r}/groups.ann" && [ -z "$(ls -A "${r}/etc/sudoers.d" 2>/dev/null)" ] \
                       && ok "${n}: granted through wheel, no sudoers.d file" || bad "${n}: not a wheel grant" ;;
        sudoers.d) ! grep -qE '(^|[:,])wheel(,|$)' "${r}/groups.ann" && [ "$(stat -c %a "${r}/etc/sudoers.d/90-local-ann" 2>/dev/null)" = 440 ] \
                       && ! grep -q '^%wheel' "${r}/etc/sudoers" \
                       && ok "${n}: granted through sudoers.d/90-local-ann (0440), not wheel, no %wheel line added" || bad "${n}: not a sudoers.d grant" ;;
        -)         ! grep -qE '(^|[:,])wheel(,|$)' "${r}/groups.ann" && [ ! -e "${r}/etc/sudoers.d/90-local-ann" ] \
                       && ok "${n}: no wheel, no sudoers.d grant" || bad "${n}: a grant landed on a governed image" ;;
    esac
    if [ "${want}" = y ]; then
        grep -q 'ann created (administrator, via ' "${r}/extra.out" && ok "${n}: says administrator" || bad "${n}: no administrator line: $(cat "${r}/extra.out")"
    else
        ! grep -q 'administrator, via' "${r}/extra.out" && grep -q 'NOT made an administrator' "${r}/extra.out" \
            && ok "${n}: says NOT an administrator, never '(administrator)'" || bad "${n}: wrong message: $(cat "${r}/extra.out")"
    fi
    [ ! -e "${r}/etc/hugmesh/extra-local-users" ] && ok "${n}: list removed after success" || bad "${n}: list left behind"
}
expect "standalone + --local-pass"        "$(boot_shape sa-pass true  "${FB_HASH}" no no)" y wheel
expect "standalone, no --local-pass"      "$(boot_shape sa-nopass true "" no no)" y wheel
expect "mesh keyless + --local-pass"      "$(boot_shape m-pass false "${FB_HASH}" no no)" y wheel
expect "mesh keyless, no --local-pass"    "$(boot_shape m-nopass false "" no no)" y wheel
expect "KEYS (ungoverned) + --local-pass" "$(boot_shape keys-pass false "${FB_HASH}" ungoverned no)" y sudoers.d
expect "KEYS (ungoverned), no local pass" "$(boot_shape keys-nopass false "" ungoverned no)" y sudoers.d
expect "governed from the KEYS stick"     "$(boot_shape gov-keys false "${FB_HASH}" governed no)" n -
expect "governed, templates baked"        "$(boot_shape gov-baked false "" ungoverned yes)" n -

echo "== 5. Python targets"
PS="${TMP}/py"; mkdir -p "${PS}/etc/portage/package.use" "${PS}/usr/lib/python3.13" "${PS}/var/db/pkg/dev-lang/python-3.13.5"
echo 'python_targets_python3_13 python_single_target_python3_13' > "${PS}/var/db/pkg/dev-lang/python-3.13.5/USE"
echo 'USE="x"' > "${PS}/etc/portage/make.conf"
lib "pt_apply_seed_targets '${PS}' t" >/dev/null
seed_line="$(grep '^PYTHON_TARGETS=' "${PS}/etc/portage/make.conf")"
lib "PT_EXTRA_TARGETS='python3_14 python3_12'; PT_SINGLE_TARGET=python3_14; pt_apply_seed_targets '${PS}' t" >/dev/null
grep -x 'PYTHON_TARGETS="python3_12 python3_13 python3_14"' "${PS}/etc/portage/make.conf" >/dev/null \
    && ok "extras WIDEN the seed set (${seed_line} + extras, sorted)" || bad "union: $(grep PYTHON_ "${PS}/etc/portage/make.conf")"
grep -x 'PYTHON_SINGLE_TARGET="python3_14"' "${PS}/etc/portage/make.conf" >/dev/null && ok "single target honoured" || bad "single: $(grep PYTHON_SINGLE "${PS}/etc/portage/make.conf")"
[ "$(grep -c '^PYTHON_TARGETS=' "${PS}/etc/portage/make.conf")" = 1 ] && ok "one assignment, never two" || bad "duplicate assignments"
if out="$(lib "PT_SINGLE_TARGET=python3_15; pt_apply_seed_targets '${PS}' t")"; then bad "a single target outside the set was accepted"
else case "${out}" in *"is not in PYTHON_TARGETS"*) ok "a single target outside the set fails";; *) bad "single outside: ${out}";; esac; fi

echo "== 6. scripts/_pretend-lib.sh against a stub emerge"
STUB="${TMP}/stub"; mkdir -p "${STUB}"
mkconf() { printf 'PYTHON_TARGETS="python3_13 python3_14"\nVIDEO_CARDS="amdgpu radeonsi"\n' > "${TMP}/make.conf"; }
mkconf
pretend() { # FIXTURE RC -> runs run+report with a stub emerge, prints output, returns report rc
    cat > "${STUB}/emerge" <<STUBEOF
#!/bin/bash
cat "${REPO}/tests/scripts/fixtures/desktop-pretend/$1"
exit $2
STUBEOF
    chmod +x "${STUB}/emerge"
    ( PATH="${STUB}:${PATH}"
      # shellcheck source=/dev/null
      . "${REPO}/scripts/_pretend-lib.sh"
      _hugmesh_pretend_conf_list() { local v; v="$(grep -a -E "^$1=" "${TMP}/make.conf" | tail -n 1)"; v="${v#*=}"; v="${v//\"/}"; printf '%s' "${v// /,}"; }
      rc=0; hugmesh_pretend_run "${TMP}/p.log" @world media-video/obs-studio || rc=$?
      hugmesh_pretend_report "${TMP}/p.log" "${rc}" )
}
out="$(pretend needs.txt 1)"; rc=$?
[ "${rc}" = 3 ] && ok "needs -> exit 3" || bad "needs rc=${rc}"
printf '%s\n' "${out}" | grep -x '==> Pretend result: status=needs rc=1 seed_python=python3_13,python3_14 video_cards=amdgpu,radeonsi' >/dev/null \
    && ok "result line" || bad "result line: $(printf '%s\n' "${out}" | grep 'Pretend result')"
printf '%s\n' "${out}" | grep -x '==> Pretend needs: accept_keywords =media-video/obs-studio-32.2.2 ~amd64' >/dev/null && ok "keyword need" || bad "keyword need missing"
printf '%s\n' "${out}" | grep -x '==> Pretend needs: package.use >=media-video/ffmpeg-7.1.5 opus x264' >/dev/null && ok "USE need" || bad "USE need missing"
[ "$(printf '%s\n' "${out}" | grep -c '^==> Pretend needs: ')" = 2 ] && ok "exactly the two needs (comments, '(see' and the trailer are not needs)" || bad "needs count: $(printf '%s\n' "${out}" | grep '^==> Pretend needs')"
printf '%s\n' "${out}" | grep -x '===== END PRETEND RESOLVER OUTPUT =====' >/dev/null && ok "resolver excerpt framed" || bad "no excerpt frame"
out="$(pretend clean.txt 0)"; rc=$?
[ "${rc}" = 0 ] && printf '%s\n' "${out}" | grep '^==> Pretend result: status=clean ' >/dev/null && ok "clean -> exit 0" || bad "clean rc=${rc}"
# clean-real.txt is the REAL --verbose resolver output of the first pretend run
# (standalone-thin, 2026-11-11; "Total: 687 packages ..."), not a hand-written one
out="$(pretend clean-real.txt 0)"; rc=$?
[ "${rc}" = 0 ] && printf '%s\n' "${out}" | grep '^==> Pretend result: status=clean ' >/dev/null \
    && ok "the real run's output reads as clean" || bad "real clean output rc=${rc}"
out="$(pretend clean.txt 124)"; rc=$?
[ "${rc}" = 1 ] && printf '%s\n' "${out}" | grep '^==> Pretend result: status=error rc=124' >/dev/null && ok "a timeout (rc 124) is error even with a plan line" || bad "timeout rc=${rc}"
out="$(pretend slot-conflict.txt 1)"; rc=$?
[ "${rc}" = 1 ] && ok "a slot conflict that names no change is error, never clean" || bad "slot conflict rc=${rc}"
out="$(pretend empty.txt 0)"; rc=$?
[ "${rc}" = 1 ] && ok "an empty log with exit 0 is error (no positive evidence)" || bad "empty rc=${rc}"
out="$(pretend needs-nul.bin 1 2>/dev/null)"; rc=$?
[ "${rc}" = 3 ] && printf '%s\n' "${out}" | grep -x '==> Pretend needs: package.use >=media-video/ffmpeg-7.1.5 opus x264' >/dev/null \
    && ok "a NUL byte in the log does not blind the parser" || bad "NUL log rc=${rc}"
# needs-real-obs-r1/r2.txt are the REAL resolver output of the 2026-11-11 OBS rounds
# (standalone-thin + native media-video/obs-studio). Portage listed the keyword change
# but put the ffmpeg USE wall in its OTHER form, a "(Change USE: +opus +x264)" hint
# under "!!! One of the following packages is required"; the parser missed it, round 1
# applied the keyword only, and round 2 came back "error" with nothing to apply.
out="$(pretend needs-real-obs-r1.txt 1)"; rc=$?
[ "${rc}" = 3 ] && ok "real OBS round 1 -> needs" || bad "real OBS round 1 rc=${rc}"
printf '%s\n' "${out}" | grep -x '==> Pretend needs: accept_keywords =media-video/obs-studio-32.2.2 ~amd64' >/dev/null \
    && ok "real OBS round 1: the keyword change" || bad "real OBS round 1: no keyword need"
printf '%s\n' "${out}" | grep -x '==> Pretend needs: package.use >=media-video/ffmpeg-8.1.2 opus x264' >/dev/null \
    && ok "real OBS round 1: the USE wall from portage's (Change USE: ...) hint" || bad "real OBS round 1: USE hint not read"
[ "$(printf '%s\n' "${out}" | grep -c '^==> Pretend needs: ')" = 2 ] && ok "real OBS round 1: exactly two needs" \
    || bad "real OBS round 1 needs: $(printf '%s\n' "${out}" | grep '^==> Pretend needs')"
out="$(pretend needs-real-obs-r2.txt 1)"; rc=$?
[ "${rc}" = 3 ] && [ "$(printf '%s\n' "${out}" | grep -c '^==> Pretend needs: ')" = 1 ] \
    && printf '%s\n' "${out}" | grep -x '==> Pretend needs: package.use >=media-video/ffmpeg-8.1.2 opus x264' >/dev/null \
    && ok "real OBS round 2 (keyword applied): the USE hint alone is a need, not an error" || bad "real OBS round 2 rc=${rc}: ${out%%=====*}"
out="$(pretend hint-violates.txt 1)"; rc=$?
[ "${rc}" = 1 ] && ! printf '%s\n' "${out}" | grep '^==> Pretend needs: ' >/dev/null \
    && ok "a hint that would violate REQUIRED_USE is not named (error, the operator decides)" || bad "violating hint rc=${rc}"
out="$(pretend hint-alternatives.txt 1)"; rc=$?
[ "${rc}" = 3 ] && [ "$(printf '%s\n' "${out}" | grep -c '^==> Pretend needs: ')" = 1 ] \
    && printf '%s\n' "${out}" | grep -x '==> Pretend needs: package.use >=media-libs/libbar-3.1-r1 gtk -static' >/dev/null \
    && ok "the hint's FIRST alternative only (the dependency, not the parent), a -flag kept, a dash line outside the block ignored" \
    || bad "alternatives rc=${rc}: $(printf '%s\n' "${out}" | grep '^==> Pretend needs')"
# synthetic scoping guard: a "- ... (Change USE: ...)" line that does not DIRECTLY follow
# the header is not part of portage's list
out="$(pretend hint-out-of-block.txt 1)"; rc=$?
[ "${rc}" = 1 ] && ! printf '%s\n' "${out}" | grep '^==> Pretend needs: ' >/dev/null \
    && ok "a hint line that does not directly follow the header is not named" || bad "out-of-block hint rc=${rc}"

echo "== 7. builder wiring (static)"
ALL=(build-x86-host-stage4.sh build-rpi5-stage4.sh build-jetson-stage4.sh build-frite-stage4.sh build-orangepi5-stage4.sh build-orangepi4-lts-stage4.sh)
for b in "${ALL[@]}"; do
    f="${REPO}/${b}"
    parse="$(awk '/^while \[\[ \$# -gt 0 \]\]/{on=1} on{print} on&&/^done/{exit}' "${f}")"
    miss=""
    for flag in --default-session --extra-local-users --extra-local-pass-file --flatpak-apps --flatpak-remotes \
                --python-extra-targets --python-single-target --package-use --accept-keywords; do
        printf '%s\n' "${parse}" | grep -E "^[[:space:]]+${flag}\)" >/dev/null || miss="${miss} ${flag}"
    done
    [ -z "${miss}" ] && ok "${b}: parses the Desktop-step flags" || bad "${b}: does not parse${miss}"
    ov="$(grep -n '^dc_apply_portage_overlay ' "${f}" | head -1 | cut -d: -f1)"
    pt="$(grep -n '^pt_apply_seed_targets ' "${f}" | head -1 | cut -d: -f1)"
    last_sync="$(grep -n 'pcs_sync_dir .*package\.\(use\|accept_keywords\)"' "${f}" | tail -1 | cut -d: -f1)"
    if [ -n "${ov}" ] && [ -n "${pt}" ] && [ -n "${last_sync}" ] && [ "${last_sync}" -lt "${ov}" ] && [ "${ov}" -lt "${pt}" ]; then
        ok "${b}: overlay after the last package.use/accept_keywords sync, before pt_apply_seed_targets"
    else bad "${b}: overlay order (sync=${last_sync} overlay=${ov} pt_apply=${pt})"; fi
    lt="$(grep -n '^LIGHTDM$' "${f}" | head -1 | cut -d: -f1)"
    bk="$(grep -n 'dc_bake_desktop "${SYSROOT}"' "${f}" | head -1 | cut -d: -f1)"
    [ -n "${lt}" ] && [ -n "${bk}" ] && [ "${bk}" -gt "${lt}" ] && [ "${bk}" -le $((lt + 3)) ] \
        && ok "${b}: bakes right after its lightdm.conf heredoc" || bad "${b}: bake placement (LIGHTDM=${lt} bake=${bk})"
    va="$(grep -n '^dc_validate ' "${f}" | head -1 | cut -d: -f1)"
    pa="$(grep -n '^_validate_pkg_atoms --packages-add' "${f}" | head -1 | cut -d: -f1)"
    [ -n "${va}" ] && [ -n "${pa}" ] && [ "${va}" -lt "${pa}" ] && ok "${b}: validates before the atom check" || bad "${b}: validate order"
done
X86="${REPO}/build-x86-host-stage4.sh"
xparse="$(awk '/^while \[\[ \$# -gt 0 \]\]/{on=1} on{print} on&&/^done/{exit}' "${X86}")"
for flag in --desktop-sessions --video-cards --pretend-only; do
    printf '%s\n' "${xparse}" | grep -E "^[[:space:]]+${flag}\)" >/dev/null && ok "x86 parses ${flag}" || bad "x86 does not parse ${flag}"
done
pr="$(grep -n '^if \${PRETEND_ONLY}; then' "${X86}" | cut -d: -f1)"
ch="$(grep -n '^chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT' "${X86}" | head -1 | cut -d: -f1)"
[ -n "${pr}" ] && [ -n "${ch}" ] && [ "${pr}" -lt "${ch}" ] && ok "--pretend-only exits before the payload chroot" || bad "pretend branch order (pretend=${pr} chroot=${ch})"
body="$(awk '/chroot .*<<PRETEND/{on=1;next} on&&/^PRETEND$/{exit} on{print}' "${X86}")"
[ -n "${body}" ] || bad "no PRETEND heredoc"
if printf '%s\n' "${body}" | grep -F -e '`' -e '$(' >/dev/null; then bad "PRETEND heredoc has a backtick or dollar-paren"; else ok "PRETEND heredoc: no backticks / dollar-parens"; fi
printf '%s\n' "${body}" | grep -F 'hugmesh_pretend_report /tmp/hugmesh-pretend.log "\${_rc}"' >/dev/null \
    && ok "PRETEND heredoc reports with the chroot-side rc escaped" || bad "PRETEND heredoc report line"
pbody="$(awk '/^if \$\{PRETEND_ONLY\}; then/{on=1} on{print} on&&/^    exit "\$\{_pretend_rc\}"$/{exit}' "${X86}")"
um="$(printf '%s\n' "${pbody}" | grep -n 'umount_chroot; trap - EXIT' | head -1 | cut -d: -f1)"
rmn="$(printf '%s\n' "${pbody}" | grep -n 'rm -rf --one-file-system "${BUILD_ROOT}"' | head -1 | cut -d: -f1)"
[ -n "${um}" ] && [ -n "${rmn}" ] && [ "${um}" -lt "${rmn}" ] \
    && ok "pretend removes its throwaway tree only AFTER detaching the chroot mounts" || bad "pretend cleanup order (umount=${um} rm=${rmn})"
printf '%s\n' "${pbody}" | grep -E '^        pretend-\*\)' >/dev/null && printf '%s\n' "${pbody}" | grep -F 'hmr_stale_mounts "${SYSROOT}"' >/dev/null \
    && ok "pretend removes only a pretend-* tree, and only with nothing left mounted" || bad "pretend cleanup guards missing"
# The subdir guard, run for real: --pretend-only rm -rf's WORK_DIR/BUILD_SUBDIR afterwards.
sguard="$(awk '/^case "\$\{PRETEND_ONLY\}:\$\{BUILD_SUBDIR\}" in$/{on=1} on{print} on&&/^esac$/{exit}' "${X86}")"
if [ -z "${sguard}" ]; then bad "pretend --build-subdir guard not found"; else
    for sd in 'pretend-x/../..' '../x' 'pretend-a/b' '..' '.' '' 'pretend-..'; do
        if ( err(){ :; }; PRETEND_ONLY=true; BUILD_SUBDIR="${sd}"; eval "${sguard}"; exit 0 ); then
            bad "pretend --build-subdir '${sd}' accepted"; else ok "pretend --build-subdir '${sd}' refused"; fi
    done
    for sd in 'pretend-1a2b3c4d' 'snap-build-x86'; do
        ( err(){ :; }; PRETEND_ONLY=true; BUILD_SUBDIR="${sd}"; eval "${sguard}"; exit 0 ) \
            && ok "pretend --build-subdir '${sd}' accepted" || bad "pretend --build-subdir '${sd}' refused"
    done
    ( err(){ :; }; PRETEND_ONLY=false; BUILD_SUBDIR='a/b'; eval "${sguard}"; exit 0 ) \
        && ok "a real build's --build-subdir is not this guard's business" || bad "guard fires without --pretend-only"
fi
grep -F -- '--pretend --verbose' "${REPO}/scripts/_pretend-lib.sh" >/dev/null \
    && ok "pretend asks for --verbose (portage prints Total: only then)" || bad "pretend lib lost --verbose"
for lib_f in scripts/_desktop-config-lib.sh scripts/_pretend-lib.sh; do
    bash -n "${REPO}/${lib_f}" && ok "${lib_f}: bash -n" || bad "${lib_f}: syntax"
done

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
