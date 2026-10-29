"""Small code edits in a domain's code folder, proposed as a diff, applied on a press,
revertible (Qt-free, stdlib only).

WHERE. Only the per-domain workspace folders the Studio made
(core/domain_workspaces.plan_workspaces: ``<state>/domain-code/<mesh>/<app>-<domain>/``)
whose ``hugmesh-workspace.json`` marker reads back. Never the build source root
(``.stack-src`` is git-reset by ``make stack-clone``), never a foreign folder, never a
path that resolves outside the workspace or passes through a symlink, never a file the
deny-list names (core/assistant_context.is_denied_path) or a secret-shaped file name.

HOW SMALL. :data:`SCOPE`: text files with a known extension, at most 3 files, 120
changed lines, 64 KiB per file. Anything bigger — more files, "refactor", "add a
feature" — is refused with the hand-off to the coding-agent launcher, which gets the
request as its first task.

WHAT THE MODEL EMITS. One sentence and one fenced ```diff block, unified, paths
relative to the workspace root (``a/<path>``, ``b/<path>``), made from a prompt that
holds the exact current text of the files the person named (:func:`files_mentioned`).
:func:`parse_diff` is a small unified-diff parser: every context and minus line must
match the current file exactly or the hunk is refused with the first mismatching line.

APPLY AND REVERT. :func:`apply` writes byte copies of each file to
``<state>/assistant-edits/<id>/before/<path>`` plus a ``manifest.json`` (workspace,
mesh, domain, files, sha256 before and after, time), then writes the files.
:func:`revert` restores the saved bytes after checking the current sha256 still equals
``after``; a mismatch refuses and names the before-copy. Never ``git checkout``: the
workspace may hold the person's own edits. The last 20 edit ids are kept.

LOCAL ONLY. No git add/commit/push, no build, no run; the footer says so.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import time
from dataclasses import dataclass, field
from typing import Iterable, Optional

from . import domain_workspaces as dw
from .assistant_context import is_denied_path, redact

__all__ = [
    "SCOPE", "Workspace", "FileEdit", "DiffProblem", "Applied", "find_workspaces",
    "files_mentioned", "file_text", "safe_path", "parse_diff", "preview", "apply", "revert",
    "handoff_text", "edits_dir", "list_applied", "load_applied", "FILES_BLOCK_MAX_LINES",
    "SECRET_FILE_RE", "too_big_reason", "KEEP_EDITS",
]

SCOPE = {
    "extensions": (".md", ".txt", ".json", ".yaml", ".yml", ".toml", ".ini", ".conf",
                   ".env.example", ".css", ".scss", ".html", ".ts", ".js", ".tsx", ".jsx",
                   ".py", ".java", ".properties", ".xml", ".sh"),
    "max_files": 3, "max_changed_lines": 120, "max_file_bytes": 64 * 1024,
}
FILES_BLOCK_MAX_LINES = 200
KEEP_EDITS = 20
SECRET_FILE_RE = re.compile(r"^(\.env(\..*)?|.*\.pem|.*\.key|id_.*|.*\.kubeconfig|secrets\..*|credentials.*|token.*)$", re.I)
_BIG_WORDS = ("refactor", "add a feature", "new feature", "rewrite", "migrate", "whole app",
              "every file", "all files")


@dataclass(frozen=True)
class Workspace:
    mesh: str
    domain: str
    app: str
    path: str                    # the folder (realpath)

    @property
    def name(self) -> str:
        return os.path.basename(self.path.rstrip(os.sep))


@dataclass(frozen=True)
class Hunk:
    old_start: int
    old_lines: "tuple[str, ...]"      # the lines the file must hold (context + minus)
    new_lines: "tuple[str, ...]"      # what replaces them (context + plus)
    added: int
    removed: int


@dataclass(frozen=True)
class FileEdit:
    path: str                         # relative, forward slashes
    hunks: "tuple[Hunk, ...]"
    changed: int

    def new_text(self, old: str) -> str:
        lines = old.split("\n")
        out: list = []
        pos = 0
        for h in self.hunks:
            start = h.old_start - 1
            out += lines[pos:start]
            out += list(h.new_lines)
            pos = start + len(h.old_lines)
        out += lines[pos:]
        return "\n".join(out)


@dataclass(frozen=True)
class DiffProblem:
    text: str


@dataclass
class Applied:
    id: str
    workspace: str
    mesh: str
    domain: str
    files: "list[dict]"            # {path, before, after} (sha256)
    before_dir: str
    time: float = field(default_factory=time.time)

    @property
    def footer(self) -> str:
        return (f"Applied to {self.workspace}. Not committed. Revert: press Revert or copy "
                f"from {self.before_dir}.")


# ── where ────────────────────────────────────────────────────────────────────────────
def _real(path: str) -> str:
    return os.path.realpath(os.path.expanduser(path))


def find_workspaces(generator_dir: str, source_mode: str, source_dir: str, domains, mesh: str,
                    *, state_root: Optional[str] = None, environ=None,
                    only_domain: str = "") -> "list[Workspace]":
    """The existing, marker-bearing per-domain folders (optionally one domain's)."""
    out: list = []
    try:
        plan = dw.plan_workspaces(generator_dir, source_mode, source_dir, list(domains or ()), mesh,
                                  state_root=state_root, environ=environ, claims={})
    except Exception:                        # noqa: BLE001 — none, not a crash
        return out
    for dom in plan.domains:
        if only_domain and dom.name != only_domain:
            continue
        for repo in dom.repos:
            dest = repo.dest
            if not dest or not os.path.isdir(dest) or dw.read_marker(dest) is None:
                continue
            out.append(Workspace(mesh, dom.name, repo.app, _real(dest)))
    return out


def safe_path(ws: Workspace, rel: str) -> "tuple[str, str]":
    """``(absolute path, problem)`` for ``rel`` inside ``ws``: no symlink on any
    component, inside the folder after realpath, allowed extension, not a secret name,
    not denied."""
    rel = (rel or "").replace("\\", "/").strip()
    if not rel or rel.startswith("/") or ".." in rel.split("/"):
        return "", f"{rel or '(empty)'} is not a path inside the folder"
    root = ws.path
    cur = root
    for part in rel.split("/"):
        cur = os.path.join(cur, part)
        if os.path.islink(cur):
            return "", f"{rel} goes through a link; I do not follow links"
    full = os.path.realpath(cur)
    if not (full == root or full.startswith(root.rstrip(os.sep) + os.sep)):
        return "", f"{rel} resolves outside the folder"
    base = os.path.basename(rel)
    if SECRET_FILE_RE.match(base) or is_denied_path(full):
        return "", f"{base} holds secrets; I do not read it"
    if not any(rel.lower().endswith(ext) for ext in SCOPE["extensions"]):
        return "", f"{rel} is not a text file I edit ({', '.join(SCOPE['extensions'][:8])}, ...)"
    return full, ""


def file_text(ws: Workspace, rel: str, *, max_lines: int = FILES_BLOCK_MAX_LINES) -> "tuple[str, str]":
    """``(text, problem)``: the current file, redacted, capped at ``max_lines``."""
    full, why = safe_path(ws, rel)
    if why:
        return "", why
    try:
        size = os.path.getsize(full)
        if size > SCOPE["max_file_bytes"]:
            return "", f"{rel} is {size // 1024} KiB; I edit files up to {SCOPE['max_file_bytes'] // 1024} KiB"
        with open(full, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        return "", f"cannot read {rel}: {exc.__class__.__name__}"
    if b"\0" in data:
        return "", f"{rel} is not a text file"
    text = data.decode("utf-8", "replace")
    lines = text.split("\n")
    if len(lines) > max_lines:
        text = "\n".join(lines[:max_lines]) + f"\n... ({len(lines) - max_lines} more lines not shown)"
    return redact(text), ""


def _walk(ws: Workspace, limit: int = 4000) -> "list[str]":
    out: list = []
    for root, dirs, files in os.walk(ws.path):
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "target", "dist", "build", ".stack-src")
                   and not os.path.islink(os.path.join(root, d))]
        for fn in files:
            rel = os.path.relpath(os.path.join(root, fn), ws.path).replace(os.sep, "/")
            out.append(rel)
            if len(out) >= limit:
                return out
    return out


