"""BrandingPage — TWO branding surfaces with opposite scopes:

* DESKTOP assets (premade theme XOR custom boot/login/wallpaper/GRUB/accent, plus
  the brand lock): x86-only emission, greys+clears on node images
  (``branding_allowed`` / ``_desktop_half_allowed``) and on the unaffiliated role
  (a builder hard-conflict). In MESH mode the half is live whenever the worklist
  carries a desktop-class x86 entry — the theme rides the shared cfg and
  materialize()'s per-entry clear keeps it off every node image (operator ask
  2026-08-14; supersedes spec 2's never-in-mesh). The premade picker and the eight
  custom fields are an exclusive either/or so the two branding channels can never
  fight.
* The WEB LOGIN THEME (colours/fonts for the login page the MESH serves to
  browsers): NON-argv mesh-plane fields (config NON_ARGV_FIELDS), deliberately
  OUTSIDE the desktop gating — mesh mode visits this page exactly FOR this half,
  and greying it there would gate the knob off on the only plane that renders it.

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
from ...core.branding_themes import theme_set_problem
from ...core.config import UNAFFILIATED_ROLE, branding_allowed, image_class
from ._gating import (
    clear_unsupported, gate_widgets_role_class, platform_supports, unsupported_note,
)
from ._logintheme import LoginThemeGroup
from ._scroll import scrollable
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

_ROLE_CLASS_REASON = (
    "Desktop theming applies to desktop images only — cluster-node images take "
    "the brand defaults. In mesh mode it unlocks when the worklist carries a "
    "desktop-class x86 entry (laptop/chromebook); the theme is applied to those "
    "entries and never to the nodes. Cleared when you leave the page.")

_NOTE_STYLE = "color: #a65d00;"


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
        self.setSubTitle("Desktop branding (a premade theme or your own assets) plus "
                         "the Themes for the web pages the mesh serves.")
        # scrollable: the login-theme group grew this page past the #400 jitter
        # budget — tall content scrolls inside the page instead of resizing the window.
        lay = scrollable(self)
        # shown INSTEAD of the (disabled) form when the unaffiliated role is selected
        self.unaffiliated_note = _note(
            "Branding does not apply — unaffiliated build (plain Gentoo, zero brand identity).")
        lay.addWidget(self.unaffiliated_note)
        # every branding widget lives in one container so the role-class / platform /
        # unaffiliated grey can disable the whole surface at once.
        self.form = QtWidgets.QWidget()
        form_lay = QtWidgets.QVBoxLayout(self.form)
        form_lay.setContentsMargins(0, 0, 0, 0)
        form_lay.setSpacing(8)
        # The page hosts TWO theme surfaces with different destinations; name this
        # one so it can never be confused with the web login theme group below.
        desktop_hdr = QtWidgets.QLabel(
            "<b>Desktop theme</b> — baked into the IMAGE itself: wallpaper, GRUB "
            "boot screen, login greeter, colours. (The web login page the mesh "
            "serves to browsers is themed separately, below.)")
        desktop_hdr.setWordWrap(True)
        form_lay.addWidget(desktop_hdr)

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
            cg.addWidget(_row(label, w))
            self.fields[key] = le
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
        self.locked = QtWidgets.QCheckBox("Lock branding (user cannot re-theme — managed image)")
        form_lay.addWidget(self.locked)
        lay.addWidget(self.form)

        # WEB login theme — OUTSIDE self.form on purpose: the desktop gating
        # (role-class / platform / unaffiliated) must never grey it, because it
        # themes the login page the MESH serves, not the desktop image. Collapsed
        # by default in desktop flows; initializePage expands it in mesh, where it
        # is the reason the page is shown at all.
        self.login_theme = LoginThemeGroup()
        # "Themes", not "Web login theme" (#50 item 2): label-only rename — the
        # persisted login_* config keys keep their names so old sessions load.
        self.login_collapsible = collapsible("Themes", self.login_theme,
                                             expanded=False)
        lay.addWidget(self.login_collapsible)
        lay.addStretch(1)

        self.rb_preset.toggled.connect(self._mode_toggled)
        self.rb_preset.setChecked(True)   # default channel: premade theme

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
        """SKIP this page entirely on an unaffiliated image (operator report: "the
        unaffiliated desktop image wizard still shows options like mesh services and
        branding and login when it shouldn't").

        The role builds a plain Gentoo desktop with ZERO HugMesh affiliation, so
        EVERY field this page owns is a builder hard conflict
        (_check_unaffiliated_conflicts) — the page could only ever be shown greyed
        with an apology note, which is what it did. A greyed-out screen the operator
        must still click Next through is not a choice; it is noise.

        Emission-neutral, the documented precondition for applies_to() -> False: the
        RolePage now blanks every branding field at the moment the role is committed,
        so nothing this page would have cleared can survive to the argv.

        The web-login-theme half goes with it. Those fields are mesh-plane and
        deliberately NOT cleared for the unaffiliated ROLE (an unaffiliated image can
        ride a mesh whose login page is themed — different scopes), but that scope
        only exists in MESH mode, where the RolePage never runs and this role is
        unreachable. In the standalone/cloud flows that DO reach it there is no
        login-ui being served, so the section themed nothing.
        """
        return not (getattr(cfg, "role", "") == UNAFFILIATED_ROLE
                    or getattr(cfg, "unaffiliated", False))

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
        unaffiliated = c.role == UNAFFILIATED_ROLE
        self.unaffiliated_note.setVisible(unaffiliated)
        # theming is desktop-class AND x86-only emission — grey the whole form when
        # (a) the unaffiliated role is selected, (b) neither the image nor any mesh
        # worklist entry is a themable desktop (_desktop_half_allowed), or (c) the
        # platform's builder parses no --theme/… flag.
        enabled = not unaffiliated and self._desktop_half_allowed(c)

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
        self.fields["brand_logo"].setText(c.brand_logo)
        self.fields["color_scheme"].setText(c.color_scheme)
        self.accent.setText(c.accent_color)
        self.locked.setChecked(c.brand_locked)

        # decide the active channel: theme-only or neither → preset; any custom field
        # → custom; BOTH set → custom wins (theme cleared) with the orange warning.
        has_theme = bool(c.theme)
        has_custom = any(getattr(c, f) for f in _CUSTOM_FIELDS)
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

        # web login theme: ALWAYS active (mesh-plane, not desktop). In mesh it is
        # the half every worklist renders, so keep it opened by default there
        # (respecting an operator who folded it themselves).
        self.login_theme.load(c)
        self.login_collapsible.set_default_expanded(c.mode == "mesh")

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
        if c.role == UNAFFILIATED_ROLE:
            # branding is a builder HARD CONFLICT on the unaffiliated role — clear
            # everything so a role switch cannot poison the argv.
            self._blank_all(c)
            return True
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
        # platform belt & braces (the form is already greyed off-x86, but keep the
        # established clear so nothing can linger).
        clear_unsupported(c, _BRANDING_FIELDS)
        return True
