"""Row models for the TUI — pure functions over core.build_sessions (no urwid, no Qt).

Both faces (the urwid UI and the plain-prompt fallback) render EXACTLY these rows and
strings, so the degradation path shows the same truth as the rich one and the headless
tests exercise the real logic with urwid absent.

Honesty rules inherited from the GUI lane (gui/pages/build_window.actions_for):

* a "running" record whose pid is gone renders as *running (process gone — likely
  interrupted)* — a RENDER hint only, the record is never mutated (``is_stale``);
* an ACTIVE session (genuinely running right now) is never deletable — the refusal
  carries its reason instead of failing silently;
* artifact listings come from the real workdir; a missing/empty dir is an honest
  "(no artifacts)", never a fabricated list;
* an UNREADABLE record is a row like any other (the GUI lists it, B-11): numbered after
  the sessions, and delete — a plain unlink, checked afterwards — is the one action it
  takes; every other verb says why not instead of doing nothing;
* RESTART is gated exactly as the GUI's ``PreviousBuildsWidget.can_restart`` (an active
  build, a deleted workdir, the per-domain services gate) and then HANDED OVER: the TUI
  runs no builds, so it says what the restart would do and where to start it, never
  pretends to have dispatched one. REDO loads the recorded configuration into the
  journey — the twin of ``StudioWizard.load_session``.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

from ..core import build_sessions

__all__ = [
    "SessionRow", "UnreadableRow", "display_status", "session_rows", "list_entries",
    "artifact_entries", "image_lines", "session_detail_lines", "delete_refusal",
    "worklist_table", "format_table", "session_line", "unreadable_line",
    "unreadable_detail_lines", "unreadable_refusal", "delete_unreadable",
    "restart_refusal", "restart_handover_lines", "redo_refusal", "DELETE_ALL_QUESTION",
    "delete_all_result",
]

#: Render string for a running record whose recorded pid is gone on this host —
#: the same phrase the GUI sessions list uses (crash honesty, never written back).
STALE_STATUS = "running (process gone — likely interrupted)"


@dataclass(frozen=True)
class SessionRow:
    """One list row: the record plus its crash-honest DISPLAY status."""
    session: build_sessions.BuildSession
    status: str


@dataclass(frozen=True)
class UnreadableRow:
    """A record file ``scan`` could not parse: listed, never rewritten, and deletable."""
    path: str


#: Why an unreadable record takes no verb but delete — the GUI's per-build window says
#: "This record could not be parsed, so it points at no build directory."
UNREADABLE_WHY = ("could not be parsed, so it names no build and points at no build "
                  "directory — only delete (removing the file) applies")


def display_status(s: build_sessions.BuildSession) -> str:
    """The status string a UI should render: ``is_stale`` is a render hint, so a
    stale "running" record reads as interrupted without ever mutating the record."""
    return STALE_STATUS if build_sessions.is_stale(s) else s.status


def session_rows() -> tuple[list[SessionRow], list[str]]:
    """All readable session records newest-first as display rows, plus the paths of
    unreadable/corrupt record files (surfaced, never rewritten — ``scan``'s rule)."""
    sessions, unreadable = build_sessions.scan()
    return [SessionRow(s, display_status(s)) for s in sessions], unreadable


def list_entries(rows: list[SessionRow],
                 unreadable: list[str]) -> list["SessionRow | UnreadableRow"]:
    """The review's ONE numbering: the sessions newest-first, then every unreadable
    record — so ``d NUMBER`` reaches a corrupt record the same way it reaches a build."""
    return [*rows, *(UnreadableRow(p) for p in unreadable)]


def unreadable_line(row: UnreadableRow, index: int) -> str:
    """``  4. ! unreadable record zz.json — only delete applies`` (the file's name; its
    detail screen and the delete question show the whole path)."""
    return (f"{index:3d}. ! unreadable record {os.path.basename(row.path)} — only "
            "delete applies")


def unreadable_detail_lines(row: UnreadableRow) -> list[str]:
    return [f"record    {row.path}", "status    unreadable record", "",
            f"This record file {UNREADABLE_WHY}."]


def unreadable_refusal(verb: str) -> str:
    """What every verb but delete says on an unreadable row."""
    return f"no {verb} for an unreadable record: it {UNREADABLE_WHY}"


def delete_unreadable(row: UnreadableRow) -> tuple[bool, str]:
    """Unlink the record file and report what is TRUE afterwards: ``delete_path``
    swallows every error, so the file is looked for again rather than assumed gone."""
    build_sessions.delete_path(row.path)
    if os.path.lexists(row.path):
        return False, (f"not deleted: {row.path} is still there (it could not be "
                       "removed — check its folder's permissions)")
    return True, f"deleted the unreadable record {row.path}."


def session_line(row: SessionRow, index: int) -> str:
    """One list line: ``  3. 20260807-071119-5c1ccb  mesh · 2 images (x86, rpi5) — failed``."""
    s = row.session
    label = s.label or "(no label)"
    return f"{index:3d}. {s.id}  {label} — {row.status}"


def artifact_entries(s: build_sessions.BuildSession) -> list[str]:
    """Sorted top-level listing of the session's artifact dir (directories get a
    trailing ``/``). ``[]`` when the dir is missing, empty or unreadable — the honest
    "no artifacts", mirroring the GUI's ``_has_artifacts`` refusal."""
    try:
        names = sorted(os.listdir(s.workdir))
    except OSError:
        return []
    out: list[str] = []
    for name in names:
        path = os.path.join(s.workdir, name)
        out.append(name + "/" if os.path.isdir(path) else name)
    return out


def image_lines(s: build_sessions.BuildSession) -> list[str]:
    """One line per per-image outcome row: ``pki.x86: pki · x86 — ok (exit 0)``."""
    lines: list[str] = []
    for img in s.images:
        head = f"{img.get('id', '?')}: {img.get('role', '?')} · {img.get('platform', '?')}"
        status = str(img.get("status", "unknown"))
        code = img.get("exit_code")
        if code is not None:
            status += f" (exit {code})"
        lines.append(f"{head} — {status}")
    return lines


def session_detail_lines(row: SessionRow) -> list[str]:
    """The detail screen, as plain lines both faces render verbatim."""
    s = row.session
    lines = [
        f"session   {s.id}",
        f"label     {s.label or '(no label)'}",
        f"kind      {s.kind}",
        f"status    {row.status}",
        f"created   {s.created or '-'}",
        f"started   {s.started or '-'}",
        f"finished  {s.finished or '-'}",
        f"workdir   {s.workdir or '-'}",
        f"log       {s.log_path or '-'}",
    ]
    if s.restarts:
        lines.append(f"restarts  {s.restarts}")
    lines.append("")
    lines.append("images:")
    imgs = image_lines(s)
    lines += [f"  {ln}" for ln in imgs] or ["  (none recorded)"]
    lines.append("")
    lines.append("artifacts:")
    arts = artifact_entries(s)
    lines += [f"  {name}" for name in arts] or ["  (no artifacts)"]
    return lines


def delete_refusal(s: build_sessions.BuildSession) -> str | None:
    """``None`` when the session is deletable; otherwise the human reason — derived
    from the record's REAL state (the ask-15 honesty rule), matching the guard
    ``build_sessions.delete`` enforces so the UI never offers a dead action."""
    if build_sessions.is_active(s):
        return ("this build is running right now — stop it in the Studio that owns "
                "it first (an active session's record and artifacts are never "
                "removed out from under it)")
    return None


# ── restart / redo / delete all (the GUI's Previous builds buttons) ───────────────────
#: The GUI's "Delete all finished…" question, word for word.
DELETE_ALL_QUESTION = ("Delete every finished build-session record? "
                       "Sessions still running are kept.")


def delete_all_result(deleted: int, skipped: int) -> str:
    """What ``build_sessions.prune`` did — the GUI's sentence."""
    return f"Deleted {deleted}; skipped {skipped} still running."


def _services_refusal(s: build_sessions.BuildSession) -> str:
    """The per-domain services arm of the restart gate (#495) — the same reading as
    the GUI's ``sessions_widget._session_services_refusal``: the RECORD's own config
    is what a restart re-dispatches, and a record that does not parse is let through
    (the dispatch preflight refuses an unusable one)."""
    cfg_dict = getattr(s, "config", None)
    if not isinstance(cfg_dict, dict):
        return ""
    try:
        from ..core import worklist as worklist_mod
        from ..core.domain_services import restart_gate_reason
        base = worklist_mod.WorklistConfig.from_dict(cfg_dict).base
    except Exception:                          # noqa: BLE001 — the GUI's own rule
        return ""
    return restart_gate_reason(base)


def restart_refusal(s: build_sessions.BuildSession) -> str | None:
    """``None`` when the session may be restarted; otherwise the GUI's reason, arm for
    arm (``PreviousBuildsWidget.can_restart`` — test_tui_gui_parity pins the match).
    A reason that names Redo is the one the GUI answers by offering the Redo."""
    if build_sessions.is_active(s):
        return ("This session appears to be running in another Studio "
                "process — stop it there first.")
    if not os.path.isdir(s.workdir):
        return ("Its artifact directory no longer exists:\n"
                f"{s.workdir}\nUse Redo to build it as a new session.")
    return _services_refusal(s) or None


def restart_handover_lines(s: build_sessions.BuildSession) -> list[str]:
    """What a restart of ``s`` would do, and where it runs. The TUI runs no builds (its
    Build screen says so too), so after the gate passes this is the honest end of the
    verb: what the GUI's Restart does with THIS record — its own confirmation text for
    a wizard build, the fleet window for a fleet run — then the route to the button."""
    if s.kind == "fleet":
        # The GUI asks no "Rebuild into …?" question about a fleet run and warns about
        # no secrets (a fleet configuration holds none): its Restart returns into the
        # fleet window before either (PreviousBuildsWidget._restart), and that window's
        # Review step is the confirmation. Saying the wizard's sentence here described
        # a dialog the GUI never shows for this record.
        return [f"Restart session {s.id} is a fleet run: the GUI reopens its fleet "
                "window on the Review step with this run's configuration, pinned to "
                f"this record and its build directory {s.workdir}",
                "  nothing is rebuilt before that step: ‘Build fleet now’ there is the "
                "confirmation, and the prior outcome is kept in the record's history.",
                "The TUI does not run builds. Restart it from the GUI: python -m "
                "hugmesh_studio → Review prior sessions → select this build → Restart "
                "(its fleet window opens on the Review step, pinned to this record)."]
    from ..core import secret_files
    out = [f"Restart session {s.id} rebuilds into {s.workdir}",
           "  existing artifacts will be reused/overwritten."]
    if s.blanked_secrets:
        out.append("  NOTE: these secrets were NOT saved with the session and will be "
                   "empty: " + ", ".join(s.blanked_secrets))
    need = secret_files.missing_for_restart(getattr(s, "held_secret_files", []))
    if need:
        labels = secret_files.FIELD_LABELS
        out.append("  These secret files were held in memory only (never saved) — the "
                   "restart asks for them again before the build starts: " + ", ".join(
                       f"{r.get('name', '?')} "
                       f"({labels.get(r.get('field', ''), r.get('field', ''))})"
                       for r in need))
    out += ["The TUI does not run builds. Restart it from the GUI: python -m "
            "hugmesh_studio → Review prior sessions → select this build → Restart "
            "(the build starts on the Build progress page)."]
    return out


def redo_refusal(s: build_sessions.BuildSession) -> str | None:
    """``None`` when REDO can load ``s``'s recorded configuration into the journey;
    otherwise why not. A fleet run is not a wizard configuration (the GUI's Redo opens
    the fleet window for it), and a snapshot that no longer parses loads nothing."""
    if s.kind == "fleet":
        return ("a fleet run is redone in the GUI's fleet window (python -m "
                "hugmesh_studio → Review prior sessions → Redo); the TUI's fleet flow "
                "(--fleet) does not load a recorded run")
    if not isinstance(s.config, dict) or not s.config:
        return "its record carries no configuration snapshot to load"
    try:
        from ..core import worklist as worklist_mod
        worklist_mod.WorklistConfig.from_dict(s.config)
    except Exception as exc:                   # noqa: BLE001 — said, never raised
        return f"its recorded configuration no longer loads: {exc}"
    return None


# ── worklist table (read-only) ─────────────────────────────────────────────────────
def worklist_table(s: build_sessions.BuildSession) -> tuple[list[str], list[list[str]]]:
    """A read-only mesh-worklist table for one session: headers + rows.

    Rows come from the session's per-image outcome records (the truth of what this
    run dispatched); the board/flavor axis is joined in from the config snapshot's
    worklist entries when one exists (a fleet session has no worklist — its single
    aggregate row still renders honestly)."""
    headers = ["#", "id", "role", "platform", "board/flavor", "status"]
    axis: dict[str, str] = {}
    if s.kind == "wizard" and s.config:
        try:
            for e in s.worklist().entries:
                axis[e.id] = e.board or e.flavor or ""
        except (ValueError, TypeError, KeyError):
            pass                      # a snapshot that no longer parses loses only the axis column
    rows: list[list[str]] = []
    for i, img in enumerate(s.images, 1):
        img_id = str(img.get("id", ""))
        status = str(img.get("status", "unknown"))
        code = img.get("exit_code")
        if code is not None:
            status += f" (exit {code})"
        rows.append([str(i), img_id, str(img.get("role", "")),
                     str(img.get("platform", "")), axis.get(img_id, ""), status])
    return headers, rows


def format_table(headers: list[str], rows: list[list[str]]) -> list[str]:
    """Dumb fixed-width table lines (header, rule, rows) shared by both faces."""
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))
    def fmt(cells: list[str]) -> str:
        return "  ".join(c.ljust(w) for c, w in zip(cells, widths)).rstrip()
    lines = [fmt(headers), "  ".join("-" * w for w in widths)]
    lines += [fmt(r) for r in rows]
    return lines
