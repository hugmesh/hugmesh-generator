"""Text output survives a stream that cannot spell it (degradation parity, gap G46).

On ``LANG=C`` with Python's UTF-8 mode off, ``PYTHONIOENCODING=ascii`` or a legacy code
page, stdout cannot encode "·" or "—", and ``print()`` raised ``UnicodeEncodeError``:

* ``--show-session`` died on the "·" the build-session labels are made of;
* the text UI (``python -m hugmesh_studio.tui``) died on the "—" of its own welcome text
  and on the "·" of the sessions list.

``core/safe_stdio.py`` is the one place that decides what a stream does with a character
it cannot encode, and ``core/entry.bootstrap()`` (the call every process entry already
makes) installs it. These tests prove the helper, that the hook installs it, and the two
entries end to end, both in this process (a stream that is ASCII on purpose) and in a
child process under a real C locale.

POSIX only where they read the bytes: on native Windows ``app.utf8_stdio`` switches the
streams to UTF-8 (test_windows_sweep_c10.py), so the output is not ASCII there by design.
"""
from __future__ import annotations

import io
import json
import os
import subprocess
import sys

import pytest

from hugmesh_studio import app
from hugmesh_studio.core import build_sessions as bs
from hugmesh_studio.core import entry, safe_stdio, secret_files
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.worklist import synthesize
from hugmesh_studio.tui import app as tui_app

posix_only = pytest.mark.skipif(os.name == "nt", reason="Windows switches stdio to UTF-8")

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: The label every wizard session gets: "<role> · <platform>".
LABEL = "standalone-thick · x86"
FOLDED_LABEL = "standalone-thick | x86"


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _stream(encoding="ascii", errors="strict"):
    return io.TextIOWrapper(io.BytesIO(), encoding=encoding, errors=errors, newline="")


def _written(stream) -> bytes:
    stream.flush()
    return stream.buffer.getvalue()


def _session(tmp_path):
    wl = synthesize(ImageConfig(mode="standalone", role="standalone-thick",
                                platform="x86", brand="acme",
                                output_dir=str(tmp_path / "out")))
    s = bs.new_session(wl, str(tmp_path))
    bs.start(s)
    bs.finish(s, bs.COMPLETE)
    return s


# ── the helper ──────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("text, folded", [
    ("standalone-thick · x86", "standalone-thick | x86"),
    ("a — b – c", "a - b - c"),
    ("wait…", "wait..."),
    ("a → b ← c", "a -> b <- c"),
    ("──══", "--=="),
    ("“quoted” ‘text’", "\"quoted\" 'text'"),
    ("§5 × 2 ≥ 1", "sec.5 x 2 >= 1"),
    ("café Zoë ² ½", "cafe Zoe 2 1/2"),
    ("Łukasz Иван 游", "?ukasz ???? ?"),
    ("\udcff", "?"),                       # a lone surrogate: an undecodable file name
])
def test_ascii_text_folds_what_the_studio_prints(text, folded):
    assert safe_stdio.ascii_text(text) == folded
    assert safe_stdio.ascii_text(text).isascii()


def test_install_makes_an_ascii_stream_fold_instead_of_raise():
    w = _stream()
    with pytest.raises(UnicodeEncodeError):       # the control: this is the crash
        w.write(LABEL)
    w = _stream()
    safe_stdio.install([w])
    assert w.errors == safe_stdio.HANDLER and w.encoding == "ascii"
    w.write(f"label: {LABEL} — Łukasz → ok\n")
    assert _written(w) == b"label: standalone-thick | x86 - ?ukasz -> ok\n"


def test_the_c_locale_default_handler_is_replaced_too():
    """LANG=C with the UTF-8 mode off: ascii + surrogateescape, which spells neither
    "·" nor "—" (it only passes a lone surrogate through as a byte)."""
    w = _stream(errors="surrogateescape")
    with pytest.raises(UnicodeEncodeError):
        w.write("—")
    w = _stream(errors="surrogateescape")
    safe_stdio.install([w])
    w.write("a — b")
    assert _written(w) == b"a - b"


def test_a_legacy_code_page_keeps_what_it_can_spell_and_folds_the_rest():
    w = _stream("latin-1")
    safe_stdio.install([w])
    w.write("é · § — →")
    assert _written(w) == "é · § ".encode("latin-1") + b"- ->"


def test_a_utf8_stream_keeps_its_encoding_and_never_raises():
    w = _stream("utf-8")
    safe_stdio.install([w])
    w.write("· — Łukasz \udcff")                 # the lone surrogate would raise on strict
    assert _written(w).decode("utf-8") == "· — Łukasz ?"
    assert w.encoding == "utf-8"


@pytest.mark.parametrize("errors", ["surrogateescape", "replace", "backslashreplace"])
def test_a_utf8_stream_that_already_copes_is_left_alone(errors):
    w = _stream("utf-8", errors)
    safe_stdio.install([w])
    assert w.errors == errors


def test_install_is_idempotent_and_ignores_streams_it_cannot_change():
    w = _stream()
    safe_stdio.install([w])
    safe_stdio.install([w])
    assert w.errors == safe_stdio.HANDLER
    closed = _stream()
    closed.close()
    # the windowed exe has no stream; a test's StringIO has no encoding to speak of
    safe_stdio.install([None, io.StringIO(), object(), closed])


