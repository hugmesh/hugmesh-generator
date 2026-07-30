#!/usr/bin/env bash
# test-x86-artifact-integrity.sh — guards the four 2026-07 x86 artifact-integrity
# fixes in build-x86-host-stage4.sh. Each one shipped BROKEN artifacts with
# exit 0; each fix below is asserted by EXECUTING the extracted block, not just
# grepping for it (a guard of mine once PASSED on the very spec it was written
# to catch — a regex matched a whole line instead of its fields):
#
#   1. DISK-INITRAMFS GATE — dracut's disk-initramfs step is warn-only and
#      build_img's grub.cfg writer silently omits the `initrd` line when the
#      file is missing, sealing an unbootable .img (no rd.luks/dm_crypt/usb).
#   2. SHIM POST-PROCESSING — extracted the UPPERCASE /EFI/BOOT/BOOTX64.EFI that
#      grub-mkrescue writes LOWERCASE, error eaten by `2>/dev/null || true`:
#      4 of 4 live ISOs shipped with no Secure Boot shim (sessions
#      20260724-013844-53b498, 20260725-061608-978c99, 2x 20260719-103006-a775c2).
#   3. PORTAGE SELF-UPGRADE + FAILURE NOTICES — portage upgraded itself mid-
#      @world; the next merge died "ModuleNotFoundError: No module named
#      'portage.util.env_update'" reported as ">>> Failed to install" — a shape
#      nothing matched — and --keep-going dropped 17 core packages (+3 more
#      merge-phase '>>> Failed to install' deaths) that SHIPPED
#      (out/sessions/20260725-061608-978c99/build.log:386963,388420+).
#   4. CONCURRENT-BUILD EXCLUSION — two same-role builds bind-mounted ONE host
#      scratch onto both chroots' /var/tmp/portage with no lock; session
#      20260725-140638-09692d died mid-compile of inkscape under the other
#      build's per-package clean.
#
# Pure extract + execute checks. No emerge, no chroot, no network, no root.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BUILDER="${REPO}/build-x86-host-stage4.sh"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
note(){ echo "  NOTE $*"; }

TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"; rm -f /tmp/hugmesh-emerge-failures.log /tmp/hugmesh-emerge-failures.uniq /tmp/hugmesh-emerge-still-broken.txt' EXIT

echo "== x86 artifact-integrity gates =="

# ─────────────────────────────────────────────────────────────────────────────
echo "-- 1) disk-initramfs gate (host side), EXECUTED --"
# Extract the whole col-0 `if ${BUILD_IMG} || ${INSTALLER_ISO}` block that
# follows the gate banner (inner ifs are indented, so the first col-0 `fi`
# closes it).
awk '/^# ── DISK-INITRAMFS GATE/{f=1} f&&/^if \$\{BUILD_IMG\}/{s=1} s{print} s&&/^fi$/{exit}' \
    "${BUILDER}" > "${TMPD}/gate-initramfs"
if [ ! -s "${TMPD}/gate-initramfs" ]; then
  bad "could not extract the DISK-INITRAMFS GATE block from the builder"
else
  ok "extracted the host-side gate ($(wc -l < "${TMPD}/gate-initramfs") lines)"
  {
    echo 'err(){ echo "ERROR: $*" >&2; }'
    echo 'info(){ echo "INFO: $*"; }'
    echo 'BUILD_IMG=$1; INSTALLER_ISO=$2; SYSROOT=$3'
    cat "${TMPD}/gate-initramfs"
  } > "${TMPD}/run-gate-initramfs"
  FIX="${TMPD}/sysroot"
  mkdir -p "${FIX}/lib/modules/6.18.9-hardened1" "${FIX}/boot"
  touch "${FIX}/boot/vmlinuz-6.18.9-hardened1"
  # (a) kernel present, NO initramfs, .img requested → must FAIL
  if out="$(bash "${TMPD}/run-gate-initramfs" true false "${FIX}" 2>&1)"; then
    bad ".img build with NO disk initramfs passed the gate: ${out}"
  else
    case "${out}" in
      *"initramfs missing or EMPTY"*) ok "missing initramfs FAILS an .img build (named in the error)" ;;
      *) bad "missing initramfs failed, but with the wrong message: ${out}" ;;
    esac
  fi
  # (b) EMPTY (0-byte) initramfs is the same defect — dracut died after creat()
  touch "${FIX}/boot/initramfs-6.18.9-hardened1.img"
  bash "${TMPD}/run-gate-initramfs" true false "${FIX}" >/dev/null 2>&1 \
    && bad "an EMPTY initramfs passed the gate" \
    || ok "an empty (0-byte) initramfs FAILS an .img build"
  # (c) non-empty initramfs → pass
  printf 'not-really-a-cpio-but-non-empty' > "${FIX}/boot/initramfs-6.18.9-hardened1.img"
  if out="$(bash "${TMPD}/run-gate-initramfs" true false "${FIX}" 2>&1)"; then
    case "${out}" in
      *"Disk-initramfs gate"*) ok "healthy initramfs passes, and SAYS so in the log" ;;
      *) bad "healthy initramfs passed silently (no explicit gate line): ${out}" ;;
    esac
  else
    bad "gate FAILS a healthy sysroot: ${out}"
  fi
  # (d) STALE initramfs: newer kernel in /lib/modules, only the old initramfs on
  # disk. A bare "any initramfs-*.img exists" probe would pass this and the .img
  # still would not boot (module tree mismatch) — the gate pins <kver>.
  mkdir -p "${FIX}/lib/modules/6.19.2-hardened1"
  bash "${TMPD}/run-gate-initramfs" true false "${FIX}" >/dev/null 2>&1 \
    && bad "a STALE initramfs (older than the newest kernel) passed the gate" \
    || ok "a stale initramfs for a superseded kernel FAILS the gate (kver is pinned)"
  # (e) tar/live-only build (no .img, no installer ISO): dracut stays warn-only
  rm -f "${FIX}/boot/initramfs-"*.img
  bash "${TMPD}/run-gate-initramfs" false false "${FIX}" >/dev/null 2>&1 \
    && ok "no disk artifact requested → no gate (ISO/tar-only builds not hostage)" \
    || bad "gate fired for a build with no disk-boot artifact"
