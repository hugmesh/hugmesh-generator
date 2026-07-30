"""package_flags — Qt-free data layer for the per-package flag badges.

Ground truth is ``docs/PACKAGE-FLAG-BADGES.md`` (derived from portage 3.0.81.2's
own source plus real fleet logs). This module implements its four data legs:

* **Resolver-row parsing** (§2): one ``[ebuild …]`` / ``[binary …]`` line →
  type, decoded 7-char attrs, cpv/cat/pkg/version/slot/repo, and the ordered
  ``KEY="…"`` flag groups (plain ``USE`` is just the first group). Input may be
  plain text (our captured logs — colour is stripped by the pipe, §1.3) or
  ``--color=y`` ANSI. ANSI is stripped for the verbatim tokens but the colour is
  RETAINED per token, because plain ``(-f)`` is a real two-way collision
  (states 10/11, §1.3) that only colour separates.
* **Flag-token classification** (§1.1's 11 states → §5's 6 display states plus
  the forced/masked modifier). Portage's emitted order is preserved — position
  is information (§1.2); nothing here sorts.
* **VDB reading** (§3): ``<sysroot>/var/db/pkg/<cat>/<pf>/{KEYWORDS,LICENSE,…}``
  one-line files → per-package records. Missing files are DATA (68/319 real
  packages have no LICENSE): the field is simply ``None`` and the GUI shows no
  column.
* **Offline flag descriptions** (§4): ``profiles/use.desc``,
  ``use.local.desc`` and ``profiles/desc/*.desc`` (the 52 filenames ARE the
  USE_EXPAND group list), lazily parsed and size-bounded, plus the §4.4 sidecar
  JSON (``{"cat/pkg:flag" | "*:flag" | "@GROUP:flag" → description}``) which a
  future build-time Emit phase drops next to the session so archived sessions
  keep hover text on any machine. The sidecar always wins over the host tree.

HARD RULE (§4.5): the Studio never touches the network. URLs may be built and
displayed elsewhere; nothing in this module imports urllib/requests/QNetwork
and nothing here performs I/O beyond reading local files it was pointed at.
"""
from __future__ import annotations

import dataclasses
import gzip
import json
import os
import re
from typing import Iterable, Iterator

# ── ANSI (§1.3) ──────────────────────────────────────────────────────────────────────
# emerge --color=y uses a stable four-value alphabet for flag states
# (portage/output.py codes, verified by driving colorize() directly).
ANSI_COLOUR_ALPHABET = {
    "31;01": "red",     # enabled, unchanged
    "32;01": "green",   # transition (* — turning on or off)
    "33;01": "yellow",  # % axis (newly in / removed from IUSE)
    "34;01": "blue",    # disabled, unchanged
}

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def strip_ansi(text: str) -> str:
    """Remove ANSI escape sequences, keeping every printable byte."""
    return _ANSI_RE.sub("", text)


# ── flag-token classification (§1.1 → §5) ────────────────────────────────────────────

#: The six §5 display states. ``forced_masked`` is a modifier, not a 7th state.
DISPLAY_STATES = (
    "enabled-unchanged",   # f      — §5 #1
    "disabled-unchanged",  # -f     — §5 #2
    "turning-on",          # f*     — §5 #3
    "turning-off",         # -f*    — §5 #4
    "new-in-iuse",         # f%* / -f%  — §5 #5 (compose with changed for the triangle)
    "removed",             # (-f%) / (-f%*) — §5 #6
)


@dataclasses.dataclass(frozen=True)
class FlagToken:
    """One flag as portage printed it, decoded but never re-ordered."""

    name: str                 # bare flag name as printed (USE_EXPAND prefix stripped by portage)
    verbatim: str             # the exact plain-text token portage printed (ANSI stripped)
    enabled: bool             # no '-' prefix
    changed: bool             # '*' suffix — flipped state since the last merge
    new_in_iuse: bool | None  # '%' axis; None == honestly unknown (plain "(-f)", §1.3)
    removed: bool             # parens + '%' — gone from the new version's IUSE
    forced_masked: bool       # parens without '%' — profile use.force/use.mask
    colour_seen: str | None   # red/green/yellow/blue when the input carried ANSI
    display_state: str        # one of DISPLAY_STATES
    ambiguous: bool           # True only for colourless "(-f)": states 10/11 collide


# One whitespace-separated token, plain or ANSI. Colour wraps sign+name; the
# %/* suffixes and the parens sit OUTSIDE the escape (fixture-verified shapes
# like "(\x1b[33;01m-f\x1b[39;49;00m%*)").
_TOKEN_RE = re.compile(
    r"^(?P<open>\()?"
    r"(?:\x1b\[(?P<col>[0-9;]+)m)?"
    r"(?P<sign>-)?"
    r"(?P<name>[^\s()%*\x1b]+)"
    r"(?:\x1b\[[0-9;]+m)?"
    r"(?P<suffix>[%*]{0,2})"
    r"(?P<close>\))?$"
)


