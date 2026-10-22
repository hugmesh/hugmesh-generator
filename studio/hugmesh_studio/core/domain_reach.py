"""How ONE domain is reached beyond its names — the per-domain VPN (tailnet /
headscale) membership and egress (2026-10-21, operator ask "tor/vpn + egress config
per domain").

Qt-free. Both choices live in the row's ``ways`` block (``config.Domain.ways`` —
"how this brand is reached"), written by the ONE writer ``brand_model.set_ways``,
beside the ``internal_name`` and ``public`` ways that are already there. Tor stays
the row's own ``tor`` field (decision 68; ``set_ways(tor=...)``), unchanged.

An ABSENT key INHERITS the mesh-wide value — the same rule ``Domain.look`` follows
for the superbrand look — so every row written before these keys existed reads as
"inherited" and keeps its bytes (``ways`` is OMIT-WHEN-EMPTY on every saved shape):

* ``ways["tailnet"]`` — True/False: is this domain published on the mesh's own VPN
  (the tailnet that headscale coordinates, the one the ``internal_name`` way lives
  on)? Absent = the mesh's (``mesh_tailnet_default``: a mesh node image joins its
  tailnet; a local Docker mesh joins one only in production, where the overlay
  attaches).
* ``ways["egress"]`` — ``{"mode": "vpn"|"direct", "conf": "<path>"}``: does this
  domain's OUTBOUND traffic leave through an egress VPN provider (WireGuard .conf or
  OpenVPN .ovpn, the files ``core/egress_conf.validate_egress_conf`` sniffs), and
  through which provider file? ``conf`` is a POINTER (a path, never the key text — the
  record's secret scan refuses key material), and "" with mode ``vpn`` means the
  mesh's own file. Absent = the mesh's (``mesh_egress_default``: an image's
  ``--egress-vpn FILE``, a Docker mesh's egress-vpn service + its conf).

WHAT EACH ROUTE DOES WITH THEM — measured, said by ``plain_words.WAY_EFFECT`` and
decided by ``core/reach_apply``: the Docker mesh runs ONE egress container that
carries only Mastodon's outbound delivery, so the egress of the domains that run its
one Mastodon decides that container (applied at start); it joins its VPN as one
machine, so a per-domain VPN choice is not applied. No builder reads a manifest row's
``ways``, and the kind lane applies neither. Tor is different: a domain's own onion
RUNS on the Docker mesh. A mesh-wide Tor switch is NOT inherited as a per-domain
onion — turning Tor on for a mesh gives the mesh its one address, and minting an
onion for every domain because of it would change every existing Tor mesh; a domain
without its own onion is reached through the mesh's.
"""
from __future__ import annotations

import os
import re
from typing import NamedTuple

from .egress_conf import validate_egress_conf

__all__ = [
    "WAY_TAILNET", "WAY_EGRESS", "REACH_INHERIT", "EGRESS_VPN", "EGRESS_DIRECT",
    "EGRESS_MODES", "EGRESS_KEYS", "REACH_FROM_MESH", "REACH_OWN",
    "TailnetChoice", "EgressChoice",
    "tailnet_problems", "egress_problems", "mesh_tailnet_default", "mesh_egress_default",
    "effective_tailnet", "effective_egress", "egress_conf_problems", "reach_words",
]

#: The two ``ways`` keys this module owns.
WAY_TAILNET = "tailnet"
WAY_EGRESS = "egress"

#: What a screen passes to ``brand_model.set_ways(tailnet=..., egress=...)`` to take a
#: domain back to the mesh's value (removes the key). None there means "leave it".
REACH_INHERIT = "inherit"

EGRESS_VPN = "vpn"
EGRESS_DIRECT = "direct"
EGRESS_MODES: tuple[str, ...] = (EGRESS_VPN, EGRESS_DIRECT)
EGRESS_KEYS: tuple[str, ...] = ("mode", "conf")

#: Text that is a provider FILE'S CONTENTS, never a path to it: a WireGuard or OpenVPN
#: section or key line, or a PEM block. Pasted into the path field, it would be key
#: material in a shared record.
_CONF_CONTENTS_RE = re.compile(
    r"(?i)privatekey|presharedkey|\[(interface|peer)\]|<(key|cert|ca|tls-auth|tls-crypt)>"
    r"|-----BEGIN ")

#: Where an effective value came from, in the words the look's sources use.
REACH_FROM_MESH = "inherited from the mesh"
REACH_OWN = "this domain's own"


class TailnetChoice(NamedTuple):
    on: bool
    source: str          # REACH_FROM_MESH | REACH_OWN


class EgressChoice(NamedTuple):
    mode: str            # EGRESS_VPN | EGRESS_DIRECT
    conf: str            # the provider file (a path); "" with mode direct
    source: str          # REACH_FROM_MESH | REACH_OWN


def _ways(row) -> dict:
    w = row.get("ways") if isinstance(row, dict) else getattr(row, "ways", None)
    return w if isinstance(w, dict) else {}


# ── shape checks (brand_model.ways_problems calls these) ─────────────────────────────
def tailnet_problems(value, where: str) -> list[str]:
    if value is None or isinstance(value, bool):
        return []
    return [f"{where}: ways.tailnet must be yes or no (true/false)"]


