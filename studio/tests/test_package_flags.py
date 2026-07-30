"""package_flags — the data layer for the per-package flag badges, driven entirely
by the committed ground-truth fixtures (docs/PACKAGE-FLAG-BADGES.md):

* ``portage-use-flag-states.json`` — EVERY reachable USE-flag display state,
  produced by portage 3.0.81.2's own ``_create_use_string`` at havecolor 0 and 1.
  The classifier is driven against every row of both variants.
* ``emerge-resolver-lines.x86-pki.txt`` — 229 real resolver rows lifted verbatim
  from a live fleet build log. All 229 must parse; the §2.1 quoted examples are
  spot-checked; joining parsed tokens must reproduce each ``KEY="…"`` block
  byte-for-byte (the copy-paste guarantee).
* ``vdb-package-metadata.sample.json`` — real VDB files, including the package
  with NO LICENSE file at all (that is data, not an error — §3).
"""
import dataclasses
import gzip
import json
import os

import pytest

from hugmesh_studio.core import package_flags as pf

_FIXDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "fixtures", "package-flags")


def _load_state_cases():
    with open(os.path.join(_FIXDIR, "portage-use-flag-states.json")) as fh:
        return json.load(fh)["cases"]


def _load_resolver_lines():
    with open(os.path.join(_FIXDIR, "emerge-resolver-lines.x86-pki.txt")) as fh:
        return fh.read().splitlines()


def _data_lines():
    return [l for l in _load_resolver_lines() if l and not l.startswith("#")]


def _find_row(rows, pkg):
    for r in rows:
        if r.pkg == pkg:
            return r
    raise AssertionError(f"fixture row for {pkg!r} not found")


# ── 1. the state matrix: EVERY reachable display state, both havecolor variants ──────

# Expected classification per generator label. Fields:
#   (enabled, changed, new_in_iuse, removed, forced_masked, display_state, ambiguous)
# "ansi" overrides apply only where colour resolves the plain-text (-f) collision
# (§1.3: states 10 and 11 both print "(-f)"; blue vs yellow separates them).
_PLAIN = {
    "new-pkg / enabled":
        (True, False, False, False, False, "enabled-unchanged", False),
    "new-pkg / disabled":
        (False, False, False, False, False, "disabled-unchanged", False),
    "new-pkg / enabled + profile-forced":
        (True, False, False, False, True, "enabled-unchanged", False),
    "new-pkg / disabled + profile-masked":
        (False, False, None, False, True, "disabled-unchanged", True),
    "reinstall / enabled, unchanged":
        (True, False, False, False, False, "enabled-unchanged", False),
    "reinstall / disabled, unchanged":
        (False, False, False, False, False, "disabled-unchanged", False),
    "reinstall / turning ON (was off last merge)":
        (True, True, False, False, False, "turning-on", False),
    "reinstall / turning OFF (was on last merge)":
        (False, True, False, False, False, "turning-off", False),
    "reinstall / newly in IUSE, enabled":
        (True, True, True, False, False, "new-in-iuse", False),
    "reinstall / newly in IUSE, disabled":
        (False, False, True, False, False, "new-in-iuse", False),
    "reinstall / newly in IUSE, disabled + forced/masked":
        (False, False, None, False, True, "disabled-unchanged", True),
    # The three states the iuse_forced paren wrap produces around a token that
    # already carries its %/* suffix. "(f%*)" is the one that used to invert:
    # its '%' means NEWLY ADDED (the enabled branch), never "removed" — portage's
    # removed branch ALWAYS emits a '-' inside its parens.
    "reinstall / newly in IUSE, ENABLED + forced":
        (True, True, True, False, True, "new-in-iuse", False),
    "reinstall / turning ON + forced":
        (True, True, False, False, True, "turning-on", False),
    "reinstall / turning OFF + masked":
        (False, True, False, False, True, "turning-off", False),
    "reinstall / REMOVED from IUSE (was off)":
        (False, False, False, True, False, "removed", False),
    "reinstall / REMOVED from IUSE (was on)":
        (False, True, False, True, False, "removed", False),
    "reinstall / enabled unchanged + forced":
        (True, False, False, False, True, "enabled-unchanged", False),
    "reinstall / disabled unchanged + masked":
        (False, False, None, False, True, "disabled-unchanged", True),
}
# With colour the two (-f) states resolve — the ambiguity flag MUST drop.
_ANSI_OVERRIDES = {
    "new-pkg / disabled + profile-masked":                    # state 10, blue
        (False, False, False, False, True, "disabled-unchanged", False),
    "reinstall / newly in IUSE, disabled + forced/masked":    # state 11, yellow
        (False, False, True, False, True, "new-in-iuse", False),
    "reinstall / disabled unchanged + masked":                # state 10, blue
        (False, False, False, False, True, "disabled-unchanged", False),
}
_EXPECT_COLOUR = {
    "enabled-unchanged": "red",
    "disabled-unchanged": "blue",
    "turning-on": "green",
    "turning-off": "green",
    "new-in-iuse": "yellow",
    "removed": "yellow",
}

