"""J-BRAND-SCREEN — a superbrand and two brands, walked end to end in BOTH faces with one
script (hugmesh-generator#654, D9 and D10; operator decision 71 = A).

THE SCRIPT (one list of gestures, run once through the window's real widgets and once
through the text screens' command lines, on the Docker mesh route, where a brand's own
look can be shown):

  1. design the superbrand: id, title, organisation, public name, a colour and a font;
  2. add two brands (shop.example and blog.example) to the Domains step's state;
  3. open the Brand settings of shop.example: override its colour and its font;
  4. give the font back with the second click of "Use the superbrand's value" (the first
     click arms and changes nothing);
  5. read its Ways-to-reach-it tab: a read-only summary and one button, no way editable;
  6. leave the step: the mesh's brand record is written.

WHAT IS COMPARED. The two faces' record files, byte for byte, against the record the
script is EXPECTED to leave — a literal written below from the model's rules, not built
by the code under test — and then the record read by a FRESH process (C-RECORD:
``python -m hugmesh_studio.core.brand_model show / validate``), which must say the same
things in the model's words.

Nothing here starts a stack, a browser or a dialog. A brand's own look shows on the
Docker mesh only (D18); the live tier (press Generate and start, assert brand B's
sign-in) needs a Docker mesh and is unexercised.
"""
import json
import os
import subprocess
import sys
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import brand_model                                   # noqa: E402
from hugmesh_studio.core.config import Domain                                 # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig  # noqa: E402
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains           # noqa: E402
from hugmesh_studio.gui.pages import domain_services as ds_mod                # noqa: E402
from hugmesh_studio.gui.pages.superbrand import SuperbrandStep                # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                   # noqa: E402
from hugmesh_studio.tui.domain_services_step import DomainServicesScreen      # noqa: E402
from hugmesh_studio.tui.superbrand_step import SuperbrandScreen, session_for  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

#: The record this script is expected to leave, written from the model's rules (D5): the
#: superbrand block with its look and the two facts only the Docker start path has, and
#: both brands with the one override that survives the two-click.
EXPECTED = {
    "schema": 1,
    "superbrand": {
        "id": "acme", "title": "Acme Mesh", "org": "example",
        "public_name": "mesh.example",
        "look": {"font": "System UI", "primary": "#336699"},
        "central_signin": "http://localhost:8000",
        "ways": {"tor": False},
    },
    "brands": [
        {"name": "shop.example", "title": "Shop", "images": [],
         "optional_services": [], "idp": "superdomain",
         "look": {"primary": "#aa0000"}},
        {"name": "blog.example", "title": "Blog", "images": [],
         "optional_services": [], "idp": "superdomain"},
    ],
}


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-brand-screen-journey"])


@pytest.fixture
def gen(tmp_path):
    (tmp_path / "brands").mkdir()
    return str(tmp_path)


def _fresh():
    state = LocalMeshDomains(domains=[Domain(name="mesh.example")], own_name="mesh.example")
    return LocalMeshBootstrapConfig(), state


def _read_record() -> bytes:
    with open(brand_model.record_path(), "rb") as fh:
        return fh.read()


# ── the two faces ────────────────────────────────────────────────────────────────────
class WindowFace:
    """A person using the window: real widgets, real signals."""

    name = "window"

    def __init__(self, gen):
        self.boot, self.state = _fresh()
        self.owner = SimpleNamespace()
        self.session = session_for(self.owner, "docker", (self.boot, self.state), gen)
        self.step = SuperbrandStep(self.session, route="docker")
        self.step.show()
        self.widget = ds_mod.DomainServicesWidget(
            brand_session=lambda: self.session, route="docker")
        self.widget.show()

    def design(self, **fields):
        for f, v in fields.items():
            box = self.step.fields[f]
            box.setText(v)
            box.editingFinished.emit()
        assert self.step.note.isHidden(), self.step.note.text()

    def superbrand_look(self, primary, font):
        ed = self.step.look_editor
        ed.primary.setText(primary)
        ed.primary.editingFinished.emit()
        ed.font.setCurrentIndex(ed.font.findData(font))

    def add_brands(self, *rows):
        self.state.domains += [Domain(name=n, title=t) for n, t in rows]
        self.widget.load(self.state)

    def open_brand(self, name):
        while self.widget.current_domain() != name:
            self.widget._step(1)

    def override(self, primary, font):
        ed = self.widget.brand_tabs.look_editor
        ed.primary.setText(primary)
        ed.primary.editingFinished.emit()
        ed.font.setCurrentIndex(ed.font.findData(font))
        assert ed.source_labels["font"].text() == "this brand's own"

    def use_superbrands(self, field):
        ed = self.widget.brand_tabs.look_editor
        ed.use_buttons[field].click()
        armed = self.state.by_name("shop.example").look.get(field)
        ed.use_buttons[field].click()
        return armed

    def ways(self):
        tabs = self.widget.brand_tabs
        tabs.open_tab("Ways to reach it")
        asked = []
        tabs.ways_requested.connect(asked.append)
        tabs.ways_btn.click()
        # nothing on the tab can be typed in: every widget is a label or the one button
        editable = [w for w in tabs.ways_page.findChildren(QtWidgets.QWidget)
                    if isinstance(w, (QtWidgets.QLineEdit, QtWidgets.QComboBox,
                                      QtWidgets.QCheckBox))]
        assert editable == []
        return tabs.ways_text.text(), asked

    def look_tab(self):
        self.widget.brand_tabs.open_tab("Look")

    def leave(self):
        self.widget.record(self.state)
        assert self.widget.commit_brand(save=True) == []
        self.step.commit()


