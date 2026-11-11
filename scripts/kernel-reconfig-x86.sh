#!/usr/bin/env bash
# kernel-reconfig-x86.sh — reopen a FINISHED x86 image's kernel in menuconfig, then
# rebuild only the kernel + modules, re-sign the UKI with the key the build used and
# repackage the stage4 tar, .img, .fs.tar and both ISOs — without a full rebuild.
#
#   kernel-reconfig-x86.sh <verb> --build-root <work-dir>/wl-<image-id> [options]
#
# Verbs
#   status      KEY=VALUE facts about this image's reconfiguration state (no root
#               needed for most of it; never changes anything).
#   edit        prepare the pending edit (if none) and run `make menuconfig` on a COPY
#               of the build's final .config, inside the build system (chroot). Needs a
#               terminal. Saves <build-root>/kernel-reconfig/pending/config.after.
#   set -- ARGS scripted edit: run the kernel tree's scripts/config ARGS on that copy
#               (e.g. `set -- --set-str LOCALVERSION -hmtest`, `set -- --disable USB_NET_CDC_NCM`).
#   diff        print the pending change, one `CONFIG_X: old -> new` per line.
#   discard     drop the pending edit.
#   apply       olddefconfig + the builder's hardening asserts on the edit, rebuild the
#               kernel and modules with the builder's own recipe, re-sign, relabel and
#               repackage every artifact this build produced. Non-interactive; streams.
#
# Options
#   --work-dir DIR   the session work dir holding the artifacts (default: the parent
#                    of --build-root).
#   --jobs N         make -j for the kernel compile (default: the build's own JOBS).
#   --seed-dir DIR   where the build's stage3 seed is, when the clean step stripped the
#                    build system's static libraries (default: /shared/seed/amd64, then
#                    <out>/shared/seed/amd64 beside the session).
#
# Runs as ROOT, natively (sudo) or inside the builder container (the Studio mounts
# the generator at /src and the session at /out, exactly as for the build). It is
# x86-only: the ARM builders delete their kernel source at the clean step.
#
# What it reuses, never re-implements:
#   scripts/_x86-kernel-asserts.sh   the builder's post-olddefconfig asserts (one list)
#   scripts/_x86-kernel-install.sh   the builder's compile/install/initramfs/UKI recipe
#   scripts/_selinux-policy-lib.sh   slx_label_tree / slx_label_gate / slx_tar_label_gate
#   scripts/_builder-resume-lib.sh   hmr_owner_gate / stale-mount checks / link check
#   the builder's "Live-ISO root pack helpers" block (live_root_gate, live_label_gate),
#   read out of build-x86-host-stage4.sh at run time, as its own test does.
#
# What it refuses, in one sentence each (exit 3, line `[kernel-reconfig] REFUSED: …`):
# no build tree, a build that predates this contract, no kept .config, an image still
# building (its <build-root>.lock is held), a missing Secure Boot key for an image that
# was signed, an edit that fails the hardening asserts, out-of-tree modules that a new
# kernel would orphan, too little disk.
#
# Repackaging PATCHES the artifacts this build produced instead of re-running the
# builder's image steps: PARTUUIDs, the grub.cfg, the installer ISO's LUKS keyfile and
# passphrase marker and the home archive all stay exactly as built, and no secret is
# needed. New artifacts get a new UTC timestamp in the SAME name pattern (so every
# flash/QEMU glob still matches); the originals move to <work-dir>/superseded/<old-ts>/.
# Every new artifact gets a <name>.sha256 (the sidecar core/flash_validate.py reads).
set -euo pipefail

KRC_GEN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_builder-resume-lib.sh
source "${KRC_GEN}/scripts/_builder-resume-lib.sh"
# shellcheck source=scripts/_selinux-policy-lib.sh
source "${KRC_GEN}/scripts/_selinux-policy-lib.sh"

KRC_TAG="[kernel-reconfig]"
banner() { printf '\n==> %s\n' "$1"; }
info()   { printf '    %s\n' "$1"; }
warn()   { printf '    WARNING: %s\n' "$1"; }
err()    { printf '    ERROR: %s\n' "$1" >&2; }
say()    { printf '%s %s\n' "${KRC_TAG}" "$*"; }
# krc_refuse <sentence> — the one-sentence refusal the Studio shows verbatim.
krc_refuse() { printf '%s REFUSED: %s\n' "${KRC_TAG}" "$*"; exit 3; }
krc_fail()   { printf '%s FAILED: %s\n' "${KRC_TAG}" "$*" >&2; exit 1; }

# ── arguments ───────────────────────────────────────────────────────────────────
VERB=""; BR=""; WD=""; JOBS_OVERRIDE=""; SET_ARGS=(); KRC_SEED_DIR="${KRC_SEED_DIR:-}"
krc_usage() { printf 'usage: %s <status|edit|set|diff|discard|apply> --build-root DIR [--work-dir DIR] [--jobs N] [-- scripts/config args]\n' "$0" >&2; exit 2; }
krc_args() {
    VERB="${1:-}"; [ $# -gt 0 ] && shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --build-root) BR="${2:?--build-root needs a path}"; shift 2 ;;
            --work-dir)   WD="${2:?--work-dir needs a path}"; shift 2 ;;
            --jobs)       JOBS_OVERRIDE="${2:?--jobs needs a number}"; shift 2 ;;
            --seed-dir)   KRC_SEED_DIR="${2:?--seed-dir needs a path}"; shift 2 ;;
            --) shift; SET_ARGS=("$@"); break ;;
            *) krc_usage ;;
        esac
    done
    case "${VERB}" in status|edit|set|diff|discard|apply) ;; *) krc_usage ;; esac
    [ -n "${BR}" ] || krc_usage
    krc_paths "${BR}" "${WD}"
}
# krc_paths <build-root> [work-dir] — every path the verbs use, derived in ONE place.
krc_paths() {
    BR="${1%/}"; WD="${2:-$(dirname "${BR}")}"; WD="${WD%/}"
    SYSROOT="${BR}/sysroot"
    KDIR="${BR}/kernel"
    KRC_ROOT="${BR}/kernel-reconfig"
    PEND="${KRC_ROOT}/pending"
    ENV_FILE="${BR}/kernel-reconfig.env"
    SLX_PROBE_TABLE="${BR}/selinux-label-probes.tsv"
    # shellcheck disable=SC2034  # read by the builder's live-pack helpers sourced below
    BUILD_ROOT="${BR}"
}

# ── the no-secret contract the builder wrote (strict KEY=VALUE, never sourced) ──
KRC_ENV_KEYS="KR_FORMAT BUILD_TS BRAND BRAND_TITLE ROLE ROLE_TAG ROLE_K8S ENV UNAFFILIATED
UKI_NAME ROOT_LABEL ESP_LABEL SB_ETC_DIR SB_EFI_VENDOR SECURE_BOOT UKI_SIGNED DEFAULT_USER
LIVE_ROOT_MOUNTPOINTS LIVE_VOLID INSTALL_VOLID SLX_TYPE JOBS KVER KERNEL_FROM_CACHE
KERNEL_CONFIG COMPRESS_IMG COMPRESS_LEVEL STAGE4 IMG FS_TAR LIVE_ISO INSTALLER_ISO"
declare -A KRE=()
krc_read_env() {
    local line k
    KRE=()
    [ -f "${ENV_FILE}" ] || return 1
    while IFS= read -r line || [ -n "${line}" ]; do
        [[ "${line}" == *=* ]] || continue
        k="${line%%=*}"
        case " ${KRC_ENV_KEYS//$'\n'/ } " in *" ${k} "*) KRE["${k}"]="${line#*=}" ;; esac
    done < "${ENV_FILE}"
    # Every known key exists afterwards (empty when the file lacks it): set -u never
    # trips on an older contract, and a missing artifact name reads as "not built".
    for k in ${KRC_ENV_KEYS}; do [ -n "${KRE[${k}]+x}" ] || KRE["${k}"]=""; done
    [ "${KRE[KR_FORMAT]:-}" = 1 ]
}
krc_write_env() {
    local k
    for k in ${KRC_ENV_KEYS}; do printf '%s=%s\n' "${k}" "${KRE[${k}]:-}"; done > "${ENV_FILE}.tmp"
    mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"
    chmod 0644 "${ENV_FILE}"
}

