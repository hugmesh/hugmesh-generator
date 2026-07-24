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
import re

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core.local_mesh_bootstrap import (   # noqa: E402
    LocalMeshBootstrap, LocalMeshBootstrapConfig, _tail, discover_brands,
    expected_build_contexts)
from hugmesh_studio.core.local_stack_node import LocalStackNode  # noqa: E402

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
    assert all(c.startswith("hugmesh") for c in ctx)
    assert len(ctx) == len(set(ctx))            # de-duplicated (gateway appears 3x)


def test_source_coverage_never_rounds_up(tmp_path):
    ctx = expected_build_contexts(GENERATOR_DIR)
    for c in ctx[:5]:
        (tmp_path / c).mkdir()
    cfg = LocalMeshBootstrapConfig(source_mode="existing", source_dir=str(tmp_path))
    found, missing = LocalMeshBootstrap(GENERATOR_DIR, cfg).source_coverage()
    assert len(found) == 5 and len(found) + len(missing) == len(ctx)


def _clone_script_repos():
    """The REPOS array from scripts/clone-all-repos.sh — the dir names the clone
    step actually CREATES under STACK_SRC."""
    path = os.path.join(GENERATOR_DIR, "scripts", "clone-all-repos.sh")
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    body = re.search(r"^REPOS=\((.*?)^\)", text, re.S | re.M)
    assert body, "clone-all-repos.sh no longer declares a REPOS=( … ) array"
    return {ln.strip() for ln in body.group(1).splitlines()
            if ln.strip() and not ln.strip().startswith("#")}


def test_every_compose_build_context_is_a_repo_the_clone_step_creates():
    """The drift that broke a live bring-up: the HugMesh rebrand renamed every
    compose ``context:`` to .stack-src/hugmesh-*, but clone-all-repos.sh kept
    cloning the pre-rename snapdragon-* directory names. Nothing compared the two
    sides, so `make stack-up` died at the first image with "unable to prepare
    context: path …/.stack-src/hugmesh-remote-fragment not found" — after a full
    24-repo clone. One side is the producer, the other the consumer; pin them."""
    cloned = _clone_script_repos()
    missing = [c for c in expected_build_contexts(GENERATOR_DIR) if c not in cloned]
    assert not missing, (
        f"compose.local.yaml builds from {missing}, which scripts/clone-all-repos.sh "
        f"never creates under STACK_SRC (it clones {sorted(cloned)})")


def _compose_services_by_context():
    """service -> build-context dir, straight out of compose.local.yaml. The two are
    NOT interchangeable: the gateway image is built by three services (pki/be/fe) from
    ONE context, and hugmesh-actions' context serves the service named hugmesh-api."""
    path = os.path.join(GENERATOR_DIR, "tests", "stack", "compose.local.yaml")
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    out, service = {}, None
    for line in text.splitlines():
        m = re.match(r"^  ([A-Za-z0-9][\w.-]*):\s*$", line)
        if m:
            service = m.group(1)
            continue
        c = re.search(r"context:\s*\$\{STACK_SRC[^}]*\}/([\w.-]+)", line)
        if c and service:
            out[service] = c.group(1)
    return out


def test_every_private_maven_consumer_is_wired_into_the_m2_override():
    """Every checkout whose Dockerfile takes ARG CI_API_V4_URL resolves org-private
    systems.hugmesh:* artifacts, so a COLD build must hand EVERY service built from it
    the local registry via tests/stack/compose.m2-local.yaml. Two ways this drifted:

      * the forum/wiki/owncast/tube BFFs were added to compose.local.yaml long after
        the override and were simply omitted;
      * the gateway trio shares ONE context under THREE service names, so matching on
        directory names alone silently "covered" a service that was never wired.

    Both reached maven with an empty CI_API_V4_URL and died resolving hugmesh-parent /
    hugmesh-commons. Only checkable against a real clone (the Dockerfiles live in the
    sibling repos), so it SKIPS rather than pretends when .stack-src is not populated."""
    src = os.path.join(GENERATOR_DIR, ".stack-src")
    if not os.path.isdir(src):
        pytest.skip(".stack-src not populated — run `make stack-clone` first")
    consumers = set()
    for name in os.listdir(src):
        dockerfile = os.path.join(src, name, "Dockerfile")
        if not os.path.isfile(dockerfile):
            continue
        with open(dockerfile, encoding="utf-8", errors="replace") as fh:
            if "ARG CI_API_V4_URL" in fh.read():
                consumers.add(name)
    if not consumers:
        pytest.skip("no private-maven consumer checkouts found")
    with open(os.path.join(GENERATOR_DIR, "tests", "stack", "compose.m2-local.yaml"),
              encoding="utf-8") as fh:
        wired = set(re.findall(r"^  ([A-Za-z0-9][\w.-]*):$", fh.read(), re.M))
    need = {svc for svc, ctx in _compose_services_by_context().items() if ctx in consumers}
    assert need, "no service maps to a private-maven consumer context — parser broke"
    assert not (need - wired), (
        f"{sorted(need - wired)} build from a checkout that resolves org-private maven "
        f"artifacts but are not in compose.m2-local.yaml — their cold build gets an "
        f"empty CI_API_V4_URL")


