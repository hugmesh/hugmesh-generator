"""core/assistant_docs: chunking, ranking, cache, sources and command checks.

A planted docs tree pins the mechanics; the real corpus pins that the walkthrough's
page sections are found for each eval question (slow, but part of the gate) and that
a generator dir with NO docs folder still works and says so.
"""
import os
import time

import pytest

from hugmesh_studio.core import assistant_context as ac
from hugmesh_studio.core import assistant_docs as ad

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _gen(tmp_path, **files):
    gen = tmp_path / "gen"
    for rel, text in files.items():
        p = gen / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    return gen


WALK = """# Walkthrough

## Getting in

Start the Studio.

### Domain services

Tick the services this domain runs: akkoma, tuwunel, phpbb. The Ways to reach it tab
holds the Tor address.

### Review

Nothing starts here. Continue commits nothing.

## Current State

Old notes that must never be indexed.
"""


def test_chunks_follow_headings_and_carry_file_heading_and_weight(tmp_path):
    gen = _gen(tmp_path, **{"docs/STUDIO-WALKTHROUGH.md": WALK})
    idx = ad.build_index(str(gen))
    ids = [c.id for c in idx.chunks]
    assert "docs/STUDIO-WALKTHROUGH.md#Domain services" in ids
    assert "docs/STUDIO-WALKTHROUGH.md#Review" in ids
    assert not any("Current State" in i for i in ids)
    c = next(c for c in idx.chunks if c.heading == "Domain services")
    assert c.file == "docs/STUDIO-WALKTHROUGH.md" and c.weight == 1.0 and c.tokens == ac.tokens(c.text)
    assert c.label == "STUDIO-WALKTHROUGH.md § Domain services"


def test_a_long_section_is_split_on_blank_lines_into_parts_of_the_same_heading(tmp_path):
    paras = "\n\n".join(f"Paragraph {i} " + "word " * 150 for i in range(12))
    gen = _gen(tmp_path, **{"docs/STUDIO-WALKTHROUGH.md": "## Big\n\n" + paras + "\n"})
    idx = ad.build_index(str(gen))
    parts = [c for c in idx.chunks if c.heading == "Big"]
    assert len(parts) >= 2
    assert all(300 <= c.tokens <= 700 for c in parts[:-1]), [c.tokens for c in parts]
    assert all(c.tokens <= 700 for c in parts)
    assert [c.part for c in parts] == list(range(len(parts)))
    assert parts[0].id.endswith("(part 1)")


def test_excluded_files_and_readme_sections_are_never_indexed(tmp_path):
    gen = _gen(tmp_path, **{
        "docs/STUDIO-WALKTHROUGH.md": "## A\n\nok\n",
        "docs/HANDOFF.md": "## Secret plans\n\nnever\n",
        "docs/ROADMAP.md": "## Roadmap\n\nnever\n",
        "docs/manual-test-evidence/x.md": "## Evidence\n\nnever\n",
        "README.md": "## Quick start\n\nyes\n\n## Current State\n\nnever\n\n## Contributing\n\nnever\n",
    })
    idx = ad.build_index(str(gen))
    text = " ".join(c.text for c in idx.chunks)
    assert "never" not in text and "yes" in text and "ok" in text
    assert [c.heading for c in idx.chunks if c.file == "README.md"] == ["Quick start"]
    assert ad._excluded_file("docs/HANDOFF.md") and ad._excluded_file("docs/BINPKG-x.md")
    assert not ad._excluded_file("docs/STUDIO-WALKTHROUGH.md")


def test_bm25_ranks_the_matching_section_first_and_the_title_boost_adds(tmp_path):
    gen = _gen(tmp_path, **{"docs/STUDIO-WALKTHROUGH.md": WALK})
    idx = ad.build_index(str(gen))
    top = ad.retrieve("which services can I tick for this domain", index=idx)
    assert top[0].heading == "Domain services"
    # on the Review page, a vague question still brings the page's own section along
    class W:
        title, slug = "Review", "build"
    got = ad.retrieve("what happens next", W, index=idx)
    assert any(c.heading == "Review" for c in got)
    scores = {c.heading: s for s, c in ad.scored(idx, "what happens next", W)}
    assert scores["Review"] >= 1.5


def test_the_cache_is_rebuilt_only_when_a_file_changes(tmp_path, monkeypatch):
    gen = _gen(tmp_path, **{"docs/STUDIO-WALKTHROUGH.md": WALK})
    state = tmp_path / "state"
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(state))
    calls = []
    real = ad.build_index
    monkeypatch.setattr(ad, "build_index", lambda g=None: calls.append(g) or real(g))
    ad.load_index(str(gen))
    ad.load_index(str(gen))
    assert len(calls) == 1 and os.path.isfile(ad.cache_path(str(state)))
    time.sleep(1.1)
    (gen / "docs" / "STUDIO-WALKTHROUGH.md").write_text(WALK + "\n### More\n\nnew words here\n")
    idx = ad.load_index(str(gen))
    assert len(calls) == 2 and any(c.heading == "More" for c in idx.chunks)


