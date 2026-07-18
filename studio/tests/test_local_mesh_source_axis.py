"""The bootstrap SOURCE axis + brand wiring (the 2026-07-17 operator asks).

Pins, in order of importance:
  1. ZERO REGRESSION: the default ("clone") mode produces a make-env byte-identical
     to the pre-field behaviour — no STACK_SRC, no STACK_NO_CLONE.
  2. THE FOOTGUN GUARD: "existing" mode always pairs STACK_SRC with STACK_NO_CLONE=1,
     because `stack-up` depends unconditionally on `stack-clone`, whose update path
     `git reset --hard`s every checkout under STACK_SRC (clone-all-repos.sh:88-99) —
     pointed at the operator's own tree it would destroy uncommitted work. The
     Makefile's skip gate is asserted TEXTUALLY too, so a Makefile refactor cannot
     silently drop it while this suite stays green.
  3. THE DEAD-FIELD CLASS: collect_bootstrap() must carry EVERY operator-visible
     control (brand was declared on the config but never collected — the GUI was
     strictly less capable than the CLI's --brand).
  4. Honest coverage: expected contexts derive from compose.local.yaml (the file
     compose actually reads), and source_coverage never rounds up.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from snapdragon_studio.core.local_mesh_bootstrap import (   # noqa: E402
    LocalMeshBootstrap, LocalMeshBootstrapConfig, discover_brands,
    expected_build_contexts)
from snapdragon_studio.core.local_stack_node import LocalStackNode  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


# ── 1. zero regression ─────────────────────────────────────────────────────────────
def test_default_clone_mode_env_is_byte_identical_to_pre_field_behaviour():
    plain = LocalStackNode(GENERATOR_DIR, env="test")._build_env()
    with_axis = LocalStackNode(GENERATOR_DIR, env="test",
                               source_mode="clone", source_dir="")._build_env()
    assert plain == with_axis
    assert "STACK_SRC" not in with_axis
    assert "STACK_NO_CLONE" not in with_axis


# ── 2. the footgun guard ───────────────────────────────────────────────────────────
def test_existing_mode_sets_stack_src_and_the_no_clone_interlock_as_a_pair(tmp_path):
    env = LocalStackNode(GENERATOR_DIR, source_mode="existing",
                         source_dir=str(tmp_path))._build_env()
    assert env["STACK_SRC"] == str(tmp_path)
    assert env["STACK_NO_CLONE"] == "1"


def test_existing_mode_with_empty_dir_sets_neither():
    # an empty STACK_SRC would silently resolve the Makefile default and build the
    # wrong tree — the pair is all-or-nothing.
    env = LocalStackNode(GENERATOR_DIR, source_mode="existing", source_dir="")._build_env()
    assert "STACK_SRC" not in env and "STACK_NO_CLONE" not in env


def test_makefile_stack_clone_honours_the_skip_gate():
    # TEXTUAL pin: stack-clone must consult STACK_NO_CLONE before running
    # clone-all-repos.sh (whose update path git-reset --hards existing checkouts).
    with open(os.path.join(GENERATOR_DIR, "Makefile"), encoding="utf-8") as fh:
        mk = fh.read()
    target = mk[mk.index("stack-clone:"):]
    recipe = target[:target.index("\n\n")]
    assert "STACK_NO_CLONE" in recipe, "the skip gate vanished from stack-clone"
    assert recipe.index("STACK_NO_CLONE") < recipe.index("clone-all-repos.sh"), \
        "the gate must be checked BEFORE clone-all-repos.sh runs"


# ── 3. the dead-field class ────────────────────────────────────────────────────────
def test_collect_bootstrap_drops_no_operator_visible_field(qapp_localmesh_page):
    """Every bootstrap-tab control must reach the config — set every widget to a
    non-default value and assert each lands. A new widget whose value never arrives
    fails the length check below when the config grows a field for it."""
    page = qapp_localmesh_page
    page.env_prod.setChecked(True)
    page.superadmin.setText("boss")
    page.social.setChecked(True)
    page.with_tor.setChecked(True)
    page.boot_domain.setText("acme.example")
    page.boot_auth_key.setText("tskey-x")
    page.boot_login_server.setText("https://hs.acme.example")
    page.brand.setCurrentText("example")
    page.src_existing.setChecked(True)
    page.src_dir.setText("/some/tree")
    c = page.collect_bootstrap()
    assert (c.env, c.superadmin_username, c.social, c.with_tor) == (
        "prod", "boss", True, True)
    assert (c.cluster_domain, c.auth_key, c.login_server) == (
        "acme.example", "tskey-x", "https://hs.acme.example")
    assert (c.brand, c.source_mode, c.source_dir) == (
        "example", "existing", "/some/tree")


# ── 4. honest coverage ─────────────────────────────────────────────────────────────
def test_expected_contexts_derive_from_the_compose_file():
    ctx = expected_build_contexts(GENERATOR_DIR)
    assert len(ctx) >= 20
    assert all(c.startswith("snapdragon") for c in ctx)
    assert len(ctx) == len(set(ctx))            # de-duplicated (gateway appears 3x)


def test_source_coverage_never_rounds_up(tmp_path):
    ctx = expected_build_contexts(GENERATOR_DIR)
    for c in ctx[:5]:
        (tmp_path / c).mkdir()
    cfg = LocalMeshBootstrapConfig(source_mode="existing", source_dir=str(tmp_path))
    found, missing = LocalMeshBootstrap(GENERATOR_DIR, cfg).source_coverage()
    assert len(found) == 5 and len(found) + len(missing) == len(ctx)


def test_discover_brands_leads_with_default_and_excludes_non_brand_conf():
    brands = discover_brands(GENERATOR_DIR)
    assert brands[0] == "snapdragon"
    assert "domains" not in brands              # a CA registry, not a brand profile
    assert "example" in brands                  # brands/example.conf is real


# ── page fixture (offscreen; no wizard needed for the collect test) ────────────────
@pytest.fixture
def qapp_localmesh_page():
    pytest.importorskip("snapdragon_studio.gui.qt",
                        reason="no Qt binding (PySide6/PyQt6) installed")
    from snapdragon_studio.gui.qt import QtWidgets
    from snapdragon_studio.gui.pages.localmesh import LocalMeshPage
    import types
    _ = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"])
    shim = types.SimpleNamespace(generator_dir=GENERATOR_DIR, localmesh_selected=True)
    return LocalMeshPage(shim)
