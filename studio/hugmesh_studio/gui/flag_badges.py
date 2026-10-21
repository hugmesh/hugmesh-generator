"""flag_badges — the four per-package flag columns (USE_EXPAND / USE / KEYWORDS /
LICENSE) rendered as hoverable badges in the progress tree.

Ground truth is ``docs/PACKAGE-FLAG-BADGES.md``; the data layer is the Qt-free
:mod:`...core.package_flags`. This module owns the Qt face only:

* :class:`FlagBadgeDelegate` — a QStyledItemDelegate that PAINTS badges instead of
  creating widgets. A real build emerges 300+ packages and four columns of
  per-badge child widgets would be thousands of live QWidgets; a delegate costs
  zero widgets and one paint per visible cell. Hover works through
  ``helpEvent`` per-badge hit-testing, and the tip is a SELECTABLE QLabel (a
  plain QToolTip cannot be selected, and §4.5's constructed URLs are only useful
  if the operator can copy them).
* :class:`FlagColumns` — installs the delegate on the four tree columns and
  enforces the §5 rule "empty column ⇒ no column": every column starts hidden
  and is revealed the first time any row has content for it. The verbatim
  ``KEY="…"`` text is ALSO stored as the item's display text, so selection/copy
  paths that read ``item.text(col)`` yield exactly what portage printed.
* :class:`ImageFlagJoin` — the per-image join: resolver merge-list rows
  (streamed in, later block wins — §0c: the display is a slot-conflict accident,
  so it may never come) fill USE_EXPAND + USE with per-flag state; the VDB under
  the session's build sysroot fills KEYWORDS + LICENSE, and fills
  enabled/disabled-only USE data when no resolver row exists (markers are then
  honestly absent — §3).

Badge semantics are §5's table EXACTLY: six states + the forced/masked modifier
(outlined chip + 🔒, never a new colour), strike-through for removed, ✨ composed
with 🔼/🔽 when a flag is both new in IUSE and changing state. Colours reuse
``styles.MUTED``/``styles.WARN``; the only new values are the two recorded in the
doc (#0e7a63 teal, #1a7f37 green) — single mid-tone values per styles.py's
cross-theme palette rule, no light/dark pairs. Order is portage's own emitted
order (enabled → disabled → removed, natural sort within): the parser preserves
it and NOTHING here re-sorts.

HARD RULE (§4.5): the Studio never touches the network. The
packages.gentoo.org / wiki.gentoo.org URLs below are CONSTRUCTED strings for
the operator to read and copy — nothing in this module imports urllib /
requests / QtNetwork and nothing performs any I/O beyond reading local files
via the core data layer.
"""
from __future__ import annotations

import dataclasses
import functools
import os

from .qt import QtCore, QtGui, QtWidgets, Qt
from . import styles
from ..core import package_flags as pf

# ── palette (docs/PACKAGE-FLAG-BADGES.md §5 — the ONLY colours badges may use) ────────
TEAL = "#0e7a63"    # enabled, unchanged — the one deliberate deviation from portage's
                    # red; every tooltip for this state says so (RED_NOTE below).
GREEN = "#1a7f37"   # turning on / turning off (portage's green, darkened for 4.5:1)
# styles.MUTED  → disabled, unchanged (portage's blue reads as a hyperlink in Qt)
# styles.WARN   → new in IUSE / removed from IUSE (portage's yellow, legible form)

#: The four columns, in the §5 order. "USE_EXPAND", not "package.env" — the operator
#: named the wrong file; PYTHON_TARGETS/ABI_X86/… are USE_EXPAND variables (§3.1).
FLAG_COLUMNS = ("USE_EXPAND", "USE", "KEYWORDS", "LICENSE")

#: Item data role carrying a :class:`FlagCell` for the delegate.
CELL_ROLE = Qt.ItemDataRole.UserRole + 41

#: §5 row 1's mandatory honesty note, verbatim substring included in the tooltip.
RED_NOTE = "portage prints this in red"

#: §1.3's collision, stated whenever a colourless "(-f)" is rendered: states 10 and 11
#: only differ by colour, and our captured logs have none.
AMBIGUITY_CAVEAT = (
    "cannot tell from this log whether this flag is also newly added to IUSE — the log "
    "was captured without colour, and portage suppresses the % marker inside "
    "parentheses, so a masked-and-unchanged (-f) and a masked-and-newly-in-IUSE (-f) "
    "collide in plain text (only their colour differs). Emitting with --color=y would "
    "remove this ambiguity.")

#: Stated on every VDB-fallback USE badge: without a resolver display (which portage
#: only prints on e.g. a slot conflict, §0c) the change markers simply do not exist.
VDB_NOTE = (
    "state read from the merged package's VDB — this log carries no resolver merge-list "
    "display for it, so the change markers (* / % / parentheses) are unavailable; only "
    "enabled/disabled is known")

#: Said on VDB-derived USE/USE_EXPAND badges when the group names came from the
#: built-in snapshot rather than a live tree or a §4.4 sidecar. The grouping is still
#: correct for every known group — but the operator cannot audit the list here, and a
#: group added to the tree since the snapshot would stay folded into plain USE.
GROUPS_FALLBACK_NOTE = (
    "USE_EXPAND grouping came from the Studio's built-in group-name snapshot: this "
    "session carries no flag-descriptions sidecar and this machine has no Gentoo tree, "
    "so profiles/desc/*.desc — the authoritative group list — could not be read. A "
    "group added to the tree since that snapshot would still be shown as a plain USE "
    "flag under its full prefixed name")

#: Every URL block leads with this — the no-fetch guarantee, visible to the operator.
URL_NOTE = "links (constructed offline — the Studio never fetches them):"

#: Said on USE/USE_EXPAND badges whose flags came from the PLAN PREVIEW rather than a
#: merge-list display portage printed during the merge. The distinction is real and
#: worth one line of hover text: a plan is portage's answer to "what WOULD you merge",
#: computed from the same argv immediately before the merge runs — normally identical
#: to what happens, but it is a prediction, and a --keep-going drop or an autounmask
#: change can make the merge differ from it. A confirmed resolver row for the same
#: package supersedes the plan and this note disappears.
PLAN_NOTE = (
    "flags from the plan preview — portage's own --pretend column for this package, "
    "captured with the SAME emerge arguments immediately before the merge (a normal "
    "merge prints no merge-list display at all, docs/EMERGE-PLAN-PREVIEW.md). It is "
    "what portage INTENDED to merge; a later real merge-list display supersedes it")

