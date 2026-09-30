"""e2e_evidence.py — READ the BDD run's evidence manifest, so the Studio can browse it.

WHAT THIS CONSUMES. tests/e2e/steps/evidence.ts writes, per Gherkin step, an
ordinal-prefixed artefact plus a JSON sidecar under

    ${SNAP_REPORT_DIR:-test-results}/bdd-steps/<runId>/<feature>/<scenario>/

and indexes every one of them in ``manifest.json`` (materialised in AfterAll from
the ``manifest.jsonl`` append log). That manifest is a PINNED CONTRACT — schema
``hugmesh.bdd.evidence-manifest/1``, every key present on every row, paths
RELATIVE to ``root`` — and this module is the consumer that contract was written
for. The pinned oracle is tests/e2e/evidence-manifest.schema.json.

WHY A READER AND NOT A GLOB. The Studio already had a screenshot browser that
listed PNGs off the filesystem and labelled each one with HOW it had been linked
to a test, because per-STEP data did not exist. It does now, and it carries the
environment and the interface the step ran on — which is the entire point of the
operator's ask ("screenshots in docker, local devops, and qemu ... through cli
and gui"). Grouping the real index by env × interface is what turns a pile of
PNGs into an answer.

*** THE CHECK THAT MATTERS: A MANIFEST THAT LIES IS WORSE THAN NO MANIFEST. ***
A reviewer counts the rows and believes them. So `verify()` walks BOTH
directions — every row must point at a file that exists, and every artefact on
disk must have a row — and `missing`/`orphans` are rendered in the browser as
loud rows, never dropped. The mutation battery deletes a grab while leaving its
row in place and requires this to fail.

SCHEMA HANDLING. An unknown schema is REPORTED, not guessed at: `Manifest.problems`
carries the mismatch and the caller shows it. Silently parsing a future shape
because the field names happened to overlap is how a contract goes stale while every
consumer stays green.

Qt-free, stdlib-only: the CLI channel must work with no display and no Qt.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field

#: The schema this reader was written against. A manifest declaring anything
#: else is loaded ANYWAY (the rows may well still be readable) but the mismatch
#: is reported so a stale reader cannot pass for a working one.
SUPPORTED_SCHEMA = "hugmesh.bdd.evidence-manifest/1"

#: Every key evidence.ts promises on EVERY row. Absent keys are reported per row
#: rather than defaulted — a consumer that fills in `null` for a missing `env`
#: turns a broken writer into a plausible-looking index.
REQUIRED_ROW_KEYS = (
    "env", "interface", "feature", "scenario", "step", "ordinal",
    "role", "service", "platform", "layer", "failed",
    "kind", "path", "sidecar", "bytes", "at", "note",
)

#: Files inside a run dir that are the index itself, not artefacts of a step.
_INDEX_FILES = ("manifest.json", "manifest.jsonl")

#: The driver's scratch dir — grabs are COPIED out of it into the run tree, so
#: the originals are not orphans.
_SCRATCH_DIRS = (".driver-tmp",)


@dataclass
class Manifest:
    """One run's index, plus everything wrong with it."""

    path: str
    root: str
    schema: str = ""
    run_id: str = ""
    generated_at: str = ""
    counts: dict = field(default_factory=dict)
    rows: list[dict] = field(default_factory=list)
    #: Loud, human-readable defects. NEVER empty-by-default optimism: a manifest
    #: that could not be read at all comes back with the reason in here.
    problems: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.problems


def run_dirs(report_dir: str) -> list[str]:
    """Every per-run evidence directory under a report dir, newest name last.

    Accepts either the report dir itself (``…/test-results``) or its
    ``bdd-steps`` child, because an operator pointing the browser at a run will
    reasonably do either.
    """
    if not report_dir:
        return []
    bases = [os.path.join(report_dir, "bdd-steps"), report_dir]
    out: list[str] = []
    for base in bases:
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            cand = os.path.join(base, name)
            if os.path.isfile(os.path.join(cand, "manifest.json")) \
                    or os.path.isfile(os.path.join(cand, "manifest.jsonl")):
                if cand not in out:
                    out.append(cand)
        if out:
            break
    return out


def _rows_from_jsonl(path: str) -> tuple[list[dict], list[str]]:
    rows: list[dict] = []
    problems: list[str] = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            s = line.strip()
            if not s:
                continue
            try:
                rows.append(json.loads(s))
            except ValueError as exc:
                problems.append("manifest.jsonl line %d is unparseable (%s): %s"
                                % (lineno, exc, s[:160]))
    return rows, problems


