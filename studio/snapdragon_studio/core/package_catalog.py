"""Package catalog — parse the builders' portage package lists into a 3-level tree and
derive the tri-tier per-image package model (design 2.8).

The generator's ``specs-<platform>/portage/packages*.list`` files are the single source of
truth for what a builder emerges: one atom per line, ``#`` comments, and uniform
``# ── Section ──`` headers. This module parses them LIVE from a generator checkout (so the
Studio can never drift from the tree) and layers two DATA maps that mirror builder logic:

* :data:`LIST_GATES` — which lists a given :class:`~.config.ImageConfig` pulls in
  (role / desktop / GPU / media / flavor gates), and
* :data:`ADHOC_ADDS` — option → extra atoms the builder appends outside the list files
  (yubikey login, home encryption, calamares, egress VPN, tor, snort, nvidia-container).

From those it computes, for a config, the builder's DEFAULT install set and splits it into
the dialog's three tiers, always RELATIVE to that builder-derived default (the builder stays
the source of truth; the UI only ever expresses +add / -drop deltas against it):

* **tier 1 — essential** (checked, locked): the base list, the k8s payload on node images,
  the option-required adhoc adds, and the SNAP_ROLE_BINS mandatory-binary floor
  (build-x86:3454-3462). Never removable.
* **tier 2 — default-removable** (checked): the rest of the default set; unchecking one
  compiles to ``packages_drop`` (honestly labelled "may return as a dependency").
* **tier 3 — available extras** (unchecked): atoms from lists NOT gated in for this config;
  checking one compiles to ``packages_add``.

Qt-free: imported by the headless catalog emitter and the pure-core test suite.
"""
from __future__ import annotations

import os
from collections.abc import Callable
from dataclasses import dataclass

from .config import ImageConfig, image_class

# platform id -> specs subdir (note orangepizero2 -> specs-orangepi-zero2).
SPECS_SUBDIR = {
    "x86": "specs-x86", "rpi5": "specs-rpi5", "jetson": "specs-jetson",
    "frite": "specs-frite", "orangepi5": "specs-orangepi5",
    "orangepizero2": "specs-orangepi-zero2",
}
PLATFORMS = tuple(SPECS_SUBDIR)


# ── list-file parsing ───────────────────────────────────────────────────────────────
def _section_title(comment_line: str) -> str | None:
    """A ``# ── Title ──`` section header -> "Title"; a plain ``# comment`` -> None (so
    only real section rules start a new section; ordinary comments are ignored)."""
    s = comment_line.lstrip("#").strip()
    if "─" not in s:              # the box-drawing rule char '─' marks a header
        return None
    return s.strip("─").strip("- ").strip()


def parse_list_file(path: str) -> list[dict]:
    """Parse one ``packages*.list`` into ``[{title, atoms}]`` in file order. Atoms before
    the first section header land in a leading untitled section; sections with no atoms are
    dropped."""
    sections: list[dict] = []
    cur = {"title": "", "atoms": []}
    for raw in _read_lines(path):
        s = raw.strip()
        if not s:
            continue
        if s.startswith("#"):
            t = _section_title(s)
            if t is not None:
                if cur["atoms"]:
                    sections.append(cur)
                cur = {"title": t, "atoms": []}
            continue
        cur["atoms"].append(s)
    if cur["atoms"]:
        sections.append(cur)
    return sections


def _read_lines(path: str) -> list[str]:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.readlines()
    except OSError:
        return []


def _list_path(generator_dir: str, platform: str, list_id: str) -> str:
    sub = SPECS_SUBDIR.get(platform or "x86", "specs-x86")
    return os.path.join(generator_dir, sub, "portage", f"{list_id}.list")


def list_sections(generator_dir: str, platform: str, list_id: str) -> list[dict]:
    return parse_list_file(_list_path(generator_dir, platform, list_id))


def list_atoms(generator_dir: str, platform: str, list_id: str) -> list[str]:
    return [a for sec in list_sections(generator_dir, platform, list_id) for a in sec["atoms"]]


