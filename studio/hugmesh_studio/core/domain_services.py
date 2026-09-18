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
                     SERVICES_NONE)

__all__ = [
    "SCOPE_DOMAIN", "SCOPE_IMAGE", "SCOPE_NODE", "SCOPE_LABELS", "SCOPE_WHERE",
    "SCOPE_BINDS", "INFRA_WHERE", "OTHER_SCOPE_HEADERS",
    "IMAGE_SCOPE_ROW_LABEL",
    "image_service_state", "node_service_state", "other_scope_rows",
    "DOMAIN_CATALOGUE", "ENFORCEMENT_NOTE",
    "scope_of", "grouped_domain_catalogue", "split_services", "normalise_slugs",
    "carried_over_slugs", "describe", "describe_carried_over",
    "CARRIED_OVER_NOTE", "reviewed_names", "unconfigured_domains",
    "gate_reason", "record_reviewed", "domain_summary",
    "ACTION_IMAGE_BUILD", "ACTION_MESH_START",
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
    """The domain NAMES whose services page has actually been gone through."""
    return {str(n) for n in (getattr(cfg, "domain_services_reviewed", None) or [])}


def unconfigured_domains(cfg) -> list[str]:
    """The named domains on ``cfg`` with no recorded service configuration, in table
    order. A row with an empty name is not a domain yet (the Domains table drops those
    at validatePage) and is never reported."""
    done = reviewed_names(cfg)
    out: list[str] = []
    for d in getattr(cfg, "domains", None) or []:
        name = (getattr(d, "name", "") or "").strip()
        if name and name not in done and name not in out:
            out.append(name)
    return out


def gate_reason(cfg, action: str = ACTION_IMAGE_BUILD) -> str:
    """"" when ``action`` may proceed; otherwise the refusal, naming every domain.

    THE SEAM. Both gates (the image build at ``gui/pages/launch.py`` and the docker
    mesh start at ``gui/pages/localmesh.py``) call exactly this, and a test can drive it
    with a bare ImageConfig — no Qt, no wizard, no build. Naming the domains is the
    point: "configure your domains" is a message that scrolls past, "acme.example has
    no recorded service configuration" is one the operator can act on."""
    missing = unconfigured_domains(cfg)
    if not missing:
        return ""
    plural = "s" if len(missing) > 1 else ""
    return (
        f"Cannot {action}: {len(missing)} domain{plural} ha{'ve' if plural else 's'} "
        f"no recorded service configuration — " + ", ".join(missing) + ". "
        "Go back to the ‘Domain services’ step and go through each one "
        "(every domain has its own page there)."
    )


def record_reviewed(cfg, names: Iterable[str]) -> list[str]:
    """Set ``cfg.domain_services_reviewed`` to ``names``, restricted to domains that
    still exist and in table order. REBUILT, never merged: a renamed or deleted domain
    must not leave a stranded marker behind that would let the gate pass for a domain
    nobody configured (the same rule ``cfg.domain_ca`` follows)."""
    keep = {str(n) for n in names or ()}
    out = [d.name for d in (getattr(cfg, "domains", None) or [])
           if (getattr(d, "name", "") or "").strip() and d.name in keep]
    seen: set[str] = set()
    cfg.domain_services_reviewed = [n for n in out
                                    if not (n in seen or seen.add(n))]
    return cfg.domain_services_reviewed


def domain_summary(domain, cfg=None) -> str:
    """One line for a domain's recorded services — what the Domains table's read-only
    cell and the TUI table both show. Distinguishes the three states that
    ``optional_services`` alone cannot: never configured, configured as "the
    cluster-wide set applies", and an explicit allow-list."""
    slugs = normalise_slugs(getattr(domain, "optional_services", None))
    name = (getattr(domain, "name", "") or "").strip()
    if cfg is not None and name and name not in reviewed_names(cfg):
        return ("not configured yet" if not slugs
                else "not confirmed — " + ", ".join(slugs))
    if not slugs:
        return "cluster default"
    return ", ".join(slugs)


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
