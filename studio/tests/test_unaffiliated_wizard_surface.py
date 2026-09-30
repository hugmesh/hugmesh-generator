"""The unaffiliated desktop wizard must not offer AFFILIATION machinery — but it
must still offer a LOOK.

Two operator reports, a fortnight apart, pull this page set in opposite directions,
and this file pins the line between them.

FIRST REPORT: "unaffiliated desktop image wizard still shows options like mesh
services and branding and login when it shouldn't". ``standalone-unaffiliated``
builds a plain Gentoo desktop with ZERO HugMesh affiliation, and at the time
``ImageConfig._check_unaffiliated_conflicts()`` hard-errored on every branding field
alike, so the wizard was showing choices whose only possible outcomes were "leave it
alone" or "break the build". BrandingPage removed itself; the NetworkPage's
"Optional cluster services" picker was hidden.

SECOND REPORT (2026-08-26, session 20260826-151356-64070a, role=standalone-unaffiliated
platform=x86): "standalone menu is asking same questions seemingly multiple times when
nothing should be an image there related to the mesh or domain at all. There should
also be no inbetween menu for configuring domain. There should be the menu for adding
the themes as in the branded images." The last sentence reverses half of the first
report's fix, and DECISION 1 is the resolution:

  IDENTITY stays FORBIDDEN — ``--brand`` / ``--brand-title`` / ``--org`` /
    ``--brand-logo`` / ``--brand-locked`` and a ``--config`` brand profile. A brand
    IS an affiliation: those flags name WHOSE image this is.
  LOOK becomes ALLOWED — ``--theme`` / ``--branding-dir`` / ``--wallpaper`` /
    ``--grub-background`` / ``--grub-theme`` / ``--login-background`` /
    ``--accent-color`` / ``--color-scheme``. A wallpaper names nobody. The builder
    bakes them under NEUTRAL artefact names on this image (/etc/gentoo, /usr/sbin/
    branding, gentoo-background.png), the way the home/installer/media machinery
    already does.

So BrandingPage is IN the flow again for an unaffiliated desktop, with its two
identity widgets hidden and cleared, and the tests below were inverted to match. Each
inverted test keeps a NEGATIVE half: the identity fields must still blank on a role
commit and must still raise from ``to_cli_args()``. A test that merely stopped
checking would let the affiliation leak back.

The property that matters throughout is that hiding or skipping must be
LEAVES THE OUTPUT UNCHANGED (``StudioWizard.nextId``: applies_to may return False "ONLY when
every config field the page emits is already at the mode-correct default"; every
widget hide is paired with a validatePage clear to the dataclass default).
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import (   # noqa: E402
    ImageConfig, SERVICES_NONE, UNAFFILIATED_ROLE,
)
from hugmesh_studio.core.platform_info import HostInfo                  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                             # noqa: E402
from hugmesh_studio.gui.pages.branding import BrandingPage              # noqa: E402
from hugmesh_studio.gui.pages.network import NetworkPage                # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _unaff_cfg(**kw):
    base = dict(mode="standalone", platform="x86", role=UNAFFILIATED_ROLE)
    base.update(kw)
    return ImageConfig(**base)


def _branded_cfg(**kw):
    base = dict(mode="standalone", platform="x86", role="standalone-thick")
    base.update(kw)
    return ImageConfig(**base)


def _page(wiz, cls):
    return wiz.page([i for i in wiz.pageIds() if isinstance(wiz.page(i), cls)][0])


def pairs(args):
    """Adjacent (flag, value) pairs of an argv list — the flag-adjacency helper the
    identity tests use, so `--optional-services ""` is asserted as a PAIR and an empty
    value can never be read off some unrelated flag."""
    return list(zip(args, args[1:]))


# ── the BrandingPage is BACK, minus its identity half ────────────────────────────────
def test_branding_page_applies_to_the_unaffiliated_role(wiz):
    """INVERTED by DECISION 1 (was ..._is_skipped_for_the_unaffiliated_role).

    This assertion used to read ``is False``, and the reason it did was sound at the
    time: every field on the page was a builder hard conflict, so the screen could
    only render greyed behind an apology note. The 2026-08-26 split makes the LOOK
    half legal, which is the operator's own third ask — "There should be the menu for
    adding the themes as in the branded images" — so the page has something real to
    offer again and must be in the flow.

    The negative half of the old contract is NOT dropped; it moves down to
    ``test_the_unaffiliated_page_hides_and_clears_only_the_identity_half``, which
    pins that the two identity widgets are gone and that identity still raises."""
    page = _page(wiz, BrandingPage)
    assert page.applies_to(_unaff_cfg()) is True


def test_branding_page_applies_to_the_composable_unaffiliated_flag(wiz):
    """--unaffiliated (G22) reaches the same builder posture from any x86 client role,
    so it must reach the same wizard surface — the page appears for it too, not just
    for the dedicated role id. (Also inverted; this asserted ``is False``.)"""
    page = _page(wiz, BrandingPage)
    assert page.applies_to(_branded_cfg(unaffiliated=True)) is True


def test_branding_page_still_applies_to_a_branded_desktop(wiz):
    """KEPT VERBATIM. It was the mutation guard for a rule that hid the page from
    everyone; it is now the control case the two inverted tests are measured against
    — a branded desktop's page must be unchanged by any of this."""
    page = _page(wiz, BrandingPage)
    assert page.applies_to(_branded_cfg()) is True


