"""Create nodes for local cloud — WHICH saved mesh the node images import (GUI + TUI).

The fix round on "save the mesh being worked on": a record can now be a DRAFT,
saved before its mesh ever ran. The node-image pages must import the newest mesh
that RAN (not a newer draft), say NEVER RAN when a draft is imported, and let the
operator pick any record of this checkout — inline, never a modal. The GUI picker is
looked at, not only tested: the visibility/size test below is the "193 green tests
and nobody could see the control" rule.

Real wizard on Qt's offscreen platform; k8s is stubbed exactly as
test_localcloud_nodes.py does, so no test can touch a live cluster.
"""
import os
import socket
import time
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import saved_meshes as sm  # noqa: E402
from hugmesh_studio.core import vaults  # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages import localcloud_nodes as lc_mod  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402
from hugmesh_studio.tui import journey  # noqa: E402
from hugmesh_studio.tui import localcloud as tui_lc  # noqa: E402

from _helpers import advance_to, pick_mode  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    monkeypatch.setattr(lc_mod, "local_k8s_running", lambda _gd: False)

    def _never(_gd, on_line=None, cancel=None):
        raise AssertionError("local_k8s_teardown called without a test stubbing it")
    monkeypatch.setattr(lc_mod, "local_k8s_teardown", _never)
    monkeypatch.setattr(vaults, "list_volumes", lambda *a, **k: [])
    monkeypatch.setattr(sm, "_repo_rows", lambda root: [])


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.resize(736, 760)
    w.show()
    yield w
    page = w.page(w._page_ids["localcloud"])
    for name in ("_k8s_probe", "worker"):
        t = getattr(page, name, None)
        try:
            if t is not None:
                t.wait(5000)
        except RuntimeError:
            pass
    qapp.processEvents()
    w.close()


class _Node:
    web_url = "https://localhost:8488"
    plain_web_url = "http://localhost:8088"

    def __init__(self, running):
        self.running = running

    def _build_env(self, extra_env=None, *, write_overlays=True):
        return dict(os.environ, ENV="test")

    def status(self):
        return SimpleNamespace(running=self.running)

    def running_env(self):
        return "test" if self.running else ""

    def onion_url(self):
        return ""


class _Boot:
    secrets_json = ""

    def superadmin_login(self):
        return None


def _save(domain, tor, *, running, label):
    cfg = LocalMeshBootstrapConfig(cluster_domain=domain, kind_addons=(),
                                   services=("tor",) if tor else (), with_tor=tor)
    # kind_running=False: both lanes checked and down, so a not-running save is a
    # true draft ("never ran"), not one whose DevOps lane was unchecked
    rec = sm.capture(GENERATOR_DIR, cfg, _Node(running), _Boot(), label=label,
                     kind_running=False)
    assert sm.save(rec)
    time.sleep(1.05)        # `updated` has one-second resolution: keep the order real
    return rec


def _gate(wiz, qapp):
    pick_mode(wiz, "localcloud")
    page = advance_to(wiz, wizard_mod.LocalCloudNodesPage)
    deadline = time.monotonic() + 5
    while page._k8s_up is None and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.01)
    return page


@pytest.fixture
def ran_then_draft():
    ran = _save("running.example", True, running=True, label="the mesh that ran")
    draft = _save("draft.example", False, running=False, label="draft, never run")
    return ran, draft


# ── GUI ────────────────────────────────────────────────────────────────────────
def test_the_gui_imports_the_mesh_that_ran_not_the_newer_draft(wiz, qapp,
                                                                ran_then_draft):
    ran, draft = ran_then_draft
    page = _gate(wiz, qapp)
    assert page._domain == "running.example" and page._with_tor is True
    text = page.summary.text()
    assert "the mesh that ran" in text and "NEVER RAN" not in text
    # the picker lists the one that ran first, the draft after it, and says which
    assert page.record_pick.count() == 2
    assert page.record_pick.itemData(0) == ran.id
    assert page.record_pick.itemData(1) == draft.id
    assert "never ran" in page.record_pick.itemText(1)
    assert page.record_pick.currentIndex() == 0


