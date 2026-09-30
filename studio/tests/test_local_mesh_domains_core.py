"""Qt-free core of the generated local mesh's domains (#494 fix round, PR #595).

No Qt import, so this runs on the pre-merge CI job that installs no Qt binding:

* ``own_idp_names`` collapses a repeated name (one compose service per name — the
  CLI's ``_parse_own_casdoor_domains`` rule), so two Own rows with one name cannot
  emit the same ``casdoor-<slug>`` key twice;
* ``added_row_problems`` refuses a non-hostname, a duplicate, and a row named after
  row 0, in the TUI's words;
* ``LocalMeshBootstrap.validate()`` is the backstop for any other door: a duplicate
  own-IdP name, or one equal to the mesh's own apex, is a problem;
* ``domains_from_bootstrap`` marks REVIEWED only what the record says was reviewed
  (plus an unrecorded own domain) — never every row in the record;
* ``record_walk`` writes a form walk INTO a saved record: markers plus the walk's
  ticks, never a field that runs.
"""
from hugmesh_studio.core.config import DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, Domain
from hugmesh_studio.core.local_mesh_bootstrap import (LocalMeshBootstrap,
                                                      LocalMeshBootstrapConfig)
from hugmesh_studio.core.local_mesh_domains import (
    LocalMeshDomains, added_row_problems, bootstrap_domain_records,
    domains_from_bootstrap, own_idp_names, record_walk, reviewed_record_names)

import os

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def test_own_idp_names_collapses_a_repeated_name_to_the_first():
    rows = [Domain(name="a.example", idp=DOMAIN_IDP_OWN),
            Domain(name="b.example", idp=DOMAIN_IDP_SUPERDOMAIN),
            Domain(name=" a.example ", idp=DOMAIN_IDP_OWN),
            Domain(name="c.example", idp=DOMAIN_IDP_OWN)]
    assert own_idp_names(rows) == ("a.example", "c.example")


def test_added_row_problems():
    assert added_row_problems(["a.example", "b.example", ""], "hugmesh.net") == []
    p = added_row_problems(["a.example", "a.example", "hugmesh.net", "junk"],
                           "hugmesh.net")
    assert p == ["already listed: a.example",
                 "hugmesh.net is this mesh's own domain (row 0) — it is already "
                 "listed and cannot be added again",
                 "not a domain name: 'junk' (lowercase dotted hostname, e.g. "
                 "chat.example.org)"]


def _problems(**kw):
    return LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(**kw)).validate()


def test_validate_refuses_a_duplicate_or_apex_own_idp_name():
    base = _problems()
    assert not [p for p in base if "own-Casdoor" in p]
    dup = _problems(own_idp_domains=("a.example", "A.example"))
    assert any("listed twice" in p for p in dup), dup
    apex = LocalMeshBootstrapConfig().resolved_domain()
    own = _problems(own_idp_domains=(apex,))
    assert any("this mesh's own domain" in p for p in own), own
    ok = _problems(own_idp_domains=("team.example", "shop.example"))
    assert not [p for p in ok if "own-Casdoor" in p], ok


def test_domains_from_bootstrap_reviews_only_what_the_record_says():
    assert domains_from_bootstrap(LocalMeshBootstrapConfig()) is None
    cfg = LocalMeshBootstrapConfig(
        domains=({"name": "a.example", "title": "A", "idp": "superdomain",
                  "optional_services": ["games"]},),
        own_idp_domains=("b.example",), domain_services_reviewed=("a.example",))
    md = domains_from_bootstrap(cfg)
    own = cfg.resolved_domain()
    assert md.names() == [own, "a.example", "b.example"]
    assert md.by_name("b.example").idp == DOMAIN_IDP_OWN
    assert md.by_name("a.example").optional_services == ["games"]
    # own (unrecorded) + the marked row; the CLI-only b.example is NOT reviewed
    assert md.domain_services_reviewed == [own, "a.example"]


def test_a_recorded_own_row_needs_its_own_marker():
    own = LocalMeshBootstrapConfig().resolved_domain()
    cfg = LocalMeshBootstrapConfig(domains=({"name": own, "title": "Mine",
                                             "idp": "superdomain",
                                             "optional_services": []},))
    assert domains_from_bootstrap(cfg).domain_services_reviewed == []


def test_reviewed_record_names_never_names_an_unrecorded_domain():
    md = LocalMeshDomains(domains=[Domain(name="hugmesh.net"),
                                   Domain(name="a.example")],
                          domain_services_reviewed=["hugmesh.net", "a.example"],
                          own_name="hugmesh.net")
    recs = bootstrap_domain_records(md.domains, md.own_name)
    assert [r["name"] for r in recs] == ["a.example"]
    assert reviewed_record_names(md, recs) == ("a.example",)
    assert reviewed_record_names(md, ()) == ()


