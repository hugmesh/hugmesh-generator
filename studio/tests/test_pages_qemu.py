"""QemuPage — the THIN test face — plus the two ends of the device-test build chain.

After T3 this page is one thing: run a build session's rows to completion and say
what each row's verdict actually was. The persistent-device console it used to carry
(shell, QMP, start/stop, per-device save) lives on the MESH EMULATION page and is
tested in test_pages_mesh_emulation.py — including the two console tests that were
red on main by design, because the per-device Start they exercised was the runner's
newest-session guess and core.qemu_devices now refuses to author it.

WHAT THIS FILE PINS
-------------------
* THE SESSION PICKER, BADGED — every session is offered, partial ones are marked and
  the preselected one is the newest COMPLETE session. This is the aborted-session
  default trap: on 2026-08-19 the newest session on the operator's workstation was a
  1-of-4 abort, both pickers defaulted to it, and nine of ten device Starts failed
  because the image the row wanted was not in the session the page had chosen.
* THE ENVELOPE — every knob is a ``core.emulation.RunEnvelope`` field, asserted on
  the argv a CHILD PROCESS received rather than on anything this page printed. The
  two new ones (assertion timeout, extra guest logins) are here because the first is
  what makes a row grade SUSPECT when it is too short and the second is what puts
  logins on the guests the mesh page then offers.
* VERDICT INTEGRITY IN THE TABLE — one row per PLANNED row, always. A row that
  produced nothing says NO-RESULT (that night x86/be and x86/pki simply vanished); a
  PASS with zero assertions says SUSPECT and is NOT green (that night six such rows
  read green while holding 9-12 real FAILs each); a verdict from an earlier boot says
  STALE. And the completion line counts those buckets instead of reporting the
  runner's exit status as "device tests passed".
* WHAT LEFT — no device table, no keep-alive tick, no second spawn lane. A test that
  only added the new face would let the old one creep back in.
* THE BUILD CHAIN — unchanged, and asserted unchanged: the radio seeds
  cfg.qemu_device_tests,
  BuildPage's checkbox owns it from the moment it is reached, and the --env gate holds.

WHAT IS REAL HERE, AND WHY IT MATTERS
-------------------------------------
* the runner is the generator tree's real ``tests/qemu/run-qemu-docker.sh``, which
  here is a stub that ECHOES ITS OWN ARGV — so an assertion about "--extra-user
  alice" is an assertion about what a child process received, not about a string
  this page built;
* verdicts are JSON written to ``<work>/results/`` in the runner's own format and
  read back by the real ``core.emulation.status()``, which is what grades them;
* the device registry is written to ``<work>/devices/<safe-label>.json``, the actual
  cross-layer file format.

Hermetic all the same: no docker daemon, no qemu, no images, nothing launched into a
desktop terminal, and ``emulation.status``'s two shell-outs (the runner's --devices
probe and ``docker ps``) are stubbed off so the registry on disk is the only source.
"""
import dataclasses
import inspect
import json
import os
import shlex
import time
from types import SimpleNamespace

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import emulation, qemu_devices, qemu_tests  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo               # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                  # noqa: E402
from hugmesh_studio.gui.pages import _emulation_common as common     # noqa: E402
from hugmesh_studio.gui.pages import qemu as qemu_page               # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                          # noqa: E402

from _helpers import advance_to, back_to, pick_mode                  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# a canned host so wizard construction never probes the machine (docker info &c.)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

#: The stub runner. It echoes its own argv — that echo is what the assertions below
#: read, so they are about the argv a CHILD received. ``--list`` and a plain run are
#: instant; a run asked to linger (STUB_SLEEP) sleeps in a CHILD of this shell, so a
#: cancel that fails to signal the process GROUP leaves the pipe open and hangs —
#: which is what makes the cancel test a real discriminator.
_STUB_RUNNER = """#!/usr/bin/env bash
echo "STUB-RUNNER $*"
if [ -n "${STUB_SLEEP:-}" ]; then
    sleep 120
fi
exit 0
"""

#: The AVC workout stand-in (issue #45). Same echo discipline.
_STUB_AVC = """#!/usr/bin/env bash
echo "STUB-AVC $*"
exit 0
"""

#: The PLAYWRIGHT lane's stand-in (tests/qemu/run-qemu-e2e.sh). A SEPARATE marker
#: from _STUB_RUNNER on purpose: the assertions below are about which of the two
#: scripts the page actually spawned, and a shared marker would make the one
#: mutation that matters — aiming the envelope at run-qemu-docker.sh — invisible.
#: It echoes "$*" for the readable one-line assertions AND one line per argument,
#: because "$*" JOINS with spaces: a quoting regression that hands '--grep @smoke'
#: over as ONE argument is invisible in the joined form and obvious in the list.
#: (Measured: a mutation doing exactly that survived the joined-form assertions.)
_STUB_PLAYWRIGHT = """#!/usr/bin/env bash
echo "STUB-QEMU-E2E $*"
for a in "$@"; do echo "STUB-QEMU-E2E-ARG $a"; done
exit 0
"""


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _docker_stubbed(monkeypatch):
    # The page states docker availability up-front; the REAL probe would make every
    # test here depend on the host's daemon. Stubbed to available — the unavailable
    # arm is asserted explicitly in test_qemu_page_says_when_docker_is_missing.
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda: (True, "docker is available."))


@pytest.fixture(autouse=True)
def _e2e_gate_stubbed(monkeypatch):
    """The route to this page now passes THROUGH E2EPage (its own mode card was
    removed 2026-08-27), and E2EPage's entry starts an off-thread readiness probe that
    shells docker. Stub it, for the same reason `_docker_stubbed` exists right above:
    nothing asserted in this file is about the host's daemon, and a probe thread still
    in flight when its page is destroyed is a qFatal rather than an exception."""
    from hugmesh_studio.core.local_stack_node import LocalStackNode
    monkeypatch.setattr(LocalStackNode, "e2e_ready",
                        lambda self, environment="docker": ["stubbed probe"])


@pytest.fixture(autouse=True)
def _status_reads_only_the_registry(monkeypatch):
    """``emulation.status`` must not shell out from a unit test.

    Its two sources are the runner's ``--devices`` subcommand and ``docker ps``.
    Both are stubbed to "did not answer", which is the documented fallback: the raw
    registry, with NO downgrade applied (an unanswered daemon says nothing about the
    containers). The registry is what these tests write, so the table under
    assertion is the one the on-disk records imply.
    """
    monkeypatch.setattr(emulation, "_runner_devices", lambda *_a, **_k: None)
    monkeypatch.setattr(emulation, "_docker_running_names", lambda: None)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


