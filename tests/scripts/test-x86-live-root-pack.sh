#!/usr/bin/env bash
# test-x86-live-root-pack.sh — guards the two properties of the live-ISO rootfs pack
# in build-x86-host-stage4.sh without which the live boot dies right after
# `dracut: Switching root` (2026-10-28, every live ISO this builder had shipped):
#
#   1. MOUNT POINTS — `mksquashfs -e proc sys dev run` drops the DIRECTORIES, so
#      switch_root cannot move /dev /proc /sys /run into the live root and PID 1
#      starts with no console/proc/sys (the console shows "Mount failed for
#      selinuxfs on /sys/fs/selinux: No such file or directory", then nothing).
#      The pack must exclude the CONTENTS (`proc/*` + `proc/.*`; tar `./proc/*`).
#   2. LIVE FSTAB — the sysroot's /etc/fstab is the installed image's
#      (PARTUUID=__ROOT_PARTUUID__ / and __ESP_PARTUUID__ /boot/efi). On a live
#      boot OpenRC fsck fails on them ("Filesystems couldn't be fixed", then
#      "rc: Aborting!"). The pack runs between live_fstab_swap_in and
#      live_fstab_restore, and the sysroot's own fstab must come back intact.
#
# The helpers and the pack block are EXTRACTED from the builder and EXECUTED against
# a fake sysroot (the integrity-suite pattern: a guard that only greps for the fix
# once passed on the very defect it was written for). mksquashfs is required under
# CI (squashfs-tools is installed by the suite job); on a host without it the
# executable cases are reported as NOTE and only the static ones run. The tar2sqfs
# branch is executed up to the tar stream (tar2sqfs itself is not needed).
#
# No root, no network, no chroot. Checks 1–7 below.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BUILDER="${REPO}/build-x86-host-stage4.sh"
SPEC_FSTAB="${REPO}/specs-x86/etc/fstab"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
note(){ echo "  NOTE $*"; }

TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT

echo "== x86 live-root pack guards =="

# ── Extraction ───────────────────────────────────────────────────────────────
# Helpers: the col-0 block from the banner to the line before umount_chroot().
awk '/^# ── Live-ISO root pack helpers/{f=1} f&&/^umount_chroot\(\) \{/{exit} f{print}' \
    "${BUILDER}" > "${TMPD}/helpers.sh"
# Pack block: from the squashfs rm to the live_root_gate call (inclusive).
awk '/^        rm -f "\$\{ISO_DIR\}\/LiveOS\/squashfs.img"$/{f=1} f{print} f&&/^        live_root_gate /{exit}' \
    "${BUILDER}" > "${TMPD}/pack.sh"

echo "-- 1) extraction --"
for fn in live_squash_excludes live_fstab_swap_in live_fstab_restore live_root_gate; do
  grep -q "^${fn}()" "${TMPD}/helpers.sh" && ok "helper ${fn}() extracted" || bad "helper ${fn}() not found in the extracted block"
done
if [ -s "${TMPD}/pack.sh" ] && grep -q 'live_root_gate "${ISO_DIR}/LiveOS/squashfs.img"' "${TMPD}/pack.sh"; then
  ok "pack block extracted ($(wc -l < "${TMPD}/pack.sh") lines, ends at the live-root gate)"
else
  bad "could not extract the live pack block (rm squashfs.img … live_root_gate)"
fi

# ── Static shape (always runs) ───────────────────────────────────────────────
echo "-- 2) static shape of the pack block --"
grep -q 'live_fstab_swap_in' "${TMPD}/pack.sh" && ok "pack block swaps the live fstab in before packing" || bad "pack block never calls live_fstab_swap_in"
grep -q 'live_fstab_restore' "${TMPD}/pack.sh" && ok "pack block restores the sysroot fstab after packing" || bad "pack block never calls live_fstab_restore"
grep -qE 'mksquashfs "\$\{SYSROOT\}".*' "${TMPD}/pack.sh" && grep -q -- '-wildcards -e "${LIVE_SQUASH_EXCL\[@\]}"' "${TMPD}/pack.sh" \
  && ok "mksquashfs takes its excludes from LIVE_SQUASH_EXCL with -wildcards" \
  || bad "mksquashfs line does not use -wildcards -e \"\${LIVE_SQUASH_EXCL[@]}\""
