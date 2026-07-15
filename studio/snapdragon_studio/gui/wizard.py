"""The Snapdragon Image Studio wizard — a Calamares-style page-based flow that surfaces
the WHOLE build flag surface (mode, hardware, branding, network/SSO, admin key-zip,
superadmin domains+users, home, build) and runs the build natively or via Docker.

The page classes live in gui/pages/ (one module per WIZARD_PAGE_SLUGS entry — the
golive.py precedent); this module keeps only the page registry, the mode-gated
nextId() flow, and collect_all().
"""
from __future__ import annotations

import os

from .qt import QtWidgets
from ..core.build_driver import BuildDriver
from ..core.config import ImageConfig, MODE_SKIPPED_PAGES, WIZARD_PAGE_SLUGS
from ..core.platform_info import detect
from ..core import worklist as worklist_mod
from .pages import (
    BrandingPage, BuildPage, DomainsPage, HardwarePage, HomePage, KeyZipPage,
    ModePage, NetworkPage, ProgressPage, RolePage, SystemPage, UsersPage,
    WelcomePage, WorklistPage,
)
# re-exported for golive.py (and any other page set) — the helpers moved to
# gui/pages/_widgets.py with the page split, but this module stays their
# established import path.
from .pages._widgets import _file_picker, _row  # noqa: F401

__all__ = [
    "StudioWizard",
    "WelcomePage", "ModePage", "RolePage", "WorklistPage", "HardwarePage",
    "BrandingPage", "NetworkPage", "KeyZipPage", "DomainsPage", "UsersPage",
    "SystemPage", "HomePage", "BuildPage", "ProgressPage",
]


class StudioWizard(QtWidgets.QWizard):
    def __init__(self, generator_dir, parent=None,
                 remember_roles_for_passwordless_login=False, login_manifest_path=None):
        super().__init__(parent)
        self.generator_dir = os.path.abspath(generator_dir)
        self.host = detect()
        self.cfg = ImageConfig()
        # Studio-local preference (NOT part of ImageConfig — it describes a
        # side-effect of running Studio itself, not the built image's runtime).
        # See KeyZipPage / core.keyzip.emit_passwordless_login_roles().
        self.remember_roles_for_passwordless_login = remember_roles_for_passwordless_login
        self.login_manifest_path = login_manifest_path
        # The active worklist envelope (mesh: the WorklistPage builds it; standalone/cloud:
        # BuildPage synthesizes a 1-entry worklist at Build time). None until a page sets it.
        self.worklist = None
        # graphical=True: a build reached from the GUI must elevate through a password
        # DIALOG (sudo -A askpass / pkexec), never a sudo prompt on an invisible terminal.
        self.driver = BuildDriver(self.generator_dir, self.host, graphical=True)
        self.setWindowTitle("Snapdragon Image Studio")
        self.setWizardStyle(QtWidgets.QWizard.WizardStyle.ModernStyle)
        self.resize(820, 640)
        # One page-constructor per WIZARD_PAGE_SLUGS entry, SAME order — nextId() keys the
        # mode-gated skip set (MODE_SKIPPED_PAGES) by slug, so drift here would silently
        # skip the WRONG page. ProgressPage lands in WS-REVIEWUI (gui/pages/progress.py);
        # until then it is None and the flow terminates on BuildPage — the None-filter
        # keeps the slug->id map aligned and the drift assert fail-loud.
        page_ctors = [
            WelcomePage, ModePage, RolePage, WorklistPage, HardwarePage, BrandingPage,
            NetworkPage, KeyZipPage, DomainsPage, UsersPage, SystemPage, HomePage,
            BuildPage, ProgressPage,
        ]
        assert len(page_ctors) == len(WIZARD_PAGE_SLUGS), (
            f"page constructors ({len(page_ctors)}) drifted from "
            f"WIZARD_PAGE_SLUGS ({len(WIZARD_PAGE_SLUGS)})")
        present = [(slug, ctor) for slug, ctor in zip(WIZARD_PAGE_SLUGS, page_ctors)
                   if ctor is not None]
        self._pages = [ctor(self) for _slug, ctor in present]
        for p in self._pages:
            self.addPage(p)
        self._page_ids = dict(zip([slug for slug, _ctor in present], self.pageIds()))

    def nextId(self):
        """Mode-gated page flow: pages that do not apply to the selected Studio mode
        (MODE_SKIPPED_PAGES — e.g. the admin key-zip and the superadmin domains/users
        tables on a standalone build) are skipped, so standalone → unaffiliated is
        the shortest path. Qt calls this AFTER the current page's validatePage(), so
        cfg.mode is already committed when the flow is decided; a skipped page is
        never visited, and collect_all() only reads visited pages."""
        nid = super().nextId()
        skipped = {self._page_ids[s] for s in MODE_SKIPPED_PAGES[self.cfg.mode]}
        ids = self.pageIds()
        while nid in skipped:
            i = ids.index(nid)
            nid = ids[i + 1] if i + 1 < len(ids) else -1
        return nid

    def collect_all(self):
        """Pull values out of every VISITED page into self.cfg. Only visited pages are
        collected — an unvisited page's widgets hold construction defaults, so collecting
        them would wipe loaded/earlier values (this also lets Domains/Users be collected,
        which the old blanket exclusion silently dropped on save + the mesh build path)."""
        for pid in self.pageIds():
            if not self.hasVisitedPage(pid):
                continue
            p = self.page(pid)
            if hasattr(p, "validatePage"):
                try:
                    p.validatePage()
                except Exception:
                    pass

    def load_config(self, path):
        """Load EITHER a flat single-image config OR a worklist envelope through the one
        loader both UIs share (worklist.load_any). A flat config keeps loading
        byte-identically (the envelope is discriminated by an explicit `schema` key);
        an envelope restores self.worklist so the mesh flow re-populates. restart() so
        each page's initializePage() re-reads the freshly loaded config."""
        base, wl = worklist_mod.load_any(path)
        self.cfg = base
        self.worklist = wl
        self.restart()

    def save_config(self, path):
        """Persist the current config, blanking plaintext secrets (returns the aggregated
        per-secret warning list). A worklist writes the `snapdragon-worklist/v1` envelope;
        a plain (standalone/cloud) config writes the flat JSON byte-identically (I1)."""
        self.collect_all()
        if self.worklist is not None:
            return self.worklist.save(path)
        return self.cfg.save(path)
