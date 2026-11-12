"""The TUI face of ISSUING HugMesh tokens — the text twin of the GUI's "Issue a HugMesh
token…" dialog (``gui/mesh_token_issue_dialog.py``), over the same Qt-free core
(:mod:`core.mesh_token`).

OPERATOR ASK (2026-11-04): "make sure locally created mesh can also generate tokens
through both the web ui and the gui/tui/cli on all platforms". Reached from the Local
Docker mesh screens with ``t`` (its first screen and its review), so the admin of a mesh
created here can share it from a terminal on Linux, Windows and macOS alike.

What is the same as the dialog and the CLI, by construction: the roles are
``mesh_token.ROLES``, shell access is offered only to ``mesh_token.SHELL_ROLES``, a
lifetime is at most ``mesh_token.MAX_LIFETIME_S``, every field is checked by the core's
own ``check_fields`` BEFORE an issuer key is created, and the token is signed with the
Studio's issuer key for the mesh (``ensure_issuer``, created and trusted on first use)
by ``issue(interactive=False)``. test_tui_mesh_token.py and test_tui_gui_parity.py pin
the three faces together.

What is deliberately different:

* MINTING. The TUI never starts docker (the rule the emulation screens follow: whatever
  would spawn a container is printed as a copy-ready command). With ``mint`` the screen
  prints the ``--mesh-token issue --mint`` line that mints the single-use pre-auth key in
  the mesh's running headscale container and signs, in one run, on the command line.
  The headscale user is optional (``u USER`` adds ``--headscale-user``): without it the
  CLI mints for the container's ``net.hugmesh.headscale.user`` label, else ``hugmesh``,
  and the screen says so. Signing alone (``ssh-keygen -Y sign``, a second or so) does
  run here.
* THE PRE-AUTH KEY is never typed into this screen: the line would stay on the screen
  and in the terminal's scrollback. It is read from a file (``k PATH``), as the CLI's
  ``--authkey-file`` reads it, at the moment of signing, and is not kept afterwards.
"""
from __future__ import annotations

import argparse
import os
import time
from typing import Callable, Optional

from ..core import mesh_token as mt

__all__ = ["MeshTokenScreen", "TITLE", "FINGERPRINT_NOTE", "SHELL_ONLY_TIP",
           "NO_KEY", "MINT_NOTE", "DEFAULT_USER", "lifetime_text", "mint_argv", "mint_line",
           "login_hint", "LOGIN_EMPTY"]

#: The dialog's title, word for word (test_tui_gui_parity pins it).
TITLE = "Issue a HugMesh token"

#: Said under the issuer fingerprint, every time a token is shown — the dialog's
#: sentence, word for word (pinned).
FINGERPRINT_NOTE = (
    "Send the recipient this fingerprint separately from the token (in person, by "
    "phone, or in a message you trust): their tray asks them to compare it before it "
    "trusts this issuer.")

#: The dialog's sentence for a role that cannot hold shell access (pinned).
SHELL_ONLY_TIP = (f"Only {' and '.join(mt.SHELL_ROLES)} can hold shell access; the token "
                  "for any other role is refused if it claims it.")

NO_KEY = ("Give the file holding the headscale pre-auth key the token should carry "
          "(k PATH), or choose mint to mint one from the mesh's running headscale.")

MINT_NOTE = ("This screen does not start docker. Run this line in a terminal: it mints a "
             "single-use pre-auth key in the mesh's running headscale container (the one "
             "labelled or named like headscale unless c NAME names it), expiring with the "
             "token, for the headscale user shown above, and prints the signed token. "
             "Nothing secret is on it.")

#: The headscale user row while u USER names none: which default the line mints for.
DEFAULT_USER = (f"default: the container's {mt.HEADSCALE_USER_LABEL} label, else "
                f"{mt.DEFAULT_MINT_USER} (u USER names another)")

DEFAULT_LIFETIME_S = 7 * 86400

#: The login server row while none is typed: both forms a login server can take.
LOGIN_EMPTY = "(type it: l URL — https://hs.example.org or http://<56 characters>.onion)"


