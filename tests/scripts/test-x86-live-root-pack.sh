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
#   3. NO MODULE-SIGNING KEY — the sysroot keeps the BUILT kernel tree under
#      /usr/src for kernel reconfiguration, and with it certs/signing_key.pem. The
#      live pack drops usr/src whole and live_root_gate refuses a squashfs whose
#      listing still names the key or a kernel certs/ dir — in BOTH listing arms
#      (unsquashfs, and rdsquashfs, which prints paths with no leading slash).
#   4. THE --bundle-source TREE SURVIVES — because usr/src is dropped whole, the
#      bundled generator source must live OUTSIDE it, or no artifact carries it and
#      /usr/sbin/hugmesh-regenerate can only fail. The real bundle block is
#      executed into the fake sysroot and must come out of the live pack, the
#      tar2sqfs stream AND the stage4 tar, at the path hugmesh-regenerate reads.
#
# No root, no network, no chroot. Checks 1–9 below (4b: a pack that dies mid-way).
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

# Bundle-source: the BUNDLE_SOURCE_DIR assignment (if the builder has one) and the
# `if ${BUNDLE_SOURCE:-false}; then … fi` block that stages the generator tree.
grep -E '^BUNDLE_SOURCE_DIR=' "${BUILDER}" > "${TMPD}/bundle.sh" || true
awk '/^if \$\{BUNDLE_SOURCE:-false\}; then$/{f=1} f{print} f&&/^fi$/{exit}' "${BUILDER}" >> "${TMPD}/bundle.sh"
REGEN="${REPO}/specs/usr/sbin/hugmesh-regenerate"
REGEN_SRC="$(sed -nE 's/^SRC="\$\{HUGMESH_SRC:-([^}]*)\}"$/\1/p' "${REGEN}")"

echo "-- 1) extraction --"
for fn in live_squash_excludes live_fstab_swap_in live_fstab_restore live_root_gate; do
  grep -q "^${fn}()" "${TMPD}/helpers.sh" && ok "helper ${fn}() extracted" || bad "helper ${fn}() not found in the extracted block"
done
if [ -s "${TMPD}/pack.sh" ] && grep -q 'live_root_gate "${ISO_DIR}/LiveOS/squashfs.img"' "${TMPD}/pack.sh"; then
  ok "pack block extracted ($(wc -l < "${TMPD}/pack.sh") lines, ends at the live-root gate)"
else
  bad "could not extract the live pack block (rm squashfs.img … live_root_gate)"
fi
grep -q 'hugmesh-regenerate' "${TMPD}/bundle.sh" && ok "bundle-source block extracted" || bad "could not extract the builder's 'if \${BUNDLE_SOURCE:-false}; then … fi' block"
[ -n "${REGEN_SRC}" ] && ok "hugmesh-regenerate's default source dir read (${REGEN_SRC})" || bad "could not read SRC=\"\${HUGMESH_SRC:-…}\" from ${REGEN}"

# ── Static shape (always runs) ───────────────────────────────────────────────
echo "-- 2) static shape of the pack block --"
grep -q 'live_fstab_swap_in' "${TMPD}/pack.sh" && ok "pack block swaps the live fstab in before packing" || bad "pack block never calls live_fstab_swap_in"
grep -q 'live_fstab_restore' "${TMPD}/pack.sh" && ok "pack block restores the sysroot fstab after packing" || bad "pack block never calls live_fstab_restore"
grep -qE 'mksquashfs "\$\{SYSROOT\}".*' "${TMPD}/pack.sh" && grep -q -- '-wildcards -e "${LIVE_SQUASH_EXCL\[@\]}"' "${TMPD}/pack.sh" \
  && ok "mksquashfs takes its excludes from LIVE_SQUASH_EXCL with -wildcards" \
  || bad "mksquashfs line does not use -wildcards -e \"\${LIVE_SQUASH_EXCL[@]}\""
