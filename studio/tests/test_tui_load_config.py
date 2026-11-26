"""tui — LOAD a saved configuration (the GUI sessions page's "Load config…", G34).

The TUI could only SAVE (the Build screen's ``s PATH``): a config a walk wrote, or one
the GUI wrote, could not be opened again here. ``Journey.load_config`` is the twin of
``StudioWizard.load_config`` — the one loader both faces share (``worklist.load_any``),
flat image config or worklist envelope — and is reached by the welcome screen's
``load PATH``, by the previous-builds review's ``l PATH`` (plain) / ``l`` (urwid), the
same three places the GUI puts the button's neighbours. A file that does not load is
SAID, never raised, and changes nothing.
"""
import io
import json
import os

import pytest

from hugmesh_studio.core.config import Domain, ImageConfig
from hugmesh_studio.core.json_files import load_problem
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry, load_any
from hugmesh_studio.tui import journey, plain


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _flat(tmp_path) -> str:
    path = tmp_path / "cloud.json"
    ImageConfig(mode="cloud", role="laptop", platform="x86", brand="acme",
                domains=[Domain(name="a.example")]).save(str(path))
    return str(path)


def _envelope(tmp_path) -> str:
    path = tmp_path / "mesh.json"
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       hostname="")
    WorklistConfig(base=base, entries=[
        WorklistEntry(role="pki", platform="x86"),
        WorklistEntry(role="backend", platform="rpi5")]).save(str(path))
    return str(path)


# ── the welcome screen's `load PATH` ────────────────────────────────────────────────
def test_the_welcome_screen_says_how_to_load_a_saved_configuration():
    text = "\n".join(journey.Journey(".").lines())
    assert "load PATH opens a saved configuration" in text


def test_load_opens_a_flat_config_and_the_mode_menu_keeps_its_mode(tmp_path):
    j = journey.Journey(str(tmp_path))
    j.feed(f"load {_flat(tmp_path)}")
    assert j.slug == "welcome"                       # lands where a Redo lands
    assert "loaded" in j.status and "Enter on the mode menu keeps its mode" in j.status
    assert (j.cfg.mode, j.cfg.role, j.cfg.brand) == ("cloud", "laptop", "acme")
    assert [d.name for d in j.cfg.domains] == ["a.example"]
    assert j.worklist is None
    j.feed("")                                       # Start building
    assert " * 9. Mesh desktop client" in j.lines()  # the loaded mode is the * row
    j.feed("")                                       # Enter keeps it
    assert (j.cfg.mode, j.cfg.role) == ("cloud", "laptop")


def test_load_opens_a_worklist_envelope_with_its_rows(tmp_path):
    j = journey.Journey(str(tmp_path))
    j.feed(f"load {_envelope(tmp_path)}")
    assert j.cfg.mode == "mesh"
    assert [e.id for e in j.worklist.entries] == ["pki.x86", "backend.rpi5"]
    assert "a worklist of 2 image(s)" in j.status
    j.feed("")
    j.feed("")                                       # Enter on the menu keeps the mesh
    assert j.cfg.mode == "mesh" and j.slug == "idp"


def test_a_saved_walk_loads_back_identical(tmp_path):
    """The point of the verb: what the Build screen's ``s`` wrote, ``load`` reads back
    to the same configuration (flat and envelope, through the one loader)."""
    walked = journey.Journey(str(tmp_path))
    walked.feed("")
    walked.feed("3")                                 # mesh -> idp
    walked.feed("")
    walked.feed("1")                                 # pki.x86
    walked.feed("")                                  # commit the worklist
    for _ in range(len(journey.PAGE_ORDER)):
        if walked.slug == "build":
            break
        walked.feed("n" if walked.slug.endswith("_choice") else "")
    assert walked.slug == "build"
    path = tmp_path / "walked.json"
    walked.feed(f"s {path}")
    again = journey.Journey(str(tmp_path))
    again.feed(f"load {path}")
    assert again.cfg.to_dict() == walked.cfg.to_dict()
    assert again.worklist.to_dict() == walked.worklist.to_dict()