fi

echo "-- 1b) build_img seal gate, EXECUTED --"
# The last line of defense: inside build_img, right after initrd discovery.
awk '/# The initrd is LOAD-BEARING/{f=1} f{print} f&&/^    fi$/{exit}' \
    "${BUILDER}" > "${TMPD}/gate-seal"
if [ ! -s "${TMPD}/gate-seal" ]; then
  bad "could not extract the build_img seal gate"
else
  {
    echo 'err(){ echo "ERROR: $*" >&2; }'
    echo 'initrd=$1; root_mnt=$2'
    cat "${TMPD}/gate-seal"
    echo 'echo SEALED'
  } > "${TMPD}/run-gate-seal"
  MNT="${TMPD}/root_mnt"; mkdir -p "${MNT}/boot"
  # (a) no initrd found at all (the 978c99 shape: grub.cfg would omit the line)
  out="$(bash "${TMPD}/run-gate-seal" "" "${MNT}" 2>&1)" \
    && bad "build_img sealed with NO initrd: ${out}" \
    || ok "build_img refuses to seal with no initrd on the image /boot"
  # (b) initrd name found but the file is empty
  touch "${MNT}/boot/initramfs-6.18.9-hardened1.img"
  bash "${TMPD}/run-gate-seal" initramfs-6.18.9-hardened1.img "${MNT}" >/dev/null 2>&1 \
    && bad "build_img sealed over an EMPTY initrd" \
    || ok "build_img refuses an empty initrd file"
  # (c) healthy → seals
  printf 'x' > "${MNT}/boot/initramfs-6.18.9-hardened1.img"
  out="$(bash "${TMPD}/run-gate-seal" initramfs-6.18.9-hardened1.img "${MNT}" 2>&1)" \
    && ok "healthy initrd seals normally" \
    || bad "seal gate rejects a healthy initrd: ${out}"
fi
# Ordering: the seal gate must sit between initrd discovery and grub-mkimage,
# and the host gate between the kernel phase and Secure Boot signing.
seal_ln=$(grep -n 'refusing to seal an .img' "${BUILDER}" | head -1 | cut -d: -f1)
mkimg_ln=$(grep -n 'Building GRUB-EFI core image' "${BUILDER}" | head -1 | cut -d: -f1)
gate_ln=$(grep -n '^# ── DISK-INITRAMFS GATE' "${BUILDER}" | head -1 | cut -d: -f1)
dracut_ln=$(grep -n 'WARN: dracut (disk initramfs) failed' "${BUILDER}" | head -1 | cut -d: -f1)
sb_ln=$(grep -n '^# ── Secure Boot: org signing-key generation' "${BUILDER}" | head -1 | cut -d: -f1)
if [ -n "${seal_ln}" ] && [ -n "${mkimg_ln}" ] && [ "${seal_ln}" -lt "${mkimg_ln}" ]; then
  ok "seal gate (${seal_ln}) runs before grub-mkimage (${mkimg_ln})"
else
  bad "seal gate mis-ordered (seal=${seal_ln:-missing} mkimage=${mkimg_ln:-missing})"
