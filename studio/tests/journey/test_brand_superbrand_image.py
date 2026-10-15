"""J-SUPERBRAND-IMAGE — the image route in mesh mode, from the drop-down to the build
command and the builder's own plan, in BOTH faces, including the unaffiliated refusal
(hugmesh-generator#654, D8 and D20; operator decision 71 = A).

THE SCRIPT (one list of gestures, run through the window's Branding page and through the
text screens):

  A. AFFILIATED. ‘Create a new superbrand’ is the default; type its id, title,
     organisation and public name; pick a colour; press Next. Then:
       - the configuration holds the superbrand (cfg.brand, brand_title, org,
         cluster_domain) and the colour;
       - ``python -m hugmesh_studio --print-command --config FILE`` prints a build
         command that carries ``--brand acme --brand-title 'Acme Mesh' --org example
         --cluster-domain mesh.example`` — the SAME words from both faces;
       - the builder's ``--print-plan`` on that command says PLAN_BRAND=acme and
         PLAN_CLUSTER_DOMAIN=mesh.example (build-x86-host-stage4.sh resolves and
         validates every flag and builds nothing).

  B. UNAFFILIATED (D20: identity refused, look allowed). On an unaffiliated image:
       - the drop-down is disabled and the reason is drawn beside it, in both faces
         with the same sentence; no ‘Create a new superbrand’ item is offered;
       - a brand typed into the design is refused and the configuration keeps its own;
       - the LOOK still takes a colour;
       - the Studio's own check, the builder's ``--print-plan`` and the record writer
         each refuse a brand identity on it, with their own sentence (the four
         enforcement sites: the removal of any one is red here).

Nothing here starts a build, a stack or a dialog; the builder is run with --print-plan
only, which writes nothing.
"""
import json
import os
import shlex
import subprocess
import sys
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import brand_model                                   # noqa: E402
from hugmesh_studio.core.config import ImageConfig                            # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                           # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                   # noqa: E402
from hugmesh_studio.tui.journey import Journey                                # noqa: E402
from hugmesh_studio.tui.superbrand_step import UNAFFILIATED_REASON, session_for  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

IDENTITY = {"id": "acme", "title": "Acme Mesh", "org": "example",
            "public_name": "mesh.example"}
COLOUR = "#336699"


@pytest.fixture(scope="module")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-superbrand-image-journey"])


def _base_cfg(**kw) -> ImageConfig:
    cfg = ImageConfig()
    cfg.mode, cfg.role, cfg.platform = "mesh", "backend", "x86"
    for k, v in kw.items():
        setattr(cfg, k, v)
    return cfg


# ── the two faces, over the same starting configuration ─────────────────────────────
class WindowFace:
    name = "window"

    def __init__(self, cfg):
        self.cfg = cfg
        self.wiz = SimpleNamespace(cfg=cfg, generator_dir=GENERATOR_DIR)
        self.page = wizard_mod.BrandingPage(self.wiz)
        self.page.initializePage()

    @property
    def drop_down(self):
        p = self.page.superbrand.picker
        return p.item_labels(), p.current_key(), p.combo.isEnabled(), p.note.text()

    def type(self, **fields):
        refusals = []
        for f, v in fields.items():
            box = self.page.superbrand.fields[f]
            box.setText(v)
            box.editingFinished.emit()
            note = self.page.superbrand.note
            refusals.append("" if note.isHidden() else note.text())
        return refusals

    def colour(self, hexvalue):
        ed = self.page.superbrand.look_editor
        ed.primary.setText(hexvalue)
        ed.primary.editingFinished.emit()

    def next(self):
        assert self.page.validatePage()

    @property
    def identity_hidden(self):
        return self.page.superbrand.identity_box.isHidden()

    @property
    def reason(self):
        s = self.page.superbrand
        return s.reason.text() if not s.reason.isHidden() else ""


