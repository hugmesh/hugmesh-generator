"""The "Issue a HugMesh token…" dialog — the ISSUING side of core/mesh_token.py, for the
admin of a mesh created locally with the Studio.

OPERATOR ASK (2026-11-04): "make sure locally created mesh can also generate tokens
through both the web ui and the gui/tui/cli on all platforms". The CLI is
``python -m hugmesh_studio.core.mesh_token issue``; this is the GUI's door, reached
from the tray's mesh section and from the Local mesh page's Actions.

Every decision is the core's: the fields are checked by the same ``check_fields`` the
CLI and the verifier use (before anything is created or minted, so a typo never leaves
a minted pre-auth key on the server), the token is signed with the Studio's issuer key
for the mesh (:func:`core.mesh_token.ensure_issuer`, created and trusted on first use),
and a minted key comes from :func:`core.mesh_token.mint_preauth_key`. Everything that
runs a process (the headscale container probe, ssh-keygen, docker exec) runs on a
QThread, never on the GUI thread.

SECRETS. A pasted pre-auth key sits in a password-echo field and is cleared once a
token is issued; a minted one never reaches a widget at all, only the token. Neither
is logged, and the token itself is shown only in this dialog's read-only box.
"""
from __future__ import annotations

import os
import time

from .qt import QtCore, QtWidgets, Signal
from ..core import mesh_token as mt
from .pages._widgets import own_probe, probe_running

TITLE = "Issue a HugMesh token"

INTRO = (
    "Sign a token that lets someone's tray join this mesh in one access domain, as one "
    "role, with or without shell access. It is signed with this Studio's issuer key for "
    "the mesh (created on first use, and trusted by this computer).")

#: Said under the issuer fingerprint, every time a token is shown.
FINGERPRINT_NOTE = (
    "Send the recipient this fingerprint separately from the token (in person, by "
    "phone, or in a message you trust): their tray asks them to compare it before it "
    "trusts this issuer.")

SHELL_ONLY_TIP = (f"Only {' and '.join(mt.SHELL_ROLES)} can hold shell access; the token "
                  "for any other role is refused if it claims it.")

NO_KEY = ("Paste the headscale pre-auth key the token should carry, or mint one from "
          "the local headscale.")

CHECKING_TIP = "Checking for a running headscale container…"

NAME_CONTAINER_TIP = ("Name the running headscale container under Headscale container to "
                      "mint the key in it.")

#: The token lifetime units the dialog offers, and their size in seconds.
UNITS = (("days", 86400), ("hours", 3600))


def valid_mesh_name(name: str) -> bool:
    """Whether ``name`` is a mesh name a token (and an issuer key) can carry."""
    return bool(mt._MESH_RE.match(name or ""))


def known_meshes() -> list[str]:
    """Meshes this Studio already holds an issuer key for, sorted."""
    root = os.path.join(mt.state_dir(), mt.ISSUERS_DIR)
    try:
        names = os.listdir(root)
    except OSError:
        return []
    return sorted(n for n in names if valid_mesh_name(n)
                  and os.path.isfile(os.path.join(root, n, mt.ISSUER_KEY)))


class _Job(QtCore.QThread):
    """Run ``fn`` off the GUI thread; emit ``(True, value)`` or ``(False, sentence)``.
    Never raises: an exception escaping run() would leave the dialog busy forever."""

    result = Signal(object)

    def __init__(self, fn, what: str, parent=None):
        super().__init__(parent)
        self._fn = fn
        self._what = what

    def run(self):
        try:
            self.result.emit((True, self._fn()))
        except mt.TokenError as e:
            self.result.emit((False, str(e)))
        except Exception as e:                       # noqa: BLE001 — never kill the dialog
            self.result.emit((False, f"{self._what}: {e}"))