def test_sources_line_dedupes_in_rank_order_and_says_none_in_words():
    a = ad.Chunk("f#A", "docs/A.md", "A", "x", 1.0, 1)
    b = ad.Chunk("f#B (part 2)", "docs/B.md", "B", "y", 1.0, 1, 1)
    assert ad.sources_line([a, b, a]) == "Sources: A.md § A; B.md § B"
    assert ad.sources_line([]) == ad.NO_CHUNKS_SOURCES
    assert ad.sources_line([], index=ad.Index()) == ad.NO_DOCS_SOURCES


def test_commands_in_and_unverified_commands():
    text = ("Run `make stack-up` then scripts/local-ai.sh start. Then ollama pull qwen3:8b and "
            "docker compose up -d; never git push origin main.")
    assert ad.commands_in(text) == {"make stack-up", "scripts/local-ai.sh start", "ollama pull qwen3:8b",
                                    "docker compose up -d", "git push origin main"}
    chunk = ad.Chunk("x", "docs/X.md", "X", "Start it with  make stack-up  and watch.", 1.0, 5)
    bad = ad.unverified_commands(text, [chunk], primer="scripts/local-ai.sh start is the launcher")
    assert bad == ["docker compose up -d", "git push origin main", "ollama pull qwen3:8b"]
    assert ad.unverified_commands("no commands here", [chunk]) == []


def test_fallback_text_shows_the_best_chunk_or_the_primer():
    c = ad.Chunk("f#Review", "docs/W.md", "Review", "Nothing starts here. " * 30, 1.0, 10)
    out = ad.fallback_text([c])
    assert out.startswith("Without a model I can still show the docs: W.md § Review — “Nothing starts here.")
    assert len(out) < 420
    assert ad.fallback_text([], "The primer.\n\nMore.", index=ad.Index()).endswith("The primer.")


def test_no_docs_folder_is_a_working_configuration(tmp_path, monkeypatch):
    gen = tmp_path / "empty"
    gen.mkdir()
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    idx = ad.load_index(str(gen))
    assert idx.empty and "docs/STUDIO-WALKTHROUGH.md" in idx.missing
    assert ad.retrieve("what is hugmesh", index=idx) == []
    assert ad.sources_line([], index=idx) == "Sources: none (no docs folder on this machine)"


def test_generator_dir_env_wins_over_the_package_location(tmp_path, monkeypatch):
    monkeypatch.setenv(ad.GENERATOR_ENV, str(tmp_path))
    assert ad.generator_dir("/somewhere/else") == str(tmp_path)
    monkeypatch.delenv(ad.GENERATOR_ENV)
    assert ad.generator_dir() == GENERATOR_DIR


# ── the real corpus (slow, in the gate) ──────────────────────────────────────────────
EXPECTED = [
    ("welcome", "What is HugMesh, and what does this Studio actually do for me?",
     "STUDIO-WALKTHROUGH.md § Welcome"),
    ("mode", "Which of these cards actually build an image and which are just tools?",
     "STUDIO-WALKTHROUGH.md § What do you want to build?"),
    ("domain_services", "What services can I switch on for this domain?",
     "STUDIO-WALKTHROUGH.md § Domain services"),
    ("domain_services", "How do I give this domain its own Tor address?",
     "STUDIO-WALKTHROUGH.md § Domain services"),
    ("localmesh", "How do I stop the DevOps lane without deleting the cluster?",
     "STUDIO-WALKTHROUGH.md § Stopping the DevOps lane without deleting it"),
    ("review", "Does pressing Continue on this page start the build?",
     "STUDIO-WALKTHROUGH.md § Review"),
    ("progress", "My build failed. Where is the log and what went wrong?",
     "STUDIO-WALKTHROUGH.md § Building"),
    ("sessions", "Where do I see my previous builds and their errors?",
     "STUDIO-WALKTHROUGH.md § Prior sessions"),
    ("vault", "Do I have to fill in a KV mount or a base path on this Secrets store page?",
     "STUDIO-WALKTHROUGH.md § Secrets store"),
    ("localmesh_env", "What is the difference between test and prod here?",
     "LOCAL-STACK.md § ENV = test vs prod"),
]


@pytest.mark.slow
def test_the_real_corpus_indexes_fast_and_finds_each_pages_section(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    t0 = time.monotonic()
    idx = ad.load_index(GENERATOR_DIR)
    assert time.monotonic() - t0 < 2.0
    assert len(idx.chunks) > 300 and not idx.missing
    assert all(c.tokens <= 700 for c in idx.chunks)
    for slug, question, want in EXPECTED:
        class W:
            pass
        W.slug, W.title = slug, ad.TITLE_ALIASES.get(slug, slug)
        got = [c.label for c in ad.retrieve(question, W, index=idx)]
        assert any(g.startswith(want) for g in got), (question, got)
