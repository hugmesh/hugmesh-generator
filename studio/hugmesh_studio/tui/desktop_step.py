"""The Desktop step, TUI face (the twin of gui/pages/desktop.py).

Same model, same rules, same emission — all from :mod:`core.desktop_spec`; the pretend
run and its parser from :mod:`core.desktop_pretend`. The GUI types an extra account's
first-login password into a masked field; here it is read from a FILE (``pass=FILE``,
first line) so it never appears on the screen or in a scrollback. ``p`` runs the
emerge --pretend check (the same builder run the GUI starts, gated the same way, one
at a time machine-wide) and ``a`` applies the changes portage itself named, recorded in
the spec's history exactly as the GUI's "Apply portage's changes" does.
"""
from __future__ import annotations

import os
import shlex

from ..core import desktop_pretend as dp
from ..core import desktop_spec as ds

COMMANDS = (
    ("env lxde|xfce|plasma", "the desktop environment (x86; the role may pin it)"),
    ("steam default|native|flatpak|none", "Steam delivery (x86)"),
    ("s +i3 -picom ...", "add/remove window managers and compositors (x86)"),
    ("default NAME|-", "the greeter's default session"),
    ("cards LIST|-", "choose VIDEO_CARDS yourself (x86), '-' = the GPU driver's list"),
    ("user add NAME [admin] pass=FILE", "an extra local account (password: FILE's first line)"),
    ("user rm NAME", "remove an extra account"),
    ("app ID native|flatpak|off", "a catalog app and how it is delivered"),
    ("app add ATOM | REMOTE:APP.ID", "another app (native atom or Flatpak)"),
    ("remote NAME=URL | remote rm NAME", "an extra Flatpak remote"),
    ("py +python3_13 -python3_14", "extra Python targets"),
    ("py single TARGET|-", "PYTHON_SINGLE_TARGET"),
    ("use LINE | use rm LINE", "a package.use line"),
    ("kw LINE | kw rm LINE", "a package.accept_keywords line"),
    ("p", "check with emerge --pretend (x86; runs the builder, minutes)"),
    ("a / u", "apply portage's own suggested changes / undo that apply"),
    ("row N", "mesh: edit desktop row N"),
    ("Enter", "keep these and continue"),
)


def _password_from(token: str) -> str:
    path = os.path.expanduser(token[5:])
    with open(path, encoding="utf-8") as fh:
        return fh.readline().rstrip("\r\n")


