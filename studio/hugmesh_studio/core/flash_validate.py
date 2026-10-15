"""Check a built image WITHOUT flashing it (#415, deliverable D).

Nothing here opens a block device, runs ``dd``, or needs root. Every check is a
read of the ARTIFACT — ``os.stat``, the first 32 KiB, ``xz --robot --list`` (which
reads the index, not the payload), and ``hashlib`` over the file when the build left
a checksum beside it. The device only ever contributes its SIZE, which the caller
already has from the read-only ``lsblk`` scan.

Why it exists: until #415 nothing validated an image at all. ``scripts/flash-disk.sh``
checks size-fit and refuses a non-whole-disk, but both of those happen seconds before
``dd`` starts, behind the one destroy confirmation — so "is this actually the image I
meant, and is it intact?" could only be answered by writing it and booting.

What it CANNOT check is stated in the report itself, never implied:

  * **Contents.** For a compressed artifact only the xz container is inspected
    (magic + index). ``xz -t`` would verify the CRC64 of the payload, but on the
    operator's real 2.9 GiB / 50.5 GiB-uncompressed image that is a multi-minute full
    decompression, so it is not run here.
  * **Bootability.** A valid partition table is not a booting system. The QEMU
    device tests are what answer that.
  * **Provenance.** A checksum is only verified when the build left one next to the
    image. The stage4 builders do NOT write one (measured on the operator's
    2026-09-16 session: no ``.sha256`` and no ``SHA256SUMS`` beside any artifact) —
    only ``scripts/publish-images.sh`` writes ``SHA256SUMS``, into its own publish
    tree. So on a freshly built image this check reports "not verified" and says why,
    which is the honest answer, not a pass.
  * **Which device is which.** Role/arch are matched against the artifact's NAME, the
    same two anchors flash-disk.sh globs on. A correctly-named image for the wrong
    physical stick still matches.
"""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
from dataclasses import dataclass

from . import flash_targets as ft

# A whole-disk OS image below this is not a whole-disk OS image — it is a truncated
# copy, an aborted build, or the wrong file. The smallest thing the builders emit is a
# live ISO in the hundreds of MiB; 16 MiB is a floor no real artifact approaches.
_MIN_WRITE_SIZE = 16 << 20

# magic, measured against the operator's real 2026-09-16 artifacts:
#   .img.xz       -> fd 37 7a 58 5a 00                          (xz container)
#   .installer.iso-> "CD001" at 0x8001                          (ISO9660 PVD)
#   .live.iso     -> "CD001" at 0x8001 AND 55 aa at 510 AND "EFI PART" at 512 (hybrid)
_XZ_MAGIC = b"\xfd7zXZ\x00"
_ISO_PVD_OFF = 0x8001
_ISO_PVD = b"CD001"
_MBR_SIG_OFF = 510
_MBR_SIG = b"\x55\xaa"
_GPT_OFF = 512
_GPT_SIG = b"EFI PART"
_HEAD_BYTES = 0x8010

_SUM_LINE_RE = re.compile(r"^([0-9a-fA-F]{64})\s+[*]?(.+)$")

OK, BAD, SKIP = "ok", "bad", "skip"


@dataclass(frozen=True)
class Check:
    """One named verdict. ``SKIP`` is a check that could not run — it is rendered
    distinctly from ``OK`` on purpose, so "not verified" never reads as "verified"."""
    name: str
    state: str
    detail: str

    def line(self) -> str:
        glyph = {OK: "✔", BAD: "✘", SKIP: "–"}.get(self.state, "?")
        return f"  {glyph} {self.name}: {self.detail}"


@dataclass(frozen=True)
class ImageReport:
    artifact: str
    device: str
    checks: tuple[Check, ...]

    @property
    def ok(self) -> bool:
        return all(c.state != BAD for c in self.checks)

    @property
    def unverified(self) -> tuple[str, ...]:
        return tuple(c.name for c in self.checks if c.state == SKIP)

    def text(self) -> str:
        head = os.path.basename(self.artifact) or "(no image selected)"
        if self.device:
            head += f"  →  {self.device}"
        verdict = "OK" if self.ok else "PROBLEM"
        if self.ok and self.unverified:
            verdict = "OK (" + ", ".join(self.unverified) + " not verified)"
        return "\n".join([f"{head}  —  {verdict}"] + [c.line() for c in self.checks])


