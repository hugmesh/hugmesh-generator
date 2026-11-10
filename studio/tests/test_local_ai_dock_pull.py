"""The Studio panel when the chosen Ollama has no model: the Download offer, its
progress, Cancel, failures, and the question asked again once the model is in.

A real :class:`StudioShell` opens a real wizard offscreen at the smallest window the
Studio supports (942x552); the snapshot, the prompt, the pull and the free-space read are
fakes, so nothing here reaches an Ollama on the test host. Each state is rendered and
its geometry asserted: the Download button, the progress bar and Cancel are inside the
panel and the window, tall enough to click, and clear of the wizard's own buttons. Set
``LOCAL_AI_DOCK_GRABS=<dir>`` to keep the screenshots.
"""
import os
import threading

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import local_ai_models as lam                 # noqa: E402
from hugmesh_studio.core import local_ai_status as lai                 # noqa: E402
from hugmesh_studio.core import ollama_docker as odk                   # noqa: E402
from hugmesh_studio.gui import _local_ai_dock as dock_mod              # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.qt import QtCore                               # noqa: E402
from test_local_ai_dock import (GENERATOR_DIR, HOST, NORMAL, SMALLEST, button_rects,  # noqa: E402,F401
                                make_snapshot, open_at, qapp, rect_in, shell, wait_for)

FREE = 120_300_000_000


def empty_snapshot(docker=False):
    """What a fresh Ollama with no model reads as (read_snapshot + adjust_snapshot)."""
    env = {"OLLAMA_HOST": odk.endpoint(odk.DOCKER) if docker else "127.0.0.1:11434"}
    snap = make_snapshot(models=[], loaded=[], worker="stopped", worker_pid=0,
                         counts={"pending": 0, "running": 0, "stalled": 0, "done": 0,
                                 "drafts": 0, "builds": 0})
    snap.jobs = []
    snap.problem = ("The Docker Ollama is running but no model is pulled into it." if docker
                    else "Ollama is running but no model is pulled.")
    snap.offer = lam.offer_for(env)
    snap.fix = lam.fix_words(snap.offer, "cli", env)
    snap.summary = lai.summary_line(snap)
    return snap


@pytest.fixture(autouse=True)
def _pinned(monkeypatch, tmp_path):
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": HOST)
    monkeypatch.setattr(lai, "read_snapshot", lambda *a, **k: empty_snapshot())
    monkeypatch.setattr(lai, "send_prompt",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("real model called")))
    monkeypatch.setattr(lai, "start_assistant",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("real start called")))
    monkeypatch.setattr(lam, "pull",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("real pull called")))
    monkeypatch.setattr(lam, "free_bytes", lambda env=None, **k: FREE)
    monkeypatch.setattr(odk, "state", lambda runner=None: odk.DockerState(True, True, True))
    monkeypatch.setattr(odk, "detect_gpu", lambda runner=None, **k: odk.GpuChoice(
        "cpu", (), odk.IMAGE, "CPU only: Docker has no GPU runtime. Answers will be slower."))
    monkeypatch.setenv("HUGMESH_LOCAL_AI_DIR", str(tmp_path / "localai"))


def grab(wiz, name, tmp_path):
    img = wiz.grab()
    path = tmp_path / f"{name}.png"
    assert img.save(str(path)) and path.stat().st_size > 5000
    keep = os.environ.get("LOCAL_AI_DOCK_GRABS")
    if keep:
        os.makedirs(keep, exist_ok=True)
        img.save(os.path.join(keep, f"{name}.png"))


def assert_drawn_whole(wiz, dock, *widgets):
    window = QtCore.QRect(QtCore.QPoint(0, 0), wiz.size())
    d = rect_in(wiz, dock)
    assert window.contains(d), f"the dock {d} leaves the window"
    assert not any(d.intersects(b) for b in button_rects(wiz)), "the dock covers a wizard button"
    for w in widgets:
        r = rect_in(wiz, w)
        assert w.isVisible(), w.objectName() or type(w).__name__
        assert r.height() >= 26 and r.width() >= w.minimumSizeHint().width() - 1, (w, r)
        assert d.contains(r), f"{type(w).__name__} {r} is outside the dock {d}"