@pytest.mark.parametrize("cfg_kw, axis", [
    (dict(platform="rpi5"), "platform: no ARM builder parses --theme"),
    # role="backend" must carry the COMPOSABLE flag: overriding the role id would
    # also drop the unaffiliated axis, and applies_to short-circuits to True for any
    # affiliated image (the page still hosts the mesh web-login theme). That would
    # make the case pass for the wrong reason and guard nothing.
    (dict(role="backend", unaffiliated=True),
     "role class: a node image takes the brand defaults"),
])
def test_the_page_still_disappears_where_there_is_no_look_to_offer(wiz, cfg_kw, axis):
    """THE REPLACEMENT MUTATION GUARD, and the reason the inversion above is not just
    "assert True everywhere".

    ``applies_to`` no longer keys on the unaffiliated axis at all — it keys on whether
    a themable DESKTOP HALF exists (branding.py ``_desktop_half_allowed``: role class
    desktop AND a platform whose builder parses --theme). So an unaffiliated image
    with nothing to theme must STILL vanish, and still leave the output unchanged by RolePage's
    clear exactly as it did before. A change that simply made applies_to return True
    unconditionally would pass every other test in this section and fail here."""
    page = _page(wiz, BrandingPage)
    assert page.applies_to(_unaff_cfg(**cfg_kw)) is False, axis


def test_the_unaffiliated_page_hides_and_clears_only_the_identity_half(wiz):
    """Where the old page-level skip GOES: down one level, onto two widgets.

    This is the negative half of the three inverted tests above, and the reason
    inverting them does not reopen the affiliation hole. The page is shown, the theme
    cards are live, and exactly two controls are gone — the brand-logo row (the whole
    _row(), caption included, so no orphan label is left behind) and the "Lock
    branding" checkbox. Both are paired with a validatePage clear back to the
    ImageConfig dataclass default, which is what keeps the hide leaving the output unchanged.

    --brand-logo matters more than it looks: it is a hard conflict AND every --theme
    preset ships its own logo.png, which apply_dir installs as the greeter's
    default-user-image. A hidden-but-collected logo would have put an organization's
    mark on the login screen of an image built to carry none."""
    page = _page(wiz, BrandingPage)
    wiz.cfg = _unaff_cfg()
    page.initializePage()

    assert not page.field_rows["brand_logo"].isVisibleTo(page), (
        "the brand-logo row is IDENTITY and must not be offered here")
    assert not page.locked.isVisibleTo(page), (
        "'Lock branding' locks a brand this image does not have")
    # the LOOK half is live in the same breath — the operator's actual ask
    assert page.form.isEnabled(), (
        "the theme form is greyed on the one image the operator asked to theme")
    assert page.unaffiliated_note.isVisibleTo(page), (
        "the page must SAY why identity is missing, not just drop it silently")

    # leaves the output unchanged: drive the hidden controls, commit, and prove nothing escapes
    page.locked.setChecked(True)
    page.validatePage()
    assert wiz.cfg.brand_logo == "" and wiz.cfg.brand_locked is False
    argv = wiz.cfg.to_cli_args()
    assert "--brand-logo" not in argv and "--brand-locked" not in argv