def classify_flag_token(token: str) -> FlagToken | None:
    """Decode one flag token (plain or ANSI) into a :class:`FlagToken`.

    Returns None when the text is not a flag token at all.
    """
    m = _TOKEN_RE.match(token)
    if not m or bool(m.group("open")) != bool(m.group("close")):
        return None
    paren = bool(m.group("open"))
    enabled = m.group("sign") is None
    suffix = m.group("suffix")
    changed = "*" in suffix
    has_pct = "%" in suffix
    colour = None
    if m.group("col") is not None:
        colour = ANSI_COLOUR_ALPHABET.get(m.group("col"), m.group("col"))

    # THE SIGN IS THE DISCRIMINATOR. portage's removed-from-IUSE branch
    # (output_helpers.py:302-309) builds its own parens around a token that
    # ALWAYS carries the '-' prefix — "(-f%)" / "(-f%*)" — and then `continue`s,
    # so it never reaches the iuse_forced wrap. A parenthesised token with '%'
    # and NO '-' therefore cannot be a removal: it is the ENABLED branch's
    # `yellow(flag) + "%*"` (:295-296, newly in IUSE) wrapped by the iuse_forced
    # paren at :324-325 — i.e. "(f%*)" = profile-forced + newly in IUSE + on.
    removed = paren and has_pct and not enabled   # states 7/8: (-f%) / (-f%*)
    forced_masked = paren and not removed        # the iuse_forced wrap: (f) (-f)
                                                 # (f*) (-f*) (f%*)
    ambiguous = False
    if removed:
        new_in_iuse = False                     # '%' here means REMOVED, not new
    elif has_pct:
        # Outside the removed branch, '%' only ever means NEWLY ADDED to IUSE:
        # states 5/6 (f%* / -f%) and the forced-and-new (f%*).
        new_in_iuse = True
    elif not paren:
        new_in_iuse = False
    elif colour == "yellow":
        new_in_iuse = True                      # state 11
    elif colour in ANSI_COLOUR_ALPHABET.values():
        new_in_iuse = False                     # red/blue/green all imply "not new"
    elif changed:
        # "(f*)" / "(-f*)": the '*' can only come from the green transition
        # branches (:297 / :318), both of which require the flag to have been in
        # the OLD iuse — so it is structurally impossible for it to also be new.
        new_in_iuse = False
    elif enabled:
        new_in_iuse = False                     # "(f)" — only red's branch emits it
    else:
        # The one genuine §1.3 collision: a bare colourless "(-f)" is either
        # blue (masked, unchanged) or yellow (masked AND newly in IUSE) — portage
        # suppresses '%' inside parens for forced flags (:318-321).
        new_in_iuse = None
        ambiguous = True

    if removed:
        display_state = "removed"
    elif new_in_iuse:
        display_state = "new-in-iuse"
    elif changed:
        display_state = "turning-on" if enabled else "turning-off"
    elif enabled:
        display_state = "enabled-unchanged"
    else:
        display_state = "disabled-unchanged"

    return FlagToken(
        name=m.group("name"),
        verbatim=strip_ansi(token),
        enabled=enabled,
        changed=changed,
        new_in_iuse=new_in_iuse,
        removed=removed,
        forced_masked=forced_masked,
        colour_seen=colour,
        display_state=display_state,
        ambiguous=ambiguous,
    )


# ── flag groups (§2.1) ───────────────────────────────────────────────────────────────

@dataclasses.dataclass(frozen=True)
class FlagGroup:
    """One ``KEY="…"`` block, order preserved. ``USE`` is always the first."""

    key: str                        # USE, ABI_X86, PYTHON_TARGETS, …
    raw: str                        # the whole plain-text KEY="…" block as printed
    tokens: tuple[FlagToken, ...]   # in portage's emitted order — NEVER sorted (§1.2)

    def verbatim_value(self) -> str:
        """Join the tokens back into the quoted value — the copy-paste guarantee."""
        return " ".join(t.verbatim for t in self.tokens)


# Keys are plain ALL-CAPS even under --color=y (colour lives inside the quotes).
_GROUP_RE = re.compile(r'(?P<key>[A-Z][A-Z0-9_]*)="(?P<val>[^"]*)"')


