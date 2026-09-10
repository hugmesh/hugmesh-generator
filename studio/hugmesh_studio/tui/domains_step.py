"""The Domains step — with the per-domain Sign-in choice of GUI PR #71 (#47).

The table mirrors ``gui/pages/domains.py``: one row per ``cfg.domains`` entry,
and — MESH ONLY — the Sign-in column carrying each row's ``Domain.idp``:

* ``superdomain`` (the DEFAULT — absent in old configs, omitted from manifests):
  sign-in via the mesh's central Casdoor on the superdomain;
* ``own``: this domain runs its OWN Casdoor instance (cluster provisioning /
  the local compose lane stand it up from the manifest).

The column is hidden in cloud mode exactly as the GUI hides it (a client hosts
no Casdoor and writes no manifest), and an untouched row keeps the default so
superdomain-only manifests stay byte-identical (the schema's omit-when-default
rule — owned by core/config.py, only CONSUMED here).

MESH ONLY, and added by #335: the Base CA column, each row's entry in
``cfg.domain_ca``. It offers the certificates the Secrets store step collected into
``cfg.base_ca_certs``, hides in cloud for the same reason Sign-in does, and is
RECORDED ONLY — no builder parses a CA flag and no manifest carries the choice, so
picking one changes no image today. An untouched row writes no key at all, so a
config that never met this column round-trips byte-identically.

Title/optional-services/applies-to editing is not ported yet (honest note);
add/remove, the Sign-in toggle and the base-CA choice are, so both per-domain
choices are real TUI surfaces.
"""
from __future__ import annotations

import os
import re

from ..core.config import (
    DOMAIN_IDP_CHOICES, DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, Domain,
)
from . import model

__all__ = ["DomainsScreen", "IDP_LABELS", "domain_table"]

#: schema value -> the label the GUI combo shows (parity-pinned).
IDP_LABELS = {
    DOMAIN_IDP_SUPERDOMAIN: "Superdomain Casdoor (default)",
    DOMAIN_IDP_OWN: "Own Casdoor",
}

# a lowercase dotted hostname — the same shape the wizard's inline validators
# accept; the authoritative check stays cfg.validate_identity() at save time.
_NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")


def domain_table(cfg) -> tuple[list[str], list[list[str]]]:
    """(headers, rows) for the domains table. The Sign-in column appears ONLY
    in mesh mode — the GUI hides it in cloud for the same reason."""
    mesh = cfg.mode == "mesh"
    headers = ["#", "domain", "title", "optional services", "applies to"]
    if mesh:
        headers += ["sign-in", "base CA"]
    domain_ca = getattr(cfg, "domain_ca", None) or {}
    rows: list[list[str]] = []
    for i, d in enumerate(cfg.domains, 1):
        row = [str(i), d.name, d.title or "-",
               ", ".join(d.optional_services) or "-",
               ", ".join(d.images) or "every eligible image"]
        if mesh:
            row.append(IDP_LABELS[d.idp])
            chosen = domain_ca.get(d.name, "")
            row.append(os.path.basename(chosen) if chosen else "none")
        rows.append(row)
    return headers, rows