_CASES = _load_state_cases()


@pytest.mark.parametrize("case", _CASES,
                         ids=[f"{c['verbosity'][:4]}-{c['state']}" for c in _CASES])
@pytest.mark.parametrize("variant", ["plain", "ansi"])
def test_state_matrix_every_reachable_state(case, variant):
    text = case[variant]
    if variant == "ansi":
        # The generator stored the escapes via encode("unicode_escape").
        text = text.encode().decode("unicode_escape")
    groups = pf.parse_flag_groups(text)
    if case["plain"] == "":
        # Default verbosity suppresses unchanged/removed flags for reinstalls
        # (§2.3) — the honest parse of nothing is nothing.
        assert groups == ()
        return
    assert len(groups) == 1 and groups[0].key == "USE"
    assert len(groups[0].tokens) == 1
    tok = groups[0].tokens[0]

    expect = dict(_PLAIN)
    if variant == "ansi":
        expect.update(_ANSI_OVERRIDES)
    enabled, changed, new, removed, forced, state, amb = expect[case["state"]]
    assert tok.enabled is enabled
    assert tok.changed is changed
    assert tok.new_in_iuse is new
    assert tok.removed is removed
    assert tok.forced_masked is forced
    assert tok.display_state == state
    assert tok.ambiguous is amb
    assert tok.name == "f"
    # verbatim is always the plain-text portage token, whatever the input carried
    assert tok.verbatim == case["plain"][len('USE="'):-1]
    if variant == "ansi":
        assert tok.colour_seen == _EXPECT_COLOUR[tok.display_state]
    else:
        assert tok.colour_seen is None


def test_ambiguity_is_exactly_the_two_way_collision():
    """Plain "(-f)" is states 10/11 collided; colour resolves it; nothing else
    is ever flagged ambiguous."""
    plain = pf.classify_flag_token("(-f)")
    assert plain.ambiguous and plain.new_in_iuse is None and plain.forced_masked
    blue = pf.classify_flag_token("(\x1b[34;01m-f\x1b[39;49;00m)")
    assert not blue.ambiguous and blue.new_in_iuse is False
    assert blue.display_state == "disabled-unchanged" and blue.forced_masked
    yellow = pf.classify_flag_token("(\x1b[33;01m-f\x1b[39;49;00m)")
    assert not yellow.ambiguous and yellow.new_in_iuse is True
    assert yellow.display_state == "new-in-iuse" and yellow.forced_masked
    # EVERY other rendering portage can produce — parenthesised ones included —
    # is uniquely recoverable from plain text and must never be flagged
    # ambiguous. This list is all 13 renderings _create_use_string emits (driven
    # exhaustively over its 64-combination input space) minus the bare "(-f)".
    for t in ("f", "-f", "f*", "-f*", "f%*", "-f%",
              "(f)", "(f*)", "(-f*)", "(f%*)", "(-f%)", "(-f%*)"):
        tok = pf.classify_flag_token(t)
        assert not tok.ambiguous, t
        assert tok.new_in_iuse is not None, t