#: Added after PLAN_NOTE when the plan row is ``via=binary``: this package is merged
#: from the shared binpkg pool, not compiled (issue #46).
PLAN_BINARY_NOTE = "merged from the binpkg pool (a binary package), not compiled"


def _append_note(tip_source: object, note: str) -> object:
    """Add ``note`` to a badge tooltip, preserving laziness.

    ``tip_source`` may be a zero-arg factory (the whole point of the lazy tooltip:
    a build with 300 packages × ~20 flags would otherwise build 6 000 multi-paragraph
    strings nobody reads). Wrapping it in another factory keeps it unevaluated."""
    if callable(tip_source):
        def _lazy(_src=tip_source, _note=note):     # bind now, not at call time
            try:
                return f"{_src()}\n{_note}"
            except Exception:            # noqa: BLE001 — a hover must never raise
                return _note
        return _lazy
    return f"{tip_source}\n{note}" if tip_source else note


def _annotate_cells(cells: dict[str, "FlagCell"], note: str) -> dict[str, "FlagCell"]:
    """Copy ``cells`` with ``note`` appended to every badge tooltip."""
    out: dict[str, FlagCell] = {}
    for key, cell in cells.items():
        out[key] = dataclasses.replace(cell, badges=tuple(
            dataclasses.replace(b, tip_source=_append_note(b.tip_source, note))
            for b in cell.badges))
    return out

#: Cheap exact prefix gate for the stream: a resolver row's type word sits immediately
#: after the '[' (package_flags._LINE_RE anchors on exactly these), so this tuple is
#: equivalent to the full parse and costs one C-level startswith. It matters — a bare
#: "starts with [" would also let through the ~75 000 "[123/456]" ninja counter lines a
#: single real build emits.
RESOLVER_PREFIXES = ("[ebuild", "[binary", "[nomerge", "[blocks", "[uninstall")

#: The same cheap prefix gate for plan-preview lines. Re-exported from the parser's own
#: pin rather than re-spelled here, so the builder side, the parser side and this stream
#: gate cannot drift apart — check.sh asserts the builder/parser halves byte-equal, and
#: this makes the GUI a third consumer of the same constant instead of a fourth spelling.
def _plan_prefix() -> str:
    from ..core import emerge_packages as ep     # local: avoids an import cycle
    return ep.PLAN_BANNER_PREFIX


PLAN_PREFIX = _plan_prefix()


# ── badge + cell model ───────────────────────────────────────────────────────────────

@dataclasses.dataclass(frozen=True)
class Badge:
    """One paintable chip. ``verbatim`` is the exact portage token it stands for.

    ``tooltip`` is LAZY: a real emerge names 300+ packages with ~20 flags each, and
    building 6 000 multi-paragraph hover strings (each of which parses/queries the
    §4 description sources) up front is pure waste — only the badge under the
    pointer is ever read. ``tip_source`` may therefore be a zero-argument factory;
    the first ``.tooltip`` read materialises and memoises it."""

    text: str            # what the chip shows: emoji + printed flag name
    colour: str          # chip colour (fill when filled, border+text when outlined)
    outlined: bool       # §5 modifier: forced/masked = outlined-not-filled (+🔒 in text)
    strike: bool         # §5 #6: removed from IUSE
    tip_source: object   # str, or a callable returning one (memoised on first read)
    verbatim: str

    @property
    def tooltip(self) -> str:
        tip = self.tip_source
        if callable(tip):
            try:
                tip = tip()
            except Exception:            # noqa: BLE001 — a hover must never raise
                tip = self.verbatim
            object.__setattr__(self, "tip_source", tip)
        return tip if isinstance(tip, str) else str(tip)


@dataclasses.dataclass(frozen=True)
class FlagCell:
    """One column's worth of badges for one package row.

    ``copy_text`` is the verbatim ``KEY="…"`` form (straight from the parser's
    ``FlagGroup.raw`` when a resolver row supplied it) — the §5 copy-paste
    guarantee. It is also what the item's display text is set to."""

    badges: tuple[Badge, ...]
    copy_text: str
    #: The UNFILTERED ``KEY="…"`` string — every flag portage would print, including
    #: the uninteresting always-off ones the display filter hides (see
    #: :func:`_interesting`). The row shows ``copy_text``; the context menu's
    #: "Copy flags (verbatim)" hands over THIS, so filtering the view never costs
    #: the operator the real portage string. Defaults to ``copy_text`` for cells
    #: that were never filtered.
    verbatim_text: str = ""

    def __post_init__(self) -> None:
        if not self.verbatim_text:
            object.__setattr__(self, "verbatim_text", self.copy_text)


# ── tooltips ─────────────────────────────────────────────────────────────────────────

def _flag_urls(cat_pkg: str | None, wiki_topic: str) -> list[str]:
    """§4.5: URLs are built and displayed, NEVER fetched."""
    lines = [URL_NOTE]
    if cat_pkg:
        lines.append(f"  https://packages.gentoo.org/packages/{cat_pkg}")
    lines.append(f"  https://wiki.gentoo.org/wiki/{wiki_topic}")
    return lines


def _token_meaning(tok: pf.FlagToken) -> str:
    """Plain-English meaning of one §1.1 state, as §5 maps it."""
    if tok.removed:
        base = ("removed from IUSE — the flag existed at the last merge and is gone "
                "from the new version's IUSE")
        if tok.changed:
            base += " (and it had been enabled)"
        return base
    if tok.new_in_iuse:
        base = ("new in IUSE — this flag did not exist in the installed version's IUSE")
        if tok.changed:
            base += "; it is enabled and turning on"
        else:
            base += "; it is enabled" if tok.enabled else "; it is disabled"
        return base
    if tok.changed:
        if tok.enabled:
            return "turning ON — off at the last merge, on for this build"
        return "turning OFF — on at the last merge, off for this build"
    if tok.enabled:
        return ("enabled — on now and on at the last merge (or the package is new). "
                f"In a terminal {RED_NOTE}; the Studio shows it teal because red would "
                "read as an error here")
    return "disabled — off now and off at the last merge (or the package is new)"


