"""The TUI face of the per-domain code copies (operator ask 2026-10-21) — the text twin
of the GUI Code folders block's "Copies for this domain" part, over the SAME Qt-free
core (:mod:`core.domain_workspaces`), so both faces plan, name, copy and remove exactly
the same folders.

Reached from the Local Docker mesh review screen with ``f``. Commands:

* ``m N`` / ``m all`` — make the missing copies of domain N (every domain);
* ``r N`` — ARM the removal of domain N's extra copies: lists what would go and what
  is kept and why, and removes nothing;
* ``yes`` — the second, explicit step: removes the armed folders that are still extra
  (each re-checked by the core); any other command disarms;
* ``src PATH`` / ``src clone`` — which build tree the copies are made from: the
  operator's own tree, or ``.stack-src`` (the default; the TUI has no Repo source step
  yet, issue #519);
* ``b`` — back to the review.

No dialog, no hidden deletion: the same two-step rule as the window.
"""
from __future__ import annotations

import os
from typing import Callable, Optional

from ..core import domain_workspaces as dw

__all__ = ["CodeFoldersScreen"]


class CodeFoldersScreen:
    """``rows_of(j)`` gives the domain rows and ``mesh_of(j)`` the mesh's name;
    ``on_back(j)`` leaves. ``runner`` is the git runner (None = the real git)."""

    def __init__(self, rows_of: Callable, mesh_of: Callable, on_back: Callable,
                 runner=None, state_root: Optional[str] = None):
        self.rows_of = rows_of
        self.mesh_of = mesh_of
        self.on_back = on_back
        self.runner = runner
        self.state_root = state_root
        self.source_mode = "clone"
        self.source_dir = ""
        #: (domain name, armed paths) — set by ``r N``, consumed by ``yes``
        self.armed: "tuple[str, tuple[str, ...]] | None" = None
        self.last: list[str] = []

    def plan(self, j) -> dw.WorkspacePlan:
        return dw.plan_workspaces(getattr(j, "generator_dir", "") or ".",
                                  self.source_mode, self.source_dir,
                                  list(self.rows_of(j)), self.mesh_of(j) or "mesh",
                                  state_root=self.state_root)

    # ── screen protocol ─────────────────────────────────────────────────────────
    def lines(self, j) -> list[str]:
        plan = self.plan(j)
        where = ("your own tree " + self.source_dir if self.source_mode == "existing"
                 else ".stack-src (make stack-clone)")
        out = ["Code copies for each domain — one folder per domain, one git copy per "
               "app that domain has, each named <app>.<domain>.",
               f"Copies folder: {plan.root}",
               f"Copied from: {where}",
               dw.EDITS_NOTE, ""]
        if plan.root_problem:
            out += [f"No copy can be made: {plan.root_problem}", ""]
        for i, ws in enumerate(plan.domains, 1):
            if not ws.in_mesh:
                out.append(f"  {i}. {ws.name} — no longer a domain of this mesh "
                           f"({ws.folder})")
            else:
                made, missing = len(ws.cloned()), len(ws.missing())
                out.append(f"  {i}. {ws.name} — {made} of {len(ws.repos)} copies made"
                           + (f", {missing} to make" if missing else "")
                           + (f" — {ws.problem}" if ws.problem else ""))
                blocked = [r for r in ws.repos if not r.cloned and r.reason]
                if blocked and not ws.problem:
                    out.append(f"       {len(blocked)} cannot be made yet: "
                               f"{blocked[0].reason}")
            for x in ws.extras:
                out.append(f"       EXTRA {os.path.basename(x.path)}: {x.why}")
            for p in ws.foreign:
                out.append(f"       not made by the Studio, left alone: "
                           f"{os.path.basename(p)}")
        if self.armed:
            out += ["", f"ARMED: removing {len(self.armed[1])} folder(s) of "
                    f"{self.armed[0]}. Type ‘yes’ to remove them; anything else keeps "
                    "them."]
        if self.last:
            out += [""] + self.last
        out += ["", "commands: m N / m all=make the missing copies · r N=list a domain's "
                "extra copies for removal · yes=remove what r listed · src PATH / src "
                "clone=copy from your own tree / .stack-src · b=back"]
        return out

    def prompt(self, j) -> str:  # noqa: ARG002
        return "code-folders> "

    def feed(self, j, line: str) -> None:
        line = line.strip()
        armed, self.armed = self.armed, None          # any command disarms…
        if line == "yes":
            self._remove(j, armed)                    # …except the one that confirms
            return
        if line.lower() == "b":
            self.last = []
            self.on_back(j)
            return
        parts = line.split(None, 1)
        if not parts:
            return
        cmd, arg = parts[0].lower(), (parts[1].strip() if len(parts) > 1 else "")
        plan = self.plan(j)
        if cmd == "src":
            if arg == "clone":
                self.source_mode, self.source_dir = "clone", ""
            elif arg:
                self.source_mode, self.source_dir = "existing", arg
            self.last = []
            return
        if cmd == "m":
            targets = ([d for d in plan.domains if d.in_mesh] if arg == "all"
                       else [d for d in [self._pick(plan, arg)] if d and d.in_mesh])
            if not targets:
                j.status = f"no such domain: {arg!r}"
                return
            self.last = []
            for ws in targets:
                res = dw.clone_missing(plan, ws.name, self.runner)
                bad = [r for r in res if not r.ok]
                self.last.append(f"{ws.name}: made {len(res) - len(bad)} of {len(res)} "
                                 "copies" + (f"; {bad[0].app}: {bad[0].message}"
                                             if bad else ""))
            return
        if cmd == "r":
            ws = self._pick(plan, arg)
            if ws is None or not ws.extras:
                j.status = f"no extra copies for {arg!r}"
                return
            ok, self.last = [], [f"Extra copies of {ws.name} (nothing removed yet):"]
            for x in ws.extras:
                st = dw.extra_status(x.path, self.runner)
                self.last.append(f"  {os.path.basename(x.path)}: {st.words()}")
                if st.safe_to_remove:
                    ok.append(x.path)
            if ok:
                self.armed = (ws.name, tuple(ok))
            else:
                self.last.append("Every one holds work of its own, so none will be "
                                 "removed.")
            return
        j.status = f"unrecognised command: {line!r}"

    @staticmethod
    def _pick(plan: dw.WorkspacePlan, arg: str) -> "dw.DomainWorkspace | None":
        if arg.isdigit() and 1 <= int(arg) <= len(plan.domains):
            return plan.domains[int(arg) - 1]
        return next((d for d in plan.domains if d.name == arg), None)

    def _remove(self, j, armed) -> None:
        if not armed:
            j.status = "nothing is armed: type r N first"
            return
        name, paths = armed
        fresh = self.plan(j)
        self.last = []
        still = {x.path: x for x in fresh.extras()}
        for path in paths:
            x = still.get(path)
            if x is None:
                self.last.append(f"{os.path.basename(path)}: no longer extra; kept")
                continue
            res = dw.remove_extra(x, fresh, self.runner)
            self.last.append(f"{os.path.basename(path)}: "
                             + ("removed" if res.removed else res.message))
        j.status = f"{name}: done"