# ── the kernel tree inside the build system ─────────────────────────────────────
# /usr/src/linux is eselect's symlink; resolve it INSIDE the sysroot (an absolute
# target must never be followed on the host).
krc_tree() {
    local t
    t="$(readlink "${SYSROOT}/usr/src/linux" 2>/dev/null || true)"
    case "${t}" in
        "") [ -d "${SYSROOT}/usr/src/linux" ] && t="${SYSROOT}/usr/src/linux" ;;
        /*) t="${SYSROOT}${t}" ;;
        *)  t="${SYSROOT}/usr/src/${t}" ;;
    esac
    [ -n "${t}" ] && [ -f "${t}/Makefile" ] || return 1
    printf '%s\n' "${t}"
}
# The kernel release this build system currently carries (the newest module tree).
krc_cur_kver() { ls -1 "${SYSROOT}/lib/modules" 2>/dev/null | sort -V | tail -1 || true; }

# krc_locate — the refusals every verb shares. Sets KTREE, KVER_NOW, KCFG.
krc_locate() {
    [ -d "${SYSROOT}/usr" ] \
        || krc_refuse "The build system for this image is gone (${SYSROOT}) — were its build files deleted? Rebuild the image."
    KTREE="$(krc_tree)" \
        || krc_refuse "The kernel source tree is not in this image's build system any more (${SYSROOT}/usr/src/linux) — rebuild the image."
    KVER_NOW="$(krc_cur_kver)"
    [ -n "${KVER_NOW}" ] || krc_refuse "This image's build has not installed a kernel yet — wait for its Build kernel step to finish."
    KCFG="${KDIR}/config-${KVER_NOW}"
    [ -s "${KCFG}" ] \
        || krc_refuse "No kernel config was kept for ${KVER_NOW} (this build predates kernel reconfiguration, or its kernel came from an older cache entry) — rebuild the image once."
}

# ── the pending edit ─────────────────────────────────────────────────────────────
krc_prepare() {
    krc_locate
    if [ -f "${PEND}/config.before" ]; then
        cmp -s "${PEND}/config.before" "${KCFG}" \
            || krc_refuse "A pending kernel config edit was started against a different kernel config than this build now carries — discard it first."
        return 0
    fi
    mkdir -p "${PEND}"
    cp -f "${KCFG}" "${PEND}/config.before"
    printf 'kver=%s\nstarted=%s\n' "${KVER_NOW}" "$(date -u +%FT%TZ)" > "${PEND}/meta"
    chmod 0755 "${KRC_ROOT}" "${PEND}"; chmod 0644 "${PEND}/config.before" "${PEND}/meta"
    say "pending edit prepared from ${KCFG}"
}
krc_base_config() { if [ -s "${PEND}/config.after" ]; then printf '%s' "${PEND}/config.after"; else printf '%s' "${PEND}/config.before"; fi; }

# krc_config_diff <before> <after> — `CONFIG_X: old -> new`, sorted, `(unset)` for a
# symbol that is absent or `is not set`. Values are printed as the .config spells them.
krc_config_diff() {
    awk '
        function val(line,   v) { v = line; sub(/^[^=]*=/, "", v); return v }
        FNR == 1 { file++ }
        /^CONFIG_[A-Za-z0-9_]+=/ { s = $0; sub(/=.*/, "", s); v[file, s] = val($0); seen[s] = 1; next }
        /^# CONFIG_[A-Za-z0-9_]+ is not set$/ { s = $2; v[file, s] = "n"; seen[s] = 1; next }
        END {
            for (s in seen) {
                a = ((1, s) in v) ? v[1, s] : "(unset)"; b = ((2, s) in v) ? v[2, s] : "(unset)"
                if (a == "n") a = "n (not set)"; if (b == "n") b = "n (not set)"
                if (a != b) printf "%s: %s -> %s\n", s, a, b
            }
        }' "$1" "$2" | LC_ALL=C sort
}

# ── the build system, entered in a PRIVATE mount namespace ─────────────────────
# Every command runs as `unshare --mount --propagation private` + chroot, with /dev,
# /proc and /sys bound INSIDE that namespace only. Three things this buys, all measured
# on the real 2026-11-11 run:
#   * nothing is ever mounted in the namespace the builder (or the host) sees: the
#     builder asserts its build system has no mounts before the SELinux labelling and
#     the clean, so an operator sitting in menuconfig mid-build cannot fail the build,
#     and a crashed run leaves no stale mount behind (the namespace dies with it);
#   * the sysroot's own /dev nodes are useless on a nodev filesystem (this operator's
#     eCryptfs home: "/dev/null: Permission denied"), so a bind is required anyway;
#   * the clean step strips every static archive (no libgcc.a, no libc_nonshared.a),
#     so mconf and the kernel's host tools cannot link. krc_statics_prepare extracts
#     those archives from the stage3 seed the build system came from, and they are
#     overlaid read-only onto usr/lib64 and usr/lib/gcc in the private namespace only —
#     the build system on disk never gains a file, so no artifact can carry one.
KRC_STATICS=""
# krc_seed_dirs — where the build's stage3 seed can be: the builder container's
# /shared, the Studio layout (<out>/sessions/<id> next to <out>/shared), --seed-dir.
krc_seed_dirs() {
    printf '%s\n' ${KRC_SEED_DIR:+"${KRC_SEED_DIR}"} /shared/seed/amd64 \
        "$(dirname "$(dirname "${WD}")")/shared/seed/amd64" "${WD}/shared/seed/amd64"
}
krc_statics_prepare() {
    [ -n "${KRC_STATICS}" ] && return 0
    hmr_statics_missing "${SYSROOT}" || return 0
    local name d seed=""
    name="$(hmr_seed_marker_read "${BR}" 2>/dev/null || true)"
    [ -n "${name}" ] || krc_refuse "The build system's static libraries were stripped by its clean step and it does not record which stage3 seed it came from — rebuild the image."
    while IFS= read -r d; do
        [ -n "${d}" ] && [ -f "${d}/${name}" ] && { seed="${d}/${name}"; break; }
    done < <(krc_seed_dirs)
    [ -n "${seed}" ] || krc_refuse "The build system's static libraries were stripped by its clean step and the seed it came from (${name}) is not in any seed folder ($(krc_seed_dirs | tr '\n' ' ')) — rebuild the image."
    KRC_STATICS="$(mktemp -d "${TMPDIR:-/tmp}/hm-kreconf-statics.XXXXXX")"
    tar -xJf "${seed}" -C "${KRC_STATICS}" --wildcards './usr/lib64/*.a' './usr/lib/gcc/*' 2>/dev/null \
        || { rm -rf "${KRC_STATICS}"; KRC_STATICS=""; krc_refuse "Could not read the static libraries out of ${seed} — rebuild the image."; }
    info "Toolchain static archives overlaid from ${name} (private to this run; the build system on disk is unchanged)"
}
krc_statics_cleanup() { [ -n "${KRC_STATICS}" ] && rm -rf "${KRC_STATICS}"; KRC_STATICS=""; return 0; }
krc_chroot() {
    SYSROOT="${SYSROOT}" KRC_STATICS="${KRC_STATICS}" KTERM="${TERM:-xterm}" \
    unshare --mount --propagation private /bin/bash -c '
        set -e
        mount --rbind /dev "${SYSROOT}/dev"
        mount -t proc none "${SYSROOT}/proc"
        mount --rbind /sys "${SYSROOT}/sys"
        if [ -n "${KRC_STATICS}" ]; then
            for d in usr/lib64 usr/lib/gcc; do
                [ -d "${KRC_STATICS}/${d}" ] || continue
                mount -t overlay overlay -o "lowerdir=${KRC_STATICS}/${d}:${SYSROOT}/${d}" "${SYSROOT}/${d}"
            done
        fi
        exec chroot "${SYSROOT}" /usr/bin/env -i HOME=/root TERM="${KTERM}" LANG=C.UTF-8 \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
    ' krc-chroot "$@"
}
# krc_link_check — can the build system link a C program (the mconf / host-tool path)?
krc_link_check() {
    krc_chroot /bin/bash -c 'd="$(mktemp -d /usr/src/.hm-link.XXXXXX)"; trap "rm -rf \"$d\"" EXIT
        printf "int main(void){return 0;}\n" > "$d/t.c"; gcc -o "$d/t" "$d/t.c" -lpthread -ldl' >/dev/null 2>&1
}

