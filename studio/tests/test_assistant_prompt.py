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
    # under the cap wherever the checkout lives: CI's path is longer than this box's,
    # and 602 > 600 there once (PR #832). A 100-character generator path and a
    # 40-character checkouts folder still fit.
    gen = "/" + "/".join(["checkout-folder"] * 5) + "/" + "x" * 2 + "/hugmesh-generator"
    root = "/home/a-rather-long-user-name/Github-all"
    assert len(gen) >= 100 and len(root) >= 40
    assert ac.tokens(actx.primer_text(gen, root)) <= ap.CAPS["primer"]
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
    assert out.splitlines()[-1].startswith(
        "I never set passwords, keys or tokens: you type those on the page itself, and they "
        "never reach me. I can only change these on this page: ")
    assert "hunter2" not in out
    assert "never set" not in footer("which services can I switch on?", "akkoma, tuwunel ...")
    assert "never set" not in footer("where do the node key folders end up?", "under keys-")
    blocked = footer("change the api key and turn the forum off",
                     'ok\n```change\n{"domain": "shop.example", "field": "services", "to": []}\n```')
    assert "never set" not in blocked


def test_no_call_on_the_footer_path_has_a_secret_like_name():
    """CodeQL reads the result of a call named like secret/token/password as secret data:
    secret_request_note() made every footer write (the CLI chat, the prompt command,
    draft.py) a clear-text-logging alert (PR #832 round 3, alerts 49-53). The note holds
    a fixed sentence and option names only; the names on its path must say so."""
    import ast
    import inspect
    import re
    import textwrap
    from hugmesh_studio.core import assistant_actions as aact
    names = set()
    for fn in (ap.after_answer, aact.never_set_note):
        for node in ast.walk(ast.parse(textwrap.dedent(inspect.getsource(fn)))):
            if isinstance(node, ast.Name):
                names.add(node.id)
            elif isinstance(node, ast.Attribute):
                names.add(node.attr)
            elif isinstance(node, ast.arg):
                names.add(node.arg)
    sensitive = re.compile(r"(?i)secret|token|pass(wd|word|code|phrase)|cert")
    assert "never_set_note" in names and "_NEVER_SET_NOUN_RE" in names
    assert not [n for n in names if sensitive.search(n)], sorted(names)


def test_eval_skips_only_the_sources_line_the_studio_wrote():
    """scripts/local-ai/eval.py scores must_not on what the MODEL said: the Studio's own
    Sources line (doc headings) is skipped, a line the model began with "Sources: " is
    not (the filter once dropped every such line), and the card stays scored."""
    import importlib.util
    path = os.path.join(GENERATOR_DIR, "scripts", "local-ai", "eval.py")
    spec = importlib.util.spec_from_file_location("hugmesh_local_ai_eval", path)
    ev = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ev)
    answer = "Nothing leaves this machine.\nSources: the cloud docs, I made this up"
    final = (answer + "\n\nSources: STUDIO-WALKTHROUGH.md (Target hardware — standalone and cloud)"
             "\nCommands not found in the docs I read: make cloud\nProposed change — x")
    said = ev.model_said(final, answer)
    assert said == (answer + "\n\nCommands not found in the docs I read: make cloud\nProposed change — x")
    assert "STUDIO-WALKTHROUGH" not in said and "I made this up" in said
    assert ev.model_said(answer + "\n\nSources: a.md", answer) == answer + "\n\n"
    assert ev.model_said("[error: refused]", "") == "[error: refused]"
    assert ev.model_said("plain", "plain") == "plain"


# ── round 6 (PR #832): no invented commands, a warning for delete commands, no paths ──
WIPE_ANSWER = ("To wipe it:\n1. **Stop:**\n   ```bash\n   docker-compose down\n   ```\n"
               "2. **Remove the data:**\n   ```bash\n   rm -rf ~/.hugmesh-checkouts\n   ```\n"
               "3. **Clean Docker:**\n   ```bash\n   docker system prune -a\n   ```\n")


