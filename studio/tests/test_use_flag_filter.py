"""The USE column shows decisions, not inventory.

Operator rule (2026-08-05): "don't show unused flags in USE unless they are enabled by
default by gentoo and disabled by our profile or mesh builds."

A stage4 sysroot lists every flag in a package's IUSE. Most are disabled and were never
going to be anything else — noise in a column the operator scans for decisions. The one
disabled flag that IS a decision is the one Gentoo's own ebuild defaults ON (``+flag``)
that our profile / make.conf / mesh posture turned off.
"""
import dataclasses

import pytest

from hugmesh_studio.core import package_flags as pf
from hugmesh_studio.gui import flag_badges as fb


def _vdb(iuse: str, use: str) -> pf.VdbPackage:
    kw = {f.name: None for f in dataclasses.fields(pf.VdbPackage)}
    kw.update(cat="dev-libs", pf="thing-1.0", pkg="thing", version="1.0",
              iuse=iuse, use=use)
    return pf.VdbPackage(**kw)


def _shown(cells):
    """Flag names visible in the USE cell — read from each badge's verbatim token
    (Badge carries the portage text, not the parsed token)."""
    cell = cells.get("USE")
    if not cell:
        return []
    return [b.verbatim.lstrip("-").rstrip("*%()") for b in cell.badges]


def test_default_on_marker_is_preserved_not_stripped():
    v = _vdb("+ssl nls -debug test", "ssl nls")
    assert v.iuse_default_on == frozenset({"ssl"})
    assert v.iuse_names == ("ssl", "nls", "debug", "test")   # unchanged contract


def test_plain_disabled_flags_are_hidden():
    """`-test` where the ebuild says plain `test`: nobody ever wanted it."""
    v = _vdb("ssl test debug", "ssl")
    shown = _shown(fb.vdb_use_cells(v))
    assert "ssl" in shown
    assert "test" not in shown and "debug" not in shown


def test_explicit_default_off_flags_are_hidden():
    """`-debug` in IUSE is upstream saying off; us leaving it off is not a decision."""
    v = _vdb("ssl -debug", "ssl")
    assert "debug" not in _shown(fb.vdb_use_cells(v))


def test_the_one_interesting_disabled_flag_is_shown():
    """`+ssl` in IUSE but absent from USE — WE turned off what Gentoo ships on."""
    v = _vdb("+ssl nls", "nls")
    shown = _shown(fb.vdb_use_cells(v))
    assert "ssl" in shown, "our override of a Gentoo default must stay visible"
    assert "nls" in shown


def test_enabled_flags_are_always_shown():
    v = _vdb("+ssl nls test", "ssl nls test")
    assert set(_shown(fb.vdb_use_cells(v))) == {"ssl", "nls", "test"}


def test_a_package_whose_flags_are_all_boring_shows_nothing_but_keeps_the_copy():
    """All-off, none default-on: nothing to SEE, but the verbatim string must survive.

    The cell is still built (it carries verbatim_text) while having no badges and no
    display text — and apply_cells refuses to reveal a column for a badge-less cell,
    so the row cannot un-hide an empty USE column. Losing the cell entirely would cost
    the operator the real portage string for exactly the boring-looking packages."""
    v = _vdb("test debug doc", "")
    cell = fb.vdb_use_cells(v)["USE"]
    assert cell.badges == ()
    assert cell.copy_text == ""
    for name in ("test", "debug", "doc"):
        assert name in cell.verbatim_text


def test_verbatim_copy_keeps_every_flag_even_when_the_view_hides_them():
    """§5's copy guarantee survives the filter — the view narrows, the copy does not."""
    v = _vdb("+ssl nls test debug", "ssl nls")
    cell = fb.vdb_use_cells(v)["USE"]
    assert "test" not in cell.copy_text and "debug" not in cell.copy_text
    for name in ("ssl", "nls", "test", "debug"):
        assert name in cell.verbatim_text, f"{name} missing from the verbatim string"


def test_verbatim_defaults_to_copy_text_for_unfiltered_cells():
    cell = fb.FlagCell(badges=(), copy_text='USE="a b"')
    assert cell.verbatim_text == 'USE="a b"'


@pytest.mark.parametrize("attr", ["changed", "removed", "forced_masked", "new_in_iuse"])
def test_state_carrying_flags_survive_the_filter_regardless_of_default(attr):
    """A transition or a profile force/mask is interesting even if not default-on:
    dropping those would hide exactly what the badge design exists to surface."""
    tok = pf.classify_flag_token("-quux")
    assert tok is not None and not tok.enabled
    marked = dataclasses.replace(tok, **{attr: True})
    assert fb._interesting(marked, frozenset()) is True
    assert fb._interesting(tok, frozenset()) is False        # the control
