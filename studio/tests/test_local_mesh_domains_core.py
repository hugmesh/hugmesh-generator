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
  (plus an unrecorded own domain) — never every row in the record.
"""
from hugmesh_studio.core.config import DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, Domain
from hugmesh_studio.core.local_mesh_bootstrap import (LocalMeshBootstrap,
                                                      LocalMeshBootstrapConfig)
from hugmesh_studio.core.local_mesh_domains import (
    LocalMeshDomains, added_row_problems, bootstrap_domain_records,
    domains_from_bootstrap, own_idp_names, reviewed_record_names)

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
