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


def test_prompt_with_a_bad_local_ai_ctx_is_one_sentence_and_exit_one(fake, env, capsys):
    env.setenv("OLLAMA_HOST", fake.host)
    env.setenv("LOCAL_AI_CTX", "16k")
    rc, out, err = cli(["--local-ai-prompt", "hi"], capsys)
    assert rc == 1 and out == "" and err.startswith("error: ") and "LOCAL_AI_CTX" in err
    assert "Traceback" not in err and err.count("\n") == 1


@pytest.mark.parametrize("blank", ["", "   ", "\n\t "])
def test_a_blank_prompt_is_usage_and_exit_two_and_asks_nothing(fake, env, capsys, blank):
    # The module's own ``prompt`` command and the dock both refuse an empty question;
    # the flag used to send it to the model and exit 0.
    env.setenv("OLLAMA_HOST", fake.host)
    rc, out, err = cli(["--local-ai-prompt", blank], capsys)
    assert rc == 2 and out == "" and err.startswith("usage:") and "--local-ai-prompt" in err
    assert not [r for r in fake.requests if r[1] == "/api/chat"]


def test_prompt_refuses_a_non_loopback_host(env, capsys):
    env.setenv("OLLAMA_HOST", "203.0.113.9:11434")
    rc, out, err = cli(["--local-ai-prompt", "hi"], capsys)
    assert rc == 1 and "loopback" in err


def test_the_flags_are_documented_next_to_print_specs():
    readme = open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                               "README.md"), encoding="utf-8").read()
    assert "--local-ai-status" in readme and "--local-ai-prompt" in readme
    assert readme.index("--local-ai-status") > readme.index("--scan-hardware")


# ── the grounded assistant's command-line faces (2026-10-29) ─────────────────────────
STUDIO_ROOT_ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def test_prompt_is_unchanged_unless_grounded_and_then_carries_a_system_and_a_footer(fake, env, capsys):
    env.setenv("OLLAMA_HOST", fake.host)
    env.delenv("LOCAL_AI_GROUNDED", raising=False)
    rc, out, err = cli(["--local-ai-prompt", "what is hugmesh"], capsys)
    body = [r[2] for r in fake.requests if r[1] == "/api/chat"][-1]
    assert rc == 0 and out.strip() == "Hello there" and body["messages"] == [{"role": "user", "content": "what is hugmesh"}]
    env.setenv("LOCAL_AI_GROUNDED", "1")
    env.setenv("HUGMESH_GENERATOR_DIR", os.path.dirname(STUDIO_ROOT_))
    rc, out, err = cli(["--local-ai-prompt", "what is hugmesh"], capsys)
    body = [r[2] for r in fake.requests if r[1] == "/api/chat"][-1]
    assert rc == 0 and body["messages"][0]["role"] == "system"
    assert "# HugMesh primer" in body["messages"][0]["content"] and "- face: command line (cli)" in body["messages"][0]["content"]
    assert out.startswith("Hello there") and "\nSources: " in out


def test_catalogue_and_docs_need_no_model(env, capsys):
    from hugmesh_studio.core import local_ai_status as lai_mod
    import io
    out = io.StringIO()
    assert lai_mod.main(["catalogue", "domain"], out=out, err=io.StringIO()) == 0
    text = out.getvalue()
    for key in ("services", "signin", "tor", "tailnet", "egress", "look.preset", "look.primary", "github_org"):
        assert f"\n- {key} (" in text, key
    err = io.StringIO()
    assert lai_mod.main(["catalogue", "nope"], out=io.StringIO(), err=err) == 2 and "usage" in err.getvalue()
    env.setenv("HUGMESH_GENERATOR_DIR", os.path.dirname(STUDIO_ROOT_))
    out = io.StringIO()
    assert lai_mod.main(["docs", "how", "do", "I", "stop", "the", "DevOps", "lane", "without", "deleting", "it"],
                        out=out, err=io.StringIO()) == 0
    text = out.getvalue()
    assert "[doc: STUDIO-WALKTHROUGH.md § Stopping the DevOps lane without deleting it]" in text
    assert text.rstrip().split("\n")[-1].startswith("Sources: STUDIO-WALKTHROUGH.md § ")
    err = io.StringIO()
    assert lai_mod.main(["docs"], out=io.StringIO(), err=err) == 2 and "usage: docs" in err.getvalue()
    env.setenv("HUGMESH_GENERATOR_DIR", str(env._setitem[0][0]) if False else os.path.join(os.environ["HUGMESH_STUDIO_STATE_DIR"], "nodocs"))
    os.makedirs(os.environ["HUGMESH_GENERATOR_DIR"], exist_ok=True)
    out = io.StringIO()
    assert lai_mod.main(["docs", "what", "is", "hugmesh"], out=out, err=io.StringIO()) == 0
    assert out.getvalue().strip() == "Sources: none (no docs folder on this machine)"


