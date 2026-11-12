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
  "(no artifacts)", never a fabricated list.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

from ..core import build_sessions

__all__ = [
    "SessionRow", "display_status", "session_rows", "artifact_entries",
    "image_lines", "session_detail_lines", "delete_refusal", "worklist_table",
    "format_table", "session_line",
]

#: Render string for a running record whose recorded pid is gone on this host —
#: the same phrase the GUI sessions list uses (crash honesty, never written back).
STALE_STATUS = "running (process gone — likely interrupted)"


@dataclass(frozen=True)
class SessionRow:
    """One list row: the record plus its crash-honest DISPLAY status."""
    session: build_sessions.BuildSession
    status: str


def display_status(s: build_sessions.BuildSession) -> str:
    """The status string a UI should render: ``is_stale`` is a render hint, so a
    stale "running" record reads as interrupted without ever mutating the record."""
    return STALE_STATUS if build_sessions.is_stale(s) else s.status


def session_rows() -> tuple[list[SessionRow], list[str]]:
    """All readable session records newest-first as display rows, plus the paths of
    unreadable/corrupt record files (surfaced, never rewritten — ``scan``'s rule)."""
    sessions, unreadable = build_sessions.scan()
    return [SessionRow(s, display_status(s)) for s in sessions], unreadable


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