def token_tooltip(tok: pf.FlagToken, cat_pkg: str | None = None,
                  group: str | None = None,
                  descriptions: pf.FlagDescriptions | None = None,
                  extra_note: str | None = None) -> str:
    """The full hover text for one flag token: verbatim portage text, plain-English
    state, honesty caveats, the §4 offline description, and constructed URLs."""
    lines = [f'{tok.verbatim} — portage\'s exact text'
             + (f' (inside {group}="…")' if group else "")]
    lines.append(_token_meaning(tok))
    if tok.forced_masked:
        if tok.enabled:
            lines.append("forced ON by the profile (use.force) — (f): you did not "
                         "choose this and cannot change it here")
        else:
            lines.append("masked OFF by the profile (use.mask) — (-f): you did not "
                         "choose this and cannot change it here (the sign inside the "
                         "parentheses is portage's only forced-vs-masked hint)")
    if tok.ambiguous:
        lines.append(AMBIGUITY_CAVEAT)
    if extra_note:
        lines.append(extra_note)
    desc = None
    if descriptions is not None:
        try:
            desc = descriptions.describe(tok.name, cat_pkg=cat_pkg, group=group)
        except OSError:
            desc = None
    if desc:
        lines.append(f"{tok.name}: {desc}")
    else:
        lines.append(f"{tok.name}: no offline description available (no session "
                     "sidecar and no host Gentoo tree)")
    lines.extend(_flag_urls(cat_pkg, "USE_flag"))
    return "\n".join(lines)


# ── badge construction (§5's table, EXACTLY) ─────────────────────────────────────────

def badge_for_token(tok: pf.FlagToken, cat_pkg: str | None = None,
                    group: str | None = None,
                    descriptions: pf.FlagDescriptions | None = None,
                    extra_note: str | None = None) -> Badge:
    """§5 mapping of one classified token to its chip."""
    if tok.display_state == "removed":
        emoji, colour = "🗑️", styles.WARN
    elif tok.display_state == "new-in-iuse":
        # §5 #5: sparkle, COMPOSED with the transition triangle when both apply
        # (f%* is new AND turning on).
        emoji = "✨" + ("🔼" if tok.changed and tok.enabled
                        else "🔽" if tok.changed else "")
        colour = styles.WARN
    elif tok.display_state == "turning-on":
        emoji, colour = "🔼", GREEN
    elif tok.display_state == "turning-off":
        emoji, colour = "🔽", GREEN
    elif tok.display_state == "enabled-unchanged":
        emoji, colour = "🟢", TEAL
    else:                                   # disabled-unchanged
        emoji, colour = "⚪", styles.MUTED
    text = f"{emoji} {tok.name}"
    if tok.forced_masked:
        text = f"🔒 {text}"                 # modifier: padlock + outlined, no new colour
    return Badge(
        text=text,
        colour=colour,
        outlined=tok.forced_masked,
        strike=tok.removed,
        # lazy: only the hovered badge ever pays for its hover text (see Badge).
        tip_source=functools.partial(token_tooltip, tok, cat_pkg=cat_pkg, group=group,
                                     descriptions=descriptions, extra_note=extra_note),
        verbatim=tok.verbatim,
    )


def _group_header_badge(key: str) -> Badge:
    """A plain label chip naming a USE_EXPAND group before its member badges — one
    cell can carry several groups (ABI_X86="…" PYTHON_TARGETS="…") and the printed
    member names have the group prefix stripped, so the label disambiguates them."""
    return Badge(
        text=key,
        colour=styles.MUTED,
        outlined=True,
        strike=False,
        tip_source=(f'USE_EXPAND group {key} — portage prints its member flags as '
                    f'{key}="…" with the {key.lower()}_ prefix stripped from each name'),
        verbatim=key,
    )


def resolver_cells(row: pf.ResolverRow,
                   descriptions: pf.FlagDescriptions | None = None
                   ) -> dict[str, FlagCell]:
    """USE_EXPAND + USE cells from one resolver merge-list row. Order is portage's
    emitted order — never re-sorted (§1.2: position is information)."""
    cells: dict[str, FlagCell] = {}
    use_badges: list[Badge] = []
    use_raw = ""
    expand_badges: list[Badge] = []
    expand_raw: list[str] = []
    for g in row.groups:
        if g.key == "USE":
            use_raw = g.raw
            for tok in g.tokens:
                use_badges.append(badge_for_token(
                    tok, cat_pkg=row.cat_pkg, descriptions=descriptions))
        else:
            expand_raw.append(g.raw)
            expand_badges.append(_group_header_badge(g.key))
            for tok in g.tokens:
                expand_badges.append(badge_for_token(
                    tok, cat_pkg=row.cat_pkg, group=g.key, descriptions=descriptions))
    if use_badges:
        cells["USE"] = FlagCell(badges=tuple(use_badges), copy_text=use_raw)
    if expand_badges:
        cells["USE_EXPAND"] = FlagCell(badges=tuple(expand_badges),
                                       copy_text=" ".join(expand_raw))
    return cells


# ── display filter: hide the flags nobody ever wanted ────────────────────────
# A stage4 sysroot lists every flag in a package's IUSE, and the vast majority are
# disabled and were never going to be anything else — pure noise in a column the
# operator scans for decisions. The operator's rule (2026-08-05): show a flag only
# when it is ENABLED, or when it is DISABLED **and Gentoo's own ebuild defaults it
# ON** (``+flag`` in IUSE) — i.e. our profile / make.conf / mesh posture overrode
# upstream, which is exactly the case worth reviewing.
#
# Deliberately NOT filtered:
#   * anything enabled — always shown;
#   * any flag carrying a state marker (changed / new-in-IUSE / removed / forced or
#     masked by the profile). Those describe a TRANSITION or a profile decision and
#     are interesting regardless of the default, and dropping them would silently
#     hide the parenthesised profile-forced case the badge design exists to surface.
# The unfiltered string stays reachable via FlagCell.verbatim_text.
def _interesting(tok: "pf.FlagToken", default_on: frozenset[str]) -> bool:
    if tok.enabled:
        return True
    if tok.changed or tok.removed or tok.forced_masked or tok.new_in_iuse:
        return True
    return tok.name in default_on