class TextFace:
    name = "text"

    def __init__(self, cfg):
        self.j = Journey(GENERATOR_DIR)
        self.j.cfg = cfg
        self.cfg = cfg
        self.j.goto("branding")
        self.j.feed("s")

    @property
    def drop_down(self):
        text = "\n".join(self.j.lines())
        items = [ln.strip().lstrip("*").strip().split(". ", 1)[1]
                 for ln in text.splitlines()
                 if ln.strip().lstrip("*")[:1].isdigit() and ". " in ln.strip()[:6]]
        selected = [ln for ln in text.splitlines() if ln.strip().startswith("*1.")]
        return items, "create" if selected else "", UNAFFILIATED_REASON not in text, \
            UNAFFILIATED_REASON if UNAFFILIATED_REASON in text else ""

    def type(self, **fields):
        cmd = {"id": "id", "title": "title", "org": "org", "public_name": "public"}
        refusals = []
        for f, v in fields.items():
            self.j.feed(f"{cmd[f]} {v}")
            refusals.append(self.j.status)
        return refusals

    def colour(self, hexvalue):
        self.j.feed("look")
        self.j.feed(f"1 {hexvalue}")
        self.j.feed("back")

    def next(self):
        self.j.feed("")                      # commit and close the screen
        assert self.j.overlay is None

    @property
    def identity_hidden(self):
        return "1. Identity" not in "\n".join(self.j.lines())

    @property
    def reason(self):
        text = "\n".join(self.j.lines())
        return UNAFFILIATED_REASON if UNAFFILIATED_REASON in text else ""


FACES = [WindowFace, TextFace]


# ── helpers: the build command and the builder's plan ───────────────────────────────
def _print_command(cfg, tmp_path):
    f = tmp_path / f"{cfg.brand}-cfg.json"
    f.write_text(json.dumps(cfg.to_dict()))
    run = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(f)],
        cwd=STUDIO_ROOT, capture_output=True, text=True, timeout=120)
    return run


def _plan(command: str, tmp_path, extra=()):
    """The builder's own --print-plan for a printed build command: the same flags, the
    workdir moved into the scratch folder, nothing built."""
    argv = shlex.split(command)
    while argv and argv[0] in ("sudo", "bash"):
        argv.pop(0)
    out = []
    skip = 0
    for a in argv:
        if skip:
            skip -= 1
            continue
        if a in ("-w", "--shared-assets"):
            skip = 1
            continue
        out.append(a)
    run = subprocess.run(
        ["bash", *out, "-w", str(tmp_path / "w"), "--print-plan", *extra],
        cwd=GENERATOR_DIR, capture_output=True, text=True, timeout=120)
    plan = dict(ln.split("=", 1) for ln in run.stdout.splitlines()
                if ln.startswith("PLAN_") and "=" in ln)
    return run.returncode, plan, run.stdout + run.stderr


# ── A. affiliated ────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("face_cls", FACES, ids=[f.name for f in FACES])
def test_a_created_superbrand_reaches_the_build_command_and_the_builders_plan(
        qapp, tmp_path, face_cls):
    cfg = _base_cfg()
    face = face_cls(cfg)
    labels, current, enabled, note = face.drop_down
    assert labels[0] == "Create a new superbrand" and current == "create" and enabled
    assert face.type(**IDENTITY) == ["", "", "", ""]
    face.colour(COLOUR)
    face.next()
    assert (cfg.brand, cfg.brand_title, cfg.org, cfg.cluster_domain) == (
        "acme", "Acme Mesh", "example", "mesh.example")
    assert cfg.login_primary_color == COLOUR
    run = _print_command(cfg, tmp_path)
    assert run.returncode == 0, run.stderr
    cmd = run.stdout.strip().splitlines()[-1]
    argv = shlex.split(cmd)
    for flag, value in (("--brand", "acme"), ("--brand-title", "Acme Mesh"),
                        ("--org", "example"), ("--cluster-domain", "mesh.example")):
        assert argv[argv.index(flag) + 1] == value, (flag, cmd)
    rc, plan, text = _plan(cmd, tmp_path)
    assert rc == 0, text
    assert plan["PLAN_BRAND"] == "acme" and plan["PLAN_CLUSTER_DOMAIN"] == "mesh.example"
    assert plan["PLAN_UNAFFILIATED"] == "false"


