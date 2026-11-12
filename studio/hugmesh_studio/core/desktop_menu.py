"""The Desktop step for scripts/build-menu.sh (``make menu``) — Qt-free, stdlib only.

The make menu is bash; the Desktop step's catalog and rules live in
:mod:`core.desktop_spec`. Rather than re-type them in shell, the menu runs this module
(the way it already runs core.local_mesh) and renders what it prints, so the menu offers
the same options, greys the same ones with the same reasons and emits the same builder
flags as the Studio's GUI, text UI and CLI.

    python3 -m hugmesh_studio.core.desktop_menu TARGET STATE CMD [ARGS...] [--opt ...]

TARGET is the make target the menu is about to run (x86-standalone-thin, rpi-desktop,
frite, ...). STATE is the menu's per-target JSON (it holds no secret). Commands:

    rows                  one TSV line per row: TAG, live|info|grey, LABEL, TEXT
    choices TAG           line 1: the row's kind; then VALUE, LABEL, on|off|grey, REASON
    set TAG VALUE...      change one option (rc 2 and the reason on stderr if refused)
    flags                 the builder flags as ONE shell-quoted string (rc 2 + reasons
                          on stderr when the build must not start)
    problems              every problem, "error: ..." / "warning: ..."
    pretend [--apply]     run the emerge --pretend check (x86) via core.desktop_cli

Options every command takes: ``--standalone`` (an ARM desktop built --standalone),
``--frite-desktop light|none``, ``--owned gpu,steam,user`` (fields the menu's own screen
already emits: their flags are left out of ``flags``) with ``--gpu X --steam Y --user Z``
(their current values), ``--pass-file REL`` (``flags``: the staged 0600 NAME:PASSWORD
file for the extra accounts, relative to the checkout; read only to check each account
has a password, never printed) and ``--generator-dir DIR`` (``pretend``).

Passwords never reach this module's argv: the menu types them masked and stages them in
a 0600 file under the checkout, exactly like the login password (_stage_login_pass).
"""
from __future__ import annotations

import json
import os
import shlex
import sys

from . import desktop_spec as ds

#: make target -> (platform, Studio role id, mode)
TARGETS = {
    "x86-standalone-thin": ("x86", "standalone-thin", "standalone"),
    "x86-standalone-thick": ("x86", "standalone-thick", "standalone"),
    "x86-standalone-unaffiliated": ("x86", "standalone-unaffiliated", "standalone"),
    "x86-laptop": ("x86", "laptop", "cloud"),
    "x86-chromebook": ("x86", "chromebook", "cloud"),
    "x86-desktop": ("x86", "desktop", "cloud"),
    "rpi-desktop": ("rpi5", "rpi5-desktop", "cloud"),
    "jetson-desktop": ("jetson", "jetson-desktop", "cloud"),
    "frite": ("frite", "frite", "cloud"),
    "orangepi5": ("orangepi5", "orangepi5", "cloud"),
    "orangepi4-lts": ("orangepi4-lts", "orangepi4-lts", "cloud"),
}

#: The menu's rows: tag -> (kind, the option ids it covers). The window managers and
#: compositors share one checklist row; the info rows have nothing to choose.
ROWS: tuple[tuple[str, str, tuple[str, ...]], ...] = (
    ("environment", "menu", ("environment",)),
    ("steam", "menu", ("steam",)),
    ("login_manager", "info", ("login_manager",)),
    ("openbox", "info", ("openbox",)),
    ("sessions", "checklist", ds.SESSION_OPTION_IDS),
    ("default_session", "menu", ("default_session",)),
    ("gpu_driver", "menu", ("gpu_driver",)),
    ("video_cards", "checklist", ("video_cards",)),
    ("primary_account", "account", ("primary_account",)),
    ("extra_users", "users", ("extra_users",)),
    ("apps_native", "apps", ("apps_native",)),
    ("apps_flatpak", "apps", ("apps_flatpak",)),
    ("flatpak_remotes", "lines", ("flatpak_remotes",)),
    ("python", "python", ("python",)),
    ("overlay", "overlay", ("overlay",)),
    ("pretend", "action", ("pretend",)),
    ("assistant", "info", ("assistant",)),
)
ROW_KIND = {t: k for t, k, _ in ROWS}
ROW_OPTIONS = {t: o for t, _, o in ROWS}

STEAM_CHOICES = ("native", "flatpak", "none")
OWNABLE = ("gpu", "steam", "user")


class Refused(Exception):
    """A change the step refuses; the message is the reason the menu shows."""


