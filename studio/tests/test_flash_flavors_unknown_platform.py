"""#478: the flavour menu for a platform nobody can name is "auto" only.

``flash_targets.flavors_for_platform`` used to read ``platform or "x86"``, so an EMPTY
platform got the widest menu (auto, img, live, installer) while an unrecognised one got
(auto, img). The empty case is what the Review page's device table has for a flash
row whose image left the worklist, so an rpi5 or jetson image was offered live and
installer, and a pick of either was skipped at flash time every time.

Qt-free on purpose: tests/test_flash_targets.py and tests/test_device_imaging_flavors.py
skip at module level without a Qt binding, so the no-Qt pull-request job never runs a
model pin placed there.
"""
import pytest

from hugmesh_studio.core import config
from hugmesh_studio.core import flash_targets as ft


@pytest.mark.parametrize("platform", ["", None, "nonsense-platform", "X86", "rpi"])
def test_unknown_or_empty_platform_offers_auto_only(platform):
    flavors = ft.flavors_for_platform(platform)
    assert flavors == (ft.FLAVOR_AUTO,)
    assert "live" not in flavors and "installer" not in flavors


def test_empty_platform_is_not_given_the_x86_menu():
    assert ft.flavors_for_platform("") != ft.flavors_for_platform("x86")


def test_known_platform_menus_are_unchanged():
    assert ft.flavors_for_platform("x86") == ("auto", "img", "live", "installer")
    assert ft.flavors_for_platform("rpi5") == ("auto", "img")
    assert ft.flavors_for_platform("jetson") == ("auto", "img")
    for p in ("frite", "orangepi5", "orangepizero2", "orangepizero2w", "orangepizero3",
              "orangepi3-lts", "orangepi4-lts"):
        assert ft.flavors_for_platform(p) == ("auto", "live", "installer"), p


def test_every_buildable_platform_has_a_menu():
    # the conservative fallback must only ever catch platforms the builders do not
    # have: a real platform missing from the table would lose its flavours silently
    assert set(config.BUILDER_SCRIPTS) <= set(ft._PLATFORM_FLAVORS)
    for p in config.BUILDER_SCRIPTS:
        assert len(ft.flavors_for_platform(p)) > 1, p