def login_hint(url: str, domain: str) -> str:
    """The line said under the login server: :func:`core.mesh_token.login_server_hint`
    (the same words in the window, the text interface and the command line)."""
    return mt.login_server_hint(url, domain)


def lifetime_text(seconds: int) -> str:
    """A lifetime the way the CLI's ``--expires`` spells it (7d, 12h, 90m)."""
    for unit, size in (("d", 86400), ("h", 3600)):
        if seconds % size == 0:
            return f"{seconds // size}{unit}"
    return f"{max(1, seconds // 60)}m"


def mint_argv(fields: dict, *, user: str = "", container: str = "",
              osname: Optional[str] = None) -> list[str]:
    """The Studio CLI argv that mints the pre-auth key and signs, for ``fields`` (the
    screen's own; ``node_name`` is never set here, as in the dialog). The program is how
    a person runs THIS Studio's CLI on this platform (the MSI's console twin on Windows,
    the module from a checkout) — the one author org_export's lines use too."""
    from ..core.org_export import _studio_cli
    argv = [*_studio_cli(osname), "--mesh-token", "issue",
            "--mesh", fields["mesh"], "--domain", fields["domain"],
            "--role", fields["role"]]
    if fields["shell"]:
        argv.append("--shell")
    argv += ["--login-server", fields["login_server"], "--mint",
             "--expires", lifetime_text(fields["lifetime_s"])]
    if container:
        argv += ["--headscale-container", container]
    if user:
        argv += ["--headscale-user", user]
    return argv


def mint_line(fields: dict, *, user: str = "", container: str = "",
              osname: Optional[str] = None) -> str:
    """:func:`mint_argv` as one line to paste (PowerShell's quoting on Windows)."""
    from ..core.org_export import _terminal_line
    return _terminal_line(mint_argv(fields, user=user, container=container,
                                    osname=osname), osname)