# ── state ─────────────────────────────────────────────────────────────────────


def _parse(argv: list[str]) -> tuple[list[str], dict]:
    pos: list[str] = []
    opt = {"standalone": False, "frite_desktop": "", "owned": set(), "gpu": None,
           "steam": None, "user": None, "pass_file": "", "generator_dir": "", "apply": False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--standalone":
            opt["standalone"] = True
        elif a == "--apply":
            opt["apply"] = True
        elif a in ("--frite-desktop", "--owned", "--gpu", "--steam", "--user", "--pass-file",
                   "--generator-dir"):
            if i + 1 >= len(argv):
                raise Refused(f"{a} needs a value")
            v = argv[i + 1]
            i += 1
            key = a[2:].replace("-", "_")
            if key == "owned":
                opt["owned"] = {x for x in v.replace(",", " ").split() if x in OWNABLE}
            else:
                opt[key] = v
        else:
            pos.append(a)
        i += 1
    return pos, opt


def load(target: str, state: str, opt: dict):
    """The ImageConfig standing for TARGET, from STATE (or fresh), with the fields the
    menu owns elsewhere stamped on. Returns (cfg, meta)."""
    from .config import ImageConfig
    if target not in TARGETS:
        raise Refused(f"{target} builds no desktop the Desktop step knows")
    plat, role, mode = TARGETS[target]
    data: dict = {}
    if state and os.path.isfile(state):
        with open(state, encoding="utf-8") as fh:
            data = json.load(fh)
    meta = dict(data.get("menu") or {})
    cfg = ImageConfig.from_dict(dict(data.get("config") or {}))
    cfg.platform, cfg.role = plat, role
    cfg.mode = "standalone" if (mode == "standalone" or opt["standalone"]) else mode
    cfg.standalone = cfg.mode == "standalone" and not role.startswith("standalone-")
    if plat == "frite":
        cfg.desktop = opt["frite_desktop"] or cfg.desktop or "light"
    if not meta.get("account_set"):
        cfg.local_user, cfg.local_admin = "", False
    if opt["gpu"] is not None:
        cfg.gpu_driver = opt["gpu"] or "auto"
    if opt["steam"] is not None:
        cfg.steam = opt["steam"]
    if opt["user"] is not None:
        cfg.local_user = opt["user"]
    return cfg, meta


def save(state: str, cfg, meta: dict) -> None:
    d = cfg.to_dict()
    for k in ("local_pass", "extra_local_passes"):
        d.pop(k, None)
    tmp = state + ".tmp"
    os.makedirs(os.path.dirname(os.path.abspath(state)), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"config": d, "menu": meta}, fh, indent=2)
    os.replace(tmp, state)


# ── rows / choices ─────────────────────────────────────────────────────────────


def row_state(cfg, tag: str) -> tuple[str, str]:
    """A row's state: the first live option it covers decides; a row whose every option
    is greyed is greyed with the first one's reason."""
    states = [ds.option_state(cfg, o, "menu") for o in ROW_OPTIONS[tag]]
    for st, text in states:
        if st == "live":
            if tag == "sessions":
                return "live", " ".join(ds.spec_of(cfg).sessions) or "none"
            return st, text
    return states[0]


def rows(cfg) -> list[tuple[str, str, str, str]]:
    out = []
    for tag, _kind, oids in ROWS:
        st, text = row_state(cfg, tag)
        label = "Window managers / compositors" if tag == "sessions" else ds.OPTION_LABELS[oids[0]]
        out.append((tag, st, label, text))
    return out


