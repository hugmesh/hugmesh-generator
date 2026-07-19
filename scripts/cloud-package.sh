#!/usr/bin/env bash
# cloud-package.sh — convert a built x86 raw .img into a cloud-uploadable format.
#
# Standalone OPERATOR tool, deliberately NOT wired into the builders' hot path:
# you build the normal x86 raw .img first (any channel), then package it for the
# cloud you are importing into. One artifact per run:
#
#   qcow2      qemu-img convert -O qcow2            -> <base>.qcow2
#              (KubeVirt/CNV DataVolumes, libvirt/RHEL virt-install, OpenStack)
#   vhd-fixed  round the virtual size UP to a whole MiB, then
#              qemu-img convert -O vpc -o subformat=fixed,force_size -> <base>.vhd
#              (Azure HARD-requires a fixed VHD whose virtual size is a whole-MiB
#              multiple; the compact .img is 1+512+ROOT+1 MiB so it usually already
#              is one — the round-up only pads when an input isn't. Padding happens
#              on a WORKING COPY; the input .img is never mutated.)
#   raw        byte-identical copy                  -> <base>.img
#              (AWS ec2 import-snapshot ingests RAW as-is — no conversion, but you
#              get the manifest line + checksum for the upload.)
#
# Every run appends one manifest line to <out-dir>/cloud-package.manifest and
# echoes it (the parseable API):
#
#   FORMAT <fmt> FILE <path> BYTES <n> SHA256 <hex>
#
# x86 ONLY: the ARM images (rpi/jetson/frite/orangepi) boot via u-boot / L4T +
# board-specific firmware, not the generic UEFI path clouds emulate — converting
# one produces an unbootable disk, so non-x86 artifacts are REFUSED by filename
# shape (the builders' <brand>-<platform>-<arch>-... naming). Only the x86 raw
# .img (pure-UEFI GPT, PARTUUID fstab, growroot) is cloud-viable today.
#
# Env seam: SNAP_QEMU_IMG overrides the qemu-img binary (tests stub it; raw
# needs no qemu-img at all). No secrets are read, written or printed here.
#
#   scripts/cloud-package.sh --img work/acme-x86-amd64-pki-prod-<ts>.img \
#       --format vhd-fixed --out-dir cloud-out/
#
# What this does NOT solve (see docs/CLOUD-IMAGE-PACKAGING.md): first-boot
# provisioning still needs a KEYS volume (no cloud-init/waagent is baked), and
# cloud NIC/disk drivers (ENA, hv_*) are a kernel-config concern, not a format one.
set -euo pipefail

if [ -t 2 ]; then C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_RST=$'\033[0m'; else C_RED=""; C_YEL=""; C_RST=""; fi
info() { printf '[cloud-package] %s\n' "$*"; }
warn() { printf '%s[cloud-package] WARNING:%s %s\n' "${C_YEL}" "${C_RST}" "$*" >&2; }
die()  { printf '%s[cloud-package] ERROR:%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; exit 1; }

usage() {
cat <<EOF
Usage: $0 --img <raw.img> --format qcow2|vhd-fixed|raw --out-dir <dir>

  Converts a built x86 raw .img into ONE cloud-uploadable artifact and appends
  a "FORMAT <fmt> FILE <path> BYTES <n> SHA256 <hex>" line to
  <out-dir>/cloud-package.manifest.

Options:
  --img PATH       The built x86 raw image (<brand>-x86-amd64-...-<stamp>.img).
  --format FMT     qcow2 (KubeVirt/libvirt/OpenStack) | vhd-fixed (Azure Gen2,
                   whole-MiB fixed VPC) | raw (AWS import-snapshot; checksum copy).
  --out-dir DIR    Where the artifact + manifest land (created if absent).
  -h, --help       Show this help.

Env:
  SNAP_QEMU_IMG    qemu-img binary override (default: qemu-img on PATH).
EOF
exit "${1:-0}"
}

IMG=""
FORMAT=""
OUT_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --img)     IMG="${2:?--img needs a path}"; shift 2 ;;
        --format)  FORMAT="${2:?--format needs a value}"; shift 2 ;;
        --out-dir) OUT_DIR="${2:?--out-dir needs a dir}"; shift 2 ;;
        -h|--help) usage 0 ;;
        *)         echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