# ── status ──────────────────────────────────────────────────────────────────────
krc_status() {
    local k
    printf 'BUILD_ROOT=%s\nWORK_DIR=%s\n' "${BR}" "${WD}"
    printf 'SYSROOT=%s\n' "$([ -d "${SYSROOT}/usr" ] && echo present || echo missing)"
    printf 'TREE=%s\n' "$(krc_tree >/dev/null 2>&1 && echo present || echo missing)"
    printf 'KVER_NOW=%s\n' "$(krc_cur_kver)"
    if krc_read_env; then printf 'ENV=present\n'; else printf 'ENV=missing\n'; fi
    for k in BUILD_TS KVER UKI_SIGNED KERNEL_CONFIG STAGE4 IMG FS_TAR LIVE_ISO INSTALLER_ISO; do
        printf '%s=%s\n' "${k}" "${KRE[${k}]:-}"
    done
    printf 'PENDING=%s\n' "$([ -f "${PEND}/config.before" ] && echo yes || echo no)"
    printf 'PENDING_CHANGED=%s\n' "$([ -s "${PEND}/config.after" ] && ! cmp -s "${PEND}/config.before" "${PEND}/config.after" && echo yes || echo no)"
    printf 'RECONFIGURED=%s\n' "$([ -f "${KDIR}/reconfigured" ] && echo yes || echo no)"
}

# ── edit / set / diff / discard ─────────────────────────────────────────────────
krc_edit() {
    krc_prepare
    [ -t 0 ] && [ -t 1 ] \
        || krc_refuse "menuconfig needs an interactive terminal — open it from the Studio's \"Kernel config…\" button (it opens a terminal window), or use 'set' for a scripted change."
    # Staged under /usr/src, NOT /var/tmp: the builder's clean step empties /var/tmp —
    # the very step that starts when the Build kernel stage (and this button) turns
    # ready — and every artifact excludes ./usr/src, so the copy can never ship.
    local stage="${SYSROOT}/usr/src/.hm-kreconf"
    rm -rf "${stage}"; mkdir -p "${stage}"
    cp -f "$(krc_base_config)" "${stage}/.config"
    trap 'krc_statics_cleanup; rm -rf "${stage}"' EXIT
    krc_statics_prepare
    # mconf-cfg.sh caches its ncurses flags in mconf-cflags / mconf-libs and nothing
    # regenerates them. An attempt that ran without /proc (pkg-config segfaults there)
    # cached a bare -lncursesw, and every later link failed on libtinfow ("DSO missing
    # from command line"). Until mconf has linked once, recompute them.
    [ -x "${KTREE}/scripts/kconfig/mconf" ] \
        || rm -f "${KTREE}/scripts/kconfig/mconf-cflags" "${KTREE}/scripts/kconfig/mconf-libs" "${KTREE}/scripts/kconfig/mconf-bin"
    say "menuconfig on a COPY of ${KCFG} (the build's own .config is not touched); save and exit to keep the change"
    # KCONFIG_CONFIG points mconf at the staged copy: the tree's live .config — the one
    # the build compiled — never changes here.
    krc_chroot make -C "/usr/src/linux" KCONFIG_CONFIG=/usr/src/.hm-kreconf/.config menuconfig \
        || krc_fail "menuconfig did not run inside the build system (see above)"
    cp -f "${stage}/.config" "${PEND}/config.after"; chmod 0644 "${PEND}/config.after"
    krc_statics_cleanup; rm -rf "${stage}"; trap - EXIT
    krc_diff_verb
}
krc_set() {
    krc_prepare
    [ "${#SET_ARGS[@]}" -gt 0 ] || krc_refuse "set needs scripts/config arguments after --, e.g. -- --set-str LOCALVERSION -hmtest"
    local tmp="${PEND}/config.set.tmp"
    cp -f "$(krc_base_config)" "${tmp}"
    bash "${KTREE}/scripts/config" --file "${tmp}" "${SET_ARGS[@]}" \
        || { rm -f "${tmp}"; krc_fail "scripts/config ${SET_ARGS[*]} failed"; }
    mv -f "${tmp}" "${PEND}/config.after"; chmod 0644 "${PEND}/config.after"
    krc_diff_verb
}
krc_diff_verb() {
    [ -f "${PEND}/config.before" ] || { say "no pending kernel config edit"; return 0; }
    [ -s "${PEND}/config.after" ] || { say "pending edit opened, nothing saved yet"; return 0; }
    local d; d="$(krc_config_diff "${PEND}/config.before" "${PEND}/config.after")"
    if [ -z "${d}" ]; then say "the pending edit changes nothing"; else
        say "pending change ($(printf '%s\n' "${d}" | wc -l) symbol(s)):"; printf '%s\n' "${d}" | sed 's/^/    /'; fi
}
krc_discard() {
    exec 217>>"${BR}.lock"
    flock -n 217 || krc_refuse "A kernel rebuild for this image is running — wait for it to finish before discarding the edit."
    krc_state_has kernel \
        && krc_refuse "An interrupted kernel rebuild already put the edited kernel into this image's build system — run the rebuild again to finish it; discarding now would leave the build system and the artifacts disagreeing."
    rm -rf "${PEND}"; say "pending kernel config edit discarded"
}

# ── apply: the steps ────────────────────────────────────────────────────────────
krc_artifact() { [ -n "${1:-}" ] && printf '%s/%s' "${WD}" "$1"; }

# Disk the patch path needs at its peak (bytes): the .img UNcompressed, the live
# squashfs unpacked (~3x its compressed size) and the rebuilt copies of every artifact.
krc_disk_need() {
    local n=0 f sz
    for f in "${KRE[STAGE4]}" "${KRE[FS_TAR]}" "${KRE[LIVE_ISO]}" "${KRE[INSTALLER_ISO]}"; do
        [ -n "${f}" ] && [ -f "${WD}/${f}" ] && n=$(( n + $(stat -c %s "${WD}/${f}") ))
    done
    if [ -n "${KRE[IMG]}" ] && [ -f "${WD}/${KRE[IMG]}" ]; then
        case "${KRE[IMG]}" in
            *.xz) sz="$(xz --robot -l "${WD}/${KRE[IMG]}" 2>/dev/null | awk '$1=="totals"{print $5}')"; n=$(( n + ${sz:-0} + $(stat -c %s "${WD}/${KRE[IMG]}") )) ;;
            *)    n=$(( n + 2 * $(stat -c %s "${WD}/${KRE[IMG]}") )) ;;
        esac
    fi
    [ -n "${KRE[LIVE_ISO]}" ] && [ -f "${WD}/${KRE[LIVE_ISO]}" ] && n=$(( n + 3 * $(stat -c %s "${WD}/${KRE[LIVE_ISO]}") ))
    printf '%s' "$(( n + 4 * 1024 * 1024 * 1024 ))"
}

