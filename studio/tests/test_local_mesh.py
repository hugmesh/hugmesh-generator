"""Local Docker mesh — the ModePage's fourth first-screen choice.

Pins the behavior that the flow-clarity review found unguarded: the local-mesh GATE
(the choice disables Next and reveals the inline launcher) and the LAUNCHER itself
(it must open a LocalMeshDialog without crashing and drive a MeshNode-shaped node).
A missing localmesh module used to slip through CI precisely because nothing here
exercised the launcher — this file is that missing coverage.

Runs the REAL wizard on Qt's offscreen platform; skipped whole when no Qt binding is
installed (the pure-core LocalMeshConfig/LocalMeshNode assertions still need the core
import, which does not require Qt, but they live here beside the GUI ones for locality).
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.local_mesh import (  # noqa: E402  (after the importorskip gate)
    LocalMeshConfig, LocalMeshNode,
)
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrap  # noqa: E402
from hugmesh_studio.core.mesh_node import MeshNode  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod  # noqa: E402
from hugmesh_studio.gui.pages import ModePage  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


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


def _drain_worker(qapp, host, timeout_ms=5000):
    """Join the _MeshWorker (verbs run OFF the GUI thread since the page
    conversion — the no-freeze fix) and pump the loop so its queued line/done
    signals land before the test asserts."""
    w = getattr(host, "worker", None)
    if w is not None:
        w.wait(timeout_ms)
    for _ in range(200):
        qapp.processEvents()


def _mode_page(wiz):
    return next(p for p in wiz._pages if isinstance(p, ModePage))


# ---- the GATE (this is the assertion that would have caught the missing module) ----

# (test_localmesh_choice_gates_next_and_reveals_launcher was DELETED with the popout:
# it pinned the old contract — Next disabled + a modal launcher button. The page-flow
# replacements above pin the new one: Next ENABLED, flows into the registered
# LocalMeshPage, cfg.mode untouched.)


@pytest.mark.parametrize("mode", ["mesh", "cloud", "standalone"])
def test_image_choices_stay_complete_and_hide_launcher(wiz, mode):
    # page-flow contract: EVERY choice is complete (each has a next page now), and
    # committing an image mode lowers the transient localmesh flag so LocalMeshPage
    # is dynamically skipped (applies_to reads wiz.localmesh_selected).
    mp = _mode_page(wiz)
    mp._buttons[mode].setChecked(True)
    mp._on_mode_toggled()
    assert mp.isComplete() is True
    assert mp.validatePage() is True
    assert wiz.localmesh_selected is False
    lm = wiz.page(wiz._page_ids["localmesh"])
    assert lm.applies_to(wiz.cfg) is False


# ---- the LAUNCHER: opens a real dialog, never a ModuleNotFoundError ----

def test_localmesh_choice_flows_into_the_wizard_page_not_a_popout(wiz):
    # THE CONVERSION ITSELF (operator: "follow the same gui wizard and not pop out
    # a new window"): the localmesh radio makes Next flow into the REGISTERED
    # LocalMeshPage — no dialog, no .exec(). The page is terminal for its branch.
    mp = _mode_page(wiz)
    assert not hasattr(mp, "local_btn")          # the popout launcher is GONE
    mp._buttons_by_mode = None
    for b in mp.group.buttons():
        if b.property("mode") == "localmesh":
            b.setChecked(True)
    assert mp.isComplete() is True               # Next is enabled for this choice now
    assert mp.validatePage() is True
    assert wiz.localmesh_selected is True
    lm = wiz.page(wiz._page_ids["localmesh"])
    assert lm.applies_to(wiz.cfg) is True        # the page is IN the flow
    assert lm.nextId() == -1 and lm.isFinalPage()  # and terminal: Finish, no image


def test_localmesh_never_touches_cfg_mode(wiz):
    # cfg.mode stays an IMAGE mode: picking localmesh commits NOTHING to cfg (the
    # transient flag lives on the wizard), so save()/argv can never see "localmesh".
    mp = _mode_page(wiz)
    before = wiz.cfg.mode
    for b in mp.group.buttons():
        if b.property("mode") == "localmesh":
            b.setChecked(True)
    assert mp.validatePage() is True
    assert wiz.cfg.mode == before


def test_dialog_shim_still_hosts_the_page_standalone(qapp, monkeypatch):
    # the standalone-host promise survives the conversion: LocalMeshDialog wraps the
    # SAME LocalMeshPage (one implementation, two frames) and delegates its former
    # widget surface, so pre-conversion callers keep working unchanged.
    monkeypatch.setattr(LocalMeshNode, "status", lambda self: _stopped(), raising=True)
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    assert isinstance(dlg.page, localmesh_mod.LocalMeshPage)
    assert dlg.tabs is dlg.page.tabs             # delegation, not a second copy


def test_dialog_start_builds_and_calls_a_mesh_node(qapp, monkeypatch):
    calls = {}

    def _fake_available(self):
        return True, ""

    def _fake_start(self):
        calls["auth_key"] = self.cfg.auth_key
        return True, "up"

    monkeypatch.setattr(LocalMeshNode, "available", _fake_available, raising=True)
    monkeypatch.setattr(LocalMeshNode, "start", _fake_start, raising=True)
    monkeypatch.setattr(LocalMeshNode, "status", lambda self: _stopped(), raising=True)

    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.auth_key.setText("tskey-live")
    dlg.node_name.setText("mynode")
    dlg._start()
    _drain_worker(qapp, dlg.page)
    assert calls.get("auth_key") == "tskey-live"       # launcher DID call MeshNode.start
    # the node it drives IS a MeshNode (shared lifecycle with the tray)
    assert isinstance(dlg.node, MeshNode)


def test_dialog_start_is_gated_when_auth_key_missing(qapp, monkeypatch):
    started = {"called": False}
    monkeypatch.setattr(LocalMeshNode, "start",
                        lambda self: started.__setitem__("called", True) or (True, ""),
                        raising=True)
    monkeypatch.setattr(LocalMeshNode, "status", lambda self: _stopped(), raising=True)
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.auth_key.setText("")   # no key -> available() gates, start() must NOT run
    dlg._start()
    assert started["called"] is False
    assert "auth key" in dlg.status.text().lower()


# ---- the BOOTSTRAP tab (generate & start from scratch) ----

def test_dialog_has_both_mode_tabs(qapp):
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    titles = [dlg.tabs.tabText(i) for i in range(dlg.tabs.count())]
    assert any("Join" in t for t in titles)
    assert any("scratch" in t for t in titles)


def test_bootstrap_plan_preview_populates_and_hides_prod_group(qapp):
    from hugmesh_studio.core import local_mesh_bootstrap as bmod
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    # default test env: the plan preview is rendered and the prod-only group is hidden
    assert bmod.GEN_CLUSTER_SECRETS in dlg.plan_view.toPlainText()
    assert dlg.prod_group.isHidden() is True     # prod-only group hidden in test env
    # switching to prod reveals the overlay group + re-renders the plan for prod
    dlg.env_prod.setChecked(True)
    assert dlg.prod_group.isHidden() is False
    assert "https://id." in dlg.plan_view.toPlainText()


def test_bootstrap_start_is_gated_behind_acknowledgement(qapp, monkeypatch):
    up_ran = {"called": False}
    monkeypatch.setattr(LocalMeshBootstrap, "up",
                        lambda self: up_ran.__setitem__("called", True) or (True, ["ok"]),
                        raising=True)
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    # nothing runs on mere selection: the button is disabled until acknowledged
    assert dlg.boot_start_btn.isEnabled() is False
    dlg._bootstrap_up()                       # clicking anyway is a no-op
    assert up_ran["called"] is False
    dlg.ack.setChecked(True)
    assert dlg.boot_start_btn.isEnabled() is True


def test_bootstrap_up_collects_config_and_runs(qapp, monkeypatch):
    seen = {}

    def _fake_up(self, on_line=None, cancel=None):
        seen["env"] = self.cfg.env
        seen["superadmin"] = self.cfg.superadmin_username
        seen["social"] = self.cfg.social
        if on_line is not None:
            on_line("[done] platform up")   # the real up() streams milestones too
        return True, ["[done] platform up"]

    monkeypatch.setattr(LocalMeshBootstrap, "up", _fake_up, raising=True)
    monkeypatch.setattr(LocalMeshNode, "status", lambda self: _stopped(), raising=True)

    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.superadmin.setText("root-boss")
    dlg.social.setChecked(True)
    dlg.ack.setChecked(True)
    dlg._bootstrap_up()
    _drain_worker(qapp, dlg.page)
    assert seen == {"env": "test", "superadmin": "root-boss", "social": True}
    assert "[done] platform up" in dlg.log.toPlainText()


def test_bootstrap_web_locales_widget_defaults_to_english_only(qapp):
    """The 'Web login languages' field is empty by default, so collect_bootstrap
    yields web_locales=() and the plan states English-only. This is the operator's
    'exclude' state — and the anti-dead-knob default (zero catalogs shipped)."""
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    assert dlg.web_locales.text() == ""
    assert dlg.collect_bootstrap().web_locales == ()
    assert "English only" in dlg.plan_view.toPlainText()


def test_bootstrap_web_locales_widget_collects_and_shows_in_plan(qapp):
    """Typing locales flows into the config AND updates the read-only plan preview
    — the operator sees exactly which catalogs will ship before acknowledging."""
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.web_locales.setText("de, fr")
    assert dlg.collect_bootstrap().web_locales == ("de", "fr")
    plan = dlg.plan_view.toPlainText()
    assert "de, fr" in plan
    assert "SNAP_WEB_LOCALES=de,fr" in plan


def test_bootstrap_up_carries_web_locales(qapp, monkeypatch):
    seen = {}
    monkeypatch.setattr(
        LocalMeshBootstrap, "up",
        lambda self, on_line=None, cancel=None:
            seen.update(web_locales=self.cfg.web_locales) or (True, ["ok"]),
        raising=True)
    monkeypatch.setattr(LocalMeshNode, "status", lambda self: _stopped(), raising=True)
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.web_locales.setText("en-XA")
    dlg.ack.setChecked(True)
    dlg._bootstrap_up()
    _drain_worker(qapp, dlg.page)
    assert seen == {"web_locales": ("en-XA",)}


def test_bootstrap_up_blocked_by_validation(qapp, monkeypatch):
    up_ran = {"called": False}
    monkeypatch.setattr(
        LocalMeshBootstrap, "up",
        lambda self, on_line=None, cancel=None:
            up_ran.__setitem__("called", True) or (True, []),
        raising=True)
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.env_prod.setChecked(True)     # prod without domain/key -> validate() blocks
    dlg.ack.setChecked(True)
    dlg._bootstrap_up()
    assert up_ran["called"] is False
    assert "cannot start" in dlg.status.text().lower()


# ---- the pure-core runner (no Qt, no docker needed) ----

def test_config_env_maps_the_overlay_vars():
    e = LocalMeshConfig(auth_key="  tskey-abc  ", node_name="n1",
                        login_server="https://hs.example.com").env()
    assert e["TS_AUTHKEY"] == "tskey-abc"                    # trimmed
    assert e["HUGMESH_NODE_NAME"] == "n1"
    assert e["TS_EXTRA_ARGS"] == "--accept-routes --login-server=https://hs.example.com"
    # bare config: only the accept-routes default, no node-name / login-server keys
    bare = LocalMeshConfig(auth_key="tskey-x").env()
    assert bare == {"TS_AUTHKEY": "tskey-x", "TS_EXTRA_ARGS": "--accept-routes"}


def test_available_gates_on_auth_key():
    ok, why = LocalMeshNode(GENERATOR_DIR, LocalMeshConfig(auth_key="")).available()
    assert ok is False and "auth key" in why.lower()
    # with a key present the gate defers to MeshNode (docker/template checks) — the
    # message, whatever it is, is NO LONGER the auth-key prompt.
    _, why2 = LocalMeshNode(GENERATOR_DIR, LocalMeshConfig(auth_key="tskey-x")).available()
    assert "auth key" not in why2.lower()


def test_stage_writes_authkey_env(tmp_path):
    node = LocalMeshNode(GENERATOR_DIR, LocalMeshConfig(
        auth_key="tskey-xyz", node_name="mynode",
        login_server="https://hs.example.com", workdir=str(tmp_path)))
    node._stage()
    env = _read_env(tmp_path / ".env")
    assert env["TS_AUTHKEY"] == "tskey-xyz"
    assert env["HUGMESH_NODE_NAME"] == "mynode"
    assert env["TS_EXTRA_ARGS"] == "--accept-routes --login-server=https://hs.example.com"


def test_stage_overrides_any_bundled_env_key(tmp_path):
    # a pre-existing .env in the workdir (as MeshNode._stage may copy from the stack dir)
    # must not shadow the operator's auth key — ours wins.
    (tmp_path / ".env").write_text("TS_AUTHKEY=stale\nOTHER=keep\n")
    node = LocalMeshNode(GENERATOR_DIR, LocalMeshConfig(
        auth_key="tskey-new", workdir=str(tmp_path)))
    node._stage()
    env = _read_env(tmp_path / ".env")
    assert env["TS_AUTHKEY"] == "tskey-new"
    assert env["OTHER"] == "keep"          # unrelated keys are preserved


def _read_env(path):
    out = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


def _stopped():
    from hugmesh_studio.core.mesh_node import MeshStatus
    return MeshStatus(running=False, detail="not started")
