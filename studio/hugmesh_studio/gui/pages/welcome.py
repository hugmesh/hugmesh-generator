"""WelcomePage — the Studio's first screen: what HugMesh is, plus two ways in.

Issue #50's guided flow starts HERE: an explainer of what this studio builds (with
the GitHub README's getting-started guide one explicit click away) and TWO large
icon buttons — the ChoiceCard idiom ModePage established:

  - START BUILDING        -> ModePage (the full menu of choices, journey-ordered)
  - REVIEW PRIOR SESSIONS -> SessionsPage (the previous default first screen: the
                             Previous-builds manager + Load/Save config)

THE THIRD CARD IS GONE (operator report, 2026-08-26: "standalone menu is asking same
questions seemingly multiple times"). "Start a local mesh" and ModePage's "Local
Docker mesh" were ONE destination offered on two consecutive screens — both raised
``wiz.localmesh_selected`` and both landed on LocalMeshPage — and this page's own
"Start building" text enumerates ModePage's cards, so screen 1 was a menu OF screen
2. ModePage owns that choice now, beside the six other side-flows it already carries
(localcloud, qemu, meshemu, deploy, phone, quest); one extra click reaches it, and
there is one place where "what am I building?" is answered. "Review prior sessions"
stays: SessionsPage is NOT a ModePage card, so it is a genuine second door.

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
#: No "localmesh" entry any more — that door is ModePage's alone (see the module
#: docstring); leaving a target for a card nobody can pick would be an unreachable
#: branch in nextId().
_CHOICE_TARGET = {"build": "mode", "sessions": "sessions"}

#: choice id -> choice_icons registry name (presentation only). "main-menu" is the
#: same mark LaunchPage's "Back to the main menu" card wears — it IS the same menu.
_CHOICE_ICONS = {"build": "main-menu", "sessions": "sessions"}


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
            "Welcome. Start building, or review what you've built before.")
        # the cards + two paragraphs can outgrow a small window: scroll, never clip
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

        # TWO large icon buttons (issue #50 item 1, minus the duplicate local-mesh
        # card) — one clickable CARD each, the exact ModePage idiom: title + muted
        # description left, drawn-in-code icon right, click == choose == proceed
        # (choice_nav).
        self.group = ChoiceCardGroup(self)
        self.choices = [
            ("build", "Start building",
             "Open the menu of choices — build a mesh node, run a local Docker "
             "mesh, build a desktop image, enroll MDM devices, publish to a cloud, "
             "or boot built images as emulated QEMU devices."),
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
        # This page no longer OFFERS the local-stack flow (see the module docstring) —
        # but it still CLEARS the transient flag, and that line is load-bearing rather
        # than tidy-up: LocalMeshPage.applies_to reads it, and an operator who took
        # ModePage's "Local Docker mesh" card and then stepped Back to this screen would
        # otherwise walk forward through a stale True. Written as a constant False, not
        # as a comparison against a choice id nothing can select, so no unreachable
        # branch is left behind. ModePage.validatePage re-derives it on its own commit.
        self.wiz.localmesh_selected = False
        return True

    def nextId(self):
        """Route by the selected card: build -> mode, sessions -> the Previous-builds
        screen. Falls back to the positional next page until the wizard's slug->id map
        exists (construction order). An unknown/absent choice resolves to "mode", which
        is also what the default card selects."""
        ids = getattr(self.wiz, "_page_ids", None)
        if not ids:
            return super().nextId()
        slug = _CHOICE_TARGET.get(self._selected_choice() or "build", "mode")
        return ids[slug]
