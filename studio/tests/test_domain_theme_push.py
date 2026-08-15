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


class TestTheDecorAxisReachesTheBff:
    """The axis that was rendered locally but never sent.

    ``render_css`` has always baked decor into the stylesheet, so the Studio LOOKED
    correct end to end. But ``build_payload`` sent only preset/ramp/style, so the BFF
    stored ``decor='none'`` no matter what was chosen. Two things then broke: the admin UI
    showed "None" for a mesh that visibly had decoration, and -- because the BFF decides
    whether to drop a cached render by comparing selections -- switching a decoration off
    compared EQUAL to leaving it on, so the decorated stylesheet survived the write meant
    to clear it.
    """

    def test_the_payload_carries_the_decor(self):
        assert dt.build_payload(sel(decor="uwu"))["decor"] == "uwu"

    def test_none_is_sent_rather_than_omitted(self):
        # The hexes are omitted when blank; decor must NOT follow that rule. "none" is the
        # selection that turns decoration off, and an absent key cannot express it.
        body = dt.build_payload(sel(decor="none"))
        assert body["decor"] == "none"

    def test_it_is_sent_even_when_the_css_is_not(self):
        # A caller re-pointing a domain without re-rendering still has to move the axis,
        # or the stored selection silently disagrees with the served stylesheet.
        assert dt.build_payload(sel(decor="sparkle"), include_css=False)["decor"] == "sparkle"

    def test_the_decor_axis_changes_the_rendered_output_too(self):
        # Pins that the value sent and the bytes rendered come from the same selection.
        assert dt.render_css(sel(decor="uwu")) != dt.render_css(sel(decor="none"))


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


class _Cap:
    """Stands in for vaults.Capability without importing the docker-dependent module."""

    def __init__(self, detail=""):
        self.detail = detail
        self.available = False


class TestTokenResolution:
    """Where the mesh-admin token comes from, and what happens when it is nowhere.

    The ORDER is the design: Vault is preferred, but it cannot be required. vaults.py is
    explicit that Vault is a DevOps/Kubernetes-lane service and a docker-compose mesh has
    no vault container at all — so a Vault-only lookup would ship a theme control that is
    permanently dead on the lane the operator actually runs. That is the inert-control
    trap this codebase has hit repeatedly.
    """

    def test_an_explicit_token_wins_and_vault_is_not_even_consulted(self):
        calls = []
        def reader(p, k):
            calls.append((p, k))
            return "vault-token", _Cap()
        src = dt.resolve_token("explicit-token", reader=reader, environ={})
        assert src.token == "explicit-token"
        assert src.origin == "argument"
        assert calls == [], "an explicit token must not trigger a Vault read"

    def test_vault_is_preferred_over_the_environment(self):
        src = dt.resolve_token(reader=lambda p, k: ("vault-token", _Cap()),
                               environ={"HUGMESH_ADMIN_TOKEN": "env-token"})
        assert src.token == "vault-token"
        assert src.origin == "vault"

    def test_it_reads_the_agreed_vault_path_and_key(self):
        seen = {}
        def reader(p, k):
            seen["path"], seen["key"] = p, k
            return "t", _Cap()
        dt.resolve_token(reader=reader, environ={})
        assert seen["path"] == dt.TOKEN_VAULT_PATH
        assert seen["key"] == dt.TOKEN_VAULT_KEY

    def test_the_environment_is_used_when_vault_has_nothing(self):
        # The docker-lane case: no vault container, so the fallback is the whole point.
        src = dt.resolve_token(reader=lambda p, k: (None, _Cap("Vault is not running on this mesh.")),
                               environ={"HUGMESH_ADMIN_TOKEN": "env-token"})
        assert src.token == "env-token"
        assert src.origin == "environment"

    def test_with_no_token_anywhere_it_names_BOTH_routes(self):
        src = dt.resolve_token(reader=lambda p, k: (None, _Cap("Vault is not running on this mesh.")),
                               environ={})
        assert not src.available
        assert dt.TOKEN_VAULT_PATH in src.remedy
        assert dt.TOKEN_ENV_VAR in src.remedy

    def test_it_carries_vaults_own_reason_forward(self):
        # "vault is absent on this lane" and "vault is up but the path is empty" need
        # different actions, so the reason must survive rather than collapse to "no token".
        src = dt.resolve_token(reader=lambda p, k: (None, _Cap("secret/x has no value for 'admin_token'")),
                               environ={})
        assert "has no value" in src.detail

    def test_a_blank_or_whitespace_token_is_not_a_token(self):
        src = dt.resolve_token("   ", reader=lambda p, k: (None, _Cap()),
                               environ={"HUGMESH_ADMIN_TOKEN": "  "})
        assert not src.available

    def test_the_token_never_appears_in_the_detail_or_remedy(self):
        # Details reach logs and dialogs; the token must not.
        src = dt.resolve_token(reader=lambda p, k: ("s3cret-token", _Cap()), environ={})
        assert src.token == "s3cret-token"
        assert "s3cret-token" not in src.detail
        assert "s3cret-token" not in src.remedy


