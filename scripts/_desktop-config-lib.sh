# _desktop-config-lib.sh — the Studio "Desktop" step's builder half. Sourced by
# every DESKTOP-producing stage4 builder (x86, rpi5, jetson, frite, orangepi5,
# orangepi4-lts) next to the other shared libs. Sourced, not executed.
#
# The Studio's Desktop step (studio/hugmesh_studio/core/desktop_spec.py) gathers,
# per build: extra window managers / compositors, the default greeter session, a
# VIDEO_CARDS override, extra local accounts, apps (native or Flatpak), Python
# targets and a small portage overlay (package.use / package.accept_keywords
# lines). This lib is the ONE place every builder turns those flags into image
# content, so the six builders cannot drift on what a flag means.
#
# EVERY FLAG DEFAULTS TO "EMIT NOTHING": with no DC_* variable set, no function
# here writes a file, folds an atom or prints a line, so an image built without
# the Desktop step is byte-identical to one built before this lib existed.
#
# Each flag is SINGLE-VALUED (last one wins, like --packages-add): a list rides
# one argv word, separated by spaces, or by ';' for the overlay lines (each of
# which has spaces in it).
#
#   --desktop-sessions "i3 picom sway"   x86 only   DC_SESSIONS
#   --default-session NAME               all six    DC_DEFAULT_SESSION
#   --video-cards "intel i915"           x86 only   DC_VIDEO_CARDS
#   --extra-local-users "ann bob:admin"  all six    DC_EXTRA_USERS
#   --extra-local-pass-file FILE         all six    DC_EXTRA_PASS_FILE (NAME:PASSWORD lines)
#   --flatpak-apps "flathub:org.x.Y"     all six    DC_FLATPAK_APPS
#   --flatpak-remotes "name=https://.."  all six    DC_FLATPAK_REMOTES
#   --python-extra-targets "python3_13"  all six    PT_EXTRA_TARGETS (read by _python-targets-lib.sh)
#   --python-single-target python3_13    all six    PT_SINGLE_TARGET (read by _python-targets-lib.sh)
#   --package-use "ATOM FLAGS;..."       all six    DC_PACKAGE_USE
#   --accept-keywords "ATOM ~arch;..."   all six    DC_ACCEPT_KEYWORDS
#
# HEREDOC SAFETY: nothing here is pasted into a <<CHROOT heredoc; the files it
# writes are written from the host shell.

DC_SESSIONS="${DC_SESSIONS:-}"
DC_DEFAULT_SESSION="${DC_DEFAULT_SESSION:-}"
DC_VIDEO_CARDS="${DC_VIDEO_CARDS:-}"
DC_EXTRA_USERS="${DC_EXTRA_USERS:-}"
DC_EXTRA_PASS_FILE="${DC_EXTRA_PASS_FILE:-}"
DC_FLATPAK_APPS="${DC_FLATPAK_APPS:-}"
DC_FLATPAK_REMOTES="${DC_FLATPAK_REMOTES:-}"
DC_PACKAGE_USE="${DC_PACKAGE_USE:-}"
DC_ACCEPT_KEYWORDS="${DC_ACCEPT_KEYWORDS:-}"
PT_EXTRA_TARGETS="${PT_EXTRA_TARGETS:-}"
PT_SINGLE_TARGET="${PT_SINGLE_TARGET:-}"

_DC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── the session map: name -> atom|session-file|kind ───────────────────────────
# kind: x11 = an X11 window manager with a /usr/share/xsessions entry,
#       wayland = a Wayland compositor with a /usr/share/wayland-sessions entry,
#       compositor = an X11 compositor (no session of its own).
# studio/hugmesh_studio/core/desktop_spec.py SESSION_CATALOG mirrors this table
# and studio/tests/test_desktop_spec.py reads THIS function to prove they agree.
dc_session_map() {
    cat <<'MAP'
openbox x11-wm/openbox openbox x11
i3 x11-wm/i3 i3 x11
picom x11-misc/picom - compositor
sway gui-wm/sway sway wayland
wayfire gui-wm/wayfire wayfire wayland
labwc gui-wm/labwc labwc wayland
MAP
}

# The VIDEO_CARDS tokens an override may name. Mesa 26 spells Intel "intel"
# (iris/crocus/anv) plus "i915", VM virtio-gpu "virgl", VMware "vmware";
# "lavapipe"/"zink" are Mesa's software Vulkan and GL-on-Vulkan.
DC_VIDEO_CARD_TOKENS="intel i915 amdgpu radeonsi radeon nouveau nvidia virgl vmware lavapipe zink"

