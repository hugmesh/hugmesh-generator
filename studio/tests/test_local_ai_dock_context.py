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
from hugmesh_studio.core import ollama_docker as odk                              # noqa: E402
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
#: the real start, kept before the autouse fixture swaps it for one that raises
_REAL_START = lai.start_assistant
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


def assert_card_fits(wiz, dock, card):
    """Nothing on a card is clipped: every wrapped label is as tall as its text needs,
    inside the card, and the buttons are clickable and inside the dock (a long status
    line was once cut off top and bottom; see diff-applied.png in the PR)."""
    for lab in (card.title, card.rows, card.status):
        if lab.isVisible() and lab.text():
            need = lab.heightForWidth(lab.width())
            assert lab.height() >= need, (lab.text()[:60], lab.height(), need)
            assert rect_in(wiz, card).contains(rect_in(wiz, lab)), lab.text()[:60]
    for b in (card.apply_btn, card.cancel_btn, card.undo_btn):
        if b.isVisible():
            assert b.height() >= dock_mod.MIN_CLICK_PX
            assert rect_in(wiz, dock).contains(rect_in(wiz, b)), b.text()


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
    assert_card_fits(wiz, dock, card)
    wiz.grab().save(str(tmp_path / "proposal-card.png"))
    card.apply_btn.click()
    pump(qapp)
    assert card.status.text() == "Applied. The page shows the new value."
    assert_card_fits(wiz, dock, card)
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
    assert not dock.tip_row.isVisibleTo(dock)            # the card has the room
    dock.clear()
    assert dock._card is None and dock._undo == {}
    assert dock.tip_row.isVisibleTo(dock)                # and the tip line is back


def test_a_card_left_up_after_next_domain_neither_applies_nor_undoes_there(mesh_window, qapp, tmp_path):
    """PR #832 review (D1/U1): the card stayed up after Next domain and Apply wrote the
    domain on screen (blog.example), while the card named shop.example. Both domains hold
    the same services here, so only the domain guard can stop it."""
    wiz, dock, body = mesh_window
    page = wiz.localmesh_page
    page.mesh_domains.domains.append(Domain(name="blog.example", optional_services=["tuwunel", "phpbb"]))
    page.domain_services.load(page.mesh_domains)

    def step_to(name):
        """Next / Previous domain as the person presses them (never wraps)."""
        for delta in (1, -1):
            for _ in range(10):
                if body.current_domain() == name:
                    pump(qapp)
                    return
                body._step(delta)
        raise AssertionError(name)
    step_to("shop.example")
    from hugmesh_studio.core import assistant_prompt as ap
    dock._last_prompt[dock._clears] = ap.Prompt("sys", [], [], {}, dock._page_where())
    dock._handle("done", (dock._clears, "turn off the forum", 'ok\n```change\n'
                          '{"domain": "shop.example", "field": "services", "to": ["tuwunel"]}\n```'), None)
    card = dock._card
    assert card.title.text() == "Proposed change — shop.example"
    step_to("blog.example")
    card.apply_btn.click()
    pump(qapp)
    assert card.status.text().startswith("This change is for shop.example, but the page now shows blog.example")
    assert body.selected_slugs("blog.example") == body.selected_slugs("shop.example") == ["tuwunel", "phpbb"]
    assert card.apply_btn.isVisible()                    # back on shop.example it can still apply
    assert_card_fits(wiz, dock, card)
    wiz.grab().save(str(tmp_path / "card-after-next-domain.png"))
    step_to("shop.example")
    card.apply_btn.click()
    pump(qapp)
    assert card.status.text() == "Applied. The page shows the new value."
    assert body.selected_slugs("shop.example") == ["tuwunel"]
    step_to("blog.example")
    card.undo_btn.click()
    pump(qapp)
    assert "Go back to shop.example to undo it" in card.status.text()
    assert body.selected_slugs("blog.example") == ["tuwunel", "phpbb"]
    assert body.selected_slugs("shop.example") == ["tuwunel"]
    step_to("shop.example")
    card.undo_btn.click()
    pump(qapp)
    assert card.status.text() == "Undone." and body.selected_slugs("shop.example") == ["tuwunel", "phpbb"]


def test_an_answer_shows_its_sources_line_at_both_widths(mesh_window, qapp, tmp_path):
    """An answered question as the person sees it: the bare answer, then the Sources
    line the code (never the model) writes from the docs it retrieved."""
    wiz, dock, body = mesh_window
    from hugmesh_studio.core import assistant_prompt as ap
    q = "Which services can I switch on for this domain?"
    w = dock._page_where(question=q)
    prompt = ap.build(q, w, [], generator_dir=GENERATOR_DIR, ctx_tokens=16384)
    assert prompt.sources, "the real docs index retrieved nothing"
    dock._last_prompt[dock._clears] = prompt
    dock._handle("done", (dock._clears, q, "shop.example runs tuwunel and phpbb; you can also "
                                           "tick akkoma, owncast, tube, games and the two character apps."), None)
    pump(qapp)
    text = dock.answer.toPlainText()
    assert "Sources: STUDIO-WALKTHROUGH.md" in text or "Sources: " in text
    assert dock._history[-1]["content"].startswith("shop.example runs") and "Sources:" not in dock._history[-1]["content"]
    for size in SIZES:
        wiz.resize(*size)
        pump(qapp)
        name = tmp_path / f"answered-{size[0]}x{size[1]}.png"
        wiz.grab().save(str(name))
        assert os.path.getsize(name) > 5000
        a = rect_in(wiz, dock.answer)
        assert a.height() >= 3 * dock_mod.MIN_CLICK_PX and QtCore.QRect(0, 0, wiz.width(), wiz.height()).contains(a)


