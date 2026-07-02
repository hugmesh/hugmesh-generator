"""Snapdragon Image Studio — entry point.

  python -m snapdragon_studio            # wizard + tray
  python -m snapdragon_studio --tray     # tray only (mesh-node controller)
  python -m snapdragon_studio --generator-dir /path/to/snapdragon-generator
"""
from __future__ import annotations

import argparse
import os
import sys


def _default_generator_dir() -> str:
    # studio/ lives inside the generator repo; default to the repo root.
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(os.path.join(here, "..", ".."))
    if os.path.exists(os.path.join(repo, "build-x86-host-stage4.sh")):
        return repo
    return os.getcwd()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Snapdragon Image Studio")
    ap.add_argument("--generator-dir", default=_default_generator_dir(),
                    help="path to the snapdragon-generator checkout")
    ap.add_argument("--tray", action="store_true", help="run only the mesh-node tray controller")
    ap.add_argument("--print-command", action="store_true",
                    help="headless: print the build command for a saved config and exit")
    ap.add_argument("--config", help="config JSON (with --print-command)")
    ap.add_argument("--backend", choices=["auto", "native", "docker"], default="auto",
                    help="build backend for --print-command (auto = host default)")
    args = ap.parse_args(argv)

    if args.print_command:
        # Qt-free path: core only — must work with no display and no Qt installed.
        from .core.build_driver import BuildDriver
        from .core.config import ImageConfig
        cfg = ImageConfig.load(args.config) if args.config else ImageConfig()
        driver = BuildDriver(args.generator_dir)
        backend = None if args.backend == "auto" else args.backend
        if backend is None and driver.host.default_backend == "none":
            backend = "native"  # still print a deterministic command on a host that can't build
        print(driver.command_string(cfg, backend))
        return 0

    # GUI
    from .gui.qt import QtWidgets, BINDING  # noqa: N806
    app = QtWidgets.QApplication(sys.argv if argv is None else [sys.argv[0], *argv])
    app.setApplicationName("Snapdragon Image Studio")
    print(f"[studio] Qt binding: {BINDING}")

    wizard = None

    def open_studio():
        nonlocal wizard
        from .gui.wizard import StudioWizard
        if wizard is None:
            wizard = StudioWizard(args.generator_dir)
        wizard.show()
        wizard.raise_()

    tray = None
    if QtWidgets.QSystemTrayIcon.isSystemTrayAvailable():
        from .gui.tray import MeshTray
        tray = MeshTray(args.generator_dir, on_open_studio=open_studio)
        tray.show()
        app.setQuitOnLastWindowClosed(False)  # keep running in the tray

    if not args.tray:
        open_studio()
    elif tray is None:
        print("[studio] no system tray available; opening the wizard instead", file=sys.stderr)
        open_studio()

    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
