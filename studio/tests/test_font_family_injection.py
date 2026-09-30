"""The uploaded font's family name is ATTACKER-CONTROLLED TEXT — regression pins.

The operator never types this string. It is read out of the font FILE's own ``name``
table (``QFontDatabase.applicationFontFamilies``), so whoever authored the .ttf/.woff2
chose it, and it is then interpolated into css that lands in a ``<style id="snap-theme">``
element of the generated platform preview. ``<style>`` is an HTML RAW-TEXT element:
entities do not decode inside it and only the literal ``</`` + name-start sequence ends
it, so a family of ``Evil</style><script>…</script><style>`` closed the element and the
rest of the page parsed as markup. Reproduced end to end in chromium from a real .ttf
(fontTools, nameIDs 1/4/6/16): ``window.PWNED = 1``, ``document.title = "pwned"``.

The old sanitiser was a two-character blacklist (``\\`` and ``"``) — ``<`` ``>`` ``/``
``;`` ``{`` ``}`` and newlines all walked through it. The same unsanitised text also
ships to production as HUG_THEME_CSS / the login-theme ConfigMap, where ``</style>`` is
ineffective but attacker-authored css still lands in the stylesheet served on the real login
page. So the fix is an ALLOWLIST at the composer (fonts.safe_font_family), a raw-text
backstop at the sink (platform_preview.raw_text_safe), and a CSP on the artifact.

Three independent layers, pinned independently below so a regression in ONE of them
fails a test instead of being masked by the other two.
"""
import re

import pytest

from hugmesh_studio.core import fonts, login_preview, platform_preview, theme

_TTF = b"\x00\x01\x00\x00" + b"\x00" * 60

# The exact shape reproduced in chromium.
PAYLOAD = 'Evil</style><script>window.PWNED=1;document.title="pwned"</script><style>'

# Characters that end a css string, a css declaration/block, a css comment, or the
# HTML raw-text element the css is interpolated into.
BREAKOUT = ('<', '>', '/', '\\', '"', ';', '{', '}', '*', '@', ':', ',', '\n', '\r',
            '\t', '\x00', ' ', ' ')


# ── layer 1: the allowlist itself ────────────────────────────────────────────────

def test_safe_font_family_drops_every_breakout_character():
    got = fonts.safe_font_family("A" + "".join(BREAKOUT) + "B")
    for ch in BREAKOUT:
        assert ch not in got, f"{ch!r} survived the allowlist: {got!r}"
    assert got == "AB"


def test_safe_font_family_neutralises_the_reproduced_payload():
    got = fonts.safe_font_family(PAYLOAD)
    assert "</style>" not in got and "<script" not in got
    assert "<" not in got and ">" not in got and "/" not in got


def test_safe_font_family_keeps_real_family_names_intact():
    """An allowlist that mangles legitimate faces would be traded one bug for another:
    real name tables carry spaces, dots, dashes, underscores, ``+``, ``&``, brackets
    and NON-ASCII letters (CJK/Cyrillic families are not exotic)."""
    for real in ("Liberation Mono", "PT_Sans-Web", "M+ 1p", "Trebuchet MS",
                 "Bitstream Vera Sans (Roman)", "Gill Sans & Co", "Noto Sans JP",
                 "游ゴシック Medium", "Иван Sans", "Source Code Pro 2.0"):
        assert fonts.safe_font_family(real) == real, real


def test_safe_font_family_falls_back_rather_than_emitting_an_empty_family():
    # A name table of nothing but payload leaves no usable text; `font-family: ""`
    # resolves to nothing in every browser, so a named fallback is the honest result.
    assert fonts.safe_font_family("") == fonts.FALLBACK_FAMILY
    assert fonts.safe_font_family("   \n\t ") == fonts.FALLBACK_FAMILY
    assert fonts.safe_font_family("</>;{}*\\\"") == fonts.FALLBACK_FAMILY