class IssueTokenDialog(QtWidgets.QDialog):
    """Fill in what the token grants, pick where the pre-auth key comes from, Issue."""

    def __init__(self, parent=None, *, mesh: str = "", domain: str = "",
                 login_server: str = ""):
        super().__init__(parent)
        self.setWindowTitle(TITLE)
        self.resize(620, 560)
        self._probed = False
        self._probe_why = ""
        self._minted_in = None
        self._issued_text = ""
        self._probe = None
        self._job = None
        lay = QtWidgets.QVBoxLayout(self)
        intro = QtWidgets.QLabel(INTRO)
        intro.setWordWrap(True)
        lay.addWidget(intro)

        form = QtWidgets.QFormLayout()
        self.mesh = QtWidgets.QComboBox()
        self.mesh.setEditable(True)
        self.mesh.addItems(known_meshes())
        self.mesh.setCurrentText(mesh)
        self.mesh.setToolTip("The mesh's name: lower-case letters, digits and -. Each mesh "
                             "has its own issuer key.")
        form.addRow("Mesh", self.mesh)
        self.domain = QtWidgets.QLineEdit(domain)
        self.domain.setPlaceholderText("example.org")
        self.domain.setToolTip("The access domain the token grants. The login server must "
                               "be this domain or a name under it.")
        form.addRow("Access domain", self.domain)
        self.role = QtWidgets.QComboBox()
        self.role.addItems(list(mt.ROLES))
        form.addRow("Role", self.role)
        self.shell = QtWidgets.QCheckBox("Grant shell access (Tailscale SSH on the node)")
        form.addRow("", self.shell)
        self.login_server = QtWidgets.QLineEdit(login_server)
        self.login_server.setPlaceholderText("https://headscale.example.org")
        self.login_server.setToolTip("The mesh's headscale URL: https://host or "
                                     "https://host:port, inside the access domain.")
        form.addRow("Login server", self.login_server)
        life = QtWidgets.QHBoxLayout()
        self.lifetime = QtWidgets.QSpinBox()
        self.lifetime.setMinimum(1)
        self.unit = QtWidgets.QComboBox()
        self.unit.addItems([u for u, _ in UNITS])
        life.addWidget(self.lifetime)
        life.addWidget(self.unit)
        life.addStretch(1)
        form.addRow("Lifetime", life)
        lay.addLayout(form)

        box = QtWidgets.QGroupBox("Pre-auth key")
        kl = QtWidgets.QVBoxLayout(box)
        self.paste_radio = QtWidgets.QRadioButton("Paste a headscale pre-auth key:")
        self.paste_radio.setChecked(True)
        kl.addWidget(self.paste_radio)
        self.auth_key = QtWidgets.QLineEdit()
        self.auth_key.setEchoMode(QtWidgets.QLineEdit.EchoMode.Password)
        self.auth_key.setPlaceholderText("the pre-auth key (hidden)")
        kl.addWidget(self.auth_key)
        self.mint_radio = QtWidgets.QRadioButton("Mint from the local headscale")
        self.mint_radio.setEnabled(False)
        self.mint_radio.setToolTip(CHECKING_TIP)
        kl.addWidget(self.mint_radio)
        cr = QtWidgets.QHBoxLayout()
        cr.addWidget(QtWidgets.QLabel("Headscale container:"))
        self.container = QtWidgets.QComboBox()
        self.container.setEditable(True)
        self.container.setToolTip("The running container headscale runs in. The running "
                                  "containers named like headscale are listed; type another "
                                  "name if yours is named otherwise.")
        cr.addWidget(self.container, 1)
        kl.addLayout(cr)
        ur = QtWidgets.QHBoxLayout()
        ur.addWidget(QtWidgets.QLabel("Headscale user:"))
        self.hs_user = QtWidgets.QLineEdit()
        self.hs_user.setPlaceholderText(mt.DEFAULT_MINT_USER)
        self.hs_user.setToolTip(f"The headscale user the minted key is for; empty means "
                                f"{mt.DEFAULT_MINT_USER}, the mesh's control user.")
        ur.addWidget(self.hs_user, 1)
        kl.addLayout(ur)
        lay.addWidget(box)

        row = QtWidgets.QHBoxLayout()
        self.issue_btn = QtWidgets.QPushButton("Issue")
        row.addWidget(self.issue_btn)
        row.addStretch(1)
        lay.addLayout(row)

        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        self.status.setTextInteractionFlags(
            QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.status)
        self.token_view = QtWidgets.QPlainTextEdit()
        self.token_view.setReadOnly(True)
        self.token_view.setPlaceholderText("The token appears here.")
        lay.addWidget(self.token_view, 1)
        self.fingerprint = QtWidgets.QLabel("")
        self.fingerprint.setWordWrap(True)
        self.fingerprint.setTextInteractionFlags(
            QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.fingerprint)
        bottom = QtWidgets.QHBoxLayout()
        self.copy_btn = QtWidgets.QPushButton("Copy token")
        self.copy_btn.setEnabled(False)
        close = QtWidgets.QPushButton("Close")
        bottom.addWidget(self.copy_btn)
        bottom.addStretch(1)
        bottom.addWidget(close)
        lay.addLayout(bottom)

        self.role.currentTextChanged.connect(self._sync_shell)
        self.unit.currentTextChanged.connect(self._sync_unit)
        self.mint_radio.toggled.connect(self._sync_source)
        self.container.currentTextChanged.connect(self._sync_mint)
        self.issue_btn.clicked.connect(self._issue)
        self.copy_btn.clicked.connect(self._copy)
        close.clicked.connect(self.accept)
        self._sync_unit()
        self.lifetime.setValue(7)
        self._sync_shell()
        self._sync_source()
        self._find_container()

    # ── field gating ─────────────────────────────────────────────────────────────
    def _sync_shell(self, *_args) -> None:
        allowed = self.role.currentText() in mt.SHELL_ROLES
        if not allowed:
            self.shell.setChecked(False)
        self.shell.setEnabled(allowed)
        self.shell.setToolTip("" if allowed else SHELL_ONLY_TIP)

    def _sync_unit(self, *_args) -> None:
        self.lifetime.setMaximum(mt.MAX_LIFETIME_S // self._unit_s())

    def _unit_s(self) -> int:
        return dict(UNITS)[self.unit.currentText()]

    def _sync_source(self, *_args) -> None:
        mint = self.mint_radio.isChecked()
        self.auth_key.setEnabled(not mint)
        self.hs_user.setEnabled(mint)

    def lifetime_s(self) -> int:
        return self.lifetime.value() * self._unit_s()

    # ── the headscale container, found off-thread ────────────────────────────────
    def _find_container(self) -> None:
        if probe_running(self, "_probe"):
            return

        def probe():
            # (the one found or "", the names to offer, why none was picked). Several
            # without a clear one is not a failure here: the operator picks one under
            # Headscale container.
            try:
                found = mt.find_headscale_container()
                return found, (found,), ""
            except mt.TokenError as e:
                if e.choices:
                    return "", e.choices, str(e)
                raise

        job = own_probe(self, "_probe", _Job(probe, "The headscale container could not be "
                                                    "looked for", parent=self))
        job.result.connect(self._on_container)
        job.start()

    def _on_container(self, payload) -> None:
        ok, value = payload
        typed = self.container.currentText().strip()
        if ok:
            found, names, self._probe_why = value
            self.container.addItems([n for n in names if self.container.findText(n) < 0])
            self.container.setCurrentText(typed or found)
        else:
            self._probe_why = value
        self._probed = True
        self._sync_mint()

    def _sync_mint(self, *_args) -> None:
        """Mint is offered, once the probe has run, for the container named under
        Headscale container (the one the probe found, one picked, or one typed)."""
        if not self._probed:
            return
        name = self.container.currentText().strip()
        self.mint_radio.setEnabled(bool(name))
        if name:
            self.mint_radio.setText(f"Mint from the local headscale ({name})")
            self.mint_radio.setToolTip(
                f"Mint a single-use pre-auth key in the running container {name} "
                "(docker exec … headscale preauthkeys create), expiring with the token.")
            return
        self.mint_radio.setText("Mint from the local headscale")
        if self.mint_radio.isChecked():
            self.paste_radio.setChecked(True)
        self.mint_radio.setToolTip(f"Unavailable: {self._probe_why}" if self._probe_why
                                   else NAME_CONTAINER_TIP)

    # ── issuing ──────────────────────────────────────────────────────────────────
    def _fields(self) -> dict:
        return dict(mesh=self.mesh.currentText().strip(),
                    domain=self.domain.text().strip(), role=self.role.currentText(),
                    shell=self.shell.isChecked() and self.shell.isEnabled(),
                    login_server=self.login_server.text().strip(),
                    lifetime_s=self.lifetime_s(), node_name="")

    def _issue(self) -> None:
        if probe_running(self, "_job"):
            return
        fields = self._fields()
        mint = self.mint_radio.isChecked() and self.mint_radio.isEnabled()
        pasted = "" if mint else self.auth_key.text().strip()
        if not mint and not pasted:
            self._fail(NO_KEY)
            return
        try:
            # Every field checked BEFORE an issuer key is created or a key is minted
            # (the same check the CLI makes), so a typo leaves nothing behind.
            mt.issuer_dir(fields["mesh"])
            mt._new_grant(issuer="ssh-ed25519 AAAA", now=int(time.time()),
                          auth_key=pasted or "not-yet-minted", **fields)
        except mt.TokenError as e:
            self._fail(str(e))
            return
        container = self.container.currentText().strip()
        user = self.hs_user.text().strip() or mt.DEFAULT_MINT_USER
        if mint and not mt._NAME_RE.match(container):
            self._fail(f"{container!r} is not a container name.")
            return
        if mint and not mt._NAME_RE.match(user):
            self._fail(f"{user!r} is not a headscale user name.")
            return

        def work():
            existed = os.path.isfile(mt.issuer_key_path(fields["mesh"]))
            key_path, _line, fp = mt.ensure_issuer(fields["mesh"])
            if mint:
                # signs once before it mints, and expires the key if signing fails after
                token, _ = mt.mint_and_issue(key_path=key_path, user=user,
                                             container=container, interactive=False,
                                             **fields)
            else:
                token = mt.issue(key_path=key_path, auth_key=pasted, interactive=False,
                                 **fields)
            return token, fp, not existed

        self.issue_btn.setEnabled(False)
        self.copy_btn.setEnabled(False)
        self.token_view.clear()
        self.fingerprint.setText("")
        self.status.setText("Minting a pre-auth key and signing…" if mint else "Signing…")
        self._minted_in = (container, user) if mint else None
        job = own_probe(self, "_job", _Job(work, "The token could not be issued",
                                         parent=self))
        job.result.connect(self._on_issued)
        job.start()

    def _fail(self, sentence: str) -> None:
        self.status.setText(sentence)
        self.token_view.clear()
        self.fingerprint.setText("")
        self.copy_btn.setEnabled(False)

    def _on_issued(self, payload) -> None:
        self.issue_btn.setEnabled(True)
        ok, value = payload
        if not ok:
            self._fail(value)
            return
        token, fp, created = value
        self.auth_key.clear()        # it is in the token now; not kept here
        self.token_view.setPlainText(token)
        self.copy_btn.setEnabled(True)
        try:
            grant = mt.parse(token)[0].describe()
        except mt.TokenError:        # pragma: no cover - issue() just produced it
            grant = "what was asked"
        minted = ""
        if self._minted_in:
            container, user = self._minted_in
            minted = (f" The pre-auth key was minted in {container} for the headscale "
                      f"user {user}: single-use, expiring with the token.")
        self._issued_text = (f"Issued: {grant}.{minted} The server still decides: the "
                             "pre-auth key's tags and the headscale ssh policy set what "
                             "the node may reach.")
        self.status.setText(self._issued_text)
        self.fingerprint.setText(
            f"Issuer fingerprint: {fp}"
            + (" (this issuer key was created now; this computer trusts it)" if created
               else "") + f"\n{FINGERPRINT_NOTE}")

    def _copy(self) -> None:
        QtWidgets.QApplication.clipboard().setText(self.token_view.toPlainText())
        self.status.setText(f"{self._issued_text} Copied to the clipboard.")

    def token(self) -> str:
        return self.token_view.toPlainText()


def open_issue_token_dialog(parent=None, **prefill) -> None:
    IssueTokenDialog(parent, **prefill).exec()


__all__ = ["IssueTokenDialog", "open_issue_token_dialog", "known_meshes", "valid_mesh_name",
           "FINGERPRINT_NOTE", "NO_KEY", "SHELL_ONLY_TIP", "TITLE"]