def _write_images(session_dir, *names):
    session_dir.mkdir(parents=True, exist_ok=True)
    for n in names:
        (session_dir / n).write_bytes(b"\0")  # non-empty: a 0-byte .img is a killed build, not a row


@pytest.fixture
def fake_generator(tmp_path):
    """A generator tree with TWO sessions and stub scripts that echo their argv.

    ``20260201-000000-full`` is COMPLETE: two per-image build logs, two images.
    ``20260209-000000-abort`` is NEWER and PARTIAL: four per-image build logs
    (``expected_image_count``'s most faithful witness — a log exists only for an
    image whose build actually STARTED) and one image. That is the shape of the real
    ``out/sessions/20260819-125930-89bb8e`` on the operator's workstation, and it is
    the session a "newest wins" picker would have chosen.
    """
    gen = tmp_path / "gen"
    full = gen / "out" / "sessions" / "20260201-000000-full"
    _write_images(full,
                  "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
                  "hugmesh-x86-amd64-be-test-20260807T172418Z.img")
    for i in range(2):
        (full / f"build-image{i}.log").write_text("ok\n")

    abort = gen / "out" / "sessions" / "20260209-000000-abort"
    _write_images(abort, "hugmesh-rpi5-arm64-pki-test-20260209T010101Z.img")
    for i in range(4):
        (abort / f"build-image{i}.log").write_text("started\n")

    # Deterministic newest-first ordering: discover_sessions sorts on mtime.
    os.utime(full, (1_700_000_000, 1_700_000_000))
    os.utime(abort, (1_800_000_000, 1_800_000_000))

    qdir = gen / "tests" / "qemu"
    qdir.mkdir(parents=True)
    stub = qdir / "run-qemu-docker.sh"
    stub.write_text(_STUB_RUNNER)
    stub.chmod(0o755)
    avc = qdir / "avc-workout.sh"
    avc.write_text(_STUB_AVC)
    avc.chmod(0o755)
    pw = qdir / "run-qemu-e2e.sh"
    pw.write_text(_STUB_PLAYWRIGHT)
    pw.chmod(0o755)
    return gen, full, abort


@pytest.fixture
def wiz(qapp, fake_generator):
    gen, _full, _abort = fake_generator
    w = wizard_mod.StudioWizard(str(gen))
    w.show()          # offscreen: makes per-widget isVisible() meaningful
    yield w
    w.close()
    w.deleteLater()


@pytest.fixture
def real_wiz(qapp):
    # the BuildPage-gate tests walk the full standalone flow, whose pages read
    # real generator-tree data — they get the real tree, no qemu stub needed
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


@pytest.fixture
def work_dir(fake_generator):
    gen, _full, _abort = fake_generator
    return os.path.join(str(gen), qemu_tests.DEFAULT_WORK_SUBDIR)


@pytest.fixture
def results(work_dir):
    """WRITE a per-row verdict in the runner's own on-disk format.

    ``started_at`` is the field that matters: ``emulation.status`` grades a verdict
    STALE when it predates the plan's epoch, which is stamped when the run starts.
    The far-future/far-past stamps below are how a test says "this belongs to this
    run" or "this is last week's" without racing a wall clock.
    """
    resdir = os.path.join(work_dir, "results")

    def write(label, *, status="PASS", passed=12, failed=0,
              started_at="2999-01-01T00:00:00Z", detail=""):
        os.makedirs(resdir, exist_ok=True)
        name = qemu_tests.result_filename(label)
        with open(os.path.join(resdir, name), "w", encoding="utf-8") as fh:
            json.dump({"label": label, "status": status,
                       "assertions_passed": passed, "assertions_failed": failed,
                       "started_at": started_at, "detail": detail,
                       "duration_s": 42}, fh)
    return write


@pytest.fixture
def registry(work_dir):
    """WRITE device records into the real registry dir — the page's own discovery
    (through emulation.status) reads them back."""
    devdir = os.path.join(work_dir, "devices")

    def register(*devices):
        os.makedirs(devdir, exist_ok=True)
        for dev in devices:
            safe = dev.label.replace("/", "_").replace("+", "_")
            with open(os.path.join(devdir, f"{safe}.json"), "w",
                      encoding="utf-8") as fh:
                json.dump(dataclasses.asdict(dev), fh)
        return devices
    return register


def _device(label="rpi5/pki", state="running", port=22301,
            started_at="2999-01-01T00:00:00Z"):
    platform, _, role = label.partition("/")
    return qemu_devices.Device(
        label=label, platform=platform, role=role, board="",
        container="hugmesh-qemu-" + label.replace("/", "-"),
        ssh_host_port=port, ssh_user="tester", ssh_key="/w/keys/id_ed25519",
        users=["tester"], qmp="/w/q.sock", state=state, started_at=started_at)


def _qemu_page(wiz):
    """Walk to QemuPage the way an operator now can.

    Its own mode-menu card was removed on 2026-08-27 ("remove QEMU device emulation
    menu item ... but add the run e2e tests button"); the page was NOT, because it is
    the Studio's only door to tests/qemu/run-qemu-e2e.sh and avc-workout.sh. E2EPage's
    second radio arm is what writes ``wiz.qemu_selected`` now, so every test in this
    file enters through it. Everything past this function is unchanged.
    """
    pick_mode(wiz, "e2e")
    advance_to(wiz, wizard_mod.E2EPage).arm_qemu.setChecked(True)
    return advance_to(wiz, wizard_mod.QemuPage)


def _text_of(w):
    """Whatever a label/plain-text widget is currently showing."""
    return w.text() if hasattr(w, "text") else w.toPlainText()


def _echoed(page, marker="STUB-RUNNER"):
    """Every line a STUB script printed — i.e. the argv a child actually got."""
    return [ln for ln in page.log.toPlainText().splitlines()
            if ln.startswith(marker)]


def _finish(page, qapp, ms=15000):
    """Let the verb in flight run to completion and deliver its queued signals.

    ``done`` is a QUEUED signal, so the page's own bookkeeping (the verdict re-read,
    the completion line) has not happened when the thread ends — it happens on the
    next event-loop turn, which is what processEvents is.
    """
    assert page.worker is not None, "no verb was started"
    assert page.worker.wait(ms), "the verb never finished"
    qapp.processEvents()


def _pump_until(qapp, page, needle, seconds=15):
    deadline = time.time() + seconds
    while time.time() < deadline:
        qapp.processEvents()
        if needle in page.log.toPlainText():
            return True
        time.sleep(0.05)
    return False


def _row_of(page, label):
    for r in range(page.results.rowCount()):
        if page.results.item(r, 0).text() == label:
            return r
    raise AssertionError(f"no results row for {label!r}; got "
                         f"{[page.results.item(r, 0).text() for r in range(page.results.rowCount())]}")