_dc_err() { printf '[%s] ERROR: %s\n' "${_DC_TAG:-desktop-config}" "$1" >&2; }
_dc_info() { printf '[%s] %s\n' "${_DC_TAG:-desktop-config}" "$1"; }

# _dc_session_field NAME FIELD(2=atom 3=session 4=kind) -> value, rc 1 if unknown
_dc_session_field() {
    local name="$1" field="$2" line
    line="$(dc_session_map | awk -v n="${name}" '$1 == n')"
    [ -n "${line}" ] || return 1
    printf '%s\n' "${line}" | awk -v f="${field}" '{print $f}'
}

# dc_any_set -> 0 when at least one Desktop-step flag was given
dc_any_set() {
    [ -n "${DC_SESSIONS}${DC_DEFAULT_SESSION}${DC_VIDEO_CARDS}${DC_EXTRA_USERS}" ] && return 0
    [ -n "${DC_EXTRA_PASS_FILE}${DC_FLATPAK_APPS}${DC_FLATPAK_REMOTES}" ] && return 0
    [ -n "${DC_PACKAGE_USE}${DC_ACCEPT_KEYWORDS}${PT_EXTRA_TARGETS}${PT_SINGLE_TARGET}" ] && return 0
    return 1
}

# dc_wayland_selected -> 0 when a Wayland compositor is among DC_SESSIONS
dc_wayland_selected() {
    local s
    for s in ${DC_SESSIONS}; do
        [ "$(_dc_session_field "${s}" 4)" = "wayland" ] && return 0
    done
    return 1
}

# ── portage overlay grammar ──────────────────────────────────────────────────
# An atom as portage prints it in an autounmask suggestion: an optional
# operator, category/name, an optional version (REQUIRED with an operator, and
# only with one) and an optional :slot. No '*' anywhere: a wildcard line would
# apply to every package, which is exactly what this overlay must never do.
_DC_ATOM_PLAIN='^[a-z0-9][a-z0-9+._-]*/[A-Za-z0-9+_][A-Za-z0-9+_-]*(:[A-Za-z0-9+._-]+(/[A-Za-z0-9+._-]+)?)?$'
_DC_ATOM_VER='^(>=|<=|=|~|<|>)[a-z0-9][a-z0-9+._-]*/[A-Za-z0-9+_][A-Za-z0-9+_-]*-[0-9][0-9.]*[a-z]?(_(alpha|beta|pre|rc|p)[0-9]*)*(-r[0-9]+)?(:[A-Za-z0-9+._-]+(/[A-Za-z0-9+._-]+)?)?$'
_DC_USE_FLAG='^-?[A-Za-z0-9][A-Za-z0-9+_@.-]*$'

dc_valid_atom() {
    [[ "$1" =~ ${_DC_ATOM_PLAIN} ]] || [[ "$1" =~ ${_DC_ATOM_VER} ]]
}

# dc_check_use_line "ATOM FLAG..." -> 0 valid, 1 (with a reason on stderr) not
dc_check_use_line() {
    local line="$1" atom flag
    local -a words
    read -ra words <<< "${line}"
    [ "${#words[@]}" -ge 2 ] || { _dc_err "package.use line '${line}': want ATOM FLAG [FLAG...]"; return 1; }
    atom="${words[0]}"
    dc_valid_atom "${atom}" || { _dc_err "package.use line '${line}': '${atom}' is not a plain package atom (no wildcards)"; return 1; }
    for flag in "${words[@]:1}"; do
        [[ "${flag}" =~ ${_DC_USE_FLAG} ]] || { _dc_err "package.use line '${line}': '${flag}' is not a USE flag"; return 1; }
        case "${flag#-}" in
            video_cards_*)
                _dc_err "package.use line '${line}': video_cards_* belongs to the Video section (--video-cards), never to one package"; return 1 ;;
            python_targets_*|python_single_target_*)
                _dc_err "package.use line '${line}': Python targets belong to the Python section"; return 1 ;;
        esac
    done
    return 0
}

