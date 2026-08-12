"""Which services a LOCAL Docker mesh can turn on, and HOW each one is applied.

The node builders have ONE services axis (`--optional-services`: a slug is baked into
the image or it is not). The local docker mesh has TWO, and they behave nothing alike —
which is exactly why this module exists instead of a bare slug list:

  * COMPOSE-PROFILE services (``MECH_COMPOSE_PROFILE``). The slug maps to a compose
    ``profiles:`` tag, driven by an env var LocalStackNode exports and the Makefile
    turns into a ``--profile <name>`` flag (Makefile:1252-1253). Turning one on or off
    STARTS or STOPS containers, so it only takes effect at bring-up: changing it on a
    running mesh means a `make stack-down` + `stack-up`. The local compose stack has
    exactly TWO profiles — `social` (tests/stack/compose.social-profile.yaml tags six
    services: tuwunel + the five Mastodon ones) and `tor` (compose.local.yaml's single
    hugmesh-tor service). There is no third one, and inventing a slug here that no
    ``profiles:`` key backs would produce a checkbox that silently does nothing.

  * FEDERATION-ENABLED services (``MECH_FEDERATION``). Their containers are
    UNCONDITIONAL in compose.local.yaml — wiki/owncast/tube/character-forge carry no
    ``profiles:`` key at all, so they are always built and always started. What decides
    whether the operator SEES them is the ``enabled`` column of their
    ``federation_modules`` registry row (docs/FEDERATION-EXAMPLES.md:135-137): the host
    shell resolves its remotes from federation at runtime, so flipping that column
    flips the menu entry between live and greyed WITH NO container restart. Several
    ship enabled=false (specs/cluster/optional-services.yaml's DEFAULT-OFF policy),
    which is the whole reason the operator could not reach them: they were running and
    invisible, with no UI to turn them on.

Because the second mechanism is a DB row on an already-running stack, it is applied at
SEED time, not at up time, and it is carried on the same env channel every other stack
knob rides (see ``federation_env`` + the TODO below) — never a new file format.

A service the local stack simply cannot run is NOT offered: ``UNAVAILABLE_LOCALLY``
names it with the concrete reason instead, so the surface can show a greyed row that
explains itself rather than a live toggle that lies (the same honesty idiom as the
disabled "render locally" card on the local-mesh page).

Qt-free by contract: this file is catalogue + derivation only. The guard is
tests/test_local_mesh_bootstrap.py::test_module_imports_no_qt, which imports
local_mesh_bootstrap in a FRESH interpreter and therefore covers this module
transitively — local_mesh_bootstrap imports it. (test_headless.py's census only walks
the --print-command path and never reaches here, so it is not the guard.)
Labels, one-line descriptions and the presentation grouping are
IMPORTED from core.config — the node wizard's services table and this one must never
drift into two spellings of the same catalogue.
"""
from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

from .config import SERVICE_DESCRIPTIONS, SERVICE_GROUPS

# ── the two mechanisms, as values rather than an is-it-tor special case ──────────
MECH_COMPOSE_PROFILE = "compose-profile"
MECH_FEDERATION = "federation"

# The ONLY two compose profiles tests/stack/ defines (Makefile:1252-1253 ->
# STACK_PROFILE / STACK_TOR_PROFILE). Named so the GUI can say WHICH profile a row
# drives without restating the mapping.
PROFILE_SOCIAL = "social"
PROFILE_TOR = "tor"

