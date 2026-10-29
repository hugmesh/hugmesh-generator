"""Portage user patches shipped in specs-*/portage/patches must be version-scoped and must not linger.

THE FAILURE THIS PINS (rpi5 replay, 2026-10-21): specs-rpi5 and specs-jetson carried
``portage/patches/net-misc/networkmanager/0001-cross-jansson-soname.patch``. Portage's
eapply_user applies a patch in an UNVERSIONED ``<cat>/<pkg>/`` directory to every version
of that package, forever. NetworkManager 1.58.1 fixed the cross jansson SONAME lookup
upstream (its meson.build reads ``meson.get_external_property('sys_root', '')``), so the
patch stopped applying and src_prepare died::

    patch '-p1' '-f' '-g0' '--no-backup-if-mismatch' failed with
    '.../etc/portage/patches/net-misc/networkmanager/0001-cross-jansson-soname.patch'
    Hunk #1 FAILED at 296.

The image then ends "stage4 payload incomplete - missing: NetworkManager nmcli". The patch
is removed. Two rules keep it from coming back:

1. every patch directory names a version (``<pkg>-<ver>``), so a patch retires itself when
   the tree moves on instead of breaking the next version;
2. the builders REBUILD ``${SYSROOT}/etc/portage/patches`` from specs on every run, so a
   ``--resume`` sysroot cannot keep a patch the specs have dropped. The old ``cp -a`` only
   ever added files, and with the specs directory gone it did nothing at all.

Rule 2 is exercised for real: the exact block is cut out of each builder and run by bash.
"""
import os
import re
import subprocess
import textwrap

import pytest

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

#: Builders that copy specs portage/patches into the sysroot (rpi4/rpi3 run build-rpi5).
PATCH_BUILDERS = ["build-rpi5-stage4.sh", "build-jetson-stage4.sh"]

#: Portage version tail: -1.2.3, -1.2.3a, -1.2_rc1, -1.2-r4, optional :SLOT.
VERSIONED_DIR = re.compile(
    r"^[A-Za-z0-9+_][A-Za-z0-9+_.-]*?-\d+(\.\d+)*[a-z]?(_(alpha|beta|pre|rc|p)\d*)*(-r\d+)?(:[A-Za-z0-9+_.-]+)?$"
)


def _specs_patch_roots():
    for name in sorted(os.listdir(GENERATOR_DIR)):
        root = os.path.join(GENERATOR_DIR, name, "portage", "patches")
        if name.startswith("specs-") and os.path.isdir(root):
            yield name, root


def _patch_dirs():
    """(specs, category, dirname) for every <cat>/<dir> that holds a file."""
    for specs, root in _specs_patch_roots():
        for cat in sorted(os.listdir(root)):
            cdir = os.path.join(root, cat)
            if not os.path.isdir(cdir):
                continue
            for d in sorted(os.listdir(cdir)):
                if os.path.isdir(os.path.join(cdir, d)):
                    yield specs, cat, d


def _eapply_user_dirs(category, pn, pv, pr, slot="0"):
    """The directories portage's eapply_user reads, in its own order (phase-helpers.sh):
    ${CATEGORY}/{${P}-${PR},${P},${PN}}{:${SLOT%/*},}"""
    p = f"{pn}-{pv}"
    out = []
    for base in (f"{p}-{pr}", p, pn):
        for suffix in (f":{slot}", ""):
            out.append(os.path.join(category, base + suffix))
    return out


def test_every_specs_patch_dir_names_a_version():
    bad = [f"{s}/portage/patches/{c}/{d}" for s, c, d in _patch_dirs() if not VERSIONED_DIR.match(d)]
    assert not bad, (
        "unversioned portage user-patch dir(s): portage applies these to EVERY future "
        "version of the package, which is how the NetworkManager jansson patch broke "
        "1.58.1. Move each into <cat>/<pkg>-<version>/: " + ", ".join(bad)
    )


def test_version_regex_tells_versioned_from_bare():
    for ok in ("networkmanager-1.56.1", "networkmanager-1.56.1-r2", "gtk+-3.24.41",
               "foo-2.0_rc1", "foo-1.0:0", "libfoo2-0.9a"):
        assert VERSIONED_DIR.match(ok), ok
    for bare in ("networkmanager", "gtk+", "libfoo2", "foo-bar"):
        assert not VERSIONED_DIR.match(bare), bare


