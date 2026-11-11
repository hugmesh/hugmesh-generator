#!/usr/bin/env bash
# test-kernel-reconfig-x86.sh — scripts/kernel-reconfig-x86.sh (the Studio's "Kernel
# config…" button) and the builder half of its contract, EXECUTED against fixture build
# roots. No root, no chroot, no network, no kernel tree: the real functions are sourced
# (KRC_LIB_ONLY=1, and the builder's own functions are cut out of the builder with awk,
# as the other builder suites do) and only the outside world is stubbed — the chroot,
# sbsign/sbverify, the owner gate (a fixture cannot be root's).
#
#   1  usage and verbs
#   2  the config diff (CONFIG_X: old -> new, not-set spelled out)
#   3  refusals of the shared locate step (no build system / no tree / no kept config)
#   4  the scripted edit (set) / diff / discard round trip, and a stale pending edit
#   5  edit without a terminal refuses; apply as non-root refuses
#   6  apply preflight refusals: lock held, no env, nothing to apply, unchanged edit,
#      signed image without its key (and NO key is minted), missing artifact,
#      out-of-tree modules, too little disk — and a clean preflight passes
#   7  the kernel rebuild: the REAL builder asserts refuse a config without SELinux and
#      the tree .config is restored; a LOCALVERSION change installs the new release,
#      drops the old modules/initramfs, moves the kept config and writes the marker
#   8  signing is strict: sbsign failure and sbverify failure are fatal, the old signed
#      UKI is never replaced by an unsigned one; an image built unsigned stays unsigned
#   9  grub.cfg initrd rewrite (literal, dots are not wildcards; proven after)
#  10  pins against the builder: the stage4 exclude set, the live dracut call, no
#      kernel-cache store from the reconfig path
#  11  the builder half: the `reconfigured` marker forces a cache MISS and removes the
#      edited kernel; the final .config is kept on a miss and a hit; the env contract
#      holds no secret, only basenames, and the reader never executes a value
#
# Mutation-tested (see the PR): each numbered property goes red when its line in the
# script or the builder is broken.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
KRC="${REPO}/scripts/kernel-reconfig-x86.sh"
BUILDER="${REPO}/build-x86-host-stage4.sh"
ASSERTS="${REPO}/scripts/_x86-kernel-asserts.sh"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT
KV="6.0.1-gentoo"

# ── fixtures ────────────────────────────────────────────────────────────────────
# A .config that passes every assert in the REAL scripts/_x86-kernel-asserts.sh: each
# CONFIG_ symbol the asserts name is =y, CONFIG_LSM is the exact string.
good_config() {
    {
        grep -oE 'CONFIG_[A-Z0-9_]+' "${ASSERTS}" | grep -v '^CONFIG_LSM$' | sort -u | sed 's/$/=y/'
        echo 'CONFIG_LSM="lockdown,yama,selinux,bpf"'
        echo 'CONFIG_LOCALVERSION=""'
        echo 'CONFIG_USB_NET_CDC_NCM=m'
        echo '# CONFIG_EXT2_FS is not set'
    } > "$1"
}
# A stand-in for the kernel's scripts/config (GPL; not vendored): the four actions the
# suite uses, same argv shape (--file F first).
fake_scripts_config() {
    cat > "$1" <<'SH'
#!/bin/bash
[ "$1" = --file ] || exit 2; f="$2"; shift 2
set_line() { local s="CONFIG_${1#CONFIG_}" v="$2"; sed -i "/^${s}=/d; /^# ${s} is not set\$/d" "$f"; printf '%s\n' "${v/@S@/${s}}" >> "$f"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --set-str) set_line "$2" "@S@=\"$3\""; shift 3 ;;
        --enable)  set_line "$2" "@S@=y"; shift 2 ;;
        --module)  set_line "$2" "@S@=m"; shift 2 ;;
        --disable) set_line "$2" "# @S@ is not set"; shift 2 ;;
        *) exit 2 ;;
    esac
done
SH
    chmod +x "$1"
}
# mkbr <dir> — a finished x86 build root: sysroot with a kernel tree, modules, /boot,
# the kept config, the env contract and artifacts in the work dir.
mkbr() {
    local wd="$1" br="$1/wl-pki.x86" s
    s="${br}/sysroot"
    rm -rf "${wd}"; mkdir -p "${s}/usr/src/linux-${KV}/scripts" "${s}/usr/lib/modules/${KV}/kernel" "${s}/boot" "${s}/tmp" "${s}/var/tmp" "${br}/kernel" "${wd}/secureboot"
    ln -s usr/lib "${s}/lib"
    ln -s "linux-${KV}" "${s}/usr/src/linux"
    printf 'VERSION = 6\n' > "${s}/usr/src/linux-${KV}/Makefile"
    fake_scripts_config "${s}/usr/src/linux-${KV}/scripts/config"
    good_config "${br}/kernel/config-${KV}"
    cp "${br}/kernel/config-${KV}" "${s}/usr/src/linux-${KV}/.config"
    echo ko > "${s}/usr/lib/modules/${KV}/kernel/a.ko"
    echo k > "${s}/boot/vmlinuz"; echo i > "${s}/boot/initramfs-${KV}.img"; echo SIGNED-OLD > "${s}/boot/hugmesh.efi"
    local ts=20261111T000000Z a
    for a in stage4.tar.xz img.xz fs.tar.xz live.iso installer.iso; do echo x > "${wd}/hugmesh-x86-amd64-pki-test-${ts}.${a}"; done
    cat > "${br}/kernel-reconfig.env" <<EOF
KR_FORMAT=1
BUILD_TS=${ts}
BRAND=hugmesh
BRAND_TITLE=HugMesh
ROLE=pki
ROLE_TAG=pki
ROLE_K8S=control-plane
ENV=test
UKI_NAME=hugmesh.efi
ROOT_LABEL=SNAP_ROOT
SECURE_BOOT=true
UKI_SIGNED=no
DEFAULT_USER=snap
SLX_TYPE=strict
JOBS=4
KVER=${KV}
KERNEL_CONFIG=kernel/config-${KV}
STAGE4=hugmesh-x86-amd64-pki-test-${ts}.stage4.tar.xz
IMG=hugmesh-x86-amd64-pki-test-${ts}.img.xz
FS_TAR=hugmesh-x86-amd64-pki-test-${ts}.fs.tar.xz
LIVE_ISO=hugmesh-x86-amd64-pki-test-${ts}.live.iso
INSTALLER_ISO=hugmesh-x86-amd64-pki-test-${ts}.installer.iso
EOF
}
# Fake tools for the preflight's "is it on this host" checks and for the signer.
FAKEBIN="${TMPD}/bin"; mkdir -p "${FAKEBIN}"
for t in sfdisk losetup unsquashfs mksquashfs xorriso; do
    command -v "${t}" >/dev/null || { printf '#!/bin/sh\nexit 0\n' > "${FAKEBIN}/${t}"; chmod +x "${FAKEBIN}/${t}"; }
