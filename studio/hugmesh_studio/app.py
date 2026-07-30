"""HugMesh Image Studio — entry point.

  python -m hugmesh_studio               # wizard + mesh-node tray + local-stack tray
  python -m hugmesh_studio --tray        # tray only (mesh-node controller)
  python -m hugmesh_studio --stack-tray  # tray only (local dev-stack controller)
  python -m hugmesh_studio --go-live     # superadmin go-live wizard (hugmesh-go-live front-end)
  python -m hugmesh_studio --fleet       # fleet build dialog (scripts/build-all-roles.sh front-end)
  python -m hugmesh_studio --login-agent # headless: run the passwordless local-login loopback agent
  python -m hugmesh_studio --generator-dir /path/to/hugmesh-generator
  python -m hugmesh_studio --remember-roles-for-passwordless-login
      # OPT-IN, default OFF: KeyZipPage imports also mirror human-loginable KEYS
      # roles (e.g. platform superadmin) into the local-login manifest.
"""
from __future__ import annotations

import argparse
import os
import sys

from .core import crashlog


def _default_generator_dir() -> str:
    # studio/ lives inside the generator repo; default to the repo root.
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(os.path.join(here, "..", ".."))
    if os.path.exists(os.path.join(repo, "build-x86-host-stage4.sh")):
        return repo
    return os.getcwd()


def _env_flag(name: str) -> bool:
    """Truthy env-var check ("1"/"true"/"yes"/"on", case-insensitive)."""
    return os.environ.get(name, "").strip().lower() in ("1", "true", "yes", "on")


REMEMBER_ROLES_ENV = "HUGMESH_REMEMBER_ROLES_FOR_PASSWORDLESS_LOGIN"


