"""HugMesh Image Studio — entry point.

  python -m hugmesh_studio               # wizard + mesh-node tray + local-stack tray
  python -m hugmesh_studio --tray        # tray only (mesh-node controller)
  python -m hugmesh_studio --stack-tray  # tray only (local dev-stack controller)
  python -m hugmesh_studio --go-live     # superadmin go-live wizard (hugmesh-go-live front-end)
  python -m hugmesh_studio --fleet       # fleet build dialog (scripts/build-all-roles.sh front-end)
  python -m hugmesh_studio --login-agent # headless: run the passwordless local-login loopback agent
  python -m hugmesh_studio --scan-hardware [--json]
      # headless: the wizard HardwarePage's probe (CPU/GPU/Wi-Fi/Bluetooth +
      # recommended build settings) as a terminal table, or --json for automation
  python -m hugmesh_studio --list-sessions [--json]
  python -m hugmesh_studio --show-session ID [--json]
  python -m hugmesh_studio --session-artifacts ID [--json]
  python -m hugmesh_studio --delete-session ID --yes [--delete-artifacts]
      # headless: the wizard Sessions page's build-session history (core/build_sessions)
  python -m hugmesh_studio --local-ai-status [--json]
  python -m hugmesh_studio --local-ai-prompt "question"
      # headless: what the local model is doing (the Studio window's Local AI bar, as text),
      # and one question to it; both exit non-zero with a plain sentence when Ollama is down
  python -m hugmesh_studio --generator-dir /path/to/hugmesh-generator
  python -m hugmesh_studio --remember-roles-for-passwordless-login
      # OPT-IN, default OFF: KeyZipPage imports also mirror human-loginable KEYS
      # roles (e.g. platform superadmin) into the local-login manifest.
"""
from __future__ import annotations

import argparse
import os
import sys

from .core import crashlog, no_console


def _default_generator_dir() -> str:
    # studio/ lives inside the generator repo; a source run defaults to the repo root.
    # The frozen exe has none, so see core/generator_dir for the rest of the order.
    from .core import generator_dir
    here = os.path.dirname(os.path.abspath(__file__))
    return generator_dir.resolve(os.path.abspath(os.path.join(here, "..", "..")))