def test_forced_paren_wrap_keeps_the_suffix_meaning():
    """portage wraps the iuse_forced parens around a token that ALREADY carries
    its %/* suffix (output_helpers.py:324-325), so "(f%*)", "(f*)" and "(-f*)"
    are real renderings. The removed branch (:302-309) builds its own parens and
    `continue`s, and always emits '-' inside them — the sign is the discriminator.
    Before this was fixed, "(f%*)" came back as removed+struck-through with the
    forced modifier dropped: the exact inverse of the truth."""
    new_forced = pf.classify_flag_token("(f%*)")
    assert new_forced.display_state == "new-in-iuse"
    assert new_forced.new_in_iuse is True
    assert new_forced.removed is False          # '%' outside the removed branch == NEW
    assert new_forced.forced_masked is True     # the 🔒 modifier must survive
    assert new_forced.enabled and new_forced.changed
    # ...and identically when the log carried colour.
    assert pf.classify_flag_token("(\x1b[33;01mf\x1b[39;49;00m%*)") == \
        dataclasses.replace(new_forced, colour_seen="yellow")

    on_forced = pf.classify_flag_token("(f*)")
    assert (on_forced.display_state, on_forced.forced_masked, on_forced.removed) == \
        ("turning-on", True, False)
    off_masked = pf.classify_flag_token("(-f*)")
    assert (off_masked.display_state, off_masked.forced_masked, off_masked.removed) == \
        ("turning-off", True, False)
    assert off_masked.new_in_iuse is False      # '*' ⇒ was in the old IUSE ⇒ not new
    # green is portage's transition marker and can never be the '%' axis, so a
    # coloured capture must not come back ambiguous either.
    green = pf.classify_flag_token("(\x1b[32;01m-f\x1b[39;49;00m*)")
    assert green.colour_seen == "green" and not green.ambiguous
    assert green.new_in_iuse is False

    # The removals keep their meaning, and never claim to be profile-forced.
    for t in ("(-f%)", "(-f%*)"):
        tok = pf.classify_flag_token(t)
        assert tok.removed is True and tok.forced_masked is False, t
        assert tok.display_state == "removed", t


def test_classifier_rejects_non_tokens():
    assert pf.classify_flag_token("(f") is None      # unbalanced
    assert pf.classify_flag_token("a b") is None     # not one token


# ── 2. the 229 real resolver rows ────────────────────────────────────────────────────

def test_all_229_fixture_rows_parse():
    lines = _data_lines()
    assert len(lines) == 229
    rows = [pf.parse_resolver_line(l) for l in lines]
    unparsed = [l for l, r in zip(lines, rows) if r is None]
    assert unparsed == []
    assert all(r.type == "ebuild" for r in rows)
    # comment lines must NOT parse
    for l in _load_resolver_lines():
        if l.startswith("#"):
            assert pf.parse_resolver_line(l) is None


def test_attr_shapes_match_the_doc():
    """§2.1: the seven real attr shapes and their exact multiplicities."""
    from collections import Counter
    counts = Counter(pf.parse_resolver_line(l).attrs.raw for l in _data_lines())
    assert counts == {
        " N     ": 198, "  R    ": 16, " N    ~": 11,
        " rR    ": 1, " r  UD ": 1, " NS    ": 1, "    UD ": 1,
    }


def test_spot_check_libnl_anatomy():
    """The exact §2.1 anatomy example."""
    row = _find_row([pf.parse_resolver_line(l) for l in _data_lines()], "libnl")
    assert (row.cpv, row.cat, row.pkg, row.version) == \
        ("dev-libs/libnl-3.12.0", "dev-libs", "libnl", "3.12.0")
    assert row.attrs.new and not row.attrs.replacing and row.attrs.mask is None
    assert [g.key for g in row.groups] == ["USE", "ABI_X86", "PYTHON_TARGETS"]
    use = row.group("USE")
    assert [t.verbatim for t in use.tokens] == \
        ["debug", "-python", "-test", "-utils", "-verify-sig"]
    assert use.tokens[0].enabled and use.tokens[0].display_state == "enabled-unchanged"
    assert not use.tokens[1].enabled
    abi = row.group("ABI_X86")
    assert [t.verbatim for t in abi.tokens] == ["(64)", "-32", "(-x32)"]
    assert abi.tokens[0].enabled and abi.tokens[0].forced_masked      # (64) forced on
    assert abi.tokens[2].forced_masked and abi.tokens[2].ambiguous    # (-x32): §1.3
    pyt = row.group("PYTHON_TARGETS")
    # group prefix stripped by portage — names as printed
    assert [t.name for t in pyt.tokens] == ["python3_12", "python3_13", "python3_14"]


@pytest.mark.parametrize("pkg,key,tokens", [
    # every §2.1 "decoration in the wild" example, verbatim
    ("lzo", "USE", ["-examples", "(-split-usr)", "-static-libs"]),
    ("talloc", "PYTHON_SINGLE_TARGET", ["python3_12", "-python3_13", "-python3_14"]),
    ("typing-extensions", "PYTHON_TARGETS", ["python3_12*", "-python3_13*", "-python3_14*"]),
    ("pyproject-metadata", "PYTHON_TARGETS",
     ["python3_12", "-python3_13", "-python3_14",
      "(-python3_14t)", "(-python3_15)", "(-python3_15t)"]),
    ("go", "CPU_FLAGS_X86", ["sse2"]),
    ("go-bootstrap", "USE", ["(-big-endian)"]),
])
def test_spot_check_section21_examples(pkg, key, tokens):
    row = _find_row([pf.parse_resolver_line(l) for l in _data_lines()], pkg)
    assert [t.verbatim for t in row.group(key).tokens] == tokens