# ── feature predicates (mirror the builders' role/flag presets) ──────────────────────
def _is_desktop(cfg: ImageConfig) -> bool:
    return image_class(cfg.mode, cfg.role) == "desktop"


def _is_gpu(cfg: ImageConfig) -> bool:
    # x86: pki/be/fe -> GPU off; be+gpu/omnibus/edge_ai and every client desktop -> GPU on;
    # an explicit --gpu-driver forces it on for any role (build-x86:1131).
    if cfg.role in ("be+gpu", "omnibus", "edge_ai", "edge-ai"):
        return True
    if _is_desktop(cfg):
        return True
    return cfg.gpu_driver not in ("", "auto", "none")


def _media_on(cfg: ImageConfig) -> bool:
    return _is_desktop(cfg) and cfg.media_data not in (False, "off", "false")


def _opt_services(cfg: ImageConfig) -> set[str]:
    svc = set(cfg.optional_services or [])
    for d in cfg.domains:
        svc |= set(getattr(d, "optional_services", []) or [])
    return svc


def _flavor_live(cfg: ImageConfig) -> bool:
    return cfg.flavor in ("live", "both")


@dataclass(frozen=True)
class ListSpec:
    list_id: str
    gate: str
    predicate: Callable[[ImageConfig], bool]


# Which lists each platform concatenates, and the gate id + predicate that pulls each in.
# "base" is always-on. Predicates are best-effort mirrors of the builders' role/flag logic;
# the builder derivation stays authoritative — these only drive the dialog's default checks.
_ALWAYS: Callable[[ImageConfig], bool] = lambda cfg: True
_NODE: Callable[[ImageConfig], bool] = lambda cfg: image_class(cfg.mode, cfg.role) == "node"

PLATFORM_LISTS: dict[str, tuple[ListSpec, ...]] = {
    "x86": (
        ListSpec("packages", "base", _ALWAYS),
        ListSpec("packages-gpu", "gpu", _is_gpu),
        ListSpec("packages-gpu-nvidia", "gpu-nvidia", lambda cfg: cfg.gpu_driver == "nvidia"),
        ListSpec("packages-gpu-nvidia-cuda", "gpu-nvidia-cuda",
                 lambda cfg: cfg.gpu_driver == "nvidia" and bool(cfg.nvidia_cuda)),
        ListSpec("packages-gpu-amd-pro", "gpu-amd-pro", lambda cfg: cfg.gpu_driver == "amd-pro"),
        ListSpec("packages-gpu-intel-pro", "gpu-intel-pro",
                 lambda cfg: cfg.gpu_driver == "intel-pro"),
        ListSpec("packages-desktop", "desktop", _is_desktop),
        ListSpec("packages-desktop-full", "desktop-full",
                 lambda cfg: _is_desktop(cfg) and cfg.desktop == "full"),
        ListSpec("packages-desktop-capable", "desktop-capable",
                 lambda cfg: _is_desktop(cfg) and bool(cfg.capable)),
        ListSpec("packages-media-data", "media-data", _media_on),
        ListSpec("packages-steam-native", "steam-native",
                 lambda cfg: _is_desktop(cfg) and bool(getattr(cfg, "steam_native", False))),
    ),
    "rpi5": (
        ListSpec("packages", "base", _ALWAYS),
        ListSpec("packages-desktop", "desktop", _is_desktop),
        ListSpec("packages-k8s", "k8s", _NODE),
    ),
    "jetson": (
        ListSpec("packages", "base", _ALWAYS),
        ListSpec("packages-desktop", "desktop", _is_desktop),
        ListSpec("packages-edge-ai", "edge-ai",
                 lambda cfg: cfg.role in ("edge_ai", "edge-ai", "full", "gpu-host")),
        ListSpec("packages-k8s", "k8s", _NODE),
    ),
    "frite": (
        ListSpec("packages", "base", _ALWAYS),
        ListSpec("packages-light-desktop", "desktop",
                 lambda cfg: _is_desktop(cfg) and cfg.desktop != "none"),
        ListSpec("packages-live", "live", _flavor_live),
    ),
    "orangepi5": (
        ListSpec("packages", "base", _ALWAYS),
        ListSpec("packages-desktop", "desktop", _is_desktop),
        ListSpec("packages-live", "live", _flavor_live),
    ),
    "orangepizero2": (
        ListSpec("packages", "base", _ALWAYS),
        ListSpec("packages-live", "live", _flavor_live),
    ),
}