fi
if [ -n "${gate_ln}" ] && [ -n "${dracut_ln}" ] && [ -n "${sb_ln}" ] \
   && [ "${gate_ln}" -gt "${dracut_ln}" ] && [ "${gate_ln}" -lt "${sb_ln}" ]; then
  ok "host gate (${gate_ln}) sits between the dracut step (${dracut_ln}) and Secure Boot (${sb_ln})"
else
  bad "host gate mis-ordered (gate=${gate_ln:-missing} dracut=${dracut_ln:-missing} sb=${sb_ln:-missing})"
fi
# The hazard the gates guard: the grub.cfg writer's conditional initrd line. If
# this ever becomes unconditional the gates are belt over suspenders — fine, but
# say so rather than fail.
grep -q '\[ -n "${initrd}" \] && echo "    initrd /boot/${initrd}"' "${BUILDER}" \
  && ok "grub.cfg writer still omits initrd conditionally (the guarded hazard is live)" \
  || note "grub.cfg writer no longer conditionally omits initrd — gates may be redundant now"

# ─────────────────────────────────────────────────────────────────────────────
echo "-- 2) live-ISO shim post-processing --"
# The probe transform, EXECUTED against canned `xorriso -find` output (paths
# quoted, lowercase — exactly what xorriso 1.5.8 prints for a grub-mkrescue
# tree; verified against the real 53b498 ISO).
awk '/_grub_in_iso="\$\(xorriso -indev/{f=1} f{print} f&&/head -1 \|\| true\)"/{exit}' \
    "${BUILDER}" > "${TMPD}/probe"
if [ ! -s "${TMPD}/probe" ]; then
  bad "could not extract the case-insensitive GRUB-EFI probe"
else
  mkdir -p "${TMPD}/bin"
  cat > "${TMPD}/bin/xorriso" <<'STUB'
#!/bin/sh
# canned `xorriso -indev X -find / -type f` output, shape-verified on the real
# 20260724-013844-53b498 live ISO (quoted, lowercase Rock Ridge tree)
cat <<'EOF'
'/boot.catalog'
'/boot/grub/grub.cfg'
'/efi.img'
'/efi/boot/bootx64.efi'
'/live/squashfs.img'
EOF
STUB
  chmod +x "${TMPD}/bin/xorriso"
  got="$(PATH="${TMPD}/bin:${PATH}" ISO_PATH=/dev/null bash -c ". '${TMPD}/probe'; printf %s \"\${_grub_in_iso}\"")"
  if [ "${got}" = "/efi/boot/bootx64.efi" ]; then
    ok "probe finds the LOWERCASE tree path grub-mkrescue actually writes"
  else
    bad "probe returned '${got}' for a lowercase tree (the 4/4-broken-ISOs bug is back)"
  fi
  # An ISO with no tree-level EFI file → probe must come back empty so the
  # El Torito /efi.img fallback branch is taken (not a false hit).
  cat > "${TMPD}/bin/xorriso" <<'STUB'
#!/bin/sh
cat <<'EOF'
'/boot.catalog'
'/efi.img'
EOF
STUB
  got="$(PATH="${TMPD}/bin:${PATH}" ISO_PATH=/dev/null bash -c ". '${TMPD}/probe'; printf %s \"\${_grub_in_iso}\"")"
  [ -z "${got}" ] \
    && ok "no tree-level match → empty probe → El Torito fallback branch is reachable" \
    || bad "probe false-positived on '${got}'"
fi
# Static posture of the block (bounded to the shim section only). Two
# normalizations, each one a mutation-proven necessity:
#   - COMMENTS OUT: the block's own rationale comment quotes '-boot_image any
#     replay' and '-hfsplus off' verbatim, so a bare grep still matched after
#     the ARGS were deleted from the code (the check passed on the broken
#     builder — caught by mutation M2d, 2026-07-29).
#   - CONTINUATIONS JOINED: every xorriso call is backslash-wrapped, so a
#     single-line 'xorriso .*-extract' grep can never see a '2>/dev/null'
#     sitting on the continuation line (the swallow check passed with the
#     swallow re-added — caught by mutation M2b, 2026-07-29).
sed -n '/Shim post-processing for Secure Boot live boot/,/Shim not found on build host/p' \
    "${BUILDER}" > "${TMPD}/shimblk"
[ -s "${TMPD}/shimblk" ] || bad "could not bound the shim post-processing block"
grep -v '^[[:space:]]*#' "${TMPD}/shimblk" \
  | sed ':a;/\\$/{N;s/\\\n/ /;ba}' > "${TMPD}/shimblk-code"
