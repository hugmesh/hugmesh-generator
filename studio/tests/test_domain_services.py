"""The per-domain service model and the build/mesh-start gate — Qt-free (#494/#495).

    "make sure that the service configuration is integrated into the domain setup
     instead of its own separate thing. make sure that for each domain, the service
     page needs to be config, so there's basically a service page per domain you make
     you have to go through before building or starting a mesh in docker or nodes"
                                                        — the operator, 2026-09-17

THIS FILE HAS NO QT IMPORT, and that is the point rather than a convenience. The
pre-merge CI job (`.github/workflows/studio-tests.yml`) installs **no Qt binding** on
purpose, and a `pytest.importorskip("hugmesh_studio.gui.qt")` anywhere in a module
skips the WHOLE module — so a gate tested only inside a GUI file is a gate the
pre-merge job never runs. `core/domain_services.py` exists as a Qt-free seam precisely
so the refusal can be driven with a bare `ImageConfig`; these tests are what cash that
in. The GUI surfaces live in tests/test_domain_services_page.py (the step) and
tests/test_domain_services_scope.py (the scope column), both of which DO skip without
a binding.

What is pinned here: the gate itself, the remedy each call site shows, the marker's
fail-closed loading and its absence from both manifests, the domain catalogue and its
scopes, and the catalogue-order normalisation that keeps the manifest byte-stable.
"""
import os

import pytest

from hugmesh_studio.core import domain_services as ds
from hugmesh_studio.core.config import (
    INFRA_SERVICES_CHOICES, OPTIONAL_SERVICES_CHOICES, SERVICE_GROUPS, Domain,
    ImageConfig)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


# ── the seam ──────────────────────────────────────────────
def test_gate_passes_when_there_are_no_domains():
    assert ds.gate_reason(ImageConfig()) == ""


def test_gate_names_every_unconfigured_domain():
    cfg = ImageConfig(domains=[Domain(name="a.example"), Domain(name="b.example")])
    msg = ds.gate_reason(cfg)
    assert "a.example" in msg and "b.example" in msg
    assert "2 domains" in msg


def test_gate_names_the_action_it_refused():
    cfg = ImageConfig(domains=[Domain(name="a.example")])
    assert "build these images" in ds.gate_reason(cfg, ds.ACTION_IMAGE_BUILD)
    assert "start this mesh" in ds.gate_reason(cfg, ds.ACTION_MESH_START)


def test_each_refusal_names_a_route_that_exists_from_where_it_is_shown():
    """A remedy that does not work is a dead end with extra words, and ONE shared
    sentence would be wrong at BOTH call sites in different ways:

    * the build screen has Qt's Back DISABLED — the review screen before it is a
      commit page (``pages/build.py`` setCommitPage(True)), which is why that screen
      has a "back to the main menu" card at all — so "go back a step" is false there;
    * the local-mesh branch is TERMINAL and hosts no Domains table; its domains come
      from the configuration the session is carrying, so "go back a step" names a
      step that is not in that flow.
    """
    cfg = ImageConfig(domains=[Domain(name="a.example")])
    build = ds.gate_reason(cfg, ds.ACTION_IMAGE_BUILD)
    mesh = ds.gate_reason(cfg, ds.ACTION_MESH_START)
    assert ds.ACTION_REMEDY[ds.ACTION_IMAGE_BUILD] in build
    assert ds.ACTION_REMEDY[ds.ACTION_MESH_START] in mesh
    assert build != mesh
    # the build remedy names the card that IS reachable, and says why Back is not
    assert "Back to the main menu" in build
    assert "Back button is disabled" in build
    # ...and the mesh remedy does not send anyone to a Back that leads elsewhere
    assert "Back to the main menu" not in mesh
    assert "the configuration this session is carrying" in mesh


def test_an_unknown_action_still_gets_a_usable_sentence():
    """gate_reason must not fall off a dict lookup into a bare domain list if a third
    call site ever passes its own action string."""
    cfg = ImageConfig(domains=[Domain(name="a.example")])
    msg = ds.gate_reason(cfg, "do the thing")
    assert "Cannot do the thing" in msg
    assert "Domain services" in msg


def test_an_empty_selection_is_a_real_answer_once_the_domain_is_configured():
    """``optional_services == []`` means "the cluster-wide set applies" — a real
    answer, and the reason emptiness could not double as "never configured"."""
    cfg = ImageConfig(domains=[Domain(name="a.example", optional_services=[])])
    assert ds.gate_reason(cfg) != ""
    ds.record_reviewed(cfg, ["a.example"])
    assert ds.gate_reason(cfg) == ""
    assert cfg.domains[0].optional_services == []


