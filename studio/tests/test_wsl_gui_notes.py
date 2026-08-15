"""The WSL remedies where the operator actually reads them: Welcome and the QEMU page.

Companion to test_platform_targets.py, which proves the DETECTION. This file proves the
RENDERING, because a correct diagnosis that never reaches a screen is worth nothing —
and because both remedies are multi-line text containing ``<`` and backslashes being
interpolated into Qt RichText, which is a silent-corruption hazard all of its own: an
unescaped ``<distro>`` is parsed as a tag and DELETED, taking the one word the operator
was supposed to substitute with it.

Everything is driven through a PINNED HostInfo and a fake mount table, never by running
on the target: this workstation is not WSL, so a test that only passed there would prove
nothing about the code path Windows operators hit.
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import platform_info, qemu_tests        # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo           # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod              # noqa: E402
from hugmesh_studio.gui.pages.welcome import WelcomePage         # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                      # noqa: E402

from _helpers import advance_to, pick_mode                       # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def wsl_host(**kw) -> HostInfo:
    """A WSL2 host with Docker up and no KVM — the DEFAULT state on Windows, since
    nested virtualisation is off unless a .wslconfig stanza turns it on."""
    base = dict(os="linux", is_gentoo=False, has_docker=True, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder",
                is_wsl=True, wsl_version=2, wsl_distro="Ubuntu-24.04")
    base.update(kw)
    return HostInfo(**base)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _docker_stubbed(monkeypatch):
    # the QEMU page probes the real daemon otherwise, making every test here depend on
    # this machine's docker
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda: (True, "docker is available."))


@pytest.fixture(autouse=True)
def _local_disk_by_default(monkeypatch):
    """Nothing is on a Windows drive unless a test says so — the slow-filesystem tests
    opt IN, so every other assertion here is unaffected by this machine's mounts."""
    monkeypatch.setattr(platform_info, "read_mounts", lambda _p=None: [("/", "ext4")])


def _wizard(qapp, host, generator_dir=GENERATOR_DIR):
    orig = wizard_mod.detect
    wizard_mod.detect = lambda builder_image="hugmesh-builder": host
    try:
        return wizard_mod.StudioWizard(generator_dir)
    finally:
        wizard_mod.detect = orig


def _welcome(wiz) -> WelcomePage:
    for pid in wiz.pageIds():
        if isinstance(wiz.page(pid), WelcomePage):
            return wiz.page(pid)
    raise AssertionError("WelcomePage not found")


# ── 1. the /mnt/c trap, on the first screen ─────────────────────────────────────────

def test_welcome_warns_when_the_generator_lives_on_a_windows_drive(qapp, monkeypatch):
    """Said on the FIRST screen, not only at preflight: by the time preflight runs the
    operator has configured a whole image and is one click from a 'hang' they will wait
    out. The cheap fix (re-clone into ~) is only cheap BEFORE that."""
    monkeypatch.setattr(platform_info, "read_mounts",
                        lambda _p=None: [("/", "ext4"), (os.path.realpath(GENERATOR_DIR), "9p")])
    wiz = _wizard(qapp, wsl_host())
    html = _welcome(wiz)._intro_html()
    assert "SLOW FILESYSTEM" in html
    assert "git clone" in html
    wiz.deleteLater()


def test_welcome_is_quiet_when_the_repo_is_on_the_linux_disk(qapp):
    wiz = _wizard(qapp, wsl_host())
    assert "SLOW FILESYSTEM" not in _welcome(wiz)._intro_html()
    wiz.deleteLater()


def test_the_windows_drive_remedy_survives_richtext(qapp, monkeypatch):
    """``git clone <repo-url> …`` interpolated raw into RichText loses ``<repo-url>``
    entirely — Qt parses it as an unknown tag and drops it, leaving an instruction with
    a hole where the substitution was supposed to go."""
    monkeypatch.setattr(platform_info, "read_mounts",
                        lambda _p=None: [("/", "ext4"), (os.path.realpath(GENERATOR_DIR), "9p")])
    wiz = _wizard(qapp, wsl_host())
    html = _welcome(wiz)._intro_html()
    assert "&lt;repo-url&gt;" in html and "<repo-url>" not in html
    # the recipe's own newlines become breaks rather than collapsing into a run-on line
    assert "git clone" in html and "<br>" in html.split("git clone")[0]
    wiz.deleteLater()


# ── 2. docker reachability ──────────────────────────────────────────────────────────

