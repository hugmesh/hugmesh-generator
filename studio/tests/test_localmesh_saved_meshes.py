"""The SAVED MESHES table + the Actions-row 'Save current mesh' (formerly 'Save this mesh') on the local-mesh page (ask C).

Headless (QT_QPA_PLATFORM=offscreen); every docker/git override point is faked the way
test_localmesh_page_entry_offthread.py fakes them, so nothing here shells out.
The Studio state dir is the autouse tmp dir, so the records these tests write
never touch ~/.hugmesh.
"""
from __future__ import annotations

import json
import os
import threading
import time
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import local_mesh_bootstrap as lmb          # noqa: E402
from hugmesh_studio.core import saved_meshes as sm                   # noqa: E402
from hugmesh_studio.core import vaults                               # noqa: E402
from hugmesh_studio.core.local_services import local_slugs           # noqa: E402
from hugmesh_studio.core.mesh_node import MeshNode, MeshStatus       # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod      # noqa: E402
from hugmesh_studio.gui.pages import _saved_meshes_widget as smw     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                          # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

_PROBE_ATTRS = ("_probe", "_node_probe", "_e2e_probe", "_saved_probe")


@pytest.fixture(scope="module")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


class _Stack:
    """A LocalStackNode stand-in: instant, records what was asked of it."""
    web_url = "https://localhost:8488"
    plain_web_url = "http://localhost:8088"

    def __init__(self):
        self.calls: list[str] = []
        self.threads: list[int] = []
        self.running = False

    def status(self):
        return SimpleNamespace(running=self.running, detail="faked")

    def e2e_ready(self, environment="docker"):
        return ["faked: not ready"]

    def _build_env(self, extra_env=None, *, write_overlays=True):
        return dict(os.environ, ENV="test")

    def running_env(self):
        return "test"

    def onion_url(self):
        return ""

    def start(self, on_line=None, cancel=None):
        self.calls.append("start")
        self.threads.append(threading.get_ident())
        return True, "up"

    def seed(self, extra_env=None, timeout=600, on_line=None, cancel=None):
        self.calls.append("seed")
        return True, "seeded"

    def preflight(self):
        return []


#: the probe answer every record gets unless a test overrides it
_PROBE_OK = {"volumes_present": True, "images_present": True, "creds_match": True,
             "mesh_running": False, "source_ok": True, "copies_missing": (),
             "source_drift": (), "volumes_missing": (), "volumes_seen": 3}


@pytest.fixture
def page(qapp, monkeypatch):
    stack = _Stack()
    probe = {"answer": dict(_PROBE_OK), "threads": []}

    def fake_probe_state(rec, project=""):
        probe["threads"].append(threading.get_ident())
        return dict(probe["answer"])

    monkeypatch.setattr(MeshNode, "status",
                        lambda self: MeshStatus(running=False, detail="not started"))
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "_stack_node", lambda self: stack)
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "guard_host_local",
                        lambda self: (True, ""))
    monkeypatch.setattr(sm, "probe_state", fake_probe_state)
    p = localmesh_mod.LocalMeshPage(
        SimpleNamespace(generator_dir=GENERATOR_DIR, cfg=SimpleNamespace(),
                        localmesh_selected=True))
    p.stack, p.probe = stack, probe
    yield p
    for name in _PROBE_ATTRS:
        t = getattr(p, name, None)
        if t is not None:
            t.wait(5000)
    w = getattr(p, "worker", None)
    if w is not None:
        w.wait(5000)
    qapp.processEvents()
    p.deleteLater()


def _settle(qapp, page, timeout_s=8.0):
    deadline = time.monotonic() + timeout_s
    idle = 0
    while time.monotonic() < deadline and idle < 20:
        for n in _PROBE_ATTRS:
            t = getattr(page, n, None)
            if t is not None:
                t.wait(200)
        w = getattr(page, "worker", None)
        if w is not None:
            w.wait(200)
        qapp.processEvents()
        busy = any(getattr(page, n, None) is not None and getattr(page, n).isRunning()
                   for n in _PROBE_ATTRS) or page._running
        idle = 0 if busy else idle + 1
        time.sleep(0.005)
    qapp.processEvents()