# krc_avail_bytes <dir> — free bytes under <dir> (a seam: the suite answers it instead
# of faking a full disk with a huge file).
krc_avail_bytes() { df --output=avail -B1 "$1" | tail -1 | tr -dc 0-9; }

krc_preflight() {
    exec 217>>"${BR}.lock"
    flock -n 217 \
        || krc_refuse "This image is still building (or another kernel rebuild holds ${BR}.lock) — wait for it to finish."
    krc_read_env \
        || krc_refuse "This build predates kernel reconfiguration (no ${ENV_FILE}) — rebuild it once."
    krc_locate
    [ -f "${PEND}/config.before" ] && [ -s "${PEND}/config.after" ] \
        || krc_refuse "There is no kernel config edit to apply — open menuconfig (Kernel config…) first."
    if krc_state_has kernel; then
        # An interrupted rebuild (a cancel, a killed container): the build system already
        # carries THIS edit's kernel, so its kept config is the applied one.
        cmp -s "${PEND}/config.applied" "${KCFG}" \
            || krc_refuse "An interrupted kernel rebuild was recorded, but the build system no longer carries its kernel — discard the edit and edit again."
    else
        cmp -s "${PEND}/config.before" "${KCFG}" \
            || krc_refuse "The pending edit was made against a different kernel config than this build now carries — discard it and edit again."
        [ -n "$(krc_config_diff "${PEND}/config.before" "${PEND}/config.after")" ] \
            || krc_refuse "The kernel config edit changes nothing — there is nothing to rebuild."
    fi
    hmr_owner_gate "${SYSROOT}" "rebuild the image (never with --resume) so the build system is root's again" \
        || krc_refuse "The build system is not root's any more (see above) — rebuild the image."
    local stale; stale="$(hmr_stale_mounts "${SYSROOT}" 2>/dev/null || true)"
    if [ -n "${stale}" ]; then
        # The builder's own chroot mounts would mean it is still running; anything else
        # is a crashed run's leftovers. Either way an rm/relabel must not cross them.
        krc_refuse "Something is still mounted inside this image's build system (${stale%%$'\n'*}) — wait for the build to finish or unmount it."
    fi
    KR_SIGNED="${KRE[UKI_SIGNED]:-no}"
    SBDIR="${WD}/secureboot"
    if [ "${KR_SIGNED}" = yes ]; then
        [ -f "${SBDIR}/sb.key" ] && [ -f "${SBDIR}/sb.crt" ] \
            || krc_refuse "The Secure Boot key this image was signed with is gone: ${SBDIR}/sb.key — its kernel cannot be re-signed."
        command -v sbsign >/dev/null && command -v sbverify >/dev/null \
            || krc_refuse "sbsign/sbverify (app-crypt/sbsigntools) are not on this host — run the rebuild in the builder container."
    fi
    local k f
    for k in STAGE4 IMG FS_TAR LIVE_ISO INSTALLER_ISO; do
        f="${KRE[${k}]:-}"; [ -n "${f}" ] || continue
        [ -f "${WD}/${f}" ] || [ -f "${WD}/superseded/${KRE[BUILD_TS]}/${f}" ] \
            || krc_refuse "The ${k} artifact this build produced is missing from ${WD} (${f}) — was it moved or deleted?"
    done
    local extra
    # (find exits 1 for each of the four dirs that does not exist: never let that, under
    # pipefail, read as "found nothing" or abort the preflight)
    extra="$( { find "${SYSROOT}/lib/modules/${KVER_NOW}"/{extra,updates,video,misc} -name '*.ko*' 2>/dev/null || true; } \
               | head -3 | xargs -r -n1 basename | tr '\n' ' ')" || true
    [ -z "${extra}" ] \
        || krc_refuse "This image carries out-of-tree kernel modules (${extra% }) built against its current kernel; kernel reconfiguration cannot rebuild them, so a new kernel would leave them unloadable."
    local need avail
    need="$(krc_disk_need)"; avail="$(krc_avail_bytes "${WD}")"
    [ "${avail:-0}" -ge "${need}" ] \
        || krc_refuse "Repackaging needs about $(( need / 1073741824 )) GiB free under ${WD}; $(( ${avail:-0} / 1073741824 )) GiB is available."
    # The live ISO step reuses the builder's own live-root helpers; read them NOW, so a
    # renamed anchor in the builder fails here in seconds rather than after the .img.
    [ -z "${KRE[LIVE_ISO]:-}" ] || krc_live_helpers
    for k in xz tar sfdisk losetup mount unsquashfs mksquashfs xorriso; do
        command -v "${k}" >/dev/null || krc_refuse "${k} is not on this host — run the rebuild in the builder container."
    done
}

# The live initramfs: the builder's own dracut call for the live ISO (build-x86-host-stage4.sh,
# "Building LIVE image"). tests/scripts/test-kernel-reconfig-x86.sh pins the two argument
# lists as identical.
krc_live_initramfs() {
    krc_chroot dracut --force --no-hostonly \
        --add "dmsquash-live" \
        --add-drivers "squashfs iso9660 loop sr_mod usb_storage ahci nvme" \
        --kver "$1" /boot/initramfs-live.img
}

krc_kernel_rebuild() {
    local tree_cfg="${KTREE}/.config" out rc=0 jobs
    jobs="${JOBS_OVERRIDE:-${KRE[JOBS]:-$(nproc)}}"
    banner "Building hardened kernel (reconfigured: menuconfig)"
    OLD_KVER="${KVER_NOW}"
    [ -f "${tree_cfg}" ] && cp -f "${tree_cfg}" "${PEND}/config.tree-before"
    trap 'krc_statics_cleanup' EXIT
    krc_statics_prepare
    krc_link_check \
        || krc_refuse "The build system cannot link a C program, so the kernel cannot be rebuilt in it — rebuild the image."
    cp -f "${PEND}/config.after" "${tree_cfg}"
    krc_chroot make -C /usr/src/linux olddefconfig >/dev/null \
        || { cp -f "${PEND}/config.before" "${tree_cfg}"; krc_refuse "make olddefconfig rejected the edited kernel config — nothing was rebuilt."; }
    install -m 0755 "${KRC_GEN}/scripts/_x86-kernel-asserts.sh" "${SYSROOT}/tmp/hm-x86-kernel-asserts.sh"
    install -m 0755 "${KRC_GEN}/scripts/_x86-kernel-install.sh" "${SYSROOT}/tmp/hm-x86-kernel-install.sh"
    out="$(krc_chroot bash /tmp/hm-x86-kernel-asserts.sh "${KRE[ROLE_K8S]}" 2>&1)" || rc=$?
    [ -n "${out}" ] && printf '%s\n' "${out}" | sed 's/^/    /'
    if [ "${rc}" -ne 0 ]; then
        if [ -f "${PEND}/config.tree-before" ]; then cp -f "${PEND}/config.tree-before" "${tree_cfg}"; else cp -f "${PEND}/config.before" "${tree_cfg}"; fi
        krc_refuse "The edited kernel config fails the build's hardening asserts: $(printf '%s\n' "${out}" | grep -m1 'ERROR' | sed 's/^.*ERROR: *//') — nothing was rebuilt."
    fi
    cp -f "${tree_cfg}" "${PEND}/config.applied"; chmod 0644 "${PEND}/config.applied"
    # From here on the build system's kernel is no longer the fragments' kernel: a later
    # --resume of the BUILD must not restore a cached one over it (kernel_reconfig_reset).
    mkdir -p "${KDIR}"
    printf 'kver=%s\norig_kver=%s\nat=%s\n' "(building)" "${OLD_KVER}" "$(date -u +%FT%TZ)" > "${KDIR}/reconfigured"
    info "Compiling the kernel and modules (make -j${jobs}); modules are stripped before they are signed"
    krc_chroot env INSTALL_MOD_STRIP=1 bash /tmp/hm-x86-kernel-install.sh "${jobs}" "${KRE[ROOT_LABEL]}" "${KRE[UKI_NAME]}" \
        || krc_fail "the kernel build or install failed (see above); the artifacts were NOT touched"
    NEW_KVER="$(krc_chroot make -s -C /usr/src/linux kernelrelease 2>/dev/null)"
    [ -n "${NEW_KVER}" ] && [ -d "${SYSROOT}/lib/modules/${NEW_KVER}" ] \
        || krc_fail "the rebuilt kernel's release could not be read back (make kernelrelease)"
    printf 'kver=%s\norig_kver=%s\nat=%s\n' "${NEW_KVER}" "${OLD_KVER}" "$(date -u +%FT%TZ)" > "${KDIR}/reconfigured"
    # arch/x86/boot/install.sh keeps the previous image as *.old — never ship those.
    rm -f "${SYSROOT}/boot/vmlinuz.old" "${SYSROOT}/boot/System.old" "${SYSROOT}/boot/System.map.old"
    if [ "${NEW_KVER}" != "${OLD_KVER}" ]; then
        info "Kernel release changed: ${OLD_KVER} -> ${NEW_KVER} (removing the old module tree and initramfs)"
        rm -rf "${SYSROOT:?}/lib/modules/${OLD_KVER}" "${SYSROOT}/boot/initramfs-${OLD_KVER}.img"
    fi
    [ -s "${SYSROOT}/boot/initramfs-${NEW_KVER}.img" ] \
        || krc_fail "no disk initramfs for ${NEW_KVER} after the rebuild (dracut failed, see above)"
    [ -s "${SYSROOT}/boot/vmlinuz" ] || krc_fail "no /boot/vmlinuz after make install"
    if [ -n "${KRE[LIVE_ISO]}" ]; then
        info "Rebuilding the live ISO's initramfs (dmsquash-live) for ${NEW_KVER}"
        krc_live_initramfs "${NEW_KVER}" || krc_fail "the live initramfs (dracut dmsquash-live) failed"
    fi
    rm -f "${SYSROOT}/tmp/hm-x86-kernel-asserts.sh" "${SYSROOT}/tmp/hm-x86-kernel-install.sh"
    krc_statics_cleanup; trap - EXIT
    # The kept config follows the new release.
    rm -f "${KDIR}"/config-*
    cp -f "${PEND}/config.applied" "${KDIR}/config-${NEW_KVER}"
}