def egress_problems(value, where: str) -> list[str]:
    """Why an egress block cannot be saved ([] when it can): an object with a known
    ``mode`` and, for ``vpn`` only, an optional ``conf`` that is an absolute path to a
    provider file — a pointer, never the key text (no newline, no control character)."""
    if value is None:
        return []
    if not isinstance(value, dict):
        return [f"{where}: ways.egress must be an object with a mode "
                f"({' or '.join(EGRESS_MODES)})"]
    out: list[str] = []
    for k in value:
        if k not in EGRESS_KEYS:
            out.append(f"{where}: unknown egress field ‘{k}’ ({', '.join(EGRESS_KEYS)})")
    mode = value.get("mode")
    if mode not in EGRESS_MODES:
        out.append(f"{where}: egress mode must be {' or '.join(EGRESS_MODES)}, "
                   f"got {mode!r}")
    conf = value.get("conf", "")
    if conf is None:
        conf = ""
    if not isinstance(conf, str):
        out.append(f"{where}: egress conf must be a path to the provider file")
    elif conf:
        if mode == EGRESS_DIRECT:
            out.append(f"{where}: egress is direct, so a provider file would never be "
                       "read; clear it or choose the VPN")
        if _CONF_CONTENTS_RE.search(conf):
            out.append(f"{where}: egress conf holds what looks like the provider file's "
                       "contents; give the path to the file instead (the record is "
                       "shared, key material never goes in it)")
        elif any(ord(c) < 32 or ord(c) == 127 for c in conf):
            out.append(f"{where}: egress conf must be a path on one line (a pointer to "
                       "the provider file, never its contents)")
        elif not os.path.isabs(os.path.expanduser(conf)):
            out.append(f"{where}: egress conf must be an absolute path, got {conf!r}")
    return out


# ── the mesh-wide defaults ────────────────────────────────────────────────────────────
def mesh_tailnet_default(mesh) -> bool:
    """Whether the MESH joins its VPN (tailnet): a local Docker mesh in production
    (the overlay attaches there; a test mesh is LAN-only), a node image in mesh mode,
    a fleet when it names a headscale server. None or anything else: no."""
    if mesh is None:
        return False
    if callable(getattr(mesh, "is_prod", None)) and hasattr(mesh, "egress_vpn_conf"):
        return bool(mesh.is_prod())
    if hasattr(mesh, "mode"):
        return (getattr(mesh, "mode", "") or "") == "mesh"
    return bool((getattr(mesh, "headscale_url", "") or "").strip())


def mesh_egress_default(mesh) -> EgressChoice:
    """The MESH's egress: a local Docker mesh's egress-vpn service with its provider
    file, or an image's ``--egress-vpn FILE``; otherwise direct."""
    if mesh is not None and callable(getattr(mesh, "effective_egress_vpn", None)):
        if mesh.effective_egress_vpn():
            return EgressChoice(EGRESS_VPN, (mesh.egress_vpn_conf or "").strip(),
                                REACH_FROM_MESH)
        return EgressChoice(EGRESS_DIRECT, "", REACH_FROM_MESH)
    conf = (getattr(mesh, "egress_vpn", "") or "").strip() if mesh is not None else ""
    if conf:
        return EgressChoice(EGRESS_VPN, conf, REACH_FROM_MESH)
    return EgressChoice(EGRESS_DIRECT, "", REACH_FROM_MESH)


# ── the resolvers ─────────────────────────────────────────────────────────────────────
def effective_tailnet(row, mesh=None) -> TailnetChoice:
    """This domain's VPN membership: its own ``ways.tailnet`` when set, else the
    mesh's."""
    v = _ways(row).get(WAY_TAILNET)
    if isinstance(v, bool):
        return TailnetChoice(v, REACH_OWN)
    return TailnetChoice(mesh_tailnet_default(mesh), REACH_FROM_MESH)


def effective_egress(row, mesh=None) -> EgressChoice:
    """This domain's egress: its own ``ways.egress`` when set (a ``vpn`` with no file
    of its own uses the mesh's file), else the mesh's."""
    v = _ways(row).get(WAY_EGRESS)
    if isinstance(v, dict) and v.get("mode") in EGRESS_MODES:
        if v["mode"] == EGRESS_DIRECT:
            return EgressChoice(EGRESS_DIRECT, "", REACH_OWN)
        conf = str(v.get("conf") or "").strip()
        if not conf:
            conf = mesh_egress_default(mesh).conf
        return EgressChoice(EGRESS_VPN, conf, REACH_OWN)
    return mesh_egress_default(mesh)


def egress_conf_problems(rows, mesh=None) -> list[str]:
    """The FILE check for every domain whose own egress names a provider file: it must
    exist and look like a WireGuard or OpenVPN client file (``validate_egress_conf``,
    the stack container's own sniff rules), and a ``vpn`` with no file of its own
    needs the mesh to have one. Run where a mesh is about to start (the files are on
    this computer), never at save."""
    out: list[str] = []
    for r in rows or ():
        v = _ways(r).get(WAY_EGRESS)
        if not isinstance(v, dict) or v.get("mode") != EGRESS_VPN:
            continue
        name = str((r.get("name") if isinstance(r, dict) else getattr(r, "name", ""))
                   or "").strip() or "a domain"
        conf = str(v.get("conf") or "").strip()
        if not conf:
            if not mesh_egress_default(mesh).conf:
                out.append(f"{name}: its egress goes through a VPN but neither it nor "
                           "the mesh names a provider file")
            continue
        _kind, err = validate_egress_conf(os.path.expanduser(conf))
        if err:
            out.append(f"{name}: egress provider file: {err}")
    return out


def reach_words(row, mesh=None) -> dict[str, str]:
    """{way: one plain line} for a domain's VPN and egress, each saying where its value
    came from — what a screen shows next to the controls."""
    t = effective_tailnet(row, mesh)
    e = effective_egress(row, mesh)
    egress = ("direct" if e.mode == EGRESS_DIRECT else
              f"through the egress VPN ({os.path.basename(e.conf) if e.conf else 'no provider file yet'})")
    return {
        WAY_TAILNET: f"{'on' if t.on else 'off'} — {t.source}",
        WAY_EGRESS: f"{egress} — {e.source}",
    }