grep -vE '^[[:space:]]*#' "${TMPD}/pack.sh" | grep -E -- '-e (proc|sys|dev|run)( |$)' >/dev/null && bad "a bare mount-point name is still passed to mksquashfs -e (drops the directory)" || ok "no bare mount-point name on any -e"
grep -vE '^[[:space:]]*#' "${TMPD}/pack.sh" | grep -E -- "--exclude='\./(proc|sys|dev|run)'" >/dev/null && bad "tar fallback still excludes a bare ./<mountpoint> (drops the directory)" || ok "tar fallback carries no bare ./<mountpoint> exclude"
awk '/^umount_chroot\(\) \{/{f=1} f&&/^}/{exit} f' "${BUILDER}" | grep -E 'mv -f "\$\{LIVE_FSTAB_SAVED\}" "\$\{SYSROOT\}/etc/fstab"' >/dev/null \
  && ok "umount_chroot (the EXIT trap) restores the fstab too" || bad "umount_chroot does not restore \${LIVE_FSTAB_SAVED} — a dead pack leaves the live fstab in the sysroot"

# ── Helpers, EXECUTED ────────────────────────────────────────────────────────
echo "-- 3) live_squash_excludes, EXECUTED --"
{
  echo 'err(){ echo "ERROR: $*" >&2; }; info(){ echo "INFO: $*"; }; warn(){ echo "WARN: $*"; }'
  echo 'DEFAULT_USER=snap'
  cat "${TMPD}/helpers.sh"
  echo 'live_squash_excludes "$1" && printf "%s\n" "${LIVE_SQUASH_EXCL[@]}"'
} > "${TMPD}/run-excl"
mk="$(bash "${TMPD}/run-excl" mksquashfs 2>&1)"; tr="$(bash "${TMPD}/run-excl" tar 2>&1)"
for m in proc sys dev run; do
  grep -qx "${m}/\*" <<<"${mk}" && grep -qx "${m}/\.\*" <<<"${mk}" && ok "mksquashfs excludes ${m}/* and ${m}/.* (contents, dotfiles too)" || bad "mksquashfs excludes lack ${m}/* + ${m}/.*: ${mk}"
  grep -qx "${m}" <<<"${mk}" && bad "mksquashfs excludes still name bare '${m}'" || true
  grep -qx -- "--exclude=./${m}/\*" <<<"${tr}" && ok "tar excludes ./${m}/* (keeps the directory entry)" || bad "tar excludes lack --exclude=./${m}/*: ${tr}"
  grep -qx -- "--exclude=./${m}" <<<"${tr}" && bad "tar excludes still name bare ./${m}" || true
done
grep -qx "home/snap" <<<"${mk}" && grep -qx "var/cache/distfiles" <<<"${mk}" && ok "mksquashfs keeps the distfiles + local-user excludes" || bad "mksquashfs lost the distfiles/home excludes: ${mk}"
grep -qx -- "--exclude=./home/snap" <<<"${tr}" && ok "tar keeps the local-user exclude" || bad "tar lost the home exclude: ${tr}"

