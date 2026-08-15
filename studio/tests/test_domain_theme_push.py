"""The Studio's per-domain theme writer.

Two things here are load-bearing beyond ordinary HTTP plumbing:

* **The Studio ships the RENDERED CSS, not just the choice.** The colour derivation has
  one implementation and it is the Studio's; the BFF stores the result as a cache and
  never re-derives, because a second implementation would drift until the admin UI showed
  one theme and the page rendered another. If the payload ever stops carrying the
  stylesheet, per-domain theming silently degrades to default chrome everywhere.

* **The ``_default`` segment.** The mesh default's storage key is the empty string, which
  cannot be a URL path segment, so both sides agree on a literal that no real domain can
  take. If the two spellings ever diverge, a superadmin setting "the default" would
  create a row for a domain literally named ``_default`` that nothing inherits.

The push tests drive the REAL request-building code through an injected opener, so the
URL, method, headers and body are all actually asserted — stubbing ``push`` itself would
verify none of the things that break.
"""
import json

import pytest

from hugmesh_studio.core import domain_theme as dt
from hugmesh_studio.core import theme, theme_presets


class _Resp:
    def __init__(self, body: bytes):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class _Recorder:
    """Captures the request instead of sending it."""

    def __init__(self, body: bytes = b'{"domain":"brandx"}'):
        self.body = body
        self.req = None
        self.timeout = None

    def __call__(self, req, timeout=None):
        self.req = req
        self.timeout = timeout
        return _Resp(self.body)


def sel(**kw):
    return dt.ThemeSelection(**{"preset": "nord", "ramp": "dusk", "style": "sharp", **kw})


class TestTheRenderedStylesheet:

    def test_the_payload_carries_the_derived_css(self):
        body = dt.build_payload(sel())
        assert "renderedCss" in body
        assert ":root:root" in body["renderedCss"]
        assert "--sd-" in body["renderedCss"]

    def test_the_css_is_literal_tokens_with_nothing_left_to_derive(self):
        # css_root raises on a var() value, so this also pins that the BFF never has to
        # resolve anything -- it serves bytes.
        css = dt.render_css(sel())
        assert "var(" not in css

    def test_every_axis_actually_changes_the_output(self):
        base = dt.render_css(sel())
        assert dt.render_css(sel(preset="pride")) != base
        assert dt.render_css(sel(ramp="light")) != base
        assert dt.render_css(sel(style="flat")) != base

    def test_the_style_axis_contributes_shape_tokens(self):
        sharp = dt.render_css(sel(style="sharp"))
        soft = dt.render_css(sel(style="soft"))
        assert "--sd-radius" in sharp and "--sd-radius" in soft
        assert sharp != soft

    def test_selection_only_payloads_omit_the_css(self):
        body = dt.build_payload(sel(), include_css=False)
        assert "renderedCss" not in body
        assert body["preset"] == "nord"


class TestTheMeshDefaultSegment:

    @pytest.mark.parametrize("domain", ["", "   ", None])
    def test_an_absent_domain_targets_the_reserved_default_segment(self, domain):
        assert dt.theme_url("http://mesh:9000", domain).endswith("/bff/admin/themes/_default")

    def test_a_real_domain_targets_itself(self):
        assert dt.theme_url("http://mesh:9000", "brandx").endswith("/bff/admin/themes/brandx")

    def test_the_segment_matches_the_bff_constant(self):
        # Both sides must spell it identically; this is the Python half of that pact.
        assert dt.DEFAULT_SEGMENT == "_default"

    def test_a_trailing_slash_on_the_base_url_does_not_double_up(self):
        assert "//bff" not in dt.theme_url("http://mesh:9000/", "brandx")

    def test_a_domain_needing_escaping_is_quoted(self):
        assert "%2F" in dt.theme_url("http://mesh:9000", "a/b")


