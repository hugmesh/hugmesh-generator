"""The org-export plan's three shortcuts change nothing but its speed.

Measured 2026-11-13 on Windows 11: a plan of the generator took 157 s, printing nothing
until the end. About half of it was ~25 rename patterns run over every file (most name
no repository at all), and most of the rest was file opens: each file was read once for
the rewrite and once more for the scan, and two realpath calls per tar member opened
paths too. The shortcuts:

* a built-in rule is skipped when the text its every match contains is absent
  (``_RULE_NEEDLE``); an operator's own token rule always runs;
* the scan takes the bytes the rewrite pass already holds (``known``);
* the snapshot resolves the work folder once and each parent folder once, starting
  afresh after every link it writes.

The plan below runs twice over the same sources, once with every shortcut turned off,
and must come out the same: the same plan, byte for byte the same work trees.
"""
from __future__ import annotations

import io
import os
import tarfile

import pytest

from hugmesh_studio.core import org_export as oe

from _org_export_helpers import git as _git, make_world  # noqa: E402


# ── the rename rules ────────────────────────────────────────────────────────────────
def _rules(extra_tokens=()):
    cfg = oe.ExportConfig(org="exampleorg",
                          rename_map={"tokens": list(extra_tokens)} if extra_tokens else {})
    names = ["hugmesh-parent", "hugmesh-commons", "hugmesh-user-ui", "hugmesh-user",
             "hugmesh-wiki-bff-api", "hugmesh-admin-bff-api", "hugmesh-gateway",
             "hugmesh-actions"]
    return oe.rename_rules(cfg, names)


def _every_rule(text, rules):
    total = 0
    for rx, rep, _note in rules:
        text, n = rx.subn(rep, text)
        total += n
    return text, total


TEXTS = [
    "",
    "nothing to rename here at all\n",
    "see https://github.com/hugmesh/hugmesh-parent and ghcr.io/hugmesh/hugmesh-gateway:1\n",
    "git@github.com:hugmesh/hugmesh-commons.git and hugmesh/hugmesh-user-ui@main\n",
    "hugmesh-user hugmesh-user-ui xhugmesh-user hugmesh-user-uix @hugmesh-user\n",
    "maven.pkg.github.com/hugmesh/x hugmesh/notarepo hugmesh-actionsX hugmesh-actions\n",
    "HUGMESH-PARENT Hugmesh-Parent hugmesh_parent hugmesh-parent\n" * 3,
    "﻿café hugmesh-wiki-bff-api é hugmesh-admin-bff-api\r\n",
]


@pytest.mark.parametrize("text", TEXTS)
def test_skipping_rules_gives_what_running_every_rule_gives(text):
    rules = _rules()
    assert oe.rewrite_text(text, rules) == _every_rule(text, rules)


def test_every_built_in_rule_has_a_needle_and_every_match_contains_it():
    rules = _rules()
    for rx, _rep, note in rules:
        needle = oe._RULE_NEEDLE.get(rx)
        assert needle, f"no needle for {note}"
        for text in TEXTS:
            for m in rx.finditer(text):
                assert needle in text[max(0, m.start() - len(needle)):m.end() + len(needle)]


def test_an_operators_token_rule_always_runs():
    rules = _rules([{"pattern": r"\bfoo\b", "replace": "bar", "note": "mine"}])
    rx = rules[-1][0]
    assert rx not in oe._RULE_NEEDLE
    assert oe.rewrite_text("a foo b", rules) == ("a bar b", 1)


def test_equal_length_names_are_listed_in_one_order_whatever_the_hash_seed():
    a = oe.rename_rules(oe.ExportConfig(org="exampleorg"),
                        ["hugmesh-gateway", "hugmesh-actions", "hugmesh-user-ui"])
    b = oe.rename_rules(oe.ExportConfig(org="exampleorg"),
                        ["hugmesh-user-ui", "hugmesh-gateway", "hugmesh-actions"])
    assert [r[2] for r in a] == [r[2] for r in b]
    named = [r[2] for r in a if r[2].startswith("repository name")]
    assert named == sorted(named, key=lambda s: (-len(s.split()[2]), s.split()[2]))


# ── the snapshot's realpath cache ───────────────────────────────────────────────────
class _Runner:
    def __init__(self, tar_bytes):
        self._tar = tar_bytes

    def run(self, argv, **_kw):
        return oe.RunResult(0, self._tar, b"") if "archive" in argv else \
            oe.RunResult(1, b"", b"")


def _tar(members):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for name, kind, payload in members:
            info = tarfile.TarInfo(name)
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                tf.addfile(info)
            elif kind == "link":
                info.type, info.linkname = tarfile.SYMTYPE, payload
                tf.addfile(info)
            else:
                info.size = len(payload)
                tf.addfile(info, io.BytesIO(payload))
    return buf.getvalue()


def _count_realpath(monkeypatch):
    """realpath calls made BY org_export (tarfile's own data filter resolves each member
    too, and stays: it is the second of the two checks)."""
    import sys
    calls = []
    real = os.path.realpath

    def counted(p, *a, **k):
        if sys._getframe(1).f_globals.get("__name__") == oe.__name__:
            calls.append(p)
        return real(p, *a, **k)
    monkeypatch.setattr(oe.os.path, "realpath", counted)
    return calls


def test_the_snapshot_resolves_each_folder_once(tmp_path, monkeypatch):
    members = [(d, "dir", None) for d in ("a/", "b/", "b/c/")]
    members += [(f"{d}f{i}.txt", "file", b"x") for d in ("a", "b", "b/c") for i in range(60)]
    calls = _count_realpath(monkeypatch)
    files = oe._snapshot(_Runner(_tar(members)), str(tmp_path), "HEAD",
                         str(tmp_path / "work"), {})
    assert len(files) == 180
    assert len(calls) <= 8, f"{len(calls)} realpath calls for 4 folders"


