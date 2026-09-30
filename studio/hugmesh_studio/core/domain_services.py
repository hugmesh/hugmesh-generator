"""Per-domain service configuration — the Qt-free half (issues #494 / #495).

The operator's ask, verbatim (2026-09-17):

    "make sure that the service configuration is integrated into the domain setup
     instead of its own separate thing. make sure that for each domain, the service
     page needs to be config, so there's basically a service page per domain you make
     you have to go through before building or starting a mesh in docker or nodes"

Two facts this module owns, both deliberately Qt-free so the GUI page, the TUI step
and the build/mesh-start gates cannot disagree about them:

1. **WHICH SLUGS ARE DOMAIN-SCOPED.** ``DOMAIN_CATALOGUE`` is
   ``OPTIONAL_SERVICES_CHOICES`` — exactly what ``--all-services`` expands to, and the
   only slugs whose own ``SERVICE_DESCRIPTIONS`` are ``<domain>``-scoped. The INFRA
   slugs (``INFRA_SERVICES_CHOICES``: tor, egress-vpn, workloadConsole, anubis) are
   node- or cluster-plane scoped and are NOT domain-scoped — ``gui/pages/domains.py``
   has said since #227 that "a per-DOMAIN checkbox for them would be a new lie", and
   that rule survives this change rather than being flattened by it.

2. **WHETHER A DOMAIN HAS BEEN CONFIGURED.** ``ImageConfig.domain_services_reviewed``
   holds the NAMES of the domains whose services page the operator actually went
   through. It is bookkeeping for the gate, not provisioning data: neither mesh
   manifest carries it (``manifest_v2`` emits an explicit key list;
   ``mesh_manifest`` filters it), and it reaches no builder and no argv.

   The distinction matters because ``optional_services == []`` is already MEANINGFUL —
   it is "the cluster-wide set applies" (config.py's emission table), NOT "unset". So
   emptiness cannot stand in for "never configured" and a separate marker is the only
   reading that does not invent a selection for a domain nobody has looked at.

**THE SELECTION IS NOT YET ENFORCED AT THE CLUSTER** — see ``ENFORCEMENT_NOTE`` and
issue #496. Say so wherever the operator will read it. A required page that implies
otherwise is worse than the row button it replaces.
"""
from __future__ import annotations

from typing import Iterable

from .config import (INFRA_SERVICES_CHOICES, OPTIONAL_SERVICES_CHOICES,
                     SERVICE_DESCRIPTIONS, SERVICE_GROUPS, SERVICES_ALL,
                     SERVICES_NONE, superadmin_plane_applies)

__all__ = [
    "SCOPE_DOMAIN", "SCOPE_IMAGE", "SCOPE_NODE", "SCOPE_LABELS", "SCOPE_WHERE",
    "SCOPE_BINDS", "INFRA_WHERE", "OTHER_SCOPE_HEADERS",
    "IMAGE_SCOPE_ROW_LABEL",
    "image_service_state", "node_service_state", "other_scope_rows",
    "DOMAIN_CATALOGUE", "ENFORCEMENT_NOTE",
    "scope_of", "grouped_domain_catalogue", "split_services", "normalise_slugs",
    "carried_over_slugs", "describe", "describe_carried_over",
    "CARRIED_OVER_NOTE", "reviewed_names", "unconfigured_domains",
    "gate_applies", "gate_reason", "record_reviewed", "OWN_DOMAIN_GATED_ACTIONS",
    "implicit_own_domain", "domain_names_for_services", "services_page_applies",
    "services_summary", "domain_summary",
    "restart_gate_reason", "session_boot_gate_reason",
    "ACTION_IMAGE_BUILD", "ACTION_MESH_START", "ACTION_BUILD_RESTART",
    "ACTION_EMULATE", "ACTION_REMEDY",
]

#: The three scopes a service choice can have in this platform (#497). They are NOT
#: interchangeable: a domain-scoped slug binds one domain, an image-scoped one binds
#: every image this build produces, a node-plane one binds a node or the cluster.
SCOPE_DOMAIN = "domain"
SCOPE_IMAGE = "image"
SCOPE_NODE = "node"

SCOPE_LABELS = {
    SCOPE_DOMAIN: "Domain",
    SCOPE_IMAGE: "Image / mesh-wide",
    SCOPE_NODE: "Node / cluster plane",
}

#: scope -> WHERE that choice is made, in words the operator can act on. Issue #497's
#: actual requirement: "the operator can see — without reading source — which of their
#: choices binds the domain, which binds the image, and which binds a node".
SCOPE_WHERE = {
    SCOPE_DOMAIN: "here, once per domain",
    SCOPE_IMAGE: "on the ‘Network & services’ step, once for the whole build",
    SCOPE_NODE: "on the ‘Network & services’ step, and — for the two that have a "
                "per-node spelling — in the worklist’s own Services column",
}

#: PER-SLUG "where", because the four infra slugs do NOT all live in the same place and
#: one shared sentence would be false for two of them. ``tor`` and ``egress-vpn`` are the
#: only genuine per-NODE image services (``core/worklist.WORKLIST_INFRA_SERVICES``);
#: ``workloadConsole`` and ``anubis`` are CLUSTER-plane and have no per-node spelling at
#: all, so telling the operator to look for them in the worklist would send them hunting
#: for a control that does not exist.
INFRA_WHERE = {
    "tor": "the ‘Network & services’ step (mesh-wide), or per node in the worklist’s "
           "own Services column — that runs Tor on the node; whether a DOMAIN gets "
           "its own .onion is that domain's ‘Tor front door’ row",
    "egress-vpn": "the ‘Network & services’ step (mesh-wide), or per node in the "
                  "worklist’s own Services column",
    "workloadConsole": "the ‘Network & services’ step — cluster-plane, it has no "
                       "per-node control",
    "anubis": "the ‘Network & services’ step — cluster-plane, it has no per-node "
              "control",
}

#: scope -> WHAT that choice binds. Kept apart from SCOPE_WHERE because they are two
#: different questions and conflating them is how the scopes got flattened before.
SCOPE_BINDS = {
    SCOPE_DOMAIN: "this domain, and no other",
    SCOPE_IMAGE: "every image this build produces — not one domain",
    SCOPE_NODE: "a node, or the whole cluster — never one domain",
}