def test_the_rules_forbid_invented_commands_and_name_the_documented_reset():
    for words in ("Never invent a shell command", "Stop & clean Docker…", "Stop mesh keeps the data",
                  "make stack-halt", "make stack-down", "never a command that deletes"):
        assert words in ap.RULES, words
    # the rules never spell a delete command a small model could copy
    assert ad.destructive_commands(ap.RULES) == [] and ad.destructive_commands(ap.CHANGE_FORMAT) == []


def test_the_warning_names_the_documented_ways_and_never_repeats_a_delete_command():
    w = ap.danger_banner(WIPE_ANSWER)
    assert w.startswith(ap.DESTRUCTIVE_WARNING) and ap.DESTRUCTIVE_WARNING.startswith("WARNING:")
    assert "Do not run them" in w and "\n" not in w
    assert "Stop & clean Docker…" in w and "make stack-down" in w and "STUDIO-WALKTHROUGH.md" in w \
        and "LOCAL-STACK.md" in w and "make stack-halt" in w
    assert w == " ".join([ap.DESTRUCTIVE_WARNING, ap.DANGER_SENTENCES["files"], ap.DANGER_SENTENCES["mesh"]])
    assert ad.destructive_commands(w) == [] and ad.destructive_commands(ap.DANGER_NOTE) == []
    assert ap.danger_banner("Press Stop & clean Docker…, or run make stack-down.") == ""


#: (answer, words its warning must carry, words it must NOT carry): the warning fits the
#: command. Round 6 pointed an `ollama rm` answer at the Docker button.
FITTED = [
    ("Run:\n```bash\nollama rm qwen3:8b\n```", ("Ollama model", "downloading it again"),
     ("Stop & clean", "stack-down", "WSL")),
    ("Unregister it with `wsl --unregister <distro-name>`.", ("WSL distro", "your checkouts", "Nothing undoes it"),
     ("Stop & clean", "Ollama")),
    ("```powershell\nRemove-Item -Recurse -Force $env:USERPROFILE\\hugmesh-generator\n```",
     ("files and folders", "check every path"), ("Stop & clean", "Ollama", "WSL")),
    ("```bash\nsudo dd if=hugmesh.img of=/dev/sdb bs=4M\n```", ("whole disk", "Flash (DESTRUCTIVE)"),
     ("Stop & clean",)),
    ("```bash\nkind delete cluster --name hugmesh\n```", ("make kind-down", "make kind-halt"),
     ("Stop & clean",)),
    ("```sql\nDROP DATABASE casdoor;\n```", ("database",), ("Stop & clean",)),
    ("```bash\ngit reset --hard origin/main\n```", ("not committed",), ("Stop & clean",)),
    ("```bash\nflatpak uninstall --delete-data org.hugmesh.Studio\n```", ("app's settings",), ("Stop & clean",)),
    ("```bash\ndocker system prune -a --volumes\n```", ("Stop & clean Docker…", "make stack-down"), ("Ollama",)),
]


@pytest.mark.parametrize("answer,want,never", FITTED)
def test_the_warning_fits_the_command(answer, want, never):
    w = ap.danger_banner(answer)
    assert w.startswith(ap.DESTRUCTIVE_WARNING), answer
    for words in want:
        assert words in w, (answer, words)
    for words in never:
        assert words not in w, (answer, words)
    assert ad.destructive_commands(w) == [], w          # never spells a command itself


def test_no_kind_sentence_spells_a_command_and_every_kind_has_one():
    assert set(ap.DANGER_SENTENCES) == set(ad.DESTRUCTIVE_KIND_ORDER)
    for kind, sentence in ap.DANGER_SENTENCES.items():
        assert ad.destructive_commands(sentence) == [], kind
        assert ad.destructive_kinds(ap.danger_banner("", [kind])) == [], kind