done
export PATH="${FAKEBIN}:${PATH}"

# run_lib <wd> <snippet> — source the REAL script in library mode (stubs for what a
# fixture cannot be) and run <snippet> in a fresh shell; prints its output, returns rc.
run_lib() {
    local wd="$1" snippet="$2"
    bash -c '
        set -euo pipefail
        KRC_LIB_ONLY=1 source "$1"
        hmr_owner_gate() { return 0; }          # a fixture is never root-owned
        hmr_stale_mounts() { :; }
        krc_paths "$2/wl-pki.x86" "$2"
        eval "$3"
    ' _ "${KRC}" "${wd}" "${snippet}" 2>&1
}

echo "== kernel reconfiguration (x86) =="

echo "-- 1) usage and verbs --"
bash "${KRC}" >/dev/null 2>&1; [ $? -eq 2 ] && ok "no verb -> usage, exit 2" || bad "no verb did not exit 2"
bash "${KRC}" frobnicate --build-root /x >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown verb -> exit 2" || bad "unknown verb did not exit 2"
bash "${KRC}" status >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing --build-root -> exit 2" || bad "missing --build-root did not exit 2"

echo "-- 2) the config diff --"
printf 'CONFIG_A=y\nCONFIG_B=m\nCONFIG_LOCALVERSION=""\n# CONFIG_C is not set\nCONFIG_GONE=y\n' > "${TMPD}/b"
printf 'CONFIG_A=y\n# CONFIG_B is not set\nCONFIG_LOCALVERSION="-hmtest"\nCONFIG_C=y\nCONFIG_NEW=m\n' > "${TMPD}/a"
d="$(KRC_LIB_ONLY=1 bash -c 'source "$1"; krc_config_diff "$2" "$3"' _ "${KRC}" "${TMPD}/b" "${TMPD}/a")"
want='CONFIG_B: m -> n (not set)
CONFIG_C: n (not set) -> y
CONFIG_GONE: y -> (unset)
CONFIG_LOCALVERSION: "" -> "-hmtest"
CONFIG_NEW: (unset) -> m'
[ "${d}" = "${want}" ] && ok "diff names every changed symbol, old -> new, sorted, unchanged ones omitted" || bad "diff wrong:
${d}"

echo "-- 3) locate refusals --"
W="${TMPD}/w3"; mkdir -p "${W}/wl-pki.x86"
out="$(bash "${KRC}" set --build-root "${W}/wl-pki.x86" -- --enable X 2>&1)"; rc=$?
[ "${rc}" -eq 3 ] && grep -q 'REFUSED: The build system for this image is gone' <<<"${out}" && ok "no sysroot -> one-sentence refusal (exit 3)" || bad "no-sysroot refusal wrong (rc=${rc}): ${out}"
out="$(bash "${KRC}" status --build-root "${W}/wl-pki.x86" 2>&1)"
grep -qx 'SYSROOT=missing' <<<"${out}" && grep -qx 'ENV=missing' <<<"${out}" && ok "status reports a missing build system and contract" || bad "status wrong: ${out}"
mkbr "${W}"; rm "${W}/wl-pki.x86/sysroot/usr/src/linux"
out="$(bash "${KRC}" set --build-root "${W}/wl-pki.x86" -- --enable X 2>&1)"; rc=$?
[ "${rc}" -eq 3 ] && grep -q 'kernel source tree is not in this image' <<<"${out}" && ok "no kernel tree -> refusal" || bad "no-tree refusal wrong (rc=${rc}): ${out}"
mkbr "${W}"; rm "${W}/wl-pki.x86/kernel/config-${KV}"
out="$(bash "${KRC}" set --build-root "${W}/wl-pki.x86" -- --enable X 2>&1)"; rc=$?
[ "${rc}" -eq 3 ] && grep -q 'No kernel config was kept for' <<<"${out}" && ok "no kept config (pre-contract build / old cache entry) -> refusal" || bad "no-config refusal wrong (rc=${rc}): ${out}"

echo "-- 4) set / diff / discard --"
mkbr "${W}"; B="${W}/wl-pki.x86"
out="$(bash "${KRC}" set --build-root "${B}" -- --set-str LOCALVERSION -hmtest 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && [ -f "${B}/kernel-reconfig/pending/config.after" ] && grep -q 'CONFIG_LOCALVERSION: "" -> "-hmtest"' <<<"${out}" \
    && ok "set writes pending/config.after and prints the change" || bad "set failed (rc=${rc}): ${out}"
