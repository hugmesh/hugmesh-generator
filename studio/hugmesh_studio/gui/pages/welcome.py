"""WelcomePage — the Studio's first screen: what HugMesh is, plus three ways in.

Issue #50's guided flow starts HERE: an explainer of what this studio builds (with
the GitHub README's getting-started guide one explicit click away) and THREE large
icon buttons — the ChoiceCard idiom ModePage established:

  - START BUILDING        -> ModePage (the full menu of choices, journey-ordered)
  - START A LOCAL MESH    -> LocalMeshPage (the existing local-stack flow: flesh out
                             users/domains locally, start k8s, configure branded
                             repositories)
  - REVIEW PRIOR SESSIONS -> SessionsPage (the previous default first screen: the
                             Previous-builds manager + Load/Save config)

The Load/Save/Fleet buttons and the Previous-builds manager this page used to host
moved wholesale to gui/pages/sessions.py (SessionsPage — the "sessions" slug); the
host-capability intro (:meth:`WelcomePage._intro_html`) stays here because both of
its warnings — no build backend, /mnt/c slow filesystem — are only worth anything
on the FIRST screen (their docstrings say why).

Navigation contract: a fresh start lands here (first WIZARD_PAGE_SLUGS entry, and
nothing else sets a start id), and :meth:`nextId` routes by the selected card. The
default card is START BUILDING, so a plain Next() — every existing wizard-walk
test, and an operator who just presses Enter — flows welcome -> mode exactly as it
always has. Prior-session auto-resume is untouched: RESTART still enters through
``StudioWizard.start_build_from_session``, which jumps straight to "progress".
"""
from __future__ import annotations

import html

from ..choice_cards import ChoiceCard, ChoiceCardGroup
from .. import choice_nav
from ..qt import Qt, QtWidgets
from ..styles import WARN
from ._scroll import scrollable

#: The README's getting-started section ("Quick start"), linked from the explainer.
#: Rendered as a real anchor with ``openExternalLinks=True`` — the click hands the
#: URL to the desktop browser; the Studio itself fetches nothing.
README_GETTING_STARTED = "https://github.com/hugmesh/hugmesh-generator#quick-start"

#: welcome choice id -> the WIZARD_PAGE_SLUGS entry it routes to. The ids are the
#: page's test surface (property("choice")); the slugs are nextId()'s address book.
_CHOICE_TARGET = {"build": "mode", "localmesh": "localmesh", "sessions": "sessions"}

#: choice id -> choice_icons registry name (presentation only). "main-menu" is the
#: same mark LaunchPage's "Back to the main menu" card wears — it IS the same menu.
_CHOICE_ICONS = {"build": "main-menu", "localmesh": "localmesh",
                 "sessions": "sessions"}


def _as_html(text: str) -> str:
    """Plain remedy text -> RichText, escaped and line-broken.

    Both remedies rendered here are multi-line shell/settings recipes containing `<`
    (`wsl --set-version <distro> 2`, `git clone <repo-url> …`). Interpolated raw, Qt's
    RichText engine swallows those as unknown tags — deleting the exact placeholder the
    operator is supposed to substitute — and collapses the newlines that separate the
    commands into one unreadable run-on line.
    """
    return "<br>".join(html.escape(line) for line in text.splitlines())


