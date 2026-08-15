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
from hugmesh_studio.core import local_services  # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrap  # noqa: E402
from hugmesh_studio.core.local_stack_node import LocalStackNode  # noqa: E402
from hugmesh_studio.core.mesh_node import MeshNode  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages import localmesh as localmesh_mod  # noqa: E402
from hugmesh_studio.gui.pages import ModePage  # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets  # noqa: E402

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


def _join_page_threads(dlg):
    """Wait out every QThread the page owns before the dialog is collected.

    The page starts probes on entry that shell out to docker (stack status, and the
    e2e gate). On a machine with a REAL mesh running they are still in flight at
    teardown, and Qt turns that into a FATAL — "QThread: Destroyed while thread is
    still running" aborts the whole interpreter, taking every later test in the file
    with it. Reproduces at HEAD with no changes of any kind, so it is the harness's
    problem to work around here; the page not stopping its own probes on close is the
    real fix and belongs to the page. Swept by type rather than by attribute name so
    a probe added later is joined too."""
    for _t in dlg.findChildren(QtCore.QThread):
        _t.wait(60_000)


# ---- the SERVICES picker (the local mesh's "which services" axis) ----

def test_services_table_offers_every_locally_runnable_slug(qapp):
    """One checkbox per slug core says the local mesh can genuinely run — and NONE
    for the slugs it cannot, which are rendered as greyed rows carrying the reason.
    Reading the registry from core is the point: a slug added there must appear here
    with no GUI edit at all."""
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    # local_slugs() is the SELECTABLE set, so this is also the guard that a row with
    # no runnable mechanism on this lane never grows a checkbox.
    assert set(dlg.service_boxes) == set(local_services.local_slugs())
    for slug in local_services.UNAVAILABLE_LOCALLY:
        assert slug not in dlg.service_boxes
        item = dlg.page._svc_items[slug]
        # lay-user copy (operator ask 2026-08-14): "disabled" + one plain sentence
        assert item.text(localmesh_mod._LS_COL_MECH) == "disabled"
        assert item.text(localmesh_mod._LS_COL_DESC) == \
            f"Disabled — {local_services.UNAVAILABLE_LOCALLY[slug]}"
    _join_page_threads(dlg)


def test_services_rows_state_which_mechanism_applies_them(qapp):
    """The operator's real question is "does ticking this restart my mesh?" — so the
    row says which back-end it drives rather than leaving the three indistinguishable."""
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    assert dlg.page._svc_items["tor"].text(localmesh_mod._LS_COL_MECH) == \
        "--profile tor"
    assert dlg.page._svc_items["wiki"].text(localmesh_mod._LS_COL_MECH) == \
        "federation: wiki"
    # THREE mechanisms, so three answers. The column was built by a TWO-way branch,
    # which fell through to the federation arm for the DevOps rows and printed
    # "federation: " with an empty module beside a live checkbox.
    assert dlg.page._svc_items["argocd"].text(localmesh_mod._LS_COL_MECH) == \
        local_services.KIND_LANE_LABEL
    assert "federation" not in \
        dlg.page._svc_items["workloadConsole"].text(localmesh_mod._LS_COL_MECH)
    _join_page_threads(dlg)


def test_devops_lane_rows_are_informational_and_carry_no_checkbox(qapp):
    """THE FIX. argocd/workloadConsole are Kubernetes controllers: the docker-compose
    lane cannot drive them, so the row must not offer to. A checkbox here was inert by
    construction — profile_flags(), federation_env() and plan() all (correctly) drop a
    kind slug, so ticking it changed nothing anywhere.

    The honest row is the one UNAVAILABLE_LOCALLY already uses — greyed, self-
    explaining — except it points at the DevOps buttons on this same page instead of
    at a refusal."""
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    assert local_services.kind_slugs()                      # the lane is non-empty
    for slug in local_services.kind_slugs():
        # (a) rendered — the operator still learns the service exists
        item = dlg.page._svc_items[slug]
        assert item is not None, slug
        # (b) NO checkbox: neither in the registry nor as a widget in the On column
        assert slug not in dlg.service_boxes, slug
        assert dlg.page.services_table.itemWidget(
            item, localmesh_mod._LS_COL_ON) is None, slug
        # (c) greyed, like every other row that is not a live toggle
        assert item.foreground(localmesh_mod._LS_COL_NAME).color().name() == "#888888"
        # (d) the row says where it DOES live — the button on this page
        desc = item.text(localmesh_mod._LS_COL_DESC)
        assert local_services.KIND_LANE_BUTTON in desc, slug
        assert local_services.KIND_LANE_TARGET in desc, slug
        assert item.text(localmesh_mod._LS_COL_MECH) == \
            local_services.KIND_LANE_LABEL, slug
    # and that button is really on this page, with the target the row names
    assert dlg.page.devops_up_btn.text() == local_services.KIND_LANE_BUTTON
    # (e) a kind slug can therefore never reach the config the plan describes
    assert not (set(local_services.kind_slugs())
                & set(dlg.collect_bootstrap().services or ()))
    _join_page_threads(dlg)


