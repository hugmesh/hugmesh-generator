"""BrandingPage — TWO branding surfaces with opposite scopes:

* DESKTOP assets (premade theme XOR custom boot/login/wallpaper/GRUB/accent, plus
  the brand logo and the brand lock): x86-only emission, greys+clears on node images
  (``branding_allowed`` / ``_desktop_half_allowed``). In MESH mode the half is live
  whenever the worklist carries a desktop-class x86 entry — the theme rides the
  shared cfg and materialize()'s per-entry clear keeps it off every node image
  (operator ask 2026-08-14; supersedes spec 2's never-in-mesh). The premade picker
  and the eight custom fields are an exclusive either/or so the two branding
  channels can never fight.
* The WEB LOGIN THEME (colours/fonts for the login page the MESH serves to
  browsers): NON-argv mesh-plane fields (config NON_ARGV_FIELDS), deliberately
  OUTSIDE the desktop gating — mesh mode visits this page exactly FOR this half,
  and greying it there would gate the knob off on the only plane that renders it.
  SHOWN ONLY IN MESH since 2026-08-26: a standalone/cloud desktop serves no
  login-ui (the page's own applies_to docstring already conceded this), so the
  section themed nothing there while still persisting its login_* keys into that
  image's saved config. The COMMIT stays unconditional, so a mesh config survives a
  stray visit unharmed. It is also retitled "Web login theme": the DESKTOP cards
  live under a "Desktop theme" header while the thing literally titled "Themes" was
  the web one, which is the ambiguity behind the operator's "the menu for adding the
  themes".

IDENTITY vs LOOK on an UNAFFILIATED image (operator decision, 2026-08-26). This page
used to delete itself wholesale for ``standalone-unaffiliated`` / the composable
``--unaffiliated`` flag — which is exactly what the operator's report is about:
"There should be the menu for adding the themes as in the branded images". A BRAND is
an affiliation; a WALLPAPER is not. The two halves are now gated separately:

  * IDENTITY stays FORBIDDEN — ``--brand`` / ``--brand-title`` / ``--org`` (the
    NetworkPage plane) plus this page's ``--brand-logo`` and ``--brand-locked``. Both
    widgets are HIDDEN here and cleared in ``validatePage``;
    ``ImageConfig._check_unaffiliated_conflicts`` and build-x86-host-stage4.sh keep
    hard-erroring on them, so the wizard cannot hand over a config they reject.
  * LOOK is OFFERED — the four premade themes and the neutral custom assets
    (branding dir, wallpaper, GRUB background, GRUB theme dir, login background,
    accent colour, colour scheme). The builder bakes them under NEUTRAL names on this
    role, the way the home/installer/media machinery already does.

ASK 6 — "redo entire branding section as well and remove existing themes and leave a
light and a dark, a purple, and a grey theme selectable". What changed and why:

1. **The premade/custom choice is now two CHOICE CARDS**, not two bare radio buttons.
   It is the page's top-level fork — which of two mutually exclusive branding channels
   you are using — and it was rendered smaller and quieter than the eight file pickers
   underneath it. The #507 card idiom gives the fork the weight it carries.
2. **The theme is picked from CARDS WITH A PREVIEW SWATCH** (``_themecards``), not a
   ``QComboBox``. A theme is a look; a combo could only show the word.
3. **The offered set is closed and asserted** — exactly ``core.branding_themes``'
   four. The old page listed the theme directories AND THEN APPENDED THE BRAND NAME
   plus any loaded value, so it offered names with no directory behind them: on a
   stock checkout the combo carried ``hugmesh``, the BRAND, as if it were a theme.
   Choosing it emitted
   ``--theme hugmesh`` into a builder whose resolver hard-errors
   ``unknown --theme 'hugmesh'``: the wizard could hand you a build that cannot start.
   Nothing is appended now. A saved config naming an unknown theme is CLEARED with a
   visible note, and a GUI/disk set mismatch is reported in the page rather than
   raised (under PyQt6 an exception escaping a slot calls ``qFatal``).
4. The custom-branding channel is byte-for-byte the same eight fields, the same
   either/or blanking, the same both-set reconciliation and the same gating as before.
"""
from __future__ import annotations

