"""The first-run bootstrap (issue #49) must be idempotent, per-user, and advisory.

core/first_run.py is the python half of the pair (scripts/_first-run-lib.sh is
the shell gate). These tests pin its three duties — ~/.local/bin symlinks,
the versioned properties.json in the Studio state dir, the doctor pass — and
the contracts that make it safe to call from EVERY entrypoint:

* every write lands under the overridable state/bin dirs (never the real $HOME
  during a test),
* a current stamp makes ensure() a silent no-op; ``force`` reruns it,
* foreign files on PATH are never clobbered, and the appliance's reserved
  ``hugmesh-mesh-node`` name is never created,
* the doctor prints advisory lines and NEVER raises or blocks,
* nothing is ever printed to stdout (the launcher's automation channel owns it).

Qt-free on purpose: first_run must be importable before any binding exists —
it runs on boxes whose whole problem is that PySide6 is missing.
"""
import json
import os
import stat
import sys

import pytest

from hugmesh_studio.core import first_run


@pytest.fixture(autouse=True)
def _sandboxed_home(tmp_path, monkeypatch):
    """Every write in this suite must land under tmp_path, never the real ~ —
    and the doctor must never reach a REAL docker CLI (or any other host tool):
    PATH is pinned to a shim dir whose fake docker always answers "no image"."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("HUGMESH_BIN_DIR", str(tmp_path / "bin"))
    monkeypatch.delenv("IMAGE", raising=False)
    shims = tmp_path / "path-shims"
    shims.mkdir()
    fake_docker = shims / "docker"
    fake_docker.write_text("#!/bin/sh\nexit 1\n")
    fake_docker.chmod(0o755)
    monkeypatch.setenv("PATH", str(shims))


@pytest.fixture()
def repo(tmp_path):
    """A minimal fake generator checkout: just the two executable CLI faces."""
    root = tmp_path / "repo"
    (root / "scripts").mkdir(parents=True)
    (root / "studio").mkdir()
    for rel in ("scripts/studio-launch.sh", "scripts/build-menu.sh"):
        p = root / rel
        p.write_text("#!/bin/sh\nexit 0\n")
        p.chmod(p.stat().st_mode | stat.S_IXUSR)
    return str(root)


def _lines(bucket):
    def echo(msg):
        bucket.append(msg)
    return echo


# ── paths honour the overrides (never the operator's real home) ─────────────────


def test_state_and_bin_dirs_honour_overrides(tmp_path):
    assert first_run.properties_path().startswith(str(tmp_path / "state"))
    assert first_run.stamp_path().startswith(str(tmp_path / "state"))
    assert first_run.bin_dir() == str(tmp_path / "bin")


def test_bin_dir_defaults_to_xdg_local_bin(tmp_path, monkeypatch):
    monkeypatch.delenv("HUGMESH_BIN_DIR", raising=False)
    assert first_run.bin_dir() == str(tmp_path / "home" / ".local" / "bin")


def test_builder_image_name_honours_image_env(monkeypatch):
    assert first_run.builder_image_name() == "hugmesh-builder"
    monkeypatch.setenv("IMAGE", "my-builder:dev")
    assert first_run.builder_image_name() == "my-builder:dev"


# ── ensure(): first run writes everything, reruns are silent no-ops ─────────────


def test_first_ensure_writes_stamp_properties_and_links(tmp_path, repo):
    out = []
    props = first_run.ensure(repo, echo=_lines(out))

    stamp = (tmp_path / "state" / "first-run.stamp").read_text().strip()
    assert stamp == str(first_run.FIRST_RUN_VERSION)

    on_disk = json.loads((tmp_path / "state" / "properties.json").read_text())
    assert on_disk["version"] == first_run.FIRST_RUN_VERSION
    assert on_disk["generator_dir"] == repo
    assert on_disk["builder_image"] == "hugmesh-builder"
    assert on_disk["venv"] is None          # the fake repo has no .venv-studio
    assert props["generator_dir"] == repo

    for name, rel in (("hugmesh-studio", "scripts/studio-launch.sh"),
                      ("hugmesh-build-menu", "scripts/build-menu.sh")):
        link = tmp_path / "bin" / name
        assert os.path.islink(link)
        assert os.path.realpath(link) == os.path.realpath(
            os.path.join(repo, rel))
    # the reserved appliance name must never appear
    assert not (tmp_path / "bin" / "hugmesh-mesh-node").exists()

    joined = "\n".join(out)
    assert "FIRSTRUN bootstrap=done" in joined
    assert "DOCTOR git=" in joined
    assert "DOCTOR kvm=" in joined


def test_rerun_is_a_silent_noop_and_force_reruns(repo):
    first_run.ensure(repo, echo=lambda m: None)
    before = os.path.getmtime(first_run.properties_path())

    out = []
    first_run.ensure(repo, echo=_lines(out))
    assert out == []                              # no prints, no work
    assert os.path.getmtime(first_run.properties_path()) == before

    out = []
    first_run.ensure(repo, force=True, echo=_lines(out))
    assert any(m.startswith("FIRSTRUN bootstrap=done") for m in out)


def test_stale_stamp_version_triggers_a_rerun(tmp_path, repo):
    first_run.ensure(repo, echo=lambda m: None)
    (tmp_path / "state" / "first-run.stamp").write_text("0\n")
    assert not first_run.is_current()
    out = []
    first_run.ensure(repo, echo=_lines(out))
    assert any(m.startswith("FIRSTRUN bootstrap=done") for m in out)
    assert first_run.is_current()


def test_interrupted_bootstrap_never_stamps(repo, monkeypatch):
    """The stamp is written LAST: a crash mid-bootstrap must rerun next time."""
    monkeypatch.setattr(first_run, "install_links",
                        lambda *_a, **_k: (_ for _ in ()).throw(RuntimeError))
    with pytest.raises(RuntimeError):
        first_run.ensure(repo, echo=lambda m: None)
    assert not first_run.is_current()


def test_nothing_is_printed_to_stdout(repo, capsys):
    """stdout belongs to the automation channels (--print-command); every
    advisory line must ride stderr."""
    first_run.ensure(repo, force=True)
    assert capsys.readouterr().out == ""


# ── symlink policy: never clobber, retarget only our own ────────────────────────


def test_foreign_regular_file_is_never_clobbered(tmp_path, repo):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    foreign = bin_dir / "hugmesh-studio"
    foreign.write_text("someone else's script\n")
    out = []
    first_run.ensure(repo, echo=_lines(out))
    assert foreign.read_text() == "someone else's script\n"
    assert any("status=skipped-foreign-file" in m for m in out)
    assert os.path.islink(bin_dir / "hugmesh-build-menu")   # others still land


def test_foreign_symlink_is_never_clobbered(tmp_path, repo):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    other = tmp_path / "other-tool"
    other.write_text("#!/bin/sh\n")
    os.symlink(other, bin_dir / "hugmesh-studio")
    out = []
    first_run.ensure(repo, echo=_lines(out))
    assert os.readlink(bin_dir / "hugmesh-studio") == str(other)
    assert any("status=skipped-foreign-link" in m for m in out)


def test_stale_hugmesh_link_is_retargeted(tmp_path, repo):
    """A link into ANOTHER (moved/deleted) checkout's scripts/studio-launch.sh
    is ours — refresh it so the command keeps working after a repo move."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    os.symlink("/old/checkout/scripts/studio-launch.sh",
               bin_dir / "hugmesh-studio")
    out = []
    first_run.ensure(repo, echo=_lines(out))
    assert os.path.realpath(bin_dir / "hugmesh-studio") == os.path.realpath(
        os.path.join(repo, "scripts", "studio-launch.sh"))
    assert any("status=retargeted" in m for m in out)