# Sign the UKI with the key the BUILD used, strictly: never mint a key, never ship an
# unsigned UKI for an image that was signed, and verify against the build's cert.
krc_sign() {
    local name="${KRE[UKI_NAME]}" unsigned signed
    unsigned="${SYSROOT}/boot/${name%.efi}-unsigned.efi"; signed="${SYSROOT}/boot/${name}"
    [ -s "${unsigned}" ] || krc_fail "dracut --uefi produced no UKI (${unsigned}) — the image's Secure Boot entry would boot the OLD kernel"
    if [ "${KR_SIGNED}" = yes ]; then
        sbsign --key "${SBDIR}/sb.key" --cert "${SBDIR}/sb.crt" --output "${signed}" "${unsigned}" \
            || krc_fail "sbsign failed with ${SBDIR}/sb.key — the old signed kernel is still in the artifacts"
        sbverify --cert "${SBDIR}/sb.crt" "${signed}" >/dev/null 2>&1 \
            || krc_fail "the re-signed UKI does not verify against ${SBDIR}/sb.crt"
        info "UKI re-signed with ${SBDIR}/sb.key and verified (sbverify --cert sb.crt)"
        SBV_SYSROOT=true
    else
        cp -f "${unsigned}" "${signed}"
        warn "This image's UKI was not signed when it was built (Secure Boot off, or no signing tool) — the rebuilt UKI stays unsigned."
        SBV_SYSROOT=false
    fi
    rm -f "${unsigned}"
}

krc_label_sysroot() {
    banner "Labelling the rebuilt kernel (SELinux ${KRE[SLX_TYPE]})"
    [ -n "${KRE[SLX_TYPE]}" ] || krc_fail "the build recorded no SELinux policy type"
    slx_label_tree "${SYSROOT}" "${KRE[SLX_TYPE]}" \
        && slx_label_gate "${SYSROOT}" sysroot "${SLX_PROBE_TABLE}" --census \
        || krc_fail "SELinux labelling of the rebuilt kernel failed (see above)"
}

# krc_patch_kernel_tree <root> — replace the kernel files of an unpacked image root with
# the rebuilt ones: /boot (vmlinuz, System.map, the disk initramfs, the signed UKI and,
# when present there, the live initramfs) and /lib/modules/<kver>. Labels ride along
# (cp -a keeps security.selinux from the freshly labelled sysroot).
krc_patch_kernel_tree() {
    local root="$1" f
    for f in vmlinuz System.map "${KRE[UKI_NAME]}" "initramfs-${NEW_KVER}.img"; do
        [ -e "${SYSROOT}/boot/${f}" ] && cp -a "${SYSROOT}/boot/${f}" "${root}/boot/${f}"
    done
    [ -e "${root}/boot/initramfs-live.img" ] && cp -a "${SYSROOT}/boot/initramfs-live.img" "${root}/boot/initramfs-live.img"
    if [ "${NEW_KVER}" != "${OLD_KVER}" ]; then
        rm -f "${root}/boot/initramfs-${OLD_KVER}.img"
    fi
    # Merged /usr: /lib is a relative symlink to usr/lib in these images. Address the
    # real directory so no path is ever resolved through a link (an absolute one would
    # point at the HOST's /usr/lib).
    local md="${root}/usr/lib/modules"
    [ -L "${root}/lib" ] || md="${root}/lib/modules"
    [ -d "${md}" ] || krc_fail "no module directory in ${root}"
    rm -rf "${md:?}/${OLD_KVER}" "${md:?}/${NEW_KVER}"
    cp -a "${SYSROOT}/lib/modules/${NEW_KVER}" "${md}/${NEW_KVER}"
    rm -f "${root}/boot/vmlinuz.old" "${root}/boot/System.old"
}

krc_pack_stage4() {
    banner "Packaging stage4 tarball"
    NEW_STAGE4="${WD}/${KRE[BRAND]}-x86-amd64-${KRE[ROLE_TAG]}-${KRE[ENV]}-${NEW_TS}.stage4.tar.xz"
    # The builder's stage4 tar (build-x86-host-stage4.sh, "Packaging stage4 tarball"),
    # plus ./boot/initramfs-live.img: the builder packs BEFORE its live step creates
    # that file, so the original stage4 never carried it. The exclude set is pinned
    # against the builder's by tests/scripts/test-kernel-reconfig-x86.sh.
    tar -C "${SYSROOT}" --xattrs --xattrs-include='*.*' --numeric-owner \
        --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
        --exclude='./var/cache' --exclude='./tmp/*' --exclude='./usr/src' --exclude="./home/${KRE[DEFAULT_USER]}" \
        --exclude='./boot/initramfs-live.img' -cpf - . \
        | xz -T0 "$(krc_xz_memlimit)" -6 > "${NEW_STAGE4}" \
        || krc_fail "stage4 tar (with xattrs) failed"
    slx_tar_label_gate "${NEW_STAGE4}" stage4 "${SLX_PROBE_TABLE}" \
        || krc_fail "the new stage4 lost its SELinux labels"
    info "Stage4: ${NEW_STAGE4} ($(du -sh "${NEW_STAGE4}" | cut -f1))"
}