DIFF_ANSWER = ("I can change the footer text.\n```diff\n--- a/src/index.html\n+++ b/src/index.html\n"
               "@@ -3 @@ -3 @@\n <footer>\n-  <p>Welcome to shop</p>\n+  <p>Welcome to the Shop</p>\n"
               " </footer>\n```\n")   # the garbled header qwen3:8b really wrote on 2026-10-29


def test_a_diff_block_becomes_a_diff_card_and_apply_revert_touch_only_the_folder(mesh_window, qapp, tmp_path,
                                                                                 monkeypatch):
    import json as _json
    from hugmesh_studio.core import assistant_code_edits as ce
    from hugmesh_studio.core import assistant_prompt as ap
    from hugmesh_studio.core import domain_workspaces as dw
    wiz, dock, body = mesh_window
    state = os.environ["HUGMESH_STUDIO_STATE_DIR"]
    folder = os.path.join(state, "domain-code", "shop", "web-shop.example")
    os.makedirs(os.path.join(folder, ".git"))
    os.makedirs(os.path.join(folder, "src"))
    with open(os.path.join(folder, ".git", dw.MARKER), "w") as fh:
        _json.dump({"app": "web", "domain": "shop.example", "mesh": "shop", "source": "x", "schema": 1}, fh)
    index = os.path.join(folder, "src", "index.html")
    original = "<html>\n<body>\n<footer>\n  <p>Welcome to shop</p>\n</footer>\n</body>\n</html>\n"
    with open(index, "w") as fh:
        fh.write(original)
    ws = ce.Workspace("shop", "shop.example", "web", os.path.realpath(folder))
    # workspace discovery itself is pinned in test_assistant_code_edits.py
    monkeypatch.setattr(dock, "_code_context", lambda where, q: {"ctx": None, "workspace": ws,
                                                                  "files": ["src/index.html"], "wants_edit": True})
    q = "change the footer text in index.html to 'Welcome to the Shop'"
    dock._last_prompt[dock._clears] = ap.Prompt("sys", [], [], {}, dock._page_where(q))
    dock._handle("done", (dock._clears, q, DIFF_ANSWER), None)
    pump(qapp)
    card = dock._card
    assert isinstance(card, dock_mod._DiffCard)
    assert card.title.text() == "Proposed edit \u2014 web-shop.example"
    assert card.rows.text() == "1 file(s), 2 changed lines: src/index.html"
    for b in (card.view_btn, card.apply_btn, card.cancel_btn):
        assert b.isVisible() and b.height() >= dock_mod.MIN_CLICK_PX
        r = rect_in(wiz, b)
        assert rect_in(wiz, dock).contains(r) and not r.intersects(rect_in(wiz, dock.answer))
    wiz.grab().save(str(tmp_path / "diff-card.png"))
    card.view_btn.click()
    pump(qapp)
    win = dock._work_window if hasattr(dock, "_work_window") else None
    shown = [w for w in QtWidgets.QApplication.topLevelWidgets()
             if w.isVisible() and hasattr(w, "diff_view")]
    assert shown and "+  <p>Welcome to the Shop</p>" in shown[0].diff_view.toPlainText()
    assert not shown[0].isModal()
    shown[0].grab().save(str(tmp_path / "diff-viewer.png"))
    shown[0].close()
    card.apply_btn.click()
    pump(qapp)
    with open(index) as fh:
        assert "Welcome to the Shop" in fh.read()
    assert card.status.text().startswith("Applied to web-shop.example") and "Not committed" in card.status.text()
    assert card.undo_btn.text() == "Revert" and card.undo_btn.isVisible()
    assert_card_fits(wiz, dock, card)
    assert folder in card.status.toolTip() and "assistant-edits" in card.status.toolTip()
    wiz.grab().save(str(tmp_path / "diff-applied.png"))
    wiz.resize(*SIZES[1])
    pump(qapp)
    assert_card_fits(wiz, dock, card)
    wiz.grab().save(str(tmp_path / "diff-applied-1024x700.png"))
    card.undo_btn.click()
    pump(qapp)
    with open(index) as fh:
        assert fh.read() == original
    assert card.status.text() == "Reverted."
    wiz.grab().save(str(tmp_path / "diff-reverted.png"))
    del win
    # a diff that changes nothing never becomes a card
    dock._last_prompt[dock._clears] = ap.Prompt("sys", [], [], {}, dock._page_where(q))
    dock._handle("done", (dock._clears, q, "x\n```diff\n--- a/src/index.html\n+++ b/src/index.html\n```\n"), None)
    pump(qapp)
    assert dock._card is None and "changes nothing" in dock.answer.toPlainText()


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
    pump(qapp)
    assert_card_fits(wiz, dock, card)