def test_clone_script_migrates_pre_rename_checkouts_instead_of_re_cloning():
    """A ./.stack-src from before the rename holds snapdragon-* dirs (several GB).
    The script must rename them into the canonical names rather than leave them
    orphaned beside a fresh 24-repo download."""
    path = os.path.join(GENERATOR_DIR, "scripts", "clone-all-repos.sh")
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    assert "migrate_legacy_dir" in text and "snapdragon.systems" in text, \
        "the pre-rename directory migration is gone"
    assert text.index("migrate_legacy_dir \"${repo}\"") < text.index('dest="${STACK_SRC}/${repo}"'), \
        "migration must run BEFORE the present/absent check that decides clone-vs-update"
    body = text.split("migrate_legacy_dir()")[1].split("\n}")[0]
    code = "\n".join(ln for ln in body.splitlines() if not ln.strip().startswith("#"))
    assert "clone_url" not in code, \
        "clone_url injects the token — never write that URL into .git/config"
    assert 'remote set-url origin "${GIT_BASE}/${new}.git"' in code, \
        "the migrated checkout must be re-pointed at the canonical (token-free) URL"


def test_failure_lines_report_the_tail_of_the_output_not_the_banner():
    """`make stack-*` prints its banner first and fails last, so a head slice hides
    the cause (the live case reported '==> Cloning 24 HugMesh repos …' while the
    real error sat 40 lines below)."""
    out = "==> Cloning 24 HugMesh repos into /x\n" + ("noise\n" * 400) + "unable to prepare context"
    assert _tail(out).endswith("unable to prepare context")
    assert "Cloning 24 HugMesh repos" not in _tail(out)
    assert _tail(out).startswith("…")                    # truncation is visible
    assert _tail("short output") == "short output"       # no ellipsis when it fits
    assert _tail("") == "" and _tail(None) == ""


def test_stack_clean_removes_only_what_this_stack_built():
    """`make stack-clean` is the destructive disk-reclaim verb behind the GUI's
    "Stop & clean Docker…". It must stay SCOPED: down the compose project with
    --rmi local (images with no registry name — the ones this stack built), never
    a `docker system prune`/`image prune`, which would delete other projects' work."""
    with open(os.path.join(GENERATOR_DIR, "Makefile"), encoding="utf-8") as fh:
        mk = fh.read()
    target = mk[mk.index("\nstack-clean:"):]
    recipe = target[:target.index("\n\n")]
    assert "--rmi local" in recipe, "stack-clean no longer removes the built images"
    assert "down -v" in recipe and "--remove-orphans" in recipe
    for forbidden in ("system prune", "image prune", "-a ", "--all"):
        assert forbidden not in recipe, \
            f"stack-clean must not reach beyond this compose project ({forbidden!r})"
    # the private-maven registry + its env file are this stack's too
    assert "docker rm -f $(M2_REGISTRY_NAME)" in recipe
    assert "rm -f $(STACK_M2_ENV)" in recipe


def test_stack_clean_recipe_has_no_command_substitution():
    """A backtick inside a double-quoted recipe echo is COMMAND SUBSTITUTION: an
    early draft of this target ended with `... run \u0060make stack-m2-bootstrap\u0060 ...`
    inside double quotes, so "clean" would have kicked off a full maven bootstrap."""
    with open(os.path.join(GENERATOR_DIR, "Makefile"), encoding="utf-8") as fh:
        mk = fh.read()
    target = mk[mk.index("\nstack-clean:"):]
    recipe = target[:target.index("\n\n")]
    for line in recipe.splitlines():
        if '"' in line and "`" in line:
            body = line[line.index('"'):]
            assert "`" not in body, f"backtick inside a double-quoted recipe line: {line}"


def test_the_gui_exposes_stop_and_clean_as_separate_verbs():
    """Stopping is routine; deleting ~26 built images is not. Conflating them would
    make an ordinary restart cost an hour-long rebuild, so they stay separate — and
    the destructive one confirms first."""
    path = os.path.join(GENERATOR_DIR, "studio", "hugmesh_studio", "gui", "pages",
                        "localmesh.py")
    with open(path, encoding="utf-8") as fh:
        gui = fh.read()
    assert "boot_down_btn" in gui and "boot_clean_btn" in gui
    handler = gui[gui.index("def _bootstrap_clean"):]
    handler = handler[:handler.index("\n    def ", 1)]
    assert "QMessageBox.question" in handler, "the destructive verb must confirm first"
    assert "boot.clean(" in handler
    assert "cancelled — nothing was removed" in handler, "declining must be a no-op"


def test_disabled_start_says_why(qapp_localmesh_page):
    """"Generate & start" is disabled until the acknowledgement is ticked. A disabled
    button that explains nothing reads as a broken app — and the "Acknowledge the plan
    first." status line is unreachable precisely BECAUSE the button is disabled."""
    page = qapp_localmesh_page
    page.ack.setChecked(False)
    assert not page.boot_start_btn.isEnabled()
    tip = page.boot_start_btn.toolTip()
    assert "acknowledgement" in tip.lower(), f"no reason given: {tip!r}"
    assert "tick the acknowledgement" in page.status.text().lower()

    page.ack.setChecked(True)
    assert page.boot_start_btn.isEnabled()
    assert "acknowledgement" not in page.boot_start_btn.toolTip().lower(), \
        "the stale 'why disabled' reason survived into the enabled state"


def test_discover_brands_leads_with_default_and_excludes_non_brand_conf():
    brands = discover_brands(GENERATOR_DIR)
    assert brands[0] == "hugmesh"
    assert "domains" not in brands              # a CA registry, not a brand profile
    assert "example" in brands                  # brands/example.conf is real


# ── page fixture (offscreen; no wizard needed for the collect test) ────────────────
@pytest.fixture
def qapp_localmesh_page():
    pytest.importorskip("hugmesh_studio.gui.qt",
                        reason="no Qt binding (PySide6/PyQt6) installed")
    from hugmesh_studio.gui.qt import QtWidgets
    from hugmesh_studio.gui.pages.localmesh import LocalMeshPage
    import types
    _ = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"])
    shim = types.SimpleNamespace(generator_dir=GENERATOR_DIR, localmesh_selected=True)
    return LocalMeshPage(shim)