def test_the_picker_is_visible_enabled_and_sanely_sized(wiz, qapp, ran_then_draft):
    page = _gate(wiz, qapp)
    for w in (page.record_row, page.record_pick, page.record_label):
        assert w.isVisible() and w.isEnabled()
    size = page.record_pick.size()
    assert size.width() >= 200 and size.height() >= 18
    # it never widens the page past the window (#661)
    assert page.minimumSizeHint().width() <= wiz.width()


def test_picking_the_draft_imports_it_and_says_it_never_ran(wiz, qapp,
                                                            ran_then_draft):
    _ran, draft = ran_then_draft
    page = _gate(wiz, qapp)
    page.record_pick.setCurrentIndex(1)
    assert page._domain == "draft.example" and page._with_tor is False
    assert "NEVER RAN" in page.summary.text()
    page.confirm.setChecked(True)
    wiz.next()
    assert wiz.cfg.cluster_domain == "draft.example"
    # back to the default: the mesh that ran again
    wiz.back()
    page.record_pick.setCurrentIndex(0)
    assert page._domain == "running.example" and page._with_tor is True


def test_with_no_saved_mesh_the_picker_is_hidden(wiz, qapp):
    page = _gate(wiz, qapp)
    assert not page.record_row.isVisible()
    assert "no saved mesh for this checkout" in page.summary.text()


# ── TUI parity ─────────────────────────────────────────────────────────────────
def _tui_gate():
    j = journey.Journey(GENERATOR_DIR)
    j.feed("")
    j.feed("2")
    assert j.slug == "localcloud"
    return j


def test_the_tui_imports_the_mesh_that_ran_and_takes_a_number(ran_then_draft):
    _ran, _draft = ran_then_draft
    j = _tui_gate()
    text = "\n".join(j.lines())
    assert "apex domain: running.example" in text and "Tor onion: on" in text
    assert "1) the mesh that ran" in text and "<- importing" in text
    assert "2) draft, never run" in text and "never ran (draft)" in text
    assert "or 1-2 to import another saved mesh" in j.prompt()
    j.feed("2")
    assert j.slug == "localcloud"                  # still asking for consent
    text = "\n".join(j.lines())
    assert "apex domain: draft.example" in text and "NEVER RAN" in text
    j.feed("9")
    assert "no saved mesh numbered 9" in j.status
    j.feed("y")
    assert j.cfg.cluster_domain == "draft.example"


# ── Tor follows the picked record (saved-meshes skeptic 2, 2026-10-21) ────────
def test_a_re_pick_after_back_does_not_keep_the_first_meshs_tor(wiz, qapp,
                                                                ran_then_draft):
    """Next imports the mesh that ran (Tor on); Back; pick the draft (Tor off): the
    summary says off, so the node images must not carry Tor either. Before the fix
    the import only ever turned Tor ON, and the first mesh's Tor stuck."""
    _ran, draft = ran_then_draft
    page = _gate(wiz, qapp)
    page.confirm.setChecked(True)
    wiz.next()
    qapp.processEvents()
    assert wiz.cfg.tor_onion_service is True
    assert wiz.cfg.cluster_domain == "running.example"
    wiz.back()
    qapp.processEvents()
    assert wiz.currentPage() is page
    page.record_pick.setCurrentIndex(page.record_pick.findData(draft.id))
    assert "Tor onion: <b>off</b>" in page.summary.text()
    page.confirm.setChecked(True)
    wiz.next()
    qapp.processEvents()
    assert wiz.cfg.cluster_domain == "draft.example"
    assert wiz.cfg.tor_onion_service is False