def _record(label="saved one", **over) -> sm.SavedMesh:
    rec = sm.SavedMesh(id=sm.new_id(), label=label, generator_dir=GENERATOR_DIR,
                       hostname=__import__("socket").gethostname())
    rec.config = lmb.LocalMeshBootstrapConfig(services=("tuwunel",),
                                              kind_addons=()).to_dict()
    rec.volumes = {"included": False, "inventory": [{"name": f"v{i}"} for i in range(3)]}
    rec.credentials = {"superadmin_username": "sa",
                       "e2e_file": {"copied": False, "copy": ""},
                       "secrets_json": {"copied": False, "copy": ""}}
    for k, v in over.items():
        setattr(rec, k, v)
    assert sm.save(rec)
    return rec


def _select(page, row=0):
    page.saved_meshes.table.selectRow(row)
    page.saved_meshes._update_buttons()


# ── apply_bootstrap ↔ collect_bootstrap ───────────────────────────────────────
def test_apply_bootstrap_round_trips_collect_bootstrap(qapp, page, tmp_path):
    """THE fidelity test: every page-owned field non-default, including the
    None-vs-() distinction for services/kind_addons."""
    page.login_theme.primary.setText("#123456")
    page.login_theme.secondary.setText("#654321")
    css = page.login_theme.compose_css()
    assert css and not page.login_theme.error_text()
    form = page.theme_form()
    svcs = tuple(s for s in local_slugs() if s != "egress-vpn")
    cfg = lmb.LocalMeshBootstrapConfig(
        env="prod", superadmin_username="root", social="tuwunel" in svcs,
        with_tor="tor" in svcs, services=svcs, cluster_domain="example.org",
        login_server="https://hs.example.org", brand="acme-x",
        source_mode="existing", source_dir=str(tmp_path), web_locales=("de", "fr"),
        login_theme_css=css, idp="oidc", idp_issuer="https://id.example.org",
        idp_client_id="cid", idp_jwks="https://id.example.org/jwks",
        kind_addons=())
    # scramble the theme first so the round-trip has to restore it
    page.login_theme.primary.setText("")
    missing = page.apply_bootstrap(cfg, form=form)
    assert missing == ["auth_key"]
    assert page.collect_bootstrap() == cfg
    # …and the other direction of the two tuple fields
    cfg2 = lmb.LocalMeshBootstrapConfig(services=(), kind_addons=("metrics-server",))
    page.apply_bootstrap(cfg2, form={})
    got = page.collect_bootstrap()
    assert got.services == () and got.kind_addons == ("metrics-server",)


def test_apply_bootstrap_restores_the_web_chrome_the_record_carries(qapp, page):
    """commit() writes seventeen login_* inputs into the record's form; load()
    reads all seventeen back. apply_bootstrap used to filter the form against an
    eight-key whitelist, so the nine web-chrome inputs (header hidden, header /
    footer colours and sizes, background effect) were dropped on every Load /
    Restore: the group reloaded the shipped page, compose_css() derived a
    DIFFERENT login page, and _not_applied_text still said "every field applied".
    This test sets two chrome inputs, scrambles them, and requires the record
    to bring them — and the identical derived css — back."""
    g = page.login_theme
    g.primary.setText("#123456")
    g.secondary.setText("#654321")
    g.set_chrome("header_hidden", True)
    g.set_chrome("footer_bg", "#101010")
    css = g.compose_css()
    assert css and not g.error_text()
    form = page.theme_form()
    assert form["login_header_hidden"] is True and form["login_footer_bg"] == "#101010"
    cfg = lmb.LocalMeshBootstrapConfig(login_theme_css=css)
    # scramble the chrome so the round-trip has to restore it — and prove the
    # scramble changed the derived css, or the equality below proves nothing
    g.set_chrome("header_hidden", False)
    g.set_chrome("footer_bg", "")
    assert g.compose_css() != css
    missing = page.apply_bootstrap(cfg, form=form)
    assert "login_theme_css" not in missing
    assert g.chrome["header_hidden"] is True
    assert g.chrome["footer_bg"] == "#101010"
    assert page.collect_bootstrap().login_theme_css == css