def parse_flag_groups(text: str) -> tuple[FlagGroup, ...]:
    """Extract every ``KEY="…"`` group from a fragment (plain or ANSI)."""
    groups = []
    for m in _GROUP_RE.finditer(text):
        tokens = []
        for raw_tok in m.group("val").split():
            tok = classify_flag_token(raw_tok)
            if tok is not None:
                tokens.append(tok)
        groups.append(FlagGroup(
            key=m.group("key"),
            raw=strip_ansi(m.group(0)),
            tokens=tuple(tokens),
        ))
    return tuple(groups)


# ── resolver-row parsing (§2) ────────────────────────────────────────────────────────

@dataclasses.dataclass(frozen=True)
class PkgAttrs:
    """The decoded 7-char positional attrs field (§2.1's table)."""

    raw: str                    # verbatim 7 chars (6 under --quiet, right-padded here)
    interactive: bool           # pos 1: I
    new: bool                   # pos 2: N
    forced_reinstall: bool      # pos 2: r
    new_slot: bool              # pos 3: S
    replacing: bool             # pos 3: R
    fetch: str | None           # pos 4: fetch-satisfied / fetch-restricted / remote-binary
    upgrade: bool               # pos 5: U
    downgrade: bool             # pos 6: D
    mask: str | None            # pos 7: package.mask / missing-keyword / unstable-keyword


_FETCH_CODES = {"f": "fetch-satisfied", "F": "fetch-restricted", "g": "remote-binary"}
_MASK_CODES = {"#": "package.mask", "*": "missing-keyword", "~": "unstable-keyword"}
# Per-position legal characters (space = unset). Position 7 vanishes at --quiet.
_ATTR_ALLOWED = ("I ", "Nr ", "SR ", "fFg ", "U ", "D ", "#*~ ")


def _attrs_valid(attrs: str) -> bool:
    if len(attrs) not in (6, 7):
        return False
    return all(ch in ok for ch, ok in zip(attrs.ljust(7), _ATTR_ALLOWED))


def _decode_attrs(attrs: str) -> PkgAttrs:
    a = attrs.ljust(7)
    return PkgAttrs(
        raw=attrs,
        interactive=a[0] == "I",
        new=a[1] == "N",
        forced_reinstall=a[1] == "r",
        new_slot=a[2] == "S",
        replacing=a[2] == "R",
        fetch=_FETCH_CODES.get(a[3]),
        upgrade=a[4] == "U",
        downgrade=a[5] == "D",
        mask=_MASK_CODES.get(a[6]),
    )


@dataclasses.dataclass(frozen=True)
class ResolverRow:
    """One parsed merge-list row."""

    type: str                          # ebuild / binary / nomerge / blocks / uninstall
    attrs: PkgAttrs
    cpv: str                           # cat/pkg-version (slot/repo split off)
    cat: str | None
    pkg: str | None
    version: str | None
    slot: str | None                   # only present at -v (":slot")
    repo: str | None                   # only present at -v ("::repo")
    old_versions: tuple[str, ...]      # the trailing "[1.9.8]" / "[a, b, c]" bracket
    groups: tuple[FlagGroup, ...]      # ordered; USE (when present) is first
    line: str                          # the whole row, ANSI stripped

    @property
    def cat_pkg(self) -> str | None:
        return f"{self.cat}/{self.pkg}" if self.cat and self.pkg else None

    def group(self, key: str) -> FlagGroup | None:
        for g in self.groups:
            if g.key == key:
                return g
        return None


_ROW_TYPES = ("ebuild", "binary", "nomerge", "blocks", "uninstall")
_LINE_RE = re.compile(
    r"^\[(?P<type>" + "|".join(_ROW_TYPES) + r")(?P<attrs>[^\]]*)\]\s?(?P<rest>.*)$"
)
# Package version split: version starts at the first '-' followed by a digit and
# must be a well-formed PMS version through end-of-string ("go-bootstrap-1.24.6"
# → "go-bootstrap" + "1.24.6"; "perl-MIME-Base64-3.160.100_rc-r3" survives).
_PV_RE = re.compile(
    r"^(?P<pn>.+?)-(?P<pv>\d[\d.]*[a-z]?(?:_(?:alpha|beta|pre|rc|p)\d*)*(?:-r\d+)?)$"
)
_OLD_VER_RE = re.compile(r"^\s*\[(?P<old>[^\]]*)\]")


def plain_cpv(atom: str) -> str:
    """``cat/pkg-ver[:slot][::repo]`` (or a blocker atom) → the bare ``cat/pkg-ver``.

    This is the EXACT key resolver rows are stored under, so a lookup by it can
    never confuse two slots of the same package (``dev-lang/python-3.13.14`` vs
    ``dev-lang/python-3.14.6`` — both real in this fleet's own sysroots).
    """
    return atom.partition("::")[0].partition(":")[0].lstrip("<>=!~").strip()