def test_the_shell_script_lists_the_new_verbs_and_grounds_prompt_and_chat():
    path = os.path.join(os.path.dirname(STUDIO_ROOT_), "scripts", "local-ai.sh")
    with open(path, encoding="utf-8") as fh:
        sh = fh.read()
    assert "LOCAL_AI_GROUNDED=1 la_py chat" in sh and 'LOCAL_AI_GROUNDED=1 la_py prompt "$@"' in sh
    assert 'docs)          shift; la_py docs "$@" ;;' in sh and 'catalogue)     shift; la_py catalogue "$@" ;;' in sh
    assert "scripts/local-ai.sh docs" in sh and "scripts/local-ai.sh catalogue" in sh


# ── round 7 (PR #832): every command-line face warns, grounded or not ────────────────
#: What the bare --local-ai-prompt printed in round 6 for "Docker is eating my drive",
#: with no warning (it was not grounded, and only the grounded path had the gate).
PRUNE = ("To free space:\n```bash\ndocker container prune\ndocker volume prune\n"
         "docker image prune -a\n```\nThen check `docker system df`.\n")


def _ungrounded(env, fake):
    env.setenv("OLLAMA_HOST", fake.host)
    env.delenv("LOCAL_AI_GROUNDED", raising=False)
    fake.chunks = [PRUNE[i:i + 6] for i in range(0, len(PRUNE), 6)]


def _warned_above(out):
    from hugmesh_studio.core import assistant_prompt as ap
    assert out.count(ap.DESTRUCTIVE_WARNING) == 1, out
    assert out.index(ap.DESTRUCTIVE_WARNING) < out.index("docker container prune"), out
    assert "Stop & clean Docker…" in out and "Ollama model" not in out
    assert out.replace("\n" + ap.danger_banner(PRUNE) + "\n\n", "").rstrip("\n") == PRUNE.rstrip("\n")


def test_the_bare_prompt_flag_prints_the_warning_above_a_delete_command(fake, env, capsys):
    _ungrounded(env, fake)
    rc, out, err = cli(["--local-ai-prompt", "How do I free up disk space? Docker is eating my drive."], capsys)
    assert rc == 0 and err == ""
    _warned_above(out)
    body = [r for r in fake.requests if r[1] == "/api/chat"][-1][2]
    assert [m["role"] for m in body["messages"]] == ["user"]      # still bare: no system message


def test_local_ai_status_prompt_and_chat_warn_when_not_grounded(fake, env, capsys):
    import io
    from hugmesh_studio.core import local_ai_status as lai
    _ungrounded(env, fake)
    out = io.StringIO()
    assert lai.main(["prompt", "free up disk space"], out=out, err=io.StringIO()) == 0
    _warned_above(out.getvalue())
    out = io.StringIO()
    assert lai.chat_loop(io.StringIO("free up disk space\n/quit\n"), out, dict(os.environ)) == 0
    text = out.getvalue()
    _warned_above(text.split("> ", 1)[1].rsplit("> ", 1)[0])   # what one answer printed


def test_a_harmless_bare_answer_streams_unchanged(fake, env, capsys):
    env.setenv("OLLAMA_HOST", fake.host)
    env.delenv("LOCAL_AI_GROUNDED", raising=False)
    fake.chunks = ["Press Stop & clean ", "Docker… on the Local", " Docker mesh step."]
    rc, out, err = cli(["--local-ai-prompt", "how do I start over?"], capsys)
    assert rc == 0 and out == "Press Stop & clean Docker… on the Local Docker mesh step.\n"
