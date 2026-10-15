"""The Docker route, round 2 (hugmesh-generator#654): a design is checked the way the Docker
start checks a mesh, and a record file that was refused says so where the person is looking.

The measured defect: a Domains row titled "Bob's Shop" (free text; the Docker start accepts
it) made the whole superbrand design refuse to commit, left the record file stale, and
said nothing on the steps after it.
"""
import os
import types

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import brand_model                                    # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrap        # noqa: E402
from hugmesh_studio.gui.pages import localmesh as lm_mod                       # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                    # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture
def ctl(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"])
    shim = types.SimpleNamespace(generator_dir=GENERATOR_DIR, localmesh_selected=True)
    page = lm_mod.LocalMeshPage(shim)
    page.show()
    page.mount_brand()
    yield page
    page.close()
    del page, app


def _type(step, field, value):
    box = step.fields[field]
    box.setText(value)
    box.editingFinished.emit()


def _add_apostrophe_row(page):
    md = page.mesh_domains
    page.domains_table.fill(md.domains, md.own_name)
    page.domains_table._add("shop.example", "Bob's Shop")
    assert page._commit_domains()


def test_an_apostrophe_title_on_a_brand_row_does_not_block_the_superbrand_design(ctl):
    step = ctl.superbrand_design
    _type(step, "id", "acme")
    _type(step, "title", "Acme Mesh")
    ctl.leave_brand()
    _add_apostrophe_row(ctl)
    # the Docker start accepts this mesh ...
    cfg = ctl.collect_bootstrap()
    assert not [p for p in LocalMeshBootstrap(GENERATOR_DIR, cfg).validate()
                if "brand record" in p], LocalMeshBootstrap(GENERATOR_DIR, cfg).validate()
    # ... so editing the design afterwards is not refused over the other brand's title
    _type(step, "title", "Acme Mesh 2")
    assert step.note.isHidden(), step.note.text()
    assert ctl.collect_bootstrap().superbrand.get("title") == "Acme Mesh 2"


def test_a_refused_record_file_is_said_on_the_page_and_on_the_plan(ctl):
    step = ctl.superbrand_design
    _type(step, "id", "acme")
    _type(step, "title", "Acme Mesh")
    ctl.leave_brand()
    _add_apostrophe_row(ctl)
    assert ctl.leave_brand() is True              # leaving a step is never blocked
    sentence = ctl.brand_error.text()
    assert "brand record file was not written" in sentence, sentence
    assert "Bob's Shop" in sentence and "still starts" in sentence, sentence
    assert not ctl.brand_error.isHidden()
    ctl._refresh_plan()
    assert "BRAND RECORD: The brand record file was not written" in ctl.plan_view.toPlainText()
    # the mesh itself took the design
    assert ctl.collect_bootstrap().brand == "acme"
    # taking the row away writes the file again and the notice goes
    md = ctl.mesh_domains
    md.domains = [d for d in md.domains if d.name != "shop.example"]
    assert ctl.leave_brand() is True
    ctl._refresh_plan()
    assert "BRAND RECORD:" not in ctl.plan_view.toPlainText()
    assert brand_model.load_record().brands == []


def test_arriving_at_the_review_step_writes_the_record_file(ctl, monkeypatch):
    """A saved mesh restored straight onto the Review step never passed Domain services,
    so the Review step is the last place the record file is written before a start.
    (Mutation: drop ctl.leave_brand() from LocalMeshReviewPage.initializePage and the file
    stays absent.)"""
    step = ctl.superbrand_design
    _type(step, "id", "acme")
    _type(step, "title", "Acme Mesh")
    path = brand_model.record_path()
    if os.path.exists(path):
        os.remove(path)
    monkeypatch.setattr(ctl, "_probe_mesh_state", lambda: None)
    monkeypatch.setattr(ctl.saved_meshes, "refresh", lambda: None)
    wiz = types.SimpleNamespace(generator_dir=GENERATOR_DIR, localmesh_selected=True,
                                localmesh_join_selected=False, localmesh_page=ctl)
    page = lm_mod.LocalMeshReviewPage(wiz)
    try:
        page.initializePage()
        assert os.path.exists(path), "the Review step did not write the record file"
        assert brand_model.load_record().superbrand.id == "acme"
    finally:
        page.deleteLater()
