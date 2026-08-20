"""The SERVICES SECTION redo — asks 1, 2, 3, 4, 5, 11, 18 and 23.

Operator, verbatim, from live QA of the wizard:

  1.  "gui studio should leave optional services and edge ai unchecked instead of half
      checked for default no"
  2.  "remove the exclude services field, it makes no sense"
  3.  "again, options for standalone desktops shouldnt appear in the mesh wizard"
  4.  "tor onion services are optional and off and unchecked by default"
  5.  "redo entire services section"
  11. "your login/standalone account doesnt belong on mesh builds, keep that to the
      desktop mesh track"
  18. "image/roles that cant be a mesh should be excluded from mesh generation options"
  23. services and apps as a TABLE — "columns as options, with dropdowns, fields and
      submenus as makes sense", and "anything off by default is UNCHECKED"

WHY THIS FILE EXISTS SEPARATELY from test_pages_identity.py (which pins the services
FLAGS — G13/G14/G15/G34 — and keeps doing so): these are properties of the SURFACE, and
several of them are properties that can only be asserted by NOT finding something. A
"there is no tri-state anywhere in this section" test has no natural home next to the
flag it does not apply to; it belongs with the other absences.

Everything here drives the REAL wizard offscreen. Nothing constructs a page directly:
asks 3, 11 and 18 are all about what the FLOW makes reachable, and a directly-built page
has no flow to be wrong about.
"""
import os
import re

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import device_catalog                    # noqa: E402
from hugmesh_studio.core.config import (                          # noqa: E402
    BUILTIN_DEFAULT_SERVICES,
    INFRA_SERVICES_CHOICES,
    ImageAxes,
    ImageConfig,
    OPTIONAL_SERVICES_CHOICES,
    PLATFORM_FIELD_SUPPORT,
    SERVICE_DESCRIPTIONS,
    SERVICE_GROUPS,
    SERVICES_ALL,
    SERVICES_NONE,
    USER_LEVEL_SERVICES,
    default_local_user,
    external_media_applies,
    flow_allows,
    home_options_allowed,
    local_login_applies,
)
from hugmesh_studio.core.platform_info import HostInfo             # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                # noqa: E402
from hugmesh_studio.gui.pages import network as network_mod        # noqa: E402
from hugmesh_studio.gui.pages.network import (                     # noqa: E402
    _FLAG_SERVICE_FIELDS, _PRESET_ALL, _PRESET_CUSTOM, _PRESET_NONE, _SVC_COL_DESC,
    _SVC_COL_NAME, _SVC_HEADERS,
)
from hugmesh_studio.gui.qt import Qt, QtWidgets                    # noqa: E402

from _helpers import (   # noqa: E402
    advance_to, back_to, check_worklist_rows, pairs, pick_mode, pick_role,
)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# a canned host so wizard construction never probes the machine (docker info &c.)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-services-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()          # offscreen: makes per-widget isVisible() meaningful
    yield w
    w.close()
    w.deleteLater()


def mesh(wiz, *ids):
    """Enter mesh mode and check exactly `ids` on the WorklistPage (default: one x86
    cluster node). Returns the WorklistPage."""
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, *(ids or ("omnibus.x86",)))
    return wl


# =====================================================================================
# ASKS 1 + 4 + 23 — DEFINITE DEFAULTS. Nothing half-checked, nothing checked by accident.
# =====================================================================================