def test_record_walk_writes_markers_and_ticks_and_nothing_that_runs():
    cfg = LocalMeshBootstrapConfig(
        own_idp_domains=("cli.example",),
        domains=({"name": "a.example", "title": "A", "idp": DOMAIN_IDP_SUPERDOMAIN,
                  "optional_services": ["phpbb"]},),
        domain_services_reviewed=())
    runs_before = {k: v for k, v in cfg.to_dict().items()
                   if k not in ("domains", "domain_services_reviewed")}
    form = LocalMeshDomains(domains=[
        Domain(name="a.example", title="changed in the form", idp=DOMAIN_IDP_OWN,
               optional_services=["games"]),
        Domain(name="cli.example", title="", optional_services=["tube"])])
    record_walk(cfg, form, ["a.example", "cli.example"])
    rows = {r["name"]: r for r in cfg.domains}
    # a recorded row: the walk's ticks replace the old selection; title and sign-in
    # stay the RECORD's (what runs is the record, not the form)
    assert rows["a.example"] == {"name": "a.example", "title": "A",
                                 "idp": DOMAIN_IDP_SUPERDOMAIN,
                                 "optional_services": ["games"]}
    # an own-IdP name the record carried alone gets a row, sign-in own
    assert rows["cli.example"]["idp"] == DOMAIN_IDP_OWN
    assert rows["cli.example"]["optional_services"] == ["tube"]
    assert cfg.domain_services_reviewed == ("a.example", "cli.example")
    assert {k: v for k, v in cfg.to_dict().items()
            if k not in ("domains", "domain_services_reviewed")} == runs_before
    # idempotent: a second write adds no duplicate marker or row
    record_walk(cfg, form, ["a.example"])
    assert cfg.domain_services_reviewed == ("a.example", "cli.example")
    assert [r["name"] for r in cfg.domains] == ["a.example", "cli.example"]


# ── #636: the saved mesh -> node images import carries EVERY domain ─────────────────
from hugmesh_studio.core import domain_services as _ds  # noqa: E402
from hugmesh_studio.core.config import ImageConfig  # noqa: E402
from hugmesh_studio.core.local_mesh_bootstrap import (  # noqa: E402
    LocalMeshBootstrapConfig as _BootCfg,
)
from hugmesh_studio.core.local_mesh_domains import (  # noqa: E402
    apply_imported_domains, imported_domains_lines, imported_mesh_domains,
)


def _n_domain_record(**kw):
    """A saved local mesh generated with THREE domains: its own (with a per-domain
    selection), an added superdomain-sign-in row, and an added own-Casdoor row — only
    the own domain and a.example were walked."""
    kw.setdefault("cluster_domain", "saved.example.org")
    kw.setdefault("domains", (
        {"name": "saved.example.org", "title": "", "idp": DOMAIN_IDP_SUPERDOMAIN,
         "optional_services": ["games"]},
        {"name": "a.example", "title": "Alpha", "idp": DOMAIN_IDP_SUPERDOMAIN,
         "optional_services": ["phpbb", "akkoma"]},
        {"name": "b.example", "title": "Beta", "idp": DOMAIN_IDP_OWN,
         "optional_services": []},
    ))
    kw.setdefault("own_idp_domains", ("b.example",))
    kw.setdefault("domain_services_reviewed", ("saved.example.org", "a.example"))
    return _BootCfg(env="prod", **kw)


def _node_flow_cfg(domain="saved.example.org"):
    """The node-image flow's config at the moment the localcloud import runs: mesh
    mode, cluster_domain already set to the imported apex."""
    return ImageConfig(mode="mesh", cluster_domain=domain)


def test_every_added_domain_reaches_the_node_image_config():
    cfg = _node_flow_cfg()
    added = apply_imported_domains(cfg, imported_mesh_domains(_n_domain_record()))
    assert added == ["a.example", "b.example"]
    by = {d.name: d for d in cfg.domains}
    assert list(by) == ["a.example", "b.example"]          # the OWN domain is no row
    assert (by["a.example"].title, by["a.example"].idp,
            by["a.example"].optional_services) == (
        "Alpha", DOMAIN_IDP_SUPERDOMAIN, ["akkoma", "phpbb"])  # catalogue order
    assert (by["b.example"].title, by["b.example"].idp) == ("Beta", DOMAIN_IDP_OWN)
    assert cfg.own_idp_domains() == ("b.example",)          # Sign-in = Own survives
    assert cfg.cluster_domain_services == ["games"]          # the own row's selection
    assert cfg.additional_domains is True                    # or the default card wipes
    # the implicit own domain is untouched by the rows: still implicit
    assert _ds.implicit_own_domain(cfg) == "saved.example.org"


def test_only_what_the_record_walked_is_marked_reviewed():
    cfg = _node_flow_cfg()
    apply_imported_domains(cfg, imported_mesh_domains(_n_domain_record()))
    assert cfg.domain_services_reviewed == ["saved.example.org", "a.example"]
    # b.example was never walked on the local mesh: the build gate still names it
    assert _ds.unconfigured_domains(cfg, include_own=True) == ["b.example"]


