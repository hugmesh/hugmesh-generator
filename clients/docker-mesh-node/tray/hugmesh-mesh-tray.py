#!/usr/bin/env python3
# HugMesh mesh-node — LINUX system tray indicator (FD-09). A small AppIndicator
# that shows the mesh-node container state and offers Join / Logs / Leave from the
# task bar. Actions shell out to `hugmesh-mesh-ctl` (installed by install.sh), so
# the keys/role come from ~/.config/hugmesh-mesh/launch.env. Pairs with the
# Windows tray (hugmesh-mesh-tray.ps1). Degrades gracefully if no AppIndicator
# GI typelib is present (the menu entries + autostart still work without this).
import os
import shutil
import subprocess
import sys

import gi

# Prefer Ayatana (current); fall back to the legacy AppIndicator3.
_IND_NS = None
for ns in ("AyatanaAppIndicator3", "AppIndicator3"):
    try:
        gi.require_version(ns, "0.1")
        _IND_NS = ns
        break
    except (ValueError, ImportError):
        continue

if _IND_NS is None:
    sys.stderr.write(
        "hugmesh-mesh-tray: no AppIndicator typelib found.\n"
        "  Debian/Ubuntu: apt install gir1.2-ayatanaappindicator3-0.1 python3-gi\n"
        "  Fedora:        dnf install libayatana-appindicator-gtk3 python3-gobject\n"
        "The app-menu entries (Join/Status/Leave) work without the tray.\n"
    )
    sys.exit(1)

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402
from gi.repository import GdkPixbuf  # noqa: E402,F401  (ensures pixbuf loaders present)

if _IND_NS == "AyatanaAppIndicator3":
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
else:
    from gi.repository import AppIndicator3 as AppIndicator

CONTAINER = "hugmesh-mesh-node"
CTL = shutil.which("hugmesh-mesh-ctl") or os.path.expanduser(
    "~/.local/bin/hugmesh-mesh-ctl"
)
ICON = "hugmesh-mesh-node"  # resolved from the hicolor theme installed by install.sh


def _run(cmd):
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=6
        ).stdout.strip()
    except Exception:
        return ""


def container_running():
    out = _run(["docker", "inspect", "-f", "{{.State.Running}}", CONTAINER])
    return out == "true"


def mesh_state():
    if not container_running():
        return "stopped"
    # Best-effort: ask the in-container tailscale for the backend state.
    out = _run(["docker", "exec", CONTAINER, "tailscale", "status", "--json"])
    if '"BackendState"' in out:
        if '"Running"' in out:
            return "joined"
        if '"NeedsLogin"' in out or '"NoState"' in out:
            return "registered (awaiting approval)"
    return "running"


class Tray:
    def __init__(self):
        self.ind = AppIndicator.Indicator.new(
            "hugmesh-mesh-node",
            ICON,
            AppIndicator.IndicatorCategory.SYSTEM_SERVICES,
        )
        self.ind.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.ind.set_title("HugMesh Mesh")
        self.menu = Gtk.Menu()

        self.status_item = Gtk.MenuItem(label="Status: …")
        self.status_item.set_sensitive(False)
        self.menu.append(self.status_item)
        self.menu.append(Gtk.SeparatorMenuItem())

        self._add("Join the mesh", lambda _w: self._ctl("up", in_terminal=True))
        self._add("Show logs", lambda _w: self._ctl("logs", in_terminal=True))
        self._add("Leave the mesh", lambda _w: self._ctl("stop"))
        self.menu.append(Gtk.SeparatorMenuItem())
        self._add("Refresh", lambda _w: self.refresh())
        self._add("Quit tray", lambda _w: Gtk.main_quit())

        self.menu.show_all()
        self.ind.set_menu(self.menu)
        self.refresh()
        GLib.timeout_add_seconds(15, self.refresh)

    def _add(self, label, cb):
        item = Gtk.MenuItem(label=label)
        item.connect("activate", cb)
        self.menu.append(item)

    def _ctl(self, action, in_terminal=False):
        if in_terminal and shutil.which("x-terminal-emulator"):
            subprocess.Popen(
                ["x-terminal-emulator", "-e", CTL, action]
            )  # noqa: S603
        else:
            subprocess.Popen([CTL, action])  # noqa: S603
        GLib.timeout_add_seconds(2, self.refresh)

    def refresh(self):
        self.status_item.set_label(f"Status: {mesh_state()}")
        return True  # keep the GLib timer alive


def main():
    if not shutil.which("docker"):
        sys.stderr.write("hugmesh-mesh-tray: docker not found on PATH.\n")
        sys.exit(1)
    Tray()
    Gtk.main()


if __name__ == "__main__":
    main()
