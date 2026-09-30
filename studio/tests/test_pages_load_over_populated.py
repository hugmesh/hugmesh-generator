"""Loading a configuration into an ALREADY-POPULATED table must show the loaded rows
(#542).

The defect these pin, exactly as it was watched: ``DomainsPage.initializePage`` filled
the table only when ``rowCount() == 0``. ``StudioWizard.load_config`` / ``load_session``
replace ``wiz.cfg`` wholesale and call ``restart()``; ``restart()`` re-enters every page,
``initializePage`` took the else-branch, and the previous flow's rows stayed. That is not
a display bug — ``DomainsPage.validatePage`` rebuilds ``cfg.domains`` FROM the table, so
the domains the operator had just loaded were erased from the configuration. And a
domain that is no longer in ``cfg.domains`` can never be refused by the #495 per-domain
services gate, so the operator loses the rows AND the guard that exists to notice.

``UsersPage`` carried the identical shape and is pinned here too.

The fix is identity, not equality (same idiom as ``pages/domain_services.py``): a
DIFFERENT cfg object means refill; a ``restart()`` on the SAME object must still keep
the operator's in-progress edits, which is the second half of every pair below.

Same harness as tests/test_pages_domains_services.py — the real wizard on Qt's
offscreen platform, no ``.exec()`` anywhere.
"""
import json
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import Domain, ImageConfig, User  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages.domains import _COL_NAME  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402

from _helpers import (  # noqa: E402
    advance_to, check_worklist_rows, enable_additional_domains,
    enable_configure_users, pick_mode)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

_USERS_COL_NAME = 0


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-load-over-populated-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _mesh_domains(wiz):
    """Walk a fresh mesh flow to the Domains table."""
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86")
    enable_additional_domains(wiz)
    return advance_to(wiz, wizard_mod.DomainsPage)


def _mesh_cfg(domains=(), users=()):
    """A mesh ImageConfig that routes through BOTH superadmin tables."""
    c = ImageConfig()
    c.mode = "mesh"
    c.role = "omnibus"
    c.additional_domains = True
    c.configure_users = True
    c.domains = list(domains)
    c.users = list(users)
    return c


def _names(table, col):
    """The ADDED rows' text — row 0 is the mesh's own domain since #494 (display-only,
    never a cfg.domains row), so it is not one of "the rows a load must replace"."""
    dom = table.parentWidget()
    while dom is not None and not hasattr(dom, "is_own_row"):
        dom = dom.parentWidget()
    return [table.item(r, col).text() for r in range(table.rowCount())
            if dom is None or not dom.is_own_row(r)]


# ---- Domains: load over a populated table ---------------------------------------

def test_load_session_over_a_populated_domains_table_replaces_the_rows(wiz):
    """THE REPORTED BUG. Populate the table by hand (the previous flow), then load a
    configuration that names a DIFFERENT domain. Before the fix the loaded
    ``zeta.example`` never appeared and the stale row survived."""
    dom = _mesh_domains(wiz)
    dom._add("stale.example", "Stale")
    assert _names(dom.table, _COL_NAME) == ["stale.example"]

    loaded = _mesh_cfg(domains=[Domain(name="zeta.example", title="Zeta")])
    wiz.load_session(WorklistConfig(base=loaded).to_dict())

    dom2 = advance_to(wiz, wizard_mod.DomainsPage)
    assert dom2 is dom, "the wizard reuses the page instance — that is why it can go stale"
    assert _names(dom.table, _COL_NAME) == ["zeta.example"]


def test_the_loaded_domains_survive_into_the_configuration_not_just_the_display(wiz):
    """The half that makes this an ERASURE and not a cosmetic bug: validatePage writes
    the table back over cfg.domains, so a stale table does not merely hide the loaded
    domains, it deletes them. Walking PAST Domains is what runs validatePage."""
    dom = _mesh_domains(wiz)
    dom._add("stale.example", "Stale")

    loaded = _mesh_cfg(domains=[Domain(name="zeta.example", title="Zeta")])
    wiz.load_session(WorklistConfig(base=loaded).to_dict())

    advance_to(wiz, wizard_mod.DomainsPage)
    advance_to(wiz, wizard_mod.DomainServicesPage)      # Next past Domains collects
    assert [d.name for d in wiz.cfg.domains] == ["zeta.example"]


def test_load_config_from_a_file_over_a_populated_domains_table(wiz, tmp_path):
    """The operator's actual verb is File -> Load config, which goes through
    worklist.load_any rather than load_session. Same guarantee."""
    dom = _mesh_domains(wiz)
    dom._add("stale.example", "Stale")

    path = tmp_path / "loaded.json"
    loaded = _mesh_cfg(domains=[Domain(name="zeta.example", title="Zeta")])
    path.write_text(json.dumps(WorklistConfig(base=loaded).to_dict()))
    wiz.load_config(str(path))

    advance_to(wiz, wizard_mod.DomainsPage)
    assert _names(dom.table, _COL_NAME) == ["zeta.example"]


def test_a_config_with_no_domains_clears_a_populated_domains_table(wiz):
    """The asymmetric half. If the refill only ran when the loaded config HAS domains,
    loading an empty one would leave the previous flow's rows and then write them into
    the loaded configuration — the same erasure with the arrow reversed."""
    dom = _mesh_domains(wiz)
    dom._add("stale.example", "Stale")

    wiz.load_session(WorklistConfig(base=_mesh_cfg()).to_dict())
    advance_to(wiz, wizard_mod.DomainsPage)
    assert _names(dom.table, _COL_NAME) == []          # only the own row is left


# ---- Domains: restart on the SAME cfg keeps in-progress edits --------------------

def test_restart_on_the_same_cfg_keeps_in_progress_domain_edits(wiz):
    """The behaviour the identity check BUYS over an unconditional refill: restart()
    without replacing the configuration object is not a load, and must not throw away
    what the operator has typed but not yet collected."""
    dom = _mesh_domains(wiz)
    dom._add("inprogress.example", "In progress")
    same = wiz.cfg
    wiz.restart()
    assert wiz.cfg is same

    advance_to(wiz, wizard_mod.DomainsPage)
    assert _names(dom.table, _COL_NAME) == ["inprogress.example"]


# ---- Users: the identical shape --------------------------------------------------

def _mesh_users(wiz):
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "omnibus.x86")
    enable_additional_domains(wiz)
    enable_configure_users(wiz)
    return advance_to(wiz, wizard_mod.UsersPage)


def test_load_session_over_a_populated_users_table_replaces_the_rows(wiz):
    usr = _mesh_users(wiz)
    usr._add("stale-person", "", ["user"], "")
    assert _names(usr.table, _USERS_COL_NAME) == ["stale-person"]

    loaded = _mesh_cfg(domains=[Domain(name="zeta.example", title="Zeta")],
                       users=[User(username="zeta-person", domain="zeta.example",
                                   roles=["user"])])
    wiz.load_session(WorklistConfig(base=loaded).to_dict())

    advance_to(wiz, wizard_mod.UsersPage)
    assert _names(usr.table, _USERS_COL_NAME) == ["zeta-person"]


def test_restart_on_the_same_cfg_keeps_in_progress_user_edits(wiz):
    usr = _mesh_users(wiz)
    usr._add("inprogress-person", "", ["user"], "")
    same = wiz.cfg
    wiz.restart()
    assert wiz.cfg is same

    advance_to(wiz, wizard_mod.UsersPage)
    assert _names(usr.table, _USERS_COL_NAME) == ["inprogress-person"]
