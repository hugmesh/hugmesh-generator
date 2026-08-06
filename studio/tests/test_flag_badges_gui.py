"""The four per-package flag columns as hoverable badges — the GUI face.

Ground truth is ``docs/PACKAGE-FLAG-BADGES.md``; the Qt-free data layer is covered by
``test_package_flags.py``. This file asserts the *rendered* contract on the REAL
ProgressPage (offscreen Qt, the same harness as test_pages_progress_packages.py), driven
by the committed ground-truth fixtures:

* ``portage-use-flag-states.json`` — every reachable display state, produced by driving
  portage's own ``_create_use_string``. The §5 badge table is asserted case-by-case
  against it, so a badge can never drift from the state portage actually prints.
* ``emerge-resolver-lines.x86-pki.txt`` — 229 real ``[ebuild …]`` rows from a live fleet
  build, replayed through the page's own ``_on_line`` slot exactly as the stream delivers
  them.
* ``vdb-package-metadata.sample.json`` — real VDB records, materialised back into a
  ``<sysroot>/var/db/pkg/<cat>/<pf>/`` tree so the KEYWORDS/LICENSE join runs against the
  same file shapes portage writes.

``dev-python/certifi-3024.7.22`` appears in BOTH fixtures, which is what makes the
full-stack join (resolver → USE/USE_EXPAND, VDB → KEYWORDS/LICENSE) testable end to end.
"""
import ast
import json
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import package_flags as pf                # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo             # noqa: E402
from hugmesh_studio.gui import flag_badges as fb                   # noqa: E402
from hugmesh_studio.gui import styles                              # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtGui, QtWidgets, Qt     # noqa: E402
from hugmesh_studio.gui.pages import progress as progress_mod      # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "fixtures", "package-flags")
RESOLVER_FIXTURE = os.path.join(FIXTURES, "emerge-resolver-lines.x86-pki.txt")
STATES_FIXTURE = os.path.join(FIXTURES, "portage-use-flag-states.json")
VDB_FIXTURE = os.path.join(FIXTURES, "vdb-package-metadata.sample.json")

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")

_CYAN, _BOLD, _RST = "\x1b[36m", "\x1b[1m", "\x1b[0m"

# The one package present in BOTH ground-truth fixtures.
BOTH = "dev-python/certifi-3024.7.22"
# Rich resolver rows lifted verbatim from the fixture (asserted to still be there).
TALLOC = "sys-libs/talloc-2.4.4"          # USE + ABI_X86 + PYTHON_SINGLE_TARGET
LZO = "dev-libs/lzo-2.10"                 # carries the colourless "(-split-usr)"


# ── harness ───────────────────────────────────────────────────────────────────────────

@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    yield w
    w.close()
    w.deleteLater()


@pytest.fixture
def fake_repo(tmp_path, monkeypatch):
    """A miniature Gentoo profiles tree so the §4 description lookup is HERMETIC.

    The real host tree (``/var/db/repos/gentoo``) is the production source and is what
    ``descriptions_for_session`` reaches for; pinning a fake one here keeps the suite
    identical on a non-Gentoo machine AND makes the expected description text exact.
    The ``desc/*.desc`` FILENAMES are also the USE_EXPAND group list (§4.1), which is
    what drives the VDB-only column split — so this tree exercises that too."""
    root = tmp_path / "repo"
    prof = root / "profiles"
    (prof / "desc").mkdir(parents=True)
    (prof / "use.desc").write_text(
        "# comment line, ignored\n"
        "python - Add optional support/bindings for the Python language\n"
        "test - Enable dependencies and/or preparation necessary to run tests\n")
    (prof / "use.local.desc").write_text(
        "sys-libs/talloc:compat - Build the deprecated compat library\n")
    (prof / "desc" / "python_targets.desc").write_text(
        "python3_12 - Build with CPython 3.12\n"
        "python3_13 - Build with CPython 3.13\n")
    (prof / "desc" / "python_single_target.desc").write_text(
        "python3_12 - Build for CPython 3.12 only\n")
    (prof / "desc" / "abi_x86.desc").write_text(
        "64 - 64-bit (amd64) libraries\n"
        "32 - 32-bit (x86) libraries\n")
    descs = pf.FlagDescriptions(repo_root=str(root))
    monkeypatch.setattr(fb, "descriptions_for_session", lambda _sd: descs)
    return descs


def _write_vdb(sysroot, cpv, fields):
    """Materialise one VDB record the way portage writes it: one one-line file per
    field, and a field portage never wrote simply has NO file (that is how 68/319 real
    packages carry no LICENSE — §3)."""
    cat, _, pfname = cpv.partition("/")
    d = os.path.join(sysroot, "var", "db", "pkg", cat, pfname)
    os.makedirs(d, exist_ok=True)
    for name in pf.VDB_FIELDS:
        val = fields.get(name)
        if val is None:
            continue
        with open(os.path.join(d, name), "w", encoding="utf-8") as fh:
            fh.write(val + "\n")
    return d


def _vdb_sample():
    with open(VDB_FIXTURE, encoding="utf-8") as fh:
        return json.load(fh)["packages"]


def _make_sysroot(tmp_path, cpvs):
    """A build sysroot laid out EXACTLY as the progress page derives it from log_root:
    ``<session>/wl-<id>/sysroot`` with the package logs under
    ``sysroot/var/log/portage/build``. Returns (log_root, sysroot)."""
    sysroot = tmp_path / "session" / "wl-x" / "sysroot"
    log_root = sysroot / "var" / "log" / "portage" / "build"
    log_root.mkdir(parents=True)
    sample = _vdb_sample()
    for cpv in cpvs:
        _write_vdb(str(sysroot), cpv, sample[cpv])
    return str(log_root), str(sysroot)


def _resolver_lines():
    with open(RESOLVER_FIXTURE, encoding="utf-8") as fh:
        return [ln.rstrip("\n") for ln in fh
                if ln.startswith("[") and not ln.startswith("#")]


def _banner(text):
    return f"{_CYAN}{_BOLD}==> {text}{_RST}"