def test_a_branded_desktop_keeps_both_identity_controls(wiz):
    """Mutation guard for the hide above — a gate that ran unconditionally would take
    the logo and the lock away from every branded desktop too."""
    page = _page(wiz, BrandingPage)
    wiz.cfg = _branded_cfg()
    page.initializePage()
    assert page.field_rows["brand_logo"].isVisibleTo(page)
    assert page.locked.isVisibleTo(page)


#: The walk STOPS here rather than entering. ProgressPage.initializePage() calls
#: _start_worker() (progress.py:941 -> :1212), which spawns a real _WorklistWorker
#: QThread and runs an actual image build — hours of work from a unit test, and on
#: this box it aborts the interpreter outright: the thread outlives the wizard's
#: teardown and Qt's qFatal fires from ~QObject ("QThread: Destroyed while thread is
#: still running"). The slug is still RECORDED, so the flow assertions can prove the
#: walk terminates where it should; only the visit is suppressed.
_WALK_STOP = "progress"


def _walk(wiz, cfg, start="role"):
    """Walk the REAL flow from ``start``, returning the page slugs visited in order.

    applies_to is only a promise; nextId() is what the operator walks. Returns slugs
    rather than raw ids so a failure message names the screen the operator would see.

    The page is navigated to FIRST and validated SECOND, and the next id is read
    before the following navigation, so the loop can look at where it is about to go
    and refuse (see _WALK_STOP) without ever having fired that page's
    initializePage."""
    wiz.cfg = cfg
    by_id = {pid: slug for slug, pid in wiz._page_ids.items()}
    seen, cur, guard = [], wiz._page_ids[start], 0
    while cur != -1 and guard < 40:
        slug = by_id.get(cur, cur)
        seen.append(slug)
        if slug == _WALK_STOP:
            break
        wiz.setStartId(cur); wiz.restart(); wiz.setStartId(-1)
        if not wiz.currentPage().validatePage():
            break
        cur = wiz.nextId()
        guard += 1
    return seen


def test_the_wizard_flow_really_includes_the_branding_page(wiz):
    """INVERTED by DECISION 1 (was ..._really_omits_...). Same walk, same machinery,
    opposite expectation — and with the operator's OTHER two complaints pinned in the
    same traversal, because they are all one screen sequence to them.

    The three negatives here are the literal text of the 2026-08-26 report: "nothing
    should be an image there related to the mesh or domain at all" and "there should
    also be no inbetween menu for configuring domain". Those pages are statically
    skipped for standalone (MODE_SKIPPED_PAGES), so this doubles as the regression
    pin that DECISION 1 did not disturb the static skip while re-adding branding."""
    seen = _walk(wiz, _unaff_cfg())
    assert "branding" in seen, (
        f"the theme menu is still unreachable on the operator's own image: {seen}")
    for mesh_plane in ("domains_choice", "domains", "users_choice", "users",
                       "idp", "keyzip", "worklist"):
        assert mesh_plane not in seen, (
            f"a mesh/domain screen leaked into the standalone walk: {mesh_plane}")
    # and no page is offered twice — the report opens with "asking same questions
    # seemingly multiple times", so an actual repeat would be the headline defect.
    assert len(seen) == len(set(seen)), f"a page is visited twice: {seen}"


