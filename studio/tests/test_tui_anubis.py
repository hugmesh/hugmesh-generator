"""The anubis choice on the TUI face — issue #384, parity half.

The GUI shows it as a dropdown (Default / Force on / Force off) on the Network page; the
TUI's Network step ports that ONE row and says the rest is not ported. Both write the same
field with the same words, lock it at Default under the same whole-set selections, and
produce the same argv — the last block drives both faces and compares.
"""
import pytest

from hugmesh_studio.core.config import (
    ANUBIS_LABELS, BUILTIN_DEFAULT_SERVICES, SERVICES_ALL, SERVICES_NONE, WIZARD_PAGE_SLUGS,
    ImageConfig, anubis_locked, anubis_shown,
)
from hugmesh_studio.core.domain_services import image_service_state
from hugmesh_studio.tui import journey
from hugmesh_studio.tui.network_step import NOT_PORTED_NOTE, NetworkScreen

DEFAULTS = " ".join(BUILTIN_DEFAULT_SERVICES)


def at_network(**cfg_kw) -> journey.Journey:
    kw = dict(mode="mesh", role="generic", platform="x86")
    kw.update(cfg_kw)
    j = journey.Journey(".", cfg=ImageConfig(**kw))
    j.goto("network")
    return j


def text(j) -> str:
    return "\n".join(j.lines())


# ------------------------------------------------------------------ the step is hosted

def test_network_is_a_real_screen_that_says_what_it_does_not_port():
    j = at_network()
    assert isinstance(j.screen_for("network"), NetworkScreen)
    assert not isinstance(j.screen_for("network"), journey.PendingStep)
    body = text(j)
    assert NOT_PORTED_NOTE in body and "anubis" in body and "Default" in body
    assert "network" in WIZARD_PAGE_SLUGS


def test_enter_continues_past_the_step_and_keeps_the_default():
    j = at_network()
    j.feed("")
    assert j.slug != "network" and j.cfg.anubis == ""


# --------------------------------------------------------------- setting the value

@pytest.mark.parametrize(("cmd", "field"), [
    ("on", "on"), ("off", "off"), ("default", ""), ("d", ""), ("OFF", "off")])
def test_a_command_sets_the_field(cmd, field):
    j = at_network(anubis="on" if field == "" else "")
    j.feed(cmd)
    assert j.cfg.anubis == field
    assert ANUBIS_LABELS[field] in j.status
    assert ANUBIS_LABELS[field] in text(j)


def test_one_cycles_default_on_off_and_back():
    j = at_network()
    seen = []
    for _ in range(4):
        j.feed("1")
        seen.append(j.cfg.anubis)
    assert seen == ["on", "off", "", "on"]


def test_a_junk_command_changes_nothing():
    j = at_network(anubis="off")
    j.feed("maybe")
    assert j.cfg.anubis == "off" and "unrecognised" in j.status


def test_the_chosen_value_reaches_the_argv():
    j = at_network()
    j.feed("off")
    argv = j.cfg._services_args()
    assert argv == ["--optional-services", "-anubis"]       # a lone veto keeps the defaults
    j.feed("on")
    assert j.cfg._services_args() == ["--optional-services", DEFAULTS + " anubis"]


def test_a_config_that_spelled_it_in_the_picker_shows_that_value():
    j = at_network(optional_services=["akkoma", "-anubis"])
    assert "Force off" in text(j)
    j.feed("1")                      # off -> default
    assert j.cfg.anubis == ""


# ------------------------------------------------- the whole-set lock, same as the GUI

@pytest.mark.parametrize("sentinel", [SERVICES_ALL, SERVICES_NONE])
def test_a_whole_set_selection_locks_the_row_at_default(sentinel):
    assert anubis_locked([sentinel]) and not anubis_locked(["akkoma"])
    j = at_network(optional_services=[sentinel], anubis="off")
    body = text(j)
    assert "Default (locked" in body and "Force off (" not in body
    j.feed("on")
    assert j.cfg.anubis == "off", "a locked row must not change"
    assert "not changed" in j.status
    j.feed("")                       # Enter settles the field, as the GUI's collect does
    assert j.cfg.anubis == ""
    assert "anubis" not in " ".join(j.cfg._services_args())


# ------------------------------------------- where the row does not apply, nothing is set

@pytest.mark.parametrize("cfg_kw", [
    dict(mode="standalone", role="standalone-thick"),
    dict(mode="standalone", role="standalone-unaffiliated"),
    dict(platform="jetson", role="jetson-server"),
])
def test_an_image_the_row_does_not_apply_to_cannot_be_set_and_is_cleared(cfg_kw):
    j = at_network(anubis="off", **cfg_kw)
    assert "cannot be changed here" in text(j)
    j.feed("on")
    assert "not changed" in j.status
    j.feed("")
    assert j.cfg.anubis == ""


# ------------------------- a standalone rpi5 'generic' bakes the cluster tree: the row applies

def test_a_standalone_rpi5_generic_image_offers_the_row_on_the_tui():
    """The GUI keeps the picker (and the anubis row) for standalone rpi5 'generic' —
    cluster-node class, its builder bakes the GitOps tree (G16) — so the TUI must not
    refuse it as 'bakes no cluster services'."""
    j = at_network(mode="standalone", role="generic", platform="rpi5")
    assert "cannot be changed here" not in text(j)
    j.feed("off")
    assert j.cfg.anubis == "off" and "not changed" not in j.status
    assert "-anubis" in " ".join(j.cfg._services_args())
    j.feed("")
    assert j.cfg.anubis == "off", "an applicable row keeps the operator's choice"


