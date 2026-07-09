"""Snapdragon Image Studio — entry point.

  python -m snapdragon_studio               # wizard + mesh-node tray + local-stack tray
  python -m snapdragon_studio --tray        # tray only (mesh-node controller)
  python -m snapdragon_studio --stack-tray  # tray only (local dev-stack controller)
  python -m snapdragon_studio --login-agent # headless: run the passwordless local-login loopback agent
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
    ap.add_argument("--stack-tray", action="store_true",
                    help="run only the local dev-stack (make stack-up) tray controller")
    ap.add_argument("--login-agent", action="store_true",
                    help="headless: run the passwordless local-login loopback agent "
                         "(binds 127.0.0.1:27621; serves the role-picker handoff to login-ui)")
    ap.add_argument("--login-manifest",
                    help="path to the local-login roles manifest (default: "
                         "$SNAPDRAGON_LOCAL_LOGIN_MANIFEST or "
                         "~/.config/snapdragon-studio/local-login/roles.json)")
    ap.add_argument("--print-command", action="store_true",
                    help="headless: print the build command for a saved config and exit")
    ap.add_argument("--config", help="config JSON (with --print-command)")
    ap.add_argument("--backend", choices=["auto", "native", "docker"], default="auto",
                    help="build backend for --print-command (auto = host default)")
    args = ap.parse_args(argv)

    if args.login_agent:
        # Qt-free path: the loopback login agent is stdlib-only and blocks in
        # serve_forever(), so it must never touch a Qt binding or a display.
        from .core.local_login_agent import run as run_login_agent
        return run_login_agent(manifest_path=args.login_manifest)

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

    tray_only = args.tray or args.stack_tray
    # --tray/--stack-tray each mean "only this one" in isolation, but "show
    # everything relevant" if neither (default) or both are given.
    show_mesh = args.tray or not tray_only
    show_stack = args.stack_tray or not tray_only
    trays = []
    if QtWidgets.QSystemTrayIcon.isSystemTrayAvailable():
        from .gui.tray import MeshTray, StackTray
        if show_mesh:
            trays.append(MeshTray(args.generator_dir, on_open_studio=open_studio))
        if show_stack:
            trays.append(StackTray(args.generator_dir, on_open_studio=open_studio))
        for tray in trays:
            tray.show()
        if trays:
            app.setQuitOnLastWindowClosed(False)  # keep running in the tray

    if not tray_only:
        open_studio()
    elif not trays:
        print("[studio] no system tray available; opening the wizard instead", file=sys.stderr)
        open_studio()

    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
