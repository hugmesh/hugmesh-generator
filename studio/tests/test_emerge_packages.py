"""Per-PACKAGE emerge parsing — group banners, the ebuild step ladder, the full elog
header block (USE flags included), build-tool telemetry (ninja/make/cmake/configure/npm/
cargo -> tool_info, with ninja's N/M refining the compile percent), per-package log
discovery, the failure path, and the (N of M) reconstruction that survives portage's
counter restarts.

Every literal line fed below is copied from the real transcript of session
``20260725-140638-09692d`` (``build-standalone-unaffiliated.x86.log``, 3.16M lines) or from
the per-package logs under its
``wl-standalone-unaffiliated.x86/sysroot/var/log/portage/build/`` — cited by line number at
each use so a future reader can re-check the format instead of trusting this file.
"""
import dataclasses
import os
import subprocess
import sys

import pytest

from hugmesh_studio.core import emerge_packages as ep

_STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# SGR wrappers exactly as portage emits them. The elog header uses a green "*" bullet
# followed by a reset-to-default (\x1b[39;49;00m) — verified byte-for-byte with od -c on
# media-libs:freetype-2.14.3:20260725-211000.log, whose first bytes are
# 033 [ 3 2 m sp * sp 033 [ 3 9 ; 4 9 ; 0 0 m P a c k a g e :
_GREEN, _RESET = "\x1b[32m", "\x1b[39;49;00m"
_CYAN, _BOLD, _RST = "\x1b[36m", "\x1b[1m", "\x1b[0m"


def _elog(text: str) -> str:
    return f"{_GREEN} * {_RESET}{text}"


def _banner(text: str) -> str:
    """The builders' banner() wrapping, same as test_progress_parse.py uses."""
    return f"{_CYAN}{_BOLD}==> {text}{_RST}"


# The real freetype log head, reproduced verbatim (321 bytes on disk).
_FREETYPE_LOG = "\n".join([
    _elog("Package:    media-libs/freetype-2.14.3:2"),
    _elog("Repository: gentoo"),
    _elog("Maintainer: fonts@gentoo.org"),
    _elog("USE:        X abi_x86_64 adobe-cff amd64 bzip2 cleartype-hinting elibc_glibc "
          "harfbuzz kernel_linux png"),
    _elog("FEATURES:   nostrip preserve-libs"),
]) + "\n"


# ── the cross-lane group-banner contract ─────────────────────────────────────────────
def test_group_banner_wire_format_is_pinned():
    """The builders lane emits this EXACT string; a reword on either side must fail here
    rather than silently un-group every package in the GUI."""
    assert ep.GROUP_BANNER_PREFIX == "==> Emerge group: "
    assert ep.EMERGE_GROUPS == ("image", "tools", "dependencies", "system", "world")
    assert ep.GROUP_UNKNOWN == ""


@pytest.mark.parametrize("group", ep.EMERGE_GROUPS)
def test_group_banner_switches_group(group):
    p = ep.EmergePackageParser()
    assert p.feed(_banner(f"Emerge group: {group}")) is None   # moves no package
    assert p.group() == group


def test_group_banner_matched_through_ansi_and_via_the_pinned_prefix():
    # both the banner() wrapping and a bare echo of the pinned prefix must land
    for line in (_banner("Emerge group: world"), ep.GROUP_BANNER_PREFIX + "world"):
        p = ep.EmergePackageParser()
        p.feed(line)
        assert p.group() == "world"


def test_unknown_group_name_is_ignored_not_invented():
    p = ep.EmergePackageParser()
    p.feed(_banner("Emerge group: system"))
    p.feed(_banner("Emerge group: kitchen-sink"))
    assert p.group() == "system"


def test_group_is_honestly_unknown_before_the_first_banner():
    """Defaulting to "image" would file the builder's pre-banner packages under the wrong
    heading; "" says what we actually know."""
    p = ep.EmergePackageParser()
    assert p.group() == ep.GROUP_UNKNOWN
    pkg = p.feed(">>> Emerging (1 of 1) sys-devel/gettext-0.22.5-r2::gentoo")
    assert pkg.group == ep.GROUP_UNKNOWN


# ── atom splitting ───────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("atom,expect", [
    # every one of these is a real atom from the transcript
    ("dev-lang/duktape-2.7.0-r3", ("dev-lang", "duktape", "2.7.0-r3")),          # L17744
    ("acct-group/polkitd-0-r3", ("acct-group", "polkitd", "0-r3")),              # L17836
    ("dev-lang/python-exec-conf-2.4.6", ("dev-lang", "python-exec-conf", "2.4.6")),  # L18025
    ("llvm-runtimes/compiler-rt-sanitizers-22.1.8",
     ("llvm-runtimes", "compiler-rt-sanitizers", "22.1.8")),                     # L298427
    ("dev-lang/python-3.12.13_p1", ("dev-lang", "python", "3.12.13_p1")),        # L74666
    ("app-office/libreoffice-25.2.7.2-r1", ("app-office", "libreoffice", "25.2.7.2-r1")),
    ("sys-libs/pam_wrapper-1.1.8", ("sys-libs", "pam_wrapper", "1.1.8")),        # L2729778
    ("net-misc/ethertypes-0", ("net-misc", "ethertypes", "0")),                  # L18414
])
def test_split_atom_shapes(atom, expect):
    assert ep.split_atom(atom) == expect


def test_split_atom_degrades_instead_of_guessing():
    # no version to be found -> report the raw text, never a fabricated version
    assert ep.split_atom("sys-apps/weird_name") == ("sys-apps", "weird_name", "")
    assert ep.split_atom("no-slash-at-all") == ("", "no-slash-at-all", "")


# ── the counter lines ────────────────────────────────────────────────────────────────
def test_emerging_counter_creates_a_row():
    p = ep.EmergePackageParser()
    p.feed(_banner("Emerge group: image"))
    pkg = p.feed(">>> Emerging (1 of 258) dev-lang/duktape-2.7.0-r3::gentoo")   # L17744
    assert (pkg.atom, pkg.category, pkg.name, pkg.version) == (
        "dev-lang/duktape-2.7.0-r3", "dev-lang", "duktape", "2.7.0-r3")
    assert (pkg.index, pkg.total, pkg.group) == (1, 258, "image")
    assert pkg.step == "queued" and pkg.percent == 0 and not pkg.failed
    assert p.current() is pkg


def test_emerging_binary_counter_is_the_same_row_shape():
    """Binary merges print ``Emerging binary`` and then skip the whole ebuild ladder —
    line 2526970 goes Emerging binary -> Extracting -> Installing -> Completed."""
    p = ep.EmergePackageParser()
    pkg = p.feed(">>> Emerging binary (436 of 805) sys-apps/groff-1.23.0-r2::gentoo")
    assert pkg.name == "groff" and (pkg.index, pkg.total) == (436, 805)


def test_repo_suffix_is_optional():
    p = ep.EmergePackageParser()
    pkg = p.feed(">>> Emerging (2 of 9) sys-apps/hwdata-0.401")
    assert pkg.atom == "sys-apps/hwdata-0.401"


