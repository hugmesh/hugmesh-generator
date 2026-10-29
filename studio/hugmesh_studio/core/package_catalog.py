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

from .config import (
    PLATFORM_FIELD_SUPPORT, ImageConfig, ROLE_CHOICES, clear_role_class_fields,
    image_class, strip_platform_unsupported,
)

# platform id -> specs subdir (note orangepizero2 -> specs-orangepi-zero2).
SPECS_SUBDIR = {
    "x86": "specs-x86", "rpi5": "specs-rpi5", "jetson": "specs-jetson",
    "frite": "specs-frite", "orangepi5": "specs-orangepi5",
    "orangepizero2": "specs-orangepi-zero2",
    "orangepizero2w": "specs-orangepi-zero2w",
    "orangepizero3": "specs-orangepi-zero3",
    "orangepi3-lts": "specs-orangepi3-lts",
    "orangepi4-lts": "specs-orangepi4-lts",
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


# Lists a platform READS FROM ANOTHER platform's specs tree instead of carrying a
# copy: the Orange Pi node roles install the Raspberry Pi k8s node set
# (build-orangepi5-stage4.sh / build-orangepi4-lts-stage4.sh read
# specs-rpi5/portage/packages-k8s.list directly).
_SHARED_LIST_SOURCE = {
    ("orangepi5", "packages-k8s"): "rpi5",
    ("orangepi4-lts", "packages-k8s"): "rpi5",
    # ...and the node host packages the Pi carries in its own base list
    # (scripts/_node-role-lib.sh NODE_ROLE_HOST_PACKAGES_LIST).
    ("orangepi5", "packages-node-host"): "rpi5",
    ("orangepi4-lts", "packages-node-host"): "rpi5",
}


def _list_path(generator_dir: str, platform: str, list_id: str) -> str:
    platform = _SHARED_LIST_SOURCE.get((platform or "x86", list_id), platform)
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
    if cfg.role in ("backend-gpu", "omnibus", "edge-ai", "be+gpu", "edge_ai", "gpu-host"):
        return True
    if _is_desktop(cfg):
        return True
    return cfg.gpu_driver not in ("", "auto", "none")


def _media_on(cfg: ImageConfig) -> bool:
    return _is_desktop(cfg) and cfg.media_data not in (False, "off", "false")


def _tor_selected(cfg: ImageConfig) -> bool:
    """Does THIS image's builder bake net-vpn/tor? The two NODE-level channels the
    builders actually read, and nothing else (#580):

    * the ``tor`` slug in the image's own ``--optional-services`` allow-list —
      ``_opt_selected tor`` gates the package on x86 (build-x86-host-stage4.sh:5267)
      and rpi5 (build-rpi5-stage4.sh:2751) alike;
    * the x86 dedicated ``--with-tor`` flag (``tor_onion_service``), which the x86
      builder folds into OPTIONAL_SERVICES (:1318-1331) — but only on a NODE: for a
      CLIENT role it warns and resets WANT_TOR, so a desktop image never bakes it that
      way. The field is TRI-STATE (``True``/``"on"``/``"off"``/``""``), so it is read
      through ``ImageConfig._tri`` — ``bool("off")`` is True and would claim a
      ``--no-tor`` image carries the daemon.

    A DOMAIN row's ``optional_services`` is deliberately NOT read. ``from_dict`` keeps
    a ``tor`` on a domain row and the mesh manifest carries it, but no builder reads a
    domain's list for tor (``worklist._apply_infra_services`` reads only the entry's
    per-node set and ``--with-tor``), so counting it here showed ``net-vpn/tor`` in the
    package preview of an image that bakes nothing. Tor is node-scoped (#494 #C) until
    #582 rules on a per-domain onion; the #580 addendum asked for exactly this cut.

    Neither channel counts on a DESKTOP-class image: both builders gate the package
    and the runlevel links on ``_tor_node_selected`` (``! ROLE_CLIENT && _opt_selected
    tor`` — #583), so a ``tor`` slug on a client role bakes nothing either."""
    if _is_desktop(cfg):
        return False
    if "tor" in (cfg.optional_services or []):
        return True
    plat = cfg.platform or "x86"
    return (ImageConfig._tri(cfg.tor_onion_service) == "on"
            and plat in PLATFORM_FIELD_SUPPORT.get("tor_onion_service", ("x86",)))


def _flavor_live(cfg: ImageConfig) -> bool:
    return cfg.flavor in ("live", "both")


@dataclass(frozen=True)
class ListSpec:
    list_id: str
    gate: str
    predicate: Callable[[ImageConfig], bool]
    # addable=False: the list's atoms need builder machinery beyond a bare emerge
    # (overlay sync, multilib ABI, licence acceptance), so the raw packages_add
    # channel can NEVER install them — the dialog must not offer them as tier-3
    # extras. They still tier normally (essential/removable) when gated in.
    addable: bool = True


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
        # Native Steam (games-util/steam-launcher) lives in the steam-overlay; the
        # builder gates it on native delivery + client + media-data + gaming desktop
        # (build-x86:1465) and only THAT path syncs the overlay, flips ABI_X86
        # multilib and accepts the Valve licence. A checked tier-3 extra compiles to
        # --packages-add, which has none of that machinery — the atom is unsatisfiable
        # there by construction (proven: standalone-unaffiliated 20260814, "there are
        # no ebuilds to satisfy"). addable=False keeps it out of the dialog; the
        # Steam-delivery knob on the role page is the real control.
        ListSpec("packages-steam-native", "steam-native",
                 lambda cfg: False, addable=False),
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
                 lambda cfg: cfg.role in ("edge-ai", "omnibus", "backend-gpu",
                                          "edge_ai", "full", "gpu-host")),
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
        # cluster NODE roles (EXPERIMENTAL): the Raspberry Pi k8s node set
        ListSpec("packages-k8s", "k8s", _NODE),
        ListSpec("packages-node-host", "node-host", _NODE),
    ),
    "orangepizero2": (
        ListSpec("packages", "base", _ALWAYS),
        ListSpec("packages-live", "live", _flavor_live),
    ),
    "orangepizero2w": (
        ListSpec("packages", "base", _ALWAYS),
        ListSpec("packages-live", "live", _flavor_live),
    ),
    "orangepizero3": (
        ListSpec("packages", "base", _ALWAYS),
        ListSpec("packages-live", "live", _flavor_live),
    ),
    "orangepi3-lts": (
        ListSpec("packages", "base", _ALWAYS),
        ListSpec("packages-live", "live", _flavor_live),
    ),
    # UNLIKE the appliance Orange Pi platforms, this one also concatenates
    # packages-desktop.list for its light desktop (role id "orangepi4-lts", a desktop
    # role) — but not for its frontend NODE role, exactly like orangepi5 above.
    "orangepi4-lts": (
        ListSpec("packages", "base", _ALWAYS),
        ListSpec("packages-desktop", "desktop", _is_desktop),
        ListSpec("packages-live", "live", _flavor_live),
        # the frontend cluster NODE role (EXPERIMENTAL): the Raspberry Pi k8s node set
        ListSpec("packages-k8s", "k8s", _NODE),
        ListSpec("packages-node-host", "node-host", _NODE),
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
             _tor_selected),
    AdhocAdd("snort", "Snort IDS", ("net-analyzer/snort",),
             lambda cfg: bool(getattr(cfg, "snort", False))),
    AdhocAdd("nvidia-container-toolkit", "NVIDIA container runtime",
             ("app-containers/nvidia-container-toolkit",),
             lambda cfg: cfg.gpu_driver == "nvidia"
             and cfg.role in ("edge-ai", "backend-gpu", "omnibus", "edge_ai", "be+gpu")),
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


