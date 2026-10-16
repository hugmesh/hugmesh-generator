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
COMPOSE_ALT = os.path.join(GENERATOR_DIR, "tests", "stack",
                           "compose.alt-social.yaml")
COMPOSE_POISONER = os.path.join(GENERATOR_DIR, "tests", "stack",
                                "compose.media-poisoner.yaml")
MAKEFILE = os.path.join(GENERATOR_DIR, "Makefile")


def _read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _compose_down_line(mk, target):
    """The single `$(COMPOSE_CMD) … down…` recipe line of a Makefile target.

    Returned stripped of its leading tab and trailing whitespace so a caller can
    assert on the VERB it ends with and on the flags it carries, without pinning
    where an unrelated variable happens to sit in between."""
    recipe, seen = [], False
    for ln in mk.splitlines():
        if ln.startswith(f"{target}:"):
            seen = True
            continue
        if seen:
            if ln.startswith("\t"):
                recipe.append(ln[1:].rstrip())
            elif ln.strip() and not ln.startswith("#"):
                break                       # next target: recipe is over
    assert seen, f"Makefile has no `{target}:` target"
    hits = [ln for ln in recipe if "$(COMPOSE_CMD)" in ln and " down" in ln]
    assert len(hits) == 1, f"{target}: expected exactly one compose down line, got {hits}"
    return hits[0]


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
        assert svc.mechanism in (ls.MECH_COMPOSE_PROFILE, ls.MECH_FEDERATION,
                                 ls.MECH_KIND)
        if svc.is_profile():
            assert svc.profile and not svc.module
        elif svc.is_federation():
            assert svc.module and not svc.profile
        else:
            # DEVOPS lane (MECH_KIND): a Kubernetes controller. It names neither
            # a compose profile nor a federation module — `make kind-up` IS its
            # mechanism, so asserting either field would invent a mapping.
            #
            # THIS ASSERTION ALONE ONCE HID THE BUG IT LOOKS LIKE IT GUARDS. Empty
            # profile + empty module is what the DATA should look like; it says
            # nothing about whether the SURFACE offers a checkbox over that
            # emptiness, which is exactly what it was doing (a live box labelled
            # "federation: " with no module, driving nothing). So the emptiness is
            # asserted together with the two facts that make it honest: the row is
            # NOT selectable, and it still names a mechanism a human can act on.
            assert svc.is_kind() and not svc.profile and not svc.module
            assert not svc.is_selectable(), svc.slug
            assert svc.mechanism_label() == ls.KIND_LANE_LABEL
            assert ls.KIND_LANE_TARGET in svc.mechanism_label()


def test_kind_rows_are_informational_not_inert_checkboxes():
    """The DEFECT this pins: `argocd` and `workloadConsole` rendered live checkboxes
    that changed nothing — profile_flags() dropped them, federation_env() dropped
    them, plan() never mentioned them, and validate_selection() waved them through.

    An informational row has to survive four separate checks, because the old bug
    passed three of them: it must be excluded from the selectable set, included in
    the rendered set, carry a non-empty mechanism label AND a description that names
    where the thing actually lives."""
    assert set(ls.kind_slugs()) == {"argocd", "workloadConsole"}
    for slug in ls.kind_slugs():
        svc = ls.by_slug(slug)
        # 1. not selectable — no checkbox may be built for it
        assert slug not in ls.local_slugs(), slug
        assert not svc.is_selectable(), slug
        # 2. still rendered — an unreachable service the operator never hears about
        #    is how "does this mesh even have GitOps?" gets asked in the first place
        assert slug in ls.catalogue_slugs(), slug
        rows = [s for _t, slugs in ls.local_groups() for s in slugs]
        assert slug in rows, slug
        # 3. the mechanism column is the LANE, never an empty "federation: "
        label = svc.mechanism_label()
        assert label == ls.KIND_LANE_LABEL and "federation" not in label
        # 4. the description exists and points at the lane that installs it
        desc = ls.describe(slug)
        assert len(desc) > 60, slug              # a line, not a blank cell
        assert ls.KIND_LANE_BUTTON in desc, slug
        assert ls.KIND_LANE_TARGET in desc, slug


