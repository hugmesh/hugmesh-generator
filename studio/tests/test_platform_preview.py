"""The platform preview page (core/platform_preview.py).

What makes it honest, pinned here:
  * the theme substitution uses the SAME marker mechanism as the shipped login asset
    and REACHES ALL FOUR PANES — one :root:root rule covers the three representative
    panes (they are painted exclusively in var(--sd-*)), and the embedded login
    snapshot carries its OWN substituted copy inside the iframe srcdoc (an iframe is
    a separate document; the outer rule cannot cascade into it);
  * the login pane is the REAL captured page riding along byte-escaped, not a mock;
  * the three mock panes SAY they are mocks, in-pane;
  * the sample content is deterministic neutral demo text (theme diffs stay theme
    diffs) with no real names/domains;
  * the page is inert (no scripts) and self-contained (one file:// artifact — the
    open path is the fragile part, so there is exactly one thing to open);
  * the asset-intact guard mirrors the login one: a snapshot that lost its marker
    raises instead of silently previewing an unthemed page.
"""
import pytest

from hugmesh_studio.core import login_preview, platform_preview, theme

THEMED_CSS = theme.compose_login_css("#e91e63", "#00bcd4", font_preset="Monospace")


@pytest.fixture(scope="module")
def themed_page() -> str:
    return platform_preview.platform_preview_html(THEMED_CSS)


def test_all_four_panes_are_present(themed_page):
    for pane in ("pane-login", "pane-matrix", "pane-akkoma", "pane-forum"):
        assert f'id="{pane}"' in themed_page, f"{pane} missing"


def test_marker_substitution_reaches_all_panes(themed_page):
    # Top level: exactly one substituted style#snap-theme, no marker residue. The
    # three mock panes inherit it because their stylesheet is var(--sd-*)-only.
    assert platform_preview.MARKER not in themed_page
    assert themed_page.count('<style id="snap-theme">') == 1
    assert f'<style id="snap-theme">{THEMED_CSS}</style>' in themed_page
    # The login pane is a SEPARATE document (iframe srcdoc), so the outer rule
    # cannot reach it — it must carry its own substituted copy. The srcdoc escape
    # leaves the token text itself untouched, so the substituted primary appears
    # exactly twice: once outer, once inside the escaped snapshot.
    assert themed_page.count("--sd-primary: #e91e63;") == 2
    assert themed_page.count("id=&quot;snap-theme&quot;") == 1
    # And the pane styles actually consume the tokens (a hardcoded-hex pane would
    # pass the counts above while ignoring the theme).
    for token in ("var(--sd-primary)", "var(--sd-secondary)", "var(--sd-accent-soft)",
                  "var(--sd-text-muted)", "var(--sd-bg-1)"):
        assert token in themed_page, f"pane styles no longer consume {token}"


def test_unthemed_page_keeps_the_shipped_default_fallback():
    page = platform_preview.platform_preview_html("")
    assert '<style id="snap-theme"></style>' in page
    # the plain :root fallback carries the LITERAL shipped triple (theme.py golden)
    assert "--sd-primary: #ffd700;" in page
    assert "--sd-accent-soft: #b388ff;" in page
    # fallback stays a plain :root RULE (the banner prose may mention :root:root,
    # but no doubled-selector rule exists until a theme is substituted)
    assert ":root:root {" not in page
    assert '<style id="compiled-default-tokens">:root {' in page


def test_login_pane_is_the_real_captured_page(themed_page):
    # the real form controls ride along escaped inside the srcdoc attribute
    assert "data-testid=&quot;login-submit&quot;" in themed_page
    assert "id=&quot;snap-login-username&quot;" in themed_page
    assert platform_preview.LOGIN_PANE_LABEL.split(" — ")[0] in themed_page


def test_mock_panes_admit_they_are_mocks(themed_page):
    # one honesty line per representative pane — matrix, akkoma, forum
    assert themed_page.count(platform_preview.HONESTY_LABEL) == 3


def test_page_is_inert_and_self_contained(themed_page):
    assert "<script" not in themed_page          # frozen visual preview: no JS
    assert 'href="http' not in themed_page       # no external fetches
    assert 'src="http' not in themed_page
    assert themed_page.count("<iframe") == 1     # srcdoc only — no linked files


