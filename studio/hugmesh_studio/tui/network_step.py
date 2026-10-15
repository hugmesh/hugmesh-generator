"""The Network step — the TUI twin of the anubis row on ``gui/pages/network.py`` (#384).

Only that ONE row is ported, and the screen says so: the rest of the step (domain, tailnet,
egress, security stack, the other services) keeps its defaults, as every un-ported step
does (``PendingStep``). The row is the same three-valued choice the GUI shows as a
dropdown — Default / Force on / Force off — written to the same field
(``ImageConfig.anubis``), with the same words (``config.ANUBIS_LABELS``) and the same
lock: a whole-set selection (``--all-services`` or "no services at all") replaces the list
the choice rides in, so there the row reads Default and ``config.anubis_locked`` says why.

Why it is real rather than a stub: the other half of #384 gave Studio a field that can
say "anubis off", and a face that cannot set it would leave a prod mesh's public
proof-of-work gate decided by the build's ENV with no way to say otherwise from the TUI.
"""
from __future__ import annotations

from ..core.config import (
    ANUBIS_CHOICES, ANUBIS_LABELS, PLATFORM_FIELD_SUPPORT, SERVICE_DESCRIPTIONS,
    anubis_locked, anubis_shown, services_picker_hidden,
)

#: What each command word sets. Longest spelling first is irrelevant (exact match).
_WORDS = {"d": "", "default": "", "on": "on", "off": "off"}

NOT_PORTED_NOTE = ("Only the anubis row of this step is ported to the TUI — configure "
                   "the rest of it (domain, tailnet, egress, the other services) in the "
                   "GUI (python -m hugmesh_studio); Enter keeps their defaults and "
                   "continues.")


def anubis_applies(cfg) -> str:
    """"" when the anubis row applies to ``cfg``, else the reason it does not — the
    same cases the GUI row is absent for: a platform whose builder parses no
    ``--optional-services``, and an image whose cluster-services picker the GUI hides
    (``config.services_picker_hidden``: the unaffiliated role, or a standalone
    CLIENT-class desktop). A standalone rpi5 'generic' is a cluster node that bakes the
    tree, so the row applies there, as it does on the GUI."""
    if (getattr(cfg, "platform", "") or "x86") not in PLATFORM_FIELD_SUPPORT["anubis"]:
        return f"the {cfg.platform} builder has no --optional-services"
    if services_picker_hidden(cfg):
        return "this image bakes no cluster services"
    return ""


class NetworkScreen:
    """``1`` cycles the anubis row; ``default`` / ``on`` / ``off`` set it; Enter continues.
    Enter also settles the field: a row that does not apply, or is locked by a whole-set
    selection, collects Default (the GUI's ``validatePage`` does the same)."""

    slug = "network"
    title = "Network"

    def enter(self, j) -> None:  # noqa: ARG002 — protocol signature
        return None

    @staticmethod
    def _state(cfg) -> tuple[str, str]:
        """``(value shown, why it cannot be changed or "")``."""
        why = anubis_applies(cfg)
        if why:
            return "", why
        if anubis_locked(cfg.optional_services):
            return "", ("locked by the whole-set services selection — pick services "
                        "individually in the GUI to force it")
        return anubis_shown(cfg), ""

    def lines(self, j) -> list[str]:
        from . import model
        value, why = self._state(j.cfg)
        label = ANUBIS_LABELS[value] + (f" ({why})" if why else "")
        out = [NOT_PORTED_NOTE, "",
               *model.format_table(["#", "service", "choice"], [["1", "anubis", label]]),
               "", SERVICE_DESCRIPTIONS["anubis"], ""]
        out.append("Default leaves anubis to the build; Force on and Force off say it "
                   "either way." if not why else
                   "This row cannot be changed here: " + why + ".")
        out.append("commands: 1=cycle · default · on · off · Enter=continue")
        return out

    def prompt(self, j) -> str:  # noqa: ARG002
        return "network> "

    def feed(self, j, line: str) -> None:
        cfg = j.cfg
        word = line.strip().lower()
        if word == "":
            if self._state(cfg)[1]:
                cfg.anubis = ""
            j.advance()
            return
        value, why = self._state(cfg)
        if why:
            j.status = f"anubis: not changed — {why}"
            return
        if word == "1":
            new = ANUBIS_CHOICES[(ANUBIS_CHOICES.index(value) + 1) % len(ANUBIS_CHOICES)]
        elif word in _WORDS:
            new = _WORDS[word]
        else:
            j.status = (f"unrecognised command: {line.strip()!r} "
                        "(1 cycles; default, on or off sets it; Enter continues)")
            return
        cfg.anubis = new
        j.status = f"anubis -> {ANUBIS_LABELS[new]}"
