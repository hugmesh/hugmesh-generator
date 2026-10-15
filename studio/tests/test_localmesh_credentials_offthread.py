"""The "Sign-in credentials" button: probe off the GUI thread, modal from the slot.

WHY THIS FILE EXISTS. ``_show_credentials`` used to parse three seeder scripts, build
the stack env (which WRITES the theme/limits overlay files) and then open a modal —
all inline on the click. It now starts a ``_CredsProbe`` (docker + Casdoor + stat,
blocking by contract) and constructs the dialog only in that probe's result slot.

Pinned here: the probe runs off the GUI thread; the dialog is constructed only after
the probe emits; the button is disabled and relabelled while checking and re-armed
after; a second click while checking starts no second probe; the "Start with X / Y"
lead is suppressed unless the mesh is proven seeded; the banner text is the state's
headline; and the button's tooltip no longer claims "deterministic throwaway".
"""
from __future__ import annotations

import os
import threading
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from types import SimpleNamespace                                   # noqa: E402

from hugmesh_studio.core import credentials_truth as ct             # noqa: E402
from hugmesh_studio.core import local_mesh_bootstrap as lmb         # noqa: E402
from hugmesh_studio.core.mesh_node import MeshNode, MeshStatus      # noqa: E402
from hugmesh_studio.gui.pages import _credentials_dialog as dlg_mod  # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                         # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

FIXTURE_PW = "fixture-pw-offthread-7Lk"
_PROBE_ATTRS = ("_probe", "_node_probe", "_e2e_probe", "_creds_probe")


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


class _Stack:
    """A LocalStackNode stand-in whose docker answers are scripted and whose
    ``_build_env`` writes NOTHING (the real one writes overlay files)."""
    web_url = "https://localhost:8488"

    def __init__(self, tmp_path):
        self._creds = str(tmp_path / ".e2e-credentials")
        self.env_threads: list[int] = []

    def _build_env(self, extra_env=None, *, write_overlays=True):
        self.env_threads.append(threading.get_ident())
        return {"E2E_CREDENTIALS_FILE": self._creds}

    def status(self):
        return SimpleNamespace(running=True, detail="3 container(s)")

    def e2e_ready(self, environment="docker"):
        return []

    def _probe(self, cmd, timeout=15):
        if cmd[:3] == ["docker", "volume", "ls"]:
            return 0, "hugmesh-local_casdoor-pg\n"
        if cmd[:3] == ["docker", "volume", "inspect"]:
            return 0, "2026-08-27T06:20:11-07:00"
        return 0, ""

    def seeded_user(self, username):
        return True, ""


@pytest.fixture
def page(qapp, monkeypatch, tmp_path):
    """A LocalMeshPage whose stack is faked at the override point credentials_truth documents.
    The minted bundle is a tmp file (never the operator's keys-out/), and its
    superadmin is a fixture pair."""
    stack = _Stack(tmp_path)
    (tmp_path / ".e2e-credentials").write_text("E2E_PASSWORD=" + FIXTURE_PW + "\n")
    secrets = tmp_path / "secrets.json"
    secrets.write_text("{}")
    monkeypatch.setattr(MeshNode, "status",
                        lambda self: MeshStatus(running=False, detail="not started"))
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "_stack_node", lambda self: stack)
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "secrets_json",
                        property(lambda self: str(secrets)))
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "superadmin_login",
                        lambda self: ("minted-admin", FIXTURE_PW + "-sa"))
    p = localmesh_mod.LocalMeshPage(
        SimpleNamespace(generator_dir=GENERATOR_DIR, cfg=SimpleNamespace(),
                        localmesh_selected=True))
    p.stack = stack
    yield p
    for name in _PROBE_ATTRS:
        t = getattr(p, name, None)
        if t is not None:
            t.wait(5000)
    qapp.processEvents()
    p.deleteLater()
    qapp.processEvents()


class _FakeDialog:
    """Records construction; exec() returns at once (a real modal would block)."""
    made: list[tuple] = []

    def __init__(self, roster, truth=None, front_door="", parent=None):
        _FakeDialog.made.append((roster, truth, front_door))

    def exec(self):
        return 0


@pytest.fixture
def fake_dialog(monkeypatch):
    _FakeDialog.made = []
    monkeypatch.setattr(localmesh_mod, "CredentialsDialog", _FakeDialog)
    return _FakeDialog


def _settle(qapp, page, timeout_s=8.0):
    deadline = time.monotonic() + timeout_s
    idle = 0
    while time.monotonic() < deadline and idle < 20:
        for n in _PROBE_ATTRS:
            t = getattr(page, n, None)
            if t is not None:
                t.wait(200)
        qapp.processEvents()
        busy = any(getattr(page, n, None) is not None and getattr(page, n).isRunning()
                   for n in _PROBE_ATTRS)
        idle = 0 if busy else idle + 1
        time.sleep(0.005)
    qapp.processEvents()


