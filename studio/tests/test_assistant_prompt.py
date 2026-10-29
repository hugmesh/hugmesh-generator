"""core/assistant_prompt: the budget, the drop order, the grounded send_prompt path
through the fake Ollama, the footer, the no-model fallback, and that the primer is
one text shared with the coding-agent brief.
"""
import json
import os

import pytest
from _local_ai_fake import FakeOllama

from hugmesh_studio.core import agent_context as actx
from hugmesh_studio.core import assistant_context as ac
from hugmesh_studio.core import assistant_docs as ad
from hugmesh_studio.core import assistant_prompt as ap
from hugmesh_studio.core import local_ai_status as lai

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(autouse=True)
def _state(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv(lai.GROUNDED_ENV, raising=False)


def big_history(n_messages=40, kb=20):
    per = (kb * 1024) // n_messages
    out = []
    for i in range(n_messages):
        role = "user" if i % 2 == 0 else "assistant"
        out.append({"role": role, "content": f"m{i} " + ("x" * per)})
    return out


def test_the_primer_is_the_first_part_of_the_coding_agent_context_and_under_its_cap():
    primer = actx.primer_text(GENERATOR_DIR, "/home/someone/Github")
    assert ac.tokens(primer) <= ap.CAPS["primer"]
    ctx = actx.render_context(generator_dir=GENERATOR_DIR, checkouts_root="/home/someone/Github", checkouts=[])
    assert primer in ctx and ctx.index(primer) < ctx.index("## Rules")
    for words in ("## What HugMesh is", "## The Studio", "Casdoor", "akkoma", "phpbb", "Tor",
                  "Review commits nothing", "Ollama on this machine"):
        assert words in primer, words


def test_budget_holds_under_16k_with_a_40_message_20kb_history():
    w = ac.Where(slug="domain_services", title="Domain services", domain="shop.example", tab="services",
                 domains=ac.domain_rows_from([{"name": "shop.example", "optional_services": ["tuwunel"]}]))
    p = ap.build("what services can I switch on for this domain", w, big_history(), generator_dir=GENERATOR_DIR,
                 ctx_tokens=16384)
    b = p.budget
    assert b["ctx"] == 16384 and b["reserve"] == 6000
    assert b["total"] <= 16384 - 6000, b
    for part in ("primer", "where", "options", "snippets"):
        assert b[part] <= ap.CAPS[part], (part, b[part])
    assert b["rules"] <= ap.CAPS["rules"] + 150
    assert b["history"] <= ap.CAPS["history"] and b["history"] > 0
    assert b["dropped"] == []
    assert p.history and p.history[-1]["role"] == "assistant" and p.history[0]["role"] == "user"
    assert len(p.history) % 2 == 0                         # pairs kept whole
    assert "# HugMesh primer" in p.system and "# Where the person is" in p.system
    assert "# Options on this page" in p.system and "# Snippets" in p.system and "# Change format" in p.system
    assert p.sources and all(ad.tokens(c.text) <= 700 for c in p.sources)


def test_the_rules_and_both_formats_are_sent_whole_never_cut():
    """A cap once truncated this block mid-example and dropped the diff grammar, so a
    code-edit question never got a diff (2026-10-29 eval item 20)."""
    import re
    for text in (ap.RULES, ap.CHANGE_FORMAT, ap.DIFF_FORMAT):
        # a small model copies a placeholder verbatim ("I cannot change <that> here")
        assert not re.search(r"<[a-z][^<>]*>", text), text
    whole = ap.RULES + "\n\n# Change format\n" + ap.CHANGE_FORMAT + "\n\n" + ap.DIFF_FORMAT
    assert ap.tokens(whole) <= ap.RULES_BLOCK_CAP
    w = ac.Where(slug="domain_services", title="Domain services", domain="shop.example", tab="services",
                 domains=ac.domain_rows_from([{"name": "shop.example", "optional_services": ["tuwunel"]}]))
    p = ap.build("change the footer in index.html", w, [], generator_dir=GENERATOR_DIR, ctx_tokens=16384,
                 files_block="[file: src/index.html in web-shop.example]\n<p>hi</p>\n")
    assert ap.CHANGE_FORMAT in p.system and ap.DIFF_FORMAT in p.system and ap.RULES in p.system
    assert p.budget["rules"] <= ap.RULES_BLOCK_CAP


def test_drop_order_when_the_question_itself_is_huge():
    w = ac.Where(slug="domain_services", title="Domain services", domain="shop.example")
    order = ["options", "snippets", "where", "history"]
    question = "why " * 7200                              # ~9000 tokens in a 10384-token room
    p = ap.build(question, w, big_history(), generator_dir=GENERATOR_DIR, ctx_tokens=16384)
    assert p.budget["dropped"][:2] == ["options", "snippets"]   # the page facts still fit
    kept_order = [d for d in p.budget["dropped"] if d != "history"]
    assert kept_order == order[:len(kept_order)]
    assert p.budget["where"] > 0
    assert p.budget["total"] <= 16384 - 6000
    huge = "why " * 9000                                  # the question alone fills the room
    p2 = ap.build(huge, w, big_history(), generator_dir=GENERATOR_DIR, ctx_tokens=16384)
    assert p2.budget["dropped"] == ["options", "snippets", "where", "history"]
    assert ap.FACTS_DROPPED in ap.after_answer("x", p2)


def test_trim_history_keeps_newest_pairs_whole():
    hist = [{"role": "user", "content": "a" * 100}, {"role": "assistant", "content": "b" * 100},
            {"role": "user", "content": "c" * 100}, {"role": "assistant", "content": "d" * 100}]
    kept = ap.trim_history(hist, 80)
    assert kept == hist[2:]
    assert ap.trim_history(hist, 10) == []


def test_after_answer_builds_the_footer_and_flags_commands_the_docs_lack():
    w = ac.Where(slug="localmesh", title="Local Docker mesh")
    p = ap.build("how do I stop the DevOps lane without deleting it", w, [], generator_dir=GENERATOR_DIR)
    foot = ap.after_answer("Press kind-halt. Or run make stack-reset-everything.", p)
    assert foot.startswith("Sources: STUDIO-WALKTHROUGH.md § ")
    assert "Commands not found in the docs I read: make stack-reset-everything" in foot
    assert ap.after_answer("plain", ap.Prompt("", [], [], {"no_docs": True})) == ad.NO_DOCS_SOURCES
    assert ap.after_answer("plain", ap.Prompt("", [], [], {})) == ad.NO_CHUNKS_SOURCES


def test_no_model_fallback_shows_the_best_chunk():
    w = ac.Where(slug="build", title="Review")
    p = ap.build("does continue start the build", w, [], generator_dir=GENERATOR_DIR)
    line = ap.fallback_line(p)
    assert line.startswith("Without a model I can still show the docs: STUDIO-WALKTHROUGH.md § ")


def test_no_docs_folder_still_builds_and_says_so(tmp_path):
    w = ac.Where(slug="welcome", title="HugMesh Image Studio")
    p = ap.build("what is hugmesh", w, [], generator_dir=str(tmp_path / "empty"))
    assert p.budget["no_docs"] and p.sources == [] and "# Snippets" not in p.system
    assert ap.after_answer("HugMesh is a mesh.", p) == "Sources: none (no docs folder on this machine)"
    assert ap.fallback_line(p).startswith("Without a model I can still say this much: ## What HugMesh is")


def _run_fake(monkeypatch, grounded, on_chunk_pieces):
    fake = FakeOllama()
    try:
        monkeypatch.setenv("OLLAMA_HOST", fake.host)
        if grounded:
            monkeypatch.setenv(lai.GROUNDED_ENV, "1")
        env = dict(os.environ)
        env["HUGMESH_GENERATOR_DIR"] = GENERATOR_DIR
        out = lai.send_prompt("what is hugmesh", env=env, on_chunk=on_chunk_pieces.append)
        body = next(b for m, p, b in fake.requests if p == "/api/chat")
    finally:
        fake.close()
    return out, body


def test_grounded_env_adds_a_system_message_and_a_footer_through_on_chunk(monkeypatch):
    pieces = []
    out, body = _run_fake(monkeypatch, True, pieces)
    assert body["messages"][0]["role"] == "system" and "# HugMesh primer" in body["messages"][0]["content"]
    assert body["messages"][-1] == {"role": "user", "content": "what is hugmesh"}
    assert out.startswith("Hello there") and "\n\nSources: " in out
    assert pieces[-1].startswith("\n\nSources: ")


def test_unset_grounded_env_sends_exactly_todays_body(monkeypatch):
    pieces = []
    out, body = _run_fake(monkeypatch, False, pieces)
    assert body["messages"] == [{"role": "user", "content": "what is hugmesh"}]
    assert out == "Hello there" and pieces == ["Hel", "lo ", "there"]
    assert body["options"] == {"num_ctx": 16384, "temperature": 0.2} and body["think"] is False


def test_an_explicit_system_is_never_grounded_twice(monkeypatch):
    fake = FakeOllama()
    try:
        monkeypatch.setenv("OLLAMA_HOST", fake.host)
        monkeypatch.setenv(lai.GROUNDED_ENV, "1")
        lai.send_prompt("hi", system="mine")
        body = next(b for m, p, b in fake.requests if p == "/api/chat")
        assert body["messages"][0] == {"role": "system", "content": "mine"}
        lai.send_prompt("hi", system="")
        body2 = [b for m, p, b in fake.requests if p == "/api/chat"][-1]
        assert body2["messages"] == [{"role": "user", "content": "hi"}]
    finally:
        fake.close()


def test_answer_calls_the_module_attribute_send_prompt_and_history_stays_bare(monkeypatch):
    seen = {}

    def fake(text, model=None, *, env=None, history=None, system=None, on_chunk=None, **k):
        seen.update(text=text, history=history, system=system)
        return "An answer with make stack-up."
    monkeypatch.setattr(lai, "send_prompt", fake)
    w = ac.Where(slug="localmesh", title="Local Docker mesh")
    hist = [{"role": "user", "content": "earlier"}, {"role": "assistant", "content": "earlier answer"}]
    text, prompt = ap.answer("how do I start it", w, hist, generator_dir=GENERATOR_DIR)
    assert text == "An answer with make stack-up." and seen["text"] == "how do I start it"
    assert seen["history"] == hist and "Sources:" not in json.dumps(seen["history"])
    assert "# Where the person is" in seen["system"]
    assert ap.after_answer(text, prompt).startswith("Sources: ")


def test_a_request_to_set_a_secret_gets_a_plain_footer_note_whatever_the_model_said():
    """The model may only say "I do not know" (2026-10-29 eval item 19); the footer
    always says why nothing was proposed and what this page CAN change."""
    def footer(question, answer):
        w = ac.Where(slug="domain_services", title="Domain services", domain="shop.example",
                     tab="services", question=question)
        p = ap.build(question, w, [], generator_dir=GENERATOR_DIR, ctx_tokens=16384)
        return ap.after_answer(answer, p)
    out = footer("set the root password for this domain to hunter2", "I do not know from the docs I have.")
    assert "I never set passwords, keys or tokens" in out and "services" in out and "tor" in out
    assert "hunter2" not in out
    assert "never set" not in footer("which services can I switch on?", "akkoma, tuwunel ...")
    assert "never set" not in footer("where do the node key folders end up?", "under keys-")
    blocked = footer("change the api key and turn the forum off",
                     'ok\n```change\n{"domain": "shop.example", "field": "services", "to": []}\n```')
    assert "never set" not in blocked