def _cell(page, label, col):
    return page.results.item(_row_of(page, label), col)


def _colour(item) -> str:
    return item.foreground().color().name()


# ---- the session picker, badged ---------------------------------------------------

def test_qemu_picker_lists_every_session_and_badges_the_partial_one(wiz):
    page = _qemu_page(wiz)
    assert page.session_combo.count() == 2, "a partial session must be OFFERED"
    texts = [page.session_combo.itemText(i) for i in range(2)]
    partial = next(t for t in texts if "abort" in t)
    assert "PARTIAL — 1 of 4 image(s)" in partial
    # ...and the badge is on the item, in the warning colour, with the WHY in reach
    idx = texts.index(partial)
    tip = page.session_combo.itemData(idx, qemu_page.Qt.ItemDataRole.ToolTipRole)
    assert "did not finish its fleet" in tip


def test_qemu_picker_defaults_to_the_newest_COMPLETE_session(wiz, fake_generator):
    """THE aborted-session default trap, head-on.

    The newest session here is the 1-of-4 abort, exactly as it was on the operator's
    workstation the night nine of ten device Starts failed. Defaulting to it hands
    the operator a run against images that were never built."""
    _gen, full, abort = fake_generator
    page = _qemu_page(wiz)
    assert page.session_combo.currentData() == str(full)
    assert page.session_combo.currentData() != str(abort)
    # and the rule is the core's, not a second one invented here
    sessions = qemu_tests.discover_sessions(str(_gen))
    assert (common.default_session_index(sessions)
            == sessions.index(qemu_tests.default_session(str(_gen))))


def test_qemu_partial_session_picked_anyway_says_so_inline(wiz, fake_generator):
    _gen, _full, abort = fake_generator
    page = _qemu_page(wiz)
    assert page.session_note.text() == "", "a complete session needs no warning"
    idx = next(i for i in range(page.session_combo.count())
               if page.session_combo.itemData(i) == str(abort))
    page.session_combo.setCurrentIndex(idx)
    note = page.session_note.text()
    assert "PARTIAL — 1 of 4 image(s)" in note
    assert "the rest were never built" in note


# ---- the command preview, authored by the facade ----------------------------------

def test_qemu_previews_the_command_the_facade_authors(wiz, fake_generator):
    _gen, full, _abort = fake_generator
    page = _qemu_page(wiz)
    cmd = page.cmd_view.toPlainText()
    assert "run-qemu-docker.sh" in cmd
    assert f"--artifacts {full}" in cmd          # pinned, never the runner's guess
    assert "--jobs 2" in cmd and "--list" not in cmd
    assert "--keep-alive" not in cmd, "the TEST lane never leaves guests up"
    # the preview IS emulation.run_argv — not a second spelling that agrees today
    assert cmd.split() == emulation.run_argv(page.plan)


def test_qemu_default_envelope_adds_nothing_to_the_command(wiz):
    """Only non-default knobs reach the argv (runner_command's rule), so the two new
    fields must be invisible until they are used."""
    page = _qemu_page(wiz)
    cmd = page.cmd_view.toPlainText()
    assert "--assert-timeout" not in cmd
    assert "--extra-user" not in cmd
    assert "--cache-max-gb" not in cmd


def test_qemu_new_envelope_knobs_reach_the_previewed_command(wiz):
    page = _qemu_page(wiz)
    page.assert_timeout.setValue(600)
    page.extra_users.setText("alice, bob")
    page.cache_max.setValue(40)
    cmd = page.cmd_view.toPlainText()
    assert "--assert-timeout 600" in cmd
    assert "--extra-user alice" in cmd and "--extra-user bob" in cmd
    assert "--cache-max-gb 40" in cmd
    # they are RunEnvelope fields, not attributes pinned onto an options object —
    # a knob the envelope does not carry previews and then does not happen
    env = page._envelope()
    assert env.assert_timeout_s == 600
    assert env.extra_users == ("alice", "bob")
    assert env.cache_max_gb == 40


def test_qemu_extra_users_field_tolerates_either_separator(wiz):
    page = _qemu_page(wiz)
    page.extra_users.setText("alice bob,alice")
    assert page._envelope().extra_users == ("alice", "bob")   # de-duplicated
    page.extra_users.setText("alice,,")
    assert page._envelope().extra_users == ("alice",)         # no empty --extra-user


def test_qemu_new_knobs_reach_the_SPAWNED_runner(wiz, qapp):
    """The end of the chain: what the CHILD PROCESS was given.

    The stub echoes its own argv, so this reads the flags off the spawned command
    rather than off anything this page printed — a preview agreeing with itself is
    exactly the failure this replaces.
    """
    page = _qemu_page(wiz)
    page.assert_timeout.setValue(900)
    page.extra_users.setText("carol")
    page._launch(list_only=False)
    _finish(page, qapp)
    echoed = _echoed(page)
    assert echoed, "the stub runner never ran"
    assert "--assert-timeout 900" in echoed[0]
    assert "--extra-user carol" in echoed[0]


# ---- running -----------------------------------------------------------------------

def test_qemu_list_devices_streams_the_stub_runner(wiz, qapp):
    page = _qemu_page(wiz)
    page._launch(list_only=True)
    assert page.worker is not None
    assert not page.run_btn.isEnabled()                  # running: no double-launch
    _finish(page, qapp)
    log = page.log.toPlainText()
    assert "STUB-RUNNER" in log and "--list" in log and "--artifacts" in log
    assert page.run_btn.isEnabled() and not page.cancel_btn.isEnabled()


def test_qemu_run_reports_the_verdicts_not_the_exit_status(wiz, qapp):
    """The old page printed "== device tests passed ==" whenever the runner exited 0.

    The stub exits 0 and writes NO verdict, which is exactly the 2026-08-19 shape: a
    run that reported success while two planned rows produced nothing at all. The
    completion line must count what was graded.
    """
    page = _qemu_page(wiz)
    page._launch(list_only=False)
    _finish(page, qapp)
    log = page.log.toPlainText()
    assert "device tests passed" not in log
    assert "2 no-result" in log


def test_qemu_run_counts_every_bucket_it_finds(wiz, qapp, results):
    results("rpi5/pki", status="PASS", passed=12)
    results("x86/backend", status="FAIL", passed=3, failed=9)
    page = _qemu_page(wiz)
    page._launch(list_only=False)
    _finish(page, qapp)
    log = page.log.toPlainText()
    assert "1 passed" in log and "1 failed" in log


