"""The field-level wizard asks, driven against the REAL wizard offscreen.

One module per ask, in the operator's own words:

* **7** — "this devices person role is completely unclear": the control has a plain
  label, an on-page description of what it decides, and per-option prose; it is HIDDEN
  wherever the builder would discard the value.
* **8** — "only show steps for users and domains if its selected to start with
  aditional domains": real page gating (the ids are absent from the visited sequence),
  correct Back/Next, and state entered-then-de-selected is CLEARED, not submitted.
* **9** — "hostname, timezone, and default user should be preselected and timezone
  should be dropdown": the two derived values match the builders' own tables, the
  timezone is a combo populated from real offline zone data.
* **10** — "setting a baked user and root password should be optional and only show
  fields if selected … for node fallback option that is": unchecked by default, fields
  hidden, nothing emitted, de-selecting wipes.
* **12 -> 21** — "rot encryption should be a mesh device default", then "root disk
  encryption should always be enabled": the posture is ALWAYS on, stated rather than
  offered, inherited by every worklist row, with jetson (whose builder has no FDE path)
  the one exemption.
* **19** — "domains at launch": a choice-icon-button screen; the default (internal only)
  goes straight to the users choice screen, the other card opens the domains table.
* **20** — "users at launch": a card that STATES which accounts are generated and where
  their credentials land — checked against the real key channel, not trusted as prose —
  or the superusers/domain-users table; the default continues to System identity.
* **21** — also: the ``--standalone`` posture LEFT the Home step. The finding-1 guards
  moved with it (RolePage visibility, the ARM appliance pins, the mesh-node clear).
* **22** — "Simplify the review screen and make the build screen separate with an option
  to continue the build and go back to the main menu." ProgressPage DISPATCHES ON
  ARRIVAL, so every walk onto it here goes through ``_install_inert_build_driver`` —
  the walk that did not (2026-09-04) launched a real ``sudo -A bash
  ./build-x86-host-stage4.sh`` per run and left 60 root-owned launchers hung on an
  offscreen askpass dialog. The unstubbed arrival is now pinned to be REFUSED.

Every gate here has a MUTATION proof recorded in the lane report: reverting the gating
condition in the source makes the named test fail.
"""
import os
import re
import subprocess
from types import SimpleNamespace

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import build_driver as bd   # noqa: E402
from hugmesh_studio.core import roles as roles_lib   # noqa: E402
from hugmesh_studio.core import timezones          # noqa: E402
from hugmesh_studio.core import worklist_driver as wd   # noqa: E402
from hugmesh_studio.core.config import (           # noqa: E402
    PERSON_ROLE_CHOICES, Domain, ImageConfig, User, clear_role_class_fields,
    default_local_user, derive_default_user, derive_hostname, encrypt_root_always,
    person_role_applies, superadmin_plane_applies, users_table_applies,
)
from hugmesh_studio.core.platform_info import HostInfo   # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod      # noqa: E402
from hugmesh_studio.gui.pages.home import HomePage       # noqa: E402
from hugmesh_studio.gui.pages.role import RolePage       # noqa: E402
from hugmesh_studio.gui.pages.system import (            # noqa: E402
    _PERSON_ROLE_HELP, _PERSON_ROLE_LABEL, SystemPage,
)
from hugmesh_studio.gui.pages.users_choice import default_accounts_summary  # noqa: E402
from hugmesh_studio.gui.pages.launch import launch_summary                  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets              # noqa: E402

