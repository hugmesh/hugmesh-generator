"""Ask 6 — the premade branding themes, end to end and Qt-free.

The defect class this file exists to prevent: **a theme the GUI offers but the builder
rejects, or a theme on disk the GUI never offers.** On ``origin/main`` the first half
was live — the branding page listed the theme directories and then appended the brand
name, so a stock checkout offered ``hugmesh``, a name with no directory, straight into
``build-x86-host-stage4.sh``'s resolver, which hard-errors ``unknown --theme``.

So every test here anchors on ONE equality:

    PREMADE_THEMES  ==  the on-disk theme directories  ==  what the builder accepts

The third term is not an article of faith: the builder resolves
``${SPECS_DIR}/branding/themes/<name>`` and fails when that directory is absent, so its
accepted set IS the directory listing — and
:func:`test_builder_accepted_set_is_the_directory_listing` pins those two builder lines
verbatim so the equivalence cannot rot underneath the assertion.

Pure core + text greps: no Qt import, so this runs in plain CI. The GUI half (what the
cards offer, what ``validatePage`` can emit) is ``test_branding_page_gui.py``.
"""
import importlib.util
import os
import re
import subprocess

import pytest

from hugmesh_studio.core.branding_themes import (
    PREMADE_THEMES, REMOVED_THEMES, REQUIRED_THEME_ASSETS, THEME_ASSETS, THEME_SPECS,
    ThemeSetMismatch, assert_theme_set_agrees, is_valid_theme, on_disk_themes,
    theme_set_problem, themes_dir,
)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
THEMES_DIR = themes_dir(GENERATOR_DIR)
BUILDER = os.path.join(GENERATOR_DIR, "build-x86-host-stage4.sh")
MENU = os.path.join(GENERATOR_DIR, "scripts", "build-menu.sh")
GEN_SCRIPT = os.path.join(GENERATOR_DIR, "scripts", "gen-branding-themes.py")

#: the operator's four, spelled out here as a LITERAL so a typo in the module the
#: rest of the suite imports cannot quietly redefine what "the four" means.
THE_FOUR = ("light", "dark", "purple", "grey")


def _read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