def addable_platform_atoms(generator_dir: str, platform: str) -> set[str]:
    """The tier-3 candidate pool: atoms from addable lists only. Non-addable lists
    (see ListSpec.addable) hold atoms the raw packages_add channel cannot install."""
    atoms: set[str] = set()
    for spec in PLATFORM_LISTS.get(platform or "x86", ()):
        if spec.addable:
            atoms.update(list_atoms(generator_dir, platform, spec.list_id))
    return atoms


def tiers(generator_dir: str, cfg: ImageConfig) -> dict[str, list[str]]:
    """Split the platform catalog into the dialog's three tiers for this config:
    essential (locked), removable (default-on, uncheck -> drop), available (off, check ->
    add). Sorted for stable rendering + diffing."""
    default = default_set(generator_dir, cfg)
    floor = essential_floor(generator_dir, cfg)
    available = addable_platform_atoms(generator_dir, cfg.platform) - default
    return {
        "essential": sorted(floor),
        "removable": sorted(default - floor),
        "available": sorted(available),
    }


# ── per-cell role tiers (the web catalog's default-options baseline) ─────────────────
ROLES_DOC = (
    "Per-platform role->tier baseline: tiers() on a DEFAULT-OPTIONS ImageConfig for every "
    "valid ROLE_CHOICES role x platform cell — NO adhoc options enabled; board/flavor/"
    "desktop-weight/GPU-driver left at builder defaults. essential is locked (base list + "
    "node k8s payload + installed SNAP_ROLE_BINS); essential+removable = the builder's "
    "default install set; available = the rest of the platform catalog. The UI layers "
    "option atoms client-side from adhoc_adds: an enabled option's atoms render LOCKED "
    "(as essential_floor treats them) but MUST still be emitted in packages_add unless "
    "the role tier already installs them — a worklist entry has no per-option wire "
    "channel, so packages_add is the only channel that installs an option's atoms."
)