class DomainsScreen:
    """The domains table: add/remove rows + the per-domain Sign-in choice."""

    slug = "domains"
    title = "Domains"

    def enter(self, j) -> None:  # noqa: ARG002 — screen-protocol signature
        return None

    def lines(self, j) -> list[str]:
        cfg = j.cfg
        out = ["The go-live domains this mesh serves to browsers."
               if cfg.mode == "mesh" else
               "The domains this client image is tied to.", ""]
        if cfg.domains:
            headers, rows = domain_table(cfg)
            out += model.format_table(headers, rows)
        else:
            out.append("(no additional domains yet)")
        out.append("")
        commands = ["a NAME=add a domain", "d NUMBER=delete"]
        if cfg.mode == "mesh":
            commands.append("s NUMBER=toggle its sign-in "
                            "(Superdomain Casdoor <-> Own Casdoor)")
            commands.append("b NUMBER CERT|-=set its base CA")
        commands.append("Enter=continue")
        out.append("commands: " + " · ".join(commands))
        if cfg.mode == "mesh":
            out.append("'Sign-in' = which Casdoor serves this domain's login: "
                       "Superdomain (its users sign in via the mesh's central "
                       "Casdoor — the default) or Own (this domain runs its "
                       "own Casdoor instance).")
            certs = getattr(cfg, "base_ca_certs", None) or []
            if certs:
                out.append("'Base CA' = which certificate authority this domain "
                           "chains to. Recorded only — no builder parses a CA flag "
                           "and no manifest carries it. Available: "
                           + " · ".join(f"{i}={os.path.basename(p)}"
                                        for i, p in enumerate(certs, 1)))
            else:
                out.append("'Base CA' = which certificate authority this domain "
                           "chains to. Recorded only. No certificates yet: add them "
                           "on the Secrets store step (its 'c' command), then come "
                           "back — this step runs before that one.")
        out.append("Title/optional-services/applies-to editing is not yet "
                   "ported to the TUI — edit those columns in the GUI.")
        return out

    def prompt(self, j) -> str:  # noqa: ARG002
        return "domains> "

    def feed(self, j, line: str) -> None:
        cfg = j.cfg
        if line == "":
            j.advance()
            return
        verb, _, arg = line.partition(" ")
        verb, arg = verb.lower(), arg.strip()
        if verb == "a":
            if not _NAME_RE.match(arg):
                j.status = (f"not a domain name: {arg!r} (lowercase dotted "
                            "hostname, e.g. chat.example.org)")
                return
            if any(d.name == arg for d in cfg.domains):
                j.status = f"already listed: {arg}"
                return
            cfg.domains.append(Domain(name=arg))       # idp defaults superdomain
            return
        if verb == "d":
            row = _index(arg, len(cfg.domains))
            if row is None:
                j.status = f"no such domain row: {arg!r}"
                return
            removed = cfg.domains.pop(row)
            j.status = f"removed {removed.name}"
            return
        if verb == "s" and cfg.mode == "mesh":
            row = _index(arg, len(cfg.domains))
            if row is None:
                j.status = f"no such domain row: {arg!r}"
                return
            d = cfg.domains[row]
            flipped = (DOMAIN_IDP_OWN if d.idp == DOMAIN_IDP_SUPERDOMAIN
                       else DOMAIN_IDP_SUPERDOMAIN)
            assert flipped in DOMAIN_IDP_CHOICES
            d.idp = flipped
            j.status = f"{d.name}: sign-in -> {IDP_LABELS[d.idp]}"
            return
        if verb == "b" and cfg.mode == "mesh":
            self._feed_base_ca(j, arg)
            return
        j.status = f"unrecognised command: {line!r}"

    @staticmethod
    def _feed_base_ca(j, arg: str) -> None:
        """'b DOMAIN-NUMBER CERT-NUMBER|-' — the per-domain base CA (#335). Both
        operands are ROW NUMBERS off the two tables the operator is looking at, never
        paths: a typed path could name a certificate the config does not carry, which
        is precisely the state domain_ca_error refuses. '-' clears the choice, which
        is the same fact as never having made one (the key is deleted, not blanked)."""
        cfg = j.cfg
        certs = list(getattr(cfg, "base_ca_certs", None) or [])
        which, _, pick = arg.partition(" ")
        row = _index(which.strip(), len(cfg.domains))
        if row is None:
            j.status = f"no such domain row: {which.strip()!r}"
            return
        name = cfg.domains[row].name
        pick = pick.strip()
        if not pick:
            j.status = "b needs a certificate number (or - to clear)"
            return
        table = dict(getattr(cfg, "domain_ca", None) or {})
        if pick == "-":
            table.pop(name, None)
            cfg.domain_ca = table
            j.status = f"{name}: base CA -> none"
            return
        if not certs:
            j.status = ("no base CA certificates yet — add one on the Secrets store "
                        "step ('c PATH'), then come back")
            return
        cert = _index(pick, len(certs))
        if cert is None:
            j.status = f"no such certificate: {pick!r} (1..{len(certs)})"
            return
        table[name] = certs[cert]
        cfg.domain_ca = table
        j.status = f"{name}: base CA -> {os.path.basename(certs[cert])}"


def _index(arg: str, count: int) -> int | None:
    try:
        n = int(arg)
    except ValueError:
        return None
    return n - 1 if 1 <= n <= count else None