# ── the cross-build target-root tail ────────────────────────────────────────────────
# Every ARM builder emerges into ${BUILD_ROOT}/sysroot, and portage then appends the
# target root to these lines. Lines below are copied from the operator's real
# out/sessions/20260729-065121-ce11e0/build-pki.rpi5.log (L137/L155 Emerging, the
# Installing/Completed twins from the same run). 222 of that log's 283 Emerging lines
# carry the tail — it marks precisely the packages that land in the IMAGE, while host
# BDEPEND tools merged to / have no tail. A `$`-anchored counter regex dropped all of
# them, so the Studio tree listed 61 host tools out of 266 real packages.
@pytest.mark.parametrize("line, atom", [
    (">>> Emerging (1 of 149) dev-libs/xxhash-0.8.3-r2::gentoo "
     "for /out/wl-pki.rpi5/sysroot/", "dev-libs/xxhash-0.8.3-r2"),
    (">>> Installing (1 of 149) dev-libs/xxhash-0.8.3-r2::gentoo "
     "to /out/wl-pki.rpi5/sysroot/", "dev-libs/xxhash-0.8.3-r2"),
    (">>> Emerging binary (436 of 805) sys-apps/groff-1.23.0-r2::gentoo "
     "for /out/wl-pki.rpi5/sysroot/", "sys-apps/groff-1.23.0-r2"),
    (">>> Emerging (7 of 149) sys-apps/hwdata-0.401 for /out/wl-pki.rpi5/sysroot/",
     "sys-apps/hwdata-0.401"),
])
def test_cross_build_target_root_tail_still_opens_the_row(line, atom):
    p = ep.EmergePackageParser()
    pkg = p.feed(line)
    assert pkg is not None, "a cross build's target packages must not be dropped"
    assert pkg.atom == atom


def test_cross_build_row_reaches_done_through_the_tailed_completed_line():
    """``Completed`` carries the tail too (">>> Completed (1 of 1) …::gentoo to <root>"),
    so without it a cross build's rows would sit forever below 100%."""
    p = ep.EmergePackageParser()
    p.feed(">>> Emerging (1 of 1) app-containers/cni-plugins-1.9.1::gentoo "
           "for /out/wl-pki.rpi5/sysroot/")
    pkg = p.feed(">>> Completed (1 of 1) app-containers/cni-plugins-1.9.1::gentoo "
                 "to /out/wl-pki.rpi5/sysroot/")
    assert (pkg.step, pkg.percent) == ("done", 100)


def test_the_root_tail_is_matched_not_captured_into_the_atom():
    """The atom is the row key — a leaked sysroot path would fork one package into two
    rows (native vs cross) and break every dict keyed by it."""
    p = ep.EmergePackageParser()
    plain = p.feed(">>> Emerging (1 of 2) dev-libs/xxhash-0.8.3-r2::gentoo")
    tailed = p.feed(">>> Emerging (2 of 2) dev-libs/xxhash-0.8.3-r2::gentoo "
                    "for /out/wl-pki.rpi5/sysroot/")
    assert plain.atom == tailed.atom
    assert "/out/" not in tailed.atom and "sysroot" not in tailed.atom


def test_the_tail_does_not_swallow_a_trailing_atom_like_word():
    """Only portage's own ``for``/``to`` preposition may be absorbed. Anything else after
    the atom means the line is not the shape we think it is, and inventing a row from it
    would be a guess."""
    p = ep.EmergePackageParser()
    assert p.feed(">>> Emerging (1 of 2) dev-libs/xxhash-0.8.3-r2::gentoo AND MORE") is None


def test_a_cross_build_lists_host_tools_AND_target_packages():
    """THE REGRESSION THIS PINS. A cross build interleaves untailed host BDEPEND merges
    with tailed target merges; the tree must show BOTH. Feeding only the untailed half is
    what the operator saw — 61 of 266 packages on a Pi mesh build."""
    p = ep.EmergePackageParser()
    p.feed(_banner("Emerge group: system"))
    for i, (atom, tail) in enumerate([
        ("dev-lang/python-exec-conf-2.4.6", ""),                       # host tool, no tail
        ("dev-libs/xxhash-0.8.3-r2", " for /out/wl-pki.rpi5/sysroot/"),
        ("acct-group/messagebus-0-r3", ""),
        ("net-libs/libnfnetlink-1.0.2", " for /out/wl-pki.rpi5/sysroot/"),
        ("app-containers/cni-plugins-1.9.1", " for /out/wl-pki.rpi5/sysroot/"),
    ], start=1):
        p.feed(f">>> Emerging ({i} of 5) {atom}::gentoo{tail}")
    seen = {x.atom for x in p.packages()}
    assert len(seen) == 5, f"a cross build must list every package, got {sorted(seen)}"
    assert "dev-libs/xxhash-0.8.3-r2" in seen and "acct-group/messagebus-0-r3" in seen


# The skipif-guarded replay of the operator's real cross-build log (266 rows, every one
# reaching 100%) lives in test_emerge_packages_parallel.py ::
# test_real_parallel_rpi5_transcript_replays_every_package — it is the same replay of the
# same transcript asserting the same 266, so it is kept in ONE place rather than two. That
# copy resolves the transcript through _operator_log() (several candidate session dirs plus
# a $HUGMESH_STUDIO_SESSIONS override) instead of one hard-coded path, and additionally
# pins the scheduler aggregate, the empty in-flight set, no-failures, percent == 100, and
# that a --jobs=1 build is NOT reported as parallel. The x86 serial transcript has a
# matching anchor beside it. The non-replay tail tests above are the ones unique to here.


def test_non_package_lines_return_none():
    p = ep.EmergePackageParser()
    for noise in ("Calculating dependencies  ... done!",
                  " 9650K .......... .......... 96% 51.9M 0s",
                  ">>> Running pre-merge checks for media-gfx/gimp-3.2.4",   # L2794920
                  "stty: 'standard input': Inappropriate ioctl for device"):
        assert p.feed(noise) is None


# ── the ebuild step ladder ───────────────────────────────────────────────────────────
# Verbatim from lines 322..16270 (sys-devel/gettext-0.22.5-r2) of the real transcript.
_GETTEXT_LADDER = [
    ">>> Unpacking source...",
    ">>> Unpacking 'gettext-0.22.5.tar.xz' to /var/tmp/portage/sys-devel/gettext-0.22.5-r2/work",
    ">>> Source unpacked in /var/tmp/portage/sys-devel/gettext-0.22.5-r2/work",
    ">>> Preparing source in /var/tmp/portage/sys-devel/gettext-0.22.5-r2/work/gettext-0.22.5 ...",
    ">>> Source prepared.",
    ">>> Configuring source in /var/tmp/portage/sys-devel/gettext-0.22.5-r2/work/gettext-0.22.5 ...",
    ">>> Source configured.",
    ">>> Compiling source in /var/tmp/portage/sys-devel/gettext-0.22.5-r2/work/gettext-0.22.5 ...",
    ">>> Source compiled.",
    ">>> Test phase [not enabled]: sys-devel/gettext-0.22.5-r2",
    ">>> Install sys-devel/gettext-0.22.5-r2 into /var/tmp/portage/sys-devel/gettext-0.22.5-r2/image",
    ">>> Completed installing sys-devel/gettext-0.22.5-r2 into "
    "/var/tmp/portage/sys-devel/gettext-0.22.5-r2/image",
]


def test_ladder_walks_the_steps_in_order_and_percent_is_monotonic():
    p = ep.EmergePackageParser()
    p.feed(_banner("Emerge group: system"))
    pkg = p.feed(">>> Emerging (1 of 1) sys-devel/gettext-0.22.5-r2::gentoo")
    seen_steps, last = [pkg.step], pkg.percent
    for ln in _GETTEXT_LADDER:
        p.feed(ln)
        assert pkg.percent >= last, f"regressed at {ln!r}: {pkg.percent} < {last}"
        assert pkg.percent < 100, "only step=='done' may reach 100"
        last = pkg.percent
        if pkg.step != seen_steps[-1]:
            seen_steps.append(pkg.step)
    assert seen_steps == ["queued", "unpack", "prepare", "configure", "compile",
                          "test", "install"]
    # ">>> Completed (N of M)" is the terminal marker, not "Completed installing"
    p.feed(">>> Completed (1 of 1) sys-devel/gettext-0.22.5-r2::gentoo")
    assert pkg.step == "done" and pkg.percent == 100 and not pkg.failed