def vdb_use_cells(vdb: pf.VdbPackage,
                  descriptions: pf.FlagDescriptions | None = None
                  ) -> dict[str, FlagCell]:
    """The §3 fallback when no resolver row exists: USE + USE_EXPAND from the VDB's
    IUSE/USE sets — enabled/disabled ONLY, badges in the 'unchanged' pair, every
    tooltip carrying :data:`VDB_NOTE`. Mirrors portage's enabled→disabled order;
    IUSE's own order is kept within each half.

    The group names come from :meth:`pf.FlagDescriptions.use_expand_groups`, which
    never returns () — an archived session on a machine with no Gentoo tree must
    still get its USE_EXPAND column, or the USE cell silently degrades to the flat
    prefix-mixing list §3.1 calls out (``python_targets_python3_13`` sitting beside
    real USE flags) with no column and no caveat."""
    if not vdb.iuse:
        return {}
    groups: tuple[str, ...] = pf.USE_EXPAND_GROUPS_FALLBACK
    note = VDB_NOTE
    if descriptions is not None:
        try:
            groups = descriptions.use_expand_groups()
            if descriptions.use_expand_groups_source() == "fallback":
                note = f"{VDB_NOTE}\n{GROUPS_FALLBACK_NOTE}"
        except OSError:
            groups = pf.USE_EXPAND_GROUPS_FALLBACK
            note = f"{VDB_NOTE}\n{GROUPS_FALLBACK_NOTE}"
    plain, grouped = pf.split_use_expand(vdb.iuse_names, groups)
    use_set = set(vdb.use_list)
    cells: dict[str, FlagCell] = {}

    def _tokens(names: list[str], enabled_of) -> list[pf.FlagToken]:
        toks = []
        for name in names:
            t = pf.classify_flag_token(name if enabled_of(name) else f"-{name}")
            if t is not None:
                toks.append(t)
        # enabled first, then disabled — the §1.2 shape; input order kept within.
        return [t for t in toks if t.enabled] + [t for t in toks if not t.enabled]

    use_toks = _tokens(list(plain), lambda n: n in use_set)
    default_on = vdb.iuse_default_on
    shown_toks = [t for t in use_toks if _interesting(t, default_on)]
    if use_toks:
        # The cell is built whenever the package HAS flags, even when every one of them
        # is filtered out of the view: it is what carries verbatim_text, and dropping it
        # would cost the operator the real portage string for exactly the boring-looking
        # packages. An all-filtered cell simply has no badges and no display text —
        # apply_cells refuses to reveal a column for a cell with no badges, so a row
        # like that stays invisible instead of un-hiding an empty USE column.
        cells["USE"] = FlagCell(
            badges=tuple(badge_for_token(t, cat_pkg=vdb.cat_pkg,
                                         descriptions=descriptions,
                                         extra_note=note) for t in shown_toks),
            copy_text=('USE="' + " ".join(t.verbatim for t in shown_toks) + '"')
                      if shown_toks else "",
            verbatim_text='USE="' + " ".join(t.verbatim for t in use_toks) + '"')
    expand_badges: list[Badge] = []
    expand_raw: list[str] = []
    for gname, suffixes in grouped.items():
        toks = _tokens(list(suffixes),
                       lambda s, g=gname: f"{g.lower()}_{s}" in use_set)
        if not toks:
            continue
        expand_badges.append(_group_header_badge(gname))
        expand_badges.extend(badge_for_token(t, cat_pkg=vdb.cat_pkg, group=gname,
                                             descriptions=descriptions,
                                             extra_note=note) for t in toks)
        expand_raw.append(f'{gname}="' + " ".join(t.verbatim for t in toks) + '"')
    if expand_badges:
        cells["USE_EXPAND"] = FlagCell(badges=tuple(expand_badges),
                                       copy_text=" ".join(expand_raw))
    return cells


def vdb_keywords_cell(vdb: pf.VdbPackage) -> FlagCell | None:
    """KEYWORDS badges from the VDB (§2.2: the resolver line has no keyword list at
    all — the VDB is the only captured source)."""
    kws = vdb.keywords_list
    if not kws:
        return None
    badges = []
    for kw in kws:
        arch = kw.lstrip("~-")
        if kw.startswith("-"):
            emoji, colour = "⛔", styles.MUTED
            meaning = ("explicitly excluded — known broken/unsupported"
                       + (f" on {arch}" if arch and kw != "-*" else
                          " everywhere except the arches listed"))
        elif kw.startswith("~"):
            emoji, colour = "⚠️", styles.WARN
            meaning = (f"testing (unstable) keyword on {arch} — merged only when "
                       "accepted via ACCEPT_KEYWORDS / package.accept_keywords")
        else:
            emoji, colour = "🟢", TEAL
            meaning = f"stable keyword — the ebuild is marked stable on {arch}"
        tip = "\n".join([
            f"{kw} — portage's exact text (VDB KEYWORDS of the merged package)",
            meaning,
            *_flag_urls(vdb.cat_pkg, "KEYWORDS"),
        ])
        badges.append(Badge(text=f"{emoji} {kw}", colour=colour, outlined=False,
                            strike=False, tip_source=tip, verbatim=kw))
    return FlagCell(badges=tuple(badges),
                    copy_text=f'KEYWORDS="{vdb.keywords}"')


#: LICENSE structural tokens — kept verbatim in the copy text, not badged.
_LICENSE_STRUCTURAL = frozenset({"||", "(", ")"})


def vdb_license_cell(vdb: pf.VdbPackage) -> FlagCell | None:
    """LICENSE badges from the VDB (§2.2/§3: never in the resolver line; 68/319 real
    packages have none at all, which is exactly the empty-cell case)."""
    if not vdb.license:
        return None
    names = [t for t in vdb.license.split() if t not in _LICENSE_STRUCTURAL]
    if not names:
        return None
    any_of = "||" in vdb.license
    badges = []
    for name in names:
        lines = [f"{name} — from the VDB LICENSE of the merged package "
                 "(USE-conditionals already resolved)"]
        if any_of:
            lines.append(f'the LICENSE string offers alternatives (|| = any-of): '
                         f'{vdb.license}')
        lines.extend(_flag_urls(vdb.cat_pkg, "License_groups"))
        badges.append(Badge(text=f"📜 {name}", colour=styles.MUTED, outlined=False,
                            strike=False, tip_source="\n".join(lines),
                            verbatim=name))
    return FlagCell(badges=tuple(badges),
                    copy_text=f'LICENSE="{vdb.license}"')


# ── per-image join (resolver stream + session VDB) ───────────────────────────────────

_SYSROOT_SUFFIX = ("var", "log", "portage", "build")


def sysroot_from_log_root(log_root: str) -> str:
    """The build sysroot, derived from the SAME per-entry log_root the progress page
    already wires (``<session>/wl-<id>/sysroot/var/log/portage/build``) — never a
    hardcoded session path. "" when the shape doesn't match (direct-slot tests)."""
    if not log_root:
        return ""
    p = os.path.normpath(log_root)
    for expect in reversed(_SYSROOT_SUFFIX):
        head, tail = os.path.split(p)
        if tail != expect or not head:
            return ""
        p = head
    return p


