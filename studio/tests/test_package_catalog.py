"""Package catalog (design 2.8) — parse the real spec trees, verify the tri-tier model
(essential floor superset of the SNAP_ROLE_BINS payload, tiers disjoint), and drift-check
the checked-in packages-catalog.json / image-catalog.json against a fresh emit."""
import importlib.util
import json
import os

import pytest

from snapdragon_studio.core import package_catalog as pc
from snapdragon_studio.core.config import ImageConfig, image_class

_GEN = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# raw (non-deduped) per-platform atom totals — pinned to the tree (design 2.8 counts).
# x86 = 149 since main added sys-apps/systemd-utils to packages.list (boot-chain #307).
_RAW_TOTALS = {"x86": 149, "rpi5": 74, "jetson": 66, "frite": 52,
               "orangepi5": 53, "orangepizero2": 32}

_CONFIGS = [
    ("x86 omnibus node", ImageConfig(mode="mesh", role="omnibus", platform="x86")),
    ("x86 pki node", ImageConfig(mode="mesh", role="pki", platform="x86")),
    ("x86 thick desktop", ImageConfig(mode="standalone", role="standalone-thick",
                                      platform="x86", desktop="full", capable=True)),
    ("x86 laptop nvidia", ImageConfig(mode="cloud", role="laptop", platform="x86",
                                      gpu_driver="nvidia", nvidia_cuda=True)),
    ("rpi5 pki node", ImageConfig(mode="mesh", role="pki", platform="rpi5")),
    ("rpi5 desktop", ImageConfig(mode="cloud", role="rpi5-desktop", platform="rpi5")),
    ("jetson edge_ai", ImageConfig(mode="mesh", role="edge_ai", platform="jetson")),
    ("frite standalone", ImageConfig(mode="standalone", role="frite", platform="frite",
                                     flavor="both", desktop="light")),
    ("opz2 appliance", ImageConfig(mode="standalone", role="orangepizero2",
                                   platform="orangepizero2", flavor="live")),
]


# ── list-file parsing ────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("platform,total", sorted(_RAW_TOTALS.items()))
def test_raw_atom_totals_match_tree(platform, total):
    got = sum(len(pc.list_atoms(_GEN, platform, s.list_id))
              for s in pc.PLATFORM_LISTS[platform])
    assert got == total, f"{platform}: parsed {got} atoms, expected {total}"


def test_sections_parsed_with_titles():
    secs = pc.list_sections(_GEN, "x86", "packages")
    assert len(secs) == 6                       # 6 '# ── Section ──' headers in the base list
    assert all(s["title"] and s["atoms"] for s in secs)
    titles = [s["title"] for s in secs]
    assert any("Networking" in t for t in titles)
    # a real atom lands under its section, a plain comment does not become a section
    flat = [a for s in secs for a in s["atoms"]]
    assert "sys-boot/grub" in flat
    assert not any(a.startswith("#") for a in flat)


def test_headerless_list_is_one_untitled_section():
    secs = pc.list_sections(_GEN, "x86", "packages-desktop-full")
    assert len(secs) == 1 and secs[0]["title"] == ""
    assert len(secs[0]["atoms"]) == 9


def test_all_atoms_are_valid_shape():
    # every parsed atom is a category/name Portage atom (no stray comment/blank leaked)
    import re
    atom_re = re.compile(r"^[a-z0-9][a-z0-9+._-]*/[A-Za-z0-9+._-]+$")
    for p in pc.PLATFORMS:
        for a in pc.all_platform_atoms(_GEN, p):
            assert atom_re.match(a), f"{p}: bad atom {a!r}"


# ── LIST_GATES ───────────────────────────────────────────────────────────────────────
def test_gated_lists_mirror_builder():
    node = ImageConfig(mode="mesh", role="pki", platform="x86")
    assert "packages" in pc.gated_lists(node)
    assert "packages-desktop" not in pc.gated_lists(node)   # a node pulls no desktop stack
    desk = ImageConfig(mode="cloud", role="laptop", platform="x86")
    assert "packages-desktop" in pc.gated_lists(desk)
    assert "packages-gpu" in pc.gated_lists(desk)           # clients get the GPU/DRI stack
    nv = ImageConfig(mode="cloud", role="laptop", platform="x86", gpu_driver="nvidia")
    assert "packages-gpu-nvidia" in pc.gated_lists(nv)


