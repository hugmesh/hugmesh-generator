"""Secret-file vault — the GUI faces (BuildPage rows + ProgressPage restart gate).

The 2026-07-29 operator ask at the widget layer: browsing the KEYS USB / signing key
holds CONTENT and the row says so (filename + sha256 fingerprint + "held in memory
for this session"); a USER edit drops the held copy; a RESTART whose record names
held files that this process's vault lacks PROMPTS for re-selection BEFORE dispatch
and, on decline, aborts with an honest message and dispatches nothing; a COMPLETE
run drops its entries while failed/stopped runs keep them for the retry.

Runs the REAL wizard on Qt's offscreen platform — same harness as
test_pages_build.py / test_pages_progress.py.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import build_sessions, secret_files       # noqa: E402
from hugmesh_studio.core import worklist_driver as wd              # noqa: E402
from hugmesh_studio.core.config import ImageConfig                 # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo             # noqa: E402
from hugmesh_studio.core.worklist import synthesize                # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                        # noqa: E402

from _helpers import advance_to                                    # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")

KEY_PEM = b"-----BEGIN PRIVATE KEY-----\nGUI-VAULT-SENTINEL\n-----END PRIVATE KEY-----\n"


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _fresh_vault(monkeypatch):
    monkeypatch.setattr(secret_files, "_VAULT", secret_files.SecretFileVault())


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _key_file(tmp_path, name="kernel_key.pem", data=KEY_PEM):
    p = tmp_path / name
    p.write_bytes(data)
    return str(p)


# ── BuildPage: browse holds; the row tells the truth ────────────────────────────────
def test_browse_holds_and_row_shows_fingerprint(wiz, tmp_path):
    build = advance_to(wiz, wizard_mod.BuildPage)
    p = _key_file(tmp_path)
    build._browse_held("secureboot_key", build.secureboot_key, p)
    held = secret_files.vault().get("secureboot_key")
    assert held is not None and held.origin == p
    assert build.secureboot_key.text() == p            # preview/collect still see the path
    label = build.secureboot_key_held.text()
    assert "held in memory for this session" in label
    assert "kernel_key.pem" in label and held.fingerprint in label
    # the collected config carries the path — the flag still previews/emits
    build._preview()
    assert wiz.cfg.secureboot_key == p


def test_user_edit_drops_the_held_copy(wiz, tmp_path):
    build = advance_to(wiz, wizard_mod.BuildPage)
    build._browse_held("secureboot_key", build.secureboot_key, _key_file(tmp_path))
    assert secret_files.vault().has("secureboot_key")
    # textEdited fires for USER input only — drive the hook the signal is wired to,
    # exactly as the connection does (lambda _t: self._drop_held(...))
    build.secureboot_key.setText("/somewhere/else.pem")
    build._drop_held("secureboot_key")
    assert not secret_files.vault().has("secureboot_key")
    assert "held in memory for this session" not in build.secureboot_key_held.text()
    assert "not held in memory" in build.secureboot_key_held.text()


def test_loaded_config_path_mismatch_drops_on_refresh(wiz, tmp_path):
    """A held copy corresponds to ONE browsed selection: when a loaded config (or a
    device-table assignment) shows a different path, the refresh's origin check must
    drop the entry rather than let dispatch consume the wrong material."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build._browse_held("secureboot_key", build.secureboot_key, _key_file(tmp_path))
    build.secureboot_key.setText(str(tmp_path / "different.pem"))  # programmatic
    build._refresh_held_labels()
    assert not secret_files.vault().has("secureboot_key")


def test_keys_usb_dir_without_material_falls_back_honestly(wiz, tmp_path):
    d = tmp_path / "EMPTY"
    (d / "Keys").mkdir(parents=True)
    build = advance_to(wiz, wizard_mod.BuildPage)
    build._browse_held("keys_usb", build.keys_usb, str(d))
    assert not secret_files.vault().has("keys_usb")
    assert build.keys_usb.text() == str(d)             # plain-path semantics kept
    assert "Not held in memory" in build.keys_usb_held.text()


# ── ProgressPage: the restart re-collection gate ────────────────────────────────────
def _fake_builddriver(monkeypatch, code=0):
    class FakeBuildDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.workdir = workdir

        def run(self, cfg, backend, on_line=None):
            if on_line:
                on_line(f"==> building {cfg.role}")
            return code

        def cancel(self):
            pass

        def preflight(self, cfg, backend):
            return []

        def preflight_warnings(self, cfg, backend):
            return []

        def command_string(self, cfg, backend=None):
            return f"cmd:{cfg.role}"

    monkeypatch.setattr(wd, "BuildDriver", FakeBuildDriver)


def _progress_page(wiz):
    return wiz.page(wiz._page_ids["progress"])


def _run_to_completion(qapp, page, timeout_ms=5000):
    if page.worker is not None:
        page.worker.wait(timeout_ms)
    for _ in range(500):
        qapp.processEvents()
        if page.isComplete():
            break


def _held_wl(tmp_path, origin):
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      output_dir=str(tmp_path / "out"), secureboot_key=origin)
    return synthesize(cfg)


