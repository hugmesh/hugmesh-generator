"""B-WORDS: the seven words of the brand model are written once (hugmesh-generator#654, D1).

1. The word table the screens read (core/plain_words.WORDS, as (term, meaning) rows)
   EQUALS the table in docs/BRAND-MODEL.md ("## The seven words"), row for row, in
   order.
2. No window page or text screen (hugmesh_studio/gui, tui) spells one of the
   distinctive terms itself without reading the table: a module whose text says
   "superbrand", "internal root name", "ways to reach" or "Open public ports 80 and
   443" must import plain_words. (The short words brand, sign-in and Go live are too
   common to guard by text search; the table and the document carry them.) The seven
   house words D1 bans on brand screens are NOT searched for over today's screens:
   screens this lane does not own still say some of them, and a guard that is red on
   main teaches everyone to ignore it. They are exported for the screen lanes as
   plain_words.FORBIDDEN_ON_SCREENS.
3. SELF-CHECK: the same comparison against a copy of the document with one meaning
   changed must FAIL, so a comparison that cannot go red is caught here and not months
   later.

A wording check, not an end-to-end test. Lives with the Studio's pytest suite (the
pre-merge gate already runs it) rather than as a tests/scripts/*.sh suite, which the
pipeline files this lane does not own would have had to list.
"""
from __future__ import annotations

import os
import re

import pytest

from hugmesh_studio.core import plain_words

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
DOC = os.path.join(GENERATOR_DIR, "docs", "BRAND-MODEL.md")
PACKAGE = os.path.join(STUDIO_ROOT, "hugmesh_studio")

#: The terms distinctive enough to search the screens for.
DISTINCTIVE_TERMS = ("superbrand", "internal root name", "ways to reach",
                     "Open public ports 80 and 443")


def document_rows(text: str) -> list[tuple[str, str]]:
    """The (term, meaning) rows of the document's '## The seven words' table."""
    m = re.search(r"^## The seven words\n(.*?)(?=^## )", text, re.S | re.M)
    assert m, "the document has no '## The seven words' section"
    rows: list[tuple[str, str]] = []
    for line in m.group(1).splitlines():
        if not line.startswith("|") or set(line.replace("|", "").strip()) <= {"-"}:
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if cells[:2] == ["Word", "Meaning"]:
            continue
        rows.append((cells[0], cells[1]))
    return rows


def table_rows() -> list[tuple[str, str]]:
    return [(t, meaning) for _k, t, meaning in plain_words.WORDS]


def test_the_word_table_equals_the_documents_table_row_for_row():
    with open(DOC, encoding="utf-8") as fh:
        rows = document_rows(fh.read())
    assert len(rows) == 7
    assert rows == table_rows()


def test_a_changed_meaning_in_the_document_turns_the_comparison_red():
    """Self-check: the comparison above can go red."""
    with open(DOC, encoding="utf-8") as fh:
        doc = fh.read()
    mutated = doc.replace("start the Tor addresses; it opens no public port",
                          "start the Tor addresses and open the public ports")
    assert mutated != doc, "the mutation changed nothing (the Go live row moved?)"
    assert document_rows(mutated) != table_rows()
    # and a dropped row is seen as well
    rows = document_rows(doc)
    assert rows[:-1] != table_rows()


def test_every_screen_module_that_says_a_distinctive_term_reads_the_table():
    offenders: list[str] = []
    for sub in ("gui", "tui"):
        for root, _dirs, files in os.walk(os.path.join(PACKAGE, sub)):
            for fn in files:
                if not fn.endswith(".py"):
                    continue
                path = os.path.join(root, fn)
                with open(path, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
                low = text.lower()
                if any(t.lower() in low for t in DISTINCTIVE_TERMS) and "plain_words" not in text:
                    offenders.append(os.path.relpath(path, STUDIO_ROOT))
    assert offenders == [], ("screen modules that spell a term without reading "
                             "plain_words: " + ", ".join(sorted(offenders)))


def test_the_table_and_its_lookups_agree():
    assert plain_words.WORD_KEYS == tuple(k for k, _t, _m in plain_words.WORDS)
    for k, t, m in plain_words.WORDS:
        assert plain_words.term(k) == t and plain_words.meaning(k) == m
    with pytest.raises(KeyError):
        plain_words.term("tenant")
    # every way and path show-record prints has an effect sentence, and none of the
    # sentences says a word the screens forbid
    for way, _label in plain_words.WAYS:
        for path, _plabel in plain_words.PATHS:
            sentence = plain_words.WAY_EFFECT[(way, path)]
            assert sentence
            for word in plain_words.FORBIDDEN_ON_SCREENS:
                assert not re.search(rf"\b{word}\b", sentence.lower()), (way, path, word)
