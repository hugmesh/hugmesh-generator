#!/usr/bin/env python3
"""Build a forwarder ``icuuc.dll`` so PySide6's Qt6Core.dll can load under Wine.

WHY THIS EXISTS. The PySide6 wheel's Qt6Core.dll links against ``icuuc.dll``, the
copy of ICU that Windows 10 ships in System32. Wine ships only ``icu.dll`` (the
combined ICU of Windows 10 1903 and later), so ``import PySide6.QtCore`` dies with

    ImportError: DLL load failed while importing QtCore: Module not found.

(``WINEDEBUG=err+module`` names the real cause: "Library icuuc.dll ... not found").
The ICU functions Qt6Core asks for are all exported by Wine's ``icu.dll``, so the
only thing missing is the name. This script writes a DLL with no code at all, just an
export table whose every entry is a FORWARDER ("ucnv_open" -> "icu.ucnv_open"), the
same mechanism Windows itself uses for its own forwarder DLLs.

The list of names is read from Qt6Core.dll's own import table rather than written
down here, so a PySide6 bump that needs one more ICU function is picked up by the
next build instead of breaking it.

THIS FILE IS A BUILD-MACHINE WORKAROUND AND MUST NEVER BE SHIPPED. It is installed
into the Wine prefix's ``windows/system32`` (where real Windows keeps the genuine
article), NOT next to Qt6Core.dll: PyInstaller treats system32 as "provided by the
OS" and leaves it out of the frozen bundle, whereas a copy beside Qt6Core would be
collected into the installer. build-msi-wine.sh checks the frozen tree for it.

    python3 wine_icu_shim.py --qt-dll .../PySide6/Qt6Core.dll --out .../system32/icuuc.dll

Stdlib only, so it runs on whatever python3 the build machine has.
"""
from __future__ import annotations

import argparse
import struct
import sys

IMAGE_BASE = 0x180000000
SECTION_ALIGN = 0x1000
FILE_ALIGN = 0x200


def _align(value: int, to: int) -> int:
    return (value + to - 1) // to * to


class _Pe:
    """Just enough of a PE reader to walk the import table of an x64 image."""

    def __init__(self, data: bytes) -> None:
        if data[:2] != b"MZ":
            raise ValueError("not a PE file (no MZ header)")
        self.data = data
        (self.pe,) = struct.unpack_from("<I", data, 0x3C)
        if data[self.pe:self.pe + 4] != b"PE\0\0":
            raise ValueError("not a PE file (no PE signature)")
        nsec, = struct.unpack_from("<H", data, self.pe + 6)
        opt_size, = struct.unpack_from("<H", data, self.pe + 20)
        self.opt = self.pe + 24
        magic, = struct.unpack_from("<H", data, self.opt)
        if magic != 0x20B:
            raise ValueError("only PE32+ (x64) images are handled")
        self.dirs = self.opt + 112
        self.sections = []
        first = self.opt + opt_size
        for i in range(nsec):
            vsize, va, raw_size, raw_ptr = struct.unpack_from("<IIII", data, first + i * 40 + 8)
            self.sections.append((va, max(vsize, raw_size), raw_ptr))

    def offset(self, rva: int) -> int:
        for va, size, raw in self.sections:
            if va <= rva < va + size:
                return rva - va + raw
        raise ValueError(f"RVA {rva:#x} is not inside any section")

    def cstr(self, offset: int) -> str:
        end = self.data.index(b"\0", offset)
        return self.data[offset:end].decode("latin1")

    def imports(self, dll: str) -> list[str]:
        """Names imported BY NAME from ``dll`` (case-insensitive). Ordinal imports are
        skipped: a forwarder is keyed on names and Qt imports ICU by name."""
        rva, _size = struct.unpack_from("<II", self.data, self.dirs + 8)
        if not rva:
            return []
        want = dll.lower()
        out: list[str] = []
        desc = self.offset(rva)
        while True:
            oft, _ts, _fc, name_rva, ft = struct.unpack_from("<IIIII", self.data, desc)
            if name_rva == 0:
                break
            if self.cstr(self.offset(name_rva)).lower() == want:
                thunk = self.offset(oft or ft)
                while True:
                    (value,) = struct.unpack_from("<Q", self.data, thunk)
                    if value == 0:
                        break
                    if not value >> 63:
                        out.append(self.cstr(self.offset(value & 0x7FFFFFFF) + 2))
                    thunk += 8
            desc += 20
        return out