def split_cpv(cpv_token: str) -> tuple[str | None, str | None, str | None, str | None, str | None]:
    """``cat/pkg-ver[:slot][::repo]`` → (cat, pkg, version, slot, repo). Tolerant."""
    base, _, repo = cpv_token.partition("::")
    repo = repo or None
    slot = None
    if ":" in base:
        base, _, slot = base.partition(":")
        slot = slot or None
    base = base.lstrip("<>=!~")   # blocks rows carry an atom operator prefix
    cat, sep, pv = base.partition("/")
    if not sep:
        return None, None, None, slot, repo
    m = _PV_RE.match(pv)
    if m:
        return cat, m.group("pn"), m.group("pv"), slot, repo
    return cat, pv, None, slot, repo


def parse_resolver_line(line: str) -> ResolverRow | None:
    """Parse one resolver row (plain or ANSI). Returns None for any other line."""
    raw = line.rstrip("\r\n")
    plain = strip_ansi(raw)
    m = _LINE_RE.match(plain)
    if m is None:
        return None
    attrs = m.group("attrs")
    if attrs.startswith(" "):        # the single separator space after the type
        attrs = attrs[1:]
    if m.group("type") in ("ebuild", "binary") and not _attrs_valid(attrs):
        return None
    rest = m.group("rest").strip()
    if not rest:
        return None
    cpv_token = rest.split()[0]
    if "/" not in cpv_token:
        return None
    cat, pkg, version, slot, repo = split_cpv(cpv_token)
    cpv_plain = plain_cpv(cpv_token)

    after = rest[len(cpv_token):]
    old_versions: tuple[str, ...] = ()
    m_old = _OLD_VER_RE.match(after)
    if m_old:
        old_versions = tuple(v.strip() for v in m_old.group("old").split(",") if v.strip())

    # Groups come from the RAW text so per-token colour survives (§1.3).
    groups = parse_flag_groups(raw)

    return ResolverRow(
        type=m.group("type"),
        attrs=_decode_attrs(attrs),
        cpv=cpv_plain,
        cat=cat,
        pkg=pkg,
        version=version,
        slot=slot,
        repo=repo,
        old_versions=old_versions,
        groups=groups,
        line=plain,
    )


# ── block extraction (§0(c): the display is conflict-triggered, so scrape honestly) ──

@dataclasses.dataclass(frozen=True)
class ResolverBlock:
    """A maximal run of consecutive resolver rows in a log."""

    first_line: int                  # 0-based index into the iterable fed in
    last_line: int
    rows: tuple[ResolverRow, ...]


def iter_resolver_blocks(lines: Iterable[str]) -> Iterator[ResolverBlock]:
    """Scan log lines and yield each contiguous resolver block."""
    rows: list[ResolverRow] = []
    start = 0
    for i, raw in enumerate(lines):
        row = parse_resolver_line(raw)
        if row is not None:
            if not rows:
                start = i
            rows.append(row)
        elif rows:
            yield ResolverBlock(first_line=start, last_line=i - 1, rows=tuple(rows))
            rows = []
    if rows:
        yield ResolverBlock(first_line=start, last_line=start + len(rows) - 1,
                            rows=tuple(rows))


