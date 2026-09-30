"""Which services a LOCAL Docker mesh can turn on, and HOW each one is applied.

The node builders have ONE services axis (`--optional-services`: a slug is baked into
the image or it is not). The local mesh surface has THREE — two the docker lane can
actually drive, plus one that belongs to a DIFFERENT lane entirely and is therefore
shown but never offered as a toggle. They behave nothing alike, which is exactly why
this module exists instead of a bare slug list:

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

  * DEVOPS-LANE services (``MECH_KIND``). Kubernetes controllers. The docker-compose
    lane structurally cannot drive them, so they are catalogued as INFORMATIONAL rows,
    not selectable ones: ``local_slugs()`` (the selectable set) excludes them,
    ``catalogue_slugs()`` (the rows to render) includes them, and
    ``validate_selection`` refuses one with the lane it actually needs. They exist in
    the catalogue at all so the surface can say "this is real, here is where it lives"
    instead of leaving the operator to conclude the mesh has no GitOps.

Because the second mechanism is a DB row on an already-running stack, it is applied at
SEED time, not at up time, and it is carried on the same env channel every other stack
knob rides (see ``federation_env``) — never a new file format.

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
# DEVOPS-LANE services (``MECH_KIND``). These are KUBERNETES controllers: they
# reconcile cluster objects, so the docker-compose lane has nothing for them to
# operate on and no compose profile could ever make them real (the same honesty
# rule that kept workloadConsole greyed). They run on the repo's OWN local
# Kubernetes lane — `make kind-up` (specs/cluster/bootstrap/kind-local), which
# installs real ArgoCD — so the Studio offers them as a SEPARATE lane rather
# than pretending a compose profile exists (operator ask 2026-08-14: "ArgoCD and
# all devops should be an option to enable with local mesh").
#
# A kind row is therefore INFORMATIONAL on the local-mesh surface — a row that
# says where the service lives, with NO checkbox. Rendering a live checkbox for it
# (as this page did until 2026-08-14) is the exact failure this module exists to
# prevent, one layer up: the box ticked, and profile_flags/federation_env/plan()
# all correctly ignored it, so the operator "enabled ArgoCD" and nothing anywhere
# changed. The honest row is the same idiom UNAVAILABLE_LOCALLY uses; the only
# difference is that this one points at a lane that WORKS rather than at a refusal.
MECH_KIND = "kind"

# The DevOps lane's entry points, spelled ONCE so the mechanism column, the
# describe() line, the plan preview and the CLI refusal cannot drift into four
# different names for one button.
KIND_LANE_TARGET = "make kind-up"
KIND_LANE_BUTTON = "Start DevOps lane (Kubernetes)"
KIND_LANE_LABEL = f"DevOps lane ({KIND_LANE_TARGET})"
# Worded to be true on BOTH surfaces it appears on — the greyed table row and the
# CLI's refusal of `--services argocd` — so neither has to keep its own copy.
KIND_LANE_HINT = (
    f"NOT started by this bring-up: run `{KIND_LANE_TARGET}`, or press "
    f"'{KIND_LANE_BUTTON}' on the local-mesh page — either one creates the local "
    f"Kubernetes cluster and installs it for you.")

# The compose profiles tests/stack/ defines, each turned into a `--profile` flag by
# one Makefile variable off one env knob. Named so the GUI can say WHICH profile a
# row drives without restating the mapping.
#   social -> STACK_PROFILE      (SOCIAL=1)
#   tor    -> STACK_TOR_PROFILE  (TOR=1)
#   phpbb  -> STACK_ALT_PROFILE  (PHPBB=1)
#   akkoma -> STACK_ALT_PROFILE  (AKKOMA=1)
#   anubis -> STACK_ALT_PROFILE  (ANUBIS=1)
PROFILE_SOCIAL = "social"
PROFILE_TOR = "tor"
PROFILE_PHPBB = "phpbb"
PROFILE_AKKOMA = "akkoma"
#   games  -> STACK_GAMES_PROFILE (GAMES=1): the hugmesh-games wasm-fragment
#   asset tier from tests/stack/compose.games.yaml.
PROFILE_GAMES = "games"
PROFILE_ANUBIS = "anubis"
#   edge-ai-tts -> STACK_BRAND_B_PROFILE line (TTS=1): built FROM SOURCE from
#   specs/cluster/manifests/edge-ai-tts/image — the pinned registry coordinates
#   do not resolve off-mesh, and the container build is the repo's own pending
#   spike, so the first TTS=1 bring-up IS that spike.
PROFILE_EDGE_AI_TTS = "edge-ai-tts"
#   media-poisoner -> the AI MEDIA CLOAK worker (POISONER=1). Built FROM SOURCE
#   from specs/cluster/manifests/media-poisoner/worker.
PROFILE_MEDIA_POISONER = "media-poisoner"
#   egress-vpn -> STACK_EGRESS_FLAGS (EGRESS_VPN=1 + EGRESS_VPN_CONF=<abs path>):
#   the fail-closed VPN client from tests/stack/compose.egress-vpn.yaml routing
#   mastodon-sidekiq's federation egress. The conf (WireGuard .conf or OpenVPN
#   .ovpn) comes from the page's file popup — core.egress_conf validates it with
#   the same sniff rules the container entrypoint applies.
PROFILE_EGRESS_VPN = "egress-vpn"

# ── the seeder contract for the federation half ─────────────────────────────────
# CONSUMED by tests/stack/seed-e2e.sh leg 4 (added 2026-08-14) — it reads both vars
# verbatim, UPDATEs federation_modules in the compose federation-db, and reads the
# registry back. Until that leg existed these five checkboxes did nothing: the vars
# were exported and nothing consumed them, so ticking one changed nothing while
# owncast/tube/character-forge sat enabled=false, running but absent from the menu.
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

    def is_kind(self) -> bool:
        return self.mechanism == MECH_KIND

    def is_selectable(self) -> bool:
        """Whether a CHECKBOX for this row would drive anything. False for the
        DevOps lane: no compose profile and no registry row exist to flip, so a
        box there could only ever do nothing."""
        return self.is_profile() or self.is_federation()

    def mechanism_label(self) -> str:
        """The "How it is applied" column, derived HERE rather than restated at the
        surface. This exists because the surface's version was a TWO-way branch over
        THREE mechanisms: `--profile x` if is_profile() else `federation: <module>`,
        which labelled both kind rows "federation: " with an empty module. A
        three-valued fact belongs in the module that owns the three values."""
        if self.is_profile():
            return f"--profile {self.profile}"
        if self.is_federation():
            return f"federation: {self.module}"
        return KIND_LANE_LABEL


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
        slug="phpbb", mechanism=MECH_COMPOSE_PROFILE, profile=PROFILE_PHPBB,
        # Registry says `default: on`; OFF here for the same reason tuwunel is —
        # a from-scratch bring-up should not silently grow containers. The row is
        # a real toggle now: it was in UNAVAILABLE_LOCALLY ("NO phpBB backend —
        # nothing to enable"), which stopped being true when the phpbb profile
        # landed in tests/stack/compose.alt-social.yaml.
        default_on=False,
        local_note="phpBB 3.3 + its own Postgres, built from the official release "
                   "(pinned by sha256) and installed unattended on first run. Serves "
                   "on :8081 and at /social/phpbb/ behind the gateway. Needs a stack "
                   "restart to change — it starts/stops containers."),
    LocalService(
        slug="akkoma", mechanism=MECH_COMPOSE_PROFILE, profile=PROFILE_AKKOMA,
        # Same deviation from the registry's `default: on`. Previously listed as
        # unavailable ("the local social profile ships MASTODON, not Akkoma") —
        # true until the akkoma profile landed; Akkoma now runs ALONGSIDE Mastodon
        # rather than replacing it, so both can be exercised in one stack.
        default_on=False,
        local_note="Akkoma (Pleroma fork, same ActivityPub + Mastodon-client API) "
                   "+ its own Postgres, on :4001. Independent of the social profile, "
                   "so it can run beside Mastodon. Needs a stack restart to change."),
    LocalService(
        slug="anubis", mechanism=MECH_COMPOSE_PROFILE, profile=PROFILE_ANUBIS,
        # Matches the registry's `default: off` / envConditional test:off — the
        # local stack IS the test env, so no deviation note is needed here.
        default_on=False,
        local_note="Techaro Anubis (pinned upstream image) as a SECOND published "
                   "front door on :8923: the PoW challenge fronts the same "
                   "fe-gateway the direct :8088/:8488 doors hit, mirroring the "
                   "cluster's ingress-through-Anubis wiring. Browsers solve a "
                   "one-time JS proof-of-work; non-browser agents pass through. "
                   "Needs a stack restart to change — it starts/stops a container."),
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
    LocalService(
        slug="edge-ai-tts", mechanism=MECH_COMPOSE_PROFILE, profile=PROFILE_EDGE_AI_TTS,
        default_on=False,
        local_note="BUILT FROM SOURCE (specs/cluster/manifests/edge-ai-tts/image) — "
                   "the pinned registry image does not resolve off-mesh, and the "
                   "container build is the repo's own pending spike: the first "
                   "TTS=1 bring-up IS that spike and may surface build gaps. "
                   "Consumers keep their __HUG_VOICE_TTS__ flag dark until wired. "
                   "Needs a stack restart to change."),
    LocalService(
        slug="media-poisoner", mechanism=MECH_COMPOSE_PROFILE,
        profile=PROFILE_MEDIA_POISONER,
        default_on=False,
        local_note="THE AI MEDIA CLOAK. Poisons an opted-in image before it is "
                   "ingested by the homeserver, so a scraped copy degrades a "
                   "training run. The UI (user preferences 'AI media cloak') and "
                   "the whole BFF media-proxy already shipped; what was missing "
                   "locally was the WORKER, which existed only as a MANUAL-sync "
                   "cluster Application — so the control rendered permanently "
                   "unavailable no matter how many AI services were enabled "
                   "(operator report 2026-08-14). Enabling this starts the worker "
                   "AND flips the BFF's media.poisoning.enabled, which is off by default; "
                   "either half alone leaves the control greyed. BUILT FROM SOURCE "
                   "(specs/cluster/manifests/media-poisoner/worker). CPU-ONLY here: "
                   "the default image is the lean Pillow baseline with no torch, so "
                   "/health reports device 'cpu' and the cloak is the "
                   "reduced-strength tier, NOT the GPU PGD one. Needs a stack "
                   "restart to change."),
    LocalService(
        slug="games", mechanism=MECH_COMPOSE_PROFILE, profile=PROFILE_GAMES,
        # Registry agreement: optional-services.yaml ships games `default: off`,
        # so unlike tuwunel/phpbb/akkoma this is NOT a local deviation.
        default_on=False,
        local_note="LOCAL SUBSET: one nginx (the hugmesh-games wasm-fragment "
                   "asset tier) serving the committed Godot WASM bundles at "
                   "/_remotes/wasm-fragment/<slug>/ behind the front door — "
                   "shadows-of-the-net included. The games portal, app store, "
                   "games admin and the second (games-realm) Casdoor stay "
                   "ABSENT locally; /games remains the host shell's guarded "
                   "placeholder. Needs a hugmesh-games checkout next to this "
                   "repo (GAMES_SRC overrides). Needs a stack restart to "
                   "change — it starts/stops a container."),
    # ── the DEVOPS lane (MECH_KIND): real Kubernetes, not a compose profile ──
    LocalService(
        slug="argocd", mechanism=MECH_KIND,
        default_on=False,
        local_note="Runs on the DevOps (Kubernetes) "
                   "lane, not the docker lane: ArgoCD reconciles cluster objects, "
                   "so there is nothing for it to manage without Kubernetes. "
                   "Starting that lane installs the real upstream ArgoCD and "
                   "applies this mesh's app tree."),
    LocalService(
        slug="workloadConsole", mechanism=MECH_KIND,
        default_on=False,
        # Graduated out of UNAVAILABLE_LOCALLY (operator ask 2026-08-14): its
        # backend driver is the fabric8 k8s client and no docker driver exists,
        # which is exactly what the DevOps lane supplies. The compose lane still
        # cannot run it — that is now stated as a LANE, not a refusal.
        local_note="Pod console + workload inspection. Runs on the DevOps "
                   "(Kubernetes) lane: its only backend driver is the Kubernetes "
                   "API, so the docker lane has nothing to show it."),
    LocalService(
        slug="egress-vpn", mechanism=MECH_COMPOSE_PROFILE, profile=PROFILE_EGRESS_VPN,
        default_on=False,
        # Graduated from UNAVAILABLE_LOCALLY (operator ask 2026-08-14): the page
        # now carries the conf-path channel — checking the box pops a file picker
        # and the box cannot stay checked without a valid conf (fail-closed at
        # the surface, mirroring the container's own refusal).
        local_note="Routes Mastodon's federation traffic through your own VPN. "
                   "Checking this asks for your VPN provider's WireGuard (.conf) "
                   "or OpenVPN (.ovpn) file. Needs a stack restart to change."),
)

# Slugs the shared catalogue carries that the LOCAL docker stack cannot run, each with
# the reason the surface shows. Offering these as live toggles is the exact failure this
# module exists to prevent: a checkbox that changes no bytes.
# Reasons are ONE lay-user sentence (operator ask 2026-08-14: "just say disabled
# and clean up language"): the row's visible text is "Disabled" + this sentence.
# Technical whys live here as comments, not on the surface.
# EMPTY as of 2026-08-14: every catalogued slug now has a real lane. The map and
# its honesty contract STAY — a future slug the local mesh genuinely cannot run
# belongs here with one lay sentence, never as a live checkbox over a mechanism
# that does not exist. (workloadConsole left this map when the DevOps/kind lane
# gave it the Kubernetes API its only driver needs.)
UNAVAILABLE_LOCALLY: dict[str, str] = {}

# `wiki` is deliberately absent from core.config's catalogues: those mirror the node
# builders' --optional-services slugs, and a test there asserts SERVICE_DESCRIPTIONS
# has no entry outside OPTIONAL_SERVICES_CHOICES + INFRA_SERVICES_CHOICES. Wiki exists
# only as compose services + gateway_route_access rows + a federation module, i.e. it
# is a LOCAL/federation fact, so its one line lives here — the one place that owns it.
# `argocd` is absent from core.config's catalogues for the same reason: it is not a
# node-image --optional-services slug (nothing is baked into a Pi/x86 image for it) —
# it is a cluster-plane controller the DevOps lane installs. It had NO line at all
# until 2026-08-14, so its row rendered with an EMPTY description column next to an
# equally empty mechanism column.
LOCAL_ONLY_DESCRIPTIONS: dict[str, str] = {
    "wiki": "Collaborative wiki — shared pages at /wiki, SSO-linked to mesh accounts.",
    "argocd": "GitOps delivery — ArgoCD keeps the mesh's workloads matching what is "
              "committed in git, and shows every app's sync/health state in its own "
              "web UI.",
}

# Where a local-only slug lands in the SHARED grouping (core.config.SERVICE_GROUPS).
# A wiki is a shared-authorship community surface, so it joins that group rather than
# earning a one-row group of its own — which would make the local services surface
# grouped differently from the node wizard's for no operator gain.
LOCAL_ONLY_GROUP: dict[str, str] = {"wiki": "Social & Community",
                                    "argocd": "Network & Access"}


# ── the DevOps lane's OWN selection channel (operator ask 2026-08-26) ───────────
# The MECH_KIND rows above are informational because the docker lane structurally
# cannot drive a Kubernetes controller. That is still true — and it left a second,
# quieter hole: the DevOps lane could not drive one EITHER. `make kind-up` passed
# KIND_PROFILE and MFA and nothing else, so the curated Application set in
# specs/cluster/bootstrap/kind-local/bootstrap-kind.sh could only be changed by
# editing that file. specs/cluster/apps/01-metrics-server.yaml therefore sat in no
# profile while KIND_PROFILE=sso deployed SEVEN HorizontalPodAutoscalers with no
# resource-metrics API to read — HPAs that report `<unknown>/70%` forever and look
# exactly like an idle cluster.
#
# These rows are a THIRD axis, deliberately kept out of LOCAL_SERVICES: they are
# not compose profiles, not federation rows, and not the docker mesh's business at
# all. Mixing them into `local_slugs()` would put a Kubernetes-only selection into
# the compose bring-up's `--services` list, which is the lane confusion this whole
# module exists to prevent.
MECH_KIND_ADDON = "kind-addon"

# The env var bootstrap-kind.sh reads, spelled ONCE. Its `none` sentinel is not
# decoration: an EMPTY value is read by the script as UNSET (falling back to its own
# default), because empty is what every layer in between produces by accident.
KIND_ADDONS_ENV = "KIND_ADDONS"
KIND_ADDONS_NONE = "none"


@dataclass(frozen=True)
class KindAddon:
    """One infra Application the DevOps lane can be asked to add to its curated set.

    ``slug`` is the KIND_ADDONS token, verbatim — bootstrap-kind.sh's KIND_ADDON_MAP
    is the authority for what a slug maps to, and this side never re-derives it.
    ``default_on`` mirrors that script's KIND_ADDONS_DEFAULT (asserted by
    tests/scripts/test-kind-addon-channel.sh, which reads both)."""
    slug: str
    default_on: bool
    label: str
    note: str


KIND_ADDONS: tuple[KindAddon, ...] = (
    KindAddon(
        slug="metrics-server", default_on=True,
        label="Resource metrics (metrics-server)",
        note="The cluster's CPU/memory metrics API. DEFAULT ON, and not a nicety: "
             "the DevOps lane already deploys seven HorizontalPodAutoscalers "
             "(admin-bff, user-bff, the host shell and four UI remotes) that read "
             "it. Without it they report <unknown> forever and hold their "
             "Deployments at the replicas floor — nothing reports that as a "
             "failure. Also what makes `kubectl top` answer."),
    KindAddon(
        slug="keda", default_on=False,
        label="Event-driven autoscaling (KEDA)",
        note="Installs the KEDA operator (no ScaledObjects — the repo ships none "
             "that this lane can run). Substrate for latency/queue-driven scaling; "
             "the CPU/memory HPAs above do not need it."),
)


def kind_addon_slugs() -> tuple[str, ...]:
    """Every DevOps-lane add-on slug, in catalogue order."""
    return tuple(a.slug for a in KIND_ADDONS)


def kind_addon_by_slug(slug: str) -> KindAddon | None:
    for a in KIND_ADDONS:
        if a.slug == slug:
            return a
    return None


def kind_addon_default_selection() -> tuple[str, ...]:
    """What `make kind-up` applies with no selection at all — the state the
    checkboxes must start in, or the surface lies about the lane it describes."""
    return tuple(a.slug for a in KIND_ADDONS if a.default_on)


def validate_kind_addons(selection: Sequence[str] | None) -> list[str]:
    """Problems with a DevOps-lane add-on selection (empty list = OK).

    An unknown slug is REFUSED, never dropped: bootstrap-kind.sh's own parse is
    fail-closed for the same reason, and a slug that vanishes silently between the
    picker and the script is a selection channel that lies."""
    if selection is None:
        return []
    problems: list[str] = []
    for slug in selection:
        if kind_addon_by_slug(slug) is None:
            problems.append(
                f"unknown DevOps-lane add-on '{slug}' — the lane knows "
                f"{', '.join(kind_addon_slugs())}.")
    return problems


def kind_addon_env(selection: Sequence[str] | None) -> dict[str, str]:
    """The env `make kind-up` needs to apply ``selection``, or {}.

    Returns {} — i.e. changes NOTHING about the subprocess env — in the two cases
    where there is genuinely nothing to say: ``selection is None`` (no picker was
    used) and a selection that already equals what the lane ships. Same invariant
    ``federation_env`` holds: an operator who touches nothing gets the same env,
    byte for byte, as before this axis existed.

    An EMPTY selection is exported as the literal ``none``, NOT as an empty string.
    That distinction is the whole safety property of this channel: bootstrap-kind.sh
    reads an empty KIND_ADDONS as UNSET and falls back to its default, so exporting
    "" for "the operator unticked everything" would silently turn metrics-server
    back ON while the surface said it was off.

    Raises ValueError on an unknown slug — fail closed rather than export a
    selection the script will refuse halfway through a bring-up."""
    if selection is None:
        return {}
    problems = validate_kind_addons(selection)
    if problems:
        raise ValueError("; ".join(problems))
    chosen = tuple(a.slug for a in KIND_ADDONS if a.slug in set(selection))
    if set(chosen) == set(kind_addon_default_selection()):
        return {}
    return {KIND_ADDONS_ENV: ",".join(chosen) if chosen else KIND_ADDONS_NONE}


# ── catalogue accessors ─────────────────────────────────────────────────────────
def by_slug(slug: str) -> LocalService | None:
    """The catalogue entry for ``slug``, or None when the local stack cannot run it
    (whether it is a known-unavailable slug or not a slug at all)."""
    for svc in LOCAL_SERVICES:
        if svc.slug == slug:
            return svc
    return None


def local_slugs() -> tuple[str, ...]:
    """Every slug the local mesh can genuinely TOGGLE, in catalogue order — i.e. the
    set a selection may contain and the set that gets one checkbox each.

    Deliberately NOT every catalogued row: the DevOps-lane rows are rendered
    (``catalogue_slugs``) but not selectable, because no compose profile and no
    registry row exists for them to flip. Keeping them out here is what makes the
    surface's `service_boxes[slug]` sweep and the CLI's `--services` help list agree
    with what actually happens."""
    return tuple(s.slug for s in LOCAL_SERVICES if s.is_selectable())


def catalogue_slugs() -> tuple[str, ...]:
    """Every row the surface RENDERS, selectable or not, in catalogue order."""
    return tuple(s.slug for s in LOCAL_SERVICES)


def profile_slugs() -> tuple[str, ...]:
    return tuple(s.slug for s in LOCAL_SERVICES if s.is_profile())


def federation_slugs() -> tuple[str, ...]:
    return tuple(s.slug for s in LOCAL_SERVICES if s.is_federation())


def kind_slugs() -> tuple[str, ...]:
    """The DevOps-lane rows, in catalogue order. Informational everywhere the local
    docker mesh is concerned — the plan preview lists them so the confirm-before-run
    manifest is COMPLETE (it describes every row the operator was shown), marked as
    the separate lane they are rather than silently omitted."""
    return tuple(s.slug for s in LOCAL_SERVICES if s.is_kind())


def default_selection() -> tuple[str, ...]:
    """What the SHIPPED local stack runs with no selection at all. The checkbox surface
    starts in exactly this state, and ``federation_env`` treats a selection equal to it
    as "nothing to do" — which is what keeps an untouched bring-up byte-identical."""
    return tuple(s.slug for s in LOCAL_SERVICES if s.default_on)


def describe(slug: str) -> str:
    """The one-line "what enabling it does", plus the local-stack note when the row has
    one. The shared half is IMPORTED from core.config — never restated here.

    A DevOps-lane row additionally carries ``KIND_LANE_HINT``, because "what enabling
    it does" has no answer on this page for those two: the honest line has to name the
    button that DOES enable them, or a row with no checkbox reads as a dead end."""
    base = SERVICE_DESCRIPTIONS.get(slug) or LOCAL_ONLY_DESCRIPTIONS.get(slug, "")
    svc = by_slug(slug)
    if svc is None:
        return base
    parts = [base, svc.local_note]
    if svc.is_kind():
        parts.append(KIND_LANE_HINT)
    return " ".join(p for p in parts if p).strip()


def local_groups() -> tuple[tuple[str, tuple[str, ...]], ...]:
    """(group title, slugs) for the local services surface, in core.config's
    SERVICE_GROUPS order — every shared slug this module has an opinion about (runnable
    OR explicitly unavailable) plus the local-only ones. Groups with no rows are
    dropped, so one loop renders the whole surface and adding a slug to either table
    above is the only edit a new service needs.

    Built from ``catalogue_slugs`` (every row), NOT ``local_slugs`` (the selectable
    ones): the DevOps-lane rows are shown, they just carry no checkbox."""
    known = set(catalogue_slugs()) | set(UNAVAILABLE_LOCALLY)
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
    would let a CLI caller believe they enabled something that never existed.

    That is exactly why a DevOps-lane slug is refused here too. The GUI cannot
    produce one (those rows have no checkbox), but `--services argocd` on the CLI
    used to sail through validation and then vanish: profile_flags() ignored it,
    federation_env() ignored it, plan() never mentioned it, and the bring-up ran
    without a word. The refusal names the lane that DOES install it."""
    if selection is None:
        return []
    problems: list[str] = []
    for slug in selection:
        svc = by_slug(slug)
        if svc is not None and svc.is_selectable():
            continue
        if svc is not None:            # catalogued, but not on this lane
            problems.append(
                f"service '{slug}' is not part of the local docker mesh — it runs on "
                f"the DevOps (Kubernetes) lane. {KIND_LANE_HINT}")
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
