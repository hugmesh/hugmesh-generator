"""``--local-ai-status`` and ``--local-ai-prompt``: the command-line twin of the dock.

Run against a fake Ollama on loopback (never the host's). The status flag prints what the
Studio window's Local AI bar shows and exits non-zero, with a plain sentence on stderr,
when Ollama is down; the prompt flag prints the model's answer or the same kind of
sentence.
"""
import json
import os

import pytest
from _local_ai_fake import FakeOllama

from hugmesh_studio import app as studio_app


@pytest.fixture
def fake():
    f = FakeOllama()
    yield f
    f.close()


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_LOCAL_AI_DIR", str(tmp_path / "localai"))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "studio"))
    monkeypatch.delenv("LOCAL_AI_MODEL", raising=False)
    return monkeypatch


def cli(args, capsys):
    rc = studio_app.main(args)
    cap = capsys.readouterr()
    return rc, cap.out, cap.err


def test_status_prints_the_dock_text_and_exits_zero(fake, env, capsys):
    env.setenv("OLLAMA_HOST", fake.host)
    rc, out, err = cli(["--local-ai-status"], capsys)
    assert rc == 0 and out.startswith("Local AI: ready, qwen3:8b loaded, idle") and err == ""
    rc, out, err = cli(["--local-ai-status", "--json"], capsys)
    data = json.loads(out)
    assert rc == 0 and data["ok"] is True and data["loaded"] == ["qwen3:8b"] and data["schema"] == 1


def test_status_exits_non_zero_with_a_sentence_when_ollama_is_down(env, capsys):
    env.setenv("OLLAMA_HOST", "127.0.0.1:1")
    rc, out, err = cli(["--local-ai-status"], capsys)
    assert rc == 1 and err.startswith("error: Ollama") and "scripts/local-ai.sh up" in err
    assert "docs/LOCAL-AI-ASSISTANT.md" in err
    assert "Problem:" in out                         # the screen still says what it can
    rc, out, err = cli(["--local-ai-status", "--json"], capsys)
    assert rc == 1 and json.loads(out)["ok"] is False


@pytest.mark.parametrize("how", [("cut_tags", True), ("garbage_tags", True),
                                 ("tags_body", b"[]"), ("tags_body", b"null")],
                         ids=["cut", "garbage", "json-list", "json-null"])
def test_status_says_what_is_wrong_when_ollama_dies_mid_reply(fake, env, capsys, how):
    """A server that drops the connection mid-reply, or answers bytes that are not
    HTTP, raises an HTTPException (not an OSError) inside urllib; one that answers
    valid JSON that is not an object used to raise AttributeError from ``.get``. The
    flag promises "exits 1 with the problem and its fix": a traceback is neither."""
    setattr(fake, *how)
    env.setenv("OLLAMA_HOST", fake.host)
    rc, out, err = cli(["--local-ai-status"], capsys)
    assert rc == 1 and err.startswith("error: Ollama") and "scripts/local-ai.sh up" in err
    assert "Traceback" not in err and "Problem:" in out
    rc, out, err = cli(["--local-ai-status", "--json"], capsys)
    assert rc == 1 and json.loads(out)["ok"] is False and json.loads(out)["ollama_up"] is False


@pytest.mark.parametrize("how", [("cut_ps", True), ("garbage_ps", True), ("ps_body", b"[]")],
                         ids=["cut", "garbage", "json-list"])
def test_status_exits_zero_when_only_the_loaded_models_lookup_is_unwell(fake, env, capsys, how):
    """/api/tags is healthy, /api/ps is not: the server is up with a model pulled and
    nothing is known to be loaded. Exit 0, no traceback, the line says no model loaded."""
    setattr(fake, *how)
    env.setenv("OLLAMA_HOST", fake.host)
    rc, out, err = cli(["--local-ai-status"], capsys)
    assert rc == 0 and err == "" and out.startswith("Local AI: ready, no model loaded, idle")
    rc, out, err = cli(["--local-ai-status", "--json"], capsys)
    assert rc == 0 and json.loads(out)["ollama_up"] is True and json.loads(out)["loaded"] == []


def test_status_lists_a_finished_draft(fake, env, capsys, tmp_path):
    env.setenv("OLLAMA_HOST", fake.host)
    d = tmp_path / "localai" / "drafts" / "hugmesh-generator-7"
    d.mkdir(parents=True)
    (d / "STATUS").write_text("applied files=1 diff_lines=9\n")
    (d / "draft.diff").write_text("--- a\n+++ b\n")
    rc, out, err = cli(["--local-ai-status"], capsys)
    assert rc == 0 and "hugmesh-generator-7" in out and "applied" in out


def test_prompt_prints_the_answer(fake, env, capsys):
    env.setenv("OLLAMA_HOST", fake.host)
    rc, out, err = cli(["--local-ai-prompt", "say hello"], capsys)
    assert rc == 0 and out.strip() == "Hello there" and err == ""
    assert [r[2]["messages"][-1]["content"] for r in fake.requests if r[1] == "/api/chat"] == ["say hello"]


def test_prompt_exits_non_zero_with_a_sentence_when_ollama_is_down(env, capsys):
    env.setenv("OLLAMA_HOST", "127.0.0.1:1")
    rc, out, err = cli(["--local-ai-prompt", "hi"], capsys)
    assert rc == 1 and out == "" and err.startswith("error: Ollama is not answering")


def test_prompt_refuses_a_non_loopback_host(env, capsys):
    env.setenv("OLLAMA_HOST", "203.0.113.9:11434")
    rc, out, err = cli(["--local-ai-prompt", "hi"], capsys)
    assert rc == 1 and "loopback" in err


def test_the_flags_are_documented_next_to_print_specs():
    readme = open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                               "README.md"), encoding="utf-8").read()
    assert "--local-ai-status" in readme and "--local-ai-prompt" in readme
    assert readme.index("--local-ai-status") > readme.index("--scan-hardware")