class TestValidationHappensBeforeTheNetwork:

    @pytest.mark.parametrize("bad", [
        {"preset": ""},
        {"preset": "no-such-preset-anywhere"},
        {"ramp": "twilight"},
        {"style": "neon"},
        {"primary_hex": "fuchsia"},
        {"secondary_hex": "#12345"},
    ])
    def test_a_bad_selection_raises_locally(self, bad):
        rec = _Recorder()
        with pytest.raises(ValueError):
            dt.push("http://mesh:9000", "brandx", sel(**bad), "tok", opener=rec)
        assert rec.req is None, "an invalid selection must never reach the mesh"

    def test_the_vocabularies_come_from_the_renderer_itself(self):
        # Not a restated copy: if a ramp or style is added to the theme modules, this
        # validator accepts it with no edit here.
        for ramp in theme_presets.MODES:
            sel(ramp=ramp).validate()
        for style in theme.STYLE_VARIANTS:
            sel(style=style).validate()


class TestThePushRequest:

    def test_it_is_a_put_with_a_bearer_token_and_json(self):
        rec = _Recorder()
        dt.push("http://mesh:9000", "brandx", sel(), "tok-123", opener=rec)
        assert rec.req.get_method() == "PUT"
        assert rec.req.full_url == "http://mesh:9000/bff/admin/themes/brandx"
        assert rec.req.headers["Authorization"] == "Bearer tok-123"
        assert rec.req.headers["Content-type"] == "application/json"
        sent = json.loads(rec.req.data)
        assert sent["preset"] == "nord"
        assert ":root:root" in sent["renderedCss"]

    def test_it_returns_the_stored_row(self):
        rec = _Recorder(b'{"domain":"brandx","preset":"nord"}')
        assert dt.push("http://mesh:9000", "brandx", sel(), "t", opener=rec)["preset"] == "nord"

    def test_hex_overrides_are_sent_only_when_set(self):
        rec = _Recorder()
        dt.push("http://mesh:9000", "brandx", sel(), "t", opener=rec)
        assert "primaryHex" not in json.loads(rec.req.data)

        rec2 = _Recorder()
        dt.push("http://mesh:9000", "brandx", sel(primary_hex="#ff0088"), "t", opener=rec2)
        assert json.loads(rec2.req.data)["primaryHex"] == "#ff0088"


class TestFailuresExplainWhatToDoAboutThem:

    def _http_error(self, code):
        import urllib.error
        def _raise(req, timeout=None):
            raise urllib.error.HTTPError(req.full_url, code, "err", {}, None)
        return _raise

    def test_a_403_on_the_mesh_default_names_the_superadmin_rule(self):
        # A bare "403 Forbidden" is genuinely ambiguous here: editing the default and
        # editing a neighbour's domain both land on it, with different fixes.
        with pytest.raises(dt.ThemePushError) as e:
            dt.push("http://mesh:9000", "", sel(), "t", opener=self._http_error(403))
        assert "superadmin-only" in str(e.value)
        assert "mesh default" in str(e.value)
        assert e.value.status == 403

    def test_a_403_on_a_domain_names_the_own_domain_rule(self):
        with pytest.raises(dt.ThemePushError) as e:
            dt.push("http://mesh:9000", "brandy", sel(), "t", opener=self._http_error(403))
        assert "ONLY their own domain" in str(e.value)
        assert "brandy" in str(e.value)

    def test_a_401_says_the_token_is_the_problem(self):
        with pytest.raises(dt.ThemePushError) as e:
            dt.push("http://mesh:9000", "brandx", sel(), "t", opener=self._http_error(401))
        assert "not signed in" in str(e.value)

    def test_an_unreachable_mesh_is_not_reported_as_a_permission_problem(self):
        def _down(req, timeout=None):
            raise OSError("connection refused")
        with pytest.raises(dt.ThemePushError) as e:
            dt.push("http://mesh:9000", "brandx", sel(), "t", opener=_down)
        assert "could not reach" in str(e.value)
        assert e.value.status is None

    def test_a_non_json_body_is_reported_as_such(self):
        with pytest.raises(dt.ThemePushError) as e:
            dt.push("http://mesh:9000", "brandx", sel(), "t", opener=_Recorder(b"<html>"))
        assert "non-JSON" in str(e.value)
