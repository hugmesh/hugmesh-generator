"""core.keyzip staging dirs are ENV-SEAMED, and extract() only deletes what it owns.

DEFECT (live, observed on the operator's own machine)
-----------------------------------------------------
``gui/pages/keyzip.py`` computed its two host-side paths from a bare
``os.path.expanduser("~")``:

    staging = os.path.join(os.path.expanduser("~"), ".hugmesh", "keyzip")
    c = keyzip.extract(zip_path, staging)

and ``core/keyzip.extract`` opens with ``shutil.rmtree(staging_dir,
ignore_errors=True)``. Unlike every other member of the Studio state family
(``core.instance.state_dir``, ``core.build_sessions``, ``core.crashlog``) that path
honoured NO environment override, so there was no way — for a test, a second
profile or a sandbox — to point it anywhere else.

Consequence: every studio test that drove a key-zip import RECURSIVELY DELETED the
operator's real ``~/.hugmesh/keyzip`` — the Secure-Boot signing staging and the
offline ``vault/secrets.json`` bundle — and then passed green. Measured on
origin/main: an operator sentinel planted in ``~/.hugmesh/keyzip`` was gone after
``pytest tests/test_pages_identity.py -k keyzip`` reported "4 passed", leaving only
that test's own ``branding/logo.svg`` behind.

The tests below fail on the unfixed code and pass on the fixed code.
"""
from __future__ import annotations

import os
import re
import sys
import zipfile

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from hugmesh_studio.core import keyzip                                  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUI_KEYZIP_PAGE = os.path.join(STUDIO_ROOT, "hugmesh_studio", "gui", "pages", "keyzip.py")


def _make_zip(path, entries: dict) -> None:
    with zipfile.ZipFile(path, "w") as zf:
        for name, body in entries.items():
            zf.writestr(name, body)


# ── 1. the leak itself: a run under an isolated state dir must not touch $HOME ──────

def test_gui_import_under_a_state_dir_override_never_touches_the_real_home(
        tmp_path, monkeypatch):
    """THE regression, driven through the production widget (KeyZipPage._import ->
    core.keyzip.extract), which is where the hard-coded path lived.

    Point ``$HOME`` at a fake home holding STAGED OPERATOR KEY MATERIAL, point
    ``$HUGMESH_STUDIO_STATE_DIR`` somewhere else entirely, then run a real key-zip
    import. The operator's files must still be there afterwards, and the zip must
    have landed under the override.

    Unfixed, KeyZipPage._apply computes ``expanduser("~")/.hugmesh/keyzip`` and
    extract() rmtree's it: every one of these files is gone and the test still
    reported "Imported"."""
    pytest.importorskip("hugmesh_studio.gui.qt",
                        reason="no Qt binding (PySide6/PyQt6) installed")
    from types import SimpleNamespace
    from hugmesh_studio.core.config import ImageConfig
    from hugmesh_studio.gui.pages import keyzip as keyzip_page
    from hugmesh_studio.gui.qt import QtWidgets
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["kz-isolation"])
    assert app is not None

    home = tmp_path / "home"
    operator = home / ".hugmesh" / "keyzip"
    (operator / "keys").mkdir(parents=True)
    (operator / "vault").mkdir(parents=True)
    # what the operator actually had staged there (mirrors the live machine)
    (operator / "keys" / "ca.crt").write_text("REAL-ORG-CA", encoding="utf-8")
    (operator / "keys" / "kernel_key.pem").write_text("REAL-SB-KEY", encoding="utf-8")
    (operator / "vault" / "secrets.json").write_text('{"real": true}', encoding="utf-8")
    before = {str(p.relative_to(operator)): p.read_text(encoding="utf-8")
              for p in operator.rglob("*") if p.is_file()}
    assert len(before) >= 3, "fixture floor: the operator dir must hold real files"

    state = tmp_path / "state"
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("USERPROFILE", str(home))          # expanduser on Windows
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(state))

    zp = tmp_path / "admin-config.zip"
    _make_zip(zp, {"keys/ca.crt": "dummy-ca",
                   "branding/logo.svg": "<svg/>",
                   "vault/secrets.json": "{}"})
    page = keyzip_page.KeyZipPage(SimpleNamespace(cfg=ImageConfig(), generator_dir="."))
    try:
        page.path.setText(str(zp))
        page._import()
        assert "Imported" in page.out.text(), page.out.text()

        # (a) the operator's staged material survived, byte for byte
        after = {str(p.relative_to(operator)): p.read_text(encoding="utf-8")
                 for p in operator.rglob("*") if p.is_file()}
        assert after == before, (
            "the key-zip import destroyed the operator's real ~/.hugmesh/keyzip; "
            f"before={sorted(before)} after={sorted(after)}")

        # (b) the zip really was extracted — under the override, not under $HOME
        staged = state / "keyzip"
        landed = sorted(str(f.relative_to(staged)) for f in staged.rglob("*")
                        if f.is_file() and f.name != keyzip.STAGING_MARKER)
        assert len(landed) >= 3, f"floor: the import extracted nothing: {landed}"
        assert landed == ["branding/logo.svg", "keys/ca.crt", "vault/secrets.json"]
    finally:
        page.deleteLater()