def test_the_load_is_the_one_loader_the_gui_uses(tmp_path):
    base, wl = load_any(_envelope(tmp_path))
    j = journey.Journey(str(tmp_path))
    j.feed(f"load {_envelope(tmp_path)}")
    assert j.cfg.to_dict() == base.to_dict()
    assert j.worklist.to_dict() == wl.to_dict()


@pytest.mark.parametrize("raw", [
    b"{not json",
    '{"hostname": "café"}'.encode("cp1252"),         # Windows PowerShell 5.1 Set-Content
    b"[1, 2]",
    b"",
])
def test_a_file_that_does_not_load_is_said_and_changes_nothing(tmp_path, raw):
    bad = tmp_path / "bad.json"
    bad.write_bytes(raw)
    j = journey.Journey(str(tmp_path))
    j.cfg.brand = "keepme"
    before_cfg, before_cfg_dict = j.cfg, j.cfg.to_dict()
    j.feed(f"load {bad}")
    assert j.status.startswith(f"{bad} could not be loaded: ")
    assert j.cfg is before_cfg and j.cfg.to_dict() == before_cfg_dict
    assert j.worklist is None and j.slug == "welcome"


def test_the_ansi_code_page_file_is_told_how_to_fix_it(tmp_path):
    from hugmesh_studio.core import json_files
    bad = tmp_path / "ansi.json"
    bad.write_bytes('{"hostname": "café"}'.encode("cp1252"))
    j = journey.Journey(str(tmp_path))
    j.feed(f"load {bad}")
    assert "Save it again as UTF-8" in j.status
    # the very sentence the window's "Load config" dialog shows: one function, two faces
    with pytest.raises(UnicodeDecodeError) as caught:
        json_files.load(str(bad))
    assert j.status == load_problem(str(bad), caught.value)


def test_a_missing_file_and_an_empty_path_are_refused_inline(tmp_path):
    j = journey.Journey(str(tmp_path))
    j.feed(f"load {tmp_path / 'nope.json'}")
    assert "could not be loaded" in j.status and "nope.json" in j.status
    j.feed("load")
    assert "needs the path of a saved configuration" in j.status
    assert j.slug == "welcome"


def test_a_worklist_with_colliding_ids_is_refused_not_degraded(tmp_path):
    dup = tmp_path / "dup.json"
    ImageConfig(mode="mesh").save(str(dup))
    data = json.loads(dup.read_text(encoding="utf-8"))
    dup.write_text(json.dumps({"schema": "hugmesh-worklist/v1", "base": data, "entries": [
        {"role": "pki", "platform": "x86"}, {"role": "pki", "platform": "x86"}]}),
        encoding="utf-8")
    j = journey.Journey(str(tmp_path))
    before = j.cfg.to_dict()
    j.feed(f"load {dup}")
    assert "share id" in j.status
    assert j.cfg.to_dict() == before and j.worklist is None


# ── the plain face's review: `l PATH` ───────────────────────────────────────────────
def _plain(script: str, tmp_path) -> str:
    out = io.StringIO()
    assert plain.run_journey(inp=io.StringIO(script), out=out,
                             generator_dir=str(tmp_path)) == 0
    return out.getvalue()


def test_the_plain_review_loads_a_config_and_the_journey_resumes_on_it(tmp_path):
    path = _envelope(tmp_path)
    # welcome -> 2 (Review prior sessions) -> l PATH -> back on welcome with the load said
    text = _plain(f"2\nl {path}\nq\n", tmp_path)
    assert "l PATH=load a saved config" in text      # the commands line says so
    assert f"loaded {path}" in text and "a worklist of 2 image(s)" in text
    assert text.index("previous builds (newest first)") < text.index(f"loaded {path}")


