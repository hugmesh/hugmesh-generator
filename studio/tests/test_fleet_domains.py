"""#587 — the Fleet build route gets the shared Domains table, the per-domain services
walk and the per-domain services gate (GUI + TUI, operator decision 71 = A).

Pinned here, and why each one:

* the rows are RECORDED and GATED but reach NO builder: ``to_env`` / ``to_cli_args``
  are byte-identical with and without them — and the builder facts that make that the
  only honest choice are pinned against the builders themselves (node roles ignore
  ``--domains``, the unaffiliated desktop refuses it, build-all-roles.sh writes no
  manifest);
* the gate refuses BEFORE build-all-roles.sh is spawned — ``FleetDriver.preflight``
  names the domain and the GUI's "Build fleet now" never reaches the driver's run();
* THE TRAP: a session record round-trips through JSON, and an un-rehydrated row is a
  dict the gate reads as nameless — so ``from_dict(to_dict())`` must still refuse;
* a RESTART (load_from_session) of an incompletely walked record is refused at Review
  without the operator ever seeing the services step;
* the GUI collects WITH_TOR / OPTIONAL_SERVICES again (a restart of a WITH_TOR=1 fleet
  used to rebuild without Tor: the page had no widget to put it back in);
* the TUI's fleet screen walks the same objects to the same refusal.
"""
import io
import json
import os
import re

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import build_sessions as bs                     # noqa: E402
from hugmesh_studio.core.config import Domain                            # noqa: E402
from hugmesh_studio.core.fleet import (                                  # noqa: E402
    ACTION_FLEET_BUILD, FLEET_DEFAULT_DOMAIN, FLEET_LANE_NOTE, FLEET_REMEDY,
    FleetConfig, FleetDomains, FleetDriver, commit_fleet_domains,
    fleet_domains_from_config, fleet_gate_reason, seed_fleet_domains)
from hugmesh_studio.core.platform_info import HostInfo                   # noqa: E402
from hugmesh_studio.tui import app as tui_app                            # noqa: E402
from hugmesh_studio.tui import journey                                   # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")


def _read(rel):
    with open(os.path.join(GENERATOR_DIR, rel), encoding="utf-8", errors="replace") as fh:
        return fh.read()


def _cfg(reviewed=("mesh.example",), **kw):
    return FleetConfig(cluster_domain="mesh.example",
                       domains=[Domain(name="mesh.example"),
                                Domain(name="acme.example", optional_services=["akkoma"])],
                       domain_services_reviewed=list(reviewed), **kw)


