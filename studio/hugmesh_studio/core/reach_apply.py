"""What the start paths DO with a domain's own VPN (tailnet) and egress choices
(core/domain_reach) — 2026-10-21 round 2, operator ask "tor/vpn + egress config per
domain".

Qt-free. ``domain_reach`` records the choices and resolves them against the mesh's
values; this module answers the next question, per route: does a start apply them?

THE DOCKER MESH, MEASURED (tests/stack/compose.egress-vpn.yaml, Makefile
``STACK_EGRESS_FLAGS``, specs/usr/share/hugmesh/stack/docker-compose.mesh.yml):

* EGRESS — APPLIED, for the one thing the stack can route. The local stack runs ONE
  egress VPN client container (``hugmesh-egress-vpn``, ``EGRESS_VPN=1`` +
  ``EGRESS_VPN_CONF=<file>``) and attaches exactly ONE service to it:
  ``mastodon-sidekiq``, Mastodon's outbound delivery worker. Mastodon comes with the
  ``tuwunel`` service (the ``social`` compose profile brings up Matrix AND Mastodon),
  and the mesh runs ONE Mastodon that every domain which ticked ``tuwunel`` shares.
  So the domains that run that Mastodon decide the egress container: their effective
  egress (own value, else the mesh's) is what ``docker_egress`` turns into the
  ``EGRESS_VPN``/``EGRESS_VPN_CONF`` pair. Rules:

  - no domain that runs Mastodon has a choice of its own -> the mesh's own egress
    exactly as before (the Mesh infrastructure tick and its file): byte-identical;
  - any of them goes through a VPN -> the VPN is on (never the other way round: a
    domain that asked for direct but shares the Mastodon is carried by the tunnel
    too, and its screen says so — a stricter path, never a leak);
  - two of them name DIFFERENT provider files -> refused at start (one container,
    one tunnel); the refusal names both;
  - all of them direct -> off, even when the Mesh infrastructure tick is on (a
    domain's own value overrides the mesh's), and the plan says so.

  A domain that does not run Mastodon has nothing on this mesh that uses the
  egress VPN: its own choice is recorded and the screen says it is not applied.

* VPN (tailnet) — NOT APPLIED, and cannot be on this stack. The mesh overlay is a
  separate compose project with ONE tailscale container that joins the private
  network as one machine (production, with an auth key). No app container is
  attached to it and nothing publishes any domain's pages over it, so there is no
  per-domain switch to set; ``tailnet_notes`` says that per domain, and names a
  choice the mesh contradicts.

THE OTHER ROUTES apply neither (``ROUTE_NOT_APPLIED``): an image's egress VPN and
its private network cover the whole computer; the kind DevOps lane ships the egress
delivery dark and joins no private network; the fleet's nodes join as whole
machines.
"""
from __future__ import annotations

import os
from typing import NamedTuple

from . import domain_reach
from .domain_reach import (EGRESS_DIRECT, EGRESS_VPN, REACH_FROM_MESH, EgressChoice,
                           TailnetChoice)
from .local_services import split_selection

__all__ = [
    "MASTODON_SLUG", "DomainEgress", "DockerEgress", "docker_own_name", "docker_rows",
    "mastodon_domains", "docker_egress", "docker_egress_note", "docker_tailnet_note",
    "docker_reach_notes", "ROUTE_NOT_APPLIED", "DOCKER_TAILNET_NOT_APPLIED",
    "DOCKER_EGRESS_SCOPE", "KIND_NOT_APPLIED", "plan_lines", "reach_warnings",
]

#: The per-domain service whose compose profile (``social``) brings up the Mastodon
#: tier — and with it ``mastodon-sidekiq``, the one container the egress VPN carries.
MASTODON_SLUG = "tuwunel"

#: What every Docker-route screen says about the egress VPN's reach, once.
DOCKER_EGRESS_SCOPE = (
    "On this Docker mesh the egress VPN carries one thing: Mastodon's outbound "
    "delivery (Mastodon comes with the tuwunel service). Every other app shares the "
    "mesh's containers and goes out the computer's own way.")

#: Why a domain's own VPN choice is not applied on the Docker mesh.
DOCKER_TAILNET_NOT_APPLIED = (
    "VPN: not applied on this Docker mesh. Its VPN container joins the private "
    "network as one machine (production, with an auth key) and puts no domain's "
    "pages on it, so there is no per-domain switch; the choice is kept with the "
    "domain.")

#: The kind DevOps lane, said on the Docker route (it is started from the same page).
KIND_NOT_APPLIED = ("The DevOps (kind) lane applies neither: it joins no private "
                    "network and its egress delivery ships switched off.")