def _head(path: str) -> bytes:
    try:
        with open(path, "rb") as fh:
            return fh.read(_HEAD_BYTES)
    except OSError:
        return b""


def uncompressed_size(path: str) -> int:
    """Bytes that will actually be WRITTEN: the xz index's uncompressed total for a
    ``.xz``, else the file size. 0 when it cannot be determined.

    This is the same number scripts/flash-disk.sh computes as ART_SIZE (and now
    reports as its ``Write-bytes:`` line), by the same command, so the validator's
    size-fit verdict and the flasher's own cannot disagree."""
    if ft.is_compressed_artifact(path):
        try:
            out = subprocess.run(["xz", "--robot", "--list", path], check=False,
                                 capture_output=True, text=True, timeout=60).stdout
        except (OSError, subprocess.SubprocessError):
            return 0
        for line in out.splitlines():
            fields = line.split("\t")
            if fields and fields[0] == "totals" and len(fields) > 4:
                # xz prints a ZEROED totals row and exits 1 on a truncated/non-xz
                # file, so a digits check is relied on, not belt-and-braces —
                # exactly the trap flash-disk.sh documents at its own ART_SIZE.
                return int(fields[4]) if fields[4].isdigit() else 0
        return 0
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def _checksum_sidecar(path: str) -> tuple[str, str]:
    """``(expected_hex, source)`` for an image the build left a checksum for, else
    ``("", "")``. Looks for ``<image>.sha256`` / ``.sha256sum`` and for a ``SHA256SUMS``
    (publish-images.sh's spelling) listing this basename."""
    base = os.path.basename(path)
    for suffix in (".sha256", ".sha256sum"):
        side = path + suffix
        try:
            with open(side, encoding="utf-8") as fh:
                first = fh.readline().strip()
        except OSError:
            continue
        m = _SUM_LINE_RE.match(first)
        if m:
            return m.group(1).lower(), os.path.basename(side)
        if re.fullmatch(r"[0-9a-fA-F]{64}", first):
            return first.lower(), os.path.basename(side)
    for sums in ("SHA256SUMS", "sha256sums.txt", "SHA256SUMS.txt"):
        cand = os.path.join(os.path.dirname(path), sums)
        try:
            with open(cand, encoding="utf-8") as fh:
                for line in fh:
                    m = _SUM_LINE_RE.match(line.strip())
                    if m and os.path.basename(m.group(2)) == base:
                        return m.group(1).lower(), sums
        except OSError:
            continue
    return "", ""


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 22), b""):
                h.update(chunk)
    except OSError:
        return ""
    return h.hexdigest()


def _format_check(path: str, head: bytes) -> Check:
    base = os.path.basename(path).lower()
    if ft.is_compressed_artifact(base):
        if not head.startswith(_XZ_MAGIC):
            return Check("format", BAD,
                         "no xz magic — this is not an xz stream (truncated? renamed?)")
        if uncompressed_size(path) <= 0:
            return Check("format", BAD,
                         "xz magic is present but the index is unreadable — the file "
                         "is truncated or corrupt")
        return Check("format", OK, "valid xz container (magic + readable index)")
    if base.endswith(".iso"):
        if head[_ISO_PVD_OFF:_ISO_PVD_OFF + len(_ISO_PVD)] != _ISO_PVD:
            return Check("format", BAD,
                         "no ISO9660 'CD001' descriptor at 0x8001 — not an ISO")
        hybrid = (head[_MBR_SIG_OFF:_MBR_SIG_OFF + 2] == _MBR_SIG
                  and head[_GPT_OFF:_GPT_OFF + len(_GPT_SIG)] == _GPT_SIG)
        return Check("format", OK, "ISO9660" + (" + hybrid MBR/GPT (USB-bootable)"
                                                if hybrid else ""))
    if base.endswith(".img"):
        if head[_GPT_OFF:_GPT_OFF + len(_GPT_SIG)] == _GPT_SIG:
            return Check("format", OK, "GPT partition table")
        if head[_MBR_SIG_OFF:_MBR_SIG_OFF + 2] == _MBR_SIG:
            return Check("format", OK, "MBR partition table")
        return Check("format", BAD,
                     "no MBR signature at 0x1fe and no GPT header at 0x200 — this .img "
                     "carries no partition table")
    ext = os.path.splitext(base)[1] or base
    return Check("format", SKIP, f"no format check for '{ext}' files")