#: The read-only "not domain-scoped" table's columns.
OTHER_SCOPE_HEADERS = ("Service", "Scope", "Where it is set", "Right now")

#: The one row standing for the whole image-wide services table, which is a surface
#: rather than a slug and so cannot be listed slug by slug here without duplicating it.
IMAGE_SCOPE_ROW_LABEL = "the services step’s own table"

#: The per-domain catalogue: the user-level cluster slugs, i.e. exactly what
#: ``--all-services`` expands to. Consumed, never copied, so a slug added to the
#: catalogue is offered per domain the same day.
DOMAIN_CATALOGUE: tuple[str, ...] = OPTIONAL_SERVICES_CHOICES

#: The honesty line issue #495 makes non-optional while #496 is open. Shown on the
#: page itself, not in a tooltip: an operator forced through a service page will
#: otherwise reasonably conclude the mesh runs what they chose, and today it does not.
ENFORCEMENT_NOTE = (
    "RECORDED, NOT YET ENFORCED AT THE CLUSTER. This selection is carried in the mesh "
    "manifest as provisioning input. It does NOT yet decide which services the cluster "
    "actually runs: ArgoCD still creates every optional-service Application from the "
    "git tree regardless of what is chosen here — measured, an image built with one "
    "optional service selected boots with all fifteen. Until that is closed, treat "
    "this page as recording your intent, not as switching services off."
)

#: Gate call sites, as the operator sees them. Passed to :func:`gate_reason` so the
#: refusal names the thing that was refused rather than a generic "cannot continue".
ACTION_IMAGE_BUILD = "build these images"
ACTION_MESH_START = "start this mesh"
#: The previous-builds manager's RESTART. Narrower than the other two on purpose —
#: see :func:`restart_gate_reason`.
ACTION_BUILD_RESTART = "restart this build"
#: Booting a PREVIOUS build session's images — Mesh emulation (Start mesh / a device's
#: Start) and the QEMU device tests' "Images from a previous build session" arm, on both
#: faces (#637). Narrow like the restart — see :func:`session_boot_gate_reason`.
ACTION_EMULATE = "boot this build session's images"

#: action -> HOW TO FIX IT FROM WHERE YOU ARE STANDING. Not one shared sentence,
#: because "go back to the Domain services step" is FALSE at both call sites in
#: different ways, and a refusal whose remedy does not work is a dead end with extra
#: words:
#:
#: * on the build screen Qt has already DISABLED Back — the review screen before it is
#:   a commit page (``gui/pages/build.py`` setCommitPage(True)), which is the whole
#:   reason that screen has a "back to the main menu" card at all;
#: * the local-mesh branch is terminal and has no Domains table in it — domains reach
#:   it from the configuration the session is carrying, not from anything on that page.
ACTION_REMEDY = {
    ACTION_IMAGE_BUILD:
        "Use ‘Back to the main menu’ on this screen — nothing has started and your "
        "settings are kept — then walk to the ‘Domain services’ step, where every "
        "domain has its own page. (The Back button is disabled here because the "
        "review screen before it is a commit page.)",
    ACTION_MESH_START:
        "These domains come from the configuration this session is carrying, not from "
        "this screen. Configure them on the ‘Domain services’ step of the image flow "
        "— every domain has its own page there — or drop them from the Domains table.",
    ACTION_BUILD_RESTART:
        "This session's saved configuration names domains it never recorded services "
        "for. Use Redo instead — it loads the same configuration into the wizard, "
        "where the ‘Domain services’ step gives every domain its own page.",
    ACTION_EMULATE:
        "These images were built from a configuration that names domains it never "
        "recorded services for. Open that session in ‘Review prior sessions’ and use "
        "Redo — the wizard's ‘Domain services’ step gives every domain its own page "
        "— then emulate the session that build produces.",
}


#: The actions whose gate covers the mesh's IMPLICIT own domain (:func:`implicit_own_domain`)
#: as well as the Domains-table rows (#631 section 1). ONLY the image build, and on
#: purpose:
#:
#: * the image BUILD is the door where the own domain's page is always reachable — the
#:   own domain gets a services page on EVERY mesh flow (#589, decision 69), and the
#:   refusal's remedy (``ACTION_REMEDY[ACTION_IMAGE_BUILD]``: back to the main menu, walk
#:   to "Domain services") leads straight to it. Before this, a config LOADED on the
#:   Sessions screen whose own-domain page was never opened built anyway, because the
#:   page was enforced only by being unavoidable on a fresh walk;
#: * the docker MESH START (``ACTION_MESH_START``) gates ``wiz.cfg`` too, but that
#:   route is the local-mesh branch: an operator who clicked "Mesh node" and then went
#:   Back into "Local Docker mesh" carries ``mode == "mesh"`` with the default cluster
#:   domain and no walk, and the image flow's own domain does not reach a docker mesh at
#:   all (its own domain is the local-mesh Domains step's row 0). Gating it there would
#:   be a refusal over a page that route cannot show — a dead end;
#: * the previous-builds RESTART (``ACTION_BUILD_RESTART``) re-dispatches a RECORDED
#:   config, and every session recorded before this gate existed — including the
#:   #495-to-#595 window, whose table rows carry markers but whose own domain had no page
#:   yet — would be refused over a question nobody was asked. That is the migration rule
#:   for configs saved before #595: a restart keeps its row-only check
#:   (:func:`restart_gate_reason`), and anything that goes back through the wizard
#:   (Redo, Load config) walks the own domain's page and so records it.
OWN_DOMAIN_GATED_ACTIONS: frozenset[str] = frozenset({ACTION_IMAGE_BUILD})


def scope_of(slug: str) -> str:
    """Which plane ``slug`` binds. Domain-catalogue slugs are domain-scoped; the four
    INFRA slugs are node/cluster-plane; anything else the services surfaces can show
    (media-poisoner, edge-ai-tts, the managed backing services) is image-wide."""
    if slug in DOMAIN_CATALOGUE:
        return SCOPE_DOMAIN
    if slug in INFRA_SERVICES_CHOICES:
        return SCOPE_NODE
    return SCOPE_IMAGE