def descriptions_for_session(session_dir: str | None) -> pf.FlagDescriptions:
    """The §4 offline description resolver for one session: the §4.4 sidecar (plain or
    .gz) when the session has one, the host Gentoo tree otherwise. Both absent is a
    supported, silent case — every description is then honestly None."""
    sidecar = None
    if session_dir:
        p = pf.sidecar_path_for_session(session_dir)
        if os.path.isfile(p):
            sidecar = p
        elif os.path.isfile(p + ".gz"):
            sidecar = p + ".gz"
    return pf.FlagDescriptions(sidecar=sidecar)


#: VDB re-read attempts per atom before giving up (the tick retries roughly 1/s while
#: the atom is listed; a merged package's VDB dir appears within a few seconds of its
#: Completed line, so 30 is generous without letting a dead path spin forever).
_VDB_MAX_ATTEMPTS = 30
#: Pending-VDB atoms retried per tick — the same bounded-pass discipline as
#: EmergePackageParser.poll().
_VDB_RETRY_PER_TICK = 8


class ImageFlagJoin:
    """Per-image flag state: streamed resolver rows + lazily-read VDB records.

    Everything is incremental and bounded: ``feed_line`` is one regex on lines the
    caller has already first-char-gated; VDB reads happen only on package step
    transitions and a small per-tick retry budget; ``cells_if_changed`` returns
    None unless something genuinely new is available for that atom, so the GUI
    repaints nothing on the (overwhelmingly common) no-op call."""

    def __init__(self, sysroot: str = "",
                 descriptions: pf.FlagDescriptions | None = None) -> None:
        self.sysroot = sysroot
        self.descriptions = descriptions
        self.revision = 0                    # bumps per indexed resolver row
        # Keyed by EXACT cpv, with an unambiguous-only (cat, pkg) fallback: a -v
        # merge list gives each slot its own row, and this fleet really does merge
        # dev-lang/python at two slots and app-text/docbook-xml-dtd at four.
        self._resolver = pf.ResolverIndex()
        self._vdb: dict[str, pf.VdbPackage] = {}
        self._vdb_attempts: dict[str, int] = {}
        self._want_vdb: dict[str, tuple[str, str, str]] = {}   # atom -> (cat,pkg,ver)
        self._applied: dict[str, tuple[int | None, bool]] = {}
        #: atoms whose USE came from the PLAN PREVIEW rather than a merge-list
        #: display portage printed. Their badges carry PLAN_NOTE.
        self._plan_atoms: set[str] = set()

    # -- plan-preview stream ---------------------------------------------------------
    def feed_plan_line(self, raw_line: str) -> str | None:
        """Index one ``==> Emerge plan:`` wire line, returning the atom it described.

        WHY THIS EXISTS. A normal merge prints NO resolver merge-list at all —
        portage's display is conflict-triggered, which is why USE/USE_EXPAND stayed
        empty on real builds while KEYWORDS/LICENSE (read from the VDB on disk)
        painted fine. Measured on a live 1.37M-line session: zero ``[ebuild …]``
        rows in every emerge group. The plan preview
        (``docs/EMERGE-PLAN-PREVIEW.md``) is the deliberate emission that fixes
        that, and its ``USE="…"`` clause is portage's OWN flag column copied
        verbatim from a ``--pretend`` run of the SAME argv as the merge that
        follows.

        Because it is byte-identical in shape to what a resolver row carries, it is
        re-parsed through ``pf.parse_resolver_line`` and indexed in the SAME
        ResolverIndex — the whole badge pipeline (per-token state, USE_EXPAND
        grouping, multi-slot keying) then applies unchanged rather than growing a
        parallel implementation that could drift from it.

        The atom is remembered as plan-sourced so its badges can say so: a plan is
        portage's PREDICTION for the merge about to run, not a display of what it
        did. A real resolver row for the same atom always wins and clears the mark
        (see ``feed_line``)."""
        from ..core import emerge_packages as ep    # local: avoids an import cycle
        pl = ep.parse_plan_line(raw_line)
        if pl is None or pl.kind != "pkg" or not pl.atom or not pl.use:
            return None
        # Rebuild the exact shape portage prints so ONE parser owns the grammar.
        # NOTE `pl.use` is the flag CONTENTS ("python -compat"), not the whole
        # `USE="…"` clause — parse_plan_line strips the wrapper. Re-adding it is
        # required: without it the resolver parser finds no flag GROUP, returns a row
        # with groups=() and the USE cell comes out empty, which looks exactly like
        # "this package has no flags" rather than a bug.
        # The row KIND is portage's own (issue #46): a plan row the builder marked
        # ``via=binary`` is rebuilt as ``[binary …]``, never as ``[ebuild …]``, so the
        # index can tell a package merged from the binpkg pool from one compiled.
        kind = "binary" if pl.via == "binary" else "ebuild"
        row = pf.parse_resolver_line(f'[{kind}  N     ] {pl.atom} USE="{pl.use}"')
        if row is None or not (row.cat and row.pkg):
            return None
        self._resolver.add(row)
        self._plan_atoms.add(row.cpv)
        self.revision += 1
        return row.cpv

    # -- resolver stream ------------------------------------------------------------
    def feed_line(self, raw_line: str) -> pf.ResolverRow | None:
        """Index one raw stream line IF it is a resolver merge-list row, returning the
        parsed row (else None, which is also the falsy "not a resolver line" answer).

        Fed the RAW line (ANSI intact): a --color=y emission's per-token colour is the
        only thing separating §1.3's states 10/11, and it survives only pre-sanitise.
        Returning the row lets the caller repaint a package whose tree item ALREADY
        exists — with --keep-going portage can re-run the depgraph mid-build and print a
        second merge list, and that display must not be silently dropped."""
        row = pf.parse_resolver_line(raw_line)
        if row is None or row.type not in ("ebuild", "binary"):
            return None
        if not (row.cat and row.pkg):
            return None
        self._resolver.add(row)                      # later display wins (§0c)
        # A row portage actually printed supersedes our prediction, so the atom
        # must stop being labelled plan-sourced — otherwise a confirmed display
        # would keep carrying the 'this is a prediction' caveat forever.
        self._plan_atoms.discard(row.cpv)
        self.revision += 1
        return row

    # -- VDB ------------------------------------------------------------------------
    def _vdb_for(self, atom: str, cat: str | None, pkg: str | None,
                 version: str | None) -> pf.VdbPackage | None:
        rec = self._vdb.get(atom)
        if rec is not None:
            return rec
        if not (self.sysroot and cat and pkg and version):
            return None
        n = self._vdb_attempts.get(atom, 0)
        if n >= _VDB_MAX_ATTEMPTS:
            return None
        self._vdb_attempts[atom] = n + 1
        rec = pf.read_vdb_package(
            os.path.join(self.sysroot, "var", "db", "pkg", cat, f"{pkg}-{version}"))
        if rec is not None:
            self._vdb[atom] = rec
            self._want_vdb.pop(atom, None)
        else:
            self._want_vdb[atom] = (cat, pkg, version)
        return rec

    # -- the join -------------------------------------------------------------------
    def cells_if_changed(self, atom: str) -> dict[str, FlagCell] | None:
        """The four cells for ``atom`` when something NEW is available, else None.

        Resolver row present → USE/USE_EXPAND from it (per-flag state, §5); absent →
        the VDB enabled/disabled fallback. VDB present → KEYWORDS + LICENSE (their
        ONLY source, §2.2). Missing halves are missing cells — the column-hiding
        rule needs the honesty.

        The resolver lookup is by exact cpv (``row_for``), so a multi-slot package
        never shows one slot's flags on another slot's row; where only a collapsed
        ``(cat, pkg)`` match exists and it is ambiguous, the row honestly falls
        back to the VDB rather than displaying the wrong slot."""
        cat, pkg, version, _slot, _repo = pf.split_cpv(atom)
        rr = self._resolver.row_for(atom)
        vdb = self._vdb_for(atom, cat, pkg, version)
        key = (id(rr) if rr is not None else None, vdb is not None)
        if self._applied.get(atom) == key:
            return None
        self._applied[atom] = key
        cells: dict[str, FlagCell] = {}
        if rr is not None:
            rc = resolver_cells(rr, self.descriptions)
            if atom in self._plan_atoms or rr.cpv in self._plan_atoms:
                rc = _annotate_cells(rc, PLAN_NOTE)
                if rr.type == "binary":
                    rc = _annotate_cells(rc, PLAN_BINARY_NOTE)
            cells.update(rc)
        elif vdb is not None:
            cells.update(vdb_use_cells(vdb, self.descriptions))
        if vdb is not None:
            kc = vdb_keywords_cell(vdb)
            if kc is not None:
                cells["KEYWORDS"] = kc
            lc = vdb_license_cell(vdb)
            if lc is not None:
                cells["LICENSE"] = lc
        return cells or None

    def retry_pending(self, limit: int = _VDB_RETRY_PER_TICK
                      ) -> dict[str, dict[str, FlagCell]]:
        """Bounded per-tick retry for atoms whose VDB record was not on disk yet when
        their last step transition looked (portage writes it around the Completed
        line — a real race, not an error). Returns the atoms that newly resolved."""
        out: dict[str, dict[str, FlagCell]] = {}
        for atom in list(self._want_vdb)[:limit]:
            cells = self.cells_if_changed(atom)
            if cells:
                out[atom] = cells
            if self._vdb_attempts.get(atom, 0) >= _VDB_MAX_ATTEMPTS:
                self._want_vdb.pop(atom, None)       # give up quietly, keep the rest
        return out