def main(argv=None) -> int:
    # FIRST thing, before argparse and long before any Qt import: a crash from here
    # on leaves a file behind. Under PyQt6 an unhandled exception in a slot calls
    # qFatal() and ABORTS the process, and a Studio launched from a desktop entry has
    # nowhere to print — which is why the 2026-07-29 GUI crash had to be
    # reconstructed from build artifacts and file mtimes. See core/crashlog.py.
    crashlog.install()
    ap = argparse.ArgumentParser(description="HugMesh Image Studio")
    ap.add_argument("--generator-dir", default=_default_generator_dir(),
                    help="path to the hugmesh-generator checkout")
    ap.add_argument("--tray", action="store_true", help="run only the mesh-node tray controller")
    ap.add_argument("--stack-tray", action="store_true",
                    help="run only the local dev-stack (make stack-up) tray controller")
    ap.add_argument("--go-live", action="store_true",
                    help="open the superadmin go-live wizard (take a provisioned brand "
                         "device from internal-only to publicly live — the GUI front-end "
                         "to the shared driver specs/usr/sbin/hugmesh-go-live)")
    ap.add_argument("--fleet", action="store_true",
                    help="open the fleet build dialog (build EVERY role for the selected "
                         "platforms in one run — the GUI front-end to "
                         "scripts/build-all-roles.sh; also reachable from the wizard's "
                         "welcome page)")
    ap.add_argument("--login-agent", action="store_true",
                    help="headless: run the passwordless local-login loopback agent "
                         "(binds 127.0.0.1:27621; serves the role-picker handoff to login-ui)")
    ap.add_argument("--login-manifest",
                    help="path to the local-login roles manifest (default: "
                         "$HUGMESH_LOCAL_LOGIN_MANIFEST or "
                         "~/.config/hugmesh-studio/local-login/roles.json)")
    ap.add_argument("--dev", action="store_true",
                    help="local-login agent: ALSO trust the localhost dev origins "
                         "(http://localhost:4200, http://127.0.0.1:4200) — DEV ONLY, "
                         "never in a shipped production build (also settable via "
                         "$HUGMESH_LOCAL_LOGIN_DEV or the manifest's devOrigins)")
    ap.add_argument("--remember-roles-for-passwordless-login", action="store_true",
                    default=_env_flag(REMEMBER_ROLES_ENV),
                    help="OPT-IN, default OFF: after an admin key-zip is imported on the "
                         "KeyZipPage, also mirror ONLY its human-loginable role credentials "
                         "(currently: the platform superadmin Casdoor login) into the "
                         "local-login roles manifest (--login-manifest), so they appear in "
                         "the passwordless-login role picker. NEVER writes DB passwords, "
                         "mTLS/PKI material, or other machine/service secrets — see "
                         "core.keyzip.emit_passwordless_login_roles() for the exact "
                         f"include/exclude list. Can also be set via ${REMEMBER_ROLES_ENV}=1. "
                         "The KeyZipPage also shows a per-import checkbox seeded from this "
                         "value that is the actual gate at import time.")
    ap.add_argument("--print-command", action="store_true",
                    help="headless: print the build command for a saved FLAT config and "
                         "exit (fails loudly on a worklist envelope — use --print-commands)")
    ap.add_argument("--print-commands", action="store_true",
                    help="headless: print one build command per materialized image for a "
                         "worklist ENVELOPE (or a flat config = one command) and exit")
    ap.add_argument("--print-specs", action="store_true",
                    help="headless: print each materialized image's flat ImageConfig JSON "
                         "(one per line, SECRET fields blanked) — the materialization bridge "
                         "the web IMAGE_SPEC_JSON / build-image.sh channel consumes")
    ap.add_argument("--image", type=int, default=None,
                    help="with --print-commands/--print-specs: print ONLY the image at this "
                         "0-based materialized index (default: every image)")
    ap.add_argument("--askpass", action="store_true",
                    help="internal: the GUI SUDO_ASKPASS helper for a GUI-launched native "
                         "build — pop a password dialog and print the entered password to "
                         "stdout (exit non-zero on cancel so sudo aborts). Set as "
                         "SUDO_ASKPASS for `sudo -A` by core.build_driver so the prompt is "
                         "a dialog, never an invisible terminal.")
    ap.add_argument("--config", help="config JSON (with --print-command/--print-commands/--print-specs)")
    ap.add_argument("--backend", choices=["auto", "native", "docker"], default="auto",
                    help="build backend for --print-command (auto = host default)")
    args = ap.parse_args(argv)

    if args.login_agent:
        # Qt-free path: the loopback login agent is stdlib-only and blocks in
        # serve_forever(), so it must never touch a Qt binding or a display.
        from .core.local_login_agent import run as run_login_agent
        return run_login_agent(manifest_path=args.login_manifest, allow_dev_origins=args.dev)

    if args.print_command:
        # Qt-free path: core only — must work with no display and no Qt installed.
        from .core.build_driver import BuildDriver
        from .core.config import (
            ImageConfig,
            resolve_installer_ui_default,
            resolve_platform_defaults,
        )
        # graphical stays False (default): this is the headless single-build command
        # channel — its sudo prefix is a literal `sudo ` the callers strip (test_headless
        # removeprefix, build-matrix check.sh ${cmdline#sudo }), never `sudo -A`/pkexec.
        driver = BuildDriver(args.generator_dir)
        backend = None if args.backend == "auto" else args.backend
        if backend is None and driver.host.default_backend == "none":
            backend = "native"  # still print a deterministic command on a host that can't build
        try:
            # ImageConfig.load raises on a worklist envelope (explicit `schema` key) so
            # it can never silently degrade to a default config; the unaffiliated
            # conflicts / identity allowlist raise ValueError inside command_string. Both
            # surface as a clean non-zero exit with the reason on stderr (never argv).
            cfg = ImageConfig.load(args.config) if args.config else ImageConfig()
            # Resolve platform defaults on this fresh throwaway cfg BEFORE dispatch — the
            # single-build flat path bypasses worklist._materialize_one, so without this a
            # standalone frite/orangepi5/orangepizero2[w]/orangepizero3/orangepi3-lts with an unset flavor would print
            # `--flavor both` and build TWO ISOs the worker can't disambiguate (G2). Same
            # #337 resolver the materialize path uses; in-place mutation is safe here.
            resolve_platform_defaults(cfg)
            # Role-class twin of the above, same reason: this flat path bypasses
            # worklist._materialize_one, so without it a headless x86 node would print
            # `--installer-ui all` and pull an UNSATISFIABLE app-admin/calamares (the
            # desktop USE closure is ROLE_CLIENT-gated). The note goes to STDERR — stdout
            # here IS the argv channel and any extra byte corrupts every consumer.
            note = resolve_installer_ui_default(cfg)
            if note:
                print(f"warning: {note}", file=sys.stderr)
            print(driver.command_string(cfg, backend))
        except (ValueError, OSError) as exc:
            # ValueError: bad JSON / non-dict config / envelope-vs-flat mismatch /
            # unaffiliated-identity conflict. OSError: a missing or unreadable --config
            # path. Both are bad INPUT — exit 2 with a clean message rather than letting
            # a FileNotFoundError/TypeError escape as a traceback + exit 1.
            print(f"error: {exc}", file=sys.stderr)
            return 2
        return 0

    if args.print_commands:
        # Qt-free path: the worklist model is model-only (no Qt). Accepts BOTH shapes via
        # load_any — an envelope prints one command per materialized image; a flat config
        # prints its single command. --image selects one 0-based materialized index.
        from .core.build_driver import BuildDriver
        from .core.config import ImageConfig
        from .core.worklist import load_any, synthesize
        driver = BuildDriver(args.generator_dir)
        backend = None if args.backend == "auto" else args.backend
        if backend is None and driver.host.default_backend == "none":
            backend = "native"
        try:
            if args.config:
                base, wl = load_any(args.config)
            else:
                base, wl = ImageConfig(), None
            if wl is None:
                wl = synthesize(base)
            materialized = [cfg for _entry, cfg in wl.materialize()]
            if args.image is not None:
                if not -len(materialized) <= args.image < len(materialized):
                    print(f"error: --image {args.image} out of range "
                          f"(worklist has {len(materialized)} image(s))", file=sys.stderr)
                    return 2
                materialized = [materialized[args.image]]
            for cfg in materialized:
                print(driver.command_string(cfg, backend))
        except (ValueError, OSError) as exc:
            # ValueError: bad JSON / non-dict config / envelope-vs-flat mismatch /
            # unaffiliated-identity conflict. OSError: a missing or unreadable --config
            # path. Both are bad INPUT — exit 2 with a clean message rather than letting
            # a FileNotFoundError/TypeError escape as a traceback + exit 1.
            print(f"error: {exc}", file=sys.stderr)
            return 2
        return 0

    if args.print_specs:
        # The materialization BRIDGE (Qt-free, model only): expand a worklist envelope (or a
        # flat config) into the N flat, fully-resolved ImageConfig specs that
        # WorklistConfig.materialize() produces — the exact per-image spec the web
        # IMAGE_SPEC_JSON channel puts in a ConfigMap and build-image.sh feeds back through
        # --print-command. One JSON object per line (JSONL); SECRET fields are blanked
        # (to_dict(include_secrets=False)) because they ride a separate channel.
        import json
        from .core.config import ImageConfig
        from .core.worklist import load_any, synthesize
        try:
            if args.config:
                base, wl = load_any(args.config)
            else:
                base, wl = ImageConfig(), None
            if wl is None:
                wl = synthesize(base)
            materialized = [cfg for _entry, cfg in wl.materialize()]
            if args.image is not None:
                if not -len(materialized) <= args.image < len(materialized):
                    print(f"error: --image {args.image} out of range "
                          f"(worklist has {len(materialized)} image(s))", file=sys.stderr)
                    return 2
                materialized = [materialized[args.image]]
            for cfg in materialized:
                print(json.dumps(cfg.to_dict(), sort_keys=True))
        except (ValueError, OSError) as exc:
            # ValueError: bad JSON / non-dict config / envelope-vs-flat mismatch /
            # unaffiliated-identity conflict. OSError: a missing or unreadable --config
            # path. Both are bad INPUT — exit 2 with a clean message rather than letting
            # a FileNotFoundError/TypeError escape as a traceback + exit 1.
            print(f"error: {exc}", file=sys.stderr)
            return 2
        return 0

    if args.askpass:
        # The GUI SUDO_ASKPASS helper: sudo -A execs this to obtain the password. Pop a
        # modal Qt password dialog and print the entry to stdout; a cancel returns non-zero
        # so sudo aborts elevation cleanly instead of hanging. Because it always renders a
        # DIALOG, a GUI-launched native build never prompts into an invisible terminal even
        # when sudo's credential cache misses. Minimal QApplication; no wizard/tray.
        from .gui.qt import QtWidgets
        _app = QtWidgets.QApplication(sys.argv if argv is None else [sys.argv[0], *argv])
        prompt = (os.environ.get("SUDO_PROMPT")
                  or "Administrator password required to build the image:")
        pw, ok = QtWidgets.QInputDialog.getText(
            None, "HugMesh Image Studio — Administrator access", prompt,
            QtWidgets.QLineEdit.EchoMode.Password)
        if not ok:
            return 1
        sys.stdout.write(pw + "\n")
        return 0

    # GUI
    from . import __version__, advanced_mode
    from .gui.qt import QtWidgets, BINDING  # noqa: N806
    from .gui.branding_icon import brand_icon
    app = QtWidgets.QApplication(sys.argv if argv is None else [sys.argv[0], *argv])
    app.setApplicationName("HugMesh Image Studio")
    # Brand identity: a title-bar/taskbar/alt-tab icon, a display name, a version and a
    # .desktop id (the last is what groups the icon correctly under Wayland). Without
    # these every window rendered the generic Python/Qt icon.
    app.setApplicationDisplayName("HugMesh Image Studio")
    app.setApplicationVersion(__version__)
    app.setWindowIcon(brand_icon())
    if hasattr(app, "setDesktopFileName"):
        app.setDesktopFileName("hugmesh-image-studio")
    if advanced_mode():
        # dev console line — expert-only now; it used to print on every launch.
        print(f"[studio] Qt binding: {BINDING}", file=sys.stderr)

    wizard = None
    golive = None
    fleet = None

    def open_studio():
        nonlocal wizard
        from .gui.wizard import StudioWizard
        if wizard is None:
            wizard = StudioWizard(
                args.generator_dir,
                remember_roles_for_passwordless_login=args.remember_roles_for_passwordless_login,
                login_manifest_path=args.login_manifest,
            )
        wizard.show()
        wizard.raise_()

    def open_golive():
        nonlocal golive
        from .gui.pages.golive import GoLiveWizard
        if golive is None:
            golive = GoLiveWizard(args.generator_dir)
        golive.show()
        golive.raise_()

    def open_fleet():
        nonlocal fleet
        from .gui.pages.fleet import FleetDialog
        if fleet is None:
            fleet = FleetDialog(args.generator_dir)
        fleet.show()
        fleet.raise_()

    # --go-live/--fleet pick WHICH window the non-tray launch opens; the trays
    # are unaffected
    if args.go_live:
        open_main = open_golive
    elif args.fleet:
        open_main = open_fleet
    else:
        open_main = open_studio

    tray_only = args.tray or args.stack_tray
    # --tray/--stack-tray each mean "only this one" in isolation; neither (default) or
    # both means "show everything relevant" — but ALWAYS as exactly ONE tray icon.
    # (The old code appended a MeshTray AND a StackTray on the default path, so the user
    # saw two indistinguishable navy-'S' icons; build_tray now yields a single icon whose
    # menu carries both sections.)
    show_mesh = args.tray or not tray_only
    show_stack = args.stack_tray or not tray_only
    tray = None
    if QtWidgets.QSystemTrayIcon.isSystemTrayAvailable():
        from .gui.tray import build_tray
        tray = build_tray(args.generator_dir, show_mesh=show_mesh, show_stack=show_stack,
                          on_open_studio=open_studio, on_open_golive=open_golive)
        tray.show()
        app.setQuitOnLastWindowClosed(False)  # keep running in the tray

    if not tray_only:
        open_main()
    elif tray is None:
        print("[studio] no system tray available; opening the wizard instead", file=sys.stderr)
        open_main()

    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