def test_core_extract_under_a_state_dir_override_never_touches_the_real_home(
        tmp_path, monkeypatch):
    """Same guarantee at the core override point, with no Qt in the picture."""
    home = tmp_path / "home"
    operator = home / ".hugmesh" / "keyzip"
    operator.mkdir(parents=True)
    (operator / "ca.crt").write_text("REAL-ORG-CA", encoding="utf-8")
    (operator / "kernel_key.pem").write_text("REAL-SB-KEY", encoding="utf-8")
    before = sorted(str(p.name) for p in operator.iterdir())
    assert len(before) >= 2, "fixture floor: the operator dir must hold real files"

    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("USERPROFILE", str(home))
    monkeypatch.setenv(keyzip.STATE_DIR_ENV, str(tmp_path / "state"))

    zp = tmp_path / "z.zip"
    _make_zip(zp, {"keys/ca.crt": "dummy-ca", "branding/logo.svg": "<svg/>"})
    c = keyzip.extract(str(zp), keyzip.staging_dir())

    assert sorted(str(p.name) for p in operator.iterdir()) == before
    assert len(c.files) >= 2, "floor: the import must have extracted something"
    assert c.staging_dir == str(tmp_path / "state" / "keyzip")


def test_both_keyzip_host_paths_follow_the_override(tmp_path, monkeypatch):
    """Staging AND the remote-config fetch destination move together — a fetch that
    still wrote under the real $HOME would re-open the same hole."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv(keyzip.STATE_DIR_ENV, str(tmp_path / "state"))
    paths = [keyzip.staging_dir(), keyzip.fetch_zip_path()]
    assert len(paths) == 2
    for p in paths:
        assert p.startswith(str(tmp_path / "state") + os.sep), p
        assert str(tmp_path / "home") not in p, p


def test_without_the_override_the_paths_are_the_documented_home_defaults(tmp_path,
                                                                        monkeypatch):
    """The env var is an override, not a relocation: unset, behaviour is unchanged."""
    monkeypatch.delenv(keyzip.STATE_DIR_ENV, raising=False)
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    assert keyzip.staging_dir() == str(tmp_path / "home" / ".hugmesh" / "keyzip")
    assert keyzip.fetch_zip_path() == str(
        tmp_path / "home" / ".hugmesh" / "keyzip-fetch" / "admin-config.zip")


# ── 2. the GUI page must not re-grow a hard-coded home path ─────────────────────────

def test_the_gui_page_derives_its_host_paths_from_the_seam(tmp_path, monkeypatch):
    """Source-level guard: gui/pages/keyzip.py must reach its host paths through
    core.keyzip, never through its own expanduser("~")."""
    src = open(GUI_KEYZIP_PAGE, encoding="utf-8").read()
    code = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))
    assert len(code.splitlines()) >= 100, "floor: the page source was actually read"

    hardcoded = [l for l in code.splitlines() if "expanduser(" in l]
    assert hardcoded == [], (
        "gui/pages/keyzip.py builds a host path from expanduser('~') again — "
        f"{hardcoded}. extract() rmtree's that path.")

    seams = re.findall(r"keyzip\.(staging_dir|fetch_zip_path)\(\)", code)
    assert len(seams) >= 2, f"expected both host paths to go through the seam, got {seams}"


# ── 3. extract() deletes only a directory it owns ──────────────────────────────────

def test_extract_refuses_to_recursively_delete_a_directory_it_does_not_own(tmp_path):
    """A wrong/mistyped staging path used to be an unconditional recursive delete.
    It is now a loud ValueError, with nothing removed."""
    victim = tmp_path / "important"
    (victim / "sub").mkdir(parents=True)
    (victim / "sub" / "notes.txt").write_text("keep me", encoding="utf-8")
    (victim / "ca.crt").write_text("keep me too", encoding="utf-8")
    before = sorted(str(p.relative_to(victim)) for p in victim.rglob("*"))
    assert len(before) >= 3, "fixture floor: the victim dir must hold real entries"

    zp = tmp_path / "z.zip"
    _make_zip(zp, {"keys/ca.crt": "dummy-ca"})
    with pytest.raises(ValueError) as exc:
        keyzip.extract(str(zp), str(victim))
    assert keyzip.STAGING_MARKER in str(exc.value)

    after = sorted(str(p.relative_to(victim)) for p in victim.rglob("*"))
    assert after == before, f"extract() deleted from a dir it does not own: {before} -> {after}"


def test_extract_still_starts_clean_in_a_dir_it_owns(tmp_path):
    """The guard must not cost the reason the rmtree exists: a second import into the
    SAME staging dir still cannot see the first zip's files."""
    staging = tmp_path / "staging"
    first = tmp_path / "first.zip"
    _make_zip(first, {"keys/ca.crt": "a", "branding/logo.svg": "<svg/>",
                      "stale/old.txt": "old"})
    c1 = keyzip.extract(str(first), str(staging))
    assert len(c1.files) >= 3, "floor: the first import must have extracted something"
    assert (staging / "stale" / "old.txt").exists()
    assert (staging / keyzip.STAGING_MARKER).exists(), "extract() must mark what it owns"

    second = tmp_path / "second.zip"
    _make_zip(second, {"keys/ca.crt": "b"})
    c2 = keyzip.extract(str(second), str(staging))
    assert c2.files == ["keys/ca.crt"]
    assert not (staging / "stale").exists(), "the previous zip's files survived"
    assert (staging / "keys" / "ca.crt").read_text(encoding="utf-8") == "b"


def test_extract_adopts_an_unmarked_canonical_staging_dir(tmp_path, monkeypatch):
    """Installs that staged a key-zip BEFORE the marker existed must keep working:
    the app's own staging_dir() is adopted rather than refused."""
    state = tmp_path / "state"
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv(keyzip.STATE_DIR_ENV, str(state))
    legacy = state / "keyzip"
    legacy.mkdir(parents=True)
    (legacy / "leftover.txt").write_text("from an older import", encoding="utf-8")

    zp = tmp_path / "z.zip"
    _make_zip(zp, {"keys/ca.crt": "dummy-ca"})
    c = keyzip.extract(str(zp), keyzip.staging_dir())
    assert c.files == ["keys/ca.crt"]
    assert not (legacy / "leftover.txt").exists()      # start-clean, as always


def test_extract_rejects_an_empty_staging_path(tmp_path):
    zp = tmp_path / "z.zip"
    _make_zip(zp, {"keys/ca.crt": "dummy-ca"})
    for bad in ("", "   "):
        with pytest.raises(ValueError):
            keyzip.extract(str(zp), bad)