# ── the selectable hover tip ─────────────────────────────────────────────────────────

_TIP: QtWidgets.QLabel | None = None


def _tip_label() -> QtWidgets.QLabel:
    """One shared, SELECTABLE tooltip window (QToolTip text cannot be selected, and
    the §4.5 URLs are displayed precisely so the operator can copy them)."""
    global _TIP
    if _TIP is None:
        lab = QtWidgets.QLabel(None, Qt.WindowType.ToolTip)
        lab.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        lab.setTextFormat(Qt.TextFormat.PlainText)
        lab.setWordWrap(True)
        lab.setMargin(8)
        lab.setMaximumWidth(560)
        lab.setFrameShape(QtWidgets.QFrame.Shape.StyledPanel)
        _TIP = lab
    return _TIP


def show_tip(text: str, anchor, global_pos) -> None:
    """Show the shared selectable tip at ``global_pos``, ANCHORED so Wayland can place it.

    Under X11 a client may position any top-level, so ``move()`` alone was enough. Under
    Wayland it is not: a parentless top-level surface has no placement protocol at all,
    so ``move()`` is accepted and silently ignored, and the tip lands wherever the
    compositor decides — usually the last place it was shown, which reads as "the wrong
    tooltip is stuck on screen".

    Giving the popup a TRANSIENT PARENT is what fixes it: an xdg_popup is positioned
    RELATIVE to a parent surface, so once Qt knows which window this tip belongs to it
    can translate the move into a positioner the compositor honours. On X11 the transient
    parent is merely a hint and the behaviour is unchanged, which is why this is done
    unconditionally rather than branched on the session — one code path, no
    platform-specific drift.

    We deliberately keep the custom QLabel rather than falling back to QToolTip on
    Wayland: QToolTip positions itself correctly there, but its text cannot be SELECTED,
    and being able to copy the §4.5 URLs out of the tip is the entire reason this widget
    exists.
    """
    tip = _tip_label()
    tip.setText(text)
    tip.adjustSize()
    try:
        tip.createWinId()               # a windowHandle only exists once created
        handle = tip.windowHandle()
        parent_win = None
        if anchor is not None:
            win = anchor.window()
            parent_win = win.windowHandle() if win is not None else None
        if handle is not None and parent_win is not None \
                and handle.transientParent() is not parent_win:
            handle.setTransientParent(parent_win)
    except (AttributeError, RuntimeError):
        # Dead C++ wrapper or a platform with no window handle (offscreen): the tip is
        # cosmetic, so degrade to an unanchored show rather than taking the page down.
        pass
    tip.move(global_pos)
    tip.show()


def hide_tip() -> None:
    """Hide the shared tip. Guarded: this is reached from page resets and teardown
    paths, where the underlying C++ widget may already be gone — and under PyQt6 a
    RuntimeError from a dead wrapper inside a Qt slot would abort the Studio."""
    global _TIP
    try:
        if _TIP is not None and _TIP.isVisible():
            _TIP.hide()
    except RuntimeError:            # wrapped C++ object deleted — nothing left to hide
        _TIP = None


# ── the delegate ─────────────────────────────────────────────────────────────────────