def grouped_domain_catalogue() -> list[tuple[str, list[str]]]:
    """``[(group title, [slug, ...]), ...]`` — the domain-scoped catalogue in
    SERVICE_GROUPS presentation order, with a trailing "Other services" group for any
    catalogue slug no group lists.

    SERVICE_GROUPS is a PRESENTATION table and DOMAIN_CATALOGUE is the catalogue: a slug
    added to one and not the other would otherwise be silently impossible to offer, which is
    exactly the quiet drop the #227 menu already refused to make. Offer it ungrouped
    instead (a test pins that the two agree today, so this arm is a floor, not a licence
    to skip the grouping)."""
    out: list[tuple[str, list[str]]] = []
    seen: set[str] = set()
    for group, slugs in SERVICE_GROUPS:
        members = [s for s in slugs if s in DOMAIN_CATALOGUE]
        if members:
            out.append((group, members))
            seen.update(members)
    ungrouped = [s for s in DOMAIN_CATALOGUE if s not in seen]
    if ungrouped:
        out.append(("Other services", ungrouped))
    return out


def split_services(services) -> list[str]:
    """Accept either a list of slugs or the legacy space/comma-separated string that
    older callers (and three test files) still pass. Moved here from
    ``gui/pages/domains.py`` so the TUI and the gate read it the same way."""
    if services is None:
        return []
    if isinstance(services, str):
        return services.replace(",", " ").split()
    return [str(x) for x in services]


def normalise_slugs(selected) -> list[str]:
    """``selected`` in CATALOGUE order, with any carried-over extra last, deduped.

    The order comes from the CATALOGUE and deliberately NOT from whatever widget order
    a surface happens to have: ``SERVICE_GROUPS`` and ``DOMAIN_CATALOGUE`` are two
    different constants and they already disagree (the catalogue has games before
    owncast/tube; the media group lists owncast, tube, games). Reading a presentation
    order here would let a purely cosmetic regrouping rewrite the bytes of
    ``domains[].optional_services`` in the mesh manifest.

    NOTE this NORMALISES order: a row loaded with its slugs in some other order reads
    back in catalogue order. ``optional_services`` is an allow-list (the builders join
    it into one ``--optional-services`` string and the manifest key is a set of slugs),
    so order carries no meaning — and a deterministic order is what keeps the manifest
    byte-stable across a load/save round trip."""
    chosen = split_services(selected)
    known = [s for s in DOMAIN_CATALOGUE if s in chosen]
    extra: list[str] = []
    for s in chosen:
        if s not in DOMAIN_CATALOGUE and s not in extra:
            extra.append(s)
    return known + extra


def carried_over_slugs(selected) -> list[str]:
    """The slugs on a loaded row that this build's catalogue does not offer.

    They are kept, offered and pre-checked wherever the selection is edited, so loading
    an older worklist never silently drops manifest data (the #227 rule, unchanged)."""
    return [s for s in normalise_slugs(selected) if s not in DOMAIN_CATALOGUE]


def describe(slug: str) -> str:
    """The catalogue description for ``slug``, or "" when nothing describes it."""
    return SERVICE_DESCRIPTIONS.get(slug, "")


#: What a carried-over slug's row says about ITSELF. Appended to whatever description
#: the slug has rather than replacing it: several carried-over slugs DO have a
#: SERVICE_DESCRIPTIONS entry — every INFRA slug does, and an infra slug typed into the
#: pre-#227 freeform cell is the commonest way one reaches a domain row — so a bare
#: "kept from your config" would have thrown away the one line saying what it is.
CARRIED_OVER_NOTE = (
    "Not in this build's per-domain catalogue; kept from the config you loaded so the "
    "mesh manifest keeps the value you had.")


def describe_carried_over(slug: str) -> str:
    """The description a CARRIED-OVER slug's row shows: what it is (when anything
    says), plus the fact that it came from the loaded config and is being kept."""
    base = describe(slug)
    return (base + "  " + CARRIED_OVER_NOTE) if base else CARRIED_OVER_NOTE


# ── the gate ────────────────────────────────────────────────────────────────────────
def reviewed_names(cfg) -> set[str]:
    """The domain NAMES whose services page has actually been gone through.

    STRIPPED here, at the one place the config is read, so a hand-edited config carrying
    ``" acme.example "`` still satisfies the gate for ``acme.example`` instead of
    wedging it for ever (``unconfigured_domains`` compares the stripped name)."""
    return {str(n).strip()
            for n in (getattr(cfg, "domain_services_reviewed", None) or [])}


def gate_applies(cfg) -> bool:
    """Whether the per-domain gate can bite for this config at all.

    It exists so the gate's predicate and the page's ``applies_to`` cannot disagree in
    the one direction that matters: **the gate must never refuse a flow that does not
    CONTAIN the step**, because that is a dead end — a refusal naming a screen the
    operator has no route to. Two flows are exactly that, and in both the domains reach
    nothing at all:

    * ``standalone`` — ``MODE_SKIPPED_PAGES`` skips the step outright,
      ``ModePage.validatePage`` clears ``cfg.domains`` on the transition into it, and
      ``to_cli_args`` emits no ``--domains``;
    * a cloud **node** role — ``to_cli_args`` emits ``--domains`` only when
      ``role not in X86_NODE_ROLES`` and cloud writes no mesh manifest, which is the
      same reason ``superadmin_plane_applies`` skips the tables there.

    The MESH arm of ``superadmin_plane_applies`` is deliberately NOT mirrored. That arm
    also asks ``cfg.additional_domains``, and a config that carries domains with the
    opt-in off is one whose domains ``NetworkPage.validatePage`` has not cleared *yet* —
    on the docker mesh-start path that page may never run at all, so deferring to it
    there would turn a loaded config's domains into a set nothing can refuse. It is not
    a dead end either: walking the image flow reaches the step (tick the opt-in) or
    clears the rows, and both outcomes satisfy the gate.
    """
    mode = getattr(cfg, "mode", "") or ""
    if mode == "standalone":
        return False
    if mode == "cloud":
        # exactly the cloud arm: False for a node role, True for a client image.
        return superadmin_plane_applies(cfg)
    return True


