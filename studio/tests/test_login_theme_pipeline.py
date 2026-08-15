"""The login-theme DELIVERY pipeline — compose_login_css() -> SNAP_THEME_CSS ->
compose/ConfigMap — plus the derive-theme.py CLI (subprocess, like a CI box).

Pins:
  1. ZERO REGRESSION: an unthemed config adds NO env var and composes "" (the
     entrypoint then writes an empty snap-theme.css and the shipped brand renders).
  2. ONE COMPOSITION POINT: GUI/CLI/bootstrap all ride theme.compose_login_css —
     asserted here by comparing the CLI's stdout to the library call byte-for-byte.
  3. The compose file actually passes SNAP_THEME_CSS through to the login-ui
     service (textual pin, like the Makefile STACK_NO_CLONE gate) — without it the
     whole chain is a knob wired to nothing.
  4. Upload provenance is fail-closed in the CLI: font file without licence+source
     exits 2 (the licensing decision must be recorded, never implied).
"""
import os
import subprocess
import sys

import pytest

from hugmesh_studio.core import theme
from hugmesh_studio.core.local_mesh_bootstrap import (
    LocalMeshBootstrap, LocalMeshBootstrapConfig)

_REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_CLI = os.path.join(_REPO, "scripts", "tooling", "derive-theme.py")


def _env_of(cfg: LocalMeshBootstrapConfig) -> dict:
    return LocalMeshBootstrap(_REPO, cfg)._stack_node()._build_env()


def test_unthemed_bootstrap_env_is_byte_identical_no_theme_var():
    assert "SNAP_THEME_CSS" not in _env_of(LocalMeshBootstrapConfig())
    assert theme.compose_login_css() == ""
    assert theme.compose_login_css("", "", font_preset="") == ""


def test_themed_bootstrap_env_carries_the_exact_derived_css():
    css = theme.compose_login_css("#336699", "#996633", font_preset="System UI")
    env = _env_of(LocalMeshBootstrapConfig(login_theme_css=css))
    assert env["SNAP_THEME_CSS"] == css
    assert ":root:root {" in css and "--sd-font-sans: system-ui" in css


def test_font_only_theme_still_emits_a_complete_selfcontained_css():
    css = theme.compose_login_css(font_preset="Monospace")
    assert "--sd-accent: #7c4dff;" in css          # default colours ride along
    assert "--sd-font-sans: ui-monospace" in css


def test_compose_fails_closed_on_unknown_preset_and_bad_hex():
    with pytest.raises(ValueError):
        theme.compose_login_css("#336699", font_preset="Comic Sans")
    with pytest.raises(ValueError):
        theme.compose_login_css("blue")


def test_compose_file_passes_the_theme_env_to_the_login_ui_service():
    compose = open(os.path.join(_REPO, "tests", "stack", "compose.local.yaml"),
                   encoding="utf-8").read()
    svc = compose.split("hugmesh-login-ui:", 1)[1].split("hugmesh-mastodon-ui:")[0]
    assert "SNAP_THEME_CSS: ${SNAP_THEME_CSS:-}" in svc, (
        "the compose passthrough is the delivery leg — without it the Studio knob "
        "derives css that reaches no container")


def test_cluster_deployment_env_ref_is_optional_so_unbranded_clusters_deploy():
    dep = open(os.path.join(_REPO, "specs", "cluster", "manifests", "social-ui",
                            "deployment.yaml"), encoding="utf-8").read()
    idx = dep.find("SNAP_THEME_CSS")
    assert idx != -1
    assert "optional: true" in dep[idx:idx + 400], (
        "a REQUIRED configMapKeyRef would wedge every unbranded cluster's login-ui "
        "rollout on a ConfigMap that intentionally does not exist")


def test_plan_mentions_theme_only_when_set_and_never_duplicates_stack_up():
    plan = LocalMeshBootstrap(_REPO, LocalMeshBootstrapConfig()).plan()
    assert plan.count("make stack-up") == 1     # the i18n union-rebase shipped a dupe
    assert "CUSTOM login theme" not in plan
    themed = LocalMeshBootstrap(_REPO, LocalMeshBootstrapConfig(
        login_theme_css=theme.compose_login_css("#336699"))).plan()
    assert themed.count("make stack-up") == 1
    assert "CUSTOM login theme" in themed


# ── the render-time CLI, run exactly as a CI box would ──────────────────────────────
def _cli(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, _CLI, *args],
                          capture_output=True, text=True, timeout=60)


def test_cli_stdout_is_byte_identical_to_the_library_composition():
    got = _cli("--primary", "#336699", "--secondary", "#996633", "--font", "System UI")
    assert got.returncode == 0, got.stderr
    assert got.stdout == theme.compose_login_css(
        "#336699", "#996633", font_preset="System UI")


def test_cli_nothing_chosen_emits_nothing_and_succeeds():
    got = _cli()
    assert got.returncode == 0 and got.stdout == ""


def test_cli_blocks_malformed_colour_with_exit_2():
    got = _cli("--primary", "red")
    assert got.returncode == 2 and "BLOCKED" in got.stderr