# ── essential floor + tiers ──────────────────────────────────────────────────────────
@pytest.mark.parametrize("name,cfg", _CONFIGS, ids=[n for n, _ in _CONFIGS])
def test_essential_floor_superset_of_role_bins(name, cfg):
    floor = pc.essential_floor(_GEN, cfg)
    default = pc.default_set(_GEN, cfg)
    installed_mandatory = set(pc.mandatory_atoms(cfg)) & default
    assert installed_mandatory <= floor, f"{name}: SNAP_ROLE_BINS not locked: {installed_mandatory - floor}"
    assert floor <= default, f"{name}: floor claims atoms the builder wouldn't install"


@pytest.mark.parametrize("name,cfg", _CONFIGS, ids=[n for n, _ in _CONFIGS])
def test_tiers_partition_the_catalog(name, cfg):
    t = pc.tiers(_GEN, cfg)
    e, r, a = set(t["essential"]), set(t["removable"]), set(t["available"])
    assert e.isdisjoint(r) and e.isdisjoint(a) and r.isdisjoint(a), f"{name}: tiers overlap"
    # essential+removable = the builder's default install set (list atoms + adhoc adds);
    # +available = that plus every not-gated-in list atom (the full addable universe).
    assert e | r == pc.default_set(_GEN, cfg)
    universe = pc.all_platform_atoms(_GEN, cfg.platform) | pc.default_set(_GEN, cfg)
    assert e | r | a == universe


def test_node_k8s_payload_is_locked():
    cfg = ImageConfig(mode="mesh", role="pki", platform="rpi5")
    floor = pc.essential_floor(_GEN, cfg)
    for atom in pc.list_atoms(_GEN, "rpi5", "packages-k8s"):
        assert atom in floor, f"node k8s atom {atom} must be non-removable"


def test_option_gated_adhoc_is_essential():
    cfg = ImageConfig(mode="cloud", role="laptop", platform="x86", home_encrypted=True)
    floor = pc.essential_floor(_GEN, cfg)
    assert "sys-fs/ecryptfs-utils" in floor and "sys-apps/keyutils" in floor


# ── drift: checked-in JSON vs fresh emit ─────────────────────────────────────────────
def _load_json(rel):
    with open(os.path.join(_GEN, rel), encoding="utf-8") as fh:
        return json.load(fh)


def test_packages_catalog_json_is_current():
    committed = _load_json(os.path.join("docs", "catalog", "packages-catalog.json"))
    fresh = pc.build_catalog(_GEN)
    assert committed == fresh, ("docs/catalog/packages-catalog.json is stale — run "
                                "scripts/emit-package-catalog.py")


def _load_script(name):
    path = os.path.join(_GEN, "scripts", name)
    spec = importlib.util.spec_from_file_location(name.replace("-", "_")[:-3], path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_image_catalog_json_is_current():
    committed = _load_json(os.path.join("docs", "catalog", "image-catalog.json"))
    fresh = _load_script("emit-image-catalog.py").build_image_catalog()
    assert committed == fresh, ("docs/catalog/image-catalog.json is stale — run "
                                "scripts/emit-image-catalog.py")


def test_image_catalog_grammar_covers_role_choices():
    cat = _load_script("emit-image-catalog.py").build_image_catalog()
    for mode in ("standalone", "cloud", "mesh"):
        assert cat["roles"][mode], f"{mode} has no roles"
        for entry in cat["roles"][mode]:
            assert entry["image_class"] in ("desktop", "node")
            assert entry["image_class"] == image_class(mode, entry["role"])
            assert entry["platforms"], f"{entry['role']} has no platforms"