def default_cell_config(mode: str, role: str, platform: str) -> ImageConfig:
    """The DEFAULT-OPTIONS config for one role x platform cell — the same stamping +
    gating order as WorklistConfig._materialize_one (structural axes onto a default base,
    then the platform / role-class strips), with every ADHOC_ADDS trigger forced OFF
    (snort and installer_ui are default-ON in the dataclass) so the baseline default set
    carries no option atoms: the web UI layers those client-side from adhoc_adds. Fails
    loud if a future default-ON option would leak atoms into the baseline.

    KNOWN INCONSISTENCY: WorklistConfig._materialize_one additionally forces tailscale=True and
    sso=True for MESH mode after the strips; that forcing is deliberately NOT mirrored
    here because no PLATFORM_LISTS gate and no ADHOC_ADDS predicate reads cfg.tailscale
    or cfg.sso today, so tiers() output is identical either way. If a future gate or
    adhoc predicate ever keys on either field, mirror the forcing here (or the emitted
    mesh baselines will silently diverge from what the Studio really materializes)."""
    cfg = ImageConfig(mode=mode, role=role, platform=platform)
    strip_platform_unsupported(cfg)
    clear_role_class_fields(cfg)
    cfg.snort = False        # dataclass default True — an adhoc option, not baseline
    cfg.installer_ui = ""    # dataclass default "all" enables the calamares adhoc add
    leaked = adhoc_atoms(cfg)
    if leaked:
        raise ValueError(f"default cell {role} x {platform}: adhoc atoms leaked into the "
                         f"baseline ({leaked}) — force the new default-ON option off in "
                         "default_cell_config")
    return cfg


def role_cells() -> dict[tuple[str, str], list[str]]:
    """Every valid ``(platform, role)`` cell -> the Studio modes offering it, straight
    from ROLE_CHOICES (the same grammar emit-image-catalog.py serves the admin-ui) —
    cells are enumerated, never invented. A cell shared across modes (frite standalone+
    cloud, rpi5-desktop cloud+mesh) keeps every mode so roles_tiers can assert mode
    never changes the tiering."""
    cells: dict[tuple[str, str], list[str]] = {}
    for mode, choices in ROLE_CHOICES.items():
        for role, platforms, _label in choices:
            for platform in platforms:
                cells.setdefault((platform, role), []).append(mode)
    return cells