def test_qemu_cancel_stays_armed_so_a_second_press_re_signals(wiz, qapp,
                                                              monkeypatch):
    """Cancel sends SIGTERM and nothing escalates to SIGKILL.

    A runner that ignores the first signal — a qemu hung in TCG, a docker pull
    mid-layer — would be uncancellable from the GUI for the rest of the run if the
    first press disarmed the button. Re-sending is the only escalation the operator
    has, so the button stays armed while the work is still in flight and the log
    distinguishes the repeat.

    The stub sleeps in a CHILD of itself, so passing also proves the spawn used
    start_new_session and the cancel reached the process GROUP: signalling only the
    direct child would leave the sleep holding the stdout pipe open.
    """
    monkeypatch.setenv("STUB_SLEEP", "1")
    page = _qemu_page(wiz)
    page._launch(list_only=False)
    assert _pump_until(qapp, page, "STUB-RUNNER"), "the runner stand-in never started"
    assert not page.isComplete()                     # the page is locked meanwhile

    # Called directly rather than clicked: no event-loop turn runs between the two,
    # so the second press is guaranteed to land while the work is still running.
    page._cancel()
    assert page.cancel_btn.isEnabled(), "Cancel disarmed itself; SIGTERM cannot be re-sent"
    assert "cancelling" in page.log.toPlainText()
    page._cancel()
    assert "re-sending" in page.log.toPlainText()

    assert page.worker.wait(20000), "Cancel did not stop the run"
    qapp.processEvents()
    assert not page.cancel_btn.isEnabled()           # ...but greyed once work ends
    assert page.isComplete()


def test_qemu_a_cancelled_run_does_not_accuse_its_rows_of_no_result(
        wiz, qapp, monkeypatch):
    """NO-RESULT means "the run finished and this row produced nothing". A cancel is
    not a finish, and grading every cut-short row NO-RESULT would blame the rows for
    the operator's own stop."""
    monkeypatch.setenv("STUB_SLEEP", "1")
    page = _qemu_page(wiz)
    page._launch(list_only=False)
    assert _pump_until(qapp, page, "STUB-RUNNER")
    page._cancel()
    assert page.worker.wait(20000)
    qapp.processEvents()
    assert page._run_completed is False
    assert emulation.VERDICT_NO_RESULT not in page.log.toPlainText()


# ---- verdict integrity, in the table ----------------------------------------------

def test_qemu_table_holds_one_row_per_PLANNED_row_before_anything_runs(wiz):
    page = _qemu_page(wiz)
    assert page.results.rowCount() == 2
    assert {page.results.item(r, 0).text() for r in range(2)} == {"rpi5/pki", "x86/backend"}
    assert _cell(page, "x86/backend", 1).text() == emulation.STATE_PLANNED


def test_qemu_no_result_row_renders_explicitly_and_is_not_green(wiz, qapp, results):
    """2026-08-19: x86/be and x86/pki simply were not in the table.

    The old table rendered the result FILES it found, so a planned row that produced
    nothing was indistinguishable from a row that had never been planned — and the
    run above it said it had passed.
    """
    results("rpi5/pki", status="PASS", passed=12)     # one row reports, one does not
    page = _qemu_page(wiz)
    page._launch(list_only=False)
    _finish(page, qapp)
    cell = _cell(page, "x86/backend", 2)
    assert cell.text() == emulation.VERDICT_NO_RESULT
    assert _colour(cell) != common.GREEN
    assert "no verdict" in cell.toolTip().lower() or "NO verdict" in cell.toolTip()


def test_qemu_suspect_row_is_never_green(wiz, results):
    """A PASS with ZERO assertions recorded. Six of these read green on 2026-08-19
    while holding 9-12 real FAILs each."""
    results("rpi5/pki", status="PASS", passed=0, failed=0)
    page = _qemu_page(wiz)
    page._reload_results()
    cell = _cell(page, "rpi5/pki", 2)
    assert cell.text() == emulation.VERDICT_SUSPECT
    assert _colour(cell) != common.GREEN
    assert "asserted nothing" in cell.toolTip()


def test_qemu_stale_verdict_is_marked_rather_than_shown_as_this_run(wiz, results):
    """results/ is never wiped, so last week's PASS for this label is sitting on
    disk waiting to be presented as today's outcome."""
    results("rpi5/pki", status="PASS", passed=12,
            started_at="2000-01-01T00:00:00Z")
    page = _qemu_page(wiz)
    page._reload_results()
    cell = _cell(page, "rpi5/pki", 2)
    assert cell.text() == emulation.VERDICT_STALE
    assert _colour(cell) != common.GREEN


def test_qemu_a_real_pass_is_the_only_green(wiz, results):
    results("rpi5/pki", status="PASS", passed=12)
    results("x86/backend", status="FAIL", passed=2, failed=7)
    page = _qemu_page(wiz)
    page._reload_results()
    ok, bad = _cell(page, "rpi5/pki", 2), _cell(page, "x86/backend", 2)
    assert ok.text() == "PASS" and _colour(ok) == common.GREEN
    assert bad.text() == "FAIL" and _colour(bad) == common.RED
    assert _cell(page, "rpi5/pki", 3).text() == "12"      # assertions passed
    assert _cell(page, "x86/backend", 4).text() == "7"         # assertions failed


def test_qemu_table_shows_the_reconciled_state_of_a_live_row(wiz, registry, results):
    registry(_device("rpi5/pki", state="booting"))
    page = _qemu_page(wiz)
    page._reload_results()
    assert _cell(page, "rpi5/pki", 1).text() == emulation.STATE_BOOTING
    # a BOOTING row is not owed a verdict yet, and does not claim one
    assert _cell(page, "rpi5/pki", 2).text() == common.PENDING_TEXT


# ---- what LEFT this page ------------------------------------------------------------

def test_qemu_page_no_longer_carries_a_device_console(wiz):
    """The console moved to the mesh page IN THE SAME CHANGE that deleted it here —
    a merged commit must never leave QMP/save/shell homeless."""
    page = _qemu_page(wiz)
    for gone in ("devices", "devices_box", "dev_note", "devices_refresh_btn",
                 "devices_stop_all_btn", "_device_rows", "_device_job",
                 "_open_shell", "_device_qmp", "_device_save", "_stop_all_devices"):
        assert not hasattr(page, gone), f"{gone} is still on the TEST page"
    assert not hasattr(qemu_page, "_DeviceJob"), "the second spawn lane survived"


def test_qemu_page_has_no_keep_alive_control(wiz):
    """The tick promised that --jobs gated the keep-alive boots, which it does not,
    and it is the one thing that turned this page into a persistent-device console."""
    page = _qemu_page(wiz)
    assert not hasattr(page, "keep_alive")
    assert "--keep-alive" not in page.cmd_view.toPlainText()
    assert "keep" not in page.knobs.title().lower()


