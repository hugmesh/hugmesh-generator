"""prebuild_union (shared-binpkg Lane 4b) — the headless role-UNION feed the
``make prebuild-binaries`` target hands the builder via --seed-packages-from.

Asserts the union is exactly ``set().union`` over the EXISTING
``package_catalog.default_set`` for every ``(platform, role)`` cell (no invented
resolution), is a superset of each contributing role, carries the base packages.list
floor, and that the module's CLI face prints the sorted atoms + rejects bad input."""
import os

import pytest

from snapdragon_studio.core import package_catalog as pc
from snapdragon_studio.core import prebuild_union as pu

_GEN = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

_PLATFORMS = ("x86", "rpi5", "frite", "jetson", "orangepi5", "orangepizero2")


@pytest.mark.parametrize("platform", _PLATFORMS)
def test_union_is_superset_of_every_role(platform):
    """The union must contain every role's default_set for that platform (it IS their
    union) — and be exactly that union, so it never invents or drops an atom."""
    cells = [(r, modes) for (p, r), modes in pc.role_cells().items() if p == platform]
    assert cells, f"no roles for {platform}"
    want = set()
    for role, modes in cells:
        cfg = pc.default_cell_config(modes[0], role, platform)
        role_set = pc.default_set(_GEN, cfg)
        assert role_set, f"{role} x {platform} default_set empty"
        want |= role_set
    got = pu.union_atoms(_GEN, platform)
    assert got == want                      # exactly the union, nothing more/less
    for role, modes in cells:               # and a superset of each contributor
        cfg = pc.default_cell_config(modes[0], role, platform)
        assert pc.default_set(_GEN, cfg) <= got


@pytest.mark.parametrize("platform", _PLATFORMS)
def test_union_carries_base_floor(platform):
    """Every platform's base packages.list atoms are in the union (they are in every
    role's set), so the prebuilt pool always covers the common floor."""
    base = set(pc.list_atoms(_GEN, platform, "packages"))
    assert base, f"{platform} has no base packages.list"
    assert base <= pu.union_atoms(_GEN, platform)


def test_platform_roles_matches_role_cells():
    for platform in _PLATFORMS:
        want = sorted({r for (p, r) in pc.role_cells() if p == platform})
        assert pu.platform_roles(platform) == want


def test_known_platforms():
    assert set(pu.known_platforms()) == set(_PLATFORMS)


def test_cli_prints_sorted_atoms(capsys):
    rc = pu.main(["rpi5", "--generator-dir", _GEN])
    assert rc == 0
    out = capsys.readouterr().out.splitlines()
    assert out == sorted(pu.union_atoms(_GEN, "rpi5"))
    assert out == sorted(set(out))          # sorted + de-duplicated


def test_cli_rejects_unknown_platform():
    with pytest.raises(SystemExit):         # argparse choices -> SystemExit(2)
        pu.main(["not-a-platform"])