# dc_check_keyword_line "ATOM [~arch]" ARCH -> 0 valid, 1 not
dc_check_keyword_line() {
    local line="$1" arch="$2"
    local -a words
    read -ra words <<< "${line}"
    [ "${#words[@]}" -ge 1 ] && [ "${#words[@]}" -le 2 ] \
        || { _dc_err "accept_keywords line '${line}': want ATOM [~${arch}]"; return 1; }
    dc_valid_atom "${words[0]}" \
        || { _dc_err "accept_keywords line '${line}': '${words[0]}' is not a plain package atom (no wildcards)"; return 1; }
    if [ "${#words[@]}" -eq 2 ] && [ "${words[1]}" != "~${arch}" ]; then
        _dc_err "accept_keywords line '${line}': only the testing keyword ~${arch} may be accepted here (no '**', no other arch)"
        return 1
    fi
    return 0
}

# _dc_lines VALUE -> one trimmed, non-empty line per ';'-separated entry
_dc_lines() {
    printf '%s\n' "$1" | tr ';' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' | grep -av '^$' || true
}

# ── dc_validate TAG ARCH IS_DESKTOP IS_X86 [DE_SESSION] [GPU_DRIVER] [PRIMARY_USER] ──
# Fails (rc 1, one ERROR line per problem) on anything the image could not
# honour. Called right after the builder knows its role, before any download.
#   ARCH        amd64 | arm64 (the testing keyword an overlay may accept)
#   IS_DESKTOP  true when this build produces a desktop (lightdm) image
#   IS_X86      true on build-x86-host-stage4.sh (sessions + video cards)
#   DE_SESSION  the desktop environment's own session (LXDE, xfce, plasmax11)
dc_validate() {
    _DC_TAG="$1"
    local arch="$2" is_desktop="$3" is_x86="$4" de_session="${5:-LXDE}"
    local gpu_driver="${6:-}" primary="${7:-}"
    local bad=0 s kind tok line name admin seen="" remote ref
    dc_any_set || return 0
    if [ "${is_desktop}" != "true" ]; then
        _dc_err "Desktop-step flags (--desktop-sessions/--default-session/--video-cards/--extra-local-users/--flatpak-apps/--python-*/--package-use/--accept-keywords) need a desktop image; this role builds none"
        return 1
    fi
    # sessions (x86 only in this phase)
    if [ -n "${DC_SESSIONS}" ]; then
        if [ "${is_x86}" != "true" ]; then
            _dc_err "--desktop-sessions is x86-only for now; this board ships its LXDE session only"
            bad=1
        fi
        for s in ${DC_SESSIONS}; do
            kind="$(_dc_session_field "${s}" 4)" || { _dc_err "--desktop-sessions: unknown session '${s}' (known: $(dc_session_map | awk '{print $1}' | tr '\n' ' '))"; bad=1; continue; }
            case " ${seen} " in *" ${s} "*) _dc_err "--desktop-sessions: '${s}' named twice"; bad=1 ;; esac
            seen="${seen} ${s}"
            : "${kind}"
        done
        case " ${DC_SESSIONS} " in
            *" picom "*)
                # picom composites for an X11 WM that has none of its own. Plasma's
                # kwin composites already: picom next to Plasma alone is a conflict.
                if [ "${de_session}" = "plasmax11" ]; then
                    case " ${DC_SESSIONS} " in
                        *" i3 "*|*" openbox "*) ;;
                        *) _dc_err "--desktop-sessions: picom needs an X11 window manager without a compositor (LXDE/openbox or i3); Plasma's kwin already composites"; bad=1 ;;
                    esac
                fi ;;
        esac
        if dc_wayland_selected && [ "${gpu_driver}" = "nvidia" ]; then
            _dc_err "--desktop-sessions: a Wayland compositor with the proprietary NVIDIA driver needs nvidia-drivers[wayland] + kernel modesetting, which this builder does not set up yet; pick an X11 session or --gpu-driver nvidia-free"
            bad=1
        fi
    fi
    # default session: must be one this image installs
    if [ -n "${DC_DEFAULT_SESSION}" ]; then
        local allowed="${de_session} openbox"
        for s in ${DC_SESSIONS}; do
            tok="$(_dc_session_field "${s}" 3 2>/dev/null)" || continue
            [ "${tok}" = "-" ] || allowed="${allowed} ${tok}"
        done
        case " ${allowed} " in
            *" ${DC_DEFAULT_SESSION} "*) ;;
            *) _dc_err "--default-session '${DC_DEFAULT_SESSION}' is not a session this image installs (installed: ${allowed})"; bad=1 ;;
        esac
    fi
    # video cards (x86 only)
    if [ -n "${DC_VIDEO_CARDS}" ]; then
        if [ "${is_x86}" != "true" ]; then
            _dc_err "--video-cards is x86-only: this board's GPU is fixed by its SoC"
            bad=1
        fi
        for tok in ${DC_VIDEO_CARDS}; do
            case " ${DC_VIDEO_CARD_TOKENS} " in
                *" ${tok} "*) ;;
                *) _dc_err "--video-cards: unknown card '${tok}' (known: ${DC_VIDEO_CARD_TOKENS})"; bad=1 ;;
            esac
        done
        case " ${DC_VIDEO_CARDS} " in
            *" nvidia "*) [ "${gpu_driver}" = "nvidia" ] || { _dc_err "--video-cards nvidia needs --gpu-driver nvidia (the proprietary driver)"; bad=1; } ;;
            *) [ "${gpu_driver}" = "nvidia" ] && { _dc_err "--gpu-driver nvidia needs 'nvidia' in --video-cards"; bad=1; } ;;
        esac
    fi
    if dc_wayland_selected && [ "${is_x86}" = "true" ] && [ -z "${DC_VIDEO_CARDS}" ] \
        && { [ -z "${gpu_driver}" ] || [ "${gpu_driver}" = "none" ]; }; then
        _dc_err "--desktop-sessions: a Wayland compositor needs at least one Mesa video card (--video-cards or a --gpu-driver other than none)"
        bad=1
    fi
    # extra local accounts
    seen=""
    for tok in ${DC_EXTRA_USERS}; do
        name="${tok%%:*}"; admin=""
        [ "${tok}" = "${name}" ] || admin="${tok#*:}"
        if ! [[ "${name}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            _dc_err "--extra-local-users: '${name}' is not a valid login name"; bad=1; continue
        fi
        case "${admin}" in ""|admin) ;; *) _dc_err "--extra-local-users: '${tok}': the only suffix is ':admin'"; bad=1 ;; esac
        case " root ${primary} ${seen} " in
            *" ${name} "*) _dc_err "--extra-local-users: '${name}' is root, the primary account or named twice"; bad=1 ;;
        esac
        seen="${seen} ${name}"
    done
    if [ -n "${DC_EXTRA_USERS}" ]; then
        if [ -z "${DC_EXTRA_PASS_FILE}" ] || [ ! -r "${DC_EXTRA_PASS_FILE}" ]; then
            _dc_err "--extra-local-users needs --extra-local-pass-file (NAME:PASSWORD lines; the passwords never ride argv)"
            bad=1
        else
            for name in ${seen}; do
                grep -aq "^${name}:." "${DC_EXTRA_PASS_FILE}" \
                    || { _dc_err "--extra-local-pass-file has no password for '${name}'"; bad=1; }
            done
        fi
    fi
    # flatpak remotes + apps
    for tok in ${DC_FLATPAK_REMOTES}; do
        [[ "${tok}" =~ ^[a-z0-9][a-z0-9-]*=https://[A-Za-z0-9._~:/?#@!\&+,=%-]+$ ]] \
            || { _dc_err "--flatpak-remotes: '${tok}' is not NAME=https://URL"; bad=1; }
    done
    for tok in ${DC_FLATPAK_APPS}; do
        remote="${tok%%:*}"; ref="${tok#*:}"
        if [ "${remote}" = "${tok}" ] || ! [[ "${remote}" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
            || ! [[ "${ref}" =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$ ]]; then
            _dc_err "--flatpak-apps: '${tok}' is not REMOTE:app.id (e.g. flathub:org.mozilla.firefox)"; bad=1; continue
        fi
        if [ "${remote}" != "flathub" ]; then
            case " ${DC_FLATPAK_REMOTES} " in
                *" ${remote}="*) ;;
                *) _dc_err "--flatpak-apps: remote '${remote}' is not defined by --flatpak-remotes"; bad=1 ;;
            esac
        fi
    done
    # python
    for tok in ${PT_EXTRA_TARGETS}; do
        [[ "${tok}" =~ ^python3_[0-9]{1,2}t?$ ]] || { _dc_err "--python-extra-targets: '${tok}' is not a python3_NN target"; bad=1; }
    done
    if [ -n "${PT_SINGLE_TARGET}" ]; then
        [[ "${PT_SINGLE_TARGET}" =~ ^python3_[0-9]{1,2}$ ]] \
            || { _dc_err "--python-single-target: '${PT_SINGLE_TARGET}' is not a python3_NN target (free-threading 't' targets cannot be the single target)"; bad=1; }
    fi
    # portage overlay
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        dc_check_use_line "${line}" || bad=1
    done < <(_dc_lines "${DC_PACKAGE_USE}")
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        dc_check_keyword_line "${line}" "${arch}" || bad=1
    done < <(_dc_lines "${DC_ACCEPT_KEYWORDS}")
    [ "${bad}" -eq 0 ]
}

# dc_fold_packages_add CURRENT -> CURRENT plus the session atoms and, with any
# Flatpak app, sys-apps/flatpak; no duplicates, order kept.
dc_fold_packages_add() {
    local out="$1" s atom
    for s in ${DC_SESSIONS}; do
        atom="$(_dc_session_field "${s}" 2)" || continue
        case " ${out} " in *" ${atom} "*) ;; *) out="${out:+${out} }${atom}" ;; esac
    done
    if [ -n "${DC_FLATPAK_APPS}" ]; then
        case " ${out} " in *" sys-apps/flatpak "*) ;; *) out="${out:+${out} }sys-apps/flatpak" ;; esac
    fi
    printf '%s\n' "${out}"
}