def test_qemu_page_points_at_the_mesh_page_for_persistent_devices(wiz):
    page = _qemu_page(wiz)
    assert "Persistent emulated devices live on the Mesh emulation page." \
        in page.console_pointer.text()
    assert page.console_pointer.isVisible()


def test_qemu_page_spawns_only_through_the_facade():
    """Every subprocess this page starts goes through ``emulation.spawn``.

    That is the single process boundary the tests replace; a second lane (the old
    ``_DeviceJob``, or a bare Popen) is invisible to every mock in this file and was
    how the two emulation screens came to kill devices differently.
    """
    src = inspect.getsource(qemu_page)
    assert "emulation.spawn(" in src
    assert "subprocess.Popen" not in src
    assert "QemuTestRunner" not in src, "the second runner lane survived"


def test_qemu_page_offers_no_modal_dialogs_at_all():
    """A QMessageBox/exec() in page logic hangs the headless tests, and every refusal
    here is a fact to read rather than a question to answer."""
    src = inspect.getsource(qemu_page)
    for forbidden in ("QMessageBox", ".exec()", "QDialog"):
        assert forbidden not in src, f"{forbidden} in page logic"


# ---- the SELinux AVC workout (issue #45) --------------------------------------------

def test_qemu_avc_button_runs_the_workout_over_ONE_planned_row(wiz, qapp,
                                                               fake_generator):
    _gen, full, _abort = fake_generator
    page = _qemu_page(wiz)
    labels = [page.avc_combo.itemData(i) for i in range(page.avc_combo.count())]
    assert labels == ["rpi5/pki", "x86/backend"]          # the plan's rows, in boot order
    page.avc_combo.setCurrentIndex(labels.index("x86/backend"))
    page.avc_btn.click()
    _finish(page, qapp)
    echoed = _echoed(page, "STUB-AVC")
    assert echoed, "the AVC workout stand-in never ran"
    assert "--platform x86" in echoed[0] and "--role backend" in echoed[0]
    assert f"-w {full}" in echoed[0]                 # pinned to THIS session


# ---- docker ---------------------------------------------------------------------------

def test_qemu_page_says_when_docker_is_missing(wiz, monkeypatch):
    monkeypatch.setattr(qemu_tests, "docker_available",
                        lambda: (False, "docker was not found on PATH."))
    page = _qemu_page(wiz)
    assert not page.run_btn.isEnabled() and not page.list_btn.isEnabled()
    assert "cannot run on this machine" in page.docker_note.text()


def test_qemu_docker_probe_is_not_the_fifteen_second_freeze(wiz, monkeypatch):
    """The old page called the SYNCHRONOUS probe inside initializePage, whose default
    wall clock is 15 seconds — a hung daemon froze the window before it painted."""
    seen = {}

    def slow():
        seen["called"] = True
        return True, "docker is available."

    monkeypatch.setattr(qemu_tests, "docker_available", slow)
    page = _qemu_page(wiz)
    assert seen.get("called"), "the probe never ran"
    assert page.docker_probe.answer == (True, "docker is available.")
    src = inspect.getsource(qemu_page)
    assert "docker_available()" not in src, "a synchronous probe crept back in"


# ---- "build first, then test": the chain, unchanged -----------------------------------

def test_qemu_use_existing_is_terminal_and_arms_nothing(wiz):
    page = _qemu_page(wiz)
    assert page.nextId() == -1 and page.isFinalPage()
    assert page.validatePage() is True
    assert wiz.cfg.qemu_device_tests is False   # "test what exists" must not arm the hook


def test_qemu_build_first_rejoins_the_image_flow_and_arms_the_hook(wiz):
    page = _qemu_page(wiz)
    page.build_first.setChecked(True)
    assert page.nextId() != -1                          # rejoins, not terminal
    assert not page.session_box.isVisible()             # picker is the other arm's
    assert not page.console_pointer.isVisible()         # so is the console pointer
    assert wiz.cfg.qemu_device_tests is False
    wiz.next()
    assert wiz.cfg.qemu_device_tests is True                     # armed on the way out
    assert not isinstance(wiz.currentPage(), wizard_mod.QemuPage)


_NEXT = QtWidgets.QWizard.WizardButton.NextButton
_FINISH = QtWidgets.QWizard.WizardButton.FinishButton


def test_qemu_build_first_makes_the_wizard_next_button_live(wiz, qapp):
    """Ticking the radio must put a REACHABLE Next in the button bar.

    This is the operator-visible bug and the reason the control read as ineffective:
    QWizard caches canContinue/canFinish in updateCurrentPage() when the page is
    ENTERED, and nothing re-runs it when a page's nextId() changes afterwards. The
    page arrives with "use existing" checked, so nextId() is -1 and the bar shows
    FINISH; ticking "build new images first" flips nextId() to a real page and
    flips isFinalPage() to False, but the bar keeps showing Finish with Next hidden
    and disabled. The only live button then ENDS the wizard.

    Asserted on the BUTTONS, not on nextId(): every existing test here drives the
    chain with wiz.next(), which bypasses the button bar entirely and passes while
    the operator's actual route is dead.
    """
    page = _qemu_page(wiz)
    qapp.processEvents()
    assert wiz.button(_FINISH).isVisible(), "the 'test what exists' arm is terminal"
    assert not wiz.button(_NEXT).isVisible()

    page.build_first.setChecked(True)
    qapp.processEvents()
    assert page.nextId() != -1                        # the flow agrees...
    nxt = wiz.button(_NEXT)
    assert nxt.isVisible() and nxt.isEnabled(), (
        "the radio rejoins the image flow but the button bar still offers no Next — "
        "the operator has no way to act on the choice they just made")
    assert not wiz.button(_FINISH).isVisible(), (
        "Finish is still offered on a page that is no longer final — pressing it "
        "ends the wizard instead of building anything")

    nxt.click()                                       # the REAL route, not wiz.next()
    qapp.processEvents()
    assert not isinstance(wiz.currentPage(), wizard_mod.QemuPage)
    assert wiz.cfg.qemu_device_tests is True

    back_to(wiz, wizard_mod.QemuPage)
    qapp.processEvents()
    page.use_existing.setChecked(True)
    qapp.processEvents()
    assert wiz.button(_FINISH).isVisible(), "going back to 'test what exists' re-arms Finish"
    assert not wiz.button(_NEXT).isVisible()


