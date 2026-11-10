"""PR #957 round 2 — core (Qt-free) pins for the refuter's findings (FAKE keys only).

* the org-secret push names WHICH key it sent: the stored key's short fingerprint
  (first/last 4 hex of a slow hash — never characters of the key), and a face can ask
  :func:`nvd_key.typed_conflict` whether a key still in its box is a different one;
* the "set anyway" wording comes from the stored key's real state;
* a per-run key copy left behind by a SIGKILLed Studio is swept on the next start —
  the same owner-lock + grace sweep the held-keys / domain-CA / login dirs use
  (``secret_files.sweep_stale_private_dirs``), while a live run's copy is never touched.
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time

import pytest

from hugmesh_studio.core import nvd_key, secret_files

from test_nvd_key_core import NVD_200, FakeOpener, FakeRunner

KEY = "11111111-2222-4333-8444-555555555555"
KEY2 = "abcdef01-2345-4678-9abc-def012345678"
STUDIO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _verified(key):
    nvd_key.save(key)
    nvd_key.record_verdict(nvd_key.verify(key, opener=FakeOpener(NVD_200)))


# ── which key went to GitHub ─────────────────────────────────────────────────────────
def test_short_fingerprint_is_four_and_four_of_the_hash_never_the_key():
    fp = nvd_key.status().fingerprint or nvd_key.fingerprint_of(KEY)
    short = nvd_key.short_fingerprint(fp)
    assert short == f"{fp[:4]}…{fp[-4:]}" and len(fp) == 12
    assert short.replace("…", "") not in KEY.replace("-", "")
    assert nvd_key.fingerprint_of("not-a-key") == "" and nvd_key.fingerprint_of("") == ""
    assert nvd_key.fingerprint_of(f"  {KEY}\n") == nvd_key.fingerprint_of(KEY)


def test_push_success_names_the_stored_keys_fingerprint():
    _verified(KEY)
    r = FakeRunner()
    res = nvd_key.push_org_secret("acme", runner=r)
    assert res.ok
    short = nvd_key.short_fingerprint(nvd_key.status().fingerprint)
    assert f"the stored key (fingerprint {short})" in res.sentence
    assert KEY not in res.sentence and KEY[:8] not in res.sentence


def test_typed_conflict():
    assert nvd_key.typed_conflict("") == "" and nvd_key.typed_conflict("  \n") == ""
    _verified(KEY)
    st = nvd_key.status()
    short = nvd_key.short_fingerprint(st.fingerprint)
    assert nvd_key.typed_conflict(KEY) == ""                 # the same key: fine
    assert nvd_key.typed_conflict(f" {KEY.upper()} ") == ""  # (normalised)
    other = nvd_key.typed_conflict(KEY2)
    assert "different key" in other and "Save first" in other and short in other
    assert nvd_key.short_fingerprint(nvd_key.fingerprint_of(KEY2)) in other
    assert KEY not in other and KEY2 not in other
    junk = nvd_key.typed_conflict("not-a-key")
    assert "not a key" in junk and short in junk
    nvd_key.forget()
    assert "no stored key" in nvd_key.typed_conflict(KEY2)


def test_set_anyway_text_follows_the_stored_key():
    assert "no key is stored" in nvd_key.set_anyway_text()
    nvd_key.save(KEY)
    short = nvd_key.short_fingerprint(nvd_key.status().fingerprint)
    t = nvd_key.set_anyway_text()
    assert "has not passed Verify" in t and short in t
    nvd_key.record_verdict(nvd_key.verify(KEY, opener=FakeOpener(NVD_200)))
    t = nvd_key.set_anyway_text()
    assert t.startswith("set anyway — not needed") and short in t and "not OK" not in t


def test_checked_line_names_the_key_it_checked():
    res = nvd_key.verify(KEY, opener=FakeOpener(NVD_200))
    short = nvd_key.short_fingerprint(nvd_key.fingerprint_of(KEY))
    assert res.checked_line() == f"{res.line()} (checked key {short})"
    assert KEY not in res.checked_line()


# ── a SIGKILLed run's per-run copy is swept on the next start ────────────────────────
_CHILD = r"""
import sys, time
sys.path.insert(0, sys.argv[1])
from hugmesh_studio.core import nvd_key
nvd_key.save(sys.argv[2])
path, _cleanup = nvd_key.materialize_for_run()
print(path, flush=True)
time.sleep(120)
"""


def _spawn_run(tmp_path, key):
    env = dict(os.environ, TMPDIR=str(tmp_path / "tmp"))
    os.makedirs(env["TMPDIR"], exist_ok=True)
    p = subprocess.Popen([sys.executable, "-c", _CHILD, STUDIO, key], env=env,
                         stdout=subprocess.PIPE, text=True)
    path = p.stdout.readline().strip()
    assert path and os.path.isfile(path), path
    return p, path


def test_a_sigkilled_runs_key_copy_is_swept_and_a_live_one_is_not(tmp_path):
    tmpdir = str(tmp_path / "tmp")
    dead, dead_path = _spawn_run(tmp_path, KEY)
    live, live_path = _spawn_run(tmp_path, KEY2)
    try:
        dead_dir, live_dir = os.path.dirname(dead_path), os.path.dirname(live_path)
        assert os.path.basename(dead_dir).startswith("hugmesh-nvd-")
        assert stat_mode(dead_path) == 0o600 and stat_mode(dead_dir) == 0o700
        dead.send_signal(signal.SIGKILL)       # no finally, no cleanup: the crash case
        dead.wait(10)
        assert os.path.isfile(dead_path), "the crash left the copy (the case to sweep)"
        # inside the grace window nothing is touched (it may be one being created)
        assert secret_files.sweep_stale_private_dirs(tmpdir) == []
        swept = secret_files.sweep_stale_private_dirs(tmpdir, grace=0)
        assert swept == [dead_dir], swept
        assert not os.path.exists(dead_dir)
        # the live run holds its owner lock: its copy stays, whatever its age
        assert os.path.isfile(live_path)
    finally:
        for p in (dead, live):
            if p.poll() is None:
                p.kill()
            p.wait(10)
            p.stdout.close()
    # once the live owner is gone too, the next start sweeps it
    assert secret_files.sweep_stale_private_dirs(tmpdir, grace=0) == [os.path.dirname(live_path)]


def test_the_studio_start_sweep_covers_the_nvd_prefix(tmp_path, monkeypatch):
    """startup_sweep() (GUI + TUI entry points) reads TMPDIR: an old ownerless
    hugmesh-nvd-* dir there is removed."""
    monkeypatch.setenv("TMPDIR", str(tmp_path))
    import tempfile
    monkeypatch.setattr(tempfile, "tempdir", None)
    d = tmp_path / "hugmesh-nvd-abc123"
    d.mkdir(mode=0o700)
    (d / "nvd_api_key").write_text(KEY)
    old = time.time() - 3600
    os.utime(d, (old, old))
    assert "hugmesh-nvd-" in secret_files.PRIVATE_DIR_PREFIXES
    assert secret_files.startup_sweep() == [str(d)]
    assert not d.exists()


def stat_mode(path):
    return os.stat(path).st_mode & 0o777


# ── no compiled bytecode in the tree (round 1 committed one, with a worktree path) ───
def _git(*args):
    root = os.path.dirname(STUDIO)
    try:
        return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True,
                              timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None


def test_no_python_bytecode_is_tracked_and_local_ai_cache_is_ignored():
    probe = _git("rev-parse", "--is-inside-work-tree")
    if probe is None or probe.returncode != 0 or probe.stdout.strip() != "true":
        pytest.skip("not a git checkout")
    tracked = _git("ls-files", "--", "*.pyc", "*/__pycache__/*")
    assert tracked.returncode == 0 and tracked.stdout.strip() == "", tracked.stdout
    ign = _git("check-ignore", "-q", "--no-index",
               "scripts/local-ai/__pycache__/eval.cpython-314.pyc")
    assert ign.returncode == 0, "scripts/local-ai/__pycache__/ is not in .gitignore"
