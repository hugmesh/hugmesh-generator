"""KeyZipPage — load the admin-provided config for a mesh-client (or mesh-node) build.

Two equivalent ways in, plus an opt-in "remember loginable roles" step:
  * browse to the key-zip the admin generated (keys/certs/egress/branding), or
  * paste the REMOTE-CONFIG LINK the admin gave you and fetch that same zip.

Both funnel through the one :mod:`core.keyzip` extract/apply path, so a fetched link
behaves identically to a browsed file — it is a fetch-then-import, not a parallel
import path. On the cloud path this is the config that lets the desktop JOIN an
existing mesh (tailnet + SSO); on the mesh path it carries the fleet Secure-Boot key.
"""
from __future__ import annotations

import os
import urllib.parse
import urllib.request
import zipfile

from ..qt import QtCore, QtWidgets, Signal
from ...core import keyzip
from ._widgets import _file_picker, _row, own_probe

# Schemes the "Fetch from link" button will follow. file:// is included ON PURPOSE so
# the flow stays exercisable/offline-testable without any network — and, like the http
# schemes, it is NEVER auto-fired (only an explicit button click fetches). Anything
# else (ftp:, data:, a bare path, a shell-ish string) is rejected before urlopen is
# ever reached, so a typo can't turn into a surprising protocol.
_ALLOWED_LINK_SCHEMES = ("http", "https", "file")

#: Socket timeout for the remote-config fetch, in seconds.
#:
#: urlopen() WITHOUT a timeout blocks on the default socket timeout, which is normally
#: None — i.e. forever. A server that accepts the connection and then never answers (a
#: half-open NAT, a hung reverse proxy, a black-holed IP) therefore hung the fetch with
#: no upper bound. That is bad enough on a worker thread; on the GUI thread, where this
#: used to run, it hung the whole window with no Cancel and no way to close it.
#:
#: 60s is generous for a key-zip (capped at core.keyzip.MAX_TOTAL) over a slow link, and
#: it is a per-socket-operation timeout, not a whole-transfer deadline: a slow but
#: PROGRESSING download is never cut off, only a stalled one.
_FETCH_TIMEOUT_S = 60


def _fetch_to_zip(url: str, dest_path: str) -> str:
    """Download/copy an admin remote-config link to a local .zip and return its path.

    User-initiated ONLY (the Fetch button); nothing here runs on its own, so there is
    no background/cluster contact. The scheme is allowlisted BEFORE ``urlopen`` runs,
    the socket carries :data:`_FETCH_TIMEOUT_S` so a hung server cannot block
    forever, and the body is capped at :data:`core.keyzip.MAX_TOTAL` so a hostile link
    can't fill the disk. The caller then hands the bytes to the SAME
    :func:`core.keyzip.extract` / :meth:`KeyZipContents.apply_to` path a browsed .zip
    takes. (No remote-config service ships today; when one lands, point this at it —
    the extract/apply override point below does not change.)

    BLOCKING BY CONTRACT: this is network I/O, so it runs on :class:`_FetchWorker`, never
    on the GUI thread.
    """
    scheme = urllib.parse.urlparse(url).scheme.lower()
    if scheme not in _ALLOWED_LINK_SCHEMES:
        raise ValueError(
            f"unsupported link scheme {scheme or '(none)'!r} — paste an "
            "http://, https:// or file:// link")
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    with urllib.request.urlopen(               # nosec B310 — scheme allowlisted above
            url, timeout=_FETCH_TIMEOUT_S) as resp:
        data = resp.read(keyzip.MAX_TOTAL + 1)
    if len(data) > keyzip.MAX_TOTAL:
        raise ValueError(f"linked key-zip is too large (> {keyzip.MAX_TOTAL} bytes)")
    with open(dest_path, "wb") as fh:
        fh.write(data)
    return dest_path