@pytest.fixture(scope="module")
def gen_module():
    """``scripts/gen-branding-themes.py`` loaded by path (the filename has a dash)."""
    spec = importlib.util.spec_from_file_location("gen_branding_themes", GEN_SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _fake_generator_dir(root, themes=THE_FOUR, assets=REQUIRED_THEME_ASSETS):
    """A minimal generator layout with ``themes`` present — the mutation harness."""
    for name in themes:
        d = os.path.join(root, "specs-x86", "branding", "themes", name)
        os.makedirs(d, exist_ok=True)
        for asset in assets:
            open(os.path.join(d, asset), "wb").close()
    return str(root)


# ── 1. THE SET EQUALITY ───────────────────────────────────────────────────────────
def test_declared_set_is_exactly_the_operators_four():
    """Ask 6 named them: light, dark, purple, grey — no more, no fewer, in that order."""
    assert PREMADE_THEMES == THE_FOUR
    assert tuple(sorted(THEME_SPECS)) == tuple(sorted(THE_FOUR))


def test_offered_set_equals_on_disk_set():
    """The assertion itself, against the REAL checkout: what the GUI offers is what
    exists on disk is what the builder will accept."""
    assert set(on_disk_themes(GENERATOR_DIR)) == set(PREMADE_THEMES)
    assert theme_set_problem(GENERATOR_DIR) == ""
    assert_theme_set_agrees(GENERATOR_DIR)          # raises on any disagreement


def test_builder_accepted_set_is_the_directory_listing():
    """Why directory-set equality IS builder equality — pinned to the builder's own
    two lines. If the builder ever gains a hardcoded name list or a different search
    path, this fails and the equality above must be rewritten rather than trusted."""
    src = _read(BUILDER)
    assert '_tdir="${SPECS_DIR}/branding/themes/${BRANDING_THEME}"' in src
    assert ('[ -d "${_tdir}" ] || { err "unknown --theme \'${BRANDING_THEME}\' '
            '(looked in ${_tdir})"; exit 1; }') in src
    # and the optional per-theme logo the Calamares branding component picks up
    assert '${SPECS_DIR}/branding/themes/${BRANDING_THEME}/logo.png' in src


# ── 1b. THE VALIDATOR AND THE BUILD MUST ACCEPT THE SAME SET ─────────────────────
# Found by auditing the inherited work: the set equality held between the GUI, the
# disk and the builder's *branding step* — but NOT between the builder's branding
# step and the builder's own --print-plan VALIDATOR, which is what every channel
# preflights with. --print-plan exited 0 on `--theme totally-not-a-theme`, i.e. the
# resolver green-lit a theme the build hard-errors on ~2100 lines later. Same defect
# class as the GUI half, one layer down.
def _print_plan(*extra):
    """Run the x86 builder's pure resolver. It exits before the root gate, before
    mkdir and before any network fetch or sysroot write (the script says so at the
    --print-plan banner), which is exactly why the build-matrix uses it as a
    validator. Returns (rc, combined output)."""
    proc = subprocess.run(
        [BUILDER, "--role", "standalone-thick", *extra, "--print-plan"],
        cwd=GENERATOR_DIR, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


@pytest.mark.parametrize("name", THE_FOUR)
def test_print_plan_accepts_every_shipped_theme(name):
    """The guard must not be a wall: all four still resolve."""
    rc, out = _print_plan("--theme", name)
    assert rc == 0, out


@pytest.mark.parametrize("bogus", ["totally-not-a-theme", "boogiepop", "hugmesh",
                                   "Light", "neon"])
def test_print_plan_rejects_a_theme_that_has_no_directory(bogus):
    """THE regression. Before the fix each of these returned rc=0 with a full
    PLAN_ARTIFACTS line, and the operator only learned the name was wrong once the
    build reached its branding step."""
    rc, out = _print_plan("--theme", bogus)
    assert rc != 0, out
    assert f"unknown --theme '{bogus}'" in out, out


@pytest.mark.parametrize("evil", ["../..", "../../etc", "a/b", ".", "..", ".hidden"])
def test_print_plan_rejects_a_theme_that_is_a_PATH(evil):
    """`[ -d ]` alone cannot stop a traversal: the name is concatenated into
    ${SPECS_DIR}/branding/themes/<name>, so `../..` names a directory that really
    exists, passes the existence check, and `cp -r`s that whole tree into the image's
    branding dir. Verified before the fix: `[ -d specs-x86/branding/themes/../.. ]`
    is TRUE. Only a bare-name allowlist closes it."""
    rc, out = _print_plan("--theme", evil)
    assert rc != 0, out
    assert "invalid --theme" in out, out


def test_the_existence_check_runs_before_print_plan_exits():
    """Structural companion to the behaviour tests above: the guard has to sit ahead
    of the --print-plan block, or the validator silently stops validating again."""
    src = _read(BUILDER)
    guard = src.index('err "invalid --theme')
    plan = src.index("# ── --print-plan: emit the resolved plan and exit BEFORE ANY mutation")
    staging = src.index('_tdir="${SPECS_DIR}/branding/themes/${BRANDING_THEME}"')
    assert guard < plan < staging, (guard, plan, staging)


def test_studio_refuses_to_emit_a_theme_outside_the_four():
    """The HEADLESS half. The wizard's picker has no free-text path, but a
    hand-written config JSON went straight to --print-command with no check at all —
    so the closed set was a GUI convention, not a contract. ImageConfig now fails
    closed at the same boundary it checks idp / login_font."""
    from hugmesh_studio.core.config import ImageConfig
    from hugmesh_studio.core.validate import IdentityValidationError

    def cfg(theme):
        return ImageConfig(mode="standalone", role="standalone-thick",
                           platform="x86", theme=theme)

    for name in PREMADE_THEMES:                       # the four still emit
        argv = cfg(name).to_cli_args()
        assert argv[argv.index("--theme") + 1] == name
    assert "--theme" not in cfg("").to_cli_args()      # "" = stock look, no flag
    for bogus in ("boogiepop", "hugmesh", "neon", "Light", "light ", "../../.."):
        with pytest.raises(IdentityValidationError, match="unknown theme"):
            cfg(bogus).to_cli_args()


def test_the_theme_guard_does_not_widen_past_the_platforms_that_emit_it():
    """Scope regression. ``theme`` is x86-only emission (PLATFORM_FIELD_SUPPORT):
    ``_rpi5_args`` / ``_jetson_args`` / ``_orangepi*_args`` never write ``--theme``.
    A first cut of the guard above validated unconditionally, so an ARM config still
    carrying ANY stale theme name refused to produce a command at all — with an error
    naming a premade set that platform cannot use. That is every config saved before
    this branch, because ``boogiepop`` was the only theme that ever existed, and the
    headless ``--print-command`` channel has no page to self-heal it the way the
    wizard does. The argv those platforms emit must stay exactly what it was."""
    from hugmesh_studio.core.config import ImageConfig, PLATFORM_FIELD_SUPPORT
    from hugmesh_studio.core.validate import IdentityValidationError

    assert PLATFORM_FIELD_SUPPORT["theme"] == ("x86",)      # the premise of the scope

    def cfg(platform, theme):
        return ImageConfig(platform=platform, theme=theme)

    for plat in ("rpi5", "jetson", "orangepi5", "orangepizero2w", "frite"):
        stale = cfg(plat, "boogiepop").to_cli_args()        # must not raise
        assert "--theme" not in stale
        # and the value is DROPPED, not smuggled in under another flag: identical to
        # the same config with no theme at all.
        assert stale == cfg(plat, "").to_cli_args()
        # a path-shaped name is dropped the same way — there is no --theme to traverse
        assert cfg(plat, "../../etc").to_cli_args() == stale
    # x86 — the one platform that DOES emit it — still fails closed, both ways
    for bogus in ("boogiepop", "../../etc"):
        with pytest.raises(IdentityValidationError, match="unknown theme"):
            cfg("x86", bogus).to_cli_args()
    assert "--theme" in cfg("x86", PREMADE_THEMES[0]).to_cli_args()


def test_every_channel_rejects_the_same_bogus_theme():
    """The three channels agree, which is the whole point of the set equality: the
    GUI cannot offer it, the Studio cannot emit it, the builder cannot resolve it."""
    from hugmesh_studio.core.config import ImageConfig
    from hugmesh_studio.core.validate import IdentityValidationError
    bogus = "boogiepop"
    assert not is_valid_theme(bogus)                                   # the contract
    assert bogus not in on_disk_themes(GENERATOR_DIR)                  # the disk
    with pytest.raises(IdentityValidationError):                       # the Studio
        ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                    theme=bogus).to_cli_args()
    rc, out = _print_plan("--theme", bogus)                            # the builder
    assert rc != 0 and "unknown --theme" in out


# ── 2. MUTATION PROOFS — the assertion must BITE in both directions ───────────────
def test_extra_theme_dir_fails_the_set_equality(tmp_path):
    """A theme the builder would accept but the GUI never offers."""
    root = _fake_generator_dir(tmp_path)
    os.makedirs(os.path.join(root, "specs-x86", "branding", "themes", "neon"))
    problem = theme_set_problem(root)
    assert "on disk but not offered: neon" in problem, problem
    with pytest.raises(ThemeSetMismatch, match="neon"):
        assert_theme_set_agrees(root)


def test_missing_theme_dir_fails_the_set_equality(tmp_path):
    """A theme the GUI offers but the builder would hard-error on."""
    root = _fake_generator_dir(tmp_path, themes=("light", "dark", "purple"))
    problem = theme_set_problem(root)
    assert "missing on disk: grey" in problem, problem
    with pytest.raises(ThemeSetMismatch, match="grey"):
        assert_theme_set_agrees(root)


def test_theme_without_its_assets_fails_the_set_equality(tmp_path):
    """A directory alone is not a theme: the builder copies its CONTENTS, so a theme
    with no wallpaper.png stages nothing and brands nothing."""
    root = _fake_generator_dir(tmp_path)
    os.remove(os.path.join(root, "specs-x86", "branding", "themes",
                           "purple", "wallpaper.png"))
    assert "missing wallpaper.png" in theme_set_problem(root)
    with pytest.raises(ThemeSetMismatch, match="wallpaper.png"):
        assert_theme_set_agrees(root)


# ── 3. THE GENERATOR: deterministic, and what is committed IS what it renders ─────
def test_generator_render_is_deterministic(gen_module):
    """Two renders in one process are byte-identical — no dict ordering, no clock,
    no random, no libm transcendental in the pixel maths."""
    a, b = gen_module.render_all(), gen_module.render_all()
    assert sorted(a) == sorted(b) == sorted(PREMADE_THEMES)
    for name in PREMADE_THEMES:
        for fn in THEME_ASSETS:
            assert a[name][fn] == b[name][fn], f"{name}/{fn} differs between renders"


def test_committed_assets_equal_a_fresh_render(gen_module):
    """THE regeneration gate: every committed byte comes back out of the generator.
    Fails loudly (naming the file) if the committed tree is hand-edited — or if the
    host zlib ever stops producing the same deflate stream, which is the one input
    the script's determinism does not own."""
    for name in PREMADE_THEMES:
        rendered = gen_module.render_theme(name)
        for fn in THEME_ASSETS:
            path = os.path.join(THEMES_DIR, name, fn)
            assert os.path.isfile(path), path
            with open(path, "rb") as fh:
                assert fh.read() == rendered[fn], f"{name}/{fn} drifted from the generator"


def test_generator_check_mode_passes_on_the_committed_tree(gen_module):
    """The operator-facing gate — `scripts/gen-branding-themes.py --check` — is green,
    and its rc is what a CI job would read."""
    assert gen_module.main(["--check", "--generator-dir", GENERATOR_DIR]) == 0


def test_generator_check_mode_catches_a_hand_edit(gen_module, tmp_path):
    """--check must FAIL on drift, or it is decoration. One flipped byte is enough."""
    root = str(tmp_path)
    assert gen_module.main(["--generator-dir", root]) == 0     # write a fresh tree
    victim = os.path.join(root, "specs-x86", "branding", "themes", "dark", "brand.conf")
    with open(victim, "ab") as fh:
        fh.write(b"# hand-edited\n")
    assert gen_module.main(["--check", "--generator-dir", root]) == 1


def test_generator_check_mode_catches_an_undeclared_theme(gen_module, tmp_path):
    """A fifth directory dropped into the tree is drift too — the generator reports it
    as STALE rather than leaving the GUI and the builder to disagree about it."""
    root = str(tmp_path)
    assert gen_module.main(["--generator-dir", root]) == 0
    os.makedirs(os.path.join(root, "specs-x86", "branding", "themes", "neon"))
    assert gen_module.main(["--check", "--generator-dir", root]) == 1


def test_generator_uses_no_network_and_no_platform_varying_maths():
    """The rules the assets were required to be built under, pinned against the
    source: no socket/urllib/requests/subprocess-fetch, and none of the libm calls
    (sin/cos/pow) whose results are not bit-identical across platforms."""
    src = _read(GEN_SCRIPT)
    body = "\n".join(ln for ln in src.splitlines() if not ln.lstrip().startswith("#"))
    for banned in ("import socket", "import urllib", "import requests", "http://",
                   "https://", "urlopen", "base64.b64decode"):
        assert banned not in body, f"generator must not reference {banned!r}"
    for banned in ("math.sin", "math.cos", "math.pow", "math.atan", "random."):
        assert banned not in body, f"generator must not call {banned!r} (host-varying)"
    assert "math.sqrt" in body                     # the one libm call, IEEE-exact


# ── 4. THE ASSETS THEMSELVES ─────────────────────────────────────────────────────
@pytest.mark.parametrize("name", THE_FOUR)
def test_every_theme_ships_every_asset(name):
    for fn in THEME_ASSETS:
        path = os.path.join(THEMES_DIR, name, fn)
        assert os.path.isfile(path), path
        assert os.path.getsize(path) > 0, path


@pytest.mark.parametrize("name", THE_FOUR)
def test_wallpaper_and_logo_are_real_pngs_of_the_right_size(name):
    """PNG magic + IHDR width/height, read straight out of the header — the builder
    hands these to hugmesh-branding and Calamares, which hard-fail on a bad image."""
    import struct
    for fn, want in (("wallpaper.png", (1920, 1080)), ("logo.png", (256, 256))):
        with open(os.path.join(THEMES_DIR, name, fn), "rb") as fh:
            head = fh.read(24)
        assert head[:8] == b"\x89PNG\r\n\x1a\n", f"{name}/{fn} is not a PNG"
        assert head[12:16] == b"IHDR"
        assert struct.unpack(">II", head[16:24]) == want, f"{name}/{fn} wrong size"


@pytest.mark.parametrize("name", THE_FOUR)
def test_brand_conf_carries_the_specs_accent_and_scheme(name):
    """The theme's brand.conf must set exactly the two THEMING keys — and must NOT set
    BRAND_NAME/BRAND_TITLE, which are identity: the builder appends those after
    copying the preset, so a theme that wrote them would be silently overridden."""
    spec = THEME_SPECS[name]
    text = _read(os.path.join(THEMES_DIR, name, "brand.conf"))
    assert f"ACCENT_COLOR={spec.accent}\n" in text
    assert f"COLOR_SCHEME_NAME={spec.color_scheme_name}\n" in text
    assert "BRAND_NAME=" not in text and "BRAND_TITLE=" not in text
    # the applier's strict loader takes #rrggbb; anything else is silently dropped
    assert re.fullmatch(r"#[0-9a-f]{6}", spec.accent), spec.accent


@pytest.mark.parametrize("name", THE_FOUR)
def test_colors_file_names_the_same_scheme(name):
    spec = THEME_SPECS[name]
    text = _read(os.path.join(THEMES_DIR, name, "colors.colors"))
    assert f"ColorScheme={spec.color_scheme_name}" in text
    assert f"Name={spec.color_scheme_name}" in text


def test_every_theme_asset_is_actually_TRACKED_by_git():
    """On disk is not the same as SHIPPED. This caught a real one: ``.gitignore``
    carries a bare ``brand.conf`` rule (a brand PROFILE may hold default passwords),
    which silently swallowed all four themes' generated ``brand.conf`` — every
    working tree looked perfect while a fresh clone would have had four themes with
    no accent and no colour scheme, and would have tripped the missing-asset half of
    the set-equality assertion on first run. A file-exists check cannot see that;
    only asking git can.

    TWO LAYERS, deliberately. ``git ls-files`` reads the INDEX, which is where the
    damage shows AFTER someone re-adds the files by hand or runs `git rm --cached`.
    It does not see the .gitignore rule itself: with the assets already staged,
    deleting the ``!…/themes/*/brand.conf`` negation leaves this half green while the
    next generated theme — and any contributor who regenerates from a clean tree — is
    silently swallowed again. So ``git check-ignore`` is asked too: no theme asset may
    be ignored, whatever the index currently holds."""
    want = {f"specs-x86/branding/themes/{name}/{fn}"
            for name in PREMADE_THEMES for fn in THEME_ASSETS}
    try:
        out = subprocess.run(["git", "ls-files", "-z", "--", "specs-x86/branding/themes"],
                             cwd=GENERATOR_DIR, capture_output=True, text=True)
    except OSError:                                    # pragma: no cover
        pytest.skip("git unavailable")
    if out.returncode != 0:                            # pragma: no cover
        pytest.skip(f"git ls-files unusable here: {out.stderr.strip()}")
    tracked = {p for p in out.stdout.split("\0") if p}
    assert want <= tracked, sorted(want - tracked)
    assert tracked == want, sorted(tracked - want)     # and nothing else ships either
    # layer 2: the RULE, not the index. --no-index so an already-staged path cannot
    # mask an ignore rule that would swallow the next regenerated copy.
    ign = subprocess.run(["git", "check-ignore", "--no-index", "--"] + sorted(want),
                         cwd=GENERATOR_DIR, capture_output=True, text=True)
    if ign.returncode not in (0, 1):                   # pragma: no cover
        pytest.skip(f"git check-ignore unusable here: {ign.stderr.strip()}")
    ignored = sorted(p for p in ign.stdout.splitlines() if p)
    assert ignored == [], ignored


def test_themes_dir_contains_nothing_but_the_four():
    """No stray directory, and no loose file either — the builder does `cp -r
    <theme>/.` into the staging dir, so anything that lands in a theme ships."""
    entries = sorted(os.listdir(THEMES_DIR))
    assert entries == sorted(THE_FOUR), entries
    for name in THE_FOUR:
        assert sorted(os.listdir(os.path.join(THEMES_DIR, name))) == sorted(THEME_ASSETS)


# ── 5. NO REMOVED THEME NAME SURVIVES ────────────────────────────────────────────
#: The only files allowed to CONTAIN a removed theme name, each because naming it is
#: the point. Anything else mentioning it is a live reference that would break.
_REMOVED_NAME_ALLOWLIST = {
    "SURVEY.md",                                       # the survey OF origin/main
    "scripts/gen-branding-themes.py",                  # "what this replaced"
    "studio/hugmesh_studio/core/branding_themes.py",   # REMOVED_THEMES itself
    "studio/tests/test_branding_themes.py",            # this file
    "studio/tests/test_branding_page_gui.py",          # the "stale saved theme" case
}


@pytest.mark.parametrize("removed", REMOVED_THEMES)
def test_removed_theme_is_gone_from_disk(removed):
    assert not os.path.exists(os.path.join(THEMES_DIR, removed))


@pytest.mark.parametrize("removed", REMOVED_THEMES)
def test_removed_theme_name_survives_nowhere_live(removed):
    """Repo-wide: the ONLY files still spelling a removed theme are the ones whose
    job is to record that it was removed. A reintroduced default in build-menu.sh, a
    test literal, a doc example — each would land outside the allowlist and fail.

    CASE-INSENSITIVE (``-i``) deliberately. The first cut of this guard grepped
    case-sensitively and was green while five ``/tmp/Boogiepop.colors`` literals sat
    in ``test_pages_home.py`` — a removed name survives a rename just as well in
    title case, and ``BOOGIEPOP`` in a shell variable would have slipped through too.
    A guard that only catches the lower-case spelling is not a guard against the name.
    """
    try:
        out = subprocess.run(["git", "grep", "-lIi", "--", removed],
                             cwd=GENERATOR_DIR, capture_output=True, text=True)
    except OSError:                                    # pragma: no cover
        pytest.skip("git unavailable")
    if out.returncode not in (0, 1):                   # 1 == no matches
        pytest.skip(f"git grep unusable here: {out.stderr.strip()}")
    hits = {ln for ln in out.stdout.splitlines() if ln}
    assert hits <= _REMOVED_NAME_ALLOWLIST, sorted(hits - _REMOVED_NAME_ALLOWLIST)


# ── 6. EVERY OTHER CONSUMER OF THE THEME NAME AGREES ─────────────────────────────
def test_ncurses_menu_default_is_a_theme_that_exists():
    """scripts/build-menu.sh persists OPT_SA_THEME and emits `--theme $OPT_SA_THEME`
    for branded standalone builds. Left pointing at a deleted theme it would send
    every menu build straight into the builder's hard error."""
    m = re.search(r'^OPT_SA_THEME="([^"]*)"', _read(MENU), re.M)
    assert m, "OPT_SA_THEME default not found in scripts/build-menu.sh"
    assert m.group(1) in PREMADE_THEMES, m.group(1)


def test_ncurses_menu_picker_enumerates_the_directories():
    """The menu's picker must stay a LIVE directory enumeration, not a typed list —
    that is what keeps it inside the set equality for free."""
    assert 'specs-x86/branding/themes/*/' in _read(MENU)


def test_docs_name_exactly_the_four():
    doc = _read(os.path.join(GENERATOR_DIR, "docs", "STANDALONE-DESKTOP.md"))
    assert "### Premade themes" in doc
    for name in PREMADE_THEMES:
        assert f"`{name}`" in doc, name
    assert "scripts/gen-branding-themes.py" in doc


def test_is_valid_theme_accepts_only_the_four_and_empty():
    assert is_valid_theme("")                          # "" = stock look, not a theme
    for name in PREMADE_THEMES:
        assert is_valid_theme(name)
    for bogus in ("hugmesh", "boogiepop", "Light", "light ", "../etc"):
        assert not is_valid_theme(bogus), bogus


def test_required_assets_are_a_subset_of_shipped_assets():
    assert set(REQUIRED_THEME_ASSETS) <= set(THEME_ASSETS)