[ -n "${IMG}" ]     || { echo "Missing --img" >&2; usage 1; }
[ -n "${FORMAT}" ]  || { echo "Missing --format" >&2; usage 1; }
[ -n "${OUT_DIR}" ] || { echo "Missing --out-dir" >&2; usage 1; }

case "${FORMAT}" in
    qcow2|vhd-fixed|raw) : ;;
    *) die "unknown --format '${FORMAT}' (valid: qcow2 | vhd-fixed | raw)" ;;
esac

[ -e "${IMG}" ] || die "image not found: ${IMG}"
[ -f "${IMG}" ] || die "not a regular file: ${IMG} (this tool packages a built .img, not a device)"
[ -s "${IMG}" ] || die "image is EMPTY (0 bytes): ${IMG} — refusing to package a hollow artifact"

# ── x86-only refusal, by the builders' filename shape ─────────────────────────
# Every builder stamps its platform+arch into the artifact name
# (x86: <brand>-x86-amd64-<role>-<env>-<ts>.img; ARM: ...-arm64-...). We refuse
# anything not recognizably the x86 raw .img rather than emit a cloud disk that
# cannot boot: ARM images carry u-boot/L4T board firmware in place of the generic
# UEFI path (recon: cloud-nonviable), and the ISO platforms (frite/orangepi) ship
# optical media, not disks.
BASE="$(basename "${IMG}")"
case "${BASE}" in
    *.img) : ;;
    *.xz)  die "compressed artifact: ${BASE} — decompress first (unxz), then package the raw .img" ;;
    *.iso) die "ISO artifact: ${BASE} — live/installer ISOs are optical media, not cloud disks; build and package the x86 raw .img instead" ;;
    *)     die "not a .img artifact: ${BASE} — this tool packages the x86 builder's raw .img only" ;;
esac
case "${BASE}" in
    *-arm64-*)
        die "ARM artifact refused: ${BASE} — ARM images (rpi/jetson/frite/orangepi) boot via u-boot/L4T + board firmware, not the generic UEFI path clouds emulate, so a converted disk would not boot. Only the x86 raw .img is cloud-viable." ;;
esac
case "${BASE}" in
    *-x86-amd64-*) : ;;
    *)
        die "cannot confirm x86 provenance from the filename: ${BASE} — expected the x86 builder's <brand>-x86-amd64-<role>-<env>-<stamp>.img naming. Refusing to package an artifact of unknown platform (rename it back if it IS the x86 .img)." ;;
esac

# A qcow2 fed in as "raw" would convert its HEADER as disk bytes — catch the
# magic ("QFI\xfb") up front. tr strips the NULs a sparse/raw image starts with,
# keeping the substitution warning-free.
MAGIC="$(head -c 3 "${IMG}" | tr -d '\0')"
if [ "${MAGIC}" = "QFI" ]; then
    die "${BASE} is already a qcow2 (QFI magic), not the raw .img — pass the builder's raw artifact"
fi

mkdir -p "${OUT_DIR}"

STEM="${BASE%.img}"
case "${FORMAT}" in
    qcow2)     OUT="${OUT_DIR}/${STEM}.qcow2" ;;
    vhd-fixed) OUT="${OUT_DIR}/${STEM}.vhd" ;;
    raw)       OUT="${OUT_DIR}/${STEM}.img" ;;
esac
# Never clobber a prior artifact (also catches --out-dir pointed at the .img's
# own directory on --format raw, where OUT would BE the input).
if [ -e "${OUT}" ]; then
    die "output already exists: ${OUT} — refusing to overwrite (remove it or pick another --out-dir)"
fi

# qemu-img is only a dependency for the two real conversions; raw stays
# tool-free. SNAP_QEMU_IMG is the test seam (a recording stub in CI).
QEMU_IMG="${SNAP_QEMU_IMG:-qemu-img}"
if [ "${FORMAT}" != "raw" ]; then
    command -v "${QEMU_IMG}" >/dev/null 2>&1 \
        || die "qemu-img not found ('${QEMU_IMG}') — needed for ${FORMAT}. Install it (app-emulation/qemu on Gentoo, qemu-utils on Debian) or point SNAP_QEMU_IMG at one."