cmp -s "${B}/kernel/config-${KV}" "${B}/sysroot/usr/src/linux-${KV}/.config" && cmp -s "${B}/kernel/config-${KV}" "${B}/kernel-reconfig/pending/config.before" \
    && ok "the build's own .config and the kept config are untouched by an edit" || bad "an edit touched the live .config or the kept config"
bash "${KRC}" set --build-root "${B}" -- --disable USB_NET_CDC_NCM >/dev/null 2>&1
out="$(bash "${KRC}" diff --build-root "${B}" 2>&1)"
grep -q 'CONFIG_LOCALVERSION' <<<"${out}" && grep -q 'CONFIG_USB_NET_CDC_NCM: m -> n (not set)' <<<"${out}" \
    && ok "a second set ACCUMULATES on the pending edit (module toggle m -> n)" || bad "edits did not accumulate: ${out}"
out="$(bash "${KRC}" status --build-root "${B}" 2>&1)"
grep -qx 'PENDING=yes' <<<"${out}" && grep -qx 'PENDING_CHANGED=yes' <<<"${out}" && ok "status sees the pending, changed edit" || bad "status missed the pending edit: ${out}"
echo 'CONFIG_DRIFT=y' >> "${B}/kernel/config-${KV}"
out="$(bash "${KRC}" set --build-root "${B}" -- --enable X 2>&1)"; rc=$?
[ "${rc}" -eq 3 ] && grep -q 'different kernel config' <<<"${out}" && ok "a pending edit made against another config is refused, not silently rebased" || bad "stale pending not refused (rc=${rc}): ${out}"
out="$(bash "${KRC}" discard --build-root "${B}" 2>&1)"
[ ! -e "${B}/kernel-reconfig/pending" ] && ok "discard drops the pending edit" || bad "discard left the pending edit: ${out}"

echo "-- 5) no terminal / not root --"
mkbr "${W}"
out="$(bash "${KRC}" edit --build-root "${W}/wl-pki.x86" </dev/null 2>&1)"; rc=$?
[ "${rc}" -eq 3 ] && grep -q 'menuconfig needs an interactive terminal' <<<"${out}" && ok "edit without a terminal refuses (never hangs a pipe on ncurses)" || bad "edit without tty: rc=${rc} ${out}"
if [ "$(id -u)" != 0 ]; then
    bash "${KRC}" set --build-root "${W}/wl-pki.x86" -- --enable X >/dev/null 2>&1
    out="$(bash "${KRC}" apply --build-root "${W}/wl-pki.x86" 2>&1)"; rc=$?
    [ "${rc}" -eq 3 ] && grep -q 'runs as root' <<<"${out}" && ok "apply as non-root refuses in one sentence" || bad "non-root apply: rc=${rc} ${out}"
fi