def test_apply_bootstrap_leaves_the_auth_key_empty_and_reports_it(qapp, page):
    page.boot_auth_key.setText("typed-by-hand")
    missing = page.apply_bootstrap(lmb.LocalMeshBootstrapConfig(auth_key="tskey-x"))
    assert "auth_key" in missing
    assert page.boot_auth_key.text() == "typed-by-hand"     # never overwritten
    page.boot_auth_key.setText("")
    page.apply_bootstrap(lmb.LocalMeshBootstrapConfig(auth_key="tskey-x"))
    assert page.boot_auth_key.text() == ""


def test_apply_bootstrap_reports_none_selections_and_a_gone_source_tree(qapp, page):
    before = {s: b.isChecked() for s, b in page.kind_addon_boxes.items()}
    missing = page.apply_bootstrap(lmb.LocalMeshBootstrapConfig(
        services=None, kind_addons=None, source_mode="existing",
        source_dir="/definitely/not/here"))
    assert {"services", "kind_addons", "source_dir", "auth_key"} <= set(missing)
    assert {s: b.isChecked() for s, b in page.kind_addon_boxes.items()} == before


def test_apply_bootstrap_refreshes_the_plan_once(qapp, page, monkeypatch):
    calls = []
    orig = lmb.LocalMeshBootstrap.plan
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "plan",
                        lambda self: calls.append(1) or orig(self))
    page.apply_bootstrap(lmb.LocalMeshBootstrapConfig(
        env="prod", cluster_domain="x.org", services=("tuwunel", "tor"),
        web_locales=("de",), kind_addons=()))
    assert len(calls) == 1, f"the plan preview re-rendered {len(calls)} times"
    assert page._applying_bootstrap is False


# ── the section ───────────────────────────────────────────────────────────────
def test_saved_section_is_open_at_zero_records_because_it_holds_the_save(qapp, page):
    """It USED to fold away at zero records. Since 2026-10-21 the section also holds
    the 'Save current mesh' strip, and a fold there hid the one place to save a mesh
    nobody had saved yet — exactly what the operator reported ("Saved meshes screen
    does not give anywhere to save the mesh we just started working on")."""
    page.initializePage()
    assert page.saved_meshes.record_count() == 0
    assert page.saved_section.is_expanded()
    assert page.saved_meshes.save_btn.isEnabled(), page.saved_meshes.save_btn.toolTip()
    # It sits BEFORE the Actions row — the operator asked for the saved-mesh table to
    # be in front of them when they go to generate a new mesh. Issue #334 split the two
    # into separate sections (and separate wizard steps), so the ordering is now
    # asserted between those sections rather than between two widgets of one layout:
    # "review" (which hosts saved_section) precedes "bringup" (which hosts the Actions
    # flow box) in the page body, and the review STEP precedes the bring-up step.
    body = page._body
    idx = [body.indexOf(page.sections["review"]), body.indexOf(page.sections["bringup"])]
    assert idx[0] >= 0 and idx[1] >= 0 and idx[0] < idx[1]
    assert page.sections["review"].layout().indexOf(page.saved_section) >= 0
    assert page.sections["bringup"].layout().indexOf(
        page.boot_start_btn.parentWidget()) >= 0
    _settle(qapp, page)


def test_zero_records_shows_the_grey_note_not_a_hidden_widget(qapp, page):
    page.initializePage()
    assert not page.saved_meshes.empty_note.isHidden()
    assert "Save current mesh" in page.saved_meshes.empty_note.text()
    page.saved_section.set_expanded(True)
    assert not page.saved_meshes.isHidden(), "the widget hid itself at zero rows"
    _settle(qapp, page)


def test_saved_section_expands_by_default_when_records_exist(qapp, page):
    rec = _record()
    page.initializePage()
    assert page.saved_meshes.record_count() == 1
    assert page.saved_section.is_expanded()
    assert page.saved_meshes.empty_note.isHidden()
    table = page.saved_meshes.table
    assert table.item(0, smw._SM_COL_MESH).text() == rec.label
    assert table.item(0, smw._SM_COL_SERVICES).text() == "tuwunel"
    _settle(qapp, page)