def files_mentioned(question: str, ws: Workspace, *, limit: int = 2) -> "list[str]":
    """Paths in ``ws`` whose basename the question names (fuzzy: a word with a dot in
    it, or a bare basename)."""
    words = set(re.findall(r"[A-Za-z0-9_./\-]+\.[A-Za-z0-9]+", question or ""))
    if not words:
        return []
    found: list = []
    for rel in _walk(ws):
        base = os.path.basename(rel)
        if rel in words or base in words or any(w.endswith("/" + base) for w in words):
            if safe_path(ws, rel)[1] == "" and rel not in found:
                found.append(rel)
        if len(found) >= limit:
            break
    return found


def too_big_reason(question: str, edits: "Iterable[FileEdit] | None" = None) -> str:
    """Why this is more than a small edit ("" when it is small)."""
    low = (question or "").lower()
    for w in _BIG_WORDS:
        if w in low:
            return f"you asked to {w}"
    if edits is not None:
        edits = list(edits)
        if len(edits) > SCOPE["max_files"]:
            return f"{len(edits)} files, I edit up to {SCOPE['max_files']}"
        changed = sum(e.changed for e in edits)
        if changed > SCOPE["max_changed_lines"]:
            return f"{changed} changed lines, I edit up to {SCOPE['max_changed_lines']}"
    return ""