def test_the_longest_refusal_fits_its_card_at_the_narrow_width(mesh_window, qapp, tmp_path):
    wiz, dock, body = mesh_window
    wiz.resize(*SIZES[1])
    pump(qapp)
    from hugmesh_studio.core import assistant_prompt as ap
    dock._last_prompt[dock._clears] = ap.Prompt("sys", [], [], {}, dock._page_where())
    dock._handle("done", (dock._clears, "use a darker purple",
                          '```change\n{"domain": "shop.example", "field": "look.preset", "to": "purple"}\n```'), None)
    pump(qapp)
    card = dock._card
    assert card.status.text().startswith("Valid values for look.preset: dark, light")
    assert "demisexual" in card.status.toolTip() and "demisexual" in dock.answer.toPlainText()
    wiz.grab().save(str(tmp_path / "refusal-1024x700.png"))
    assert_card_fits(wiz, dock, card)


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


# ── PR #832 round 2: every card state keeps its buttons in the window ──────────────────
#: 1280x800, the 1024x600 netbook's documented default (wizard.medium_size) and the
#: 800x800 screen's narrow one.
CARD_SIZES = ((1280, 800), (942, 552), (736, 736))


def assert_card_in_window(wiz, dock, card, name, shots):
    """Everything assert_card_fits checks, plus: the window is the size asked for, every
    visible button is INSIDE THE WINDOW (round 2: Close / Undo sat below a 552 px
    window's edge while still inside the overflowing dock), the answer area keeps its
    floor and the wizard's Next is not under the panel."""
    qapp = QtWidgets.QApplication.instance()
    pump(qapp)
    pump(qapp)
    win = QtCore.QRect(0, 0, wiz.width(), wiz.height())
    assert_card_fits(wiz, dock, card)
    buttons = [b for b in (getattr(card, "view_btn", None), card.apply_btn, card.cancel_btn, card.undo_btn)
               if b is not None and b.isVisible()]
    assert buttons, name
    for b in buttons:
        r = rect_in(wiz, b)
        assert win.contains(r), (name, b.text(), r.getRect(), wiz.size())
        assert b.width() >= b.minimumSizeHint().width(), (name, b.text())
    c = rect_in(wiz, card)
    assert win.contains(c), (name, c.getRect(), wiz.size())
    assert rect_in(wiz, dock).contains(c), (name, c.getRect(), rect_in(wiz, dock).getRect())
    a = rect_in(wiz, dock.answer)
    assert a.height() >= 36 and a.bottom() < c.top(), (name, a.getRect(), c.getRect())
    nxt = wiz.button(QtWidgets.QWizard.WizardButton.NextButton)
    if nxt.isVisible():
        assert not rect_in(wiz, nxt).intersects(rect_in(wiz, dock)), (name, rect_in(wiz, nxt).getRect())
    wiz.grab().save(str(shots / f"{name}.png"))


@pytest.fixture
def two_domains(mesh_window, qapp):
    wiz, dock, body = mesh_window
    page = wiz.localmesh_page
    page.mesh_domains.domains.append(Domain(name="blog.example", optional_services=["akkoma"]))
    page.domain_services.load(page.mesh_domains)

    def step_to(name):
        for delta in (1, -1):
            for _ in range(10):
                if body.current_domain() == name:
                    pump(qapp)
                    return
                body._step(delta)
        raise AssertionError(name)
    step_to("shop.example")
    return wiz, dock, body, step_to


def _answer(dock, qapp, question, answer):
    from hugmesh_studio.core import assistant_prompt as ap
    dock._last_prompt[dock._clears] = ap.Prompt("sys", [], [], {}, dock._page_where(question))
    dock._handle("done", (dock._clears, question, answer), None)
    pump(qapp)
    return dock._card


def _plant_workspace(dock, monkeypatch):
    import json as _json
    from hugmesh_studio.core import assistant_code_edits as ce
    from hugmesh_studio.core import domain_workspaces as dw
    state = os.environ["HUGMESH_STUDIO_STATE_DIR"]
    folder = os.path.join(state, "domain-code", "shop", "web-shop.example")
    os.makedirs(os.path.join(folder, ".git"), exist_ok=True)
    os.makedirs(os.path.join(folder, "src"), exist_ok=True)
    with open(os.path.join(folder, ".git", dw.MARKER), "w") as fh:
        _json.dump({"app": "web", "domain": "shop.example", "slug": "shop.example", "mesh": "shop",
                    "source": "x", "schema": 1}, fh)
    index = os.path.join(folder, "src", "index.html")
    with open(index, "w") as fh:
        fh.write("<html>\n<body>\n<footer>\n  <p>Welcome to shop</p>\n</footer>\n</body>\n</html>\n")
    ws = ce.Workspace("shop", "shop.example", "web", os.path.realpath(folder))
    monkeypatch.setattr(dock, "_code_context", lambda where, q: {"ctx": None, "workspace": ws,
                                                                  "files": ["src/index.html"], "wants_edit": True})
    return index


