"""The TUI Go-Live route's two prompts (GUI-28 / B-10): ``tui --go-live`` -> provider
-> domain -> plan, driven through the journey exactly as the plain face feeds it.

* an EMPTY Enter on the provider step is a usage line, never "no such provider: ''";
* a plan with NO domain names THIS face's remedy (``b``, then ``t NAME`` on the domain
  step). It used to print the GUI's "type one on the Inputs step" — a step the TUI does
  not have. The GUI's sentence is unchanged (the default of ``exposure_lines``).

Headless and Qt-free; the host's /etc/hugmesh files are replaced by the driver's own
env seams pointing at nothing, so no domain is known.
"""
import io
import os

import pytest

from hugmesh_studio.core.golive_domains import (NO_DOMAIN_HINT_GUI, NO_DOMAIN_HINT_TUI,
                                                exposure_lines)
from hugmesh_studio.tui import app as tui_app
from hugmesh_studio.tui import journey
from hugmesh_studio.tui.golive import GoLiveScreen

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

GUI_EMPTY = "(no domain known yet — type one on the Inputs step)"


@pytest.fixture(autouse=True)
def _no_domain_on_this_host(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(tmp_path / "no-cluster-domain"))
    monkeypatch.setenv("GOLIVE_DOMAINS_FILE", str(tmp_path / "no-domains"))
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(tmp_path / "no-tor"))


def _go_live() -> tuple[journey.Journey, GoLiveScreen]:
    j = journey.Journey(GENERATOR_DIR)
    j.goto("golive")
    gl = j.screen()
    assert isinstance(gl, GoLiveScreen)
    return j, gl


# ── the empty plan's hint, per face ────────────────────────────────────────────────
def test_the_gui_keeps_its_inputs_step_sentence():
    assert exposure_lines([]) == [GUI_EMPTY]
    assert exposure_lines([], NO_DOMAIN_HINT_GUI) == [GUI_EMPTY]


def test_the_tui_hint_names_a_command_the_tui_has():
    (line,) = exposure_lines([], NO_DOMAIN_HINT_TUI)
    assert "Inputs step" not in line
    assert "t NAME" in line and "b " in line


def test_rows_render_the_same_whatever_the_hint():
    rows = [("mesh.example (cluster domain)", "x via y — THIS run")]
    assert exposure_lines(rows) == exposure_lines(rows, NO_DOMAIN_HINT_TUI)


def test_the_tui_plan_without_a_domain_says_b_then_t_name():
    j, gl = _go_live()
    j.feed("1")                                    # a provider
    assert gl.stage == "domain"
    j.feed("")                                     # Enter: no domain baked, none typed
    assert gl.stage == "plan"
    shown = "\n".join(j.lines())
    assert ("(no domain known yet — b goes back to the domain step, where t NAME "
            "types one)") in shown
    assert "Inputs step" not in shown
    # and the remedy it names works: b, then t NAME, and the plan has the domain
    j.feed("b")
    assert gl.stage == "domain"
    j.feed("t shop.example")
    j.feed("")
    assert gl.stage == "plan"
    assert "shop.example" in "\n".join(gl.plan_lines(j))
    assert "no domain known yet" not in "\n".join(j.lines())


# ── an empty Enter on the provider step ────────────────────────────────────────────
def test_an_empty_enter_on_the_provider_step_is_a_usage_line():
    j, gl = _go_live()
    count = len(gl._driver(j).providers())
    assert count > 1
    j.feed("")
    assert gl.stage == "provider"
    assert "no such provider" not in j.status
    assert j.status == (f"pick a provider: type its NUMBER (1-{count}) and Enter · "
                        "t=pick the target · q=quit")
    assert not j.done


def test_a_wrong_number_still_says_no_such_provider():
    j, gl = _go_live()
    j.feed("99")
    assert j.status == "no such provider: '99'"


def test_the_plain_face_route_end_to_end():
    out = io.StringIO()
    rc = tui_app.main(["--go-live", "--generator-dir", GENERATOR_DIR],
                      inp=io.StringIO("\n1\n\nq\n"), out=out)
    text = out.getvalue()
    assert rc == 0
    assert "no such provider: ''" not in text
    assert "pick a provider: type its NUMBER" in text
    assert "where t NAME types one" in text
    assert "Inputs step" not in text
