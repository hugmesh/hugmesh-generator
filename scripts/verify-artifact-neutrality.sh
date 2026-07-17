#!/usr/bin/env bash
# =============================================================================
# verify-artifact-neutrality.sh — brand-neutrality gate for standalone
# UNAFFILIATED build artifacts (the shipped guarantee of generator PR #260).
#
# Verifies, against a build-output directory, that every artifact is neutral:
#   * artifact NAMES     — gentoo-*, never snapdragon-*
#   * live ISO           — volid GENTOO_LIVE, snapdragon-free tree, bare
#                          EFI/BOOT/bootx64.efi boot path (live media boots the
#                          bare grub stub BY DESIGN — no UKI is expected here),
#                          grub.cfg carries the neutral gentoo.install= cmdline
#                          key + CDLABEL GENTOO_LIVE and is snapdragon-free
#   * live squashfs      — no /etc/snapdragon marker tree, /etc/gentoo present,
#                          no snapdragon-* tools, no k8s payload, and the
#                          gentoo-calamares-install bridge present
#                          (listed via unsquashfs in the builder container)
#   * installer ISO      — volid GENTOO_INSTALL, snapdragon-free tree,
#                          gentoo-named embedded stage4
#   * disk image         — snapdragon-free GPT partition names, FAT ESP labeled
#                          GENTOO_ESP, ESP carries EFI/BOOT/bootx64.efi
#   * UKI (Secure Boot)  — a gentoo UKI is checked on the INSTALLED ESP and the
#                          sysroot /boot (NOT the live ISO). A snapdragon-named
#                          UKI FAILs. A missing UKI is a WARN, not a FAIL:
#                          absence is a boot-chain regression, not a
#                          brand-neutrality violation, and only neutrality
#                          violations fail this gate.
#   * sysroot            — marker tree / tools / k8s / hostname neutrality
#   * fs + stage4 tars   — same neutrality sweep over the tarball listings
#                          (multi-GB xz — these passes take minutes)
#   * raw-string sweep   — attributed 'snapdragon' hit count on the live ISO
#                          (kernel/firmware legitimately carry Qualcomm
#                          Snapdragon driver strings; hits are attributed,
#                          never blanket-failed)
#
# Usage:
#   scripts/verify-artifact-neutrality.sh [options] <artifact-dir> [builder-image]
#
#   <artifact-dir>    directory holding the build outputs
#                     (gentoo-*.live.iso / *.installer.iso / *.img /
#                      *.fs.tar.xz / *.stage4.tar.xz — any subset)
#   [builder-image]   local container image providing unsquashfs, parted and
#                     mdir (default: snapdragon-builder). Never pulled — this
#                     tool makes NO network access.
#
# Options:
#   --sysroot=PATH    baked sysroot to sweep (default: first */sysroot or
#                     ./sysroot directory found under <artifact-dir>)
#   --workdir=DIR     scratch base for extracted pieces, needs room for the
#                     live squashfs (default: $TMPDIR, else /var/tmp)
#   -h, --help        show this header
#
# Fails closed: exits 0 only when at least one check ran and none FAILed
# (WARNs are allowed); exits non-zero otherwise, with a full check tally.
# =============================================================================
set -u

usage() { sed -n '2,53p' "$0"; }

DIR=""
BUILDER_IMG="snapdragon-builder"
SYSROOT=""
WORKBASE="${TMPDIR:-/var/tmp}"
npos=0
for a in "$@"; do
  case "$a" in
    -h|--help)    usage; exit 0 ;;
    --sysroot=*)  SYSROOT="${a#--sysroot=}" ;;
    --workdir=*)  WORKBASE="${a#--workdir=}" ;;
    --*)          echo "unknown option: $a" >&2; usage >&2; exit 2 ;;
    *)            npos=$((npos+1))
                  case "$npos" in
                    1) DIR="$a" ;;
                    2) BUILDER_IMG="$a" ;;
                    *) echo "too many arguments: $a" >&2; usage >&2; exit 2 ;;
                  esac ;;
  esac