echo "-- 4) live_fstab_swap_in / live_fstab_restore, EXECUTED --"
mkfake() { # $1 = dir — the fake sysroot with everything the pack must keep or drop
  local d="$1"
  rm -rf "${d}"; mkdir -p "${d}/proc/x" "${d}/sys/y" "${d}/dev" "${d}/run/z" "${d}/etc" "${d}/usr" "${d}/home/snap" "${d}/var/cache/distfiles" "${d}/tmp"
  echo j > "${d}/proc/x/j"; echo k > "${d}/sys/y/k"; echo n > "${d}/dev/null"; echo keep > "${d}/dev/.keep"; echo w > "${d}/run/z/w"
  echo secret > "${d}/home/snap/secret"; echo dist > "${d}/var/cache/distfiles/d"; echo f > "${d}/usr/f"; echo t > "${d}/tmp/t"
  cp "${SPEC_FSTAB}" "${d}/etc/fstab"
}
FIX="${TMPD}/sysroot"; BR="${TMPD}/build-root"; mkdir -p "${BR}"; mkfake "${FIX}"
grep -q '__ROOT_PARTUUID__' "${FIX}/etc/fstab" || bad "specs-x86/etc/fstab no longer carries the PARTUUID tokens — this suite's fixture assumption broke"
{
  echo 'err(){ echo "ERROR: $*" >&2; }; info(){ echo "INFO: $*"; }; warn(){ echo "WARN: $*"; }'
  echo "DEFAULT_USER=snap; SYSROOT='${FIX}'; BUILD_ROOT='${BR}'"
  cat "${TMPD}/helpers.sh"
  cat <<'EOS'
live_fstab_swap_in || { echo SWAP_FAILED; exit 1; }
echo "--live--"; cat "${SYSROOT}/etc/fstab"; echo "--end--"
[ -f "${LIVE_FSTAB_SAVED}" ] && echo "SAVED_AT=${LIVE_FSTAB_SAVED}"
live_fstab_swap_in 2>/dev/null && echo DOUBLE_SWAP_ACCEPTED
live_fstab_restore || { echo RESTORE_FAILED; exit 1; }
live_fstab_restore || { echo RESTORE2_FAILED; exit 1; }
echo "SAVED_AFTER=${LIVE_FSTAB_SAVED:-}"
EOS
} > "${TMPD}/run-swap"
out="$(bash "${TMPD}/run-swap" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "swap-in → restore → restore(idempotent) ran clean" || bad "swap/restore sequence failed (rc=${rc}): ${out}"
live="$(sed -n '/^--live--$/,/^--end--$/p' <<<"${out}")"
grep -qE '^[[:space:]]*PARTUUID=' <<<"${live}" && bad "live fstab still carries a PARTUUID line: ${live}" || ok "live fstab has no PARTUUID/disk line"
grep -qE '^tmpfs[[:space:]]+/tmp[[:space:]]' <<<"${live}" && grep -qE '^tmpfs[[:space:]]+/var/tmp[[:space:]]' <<<"${live}" && ok "live fstab keeps the tmpfs hardening lines" || bad "live fstab lost the tmpfs lines: ${live}"
grep -q "SAVED_AT=${BR}/" <<<"${out}" && ok "the saved copy lives OUTSIDE the sysroot (cannot ride into the squashfs)" || bad "saved fstab copy is not under BUILD_ROOT: ${out}"
grep -q DOUBLE_SWAP_ACCEPTED <<<"${out}" && bad "a second swap-in over an un-restored one was accepted (would overwrite the saved original)" || ok "a second swap-in is refused while one is outstanding"
cmp -s "${FIX}/etc/fstab" "${SPEC_FSTAB}" && ok "sysroot fstab restored byte-identical" || bad "sysroot fstab NOT restored to the original"
[ -e "${BR}/fstab.img-tokens" ] && bad "saved copy left behind after restore" || ok "no saved copy left behind"
grep -q 'SAVED_AFTER=$' <<<"${out}" && ok "LIVE_FSTAB_SAVED cleared after restore" || bad "LIVE_FSTAB_SAVED not cleared: ${out}"

# ── The pack block + gate, EXECUTED (needs mksquashfs) ───────────────────────
echo "-- 5) pack block + live_root_gate, EXECUTED --"
if ! command -v mksquashfs >/dev/null || ! command -v unsquashfs >/dev/null; then
  if [ "${CI:-}" = true ]; then
    bad "mksquashfs/unsquashfs missing under CI — install squashfs-tools in the suite job (the executable half of this guard did NOT run)"
  else
    note "mksquashfs/unsquashfs not on this host — skipping the executable pack/gate cases (run inside the hugmesh-builder image to cover them)"
  fi