@pytest.mark.parametrize("size", CARD_SIZES, ids=lambda s: f"{s[0]}x{s[1]}")
def test_every_card_state_keeps_its_buttons_inside_the_window(two_domains, qapp, tmp_path, size, monkeypatch):
    """Round 2 measured, at 942x552: the applied card's bottom at 572, the Next-domain
    refusal's at 600 and the invalid-choice card's at 582, all in a 552 px window; and
    at 800x600 a diff card's stale-edit refusal hid View / Apply / Cancel. The panel now
    grows to fit its card. PNGs of every state land in tmp_path."""
    wiz, dock, body, step_to = two_domains
    wiz.resize(*size)
    pump(qapp)
    assert (wiz.width(), wiz.height()) == size          # else the small cases are vacuous
    t = f"{size[0]}x{size[1]}"
    change = 'ok\n```change\n{"domain": "shop.example", "field": "services", "to": ["tuwunel"]}\n```'
    card = _answer(dock, qapp, "turn off the forum", change)
    assert isinstance(card, dock_mod._ProposalCard)
    assert_card_in_window(wiz, dock, card, f"proposed-{t}", tmp_path)
    step_to("blog.example")
    card.apply_btn.click()
    assert card.status.text().startswith("This change is for shop.example")
    assert_card_in_window(wiz, dock, card, f"next-domain-refused-{t}", tmp_path)
    step_to("shop.example")
    card.apply_btn.click()
    assert card.status.text() == "Applied. The page shows the new value."
    assert card.undo_btn.isVisible() and card.cancel_btn.text() == "Close"
    assert_card_in_window(wiz, dock, card, f"applied-{t}", tmp_path)
    card = _answer(dock, qapp, "add minecraft",
                   'x\n```change\n{"domain": "shop.example", "field": "services", "to": ["minecraft"]}\n```')
    assert not card.apply_btn.isVisible() and card.cancel_btn.text() == "Close"
    assert_card_in_window(wiz, dock, card, f"invalid-choice-{t}", tmp_path)
    index = _plant_workspace(dock, monkeypatch)
    card = _answer(dock, qapp, "change the footer text in index.html", DIFF_ANSWER)
    assert isinstance(card, dock_mod._DiffCard)
    assert_card_in_window(wiz, dock, card, f"diff-card-{t}", tmp_path)
    with open(index) as fh:
        text = fh.read()
    with open(index, "w") as fh:
        fh.write("<!-- a line the person added -->\n" + text)
    card.apply_btn.click()
    assert "the file says '<body>'" in card.status.text() or "the file says '<body>'" in dock.answer.toPlainText()
    assert_card_in_window(wiz, dock, card, f"diff-stale-refused-{t}", tmp_path)
    with open(index, "w") as fh:
        fh.write(text)
    card.apply_btn.click()
    assert card.status.text().startswith("Applied to web-shop.example")
    assert_card_in_window(wiz, dock, card, f"diff-applied-{t}", tmp_path)
    card.cancel_btn.click()
    pump(qapp)
    assert dock._card is None
    print("PNGs in", tmp_path)


def test_card_labels_show_markup_as_written(two_domains, qapp, tmp_path, monkeypatch):
    """Round 2: the stale-edit refusal quotes the file ("the file says '<body>'") and
    Qt's AutoText rendered it as rich text: "the file says ''". Every label that shows
    model, file or log text is plain text; the quoted line survives on the card, in its
    tooltip and in the answer area."""
    wiz, dock, body, step_to = two_domains
    wiz.resize(942, 552)
    index = _plant_workspace(dock, monkeypatch)
    card = _answer(dock, qapp, "change the footer text in index.html", DIFF_ANSWER)
    with open(index) as fh:
        text = fh.read()
    with open(index, "w") as fh:
        fh.write("<!-- one -->\n" + text)
    card.apply_btn.click()
    pump(qapp)
    for lab in (card.title, card.rows, card.status, dock.tip_line, dock.note, dock.tip, dock.summary):
        assert lab.textFormat() == QtCore.Qt.TextFormat.PlainText, lab.objectName()
    full = ("src/index.html changed since I proposed this edit (src/index.html line 3: the file says "
            "'<body>', the diff expects '<footer>'); nothing was changed. Ask again for a fresh diff.")
    assert full in dock.answer.toPlainText()                   # the full text, where it can scroll
    card.apply_btn.click()                                     # pressed again: said once
    pump(qapp)
    assert dock.answer.toPlainText().count(full) == 1
    shown = card.status.text()
    assert "'<body>'" in shown or shown.endswith("(the full list is in the answer above)")
    assert "&lt;body&gt;" in card.status.toolTip() or "<body>" in card.status.toolTip()
    # rendered, not just stored: the plain label is wider than the same text with the
    # markup removed (AutoText swallowed "<b>" and "<body>" and measured the rest)
    for payload in ("the file says '<body>'", "the model wrote <b>bold</b> here"):
        for lab in (card.title, card.rows, card.status):
            lab.setText(payload)
            lab.setWordWrap(False)                      # one line: its width is what it draws
            stripped = QtWidgets.QLabel(payload.replace("<body>", "").replace("<b>", "").replace("</b>", ""))
            stripped.setFont(lab.font())
            assert lab.sizeHint().width() > stripped.sizeHint().width() + 10, (payload, lab.sizeHint())
            lab.setWordWrap(True)
        dock._set_tip_text(payload, model=True)
        assert dock.tip_line.text() == "Tip: " + payload
        assert "&lt;" in dock.tip.toolTip()
    card.status.setText("the file says '<body>', the diff expects '<footer>'")
    card._fit()
    pump(qapp)
    wiz.grab().save(str(tmp_path / "plain-text-labels-942x552.png"))