def check_image(path: str, *, device_size: int = 0, device_path: str = "",
                role: str = "", arch: str = "",
                flavor: str = ft.FLAVOR_AUTO) -> ImageReport:
    """Check ONE image against ONE target. Read-only; never writes, never flashes."""
    checks: list[Check] = []
    if not path:
        return ImageReport("", device_path, (Check("image", BAD,
                                                   "no image is selected for this "
                                                   "target"),))
    if not os.path.isfile(path):
        return ImageReport(path, device_path,
                           (Check("exists", BAD, f"not found: {path}"),))
    if not os.access(path, os.R_OK):
        return ImageReport(path, device_path,
                           (Check("exists", BAD, f"not readable: {path}"),))
    if not ft.is_flashable_artifact(os.path.basename(path)):
        return ImageReport(path, device_path,
                           (Check("kind", BAD,
                                  "not a flashable artifact — scripts/flash-disk.sh "
                                  "accepts only .img/.iso/.img.xz/.iso.xz, and never a "
                                  "kernel/initramfs/initrd/squashfs blob"),))
    file_size = os.path.getsize(path)
    if file_size <= 0:
        return ImageReport(path, device_path,
                           (Check("exists", BAD, "the file is empty (0 bytes)"),))
    checks.append(Check("exists", OK,
                        f"{ft.human_size(file_size)} on disk, readable"))

    checks.append(_format_check(path, _head(path)))

    write = uncompressed_size(path)
    if write <= 0:
        checks.append(Check("size", BAD, "could not determine the size that will be "
                                         "written"))
    elif write < _MIN_WRITE_SIZE:
        checks.append(Check("size", BAD,
                            f"only {ft.human_size(write)} would be written — far too "
                            f"small for a whole-disk image (truncated build?)"))
    elif device_size and write > device_size:
        checks.append(Check("size", BAD,
                            f"{ft.human_size(write)} will be written but "
                            f"{device_path or 'the device'} holds only "
                            f"{ft.human_size(device_size)} — it will not fit"))
    elif device_size:
        checks.append(Check("size", OK,
                            f"{ft.human_size(write)} written of "
                            f"{ft.human_size(device_size)} available"))
    else:
        checks.append(Check("size", SKIP,
                            f"{ft.human_size(write)} will be written; no device "
                            f"selected, so the fit was not checked"))

    got_flavor = ft.classify_artifact_flavor(path)
    bits: list[str] = []
    bad = False
    if role or arch:
        if ft.artifact_matches(path, role=role, arch=arch):
            bits.append(f"name carries {arch}/{role}")
        else:
            bad = True
            bits.append(f"name does NOT carry the target's arch ({arch}) and role "
                        f"({role}) — flash-disk.sh would not have found this file")
    if flavor and flavor != ft.FLAVOR_AUTO:
        if got_flavor == flavor:
            bits.append(f"flavour {flavor}")
        else:
            bad = True
            bits.append(f"flavour is '{got_flavor or 'unflavoured'}', not the "
                        f"planned '{flavor}'")
    if not bits:
        checks.append(Check("naming", SKIP,
                            "no role/arch/flavour given for this target"))
    else:
        checks.append(Check("naming", BAD if bad else OK, "; ".join(bits)))

    expected, source = _checksum_sidecar(path)
    if not expected:
        checks.append(Check("checksum", SKIP,
                            "the build wrote no checksum beside this image "
                            "(no .sha256 and no SHA256SUMS) — nothing to verify "
                            "against"))
    else:
        actual = _sha256(path)
        if not actual:
            checks.append(Check("checksum", BAD,
                                f"{source} exists but the image could not be read to "
                                f"hash it"))
        elif actual == expected:
            checks.append(Check("checksum", OK, f"sha256 matches {source}"))
        else:
            checks.append(Check("checksum", BAD,
                                f"sha256 MISMATCH against {source} — the image is not "
                                f"the one that was published"))
    return ImageReport(path, device_path, tuple(checks))


def report_text(reports) -> str:
    """The inline pane's whole body: one block per image, plus a one-line summary."""
    reports = list(reports)
    if not reports:
        return "Nothing to check — no image is selected."
    body = "\n\n".join(r.text() for r in reports)
    bad = [r for r in reports if not r.ok]
    if bad:
        head = (f"{len(bad)} of {len(reports)} image(s) have a PROBLEM — "
                f"see below. Nothing has been written.")
    else:
        head = (f"{len(reports)} image(s) checked, no problems found. "
                f"Nothing has been written.")
    return head + "\n\n" + body