#: Routes that apply neither choice, in the words their tab shows.
ROUTE_NOT_APPLIED: dict[str, str] = {
    "image": ("Not applied by an image: a node image's private network and egress VPN "
              "cover the whole computer (every domain on it), so this domain's own VPN "
              "and egress are recorded only. Set the image's own egress on its "
              "Network step."),
    "fleet": ("Not applied by the fleet: its nodes join the private network as whole "
              "machines and run one egress each, so this domain's own VPN and egress "
              "are recorded only."),
    "": ("Recorded with this domain; this screen's route applies neither its own VPN "
         "nor its own egress."),
}


class DomainEgress(NamedTuple):
    name: str
    choice: EgressChoice
    own_domain: bool       # the mesh's own domain (row 0): always the mesh's values


class DockerEgress(NamedTuple):
    """What a Docker start passes as ``EGRESS_VPN`` / ``EGRESS_VPN_CONF``."""
    on: bool
    conf: str                       # "" when off, or when nothing names a file
    carried: tuple[DomainEgress, ...]   # the domains whose Mastodon it decides for
    from_domains: bool              # False: the mesh's own tick decided, as before
    conflict: str                   # "" or the refusal sentence
    not_applied: tuple[str, ...]    # added domains with an egress of their own that
    #                                 run no Mastodon here (recorded only)


# ── reading a configuration ────────────────────────────────────────────────────────
def _name(r) -> str:
    v = r.get("name") if isinstance(r, dict) else getattr(r, "name", "")
    return str(v or "").strip()


def _services(r) -> tuple[str, ...]:
    v = (r.get("optional_services") if isinstance(r, dict)
         else getattr(r, "optional_services", None))
    return tuple(str(x) for x in v) if isinstance(v, (list, tuple)) else ()


def _ways(r) -> dict:
    v = r.get("ways") if isinstance(r, dict) else getattr(r, "ways", None)
    return v if isinstance(v, dict) else {}


def docker_own_name(cfg) -> str:
    """The mesh's own domain on the Docker route — the same name ``tor_domains`` and
    ``external_idp_domains`` leave out."""
    own = str(getattr(cfg, "cluster_domain", "") or "").strip()
    if own:
        return own
    resolved = getattr(cfg, "resolved_domain", None)
    return str(resolved() if callable(resolved) else "").strip()


def docker_rows(cfg) -> list:
    return [r for r in (getattr(cfg, "domains", None) or ()) if isinstance(r, (dict,))
            or hasattr(r, "name")]


def _expand(conf: str) -> str:
    conf = (conf or "").strip()
    return os.path.abspath(os.path.expanduser(conf)) if conf else ""


def mastodon_domains(cfg, rows=None, own_name: str | None = None
                     ) -> list[tuple[str, object, bool]]:
    """``[(name, row or None, is the mesh's own domain), ...]`` — the domains the
    mesh's ONE Mastodon serves, in record order (own domain first). [] when the mesh
    starts no Mastodon (the ``social`` profile is off).

    The mesh's own domain is among them when its row ticked tuwunel, when the mesh
    itself still carries it (a legacy ``social`` flag or a ``--services`` list naming
    it), or when no added domain did (the Mastodon is then simply the mesh's)."""
    if not cfg.effective_social():
        return []
    own = docker_own_name(cfg) if own_name is None else (own_name or "").strip()
    rows = docker_rows(cfg) if rows is None else list(rows)
    own_row = next((r for r in rows if _name(r) == own), None)
    added = [r for r in rows if _name(r) and _name(r) != own
             and MASTODON_SLUG in _services(r)]
    services = getattr(cfg, "services", None)
    mesh_part = (split_selection(services)[0] if services is not None
                 else ((MASTODON_SLUG,) if getattr(cfg, "social", False) else ()))
    own_runs = (not added or MASTODON_SLUG in mesh_part
                or (own_row is not None and MASTODON_SLUG in _services(own_row)))
    out: list[tuple[str, object, bool]] = []
    if own_runs:
        out.append((own or "the mesh's own domain", own_row, True))
    out.extend((_name(r), r, False) for r in added)
    return out