def choices(cfg, tag: str, owned: frozenset | set = frozenset()) -> list[tuple[str, str, str, str]]:
    spec = ds.spec_of(cfg)
    if tag == "environment":
        cur = ds.environment(cfg)
        return [(e, ds.ENVIRONMENTS[e][0], "on" if e == cur else "off", "")
                for e in ds.environment_choices(cfg)]
    if tag == "steam":
        cur = getattr(cfg, "steam", "") or ""
        return [(s, s, "on" if s == cur else "off", "") for s in STEAM_CHOICES]
    if tag == "sessions":
        return [(s.name, s.label, "on" if s.name in spec.sessions else "off", "")
                for s in ds.SESSION_CATALOG if s.name not in ds.ALWAYS_ON_SESSIONS]
    if tag == "default_session":
        cur = spec.default_session
        return [("-", f"the environment's own ({ds.de_session(cfg)})", "on" if not cur else "off", "")] + [
            (s, s, "on" if s == cur else "off", "") for s in ds.installed_sessions(cfg, spec)]
    if tag == "gpu_driver":
        from .config import GPU_DRIVER_CHOICES
        cur = getattr(cfg, "gpu_driver", "auto") or "auto"
        # "auto" emits nothing; a screen that always emits --gpu-driver (the x86
        # standalone screen owns it there) needs a real preset.
        return [(g, f"{g} (VIDEO_CARDS {ds.X86_GPU_VIDEO_CARDS.get(g, 'by role') or 'none'})",
                 "on" if g == cur else "off", "") for g in GPU_DRIVER_CHOICES
                if not (g == "auto" and "gpu" in owned)]
    if tag == "video_cards":
        return [(t, ds.VIDEO_CARD_LABELS.get(t, t), "on" if t in spec.video_cards else "off", "")
                for t in ds.VIDEO_CARD_TOKENS]
    if tag in ("apps_native", "apps_flatpak"):
        how = "native" if tag == "apps_native" else "flatpak"
        key = "atom" if how == "native" else "flatpak"
        have = {a.id for a in spec.apps if a.delivery == how}
        out = []
        for a in ds.app_catalog():
            if not a.get(key):
                continue
            why = ds.catalog_blocks(cfg, a).get(how, "")
            out.append((a["id"], f"{a['label']} ({a[key]})",
                        "grey" if why else ("on" if a["id"] in have else "off"), why))
        out += [(a.id, f"{a.label} (added by hand)", "on", "") for a in spec.apps
                if a.delivery == how and not any(c["id"] == a.id for c in ds.app_catalog())]
        return out
    if tag == "python":
        return [(t, t, "on" if t in spec.python_extra_targets else "off", "")
                for t in ds.PYTHON_TARGET_CHOICES]
    if tag == "flatpak_remotes":
        return [(k, f"{k}={v}", "on", "") for k, v in sorted(spec.flatpak_remotes.items())]
    if tag == "extra_users":
        return [(u.name, u.name + (" (administrator)" if u.admin else ""), "on", "")
                for u in spec.extra_users]
    if tag == "overlay":
        return ([("use", f"package.use {x}", "on", "") for x in spec.use_lines]
                + [("kw", f"accept_keywords {x}", "on", "") for x in spec.keyword_lines])
    if tag == "primary_account":
        return [("name", (getattr(cfg, "local_user", "") or "").strip(), "on", ""),
                ("admin", "administrator", "on" if getattr(cfg, "local_admin", False) else "off", "")]
    return []


# ── set ───────────────────────────────────────────────────────────────────────


def _check(cfg, spec) -> None:
    bad = ds.grammar_errors(cfg, spec)
    if bad:
        raise Refused(bad[0])


def _words(args: list[str]) -> list[str]:
    return " ".join(args).split()