[ -s "${TMPD}/shimblk-code" ] || bad "comment-strip/continuation-join produced an empty shim block"
grep -q -- '-extract EFI/BOOT/BOOTX64.EFI' "${TMPD}/shimblk-code" \
  && bad "the UPPERCASE extract is back — grub-mkrescue writes lowercase; this can never succeed" \
  || ok "the impossible uppercase -extract is gone"
if grep -E 'xorriso .*-extract' "${TMPD}/shimblk-code" | grep -qE '2>/dev/null|\|\| true'; then
  bad "an xorriso extract still swallows its error (2>/dev/null / || true) — that hid the bug for 4 ISOs"
else
  ok "xorriso extract failures now reach the log (checked on joined continuations)"
fi
# Anchor BOTH arg checks on the _xr_args ASSIGNMENT itself: the failure
# message string `_shim_fail "xorriso rewrite (-boot_image any replay)
# failed"` is code too, so even the comment-stripped grep matched with the
# args deleted (mutation M2d passed a second time before this anchor).
grep -q -- '_xr_args=( -boot_image any replay' "${TMPD}/shimblk-code" \
  && ok "rewrite replays the El Torito/MBR/GPT boot equipment (checked on the _xr_args assignment)" \
  || bad "rewrite lost '-boot_image any replay' — xorriso would DISCARD the boot equipment"
grep -qE -- '_xr_args=\(.* -hfsplus off' "${TMPD}/shimblk-code" \
  && ok "-hfsplus off present (replay otherwise dies: GPT partitions 1 and 2 overlap by 80 blocks)" \
  || bad "-hfsplus off missing — replay fails on grub-mkrescue's Mac APM layout"
grep -q 'cmp -s "${_shim_src}" "${_iso_tmp}/verify-bootx64.efi"' "${TMPD}/shimblk" \
  && ok "postcondition: the rewritten El Torito FAT is verified to carry the byte-identical shim" \
  || bad "no byte-level postcondition on the rewritten /efi.img"
awk '/_shim_fail\(\) \{/{f=1} f&&/exit 1/{found=1} f&&/^            \}/{exit} END{exit(found?0:1)}' "${TMPD}/shimblk" \
  && ok "_shim_fail FAILS the build (a shim-capable host must not ship a shimless live ISO silently)" \
  || bad "_shim_fail does not exit 1 — failure would be warn-only again"
grep -q 'command -v mkfs.vfat' "${TMPD}/shimblk" && grep -q 'command -v mcopy' "${TMPD}/shimblk" \
  && ok "tool preflight covers the FAT-rebuild path (mkfs.vfat + mtools)" \
  || bad "tool preflight does not cover mkfs.vfat/mtools — the rebuild would fail mid-way"

# ─────────────────────────────────────────────────────────────────────────────
echo "-- 3) portage self-upgrade isolation + failure-notice capture --"
# Match the oneshot portage merge by its INVARIANT PARTS (emerge ... --oneshot
# ... sys-apps/portage), not by an exact flag string. The invariant this section
# protects is the ORDERING — portage upgrades alone, before @world — and pinning
# the literal flag list made the check fail the moment a legitimate flag was
# added (`--newuse`, so the seed's portage actually rebuilds when the derived
# PYTHON_TARGETS change; see docs/PYTHON-TARGETS-SEED-DRIFT.md). A brittle match
# that breaks on a correct change teaches people to edit the test, which is how
# a real gate gets hollowed out.
oneshot_ln=$(grep -nE -- '^[[:space:]]*emerge .*--oneshot .*sys-apps/portage' "${BUILDER}" | head -1 | cut -d: -f1)
world_ln=$(grep -n -- '--keep-going --exclude sys-apps/portage ${EMERGE_EXCLUDE} @world' "${BUILDER}" | head -1 | cut -d: -f1)
if [ -n "${oneshot_ln}" ] && [ -n "${world_ln}" ] && [ "${oneshot_ln}" -lt "${world_ln}" ]; then
  ok "portage merges ALONE (${oneshot_ln}) before the @world pass (${world_ln})"
else
  bad "portage-first ordering broken (oneshot=${oneshot_ln:-missing} @world=${world_ln:-missing})"
fi
n_excl=$(grep -c -- '--keep-going.*--exclude sys-apps/portage' "${BUILDER}" || true)
if [ "${n_excl}" -ge 2 ]; then
  ok "both long --keep-going passes exclude sys-apps/portage (${n_excl} sites)"
else
  bad "only ${n_excl} --keep-going pass(es) exclude portage — the mid-run self-replace can recur"
fi
n_sink=$(grep -c '| _emerge_notice_sink' "${BUILDER}" || true)
[ "${n_sink}" -ge 2 ] \
  && ok "both payload emerges stream through the notice sink (${n_sink} sites)" \
  || bad "only ${n_sink} emerge(s) feed the notice sink — failures there go unwatched"