grep -vE '^[[:space:]]*#' "${TMPD}/pack.sh" | grep -E -- '-e (proc|sys|dev|run)( |$)' >/dev/null && bad "a bare mount-point name is still passed to mksquashfs -e (drops the directory)" || ok "no bare mount-point name on any -e"
grep -vE '^[[:space:]]*#' "${TMPD}/pack.sh" | grep -E -- "--exclude='\./(proc|sys|dev|run)'" >/dev/null && bad "tar fallback still excludes a bare ./<mountpoint> (drops the directory)" || ok "tar fallback carries no bare ./<mountpoint> exclude"
grep -q '^        trap live_fstab_restore EXIT$' "${TMPD}/pack.sh" && ok "pack block arms its own EXIT trap for the swap window (umount_chroot's is disarmed before the live pack)" || bad "pack block arms no EXIT trap after live_fstab_swap_in — an exit mid-pack leaves the live fstab in the sysroot"
grep -q '^        trap - EXIT$' "${TMPD}/pack.sh" && ok "pack block disarms that trap after the restore" || bad "pack block never disarms the swap-window trap"

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
# usr/src carries the BUILT kernel tree (kept for kernel reconfiguration) and with it
# certs/signing_key.pem, the module-signing PRIVATE key: both arms drop it whole.
grep -qx "usr/src" <<<"${mk}" && ok "mksquashfs excludes usr/src (the kernel tree and its module-signing key)" || bad "mksquashfs does NOT exclude usr/src — the live ISO ships certs/signing_key.pem: ${mk}"
grep -qx -- "--exclude=./usr/src" <<<"${tr}" && ok "tar excludes ./usr/src" || bad "tar does NOT exclude ./usr/src — the live ISO ships certs/signing_key.pem: ${tr}"