def test_after_answer_puts_the_warning_first_and_lists_every_invented_command():
    p = ap.Prompt("", [], [ad.Chunk("x", "docs/X.md", "X", "make stack-down # stop + drop volumes", 1.0, 5)], {})
    foot = ap.after_answer(WIPE_ANSWER, p)
    lines = foot.split("\n")
    assert lines[0] == ap.danger_banner(WIPE_ANSWER) and lines[1].startswith("Sources: ")
    bad = next(ln for ln in lines if ln.startswith("Commands not found in the docs I read: "))
    for cmd in ("docker-compose down", "rm -rf ~/.hugmesh-checkouts", "docker system prune -a"):
        assert cmd in bad, cmd
    assert ap.after_answer("Press Stop & clean Docker….", p).startswith("Sources: ")


def test_the_gate_prints_the_warning_before_the_first_delete_line_whatever_the_chunking():
    for size in (1, 3, 7, 50, len(WIPE_ANSWER)):
        shown = []
        gate = ap.WarnGate(shown.append)
        for i in range(0, len(WIPE_ANSWER), size):
            gate.feed(WIPE_ANSWER[i:i + size])
        gate.finish()
        text = "".join(shown)
        assert gate.warned and text.count(ap.DESTRUCTIVE_WARNING) == 1
        assert text.index(ap.DESTRUCTIVE_WARNING) < text.index("rm -rf")
        # the first delete block is rm -rf: the file sentence comes first, the Docker
        # one is added above the prune block that follows
        first = "\n" + ap.danger_banner("", ["files"]) + "\n\n"
        also = "\nWARNING, also: " + ap.DANGER_SENTENCES["mesh"] + "\n\n"
        assert text.index(first) < text.index("rm -rf") < text.index(also) < text.index("docker system prune")
        assert text.replace(first, "").replace(also, "") == WIPE_ANSWER
    shown = []
    gate = ap.WarnGate(shown.append)
    gate.feed("No delete here.\n```bash\nmake stack-halt\n```\nand a tail without newline")
    gate.finish()
    assert not gate.warned and "".join(shown).endswith("a tail without newline")


def test_a_grounded_stream_shows_the_warning_above_the_command(monkeypatch):
    fake = FakeOllama()
    fake.chunks = [WIPE_ANSWER[i:i + 9] for i in range(0, len(WIPE_ANSWER), 9)]
    pieces = []
    try:
        monkeypatch.setenv("OLLAMA_HOST", fake.host)
        monkeypatch.setenv(lai.GROUNDED_ENV, "1")
        env = dict(os.environ)
        env["HUGMESH_GENERATOR_DIR"] = GENERATOR_DIR
        out = lai.send_prompt("wipe everything and start fresh", env=env, on_chunk=pieces.append)
    finally:
        fake.close()
    shown = "".join(pieces)
    assert shown.index(ap.DESTRUCTIVE_WARNING) < shown.index("rm -rf")
    assert "\n\n" + ap.danger_banner(WIPE_ANSWER) + "\nSources: " in shown   # and first in the footer
    assert out.startswith(WIPE_ANSWER)                                 # the answer itself, unchanged