class _FetchWorker(QtCore.QThread):
    """Fetch ONE remote-config link off the GUI thread.

    A timeout alone is not enough: even a bounded 60s wait is 60s of a frozen window with
    a spinning cursor and no way to cancel or close, which is exactly the class of defect
    the localmesh _StatusProbe exists to prevent (the same one-shot off-thread probe
    shape, and this follows it deliberately rather than inventing a second pattern).

    Emits (path, error) — exactly one of them non-empty. Never raises: every failure a
    fetch can have is already an OSError or a ValueError, and an exception escaping
    QThread.run would be lost anyway."""
    done = Signal(str, str)

    def __init__(self, url: str, dest: str, parent=None):
        super().__init__(parent)
        self._url = url
        self._dest = dest

    def run(self):                              # noqa: D102 — QThread contract
        try:
            self.done.emit(_fetch_to_zip(self._url, self._dest), "")
        except (OSError, ValueError) as e:
            self.done.emit("", str(e))
        except Exception as e:                  # noqa: BLE001 — a probe must never die
            self.done.emit("", f"{type(e).__name__}: {e}")


class KeyZipPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
        #: the in-flight remote-config fetch (None = idle) — see _fetch.
        self._fetch_worker: _FetchWorker | None = None
        self.setTitle("Load your admin config (key-zip or link)")
        # initializePage() sets a path-aware subtitle; this is the fallback.
        self.setSubTitle(
            "Bring in the keys, certs, egress-VPN and branding your admin generated "
            "— browse to the .zip, or paste the remote-config link they gave you.")
        lay = QtWidgets.QVBoxLayout(self)

        # (1) browse to a key-zip on disk (the original path — attributes preserved)
        self.path = QtWidgets.QLineEdit()
        btn = _file_picker(self, self.path, "Admin key-zip", "Zip (*.zip)")
        w = QtWidgets.QWidget(); h = QtWidgets.QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.path, 1); h.addWidget(btn)
        lay.addWidget(_row("Key-zip file", w))
        imp = QtWidgets.QPushButton("Import & apply")
        imp.clicked.connect(self._import)
        lay.addWidget(imp)

        # (2) NEW: paste the admin-provided remote-config link and fetch that same zip
        self.link = QtWidgets.QLineEdit()
        self.link.setPlaceholderText(
            "https://…  or  file://…  (the link your admin gave you)")
        lw = QtWidgets.QWidget(); lh = QtWidgets.QHBoxLayout(lw); lh.setContentsMargins(0, 0, 0, 0)
        self.fetch_btn = QtWidgets.QPushButton("Fetch from link…")
        self.fetch_btn.clicked.connect(self._fetch)
        lh.addWidget(self.link, 1); lh.addWidget(self.fetch_btn)
        lay.addWidget(_row("Remote-config link", lw))
        link_help = QtWidgets.QLabel(
            "Paste the link your admin gave you to fetch the key-zip (keys, certs, "
            "egress-VPN, branding) automatically instead of browsing to it. Nothing "
            "is contacted until you click Fetch — no link is followed on its own.")
        link_help.setWordWrap(True)
        link_help.setStyleSheet("color: gray;")
        lay.addWidget(link_help)

        # OPT-IN, default OFF (per --remember-roles-for-passwordless-login / the
        # HUGMESH_REMEMBER_ROLES_FOR_PASSWORDLESS_LOGIN env var): this is the
        # actual gate checked at import time, seeded from that CLI/env default so
        # the box still starts unchecked unless the operator asked for it.
        #
        # The LABEL stays short and the prose moves to a wrapped gray QLabel below it
        # (the _hint / BrandingPage.unaffiliated_note idiom) — not cosmetic: a QCheckBox
        # CANNOT word-wrap, so a long label becomes a hard horizontal floor under the
        # page's minimumSizeHint. The old 249-char label measured a 1387px minimum
        # width, which QWizard cannot lay out below — it forced the whole window to
        # 1431px the moment this page was reached, and it never shrank back. That was
        # the "size changes wildly" report. Keep this label short.
        self.remember_roles = QtWidgets.QCheckBox(
            "Remember loginable roles from this key-zip for passwordless login")
        self.remember_roles.setChecked(
            bool(getattr(wiz, "remember_roles_for_passwordless_login", False)))
        lay.addWidget(self.remember_roles)
        remember_help = QtWidgets.QLabel(
            "Remembers human-loginable roles (e.g. platform superadmin) from this "
            "key-zip and writes real login credentials to local disk "
            "(~/.config/hugmesh-studio/local-login/roles.json, mode 0600). "
            "Never DB passwords or other machine secrets.")
        remember_help.setWordWrap(True)
        remember_help.setStyleSheet("color: gray;")
        lay.addWidget(remember_help)

        self.out = QtWidgets.QLabel("")
        self.out.setWordWrap(True)
        lay.addWidget(self.out)
        lay.addStretch(1)

    def initializePage(self):
        # Path-aware clarity — the page is only visited for cloud (mesh desktop client)
        # and mesh (superadmin node); standalone skips it (MODE_SKIPPED_PAGES).
        if self.wiz.cfg.mode == "cloud":
            self.setSubTitle(
                "This builds a client desktop that JOINS an existing mesh (tailnet + "
                "SSO). Bring in the keys, certs, egress-VPN and branding your domain "
                "admin generated for you — browse to the .zip, or paste their "
                "remote-config link and fetch it.")
        else:  # mesh node
            self.setSubTitle(
                "Bring in fleet key material an admin prepared — including the "
                "Secure-Boot signing key so the node signs with the key already "
                "enrolled in the fleet firmware. Browse to the .zip, or paste a "
                "remote-config link and fetch it.")

    def _apply(self, zip_path: str):
        """Extract + wire a key-zip into the ImageConfig. Shared by Import (browse to a
        file) and Fetch (a remote-config link) so both behave identically."""
        try:
            # keyzip.staging_dir() (NOT a bare expanduser("~")) — extract() clears
            # this dir recursively, so it has to be overridable: it honours the same
            # $HUGMESH_STUDIO_STATE_DIR the rest of the state family does.
            c = keyzip.extract(zip_path, keyzip.staging_dir())
            c.apply_to(self.wiz.cfg)
            self.wiz.cfg.keyzip = zip_path
            role_ids = keyzip.emit_passwordless_login_roles(
                c, enabled=self.remember_roles.isChecked(),
                manifest_path=getattr(self.wiz, "login_manifest_path", None))
            msg = f"Imported: {c.summary()}"
            if c.warnings:
                msg += f"  ·  warnings: {'; '.join(c.warnings)}"
            if role_ids:
                msg += f"  ·  passwordless-login roles remembered: {', '.join(role_ids)}"
            self.out.setText(msg)
        except (OSError, ValueError, zipfile.BadZipFile) as e:
            self.out.setText(f"Failed: {e}")

    def _import(self):
        p = self.path.text().strip()
        if not p or not os.path.exists(p):
            self.out.setText("Pick a .zip first.")
            return
        self._apply(p)

    def _fetch(self):
        """Start the fetch OFF the GUI thread and return immediately.

        This used to call _fetch_to_zip() inline, so the whole window froze for as long as
        the server took to answer — and with no timeout on the socket, "as long as" had no
        upper bound (see _FETCH_TIMEOUT_S). The button is disabled for the duration so the
        click cannot be repeated into a second thread, and the status line says what is
        happening instead of the window simply going dead."""
        if self._fetch_worker is not None and self._fetch_worker.isRunning():
            return
        url = self.link.text().strip()
        if not url:
            self.out.setText("Paste a remote-config link first.")
            return
        dest = keyzip.fetch_zip_path()
        self.fetch_btn.setEnabled(False)
        self.out.setText(f"Fetching {url} … (the window stays responsive; this gives up "
                         f"after {_FETCH_TIMEOUT_S}s if the server never answers)")
        # Held on the page, not in a local: a QThread whose last Python reference is
        # dropped is garbage-collected mid-run and takes its thread with it. own_probe
        # also releases the PREVIOUS one — parenting alone keeps every finished fetch
        # alive as a child of the page (see its docstring).
        worker = own_probe(self, "_fetch_worker", _FetchWorker(url, dest, parent=self))
        worker.done.connect(self._fetched)
        worker.start()

    def _fetched(self, zip_path: str, error: str):
        """The fetch finished (GUI thread). Applying is local work — extract + wire into
        the config — so it belongs here, on the same path a BROWSED zip takes."""
        self.fetch_btn.setEnabled(True)
        if error or not zip_path:
            self.out.setText(f"Fetch failed: {error or 'no file was written'}")
            return
        self.path.setText(zip_path)   # surface what was fetched (re-importable too)
        self._apply(zip_path)

    def isComplete(self):
        return True