def build_forwarder_dll(own_name: str, target_module: str, names: list[str]) -> bytes:
    """A PE32+ DLL named ``own_name`` whose exports forward ``name`` to
    ``<target_module>.name`` for every entry of ``names``. No code, no relocations,
    no entry point: the loader resolves a forwarder at bind time."""
    if not names:
        raise ValueError("no names to forward")
    names = sorted(set(names))          # the loader binary-searches the name table

    # ── the export section, built as one blob; every RVA below is section-relative
    #    until the final `+ SECTION_ALIGN` shift ─────────────────────────────────
    n = len(names)
    dir_size = 40
    eat_off = dir_size                       # address table      n * u32
    ent_off = eat_off + 4 * n                # name pointer table n * u32
    eot_off = ent_off + 4 * n                # ordinal table      n * u16
    strings_off = _align(eot_off + 2 * n, 4)

    strings = bytearray()
    own_off = strings_off + len(strings)
    strings += own_name.encode("ascii") + b"\0"
    name_offs: list[int] = []
    fwd_offs: list[int] = []
    for name in names:
        name_offs.append(strings_off + len(strings))
        strings += name.encode("ascii") + b"\0"
    for name in names:
        fwd_offs.append(strings_off + len(strings))
        strings += f"{target_module}.{name}".encode("ascii") + b"\0"

    size = strings_off + len(strings)
    shift = SECTION_ALIGN
    blob = bytearray(size)
    struct.pack_into(
        "<IIHHIIIIIII", blob, 0,
        0, 0, 0, 0,                       # characteristics, timestamp, version
        own_off + shift,                  # name of this DLL
        1, n, n,                          # ordinal base, #functions, #names
        eat_off + shift, ent_off + shift, eot_off + shift)
    for i in range(n):
        struct.pack_into("<I", blob, eat_off + 4 * i, fwd_offs[i] + shift)
        struct.pack_into("<I", blob, ent_off + 4 * i, name_offs[i] + shift)
        struct.pack_into("<H", blob, eot_off + 2 * i, i)
    blob[strings_off:strings_off + len(strings)] = strings

    raw_size = _align(size, FILE_ALIGN)
    image_size = shift + _align(size, SECTION_ALIGN)

    dos = bytearray(64)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, 0x40)

    coff = struct.pack("<HHIIIHH", 0x8664, 1, 0, 0, 0, 240, 0x2022)
    opt = struct.pack(
        "<HBBIIIIIQIIHHHHHHIIIIHHQQQQII",
        0x20B, 14, 0,
        0, raw_size, 0, 0, shift,
        IMAGE_BASE, SECTION_ALIGN, FILE_ALIGN,
        6, 0, 0, 0, 6, 0,
        0, image_size, FILE_ALIGN, 0,
        2, 0x8140,
        0x100000, 0x1000, 0x100000, 0x1000,
        0, 16)
    dirs = bytearray(16 * 8)
    struct.pack_into("<II", dirs, 0, shift, size)       # export directory
    section = struct.pack(
        "<8sIIIIIIHHI", b".edata", size, shift, raw_size, FILE_ALIGN, 0, 0, 0, 0, 0x40000040)

    headers = bytes(dos) + b"PE\0\0" + coff + opt + bytes(dirs) + section
    if len(headers) > FILE_ALIGN:               # pragma: no cover - fixed-size headers
        raise AssertionError("PE headers outgrew their reserved space")
    return headers.ljust(FILE_ALIGN, b"\0") + bytes(blob).ljust(raw_size, b"\0")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--qt-dll", required=True, help="Qt6Core.dll whose icuuc.dll imports to satisfy")
    ap.add_argument("--out", required=True, help="where to write the forwarder DLL")
    ap.add_argument("--dll", default="icuuc.dll", help="the missing DLL name (default icuuc.dll)")
    ap.add_argument("--target", default="icu", help="the module Wine provides (default icu)")
    args = ap.parse_args(argv)

    with open(args.qt_dll, "rb") as fh:
        names = _Pe(fh.read()).imports(args.dll)
    if not names:
        print(f"{args.qt_dll} imports nothing by name from {args.dll}: no shim needed",
              file=sys.stderr)
        return 3
    blob = build_forwarder_dll(args.dll, args.target, names)
    with open(args.out, "wb") as fh:
        fh.write(blob)
    print(f"{args.out}: {args.dll} -> {args.target}.dll, {len(set(names))} forwarded names, "
          f"{len(blob)} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