def test_the_alternate_test_phase_wording_also_lands():
    """Both wordings occur in the real logs: "[not enabled]" (main stream L13775) and
    "[disabled because of RESTRICT=test]" (sys-libs:libseccomp-2.6.0-r3 log, line 183)."""
    for text in ("[not enabled]", "[disabled because of RESTRICT=test]"):
        p = ep.EmergePackageParser()
        p.feed(">>> Emerging (1 of 1) sys-libs/libseccomp-2.6.0-r3::gentoo")
        pkg = p.feed(f">>> Test phase {text}: sys-libs/libseccomp-2.6.0-r3")
        assert pkg is not None and pkg.step == "test"


def test_step_percent_ladder_is_ordered_and_only_done_is_100():
    pcts = [ep.STEP_PERCENT[s] for s in ep.STEPS]
    assert pcts == sorted(pcts) and len(set(pcts)) == len(pcts)
    assert ep.STEP_PERCENT["done"] == 100
    assert max(ep.STEP_PERCENT[s] for s in ep.STEPS if s != "done") < 100
    # compile is the long pole (69% of gettext's log lines) — its band must dominate
    bands = {s: ep.STEP_PERCENT[ep.STEPS[i + 1]] - ep.STEP_PERCENT[s]
             for i, s in enumerate(ep.STEPS[:-1])}
    assert bands["compile"] == max(bands.values())


def test_out_of_order_ladder_line_cannot_drag_a_package_backwards():
    p = ep.EmergePackageParser()
    p.feed(">>> Emerging (1 of 1) sys-devel/gettext-0.22.5-r2::gentoo")
    for ln in _GETTEXT_LADDER:
        p.feed(ln)
    pkg = p.packages()[0]
    at_install = (pkg.step, pkg.percent)
    p.feed(">>> Unpacking source...")
    assert (pkg.step, pkg.percent) == at_install


def test_binary_merge_reaches_done_without_any_ladder_line():
    """The ladder steps must not be a precondition for install/done — a binpkg merge
    never emits one (line 2526970 groff)."""
    p = ep.EmergePackageParser()
    p.feed(_banner("Emerge group: dependencies"))
    p.feed(">>> Emerging binary (436 of 805) sys-apps/groff-1.23.0-r2::gentoo")
    pkg = p.feed(">>> Installing (436 of 805) sys-apps/groff-1.23.0-r2::gentoo")
    assert pkg.step == "install" and 0 < pkg.percent < 100
    p.feed(">>> Completed (436 of 805) sys-apps/groff-1.23.0-r2::gentoo")
    assert pkg.step == "done" and pkg.percent == 100


def test_completed_installing_is_not_mistaken_for_the_terminal_completed():
    p = ep.EmergePackageParser()
    p.feed(">>> Emerging (1 of 1) sys-devel/gettext-0.22.5-r2::gentoo")
    pkg = p.feed(">>> Completed installing sys-devel/gettext-0.22.5-r2 into "
                 "/var/tmp/portage/sys-devel/gettext-0.22.5-r2/image")
    assert pkg.step == "install" and pkg.step != "done" and pkg.percent < 100


# ── attribution under parallel emerge ────────────────────────────────────────────────
def test_anonymous_ladder_lines_are_dropped_when_several_packages_are_in_flight():
    """x86/rpi5 serialise (EMERGE_JOBS=1) so ">>> Compiling source in ..." is unambiguous,
    but jetson/frite/orangepi pass --jobs="${JOBS}". With two packages in flight the line
    genuinely cannot be attributed, so NEITHER bar may move — crediting the wrong one is
    the dishonest option."""
    p = ep.EmergePackageParser()
    a = p.feed(">>> Emerging (1 of 20) dev-libs/libfoo-1.0::gentoo")
    b = p.feed(">>> Emerging (2 of 20) dev-libs/libbar-2.0::gentoo")
    assert p.feed(">>> Compiling source in /var/tmp/portage/dev-libs/libfoo-1.0/work") is None
    assert a.step == "queued" and b.step == "queued"
    # the atom-NAMED markers still move the right row, so the bars keep advancing
    assert p.feed(">>> Install dev-libs/libfoo-1.0 into "
                  "/var/tmp/portage/dev-libs/libfoo-1.0/image") is a
    assert a.step == "install" and b.step == "queued"
    # once libfoo completes, libbar is alone again and anonymous lines resume
    p.feed(">>> Completed (1 of 20) dev-libs/libfoo-1.0::gentoo")
    assert p.feed(">>> Compiling source in /var/tmp/portage/dev-libs/libbar-2.0/work") is b
    assert b.step == "compile"


def test_current_is_none_when_nothing_is_in_flight():
    p = ep.EmergePackageParser()
    assert p.current() is None
    pkg = p.feed(">>> Emerging (1 of 1) net-misc/ethertypes-0::gentoo")
    assert p.current() is pkg
    p.feed(">>> Completed (1 of 1) net-misc/ethertypes-0::gentoo")
    assert p.current() is None


# ── the failure path ─────────────────────────────────────────────────────────────────
# Verbatim from lines 2794910-2794913, the libreoffice failure that PR #461 was about.
_LIBREOFFICE_FAILURE = [
    ">>> Failed to emerge app-office/libreoffice-25.2.7.2-r1, Log file:",
    "",
    ">>>  '/var/log/portage/build/app-office:libreoffice-25.2.7.2-r1:20260726-024143.log'",
]


def test_failed_package_is_red_terminal_and_never_done():
    p = ep.EmergePackageParser()
    p.feed(_banner("Emerge group: image"))
    pkg = p.feed(">>> Emerging (561 of 805) app-office/libreoffice-25.2.7.2-r1::gentoo")
    p.feed(">>> Compiling source in /var/tmp/portage/app-office/libreoffice-25.2.7.2-r1/work")
    at_death = pkg.percent
    for ln in _LIBREOFFICE_FAILURE:
        p.feed(ln)
    assert pkg.failed and pkg.step == "failed"
    assert pkg.percent == at_death, "percent must freeze where the build actually got to"
    assert pkg.percent < 100
    # a stray later marker must NOT be able to turn a red row green: --keep-going drops
    # the failed atom from the resumed list (L2794913) rather than retrying it
    p.feed(">>> Completed (561 of 805) app-office/libreoffice-25.2.7.2-r1::gentoo")
    assert pkg.failed and pkg.step == "failed" and pkg.percent < 100
    assert p.current() is None                        # a dead package is not in flight


def test_failure_log_path_is_rebased_onto_log_root(tmp_path):
    """Portage prints a CHROOT-absolute path (``/var/log/portage/build/...``) which does
    not exist on the host — it must be rebased onto the session's sysroot log dir."""
    root = tmp_path / "sysroot" / "var" / "log" / "portage" / "build"
    root.mkdir(parents=True)
    p = ep.EmergePackageParser(log_root=str(root))
    p.feed(">>> Emerging (561 of 805) app-office/libreoffice-25.2.7.2-r1::gentoo")
    for ln in _LIBREOFFICE_FAILURE:
        p.feed(ln)
    pkg = p.packages()[0]
    assert pkg.log_path == os.path.join(
        str(root), "app-office:libreoffice-25.2.7.2-r1:20260726-024143.log")


