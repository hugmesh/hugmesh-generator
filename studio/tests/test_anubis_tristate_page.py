"""The anubis row on the Network page, as the operator meets it — issue #384, GUI half.

The row is a three-valued dropdown (Default / Force on / Force off), not a tick: the build
has its own ENV policy for the public proof-of-work gate (prod on, test off), so a tick
could say "on" but never "off". The core half (test_anubis_tristate.py) pins the field and
what it emits; this file pins that the PAGE drives the field, and what a person SEES.

Drives the real wizard offscreen. The ``test_look_*`` case at the bottom runs in a fresh
interpreter started by tests/test_look.py and saves a screenshot when HUGMESH_LOOK_SHOTS
is set.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import (                          # noqa: E402
    ANUBIS_CHOICES, ANUBIS_LABELS, BUILTIN_DEFAULT_SERVICES, SERVICES_ALL, SERVICES_NONE,
    ImageConfig,
)
from hugmesh_studio.core.platform_info import HostInfo            # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod               # noqa: E402
from hugmesh_studio.gui.pages.network import (                    # noqa: E402
    _PRESET_ALL, _PRESET_CUSTOM, _PRESET_NONE, _SVC_COL_MODE, _SVC_COL_ON, NetworkPage,
)
from hugmesh_studio.gui.qt import QtWidgets                       # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")
DEFAULTS = " ".join(BUILTIN_DEFAULT_SERVICES)
OFF, DEFAULT, ON = (ANUBIS_CHOICES.index(v) for v in ("off", "", "on"))


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-anubis-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def net_page(wiz, **cfg_kw):
    """The NetworkPage as the CURRENT page, initialised for ``cfg_kw`` (an x86 mesh node
    unless told otherwise)."""
    kw = dict(mode="mesh", role="generic", platform="x86")
    kw.update(cfg_kw)
    pid = [i for i in wiz.pageIds() if isinstance(wiz.page(i), NetworkPage)][0]
    wiz.cfg = ImageConfig(**kw)
    wiz.setStartId(pid)
    wiz.restart()
    wiz.setStartId(-1)
    QtWidgets.QApplication.processEvents()
    page = wiz.page(pid)
    assert wiz.currentPage() is page
    return page


def collect(wiz, page):
    assert page.validatePage()
    return wiz.cfg.to_cli_args()


def services_value(argv):
    """The ONE --optional-services value on ``argv``, or None when the flag is absent."""
    return argv[argv.index("--optional-services") + 1] if "--optional-services" in argv else None


# ------------------------------------------------------------------ the row is a dropdown

def test_the_anubis_row_is_a_three_valued_dropdown_not_a_tick(wiz):
    page = net_page(wiz)
    item = page._svc_items["anubis"]
    assert not item.isHidden()
    assert "anubis" not in page.service_boxes
    combo = page.anubis_mode
    assert [combo.itemText(i) for i in range(combo.count())] == \
        [ANUBIS_LABELS[v] for v in ANUBIS_CHOICES] == ["Default", "Force on", "Force off"]
    assert page.services_table.itemWidget(item, _SVC_COL_MODE) is combo
    assert page.services_table.itemWidget(item, _SVC_COL_ON) is None, \
        "a tick sits in the On cell of a row that has three answers"
    assert combo.currentIndex() == DEFAULT and combo.isEnabled()


def test_untouched_page_emits_what_it_emitted_before_the_row_was_a_dropdown(wiz):
    page = net_page(wiz)
    argv = collect(wiz, page)
    assert wiz.cfg.anubis == ""
    assert services_value(argv) == DEFAULTS
    assert "anubis" not in " ".join(argv)


@pytest.mark.parametrize(("index", "field", "want"), [
    (DEFAULT, "", DEFAULTS),
    (ON, "on", DEFAULTS + " anubis"),
    (OFF, "off", DEFAULTS + " -anubis"),
])
def test_each_state_reaches_the_argv_through_the_page(wiz, index, field, want):
    page = net_page(wiz)
    page.anubis_mode.setCurrentIndex(index)
    argv = collect(wiz, page)
    assert wiz.cfg.anubis == field
    assert services_value(argv) == want
    # never the subtractive spelling, which both builders refuse for anubis
    assert "--exclude-services" not in argv


def test_force_off_with_every_service_unticked_keeps_the_veto(wiz):
    """Every row unticked is the explicit-none answer; the veto must still reach the
    argv, as the none + veto shape the core emits (the lone token would give the defaults
    back)."""
    page = net_page(wiz)
    for box in page.service_boxes.values():
        box.setChecked(False)
    page.anubis_mode.setCurrentIndex(OFF)
    argv = collect(wiz, page)
    assert wiz.cfg.optional_services == [SERVICES_NONE] and wiz.cfg.anubis == "off"
    assert services_value(argv) == "-anubis"
    assert argv[argv.index("--exclude-services") + 1] == DEFAULTS


def test_the_choice_survives_leaving_the_page_and_coming_back(wiz):
    page = net_page(wiz)
    page.anubis_mode.setCurrentIndex(OFF)
    collect(wiz, page)
    page.initializePage()
    assert page.anubis_mode.currentIndex() == OFF


# --------------------------------------------------------- the whole-set presets lock it

@pytest.mark.parametrize(("preset", "sentinel", "flag"), [
    (_PRESET_ALL, SERVICES_ALL, "--all-services"),
    (_PRESET_NONE, SERVICES_NONE, "--optional-services"),
])
def test_a_whole_set_preset_locks_the_row_at_default(wiz, preset, sentinel, flag):
    page = net_page(wiz)
    page.anubis_mode.setCurrentIndex(OFF)
    page.services_preset.setCurrentIndex(preset)
    assert page.anubis_mode.currentIndex() == DEFAULT
    assert not page.anubis_mode.isEnabled()
    argv = collect(wiz, page)
    assert wiz.cfg.anubis == "" and wiz.cfg.optional_services == [sentinel]
    assert flag in argv
    assert "anubis" not in " ".join(argv), argv


def test_leaving_the_preset_gives_the_operators_choice_back(wiz):
    page = net_page(wiz)
    page.anubis_mode.setCurrentIndex(OFF)
    page.services_preset.setCurrentIndex(_PRESET_ALL)
    page.services_preset.setCurrentIndex(_PRESET_NONE)      # preset to preset: still held
    assert page.anubis_mode.currentIndex() == DEFAULT
    page.services_preset.setCurrentIndex(_PRESET_CUSTOM)
    assert page.anubis_mode.currentIndex() == OFF and page.anubis_mode.isEnabled()
    assert services_value(collect(wiz, page)) == DEFAULTS + " -anubis"


def test_a_force_off_saved_beside_the_all_preset_reads_default_not_a_hidden_off(wiz):
    """A config written headless with --all-services AND a force-off: the page locks the
    row at Default and says so, instead of showing Default over a veto it still emits."""
    page = net_page(wiz, optional_services=[SERVICES_ALL], anubis="off")
    assert page.services_preset.currentIndex() == _PRESET_ALL
    assert page.anubis_mode.currentIndex() == DEFAULT and not page.anubis_mode.isEnabled()
    collect(wiz, page)
    assert wiz.cfg.anubis == ""


# ------------------------------------------------------ pre-existing spellings keep their argv

@pytest.mark.parametrize(("picker", "shown"), [
    (["akkoma", "anubis"], ON),
    (["akkoma", "-anubis"], OFF),
    (["akkoma", "no-anubis"], OFF),
    (["akkoma", "tuwunel"], DEFAULT),
])
def test_a_config_that_spelled_it_in_the_picker_keeps_its_argv(wiz, picker, shown):
    before = ImageConfig(platform="x86", optional_services=list(picker))._services_args()
    page = net_page(wiz, optional_services=list(picker))
    assert page.anubis_mode.currentIndex() == shown
    collect(wiz, page)
    # `no-anubis` and `-anubis` are the builders' two spellings of one veto; the page
    # writes the canonical one.
    assert wiz.cfg._services_args() == [a.replace("no-anubis", "-anubis") for a in before]


def test_anubis_alone_in_the_picker_still_builds_anubis_alone(wiz):
    before = ImageConfig(platform="x86", optional_services=["anubis"])._services_args()
    assert before == ["--optional-services", "anubis"]
    page = net_page(wiz, optional_services=["anubis"])
    collect(wiz, page)
    assert wiz.cfg._services_args() == before


# ------------------------------------------------ where the row does not apply, nothing is emitted

def test_a_hidden_picker_collects_default_whatever_the_config_held(wiz):
    page = net_page(wiz, mode="standalone", role="standalone-thick", anubis="off")
    assert page._services_hidden
    collect(wiz, page)
    assert wiz.cfg.anubis == ""


def test_a_platform_with_no_optional_services_flag_drops_the_field(wiz):
    page = net_page(wiz, platform="jetson", role="jetson-server", anubis="off")
    collect(wiz, page)
    assert wiz.cfg.anubis == ""
    assert "-anubis" not in " ".join(wiz.cfg.to_cli_args())


def test_rpi5_offers_the_row_and_emits_the_same_token(wiz):
    page = net_page(wiz, platform="rpi5")
    assert not page._svc_items["anubis"].isHidden()
    page.anubis_mode.setCurrentIndex(OFF)
    assert services_value(collect(wiz, page)) == DEFAULTS + " -anubis"


# ----------------------------------------------------------------- what a person SEES

from _look import (LOOK_CASES, LOOK_IDS, DEFAULT_WINDOW,         # noqa: E402
                   child_only, looking, settle, snap)


def _cell_geometry(page, slug="anubis"):
    """``(combo box, MODE column span, row box)`` in the table viewport's coordinates."""
    tbl = page.services_table
    item = page._svc_items[slug]
    tbl.scrollToItem(item)
    settle(QtWidgets.QApplication.instance())
    hdr = tbl.header()
    x0 = hdr.sectionViewportPosition(_SVC_COL_MODE)
    span = (x0, x0 + hdr.sectionSize(_SVC_COL_MODE))
    row = tbl.visualItemRect(item)
    combo = page.anubis_mode
    top_left = combo.parentWidget().mapTo(tbl.viewport(), combo.pos())
    box = (top_left.x(), top_left.y(),
           top_left.x() + combo.width(), top_left.y() + combo.height())
    return box, span, row


