"""J-SUPERBRAND, offline tier, for the slice the Docker route's page owns
(hugmesh-generator#654, D8; operator decision 71 = A: the window and the text screens
offer the same controls).

THE SCRIPT (one list of gestures, run through the window's wizard and through the text
screens):

  1. From the first page choose the local mesh and generate.
  2. Leave the brand box on its default, ‘Create a new superbrand’, and design it: an id,
     a title, an organisation and a colour.
  3. Go on to the end of the steps (the review).

What each face must then show: the configuration the bring-up reads carries the brand and
the designed block, the plan names it, and THE RECORD FILE BOTH FACES SAVED IS BYTE FOR BYTE
THE SAME. The text face's printed command is then RUN (its ``plan`` subcommand reads
nothing live and starts nothing) and its output names the superbrand.

NOT HERE (the live tier): ``hugmesh-mesh-bootstrap up --record`` on a running Docker mesh
and the asserts on a second brand's sign-in lines need a Docker mesh. UNEXERCISED.
"""
import os
import shlex
import subprocess
import sys

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import brand_model                                    # noqa: E402
from hugmesh_studio.core.config import DOMAIN_IDP_OWN                          # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                         # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                            # noqa: E402
from hugmesh_studio.gui.pages import localmesh as lm_mod                       # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                    # noqa: E402
from hugmesh_studio.tui import journey                                         # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

DESIGN = {"id": "acme", "title": "Acme Mesh", "org": "example"}
COLOUR = "#336699"


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-docker-brand-journey"])