def _choose_generator_dir(current: str, QtWidgets) -> str:  # noqa: N803
    """Ask for the checkout when ``current`` is not one, and remember the answer. A
    cancel keeps ``current``: the pages then say what is missing, as they always did."""
    from .core import generator_dir
    while not generator_dir.is_checkout(current):
        box = QtWidgets.QMessageBox(QtWidgets.QMessageBox.Icon.Information,
                                    "Choose your hugmesh-generator folder",
                                    generator_dir.not_a_checkout_message(current))
        ok = box.addButton("Choose folder…", QtWidgets.QMessageBox.ButtonRole.AcceptRole)
        box.addButton(QtWidgets.QMessageBox.StandardButton.Cancel)
        box.exec()
        if box.clickedButton() is not ok:       # exec()'s return differs by binding
            return current
        picked = QtWidgets.QFileDialog.getExistingDirectory(
            None, "hugmesh-generator folder", os.path.expanduser("~"))
        if not picked:
            return current
        current = os.path.abspath(picked)
    try:
        generator_dir.save(current)
    except OSError:
        pass                                   # remembered next time or not: never fatal
    return current


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
    # Second, before anything can spawn a process: the windowed Windows exe would
    # otherwise flash a console window for every docker/kubectl/git probe.
    no_console.install()
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
                         "sessions page)")
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
                    help="the SUDO_ASKPASS helper: acquire the admin password and print "
                         "ONLY it to stdout for `sudo -A` to consume (exit non-zero on "
                         "cancel so sudo aborts elevation — the build never runs "
                         "un-elevated). Source order: $HUGMESH_STUDIO_SUDO_PASSWORD, then "
                         "$HUGMESH_STUDIO_ASKPASS_COMMAND, then a terminal prompt when "
                         "stdin is a TTY. NEVER a dialog: with no source and no TTY it "
                         "fails fast (exit 1) instead of blocking a headless run on a "
                         "prompt nobody can answer — the dialog is --askpass-gui's opt-in.")
    ap.add_argument("--askpass-gui", action="store_true",
                    help="like --askpass, but ALSO offers the Qt password dialog (after "
                         "the env sources, before the terminal prompt) when a display is "
                         "reachable. The explicit dialog opt-in that core.build_driver's "
                         "generated SUDO_ASKPASS helper passes for a GUI-launched build. "
                         "Refused outright under $HUGMESH_STUDIO_NO_ELEVATION.")
    ap.add_argument("--askpass-no-gui", action="store_true",
                    help="kept for #221 scripts: identical to --askpass (which never pops "
                         "the dialog either). Uses $HUGMESH_STUDIO_SUDO_PASSWORD, then "
                         "$HUGMESH_STUDIO_ASKPASS_COMMAND, then a terminal prompt — only "
                         "when stdin is a TTY: with stdin redirected (`</dev/null`, "
                         "`<file`, a `while read` loop) it does not prompt on the "
                         "controlling terminal and fails fast (exit 1).")
    ap.add_argument("--config", help="config JSON (with --print-command/--print-commands/--print-specs)")
    ap.add_argument("--backend", choices=["auto", "native", "docker"], default="auto",
                    help="build backend for --print-command (auto = host default)")
    ap.add_argument("--scan-hardware", action="store_true",
                    help="headless: probe THIS machine (CPU / GPUs / Wi-Fi / Bluetooth) and "
                         "print the recommended build settings — the exact core scan the "
                         "wizard's Hardware page runs (core/hw_scan.py). Human table by "
                         "default; --json for the stable machine-readable form.")
    ap.add_argument("--list-sessions", action="store_true",
                    help="headless: the recorded build-session history, one line per "
                         "session (id, date, roles, status, artifact count), newest "
                         "first — the wizard Sessions page's Previous-builds list "
                         "(core/build_sessions.py). --json for the stable row schema.")
    ap.add_argument("--show-session", metavar="ID",
                    help="headless: one session's full record (per-image outcomes, "
                         "workdir, log path). --json prints the persisted record plus "
                         "the derived stale/artifact_count hints.")
    ap.add_argument("--session-artifacts", metavar="ID",
                    help="headless: the artifact files under one session's workdir "
                         "(absolute paths, one per line; --json = workdir + relative "
                         "names).")
    ap.add_argument("--delete-session", metavar="ID",
                    help="headless: delete a session RECORD. REFUSES without --yes, "
                         "refuses an in-progress build, and never touches the artifact "
                         "tree unless --delete-artifacts is also given — the same "
                         "three-way guard as the GUI's delete affordance.")
    ap.add_argument("--yes", action="store_true",
                    help="with --delete-session: the required explicit confirmation.")
    ap.add_argument("--delete-artifacts", action="store_true",
                    help="with --delete-session: ALSO remove the session's "
                         "<out>/sessions/<id>/ artifact tree (guarded by the same "
                         "workdir shape-check as the GUI).")
    # ── the e2e ENVIRONMENT channel (Qt-free) ───────────────────────────────
    # The GUI chooser and the terminal must select an environment the SAME way,
    # or the Studio's idea of "kind" drifts from the harness's and a GUI run
    # silently drives the wrong mesh while the log says otherwise. So both go
    # through core/e2e_environments.plan(), and this verb is how a script (or a
    # Gherkin step) reads exactly what the GUI would spawn — argv, env, refusals
    # — without spawning anything.
    ap.add_argument("--e2e-plan", action="store_true",
                    help="print what an e2e run against --e2e-env would spawn "
                         "(argv + environment + refusals). Runs NOTHING.")
    ap.add_argument("--e2e-env", metavar="ID", default=None,
                    help="which mesh an e2e run drives: docker | kind | qemu "
                         "(default: docker, which is what an unset SNAP_ENV has "
                         "always meant). Used with --e2e-plan/--e2e-environments.")
    ap.add_argument("--e2e-boot", action="store_true",
                    help="with --e2e-plan: ask for the mesh to be BROUGHT UP too. "
                         "Always refused — printed so the refusal and the exact "
                         "command to type by hand are scriptable.")
    ap.add_argument("--e2e-environments", action="store_true",
                    help="print the e2e environment catalogue (the chooser's model).")
    ap.add_argument("--e2e-evidence-live", action="store_true",
                    help="with --e2e-evidence: read the manifest.jsonl APPEND LOG "
                         "instead of manifest.json. Use this while a run is still "
                         "going: manifest.json is rewritten at the end of every "
                         "feature spec file, so mid-run it is a truncated index "
                         "and good artefacts read as unindexed.")
    ap.add_argument("--e2e-evidence", metavar="RUN_DIR",
                    help="read a BDD run's evidence manifest and report it grouped "
                         "by environment and interface, with the index verified "
                         "against the disk BOTH ways. Accepts a run dir or a "
                         "report dir containing bdd-steps/.")
    ap.add_argument("--local-ai-status", action="store_true",
                    help="headless: what the local AI is doing - the Ollama server, the model "
                         "loaded, the queue, the drafts and the Studio's running builds (the "
                         "Studio window's Local AI bar as text). Exits 1 with the problem and "
                         "its fix when Ollama is not installed, not answering or has no model. "
                         "With --json: the same snapshot as JSON.")
    ap.add_argument("--local-ai-prompt", metavar="TEXT", default=None,
                    help="headless: ask the local model one question (loopback Ollama only) and "
                         "print the answer; exits 1 with a plain sentence when Ollama is down.")
    ap.add_argument("--json", action="store_true",
                    help="with --scan-hardware/--list-sessions/--show-session/"
                         "--session-artifacts/--local-ai-status: machine-readable JSON on stdout.")
    # ── the Go-Live "Export to GitHub org" step, from a terminal (Qt-free) ──────
    # --org-export PLAN|APPLY with --domain/--org or --config, --rename-map, --out;
    # APPLY refuses without --apply. The engine is core/org_export.py.
    from .core.org_export import add_cli_arguments as _add_org_export_args
    _add_org_export_args(ap)
    args = ap.parse_args(argv)

    if args.org_export:
        # Qt-free path: the same plan()/apply() the GUI step and the TUI step call,
        # printed as the same text. Runs only git and gh (through the engine's one
        # runner), never a Qt binding.
        from .core.org_export import run_cli as _run_org_export
        return _run_org_export(args, args.generator_dir)

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
            emit_note_once,
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
            emit_note_once(resolve_installer_ui_default(cfg))
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

    if args.e2e_environments:
        # Qt-free: the chooser's model as data, so a script and the combo box
        # can never disagree about which environments exist.
        import json
        from .core import e2e_environments as e2e_env
        rows = e2e_env.describe()
        if args.json:
            print(json.dumps(rows, sort_keys=True))
        else:
            for r in rows:
                print("%-7s %s" % (r["id"], r["label"]))
                print("        run  : make %s   (with %s=%s)"
                      % (r["makeTarget"], e2e_env.ENV_VAR, r["id"]))
                print("        pins : %s" % (", ".join(r["pins"]) or "<none>"))
                print("        start: %s" % r["startHint"])
        return 0

    if args.e2e_plan:
        # Qt-free: EXACTLY what the GUI chooser would hand the runner. Printing
        # it rather than running it is the whole point — this is the channel the
        # guard asserts on, so "the selected environment reaches the spawned
        # runner's argv/env" is a measurable claim instead of a comment.
        import json
        from .core import e2e_environments as e2e_env
        try:
            p = e2e_env.plan(args.e2e_env or e2e_env.DEFAULT_ENVIRONMENT,
                             boot=args.e2e_boot)
        except ValueError as exc:
            print("error: %s" % exc, file=sys.stderr)
            return 2
        if args.json:
            print(json.dumps(p.to_dict(), sort_keys=True))
        else:
            print("environment : %s" % p.environment)
            print("argv        : %s" % " ".join(p.argv))
            for k in sorted(p.env):
                print("env         : %s=%s" % (k, p.env[k]))
            print("runnable    : %s" % ("yes" if p.runnable else "NO"))
            for r in p.refusals:
                print("REFUSED     : %s" % r)
            print("start hint  : %s" % p.start_hint)
        return 0

    if args.e2e_evidence:
        # Qt-free: the SAME model the Studio's evidence browser renders, so the
        # terminal and the GUI can never show different numbers. Exits non-zero
        # when the index and the disk disagree — a manifest that lies is worse
        # than no manifest, because a reviewer counts the rows and believes them.
        import json
        from .core import e2e_evidence
        target = args.e2e_evidence
        dirs = [target] if os.path.isfile(os.path.join(target, "manifest.json")) \
            or os.path.isfile(os.path.join(target, "manifest.jsonl")) \
            else e2e_evidence.run_dirs(target)
        if not dirs:
            print("error: no evidence run directory under %s (looked for "
                  "manifest.json / bdd-steps/*/manifest.json)" % target,
                  file=sys.stderr)
            return 2
        bad = 0
        reports = []
        for d in dirs:
            man = e2e_evidence.load(d, prefer_jsonl=args.e2e_evidence_live)
            rep = e2e_evidence.report(man)
            reports.append(rep)
            if rep["problems"] or not rep["verification"]["ok"]:
                bad += 1
        if args.json:
            print(json.dumps(reports if len(reports) > 1 else reports[0],
                             sort_keys=True))
        else:
            for rep in reports:
                print("run %s  (%s)" % (rep["runId"] or "?", rep["root"]))
                print("  schema     : %s" % (rep["schema"] or "<none>"))
                print("  artefacts  : %d (%d from failed steps)"
                      % (rep["counts"]["rows"], rep["counts"]["failed"]))
                print("  by env     : %s" % rep["counts"]["byEnv"])
                print("  by iface   : %s" % rep["counts"]["byInterface"])
                print("  by kind    : %s" % rep["counts"]["byKind"])
                print("  index      : %s" % rep["verification"]["summary"])
                for m in rep["verification"]["missing"]:
                    print("  MISSING    : %s" % m)
                for o in rep["verification"]["orphans"]:
                    print("  ORPHAN     : %s" % o)
                for m in rep["verification"]["malformed"]:
                    print("  MALFORMED  : %s" % m)
                for pr in rep["problems"]:
                    print("  PROBLEM    : %s" % pr)
        return 1 if bad else 0

    if args.scan_hardware:
        # Qt-free path: the exact core probe the wizard's Hardware page runs
        # (core/hw_scan.py — subprocess/regex only), exposed so "generate an image
        # tuned to this machine" is scriptable, not GUI-only (#49).
        import json
        from .core import hw_scan
        s = hw_scan.scan()
        print(json.dumps(hw_scan.to_dict(s), sort_keys=True) if args.json
              else hw_scan.format_table(s))
        return 0

    if args.local_ai_status or args.local_ai_prompt is not None:
        # Qt-free path: the same snapshot and the same loopback-only prompt the Studio
        # window's Local AI bar and the terminal UI use (core/local_ai_status.py).
        import json
        from .core import local_ai_status as lai
        if args.local_ai_status:
            snap = lai.read_snapshot()
            print(json.dumps(snap.to_dict(), sort_keys=True) if args.json
                  else lai.format_status(snap))
            if not snap.ok:
                print(f"error: {snap.problem} {snap.fix} (see {snap.doc})", file=sys.stderr)
                return 1
            return 0
        if not args.local_ai_prompt.strip():
            # Same answer as ``local_ai_status prompt`` and the dock: an empty question is
            # not sent. Exit 2 is "bad input", the code the other flags use for it.
            print('usage: python -m hugmesh_studio --local-ai-prompt "question"',
                  file=sys.stderr)
            return 2
        # sys.stdout is None in the WINDOWED exe (hugmesh-studio.exe, console=False):
        # writing to it raised AttributeError on the first chunk. The console exe
        # (hugmesh-studio-cli.exe) has one; without it the answer has nowhere to go.
        if sys.stdout is None:
            return 2
        try:
            lai.send_prompt(args.local_ai_prompt,
                            on_chunk=lambda c: (sys.stdout.write(c), sys.stdout.flush()))
        except lai.LocalAIError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        print()
        return 0

    if args.list_sessions or args.show_session or args.session_artifacts \
            or args.delete_session:
        # Qt-free path: the build-session history (core/build_sessions.py — the same
        # records/guards the wizard Sessions page renders and the TUI drives; all the
        # listing/formatting lives in core so every front-end shows the same truth).
        import json
        from .core import build_sessions

        if args.list_sessions:
            sessions = build_sessions.load_all()
            if args.json:
                print(json.dumps([build_sessions.session_row(s) for s in sessions],
                                 sort_keys=True))
            else:
                for s in sessions:
                    print(build_sessions.format_session_line(s))
            return 0

        sid = args.show_session or args.session_artifacts or args.delete_session
        s = build_sessions.find(sid)
        if s is None:
            print(f"error: no build session {sid!r} under "
                  f"{build_sessions.sessions_dir()}", file=sys.stderr)
            return 2

        if args.show_session:
            print(json.dumps(build_sessions.session_detail(s), sort_keys=True)
                  if args.json else build_sessions.format_session_detail(s))
            return 0

        if args.session_artifacts:
            rel = build_sessions.artifact_paths(s)
            if args.json:
                print(json.dumps({"id": s.id, "workdir": s.workdir, "artifacts": rel},
                                 sort_keys=True))
            else:
                for r in rel:
                    print(os.path.join(s.workdir, r))
            return 0

        # --delete-session: refuse without the explicit --yes (a destructive verb must
        # never fire from a bare invocation), and let core's is_active guard refuse a
        # live build — exactly the GUI delete affordance's three-way guard.
        if not args.yes:
            print(f"error: --delete-session {s.id} refused: pass --yes to confirm "
                  "(add --delete-artifacts to also remove its artifact tree)",
                  file=sys.stderr)
            return 2
        if not build_sessions.delete(s, remove_artifacts=args.delete_artifacts):
            print(f"error: session {s.id} is a build in progress — not deleted",
                  file=sys.stderr)
            return 1
        print(f"deleted session {s.id}"
              + (" (artifacts removed)" if args.delete_artifacts else " (record only)"))
        return 0

    if args.askpass or args.askpass_no_gui or args.askpass_gui:
        # The SUDO_ASKPASS helper: `sudo -A` execs this to obtain the password. Qt-free
        # core (core/askpass.py) acquires it and writes ONLY the password to stdout for
        # sudo to consume; a cancel/no-password returns non-zero so sudo ABORTS elevation
        # instead of the build running un-elevated (the #222 failure). The Qt dialog is
        # an explicit OPT-IN (--askpass-gui, what the driver's generated helper passes
        # for a GUI-launched build); --askpass / --askpass-no-gui (#221) never pop it,
        # and with no credential source and no TTY on stdin they fail fast rather than
        # hang a headless run. Every prompt and diagnostic goes to stderr, never the
        # password channel.
        from .core.askpass import run_askpass
        return run_askpass(argv, allow_gui=bool(args.askpass_gui and not args.askpass_no_gui))

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

    golive = None
    fleet = None

    # ── ASK 16: is a Studio already open? ────────────────────────────────────────
    # Detection is a socket handshake with the running process (core/instance.py), not
    # a pid-file guess — and every failure mode reads as "no instance", so a crashed
    # Studio can never lock the operator out of their own tool. Only the DEFAULT studio
    # launch coordinates: --tray/--stack-tray/--go-live/--fleet each name a specific
    # window the operator asked for by hand, and second-guessing that would be rude.
    from .core import instance
    from .gui import shell as shell_mod
    coordinates = not (args.tray or args.stack_tray or args.go_live or args.fleet)
    # Claim the endpoint ONLY on the coordinating launch. A --tray/--go-live/--fleet
    # process that grabbed it without draining commands would be a black hole: a later
    # default launch would detect "an instance is running" and send it a NEW-WINDOW
    # nobody reads.
    server = instance.InstanceServer() if coordinates else None
    primary = server.start() if server is not None else True
    if coordinates and not primary:
        # A live Studio answered. Ask, then have IT do the work — one process keeps
        # owning every build, which is what makes the tray's roster complete and what
        # "builds continue in the background" actually means.
        choice = shell_mod.ask_already_running()
        if choice == shell_mod.CHOICE_NEW_WINDOW:
            instance.send(instance.CMD_NEW_WINDOW)
        elif choice == shell_mod.CHOICE_RESET:
            instance.send(instance.CMD_RESET)
        return 0

    args.generator_dir = _choose_generator_dir(args.generator_dir, QtWidgets)
    shell = shell_mod.StudioShell(
        args.generator_dir,
        remember_roles_for_passwordless_login=args.remember_roles_for_passwordless_login,
        login_manifest_path=args.login_manifest,
        server=server)
    shell.install_quit_guard(app)

    def open_studio():
        # the launch window. The old code capped the Studio at ONE forever-window via a
        # `nonlocal wizard`; the shell can now mint as many as ask 16 needs.
        return shell.open_or_raise()

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
        # ONE icon, now carrying the ask-16 "Running builds" submenu (each entry opens
        # a window for that build). The shell owns the wiring so the roster, the
        # windows and the build supervisor are the same three objects everywhere.
        tray = shell.install_tray(show_mesh=show_mesh, show_stack=show_stack,
                                  on_open_golive=open_golive)
        tray.show()
        app.setQuitOnLastWindowClosed(False)  # keep running in the tray

    if not tray_only:
        open_main()
    elif tray is None:
        print("[studio] no system tray available; opening the wizard instead", file=sys.stderr)
        open_main()

    # With no tray there is no other way back into the Studio, so closing the last
    # window should end the process — but ONLY once nothing is still building
    # (shell._sync_lifetime). Enabling it also turns Qt's quitOnLastWindowClosed off,
    # which is what stops a window close from quitting the app and cancelling the build.
    #
    # Scoped deliberately:
    #   * with a tray, the tray branch above already turned the flag off and the tray
    #     itself is the reason to stay, so autoquit would do nothing anyway;
    #   * --go-live/--fleet open a single-purpose window the shell does not track, so
    #     turning the flag off for them would leave an invisible process with nothing
    #     on screen and no way back. Their pre-existing quit-on-close is correct.
    if tray is None and open_main is open_studio:
        shell.enable_autoquit(True)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
