"""The Snapdragon Image Studio wizard — a Calamares-style page-based flow that surfaces
the WHOLE build flag surface (mode, hardware, branding, network/SSO, admin key-zip,
superadmin domains+users, home, build) and runs the build natively or via Docker.

The page classes live in gui/pages/ (one module per WIZARD_PAGE_SLUGS entry — the
golive.py precedent); this module keeps only the page registry, the mode-gated
nextId() flow, and collect_all().
"""
from __future__ import annotations

import os

from .qt import BINDING, QtCore, QtGui, QtWidgets
from .branding_icon import brand_icon
from .. import __version__
from ..core.build_driver import BuildDriver
from ..core.config import ImageConfig, MODE_SKIPPED_PAGES, WIZARD_PAGE_SLUGS
from ..core.platform_info import detect
from ..core import worklist as worklist_mod
from .pages import (
    BrandingPage, BuildPage, DeployPage, DomainsPage, HardwarePage, HomePage,
    KeyZipPage, LocalMeshPage, ModePage, NetworkPage, PhonePage, ProgressPage,
    RolePage, SystemPage, UsersPage, WelcomePage, WorklistPage,
)
# re-exported for golive.py (and any other page set) — the helpers moved to
# gui/pages/_widgets.py with the page split, but this module stays their
# established import path.
from .pages._widgets import _file_picker, _row  # noqa: F401

__all__ = [
    "StudioWizard", "medium_size", "centred_top_left",
    "WelcomePage", "ModePage", "LocalMeshPage", "PhonePage", "DeployPage",
    "RolePage", "WorklistPage", "HardwarePage",
    "BrandingPage", "NetworkPage", "KeyZipPage", "DomainsPage", "UsersPage",
    "SystemPage", "HomePage", "BuildPage", "ProgressPage",
]

# The wizard's ONE size, for every page (the "medium" — pages used to jump between
# 1040x780 and 1431x780 as you walked them). 1040x780 is deliberately the size the
# terminal ProgressPage used to ratchet itself up to for build-log readability: it is
# the largest any page genuinely wanted, so adopting it as the default makes that
# ratchet redundant (it was removed) and every page settles on one size.
#
# _MARGIN keeps the window off the screen edges on small displays. Clamping to the
# REAL screen is the point: the old ratchet resized to a hardcoded 1040x780 with no
# regard for the display, so an 800x800 screen got a window larger than itself.
_PREFERRED = (1040, 780)
_MARGIN = 0.92


def medium_size(avail) -> "QtCore.QSize":
    """The wizard's default size for an available screen rect — the preferred size
    clamped to fit ``avail`` (QGuiApplication.primaryScreen().availableGeometry()).

    Pure function of the rect (no display needed) so the clamp is directly testable
    against screens the test host does not have. Measured: 1080p/1440p -> 1040x780,
    768p laptop -> 1040x706, 1024x600 netbook -> 942x552, 800x800 -> 736x736 — all
    of which clear every page's minimumSizeHint (widest: WorklistPage at 518, tallest:
    ProgressPage at 401)."""
    w, h = _PREFERRED
    return QtCore.QSize(min(w, int(avail.width() * _MARGIN)),
                        min(h, int(avail.height() * _MARGIN)))


def centred_top_left(frame, avail) -> "QtCore.QPoint":
    """Where to move a window whose frame rect is ``frame`` to centre it on ``avail``.

    Pure function of the two rects, for the same reason medium_size() is one — but
    here testability is the WHOLE point rather than a bonus. QWizard is a QDialog, and
    Qt's QDialog::adjustPosition already auto-centres a parentless dialog on show, so a
    test that merely shows the wizard and measures its centre passes even with all of
    our centring deleted (verified: a bare QWizard lands dead-centre, 0px error). Only
    a test that drives this arithmetic over screens the host does not have can actually
    fail when the centring is wrong, so the arithmetic lives here in the open.

    The move() that consumes this is still load-bearing beyond the centring itself: it
    sets Qt's explicit-position flag, which is what stops adjustPosition re-centring the
    window over a position the user dragged it to (see showEvent)."""
    fg = QtCore.QRect(frame)
    fg.moveCenter(avail.center())
    return fg.topLeft()