from ..qt import QtWidgets
from ..choice_cards import ChoiceCard, ChoiceCardGroup
from ...core import plain_words
from ...tui.superbrand_step import session_for
from ...core.branding_themes import theme_set_problem
from ...core.config import (
    UNAFFILIATED_ROLE, branding_allowed, image_class, unaffiliated_image,
)
from ._gating import (
    clear_unsupported, gate_widgets_role_class, platform_supports, unsupported_note,
)
from ._logintheme import LoginThemeGroup
from ._scroll import scrollable
from .superbrand import SuperbrandStep
from ._themecards import (
    NO_THEME, CustomAssetsSwatch, ThemeCardGroup, ThemeStripSwatch,
)
from ._widgets import _file_picker, _row, collapsible

# every widget-backed field on this page — all x86-only emission, so the whole
# form greys as one unit off-x86 (G10) and clears on Next.
_BRANDING_FIELDS = ("theme", "branding_dir", "wallpaper", "grub_background",
                    "grub_theme", "login_background", "brand_logo", "accent_color",
                    "color_scheme", "brand_locked")
# The eight custom-value fields (spec 2): everything in THEME_FIELDS except the
# premade ``theme`` (the preset card's picker) and ``brand_locked`` (which stays
# OUTSIDE the either/or — a lock applies to whichever branding channel is chosen).
# Selecting "Premade theme" blanks these; selecting "Custom branding" blanks theme.
_CUSTOM_FIELDS = ("branding_dir", "wallpaper", "grub_background", "grub_theme",
                  "login_background", "brand_logo", "color_scheme", "accent_color")

# The two IDENTITY widgets on this page. Hidden + cleared on an unaffiliated image
# (decision 2026-08-26 "split identity from look"): a logo and a managed-image lock
# are a brand's marks, and both remain builder hard conflicts there
# (config._check_unaffiliated_conflicts' `assets` list; build-x86-host-stage4.sh's
# unaffiliated err). Everything else this page owns is a LOOK and stays offered.
_IDENTITY_FIELDS = ("brand_logo", "brand_locked")

_UNAFFILIATED_NOTE = (
    "Unaffiliated build: no brand IDENTITY is baked — no brand name, no logo, no "
    "branding lock (the builder hard-errors on those). The LOOK is yours: pick a "
    "premade theme or supply your own wallpaper, boot screen, greeter and colours. "
    "They are baked under neutral names, with no HugMesh marks.")

_IDENTITY_HIDDEN_REASON = (
    "A brand logo and a managed-image branding lock are brand IDENTITY, which an "
    "unaffiliated image has none of — build-x86-host-stage4.sh exits 1 on either "
    "flag for this role. The rest of the look (themes, wallpaper, GRUB, greeter, "
    "colours) is offered. Cleared when you leave the page.")

# The page's own subtitle, per plane. The web-login half only exists in mesh, so the
# non-mesh flows must not advertise it (initializePage swaps them).
_SUBTITLE_IMAGE = ("Desktop branding for this image: a premade theme, or your own "
                   "wallpaper, boot screen, greeter and colours.")
_SUBTITLE_MESH = ("Desktop branding for the desktop images in this worklist, plus the "
                  "look of the login page this mesh serves to browsers.")

_DESKTOP_HDR = (
    "<b>Desktop theme</b> — baked into the IMAGE itself: wallpaper, GRUB boot "
    "screen, login greeter, colours.")
_DESKTOP_HDR_MESH = _DESKTOP_HDR[:-1] + (
    ". (The web login page this mesh serves to browsers is themed separately, "
    "below.)")

_ROLE_CLASS_REASON = (
    "Desktop theming applies to desktop images only — cluster-node images take "
    "the brand defaults. In mesh mode it unlocks when the worklist carries a "
    "desktop-class x86 entry (laptop/chromebook); the theme is applied to those "
    "entries and never to the nodes. Cleared when you leave the page.")

_NOTE_STYLE = "color: #a65d00;"