# krc_grub_rewrite <grub.cfg> <old-kver> <new-kver> — build_img names the disk initramfs
# by release in every `initrd` line (the GRUB entry and the SELinux-permissive rescue);
# the UKI chainload entry carries its own. Rewrite the LITERAL (dots are not wildcards),
# then prove it took: no old name left, at least one initrd line naming the new one.
krc_grub_rewrite() {
    local grub="$1" old="$2" new="$3" tmp
    tmp="${grub}.krc.tmp"
    awk -v o="/boot/initramfs-${old}.img" -v n="/boot/initramfs-${new}.img" '
        { out = ""; s = $0
          while ((i = index(s, o)) > 0) { out = out substr(s, 1, i - 1) n; s = substr(s, i + length(o)) }
          print out s }' "${grub}" > "${tmp}" && cat "${tmp}" > "${grub}" && rm -f "${tmp}"
    grep -F "/boot/initramfs-${old}.img" "${grub}" >/dev/null \
        && krc_fail "grub.cfg still names initramfs-${old}.img after the rewrite"
    grep -F "initrd /boot/initramfs-${new}.img" "${grub}" >/dev/null \
        || krc_fail "grub.cfg names no initramfs-${new}.img after the rewrite"
    return 0
}

# The .img: patched in place on a scratch copy, with build_img's own loop recipe —
# sfdisk geometry and --offset/--sizelimit loops (no partition scanning in a container).
KRC_IMG_MNT=""; KRC_IMG_LOOPS=()
krc_img_cleanup() {
    set +e
    [ -n "${KRC_IMG_MNT}" ] && mountpoint -q "${KRC_IMG_MNT}/boot/efi" && umount "${KRC_IMG_MNT}/boot/efi"
    [ -n "${KRC_IMG_MNT}" ] && mountpoint -q "${KRC_IMG_MNT}" && umount "${KRC_IMG_MNT}"
    local l; for l in "${KRC_IMG_LOOPS[@]}"; do losetup "${l}" >/dev/null 2>&1 && losetup -d "${l}"; done
    KRC_IMG_LOOPS=()
    [ -n "${KRC_IMG_MNT}" ] && rmdir "${KRC_IMG_MNT}" 2>/dev/null
    KRC_IMG_MNT=""
    set -e
}
krc_img_patch() {
    local src="${WD}/${KRE[IMG]}" work="${KRC_WORK}/work.img" geom esp_start esp_size root_start root_size
    local esp_part root_part grub n
    banner "Building raw .img (UEFI GPT: ESP + ext4 root, GRUB-EFI --removable)"
    info "Patching ${KRE[IMG]}: kernel, modules, initramfs and the signed UKI on the ESP"
    case "${src}" in
        *.xz) xz -dc -T1 "${src}" | dd of="${work}" bs=1M conv=sparse iflag=fullblock status=none ;;
        *)    cp --sparse=always "${src}" "${work}" ;;
    esac
    geom="$(sfdisk -d "${work}")"
    local -a pl; mapfile -t pl < <(printf '%s\n' "${geom}" | grep -E 'start=')
    [ "${#pl[@]}" -ge 2 ] || krc_fail "${KRE[IMG]} does not carry the ESP+root GPT this builder writes"
    _fld() { printf '%s' "$1" | grep -oE "$2=[ ]*[^,]*" | sed "s/$2=//; s/[\" ]//g"; }
    esp_start="$(_fld "${pl[0]}" start)"; esp_size="$(_fld "${pl[0]}" size)"
    root_start="$(_fld "${pl[1]}" start)"; root_size="$(_fld "${pl[1]}" size)"
    for n in $(seq 0 31); do [ -e "/dev/loop${n}" ] || mknod "/dev/loop${n}" b 7 "${n}" 2>/dev/null || true; done
    trap 'krc_img_cleanup' EXIT
    esp_part="$(losetup --show -f --offset $((esp_start*512)) --sizelimit $((esp_size*512)) "${work}")"; KRC_IMG_LOOPS+=("${esp_part}")
    root_part="$(losetup --show -f --offset $((root_start*512)) --sizelimit $((root_size*512)) "${work}")"; KRC_IMG_LOOPS+=("${root_part}")
    KRC_IMG_MNT="$(mktemp -d "${KRC_WORK}/img-root.XXXXXX")"
    mount "${root_part}" "${KRC_IMG_MNT}"
    mount "${esp_part}" "${KRC_IMG_MNT}/boot/efi"
    krc_patch_kernel_tree "${KRC_IMG_MNT}"
    if [ -f "${KRC_IMG_MNT}/boot/efi/EFI/Linux/${KRE[UKI_NAME]}" ]; then
        cp -f "${SYSROOT}/boot/${KRE[UKI_NAME]}" "${KRC_IMG_MNT}/boot/efi/EFI/Linux/${KRE[UKI_NAME]}"
    fi
    grub="${KRC_IMG_MNT}/boot/grub/grub.cfg"
    if [ "${NEW_KVER}" != "${OLD_KVER}" ] && [ -f "${grub}" ]; then
        krc_grub_rewrite "${grub}" "${OLD_KVER}" "${NEW_KVER}"
        info "grub.cfg: initrd lines now name initramfs-${NEW_KVER}.img"
    fi
    slx_label_tree "${KRC_IMG_MNT}" "${KRE[SLX_TYPE]}" boot/efi \
        && slx_label_gate "${KRC_IMG_MNT}" img "${SLX_PROBE_TABLE}" --census --exclude boot/efi \
        || krc_fail ".img root label pass/gate failed"
    SBV_ESP=n/a
    if [ -f "${KRC_IMG_MNT}/boot/efi/EFI/Linux/${KRE[UKI_NAME]}" ]; then
        if [ "${KR_SIGNED}" = yes ]; then
            sbverify --cert "${SBDIR}/sb.crt" "${KRC_IMG_MNT}/boot/efi/EFI/Linux/${KRE[UKI_NAME]}" >/dev/null 2>&1 \
                || krc_fail "the UKI on the new .img's ESP does not verify against ${SBDIR}/sb.crt"
            SBV_ESP=true; info "ESP copy of the UKI verifies against sb.crt"
        else
            SBV_ESP=false
        fi
    fi
    NEW_FS_TAR=""
    if [ -n "${KRE[FS_TAR]}" ]; then
        NEW_FS_TAR="${WD}/${KRE[BRAND]}-x86-amd64-${KRE[ROLE_TAG]}-${KRE[ENV]}-${NEW_TS}.fs.tar.xz"
        info "Filesystem tarball (mounted tree) -> ${NEW_FS_TAR}"
        tar -C "${KRC_IMG_MNT}" --xattrs --xattrs-include='*.*' --numeric-owner -cpf - . \
            | xz -T0 "$(krc_xz_memlimit)" -6 > "${NEW_FS_TAR}" || krc_fail "fs.tar (with xattrs) failed"
    fi
    sync
    krc_img_cleanup; trap - EXIT
    NEW_IMG="${WD}/${KRE[BRAND]}-x86-amd64-${KRE[ROLE_TAG]}-${KRE[ENV]}-${NEW_TS}.img"
    mv -f "${work}" "${NEW_IMG}"
    case "${src}" in
        *.xz) info "Compressing image (xz -T0 -${KRE[COMPRESS_LEVEL]:-6})..."
              xz -T0 "$(krc_xz_memlimit)" "-${KRE[COMPRESS_LEVEL]:-6}" -f "${NEW_IMG}"; NEW_IMG="${NEW_IMG}.xz" ;;
    esac
    info "Image: ${NEW_IMG} ($(du -sh "${NEW_IMG}" | cut -f1))"
}

# The builder's live-pack helpers (live_root_gate, live_label_gate, live_squash_excludes),
# read out of the builder exactly as tests/scripts/test-x86-live-root-pack.sh does.
krc_live_helpers() {
    local blk
    blk="$(awk '/^# ── Live-ISO root pack helpers/{f=1} f&&/^umount_chroot\(\) \{/{exit} f{print}' "${KRC_GEN}/build-x86-host-stage4.sh")"
    grep -q '^live_root_gate()' <<<"${blk}" \
        || krc_fail "cannot read the live-root gate out of build-x86-host-stage4.sh"
    # shellcheck disable=SC1090
    source <(printf '%s\n' "${blk}")
    LIVE_ROOT_MOUNTPOINTS="${KRE[LIVE_ROOT_MOUNTPOINTS]:-proc sys dev run}"
    DEFAULT_USER="${KRE[DEFAULT_USER]}"
}

