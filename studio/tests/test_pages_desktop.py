"""The Desktop step (gui/pages/desktop.py), on Qt's offscreen platform.

Operator ask 2026-11-11: "allow for a step to configure each desktop, login, window
managers on board, compositers, per build being made, users, roles, installed apps and if
they're native or flatpak, video drivers, and the ai assistant will help it run emerge
pretend and resolve any build flag or package useflag issues. It can also configure python."

Pinned here: the step is on the walk exactly when the build produces a desktop; untouched
it changes no argv; every section reaches the builder through the model; problems are
inline (never a dialog); the pretend result card applies portage's OWN suggestion only on
a click and records it; the assistant's portage card goes through the same page methods;
a mesh edits each desktop row's own spec. ``test_look_*`` render the page at 1200x800 and
942x552 and assert its geometry (set HUGMESH_SHOT_DIR to keep the PNGs).
"""
from __future__ import annotations

import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import assistant_portage as aport              # noqa: E402
from hugmesh_studio.core import desktop_pretend as dp                    # noqa: E402
from hugmesh_studio.core import desktop_spec as ds                       # noqa: E402
from hugmesh_studio.core.config import ImageConfig                       # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                   # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry   # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                      # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                      # noqa: E402
from _helpers import advance_to, pick_mode, pick_role                    # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")
FIXTURES = os.path.join(GENERATOR_DIR, "tests", "scripts", "fixtures", "desktop-pretend")