def test_replacing_rows_carry_only_changed_flags():
    """§2.3: at default verbosity an [ebuild R] row lists ONLY flags that changed
    — plus the profile-forced/masked parenthesised ones, which portage prints
    regardless (real fixture shape: "python3_12* … (-python3_14t)")."""
    rows = [pf.parse_resolver_line(l) for l in _data_lines()]
    r_rows = [r for r in rows if r.attrs.raw == "  R    "]
    assert len(r_rows) == 16
    saw_changed = 0
    for r in r_rows:
        for g in r.groups:
            for t in g.tokens:
                assert t.changed or t.forced_masked, (r.cpv, t.verbatim)
                if t.changed:
                    saw_changed += 1
                    assert t.display_state in ("turning-on", "turning-off")
    assert saw_changed > 0


def test_old_version_brackets():
    rows = [pf.parse_resolver_line(l) for l in _data_lines()]
    jsoncpp = _find_row(rows, "jsoncpp")           # [ebuild  r  UD ] ... [1.9.8]
    assert jsoncpp.old_versions == ("1.9.8",)
    assert jsoncpp.attrs.forced_reinstall and jsoncpp.attrs.upgrade \
        and jsoncpp.attrs.downgrade
    docbook = _find_row(rows, "docbook-xml-dtd")   # [ebuild  NS    ] ... [a, b, c]
    assert docbook.old_versions == ("4.1.2-r7", "4.2-r3", "4.5-r2")
    assert docbook.attrs.new and docbook.attrs.new_slot
    maturin = _find_row(rows, "maturin")           # [ebuild     UD ] ... [1.14.1] KEY=...
    assert maturin.old_versions == ("1.14.1",)
    assert maturin.group("PYTHON_TARGETS") is not None


def test_unstable_keyword_attr():
    rows = [pf.parse_resolver_line(l) for l in _data_lines()]
    go = _find_row(rows, "go")
    assert go.attrs.mask == "unstable-keyword"     # pos 7 '~'
    assert go.version == "1.26.4"


def test_verbose_cpv_slot_repo_split():
    """§2.1: at -v the cpv carries :slot::repo — documented shape, no fleet sample
    yet (open unknown 3), so drive the split directly."""
    row = pf.parse_resolver_line(
        '[ebuild  N     ] dev-libs/libnl-3.12.0:3/200::gentoo  USE="debug"')
    assert row.cpv == "dev-libs/libnl-3.12.0"
    assert row.slot == "3/200" and row.repo == "gentoo"
    assert [t.verbatim for t in row.group("USE").tokens] == ["debug"]


def test_round_trip_copy_paste_guarantee():
    """§5: joining the parsed tokens reproduces every KEY="…" block verbatim."""
    for line in _data_lines():
        row = pf.parse_resolver_line(line)
        for g in row.groups:
            rebuilt = f'{g.key}="{g.verbatim_value()}"'
            assert rebuilt == g.raw
            assert rebuilt in line


def test_round_trip_survives_ansi():
    """An ANSI-coloured row round-trips to the plain text portage would have
    printed at havecolor 0 — and the colour separates states 10 vs 11."""
    line = ('[ebuild  N     ] dev-libs/lzo-2.10  '
            'USE="\x1b[34;01m-examples\x1b[39;49;00m '
            '(\x1b[33;01m-split-usr\x1b[39;49;00m) '
            '\x1b[34;01m-static-libs\x1b[39;49;00m" '
            'ABI_X86="(\x1b[31;01m64\x1b[39;49;00m) '
            '\x1b[34;01m-32\x1b[39;49;00m (\x1b[34;01m-x32\x1b[39;49;00m)"')
    row = pf.parse_resolver_line(line)
    use = row.group("USE")
    assert use.verbatim_value() == "-examples (-split-usr) -static-libs"
    assert use.raw == 'USE="-examples (-split-usr) -static-libs"'
    split_usr = use.tokens[1]
    assert split_usr.colour_seen == "yellow"
    assert split_usr.new_in_iuse is True and not split_usr.ambiguous   # state 11
    abi = row.group("ABI_X86")
    assert abi.tokens[0].colour_seen == "red" and abi.tokens[0].forced_masked
    x32 = abi.tokens[2]
    assert x32.colour_seen == "blue"
    assert x32.new_in_iuse is False and not x32.ambiguous              # state 10
    assert abi.verbatim_value() == "(64) -32 (-x32)"