def docked(shell, qapp, size=SMALLEST):
    wiz = open_at(shell, qapp, size)
    dock = wiz.local_ai_dock
    dock.set_expanded(True)
    dock.show_tab("assistant")
    assert wait_for(qapp, lambda: dock.snapshot is not None and not dock.offer_row.isHidden())
    assert wait_for(qapp, lambda: dock._free is not None)
    for _ in range(3):
        qapp.processEvents()
    return wiz, dock


class ControlledPull:
    """A pull that reports progress and then waits for the test to let it finish."""

    def __init__(self, result=None):
        self.release = threading.Event()
        self.calls = []
        self.result = result

    def __call__(self, model, env, on_progress=None, should_stop=None):
        self.calls.append((model, env.get("OLLAMA_HOST")))
        on_progress(lam.PullProgress("pulling manifest"))
        on_progress(lam.PullProgress("pulling aaa", 512_000_000, lam.size_of(model) or 10 ** 9))
        while not self.release.wait(0.02):
            if should_stop():
                return lam.PullResult(False, model, f"Stopped downloading {model}. What arrived "
                                      "is kept; the next download resumes.", True)
        return self.result or lam.PullResult(True, model, f"{model} is downloaded and ready.")


# ── the offer ────────────────────────────────────────────────────────────────────────
def test_no_model_shows_a_download_button_with_the_size_and_the_free_space(shell, qapp, tmp_path):
    wiz, dock = docked(shell, qapp)
    assert dock.pull_btn.text() == "Download qwen3:1.7b (1.4 GB, 120.3 GB free)"
    assert dock.pull_other.isVisible() and not dock.pull_bar.isVisible()
    note = dock.note.text()
    assert "no model is pulled" in note and "Press Download below to fetch qwen3:1.7b" in note
    assert "by hand: ollama pull qwen3:1.7b" in note
    assert dock.summary.full_text() == "Local AI: no model pulled, no model loaded, idle"
    assert_drawn_whole(wiz, dock, dock.pull_btn, dock.pull_other, dock.prompt, dock.send_btn)
    assert not rect_in(wiz, dock.pull_btn).intersects(rect_in(wiz, dock.note))
    grab(wiz, "pull-1-offer-system", tmp_path)


def test_in_docker_mode_the_offer_names_the_container(shell, qapp, tmp_path, monkeypatch):
    odk.set_mode(odk.DOCKER)
    monkeypatch.setattr(lai, "read_snapshot", lambda *a, **k: empty_snapshot(docker=True))
    wiz, dock = docked(shell, qapp)
    note = dock.note.text()
    assert "Docker Ollama is running but no model is pulled into it" in note
    assert "by hand: docker exec hugmesh-studio-ollama ollama pull qwen3:1.7b" in note
    assert "; by hand: ollama pull" not in note
    assert dock.summary.full_text().startswith("Local AI (Docker): no model pulled")
    assert "docker exec hugmesh-studio-ollama ollama pull qwen3:1.7b" in dock.docker_label.text()
    assert_drawn_whole(wiz, dock, dock.pull_btn, dock.pull_other)
    grab(wiz, "pull-2-offer-docker", tmp_path)


def test_other_model_lists_every_choice_with_its_size(shell, qapp):
    _wiz, dock = docked(shell, qapp)
    texts = [a.text() for a in dock.pull_other.menu().actions()]
    assert texts[0].startswith("qwen3:1.7b (1.4 GB)") and texts[1].startswith("qwen3:0.6b (523 MB)")
    assert texts[2].startswith("qwen3:8b (5.2 GB)")