@pytest.mark.parametrize("cfg_kw", [
    dict(mode="mesh", role="generic", platform="x86"),
    dict(mode="cloud", role="laptop", platform="x86"),
    dict(mode="standalone", role="standalone-thick", platform="x86"),
    dict(mode="standalone", role="standalone-unaffiliated", platform="x86"),
    dict(mode="standalone", role="laptop", unaffiliated=True, platform="x86"),
    dict(mode="standalone", role="generic", platform="rpi5"),
    dict(mode="standalone", role="rpi5-desktop", platform="rpi5"),
    dict(mode="cloud", role="generic", platform="rpi5"),
    dict(mode="standalone", role="jetson-server", platform="jetson"),
])
def test_the_tui_and_the_gui_agree_on_whether_the_row_applies(cfg_kw):
    """Same config, same answer on both faces: the GUI shows the anubis row iff its
    services picker is on screen on a platform whose builder parses --optional-services."""
    pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")
    import os
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from hugmesh_studio.gui import wizard as wizard_mod
    from hugmesh_studio.gui.pages.network import NetworkPage
    from hugmesh_studio.gui.qt import QtWidgets
    from hugmesh_studio.tui.network_step import anubis_applies
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["anubis-parity"])
    gen = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    w = wizard_mod.StudioWizard(gen)
    try:
        pid = [i for i in w.pageIds() if isinstance(w.page(i), NetworkPage)][0]
        w.cfg = ImageConfig(**cfg_kw)
        w.setStartId(pid)
        w.restart()
        w.setStartId(-1)
        app.processEvents()
        page = w.page(pid)
        gui_applies = (not page._svc_items["anubis"].isHidden()
                       and not page._services_hidden)
        assert (anubis_applies(ImageConfig(**cfg_kw)) == "") == gui_applies, cfg_kw
    finally:
        w.close()
        w.deleteLater()
        app.processEvents()


# --------------------------------------------- the domain-services table reads the field

def test_the_domain_services_state_column_reads_the_forced_value():
    on = ImageConfig(anubis="on")
    off = ImageConfig(anubis="off", optional_services=["anubis"])   # the field wins
    assert image_service_state(on, "anubis") == "on (mesh-wide)"
    assert image_service_state(off, "anubis").startswith("off")
    assert image_service_state(ImageConfig(optional_services=["anubis"]),
                               "anubis") == "on (mesh-wide)"
    assert image_service_state(ImageConfig(), "anubis") == "off"
    assert anubis_shown(ImageConfig(optional_services=["no-anubis"])) == "off"


# ----------------------------------------------------------------- the urwid face

def test_the_urwid_face_renders_the_same_screen():
    pytest.importorskip("urwid")
    from hugmesh_studio.tui import urwid_ui
    app = urwid_ui.JourneyApp(".", start="network")
    app.journey.cfg = ImageConfig(mode="mesh", role="generic", platform="x86")
    app.sync()
    app.feed("off")
    canvas = app.frame.render((110, 30))
    shown = "\n".join(line.decode("utf-8", "replace") for line in canvas.text)
    assert "Force off" in shown and "network> " in shown
    assert app.journey.cfg.anubis == "off"


# --------------------------------------------- both faces, one config and one argv

def _picked(cfg) -> set:
    """The services the argv names, with the builder default spelled out: the GUI ticks
    the default set and so emits it, the TUI leaves the list empty, and both mean it."""
    argv = cfg._services_args()
    val = argv[argv.index("--optional-services") + 1] if "--optional-services" in argv \
        else DEFAULTS
    toks = set(val.split())
    if toks and all(t.startswith("-") for t in toks):
        toks |= set(BUILTIN_DEFAULT_SERVICES)      # the builders' lone-veto rule
    return toks


def test_the_gui_page_and_the_tui_step_write_the_same_field_and_argv():
    pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")
    import os
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from hugmesh_studio.core.config import ANUBIS_CHOICES
    from hugmesh_studio.gui import wizard as wizard_mod
    from hugmesh_studio.gui.pages.network import NetworkPage
    from hugmesh_studio.gui.qt import QtWidgets
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["anubis-parity"])
    gen = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    w = wizard_mod.StudioWizard(gen)
    try:
        pid = [i for i in w.pageIds() if isinstance(w.page(i), NetworkPage)][0]
        for value in ANUBIS_CHOICES:
            w.cfg = ImageConfig(mode="mesh", role="generic", platform="x86")
            w.setStartId(pid)
            w.restart()
            w.setStartId(-1)
            page = w.page(pid)
            page.anubis_mode.setCurrentIndex(ANUBIS_CHOICES.index(value))
            assert page.validatePage()
            j = at_network()
            j.feed({"": "default"}.get(value, value))
            assert j.cfg.anubis == w.cfg.anubis == value
            assert _picked(j.cfg) == _picked(w.cfg), value
            assert page.anubis_mode.itemText(ANUBIS_CHOICES.index(value)) == \
                ANUBIS_LABELS[value]
    finally:
        w.close()
        w.deleteLater()
        app.processEvents()