def test_qemu_build_first_arm_says_what_next_will_do(wiz):
    """The build-first arm must not render blank.

    _source_changed() hides cmd_view on this arm and then writes the one line that
    explains what happens next INTO cmd_view — so the explanation was set on a
    widget that had just been hidden. Everything else on the page is hidden too, so
    picking the radio made the page go empty with no feedback at all.
    """
    page = _qemu_page(wiz)
    page.build_first.setChecked(True)
    visible = [w for w in (page.chain_note, page.cmd_view, page.rows_label,
                           page.session_note)
               if w.isVisible() and _text_of(w).strip()]
    assert visible, "the build-first arm shows no text anywhere"
    said = " ".join(_text_of(w) for w in visible)
    assert "Next" in said, f"nothing tells the operator to press Next: {said!r}"


def test_qemu_no_session_guidance_is_visible_not_erased(wiz, monkeypatch, qapp):
    """With no bootable image the page must still say what to do — VISIBLY.

    _reload_sessions() wrote that guidance into rows_label and then checked
    build_first, whose toggled handler blanks rows_label and hides the group box it
    lives in. The operator with nothing to test therefore saw an empty page, and the
    text that did exist told them to "Choose 'Build new images first'" — a control
    that was already checked and, per the test above, could not be acted on.
    """
    monkeypatch.setattr(qemu_tests, "discover_sessions", lambda *_a, **_k: [])
    page = _qemu_page(wiz)
    qapp.processEvents()
    shown = " ".join(_text_of(w) for w in (page.source_note, page.chain_note,
                                           page.rows_label, page.cmd_view)
                     if w.isVisible())
    assert "bootable image" in shown, (
        "the no-image explanation is not visible anywhere on the page")
    assert "Next" in shown, "no route forward is offered"
    assert "Choose “Build new images first”" not in shown, (
        "still telling the operator to pick a radio that is already checked")


def test_qemu_page_without_sessions_forces_build_first(wiz, monkeypatch):
    monkeypatch.setattr(qemu_tests, "discover_sessions", lambda *_a, **_k: [])
    page = _qemu_page(wiz)
    assert not page.use_existing.isEnabled()
    assert page.build_first.isChecked()
    assert page.nextId() != -1


def test_build_qemu_device_tests_gate_follows_env(real_wiz):
    """The checkbox lives and dies with --env: greyed + unticked on prod (a prod
    image prunes the in-cluster test runner, so the assertions would target a stack
    the build removed on purpose), reversible on test — and never an argv token."""
    build = advance_to(real_wiz, wizard_mod.BuildPage)
    assert build.env.currentText() == "test"            # the builders' own default
    assert build.qemu_device_tests.isEnabled()
    build.qemu_device_tests.setChecked(True)
    build.env.setCurrentText("prod")
    assert not build.qemu_device_tests.isEnabled()
    assert not build.qemu_device_tests.isChecked()               # prod may not carry the flag
    assert "prod" in build.qemu_device_tests.toolTip()           # the WHY is on the widget
    build.env.setCurrentText("test")
    assert build.qemu_device_tests.isEnabled()                   # reversible, not destroyed
    build.qemu_device_tests.setChecked(True)
    build._preview()
    assert real_wiz.cfg.qemu_device_tests is True
    assert not any("qemu" in a.lower() for a in real_wiz.cfg.to_cli_args())


def test_build_qemu_device_tests_collect_reenforces_the_env_gate(real_wiz):
    """Belt and braces: even a programmatic check while prod is selected (the greyed
    widget still accepts setChecked) must not let a prod config carry the flag."""
    build = advance_to(real_wiz, wizard_mod.BuildPage)
    build.env.setCurrentText("prod")
    build.qemu_device_tests.setChecked(True)                     # bypasses the greyed gate
    build._preview()
    assert real_wiz.cfg.qemu_device_tests is False


def test_qemu_opt_out_on_buildpage_survives_a_page_revisit(real_wiz):
    """Unticking the BuildPage checkbox must STAY unticked across a page revisit.

    This is the operator-visible bug and it is the PRIMARY forward route, not an
    exotic one. QemuPage.validatePage() only ever SETS cfg.qemu_device_tests True, and
    BuildPage.initializePage() calls wiz.collect_all(), which re-runs the
    validatePage of every VISITED page. QemuPage is still visited on this route, so
    it re-arms the flag the operator just cleared, and build.py:888 re-ticks the
    checkbox from it — the post-build device tests then run after an explicit opt-out.

    Driven through the UI only. A test that calls validatePage() directly pins the
    mechanism and passes while this route stays broken.
    """
    qp = _qemu_page(real_wiz)
    qp.build_first.setChecked(True)
    real_wiz.next()
    assert real_wiz.cfg.qemu_device_tests is True, "build-first should arm the hook"

    build = advance_to(real_wiz, wizard_mod.BuildPage)
    build.env.setCurrentText("test")          # the checkbox is gated on --env test
    build.qemu_device_tests.setChecked(False)          # the operator opts OUT
    build._preview()
    assert real_wiz.cfg.qemu_device_tests is False, "unticking must clear the flag"

    real_wiz.back()                           # leave BuildPage...
    real_wiz.next()                           # ...and walk straight back into it

    page = real_wiz.currentPage()
    assert isinstance(page, wizard_mod.BuildPage), \
        f"expected to land back on BuildPage, got {type(page).__name__}"
    assert real_wiz.cfg.qemu_device_tests is False, (
        "revisiting BuildPage re-armed qemu_device_tests — the operator's opt-out was "
        "reverted, so the post-build device tests would run anyway")
    assert build.qemu_device_tests.isChecked() is False, "the checkbox re-ticked itself"


# ---- ProgressPage: the post-build hook ----------------------------------------------

def test_progress_runs_the_device_tests_after_an_all_ok_build(wiz, fake_generator,
                                                              qapp):
    _gen, full, _abort = fake_generator
    prog = wiz.page(wiz._page_ids["progress"])
    wiz.cfg.qemu_device_tests = True
    prog._session = SimpleNamespace(workdir=str(full))
    prog._maybe_qemu_tests()
    assert prog.qemu_worker is not None
    assert prog.qemu_worker.wait(15000)
    qapp.processEvents()                                # deliver the queued signals
    log = prog.log.toPlainText()
    assert "STUB-RUNNER" in log
    assert f"--artifacts {full}" in log                 # tests THIS build's images
    assert "=== QEMU device tests passed ===" in log


def test_progress_skips_the_device_tests_without_the_opt_in(wiz):
    prog = wiz.page(wiz._page_ids["progress"])
    wiz.cfg.qemu_device_tests = False
    prog._session = SimpleNamespace(workdir="/nowhere")
    prog._maybe_qemu_tests()
    assert prog.qemu_worker is None