def set_option(cfg, meta: dict, tag: str, args: list[str]) -> str:
    """Apply one change; returns what to say. Raises Refused with the reason."""
    if tag not in ROW_KIND:
        raise Refused(f"no such Desktop option: {tag}")
    st, text = row_state(cfg, tag)
    if st != "live":
        raise Refused(text)
    spec = ds.spec_of(cfg)
    if tag == "environment":
        try:
            ds.set_environment(cfg, args[0])
        except (ValueError, IndexError) as e:
            raise Refused(str(e) or "environment lxde|xfce|plasma") from None
        return f"environment: {args[0]}"
    if tag == "steam":
        if not args or args[0] not in STEAM_CHOICES + ("default", ""):
            raise Refused("steam native|flatpak|none")
        cfg.steam = "" if args[0] == "default" else args[0]
        return f"Steam: {args[0]}"
    if tag == "gpu_driver":
        from .config import GPU_DRIVER_CHOICES
        if not args or args[0] not in GPU_DRIVER_CHOICES:
            raise Refused("gpu driver: one of " + " ".join(GPU_DRIVER_CHOICES))
        cfg.gpu_driver = args[0]
        return f"GPU driver: {args[0]}"
    if tag == "primary_account":
        from .validate import validate_username
        name = args[0] if args else ""
        try:
            validate_username(name)
        except ValueError as e:
            raise Refused(str(e)) from None
        cfg.local_user = name
        cfg.local_admin = len(args) > 1 and args[1] == "admin"
        meta["account_set"] = True
        return f"login account: {name}" + (" (administrator)" if cfg.local_admin else "")
    if tag == "sessions":
        pick = _words(args)
        for s in pick:
            if s not in ds.SESSIONS or s in ds.ALWAYS_ON_SESSIONS:
                raise Refused(f"unknown session {s!r}")
        spec.sessions = list(dict.fromkeys(pick))
    elif tag == "default_session":
        v = args[0] if args else "-"
        spec.default_session = "" if v == "-" else v
    elif tag == "video_cards":
        spec.video_cards = list(dict.fromkeys(_words(args)))
    elif tag == "extra_users":
        sub = args[0] if args else ""
        if sub == "add" and len(args) >= 2:
            name, admin = args[1], len(args) > 2 and args[2] == "admin"
            spec.extra_users = [u for u in spec.extra_users if u.name != name]
            spec.extra_users.append(ds.ExtraUser(name, admin))
        elif sub == "rm" and len(args) >= 2:
            spec.extra_users = [u for u in spec.extra_users if u.name != args[1]]
        else:
            raise Refused("extra_users add NAME [admin] | rm NAME")
    elif tag in ("apps_native", "apps_flatpak"):
        how = "native" if tag == "apps_native" else "flatpak"
        if args and args[0] == "add":
            text = args[1] if len(args) > 1 else ""
            if how == "flatpak":
                remote, _, flat = text.rpartition(":")
                app = ds.DesktopApp(id=flat, label=flat, delivery="flatpak", flatpak=flat,
                                    remote=remote or "flathub")
            else:
                app = ds.DesktopApp(id=text, label=text, delivery="native", atom=text)
            spec.apps = [a for a in spec.apps if a.id != app.id]
            spec.apps.append(app)
        elif args and args[0] == "rm":
            spec.apps = [a for a in spec.apps if not (a.id == args[1] and a.delivery == how)]
        else:
            pick = _words(args)
            keep = [a for a in spec.apps if a.delivery != how or
                    not any(c["id"] == a.id for c in ds.app_catalog())]
            new = []
            for app_id in pick:
                app = ds.catalog_app(app_id, how)
                if app is None:
                    raise Refused(f"{app_id} is not offered as {how}")
                new.append(app)
            # one delivery per app: picking it here drops it from the other delivery
            ids = {a.id for a in new}
            spec.apps = [a for a in keep if a.id not in ids] + new
        for a in spec.apps:
            why = ds.delivery_block(cfg, a)
            if why:
                raise Refused(f"{a.label}: {why}")
    elif tag == "flatpak_remotes":
        sub = args[0] if args else ""
        if sub == "add" and len(args) >= 2:
            name, _, url = args[1].partition("=")
            spec.flatpak_remotes[name] = url
        elif sub == "rm" and len(args) >= 2:
            spec.flatpak_remotes.pop(args[1], None)
        else:
            raise Refused("flatpak_remotes add NAME=URL | rm NAME")
    elif tag == "python":
        if args and args[0] == "single":
            v = args[1] if len(args) > 1 else "-"
            spec.python_single_target = "" if v == "-" else v
        else:
            spec.python_extra_targets = list(dict.fromkeys(_words(args)))
    elif tag == "overlay":
        if len(args) < 3 or args[0] not in ("use", "kw") or args[1] not in ("add", "rm"):
            raise Refused("overlay use|kw add|rm LINE")
        kind = "package.use" if args[0] == "use" else "accept_keywords"
        target = spec.use_lines if args[0] == "use" else spec.keyword_lines
        line = ds.normalise_line(" ".join(args[2:]))
        if args[1] == "rm":
            if line in target:
                target.remove(line)
                spec.history.append({"op": "remove", "kind": kind, "line": line,
                                     "source": "operator", "at": ds._now()})
        else:
            why = ds.check_change(ds.OverlayChange(kind, line), cfg)
            if why:
                raise Refused(why)
            if line not in target:
                target.append(line)
                spec.history.append({"op": "add", "kind": kind, "line": line,
                                     "source": "operator", "at": ds._now()})
    else:
        raise Refused(f"{tag} has nothing to set here")
    _check(cfg, spec)
    ds.store(cfg, spec)
    return ""


# ── emission ──────────────────────────────────────────────────────────────────


def _passwords(pass_file: str, root: str) -> dict[str, str]:
    if not pass_file:
        return {}
    path = pass_file if os.path.isabs(pass_file) else os.path.join(root, pass_file)
    try:
        with open(path, encoding="utf-8") as fh:
            return ds.parse_passwords(fh.read())
    except OSError:
        return {}