def test_a_manual_fold_survives_a_page_revisit(qapp, page):
    _record()
    page.initializePage()
    assert page.saved_section.is_expanded()
    page.saved_section.toggle.click()               # the OPERATOR folds it
    assert not page.saved_section.is_expanded()
    page.initializePage()
    assert not page.saved_section.is_expanded(), "the revisit re-opened a manual fold"
    _settle(qapp, page)


# ── Save ──────────────────────────────────────────────────────────────────────
def test_save_needs_no_running_mesh_but_the_copy_box_does(qapp, page):
    """The Actions row's save was greyed until a mesh was RUNNING, so a mesh being
    worked on could not be saved at all (operator, 2026-10-21). Saving is now gated
    by a running VERB only; copying credential files still needs a mesh that is up,
    because the files on disk belong to whatever mesh last ran."""
    for up in (False, None):
        page._mesh_up = up
        page._set_verbs_enabled(True)
        assert page.save_mesh_btn.isEnabled(), f"_mesh_up={up}"
        assert page.save_mesh_btn.text() == "Save current mesh"
        assert "does not need the mesh to be running" in page.save_mesh_btn.toolTip()
        assert not page.save_copy_creds.isEnabled(), f"_mesh_up={up}"
        assert "POINTERS" in page.save_copy_creds.toolTip()
    page._mesh_up = True
    page._set_verbs_enabled(True)
    assert page.save_mesh_btn.isEnabled() and page.save_copy_creds.isEnabled()
    assert "NOT saved" in page.save_mesh_btn.toolTip()
    assert not page.save_copy_creds.isChecked(), "credential copying must default OFF"
    page._running = True
    page._sync_saved_gate()
    assert not page.save_mesh_btn.isEnabled()
    assert "verb is running" in page.save_mesh_btn.toolTip()
    page._running = False
    _settle(qapp, page)


def test_save_runs_off_the_gui_thread(qapp, page, monkeypatch):
    seen = {}

    def fake_capture(gen, cfg, node, boot, **kw):
        seen["thread"] = threading.get_ident()
        seen["kw"] = kw
        rec = sm.SavedMesh(id=sm.new_id(), label="captured", generator_dir=gen)
        rec.config = cfg.to_dict()
        return rec
    monkeypatch.setattr(sm, "capture", fake_capture)
    page.initializePage()
    _settle(qapp, page)
    page._mesh_up = True
    page._set_verbs_enabled(True)
    page.save_mesh_btn.click()
    assert page._running
    _settle(qapp, page)
    assert seen["thread"] != threading.get_ident(), "capture ran on the GUI thread"
    assert seen["kw"]["copy_credentials"] is False
    assert page.saved_meshes.record_count() == 1
    assert page.saved_meshes.table.item(0, smw._SM_COL_MESH).text() == "captured"
    assert "captured" in page.log.toPlainText()


# ── Start / Restore ───────────────────────────────────────────────────────────
def _launch_spy(page, monkeypatch):
    calls = []
    orig = page._launch

    def spy(label, fn, stream=False, cancellable=False, verb=""):
        calls.append({"label": label, "verb": verb, "stream": stream})
        return orig(label, fn, stream=stream, cancellable=cancellable, verb=verb)
    monkeypatch.setattr(page, "_launch", spy)
    return calls


def test_start_warm_launches_stack_start_with_no_verb_id(qapp, page, monkeypatch):
    def never(self, *a, **k):
        raise AssertionError("a warm start must not mint or run up()")
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "generate_creds", never)
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "up", never)
    monkeypatch.setattr(page, "_bootstrap_up", lambda: (_ for _ in ()).throw(
        AssertionError("_bootstrap_up must not be used for a saved mesh")))
    rec = _record()
    page.initializePage()
    _settle(qapp, page)
    page._mesh_up = False
    page._set_verbs_enabled(True)
    calls = _launch_spy(page, monkeypatch)
    page._start_saved(rec, sm.MODE_START)
    assert calls and calls[0]["label"].startswith("Starting saved mesh")
    assert calls[0]["verb"] == ""                     # no mint-and-seed ladder
    _settle(qapp, page)
    assert page.stack.calls == ["start"]              # start ONLY — no seed
    assert threading.get_ident() not in page.stack.threads