# ── ADHOC adds (atoms the builder appends outside the list files) ────────────────────
@dataclass(frozen=True)
class AdhocAdd:
    option: str
    label: str
    atoms: tuple[str, ...]
    predicate: Callable[[ImageConfig], bool]


def _egress(cfg: ImageConfig) -> str:
    return str(getattr(cfg, "egress_vpn", "") or "")


# x86-derived (build-x86:3291-3317 + 2376); ARM builders bake a leaner set, but the adds are
# gated by the same config options so the map is shared and platform-support-filtered above.
ADHOC_ADDS: tuple[AdhocAdd, ...] = (
    AdhocAdd("yubikey-login", "YubiKey login (pam-u2f)", ("sys-auth/pam-u2f",),
             lambda cfg: getattr(cfg, "unlock_yubikey", "") == "login"),
    AdhocAdd("home-encrypted", "Encrypted home (eCryptfs)",
             ("sys-fs/ecryptfs-utils", "sys-apps/keyutils"),
             lambda cfg: bool(getattr(cfg, "home_encrypted", False))),
    AdhocAdd("calamares", "Graphical installer (Calamares)", ("app-admin/calamares",),
             lambda cfg: getattr(cfg, "installer_ui", "") in ("calamares", "all")),
    AdhocAdd("egress-openvpn", "Egress VPN (OpenVPN)",
             ("net-vpn/networkmanager-openvpn", "net-vpn/openvpn"),
             lambda cfg: _egress(cfg).endswith(".ovpn")),
    AdhocAdd("egress-wireguard", "Egress VPN (WireGuard)", ("net-vpn/wireguard-tools",),
             lambda cfg: bool(_egress(cfg)) and not _egress(cfg).endswith(".ovpn")),
    AdhocAdd("tor", "Tor onion service (net-vpn/tor)", ("net-vpn/tor",),
             lambda cfg: "tor" in _opt_services(cfg)),
    AdhocAdd("snort", "Snort IDS", ("net-analyzer/snort",),
             lambda cfg: bool(getattr(cfg, "snort", False))),
    AdhocAdd("nvidia-container-toolkit", "NVIDIA container runtime",
             ("app-containers/nvidia-container-toolkit",),
             lambda cfg: cfg.gpu_driver == "nvidia"
             and cfg.role in ("edge_ai", "edge-ai", "be+gpu", "omnibus")),
)


def adhoc_atoms(cfg: ImageConfig) -> list[str]:
    out: list[str] = []
    for a in ADHOC_ADDS:
        if a.predicate(cfg):
            out.extend(a.atoms)
    return out


# ── SNAP_ROLE_BINS mandatory-payload floor (build-x86:3368/3454-3462) ────────────────
MANDATORY_BASE_BINS = ("grub-install", "dracut", "parted", "jq", "nmcli")
MANDATORY_CLIENT_BINS = ("Xorg", "lightdm", "openbox")     # ROLE_CLIENT SNAP_ROLE_BINS
MANDATORY_NODE_BINS = ("kubelet", "kubeadm", "containerd")  # node SNAP_ROLE_BINS
BIN_ATOM = {
    "grub-install": "sys-boot/grub", "dracut": "sys-kernel/dracut",
    "parted": "sys-block/parted", "jq": "app-misc/jq", "nmcli": "net-misc/networkmanager",
    "Xorg": "x11-base/xorg-server", "lightdm": "x11-misc/lightdm", "openbox": "x11-wm/openbox",
    "kubelet": "sys-cluster/kubelet", "kubeadm": "sys-cluster/kubeadm",
    "containerd": "app-containers/containerd",
}