class DesktopScreen:
    slug = "desktop"
    title = "Desktop"

    def __init__(self):
        self.row = 0
        self.last_result: dp.PretendResult | None = None
        self.last_applied: list[ds.OverlayChange] = []

    # ── which config ─────────────────────────────────────────────────────────
    def _entries(self, j) -> list:
        return ds.desktop_entries(getattr(j, "worklist", None), "mesh") \
            if j.cfg.mode == "mesh" else []

    def _entry(self, j):
        entries = self._entries(j)
        if not entries:
            return None
        self.row = min(self.row, len(entries) - 1)
        return entries[self.row]

    def view(self, j):
        e = self._entry(j)
        return ds.entry_view(j.cfg, e) if e is not None else j.cfg

    def _store(self, j, spec: ds.DesktopSpec) -> None:
        e = self._entry(j)
        if e is not None:
            e.desktop_spec = spec.to_dict()
        else:
            ds.store(j.cfg, spec)

    def _pretend_cfg(self, j):
        e = self._entry(j)
        if e is not None:
            return j.worklist._materialize_one(e)
        return j.cfg

    # ── rendering ────────────────────────────────────────────────────────────
    def enter(self, j) -> None:  # noqa: ARG002
        return None

    def lines(self, j) -> list[str]:
        c = self.view(j)
        spec = ds.spec_of(c)
        out = ["Environment, login, window managers, video drivers, extra accounts, apps "
               "(native or Flatpak) and Python for this build.", ""]
        entries = self._entries(j)
        if entries:
            out.append("Desktop rows: " + "  ".join(
                f"[{i + 1}{'*' if i == self.row else ''}] {e.role} on {e.platform}"
                for i, e in enumerate(entries)))
        out += [f"  {x}" for x in ds.summary_lines(c)]
        out.append("  " + ds.LOGIN_MANAGER_NOTE)
        if ds.is_x86(c):
            out.append("  Environments here: " + ", ".join(ds.environment_choices(c))
                       + (f" ({ds.environment_lock(c)})" if ds.environment_lock(c) else ""))
            out.append("  Sessions: " + ", ".join(
                f"{s.name}{' (on)' if s.name in spec.sessions or s.name in ds.ALWAYS_ON_SESSIONS else ''}"
                for s in ds.SESSION_CATALOG))
        out.append("  Apps: " + ", ".join(
            f"{a['id']}({'/'.join(x for x, k in (('native', 'atom'), ('flatpak', 'flatpak')) if a.get(k))})"
            for a in ds.app_catalog()))
        if spec.use_lines or spec.keyword_lines:
            out.append("  package.use: " + ("; ".join(spec.use_lines) or "-"))
            out.append("  accept_keywords: " + ("; ".join(spec.keyword_lines) or "-"))
        probs = ds.problems(c, passwords=ds.parse_passwords(j.cfg.extra_local_passes))
        if probs:
            out.append("")
            out += [("Fix: " if p.level == "error" else "Note: ") + p.text for p in probs]
        res = self.last_result
        if res is not None:
            out += ["", f"emerge --pretend: {res.status}"
                    + (f" — {res.reason}" if res.status == "error" and res.reason else ""),
                    *[f"  needs: {k} {line}" for k, line in res.needs]]
            if res.applicable_needs():
                out.append("  'a' applies portage's own suggestion:")
                out += ["    " + x for x in ds.overlay_diff(spec, res.applicable_needs())]
            out.append("  " + dp.HONESTY_NOTE)
            if res.log_path:
                out.append(f"  log: {res.log_path}")
        else:
            why = dp.supported(self._pretend_cfg(j))
            if why:
                out += ["", why]
        out += ["", "commands:"]
        out += [f"  {cmd:<36} {what}" for cmd, what in COMMANDS]
        return out

    def prompt(self, j) -> str:  # noqa: ARG002
        return "desktop> "

    # ── input ────────────────────────────────────────────────────────────────
    def feed(self, j, line: str) -> None:
        if not line.strip():
            c = self.view(j)
            errs = ds.errors(c, passwords=ds.parse_passwords(j.cfg.extra_local_passes))
            if errs:
                j.status = "Fix first: " + errs[0]
                return
            j.advance()
            return
        try:
            tok = shlex.split(line)
        except ValueError as e:
            j.status = f"unreadable command: {e}"
            return
        try:
            j.status = self._command(j, tok[0].lower(), tok[1:]) or ""
        except (OSError, ValueError, IndexError) as e:
            j.status = f"not done: {e}"

    def _command(self, j, cmd: str, args: list[str]) -> str:
        c = self.view(j)
        spec = ds.spec_of(c)
        if cmd == "row":
            n = int(args[0]) - 1
            if not 0 <= n < len(self._entries(j)):
                return "no such row"
            self.row, self.last_result = n, None
            return ""
        if cmd == "env":
            if j.cfg.mode == "mesh":
                return "in a mesh build each row's weight is set on the Worklist step"
            ds.set_environment(j.cfg, args[0])
            return f"environment: {args[0]}"
        if cmd == "steam":
            if not ds.is_x86(c) or j.cfg.mode == "mesh":
                return "Steam delivery is an x86 single-image choice"
            if args[0] not in ("default", "native", "flatpak", "none"):
                return "steam default|native|flatpak|none"
            j.cfg.steam = "" if args[0] == "default" else args[0]
            return f"Steam: {args[0]}"
        if cmd == "s":
            for t in args:
                name = t.lstrip("+-")
                if name not in ds.SESSIONS:
                    return f"unknown session {name!r}"
                if t.startswith("-"):
                    spec.sessions = [x for x in spec.sessions if x != name]
                elif name not in spec.sessions and name not in ds.ALWAYS_ON_SESSIONS:
                    spec.sessions.append(name)
        elif cmd == "default":
            spec.default_session = "" if args[0] == "-" else args[0]
        elif cmd == "cards":
            spec.video_cards = [] if args == ["-"] else list(args)
        elif cmd == "user":
            sub = args[0]
            if sub == "add":
                name = args[1]
                admin = "admin" in args[2:]
                pw_tok = [a for a in args[2:] if a.startswith("pass=")]
                if not pw_tok:
                    return "user add NAME [admin] pass=FILE (the password is read from FILE)"
                spec.extra_users = [u for u in spec.extra_users if u.name != name]
                spec.extra_users.append(ds.ExtraUser(name, admin))
                typed = ds.parse_passwords(j.cfg.extra_local_passes)
                typed[name] = _password_from(pw_tok[0])
                j.cfg.extra_local_passes = ds.extra_pass_file_text(
                    ds.DesktopSpec(extra_users=[ds.ExtraUser(n) for n in typed]), typed)
            elif sub == "rm":
                spec.extra_users = [u for u in spec.extra_users if u.name != args[1]]
            else:
                return "user add|rm"
        elif cmd == "app":
            if args[0] == "add":
                text = args[1]
                if ":" in text:
                    remote, _, flat = text.partition(":")
                    spec.apps.append(ds.DesktopApp(id=flat, label=flat, delivery="flatpak",
                                                   flatpak=flat, remote=remote))
                else:
                    spec.apps.append(ds.DesktopApp(id=text, label=text, delivery="native", atom=text))
            else:
                app_id, how = args[0], args[1]
                spec.apps = [a for a in spec.apps if a.id != app_id]
                if how != "off":
                    app = ds.catalog_app(app_id, how)
                    if app is None:
                        return f"{app_id} is not offered as {how}"
                    spec.apps.append(app)
        elif cmd == "remote":
            if args[0] == "rm":
                spec.flatpak_remotes.pop(args[1], None)
            else:
                name, _, url = args[0].partition("=")
                spec.flatpak_remotes[name] = url
        elif cmd == "py":
            if args and args[0] == "single":
                spec.python_single_target = "" if args[1] == "-" else args[1]
            else:
                for t in args:
                    name = t.lstrip("+-")
                    if t.startswith("-"):
                        spec.python_extra_targets = [x for x in spec.python_extra_targets if x != name]
                    elif name not in spec.python_extra_targets:
                        spec.python_extra_targets.append(name)
        elif cmd in ("use", "kw"):
            kind = "package.use" if cmd == "use" else "accept_keywords"
            target = spec.use_lines if cmd == "use" else spec.keyword_lines
            if args and args[0] == "rm":
                line = ds.normalise_line(" ".join(args[1:]))
                if line in target:
                    target.remove(line)
                    spec.history.append({"op": "remove", "kind": kind, "line": line,
                                         "source": "operator", "at": ds._now()})
            else:
                line = ds.normalise_line(" ".join(args))
                why = ds.check_change(ds.OverlayChange(kind, line), c)
                if why:
                    return why
                if line not in target:
                    target.append(line)
                    spec.history.append({"op": "add", "kind": kind, "line": line,
                                         "source": "operator", "at": ds._now()})
        elif cmd == "p":
            return self.run_pretend(j)
        elif cmd == "a":
            res = self.last_result
            if res is None or not res.applicable_needs():
                return "nothing to apply: run p first"
            probe = self.view(j)
            self.last_applied = ds.apply_changes(probe, res.applicable_needs(),
                                                 source="autounmask", pretend_run=res.run_id)
            self._store(j, ds.spec_of(probe))
            return f"applied {len(self.last_applied)} line(s); p checks again"
        elif cmd == "u":
            probe = self.view(j)
            ds.undo_changes(probe, self.last_applied, source="autounmask")
            self._store(j, ds.spec_of(probe))
            self.last_applied = []
            return "undone"
        else:
            return f"unrecognised command: {cmd!r} (Enter continues, q quits)"
        bad = ds.grammar_errors(c, spec)
        if bad:
            return f"not changed: {bad[0]}"
        self._store(j, spec)
        return ""

    def run_pretend(self, j, *, driver=None, out_dir: str = "") -> str:
        cfg = self._pretend_cfg(j)
        why = dp.supported(cfg)
        out_dir = out_dir or (j.cfg.output_dir or os.path.join(j.generator_dir, "out"))
        if not why:
            why = dp.gate(out_dir)
        if why:
            return why
        if driver is None:
            from ..core.build_driver import BuildDriver
            driver = BuildDriver(j.generator_dir, workdir=out_dir)
        res = dp.run(cfg, driver, out_dir=out_dir)
        self.last_result = res
        probe = self.view(j)
        dp.record(probe, res)
        self._store(j, ds.spec_of(probe))
        return f"emerge --pretend: {res.status}"