def test_start_cold_routes_through_boot_restore(qapp, page, monkeypatch):
    restored = []
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "restore",
                        lambda self, rec, on_line=None, cancel=None:
                        restored.append(rec.id) or (True, ["[done]"]))

    def never(self, *a, **k):
        raise AssertionError("restore must never mint")
    monkeypatch.setattr(lmb.LocalMeshBootstrap, "generate_creds", never)
    monkeypatch.setattr(page, "_bootstrap_up", lambda: (_ for _ in ()).throw(
        AssertionError("_bootstrap_up must not be used for a saved mesh")))
    rec = _record()
    page.initializePage()
    _settle(qapp, page)
    page._mesh_up = False
    page._set_verbs_enabled(True)
    calls = _launch_spy(page, monkeypatch)
    page._start_saved(rec, sm.MODE_RESEED)
    assert calls and calls[0]["label"].startswith("Restoring saved mesh")
    assert calls[0]["verb"] == ""
    _settle(qapp, page)
    assert restored == [rec.id]
    assert page.stack.calls == []


def test_start_runs_the_records_config_not_the_forms_recollection(qapp, page, monkeypatch):
    """A CLI-made record says services=None (profile defaults) and social=True
    while the form's boxes hold something else: what RUNS is the record — the
    form only shows it, and says what it could not apply — and the one field a
    record never carries (the auth key) comes from the form."""
    rec = _record()
    rec.config = lmb.LocalMeshBootstrapConfig(
        services=None, social=True, superadmin_username="recadmin").to_dict()
    sm.save(rec)
    page.initializePage()
    _settle(qapp, page)
    page._mesh_up = False
    page._set_verbs_enabled(True)
    slug = next(s for s in page.service_boxes if s != "egress-vpn")
    page.service_boxes[slug].setChecked(True)          # the form disagrees
    page.boot_auth_key.setText("tskey-typed")
    calls = _launch_spy(page, monkeypatch)
    page._start_saved(rec, sm.MODE_START)
    _settle(qapp, page)
    assert calls and page.stack.calls == ["start"]
    cfg = page.boot.cfg
    assert cfg.services is None and cfg.social is True
    assert cfg.superadmin_username == "recadmin"
    assert cfg.auth_key == "tskey-typed"
    assert page.collect_bootstrap().services is not None    # the form shows boxes…
    assert "services" in page.saved_meshes.note.text()      # …and says so


def test_start_is_refused_while_a_mesh_is_running(qapp, page, monkeypatch):
    rec = _record()
    page.initializePage()
    _settle(qapp, page)
    page._mesh_up = True
    page._set_verbs_enabled(True)
    calls = _launch_spy(page, monkeypatch)
    page._start_saved(rec, sm.MODE_START)
    assert calls == [] and "stop it first" in page.status.text()
    _select(page)
    assert not page.saved_meshes.start_btn.isEnabled()
    assert "stop it first" in page.saved_meshes.start_btn.toolTip()


def test_rows_state_what_a_restore_gives_back_before_the_click(qapp, page):
    _record()
    page.initializePage()
    _settle(qapp, page)
    page._mesh_up = False
    page._set_verbs_enabled(True)
    table = page.saved_meshes.table
    assert table.item(0, smw._SM_COL_RESTORE).text().startswith("Start: reattaches 3")
    assert table.item(0, smw._SM_COL_VOLUMES).text() == "3 present"
    _select(page)
    w = page.saved_meshes
    assert w.start_btn.isEnabled() and not w.restore_btn.isEnabled()
    assert w.load_btn.isEnabled()
    # volumes gone -> the row flips to reseed, and the buttons follow
    page.probe["answer"] = dict(_PROBE_OK, volumes_present=False)
    page._probe_saved(w.records())
    _settle(qapp, page)
    assert table.item(0, smw._SM_COL_RESTORE).text().startswith("Restore (reseed)")
    assert table.item(0, smw._SM_COL_VOLUMES).text() == "gone (cleaned)"
    _select(page)
    assert not w.start_btn.isEnabled() and w.restore_btn.isEnabled()