def load(run_dir: str, prefer_jsonl: bool = False) -> Manifest:
    """Load one run's manifest.

    Falls back to ``manifest.jsonl`` when ``manifest.json`` is absent — that is
    exactly the state a CRASHED run leaves behind, and refusing to read it would
    throw away the evidence of the run most worth looking at. The fallback is
    REPORTED in `problems`, so nobody mistakes a partial index for a complete one.

    *** prefer_jsonl=True IS FOR READING A RUN THAT IS STILL GOING. ***
    MEASURED 2026-08-26, and it contradicts what evidence.ts's own header says:
    ``manifest.json`` is NOT written once at the end of a run. playwright-bdd
    maps its ``AfterAll`` onto Playwright's ``test.afterAll``, which fires at the
    end of EVERY generated feature spec FILE — so materializeManifest() rewrites
    manifest.json dozens of times per run, each time with only the rows written
    so far. Measured on a 115-scenario lane: mid-run the file held 188 rows while
    the append log already held 293, and the FINAL file held all 407. A consumer
    that reads manifest.json while the suite is in flight therefore sees a
    TRUNCATED index and will report perfectly good artefacts as unindexed.

    The append log has no such window: a step's artefacts are written and then
    its rows appended, synchronously, in one AfterStep. So a live consumer reads
    the JSONL. The final artefact is unaffected — the last materialisation of a
    finished run is complete — which is why this is an option and not a change of
    default.
    """
    js = os.path.join(run_dir, "manifest.json")
    jl = os.path.join(run_dir, "manifest.jsonl")
    man = Manifest(path=js, root=run_dir)

    if prefer_jsonl and os.path.isfile(jl):
        rows, probs = _rows_from_jsonl(jl)
        man.path = jl
        man.rows = rows
        man.problems.extend(probs)
        man.schema = SUPPORTED_SCHEMA if rows else ""
        man.run_id = os.path.basename(run_dir)
        return man

    if os.path.isfile(js):
        try:
            with open(js, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError) as exc:
            man.problems.append("manifest.json could not be read (%s: %s)"
                                % (type(exc).__name__, exc))
            doc = None
        if isinstance(doc, dict):
            man.schema = str(doc.get("schema") or "")
            man.run_id = str(doc.get("runId") or "")
            man.generated_at = str(doc.get("generatedAt") or "")
            man.counts = doc.get("counts") if isinstance(doc.get("counts"), dict) else {}
            rows = doc.get("artefacts")
            man.rows = list(rows) if isinstance(rows, list) else []
            if not isinstance(rows, list):
                man.problems.append("manifest.json has no `artefacts` array")
            # `root` in the file is the ABSOLUTE dir at write time. Prefer the
            # dir we were actually handed: a report tree copied onto the
            # test-reports PVC keeps working, which is why the contract makes
            # every row's path relative in the first place.
        elif doc is not None:
            man.problems.append("manifest.json is not a JSON object")
    elif os.path.isfile(jl):
        man.problems.append(
            "no manifest.json — reading the manifest.jsonl append log instead. "
            "The index is materialised in AfterAll, so this run either crashed "
            "or is still going; the rows below are what it managed to write.")
        rows, probs = _rows_from_jsonl(jl)
        man.rows = rows
        man.problems.extend(probs)
        man.schema = SUPPORTED_SCHEMA if rows else ""
    else:
        man.problems.append("no manifest.json and no manifest.jsonl in %s — this "
                            "is not an evidence run directory" % run_dir)
        return man

    if man.schema and man.schema != SUPPORTED_SCHEMA:
        man.problems.append(
            "manifest declares schema %r; this reader implements %r. Reading it "
            "anyway, but a field this reader shows may mean something else. Bump "
            "the reader in the same change that bumped EVIDENCE_SCHEMA."
            % (man.schema, SUPPORTED_SCHEMA))
    return man


def artefact_path(man: Manifest, row: dict) -> str:
    """Absolute path of a row's artefact. Paths in the manifest are RELATIVE to
    the run dir by contract, so this is where that contract is honoured."""
    rel = str(row.get("path") or "")
    if not rel:
        return ""
    if os.path.isabs(rel):
        # Not the contract, but do not silently mangle it — verify() reports it.
        return rel
    return os.path.normpath(os.path.join(man.root, rel))


def _on_disk(run_dir: str) -> set[str]:
    """Every artefact file in the run tree — sidecars and index files excluded.

    Sidecars are indexed through their artefact's `sidecar` field rather than
    as rows of their own, so counting them as orphans would make every healthy
    run look broken. `.cli.json` / `.studio.json` ARE artefacts and do get rows.
    """
    found: set[str] = set()
    for dirpath, dirs, files in os.walk(run_dir):
        dirs[:] = [d for d in dirs if d not in _SCRATCH_DIRS]
        for fn in files:
            if fn in _INDEX_FILES:
                continue
            if fn.endswith(".json") and not fn.endswith(".cli.json") \
                    and not fn.endswith(".studio.json"):
                continue          # a step sidecar
            found.add(os.path.normpath(os.path.join(dirpath, fn)))
    return found