def _emerge_stream(atoms, total=None):
    """The builder banners + portage's own per-package lines for a list of atoms —
    the same shape test_pages_progress_packages.py replays."""
    total = total or len(atoms)
    out = [_banner("Native emerge inside chroot"), _banner("Emerge group: image")]
    for i, atom in enumerate(atoms, 1):
        out += [f">>> Emerging ({i} of {total}) {atom}::gentoo",
                f">>> Installing ({i} of {total}) {atom}::gentoo",
                f">>> Completed ({i} of {total}) {atom}::gentoo"]
    return out


def _page(wiz, log_root=""):
    page = wiz.page(wiz._page_ids["progress"])
    page._reset()
    page._build_row(0, "acme-x86", "x86", log_root=log_root)
    return page


def _flag_col(key):
    return progress_mod._FLAG_COLS[key]


def _badges(item, key):
    cell = item.data(_flag_col(key), fb.CELL_ROLE)
    return list(cell.badges) if cell is not None else []


# ── §4.5 the hard rule: constructed URLs, never fetched ───────────────────────────────

_BANNED_IMPORTS = ("urllib", "requests", "http", "httplib", "socket", "ftplib",
                   "telnetlib", "aiohttp", "httpx", "xmlrpc", "webbrowser",
                   "QtNetwork", "QtWebEngineWidgets", "QtWebEngineCore")
_BANNED_CALLS = ("urlopen", "QNetworkAccessManager", "QNetworkRequest",
                 "requests.get", "socket.socket", "openUrl")