@pytest.mark.parametrize(("style", "pt"), LOOK_CASES, ids=LOOK_IDS)
def test_look_the_anubis_dropdown_sits_whole_in_its_cell(qapp, style, pt):
    child_only()
    with looking(qapp, style, pt):
        w = wizard_mod.StudioWizard(GENERATOR_DIR)
        w.show()
        try:
            page = net_page(w)
            settle(qapp)
            assert (w.width(), w.height()) == DEFAULT_WINDOW
            combo = page.anubis_mode
            # bring the row on screen: the page scrolls, and so does the table
            sa = getattr(page, "_content_scroll", None)
            if sa is not None:
                sa.ensureWidgetVisible(combo)
            box, (x0, x1), row = _cell_geometry(page)
            assert combo.isVisible(), "the anubis dropdown is not on screen"
            left, top, right, bottom = box
            # inside its own column…
            assert x0 <= left and right <= x1, f"combo {left}..{right} vs column {x0}..{x1}"
            # …and inside its own row, without spilling onto the neighbours
            assert row.top() <= top and bottom <= row.bottom() + 1, \
                f"combo {top}..{bottom} vs row {row.top()}..{row.bottom()}"
            assert combo.width() >= 40 and combo.height() >= 16
            # every item's text fits, so none is elided (arrow + frame take the rest)
            fm = combo.fontMetrics()
            for i in range(combo.count()):
                need = fm.horizontalAdvance(combo.itemText(i))
                assert need + 24 <= combo.width(), \
                    f"{combo.itemText(i)!r} needs {need}px of {combo.width()}px"
            # nothing of the row's own text is covered by the dropdown: the name and the
            # description cells are to the left and right of the MODE column
            hdr = page.services_table.header()
            assert hdr.sectionViewportPosition(_SVC_COL_ON) + \
                hdr.sectionSize(_SVC_COL_ON) <= x0
            # the same geometry with the row locked by a preset
            page.anubis_mode.setCurrentIndex(OFF)
            snap(w, "anubis-force-off", style, pt)
            page.services_preset.setCurrentIndex(_PRESET_ALL)
            settle(qapp)
            assert not combo.isEnabled() and combo.currentText() == "Default"
            assert _cell_geometry(page)[0] == box, "locking the row moved the dropdown"
            snap(w, "anubis-locked-by-all", style, pt)
        finally:
            w.close()
            w.deleteLater()
            settle(qapp)