@pytest.mark.parametrize("pr", ["r0", "r1", "r2", "r3"])
def test_no_specs_patch_reaches_networkmanager_1_58_1(pr):
    """NM >= 1.58.1 handles the cross sys_root itself; no shipped patch may be picked for it."""
    hits = []
    for specs, root in _specs_patch_roots():
        for d in _eapply_user_dirs("net-misc", "networkmanager", "1.58.1", pr):
            full = os.path.join(root, d)
            if os.path.isdir(full) and os.listdir(full):
                hits.append(f"{specs}/portage/patches/{d}")
    assert not hits, f"eapply_user would apply these to networkmanager-1.58.1-{pr}: {hits}"


def _install_block(builder):
    """The builder's live patches-install block: from its comment header to the closing fi."""
    with open(os.path.join(GENERATOR_DIR, builder), encoding="utf-8") as fh:
        src = fh.read()
    m = re.search(
        r"^# Per-package user patches auto-applied by eapply_user.*?^fi\n", src, re.S | re.M
    )
    assert m, f"{builder}: patches install block not found"
    return m.group(0)


def _run_block(block, sysroot, specs_dir):
    script = "set -euo pipefail\n" + block
    return subprocess.run(
        ["bash", "-c", script],
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
             "SYSROOT": sysroot, "SPECS_DIR": specs_dir},
        capture_output=True, text=True, timeout=30,
    )


def _seed_stale(sysroot):
    stale = os.path.join(sysroot, "etc", "portage", "patches", "net-misc", "networkmanager")
    os.makedirs(stale)
    with open(os.path.join(stale, "0001-cross-jansson-soname.patch"), "w") as fh:
        fh.write("--- a/meson.build\n+++ b/meson.build\n")
    return stale


@pytest.mark.parametrize("builder", PATCH_BUILDERS)
def test_resumed_sysroot_loses_a_patch_the_specs_dropped(builder, tmp_path):
    """--resume reuses the sysroot; a stale NM patch there must be gone after spec install,
    run against the builder's REAL specs dir (which no longer has a patches dir at all)."""
    sysroot = str(tmp_path / "sysroot")
    stale = _seed_stale(sysroot)
    specs = "specs-rpi5" if "rpi5" in builder else "specs-jetson"
    r = _run_block(_install_block(builder), sysroot, os.path.join(GENERATOR_DIR, specs))
    assert r.returncode == 0, r.stderr
    assert not os.path.exists(stale), (
        f"{builder}: stale {stale} survived the spec install; the next emerge of "
        "networkmanager-1.58.1 would die in src_prepare on it"
    )
    assert os.path.isdir(os.path.join(sysroot, "etc", "portage", "patches"))


@pytest.mark.parametrize("builder", PATCH_BUILDERS)
def test_spec_install_still_copies_versioned_patches(builder, tmp_path):
    """The rebuild must not throw away what the specs DO ship."""
    sysroot = str(tmp_path / "sysroot")
    _seed_stale(sysroot)
    specs = tmp_path / "specs"
    want = specs / "portage" / "patches" / "dev-libs" / "foo-1.2.3"
    want.mkdir(parents=True)
    (want / "0001-fix.patch").write_text("--- a/x\n+++ b/x\n")
    r = _run_block(_install_block(builder), sysroot, str(specs))
    assert r.returncode == 0, r.stderr
    got = os.path.join(sysroot, "etc", "portage", "patches", "dev-libs", "foo-1.2.3", "0001-fix.patch")
    assert os.path.isfile(got)
    assert not os.path.exists(os.path.join(sysroot, "etc", "portage", "patches", "net-misc", "networkmanager"))


def test_block_is_the_one_the_builder_runs():
    """The cut block must be live code at top level, not a dead copy in a comment or heredoc."""
    for builder in PATCH_BUILDERS:
        block = _install_block(builder)
        live = [ln for ln in block.split("\n") if ln.strip() and not ln.lstrip().startswith("#")]
        assert live[0] == 'rm -rf "${SYSROOT}/etc/portage/patches"', (builder, live[:2])
        assert textwrap.dedent(live[-1]) == "fi"