def test_a_branded_desktop_walks_the_same_screens(wiz):
    """Mutation guard for the walk above: the unaffiliated flow must differ from the
    branded one ONLY where a decision says it does. Since DECISION 1 that is nowhere
    in the page SEQUENCE — the difference moved inside BrandingPage, to two hidden
    identity widgets. If these two walks ever diverge again, a page-level skip has
    come back and the audit that leaves the output unchanged has to be redone with it."""
    assert _walk(wiz, _unaff_cfg()) == _walk(wiz, _branded_cfg())


# ── RolePage blanks IDENTITY and keeps LOOK ──────────────────────────────────────────
#: The two halves of DECISION 1, spelled once. IDENTITY names whose image this is;
#: LOOK only says what the desktop looks like. core.config._check_unaffiliated_conflicts
#: raises on the first list and not the second; build-x86-host-stage4.sh's unaffiliated
#: fold now refuses exactly the same set.
IDENTITY_FIELDS = ("brand", "brand_title", "org", "brand_logo", "brand_locked")
LOOK_FIELDS = ("theme", "branding_dir", "wallpaper", "grub_background", "grub_theme",
               "login_background", "accent_color", "color_scheme")


def test_committing_the_unaffiliated_role_blanks_identity_and_keeps_look(wiz):
    """REWRITTEN by DECISION 1 (was ..._blanks_every_branding_field, asserting all
    nine went to "").

    The old blanket clear is precisely what made the operator's theme menu useless:
    even once BrandingPage was shown again, a visit to RolePage wiped whatever theme
    had been picked. So the LOOK half must now SURVIVE a role commit — while the
    IDENTITY half must still be taken back, because BrandingPage cannot be relied on
    to do it (it removes itself when there is no themable desktop half, and an
    operator can abandon the flow before reaching it).

    Note what identity resets TO. brand/brand_title/org do NOT default to "" — they
    are "hugmesh"/"HugMesh Systems"/"hugmesh", and the builder's conflict test is
    "differs from the neutral identity", not "non-empty". Asserting "" here would
    demand the very value that TRIPS the check."""
    from hugmesh_studio.gui.pages.role import RolePage
    from hugmesh_studio.core.config import _field_default
    page = _page(wiz, RolePage)
    wiz.cfg = _unaff_cfg(theme="dark", wallpaper="/tmp/w.png",
                         grub_theme="/tmp/g", accent_color="#ff0000",
                         brand="acme", brand_title="Acme Ltd", org="acme",
                         brand_logo="/tmp/l.png", brand_locked=True)
    page.initializePage()
    page.validatePage()
    c = wiz.cfg

    # THE NEGATIVE, kept as a negative: affiliation is still taken back.
    for field in IDENTITY_FIELDS:
        assert getattr(c, field) == _field_default(field), (
            f"{field} is IDENTITY and must not survive the unaffiliated role commit")
    assert c.brand_logo == "" and c.brand_locked is False

    # THE POSITIVE, which is the operator's ask: the look survives to the argv.
    assert c.theme == "dark", "the theme was wiped by the role commit again"
    assert c.wallpaper == "/tmp/w.png"
    assert c.grub_theme == "/tmp/g"
    assert c.accent_color == "#ff0000"

    # ...and really reaches the builder, not just the dataclass.
    argv = c.to_cli_args()
    assert "--theme" in argv and "dark" in argv
    assert "--wallpaper" in argv and "--accent-color" in argv
    assert "--brand-logo" not in argv and "--brand-locked" not in argv


