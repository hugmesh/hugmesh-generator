"""Honest builder-progress parsing (design 2.9) — banner phase tables, ANSI stripping,
emerge sub-fractions, failure markers, indeterminate fallback, and the banner-count DRIFT
probe that fails when a builder's banners change without a table update."""
import os
import re

import pytest

from snapdragon_studio.core import progress_parse as pp
from snapdragon_studio.core.config import BUILDER_SCRIPTS

_GEN = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# CYAN/BOLD SGR wrappers exactly as the builders' banner() emits them.
_CYAN, _BOLD, _RST = "\x1b[36m", "\x1b[1m", "\x1b[0m"


def _banner(text: str) -> str:
    return f"{_CYAN}{_BOLD}==> {text}{_RST}"


# ── drift probe ──────────────────────────────────────────────────────────────────────
_BANNER_CALLSITE = re.compile(r'^\s*banner\s+"')


def _count_banner_callsites(script_path: str) -> int:
    with open(script_path, encoding="utf-8") as fh:
        return sum(1 for ln in fh if _BANNER_CALLSITE.match(ln))


@pytest.mark.parametrize("platform,script", sorted(BUILDER_SCRIPTS.items()))
def test_banner_drift_probe(platform, script):
    """The number of ``banner "..."`` call sites in each builder MUST equal the number of
    match patterns in its progress table — so a banner add/remove/rename fails CI until the
    table is updated (the whole point of a data-driven, honest progress model)."""
    n = _count_banner_callsites(os.path.join(_GEN, script))
    assert n == pp.pattern_count(platform), (
        f"{script}: {n} banner call sites vs {pp.pattern_count(platform)} table patterns "
        f"for {platform} — regenerate/update progress-tables.json")
    assert n == pp.declared_callsites(platform), (
        f"{script}: banner_callsites annotation ({pp.declared_callsites(platform)}) is stale")


def test_every_platform_has_a_table():
    assert set(pp.platforms()) == set(BUILDER_SCRIPTS)
    for p in BUILDER_SCRIPTS:
        assert pp.platform_phases(p), f"{p} has no phases"


# ── ANSI stripping (mandatory first) ─────────────────────────────────────────────────
def test_strip_ansi_removes_sgr():
    assert pp.strip_ansi(_banner("Verifying prerequisites")) == "==> Verifying prerequisites"
    assert pp.strip_ansi("plain line") == "plain line"


def test_banner_matched_through_ansi():
    p = pp.ProgressParser("x86")
    st = p.feed(_banner("Verifying prerequisites"))
    assert st.phase_index == 1  # "Rebranding baked config" (idx 0) is conditional/skipped
    assert "Verify prerequisites" in st.phase_label


# ── indeterminate before any phase ───────────────────────────────────────────────────
def test_indeterminate_before_first_banner():
    p = pp.ProgressParser("x86")
    st = p.feed("some preamble noise")
    assert st.percent is None and st.phase_index == -1
    # an emerge counter with no phase yet is still honestly indeterminate
    st = p.feed(">>> Emerging (3 of 10) sys-apps/foo")
    assert st.percent is None


# ── determinate step-K-of-M + monotonicity ───────────────────────────────────────────
_X86_HAPPY = [
    "Verifying prerequisites", "Preparing build directories",
    "Fetching amd64 hardened stage3 seed", "Verifying stage3 seed signature + checksum",
    "Extracting stage3", "Installing spec files", "Native emerge inside chroot",
    "Installing mesh VPN (headscale + tailscale, amd64)",
    "Building Gentoo hardened kernel (gentoo-sources + KSPP/SELinux + k8s fragment)",
    "Cleaning sysroot", "Packaging stage4 tarball",
    "Building raw .img (UEFI GPT: ESP + ext4 root, GRUB-EFI --removable)",
    "Building bootable LIVE ISO (grub-mkrescue + squashfs)",
]


def test_monotonic_determinate_progress():
    p = pp.ProgressParser("x86")
    last = -1
    for text in _X86_HAPPY:
        st = p.feed(_banner(text))
        assert st.percent is not None
        assert st.percent >= last, f"regressed at {text!r}: {st.percent} < {last}"
        assert st.percent < 100, "must never claim 100 before finalize()"
        last = st.percent
    # exit 0 settles to 100 and done
    st = p.finalize(0)
    assert st.percent == 100 and st.done and not st.failed


def test_skipped_banner_advances_same_phase():
    """A SKIPPED alternate reaches the SAME phase as its active twin (grouped patterns)."""
    a = pp.ProgressParser("x86")
    b = pp.ProgressParser("x86")
    a.feed(_banner("Native emerge inside chroot"))
    b.feed(_banner("Native emerge inside chroot"))
    ia = a.feed(_banner("Installing mesh VPN (headscale + tailscale, amd64)")).phase_index
    ib = b.feed(_banner("Mesh VPN SKIPPED")).phase_index
    assert ia == ib


def test_forward_only_ignores_out_of_order_and_unknown():
    p = pp.ProgressParser("x86")
    p.feed(_banner("Packaging stage4 tarball"))
    idx = p.phase_index
    # an earlier banner must NOT drag the bar backwards
    st = p.feed(_banner("Verifying prerequisites"))
    assert st.phase_index == idx
    # an unknown banner is ignored
    st = p.feed(_banner("Frobnicating the widget"))
    assert st.phase_index == idx


# ── intra-phase emerge fraction ──────────────────────────────────────────────────────
def test_emerge_fraction_refines_within_phase():
    p = pp.ProgressParser("x86")
    p.feed(_banner("Native emerge inside chroot"))
    base = p.state().percent
    st = p.feed(">>> Emerging (10 of 20) dev-lang/python")
    assert st.fraction == pytest.approx(0.5)
    assert st.percent >= base
    # a fresh phase banner resets the intra-phase fraction
    st = p.feed(_banner("Cleaning sysroot"))
    assert st.fraction is None


def test_installing_counter_also_parses():
    p = pp.ProgressParser("rpi5")
    p.feed(_banner("Phase 2: Cross-building stage4 packages"))
    st = p.feed(">>> Installing (4 of 8) sys-apps/bar")
    assert st.fraction == pytest.approx(0.5)


# ── failure markers ──────────────────────────────────────────────────────────────────
def test_failure_marker_sets_failed():
    p = pp.ProgressParser("x86")
    p.feed(_banner("Native emerge inside chroot"))
    st = p.feed("!! emerge failed for dev-lang/python")
    assert st.failed


def test_finalize_nonzero_is_failed_not_done():
    p = pp.ProgressParser("x86")
    p.feed(_banner("Packaging stage4 tarball"))
    st = p.finalize(1)
    assert st.failed and not st.done and st.percent != 100


# ── convenience whole-stream parse ───────────────────────────────────────────────────
def test_parse_lines_end_to_end():
    lines = [_banner(t) for t in _X86_HAPPY]
    st = pp.parse_lines("x86", lines, exit_code=0)
    assert st.percent == 100 and st.done


def test_unknown_platform_falls_back_to_x86():
    # never crash on an unrecognised builder — coarse x86 phases instead
    st = pp.parse_lines("no-such-platform", [_banner("Verifying prerequisites")])
    assert st.phase_index >= 0