# ── the seeder contract for the federation half ─────────────────────────────────
# TODO(tests/stack/seed-e2e.sh): the seeder does not read these yet — another agent
# owns that file this pass, so this side ships the values and the contract, and the
# GUI/plan say the flip is PENDING rather than claiming it happened.
#
# CONTRACT (both vars, or neither):
#   HUGMESH_FEDERATION_ENABLE  — space-separated federation_modules.slug values to
#                                UPDATE ... SET enabled = true
#   HUGMESH_FEDERATION_DISABLE — space-separated slugs to SET enabled = false
# Both are exported by LocalStackNode._build_env() ONLY when the operator's selection
# differs from what the registry ships (see ``federation_env``), so an untouched
# bring-up's env stays byte-identical and the seeder keeps its current behaviour.
# The target DB is the compose `federation-db` service (database/user/password
# `federation`, compose.local.yaml:556-561). Slugs are federation MODULE slugs, which
# are NOT always the catalogue slug — phpbb's module is `forum` — so the seeder must
# use these values verbatim and never re-derive them.
FEDERATION_ENABLE_ENV = "HUGMESH_FEDERATION_ENABLE"
FEDERATION_DISABLE_ENV = "HUGMESH_FEDERATION_DISABLE"


@dataclass(frozen=True)
class LocalService:
    """One service the LOCAL mesh can genuinely turn on, and the mechanism that does it.

    ``slug`` is the catalogue slug (a core.config.SERVICE_DESCRIPTIONS key wherever one
    exists) so a row here and a row on the node wizard's services table are the same
    service under the same name. ``profile`` is set for MECH_COMPOSE_PROFILE only,
    ``module`` (the federation_modules.slug) for MECH_FEDERATION only."""
    slug: str
    mechanism: str
    profile: str = ""
    module: str = ""
    # What the SHIPPED stack does with no selection at all — the state the checkbox
    # must start in, or the surface lies about the mesh it is describing.
    default_on: bool = False
    # Local-stack truth the cluster-wide description cannot carry (e.g. that one
    # profile brings up two services). Appended to the description, never replacing it.
    local_note: str = ""

    def is_profile(self) -> bool:
        return self.mechanism == MECH_COMPOSE_PROFILE

    def is_federation(self) -> bool:
        return self.mechanism == MECH_FEDERATION


# The catalogue. Every entry is backed by a mechanism that exists in THIS repo's
# tests/stack tree — a slug with no backing mechanism belongs in UNAVAILABLE_LOCALLY.
# default_on mirrors specs/cluster/optional-services.yaml's per-slug `default: on|off`
# (tests/test_local_services.py parses that registry and asserts the two agree), with
# ONE deliberate local deviation, called out on the row itself.
LOCAL_SERVICES: tuple[LocalService, ...] = (
    LocalService(
        slug="tuwunel", mechanism=MECH_COMPOSE_PROFILE, profile=PROFILE_SOCIAL,
        # DELIBERATE local deviation from the registry's `default: on`: the local
        # social tier is SIX containers (tuwunel + Mastodon web/sidekiq/streaming/
        # db/redis) and docs/LOCAL-STACK.md calls it "heavy + opt-in". The existing
        # LocalMeshBootstrapConfig.social has always defaulted False; flipping that
        # here would silently make every from-scratch bring-up much slower.
        default_on=False,
        local_note="ONE compose profile brings up the whole social tier: Matrix "
                   "(tuwunel) AND the Mastodon services. Needs a stack restart to "
                   "change — it starts/stops containers."),
    LocalService(
        slug="tor", mechanism=MECH_COMPOSE_PROFILE, profile=PROFILE_TOR,
        default_on=False,
        local_note="Starts hugmesh-tor and publishes the fe-gateway as a v3 .onion. "
                   "Needs a stack restart to change."),
    LocalService(
        slug="wiki", mechanism=MECH_FEDERATION, module="wiki", default_on=False,
        local_note="Containers are always up (hugmesh-wiki-bff-api + hugmesh-wiki-ui "
                   "+ wiki-bff-db carry no compose profile); this flips the menu "
                   "entry, no restart."),
    LocalService(
        slug="owncast", mechanism=MECH_FEDERATION, module="owncast", default_on=False,
        local_note="Containers are always up; this flips the registry row."),
    LocalService(
        slug="tube", mechanism=MECH_FEDERATION, module="tube", default_on=False,
        local_note="Containers are always up; this flips the registry row."),
    LocalService(
        slug="character-studio", mechanism=MECH_FEDERATION, module="character-studio",
        default_on=False,
        local_note="UI container is always up; this flips the registry row."),
    LocalService(
        slug="character-forge", mechanism=MECH_FEDERATION, module="character-forge",
        default_on=False,
        local_note="BFF + db + UI containers are always up; this flips the registry "
                   "row."),
)