def test_no_absolute_home_path_reaches_the_model(tmp_path, monkeypatch):
    """Round 6: the primer named the checkouts folder and the generator checkout, and the
    model answered "wipe everything" with rm -rf of both. No part of the system message,
    and no history message, carries the home folder, the checkouts folder or the
    generator checkout as an absolute path."""
    home = tmp_path / "home" / "someone"
    root = home / "Github"
    gen = root / "hugmesh-generator"
    (gen / "docs").mkdir(parents=True)
    (gen / "docs" / "STUDIO-WALKTHROUGH.md").write_text("# W\n\n### Local Docker mesh\n\nPress Stop mesh.\n")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("HUGMESH_REPOS_ROOT", str(root))
    log = home / ".hugmesh" / "studio" / "w1" / "build.log"
    w = ac.Where(slug="localmesh", title="Local Docker mesh", mode="docker",
                 state=(("build", f"failed; log {log}"), ("code", f"{root}/hugmesh-auth-ui/src"),
                        ("elsewhere", "/home/other/x/y/z.txt")))
    hist = [{"role": "user", "content": f"is {gen} right?"},
            {"role": "assistant", "content": f"yes, {gen}/scripts/local-ai.sh and {root}"}]
    p = ap.build("How do I reset the local mesh completely?", w, hist, env=dict(os.environ),
                 generator_dir=str(gen), ctx_tokens=16384,
                 files_block=f"[file: src/index.html in {root}/web/x]\n<p>hi</p>")
    sent = p.system + "\n".join(m["content"] for m in p.history)
    for path in (str(home), str(root), str(gen), "/home/other"):
        assert path not in sent, path
    assert "~/.hugmesh/studio/w1/build.log" in sent and "hugmesh-auth-ui/src" in sent
    assert "scripts/local-ai.sh" in sent and "…/y/z.txt" in sent
    assert "## Where the local sources are" in p.primer and "checkouts folder" in p.primer
    # the primer itself names neither folder (not merely scrubbed later) and is whole
    primer = ap.primer_for(str(gen), dict(os.environ))
    assert str(gen) not in primer and str(root) not in primer and "`" + str(root) not in primer
    assert not primer.endswith("…") and ap.tokens(primer) <= ap.CAPS["primer"]
    assert primer.rstrip().endswith("or start with ~.")
    # the coding-agent brief still names both folders: it is the person's own file
    assert str(root) in actx.render_context(generator_dir=str(gen), checkouts_root=str(root), checkouts=[])


def test_scrub_paths_rewrites_each_kind_of_machine_path():
    kw = dict(generator_dir="/h/u/G/gen", checkouts_root="/h/u/G", home="/h/u")
    assert ap.scrub_paths("/h/u/G/gen", **kw) == "the generator checkout"
    assert ap.scrub_paths("in /h/u/G/gen/docs/A.md.", **kw) == "in docs/A.md."
    assert ap.scrub_paths("`/h/u/G`", **kw) == "`the checkouts folder`"
    assert ap.scrub_paths("/h/u/G/hugmesh-ui/src/a.ts", **kw) == "hugmesh-ui/src/a.ts"
    assert ap.scrub_paths("/h/u/.cache/x", **kw) == "~/.cache/x"
    # never a user name, even when the path is short
    assert ap.scrub_paths("/home/z/a/b/c.log and /Users/z/q", **kw) == "…/b/c.log and …/q"
    assert ap.scrub_paths("https://example.org/home/x/y", **kw) == "https://example.org/home/x/y"


#: (machine text, what reaches the model): STRICT, every part the machine fills in.
#: Round 6: a build output folder on another disk reached the model whole.
STRICT = [
    ("log /mnt/bigdisk/hugmesh-out/sessions/20261030-014500-ab12cd/build.log",
     "log …/20261030-014500-ab12cd/build.log"),
    ("flash to /media/someone/USB-STICK", "flash to …/USB-STICK"),
    ("/media/someone", "…"),
    ("/run/media/someone/SD/hugmesh.img", "…/SD/hugmesh.img"),
    ("located at '/var/tmp/portage/dev-lang/rust-1.80.0/temp/build.log'.", "located at '…/temp/build.log'."),
    ("C:\\Users\\someone\\hugmesh-out\\sessions\\s1\\build.log", "…\\s1\\build.log"),
    ("C:\\Users\\someone", "…"),
    ("D:/hugmesh-out/s1/build.log", "…/s1/build.log"),
    ("\\\\nas\\share\\someone\\out\\build.log", "…\\out\\build.log"),
    ("/mnt/c/Users/someone/Github/hugmesh-generator", "…/Github/hugmesh-generator"),
    ("/tmp/c832-xyz/state/w1/build.log", "…/w1/build.log"),
    ("/etc/wireguard/wg0.conf", "…/wireguard/wg0.conf"),
    ("file:///home/someone/x/y.html", "file://…/x/y.html"),
    ("see https://hugmesh.github.io/docs/a and docs/A.md", "see https://hugmesh.github.io/docs/a and docs/A.md"),
    # a folder name with a space is one path, and never leaves the rest of a name behind
    ("log /mnt/big disk/hugmesh out/build.log", "log …/hugmesh out/build.log"),
    ("C:\\Users\\someone else\\hugmesh\\out\\build.log", "…\\out\\build.log"),
    ("/cygdrive/c/Users/someone/x/y", "…/x/y"),
    ("/mnt/a/b.log and/or docs/A.md", "…/a/b.log and/or docs/A.md"),
    ("/mnt/a/b.log see https://hugmesh.github.io/x/y", "…/a/b.log see https://hugmesh.github.io/x/y"),
    # a one-part path has nothing more to cut (routes in an option's text)
    ("the /superdomain and /character-forge pages", "the /superdomain and /character-forge pages"),
]