def unconfigured_domains(cfg, include_own: bool = False) -> list[str]:
    """The named domains on ``cfg`` with no recorded service configuration, in table
    order. A row with an empty name is not a domain yet (the Domains table drops those
    at validatePage) and is never reported. Empty whenever :func:`gate_applies` is
    False.

    ``include_own`` adds the mesh's IMPLICIT own domain (:func:`implicit_own_domain`),
    FIRST — the walk order — when its page has not been gone through. Only
    :func:`gate_reason` sets it, and only for ``OWN_DOMAIN_GATED_ACTIONS`` (see there
    for why the image build and nothing else). It is a READ of the reviewed marker and
    nothing more: the own domain stays implicit, never a ``cfg.domains`` row, so an
    untouched flow still emits no ``--domains`` and no manifest ``domains`` entry.

    STRICTER THAN THE WORKLIST, on purpose: a mesh worklist filters ``base.domains``
    per entry by ``Domain.images`` (``worklist.entry_config``), and this does not — a
    domain attached to NO selected image still has to be configured before the build
    runs. Fail-closed: the alternative is a domain that is in the config, rides the
    mesh manifest on the next entry that does claim it, and was never asked about."""
    if not gate_applies(cfg):
        return []
    done = reviewed_names(cfg)
    out: list[str] = []
    if include_own:
        own = implicit_own_domain(cfg)
        if own and own not in done:
            out.append(own)
    for d in getattr(cfg, "domains", None) or []:
        name = (getattr(d, "name", "") or "").strip()
        if name and name not in done and name not in out:
            out.append(name)
    return out


def gate_reason(cfg, action: str = ACTION_IMAGE_BUILD, remedy: str | None = None) -> str:
    """"" when ``action`` may proceed; otherwise the refusal, naming every domain.

    ``remedy`` overrides the ``ACTION_REMEDY`` sentence for a route whose steps have
    different names — the generate-a-new-local-mesh route (``core/local_mesh_domains.
    LOCAL_MESH_REMEDY``) has its own Domains / Domain services steps, and a refusal
    that sends the operator to "the image flow" from there is a dead end.

    THE OVERRIDE POINT. Every gate calls exactly this — the image build at
    ``gui/pages/launch.py``, BOTH docker mesh-start doors at ``gui/pages/localmesh.py``
    (``_bootstrap_up`` and ``_start_saved``), and, through
    :func:`restart_gate_reason`, the previous-builds RESTART at
    ``gui/pages/sessions_widget.py`` — and a test can drive it with a bare ImageConfig,
    no Qt, no wizard, no build, no docker. On ``ACTION_IMAGE_BUILD`` it also covers the
    mesh's implicit OWN domain (``OWN_DOMAIN_GATED_ACTIONS``, #631), exactly as it covers
    a table row: no reviewed marker, refused by name. Everywhere else it reads the
    table rows only. Naming the domains is the point: "configure your domains" is a
    message that scrolls past, "acme.example has no recorded service configuration" is
    one the operator can act on."""
    missing = unconfigured_domains(
        cfg, include_own=action in OWN_DOMAIN_GATED_ACTIONS)
    if not missing:
        return ""
    plural = "s" if len(missing) > 1 else ""
    remedy = remedy or ACTION_REMEDY.get(action)
    return (
        f"Cannot {action}: {len(missing)} domain{plural} ha{'ve' if plural else 's'} "
        f"no recorded service configuration — " + ", ".join(missing) + ". "
        + (remedy or "Go through each one on the ‘Domain services’ step — every "
                     "domain has its own page there.")
    )


def record_reviewed(cfg, names: Iterable[str]) -> list[str]:
    """Set ``cfg.domain_services_reviewed`` to ``names``, restricted to domains that
    still exist and in table order. REBUILT, never merged: a renamed or deleted domain
    must not leave a stranded marker behind that would let the gate pass for a domain
    nobody configured (the same rule ``cfg.domain_ca`` follows)."""
    # STRIP on both sides. unconfigured_domains() compares the STRIPPED name, so a
    # config carrying " acme.example " would otherwise record a marker the gate can
    # never match and refuse for ever. The Domains table strips at validatePage, so
    # only a hand-edited or externally produced config reaches this — which is exactly
    # the config that must not be able to hang the gate.
    keep = {str(n).strip() for n in names or ()}
    # The mesh's OWN domain first (mesh mode only — implicit_own_domain), then the
    # table rows in table order: it is a domain with a services page too, and
    # rebuilding from the table alone would drop its marker on every write.
    own = implicit_own_domain(cfg)
    out = [own] if own and own in keep else []
    out += [(getattr(d, "name", "") or "").strip()
            for d in (getattr(cfg, "domains", None) or [])
            if (getattr(d, "name", "") or "").strip()
            and (getattr(d, "name", "") or "").strip() in keep]
    seen: set[str] = set()
    cfg.domain_services_reviewed = [n for n in out
                                    if not (n in seen or seen.add(n))]
    return cfg.domain_services_reviewed


def implicit_own_domain(cfg) -> str:
    """The MESH's own domain as a services-page subject, or "".

    A mesh serves ``cfg.cluster_domain`` whether or not the operator adds more
    domains (ask 19's default card is "Just this mesh's own domain"), and the
    operator's rule is a service page per domain — so on the mesh route the own
    domain gets one even when the Domains table is skipped (reported 2026-09-23:
    "the checkbox doesn't seem to be present on each domain page"). It is IMPLICIT:
    never a ``cfg.domains`` row, so the ASK-8 emission guard holds — an untouched
    flow still emits no ``--domains`` and no manifest ``domains`` entry; its
    selection lives in ``cfg.cluster_domain_services`` and reaches the manifest
    only when non-empty.

    Mesh mode only. A cloud client's Domains table prefills the cluster domain as a
    REAL row 0 (``pages/domains.py``), standalone has no domains at all — and a
    ``cfg.domains`` row already named after the cluster domain makes it a row, not
    an implicit one, so the two can never be asked twice."""
    if (getattr(cfg, "mode", "") or "") != "mesh":
        return ""
    own = (getattr(cfg, "cluster_domain", "") or "").strip()
    if not own:
        return ""
    for d in (getattr(cfg, "domains", None) or []):
        if (getattr(d, "name", "") or "").strip() == own:
            return ""
    return own


def domain_names_for_services(cfg) -> list[str]:
    """Every domain that gets a services page, in walk order: the implicit own
    domain first (when there is one), then the named table rows, deduped."""
    out: list[str] = []
    own = implicit_own_domain(cfg)
    if own:
        out.append(own)
    for d in (getattr(cfg, "domains", None) or []):
        name = (getattr(d, "name", "") or "").strip()
        if name and name not in out:
            out.append(name)
    return out



