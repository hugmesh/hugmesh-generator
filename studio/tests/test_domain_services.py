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
from hugmesh_studio.core.worklist import WORKLIST_INFRA_SERVICES, WorklistEntry

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _mesh(**kw):
    """An ImageConfig whose domains can actually REACH something.

    ``ImageConfig.mode`` defaults to ``standalone``, and there a domain emits no
    ``--domains`` and no mesh manifest is written at all
    (``worklist_driver.run_all`` writes it only when ``base.mode == "mesh"``), so
    ``gate_applies`` deliberately does not bite — see
    ``test_the_gate_bites_exactly_where_domains_reach_something``. Every gate test
    below is about the case where the domains DO reach a cluster."""
    kw.setdefault("mode", "mesh")
    return ImageConfig(**kw)


# ── the seam ──────────────────────────────────────────────
def test_gate_passes_when_there_are_no_domains():
    # No table rows AND no own domain to ask about...
    assert ds.gate_reason(_mesh(cluster_domain="")) == ""
    # ...or the own domain's page already walked (#631: the own domain is gated on the
    # build like a row — see the "own domain" section below).
    cfg = _mesh()
    ds.record_reviewed(cfg, [cfg.cluster_domain])
    assert ds.gate_reason(cfg) == ""


def test_gate_names_every_unconfigured_domain():
    cfg = _mesh(domains=[Domain(name="a.example"), Domain(name="b.example")])
    ds.record_reviewed(cfg, [cfg.cluster_domain])      # the rows are the subject here
    msg = ds.gate_reason(cfg)
    assert "a.example" in msg and "b.example" in msg
    assert "2 domains" in msg


def test_gate_names_the_action_it_refused():
    cfg = _mesh(domains=[Domain(name="a.example")])
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
    cfg = _mesh(domains=[Domain(name="a.example")])
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
    cfg = _mesh(domains=[Domain(name="a.example")])
    msg = ds.gate_reason(cfg, "do the thing")
    assert "Cannot do the thing" in msg
    assert "Domain services" in msg


def test_an_empty_selection_is_a_real_answer_once_the_domain_is_configured():
    """``optional_services == []`` means "the cluster-wide set applies" — a real
    answer, and the reason emptiness could not double as "never configured"."""
    cfg = _mesh(domains=[Domain(name="a.example", optional_services=[])])
    assert ds.gate_reason(cfg) != ""
    ds.record_reviewed(cfg, [cfg.cluster_domain, "a.example"])
    assert ds.gate_reason(cfg) == ""
    assert cfg.domains[0].optional_services == []


def test_a_marker_for_a_domain_that_no_longer_exists_is_dropped():
    """REBUILT, never merged: a renamed or deleted domain must not leave a marker that
    would let the gate pass for a domain nobody configured."""
    cfg = _mesh(domains=[Domain(name="a.example")])
    ds.record_reviewed(cfg, ["a.example", "ghost.example"])
    assert cfg.domain_services_reviewed == ["a.example"]
    cfg.domains = [Domain(name="renamed.example")]
    ds.record_reviewed(cfg, cfg.domain_services_reviewed)
    assert cfg.domain_services_reviewed == []
    assert "renamed.example" in ds.gate_reason(cfg)


def test_the_marker_never_reaches_either_mesh_manifest():
    """It is the GATE's bookkeeping, not provisioning data — a manifest must be
    byte-identical whether or not the page was walked."""
    cfg = _mesh(domains=[Domain(name="a.example")])
    before = cfg.mesh_manifest()
    ds.record_reviewed(cfg, ["a.example"])
    assert cfg.mesh_manifest() == before
    assert "domain_services_reviewed" not in cfg.mesh_manifest()
    assert all("domain_services_reviewed" not in d
               for d in cfg.mesh_manifest()["domains"])


def test_the_marker_round_trips_through_a_saved_config():
    cfg = _mesh(domains=[Domain(name="a.example")])
    ds.record_reviewed(cfg, [cfg.cluster_domain, "a.example"])
    again = ImageConfig.from_dict(cfg.to_dict())
    assert again.domain_services_reviewed == [cfg.cluster_domain, "a.example"]
    assert ds.gate_reason(again) == ""


