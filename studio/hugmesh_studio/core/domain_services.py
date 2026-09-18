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
    "gate_applies", "gate_reason", "record_reviewed",
    "services_summary", "domain_summary",
    "restart_gate_reason",
    "ACTION_IMAGE_BUILD", "ACTION_MESH_START", "ACTION_BUILD_RESTART",
    "ACTION_REMEDY",
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
           "own Services column",
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
}


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
    added to one and not the other would otherwise be silently un-offerable, which is
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

    STRIPPED here, at the one read seam, so a hand-edited config carrying
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


def unconfigured_domains(cfg) -> list[str]:
    """The named domains on ``cfg`` with no recorded service configuration, in table
    order. A row with an empty name is not a domain yet (the Domains table drops those
    at validatePage) and is never reported. Empty whenever :func:`gate_applies` is
    False.

    STRICTER THAN THE WORKLIST, on purpose: a mesh worklist filters ``base.domains``
    per entry by ``Domain.images`` (``worklist.entry_config``), and this does not — a
    domain attached to NO selected image still has to be configured before the build
    runs. Fail-closed: the alternative is a domain that is in the config, rides the
    mesh manifest on the next entry that does claim it, and was never asked about."""
    if not gate_applies(cfg):
        return []
    done = reviewed_names(cfg)
    out: list[str] = []
    for d in getattr(cfg, "domains", None) or []:
        name = (getattr(d, "name", "") or "").strip()
        if name and name not in done and name not in out:
            out.append(name)
    return out


def gate_reason(cfg, action: str = ACTION_IMAGE_BUILD) -> str:
    """"" when ``action`` may proceed; otherwise the refusal, naming every domain.

    THE SEAM. Every gate calls exactly this — the image build at
    ``gui/pages/launch.py``, BOTH docker mesh-start doors at ``gui/pages/localmesh.py``
    (``_bootstrap_up`` and ``_start_saved``), and, through
    :func:`restart_gate_reason`, the previous-builds RESTART at
    ``gui/pages/sessions_widget.py`` — and a test can drive it with a bare ImageConfig,
    no Qt, no wizard, no build, no docker. Naming the domains is the
    point: "configure your domains" is a message that scrolls past, "acme.example has
    no recorded service configuration" is one the operator can act on."""
    missing = unconfigured_domains(cfg)
    if not missing:
        return ""
    plural = "s" if len(missing) > 1 else ""
    remedy = ACTION_REMEDY.get(action)
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
    # the config that must not be able to wedge the gate.
    keep = {str(n).strip() for n in names or ()}
    out = [(getattr(d, "name", "") or "").strip()
           for d in (getattr(cfg, "domains", None) or [])
           if (getattr(d, "name", "") or "").strip()
           and (getattr(d, "name", "") or "").strip() in keep]
    seen: set[str] = set()
    cfg.domain_services_reviewed = [n for n in out
                                    if not (n in seen or seen.add(n))]
    return cfg.domain_services_reviewed


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
    marker list and a domain, because the build gate refused exactly that."""
    if not reviewed_names(cfg):
        return ""
    return gate_reason(cfg, ACTION_BUILD_RESTART)


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
