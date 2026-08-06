"""Package catalog (design 2.8) — parse the real spec trees, verify the tri-tier model
(essential floor superset of the SNAP_ROLE_BINS payload, tiers disjoint), and drift-check
the checked-in packages-catalog.json / image-catalog.json against a fresh emit."""
import importlib.util
import json
import os

import pytest

from hugmesh_studio.core import package_catalog as pc
from hugmesh_studio.core.config import ImageConfig, ROLE_CHOICES, image_class

_GEN = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# raw (non-deduped) per-platform atom totals — pinned to the tree (design 2.8 counts).
# x86 = 149 since main added sys-apps/systemd-utils to packages.list (boot-chain #307).
# rpi5 = 73 since #513 excluded net-firewall/firewalld from specs-rpi5: its
# glib[introspection] chain does not cross-compile (the real build died in glib's
# in-source gobject-introspection bootstrap), so the atom was removed behind a
# paper-trail comment and tests/requested-atoms-resolvable.sh pins the exclusion.
_RAW_TOTALS = {"x86": 149, "rpi5": 73, "jetson": 66, "frite": 52,
               "orangepi5": 53, "orangepizero2": 32, "orangepizero2w": 32}

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
    ("opz2w appliance", ImageConfig(mode="standalone", role="orangepizero2w",
                                    platform="orangepizero2w", flavor="live")),
    ("opz3 appliance", ImageConfig(mode="standalone", role="orangepizero3",
                                   platform="orangepizero3", flavor="live")),
    ("opi3lts appliance", ImageConfig(mode="standalone", role="orangepi3-lts",
                                      platform="orangepi3-lts", flavor="live")),
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


# ── per-cell role tiers (the emitted default-options baseline; "roles" in the JSON) ──
def _load_json(rel):
    with open(os.path.join(_GEN, rel), encoding="utf-8") as fh:
        return json.load(fh)


def _committed_roles():
    return _load_json(os.path.join("docs", "catalog", "packages-catalog.json"))["roles"]


def test_roles_map_covers_every_valid_cell_exactly():
    # cells come from ROLE_CHOICES (the grammar image-catalog.json serves) — the emitted
    # map must carry EVERY valid role x platform cell and nothing invented.
    want = {(p, r) for choices in ROLE_CHOICES.values()
            for r, plats, _label in choices for p in plats}
    got = {(p, r) for p, rs in _committed_roles().items() for r in rs}
    assert got == want, f"missing={want - got} extra={got - want}"


def test_roles_tiers_sorted_unique_disjoint():
    for p, rs in _committed_roles().items():
        for r, t in rs.items():
            assert set(t) == {"essential", "removable", "available"}, f"{p}/{r}"
            for name, lst in t.items():
                assert lst == sorted(set(lst)), f"{p}/{r}.{name}: not sorted/unique"
            e, rm, av = set(t["essential"]), set(t["removable"]), set(t["available"])
            assert e.isdisjoint(rm) and e.isdisjoint(av) and rm.isdisjoint(av), \
                f"{p}/{r}: tiers overlap"
            assert e, f"{p}/{r}: empty essential (the base list must always lock)"


def test_roles_invariants_hold_against_fresh_derivation():
    # the exporter's fail-loud gate (essential == essential_floor, essential∪removable ==
    # default set, universe coverage, exact cells) must hold on the COMMITTED data too.
    pc.validate_roles_tiers(_GEN, _committed_roles())


def test_validator_rejects_essential_removable_boundary_shift():
    # A hand-edited (or out-of-band) roles map that shifts an atom across the essential/
    # removable BOUNDARY keeps every set-algebra invariant green (disjoint, e∪rm == default,
    # e ⊆ default) — the validator must reject the boundary itself (e == essential_floor),
    # or a consumer revalidating a served copy could render a mandatory node binary as
    # droppable. Injected in BOTH directions.
    import copy

    # demote: weaken the exact lock the floor exists for (rpi5/pki k8s payload).
    roles = copy.deepcopy(_committed_roles())
    t = roles["rpi5"]["pki"]
    atom = "sys-cluster/kubelet"
    assert atom in t["essential"]
    t["essential"].remove(atom)
    t["removable"] = sorted(set(t["removable"]) | {atom})
    with pytest.raises(ValueError, match="essential != essential_floor"):
        pc.validate_roles_tiers(_GEN, roles)

    # promote: wrongly widen the lock floor with a removable atom.
    roles = copy.deepcopy(_committed_roles())
    cell = next((p, r, t) for p, rs in sorted(roles.items())
                for r, t in sorted(rs.items()) if t["removable"])
    p, r, t = cell
    atom = t["removable"][0]
    t["removable"].remove(atom)
    t["essential"] = sorted(set(t["essential"]) | {atom})
    with pytest.raises(ValueError, match="essential != essential_floor"):
        pc.validate_roles_tiers(_GEN, roles)


def test_node_cell_locks_k8s_payload_desktop_cell_does_not():
    roles = _committed_roles()
    for platform, node_role, desk_role in (("rpi5", "pki", "rpi5-desktop"),
                                           ("jetson", "edge_ai", "jetson-desktop")):
        k8s = set(pc.list_atoms(_GEN, platform, "packages-k8s"))
        assert k8s, f"{platform}: packages-k8s parsed empty"
        assert k8s <= set(roles[platform][node_role]["essential"]), \
            f"{platform}/{node_role}: k8s payload not locked"
        desk = roles[platform][desk_role]
        assert not k8s & set(desk["essential"]) and not k8s & set(desk["removable"]), \
            f"{platform}/{desk_role}: k8s payload leaked into the default set"
        assert k8s <= set(desk["available"])
    # x86 bakes the k8s payload into its BASE list (every x86 image emerges it), so the
    # node/desktop distinction is an ARM reality — pin the x86 base-bake so nobody
    # "fixes" it into the ARM shape without noticing the builder difference.
    assert "sys-cluster/kubelet" in roles["x86"]["laptop"]["essential"]
    assert "sys-cluster/kubelet" in roles["x86"]["pki"]["essential"]


def test_roles_baseline_carries_no_adhoc_option_atoms():
    # default-options semantics: NO adhoc option enabled in the baseline — the web UI
    # layers option atoms client-side from adhoc_adds. default_cell_config also raises
    # on leak; this pins the contract (snort/installer_ui are default-ON dataclass
    # fields the cell config must force off).
    for (platform, role), modes in pc.role_cells().items():
        for mode in modes:
            cfg = pc.default_cell_config(mode, role, platform)
            assert pc.adhoc_atoms(cfg) == [], f"{platform}/{role} ({mode})"
    t = _committed_roles()["x86"]["laptop"]
    default = set(t["essential"]) | set(t["removable"])
    assert "app-admin/calamares" not in default      # installer_ui default "all"
    assert "net-analyzer/snort" not in default       # snort default True


def test_shared_role_tokens_tier_identically_across_modes():
    # what makes the plain role token a sound key: a cell offered in several Studio
    # modes (frite standalone+cloud, rpi5-desktop cloud+mesh, ...) tiers identically.
    multi = {cell: modes for cell, modes in pc.role_cells().items() if len(modes) > 1}
    assert multi, "expected mode-shared cells (frite / rpi5-desktop ...)"
    for (platform, role), modes in multi.items():
        results = [pc.tiers(_GEN, pc.default_cell_config(m, role, platform))
                   for m in modes]
        assert all(x == results[0] for x in results[1:]), f"{platform}/{role}"


# ── drift: checked-in JSON vs fresh emit ─────────────────────────────────────────────


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
