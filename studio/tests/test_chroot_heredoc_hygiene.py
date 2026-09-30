"""Unquoted-heredoc hygiene in the builder scripts.

WHY THIS EXISTS
---------------
The builders drive their chroots through UNQUOTED heredocs:

    chroot "${SYSROOT}" /bin/bash -eo pipefail <<CHROOT
    ...
    CHROOT

An unquoted delimiter means the HOST shell expands the body before the guest ever
parses it — which is relied on (``${UKI_NAME}``/``${ROOT_LABEL}`` must expand
host-side) but also means a backtick is COMMAND SUBSTITUTION even inside what looks
like a comment. build-x86-host-stage4.sh says so in-line:

    # Bare echo, and no dollar/backtick/dollar-paren anywhere in these lines: this is
    # the UNQUOTED CHROOT heredoc, where the HOST shell expands comments too

That rule was documented but unenforced, and it got broken exactly as predicted: a
comment written as ``minted by `parted` inside build_img()`` ran `parted` at build
time, spliced its stdout ("Using /dev/sda") into the script, and the next line failed
with ``Using: command not found`` — an hour into an x86 build (2026-08-13).

So: inside an unquoted heredoc, an UNESCAPED backtick is always a bug. The one
legitimate backtick in that file is escaped (``\\`make olddefconfig\\```), which is the
pattern this test permits. Quoted heredocs (<<'EOF') are literal and exempt.

This is a pure text scan — no build, no chroot, no root.
"""
import os
import re

import pytest

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

#: Every builder that drives a chroot through a heredoc.
BUILDER_GLOBS = ("build-x86-host-stage4.sh", "build-rpi5-stage4.sh",
                 "build-frite-stage4.sh", "build-jetson-stage4.sh",
                 "build-orangepi5-stage4.sh", "build-orangepi-zero2-stage4.sh",
                 "build-orangepi-zero2w-stage4.sh", "build-orangepi-zero3-stage4.sh",
                 "build-orangepi3-lts-stage4.sh", "build-orangepi4-lts-stage4.sh")

# <<WORD / <<-WORD, capturing the delimiter and whether it was quoted. A quoted
# delimiter (<<'EOF' or <<"EOF") makes the body LITERAL — nothing expands, so those
# heredocs are exempt.
_HEREDOC_OPEN = re.compile(r"<<-?\s*(?P<q>['\"]?)(?P<word>[A-Za-z_][A-Za-z0-9_]*)(?P=q)")


def _unquoted_heredoc_spans(lines):
    """Yield (delimiter, start_idx, end_idx) for each UNQUOTED heredoc body.

    Indices are 0-based into ``lines``; the body is (start_idx, end_idx) exclusive of
    the opener line and of the terminator line.
    """
    spans = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        # A line may open a heredoc; ignore ones inside an obvious comment.
        stripped = line.lstrip()
        if not stripped.startswith("#"):
            m = _HEREDOC_OPEN.search(line)
            if m and not m.group("q"):
                word = m.group("word")
                # find the terminator
                j = i + 1
                while j < n and lines[j].strip() != word:
                    j += 1
                if j < n:
                    spans.append((word, i + 1, j))
                    i = j
        i += 1
    return spans


def _unescaped_backticks(text):
    """Column indices of backticks that are NOT backslash-escaped."""
    out = []
    for idx, ch in enumerate(text):
        if ch != "`":
            continue
        # count trailing backslashes before it
        b = idx - 1
        slashes = 0
        while b >= 0 and text[b] == "\\":
            slashes += 1
            b -= 1
        if slashes % 2 == 0:          # even => the backtick itself is not escaped
            out.append(idx)
    return out


def _builder_paths():
    found = []
    for name in BUILDER_GLOBS:
        p = os.path.join(GENERATOR_DIR, name)
        if os.path.isfile(p):
            found.append(p)
    return found


def test_at_least_one_builder_is_scanned():
    """Guard the guard: a rename must not silently turn this suite into a no-op."""
    assert _builder_paths(), f"no builder scripts found under {GENERATOR_DIR}"


@pytest.mark.parametrize("path", _builder_paths(), ids=os.path.basename)
def test_no_unescaped_backticks_inside_unquoted_heredocs(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()

    offenders = []
    for word, start, end in _unquoted_heredoc_spans(lines):
        for idx in range(start, end):
            line = lines[idx]
            if _unescaped_backticks(line):
                offenders.append(f"  {os.path.basename(path)}:{idx + 1} (in <<{word}): {line.strip()[:100]}")

    assert not offenders, (
        "Unescaped backtick inside an UNQUOTED heredoc — the HOST shell will run it as "
        "command substitution (comments included) and splice the output into the script:\n"
        + "\n".join(offenders)
        + "\n\nUse 'single quotes' in prose, or escape it as \\` if you really mean a backtick."
    )


# ── the detector itself must actually detect ────────────────────────────────────
# A lint that silently matches nothing is worse than no lint, so pin both directions
# against the REAL regression rather than trusting the scan above to be exercised.

def test_detector_flags_the_2026_08_13_regression(tmp_path):
    """The exact shape that broke the x86 build must be caught."""
    script = tmp_path / "b.sh"
    script.write_text(
        'chroot "${SYSROOT}" /bin/bash <<CHROOT\n'
        "# LABEL=, not PARTUUID=: the UUIDs are minted by `parted` inside build_img()\n"
        'CMDLINE="root=LABEL=X ro"\n'
        "CHROOT\n")
    lines = script.read_text().splitlines()
    spans = _unquoted_heredoc_spans(lines)
    assert spans, "opener not recognized"
    hits = [i for _w, s, e in spans for i in range(s, e) if _unescaped_backticks(lines[i])]
    assert hits, "the `parted` comment should have been flagged"


def test_detector_allows_escaped_backticks_and_quoted_heredocs(tmp_path):
    """Escaped backticks are the sanctioned form; quoted heredocs never expand."""
    script = tmp_path / "b.sh"
    script.write_text(
        'chroot x /bin/bash <<CHROOT\n'
        "# fixed, \\`make olddefconfig\\` (above) will SILENTLY DROP any symbol\n"
        "CHROOT\n"
        "cat <<'LITERAL'\n"
        "this `is` fine because the delimiter is quoted\n"
        "LITERAL\n")
    lines = script.read_text().splitlines()
    offenders = [i for _w, s, e in _unquoted_heredoc_spans(lines)
                 for i in range(s, e) if _unescaped_backticks(lines[i])]
    assert not offenders, f"false positive at lines {[i + 1 for i in offenders]}"