# ── the download ─────────────────────────────────────────────────────────────────────
def test_download_shows_progress_and_cancel_then_asks_the_question_again(shell, qapp, tmp_path,
                                                                          monkeypatch):
    asked = []
    models = {"pulled": False}

    def prompt_fn(text, history, on_chunk, should_stop):
        asked.append(text)
        if not models["pulled"]:
            raise lam.NoModel("", {"OLLAMA_HOST": "127.0.0.1:11434"})
        on_chunk("A brand is the look of a domain.")
        return "A brand is the look of a domain."
    wiz, dock = docked(shell, qapp)
    dock._prompt_fn = prompt_fn
    pull = ControlledPull()
    dock._pull_fn = pull
    dock.prompt.setText("what is a brand?")
    assert dock.send()
    assert wait_for(qapp, lambda: not dock._busy)
    answer = dock.answer.toPlainText()
    assert "No model is pulled" in answer and "Press Download below" in answer
    assert dock._pending_question == "what is a brand?"

    dock.pull_btn.click()
    assert wait_for(qapp, lambda: dock.pull_bar.value() > 0)
    assert [c[0] for c in pull.calls] == ["qwen3:1.7b"]
    assert dock.pull_bar.isVisible() and dock.pull_cancel.isVisible()
    assert not dock.pull_btn.isVisible() and not dock.send_btn.isEnabled()
    assert dock.pull_bar.format() == "qwen3:1.7b: pulling 37% (512/1359 MB)"
    assert "Downloading qwen3:1.7b (1.4 GB) into the Ollama on" in dock.note.text()
    assert_drawn_whole(wiz, dock, dock.pull_bar, dock.pull_cancel, dock.prompt)
    grab(wiz, "pull-3-downloading", tmp_path)
    # a question typed during the download waits for it
    dock.prompt.setText("what is a brand?")
    assert not dock.send() and "still downloading" in dock.note.text()

    models["pulled"] = True
    monkeypatch.setattr(lai, "read_snapshot", lambda *a, **k: make_snapshot(
        models=["qwen3:1.7b"], loaded=["qwen3:1.7b"]))
    pull.release.set()
    assert wait_for(qapp, lambda: "A brand is the look of a domain." in dock.answer.toPlainText())
    assert asked == ["what is a brand?", "what is a brand?"]
    assert wait_for(qapp, lambda: dock.offer_row.isHidden())
    assert dock.send_btn.isEnabled()
    grab(wiz, "pull-4-ready-and-answered", tmp_path)


def test_cancel_stops_the_download_and_the_offer_comes_back(shell, qapp, tmp_path):
    wiz, dock = docked(shell, qapp)
    pull = ControlledPull()
    dock._pull_fn = pull
    dock.start_pull("qwen3:0.6b")
    assert wait_for(qapp, lambda: dock.pull_bar.value() > 0)
    dock.pull_cancel.click()
    assert dock.pull_cancel.text() == "Stopping…"
    assert wait_for(qapp, lambda: not dock._pulling)
    assert "Stopped downloading qwen3:0.6b" in dock.note.text()
    assert dock.pull_btn.isVisible() and not dock.pull_bar.isVisible()
    assert dock._message_warn is False                    # a cancel is not a failure
    grab(wiz, "pull-5-cancelled", tmp_path)


def test_a_failed_download_says_why_and_offers_again(shell, qapp, tmp_path):
    wiz, dock = docked(shell, qapp)
    pull = ControlledPull(lam.PullResult(False, "qwen3:1.7b", "This Ollama is too old for "
                                         "qwen3:1.7b (Ollama said: 412). Update it."))
    pull.release.set()
    dock._pull_fn = pull
    dock.pull_btn.click()
    assert wait_for(qapp, lambda: not dock._pulling)
    assert "too old for qwen3:1.7b" in dock.note.text()
    assert dock.pull_btn.isVisible() and dock.send_btn.isEnabled()
    grab(wiz, "pull-6-failed", tmp_path)


def test_a_download_that_will_not_fit_is_refused_before_it_starts(shell, qapp):
    _wiz, dock = docked(shell, qapp)
    pull = ControlledPull()
    dock._pull_fn = pull
    dock._free_fn = lambda env: 1_500_000_000
    dock.start_pull()
    assert wait_for(qapp, lambda: not dock._pulling)
    assert pull.calls == [] and "Not enough free space" in dock.note.text()


def test_the_agent_card_has_the_same_download(shell, qapp):
    from hugmesh_studio.core import local_agent as la
    _wiz, dock = docked(shell, qapp, NORMAL)
    card = dock.agent_card
    card.probe = la.Probe(ollama_path="/usr/bin/ollama", server_up=True, agents={"claude": "/c"})
    card._sync()
    assert card.problems()[0].code == "no_models"
    assert not card.download_btn.isHidden() and "qwen3:1.7b" in card.download_btn.text()
    assert "Download qwen3:1.7b (1.4 GB) on this card or in the chat" in card.status.text()
    pull = ControlledPull()
    dock._pull_fn = pull
    card.download_btn.click()
    assert wait_for(qapp, lambda: pull.calls)
    assert pull.calls[0][0] == "qwen3:1.7b" and dock._pulling
    assert card.download_btn.isHidden()                       # one download at a time
    pull.release.set()
    assert wait_for(qapp, lambda: not dock._pulling)


