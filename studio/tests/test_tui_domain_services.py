"""tui — the per-domain Services step (#495's TUI surface).

Headless and Qt-free. The catalogue, the ordering rule and the gate itself live in
``core/domain_services.py`` and are pinned by tests/test_domain_services_page.py; HERE
the pins are that the TUI step is a REAL surface rather than an honest stub, and that
it records through the SAME function the GUI page calls — so a config walked in the TUI
and one walked in the GUI gate identically.

Why that matters enough to test: a ``PendingStep`` ("configure this in the GUI") would
leave every domain unconfigured, and the build/mesh-start gate refuses on exactly that.
The TUI would have had a step it could walk but never satisfy.
"""
import pytest

from hugmesh_studio.core import domain_services as ds
from hugmesh_studio.core.config import (
    INFRA_SERVICES_CHOICES, OPTIONAL_SERVICES_CHOICES, Domain)
from hugmesh_studio.tui import domain_services_step, journey


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _at_mesh_domains() -> journey.Journey:
    j = journey.Journey(".")
    for line in ("", "3", "", "1", "", "", "", ""):
        # welcome, mesh, idp, worklist row, collect, branding, network, keyzip
        j.feed(line)
    assert j.slug == "domains_choice"
    j.feed("y")
    assert j.slug == "domains"
    return j


def _at_services(*names) -> journey.Journey:
    j = _at_mesh_domains()
    for n in names:
        j.feed(f"a {n}")
    j.feed("")
    assert j.slug == "domain_services"
    return j


# ── the step exists and is walked ───────────────────────────────────────────────
def test_the_step_is_registered_for_its_slug():
    j = journey.Journey(".")
    screen = j._screens["domain_services"]
    assert isinstance(screen, domain_services_step.DomainServicesScreen)


def test_a_step_with_no_domains_is_skipped_by_the_walk():
    """Nothing to ask, and nothing for the gate to refuse either — the GUI page's
    applies_to says the same thing."""
    j = _at_mesh_domains()
    j.feed("")                               # Enter with an empty table
    assert j.slug == "users_choice"


def test_walking_the_only_domain_clears_the_gate():
    j = _at_services("chat.example.org")
    assert ds.gate_reason(j.cfg) == ""
    j.feed("")
    assert j.slug == "users_choice"


def test_a_domain_never_stepped_onto_is_still_refused():
    """THE GATE'S REASON TO EXIST, on the TUI side: being on a domain's screen is what
    records it, so a second domain nobody stepped to is named downstream."""
    j = _at_services("a.example.org", "b.example.org")
    assert ds.unconfigured_domains(j.cfg) == ["b.example.org"]
    assert "b.example.org" in ds.gate_reason(j.cfg)
    j.feed("n")
    assert ds.gate_reason(j.cfg) == ""


# ── what it offers ──────────────────────────────────────────────────────────────
def test_it_offers_the_domain_catalogue_and_not_the_infra_slugs():
    j = _at_services("chat.example.org")
    headers, rows = domain_services_step.service_table(j.cfg.domains[0])
    slugs = [r[headers.index("service")] for r in rows]
    assert slugs == list(OPTIONAL_SERVICES_CHOICES)
    for infra in INFRA_SERVICES_CHOICES:
        assert infra not in slugs


def test_it_says_where_the_infra_slugs_live_instead_of_dropping_them_silently():
    """#497: reachable from the same flow AND visibly not domain-scoped. Each infra
    slug is printed with the scope it really has and where it IS set."""
    j = _at_services("chat.example.org")
    text = "\n".join(j.lines())
    for infra in INFRA_SERVICES_CHOICES:
        assert infra in text
    assert "NOT domain-scoped" in text
    assert ds.SCOPE_LABELS[ds.SCOPE_NODE] in text
    for slug, where in ds.INFRA_WHERE.items():
        assert where in text, slug


def test_it_prints_the_not_yet_enforced_note():
    """The same words the GUI page shows — a required step that implies the mesh will
    run only what was chosen is worse than the menu it replaced."""
    j = _at_services("chat.example.org")
    assert ds.ENFORCEMENT_NOTE in "\n".join(j.lines())


# ── toggling ────────────────────────────────────────────────────────────────────
def test_a_number_toggles_that_service_on_the_current_domain():
    j = _at_services("chat.example.org")
    idx = list(OPTIONAL_SERVICES_CHOICES).index("phpbb") + 1
    j.feed(str(idx))
    assert j.cfg.domains[0].optional_services == ["phpbb"]
    j.feed(str(idx))
    assert j.cfg.domains[0].optional_services == []


def test_toggling_records_in_catalogue_order_not_click_order():
    """DISCRIMINATING PAIR: games/owncast is where catalogue order and the presentation
    grouping disagree, so this can tell the two apart. optional_services must be
    byte-stable across a load/save round trip."""
    j = _at_services("chat.example.org")
    cat = list(OPTIONAL_SERVICES_CHOICES)
    j.feed(str(cat.index("owncast") + 1))
    j.feed(str(cat.index("games") + 1))
    assert j.cfg.domains[0].optional_services == ["games", "owncast"]


def test_each_domain_keeps_its_own_selection():
    j = _at_services("a.example.org", "b.example.org")
    cat = list(OPTIONAL_SERVICES_CHOICES)
    j.feed(str(cat.index("akkoma") + 1))
    j.feed("n")
    j.feed(str(cat.index("phpbb") + 1))
    assert [d.optional_services for d in j.cfg.domains] == [["akkoma"], ["phpbb"]]


def test_a_carried_over_slug_is_listed_and_kept():
    """An older worklist can carry a slug this build's catalogue does not offer;
    dropping it would silently rewrite the operator's manifest."""
    j = _at_mesh_domains()
    j.cfg.domains = [Domain(name="chat.example.org",
                            optional_services=["akkoma", "tor"])]
    j.feed("")
    headers, rows = domain_services_step.service_table(j.cfg.domains[0])
    slugs = [r[headers.index("service")] for r in rows]
    assert slugs[-1] == "tor"
    assert rows[-1][headers.index("on")] == "on"
    note = rows[-1][headers.index("what it does for this domain")]
    assert ds.CARRIED_OVER_NOTE in note
    # ...and the slug's OWN description survives beside it. Every infra slug HAS a
    # SERVICE_DESCRIPTIONS entry, and an infra slug typed into the pre-#227 freeform
    # cell is the commonest way one reaches a domain row — replacing that line with
    # "kept from your config" would throw away the only text saying what it is.
    assert ds.describe("tor") in note


def test_junk_input_is_refused_inline_and_changes_nothing():
    j = _at_services("chat.example.org")
    j.feed("definitely-not-a-service")
    assert "unrecognised command" in j.status
    j.feed("99")
    assert "no such service row" in j.status
    assert j.cfg.domains[0].optional_services == []
