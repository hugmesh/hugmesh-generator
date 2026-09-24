"""The e2e catalogue's per-lane door rows (hugmesh-generator#577, decision 67 = B).

`tor` has no compose-lane SPEC, so service_coverage() rightly reports it uncovered.
Its kind-lane door (`make kind-tor`) is driven by a Gherkin feature instead, and the
catalogue says so next to the row — but only while that feature really exists and
still carries the tags `make kind-e2e-tor` selects on. These tests pin both halves.
"""
import os
import re

import pytest

from hugmesh_studio.core import e2e_catalogue as ec

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _tor_kind_door() -> ec.LaneDoor:
    doors = [d for d in ec.LANE_DOORS if d.slug == "tor" and d.lane == "kind"]
    assert len(doors) == 1, ec.LANE_DOORS
    return doors[0]


def test_the_real_checkout_reports_the_kind_onion_door_as_driven():
    lines = ec.lane_door_lines(GENERATOR_DIR, "tor")
    assert len(lines) == 1, lines
    assert lines[0].startswith("kind: tor-onion-kind.feature drives this service")
    assert "make kind-tor" in lines[0] and "make kind-e2e-tor" in lines[0]


def test_the_door_does_not_flip_the_compose_coverage_verdict():
    # A .feature is not a compose spec; tor's service_coverage verdict belongs to the
    # compose lane and must not be changed by the kind door existing.
    cov = {c.slug: c for c in ec.service_coverage(GENERATOR_DIR)}
    assert all("tor-onion-kind" not in f for f in cov["tor"].spec_files)


def test_a_missing_feature_is_named_not_vouched_for(tmp_path):
    lines = ec.lane_door_lines(str(tmp_path), "tor")
    assert len(lines) == 1
    assert "MISSING" in lines[0] and "nothing drives it" in lines[0]


def test_a_feature_that_lost_its_selector_tag_is_named(tmp_path):
    door = _tor_kind_door()
    path = tmp_path / door.feature
    path.parent.mkdir(parents=True)
    # @via:onion only in a COMMENT and in step text: neither is a tag.
    path.write_text("# @via:onion is how this used to be selected\n"
                    "@env:kind\nFeature: x\n  Scenario: y\n"
                    "    Given the tag @via:onion appears in a step\n",
                    encoding="utf-8")
    lines = ec.lane_door_lines(str(tmp_path), "tor")
    assert len(lines) == 1
    assert "lost its @via:onion tag(s)" in lines[0], lines


def test_a_service_with_no_door_gets_no_line():
    assert ec.lane_door_lines(GENERATOR_DIR, "wiki") == ()


def test_every_make_target_a_door_names_exists():
    with open(os.path.join(GENERATOR_DIR, "Makefile"), encoding="utf-8") as fh:
        targets = set(re.findall(r"^([A-Za-z0-9_.-]+):", fh.read(), re.MULTILINE))
    for door in ec.LANE_DOORS:
        named = re.findall(r"make ([A-Za-z0-9_.-]+)", door.bring_up + " " + door.run)
        assert named, door
        for t in named:
            assert t in targets, f"{door.slug}/{door.lane} names `make {t}`, which the Makefile does not define"


def test_the_door_tags_are_what_the_make_target_selects_on():
    door = _tor_kind_door()
    with open(os.path.join(GENERATOR_DIR, "Makefile"), encoding="utf-8") as fh:
        mk = fh.read()
    m = re.search(r"^kind-e2e-tor:.*?(?=^\S)", mk, re.MULTILINE | re.DOTALL)
    assert m, "no kind-e2e-tor recipe"
    expr = " and ".join(door.tags)
    assert f"--tags '{expr}'" in m.group(0), m.group(0)


# ── both faces tell the kind plan the same thing (decision 71: TUI parity) ────────
def test_the_tui_kind_plan_names_the_onion_door_and_the_others_do_not():
    from hugmesh_studio.tui import e2e as tui_e2e
    kind = "\n".join(tui_e2e.plan_lines("kind"))
    want = ec.lane_door_lines_for_lane(GENERATOR_DIR, "kind")
    assert want and all(w in kind for w in want), kind
    assert "make kind-tor" in kind and "tor-onion-kind.feature" in kind
    for other in ("docker", "qemu"):
        assert "make kind-tor" not in "\n".join(tui_e2e.plan_lines(other))


def test_the_gui_e2e_page_says_the_same_as_the_tui(monkeypatch):
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")
    import html
    from hugmesh_studio.core.platform_info import HostInfo
    from hugmesh_studio.gui import wizard as wizard_mod
    from hugmesh_studio.gui.qt import QtWidgets
    host = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": host)
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["lane-doors"])  # noqa: F841 — must outlive the wizard
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    try:
        page = wiz.page(wiz._page_ids["e2e"])
        page.env_combo.setCurrentIndex(page.env_combo.findData("kind"))
        text = page.env_note.text()
        for line in ec.lane_door_lines_for_lane(GENERATOR_DIR, "kind"):
            assert html.escape(line) in text, text
        page.env_combo.setCurrentIndex(page.env_combo.findData("docker"))
        assert "make kind-tor" not in page.env_note.text()
    finally:
        wiz.deleteLater()