def test_emitted_order_is_never_sorted():
    """§1.2: position is information — enabled → disabled as portage printed it."""
    row = pf.parse_resolver_line(
        '[ebuild  N     ] a-cat/pkg-1.0  USE="zeta -alpha beta*"')
    assert [t.name for t in row.group("USE").tokens] == ["zeta", "alpha", "beta"]


# ── 3. block extraction + join index ─────────────────────────────────────────────────

def test_block_extractor_finds_blocks_amid_noise():
    fixture = _data_lines()
    log = (
        ["make[1]: Entering directory '/x'",
         ">>> Emerging (1 of 3) dev-libs/lzo-2.10::gentoo"]
        + fixture[:3]
        + ["", "Total: 229 packages (213 new), Size of downloads: 0 KiB"]
        + fixture[3:5]
        + ["done."]
    )
    blocks = list(pf.iter_resolver_blocks(log))
    assert [len(b.rows) for b in blocks] == [3, 2]
    assert blocks[0].first_line == 2 and blocks[0].last_line == 4
    assert blocks[1].first_line == 7 and blocks[1].last_line == 8


def test_flag_index_joins_on_cat_pkg_and_cpv():
    idx = pf.build_flag_index(_data_lines())
    assert len(idx.blocks) == 1
    assert len(idx.by_cpv) == 229
    row = idx.by_cat_pkg[("dev-libs", "libnl")]
    assert row.cpv == "dev-libs/libnl-3.12.0"
    assert idx.by_cpv["dev-libs/libnl-3.12.0"] is row


def test_flag_index_later_block_wins():
    log = (
        ['[ebuild  N     ] dev-libs/lzo-2.10  USE="-examples"',
         "conflict chatter",
         '[ebuild   R    ] dev-libs/lzo-2.10  USE="examples*"'])
    idx = pf.build_flag_index(log)
    row = idx.by_cat_pkg[("dev-libs", "lzo")]
    assert row.attrs.replacing
    assert row.group("USE").tokens[0].display_state == "turning-on"
    # re-listing the SAME cpv is a --keep-going re-run, not a slot ambiguity
    assert idx.multi_slot == frozenset()
    assert idx.row_for("dev-libs/lzo-2.10") is row


# The fleet's own sysroots carry dev-lang/python at two slots and
# app-text/docbook-xml-dtd at four, and a -v merge list gives each slot its own row.
_MULTI_SLOT_LOG = [
    '[ebuild  N     ] dev-lang/python-3.13.14:3.13::gentoo  USE="ncurses readline -tk"',
    '[ebuild  N     ] dev-lang/python-3.14.6:3.14::gentoo  USE="-ncurses -readline tk"',
]


def test_multi_slot_rows_never_collapse_onto_one_key():
    """A (cat, pkg) key silently merges every slot of a package and lets the LAST
    row speak for all of them — one slot's row would confidently display another
    slot's USE flags, with no caveat, and put the wrong string on the clipboard."""
    idx = pf.build_flag_index(_MULTI_SLOT_LOG)
    assert sorted(idx.by_cpv) == ["dev-lang/python-3.13.14", "dev-lang/python-3.14.6"]
    # the exact key answers per slot...
    assert idx.row_for("dev-lang/python-3.13.14").group("USE").verbatim_value() == \
        "ncurses readline -tk"
    assert idx.row_for("dev-lang/python-3.14.6").group("USE").verbatim_value() == \
        "-ncurses -readline tk"
    # ...and the collapsed one refuses rather than guessing.
    assert ("dev-lang", "python") in idx.multi_slot
    assert ("dev-lang", "python") not in idx.by_cat_pkg
    assert idx.row_for("dev-lang/python") is None
    # a :slot / ::repo suffix on the lookup atom is tolerated
    assert idx.row_for("dev-lang/python-3.13.14:3.13::gentoo") is \
        idx.row_for("dev-lang/python-3.13.14")


def test_single_slot_cat_pkg_fallback_still_answers():
    """The fallback exists for the ordinary case and must survive the fix — only
    genuinely ambiguous packages lose it."""
    idx = pf.build_flag_index(_data_lines())
    assert len(idx.by_cpv) == 229
    assert idx.multi_slot == frozenset()
    row = idx.by_cat_pkg[("dev-libs", "libnl")]
    assert idx.row_for("dev-libs/libnl-3.12.0") is row
    assert idx.row_for("dev-libs/libnl") is row          # version-less atom
    assert idx.row_for("dev-libs/not-a-package") is None