def test_reserved_name_is_refused_even_if_asked(repo):
    assert "hugmesh-mesh-node" not in first_run.link_map(repo)
    assert first_run._ensure_link(
        "hugmesh-mesh-node", os.path.join(repo, "scripts/studio-launch.sh"),
        "scripts/studio-launch.sh") == "reserved"


# ── the doctor: advisory always, blocker never ───────────────────────────────────


def _doctor_lines(repo_dir, monkeypatch, path_dir):
    monkeypatch.setenv("PATH", str(path_dir))
    out = []
    first_run.doctor(repo_dir, echo=_lines(out))
    return out


def test_doctor_with_a_bare_path_only_advises(tmp_path, repo, monkeypatch):
    """git missing, docker missing, no venv, no kvm — the doctor still just
    prints; nothing raises, nothing exits."""
    empty = tmp_path / "empty-path"
    empty.mkdir()
    out = _doctor_lines(repo, monkeypatch, empty)
    joined = "\n".join(out)
    assert "DOCTOR git=missing" in joined
    assert "DOCTOR builder_image=unknown docker=missing" in joined
    assert "NATIVE=1" in joined                      # the one-line hint
    assert "DOCTOR venv=absent" in joined


def test_doctor_missing_builder_image_prints_the_hint(tmp_path, repo,
                                                      monkeypatch):
    shim = tmp_path / "shim"
    shim.mkdir()
    fake = shim / "docker"
    fake.write_text("#!/bin/sh\nexit 1\n")            # every inspect: missing
    fake.chmod(0o755)
    out = _doctor_lines(repo, monkeypatch, shim)
    joined = "\n".join(out)
    assert "DOCTOR builder_image=missing name=hugmesh-builder" in joined
    assert "make docker-image" in joined