def test_failure_without_a_log_line_still_fails_cleanly():
    p = ep.EmergePackageParser()
    p.feed(">>> Emerging (1 of 3) dev-libs/libfoo-1.0::gentoo")
    pkg = p.feed(">>> Failed to emerge dev-libs/libfoo-1.0")
    assert pkg.failed and pkg.step == "failed" and pkg.log_path == ""


def test_a_late_quoted_log_line_outside_the_window_is_not_glued_on(tmp_path):
    p = ep.EmergePackageParser(log_root=str(tmp_path))
    p.feed(">>> Failed to emerge dev-libs/libfoo-1.0, Log file:")
    for _ in range(ep._FAILED_LOG_WINDOW + 1):
        p.feed("noise")
    p.feed(">>>  '/var/log/portage/build/dev-libs:libbar-2.0:20260726-024143.log'")
    assert p.packages()[0].log_path == ""


# ── USE flags from the per-package log ───────────────────────────────────────────────
def test_parse_use_flags_from_the_real_ansi_coloured_header(tmp_path):
    log = tmp_path / "media-libs:freetype-2.14.3:20260725-211000.log"
    log.write_text(_FREETYPE_LOG, encoding="utf-8")
    assert ep.parse_use_flags(str(log)) == (
        "X", "abi_x86_64", "adobe-cff", "amd64", "bzip2", "cleartype-hinting",
        "elibc_glibc", "harfbuzz", "kernel_linux", "png")


def test_parse_use_flags_missing_unreadable_or_headerless_returns_empty(tmp_path):
    assert ep.parse_use_flags("") == ()
    assert ep.parse_use_flags(str(tmp_path / "nope.log")) == ()
    assert ep.parse_use_flags(str(tmp_path)) == ()          # a directory is an OSError
    headerless = tmp_path / "x.log"
    headerless.write_text(">>> Unpacking source...\n", encoding="utf-8")
    assert ep.parse_use_flags(str(headerless)) == ()


def test_parse_use_flags_survives_undecodable_bytes(tmp_path):
    log = tmp_path / "y.log"
    log.write_bytes(b"\xff\xfe garbage\n" + _FREETYPE_LOG.encode("utf-8"))
    assert "harfbuzz" in ep.parse_use_flags(str(log))


def test_parse_use_flags_does_not_scan_a_whole_compile_log(tmp_path):
    """The header is in the first ~5 lines; a USE-looking string deep in a build log must
    not be picked up (and a 100 MB log must not be walked)."""
    log = tmp_path / "z.log"
    log.write_text("noise\n" * (ep._USE_HEADER_SCAN_LINES + 5)
                   + _elog("USE:        should_not_be_seen") + "\n", encoding="utf-8")
    assert ep.parse_use_flags(str(log)) == ()


# ── the full elog header block (parse_header) ────────────────────────────────────────
# The real BINARY-merge log head, reproduced verbatim from
# sys-apps:groff-1.23.0-r2:20260726-015900.log lines 1-6 (the ">>> Emerging binary"
# merge of main-stream line 2526970): the header does NOT start at line 0 and has NO
# Maintainer row.
_GROFF_BINARY_LOG = "\n".join([
    ">>> Extracting info",
    _elog("Package:    sys-apps/groff-1.23.0-r2:0"),
    _elog("Repository: gentoo"),
    _elog("USE:        kernel_linux abi_x86_64 elibc_glibc amd64 X"),
    _elog("FEATURES:   nostrip preserve-libs"),
    ">>> Extracting sys-apps/groff-1.23.0-r2",
]) + "\n"


def test_parse_header_reads_the_full_real_header(tmp_path):
    log = tmp_path / "media-libs:freetype-2.14.3:20260725-211000.log"
    log.write_text(_FREETYPE_LOG, encoding="utf-8")
    assert ep.parse_header(str(log)) == {
        "Package": "media-libs/freetype-2.14.3:2",
        "Repository": "gentoo",
        "Maintainer": "fonts@gentoo.org",
        "USE": "X abi_x86_64 adobe-cff amd64 bzip2 cleartype-hinting elibc_glibc "
               "harfbuzz kernel_linux png",
        "FEATURES": "nostrip preserve-libs",
    }


def test_parse_header_binary_merge_shape_not_line_zero_no_maintainer(tmp_path):
    """Demanding line 0 or a fixed key set would return {} for every binpkg merge —
    the groff log opens with ``>>> Extracting info`` and never names a Maintainer."""
    log = tmp_path / "sys-apps:groff-1.23.0-r2:20260726-015900.log"
    log.write_text(_GROFF_BINARY_LOG, encoding="utf-8")
    hdr = ep.parse_header(str(log))
    assert hdr == {
        "Package": "sys-apps/groff-1.23.0-r2:0",
        "Repository": "gentoo",
        "USE": "kernel_linux abi_x86_64 elibc_glibc amd64 X",
        "FEATURES": "nostrip preserve-libs",
    }


def test_parse_header_missing_unreadable_or_headerless_returns_empty(tmp_path):
    assert ep.parse_header("") == {}
    assert ep.parse_header(str(tmp_path / "nope.log")) == {}
    assert ep.parse_header(str(tmp_path)) == {}             # a directory is an OSError
    # an asterisk line that is NOT "Key: value"-shaped (the real iptables pkg_prerm
    # trailer) must not be mistaken for a one-row header
    trailer = tmp_path / "t.log"
    trailer.write_text(_elog("Unsetting ebtables symlinks before removal") + "\n",
                       encoding="utf-8")
    assert ep.parse_header(str(trailer)) == {}


def test_parse_header_stops_at_the_end_of_the_contiguous_block(tmp_path):
    """A later elog row (" * ERROR: ... failed (compile phase):" is what a real failure
    prints) must not be glued onto the header once the block has ended."""
    log = tmp_path / "x.log"
    log.write_text(_FREETYPE_LOG + ">>> Unpacking source...\n"
                   + _elog("ERROR: media-libs/freetype-2.14.3 failed (compile phase):")
                   + "\n", encoding="utf-8")
    hdr = ep.parse_header(str(log))
    assert "ERROR" not in hdr and hdr["Package"] == "media-libs/freetype-2.14.3:2"


def test_parse_use_flags_is_exactly_the_use_row_of_parse_header(tmp_path):
    log = tmp_path / "sys-apps:groff-1.23.0-r2:20260726-015900.log"
    log.write_text(_GROFF_BINARY_LOG, encoding="utf-8")
    assert " ".join(ep.parse_use_flags(str(log))) == ep.parse_header(str(log))["USE"]


def test_parser_populates_header_when_the_log_resolves(tmp_path):
    (tmp_path / "media-libs:freetype-2.14.3:20260725-211000.log").write_text(
        _FREETYPE_LOG, encoding="utf-8")
    p = ep.EmergePackageParser(log_root=str(tmp_path))
    pkg = p.feed(">>> Emerging (7 of 258) media-libs/freetype-2.14.3::gentoo")
    assert pkg.header["Maintainer"] == "fonts@gentoo.org"
    assert pkg.header["FEATURES"] == "nostrip preserve-libs"
    assert pkg.use_flags == tuple(pkg.header["USE"].split())


def test_header_and_tool_info_start_empty():
    p = ep.EmergePackageParser()                    # no log_root -> nothing to read
    pkg = p.feed(">>> Emerging (1 of 1) media-libs/freetype-2.14.3::gentoo")
    assert pkg.header == {} and pkg.tool_info == ""