krc_live_iso() {
    local src="${WD}/${KRE[LIVE_ISO]}" tree="${KRC_WORK}/live-root" oldsq="${KRC_WORK}/old.sqfs" newsq="${KRC_WORK}/squashfs.img" comp
    banner "Building LIVE image (bootable ISO: grub-mkrescue + squashfs)"
    info "Patching ${KRE[LIVE_ISO]}: the squashfs root's kernel and modules, /boot/vmlinuz and /boot/initramfs.img"
    xorriso -indev "${src}" -osirrox on -extract /LiveOS/squashfs.img "${oldsq}" > "${KRC_WORK}/xorriso-extract.log" 2>&1 \
        || { tail -n 20 "${KRC_WORK}/xorriso-extract.log" >&2; krc_fail "cannot extract /LiveOS/squashfs.img from ${KRE[LIVE_ISO]}"; }
    comp="$(unsquashfs -s "${oldsq}" 2>/dev/null | sed -n 's/^Compression //p' | head -1)"; comp="${comp:-xz}"
    rm -rf "${tree}"
    unsquashfs -no-progress -d "${tree}" "${oldsq}" >/dev/null || krc_fail "unsquashfs of the live root failed"
    rm -f "${oldsq}"
    krc_patch_kernel_tree "${tree}"
    # Never carry a kernel tree (and its module-signing key) into a live root.
    rm -rf "${tree:?}/usr/src"; mkdir -p "${tree}/usr/src"
    mksquashfs "${tree}" "${newsq}" -comp "${comp}" -noappend -quiet >/dev/null \
        || krc_fail "mksquashfs of the patched live root failed"
    rm -rf "${tree}"
    live_root_gate "${newsq}" || krc_fail "the patched live root fails the builder's live-root gate"
    live_label_gate "${newsq}" || krc_fail "the patched live root fails the builder's label gate"
    NEW_LIVE="${WD}/${KRE[BRAND]}-x86-amd64-${KRE[ROLE_TAG]}-${KRE[ENV]}-${NEW_TS}.live.iso"
    # The builder's shim post-process recipe: replay the boot images byte-for-byte and
    # replace only the three files the kernel lives in. The volume id is the CDLABEL the
    # live grub.cfg boots by, so it is restated, not left to xorriso's default.
    xorriso -indev "${src}" -outdev "${NEW_LIVE}" -volid "${KRE[LIVE_VOLID]}" \
        -boot_image any replay -hfsplus off \
        -map "${newsq}" /LiveOS/squashfs.img \
        -map "${SYSROOT}/boot/vmlinuz" /boot/vmlinuz \
        -map "${SYSROOT}/boot/initramfs-live.img" /boot/initramfs.img > "${KRC_WORK}/xorriso-live.log" 2>&1 \
        || { tail -n 20 "${KRC_WORK}/xorriso-live.log" >&2; rm -f "${NEW_LIVE}"; krc_fail "xorriso could not rewrite the live ISO"; }
    rm -f "${newsq}"
    info "Live ISO: ${NEW_LIVE} ($(du -sh "${NEW_LIVE}" | cut -f1))"
}

krc_installer_iso() {
    local src="${WD}/${KRE[INSTALLER_ISO]}"
    banner "Building INSTALLER image (installer ISO: stage4 + install-x86.sh; boot a live USB to install)"
    NEW_INSTALLER="${WD}/${KRE[BRAND]}-x86-amd64-${KRE[ROLE_TAG]}-${KRE[ENV]}-${NEW_TS}.installer.iso"
    # Only the stage4 tarball changes; the keyfile, the passphrase marker and the home
    # archive the builder put on this ISO are carried over untouched (never re-minted).
    xorriso -indev "${src}" -outdev "${NEW_INSTALLER}" -volid "${KRE[INSTALL_VOLID]}" -joliet on \
        -rm "/stage4/${KRE[STAGE4]}" -- \
        -map "${NEW_STAGE4}" "/stage4/$(basename "${NEW_STAGE4}")" > "${KRC_WORK}/xorriso-installer.log" 2>&1 \
        || { tail -n 20 "${KRC_WORK}/xorriso-installer.log" >&2; rm -f "${NEW_INSTALLER}"; krc_fail "xorriso could not rewrite the installer ISO"; }
    info "Installer ISO: ${NEW_INSTALLER}"
}

# krc_xz_memlimit — xz's thread budget from the memory this machine has FREE right now
# (half of MemAvailable, at least 256 MiB): xz -T0 shrinks its thread count to fit.
# Measured on the real run: an unbounded multi-threaded `xz -dc` of the -9 image was
# OOM-killed on a busy 31 GiB host, so decompression is single-threaded (-T1, ~65 MiB)
# and every compression is capped.
krc_xz_memlimit() {
    local kb; kb="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
    kb=$(( ${kb:-0} / 2 / 1024 )); [ "${kb}" -ge 256 ] || kb=256
    printf -- '--memlimit-compress=%sMiB' "${kb}"
}

krc_sha256() { local f="$1"; (cd "$(dirname "${f}")" && sha256sum "$(basename "${f}")" > "$(basename "${f}").sha256"); cut -d' ' -f1 < "${f}.sha256"; }

# ── the step journal: an interrupted rebuild resumes, it never strands the session ──
# <pending>/apply.state records each finished step and what it produced. A Studio
# cancel or a killed container in the middle of a 30-minute repackaging used to leave
# a build system that already carries the new kernel next to artifacts that do not —
# and a retry refused, because the kept config had moved on. Now `apply` again picks up
# after the last finished step, under the SAME stamp, so the artifact names agree.
KRC_STATE_KEYS="stamp old_ts old_kver new_kver signed sbv_sysroot sbv_esp done new_stage4 new_img new_fs_tar new_live new_installer"
declare -A KST=()
krc_state_file() { printf '%s/apply.state' "${PEND}"; }
krc_state_load() {
    local line k
    KST=()
    [ -f "$(krc_state_file)" ] || return 1
    while IFS= read -r line || [ -n "${line}" ]; do
        [[ "${line}" == *=* ]] || continue
        k="${line%%=*}"
        case " ${KRC_STATE_KEYS} " in *" ${k} "*) KST["${k}"]="${line#*=}" ;; esac
    done < "$(krc_state_file)"
    for k in ${KRC_STATE_KEYS}; do [ -n "${KST[${k}]+x}" ] || KST["${k}"]=""; done
    return 0
}
krc_state_has() { krc_state_load >/dev/null 2>&1 || return 1; case " ${KST[done]} " in *" $1 "*) return 0 ;; esac; return 1; }
krc_state_save() {
    local k f; f="$(krc_state_file)"
    KST[stamp]="${STAMP:-}"; KST[old_ts]="${OLD_TS:-}"; KST[old_kver]="${OLD_KVER:-}"; KST[new_kver]="${NEW_KVER:-}"
    KST[signed]="${KR_SIGNED:-}"; KST[sbv_sysroot]="${SBV_SYSROOT:-false}"; KST[sbv_esp]="${SBV_ESP:-n/a}"
    KST[new_stage4]="${NEW_STAGE4:-}"; KST[new_img]="${NEW_IMG:-}"; KST[new_fs_tar]="${NEW_FS_TAR:-}"
    KST[new_live]="${NEW_LIVE:-}"; KST[new_installer]="${NEW_INSTALLER:-}"
    for k in ${KRC_STATE_KEYS}; do printf '%s=%s\n' "${k}" "${KST[${k}]:-}"; done > "${f}.tmp" && mv -f "${f}.tmp" "${f}"
}
# krc_step <name> <function...> — run a step unless the journal says it finished.
krc_step() {
    local name="$1"; shift
    if case " ${KST[done]:-} " in *" ${name} "*) true ;; *) false ;; esac; then
        info "(${name}: already done by the interrupted run — kept)"
        return 0
    fi
    "$@"
    KST[done]="${KST[done]:+${KST[done]} }${name}"
    krc_state_save
}

