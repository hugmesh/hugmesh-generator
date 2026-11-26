"""The web login theme's key list lives in core/brand_look.py, not in a screen.

gui/pages/localmesh.py used to carry its own dict of the seventeen ``login_*`` keys (the
inputs a saved-mesh record keeps, because the stylesheet derived from them is not
invertible). A key missing from a hand-copied list is silently dropped on every
Load/Restore, so the list now has one home and these tests hold it to the two things
that define it: the ``login_*`` members of the config's non-argv fields that the look
maps onto, and the shipped defaults of the config itself.
"""
from __future__ import annotations

import dataclasses
import os
import re
from types import SimpleNamespace

from hugmesh_studio.core import brand_look
from hugmesh_studio.core.config import NON_ARGV_FIELDS, ImageConfig

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE = os.path.join(STUDIO_ROOT, "hugmesh_studio")


def test_the_list_is_every_login_input_the_look_maps_onto():
    """Derived independently: a look field whose config attribute is a ``login_*`` NON-argv
    field. A new web look field added to ImageConfig and CFG_FIELDS but not to
    LOGIN_THEME_FIELDS goes red here, not on a user's Load."""
    derived = {f for f, attr in brand_look.CFG_FIELDS.items()
               if attr.startswith("login_") and attr in NON_ARGV_FIELDS}
    assert set(brand_look.LOGIN_THEME_FIELDS) == derived
    assert len(brand_look.LOGIN_THEME_FIELDS) == 17
    assert len(set(brand_look.LOGIN_THEME_FIELDS)) == 17        # no repeats


def test_the_desktop_look_fields_are_not_web_theme_inputs():
    for f in ("theme", "wallpaper", "boot_background", "boot_theme",
              "login_screen_background", "desktop_logo", "accent_color", "color_scheme",
              "style", "decor", "logo_image", "login_bg_image"):
        assert f not in brand_look.LOGIN_THEME_FIELDS, f


def test_the_attr_map_and_the_form_defaults_agree_with_the_config():
    cfg_defaults = {f.name: f.default for f in dataclasses.fields(ImageConfig)}
    assert set(brand_look.LOGIN_THEME_ATTRS.values()) == set(brand_look.LOGIN_THEME_FORM_DEFAULTS)
    for field, attr in brand_look.LOGIN_THEME_ATTRS.items():
        assert attr == brand_look.CFG_FIELDS[field]
        assert attr in cfg_defaults, f"{attr} is not an ImageConfig field"
        # "the shipped look" is not a second opinion: it IS the dataclass default
        assert brand_look.LOGIN_THEME_FORM_DEFAULTS[attr] == cfg_defaults[attr], attr


def test_an_empty_form_derives_the_shipped_look():
    """What apply_bootstrap does with a record that has no inputs: the defaults laid over
    nothing derive the same look as a fresh config."""
    ns = SimpleNamespace(**brand_look.LOGIN_THEME_FORM_DEFAULTS)
    from_form = brand_look.look_from_cfg(ns)
    fresh = brand_look.look_from_cfg(ImageConfig())
    for f in brand_look.LOGIN_THEME_FIELDS:
        assert from_form[f] == fresh[f], f


def _front_end_sources():
    for sub in ("gui", "tui"):
        for root, _dirs, files in os.walk(os.path.join(PACKAGE, sub)):
            for name in files:
                if name.endswith(".py"):
                    path = os.path.join(root, name)
                    with open(path, encoding="utf-8") as fh:
                        yield os.path.relpath(path, PACKAGE), fh.read()


#: a quoted "login_<theme input>" key, i.e. a list of keys rather than a read of one
_KEY_LITERAL = re.compile(
    r"""["'](%s)["']""" % "|".join(re.escape(a) for a in brand_look.LOGIN_THEME_FORM_DEFAULTS))


def _offenders(sources):
    return [(rel, m.group(1)) for rel, text in sources for m in _KEY_LITERAL.finditer(text)]


def test_no_front_end_lists_the_login_theme_keys_itself():
    sources = list(_front_end_sources())
    assert len(sources) > 20, "the walk found no front-end files"
    assert not _offenders(sources), (
        "a front end spells ImageConfig's login_* theme keys out; read "
        f"brand_look.LOGIN_THEME_FORM_DEFAULTS / LOGIN_THEME_ATTRS instead: {_offenders(sources)}")


def test_the_scan_catches_a_planted_copy():
    planted = '_FORM = {"login_primary_color": "", "login_bg_effect": ""}\n'
    assert _offenders([("gui/pages/x.py", planted)]) == [
        ("gui/pages/x.py", "login_primary_color"), ("gui/pages/x.py", "login_bg_effect")]