def test_plain_cpv_strips_slot_repo_and_atom_operators():
    assert pf.plain_cpv("dev-lang/python-3.13.14:3.13::gentoo") == "dev-lang/python-3.13.14"
    assert pf.plain_cpv(">=dev-libs/lzo-2.10") == "dev-libs/lzo-2.10"
    assert pf.plain_cpv("dev-libs/lzo-2.10") == "dev-libs/lzo-2.10"


# ── 4. the VDB reader ────────────────────────────────────────────────────────────────

def _build_vdb_tree(tmp_path):
    with open(os.path.join(_FIXDIR, "vdb-package-metadata.sample.json")) as fh:
        sample = json.load(fh)["packages"]
    sysroot = tmp_path / "sysroot"
    for cpv, fields in sample.items():
        cat, _, pf_name = cpv.partition("/")
        d = sysroot / "var" / "db" / "pkg" / cat / pf_name
        d.mkdir(parents=True)
        for name in pf.VDB_FIELDS:
            if fields.get(name) is not None:
                (d / name).write_text(fields[name] + "\n")
    return sysroot, sample


def test_vdb_reader_against_real_sample(tmp_path):
    sysroot, sample = _build_vdb_tree(tmp_path)
    records = pf.read_vdb_sysroot(str(sysroot))
    assert set(records) == set(sample)

    elf = records["dev-libs/elfutils-0.195"]
    assert (elf.cat, elf.pkg, elf.version) == ("dev-libs", "elfutils", "0.195")
    assert elf.license == sample["dev-libs/elfutils-0.195"]["LICENSE"]
    assert elf.keywords == sample["dev-libs/elfutils-0.195"]["KEYWORDS"]
    assert "~alpha" in elf.keywords_list and "amd64" in elf.keywords_list
    # '+debuginfod' IUSE default marker is stripped from names, order kept
    assert "debuginfod" in elf.iuse_names and "+debuginfod" not in elf.iuse_names
    assert elf.iuse_names[0] == "bzip2"
    assert "debuginfod" in elf.use_list
    assert elf.slot == "0" and elf.repository == "gentoo"
    assert elf.description.startswith("Libraries/utilities")

    ul = records["sys-apps/util-linux-2.41.4-r1"]
    assert (ul.pkg, ul.version) == ("util-linux", "2.41.4-r1")

    certifi = records["dev-python/certifi-3024.7.22"]
    assert (certifi.pkg, certifi.version) == ("certifi", "3024.7.22")


def test_vdb_missing_license_is_data_not_error(tmp_path):
    """§3: 68/319 real packages have no LICENSE file — empty column ⇒ no column."""
    sysroot, _ = _build_vdb_tree(tmp_path)
    audio = pf.read_vdb_sysroot(str(sysroot))["acct-group/audio-0-r3"]
    assert audio.license is None
    assert audio.iuse == "" and audio.iuse_names == ()
    assert audio.keywords is not None          # KEYWORDS present for 319/319
    assert (audio.cat, audio.pkg, audio.version) == ("acct-group", "audio", "0-r3")


def test_vdb_reader_tolerates_absence_and_transients(tmp_path):
    assert pf.read_vdb_sysroot(str(tmp_path / "nope")) == {}
    sysroot, _ = _build_vdb_tree(tmp_path)
    merging = sysroot / "var" / "db" / "pkg" / "dev-libs" / "-MERGING-elfutils-0.195"
    merging.mkdir()
    records = pf.read_vdb_sysroot(str(sysroot))
    assert not any("-MERGING-" in k for k in records)
    assert pf.read_vdb_package(str(tmp_path / "not-there")) is None


def test_vdb_index_by_cat_pkg(tmp_path):
    sysroot, _ = _build_vdb_tree(tmp_path)
    by_cp = pf.index_vdb_by_cat_pkg(pf.read_vdb_sysroot(str(sysroot)))
    assert by_cp[("dev-libs", "elfutils")].pf == "elfutils-0.195"


def test_split_use_expand_partitions_vdb_iuse():
    groups = ["ABI_X86", "PYTHON_TARGETS", "PYTHON_SINGLE_TARGET", "CPU_FLAGS_X86"]
    names = ["bzip2", "abi_x86_64", "python_targets_python3_12",
             "python_single_target_python3_12", "cpu_flags_x86_sse2", "nls"]
    plain, grouped = pf.split_use_expand(names, groups)
    assert plain == ("bzip2", "nls")
    assert grouped == {
        "ABI_X86": ("64",),
        "PYTHON_TARGETS": ("python3_12",),           # longest prefix wins
        "PYTHON_SINGLE_TARGET": ("python3_12",),
        "CPU_FLAGS_X86": ("sse2",),
    }