def test_the_real_pull_through_the_panel_against_a_loopback_fake(qapp, monkeypatch):
    """No fakes between the button and the HTTP stream: the panel's default pull talks
    to a FakeOllama on 127.0.0.1 and the model it adds is then in its list."""
    from _local_ai_fake import FakeOllama
    fake = FakeOllama()
    fake.models = []
    try:
        monkeypatch.setenv("OLLAMA_HOST", fake.host)
        # lam.pull is pinned to fail in this file; its body (_pull) is the real stream
        dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=empty_snapshot, auto_poll=False,
                                    expanded=True, agent_card=False,
                                    pull_fn=lambda m, e, **k: lam._ended(lam._pull(m, e, **k)),
                                    free_fn=lambda env: FREE)
        dock.show()
        dock.refresh()
        assert wait_for(qapp, lambda: not dock.offer_row.isHidden())
        dock.pull_btn.click()
        assert wait_for(qapp, lambda: not dock._pulling, 10)
        assert {"name": "qwen3:1.7b"} in fake.models
        assert "qwen3:1.7b is downloaded and ready." in dock.note.text()
        assert lam.saved_choice() == "qwen3:1.7b"
        dock.close()
    finally:
        fake.close()


def test_an_offer_for_a_named_model_stays_until_that_model_is_in(shell, qapp, monkeypatch):
    """LOCAL_AI_MODEL=qwen3:8b with only qwen3:1.7b pulled: the 404 offer must not
    vanish at the next poll just because SOME model is pulled."""
    def prompt_fn(text, history, on_chunk, should_stop):
        raise lam.NoModel("qwen3:8b", {"OLLAMA_HOST": "127.0.0.1:11434"}, gone=True)
    _wiz, dock = docked(shell, qapp)
    dock._prompt_fn = prompt_fn
    monkeypatch.setattr(lai, "read_snapshot", lambda *a, **k: make_snapshot(
        models=["qwen3:1.7b"], loaded=[]))
    dock.prompt.setText("hi")
    assert dock.send()
    assert wait_for(qapp, lambda: not dock._busy and dock._error_offer)
    dock.refresh()
    assert wait_for(qapp, lambda: dock.snapshot is not None and dock.snapshot.models == ["qwen3:1.7b"])
    qapp.processEvents()
    assert not dock.offer_row.isHidden() and dock.pull_btn.text().startswith("Download qwen3:8b (5.2 GB")
    monkeypatch.setattr(lai, "read_snapshot", lambda *a, **k: make_snapshot(
        models=["qwen3:1.7b", "qwen3:8b"], loaded=[]))
    dock.refresh()
    assert wait_for(qapp, lambda: dock.offer_row.isHidden())


# ── the status line follows the problem (round 2 of #933) ────────────────────────────
def test_docker_mode_down_status_line_names_the_docker_ollama_not_a_missing_install(
        shell, qapp, tmp_path, monkeypatch):
    """Docker mode, the container not started, no ``ollama`` on this machine: what
    read_snapshot says ("not installed") is rewritten by adjust_snapshot, and the status
    line on the strip must say the same as the note under it."""
    odk.set_mode(odk.DOCKER)
    monkeypatch.delenv(odk.PORT_ENV, raising=False)
    down = make_snapshot(ollama_installed=False, ollama_up=False, models=[], loaded=[],
                         worker="stopped", worker_pid=0, counts={})
    down.jobs = []
    down.problem = "Ollama is not installed on this machine."
    down.fix = "Install it (see the link), then run: scripts/local-ai.sh up"
    down.summary = lai.summary_line(down)
    assert down.summary == "Local AI: Ollama is not installed on this machine"
    monkeypatch.setattr(lai, "read_snapshot", lambda *a, **k: down)
    wiz = open_at(shell, qapp, SMALLEST)
    dock = wiz.local_ai_dock
    dock.set_expanded(True)
    dock.show_tab("assistant")
    assert wait_for(qapp, lambda: dock.snapshot is not None)
    for _ in range(3):
        qapp.processEvents()
    said = dock.summary.full_text()
    assert "not installed" not in said, said
    assert "Docker Ollama is not answering on 127.0.0.1:11435" in said, said
    assert "Docker Ollama is not answering on 127.0.0.1:11435" in dock.note.text()
    assert_drawn_whole(wiz, dock, dock.prompt)
    grab(wiz, "down-docker-status-line", tmp_path)
