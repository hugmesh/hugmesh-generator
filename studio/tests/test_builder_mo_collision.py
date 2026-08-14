"""The gettext empty-$(DOMAIN) .mo-collision dodge must stay in the builders.

gettext-0.23.2 miscomputes $(DOMAIN), so every autotools-NLS package installs a
file literally named /usr/share/locale/<lang>/LC_MESSAGES/.mo. Two packages
claiming one path is a file collision, and collision-protect refuses the WHOLE
merge — so gettext/sed/util-linux fail, and since they are BDEPENDs of nearly
everything, every following atom is warn-skipped too. The build then grinds on
for hours and dies at the requested-atom completeness gate.

This is a REGRESSION test in the literal sense: the dodge existed in
build-x86-host-stage4.sh (whose comment records a 2026-07-08 build that "lost 143
packages to this") and was never carried into build-rpi5-stage4.sh, which cost a
~2h rpi5/pki run on 2026-08-14. Cross-builder drift is the bug; this pins it shut.

KNOWN GAP, deliberately not asserted here: the eight other cross builders
(frite, jetson, orangepi{,-zero2,-zero2w,-zero3,3-lts,4-lts,5}) share the same
hostguard_mutation_allowed + cross_emerge structure and carry NO dodge, so they
are expected to fail the same way. They are untested on this workstation and out
of the scope that surfaced this, so widening the fix is the operator's call
rather than a blind eight-file edit.
"""
import os

import pytest

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

#: The builders this harness actually exercises, and therefore pins.
_PINNED = ["build-x86-host-stage4.sh", "build-rpi5-stage4.sh"]

#: Cross builders known to lack the dodge. Listed so the gap is discoverable from
#: the test suite rather than only from a two-hour build failure.
_KNOWN_GAP = [
    "build-frite-stage4.sh", "build-jetson-stage4.sh",
    "build-orangepi5-stage4.sh", "build-orangepi-zero2-stage4.sh",
    "build-orangepi-zero2w-stage4.sh", "build-orangepi-zero3-stage4.sh",
    "build-orangepi3-lts-stage4.sh", "build-orangepi4-lts-stage4.sh",
]

_MASK_PATTERN = "/usr/share/locale/*/LC_MESSAGES/.mo"


def _read(name: str) -> str:
    with open(os.path.join(GENERATOR_DIR, name), encoding="utf-8") as fh:
        return fh.read()


@pytest.mark.parametrize("builder", _PINNED)
def test_builder_masks_empty_domain_mo_catalogs(builder):
    assert _MASK_PATTERN in _read(builder), (
        f"{builder} lost the gettext empty-$(DOMAIN) .mo INSTALL_MASK. Without it "
        f"gettext/sed/util-linux fail to merge on file collisions and every "
        f"dependent atom is warn-skipped, including sys-kernel/raspberrypi-sources "
        f"— the build dies HOURS later at the requested-atom gate."
    )


def test_rpi5_dodge_is_seeded_host_side_not_into_the_sysroot():
    """Placement is the whole fix, so assert the placement — not just the string.

    The colliding packages are BDEPENDs that portage merges to "/", so the
    collision happens on the BUILD CONTAINER's root. specs-rpi5/portage/
    make.conf.tmpl renders to ${SYSROOT}/etc/portage/make.conf — the wrong side —
    so a mask that lands only there would read as fixed and change nothing.
    """
    src = _read("build-rpi5-stage4.sh")
    idx = src.index(_MASK_PATTERN)
    # The seed must sit in the host-mutation branch, i.e. after that guard opens.
    guard = src.index("hostguard_mutation_allowed")
    assert guard < idx, "the .mo mask must be seeded inside the host-mutation block"
    # It writes to the CONTAINER's /etc/portage/make.conf, never the sysroot's.
    window = src[idx - 600:idx + 400]
    assert "/etc/portage/make.conf" in window
    assert "SYSROOT" not in window.split(_MASK_PATTERN)[1][:200], (
        "the mask must not be written into the sysroot make.conf")


def test_known_gap_list_is_accurate():
    """If someone fixes a gap builder, this test tells them to update the list.

    A stale 'known gap' comment is worse than none: it would keep advertising a
    defect that no longer exists, or hide one that spread.
    """
    still_missing = [b for b in _KNOWN_GAP if _MASK_PATTERN not in _read(b)]
    assert still_missing == _KNOWN_GAP, (
        "these builders gained the .mo dodge — move them into _PINNED so they are "
        f"pinned against drift: {sorted(set(_KNOWN_GAP) - set(still_missing))}"
    )
