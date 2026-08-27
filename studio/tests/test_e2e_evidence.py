"""The BDD evidence-manifest READER — the consumer side of a pinned contract.

Qt-FREE: the model the Studio's evidence browser renders is stdlib-only, so
`python -m hugmesh_studio --e2e-evidence` works with no display. The Qt pane is
tested separately in test_pages_e2e_evidence.py.

THE PROPERTY THAT MATTERS. *** A MANIFEST THAT LIES IS WORSE THAN NO MANIFEST ***
— a reviewer counts the rows and believes them. So the reader's verification
walks BOTH directions, and a row with no file (or a file with no row) is a
reported defect, never a row quietly filtered out of the view. Two tests plant
each direction deliberately.
"""
import json
import os

from hugmesh_studio.core import e2e_evidence


def _row(**kw):
    base = {
        "env": "docker", "interface": "browser",
        "feature": "features/x/y.feature", "scenario": "a scenario",
        "step": "I do a thing", "ordinal": 1,
        "role": None, "service": None, "platform": None, "layer": "ui",
        "failed": False, "kind": "screenshot",
        "path": "y/a-scenario/001-I-do-a-thing.png",
        "sidecar": "y/a-scenario/001-I-do-a-thing.json",
        "bytes": 10, "at": "2026-08-26T00:00:00.000Z", "note": "",
    }
    base.update(kw)
    return base


