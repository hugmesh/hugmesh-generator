"""tui — the NO_TUI degradation gate (issue #51 phase 1).

urwid must NEVER become a hard studio dependency: these tests run headlessly with
urwid absent (the gate is probed through monkeypatched seams, both directions), and
they pin that importing the TUI package pulls in neither urwid nor a Qt binding.
The gate itself is scripts/build-menu.sh's HAVE_TUI block, ported line for line.
"""
import importlib.util
import io
import os
import subprocess
import sys

import pytest

from hugmesh_studio.tui import app as tui_app

_STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


class _Tty(io.StringIO):
    def isatty(self):
        return True


def _rich_environment(monkeypatch, *, urwid_present=True):
    """Every gate condition satisfied; urwid presence is the parameter."""
    monkeypatch.delenv("NO_TUI", raising=False)
    monkeypatch.setenv("TERM", "xterm-256color")
    real = importlib.util.find_spec
    monkeypatch.setattr(
        importlib.util, "find_spec",
        lambda name, *a, **kw: (object() if urwid_present else None)
        if name == "urwid" else real(name, *a, **kw))


# ── the gate, condition by condition (build-menu.sh: NO_TUI / -t 0 / -t 1 / TERM / renderer) ──
def test_have_tui_true_when_every_condition_holds(monkeypatch):
    _rich_environment(monkeypatch)
    assert tui_app.have_tui(stdin=_Tty(), stdout=_Tty()) is True


def test_no_tui_env_forces_the_fallback(monkeypatch):
    _rich_environment(monkeypatch)
    monkeypatch.setenv("NO_TUI", "1")
    assert tui_app.have_tui(stdin=_Tty(), stdout=_Tty()) is False


def test_no_tui_empty_reenables(monkeypatch):
    # build-menu.sh checks [ -z "${NO_TUI:-}" ]: NO_TUI= (empty) re-enables the rich UI.
    _rich_environment(monkeypatch)
    monkeypatch.setenv("NO_TUI", "")
    assert tui_app.have_tui(stdin=_Tty(), stdout=_Tty()) is True


def test_non_tty_streams_force_the_fallback(monkeypatch):
    _rich_environment(monkeypatch)
    assert tui_app.have_tui(stdin=io.StringIO(), stdout=_Tty()) is False
    assert tui_app.have_tui(stdin=_Tty(), stdout=io.StringIO()) is False


def test_dumb_term_forces_the_fallback(monkeypatch):
    _rich_environment(monkeypatch)
    monkeypatch.setenv("TERM", "dumb")
    assert tui_app.have_tui(stdin=_Tty(), stdout=_Tty()) is False
    monkeypatch.delenv("TERM")                    # unset TERM defaults to dumb too
    assert tui_app.have_tui(stdin=_Tty(), stdout=_Tty()) is False


def test_missing_urwid_forces_the_fallback_not_a_crash(monkeypatch):
    _rich_environment(monkeypatch, urwid_present=False)
    assert tui_app.have_tui(stdin=_Tty(), stdout=_Tty()) is False


# ── import purity: the package must import with urwid absent and never pull Qt ──────
def test_importing_the_tui_imports_neither_urwid_nor_qt():
    code = (
        "import sys\n"
        "import hugmesh_studio.tui\n"
        "import hugmesh_studio.tui.app\n"
        "import hugmesh_studio.tui.model\n"
        "import hugmesh_studio.tui.plain\n"
        "import hugmesh_studio.tui.journey\n"
        "import hugmesh_studio.tui.themes\n"
        "import hugmesh_studio.tui.localcloud\n"
        "import hugmesh_studio.tui.meshemu\n"
        "import hugmesh_studio.tui.domains_step\n"
        "hugmesh_studio.tui.journey.Journey('.')\n"   # the lazy screen imports too
        "bad = [m for m in sys.modules\n"
        "       if m == 'urwid' or m.startswith(('urwid.', 'PySide6', 'PyQt6'))]\n"
        "assert not bad, bad\n")
    env = dict(os.environ, PYTHONPATH=_STUDIO_ROOT)
    subprocess.run([sys.executable, "-c", code], check=True, env=env)


# ── main(): scripted streams take the plain path and say so, exit 0 ────────────────
def test_main_degrades_to_plain_prompts_with_the_menu_notice(capsys):
    out = io.StringIO()
    rc = tui_app.main([], inp=io.StringIO("q\n"), out=out)
    assert rc == 0
    # the default flow is the JOURNEY now (#67 parity: welcome screen first);
    # the sessions review stays one entry point (and --sessions) away.
    assert "HugMesh Image Studio" in out.getvalue()
    err = capsys.readouterr().err
    assert "NO_TUI" in err and "dev-python/urwid" in err


def test_main_sessions_flag_keeps_the_old_default_reachable(capsys):
    out = io.StringIO()
    rc = tui_app.main(["--sessions"], inp=io.StringIO("q\n"), out=out)
    assert rc == 0
    assert "previous builds" in out.getvalue()
    assert "NO_TUI" in capsys.readouterr().err


def test_main_plain_flag_forces_the_fallback(capsys):
    rc = tui_app.main(["--plain"], inp=io.StringIO("q\n"), out=io.StringIO())
    assert rc == 0
    assert "plain text prompts" in capsys.readouterr().err


def test_main_worklist_unknown_session_exits_2(capsys):
    rc = tui_app.main(["--worklist", "no-such-session"],
                      inp=io.StringIO(""), out=io.StringIO())
    assert rc == 2
    assert "no readable session record" in capsys.readouterr().err