def mandatory_bins(cfg: ImageConfig) -> list[str]:
    """The binaries the x86 stage4 payload assert requires (base + role-class). The floor
    is an x86 concept; ARM builders have no such assert, so its atoms only ever join the
    essential floor when they are actually in that platform's default set (below)."""
    bins = list(MANDATORY_BASE_BINS)
    bins += MANDATORY_CLIENT_BINS if _is_desktop(cfg) else MANDATORY_NODE_BINS
    return bins


def mandatory_atoms(cfg: ImageConfig) -> list[str]:
    return [BIN_ATOM[b] for b in mandatory_bins(cfg) if b in BIN_ATOM]


# ── the derived model ────────────────────────────────────────────────────────────────
def gated_lists(cfg: ImageConfig) -> list[str]:
    """The list_ids the builder concatenates for this config, in platform order."""
    return [spec.list_id for spec in PLATFORM_LISTS.get(cfg.platform or "x86", ())
            if spec.predicate(cfg)]


def default_set(generator_dir: str, cfg: ImageConfig) -> set[str]:
    """Every atom the builder would emerge for this config: the gated-in lists + the
    option-gated adhoc adds. This is the checked (installed) set the tiers split."""
    atoms: set[str] = set()
    for list_id in gated_lists(cfg):
        atoms.update(list_atoms(generator_dir, cfg.platform, list_id))
    atoms.update(adhoc_atoms(cfg))
    return atoms


def essential_floor(generator_dir: str, cfg: ImageConfig) -> set[str]:
    """The hard-locked tier-1 set: base list + k8s payload on nodes + option-required adhoc
    adds + the installed SNAP_ROLE_BINS atoms. Intersected with the default set so it never
    claims an atom the builder would not install (essential_floor ⊆ default_set)."""
    default = default_set(generator_dir, cfg)
    floor: set[str] = set(list_atoms(generator_dir, cfg.platform, "packages"))  # base always
    if image_class(cfg.mode, cfg.role) == "node":
        floor.update(list_atoms(generator_dir, cfg.platform, "packages-k8s"))   # [] if absent
    floor.update(a for a in mandatory_atoms(cfg) if a in default)
    floor.update(adhoc_atoms(cfg))          # an enabled option's atoms are required
    return floor & default


def all_platform_atoms(generator_dir: str, platform: str) -> set[str]:
    """Every atom in every list file for a platform (the full catalog superset)."""
    atoms: set[str] = set()
    for spec in PLATFORM_LISTS.get(platform or "x86", ()):
        atoms.update(list_atoms(generator_dir, platform, spec.list_id))
    return atoms


def tiers(generator_dir: str, cfg: ImageConfig) -> dict[str, list[str]]:
    """Split the platform catalog into the dialog's three tiers for this config:
    essential (locked), removable (default-on, uncheck -> drop), available (off, check ->
    add). Sorted for stable rendering + diffing."""
    default = default_set(generator_dir, cfg)
    floor = essential_floor(generator_dir, cfg)
    available = all_platform_atoms(generator_dir, cfg.platform) - default
    return {
        "essential": sorted(floor),
        "removable": sorted(default - floor),
        "available": sorted(available),
    }


# ── checked-in catalog (for the web; drift-checked) ──────────────────────────────────
def catalog_for_platform(generator_dir: str, platform: str) -> dict:
    """``{list_id: {gate, sections: [{title, atoms}]}}`` — the raw parsed tree the web
    consumes (the tier predicates are ported into the BFF)."""
    out: dict[str, dict] = {}
    for spec in PLATFORM_LISTS.get(platform or "x86", ()):
        out[spec.list_id] = {
            "gate": spec.gate,
            "sections": list_sections(generator_dir, platform, spec.list_id),
        }
    return out


def build_catalog(generator_dir: str) -> dict:
    """The full checked-in ``packages-catalog.json`` payload: every platform's list tree +
    the adhoc-adds map. Emitted by scripts/emit-package-catalog.py; the Studio parses lists
    live instead, so only the web copy can drift (a CI test regenerates and diffs)."""
    return {
        "platforms": {p: catalog_for_platform(generator_dir, p) for p in PLATFORMS},
        "adhoc_adds": {a.option: {"label": a.label, "atoms": list(a.atoms)}
                       for a in ADHOC_ADDS},
    }