class TestPushUsesTheResolvedToken:

    def test_a_resolved_token_reaches_the_authorization_header(self):
        rec = _Recorder()
        src = dt.TokenSource(token="vault-token", origin="vault")
        dt.push("http://mesh:9000", "brandx", sel(), token_source=src, opener=rec)
        assert rec.req.headers["Authorization"] == "Bearer vault-token"

    def test_no_token_fails_BEFORE_a_request_is_built(self):
        # Sending an anonymous request and reporting the mesh's 401 would blame the mesh
        # for a local misconfiguration.
        rec = _Recorder()
        src = dt.TokenSource(detail="no mesh-admin token available.", remedy="Store one in Vault…")
        with pytest.raises(dt.ThemePushError) as e:
            dt.push("http://mesh:9000", "brandx", sel(), token_source=src, opener=rec)
        assert rec.req is None
        assert "no mesh-admin token" in str(e.value)
        assert "Vault" in str(e.value)

    def test_an_explicit_token_argument_still_works_unchanged(self):
        rec = _Recorder()
        dt.push("http://mesh:9000", "brandx", sel(), "explicit", opener=rec)
        assert rec.req.headers["Authorization"] == "Bearer explicit"


class TestTheDecorAxis:
    """Decorative nav text — formerly hard-coded, now an operator choice.

    hugmesh-host-shell's menu.component.scss appended ' UwU' to every nav link, ' UwO' on
    hover and ' OwO' when active, with no way to change or remove it. Two things were
    wrong with that on a platform whose appearance is otherwise fully themeable: it was
    not the operator's choice, and pseudo-element `content` is ANNOUNCED BY SCREEN
    READERS, so every link read as "Home UwU".

    The default is therefore OFF, and the consuming SCSS pairs these tokens with CSS
    alt-text syntax (`content: var(...) / ''`) so the text is decorative-only. Without
    that pairing this axis would be an accessibility regression sold as a feature.
    """

    def test_the_default_is_off_so_a_plain_mesh_renders_plain_nav(self):
        assert dt.ThemeSelection(preset="nord").decor == "none"
        css = dt.render_css(dt.ThemeSelection(preset="nord"))
        assert "--hug-nav-suffix: '';" in css

    def test_the_historical_chrome_survives_as_an_opt_in(self):
        # Removed as a default, kept as a choice — the operator asked for it to become an
        # option, not to be deleted.
        css = dt.render_css(dt.ThemeSelection(preset="nord", decor="uwu"))
        assert "--hug-nav-suffix: ' UwU';" in css
        assert "--hug-nav-suffix-hover: ' UwO';" in css
        assert "--hug-nav-suffix-active: ' OwO';" in css

    def test_every_variant_emits_all_three_states(self):
        # A variant missing a state would inherit the previous theme's value at runtime.
        for variant in theme.DECOR_VARIANTS:
            css = dt.render_css(dt.ThemeSelection(preset="nord", decor=variant))
            for token in ("--hug-nav-suffix", "--hug-nav-suffix-hover", "--hug-nav-suffix-active"):
                assert f"{token}:" in css, f"{variant} is missing {token}"

    def test_values_are_css_string_literals_ready_to_interpolate(self):
        # They land verbatim inside a `content:` declaration, so an unquoted value would
        # be a parse error that silently drops the whole rule.
        for variant, tokens in theme.DECOR_VARIANTS.items():
            for name, value in tokens.items():
                assert value.startswith("'") and value.endswith("'"), f"{variant}/{name}"

    def test_an_unknown_variant_is_rejected_before_the_network(self):
        rec = _Recorder()
        with pytest.raises(ValueError):
            dt.push("http://mesh:9000", "brandx",
                    dt.ThemeSelection(preset="nord", decor="nyan"), "t", opener=rec)
        assert rec.req is None

    def test_decor_tokens_falls_back_to_nothing_rather_than_raising(self):
        # Cosmetic: a typo should render plain chrome, not refuse the whole theme.
        assert theme.decor_tokens("nyan") == theme.decor_tokens(theme.DEFAULT_DECOR)

    def test_it_changes_the_rendered_output_so_it_is_a_real_axis(self):
        base = dt.render_css(dt.ThemeSelection(preset="nord"))
        assert dt.render_css(dt.ThemeSelection(preset="nord", decor="uwu")) != base