else
  mkfake "${FIX}"; ISO="${TMPD}/isoroot"; mkdir -p "${ISO}/LiveOS"
  {
    echo 'err(){ echo "ERROR: $*" >&2; }; info(){ echo "INFO: $*"; }; warn(){ echo "WARN: $*"; }'
    echo "DEFAULT_USER=snap; SYSROOT='${FIX}'; BUILD_ROOT='${BR}'; ISO_DIR='${ISO}'; JOBS=2"
    cat "${TMPD}/helpers.sh"
    # the block's 200 MiB sanity floor is for a real rootfs; a fixture is tiny
    sed 's/-lt 200 \]/-lt 0 ]/' "${TMPD}/pack.sh"
  } > "${TMPD}/run-pack"
  out="$(bash "${TMPD}/run-pack" 2>&1)"; rc=$?
  SQ="${ISO}/LiveOS/squashfs.img"
  if [ "${rc}" -ne 0 ] || [ ! -s "${SQ}" ]; then
    bad "the extracted pack block failed (rc=${rc}): ${out}"
  else
    ok "pack block ran (rc=0) and produced LiveOS/squashfs.img"
    top="$(unsquashfs -ls -d '' "${SQ}" 2>/dev/null | grep -E '^/')"
    for m in proc sys dev run; do
      grep -qx "/${m}" <<<"${top}" && ok "squashfs root has /${m}" || bad "squashfs root LACKS /${m} — switch_root cannot move it (this is the shipped defect)"
      grep -qE "^/${m}/" <<<"${top}" && bad "/${m} still has contents in the squashfs: $(grep -E "^/${m}/" <<<"${top}" | head -3 | tr '\n' ' ')" || ok "/${m} is empty (contents excluded, dotfiles included)"
    done
    grep -qx "/home/snap" <<<"${top}" && bad "the local user's home rode into the live root" || ok "home/snap excluded"
    grep -qx "/var/cache/distfiles/d" <<<"${top}" && bad "distfiles rode into the live root" || ok "var/cache/distfiles excluded"
    grep -qx "/usr/f" <<<"${top}" && grep -qx "/tmp/t" <<<"${top}" && ok "ordinary content kept" || bad "ordinary content missing from the squashfs"
    sqf="$(unsquashfs -cat "${SQ}" etc/fstab 2>/dev/null)"
    grep -qE '^[[:space:]]*PARTUUID=' <<<"${sqf}" && bad "squashfs /etc/fstab is the INSTALLED image's (PARTUUID lines) — OpenRC fsck would abort the live boot" || ok "squashfs /etc/fstab is the live one"
    grep -qE '^tmpfs[[:space:]]+/tmp[[:space:]]' <<<"${sqf}" && ok "squashfs /etc/fstab keeps the tmpfs lines" || bad "squashfs /etc/fstab lost the tmpfs lines"
    cmp -s "${FIX}/etc/fstab" "${SPEC_FSTAB}" && ok "sysroot fstab restored after the pack" || bad "sysroot fstab NOT restored after the pack"
    grep -q 'Live-root gate:' <<<"${out}" && ok "live_root_gate ran on the packed image and said so" || bad "no 'Live-root gate:' line in the pack output: ${out}"
  fi

  echo "-- 6) live_root_gate rejects the two shipped defects, EXECUTED --"
  {
    echo 'err(){ echo "ERROR: $*" >&2; }; info(){ echo "INFO: $*"; }; warn(){ echo "WARN: $*"; }'
    echo "DEFAULT_USER=snap"
    cat "${TMPD}/helpers.sh"
    echo 'live_root_gate "$1"'
  } > "${TMPD}/run-gate"
  mkfake "${FIX}"
  # (a) the OLD argv: bare -e proc sys dev run (directories dropped), token fstab
  mksquashfs "${FIX}" "${TMPD}/old.sqfs" -quiet -noappend -comp gzip -e proc sys dev run >/dev/null 2>&1
  if out="$(bash "${TMPD}/run-gate" "${TMPD}/old.sqfs" 2>&1)"; then
    bad "gate PASSED a squashfs with no /proc /sys /dev /run (the 2026-10-23 live ISO)"
  else
    case "${out}" in *"has no /proc directory"*) ok "gate fails the old pack and names the missing mount point" ;; *) bad "gate failed the old pack with the wrong message: ${out}" ;; esac
  fi
  # (b) directories present, but the installed image's fstab
  mksquashfs "${FIX}" "${TMPD}/fstab.sqfs" -quiet -noappend -comp gzip -wildcards -e 'proc/*' 'sys/*' 'dev/*' 'run/*' >/dev/null 2>&1
  if out="$(bash "${TMPD}/run-gate" "${TMPD}/fstab.sqfs" 2>&1)"; then
    bad "gate PASSED a live root whose /etc/fstab still addresses PARTUUID disks"
  else
    case "${out}" in *"still addresses a disk"*) ok "gate fails the token fstab and says why" ;; *) bad "gate failed the token fstab with the wrong message: ${out}" ;; esac
  fi
  # (c) a dotfile left under a mount point is NOT a mount-point failure (it is
  # shadowed by the moved devtmpfs) — the gate checks presence, not emptiness,
  # but a bare -e that keeps /dev and drops /proc must still fail on /proc
  mksquashfs "${FIX}" "${TMPD}/partial.sqfs" -quiet -noappend -comp gzip -e proc sys run >/dev/null 2>&1
  bash "${TMPD}/run-gate" "${TMPD}/partial.sqfs" >/dev/null 2>&1 && bad "gate passed a root with /dev but no /proc /sys /run" || ok "gate fails when only some mount points survive"
  # (d) a correct pack passes
  mkdir -p "${TMPD}/good"; cp -r "${FIX}/." "${TMPD}/good/"; printf 'tmpfs /tmp tmpfs defaults 0 0\n' > "${TMPD}/good/etc/fstab"
  mksquashfs "${TMPD}/good" "${TMPD}/good.sqfs" -quiet -noappend -comp gzip -wildcards -e 'proc/*' 'sys/*' 'dev/*' 'dev/.*' 'run/*' >/dev/null 2>&1
  if out="$(bash "${TMPD}/run-gate" "${TMPD}/good.sqfs" 2>&1)"; then
    ok "gate passes a correct live root"
  else
    bad "gate FAILS a correct live root: ${out}"
  fi
