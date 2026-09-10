"""What the two emulation faces genuinely share — and nothing else.

The Studio has two emulation screens and they are deliberately NOT the same screen:

  * ``gui/pages/qemu.py``           — the TEST face: boot the session's rows, assert,
    power off, read the verdicts. Ephemeral by construction.
  * ``gui/pages/mesh_emulation.py`` — the DEPLOY face: a standing ``--keep-alive``
    mesh with a console (ssh, QMP, per-device save, the whole-mesh save, the web
    front door).

Before this module they shared their code the way pages usually do — by having been
copy-pasted from one another. That is how the two screens came to disagree about
things they had no business disagreeing about: one greyed a Shell button for a
paused guest and the other did not, one badged an aborted build session and the
other silently defaulted to it, one printed a copy-ready ssh command when no
terminal emulator existed and the other printed nothing. Each of those is a
one-line divergence, and each of them cost an operator a debugging session.

WHAT LIVES HERE, AND THE RULE FOR ADDING TO IT
----------------------------------------------
Only things BOTH faces need, in the SAME shape:

* :func:`populate_sessions` — the session picker, badged. This is the aborted-session
  default trap: ``out/sessions`` keeps every session a build ever minted, including
  the ones whose build died after one image, and a picker that just took the newest
  handed the operator a 1-of-4 "mesh". Both pickers now list every session, mark the
  PARTIAL ones, and preselect the newest COMPLETE one.
* the status vocabulary's COLOURS — one map, so a SUSPECT row cannot read green on
  one screen and amber on the other. The rule the map encodes is
  :data:`NEVER_GREEN`: PASS is the only green verdict there is.
* :func:`button_strip` / :func:`make_table` / :func:`set_cell` — the table
  delegates. QTableWidget takes ONE widget per cell, so several controls in a cell
  need a container; doing that twice produced two different row heights.
* :class:`ReplicaStrip` — the −/count/+/Apply row control, mounted by the mesh
  monitor's pod table AND by the emulation device table (#336). One shape, one rule
  about what a repaint may do to a target the operator is still choosing.
* :func:`open_terminal` — opening the desktop terminal, with the copy-ready INLINE
  fallback for a desktop that has no terminal emulator. Inline, never a dialog: a
  modal in page logic hangs the headless tests, and "no terminal here" is a fact to
  read rather than a decision to make.
* :class:`DockerProbe` — the availability probe, off the GUI thread.

Everything that is not shared by both faces stays on the page that owns it. This
module is not a junk drawer: a helper only one page calls belongs to that page,
where its reasons are next to it.
"""
from __future__ import annotations

import datetime
import html
import os
import shlex
import subprocess

from ..qt import Qt, QtCore, QtGui, QtWidgets, Signal
from ..styles import MUTED, WARN
from ...core import emulation, qemu_devices, qemu_tests

# ── the status vocabulary, in colour ────────────────────────────────────────────────
#: PASS green and FAIL/ERROR red are the runner's own two outcomes. Everything else
#: is a verdict core/emulation SYNTHESIZED, and every one of those is a reason to
#: look rather than a reason to relax — so they are amber, never green.
GREEN = "#2e7d32"
RED = "#c62828"

#: The three verdicts that must NEVER render green, each earned the hard way:
#:
#: * SUSPECT — a PASS with zero assertions recorded. On 2026-08-19 six rows holding
#:   9-12 real FAILs each were graded PASS with no assertions counted, and the table
#:   showed six greens.
#: * NO-RESULT — planned, the run finished, no verdict was ever written. That night
#:   x86/be and x86/pki simply vanished from the results: the old table rendered the
#:   rows it FOUND, so a row that produced nothing was indistinguishable from a row
#:   that had never been planned.
#: * STALE — a verdict that predates this boot. results/ is never wiped, so last
#:   week's PASS for this label is sitting on disk waiting to be shown as today's.
NEVER_GREEN = frozenset({emulation.VERDICT_SUSPECT, emulation.VERDICT_STALE,
                         emulation.VERDICT_NO_RESULT})

VERDICT_COLOURS = {
    "PASS": GREEN,
    "FAIL": RED,
    "ERROR": RED,
    emulation.VERDICT_SUSPECT: WARN,
    emulation.VERDICT_STALE: WARN,
    emulation.VERDICT_NO_RESULT: WARN,
}

STATE_COLOURS = {
    emulation.STATE_PLANNED: MUTED,
    emulation.STATE_BOOTING: WARN,
    emulation.STATE_RUNNING: GREEN,
    emulation.STATE_ASSERTIONS: WARN,
    emulation.STATE_STOPPED: MUTED,
}