def services_page_applies(cfg) -> bool:
    """Whether the per-domain services step is part of this flow — ONE predicate for
    both faces (``gui/pages/domain_services.DomainServicesPage.applies_to`` and the
    TUI walk in ``tui/journey.Journey.advance``), so the two cannot disagree about
    which flows walk it.

    On EVERY mesh flow with a cluster domain (the mesh's own domain always has a
    services page — :func:`implicit_own_domain`, #494 / #589 decision 69), and
    otherwise wherever the Domains table is, when it names at least one domain.

    Emission-neutral when False, in the strong sense the wizard's nextId() ALL-OPTIONS
    guard asks for: nothing is named, so there is nothing to record and nothing for
    the build/mesh-start gate to refuse either — skipping cannot smuggle a domain past
    it. Standalone is skipped statically (MODE_SKIPPED_PAGES) on both faces."""
    if implicit_own_domain(cfg):
        return True
    if not superadmin_plane_applies(cfg):
        return False
    return any((getattr(d, "name", "") or "").strip()
               for d in (getattr(cfg, "domains", None) or []))

def services_summary(selected, reviewed: bool) -> str:
    """ONE line for a domain's recorded services, and the ONLY place its wording lives.

    Three states ``optional_services`` alone cannot tell apart:

    * ``reviewed=False``  → "not configured yet" (nobody has been through this
      domain's page) or "not confirmed — <slugs>" (a loaded config already carried
      slugs, which are shown so an older worklist visibly keeps its manifest data);
    * ``reviewed=True`` with no slugs → "cluster default", i.e. the cluster-wide set
      applies. That is a real answer and NOT the same fact as "unset" — and it is not
      the ``SERVICES_NONE`` sentinel either, which is spelled "none" and emits an
      explicit EMPTY allow-list (config.py's emission table);
    * ``reviewed=True`` with slugs → the allow-list itself.

    ``gui/pages/domains.py``'s read-only cell renders exactly this string. It used to
    carry its own copy of the three branches, which meant the wording the whole
    honesty argument rests on had two sources of truth and the tested one was not the
    one on screen."""
    slugs = normalise_slugs(selected)
    if not reviewed:
        return ("not configured yet" if not slugs
                else "not confirmed — " + ", ".join(slugs))
    return "cluster default" if not slugs else ", ".join(slugs)


def domain_summary(domain, cfg=None) -> str:
    """:func:`services_summary` for a ``Domain`` object, reading the reviewed marker
    off ``cfg``. With ``cfg=None`` the domain is treated as reviewed (there is nothing
    to read the marker from, and inventing "unconfigured" from an absent config would
    make every caller that only has a domain say the alarming thing)."""
    name = (getattr(domain, "name", "") or "").strip()
    reviewed = True
    if cfg is not None and name:
        reviewed = name in reviewed_names(cfg)
    return services_summary(getattr(domain, "optional_services", None), reviewed)


def restart_gate_reason(cfg) -> str:
    """The RESTART gate — narrower than :func:`gate_reason`, and deliberately so.

    ``StudioWizard.start_build_from_session`` re-dispatches a configuration that was
    already recorded and already built once. Every session recorded BEFORE
    ``domain_services_reviewed`` existed carries no marker at all, so refusing on an
    empty marker list would refuse every historical restart over a question nobody was
    ever asked — a gate that only punishes the operator for having used the tool
    earlier.

    So this bites only for a configuration that ALREADY carries at least one reviewed
    name, i.e. one produced under this feature, and has since gained a domain with no
    recorded configuration. A session recorded under this feature cannot have an empty
    marker list and a domain, because the build gate refused exactly that.

    It reads the TABLE ROWS only — never the implicit own domain, which the build gate
    covers since #631 (``OWN_DOMAIN_GATED_ACTIONS``). That is the migration rule for
    sessions recorded before then: one from the #495-to-#595 window carries its rows'
    markers and no own-domain marker (the own domain had no page yet), and refusing its
    restart would be the same punishment for history this narrow gate exists to avoid.
    Redo goes back through the wizard, where the own domain's page is walked."""
    if not reviewed_names(cfg):
        return ""
    return gate_reason(cfg, ACTION_BUILD_RESTART)


def session_boot_gate_reason(session_id: str) -> str:
    """The gate for BOOTING a previous build session's images (#637): "" when they may
    boot; otherwise the refusal naming every domain of that session's recorded
    configuration with no recorded service configuration.

    THE MANIFEST CANNOT ANSWER THIS. ``domain_services_reviewed`` is emitted into
    neither mesh manifest (the module doc), so the question is put to the session's
    BUILD RECORD instead: an artifact session dir ``out/sessions/<id>`` is named after
    its record ``<state>/sessions/<id>.json`` (``build_sessions.session_workdir``), whose
    ``config.base`` is the ImageConfig the images were built from.

    NARROW, exactly like :func:`restart_gate_reason` and for the same reason — it is
    that rule, applied to the configuration a session RECORDED:

    * no record (a CLI build, a record pruned since, an unreadable one) -> "": there is
      nothing to read a marker from, and inventing "unconfigured" would refuse images
      that are already on disk over a question nobody could have answered;
    * a record with NO reviewed marker (built before #495) -> "": history;
    * a record with markers that still names an unwalked TABLE ROW -> refused. The own
      domain is not asked (``OWN_DOMAIN_GATED_ACTIONS``): a session from before #631
      never had it gated.

    Qt-free and the ONE seam both GUI doors (``gui/pages/mesh_emulation.py``,
    ``gui/pages/qemu.py``) and both TUI screens (``tui/meshemu.py``, ``tui/qemu.py``)
    call, so the four cannot disagree about which session boots."""
    name = (session_id or "").strip()
    if not name:
        return ""
    try:
        from . import build_sessions        # lazy: build_sessions -> worklist -> config
        rec = build_sessions.find(name)
        base = rec.worklist().base if rec is not None else None
    except Exception:                       # noqa: BLE001 — a record we cannot read
        return ""                           # is a record with nothing to say
    if base is None or not reviewed_names(base):
        return ""
    return gate_reason(base, ACTION_EMULATE)


