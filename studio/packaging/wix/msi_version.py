#!/usr/bin/env python3
"""Map the Studio's SemVer ``__version__`` to the numeric ProductVersion an MSI needs.

    msi_version.py 0.3.0-beta.1      ->  0.3.1
    msi_version.py 0.3.0-beta.2      ->  0.3.2
    msi_version.py 0.3.0             ->  0.3.99
    msi_version.py 0.3.1-beta.1      ->  0.3.101

WHY A MAPPING AT ALL. Windows Installer's ProductVersion is ``major.minor.build`` with
numbers only (major and minor up to 255, build up to 65535). It cannot hold
``-beta.1``. A fourth field would be legal but useless: MajorUpgrade compares only the
first three, so two betas of the same base would look like the SAME version and the
second would not replace the first (Package.wxs sets AllowSameVersionUpgrades="no").

So N goes into the third field: ``build = PATCH * 100 + N`` for ``-beta.N`` and
``PATCH * 100 + 99`` for the final release. Every beta sorts above the one before it
and below its own final, and the final sorts below the first beta of the next PATCH.
The cost is a cap of 98 betas per PATCH, and PATCH itself is capped at 654.

The installer FILE NAME keeps the SemVer string (hugmesh-studio-0.3.0-beta.1-x64.msi);
only the ProductVersion inside the MSI uses this number. The release workflow and
build-msi-wine.sh both call this script, so the two cannot drift apart.
"""
from __future__ import annotations

import re
import sys

_SEMVER = re.compile(r"(\d+)\.(\d+)\.(\d+)(?:-beta\.([1-9]\d*))?")
FINAL_SLOT = 99


def msi_version(version: str) -> str:
    """Return the MSI ProductVersion for a Studio version, or raise ValueError."""
    match = _SEMVER.fullmatch(version.strip())
    if not match:
        raise ValueError(
            f"{version!r} is not MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-beta.N; "
            "the MSI mapping knows no other pre-release form")
    major, minor, patch = (int(match.group(i)) for i in (1, 2, 3))
    beta = match.group(4)
    slot = FINAL_SLOT if beta is None else int(beta)
    if beta is not None and slot >= FINAL_SLOT:
        raise ValueError(f"{version!r}: beta.N must be 1..{FINAL_SLOT - 1} "
                         f"(N = {FINAL_SLOT} is the final release's slot)")
    if major > 255 or minor > 255:
        raise ValueError(f"{version!r}: an MSI major and minor must each be at most 255")
    build = patch * 100 + slot
    if build > 65535:
        raise ValueError(f"{version!r}: PATCH * 100 + N = {build} is over the MSI limit 65535")
    return f"{major}.{minor}.{build}"


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: msi_version.py <studio version>", file=sys.stderr)
        return 2
    try:
        print(msi_version(argv[0]))
    except ValueError as exc:
        print(f"msi_version.py: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