#: What each synthesized verdict MEANS, on the widget rather than in prose. The
#: per-row ``DeviceStatus.detail`` carries the specifics (which epoch, how many
#: assertions); this carries the class of problem, which is the part an operator
#: seeing it for the first time needs.
VERDICT_TOOLTIPS = {
    emulation.VERDICT_SUSPECT:
        "PASS with ZERO assertions recorded. A verdict that asserted nothing is "
        "not a green row — it is a row whose assertions never ran, or never "
        "reported. Read the device's log before trusting it.",
    emulation.VERDICT_STALE:
        "This verdict is OLDER than the boot it is shown against — it belongs to "
        "an earlier run of the same label. The results directory is never wiped, "
        "so it is still on disk; it is not this run's outcome.",
    emulation.VERDICT_NO_RESULT:
        "The run finished and this planned row produced NO verdict at all. The "
        "row is not missing from the table (that is how it used to look) — it is "
        "here, saying that nothing was recorded for it.",
    "": "No verdict yet, and none is owed yet.",
}

#: The verdict a row shows before anything is owed. Spelled once so a table cell and
#: a summary line cannot disagree about how "nothing yet" reads.
PENDING_TEXT = "pending"


def verdict_colour(verdict: str) -> str:
    """The colour a verdict reads as — "" for "leave the palette alone"."""
    return VERDICT_COLOURS.get(verdict or "", "")


def state_colour(state: str) -> str:
    return STATE_COLOURS.get(state or "", "")


def is_green(verdict: str) -> bool:
    """Only a fresh, assertion-backed PASS. Mirrors ``DeviceStatus.green`` so the
    GUI cannot grade a row differently from the facade that graded it."""
    return verdict == "PASS"


def verdict_text(verdict: str) -> str:
    return verdict or PENDING_TEXT


def status_summary(st: emulation.MeshStatus) -> str:
    """"3 passed / 1 failed / 2 no-result" — the completion wording, from status().

    The old TEST page printed "== device tests passed ==" whenever the runner exited
    0, which is a different question from whether the devices passed: a run that
    booted nothing, or one whose rows produced no verdict at all, exits 0 too. This
    counts the graded rows and names every bucket that is non-empty, so a run with
    six SUSPECT rows cannot report itself as a pass.
    """
    counts = st.counts()
    buckets = [
        ("passed", counts.get("PASS", 0)),
        ("failed", counts.get("FAIL", 0) + counts.get("ERROR", 0)),
        ("no-result", counts.get(emulation.VERDICT_NO_RESULT, 0)),
        ("suspect", counts.get(emulation.VERDICT_SUSPECT, 0)),
        ("stale", counts.get(emulation.VERDICT_STALE, 0)),
        ("pending", counts.get("PENDING", 0)),
    ]
    named = [f"{n} {name}" for name, n in buckets if n]
    if not named:
        return "no planned rows to grade"
    return " / ".join(named)


# ── the session picker, badged ───────────────────────────────────────────────────────
#: Why a session is marked. Verbatim on the item, because the badge in the summary
#: line ("[PARTIAL — 1 of 4 image(s)]") says WHAT but not why it matters.
PARTIAL_TOOLTIP = (
    "{badge}. The build that minted this session did not finish its fleet, so the "
    "images it holds are a FRACTION of what was configured. Each one is real and "
    "individually bootable — but “emulate the mesh” against this session "
    "emulates that fraction, silently. It is offered, not preselected."
)
COMPLETE_TOOLTIP = ("Every image this build intended is present, so the whole "
                    "session can be emulated.")


def default_session_index(sessions: list[qemu_tests.BuildSession]) -> int:
    """Which session a picker should preselect: the newest COMPLETE one.

    ``discover_sessions`` returns newest-first, so "the first non-partial" IS
    ``qemu_tests.default_session``'s rule, applied to a list the caller already has
    rather than by re-walking the filesystem. When every session is partial the
    newest of them still wins — runnable-with-a-badge beats nothing — and an empty
    list answers -1 rather than 0.

    This is the fix for the aborted-session default trap: on 2026-08-19 the newest
    session on this workstation was a 1-of-4 abort, both pickers defaulted to it,
    and nine of ten device Starts failed because the image the row wanted was not
    in the session the page had silently chosen.
    """
    for i, session in enumerate(sessions):
        if not session.is_partial:
            return i
    return 0 if sessions else -1


