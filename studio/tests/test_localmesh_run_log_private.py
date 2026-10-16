"""A persisted run log must not leak a secret, and must not be world-readable (#362).

`make stack-seed` used to echo "... sign in with an e2e persona (e.g. e2e-admin /
<password>)". The Studio streams make's stdout into the run buffer and
`_save_run_log` wrote it to `<state>/logs/` with the default umask (0644 in a 0755
dir): the shared persona password sat in a world-readable file in the operator's
home. Three independent layers close it and each is pinned here:

  1. the Makefile no longer prints the value (source of the leak),
  2. `_save_run_log` writes 0600 files in a 0700 directory, even over an older,
     looser directory/file (the operator's existing logs dir is already 0755),
  3. a line in the old `<user> / <value>` shape is redacted on the way to disk.
"""
from __future__ import annotations

import os
import shutil
import stat
import subprocess
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed in this job")

from hugmesh_studio.gui.pages import localmesh  # noqa: E402

GENERATOR_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

SECRET = "Zx9-not-a-real-password-Qv7"
# The Makefile's OLD sentence, verbatim in shape — the exact line the issue names.
OLD_MAKEFILE_LINE = (
    "==> Seeded. Real SSO web login: open http://localhost:9080/login and sign in "
    f"with an e2e persona (e.g. e2e-admin / {SECRET}) — {SECRET} is also readable "
    "from .e2e-credentials at the repo root."
)


def _save(tmp_path, monkeypatch, lines, label="Bootstrapping"):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path))
    run = SimpleNamespace(label=label, buffer=list(lines))
    path = localmesh.LocalMeshPage._save_run_log(None, run, True)
    assert path, "the run log was not written at all"
    return path


def _mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def test_run_log_is_private_and_its_directory_too(tmp_path, monkeypatch):
    old = os.umask(0o022)   # the operator's umask: the default that leaked
    try:
        path = _save(tmp_path, monkeypatch, ["[boot] hello"])
    finally:
        os.umask(old)
    assert _mode(path) == 0o600, oct(_mode(path))
    assert _mode(os.path.dirname(path)) == 0o700, oct(_mode(os.path.dirname(path)))
    assert "[boot] hello" in open(path, encoding="utf-8").read()


def test_a_preexisting_loose_dir_and_file_are_tightened(tmp_path, monkeypatch):
    logs = tmp_path / "logs"
    logs.mkdir()
    os.chmod(logs, 0o755)
    monkeypatch.setattr(localmesh.time, "strftime", lambda fmt: "20260101-000000")
    stale = logs / "20260101-000000-Bootstrapping-ok.log"
    stale.write_text("old run\n")
    os.chmod(stale, 0o644)
    path = _save(tmp_path, monkeypatch, ["[boot] new run"])
    assert path == str(stale), "the test did not hit the pre-existing file"
    assert _mode(path) == 0o600, oct(_mode(path))
    assert _mode(str(logs)) == 0o700, oct(_mode(str(logs)))


def test_the_old_makefile_sentence_reaches_disk_without_the_value(tmp_path, monkeypatch):
    path = _save(tmp_path, monkeypatch, ["[seed] working", OLD_MAKEFILE_LINE, "[seed] done"])
    body = open(path, encoding="utf-8").read()
    assert "Seeded. Real SSO web login" in body, "the line itself must survive"
    assert SECRET not in body, "the persona password reached the persisted run log"
    assert "[seed] done" in body


def test_stack_seed_no_longer_prints_the_password():
    """Layer 1: the source. `make -n` prints the recipe without running it, so a
    `$(bash tests/stack/e2e-password.sh)` / `$$pw` interpolation is visible here."""
    make = shutil.which("make")
    if make is None:
        pytest.skip("no make on PATH")
    out = subprocess.run([make, "-n", "stack-seed"], cwd=GENERATOR_DIR,
                         capture_output=True, text=True, timeout=60)
    text = out.stdout
    assert "Seeded. Real SSO web login" in text, (
        "stack-seed's final banner is gone or make -n failed:\n" + out.stderr[-500:])
    assert "e2e-password.sh" not in text, (
        "stack-seed reads the persona password back in order to print it:\n" + text)
    assert "$pw" not in text and "$$pw" not in text, (
        "stack-seed interpolates a password into its output:\n" + text)
