"""Shared GUI-test helpers — the wizard navigation / selection primitives that were
triplicated across test_wizard.py, test_pages_build.py and test_pages_identity.py.

Consolidated here (design 6) so a flow change is edited in ONE place. These drive the
REAL wizard on Qt's offscreen platform; importing this module pulls in the Qt binding,
so a pure-core test module (e.g. test_worklist.py) must NOT import it — it is for the
GUI test files only, which already `pytest.importorskip("hugmesh_studio.gui.qt")`.

The page-class arguments are resolved against ``hugmesh_studio.gui.wizard`` lazily
(inside each function body, or passed in by the caller), so this module imports cleanly
even before the WorklistPage/ProgressPage classes land in their own workstreams.
"""
from __future__ import annotations

from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS
from hugmesh_studio.gui import wizard as wizard_mod
from hugmesh_studio.gui.qt import Qt


def advance_to(wiz, page_cls):
    """Click Next until an instance of page_cls is current — failing loudly if the flow
    stalls (validatePage rejected) or never routes through the page."""
    for _ in range(len(WIZARD_PAGE_SLUGS) + 1):
        page = wiz.currentPage()
        if isinstance(page, page_cls):
            return page
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, \
            f"flow stuck on {type(page).__name__} (validatePage rejected?)"
    raise AssertionError(f"never reached {page_cls.__name__}")


def back_to(wiz, page_cls):
    """Click Back until an instance of page_cls is current."""
    for _ in range(len(WIZARD_PAGE_SLUGS) + 1):
        page = wiz.currentPage()
        if isinstance(page, page_cls):
            return page
        wiz.back()
    raise AssertionError(f"never reached {page_cls.__name__} going back")


def pick_mode(wiz, mode):
    """Advance to ModePage and check the radio for `mode` (standalone|cloud|mesh)."""
    page = advance_to(wiz, wizard_mod.ModePage)
    idx = [m for m, _, _ in page.modes].index(mode)
    page.group.button(idx).setChecked(True)
    return page


def enable_additional_domains(wiz):
    """Asks 8+19: pick "Add more domains" on the DOMAINS CHOICE screen.

    In MESH mode that card is what makes the Domains table reachable at all
    (DomainsPage.applies_to -> config.superadmin_plane_applies). Ask 19 moved the
    decision off the Network step's checkbox onto its own choice-card screen, so this
    helper now advances to that screen instead. Call it BEFORE advancing to the Domains
    page in a mesh flow; cloud flows do not need it (their Domains/Users steps carry the
    FD-08 --domains tie and are always visited)."""
    page = advance_to(wiz, wizard_mod.DomainsChoicePage)
    page._buttons["more"].setChecked(True)
    return page


def enable_configure_users(wiz):
    """Ask 20: pick "Name superusers and domain users myself" on the USERS CHOICE
    screen — the only thing that makes the mesh Users TABLE reachable
    (UsersPage.applies_to -> config.users_table_applies). The default card keeps the
    accounts gen-provision-keys.sh mints and skips the table."""
    page = advance_to(wiz, wizard_mod.UsersChoicePage)
    page._buttons["table"].setChecked(True)
    return page


def pick_role(wiz, role):
    """Advance to RolePage and select the image-type row whose role id == `role`
    (machine-first: this picks the machine card that supports the role first)."""
    page = advance_to(wiz, wizard_mod.RolePage)
    if not page.select_role(role):
        raise AssertionError(f"role {role} not offered on RolePage")
    return page


def pick_platform(role_page, plat):
    """Select the machine card for `plat` on a RolePage (the machine IS the platform)."""
    if plat not in role_page._machine_buttons:
        raise AssertionError(f"machine card {plat} not present on RolePage")
    role_page.select_machine(plat)


def pairs(args):
    """Adjacent (flag, value) pairs of an argv list — the flag-adjacency helper the
    identity/build tests use to assert `--flag value` ordering."""
    return list(zip(args, args[1:]))


# ---- worklist / progress helpers (new pages; resolved lazily so this module imports
# cleanly before WorklistPage/ProgressPage land) -----------------------------------

def check_worklist_rows(worklist_page, *ids):
    """Check the WorklistPage rows whose stable entry id (``{role}.{platform}``) is in
    `ids`; uncheck all others. Returns the list of ids actually toggled on. The page is
    expected to expose ``row_for_id(id) -> QTreeWidgetItem`` (or ``.rows`` keyed by id);
    both access paths are tried so the helper survives either WorklistPage shape."""
    toggled: list[str] = []
    wanted = set(ids)
    rows = getattr(worklist_page, "rows", None)
    if rows is None and hasattr(worklist_page, "row_for_id"):
        rows = {i: worklist_page.row_for_id(i) for i in wanted}
    assert rows is not None, "WorklistPage exposes neither .rows nor .row_for_id"
    for entry_id, item in rows.items():
        on = entry_id in wanted
        item.setCheckState(0, Qt.CheckState.Checked if on else Qt.CheckState.Unchecked)
        if on:
            toggled.append(entry_id)
    return toggled


def advance_to_progress(wiz):
    """Advance through the (commit) Build page to ProgressPage — the terminal page in
    every mode. ProgressPage is resolved off wizard_mod at call time."""
    return advance_to(wiz, wizard_mod.ProgressPage)