def test_kind_slugs_are_refused_from_a_selection_with_the_lane_that_runs_them():
    """The GUI can no longer produce a kind slug (no checkbox exists), but the CLI
    can: `--services argocd` used to validate clean and then evaporate. A refusal
    that names the lane is the only answer that is not a lie."""
    problems = ls.validate_selection(("argocd",))
    assert len(problems) == 1
    assert "argocd" in problems[0]
    assert ls.KIND_LANE_TARGET in problems[0]
    assert ls.KIND_LANE_BUTTON in problems[0]
    # …and it does not get mistaken for an unknown slug
    assert "unknown" not in problems[0]
    assert ls.validate_selection(ls.kind_slugs()) != []


def test_kind_lane_rows_name_the_make_target_that_runs_them():
    """The DevOps lane must be backed by a REAL target, or the rows lie exactly
    like a compose profile nothing consumes would."""
    mk = _read(MAKEFILE)
    assert "kind-up:" in mk and "bootstrap-kind.sh" in mk
    assert "kind-down:" in mk
    assert set(ls.kind_slugs()) == {"argocd", "workloadConsole"}
    # the mechanism column's text must be the target a human can actually run
    assert ls.KIND_LANE_TARGET == "make kind-up"
    assert "kind-up:" in mk
    # and the bootstrap really installs ArgoCD (not a placeholder)
    boot = _read(os.path.join(
        GENERATOR_DIR, "specs", "cluster", "bootstrap", "kind-local",
        "bootstrap-kind.sh"))
    assert "argo-cd" in boot and "argocd-repo-server" in boot


def test_profile_slugs_name_a_profile_compose_actually_declares():
    """Every profile slug must name a compose profile the Makefile actually turns into
    a `--profile` flag — a slug nothing consumes would be a toggle that lies.

    `phpbb` and `akkoma` joined `social`/`tor` when tests/stack/compose.alt-social.yaml
    landed; both were previously in UNAVAILABLE_LOCALLY ("no phpBB backend" / "ships
    MASTODON, not Akkoma"), which stopped being true then. They share ONE Makefile
    variable (STACK_ALT_PROFILE) because they stack additively with SOCIAL."""
    mk = _read(MAKEFILE)
    local = _read(COMPOSE_LOCAL)
    social = _read(COMPOSE_SOCIAL)
    alt = _read(COMPOSE_ALT)
    assert "STACK_PROFILE := $(if $(strip $(SOCIAL)),--profile social,)" in mk
    assert "STACK_TOR_PROFILE := $(if $(strip $(TOR)),--profile tor,)" in mk
    assert "$(if $(strip $(PHPBB)),--profile phpbb,)" in mk
    assert "$(if $(strip $(AKKOMA)),--profile akkoma,)" in mk
    assert "$(if $(strip $(ANUBIS)),--profile anubis,)" in mk
    assert "$(if $(strip $(POISONER)),--profile media-poisoner,)" in mk
    assert "$(if $(strip $(EGRESS_VPN)),-f $(STACK_EGRESS_COMPOSE) --profile egress-vpn,)" in mk
    profiles = {s.profile for s in ls.LOCAL_SERVICES if s.is_profile()}
    assert profiles == {ls.PROFILE_SOCIAL, ls.PROFILE_TOR, ls.PROFILE_PHPBB,
                        ls.PROFILE_AKKOMA, ls.PROFILE_ANUBIS,
                        ls.PROFILE_GAMES, ls.PROFILE_EDGE_AI_TTS,
                        ls.PROFILE_MEDIA_POISONER,
                        ls.PROFILE_EGRESS_VPN}
    assert 'profiles: ["tor"]' in local
    assert 'profiles: ["media-poisoner"]' in _read(COMPOSE_POISONER)
    assert 'profiles: ["anubis"]' in local
    assert "social" in social and "profiles:" in social
    assert 'profiles: ["phpbb"]' in alt and 'profiles: ["akkoma"]' in alt
    # `down`/`clean` must reap these even when the knob that started them is not
    # repeated, so EVERY profile is listed on the down path as a LITERAL
    # `--profile <slug>` — never behind the $(if $(strip $(KNOB)),…) guard the up
    # path uses, or `make stack-down` leaves containers the previous `up` started
    # orphaned while reporting success.
    #
    # Asserted per down-target instead of as one contiguous string. The previous
    # form was a single `"--profile anubis … --profile egress-vpn down -v" in mk`
    # literal; the per-domain Casdoor lane (85d2a605) spliced
    # $(STACK_OWN_CASDOOR_DOWN_FLAGS) between the last profile and the verb, so the
    # INVARIANT still held and only the byte order moved — and the test then sat on
    # tests/known-failures.txt gating nothing while it was the reap rule, not the
    # spelling, that mattered. Pin the rule.
    for target, verb in (("stack-halt", "down"),
                         ("stack-down", "down -v"),
                         ("stack-clean", "down -v --rmi local --remove-orphans")):
        line = _compose_down_line(mk, target)
        assert line.endswith(verb), f"{target}: expected the recipe to end `{verb}`: {line!r}"
        for slug in ("social", "tor", "anubis", "phpbb", "akkoma", "games",
                     "brandb", "edge-ai-tts", "media-poisoner", "egress-vpn"):
            assert f"--profile {slug}" in line, \
                f"{target} does not unconditionally reap --profile {slug}: {line!r}"


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
    assert not (set(ls.UNAVAILABLE_LOCALLY) & set(ls.catalogue_slugs()))
    for slug, why in ls.UNAVAILABLE_LOCALLY.items():
        assert len(why) > 30, slug          # a reason, not a shrug