def test_undo_follows_cancel_in_the_tab_order_on_both_cards(two_domains, qapp, monkeypatch):
    """Round 2: after a keyboard Apply, Undo was 20 Tabs away (never put in the order)."""
    wiz, dock, body, step_to = two_domains
    card = _answer(dock, qapp, "turn off the forum",
                   'ok\n```change\n{"domain": "shop.example", "field": "services", "to": ["tuwunel"]}\n```')
    card.apply_btn.click()
    pump(qapp)
    assert card.undo_btn.isVisible()
    assert dock.clear_btn.nextInFocusChain() is card.apply_btn
    assert card.apply_btn.nextInFocusChain() is card.cancel_btn
    assert card.cancel_btn.nextInFocusChain() is card.undo_btn
    _plant_workspace(dock, monkeypatch)
    card = _answer(dock, qapp, "change the footer text in index.html", DIFF_ANSWER)
    chain = [dock.clear_btn]
    for _ in range(4):
        chain.append(chain[-1].nextInFocusChain())
    assert chain[1:] == [card.view_btn, card.apply_btn, card.cancel_btn, card.undo_btn]


def test_a_diff_card_left_up_after_next_domain_neither_applies_nor_reverts_there(two_domains, qapp,
                                                                                monkeypatch, tmp_path):
    """Round 2 (CDW): a diff card survived Next domain and Apply wrote shop's folder while
    blog.example was on screen. It now refuses like the proposal card; back on
    shop.example it applies and reverts."""
    wiz, dock, body, step_to = two_domains
    index = _plant_workspace(dock, monkeypatch)
    with open(index, "rb") as fh:
        original = fh.read()
    card = _answer(dock, qapp, "change the footer text in index.html", DIFF_ANSWER)
    step_to("blog.example")
    card.apply_btn.click()
    pump(qapp)
    assert card.status.text() == ("This edit is for shop.example, but the page now shows blog.example. "
                                  "Go back to shop.example to apply it; nothing was changed.")
    assert card.apply_btn.isVisible()
    with open(index, "rb") as fh:
        assert fh.read() == original
    wiz.grab().save(str(tmp_path / "diff-card-on-blog.png"))
    step_to("shop.example")
    card.apply_btn.click()
    pump(qapp)
    assert card.status.text().startswith("Applied to web-shop.example")
    with open(index, "rb") as fh:
        applied = fh.read()
    assert applied != original
    step_to("blog.example")
    card.undo_btn.click()
    pump(qapp)
    assert card.status.text().startswith("This edit is for shop.example") and "to revert it" in card.status.text()
    with open(index, "rb") as fh:
        assert fh.read() == applied
    step_to("shop.example")
    card.undo_btn.click()
    pump(qapp)
    assert card.status.text() == "Reverted."
    with open(index, "rb") as fh:
        assert fh.read() == original


def test_a_native_windows_start_refusal_names_no_command_and_opens_no_window(qapp):
    """The Windows refusal comes with no command (the script is bash there): the panel
    says the sentence alone and does not open the work window, whose commands are the
    same bash script. A refusal WITH a command still opens it (test_local_ai_dock)."""
    said = lai.StartResult(False, lai.windows_refusal("nt"), "")   # what start_assistant returns there
    dock = dock_mod.LocalAIDock(GENERATOR_DIR, snapshot_fn=make_snapshot, start_fn=lambda: said,
                                auto_poll=False, expanded=True)
    dock.show()
    try:
        dock.start_btn.click()
        assert wait_for(qapp, lambda: dock.start_btn.isEnabled() and "WSL2" in dock.note.text())
        assert "Run it yourself" not in dock.note.text() and dock.note.text().startswith(
            "Starting the local assistant runs the bash script")
        assert dock.work_window is None
    finally:
        dock.close()
        dock.deleteLater()