def test_the_fallback_family_is_itself_safe_to_emit():
    """FALLBACK_FAMILY is what EVERY all-payload name reduces to, so it is the string
    emitted into ``font-family: "..."`` on precisely the attacker-controlled path — and
    nothing else re-checks it. Pin the constant against the allowlist it backstops: a
    mutant that put ``</style><script>`` in FALLBACK_FAMILY otherwise survived this
    whole suite (found by the refuting mutation battery, MX1)."""
    assert fonts.safe_font_family(fonts.FALLBACK_FAMILY) == fonts.FALLBACK_FAMILY
    head = fonts.font_face_css("</>;{}*", _TTF).split("src:", 1)[0]   # all payload
    assert fonts.FALLBACK_FAMILY in head
    assert "<" not in head and ">" not in head
    assert head.count('"') == 2


def test_safe_font_family_collapses_the_gaps_a_stripped_payload_leaves():
    assert fonts.safe_font_family("Evil</style>   <b>Face") == "Evilstyle bFace"


# ── layer 1 at both emission points ──────────────────────────────────────────────

def test_font_face_css_cannot_carry_the_payload():
    css = fonts.font_face_css(PAYLOAD, _TTF)
    head = css.split("src:", 1)[0]          # the base64 blob is not the interesting half
    assert "</style>" not in head and "<script" not in head
    assert "<" not in head and ">" not in head
    assert head.count('"') == 2             # exactly the family's own quotes


def test_font_tokens_cannot_carry_the_payload():
    t = fonts.font_tokens(fonts.FONT_PRESETS["System UI"], uploaded_family=PAYLOAD)
    for name, value in t.items():
        assert "</style>" not in value and "<script" not in value, name
        assert "<" not in value and ">" not in value, name


# ── layer 1 through the one real composition point ───────────────────────────────

def test_composed_theme_css_cannot_carry_the_payload():
    """theme.compose_login_css is the ONE composer shared by the Studio GUI, the
    bootstrap CLI and scripts/tooling/derive-theme.py — so pinning it here covers the
    preview artifact AND the production HUG_THEME_CSS / login-theme ConfigMap."""
    css = theme.compose_login_css("#e91e63", "#00bcd4",
                                  font_family=PAYLOAD, font_bytes=_TTF)
    assert "</style>" not in css and "<script" not in css
    assert "<" not in css and ">" not in css


# ── the end-to-end sink: the generated preview page ──────────────────────────────

def _snap_theme_block(page: str) -> str:
    """What the BROWSER treats as the style#snap-theme element's content: everything
    up to the first raw-text terminator, which is the whole point of the bug."""
    start = page.index('<style id="snap-theme">') + len('<style id="snap-theme">')
    end = re.compile(r"</(?=[A-Za-z!/?])").search(page, start)
    return page[start:end.start()]


def test_preview_page_does_not_execute_a_malicious_family(tmp_path):
    css = theme.compose_login_css("#e91e63", "#00bcd4",
                                  font_family=PAYLOAD, font_bytes=_TTF)
    path = platform_preview.write_platform_preview(css, str(tmp_path))
    page = open(path, encoding="utf-8").read()
    # Not a single tag survives — the leftovers of the payload are harmless word
    # characters inside a quoted css family name, which is the whole point.
    assert "<script" not in page and "</script" not in page
    assert "</style>" not in css
    assert "<" not in css and ">" not in css
    # And the style element the theme lands in is closed by ITS OWN end tag: what the
    # browser reads as style#snap-theme is exactly the composed css, not a prefix of
    # it followed by markup.
    assert _snap_theme_block(page) == css
    # both documents (top-level page + escaped iframe srcdoc) carry the same clean css
    assert page.count(fonts.safe_font_family(PAYLOAD)) >= 5


# ── layer 2: the raw-text backstop at the sink ───────────────────────────────────

def test_raw_text_safe_breaks_a_terminator_without_touching_real_css():
    themed = theme.compose_login_css("#e91e63", "#00bcd4", font_preset="Monospace")
    assert platform_preview.raw_text_safe(themed) == themed      # no-op on real css
    broken = platform_preview.raw_text_safe("a{}</style><script>x</script>")
    assert "</style>" not in broken and "</script>" not in broken
    assert broken == r"a{}<\/style><script>x<\/script>"