class FlagBadgeDelegate(QtWidgets.QStyledItemDelegate):
    """Paints a cell's badges (no per-badge child widgets — 300+ packages × four
    columns must stay one delegate) and answers hover per badge via helpEvent
    hit-testing. Every virtual is exception-guarded: the operator runs PyQt6,
    where an exception escaping into Qt aborts the Studio."""

    _PAD_X = 4       # cell left padding
    _GAP = 4         # gap between chips
    _CHIP_PAD = 5    # horizontal padding inside a chip
    _RADIUS = 4

    _LINE_GAP = 2    # vertical gap between wrapped badge rows

    # -- geometry (shared by paint / helpEvent / sizeHint) ---------------------------
    def layout_badges(self, rect: QtCore.QRect, font: QtGui.QFont,
                      cell: FlagCell,
                      wrap_width: int = 0) -> list[tuple[QtCore.QRect, Badge]]:
        """Badge rects for one cell.

        With ``wrap_width > 0`` badges FLOW onto as many lines as they need and the
        block is top-aligned; the caller (``sizeHint``) grows the row to fit, so a
        package with thirty flags shows all thirty instead of silently clipping the
        tail at the column edge. The operator asked for exactly that, and the
        previous single-line layout was the reason a wide flag set looked truncated.

        With ``wrap_width == 0`` the old single-line, vertically-centred behaviour is
        kept — that is what a caller wants when it has no column width to wrap to.

        This is the ONE geometry function behind paint, hover hit-testing and
        sizeHint, so wrapping cannot desynchronise the three: a badge is painted
        where the size was reserved and where the tooltip probe looks for it."""
        fm = QtGui.QFontMetrics(font)
        ch = fm.height() + 2
        widths = [fm.horizontalAdvance(b.text) + 2 * self._CHIP_PAD
                  for b in cell.badges]
        # Usable width inside the cell; never let a pathologically narrow column
        # produce a zero/negative budget (that would put every badge on its own line
        # AND still overflow) — fall back to single-line rather than lay out garbage.
        avail = wrap_width - 2 * self._PAD_X if wrap_width > 0 else 0
        if avail <= 0 or not widths:
            y = rect.y() + max(0, (rect.height() - ch) // 2)
            x = rect.x() + self._PAD_X
            out = []
            for badge, w in zip(cell.badges, widths):
                out.append((QtCore.QRect(x, y, w, ch), badge))
                x += w + self._GAP
            return out

        out = []
        x = rect.x() + self._PAD_X
        y = rect.y() + self._PAD_X
        line_x = 0
        for badge, w in zip(cell.badges, widths):
            # Wrap BEFORE placing when this badge would overflow — but never wrap a
            # line that is still empty, or a badge wider than the whole column would
            # loop forever placing nothing.
            if line_x > 0 and line_x + w > avail:
                y += ch + self._LINE_GAP
                x = rect.x() + self._PAD_X
                line_x = 0
            out.append((QtCore.QRect(x, y, w, ch), badge))
            x += w + self._GAP
            line_x += w + self._GAP
        return out

    def _wrap_width_for(self, index) -> int:
        """The column's real on-screen width, which is what badges must wrap to.
        ``option.rect`` is not usable for this inside sizeHint (Qt asks for a size
        before it has a final rect), so ask the view's header directly."""
        try:
            view = self.parent()
            width = int(view.columnWidth(index.column()))
            return width if width > 0 else 0
        except Exception:        # noqa: BLE001 — no view, or not a column-ed view
            return 0

    def badge_at(self, cell: FlagCell, rect: QtCore.QRect, font: QtGui.QFont,
                 pos: QtCore.QPoint) -> Badge | None:
        # Same wrap width the painter used (the cell rect), so the hover probe finds
        # a badge exactly where it was drawn — including on wrapped lines.
        for r, badge in self.layout_badges(rect, font, cell,
                                           wrap_width=rect.width()):
            if r.contains(pos):
                return badge
        return None

    @staticmethod
    def _cell(index) -> FlagCell | None:
        data = index.data(CELL_ROLE)
        return data if isinstance(data, FlagCell) else None

    # -- painting --------------------------------------------------------------------
    def paint(self, painter, option, index) -> None:  # noqa: N802 (Qt virtual)
        try:
            cell = self._cell(index)
            opt = QtWidgets.QStyleOptionViewItem(option)
            self.initStyleOption(opt, index)
            opt.text = ""        # background/selection only; badges replace the text
            widget = getattr(opt, "widget", None)
            style = widget.style() if widget is not None \
                else QtWidgets.QApplication.style()
            style.drawControl(QtWidgets.QStyle.ControlElement.CE_ItemViewItem,
                              opt, painter, widget)
            if cell is None:
                return
            painter.save()
            painter.setClipRect(option.rect)
            painter.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing, True)
            for rect, badge in self.layout_badges(option.rect, option.font, cell,
                                                  wrap_width=option.rect.width()):
                self._paint_badge(painter, rect, option.font, badge)
            painter.restore()
        except Exception:        # noqa: BLE001 — PyQt6: an escape here aborts the app
            return

    def _paint_badge(self, painter, rect: QtCore.QRect, base_font: QtGui.QFont,
                     badge: Badge) -> None:
        colour = QtGui.QColor(badge.colour)
        rf = QtCore.QRectF(rect).adjusted(0.5, 0.5, -0.5, -0.5)
        if badge.outlined:
            # §5 modifier: outlined, not filled — "you did not choose this".
            painter.setPen(QtGui.QPen(colour, 1))
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawRoundedRect(rf, self._RADIUS, self._RADIUS)
            painter.setPen(QtGui.QPen(colour))
        else:
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QtGui.QBrush(colour))
            painter.drawRoundedRect(rf, self._RADIUS, self._RADIUS)
            painter.setPen(QtGui.QPen(QtGui.QColor("#ffffff")))
        font = QtGui.QFont(base_font)
        font.setStrikeOut(badge.strike)
        painter.setFont(font)
        painter.drawText(rect, Qt.AlignmentFlag.AlignCenter, badge.text)

    def sizeHint(self, option, index):  # noqa: N802 (Qt virtual)
        try:
            cell = self._cell(index)
            if cell is None:
                return super().sizeHint(option, index)
            fm = QtGui.QFontMetrics(option.font)
            wrap = self._wrap_width_for(index)
            if wrap <= 0:
                # No column width to wrap to: the pre-wrap behaviour (one line, as
                # wide as the badges need).
                w = self._PAD_X + sum(
                    fm.horizontalAdvance(b.text) + 2 * self._CHIP_PAD + self._GAP
                    for b in cell.badges)
                return QtCore.QSize(w, fm.height() + 8)
            # Lay the badges out for real and reserve the height they actually
            # occupy, so the row GROWS to fit every badge instead of clipping the
            # tail. Measured from the same layout_badges the painter uses, not from
            # a parallel estimate that could drift away from it.
            rects = self.layout_badges(QtCore.QRect(0, 0, wrap, 0),
                                       option.font, cell, wrap_width=wrap)
            if not rects:
                return QtCore.QSize(wrap, fm.height() + 8)
            bottom = max(r.bottom() for r, _ in rects)
            return QtCore.QSize(wrap, bottom + self._PAD_X + 1)
        except Exception:        # noqa: BLE001
            return super().sizeHint(option, index)

    # -- hover: per-badge hit-testing ------------------------------------------------
    def helpEvent(self, event, view, option, index) -> bool:  # noqa: N802
        try:
            if event.type() != QtCore.QEvent.Type.ToolTip:
                return super().helpEvent(event, view, option, index)
            cell = self._cell(index)
            if cell is None:
                hide_tip()
                return super().helpEvent(event, view, option, index)
            badge = self.badge_at(cell, view.visualRect(index), option.font,
                                  event.pos())
            if badge is None:
                hide_tip()
                return False
            show_tip(badge.tooltip, view, event.globalPos() + QtCore.QPoint(12, 12))
            return True
        except Exception:        # noqa: BLE001 — see paint()
            return False

    # -- housekeeping: hide the tip when the pointer leaves the tree ------------------
    def eventFilter(self, obj, event) -> bool:  # noqa: N802
        try:
            if event.type() in (QtCore.QEvent.Type.Leave,
                                QtCore.QEvent.Type.MouseButtonPress,
                                QtCore.QEvent.Type.Wheel,
                                QtCore.QEvent.Type.Hide):
                hide_tip()
        except Exception:        # noqa: BLE001
            pass
        return False             # never consumes — observation only


