"""Out-of-scope VALUES on the channels that draw no widget (findings 1, 6, 8).

The GUI half of the field-scope track hides an option so it cannot be set. That fixes the
wizard and nothing else: `--config`, the worklist worker and docker/build-image.sh hand a
JSON straight to to_cli_args and never construct a page. These tests pin the non-GUI half.

THE TIERING RULE, which is the whole point and is grounded in each builder's REAL
behaviour rather than in what feels tidy:

  BLOCK  only where the BUILDER ITSELF errs, i.e. a genuine post-dispatch dead-end.
         rpi5 + --standalone + a node role is one: build-rpi5-stage4.sh:1037 hard-errors,
         but only AFTER the operator has paid the dispatch. Catching it at second 0
         invents no constraint — it just moves the builder's own answer earlier.
  WARN   where the builder ACCEPTS the value. x86 + --standalone + a node role builds
         SUCCESSFULLY and silently wrong. Blocking it would invent a constraint the
         builder does not have; staying silent is what let the bug ship for months.

  LEAK vs EXPLICIT: only a NON-DEFAULT value is reported. A field at its dataclass default
  is a leak nobody asked for and belongs to the resolve lane (this is the rule
  _DEFAULT_LEAK_ROLES already states for role resolution). bundle_source defaults to True,
  so True-on-a-node is a LEAK and must NOT appear here — finding 4/5 is a resolve, not a
  warning. test_bundle_source_default_is_a_leak_not_a_violation pins that boundary.
"""
from __future__ import annotations

import os
import re

from hugmesh_studio.core.config import (
    RPI5_ROLE_MAP, ImageConfig, field_in_scope, image_class, roles_for_platform,
    scope_violations,
)
from hugmesh_studio.core.config import _ALL_MODES as ALL_MODES  # single source: standalone|cloud|mesh

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _cfg(**kw) -> ImageConfig:
    cfg = ImageConfig(platform="x86", role="backend", mode="mesh", env="test")
    for k, v in kw.items():
        setattr(cfg, k, v)
    return cfg


# ── finding 1: --standalone on a node, from a config JSON ───────────────────────────────
def test_x86_standalone_on_a_node_warns_and_never_blocks():
    """The builder ACCEPTS it, so blocking would invent a constraint. It must warn — and
    the text must name the CONSEQUENCE (a node that cannot join the mesh), not just say
    "invalid": the operator's whole problem was that nothing told them what went wrong."""
    blocking, advisory = scope_violations(_cfg(standalone=True))
    assert blocking == []
    assert len(advisory) == 1
    assert "never join the mesh" in advisory[0].lower() or "never join" in advisory[0]
    assert "ROLE_K8S=none" in advisory[0]


# ── nvidia_cuda × gpu_driver: the 2026-07-19 08:2x burst of 8 dispatch deaths ───────────
def test_cuda_with_explicit_non_nvidia_driver_blocks():
    """cuda + amd-free is the EXACT pair the operator shipped 8 times (empty session dirs,
    1-second deaths). The x86 builder hard-errors on it -> BLOCK (a real post-dispatch dead
    end), naming the fix. This is what a Studio preflight must catch BEFORE dispatch."""
    blocking, advisory = scope_violations(_cfg(nvidia_cuda=True, gpu_driver="amd-free"))
    assert len(blocking) == 1 and advisory == []
    assert "nvidia" in blocking[0].lower() and "amd-free" in blocking[0]


def test_cuda_with_auto_driver_advises_the_implication():
    """gpu_driver=auto is ACCEPTED — the builder implies --gpu-driver nvidia — so it warns
    (names the implication), never blocks. Blocking would invent a constraint."""
    blocking, advisory = scope_violations(_cfg(nvidia_cuda=True, gpu_driver="auto"))
    assert blocking == []
    assert len(advisory) == 1 and "imply" in advisory[0].lower()


def test_cuda_with_nvidia_driver_is_silent():
    assert scope_violations(_cfg(nvidia_cuda=True, gpu_driver="nvidia")) == ([], [])


def test_cuda_false_is_silent_under_any_driver():
    for gd in ("auto", "amd-free", "nvidia", "intel-free"):
        assert scope_violations(_cfg(nvidia_cuda=False, gpu_driver=gd)) == ([], [])


def test_cuda_rule_is_x86_only():
    # rpi5 has no CUDA path; the rule must not fire off-platform (rpi5 can't set the pair
    # in practice, but guard against a future ARM CUDA field inventing a false block).
    cfg = ImageConfig(platform="rpi5", role="desktop", mode="mesh", env="test")
    cfg.nvidia_cuda = True
    cfg.gpu_driver = "amd-free"
    blocking, _ = scope_violations(cfg)
    assert all("nvidia_cuda" not in b for b in blocking)