done
if [ -z "$DIR" ]; then usage >&2; exit 2; fi
if [ ! -d "$DIR" ]; then echo "FATAL: artifact dir not found: $DIR" >&2; exit 2; fi

PASS=0; FAIL=0; WARN=0
ok()   { echo "PASS: $*"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
warn() { echo "WARN: $*"; WARN=$((WARN+1)); }
note() { echo "NOTE: $*"; }

# --- preflight: required host tools; fail closed on anything missing --------
missing=0
for t in xorriso file tar xz strings awk dd sed grep sort uniq; do
  if ! command -v "$t" >/dev/null 2>&1; then
    bad "required tool missing on host: $t"
    missing=1
  fi
done
if [ "$missing" -eq 1 ]; then
  echo "===== NEUTRALITY: aborting — install the missing tools above ====="
  exit 1
fi
HAVE_BUILDER=0
if command -v docker >/dev/null 2>&1 \
   && docker image inspect "$BUILDER_IMG" >/dev/null 2>&1; then
  HAVE_BUILDER=1
else
  bad "builder image '$BUILDER_IMG' not usable locally (docker + local image required for squashfs/partition/ESP checks; this tool never pulls)"
fi

WORK="$(mktemp -d "${WORKBASE%/}/verify-neutrality.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

# helper: 0/non-0 verdict -> PASS/FAIL line
verdict() { # verdict <rc> <pass-msg> <fail-msg>
  if [ "$1" -eq 0 ]; then ok "$2"; else bad "$3"; fi
}
# helper: ISO volume id
iso_volid() { xorriso -indev "$1" -pvd_info 2>/dev/null | sed -n 's/^Volume Id[[:space:]]*: //p'; }
# helper: ISO file tree, one path per line, xorriso's quoting stripped.
# (xorriso -find prints every path single-quoted; feeding a quoted path back
#  into -extract fails — strip the quotes here, once, for every consumer.)
iso_tree() { xorriso -indev "$1" -find / 2>/dev/null | sed "s/^'//;s/'\$//"; }
# helper: extract one file from an ISO (path must already be unquoted)
iso_extract() { # iso_extract <iso> <path-in-iso> <dest>
  xorriso -osirrox on -indev "$1" -extract "$2" "$3" >/dev/null 2>&1
}
# helper: neutrality sweep over a file listing (squashfs / tar / sysroot find)
sweep_listing() { # sweep_listing <listing-file> <label>
  local lst="$1" what="$2" rc
  ! grep -q 'etc/snapdragon' "$lst"; verdict $? \
      "$what: no /etc/snapdragon marker tree" \
      "$what: /etc/snapdragon marker tree present"
  grep -q 'etc/gentoo' "$lst"; verdict $? \
      "$what: /etc/gentoo present" \
      "$what: /etc/gentoo missing"
  ! grep -Eq 'bin/snapdragon-' "$lst"; rc=$?
  if [ $rc -eq 0 ]; then ok "$what: no snapdragon-* tools"; else
    bad "$what: snapdragon-* tools present: $(grep -E 'bin/snapdragon-' "$lst" | head -3 | tr '\n' ' ')"
  fi
  ! grep -Eq 'bin/(kubelet|kubeadm|kubectl|containerd)$' "$lst"; verdict $? \
      "$what: no k8s payload (kubelet/kubeadm/kubectl/containerd)" \
      "$what: k8s binaries present: $(grep -E 'bin/(kubelet|kubeadm|kubectl|containerd)$' "$lst" | head -3 | tr '\n' ' ')"
}
# helper: hostname value -> PASS/WARN/FAIL
check_hostname() { # check_hostname <value> <label>
  local hn="$1" what="$2"
  if echo "$hn" | grep -qi 'snapdragon'; then
    bad "$what: hostname is snapdragon-branded: '$hn'"
  elif echo "$hn" | grep -q 'gentoo'; then
    ok "$what: hostname is neutral ('$(echo "$hn" | grep gentoo | head -1)')"
  else
    warn "$what: hostname could not be confirmed neutral (read: '$hn')"
  fi
}
in_builder() { # in_builder <host-dir-to-mount-ro> <cmd...>
  local vol="$1"; shift
  docker run --rm --network=none -v "$vol":/a:ro "$BUILDER_IMG" "$@" 2>/dev/null
}

# --- artifact discovery (generic: any unaffiliated build output subset) -----
shopt -s nullglob
LIVE_ISOS=("${DIR%/}"/gentoo-*.live.iso)
INST_ISOS=("${DIR%/}"/gentoo-*.installer.iso)
IMGS=("${DIR%/}"/gentoo-*.img)
FS_TARS=("${DIR%/}"/gentoo-*.fs.tar.xz)
STAGE4_TARS=("${DIR%/}"/gentoo-*.stage4.tar.xz)
SNAP_NAMED=("${DIR%/}"/snapdragon-*)

if [ -z "$SYSROOT" ]; then
  SYSROOT="$(find "$DIR" -maxdepth 2 -type d -name sysroot 2>/dev/null | head -1)"
  [ -n "$SYSROOT" ] && note "auto-discovered sysroot: $SYSROOT"
fi

total_found=$(( ${#LIVE_ISOS[@]} + ${#INST_ISOS[@]} + ${#IMGS[@]} + ${#FS_TARS[@]} + ${#STAGE4_TARS[@]} ))
if [ "$total_found" -eq 0 ] && [ -z "$SYSROOT" ]; then
  bad "nothing to verify: no gentoo-* artifacts and no sysroot under $DIR"
fi

# --- 0. artifact names are neutral -------------------------------------------
[ ${#SNAP_NAMED[@]} -eq 0 ]; verdict $? \
    "artifact names: no snapdragon-named files in $DIR" \
    "artifact names: snapdragon-named files present: ${SNAP_NAMED[*]:-}"

# UKI evidence is gathered from the INSTALLED ESP and the sysroot /boot and
# judged once, after both sections (the live ISO is deliberately NOT a UKI
# source — live media boots the bare bootx64.efi grub stub by design).
UKI_HITS="$WORK/uki-hits"; : > "$UKI_HITS"
UKI_SOURCES=0

# --- 1. live ISO --------------------------------------------------------------
for iso in "${LIVE_ISOS[@]}"; do
  b="$(basename "$iso")"
  volid="$(iso_volid "$iso")"
  [ "$volid" = "GENTOO_LIVE" ]; verdict $? \
      "$b: volid GENTOO_LIVE" "$b: volid '$volid' (want GENTOO_LIVE)"

  tree="$WORK/live-tree"; iso_tree "$iso" > "$tree"
  if [ ! -s "$tree" ]; then
    bad "$b: could not list ISO tree"
    continue
  fi
  ! grep -qi 'snapdragon' "$tree"; verdict $? \
      "$b: no snapdragon-named paths in ISO tree" \
      "$b: snapdragon-named paths in ISO tree: $(grep -i snapdragon "$tree" | head -3 | tr '\n' ' ')"
  grep -qi '/efi/boot/bootx64\.efi$' "$tree"; verdict $? \
      "$b: bare EFI/BOOT/bootx64.efi present (live media boots this by design; no UKI expected on live media)" \
      "$b: EFI/BOOT/bootx64.efi missing from ISO tree"

  grub_path="$(grep -Ei '/grub\.cfg$' "$tree" | head -1)"
  grub="$WORK/live-grub.cfg"; rm -f "$grub"
  [ -n "$grub_path" ] && iso_extract "$iso" "$grub_path" "$grub"
  if [ -s "$grub" ]; then
    grep -q 'gentoo\.install=' "$grub"; verdict $? \
        "$b: grub.cfg carries the gentoo.install= cmdline key" \
        "$b: gentoo.install= cmdline key missing from grub.cfg"
    grep -q 'GENTOO_LIVE' "$grub"; verdict $? \
        "$b: grub.cfg references CDLABEL GENTOO_LIVE" \
        "$b: GENTOO_LIVE label missing from grub.cfg"
    ! grep -qi 'snapdragon' "$grub"; verdict $? \
        "$b: grub.cfg is snapdragon-free" \
        "$b: snapdragon token in grub.cfg: $(grep -i snapdragon "$grub" | head -2 | tr '\n' ' ')"
  else
    bad "$b: could not extract grub.cfg from ISO (path: '${grub_path:-none found}')"
  fi

  sq_path="$(grep -Ei '\.squashfs$|squashfs\.img$|image\.squashfs$' "$tree" | head -1)"
  if [ -n "$sq_path" ] && [ "$HAVE_BUILDER" -eq 1 ]; then
    sq="$WORK/live.squashfs"; rm -f "$sq"
    iso_extract "$iso" "$sq_path" "$sq"
    if [ -s "$sq" ]; then
      lst="$WORK/squashfs-list"
      in_builder "$WORK" unsquashfs -l /a/live.squashfs > "$lst"
      if [ -s "$lst" ]; then
        sweep_listing "$lst" "$b squashfs"
        grep -q 'libexec/gentoo-calamares-install' "$lst"; verdict $? \
            "$b squashfs: gentoo-calamares-install bridge present" \
            "$b squashfs: gentoo-calamares-install bridge missing"
      else
        bad "$b: unsquashfs listing failed in builder container"
      fi
      rm -f "$sq"
    else
      bad "$b: could not extract squashfs '$sq_path' from ISO"
    fi
  elif [ -n "$sq_path" ]; then
    bad "$b: squashfs '$sq_path' found but builder image unavailable — squashfs sweep did not run"
  else
    bad "$b: no squashfs found in live ISO tree"
  fi

  # attributed raw-string sweep (never blanket-failed: kernel/firmware carry
  # legitimate Qualcomm Snapdragon driver strings)
  hits="$(strings -a "$iso" 2>/dev/null | grep -ci 'snapdragon')" || hits=0
  ok "$b: attributed raw-string sweep done — ${hits} 'snapdragon' hit(s) (qcom kernel/firmware strings are legitimate; top sources below if any)"
  if [ "${hits:-0}" -gt 0 ]; then
    strings -a "$iso" 2>/dev/null | grep -i 'snapdragon' | sort | uniq -c | sort -rn | head -10
  fi
done

# --- 2. installer ISO ---------------------------------------------------------
for iso in "${INST_ISOS[@]}"; do
  b="$(basename "$iso")"
  volid="$(iso_volid "$iso")"
  [ "$volid" = "GENTOO_INSTALL" ]; verdict $? \
      "$b: volid GENTOO_INSTALL" "$b: volid '$volid' (want GENTOO_INSTALL)"
  tree="$WORK/inst-tree"; iso_tree "$iso" > "$tree"
  if [ ! -s "$tree" ]; then
    bad "$b: could not list ISO tree"
    continue
  fi
  ! grep -qi 'snapdragon' "$tree"; verdict $? \
      "$b: no snapdragon-named paths in ISO tree" \
      "$b: snapdragon-named paths in ISO tree: $(grep -i snapdragon "$tree" | head -3 | tr '\n' ' ')"
  if grep -q '^/stage4/' "$tree"; then
    grep -E '^/stage4/.+' "$tree" | grep -vq '/stage4/gentoo-'; rc=$?
    [ $rc -ne 0 ]; verdict $? \
        "$b: embedded stage4 tarball is gentoo-named" \
        "$b: non-gentoo-named file under /stage4: $(grep -E '^/stage4/.+' "$tree" | grep -v '/stage4/gentoo-' | head -2 | tr '\n' ' ')"
  fi
  # attributed content note on root-level installer scripts (informational)
  while IFS= read -r sh_path; do
    f="$WORK/inst-script"; rm -f "$f"
    if iso_extract "$iso" "$sh_path" "$f" && [ -s "$f" ]; then
      n="$(grep -ci 'snapdragon' "$f")" || n=0
      [ "${n:-0}" -gt 0 ] && note "$b: installer script $sh_path carries ${n} 'snapdragon' token(s) (attributed, informational): $(grep -i snapdragon "$f" | head -2 | tr '\n' ' ')"
    fi
  done < <(grep -E '^/[^/]+\.sh$' "$tree")
done

# --- 3. installed disk image: partitions, ESP label, ESP contents ------------
for img in "${IMGS[@]}"; do
  b="$(basename "$img")"
  if [ "$HAVE_BUILDER" -ne 1 ]; then
    bad "$b: builder image unavailable — partition/ESP checks did not run"
    continue
  fi
  pt="$WORK/parted"
  in_builder "$(dirname "$img")" parted -sm "/a/$b" unit B print > "$pt"
  if [ ! -s "$pt" ]; then
    bad "$b: could not read partition table (parted in builder container failed)"
    continue
  fi
  ! grep -qi 'snapdragon' "$pt"; verdict $? \
      "$b: partition-table names are snapdragon-free" \
      "$b: snapdragon token in partition table: $(grep -i snapdragon "$pt" | head -2 | tr '\n' ' ')"

  esp_off="$(awk -F: '$5~/^fat/{gsub(/B/,"",$2); print $2; exit}' "$pt")"
  if [ -n "$esp_off" ]; then
    UKI_SOURCES=$((UKI_SOURCES+1))
    if [ $((esp_off % 512)) -eq 0 ]; then
      lbl="$(dd if="$img" bs=512 skip=$((esp_off / 512)) count=1 2>/dev/null | file - )"
    else
      lbl="$(dd if="$img" bs=1 skip="$esp_off" count=512 2>/dev/null | file - )"
    fi
    lbl="$(echo "$lbl" | grep -oE 'label: "[^"]*"')" || lbl=""
    echo "$lbl" | grep -q 'GENTOO_ESP'; verdict $? \
        "$b: ESP volume label GENTOO_ESP" \
        "$b: ESP volume label not GENTOO_ESP (read: '${lbl:-unreadable}')"
    esp="$WORK/esp-list"
    in_builder "$(dirname "$img")" mdir -i "/a/$b@@$esp_off" -/ -b ::/ > "$esp"
    if [ -s "$esp" ]; then
      grep -qi 'EFI/BOOT/BOOTX64\.EFI$' "$esp"; verdict $? \
          "$b: installed ESP carries EFI/BOOT/bootx64.efi" \
          "$b: EFI/BOOT/bootx64.efi missing from installed ESP"
      ! grep -qi 'snapdragon' "$esp"; verdict $? \
          "$b: installed ESP file names are snapdragon-free" \
          "$b: snapdragon-named file on installed ESP: $(grep -i snapdragon "$esp" | head -2 | tr '\n' ' ')"
      grep -Ei '/gentoo[^/]*\.efi$|EFI/LINUX/[^/]+\.efi$' "$esp" >> "$UKI_HITS" || true
    else
      bad "$b: could not list installed ESP contents (mdir in builder container failed)"
    fi
  else
    bad "$b: no FAT ESP partition found in partition table"
  fi
done

# --- 4. sysroot ---------------------------------------------------------------
if [ -n "$SYSROOT" ]; then
  if [ ! -d "$SYSROOT" ]; then
    bad "sysroot: not a directory: $SYSROOT"
  else
    s="${SYSROOT%/}"
    lst="$WORK/sysroot-list"
    find -H "$s/etc" "$s/bin" "$s/sbin" "$s/usr/bin" "$s/usr/sbin" \
         -maxdepth 1 2>/dev/null > "$lst" || true
    sweep_listing "$lst" "sysroot"
    hn="$(grep -hv '^#' "$s/etc/conf.d/hostname" "$s/etc/hostname" 2>/dev/null | head -2)"
    check_hostname "${hn:-}" "sysroot"
    if [ -d "$s/boot" ] || [ -d "$s/efi" ]; then
      UKI_SOURCES=$((UKI_SOURCES+1))
      find -H "$s/boot" "$s/efi" -iname '*.efi' 2>/dev/null \
        | grep -Ei '/gentoo[^/]*\.efi$|EFI/Linux/[^/]+\.efi$' >> "$UKI_HITS" || true
    fi
  fi
else
  note "no sysroot found or given — sysroot sweep skipped (pass --sysroot=PATH to include it)"
fi

# --- 5. UKI verdict (installed ESP + sysroot /boot only) ----------------------
if [ -s "$UKI_HITS" ]; then
  ! grep -qi 'snapdragon' "$UKI_HITS"; verdict $? \
      "UKI present on installed ESP / sysroot boot: $(head -2 "$UKI_HITS" | tr '\n' ' ')" \
      "UKI found but snapdragon-named: $(grep -i snapdragon "$UKI_HITS" | head -2 | tr '\n' ' ')"
elif [ "$UKI_SOURCES" -gt 0 ]; then
  warn "no UKI (gentoo*.efi / EFI/Linux/*.efi) on the installed ESP or sysroot /boot — the build profile already wires the UKI chain (sys-kernel/dracut[uefi] + sys-apps/systemd-utils[boot], landed in #307), so a missing UKI is a genuine finding, NOT an expected or blocked state: the in-chroot 'dracut --uefi' step failed or was skipped and the Secure Boot chain has degraded to GRUB+vmlinuz. Check the builder log for 'dracut --uefi failed' / 'UKI skipped'. WARN not FAIL: absence is a boot-chain regression, not a brand-neutrality violation."
elif [ "$total_found" -gt 0 ] || [ -n "$SYSROOT" ]; then
  warn "no installed ESP or sysroot boot tree available — UKI check could not run"
fi

# --- 6. fs / stage4 tarball listings (multi-GB xz — minutes each) -------------
sweep_tar() { # sweep_tar <tarball> <label>
  local t="$1" what="$2" lst member hn
  lst="$WORK/tar-list"
  note "$what: listing $(basename "$t") (multi-GB xz — this takes minutes)..."
  tar -tJf "$t" 2>/dev/null > "$lst"
  if [ ! -s "$lst" ]; then
    bad "$what: could not list tarball $(basename "$t")"
    return
  fi
  sweep_listing "$lst" "$what"
  member="$(grep -E '(^|/)etc/conf\.d/hostname$|(^|/)etc/hostname$' "$lst" | head -1)"
  if [ -n "$member" ]; then
    hn="$(tar -xJf "$t" --occurrence=1 --to-stdout "$member" 2>/dev/null | grep -v '^#' | head -2)"
    check_hostname "${hn:-}" "$what"
  else
    warn "$what: no hostname file in tarball — hostname check skipped"
  fi
}
for t in "${FS_TARS[@]}";     do sweep_tar "$t" "fs-tar";     done
for t in "${STAGE4_TARS[@]}"; do sweep_tar "$t" "stage4-tar"; done

# --- tally ---------------------------------------------------------------------
echo
TOTAL=$((PASS + WARN + FAIL))
echo "===== NEUTRALITY: ${PASS} passed, ${WARN} warned, ${FAIL} failed (${TOTAL} checks) ====="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
if [ "$PASS" -eq 0 ]; then echo "FAIL-CLOSED: no checks ran" ; exit 1; fi
exit 0