@dataclass
class Verification:
    """Both directions of the index-vs-disk check."""

    #: Rows whose artefact is not on disk. THE lie this whole check exists for.
    missing: list[dict] = field(default_factory=list)
    #: Files in the run tree with no row. The direction an index silently
    #: SHRINKS in — the writer drops one and the index still validates against
    #: itself perfectly.
    orphans: list[str] = field(default_factory=list)
    #: Rows missing a contract key, or carrying an absolute path.
    malformed: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not (self.missing or self.orphans or self.malformed)

    def summary(self) -> str:
        if self.ok:
            return "every manifest row points at a file that exists, and every " \
                   "artefact on disk has a row"
        bits = []
        if self.missing:
            bits.append("%d row(s) point at a MISSING file" % len(self.missing))
        if self.orphans:
            bits.append("%d artefact(s) on disk have NO row" % len(self.orphans))
        if self.malformed:
            bits.append("%d malformed row(s)" % len(self.malformed))
        return "; ".join(bits)


def verify(man: Manifest) -> Verification:
    """Walk the index against the disk, BOTH ways.

    This is the anti-decoration check for the evidence lane. A manifest listing
    artefacts nobody can open is worse than no manifest at all, because a
    reviewer counts the rows and believes them — so a missing file is a defect
    here, never a row quietly filtered out of the view.
    """
    v = Verification()
    listed: set[str] = set()
    for row in man.rows:
        for key in REQUIRED_ROW_KEYS:
            if key not in row:
                v.malformed.append("row %r (step %r) is missing the contract key %r"
                                   % (row.get("path"), row.get("step"), key))
        rel = str(row.get("path") or "")
        if os.path.isabs(rel):
            v.malformed.append(
                "row path %r is ABSOLUTE; the contract says relative to `root`, so "
                "this row breaks the moment the report dir is copied" % rel)
        abs_path = artefact_path(man, row)
        if not abs_path or not os.path.exists(abs_path):
            v.missing.append(row)
        else:
            listed.add(os.path.normpath(abs_path))
    if os.path.isdir(man.root):
        v.orphans = sorted(_on_disk(man.root) - listed)
    return v


# ── grouping: the browser's model ────────────────────────────────────────────

def group(man: Manifest) -> dict:
    """env -> interface -> feature -> scenario -> [rows], each level sorted.

    The nesting order is the operator's question order: WHICH MESH did this run
    against, driven from WHICH front-end, in which feature. `env` and `interface`
    are the two axes the ask names, so they are the two outermost levels.

    Rows with a missing dimension bucket under '<unset>' rather than being
    dropped: a row the writer failed to dimension is exactly the row worth
    seeing.
    """
    tree: dict = {}
    for row in man.rows:
        env = str(row.get("env") or "<unset>")
        iface = str(row.get("interface") or "<unset>")
        feature = str(row.get("feature") or "<unset>")
        scenario = str(row.get("scenario") or "<unset>")
        tree.setdefault(env, {}).setdefault(iface, {}) \
            .setdefault(feature, {}).setdefault(scenario, []).append(row)
    for env in tree.values():
        for iface in env.values():
            for feature in iface.values():
                for rows in feature.values():
                    rows.sort(key=lambda r: (r.get("ordinal") or 0, str(r.get("kind"))))
    return tree


def tally(man: Manifest, key: str) -> dict[str, int]:
    """Count rows by one dimension — the numbers a header line shows."""
    out: dict[str, int] = {}
    for row in man.rows:
        k = str(row.get(key) or "<unset>")
        out[k] = out.get(k, 0) + 1
    return dict(sorted(out.items()))


def row_label(row: dict) -> str:
    """One line naming a step's artefact, the way the tree renders it."""
    ordinal = row.get("ordinal")
    ordinal_s = "%03d" % ordinal if isinstance(ordinal, int) and ordinal >= 0 else "---"
    flag = "  [FAILED]" if row.get("failed") else ""
    return "%s  %s  %s%s" % (ordinal_s, row.get("kind") or "?",
                             row.get("step") or "?", flag)


def report(man: Manifest) -> dict:
    """The whole browsable model as plain data — what the CLI verb prints and
    what the Qt pane renders. One producer, so the terminal and the GUI can
    never show different numbers."""
    v = verify(man)
    return {
        "root": man.root,
        "schema": man.schema,
        "runId": man.run_id,
        "generatedAt": man.generated_at,
        "counts": {
            "rows": len(man.rows),
            "failed": sum(1 for r in man.rows if r.get("failed")),
            "byEnv": tally(man, "env"),
            "byInterface": tally(man, "interface"),
            "byKind": tally(man, "kind"),
        },
        "problems": list(man.problems),
        "verification": {
            "ok": v.ok,
            "summary": v.summary(),
            "missing": [str(r.get("path") or "") for r in v.missing],
            "orphans": [os.path.relpath(o, man.root) for o in v.orphans],
            "malformed": list(v.malformed),
        },
    }