# ── per-package log discovery ────────────────────────────────────────────────────────
def test_find_package_log_picks_the_newest_stamp(tmp_path):
    """Not hypothetical: the real session holds BOTH
    sys-devel:gettext-0.22.5-r2:20260725-210758.log and ...-210759.log, because the x86
    builder's quarantine downgrade (build-x86-host-stage4.sh:4420) merges gettext twice."""
    for stamp in ("20260725-210759", "20260725-210758", "20260724-999999"):
        (tmp_path / f"sys-devel:gettext-0.22.5-r2:{stamp}.log").write_text("x")
    got = ep.find_package_log(str(tmp_path), "sys-devel/gettext-0.22.5-r2")
    assert os.path.basename(got) == "sys-devel:gettext-0.22.5-r2:20260725-210759.log"


def test_find_package_logs_is_newest_first(tmp_path):
    for stamp in ("20260725-211746", "20260725-211759"):
        (tmp_path / f"net-firewall:iptables-1.8.13:{stamp}.log").write_text("x")
    got = [os.path.basename(x)
           for x in ep.find_package_logs(str(tmp_path), "net-firewall/iptables-1.8.13")]
    assert got == ["net-firewall:iptables-1.8.13:20260725-211759.log",
                   "net-firewall:iptables-1.8.13:20260725-211746.log"]


def test_use_flags_skip_a_headerless_unmerge_trailer(tmp_path):
    """Replaying the real session found three packages — net-firewall/iptables-1.8.13,
    dev-build/cmake-4.3.4, app-crypt/pinentry-1.3.2-r1 — whose NEWEST log is a 45-657 byte
    pkg_prerm/postrm trailer with no elog header at all, written after their real 236 KB /
    1.2 MB build log. Both the USE column and the click-through must land on the build
    log, not the stub. (The stamps below are the real ones; note that the trailer's stamp
    is later while its MTIME is earlier — which is why ranking is on the stamp.)"""
    build = tmp_path / "net-firewall:iptables-1.8.13:20260725-211746.log"
    build.write_text("\n".join([
        _elog("Package:    net-firewall/iptables-1.8.13:0"),
        _elog("USE:        abi_x86_64 amd64 conntrack ipv6 nftables"),
    ]) + "\n", encoding="utf-8")
    trailer = tmp_path / "net-firewall:iptables-1.8.13:20260725-211759.log"
    trailer.write_text(_elog("Unsetting ebtables symlinks before removal") + "\n",
                       encoding="utf-8")
    p = ep.EmergePackageParser(log_root=str(tmp_path))
    p.feed(">>> Emerging (1 of 1) net-firewall/iptables-1.8.13::gentoo")
    pkg = p.feed(">>> Unpacking source...")
    assert pkg.log_path == str(build), "must not point the operator at the stub"
    assert "nftables" in pkg.use_flags
    # the pinned find_package_log() contract is unchanged — it still means NEWEST
    assert ep.find_package_log(str(tmp_path), "net-firewall/iptables-1.8.13") == str(trailer)


def test_log_path_falls_back_to_newest_when_no_candidate_has_a_header(tmp_path):
    only = tmp_path / "net-firewall:iptables-1.8.13:20260725-211759.log"
    only.write_text(_elog("Unsetting ebtables symlinks before removal") + "\n",
                    encoding="utf-8")
    p = ep.EmergePackageParser(log_root=str(tmp_path))
    p.feed(">>> Emerging (1 of 1) net-firewall/iptables-1.8.13::gentoo")
    pkg = p.feed(">>> Unpacking source...")
    assert pkg.log_path == str(only) and pkg.use_flags == ()


def test_the_log_portage_named_itself_wins_over_the_glob(tmp_path):
    """On the failure path portage prints the exact file; a newer sibling must not
    displace it, because that file is the evidence of THIS failure."""
    named = tmp_path / "app-office:libreoffice-25.2.7.2-r1:20260726-024143.log"
    named.write_text(_elog("USE:        abi_x86_64 amd64 gtk") + "\n", encoding="utf-8")
    (tmp_path / "app-office:libreoffice-25.2.7.2-r1:20260726-999999.log").write_text(
        _elog("USE:        a_much_later_unrelated_run") + "\n", encoding="utf-8")
    p = ep.EmergePackageParser(log_root=str(tmp_path))
    p.feed(">>> Emerging (561 of 805) app-office/libreoffice-25.2.7.2-r1::gentoo")
    for ln in _LIBREOFFICE_FAILURE:
        p.feed(ln)
    pkg = p.packages()[0]
    assert pkg.log_path == str(named)
    assert pkg.use_flags == ("abi_x86_64", "amd64", "gtk")


def test_find_package_log_misses_are_empty_not_exceptions(tmp_path):
    assert ep.find_package_log(str(tmp_path), "sys-devel/gettext-0.22.5-r2") == ""
    assert ep.find_package_log("", "sys-devel/gettext-0.22.5-r2") == ""
    assert ep.find_package_log(str(tmp_path), "no-slash") == ""
    # a different version of the same package must NOT be offered as this one's log
    (tmp_path / "sys-devel:gettext-0.23:20260725-210758.log").write_text("x")
    assert ep.find_package_log(str(tmp_path), "sys-devel/gettext-0.22.5-r2") == ""


def test_parser_resolves_log_and_use_flags_when_log_root_is_given(tmp_path):
    (tmp_path / "media-libs:freetype-2.14.3:20260725-211000.log").write_text(
        _FREETYPE_LOG, encoding="utf-8")
    p = ep.EmergePackageParser(log_root=str(tmp_path))
    p.feed(_banner("Emerge group: image"))
    p.feed(">>> Emerging (7 of 258) media-libs/freetype-2.14.3::gentoo")
    pkg = p.feed(">>> Compiling source in /var/tmp/portage/media-libs/freetype-2.14.3/work")
    assert os.path.basename(pkg.log_path) == "media-libs:freetype-2.14.3:20260725-211000.log"
    assert "cleartype-hinting" in pkg.use_flags


def test_parser_with_no_log_root_touches_no_filesystem():
    p = ep.EmergePackageParser()
    p.feed(">>> Emerging (1 of 1) media-libs/freetype-2.14.3::gentoo")
    pkg = p.packages()[0]
    assert pkg.log_path == "" and pkg.use_flags == ()


def test_log_appearing_late_is_still_picked_up(tmp_path):
    """Portage creates the log when the ebuild starts, which can be after the Emerging
    line we first saw the package on — resolution must keep retrying, not settle on ""."""
    p = ep.EmergePackageParser(log_root=str(tmp_path))
    p.feed(">>> Emerging (1 of 1) media-libs/freetype-2.14.3::gentoo")
    assert p.packages()[0].use_flags == ()
    (tmp_path / "media-libs:freetype-2.14.3:20260725-211000.log").write_text(
        _FREETYPE_LOG, encoding="utf-8")
    p.feed(">>> Unpacking source...")
    assert "harfbuzz" in p.packages()[0].use_flags


# ── (N of M) totals across portage's counter restarts ────────────────────────────────
def test_totals_counts_only_done_and_projects_the_rest():
    p = ep.EmergePackageParser()
    p.feed(_banner("Emerge group: image"))
    assert p.totals() == (0, 0)
    p.feed(">>> Emerging (1 of 258) dev-lang/duktape-2.7.0-r3::gentoo")
    assert p.totals() == (0, 258)
    p.feed(">>> Completed (1 of 258) dev-lang/duktape-2.7.0-r3::gentoo")
    assert p.totals() == (1, 258)
    p.feed(">>> Emerging (2 of 258) acct-group/polkitd-0-r3::gentoo")
    assert p.totals() == (1, 258)