# ``unaffiliated_image`` is imported from core.config above and RE-EXPORTED here.
#
# It was defined in this module for one working day. The docstring it carried recorded
# why it had to exist: ``applies_to`` tested ``role == UNAFFILIATED_ROLE or
# cfg.unaffiliated`` while ``initializePage``/``validatePage`` tested ONLY the role, so
# ``role="standalone-thick", unaffiliated=True`` rendered this page fully live — brand
# assets enabled, no note — for a config whose ``to_cli_args()`` raises. That asymmetry
# was harmless while the page removed itself for both spellings, and went live the
# moment DECISION 1 put the page back on screen.
#
# It also said the rule "belongs in core.config beside branding_allowed /
# person_role_applies — filed as a contract for the config lane". That contract is now
# honoured (core/config.py, beside branding_allowed / cluster_identity_applies), and
# ``_x86_args`` — which had a THIRD inline copy of the same expression — calls it too,
# so the emitter and the wizard cannot disagree about what "unaffiliated" means.
#
# The name stays importable from this module because pages/home.py imports it from here
# (``from .branding import unaffiliated_image``) and because deleting a name a sibling
# page imports is a separate change from moving its implementation. There is exactly one
# implementation, in core.


def _note(text: str = "") -> QtWidgets.QLabel:
    """A wrapped orange advisory label, hidden until it has something to say."""
    lab = QtWidgets.QLabel(text)
    lab.setWordWrap(True)
    lab.setStyleSheet(_NOTE_STYLE)
    lab.setVisible(bool(text))
    return lab


class BrandingPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        self.setTitle("Branding")
        # The NON-mesh sentence; initializePage swaps in the mesh one, because the
        # web-login half is only shown there (module docstring, second bullet).
        self.setSubTitle(_SUBTITLE_IMAGE)
        # scrollable: the login-theme group grew this page past the #400 jitter
        # budget — tall content scrolls inside the page instead of resizing the window.
        lay = scrollable(self)
        # shown ABOVE the (LIVE) form on an unaffiliated image: the identity/look split
        # in one sentence. It used to read "Branding does not apply", which was true
        # only while the page removed itself — and is the sentence the operator's
        # 2026-08-26 report is about ("there should be the menu for adding the themes
        # as in the branded images").
        self.unaffiliated_note = _note(_UNAFFILIATED_NOTE)
        lay.addWidget(self.unaffiliated_note)
        # THE SUPERBRAND DROP-DOWN AND ITS DESIGN STEP (#654, D8) — at the top of the
        # page, in mesh mode, where the mesh's governing brand is chosen. Its Look is
        # the "Web login theme" section further down (one editor, one home), which this
        # page keeps under that title; the step points there.
        #
        # MADE ON THE FIRST MESH VISIT, not here: off a mesh the page has no superbrand
        # (a standalone image has no brands), and a page that always owned the step's
        # editable boxes would break "no editable widget but the two channels that may
        # take free text" (tests/test_branding_page_gui.py) for every image that can
        # never use them.
        self.superbrand: SuperbrandStep | None = None
        self._page_layout = lay
        # every branding widget lives in one container so the role-class / platform
        # grey can disable the whole surface at once. The UNAFFILIATED axis is no
        # longer part of that grey: it hides the two identity widgets (_gate_identity)
        # and leaves the look live.
        self.form = QtWidgets.QWidget()
        form_lay = QtWidgets.QVBoxLayout(self.form)
        form_lay.setContentsMargins(0, 0, 0, 0)
        form_lay.setSpacing(8)
        # The page hosts TWO theme surfaces with different destinations; name this
        # one so it can never be confused with the web login theme group below.
        # Text set per visit: the "themed separately, below" pointer is only true in
        # mesh, where the web-login section is the half that is actually shown.
        self.desktop_hdr = QtWidgets.QLabel(_DESKTOP_HDR)
        self.desktop_hdr.setWordWrap(True)
        form_lay.addWidget(self.desktop_hdr)

        # ── the fork: premade theme XOR custom branding ──────────────────────────
        # An exclusive either/or (spec 2). Both stay visible/scannable; selecting one
        # enables it and disables+clears the other (enable-gating, not a
        # QStackedWidget — the operator can still SEE what the other channel offers).
        # ChoiceCard, not QRadioButton: this is the page's top-level pick-one, and it
        # was previously rendered smaller than the fields it governs.
        # `rb_preset` / `rb_custom` keep their historical names — a ChoiceCard is a
        # checkable QAbstractButton, so isChecked()/setChecked()/toggled are unchanged.
        self.mode_group = ChoiceCardGroup(self)
        self.rb_preset = ChoiceCard(
            "Premade theme",
            "Pick one of the four themes that ship with the generator. Bakes a "
            "wallpaper, boot screen, greeter background, logo and colour scheme.")
        self.rb_preset.set_icon_widget(ThemeStripSwatch())
        self.rb_custom = ChoiceCard(
            "Custom branding",
            "Supply your own assets instead — a whole branding directory and/or "
            "individual wallpaper / GRUB / greeter / logo / colour-scheme files.")
        self.rb_custom.set_icon_widget(CustomAssetsSwatch())
        self.mode_group.add_card(self.rb_preset, 0)
        self.mode_group.add_card(self.rb_custom, 1)
        form_lay.addWidget(self.rb_preset)

        # ── premade themes: a pick-one over the CLOSED four-name set ─────────────
        # `theme_box` is the greyable container the either/or toggles (the old code
        # toggled a combo; the surface is a card group now, so the container is what
        # gets enabled/disabled). `theme_group` speaks THEME NAMES, never indices.
        self.theme_box = QtWidgets.QWidget()
        tb = QtWidgets.QVBoxLayout(self.theme_box)
        tb.setContentsMargins(18, 2, 0, 2)      # indented under its parent card
        tb.setSpacing(6)
        self.theme_group = ThemeCardGroup(self)
        self.theme_group.build(self.theme_box)
        form_lay.addWidget(self.theme_box)

        # a saved config naming a theme this build does not offer: cleared, not kept.
        self.stale_theme_note = _note()
        form_lay.addWidget(self.stale_theme_note)
        # the set-equality assertion, surfaced (never raised — PyQt6 qFatal).
        self.theme_sync_note = _note()
        form_lay.addWidget(self.theme_sync_note)

        form_lay.addWidget(self.rb_custom)
        # the eight custom-value fields + accent, wrapped so the custom card can grey
        # them all at once (line edits AND their Browse… buttons).
        self.custom_group = QtWidgets.QGroupBox("Custom branding assets")
        cg = QtWidgets.QVBoxLayout(self.custom_group)
        self.fields = {}
        # key -> the _row() wrapper (caption + edit + Browse…). The identity gate hides
        # the ROW: hiding the bare QLineEdit leaves the caption stranded over an empty
        # slot, which is the same orphan-header defect network.py:1180-1186 records.
        self.field_rows = {}
        for key, label, flt, is_dir in (
            # --branding-dir: a whole hand-rolled branding tree — the manual
            # counterpart of the keyzip import, which was the ONLY way to set it (G8)
            ("branding_dir", "Branding dir", "", True),
            ("wallpaper", "Wallpaper", "Images (*.png *.jpg *.jpeg)", False),
            ("grub_background", "GRUB background", "Images (*.png)", False),
            # --grub-theme: a full GRUB theme dir, distinct from the background (G33)
            ("grub_theme", "GRUB theme dir", "", True),
            ("login_background", "Login background", "Images (*.png *.jpg)", False),
            ("brand_logo", "Brand logo", "Images (*.png)", False),
            # --color-scheme FILE.colors (the build menu's OPT_BR_SCHEME; G9)
            ("color_scheme", "Colour scheme", "KDE colour scheme (*.colors)", False),
        ):
            le = QtWidgets.QLineEdit()
            btn = _file_picker(self, le, label, flt or "All files (*)", directory=is_dir)
            w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
            h.addWidget(le, 1); h.addWidget(btn)
            row = _row(label, w)
            cg.addWidget(row)
            self.fields[key] = le
            self.field_rows[key] = row
        self.accent = QtWidgets.QLineEdit()
        self.accent.setPlaceholderText("#3f5b8c")
        cg.addWidget(_row("Accent colour", self.accent))
        form_lay.addWidget(self.custom_group)

        # an old save with BOTH a premade theme AND custom assets → custom wins, the
        # theme is cleared, and this orange note explains the reconciliation.
        self.both_set_note = _note(
            "Both a premade theme and custom assets were set — keeping the custom "
            "assets and clearing the theme.")
        self.both_set_note.setVisible(False)
        form_lay.addWidget(self.both_set_note)

        # brand lock stays OUTSIDE the either/or (applies to any branding channel).
        # IDENTITY, not look: hidden + cleared on an unaffiliated image (_gate_identity).
        self.locked = QtWidgets.QCheckBox("Lock branding (user cannot re-theme — managed image)")
        form_lay.addWidget(self.locked)
        lay.addWidget(self.form)

        # WEB login theme — OUTSIDE self.form on purpose: the desktop gating
        # (role-class / platform / unaffiliated) must never grey it, because it
        # themes the login page the MESH serves, not the desktop image. Collapsed
        # by default in desktop flows; initializePage expands it in mesh, where it
        # is the reason the page is shown at all.
        self.login_theme = LoginThemeGroup()
        # The section's content: the compact group every host has always had, and — in
        # mesh, where the superbrand step is shown — the full look editor that replaces
        # it on screen (a hidden group is still loaded and committed, so a saved
        # configuration and every older caller read and write exactly what they did).
        self.login_host = QtWidgets.QWidget()
        host_lay = QtWidgets.QVBoxLayout(self.login_host)
        host_lay.setContentsMargins(0, 0, 0, 0)
        host_lay.addWidget(self.login_theme)
        self._look_host_lay = host_lay
        # "Web login theme" (2026-08-26), superseding #50 item 2's plain "Themes".
        # #50 renamed it to "Themes" when this page had ONE theme surface; it now has
        # two, and the DESKTOP one sits under a "Desktop theme" header while the thing
        # literally titled "Themes" was the web one — so an operator asking for "the
        # menu for adding the themes" was pointed at the wrong plane. Still a
        # LABEL-ONLY change: the persisted login_* config keys keep their names, so old
        # sessions load unchanged.
        self.login_collapsible = collapsible("Web login theme", self.login_host,
                                             expanded=False)
        lay.addWidget(self.login_collapsible)
        lay.addStretch(1)

        self.rb_preset.toggled.connect(self._mode_toggled)
        self.rb_preset.setChecked(True)   # default channel: premade theme

    def _ensure_superbrand(self) -> SuperbrandStep:
        if self.superbrand is None:
            self.superbrand = SuperbrandStep(route="image", look_in_step=False)
            self.superbrand.setAccessibleName(plain_words.term("superbrand").capitalize())
            self.superbrand.changed.connect(self._superbrand_changed)
            # right under the unaffiliated note: the top of the page
            self._page_layout.insertWidget(1, self.superbrand)
        return self.superbrand

    def _superbrand_changed(self) -> None:
        """The design step edited the superbrand's look through the config: the compact
        group (hidden in mesh, but committed on Next) must read the same values, or its
        commit would write the old ones back over the edit."""
        try:
            self.login_theme.load(self.wiz.cfg)
        except Exception:       # pragma: no cover - defensive, PyQt6 qFatal guard
            import sys, traceback
            print("branding: swallowed exception in _superbrand_changed", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)

    def _show_superbrand(self, c, mesh: bool) -> None:
        """The superbrand step on a mesh: the drop-down at the top and the design's
        look in the Web login theme section, in place of the compact group."""
        if not mesh:
            if self.superbrand is not None:
                self.superbrand.setVisible(False)
            self._set_full_look(False)
            return
        step = self._ensure_superbrand()
        step.setVisible(True)
        session = session_for(self.wiz, "image", c, getattr(self.wiz, "generator_dir", "") or "")
        step.set_session(session)
        editor = step.ensure_look_editor()
        if editor is not None and editor.parentWidget() is not self.login_host:
            self._look_host_lay.addWidget(editor)
        self._set_full_look(True)

    def _set_full_look(self, on: bool) -> None:
        editor = self.superbrand.look_editor if self.superbrand is not None else None
        self.login_theme.setVisible(not on)
        if editor is not None:
            editor.setVisible(on)
            sess = self.superbrand.session if self.superbrand is not None else None
            editable = bool(sess is not None and (sess.designing or sess.unaffiliated))
            editor.setEnabled(editable)

    # ── either/or plumbing ──────────────────────────────────────────────────────
    def _mode_toggled(self, *_):
        """Keep the theme picker and the custom group mutually exclusive: the selected
        channel is enabled, the other disabled AND cleared so a stale value can't leak
        past the either/or (belt & braces for validatePage's field commit).

        Guarded: this is a Qt slot, and under PyQt6 an exception escaping one calls
        qFatal and kills the Studio."""
        try:
            preset = self.rb_preset.isChecked()
            self.theme_box.setEnabled(preset)
            self.custom_group.setEnabled(not preset)
            if preset:
                for le in list(self.fields.values()) + [self.accent]:
                    le.clear()
            else:
                self.theme_group.select(NO_THEME)
        except Exception:       # pragma: no cover - defensive, PyQt6 qFatal guard
            import sys, traceback
            print("branding: swallowed exception in _mode_toggled", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)

    def applies_to(self, cfg) -> bool:
        """The page applies to every image EXCEPT an unaffiliated one with no desktop
        half to offer.

        HISTORY, because this reverses a deliberate decision. The page removed itself
        for the unaffiliated role after the operator reported "the unaffiliated desktop
        image wizard still shows options like mesh services and branding and login when
        it shouldn't" — correct at the time, because EVERY field here was then a
        builder hard conflict (_check_unaffiliated_conflicts), so the screen could only
        render greyed with an apology note. The 2026-08-26 decision splits identity from
        look (module docstring): a theme, a wallpaper, a GRUB screen and an accent
        colour are no longer conflicts on this role, so the page again has something to
        offer — which is the operator's third ask, "there should be the menu for adding
        the themes as in the branded images".

        So the skip now keys on the DESKTOP HALF, not on the role: an unaffiliated image
        that is desktop-class on a theme-emitting builder (the only shape that role has
        — x86 standalone) SHOWS the page; anything else still disappears, and stays
        leaves the output unchanged exactly as before via RolePage's clear at role-commit time.

        The web-login-theme half no longer rides on this decision either way: it is
        hidden outside mesh by initializePage, where an unaffiliated image never is.
        """
        if not unaffiliated_image(cfg):
            return True
        return self._desktop_half_allowed(cfg)

    def _desktop_half_allowed(self, c) -> bool:
        """The desktop-theme half applies when the image (or, in mesh, ANY worklist
        entry) is a desktop on a theme-emitting platform. Mesh has no single role —
        the theme rides the shared cfg and materialize()'s per-entry
        clear_role_class_fields strips it from every node entry, so offering it here
        cannot leak a --theme onto a node image."""
        if branding_allowed(c) and platform_supports("theme", c.platform):
            return True
        if c.mode == "mesh":
            wl = getattr(self.wiz, "worklist", None)
            return bool(wl and any(
                image_class("mesh", e.role) == "desktop"
                and platform_supports("theme", e.platform)
                for e in getattr(wl, "entries", ())))
        return False

    def initializePage(self):
        c = self.wiz.cfg
        # ONE predicate at all three sites (see unaffiliated_image): this line used to
        # read `c.role == UNAFFILIATED_ROLE`, which missed the composable flag that
        # applies_to already honoured.
        unaffiliated = unaffiliated_image(c)
        self.unaffiliated_note.setVisible(unaffiliated)
        # theming is desktop-class AND x86-only emission — grey the whole form when
        # (a) neither the image nor any mesh worklist entry is a themable desktop
        # (_desktop_half_allowed) or (b) the platform's builder parses no --theme/…
        # flag. The unaffiliated axis is NO LONGER part of this grey (decision
        # 2026-08-26): it hides the two identity widgets and leaves the look live.
        enabled = self._desktop_half_allowed(c)

        # SET EQUALITY, surfaced. theme_set_problem() compares the offered four
        # against the on-disk theme directories — which ARE the set the builder
        # accepts, since it resolves ${SPECS_DIR}/branding/themes/<name> and errors
        # when the directory is absent. Reported as a note, never raised: a mismatch
        # is an operator-fixable checkout problem (re-run the generator), not a
        # reason to qFatal the Studio out from under them.
        problem = theme_set_problem(getattr(self.wiz, "generator_dir", "") or "")
        self.theme_sync_note.setText(problem)
        self.theme_sync_note.setVisible(bool(problem))

        # populate the premade channel. NOTHING is appended to the offered set — the
        # old page appended the brand name and any loaded value, which is how it came
        # to offer themes the builder hard-errors on.
        known = self.theme_group.select(c.theme or NO_THEME)
        stale = "" if known else (
            f"The saved configuration names the theme '{c.theme}', which this "
            "generator does not ship — the builder would fail with "
            f"\"unknown --theme '{c.theme}'\". Cleared; pick one of the themes above "
            "or switch to custom branding.")
        self.stale_theme_note.setText(stale)
        self.stale_theme_note.setVisible(bool(stale))

        self.fields["branding_dir"].setText(c.branding_dir)
        self.fields["wallpaper"].setText(c.wallpaper)
        self.fields["grub_background"].setText(c.grub_background)
        self.fields["grub_theme"].setText(c.grub_theme)
        self.fields["login_background"].setText(c.login_background)
        self.fields["color_scheme"].setText(c.color_scheme)
        self.accent.setText(c.accent_color)
        # The two IDENTITY widgets load EMPTY on an unaffiliated image rather than
        # showing a value the operator cannot see or reach — the wipe idiom
        # SystemPage._optin_toggled uses, so nothing can be submitted from a hidden
        # control. validatePage clears the fields themselves.
        self.fields["brand_logo"].setText("" if unaffiliated else c.brand_logo)
        self.locked.setChecked(False if unaffiliated else c.brand_locked)

        # decide the active channel: theme-only or neither → preset; any custom field
        # → custom; BOTH set → custom wins (theme cleared) with the orange warning.
        #
        # The vote is over the fields this image is actually OFFERED. Measured, before
        # this narrowing: a saved unaffiliated config carrying brand_logo="/tmp/l.png"
        # (a leftover from a branded role) counted as "has custom assets", flipped the
        # page to the custom channel, and DISCARDED the theme the operator then picked —
        # explained by a both-set note pointing at a widget that is hidden on this role.
        # brand_logo/brand_locked are about to be cleared here anyway, so they get no
        # vote in a reconciliation they cannot be part of.
        offered_custom = tuple(f for f in _CUSTOM_FIELDS
                               if not (unaffiliated and f in _IDENTITY_FIELDS))
        has_theme = bool(c.theme)
        has_custom = any(getattr(c, f) for f in offered_custom)
        self.both_set_note.setVisible(has_theme and has_custom)
        self.mode_group.blockSignals(True)
        (self.rb_custom if has_custom else self.rb_preset).setChecked(True)
        self.mode_group.blockSignals(False)
        self._mode_toggled()   # sync enable + clear the inactive channel

        reason = (unsupported_note(c.platform)
                  if not platform_supports("theme", c.platform) and c.mode != "mesh"
                  else _ROLE_CLASS_REASON)
        gate_widgets_role_class(self.form, enabled, "" if enabled else reason)
        # Mesh with NO desktop entries in the worklist: the desktop-theme section
        # would theme nothing being built — HIDE it outright (operator ask
        # 2026-08-14: "if no desktops were selected to be built, there's no desktop
        # theming section") rather than greying it. Other modes keep the greyed
        # form + reason: there a single image is being configured and the note
        # explains why it cannot carry a theme.
        self.form.setVisible(not (c.mode == "mesh" and not enabled))

        # IDENTITY vs LOOK: the brand logo + the branding lock are the only two
        # widgets an unaffiliated image may not have. Re-gated EVERY visit, so a role
        # switch back to a branded desktop makes them reachable AND collectable again.
        self._gate_identity(unaffiliated)

        # WEB LOGIN THEME — mesh-plane, and now shown ONLY in mesh. It themes the
        # login-ui a MESH serves to browsers; a standalone/cloud desktop serves no
        # login-ui, so outside mesh the section themed nothing while still writing its
        # login_* keys into that image's saved config. Hiding the COLLAPSIBLE (not the
        # group inside it) takes the header with the content — network.py:906-909 /
        # :1180-1186 are the idiom; an orphan "Web login theme" header that expands to
        # nothing is the defect that rule exists to stop. Leaves the output unchanged by
        # construction: every login_* field is NON_ARGV (config.py:755-766) and the
        # commit in validatePage stays UNCONDITIONAL, so a mesh config still round-trips
        # through a stray visit. Kept opened by default in mesh, where it is the half
        # the worklist actually renders (respecting an operator who folded it).
        mesh = c.mode == "mesh"
        self.desktop_hdr.setText(_DESKTOP_HDR_MESH if mesh else _DESKTOP_HDR)
        self.setSubTitle(_SUBTITLE_MESH if mesh else _SUBTITLE_IMAGE)
        self.login_theme.load(c)
        self._show_superbrand(c, mesh)
        self.login_collapsible.setVisible(mesh)
        self.login_collapsible.set_default_expanded(mesh)

    def _gate_identity(self, unaffiliated: bool) -> None:
        """Hide/show the two IDENTITY widgets — the brand logo picker and the branding
        lock — on the unaffiliated axis (decision 2026-08-26).

        HIDE rather than grey, matching the #348 idiom the other pages use for "this
        image class cannot have this at all": a greyed control still advertises a
        decision, and there is none here. The logo's whole _row() is the gate target,
        not the bare line edit, or the "Brand logo" caption is left stranded over an
        empty slot (network.py:1180-1186).

        Leaves the output unchanged in both directions, the documented precondition: validatePage
        resets both fields to their ImageConfig defaults ("" / False) while the widgets
        are hidden, and this runs on EVERY visit, so a switch back to a branded desktop
        restores the widgets and their collectable values.
        """
        gate_widgets_role_class([self.field_rows["brand_logo"], self.locked],
                                not unaffiliated, _IDENTITY_HIDDEN_REASON, hide=True)

    def selected_theme(self) -> str:
        """The premade theme this page would commit ("" = stock look / custom channel).
        The ONE place the widget state is turned into a config value."""
        return self.theme_group.selected() if self.rb_preset.isChecked() else NO_THEME

    def _blank_all(self, c):
        """Clear every branding field — the shared clear for the unaffiliated role and
        for any greyed (node/mesh/off-x86) image, so a stale value can never poison a
        save or the emitted argv."""
        c.theme = c.branding_dir = c.wallpaper = c.grub_background = ""
        c.grub_theme = c.login_background = c.brand_logo = ""
        c.accent_color = c.color_scheme = ""
        c.brand_locked = False

    def validatePage(self):
        c = self.wiz.cfg
        # web login theme commits FIRST and UNCONDITIONALLY: it is mesh-plane data,
        # so neither the unaffiliated role nor the desktop role-class/platform
        # clears below may touch it (an unaffiliated IMAGE can ride a mesh whose
        # login page is themed — different scopes).
        self.login_theme.commit(c)
        # the design step writes after it: the superbrand block (id, title, public name)
        # onto the config and the record file the mesh is described by. A refusal is
        # shown inline by the step and never blocks Next (a page that refused its own
        # Next would strand a person who cannot see why — the build refuses downstream).
        if c.mode == "mesh" and self.superbrand is not None \
                and self.superbrand.session is not None:
            self.superbrand.commit(save=False)
        # The blank-EVERYTHING arm for the unaffiliated role is gone (decision
        # 2026-08-26): the look is legal on this image now, and blanking it here would
        # silently delete the very theme the operator just picked. What replaces it is
        # the identity-only clear at the bottom of this method, which uses the same
        # predicate as the gate that hid the widgets.
        if not self._desktop_half_allowed(c):
            # node / off-x86 / mesh-without-desktop-entries: the form is greyed —
            # clear every branding field (belt & braces, mirrored by materialize()'s
            # clear_role_class_fields I4). A mesh worklist WITH desktop entries keeps
            # the picked theme on the shared cfg; the per-entry clear strips it from
            # every node image at materialize time.
            self._blank_all(c)
            return True
        if self.rb_preset.isChecked():
            # premade-theme channel: commit the picked theme, blank the custom fields.
            # selected_theme() can only ever return "" or one of the declared four —
            # the picker has no free-text path, so an invalid --theme is unreachable.
            c.theme = self.selected_theme()
            for f in _CUSTOM_FIELDS:
                setattr(c, f, "")
        else:
            # custom-branding channel: blank the preset, collect the eight fields.
            c.theme = ""
            c.branding_dir = self.fields["branding_dir"].text().strip()
            c.wallpaper = self.fields["wallpaper"].text().strip()
            c.grub_background = self.fields["grub_background"].text().strip()
            c.grub_theme = self.fields["grub_theme"].text().strip()
            c.login_background = self.fields["login_background"].text().strip()
            c.brand_logo = self.fields["brand_logo"].text().strip()
            c.color_scheme = self.fields["color_scheme"].text().strip()
            c.accent_color = self.accent.text().strip()
        c.brand_locked = self.locked.isChecked()
        if unaffiliated_image(c):
            # IDENTITY clear, paired with _gate_identity's hide. Both fields go back to
            # their ImageConfig dataclass defaults rather than to whatever the hidden
            # widgets hold, so the GATE decides the argv, not the screen — and
            # _check_unaffiliated_conflicts / build-x86-host-stage4.sh, which still
            # hard-error on either flag for this role, can never be reached. The LOOK
            # collected above is deliberately kept.
            c.brand_logo = ""
            c.brand_locked = False
        # platform belt & braces (the form is already greyed off-x86, but keep the
        # established clear so nothing can linger).
        clear_unsupported(c, _BRANDING_FIELDS)
        return True