@pytest.mark.parametrize("text,want", STRICT)
def test_strict_scrub_cuts_every_other_absolute_path_to_its_last_two_parts(text, want):
    kw = dict(generator_dir="/h/u/G/gen", checkouts_root="/h/u/G", home="/h/u")
    got = ap.scrub_paths(text, **kw)
    assert got == want, (text, got)
    assert "someone" not in got and "bigdisk" not in got and "portage" not in got


def test_doc_snippets_keep_their_documented_paths():
    """The snippets are the repo's own text (the same on every machine): only home-like
    paths are cut there, so a documented command reaches the model whole (round 6 sent
    `-v ollama:…/root/.ollama`)."""
    kw = dict(generator_dir="/h/u/G/gen", checkouts_root="/h/u/G", home="/h/u", strict=False)
    for text in ("/etc/wireguard/wg0.conf, /var/lib/docker", "docker run -d -v ollama:/root/.ollama ollama/ollama",
                 "/mnt/c is the Windows drive", "/dev/sdX"):
        assert ap.scrub_paths(text, **kw) == text, text
    assert ap.scrub_paths("/home/someone/x/y", **kw) == "…/x/y"
    assert ap.scrub_paths("/run/media/someone/USB/x.img", **kw) == "…/USB/x.img"
    assert ap.scrub_paths("/h/u/G/gen/docs/A.md", **kw) == "docs/A.md"


def test_the_files_of_a_code_edit_keep_their_routes_and_paths(tmp_path, monkeypatch):
    """A cut route in a file the model is editing makes a diff that does not apply."""
    body = "[file: src/a.ts in web-x]\nfetch('/api/foo/bar'); const logo = '/assets/img/logo.png';"
    home = tmp_path / "home" / "someone"
    home.mkdir(parents=True)
    monkeypatch.setenv("HOME", str(home))
    p = ap.build("change the fetch url", ac.Where(slug="localmesh", title="x"), [], env=dict(os.environ),
                 generator_dir=GENERATOR_DIR, ctx_tokens=16384, files_block=body + f" /* {home}/x/y */")
    assert body in p.system and str(home) not in p.system and "~/x/y" in p.system


def test_a_build_output_folder_on_another_disk_never_reaches_the_model(tmp_path, monkeypatch):
    """Round 6: cfg.output_dir on /mnt put `log /mnt/bigdisk/...` and the error tail's
    /var/tmp/portage and /media/<user> paths into the system message unchanged."""
    import json as _json
    home = tmp_path / "home" / "someone"
    state = tmp_path / "state"
    (state / "sessions").mkdir(parents=True)
    home.mkdir(parents=True)
    work = "/mnt/bigdisk/hugmesh-out/sessions/20261030-014500-ab12cd"
    (state / "sessions" / "s1.json").write_text(_json.dumps({
        "id": "s1", "label": "mesh backend x86", "status": "failed", "images": ["backend.x86"],
        "log_path": work + "/build.log", "workdir": work,
        "error_tail": {"backend.x86": [
            "emerge: failed to build dev-lang/rust",
            " * The complete build log is located at '/var/tmp/portage/dev-lang/rust-1.80.0/temp/build.log'.",
            "cp: cannot stat '/run/media/someone/STICK/hugmesh.img'",
            "see /media/someone/USB/log.txt"]}}))
    monkeypatch.setenv("HOME", str(home))
    rows = ac.build_rows(str(state))
    assert any(work in v for _, v in rows)                    # the facts DO carry it ...
    w = ac.Where(slug="progress", title="Build progress", state=tuple(rows))
    p = ap.build("Why did my build fail, and where is the full log?", w, [], env=dict(os.environ),
                 generator_dir=GENERATOR_DIR, ctx_tokens=16384)
    sent = p.system + "\n".join(m["content"] for m in p.history)
    for leak in ("/mnt/", "bigdisk", "hugmesh-out", "/var/tmp", "portage/dev-lang", "/media/", "someone"):
        assert leak not in sent, leak                         # ... the model never sees it
    assert "…/20261030-014500-ab12cd/build.log" in sent and "…/temp/build.log" in sent