def test_credentials_button_probes_off_the_gui_thread(qapp, page, fake_dialog, monkeypatch):
    threads: list[int] = []
    real = ct.probe_credentials

    def recording(*a, **kw):
        threads.append(threading.get_ident())
        return real(*a, **kw)

    monkeypatch.setattr(ct, "probe_credentials", recording)
    t0 = time.monotonic()
    page.creds_btn.click()
    assert time.monotonic() - t0 < 0.5, "the click blocked — the probe is inline again"
    _settle(qapp, page)
    gui = threading.get_ident()
    assert threads and gui not in threads, "probe_credentials ran on the GUI thread"
    assert page.stack.env_threads and gui not in page.stack.env_threads, \
        "_build_env (which writes overlay files) ran on the GUI thread"
    assert len(fake_dialog.made) == 1


def test_dialog_opens_from_the_slot_not_inline(qapp, page, fake_dialog, monkeypatch):
    gate = threading.Event()
    real = ct.probe_credentials

    def parked(*a, **kw):
        gate.wait(10)
        return real(*a, **kw)

    monkeypatch.setattr(ct, "probe_credentials", parked)
    page.creds_btn.click()
    qapp.processEvents()
    assert fake_dialog.made == [], "the dialog was constructed before the probe answered"
    assert page._creds_probe is not None and page._creds_probe.isRunning()
    gate.set()
    _settle(qapp, page)
    assert len(fake_dialog.made) == 1
    roster, truth, door = fake_dialog.made[0]
    assert door == "https://localhost:8488"
    assert truth is not None and truth.state in ct.STATES
    assert roster.truth is truth
    assert page._cred_truth is truth


def test_button_is_disabled_while_checking_and_rearmed_after(qapp, page, fake_dialog, monkeypatch):
    gate = threading.Event()
    real = ct.probe_credentials
    monkeypatch.setattr(ct, "probe_credentials",
                        lambda *a, **kw: (gate.wait(10), real(*a, **kw))[1])
    assert page.creds_btn.isEnabled()
    page.creds_btn.click()
    qapp.processEvents()
    assert not page.creds_btn.isEnabled()
    assert "checking" in page.creds_btn.text().lower()
    gate.set()
    _settle(qapp, page)
    assert page.creds_btn.isEnabled()
    assert page.creds_btn.text() == "Sign-in credentials"


def test_second_click_while_checking_starts_one_probe(qapp, page, fake_dialog, monkeypatch):
    gate = threading.Event()
    calls: list[int] = []
    real = ct.probe_credentials

    def parked(*a, **kw):
        calls.append(1)
        gate.wait(10)
        return real(*a, **kw)

    monkeypatch.setattr(ct, "probe_credentials", parked)
    page.creds_btn.click()
    qapp.processEvents()
    first = page._creds_probe
    page._show_credentials()                 # a second press while checking
    page._show_credentials()
    assert page._creds_probe is first
    gate.set()
    _settle(qapp, page)
    assert calls == [1]
    assert len(fake_dialog.made) == 1


def test_probe_failure_reaches_the_dialog_as_a_roster_error_and_rearms(qapp, page, fake_dialog, monkeypatch):
    def boom(*a, **kw):
        raise RuntimeError("docker exploded")

    monkeypatch.setattr(ct, "probe_credentials", boom)
    page.creds_btn.click()
    _settle(qapp, page)
    assert page.creds_btn.isEnabled()
    roster, truth, _ = fake_dialog.made[0]
    assert truth is None
    assert "docker exploded" in roster.error


def test_mesh_state_line_gains_the_headline_once_known(qapp, page, fake_dialog):
    page._mesh_state_label.setText("Mesh state: RUNNING — 3 container(s).")
    page.creds_btn.click()
    _settle(qapp, page)
    truth = page._cred_truth
    assert truth is not None
    text = page._mesh_state_label.text()
    assert text.startswith("Mesh state: RUNNING") and text.endswith(truth.headline)
    # a second probe REPLACES the sentence rather than stacking it
    page.creds_btn.click()
    _settle(qapp, page)
    assert page._mesh_state_label.text().count(truth.headline) == 1
    assert FIXTURE_PW not in page._mesh_state_label.text()


# ── the dialog itself ─────────────────────────────────────────────────────────────

def _truth(tmp_path, state_over):
    f = tmp_path / ".e2e-credentials"
    f.write_text("E2E_PASSWORD=" + FIXTURE_PW + "\n")
    os.utime(f, (2.5, 2.5))                    # written BEFORE the recorded seed (3.0)
    creds = ct.credentials_file(str(tmp_path), {"E2E_CREDENTIALS_FILE": str(f)})
    base = dict(mesh_running=True, volumes_present=True, seeded_admin=True,
                seeded_operator=True, creds=creds, casdoor_created=1.0,
                secrets_mtime=2.0, last_seed_ok=3.0, lane=ct.LANE_COMPOSE,
                operator_user="mesh-operator", superadmin=("", ""))
    base.update(state_over)
    return ct.assess(**base)