def test_cli_font_file_requires_recorded_licence_and_source(tmp_path):
    face = tmp_path / "brand.woff2"
    face.write_bytes(b"wOF2" + b"\x00" * 64)
    got = _cli("--font-file", str(face))
    assert got.returncode == 2 and "licence" in got.stderr
    ok = _cli("--font-file", str(face), "--font-licence", "SIL OFL 1.1",
              "--font-source", "https://example.com/foundry")
    assert ok.returncode == 0
    assert ok.stdout.startswith("/* embedded font: ")
    assert "sha256:" in ok.stdout and "SIL OFL 1.1" in ok.stdout
    assert "@font-face" in ok.stdout and "data:font/woff2;base64," in ok.stdout


def test_cli_rejects_renamed_junk_font(tmp_path):
    face = tmp_path / "junk.woff2"
    face.write_bytes(b"this is not a font")
    got = _cli("--font-file", str(face), "--font-licence", "x", "--font-source", "y")
    assert got.returncode == 2 and "magic bytes" in got.stderr


def test_cli_configmap_wraps_the_same_css_in_a_block_scalar():
    got = _cli("--primary", "#336699", "--configmap")
    assert got.returncode == 0
    assert got.stdout.startswith("apiVersion: v1\nkind: ConfigMap\n")
    assert "  SNAP_THEME_CSS: |" in got.stdout
    yaml = pytest.importorskip("yaml")
    doc = yaml.safe_load(got.stdout)
    assert doc["metadata"]["name"] == "login-theme"
    assert doc["data"]["SNAP_THEME_CSS"] == theme.compose_login_css("#336699")


def test_cli_brand_yaml_block_drives_the_same_derivation(tmp_path):
    yaml = pytest.importorskip("yaml")   # noqa: F841 — the CLI needs it, not us
    by = tmp_path / "brand.yaml"
    by.write_text("brand: t\nlogin_theme:\n  primary: '#336699'\n  font: Monospace\n",
                  encoding="utf-8")
    got = _cli("--brand-yaml", str(by))
    assert got.returncode == 0
    assert got.stdout == theme.compose_login_css("#336699", font_preset="Monospace")


class TestTheCliPresetPath:
    """The other three axes, which were unreachable from tooling.

    theme.py has carried preset/ramp/style (and now decor) for some time and the Studio
    pushes all four, but this CLI could only render the primary/secondary path — so an
    operator scripting a rebrand could not reproduce the theme their own Studio previews.

    The rendering goes through domain_theme.render_css, the SAME function that fills the
    per-domain stylesheet cache, rather than re-assembling the tokens here. That is the
    single-implementation rule applied to tooling: two assemblies of the same tokens is
    how a CLI and a Studio start disagreeing.
    """

    def _run(self, *args):
        return subprocess.run([sys.executable, _CLI, *args],
                              capture_output=True, text=True, timeout=120)

    def test_a_preset_renders_a_full_sheet(self):
        r = self._run("--preset", "nord")
        assert r.returncode == 0, r.stderr
        assert ":root:root" in r.stdout
        assert "--hug-accent" in r.stdout

    def test_each_axis_changes_the_output(self):
        base = self._run("--preset", "nord").stdout
        assert self._run("--preset", "nord", "--ramp", "light").stdout != base
        assert self._run("--preset", "nord", "--style", "sharp").stdout != base
        assert self._run("--preset", "nord", "--decor", "uwu").stdout != base

    def test_decor_reaches_the_nav_suffix_tokens(self):
        out = self._run("--preset", "nord", "--decor", "uwu").stdout
        assert "--hug-nav-suffix: ' UwU';" in out

    def test_the_default_decor_emits_nothing_decorative(self):
        assert "--hug-nav-suffix: '';" in self._run("--preset", "nord").stdout

    def test_mixing_the_two_colour_PATHS_is_refused_rather_than_silently_resolved(self):
        # A preset BRINGS its colours; combining would discard one side without saying so.
        r = self._run("--preset", "nord", "--primary", "#ffd700")
        assert r.returncode != 0
        assert "different paths" in r.stderr

    def test_an_out_of_vocabulary_axis_is_refused_with_the_vocabulary(self):
        r = self._run("--preset", "nord", "--decor", "nyan")
        assert r.returncode != 0
        assert "none, uwu" in r.stderr

    def test_an_unknown_preset_is_refused(self):
        r = self._run("--preset", "no-such-preset-anywhere")
        assert r.returncode != 0

    def test_the_primary_secondary_path_still_works_unchanged(self):
        # The preset path is additive; the existing contract must not shift.
        r = self._run("--primary", "#ffd700", "--secondary", "#7c4dff")
        assert r.returncode == 0
        assert ":root:root" in r.stdout

    def test_accent_on_is_present_so_filled_buttons_have_a_legible_text_colour(self):
        # The token whose absence made 24/38 presets fail AA.
        assert "--hug-accent-on" in self._run("--preset", "nonbinary").stdout