def test_the_import_never_invents_the_own_domains_walk():
    """domains_from_bootstrap marks the record's own domain reviewed when it is not a
    recorded row (a START leniency). An import must not turn that into a walk."""
    rec = _n_domain_record(
        domains=({"name": "a.example", "title": "", "idp": DOMAIN_IDP_SUPERDOMAIN,
                  "optional_services": []},),
        own_idp_domains=(), domain_services_reviewed=("a.example",))
    assert "saved.example.org" in domains_from_bootstrap(rec).domain_services_reviewed
    md = imported_mesh_domains(rec)
    assert md.domain_services_reviewed == ["a.example"]
    cfg = _node_flow_cfg()
    cfg.cluster_domain_services = ["tube"]            # the operator's own earlier pick
    apply_imported_domains(cfg, md)
    assert cfg.domain_services_reviewed == ["a.example"]
    assert cfg.cluster_domain_services == ["tube"]     # the record said nothing: kept


def test_a_record_with_no_domain_rows_imports_exactly_the_apex():
    """The pre-#636 import, byte for byte: None, and nothing on cfg changes."""
    rec = _BootCfg(env="prod", cluster_domain="saved.example.org")
    assert imported_mesh_domains(rec) is None
    cfg = _node_flow_cfg()
    before = cfg.to_dict()
    assert apply_imported_domains(cfg, None) == []
    assert cfg.to_dict() == before
    assert imported_domains_lines(None) == []


def test_the_record_replaces_the_rows_an_earlier_flow_left():
    """The node images join THIS mesh: its record is the whole domain set. A row an
    earlier flow of the same Studio session left in cfg is not one of its domains
    (the post-merge review of PR #644 found such a row built into the local cloud's
    images), and a same-named row takes the record's title, sign-in and services."""
    cfg = _node_flow_cfg()
    cfg.domains = [Domain(name="b.example", title="Old", optional_services=["tube"]),
                   Domain(name="keep.example")]
    _ds.record_reviewed(cfg, ["b.example", "keep.example"])
    before = cfg.domains
    apply_imported_domains(cfg, imported_mesh_domains(_n_domain_record()))
    assert [d.name for d in cfg.domains] == ["a.example", "b.example"]   # record order
    assert cfg.domains is not before, "replaced with a new list, never merged in place"
    b = cfg.domains[1]
    assert (b.title, b.idp, b.optional_services) == ("Beta", DOMAIN_IDP_OWN, [])
    # b's old marker vouched for services that are gone, and the record never walked
    # it; keep.example is gone with its row
    assert cfg.domain_services_reviewed == ["saved.example.org", "a.example"]


def test_a_record_with_no_domain_rows_clears_an_earlier_flows_rows():
    """None means the mesh serves its own domain only — so the rows and the opt-in an
    earlier flow left are cleared too, for the reason above."""
    cfg = _node_flow_cfg()
    cfg.domains = [Domain(name="x.example", title="X")]
    cfg.additional_domains = True
    _ds.record_reviewed(cfg, ["x.example"])
    assert apply_imported_domains(cfg, None) == []
    assert cfg.domains == [] and cfg.additional_domains is False
    assert cfg.domain_services_reviewed == []


def test_a_hand_edited_record_row_is_read_as_the_config_would_read_it():
    """A record edited by hand (the only way to get these): a sign-in the config cannot
    hold reads as the default (``_domain_from_dict``'s rule), a row whose name is not a
    hostname is not a domain and is not imported, and a name is stripped and
    lowercased — so the imported config still survives a save/load round trip."""
    rec = _n_domain_record(domains=(
        {"name": " A.Example ", "title": "Alpha", "idp": "nonsense",
         "optional_services": ["phpbb"]},
        {"name": "5", "title": "Five", "idp": "own", "optional_services": []},
        {"name": "b.example", "title": "Beta", "idp": DOMAIN_IDP_OWN,
         "optional_services": []}))
    cfg = _node_flow_cfg()
    added = apply_imported_domains(cfg, imported_mesh_domains(rec))
    assert added == ["a.example", "b.example"]
    a = cfg.domains[0]
    assert (a.name, a.title, a.idp, a.optional_services) == \
        ("a.example", "Alpha", DOMAIN_IDP_SUPERDOMAIN, ["phpbb"])
    assert cfg.own_idp_domains() == ("b.example",)
    ImageConfig.from_dict(cfg.to_dict())          # would raise on idp='nonsense'


def test_the_imported_rows_reach_the_mesh_manifest():
    cfg = _node_flow_cfg()
    apply_imported_domains(cfg, imported_mesh_domains(_n_domain_record()))
    m = cfg.mesh_manifest()
    assert [d["name"] for d in m["domains"]] == ["a.example", "b.example"]
    assert m["domains"][1]["idp"] == DOMAIN_IDP_OWN
    assert m["domains"][0]["optional_services"] == ["akkoma", "phpbb"]
    assert m["cluster_domain_services"] == ["games"]


def test_the_summary_lines_name_every_added_domain_and_its_state():
    lines = imported_domains_lines(imported_mesh_domains(_n_domain_record()))
    assert lines == [
        "a.example — superdomain sign-in; services: akkoma, phpbb",
        "b.example — own Casdoor; services: cluster default "
        "(services not confirmed yet)",
    ]