# ── the window ───────────────────────────────────────────────────────────────────────
def _window_walk(qapp, monkeypatch, state):
    """Welcome -> local mesh -> generate -> the design -> every step to the review.
    Returns ``(controller page, record bytes)``."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", state)
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    wiz.show()
    try:
        wiz.next()                                    # welcome's default card
        mode = wiz.currentPage()
        mode._buttons["localmesh"].setChecked(True)
        mode._on_mode_toggled()
        wiz.next()
        wiz.currentPage()._buttons["generate"].setChecked(True)
        wiz.next()
        env = wiz.currentPage()
        assert isinstance(env, lm_mod.LocalMeshEnvPage)
        ctl = wiz.page(wiz._page_ids["localmesh"])
        picker = ctl.brand_picker
        # the default, untouched: ‘Create a new superbrand’ is first and selected
        assert picker.item_labels()[0] == "Create a new superbrand"
        assert picker.current_key() == "create"
        step = ctl.superbrand_design
        for field, value in DESIGN.items():
            step.fields[field].setText(value)
            step.fields[field].editingFinished.emit()
        ed = step.look_editor
        ed.primary.setText(COLOUR)
        ed.primary.editingFinished.emit()
        for _ in range(14):
            if isinstance(wiz.currentPage(), lm_mod.LocalMeshReviewPage):
                break
            before = wiz.currentId()
            wiz.next()
            assert wiz.currentId() != before, \
                f"stuck on {type(wiz.currentPage()).__name__}"
        assert isinstance(wiz.currentPage(), lm_mod.LocalMeshReviewPage)
        cfg = ctl.collect_bootstrap()
        plan = ctl.plan_view.toPlainText()
        with open(brand_model.record_path(), "rb") as fh:
            raw = fh.read()
        return cfg, plan, raw
    finally:
        wiz.close()
        wiz.deleteLater()


# ── the text screens ─────────────────────────────────────────────────────────────────
def _text_walk(monkeypatch, state):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", state)
    j = journey.Journey(GENERATOR_DIR)
    j.feed("")
    j.feed("1")
    j.feed("2")
    lm = j.screen_for("localmesh")
    assert "Superbrand: Create a new superbrand (default)" in "\n".join(j.lines())
    j.feed("superbrand")
    assert "*1. Create a new superbrand" in "\n".join(j.lines())
    for cmd, value in DESIGN.items():
        j.feed(f"{cmd} {value}")
    j.feed("look")
    j.feed(f"1 {COLOUR}")
    j.feed("back")
    j.feed("")                                        # leave the design
    j.feed("")                                        # domains -> services
    j.feed("")                                        # services -> review
    assert lm.stage == "review", "\n".join(j.lines())
    with open(brand_model.record_path(), "rb") as fh:
        raw = fh.read()
    return j, raw


def test_both_faces_write_the_same_record_bytes(qapp, monkeypatch, tmp_path):
    cfg, plan, window_raw = _window_walk(qapp, monkeypatch, str(tmp_path / "window"))
    j, text_raw = _text_walk(monkeypatch, str(tmp_path / "text"))
    assert window_raw == text_raw, (window_raw.decode(), text_raw.decode())
    rec = brand_model.BrandRecord.from_dict(__import__("json").loads(window_raw))
    assert (rec.superbrand.id, rec.superbrand.title, rec.superbrand.org) == (
        "acme", "Acme Mesh", "example")
    assert rec.superbrand.look.get("primary") == COLOUR


def test_the_window_hands_the_bring_up_the_design(qapp, monkeypatch, tmp_path):
    cfg, plan, _raw = _window_walk(qapp, monkeypatch, str(tmp_path / "window"))
    assert cfg.brand == "acme"
    assert cfg.superbrand["title"] == "Acme Mesh"
    assert cfg.superbrand["look"]["primary"] == COLOUR
    assert "Brand:      acme  (Acme Mesh)" in plan


def test_the_text_command_runs_and_its_plan_names_the_superbrand(monkeypatch, tmp_path):
    j, _raw = _text_walk(monkeypatch, str(tmp_path / "text"))
    line = next(ln for ln in "\n".join(j.lines()).splitlines()
                if ln.strip().startswith("python3 -m hugmesh_studio"))
    argv = shlex.split(line)
    assert argv[argv.index("--brand") + 1] == "acme"
    env = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    out = subprocess.run([sys.executable] + argv[1:], cwd=STUDIO_ROOT, env=env,
                         capture_output=True, text=True, timeout=120)
    assert out.returncode == 0, out.stderr
    assert "Brand:      acme  (Acme Mesh)" in out.stdout, out.stdout


def test_the_same_design_through_the_record_flag_starts_from_the_same_plan(
        qapp, monkeypatch, tmp_path):
    """`plan --record FILE` on the window's record prints what the window's own plan
    printed for the brand: the record is the one answer."""
    cfg, plan, _raw = _window_walk(qapp, monkeypatch, str(tmp_path / "window"))
    env = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    out = subprocess.run([sys.executable, "-m", "hugmesh_studio.core.local_mesh_bootstrap",
                          "plan", "--env", "test", "--record", brand_model.record_path()],
                         cwd=STUDIO_ROOT, env=env, capture_output=True, text=True,
                         timeout=120)
    assert out.returncode == 0, out.stderr
    for text in (plan, out.stdout):
        assert "Brand:      acme  (Acme Mesh)" in text


def test_going_back_to_the_step_keeps_the_design_and_walking_on_again_changes_nothing(
        qapp, monkeypatch, tmp_path):
    """Back into ‘Environment and brand’ fires no initializePage: the drop-down and the
    design must still show what was chosen, and Next again must write the same record."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    wiz.show()
    try:
        wiz.next()
        wiz.currentPage()._buttons["localmesh"].setChecked(True)
        wiz.currentPage()._on_mode_toggled()
        wiz.next()
        wiz.currentPage()._buttons["generate"].setChecked(True)
        wiz.next()
        ctl = wiz.page(wiz._page_ids["localmesh"])
        step = ctl.superbrand_design
        step.fields["id"].setText("acme")
        step.fields["id"].editingFinished.emit()
        wiz.next()
        assert isinstance(wiz.currentPage(), lm_mod.LocalMeshDomainsPage)
        first = open(brand_model.record_path(), "rb").read()
        wiz.back()
        assert isinstance(wiz.currentPage(), lm_mod.LocalMeshEnvPage)
        assert step.fields["id"].text() == "acme"
        assert ctl.brand.currentText() == "acme"
        assert ctl.brand_picker.current_key() == "create"
        wiz.next()
        assert open(brand_model.record_path(), "rb").read() == first
    finally:
        wiz.close()
        wiz.deleteLater()


def _walk_to(wiz, cls):
    for _ in range(14):
        if isinstance(wiz.currentPage(), cls):
            return wiz.currentPage()
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, f"stuck on {type(wiz.currentPage()).__name__}"
    raise AssertionError(f"never reached {cls.__name__}")