# ── #497: the choices this page SHOWS but does not own ──────────────────────────────
def image_service_state(cfg, slug: str) -> str:
    """Whether ``slug`` is on MESH-WIDE right now, read off the image-wide selection the
    ‘Network & services’ step wrote (``cfg.optional_services``).

    The two sentinels are handled explicitly rather than by membership, because
    membership would get both of them wrong:

    * ``SERVICES_NONE`` is an EXPLICIT empty allow-list — everything selectable is off;
    * ``SERVICES_ALL`` expands to the USER-LEVEL set only (``--all-services``), which by
      construction excludes every INFRA slug — so "all" does NOT turn tor or anubis on,
      and reporting it as if it did would be exactly the kind of quiet lie this page
      exists to stop.

    ``tor`` additionally has a dedicated x86 flag (``--with-tor`` /
    ``cfg.tor_onion_service``); it is ORed in, because either spelling really does bake
    the onion."""
    svcs = [str(x) for x in (getattr(cfg, "optional_services", None) or [])]
    if slug == "tor" and getattr(cfg, "tor_onion_service", False):
        return "on (mesh-wide)"
    if SERVICES_NONE in svcs:
        return "off — the services step selected ‘no optional services at all’"
    if SERVICES_ALL in svcs:
        return ("off — ‘every user-level service’ does not include the infra slugs"
                if slug in INFRA_SERVICES_CHOICES else "on (mesh-wide)")
    return "on (mesh-wide)" if slug in svcs else "off"


def node_service_state(entries, slug: str) -> str:
    """Which worklist NODES opted into ``slug`` in their own Services column. ``entries``
    is ``wiz.worklist.entries`` (``WorklistEntry.infra_services``); only ``tor`` and
    ``egress-vpn`` are a per-node axis at all (``worklist.WORKLIST_INFRA_SERVICES`` —
    workloadConsole and anubis are cluster-plane and have no per-node spelling)."""
    named = [getattr(e, "id", "") for e in (entries or ())
             if slug in (getattr(e, "infra_services", None) or ())]
    return ", ".join(n for n in named if n)


def other_scope_rows(cfg=None, entries=()) -> list[tuple[str, str, str, str]]:
    """``[(service, scope, where it is set, right now), ...]`` for every choice this
    page SHOWS but does not own (#497).

    Two jobs, and they pull in opposite directions unless both are done:

    * the operator must not have to hunt for where anubis is configured — so the infra
      slugs stay VISIBLE in the same flow, with their descriptions and their current
      state;
    * nothing infra-scoped may become a per-domain checkbox — so these rows are DATA,
      never controls, and every one of them carries the scope that says why.

    The last row stands for the image-wide services table as a whole: it is a SURFACE
    (dedicated-flag services, edge-AI and its sub-options, the managed backing
    services), not a slug list, and re-listing it here slug by slug would create a
    second catalogue to drift against the first."""
    rows: list[tuple[str, str, str, str]] = []
    for slug in INFRA_SERVICES_CHOICES:
        state = image_service_state(cfg, slug) if cfg is not None else ""
        nodes = node_service_state(entries, slug)
        if nodes:
            state = (state + "; per node: " + nodes) if state else "per node: " + nodes
        rows.append((slug, SCOPE_NODE,
                     INFRA_WHERE.get(slug, SCOPE_WHERE[SCOPE_NODE]), state))
    rows.append((IMAGE_SCOPE_ROW_LABEL, SCOPE_IMAGE, SCOPE_WHERE[SCOPE_IMAGE],
                 "the dedicated-flag services, edge-AI and its sub-options, and the "
                 "managed backing services"))
    return rows


# ── #582: the ONE per-domain infra slug — a domain's own Tor front door ─────────────
# Operator decision 68 = A (hugmesh-generator#347, 2026-09-23) replaces #494 #C for
# ``tor`` ONLY: "a Tor domain = its own HiddenService stanza fronting the SAME gateway,
# distinguished by the onion Host". egress-vpn, workloadConsole and anubis stay node- or
# cluster-plane and stay read-only on this page.
#
# Two facts, kept apart on purpose:
#   * the ``tor`` SLUG is still node-scoped (``scope_of("tor") == SCOPE_NODE``): it is
#     what makes a node RUN Tor at all, set mesh-wide or per node, and the read-only
#     table keeps showing it — every onion needs it;
#   * the per-domain FRONT DOOR is ``Domain.tor`` — its own checkable row, scope
#     "onion (per domain)", which never writes into ``optional_services``.
#
# THE KEY DIRECTORY NAME AND THE TENANT (the host-map line the gateway reads). A Tor
# domain's onion is minted under a directory named by a SLUG (``own_casdoor.slug`` —
# the node contract, docs/TOR-HIDDEN-SERVICE.md, refuses dots, so "acme.example" is
# "acme-example") and registered in the gateway's host map (hugmesh-gateway#38) as
# ``<onion>=<tenant>``. The TENANT is the tenancy key the gateway already resolves that
# domain's HTTPS door to: ``slug(name)`` for a domain that runs its own Casdoor
# (own_casdoor.tenancy_env's ``APP_TENANCY_HOSTS`` value), and ``default`` for one that
# signs in through the superdomain's Casdoor — such a domain has no issuer of its own,
# so mapping its onion to a slug would 403 every signed-in user on it
# (GatewayRouteAccessFilter's domainMatches). Its onion is a separate ADDRESS serving
# the default brand; a separate LOGIN needs sign-in ``own``, and the row says so.
#
# WHAT A TICK DOES DEPENDS ON THE ROUTE, and the row says which — see ``TOR_REACH``.
# Only the local docker mesh acts on it today. A required page that let the operator
# believe a node image will mint the onion would be the kind of quiet untruth this
# page exists to stop (the ENFORCEMENT_NOTE rule, applied to this row).
import re as _re

from . import own_casdoor as _own_casdoor
from .config import DOMAIN_IDP_OWN as _DOMAIN_IDP_OWN

#: The front-door row's scope — neither a domain SERVICE nor a node choice.
SCOPE_ONION = "onion"
SCOPE_LABELS[SCOPE_ONION] = "onion (per domain)"
SCOPE_WHERE[SCOPE_ONION] = "here, once per domain (Tor itself must run on the node)"
SCOPE_BINDS[SCOPE_ONION] = ("this domain's own .onion address — the SAME gateway, told "
                            "apart by the onion Host")