class ResolverIndex:
    """Resolver rows keyed by EXACT cpv, with a ``(cat, pkg)`` fallback that stops
    answering as soon as the same package appears at more than one version.

    A ``-v`` merge list lists **each slot as its own row**, so a ``(cat, pkg)``
    key silently collapses them and the last row wins for every slot. That is not
    hypothetical for this fleet: its captured sysroots carry ``dev-lang/python``
    at two slots and ``app-text/docbook-xml-dtd`` at four, and its own logs carry
    the slotted row ``[ebuild  NS    ] app-text/docbook-xml-dtd-4.4-r3 [4.1.2-r7,
    4.2-r3, 4.5-r2]``. Showing one slot's USE flags on another slot's row is a
    confident lie, so the fallback refuses rather than guesses — the exact-cpv
    key still answers for every atom that actually names its version.

    Re-feeding the SAME cpv is not ambiguity: with ``--keep-going`` portage can
    re-run the depgraph and print a second merge list, and its later row must win
    (§0c).
    """

    def __init__(self) -> None:
        self.by_cpv: dict[str, ResolverRow] = {}
        #: (cat, pkg) → the single cpv seen for it, or None once several were.
        self._cat_pkg: dict[tuple[str, str], str | None] = {}

    def __len__(self) -> int:
        return len(self.by_cpv)

    def add(self, row: ResolverRow) -> None:
        if row.cpv:
            self.by_cpv[row.cpv] = row          # later display wins (§0c)
        if not (row.cat and row.pkg and row.cpv):
            return
        key = (row.cat, row.pkg)
        if key not in self._cat_pkg:
            self._cat_pkg[key] = row.cpv
        elif self._cat_pkg[key] != row.cpv:
            self._cat_pkg[key] = None           # multi-slot: refuse to guess

    def row_for(self, atom: str) -> ResolverRow | None:
        """The row for one merge atom: exact cpv first, then the ``(cat, pkg)``
        fallback ONLY where it is unambiguous. None when nothing can be said."""
        row = self.by_cpv.get(plain_cpv(atom))
        if row is not None:
            return row
        cat, pkg, _v, _s, _r = split_cpv(atom)
        if not (cat and pkg):
            return None
        cpv = self._cat_pkg.get((cat, pkg))
        return self.by_cpv.get(cpv) if cpv else None

    @property
    def multi_slot(self) -> frozenset[tuple[str, str]]:
        """The ``(cat, pkg)`` pairs seen at more than one version — the ones whose
        fallback is deliberately switched off."""
        return frozenset(k for k, v in self._cat_pkg.items() if v is None)

    @property
    def by_cat_pkg(self) -> dict[tuple[str, str], ResolverRow]:
        """Unambiguous ``(cat, pkg)`` entries only. Multi-slot packages are absent
        on purpose — use :meth:`row_for` (or ``by_cpv``) for those."""
        return {k: self.by_cpv[v] for k, v in self._cat_pkg.items()
                if v is not None and v in self.by_cpv}


@dataclasses.dataclass(frozen=True)
class FlagIndex:
    """Per-package resolver records keyed for joining onto the emerge tree."""

    by_cat_pkg: dict[tuple[str, str], ResolverRow]
    by_cpv: dict[str, ResolverRow]
    blocks: tuple[ResolverBlock, ...]
    #: (cat, pkg) pairs listed at several versions — deliberately NOT in
    #: ``by_cat_pkg``, because one slot's flags are not another slot's flags.
    multi_slot: frozenset[tuple[str, str]] = frozenset()

    def row_for(self, atom: str) -> ResolverRow | None:
        """Exact cpv first; the ``(cat, pkg)`` fallback only when unambiguous."""
        row = self.by_cpv.get(plain_cpv(atom))
        if row is not None:
            return row
        cat, pkg, _v, _s, _r = split_cpv(atom)
        if not (cat and pkg) or (cat, pkg) in self.multi_slot:
            return None
        return self.by_cat_pkg.get((cat, pkg))


def build_flag_index(lines: Iterable[str]) -> FlagIndex:
    """Index every resolver row in a log. A later block overrides an earlier one
    (the last resolver display is the one the merge acted on)."""
    index = ResolverIndex()
    blocks = []
    for block in iter_resolver_blocks(lines):
        blocks.append(block)
        for row in block.rows:
            index.add(row)
    return FlagIndex(by_cat_pkg=index.by_cat_pkg, by_cpv=index.by_cpv,
                     blocks=tuple(blocks), multi_slot=index.multi_slot)


# ── VDB reading (§3) ─────────────────────────────────────────────────────────────────

#: The one-line files the badge columns come from. LICENSE/KEYWORDS are NOT in
#: the resolver line at all (§2.2) — the VDB is their only captured source.
VDB_FIELDS = ("KEYWORDS", "LICENSE", "IUSE", "USE", "DESCRIPTION", "SLOT", "repository")

_MAX_VDB_FILE_BYTES = 1 * 1024 * 1024    # real files are ≤ a few KB; refuse absurdity


@dataclasses.dataclass(frozen=True)
class VdbPackage:
    """One merged package's VDB record. A missing file is DATA (§3): 68/319 real
    packages have no LICENSE — the field stays None and the GUI shows no column."""

    cat: str
    pf: str                       # full package-version dir name, e.g. elfutils-0.195
    pkg: str
    version: str | None
    keywords: str | None
    license: str | None
    iuse: str | None
    use: str | None
    description: str | None
    slot: str | None
    repository: str | None

    @property
    def cpv(self) -> str:
        return f"{self.cat}/{self.pf}"

    @property
    def cat_pkg(self) -> str:
        return f"{self.cat}/{self.pkg}"

    @property
    def keywords_list(self) -> tuple[str, ...]:
        return tuple((self.keywords or "").split())

    @property
    def iuse_names(self) -> tuple[str, ...]:
        """IUSE entries with the '+'-default marker stripped, order preserved."""
        return tuple(f.lstrip("+-") for f in (self.iuse or "").split())

    @property
    def use_list(self) -> tuple[str, ...]:
        return tuple((self.use or "").split())


