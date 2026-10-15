"""The Docker route's superbrand in the TEXT screens (hugmesh-generator#654, D8; operator
decision 71 = A: the window and the text screens offer the same controls).

The local-mesh text flow has no Environment step, so the window's drop-down and design are
one command on the Domains screen, ``superbrand``, over the same session class. What is
pinned here: the screen offers it, ‘Create a new superbrand’ is the first item and is
selected, an untouched flow is byte-identical to before (no ``--brand``, no ``--record``,
no file), a design writes the record and the printed command carries it, and the one box
this route does not edit (the public name) says where it is edited.
"""
import json
import os
import subprocess
import sys

import pytest

from hugmesh_studio.core import brand_model
from hugmesh_studio.tui import journey, localmesh

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _at_domains():
    j = journey.Journey(GENERATOR_DIR)
    j.feed("")                     # welcome -> mode
    j.feed("1")                    # Local Docker mesh
    j.feed("2")                    # Generate a new mesh
    assert j.screen().stage == "domains"
    return j


def _screen(j):
    return j.screen_for("localmesh")


def _text(j):
    return "\n".join(j.lines())


def _to_review(j):
    j.feed("")                     # domains -> services
    j.feed("")                     # services: only the own domain -> review
    assert _screen(j).stage == "review", _text(j)


def _command(j) -> list[str]:
    line = next(ln for ln in _text(j).splitlines()
                if ln.strip().startswith("python3 -m hugmesh_studio"))
    import shlex
    return shlex.split(line)


# ── the screen offers it ────────────────────────────────────────────────────────────
def test_the_domains_screen_names_the_superbrand_and_its_command():
    j = _at_domains()
    text = _text(j)
    assert "Superbrand: Create a new superbrand (default)" in text
    assert "superbrand=choose or design the superbrand" in text


def test_the_drop_down_lists_create_first_and_selected():
    j = _at_domains()
    j.feed("superbrand")
    lines = _text(j).splitlines()
    items = [ln for ln in lines if ln.strip().lstrip("*").strip()[:2] in
             tuple(f"{i}." for i in range(1, 10))]
    assert items[0].strip() == "*1. Create a new superbrand"
    assert any("example" in ln and "profile" in ln for ln in items[1:])
    assert "Design your superbrand" in _text(j)


def test_an_existing_profile_skips_the_design_and_offers_change_it():
    j = _at_domains()
    j.feed("superbrand")
    number = next(ln.strip().split(".")[0].lstrip("* ") for ln in _text(j).splitlines()
                  if "example (a brands/ profile)" in ln)
    j.feed(number)
    text = _text(j)
    assert "Design your superbrand" not in text
    assert "change       open the design to change it" in text
    j.feed("change")
    assert "Design your superbrand" in _text(j)


# ── an untouched flow changes nothing ───────────────────────────────────────────────
def test_an_untouched_flow_prints_the_command_it_always_printed():
    j = _at_domains()
    _to_review(j)
    md = _screen(j).state(j)
    assert _command(j) == localmesh.bootstrap_command(md, False)
    assert "--brand" not in _command(j) and "--record" not in _command(j)
    assert not os.path.exists(brand_model.record_path())


def test_looking_at_the_drop_down_and_leaving_it_changes_nothing():
    j = _at_domains()
    j.feed("superbrand")
    j.feed("")                     # Enter on an untouched design
    assert j.overlay is None
    _to_review(j)
    assert not os.path.exists(brand_model.record_path())


# ── a design writes the record and the command carries it ───────────────────────────
def _design(j, **fields):
    j.feed("superbrand")
    for cmd, value in fields.items():
        j.feed(f"{cmd} {value}")
    j.feed("")


def test_a_design_writes_the_record_and_the_command_carries_it():
    j = _at_domains()
    _design(j, id="acme", title="Acme Mesh", org="example")
    assert "‘Acme Mesh’" in _text(j)
    _to_review(j)
    argv = _command(j)
    assert argv[argv.index("--brand") + 1] == "acme"
    path = argv[argv.index("--record") + 1]
    assert path == brand_model.record_path() and os.path.isfile(path)
    rec = brand_model.load_record(path)
    assert (rec.superbrand.id, rec.superbrand.title, rec.superbrand.org) == (
        "acme", "Acme Mesh", "example")
    assert f"record saved: {path}" in _text(j)


def test_the_printed_command_runs_and_its_plan_carries_the_superbrand():
    j = _at_domains()
    _design(j, id="acme", title="Acme Mesh")
    _to_review(j)
    argv = _command(j)
    env = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    out = subprocess.run([sys.executable] + argv[1:], cwd=STUDIO_ROOT, env=env,
                         capture_output=True, text=True, timeout=120)
    assert out.returncode == 0, out.stderr
    assert "Brand:      acme  (Acme Mesh)" in out.stdout, out.stdout


def test_a_profile_pick_is_carried_the_same_way():
    j = _at_domains()
    j.feed("superbrand")
    number = next(ln.strip().split(".")[0].lstrip("* ") for ln in _text(j).splitlines()
                  if "example (a brands/ profile)" in ln)
    j.feed(number)
    j.feed("")
    _to_review(j)
    argv = _command(j)
    assert argv[argv.index("--brand") + 1] == "example"
    assert brand_model.load_record().superbrand.id == "example"


def test_a_refused_id_is_said_and_nothing_is_written():
    j = _at_domains()
    j.feed("superbrand")
    j.feed("id Not A Slug")
    assert "not a DNS label" in j.status
    assert "id      Superbrand id         (not set" in _text(j)    # the box kept its value
    j.feed("")
    _to_review(j)
    assert not os.path.exists(brand_model.record_path())


def test_closing_the_screen_with_q_keeps_what_was_typed_and_leaves_a_whole_record():
    """q only closes the screen (as in the window there is no discard): what was typed is
    still the session's and is carried at the review, in a record that is whole JSON."""
    j = _at_domains()
    j.feed("superbrand")
    j.feed("id acme")
    j.feed("q")
    assert j.overlay is None
    _to_review(j)
    rec = json.loads(open(brand_model.record_path(), encoding="utf-8").read())
    assert rec["superbrand"]["id"] == "acme"


# ── the one box this route does not edit ───────────────────────────────────────────
def test_the_public_name_is_not_typed_in_the_design_and_says_where_it_is():
    j = _at_domains()
    j.feed("superbrand")
    assert localmesh.PUBLIC_NAME_HOME in _text(j)
    assert "id|title|org|root VALUE" in _text(j)
    j.feed("public mesh.example")
    assert localmesh.PUBLIC_NAME_HOME in j.status


def test_the_record_says_the_public_name_the_domains_hold():
    j = _at_domains()
    j.feed("p mesh.example")       # prod mesh with this public apex
    _design(j, id="acme")
    _to_review(j)
    assert brand_model.load_record().superbrand.public_name == "mesh.example"


def test_the_records_sign_in_address_follows_a_switch_to_prod_after_the_design():
    j = _at_domains()
    _design(j, id="acme")              # committed on a test mesh
    j.feed("p mesh.example")           # then the person makes it a prod mesh
    _to_review(j)
    rec = brand_model.load_record()
    assert rec.superbrand.public_name == "mesh.example"
    assert rec.superbrand.central_signin == "https://id.mesh.example"