def test_rpi5_standalone_on_a_node_blocks_because_the_builder_hard_errors():
    """build-rpi5-stage4.sh:1037 errs and exits 1 — a real post-dispatch dead-end, so this
    is the one shape that earns a BLOCK. Same field, same value, different platform: the
    tier follows builder truth, not the field."""
    blocking, advisory = scope_violations(_cfg(platform="rpi5", role="backend", standalone=True))
    assert advisory == []
    assert len(blocking) == 1
    assert "hard-errors" in blocking[0]


def test_standalone_on_a_desktop_is_silent_in_every_mode():
    """The posture's whole point. Nothing here may fire for a config that was already
    valid — a warning that cries wolf on the normal case is worse than none."""
    for mode, role in (("standalone", "standalone-thick"), ("cloud", "desktop")):
        assert scope_violations(_cfg(mode=mode, role=role, standalone=True)) == ([], [])


def test_standalone_false_is_silent_on_a_node():
    assert scope_violations(_cfg(standalone=False)) == ([], [])


def test_bundle_source_default_is_a_leak_not_a_violation():
    """THE LEAK/EXPLICIT BOUNDARY. bundle_source is out of scope on a node AND defaults to
    True, so a node config trivially carries an out-of-scope value. It must stay silent:
    nobody asked for it, so it is finding 4/5's resolve, not a warning to nag about."""
    cfg = _cfg()
    assert cfg.bundle_source is True
    assert not field_in_scope("bundle_source", cfg)      # genuinely out of scope
    assert scope_violations(cfg) == ([], [])             # ...and deliberately not reported


# ── finding 6: egress VPN scope ─────────────────────────────────────────────────────────
def test_egress_vpn_is_desktop_class_only():
    """Mirrors build-x86-host-stage4.sh:3061's own ROLE_CLIENT gate."""
    assert not field_in_scope("egress_vpn", _cfg())
    assert not field_in_scope("egress_vpn_locked", _cfg())


def test_egress_vpn_stays_in_scope_for_desktops_in_every_mode():
    """The builder gates egress on ROLE_CLIENT ALONE — not on mode — so a cloud or
    standalone desktop must keep the option. Narrowing modes here would invent a
    constraint the builder does not have."""
    for mode, role in (("cloud", "desktop"), ("standalone", "standalone-thick"),
                       ("mesh", "desktop")):
        assert field_in_scope("egress_vpn", _cfg(mode=mode, role=role)), (mode, role)


# ── finding 8: the login unlock factor ──────────────────────────────────────────────────
def test_login_factor_is_desktop_only_per_the_builder():
    """Pins the rule _sync_unlock_choices implements to the reason it exists: the builder
    writes the login marker only inside its ROLE_CLIENT branch (:3174-3175)."""
    assert image_class("mesh", "backend") == "node"
    assert image_class("cloud", "desktop") == "desktop"


# ── the BLOCK tier is pinned to build-rpi5's OWN ROLE_CLIENT ────────────────────────────
def _rpi5_builder_text() -> str:
    with open(os.path.join(GENERATOR_DIR, "build-rpi5-stage4.sh"), encoding="utf-8") as fh:
        return fh.read()


def test_rpi5_hard_error_declaration_matches_the_real_builder():
    """_STANDALONE_NODE_HARD_ERROR_PLATFORMS says "rpi5 errs". If that stops being true the
    BLOCK becomes an INVENTED constraint — the one thing the tier design forbids. So parse
    the real script rather than trusting the comment.

    Comment-stripped: build-rpi5 discusses --standalone in prose right above the check, so
    an unstripped search matches the commentary and passes while pinning nothing (#380's
    log-guard hole)."""
    body = "\n".join(re.sub(r"(^|\s)#.*$", "", ln) for ln in _rpi5_builder_text().splitlines())
    assert re.search(r'\$\{ROLE_CLIENT\}\s*\|\|\s*\{\s*err\s+"--standalone only composes onto',
                     body), \
        ("build-rpi5 no longer hard-errors on --standalone + a node role — the BLOCK tier in "
         "scope_violations() is now inventing a constraint the builder does not have. "
         "Re-tier it to WARN.")