# Render the chroot payload heredoc exactly as the builder does (same technique
# as tests/build-package-completeness.sh) and EXECUTE the pieces.
START=$(grep -n 'chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT' "${BUILDER}" | head -1 | cut -d: -f1)
END=$(awk -v s="${START}" 'NR>s && /^CHROOT$/ {print NR; exit}' "${BUILDER}")
render_payload() { # $1 = ALLOW_MISSING_PACKAGES value, $2 = output file
  sed -n "$((START+1)),$((END-1))p" "${BUILDER}" > "${TMPD}/body"
  (
    EMERGE_JOBS=1 JOBS=8 GO_PROCS=2 EMERGE_EXCLUDE="--exclude sys-devel/gcc" \
    PKGS="app-office/libreoffice sys-apps/portage" SNAP_ROLE_BINS="Xorg" \
    ALLOW_MISSING_PACKAGES="$1" STEAM_OVERLAY_SETUP="" SYSROOT=/nonexistent \
    DISTDIR_SRC="" REL_VERSION="test" ROLE="desktop" \
    bash -c 'eval "cat <<CHROOT
$(cat "$1")
CHROOT"' _ "${TMPD}/body" > "$2"
  ) 2>/dev/null
  [ -s "$2" ]
}
if [ -z "${START}" ] || [ -z "${END}" ] || ! render_payload false "${TMPD}/render"; then
  bad "could not render the chroot payload heredoc"
else
  ok "payload heredoc rendered"
  bash -n "${TMPD}/render" 2>"${TMPD}/render-err" \
    && ok "rendered payload (sink + failure gate included) is VALID bash" \
    || bad "rendered payload is INVALID bash: $(head -2 "${TMPD}/render-err" | tr '\n' ' ')"
  # NO unescaped backticks/dollar-parens ANYWHERE in the heredoc body, comments
  # included: in an unquoted heredoc they EXECUTE on the HOST at render time. A
  # backticked tee example in a comment here really did run and read stdin —
  # hanging an interactive build at the payload phase (caught only because this
  # test's own render hung). bash -n on the RENDER cannot see this: by then the
  # substitution has already run and its output looks like ordinary text.
  if sed -n "$((START+1)),$((END-1))p" "${BUILDER}" | grep -nE '(^|[^\\])`' | head -3 | grep .; then
    bad "UNESCAPED backtick(s) inside the payload heredoc (lines above, relative) — they run on the HOST during render"
  else
    ok "no unescaped backticks in the payload heredoc (host-render execution hazard)"
  fi
  if sed -n "$((START+1)),$((END-1))p" "${BUILDER}" | grep -nE '(^|[^\\$])\$\(' | head -3 | grep .; then
    bad "UNESCAPED \$( inside the payload heredoc (lines above, relative) — it runs on the HOST during render"
  else
    ok "no unescaped dollar-parens in the payload heredoc"
  fi

  # 3a) the sink, EXECUTED against VERBATIM lines from the real logs. The drop
  # notice WRAPS mid-phrase in the real output, so only the ' * emerge
  # --keep-going: ' first-line prefix is a safe anchor — feed the wrapped
  # continuation as noise that must NOT be captured.
  awk '/^_emerge_notice_sink\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' \
      "${TMPD}/render" > "${TMPD}/sinkdef"
  if [ ! -s "${TMPD}/sinkdef" ]; then
    bad "could not extract _emerge_notice_sink from the rendered payload"
  else
    cat > "${TMPD}/fixture" <<'FIXTURE'
>>> Emerging (239 of 258) sys-apps/groff-1.23.0-r2::gentoo
>>> Completed (239 of 258) sys-apps/groff-1.23.0-r2::gentoo
>>> Failed to install sys-apps/groff-1.23.0-r2, Log file:
>>> Failed to emerge app-office/libreoffice-25.2.7.2-r1, Log file:
 * emerge --keep-going: sys-apps/dbus-1.16.2 dropped because it requires sys-
 * because it requires x11-libs/gtk+:3
 * Messages for package sys-apps/groff-1.23.0-r2:
FIXTURE
    : > /tmp/hugmesh-emerge-failures.log
    passthru="$(bash -c ". '${TMPD}/sinkdef'; _emerge_notice_sink < '${TMPD}/fixture'")"
    cap_n=$(grep -c . /tmp/hugmesh-emerge-failures.log || true)
    [ "${cap_n}" = "3" ] \
      && ok "sink captured exactly the 3 real notice shapes (install/emerge/keep-going)" \
      || { bad "sink captured ${cap_n} lines, wanted 3:"; sed 's/^/       | /' /tmp/hugmesh-emerge-failures.log; }
    grep -q 'Failed to install sys-apps/groff' /tmp/hugmesh-emerge-failures.log \
      && ok "'>>> Failed to install' (the ModuleNotFoundError shape) is now seen" \
      || bad "the merge-phase '>>> Failed to install' shape is STILL invisible"
    grep -q 'keep-going: sys-apps/dbus' /tmp/hugmesh-emerge-failures.log \
      && ok "the --keep-going drop cascade is now seen" \
      || bad "the 'dropped because it requires' cascade is STILL invisible"
    grep -q 'because it requires x11-libs' /tmp/hugmesh-emerge-failures.log \
      && bad "sink captured a WRAPPED continuation line — it will never parse to a cpv" \
      || ok "wrapped continuation lines are not captured (first-line prefix anchor)"
    [ "$(printf '%s\n' "${passthru}" | grep -c .)" = "7" ] \
      && ok "sink still streams every line to the build log (nothing swallowed)" \
      || bad "sink ATE build output — operators would lose emerge visibility"
  fi

  # 3b) the failure-notice gate python, EXECUTED with a stub portage vardb.
  if command -v python3 >/dev/null 2>&1; then
    mkdir -p "${TMPD}/pystub"
    cat > "${TMPD}/pystub/portage.py" <<'PYSTUB'
import os
class _Vardb(object):
    def match(self, atom):
        if atom.startswith("=bad/"):
            raise ValueError("malformed: %s" % atom)
        inst = (os.environ.get("FAKE_INSTALLED_CPVS") or "").split()
        return ["hit"] if atom.lstrip("=") in inst else []
class _Vartree(object):
    dbapi = _Vardb()