def test_doctor_present_builder_image(tmp_path, repo, monkeypatch):
    shim = tmp_path / "shim"
    shim.mkdir()
    fake = shim / "docker"
    fake.write_text("#!/bin/sh\nexit 0\n")            # inspect: present
    fake.chmod(0o755)
    out = _doctor_lines(repo, monkeypatch, shim)
    assert any("DOCTOR builder_image=present" in m for m in out)


def test_doctor_venv_ok_and_broken(tmp_path, repo):
    venv_py = os.path.join(repo, "studio", ".venv-studio", "bin", "python")
    os.makedirs(os.path.dirname(venv_py))
    with open(venv_py, "w") as fh:
        fh.write("#!/bin/sh\nexit 0\n")
    os.chmod(venv_py, 0o755)
    out = []
    first_run._check_venv(repo, _lines(out))
    assert any("DOCTOR venv=ok" in m for m in out)

    with open(venv_py, "w") as fh:
        fh.write("#!/bin/sh\nexit 3\n")
    out = []
    first_run._check_venv(repo, _lines(out))
    assert any("DOCTOR venv=broken" in m for m in out)


def test_doctor_kvm_degraded_note(tmp_path):
    out = []
    first_run._check_kvm(_lines(out), dev=str(tmp_path / "no-such-kvm"))
    assert any("DOCTOR kvm=unavailable" in m for m in out)
    assert any("degraded" in m for m in out)

    fake_kvm = tmp_path / "kvm"
    fake_kvm.write_text("")
    out = []
    first_run._check_kvm(_lines(out), dev=str(fake_kvm))
    assert any("DOCTOR kvm=available" in m for m in out)


# ── properties round-trip + the CLI face ─────────────────────────────────────────


def test_load_properties_survives_corruption(tmp_path, repo):
    assert first_run.load_properties() is None
    first_run.ensure(repo, echo=lambda m: None)
    assert first_run.load_properties()["generator_dir"] == repo
    (tmp_path / "state" / "properties.json").write_text("{not json")
    assert first_run.load_properties() is None


def test_venv_recorded_when_present(repo):
    venv_py = os.path.join(repo, "studio", ".venv-studio", "bin", "python")
    os.makedirs(os.path.dirname(venv_py))
    with open(venv_py, "w") as fh:
        fh.write("#!/bin/sh\nexit 0\n")
    os.chmod(venv_py, 0o755)
    props = first_run.resolve_properties(repo)
    assert props["venv"] == venv_py
    assert props["python"] == venv_py


def test_main_print_properties_is_pure(tmp_path, repo, capsys):
    rc = first_run.main(["--repo", repo, "--print-properties"])
    assert rc == 0
    printed = json.loads(capsys.readouterr().out)
    assert printed["generator_dir"] == repo
    assert not (tmp_path / "state").exists()          # printed, wrote nothing


def test_main_doctor_only_writes_nothing(tmp_path, repo, capsys):
    rc = first_run.main(["--repo", repo, "--doctor"])
    assert rc == 0
    assert capsys.readouterr().out == ""              # stderr only
    assert not (tmp_path / "state").exists()


def test_main_bootstraps_and_redo_forces(tmp_path, repo):
    assert first_run.main(["--repo", repo]) == 0
    assert first_run.is_current()
    stamp = tmp_path / "state" / "first-run.stamp"
    before = os.path.getmtime(first_run.properties_path())
    assert first_run.main(["--repo", repo]) == 0      # no-op
    assert os.path.getmtime(first_run.properties_path()) == before
    assert first_run.main(["--repo", repo, "--redo-first-run"]) == 0
    assert stamp.read_text().strip() == str(first_run.FIRST_RUN_VERSION)