echo "-- 6) apply preflight refusals --"
pf() { mkbr "${W}"; run_lib "${W}" "$1"; }
SETX='bash "$1" set --build-root "${BR}" -- --set-str LOCALVERSION -hmtest >/dev/null; '
# lock held
mkbr "${W}"; bash "${KRC}" set --build-root "${W}/wl-pki.x86" -- --set-str LOCALVERSION -hmtest >/dev/null 2>&1
( flock 9; sleep 5 ) 9>>"${W}/wl-pki.x86.lock" & lockpid=$!; sleep 0.5
out="$(run_lib "${W}" 'krc_preflight')"; rc=$?
kill "${lockpid}" 2>/dev/null; wait "${lockpid}" 2>/dev/null
[ "${rc}" -eq 3 ] && grep -q 'still building' <<<"${out}" && ok "a held build lock refuses (the image is still building)" || bad "lock not honoured: rc=${rc} ${out}"
# no env
mkbr "${W}"; bash "${KRC}" set --build-root "${W}/wl-pki.x86" -- --set-str LOCALVERSION -hmtest >/dev/null 2>&1; rm "${W}/wl-pki.x86/kernel-reconfig.env"
out="$(run_lib "${W}" 'krc_preflight')"; rc=$?
[ "${rc}" -eq 3 ] && grep -q 'This build predates kernel reconfiguration' <<<"${out}" && ok "no contract -> 'predates kernel reconfiguration — rebuild it once'" || bad "no-env: rc=${rc} ${out}"
# nothing to apply
out="$(pf 'krc_preflight')"; rc=$?
[ "${rc}" -eq 3 ] && grep -q 'no kernel config edit to apply' <<<"${out}" && ok "no edit -> refusal" || bad "no-edit: rc=${rc} ${out}"
# unchanged edit
mkbr "${W}"; mkdir -p "${W}/wl-pki.x86/kernel-reconfig/pending"; cp "${W}/wl-pki.x86/kernel/config-${KV}" "${W}/wl-pki.x86/kernel-reconfig/pending/config.before"; cp "${W}/wl-pki.x86/kernel/config-${KV}" "${W}/wl-pki.x86/kernel-reconfig/pending/config.after"
out="$(run_lib "${W}" 'krc_preflight')"; rc=$?
[ "${rc}" -eq 3 ] && grep -q 'changes nothing' <<<"${out}" && ok "an edit that changes nothing -> refusal" || bad "unchanged: rc=${rc} ${out}"
# signed, key gone — and nothing minted
mkbr "${W}"; bash "${KRC}" set --build-root "${W}/wl-pki.x86" -- --set-str LOCALVERSION -hmtest >/dev/null 2>&1
sed -i 's/^UKI_SIGNED=no/UKI_SIGNED=yes/' "${W}/wl-pki.x86/kernel-reconfig.env"
out="$(run_lib "${W}" 'krc_preflight')"; rc=$?
[ "${rc}" -eq 3 ] && grep -q 'Secure Boot key this image was signed with is gone' <<<"${out}" && ok "signed image without its key -> refusal" || bad "missing key: rc=${rc} ${out}"
[ -z "$(ls -A "${W}/secureboot")" ] && ok "no key was minted in its place" || bad "a key appeared in ${W}/secureboot: $(ls "${W}/secureboot")"
# artifact missing
mkbr "${W}"; bash "${KRC}" set --build-root "${W}/wl-pki.x86" -- --set-str LOCALVERSION -hmtest >/dev/null 2>&1; rm "${W}"/*.live.iso
out="$(run_lib "${W}" 'krc_preflight')"; rc=$?
[ "${rc}" -eq 3 ] && grep -q 'LIVE_ISO artifact this build produced is missing' <<<"${out}" && ok "a missing artifact -> refusal naming it" || bad "missing artifact: rc=${rc} ${out}"
# out-of-tree module
mkbr "${W}"; bash "${KRC}" set --build-root "${W}/wl-pki.x86" -- --set-str LOCALVERSION -hmtest >/dev/null 2>&1
mkdir -p "${W}/wl-pki.x86/sysroot/usr/lib/modules/${KV}/video"; echo x > "${W}/wl-pki.x86/sysroot/usr/lib/modules/${KV}/video/nvidia.ko"
out="$(run_lib "${W}" 'krc_preflight')"; rc=$?
[ "${rc}" -eq 3 ] && grep -q 'out-of-tree kernel modules (nvidia.ko)' <<<"${out}" && ok "out-of-tree modules -> refusal naming them" || bad "out-of-tree: rc=${rc} ${out}"
# disk
mkbr "${W}"; bash "${KRC}" set --build-root "${W}/wl-pki.x86" -- --set-str LOCALVERSION -hmtest >/dev/null 2>&1
rm "${W}"/*.img.xz; truncate -s 64T "${W}/hugmesh-x86-amd64-pki-test-20261111T000000Z.img"; sed -i 's/^IMG=.*/IMG=hugmesh-x86-amd64-pki-test-20261111T000000Z.img/' "${W}/wl-pki.x86/kernel-reconfig.env"
out="$(run_lib "${W}" 'krc_preflight')"; rc=$?
[ "${rc}" -eq 3 ] && grep -q 'Repackaging needs about' <<<"${out}" && ok "too little disk -> refusal with both numbers" || bad "disk: rc=${rc} ${out}"
rm -f "${W}"/*.img
# clean preflight
mkbr "${W}"; bash "${KRC}" set --build-root "${W}/wl-pki.x86" -- --set-str LOCALVERSION -hmtest >/dev/null 2>&1
out="$(run_lib "${W}" 'krc_preflight; echo PREFLIGHT-OK')"; rc=$?
[ "${rc}" -eq 0 ] && grep -q PREFLIGHT-OK <<<"${out}" && ok "a complete, unsigned, changed build passes the preflight" || bad "clean preflight failed: rc=${rc} ${out}"

echo "-- 7) kernel rebuild (chroot stubbed; the REAL asserts run) --"
# The stub chroot runs the asserts script for real against the fixture tree and fakes
# only the compile: kernelrelease = version + the tree's CONFIG_LOCALVERSION.
STUBS='
krc_mount() { :; }; krc_umount() { :; }
hmr_statics_missing() { return 1; }; hmr_link_check_chroot() { return 0; }
krc_chroot() {
    case "$*" in
        *olddefconfig*) return 0 ;;
        *hm-x86-kernel-asserts.sh*) bash "${SYSROOT}/tmp/hm-x86-kernel-asserts.sh" "${KRE[ROLE_K8S]}" "${KTREE}" ;;
        *kernelrelease*) lv="$(sed -n "s/^CONFIG_LOCALVERSION=\"\(.*\)\"$/\1/p" "${KTREE}/.config")"; echo "'"${KV}"'${lv}" ;;
        *hm-x86-kernel-install.sh*)
            lv="$(sed -n "s/^CONFIG_LOCALVERSION=\"\(.*\)\"$/\1/p" "${KTREE}/.config")"; k="'"${KV}"'${lv}"
            [ "$1 $2" = "env INSTALL_MOD_STRIP=1" ] || { echo "install ran WITHOUT INSTALL_MOD_STRIP=1"; return 1; }
            mkdir -p "${SYSROOT}/usr/lib/modules/${k}"; echo new > "${SYSROOT}/boot/vmlinuz"; echo old > "${SYSROOT}/boot/vmlinuz.old"
            echo ird > "${SYSROOT}/boot/initramfs-${k}.img"; echo uki > "${SYSROOT}/boot/hugmesh-unsigned.efi" ;;
        *dmsquash-live*) echo live > "${SYSROOT}/boot/initramfs-live.img" ;;
        *) echo "unexpected chroot: $*"; return 1 ;;
    esac
}'
mkbr "${W}"; bash "${KRC}" set --build-root "${W}/wl-pki.x86" -- --disable SECURITY_SELINUX >/dev/null 2>&1
before_tree="$(cat "${W}/wl-pki.x86/sysroot/usr/src/linux-${KV}/.config")"
out="$(run_lib "${W}" "${STUBS}"'
krc_read_env; krc_locate; krc_kernel_rebuild')"; rc=$?
[ "${rc}" -eq 3 ] && grep -q 'fails the build.s hardening asserts: hardened kernel option CONFIG_SECURITY_SELINUX not enabled' <<<"${out}" \
    && ok "an edit that drops SELinux is refused by the builder's own asserts, naming the symbol" || bad "assert refusal wrong: rc=${rc} ${out}"
[ "$(cat "${W}/wl-pki.x86/sysroot/usr/src/linux-${KV}/.config")" = "${before_tree}" ] && ok "the tree's .config is restored after the refused edit" || bad "the tree's .config was left as the refused edit"
[ -d "${W}/wl-pki.x86/sysroot/usr/lib/modules/${KV}" ] && [ ! -e "${W}/wl-pki.x86/kernel/reconfigured" ] && ok "nothing was rebuilt and no marker was written" || bad "a refused edit still changed the build system"
mkbr "${W}"; bash "${KRC}" set --build-root "${W}/wl-pki.x86" -- --set-str LOCALVERSION -hmtest >/dev/null 2>&1
out="$(run_lib "${W}" "${STUBS}"'
krc_read_env; krc_locate; krc_kernel_rebuild; echo "OLD=${OLD_KVER} NEW=${NEW_KVER}"')"; rc=$?
S="${W}/wl-pki.x86/sysroot"
if [ "${rc}" -eq 0 ] && grep -q "OLD=${KV} NEW=${KV}-hmtest" <<<"${out}"; then
    ok "LOCALVERSION -hmtest rebuilds ${KV} -> ${KV}-hmtest (modules stripped before signing: INSTALL_MOD_STRIP=1)"
else bad "rebuild failed: rc=${rc} ${out}"; fi
[ ! -e "${S}/usr/lib/modules/${KV}" ] && [ ! -e "${S}/boot/initramfs-${KV}.img" ] && [ -d "${S}/usr/lib/modules/${KV}-hmtest" ] \
    && ok "the old module tree and initramfs are gone (sort -V would pick a stale one)" || bad "old kernel files left behind: $(ls "${S}/usr/lib/modules" "${S}/boot")"
[ ! -e "${S}/boot/vmlinuz.old" ] && ok "make install's vmlinuz.old is not shipped" || bad "vmlinuz.old left in /boot"
[ -f "${W}/wl-pki.x86/kernel/config-${KV}-hmtest" ] && [ ! -e "${W}/wl-pki.x86/kernel/config-${KV}" ] && ok "the kept config follows the new release" || bad "kept config not moved: $(ls "${W}/wl-pki.x86/kernel")"
grep -qx "kver=${KV}-hmtest" "${W}/wl-pki.x86/kernel/reconfigured" 2>/dev/null && ok "the reconfigured marker names the new release" || bad "marker missing/wrong"
[ -s "${S}/boot/initramfs-live.img" ] && ok "the live initramfs is rebuilt when the build has a live ISO" || bad "live initramfs not rebuilt"

echo "-- 8) strict signing --"
mkbr "${W}"; S="${W}/wl-pki.x86/sysroot"; echo uki > "${S}/boot/hugmesh-unsigned.efi"
printf '#!/bin/sh\nexit 1\n' > "${FAKEBIN}/sbsign"; printf '#!/bin/sh\nexit 0\n' > "${FAKEBIN}/sbverify"; chmod +x "${FAKEBIN}/sbsign" "${FAKEBIN}/sbverify"
echo key > "${W}/secureboot/sb.key"; echo crt > "${W}/secureboot/sb.crt"
out="$(run_lib "${W}" 'krc_read_env; KR_SIGNED=yes; SBDIR="${WD}/secureboot"; krc_sign')"; rc=$?
[ "${rc}" -eq 1 ] && grep -q 'sbsign failed' <<<"${out}" && ok "an sbsign failure is FATAL (the builder only warned)" || bad "sbsign failure: rc=${rc} ${out}"
[ "$(cat "${S}/boot/hugmesh.efi")" = SIGNED-OLD ] && ok "...and the old signed UKI is not replaced by the unsigned one" || bad "the signed UKI was overwritten after a failed sbsign"
printf '#!/bin/sh\nwhile [ $# -gt 1 ]; do [ "$1" = --output ] && { cp "$3" "$2"; exit 0; }; shift; done\nexit 1\n' > "${FAKEBIN}/sbsign"
printf '#!/bin/sh\nexit 1\n' > "${FAKEBIN}/sbverify"
out="$(run_lib "${W}" 'krc_read_env; KR_SIGNED=yes; SBDIR="${WD}/secureboot"; krc_sign')"; rc=$?
[ "${rc}" -eq 1 ] && grep -q 'does not verify against' <<<"${out}" && ok "a re-signed UKI that fails sbverify --cert sb.crt is FATAL" || bad "sbverify failure: rc=${rc} ${out}"
printf '#!/bin/sh\nexit 0\n' > "${FAKEBIN}/sbverify"; echo uki > "${S}/boot/hugmesh-unsigned.efi"
out="$(run_lib "${W}" 'krc_read_env; KR_SIGNED=yes; SBDIR="${WD}/secureboot"; krc_sign; echo "SBV=${SBV_SYSROOT}"')"; rc=$?
[ "${rc}" -eq 0 ] && grep -q 'SBV=true' <<<"${out}" && [ ! -e "${S}/boot/hugmesh-unsigned.efi" ] && ok "sign + verify pass: SBV recorded, the unsigned UKI removed" || bad "good sign path: rc=${rc} ${out}"
echo uki > "${S}/boot/hugmesh-unsigned.efi"
out="$(run_lib "${W}" 'krc_read_env; KR_SIGNED=no; krc_sign; echo "SBV=${SBV_SYSROOT}"')"; rc=$?
[ "${rc}" -eq 0 ] && grep -q 'stays unsigned' <<<"${out}" && [ "$(cat "${S}/boot/hugmesh.efi")" = uki ] && ok "an image built unsigned stays unsigned, and says so" || bad "unsigned path: rc=${rc} ${out}"
rm -f "${FAKEBIN}/sbsign" "${FAKEBIN}/sbverify"

echo "-- 9) grub.cfg initrd rewrite --"
cat > "${TMPD}/grub.cfg" <<EOF
menuentry "HugMesh (pki) — Secure Boot UKI" {
    chainloader /EFI/Linux/hugmesh.efi
}
menuentry "HugMesh (pki)" {
    linux /boot/vmlinuz root=PARTUUID=abc ro lsm=lockdown
    initrd /boot/initramfs-${KV}.img
}
menuentry "HugMesh (pki) — SELinux permissive rescue" {
    linux /boot/vmlinuz root=PARTUUID=abc ro lsm=lockdown enforcing=0
    initrd /boot/initramfs-${KV}.img
}
EOF
out="$(KRC_LIB_ONLY=1 bash -c 'source "$1"; krc_grub_rewrite "$2" "$3" "$4" && echo DONE' _ "${KRC}" "${TMPD}/grub.cfg" "${KV}" "${KV}-hmtest" 2>&1)"
[ "$(grep -c "initrd /boot/initramfs-${KV}-hmtest.img" "${TMPD}/grub.cfg")" = 2 ] && ! grep -q "initramfs-${KV}.img" "${TMPD}/grub.cfg" && grep -q DONE <<<"${out}" \
    && ok "both initrd lines (default + rescue) now name the new release, none the old" || bad "rewrite wrong: $(cat "${TMPD}/grub.cfg")"
grep -q 'chainloader /EFI/Linux/hugmesh.efi' "${TMPD}/grub.cfg" && ok "the UKI chainload entry is untouched" || bad "chainload entry changed"
sed "s/initramfs-6.0.1-gentoo/initramfs-6X0.1-gentoo/" "${TMPD}/grub.cfg" > "${TMPD}/grub2.cfg"; sed -i "s/${KV}-hmtest/6X0.1-gentoo/" "${TMPD}/grub2.cfg"
out="$(KRC_LIB_ONLY=1 bash -c 'source "$1"; krc_grub_rewrite "$2" "$3" "$4"' _ "${KRC}" "${TMPD}/grub2.cfg" "${KV}" "${KV}-hmtest" 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && grep -q 'initramfs-6X0.1-gentoo' "${TMPD}/grub2.cfg" && ok "the old release is matched LITERALLY (6X0.1 is not 6.0.1) and a no-op rewrite fails" || bad "rewrite treated dots as wildcards or passed a no-op: rc=${rc}"

echo "-- 10) pins against the builder --"
excl() { grep -oE -- "--exclude=['\"]?[^'\" ]+" "$1" | sed -E "s/--exclude=['\"]?//; s/\\$\\{KRE\\[DEFAULT_USER\\]\\}/\${DEFAULT_USER}/" | sort -u; }
blk_b="$(awk '/^banner "Packaging stage4 tarball"/{f=1} f&&/^tar -C "\$\{SYSROOT\}"/{t=1} t{print} t&&/-cpf - \./{exit}' "${BUILDER}")"
blk_k="$(awk '/^krc_pack_stage4\(\)/{f=1} f&&/tar -C "\$\{SYSROOT\}"/{t=1} t{print} t&&/-cpf - \./{exit}' "${KRC}")"
printf '%s\n' "${blk_b}" > "${TMPD}/tb"; printf '%s\n' "${blk_k}" > "${TMPD}/tk"
if [ -n "${blk_b}" ] && [ -n "${blk_k}" ] && diff <({ excl "${TMPD}/tb"; echo './boot/initramfs-live.img'; } | sort) <(excl "${TMPD}/tk") >/dev/null; then
    ok "the repackaged stage4 excludes exactly the builder's set (+ the live initramfs the builder never had at pack time)"
else bad "stage4 exclude sets differ: $(diff <({ excl "${TMPD}/tb"; echo './boot/initramfs-live.img'; } | sort) <(excl "${TMPD}/tk") | tr '\n' ' ')"; fi
dr() { grep -E -- '--add|--add-drivers' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]*\\$//'; }
awk '/^dracut --force --no-hostonly \\$/{f=1} f{print} f&&/--kver/{exit}' "${BUILDER}" > "${TMPD}/db"
awk '/^krc_live_initramfs\(\)/{f=1} f{print} f&&/--kver/{exit}' "${KRC}" > "${TMPD}/dk"
[ -s "${TMPD}/db" ] && [ "$(dr "${TMPD}/db")" = "$(dr "${TMPD}/dk")" ] && grep -q '/boot/initramfs-live.img' "${TMPD}/dk" \
    && ok "the live initramfs is rebuilt with the builder's exact dracut modules and drivers" || bad "live dracut call drifted from the builder's"
grep -vE '^[[:space:]]*#' "${KRC}" | grep -E 'kc_store|kernel_cache_store' >/dev/null \
    && bad "the reconfig path publishes to the kernel cache (an edited kernel would be served to the fleet)" || ok "the reconfig path never stores into the kernel cache"
grep -q 'scripts/_x86-kernel-asserts.sh' "${KRC}" && grep -q 'scripts/_x86-kernel-install.sh' "${KRC}" \
    && ok "the reconfig path runs the builder's own assert + install scripts" || bad "the reconfig path does not run the shared scripts"

echo "-- 11) the builder half of the contract --"
fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{"{f=1} f{print} f&&/^}/{exit}' "${BUILDER}"; }
{ fn kernel_reconfig_reset; fn kernel_config_preserve; fn kernel_cache_try_restore; } > "${TMPD}/bfn.sh"
[ "$(grep -c '^[a-z_]*() {' "${TMPD}/bfn.sh")" = 3 ] && ok "extracted kernel_reconfig_reset / kernel_config_preserve / kernel_cache_try_restore" || bad "could not extract the builder's reconfig functions"
BH='warn(){ echo "WARN: $*"; }; info(){ echo "INFO: $*"; }; kc_info(){ echo "KC: $*"; }; kc_prune(){ :; }
kc_lookup(){ echo LOOKUP-CALLED >&2; }; kc_restore(){ return 1; }; kc_unpack(){ return 1; }
KERNEL_CACHE_ROOT=/nonexistent; KCACHE_KVER=v; KCACHE_CFG=c; KCACHE_FP=f; KCACHE_TMP=/nonexistent/tmp'
mkdir -p "${TMPD}/b11/sysroot/lib/modules/${KV}-hmtest" "${TMPD}/b11/sysroot/lib/modules/${KV}" "${TMPD}/b11/sysroot/boot" "${TMPD}/b11/kernel"
echo i > "${TMPD}/b11/sysroot/boot/initramfs-${KV}-hmtest.img"; printf 'kver=%s\norig_kver=%s\n' "${KV}-hmtest" "${KV}" > "${TMPD}/b11/kernel/reconfigured"; echo c > "${TMPD}/b11/kernel/config-${KV}-hmtest"
out="$(bash -c "set -u; ${BH}; source '${TMPD}/bfn.sh'; SYSROOT='${TMPD}/b11/sysroot'; KRC_DIR='${TMPD}/b11/kernel'; KRC_FORCE_MISS=false; KCACHE_KEY=k; KCACHE_HIT=false
kernel_reconfig_reset; echo FORCE=\${KRC_FORCE_MISS}; kernel_cache_try_restore; echo RESTORE_RC=\$?" 2>&1)"
grep -q 'FORCE=true' <<<"${out}" && grep -q 'RESTORE_RC=1' <<<"${out}" && ! grep -q LOOKUP-CALLED <<<"${out}" \
    && ok "a reconfigured marker forces a cache MISS (no lookup at all)" || bad "marker did not force a miss: ${out}"
[ ! -e "${TMPD}/b11/sysroot/lib/modules/${KV}-hmtest" ] && [ ! -e "${TMPD}/b11/sysroot/boot/initramfs-${KV}-hmtest.img" ] && [ -d "${TMPD}/b11/sysroot/lib/modules/${KV}" ] \
    && ok "...and removes ONLY the edited kernel's modules and initramfs" || bad "marker cleanup wrong: $(ls "${TMPD}/b11/sysroot/lib/modules")"
[ ! -e "${TMPD}/b11/kernel/reconfigured" ] && [ -z "$(ls "${TMPD}/b11/kernel")" ] && ok "...and clears the marker and stale kept configs" || bad "marker/config not cleared: $(ls "${TMPD}/b11/kernel")"
grep -q 'menuconfig edit is DISCARDED' <<<"${out}" && ok "...and warns that the edit is discarded" || bad "no discard warning: ${out}"
out="$(bash -c "set -u; ${BH}; source '${TMPD}/bfn.sh'; SYSROOT='${TMPD}/b11/sysroot'; KRC_DIR='${TMPD}/b11/kernel'; KRC_FORCE_MISS=false; KCACHE_KEY=k; KCACHE_HIT=false
kernel_reconfig_reset; kernel_cache_try_restore; echo RC=\$?" 2>&1)"
grep -q LOOKUP-CALLED <<<"${out}" && ok "without a marker the cache is consulted as before" || bad "no-marker path skipped the lookup: ${out}"
mkdir -p "${TMPD}/b11/sysroot/usr/src/linux"; echo 'CONFIG_X=y' > "${TMPD}/b11/sysroot/usr/src/linux/.config"
out="$(bash -c "set -u; ${BH}; source '${TMPD}/bfn.sh'; SYSROOT='${TMPD}/b11/sysroot'; KRC_DIR='${TMPD}/b11/kernel'; KCACHE_HIT=false; KCACHE_RESTORED_CONFIG=''; kernel_config_preserve" 2>&1)"
cmp -s "${TMPD}/b11/kernel/config-${KV}" "${TMPD}/b11/sysroot/usr/src/linux/.config" && ok "cache MISS: the final .config is kept as kernel/config-<kver>" || bad "miss did not keep the config: ${out}"
rm -f "${TMPD}/b11/kernel"/config-*; echo 'CONFIG_FROM_CACHE=y' > "${TMPD}/b11/kernel/config.from-cache"
bash -c "set -u; ${BH}; source '${TMPD}/bfn.sh'; SYSROOT='${TMPD}/b11/sysroot'; KRC_DIR='${TMPD}/b11/kernel'; KCACHE_HIT=true; KCACHE_RESTORED_CONFIG='${TMPD}/b11/kernel/config.from-cache'; kernel_config_preserve" >/dev/null 2>&1
grep -qx 'CONFIG_FROM_CACHE=y' "${TMPD}/b11/kernel/config-${KV}" 2>/dev/null && [ ! -e "${TMPD}/b11/kernel/config.from-cache" ] && ok "cache HIT: the cached config is kept (the sysroot has none)" || bad "hit did not keep the cached config"
rm -f "${TMPD}/b11/kernel"/config-*
out="$(bash -c "set -u; ${BH}; source '${TMPD}/bfn.sh'; SYSROOT='${TMPD}/b11/sysroot'; KRC_DIR='${TMPD}/b11/kernel'; KCACHE_HIT=true; KCACHE_RESTORED_CONFIG=''; kernel_config_preserve" 2>&1)"
[ -z "$(ls "${TMPD}/b11/kernel")" ] && grep -q 'will refuse this image' <<<"${out}" && ok "an old cache entry with no config keeps nothing and says the Studio will refuse" || bad "old-entry hit: ${out}"
grep -q '"config=${SYSROOT}/usr/src/linux/.config"' "${BUILDER}" && ok "kernel_cache_store publishes the .config as the optional 'config' payload" || bad "the cache store no longer carries the config"

# The env contract: cut _krc_base + kernel_reconfig_env out of the builder and run them
# with secrets set in the environment — none may reach the file.
{ awk '/^_krc_base\(\) /{print}' "${BUILDER}"; fn kernel_reconfig_env; } > "${TMPD}/envfn.sh"
mkdir -p "${TMPD}/b12/sysroot/lib/modules/${KV}" "${TMPD}/b12/sysroot/boot" "${TMPD}/b12/kernel"; echo c > "${TMPD}/b12/kernel/config-${KV}"
out="$(bash -c "set -u; info(){ :; }; warn(){ echo WARN \$*; }; source '${TMPD}/envfn.sh'
BUILD_ROOT='${TMPD}/b12'; SYSROOT='${TMPD}/b12/sysroot'; KRC_DIR='${TMPD}/b12/kernel'; UKI_NAME=hugmesh.efi; SBCRT=''
LUKS_PASS='luks-SECRET-1'; LOCAL_PASS='login-SECRET-2'; USER_PASSWORD='user-SECRET-3'; ROOT_PASSWORD='root-SECRET-4'
BUILD_TS=20261111T010203Z BRAND=hugmesh BRAND_TITLE='Hug Mesh' ROLE=pki ROLE_TAG=pki ROLE_K8S=control-plane ENV=test UNAFFILIATED=false
ROOT_LABEL=SNAP_ROOT ESP_LABEL=SNAP_ESP SB_ETC_DIR=/etc/hugmesh/secureboot SB_EFI_VENDOR=hugmesh SECURE_BOOT=true DEFAULT_USER=snap
LIVE_ROOT_MOUNTPOINTS='proc sys dev run' LIVE_VOLID=HUGMESH_LIVE INSTALL_VOLID=HUGMESH_INSTALL SLX_TYPE=strict JOBS=4 KCACHE_HIT=false
COMPRESS_IMG=true COMPRESS_LEVEL=9 STAGE4=/out/a.stage4.tar.xz IMG_PATH=/out/a.img.xz FS_TAR_PATH='(not built)'
ISO_PATH=/out/a.live.iso INSTALLER_ISO_PATH='/out/a.installer.iso'
kernel_reconfig_env; cat '${TMPD}/b12/kernel-reconfig.env'" 2>&1)"
grep -q 'SECRET' <<<"${out}" && bad "a secret reached kernel-reconfig.env: $(grep SECRET <<<"${out}")" || ok "no password/LUKS value reaches kernel-reconfig.env"
grep -qx 'KR_FORMAT=1' <<<"${out}" && grep -qx 'BRAND_TITLE=Hug Mesh' <<<"${out}" && grep -qx "KVER=${KV}" <<<"${out}" && grep -qx "KERNEL_CONFIG=kernel/config-${KV}" <<<"${out}" \
    && ok "the contract carries the format, the release and the kept config's path" || bad "contract fields wrong: ${out}"
grep -qx 'IMG=a.img.xz' <<<"${out}" && grep -qx 'FS_TAR=' <<<"${out}" && grep -qx 'LIVE_ISO=a.live.iso' <<<"${out}" && ! grep -E '^(STAGE4|IMG|FS_TAR|LIVE_ISO|INSTALLER_ISO)=.*/' <<<"${out}" >/dev/null \
    && ok "artifacts are recorded as basenames, '(not built)' as empty" || bad "artifact names wrong: ${out}"