def _eval_module():
    import importlib.util
    path = os.path.join(GENERATOR_DIR, "scripts", "local-ai", "eval.py")
    spec = importlib.util.spec_from_file_location("hugmesh_local_ai_eval", path)
    ev = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ev)
    return ev


def test_eval_scores_the_model_not_the_warning_and_counts_wrong_cards_and_unwarned_deletes():
    """Round 6: eval.py must catch the two final-round blockers by itself. The warning's
    own words (Stop & clean Docker…, make stack-down) never count as the model's; its
    delete-command check uses its OWN word list; a forum-off item whose card is the Tor
    example is a WRONG CARD and FAILs, whatever the aggregate says."""
    ev = _eval_module()
    p = ap.Prompt("", [], [], {})
    foot = ap.after_answer(WIPE_ANSWER, p)
    final = WIPE_ANSWER + "\n\n" + foot
    said = ev.model_said(final, WIPE_ANSWER)
    assert ap.DESTRUCTIVE_WARNING not in said and "Stop & clean" not in said
    assert ev.looks_destructive(WIPE_ANSWER) and ap.DESTRUCTIVE_WARNING in final
    for word in ev.DANGER_WORDS:                       # independent of assistant_docs ...
        assert word.strip() and word not in ("prune", "delete")
    for safe in ("Press Stop & clean Docker…, then Generate & start.", "make stack-down",
                 "ArgoCD auto-sync prunes and self-heals.", "Delete DevOps lane removes the cluster."):
        assert not ev.looks_destructive(safe), safe
    from hugmesh_studio.core import assistant_actions as aact
    with open(os.path.join(GENERATOR_DIR, "scripts", "local-ai", "eval-items.json"), encoding="utf-8") as fh:
        items = json.load(fh)
    forum = [it for it in items if "forum" in it["question"] or "phpBB" in it["question"]]
    assert len(forum) >= 3 and all(it.get("card_must_be") for it in forum)
    wipes = [it for it in items if it.get("model_mention_any")]
    assert len(wipes) >= 5 and all("/home/" in it["must_not"] for it in wipes)
    item = forum[0]
    w = ac.Where(face="gui", slug="domain_services", title="Domain services", domain="shop.example",
                 tab="services")

    class Reader:
        id, domain, own = "eval", "shop.example", False

        def read(self, route, key):
            return {"services": ["tuwunel", "phpbb"], "tor": False}[route]

    import types
    fx = types.SimpleNamespace()                       # score() reads no fixture for these
    real = ev.ReaderTarget
    ev.ReaderTarget = lambda _fx: Reader()
    try:
        tor = 'I can give shop.example its own Tor address.\n```change\n{"domain": "shop.example", "field": "tor", "to": true}\n```'
        *_, card, wrong = ev.score(item, tor, tor, fx, w)
        assert card.startswith("Proposed change") and wrong
        ok = 'Unticking phpbb.\n```change\n{"domain": "shop.example", "field": "services", "to": ["tuwunel"]}\n```'
        *_, card, wrong = ev.score(item, ok, ok, fx, w)
        assert card.startswith("Proposed change") and not wrong
        copied = "x\n```change\n" + json.dumps(aact.EXAMPLE_PROPOSAL) + "\n```"
        *_, card, wrong = ev.score(item, copied, copied, fx, w)
        assert not card.startswith("Proposed change") and not wrong     # refused: no card, not wrong
    finally:
        ev.ReaderTarget = real
