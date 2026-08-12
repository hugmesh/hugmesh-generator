"""The LOCAL mesh's services catalogue — Qt-free.

Pins the four things a services picker can get wrong in a way no one notices until a
bring-up has already happened:

  1. OFFERING WHAT CANNOT RUN. Every slug the catalogue offers must have a real
     mechanism in THIS repo's tests/stack tree — a compose `profiles:` tag for the
     profile half, a running (unprofiled) container for the federation half. A slug
     with neither is a checkbox that changes no bytes.
  2. DRIFT. The mechanism facts are mirrored from files that own them
     (specs/cluster/optional-services.yaml, tests/stack/compose*.yaml, the Makefile),
     so this file re-parses those and asserts agreement rather than trusting a comment.
  3. DEFAULTS. An untouched picker must produce the exact env a bring-up produced
     before the picker existed.
  4. THE TWO MECHANISMS being conflated — a profile slug leaking into the federation
     env pair, or vice versa.

No Qt import anywhere on this path (core/local_services.py is core, and
tests/test_headless.py's census would catch a regression from the other direction).
"""
import os
import re

from hugmesh_studio.core import local_services as ls
from hugmesh_studio.core.config import SERVICE_DESCRIPTIONS, SERVICE_GROUPS

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
REGISTRY = os.path.join(GENERATOR_DIR, "specs", "cluster", "optional-services.yaml")
COMPOSE_LOCAL = os.path.join(GENERATOR_DIR, "tests", "stack", "compose.local.yaml")
COMPOSE_SOCIAL = os.path.join(GENERATOR_DIR, "tests", "stack",
                              "compose.social-profile.yaml")
MAKEFILE = os.path.join(GENERATOR_DIR, "Makefile")


def _read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _registry():
    """slug -> {"default_on": bool, "module": str|None} parsed out of the ONE registry
    that declares the platform's optional services. Deliberately a small regex walk
    rather than a YAML dependency: Studio ships none, and the three keys read here
    (`- slug:`, `default:`, `federationModule:`) are single-line and stable."""
    text = _read(REGISTRY)
    out = {}
    slug = None
    for line in text.splitlines():
        m = re.match(r"^\s{4}- slug:\s*(\S+)", line)
        if m:
            slug = m.group(1)
            out[slug] = {"default_on": False, "module": None}
            continue
        if slug is None:
            continue
        m = re.match(r"^\s{6}default:\s*(on|off)\b", line)
        if m:
            out[slug]["default_on"] = (m.group(1) == "on")
            continue
        m = re.match(r"^\s{6}federationModule:\s*\{\s*slug:\s*([A-Za-z0-9-]+)", line)
        if m:
            out[slug]["module"] = m.group(1)
            continue
        if re.match(r"^\s{6}federationModule:\s*$", line):
            out[slug]["module"] = "<block>"      # filled by the indented slug below
            continue
        m = re.match(r"^\s{8}slug:\s*([A-Za-z0-9-]+)", line)
        if m and out[slug]["module"] == "<block>":
            out[slug]["module"] = m.group(1)
    return out


# ── 1. nothing is offered that the local stack cannot run ───────────────────────
def test_every_offered_slug_has_a_real_local_mechanism():
    for svc in ls.LOCAL_SERVICES:
        assert svc.mechanism in (ls.MECH_COMPOSE_PROFILE, ls.MECH_FEDERATION)
        if svc.is_profile():
            assert svc.profile and not svc.module
        else:
            assert svc.module and not svc.profile


def test_profile_slugs_name_a_profile_compose_actually_declares():
    """`social` and `tor` are the only two compose profiles in the local stack — the
    Makefile turns each into a `--profile` flag off one env var. A third profile slug
    would be a toggle nothing consumes."""
    mk = _read(MAKEFILE)
    local = _read(COMPOSE_LOCAL)
    social = _read(COMPOSE_SOCIAL)
    assert "STACK_PROFILE := $(if $(strip $(SOCIAL)),--profile social,)" in mk
    assert "STACK_TOR_PROFILE := $(if $(strip $(TOR)),--profile tor,)" in mk
    profiles = {s.profile for s in ls.LOCAL_SERVICES if s.is_profile()}
    assert profiles == {ls.PROFILE_SOCIAL, ls.PROFILE_TOR}
    assert 'profiles: ["tor"]' in local
    assert "social" in social and "profiles:" in social


def test_federation_slugs_have_containers_in_the_local_stack():
    """The federation half only makes sense for services whose containers the local
    stack ACTUALLY runs — the flip is a registry row on a running mesh, not a way to
    conjure a service that was never composed."""
    local = _read(COMPOSE_LOCAL)
    for svc in ls.LOCAL_SERVICES:
        if not svc.is_federation():
            continue
        assert f"hugmesh-{svc.slug}-ui:" in local or \
               f"hugmesh-{svc.slug}-bff-api:" in local, svc.slug