# ── the one hook every entry makes ──────────────────────────────────────────────────
def test_bootstrap_installs_it_on_the_real_streams(monkeypatch):
    out, err = _stream(), _stream("latin-1")
    monkeypatch.setattr(sys, "stdout", out)
    monkeypatch.setattr(sys, "stderr", err)
    entry.bootstrap()
    assert out.errors == err.errors == safe_stdio.HANDLER


# ── the command line, in this process ───────────────────────────────────────────────
@posix_only
def test_show_session_prints_its_label_on_an_ascii_stdout(tmp_path, monkeypatch):
    s = _session(tmp_path)
    out = _stream()
    monkeypatch.setattr(sys, "stdout", out)
    assert app.main(["--show-session", s.id]) == 0
    text = _written(out).decode("ascii")
    assert f"label:    {FOLDED_LABEL}" in text and "Traceback" not in text


@posix_only
def test_list_sessions_prints_a_non_ascii_role_on_an_ascii_stdout(tmp_path, monkeypatch):
    os.makedirs(bs.sessions_dir(), exist_ok=True)
    with open(os.path.join(bs.sessions_dir(), "20261125-020000-aaaaaa.json"), "w",
              encoding="utf-8") as fh:
        json.dump({"id": "20261125-020000-aaaaaa", "status": "complete",
                   "images": [{"role": "Łukasz-backend", "platform": "x86"}]}, fh)
    out = _stream()
    monkeypatch.setattr(sys, "stdout", out)
    assert app.main(["--list-sessions"]) == 0
    assert "?ukasz-backend.x86" in _written(out).decode("ascii")


# ── the text UI, in this process ────────────────────────────────────────────────────
def _text_ui(argv, tmp_path, monkeypatch, typed):
    """The text UI's real launch (no scripted inp/out), on an ASCII stdout."""
    out, err = _stream(), _stream()
    monkeypatch.setattr(sys, "stdout", out)
    monkeypatch.setattr(sys, "stderr", err)
    monkeypatch.setattr(sys, "stdin", io.StringIO(typed))
    monkeypatch.setattr(secret_files, "startup_sweep", lambda: [])    # not the real TMPDIR
    rc = tui_app.main([*argv, "--plain", "--generator-dir", str(tmp_path)])
    return rc, _written(out).decode("ascii"), _written(err).decode("ascii")


@posix_only
def test_the_text_ui_welcome_screen_prints_on_an_ascii_stdout(tmp_path, monkeypatch):
    rc, out, err = _text_ui([], tmp_path, monkeypatch, "")    # EOF quits
    assert rc == 0 and "HugMesh Image Studio" in out and "Start building" in out
    assert "\\u2014" not in err and "using the plain text prompts" in err


@posix_only
def test_the_text_ui_sessions_list_prints_on_an_ascii_stdout(tmp_path, monkeypatch):
    _session(tmp_path)
    rc, out, _err = _text_ui(["--sessions"], tmp_path, monkeypatch, "q\n")
    assert rc == 0 and f"{FOLDED_LABEL} - complete" in out


# ── both entries in a child process under a real C locale ───────────────────────────
def _c_locale_run(args, tmp_path, stdin=""):
    """``python -m hugmesh_studio ...`` as a C-locale shell starts it: LC_ALL=C and none
    of Python's own rescues (PEP 538 locale coercion, PEP 540 UTF-8 mode)."""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("LC_", "PYTHON", "HUGMESH_", "XDG_"))}
    env.update(LC_ALL="C", LANG="C", PYTHONUTF8="0", PYTHONCOERCECLOCALE="0",
               PYTHONPATH=STUDIO_ROOT, HOME=str(tmp_path / "home"),
               TMPDIR=str(tmp_path / "tmp"),            # the text UI sweeps TMPDIR at launch
               HUGMESH_STUDIO_STATE_DIR=str(tmp_path / "state"),
               HUGMESH_STUDIO_NO_ELEVATION="1", QT_QPA_PLATFORM="offscreen")
    os.makedirs(env["TMPDIR"], exist_ok=True)
    return subprocess.run([sys.executable, *args], input=stdin.encode("ascii"), env=env,
                          cwd=str(tmp_path), capture_output=True, timeout=120)


@posix_only
def test_the_child_really_has_an_ascii_stdout_without_the_hook(tmp_path):
    """The control for the two below: this child cannot print "·" unless the fix is in."""
    r = _c_locale_run(["-c", "import sys; print(sys.stdout.encoding); print('\\u00b7')"],
                      tmp_path)
    assert r.stdout.decode().splitlines()[:1] == ["ascii"]
    assert r.returncode != 0 and b"UnicodeEncodeError" in r.stderr


@posix_only
def test_show_session_in_a_c_locale_process(tmp_path):
    s = _session(tmp_path)
    r = _c_locale_run(["-m", "hugmesh_studio", "--show-session", s.id], tmp_path)
    assert r.returncode == 0, r.stderr.decode("ascii", "replace")
    assert f"label:    {FOLDED_LABEL}".encode() in r.stdout
    assert b"Traceback" not in r.stderr


@posix_only
def test_the_text_ui_in_a_c_locale_process(tmp_path):
    _session(tmp_path)
    r = _c_locale_run(["-m", "hugmesh_studio.tui", "--plain", "--sessions",
                       "--generator-dir", str(tmp_path)], tmp_path, stdin="q\n")
    assert r.returncode == 0, r.stderr.decode("ascii", "replace")
    assert f"{FOLDED_LABEL} - complete".encode() in r.stdout
    assert b"Traceback" not in r.stderr and b"\\u2014" not in r.stderr   # stderr folds too