def populate_sessions(combo: QtWidgets.QComboBox,
                      sessions: list[qemu_tests.BuildSession]) -> int:
    """Fill a session picker and preselect the newest COMPLETE session.

    Signals are blocked throughout: filling a combo emits currentIndexChanged once
    per insertion, and each of those would replan the mesh against a half-built
    list. The caller re-plans ONCE afterwards. Returns the selected index.
    """
    combo.blockSignals(True)
    try:
        combo.clear()
        for session in sessions:
            combo.addItem(session.summary(), session.path)
            i = combo.count() - 1
            badge = session.completeness_badge()
            if badge:
                combo.setItemData(i, QtGui.QBrush(QtGui.QColor(WARN)),
                                  Qt.ItemDataRole.ForegroundRole)
                combo.setItemData(i, PARTIAL_TOOLTIP.format(badge=badge),
                                  Qt.ItemDataRole.ToolTipRole)
            else:
                combo.setItemData(i, COMPLETE_TOOLTIP, Qt.ItemDataRole.ToolTipRole)
        index = default_session_index(sessions)
        if index >= 0:
            combo.setCurrentIndex(index)
    finally:
        combo.blockSignals(False)
    return index


def partial_note(session: qemu_tests.BuildSession | None) -> str:
    """The INLINE warning for a PARTIAL session the operator has selected anyway.

    "" when the session is complete (or absent) — a note that is always on is a
    note nobody reads.
    """
    if session is None or not session.is_partial:
        return ""
    return (f'<span style="color:{WARN}"><b>{html.escape(session.completeness_badge())}'
            "</b></span> — this build did not finish. Every action here covers only "
            f"the {len(session.rows)} image(s) that exist; the rest were never built.")


# ── table delegates ──────────────────────────────────────────────────────────────────

def button_strip(*widgets: QtWidgets.QWidget) -> QtWidgets.QWidget:
    """Several controls in ONE table cell.

    ``setCellWidget`` takes a single widget, so a group needs a container; the zero
    margins are what keep the row the same height as the plain-text cells beside it
    (two hand-rolled copies of this had different margins, and the two tables had
    visibly different row heights).
    """
    holder = QtWidgets.QWidget()
    lay = QtWidgets.QHBoxLayout(holder)
    lay.setContentsMargins(0, 0, 0, 0)
    lay.setSpacing(2)
    for w in widgets:
        lay.addWidget(w)
    return holder


class ReplicaStrip:
    """The −/count/+/Apply control for ONE table row, and the pending target it holds.

    THREE tables mount this now — the mesh monitor's pods and containers, and the
    emulation page's devices — so it lives here for the reason everything else in this
    module does: two hand-rolled copies of a row control is how the two screens came to
    disagree about the same thing. It is a plain object, not a QWidget subclass: the
    cell takes ``strip.widget`` and the caller keeps the strip.

    THE PENDING TARGET IS THE OPERATOR'S, AND A REPAINT MUST NOT TAKE IT AWAY. Both
    tables repaint on a timer, and an operator pressing + three times would otherwise
    watch the number snap back mid-decision. So ``target`` survives every repaint until
    either Apply runs it or reality catches up with it (``observed == target``), at
    which point the cell goes back to showing a plain count.

    ``ceiling`` is a mis-click guard, not a claim about the lane. The emulation device
    table passes 1, because an emulated device is one guest per built image with its own
    MAC, IP and ssh port allocated by the plan — 0 and 1 are the only counts that exist
    there, and its tooltip says so rather than offering a number the runner would refuse.
    """

    def __init__(self, key: str, *, ceiling: int, what: str = "",
                 apply_text: str = "Apply", minus_tip: str = "", plus_tip: str = "",
                 apply_tip: str = ""):
        self.key = key
        self.ceiling = int(ceiling)
        #: How the workload reads in the count tooltip. Held here so a busy repaint of
        #: every row never has to re-derive it, and can never fall back to a raw key.
        self.what = what or key
        self.target = 0
        self.observed = 0
        self.minus = QtWidgets.QPushButton("−")
        self.minus.setToolTip(minus_tip or "One fewer.")
        self.count = QtWidgets.QLabel("0")
        self.count.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.count.setMinimumWidth(48)
        self.plus = QtWidgets.QPushButton("+")
        self.plus.setToolTip(plus_tip or f"One more, up to {self.ceiling}.")
        self.apply = QtWidgets.QPushButton(apply_text)
        self.apply.setToolTip(apply_tip or "Run it.")
        for b in (self.minus, self.plus):
            b.setMaximumWidth(28)
        self.widget = button_strip(self.minus, self.count, self.plus, self.apply)

    def bump(self, delta: int) -> int:
        """Move the target within [0, ceiling] and answer where it landed."""
        self.target = max(0, min(self.ceiling, self.target + int(delta)))
        return self.target

    def paint(self, observed: int, *, busy: bool = False) -> None:
        self.observed = int(observed)
        if self.target == self.observed:
            self.count.setText(str(self.observed))
        else:
            self.count.setText(f"{self.observed} → {self.target}")
        self.count.setToolTip(
            f"{self.what}: {self.observed} running"
            + ("" if self.target == self.observed
               else f"; Apply would ask for {self.target}"))
        self.minus.setEnabled(not busy and self.target > 0)
        self.plus.setEnabled(not busy and self.target < self.ceiling)
        self.apply.setEnabled(not busy and self.target != self.observed)


