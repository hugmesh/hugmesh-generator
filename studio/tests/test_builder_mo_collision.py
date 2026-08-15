"""The gettext empty-$(DOMAIN) .mo-collision dodge must stay in ALL builders, BOTH sides.

gettext-0.23.2 miscomputes $(DOMAIN), so every autotools-NLS package installs a file
literally named /usr/share/locale/<lang>/LC_MESSAGES/.mo. Two packages claiming one path
is a file collision, and collision-protect refuses the WHOLE merge — so gettext/sed/
util-linux fail, and since they are BDEPENDs of nearly everything, every following atom is
warn-skipped too. The build then grinds on for hours and dies at the requested-atom gate.

THERE ARE TWO INDEPENDENT COLLISIONS AND EACH NEEDS ITS OWN MASK. This is the part that
was got wrong twice, in opposite directions, so it is pinned explicitly:

  * HOST side — BDEPENDs are merged to "/", so they collide on the BUILD CONTAINER's root
    against its own bash (observed 2026-08-14: 41 empty-stem catalogs there owned by
    bash-5.3_p9-r2, which ships no bash.mo, while the sysroot vdb was clean). Masked by a
    seed the builder appends to the container's /etc/portage/make.conf, inside the
    hostguard_mutation_allowed branch. A mask in a spec template CANNOT fix this one.

  * TARGET side — packages cross-emerged into ${SYSROOT} collide there as well. This is
    the half build-x86-host-stage4.sh has always covered, by substituting @@INSTALL_MASK@@
    into specs-x86/portage/make.conf.tmpl (build-x86-host-stage4.sh:2010/2019 and :2058);
    its comment records grub/parted/dracut failing to merge and a 2026-07-08 build losing
    143 packages. A host-side seed CANNOT fix this one.

The rpi5 port initially carried only the host half and asserted in a comment that a
template mask "would change nothing" — true of the host collision, false in general. Both
halves are now present on every cross builder, and both are pinned below.
"""
import os
import re

import pytest

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

_MASK = "/usr/share/locale/*/LC_MESSAGES/.mo"

#: Every builder that cross-emerges and therefore needs the HOST-side seed.
_HOST_SIDE = [
    "build-x86-host-stage4.sh", "build-rpi5-stage4.sh",
    "build-frite-stage4.sh", "build-jetson-stage4.sh",
    "build-orangepi5-stage4.sh", "build-orangepi-zero2-stage4.sh",
    "build-orangepi-zero2w-stage4.sh", "build-orangepi-zero3-stage4.sh",
    "build-orangepi3-lts-stage4.sh", "build-orangepi4-lts-stage4.sh",
]

#: Spec trees whose make.conf.tmpl must mask the catalogs TARGET-side. specs-x86 is absent
#: on purpose: it templates INSTALL_MASK as @@INSTALL_MASK@@ and the builder substitutes
#: the real value, so its coverage is asserted against the builder instead.
_TARGET_SIDE = [
    "specs-rpi5", "specs-frite", "specs-jetson", "specs-orangepi5",
    "specs-orangepi-zero2", "specs-orangepi-zero2w", "specs-orangepi-zero3",
    "specs-orangepi3-lts", "specs-orangepi4-lts",
]


def _read(rel: str) -> str:
    with open(os.path.join(GENERATOR_DIR, rel), encoding="utf-8") as fh:
        return fh.read()


@pytest.mark.parametrize("builder", _HOST_SIDE)
def test_host_side_seed_present(builder):
    """Every cross builder masks the catalogs on the container root."""
    assert _MASK in _read(builder), (
        f"{builder} lost the HOST-side gettext .mo mask. Without it gettext/sed/util-linux "
        f"fail to merge on file collisions against the build container's own bash, and "
        f"every dependent atom is warn-skipped — the build dies hours later at the "
        f"requested-atom gate."
    )


@pytest.mark.parametrize("board", _TARGET_SIDE)
def test_target_side_mask_present(board):
    """Every spec tree masks the catalogs inside the sysroot as well."""
    tmpl = _read(os.path.join(board, "portage", "make.conf.tmpl"))
    assert _MASK in tmpl, (
        f"{board}/portage/make.conf.tmpl lost the TARGET-side gettext .mo mask. The "
        f"host-side seed does NOT cover this: it masks the build container's root, not "
        f"${{SYSROOT}}. This is the half that took out grub/parted/dracut on x86."
    )
    assert re.search(r'^INSTALL_MASK="[^"]*"$', tmpl, re.M), (
        f"{board}: INSTALL_MASK must stay a single well-formed assignment"
    )


def test_x86_target_coverage_comes_through_the_substitution():
    """specs-x86 templates INSTALL_MASK, so its target mask lives in the builder.

    Pinned separately so nobody 'fixes' the specs-x86 template by hardcoding a value and
    silently drops the ROLE_CLIENT-dependent mask the builder computes.
    """
    tmpl = _read(os.path.join("specs-x86", "portage", "make.conf.tmpl"))
    assert "@@INSTALL_MASK@@" in tmpl
    src = _read("build-x86-host-stage4.sh")
    assert "@@INSTALL_MASK@@|${INSTALL_MASK}" in src, "the substitution that feeds it is gone"
    assert _MASK in src


def test_host_seed_is_inside_the_host_mutation_branch():
    """Placement is the whole fix, so assert placement — not just the string.

    A seed written after the hostguard_mutation_allowed branch closes, or into a sysroot
    make.conf, reads as fixed and changes nothing. Checked on every host-side builder.
    """
    for builder in _HOST_SIDE:
        src = _read(builder)
        guard = src.find("hostguard_mutation_allowed")
        seed = src.find("hugmesh-mo-collision")
        if seed == -1:            # x86 predates the marker; covered by the string test
            continue
        assert guard != -1 and guard < seed, f"{builder}: seed precedes the host guard"
        window = src[seed - 800:seed + 400]
        assert "/etc/portage/make.conf" in window, f"{builder}: seed writes nowhere sane"
        assert "SYSROOT" not in src[seed:seed + 400], (
            f"{builder}: the host seed must not write into a sysroot make.conf"
        )