echo "-- 4) live_fstab_swap_in / live_fstab_restore, EXECUTED --"
# A fake generator checkout + shared specs for the bundle block to copy from.
GEN="${TMPD}/gen"; SPECS="${TMPD}/specs"
mkdir -p "${GEN}/.git" "${GEN}/out" "${GEN}/scripts" "${SPECS}/usr/sbin"
printf '#!/bin/bash\necho fake builder\n' > "${GEN}/build-x86-host-stage4.sh"; chmod +x "${GEN}/build-x86-host-stage4.sh"
echo s > "${GEN}/scripts/s.sh"; echo g > "${GEN}/.git/HEAD"; echo o > "${GEN}/out/o"
cp "${REGEN}" "${SPECS}/usr/sbin/hugmesh-regenerate"
stage_bundle() { # $1 = sysroot — runs the builder's REAL bundle block into it
  {
    echo 'err(){ echo "ERROR: $*" >&2; }; info(){ echo "INFO: $*"; }; warn(){ echo "WARN: $*"; }'
    echo "SYSROOT='$1'; SCRIPT_DIR='${GEN}'; SHARED_SPECS='${SPECS}'; BUNDLE_SOURCE=true"
    cat "${TMPD}/bundle.sh"
  } > "${TMPD}/run-bundle"
  mkdir -p "$1/usr/sbin"
  bash "${TMPD}/run-bundle" >/dev/null 2>&1
}
mkfake() { # $1 = dir — the fake sysroot with everything the pack must keep or drop
  local d="$1"
  rm -rf "${d}"; mkdir -p "${d}/proc/x" "${d}/sys/y" "${d}/dev" "${d}/run/z" "${d}/etc" "${d}/usr" "${d}/home/snap" "${d}/var/cache/distfiles" "${d}/tmp"
  echo j > "${d}/proc/x/j"; echo k > "${d}/sys/y/k"; echo n > "${d}/dev/null"; echo keep > "${d}/dev/.keep"; echo w > "${d}/run/z/w"
  echo secret > "${d}/home/snap/secret"; echo dist > "${d}/var/cache/distfiles/d"; echo f > "${d}/usr/f"; echo t > "${d}/tmp/t"
  mkdir -p "${d}/usr/src/linux-6.0-gentoo/certs"
  printf -- '-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----\n' > "${d}/usr/src/linux-6.0-gentoo/certs/signing_key.pem"
  cp "${SPEC_FSTAB}" "${d}/etc/fstab"
  stage_bundle "${d}"
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

echo "-- 4a) the --bundle-source block, EXECUTED into the fake sysroot --"
# Where did the REAL block put the builder? That path is what every artifact must carry.
BUNDLE_REL="$(cd "${FIX}" && find . -path ./usr/sbin -prune -o -name build-x86-host-stage4.sh -print 2>/dev/null | head -1)"
BUNDLE_REL="${BUNDLE_REL#./}"; BUNDLE_REL="${BUNDLE_REL%/build-x86-host-stage4.sh}"
if [ -z "${BUNDLE_REL}" ]; then
  bad "the bundle block staged no build-x86-host-stage4.sh into the sysroot"
else
  ok "the bundle block staged the generator tree at /${BUNDLE_REL}"
  [ -x "${FIX}/usr/sbin/hugmesh-regenerate" ] && ok "the bundle block installs /usr/sbin/hugmesh-regenerate" || bad "no executable /usr/sbin/hugmesh-regenerate after the bundle block"
  [ -e "${FIX}/${BUNDLE_REL}/.git" ] || [ -e "${FIX}/${BUNDLE_REL}/out" ] && bad "the bundle carries .git or out/ (host build products)" || ok "the bundle leaves .git and out/ behind"
  [ "/${BUNDLE_REL}" = "${REGEN_SRC}" ] && ok "hugmesh-regenerate's default (${REGEN_SRC}) is where the builder stages the tree" \
    || bad "hugmesh-regenerate reads ${REGEN_SRC} but the builder stages the tree at /${BUNDLE_REL}"
  case "/${BUNDLE_REL}/" in
    /usr/src/*) bad "the bundle is staged under /usr/src, which every artifact drops whole (the module-signing key lives there): no artifact carries it and hugmesh-regenerate always fails" ;;
    *) ok "the bundle is staged outside /usr/src" ;;
  esac
fi

echo "-- 4b) a pack that dies mid-way still restores the fstab, EXECUTED --"
# A stub mksquashfs that FAILS: `command -v mksquashfs` sees the function, the pack
# block takes the mksquashfs branch, the call fails, the block `exit 1`s between
# live_fstab_swap_in and live_fstab_restore. Only the trap the block armed can put
# the installed image's fstab back (umount_chroot's EXIT trap is disarmed before
# the live pack runs in the builder, so it is NOT simulated here either).
mkfake "${FIX}"; ISO="${TMPD}/isoroot-dead"; mkdir -p "${ISO}/LiveOS"
{
  echo 'err(){ echo "ERROR: $*" >&2; }; info(){ echo "INFO: $*"; }; warn(){ echo "WARN: $*"; }'
  echo "DEFAULT_USER=snap; SYSROOT='${FIX}'; BUILD_ROOT='${BR}'; ISO_DIR='${ISO}'; JOBS=2"
  echo 'mksquashfs(){ return 1; }'
  cat "${TMPD}/helpers.sh"
  cat "${TMPD}/pack.sh"
  echo 'echo REACHED_PAST_THE_PACK'
} > "${TMPD}/run-dead-pack"
out="$(bash "${TMPD}/run-dead-pack" 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && ! grep -q REACHED_PAST_THE_PACK <<<"${out}" && ok "the block exited on the failing mksquashfs (rc=${rc})" || bad "the block did not stop on a failing mksquashfs (rc=${rc}): ${out}"
cmp -s "${FIX}/etc/fstab" "${SPEC_FSTAB}" && ok "sysroot fstab restored by the EXIT trap after the mid-pack exit" || bad "sysroot fstab left as the LIVE one after a mid-pack exit (no trap put it back)"
[ -e "${BR}/fstab.img-tokens" ] && bad "fstab.img-tokens left behind after the mid-pack exit" || ok "no fstab.img-tokens left behind after the mid-pack exit"

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
    echo 'echo "TRAP_AFTER=[$(trap -p EXIT)]"'
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
    grep -E '^/usr/src(/|$)' <<<"${top}" >/dev/null && bad "the kernel tree (and its module-signing key) rode into the live root: $(grep -E '^/usr/src' <<<"${top}" | head -3 | tr '\n' ' ')" || ok "usr/src excluded (no module-signing key in the live root)"
    [ -n "${BUNDLE_REL}" ] && grep -qx "/${BUNDLE_REL}/build-x86-host-stage4.sh" <<<"${top}" && grep -qx "/usr/sbin/hugmesh-regenerate" <<<"${top}" \
      && ok "the --bundle-source tree and hugmesh-regenerate ride into the live root" \
      || bad "the live root LACKS the --bundle-source tree (/${BUNDLE_REL:-?}) or hugmesh-regenerate"
    sqf="$(unsquashfs -cat "${SQ}" etc/fstab 2>/dev/null)"
    grep -qE '^[[:space:]]*PARTUUID=' <<<"${sqf}" && bad "squashfs /etc/fstab is the INSTALLED image's (PARTUUID lines) — OpenRC fsck would abort the live boot" || ok "squashfs /etc/fstab is the live one"
    grep -qE '^tmpfs[[:space:]]+/tmp[[:space:]]' <<<"${sqf}" && ok "squashfs /etc/fstab keeps the tmpfs lines" || bad "squashfs /etc/fstab lost the tmpfs lines"
    cmp -s "${FIX}/etc/fstab" "${SPEC_FSTAB}" && ok "sysroot fstab restored after the pack" || bad "sysroot fstab NOT restored after the pack"
    grep -q 'Live-root gate:' <<<"${out}" && ok "live_root_gate ran on the packed image and said so" || bad "no 'Live-root gate:' line in the pack output: ${out}"
    grep -q 'TRAP_AFTER=\[\]' <<<"${out}" && ok "swap-window EXIT trap disarmed after a successful pack" || bad "EXIT trap still armed after the pack: $(grep TRAP_AFTER <<<"${out}")"
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
  mksquashfs "${FIX}" "${TMPD}/fstab.sqfs" -quiet -noappend -comp gzip -wildcards -e 'proc/*' 'sys/*' 'dev/*' 'run/*' usr/src >/dev/null 2>&1
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
  # (e) mount points and fstab right, but usr/src still packed: the module-signing
  # PRIVATE key rides along — the 2026-11-11 live ISO. The gate must refuse and say so.
  mkdir -p "${TMPD}/leak"; cp -r "${FIX}/." "${TMPD}/leak/"; printf 'tmpfs /tmp tmpfs defaults 0 0\n' > "${TMPD}/leak/etc/fstab"
  mksquashfs "${TMPD}/leak" "${TMPD}/leak.sqfs" -quiet -noappend -comp gzip -wildcards -e 'proc/*' 'sys/*' 'dev/*' 'dev/.*' 'run/*' >/dev/null 2>&1
  if out="$(bash "${TMPD}/run-gate" "${TMPD}/leak.sqfs" 2>&1)"; then
    bad "gate PASSED a live root that carries usr/src/linux-*/certs/signing_key.pem"
  else
    case "${out}" in *"module-signing PRIVATE key"*) ok "gate refuses a live root carrying the module-signing key and names it" ;; *) bad "gate failed the key-leak pack with the wrong message: ${out}" ;; esac
  fi
  # (f) the key under ANY name-path: a stray signing_key.pem outside a kernel tree
  mkdir -p "${TMPD}/pem"; cp -r "${FIX}/." "${TMPD}/pem/"; printf 'tmpfs /tmp tmpfs defaults 0 0\n' > "${TMPD}/pem/etc/fstab"
  mkdir -p "${TMPD}/pem/root"; echo k > "${TMPD}/pem/root/signing_key.pem"
  mksquashfs "${TMPD}/pem" "${TMPD}/pem.sqfs" -quiet -noappend -comp gzip -wildcards -e 'proc/*' 'sys/*' 'dev/*' 'dev/.*' 'run/*' usr/src >/dev/null 2>&1
  bash "${TMPD}/run-gate" "${TMPD}/pem.sqfs" >/dev/null 2>&1 && bad "gate PASSED a live root carrying /root/signing_key.pem (outside any certs/ dir)" || ok "gate refuses a signing_key.pem anywhere in the live root"
  # (g) a kernel certs/ dir WITHOUT the default key name (a renamed CONFIG_MODULE_SIG_KEY)
  mkdir -p "${TMPD}/certs"; cp -r "${FIX}/." "${TMPD}/certs/"; printf 'tmpfs /tmp tmpfs defaults 0 0\n' > "${TMPD}/certs/etc/fstab"
  rm -f "${TMPD}/certs/usr/src/linux-6.0-gentoo/certs/signing_key.pem"; echo x > "${TMPD}/certs/usr/src/linux-6.0-gentoo/certs/signing_key.x509"
  mksquashfs "${TMPD}/certs" "${TMPD}/certs.sqfs" -quiet -noappend -comp gzip -wildcards -e 'proc/*' 'sys/*' 'dev/*' 'dev/.*' 'run/*' >/dev/null 2>&1
  bash "${TMPD}/run-gate" "${TMPD}/certs.sqfs" >/dev/null 2>&1 && bad "gate PASSED a live root carrying usr/src/linux-*/certs/ (no .pem name)" || ok "gate refuses a kernel certs/ dir even without signing_key.pem"
  # (h) an image the gate cannot LIST is refused, not waved through. The stub lets the
  # top-level (-max-depth) and fstab (-cat) reads through and fails the full listing.
  {
    echo 'err(){ echo "ERROR: $*" >&2; }; info(){ echo "INFO: $*"; }; warn(){ echo "WARN: $*"; }'
    echo "DEFAULT_USER=snap"
    cat "${TMPD}/helpers.sh"
    echo 'unsquashfs(){ case " $* " in *" -max-depth "*|*" -cat "*) command unsquashfs "$@" ;; *) return 1 ;; esac; }'
    echo 'live_root_gate "$1"'
  } > "${TMPD}/run-gate-blind"
  mksquashfs "${TMPD}/pem" "${TMPD}/ok2.sqfs" -quiet -noappend -comp gzip -wildcards -e 'proc/*' 'sys/*' 'dev/*' 'dev/.*' 'run/*' usr/src root >/dev/null 2>&1
  if out="$(bash "${TMPD}/run-gate-blind" "${TMPD}/ok2.sqfs" 2>&1)"; then
    bad "gate PASSED a live root it could not list (the key check never looked)"
  else
    case "${out}" in *"cannot list"*) ok "gate refuses a live root it cannot list, and says so" ;; *) bad "unlistable root refused with the wrong message (the stub broke an earlier read?): ${out}" ;; esac
  fi
  # (d) a correct pack passes
  mkdir -p "${TMPD}/good"; cp -r "${FIX}/." "${TMPD}/good/"; printf 'tmpfs /tmp tmpfs defaults 0 0\n' > "${TMPD}/good/etc/fstab"
  mksquashfs "${TMPD}/good" "${TMPD}/good.sqfs" -quiet -noappend -comp gzip -wildcards -e 'proc/*' 'sys/*' 'dev/*' 'dev/.*' 'run/*' usr/src >/dev/null 2>&1
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
    grep -E '^\./usr/src(/|$)' <<<"${lst}" >/dev/null && bad "tar stream carries usr/src (the module-signing key)" || ok "tar stream excludes usr/src"
    [ -n "${BUNDLE_REL}" ] && grep -qx "./${BUNDLE_REL}/build-x86-host-stage4.sh" <<<"${lst}" \
      && ok "tar stream carries the --bundle-source tree" || bad "tar stream LACKS the --bundle-source tree (/${BUNDLE_REL:-?})"
    tar -xOf "${TMPD}/stream.tar" ./etc/fstab 2>/dev/null | grep -E '^[[:space:]]*PARTUUID=' >/dev/null && bad "tar stream's /etc/fstab is the installed image's" || ok "tar stream's /etc/fstab is the live one"
    cmp -s "${FIX}/etc/fstab" "${SPEC_FSTAB}" && ok "sysroot fstab restored after the tar stream" || bad "sysroot fstab NOT restored after the tar stream"
  else
    bad "the extracted tar statement failed: ${out}"
  fi
