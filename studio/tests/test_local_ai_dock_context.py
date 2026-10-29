"""The dock knows where the person is, shows a tip, and offers cards — GUI, offscreen.

Pins: the page hook covers every wizard page by slug; the tip label is in the collapsed
bar at MIN_CLICK_PX with bar_height() unchanged from origin/main (35); the hide button
persists; PNGs of the collapsed and expanded bar on welcome / domain_services /
localmesh at 1280x800 and 1024x700 land in tmp_path with the tip visible, elided and
not overlapping a button; a fake prompt returning a ```change block over a real
domain-services page makes a proposal card whose Apply / Undo go through the page; a
late tip for an old page is dropped; nothing opens a modal; a 2 s sleeping collector
inside send() does not stall a 100 ms timer on the window thread.
"""
import os
import threading
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")

from hugmesh_studio.core import assistant_actions as aa                           # noqa: E402
from hugmesh_studio.core import assistant_context as actxt                        # noqa: E402
from hugmesh_studio.core import assistant_settings                                # noqa: E402
from hugmesh_studio.core import assistant_tips as atips                           # noqa: E402
from hugmesh_studio.core import local_ai_status as lai                            # noqa: E402
from hugmesh_studio.core.config import Domain                                     # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                            # noqa: E402
from hugmesh_studio.gui import _local_ai_dock as dock_mod                         # noqa: E402
from hugmesh_studio.gui import shell as shell_mod                                 # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                               # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                               # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True, has_kvm=False,
                is_root=False, builder_image="hugmesh-builder")
BAR_HEIGHT_ON_MAIN = 35
SIZES = ((1280, 800), (1024, 700))


def make_snapshot(**kw):
    snap = lai.Snapshot(models=["qwen3:8b"], loaded=["qwen3:8b"], ollama_up=True, host="127.0.0.1:11434")
    for k, v in kw.items():
        setattr(snap, k, v)
    snap.summary = lai.summary_line(snap)
    return snap


@pytest.fixture(scope="session")
def qapp():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"])


@pytest.fixture(autouse=True)
def _pinned(monkeypatch, tmp_path):
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": HOST)
    monkeypatch.setattr(lai, "read_snapshot", lambda *a, **k: make_snapshot())
    monkeypatch.setattr(lai, "send_prompt",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("real model called")))
    monkeypatch.setattr(lai, "start_assistant",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("real start called")))
    monkeypatch.setenv("HUGMESH_LOCAL_AI_DIR", str(tmp_path / "localai"))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    for name in ("information", "warning", "critical", "question", "about"):
        monkeypatch.setattr(QtWidgets.QMessageBox, name,
                            staticmethod(lambda *a, **k: (_ for _ in ()).throw(AssertionError("modal"))))
    monkeypatch.setattr(QtWidgets.QDialog, "exec", lambda *a, **k: (_ for _ in ()).throw(AssertionError("modal")))


@pytest.fixture
def shell(qapp):
    sh = shell_mod.StudioShell(GENERATOR_DIR)
    yield sh
    for w in list(sh.windows):
        try:
            w.close()
            w.deleteLater()
        except RuntimeError:
            pass
    qapp.processEvents()


def pump(qapp, n=6):
    for _ in range(n):
        qapp.processEvents()
        time.sleep(0.01)