settings = {"EROOT": "/"}
db = {"/": {"vartree": _Vartree()}}
PYSTUB
    # Anchor on the gate's own col-0 banner, NOT a prose mention of its name
    # (the sink comment cites it EARLIER in the payload — anchoring there
    # captured the completeness gate's python instead, and case (a) below then
    # "passed" on a crashed interpreter writing 0 bytes; hence the rc checks).
    awk '/^# ── EMERGE FAILURE-NOTICE GATE/{g=1} g&&/python3 - <</{s=1;next} s&&/^PYEOF$/{exit} s{print}' \
        "${TMPD}/render" > "${TMPD}/gatepy"
    if [ ! -s "${TMPD}/gatepy" ] || ! grep -q 'pat_drop' "${TMPD}/gatepy"; then
      bad "could not extract the failure-notice gate python (got: $(head -1 "${TMPD}/gatepy" 2>/dev/null))"
    else
      printf '%s\n' \
        '>>> Failed to install sys-apps/groff-1.23.0-r2, Log file:' \
        ' * emerge --keep-going: sys-apps/dbus-1.16.2 dropped because it requires sys-' \
        > /tmp/hugmesh-emerge-failures.uniq
      # (a) both healed by a later pass → output must be EXACTLY 0 bytes (the
      # 1-byte bare-newline shape is the false positive that once failed every
      # clean build of the requested-atom gate — see #465).
      out_f="${TMPD}/py-out"
      if FAKE_INSTALLED_CPVS="sys-apps/groff-1.23.0-r2 sys-apps/dbus-1.16.2" \
        PYTHONPATH="${TMPD}/pystub" python3 "${TMPD}/gatepy" > "${out_f}" \
        && [ "$(wc -c < "${out_f}")" = "0" ]; then
        ok "all-healed notices emit 0 bytes (no bare-newline false positive)"
      else
        bad "healed notices: python rc=$? / $(wc -c < "${out_f}") byte(s) — the shell side will miscount"
      fi
      # (b) groff healed only as the OLD version → must STILL be reported (the
      # 978c99 shape: 1.23.0-r2 failed to install, stale files left behind).
      FAKE_INSTALLED_CPVS="sys-apps/groff-1.22 sys-apps/dbus-1.16.2" \
        PYTHONPATH="${TMPD}/pystub" python3 "${TMPD}/gatepy" > "${out_f}"
      grep -q 'sys-apps/groff-1.23.0-r2' "${out_f}" \
        && ok "an old version left behind does NOT count as healed (exact-cpv match)" \
        || bad "a stale old version was accepted as healed: $(cat "${out_f}")"
      # (c) unparsable garbage counts as failed (fail closed)
      echo 'some completely unrecognizable notice text' > /tmp/hugmesh-emerge-failures.uniq
      FAKE_INSTALLED_CPVS="" PYTHONPATH="${TMPD}/pystub" python3 "${TMPD}/gatepy" > "${out_f}"
      grep -q 'unparsable notice - counted as failed' "${out_f}" \
        && ok "an unparsable notice fails closed" \
        || bad "an unparsable notice was silently dropped"
      # (d) a cpv vardb cannot parse fails closed too
      echo '>>> Failed to install bad/thing-1.0, Log file:' > /tmp/hugmesh-emerge-failures.uniq
      FAKE_INSTALLED_CPVS="" PYTHONPATH="${TMPD}/pystub" python3 "${TMPD}/gatepy" > "${out_f}"
      grep -q 'unverifiable atom' "${out_f}" \
        && ok "a vardb-unverifiable atom fails closed" \
        || bad "a vardb exception was swallowed"
    fi

    # 3c) the gate's SHELL decision, EXECUTED end-to-end (its embedded python
    # resolves the stub portage through PYTHONPATH).
    awk '/^if \[ -s \/tmp\/hugmesh-emerge-failures\.log \]/{f=1} f{print} f&&/^fi$/{exit}' \
        "${TMPD}/render" > "${TMPD}/decide"
    if [ ! -s "${TMPD}/decide" ]; then
      bad "could not extract the failure-notice decision block"
    else
      export PYTHONPATH="${TMPD}/pystub"
      # (1) no notices at all
      : > /tmp/hugmesh-emerge-failures.log
      out="$(FAKE_INSTALLED_CPVS="" bash "${TMPD}/decide" 2>&1)" \
        && case "${out}" in
             *"failure notices: none"*) ok "no notices → explicit all-clear line" ;;
             *) bad "clean run printed something unexpected: ${out}" ;;
           esac \
        || bad "gate FAILED a build with zero failure notices: ${out}"
      # (2) notices present, all healed by the later pass
      printf '%s\n' \
        '>>> Failed to install sys-apps/groff-1.23.0-r2, Log file:' \
        ' * emerge --keep-going: sys-apps/dbus-1.16.2 dropped because it requires sys-' \
        > /tmp/hugmesh-emerge-failures.log
      out="$(FAKE_INSTALLED_CPVS="sys-apps/groff-1.23.0-r2 sys-apps/dbus-1.16.2" bash "${TMPD}/decide" 2>&1)" \
        && case "${out}" in
             *"verified installed"*) ok "healed notices pass, saying they were verified" ;;
             *) bad "healed notices passed with the wrong message: ${out}" ;;
           esac \
        || bad "gate failed although every noticed package is installed: ${out}"
      # (3) groff still absent → the 978c99 ship-broken scenario must now FAIL
      if out="$(FAKE_INSTALLED_CPVS="sys-apps/dbus-1.16.2" bash "${TMPD}/decide" 2>&1)"; then
        bad "GATE PASSED the 978c99 scenario (failed merge absent from vardb): ${out}"
      else
        case "${out}" in
          *"sys-apps/groff-1.23.0-r2"*) ok "a still-missing failed merge FAILS the build and is NAMED" ;;
          *) bad "gate failed but did not name the package: ${out}" ;;
        esac
      fi
      # (4) --allow-missing-packages renders a warn-and-continue gate
      if render_payload true "${TMPD}/render-allow"; then
        awk '/^if \[ -s \/tmp\/hugmesh-emerge-failures\.log \]/{f=1} f{print} f&&/^fi$/{exit}' \
            "${TMPD}/render-allow" > "${TMPD}/decide-allow"
        out="$(FAKE_INSTALLED_CPVS="sys-apps/dbus-1.16.2" bash "${TMPD}/decide-allow" 2>&1)" \
          && case "${out}" in
               *DEGRADED*) ok "--allow-missing-packages downgrades the gate to a loud warning" ;;
               *) bad "opt-out passed but without the DEGRADED warning: ${out}" ;;
             esac \
          || bad "--allow-missing-packages did not bypass the gate: ${out}"
      else
        bad "could not render the payload with ALLOW_MISSING_PACKAGES=true"
      fi
      unset PYTHONPATH
    fi
  else
    note "python3 not available — failure-notice gate execution SKIPPED (render+sink still checked)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "-- 4) concurrent-build exclusion, EXECUTED --"
awk '/^acquire_build_lock\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' \
    "${BUILDER}" > "${TMPD}/lockdef"
if [ ! -s "${TMPD}/lockdef" ]; then
  bad "could not extract acquire_build_lock from the builder"
elif ! command -v flock >/dev/null 2>&1; then
  note "flock not available here — lock contention execution SKIPPED"