def test_a_probe_that_docker_could_not_answer_offers_neither_verb(qapp, page):
    """#361: a wedged/unreachable docker made the probe say volumes gone + nothing
    running, so the row OFFERED Restore (reseed) — over a live mesh once docker answered
    again. The probe now reports None ('did not answer') and the row must disable BOTH
    verbs and say it does not know, even though the page's own _mesh_up reads False
    (LocalStackNode.status() also returns running=False when docker raises)."""
    _record()
    w = page.saved_meshes
    table = w.table
    for answer in (
            dict(_PROBE_OK, mesh_running=None),                  # only `docker ps` failed
            dict(_PROBE_OK, volumes_present=None, images_present=None,
                 mesh_running=None, volumes_missing=())):        # docker down altogether
        page.probe["answer"] = answer
        page.initializePage()
        _settle(qapp, page)
        page._mesh_up = False
        page._set_verbs_enabled(True)
        page._probe_saved(w.records())
        _settle(qapp, page)
        restore_cell = table.item(0, smw._SM_COL_RESTORE).text()
        assert not restore_cell.startswith(("Start", "Restore (reseed)")), restore_cell
        _select(page)
        assert not w.start_btn.isEnabled() and not w.restore_btn.isEnabled()
    assert table.item(0, smw._SM_COL_VOLUMES).text() == "unknown"


def test_start_is_disabled_for_a_record_from_another_checkout(qapp, page):
    _record(generator_dir="/somewhere/else/hugmesh-generator")
    page.initializePage()
    _settle(qapp, page)
    page._mesh_up = False
    page._set_verbs_enabled(True)
    _select(page)
    w = page.saved_meshes
    assert not w.start_btn.isEnabled()
    assert "another checkout" in w.start_btn.toolTip()
    assert "another checkout" in w.table.item(0, smw._SM_COL_MESH).toolTip().lower() \
        or "ANOTHER checkout" in w.table.item(0, smw._SM_COL_MESH).toolTip()
    assert w.load_btn.isEnabled()


def test_restore_is_disabled_when_a_declared_credential_copy_is_missing(qapp, page):
    rec = _record(credentials={
        "superadmin_username": "sa",
        "e2e_file": {"copied": True, "copy": "nowhere/e2e-credentials"},
        "secrets_json": {"copied": False, "copy": ""}})
    page.probe["answer"] = dict(_PROBE_OK, volumes_present=False,
                                copies_missing=tuple(rec.credential_copies()))
    page.initializePage()
    _settle(qapp, page)
    page._mesh_up = False
    page._set_verbs_enabled(True)
    _select(page)
    w = page.saved_meshes
    assert not w.restore_btn.isEnabled() and not w.start_btn.isEnabled()
    assert "e2e-credentials" in w.restore_btn.toolTip()
    assert w.table.item(0, smw._SM_COL_RESTORE).text().startswith("Blocked")


def test_load_into_the_form_applies_without_launching(qapp, page, monkeypatch):
    rec = _record()
    rec.config["cluster_domain"] = "loaded.example"
    rec.config["env"] = "prod"
    sm.save(rec)
    page.initializePage()
    _settle(qapp, page)
    calls = _launch_spy(page, monkeypatch)
    _select(page)
    page.saved_meshes.load_btn.click()
    assert calls == []
    assert page.boot_domain.text() == "loaded.example" and page.env_prod.isChecked()
    assert "Loaded" in page.saved_meshes.note.text()
    assert "auth key" in page.saved_meshes.note.text()