def assert_mount_agrees(wiz, dock, name):
    """The wizard's content ends exactly where the panel starts, and the panel is the
    height the mount computes NOW (round 3: after collapse and re-expand with a card
    up, the content kept 332 px over a panel whose top was 317 at 942x552, so the
    About / Back / Next / Cancel row ran under the panel)."""
    qapp = QtWidgets.QApplication.instance()
    pump(qapp)
    pump(qapp)
    mount = wiz._local_ai_mount
    want = min(mount.strip_height(), max(0, wiz.height() - 120))
    assert mount.container.height() == dock.y(), (name, mount.container.height(), dock.y())
    assert dock.y() + dock.height() == wiz.height() and dock.height() == want, \
        (name, dock.geometry().getRect(), want, wiz.size())
    nxt = wiz.button(QtWidgets.QWizard.WizardButton.NextButton)
    if nxt.isVisible():
        assert rect_in(wiz, nxt).bottom() < dock.y(), (name, rect_in(wiz, nxt).getRect(), dock.y())


@pytest.mark.parametrize("size", CARD_SIZES + ((800, 600),), ids=lambda s: f"{s[0]}x{s[1]}")
def test_collapse_expand_and_pop_out_put_back_with_a_card_up_relayout_the_window(
        two_domains, qapp, tmp_path, size, monkeypatch):
    """Round 3 (LOOK): collapsing and re-expanding the panel, or putting back a
    popped-out panel, while a card was up left the wizard content at a stale height
    under the panel. Each gesture, on a proposal card and on a diff card, at the three
    sizes: the content and the panel agree and every card button is in the window."""
    wiz, dock, body, step_to = two_domains
    wiz.resize(*size)
    pump(qapp)
    assert (wiz.width(), wiz.height()) == size
    t = f"{size[0]}x{size[1]}"
    change = 'ok\n```change\n{"domain": "shop.example", "field": "services", "to": ["tuwunel"]}\n```'
    card = _answer(dock, qapp, "turn off the forum", change)
    card.apply_btn.click()
    assert card.status.text() == "Applied. The page shows the new value."
    _plant_workspace(dock, monkeypatch)
    for kind in ("proposal", "diff"):
        if kind == "diff":
            card = _answer(dock, qapp, "change the footer text in index.html", DIFF_ANSWER)
            assert isinstance(card, dock_mod._DiffCard)
        assert_card_in_window(wiz, dock, card, f"{kind}-before-{t}", tmp_path)
        assert_mount_agrees(wiz, dock, f"{kind}-before-{t}")
        dock.chevron.click()                                   # collapse
        assert not dock.expanded
        assert_mount_agrees(wiz, dock, f"{kind}-collapsed-{t}")
        dock.chevron.click()                                   # and open again
        assert dock.expanded
        assert_mount_agrees(wiz, dock, f"{kind}-reexpanded-{t}")
        assert_card_in_window(wiz, dock, card, f"{kind}-reexpanded-{t}", tmp_path)
        dock.pop_btn.click()                                   # pop out: the panel window has the card
        assert dock.popped
        assert_mount_agrees(wiz, dock, f"{kind}-popped-{t}")
        win = dock.panel_window
        pump(qapp)
        for b in (card.apply_btn, card.cancel_btn):
            if b.isVisible():
                r = QtCore.QRect(b.mapTo(win, QtCore.QPoint(0, 0)), b.size())
                assert QtCore.QRect(0, 0, win.width(), win.height()).contains(r), (kind, b.text(), r.getRect())
        dock.pop_btn.click()                                   # put back ("Put back")
        assert not dock.popped
        assert_mount_agrees(wiz, dock, f"{kind}-put-back-{t}")
        assert_card_in_window(wiz, dock, card, f"{kind}-put-back-{t}", tmp_path)
        dock.pop_out()
        pump(qapp)
        dock.chevron.click()                                   # the chevron also puts it back
        assert not dock.popped and dock.expanded
        assert_mount_agrees(wiz, dock, f"{kind}-chevron-put-back-{t}")
        assert_card_in_window(wiz, dock, card, f"{kind}-chevron-put-back-{t}", tmp_path)
    print("PNGs in", tmp_path)


# ── PR #832 round 4 (WINDOWS): a start pressed on the collapsed strip is seen ─────────
#: The sizes the round-4 skeptic measured the note at, and the 800x800 screen's.
NOTE_SIZES = ((942, 552), (800, 600), (1024, 700), (1280, 800), (736, 736))
_NO_BASH = "the bash start script was spawned"


def _no_bash_spawn(monkeypatch):
    import subprocess
    real = subprocess.Popen

    def guard(args, *a, **k):
        if any("bash" in str(x) or "local-ai" in str(x) for x in (args if isinstance(args, (list, tuple)) else [args])):
            raise AssertionError(_NO_BASH)
        return real(args, *a, **k)
    monkeypatch.setattr(subprocess, "Popen", guard)


