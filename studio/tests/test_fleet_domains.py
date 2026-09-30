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
    assert "mesh.example" not in refusal[0].split("—")[1].split(".")[0]


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