class WelcomePage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("HugMesh Image Studio")
        self.setSubTitle(
            "Welcome. Start building, run a local mesh on this machine, or review "
            "what you've built before.")
        # three cards + two paragraphs can outgrow a small window: scroll, never clip
        lay = scrollable(self)

        # the hugmesh explainer, with the README getting-started guide one click away
        self.explainer = QtWidgets.QLabel(self._explainer_html())
        self.explainer.setWordWrap(True)
        self.explainer.setTextFormat(Qt.TextFormat.RichText)
        # the anchor hands off to the desktop browser on an EXPLICIT click — the
        # Studio itself fetches nothing (choice_cards.set_link's contract, restated)
        self.explainer.setOpenExternalLinks(True)
        lay.addWidget(self.explainer)

        info = QtWidgets.QLabel(self._intro_html())
        info.setWordWrap(True)
        info.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(info)

        # THREE large icon buttons (issue #50 item 1) — one clickable CARD each,
        # the exact ModePage idiom: title + muted description left, drawn-in-code
        # icon right, click == choose == proceed (choice_nav).
        self.group = ChoiceCardGroup(self)
        self.choices = [
            ("build", "Start building",
             "Open the menu of choices — build a mesh node, run a local Docker "
             "mesh, build a desktop image, enroll MDM devices, publish to a cloud, "
             "or boot built images as emulated QEMU devices."),
            ("localmesh", "Start a local mesh",
             "Flesh out users and domains locally, start the Kubernetes stack, and "
             "configure branded repositories — a whole mesh on THIS machine in "
             "Docker, no server hardware."),
            ("sessions", "Review prior sessions",
             "Previous builds and saved configurations: restart or redo a session, "
             "open its artifacts, read its logs — or load/save a config file."),
        ]
        self._buttons = {}
        for i, (cid, label, desc) in enumerate(self.choices):
            card = ChoiceCard(label, desc, icon_name=_CHOICE_ICONS.get(cid, ""))
            card.setProperty("choice", cid)
            self.group.add_card(card, i)          # button id == index in self.choices
            self._buttons[cid] = card
            lay.addWidget(card)
        # DEFAULT is "build" BY ID: a plain Next (or Enter) keeps the historical
        # welcome -> mode flow, so every established walk-through keeps its path.
        self._buttons["build"].setChecked(True)
        self.group.buttonToggled.connect(lambda *_: self.completeChanged.emit())
        # ASK 14 (ModePage precedent): a CLICK on a card commits this page and moves
        # on — wired to buttonClicked, never buttonToggled, so a setChecked from a
        # test or Back-navigation restore can never navigate on its own.
        choice_nav.advance_on_choice(self, self.group)
        lay.addStretch(1)

    # ── the explainer ────────────────────────────────────────────────────────────
    def _explainer_html(self) -> str:
        """What HugMesh is, in one paragraph, with the getting-started link.

        Pure method (returns HTML, touches no widget) so a headless test can assert
        the link target without rendering."""
        return (
            "<b>HugMesh</b> is a self-hosted mesh: a small cluster of nodes "
            "(Raspberry Pi and x86) that serves chat, social, storage and "
            "single-sign-on for your people, plus branded desktop clients that join "
            "it. This studio assembles every piece — from a local trial mesh in "
            "Docker to production node images you flash onto real hardware.<br>"
            f'New here? Read the <a href="{README_GETTING_STARTED}">getting-started '
            "guide</a> (the GitHub README).")

    def _intro_html(self) -> str:
        """The intro paragraph, keyed on whether this machine can actually build.

        Pure method (returns HTML, touches no widget) so a headless test can assert the
        no-backend guidance appears WITHOUT a Docker/Gentoo host. When the host has no
        build backend, ``default_backend`` is "none" — the old page cheerfully printed
        "Backend: none" and the user only hit the wall at Build time; now it says so
        up-front and how to fix it."""
        host = self.wiz.host
        if host.default_backend == "none":
            return (
                "This studio assembles and runs a HugMesh image build.<br><br>"
                f'<b style="color:{WARN}">This machine can\'t build images yet.</b> '
                # Under WSL the generic "install Docker Desktop" line is not the fix —
                # Docker Desktop is typically already installed and running on the
                # Windows side, and simply not shared with THIS distro. docker_remedy()
                # names that checkbox; without it the operator reinstalls a working app.
                + (_as_html(host.docker_remedy()) if host.is_wsl else
                   "Install Docker Desktop on Windows or macOS (and start it), or run "
                   "Studio on a Gentoo host to build natively.")
                + " You can still configure and "
                "save an image now, then build it on a machine that can.<br><br>"
                f"{self._slow_fs_html()}"
                f"Detected: {host.summary()}")
        return (
            "This studio assembles and runs a HugMesh image build.<br><br>"
            f"Build backend: <b>{host.default_backend}</b> ({host.summary()})<br><br>"
            f"{self._slow_fs_html()}"
            "On Gentoo it builds natively; everywhere else (including Windows) it drives "
            "the dockerized build.")

    def _slow_fs_html(self) -> str:
        """The /mnt/c trap, on the FIRST screen — or "" when the repo is on a local disk.

        Said here as well as in the build preflight deliberately. By the time preflight
        runs the operator has configured a whole image and is one click from a build
        they will interpret as hung; the cheap fix (re-clone into ~) is one they will
        only take before they have invested that time. Backend-independent, so it is not
        folded into either branch above.
        """
        warning = self.wiz.host.slow_filesystem_warning(self.wiz.generator_dir)
        if not warning:
            return ""
        return (f'<b style="color:{WARN}">{_as_html(warning)}</b><br><br>')

    # ── selection / flow ─────────────────────────────────────────────────────────
    def _selected_choice(self):
        btn = self.group.checkedButton()
        return btn.property("choice") if btn is not None else None

    def isComplete(self):
        # "build" is pre-checked, so a fresh page is complete — Next never greys out
        # on the first screen; the guard only matters if a subclass unchecks all.
        return self._selected_choice() is not None

    def validatePage(self):
        # Entering the local-stack flow DIRECTLY (without walking ModePage):
        # LocalMeshPage.applies_to reads this transient wizard flag, exactly as it
        # does for ModePage's "Local Docker mesh" card — never persisted into cfg
        # (cfg.mode stays an image mode; ModePage.initializePage documents why).
        # ModePage.validatePage re-derives the flag on its own commit, so a Back
        # here followed by a different path can never strand a stale True.
        self.wiz.localmesh_selected = (self._selected_choice() == "localmesh")
        return True

    def nextId(self):
        """Route by the selected card: build -> mode, localmesh -> the local-stack
        flow, sessions -> the Previous-builds screen. Falls back to the positional
        next page until the wizard's slug->id map exists (construction order)."""
        ids = getattr(self.wiz, "_page_ids", None)
        if not ids:
            return super().nextId()
        slug = _CHOICE_TARGET.get(self._selected_choice() or "build", "mode")
        return ids[slug]