def _available_geometry():
    """The primary screen's available rect, or a 1080p stand-in when there is no
    screen at all (never crash the constructor on a headless import)."""
    screen = QtGui.QGuiApplication.primaryScreen()
    if screen is None:                       # pragma: no cover - needs a screenless Qt
        return QtCore.QRect(0, 0, 1920, 1080)
    return screen.availableGeometry()


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
        # transient: ModePage's LOCAL DOCKER MESH choice — read by
        # LocalMeshPage.applies_to(), NEVER persisted into cfg (cfg.mode stays an
        # image mode; ModePage.initializePage documents why).
        self.localmesh_selected = False
        # transient: ModePage's MDM PHONE choice — read by PhonePage.applies_to(),
        # likewise NEVER persisted into cfg (the phone is not an image mode).
        self.phone_selected = False
        # transient: ModePage's CLOUD DEPLOY choice — read by DeployPage.applies_to(),
        # likewise NEVER persisted into cfg (a deploy is not an image mode).
        self.deploy_selected = False
        # The build-session id of the NEXT dispatch (core/build_sessions): minted lazily
        # by BuildPage's preview (so preview == dispatch), pinned by a RESTART (same
        # record + workdir reused), cleared by ProgressPage at finish.
        self.pending_session_id = None
        # graphical=True: a build reached from the GUI must elevate through a password
        # DIALOG (sudo -A askpass / pkexec), never a sudo prompt on an invisible terminal.
        self.driver = BuildDriver(self.generator_dir, self.host, graphical=True)
        self.setWindowTitle("Snapdragon Image Studio")
        self.setWindowIcon(brand_icon())
        self.setWizardStyle(QtWidgets.QWizard.WizardStyle.ModernStyle)
        # A user-facing About surface (name / version / license): the Qt binding used to
        # be dumped to stdout as dev noise. QWizard's Help button is the natural, always-
        # visible home for it in this page flow.
        self.setOption(QtWidgets.QWizard.WizardOption.HaveHelpButton, True)
        self.setButtonText(QtWidgets.QWizard.WizardButton.HelpButton, "About")
        self.helpRequested.connect(self._show_about)
        # ONE size for the whole flow, clamped to the real screen (see medium_size).
        # resize(), not setFixedSize() — the user stays free to resize; a page taller
        # than the window SCROLLS (pages/_scroll.py), it does not grow the window.
        # Nothing is persisted: no QSettings, so the wizard remembers no geometry.
        self.resize(medium_size(_available_geometry()))
        self._centred_once = False
        # One page-constructor per WIZARD_PAGE_SLUGS entry, SAME order — nextId() keys the
        # mode-gated skip set (MODE_SKIPPED_PAGES) by slug, so drift here would silently
        # skip the WRONG page. ProgressPage lands in WS-REVIEWUI (gui/pages/progress.py);
        # until then it is None and the flow terminates on BuildPage — the None-filter
        # keeps the slug->id map aligned and the drift assert fail-loud.
        page_ctors = [
            WelcomePage, ModePage, LocalMeshPage, PhonePage, DeployPage, RolePage,
            WorklistPage,
            HardwarePage, BrandingPage, NetworkPage, KeyZipPage, DomainsPage, UsersPage,
            SystemPage, HomePage, BuildPage, ProgressPage,
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

    def _about_text(self) -> str:
        """The About-box body: name, version and the runtime Qt license note. Kept as a
        pure method (no dialog) so a headless test can assert the version + the license
        keyed on the ACTUAL binding without popping a modal."""
        # PySide6 ships under the LGPL, PyQt6 under the GPL — which one is live is a
        # runtime fact (qt.py BINDING), so the disclosure must follow it.
        licence = ("PySide6 (LGPL v3)" if BINDING == "PySide6"
                   else "PyQt6 (GPL v3)" if BINDING == "PyQt6"
                   else BINDING or "unknown")
        return (
            f"<b>Snapdragon Image Studio</b><br>"
            f"Version {__version__}<br><br>"
            "Assemble and run a Snapdragon image build — a mesh server node, a local "
            "Docker mesh, a mesh desktop client, or a standalone Gentoo desktop.<br><br>"
            f"Qt binding: {licence}")

    def _show_about(self):
        QtWidgets.QMessageBox.about(self, "About Snapdragon Image Studio", self._about_text())

    def showEvent(self, event):
        """Centre on the primary screen the FIRST time the wizard is shown.

        One-shot: re-centring on every show would yank the window back from wherever
        the user dragged it (show/hide happens around dialogs and restart()), and the
        move() below is what pins that — it sets Qt's explicit-position flag, which
        stops QDialog::adjustPosition (QWizard IS a QDialog) re-centring on later shows.

        Centres frameGeometry() rather than geometry() so the window MANAGER's frame is
        included WHERE THE PLATFORM HAS ALREADY APPLIED ONE. On X11/Wayland it usually
        has not by the first showEvent, so frameGeometry() == geometry() and this
        degrades to client-area centring — off-centre by about half a title bar, which
        is why the tests allow a few px of slack. Exact frame centring would need to be
        deferred to the first resize/singleShot(0); not worth the flicker for ~15px."""
        super().showEvent(event)
        if self._centred_once:
            return
        self._centred_once = True
        self.move(centred_top_left(self.frameGeometry(), _available_geometry()))

    def nextId(self):
        """Mode-gated page flow: pages that do not apply to the selected Studio mode
        (MODE_SKIPPED_PAGES — e.g. the admin key-zip and the superadmin domains/users
        tables on a standalone build) are skipped, so standalone → unaffiliated is
        the shortest path. Qt calls this AFTER the current page's validatePage(), so
        cfg.mode is already committed when the flow is decided; a skipped page is
        never visited, and collect_all() only reads visited pages.

        Beyond the static MODE_SKIPPED_PAGES set, a page may opt into DYNAMIC skipping
        by implementing ``applies_to(cfg) -> bool`` (default True): a page that renders
        all-inapplicable for the committed config is skipped too. The ALL-OPTIONS guard
        is the page's own responsibility — applies_to() may return False ONLY when every
        config field the page emits is already at the mode-correct default (so skipping
        it changes no argv; collect_all reads only visited pages). The terminal
        build/progress pages are never dynamically skipped."""
        nid = super().nextId()
        skipped = {self._page_ids[s] for s in MODE_SKIPPED_PAGES[self.cfg.mode]}
        terminal = {self._page_ids[s] for s in ("build", "progress") if s in self._page_ids}
        ids = self.pageIds()
        while nid in skipped or self._dynamically_skipped(nid, terminal):
            i = ids.index(nid)
            nid = ids[i + 1] if i + 1 < len(ids) else -1
        return nid

    def _dynamically_skipped(self, nid, terminal) -> bool:
        """True when page ``nid`` is a non-terminal page whose ``applies_to(cfg)`` reports
        it contributes nothing for the committed config (emission-neutral skip)."""
        if nid < 0 or nid in terminal:
            return False
        page = self.page(nid)
        applies = getattr(page, "applies_to", None)
        if applies is None:
            return False
        try:
            return not applies(self.cfg)
        except Exception:
            return False        # never let a predicate bug strand the flow

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

    def load_session(self, data):
        """REDO ("edit as new"): load a session record's config snapshot — the full
        worklist envelope dict — back into the wizard. Exactly load_config minus the
        file read; the user lands on Welcome with every page pre-populated and walks
        the config pages to edit. The eventual Build mints a FRESH session id/workdir
        (pending_session_id is cleared here)."""
        wl = worklist_mod.WorklistConfig.from_dict(data)
        self.cfg = wl.base
        self.worklist = wl
        self.pending_session_id = None
        self.restart()

    def start_build_from_session(self, session, resume=False):
        """RESTART: re-dispatch a session's exact recorded config into the SAME
        per-session workdir. Restores the recorded dispatch params (backend /
        generate-keys), optionally sets --resume on the base config (the builders'
        documented reuse-the-build-tree flag — a user-chosen runtime option), pins
        pending_session_id = session.id so ProgressPage reuses the record + workdir
        (status back to running, restarts incremented, prior outcome archived), and
        jumps straight to the terminal progress page. Safe without extra guards:
        ProgressPage.initializePage re-runs the full preflight and refuses to launch
        on failure (the existing direct/back-nav defence)."""
        wl = worklist_mod.WorklistConfig.from_dict(session.config)
        # Explicitly assign (not merely raise) the flag: a prior resume-restart
        # re-snapshots resume=true into the persisted record, so an UNCHECKED box
        # must actively clear it or --resume ratchets on for every later restart.
        wl.base.resume = bool(resume)
        self.cfg = wl.base
        self.worklist = wl
        self.build_backend = session.backend
        self.generate_node_keys = session.generate_keys
        self.pending_session_id = session.id
        self.setStartId(self._page_ids["progress"])
        try:
            self.restart()
        finally:
            self.setStartId(-1)      # restore the normal first page for later flows

    def save_config(self, path):
        """Persist the current config, blanking plaintext secrets (returns the aggregated
        per-secret warning list). A worklist writes the `snapdragon-worklist/v1` envelope;
        a plain (standalone/cloud) config writes the flat JSON byte-identically (I1)."""
        self.collect_all()
        if self.worklist is not None:
            return self.worklist.save(path)
        return self.cfg.save(path)