def test_the_plain_review_refuses_a_bad_file_and_stays_open(tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text("{not json", encoding="utf-8")
    text = _plain(f"2\nload {bad}\nq\nq\n", tmp_path)
    assert f"not loaded: {bad} could not be loaded" in text
    assert "loaded the" not in text and "a worklist of" not in text


def test_sessions_only_load_starts_the_journey_with_the_config(tmp_path):
    path = _flat(tmp_path)
    out = io.StringIO()
    # `tui --sessions` has no journey underneath: a load starts one, which then reads EOF
    assert plain.run_sessions_review(inp=io.StringIO(f"l {path}\n"), out=out,
                                     generator_dir=str(tmp_path)) == 0
    text = out.getvalue()
    assert f"loaded {path}" in text and "welcome> " in text


def test_a_load_in_the_plain_face_does_not_touch_the_file(tmp_path):
    path = _flat(tmp_path)
    before = open(path, "rb").read()
    _plain(f"2\nl {path}\nq\n", tmp_path)
    assert open(path, "rb").read() == before and os.path.exists(path)


# ── the urwid face's review: the `l` key and its inline path prompt ─────────────────
_SIZE = (100, 30)


def _urwid_app(tmp_path, **kw):
    pytest.importorskip("urwid")
    from hugmesh_studio.tui import urwid_ui
    return urwid_ui.JourneyApp(str(tmp_path), **kw)


def _press(app, *keys):
    """Keys the way MainLoop sends them: the top widget first, what it leaves to
    ``unhandled_input`` (Enter on an Edit, Esc)."""
    for key in keys:
        left = app.root.keypress(_SIZE, key)
        if left:
            app.unhandled(left)


def _shown(app) -> str:
    return " ".join("\n".join(ln.decode("utf-8", "replace")
                              for ln in app.root.render(_SIZE).text).split())


def test_the_urwid_review_offers_the_l_key_and_loads_into_the_journey(tmp_path):
    path = _envelope(tmp_path)
    app = _urwid_app(tmp_path)
    app.feed("2")                                    # welcome: Review prior sessions
    assert "l=load a saved config" in _shown(app)
    _press(app, "l")
    assert app.sessions.review.mode == "load"
    assert "Path of a saved configuration" in _shown(app)
    _press(app, *path, "enter")                      # typed, then Enter
    assert app.sessions is None                      # the journey owns the screen again
    assert app.journey.cfg.mode == "mesh"
    assert [e.id for e in app.journey.worklist.entries] == ["pki.x86", "backend.rpi5"]
    assert f"loaded {path}" in _shown(app)
    assert "welcome>" in _shown(app)


def test_the_urwid_prompt_keeps_a_refused_path_one_edit_away(tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text("{not json", encoding="utf-8")
    app = _urwid_app(tmp_path)
    app.feed("2")
    before = app.journey.cfg.to_dict()
    _press(app, "l", *str(bad), "enter")
    assert app.sessions is not None and app.sessions.review.mode == "load"
    assert f"not loaded: {bad} could not be loaded" in _shown(app)
    assert app.journey.cfg.to_dict() == before
    _press(app, "esc")                               # back to the list, nothing loaded
    assert app.sessions.review.mode == "list"


def test_a_q_typed_into_the_path_is_text_not_a_quit(tmp_path):
    app = _urwid_app(tmp_path)
    app.feed("2")
    _press(app, "l", "q", "q")
    assert app.sessions.review.mode == "load"
    assert app.sessions.review._load_edit.edit_text == "qq"


def test_a_bare_review_without_a_journey_says_so_instead_of_loading(tmp_path):
    pytest.importorskip("urwid")
    from hugmesh_studio.tui import urwid_ui
    review = urwid_ui.SessionsReview(generator_dir=str(tmp_path))
    review.unhandled("l")
    assert review.mode == "list" and "no journey to load into" in review.status.text


def test_sessions_only_load_hands_the_screen_to_the_journey(tmp_path):
    path = _flat(tmp_path)
    app = _urwid_app(tmp_path, sessions_only=True)
    _press(app, "l", *path, "enter")
    assert app.sessions is None and not app.sessions_only
    assert app.journey.cfg.mode == "cloud"
