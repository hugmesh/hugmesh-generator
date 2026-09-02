"""root_size_floor mirrors the builders' own compact-root defaults — the numbers
are pinned here against the builder tables the module cites, so a builder-side
resize shows up as a test failure instead of a silently-wrong floor."""
from hugmesh_studio.core import root_size_floor as rsf


def test_x86_desktop_floors_mirror_builder():
    # build-x86:1600-1608
    assert rsf.min_root_mib("x86", "cloud", "laptop") == 16384
    assert rsf.min_root_mib("x86", "cloud", "laptop", desktop="full") == 24576
    assert rsf.min_root_mib("x86", "cloud", "laptop", capable=True) == 51200
    assert rsf.min_root_mib("x86", "cloud", "standalone-unaffiliated") == 16384


def test_x86_node_floors_mirror_builder():
    # build-x86:1734-1736: GPU roles get the Mesa/Vulkan bump
    assert rsf.min_root_mib("x86", "mesh", "pki") == 14336
    assert rsf.min_root_mib("x86", "mesh", "backend-gpu") == 20480
    assert rsf.min_root_mib("x86", "mesh", "omnibus") == 20480


def test_arm_floors_mirror_builders():
    assert rsf.min_root_mib("rpi5", "mesh", "pki") == 9216       # build-rpi5:203
    assert rsf.min_root_mib("jetson", "mesh", "full") == 20480   # build-jetson:531
    assert rsf.min_root_mib("jetson", "mesh", "backend-gpu") == 14336
    assert rsf.min_root_mib("frite", "cloud", "desktop") == 3072
    assert rsf.min_root_mib("orangepizero2", "mesh", "pki") == 2048


def test_error_only_for_explicit_undersized_values():
    # 0 = role default: always accepted (that IS the safe path).
    assert rsf.img_size_error("x86", "cloud", "laptop", 0) == ""
    # at/above the floor: accepted.
    assert rsf.img_size_error("x86", "cloud", "laptop", 16384) == ""
    assert rsf.img_size_error("x86", "cloud", "laptop", 65536) == ""
    # the reported bug shape: a tiny literal (3 MiB) must be refused, with the
    # floor named so the user can fix it without reading builder source.
    err = rsf.img_size_error("x86", "cloud", "standalone-unaffiliated", 3)
    assert "16384" in err and "pre-flight" in err
    err = rsf.img_size_error("x86", "cloud", "laptop", 3, capable=True)
    assert "51200" in err


def test_unknown_platform_has_no_floor():
    assert rsf.min_root_mib("someboard", "mesh", "pki") == 0
    assert rsf.img_size_error("someboard", "mesh", "pki", 3) == ""