def handoff_text(reason: str) -> str:
    return (f"That is more than a small edit ({reason}). Open a coding session with the "
            "Launch button — your request is in the brief.")


# ── the diff ─────────────────────────────────────────────────────────────────────────
_DIFF_FENCE = re.compile(r"```diff\s*\n(.*?)```", re.S)
_HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def _diff_body(text: str) -> str:
    m = _DIFF_FENCE.search(text or "")
    return m.group(1) if m else (text or "")


def parse_diff(text: str, ws: Workspace) -> "list[FileEdit] | DiffProblem":
    """Parse a unified diff against the files in ``ws``; every hunk's context and minus
    lines must match the current file exactly."""
    body = _diff_body(text)
    lines = body.split("\n")
    edits: list = []
    i = 0
    cur_path: Optional[str] = None
    cur_hunks: list = []
    file_lines: list = []

    def flush():
        if cur_path is not None:
            changed = sum(h.added + h.removed for h in cur_hunks)
            edits.append(FileEdit(cur_path, tuple(cur_hunks), changed))

    while i < len(lines):
        ln = lines[i]
        if ln.startswith("--- "):
            i += 1
            continue
        if ln.startswith("+++ "):
            flush()
            raw = ln[4:].strip().split("\t")[0]
            raw = raw[2:] if raw.startswith("b/") else raw
            cur_path, cur_hunks = raw, []
            full, why = safe_path(ws, raw)
            if why:
                return DiffProblem(why)
            try:
                with open(full, "rb") as fh:
                    data = fh.read()
            except OSError:
                return DiffProblem(f"{raw} does not exist in {ws.name}")
            if b"\0" in data or len(data) > SCOPE["max_file_bytes"]:
                return DiffProblem(f"{raw} is binary or too big to edit")
            file_lines = data.decode("utf-8", "replace").split("\n")
            i += 1
            continue
        m = _HUNK_RE.match(ln)
        if m:
            if cur_path is None:
                return DiffProblem("the diff names no file (+++ b/<path>)")
            old_start = int(m.group(1))
            old_n = int(m.group(2)) if m.group(2) is not None else 1
            i += 1
            olds, news, added, removed = [], [], 0, 0
            while i < len(lines) and not _HUNK_RE.match(lines[i]) and not lines[i].startswith(("+++ ", "--- ")):
                hl = lines[i]
                if hl.startswith("\\ No newline"):
                    i += 1
                    continue
                if hl == "" and i == len(lines) - 1:
                    break
                tag, body_line = (hl[:1], hl[1:]) if hl else (" ", "")
                if tag == " ":
                    olds.append(body_line)
                    news.append(body_line)
                elif tag == "-":
                    olds.append(body_line)
                    removed += 1
                elif tag == "+":
                    news.append(body_line)
                    added += 1
                else:
                    return DiffProblem(f"{cur_path}: unexpected diff line {hl!r}")
                i += 1
            if len(olds) != old_n and old_n != 1:
                pass                                      # counts are advisory; the match below rules
            have = file_lines[old_start - 1: old_start - 1 + len(olds)]
            for n, (want, got) in enumerate(zip(olds, have + [None] * (len(olds) - len(have)))):
                if want != got:
                    return DiffProblem(f"{cur_path} line {old_start + n}: the file says "
                                       f"{(got if got is not None else '(end of file)')!r}, the diff expects {want!r}")
            if cur_hunks and old_start <= cur_hunks[-1].old_start + len(cur_hunks[-1].old_lines) - 1:
                return DiffProblem(f"{cur_path}: hunks overlap")
            cur_hunks.append(Hunk(old_start, tuple(olds), tuple(news), added, removed))
            continue
        i += 1
    flush()
    if not edits:
        return DiffProblem("no diff hunks found; say which file and what to change")
    if len(edits) > SCOPE["max_files"]:
        return DiffProblem(too_big_reason("", edits))
    if sum(e.changed for e in edits) > SCOPE["max_changed_lines"]:
        return DiffProblem(too_big_reason("", edits))
    return edits