#: The infra slugs that have a per-DOMAIN spelling. Exactly one, by decision 68; the
#: page's catalogue assert admits these and nothing else that is not domain-scoped.
PER_DOMAIN_INFRA: tuple[str, ...] = ("tor",)

#: The row's label, on both faces.
TOR_ROW_LABEL = "Tor front door"

#: The tenant a superdomain-sign-in domain's onion is registered as, and the mesh's own
#: onion's (hugmesh-gateway#39's writer contract, point 1).
TOR_DEFAULT_TENANT = "default"

#: The node contract's slug shape (specs/usr/sbin/hugmesh-tor-reconcile, #599): the
#: entrypoint and the node agent both REFUSE anything else, so the Studio must never
#: emit it.
TOR_SLUG_RE = _re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")

#: What the row is, on both faces. What THIS route does with a tick is ``TOR_REACH``.
TOR_ROW_DESC = (
    "This domain's OWN .onion address: one more Tor onion service in front of the "
    "same gateway as every other door. The gateway tells the domains apart by the "
    "onion name in the request, so this onion opens this domain. Tor itself has to "
    "run on the node (the read-only ‘tor’ row below).")

#: The own domain's row: never a control. The mesh's own onion IS its front door.
TOR_OWN_DOMAIN_NOTE = (
    "the mesh's own onion — minted whenever Tor runs on this mesh and registered as "
    "the default brand; nothing to choose here")


def onion_slug(name: str) -> str:
    """The directory slug a domain's onion is minted under, or "" when ``name``
    cannot make one the node contract accepts (empty, or longer than 63 characters
    once slugged — truncating could collide two domains onto one key)."""
    s = _own_casdoor.slug((name or "").strip())
    return s if TOR_SLUG_RE.match(s) else ""


def onion_tenant(domain) -> str:
    """The tenancy key the gateway maps this domain's onion Host to — see the section
    comment. ``slug(name)`` for sign-in ``own``, ``default`` otherwise."""
    if getattr(domain, "idp", "") == _DOMAIN_IDP_OWN:
        return onion_slug(getattr(domain, "name", "")) or TOR_DEFAULT_TENANT
    return TOR_DEFAULT_TENANT


def tor_domain_entries(domains, own_name: str = "") -> list[tuple[str, str, str]]:
    """``[(name, slug, tenant), ...]`` for every domain with its own Tor front door,
    in table order. The mesh's OWN domain is never an entry — its front door is the
    primary onion — nor is a domain whose name makes no valid slug, nor a second
    domain whose slug collides with an earlier one (one key directory each).

    Accepts ``config.Domain`` rows or the local-mesh record dicts."""
    own = (own_name or "").strip()
    out: list[tuple[str, str, str]] = []
    seen: set[str] = set()
    for d in domains or ():
        get = d.get if isinstance(d, dict) else (lambda k, _d=d: getattr(_d, k, None))
        name = str(get("name") or "").strip()
        if not name or name == own or get("tor") is not True:
            continue
        slug = onion_slug(name)
        if not slug or slug in seen:
            continue
        seen.add(slug)
        out.append((name, slug,
                    slug if get("idp") == _DOMAIN_IDP_OWN else TOR_DEFAULT_TENANT))
    return out


def tor_onion_domains_env(entries) -> str:
    """The ``TOR_ONION_DOMAINS`` value the local docker mesh's tor entrypoint reads:
    space-separated ``<slug>=<tenant>`` (tests/stack/tor/entrypoint.sh). "" for none,
    so an untouched stack's env stays byte-identical."""
    return " ".join(f"{slug}={tenant}" for _name, slug, tenant in entries or ())


def tor_slug_clash(domain, domains=(), own_name: str = "") -> str:
    """The name of the EARLIER Tor domain whose key directory name ``domain`` would
    share, or "". Two names can slug alike ("a-b.example" and "a.b.example"); there is
    one key directory per slug, so only the first in table order gets an onion
    (:func:`tor_domain_entries`) — and the second one's row has to say so."""
    name = (getattr(domain, "name", "") or "").strip()
    slug = onion_slug(name)
    if not slug:
        return ""
    own = (own_name or "").strip()
    for d in domains or ():
        get = d.get if isinstance(d, dict) else (lambda k, _d=d: getattr(_d, k, None))
        other = str(get("name") or "").strip()
        if other == name:
            return ""
        if other and other != own and get("tor") is True and onion_slug(other) == slug:
            return other
    return ""


def tor_row_problem(domain, domains=(), own_name: str = "") -> str:
    """Why a ticked Tor front door cannot be minted for ``domain`` ("" when it can).
    ``domains`` (the rows in table order) lets it see a key-directory clash."""
    name = (getattr(domain, "name", "") or "").strip()
    if name and not onion_slug(name):
        return (f"{name} is too long to name an onion key directory (63 characters "
                "once its dots become dashes) — no onion would be minted for it")
    clash = tor_slug_clash(domain, domains, own_name)
    if clash:
        return (f"{name} and {clash} share one key directory name "
                f"(‘{onion_slug(name)}’), and {clash} comes first — only {clash} "
                "gets an onion; rename one of them")
    return ""


#: The routes that host the per-domain services step. They differ in what a ticked Tor
#: front door DOES, so the row names the one it is on.
TOR_ROUTE_COMPOSE = "compose"      # the generate-a-local-docker-mesh route
TOR_ROUTE_IMAGE = "image"          # node images for a mesh (the image flow, mesh mode)
TOR_ROUTE_CLIENT = "client"        # a Mesh desktop client image (cloud mode)
TOR_ROUTE_FLEET = "fleet"          # the fleet build