fi

# The only temp we ever make is the vhd padding copy; clean it on ANY exit so a
# failed convert can't leave a half-image behind in --out-dir.
PAD_TMP=""
trap '[ -z "${PAD_TMP}" ] || rm -f "${PAD_TMP}"' EXIT

IN_BYTES="$(stat -c %s "${IMG}")"

case "${FORMAT}" in
    raw)
        # Byte-identical copy: reflink where the fs supports it, sparseness kept
        # (the compact .img is mostly holes — a dense copy would be GiBs of zeros).
        info "raw: copying ${BASE} (${IN_BYTES} bytes) -> ${OUT}"
        cp --reflink=auto --sparse=auto "${IMG}" "${OUT}"
        ;;
    qcow2)
        info "qcow2: converting ${BASE} -> ${OUT}"
        "${QEMU_IMG}" convert -f raw -O qcow2 "${IMG}" "${OUT}"
        ;;
    vhd-fixed)
        # Azure hard-requires the FIXED VPC subformat with a whole-MiB virtual
        # size. Round UP (down would truncate the root partition). force_size
        # keeps qemu-img from re-deriving a CHS-aligned size behind our back.
        MIB=1048576
        VHD_BYTES=$(( ( (IN_BYTES + MIB - 1) / MIB ) * MIB ))
        SRC="${IMG}"
        if [ "${VHD_BYTES}" -ne "${IN_BYTES}" ]; then
            # Pad a WORKING COPY to the boundary; the input .img is never grown
            # in place (it may be someone else's build output). truncate on a raw
            # image is exactly qemu-img resize, minus the tool round-trip.
            PAD_TMP="${OUT}.pad.raw"
            info "vhd-fixed: padding a working copy ${IN_BYTES} -> ${VHD_BYTES} bytes (whole-MiB round-UP; input untouched)"
            cp --reflink=auto --sparse=auto "${IMG}" "${PAD_TMP}"
            truncate -s "${VHD_BYTES}" "${PAD_TMP}"
            SRC="${PAD_TMP}"
        else
            info "vhd-fixed: ${IN_BYTES} bytes is already a whole-MiB multiple ($(( IN_BYTES / MIB )) MiB) — no padding needed"
        fi
        info "vhd-fixed: converting -> ${OUT}"
        "${QEMU_IMG}" convert -f raw -O vpc -o subformat=fixed,force_size "${SRC}" "${OUT}"
        if [ -n "${PAD_TMP}" ]; then rm -f "${PAD_TMP}"; PAD_TMP=""; fi
        ;;
esac

# A convert that "succeeded" into a missing/empty file is a lie — fail loud
# before stamping a manifest line over it.
[ -s "${OUT}" ] || die "conversion produced no output at ${OUT} — refusing to manifest a hollow artifact"

OUT_BYTES="$(stat -c %s "${OUT}")"
OUT_SHA="$(sha256sum "${OUT}" | awk '{print $1}')"
MANIFEST="${OUT_DIR}/cloud-package.manifest"
LINE="FORMAT ${FORMAT} FILE ${OUT} BYTES ${OUT_BYTES} SHA256 ${OUT_SHA}"
printf '%s\n' "${LINE}" >> "${MANIFEST}"
printf '%s\n' "${LINE}"

case "${FORMAT}" in
    qcow2)     info "next: KubeVirt/CNV CDI DataVolume, libvirt virt-install --import, or OpenStack image upload" ;;
    vhd-fixed) info "next: az storage blob upload --type page, then az image create --hyper-v-generation V2 (the .img is UEFI-only: Gen2, never Gen1)" ;;
    raw)       info "next: aws s3 cp, then ec2 import-snapshot (vmimport role) + register-image --boot-mode uefi --ena-support" ;;
esac
info "provisioning reminder: no cloud-init/waagent is baked — first boot still reads a FAT32 volume labelled KEYS (attach one as a data disk/volume). See docs/CLOUD-IMAGE-PACKAGING.md."