def test_totals_reconstructs_the_original_size_across_a_keep_going_resume():
    """Line 2794913 is ``*** Resuming merge...``; line 2794952 restarts the counter at
    ``(1 of 245)`` after 560 packages had already merged. A naive read of (N of M) would
    report a group of 245 and make 560 finished packages vanish."""
    p = ep.EmergePackageParser()
    p.feed(_banner("Emerge group: image"))
    for i in range(1, 561):
        p.feed(f">>> Emerging ({i} of 805) dev-libs/pkg{i}-1.0::gentoo")
        p.feed(f">>> Completed ({i} of 805) dev-libs/pkg{i}-1.0::gentoo")
    assert p.totals() == (560, 805)
    p.feed(">>> Emerging (561 of 805) app-office/libreoffice-25.2.7.2-r1::gentoo")
    for ln in _LIBREOFFICE_FAILURE:
        p.feed(ln)
    assert p.totals()[0] == 560, "a failed package is never counted as progress"
    p.feed("*** Resuming merge...")
    p.feed(">>> Emerging (1 of 245) sys-apps/smartmontools-7.5-r1::gentoo")
    assert p.totals() == (560, 805)      # 560 done + 1 in flight + 244 still queued


def test_totals_never_shrinks_when_a_group_runs_several_emerge_invocations():
    """The x86 builder runs baselayout and the gettext downgrade as two separate emerges
    inside the same group (build-x86-host-stage4.sh:4413 and :4420), each restarting the
    counter at ``(1 of 1)``."""
    p = ep.EmergePackageParser()
    p.feed(_banner("Emerge group: system"))
    p.feed(">>> Emerging (1 of 1) sys-apps/baselayout-2.17::gentoo")
    p.feed(">>> Completed (1 of 1) sys-apps/baselayout-2.17::gentoo")
    assert p.totals() == (1, 1)
    p.feed(">>> Emerging (1 of 1) sys-devel/gettext-0.22.5-r2::gentoo")
    assert p.totals() == (1, 2)
    p.feed(">>> Completed (1 of 1) sys-devel/gettext-0.22.5-r2::gentoo")
    assert p.totals() == (2, 2)


def test_totals_are_per_group():
    p = ep.EmergePackageParser()
    p.feed(_banner("Emerge group: tools"))
    p.feed(">>> Emerging (1 of 1) app-eselect/eselect-repository-11::gentoo")
    p.feed(">>> Completed (1 of 1) app-eselect/eselect-repository-11::gentoo")
    assert p.totals() == (1, 1)
    p.feed(_banner("Emerge group: world"))
    assert p.totals() == (0, 0)               # a fresh group starts empty, not inherited
    p.feed(">>> Emerging (1 of 40) sys-apps/portage-3.0.81.2::gentoo")
    assert p.totals() == (0, 40)
    p.feed(_banner("Emerge group: tools"))
    assert p.totals() == (1, 1)               # and switching back restores the tools view


# ── build-tool telemetry (tool_info) ─────────────────────────────────────────────────
def _one_in_flight():
    """One package emerging and inside its compile step — the state every tool line in
    the real transcript actually arrives in."""
    p = ep.EmergePackageParser()
    pkg = p.feed(">>> Emerging (1 of 5) app-crypt/p11-kit-0.26.2::gentoo")
    p.feed(">>> Compiling source in /var/tmp/portage/app-crypt/p11-kit-0.26.2/work ...")
    return p, pkg


def test_ninja_counter_sets_tool_info_and_refines_compile_percent():
    """"[1/197] /usr/bin/cp ..." is line 60467 of the real transcript (p11-kit, 74,998
    ``^[N/M]`` lines in the whole build) — ninja's N/M is the one tool counter honest
    enough to move a percent, interpolated across the compile band only."""
    p, pkg = _one_in_flight()
    floor = pkg.percent
    line = ("[1/197] /usr/bin/cp /var/tmp/portage/app-crypt/p11-kit-0.26.2/work"
            "/p11-kit-0.26.2/subprojects/pkcs11-json/generated/pkcs11.json "
            "p11-kit/virtual-ffi-generated.h.p/pkcs11.json")
    assert p.feed(line) is pkg
    assert pkg.tool_info == line
    assert pkg.percent == floor                    # 1/197 rounds to the compile floor
    p.feed("[100/197] cc mid.o")
    mid = pkg.percent
    assert floor < mid < ep.STEP_PERCENT["test"]
    p.feed("[197/197] Linking target p11-kit/p11-kit")
    assert mid < pkg.percent < ep.STEP_PERCENT["test"], (
        "[M/M] is not '>>> Source compiled.' — it must stop short of the test floor")


def test_ninja_restart_cannot_regress_percent():
    """Multibuild ebuilds re-run ninja from [1/...] per ABI (gettext builds the whole
    tree once per ABI, module docstring) — a later run's low counter must not claw the
    bar back, though it IS the latest telemetry."""
    p, pkg = _one_in_flight()
    p.feed("[900/1000] cc big.o")
    high = pkg.percent
    p.feed("[1/1000] cc first-of-second-abi.o")
    assert pkg.percent == high
    assert pkg.tool_info == "[1/1000] cc first-of-second-abi.o"


def test_ninja_outside_compile_updates_tool_info_only():
    """After ">>> Source compiled." a ninja counter (the install phase re-invokes it) is
    no longer a compile fraction — it must not move the bar."""
    p, pkg = _one_in_flight()
    p.feed(">>> Source compiled.")
    p.feed(">>> Test phase [not enabled]: app-crypt/p11-kit-0.26.2")
    at_test = pkg.percent
    p.feed("[1/1] Install the project...")
    assert pkg.percent == at_test
    assert pkg.tool_info == "[1/1] Install the project..."


@pytest.mark.parametrize("line,expect", [
    # every literal below npm is a real transcript line, cited by line number
    ("make -j4 ", "make -j4"),                                              # L2783
    ("make[1]: Entering directory '/var/tmp/portage/sys-devel/gettext-0.22.5-r2/work"
     "/gettext-0.22.5-abi_x86_64.amd64'", None),                            # L2785
    ("-- Configuring done (1.6s)", None),                                   # L69747
    ("-- Generating done (0.0s)", None),                                    # L69748
    ("-- Build files have been written to: /var/tmp/portage/dev-cpp/eigen-3.4.0-r3"
     "/work/eigen-3.4.0_build", None),                                      # L69749
    ("   Compiling proc-macro2 v1.0.106", "Compiling proc-macro2 v1.0.106"),  # L170469
    # npm alone has ZERO occurrences in this transcript (no node package in this
    # image) — these two shapes are from the operator's list, not an in-repo proof
    ("npm install", None),
    ("added 1300 packages in 25s", None),
])
def test_tool_lines_set_tool_info_verbatim(line, expect):
    p, pkg = _one_in_flight()
    assert p.feed(line) is pkg
    assert pkg.tool_info == (line if expect is None else expect)


def test_configure_lines_are_collapsed_with_the_tool_prefix():
    """Bare "checking for a race-free mkdir -p... /usr/bin/mkdir -p" (L391) reads like
    OUR status text in a GUI cell — the configure: prefix says which tool is talking."""
    p, pkg = _one_in_flight()
    p.feed("checking for a race-free mkdir -p... /usr/bin/mkdir -p")
    assert pkg.tool_info == "configure: checking for a race-free mkdir -p... /usr/bin/mkdir -p"


