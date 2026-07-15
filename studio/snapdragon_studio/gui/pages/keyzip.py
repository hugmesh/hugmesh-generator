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

from ..qt import QtWidgets
from ...core import keyzip
from ._widgets import _file_picker, _row

# Schemes the "Fetch from link" button will follow. file:// is included ON PURPOSE so
# the flow stays exercisable/offline-testable without any network — and, like the http
# schemes, it is NEVER auto-fired (only an explicit button click fetches). Anything
# else (ftp:, data:, a bare path, a shell-ish string) is rejected before urlopen is
# ever reached, so a typo can't turn into a surprising protocol.
_ALLOWED_LINK_SCHEMES = ("http", "https", "file")


def _fetch_to_zip(url: str, dest_path: str) -> str:
    """Download/copy an admin remote-config link to a local .zip and return its path.

    User-initiated ONLY (the Fetch button); nothing here runs on its own, so there is
    no background/cluster contact. The scheme is allowlisted BEFORE ``urlopen`` runs,
    and the body is capped at :data:`core.keyzip.MAX_TOTAL` so a hostile link can't
    fill the disk. The caller then hands the bytes to the SAME
    :func:`core.keyzip.extract` / :meth:`KeyZipContents.apply_to` path a browsed .zip
    takes. (No remote-config service ships today; when one lands, point this at it —
    the extract/apply seam below does not change.)
    """
    scheme = urllib.parse.urlparse(url).scheme.lower()
    if scheme not in _ALLOWED_LINK_SCHEMES:
        raise ValueError(
            f"unsupported link scheme {scheme or '(none)'!r} — paste an "
            "http://, https:// or file:// link")
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    with urllib.request.urlopen(url) as resp:   # nosec B310 — scheme allowlisted above
        data = resp.read(keyzip.MAX_TOTAL + 1)
    if len(data) > keyzip.MAX_TOTAL:
        raise ValueError(f"linked key-zip is too large (> {keyzip.MAX_TOTAL} bytes)")
    with open(dest_path, "wb") as fh:
        fh.write(data)
    return dest_path


class KeyZipPage(QtWidgets.QWizardPage):
    def __init__(self, wiz):
        super().__init__()
        self.wiz = wiz
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
        # SNAPDRAGON_REMEMBER_ROLES_FOR_PASSWORDLESS_LOGIN env var): this is the
        # actual gate checked at import time, seeded from that CLI/env default so
        # the box still starts unchecked unless the operator asked for it.
        self.remember_roles = QtWidgets.QCheckBox(
            "Remember human-loginable roles (e.g. platform superadmin) from this "
            "key-zip for passwordless login — writes real login credentials to "
            "local disk (~/.config/snapdragon-studio/local-login/roles.json, "
            "mode 0600). Never DB passwords or other machine secrets.")
        self.remember_roles.setChecked(
            bool(getattr(wiz, "remember_roles_for_passwordless_login", False)))
        lay.addWidget(self.remember_roles)

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
            staging = os.path.join(os.path.expanduser("~"), ".snapdragon", "keyzip")
            c = keyzip.extract(zip_path, staging)
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
        url = self.link.text().strip()
        if not url:
            self.out.setText("Paste a remote-config link first.")
            return
        dest = os.path.join(os.path.expanduser("~"), ".snapdragon",
                            "keyzip-fetch", "admin-config.zip")
        try:
            zip_path = _fetch_to_zip(url, dest)
        except (OSError, ValueError) as e:
            self.out.setText(f"Fetch failed: {e}")
            return
        self.path.setText(zip_path)   # surface what was fetched (re-importable too)
        self._apply(zip_path)

    def isComplete(self):
        return True
