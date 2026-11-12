"""The "Domain CA keys" step, TUI face (the twin of gui/pages/domain_ca_keys.py).

Same rows, same imports, same refusals and the same go-live checklist, all from
:mod:`core.domain_ca_keys`. The GUI picks files through dialogs and types the
passphrase into a masked field; here the operator types paths, and a passphrase is
read from a FILE (``pass=FILE``) so it never appears on the screen or in a
scrollback. The TUI does not run builds, so what it holds lasts for this TUI process
only, and the Build screen of the GUI asks for the CA again (keys are never saved).
"""
from __future__ import annotations

import os
import shlex

from ..core import domain_ca_keys as dca
from ..core.worklist_driver import node_key_profiles

#: command letter -> what it does (rendered, and pinned against the GUI buttons).
COMMANDS = (
    ("k N CERT [KEY] [pass=FILE]",
     "import row N's signing CA: certificate, plus its private key on the mesh's "
     "own row (another domain takes the certificate only)"),
    ("p N FILE.p12 [pass=FILE]", "import row N's signing CA from a PKCS#12 file"),
    ("r N ROOT", "set row N's root CA certificate (a root key is never taken)"),
    ("x N", "remove row N's CA"),
    ("Enter", "keep these and continue"),
)


def _passphrase(tokens: list[str]) -> tuple[list[str], str | None]:
    """Split a ``pass=FILE`` token off; the passphrase is the file's first line."""
    rest, pw = [], None
    for t in tokens:
        if t.startswith("pass="):
            path = os.path.expanduser(t[5:])
            try:
                with open(path, encoding="utf-8") as fh:
                    pw = fh.readline().rstrip("\r\n")
            except OSError as e:
                raise dca.CAImportError(
                    f"cannot read the passphrase file: {e.strerror or e}") from None
        else:
            rest.append(t)
    return rest, pw


class DomainCAKeysScreen:
    slug = dca.STEP_SLUG
    title = dca.STEP_TITLE

    def enter(self, j) -> None:
        dca.rekey_own(j.cfg)

    def table(self, j) -> tuple[list[str], list[list[str]]]:
        return list(dca.TABLE_HEADERS), dca.row_cells(
            j.cfg, dca.store(), node_key_profiles(getattr(j, "worklist", None)))

    def checklist_lines(self, j) -> list[str]:
        return dca.readiness_lines(j.cfg, dca.store(),
                                   node_key_profiles(getattr(j, "worklist", None)))

    def lines(self, j) -> list[str]:
        headers, rows = self.table(j)
        out = [dca.STEP_SUBTITLE, ""]
        out.append("  #  " + " | ".join(headers))
        for i, row in enumerate(rows, 1):
            out.append(f"  {i}. " + " | ".join(row))
        out.append("")
        out += self.checklist_lines(j)
        prob = dca.crypto_problem()
        if prob:
            out += ["", "Cannot take a CA key: " + prob]
        out += ["", "commands:"]
        out += [f"  {c:<28} {what}" for c, what in COMMANDS]
        out += ["", "Not taken here:"]
        out += [f"  {what}: {why}" for what, why in dca.NOT_TAKEN]
        return out

    def prompt(self, j) -> str:  # noqa: ARG002
        return "ca> "

    def feed(self, j, line: str) -> None:
        if line.strip() == "":
            j.advance()
            return
        try:
            tokens = shlex.split(line)
        except ValueError as e:
            j.status = f"unreadable command: {e}"
            return
        cmd, args = tokens[0].lower(), tokens[1:]
        if cmd not in ("k", "p", "r", "x"):
            j.status = (f"unrecognised command: {line!r} (k/p/r/x edit a row, Enter "
                        "continues, q quits)")
            return
        rows = dca.domain_rows(j.cfg)
        try:
            n = int(args[0]) if args else 0
        except ValueError:
            n = 0
        if not 1 <= n <= len(rows):
            j.status = f"no such row: {args[0] if args else '(none)'}"
            return
        domain, own = rows[n - 1]
        args = args[1:]
        st = dca.store()
        try:
            args, pw = _passphrase(args)
            if cmd == "x":
                j.status = (f"removed the CA for {domain or 'this mesh'}"
                            if dca.remove(st, domain) else "nothing to remove")
                return
            if cmd == "k":
                if not args:
                    raise dca.CAImportError("k needs the certificate file"
                                            + (" and the key file" if own else ""))
                e = dca.import_signing(st, domain, own, cert_path=args[0],
                                       key_path=args[1] if len(args) > 1 else "",
                                       passphrase=pw)
            elif cmd == "p":
                if not args:
                    raise dca.CAImportError("p needs the PKCS#12 file")
                e = dca.import_signing(st, domain, own, p12_path=args[0],
                                       passphrase=pw)
            else:
                if not args:
                    raise dca.CAImportError("r needs the root certificate file")
                e = dca.import_root(st, domain, own, args[0])
        except dca.CAImportError as err:
            j.status = f"refused: {err}"
            return
        extra = "" if not e.warnings else " (note: " + "; ".join(e.warnings) + ")"
        j.status = (f"imported for {e.domain or 'this mesh'}: "
                    f"{e.signing_name or e.root_name}{extra}")