def test_a_junk_marker_fails_closed_not_open():
    """A hand-edited config whose marker is not a list must NOT stand in for "all
    reviewed" — absent is the fail-closed reading and the gate then says so."""
    cfg = ImageConfig.from_dict({"mode": "mesh",
                                 "domains": [{"name": "a.example"}],
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


# ── the gate's predicate agrees with what the domains can actually reach ──────────
# Added while landing #495 after the skeptic pass. gate_reason used to refuse for
# EVERY config carrying a named domain, including flows whose Domain services step
# does not exist (standalone skips it statically; a cloud NODE role skips the whole
# superadmin plane). That refusal named a screen those flows have no route to — a dead
# end. `gate_applies` is the fix, and these pin it against the EMISSION rather than
# against prose, so a future change to where domains go re-opens the question here.
def _reaches_anything(cfg) -> bool:
    """Whether this config's domains reach ANY artifact: the argv the builder gets, or
    the mesh manifest. Measured, not asserted."""
    bare = ImageConfig(mode=cfg.mode, role=cfg.role)
    argv_delta = [a for a in cfg.to_cli_args() if a not in bare.to_cli_args()]
    # worklist_driver.run_all writes the manifest ONLY when base.mode == "mesh"
    writes_manifest = cfg.mode == "mesh"
    return bool(argv_delta) or writes_manifest


def test_the_gate_bites_exactly_where_domains_reach_something():
    cases = [
        ImageConfig(mode="standalone", domains=[Domain(name="a.example")]),
        ImageConfig(mode="cloud", role="omnibus", domains=[Domain(name="a.example")]),
        ImageConfig(mode="cloud", role="desktop", domains=[Domain(name="a.example")]),
        ImageConfig(mode="mesh", domains=[Domain(name="a.example")]),
    ]
    for cfg in cases:
        reaches = _reaches_anything(cfg)
        refused = bool(ds.gate_reason(cfg))
        assert refused == reaches, (
            f"{cfg.mode}/{cfg.role or '-'}: domains reach={reaches} but "
            f"gate refuses={refused} — a gate that refuses a config whose domains "
            f"go nowhere is a dead end, and one that passes a config whose domains "
            f"DO go somewhere is the hole this feature exists to close")
        assert ds.gate_applies(cfg) == reaches


def test_the_gate_still_bites_a_mesh_whose_domains_opt_in_is_off():
    """superadmin_plane_applies' MESH arm also asks cfg.additional_domains, and
    gate_applies deliberately does NOT mirror that. A config carrying domains with the
    opt-in off is one NetworkPage.validatePage has not cleared YET — and on the docker
    mesh-start path that page may never run at all, so deferring would make those
    domains unrefusable."""
    from hugmesh_studio.core.config import superadmin_plane_applies
    cfg = ImageConfig(mode="mesh", additional_domains=False,
                      domains=[Domain(name="a.example")])
    assert superadmin_plane_applies(cfg) is False
    assert ds.gate_applies(cfg) is True
    assert "a.example" in ds.gate_reason(cfg)


def test_the_standalone_default_mode_is_the_one_that_turns_the_gate_off():
    """Stated out loud because ImageConfig.mode DEFAULTS to standalone: anyone reading
    gate_applies must see that the off case is the default value, and that it is safe
    only because a standalone config's domains emit nothing at all."""
    assert ImageConfig().mode == "standalone"
    off = ImageConfig(domains=[Domain(name="a.example")])
    assert ds.gate_reason(off) == ""
    assert not _reaches_anything(off)


# ── the RESTART gate (previous builds -> Restart) ────────────────────────────────
def test_restart_gate_exempts_a_session_recorded_before_the_field_existed():
    """A session saved before domain_services_reviewed existed carries no marker.
    Refusing it would refuse every historical restart over a question nobody asked."""
    old = ImageConfig.from_dict({"mode": "mesh",
                                 "domains": [{"name": "a.example"}]})
    assert old.domain_services_reviewed == []
    assert ds.restart_gate_reason(old) == ""
    # ...while the BUILD gate still refuses the same config, which is the point:
    # the exemption is for the restart door alone.
    assert "a.example" in ds.gate_reason(old)


def test_restart_gate_bites_a_config_produced_under_this_feature():
    cfg = _mesh(domains=[Domain(name="a.example"), Domain(name="b.example")])
    ds.record_reviewed(cfg, ["a.example"])
    msg = ds.restart_gate_reason(cfg)
    assert "b.example" in msg
    assert "a.example" not in msg.split("—")[-1]
    assert ds.ACTION_BUILD_RESTART in msg


def test_restart_gate_passes_a_fully_configured_session():
    cfg = _mesh(domains=[Domain(name="a.example")])
    ds.record_reviewed(cfg, ["a.example"])
    assert ds.restart_gate_reason(cfg) == ""


def test_the_restart_remedy_names_redo_not_a_step_that_flow_lacks():
    """start_build_from_session jumps straight to the terminal progress page; there is
    no wizard step to walk back to from there. Redo is the route that exists — and the
    caller (sessions_widget._restart) branches on the word, offering to do it."""
    cfg = _mesh(domains=[Domain(name="a.example"), Domain(name="b.example")])
    ds.record_reviewed(cfg, ["a.example"])
    msg = ds.restart_gate_reason(cfg)
    assert "Redo" in msg
    assert "Back to the main menu" not in msg


# ── #631 section 1: the mesh's OWN domain is gated on the build, like a row ─────────
# After #595 the own domain (cfg.cluster_domain) has a services page on every mesh flow,
# but the gate read the table rows only, so the page was enforced by being unavoidable
# on a FRESH walk — and a config LOADED on the Sessions screen that never opened it
# still built. These pin the gate on the build door, and the two doors it deliberately
# stays off (mesh start: a dead end on the local-docker route; restart: history).
def test_the_build_gate_names_the_own_domain_when_its_page_was_never_walked():
    """#589's suggested test: default card + build -> the ACTION_IMAGE_BUILD reason
    names the primary domain when its services were never confirmed."""
    cfg = _mesh()                                 # the default card: no table rows
    assert cfg.domains == [] and cfg.cluster_domain == "hugmesh.net"
    msg = ds.gate_reason(cfg, ds.ACTION_IMAGE_BUILD)
    assert "hugmesh.net" in msg and "1 domain has" in msg
    assert ds.ACTION_REMEDY[ds.ACTION_IMAGE_BUILD] in msg
    ds.record_reviewed(cfg, [cfg.cluster_domain])
    assert ds.gate_reason(cfg, ds.ACTION_IMAGE_BUILD) == ""


def test_the_own_domain_is_named_first_then_the_rows_in_table_order():
    cfg = _mesh(domains=[Domain(name="b.example"), Domain(name="a.example")])
    assert ds.unconfigured_domains(cfg, include_own=True) == [
        "hugmesh.net", "b.example", "a.example"]
    assert "3 domains" in ds.gate_reason(cfg)


def test_a_rows_only_walk_still_refuses_the_build_for_the_own_domain():
    """The #495-to-#595 shape: every table row walked, the own domain never (it had no
    page yet). Loaded and sent to the build, it is refused BY NAME — and only for the
    own domain."""
    cfg = _mesh(domains=[Domain(name="a.example")])
    ds.record_reviewed(cfg, ["a.example"])
    assert ds.unconfigured_domains(cfg, include_own=True) == ["hugmesh.net"]
    msg = ds.gate_reason(cfg, ds.ACTION_IMAGE_BUILD)
    assert "1 domain has no recorded service configuration — hugmesh.net." in msg


def test_the_own_domain_is_not_gated_on_the_docker_mesh_start():
    """"Mesh node" then Back into "Local Docker mesh" leaves mode == "mesh" with the
    default cluster domain and no walk; that route cannot show the image flow's
    own-domain page, and the image flow's own domain does not reach a docker mesh. A
    refusal there would be a dead end — so ACTION_MESH_START stays rows-only."""
    cfg = _mesh()
    assert ds.gate_reason(cfg, ds.ACTION_MESH_START) == ""
    assert ds.ACTION_MESH_START not in ds.OWN_DOMAIN_GATED_ACTIONS
    cfg.domains = [Domain(name="a.example")]
    msg = ds.gate_reason(cfg, ds.ACTION_MESH_START)
    assert "a.example" in msg and "hugmesh.net" not in msg


def test_the_restart_gate_keeps_its_rows_only_rule_for_history():
    """The migration rule for configs recorded before #595: a restart re-dispatches a
    RECORDED config, and one recorded in the #495-to-#595 window carries row markers
    and no own marker. Refusing it would punish history — the rule restart_gate_reason
    exists for. The build of the same config IS refused (it goes back through the
    wizard, whose walk records the own domain)."""
    cfg = _mesh(domains=[Domain(name="a.example")])
    ds.record_reviewed(cfg, ["a.example"])
    assert ds.restart_gate_reason(cfg) == ""
    assert ds.ACTION_BUILD_RESTART not in ds.OWN_DOMAIN_GATED_ACTIONS
    assert "hugmesh.net" in ds.gate_reason(cfg, ds.ACTION_IMAGE_BUILD)


def test_the_own_domain_gate_is_mesh_only():
    """implicit_own_domain is "" off the mesh route: a cloud client's cluster domain is
    a REAL row 0, a cloud node and standalone have no domain plane at all."""
    for cfg in (ImageConfig(mode="standalone"),
                ImageConfig(mode="cloud", role="desktop"),
                ImageConfig(mode="cloud", role="omnibus")):
        assert cfg.cluster_domain == "hugmesh.net"
        assert ds.gate_reason(cfg, ds.ACTION_IMAGE_BUILD) == "", cfg.mode


def test_a_row_named_after_the_cluster_domain_is_asked_once():
    cfg = _mesh(domains=[Domain(name="hugmesh.net")])
    assert ds.unconfigured_domains(cfg, include_own=True) == ["hugmesh.net"]
    assert "1 domain has" in ds.gate_reason(cfg)


def test_a_walked_own_domain_does_not_survive_a_cluster_domain_rename():
    """The marker is a NAME. Walking hugmesh.net says nothing about acme.org."""
    cfg = _mesh()
    ds.record_reviewed(cfg, [cfg.cluster_domain])
    cfg.cluster_domain = "acme.org"
    assert "acme.org" in ds.gate_reason(cfg)
    ds.record_reviewed(cfg, ds.reviewed_names(cfg))      # a page write prunes it
    assert cfg.domain_services_reviewed == []


def test_the_own_domain_gate_is_a_pure_read_and_emission_neutral():
    """The gate adds no row and writes nothing: an untouched default-card flow emits
    the same argv and the same manifest whether or not the gate has run, and still no
    --domains and no manifest domains entry (the ASK-8 emission guard)."""
    cfg = _mesh()
    argv, manifest, saved = (cfg.to_cli_args(), cfg.mesh_manifest(), cfg.to_dict())
    assert ds.gate_reason(cfg) != ""
    assert (cfg.to_cli_args(), cfg.mesh_manifest(), cfg.to_dict()) == (
        argv, manifest, saved)
    assert "--domains" not in argv and manifest["domains"] == []
    assert cfg.domains == [] and cfg.domain_services_reviewed == []


# ── one wording, one source of truth ─────────────────────────────────────────────
def test_services_summary_tells_the_three_states_apart():
    assert ds.services_summary([], False) == "not configured yet"
    assert ds.services_summary(["akkoma"], False) == "not confirmed — akkoma"
    assert ds.services_summary([], True) == "cluster default"
    assert ds.services_summary(["owncast", "games"], True) == "games, owncast"


def test_domain_summary_is_services_summary_for_a_domain():
    """domain_summary used to carry its own copy of the three branches while the cell
    the operator actually reads carried another — two sources of truth for the wording
    the whole honesty argument rests on, and the tested one was not the rendered one."""
    cfg = _mesh(domains=[Domain(name="a.example", optional_services=["akkoma"])])
    d = cfg.domains[0]
    assert ds.domain_summary(d, cfg) == ds.services_summary(["akkoma"], False)
    ds.record_reviewed(cfg, ["a.example"])
    assert ds.domain_summary(d, cfg) == ds.services_summary(["akkoma"], True)
    assert ds.domain_summary(Domain(name="a.example"), cfg) == "cluster default"


# ── whitespace cannot wedge the gate ─────────────────────────────────────────────
def test_a_padded_name_can_still_satisfy_the_gate():
    """record_reviewed stored d.name RAW while unconfigured_domains compared the
    STRIPPED name, so a hand-edited config carrying ' a.example ' could never satisfy
    the gate — a permanently unbuildable configuration with no way out."""
    cfg = _mesh(domains=[Domain(name=" a.example ")])
    ds.record_reviewed(cfg, [" a.example ", " " + cfg.cluster_domain + " "])
    # the own domain first (the walk order), both stripped
    assert cfg.domain_services_reviewed == [cfg.cluster_domain, "a.example"]
    assert ds.gate_reason(cfg) == ""


def test_a_padded_marker_loaded_from_disk_is_honoured():
    cfg = ImageConfig.from_dict({"mode": "mesh",
                                 "domains": [{"name": "a.example"}],
                                 "domain_services_reviewed": [" a.example ",
                                                              " hugmesh.net "]})
    assert cfg.cluster_domain == "hugmesh.net"
    assert ds.reviewed_names(cfg) == {"a.example", "hugmesh.net"}
    assert ds.gate_reason(cfg) == ""


# ── #497: the scope model, and the two state reads that are easy to get wrong ────────────────────────────────────────────────────
def test_the_three_scopes_each_say_where_they_are_set_and_what_they_bind():
    """Two DIFFERENT questions, kept apart. "Where is this set" and "what does this
    bind" are not the same fact, and answering only the first is how a surface ends up
    implying a node-plane toggle is a domain property."""
    for scope in (ds.SCOPE_DOMAIN, ds.SCOPE_IMAGE, ds.SCOPE_NODE):
        assert ds.SCOPE_LABELS[scope]
        assert ds.SCOPE_WHERE[scope]
        assert ds.SCOPE_BINDS[scope]
        assert ds.SCOPE_WHERE[scope] != ds.SCOPE_BINDS[scope]
    assert "domain" in ds.SCOPE_BINDS[ds.SCOPE_DOMAIN]
    assert "not one domain" in ds.SCOPE_BINDS[ds.SCOPE_IMAGE]
    assert "never one domain" in ds.SCOPE_BINDS[ds.SCOPE_NODE]


def test_every_infra_slug_has_its_own_where_and_none_of_them_is_domain_scoped():
    assert set(ds.INFRA_WHERE) == set(INFRA_SERVICES_CHOICES)
    for slug in INFRA_SERVICES_CHOICES:
        assert ds.scope_of(slug) == ds.SCOPE_NODE
        assert slug not in ds.DOMAIN_CATALOGUE


def test_a_slug_with_no_per_node_control_does_not_claim_to_have_one():
    """`workloadConsole` and `anubis` are cluster-plane: `WORKLIST_INFRA_SERVICES` is
    tor + egress-vpn only. Sending the operator to the worklist to find them would be
    a hunt for a control that does not exist — a different failure from hiding them,
    and just as bad."""
    for slug in WORKLIST_INFRA_SERVICES:
        assert "worklist" in ds.INFRA_WHERE[slug]
    for slug in set(INFRA_SERVICES_CHOICES) - set(WORKLIST_INFRA_SERVICES):
        assert "worklist" not in ds.INFRA_WHERE[slug]
        assert "no per-node control" in ds.INFRA_WHERE[slug]


# ── the live state column ──────────────────────────────────────────────────────
def test_the_state_column_reads_the_image_wide_selection():
    cfg = ImageConfig(optional_services=["anubis"])
    assert ds.image_service_state(cfg, "anubis") == "on (mesh-wide)"
    assert ds.image_service_state(cfg, "tor") == "off"


def test_all_services_does_not_claim_to_turn_the_infra_slugs_on():
    """`--all-services` expands to the USER-LEVEL set, which by construction excludes
    every infra slug. A membership test would report "off" for the right reason by
    accident and "on" for the user-level ones not at all — so both arms are pinned."""
    cfg = ImageConfig(optional_services=["all"])
    for slug in INFRA_SERVICES_CHOICES:
        state = ds.image_service_state(cfg, slug)
        assert state.startswith("off")
        assert "does not include the infra slugs" in state
    assert ds.image_service_state(cfg, "akkoma") == "on (mesh-wide)"


def test_the_explicit_none_sentinel_is_reported_as_the_explicit_none_it_is():
    cfg = ImageConfig(optional_services=["none"])
    assert "no optional services at all" in ds.image_service_state(cfg, "anubis")


def test_the_dedicated_tor_flag_counts_as_on():
    """x86 bakes the onion through `--with-tor`, not through the slug list. Reading only
    optional_services would report "off" for a node that really does publish one."""
    cfg = ImageConfig(tor_onion_service=True)
    assert ds.image_service_state(cfg, "tor") == "on (mesh-wide)"


def test_the_state_column_names_the_nodes_that_opted_in():
    entries = [WorklistEntry(role="omnibus", platform="x86",
                             infra_services=("tor",)),
               WorklistEntry(role="pki", platform="rpi5")]
    assert ds.node_service_state(entries, "tor") == "omnibus.x86"
    assert ds.node_service_state(entries, "egress-vpn") == ""
    rows = {r[0]: r for r in ds.other_scope_rows(ImageConfig(), entries)}
    assert "omnibus.x86" in rows["tor"][3]


def test_other_scope_rows_cover_every_infra_slug_plus_the_image_surface():
    rows = ds.other_scope_rows(ImageConfig())
    names = [r[0] for r in rows]
    assert names[:len(INFRA_SERVICES_CHOICES)] == list(INFRA_SERVICES_CHOICES)
    assert names[-1] == ds.IMAGE_SCOPE_ROW_LABEL
    assert rows[-1][1] == ds.SCOPE_IMAGE
    # the image-wide surface is named as a SURFACE, not re-listed slug by slug: a
    # second catalogue here would be one more thing to drift against the first.
    assert "edge-AI" in rows[-1][3]
    assert "managed backing services" in rows[-1][3]


def test_no_domain_catalogue_slug_leaks_into_the_not_domain_scoped_table():
    listed = {r[0] for r in ds.other_scope_rows(ImageConfig())}
    for slug in OPTIONAL_SERVICES_CHOICES:
        assert slug not in listed


# ── #637: booting a PREVIOUS session's images (Mesh emulation / QEMU tests) ──────────
from _session_records import write_build_record  # noqa: E402


@pytest.fixture
def _state(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def test_a_session_with_an_unwalked_row_is_refused_by_name(_state):
    write_build_record("20260901-000000-aaaaaa", domains=("a.example", "b.example"),
                       reviewed=("hugmesh.net", "a.example"))
    msg = ds.session_boot_gate_reason("20260901-000000-aaaaaa")
    assert "b.example" in msg and "Cannot boot this build session's images" in msg
    assert ds.ACTION_REMEDY[ds.ACTION_EMULATE] in msg
    assert "Redo" in msg


def test_a_fully_walked_session_boots(_state):
    write_build_record("s1", domains=("a.example",),
                       reviewed=("hugmesh.net", "a.example"))
    assert ds.session_boot_gate_reason("s1") == ""


def test_the_session_gate_is_narrow_like_the_restart(_state):
    """No record, or a record from before #495 (no marker at all): not refused —
    those images are on disk and nobody could have answered the question then."""
    assert ds.session_boot_gate_reason("no-such-session") == ""
    assert ds.session_boot_gate_reason("") == ""
    write_build_record("old", domains=("a.example",), reviewed=())
    assert ds.session_boot_gate_reason("old") == ""


def test_the_session_gate_never_asks_about_the_own_domain(_state):
    """A session recorded before #631 walked its rows and never had the own domain
    gated — emulating its images must not be refused over it."""
    write_build_record("s2", domains=("a.example",), reviewed=("a.example",))
    assert ds.session_boot_gate_reason("s2") == ""
    assert ds.ACTION_EMULATE not in ds.OWN_DOMAIN_GATED_ACTIONS


def test_an_unreadable_record_is_a_record_with_nothing_to_say(_state, tmp_path):
    from hugmesh_studio.core import build_sessions
    import os as _os
    _os.makedirs(build_sessions.sessions_dir(), exist_ok=True)
    with open(_os.path.join(build_sessions.sessions_dir(), "junk.json"), "w") as fh:
        fh.write("{not json")
    assert ds.session_boot_gate_reason("junk") == ""
