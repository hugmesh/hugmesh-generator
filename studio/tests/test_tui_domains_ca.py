"""tui — the domains step's per-domain Base CA choice (issue #335's TUI surface).

Headless and Qt-free. The schema (``cfg.base_ca_certs`` / ``cfg.domain_ca`` and the
rule that a domain may not name a certificate the config does not carry) belongs to
core/config.py and is pinned by test_vault_config.py; HERE the pins are that the TUI
step reads and writes it faithfully and refuses exactly what the GUI refuses:

* the Base CA column shows in mesh and hides in cloud, like Sign-in;
* an untouched row writes NO key, so a walk that never touched the column leaves
  ``cfg.domain_ca`` the empty dict the native default already is;
* 'b' takes ROW NUMBERS off the two tables in front of the operator, never a typed
  path — a path could name a certificate the config does not carry, which is exactly
  the state the shared rule refuses;
* the wizard-order wrinkle is surfaced, not hidden: this step runs BEFORE the Secrets
  store, so with no certificates yet the step says where to add them.
"""
import pytest

from ca_fixtures import CA_ALT, CA_ROOT
from hugmesh_studio.core.config import Domain
from hugmesh_studio.tui import domains_step, journey


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _at_mesh_domains(certs=()) -> journey.Journey:
    j = journey.Journey(".")
    for line in ("", "3", "", "1", "", "", "", ""):
        j.feed(line)
    assert j.slug == "domains_choice"
    j.feed("y")
    assert j.slug == "domains"
    j.cfg.base_ca_certs = list(certs)
    return j


# ── the column ───────────────────────────────────────────────────────────────────────
def test_mesh_table_carries_the_base_ca_column():
    j = _at_mesh_domains([CA_ROOT])
    j.feed("a chat.example.org")
    headers, rows = domains_step.domain_table(j.cfg)
    assert "base CA" in headers
    assert rows[0][headers.index("base CA")] == "none"      # the default
    text = "\n".join(j.lines())
    assert "b NUMBER CERT|-=set its base CA" in text
    assert "1=ca-root.pem" in text                          # the offered vocabulary


def test_cloud_hides_the_base_ca_column():
    j = journey.Journey(".")
    j.cfg.mode = "cloud"
    j.cfg.base_ca_certs = [CA_ROOT]
    j.cfg.domains = [Domain(name="chat.example.org")]
    headers, _rows = domains_step.domain_table(j.cfg)
    assert "base CA" not in headers and "sign-in" not in headers


def test_with_no_certificates_the_step_says_where_to_add_them():
    """WIZARD/PAGE order puts domains BEFORE the secrets store, so on a first forward
    pass the list really is empty. Say so rather than offer an empty vocabulary."""
    j = _at_mesh_domains()
    j.feed("a chat.example.org")
    text = "\n".join(j.lines())
    assert "No certificates yet" in text and "Secrets store step" in text
    j.feed("b 1 1")
    assert "no base CA certificates yet" in j.status
    assert j.cfg.domain_ca == {}


# ── the choice ───────────────────────────────────────────────────────────────────────
def test_choosing_a_certificate_by_row_number_persists():
    j = _at_mesh_domains([CA_ROOT, CA_ALT])
    j.feed("a chat.example.org")
    j.feed("a shop.example.org")
    before = j.cfg.to_cli_args()
    j.feed("b 2 2")
    assert j.cfg.domain_ca == {"shop.example.org": CA_ALT}
    assert "shop.example.org: base CA -> ca-alt.pem" in j.status
    headers, rows = domains_step.domain_table(j.cfg)
    assert rows[1][headers.index("base CA")] == "ca-alt.pem"
    assert rows[0][headers.index("base CA")] == "none"
    assert j.cfg.to_cli_args() == before                    # emits nothing
    j.cfg.validate_identity()


def test_clearing_a_choice_deletes_the_key_rather_than_blanking_it():
    """"absent" and "" are the same fact, and only one of them round-trips as the
    native default — so a cleared choice must remove the key, not store an empty."""
    j = _at_mesh_domains([CA_ROOT])
    j.feed("a chat.example.org")
    j.feed("b 1 1")
    assert j.cfg.domain_ca == {"chat.example.org": CA_ROOT}
    j.feed("b 1 -")
    assert j.cfg.domain_ca == {}
    assert "base CA -> none" in j.status


def test_an_untouched_walk_writes_no_key_at_all():
    j = _at_mesh_domains([CA_ROOT])
    j.feed("a chat.example.org")
    before = j.cfg.to_cli_args()
    j.feed("")                                              # continue, untouched
    assert j.cfg.domain_ca == {}
    assert j.cfg.to_cli_args() == before


# ── refusals ─────────────────────────────────────────────────────────────────────────
def test_bad_operands_are_inline_refusals_that_change_nothing():
    j = _at_mesh_domains([CA_ROOT])
    j.feed("a chat.example.org")
    j.feed("b 9 1")
    assert "no such domain row" in j.status and j.cfg.domain_ca == {}
    j.feed("b 1 9")
    assert "no such certificate" in j.status and j.cfg.domain_ca == {}
    j.feed("b 1")
    assert "needs a certificate number" in j.status and j.cfg.domain_ca == {}
    j.feed("b nope 1")
    assert "no such domain row" in j.status


def test_a_path_is_not_an_accepted_operand():
    """Row numbers only. A typed path could name a certificate cfg does not carry —
    exactly the half-configured state the shared rule refuses at emission."""
    j = _at_mesh_domains([CA_ROOT])
    j.feed("a chat.example.org")
    j.feed(f"b 1 {CA_ROOT}")
    assert "no such certificate" in j.status and j.cfg.domain_ca == {}


def test_the_command_is_mesh_only():
    j = journey.Journey(".")
    j.cfg.mode = "cloud"
    j.cfg.base_ca_certs = [CA_ROOT]
    j.cfg.domains = [Domain(name="chat.example.org")]
    j.goto("domains")
    j.feed("b 1 1")
    assert "unrecognised command" in j.status and j.cfg.domain_ca == {}