fi

# ── stage4 tar (the .img, fs.tar and installer are built from it), EXECUTED ──
echo "-- 8) stage4 tar statement, EXECUTED up to the tar stream --"
mkfake "${FIX}"
awk '/^tar -C "\$\{SYSROOT\}" --xattrs/{f=1} f{print} f&&/-cpf - \. \\$/{exit}' "${BUILDER}" \
  | sed 's/-cpf - \. \\$/-cpf - . > "${STREAM}"/' > "${TMPD}/stage4-line"
if ! grep -q -- "--exclude='./usr/src'" "${TMPD}/stage4-line"; then
  bad "could not extract the stage4 tar statement (or it lost --exclude='./usr/src')"
else
  {
    echo "DEFAULT_USER=snap; SYSROOT='${FIX}'; STREAM='${TMPD}/stage4.tar'"
    cat "${TMPD}/stage4-line"
  } > "${TMPD}/run-stage4"
  if out="$(bash "${TMPD}/run-stage4" 2>&1)" && [ -s "${TMPD}/stage4.tar" ]; then
    lst="$(tar -tf "${TMPD}/stage4.tar")"
    grep -E '^\./usr/src(/|$)' <<<"${lst}" >/dev/null && bad "stage4 carries usr/src (the module-signing key)" || ok "stage4 excludes usr/src"
    [ -n "${BUNDLE_REL}" ] && grep -qx "./${BUNDLE_REL}/build-x86-host-stage4.sh" <<<"${lst}" && grep -qx "./usr/sbin/hugmesh-regenerate" <<<"${lst}" \
      && ok "stage4 (and so the .img, fs.tar and installer) carries the --bundle-source tree and hugmesh-regenerate" \
      || bad "stage4 LACKS the --bundle-source tree (/${BUNDLE_REL:-?}) or hugmesh-regenerate — the installed desktop cannot regenerate"
  else
    bad "the extracted stage4 tar statement failed: ${out}"
  fi