# dc_effective_video_cards MATRIX_LIST -> the card list make.conf renders.
# No override: the --gpu-driver matrix list, untouched. An override replaces it,
# closed under the same rule gpu_video_cards() keeps: radeonsi needs radeon
# (xf86-video-ati -> libdrm[video_cards_radeon]) and amdgpu.
dc_effective_video_cards() {
    local matrix="$1" out="" c
    if [ -z "${DC_VIDEO_CARDS}" ]; then
        printf '%s\n' "${matrix}"
        return 0
    fi
    for c in ${DC_VIDEO_CARDS}; do
        case " ${out} " in *" ${c} "*) ;; *) out="${out:+${out} }${c}" ;; esac
        if [ "${c}" = "radeonsi" ]; then
            case " ${out} " in *" radeon "*) ;; *) out="${out} radeon" ;; esac
            case " ${out} " in *" amdgpu "*) ;; *) out="${out} amdgpu" ;; esac
        fi
    done
    printf '%s\n' "${out}"
}

# dc_client_use_extra -> extra make.conf USE for a client desktop ("wayland" when
# a Wayland compositor is on board, else nothing)
dc_client_use_extra() {
    dc_wayland_selected && printf 'wayland\n'
    return 0
}

# dc_session_package_use -> the package.use lines the chosen sessions NEED, one per
# line (nothing for a session that needs none). Not operator choices: without them the
# session cannot be merged at all.
#   wayfire  gui-wm/wayfire depends on gui-libs/wlroots:<slot>[x11-backend] UNCONDITIONALLY
#            (2026-11-12 pretend: "there are no ebuilds built with USE flags to satisfy
#            gui-libs/wlroots:0.19[drm(+),libinput(+),x11-backend,X?]"); wlroots defaults
#            x11-backend off. The line is slot- and version-less on purpose: the slot moves
#            with the tree (0.19 in the 2026-11 snapshot, 0.20 after it).
#   sway     wlroots[x11-backend=,X=] follows sway's OWN flags (both default off): no line.
#   labwc    wlroots[X?,libinput]: X comes from the desktop profile's global USE: no line.
# tests/scripts/test-desktop-config-lib.sh (section 3) pins the table.
dc_session_package_use() {
    local s
    for s in ${DC_SESSIONS}; do
        case "${s}" in
            wayfire) printf '%s\n' "gui-libs/wlroots x11-backend" ;;
        esac
    done | awk '!seen[$0]++'
}