def _finished_session_with_held_files(tmp_path, wl, status=build_sessions.FAILED):
    """A persisted record whose dispatch consumed held files — what a fresh Studio
    process finds when the operator hits Restart."""
    s = build_sessions.new_session(wl, GENERATOR_DIR)
    s.held_secret_files = [{"field": "secureboot_key", "name": "kernel_key.pem",
                            "sha256": "ab" * 32}]
    build_sessions.start(s)
    build_sessions.finish(s, status)
    return s


def test_restart_missing_held_file_declined_aborts_dispatch(monkeypatch, wiz, tmp_path):
    """Fresh process (empty vault) + a record naming a held file: declining the
    prompt must ABORT — honest message, no worker, no record rewrite, and no silent
    fallback to the stale path (which here even still exists on disk)."""
    _fake_builddriver(monkeypatch)
    origin = _key_file(tmp_path)                       # deliberately still present
    wl = _held_wl(tmp_path, origin)
    s = _finished_session_with_held_files(tmp_path, wl)
    prompts = []
    monkeypatch.setattr(type(_progress_page(wiz)), "_reprompt_held_file",
                        lambda self, rec, wl: (prompts.append(rec), False)[1])
    wiz.worklist = wl
    wiz.build_backend = None
    wiz.pending_session_id = s.id
    page = _progress_page(wiz)
    page.initializePage()
    assert prompts and prompts[0]["field"] == "secureboot_key"
    text = page.log.toPlainText()
    assert "Build not started" in text and "not re-selected" in text
    assert "NOT silently reused" in text
    assert page.worker is None and page._session is None      # nothing dispatched
    # the record on disk kept its prior truth (no start() rewrite)
    assert build_sessions.load(s.path()).status == build_sessions.FAILED


def test_restart_reprompt_reselect_rebuilds_with_fresh_hold(monkeypatch, qapp, wiz, tmp_path):
    """Accepting the prompt re-holds and the dispatch proceeds; the updated record
    names the NEW fingerprint (content-free) and the config snapshot follows the
    re-selected path."""
    _fake_builddriver(monkeypatch)
    stale = str(tmp_path / "gone.pem")                 # the recorded path is dead
    wl = _held_wl(tmp_path, stale)
    s = _finished_session_with_held_files(tmp_path, wl)
    fresh = _key_file(tmp_path, "fresh.pem", b"NEW-KEY-BYTES")

    def fake_reprompt(self, rec, wl_arg):
        entry = secret_files.vault().hold(rec["field"], fresh)
        setattr(wl_arg.base, rec["field"], entry.origin)
        return True

    monkeypatch.setattr(type(_progress_page(wiz)), "_reprompt_held_file", fake_reprompt)
    wiz.worklist = wl
    wiz.build_backend = None
    wiz.pending_session_id = s.id
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert page.isComplete() and page.driver.results[0].status == "ok"
    on_disk = build_sessions.load(s.path())
    assert on_disk.status == build_sessions.COMPLETE
    held_row = on_disk.held_secret_files[0]
    assert held_row["name"] == "fresh.pem"
    assert held_row["sha256"] != "ab" * 32             # the new selection's fingerprint
    assert on_disk.worklist().base.secureboot_key == fresh


def test_restart_with_vault_still_populated_skips_the_prompt(monkeypatch, qapp, wiz, tmp_path):
    """Same-process retry of a FAILED run: entries were KEPT, so no prompt fires."""
    _fake_builddriver(monkeypatch)
    origin = _key_file(tmp_path)
    secret_files.vault().hold("secureboot_key", origin)
    wl = _held_wl(tmp_path, origin)
    s = _finished_session_with_held_files(tmp_path, wl)
    called = []
    monkeypatch.setattr(type(_progress_page(wiz)), "_reprompt_held_file",
                        lambda self, rec, wl_arg: (called.append(rec), True)[1])
    wiz.worklist = wl
    wiz.build_backend = None
    wiz.pending_session_id = s.id
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert called == []
    assert page.isComplete()


# ── lifecycle: drop on COMPLETE, keep on FAILED ─────────────────────────────────────
def test_complete_run_drops_consumed_entries(monkeypatch, qapp, wiz, tmp_path):
    _fake_builddriver(monkeypatch, code=0)
    origin = _key_file(tmp_path)
    secret_files.vault().hold("secureboot_key", origin)
    wiz.worklist = _held_wl(tmp_path, origin)
    wiz.build_backend = None
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert page._session.status == build_sessions.COMPLETE
    assert not secret_files.vault().has("secureboot_key")   # the operator's lifecycle


def test_failed_run_keeps_entries_for_the_retry(monkeypatch, qapp, wiz, tmp_path):
    _fake_builddriver(monkeypatch, code=1)
    origin = _key_file(tmp_path)
    secret_files.vault().hold("secureboot_key", origin)
    wiz.worklist = _held_wl(tmp_path, origin)
    wiz.build_backend = None
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert page._session.status == build_sessions.FAILED
    assert secret_files.vault().has("secureboot_key")       # retry consumes it
