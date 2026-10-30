"""The text UI's Local AI screen: the Tip line, tips off, the footer's optional slug,
apply / cancel / undo over a fake journey holding a Domain row, docs and options
without a model, and /where in the command-line chat loop.
"""
import io
import os
import types

import pytest

from hugmesh_studio.core import assistant_tips as atips
from hugmesh_studio.core import local_ai_status as lai
from hugmesh_studio.core.config import Domain, ImageConfig
from hugmesh_studio.tui import domain_services_step as step_mod
from hugmesh_studio.tui import local_ai as tla

REAL_SEND_PROMPT = lai.send_prompt

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(autouse=True)
def _state(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("HUGMESH_LOCAL_AI_DIR", str(tmp_path / "localai"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setattr(lai, "send_prompt",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("real model called")))


def snapshot():
    s = lai.Snapshot(models=["qwen3:8b"], loaded=["qwen3:8b"], ollama_up=True)
    s.summary = lai.summary_line(s)
    return s


class Journey:
    """The two things the screen reads from a journey plus a domain-services overlay."""

    def __init__(self, slug="domain_services"):
        self.slug = slug
        self.cfg = ImageConfig(mode="mesh")
        self.cfg.domains = [Domain(name="shop.example", optional_services=["tuwunel", "phpbb"])]
        self.step = step_mod.DomainServicesScreen()
        self.step.index = next(i for i, d in enumerate(self.step.domains(self)) if d.name == "shop.example")
        self.overlay = self.step
        self.status = ""

    def screen_for(self, slug):
        return types.SimpleNamespace(title="Domain services" if slug == "domain_services" else slug)


def open_screen(j, prompt_fn=None):
    screen = tla.LocalAIScreen(snapshot_fn=snapshot, prompt_fn=prompt_fn, generator_dir=GENERATOR_DIR)
    screen._under = j.overlay
    screen.enter(j)
    return screen


def test_the_screen_shows_a_tip_for_the_page_and_tips_off_hides_it():
    j = Journey()
    s = open_screen(j)
    lines = s.lines(j)
    tip = next(ln for ln in lines if ln.startswith("Tip: "))
    assert tip == "Tip: Services: tick what this domain runs; each service gets its own address under the domain."
    s.feed(j, "tips off")
    assert s.message.startswith("Tips hidden") and not any(ln.startswith("Tip: ") for ln in s.lines(j))
    s.feed(j, "tips on")
    assert any(ln.startswith("Tip: ") for ln in s.lines(j))
    assert any("docs <question>" in ln for ln in s.lines(j)) and any("apply | cancel | undo" in ln for ln in s.lines(j))


def test_the_footer_lines_take_an_optional_slug():
    plain = tla.status_line(key_hint=True)
    assert "Tip:" not in plain and plain.endswith("[F2]")
    with_tip = tla.status_line(slug="mode")
    assert with_tip.startswith(plain) and "  Tip: " in with_tip
    assert len(with_tip) - len(plain) <= len("  Tip: ") + tla.TIP_FOOTER_CHARS
    assert tla.plain_status_line() == f"[{lai.quick_line()} | type local-ai]"
    assert tla.plain_status_line(slug="vault").startswith(tla.plain_status_line()) and "Tip:" in tla.plain_status_line(slug="vault")
    atips.set_tips_hidden(True)
    assert tla.status_line(slug="mode") == plain
    atips.set_tips_hidden(False)


def test_where_names_the_page_domain_and_tab():
    j = Journey()
    s = open_screen(j)
    w = s.where(j, "q")
    assert w.face == "tui" and w.slug == "domain_services" and w.title == "Domain services"
    assert w.domain == "shop.example" and w.tab == "services" and w.mode == "mesh"
    assert any("shop.example" in k for k, _v in w.domains)
    j.step.section = 2
    assert s.where_page_only(j).tab == "look"


def test_a_grounded_answer_gets_a_footer_and_a_change_block_becomes_a_proposal(monkeypatch):
    j = Journey()
    calls = {}

    def fake(text, model=None, *, env=None, history=None, system=None, **k):
        calls.update(text=text, system=system, history=history)
        return ('I can turn the forum off.\n```change\n'
                '{"domain": "shop.example", "field": "services", "to": ["tuwunel"]}\n```')
    monkeypatch.setattr(lai, "send_prompt", fake)
    s = open_screen(j)
    s.feed(j, "turn off the forum for this domain")
    assert "# Where the person is" in calls["system"] and "shop.example" in calls["system"]
    assert "# Options on this page" in calls["system"] and "# Change format" in calls["system"]
    t = "\n".join(s.transcript)
    assert "you: turn off the forum for this domain" in t and "Sources: " in t
    assert "Proposed change for shop.example:" in t
    assert "services this domain runs: tuwunel, phpbb -> tuwunel" in t
    assert "type  apply  to make this change" in t
    assert s.history[-1]["content"].startswith("I can turn the forum off.") and "Sources" not in s.history[-1]["content"]
    row = j.cfg.domains[0]
    s.feed(j, "apply")
    assert s.message.startswith("Applied.") and row.optional_services == ["tuwunel"]
    s.feed(j, "undo")
    assert s.message == "Undone." and row.optional_services == ["tuwunel", "phpbb"]
    s.feed(j, "undo")
    assert s.message == "Nothing to undo."
    s.feed(j, "apply")
    assert s.message == "Nothing is proposed; ask for a change first."


def test_cancel_drops_the_proposal_and_a_refusal_lists_choices(monkeypatch):
    j = Journey()
    monkeypatch.setattr(lai, "send_prompt", lambda *a, **k:
                        '```change\n{"domain": "shop.example", "field": "services", "to": ["minecraft"]}\n```')
    s = open_screen(j)
    s.feed(j, "add minecraft")
    assert any("I do not know a service called minecraft" in ln for ln in s.transcript)
    assert s._pending is None
    monkeypatch.setattr(lai, "send_prompt", lambda *a, **k:
                        '```change\n{"domain": "shop.example", "field": "tor", "to": true}\n```')
    s.feed(j, "give it a tor address")
    assert s._pending is not None
    s.feed(j, "cancel")
    assert s._pending is None and j.cfg.domains[0].tor is False


def test_docs_and_options_need_no_model():
    j = Journey()
    s = open_screen(j)
    s.feed(j, "docs how do I stop the DevOps lane without deleting it")
    t = "\n".join(s.transcript)
    assert "[doc: STUDIO-WALKTHROUGH.md § Stopping the DevOps lane without deleting it]" in t
    assert "Sources: STUDIO-WALKTHROUGH.md § " in t
    s.feed(j, "options")
    t = "\n".join(s.transcript)
    assert "- services (services this domain runs): akkoma | tuwunel | phpbb" in t


def test_a_custom_prompt_fn_keeps_the_old_contract():
    j = Journey()
    s = open_screen(j, prompt_fn=lambda text, history: "plain")
    s.feed(j, "hello")
    assert s.transcript == ["you: hello", "ai:  plain"] and s._last_prompt is None


def test_not_running_prints_the_fallback(monkeypatch):
    j = Journey("build")
    j.overlay = None
    monkeypatch.setattr(lai, "send_prompt",
                        lambda *a, **k: (_ for _ in ()).throw(lai.LocalAIError("Ollama is not answering")))
    s = open_screen(j)
    s.feed(j, "does continue start the build")
    assert s.message == "Ollama is not answering"
    assert any("Without a model I can still show the docs: STUDIO-WALKTHROUGH.md" in ln for ln in s.transcript)


def test_chat_loop_where_sets_the_page_for_grounded_answers(monkeypatch):
    from _local_ai_fake import FakeOllama
    fake = FakeOllama()
    try:
        monkeypatch.setenv("OLLAMA_HOST", fake.host)
        monkeypatch.setenv(lai.GROUNDED_ENV, "1")
        monkeypatch.setenv("HUGMESH_GENERATOR_DIR", GENERATOR_DIR)
        monkeypatch.setattr(lai, "send_prompt", REAL_SEND_PROMPT)
        out = io.StringIO()
        rc = lai.chat_loop(io.StringIO("/where vault\nwhat is this page\n/quit\n"), out, dict(os.environ))
        assert rc == 0
        text = out.getvalue()
        assert "/where <page>" in text and "(page: vault)" in text
        assert "Hello there" in text and "Sources: " in text
        body = next(b for m, p, b in fake.requests if p == "/api/chat")
        assert body["messages"][0]["role"] == "system" and "- page: Vault" in body["messages"][0]["content"]
    finally:
        fake.close()


def test_apply_and_undo_act_only_on_the_domain_they_were_made_on(monkeypatch):
    """PR #832 review (U2): after moving to another domain, ``apply`` and ``undo`` wrote
    that domain. Both domains hold the same values, so only the domain guard can stop it."""
    j = Journey()
    j.cfg.domains = [Domain(name="shop.example", optional_services=["tuwunel"]),
                     Domain(name="blog.example", optional_services=["tuwunel"])]
    monkeypatch.setattr(lai, "send_prompt", lambda *a, **k:
                        'ok\n```change\n{"domain": "shop.example", "field": "tor", "to": true}\n```')
    s = open_screen(j)

    def go(name):
        j.step.index = next(i for i, d in enumerate(j.step.domains(j)) if d.name == name)

    def tor():
        return {d.name: bool(d.tor) for d in j.cfg.domains}
    s.feed(j, "give this domain its own tor address")
    go("blog.example")
    s.feed(j, "apply")
    assert s.message.startswith("This change is for shop.example, but the page now shows blog.example")
    assert tor() == {"shop.example": False, "blog.example": False}
    go("shop.example")
    s.feed(j, "apply")
    assert s.message.startswith("Applied.") and tor() == {"shop.example": True, "blog.example": False}
    go("blog.example")
    s.feed(j, "undo")
    assert s.message == ("Nothing to undo on this domain; the last change was on shop.example "
                         "(undo it there).")
    assert tor() == {"shop.example": True, "blog.example": False}
    go("shop.example")
    s.feed(j, "undo")
    assert s.message == "Undone." and tor() == {"shop.example": False, "blog.example": False}


def test_start_on_native_windows_says_the_refusal_and_no_command_to_run():
    """A native Windows refusal has no command (the script is bash): the screen shows
    the sentence alone, not "Run it yourself: " with nothing after it; a refusal that
    has a command still names it."""
    j = Journey()
    said = lai.start_assistant(GENERATOR_DIR, osname="nt", spawn=lambda *a, **k: (_ for _ in ()).throw(
        AssertionError("spawned on Windows")))
    s = tla.LocalAIScreen(snapshot_fn=snapshot, start_fn=lambda: said, generator_dir=GENERATOR_DIR)
    s._under = j.overlay
    s.enter(j)
    s.feed(j, "start")
    assert s.message == said.message and "WSL2" in s.message and "Run it yourself" not in s.message
    # the panel's note shows this same sentence, whole (test_local_ai_dock_context)
    assert said.message == lai.windows_refusal("nt") and said.message in s.lines(j)
    s3 = tla.LocalAIScreen(snapshot_fn=snapshot, generator_dir=GENERATOR_DIR, start_fn=lambda: lai.StartResult(
        False, "Could not start it: no bash. Run it yourself: /x/local-ai.sh start", "/x/local-ai.sh start"))
    s3._under = j.overlay
    s3.enter(j)
    s3.feed(j, "start")
    assert s3.message.count("Run it yourself") == 1, s3.message     # named once, not twice
    s2 = tla.LocalAIScreen(snapshot_fn=snapshot, generator_dir=GENERATOR_DIR,
                           start_fn=lambda: lai.StartResult(False, "It is missing.", "/x/local-ai.sh start"))
    s2._under = j.overlay
    s2.enter(j)
    s2.feed(j, "start")
    assert s2.message == "It is missing. Run it yourself: /x/local-ai.sh start"


# ── round 6 (PR #832): a delete command gets a warning above the answer ──────────────
WIPE = ("To wipe it:\n```bash\ndocker-compose down\nrm -rf ~/.hugmesh-checkouts\n"
        "docker system prune -a\n```\nThat removes everything.\n" + "More words.\n" * 14)


def test_the_text_screen_shows_the_warning_above_the_answer_and_above_the_conversation(monkeypatch):
    from hugmesh_studio.core import assistant_prompt as ap
    j = Journey("localmesh")
    monkeypatch.setattr(lai, "send_prompt", lambda *a, **k: WIPE)
    s = open_screen(j)
    s.feed(j, "wipe the local mesh and start fresh")
    t = s.transcript
    you = t.index("you: wipe the local mesh and start fresh")
    warn = next(i for i, ln in enumerate(t) if ap.DESTRUCTIVE_WARNING in ln)
    first_ai = next(i for i, ln in enumerate(t) if ln.startswith("ai:  "))
    assert you < warn < first_ai and t[warn].startswith("!!   ")
    # the screen keeps only the last 12 transcript lines: the warning is ALSO above them
    out = s.lines(j)
    conv = out.index("conversation:")
    assert any(ln == "!! " + ap.DESTRUCTIVE_WARNING for ln in out[:conv])
    assert s.message == ap.DANGER_NOTE
    # and first in the footer under the answer
    foot = next(i for i, ln in enumerate(t) if ln.startswith("     ") and ap.DESTRUCTIVE_WARNING in ln)
    assert t[foot + 1].startswith("     Sources: ")
    assert any("Commands not found in the docs I read: " in ln and "rm -rf ~/.hugmesh-checkouts" in ln for ln in t)
    # a harmless next answer clears it
    monkeypatch.setattr(lai, "send_prompt", lambda *a, **k: "Press Stop & clean Docker….")
    s.feed(j, "and the safe way?")
    assert not any(ln.startswith("!! ") for ln in s.lines(j)) and s.message != ap.DANGER_NOTE


def test_chat_loop_prints_the_warning_before_the_delete_command(monkeypatch):
    from _local_ai_fake import FakeOllama
    from hugmesh_studio.core import assistant_prompt as ap
    fake = FakeOllama()
    fake.chunks = [WIPE[i:i + 5] for i in range(0, len(WIPE), 5)]
    try:
        monkeypatch.setenv("OLLAMA_HOST", fake.host)
        monkeypatch.setenv(lai.GROUNDED_ENV, "1")
        monkeypatch.setenv("HUGMESH_GENERATOR_DIR", GENERATOR_DIR)
        monkeypatch.setattr(lai, "send_prompt", REAL_SEND_PROMPT)
        out = io.StringIO()
        rc = lai.chat_loop(io.StringIO("/where localmesh\nwipe it all and start fresh\n/quit\n"), out,
                           dict(os.environ))
        assert rc == 0
        text = out.getvalue()
        assert text.index(ap.DESTRUCTIVE_WARNING) < text.index("rm -rf")
        assert ap.DESTRUCTIVE_WARNING + "\nSources: " in text           # and first in the footer
        assert "Commands not found in the docs I read: " in text
        assert "That removes everything." in text                      # the gate flushed the rest
    finally:
        fake.close()