# ── the column controller ────────────────────────────────────────────────────────────

class FlagColumns:
    """Owns the four flag columns of one tree: installs the shared delegate, hides
    every column until the first row gives it content (§5: empty column ⇒ no
    column), and stores each cell's verbatim ``KEY="…"`` text as the item's display
    text so selection/copy yields exactly what portage printed."""

    def __init__(self, tree: QtWidgets.QTreeWidget, columns: dict[str, int]) -> None:
        self.tree = tree
        self.columns = dict(columns)
        self.delegate = FlagBadgeDelegate(tree)
        for col in self.columns.values():
            tree.setItemDelegateForColumn(col, self.delegate)
        tree.viewport().installEventFilter(self.delegate)   # hover-tip housekeeping
        self._has_content: dict[str, bool] = {}
        #: Operator overrides from the Configure-view dialog: True = always show,
        #: False = always hide, key absent = AUTO (reveal on first content). The
        #: dialog has to be able to beat the auto-hide in BOTH directions, or an
        #: operator who ticks a column watches nothing happen because no row has
        #: supplied that flag yet.
        self._override: dict[str, bool] = {}
        # Badge rows are wrapped to the column width, so a resize changes how many
        # lines a cell needs. Without this the row heights keep the width they were
        # first laid out at and wrapped badges get clipped after a drag.
        try:
            tree.header().sectionResized.connect(self._on_section_resized)
        except Exception:        # noqa: BLE001 — headerless view
            pass
        self.reset()

    def _on_section_resized(self, *_args) -> None:
        try:
            self.tree.scheduleDelayedItemsLayout()
        except Exception:        # noqa: BLE001 — PyQt6: never let a slot raise
            pass

    # -- operator column overrides (Configure view) ----------------------------------
    def set_override(self, key: str, visible: bool | None) -> None:
        """Pin a flag column visible/hidden, or hand it back to AUTO with None."""
        if key not in self.columns:
            return
        if visible is None:
            self._override.pop(key, None)
        else:
            self._override[key] = bool(visible)
        self._sync(key)

    def override(self, key: str) -> bool | None:
        return self._override.get(key)

    def is_visible(self, key: str) -> bool:
        col = self.columns.get(key)
        if col is None:
            return False
        return not self.tree.isColumnHidden(col)

    def _sync(self, key: str) -> None:
        """Apply override-then-auto for one column."""
        col = self.columns.get(key)
        if col is None:
            return
        pinned = self._override.get(key)
        shown = pinned if pinned is not None else self._has_content.get(key, False)
        try:
            self.tree.setColumnHidden(col, not shown)
        except Exception:        # noqa: BLE001
            pass

    def reset(self) -> None:
        """Back to the empty state: every AUTO column hidden again (a fresh run must
        not show last run's columns).

        Operator overrides deliberately SURVIVE a reset — an explicit "show LICENSE"
        is a view preference, not run state, and silently revoking it on the next
        build would look like the dialog forgot the setting."""
        self._has_content = {key: False for key in self.columns}
        for key in self.columns:
            self._sync(key)
        hide_tip()

    def apply(self, item: QtWidgets.QTreeWidgetItem,
              cells: dict[str, FlagCell]) -> None:
        """Attach cells to one package row and reveal each newly non-empty column.
        A key absent from ``cells`` leaves that cell (and possibly its column)
        untouched — an individually empty cell just stays empty."""
        for key, col in self.columns.items():
            cell = cells.get(key)
            if cell is None:
                continue
            item.setData(col, CELL_ROLE, cell)
            item.setText(col, cell.copy_text)       # the copy path (verbatim tokens)
            # A cell with no badges is a package whose flags were ALL filtered out of
            # the view (see _interesting). It still carries verbatim_text for the copy
            # action, but it is NOT content: revealing the column for it would show the
            # operator an empty column, which is the clutter the filter exists to remove.
            if cell.badges and not self._has_content.get(key):
                self._has_content[key] = True
                # _sync, not setColumnHidden(False): a column the operator has
                # explicitly hidden must STAY hidden when content finally arrives,
                # otherwise the first package with that flag silently undoes their
                # choice mid-build.
                self._sync(key)

    def copy_text_for(self, item: QtWidgets.QTreeWidgetItem) -> str:
        """The row's VERBATIM flag text across all four columns — §5's copy guarantee.

        Reads the stored :class:`FlagCell` rather than the item's display text on
        purpose: the USE column HIDES uninteresting always-off flags (see
        ``_interesting``), so the display text is a filtered view while this must
        stay the full string portage itself would print. Falls back to the display
        text for any cell that predates the stored-object path."""
        parts = []
        for key in FLAG_COLUMNS:
            col = self.columns.get(key)
            if col is None:
                continue
            cell = item.data(col, CELL_ROLE)
            text = getattr(cell, "verbatim_text", "") or item.text(col)
            if text:
                parts.append(text)
        return " ".join(parts)