def make_table(headers: tuple[str, ...], *, min_height: int = 140
               ) -> QtWidgets.QTableWidget:
    """A read-only table with these headers — the one place the shared knobs live."""
    table = QtWidgets.QTableWidget(0, len(headers))
    table.setHorizontalHeaderLabels(list(headers))
    table.horizontalHeader().setStretchLastSection(True)
    table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
    table.setMinimumHeight(min_height)
    return table


def set_cell(table: QtWidgets.QTableWidget, row: int, col: int, text: str, *,
             tooltip: str = "", colour: str = "") -> QtWidgets.QTableWidgetItem:
    """Write one cell, reusing the item already there.

    Reused rather than replaced because both tables REPAINT rows on a timer now: a
    fresh QTableWidgetItem per tick throws away the selection and the scroll anchor
    under the operator's cursor every few seconds.
    """
    item = table.item(row, col)
    if item is None:
        item = QtWidgets.QTableWidgetItem()
        table.setItem(row, col, item)
    item.setText(str(text))
    item.setToolTip(tooltip)
    if colour:
        item.setForeground(QtGui.QColor(colour))
    else:
        item.setForeground(table.palette().text().color())
    return item


# ── the desktop terminal, with the copy-ready fallback ───────────────────────────────

def open_terminal(argv: list[str]) -> tuple[bool, str, str]:
    """Open the desktop terminal on ``argv`` — DETACHED. Returns (opened, note, log).

    ``note`` is INLINE HTML for the page's own label and is empty on success; a
    modal here would hang every headless test, and neither failure below is a
    question anyway. The no-terminal case surfaces the exact command instead, so
    the login is one paste away rather than gone — that is the whole difference
    between "the button does nothing" and "this desktop has no terminal emulator,
    here is the command".

    ``start_new_session``: the terminal is the operator's session from here on and
    must outlive the page and the wizard (the CloudDeploy destroy-TTY precedent).
    No pipes — the terminal owns its own tty.
    """
    cmd = qemu_devices.terminal_argv(argv)
    if cmd is None:
        hint = shlex.join(argv)
        return False, (f'<span style="color:{WARN}">No terminal emulator found on '
                       f"this desktop.</span> Run this yourself: "
                       f"<tt>{html.escape(hint)}</tt>"), \
            f"no terminal emulator — run: {hint}"
    try:
        subprocess.Popen(cmd, start_new_session=True)
    except OSError as exc:
        return False, (f'<span style="color:{WARN}">Could not open a terminal: '
                       f"{html.escape(str(exc))}</span>"), \
            f"!! could not open a terminal: {exc}"
    return True, "", shlex.join(cmd)


# ── files, described ─────────────────────────────────────────────────────────────────

def human_bytes(size: float) -> str:
    """"12.4 MB" / "9.5 GB" — sizes an operator can compare at a glance."""
    if size < 0:
        return "unknown"
    value = float(size)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TB"


def describe_file(path: str) -> str:
    """"12.4 MB, saved 2026-08-14 21:09" — what an Overwrite is about to destroy.

    The size and the timestamp are the only two things that let an operator tell one
    save from another before agreeing to lose it, so the destructive control names
    them instead of saying "the previous save".
    """
    try:
        st = os.stat(path)
    except OSError:
        return "unreadable"
    when = datetime.datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M")
    return f"{human_bytes(st.st_size)}, saved {when}"


# ── docker availability, without the freeze ──────────────────────────────────────────
#: How long the GUI thread will wait for an INSTANT answer before painting
#: "checking…" and letting the probe land later.
#:
#: Both pages used to call the synchronous ``docker_available()`` inside
#: ``initializePage``, whose default wall clock is 15 SECONDS — and a wedged daemon
#: takes all of it, with the window frozen and unpainted the whole time. A healthy
#: daemon answers in tens of milliseconds and a missing binary answers instantly, so
#: this grace covers every case that is not already broken, and the broken case now
#: paints a page instead of a frozen rectangle.
DOCKER_PROBE_GRACE_S = 0.35