# Slugs the shared catalogue carries that the LOCAL docker stack cannot run, each with
# the reason the surface shows. Offering these as live toggles is the exact failure this
# module exists to prevent: a checkbox that changes no bytes.
UNAVAILABLE_LOCALLY: dict[str, str] = {
    "akkoma": "the local social profile ships MASTODON, not Akkoma, and it comes up "
              "with the Matrix (tuwunel) row above — one `social` compose profile, "
              "one switch. There is no separate Akkoma service here.",
    "phpbb": "the local stack builds the forum BFF + UI but NO phpBB backend "
             "(docs/LOCAL-STACK.md, honest limitations) — nothing to enable.",
    "games": "no games service in tests/stack/compose.local.yaml, and the two-Casdoor "
             "games realm is inert locally (docs/LOCAL-STACK.md).",
    "edge-ai-tts": "image/GitOps tier only — no edge-AI service in the local compose "
                   "stack.",
    "egress-vpn": "a NODE-level route (the image's outbound traffic), not something a "
                  "docker compose stack on your workstation can apply.",
    "anubis": "cluster ingress tier — the local front door is the compose gateway, "
              "with no Anubis in front of it.",
    "workloadConsole": "an in-CLUSTER workload console (k8s); the local stack has no "
                       "cluster to inspect.",
}

# `wiki` is deliberately absent from core.config's catalogues: those mirror the node
# builders' --optional-services slugs, and a test there asserts SERVICE_DESCRIPTIONS
# has no entry outside OPTIONAL_SERVICES_CHOICES + INFRA_SERVICES_CHOICES. Wiki exists
# only as compose services + gateway_route_access rows + a federation module, i.e. it
# is a LOCAL/federation fact, so its one line lives here — the one place that owns it.
LOCAL_ONLY_DESCRIPTIONS: dict[str, str] = {
    "wiki": "Collaborative wiki — shared pages at /wiki, SSO-linked to mesh accounts.",
}

# Where a local-only slug lands in the SHARED grouping (core.config.SERVICE_GROUPS).
# A wiki is a shared-authorship community surface, so it joins that group rather than
# earning a one-row group of its own — which would make the local services surface
# grouped differently from the node wizard's for no operator gain.
LOCAL_ONLY_GROUP: dict[str, str] = {"wiki": "Social & community"}


# ── catalogue accessors ─────────────────────────────────────────────────────────
def by_slug(slug: str) -> LocalService | None:
    """The catalogue entry for ``slug``, or None when the local stack cannot run it
    (whether it is a known-unavailable slug or not a slug at all)."""
    for svc in LOCAL_SERVICES:
        if svc.slug == slug:
            return svc
    return None


def local_slugs() -> tuple[str, ...]:
    """Every slug the local mesh can genuinely toggle, in catalogue order."""
    return tuple(s.slug for s in LOCAL_SERVICES)


def profile_slugs() -> tuple[str, ...]:
    return tuple(s.slug for s in LOCAL_SERVICES if s.is_profile())


def federation_slugs() -> tuple[str, ...]:
    return tuple(s.slug for s in LOCAL_SERVICES if s.is_federation())


def default_selection() -> tuple[str, ...]:
    """What the SHIPPED local stack runs with no selection at all. The checkbox surface
    starts in exactly this state, and ``federation_env`` treats a selection equal to it
    as "nothing to do" — which is what keeps an untouched bring-up byte-identical."""
    return tuple(s.slug for s in LOCAL_SERVICES if s.default_on)


def describe(slug: str) -> str:
    """The one-line "what enabling it does", plus the local-stack note when the row has
    one. The shared half is IMPORTED from core.config — never restated here."""
    base = SERVICE_DESCRIPTIONS.get(slug) or LOCAL_ONLY_DESCRIPTIONS.get(slug, "")
    svc = by_slug(slug)
    if svc is not None and svc.local_note:
        return f"{base} {svc.local_note}".strip()
    return base


