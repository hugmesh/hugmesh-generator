"""tui — the Local Docker mesh side-flow's DOMAINS and DOMAIN SERVICES steps (#494).

Operator decision 71 (= A, recorded on #347): TUI parity is in scope in the same PR as
the GUI steps. Headless and Qt-free; the GUI twin is tests/test_localmesh_domains_steps.py
and tests/test_tui_gui_parity.py pins the shared wording/ids against the live pages.

Pinned here, driving the journey through the route:

* the Local Docker mesh card is a HOSTED screen now, not an honest stub, and its
  choice screen defaults to ``join`` by id as the GUI page does;
* ``generate`` walks Domains -> Domain services -> review;
* row 1 is the mesh's own domain — the brand-default apex on a test mesh, typed with
  ``p NAME`` on a prod one — and can never be removed or re-signed;
* the services step walks EVERY domain, the own one first, with the lane sentence;
* the SAME gate (``gate_reason`` / ACTION_MESH_START / LOCAL_MESH_REMEDY) refuses an
  un-walked domain, names it and the steps, and clears once it is walked — and the
  bootstrap command is only printed once it is clear;
* Own rows reach ``--own-casdoor-domain`` / ``own_idp_names``; the recorded rows are
  ``bootstrap_domain_records`` (the GUI's own function); ``j.cfg`` is never touched.
"""
import copy

import pytest

from hugmesh_studio.core import domain_services as ds
from hugmesh_studio.core.config import DOMAIN_IDP_OWN, OPTIONAL_SERVICES_CHOICES
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
from hugmesh_studio.core.local_mesh_domains import LOCAL_MESH_REMEDY
from hugmesh_studio.tui import journey, localmesh


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


APEX = LocalMeshBootstrapConfig().resolved_domain()
CAT = list(OPTIONAL_SERVICES_CHOICES)


def _at_choice() -> journey.Journey:
    j = journey.Journey(".")
    j.feed("")                     # welcome -> mode
    j.feed("1")                    # Local Docker mesh
    assert j.slug == "localmesh"
    return j


def _at_domains(*added) -> journey.Journey:
    j = _at_choice()
    j.feed("2")                    # Generate a new mesh
    assert j.screen().stage == "domains"
    for name in added:
        j.feed(f"a {name}")
    return j


def _screen(j) -> localmesh.LocalMeshScreen:
    return j.screen_for("localmesh")


# ── 1. the card is hosted, the choice mirrors the GUI ────────────────────────────
def test_the_local_docker_mesh_card_is_hosted_not_a_stub():
    j = _at_choice()
    assert isinstance(_screen(j), localmesh.LocalMeshScreen)
    assert not isinstance(_screen(j), journey.PendingSideFlow)
    text = "\n".join(j.lines())
    for _cid, title in localmesh.LOCALMESH_CHOICES:
        assert title in text


def test_the_default_choice_is_join_and_join_is_an_honest_stub():
    j = _at_choice()
    j.feed("")                     # the default
    assert _screen(j).stage == "join"
    assert "not yet ported to the TUI" in "\n".join(j.lines())
    j.feed("")
    assert j.slug == "mode"


def test_generate_walks_domains_then_services_then_review():
    j = _at_domains()
    j.feed("")
    assert _screen(j).stage == "services"
    j.feed("")
    assert _screen(j).stage == "review"


# ── 2. row 1 is the own domain ───────────────────────────────────────────────────
def test_row_1_is_the_brand_default_apex_on_a_test_mesh():
    j = _at_domains()
    md = j.localmesh_domains
    assert md.own_name == APEX
    assert [d.name for d in md.domains] == [APEX]
    headers, rows = _screen(j).table(j)
    assert rows[0][:2] == ["1 (own)", APEX]
    assert j.cfg.domains == [] and j.cfg.mode == "standalone"   # j.cfg untouched


def test_the_own_row_cannot_be_removed_or_re_signed():
    j = _at_domains("acme.example")
    j.feed("d 1")
    assert "own domain" in j.status
    j.feed("s 1")
    assert "own domain" in j.status
    assert [d.name for d in j.localmesh_domains.domains] == [APEX, "acme.example"]
    j.feed("d 2")
    assert [d.name for d in j.localmesh_domains.domains] == [APEX]


def test_prod_types_row_1_and_a_blank_prod_apex_cannot_continue():
    j = _at_domains("acme.example")
    j.feed("p example.com")
    md = j.localmesh_domains
    assert md.own_name == "example.com"
    assert [d.name for d in md.domains] == ["example.com", "acme.example"]
    j.feed("p -")
    assert md.own_name == APEX and md.domains[0].name == APEX
    # a prod mesh with no apex typed is an inline note, never an advance
    s = _screen(j)
    s.prod, md.own_name = True, ""
    s._seed(j)
    j.feed("")
    assert s.stage == "domains" and "public apex" in j.status