#: The prefix ``qemu_tests.docker_available_async`` puts on an answer its probe
#: could not produce at all. That helper calls ``docker_available(timeout_s=…)`` —
#: by KEYWORD — so this prefix means the call SHAPE was wrong, never that docker is
#: unavailable: the real probe catches its own OSError/SubprocessError and answers
#: (False, "docker was not found on PATH.") &c. rather than raising.
_PROBE_FAILED = "docker probe failed: "


def _reprobe_without_kwargs(why: str) -> tuple[bool, str]:
    """Answer a signature-shaped probe failure by asking again, plainly.

    A tree (or a test) whose ``docker_available`` takes no ``timeout_s`` is a
    perfectly working probe that the async wrapper cannot call; reporting "docker is
    unavailable" for it would grey every run button on a machine where docker is
    fine. Runs on the worker thread, like the probe it is replacing, and keeps the
    original text when the plain call fails too — a probe must never answer mute.
    """
    try:
        ok, reason = qemu_tests.docker_available()
    except Exception as exc:  # noqa: BLE001 — see above: a probe never dies mute
        return False, f"{why} (and a plain re-probe also failed: {exc})"
    return bool(ok), str(reason)


class DockerProbe(QtCore.QObject):
    """``qemu_tests.docker_available_async``, marshalled back onto the GUI thread.

    The core probe calls its callback FROM the worker thread, which must never touch
    a widget; ``answered`` is the queued signal that gets the result home. The short
    join in :meth:`start` is not a fallback to the old synchronous probe — it is the
    difference between "the page paints with the answer already on it" and "the page
    paints, then flickers 40ms later", for the overwhelmingly common case where
    docker answers at once.

    Delivered at most once per answer (:meth:`_deliver` de-duplicates), so a fast
    probe that satisfies both the join and the queued signal repaints once.
    """
    answered = Signal(bool, str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._answer: tuple[bool, str] | None = None
        self._late = _LateAnswer(self)
        self._late.landed.connect(self._deliver)

    @property
    def answer(self) -> tuple[bool, str] | None:
        """The last answer, or None while the first probe is still out."""
        return self._answer

    def start(self):
        """Probe. Returns the worker thread so a caller (or a test) can join it."""
        box: dict[str, tuple[bool, str]] = {}

        def on_result(ok, why):           # runs ON THE WORKER THREAD
            ok, why = bool(ok), str(why)
            if not ok and why.startswith(_PROBE_FAILED):
                ok, why = _reprobe_without_kwargs(why)
            box["a"] = (ok, why)
            try:
                self._late.landed.emit(ok, why)
            except RuntimeError:
                # The page was destroyed while the probe was out (a wizard closed
                # mid-answer). The answer has nowhere to go and that is fine — but a
                # daemon thread must not die on a traceback nobody reads.
                pass

        thread = qemu_tests.docker_available_async(on_result)
        thread.join(DOCKER_PROBE_GRACE_S)
        if "a" in box:
            self._deliver(*box["a"])
        return thread

    def _deliver(self, ok: bool, why: str):
        answer = (bool(ok), str(why))
        if answer == self._answer:
            return
        self._answer = answer
        self.answered.emit(*answer)


class _LateAnswer(QtCore.QObject):
    """The queued hop for an answer that missed the grace window.

    Its own QObject rather than a second signal on DockerProbe so that the
    de-duplicating ``_deliver`` is the only thing connected to it — a page connects
    to ``DockerProbe.answered`` and can never accidentally receive the raw,
    possibly-duplicated worker-thread emission.
    """
    landed = Signal(bool, str)


def docker_note_html(answer: tuple[bool, str] | None) -> str:
    """The availability note both pages show, in all three states.

    Escaped and newline-broken for the unavailable case: the WSL remedy is
    multi-line and contains ``<distro>``, which RichText would otherwise eat as an
    unknown tag — deleting the one word that tells the operator what to substitute.
    """
    if answer is None:
        return (f'<span style="color:{MUTED}">Checking whether this machine can run '
                "the containerized harness…</span>")
    ok, why = answer
    if ok:
        return ("These devices boot inside a <b>privileged Docker container</b>: "
                "booting a golden image means loop-mounting it to lift its kernel "
                "out, which needs root. Container root comes from your <tt>docker</tt> "
                "group membership, so no sudo password is needed.")
    detail = "<br>".join(html.escape(line) for line in why.splitlines())
    return (f'<b style="color:{WARN}">Emulated devices cannot run on this machine '
            f"yet.</b> {detail}<br>The harness needs Docker because booting an image "
            "requires a root-only loop mount, which a GUI cannot obtain "
            "interactively.")