@pytest.fixture(autouse=True)
def _isolated_state(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


# ── the builder facts the "reaches no builder" choice rests on ───────────────────────
def test_the_default_domain_is_the_builders_own():
    for rel in ("build-x86-host-stage4.sh", "build-rpi5-stage4.sh"):
        m = re.search(r'^CLUSTER_DOMAIN="([^"]+)"', _read(rel), re.M)
        assert m and m.group(1) == FLEET_DEFAULT_DOMAIN, rel


def test_the_builders_would_not_take_the_rows_through_the_pass_through_tail():
    x86 = _read("build-x86-host-stage4.sh")
    assert "--person-role/--domains are ignored for non-client role" in x86
    assert "--unaffiliated conflicts with --person-role/--domains" in x86
    assert "manifest" not in _read("scripts/build-all-roles.sh").lower(), (
        "build-all-roles.sh now mentions a manifest — if it writes the mesh manifest, "
        "the fleet's rows can reach provisioning and FLEET_LANE_NOTE must be re-said")


def test_the_rows_emit_nothing():
    bare = FleetConfig(cluster_domain="mesh.example")
    rich = _cfg(reviewed=("mesh.example", "acme.example"))
    assert rich.to_env() == bare.to_env()
    assert rich.to_cli_args() == bare.to_cli_args()
    d = FleetDriver("/gen", HOST)
    assert d.command(rich, "native") == d.command(bare, "native")
    assert d.command(rich, "docker") == d.command(bare, "docker")


# ── the gate ─────────────────────────────────────────────────────────────────────────
def test_preflight_refuses_an_unwalked_domain_naming_it():
    problems = FleetDriver(GENERATOR_DIR, HOST).preflight(_cfg(), "native")
    refusal = [p for p in problems if p.startswith(f"Cannot {ACTION_FLEET_BUILD}")]
    assert refusal and "acme.example" in refusal[0] and FLEET_REMEDY in refusal[0]
    # EXACTLY the unwalked domain is named between the dash and the remedy — the
    # walked own domain is not. (The earlier form of this line sliced at the first
    # "." and so compared " acme" with "mesh.example": it could never fail.)
    named = refusal[0].split("— ", 1)[1].split(". ", 1)[0]
    assert named == "acme.example", refusal[0]


def test_a_fully_walked_fleet_and_a_legacy_record_pass():
    assert fleet_gate_reason(_cfg(reviewed=("mesh.example", "acme.example"))) == ""
    assert fleet_gate_reason(FleetConfig()) == ""          # no rows: every old record


def test_the_gate_survives_the_session_record_round_trip():
    """THE TRAP: asdict -> JSON -> from_dict. An un-rehydrated row is a dict, the gate
    reads getattr(d, "name", "") == "" off it, and every RESTART would pass."""
    back = FleetConfig.from_dict(json.loads(json.dumps(_cfg().to_dict())))
    assert all(isinstance(d, Domain) for d in back.domains)
    assert back == _cfg()
    assert "acme.example" in fleet_gate_reason(back)


def test_a_junk_row_fails_validation_closed():
    from hugmesh_studio.core.config import IdentityValidationError
    with pytest.raises(IdentityValidationError):
        FleetConfig(domains=[Domain(name="evil|inject")]).validate()


def test_mode_is_a_class_constant_not_a_field():
    assert FleetConfig.mode == "mesh"
    assert "mode" not in FleetConfig().to_dict()
    assert FleetConfig.from_dict({"mode": "standalone", "jobs": 3}).jobs == 3


def test_validate_refuses_unbalanced_quotes_and_a_jobs_count_out_of_range():
    """``extra_flags`` is shlex-split into argv, so an unbalanced quote used to raise a
    bare ValueError from ``to_cli_args`` — which the TUI's review did not catch (the
    post-merge review of #645: the whole text-mode fleet flow died on an apostrophe).
    Now ``validate`` refuses it as an IdentityValidationError, with the remedy, and
    ``-j`` is held to the GUI spin box's range on both faces."""
    from hugmesh_studio.core.config import IdentityValidationError
    from hugmesh_studio.core.fleet import JOBS_RANGE
    for flags in ("--note it's", '--note "abc'):
        with pytest.raises(IdentityValidationError, match="balance the quotes"):
            FleetConfig(extra_flags=flags).validate()
        with pytest.raises(IdentityValidationError):
            FleetConfig(extra_flags=flags).to_cli_args()
    assert FleetConfig(extra_flags='--note "it is"').to_cli_args() == ["--note", "it is"]
    assert JOBS_RANGE == (1, 128)
    for jobs in (0, -5, 129):
        with pytest.raises(IdentityValidationError, match="jobs must be"):
            FleetConfig(jobs=jobs).validate()
    FleetConfig(jobs=1).validate()
    FleetConfig(jobs=128).validate()
    # a hand-edited saved record with `"jobs": true` must not put `-j True` on the command
    # (bool is an int in Python, and 1 is inside the range)
    for bad in (True, False, 8.0, "8", None):
        with pytest.raises(IdentityValidationError, match="jobs must be"):
            FleetConfig(jobs=bad).validate()


# ── the steps' shared Qt-free logic ──────────────────────────────────────────────────
def test_row_zero_is_the_cluster_domain_or_the_builders_default_and_renames():
    st = FleetDomains()
    seed_fleet_domains(st, "")
    assert st.names() == [FLEET_DEFAULT_DOMAIN]
    st.domains.append(Domain(name="acme.example"))
    st.domain_services_reviewed = [FLEET_DEFAULT_DOMAIN, "acme.example"]
    seed_fleet_domains(st, "mesh.example")
    assert st.names() == ["mesh.example", "acme.example"]
    # a renamed own domain is one nobody walked under that name
    assert st.domain_services_reviewed == ["acme.example"]


def test_commit_refuses_junk_duplicate_and_own_again_but_records_anyway():
    st = FleetDomains()
    seed_fleet_domains(st, "mesh.example")
    problems = commit_fleet_domains(st, [Domain(name="Bad Name"),
                                         Domain(name="mesh.example"),
                                         Domain(name="a.example"),
                                         Domain(name="a.example")])
    assert len(problems) == 3
    assert [d.name for d in st.domains][0] == "mesh.example"
    assert len(st.domains) == 5                      # recorded, so Back keeps them


def test_restart_state_keeps_the_recorded_markers_not_every_row():
    st = fleet_domains_from_config(_cfg())
    assert st.own_name == "mesh.example"
    assert st.domain_services_reviewed == ["mesh.example"]


# ── the TUI face ─────────────────────────────────────────────────────────────────────
def _tui(lines):
    out = io.StringIO()
    tui_app.main(["--fleet", "--plain", "--generator-dir", GENERATOR_DIR],
                 inp=io.StringIO("\n".join(lines) + "\n"), out=out)
    return out.getvalue()


def test_the_tui_fleet_refuses_an_unwalked_domain_like_the_gui():
    text = _tui(["set cluster_domain mesh.example", "", "a acme.example", "", "", "q"])
    assert "Cannot build this fleet: 1 domain has no recorded service configuration " \
           "— acme.example." in text
    assert FLEET_LANE_NOTE in text


def test_the_tui_fleet_hands_over_the_command_once_every_domain_is_walked():
    text = _tui(["set cluster_domain mesh.example", "set x86_omnibus on", "",
                 "a acme.example", "", "n", "", "q"])
    assert "Cannot build this fleet" not in text.split("fleet-review>")[0].rsplit(
        "Fleet build", 1)[-1]
    assert ("X86_OMNIBUS=1 bash ./scripts/build-all-roles.sh" in text
            and "--cluster-domain mesh.example" in text)


def test_the_tui_fleet_refuses_a_junk_knob_value_and_keeps_the_old_one():
    j = journey.Journey(GENERATOR_DIR)
    j.goto("fleet")
    j.feed("set x86_roles pki;rm")
    assert j.status.startswith("refused:")
    assert j.screen().options(j).x86_roles == ""
    j.feed("set x86_omnibus maybe")
    assert "switch" in j.status


def test_the_tui_fleet_row_one_cannot_be_removed():
    j = journey.Journey(GENERATOR_DIR)
    j.goto("fleet")
    j.feed("")                                 # options -> domains
    j.feed("d 1")
    assert "cannot be removed" in j.status
    assert j.screen().state(j).names() == [FLEET_DEFAULT_DOMAIN]


def test_leaving_the_domains_step_keeps_the_own_rows_recorded_services():
    """``commit_fleet_domains`` rebuilds the rows from the table's ADDED rows and the
    own row — which must keep the services recorded for it on the services step (a
    Back to Domains and a Next again must not silently empty them; the post-merge
    review of #645 measured that this had no pin)."""
    from hugmesh_studio.core.fleet import commit_fleet_domains
    st = FleetDomains()
    seed_fleet_domains(st, "mesh.example")
    st.by_name("mesh.example").optional_services = ["akkoma", "games"]
    assert commit_fleet_domains(st, [Domain(name="acme.example", title="Acme")]) == []
    assert st.names() == ["mesh.example", "acme.example"]
    assert st.by_name("mesh.example").optional_services == ["akkoma", "games"]
    assert commit_fleet_domains(st, []) == []
    assert st.by_name("mesh.example").optional_services == ["akkoma", "games"]


def test_the_tui_fleet_survives_an_apostrophe_in_extra_flags():
    """The post-merge review of #645 (robustness M1): ``set extra_flags --note it's``
    then Enter to Review raised ValueError('No closing quotation') out of shlex and
    the plain face has no handler around feed(), so the whole TUI died with a
    traceback. Now the value is refused at ``set`` time with the reason, the old value
    is kept, and the walk goes on to Review."""
    text = _tui(["set extra_flags --note it's", "", "", "", "q"])
    assert "refused: extra_flags cannot be split into arguments" in text
    assert "balance the quotes" in text
    assert "fleet-review>" in text            # the walk went on: no traceback
    j = journey.Journey(GENERATOR_DIR)
    j.goto("fleet")
    j.feed('set extra_flags --note "abc')
    assert j.status.startswith("refused:") and j.screen().options(j).extra_flags == ""
    j.feed("set jobs -5")
    assert "jobs must be" in j.status and j.screen().options(j).jobs == 8
    j.feed("set jobs 0")
    assert "jobs must be" in j.status and j.screen().options(j).jobs == 8
    j.feed("set jobs 128")
    assert j.screen().options(j).jobs == 128


def test_the_tui_domains_stage_refuses_junk_a_duplicate_and_the_own_domain_again():
    """The TUI's ``a NAME`` refuses at entry what the GUI table refuses on Next — with
    the same words as the shared ``added_row_problems`` (the post-merge review's M4:
    these refusals existed and nothing pinned them)."""
    j = journey.Journey(GENERATOR_DIR)
    j.goto("fleet")
    j.feed("set cluster_domain mesh.example")
    j.feed("")                                 # options -> domains
    st = j.screen().state(j)
    j.feed("a Not A Domain")
    assert j.status.startswith("not a domain name: 'Not A Domain'")
    assert st.names() == ["mesh.example"]
    j.feed("a acme.example")
    assert st.names() == ["mesh.example", "acme.example"]
    j.feed("a acme.example")
    assert j.status == "already listed: acme.example"
    j.feed("a mesh.example")
    assert j.status.startswith("mesh.example is this fleet's own domain (row 1)")
    assert st.names() == ["mesh.example", "acme.example"]


def test_the_tui_enter_refuses_a_row_that_a_rename_made_the_own_domain_again():
    """The one way a TUI row can be refused at Enter (entry already refuses junk and
    duplicates): rename the fleet's own domain, on the options stage, to a name that is
    an added row. Seeding renames row 1 and Enter then refuses the twin — the stage
    stays ``domains`` and the status says why — until the row is deleted."""
    j = journey.Journey(GENERATOR_DIR)
    j.goto("fleet")
    j.feed("set cluster_domain mesh.example")
    j.feed("")
    j.feed("a acme.example")
    j.feed("b")                                # back to the options
    j.feed("set cluster_domain acme.example")
    j.feed("")                                 # -> domains: row 1 renamed
    st = j.screen().state(j)
    assert st.names() == ["acme.example", "acme.example"]
    j.feed("")                                 # Enter: refused
    assert j.screen().stage == "domains"
    assert "acme.example is this mesh's own domain (row 0)" in j.status
    assert "Fix or remove these rows to continue." in j.status
    j.feed("d 2")
    assert st.names() == ["acme.example"]
    j.feed("")
    assert j.screen().stage == "services"


def test_the_tui_delete_prunes_the_deleted_rows_reviewed_marker():
    """A row walked on the services step and then deleted must not leave its marker
    behind (a stranded marker is what lets a re-added domain pass the gate unwalked)."""
    j = journey.Journey(GENERATOR_DIR)
    j.goto("fleet")
    j.feed("set cluster_domain mesh.example")
    j.feed("")
    j.feed("a acme.example")
    j.feed("")                                 # -> services: the own domain, marked
    j.feed("n")                                # acme's page: marked
    st = j.screen().state(j)
    assert st.domain_services_reviewed == ["mesh.example", "acme.example"]
    j.feed("b")                                # back to Domains
    assert j.screen().stage == "domains"
    j.feed("d 2")
    assert j.status == "removed acme.example"
    assert st.names() == ["mesh.example"]
    assert st.domain_services_reviewed == ["mesh.example"]


# ── a damaged record is refused at LOAD, with the field named (post-merge review of
#    #645: hand-edited JSON used to pass from_dict and die later as a TypeError from
#    dataclasses.asdict or an AttributeError in the gate, inside the RESTART slot) ────
@pytest.mark.parametrize("damage, field", [
    ({"domains": "junk"}, "domains must be a list"),
    ({"domains": {"name": "mesh.example"}}, "domains must be a list"),
    ({"domains": ["junk"]}, "domains[0] must be a domain row"),
    ({"domains": [5]}, "domains[0] must be a domain row"),
    ({"domains": [{"name": "mesh.example"}, 7]}, "domains[1] must be a domain row"),
    ({"domains": [{"name": 7}]}, "domains[0].name must be text"),
    ({"domains": [{"name": "mesh.example"}], "domain_services_reviewed": "abc"},
     "domain_services_reviewed must be a list"),
])
def test_a_damaged_fleet_record_is_refused_at_load_naming_the_field(damage, field):
    from hugmesh_studio.core.config import IdentityValidationError
    record = dict(_cfg().to_dict()); record.update(damage)
    with pytest.raises(IdentityValidationError) as ei:
        FleetConfig.from_dict(record)
    assert field in str(ei.value), str(ei.value)
    # and the non-object record the loaders could meet (a top-level JSON array)
    with pytest.raises(IdentityValidationError, match="must be a JSON object"):
        FleetConfig.from_dict(["not", "a", "record"])


def test_an_undamaged_record_with_absent_or_null_rows_still_loads():
    """The lenient cases stay lenient: a pre-#645 record has no domains keys at all,
    and ``null`` for either is what an old serialiser wrote — both are an empty list,
    not a refusal (the legacy-record RESTART path, pinned above as passing the gate)."""
    assert FleetConfig.from_dict({"jobs": 3}).domains == []
    back = FleetConfig.from_dict({"domains": None, "domain_services_reviewed": None})
    assert back.domains == [] and back.domain_services_reviewed == []


def test_fleet_domain_fields_hands_out_copies_of_the_rows():
    """The docstring's promise: the recorded config keeps COPIES, so editing the step
    state after a Back (the live rows) cannot rewrite a record already made."""
    from hugmesh_studio.core.fleet import fleet_domain_fields
    st = FleetDomains()
    seed_fleet_domains(st, "mesh.example")
    st.domains.append(Domain(name="acme.example", optional_services=["akkoma"]))
    fields_ = fleet_domain_fields(st)
    assert fields_["domains"] == st.domains
    assert all(a is not b for a, b in zip(fields_["domains"], st.domains))
    fields_["domains"][1].optional_services.append("games")
    fields_["domains"][0].name = "renamed.example"
    assert st.by_name("acme.example").optional_services == ["akkoma"]
    assert st.names() == ["mesh.example", "acme.example"]


# ── the GUI face ─────────────────────────────────────────────────────────────────────
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.gui.pages import fleet as fleet_mod                  # noqa: E402
from hugmesh_studio.gui.pages.domains import _COL_IDP                    # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                              # noqa: E402


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-fleet-domain-tests"]))


@pytest.fixture
def page(qapp, monkeypatch):
    monkeypatch.setattr("hugmesh_studio.core.build_driver.detect",
                        lambda builder_image="hugmesh-builder": HOST)
    p = fleet_mod.FleetPage(GENERATOR_DIR)
    p.driver = FleetDriver(GENERATOR_DIR, HOST)
    p.driver._image_present = lambda: True
    runs = []
    p.driver.run = lambda *a, **k: runs.append(a) or 0
    p.runs = runs
    yield p
    p.deleteLater()


def _to_domains(page, cluster_domain="mesh.example"):
    page.cluster_domain.setText(cluster_domain)
    while page.stack.currentIndex() < fleet_mod.STEP_DOMAINS:
        page.next_btn.click()
    return page


def test_the_domains_step_row_zero_and_no_sign_in_column(page):
    _to_domains(page)
    assert page.stack.currentIndex() == fleet_mod.STEP_DOMAINS
    assert page.domains_table.own_row_name() == "mesh.example"
    assert page.domains_table.table.isColumnHidden(_COL_IDP)


def test_an_unwalked_domain_is_refused_before_build_all_roles_runs(page):
    _to_domains(page)
    page.domains_table._add("acme.example", "Acme")
    page.next_btn.click()                                   # -> Domain services
    assert page.stack.currentIndex() == fleet_mod.STEP_DOMAIN_SERVICES
    assert page.domain_services.current_domain() == "mesh.example"
    page.next_btn.click()                                   # -> Review
    assert page.stack.currentIndex() == fleet_mod.STEP_REVIEW
    assert "acme.example" in page.problems.toPlainText()
    page.next_btn.click()                                   # "Build fleet now"
    assert page.stack.currentIndex() == fleet_mod.STEP_REVIEW
    assert "Preflight FAILED" in page.problems.toPlainText()
    assert "acme.example" in page.problems.toPlainText()
    assert page.runs == [] and page.worker is None


def test_walking_every_domain_clears_the_gate(page):
    _to_domains(page)
    page.domains_table._add("acme.example", "Acme")
    page.next_btn.click()
    page.domain_services._step(+1)                          # "Next domain" — acme
    page.next_btn.click()
    cfg = page.collect()
    assert [d.name for d in cfg.domains] == ["mesh.example", "acme.example"]
    assert set(cfg.domain_services_reviewed) == {"mesh.example", "acme.example"}
    assert fleet_gate_reason(cfg) == ""


def test_a_junk_row_keeps_the_operator_on_the_domains_step_inline(page):
    _to_domains(page)
    page.domains_table._add("Not A Domain", "")
    page.next_btn.click()
    assert page.stack.currentIndex() == fleet_mod.STEP_DOMAINS
    assert not page.domains_note.isHidden()
    assert "not a domain name" in page.domains_note.text()


def test_a_restart_of_an_incompletely_walked_record_is_refused_at_review(page, tmp_path):
    s = bs.new_fleet_session(_cfg(output_dir=str(tmp_path / "out")), GENERATOR_DIR,
                             backend="native")
    bs.save(s)
    # through the DISK record — the JSON round trip a real RESTART takes
    loaded = next(r for r in bs.load_all() if r.id == s.id)
    assert isinstance(loaded.config["domains"][0], dict)
    page.load_from_session(loaded, pin=True)
    assert page.stack.currentIndex() == fleet_mod.STEP_REVIEW
    assert "acme.example" in page.problems.toPlainText()
    page.next_btn.click()
    assert page.runs == [] and page.worker is None


def test_with_tor_and_optional_services_survive_apply_and_collect(page):
    page.apply(FleetConfig(with_tor=True, optional_services="akkoma tuwunel"))
    cfg = page.collect()
    assert cfg.with_tor is True and cfg.optional_services == "akkoma tuwunel"
    assert cfg.to_env()["WITH_TOR"] == "1"


def test_the_services_step_says_what_the_fleet_does_with_the_rows(page):
    _to_domains(page)
    page.next_btn.click()
    assert page.domain_services.lane_note.text() == FLEET_LANE_NOTE
    assert not page.domain_services.lane_note.isHidden()


def test_back_from_the_domains_step_records_a_typed_row(page):
    """Back records too (never refuses): a row typed on Domains must reach the state
    whichever way the operator leaves, and be in the table when they come back."""
    _to_domains(page)
    page.domains_table._add("acme.example", "Acme")
    page.back_btn.click()
    assert page.stack.currentIndex() == fleet_mod.STEP_SHARED
    assert page.fleet_domains.names() == ["mesh.example", "acme.example"]
    page.next_btn.click()
    assert page.stack.currentIndex() == fleet_mod.STEP_DOMAINS
    assert page.domains_table.table.rowCount() == 2


def test_removing_a_walked_domain_on_the_gui_prunes_its_marker(page):
    """Leaving the Domains step rebuilds the reviewed markers from the rows that still
    exist (``commit_fleet_domains``): a domain walked, then removed, leaves nothing
    behind. Measured through Back, which records without loading the services step
    (whose own load would hide the prune this pins)."""
    _to_domains(page)
    page.domains_table._add("acme.example", "Acme")
    page.next_btn.click()                                   # -> Domain services (own)
    page.domain_services._step(+1)                          # acme's page: walked
    page.back_btn.click()                                   # -> Domains, walk recorded
    assert set(page.fleet_domains.domain_services_reviewed) == {"mesh.example",
                                                                "acme.example"}
    page.domains_table.table.selectRow(1)
    page.domains_table._remove()
    assert page.domains_table.table.rowCount() == 1
    page.back_btn.click()                                   # records the removal
    assert page.fleet_domains.names() == ["mesh.example"]
    assert page.fleet_domains.domain_services_reviewed == ["mesh.example"]
    assert page.collect().domain_services_reviewed == ["mesh.example"]


def test_the_gui_shows_an_unbalanced_quote_inline_and_refuses_to_build(page):
    """The GUI twin of the TUI apostrophe case: the Review preview says INVALID with
    the remedy, inline, and "Build fleet now" refuses without reaching the driver."""
    page.extra_flags.setText("--note it's")
    _to_domains(page)
    page.next_btn.click()                                   # -> Domain services
    page.next_btn.click()                                   # -> Review
    assert page.stack.currentIndex() == fleet_mod.STEP_REVIEW
    assert page.cmd.toPlainText().startswith("INVALID: extra_flags cannot be split")
    assert "balance the quotes" in page.cmd.toPlainText()
    page.next_btn.click()                                   # "Build fleet now"
    assert page.stack.currentIndex() == fleet_mod.STEP_REVIEW
    assert "Preflight FAILED" in page.problems.toPlainText()
    assert "balance the quotes" in page.problems.toPlainText()
    assert page.runs == [] and page.worker is None


def test_the_gui_jobs_spin_box_is_bounded_by_the_same_range_validate_enforces(page):
    """One range on both faces: the spin box's bounds ARE ``JOBS_RANGE`` (what
    ``FleetConfig.validate`` refuses outside of, for the TUI's ``set jobs N``), not a
    second literal that could drift from it (the round-2 review's L8: decoupling the
    spin box to (0, 256) stayed green)."""
    from hugmesh_studio.core.fleet import JOBS_RANGE
    assert (page.jobs.minimum(), page.jobs.maximum()) == JOBS_RANGE
    page.jobs.setValue(JOBS_RANGE[1] + 100)
    assert page.jobs.value() == JOBS_RANGE[1]
    page.jobs.setValue(0)
    assert page.jobs.value() == JOBS_RANGE[0]
    page.collect().validate()                               # what it clamps to is valid


class _DamagedSession:
    """What the Sessions page hands RESTART / REDO: a record whose saved config was
    hand-edited into a shape FleetConfig.from_dict refuses."""
    def __init__(self, config):
        self.id = "fleet-damaged-1"
        self.backend = "native"
        self.config = config


@pytest.mark.parametrize("pin", [True, False])
def test_restarting_a_damaged_record_shows_the_refusal_inline_and_pins_nothing(page, pin):
    """RESTART (pin) and REDO of a damaged record: no exception leaves the slot (PyQt6
    would abort the Studio), the Review step's preflight pane names the record and the
    field, nothing is applied and no record id is pinned — ‘Build fleet now’ would
    build what the window already had, never the damaged record."""
    page.cluster_domain.setText("keep.example")
    page.load_from_session(_DamagedSession({"cluster_domain": "evil.example",
                                            "domains": ["junk"]}), pin=pin)
    assert page.stack.currentIndex() == fleet_mod.STEP_REVIEW
    text = page.problems.toPlainText()
    assert "Cannot restart fleet record fleet-damaged-1" in text
    assert "domains[0] must be a domain row" in text
    # the damaged record's id is NOT pinned: Review minted its own fresh id for the
    # window's own config (the normal lazy mint), so a Build there never reuses the
    # damaged record's workdir
    assert page.pending_session_id and page.pending_session_id != "fleet-damaged-1"
    assert page.cluster_domain.text() == "keep.example"
    assert page.runs == [] and page.worker is None
