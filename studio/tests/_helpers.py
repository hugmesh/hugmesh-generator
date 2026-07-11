"""Shared GUI-test helpers — the wizard navigation / selection primitives that were
triplicated across test_wizard.py, test_pages_build.py and test_pages_identity.py.

Consolidated here (design 6) so a flow change is edited in ONE place. These drive the
REAL wizard on Qt's offscreen platform; importing this module pulls in the Qt binding,
so a pure-core test module (e.g. test_worklist.py) must NOT import it — it is for the
GUI test files only, which already `pytest.importorskip("snapdragon_studio.gui.qt")`.

The page-class arguments are resolved against ``snapdragon_studio.gui.wizard`` lazily
(inside each function body, or passed in by the caller), so this module imports cleanly
even before the WorklistPage/ProgressPage classes land in their own workstreams.
"""
from __future__ import annotations

from snapdragon_studio.core.config import WIZARD_PAGE_SLUGS
from snapdragon_studio.gui import wizard as wizard_mod
from snapdragon_studio.gui.qt import Qt


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


def pick_role(wiz, role):
    """Advance to RolePage and select the list item whose role id == `role`."""
    page = advance_to(wiz, wizard_mod.RolePage)
    for i in range(page.roles.count()):
        it = page.roles.item(i)
        if it.data(Qt.ItemDataRole.UserRole)[0] == role:
            page.roles.setCurrentItem(it)
            return page
    raise AssertionError(f"role {role} not offered on RolePage")


def pick_platform(role_page, plat):
    """Select `plat` in a RolePage's platform combo (the role must offer it)."""
    for i in range(role_page.platform.count()):
        if role_page.platform.itemData(i) == plat:
            role_page.platform.setCurrentIndex(i)
            return
    raise AssertionError(f"platform {plat} not offered for this role")


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