def test_a_marker_for_a_domain_that_no_longer_exists_is_dropped():
    """REBUILT, never merged: a renamed or deleted domain must not leave a marker that
    would let the gate pass for a domain nobody configured."""
    cfg = ImageConfig(domains=[Domain(name="a.example")])
    ds.record_reviewed(cfg, ["a.example", "ghost.example"])
    assert cfg.domain_services_reviewed == ["a.example"]
    cfg.domains = [Domain(name="renamed.example")]
    ds.record_reviewed(cfg, cfg.domain_services_reviewed)
    assert cfg.domain_services_reviewed == []
    assert "renamed.example" in ds.gate_reason(cfg)


def test_the_marker_never_reaches_either_mesh_manifest():
    """It is the GATE's bookkeeping, not provisioning data — a manifest must be
    byte-identical whether or not the page was walked."""
    cfg = ImageConfig(domains=[Domain(name="a.example")])
    before = cfg.mesh_manifest()
    ds.record_reviewed(cfg, ["a.example"])
    assert cfg.mesh_manifest() == before
    assert "domain_services_reviewed" not in cfg.mesh_manifest()
    assert all("domain_services_reviewed" not in d
               for d in cfg.mesh_manifest()["domains"])


def test_the_marker_round_trips_through_a_saved_config():
    cfg = ImageConfig(domains=[Domain(name="a.example")])
    ds.record_reviewed(cfg, ["a.example"])
    again = ImageConfig.from_dict(cfg.to_dict())
    assert again.domain_services_reviewed == ["a.example"]
    assert ds.gate_reason(again) == ""


def test_a_junk_marker_fails_closed_not_open():
    """A hand-edited config whose marker is not a list must NOT stand in for "all
    reviewed" — absent is the fail-closed reading and the gate then says so."""
    cfg = ImageConfig.from_dict({"domains": [{"name": "a.example"}],
                                 "domain_services_reviewed": "everything"})
    assert cfg.domain_services_reviewed == []
    assert "a.example" in ds.gate_reason(cfg)


def test_the_domain_catalogue_is_the_user_level_set_and_excludes_infra():
    assert tuple(ds.DOMAIN_CATALOGUE) == tuple(OPTIONAL_SERVICES_CHOICES)
    for slug in INFRA_SERVICES_CHOICES:
        assert slug not in ds.DOMAIN_CATALOGUE
        assert ds.scope_of(slug) == ds.SCOPE_NODE
    for slug in ds.DOMAIN_CATALOGUE:
        assert ds.scope_of(slug) == ds.SCOPE_DOMAIN


def test_normalisation_is_catalogue_order_with_extras_last():
    """DISCRIMINATING PAIR: games/owncast is where catalogue order (… games, owncast,
    tube …) and SERVICE_GROUPS presentation order ("Media & Play" = owncast, tube,
    games) DISAGREE, so this can tell the two apart."""
    assert ds.normalise_slugs(["owncast", "games"]) == ["games", "owncast"]
    assert ds.normalise_slugs(["tor", "akkoma"]) == ["akkoma", "tor"]
    assert ds.carried_over_slugs(["tor", "akkoma"]) == ["tor"]


def test_a_catalogue_slug_missing_from_the_grouping_is_still_offered(monkeypatch):
    """SERVICE_GROUPS is presentation; DOMAIN_CATALOGUE is the catalogue. If the two
    drift, the slug must still be offered rather than silently vanish — the exact
    quiet-drop failure this surface has had before."""
    monkeypatch.setattr(ds, "SERVICE_GROUPS",
                        (("Social & Community", ("akkoma",)),))   # drops 7 slugs
    offered = [s for _g, slugs in ds.grouped_domain_catalogue() for s in slugs]
    assert sorted(offered) == sorted(OPTIONAL_SERVICES_CHOICES)
    assert "Other services" in [g for g, _s in ds.grouped_domain_catalogue()]


def test_regrouping_cannot_change_what_a_domain_emits(monkeypatch):
    """SERVICE_GROUPS is presentation ONLY. If a presentation order leaked into the
    recorded value, moving a slug between two group tuples — a purely cosmetic edit —
    would rewrite the bytes of domains[].optional_services in the mesh manifest."""
    def _reordered(slugs):
        rest = [s for s in slugs if s != "games"]
        return ("games", *rest)
    swapped = tuple((title, _reordered(slugs) if "games" in slugs else slugs)
                    for title, slugs in SERVICE_GROUPS)
    assert swapped != SERVICE_GROUPS, "the regrouping mutation did not change anything"
    before = ds.normalise_slugs(["owncast", "games"])
    before_groups = ds.grouped_domain_catalogue()
    monkeypatch.setattr(ds, "SERVICE_GROUPS", swapped)
    after_groups = ds.grouped_domain_catalogue()
    assert before_groups != after_groups, "the regrouping changed no presentation"
    assert ds.normalise_slugs(["owncast", "games"]) == before == ["games", "owncast"]