def test_no_widget_in_the_services_section_has_a_third_state(wiz):
    """ASKS 1 and 4, as an ABSENCE swept over the whole surface.

    Not a hand-listed four (which is how the page accumulated six tri-states in the first
    place) — every QCheckBox that is a descendant of the services section, whatever a
    later commit adds. A control cannot arrive half-checked here again without this
    failing."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    boxes = net.services_section.findChildren(QtWidgets.QCheckBox)
    boxes += list(net.service_boxes.values()) + [net.edge_ai, net.edge_ai_analysis]
    assert boxes, "found no checkboxes at all — the sweep would be vacuous"
    for box in boxes:
        assert not box.isTristate(), f"{box.objectName() or box.text()} is 3-state"
        assert box.checkState() != Qt.CheckState.PartiallyChecked, box.text()
    # ...and the legend that used to explain the square is gone with it. A page that
    # still needs a paragraph about its checkboxes has the checkboxes the operator
    # objected to.
    for lab in net.findChildren(QtWidgets.QLabel):
        low = lab.text().lower()
        assert "part-checked" not in low and "partially" not in low, lab.text()
        assert "3-state" not in low and "tri-state" not in low, lab.text()


def test_every_service_defaults_to_off(wiz):
    """ASK 1 ("optional services and edge ai unchecked") and ASK 4 ("tor onion services
    are optional and off and unchecked by default"), on the arriving page.

    Swept over the whole registry rather than the three the asks name: the operator named
    the ones they happened to see, and "off by default unless it is genuinely on by
    default" (ask 23) is the rule behind all of them. `snort` and BUILTIN_DEFAULT_SERVICES
    are the deliberate counter-examples asserted at the end — they are genuinely ON by
    default, so pre-checking them is the honest thing and a blanket "everything starts
    unchecked" would be wrong in the other direction."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    for slug, box in net.service_boxes.items():
        if slug in BUILTIN_DEFAULT_SERVICES:
            continue
        assert not box.isChecked(), f"service {slug} arrives pre-checked"
    assert not net.edge_ai.isChecked(), "edge AI arrives pre-checked (ask 1)"
    assert not net.edge_ai_analysis.isChecked()
    assert not net.aide.isChecked()
    assert not net.tor_onion.isChecked(), "tor onion arrives pre-checked (ask 4)"
    # the whole-set preset arrives on "pick individually", not on a set-replacing shortcut
    assert net.services_preset.currentIndex() == _PRESET_CUSTOM
    # ...and the counter-examples: ask 23 says pre-check what is genuinely on by default.
    assert net.snort.isChecked(), (
        "snort defaults True in ImageConfig — unchecking it here would make the box lie "
        "in the other direction, which is the same bug")
    for slug in BUILTIN_DEFAULT_SERVICES:
        assert net.service_boxes[slug].isChecked(), (
            f"{slug} is in the builders' default set — an untouched build ships it, so an "
            "unticked box would be the same lie inverted "
            "(test_the_builtin_default_set_arrives_ticked_and_is_really_removable)")


def test_definitely_off_reaches_the_argv_for_every_dedicated_flag(wiz):
    """The half of asks 1/4 that is not about pixels: "unchecked" must MEAN off.

    An unchecked box that emitted nothing would leave a brand.conf's WANT_TOR=true in
    force (brand.conf is sourced at build-x86-host-stage4.sh:841, BEFORE the arg loop),
    so the operator would be looking at an unticked box over a running Tor onion — the
    exact ambiguity ask 1 is about, merely relocated. Every dedicated-flag service
    therefore emits its --no-<flag> arm from the default page."""
    mesh(wiz)
    advance_to(wiz, wizard_mod.NetworkPage)
    advance_to(wiz, wizard_mod.KeyZipPage)          # Next past Network collects
    c = wiz.cfg
    assert (c.tor_onion_service, c.character_studio, c.character_forge, c.edge_ai_tts,
            c.edge_ai_service, c.aide) == ("off",) * 6
    args = c.to_cli_args()
    for flag in ("--no-tor", "--no-character-studio", "--no-character-forge",
                 "--no-edge-ai-tts", "--no-edge-ai", "--no-aide"):
        assert flag in args, f"{flag} missing — unchecked stopped meaning definitely off"
    for flag in ("--with-tor", "--with-character-studio", "--with-character-forge",
                 "--with-edge-ai-tts", "--with-edge-ai", "--with-aide"):
        assert flag not in args, flag


def test_toggling_a_row_changes_exactly_that_row_and_nothing_else(wiz):
    """Toggling emits EXACTLY the right argv — asserted per row, on both channels, by
    diffing the whole argv rather than by looking for one flag in it.

    An assertion that merely finds `--with-tor` present would pass a page that also
    switched on three neighbours; the diff catches that. The expected token per row is
    derived from _FLAG_SERVICE_FIELDS + the catalog, so a row added later is covered
    without editing this test.

    Each row is driven AWAY from whatever it arrives at and back, not blindly ticked ON:
    the builders' default set arrives ticked, so `setChecked(True)` on `phpbb` is a no-op
    and the whole assertion would have been about nothing. The untick direction is also
    the one that carries the fix — before it, unticking `phpbb` left the forum running."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    offered = [s for s, item in net._svc_items.items() if not item.isHidden()]
    assert offered, "no service rows offered on an x86 mesh node — test would be vacuous"

    def collect():
        page = wiz.currentPage()
        assert isinstance(page, wizard_mod.NetworkPage)
        page.validatePage()
        return set(wiz.cfg.to_cli_args())

    base = collect()
    base_list = list(wiz.cfg.optional_services)
    seen, directions = set(), set()
    for slug in offered:
        box = net.service_boxes[slug]
        was = box.isChecked()
        box.setChecked(not was)
        after = collect()
        now_list = list(wiz.cfg.optional_services)
        added, removed = after - base, base - after
        channel = net._channel(slug)
        seen.add(channel)
        directions.add(was)
        if channel == "flag":
            assert not was, (
                f"{slug} arrives ON — this branch's --with-/--no- expectations assume the "
                "tick direction and would be asserting the wrong arm")
            _fld, tri = _FLAG_SERVICE_FIELDS[slug]
            if tri:
                # a --with-/--no- PAIR: ticking swaps one arm for the other, nothing else
                assert added == {f"--with-{slug}"}, f"{slug}: added {added}"
                assert removed == {f"--no-{slug}"}, f"{slug}: removed {removed}"
            else:
                # a single positive flag (games): ticking ADDS it and removes nothing
                assert added == {f"--enable-{slug}"}, f"{slug}: added {added}"
                assert removed == set(), f"{slug}: removed {removed}"
        else:
            # The slug channel is ONE argv element carrying the WHOLE list, so the diff is
            # about the list's contents. Both directions asserted, including the one the
            # fix is about: unticking a builder-default row must actually REMOVE it (it
            # used to leave the list empty, which the builder re-defaulted right back).
            gained, lost = set(now_list) - set(base_list), set(base_list) - set(now_list)
            assert (gained, lost) == ((set(), {slug}) if was else ({slug}, set())), (
                f"{slug}: toggling it gained {gained} and lost {lost}")
            # …and NOTHING outside that one value element moved.
            assert added == {" ".join(now_list)}, f"{slug}: added {added}"
            assert removed == {" ".join(base_list)}, f"{slug}: removed {removed}"
        box.setChecked(was)
        assert collect() == base, f"{slug}: restoring the row did not restore the argv"
    assert seen == {"flag", "slug"}, (
        f"only the {seen} channel was exercised — an x86 mesh node offers both, so this "
        "test would be pinning half the rule")
    assert directions == {True, False}, (
        f"every offered row arrived in the same state ({directions}) — the builders' "
        "default set is supposed to arrive TICKED and everything else UNTICKED, so this "
        "test was only ever exercising one toggle direction")


# =====================================================================================
# ASK 2 — the exclude-services FIELD is gone from every surface it was on
# =====================================================================================

def test_exclude_services_is_gone_from_every_surface(wiz):
    """ASK 2, verbatim: "remove the exclude services field, it makes no sense".

    Pinned as a sweep over the real page rather than "the attribute is gone", because the
    attribute name is the one thing a reintroduction would be free to change. Nothing on
    the services surface may mention excluding, and no line edit anywhere on the page may
    carry it in a label, placeholder or tooltip."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not hasattr(net, "exclude")
    for attr in ("exclude_services", "exclude_row", "excludes"):
        assert not hasattr(net, attr), attr
    for le in net.findChildren(QtWidgets.QLineEdit):
        blob = (le.placeholderText() + " " + le.toolTip()).lower()
        assert "exclude" not in blob, le.placeholderText()
    for lab in net.services_section.findChildren(QtWidgets.QLabel):
        # the ONE permitted mention is the note explaining why there is no such field
        text = lab.text().lower()
        if "exclude" in text:
            assert "no separate" in text or "why there is no" in text, lab.text()
    # the FLAG survives on purpose (SURVEY §3: the only knob that can subtract a slug a
    # brand.conf injected straight into OPTIONAL_SERVICES) and must not be blanked by a
    # trip through the page.
    wiz.cfg.exclude_services = ["akkoma", "phpbb"]
    net.initializePage()
    net.validatePage()
    assert wiz.cfg.exclude_services == ["akkoma", "phpbb"], (
        "validatePage blanked a value that only reaches the config through -C / a saved "
        "config — removing the WIDGET must not remove the CHANNEL")


# =====================================================================================
# ASK 23 — one TABLE for services AND apps
# =====================================================================================

def test_the_services_surface_is_one_table_with_options_as_columns(wiz):
    """ASK 23's shape. A table with the OPTIONS as columns, groups as expandable rows,
    and per-row dropdowns/fields where the question has named values or free text."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    t = net.services_table
    assert isinstance(t, QtWidgets.QTreeWidget)
    assert t.columnCount() == len(_SVC_HEADERS)
    hdr = t.headerItem()
    assert [hdr.text(i) for i in range(t.columnCount())] == list(_SVC_HEADERS)
    # groups are real expanders, not bold labels pretending to be one
    for title, _slugs in SERVICE_GROUPS:
        item = net.group_items[title]
        assert item.parent() is None, f"{title} is not a top-level group row"
    # per-row dropdowns and fields really are in the table (ask 23's "dropdowns, fields")
    assert t.itemWidget(net.edge_ai_item, 2) is net.edge_ai_runtime
    assert isinstance(net.edge_ai_runtime, QtWidgets.QComboBox)
    a_backing = next(iter(net.managed_rows.values()))
    assert isinstance(a_backing[0], QtWidgets.QComboBox)
    assert isinstance(a_backing[1], QtWidgets.QLineEdit)


def test_every_offered_row_says_what_enabling_it_does(wiz):
    """ASK 5's surviving requirement inside ask 23's shape: "a clear name and a one-line
    description". A bare slug in a column was the whole complaint."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    checked = 0
    for slug, item in net._svc_items.items():
        if item.isHidden():
            continue
        assert item.text(_SVC_COL_NAME) == slug
        desc = item.text(_SVC_COL_DESC).strip()
        assert len(desc) > 20, f"{slug} has no description of what enabling it does"
        assert item.toolTip(_SVC_COL_DESC).strip() == desc
        checked += 1
    # NON-VACUITY. Every assertion above sits behind a `continue`, so a change that
    # hid every row would turn this test into an empty loop that passes — the
    # can't-fail shape this codebase has been bitten by before.
    assert checked >= 8, (
        f"only {checked} rows were actually examined — an x86 mesh node offers more "
        "than that, so this test had stopped checking anything")


def test_no_service_appears_twice_on_the_screen(wiz):
    """THE REGRESSION ASK 23 NAMES. `character-forge` was on the old page TWICE — once as
    a dedicated-flag checkbox, once as a row in the slug list — with nothing saying they
    were one service. One row per service is the fix, and it must stay one row."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    names = []
    it = QtWidgets.QTreeWidgetItemIterator(net.services_table)
    while it.value():
        item = it.value()
        if not item.isHidden() and item.childCount() == 0:
            names.append(item.text(_SVC_COL_NAME))
        it += 1
    dupes = {n for n in names if names.count(n) > 1}
    assert not dupes, f"these appear more than once on the services screen: {dupes}"
    # the named aliases really are the SAME widget object, never a second checkbox
    assert net.character_forge is net.service_boxes["character-forge"]
    assert net.tor_onion is net.service_boxes["tor"]


def test_group_grey_never_over_greys_a_supported_service(wiz):
    """The safety proof for folding the dedicated-flag rows INSIDE `services_box`.

    gate_widgets("optional_services", services_box) greys the whole group on a platform
    with no --optional-services. That is only safe because every dedicated flag's
    platform set is a SUBSET of optional_services' — otherwise the group grey would
    silently disable a box whose own builder would have taken it. Asserted against
    PLATFORM_FIELD_SUPPORT rather than against a restated pair of tuples, so a flag whose
    platform set later WIDENS fails here instead of shipping a dead control.

    (This is the test gui/pages/network.py's GATING NOTE names.)"""
    svc_platforms = set(PLATFORM_FIELD_SUPPORT["optional_services"])
    for slug, (fld, _tri) in _FLAG_SERVICE_FIELDS.items():
        flag_platforms = set(PLATFORM_FIELD_SUPPORT[fld])
        assert flag_platforms <= svc_platforms, (
            f"{slug} ({fld}) is parsed on {flag_platforms - svc_platforms}, where the "
            "services group is greyed as a unit — its row would be dead there")
    # non-vacuity: the subset relation is not trivially true because both sides are equal
    assert any(set(PLATFORM_FIELD_SUPPORT[f]) < svc_platforms
               for f, _t in _FLAG_SERVICE_FIELDS.values()), (
        "no flag is a STRICT subset — the assertion above would be vacuous")


def test_service_descriptions_and_groups_cover_the_whole_catalog():
    """The table renders SERVICE_GROUPS and captions from SERVICE_DESCRIPTIONS, so a slug
    missing from either lands on screen as a bare identifier again (ask 5's complaint) or
    silently never lands at all. Both directions pinned.

    `edge-ai-tts` is deliberately in the groups but NOT in the slug catalog: it is a
    dedicated-flag-only service (--with-edge-ai-tts), which is exactly the kind of row the
    unified table exists to carry."""
    catalog = set(OPTIONAL_SERVICES_CHOICES) | set(INFRA_SERVICES_CHOICES)
    grouped = [s for _t, slugs in SERVICE_GROUPS for s in slugs]
    assert len(grouped) == len(set(grouped)), "a slug is listed in two groups"
    assert catalog <= set(grouped), f"never rendered: {catalog - set(grouped)}"
    flag_only = set(grouped) - catalog
    assert flag_only == {"edge-ai-tts"}, (
        f"unexpected non-catalog rows {flag_only} — each needs a dedicated flag")
    assert set(grouped) <= set(SERVICE_DESCRIPTIONS), (
        f"no description: {set(grouped) - set(SERVICE_DESCRIPTIONS)}")
    assert set(SERVICE_DESCRIPTIONS) <= set(grouped), (
        f"orphaned description: {set(SERVICE_DESCRIPTIONS) - set(grouped)}")


def test_builtin_default_services_match_both_builders():
    """BUILTIN_DEFAULT_SERVICES is the set the table arrives with TICKED, so it must be
    the builders' real default and not a comment that rotted: pre-ticking the wrong three
    would put the lie back with the boxes the other way up. Parsed out of both scripts."""
    pat = re.compile(r'OPTIONAL_SERVICES="\$\{OPTIONAL_SERVICES:-([^}"]*)\}"')
    seen = {}
    for script in ("build-x86-host-stage4.sh", "build-rpi5-stage4.sh"):
        path = os.path.join(GENERATOR_DIR, script)
        with open(path, encoding="utf-8") as fh:
            found = pat.findall(fh.read())
        assert found, f"{script} no longer has an OPTIONAL_SERVICES default sentinel"
        seen[script] = set(found[0].split())
    for script, slugs in seen.items():
        assert slugs == set(BUILTIN_DEFAULT_SERVICES), (
            f"{script} defaults to {sorted(slugs)}, the wizard claims "
            f"{sorted(BUILTIN_DEFAULT_SERVICES)}")


def test_user_level_services_match_both_builders():
    """USER_LEVEL_SERVICES is what the "every user-level service" preset EXPANDS TO, and
    the page now greys+ticks exactly those rows on that preset. Same anti-rot treatment as
    BUILTIN_DEFAULT_SERVICES: parsed out of both scripts, not restated in a comment."""
    pat = re.compile(r'^USER_LEVEL_SERVICES="([^"]*)"', re.M)
    for script in ("build-x86-host-stage4.sh", "build-rpi5-stage4.sh"):
        with open(os.path.join(GENERATOR_DIR, script), encoding="utf-8") as fh:
            found = pat.findall(fh.read())
        assert found, f"{script} no longer declares USER_LEVEL_SERVICES"
        assert set(found[0].split()) == set(USER_LEVEL_SERVICES), (
            f"{script} expands 'all' to {sorted(found[0].split())}, the wizard claims "
            f"{sorted(USER_LEVEL_SERVICES)}")
    # non-vacuity for the preset rule this constant drives: it must be a STRICT superset
    # of the builders' default set (or "all" would tick nothing new) and it must NOT cover
    # the infra slugs (or nothing would be left live underneath the preset).
    assert set(BUILTIN_DEFAULT_SERVICES) < set(USER_LEVEL_SERVICES)
    assert set(INFRA_SERVICES_CHOICES).isdisjoint(USER_LEVEL_SERVICES)


# =====================================================================================
# THE CHECKBOX MUST NOT LIE — the row's state vs what the builder actually bakes
# =====================================================================================
# Verified against the BUILDERS, by resolving what OPTIONAL_SERVICES an emitted argv ends
# up with, exactly as build-x86-host-stage4.sh does it. Two verify findings said the same
# thing from opposite ends and neither was reachable by diffing argv alone:
#
#   * the "every user-level service" preset left games / character-studio / character-forge
#     ENABLED and UNCHECKED (and emitted --no-character-studio) while --all-services baked
#     all three — the --no- arms are fold-SKIPS (:1124-1130, :1140-1146 are
#     `if [ "${WANT_…}" = "true" ]` with no false arm) and cannot subtract from the
#     expansion at :1067-1069;
#   * the arriving mesh screen showed akkoma / tuwunel / phpbb UNCHECKED while
#     `OPTIONAL_SERVICES="${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}"` (:134) built all
#     three, which also made unticking `phpbb` a no-op.
#
# Both are "the box reads OFF, the service is ON", which is ask 1/4/23's complaint in its
# most literal form. So the invariant is asserted directly rather than through argv
# tokens: FOR EVERY ROW ON SCREEN, checked <=> the builder bakes it.

# The dedicated-flag fold-ins, `flag -> slug`. Every one of these is a `true`-arm-only
# `case` that ADDS the slug to OPTIONAL_SERVICES; there is no `--no-<x>` arm that removes
# one, which is precisely why a --no- flag cannot be trusted to mean "not baked".
_FOLD_INS = {"--with-tor": "tor",
             "--with-character-studio": "character-studio",
             "--with-character-forge": "character-forge",
             "--with-edge-ai-tts": "edge-ai-tts",
             "--enable-games": "games"}


def _builder_service_sets(script):
    """(USER_LEVEL_SERVICES, the built-in default set) parsed out of a builder script."""
    with open(os.path.join(GENERATOR_DIR, script), encoding="utf-8") as fh:
        text = fh.read()
    ul = re.search(r'^USER_LEVEL_SERVICES="([^"]*)"', text, re.M)
    dflt = re.search(r'OPTIONAL_SERVICES="\$\{OPTIONAL_SERVICES:-([^}"]*)\}"', text)
    assert ul and dflt, f"{script} no longer declares its service sets where we parse them"
    return ul.group(1).split(), dflt.group(1).split()


def resolve_optional_services(argv, script="build-x86-host-stage4.sh"):
    """The OPTIONAL_SERVICES set this argv ACTUALLY produces, in the builder's own order:
    built-in default -> --optional-services / --all-services -> the 'all' expansion ->
    the opt-in fold-ins. (EXCLUDE_SERVICES is applied last by the builder and is not a GUI
    knob since ask 2, so it is not modelled here; a test that set it would be testing the
    model.) Reads the two sets out of the script so it cannot drift from the builder.

    Assumes a cluster NODE role, which is what every caller below builds: the fold-ins are
    additionally guarded by `&& ${ROLE_CLIENT}` warn-and-drop arms that only fire on
    desktop-class images."""
    user_level, builtin = _builder_service_sets(script)
    services = list(builtin)
    i = 0
    while i < len(argv):
        if argv[i] == "--optional-services":
            services = argv[i + 1].split()
            i += 2
            continue
        if argv[i] == "--all-services":
            services = ["all"]
        i += 1
    if "all" in services:
        services = list(user_level)
    for flag, slug in _FOLD_INS.items():
        if flag in argv and slug not in services:
            services.append(slug)
    return set(services)


def _rows_on_screen(net):
    """slug -> is the box ticked, for every service row the operator can actually see."""
    return {s: b.isChecked() for s, b in net.service_boxes.items()
            if not net._svc_items[s].isHidden()}


@pytest.mark.parametrize("preset", [_PRESET_CUSTOM, _PRESET_NONE, _PRESET_ALL])
def test_no_row_reads_off_while_the_build_ships_it(wiz, preset):
    """THE REGRESSION, both findings, one invariant: on every preset, a row is ticked if
    and only if the builder ends up baking that service.

    Fails on the pre-fix page in BOTH directions — `character-studio` unticked but baked
    under the 'all' preset, `akkoma` unticked but baked under 'custom'."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.services_preset.setCurrentIndex(preset)
    on_screen = _rows_on_screen(net)
    assert len(on_screen) >= 8, (
        f"only {len(on_screen)} rows visible on an x86 mesh node — the sweep would be "
        "checking almost nothing")
    advance_to(wiz, wizard_mod.KeyZipPage)
    baked = resolve_optional_services(wiz.cfg.to_cli_args())
    for slug, checked in sorted(on_screen.items()):
        assert checked == (slug in baked), (
            f"[preset {preset}] the {slug} row reads "
            f"{'ON' if checked else 'OFF'} but the build "
            f"{'ships' if slug in baked else 'does not ship'} it. argv: "
            f"{' '.join(wiz.cfg.to_cli_args())}")


def test_the_whole_set_preset_locks_the_rows_it_decides_and_leaves_the_rest_live(wiz):
    """FINDING 1's root cause, pinned at the widget. --all-services replaces
    OPTIONAL_SERVICES with USER_LEVEL_SERVICES *before* the opt-in folds, so a row in that
    set is baked no matter what its own flag says — it must be ticked and locked, not left
    enabled-and-unticked over a service that is going to be built.

    A row OUTSIDE that set is still a real choice underneath the preset (--all-services
    does not set WANT_TOR), so tor and edge-ai-tts stay live. That distinction is the
    whole finding: the old code applied the tor/edge-ai-tts reasoning to all five
    dedicated-flag rows, and it is only true for those two."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.services_preset.setCurrentIndex(_PRESET_ALL)
    decided, left_alone = [], []
    for slug, box in net.service_boxes.items():
        if net._svc_items[slug].isHidden():
            continue
        (decided if slug in USER_LEVEL_SERVICES else left_alone).append(slug)
        if slug in USER_LEVEL_SERVICES:
            assert box.isChecked() and not box.isEnabled(), (
                f"{slug} is expanded into OPTIONAL_SERVICES by --all-services but its row "
                f"is checked={box.isChecked()} enabled={box.isEnabled()}")
        else:
            assert box.isEnabled(), (
                f"{slug} is NOT in the 'all' expansion — the preset must leave it live")
    assert len(decided) >= 6 and left_alone, (
        f"decided={decided} left_alone={left_alone} — this test needs both kinds of row "
        "on screen to be about anything")
    # …and no --no-<x> for a service the preset bakes: the builder has no false arm for
    # those flags, so emitting one would be a claim the build cannot honour.
    advance_to(wiz, wizard_mod.KeyZipPage)
    args = wiz.cfg.to_cli_args()
    assert "--all-services" in args
    for slug in decided:
        assert f"--no-{slug}" not in args, (
            f"--no-{slug} emitted beside --all-services, which bakes {slug} anyway")


def test_the_preset_gives_the_operators_own_ticks_back(wiz):
    """Locking the rows must not EAT them. Glancing at a whole-set preset and changing
    your mind restores the selection you made by hand — otherwise the fix for finding 1
    would silently rewrite a custom selection into "everything"."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    net.service_boxes["phpbb"].setChecked(False)
    net.service_boxes["owncast"].setChecked(True)
    mine = {s: b.isChecked() for s, b in net.service_boxes.items()}
    net.services_preset.setCurrentIndex(_PRESET_ALL)
    assert net.service_boxes["phpbb"].isChecked()          # the preset really took over
    net.services_preset.setCurrentIndex(_PRESET_NONE)      # …and none->all does not stomp
    net.services_preset.setCurrentIndex(_PRESET_CUSTOM)
    assert {s: b.isChecked() for s, b in net.service_boxes.items()} == mine
    assert all(b.isEnabled() for b in net.service_boxes.values())


def test_leaving_an_arriving_whole_set_preset_hands_its_rows_over(wiz):
    """The other side of the restore, and the reason the "forget held ticks" reset happens
    AFTER the preset is applied rather than before.

    A page that ARRIVES on "every user-level service" (a loaded config / a revisit) has
    nothing of the operator's held back, so switching to "pick individually" must hand
    them the eight rows exactly as the preset left them — ticked and now editable — and
    unticking one is how "all except the forge" is reached. Restoring a pre-forced empty
    snapshot instead would blank the table, and a blank table now means explicit-none: a
    fine-tuning gesture would have silently become a different build."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    wiz.cfg.optional_services = [SERVICES_ALL]
    net.initializePage()
    assert net.services_preset.currentIndex() == _PRESET_ALL
    net.services_preset.setCurrentIndex(_PRESET_CUSTOM)
    handed = [s for s in USER_LEVEL_SERVICES if not net._svc_items[s].isHidden()]
    assert len(handed) >= 6, f"only {handed} on screen — nothing to hand over"
    for slug in handed:
        box = net.service_boxes[slug]
        assert box.isChecked() and box.isEnabled(), (
            f"{slug} came back checked={box.isChecked()} enabled={box.isEnabled()} — the "
            "table was blanked on the way out of the preset")
    net.service_boxes["character-forge"].setChecked(False)
    net.validatePage()
    baked = resolve_optional_services(wiz.cfg.to_cli_args())
    assert baked == set(handed) - {"character-forge"}, sorted(baked)


# =====================================================================================
# FINDING 2 — the builders' own default set arrives TICKED, and unticking it works
# =====================================================================================

def test_the_builtin_default_set_arrives_ticked_and_is_really_removable(wiz):
    """The three services every untouched mesh ships arrive TICKED (ask 23: "only
    pre-check what is genuinely on by default"), and — the half that is not cosmetic —
    unticking one genuinely stops it being built.

    Before the fix `--optional-services` was emitted only for rows the operator ticked, so
    with nothing ticked no flag went out and the builder's own
    `OPTIONAL_SERVICES="${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}"` put all three back:
    unticking `phpbb` left the forum running and the screen said otherwise."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    for slug in BUILTIN_DEFAULT_SERVICES:
        assert net.service_boxes[slug].isChecked(), f"{slug} does not arrive ticked"
    net.service_boxes["phpbb"].setChecked(False)
    advance_to(wiz, wizard_mod.KeyZipPage)
    baked = resolve_optional_services(wiz.cfg.to_cli_args())
    assert "phpbb" not in baked, (
        "unticking the forum did not turn it off — the emitted argv resolves to "
        f"{sorted(baked)}")
    assert {"akkoma", "tuwunel"} <= baked, (
        f"unticking phpbb took its neighbours with it: {sorted(baked)}")
    # …and the choice ROUND-TRIPS: re-entering the page shows what was chosen, not the
    # defaults re-applied over the top. The seed must fire only for a config that carries
    # no selection at all, or "off by default" would become "off until you look away".
    #
    # initializePage() is called EXPLICITLY. Walking back with back_to() does not re-run
    # it — QWizard initializes a page on the way FORWARD — so a back-then-assert reads the
    # widget state the operator left behind and proves nothing about re-seeding. (This
    # test passed a "seed on every visit" mutation until the call went in.)
    back_to(wiz, wizard_mod.NetworkPage)
    net.initializePage()
    assert not net.service_boxes["phpbb"].isChecked(), (
        "phpbb was re-ticked from the builder defaults over an explicit selection")
    assert net.service_boxes["akkoma"].isChecked()


def test_unticking_every_row_means_none_not_the_builder_default(wiz):
    """The end of the same slope. With the default set arriving ticked, "no boxes ticked"
    is an ANSWER — so it must emit the explicit-none sentinel, or the builder re-defaults
    the three straight back and the operator has cleared the screen for nothing (and the
    state would not even round-trip, since [] re-ticks them on the next visit)."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    for slug, box in net.service_boxes.items():
        if not net._svc_items[slug].isHidden():
            box.setChecked(False)
    advance_to(wiz, wizard_mod.KeyZipPage)
    assert wiz.cfg.optional_services == [SERVICES_NONE]
    args = wiz.cfg.to_cli_args()
    assert ("--optional-services", "") in pairs(args)
    assert resolve_optional_services(args) == set(), (
        f"a cleared screen still builds {sorted(resolve_optional_services(args))}")


def test_all_except_one_is_expressible_from_the_table(wiz):
    """The capability ask 2 took away with the --exclude-services field, shown to still
    exist. `--optional-services` REPLACES rather than adds, so "everything except the
    forge" is seven ticks — which is only usable now that the default three arrive ticked
    and the list is what the screen shows."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    wanted = [s for s in USER_LEVEL_SERVICES if s != "character-forge"]
    for slug in wanted:
        net.service_boxes[slug].setChecked(True)
    advance_to(wiz, wizard_mod.KeyZipPage)
    baked = resolve_optional_services(wiz.cfg.to_cli_args())
    assert baked == set(wanted), f"asked for all-but-the-forge, got {sorted(baked)}"


# =====================================================================================
# ASKS 3 + 11 — standalone-desktop surfaces are UNREACHABLE in the mesh NODE flow
# =====================================================================================

# The standalone-desktop-only fields, by the config field id each carries, paired with
# how to reach its widget from the wizard. Field ids (not widget names) because the ask is
# about what can be SET on a node image, and the field is what reaches the argv.
_STANDALONE_ONLY_FIELDS = (
    ("local_pass", "home", "local_pass"),        # ask 11: the desktop login password
    # ("standalone", "home", "standalone") — ask 21 MOVED this checkbox to RolePage, and
    # RolePage is not visited in ANY mesh flow (WorklistPage owns roles there), so the
    # posture is now unreachable on mesh by construction rather than by gating. Asserted
    # directly below instead of through this table, which probes HomePage.
    ("media_data", "home", "media_box"),         # ask 3: a Steam library on a PKI node
    ("home_mode", "home", "mode"),               # ask 3: home provisioning
    ("egress_vpn", "network", "egress_row"),     # ask 3: desktop-class egress VPN
)


def _pages(wiz):
    net = advance_to(wiz, wizard_mod.NetworkPage)
    home = advance_to(wiz, wizard_mod.HomePage)
    return {"network": net, "home": home}


def test_standalone_desktop_fields_are_unreachable_in_the_mesh_node_flow(wiz):
    """ASKS 3 and 11 together: "options for standalone desktops shouldnt appear in the
    mesh wizard" / "your login/standalone account doesnt belong on mesh builds".

    UNREACHABLE, asserted by field id on the real offscreen wizard — not greyed, not
    merely absent from a screenshot."""
    mesh(wiz, "pki.x86")
    pages = _pages(wiz)
    for fld, page_key, attr in _STANDALONE_ONLY_FIELDS:
        page = pages[page_key]
        w = getattr(page, attr)
        assert not w.isVisibleTo(page), f"{fld} is reachable on a mesh NODE flow"


def test_the_same_fields_stay_reachable_on_the_desktop_mesh_track(wiz):
    """The other half of ask 11 — "keep that to the desktop mesh track" — and the
    non-vacuity proof for the test above: a gate that hid these everywhere would pass it
    while deleting the flow they belong to.

    A mesh worklist made entirely of desktop rows IS that track (build-rpi5-stage4.sh:998
    sets ROLE_CLIENT=true for exactly this arm), so the login and home surfaces are still
    on screen there."""
    mesh(wiz, "rpi5-desktop.rpi5")
    pages = _pages(wiz)
    home = pages["home"]
    assert home.login.isVisibleTo(home), "the desktop mesh track lost its login group"
    assert home.local_pass.isVisibleTo(home)
    # NOT home.standalone: ask 21 moved that checkbox to RolePage. See
    # test_standalone_posture_is_unreachable_in_every_mesh_flow for what that costs.
    assert home.media_box.isVisibleTo(home)
    assert home.mode.isVisibleTo(home)


def test_one_desktop_row_does_not_unlock_the_surfaces_for_a_whole_node_worklist(wiz):
    """THE ACTUAL BUG behind asks 3 and 11, pinned at the axis it lived on.

    WorklistPage.validatePage stamps the shared base with entries[0].role, and
    `rpi5-desktop` / `jetson-desktop` are both mesh roles — so a worklist whose FIRST
    checked row happened to be a desktop made the base read as desktop-class and unlocked
    every standalone surface for EVERY node in the list. The base config below really is
    desktop-class (asserted, so the test cannot pass by accident on a worklist that
    ordered itself the other way), and the surfaces are hidden anyway because the
    quantifier is ALL-images, not the base."""
    mesh(wiz, "rpi5-desktop.rpi5", "edge_ai.jetson")
    pages = _pages(wiz)
    entries = [e.id for e in wiz.worklist.entries]
    assert entries[0].startswith("rpi5-desktop"), (
        f"worklist ordered as {entries} — this test needs the desktop row first to be "
        "about anything")
    assert wiz.cfg.role == "rpi5-desktop", "the base is not the desktop-class one"
    home = pages["home"]
    # "standalone" dropped: ask 21 moved it to RolePage, which a mesh flow never visits.
    for attr in ("login", "local_pass", "media_box", "mode"):
        w = getattr(home, attr)
        assert not w.isVisibleTo(home), (
            f"{attr} leaked onto a worklist containing a NODE, because one desktop row "
            "was listed first")


def test_hiding_those_fields_changes_no_argv_for_a_flow_that_never_had_them(wiz):
    """Emission safety for the gate: on a NODE flow the operator was never shown these,
    so the argv must be what it would have been anyway — a gating fix that adds or drops
    a flag is a build change wearing a UI change's clothes.

    `--local-user <default account>` is the deliberate survivor and is asserted PRESENT:
    the x86 builder honours --local-user on every role (build-x86-host-stage4.sh:1597),
    the field defaults to the invoking user (default_local_user()), so blanking it would
    have changed every existing mesh build."""
    mesh(wiz, "pki.x86")
    advance_to(wiz, wizard_mod.BuildPage)
    args = wiz.cfg.to_cli_args()
    assert ("--local-user", default_local_user()) in pairs(args)
    assert "--local-pass" not in args
    assert "--standalone" not in args
    assert "--media-data" not in args and "--no-vaults" not in args
    assert "--egress-vpn" not in args
    assert wiz.cfg.local_pass == "" and wiz.cfg.standalone is False


def test_a_typed_secret_cannot_ride_a_switch_from_desktop_to_node(wiz):
    """The collect half of asks 3/11. A hidden widget KEEPS its text, so a password typed
    while the flow was the desktop mesh track would otherwise be deepcopied by
    WorklistConfig._materialize_one onto every node image in a later worklist."""
    mesh(wiz, "rpi5-desktop.rpi5")
    pages = _pages(wiz)
    pages["home"].local_pass.setText("hunter2")
    # (ask 21) no standalone tick to make here — the checkbox moved to RolePage, which a
    # mesh flow never reaches. local_pass IS the secret this test is about.
    advance_to(wiz, wizard_mod.BuildPage)
    assert wiz.cfg.local_pass == "hunter2"          # in scope: collected as before
    # …now walk the SAME wizard back and switch it to a node worklist
    while not isinstance(wiz.currentPage(), wizard_mod.WorklistPage):
        wiz.back()
    check_worklist_rows(wiz.currentPage(), "pki.x86")
    advance_to(wiz, wizard_mod.BuildPage)
    assert wiz.cfg.local_pass == "", (
        "a desktop password survived onto a node worklist — the hidden widget still "
        "held it and validatePage collected it anyway")
    assert wiz.cfg.standalone is False
    assert "--local-pass" not in wiz.cfg.to_cli_args()


def test_the_flow_predicates_read_only_the_three_axes(wiz):
    """``ImageAxes`` is a three-field stand-in that ``flow_images`` hands to every scope
    predicate instead of deepcopying a whole ImageConfig per worklist row. That is only
    sound while the predicates read nothing else — a predicate that grew a fourth input
    would silently start reading a DEFAULT off the shim rather than the row's real value,
    and would fail open on precisely the leak asks 3/11 are about.

    Pinned by calling each predicate with an ImageAxes carrying ONLY the three axes and
    asserting it neither raises nor disagrees with the same question asked of a real
    ImageConfig. (This is the test core/config.py's ImageAxes docstring names.)"""
    assert set(ImageAxes.__dataclass_fields__) == {"mode", "role", "platform"}
    for pred in (home_options_allowed, local_login_applies, external_media_applies):
        for mode, role, platform in (("mesh", "pki", "x86"),
                                     ("mesh", "rpi5-desktop", "rpi5"),
                                     ("standalone", "standalone-thick", "x86"),
                                     ("standalone", "orangepizero2", "orangepizero2")):
            shim = pred(ImageAxes(mode=mode, role=role, platform=platform))
            real = pred(ImageConfig(mode=mode, role=role, platform=platform))
            assert shim == real, (
                f"{pred.__name__} disagrees between ImageAxes and ImageConfig for "
                f"{mode}/{role}/{platform} — it reads an axis the shim does not carry")


def test_flow_allows_is_all_images_not_any(wiz):
    """The quantifier, pinned directly. ALL, not ANY: these surfaces live on the SHARED
    mesh base that _materialize_one deepcopies onto every entry, so a value offered
    because ONE row could use it rides onto every OTHER row too."""
    cfg = ImageConfig(mode="mesh", role="rpi5-desktop", platform="x86")
    node = ImageAxes(mode="mesh", role="pki", platform="x86")
    desk = ImageAxes(mode="mesh", role="rpi5-desktop", platform="rpi5")

    class _E:
        def __init__(self, role, platform):
            self.role, self.platform = role, platform

    mixed = [_E("rpi5-desktop", "rpi5"), _E("pki", "x86")]
    all_desk = [_E("rpi5-desktop", "rpi5")]
    assert flow_allows(home_options_allowed, cfg, all_desk) is True
    assert flow_allows(home_options_allowed, cfg, mixed) is False, (
        "ANY instead of ALL — one desktop row would unlock the surface for every node")
    assert home_options_allowed(desk) and not home_options_allowed(node)


# =====================================================================================
# ASK 18 — devices that cannot be a mesh node are excluded from the mesh screen
# =====================================================================================

def test_devices_that_cannot_be_a_mesh_node_are_absent_from_the_mesh_screen(wiz):
    """ASK 18, verbatim: "image/roles that cant be a mesh should be excluded from mesh
    generation options"."""
    wl = mesh(wiz)
    assert wl._info_items, "no non-mesh-capable rows exist — the test would be vacuous"
    for item in wl._info_items:
        assert item.isHidden(), f"{item.text(0)} is on the mesh generation screen"
    assert not wl.show_non_mesh.isChecked(), "ask 18's disclosure defaults to shown"
    # every row still ON the screen really is mesh-capable. Only the CHECKABILITY is
    # asserted: an `assert not item.isHidden() or True` used to sit here as well, which is
    # a tautology — `wl.rows` legitimately contains rows the arch filter has hidden, so
    # there was no visibility claim to make and the line read as coverage it never gave.
    for rid, item in wl.rows.items():
        assert item.flags() & Qt.ItemFlag.ItemIsUserCheckable, rid


def test_the_excluded_rows_come_back_read_only_on_request(wiz):
    """#351's guarantee, kept: "why is my Orange Pi not here" is a real question this
    screen should answer, so the rows are EXCLUDED, not deleted — one labelled checkbox
    brings them back, and they are still uncheckable when shown."""
    wl = mesh(wiz)
    wl.show_non_mesh.setChecked(True)
    shown = [i for i in wl._info_items if not i.isHidden()]
    assert shown, "the disclosure checkbox brought nothing back"
    for item in shown:
        assert item.flags() == Qt.ItemFlag.NoItemFlags, (
            f"{item.text(0)} became selectable/checkable when disclosed")
    assert str(len(wl._info_items)) in wl.show_non_mesh.text(), (
        "the disclosure does not say how many devices it is hiding")
    wl.show_non_mesh.setChecked(False)
    assert all(i.isHidden() for i in wl._info_items)


def test_mesh_capability_is_derived_from_the_catalog_not_a_hand_kept_list():
    """The predicate must stay derived, or ask 18 becomes a list that rots: a device that
    GAINS a mesh role has to appear on the screen in the same commit that gives it one."""
    cat = device_catalog.load_catalog()
    for dev in cat.devices:
        expected = (device_catalog.selectable(dev.id)
                    and bool(device_catalog.roles_for(dev.id, "mesh")))
        assert device_catalog.mesh_capable(dev.id) is expected, dev.id
    ids = [d.id for d in cat.devices]
    capable = [i for i in ids if device_catalog.mesh_capable(i)]
    assert capable and len(capable) < len(ids), (
        "mesh_capable is all-or-nothing — ask 18 would be a no-op")


# =====================================================================================
# The section's own coherence (ask 5) — no leftovers from what it replaced
# =====================================================================================

def test_the_retired_service_widgets_are_gone_for_good(wiz):
    """ASK 5's redo, pinned as the absence of every widget it replaced, so a later commit
    cannot half-restore the old surface beside the new one."""
    mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    for attr in ("services", "services_none", "services_all", "exclude",
                 "edge_ai_section", "edge_ai_box", "managed_section", "managed_box"):
        assert not hasattr(net, attr), f"{attr} came back"
    # the module-level tri-state helpers left this page with the third state
    assert not hasattr(network_mod, "_tri_state")
    assert not hasattr(network_mod, "_tri_combo")
    # exactly ONE scrolling list-of-services widget is permitted: the table
    lists = net.services_section.findChildren(QtWidgets.QListWidget)
    assert lists == [], "a QListWidget of slugs came back beside the table"


@pytest.mark.parametrize("entry", ["pki.x86", "rpi5-desktop.rpi5"])
def test_standalone_posture_is_unreachable_in_every_mesh_flow(wiz, entry):
    """Ask 21 moved the --standalone checkbox off HomePage onto RolePage. RolePage is
    NOT VISITED in a mesh flow at all — WorklistPage owns roles there — so the posture is
    now unreachable on mesh by construction, not by gating.

    For the NODE flow that is strictly stronger than asks 3/11 wanted: the field cannot
    be set even in principle.

    For the DESKTOP MESH TRACK it is a real reduction, asserted here rather than left
    implicit: ask 11 said "keep that to the desktop mesh track", and that track can no
    longer offer it. Whether --standalone should return there (on WorklistPage, the only
    mesh role surface) is an OPERATOR DECISION, deliberately not made here.
    """
    import hugmesh_studio.gui.wizard as _wm
    mesh(wiz, entry)
    try:
        advance_to(wiz, _wm.RolePage)
        reached = True
    except AssertionError:
        reached = False
    assert not reached, (
        f"RolePage became reachable on mesh({entry}) — the standalone posture is "
        "settable on a mesh image again; re-check asks 3/11/21 together")