def test_social_and_tor_rows_are_the_same_widgets_not_copies(qapp):
    """The two historical toggles moved INTO the table as the rows for their slugs.
    Aliases, never second checkboxes — a copy could disagree with its row, which is
    the exact "one service, two spellings" bug the node wizard's table killed."""
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    assert dlg.social is dlg.service_boxes["tuwunel"]
    assert dlg.with_tor is dlg.service_boxes["tor"]
    dlg.service_boxes["tor"].setChecked(True)
    assert dlg.collect_bootstrap().with_tor is True


def test_untouched_services_picker_leaves_the_bring_up_byte_identical(qapp):
    """THE default-drift guard: on arrival nothing is ticked, the config carries an
    empty (but explicit) selection, and the stack env is identical to the env a
    bring-up produced before the picker existed."""
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    assert dlg.collect_services() == ()
    cfg = dlg.collect_bootstrap()
    assert cfg.services == ()
    assert cfg.social is False and cfg.with_tor is False
    before = LocalStackNode(GENERATOR_DIR)._build_env()
    after = LocalMeshBootstrap(GENERATOR_DIR, cfg)._stack_node()._build_env()
    assert after == before


def test_ticking_a_federation_service_reaches_the_seeder_env(qapp):
    """The federation half's whole job: the chosen slugs become the enable/disable
    env pair `make stack-seed` reads, and the complement is exported too so the seeder
    can tell "leave it" from "turn it off"."""
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.service_boxes["wiki"].setChecked(True)
    dlg.service_boxes["owncast"].setChecked(True)
    cfg = dlg.collect_bootstrap()
    assert cfg.services == ("wiki", "owncast")
    env = LocalMeshBootstrap(GENERATOR_DIR, cfg)._stack_node()._build_env()
    assert env[local_services.FEDERATION_ENABLE_ENV] == "wiki owncast"
    assert env[local_services.FEDERATION_DISABLE_ENV] == \
        "tube character-studio character-forge"
    # and the compose profiles are untouched by a federation-only selection
    assert env["SOCIAL"] == "" and env["TOR"] == ""


def test_ticking_a_profile_service_drives_the_compose_profile(qapp):
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.service_boxes["tuwunel"].setChecked(True)
    cfg = dlg.collect_bootstrap()
    assert cfg.effective_social() is True
    env = LocalMeshBootstrap(GENERATOR_DIR, cfg)._stack_node()._build_env()
    assert env["SOCIAL"] == "1"
    # a profile-only change must not invent a federation flip
    assert local_services.FEDERATION_ENABLE_ENV not in env


def test_services_selection_shows_up_in_the_plan_preview(qapp):
    """Every other bootstrap control live-refreshes the confirm-before-run manifest;
    a services row that did not would leave the plan describing a different mesh."""
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.service_boxes["tube"].setChecked(True)
    plan = dlg.plan_view.toPlainText()
    assert "[x] tube" in plan
    assert "[ ] wiki" in plan
    assert local_services.FEDERATION_ENABLE_ENV in plan
    assert "PENDING" in plan          # the seeder hunk is honestly disclosed


def test_bootstrap_up_carries_the_services_selection(qapp, monkeypatch):
    seen = {}
    monkeypatch.setattr(
        LocalMeshBootstrap, "up",
        lambda self, on_line=None, cancel=None:
            seen.update(services=self.cfg.services) or (True, ["ok"]),
        raising=True)
    monkeypatch.setattr(LocalMeshNode, "status", lambda self: _stopped(), raising=True)
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    dlg.service_boxes["character-forge"].setChecked(True)
    dlg.ack.setChecked(True)
    dlg._bootstrap_up()
    _drain_worker(qapp, dlg.page)
    assert seen["services"] == ("character-forge",)


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