def docker_egress(cfg, rows=None, own_name: str | None = None) -> DockerEgress:
    """The egress a Docker start applies: see the module text for the rules. Pure;
    ``rows``/``own_name`` default to the configuration's own."""
    rows = docker_rows(cfg) if rows is None else list(rows)
    own = docker_own_name(cfg) if own_name is None else (own_name or "").strip()
    mesh = domain_reach.mesh_egress_default(cfg)
    carried: list[DomainEgress] = []
    for name, row, is_own in mastodon_domains(cfg, rows, own):
        choice = mesh if (is_own or row is None) else domain_reach.effective_egress(row, cfg)
        carried.append(DomainEgress(name, choice, is_own))
    carried_names = {d.name for d in carried}
    not_applied = tuple(
        _name(r) for r in rows
        if _name(r) and _name(r) != own and _name(r) not in carried_names
        and isinstance(_ways(r).get(domain_reach.WAY_EGRESS), dict))
    mesh_on = bool(cfg.effective_egress_vpn())
    mesh_conf = (getattr(cfg, "egress_vpn_conf", "") or "").strip()
    if not any(d.choice.source != REACH_FROM_MESH for d in carried):
        # nobody that runs the Mastodon chose for themselves: the mesh's own tick,
        # with its file as given — byte-identical to every start before this lane
        return DockerEgress(mesh_on, mesh_conf if mesh_on else "", tuple(carried),
                            False, "", not_applied)
    vpn = [d for d in carried if d.choice.mode == EGRESS_VPN]
    if not vpn:
        return DockerEgress(False, "", tuple(carried), True, "", not_applied)
    confs: dict[str, list[str]] = {}
    for d in vpn:
        c = _expand(d.choice.conf)
        if c:
            confs.setdefault(c, []).append(d.name)
    conflict = ""
    if len(confs) > 1:
        parts = [f"{' and '.join(names)} ({os.path.basename(c)})"
                 for c, names in confs.items()]
        conflict = ("the domains that share this mesh's one Mastodon name different "
                    "egress VPN provider files — " + ", ".join(parts) + " — and the "
                    "mesh runs one egress tunnel; give them the same file, or set one "
                    "of them to direct")
    conf = next(iter(confs), "")
    return DockerEgress(True, conf, tuple(carried), True, conflict, not_applied)


# ── the words a Docker-route screen shows for one domain ──────────────────────────
def _file(conf: str) -> str:
    return os.path.basename(conf) if conf else "no provider file yet"


def docker_egress_note(name: str, plan: DockerEgress) -> str:
    """One paragraph: what the next Docker start does with ``name``'s egress."""
    me = next((d for d in plan.carried if d.name == name), None)
    if me is None:
        return ("Egress: not applied for this domain on this Docker mesh — it does not "
                "run Mastodon (tick tuwunel on its Services tab), and nothing else it "
                "runs goes through the egress VPN. Its choice is kept with the domain.")
    if plan.conflict:
        return "Egress: the mesh will not start — " + plan.conflict + "."
    if not plan.from_domains:
        how = (f"through the egress VPN ({_file(plan.conf)})" if plan.on
               else "directly (no egress VPN)")
        return ("Egress: applied — this domain runs Mastodon, and the next start sends "
                f"Mastodon's outbound delivery {how}, the mesh's own choice.")
    if me.choice.mode == EGRESS_DIRECT and plan.on:
        others = [d.name for d in plan.carried if d.choice.mode == EGRESS_VPN]
        return ("Egress: direct was chosen, but this domain shares the mesh's one "
                f"Mastodon with {', '.join(others)}, whose egress is the VPN — the next "
                f"start sends that Mastodon's outbound delivery through the egress VPN "
                f"({_file(plan.conf)}) for all of them (stricter, never a leak).")
    if plan.on:
        return ("Egress: applied — the next start sends Mastodon's outbound delivery "
                f"through the egress VPN ({_file(plan.conf)}).")
    return ("Egress: applied — the next start sends Mastodon's outbound delivery "
            "directly (no egress VPN), whatever the Mesh infrastructure tick says.")


def docker_tailnet_note(row, cfg, joins: bool | None = None) -> str:
    """Why a domain's VPN choice is not applied on the Docker mesh, and — when its
    own choice and what the mesh does disagree — that too. ``joins`` is whether the
    mesh's VPN container attaches (``LocalMeshBootstrap.overlay_will_attach``); None
    reads it off the configuration (production with an auth key)."""
    if joins is None:
        joins = bool(callable(getattr(cfg, "is_prod", None)) and cfg.is_prod()
                     and str(getattr(cfg, "auth_key", "") or "").strip())
    t: TailnetChoice = domain_reach.effective_tailnet(row, cfg)
    out = DOCKER_TAILNET_NOT_APPLIED
    if t.source != REACH_FROM_MESH:
        if t.on and not joins:
            out += (" This domain asks to be on the VPN, and this mesh joins none "
                    "(a test mesh, or no auth key).")
        elif not t.on and joins:
            out += (" This domain asks to stay off the VPN; the mesh's VPN container "
                    "joins anyway, but it serves no domain's pages.")
    return out