class MeshTokenScreen:
    """An overlay: fill in what the token grants, say where the pre-auth key comes
    from, ``i`` issues. ``prefill(j)`` gives ``{mesh, domain, login_server}`` on entry
    (any may be ""); ``on_back(j)`` leaves (default: close the overlay)."""

    slug = "mesh_token"
    title = TITLE
    #: q and b both mean BACK here, never "quit the Studio" with a token on screen.
    wants_q = True

    def __init__(self, prefill: Optional[Callable] = None,
                 on_back: Optional[Callable] = None, *, keygen: Optional[str] = None):
        self._prefill = prefill
        self._on_back = on_back
        self._keygen = keygen
        self.mesh = ""
        self.domain = ""
        self.role = mt.ROLES[0]
        self.shell = False
        self.login_server = ""
        self.lifetime_s = DEFAULT_LIFETIME_S
        #: "file" (k PATH, signed here) or "mint" (the CLI line)
        self.source = "file"
        self.key_file = ""
        self.hs_user = ""
        self.hs_container = ""
        self.token = ""
        self.result: list[str] = []

    # ── the fields ──────────────────────────────────────────────────────────────
    @staticmethod
    def roles() -> tuple[str, ...]:
        return mt.ROLES

    @staticmethod
    def shell_allowed(role: str) -> bool:
        return role in mt.SHELL_ROLES

    @staticmethod
    def valid_mesh(name: str) -> bool:
        """Whether ``name`` is a mesh name a token (and an issuer key) can carry."""
        return bool(mt._MESH_RE.match(name or ""))

    def fields(self) -> dict:
        return dict(mesh=self.mesh, domain=self.domain, role=self.role,
                    shell=self.shell and self.shell_allowed(self.role),
                    login_server=self.login_server, lifetime_s=self.lifetime_s,
                    node_name="")

    def problem(self, auth_key: str = "not-yet-minted") -> str:
        """Why these fields cannot be signed, or "". The core's own checks — the same
        the dialog and the CLI make before anything is created or minted."""
        try:
            mt.issuer_dir(self.mesh)
            mt._new_grant(issuer="ssh-ed25519 AAAA", auth_key=auth_key,
                          now=int(time.time()), **self.fields())
        except mt.TokenError as e:
            return str(e)
        return ""

    def _clear_result(self) -> None:
        self.token = ""
        self.result = []

    # ── screen protocol ─────────────────────────────────────────────────────────
    def enter(self, j) -> None:
        self._clear_result()
        pre = (self._prefill(j) if self._prefill else None) or {}
        for name in ("mesh", "domain", "login_server"):
            value = (pre.get(name) or "").strip()
            if value:
                setattr(self, name, value)

    def prompt(self, j) -> str:  # noqa: ARG002
        return "mesh-token> "

    def lines(self, j) -> list[str]:  # noqa: ARG002
        roles = " · ".join(f"{i} {r}" for i, r in enumerate(self.roles(), 1))
        shell = ("yes" if self.shell else "no") if self.shell_allowed(self.role) \
            else f"no ({SHELL_ONLY_TIP})"
        if self.source == "mint":
            key = "minted by the command line below"
        elif self.key_file:
            key = f"read from {self.key_file} when the token is signed"
        else:
            key = "(none yet: k PATH, or mint)"
        out = ["Sign a token that lets someone's tray join this mesh in one access "
               "domain, as one role, with or without shell access. It is signed with "
               "this Studio's issuer key for the mesh (created on first use, and "
               "trusted by this computer).", "",
               f"  mesh           {self.mesh or '(type it: m NAME)'}",
               f"  access domain  {self.domain or '(type it: d DOMAIN)'}",
               f"  role           {self.role}   ({roles})",
               f"  shell access   {shell}",
               f"  login server   {self.login_server or LOGIN_EMPTY}"]
        # the window's inline line under Login server, word for word
        hint = login_hint(self.login_server, self.domain)
        if hint:
            out.append(f"                 {hint}")
        out += [f"  lifetime       {lifetime_text(self.lifetime_s)} (at most "
                f"{mt.MAX_LIFETIME_S // 86400}d)",
                f"  pre-auth key   {key}"]
        if self.source == "mint":
            out.append(f"  headscale user {self.hs_user or DEFAULT_USER}")
            found = "(the running one labelled or named like headscale)"
            out.append(f"  headscale container {self.hs_container or found}")
        out.append("")
        if self.source == "mint":
            why = self.problem()
            if why:
                out += [f"Not ready: {why}", ""]
            else:
                out += [MINT_NOTE, "  " + mint_line(self.fields(), user=self.hs_user,
                                                    container=self.hs_container), ""]
        out += self.result
        if self.result:
            out.append("")
        out += ["commands: m NAME=mesh · d DOMAIN=access domain · r N|ROLE=role · s=shell "
                "access on/off · l URL=login server (https://host[:port], or a Tor v3 onion "
                "http(s)://<56 characters>.onion[:port]) · e 7d|12h="
                "lifetime · k PATH=the pre-auth key's file · mint=mint it instead (prints "
                "the command) · u USER|-=headscale user for mint (optional) · "
                "c NAME|-=headscale container for mint · i=issue (sign) · "
                "w PATH=save the issued token to a file · b=back",
                "The pre-auth key is never typed here (it would stay on the screen): put "
                "it in a file and give the path, as the CLI's --authkey-file does."]
        return out

    def feed(self, j, line: str) -> None:
        line = line.strip()
        verb, _, arg = line.partition(" ")
        verb, arg = verb.lower(), arg.strip()
        if verb in ("b", "q") and not arg:
            self._clear_result()
            if self._on_back is not None:
                self._on_back(j)
            elif getattr(j, "overlay", None) is self:
                j.close_overlay()
            return
        if line == "":
            return
        if verb == "i" and not arg:
            self._issue(j)
            return
        if verb == "w":
            self._save(j, arg)
            return
        if verb == "mint" and not arg:
            self.source = "mint"
            self._clear_result()
            return
        if verb == "s" and not arg:
            if not self.shell_allowed(self.role):
                self.shell = False
                j.status = SHELL_ONLY_TIP
                return
            self.shell = not self.shell
            self._clear_result()
            return
        if not arg:
            j.status = (f"{verb} needs a value" if verb in "mdrlekuwc" and len(verb) == 1
                        else f"unrecognised command: {line!r}")
            return
        if verb == "m":
            self.mesh = arg.lower()
        elif verb == "d":
            self.domain = arg.lower().strip(".")
        elif verb == "r":
            role = arg.lower()
            if arg.isdigit() and 1 <= int(arg) <= len(self.roles()):
                role = self.roles()[int(arg) - 1]
            if role not in self.roles():
                j.status = f"no such role: {arg!r} (one of {', '.join(self.roles())})"
                return
            self.role = role
            if not self.shell_allowed(role):
                self.shell = False
        elif verb == "l":
            self.login_server = arg
        elif verb == "e":
            try:
                seconds = mt._lifetime(arg)
            except argparse.ArgumentTypeError as e:
                j.status = f"not a lifetime: {arg!r} ({e})"
                return
            if not 0 < seconds <= mt.MAX_LIFETIME_S:
                j.status = (f"a token lives between a moment and "
                            f"{mt.MAX_LIFETIME_S // 86400} days")
                return
            self.lifetime_s = seconds
        elif verb == "k":
            self.key_file = os.path.expanduser(arg)
            self.source = "file"
        elif verb == "u":
            if arg != "-" and not mt._NAME_RE.match(arg):
                j.status = f"{arg!r} is not a headscale user name"
                return
            self.hs_user = "" if arg == "-" else arg
        elif verb == "c":
            if arg != "-" and not mt._NAME_RE.match(arg):
                j.status = f"{arg!r} is not a container name"
                return
            self.hs_container = "" if arg == "-" else arg
        else:
            j.status = f"unrecognised command: {line!r}"
            return
        self._clear_result()

    # ── issuing ─────────────────────────────────────────────────────────────────
    def _issue(self, j) -> None:
        self._clear_result()
        if self.source == "mint":
            why = self.problem()
            j.status = (why or "This screen does not start docker: run the line above in "
                               "a terminal to mint the key and sign.")
            return
        if not self.key_file:
            j.status = NO_KEY
            return
        why = self.problem()
        if why:
            j.status = why
            return
        try:
            with open(self.key_file, encoding="utf-8") as fh:
                auth_key = fh.read().strip()
        except OSError as e:
            j.status = f"The pre-auth key file could not be read: {e}"
            return
        if not auth_key:
            j.status = f"{self.key_file} is empty: it should hold the pre-auth key."
            return
        fields = self.fields()
        try:
            # every field again WITH the real key (whitespace inside it is refused
            # here, before an issuer key is created)
            why = self.problem(auth_key)
            if why:
                j.status = why
                return
            existed = os.path.isfile(mt.issuer_key_path(fields["mesh"]))
            key_path, _line, fp = mt.ensure_issuer(fields["mesh"], keygen=self._keygen)
            token = mt.issue(key_path=key_path, auth_key=auth_key, interactive=False,
                             keygen=self._keygen, **fields)
        except mt.TokenError as e:
            j.status = str(e)
            return
        except Exception as e:                       # noqa: BLE001 — never kill the TUI
            j.status = f"The token could not be issued: {e}"
            return
        self.token = token
        grant = mt.parse(token)[0].describe()
        self.result = [
            "Token (give it to the recipient; line breaks in it do not matter):",
            token, "",
            f"Issuer fingerprint: {fp}"
            + ("" if existed else " (this issuer key was created now; this computer "
                                  "trusts it)"),
            FINGERPRINT_NOTE, "",
            f"Issued: {grant}. {mt.SERVER_DECIDES} The token carries "
            f"the pre-auth key now, so {self.key_file} is not needed for this token; a "
            "reusable key stays valid until it expires or is expired in headscale."]

    def _save(self, j, path: str) -> None:
        if not self.token:
            j.status = "nothing to save yet: i issues a token first"
            return
        if not path:
            j.status = "w needs the path of the file to save the token in"
            return
        path = os.path.abspath(os.path.expanduser(path))
        try:
            # the token carries the pre-auth key: a file only this user can read
            mt._write_private(path, self.token + "\n")
        except OSError as e:
            j.status = f"The token could not be saved: {e}"
            return
        j.status = (f"saved the token to {path} (mode 0600). " if os.name != "nt"
                    else f"saved the token to {path}. ") + (
            "It carries the pre-auth key: keep it private and delete it once it is sent.")
