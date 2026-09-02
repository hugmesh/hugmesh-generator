"""The installer-UI note is advice about a configuration — say it once, not per refresh.

The incident (2026-08-05): the Studio is a long-lived process that re-materializes its
worklist on every preview refresh, and `_materialize_one` printed the resolver's note
with a bare `print(..., file=sys.stderr)` each time. One operator session accumulated
**76 copies** of the same four lines in the X session log. A one-shot CLI never sees it
(it prints once and exits), which is why no test caught it.
"""
import io

import pytest

from hugmesh_studio.core.config import (
    ImageConfig,
    emit_note_once,
    reset_emitted_notes,
    resolve_installer_ui_default,
)


@pytest.fixture(autouse=True)
def _clean_notes():
    """Never inherit a sibling test's suppression, and never leak ours."""
    reset_emitted_notes()
    yield
    reset_emitted_notes()


def _cap():
    return io.StringIO()


def test_first_emission_prints():
    out = _cap()
    assert emit_note_once("something happened", stream=out) is True
    assert "warning: something happened" in out.getvalue()


def test_identical_note_is_suppressed_after_the_first():
    out = _cap()
    for _ in range(50):
        emit_note_once("something happened", stream=out)
    assert out.getvalue().count("something happened") == 1


def test_a_genuinely_different_note_still_reports():
    out = _cap()
    emit_note_once("note about role 'pki'", stream=out)
    emit_note_once("note about role 'backend'", stream=out)
    body = out.getvalue()
    assert "role 'pki'" in body and "role 'backend'" in body


def test_empty_or_none_is_a_noop():
    out = _cap()
    assert emit_note_once(None, stream=out) is False
    assert emit_note_once("", stream=out) is False
    assert out.getvalue() == ""


def test_the_real_resolver_note_repeats_only_once_across_many_materializations():
    """The actual regression: same cfg shape, many refreshes, one line of output."""
    out = _cap()
    printed = 0
    for _ in range(20):
        cfg = ImageConfig(mode="mesh", role="pki", platform="x86", installer_ui="all")
        if emit_note_once(resolve_installer_ui_default(cfg), stream=out):
            printed += 1
    assert printed == 1, f"note printed {printed} times across 20 materializations"
    assert out.getvalue().count("installer_ui") == 1


def test_the_note_still_fires_once_per_distinct_role():
    """Suppression must not hide a DIFFERENT rewrite — the note text carries the role."""
    out = _cap()
    for role in ("pki", "backend", "frontend", "omnibus"):
        cfg = ImageConfig(mode="mesh", role=role, platform="x86", installer_ui="all")
        emit_note_once(resolve_installer_ui_default(cfg), stream=out)
    body = out.getvalue()
    for role in ("pki", "backend", "frontend", "omnibus"):
        assert f"{role!r}" in body, f"the {role} rewrite was swallowed"
    assert body.count("installer_ui") == 4


def test_resolver_still_rewrites_even_when_the_note_is_suppressed():
    """Suppressing the MESSAGE must never suppress the FIX it describes."""
    out = _cap()
    first = ImageConfig(mode="mesh", role="pki", platform="x86", installer_ui="all")
    emit_note_once(resolve_installer_ui_default(first), stream=out)
    second = ImageConfig(mode="mesh", role="pki", platform="x86", installer_ui="all")
    emit_note_once(resolve_installer_ui_default(second), stream=out)
    # the second one printed nothing, but was still rewritten
    assert second.installer_ui == "cli"
    assert out.getvalue().count("installer_ui") == 1