def docker_reach_notes(name: str, cfg, rows=None, own_name: str | None = None) -> str:
    """The Ways tab's note for one ADDED domain on the Docker route: egress, VPN, the
    kind lane and the egress VPN's scope, in that order."""
    rows = docker_rows(cfg) if rows is None else list(rows)
    plan = docker_egress(cfg, rows, own_name)
    row = next((r for r in rows if _name(r) == (name or "").strip()), None)
    return "\n".join([docker_egress_note((name or "").strip(), plan),
                      docker_tailnet_note(row if row is not None else {}, cfg),
                      KIND_NOT_APPLIED, DOCKER_EGRESS_SCOPE])


# ── the start's own words: the plan block and the advisory lines ─────────────────
def plan_lines(cfg, joins: bool) -> list[str]:
    """The confirm-before-run plan's block for per-domain reach. [] when no added
    domain has a VPN or egress of its own AND the egress is the mesh's — every plan
    written before this lane stays byte-identical."""
    plan = docker_egress(cfg)
    own = docker_own_name(cfg)
    tail_rows = [r for r in docker_rows(cfg)
                 if _name(r) and _name(r) != own
                 and isinstance(_ways(r).get(domain_reach.WAY_TAILNET), bool)]
    if not plan.from_domains and not plan.not_applied and not tail_rows:
        return []
    lines = ["      PER-DOMAIN EGRESS (applied — the egress VPN carries Mastodon's "
             "outbound"]
    lines.append("      delivery only; the domains that run Mastodon decide it):")
    if not plan.carried:
        lines.append("        no domain runs Mastodon: the mesh's own egress choice "
                     "stands")
    for d in plan.carried:
        src = "the mesh's own domain" if d.own_domain else d.choice.source
        how = (f"VPN ({_file(_expand(d.choice.conf))})" if d.choice.mode == EGRESS_VPN
               else "direct")
        lines.append(f"        * {d.name}: {how} — {src}")
    if plan.conflict:
        lines.append(f"        -> REFUSED: {plan.conflict}")
    else:
        lines.append("        -> EGRESS_VPN=" + ("1" if plan.on else "(off)")
                     + (f", EGRESS_VPN_CONF={plan.conf}" if plan.on and plan.conf else "")
                     + ("  (the domains' own choices)" if plan.from_domains
                        else "  (the mesh's own choice)"))
        if plan.from_domains and plan.on != bool(cfg.effective_egress_vpn()):
            lines.append("           (the Mesh infrastructure egress tick says "
                         + ("on" if cfg.effective_egress_vpn() else "off")
                         + "; the domains' own choices win)")
    for n in plan.not_applied:
        lines.append(f"        * {n}: its own egress is NOT applied (it runs no "
                     "Mastodon here)")
    if tail_rows:
        lines.append("      PER-DOMAIN VPN: NOT applied — the mesh's VPN container "
                     "joins as one")
        lines.append("      machine and puts no domain's pages on it:")
        for r in tail_rows:
            on = _ways(r)[domain_reach.WAY_TAILNET]
            lines.append(f"        * {_name(r)}: asks {'on' if on else 'off'}; the mesh "
                         + ("joins" if joins else "joins none"))
    return lines


def reach_warnings(cfg, joins: bool) -> list[str]:
    """Advisory lines (never block) for choices this start cannot honour."""
    out: list[str] = []
    plan = docker_egress(cfg)
    for n in plan.not_applied:
        out.append(f"{n} has an egress of its own, but it runs no Mastodon on this "
                   "Docker mesh and nothing else it runs goes through the egress VPN, "
                   "so its choice is not applied here.")
    if plan.from_domains and not plan.conflict:
        direct_carried = [d.name for d in plan.carried
                          if d.choice.mode == EGRESS_DIRECT and not d.own_domain
                          and d.choice.source != REACH_FROM_MESH]
        if plan.on and direct_carried:
            out.append(", ".join(direct_carried) + " chose direct egress but shares "
                       "the mesh's one Mastodon with a domain whose egress is the VPN, "
                       "so the VPN carries it too.")
        if not plan.on and cfg.effective_egress_vpn():
            out.append("The Mesh infrastructure egress VPN is ticked, but every domain "
                       "that runs Mastodon chose direct egress, so this start runs no "
                       "egress VPN.")
    own = docker_own_name(cfg)
    for r in docker_rows(cfg):
        if not _name(r) or _name(r) == own:
            continue
        v = _ways(r).get(domain_reach.WAY_TAILNET)
        if isinstance(v, bool):
            out.append(f"{_name(r)} asks to be {'on' if v else 'off'} the VPN; this "
                       "Docker mesh does not apply a per-domain VPN choice (its VPN "
                       "container joins as one machine"
                       + (")." if joins else ", and this mesh joins none)."))
    return out