@pytest.fixture(autouse=True)
def _pinned(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": HOST)
    for name in ("information", "warning", "critical", "question", "about"):
        monkeypatch.setattr(QtWidgets.QMessageBox, name, staticmethod(
            lambda *a, **k: (_ for _ in ()).throw(AssertionError("a modal dialog opened"))))


@pytest.fixture(scope="session")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"])


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _desktop(wiz, mode="cloud", role="laptop"):
    pick_mode(wiz, mode)
    pick_role(wiz, role)
    return advance_to(wiz, wizard_mod.DesktopPage)


def _shot(widget, name):
    d = os.environ.get("HUGMESH_SHOT_DIR")
    if d:
        os.makedirs(d, exist_ok=True)
        widget.grab().save(os.path.join(d, name))


def _fixture_result(name, rc):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as fh:
        body = fh.read().splitlines()
    # what the builder prints around the resolver output (scripts/_pretend-lib.sh)
    lines = []
    if name == "needs.txt":
        lines = ["==> Pretend result: status=needs rc=1 seed_python=python3_13,python3_14 "
                 "video_cards=amdgpu,radeonsi",
                 "==> Pretend needs: accept_keywords =media-video/obs-studio-32.2.2 ~amd64",
                 "==> Pretend needs: package.use >=media-video/ffmpeg-7.1.5 opus x264"]
    elif name == "clean.txt":
        lines = ["==> Pretend result: status=clean rc=0 seed_python=python3_13 video_cards=intel"]
    lines += [dp.EXCERPT_BEGIN, *body, dp.EXCERPT_END]
    res = dp.parse(lines, rc)
    res.run_id = "20261111T120000Z"
    return res


# ── on the walk exactly when a desktop is built ─────────────────────────────────────

def test_the_step_sits_between_home_and_build(wiz):
    page = _desktop(wiz)
    assert isinstance(page, wizard_mod.DesktopPage)
    wiz.back()
    assert isinstance(wiz.currentPage(), wizard_mod.HomePage)


def test_applies_only_when_the_build_makes_a_desktop(wiz):
    page = wiz.page(wiz._page_ids["desktop"])
    assert page.applies_to(ImageConfig(mode="cloud", role="laptop", platform="x86"))
    assert page.applies_to(ImageConfig(mode="standalone", role="standalone-thin", platform="x86"))
    assert not page.applies_to(ImageConfig(mode="cloud", role="backend", platform="x86"))
    assert not page.applies_to(ImageConfig(mode="cloud", role="frite", platform="frite", desktop="none"))
    # mesh: a node-only worklist skips it, one desktop row brings it back
    cfg = ImageConfig(mode="mesh")
    wiz.worklist = WorklistConfig(base=cfg, entries=[WorklistEntry(role="backend", platform="x86")])
    assert not page.applies_to(cfg)
    wiz.worklist.entries.append(WorklistEntry(role="laptop", platform="x86"))
    assert page.applies_to(cfg)


def test_untouched_it_changes_no_argv_and_no_saved_bytes(wiz):
    page = _desktop(wiz)
    before = wiz.cfg.to_cli_args()
    saved_before = wiz.cfg.to_dict()
    assert page.validatePage()
    assert wiz.cfg.to_cli_args() == before
    assert "desktop_spec" not in wiz.cfg.to_dict() and wiz.cfg.to_dict() == saved_before
    wiz.next()
    assert isinstance(wiz.currentPage(), wizard_mod.BuildPage)


# ── every section reaches the builder ───────────────────────────────────────────────

def test_every_section_reaches_the_builder(wiz):
    # standalone: no SSO governance, so a Flathub app is allowed (see the next test)
    page = _desktop(wiz, mode="standalone", role="chromebook")
    page.env.setCurrentIndex(page.env.findData("xfce"))
    page.steam.setCurrentText("flatpak")
    page.session_checks["i3"].setChecked(True)
    page.session_checks["picom"].setChecked(True)
    page.default_session.setCurrentIndex(page.default_session.findData("i3"))
    page.cards_override.setChecked(True)
    page.card_checks["intel"].setChecked(True)
    page.card_checks["virgl"].setChecked(True)
    page._add_user_row("ann", False, "first-pw-1")
    page._add_user_row("bob", True, "first-pw-2")
    for r in range(page.apps_table.rowCount()):
        app_id = page.apps_table.item(r, 0).data(QtCore.Qt.ItemDataRole.UserRole)[0]
        combo = page.apps_table.cellWidget(r, 1)
        if app_id == "obs-studio":
            combo.setCurrentIndex(combo.findData("native"))
        if app_id == "firefox":
            combo.setCurrentIndex(combo.findData("flatpak"))
    page.py_checks["python3_13"].setChecked(True)
    page.py_single.setCurrentIndex(page.py_single.findData("python3_13"))
    page.use_lines.setPlainText(">=media-video/ffmpeg-7.1.5 opus x264")
    page.kw_lines.setPlainText("=media-video/obs-studio-32.2.2 ~amd64")
    assert page.validatePage(), page.problems.text()
    c = wiz.cfg
    a = c.to_cli_args()
    j = " ".join(a)
    assert "--desktop full" in j and "--steam flatpak" in j
    assert a[a.index("--desktop-sessions") + 1] == "i3 picom"
    assert a[a.index("--default-session") + 1] == "i3"
    assert a[a.index("--video-cards") + 1] == "intel virgl"
    assert a[a.index("--extra-local-users") + 1] == "ann bob:admin"
    assert a[a.index("--extra-local-pass-file") + 1] == ds.EXTRA_PASS_PLACEHOLDER
    assert "media-video/obs-studio" in a[a.index("--packages-add") + 1].split()
    assert a[a.index("--flatpak-apps") + 1] == "flathub:org.mozilla.firefox"
    assert a[a.index("--python-extra-targets") + 1] == "python3_13"
    assert a[a.index("--python-single-target") + 1] == "python3_13"
    assert a[a.index("--package-use") + 1] == ">=media-video/ffmpeg-7.1.5 opus x264"
    assert a[a.index("--accept-keywords") + 1] == "=media-video/obs-studio-32.2.2 ~amd64"
    # the passwords are a secret: typed for this run, never in the saved config
    assert ds.parse_passwords(c.extra_local_passes) == {"ann": "first-pw-1", "bob": "first-pw-2"}
    saved = str(c.to_dict())
    assert "first-pw" not in saved and "extra_local_passes" not in c.to_dict()
    # operator edits to the overlay are in the history
    hist = ds.spec_of(c).history
    assert {(h["kind"], h["source"]) for h in hist} == {("package.use", "operator"),
                                                        ("accept_keywords", "operator")}


def test_a_governed_desktop_refuses_a_flathub_app_inline(wiz):
    """A cloud/mesh desktop with SSO on is GOVERNED once its KEYS stick provisions it,
    and provisioning deletes flathub (keys-provision provision_desktop_governance), so a
    Flathub app there would never install: said before the build, not discovered after."""
    page = _desktop(wiz, mode="cloud", role="laptop")
    assert wiz.cfg.sso_enabled()
    for r in range(page.apps_table.rowCount()):
        if page.apps_table.item(r, 0).data(QtCore.Qt.ItemDataRole.UserRole)[0] == "firefox":
            combo = page.apps_table.cellWidget(r, 1)
            combo.setCurrentIndex(combo.findData("flatpak"))
    assert not page.validatePage()
    assert "hugmesh-discover" in page.problems.text()


def test_an_extra_account_without_a_password_is_refused_inline(wiz):
    page = _desktop(wiz)
    page._add_user_row("ann", False, "")
    assert not page.validatePage()
    assert page.problems.isVisible() and "first-login password for ann" in page.problems.text()


def test_an_extra_account_is_not_an_administrator_unless_ticked(wiz):
    page = _desktop(wiz)
    page._add_user_row("ann", False, "pw")
    assert page.validatePage()
    assert ds.spec_of(wiz.cfg).extra_users == [ds.ExtraUser("ann", False)]
    assert "ann:admin" not in " ".join(wiz.cfg.to_cli_args())


def test_picom_on_plasma_alone_is_refused_and_i3_unblocks_it(wiz):
    page = _desktop(wiz)
    page.env.setCurrentIndex(page.env.findData("plasma"))
    page.session_checks["picom"].setChecked(True)
    assert not page.validatePage()
    assert "kwin already composites" in page.problems.text()
    page.session_checks["i3"].setChecked(True)
    assert page.validatePage(), page.problems.text()


def test_the_environment_is_written_through_the_role_pins(wiz):
    page = _desktop(wiz, mode="standalone", role="standalone-thick")
    assert not page.env.isEnabled()
    assert "most-capable" in page.env_note.text()
    assert page.validatePage()
    assert wiz.cfg.capable or wiz.cfg.role == "standalone-thick"


def test_arm_desktop_shows_the_soc_cards_and_no_x86_only_section(wiz):
    page = wiz.page(wiz._page_ids["desktop"])
    wiz.cfg = ImageConfig(mode="cloud", role="orangepi5", platform="orangepi5")
    page.initializePage()
    assert "panfrost" in page.gpu_state.text()
    assert not page.cards_override.isVisibleTo(page)
    assert not any(cb.isEnabled() for cb in page.session_checks.values())
    assert not page.pretend_btn.isEnabled()
    assert "x86 images for now" in page.pretend_status.text()


def test_a_free_app_entry_is_checked_before_it_is_added(wiz):
    page = _desktop(wiz)
    page.free_app.setText("not an atom")
    page._add_free_app()
    assert "Not added" in page.free_note.text()
    page.free_app.setText("app-editors/vim")
    page._add_free_app()
    assert page.validatePage()
    assert "app-editors/vim" in wiz.cfg.to_cli_args()[wiz.cfg.to_cli_args().index("--packages-add") + 1]


# ── emerge --pretend: the result, portage's own fix, the history ────────────────────

def test_a_needs_result_offers_portages_own_fix_and_applies_it_on_a_click(wiz):
    page = _desktop(wiz)
    res = _fixture_result("needs.txt", 3)
    assert res.status == "needs"
    page.show_result(res)
    assert page.offer_box.isVisibleTo(page)
    assert "+>=media-video/ffmpeg-7.1.5 opus x264" in page.offer_text.text()
    assert "+=media-video/obs-studio-32.2.2 ~amd64" in page.offer_text.text()
    assert ds.spec_of(wiz.cfg).use_lines == []                 # nothing before the click
    page._offer_apply()
    spec = ds.spec_of(wiz.cfg)
    assert spec.use_lines == [">=media-video/ffmpeg-7.1.5 opus x264"]
    assert spec.keyword_lines == ["=media-video/obs-studio-32.2.2 ~amd64"]
    assert [(h["source"], h["pretend_run"]) for h in spec.history] == \
        [("autounmask", "20261111T120000Z")] * 2
    assert spec.last_pretend["status"] == "needs"
    assert page.offer_recheck.isVisibleTo(page) and page.offer_undo.isVisibleTo(page)
    page._offer_undo()
    assert ds.spec_of(wiz.cfg).use_lines == [] and ds.spec_of(wiz.cfg).keyword_lines == []
    assert [h["op"] for h in ds.spec_of(wiz.cfg).history] == ["add", "add", "undo", "undo"]


def test_the_real_obs_round_offers_both_changes_and_opens_the_log_at_portages_walls(wiz, qapp):
    """needs-real-obs-r1.txt is the REAL resolver output of the 2026-11-11 OBS round 1, run
    through the builder's own report: the USE wall came as a "(Change USE: ...)" hint and
    must be offered with the keyword change; the verbatim box opens at its END, where
    portage states the walls (its top is the "Performing Global Updates" noise)."""
    import subprocess
    script = (f'. "{os.path.join(GENERATOR_DIR, "scripts", "_pretend-lib.sh")}"; '
              '_hugmesh_pretend_conf_list() { printf python3_14; }; '
              f'hugmesh_pretend_report "{os.path.join(FIXTURES, "needs-real-obs-r1.txt")}" 1')
    p = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    res = dp.parse(p.stdout.splitlines(), p.returncode)
    page = _desktop(wiz)
    page.show_result(res)
    qapp.processEvents()
    assert "+>=media-video/ffmpeg-8.1.2 opus x264" in page.offer_text.text()
    assert "+=media-video/obs-studio-32.2.2 ~amd64" in page.offer_text.text()
    bar = page.pretend_log.verticalScrollBar()
    assert bar.maximum() > 0 and bar.value() == bar.maximum()


def test_a_clean_result_offers_nothing(wiz):
    page = _desktop(wiz)
    page.show_result(_fixture_result("clean.txt", 0))
    assert not page.offer_box.isVisibleTo(page)
    assert page.pretend_status.text().startswith("Clean")


def test_the_pretend_button_waits_its_turn_inline(wiz, monkeypatch):
    page = _desktop(wiz)
    monkeypatch.setattr(dp, "gate", lambda *a, **k: "Another build or emulated device is running")
    why = page.start_pretend()
    assert "Another build" in why and "Another build" in page.pretend_status.text()
    assert page._worker is None


def test_the_assistant_portage_card_applies_through_the_page(wiz):
    page = _desktop(wiz)
    page.show_result(_fixture_result("needs.txt", 3))
    answer = ("Portage asks for these.\n```portage\n"
              "package.use >=media-video/ffmpeg-7.1.5 opus x264\n"
              "package.use media-libs/mesa vulkan\n"
              "package.use */* -X\n"
              "accept_keywords =media-video/obs-studio-32.2.2 ~amd64\n```")
    prop = aport.parse(answer, wiz.cfg, page.last_result.needs)
    assert [x.problem == "" for x in prop.lines] == [True, True, False, True]
    assert prop.lines[1].note == aport.NOT_PORTAGES_OWN          # mesa: not portage's own
    applied = page.apply_portage_changes(prop.applicable(), source="assistant")
    assert len(applied) == 3
    spec = ds.spec_of(wiz.cfg)
    assert "*/* -X" not in spec.use_lines
    assert {h["source"] for h in spec.history} == {"assistant"}
    page.undo_portage_changes(applied, source="assistant")
    assert ds.spec_of(wiz.cfg).use_lines == []


# ── per build: a mesh edits each desktop row's own spec ─────────────────────────────

def test_a_mesh_edits_each_desktop_rows_own_spec(wiz):
    page = wiz.page(wiz._page_ids["desktop"])
    cfg = ImageConfig(mode="mesh")
    wiz.cfg = cfg
    a = WorklistEntry(role="laptop", platform="x86")
    b = WorklistEntry(role="desktop", platform="x86")
    node = WorklistEntry(role="backend", platform="x86")
    wiz.worklist = WorklistConfig(base=cfg, entries=[node, a, b])
    page.initializePage()
    assert page.target_row.isVisibleTo(page) and page.target.count() == 2   # the node row is not offered
    page.session_checks["i3"].setChecked(True)
    page.target.setCurrentIndex(1)                                        # -> row b
    assert not page.session_checks["i3"].isChecked()                       # b has its own spec
    page.session_checks["sway"].setChecked(True)
    assert page.validatePage()
    assert ds.DesktopSpec.from_dict(a.desktop_spec).sessions == ["i3"]
    assert ds.DesktopSpec.from_dict(b.desktop_spec).sessions == ["sway"]
    assert cfg.desktop_spec == {}                                          # the base is untouched
    out = dict((e.id, c) for e, c in wiz.worklist.materialize())
    # every row is checked on Next, not only the one on screen
    a.desktop_spec = {"sessions": ["picom"], "default_session": "sway"}
    assert not page.validatePage()
    assert f"laptop on x86 ({a.id}):" in page.problems.text()
    a.desktop_spec = {"sessions": ["i3"]}
    assert out[a.id].to_cli_args()[out[a.id].to_cli_args().index("--desktop-sessions") + 1] == "i3"
    assert "--desktop-sessions" not in out[node.id].to_cli_args()


# ── look at it ──────────────────────────────────────────────────────────────────────

def _rect_in(top, w):
    return QtCore.QRect(w.mapTo(top, QtCore.QPoint(0, 0)), w.size())


@pytest.mark.parametrize("size", [(1200, 800), (942, 552)])
def test_look_at_the_desktop_step(wiz, qapp, size):
    page = _desktop(wiz)
    page._add_user_row("ann", False, "pw")
    page.session_checks["i3"].setChecked(True)
    page.show_result(_fixture_result("needs.txt", 3))
    wiz.resize(*size)
    qapp.processEvents()
    scroll = page._content_scroll
    content = scroll.widget()
    # no horizontal scrolling at either size: the content is as wide as the viewport
    assert scroll.horizontalScrollBar().maximum() == 0
    assert content.width() <= scroll.viewport().width()
    boxes = (page.env_box, page.login_box, page.sess_box, page.video_box, page.users_box,
             page.apps_box, page.py_box, page.portage_box)
    for box in boxes:
        r = _rect_in(content, box)
        assert r.left() >= 0 and r.right() <= content.width(), box.title()
        assert box.height() > 30, box.title()
    # every wrapped label is as tall as its text needs (nothing clipped)
    for lab in content.findChildren(QtWidgets.QLabel):
        if lab.isVisibleTo(page) and lab.wordWrap() and lab.text():
            assert lab.height() >= lab.heightForWidth(lab.width()) - 1, lab.text()[:60]
    # the tables show every row without a scroll area of their own
    for table in (page.apps_table, page.users_table):
        assert table.verticalScrollBar().maximum() == 0
    # buttons are clickable-sized and inside the content
    for b in (page.pretend_btn, page.offer_apply, page.sso_btn, page.home_btn, page.add_user_btn):
        assert b.isVisibleTo(page) and b.height() >= 20 and b.width() >= 40, b.text()
        assert _rect_in(content, b).right() <= content.width(), b.text()
    # the subtitle fits the header (it was three lines and clipped at 942 once)
    assert page.subTitle().count(" ") < 40
    w, h = size
    for frac, tag in ((0, "top"), (2, "mid"), (4, "bottom")):
        bar = scroll.verticalScrollBar()
        bar.setValue(bar.maximum() * frac // 4)
        qapp.processEvents()
        _shot(wiz, f"desktop-step-{tag}-{w}x{h}.png")
    scroll.verticalScrollBar().setValue(0)


def test_an_arm_board_greys_the_deliveries_that_do_not_exist_there_and_says_why(wiz):
    """thunderbird-bin / libreoffice-bin have no arm64 build and Flathub ships Thunderbird,
    Blender and OBS for x86_64 only: on an ARM board those choices are greyed in the row's
    combo, and the row SAYS why in its visible text (not only a tooltip)."""
    page = wiz.page(wiz._page_ids["desktop"])
    wiz.cfg = ImageConfig(mode="cloud", role="rpi5-desktop", platform="rpi5")
    page.initializePage()
    rows = {page.apps_table.item(r, 0).data(QtCore.Qt.ItemDataRole.UserRole)[0]: r
            for r in range(page.apps_table.rowCount())}

    def offered(app_id):
        combo = page.apps_table.cellWidget(rows[app_id], 1)
        m = combo.model()
        return {combo.itemData(i): m.item(i).isEnabled() for i in range(combo.count())}, combo

    tb, tb_combo = offered("thunderbird")
    assert tb == {"": True, "native": False, "flatpak": False}
    assert not tb_combo.isEnabled()
    tb_text = page.apps_table.item(rows["thunderbird"], 2).text()
    assert "amd64" in tb_text and "x86_64" in tb_text
    lo, lo_combo = offered("libreoffice")
    assert lo == {"": True, "native": False, "flatpak": True} and lo_combo.isEnabled()
    assert "amd64" in page.apps_table.item(rows["libreoffice"], 2).text()
    assert offered("blender")[0]["flatpak"] is False
    assert offered("firefox")[0] == {"": True, "native": True, "flatpak": True}
    assert page.apps_table.item(rows["firefox"], 2).text() == ""
    _shot(page.apps_table, "desktop-step-rpi5-apps.png")
    # x86 offers every delivery
    wiz.cfg = ImageConfig(mode="cloud", role="laptop", platform="x86")
    page.initializePage()
    assert all(offered(i)[0].values() and all(offered(i)[0].values()) for i in rows)