def _start_case(case, monkeypatch):
    """Route the dock's own start (odk.start_assistant -> lai.start_assistant) through the
    REAL code, as native Windows (osname="nt") or as Linux with a spawn that fails.
    Returns the sentence the person must be shown whole."""
    monkeypatch.setattr(lai, "start_assistant", _REAL_START)
    real_odk = odk.start_assistant
    if case == "nt-system":
        monkeypatch.setattr(odk, "start_assistant",
                            lambda gen, mode, **k: real_odk(gen, odk.SYSTEM, osname="nt", **k))
        return lai.windows_refusal("nt")
    if case == "nt-docker":
        monkeypatch.setattr(odk, "start_assistant", lambda gen, mode, **k: real_odk(
            gen, odk.DOCKER, osname="nt", starter=lambda runner, environ=None: odk.StartOutcome(True, "up"),
            ready=lambda env, timeout: True, **k))
        return None                                  # the Docker sentence names its own endpoint

    def no_bash(*a, **k):
        raise OSError(2, "No such file or directory", "bash")
    monkeypatch.setattr(odk, "start_assistant",
                        lambda gen, mode, **k: _REAL_START(gen, spawn=no_bash))
    return None


@pytest.mark.parametrize("case", ["nt-system", "nt-docker", "linux-fail"])
@pytest.mark.parametrize("size", NOTE_SIZES, ids=lambda s: f"{s[0]}x{s[1]}")
def test_start_from_the_collapsed_strip_opens_the_panel_and_shows_the_whole_note(
        mesh_window, qapp, tmp_path, size, case, monkeypatch):
    """Round 4 (WINDOWS): on native Windows, Start local assistant pressed on the
    COLLAPSED strip (the wizard's default) showed nothing: the refusal has no command,
    so no work window opens, and the note it went to is hidden with the panel. Expanded,
    the note showed 41 of its 140 px at 942x552 and 46 of 168 at 800x600, cut off before
    the native Windows way on. Now the panel opens on the Assistant tab and grows to
    show the whole note, the page above it still placed exactly; the Linux failure note
    is not clipped either. Nothing runs bash. PNGs in tmp_path."""
    wiz, dock, body = mesh_window
    _no_bash_spawn(monkeypatch)
    want = _start_case(case, monkeypatch)
    dock.set_expanded(False)
    wiz.resize(*size)
    pump(qapp)
    assert (wiz.width(), wiz.height()) == size and not dock.expanded
    assert dock.start_btn.isVisible()                       # the button is on the strip
    t = f"{case}-{size[0]}x{size[1]}"
    dock.start_btn.click()
    assert wait_for(qapp, lambda: dock.start_btn.isEnabled() and dock.note.text())
    pump(qapp)
    pump(qapp)
    note = dock.note
    text = note.text()
    if case == "nt-system":
        assert text == want and "127.0.0.1:11434" in text and "Run it yourself" not in text
    elif case == "nt-docker":
        assert "queue worker was not started" in text and "WSL2" in text and "Run it yourself" not in text
    else:
        assert "Could not start it" in text and text.count("Run it yourself") == 1, text
    assert dock.expanded and dock.current_tab() == "assistant", t
    assert note.isVisible(), t
    assert note.height() >= note.heightForWidth(note.width()), (t, note.height(), note.heightForWidth(note.width()))
    win = QtCore.QRect(0, 0, wiz.width(), wiz.height())
    r = rect_in(wiz, note)
    assert win.contains(r) and rect_in(wiz, dock).contains(r), (t, r.getRect(), rect_in(wiz, dock).getRect())
    # nothing else in the chat column is pushed out: the prompt and the answer floor
    assert rect_in(wiz, dock.prompt).bottom() < wiz.height() and dock.answer.height() >= 36, t
    assert_mount_agrees(wiz, dock, t)
    assert wiz.height() - dock.height() >= 120, t           # the page keeps its floor
    if case.startswith("nt"):
        assert dock.work_window is None, t                  # its commands are the bash script
    else:
        assert dock.work_window is not None and dock.work_window.isVisible(), t
        dock.work_window.close()
    wiz.grab().save(str(tmp_path / f"{t}.png"))
    dock._unsay(dock._message_token)                        # the note times out
    assert wait_for(qapp, lambda: not note.isVisible())
    assert_mount_agrees(wiz, dock, f"{t}-after")             # and the panel is back to its cap
    assert dock.height() == dock_mod.dock_height_for(wiz.height(), True, dock.bar_height(), dock.tall), t