def test_every_shared_catalogue_slug_is_accounted_for():
    """A slug the node wizard offers must be either runnable here or explicitly
    unavailable-with-a-reason. Silently dropping one is how `wiki` and friends became
    invisible in the first place."""
    shared = {slug for _t, slugs in SERVICE_GROUPS for slug in slugs}
    known = set(ls.catalogue_slugs()) | set(ls.UNAVAILABLE_LOCALLY)
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
    for slug in ls.catalogue_slugs():
        shared = SERVICE_DESCRIPTIONS.get(slug)
        if shared:
            assert ls.describe(slug).startswith(shared)
    # the slugs the shared catalogue does not carry still get a line. `argocd` had
    # NEITHER a SERVICE_DESCRIPTIONS nor a LOCAL_ONLY_DESCRIPTIONS entry until
    # 2026-08-14, so its row rendered with an empty description column — swept under
    # the rug by a loop that only walked slugs which happened to have one.
    for slug in ("wiki", "argocd"):
        assert slug not in SERVICE_DESCRIPTIONS, slug
        assert slug in ls.LOCAL_ONLY_DESCRIPTIONS, slug


def test_every_rendered_row_has_a_description():
    """EVERY row the surface draws, not just the selectable ones — a blank
    description column is how a row stops explaining itself."""
    for slug in ls.catalogue_slugs():
        assert len(ls.describe(slug)) > 40, slug