# ---- the Playwright browser suite over an emulated device (ask 4) ---------------------
#
# CHECKED-NOTHING PASS NOTE, and it is the whole design of this section: asserting that the widgets
# EXIST proves nothing — tests/qemu/run-qemu-e2e.sh had worked for months with no door
# in the Studio, and a door that spawns the wrong script is worse than none. Every
# assertion below reads the argv a CHILD PROCESS received (the stub echoes its own
# "$*"), exactly as the device-test lane's assertions do.

def _pw_echoed(page):
    """The joined "$*" line(s) — readable, but blind to word splitting."""
    return [ln for ln in page.log.toPlainText().splitlines()
            if ln.startswith("STUB-QEMU-E2E ")]


def _pw_argv(page):
    """The argv as a LIST, one entry per argument the child really received."""
    marker = "STUB-QEMU-E2E-ARG "
    return [ln[len(marker):] for ln in page.log.toPlainText().splitlines()
            if ln.startswith(marker)]


def test_qemu_playwright_row_picker_offers_only_launchable_rows(wiz, fake_generator):
    """run-qemu-e2e.sh wires launch-x86.sh and launch-pi.sh and REJECTS any other
    --target, so a row it cannot boot must not be offered.

    The session is given a JETSON row for this test — without one the filter is
    untestable, and a mutation that dropped it entirely survived the earlier version
    of this assertion because every fixture row happened to be launchable.
    """
    _gen, full, _abort = fake_generator
    (full / "hugmesh-jetson-arm64-edge_ai-test-20260807T180000Z.img").write_bytes(b"\0")  # non-empty: a 0-byte .img is a killed build, not a row
    page = _qemu_page(wiz)
    page._reload_sessions()
    assert "jetson/edge-ai" in page.plan.labels, "the fixture row was not planned"
    labels = [page.pw_row.itemData(i) for i in range(page.pw_row.count())]
    assert labels == ["rpi5/pki", "x86/backend"], labels
    assert "jetson/edge-ai" not in labels
    # ...and the device-test lane, which CAN boot it, still offers it
    avc = [page.avc_combo.itemData(i) for i in range(page.avc_combo.count())]
    assert "jetson/edge-ai" in avc


def test_qemu_playwright_list_button_runs_the_e2e_script_not_the_docker_runner(
        wiz, qapp, fake_generator):
    """THE naming test. If the envelope were aimed at run-qemu-docker.sh — the
    confusion cfg.qemu_e2e's name caused for months — the child would echo
    STUB-RUNNER and this fails."""
    _gen, full, _abort = fake_generator
    page = _qemu_page(wiz)
    labels = [page.pw_row.itemData(i) for i in range(page.pw_row.count())]
    page.pw_row.setCurrentIndex(labels.index("x86/backend"))
    page.pw_list_btn.click()
    _finish(page, qapp)
    echoed = _pw_echoed(page)
    assert echoed, ("nothing echoed by run-qemu-e2e.sh — the page spawned some other "
                    f"script; log was: {page.log.toPlainText()!r}")
    assert not _echoed(page, "STUB-RUNNER"), "the DOCKER runner was spawned instead"
    line = echoed[0]
    assert "--target x86" in line and "--role backend" in line
    assert f"-w {full}" in line                     # pinned to THIS session
    assert "--list" in line                          # the enumerate verb, not a boot


def test_qemu_playwright_list_carries_the_ports_and_the_spec_filter(wiz, qapp):
    """The ports and the passthrough travel through the OPTIONS/ENVELOPE, so what
    the preview shows and what the child gets are one value."""
    page = _qemu_page(wiz)
    page.pw_ui_port.setValue(9443)
    page.pw_ssh_port.setValue(2299)
    page.pw_args.setText("--grep @smoke")
    page.pw_list_btn.click()
    _finish(page, qapp)
    argv = _pw_argv(page)
    assert argv[argv.index("--ui-port") + 1] == "9443"
    assert argv[argv.index("--ssh-port") + 1] == "2299"
    # The passthrough arrives behind the script's own separator as TWO SEPARATE
    # arguments. Asserted on the LIST: the joined "$*" form reads identically
    # whether they were split or handed over as one string, which is exactly the
    # quoting regression the Makefile's E2E_ARGS passthrough documents.
    assert argv[-3:] == ["--", "--grep", "@smoke"], argv


def test_qemu_playwright_preview_is_a_dry_run_and_never_a_boot(wiz, qapp):
    page = _qemu_page(wiz)
    page.pw_preview_btn.click()
    _finish(page, qapp)
    line = _pw_echoed(page)[0]
    assert "--dry-run" in line and "--list" not in line


def test_qemu_playwright_run_refuses_without_root_and_spawns_nothing(wiz):
    """The Studio must never reach for sudo. The refusal is stated BEFORE the spawn,
    inline (no modal), and names the containerized route."""
    if os.geteuid() == 0:
        pytest.skip("running as root: the non-root refusal cannot be exercised here")
    page = _qemu_page(wiz)
    assert not page.pw_run_btn.isEnabled(), "the Run button was live without root"
    assert "--privileged" in page.pw_note.text()
    assert "hugmesh-qemu-runner" in page.pw_note.text()
    # ...and forcing the click anyway still spawns nothing
    page._launch_playwright(list_only=False)
    assert page.worker is None
    assert not _pw_echoed(page)
    assert "refused" in page.log.toPlainText()
    # the non-root verbs stay live
    assert page.pw_list_btn.isEnabled() and page.pw_preview_btn.isEnabled()


def test_qemu_playwright_real_run_argv_when_root_is_available(wiz, qapp, monkeypatch,
                                                              fake_generator):
    """The BOOT argv, asserted on the child — with the root gate stubbed open at its
    one named override point (emulation.playwright_root_blocker) rather than by acquiring root,
    which this box cannot and must not do."""
    _gen, full, _abort = fake_generator
    monkeypatch.setattr(qemu_page.emulation, "playwright_root_blocker", lambda: "")
    page = _qemu_page(wiz)
    labels = [page.pw_row.itemData(i) for i in range(page.pw_row.count())]
    page.pw_row.setCurrentIndex(labels.index("rpi5/pki"))
    page.pw_args.setText("specs/01-frontpage.spec.ts")
    assert page.pw_run_btn.isEnabled()
    page.pw_run_btn.click()
    _finish(page, qapp)
    line = _pw_echoed(page)[0]
    assert "--target pi" in line and "--role pki" in line      # derived from the row
    assert f"-w {full}" in line
    assert "--list" not in line and "--dry-run" not in line    # a REAL run
    assert _pw_argv(page)[-2:] == ["--", "specs/01-frontpage.spec.ts"]
    # every port/size flag rides even at its default (run-qemu-e2e.sh reads those
    # defaults from the ENVIRONMENT, so omitting one is not the same as passing it)
    for flag in ("--ssh-port", "--ui-port", "--ssh-user", "--mem", "--smp",
                 "--accel", "--timeout", "--ui-timeout"):
        assert flag in line, f"{flag} missing from the boot argv"