def _read_vdb_file(path: str) -> str | None:
    try:
        if os.path.getsize(path) > _MAX_VDB_FILE_BYTES:
            return None
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return None


def read_vdb_package(pkg_dir: str) -> VdbPackage | None:
    """Read one ``…/var/db/pkg/<cat>/<pf>/`` directory. None if it isn't one."""
    pkg_dir = os.path.abspath(pkg_dir)
    if not os.path.isdir(pkg_dir):
        return None
    pf = os.path.basename(pkg_dir)
    cat = os.path.basename(os.path.dirname(pkg_dir))
    values = {name: _read_vdb_file(os.path.join(pkg_dir, name)) for name in VDB_FIELDS}
    m = _PV_RE.match(pf)
    pkg, version = (m.group("pn"), m.group("pv")) if m else (pf, None)
    return VdbPackage(
        cat=cat,
        pf=pf,
        pkg=pkg,
        version=version,
        keywords=values["KEYWORDS"],
        license=values["LICENSE"],
        iuse=values["IUSE"],
        use=values["USE"],
        description=values["DESCRIPTION"],
        slot=values["SLOT"],
        repository=values["repository"],
    )


def read_vdb_sysroot(sysroot: str) -> dict[str, VdbPackage]:
    """Read every package under ``<sysroot>/var/db/pkg`` → ``{cpv: record}``.

    ``sysroot`` is a ``…/wl-*/<role>/sysroot`` directory (or anything with a
    ``var/db/pkg`` inside). An absent tree yields an empty dict — an archived
    session on a foreign machine is a supported, silent case.
    """
    vdb_root = os.path.join(sysroot, "var", "db", "pkg")
    records: dict[str, VdbPackage] = {}
    try:
        cats = sorted(os.listdir(vdb_root))
    except OSError:
        return records
    for cat in cats:
        cat_dir = os.path.join(vdb_root, cat)
        if cat.startswith((".", "-")) or not os.path.isdir(cat_dir):
            continue
        try:
            pfs = sorted(os.listdir(cat_dir))
        except OSError:
            continue
        for pf in pfs:
            # "-MERGING-<pf>" is portage's transient marker for an interrupted
            # merge — not a package record.
            if pf.startswith((".", "-")):
                continue
            rec = read_vdb_package(os.path.join(cat_dir, pf))
            if rec is not None:
                records[rec.cpv] = rec
    return records


def index_vdb_by_cat_pkg(records: dict[str, VdbPackage]) -> dict[tuple[str, str], VdbPackage]:
    """Re-key VDB records by (cat, pkg) for joining onto resolver rows."""
    return {(rec.cat, rec.pkg): rec for rec in records.values()}


# ── USE_EXPAND splitting (§3's VDB fallback for the group columns) ───────────────────

def split_use_expand(
    names: Iterable[str], groups: Iterable[str]
) -> tuple[tuple[str, ...], dict[str, tuple[str, ...]]]:
    """Partition VDB-style flag names into plain USE and USE_EXPAND groups.

    ``python_targets_python3_12`` → ``PYTHON_TARGETS`` / ``python3_12``; longest
    group prefix wins (PYTHON_SINGLE_TARGET before PYTHON_TARGETS). Returns
    (plain_names, {GROUP: (suffixes…)}), original order preserved everywhere.
    """
    prefixes = sorted(((g.lower() + "_", g) for g in groups),
                      key=lambda p: len(p[0]), reverse=True)
    plain: list[str] = []
    grouped: dict[str, list[str]] = {}
    for name in names:
        for prefix, group in prefixes:
            if name.startswith(prefix) and len(name) > len(prefix):
                grouped.setdefault(group, []).append(name[len(prefix):])
                break
        else:
            plain.append(name)
    return tuple(plain), {g: tuple(v) for g, v in grouped.items()}


# ── offline descriptions (§4) ────────────────────────────────────────────────────────

DEFAULT_REPO_ROOT = "/var/db/repos/gentoo"