def test_identity_is_still_a_hard_conflict_on_an_unaffiliated_image(wiz):
    """The other half of the negative, at the layer that enforces it. Inverting the
    tests above must not quietly turn the whole rule off: an identity field set on an
    unaffiliated image is still a REFUSAL, and a look field still is not."""
    for field, value in (("brand", "acme"), ("brand_title", "Acme Ltd"),
                         ("org", "acme"), ("brand_logo", "/tmp/l.png"),
                         ("brand_locked", True)):
        with pytest.raises(ValueError, match=field):
            _unaff_cfg(**{field: value}).to_cli_args()
    for field, value in (("theme", "dark"), ("wallpaper", "/tmp/w.png"),
                         ("accent_color", "#ff0000"), ("grub_theme", "/tmp/g"),
                         ("branding_dir", "/tmp/b"), ("grub_background", "/tmp/gb.png"),
                         ("login_background", "/tmp/lb.png"), ("color_scheme", "/tmp/c")):
        _unaff_cfg(**{field: value}).to_cli_args()      # must NOT raise


def test_a_branded_role_keeps_its_branding(wiz):
    """Mutation guard for the blanking above — a clear that ran unconditionally would
    silently wipe every branded desktop's theme."""
    from hugmesh_studio.gui.pages.role import RolePage
    page = _page(wiz, RolePage)
    wiz.cfg = _branded_cfg(theme="dark")
    page.initializePage()
    page.validatePage()
    assert wiz.cfg.theme == "dark"


# ── the NetworkPage's cluster-services picker ────────────────────────────────────────
def _shown_net(wiz, cfg):
    pid = [i for i in wiz.pageIds() if isinstance(wiz.page(i), NetworkPage)][0]
    wiz.cfg = cfg
    wiz.setStartId(pid)
    wiz.restart()                      # fires initializePage() with cfg in place
    wiz.setStartId(-1)
    QtWidgets.QApplication.processEvents()
    page = wiz.page(pid)
    assert wiz.currentPage() is page   # non-current pages report everything invisible
    return page


def test_cluster_services_are_hidden_on_an_unaffiliated_image(wiz):
    page = _shown_net(wiz, _unaff_cfg())
    assert not page.services_box.isVisible(), (
        "the optional cluster-services picker is platform machinery — the role exists "
        "to bake none of it")
    assert not page.services_role_note.isVisible(), (
        "the 'accepted but IGNORED' note is redundant once the box is gone")


def test_hiding_the_services_box_leaves_the_emission_neutral(wiz):
    """Hiding a control must never change what gets BUILT — REWRITTEN, because the
    first version read that as "emit no flag", and emitting no flag is the one thing
    that is NOT neutral here.

    The old assertion (`"--optional-services" not in argv`) rested on the builder
    performing the client-role override itself at build-x86-host-stage4.sh
    :1130/:1146/:1162/:1178/:1214. Those five guards exist and each tests
    ${ROLE_CLIENT} — while it is still FALSE. ROLE_CLIENT is declared false at :92,
    re-set false at :1259, and only set true inside the role `case` at
    :1299/:1302/:1318/:1328/:1338 and in the composable `--standalone` fold at :1438,
    every one of which is AFTER :1214. Every line re-verified with `sed -n '<n>p'`
    against the current builder.

    So with nothing emitted the selection is decided by whatever a brand profile
    carries, and on THIS arm the profile does not even need a --config: the builder
    auto-detects `$(pwd)/brand.conf` when none is given (:884) and Studio spawns it
    with cwd=generator_dir (core/build_driver.py), the directory brand.conf.example
    ships in. Measured from a directory holding OPTIONAL_SERVICES="akkoma tor" /
    WANT_TOR=true / WANT_CHARACTER_STUDIO=true, with `--exclude-services zzz` used
    only to force the builder's own `final selection:` line (:1244, an idempotent
    no-op), --role standalone-unaffiliated and NO -C:

        bare                                   -> akkoma tor character-studio
        the PRE-fix wizard argv (no --no-tor)  -> tor
        the POST-fix wizard argv               -> none

    i.e. the pre-fix "neutral" argv emerged net-vpn/tor (the PKGS line at :5134
    carries no ROLE_CLIENT guard, unlike its runlevel neighbour at :4833) into an
    image whose whole point is to bake none of it. Neutral means the ARGV answers the
    question the hidden picker would have asked, and the answer is an explicit none.
    Absent any profile the added tokens are measurably ineffective."""
    page = _shown_net(wiz, _unaff_cfg())
    page.validatePage()
    argv = wiz.cfg.to_cli_args()
    assert wiz.cfg.optional_services == [SERVICES_NONE], (
        "a hidden picker must clear to the EXPLICIT none sentinel — the UNSET state "
        "emits no flag at all, which hands the selection to a brand profile")
    assert ("--optional-services", "") in pairs(argv), (
        f"no explicit empty selection behind the hidden picker: {' '.join(argv)}")
    for flag in ("--no-tor", "--no-character-studio", "--no-character-forge",
                 "--no-edge-ai-tts"):
        assert flag in argv, (
            f"{flag} missing — a brand profile's WANT_<x>=true survives "
            f"--optional-services \"\" and folds the slug straight back in")
    # and nothing was SELECTED: the point of an explicit none is that it is empty.
    assert "--all-services" not in argv
    assert dict(pairs(argv))["--optional-services"] == ""


