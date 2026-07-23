"""The web-login LOCALE-SET knob (the operator's 'include or exclude language
support'), threaded Studio -> LocalStackNode -> `make stack-up` env ->
compose build arg -> the login-ui Dockerfile's ARG SNAP_WEB_LOCALES.

This is the anti-dead-knob coverage for THIS feature. The session's hardest-won
rule is 'never ship a knob wired to nothing', so the load-bearing assertions here
are: (1) the DEFAULT emits NOTHING (byte-identical to a plain stack-up) and (2) a
non-empty value reaches the SAME env var `make stack-up` forwards to compose.
Everything is Qt-free and never starts a container.
"""
import os

from hugmesh_studio.core.local_stack_node import LocalStackNode
from hugmesh_studio.core.local_mesh_bootstrap import (
    LocalMeshBootstrap,
    LocalMeshBootstrapConfig,
    _parse_web_locales,
)

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# ── the env boundary: LocalStackNode._build_env is EXACTLY what stack-up runs ──

def test_default_emits_no_web_locales_env():
    """web_locales=() must add ZERO bytes to the stack-up environment — the
    English-only default has to be byte-identical to every existing caller, or it
    is not really a no-op default."""
    env = LocalStackNode(GENERATOR_DIR)._build_env()
    assert "SNAP_WEB_LOCALES" not in env


def test_selected_locales_reach_the_stackup_env():
    env = LocalStackNode(GENERATOR_DIR, web_locales=("de", "fr"))._build_env()
    assert env["SNAP_WEB_LOCALES"] == "de,fr"


def test_single_locale_reaches_the_env():
    env = LocalStackNode(GENERATOR_DIR, web_locales=("en-XA",))._build_env()
    assert env["SNAP_WEB_LOCALES"] == "en-XA"


def test_empty_tuple_is_treated_as_unset():
    env = LocalStackNode(GENERATOR_DIR, web_locales=())._build_env()
    assert "SNAP_WEB_LOCALES" not in env


# ── the config -> node wiring (the GUI/CLI both build this config) ─────────────

def test_bootstrap_threads_web_locales_into_the_stack_node():
    cfg = LocalMeshBootstrapConfig(web_locales=("de",))
    node = LocalMeshBootstrap(GENERATOR_DIR, cfg)._stack_node()
    assert node.web_locales == ("de",)
    assert node._build_env()["SNAP_WEB_LOCALES"] == "de"


def test_default_config_ships_english_only():
    cfg = LocalMeshBootstrapConfig()
    assert cfg.web_locales == ()
    node = LocalMeshBootstrap(GENERATOR_DIR, cfg)._stack_node()
    assert "SNAP_WEB_LOCALES" not in node._build_env()


# ── plan preview (the confirm-before-run surface must state what ships) ────────

def test_plan_states_english_only_by_default():
    plan = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig()).plan()
    assert "English only" in plan
    assert "SNAP_WEB_LOCALES" not in plan  # nothing forwarded => don't imply it is


def test_plan_names_selected_catalogs():
    cfg = LocalMeshBootstrapConfig(web_locales=("de", "fr"))
    plan = LocalMeshBootstrap(GENERATOR_DIR, cfg).plan()
    assert "de, fr" in plan
    assert "SNAP_WEB_LOCALES=de,fr" in plan
    assert "i18n/{de,fr}.json" in plan


# ── validation: SHAPE only, never invents an existence constraint ──────────────

def test_valid_tags_pass_validation():
    cfg = LocalMeshBootstrapConfig(web_locales=("de", "pt-BR", "zh-Hant", "en-XA"))
    problems = LocalMeshBootstrap(GENERATOR_DIR, cfg).validate()
    assert not [p for p in problems if "web locale" in p]


def test_malformed_tag_is_flagged():
    cfg = LocalMeshBootstrapConfig(web_locales=("de", "not a tag!"))
    problems = LocalMeshBootstrap(GENERATOR_DIR, cfg).validate()
    assert any("not a tag!" in p for p in problems)


def test_validation_does_not_require_a_catalog_to_exist():
    # 'xx' is a well-shaped tag with no catalog anywhere. validate() must accept it
    # (existence is the login-ui build's job); inventing an existence check here
    # would be exactly the constraint #387 forbids.
    cfg = LocalMeshBootstrapConfig(web_locales=("xx",))
    problems = LocalMeshBootstrap(GENERATOR_DIR, cfg).validate()
    assert not [p for p in problems if "web locale" in p]


# ── the --web-locales CLI parser ───────────────────────────────────────────────

def test_parse_web_locales_empty_is_english_only():
    assert _parse_web_locales("") == ()
    assert _parse_web_locales("   ") == ()


def test_parse_web_locales_splits_and_dedupes_order_preserving():
    assert _parse_web_locales("de, fr, de  es") == ("de", "fr", "es")


def test_parse_web_locales_handles_mixed_separators():
    assert _parse_web_locales("de,fr\tpt-BR") == ("de", "fr", "pt-BR")