#: The USE_EXPAND group names, as a LAST-RESORT snapshot.
#:
#: §4.1: the ``profiles/desc/*.desc`` filenames are the authoritative offline list,
#: and §4.2 records that ``<sysroot>/var/db/repos/gentoo`` is an empty bind-mount
#: point in every captured build — so an archived session opened on a machine with
#: no Gentoo tree has NO listing to read. Without a group list, split_use_expand
#: cannot split anything and the USE column silently degrades to the flat
#: prefix-mixing shape §3.1 calls out as the elog header's defect, with the
#: USE_EXPAND column never revealed at all. That is precisely the archived-session
#: case §4.2/§4.4 exist to serve, so the reader must not be able to lose it.
#:
#: Group names are a small, slow-moving, tree-wide list (52 files, 93 KB of
#: descriptions), not per-package data — verbatim from
#: ``/var/db/repos/gentoo/profiles/desc`` on the fleet's own build host. A live
#: tree and a §4.4 sidecar both still win over this (see
#: :meth:`FlagDescriptions.use_expand_groups`); it only fills the hole where
#: neither exists.
USE_EXPAND_GROUPS_FALLBACK = (
    "ABI_MIPS", "ABI_S390", "ABI_X86", "ADA_TARGET", "ALSA_CARDS",
    "AMDGPU_TARGETS", "APACHE2_MODULES", "APACHE2_MPMS",
    "CALLIGRA_FEATURES", "CAMERAS", "COLLECTD_PLUGINS", "CPU_FLAGS_ARM",
    "CPU_FLAGS_PPC", "CPU_FLAGS_X86", "CURL_QUIC", "CURL_SSL", "ELIBC",
    "GPSD_PROTOCOLS", "GRUB_PLATFORMS", "GUILE_SINGLE_TARGET",
    "GUILE_TARGETS", "INPUT_DEVICES", "KERNEL", "L10N", "LCD_DEVICES",
    "LIBREOFFICE_EXTENSIONS", "LLVM_SLOT", "LLVM_TARGETS",
    "LUA_SINGLE_TARGET", "LUA_TARGETS", "NGINX_MODULES_HTTP",
    "NGINX_MODULES_MAIL", "NGINX_MODULES_STREAM", "OFFICE_IMPLEMENTATION",
    "OPENMPI_FABRICS", "OPENMPI_OFED_FEATURES", "OPENMPI_RM",
    "PERL_FEATURES", "PHP_TARGETS", "POSTGRES_TARGETS",
    "PYTHON_SINGLE_TARGET", "PYTHON_TARGETS", "QEMU_SOFTMMU_TARGETS",
    "QEMU_USER_TARGETS", "RUBY_TARGETS", "RUST_SYSROOTS", "SANE_BACKENDS",
    "SELINUX_POLICY_TYPES", "UWSGI_PLUGINS", "VIDEO_CARDS",
    "VOICEMAIL_STORAGE", "XTABLES_ADDONS",
)

#: §4.4 sidecar: a JSON object mapping description keys to description strings.
#: Key forms (checked in this order, most specific first):
#:   "cat/pkg:flag"   — per-package meaning (use.local.desc / metadata.xml)
#:   "@GROUP:flag"    — USE_EXPAND member (profiles/desc/<group>.desc), flag is
#:                      the printed suffix ("python3_12", not the full IUSE name)
#:   "*:flag"         — tree-wide meaning (use.desc)
#: The Emit phase writes this next to the session (optionally gzipped as
#: ``<name>.gz``); the loader below accepts both.
SIDECAR_BASENAME = "flag-descriptions.json"

_MAX_DESC_FILE_BYTES = 16 * 1024 * 1024   # use.local.desc is ~750 KB; 16 MB is generous


def sidecar_path_for_session(session_dir: str) -> str:
    """Where the Emit phase drops the §4.4 sidecar inside a session directory."""
    return os.path.join(session_dir, SIDECAR_BASENAME)