def preview(edits: "Iterable[FileEdit]") -> str:
    """A unified-diff text for the viewer (from the parsed hunks, normalised)."""
    out: list = []
    for e in edits:
        out += [f"--- a/{e.path}", f"+++ b/{e.path}"]
        for h in e.hunks:
            out.append(f"@@ -{h.old_start},{len(h.old_lines)} +{h.old_start},{len(h.new_lines)} @@")
            olds, news = list(h.old_lines), list(h.new_lines)
            # a plain two-sided listing: common prefix as context, then - and +
            k = 0
            while k < len(olds) and k < len(news) and olds[k] == news[k]:
                out.append(" " + olds[k])
                k += 1
            tail = 0
            while (tail < len(olds) - k and tail < len(news) - k
                   and olds[len(olds) - 1 - tail] == news[len(news) - 1 - tail]):
                tail += 1
            out += ["-" + x for x in olds[k:len(olds) - tail]]
            out += ["+" + x for x in news[k:len(news) - tail]]
            out += [" " + x for x in olds[len(olds) - tail:]]
    return "\n".join(out) + "\n"


# ── apply / revert ───────────────────────────────────────────────────────────────────
def edits_dir(state_dir: str) -> str:
    return os.path.join(state_dir, "assistant-edits")


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def apply(edits: "Iterable[FileEdit]", ws: Workspace, state_dir: str) -> "Applied | DiffProblem":
    edits = list(edits)
    reason = too_big_reason("", edits)
    if reason:
        return DiffProblem(handoff_text(reason))
    eid = time.strftime("%Y%m%d-%H%M%S") + f"-{os.getpid() % 10000:04d}"
    base = os.path.join(edits_dir(state_dir), eid)
    before_dir = os.path.join(base, "before")
    files: list = []
    plan: list = []
    for e in edits:
        full, why = safe_path(ws, e.path)
        if why:
            return DiffProblem(why)
        with open(full, "rb") as fh:
            old = fh.read()
        new = e.new_text(old.decode("utf-8", "replace")).encode("utf-8")
        plan.append((e.path, full, old, new))
    try:
        os.makedirs(before_dir, exist_ok=True)
        for rel, full, old, new in plan:
            dest = os.path.join(before_dir, rel.replace("/", os.sep))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as fh:
                fh.write(old)
            files.append({"path": rel, "before": _sha(old), "after": _sha(new)})
        manifest = {"id": eid, "workspace": ws.path, "mesh": ws.mesh, "domain": ws.domain,
                    "app": ws.app, "files": files, "time": time.time()}
        with open(os.path.join(base, "manifest.json"), "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=1)
        for rel, full, old, new in plan:
            tmp = full + ".assistant.tmp"
            with open(tmp, "wb") as fh:
                fh.write(new)
            os.replace(tmp, full)
    except OSError as exc:
        return DiffProblem(f"could not write: {exc.__class__.__name__}: {exc}")
    _prune(state_dir)
    return Applied(eid, ws.path, ws.mesh, ws.domain, files, before_dir, manifest["time"])


def revert(applied: Applied) -> "str":
    """Restore the before copies; "" on success, else the reason."""
    for f in applied.files:
        full = os.path.join(applied.workspace, f["path"].replace("/", os.sep))
        src = os.path.join(applied.before_dir, f["path"].replace("/", os.sep))
        try:
            with open(full, "rb") as fh:
                now = _sha(fh.read())
        except OSError:
            now = ""
        if now != f["after"]:
            return (f"the file {f['path']} changed after my edit; revert by hand from {src}")
    for f in applied.files:
        full = os.path.join(applied.workspace, f["path"].replace("/", os.sep))
        src = os.path.join(applied.before_dir, f["path"].replace("/", os.sep))
        try:
            shutil.copyfile(src, full + ".assistant.tmp")
            os.replace(full + ".assistant.tmp", full)
        except OSError as exc:
            return f"could not restore {f['path']}: {exc.__class__.__name__}"
    return ""


def _prune(state_dir: str) -> None:
    base = edits_dir(state_dir)
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return
    for name in names[:-KEEP_EDITS]:
        shutil.rmtree(os.path.join(base, name), ignore_errors=True)


def list_applied(state_dir: str) -> "list[str]":
    try:
        return sorted(os.listdir(edits_dir(state_dir)))
    except OSError:
        return []


def load_applied(state_dir: str, eid: str) -> Optional[Applied]:
    base = os.path.join(edits_dir(state_dir), eid)
    try:
        with open(os.path.join(base, "manifest.json"), encoding="utf-8") as fh:
            m = json.load(fh)
    except (OSError, ValueError):
        return None
    try:
        return Applied(str(m["id"]), str(m["workspace"]), str(m.get("mesh", "")),
                       str(m.get("domain", "")), list(m["files"]), os.path.join(base, "before"),
                       float(m.get("time", 0)))
    except (KeyError, TypeError, ValueError):
        return None