else
  LROOT="${TMPD}/wl-test.x86"
  harness() { # $1 extra script
    echo 'err(){ echo "ERROR: $*" >&2; }'
    echo "BUILD_ROOT='${LROOT}'; BUILD_TS=t; ROLE=test; WORK_DIR='${TMPD}'"
    cat "${TMPD}/lockdef"
    echo "$1"
  }
  # exec, not plain sleep: fd 217 is inherited by children, so killing a parent
  # bash while a plain `sleep` child lives would NOT release the flock (which is
  # the builder's CORRECT behavior — a surviving build child still owns the
  # build — but here the holder must die cleanly on one kill).
  harness 'acquire_build_lock; touch "${BUILD_ROOT}.held"; exec sleep 30' > "${TMPD}/holder"
  harness 'acquire_build_lock' > "${TMPD}/contender"
  bash "${TMPD}/holder" & hpid=$!
  for _ in $(seq 1 50); do [ -f "${LROOT}.held" ] && break; sleep 0.1; done
  if [ ! -f "${LROOT}.held" ]; then
    bad "lock holder never came up — cannot exercise contention"
    kill "${hpid}" 2>/dev/null
  else
    if out="$(bash "${TMPD}/contender" 2>&1)"; then
      bad "a SECOND build of the same role acquired the lock while the first held it"
    else
      case "${out}" in
        *"another build already holds"*) ok "second same-role build fails FAST (the 09692d kill can't recur)" ;;
        *) bad "second build failed but without the exclusion message: ${out}" ;;
      esac
      case "${out}" in
        *"pid="*) ok "the failure NAMES the holding session (pid/role/work_dir)" ;;
        *) bad "holder identity missing from the message: ${out}" ;;
      esac
    fi
    kill "${hpid}" 2>/dev/null; wait "${hpid}" 2>/dev/null
    bash "${TMPD}/contender" >/dev/null 2>&1 \
      && ok "lock releases with the holding process (kernel flock, no stale-lock wedge)" \
      || bad "lock stayed WEDGED after the holder died"
  fi
fi
# Static wiring: the executed function must actually guard the real paths.
grep -q 'exec 217>>"${BUILD_ROOT}.lock"' "${BUILDER}" \
  && ok "build-root lockfile is a SIBLING of the guarded dir (survives its deletion)" \
  || bad "build-root lockfile moved — if it lives INSIDE a cleaned dir, cleanup re-opens the race"
awk '/^mount_chroot\(\) \{/{f=1; n=0} f&&/acquire_build_lock/{found=1} f&&++n>6{exit} END{exit(found?0:1)}' "${BUILDER}" \
  && ok "mount_chroot re-checks the build lock (a --resume run skips the Extract-phase call)" \
  || bad "mount_chroot no longer takes the build lock — a --resume run mounts unguarded"
grep -q 'exec 218>>"${scratch}.lock"' "${BUILDER}" && grep -q 'flock -n 218' "${BUILDER}" \
  && ok "the shared portage scratch has its own non-blocking flock" \
  || bad "the scratch flock is gone — same-subdir builds from two WORK_DIRs collide again"
scr_lock_ln=$(grep -n 'exec 218>>"${scratch}.lock"' "${BUILDER}" | head -1 | cut -d: -f1)
scr_bind_ln=$(grep -n 'mkdir -p "${scratch}" "${SYSROOT}/var/tmp/portage"' "${BUILDER}" | head -1 | cut -d: -f1)
if [ -n "${scr_lock_ln}" ] && [ -n "${scr_bind_ln}" ] && [ "${scr_lock_ln}" -lt "${scr_bind_ln}" ]; then
  ok "scratch lock (${scr_lock_ln}) is taken BEFORE the bind mount (${scr_bind_ln})"
else
  bad "scratch lock ordering broken (lock=${scr_lock_ln:-missing} bind=${scr_bind_ln:-missing})"
fi
mp_ln=$(grep -n 'mountpoint -q "${SYSROOT}/var/tmp/portage"' "${BUILDER}" | head -1 | cut -d: -f1)
wipe_ln=$(grep -n 'rm -rf "${SYSROOT}"/usr/share/{doc,man,info}' "${BUILDER}" | head -1 | cut -d: -f1)
if [ -n "${mp_ln}" ] && [ -n "${wipe_ln}" ] && [ "${mp_ln}" -lt "${wipe_ln}" ]; then
  ok "cleanup verifies the scratch bind is detached (${mp_ln}) before the var/tmp wipe (${wipe_ln})"
else
  bad "cleanup can rm -rf through a still-attached scratch bind (mp=${mp_ln:-missing} wipe=${wipe_ln:-missing})"
fi
grep -q '_stale_mounts="$(findmnt -rn -o TARGET' "${BUILDER}" \
  && ok "fresh-start wipe refuses a sysroot with attached mounts (pipefail-safe capture)" \
  || bad "the fresh-start rm -rf no longer checks for attached mounts"

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
