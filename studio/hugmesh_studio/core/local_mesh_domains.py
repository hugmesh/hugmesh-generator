"""The domains of a GENERATED local Docker mesh — the Qt-free half (issue #494).

The operator's ask (2026-09-17): "a service page per domain you make you have to go
through before building or starting a mesh in docker or nodes". On the generate-a-new-
mesh route the Studio had ONE domain field (``boot_domain``, on the prod-only overlay
step) and no per-domain services at all, so the per-domain gate ``localmesh.py``
calls (``domain_services.gate_reason``) could never bite there: it reads
``wiz.cfg.domains``, a table that route never fills (reported 2026-09-23: "no gui
based multidomain config in the studio for the generate new mesh path").

This module is the state the two new local-mesh steps (Domains, Domain services)
write, kept OFF ``ImageConfig`` on purpose:

* the whole local-mesh branch "emits ZERO ImageConfig fields" (``wizard.py``
  ``_LOCALMESH_STEPS``), and ``test_the_choice_screen_commits_nothing_to_cfg`` pins
  it — a docker mesh is not an image, and every saved config and builder argv must
  stay ignorant of it;
* ``wiz.cfg.mode`` on this route is whatever IMAGE mode the operator last committed
  (the local-mesh card never sets it — ``ModePage.validatePage`` returns before
  ``cfg.mode = mid``), and ``ImageConfig()``'s default is ``standalone``, for which
  ``domain_services.gate_applies`` is False. Writing the rows into ``wiz.cfg`` would
  therefore leave the gate a no-op on exactly the route it is meant to guard.

So :class:`LocalMeshDomains` is a small stand-in shaped so the ONE gate seam,
``domain_services.gate_reason``, reads it through the same ``getattr`` calls it uses
on an ``ImageConfig``: ``mode``, ``domains``, ``domain_services_reviewed``. Its
``mode`` is the class constant ``"mesh"`` because that is the gate's real question
("do these domains reach anything?") and on a local mesh they do: a row with
sign-in=own stands up its own Casdoor (``core/own_casdoor.py``).

What the rows turn into on the bring-up (``LocalMeshBootstrapConfig``):

* ``own_idp_domains`` — the names whose sign-in is ``own`` (already consumed by
  ``LocalStackNode`` / the compose overlay; the GUI just never sent them);
* ``domains`` — the rows RECORDED with the mesh (:func:`bootstrap_domain_records`),
  omitting the mesh's own domain while it is default-shaped, so an untouched flow
  keeps the empty tuple it always had (emission neutrality, pinned by test).

The per-domain optional services are recorded and NOT enforced on this lane: the
compose profiles come from the mesh-wide Services step (``services=``), exactly as
the cluster lane's #496 note says for ArgoCD. The page says so in one sentence.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import ClassVar

from .config import DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, Domain
from .domain_services import normalise_slugs

__all__ = ["LocalMeshDomains", "bootstrap_domain_records", "own_idp_names",
           "LOCAL_MESH_REMEDY"]

#: The remedy the local-mesh gate refusal carries. ``domain_services.ACTION_REMEDY``'s
#: sentence for ACTION_MESH_START points at the IMAGE flow's step, which is the wrong
#: route here — this route has its own two steps, and the refusal must name them.
LOCAL_MESH_REMEDY = (
    "Go back to the ‘Domains’ and ‘Domain services’ steps of this local-mesh setup "
    "— every domain there has its own service page, and opening it is what records "
    "it — or remove the domain from the Domains table.")


@dataclass
class LocalMeshDomains:
    """The domain rows of a generated local mesh plus the gate's bookkeeping.

    Empty until the Domains step is first visited: the step seeds the mesh's own
    domain on that visit, never the controller's constructor, so a host with no
    steps (``LocalMeshDialog``) and a saved-mesh Start on a flow that never opened
    the step keep passing the gate exactly as they did before this existed."""
    #: ``domain_services.gate_applies`` reads it: the domains of a local mesh reach
    #: the compose lane (own Casdoors), so the gate must be able to bite.
    mode: ClassVar[str] = "mesh"
    domains: list[Domain] = field(default_factory=list)
    domain_services_reviewed: list[str] = field(default_factory=list)

    def names(self) -> list[str]:
        return [(d.name or "").strip() for d in self.domains if (d.name or "").strip()]

    def by_name(self, name: str) -> Domain | None:
        name = (name or "").strip()
        for d in self.domains:
            if (d.name or "").strip() == name:
                return d
        return None


def own_idp_names(domains) -> tuple[str, ...]:
    """The names whose sign-in is ``own``, in table order — what
    ``LocalMeshBootstrapConfig.own_idp_domains`` (and so the compose overlay's port
    sequence) is derived from."""
    return tuple((d.name or "").strip() for d in domains
                 if getattr(d, "idp", "") == DOMAIN_IDP_OWN and (d.name or "").strip())


def _default_shaped(d: Domain) -> bool:
    return (not (d.title or "").strip()
            and getattr(d, "idp", DOMAIN_IDP_SUPERDOMAIN) == DOMAIN_IDP_SUPERDOMAIN
            and not normalise_slugs(d.optional_services))


def bootstrap_domain_records(domains, own_name: str) -> tuple[dict, ...]:
    """The rows to RECORD on the bootstrap config, JSON-shaped.

    Every added domain always; the mesh's OWN domain (``own_name`` — the resolved
    cluster domain) only when it says something the rest of the config does not
    already carry (a title, an own sign-in, a per-domain selection). A flow that never
    touched the new steps therefore records ``()`` — byte-identical to a config from
    before the field existed."""
    own = (own_name or "").strip()
    out: list[dict] = []
    for d in domains:
        name = (d.name or "").strip()
        if not name:
            continue
        if name == own and _default_shaped(d):
            continue
        out.append({"name": name, "title": (d.title or "").strip(),
                    "idp": getattr(d, "idp", DOMAIN_IDP_SUPERDOMAIN)
                    or DOMAIN_IDP_SUPERDOMAIN,
                    "optional_services": normalise_slugs(d.optional_services)})
    return tuple(out)