def test_a_brand_with_its_own_sign_in_reaches_the_same_record_from_both_faces(
        qapp, monkeypatch, tmp_path):
    """Design the superbrand, then add brand B with its own sign-in on the Domains step:
    the record both faces save lists B, with its sign-in, after the superbrand block."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "window"))
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    wiz.show()
    try:
        wiz.next()
        wiz.currentPage()._buttons["localmesh"].setChecked(True)
        wiz.currentPage()._on_mode_toggled()
        wiz.next()
        wiz.currentPage()._buttons["generate"].setChecked(True)
        wiz.next()
        ctl = wiz.page(wiz._page_ids["localmesh"])
        for field, value in DESIGN.items():
            ctl.superbrand_design.fields[field].setText(value)
            ctl.superbrand_design.fields[field].editingFinished.emit()
        _walk_to(wiz, lm_mod.LocalMeshDomainsPage)
        ctl.domains_table._add("blog.example", "", idp=DOMAIN_IDP_OWN)
        _walk_to(wiz, lm_mod.LocalMeshReviewPage)
        window_raw = open(brand_model.record_path(), "rb").read()
        cfg = ctl.collect_bootstrap()
    finally:
        wiz.close()
        wiz.deleteLater()
    assert cfg.own_idp_domains == ("blog.example",)
    assert [r["name"] for r in cfg.domains] == ["blog.example"]

    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "text"))
    j = journey.Journey(GENERATOR_DIR)
    j.feed("")
    j.feed("1")
    j.feed("2")
    j.feed("superbrand")
    for cmd, value in DESIGN.items():
        j.feed(f"{cmd} {value}")
    j.feed("")
    j.feed("a blog.example")
    j.feed("s 2")                                     # Own Casdoor
    j.feed("")                                        # -> services
    j.feed("n")                                       # the added domain's page
    j.feed("")                                        # -> review
    assert j.screen_for("localmesh").stage == "review", "\n".join(j.lines())
    text_raw = open(brand_model.record_path(), "rb").read()
    # both faces list the same brand with the same sign-in. (The window's Domains table
    # fills an empty title with the name and the text screen leaves it empty: that is how
    # the two Domains steps already differed, not something this step does.)
    w = brand_model.BrandRecord.from_dict(__import__("json").loads(window_raw))
    t = brand_model.BrandRecord.from_dict(__import__("json").loads(text_raw))
    assert [(b.name, b.idp, b.optional_services) for b in w.brands] == \
        [(b.name, b.idp, b.optional_services) for b in t.brands]
    assert [(b.name, b.idp) for b in t.brands] == [("blog.example", "own")]
    assert w.superbrand.id == t.superbrand.id == "acme"


def test_coming_back_to_the_step_refreshes_the_drop_down(qapp, monkeypatch, tmp_path):
    """Back into the step fires no initializePage, so the showEvent re-mount is what makes
    the drop-down describe the world as it is now: a design saved while the person was on
    another step appears in it. (Mutation: delete LocalMeshEnvPage.showEvent's mount_brand
    call and this goes red.)"""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    wiz.show()
    try:
        wiz.next()
        wiz.currentPage()._buttons["localmesh"].setChecked(True)
        wiz.currentPage()._on_mode_toggled()
        wiz.next()
        wiz.currentPage()._buttons["generate"].setChecked(True)
        wiz.next()
        ctl = wiz.page(wiz._page_ids["localmesh"])
        assert isinstance(wiz.currentPage(), lm_mod.LocalMeshEnvPage)
        assert not any("later-design" in x for x in ctl.brand_picker.item_labels())
        wiz.next()
        assert isinstance(wiz.currentPage(), lm_mod.LocalMeshDomainsPage)
        brand_model.save_design("later-design", brand_model.Superbrand(
            title="Later", look={"primary": "#102030"}))
        wiz.back()
        assert isinstance(wiz.currentPage(), lm_mod.LocalMeshEnvPage)
        assert any("later-design" in x for x in ctl.brand_picker.item_labels()), \
            ctl.brand_picker.item_labels()
    finally:
        wiz.close()
        wiz.deleteLater()