def load_sidecar(path: str) -> dict[str, str]:
    """Load a §4.4 sidecar (plain or .gz). Absent/oversized/malformed → {} —
    an archived session without one simply has no descriptions, never an error."""
    try:
        if os.path.getsize(path) > _MAX_DESC_FILE_BYTES:
            return {}
        if path.endswith(".gz"):
            with gzip.open(path, "rt", encoding="utf-8") as fh:
                data = json.load(fh)
        else:
            with open(path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {k: v for k, v in data.items() if isinstance(k, str) and isinstance(v, str)}


def _parse_desc_file(path: str, max_bytes: int) -> dict[str, str]:
    """Parse a portage ``.desc`` file: ``key - description`` per line, ``#`` comments."""
    entries: dict[str, str] = {}
    try:
        if os.path.getsize(path) > max_bytes:
            return entries
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                key, sep, desc = line.partition(" - ")
                if sep and key and desc:
                    entries[key.strip()] = desc.strip()
    except OSError:
        pass
    return entries


class FlagDescriptions:
    """Offline hover-text resolver (§4). Lazy, cached, size-bounded, graceful.

    Sources, in precedence order:
      1. a §4.4 session sidecar (works on any machine, forever),
      2. the host Gentoo tree (``repo_root``) — present during builds and on
         any Gentoo host; silently absent on a foreign machine, in which case
         every description is simply None.
    """

    def __init__(self, repo_root: str = DEFAULT_REPO_ROOT,
                 sidecar: str | None = None,
                 max_file_bytes: int = _MAX_DESC_FILE_BYTES) -> None:
        self._root = repo_root
        self._max = max_file_bytes
        self._sidecar_path = sidecar
        self._sidecar: dict[str, str] | None = None   # lazy
        self._use_desc: dict[str, str] | None = None            # profiles/use.desc
        self._local_desc: dict[str, str] | None = None          # profiles/use.local.desc
        self._group_desc: dict[str, dict[str, str]] = {}        # profiles/desc/<g>.desc
        self._groups: tuple[str, ...] | None = None
        self._groups_source: str = ""     # "tree+sidecar" / "sidecar" / "fallback"

    # -- source loading (all lazy) --------------------------------------------------
    def _sidecar_map(self) -> dict[str, str]:
        if self._sidecar is None:
            self._sidecar = load_sidecar(self._sidecar_path) if self._sidecar_path else {}
        return self._sidecar

    def _global_map(self) -> dict[str, str]:
        if self._use_desc is None:
            self._use_desc = _parse_desc_file(
                os.path.join(self._root, "profiles", "use.desc"), self._max)
        return self._use_desc

    def _local_map(self) -> dict[str, str]:
        if self._local_desc is None:
            self._local_desc = _parse_desc_file(
                os.path.join(self._root, "profiles", "use.local.desc"), self._max)
        return self._local_desc

    def _group_map(self, group: str) -> dict[str, str]:
        if group not in self._group_desc:
            self._group_desc[group] = _parse_desc_file(
                os.path.join(self._root, "profiles", "desc", group.lower() + ".desc"),
                self._max)
        return self._group_desc[group]

    # -- public API ------------------------------------------------------------------
    def use_expand_groups(self) -> tuple[str, ...]:
        """The USE_EXPAND group names, NEVER empty.

        §4.1: the ``profiles/desc/*.desc`` filenames are the authoritative offline
        list, so a live tree wins. A §4.4 sidecar's ``@GROUP:flag`` keys name every
        group the session's own packages touch, and are unioned in (they can only
        be groups a real build saw). If neither exists — an archived session opened
        on a machine with no Gentoo tree, exactly the §4.2 case — the built-in
        :data:`USE_EXPAND_GROUPS_FALLBACK` snapshot is used, because returning ()
        here does not degrade gracefully: it silently collapses every USE_EXPAND
        flag back into the flat prefix-mixing USE list that §3.1 calls out as the
        elog header's defect, and hides the USE_EXPAND column entirely.
        """
        if self._groups is None:
            desc_dir = os.path.join(self._root, "profiles", "desc")
            try:
                tree = {fn[:-5].upper() for fn in os.listdir(desc_dir)
                        if fn.endswith(".desc")}
            except OSError:
                tree = set()
            sidecar = {k[1:].partition(":")[0].upper()
                       for k in self._sidecar_map()
                       if k.startswith("@") and ":" in k}
            sidecar.discard("")
            names = tree | sidecar
            if names:
                self._groups_source = "tree+sidecar" if tree else "sidecar"
            else:
                names = set(USE_EXPAND_GROUPS_FALLBACK)
                self._groups_source = "fallback"
            self._groups = tuple(sorted(names))
        return self._groups

    def use_expand_groups_source(self) -> str:
        """Where :meth:`use_expand_groups` got its names: ``"tree+sidecar"``,
        ``"sidecar"``, or ``"fallback"`` (the built-in snapshot). The GUI says so
        in the hover text — a grouping the operator cannot audit is a grouping
        they should be told about."""
        self.use_expand_groups()
        return self._groups_source

    def describe(self, flag: str, cat_pkg: str | None = None,
                 group: str | None = None) -> str | None:
        """Best offline description for a flag, or None — never a fabrication.

        ``flag`` is the name as printed (for USE_EXPAND members, the suffix
        portage displays inside ``GROUP="…"``). ``cat_pkg`` narrows to the
        package-local meaning; ``group`` names the USE_EXPAND group.
        """
        sidecar = self._sidecar_map()
        if cat_pkg:
            hit = sidecar.get(f"{cat_pkg}:{flag}")
            if hit:
                return hit
        if group:
            hit = sidecar.get(f"@{group.upper()}:{flag}")
            if hit:
                return hit
        hit = sidecar.get(f"*:{flag}")
        if hit:
            return hit

        if group:
            return self._group_map(group.upper()).get(flag)
        if cat_pkg:
            hit = self._local_map().get(f"{cat_pkg}:{flag}")
            if hit:
                return hit
        return self._global_map().get(flag)
