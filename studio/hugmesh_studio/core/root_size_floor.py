"""Pre-build floor for an explicit ``--img-size`` override (Qt-free).

Every builder sizes its compact ext4 root from a MEASURED payload and aborts a
too-small root in the .img pre-flight ("Payload NNNN MiB exceeds the ... root
partition"; build-rpi5:4725 even suggests the corrected flag) — but only AFTER
the multi-hour emerge. This module mirrors each builder's own derived default
for the config's axes so the Studio can refuse a guaranteed-doomed override
up front. The builder tables are the single source of the numbers:

  x86 client desktops   build-x86:1600-1608   capable 51200 / full 24576 / thin 16384
  x86 cluster nodes     build-x86:1734-1736   GPU roles 20480 / other 14336
  rpi5                  build-rpi5:203        9216
  jetson                build-jetson:519-533  full 20480 / edge_ai+desktop 16384
                                              / gpu-host 14336
  frite / orangepi5 / orangepi4-lts           3072 (installer persistent root)
  orangepi zero2/zero2w/zero3 / 3-lts         2048 (lean appliance)

The floor is the builder DEFAULT (measured payload + headroom), deliberately:
an explicit size below it either overflows mid-emerge or trips the builder's
pre-flight, so the Studio rejecting it early loses nothing. It is a LOWER
bound, not a fit guarantee — a config whose builder default is higher than the
axes modelled here (e.g. a role whose weight defaults up) still relies on the
builder's du-based pre-flight as the runtime authority. A deliberately slimmed
image (heavy packages_drop) can still pass ``--img-size`` verbatim through the
Extra-builder-flags field, which this floor does not police.
"""
from __future__ import annotations

from .config import image_class

# x86 roles the builder gives the Mesa/Vulkan node bump (build-x86:1734: ${GPU}).
_X86_GPU_NODE_ROLES = ("be+gpu", "omnibus", "edge_ai", "edge-ai")

_STATIC_FLOORS = {
    "rpi5": 9216,
    "frite": 3072,
    "orangepi5": 3072,
    "orangepi4-lts": 3072,
    "orangepizero2": 2048,
    "orangepizero2w": 2048,
    "orangepizero3": 2048,
    "orangepi3-lts": 2048,
}

_JETSON_FLOORS = {"full": 20480, "edge_ai": 16384, "edge-ai": 16384,
                  "desktop": 16384, "gpu-host": 14336}


def min_root_mib(platform: str, mode: str, role: str,
                 desktop: str = "", capable: bool = False) -> int:
    """The builder-default compact-root size (MiB) for these axes — the smallest
    explicit --img-size the Studio should accept. 0 = no floor known (unknown
    platform), never a claim that 0 MiB fits."""
    p = platform or "x86"
    if p == "x86":
        if image_class(mode, role) == "desktop":
            if capable:
                return 51200
            if desktop == "full":
                return 24576
            return 16384
        return 20480 if role in _X86_GPU_NODE_ROLES else 14336
    if p == "jetson":
        return _JETSON_FLOORS.get(role, 14336)
    return _STATIC_FLOORS.get(p, 0)


def img_size_error(platform: str, mode: str, role: str, img_size: int,
                   desktop: str = "", capable: bool = False) -> str:
    """'' if img_size is acceptable (0 = role default is always fine), else a
    one-line refusal naming the floor and where the number comes from."""
    if not img_size:
        return ""
    floor = min_root_mib(platform, mode, role, desktop=desktop, capable=capable)
    if img_size >= floor:
        return ""
    return (f"Root image size {img_size} MiB is below the {floor} MiB the "
            f"{platform or 'x86'} builder derives for this {role} payload "
            "(measured packages + headroom) — the build would abort in the .img "
            "pre-flight after the full emerge. Leave 0 for the role default, or "
            f"choose at least {floor} MiB.")
