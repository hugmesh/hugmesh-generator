"""The ``nvd`` commands — the TUI face of the NVD API key box (core/nvd_key.py).

Hosted by the fleet screen's options stage (next to the pen-test knobs) and by the
Go-Live org-export step, the two places the GUI shows its NvdKeyWidget. Same words
as the GUI (every sentence is a core.nvd_key constant), same store, same Verify:

* ``nvd``                 — status, why a key is needed, the request URL, the guide,
                            the activation warning and "An empty value is refused.";
* ``nvd set``             — the NEXT line is the key, typed HIDDEN: the urwid face
                            masks its Edit with ``*`` for exactly that one line and the
                            plain face reads it with getpass; it is never echoed, never
                            put in the status line, and never reaches the Local AI;
* ``nvd verify``          — one GET to NVD (the only outside call), verdict in words;
* ``nvd forget``          — delete the stored key;
* ``nvd org-secret ORG [anyway]`` — ``gh secret set NVD_API_KEY --org ORG``, the value
                            on stdin; refused for an unverified key unless ``anyway``.
"""
from __future__ import annotations

from ..core import nvd_key

__all__ = ["NvdCommands", "HELP", "SECRET_PROMPT"]

HELP = ("nvd=NVD API key status · nvd set=enter the key (hidden) · nvd verify · "
        "nvd forget · nvd org-secret ORG [anyway]")
SECRET_PROMPT = "NVD API key (hidden; not echoed)> "


class NvdCommands:
    """The ``nvd`` verbs for a host screen. The host forwards a line starting with
    ``nvd`` to :meth:`feed`, asks :meth:`secret_input` before each prompt, and
    returns :data:`SECRET_PROMPT` while it is True. ``opener``/``runner`` are the
    test seams core.nvd_key takes."""

    def __init__(self, opener=None, runner=None, org_of=None):
        self.awaiting_key = False
        self.opener = opener
        self.runner = runner
        #: the default org for ``nvd org-secret`` with none named (Go-Live: the
        #: picked domain's org), or None
        self.org_of = org_of

    @staticmethod
    def handles(line: str) -> bool:
        return line.strip().split(" ", 1)[0].lower() == "nvd"

    def secret_input(self) -> bool:
        return self.awaiting_key

    @staticmethod
    def lines() -> list[str]:
        """The block the GUI widget shows, line for line (same core strings)."""
        return ["NVD API key: " + nvd_key.status_line(), *nvd_key.info_lines(),
                nvd_key.VERIFY_CONSENT, "commands: " + HELP]

    def feed_secret(self, j, line: str) -> None:
        """The hidden line after ``nvd set``. Whatever happens, the mode ends here and
        the line itself is never repeated back."""
        self.awaiting_key = False
        try:
            st = nvd_key.save(line)
        except nvd_key.NvdKeyError as e:
            j.status = f"not saved — {e.sentence}"
            return
        except OSError as e:
            j.status = f"not saved — {e.strerror or e}"
            return
        j.status = ("NVD API key: " + nvd_key.status_line(st)
                    + " — type nvd verify to check it with NVD. "
                    + nvd_key.ACTIVATION_WARNING)

    def feed(self, j, line: str) -> None:
        words = line.strip().split()
        verb = words[1].lower() if len(words) > 1 else ""
        if verb == "":
            j.status = "\n".join(self.lines())
            return
        if verb == "set":
            if len(words) > 2:
                # a key typed on the command line would sit in the terminal's
                # scrollback: refused, and not stored
                j.status = ("refused: the key is never typed after 'nvd set' — type "
                            "'nvd set' alone, then the key on the hidden line.")
                return
            self.awaiting_key = True
            j.status = nvd_key.NEED_LINE + " " + nvd_key.EMPTY_REFUSED
            return
        if verb == "verify":
            raw = nvd_key.load()
            if not raw:
                j.status = (f"{nvd_key.VERDICT_LABELS[nvd_key.MISSING]}: no key stored — "
                            f"nvd set first. Request one at {nvd_key.REQUEST_URL}")
                return
            res = nvd_key.verify(raw, opener=self.opener)
            nvd_key.record_verdict(res)
            j.status = res.checked_line()
            return
        if verb == "forget":
            j.status = ("NVD API key forgotten." if nvd_key.forget()
                        else "No NVD API key was stored.")
            return
        if verb == "org-secret":
            rest = words[2:]
            anyway = bool(rest) and rest[-1].lower() == "anyway"
            if anyway:
                rest = rest[:-1]
            org = rest[0] if rest else (self.org_of(j) if self.org_of else "")
            res = nvd_key.push_org_secret(org, runner=self.runner, set_anyway=anyway)
            j.status = res.sentence if res.ok else f"not set — {res.sentence}"
            return
        j.status = f"unrecognised nvd command: {verb!r} ({HELP})"