def test_welcome_no_backend_note_points_at_wsl_integration_not_a_reinstall(qapp):
    """Docker Desktop is usually already installed and running on the Windows side —
    it is simply not shared with THIS distro. 'Install Docker Desktop' would send the
    operator to reinstall a working application."""
    wiz = _wizard(qapp, wsl_host(has_docker=False))
    html = _welcome(wiz)._intro_html()
    assert "WSL Integration" in html and "Ubuntu-24.04" in html
    assert "Install Docker Desktop on Windows or macOS" not in html
    wiz.deleteLater()


def test_welcome_keeps_the_generic_advice_for_a_non_wsl_host(qapp):
    wiz = _wizard(qapp, wsl_host(has_docker=False, is_wsl=False, os="darwin"))
    html = _welcome(wiz)._intro_html()
    assert "Install Docker Desktop" in html and "WSL Integration" not in html
    wiz.deleteLater()


# ── 3. KVM / nested virtualisation on the QEMU lane ─────────────────────────────────

@pytest.fixture
def fake_generator(tmp_path):
    """Minimal generator tree with one image-holding session (the QEMU page needs one
    to render its picker) and a stub runner — nothing containerized runs."""
    gen = tmp_path / "gen"
    sess = gen / "out" / "sessions" / "20260201-000000-full"
    sess.mkdir(parents=True)
    (sess / "hugmesh-x86-amd64-be-test-20260807T172418Z.img").write_bytes(b"")
    qdir = gen / "tests" / "qemu"
    qdir.mkdir(parents=True)
    stub = qdir / "run-qemu-docker.sh"
    stub.write_text('#!/usr/bin/env bash\nexit 0\n')
    stub.chmod(0o755)
    return gen


def _qemu_page(qapp, host, gen):
    wiz = _wizard(qapp, host, str(gen))
    wiz.show()
    pick_mode(wiz, "qemu")
    return wiz, advance_to(wiz, wizard_mod.QemuPage)


def test_qemu_page_states_the_nested_virt_remedy_when_kvm_is_missing(qapp, fake_generator):
    """Under WSL2 this is the DEFAULT state, so silence would strand every Windows
    operator on the slowest possible path with no hint that a fix exists."""
    wiz, page = _qemu_page(qapp, wsl_host(), fake_generator)
    assert page.kvm_note.isVisible()
    note = page.kvm_note.text()
    assert "nestedVirtualization=true" in note
    assert "wsl --shutdown" in note
    wiz.close()
    wiz.deleteLater()


def test_the_kvm_note_warns_without_blocking_the_run(qapp, fake_generator):
    """The runner degrades to TCG by itself, so the results stay correct — they just
    take hours. Disabling the buttons would be a lie in the other direction."""
    wiz, page = _qemu_page(qapp, wsl_host(), fake_generator)
    assert page.run_btn.isEnabled() and page.list_btn.isEnabled()
    wiz.close()
    wiz.deleteLater()


def test_the_kvm_note_is_hidden_entirely_when_acceleration_works(qapp, fake_generator):
    wiz, page = _qemu_page(qapp, wsl_host(has_kvm=True), fake_generator)
    assert not page.kvm_note.isVisible() and page.kvm_note.text() == ""
    wiz.close()
    wiz.deleteLater()


def test_the_wslconfig_stanza_is_shown_verbatim_not_html_mangled(qapp, fake_generator):
    """``[wsl2]`` and the backslash in ``%UserProfile%\\.wslconfig`` have to reach the
    clipboard intact; a RichText label would eat the newlines that separate them."""
    wiz, page = _qemu_page(qapp, wsl_host(), fake_generator)
    note = page.kvm_note.text()
    assert "[wsl2]" in note
    assert "\\.wslconfig" in note
    assert "\n" in note                      # line structure preserved, not collapsed
    wiz.close()
    wiz.deleteLater()


def test_the_qemu_docker_note_escapes_the_wsl_remedy(qapp, fake_generator, monkeypatch):
    """``wsl --set-version <distro> 2`` in a RichText label: unescaped, Qt deletes
    ``<distro>`` as an unknown tag and the instruction becomes unfollowable."""
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda: (False, "cannot talk to the docker daemon. "
                                        "Convert it: wsl --set-version <distro> 2"))
    wiz, page = _qemu_page(qapp, wsl_host(has_docker=False), fake_generator)
    assert "&lt;distro&gt;" in page.docker_note.text()
    wiz.close()
    wiz.deleteLater()