grep -qx 'UKI_SIGNED=no' <<<"${out}" && ok "UKI_SIGNED=no when nothing verified (never assumed)" || bad "UKI_SIGNED wrong: ${out}"
KEYS_W="$(grep -oE '^[A-Z_0-9]+' <<<"${out}" | grep -v '^WARN' | sort | tr '\n' ' ')"
KEYS_R="$(KRC_LIB_ONLY=1 bash -c 'source "$1"; printf "%s\n" ${KRC_ENV_KEYS}' _ "${KRC}" | sort | tr '\n' ' ')"
[ "${KEYS_W}" = "${KEYS_R}" ] && ok "the builder writes exactly the keys the reconfig script reads" || bad "contract key sets differ: writer [${KEYS_W}] reader [${KEYS_R}]"
mkbr "${W}"; printf 'BRAND=$(touch %s/PWNED)\nEVIL=1\n' "${TMPD}" >> "${W}/wl-pki.x86/kernel-reconfig.env"
out="$(run_lib "${W}" 'krc_read_env; printf "%s|%s\n" "${KRE[BRAND]}" "${KRE[EVIL]:-unset}"')"
[ ! -e "${TMPD}/PWNED" ] && grep -q "^\$(touch ${TMPD}/PWNED)|unset$" <<<"${out}" && ok "the reader never executes a value and ignores unknown keys" || bad "env reader unsafe: ${out}"

echo
echo "kernel reconfiguration (x86): ${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