from _helpers import (   # noqa: E402
    advance_to, back_to, check_worklist_rows, enable_additional_domains,
    enable_configure_users, pairs, pick_mode,
)

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
            or QtWidgets.QApplication(["hugmesh-studio-field-asks"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()          # offscreen: makes per-widget isVisibleTo() meaningful
    yield w
    w.close()
    w.deleteLater()


def _system_page(cfg=None):
    return SystemPage(SimpleNamespace(cfg=cfg or ImageConfig()))


def mesh_flow(wiz, *ids):
    """Enter mesh and check the given worklist rows (default: three x86 nodes)."""
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, *(ids or ("pki.x86", "backend.x86", "frontend.x86")))
    return wl


def visited_slugs(wiz):
    """The slugs of the pages this flow has actually VISITED, in wizard order."""
    return [slug for slug, pid in wiz._page_ids.items() if wiz.hasVisitedPage(pid)]


def _install_inert_build_driver(monkeypatch):
    """Arriving at ProgressPage dispatches the committed worklist through the REAL
    WorklistDriver -> BuildDriver -> `sudo -A bash ./build-x86-host-stage4.sh` (this
    file's pinned host is non-root, native). Replace the per-image driver with a do-nothing
    one that records what it was asked to build, and the mesh node-key generator's
    Popen with a no-op, so a walk onto the page proves DISPATCH without a process.
    Same shape as tests/test_pages_progress.py::_install_fake_builddriver."""
    runs = []

    class InertBuildDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.workdir = workdir

        def run(self, cfg, backend, on_line=None):
            runs.append((cfg.role, cfg.platform, backend))
            if on_line:
                on_line(f"==> (inert) {cfg.role}.{cfg.platform}")
            return 0

        def cancel(self):
            pass

        def preflight(self, cfg, backend):
            return []

        def preflight_warnings(self, cfg, backend):
            return []

        def command_string(self, cfg, backend=None):
            return f"cmd:{cfg.role}"

    class _KeysProc:
        stdout = iter(())

        def wait(self):
            return 0

    monkeypatch.setattr(wd, "BuildDriver", InertBuildDriver)
    monkeypatch.setattr(wd.subprocess, "Popen", lambda cmd, **kw: _KeysProc())
    return runs


def _point_output_dir(wiz, tmp_path):
    """Commit a throwaway output dir through the Build page's own field, so the session
    record and work dir the dispatch mints land under tmp_path — never <generator>/out."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    build.outdir.setText(str(tmp_path / "out"))
    return build


def _settle_run(qapp, page, timeout_ms=15000):
    """Join the dispatched worker, then pump the loop so its queued signals land."""
    if page.worker is not None:
        page.worker.wait(timeout_ms)
    for _ in range(500):
        qapp.processEvents()
        if page.isComplete():
            break


# ══════════════════════════════════════════════════════════════════════════════════
# ASK 7 — "this devices person role is completely unclear"
# ══════════════════════════════════════════════════════════════════════════════════

def test_ask7_person_role_label_is_no_longer_the_unclear_one(wiz):
    """The control the operator called unclear was labelled, verbatim, "This device's
    person role", with NO on-page explanation — the meaning existed only in a tooltip.
    It now carries a plain label plus a visible description of what the value decides."""
    pick_mode(wiz, "cloud")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    labels = [w.text() for w in sysp.person_role_row.findChildren(QtWidgets.QLabel)]
    assert _PERSON_ROLE_LABEL in labels
    assert "This device's person role" not in labels     # the old wording is gone
    # the group states what the choice actually decides, ON THE PAGE (not a tooltip)
    intro = " ".join(w.text() for w in sysp.person_box.findChildren(QtWidgets.QLabel))
    assert "identity-role" in intro                       # the marker it bakes
    assert "artifact's filename" in intro                 # the other thing it really does
    assert "GRANTS nothing" in intro                      # what it is NOT
    # ...and it does not claim a behaviour the code does not have. `git grep
    # identity-role` finds ONE writer (build-x86-host-stage4.sh:4356) and ONE reader
    # (tests/qemu/verify-client.sh, a verification probe); keys-provision reads the
    # SIBLING `domains` marker, never this one. Saying the tier binds the device to an
    # account today would be inventing a semantic — exactly what ask 7 forbids.
    assert "nothing in the first-boot provisioning reads this marker yet" in intro


def test_ask7_every_option_carries_its_own_description(wiz):
    """Per-option prose: selecting any option updates a visible description, and the
    superadmin option names its real, non-obvious consequence (the device-password
    hardening the builder bakes at build-x86-host-stage4.sh:4375-4376)."""
    pick_mode(wiz, "cloud")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert set(_PERSON_ROLE_HELP) == {"derive", *PERSON_ROLE_CHOICES}
    for opt in ("derive", *PERSON_ROLE_CHOICES):
        sysp.person_role.setCurrentText(opt)
        shown = sysp.person_role_help.text()
        assert shown == _PERSON_ROLE_HELP[opt] and shown, opt
    sysp.person_role.setCurrentText("superadmin")
    assert "SEPARATE device password" in sysp.person_role_help.text()


def test_ask7_picker_is_hidden_where_the_builder_would_discard_it(wiz):
    """The picker is no longer offered on flows where the builder warns
    "--person-role/--domains are ignored" (:1588) or hard-conflicts (--unaffiliated,
    :1333). Predicate + rendered visibility, on the same three configs."""
    assert person_role_applies(ImageConfig(mode="cloud", role="laptop"))
    assert not person_role_applies(ImageConfig(mode="cloud", role="pki"))
    assert not person_role_applies(ImageConfig(mode="standalone",
                                               role="standalone-thick"))
    assert not person_role_applies(ImageConfig(mode="cloud", role="laptop",
                                               unaffiliated=True))
    # a mesh NODE flow: hidden, and any stale tier is dropped on Next
    wiz.cfg.person_role = "admin"
    mesh_flow(wiz, "pki.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert not sysp.person_box.isVisible()
    assert sysp.person_box.toolTip()                       # says WHY, not just gone
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.person_role == ""
    assert "--person-role" not in wiz.cfg.to_cli_args()


def test_ask7_picker_left_the_users_table(wiz):
    """It is a per-IMAGE build-time control, so it no longer sits under the superadmin
    users table's Add/Remove buttons — where it read as "which of these accounts"."""
    pick_mode(wiz, "cloud")
    users = advance_to(wiz, wizard_mod.UsersPage)
    assert not hasattr(users, "person_role")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert isinstance(sysp.person_role, QtWidgets.QComboBox)


# ══════════════════════════════════════════════════════════════════════════════════
# ASK 8 (+19/20) — the domains/users TABLES only when the operator asks for them
#
# Ask 8 asked for the gate; asks 19 and 20 then said WHERE the decision is made — one
# choice-card screen per table, immediately in front of it, instead of a checkbox on
# the Network step. The gate itself is what these tests pin: the table ids are ABSENT
# from the visited sequence unless chosen, Back/Next step over them, and anything typed
# then de-selected is CLEARED rather than silently published to the mesh manifest.
# ══════════════════════════════════════════════════════════════════════════════════

def test_ask8_mesh_skips_domains_and_users_without_the_opt_in(wiz):
    """OFF (the default): the two TABLE steps are ABSENT from the page sequence — not
    shown disabled. Walking the whole mesh flow never visits either id, while the two
    CHOICE screens that own the decision are visited exactly once each."""
    mesh_flow(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    # ask 19: the decision left this page entirely — two controls for one flag is the
    # muddle the ask exists to remove.
    assert not hasattr(net, "additional_domains")
    dc = advance_to(wiz, wizard_mod.DomainsChoicePage)
    assert dc._buttons["internal"].isChecked()          # default = internal only
    assert not dc._buttons["more"].isChecked()
    uc = advance_to(wiz, wizard_mod.UsersChoicePage)
    assert uc._buttons["generated"].isChecked()         # default = generated accounts
    assert not uc._buttons["table"].isChecked()
    advance_to(wiz, wizard_mod.BuildPage)
    slugs = visited_slugs(wiz)
    assert "domains" not in slugs and "users" not in slugs
    assert "domains_choice" in slugs and "users_choice" in slugs
    assert "network" in slugs and "system" in slugs        # the flow itself is intact
    assert wiz.cfg.additional_domains is False and wiz.cfg.configure_users is False


def test_ask19_default_domains_choice_lands_on_the_users_choice(wiz):
    """ASK 19, verbatim: "On the default (internal only) go straight to the USERS
    button-choice screen." No Domains TABLE in between — but since #494 (operator
    report 2026-09-23, issue #589) the mesh's OWN domain has a services page like every
    other domain, and that ONE page sits between the choice and the users choice: it
    is the own domain's, it names it, and it is the only page before the users
    choice."""
    mesh_flow(wiz)
    dc = advance_to(wiz, wizard_mod.DomainsChoicePage)
    assert dc._buttons["internal"].isChecked()
    wiz.next()
    own = wiz.currentPage()
    assert isinstance(own, wizard_mod.DomainServicesPage), (
        f"landed on {type(own).__name__}, not the own domain's services page")
    assert own.current_domain() == wiz.cfg.cluster_domain
    assert "1 of 1" in own.subTitle()                       # no other domain: no table
    wiz.next()
    assert isinstance(wiz.currentPage(), wizard_mod.UsersChoicePage), (
        f"landed on {type(wiz.currentPage()).__name__}, not the users choice screen")


def test_ask20_default_users_choice_lands_on_system_identity(wiz):
    """ASK 20, verbatim: "On the default internal-only path, go to SYSTEM IDENTITY."
    One Next from the users choice, no table in between."""
    mesh_flow(wiz)
    uc = advance_to(wiz, wizard_mod.UsersChoicePage)
    assert uc._buttons["generated"].isChecked()
    wiz.next()
    assert isinstance(wiz.currentPage(), wizard_mod.SystemPage), (
        f"landed on {type(wiz.currentPage()).__name__}, not System identity")


def test_ask8_mesh_shows_domains_and_users_when_selected(wiz):
    """ON: both steps are back in the sequence, in their registered order — each one
    immediately after the choice screen that turned it on."""
    mesh_flow(wiz)
    enable_additional_domains(wiz)
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    dom._add("acme.example", "Acme")
    enable_configure_users(wiz)
    usr = advance_to(wiz, wizard_mod.UsersPage)
    usr._add("bob", "acme.example", "admin")
    advance_to(wiz, wizard_mod.BuildPage)
    slugs = visited_slugs(wiz)
    assert "domains" in slugs and "users" in slugs
    assert (slugs.index("domains_choice") < slugs.index("domains")
            < slugs.index("users_choice") < slugs.index("users")
            < slugs.index("system"))
    assert [d.name for d in wiz.cfg.domains] == ["acme.example"]
    assert [u.username for u in wiz.cfg.users] == ["bob"]


def test_ask20_users_table_has_its_own_gate_independent_of_domains(wiz):
    """The two questions are genuinely independent — a single-domain mesh can still want
    a named superuser, and a multi-domain mesh can still want only the generated
    accounts. Proving the gates are separate rather than one flag wearing two hats."""
    mesh_flow(wiz)
    enable_configure_users(wiz)                      # users table ON, domains table OFF
    usr = advance_to(wiz, wizard_mod.UsersPage)
    usr._add("root-admin", role="superadmin")
    advance_to(wiz, wizard_mod.BuildPage)
    slugs = visited_slugs(wiz)
    assert "users" in slugs and "domains" not in slugs
    assert wiz.cfg.configure_users is True and wiz.cfg.additional_domains is False
    assert users_table_applies(wiz.cfg) and not superadmin_plane_applies(wiz.cfg)


def test_ask8_back_navigation_steps_over_the_skipped_pages(wiz):
    """Back must land on the previous VISITED page, never on a skipped one: with both
    choices left at their defaults, walking back from System reaches Network without
    stopping at either table, and Next forward returns the same way."""
    mesh_flow(wiz)
    advance_to(wiz, wizard_mod.SystemPage)
    seen = []
    while not isinstance(wiz.currentPage(), wizard_mod.NetworkPage):
        wiz.back()
        seen.append(type(wiz.currentPage()).__name__)
    assert "DomainsPage" not in seen and "UsersPage" not in seen
    # the CHOICE screens are on the path (they are the decision) — the tables are not
    assert "DomainsChoicePage" in seen and "UsersChoicePage" in seen
    # ...and Next forward again returns to System without them
    fwd = []
    while not isinstance(wiz.currentPage(), wizard_mod.SystemPage):
        wiz.next()
        fwd.append(type(wiz.currentPage()).__name__)
    assert "DomainsPage" not in fwd and "UsersPage" not in fwd


def test_ask8_deselecting_clears_what_was_entered(wiz):
    """THE emission guard, now once per choice screen: rows typed while a table was ON
    must be dropped when its choice goes back to the default — a skipped page is
    unreachable, so leaving the rows in place would publish them to the mesh manifest
    from a step the operator can no longer see."""
    mesh_flow(wiz)
    enable_additional_domains(wiz)
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    dom._add("acme.example", "Acme")
    enable_configure_users(wiz)
    usr = advance_to(wiz, wizard_mod.UsersPage)
    usr._add("bob", "acme.example", "admin")
    advance_to(wiz, wizard_mod.SystemPage)
    assert wiz.cfg.domains and wiz.cfg.users                  # really entered
    dc = back_to(wiz, wizard_mod.DomainsChoicePage)
    dc._buttons["internal"].setChecked(True)
    wiz.next()                                                # domains table now skipped
    own = wiz.currentPage()                                   # …the own domain's page stays (#494)
    assert isinstance(own, wizard_mod.DomainServicesPage)
    assert own.current_domain() == wiz.cfg.cluster_domain and "1 of 1" in own.subTitle()
    wiz.next()
    uc = wiz.currentPage()
    assert isinstance(uc, wizard_mod.UsersChoicePage)
    uc._buttons["generated"].setChecked(True)
    advance_to(wiz, wizard_mod.SystemPage)
    assert wiz.cfg.domains == [] and wiz.cfg.users == []
    manifest = wiz.cfg.mesh_manifest()
    assert manifest["domains"] == [] and manifest["users"] == []


def test_ask8_each_choice_clears_only_its_own_table(wiz):
    """...and it clears ONLY its own table. De-selecting the domains choice must not
    silently discard superusers the operator explicitly asked to name (the two gates
    are independent — see test_ask20_users_table_has_its_own_gate_independent_of_domains)."""
    mesh_flow(wiz)
    enable_additional_domains(wiz)
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    dom._add("acme.example", "Acme")
    enable_configure_users(wiz)
    usr = advance_to(wiz, wizard_mod.UsersPage)
    usr._add("bob", "acme.example", "admin")
    advance_to(wiz, wizard_mod.SystemPage)
    dc = back_to(wiz, wizard_mod.DomainsChoicePage)
    dc._buttons["internal"].setChecked(True)
    advance_to(wiz, wizard_mod.SystemPage)       # users choice stays on "table"
    assert wiz.cfg.domains == []
    assert [u.username for u in wiz.cfg.users] == ["bob"], (
        "the domains choice discarded users it does not own")


def test_ask8_opt_in_is_mesh_only_cloud_keeps_its_tables(wiz):
    """A cloud desktop client's Domains/Users steps carry the FD-08 --domains tie the
    image is built around — they are NOT "additional" and must stay unconditional, so
    that flow never sees either choice screen."""
    pick_mode(wiz, "cloud")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not hasattr(net, "additional_domains")
    advance_to(wiz, wizard_mod.BuildPage)
    slugs = visited_slugs(wiz)
    assert "domains" in slugs and "users" in slugs
    assert "domains_choice" not in slugs and "users_choice" not in slugs
    # never set outside mesh — a value left over from an earlier mesh detour is reset
    assert wiz.cfg.additional_domains is False and wiz.cfg.configure_users is False


def test_ask8_opt_in_round_trips_through_a_saved_config(wiz, tmp_path):
    """Both flow flags are saved (they are wizard-flow state, not secrets): reloading a
    mesh worklist that carries domain/user rows must not silently re-hide the tables."""
    mesh_flow(wiz)
    enable_additional_domains(wiz)
    dom = advance_to(wiz, wizard_mod.DomainsPage)
    dom._add("acme.example", "Acme")
    enable_configure_users(wiz)
    usr = advance_to(wiz, wizard_mod.UsersPage)
    usr._add("bob", "acme.example", "admin")
    advance_to(wiz, wizard_mod.SystemPage)
    path = str(tmp_path / "wl.json")
    wiz.save_config(path)
    w2 = wizard_mod.StudioWizard(GENERATOR_DIR)
    try:
        w2.load_config(path)
        assert w2.cfg.additional_domains is True
        assert w2.cfg.configure_users is True
        assert superadmin_plane_applies(w2.cfg) and users_table_applies(w2.cfg)
    finally:
        w2.close(); w2.deleteLater()


def test_ask19_internal_card_names_the_real_domains(wiz):
    """ASK 19's default card must NAME what "internal only" means for THIS config —
    the cluster domain the Network step set and the derived Tailscale root domain —
    rather than being an abstraction the operator has to take on faith."""
    mesh_flow(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.domain.setText("acme.example")            # the cluster-domain field
    dc = advance_to(wiz, wizard_mod.DomainsChoicePage)
    desc = dc._buttons["internal"].accessibleDescription()
    assert "acme.example" in desc
    assert wiz.cfg.effective_superdomain() in desc


# ══════════════════════════════════════════════════════════════════════════════════
# ASK 9 — preselected hostname / timezone / default user; timezone is a dropdown
# ══════════════════════════════════════════════════════════════════════════════════

def test_ask9_timezone_is_a_dropdown_over_real_zone_data(wiz):
    """A combo, not a line edit, populated from the HOST's tz database read at runtime
    (core/timezones -> stdlib zoneinfo). No network is touched: the module imports only
    os + zoneinfo, and the fallback is a committed literal list."""
    pick_mode(wiz, "cloud")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert isinstance(sysp.timezone, QtWidgets.QComboBox)
    assert not sysp.timezone.isEditable()                    # a dropdown, not free text
    items = [sysp.timezone.itemText(i) for i in range(sysp.timezone.count())]
    assert items == timezones.available()
    assert items[0] == "UTC" and len(items) >= len(timezones.FALLBACK_ZONES)
    assert all(re.fullmatch(r"[A-Za-z0-9+_/-]+", z) for z in items)


def test_ask9_timezone_falls_back_without_a_zone_database(monkeypatch):
    """Graceful degradation, not a crash: with no tz database at all the offered list
    is the curated fallback and the default is UTC."""
    import builtins
    real_import = builtins.__import__

    def no_zoneinfo(name, *a, **kw):
        if name == "zoneinfo":
            raise ImportError("no tz database on this host")
        return real_import(name, *a, **kw)

    monkeypatch.setattr(builtins, "__import__", no_zoneinfo)
    assert timezones.available() == list(timezones.FALLBACK_ZONES)
    # a host zone the (now curated) list does not carry degrades to UTC rather than
    # preselecting a name -T would bake unchecked into every image
    monkeypatch.setenv("TZ", "Mars/Olympus_Mons")
    assert timezones.host_timezone() == "Mars/Olympus_Mons"
    assert timezones.default_timezone() == "UTC"
    # ...while one that IS in the lifeboat list is still honoured
    monkeypatch.setenv("TZ", "Europe/Berlin")
    assert timezones.default_timezone() == "Europe/Berlin"


def test_ask9_timezone_falls_back_when_the_database_is_present_but_empty(monkeypatch):
    """The OTHER degradation arm, which the ImportError test above cannot reach.

    ``available()`` has two fallbacks: the import fails, or the import succeeds and
    ``available_timezones()`` comes back EMPTY — the real shape on a host with the
    stdlib but no /usr/share/zoneinfo and no tzdata wheel. Only the first was pinned,
    so deleting `if not zones: return list(FALLBACK_ZONES)` left the whole suite green
    while the dropdown collapsed to a single "UTC" entry."""
    import zoneinfo
    monkeypatch.setattr(zoneinfo, "available_timezones", lambda: set())
    assert timezones.available() == list(timezones.FALLBACK_ZONES)
    assert len(timezones.available()) > 1, "the dropdown collapsed to one entry"
    # ...and the preselect still degrades to a zone that IS offered
    monkeypatch.setenv("TZ", "Mars/Olympus_Mons")
    assert timezones.default_timezone() == "UTC"


def test_ask9_three_fields_are_preselected_not_blank(wiz):
    """The whole ask: none of the three arrives empty on a single-image flow, and the
    two derived ones equal what the builder itself would have produced.

    RE-DRIVEN onto a NODE-class flow (was cloud's default desktop role) by the
    operator's 2026-08-26 duplicate collapse. On a DESKTOP image --local-user IS the
    baked default account, so SystemPage's "Default user" row was asking the same
    question HomePage's "Local user" row asks two screens later — one of the "same
    questions seemingly multiple times". The row is now hidden and the field cleared
    there (system.default_user_is_local_user). A node image still owns -u outright, so
    this is where all three fields are live together and the ask is testable whole.
    The desktop half is covered by the companion test below."""
    pick_mode(wiz, "cloud")
    role = advance_to(wiz, wizard_mod.RolePage)
    assert role.select_role("orangepizero2"), "no node-class role offered in cloud"
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    c = wiz.cfg
    assert sysp.hostname.text() == derive_hostname(c) != ""
    assert sysp.user.text() == derive_default_user(c) != ""
    assert sysp.timezone.currentText() == timezones.default_timezone() != ""
    advance_to(wiz, wizard_mod.HomePage)
    got = pairs(c.to_cli_args())
    assert ("--hostname", derive_hostname(c)) in got
    assert ("--user", derive_default_user(c)) in got
    assert ("--timezone", timezones.default_timezone()) in got


def test_ask9_a_desktop_asks_for_the_account_exactly_once(wiz):
    """The other half of the same ask after the 2026-08-26 collapse: on a DESKTOP flow
    the account is asked ONCE, on HomePage, and the two derived fields are still
    preselected on SystemPage.

    This is the test that would catch the collapse going too far — losing the account
    question altogether rather than deduplicating it. The image still gets a default
    account either way: with -u unset the builder falls back to its own DEFAULT_USER,
    which is byte-identical to the value the hidden row was prefilling."""
    pick_mode(wiz, "cloud")           # cloud's default role is desktop-class
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    c = wiz.cfg
    # the two that are NOT duplicated are still preselected, exactly as before
    assert sysp.hostname.text() == derive_hostname(c) != ""
    assert sysp.timezone.currentText() == timezones.default_timezone() != ""
    # ...and the duplicate row is gone, not merely greyed
    assert not sysp.user.isVisibleTo(sysp), (
        "the 'Default user' row still duplicates HomePage's 'Local user' on a desktop")
    home = advance_to(wiz, wizard_mod.HomePage)
    assert home.local_user.isVisibleTo(home), (
        "the account question vanished entirely instead of moving")
    assert home.local_user_note.isVisibleTo(home), (
        "HomePage must SAY that this account is also the image's default user")
    # leaves the output unchanged: the hidden row emits nothing, and the surviving one does emit
    got = pairs(c.to_cli_args())
    assert ("--hostname", derive_hostname(c)) in got
    assert "--user" not in c.to_cli_args()
    assert ("--local-user", c.local_user) in got


def test_ask9_an_arm_desktop_can_still_name_its_baked_account(wiz):
    """REGRESSION (2026-08-26 change set): the duplicate collapse hid -u on EVERY desktop
    image, on the strength of "a custom --local-user is honoured by the ARM builders too".

    It is — but --local-user is only EMITTED to an ARM builder under
    `if self.standalone or self.local_user != default_local_user() or self.local_pass:`
    (config.py:3166; x86 emits it unconditionally at config.py:3536). So a PLAIN ARM
    desktop received neither flag: `build-rpi5-stage4.sh` kept DEFAULT_USER="pi" (:288)
    while the wizard displayed the local user's name, and the operator could no longer
    name the baked account AT ALL — something they could do before the change set.
    Measured on this exact flow, pre-fix:

        --role desktop --board rpi5 --env test --hostname hugmesh-rpi5-desktop
        --timezone America/Los_Angeles --compress --resume --encrypt-root ...

    with no --user and no --local-user in it. This is that walk, pinned."""
    pick_mode(wiz, "cloud")
    role = advance_to(wiz, wizard_mod.RolePage)
    assert role.select_role("rpi5-desktop"), "rpi5-desktop not offered in cloud"
    assert wiz.cfg.local_user == default_local_user(), "no longer a DEFAULT account name"
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    # RolePage commits the machine on its validatePage, so this reads AFTER the advance
    assert wiz.cfg.platform == "rpi5", "this test no longer exercises an ARM image"
    # the row is OFFERED (it is the only channel here) and prefilled with the builder's
    # own account, which is ask 9's contract for the fields that survive
    assert sysp.user.isVisibleTo(sysp), (
        "an ARM desktop lost its only way to name the baked account")
    assert sysp.user.text() == derive_default_user(wiz.cfg) == "pi"
    sysp.user.setText("operator")
    home = advance_to(wiz, wizard_mod.HomePage)
    # ...and HomePage does NOT claim a flag this argv lacks
    assert home.local_user_note.isHidden(), (
        "the note asserts --local-user on a build that does not pass it")
    wiz.next()
    args = wiz.cfg.to_cli_args()
    assert ("--user", "operator") in pairs(args), (
        "the operator named the account and the builder was never told")
    assert "--local-user" not in args


@pytest.mark.parametrize("mode,role", [
    ("cloud", "rpi5-desktop"),          # ARM desktop: NEITHER flag -> -u is the channel
    ("cloud", "orangepi5"),             # ARM desktop: NEITHER flag -> -u is the channel
    ("cloud", "frite"),                 # ARM desktop: NEITHER flag -> -u is the channel
    ("cloud", "laptop"),                # x86 desktop: --local-user, unconditional
    ("cloud", "desktop"),               # x86 desktop
    ("standalone", "standalone-thick"),
    ("standalone", "standalone-unaffiliated"),
])
def test_ask9_the_local_user_note_never_claims_a_flag_the_argv_lacks(wiz, mode, role):
    """The invariant behind both halves of the collapse, as ONE property: HomePage's note
    names --local-user, so it must be visible if and only if --local-user is in the argv,
    and SystemPage's -u row must be offered exactly where it is NOT.

    Written as an iff rather than five hand-picked cases because both directions are real
    defects: the note appearing on an ARM desktop (measured — it claimed the builder makes
    --local-user the DEFAULT_USER while the argv carried no such flag) and the row
    disappearing on one (the same walk lost the account name entirely)."""
    pick_mode(wiz, mode)
    rp = advance_to(wiz, wizard_mod.RolePage)
    assert rp.select_role(role), f"{role} not offered in {mode}"
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    row_shown = sysp.user.isVisibleTo(sysp)
    home = advance_to(wiz, wizard_mod.HomePage)
    note_shown = not home.local_user_note.isHidden()
    wiz.next()
    args = wiz.cfg.to_cli_args()
    emitted = "--local-user" in args
    assert note_shown == emitted, (
        f"{mode}/{role}: note shown={note_shown} but --local-user emitted={emitted}")
    assert row_shown == (not emitted), (
        f"{mode}/{role}: -u row shown={row_shown} while --local-user emitted={emitted} "
        "— the row is asked exactly where --local-user is NOT the account")
    # exactly one of the two flags names the account, never zero
    assert ("--user" in args) or emitted, f"{mode}/{role}: NO account flag in the argv"


def test_ask9_derived_hostname_matches_the_shell_vocabulary():
    """DRIFT GUARD, cross-LANGUAGE: config.derive_hostname() must agree with the
    shell for every canonical role on every platform.

    This used to SCRAPE `[ -z "${HOSTNAME}" ] && HOSTNAME="${BRAND}-<literal>"` out of
    build-x86-host-stage4.sh, because config._HOSTNAME_SUFFIX was a hand transcription
    of that switch. There is no transcription any more: the builders and the Studio
    both derive from scripts/_roles-lib.sh (hugmesh_role_hostname / roles.hostname).
    So the guard stops parsing one builder's literals and instead RUNS the shell
    function — the same code the builder runs — and compares its answer. That covers
    all three role-axis platforms instead of one, and it cannot be fooled by a
    refactor that moves the literal somewhere the regex does not look.
    """
    lib = os.path.join(GENERATOR_DIR, "scripts", "_roles-lib.sh")
    assert os.path.exists(lib), lib
    checked = 0
    for plat in ("x86", "rpi5", "jetson"):
        for role in roles_lib.roles_for_platform(plat):
            if role == "standalone-unaffiliated":
                # The ONE role whose hostname is not assigned by the role switch at
                # all: build-x86-host-stage4.sh's UNAFFILIATED fold runs LATER and
                # sets "gentoo-desktop", after the brand identity is neutralised —
                # a branded "${BRAND}-…" name would contradict the whole posture.
                # Asserted on its own below rather than compared to the shared table.
                continue
            board = "rpi4" if plat == "rpi5" else ""
            out = subprocess.run(
                ["bash", "-c",
                 f'. "{lib}"; hugmesh_role_hostname {plat} "{role}" acme "{board}"'],
                capture_output=True, text=True, timeout=60)
            assert out.returncode == 0, out.stderr
            want = out.stdout.strip()
            cfg = ImageConfig(mode="mesh", role=role, platform=plat, brand="acme",
                              board=board)
            assert derive_hostname(cfg) == want, f"{plat}/{role}: shell={want!r} python={derive_hostname(cfg)!r}"
            checked += 1
    # a silently empty scrape would make this test vacuous
    assert checked >= 20, checked


def test_ask9_hostname_exceptions_are_the_three_declared_ones():
    """POSITIVE control on the exceptions. The derived rule is `{brand}-{role}`; the
    three literals that survive it are DELIBERATE back-compat, not leftovers, and a
    rename must not quietly re-point them."""
    def hn(plat, role, board=""):
        return derive_hostname(ImageConfig(mode="mesh", role=role, platform=plat,
                                           brand="acme", board=board))
    assert hn("x86", "backend-gpu") == "acme-host"          # flashers/launchers
    assert hn("x86", "standalone-thick") == "acme-standalone"
    assert hn("rpi5", "generic", "rpi4") == "gentoo-rpi4"   # drops the brand entirely
    # the UNAFFILIATED desktop: assigned by the later brand-neutralising fold, not by
    # the role switch, so it is deliberately outside the shared hostname table.
    assert hn("x86", "standalone-unaffiliated") == "gentoo-desktop"
    # ...and the roles that used to spell themselves short now bake the long name,
    # which is what the Pi builder has always baked for the same logical node.
    assert hn("x86", "backend") == "acme-backend"
    assert hn("rpi5", "backend") == "acme-backend"
    assert hn("x86", "frontend") == "acme-frontend"
    assert hn("rpi5", "frontend") == "acme-frontend"


def test_ask9_derived_default_user_matches_the_real_emission():
    """DRIFT GUARD for the second layer: --local-user overrides DEFAULT_USER in every
    builder, and x86 emits --local-user unconditionally. derive_default_user must agree
    with whatever to_cli_args() actually puts on the command line."""
    for cfg in (ImageConfig(mode="mesh", role="pki", platform="x86"),
                ImageConfig(mode="cloud", role="laptop", platform="x86",
                            local_user="alice"),
                ImageConfig(mode="mesh", role="backend", platform="rpi5"),
                ImageConfig(mode="cloud", role="rpi5-desktop", platform="rpi5",
                            local_user="bob")):
        args = cfg.to_cli_args()
        emitted = args[args.index("--local-user") + 1] if "--local-user" in args else None
        expect = emitted if emitted else {"x86": "snap", "rpi5": "pi"}[cfg.platform]
        assert derive_default_user(cfg) == expect, cfg.platform


def test_ask9_mesh_worklist_does_not_bake_one_hostname_onto_every_node(wiz):
    """HONESTY arm of the preselect, as REWRITTEN by issue #229: a mesh worklist
    builds several images off ONE base config, which carries ONE hostname. The page
    used to refuse to prefill and leave that field blank (so nothing could be named);
    now the single field is withdrawn and one editor PER IMAGE takes its place, each
    placeholdered with the canonical name that node bakes when left blank. Nothing is
    prefilled INTO the editors, so an untouched walk still emits no --hostname and
    every node keeps its own role-derived name — the mesh argv is as it was."""
    mesh_flow(wiz, "pki.x86", "backend.x86", "frontend.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert not sysp.hostname_row.isVisible()          # the one-for-all field is gone
    assert sysp.hostname_rows.isVisible() and sysp.hostname_note.isVisible()
    # ...and the names it shows are the canonical ones an x86 node really bakes now
    # (they were hugmesh-be / hugmesh-fe, while the SAME logical node on a Pi baked
    # hugmesh-backend / hugmesh-frontend).
    assert {rid: ed.placeholderText() for rid, ed in sysp.hostname_edits.items()} == {
        "pki.x86": "hugmesh-pki", "backend.x86": "hugmesh-backend",
        "frontend.x86": "hugmesh-frontend"}
    assert all(ed.text() == "" for ed in sysp.hostname_edits.values())
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.hostname == ""
    assert "--hostname" not in wiz.cfg.to_cli_args()      # mesh argv stays as it was
    for _e, cfg in wiz.worklist.materialize():
        assert "--hostname" not in cfg.to_cli_args()


def test_ask9_single_row_mesh_worklist_does_prefill(wiz):
    """...and with exactly one image there is no ambiguity, so it prefills again —
    into the plain field, which since issue #229 edits THAT ROW's entry: the value
    lands on the worklist entry (the base stays blank) and the argv is unchanged."""
    mesh_flow(wiz, "pki.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert sysp.hostname.text() == "hugmesh-pki"
    assert sysp.hostname_row.isVisible() and not sysp.hostname_rows.isVisible()
    assert not sysp.hostname_note.isVisible()
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.hostname == ""
    assert wiz.worklist.entries[0].hostname == "hugmesh-pki"
    (_e, cfg), = wiz.worklist.materialize()
    assert ("--hostname", "hugmesh-pki") in pairs(cfg.to_cli_args())


def test_229_two_rows_two_hostnames_each_reach_their_own_build(wiz):
    """ISSUE #229, end to end through the real wizard: a two-row worklist, a different
    hostname typed for each image, and each materialized build receives ITS OWN -H —
    neither the other's, and the shared base never carries either."""
    mesh_flow(wiz, "pki.x86", "backend.rpi5")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert set(sysp.hostname_edits) == {"pki.x86", "backend.rpi5"}
    sysp.hostname_edits["pki.x86"].setText("ca-1")
    sysp.hostname_edits["backend.rpi5"].setText("be-pi")
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.hostname == ""
    assert {e.id: e.hostname for e in wiz.worklist.entries} == {
        "pki.x86": "ca-1", "backend.rpi5": "be-pi"}
    argvs = {e.id: cfg.to_cli_args() for e, cfg in wiz.worklist.materialize()}
    assert ("--hostname", "ca-1") in pairs(argvs["pki.x86"])
    assert ("--hostname", "be-pi") in pairs(argvs["backend.rpi5"])
    assert ("--hostname", "be-pi") not in pairs(argvs["pki.x86"])
    assert ("--hostname", "ca-1") not in pairs(argvs["backend.rpi5"])
    # the names survive a Back to the worklist and forward again (keep.hostname)
    back_to(wiz, wizard_mod.WorklistPage)
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert sysp.hostname_edits["pki.x86"].text() == "ca-1"
    assert sysp.hostname_edits["backend.rpi5"].text() == "be-pi"


def test_229_naming_one_image_leaves_the_others_derived(wiz):
    """Per image means per image: naming ONE row emits -H on that build only; the
    untouched rows still emit nothing and take their role-derived names."""
    mesh_flow(wiz, "pki.x86", "backend.x86", "frontend.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    sysp.hostname_edits["backend.x86"].setText("be-main")
    advance_to(wiz, wizard_mod.HomePage)
    argvs = {e.id: cfg.to_cli_args() for e, cfg in wiz.worklist.materialize()}
    assert ("--hostname", "be-main") in pairs(argvs["backend.x86"])
    assert "--hostname" not in argvs["pki.x86"]
    assert "--hostname" not in argvs["frontend.x86"]


def test_229_duplicate_and_malformed_hostnames_are_refused_inline(wiz):
    """Two images cannot share a name, and a name the builders' allowlist rejects is
    refused HERE (inline label, never a modal — validatePage runs headless), where the
    operator can fix it, instead of at Build time. Fixing it lets Next through."""
    mesh_flow(wiz, "pki.x86", "backend.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    sysp.hostname_edits["pki.x86"].setText("node")
    sysp.hostname_edits["backend.x86"].setText("node")
    before = wiz.currentId()
    wiz.next()
    assert wiz.currentId() == before, "a duplicate hostname must not pass"
    assert sysp.hostname_error.isVisible()
    assert "node" in sysp.hostname_error.text()
    # a typed name equal to what another BLANK row derives is the same collision
    sysp.hostname_edits["pki.x86"].setText("hugmesh-backend")
    sysp.hostname_edits["backend.x86"].clear()
    wiz.next()
    assert wiz.currentId() == before and sysp.hostname_error.isVisible()
    # the identity allowlist, per row
    sysp.hostname_edits["pki.x86"].setText("Bad_Host!")
    wiz.next()
    assert wiz.currentId() == before and "pki.x86" in sysp.hostname_error.text()
    # fixed -> through, error gone
    sysp.hostname_edits["pki.x86"].setText("ca-1")
    advance_to(wiz, wizard_mod.HomePage)
    assert not sysp.hostname_error.isVisible()
    assert {e.id: e.hostname for e in wiz.worklist.entries} == {
        "pki.x86": "ca-1", "backend.x86": ""}


def test_229_the_single_hostname_field_is_validated_inline_too(wiz, monkeypatch):
    """The per-image editors refused a malformed name from the start; the SINGLE field
    (one mesh row, and every non-mesh flow) did not — it wrote the bad value through
    and let materialize() fail a page later as "Cannot assemble the worklist", which
    points at the wrong thing. One validator now serves every path on this page, and
    the refusal is still the inline label: a modal reached from validatePage hangs a
    headless run, so nothing here may open one."""
    modals = []
    for name in ("exec", "exec_", "information", "warning", "critical", "question"):
        if hasattr(QtWidgets.QMessageBox, name):
            monkeypatch.setattr(QtWidgets.QMessageBox, name,
                                lambda *a, _n=name, **k: modals.append(_n) or 0)

    mesh_flow(wiz, "pki.x86")                      # ONE row: the plain field edits it
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert sysp.hostname_row.isVisible() and not sysp.hostname_rows.isVisible()
    before = wiz.currentId()
    sysp.hostname.setText("Bad_Host!")
    wiz.next()
    assert wiz.currentId() == before, "a malformed hostname must not pass Next"
    assert sysp.hostname_error.isVisible() and "Bad_Host!" in sysp.hostname_error.text()
    assert wiz.worklist.entries[0].hostname != "Bad_Host!"   # never written through
    sysp.hostname.setText("ca-1")
    advance_to(wiz, wizard_mod.HomePage)
    assert not sysp.hostname_error.isVisible()
    assert wiz.worklist.entries[0].hostname == "ca-1"
    assert modals == []


def test_229_the_non_mesh_hostname_field_is_validated_inline_too(wiz, monkeypatch):
    """...and the same on standalone, where there is no worklist row at all: the value
    goes to cfg.hostname, so the check belongs on the field it was typed into."""
    modals = []
    for name in ("exec", "exec_", "information", "warning", "critical", "question"):
        if hasattr(QtWidgets.QMessageBox, name):
            monkeypatch.setattr(QtWidgets.QMessageBox, name,
                                lambda *a, _n=name, **k: modals.append(_n) or 0)

    pick_mode(wiz, "standalone")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    before = wiz.currentId()
    sysp.hostname.setText("no_underscores")
    wiz.next()
    assert wiz.currentId() == before and sysp.hostname_error.isVisible()
    assert wiz.cfg.hostname != "no_underscores"
    sysp.hostname.setText("my-desktop")
    wiz.next()
    assert wiz.currentId() != before and wiz.cfg.hostname == "my-desktop"
    assert modals == []


def test_229_legacy_one_for_all_base_is_shown_per_row_and_refused_by_name(wiz):
    """A pre-#229 envelope carries ONE base hostname that rode onto every image. The
    page shows that value on every row it was going to name (nothing is dropped
    silently), Next refuses the collision by name, and naming the rows apart is what
    clears it — after which the base is blank and each build gets its own -H."""
    mesh_flow(wiz, "pki.x86", "backend.x86")
    wiz.cfg.hostname = "everyone"            # the loaded envelope's one-for-all value
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert {rid: ed.text() for rid, ed in sysp.hostname_edits.items()} == {
        "pki.x86": "everyone", "backend.x86": "everyone"}
    before = wiz.currentId()
    wiz.next()
    assert wiz.currentId() == before and "everyone" in sysp.hostname_error.text()
    sysp.hostname_edits["backend.x86"].setText("be-1")
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.hostname == ""
    argvs = {e.id: cfg.to_cli_args() for e, cfg in wiz.worklist.materialize()}
    assert ("--hostname", "everyone") in pairs(argvs["pki.x86"])
    assert ("--hostname", "be-1") in pairs(argvs["backend.x86"])


def test_229_rows_that_derive_the_same_name_are_told_not_blocked(wiz):
    """pki.x86 + pki.rpi5 both derive hugmesh-pki. The builder has always produced
    that pair, so the page does not refuse it — but it says so in the note, and the
    fix (naming one) is one keystroke away. This is exactly the case the OLD page
    handled worst: with one distinct derived name it prefilled that name into the
    single field and baked it onto both."""
    mesh_flow(wiz, "pki.x86", "pki.rpi5")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert sysp.hostname_rows.isVisible()
    assert "hugmesh-pki" in sysp.hostname_note.text()
    assert "name at least one" in sysp.hostname_note.text()
    sysp.hostname_edits["pki.rpi5"].setText("ca-pi")
    advance_to(wiz, wizard_mod.HomePage)
    argvs = {e.id: cfg.to_cli_args() for e, cfg in wiz.worklist.materialize()}
    assert "--hostname" not in argvs["pki.x86"]
    assert ("--hostname", "ca-pi") in pairs(argvs["pki.rpi5"])


def test_ask9_mesh_worklist_does_not_bake_the_x86_account_onto_every_arm_node(wiz):
    """The hostname field's honesty arm, applied to the field that was missing it.

    ``derive_default_user`` is PLATFORM-keyed: x86 resolves to --local-user (the Studio
    default account, i.e. the invoking user), every ARM board to its own builder
    DEFAULT_USER ('pi' on rpi5). The page seeded off the BASE config, which the
    WorklistPage pins to x86 — so a mixed worklist prefilled the x86 account and then
    emitted `-u <x86 account>` on the rpi5 row, which had emitted nothing before and
    whose builder would have used 'pi'. Baking a default account onto a board that
    never asked for one is exactly what the hostname guard exists to stop."""
    mesh_flow(wiz, "pki.x86", "backend.rpi5")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert sysp.user.text() == ""
    assert sysp.user_note.isVisible()
    for name in (default_local_user(), "pi"):
        assert name in sysp.user_note.text()
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert "--user" not in wiz.cfg.to_cli_args()
    by_id = {e.id: cfg for e, cfg in build._materialized}
    assert by_id["backend.rpi5"].user == ""
    assert "--user" not in by_id["backend.rpi5"].to_cli_args()


def test_ask9_a_worklist_whose_rows_agree_still_prefills(wiz):
    """The fix is a per-row AGREEMENT test, not a blanket "blank it in mesh": an
    all-x86 worklist derives one account for every row, so ask 9's preselect stands."""
    mesh_flow(wiz, "pki.x86", "backend.x86", "frontend.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert sysp.user.text() == derive_default_user(wiz.cfg) != ""
    assert not sysp.user_note.isVisible()
    advance_to(wiz, wizard_mod.BuildPage)
    assert ("--user", derive_default_user(wiz.cfg)) in pairs(wiz.cfg.to_cli_args())


def test_ask9_the_per_row_account_probe_matches_the_materialized_rows(wiz):
    """DRIFT GUARD for the probe itself: SystemPage derives each row's account from a
    SimpleNamespace rather than materializing (materialize is not free and emits build
    notes), so pin that shortcut against the real thing — every id, every value."""
    mesh_flow(wiz, "pki.x86", "backend.rpi5", "edge-ai.jetson")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    probed = dict(sysp._worklist_default_users(wiz.cfg))
    real = {e.id: derive_default_user(cfg) for e, cfg in wiz.worklist.materialize()}
    assert probed == real
    assert len(set(real.values())) > 1, "this worklist no longer exercises disagreement"


def test_ask9_a_single_arm_image_prefills_its_own_platform_account(wiz):
    """Per-platform, not x86-and-hope: a lone rpi5 image preselects the rpi5 builder's
    account, which is the only value that makes ask 9's "exactly what this build would
    produce if you left it blank" true.

    RE-DRIVEN from cloud/rpi5-desktop onto standalone/generic — still a lone rpi5
    image (the "Generic arm64 server" row IS a Raspberry Pi 5), and still derives "pi",
    so the property under test is untouched. The old subject was DESKTOP-class, and
    since the 2026-08-26 duplicate collapse a desktop has no "Default user" row to
    read (system.default_user_is_local_user) — the assertion would have been checking
    a hidden widget's leftover text rather than the preselect."""
    pick_mode(wiz, "standalone")
    role = advance_to(wiz, wizard_mod.RolePage)
    assert role.select_role("generic"), "generic (rpi5 node) not offered in standalone"
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert wiz.cfg.platform == "rpi5", "this test no longer exercises an ARM image"
    assert sysp.user.isVisibleTo(sysp), "a node image must still own the -u question"
    assert sysp.user.text() == derive_default_user(wiz.cfg) == "pi"
    assert not sysp.user_note.isVisible()


def test_ask9_an_operator_value_always_wins(wiz):
    """A typed hostname/user/zone survives a Back/Next round trip — the preselect only
    ever fills a field the operator has not set."""
    pick_mode(wiz, "cloud")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    sysp.hostname.setText("node-1")
    sysp.user.setText("operator")
    i = sysp.timezone.findText("UTC")
    sysp.timezone.setCurrentIndex(i)
    advance_to(wiz, wizard_mod.HomePage)
    back_to(wiz, wizard_mod.SystemPage)
    assert sysp.hostname.text() == "node-1"
    assert sysp.user.text() == "operator"
    assert sysp.timezone.currentText() == "UTC"


def test_ask9_placeholders_stay_humanized(qapp):
    """The public-polish contract survives the widget swap: no raw builder flag in a
    prompt an operator reads, but still discoverable in the tooltip."""
    page = _system_page()
    assert "--hostname" not in page.hostname.placeholderText()
    assert "--hostname" in page.hostname.toolTip()
    assert "--timezone" not in page.timezone.placeholderText()
    assert "--timezone" in page.timezone.toolTip()
    assert "--user" not in page.user.placeholderText()


# ══════════════════════════════════════════════════════════════════════════════════
# ASK 10 — node fallback credentials are an opt-in
# ══════════════════════════════════════════════════════════════════════════════════

def test_ask10_credentials_are_hidden_and_silent_until_opted_in(wiz):
    """Unchecked by default, fields not on screen, nothing emitted."""
    mesh_flow(wiz, "pki.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert sysp.creds.isVisible()                    # the group itself still applies
    assert not sysp.creds_optin.isChecked()          # ...but the credentials are opt-in
    assert not sysp.creds_fields.isVisible()
    assert sysp.user_password.text() == "" and sysp.root_password.text() == ""
    advance_to(wiz, wizard_mod.HomePage)
    args = wiz.cfg.to_cli_args()
    assert "--user-password" not in args and "--root-password" not in args


def test_ask10_opting_in_reveals_the_fields_and_emits(wiz):
    mesh_flow(wiz, "pki.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    sysp.creds_optin.setChecked(True)
    assert sysp.creds_fields.isVisible()
    sysp.user_password.setText("fallback-user-pw")
    sysp.root_password.setText("fallback-root-pw")
    advance_to(wiz, wizard_mod.HomePage)
    got = pairs(wiz.cfg.to_cli_args())
    assert ("--user-password", "fallback-user-pw") in got
    assert ("--root-password", "fallback-root-pw") in got


def test_ask10_deselecting_wipes_the_typed_credentials(wiz):
    """SECURITY arm: a password typed then de-selected must not sit invisible in the
    widget and get submitted on the next Next. Both the widget and the config clear."""
    mesh_flow(wiz, "pki.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    sysp.creds_optin.setChecked(True)
    sysp.user_password.setText("typed-then-abandoned")
    sysp.root_password.setText("typed-then-abandoned-root")
    sysp.creds_optin.setChecked(False)
    assert sysp.user_password.text() == "" and sysp.root_password.text() == ""
    assert not sysp.creds_fields.isVisible()
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.user_password == "" and wiz.cfg.root_password == ""
    args = wiz.cfg.to_cli_args()
    assert "typed-then-abandoned" not in " ".join(args)
    # ...and re-opting in starts from empty, never from the abandoned value
    back_to(wiz, wizard_mod.SystemPage)
    sysp.creds_optin.setChecked(True)
    assert sysp.user_password.text() == "" and sysp.root_password.text() == ""


def test_ask10_passwords_are_masked_and_never_prefilled(wiz):
    """Never pre-fill a password: even a config that somehow carries one arrives with
    the opt-in reflecting it rather than a silently populated hidden box."""
    mesh_flow(wiz, "pki.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert sysp.user_password.echoMode() == QtWidgets.QLineEdit.EchoMode.Password
    assert sysp.root_password.echoMode() == QtWidgets.QLineEdit.EchoMode.Password
    # secrets are never persisted, so a reloaded config is always un-opted-in
    assert sysp.user_password.text() == ""
    page = _system_page(ImageConfig(mode="mesh", role="pki", platform="x86",
                                    user_password="carried"))
    page.initializePage()
    assert page.creds_optin.isChecked()          # honestly reflects a held credential
    assert page.creds_fields.isVisibleTo(page)


def test_ask10_optin_slot_is_exception_guarded(wiz, capsys):
    """PyQt6 duality: an exception escaping this slot would qFatal the Studio. The slot
    swallows-and-logs instead — proven by breaking the widget it touches."""
    mesh_flow(wiz, "pki.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    sysp.creds_fields = None                      # force an AttributeError inside
    sysp._optin_toggled(True)                     # must NOT raise
    assert "swallowed exception in _optin_toggled" in capsys.readouterr().err


def test_ask10_the_collect_gate_holds_when_the_wipe_slot_swallowed(wiz, capsys):
    """The BELT-AND-BRACES half of ask 10, which the suite did not pin.

    ``_optin_toggled``'s wipe is exception-GUARDED (it has to be — under PyQt6 an
    exception escaping a slot calls qFatal), so a failure inside it is swallowed and
    the wipe silently does not happen. That is not hypothetical: the test directly
    above proves the swallow. In exactly that state a password typed and then
    de-selected is still sitting in the widget, and ``validatePage``'s opt-in gate is
    the ONLY thing standing between it and the emitted argv.

    So: break the slot the way that test breaks it, abandon a password, and require
    that Next collects nothing."""
    mesh_flow(wiz, "pki.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    sysp.creds_optin.setChecked(True)
    sysp.user_password.setText("typed-then-abandoned")
    sysp.root_password.setText("typed-then-abandoned-root")
    sysp.creds_fields = None                      # the wipe will now raise + swallow
    sysp.creds_optin.setChecked(False)
    assert "swallowed exception in _optin_toggled" in capsys.readouterr().err
    # the precondition this guard exists for: the widgets were NOT wiped
    assert sysp.user_password.text() == "typed-then-abandoned"
    assert not sysp.creds_optin.isChecked()
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.user_password == "" and wiz.cfg.root_password == ""
    assert "typed-then-abandoned" not in " ".join(wiz.cfg.to_cli_args())


def test_ask10_a_populated_field_that_was_never_opted_into_emits_nothing(wiz):
    """The same gate stated as its invariant: the CHECKBOX decides, not the widget.
    A box populated by any path other than the operator ticking the opt-in (a restore,
    a preset, a future page that reuses these widgets) contributes nothing."""
    mesh_flow(wiz, "pki.x86")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert not sysp.creds_optin.isChecked()       # never opted in
    sysp.user_password.setText("never-opted-in")  # setText fires no toggled signal
    sysp.root_password.setText("never-opted-in-root")
    assert sysp.validatePage()
    assert wiz.cfg.user_password == "" and wiz.cfg.root_password == ""
    # ...and this really is a flow where the creds WOULD have been emitted: opting in
    # with the same text does reach the argv, so the empty result above is the gate
    # doing its job, not the platform/role clears masking it.
    sysp.creds_optin.setChecked(True)
    sysp.user_password.setText("now-opted-in")
    sysp.root_password.setText("now-opted-in-root")
    assert sysp.validatePage()
    assert wiz.cfg.user_password == "now-opted-in"
    assert ("--user-password", "now-opted-in") in pairs(wiz.cfg.to_cli_args())


# ══════════════════════════════════════════════════════════════════════════════════
# ASK 12 — root encryption is a mesh device default
# ══════════════════════════════════════════════════════════════════════════════════

def test_ask12_mesh_defaults_encrypt_root_on(wiz):
    """Entering mesh seeds the encrypted-root posture; the Home step SHOWS it checked
    (the GUI is honest about what will happen) and the argv carries --encrypt-root."""
    mesh_flow(wiz)
    home = advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.encrypt_root is True
    assert home.encrypt_root.isChecked()
    assert home.enc_mesh_note.isVisible()                 # ...and says what it costs
    assert "installer ISO" in home.enc_mesh_note.text()
    assert "prompts" in home.enc_mesh_note.text()
    advance_to(wiz, wizard_mod.BuildPage)
    assert "--encrypt-root" in wiz.cfg.to_cli_args()


def test_ask12_every_worklist_row_inherits_the_mesh_default(wiz):
    """The per-row override stays "default", and "default" now resolves to ON for every
    materialized entry — that is where the posture actually lands."""
    mesh_flow(wiz)
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert {e.encrypt_root for e in wiz.worklist.entries} == {"default"}
    for _entry, cfg in build._materialized:
        assert cfg.encrypt_root is True
        assert "--encrypt-root" in cfg.to_cli_args()


def test_ask12_jetson_rows_stay_exempt(wiz):
    """The jetson builder hard-blocks --encrypt-root, so the mesh default must not make
    to_cli_args() raise for a jetson row."""
    mesh_flow(wiz, "edge-ai.jetson", "pki.x86")
    build = advance_to(wiz, wizard_mod.BuildPage)
    by_plat = {e.platform: cfg for e, cfg in build._materialized}
    assert by_plat["jetson"].encrypt_root is False
    assert "--encrypt-root" not in by_plat["jetson"].to_cli_args()   # would raise if set
    assert "--encrypt-root" in by_plat["x86"].to_cli_args()


def test_ask21_encryption_is_always_on_and_cannot_be_turned_off(wiz):
    """ASK 21 SUPERSEDED ask 12's wording: "root disk encryption should always be
    enabled", not merely defaulted on.

    So the Home step shows a STATEMENT, not a choice — checked and deliberately
    disabled — and nothing an operator can do to the widget changes the collected
    value. Un-ticking it programmatically (what a stale loaded config or a rogue
    stylesheet click would do) must not reach the config."""
    mesh_flow(wiz)
    home = advance_to(wiz, wizard_mod.HomePage)
    assert home.encrypt_root.isChecked()
    assert not home.encrypt_root.isEnabled(), "ask 21: still offered as a choice"
    home.encrypt_root.setChecked(False)               # the widget can be forced...
    advance_to(wiz, wizard_mod.BuildPage)
    assert wiz.cfg.encrypt_root is True, "...but the posture is asserted, not read"
    assert "--encrypt-root" in wiz.cfg.to_cli_args()
    # ...and a Back through Mode (which re-runs enter_mesh_defaults) keeps it on
    back_to(wiz, wizard_mod.ModePage)
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.encrypt_root is True
    assert home.encrypt_root.isChecked()


def test_ask21_a_loaded_unencrypted_config_is_corrected_not_obeyed(wiz):
    """The honesty half: a config saved BEFORE this posture (encrypt_root=false) must
    not render an unchecked, disabled box that the collect then overrides — the GUI
    would be lying about the image it is going to build."""
    wiz.cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                          encrypt_root=False)
    wiz.restart()
    home = advance_to(wiz, wizard_mod.HomePage)
    assert home.encrypt_root.isChecked()
    assert home.validatePage()
    assert wiz.cfg.encrypt_root is True


@pytest.mark.parametrize("mode", ["cloud", "standalone"])
def test_ask21_encryption_is_always_on_outside_mesh_too(wiz, mode):
    """"ALWAYS" means always. Ask 12 scoped it to mesh devices; ask 21 did not, so the
    cloud and standalone desktop flows now carry it as well.

    THIS CHANGES WHAT THOSE BUILDS PRODUCE — on x86 --encrypt-root also forces
    INSTALLER_ISO=true, and without a passphrase the installer prompts at install time.
    The dataclass default stays False on purpose (a bare ImageConfig(platform="jetson")
    must not raise at to_cli_args); the posture is applied where the platform is known."""
    pick_mode(wiz, mode)
    home = advance_to(wiz, wizard_mod.HomePage)
    assert home.encrypt_root.isChecked() and not home.encrypt_root.isEnabled()
    # ...and the consequence is stated HERE, not only on the mesh note: on x86 the
    # builder turns --encrypt-root into INSTALLER_ISO=true unconditionally
    # (build-x86-host-stage4.sh:1780), so a cloud client that never asked for an
    # installer ISO now gets one.
    assert home.enc_always_note.isVisible()
    assert "installer ISO" in home.enc_always_note.text()
    assert "asks for one at install time" in home.enc_always_note.text()
    advance_to(wiz, wizard_mod.BuildPage)
    assert wiz.cfg.encrypt_root is True, mode
    assert "--encrypt-root" in wiz.cfg.to_cli_args(), mode
    assert ImageConfig().encrypt_root is False        # the dataclass default is unchanged


def test_ask21_encrypt_root_always_is_keyed_on_the_real_emission_table(wiz):
    """The exemption list cannot drift from the emission table: encrypt_root_always is
    True for exactly the platforms PLATFORM_FIELD_SUPPORT says take the flag, and the
    one platform it excludes is the one whose to_cli_args RAISES on it."""
    from hugmesh_studio.core.config import PLATFORM_FIELD_SUPPORT
    supported = set(PLATFORM_FIELD_SUPPORT["encrypt_root"])
    assert "jetson" not in supported
    for plat in sorted(supported | {"jetson"}):
        cfg = ImageConfig(mode="standalone", platform=plat)
        assert encrypt_root_always(cfg) is (plat in supported), plat
    # the jetson exclusion is relied on, not cosmetic
    with pytest.raises(ValueError):
        ImageConfig(mode="standalone", role="full", platform="jetson",
                    encrypt_root=True).to_cli_args()


def test_ask12_manifest_v2_reports_the_encrypted_posture(wiz):
    """The mesh manifest v2 REPORTS the resolved per-image value
    (worklist_driver.manifest_v2), so an operator reading a session record now sees
    encrypt_root true for every node — which the survey found was NOT true before."""
    from hugmesh_studio.core.worklist_driver import WorklistDriver
    mesh_flow(wiz, "pki.x86", "backend.x86")
    advance_to(wiz, wizard_mod.BuildPage)
    drv = WorklistDriver(wiz.generator_dir, wiz.worklist, host=wiz.host)
    images = drv.manifest_v2()["images"]
    assert {i["id"] for i in images} == {"pki.x86", "backend.x86"}
    assert all(i["encrypt_root"] is True for i in images), images
    # the manifest also carries NO domains/users while the ask-8 opt-in is off
    assert drv.manifest_v2()["domains"] == [] and drv.manifest_v2()["users"] == []


# ── cross-ask: the two new gates are reachable from a loaded config too ─────────────

def test_loaded_mesh_config_keeps_both_new_gates_coherent(wiz):
    """A config loaded straight into the wizard (no Mode click) must still route
    correctly: each table is reachable exactly when ITS OWN flow flag says so.

    Asks 19/20 split what ask 8 had joined, so this asserts both directions
    independently — a single flag driving both would pass a one-sided version of this
    test while breaking the "second domain but generated accounts" flow."""
    wiz.cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                          additional_domains=True, configure_users=True,
                          domains=[Domain(name="acme.example", title="Acme")],
                          users=[User(username="bob", domain="acme.example")])
    wiz.restart()
    dom_id, usr_id = wiz._page_ids["domains"], wiz._page_ids["users"]
    terminal = {wiz._page_ids[s] for s in ("build", "launch", "progress")}
    assert not wiz._dynamically_skipped(dom_id, terminal)
    assert not wiz._dynamically_skipped(usr_id, terminal)
    # each flag gates ONLY its own table
    wiz.cfg.additional_domains = False
    assert wiz._dynamically_skipped(dom_id, terminal)
    assert not wiz._dynamically_skipped(usr_id, terminal)
    wiz.cfg.additional_domains, wiz.cfg.configure_users = True, False
    assert not wiz._dynamically_skipped(dom_id, terminal)
    assert wiz._dynamically_skipped(usr_id, terminal)
    wiz.cfg.additional_domains = False
    assert wiz._dynamically_skipped(dom_id, terminal)
    assert wiz._dynamically_skipped(usr_id, terminal)


# ══════════════════════════════════════════════════════════════════════════════════
# ASK 20 — the generated-accounts card must STATE which accounts and WHERE
#
#   "a big icon button to proceed with the MINIMAL needed users in the default config
#    — AND THE BUTTON ITSELF must state which users get generated and where the
#    credentials will be found when it is done"
#
# The half that matters is the CARD TEXT, and it is only worth anything if it is TRUE.
# These read the claim off the real key channel (scripts/gen-provision-keys.sh, via
# core.worklist_driver.key_profile) rather than trusting the sentence.
# ══════════════════════════════════════════════════════════════════════════════════

def test_ask20_generated_card_names_the_account_and_where_to_find_it(wiz):
    """The card names the ACCOUNT, the NODE it lands on, the FILES, and the caveat —
    for the worklist actually selected."""
    mesh_flow(wiz, "pki.x86", "backend.x86")
    uc = advance_to(wiz, wizard_mod.UsersChoicePage)
    text = uc._buttons["generated"].accessibleDescription()
    assert text == default_accounts_summary(wiz)          # painted == asserted
    assert "admin" in text                                # gen-provision-keys.sh ADMIN
    assert "pki.x86" in text                              # the node that gets accounts
    assert "users.json" in text and "admin_ed25519" in text
    assert "backend.x86" in text and "keys only" in text       # the worker node, named
    # precise about WHICH root: the generated key set locks root; ask 10's baked
    # --root-password is a different channel and the card must not blur them
    assert "root login stays LOCKED" in text
    assert "different channel" in text


def test_ask20_generated_card_claim_matches_the_real_key_channel(wiz):
    """DRIFT GUARD: the card says accounts land on the pki-profile node(s) and nowhere
    else. That is gen-provision-keys.sh's own rule (only its `pki` arm writes
    users.json; every other profile ends `rm -f users.json`), reached here through
    worklist_driver.key_profile — so a KEY_PROFILE edit that moved which roles mint
    accounts fails this test instead of silently making the card a lie."""
    from hugmesh_studio.core.worklist_driver import key_profile
    mesh_flow(wiz, "pki.x86", "backend.x86", "frontend.x86")
    uc = advance_to(wiz, wizard_mod.UsersChoicePage)
    text = uc._buttons["generated"].accessibleDescription()
    accounts_half, sep, workers_half = text.partition("The other nodes (")
    assert sep, "the card no longer distinguishes account nodes from key-only nodes"
    for e in wiz.worklist.entries:
        has_accounts = key_profile(e.role, e.platform) == "pki"
        # every id is named exactly once, on the correct side of the sentence
        assert (e.id in accounts_half) is has_accounts, (
            f"{e.id} (profile {key_profile(e.role, e.platform)}) is on the wrong side")
        assert (e.id in workers_half) is not has_accounts


def test_ask20_generated_card_is_recomputed_every_visit(wiz):
    """A Back to the worklist step changes WHICH key folders the card is talking about,
    so the text is rebuilt on each initializePage — a card written once at construction
    would keep naming a node the operator has since unchecked."""
    mesh_flow(wiz, "pki.x86")
    uc = advance_to(wiz, wizard_mod.UsersChoicePage)
    first = uc._buttons["generated"].accessibleDescription()
    assert "pki.x86" in first and "omnibus.x86" not in first
    wl = back_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86")
    uc = advance_to(wiz, wizard_mod.UsersChoicePage)
    second = uc._buttons["generated"].accessibleDescription()
    assert "omnibus.x86" in second and "pki.x86" not in second


def test_ask20_generated_card_names_the_folder_the_keys_are_actually_written_to(wiz):
    """ASK 20's ONE requirement that matters — "where the credentials will be found" —
    was wrong. The card printed ``<out>/keys-<id>``; on the GUI path ProgressPage always
    hands the driver ``workdir=<out>/sessions/<session id>/``, and _generate_keys joins
    ``keys-<id>`` onto THAT. So the operator was sent to a folder that never exists.

    This asserts against the REAL writer rather than against a string: build the driver
    exactly as ProgressPage does, ask it where the folder is, and require the card's
    text to be that path with the not-yet-minted session id substituted in."""
    from hugmesh_studio.core import build_sessions
    from hugmesh_studio.core.worklist_driver import WorklistDriver, keys_dir
    from hugmesh_studio.gui.pages.users_choice import (
        _SESSION_ID_PLACEHOLDER, default_accounts_keys_dir)
    mesh_flow(wiz, "pki.x86", "backend.x86")
    uc = advance_to(wiz, wizard_mod.UsersChoicePage)
    text = uc._buttons["generated"].accessibleDescription()

    session_id = "20260806-101112-abc123"
    out = wiz.cfg.output_dir or os.path.join(wiz.generator_dir, "out")
    # ...exactly the two arguments progress.py passes at dispatch
    drv = WorklistDriver(wiz.generator_dir, wiz.worklist, host=wiz.host,
                         workdir=build_sessions.session_workdir(out, session_id))
    real = keys_dir(drv._output_dir(), "pki.x86")

    claimed = default_accounts_keys_dir(wiz, "pki.x86")
    assert claimed.replace(_SESSION_ID_PLACEHOLDER, session_id) == real
    assert claimed in text, "the card does not print the path it computes"
    # and the two specific ways it was wrong before
    assert os.path.join(out, "keys-pki.x86") not in text
    assert os.path.join("sessions", _SESSION_ID_PLACEHOLDER) in text
    assert _SESSION_ID_PLACEHOLDER in text and "minted when the build starts" in text


def test_ask20_the_session_id_really_is_visible_where_the_card_says(wiz):
    """The card tells the operator where to READ the id it left as a placeholder. That
    pointer has to be true too: the Review screen's build command carries the -w session
    workdir."""
    from hugmesh_studio.gui.pages.users_choice import _SESSION_ID_PLACEHOLDER
    mesh_flow(wiz, "pki.x86")
    uc = advance_to(wiz, wizard_mod.UsersChoicePage)
    assert "-w path of the build command" in uc._buttons["generated"].accessibleDescription()
    build = advance_to(wiz, wizard_mod.BuildPage)
    build._preview()
    cmd = build.cmd.toPlainText()
    assert os.sep + "sessions" + os.sep in cmd, cmd
    assert _SESSION_ID_PLACEHOLDER not in cmd      # the real id, not the placeholder


def test_ask20_generated_card_is_honest_when_no_account_node_is_selected(wiz):
    """A worklist of workers only mints NO account at all. The card must say so rather
    than promise credentials that will never be written."""
    mesh_flow(wiz, "backend.x86", "frontend.x86")
    uc = advance_to(wiz, wizard_mod.UsersChoicePage)
    text = uc._buttons["generated"].accessibleDescription()
    assert "none is selected yet, so no account would be created" in text


# ══════════════════════════════════════════════════════════════════════════════════
# ASK 21 — the --standalone posture left the Home step (the finding-1 guards, re-homed)
#
# The control moved to RolePage; these are the finding-1 pins from test_pages_home.py,
# re-asserted against their new owner. They are the reason the move is safe: a mesh node
# still cannot carry --standalone, and the ARM appliance flow — whose WHOLE POINT is
# --standalone — can still set it.
# ══════════════════════════════════════════════════════════════════════════════════

def _role_page(cfg):
    """RolePage touches nothing on the wizard but ``.cfg`` (verified by grep), so it
    instantiates against a stub exactly like SystemPage/HomePage do."""
    return RolePage(SimpleNamespace(cfg=cfg))


@pytest.mark.parametrize("appliance", ["orangepizero2", "orangepizero2w", "orangepizero3",
                                       "orangepi3-lts"])
def test_ask21_standalone_live_on_the_node_class_appliance(qapp, appliance):
    """REGRESSION PIN (review finding 1), carried over intact.

    orangepizero2 is node-class AND standalone: build-orangepi-zero2-stage4.sh has zero
    ROLE_CLIENT/ROLE_K8S and composes ${STANDALONE} unconditionally (:218-226). A gate
    that declared --standalone classes=("desktop",) flat hid the box on this flow and
    made the collect force-clear the value, silently downgrading a saved appliance
    config to a non-standalone, non-FDE image. The move to RolePage must not re-open
    that hole."""
    cfg = ImageConfig(mode="standalone", role=appliance, platform=appliance)
    page = _role_page(cfg)
    page.initializePage()
    assert page.standalone.isVisibleTo(page), (
        f"--standalone hidden on the {appliance} appliance — the flow's whole point is "
        "unreachable in the wizard")
    page.standalone.setChecked(True)
    assert page.validatePage()
    assert cfg.standalone is True, "the wizard force-cleared an explicitly-ticked --standalone"
    assert "--standalone" in cfg.to_cli_args()


def test_ask21_standalone_live_where_the_posture_genuinely_composes(qapp):
    """The other direction — the gate must not eat the flow --standalone exists for.

    RE-POINTED from standalone-thick to CHROMEBOOK-in-standalone by DECISION 2(b)
    (operator, 2026-08-26: the wizard "asking same questions seemingly multiple
    times"). standalone-thick is one of the three roles whose builder arm PRESETS the
    posture — build-x86-host-stage4.sh:1505 sets STANDALONE=true from the role case
    itself — so offering a "Standalone image" tick beside an image type already
    called "Standalone thick" asked the same question twice, with only one legal
    answer. Those roles now hide the box.

    Chromebook is the shape where the tick still MEANS something: its role arm sets
    no posture, so ticking it genuinely composes one. That is the flow --standalone
    exists for, so that is where this test belongs; the property it pins (visible,
    in-scope tooltip, committed, emitted) is unchanged."""
    cfg = ImageConfig(mode="standalone", role="chromebook", platform="x86")
    page = _role_page(cfg)
    page.initializePage()
    assert page.standalone.isVisibleTo(page)
    # the in-scope tooltip explains the COMPOSE, not a refusal — and it survives the
    # gate pass, which blanks any tooltip written at construction
    assert "compose the same posture" in page.standalone.toolTip()
    page.standalone.setChecked(True)
    assert page.validatePage()
    assert cfg.standalone is True
    assert "--standalone" in cfg.to_cli_args()


def test_ask21_standalone_is_hidden_where_the_role_already_pins_it(qapp):
    """The NEGATIVE the re-point above created, kept as a negative rather than lost.

    DECISION 2(b): a knob whose value the chosen role already decided is a duplicate
    question. The three x86 standalone-* desktop roles preset STANDALONE=true in the
    builder's own role case (build-x86-host-stage4.sh:1505/:1332/:1344), so the box goes —
    box AND section, leaving no orphan header.

    The FIELD is deliberately NOT cleared here, unlike an out-of-scope hide: this is
    the REDUNDANT kind of hide, the image is byte-identical either way, and clearing
    would silently rewrite a loaded config on a mere page visit."""
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86")
    page = _role_page(cfg)
    page.initializePage()
    assert not page.standalone.isVisibleTo(page), (
        "standalone-thick's builder arm already sets this posture — asking is a "
        "duplicate question with one legal answer")


def test_ask21_standalone_is_cleared_when_the_role_moves_out_of_scope(qapp):
    """The ``and scope_allows("standalone", c)`` conjunct in RolePage.validatePage,
    which nothing covered — the mutation removing it survived the whole suite.

    It is relied on because ``gate_widgets_role_class(hide=True)`` only sets
    visibility: a box ticked on an in-scope role stays TICKED when the operator moves
    to a role the field is out of scope for. Without the conjunct that stale tick is
    committed, and --standalone reaches a builder that rejects it. standalone-thick/x86
    is in scope; generic/rpi5 (the arm64 server appliance) is not, and both are on the
    same RolePage in standalone mode."""
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86")
    page = _role_page(cfg)
    page.initializePage()
    assert page.select_role("standalone-thick")
    page.standalone.setChecked(True)
    assert page.validatePage() and cfg.standalone is True      # in scope: committed
    # ...now move to the out-of-scope role. The gate HIDES the box; it does not untick.
    assert page.select_role("generic")
    assert page.standalone.isChecked(), "premise gone: the gate now unticks as well"
    assert not page.standalone.isVisibleTo(page)
    assert page.validatePage()
    assert cfg.standalone is False, "a stale tick rode onto an out-of-scope role"
    assert "--standalone" not in cfg.to_cli_args()


def test_ask21_standalone_unreachable_and_cleared_on_a_mesh_node(wiz):
    """THE finding-1 defect, re-proved at the new site. RolePage is SKIPPED in mesh
    (MODE_SKIPPED_PAGES), so the control is not merely hidden there — the page carrying
    it is never visited. The CLEAR that made the old collect safe moved to the Qt-free
    config.clear_role_class_fields, which runs at mesh entry AND for every worklist row
    inside materialize(), so a tick made on a desktop image cannot ride the deepcopied
    worklist base onto a node's argv."""
    # 1. tick it on a real standalone flow
    pick_mode(wiz, "standalone")
    role = advance_to(wiz, wizard_mod.RolePage)
    role.standalone.setChecked(True)
    advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.standalone is True
    # 2. walk BACK to Mode and switch to mesh: the page leaves the flow and the value
    #    is dropped by the Qt-free clear, not by any collect
    mode = back_to(wiz, wizard_mod.ModePage)
    mode.group.button([m for m, _, _ in mode.modes].index("mesh")).setChecked(True)
    wiz.next()
    assert wiz.cfg.standalone is False, "a stale --standalone survived the mesh switch"
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "pki.x86")
    build = advance_to(wiz, wizard_mod.BuildPage)
    assert "role" not in visited_slugs(wiz)
    for _entry, cfg in build._materialized:
        assert cfg.standalone is False
        assert "--standalone" not in cfg.to_cli_args()


def test_ask21_clear_role_class_fields_owns_the_standalone_clear(qapp):
    """The Qt-free half, directly: the guarantee no longer depends on any page being
    visited. Every out-of-scope image has the flag cleared by the same predicate the
    widget gate uses — and an IN-scope one keeps it."""
    node = ImageConfig(mode="mesh", role="pki", platform="x86", standalone=True)
    assert "standalone" in clear_role_class_fields(node)
    assert node.standalone is False
    appliance = ImageConfig(mode="standalone", role="orangepizero2",
                            platform="orangepizero2", standalone=True)
    assert "standalone" not in clear_role_class_fields(appliance)
    assert appliance.standalone is True


def test_ask21_standalone_gate_follows_the_live_role_selection(qapp):
    """On RolePage the role IS what the operator is moving through, so the gate is
    re-evaluated on every selection change — not once per page visit, which would show
    the box for the PREVIOUS role.

    Started from CHROMEBOOK rather than standalone-thick (DECISION 2(b) hides the box
    on the latter, so the visibility assertion had nothing left to prove). The real
    property — the gate re-evaluates, and probing it does not mutate the live cfg —
    needs a role where the box is SHOWN, so the composing role is the right start."""
    cfg = ImageConfig(mode="standalone", role="chromebook", platform="x86")
    page = _role_page(cfg)
    page.initializePage()
    assert page.standalone.isVisibleTo(page)
    # ...and the probe must not mutate the live config just by walking the list
    before = (cfg.role, cfg.platform)
    page._sync_standalone_gate()
    assert (cfg.role, cfg.platform) == before


# ══════════════════════════════════════════════════════════════════════════════════
# ASK 22 — "Simplify the review screen and make the build screen separate with an
#           option to continue the build and go back to the main menu."
# ══════════════════════════════════════════════════════════════════════════════════

def test_ask22_build_screen_is_separate_and_starts_nothing_on_arrival(wiz):
    """The whole point: there is now a screen BETWEEN "I finished configuring" and "a
    root build is running". Reaching it must dispatch nothing — the progress page (which
    DOES dispatch on arrival) is one deliberate click further on."""
    mesh_flow(wiz, "pki.x86")
    launch = advance_to(wiz, wizard_mod.LaunchPage)
    assert isinstance(launch, wizard_mod.LaunchPage)
    assert wiz.currentPage() is launch
    # nothing was started, and nothing was written: the session record is minted by
    # ProgressPage, not here
    assert not isinstance(wiz.currentPage(), wizard_mod.ProgressPage)
    assert launch.continue_card.text() == "Continue the build"
    assert launch.menu_card.text() == "Back to the main menu"
    assert not launch.continue_card.isCheckable()      # actions, not a pick-one group
    assert not launch.menu_card.isCheckable()


def test_ask22_launch_sits_between_review_and_progress(wiz):
    """Page ORDER, from the registry rather than by clicking: review -> launch ->
    progress, and "launch" is terminal-set (never dynamically skipped)."""
    from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS
    order = list(WIZARD_PAGE_SLUGS)
    assert order.index("build") < order.index("launch") < order.index("progress")
    mesh_flow(wiz, "pki.x86")
    advance_to(wiz, wizard_mod.BuildPage)
    wiz.next()
    assert isinstance(wiz.currentPage(), wizard_mod.LaunchPage)


def test_ask22_launch_is_never_dynamically_skipped(wiz):
    """The terminal-set membership, pinned by the only thing it changes.

    ``nextId`` adds "launch" to the never-dynamically-skipped set alongside build and
    progress. Page order alone cannot prove that: LaunchPage declares no ``applies_to``,
    so ``_dynamically_skipped`` returns False for it either way and the addition was
    unreachable code the suite could not see removed. Give the page the ``applies_to``
    the guard exists to overrule, and require the flow to land on it anyway — a skipped
    launch screen would dispatch on arrival at Progress, which is exactly what ask 22
    took away."""
    mesh_flow(wiz, "pki.x86")
    advance_to(wiz, wizard_mod.BuildPage)
    launch = wiz.page(wiz._page_ids["launch"])
    launch.applies_to = lambda cfg: False        # "this page contributes nothing"
    try:
        wiz.next()
        assert isinstance(wiz.currentPage(), wizard_mod.LaunchPage), (
            "launch was dynamically skipped — Progress dispatches on arrival")
    finally:
        del launch.applies_to


def test_ask22_continue_advances_to_the_run(wiz, qapp, monkeypatch, tmp_path):
    """"an option to continue the build" — the card is what advances to the page that
    actually runs it. The page dispatches on arrival, so the driver does nothing here (see
    _install_inert_build_driver) and the dispatch is asserted through it: before
    2026-09-04 this test walked onto the page unstubbed and started a real
    `sudo -A bash ./build-x86-host-stage4.sh` every run."""
    runs = _install_inert_build_driver(monkeypatch)
    mesh_flow(wiz, "pki.x86")
    _point_output_dir(wiz, tmp_path)
    launch = advance_to(wiz, wizard_mod.LaunchPage)
    assert wiz.worklist.base.output_dir == str(tmp_path / "out")
    launch._continue()
    page = wiz.currentPage()
    assert isinstance(page, wizard_mod.ProgressPage)
    _settle_run(qapp, page)
    assert runs == [("pki", "x86", "native")]      # dispatched on arrival — via the stub
    assert page.isComplete()


def test_ask22_an_unstubbed_arrival_is_refused_not_elevated(wiz, qapp, monkeypatch, tmp_path):
    """The 2026-09-04 hang, end to end through the REAL page and the REAL driver, with
    nothing stubbed on the dispatch path: arriving at ProgressPage under pytest must
    surface core.build_driver.ElevationRefused in the log pane and end the run — never
    Popen a `sudo -A` (tests/conftest.py's spy would error this test if it did).

    `which` is pinned for sudo/pkexec only, so the prefix is deterministically
    `sudo -A` on any box (the refusal is what is under test, not the host's PATH)."""
    real_which = bd.shutil.which
    monkeypatch.setattr(bd.shutil, "which",
                        lambda name, *a, **k: (f"/usr/bin/{name}" if name in ("sudo", "pkexec")
                                               else real_which(name, *a, **k)))
    mesh_flow(wiz, "pki.x86")
    _point_output_dir(wiz, tmp_path)
    launch = advance_to(wiz, wizard_mod.LaunchPage)
    launch._continue()
    page = wiz.currentPage()
    assert isinstance(page, wizard_mod.ProgressPage)
    _settle_run(qapp, page)
    log = page.log.toPlainText()
    assert "refusing to spawn sudo" in log and "pytest is running this process" in log, log
    # the DRIVER now owns the refusal (#374): it fails that one image and the run ends
    # through the normal path, so the worker's catch-all line is no longer the witness
    assert "worklist finished (summary exit 1)" in log
    assert page.isComplete()                                       # the run ENDED
    # #374: a refusal is a FAILED image, not a 'running' one recorded as the operator's
    # 'stopped': the row reaches a terminal state, nothing stays registered, and the
    # session history says failed.
    assert [r.status for r in page.driver.results] == ["failed"]
    assert page.driver.results[0].exit_code == 1
    assert page.driver._drivers == {}
    assert all(r.terminal for r in page._rows)                     # not stuck on the running glyph
    from hugmesh_studio.core import build_sessions as _bs
    assert [s.status for s in _bs.load_all()] == ["failed"]
    assert not (tmp_path / "out" / "sessions").exists() or not any(
        p.name.startswith("wl-") for s in (tmp_path / "out" / "sessions").iterdir()
        for p in s.iterdir()), "a build tree was created — something ran"


def test_ask22_main_menu_returns_to_the_first_screen_with_config_intact(wiz):
    """"and go back to the main menu" — the escape the commit page took away (Qt
    disables Back after a commit page, so Cancel was the only exit). It must return to
    the FIRST screen and keep the configuration."""
    mesh_flow(wiz, "pki.x86")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.brand.setText("acme")
    launch = advance_to(wiz, wizard_mod.LaunchPage)
    launch._main_menu()
    assert isinstance(wiz.currentPage(), wizard_mod.WelcomePage)
    assert wiz.cfg.brand == "acme", "the main-menu return discarded the configuration"
    assert wiz.cfg.mode == "mesh"


def test_ask22_launch_slots_are_exception_guarded(wiz, capsys):
    """PyQt6 duality: an exception escaping either slot would qFatal the Studio."""
    mesh_flow(wiz, "pki.x86")
    launch = advance_to(wiz, wizard_mod.LaunchPage)
    launch.wiz = None                       # force an AttributeError inside both slots
    launch._continue()
    launch._main_menu()
    err = capsys.readouterr().err
    assert "swallowed exception in _continue" in err
    assert "swallowed exception in _main_menu" in err


def test_ask22_launch_summary_says_what_will_run(wiz):
    """The screen states what Continue will do, read off the COMMITTED worklist — so it
    can never describe a different build than the one that is about to start."""
    mesh_flow(wiz, "pki.x86", "backend.x86")
    launch = advance_to(wiz, wizard_mod.LaunchPage)
    text = launch.summary.text()
    assert text == launch_summary(wiz)
    assert "pki.x86" in text and "backend.x86" in text
    assert "2 image(s)" in text
    assert (wiz.cfg.output_dir or os.path.join(wiz.generator_dir, "out")) in text
    assert "Generate node keys" in text        # mesh-only line


def test_ask22_review_screen_leads_with_a_plain_language_summary(wiz):
    """"Simplify the review screen": the answer to "what will this produce" is a block
    of prose at the TOP, not a 500-character argv the operator has to parse. The exact
    command is kept — folded, one click away — because it is developer output, not the
    review."""
    mesh_flow(wiz, "pki.x86")
    build = advance_to(wiz, wizard_mod.BuildPage)
    summary = build.summary.text()
    assert summary == build.review_summary()
    assert "pki.x86" in summary
    assert "Artifacts:" in summary
    assert "LUKS2-encrypted root" in summary          # ask 21's consequence, stated
    assert build.cmd.toPlainText()                    # the argv is still there verbatim
    assert not build.cmd_section.toggle.isChecked()   # ...folded by default
    assert not build.cmd.isVisible()
    # ...and one click brings it back, unchanged — the fold is presentation only
    argv = build.cmd.toPlainText()
    build.cmd_section.set_expanded(True)
    assert build.cmd.isVisible() and build.cmd.toPlainText() == argv
    # the PREFLIGHT/log pane is NOT inside the fold: a blocking problem must never be
    # hidden along with the argv (and neither must the button that fixes one)
    build.cmd_section.set_expanded(False)
    assert build.log.isVisible()
    assert build.preview_btn.isVisible()


def test_ask22_review_summary_describes_the_same_build_the_command_does(wiz):
    """The summary and the command pane are rendered from the SAME committed state, so
    a change on the page moves both — a summary that could drift from the argv beside it
    would be worse than no summary."""
    mesh_flow(wiz, "pki.x86")
    build = advance_to(wiz, wizard_mod.BuildPage)
    first = build.review_summary()
    build.jobs.setValue(build.jobs.value() + 1)
    build._preview()
    assert build.summary.text() == build.review_summary()
    assert build.summary.text() != first
    assert str(build.jobs.value()) in build.summary.text()


def test_ask7_only_superadmin_is_claimed_to_change_the_image(wiz):
    """ASK 7's "describe what it ACTUALLY does" clause, held to the code.

    Exactly one tier changes what gets built — `superadmin`, which bakes
    /etc/hugmesh/device-password-required (build-x86-host-stage4.sh:4375-4376), the one
    person-role marker the shipped first-boot path really consumes
    (specs/etc/keys-provision/provision.sh:395). The other three are labels. The page
    must say so both ways round, or an operator picking `admin` will believe they have
    hardened a device they have not."""
    pick_mode(wiz, "cloud")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    for tier in ("user", "mod", "admin"):
        sysp.person_role.setCurrentText(tier)
        assert "changes nothing about the image" in sysp.person_role_help.text(), tier
    sysp.person_role.setCurrentText("superadmin")
    help_text = sysp.person_role_help.text()
    assert "SEPARATE device password" in help_text
    assert "changes nothing about the image" not in help_text