# ── Delete ────────────────────────────────────────────────────────────────────
def test_delete_requires_the_typed_label(qapp, page):
    rec = _record(label="keep me")
    page.initializePage()
    _settle(qapp, page)
    _select(page)
    w = page.saved_meshes
    assert not w.delete_btn.isEnabled()
    w.delete_btn.click()
    assert os.path.isfile(rec.path())
    w.confirm.setText("keep m")
    assert not w.delete_btn.isEnabled()
    w.confirm.setText("keep me")
    assert w.delete_btn.isEnabled()
    assert "not touched" in w.danger.text()
    w.delete_btn.click()
    assert not os.path.exists(rec.path())
    assert w.record_count() == 0 and "Deleted" in w.note.text()


def test_delete_never_touches_volumes(qapp, page, monkeypatch):
    called = []
    monkeypatch.setattr(vaults, "remove_volume", lambda *a, **k: called.append(a))
    rec = _record(label="x")
    page.initializePage()
    _settle(qapp, page)
    _select(page)
    page.saved_meshes.confirm.setText("x")
    page.saved_meshes.delete_btn.click()
    assert not os.path.exists(rec.path()) and called == []


def test_unreadable_record_row_offers_only_delete(qapp, page):
    os.makedirs(sm.meshes_dir(), exist_ok=True)
    bad = os.path.join(sm.meshes_dir(), "20260101-000000-bad000.json")
    with open(bad, "w") as fh:
        fh.write("{broken")
    page.initializePage()
    _settle(qapp, page)
    _select(page)
    w = page.saved_meshes
    assert w.table.item(0, smw._SM_COL_SAVED).text() == "unreadable"
    assert not w.start_btn.isEnabled() and not w.restore_btn.isEnabled()
    assert not w.load_btn.isEnabled()
    w.confirm.setText(os.path.basename(bad))
    assert w.delete_btn.isEnabled()
    w.delete_btn.click()
    assert not os.path.exists(bad)


# ── house rules ───────────────────────────────────────────────────────────────
def test_table_has_no_itemChanged_connection():
    """House rules checked on the CODE (an ast walk), not on the text: the
    module's docstring is allowed to NAME the banned signal. Strip comments
    when counting wiring."""
    import ast
    tree = ast.parse(open(smw.__file__, encoding="utf-8").read())
    attrs = {n.attr for n in ast.walk(tree) if isinstance(n, ast.Attribute)}
    names = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)}
    assert "itemChanged" not in attrs
    assert "QMessageBox" not in attrs | names
    assert not {"exec", "exec_"} & attrs
    assert "remove_volume" not in attrs | names
    # …and the wiring the widget DOES use is the sanctioned pair
    assert {"cellClicked", "itemActivated"} <= attrs


def test_stop_tooltip_says_volumes_are_kept(qapp, page):
    tip = page.boot_down_btn.toolTip()
    assert "KEPT" in tip and "stack-halt" in tip
    assert "dropped" not in tip
    assert "drops the containers and volumes" not in page.boot_start_btn.toolTip()


# ── the cross-lane hand-off: a verb changes what a record's row is read FROM ──────────
def test_a_finished_verb_marks_the_saved_table_stale_without_reading_anything(page):
    """_verb_done must not re-scan directly — that would run behind the override point tests use
    to keep a page quiet while they drive verbs (`_probe_mesh_state = lambda: None`).
    It marks, and the state probe's answer is what acts."""
    page._probe_mesh_state = lambda: None
    page._save_run_log = lambda run, ok: ""
    page._runs = []
    calls = []
    page.saved_meshes.refresh = lambda: calls.append("refresh")

    page._saved_stale = False
    page._verb_done(True)

    assert page._saved_stale is True
    assert calls == [], "the re-scan must ride _on_mesh_state, not _verb_done"


def test_the_state_probes_answer_rescans_the_saved_table_exactly_once(page):
    """…and _on_mesh_state consumes the flag: one refresh, and not a second one on the
    next answer, or a page whose probe re-fires would re-scan on every tick."""
    calls = []
    page.saved_meshes.refresh = lambda: calls.append("refresh")

    page._saved_stale = True
    page._on_mesh_state(False, "not started")
    assert calls == ["refresh"]
    assert page._saved_stale is False

    page._on_mesh_state(False, "not started")
    assert calls == ["refresh"], "an unstale table must not be re-scanned"