# ── 5. offline descriptions (§4) ─────────────────────────────────────────────────────

def _build_repo_tree(tmp_path):
    profiles = tmp_path / "repo" / "profiles"
    (profiles / "desc").mkdir(parents=True)
    (profiles / "use.desc").write_text(
        "# comment line\n"
        "\n"
        "ssl - Add support for SSL/TLS connections\n"
        "debug - Enable extra debug codepaths\n")
    (profiles / "use.local.desc").write_text(
        "dev-libs/libnl:debug - libnl-specific debug meaning\n"
        "sys-libs/talloc:compat - Enable the talloc compat library\n")
    (profiles / "desc" / "python_targets.desc").write_text(
        "python3_12 - Build with Python 3.12\n")
    (profiles / "desc" / "abi_x86.desc").write_text(
        "32 - 32-bit (x86) libraries\n"
        "64 - 64-bit (amd64) libraries\n")
    return tmp_path / "repo"


def test_descriptions_from_host_tree(tmp_path):
    d = pf.FlagDescriptions(repo_root=str(_build_repo_tree(tmp_path)))
    # the desc/ filenames ARE the group list (§4.1)
    assert d.use_expand_groups() == ("ABI_X86", "PYTHON_TARGETS")
    assert d.describe("ssl") == "Add support for SSL/TLS connections"
    # package-local meaning wins over the global one
    assert d.describe("debug", cat_pkg="dev-libs/libnl") == "libnl-specific debug meaning"
    # unknown package falls back to the global description
    assert d.describe("debug", cat_pkg="x/y") == "Enable extra debug codepaths"
    # USE_EXPAND members resolve by printed suffix against the group file
    assert d.describe("python3_12", group="PYTHON_TARGETS") == "Build with Python 3.12"
    assert d.describe("64", group="ABI_X86") == "64-bit (amd64) libraries"
    assert d.describe("no-such-flag") is None
    assert d.describe("no-such", group="PYTHON_TARGETS") is None


def test_descriptions_graceful_when_tree_absent(tmp_path):
    """Non-Gentoo host / archived session: descriptions are simply None (§4.2)."""
    d = pf.FlagDescriptions(repo_root=str(tmp_path / "no-such-tree"))
    assert d.describe("ssl") is None
    assert d.describe("debug", cat_pkg="dev-libs/libnl") is None
    assert d.describe("python3_12", group="PYTHON_TARGETS") is None


def test_use_expand_group_names_survive_a_missing_tree(tmp_path):
    """The group NAMES are not descriptions and must not vanish with the tree.

    §4.2: <sysroot>/var/db/repos/gentoo is an empty bind-mount point in every
    captured build, so an archived session opened on a non-Gentoo machine has no
    profiles/desc listing — and the §4.4 sidecar carries descriptions, not the
    group list. Returning () there does NOT degrade gracefully: split_use_expand
    can then split nothing, so every USE_EXPAND flag folds back into plain USE
    under its full prefixed name (the flat prefix-mixing shape §3.1 calls out as
    the elog header's defect) and the USE_EXPAND column is never revealed."""
    absent = pf.FlagDescriptions(repo_root=str(tmp_path / "no-such-tree"))
    assert absent.use_expand_groups() == tuple(sorted(pf.USE_EXPAND_GROUPS_FALLBACK))
    assert absent.use_expand_groups_source() == "fallback"
    # the snapshot is the real tree-wide list, and the groups the fleet's own
    # builds actually touch (§4.3) are all in it
    assert len(pf.USE_EXPAND_GROUPS_FALLBACK) == 52
    for g in ("ABI_MIPS", "ABI_S390", "ABI_X86", "CPU_FLAGS_ARM", "CPU_FLAGS_PPC",
              "CPU_FLAGS_X86", "CURL_SSL", "GUILE_SINGLE_TARGET", "L10N",
              "LLVM_SLOT", "PERL_FEATURES", "PYTHON_SINGLE_TARGET",
              "PYTHON_TARGETS"):
        assert g in pf.USE_EXPAND_GROUPS_FALLBACK, g
    # ...and the split genuinely works off it
    plain, grouped = pf.split_use_expand(
        ["test", "python_targets_python3_13", "abi_x86_64"],
        absent.use_expand_groups())
    assert plain == ("test",)
    assert grouped == {"PYTHON_TARGETS": ("python3_13",), "ABI_X86": ("64",)}