def test_unavailable_slugs_are_never_also_offered_and_always_say_why():
    assert not (set(ls.UNAVAILABLE_LOCALLY) & set(ls.local_slugs()))
    for slug, why in ls.UNAVAILABLE_LOCALLY.items():
        assert len(why) > 30, slug          # a reason, not a shrug


def test_every_shared_catalogue_slug_is_accounted_for():
    """A slug the node wizard offers must be either runnable here or explicitly
    unavailable-with-a-reason. Silently dropping one is how `wiki` and friends became
    invisible in the first place."""
    shared = {slug for _t, slugs in SERVICE_GROUPS for slug in slugs}
    known = set(ls.local_slugs()) | set(ls.UNAVAILABLE_LOCALLY)
    assert shared - known == set()


# ── 2. drift probes against the files that own these facts ──────────────────────
def test_federation_module_slugs_match_the_registry():
    reg = _registry()
    for svc in ls.LOCAL_SERVICES:
        if svc.is_federation() and svc.slug in reg and reg[svc.slug]["module"]:
            assert svc.module == reg[svc.slug]["module"], svc.slug


def test_federation_defaults_match_the_registry_default_policy():
    reg = _registry()
    for svc in ls.LOCAL_SERVICES:
        if svc.is_federation() and svc.slug in reg:
            assert svc.default_on == reg[svc.slug]["default_on"], svc.slug


def test_the_social_profile_default_deviates_from_the_registry_deliberately():
    """tuwunel is `default: on` in the cluster registry but OFF here: the local social
    tier is six heavy containers and docs/LOCAL-STACK.md calls it opt-in, which is also
    what LocalMeshBootstrapConfig.social has always defaulted to. Pinned so the
    deviation stays a decision rather than becoming an accident."""
    reg = _registry()
    assert reg["tuwunel"]["default_on"] is True
    assert ls.by_slug("tuwunel").default_on is False


def test_descriptions_are_reused_from_the_shared_catalogue():
    for slug in ls.local_slugs():
        shared = SERVICE_DESCRIPTIONS.get(slug)
        if shared:
            assert ls.describe(slug).startswith(shared)
    # the one slug the shared catalogue does not carry still gets a line
    assert "wiki" not in SERVICE_DESCRIPTIONS
    assert ls.describe("wiki")


def test_grouping_follows_the_shared_group_order():
    titles = [t for t, _ in ls.local_groups()]
    assert titles == [t for t, _ in SERVICE_GROUPS if t in titles]
    rows = [s for _t, slugs in ls.local_groups() for s in slugs]
    assert set(rows) == set(ls.local_slugs()) | set(ls.UNAVAILABLE_LOCALLY)
    assert len(rows) == len(set(rows))       # no slug rendered twice


# ── 3. defaults: an untouched picker changes nothing ────────────────────────────
def test_shipped_defaults_are_all_off():
    """Every local row is off in the shipped stack: the two profiles are opt-in, and
    the federation rows this mesh can reach are all DEFAULT-OFF in the registry."""
    assert ls.default_selection() == ()


def test_federation_env_is_empty_for_untouched_and_for_the_shipped_selection():
    assert ls.federation_env(None) == {}
    assert ls.federation_env(()) == {}
    assert ls.federation_env(ls.default_selection()) == {}
    # a profile-only selection is still no federation change
    assert ls.federation_env(("tuwunel", "tor")) == {}


# ── 4. the two mechanisms stay apart ────────────────────────────────────────────
def test_profile_flags_read_only_the_profile_half():
    assert ls.profile_flags(None) == {ls.PROFILE_SOCIAL: False, ls.PROFILE_TOR: False}
    assert ls.profile_flags(("wiki", "tube")) == {ls.PROFILE_SOCIAL: False,
                                                  ls.PROFILE_TOR: False}
    assert ls.profile_flags(("tuwunel",))[ls.PROFILE_SOCIAL] is True
    assert ls.profile_flags(("tor",))[ls.PROFILE_TOR] is True


def test_federation_env_exports_both_sides_as_module_slugs():
    env = ls.federation_env(("tuwunel", "wiki", "tube"))
    on = env[ls.FEDERATION_ENABLE_ENV].split()
    off = env[ls.FEDERATION_DISABLE_ENV].split()
    assert on == ["wiki", "tube"]                     # catalogue order, modules only
    assert "tuwunel" not in on and "tuwunel" not in off   # profile half never leaks
    assert set(off) == set(ls.federation_modules(ls.federation_slugs())) - set(on)


def test_federation_selection_is_catalogue_ordered():
    assert ls.federation_selection(("tube", "wiki")) == ("wiki", "tube")


def test_validate_refuses_unavailable_and_unknown_slugs_with_a_reason():
    assert ls.validate_selection(None) == []
    assert ls.validate_selection(ls.local_slugs()) == []
    problems = ls.validate_selection(("games",))
    assert len(problems) == 1 and "games" in problems[0] and "local" in problems[0]
    problems = ls.validate_selection(("nope",))
    assert len(problems) == 1 and "unknown" in problems[0]