# krc_json_str <value> — a JSON string literal (backslash and quote escaped; a .config
# value never carries a control character).
krc_json_str() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "${s}"; }
# krc_result_json — the record the Studio reads back (core/kernel_reconfig.run_apply):
# printed from the globals the apply set; the artifacts map is JSON_ART (pre-rendered).
krc_result_json() {
    local first=1 line sym old new
    printf '{\n  "stamp": %s,\n  "old_kver": %s,\n  "new_kver": %s,\n' \
        "$(krc_json_str "${STAMP}")" "$(krc_json_str "${OLD_KVER}")" "$(krc_json_str "${NEW_KVER}")"
    printf '  "old_build_ts": %s,\n  "new_build_ts": %s,\n' "$(krc_json_str "${OLD_TS}")" "$(krc_json_str "${NEW_TS}")"
    printf '  "signed": %s,\n' "$([ "${KR_SIGNED}" = yes ] && echo true || echo false)"
    printf '  "sbverify": {"sysroot": %s, "esp": %s},\n' \
        "$([ "${SBV_SYSROOT:-false}" = true ] && echo true || echo false)" "$(krc_json_str "${SBV_ESP:-n/a}")"
    printf '  "changes": ['
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        sym="${line%%: *}"; line="${line#*: }"; old="${line%% -> *}"; new="${line#* -> }"
        [ "${first}" = 1 ] || printf ', '; first=0
        printf '{"symbol": %s, "old": %s, "new": %s}' "$(krc_json_str "${sym}")" "$(krc_json_str "${old}")" "$(krc_json_str "${new}")"
    done < <(krc_config_diff "${PEND}/config.before" "${PEND}/config.applied")
    printf '],\n  "artifacts": {%s},\n  "superseded": %s\n}\n' "${JSON_ART:-}" "$(krc_json_str "superseded/${OLD_TS}")"
}

krc_apply() {
    krc_preflight
    NEW_STAGE4=""; NEW_IMG=""; NEW_FS_TAR=""; NEW_LIVE=""; NEW_INSTALLER=""; SBV_ESP=n/a; SBV_SYSROOT=false
    if krc_state_load; then
        STAMP="${KST[stamp]}"; OLD_TS="${KST[old_ts]}"; OLD_KVER="${KST[old_kver]}"; NEW_KVER="${KST[new_kver]}"
        SBV_SYSROOT="${KST[sbv_sysroot]:-false}"; SBV_ESP="${KST[sbv_esp]:-n/a}"
        NEW_STAGE4="${KST[new_stage4]}"; NEW_IMG="${KST[new_img]}"; NEW_FS_TAR="${KST[new_fs_tar]}"
        NEW_LIVE="${KST[new_live]}"; NEW_INSTALLER="${KST[new_installer]}"
        say "resuming the interrupted rebuild (stamp ${STAMP}); finished steps: ${KST[done]:-none}"
    else
        STAMP="$(date -u +%Y%m%dT%H%M%SZ)"; OLD_TS="${KRE[BUILD_TS]}"
        [ "${STAMP}" != "${OLD_TS}" ] || krc_refuse "Two rebuilds within the same second — try again."
        KST[done]=""; krc_state_save
    fi
    NEW_TS="${STAMP}"
    KRC_WORK="${KRC_ROOT}/work-${STAMP}"
    # A run killed during the .img step leaves loop devices on its scratch image.
    local l; for l in $(losetup -j "${KRC_WORK}/work.img" 2>/dev/null | cut -d: -f1); do losetup -d "${l}" 2>/dev/null || true; done
    rm -rf "${KRC_WORK}"; mkdir -p "${KRC_WORK}"
    export TMPDIR="${KRC_WORK}"
    say "applying the pending kernel config edit (stamp ${STAMP}):"
    krc_config_diff "${PEND}/config.before" "${PEND}/config.after" | sed 's/^/    /'
    krc_step kernel krc_kernel_rebuild
    krc_step sign krc_sign
    krc_step label krc_label_sysroot
    [ -n "${KRE[STAGE4]}" ] && krc_step stage4 krc_pack_stage4
    [ -n "${KRE[IMG]}" ] && krc_step img krc_img_patch
    if [ -n "${KRE[LIVE_ISO]}" ]; then krc_live_helpers; krc_step live krc_live_iso; fi
    [ -n "${KRE[INSTALLER_ISO]}" ] && [ -n "${NEW_STAGE4}" ] && krc_step installer krc_installer_iso

    banner "Checksums and superseded artifacts"
    local sup="${WD}/superseded/${OLD_TS}" k f new h
    JSON_ART=""
    mkdir -p "${sup}"
    declare -A NEWOF=([STAGE4]="${NEW_STAGE4}" [IMG]="${NEW_IMG}" [FS_TAR]="${NEW_FS_TAR}"
                      [LIVE_ISO]="${NEW_LIVE}" [INSTALLER_ISO]="${NEW_INSTALLER}")
    for k in STAGE4 IMG FS_TAR LIVE_ISO INSTALLER_ISO; do
        f="${KRE[${k}]:-}"; new="${NEWOF[${k}]}"
        [ -n "${f}" ] && [ -n "${new}" ] || continue
        h="$(krc_sha256 "${new}")"
        JSON_ART="${JSON_ART}${JSON_ART:+, }$(krc_json_str "$(basename "${new}")"): $(krc_json_str "${h}")"
        # A resumed run may already have moved the original, or even rewritten the
        # contract to the new names: never move the NEW artifact into superseded/.
        if [ "${f}" != "$(basename "${new}")" ]; then
            [ -f "${WD}/${f}" ] && mv -f "${WD}/${f}" "${sup}/"
            [ -f "${WD}/${f}.sha256" ] && mv -f "${WD}/${f}.sha256" "${sup}/"
        fi
        KRE["${k}"]="$(basename "${new}")"
        info "${KRE[${k}]}  sha256 ${h}"
    done
    info "The previous artifacts are kept in ${sup}/ (delete them once the new ones are proven)"
    KRE[BUILD_TS]="${NEW_TS}"; KRE[KVER]="${NEW_KVER}"; KRE[KERNEL_CONFIG]="kernel/config-${NEW_KVER}"
    [ "${KR_SIGNED}" = yes ] && KRE[UKI_SIGNED]=yes || KRE[UKI_SIGNED]=no
    krc_write_env

    local hist="${KRC_ROOT}/${STAMP}"
    krc_result_json > "${PEND}/result.json.tmp" && mv -f "${PEND}/result.json.tmp" "${PEND}/result.json"
    mv -f "${PEND}" "${hist}"
    chmod 0644 "${hist}"/*; chmod 0755 "${hist}"
    rm -rf "${KRC_WORK}"
    say "done: kernel ${OLD_KVER} -> ${NEW_KVER}; artifacts repackaged as ${NEW_TS}"
    printf 'KRC_RESULT=%s\n' "${hist}/result.json"
}

krc_main() {
    krc_args "$@"
    case "${VERB}" in
        status)  krc_status ;;
        edit)    krc_edit ;;
        set)     krc_set ;;
        diff)    krc_diff_verb ;;
        discard) krc_discard ;;
        apply)   [ "$(id -u)" = 0 ] || krc_refuse "The kernel rebuild runs as root (natively with sudo, or in the builder container)."; krc_apply ;;
    esac
}
# KRC_LIB_ONLY=1: define everything, run nothing — tests/scripts/test-kernel-reconfig-x86.sh
# sources the REAL functions and executes them against fixture build roots.
[ -n "${KRC_LIB_ONLY:-}" ] || krc_main "$@"