def test_raw_text_break_is_case_insensitive_like_the_html_parser():
    """HTML end-tag matching is ASCII case-insensitive: ``</STYLE>`` and ``</StYlE>``
    close a ``<style>`` element exactly as ``</style>`` does. A guard that only knew
    the lowercase spelling would be bypassed by shouting."""
    for spelling in ("</style>", "</STYLE>", "</StYlE>", "</style\n>", "</style/"):
        out = platform_preview.raw_text_safe("a{}" + spelling)
        assert "</" not in out, spelling
    # ...and it does not maul a `/` that closes nothing. Per the HTML tokenizer's
    # RAWTEXT end-tag-open state, `</` is only an end tag when a NAME START follows;
    # `</` before a quote or a digit is emitted as plain characters, so leaving those
    # alone keeps the guard a no-op on css that merely looks alarming.
    assert platform_preview.raw_text_safe("a{width:calc(1/2)}") == "a{width:calc(1/2)}"
    assert platform_preview.raw_text_safe("a{content:'</'}") == "a{content:'</'}"


def test_sink_survives_a_theme_css_that_already_contains_a_terminator():
    """Defence in depth: even if a FUTURE composer path gets ``</style>`` into the css,
    the top-level style element must not be closed early. The iframe copy was already
    html.escape'd; this was the one raw substitution."""
    evil = ':root:root { --sd-primary: #fff; }</style><script>window.PWNED=1</script>'
    page = platform_preview.platform_preview_html(evil)
    assert page.count('<style id="snap-theme">') == 1
    # The terminator is broken, so the browser never leaves the style element: the
    # attacker's `<script>` is css TEXT, and the element closes at the shell's own
    # end tag with the whole payload inside it.
    block = _snap_theme_block(page)
    assert block.endswith(r"<\/script>")
    assert "window.PWNED" in block           # inside the stylesheet, not the DOM
    assert page.index("<script>") < page.index('<style id="platform-preview-styles">')


def test_login_only_preview_sink_is_guarded_too():
    """login_preview.write_preview is the OTHER substitution into a raw ``<style>`` —
    the login-only artifact, a public entry point of core/. It substitutes into the
    captured snapshot's own ``style#snap-theme`` with no html.escape and no iframe in
    front of it, so it needs the same backstop as the platform page, or the second sink
    quietly keeps the bug the first one lost."""
    evil = ':root:root { --sd-primary: #fff; }</style><script>window.PWNED=1</script>'
    doc = login_preview.preview_html(evil)
    assert "</style><script>" not in doc        # the terminator never reaches the page
    assert "<" + chr(92) + "/style><script>" in doc     # broken, so the element holds
    assert "window.PWNED" in doc                # present, but as css text
    assert _snap_theme_block(doc) == login_preview.raw_text_safe(evil)


def test_login_only_preview_is_byte_identical_for_real_themes():
    """The backstop must change nothing on every css this repo actually composes — the
    login-only artifact stays byte-for-byte what it was before the hardening."""
    real = theme.compose_login_css("#7c4dff", "#00e5ff", font_preset="Humanist")
    assert login_preview.raw_text_safe(real) == real
    assert _snap_theme_block(login_preview.preview_html(real)) == real


# ── layer 3: the artifact's own CSP ──────────────────────────────────────────────

def test_preview_artifact_carries_a_no_script_csp():
    """The generated page is a frozen, self-contained file:// artifact — no scripts, no
    network, no forms. Saying so in a meta CSP means the NEXT sink bug is a broken
    stylesheet rather than script execution in the operator's browser."""
    page = platform_preview.platform_preview_html("")
    meta = ('<meta http-equiv="Content-Security-Policy" '
            f'content="{platform_preview.PREVIEW_CSP}">')
    assert meta in page
    assert "default-src 'none'" in platform_preview.PREVIEW_CSP
    assert "'unsafe-eval'" not in platform_preview.PREVIEW_CSP
    # no script-src at all: default-src 'none' already covers scripts
    assert "script-src" not in platform_preview.PREVIEW_CSP
    # the page still needs its own inline styles and the embedded @font-face
    assert "style-src 'unsafe-inline'" in platform_preview.PREVIEW_CSP
    assert "font-src data:" in platform_preview.PREVIEW_CSP


@pytest.mark.parametrize("preset", sorted(fonts.FONT_PRESETS))
def test_every_preset_still_composes_a_clean_page(preset):
    """The hardening must change nothing for every path an operator actually uses."""
    css = theme.compose_login_css("#7c4dff", "", font_preset=preset)
    page = platform_preview.platform_preview_html(css)
    assert f'<style id="snap-theme">{css}</style>' in page
