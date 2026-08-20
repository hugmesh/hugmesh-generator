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

Title/optional-services/applies-to editing is not ported yet (honest note);
add/remove and the Sign-in toggle are, so the #71 choice is a real TUI surface.
"""
from __future__ import annotations

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
        headers.append("sign-in")
    rows: list[list[str]] = []
    for i, d in enumerate(cfg.domains, 1):
        row = [str(i), d.name, d.title or "-",
               ", ".join(d.optional_services) or "-",
               ", ".join(d.images) or "every eligible image"]
        if mesh:
            row.append(IDP_LABELS[d.idp])
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
        commands.append("Enter=continue")
        out.append("commands: " + " · ".join(commands))
        if cfg.mode == "mesh":
            out.append("'Sign-in' = which Casdoor serves this domain's login: "
                       "Superdomain (its users sign in via the mesh's central "
                       "Casdoor — the default) or Own (this domain runs its "
                       "own Casdoor instance).")
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
        j.status = f"unrecognised command: {line!r}"


def _index(arg: str, count: int) -> int | None:
    try:
        n = int(arg)
    except ValueError:
        return None
    return n - 1 if 1 <= n <= count else None