#: route -> WHAT A TICK DOES THERE, measured on the builders and the local docker
#: stack, not assumed. Shown on the row's state line on both faces, whether the box is ticked or
#: not, so the operator knows before choosing.
#:
#: * compose — ``LocalStackNode`` passes the Tor domains to ``make stack-up`` as
#:   ``TOR_ONION_DOMAINS`` (tests/stack/tor/entrypoint.sh mints one onion each and
#:   writes the gateway's host map). It needs Tor on for the mesh.
#: * image — both mesh manifests carry ``domains[].tor``. NO builder or provisioning
#:   script reads a manifest's ``domains`` at all, so nothing writes
#:   ``/etc/hugmesh/tor/domains`` on a node from it (hugmesh-tor-reconcile reads that
#:   file; docs/TOR-HIDDEN-SERVICE.md). studio/tests/test_domain_services_tor.py pins
#:   that no builder does, so this sentence fails the day one starts to.
#: * client — a desktop client image serves no domain; cloud mode writes no manifest.
#: * fleet — ``core/fleet.FLEET_LANE_NOTE``: the rows are recorded with the fleet's
#:   session and reach no builder (build-all-roles.sh writes no mesh manifest).
TOR_REACH = {
    TOR_ROUTE_COMPOSE: (
        "On this local docker mesh the choice takes effect: with Tor on, starting "
        "the mesh mints this domain's onion and tells the gateway which sign-in it "
        "opens."),
    TOR_ROUTE_IMAGE: (
        "RECORDED, NOT YET BUILT INTO A NODE: the mesh manifest carries the choice "
        "(domains[].tor), but no image builder reads it, so a node built from this "
        "mints no onion for the domain until its /etc/hugmesh/tor/domains names the "
        "key directory (issue #582)."),
    TOR_ROUTE_CLIENT: (
        "RECORDED ONLY: a Mesh desktop client image serves no domain and mints no "
        "onion, so the choice is kept with this configuration and nothing else."),
    TOR_ROUTE_FLEET: (
        "RECORDED ONLY: a fleet build keeps the choice with the fleet's session and "
        "no builder reads it."),
}


def tor_route(walked) -> str:
    """Which route ``walked`` — the object the services step is walking — belongs to:
    a fleet's or a local docker mesh's domain rows, else an ImageConfig (``cloud`` is
    the desktop client). An object this function has never heard of is treated as a
    node image, the route whose sentence claims the least."""
    # Lazy: both modules import this one.
    from .fleet import FleetDomains
    from .local_mesh_domains import LocalMeshDomains
    if isinstance(walked, FleetDomains):
        return TOR_ROUTE_FLEET
    if isinstance(walked, LocalMeshDomains):
        return TOR_ROUTE_COMPOSE
    if (getattr(walked, "mode", "") or "") == "cloud":
        return TOR_ROUTE_CLIENT
    return TOR_ROUTE_IMAGE


def tor_row_state(domain, cfg=None, entries=(), own_name: str = "",
                  walked=None, domains=()) -> str:
    """ONE line for a domain's Tor front door, and the only place its wording lives:
    whether it is on, which login the onion serves, whether Tor runs on the mesh at
    all (when this surface can know — ``cfg`` None means it cannot, e.g. the local
    docker mesh's step comes BEFORE its Services step), and what this route does with
    the choice (``TOR_REACH``; ``walked`` is the object being walked, ``cfg`` when not
    given). ``domains`` — the rows in table order — lets it name a key-directory
    clash."""
    name = (getattr(domain, "name", "") or "").strip()
    if own_name and name == own_name:
        return TOR_OWN_DOMAIN_NOTE
    route = tor_route(cfg if walked is None else walked)
    reach = TOR_REACH[route]
    if not getattr(domain, "tor", False):
        return "off — this domain has no onion of its own. " + reach
    problem = tor_row_problem(domain, domains, own_name)
    if problem:
        return "on, but " + problem + ". " + reach
    # Only a route that ACTS on the tick may say the domain has an onion.
    bits = [f"on — its own onion, key directory ‘{onion_slug(name)}’"
            if route == TOR_ROUTE_COMPOSE else
            "ticked — it would be this domain's own onion, key directory "
            f"‘{onion_slug(name)}’"]
    if onion_tenant(domain) == TOR_DEFAULT_TENANT:
        bits.append("it signs in through the mesh's Casdoor, so its onion serves the "
                    "DEFAULT brand's login; choose sign-in ‘own’ on the Domains table "
                    "for a login of its own")
    else:
        bits.append("its onion serves this domain's own login")
    if route == TOR_ROUTE_COMPOSE and cfg is None:
        bits.append("Tor itself must be on for the mesh (the ‘Services’ step) or no "
                    "onion is minted")
    elif route == TOR_ROUTE_IMAGE and cfg is not None and not mesh_tor_on(cfg, entries):
        bits.append("BUT Tor is off for this mesh — turn ‘tor’ on (mesh-wide on the "
                    "‘Network & services’ step, or per node in the worklist), or no "
                    "onion is minted")
    return "; ".join(bits) + ". " + reach


def tor_row_warns(domain, cfg=None, entries=(), own_name: str = "",
                  walked=None, domains=()) -> bool:
    """Whether the state line should stand out: the front door is ticked and either it
    cannot be minted, Tor is off for the mesh, or this route only records the choice.
    Both faces ask this rather than re-deriving it."""
    name = (getattr(domain, "name", "") or "").strip()
    if (own_name and name == own_name) or not getattr(domain, "tor", False):
        return False
    route = tor_route(cfg if walked is None else walked)
    if route != TOR_ROUTE_COMPOSE or tor_row_problem(domain, domains, own_name):
        return True
    return cfg is not None and not mesh_tor_on(cfg, entries)


def mesh_tor_on(cfg, entries=()) -> bool:
    """Whether Tor runs anywhere on this mesh: mesh-wide (``image_service_state``) or
    on at least one worklist node (``node_service_state``)."""
    return (image_service_state(cfg, "tor").startswith("on")
            or bool(node_service_state(entries, "tor")))


__all__ += [
    "SCOPE_ONION", "PER_DOMAIN_INFRA", "TOR_ROW_LABEL", "TOR_ROW_DESC",
    "TOR_OWN_DOMAIN_NOTE", "TOR_DEFAULT_TENANT", "TOR_SLUG_RE",
    "onion_slug", "onion_tenant", "tor_domain_entries", "tor_onion_domains_env",
    "tor_slug_clash", "tor_row_problem", "tor_row_state", "tor_row_warns",
    "mesh_tor_on",
    "TOR_ROUTE_COMPOSE", "TOR_ROUTE_IMAGE", "TOR_ROUTE_CLIENT", "TOR_ROUTE_FLEET",
    "TOR_REACH", "tor_route",
]