def test_a_cloud_desktop_still_sees_the_services_box_and_its_note(wiz):
    """RE-POINTED by DECISION 2(a), which widened the hide this test guards.

    The guard's JOB is unchanged and still needed: prove the hide is not universal.
    Its old subject was a STANDALONE branded desktop (mode="standalone",
    role="standalone-thick"), and that is now inside the hide — a standalone client
    image bakes no cluster-services tree, so offering the picker there was one more
    of the "same questions" the operator was asked twice. The CLOUD desktop path was
    deliberately left alone (a branded client can be re-rolled as a node later, and
    its flags really are parsed), so that is where the picker must still appear.

    The standalone-node case is guarded separately in tests/test_pages_identity.py
    (test_the_rpi5_standalone_node_keeps_its_services, G16)."""
    page = _shown_net(wiz, _branded_cfg(mode="cloud", role="laptop"))
    assert page.services_box.isVisible(), (
        "the hide reached the cloud desktop path, which no decision covers")
    assert page.services_role_note.isVisible()


def test_a_standalone_branded_desktop_also_loses_the_services_picker(wiz):
    """The other side of the boundary the test above pins, made explicit: the hide is
    keyed on the standalone CLIENT shape, not on the unaffiliated role, so a BRANDED
    standalone desktop loses the picker too. Recorded as its own test because it is a
    deliberate widening (DECISION 2(a)) and not a side effect of DECISION 1."""
    page = _shown_net(wiz, _branded_cfg())
    assert not page.services_box.isVisible()
    assert not page.services_section.isVisible(), "orphan Services & apps header"
    page.validatePage()
    argv = wiz.cfg.to_cli_args()
    # Same answer as the unaffiliated arm above, and it is measured rather than
    # symmetry: this arm DOES carry a -C, so the profile reaches it by the ordinary
    # route. --role standalone-thick against the same profile, `--exclude-services
    # zzz` only to force the builder's `final selection:` line:
    #     -C brand.conf alone                     -> akkoma tor character-studio
    #     the PRE-fix wizard argv (no --no-tor)   -> tor
    #     the POST-fix wizard argv                -> none
    assert wiz.cfg.optional_services == [SERVICES_NONE]
    assert ("--optional-services", "") in pairs(argv), (
        f"the branded standalone arm still emits nothing: {' '.join(argv)}")
    for flag in ("--no-tor", "--no-character-studio", "--no-character-forge",
                 "--no-edge-ai-tts"):
        assert flag in argv, f"{flag} missing on the branded standalone arm"