@pytest.mark.parametrize("before", ["expanded", "builds-tab", "popped", "said-while-collapsed"])
@pytest.mark.parametrize("size", ((942, 552), (800, 600)), ids=lambda s: f"{s[0]}x{s[1]}")
def test_the_windows_note_is_whole_whatever_the_panel_was_doing(
        mesh_window, qapp, tmp_path, size, before, monkeypatch):
    """The same refusal when the panel was already open (the note's own change must
    re-place the panel: no expand happens), on another tab (the note lives on the
    Assistant tab), popped out (its window is raised, not the docked strip opened),
    and a long note said while collapsed and then opened with the chevron."""
    wiz, dock, body = mesh_window
    _no_bash_spawn(monkeypatch)
    want = _start_case("nt-system", monkeypatch)
    wiz.resize(*size)
    dock.set_expanded(before == "expanded")
    if before == "builds-tab":
        dock.tabs.setCurrentIndex(dock._tab_index["builds"])
    if before == "popped":
        dock.pop_out()
    if before == "expanded":
        dock._say("Starting.")                     # a one-line note first: only its text changes
    pump(qapp)
    t = f"{before}-{size[0]}x{size[1]}"
    if before == "said-while-collapsed":
        dock._say(want, 60, warn=True)
        pump(qapp)
        assert not dock.note.isVisible()
        dock.chevron.click()
    else:
        dock.start_btn.click()
        assert wait_for(qapp, lambda: dock.start_btn.isEnabled() and dock.note.text())
    pump(qapp)
    pump(qapp)
    note = dock.note
    assert note.text() == want and note.isVisible() and dock.current_tab() == "assistant", t
    assert note.height() >= note.heightForWidth(note.width()), (t, note.height(), note.heightForWidth(note.width()))
    if before == "popped":
        win = dock.panel_window
        assert dock.popped and win.isVisible(), t
        r = QtCore.QRect(note.mapTo(win, QtCore.QPoint(0, 0)), note.size())
        assert QtCore.QRect(0, 0, win.width(), win.height()).contains(r), (t, r.getRect(), win.size())
        win.grab().save(str(tmp_path / f"{t}.png"))
        dock.put_back()
        return
    assert dock.expanded, t
    r = rect_in(wiz, note)
    assert QtCore.QRect(0, 0, wiz.width(), wiz.height()).contains(r) and rect_in(wiz, dock).contains(r), t
    assert_mount_agrees(wiz, dock, t)
    wiz.grab().save(str(tmp_path / f"{t}.png"))


def test_a_plain_start_success_on_the_collapsed_strip_opens_nothing(mesh_window, qapp):
    """Only a result the note alone can say opens the panel: a Linux start that
    succeeded (it has its command) leaves the strip collapsed and the tab as it was."""
    wiz, dock, body = mesh_window
    dock.tabs.setCurrentIndex(dock._tab_index["builds"])
    dock.set_expanded(False)
    dock._start_fn, dock._custom_start = (lambda: lai.StartResult(
        True, "Starting the local assistant; the status line updates.", "x start")), True
    pump(qapp)
    dock.start_btn.click()
    assert wait_for(qapp, lambda: dock.start_btn.isEnabled() and dock.note.text())
    pump(qapp)
    assert not dock.expanded and dock.current_tab() == "builds" and dock.work_window is None
    assert dock.height() == dock.bar_height()


@pytest.mark.parametrize("size", ((942, 552), (800, 600)), ids=lambda s: f"{s[0]}x{s[1]}")
def test_a_long_standing_problem_note_is_whole_and_the_panel_returns_to_its_cap(
        mesh_window, qapp, tmp_path, size):
    """The panel grows for the note whatever wrote it: the snapshot's own problem line
    (Ollama not answering, with its fix) is shown whole too, and once the snapshot is
    clean again the panel is back to dock_height_for()."""
    wiz, dock, body = mesh_window
    wiz.resize(*size)
    pump(qapp)
    t = f"problem-{size[0]}x{size[1]}"
    dock.apply_snapshot(make_snapshot(
        ollama_up=False, loaded=[], problem="The Ollama server is not answering on 127.0.0.1:11434.",
        fix=("Start it on this machine only: OLLAMA_HOST=127.0.0.1:11434 OLLAMA_CONTEXT_LENGTH=32768 "
             "setsid ollama serve >~/.cache/ollama-serve.log 2>&1 &, or choose the Studio's own "
             "Ollama in Docker, then press Start local assistant."),
        doc="docs/LOCAL-AI-ASSISTANT.md section 3"))
    pump(qapp)
    pump(qapp)
    note = dock.note
    assert note.isVisible() and "not answering" in note.text(), t
    assert note.height() >= note.heightForWidth(note.width()), (t, note.height(), note.heightForWidth(note.width()))
    assert rect_in(wiz, dock).contains(rect_in(wiz, note)), t
    assert_mount_agrees(wiz, dock, t)
    wiz.grab().save(str(tmp_path / f"{t}.png"))
    dock.apply_snapshot(make_snapshot())
    assert wait_for(qapp, lambda: not note.isVisible())
    assert_mount_agrees(wiz, dock, f"{t}-clean")
    assert dock.height() == dock_mod.dock_height_for(wiz.height(), True, dock.bar_height(), dock.tall), t