def test_sample_content_is_deterministic_and_neutral():
    a, b = platform_preview.sample_content(), platform_preview.sample_content()
    assert a == b and a is not b
    page1 = platform_preview.platform_preview_html(THEMED_CSS)
    page2 = platform_preview.platform_preview_html(THEMED_CSS)
    assert page1 == page2
    # neutral personas on a non-delegated demo host — no real names/domains
    for persona in ("amara", "kenji", "sol"):
        assert persona in page1
    assert "@amara@demo.mesh" in page1


def test_matrix_pane_has_messages_timestamps_and_a_join_line(themed_page):
    assert "#welcome:demo.mesh" in themed_page
    assert "sol joined the room" in themed_page
    assert "12:04" in themed_page and "12:11" in themed_page


def test_akkoma_pane_has_initial_avatars_and_boost_like_counts(themed_page):
    assert 'class="av av-primary"' in themed_page      # avatars-as-initials
    assert ">A</span>" in themed_page and ">K</span>" in themed_page
    assert 'title="boosts">↻ 3' in themed_page
    assert 'title="likes">★ 7' in themed_page


def test_forum_pane_has_quote_block_and_pagination_stub(themed_page):
    assert "Tips for first-time mesh operators" in themed_page
    assert "<blockquote>" in themed_page
    assert "amara wrote:" in themed_page
    assert "pagination stub" in themed_page
    assert '<span class="cur">1</span>' in themed_page


def test_write_platform_preview_returns_a_real_file(tmp_path):
    path = platform_preview.write_platform_preview(THEMED_CSS, str(tmp_path))
    assert path.endswith(platform_preview.PLATFORM_PREVIEW_BASENAME)
    text = open(path, encoding="utf-8").read()
    assert "--sd-primary: #e91e63;" in text
    assert 'id="pane-forum"' in text


def test_preview_artifact_is_rewritten_with_the_new_font_family(tmp_path):
    """Issue #225: a font change must land in the preview FILE on the next press.
    Same basename, same dir — the artifact is overwritten, the old stack is gone,
    and the new stack reaches BOTH documents (top-level page + login iframe)."""
    first = theme.compose_login_css("", "", font_preset="Geometric")
    p1 = platform_preview.write_platform_preview(first, str(tmp_path))
    assert "--sd-font-sans: Avenir" in open(p1, encoding="utf-8").read()

    second = theme.compose_login_css("", "", font_preset="Slab serif")
    p2 = platform_preview.write_platform_preview(second, str(tmp_path))
    assert p2 == p1                                  # rewritten, not a second file
    text = open(p2, encoding="utf-8").read()
    assert text.count("--sd-font-sans: Rockwell") == 2   # outer page + iframe srcdoc
    assert "Avenir" not in text                      # the old font family is GONE


def test_chosen_font_reaches_the_login_forms_controls(themed_page):
    """Form controls don't inherit font-family (the UA default wins), so the theme
    css must carry the inherit rule or the login pane's inputs and Sign-in button
    silently ignore the chosen font — the observed half of issue #225."""
    assert theme.FORM_FONT_RESET.strip() in THEMED_CSS
    # present in both documents: the outer style#snap-theme and the escaped iframe copy
    assert themed_page.count(theme.FORM_FONT_RESET.strip()) == 2


def test_the_header_explainer_paragraph_is_gone():
    """Issue #225: the preview page's meta-explainer prose ("One theme, four
    surfaces … :root:root token text …") was operator-flagged placeholder copy.
    The header keeps only the title; the in-pane honesty labels do the explaining."""
    page = platform_preview.platform_preview_html("")
    assert "One theme, four surfaces" not in page
    assert "<h1>HugMesh platform preview</h1>" in page


def test_asset_intact_guard_mirrors_the_login_one(tmp_path, monkeypatch):
    # a snapshot that lost its marker must raise (login_preview's guard), not fall
    # through to a silently unthemed login pane inside an otherwise-themed page.
    broken = tmp_path / "broken.html"
    broken.write_text("<html><head></head><body>no marker here</body></html>",
                      encoding="utf-8")
    monkeypatch.setattr(login_preview, "_ASSET", str(broken))
    with pytest.raises(RuntimeError, match="substitution marker"):
        platform_preview.platform_preview_html(THEMED_CSS)