@pytest.mark.skipif(os.name == "nt", reason="the snapshot never writes a link on Windows")
def test_a_link_written_by_the_snapshot_makes_it_resolve_afresh(tmp_path, monkeypatch):
    members = [("a/", "dir", None), ("a/one.txt", "file", b"1"),
               ("l", "link", "a"), ("a/two.txt", "file", b"2")]
    calls = _count_realpath(monkeypatch)
    oe._snapshot(_Runner(_tar(members)), str(tmp_path), "HEAD", str(tmp_path / "work"), {})
    after_link = calls[[os.path.basename(c) for c in calls].index("work") + 1:]
    # the parent "a" is resolved before the link and again after it
    assert sum(1 for c in after_link if c.endswith(os.sep + "a")) >= 2


def test_the_cache_is_what_decides_when_it_is_passed(tmp_path):
    root = os.path.realpath(str(tmp_path))
    member = tarfile.TarInfo("sub/f.txt")
    stale = {os.path.join(root, "sub"): os.path.dirname(root)}      # resolves outside
    assert oe._member_stays_inside(str(tmp_path), member, root=root, resolved=stale) is False
    assert oe._member_stays_inside(str(tmp_path), member, root=root, resolved={}) is True


# ── the scan takes the bytes in hand ────────────────────────────────────────────────
def test_the_scan_scans_the_bytes_it_is_handed(tmp_path):
    (tmp_path / "a.txt").write_bytes(b"clean\n")
    marker = b"ghp_" + b"A" * 36
    assert oe._scan_entries(str(tmp_path)) == []
    found = oe._scan_entries(str(tmp_path), {"a.txt": marker})
    assert found and found[0].startswith("a.txt: ")


# ── the whole plan, with and without the shortcuts ──────────────────────────────────
def _plant(world):
    repo = os.path.join(world["src"], "hugmesh-commons")
    files = {
        "docs/links.md": "see https://github.com/hugmesh/hugmesh-parent\n" * 50,
        "docs/plain.md": "nothing to rename\n" * 200,
        "docs/crlf.md": "hugmesh-actions\r\nhugmesh-commons\r\n",
        "bin/blob.bin": None,
        "big/large.txt": "hugmesh-parent " * 4000,
        # rewritten INTO a token by the operator rule below: only a scan of the bytes
        # as written finds it, so a scan handed the bytes from before the rewrite
        # would publish it
        "docs/becomes-secret.md": "value: PLANTED_PLACEHOLDER\n",
    }
    for rel, text in files.items():
        full = os.path.join(repo, *rel.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as fh:
            fh.write(b"\0\1hugmesh-parent\0" if text is None else text.encode("utf-8"))
    _git(repo, "add", "-A")
    _git(repo, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "planted")


def _tree(root):
    out = {}
    for dirpath, _dirs, names in os.walk(root):
        for n in names:
            full = os.path.join(dirpath, n)
            with open(full, "rb") as fh:
                out[os.path.relpath(full, root).replace(os.sep, "/")] = fh.read()
    return out


def _comparable(p, out_dir):
    d = p.to_dict()
    d.pop("stamp", None)
    d.pop("out_dir", None)
    text = repr(d).replace(out_dir, "<OUT>").replace(out_dir.replace("\\", "\\\\"), "<OUT>")
    return text


class _NoNeedles(dict):
    def __setitem__(self, k, v):
        pass

    def get(self, k, default=None):
        return None


def test_a_plan_with_the_shortcuts_equals_one_without(tmp_path, monkeypatch):
    world = make_world(tmp_path)
    _plant(world)
    # a small cap, so files both inside and over it take their own path
    monkeypatch.setattr(oe, "_KNOWN_LIMIT", 4096)
    base = world["cfg"].to_dict()
    base["rename_map"] = {"tokens": [{"pattern": "PLANTED_PLACEHOLDER",
                                      "replace": "ghp_" + "A" * 36, "note": "test"}]}
    fast_out = str(tmp_path / "fast")
    fast = oe.plan(oe.ExportConfig(**{**base, "out_dir": fast_out}),
                   world["runner"], probe=False, stamp="20260101T000000Z")

    real_scan, real_inside = oe._scan_entries, oe._member_stays_inside
    monkeypatch.setattr(oe, "_RULE_NEEDLE", _NoNeedles())
    monkeypatch.setattr(oe, "_scan_entries", lambda w, known=None: real_scan(w))
    monkeypatch.setattr(oe, "_member_stays_inside",
                        lambda w, m, **_kw: real_inside(w, m))
    slow_out = str(tmp_path / "slow")
    slow = oe.plan(oe.ExportConfig(**{**base, "out_dir": slow_out}),
                   world["runner"], probe=False, stamp="20260101T000000Z")

    assert any(r.rewrites for r in fast.repos), "the planted files must be rewritten"
    commons = next(r for r in fast.repos if r.source == "hugmesh-commons")
    assert any(b.startswith("docs/becomes-secret.md: ") for b in commons.banned), \
        "the token the rewrite wrote must be found"
    assert _comparable(fast, fast_out) == _comparable(slow, slow_out)
    assert _tree(os.path.join(fast_out, "work")) == _tree(os.path.join(slow_out, "work"))


def test_the_cli_says_which_repository_it_is_on(tmp_path):
    world = make_world(tmp_path)
    lines = []
    oe.plan(world["cfg"], world["runner"], probe=False, progress=lines.append)
    assert lines and lines[0].startswith("[plan 1/") and all("snapshot" in l for l in lines)