class TextFace:
    """A person typing at the text screens."""

    name = "text"

    def __init__(self, gen):
        self.boot, self.state = _fresh()
        self.j = SimpleNamespace(status="", generator_dir=gen, overlay=None,
                                 advance=lambda: None)
        self.session = session_for(self.j, "docker", (self.boot, self.state), gen)
        self.sb = SuperbrandScreen(session_of=lambda j: self.session, route="docker")
        self.sb.enter(self.j)
        self.ds = DomainServicesScreen(
            cfg_of=lambda j: self.state, brand_session_of=lambda j: self.session,
            route="docker")

    def design(self, **fields):
        cmd = {"id": "id", "title": "title", "org": "org", "public_name": "public"}
        for f, v in fields.items():
            self.sb.feed(self.j, f"{cmd[f]} {v}")
            assert self.j.status in ("", None), self.j.status

    def superbrand_look(self, primary, font):
        self.sb.feed(self.j, "look")
        self.sb.feed(self.j, f"1 {primary}")
        self.sb.feed(self.j, f"font {font}")
        self.sb.feed(self.j, "back")

    def add_brands(self, *rows):
        self.state.domains += [Domain(name=n, title=t) for n, t in rows]
        self.ds.enter(self.j)

    def open_brand(self, name):
        while self.ds.current(self.j).name != name:
            self.ds.feed(self.j, "n")

    def override(self, primary, font):
        self.ds.feed(self.j, "open 2")
        self.ds.feed(self.j, f"1 {primary}")
        self.ds.feed(self.j, f"font {font}")
        assert "this brand's own" in "\n".join(self.ds.lines(self.j))

    def use_superbrands(self, field):
        cmd = {"font": "font", "primary": "1"}[field]
        self.ds.feed(self.j, f"use {cmd}")
        armed = self.state.by_name("shop.example").look.get(field)
        self.ds.feed(self.j, f"use {cmd}")
        return armed

    def ways(self):
        self.ds.feed(self.j, "open 4")
        text = "\n".join(self.ds.lines(self.j))
        self.ds.feed(self.j, "tor on")            # nothing to edit here
        assert "Nothing to change" in self.j.status
        return text, ["shop.example"]

    def look_tab(self):
        self.ds.feed(self.j, "open 2")

    def leave(self):
        self.ds.feed(self.j, "")
        self.sb.feed(self.j, "")


def _script(face):
    face.design(id="acme", title="Acme Mesh", org="example", public_name="mesh.example")
    face.superbrand_look("#336699", "System UI")
    face.add_brands(("shop.example", "Shop"), ("blog.example", "Blog"))
    face.open_brand("shop.example")
    face.look_tab()
    face.override("#aa0000", "Geometric")
    assert face.state.by_name("shop.example").look == {"primary": "#aa0000",
                                                       "font": "Geometric"}
    armed = face.use_superbrands("font")
    # the first click arms and changes nothing; the second applies
    assert armed == "Geometric"
    assert face.state.by_name("shop.example").look == {"primary": "#aa0000"}
    ways_text, asked = face.ways()
    assert "shop-example.acme.internal" in ways_text.replace("&nbsp;", " ")
    assert "Docker mesh" in ways_text and asked == ["shop.example"]
    face.leave()
    return _read_record()


def test_the_window_and_the_text_screens_leave_the_expected_record_byte_for_byte(
        qapp, gen, tmp_path, monkeypatch):
    window_bytes = _script(WindowFace(gen))
    os.remove(brand_model.record_path())
    text_bytes = _script(TextFace(gen))
    assert window_bytes == text_bytes, (window_bytes.decode(), text_bytes.decode())
    assert json.loads(window_bytes) == EXPECTED
    assert window_bytes.decode().endswith("\n"), "one byte shape, no clock value"


def test_a_fresh_process_reads_the_record_in_the_models_words(qapp, gen):
    """C-RECORD: the record the script left is read by a new interpreter: the superbrand,
    each brand with its look and where it comes from, and every way's effect."""
    _script(WindowFace(gen))
    rec = brand_model.record_path()
    run = lambda *a: subprocess.run(            # noqa: E731
        [sys.executable, "-m", "hugmesh_studio.core.brand_model", *a, "--record", rec],
        cwd=STUDIO_ROOT, capture_output=True, text=True, timeout=120)
    shown = run("show")
    assert shown.returncode == 0, shown.stderr
    out = shown.stdout
    assert "superbrand: acme — Acme Mesh" in out
    assert "shop-example" in out and "blog-example" in out
    assert "this brand's own" in out and "inherited from the superbrand" in out
    for word in ("tenant", "issuer", "slug", "epoch"):
        assert word not in out.lower(), word
    ok = run("validate")
    assert ok.returncode == 0 and ok.stdout.strip().endswith("ok"), ok.stdout + ok.stderr


def test_the_script_is_red_when_an_override_leaks_to_the_other_brand(qapp, gen):
    """The mutation this journey exists to catch: an override written to every brand.
    Break the write (copy the override to blog.example too) and the expected record no
    longer matches."""
    face = WindowFace(gen)
    face.design(id="acme", title="Acme Mesh", org="example", public_name="mesh.example")
    face.superbrand_look("#336699", "System UI")
    face.add_brands(("shop.example", "Shop"), ("blog.example", "Blog"))
    face.open_brand("shop.example")
    face.look_tab()
    face.override("#aa0000", "Geometric")
    face.use_superbrands("font")
    face.state.by_name("blog.example").look = {"primary": "#aa0000"}      # the defect
    face.leave()
    assert json.loads(_read_record()) != EXPECTED