def wait_for(qapp, cond, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        qapp.processEvents()
        if cond():
            return True
        time.sleep(0.02)
    return cond()


def open_at(shell, qapp, size=(1280, 800)):
    wiz = shell.open_window()
    wiz.resize(*size)
    pump(qapp)
    return wiz


def go(wiz, qapp, slug):
    wiz.setStartId(wiz._page_ids[slug])
    wiz.restart()
    pump(qapp)


def rect_in(wiz, widget):
    return QtCore.QRect(widget.mapTo(wiz, QtCore.QPoint(0, 0)), widget.size())


# ── the hook ─────────────────────────────────────────────────────────────────────────
def test_the_dock_knows_every_wizard_page_by_its_slug(shell, qapp):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    inverse = {v: k for k, v in wiz._page_ids.items()}
    assert set(inverse) == set(wiz.pageIds()), "wizard._page_ids no longer covers pageIds()"
    assert dock._page_slug == "welcome" and dock._page_title == "HugMesh Image Studio"
    for slug in ("mode", "domain_services", "localmesh", "build"):
        go(wiz, qapp, slug)
        assert dock._page_slug == slug, slug
        w = dock._page_where()
        assert w.slug == slug and w.title == wiz.currentPage().title() and w.face == "gui"
    wiz.cfg.mode = "mesh"
    go(wiz, qapp, "domain_services")
    w = dock._page_where()
    assert w.route == "image" and w.mode == "mesh" and w.step_total > 0 and 0 < w.step_index <= w.step_total
    go(wiz, qapp, "localmesh_domains")
    assert dock._page_where().route == "docker"


def test_the_where_carries_the_domain_and_tab_on_screen_re_read_each_time(shell, qapp):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    wiz.cfg.mode = "mesh"
    wiz.cfg.domains = [Domain(name="shop.example", optional_services=["tuwunel"]),
                       Domain(name="blog.example", optional_services=["akkoma"])]
    go(wiz, qapp, "domain_services")
    page = wiz.currentPage()
    first = page.current_domain()
    w = dock._page_where()
    assert w.domain == first and w.tab == "services"
    page.brand_tabs.open_tab("Look") if page.brand_tabs.view is not None else None
    pump(qapp)
    page._step(1)
    pump(qapp)
    w2 = dock._page_where()
    assert w2.domain == page.current_domain() and w2.domain != first
    assert any("shop.example" in k for k, _v in w2.domains)


def test_a_window_without_a_page_signal_announces_its_given_slug(qapp, tmp_path):
    holder = QtWidgets.QWidget()
    dock = dock_mod.mount_dock(holder, GENERATOR_DIR, snapshot_fn=make_snapshot, auto_poll=False,
                               page_slug="fleet", agent_card=False)
    assert dock._page_slug == "fleet" and dock.tip.full_text().startswith("Tip: ")
    holder.close()


# ── the tip ──────────────────────────────────────────────────────────────────────────
def test_tip_label_geometry_and_bar_height_unchanged_from_main(shell, qapp):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    assert dock.bar_height() == BAR_HEIGHT_ON_MAIN
    assert dock.tip.objectName() == "assistant_tip" and dock.tip.isVisible()
    assert dock.tip.full_text().startswith("Tip: ") and dock.tip.height() >= dock_mod.MIN_CLICK_PX
    assert dock.tip_hide.width() >= dock_mod.MIN_CLICK_PX and dock.tip_hide.toolTip() == "Hide tips"
    assert dock.tip.text() and dock.tip.text() != dock.tip.full_text() or len(dock.tip.full_text()) < 60
    assert dock.tip.toolTip() == dock.tip.full_text()


def test_hiding_tips_persists_and_frees_the_bar(shell, qapp, tmp_path):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    dock.tip_hide.click()
    pump(qapp)
    assert assistant_settings.get("tips_hidden") is True
    assert not dock.tip.isVisible() and not dock.tip_hide.isVisible() and not dock.tip_row.isVisible()
    assert dock.tips_show_btn.isVisible() or not dock.expanded
    assert dock.bar_height() == BAR_HEIGHT_ON_MAIN
    dock.set_expanded(True)
    pump(qapp)
    assert dock.tips_show_btn.isVisible()
    dock.tips_show_btn.click()
    pump(qapp)
    assert dock.tip.isVisible() and assistant_settings.get("tips_hidden") is False


def test_the_tip_follows_the_page_tab_and_state(shell, qapp):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    go(wiz, qapp, "mode")
    assert dock.tip.full_text() == "Tip: " + atips.TIPS["mode"][0] or dock.tip.full_text() in \
        ["Tip: " + t for t in atips.TIPS["mode"]]
    wiz.cfg.mode = "mesh"
    wiz.cfg.domains = [Domain(name="shop.example")]
    go(wiz, qapp, "domain_services")
    page = wiz.currentPage()
    assert dock.tip.full_text().startswith("Tip: Services:")
    if page.brand_tabs.view is not None:
        page.brand_tabs.open_tab("Look")
        dock.refresh_tip()
        assert dock.tip.full_text().startswith("Tip: Look:")
    assert dock.tip_line.text() == dock.tip.full_text()


def test_a_late_model_tip_for_an_old_page_is_dropped_and_none_while_busy(shell, qapp):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    go(wiz, qapp, "mode")
    dock._tip_born = (dock._clears, "mode", "")
    go(wiz, qapp, "role")                        # page changed: the old tip request is void
    dock._tip_born = (dock._clears, "mode", "")
    dock._handle("tip", "Stale sentence.", None)
    assert "Stale sentence" not in dock.tip.full_text()
    dock._tip_born = (dock._clears, "role", "")
    dock._handle("tip", "Fresh sentence for role.", None)
    assert dock.tip.full_text() == "Tip: Fresh sentence for role."
    dock._busy = True
    dock._page_since = 0.0
    dock.apply_snapshot(make_snapshot())
    before = dict(dock._tip_asked)
    dock.refresh_tip(force=True)
    assert dock._tip_asked == before and dock._tip_born is None
    dock._busy = False


# ── the pictures ───────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("size", SIZES, ids=[f"{w}x{h}" for w, h in SIZES])
def test_png_renders_of_the_bar_on_three_pages(shell, qapp, tmp_path, size):
    wiz = open_at(shell, qapp, size)
    dock = wiz.local_ai_dock
    wiz.cfg.mode = "mesh"
    wiz.cfg.domains = [Domain(name="shop.example", optional_services=["tuwunel", "phpbb"])]
    for slug in ("welcome", "domain_services", "localmesh"):
        go(wiz, qapp, slug)
        for expanded in (False, True):
            dock.set_expanded(expanded)
            if expanded:
                dock.show_tab("assistant")        # the bring-up step opens on its own tab
            pump(qapp)
            name = f"{slug}-{'expanded' if expanded else 'collapsed'}-{size[0]}x{size[1]}.png"
            wiz.grab().save(str(tmp_path / name))
            assert os.path.getsize(tmp_path / name) > 5000
            tip = rect_in(wiz, dock.tip)
            assert dock.tip.isVisible() and tip.width() >= 120 and tip.height() >= dock_mod.MIN_CLICK_PX
            assert QtCore.QRect(0, 0, wiz.width(), wiz.height()).contains(tip)
            for b in (dock.start_btn, dock.work_btn, dock.pop_btn, dock.tip_hide):
                assert not tip.intersects(rect_in(wiz, b)), (name, b.text())
            assert dock.tip.text().endswith("…") or dock.tip.text() == dock.tip.full_text()
            if expanded:
                line = rect_in(wiz, dock.tip_line)
                assert dock.tip_line.isVisible() and line.height() >= 14
                assert not line.intersects(rect_in(wiz, dock.prompt))
    print("PNGs in", tmp_path)


# ── cards ────────────────────────────────────────────────────────────────────────────
@pytest.fixture
def mesh_window(shell, qapp):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    page = wiz.localmesh_page
    page.mount_brand()
    page._seed_domains()
    page.mesh_domains.domains.append(Domain(name="shop.example", optional_services=["tuwunel", "phpbb"]))
    page.domain_services.load(page.mesh_domains)
    body = page.domain_services
    go(wiz, qapp, "localmesh_domain_services")      # entering the step reloads the walk
    while body.current_domain() != "shop.example":
        body._step(1)
    dock.set_expanded(True)
    pump(qapp)
    return wiz, dock, body


def test_a_change_block_becomes_a_card_and_apply_undo_go_through_the_page(mesh_window, qapp, tmp_path):
    wiz, dock, body = mesh_window
    w = dock._page_where()
    assert w.slug == "localmesh_domain_services" and w.domain == "shop.example"
    answer = ('I can turn the forum off for shop.example.\n```change\n'
              '{"domain": "shop.example", "field": "services", "to": ["tuwunel"]}\n```')
    from hugmesh_studio.core import assistant_prompt as ap
    prompt = ap.Prompt("sys", [], [], {}, w)
    dock._last_prompt[dock._clears] = prompt
    dock._handle("done", (dock._clears, "turn off the forum for this domain", answer), None)
    card = dock._card
    assert isinstance(card, dock_mod._ProposalCard)
    assert card.title.text() == "Proposed change — shop.example"
    assert card.rows.text() == "services this domain runs: tuwunel, phpbb -> tuwunel"
    for b in (card.apply_btn, card.cancel_btn):
        assert b.isVisible() and b.height() >= dock_mod.MIN_CLICK_PX
        r = rect_in(wiz, b)
        assert rect_in(wiz, dock).contains(r) and not r.intersects(rect_in(wiz, dock.answer))
    assert "Sources:" in dock.answer.toPlainText()
    wiz.grab().save(str(tmp_path / "proposal-card.png"))
    card.apply_btn.click()
    pump(qapp)
    assert card.status.text() == "Applied. The page shows the new value."
    assert body.selected_slugs() == ["tuwunel"] and not body._boxes["phpbb"].isChecked()
    assert card.undo_btn.isVisible() and not card.apply_btn.isVisible()
    wiz.grab().save(str(tmp_path / "proposal-applied.png"))
    card.undo_btn.click()
    pump(qapp)
    assert card.status.text() == "Undone." and body.selected_slugs() == ["tuwunel", "phpbb"]
    wiz.grab().save(str(tmp_path / "proposal-undone.png"))
    # a second answer replaces the card; Clear removes it
    dock._last_prompt[dock._clears] = prompt
    dock._handle("done", (dock._clears, "q", "plain answer"), None)
    assert dock._card is None
    dock._last_prompt[dock._clears] = prompt
    dock._handle("done", (dock._clears, "q", answer), None)
    assert dock._card is not None
    dock.clear()
    assert dock._card is None and dock._undo == {}


def test_a_refused_change_shows_the_valid_choices_on_the_card(mesh_window, qapp):
    wiz, dock, body = mesh_window
    from hugmesh_studio.core import assistant_prompt as ap
    dock._last_prompt[dock._clears] = ap.Prompt("sys", [], [], {}, dock._page_where())
    dock._handle("done", (dock._clears, "set the root password",
                          '```change\n{"domain": "shop.example", "field": "root_password", "to": "hunter2"}\n```'), None)
    card = dock._card
    assert isinstance(card, dock_mod._ProposalCard) and not card.apply_btn.isVisible()
    assert card.status.text().startswith("I can only change these on this page: services, signin, tor")
    assert "hunter2" not in card.status.text()


def test_the_prompt_fn_injection_still_gets_no_footer_and_no_card(shell, qapp):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    dock._prompt_fn = lambda text, history, on_chunk, should_stop: ('x\n```change\n'
        '{"domain": "a", "field": "tor", "to": true}\n```')
    dock.set_expanded(True)
    dock.prompt.setText("hi")
    assert dock.send()
    assert wait_for(qapp, lambda: not dock._busy)
    assert "Sources:" not in dock.answer.toPlainText() and dock._card is None


def test_send_collects_state_off_the_window_thread_and_nothing_stalls(shell, qapp, monkeypatch):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    main = threading.get_ident()
    seen = {}

    def slow_rows(state_dir):
        seen["thread"] = threading.get_ident()
        time.sleep(2.0)
        return [("build", "slow")]
    monkeypatch.setattr(actxt, "build_rows", slow_rows)
    monkeypatch.setattr(lai, "send_prompt", lambda text, *a, **k: "answered")
    ticks = []
    timer = QtCore.QTimer()
    timer.setInterval(100)
    timer.timeout.connect(lambda: ticks.append(time.monotonic()))
    timer.start()
    dock.set_expanded(True)
    dock.prompt.setText("where am I")
    t0 = time.monotonic()
    assert dock.send()
    assert wait_for(qapp, lambda: not dock._busy, timeout=8)
    timer.stop()
    assert seen["thread"] != main
    gaps = [b - a for a, b in zip(ticks, ticks[1:])]
    assert ticks and max(gaps) < 0.6, max(gaps)
    assert time.monotonic() - t0 < 4.0
    assert "answered" in dock.answer.toPlainText() and "Sources:" in dock.answer.toPlainText()


def test_no_model_running_shows_the_docs_fallback(shell, qapp, monkeypatch):
    wiz = open_at(shell, qapp)
    dock = wiz.local_ai_dock
    monkeypatch.setattr(lai, "send_prompt",
                        lambda *a, **k: (_ for _ in ()).throw(lai.LocalAIError("Ollama is not answering on 127.0.0.1:11434.")))
    go(wiz, qapp, "build")
    dock.set_expanded(True)
    dock.prompt.setText("does continue start the build")
    assert dock.send()
    assert wait_for(qapp, lambda: not dock._busy, timeout=8)
    text = dock.answer.toPlainText()
    assert dock_mod.aprompt.NOT_RUNNING in text
    assert "Without a model I can still show the docs: STUDIO-WALKTHROUGH.md § " in text


def test_nothing_the_dock_does_opens_a_modal_dialog(mesh_window, qapp):
    wiz, dock, body = mesh_window
    from hugmesh_studio.core import assistant_prompt as ap
    dock._last_prompt[dock._clears] = ap.Prompt("sys", [], [], {}, dock._page_where())
    dock._handle("done", (dock._clears, "q", '```change\n{"domain": "shop.example", "field": "tor", "to": true}\n```'), None)
    card = dock._card
    card.apply_btn.click()
    card.undo_btn.click()
    card.cancel_btn.click()
    pump(qapp)
    dock.tip_hide.click()
    dock.set_tips_hidden(False)
    assert dock._card is None