# ---- the seeded-credentials dialog (operator: "show me who to log in as") ----

def test_page_exposes_a_credentials_button(qapp):
    # The whole point of the feature: a freshly-seeded mesh renders a login page,
    # and the operator has nowhere on screen telling them WHICH account to use.
    dlg = localmesh_mod.LocalMeshDialog(GENERATOR_DIR)
    assert hasattr(dlg.page, "creds_btn")
    assert "credential" in dlg.page.creds_btn.text().lower()


def test_credentials_dialog_lists_the_real_seeded_personas(qapp):
    from hugmesh_studio.core.seeded_credentials import load_roster
    from hugmesh_studio.gui.pages._credentials_dialog import CredentialsDialog
    roster = load_roster(GENERATOR_DIR)
    d = CredentialsDialog(roster, front_door="http://localhost:8088")
    assert d.table.rowCount() == len(roster.users)
    shown = {d.table.item(r, 0).text() for r in range(d.table.rowCount())}
    assert {"e2e-admin", "e2e-user"} <= shown
    # the password column carries the resolved value, not the env-var NAME
    row = next(r for r in range(d.table.rowCount())
               if d.table.item(r, 0).text() == "e2e-admin")
    assert d.table.item(row, 1).text() == "e2e-pass"
    assert "E2E_" not in d.table.item(row, 1).text()


def test_credentials_dialog_copies_only_on_an_explicit_click(qapp):
    from hugmesh_studio.core.seeded_credentials import Roster, SeededUser
    from hugmesh_studio.gui.pages._credentials_dialog import CredentialsDialog
    roster = Roster(users=[SeededUser("e2e-admin", ("ROLE_ADMIN",), "hunter2")])
    QtWidgets.QApplication.clipboard().setText("untouched")
    d = CredentialsDialog(roster)
    # merely OPENING the dialog must not put a credential on the clipboard
    assert QtWidgets.QApplication.clipboard().text() == "untouched"
    d.table.selectRow(0)
    d.copy_pass.click()
    assert QtWidgets.QApplication.clipboard().text() == "hunter2"
    d.copy_user.click()
    assert QtWidgets.QApplication.clipboard().text() == "e2e-admin"
    d.copy_all.click()
    assert "e2e-admin\thunter2\t" in QtWidgets.QApplication.clipboard().text()


def test_credentials_dialog_says_so_when_the_roster_is_unreadable(qapp, tmp_path):
    # A silently empty table would read as "the seed created no users" — a
    # different, scarier claim than "I could not read the roster".
    from hugmesh_studio.core.seeded_credentials import load_roster
    from hugmesh_studio.gui.pages._credentials_dialog import CredentialsDialog
    d = CredentialsDialog(load_roster(str(tmp_path)))
    assert not hasattr(d, "table")
    texts = " ".join(w.text() for w in d.findChildren(QtWidgets.QLabel))
    assert "could not read" in texts.lower()


def test_field_auth_key_reaches_subprocess_env_without_os_environ(monkeypatch):
    # The runtime (not the staged .env file) invariant behind start()/stop()/status()/
    # logs(): a field-only auth key (no TS_AUTHKEY anywhere in the environment) must
    # still be the EFFECTIVE key those verbs hand to `docker compose`, since callers
    # (the CLI, the GUI's _start()) never export it to os.environ — LocalMeshNode's
    # _authkey() override is the only thing that makes cfg.auth_key reach them.
    monkeypatch.delenv("TS_AUTHKEY", raising=False)
    node = LocalMeshNode(GENERATOR_DIR, LocalMeshConfig(auth_key="field-key-999"))
    assert node._authkey() == "field-key-999"
    assert node._env()["TS_AUTHKEY"] == "field-key-999"
    # and it wins even over a stale/different ambient value
    monkeypatch.setenv("TS_AUTHKEY", "ambient-key")
    assert node._authkey() == "field-key-999"
    assert node._env()["TS_AUTHKEY"] == "field-key-999"


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