def test_grouping_follows_the_shared_group_order():
    titles = [t for t, _ in ls.local_groups()]
    assert titles == [t for t, _ in SERVICE_GROUPS if t in titles]
    rows = [s for _t, slugs in ls.local_groups() for s in slugs]
    assert set(rows) == set(ls.catalogue_slugs()) | set(ls.UNAVAILABLE_LOCALLY)
    assert len(rows) == len(set(rows))       # no slug rendered twice
    # the selectable set is a strict subset of the rendered set: rendering is what
    # the operator SEES, selecting is what the bring-up can DO, and conflating the
    # two is what put a live checkbox on a Kubernetes controller.
    assert set(ls.local_slugs()) < set(rows)


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
    # Derived from the catalogue, so it covers every profile slug rather than a
    # hardcoded pair — `phpbb` and `akkoma` joined `social`/`tor` with
    # compose.alt-social.yaml, and a hardcoded set silently goes stale when one is added.
    all_off = {s.profile: False for s in ls.LOCAL_SERVICES if s.is_profile()}
    assert set(all_off) == {ls.PROFILE_SOCIAL, ls.PROFILE_TOR, ls.PROFILE_PHPBB,
                            ls.PROFILE_AKKOMA, ls.PROFILE_ANUBIS,
                            ls.PROFILE_GAMES, ls.PROFILE_EDGE_AI_TTS,
                            ls.PROFILE_MEDIA_POISONER,
                            ls.PROFILE_EGRESS_VPN}
    assert ls.profile_flags(None) == all_off
    assert ls.profile_flags(("wiki", "tube")) == all_off
    assert ls.profile_flags(("tuwunel",))[ls.PROFILE_SOCIAL] is True
    assert ls.profile_flags(("tor",))[ls.PROFILE_TOR] is True
    assert ls.profile_flags(("phpbb",))[ls.PROFILE_PHPBB] is True
    assert ls.profile_flags(("akkoma",))[ls.PROFILE_AKKOMA] is True
    # the two mechanisms stay apart: a profile pick is never a federation flip
    assert ls.federation_env(("phpbb", "akkoma")) == {}


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
    # UNAVAILABLE_LOCALLY is EMPTY as of 2026-08-14 — every catalogued slug has a
    # lane (workloadConsole moved onto the DevOps/kind lane, which supplies the
    # Kubernetes API its only driver needs). The refusal contract still holds for
    # an unknown slug, and the map stays for a future genuinely-unrunnable one.
    assert ls.UNAVAILABLE_LOCALLY == {}
    problems = ls.validate_selection(("nope",))
    assert len(problems) == 1 and "unknown" in problems[0]


# ── 6. the DevOps (Kubernetes) lane ─────────────────────────────────────────────
def test_kind_rows_are_neither_compose_nor_federation():
    """The lane is a THIRD mechanism, not a compose profile in disguise: a kind
    row must never leak into profile_flags() (which would invent a `--profile`
    flag) nor into federation_selection() (which would flip a registry row)."""
    sel = ("argocd", "workloadConsole", "tuwunel", "wiki")
    assert "argocd" not in ls.profile_flags(sel)
    assert "workloadConsole" not in ls.profile_flags(sel)
    assert ls.federation_selection(sel) == ("wiki",)
    # …and BECAUSE both back-ends drop them, a selection containing one must be
    # refused rather than accepted-and-ignored. `== []` here was the assertion that
    # blessed the checkbox that did nothing: it certified "this selection is fine" for a
    # selection every consumer then threw away.
    problems = ls.validate_selection(sel)
    assert len(problems) == 2
    assert {"argocd", "workloadConsole"} == {
        p.split("'")[1] for p in problems}


def test_kind_lane_slugs_are_shown_and_never_default_on():
    for slug in ("argocd", "workloadConsole"):
        svc = ls.by_slug(slug)
        assert svc is not None and svc.is_kind()
        assert svc.default_on is False
        assert "Kubernetes" in svc.local_note
        # SHOWN (catalogue_slugs), not OFFERED (local_slugs). The old spelling of
        # this line asserted `slug in ls.local_slugs()` — i.e. that the row was
        # selectable — which is the defect, not the contract. It also only ever
        # ran on the loop's last value, since it sat outside the loop body.
        assert slug in ls.catalogue_slugs()
        assert slug not in ls.local_slugs()
        assert slug not in ls.default_selection()