fi

# ── live_root_gate's rdsquashfs arm (squashfs-tools-ng hosts), EXECUTED ──────
# rdsquashfs -d prints `file usr/src/…` — NO leading slash — so a regex written for
# unsquashfs's `/usr/src/…` silently misses there. Run the gate with unsquashfs
# hidden from PATH so it takes that arm for real.
echo "-- 9) live_root_gate, rdsquashfs arm, EXECUTED --"
if ! command -v rdsquashfs >/dev/null || { ! command -v mksquashfs >/dev/null && ! command -v tar2sqfs >/dev/null; }; then
  if [ "${CI:-}" = true ]; then
    bad "rdsquashfs (squashfs-tools-ng) missing under CI — install it in the suite job (the gate's rdsquashfs arm did NOT run)"
  else
    note "rdsquashfs (+ mksquashfs or tar2sqfs) not on this host — skipping the rdsquashfs-arm gate cases"
  fi
else
  mksq() { # $1 = dir, $2 = out — whichever packer this host has; excludes are applied by the caller
    if command -v mksquashfs >/dev/null; then mksquashfs "$1" "$2" -quiet -noappend -comp gzip >/dev/null 2>&1
    else (cd "$1" && tar -cf - .) | tar2sqfs -q -f "$2" >/dev/null 2>&1; fi
  }
  RBIN="${TMPD}/rbin"; mkdir -p "${RBIN}"
  for t in rdsquashfs grep sed head awk cat tr; do ln -sf "$(command -v "${t}")" "${RBIN}/${t}"; done
  {
    echo 'err(){ echo "ERROR: $*" >&2; }; info(){ echo "INFO: $*"; }; warn(){ echo "WARN: $*"; }'
    echo "DEFAULT_USER=snap"
    cat "${TMPD}/helpers.sh"
    echo '[ "${BLIND:-}" = 1 ] && rdsquashfs(){ [ "$1" = -d ] && return 1; command rdsquashfs "$@"; }'
    echo 'command -v unsquashfs >/dev/null && { echo "unsquashfs still on PATH — not the rdsquashfs arm"; exit 3; }'
    echo 'live_root_gate "$1"'
  } > "${TMPD}/run-rgate"
  rgate() { env -i PATH="${RBIN}" BLIND="${2:-}" "${BASH}" "${TMPD}/run-rgate" "$1" 2>&1; }
  mkr() { # $1 = name — a live-shaped tree (mount points empty, live fstab, no usr/src)
    local d="${TMPD}/r-$1"; rm -rf "${d}"; mkdir -p "${d}/proc" "${d}/sys" "${d}/dev" "${d}/run" "${d}/etc" "${d}/usr/sbin"
    printf 'tmpfs /tmp tmpfs defaults 0 0\n' > "${d}/etc/fstab"; echo r > "${d}/usr/sbin/r"; echo "${d}"
  }
  d="$(mkr good)"; mksq "${d}" "${TMPD}/r-good.sqfs"
  out="$(rgate "${TMPD}/r-good.sqfs")" && ok "rdsquashfs arm passes a correct live root" || bad "rdsquashfs arm FAILS a correct live root: ${out}"
  out="$(rgate "${TMPD}/r-good.sqfs" 1)" && bad "rdsquashfs arm PASSED a live root it could not list" \
    || { case "${out}" in *"cannot list"*) ok "rdsquashfs arm refuses a live root it cannot list" ;; *) bad "rdsquashfs arm: unlistable root refused with the wrong message: ${out}" ;; esac; }
  d="$(mkr pem)"; mkdir -p "${d}/usr/src/linux-6.0-gentoo/certs"; echo k > "${d}/usr/src/linux-6.0-gentoo/certs/signing_key.pem"; mksq "${d}" "${TMPD}/r-pem.sqfs"
  out="$(rgate "${TMPD}/r-pem.sqfs")" && bad "rdsquashfs arm PASSED a live root carrying certs/signing_key.pem" \
    || { case "${out}" in *"module-signing PRIVATE key"*) ok "rdsquashfs arm refuses certs/signing_key.pem and names it" ;; *) bad "rdsquashfs arm: key leak refused with the wrong message: ${out}" ;; esac; }
  d="$(mkr stray)"; mkdir -p "${d}/root"; echo k > "${d}/root/signing_key.pem"; mksq "${d}" "${TMPD}/r-stray.sqfs"
  out="$(rgate "${TMPD}/r-stray.sqfs")" && bad "rdsquashfs arm PASSED a live root carrying /root/signing_key.pem (outside any certs/ dir)" \
    || ok "rdsquashfs arm refuses a signing_key.pem anywhere in the live root"
  d="$(mkr certs)"; mkdir -p "${d}/usr/src/linux-6.0-gentoo/certs"; echo x > "${d}/usr/src/linux-6.0-gentoo/certs/signing_key.x509"; mksq "${d}" "${TMPD}/r-certs.sqfs"
  out="$(rgate "${TMPD}/r-certs.sqfs")" && bad "rdsquashfs arm PASSED a live root carrying usr/src/linux-*/certs/ (its listing has no leading slash)" \
    || { case "${out}" in *"module-signing PRIVATE key"*) ok "rdsquashfs arm refuses a kernel certs/ dir without signing_key.pem" ;; *) bad "rdsquashfs arm: certs dir refused with the wrong message: ${out}" ;; esac; }
fi

echo
echo "x86 live-root pack guards: ${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