def test_both_faces_write_the_same_command_and_the_same_configuration(qapp, tmp_path):
    outs = {}
    for face_cls in FACES:
        cfg = _base_cfg()
        face = face_cls(cfg)
        face.type(**IDENTITY)
        face.colour(COLOUR)
        face.next()
        outs[face.name] = (json.dumps(cfg.to_dict(), sort_keys=True),
                           _print_command(cfg, tmp_path).stdout)
    assert outs["window"] == outs["text"]


def test_a_brand_id_the_builder_would_refuse_never_reaches_the_command(qapp, tmp_path):
    """Red when the id rule is not applied in either face: ‘Bad ID’ is refused with its
    reason, and the configuration still holds the shipped id."""
    for face_cls in FACES:
        cfg = _base_cfg()
        face = face_cls(cfg)
        refusal, = face.type(id="Bad ID")
        assert "DNS label" in refusal, (face.name, refusal)
        face.next()
        assert cfg.brand == "hugmesh", face.name


# ── B. unaffiliated: identity refused, look allowed ──────────────────────────────────
@pytest.mark.parametrize("face_cls", FACES, ids=[f.name for f in FACES])
def test_on_an_unaffiliated_image_the_drop_down_says_why_and_the_look_is_still_the_persons(
        qapp, tmp_path, face_cls):
    cfg = _base_cfg(unaffiliated=True)
    face = face_cls(cfg)
    labels, current, enabled, note = face.drop_down
    assert "Create a new superbrand" not in labels and not enabled
    assert face.reason == UNAFFILIATED_REASON
    assert face.identity_hidden
    face.type(id="acme", title="Acme Mesh")
    face.colour(COLOUR)
    face.next()
    assert cfg.brand == "hugmesh" and cfg.brand_title == "HugMesh Systems", \
        "no identity reached the configuration"
    assert cfg.login_primary_color == COLOUR, "the look did"


def test_the_four_places_that_refuse_a_brand_identity_on_an_unaffiliated_image(
        qapp, tmp_path):
    # 1. the record writer
    sb = brand_model.Superbrand(id="acme", title="Acme Mesh", org="example")
    with pytest.raises(brand_model.RecordRefused, match="unaffiliated image carries no brand"):
        brand_model.save_record(brand_model.BrandRecord(superbrand=sb),
                                str(tmp_path / "r.json"), unaffiliated=True)
    assert not (tmp_path / "r.json").exists()
    # the session reaches it: an unaffiliated session refuses every identity edit
    wiz = SimpleNamespace(cfg=_base_cfg(unaffiliated=True), generator_dir=GENERATOR_DIR)
    assert session_for(wiz, "image", wiz.cfg, GENERATOR_DIR).set_identity(
        "title", "Acme Mesh") == UNAFFILIATED_REASON
    # 2. the Studio's own check, in the command printer
    bad = _base_cfg(unaffiliated=True)
    bad.brand, bad.brand_title = "acme", "Acme Mesh"
    run = _print_command(bad, tmp_path)
    assert run.returncode == 2 and "ZERO HugMesh affiliation" in run.stderr
    # 3. the builder's refusal
    desktop = ImageConfig()
    desktop.mode, desktop.role, desktop.platform = "standalone", "standalone-unaffiliated", "x86"
    ok = _print_command(desktop, tmp_path)
    assert ok.returncode == 0, ok.stderr
    cmd = ok.stdout.strip().splitlines()[-1]
    rc, plan, text = _plan(cmd, tmp_path)
    assert rc == 0 and plan["PLAN_UNAFFILIATED"] == "true", text
    rc, plan, text = _plan(cmd, tmp_path, extra=("--brand", "acme"))
    assert rc != 0 and "carry no brand identity" in text, text
    # ...and with nothing naming a brand it keeps the neutral one
    _rc, neutral, _t = _plan(cmd, tmp_path)
    assert neutral["PLAN_BRAND"] == "gentoo"