def test_the_gui_module_imports_no_network_machinery_at_all():
    """§4.5 is a HARD RULE, so it is asserted structurally rather than by inspection:
    parse the module and walk every import statement. A hover-time fetch would leak what
    the operator is building to a third party, break air-gapped use and block the UI
    thread — so the honest guarantee is that the capability is not even reachable."""
    src_path = os.path.abspath(fb.__file__)
    with open(src_path, encoding="utf-8") as fh:
        src = fh.read()
    tree = ast.parse(src)
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(a.name.split(".")[0] for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                imported.add(node.module.split(".")[0])
            imported.update(a.name for a in node.names)
    for banned in _BANNED_IMPORTS:
        assert banned not in imported, f"{banned} imported by flag_badges"
    for banned in _BANNED_CALLS:
        assert banned not in src, f"{banned} referenced by flag_badges"
    # the URLs themselves ARE present — they are built and displayed (§4.5).
    assert "https://packages.gentoo.org/packages/" in src
    assert "https://wiki.gentoo.org/wiki/" in src


def test_every_tooltip_states_the_no_fetch_guarantee_next_to_its_urls(fake_repo):
    """The operator must be able to see, in the hover itself, that the link is inert."""
    row = pf.parse_resolver_line(
        f'[ebuild  N     ] {TALLOC}  USE="python -compat"')
    cells = fb.resolver_cells(row, fake_repo)
    tip = cells["USE"].badges[0].tooltip
    assert fb.URL_NOTE in tip
    assert "never fetches" in fb.URL_NOTE
    assert "https://packages.gentoo.org/packages/sys-libs/talloc" in tip
    assert "https://wiki.gentoo.org/wiki/USE_flag" in tip


# ── §5 the badge table, case-by-case against portage's own generator ──────────────────

# state-name substring (from the fixture) -> (emoji, colour, outlined, strike)
_EXPECTED = [
    ("REMOVED from IUSE (was off)", "🗑️", styles.WARN, False, True),
    ("REMOVED from IUSE (was on)", "🗑️", styles.WARN, False, True),
    ("newly in IUSE, enabled", "✨🔼", styles.WARN, False, False),
    # state 11 — new in IUSE AND profile-forced/masked. Only recoverable at all because
    # the ANSI form is yellow (§1.3); it must carry BOTH the sparkle and the padlock.
    ("newly in IUSE, disabled + forced/masked", "✨", styles.WARN, True, False),
    ("newly in IUSE, disabled", "✨", styles.WARN, False, False),
    # The iuse_forced paren wrapping a token that already carries its %/* suffix:
    # "(f%*)" / "(f*)" / "(-f*)". These must keep the SUFFIX's meaning and gain the
    # padlock — "(f%*)" is new+on+forced, never a removal. Listed before the
    # unforced "turning ON"/"turning OFF" needles, which are their prefixes.
    ("newly in IUSE, ENABLED + forced", "✨🔼", styles.WARN, True, False),
    ("turning ON + forced", "🔼", fb.GREEN, True, False),
    ("turning OFF + masked", "🔽", fb.GREEN, True, False),
    ("turning ON", "🔼", fb.GREEN, False, False),
    ("turning OFF", "🔽", fb.GREEN, False, False),
    ("enabled unchanged + forced", "🟢", fb.TEAL, True, False),
    ("disabled unchanged + masked", "⚪", styles.MUTED, True, False),
    ("enabled + profile-forced", "🟢", fb.TEAL, True, False),
    ("disabled + profile-masked", "⚪", styles.MUTED, True, False),
    ("enabled, unchanged", "🟢", fb.TEAL, False, False),
    ("disabled, unchanged", "⚪", styles.MUTED, False, False),
    ("new-pkg / enabled", "🟢", fb.TEAL, False, False),
    ("new-pkg / disabled", "⚪", styles.MUTED, False, False),
]


def _expected_for(state):
    for needle, *rest in _EXPECTED:
        if needle in state:
            return tuple(rest)
    raise AssertionError(f"unmapped fixture state: {state}")


def test_badge_table_matches_docs_section5_for_every_portage_state(fake_repo):
    """Every reachable display state, straight out of portage's own formatter, mapped to
    §5's emoji + colour + modifier. The ANSI form is used where colour exists, because
    that is the only input that separates §1.3's states 10 and 11."""
    with open(STATES_FIXTURE, encoding="utf-8") as fh:
        cases = json.load(fh)["cases"]
    seen = set()
    for case in cases:
        # the generator stored the escapes via encode("unicode_escape") — decode back to
        # real ESC bytes, exactly as test_package_flags.py does.
        text = (case["ansi"].encode().decode("unicode_escape")
                if case["ansi"] else case["plain"])
        if not text:
            continue                          # suppressed at default verbosity (§2.3)
        groups = pf.parse_flag_groups(text)
        if not groups or not groups[0].tokens:
            continue
        badge = fb.badge_for_token(groups[0].tokens[0], cat_pkg="sys-libs/talloc",
                                   descriptions=fake_repo)
        emoji, colour, outlined, strike = _expected_for(case["state"])
        assert badge.text.endswith(f"{emoji} f"), (case["state"], badge.text)
        assert badge.colour == colour, case["state"]
        assert badge.outlined is outlined, case["state"]
        assert badge.strike is strike, case["state"]
        # the §5 modifier is a PADLOCK plus an outline — never a new colour.
        assert ("🔒" in badge.text) is outlined, case["state"]
        seen.add(case["state"])
    assert len(seen) >= 18, "the fixture stopped covering the reachable states"


def test_forced_and_newly_in_iuse_is_not_rendered_as_a_removal(fake_repo):
    """Regression: "(f%*)" is profile-forced + newly in IUSE + ENABLED. It used to
    render as 🗑️ struck-through with the tooltip claiming "removed from IUSE … and
    it had been enabled" — every clause the inverse of the truth — and the 🔒
    modifier was dropped entirely. Fires at our builders' DEFAULT verbosity on any
    warm-sysroot rebuild, which is precisely the case the feature exists for."""
    for text in ("(f%*)", "(\x1b[33;01mf\x1b[39;49;00m%*)"):
        badge = fb.badge_for_token(pf.classify_flag_token(text),
                                   cat_pkg="sys-libs/talloc", descriptions=fake_repo)
        assert badge.text == "🔒 ✨🔼 f", text        # padlock kept, sparkle+triangle
        assert badge.colour == styles.WARN
        assert badge.outlined is True                # §5's modifier: forced ⇒ outlined
        assert badge.strike is False                 # NOT a removal
        tip = badge.tooltip
        assert "removed from IUSE" not in tip, text
        assert "new in IUSE" in tip and "turning on" in tip
        assert "forced ON by the profile" in tip
        assert fb.AMBIGUITY_CAVEAT not in tip


def test_forced_transition_badges_are_not_falsely_ambiguous(fake_repo):
    """Regression: "(f*)"/"(-f*)" are profile-forced/masked AND transitioning. The
    '*' can only come from portage's green branch, which requires the flag to have
    been in the old IUSE — so they are uniquely recoverable even in plain text and
    must not carry §1.3's "the log was captured without colour" caveat (which was
    also asserted under an actual --color=y capture, where it is doubly false)."""
    for text, emoji in (("(f*)", "🔼"), ("(-f*)", "🔽"),
                        ("(\x1b[32;01mf\x1b[39;49;00m*)", "🔼"),
                        ("(\x1b[32;01m-f\x1b[39;49;00m*)", "🔽")):
        badge = fb.badge_for_token(pf.classify_flag_token(text), descriptions=fake_repo)
        assert badge.text == f"🔒 {emoji} f", text
        assert badge.colour == fb.GREEN and badge.outlined and not badge.strike
        assert fb.AMBIGUITY_CAVEAT not in badge.tooltip, text
    # ...while the ONE genuine collision keeps its caveat.
    bare = fb.badge_for_token(pf.classify_flag_token("(-f)"), descriptions=fake_repo)
    assert fb.AMBIGUITY_CAVEAT in bare.tooltip


def test_new_in_iuse_composes_with_the_transition_triangle(fake_repo):
    """§5 #5: ``f%*`` is new AND turning on — the sparkle composes with the triangle
    rather than replacing it, so the operator does not lose the direction."""
    on = fb.badge_for_token(pf.classify_flag_token("f%*"), descriptions=fake_repo)
    off = fb.badge_for_token(pf.classify_flag_token("-f%"), descriptions=fake_repo)
    assert on.text.startswith("✨🔼")
    assert off.text.startswith("✨ ")     # newly in IUSE but not transitioning
    assert on.colour == off.colour == styles.WARN


def test_only_the_two_documented_new_colours_are_ever_used(fake_repo):
    """The §5 palette rule: reuse styles.MUTED/WARN, and add exactly the two mid-tone
    values the doc records. Anything else would break styles.py's cross-theme rule."""
    allowed = {styles.MUTED, styles.WARN, fb.TEAL, fb.GREEN}
    assert {fb.TEAL, fb.GREEN} == {"#0e7a63", "#1a7f37"}
    row = pf.parse_resolver_line(_line_for(TALLOC))
    for cell in fb.resolver_cells(row, fake_repo).values():
        for badge in cell.badges:
            assert badge.colour in allowed, badge.text


# ── tooltips: verbatim token, meaning, description, caveats ───────────────────────────

def _line_for(atom):
    for ln in _resolver_lines():
        if f"] {atom} " in ln or ln.strip().endswith(atom):
            return ln
    raise AssertionError(f"{atom} is no longer in the resolver fixture")


def test_tooltip_carries_verbatim_token_meaning_and_offline_description(fake_repo):
    row = pf.parse_resolver_line(_line_for(TALLOC))
    cells = fb.resolver_cells(row, fake_repo)
    by_name = {b.text.split()[-1]: b for b in cells["USE"].badges}

    tip = by_name["python"].tooltip
    assert tip.startswith("python — portage's exact text")
    assert "enabled — on now and on at the last merge" in tip
    # §5 row 1's MANDATORY honesty note: our teal is a deliberate deviation.
    assert fb.RED_NOTE in tip
    assert "Add optional support/bindings for the Python language" in tip   # use.desc

    # a package-LOCAL description (use.local.desc) beats the tree-wide one
    assert "Build the deprecated compat library" in by_name["compat"].tooltip


def test_use_expand_member_tooltip_names_its_group_and_uses_the_group_desc(fake_repo):
    row = pf.parse_resolver_line(_line_for(TALLOC))
    cells = fb.resolver_cells(row, fake_repo)
    tips = {b.text.split()[-1]: b.tooltip for b in cells["USE_EXPAND"].badges}
    assert 'inside PYTHON_SINGLE_TARGET="…"' in tips["python3_12"]
    assert "Build for CPython 3.12 only" in tips["python3_12"]      # desc/*.desc wins
    # the group's own header chip explains the stripped prefix (§2.1)
    header = [b for b in cells["USE_EXPAND"].badges
              if b.text == "PYTHON_SINGLE_TARGET"][0]
    assert "prefix stripped" in header.tooltip


def test_colourless_forced_masked_carries_the_section1_3_ambiguity_caveat(fake_repo):
    """§1.3: plain-text ``(-f)`` is a genuine two-way collision (masked-unchanged vs
    masked-and-newly-in-IUSE). §5 requires the ambiguity be VISIBLE, not papered over."""
    row = pf.parse_resolver_line(_line_for(LZO))
    cells = fb.resolver_cells(row, fake_repo)
    split_usr = [b for b in cells["USE"].badges if b.text.endswith("split-usr")][0]
    tip = split_usr.tooltip
    assert fb.AMBIGUITY_CAVEAT in tip
    assert "masked OFF by the profile" in tip
    assert "--color=y" in tip                 # the caveat names its own remedy


def test_a_coloured_emission_removes_the_caveat(fake_repo):
    """The other half of §1.3: under ``--color=y`` the blue/yellow distinction is back,
    so the honest tooltip must STOP claiming it cannot tell."""
    blue = pf.classify_flag_token("(\x1b[34;01m-f\x1b[39;49;00m)")
    yellow = pf.classify_flag_token("(\x1b[33;01m-f\x1b[39;49;00m)")
    assert fb.AMBIGUITY_CAVEAT not in fb.badge_for_token(blue, descriptions=fake_repo).tooltip
    ytip = fb.badge_for_token(yellow, descriptions=fake_repo).tooltip
    assert fb.AMBIGUITY_CAVEAT not in ytip
    assert "new in IUSE" in ytip


def test_a_flag_with_no_offline_description_says_so_instead_of_inventing_one():
    """No sidecar and no host tree is a supported case (§4.2) — and must read as an
    absence, never as a fabricated meaning."""
    empty = pf.FlagDescriptions(repo_root="/nonexistent-repo-root")
    tip = fb.badge_for_token(pf.classify_flag_token("wibble"),
                             descriptions=empty).tooltip
    assert "no offline description available" in tip


def test_tooltips_are_lazy_so_300_packages_do_not_build_6000_hover_strings(fake_repo):
    """PERFORMANCE: only the hovered badge pays. The factory is memoised on first read
    so a second hover is free, and ``.tooltip`` still reads as a plain string."""
    badge = fb.badge_for_token(pf.classify_flag_token("python"),
                               cat_pkg="sys-libs/talloc", descriptions=fake_repo)
    assert callable(badge.tip_source)
    first = badge.tooltip
    assert isinstance(first, str) and first
    assert not callable(badge.tip_source)          # memoised
    assert badge.tooltip is badge.tip_source


# ── §5 order: portage's emitted order, never re-sorted ────────────────────────────────

def test_badge_order_is_exactly_portages_emitted_order(fake_repo):
    """§1.2: position alone tells the operator 'everything past here is off'. The
    fixture row's order is enabled → disabled; a GUI that re-sorted would lose that."""
    row = pf.parse_resolver_line(_line_for(TALLOC))
    cells = fb.resolver_cells(row, fake_repo)
    names = [b.text.split()[-1] for b in cells["USE"].badges]
    assert names == ["python", "compat", "test", "valgrind"]
    expand = [b.text.split()[-1] for b in cells["USE_EXPAND"].badges]
    assert expand == ["ABI_X86", "64", "32", "x32",
                      "PYTHON_SINGLE_TARGET", "python3_12", "python3_13", "python3_14"]


# ── column visibility: empty column ⇒ no column ───────────────────────────────────────

def test_all_four_columns_start_hidden(wiz, fake_repo):
    page = _page(wiz)
    for key in fb.FLAG_COLUMNS:
        assert page.tree.isColumnHidden(_flag_col(key)), key


def test_resolver_only_stream_shows_use_columns_and_leaves_vdb_columns_hidden(
        wiz, fake_repo):
    """The §0c case: a slot conflict made portage print its merge list, but there is no
    sysroot to read (an archived/foreign session). USE + USE_EXPAND light up; KEYWORDS
    and LICENSE have NO source at all (§2.2) and must stay hidden."""
    page = _page(wiz)
    for ln in _resolver_lines():
        page._on_line(0, ln)
    for ln in _emerge_stream([TALLOC]):
        page._on_line(0, ln)
    assert not page.tree.isColumnHidden(_flag_col("USE"))
    assert not page.tree.isColumnHidden(_flag_col("USE_EXPAND"))
    assert page.tree.isColumnHidden(_flag_col("KEYWORDS"))
    assert page.tree.isColumnHidden(_flag_col("LICENSE"))


def test_a_package_with_no_license_leaves_the_license_column_hidden(
        wiz, tmp_path, fake_repo):
    """68 of 319 real packages have NO LICENSE file — the strongest case for the
    operator's 'only show a column when it has content' (§3). acct-group/audio is one
    of them, verbatim from the VDB sample."""
    log_root, _ = _make_sysroot(tmp_path, ["acct-group/audio-0-r3"])
    page = _page(wiz, log_root=log_root)
    for ln in _emerge_stream(["acct-group/audio-0-r3"]):
        page._on_line(0, ln)
    assert not page.tree.isColumnHidden(_flag_col("KEYWORDS"))
    assert page.tree.isColumnHidden(_flag_col("LICENSE"))
    item = page._rows[0].pkg_items["acct-group/audio-0-r3"]
    assert item.text(_flag_col("LICENSE")) == ""      # the empty CELL simply stays empty


def test_a_licensed_package_reveals_the_license_column_and_empty_cells_stay_empty(
        wiz, tmp_path, fake_repo):
    """The column-vs-cell distinction: one row with content reveals the column for the
    whole tree, and the rows without content keep an EMPTY cell (not a placeholder)."""
    log_root, _ = _make_sysroot(
        tmp_path, ["acct-group/audio-0-r3", "dev-libs/elfutils-0.195"])
    page = _page(wiz, log_root=log_root)
    for ln in _emerge_stream(["acct-group/audio-0-r3", "dev-libs/elfutils-0.195"]):
        page._on_line(0, ln)
    assert not page.tree.isColumnHidden(_flag_col("LICENSE"))
    items = page._rows[0].pkg_items
    assert items["acct-group/audio-0-r3"].text(_flag_col("LICENSE")) == ""
    assert items["dev-libs/elfutils-0.195"].text(_flag_col("LICENSE")) == \
        'LICENSE="|| ( GPL-2+ LGPL-3+ ) GPL-3+"'


def test_reset_hides_every_flag_column_again(wiz, tmp_path, fake_repo):
    """A second build on the same page instance must not inherit the first run's
    columns — 'empty column ⇒ no column' is a property of what is on screen NOW."""
    log_root, _ = _make_sysroot(tmp_path, ["dev-libs/elfutils-0.195"])
    page = _page(wiz, log_root=log_root)
    for ln in _emerge_stream(["dev-libs/elfutils-0.195"]):
        page._on_line(0, ln)
    assert not page.tree.isColumnHidden(_flag_col("KEYWORDS"))
    page._reset()
    for key in fb.FLAG_COLUMNS:
        assert page.tree.isColumnHidden(_flag_col(key)), key


def test_flag_columns_do_not_disturb_the_488_expand_gate(wiz, fake_repo):
    """#488's package-list affordance rides the Flags column on the JOB row. Adding four
    columns after it must leave that widget, and its one-way enable latch, untouched."""
    page = _page(wiz)
    row = page._rows[0]
    assert page.tree.itemWidget(row.job_item, progress_mod._COL_FLAGS) is row.pkg_btn
    assert row.pkg_btn.isEnabled() is False           # not emerging yet
    for ln in _emerge_stream([TALLOC]):
        page._on_line(0, ln)
    assert row.pkg_expandable and row.pkg_btn.isEnabled()
    assert page.tree.itemWidget(row.job_item, progress_mod._COL_FLAGS) is row.pkg_btn


# ── the join: resolver block + VDB, onto a replayed tree ──────────────────────────────

def test_full_join_of_the_real_resolver_block_and_the_real_vdb(wiz, tmp_path, fake_repo):
    """The end-to-end case, on the one package present in BOTH ground-truth fixtures:
    the resolver row supplies USE_EXPAND with per-flag state markers, the VDB supplies
    KEYWORDS and LICENSE. All four columns become visible together."""
    log_root, _ = _make_sysroot(tmp_path, [BOTH])
    page = _page(wiz, log_root=log_root)
    for ln in _resolver_lines():
        page._on_line(0, ln)
    for ln in _emerge_stream([BOTH, TALLOC]):
        page._on_line(0, ln)

    item = page._rows[0].pkg_items[BOTH]
    # USE_EXPAND from the RESOLVER — with the '*' transition markers portage printed
    # (this is an [ebuild R] row, so it lists only what changed — §2.3).
    expand = _badges(item, "USE_EXPAND")
    assert [b.text.split()[-1] for b in expand] == [
        "PYTHON_TARGETS", "python3_12", "python3_13", "python3_14",
        "python3_14t", "python3_15t"]
    assert expand[1].text.startswith("🔼")          # python3_12* — turning on
    assert expand[2].text.startswith("🔽")          # -python3_13* — turning off
    assert expand[4].outlined and "🔒" in expand[4].text   # (-python3_14t) forced/masked

    # KEYWORDS + LICENSE from the VDB — the resolver line has neither (§2.2).
    kws = [b.text.split()[-1] for b in _badges(item, "KEYWORDS")]
    assert kws[:4] == ["~alpha", "amd64", "arm", "arm64"]
    assert [b.text.split()[-1] for b in _badges(item, "LICENSE")] == ["MPL-2.0"]
    for key in fb.FLAG_COLUMNS:
        assert not page.tree.isColumnHidden(_flag_col(key)), key


def test_keyword_badges_separate_stable_testing_and_excluded(wiz, tmp_path, fake_repo):
    log_root, _ = _make_sysroot(tmp_path, [BOTH])
    page = _page(wiz, log_root=log_root)
    for ln in _emerge_stream([BOTH]):
        page._on_line(0, ln)
    by_kw = {b.verbatim: b for b in _badges(page._rows[0].pkg_items[BOTH], "KEYWORDS")}
    assert by_kw["amd64"].text.startswith("🟢") and by_kw["amd64"].colour == fb.TEAL
    assert by_kw["~alpha"].text.startswith("⚠️") and by_kw["~alpha"].colour == styles.WARN
    assert "stable keyword" in by_kw["amd64"].tooltip
    assert "testing (unstable)" in by_kw["~alpha"].tooltip
    assert "ACCEPT_KEYWORDS" in by_kw["~alpha"].tooltip


def test_vdb_only_use_falls_back_to_the_unchanged_pair_and_says_so(
        wiz, tmp_path, fake_repo):
    """§0c/§3: with no resolver display the change markers simply do not exist. The USE
    column still fills from the VDB, but ONLY in the enabled/disabled pair, and every
    tooltip states where the state came from and what is missing."""
    log_root, _ = _make_sysroot(tmp_path, ["dev-libs/elfutils-0.195"])
    page = _page(wiz, log_root=log_root)
    for ln in _emerge_stream(["dev-libs/elfutils-0.195"]):     # NO resolver lines
        page._on_line(0, ln)
    item = page._rows[0].pkg_items["dev-libs/elfutils-0.195"]
    use = _badges(item, "USE")
    assert use, "the VDB fallback must still fill USE"
    assert {b.text.split()[0] for b in use} <= {"🟢", "⚪"}    # unchanged pair only
    assert [b.verbatim for b in use][:3] == ["bzip2", "debuginfod", "libarchive"]
    assert fb.VDB_NOTE in use[0].tooltip
    assert "change markers" in fb.VDB_NOTE
    # abi_x86_* / abi_mips_* split out of plain USE into the USE_EXPAND column, driven
    # by the desc/*.desc filenames (§4.1) — abi_x86 is in the fake repo, abi_mips is not.
    # Note the PRINTED name drops the group prefix (§2.1) while the verbatim token keeps
    # portage's sign, so the group column reads 64 / -32 / -x32.
    expand = [b.verbatim for b in _badges(item, "USE_EXPAND")]
    assert expand == ["ABI_X86", "64", "-32", "-x32"]
    plain = [b.verbatim for b in use]
    assert "abi_x86_64" not in plain and "-abi_x86_32" not in plain
    # -abi_mips_n32 has no desc file, so it never folds into a group and stays in plain
    # USE — but it is DISABLED and not '+'-defaulted by the ebuild, so the noise filter
    # (operator rule 2026-08-05) hides it from the VIEW. The verbatim copy still carries
    # it: that is the filter's whole contract, asserted here so a regression in either
    # direction is caught.
    assert "-abi_mips_n32" not in plain, "an always-off flag must not clutter the view"
    cell = item.data(_flag_col("USE"), fb.CELL_ROLE)
    assert "-abi_mips_n32" in cell.verbatim_text, "the verbatim copy must keep every flag"


def test_use_expand_still_splits_on_a_machine_with_no_gentoo_tree(
        wiz, tmp_path, monkeypatch):
    """§4.2/§4.4's whole reason to exist: an archived session opened elsewhere.

    The group names came only from os.listdir(<repo>/profiles/desc), which returns
    () with no tree — and the §4.4 sidecar carries descriptions, not the group
    list, so it could not rescue this. The USE cell silently regressed to the flat
    prefix-mixing shape §3.1 calls out as the elog header's defect
    (``python_targets_python3_13`` sitting beside real USE flags) and the
    USE_EXPAND column was never revealed at all, with nothing saying so."""
    descs = pf.FlagDescriptions(repo_root=str(tmp_path / "no-such-tree"))
    monkeypatch.setattr(fb, "descriptions_for_session", lambda _sd: descs)
    log_root, _ = _make_sysroot(tmp_path, ["dev-libs/elfutils-0.195"])
    page = _page(wiz, log_root=log_root)
    for ln in _emerge_stream(["dev-libs/elfutils-0.195"]):    # NO resolver lines
        page._on_line(0, ln)
    item = page._rows[0].pkg_items["dev-libs/elfutils-0.195"]

    assert not page.tree.isColumnHidden(_flag_col("USE_EXPAND"))
    expand = [b.verbatim for b in _badges(item, "USE_EXPAND")]
    # abi_mips_* AND abi_x86_* both fold now — the snapshot has all 52 groups,
    # where the fake 2-file repo tree only knows ABI_X86.
    assert "ABI_X86" in expand and "ABI_MIPS" in expand
    plain = [b.verbatim for b in _badges(item, "USE")]
    assert not any(v.lstrip("-").startswith(("abi_x86_", "abi_mips_")) for v in plain), \
        plain
    # ...and the operator is told the grouping came from the built-in snapshot.
    assert fb.GROUPS_FALLBACK_NOTE in _badges(item, "USE_EXPAND")[1].tooltip
    assert fb.GROUPS_FALLBACK_NOTE in _badges(item, "USE")[0].tooltip
    assert fb.VDB_NOTE in _badges(item, "USE")[0].tooltip


def test_the_snapshot_note_is_absent_when_a_real_group_list_was_read(
        wiz, tmp_path, fake_repo):
    """The caveat is honesty, not decoration: with a live tree it must not appear."""
    log_root, _ = _make_sysroot(tmp_path, ["dev-libs/elfutils-0.195"])
    page = _page(wiz, log_root=log_root)
    for ln in _emerge_stream(["dev-libs/elfutils-0.195"]):
        page._on_line(0, ln)
    item = page._rows[0].pkg_items["dev-libs/elfutils-0.195"]
    assert fb.GROUPS_FALLBACK_NOTE not in _badges(item, "USE")[0].tooltip
    assert fb.VDB_NOTE in _badges(item, "USE")[0].tooltip


def test_the_vdb_read_is_retried_when_portage_writes_it_after_the_completed_line(
        wiz, tmp_path, fake_repo):
    """A real race, not an error: portage writes the VDB directory around the Completed
    line. The bounded per-tick retry is what fills those rows in."""
    log_root, sysroot = _make_sysroot(tmp_path, [])
    page = _page(wiz, log_root=log_root)
    for ln in _emerge_stream([BOTH]):
        page._on_line(0, ln)
    assert page.tree.isColumnHidden(_flag_col("LICENSE"))      # not on disk yet
    _write_vdb(sysroot, BOTH, _vdb_sample()[BOTH])
    page._poll_packages(page._rows[0], 1.0)
    assert not page.tree.isColumnHidden(_flag_col("LICENSE"))
    assert _badges(page._rows[0].pkg_items[BOTH], "LICENSE")


def test_each_slot_of_a_multi_slot_package_shows_its_OWN_flags(wiz, fake_repo):
    """A -v merge list gives every slot its own row, and this fleet really does merge
    dev-lang/python at two slots (and app-text/docbook-xml-dtd at four). Keying the
    resolver index by (cat, pkg) collapsed them, so the LAST row spoke for all of
    them: one slot's row displayed the other slot's badges, with no caveat, and the
    copy path put the wrong USE string on the clipboard."""
    slots = {
        "dev-lang/python-3.13.14": ("3.13", 'USE="ncurses readline -tk"'),
        "dev-lang/python-3.14.6": ("3.14", 'USE="-ncurses -readline tk"'),
    }
    page = _page(wiz)
    for atom, (slot, use) in slots.items():
        page._on_line(0, f'[ebuild  N     ] {atom}:{slot}::gentoo  {use}')
    for ln in _emerge_stream(list(slots)):
        page._on_line(0, ln)
    items = page._rows[0].pkg_items
    for atom, (_slot, use) in slots.items():
        assert items[atom].text(_flag_col("USE")) == use, atom
        got = [b.verbatim for b in _badges(items[atom], "USE")]
        assert got == use[len('USE="'):-1].split(), atom
    # ...and the two rows genuinely differ (the bug made them identical).
    assert items["dev-lang/python-3.13.14"].text(_flag_col("USE")) != \
        items["dev-lang/python-3.14.6"].text(_flag_col("USE"))


def test_an_ambiguous_cat_pkg_falls_back_to_the_vdb_instead_of_the_wrong_slot(
        wiz, tmp_path, fake_repo):
    """When only a collapsed (cat, pkg) match exists and it is ambiguous, the honest
    answer is the VDB's enabled/disabled fallback (which is read at the exact
    <pkg>-<version> path), never another slot's markers."""
    log_root, _ = _make_sysroot(tmp_path, [BOTH])
    page = _page(wiz, log_root=log_root)
    # two slots of some OTHER package share a cat/pkg; neither names our atom
    page._on_line(0, '[ebuild  N     ] dev-lang/python-3.13.14  USE="ncurses"')
    page._on_line(0, '[ebuild  N     ] dev-lang/python-3.14.6  USE="-ncurses"')
    for ln in _emerge_stream([BOTH]):
        page._on_line(0, ln)
    item = page._rows[0].pkg_items[BOTH]
    # Read the CELL, not the visible badges: this fixture's flags are all disabled and
    # none is '+'-defaulted, so the noise filter (operator rule 2026-08-05) legitimately
    # shows nothing. What this test is about is WHICH SOURCE filled the cell — the VDB
    # at the exact <pkg>-<version> path, never another slot's markers — and that is
    # carried by the unfiltered verbatim string.
    cell = item.data(_flag_col("USE"), fb.CELL_ROLE)
    assert cell is not None, "the VDB fallback must still fill the USE cell"
    assert "ncurses" not in cell.verbatim_text, "took a foreign slot's flags"
    assert fb.VDB_NOTE in cell.badges[0].tooltip if cell.badges else True


def test_a_resolver_display_printed_after_the_row_exists_still_lands(wiz, fake_repo):
    """§0c is about a display that arrives at all; --keep-going makes portage re-run the
    depgraph MID-build, so a merge list can be printed for packages whose rows are
    already on screen. That display must not be silently dropped."""
    page = _page(wiz)
    for ln in _emerge_stream([TALLOC]):            # the row exists first…
        page._on_line(0, ln)
    assert page.tree.isColumnHidden(_flag_col("USE"))
    page._on_line(0, _line_for(TALLOC))            # …and the merge list comes after
    assert not page.tree.isColumnHidden(_flag_col("USE"))
    item = page._rows[0].pkg_items[TALLOC]
    assert item.text(_flag_col("USE")) == 'USE="python -compat -test -valgrind"'


def test_an_absent_sysroot_is_silent_not_an_error(wiz, fake_repo):
    """An archived session on a foreign machine has no VDB at all — a supported case."""
    page = _page(wiz, log_root="")
    assert page._rows[0].flag_join.sysroot == ""
    for ln in _emerge_stream([BOTH]):
        page._on_line(0, ln)
    page._poll_packages(page._rows[0], 1.0)
    assert page.tree.isColumnHidden(_flag_col("KEYWORDS"))
    assert page._rows[0].pkg_items[BOTH] is not None            # the row still exists


# ── copy: the verbatim KEY="…" guarantee ──────────────────────────────────────────────

def test_copy_text_is_exactly_what_portage_printed(wiz, tmp_path, fake_repo):
    """§5: 'Copy-paste of a row must yield USE="debug -python -test" exactly as portage
    printed it.' The cell's display text IS that string, so every selection/copy path
    (item.text, the context-menu action, a model export) gets the verbatim form."""
    log_root, _ = _make_sysroot(tmp_path, [BOTH])
    page = _page(wiz, log_root=log_root)
    for ln in _resolver_lines():
        page._on_line(0, ln)
    for ln in _emerge_stream([BOTH, TALLOC, LZO]):
        page._on_line(0, ln)
    items = page._rows[0].pkg_items

    assert items[TALLOC].text(_flag_col("USE")) == \
        'USE="python -compat -test -valgrind"'
    assert items[TALLOC].text(_flag_col("USE_EXPAND")) == \
        'ABI_X86="(64) -32 (-x32)" PYTHON_SINGLE_TARGET="python3_12 -python3_13 ' \
        '-python3_14"'
    assert items[LZO].text(_flag_col("USE")) == \
        'USE="-examples (-split-usr) -static-libs"'
    assert items[BOTH].text(_flag_col("KEYWORDS")).startswith('KEYWORDS="~alpha amd64')
    assert items[BOTH].text(_flag_col("LICENSE")) == 'LICENSE="MPL-2.0"'


def test_copy_text_for_a_row_joins_the_four_columns_in_order(wiz, tmp_path, fake_repo):
    log_root, _ = _make_sysroot(tmp_path, [BOTH])
    page = _page(wiz, log_root=log_root)
    for ln in _resolver_lines():
        page._on_line(0, ln)
    for ln in _emerge_stream([BOTH]):
        page._on_line(0, ln)
    text = page.flag_columns.copy_text_for(page._rows[0].pkg_items[BOTH])
    assert text.startswith('PYTHON_TARGETS="python3_12* -python3_13*')
    assert 'KEYWORDS="' in text and 'LICENSE="MPL-2.0"' in text
    # a job/stage row carries no flag cells at all
    assert page.flag_columns.copy_text_for(page._rows[0].job_item) == ""


# ── PERFORMANCE: a painting delegate, not widgets per row ─────────────────────────────

def test_no_badge_ever_becomes_a_child_widget(wiz, tmp_path, fake_repo):
    """The hard performance requirement: 300+ packages × four columns of per-badge child
    widgets would be thousands of live QWidgets. The delegate paints instead — so the
    flag columns must hold NO item widget, and the tree's widget count must not grow
    with the number of BADGES, only with the (pre-existing) one progress cell per row."""
    log_root, _ = _make_sysroot(tmp_path, [BOTH, "dev-libs/elfutils-0.195"])
    page = _page(wiz, log_root=log_root)
    baseline = len(page.tree.findChildren(QtWidgets.QWidget))

    atoms = [BOTH, "dev-libs/elfutils-0.195", TALLOC, LZO]
    for ln in _resolver_lines():
        page._on_line(0, ln)
    for ln in _emerge_stream(atoms):
        page._on_line(0, ln)

    items = page._rows[0].pkg_items
    assert len(items) == len(atoms)
    total_badges = sum(len(_badges(it, k)) for it in items.values()
                       for k in fb.FLAG_COLUMNS)
    assert total_badges > 40, "the fixtures must actually produce a lot of badges"

    for item in items.values():
        for key in fb.FLAG_COLUMNS:
            assert page.tree.itemWidget(item, _flag_col(key)) is None, key

    # the ONLY per-row widgets are the pre-existing progress cell (container + bar +
    # tool label). Four per row is the honest bound; badges add none.
    grown = len(page.tree.findChildren(QtWidgets.QWidget)) - baseline
    assert grown <= 4 * len(atoms), (grown, total_badges)


def test_the_stream_gate_ignores_ninja_counter_lines(wiz, fake_repo):
    """A single real build emits ~75 000 "[123/456]" build-tool counter lines. The gate
    must be an EXACT prefix test, not "starts with [", or every one of them would pay for
    a full resolver parse."""
    assert fb.RESOLVER_PREFIXES == ("[ebuild", "[binary", "[nomerge", "[blocks",
                                    "[uninstall")
    page = _page(wiz)
    for i in range(200):
        page._on_line(0, f"[{i}/74998] Building CXX object src/foo.cc.o")
    assert page._rows[0].flag_join.revision == 0
    for key in fb.FLAG_COLUMNS:
        assert page.tree.isColumnHidden(_flag_col(key)), key


def test_replaying_the_whole_x86_fixture_log_stays_bounded(wiz, tmp_path, fake_repo):
    """The full 229-row resolver block plus a 60-package emerge stream — the shape of a
    real build. Every resolver row is indexed, and the tree still holds no badge
    widgets."""
    log_root, _ = _make_sysroot(tmp_path, [])
    page = _page(wiz, log_root=log_root)
    lines = _resolver_lines()
    assert len(lines) >= 229
    for ln in lines:
        page._on_line(0, ln)
    join = page._rows[0].flag_join
    assert join.revision >= 229

    atoms = []
    for ln in lines[:60]:
        rr = pf.parse_resolver_line(ln)
        if rr is not None and rr.cpv:
            atoms.append(rr.cpv)
    for ln in _emerge_stream(atoms):
        page._on_line(0, ln)
    assert len(page._rows[0].pkg_items) == len(atoms)
    for item in page._rows[0].pkg_items.values():
        for key in fb.FLAG_COLUMNS:
            assert page.tree.itemWidget(item, _flag_col(key)) is None


def test_the_delegate_paints_and_hit_tests_every_badge(wiz, tmp_path, fake_repo):
    """The delegate really renders (a paint that threw would abort PyQt6), and the hover
    hit-test resolves the pointer to the badge under it — which is what makes a painted
    chip hoverable at all."""
    log_root, _ = _make_sysroot(tmp_path, [BOTH])
    page = _page(wiz, log_root=log_root)
    for ln in _resolver_lines():
        page._on_line(0, ln)
    for ln in _emerge_stream([BOTH]):
        page._on_line(0, ln)
    item = page._rows[0].pkg_items[BOTH]
    col = _flag_col("USE_EXPAND")
    delegate = page.flag_columns.delegate
    assert page.tree.itemDelegateForColumn(col) is delegate

    index = page.tree.indexFromItem(item, col)
    opt = QtWidgets.QStyleOptionViewItem()
    opt.rect = QtCore.QRect(0, 0, 900, 24)
    opt.font = page.tree.font()
    pixmap = QtGui.QPixmap(900, 24)
    painter = QtGui.QPainter(pixmap)
    try:
        delegate.paint(painter, opt, index)
    finally:
        painter.end()

    cell = item.data(col, fb.CELL_ROLE)
    laid = delegate.layout_badges(opt.rect, opt.font, cell)
    assert len(laid) == len(cell.badges)
    for rect, badge in laid:
        assert rect.width() > 0
        hit = delegate.badge_at(cell, opt.rect, opt.font, rect.center())
        assert hit is badge
    # a point past the last chip is not a badge — no tooltip is better than a wrong one
    assert delegate.badge_at(cell, opt.rect, opt.font,
                             QtCore.QPoint(890, 12)) is None


def test_help_event_never_raises_out_of_a_qt_slot(wiz, tmp_path, fake_repo):
    """The operator runs PyQt6, where an exception escaping into Qt calls qFatal and
    ABORTS the Studio. helpEvent must be total — including on a cell with no badges."""
    log_root, _ = _make_sysroot(tmp_path, [BOTH])
    page = _page(wiz, log_root=log_root)
    for ln in _emerge_stream([BOTH]):
        page._on_line(0, ln)
    delegate = page.flag_columns.delegate
    for col in (_flag_col("KEYWORDS"), _flag_col("USE_EXPAND"), progress_mod._COL_NAME):
        index = page.tree.indexFromItem(page._rows[0].pkg_items[BOTH], col)
        opt = QtWidgets.QStyleOptionViewItem()
        opt.rect = QtCore.QRect(0, 0, 400, 24)
        opt.font = page.tree.font()
        ev = QtGui.QHelpEvent(QtCore.QEvent.Type.ToolTip,
                              QtCore.QPoint(10, 10), QtCore.QPoint(10, 10))
        delegate.helpEvent(ev, page.tree, opt, index)     # must not raise
    fb.hide_tip()


def test_a_broken_cell_cannot_take_the_page_down(wiz, fake_repo, monkeypatch):
    """Belt and braces for the same PyQt6 reason: if the join itself faults, the package
    row must still render and the build must carry on."""
    page = _page(wiz)

    def _boom(_atom):
        raise RuntimeError("vdb exploded")

    monkeypatch.setattr(page._rows[0].flag_join, "cells_if_changed", _boom)
    for ln in _emerge_stream([TALLOC]):
        page._on_line(0, ln)                       # must not raise
    assert TALLOC in page._rows[0].pkg_items


# ── the column NAME the doc corrects ──────────────────────────────────────────────────

def test_the_first_column_is_named_use_expand_not_package_env(wiz, fake_repo):
    """§3.1: the operator called it 'package.env'. /etc/portage/package.env maps atoms to
    environment FILES; PYTHON_TARGETS/ABI_X86/CPU_FLAGS_* are USE_EXPAND variables set in
    package.use / make.conf. The column is real and worth building — under its real
    name."""
    assert fb.FLAG_COLUMNS == ("USE_EXPAND", "USE", "KEYWORDS", "LICENSE")
    page = _page(wiz)
    hdr = page.tree.headerItem()
    assert hdr.text(_flag_col("USE_EXPAND")) == "USE_EXPAND"
    assert "package.env" not in [hdr.text(c) for c in range(page.tree.columnCount())]