def roles_tiers(generator_dir: str) -> dict[str, dict[str, dict[str, list[str]]]]:
    """``{platform: {role: {essential, removable, available}}}`` for every valid cell.
    List gating is role/flag-keyed, never mode-keyed, so a role offered in several modes
    must tier identically — asserted (fail loud), which is what makes the plain role
    token a sound key."""
    out: dict[str, dict[str, dict[str, list[str]]]] = {}
    for (platform, role), modes in role_cells().items():
        per_mode = [tiers(generator_dir, default_cell_config(m, role, platform))
                    for m in modes]
        if any(t != per_mode[0] for t in per_mode[1:]):
            raise ValueError(f"{role} x {platform}: tiers differ across modes {modes} — "
                             "the role-token key is no longer mode-free")
        out.setdefault(platform, {})[role] = per_mode[0]
    return out


def validate_roles_tiers(generator_dir: str, roles: dict) -> None:
    """Fail-loud invariant check of an EMITTED roles map (run by the exporter before it
    writes, and by the CI drift test on the committed copy): exact cell coverage, tiers
    sorted + duplicate-free + pairwise disjoint, essential EQUAL to the freshly derived
    essential_floor (not merely a subset of the default set — a boundary shift between
    essential and removable in either direction fails loud, so an out-of-band consumer
    revalidating a served copy cannot be handed a weakened or widened lock floor),
    essential+removable == the default set, and the three tiers together == the full
    platform universe."""
    want = role_cells()
    got = {(p, r) for p, rs in roles.items() for r in rs}
    if got != set(want):
        raise ValueError(f"roles map cells drifted: missing={sorted(set(want) - got)} "
                         f"extra={sorted(got - set(want))}")
    for (platform, role), modes in want.items():
        t = roles[platform][role]
        if set(t) != {"essential", "removable", "available"}:
            raise ValueError(f"{role} x {platform}: bad tier keys {sorted(t)}")
        for name, lst in t.items():
            if lst != sorted(set(lst)):
                raise ValueError(f"{role} x {platform}.{name}: not sorted/duplicate-free")
        e, r, a = set(t["essential"]), set(t["removable"]), set(t["available"])
        if e & r or e & a or r & a:
            raise ValueError(f"{role} x {platform}: tiers overlap")
        cfg = default_cell_config(modes[0], role, platform)
        default = default_set(generator_dir, cfg)
        if not e <= default:
            raise ValueError(f"{role} x {platform}: essential not a subset of the "
                             f"default set: {sorted(e - default)}")
        floor = essential_floor(generator_dir, cfg)
        if e != floor:
            raise ValueError(f"{role} x {platform}: essential != essential_floor — the "
                             f"locked/removable boundary drifted from the derivation "
                             f"(demoted={sorted(floor - e)} promoted={sorted(e - floor)})")
        if e | r != default:
            raise ValueError(f"{role} x {platform}: essential+removable != default set")
        if e | r | a != addable_platform_atoms(generator_dir, platform) | default:
            raise ValueError(f"{role} x {platform}: tiers do not cover the platform "
                             "universe")


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
    the adhoc-adds map + the per-cell role->tier baseline (``roles``/``roles_doc``, an
    ADDITIVE extension — the platforms/adhoc_adds subtrees are byte-compatible with the
    pre-roles schema). Emitted by scripts/emit-package-catalog.py; the Studio parses lists
    live instead, so only the web copy can drift (a CI test regenerates and diffs)."""
    return {
        "platforms": {p: catalog_for_platform(generator_dir, p) for p in PLATFORMS},
        "adhoc_adds": {a.option: {"label": a.label, "atoms": list(a.atoms)}
                       for a in ADHOC_ADDS},
        "roles": roles_tiers(generator_dir),
        "roles_doc": ROLES_DOC,
    }
