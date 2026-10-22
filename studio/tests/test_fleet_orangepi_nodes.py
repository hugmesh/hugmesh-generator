"""Fleet lane: the Orange Pi node-role knobs and the board RAM (EXPERIMENTAL boards).

scripts/build-all-roles.sh takes ORANGEPI5_ROLES / ORANGEPI4LTS_ROLES (default
"desktop", so ORANGEPI5=1 is unchanged) and RAM_GB (--ram-gb on every Raspberry Pi /
Orange Pi node build; REQUIRED, 8 or more, when a role list names omnibus). The
fleet window and the text-mode fleet screen must both field them (GUI/TUI parity),
and both must refuse an omnibus run with no RAM, or too little, BEFORE a build starts
(inline, never a dialog). No fleet build is ever started here.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core.config import IdentityValidationError       # noqa: E402
from hugmesh_studio.core.fleet import FleetConfig                    # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


# ── core: the env knobs and the RAM gate ──────────────────────────────────────────
def test_defaults_emit_no_new_knobs():
    env = FleetConfig().to_env()
    for k in ("ORANGEPI5_ROLES", "ORANGEPI4LTS_ROLES", "RAM_GB"):
        assert k not in env, f"{k} must not be emitted at its default (byte identity)"


def test_orange_pi_roles_and_ram_reach_the_script():
    cfg = FleetConfig(orangepi5=True, orangepi5_roles="pki  omnibus", ram_gb="16",
                      orangepi4lts=True, orangepi4lts_roles="frontend")
    env = cfg.to_env()
    assert env["ORANGEPI5_ROLES"] == "pki omnibus"
    assert env["ORANGEPI4LTS_ROLES"] == "frontend"
    assert env["RAM_GB"] == "16"


@pytest.mark.parametrize("kw, needle", [
    ({"rpi_roles": "pki omnibus"}, "needs ram_gb"),
    ({"orangepi5": True, "orangepi5_roles": "omnibus"}, "needs ram_gb"),
    ({"rpi_roles": "full"}, "needs ram_gb"),                     # the omnibus alias
    ({"rpi_roles": "omnibus", "ram_gb": "4"}, "at least 8 GB"),
    ({"ram_gb": "8G"}, "whole number"),
    ({"ram_gb": "08"}, "whole number"),
    ({"orangepi5_roles": "pki;rm"}, "orangepi5_roles"),
])
def test_refusals(kw, needle):
    with pytest.raises(IdentityValidationError) as ei:
        FleetConfig(**kw).validate()
    assert needle in str(ei.value)


def test_omnibus_with_enough_ram_is_accepted():
    FleetConfig(rpi_roles="omnibus", ram_gb="8").validate()
    FleetConfig(orangepi5=True, orangepi5_roles="omnibus", ram_gb="32").validate()
    # a node role that does not need RAM is fine without it
    FleetConfig(orangepi5=True, orangepi5_roles="pki backend frontend").validate()


# ── TUI face: same knobs, same refusal ─────────────────────────────────────────────
def test_tui_fields_the_new_knobs_and_refuses_inline():
    from hugmesh_studio.tui import fleet as tui_fleet
    for k in ("orangepi5_roles", "orangepi4lts_roles", "ram_gb"):
        assert k in tui_fleet.FLEET_KNOBS

    class _J:                                   # the journey object the screen writes to
        status = ""
        data: dict = {}

    j = _J()
    j.data = {}
    scr = tui_fleet.FleetScreen()
    scr.enter(j)
    scr.feed(j, "set rpi_roles omnibus")
    assert j.status.startswith("refused:") and "ram_gb" in j.status
    scr.feed(j, "set ram_gb 8")
    scr.feed(j, "set rpi_roles omnibus")
    assert j.status == "rpi_roles -> omnibus", j.status
    assert scr.options(j).to_env()["RAM_GB"] == "8"


# ── GUI face: the widgets exist, are visible/enabled/sized, and refuse inline ─────────
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")
from hugmesh_studio.gui.pages import fleet as fleet_mod             # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def page(qapp):
    p = fleet_mod.FleetPage(GENERATOR_DIR)
    p.resize(1100, 1000)
    p.show()
    yield p
    p.hide()
    p.deleteLater()


def _to_roles_step(p):
    p.next_btn.click()
    QtWidgets.QApplication.processEvents()
    assert p.stack.currentIndex() == fleet_mod.STEP_ROLES


def test_new_controls_are_visible_enabled_and_sized(page):
    page.orangepi5.setChecked(True)
    page.orangepi4lts.setChecked(True)
    _to_roles_step(page)
    for w in (page.orangepi5_roles, page.orangepi4lts_roles, page.ram_gb):
        assert w.isVisible(), w
        assert w.isEnabled(), w
        assert w.width() >= 80 and w.height() >= 18, (w, w.width(), w.height())
    # the RAM group shows whenever a Pi or an Orange Pi node board takes part
    assert not page.ram_group.isHidden()
    page.skip_rpi.setChecked(True)
    page.orangepi5.setChecked(False)
    page.orangepi4lts.setChecked(False)
    assert page.ram_group.isHidden()


def test_gui_emits_and_round_trips(page):
    page.orangepi5.setChecked(True)
    page.orangepi5_roles.setText("pki omnibus")
    page.ram_gb.setCurrentIndex(page.ram_gb.findData("16"))
    cfg = page.collect()
    assert (cfg.orangepi5_roles, cfg.ram_gb) == ("pki omnibus", "16")
    other = fleet_mod.FleetPage(GENERATOR_DIR)
    other.apply(FleetConfig(orangepi4lts=True, orangepi4lts_roles="frontend", ram_gb="12"))
    got = other.collect()
    # a RAM the TUI set that is not an offered size is kept, not silently dropped
    assert (got.orangepi4lts_roles, got.ram_gb) == ("frontend", "12")
    other.deleteLater()


def test_omnibus_without_ram_is_refused_inline(page):
    page.rpi_roles.setText("omnibus")
    page.refresh_preview()
    assert page.cmd.toPlainText().startswith("INVALID:")
    assert "ram_gb" in page.cmd.toPlainText()
    # and the dispatch preflight refuses it too (the gate a RESTART goes through)
    problems = page.driver.preflight(page.collect(), None)
    assert any("ram_gb" in p for p in problems), problems
    page.ram_gb.setCurrentIndex(page.ram_gb.findData("8"))
    page.refresh_preview()
    assert "RAM_GB=8" in page.cmd.toPlainText()


def test_render_png(page, tmp_path):
    """Render the Roles & boards step offscreen (the operator LOOKS at it). The PNG
    lands in $HUGMESH_RENDER_DIR when set, else a temp dir; it must not be blank."""
    page.orangepi5.setChecked(True)
    page.orangepi4lts.setChecked(True)
    page.orangepi5_roles.setText("pki omnibus")
    page.orangepi4lts_roles.setText("frontend")
    page.ram_gb.setCurrentIndex(page.ram_gb.findData("16"))
    _to_roles_step(page)
    page.ram_group.ensurePolished()
    out_dir = os.environ.get("HUGMESH_RENDER_DIR") or str(tmp_path)
    os.makedirs(out_dir, exist_ok=True)
    pix = page.grab()
    assert pix.width() > 400 and pix.height() > 300
    path = os.path.join(out_dir, "fleet-orangepi-nodes-roles-step.png")
    assert pix.save(path)
    # the scroll area clips a tall step: grab the RAM group and the OPi groups too
    for name, w in (("ram", page.ram_group), ("opi5", page.orangepi5_group),
                    ("opi4lts", page.orangepi4lts_group)):
        assert w.grab().save(os.path.join(out_dir, f"fleet-orangepi-nodes-{name}-group.png"))