def _make_run(tmp_path, rows, write_files=True, schema=None, jsonl_only=False):
    run = tmp_path / "bdd-steps" / "run1"
    run.mkdir(parents=True)
    for r in rows:
        if not write_files:
            continue
        for rel in (r["path"], r["sidecar"]):
            if not rel:
                continue
            f = run / rel
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(b"x" * 10)
    doc = {
        "schema": schema or e2e_evidence.SUPPORTED_SCHEMA,
        "runId": "run1", "root": str(run), "generatedAt": "2026-08-26T00:00:00Z",
        "counts": {"artefacts": len(rows), "failed": 0,
                   "byEnv": {}, "byInterface": {}, "byKind": {}},
        "artefacts": rows,
    }
    if jsonl_only:
        (run / "manifest.jsonl").write_text(
            "\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
    else:
        (run / "manifest.json").write_text(json.dumps(doc), encoding="utf-8")
    return str(run)


def test_a_clean_run_verifies(tmp_path):
    run = _make_run(tmp_path, [_row()])
    man = e2e_evidence.load(run)
    assert man.ok, man.problems
    v = e2e_evidence.verify(man)
    assert v.ok, v.summary()
    assert "points at a file that exists" in v.summary()


def test_a_row_pointing_at_a_missing_file_is_caught(tmp_path):
    """DIRECTION ONE — the lie. The index claims an artefact nobody can open."""
    run = _make_run(tmp_path, [_row()])
    os.remove(os.path.join(run, "y", "a-scenario", "001-I-do-a-thing.png"))
    v = e2e_evidence.verify(e2e_evidence.load(run))
    assert not v.ok
    assert len(v.missing) == 1
    assert "MISSING file" in v.summary()


def test_an_artefact_with_no_row_is_caught(tmp_path):
    """DIRECTION TWO — the shrink. The writer drops a row and the index still
    validates against itself perfectly."""
    run = _make_run(tmp_path, [_row()])
    extra = os.path.join(run, "y", "a-scenario", "002-orphan.png")
    with open(extra, "wb") as fh:
        fh.write(b"x")
    v = e2e_evidence.verify(e2e_evidence.load(run))
    assert not v.ok
    assert v.orphans and v.orphans[0].endswith("002-orphan.png")


def test_sidecars_are_not_orphans(tmp_path):
    """Sidecars are indexed through their artefact's `sidecar` field, not as rows
    of their own. Counting them as orphans would make every healthy run look
    broken — which would train a reader to ignore the check."""
    run = _make_run(tmp_path, [_row()])
    v = e2e_evidence.verify(e2e_evidence.load(run))
    assert v.orphans == []


def test_transcripts_ARE_indexed_and_a_dropped_one_is_an_orphan(tmp_path):
    """`.cli.json` / `.studio.json` are artefacts, not sidecars — they must carry
    rows. This is the distinction the exclusion above could hide."""
    run = _make_run(tmp_path, [_row(kind="transcript",
                                    path="y/a-scenario/001-x.cli.json")])
    stray = os.path.join(run, "y", "a-scenario", "001-x.studio.json")
    with open(stray, "w", encoding="utf-8") as fh:
        fh.write("{}")
    v = e2e_evidence.verify(e2e_evidence.load(run))
    assert any(o.endswith("001-x.studio.json") for o in v.orphans)


def test_the_driver_scratch_dir_is_not_an_orphan(tmp_path):
    """runners.ts writes each grab into <run>/.driver-tmp and COPIES it into the
    run tree; the original is not an unindexed artefact."""
    run = _make_run(tmp_path, [_row()])
    scratch = os.path.join(run, ".driver-tmp")
    os.makedirs(scratch)
    with open(os.path.join(scratch, "grab-1.png"), "wb") as fh:
        fh.write(b"x")
    assert e2e_evidence.verify(e2e_evidence.load(run)).orphans == []


def test_a_row_missing_a_contract_key_is_reported(tmp_path):
    """Every key is present on every row BY CONTRACT so a consumer can index
    without existence checks. A reader that defaulted the absent one would turn
    a broken writer into a plausible-looking index."""
    bad = _row()
    del bad["interface"]
    run = _make_run(tmp_path, [bad])
    v = e2e_evidence.verify(e2e_evidence.load(run))
    assert not v.ok
    assert any("'interface'" in m for m in v.malformed)


def test_an_absolute_path_breaks_the_relocation_contract(tmp_path):
    run = _make_run(tmp_path, [_row()])
    doc = json.load(open(os.path.join(run, "manifest.json"), encoding="utf-8"))
    doc["artefacts"][0]["path"] = os.path.join(run, "y", "a-scenario",
                                               "001-I-do-a-thing.png")
    with open(os.path.join(run, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(doc, fh)
    v = e2e_evidence.verify(e2e_evidence.load(run))
    assert any("ABSOLUTE" in m for m in v.malformed)


def test_an_unknown_schema_is_reported_not_guessed_at(tmp_path):
    """Silently parsing a future shape because the field names overlap is how a
    contract rots while every consumer stays green."""
    run = _make_run(tmp_path, [_row()], schema="hugmesh.bdd.evidence-manifest/2")
    man = e2e_evidence.load(run)
    assert not man.ok
    assert any("schema" in p for p in man.problems)
    # ...but the rows are still readable, so a stale reader is useful, not dead.
    assert len(man.rows) == 1


def test_a_crashed_run_falls_back_to_the_jsonl_and_says_so(tmp_path):
    """manifest.json is materialised in AfterAll, so a crashed run has only the
    append log — which is the run most worth looking at. Refusing to read it
    would throw the evidence away; reading it silently would let a partial index
    pass for a complete one."""
    run = _make_run(tmp_path, [_row()], jsonl_only=True)
    man = e2e_evidence.load(run)
    assert len(man.rows) == 1
    assert any("manifest.jsonl" in p for p in man.problems)


def test_an_unparseable_jsonl_line_is_reported(tmp_path):
    run = _make_run(tmp_path, [_row()], jsonl_only=True)
    with open(os.path.join(run, "manifest.jsonl"), "a", encoding="utf-8") as fh:
        fh.write("{not json\n")
    man = e2e_evidence.load(run)
    assert any("unparseable" in p for p in man.problems)


def test_a_directory_that_is_not_a_run_says_so(tmp_path):
    man = e2e_evidence.load(str(tmp_path))
    assert not man.ok
    assert "not an evidence run directory" in man.problems[0]


def test_grouping_is_env_then_interface(tmp_path):
    """The nesting order IS the operator's question order: which mesh, driven
    from which front-end."""
    rows = [
        _row(env="docker", interface="browser"),
        _row(env="kind", interface="cli", kind="transcript",
             path="y/a-scenario/002-x.cli.json", sidecar="y/a-scenario/002-x.json"),
        _row(env="qemu", interface="studio", kind="widget-grab",
             path="y/a-scenario/003-x.studio.png", sidecar="y/a-scenario/003-x.json"),
    ]
    run = _make_run(tmp_path, rows)
    tree = e2e_evidence.group(e2e_evidence.load(run))
    assert sorted(tree) == ["docker", "kind", "qemu"]
    assert list(tree["kind"]) == ["cli"]
    assert list(tree["qemu"]) == ["studio"]


def test_a_row_with_no_dimension_buckets_loudly_not_silently(tmp_path):
    """A row the writer failed to dimension is exactly the row worth seeing, so
    it buckets under '<unset>' rather than being dropped."""
    run = _make_run(tmp_path, [_row(env="", interface=None)])
    tree = e2e_evidence.group(e2e_evidence.load(run))
    assert "<unset>" in tree
    assert "<unset>" in tree["<unset>"]


def test_report_counts_match_the_rows(tmp_path):
    rows = [_row(), _row(failed=True, path="y/a-scenario/002-x.png",
                         sidecar="y/a-scenario/002-x.json")]
    run = _make_run(tmp_path, rows)
    rep = e2e_evidence.report(e2e_evidence.load(run))
    assert rep["counts"]["rows"] == 2
    assert rep["counts"]["failed"] == 1
    assert rep["counts"]["byEnv"] == {"docker": 2}
    assert rep["verification"]["ok"] is True


def test_run_dirs_finds_runs_under_a_report_dir(tmp_path):
    _make_run(tmp_path, [_row()])
    found = e2e_evidence.run_dirs(str(tmp_path))
    assert len(found) == 1 and found[0].endswith("run1")
    # ...and also when pointed straight at bdd-steps/
    assert e2e_evidence.run_dirs(str(tmp_path / "bdd-steps"))


def test_row_label_marks_failure(tmp_path):
    assert "[FAILED]" in e2e_evidence.row_label(_row(failed=True))
    assert "[FAILED]" not in e2e_evidence.row_label(_row())