def test_junk_names_are_refused_inline():
    j = _at_domains()
    j.feed("a Not A Domain")
    assert "not a domain name" in j.status
    j.feed("a acme.example")
    j.feed("a acme.example")
    assert "already listed" in j.status


# ── 3. the services stepper walks every domain, own first ────────────────────────
def test_the_services_step_walks_every_domain_own_domain_first():
    j = _at_domains("acme.example", "team.example")
    j.feed("")
    text = "\n".join(j.lines())
    assert f"{APEX} (this mesh's own domain) — domain 1 of 3" in text
    assert localmesh.LANE_NOTE in text
    # the local Docker mesh runs what is ticked: the CLUSTER's "not yet enforced"
    # banner would contradict the lane note, so this route does not say it
    assert ds.ENFORCEMENT_NOTE not in text and ds.DOCKER_SERVICES_HELP in text
    assert "Mesh infrastructure" in text and "Network & services" not in text
    j.feed("n")
    assert "acme.example — domain 2 of 3" in "\n".join(j.lines())
    j.feed("n")
    assert "team.example — domain 3 of 3" in "\n".join(j.lines())
    assert "All 3 domains configured." in "\n".join(j.lines())


def test_a_tick_lands_on_that_domains_row():
    j = _at_domains("acme.example")
    j.feed("")
    j.feed("n")
    j.feed(str(CAT.index("games") + 1))
    md = j.localmesh_domains
    assert md.by_name("acme.example").optional_services == ["games"]
    assert md.by_name(APEX).optional_services == []


# ── 4. the gate ─────────────────────────────────────────────────────────────────
def test_the_review_refuses_an_unwalked_domain_and_names_the_steps():
    j = _at_domains("acme.example", "team.example")
    j.feed("")                     # services: only the own domain shown
    j.feed("")                     # -> review
    text = "\n".join(j.lines())
    assert "Cannot start this mesh" in text
    named = text.split(" — ", 1)[1].split(". ", 1)[0].split(", ")
    assert named == ["acme.example", "team.example"]
    assert LOCAL_MESH_REMEDY in text
    assert "local_mesh_bootstrap" not in text          # no command while refused
    assert _screen(j).refusal(j) == ds.gate_reason(
        j.localmesh_domains, ds.ACTION_MESH_START, remedy=LOCAL_MESH_REMEDY)


def test_walking_the_domains_clears_the_gate_and_prints_the_command():
    j = _at_domains("acme.example", "team.example")
    j.feed("s 3")                  # team.example: Own Casdoor
    j.feed("")
    j.feed("")                     # review: refused
    j.feed("b")                    # back to services
    assert _screen(j).stage == "services"
    j.feed("n")
    j.feed("n")
    j.feed("")
    text = "\n".join(j.lines())
    assert "Cannot start" not in text
    assert ("python3 -m hugmesh_studio.core.local_mesh_bootstrap plan --env test "
            "--own-casdoor-domain team.example") in text
    assert "#519" in text


def test_back_from_services_returns_to_the_domains_table():
    j = _at_domains()
    j.feed("")
    j.feed("b")
    assert _screen(j).stage == "domains"


# ── 5. what the rows turn into ─────────────────────────────────────────────────
def test_rows_are_recorded_with_the_guis_own_function():
    j = _at_domains("acme.example", "team.example")
    j.feed("s 3")
    j.feed("")
    j.feed("n")
    j.feed(str(CAT.index("games") + 1))
    j.feed("n")
    j.feed("")
    assert _screen(j).records(j) == (
        {"name": "acme.example", "title": "", "idp": "superdomain",
         "optional_services": ["games"]},
        {"name": "team.example", "title": "", "idp": DOMAIN_IDP_OWN,
         "optional_services": []},
    )


def test_an_untouched_walk_records_nothing_and_commands_the_bare_plan():
    """Emission neutrality on the TUI: Next, Next through both steps records no row
    (the own domain is default-shaped) and the command is the bare test plan."""
    j = _at_domains()
    cfg_before = copy.deepcopy(j.cfg)
    j.feed("")
    j.feed("")
    assert _screen(j).records(j) == ()
    assert localmesh.bootstrap_command(j.localmesh_domains, False) == [
        "python3", "-m", "hugmesh_studio.core.local_mesh_bootstrap", "plan",
        "--env", "test"]
    assert j.cfg == cfg_before


def test_prod_command_carries_the_apex():
    j = _at_domains()
    j.feed("p example.com")
    j.feed("")
    j.feed("")
    assert ("plan --env prod --cluster-domain example.com"
            in "\n".join(j.lines()))