def _roster_with(tmp_path, truth):
    from hugmesh_studio.core.seeded_credentials import annotate, load_roster
    roster = load_roster(GENERATOR_DIR,
                         {"E2E_CREDENTIALS_FILE": str(tmp_path / ".e2e-credentials")})
    return annotate(roster, truth)


def test_seeded_state_leads_with_a_live_account(qapp, tmp_path):
    truth = _truth(tmp_path, {})
    assert truth.state == ct.STATE_SEEDED
    d = dlg_mod.CredentialsDialog(_roster_with(tmp_path, truth), truth,
                                  front_door="https://localhost:8488")
    assert "Start with" in d.intro.text()
    assert "mesh-operator" in d.intro.text()
    assert d.table.horizontalHeaderItem(dlg_mod.COL_LIVE).text() == "Live"
    row = next(r for r in range(d.table.rowCount())
               if d.table.item(r, dlg_mod.COL_USER).text() == "e2e-admin")
    assert d.table.item(row, dlg_mod.COL_LIVE).text() == ct.LIVE
    assert d.table.item(row, dlg_mod.COL_PASSWORD).text() == FIXTURE_PW


def test_suspect_state_suppresses_the_start_with_line(qapp, tmp_path):
    truth = _truth(tmp_path, {"last_seed_ok": 2.0})     # file (2.5) rewritten after seed
    assert truth.state == ct.STATE_SEEDED_SUSPECT
    d = dlg_mod.CredentialsDialog(_roster_with(tmp_path, truth), truth,
                                  front_door="https://localhost:8488")
    assert "Start with" not in d.intro.text()
    assert FIXTURE_PW not in d.intro.text()
    assert "401" in d.banner.text()
    row = next(r for r in range(d.table.rowCount())
               if d.table.item(r, dlg_mod.COL_USER).text() == "e2e-admin")
    assert d.table.item(row, dlg_mod.COL_LIVE).text() == ct.STALE


def test_no_truth_never_leads_with_a_credential(qapp, tmp_path):
    d = dlg_mod.CredentialsDialog(_roster_with(tmp_path, None),
                                  front_door="https://localhost:8488")
    assert "Start with" not in d.intro.text()
    assert "Not checked" in d.banner.text()


def test_banner_text_matches_the_state(qapp, tmp_path):
    cases = {
        ct.STATE_SEEDED: {},
        ct.STATE_SEEDED_SUSPECT: {"last_seed_ok": 2.0},
        ct.STATE_UP_UNSEEDED: {"seeded_admin": False},
        ct.STATE_NO_MESH: {"mesh_running": False, "volumes_present": False,
                           "seeded_admin": None, "secrets_mtime": None},
        ct.STATE_HALTED: {"mesh_running": False, "seeded_admin": None},
        ct.STATE_UNKNOWN: {"mesh_running": None},
    }
    for state, over in cases.items():
        truth = _truth(tmp_path, over)
        assert truth.state == state, (state, truth.headline)
        d = dlg_mod.CredentialsDialog(_roster_with(tmp_path, truth), truth)
        assert d.banner.text() == truth.headline
        assert d.banner.toolTip() == truth.detail
        assert dlg_mod.banner_colour(state) in d.banner.styleSheet()
        assert FIXTURE_PW not in d.banner.text() + d.banner.toolTip() + d.source_line.text()
    assert dlg_mod.banner_colour(ct.STATE_SEEDED) != dlg_mod.banner_colour(ct.STATE_SEEDED_SUSPECT)
    assert dlg_mod.banner_colour(ct.STATE_UNKNOWN) == dlg_mod.banner_colour(ct.STATE_NO_MESH)


def test_creds_tooltip_no_longer_claims_deterministic_throwaway(qapp, page):
    tip = page.creds_btn.toolTip().lower()
    assert "deterministic" not in tip and "throwaway" not in tip
    assert "run-state" in tip
    assert "generated" in tip
    assert "deterministic" not in (dlg_mod.__doc__ or "").lower()
    assert "generated per run" in (dlg_mod.__doc__ or "").lower()


def test_no_literal_password_in_the_lane_diff():
    """No secret VALUE and no literal example password anywhere in the sources this
    lane touches — the former e2e literal included."""
    import glob
    import re
    roots = [os.path.join(STUDIO_ROOT, "hugmesh_studio", "core", "credentials_truth.py"),
             os.path.join(STUDIO_ROOT, "hugmesh_studio", "core", "seeded_credentials.py"),
             os.path.join(STUDIO_ROOT, "hugmesh_studio", "gui", "pages", "_credentials_dialog.py")]
    for path in roots:
        text = open(path, encoding="utf-8").read()
        # the retired literal as a VALUE (e2e-password.sh, the generator, is fine)
        assert not re.search(r"e2e-pass(?![a-zA-Z])", text), path
        assert FIXTURE_PW not in text, path
    assert glob.glob(os.path.join(STUDIO_ROOT, "hugmesh_studio", "core", "credentials_truth.py"))