def test_tool_output_never_invents_percent():
    """Only ninja's N/M may move a bar; make/cmake/configure/npm/cargo are text-only —
    none of them carries a completed/total fact to interpolate from."""
    p, pkg = _one_in_flight()
    at = pkg.percent
    for ln in ("make -j4 ", "-- Configuring done (1.6s)",
               "checking whether build environment is sane... yes",
               "   Compiling quote v1.0.45", "added 12 packages in 3s"):
        assert p.feed(ln) is pkg
        assert pkg.percent == at, f"{ln!r} invented a percent"


def test_unknown_tool_output_leaves_tool_info_unchanged():
    p, pkg = _one_in_flight()
    p.feed("[1/2] cc known.o")
    for noise in ("x86_64-pc-linux-gnu-gcc -O2 -pipe -c foo.c",
                  "Compiling locale data",       # cargo-shaped words, no vN.N version
                  "made: not a make marker",
                  "-- Up-to-date: /usr/share/eigen3",
                  "[WARNING] _do_sendfile failed unexpectedly"):  # groff log line 7 —
        assert p.feed(noise) is None              # bracketed, but not an N/M counter
    assert pkg.tool_info == "[1/2] cc known.o"


def test_tool_lines_are_dropped_when_attribution_is_ambiguous():
    """Real case: lines 43-44 of the transcript are "[1/2] Compiling locale: C.UTF-8"
    from the stage3 seed's locale generation, BEFORE any package is emerging. And under
    the ARM builders' parallel emerge two builds' ninja counters interleave — the same
    honesty rule as the anonymous ladder lines: no single candidate, no credit."""
    p = ep.EmergePackageParser()
    assert p.feed("[1/2] Compiling locale: C.UTF-8") is None    # nothing in flight
    a = p.feed(">>> Emerging (1 of 20) dev-libs/libfoo-1.0::gentoo")
    b = p.feed(">>> Emerging (2 of 20) dev-libs/libbar-2.0::gentoo")
    assert p.feed("[5/10] cc ambiguous.o") is None              # two in flight
    assert a.tool_info == "" and b.tool_info == ""
    assert a.percent == 0 and b.percent == 0


def test_ansi_wrapped_tool_line_still_matches():
    p, pkg = _one_in_flight()
    p.feed(f"{_BOLD}[42/197]{_RST} cc colored.o")
    assert pkg.tool_info == "[42/197] cc colored.o"


def test_package_progress_carries_the_pinned_contract_fields():
    """The GUI lane builds against exactly this field list (the pinned cross-lane API);
    a rename or reorder here must fail loudly, not surface as an AttributeError there."""
    assert [f.name for f in dataclasses.fields(ep.PackageProgress)] == [
        "atom", "category", "name", "version", "group", "index", "total", "step",
        "percent", "use_flags", "log_path", "failed", "header", "tool_info"]


# ── the full realistic transcript ────────────────────────────────────────────────────
def _pkg_block(n, total, atom, *, binary=False, ladder=True, fail=False, tools=()):
    """One package's worth of stream, in portage's real emission order; ``tools`` lines
    are spliced where they really occur — inside the compile step."""
    verb = "Emerging binary" if binary else "Emerging"
    out = [f">>> {verb} ({n} of {total}) {atom}::gentoo"]
    if ladder and not binary:
        work = f"/var/tmp/portage/{atom}/work"
        img = f"/var/tmp/portage/{atom}/image"
        out += [">>> Unpacking source...",
                f">>> Source unpacked in {work}",
                f">>> Preparing source in {work} ...",
                ">>> Source prepared.",
                f">>> Configuring source in {work} ...",
                ">>> Source configured.",
                f">>> Compiling source in {work} ...",
                *tools,
                ">>> Source compiled.",
                f">>> Test phase [not enabled]: {atom}"]
        if fail:
            return out + [f">>> Failed to emerge {atom}, Log file:", "",
                          f">>>  '/var/log/portage/build/{atom.replace('/', ':')}"
                          f":20260726-024143.log'"]
        out += [f">>> Install {atom} into {img}",
                f">>> Completed installing {atom} into {img}"]
    elif binary:
        out += [">>> Extracting info", f">>> Extracting {atom}"]
    out += [f">>> Installing ({n} of {total}) {atom}::gentoo",
            f">>> Completed ({n} of {total}) {atom}::gentoo"]
    return out


_TRANSCRIPT = (
    [_banner("Native emerge inside chroot"),                 # a progress_parse banner
     _banner("Emerge group: tools")]
    + _pkg_block(1, 1, "app-eselect/eselect-repository-11")
    + [_banner("Emerge group: system")]
    + _pkg_block(1, 1, "sys-apps/baselayout-2.17")
    + _pkg_block(1, 1, "sys-devel/gettext-0.22.5-r2")
    + [_banner("Emerge group: world")]
    + _pkg_block(1, 2, "sys-apps/portage-3.0.81.2", binary=True)
    + _pkg_block(2, 2, "dev-lang/python-3.12.13_p1")
    + [_banner("Emerge group: dependencies")]
    + _pkg_block(1, 2, "acct-group/polkitd-0-r3")
    + _pkg_block(2, 2, "media-libs/freetype-2.14.3", binary=True)
    + [_banner("Emerge group: image")]
    + _pkg_block(1, 3, "xfce-base/xfwm4-4.20.0", tools=(
        "[1/24] cc xfwm4.o", "[24/24] Linking target xfwm4"))
    + _pkg_block(2, 3, "app-office/libreoffice-25.2.7.2-r1", fail=True)
    + ["*** Resuming merge..."]
    + _pkg_block(1, 1, "sys-apps/smartmontools-7.5-r1")
)

_EXPECTED = [
    # (atom, group, step, percent)
    ("app-eselect/eselect-repository-11", "tools", "done", 100),
    ("sys-apps/baselayout-2.17", "system", "done", 100),
    ("sys-devel/gettext-0.22.5-r2", "system", "done", 100),
    ("sys-apps/portage-3.0.81.2", "world", "done", 100),
    ("dev-lang/python-3.12.13_p1", "world", "done", 100),
    ("acct-group/polkitd-0-r3", "dependencies", "done", 100),
    ("media-libs/freetype-2.14.3", "dependencies", "done", 100),
    ("xfce-base/xfwm4-4.20.0", "image", "done", 100),
    ("app-office/libreoffice-25.2.7.2-r1", "image", "failed", ep.STEP_PERCENT["test"]),
    ("sys-apps/smartmontools-7.5-r1", "image", "done", 100),
]


def test_realistic_multi_group_transcript():
    p = ep.EmergePackageParser()
    # every package's percent must be monotonic across the WHOLE stream, not just its own
    high = {}
    for ln in _TRANSCRIPT:
        pkg = p.feed(ln)
        if pkg is not None:
            assert pkg.percent >= high.get(pkg.atom, 0), f"{pkg.atom} regressed on {ln!r}"
            assert pkg.percent < 100 or pkg.step == "done", (
                f"{pkg.atom} hit 100 at step {pkg.step}")
            high[pkg.atom] = pkg.percent
    assert [(x.atom, x.group, x.step, x.percent) for x in p.packages()] == _EXPECTED
    assert p.group() == "image"
    assert p.current() is None                      # the stream ended cleanly
    # image ran (1..3 of 3), libreoffice died at 2, and the keep-going resume merged the
    # last one as its own "(1 of 1)" — so the group is 3 packages of which 2 are done and
    # the third is red, NOT the 1-of-1 the last counter line says on its own.
    assert p.totals() == (2, 3)
    # the failed row is red, has its log, and is NOT counted as done anywhere
    bad = [x for x in p.packages() if x.failed]
    assert [x.atom for x in bad] == ["app-office/libreoffice-25.2.7.2-r1"]
    assert bad[0].log_path.endswith(
        "app-office:libreoffice-25.2.7.2-r1:20260726-024143.log")
    assert not any(x.step == "done" and x.failed for x in p.packages())
    # tool telemetry landed on the one package whose compile emitted it — and ONLY there
    xfwm4 = next(x for x in p.packages() if x.name == "xfwm4")
    assert xfwm4.tool_info == "[24/24] Linking target xfwm4"
    assert all(x.tool_info == "" for x in p.packages() if x is not xfwm4)