def test_block_tier_matches_rpi5_role_client_for_every_role():
    """THE CORRESPONDENCE, in both directions and across the whole role space: we BLOCK
    exactly the roles build-rpi5 would hard-error on, and no others. build-rpi5:998 sets
    ROLE_CLIENT=true for its `desktop` arm ALONE — notably NOT for `generic`, which is a
    standalone-ish rpi5 server but still cluster-node class (G16). A false BLOCK there would
    break a legitimate build, so it is pinned rather than reasoned about.

    SWEEPS MODE because the builder's rule has NO mode term (:1037 gates on ROLE_CLIENT
    alone), so the correspondence must hold in every mode. Honest scope note: this sweep is
    defence-in-depth, NOT the guard that catches a mode narrowing. scope_violations() reads
    class_axis_violated(), which ignores the mode axis BY CONSTRUCTION, so this test cannot
    observe one — mutation-verified: re-adding modes=(standalone, cloud) to FIELD_SCOPE
    ["standalone"] leaves this file at 10 passed. What the sweep does buy is that the BLOCK
    tier can never GROW a mode term without failing.

    The predicate a mode narrowing actually damages is field_in_scope() — the wizard's gate,
    which hides the checkbox and (home.py:363, the sole writer of cfg.standalone) force-
    clears the value. That is pinned by
    test_gui_gate_matches_rpi5_role_client_in_every_mode below, which IS mutation-proven to
    bite on the exact regression this branch shipped and took back."""
    body = _rpi5_builder_text()
    client_arms = set(re.findall(r"^\s*(\w[\w-]*)\)\s+ROLE_CLIENT=true", body, re.M))
    assert client_arms == {"desktop"}, f"build-rpi5's ROLE_CLIENT arms changed: {client_arms}"
    checked = 0
    for mode in ALL_MODES:
        for role in sorted(roles_for_platform("rpi5")):
            try:
                cfg = ImageConfig(platform="rpi5", role=role, mode=mode, env="test")
            except Exception:
                continue          # cell the config model itself rejects (cf. jetson --encrypt-root)
            cfg.standalone = True
            blocking, _ = scope_violations(cfg)
            builder_errs = RPI5_ROLE_MAP.get(role, role) not in client_arms
            assert bool(blocking) == builder_errs, (
                f"mode={mode} role={role}: builder_hard_errors={builder_errs} but "
                f"we_block={bool(blocking)} — studio and build-rpi5 disagree about "
                "--standalone. build-rpi5:1037 gates on ROLE_CLIENT ONLY: no mode term, no "
                "platform term. If studio blocks where the builder does not, studio is "
                "inventing a constraint.")
            checked += 1
    assert checked >= len(ALL_MODES), f"sweep collapsed to {checked} cells — fixture rotted"


def test_gui_gate_matches_rpi5_role_client_in_every_mode():
    """THE GUI-GATE CORRESPONDENCE: field_in_scope("standalone") must agree with build-rpi5's
    OWN ROLE_CLIENT rule, in every mode — because on rpi5 the builder's :1037 gate is the
    whole truth about whether --standalone composes, and it has no mode term.

    WHY THIS EXISTS AS A SEPARATE GUARD. The block-tier correspondence above cannot see a
    mode narrowing (scope_violations reads class_axis_violated, which drops the mode axis by
    construction), and test_field_scope's composition test only re-states FIELD_SCOPE's own
    axes back to itself — a tautology that passes for ANY declared scope. So nothing pinned
    the WIZARD's gate to builder truth, and a mode narrowing slipped in: modes=(standalone,
    cloud) on `standalone` hid the FDE checkbox for mesh + rpi5-desktop, a combination the
    builder accepts and ROLE_CHOICES documents ("compose with --standalone for FDE, no
    mesh"). Worse than a hidden row: home.py:363 is the SOLE writer of cfg.standalone and
    reads `isChecked() and scope_allows(...)`, so an operator loading a saved mesh
    rpi5-desktop FDE config had --standalone silently dropped — a non-FDE image where an
    encrypted one was asked for, exit 0. Silent wrong image: the exact bug class this branch
    exists to eliminate.

    field_in_scope is the Qt-free twin of _gating.scope_allows (pinned equal in
    test_field_scope.py), so asserting it here covers the wizard without a Qt import."""
    body = _rpi5_builder_text()
    client_arms = set(re.findall(r"^\s*(\w[\w-]*)\)\s+ROLE_CLIENT=true", body, re.M))
    assert client_arms == {"desktop"}, f"build-rpi5's ROLE_CLIENT arms changed: {client_arms}"
    for mode in ALL_MODES:
        for role in sorted(roles_for_platform("rpi5")):
            try:
                cfg = ImageConfig(platform="rpi5", role=role, mode=mode, env="test")
            except Exception:
                continue
            builder_composes = RPI5_ROLE_MAP.get(role, role) in client_arms
            assert field_in_scope("standalone", cfg) is builder_composes, (
                f"mode={mode} role={role}: build-rpi5 composes --standalone="
                f"{builder_composes} (ROLE_CLIENT arms {sorted(client_arms)}, :1037) but the "
                f"wizard gate says in_scope={field_in_scope('standalone', cfg)}. A gate "
                "STRICTER than the builder hides a legitimate option AND force-clears it at "
                "home.py:363 — a silently non-FDE image. Do not narrow `standalone` on an "
                "axis build-rpi5 does not gate on (it gates on ROLE_CLIENT only: no mode).")
