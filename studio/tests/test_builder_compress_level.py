"""--compress-level drift guards (issue #233's one unchecked box).

Studio's whole compress-level contract rests on facts that live in TEN shell scripts,
none of which any Python test could see before this file:

  * every builder must PARSE ``--compress-level`` — Studio emits it on all ten
    (PLATFORM_FIELD_SUPPORT["compress_level"] is _ALL_PLATFORMS, pinned to emission by
    test_cli_args.py::test_platform_field_support_matches_emission). A builder that
    does not parse it dies on "Unknown option" the moment an operator moves the knob;
  * every builder's own default must be COMPRESS_LEVEL_DEFAULT. Studio emits NOTHING at
    that value, deliberately, so that an untouched config's argv is byte-identical to
    what it was before the flag existed. If a builder's default drifted off 9, "emit
    nothing" would silently start meaning a different compression level;
  * no ``xz -T0 -9`` literal may survive on the --compress path. One left behind is a
    knob that moves and changes nothing — the worst failure mode a setting can have,
    because it looks like it worked;
  * the ALWAYS-ON ``xz -T0 -6`` sites (the stage4 archive and fs.tar.xz) must stay at 6.
    That was a deliberate scope decision, not an oversight: those run with or without
    --compress, so re-pointing them at COMPRESS_LEVEL would change what a build with no
    compression flags at all emits. The count is pinned so the decision cannot be
    quietly reversed in either direction.

Pure-core (no Qt), read-only (no builder is executed) — runs in the headless suite.
"""
from __future__ import annotations

import os
import re

from hugmesh_studio.core.config import (BUILDER_SCRIPTS, COMPRESS_LEVEL_DEFAULT,
                                        ImageConfig)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

_TEXT = {}
for _p, _f in BUILDER_SCRIPTS.items():
    with open(os.path.join(GENERATOR_DIR, _f), encoding="utf-8") as _fh:
        _TEXT[_p] = _fh.read()

# The always-on archive compressions, which --compress-level deliberately does NOT own.
# x86: stage4 + fs.tar, one each since their silent no-xattr tar fallbacks went (#503).
_ALWAYS_ON_XZ6 = {"x86": 2, "rpi5": 2}          # stage4 + fs.tar / fs.tar x2


def test_every_builder_parses_compress_level():
    for platform, text in _TEXT.items():
        assert re.search(r"^\s*--compress-level\)", text, re.M), \
            f"{BUILDER_SCRIPTS[platform]} does not parse --compress-level, but Studio " \
            f"emits it for this platform"


def test_every_builder_defaults_to_studios_default_level():
    """The half that matters of "emit nothing at the default"."""
    for platform, text in _TEXT.items():
        m = re.search(r"^COMPRESS_LEVEL=(\d)\b", text, re.M)
        assert m, f"{BUILDER_SCRIPTS[platform]} declares no COMPRESS_LEVEL default"
        assert int(m.group(1)) == COMPRESS_LEVEL_DEFAULT, (
            f"{BUILDER_SCRIPTS[platform]} defaults to {m.group(1)} but Studio emits "
            f"nothing at {COMPRESS_LEVEL_DEFAULT} — an untouched config would silently "
            f"change compression level")


def test_every_builder_validates_the_level_it_accepts():
    """0-9 is xz's range and the GUI's range; a builder that took anything would hand
    xz a flag it rejects halfway through a multi-hour build."""
    for platform, text in _TEXT.items():
        arm = re.search(r"^\s*--compress-level\)\n(?:.*\n){0,3}?.*COMPRESS_LEVEL=",
                        text, re.M)
        assert arm, BUILDER_SCRIPTS[platform]
        assert "[0-9]" in arm.group(0), \
            f"{BUILDER_SCRIPTS[platform]} accepts --compress-level without validating 0-9"


def test_no_hardcoded_xz_9_survives_on_the_compress_path():
    """A single leftover literal makes the knob ineffective on that artifact."""
    for platform, text in _TEXT.items():
        assert "xz -T0 -9" not in text, (
            f"{BUILDER_SCRIPTS[platform]} still hardcodes `xz -T0 -9` — the "
            f"--compress-level knob would move and change nothing there")


def test_every_compress_path_xz_call_uses_the_level():
    """Counted, not merely absent: x86/rpi5/jetson compress the .img (one site each),
    the seven flavor builders compress the live + installer ISOs (two sites each)."""
    expected = {"x86": 1, "rpi5": 1, "jetson": 1}
    for platform in _TEXT:
        want = expected.get(platform, 2)
        got = len(re.findall(r'xz -T0 "-\$\{COMPRESS_LEVEL\}"', _TEXT[platform]))
        assert got == want, f"{BUILDER_SCRIPTS[platform]}: {got} level-aware xz calls, " \
                            f"expected {want}"


def test_the_always_on_archive_compressions_are_left_alone():
    """The deliberate scope line: --compress-level owns the --compress path only."""
    for platform, text in _TEXT.items():
        got = text.count("xz -T0 -6")
        assert got == _ALWAYS_ON_XZ6.get(platform, 0), (
            f"{BUILDER_SCRIPTS[platform]}: {got} always-on `xz -T0 -6` sites, expected "
            f"{_ALWAYS_ON_XZ6.get(platform, 0)} — --compress-level scope changed")


def test_the_level_is_only_read_inside_the_compress_gate():
    """Why Studio never emits --compress-level without --compress: the builders read
    COMPRESS_LEVEL nowhere else. Checked structurally — every USE (as opposed to the
    default and the parse arm) sits on a line that also names the xz call the
    ``if ${COMPRESS_IMG}`` gate guards."""
    for platform, text in _TEXT.items():
        uses = [ln for ln in text.splitlines()
                if "${COMPRESS_LEVEL}" in ln and "COMPRESS_LEVEL=" not in ln]
        assert uses, BUILDER_SCRIPTS[platform]
        for ln in uses:
            assert ("xz -T0" in ln or "info " in ln or "_plan " in ln), \
                f"{BUILDER_SCRIPTS[platform]}: COMPRESS_LEVEL read outside the " \
                f"--compress path: {ln.strip()!r}"


def test_studio_emits_a_flag_spelled_exactly_as_the_builders_parse_it():
    """The two ends, joined: the literal Studio puts on the command line is the literal
    every builder's case arm matches. A typo on either side is a runtime-only failure."""
    args = ImageConfig(mode="cloud", role="desktop", platform="x86",
                       compress=True, compress_level=1).to_cli_args()
    assert "--compress-level" in args
    for platform, text in _TEXT.items():
        assert "--compress-level)" in text, BUILDER_SCRIPTS[platform]