def test_a_live_tree_and_a_sidecar_both_outrank_the_snapshot(tmp_path):
    """§4.1: the profiles/desc filenames are authoritative when they exist, and a
    §4.4 sidecar's @GROUP: keys name every group the session's own build saw."""
    root = _build_repo_tree(tmp_path)
    tree_only = pf.FlagDescriptions(repo_root=str(root))
    assert tree_only.use_expand_groups() == ("ABI_X86", "PYTHON_TARGETS")
    assert tree_only.use_expand_groups_source() == "tree+sidecar"

    sidecar = str(tmp_path / pf.SIDECAR_BASENAME)
    with open(sidecar, "w") as fh:
        json.dump({"@LLVM_SLOT:19": "Build against LLVM 19",
                   "*:ssl": "sidecar global"}, fh)
    # sidecar alone (archived session WITH a sidecar): its groups, not the snapshot
    no_tree = pf.FlagDescriptions(repo_root=str(tmp_path / "gone"), sidecar=sidecar)
    assert no_tree.use_expand_groups() == ("LLVM_SLOT",)
    assert no_tree.use_expand_groups_source() == "sidecar"
    # both: the union, so neither source can hide a group from the split
    both = pf.FlagDescriptions(repo_root=str(root), sidecar=sidecar)
    assert both.use_expand_groups() == ("ABI_X86", "LLVM_SLOT", "PYTHON_TARGETS")


def test_descriptions_size_bound_refuses_absurd_files(tmp_path):
    root = _build_repo_tree(tmp_path)
    d = pf.FlagDescriptions(repo_root=str(root), max_file_bytes=8)
    assert d.describe("ssl") is None       # file exists but exceeds the bound


def test_sidecar_format_and_precedence(tmp_path):
    """§4.4: {"cat/pkg:flag" | "*:flag" | "@GROUP:flag" → description}; a session
    sidecar always wins over the host tree."""
    root = _build_repo_tree(tmp_path)
    session = tmp_path / "session"
    session.mkdir()
    sidecar = pf.sidecar_path_for_session(str(session))
    assert os.path.basename(sidecar) == pf.SIDECAR_BASENAME
    with open(sidecar, "w") as fh:
        json.dump({
            "dev-libs/libnl:debug": "sidecar per-package",
            "*:ssl": "sidecar global",
            "@PYTHON_TARGETS:python3_12": "sidecar group",
            "bogus-non-string": 7,          # ignored, not fatal
        }, fh)
    d = pf.FlagDescriptions(repo_root=str(root), sidecar=sidecar)
    assert d.describe("debug", cat_pkg="dev-libs/libnl") == "sidecar per-package"
    assert d.describe("ssl") == "sidecar global"
    assert d.describe("python3_12", group="PYTHON_TARGETS") == "sidecar group"
    # keys absent from the sidecar still resolve from the tree
    assert d.describe("64", group="ABI_X86") == "64-bit (amd64) libraries"
    # and the sidecar alone suffices with NO tree at all (archived session)
    d2 = pf.FlagDescriptions(repo_root=str(tmp_path / "gone"), sidecar=sidecar)
    assert d2.describe("ssl") == "sidecar global"


def test_sidecar_gzip_and_malformed(tmp_path):
    gz = str(tmp_path / (pf.SIDECAR_BASENAME + ".gz"))
    with gzip.open(gz, "wt", encoding="utf-8") as fh:
        json.dump({"*:nls": "Native language support"}, fh)
    assert pf.load_sidecar(gz) == {"*:nls": "Native language support"}
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    assert pf.load_sidecar(str(bad)) == {}
    assert pf.load_sidecar(str(tmp_path / "absent.json")) == {}
    lst = tmp_path / "list.json"
    lst.write_text("[1, 2]")
    assert pf.load_sidecar(str(lst)) == {}


# ── 6. the standing no-network rule ──────────────────────────────────────────────────

def test_module_never_imports_network_code():
    """§4.5 hard rule: URLs may be constructed, never fetched — so the module
    must not IMPORT any network machinery (checked on the real import graph,
    not on prose: the docstring is allowed to state the rule)."""
    import ast
    src_path = os.path.join(os.path.dirname(pf.__file__), "package_flags.py")
    with open(src_path) as fh:
        tree = ast.parse(fh.read())
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            imported.add(node.module or "")
    forbidden = {"urllib", "urllib.request", "requests", "http", "http.client",
                 "socket", "PySide6.QtNetwork", "PyQt6.QtNetwork"}
    assert not (imported & forbidden), imported & forbidden
    assert not any(m.startswith(("urllib", "http", "requests")) for m in imported)