# ── dc_apply_portage_overlay SYSROOT TAG ─────────────────────────────────────
# Writes package.use/zz-hugmesh-studio and package.accept_keywords/zz-hugmesh-studio
# from the overlay lines. MUST run after the builder's LAST pcs_sync_dir of those
# directories: pcs_sync_dir prunes every file the specs tree lacks, so a file
# written before it would vanish (and a resumed sysroot's stale copy is pruned by
# the very same sync, then rewritten here — or left absent when no line is given).
# "zz-" sorts last, so these lines are read after every spec file.
dc_apply_portage_overlay() {
    local sysroot="$1"; _DC_TAG="${2:-desktop-config}"
    local pu="${sysroot}/etc/portage/package.use/zz-hugmesh-studio"
    local ak="${sysroot}/etc/portage/package.accept_keywords/zz-hugmesh-studio"
    local ps="${sysroot}/etc/portage/package.use/zz-hugmesh-sessions"
    local body
    rm -f "${pu}" "${ak}" "${ps}"
    # What the chosen sessions need (dc_session_package_use), in its OWN file: the
    # zz-hugmesh-studio overlay stays exactly the lines the operator applied.
    body="$(dc_session_package_use)"
    if [ -n "${body}" ]; then
        mkdir -p "$(dirname "${ps}")"
        {
            printf '# Written for the chosen --desktop-sessions (dc_session_package_use;\n'
            printf '# scripts/_desktop-config-lib.sh): what each session needs to be merged at all.\n'
            printf '%s\n' "${body}"
        } > "${ps}"
        _dc_info "session needs: $(printf '%s\n' "${body}" | wc -l) package.use line(s) -> /etc/portage/package.use/zz-hugmesh-sessions"
    fi
    body="$(_dc_lines "${DC_PACKAGE_USE}")"
    if [ -n "${body}" ]; then
        mkdir -p "$(dirname "${pu}")"
        {
            printf '# Written by the Studio Desktop step (--package-use; scripts/_desktop-config-lib.sh).\n'
            printf '# Each line was proposed by an emerge --pretend run and applied by the operator.\n'
            printf '%s\n' "${body}"
        } > "${pu}"
        _dc_info "portage overlay: $(printf '%s\n' "${body}" | wc -l) package.use line(s) -> /etc/portage/package.use/zz-hugmesh-studio"
    fi
    body="$(_dc_lines "${DC_ACCEPT_KEYWORDS}")"
    if [ -n "${body}" ]; then
        mkdir -p "$(dirname "${ak}")"
        {
            printf '# Written by the Studio Desktop step (--accept-keywords; scripts/_desktop-config-lib.sh).\n'
            printf '%s\n' "${body}"
        } > "${ak}"
        _dc_info "portage overlay: $(printf '%s\n' "${body}" | wc -l) accept_keywords line(s) -> /etc/portage/package.accept_keywords/zz-hugmesh-studio"
    fi
    return 0
}