def local_groups() -> tuple[tuple[str, tuple[str, ...]], ...]:
    """(group title, slugs) for the local services surface, in core.config's
    SERVICE_GROUPS order — every shared slug this module has an opinion about (runnable
    OR explicitly unavailable) plus the local-only ones. Groups with no rows are
    dropped, so one loop renders the whole surface and adding a slug to either table
    above is the only edit a new service needs."""
    known = set(local_slugs()) | set(UNAVAILABLE_LOCALLY)
    out: list[tuple[str, tuple[str, ...]]] = []
    for title, slugs in SERVICE_GROUPS:
        rows = [s for s in slugs if s in known]
        rows += [s for s, g in LOCAL_ONLY_GROUP.items() if g == title]
        if rows:
            out.append((title, tuple(rows)))
    return tuple(out)


# ── selection -> the two back-ends ──────────────────────────────────────────────
def validate_selection(selection: Sequence[str] | None) -> list[str]:
    """Problems with an operator selection (empty list = OK). A slug the local stack
    cannot run is refused WITH ITS REASON rather than silently dropped — dropping it
    would let a CLI caller believe they enabled something that never existed."""
    if selection is None:
        return []
    problems: list[str] = []
    for slug in selection:
        if by_slug(slug) is not None:
            continue
        why = UNAVAILABLE_LOCALLY.get(slug)
        if why:
            problems.append(f"service '{slug}' cannot run on the local docker mesh: "
                            f"{why}")
        else:
            problems.append(f"unknown local service '{slug}' — the local mesh knows "
                            f"{', '.join(local_slugs())}.")
    return problems


def profile_flags(selection: Sequence[str] | None) -> dict[str, bool]:
    """{profile name: on} for the compose half. ``None`` (nothing selected/untouched)
    means every profile off — the shipped default."""
    chosen = set(selection or ())
    return {s.profile: (s.slug in chosen)
            for s in LOCAL_SERVICES if s.is_profile()}


def federation_selection(selection: Sequence[str] | None) -> tuple[str, ...]:
    """The federation-mechanism slugs of ``selection``, in catalogue order."""
    chosen = set(selection or ())
    return tuple(s.slug for s in LOCAL_SERVICES if s.is_federation() and s.slug in chosen)


def federation_modules(slugs: Sequence[str]) -> tuple[str, ...]:
    """Catalogue slugs -> the federation_modules.slug values the registry row is keyed
    by. Not always the same string (phpbb's module is `forum`), which is why the seeder
    is handed these and never asked to derive them."""
    out = []
    for slug in slugs:
        svc = by_slug(slug)
        if svc is not None and svc.is_federation():
            out.append(svc.module)
    return tuple(out)


def federation_env(selection: Sequence[str] | None) -> dict[str, str]:
    """The env pair `make stack-seed` needs to flip federation_modules.enabled, or {}.

    Returns {} — i.e. changes NOTHING about the subprocess env — in the two cases where
    there is genuinely nothing to do: ``selection is None`` (no picker was ever used)
    and a federation half that already matches what the registry ships. That is the
    invariant the build-matrix/env-equality guards rest on: an operator who touches
    nothing gets the same env, byte for byte, as before this field existed.

    Otherwise BOTH vars are exported, because the flip is two-sided: the complement is
    the set that must be turned OFF, and a seeder that only received the ON list could
    not tell "leave it" from "turn it off"."""
    if selection is None:
        return {}
    chosen = federation_selection(selection)
    shipped = tuple(s for s in default_selection() if by_slug(s).is_federation())
    if set(chosen) == set(shipped):
        return {}
    off = tuple(s for s in federation_slugs() if s not in set(chosen))
    return {
        FEDERATION_ENABLE_ENV: " ".join(federation_modules(chosen)),
        FEDERATION_DISABLE_ENV: " ".join(federation_modules(off)),
    }