fi

# ── tar2sqfs branch, EXECUTED up to the tar stream ───────────────────────────
echo "-- 7) tar2sqfs fallback stream, EXECUTED --"
mkfake "${FIX}"
awk '/^            tar -C "\$\{SYSROOT\}" --xattrs/{f=1} f{print} f&&/-cpf - \. \|/{exit}' "${TMPD}/pack.sh" \
  | sed 's/-cpf - \. |.*/-cpf - . > "${STREAM}"/' > "${TMPD}/tar-line"
if [ ! -s "${TMPD}/tar-line" ]; then
  bad "could not extract the tar2sqfs fallback's tar statement"
else
  {
    echo 'err(){ echo "ERROR: $*" >&2; }; info(){ echo "INFO: $*"; }; warn(){ echo "WARN: $*"; }'
    echo "DEFAULT_USER=snap; SYSROOT='${FIX}'; BUILD_ROOT='${BR}'; STREAM='${TMPD}/stream.tar'"
    cat "${TMPD}/helpers.sh"
    echo 'live_fstab_swap_in || exit 1'
    echo 'live_squash_excludes tar'
    cat "${TMPD}/tar-line"
    echo 'live_fstab_restore || exit 1'
  } > "${TMPD}/run-tar"
  if out="$(bash "${TMPD}/run-tar" 2>&1)" && [ -s "${TMPD}/stream.tar" ]; then
    lst="$(tar -tf "${TMPD}/stream.tar")"
    for m in proc sys dev run; do
      grep -qx "./${m}/" <<<"${lst}" && ok "tar stream keeps the ./${m}/ directory entry" || bad "tar stream LACKS ./${m}/ (the directory was excluded)"
      grep -qE "^\./${m}/." <<<"${lst}" && bad "tar stream still carries ./${m} contents" || ok "./${m} contents excluded from the tar stream"
    done
    grep -qx "./home/snap/secret" <<<"${lst}" && bad "tar stream carries the local user's home" || ok "tar stream excludes home/snap"
    tar -xOf "${TMPD}/stream.tar" ./etc/fstab 2>/dev/null | grep -E '^[[:space:]]*PARTUUID=' >/dev/null && bad "tar stream's /etc/fstab is the installed image's" || ok "tar stream's /etc/fstab is the live one"
    cmp -s "${FIX}/etc/fstab" "${SPEC_FSTAB}" && ok "sysroot fstab restored after the tar stream" || bad "sysroot fstab NOT restored after the tar stream"
  else
    bad "the extracted tar statement failed: ${out}"
  fi
fi

echo
echo "x86 live-root pack guards: ${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