# ── dc_bake_desktop SYSROOT TAG ──────────────────────────────────────────────
# After the builder wrote /etc/lightdm/lightdm.conf:
#   * --default-session rewrites its user-session= line;
#   * --extra-local-users bakes /etc/hugmesh/extra-local-users (0600: NAME ADMIN
#     HASH lines, hashed HERE with the same KDF as --local-pass) and the firstboot
#     script that creates them (not administrators unless ':admin'; each must
#     change the password at first login);
#   * --flatpak-apps bakes /etc/hugmesh/flatpak-apps.list (+ remotes) and the
#     hugmesh-flatpak-apps OpenRC service that installs them once online and
#     retries every boot until all are in.
dc_bake_desktop() {
    local sysroot="$1"; _DC_TAG="${2:-desktop-config}"
    # NS: "hugmesh" (default) or a neutral name for an --unaffiliated image, which
    # must carry no HugMesh names: /etc/NS/... and the NS-flatpak-apps service.
    local ns="${3:-hugmesh}"
    local conf="${sysroot}/etc/lightdm/lightdm.conf" tok name admin pass hash list svc
    if [ -n "${DC_DEFAULT_SESSION}" ]; then
        if [ -f "${conf}" ] && grep -aq '^user-session=' "${conf}"; then
            sed -i -E "s|^user-session=.*$|user-session=${DC_DEFAULT_SESSION}|" "${conf}"
            _dc_info "greeter default session: ${DC_DEFAULT_SESSION}"
        else
            _dc_err "--default-session: ${conf} has no user-session= line to set"
            return 1
        fi
    fi
    if [ -n "${DC_EXTRA_USERS}" ]; then
        command -v ph_crypt_hash >/dev/null 2>&1 \
            || { _dc_err "internal: ph_crypt_hash missing (source scripts/_passhash-lib.sh first)"; return 1; }
        list="${sysroot}/etc/${ns}/extra-local-users"
        mkdir -p "${sysroot}/etc/${ns}" "${sysroot}/etc/local.d"
        ( umask 077; : > "${list}" )
        for tok in ${DC_EXTRA_USERS}; do
            name="${tok%%:*}"; admin=false
            [ "${tok}" = "${name}:admin" ] && admin=true
            pass="$(grep -a -m 1 "^${name}:" "${DC_EXTRA_PASS_FILE}" || true)"
            pass="${pass#*:}"
            [ -n "${pass}" ] || { _dc_err "no password for extra account '${name}'"; return 1; }
            hash="$(ph_crypt_hash "${pass}")" || { _dc_err "could not hash the password of '${name}'"; return 1; }
            pass=""
            printf '%s %s %s\n' "${name}" "${admin}" "${hash}" >> "${list}"
        done
        chmod 0600 "${list}"
        sed "s|/etc/hugmesh/|/etc/${ns}/|g" "${_DC_LIB_DIR}/desktop-config/02-extra-local-users.start" \
            > "${sysroot}/etc/local.d/02-extra-local-users.start"
        chmod 0755 "${sysroot}/etc/local.d/02-extra-local-users.start"
        _dc_info "extra local accounts: ${DC_EXTRA_USERS} (created at first boot; password change forced at first login)"
    fi
    if [ -n "${DC_FLATPAK_APPS}" ]; then
        svc="${ns}-flatpak-apps"
        mkdir -p "${sysroot}/etc/${ns}" "${sysroot}/etc/init.d"
        {
            printf '# REMOTE APP-ID — installed by /etc/init.d/%s (system-wide).\n' "${svc}"
            for tok in ${DC_FLATPAK_APPS}; do printf '%s %s\n' "${tok%%:*}" "${tok#*:}"; done
        } > "${sysroot}/etc/${ns}/flatpak-apps.list"
        {
            printf '# NAME URL (.flatpakrepo) — added before the apps are installed.\n'
            case " ${DC_FLATPAK_APPS} " in
                *" flathub:"*)
                    case " ${DC_FLATPAK_REMOTES} " in
                        *" flathub="*) ;;
                        *) printf 'flathub https://dl.flathub.org/repo/flathub.flatpakrepo\n' ;;
                    esac ;;
            esac
            for tok in ${DC_FLATPAK_REMOTES}; do printf '%s %s\n' "${tok%%=*}" "${tok#*=}"; done
        } > "${sysroot}/etc/${ns}/flatpak-remotes.list"
        sed -e "s|/etc/hugmesh/|/etc/${ns}/|g" -e "s|/var/lib/hugmesh/|/var/lib/${ns}/|g" \
            -e "s|hugmesh-flatpak-apps|${svc}|g" \
            "${_DC_LIB_DIR}/desktop-config/hugmesh-flatpak-apps.initd" > "${sysroot}/etc/init.d/${svc}"
        chmod 0755 "${sysroot}/etc/init.d/${svc}"
        mkdir -p "${sysroot}/etc/runlevels/default"
        ln -sf "/etc/init.d/${svc}" "${sysroot}/etc/runlevels/default/${svc}"
        _dc_info "Flatpak apps (installed once online): ${DC_FLATPAK_APPS}"
    fi
    return 0
}

# dc_plan_lines -> "KEY value" lines for the builders' --print-plan
dc_plan_lines() {
    printf 'DESKTOP_SESSIONS %s\n' "${DC_SESSIONS:-none}"
    printf 'DEFAULT_SESSION %s\n' "${DC_DEFAULT_SESSION:-builder}"
    printf 'VIDEO_CARDS_OVERRIDE %s\n' "${DC_VIDEO_CARDS:-none}"
    printf 'EXTRA_LOCAL_USERS %s\n' "${DC_EXTRA_USERS:-none}"
    printf 'FLATPAK_APPS %s\n' "${DC_FLATPAK_APPS:-none}"
    printf 'PYTHON_EXTRA %s\n' "${PT_EXTRA_TARGETS:-none}"
    printf 'PYTHON_SINGLE %s\n' "${PT_SINGLE_TARGET:-seed}"
    local n
    n="$(_dc_lines "${DC_PACKAGE_USE};${DC_ACCEPT_KEYWORDS}" | wc -l | tr -d ' ')"
    printf 'PORTAGE_OVERLAY %s line(s)\n' "${n}"
}