def test_tui_a_second_gate_pass_without_tor_clears_only_the_imported_tor():
    j = journey.Journey(GENERATOR_DIR)
    j.cfg.tor_onion_service = False
    tui_lc.apply_gate(j, "running.example", [], with_tor=True)
    assert j.cfg.tor_onion_service is True
    tui_lc.apply_gate(j, "draft.example", [], with_tor=False)
    assert j.cfg.tor_onion_service is False
    # the operator's own Tor (not set by an import) is still left alone
    k = journey.Journey(GENERATOR_DIR)
    k.cfg.tor_onion_service = True
    tui_lc.apply_gate(k, "running.example", [], with_tor=True)
    tui_lc.apply_gate(k, "draft.example", [], with_tor=False)
    assert k.cfg.tor_onion_service is True


# ── the one-shot import latch is reset by a pick (skeptic 2, R4) ───────────────
def test_a_re_pick_after_back_imports_the_new_record_with_the_same_tor(wiz, qapp):
    """Isolates the latch from the Tor rule: two meshes that both RAN, both without
    Tor, differing only in their domain. Next imports the default; Back; pick the
    other; Next must import it. Without the latch reset in _on_record_picked the
    second Next keeps the first domain (validatePage imports once per entry)."""
    _save("first.example", False, running=True, label="first")
    second = _save("second.example", False, running=True, label="second")
    page = _gate(wiz, qapp)
    assert page.record_pick.itemData(0) == second.id      # newest that ran
    first_id = page.record_pick.itemData(1)
    page.confirm.setChecked(True)
    wiz.next()
    qapp.processEvents()
    assert wiz.cfg.cluster_domain == "second.example"
    wiz.back()
    qapp.processEvents()
    assert wiz.currentPage() is page
    page.record_pick.setCurrentIndex(page.record_pick.findData(first_id))
    page.confirm.setChecked(True)
    wiz.next()
    qapp.processEvents()
    assert wiz.cfg.cluster_domain == "first.example"
    assert wiz.cfg.tor_onion_service is False


def test_a_re_pick_after_back_turns_tor_on_for_a_mesh_that_ran_it(wiz, qapp,
                                                                  ran_then_draft):
    """The other direction: import the draft (Tor off) first, Back, pick the mesh
    that ran Tor — the images carry Tor, as the summary says."""
    ran, draft = ran_then_draft
    page = _gate(wiz, qapp)
    page.record_pick.setCurrentIndex(page.record_pick.findData(draft.id))
    page.confirm.setChecked(True)
    wiz.next()
    qapp.processEvents()
    assert wiz.cfg.cluster_domain == "draft.example"
    assert wiz.cfg.tor_onion_service is False
    wiz.back()
    qapp.processEvents()
    page.record_pick.setCurrentIndex(page.record_pick.findData(ran.id))
    assert "Tor onion: <b>on</b>" in page.summary.text()
    page.confirm.setChecked(True)
    wiz.next()
    qapp.processEvents()
    assert wiz.cfg.cluster_domain == "running.example"
    assert wiz.cfg.tor_onion_service is True


# ── an Overwrite made with nothing running is not "never ran" in the picker ────
def test_the_picker_says_not_run_as_saved_for_an_overwritten_mesh_that_ran(wiz, qapp):
    ran = _save("lab.example", True, running=True, label="lab mesh")
    ran_at = ran.last_seen["at"]
    cfg = LocalMeshBootstrapConfig(cluster_domain="lab.example", kind_addons=(),
                                   services=("tor",), with_tor=True)
    over = sm.capture(GENERATOR_DIR, cfg, _Node(False), _Boot(), overwrite=ran)
    assert sm.save(over)
    page = _gate(wiz, qapp)
    assert page.record_pick.count() == 1
    text = page.record_pick.itemText(0)
    assert "never ran" not in text and "not run as saved" in text, text
    summary = page.summary.text()
    assert "NEVER RAN" not in summary and "NOT RUN AS SAVED" in summary, summary
    assert ran_at[:16].replace("T", " ") in summary
    # TUI parity: the same words on the text gate
    j = _tui_gate()
    tui = "\n".join(j.lines())
    assert "NEVER RAN" not in tui and "NOT RUN AS SAVED" in tui, tui