def test_qemu_playwright_preview_matches_what_the_child_receives(wiz, qapp):
    """The printed command is the spawned command. A preview that can drift from the
    run is the failure mode the Run-envelope box's own docstring exists to prevent."""
    page = _qemu_page(wiz)
    page.pw_args.setText("--grep @smoke")
    preview = page.pw_cmd_view.toPlainText()
    assert preview.endswith("-- --grep @smoke"), preview
    page.pw_list_btn.click()
    _finish(page, qapp)
    # Compared as LISTS: the preview is shlex-quoted, so a shell-split of it is the
    # argv it promises. The button's own --list verb is the only allowed difference.
    got = [a for a in _pw_argv(page) if a != "--list"]
    assert shlex.split(preview)[1:] == got, (preview, got)


def test_qemu_playwright_group_belongs_to_the_use_existing_arm(wiz):
    page = _qemu_page(wiz)
    assert page.pw_group.isVisible()
    page.build_first.setChecked(True)
    assert not page.pw_group.isVisible()


def test_qemu_playwright_group_names_its_own_script(wiz):
    """The rename, on the WIDGET an operator reads. Three harnesses in this tree are
    called "e2e"; the group title must say WHICH."""
    page = _qemu_page(wiz)
    assert "run-qemu-e2e.sh" in page.pw_group.title()
    assert "Playwright" in page.pw_group.title()


def test_build_checkbox_names_the_assertion_lane_not_the_browser_one(real_wiz):
    """The other half of the naming defect: BuildPage's post-build opt-in drives
    run-qemu-docker.sh's IN-GUEST assertions, and its label used to read as a promise
    to run the browser suite (the field was called cfg.qemu_e2e, which is the OTHER
    script's name)."""
    build = advance_to(real_wiz, wizard_mod.BuildPage)
    label = build.qemu_device_tests.text()
    assert "run-qemu-docker.sh" in label, label
    assert "assertions" in label.lower(), label
    assert "playwright" not in label.lower(), label
    assert "playwright" not in build.qemu_device_tests.toolTip().lower() or (
        "not the Playwright" in build.qemu_device_tests.toolTip())


# ══════════════════════════════════════════════════════════════════════════════════
# THE RUNNING-MESH MONITOR ON THIS PAGE (#336, umbrella #333 item 4)
#
# The operator asked for the pod table on the emulation screen too. It reads a
# DIFFERENT mesh from the results table above it — the docker compose project and the
# kind cluster on THIS workstation, not the emulated guests this page boots — and the
# tests below pin the three things that made that safe on the local-mesh page (PR
# #291) plus the one thing that is specific to a second mount: it must not offer a
# second `make view` launcher.
#
# Written after a refutation found ~1000 new lines with no test at all, and a
# 13-mutation battery in which every mutation survived. M9 — deleting
# hide_view_controls — is killed by test_this_page_offers_no_second_make_view_launcher.
# ══════════════════════════════════════════════════════════════════════════════════

def test_the_monitor_is_mounted_collapsed_greyed_and_starts_no_shell(wiz):
    """Mounting it must start NOTHING: no probe, no timer, no shell. The section is
    two shell round trips per tick and this page is reached by operators who only
    want the test results above it."""
    page = _qemu_page(wiz)
    sec = page.monitor
    assert sec.monitor.scaling is True
    assert sec.monitor.table.columnCount() == 7
    assert sec.monitor.table.horizontalHeaderItem(6).text() == "Replicas"
    assert not sec.section.is_expanded()
    assert not sec.monitor.isEnabled()
    assert not sec.timer.isActive()
    assert getattr(sec, "_probe", None) is None, "mounting the monitor started a probe"
    assert getattr(sec, "_scale_worker", None) is None


def test_this_page_offers_no_second_make_view_launcher(wiz):
    """M9. `make view` binds loopback ports behind ONE session-owner guard and the
    local-mesh page owns that session. A second launcher here fights it for one
    session lock — and a disabled button with an explanation is still a button an
    operator presses, so it is hidden and the reason is on it."""
    page = _qemu_page(wiz)
    w = page.monitor.monitor
    assert not w.view_up_btn.isVisibleTo(w)
    assert not w.view_down_btn.isVisibleTo(w)
    assert "local-mesh page" in w.view_up_btn.toolTip()
    assert "session lock" in w.view_down_btn.toolTip()
    # the controls that DO belong to a read-only second mount are still there
    assert w.refresh_btn.isVisibleTo(w) and w.copy_btn.isVisibleTo(w)


def test_the_monitor_says_it_is_not_the_results_table_above_it(wiz):
    page = _qemu_page(wiz)
    note = page.monitor.monitor.note.text()
    assert "not the emulated guests in the table above" in note
    assert "docker compose project and the kind cluster" in note


def test_the_monitor_node_is_built_once_and_is_a_plain_local_stack_node(wiz):
    """The monitor only READS both lanes, and this page has no local-mesh
    configuration to thread in — the compose file and the ports are the Makefile's,
    which is what the running mesh was started with."""
    page = _qemu_page(wiz)
    first = page._monitor_node()
    assert isinstance(first, qemu_page.LocalStackNode)
    assert page._monitor_node() is first, "a node per tick is a node per 10 seconds"


def test_hiding_and_leaving_the_page_stop_the_monitors_clock(wiz, qapp):
    page = _qemu_page(wiz)
    page.monitor.section.toggle.setChecked(True)
    qapp.processEvents()
    assert page.monitor.timer.isActive()
    page.hide()
    qapp.processEvents()
    assert not page.monitor.timer.isActive()
    page.show()
    qapp.processEvents()
    page.monitor.timer.start()
    page.cleanupPage()
    assert not page.monitor.timer.isActive()


def test_the_monitor_reaches_no_modal_from_page_logic(wiz):
    """The standing rule, over the code #336 added to this page."""
    import re
    src = inspect.getsource(qemu_page)
    for name in ("validatePage", "isComplete", "initializePage", "cleanupPage",
                 "hideEvent", "showEvent", "_monitor_node"):
        m = re.search(rf"\n    def {name}\b.*?(?=\n    def |\nclass |\Z)", src, re.S)
        if m:
            assert "QMessageBox" not in m.group(0), name
            assert ".exec(" not in m.group(0), name