def test_the_saved_table_is_not_rescanned_when_no_verb_has_run(page):
    """The flag starts down: entering the page already refreshed once (initializePage),
    and _on_mesh_state fires on that same entry."""
    assert page._saved_stale is False
    calls = []
    page.saved_meshes.refresh = lambda: calls.append("refresh")
    page._on_mesh_state(True, "running")
    assert calls == []


def test_the_state_probes_answer_re_probes_every_rows_facts_even_without_a_flip(qapp,
                                                                              page):
    """refresh() KEEPS the probe answers it already holds, so the override point's re-scan alone
    re-probed NOTHING: a row probed 'Start · 3 present' went on offering that Start
    after the volumes were gone whenever _mesh_up did not flip (a Clean with the mesh
    already down, a Restore that failed). The per-row facts must be re-read, not
    only the directory — and this is the no-flip case, where _sync_saved_gate does
    not do it."""
    _record()
    page.initializePage()
    _settle(qapp, page)
    page._mesh_up = False
    page._set_verbs_enabled(True)
    _settle(qapp, page)
    table = page.saved_meshes.table
    assert table.item(0, smw._SM_COL_VOLUMES).text() == "3 present"
    assert page._saved_last_up is False
    page.probe["answer"] = dict(_PROBE_OK, volumes_present=False)   # cleaned meanwhile
    n = len(page.probe["threads"])
    page._saved_stale = True
    page._on_mesh_state(False, "not started")            # False -> False: no flip
    _settle(qapp, page)
    assert len(page.probe["threads"]) > n, \
        "the seam re-scanned the disk but re-probed no row"
    assert threading.get_ident() not in page.probe["threads"]
    assert table.item(0, smw._SM_COL_VOLUMES).text() == "gone (cleaned)"
    assert table.item(0, smw._SM_COL_RESTORE).text().startswith("Restore (reseed)")


def test_a_record_that_does_not_describe_the_running_mesh_says_so_on_screen(
        qapp, page, monkeypatch):
    """capture() follows the page's configuration; the one knob it can read back
    off a running mesh is its env. A disagreement means restoring this record
    brings up a DIFFERENT mesh — so it lands in the log AND under the table, not
    just inside the JSON nobody opens."""
    def fake_capture(gen, cfg, node, boot, **kw):
        rec = sm.SavedMesh(id=sm.new_id(), label="captured", generator_dir=gen)
        rec.config = cfg.to_dict()
        rec.last_seen = {"disagrees_with_running": [
            {"field": "env", "form": "test", "running": "prod"}]}
        return rec
    monkeypatch.setattr(sm, "capture", fake_capture)
    page.initializePage()
    _settle(qapp, page)
    page._mesh_up = True
    page._set_verbs_enabled(True)
    page.save_mesh_btn.click()
    _settle(qapp, page)
    log = page.log.toPlainText()
    assert "WARNING" in log and "env=test" in log and "env=prod" in log
    note = page.saved_meshes.note.text()
    # isHidden(), not isVisible(): the page is never shown in a headless test, so
    # isVisible() is False for every widget on it whatever set_note() did.
    assert "env=prod" in note and not page.saved_meshes.note.isHidden()
    assert "not the one running now" in note


def test_an_agreeing_save_leaves_no_warning_note(qapp, page, monkeypatch):
    def fake_capture(gen, cfg, node, boot, **kw):
        rec = sm.SavedMesh(id=sm.new_id(), label="captured", generator_dir=gen)
        rec.config = cfg.to_dict()
        return rec
    monkeypatch.setattr(sm, "capture", fake_capture)
    page.initializePage()
    _settle(qapp, page)
    page._mesh_up = True
    page._set_verbs_enabled(True)
    page.save_mesh_btn.click()
    _settle(qapp, page)
    assert "WARNING" not in page.log.toPlainText()
    note = page.saved_meshes.note.text()
    assert "not the one running now" not in note and "env=" not in note