def test_realistic_transcript_group_membership_covers_every_group():
    p = ep.EmergePackageParser()
    for ln in _TRANSCRIPT:
        p.feed(ln)
    by_group = {}
    for x in p.packages():
        by_group.setdefault(x.group, []).append(x.atom)
    assert set(by_group) == set(ep.EMERGE_GROUPS), "every emerge group must be represented"
    assert ep.GROUP_UNKNOWN not in by_group, "no package fell outside a group banner here"


def test_module_is_qt_free():
    """Same discipline as progress_parse/stage_tracker: importable by the headless CLI and
    portable to the admin-bff pod-log follower (design 2.9), so no Qt binding may appear
    in it — directly or by importing a module that pulls one in."""
    with open(ep.__file__, encoding="utf-8") as fh:
        src = fh.read()
    assert "PySide6" not in src and "PyQt6" not in src
    r = subprocess.run(
        [sys.executable, "-c",
         "import sys; from hugmesh_studio.core import emerge_packages; "
         "print(sorted(m for m in sys.modules if m.split('.')[0] in ('PySide6','PyQt6')))"],
        capture_output=True, text=True, timeout=60,
        env=dict(os.environ, PYTHONPATH=_STUDIO_ROOT))
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "[]", r.stdout


# ── the cross-lane PLAN-preview contract (scripts/_emerge-plan-lib.sh) ───────────────
_REPO_ROOT = os.path.dirname(_STUDIO_ROOT)
_PLAN_LIB = os.path.join(_REPO_ROOT, "scripts", "_emerge-plan-lib.sh")


def _plan_lib_src() -> str:
    with open(_PLAN_LIB, encoding="utf-8") as fh:
        return fh.read()


def test_plan_prefix_is_pinned_and_matches_the_builder_lib():
    """Both-sides pin, same discipline as GROUP_BANNER_PREFIX: the builder-side variable
    in scripts/_emerge-plan-lib.sh and this parser constant must be byte-identical, so a
    reword on either side fails HERE (and in check.sh's EPL bucket) instead of silently
    starving the GUI of every plan."""
    assert ep.PLAN_BANNER_PREFIX == "==> Emerge plan: "
    import re as _re
    m = _re.search(r'^EMERGE_PLAN_PREFIX="(.*)"$', _plan_lib_src(), _re.M)
    assert m, "EMERGE_PLAN_PREFIX= pin not found in scripts/_emerge-plan-lib.sh"
    assert m.group(1) == ep.PLAN_BANNER_PREFIX


def test_plan_unavailable_reasons_match_the_builder_lib():
    """Every reason= slug the lib can emit must be declared here (the GUI keys honest
    fallback copy off them), and vice versa — no undeclared slug on either side."""
    import re as _re
    emitted = set(_re.findall(r"reason=([a-z-]+)", _plan_lib_src()))
    assert emitted == set(ep.PLAN_UNAVAILABLE_REASONS), (
        f"lib emits {sorted(emitted)}, parser declares {sorted(ep.PLAN_UNAVAILABLE_REASONS)}")


def test_parse_plan_line_all_four_shapes():
    hdr = ep.parse_plan_line("==> Emerge plan: image total=149")
    assert hdr == ep.PlanLine(kind="total", group="image", total=149)
    pkg = ep.parse_plan_line(
        '==> Emerge plan: image 3/149 dev-libs/xxhash-0.8.3-r2 USE="-static-libs test%"')
    assert pkg.kind == "pkg" and pkg.group == "image"
    assert (pkg.index, pkg.total) == (3, 149)
    assert pkg.atom == "dev-libs/xxhash-0.8.3-r2"
    assert pkg.use == "-static-libs test%"
    bare = ep.parse_plan_line("==> Emerge plan: system 1/2 sys-apps/baselayout-2.17")
    assert bare.kind == "pkg" and bare.use is None, "no USE clause must parse as None, not ''"
    empty = ep.parse_plan_line('==> Emerge plan: system 2/2 sys-apps/gawk-5.3.1 USE=""')
    assert empty.use == "", "an explicitly empty USE=\"\" is distinct from an absent one"
    unav = ep.parse_plan_line("==> Emerge plan: world unavailable reason=opt-out")
    assert unav == ep.PlanLine(kind="unavailable", group="world", reason="opt-out")


def test_parse_plan_line_rejects_everything_else():
    for line in (
        _banner("Emerge group: world"),                       # group banner, not a plan
        ">>> Emerging (1 of 149) dev-libs/xxhash-0.8.3-r2::gentoo",
        "==> Emerge plan: ",                                  # prefix alone
        "==> Emerge packages",                                # phase banner
        "[ebuild  N     ] dev-libs/xxhash-0.8.3-r2  USE=\"-static-libs\"",  # raw pretend row
        "",
    ):
        assert ep.parse_plan_line(line) is None, f"must not parse: {line!r}"


def test_plan_lines_parse_through_ansi():
    """The builders pass --color=n, but the parser side stays ANSI-tolerant like every
    other regex in this module (applied after strip_ansi per the module contract)."""
    got = ep.parse_plan_line(f"{_CYAN}{_BOLD}==> Emerge plan: image total=7{_RST}")
    assert got == ep.PlanLine(kind="total", group="image", total=7)


def test_plan_lines_move_no_package_and_no_group():
    """Feeding the raw stream (which now carries plan lines) into the existing parser
    must be a no-op: no row invented, no group switched, scheduler untouched — the plan
    tree is the GUI lane's separate consumer via parse_plan_line()."""
    p = ep.EmergePackageParser()
    p.feed(_banner("Emerge group: system"))
    for line in (
        "==> Emerge plan: image total=2",
        '==> Emerge plan: image 1/2 dev-libs/xxhash-0.8.3-r2 USE="-static-libs"',
        "==> Emerge plan: image 2/2 sys-apps/gawk-5.3.1",
        "==> Emerge plan: image unavailable reason=pretend-timeout",
    ):
        assert p.feed(line) is None
    assert p.group() == "system", "a plan line must never switch the live group"
    assert p.packages() == []


def test_plan_lines_do_not_advance_the_phase_ladder():
    """Plan lines start with '==> ' and thus reach ProgressParser._match_phase; none may
    be a substring-match for any platform's phase patterns, on any platform, or the bar
    would jump on a preview. (Same stranded-ladder class test_progress_uniformity pins
    for banners.)"""
    from hugmesh_studio.core.progress_parse import ProgressParser, platforms
    lines = (
        "==> Emerge plan: world total=258",
        '==> Emerge plan: world 1/258 sys-apps/portage-3.0.81.2 USE="-build"',
        "==> Emerge plan: image unavailable reason=opt-out",
    )
    for platform in platforms():
        p = ProgressParser(platform)
        for line in lines:
            p.feed(line)
        assert p.phase_index == -1, f"{platform}: a plan line advanced the phase ladder"