def flag_list(cfg, meta: dict, opt: dict, *, root: str = "") -> tuple[list[str], list[str]]:
    """(builder flags, reasons the build must not start)."""
    if not ds.applies(cfg):
        return [], []
    spec = ds.spec_of(cfg)
    owned = opt["owned"]
    passwords = _passwords(opt["pass_file"], root) if spec.extra_users else None
    errs = ds.errors(cfg, passwords=passwords)
    a: list[str] = []
    x86 = ds.is_x86(cfg)
    if x86:
        from .config import role_presets_capable
        if getattr(cfg, "capable", False) and not role_presets_capable(cfg.role):
            a.append("--capable")
        if getattr(cfg, "desktop", "") and cfg.platform == "x86":
            a += ["--desktop", cfg.desktop]
        if "steam" not in owned and getattr(cfg, "steam", ""):
            a += ["--steam", cfg.steam]
        if "gpu" not in owned and (getattr(cfg, "gpu_driver", "auto") or "auto") != "auto":
            a += ["--gpu-driver", cfg.gpu_driver]
    if meta.get("account_set"):
        if "user" not in owned and (cfg.local_user or "").strip():
            a += ["--local-user", cfg.local_user]
        if cfg.local_admin:
            a.append("--local-admin")
    natives = ds.native_atoms(spec)
    if natives:
        a += ["--packages-add", " ".join(natives)]
    for x in ds.cli_args(cfg):
        a.append(opt["pass_file"] if x == ds.EXTRA_PASS_PLACEHOLDER else x)
    return a, errs


# ── main ──────────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None, out=None, err=None) -> int:
    out, err = out or sys.stdout, err or sys.stderr
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        pos, opt = _parse(argv)
        if len(pos) < 3:
            print(__doc__, file=err)
            return 2
        target, state, cmd, args = pos[0], pos[1], pos[2], pos[3:]
        cfg, meta = load(target, state, opt)
        if cmd == "rows":
            for r in rows(cfg):
                print("\t".join(x.replace("\t", " ").replace("\n", " ") for x in r), file=out)
            return 0
        if cmd == "choices":
            tag = args[0] if args else ""
            if tag not in ROW_KIND:
                raise Refused(f"no such Desktop option: {tag}")
            print(ROW_KIND[tag], file=out)
            for r in choices(cfg, tag, opt["owned"]):
                print("\t".join(x.replace("\t", " ").replace("\n", " ") for x in r), file=out)
            return 0
        if cmd == "set":
            if not args:
                raise Refused("set TAG VALUE...")
            said = set_option(cfg, meta, args[0], args[1:])
            save(state, cfg, meta)
            if said:
                print(said, file=out)
            return 0
        if cmd == "problems":
            spec = ds.spec_of(cfg)
            pw = _passwords(opt["pass_file"], os.getcwd()) if opt["pass_file"] else None
            for p in ds.problems(cfg, spec, passwords=pw):
                print(f"{p.level}: {p.text}", file=out)
            return 0
        if cmd == "flags":
            flags, errs = flag_list(cfg, meta, opt, root=os.getcwd())
            if errs:
                for e in errs:
                    print(e, file=err)
                return 2
            print(" ".join(shlex.quote(x) for x in flags), file=out)
            return 0
        if cmd == "pretend":
            return _pretend(target, state, cfg, meta, opt, out, err)
        raise Refused(f"unknown command {cmd!r}")
    except Refused as e:
        print(str(e), file=err)
        return 2
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"not done: {e}", file=err)
        return 2


def _pretend(target, state, cfg, meta, opt, out, err) -> int:
    """Run the same check as the GUI button / TUI ``p`` / ``--desktop-pretend``: on a
    config file beside STATE, then fold its result (and, with --apply, portage's own
    suggestion) back into STATE."""
    from . import desktop_cli
    st, why = ds.option_state(cfg, "pretend", "menu")
    if st != "live":
        print(why, file=err)
        return 2
    gen = opt["generator_dir"] or os.getcwd()
    path = state + ".pretend.json"
    cfg.save(path)
    rc = desktop_cli.pretend(path, generator_dir=gen, apply_fixes=opt["apply"], out=out, err=err)
    from .config import ImageConfig
    try:
        back = ImageConfig.load(path)
        cfg.desktop_spec = back.desktop_spec
        save(state, cfg, meta)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    return rc


if __name__ == "__main__":
    from .entry import bootstrap as _bootstrap   # the Mac PATH hook: core/entry.py
    _bootstrap()
    sys.exit(main())
