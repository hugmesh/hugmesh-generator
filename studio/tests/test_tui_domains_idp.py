"""tui — the domains step's per-domain Sign-in choice (#71's TUI surface).

Headless and Qt-free. The schema (Domain.idp, omit-when-default manifests) is
core/config.py's and already pinned by test_domain_idp_schema.py — HERE the pins
are that the TUI step reads/writes it faithfully: superdomain default, the
toggle persists, cloud hides the column, manifests stay byte-honest.
"""
import pytest

from hugmesh_studio.core.config import (
    DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, Domain,
)
from hugmesh_studio.tui import domains_step, journey


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


# ── the Sign-in column: mesh shows it, cloud hides it ───────────────────────────────
def test_labels_cover_exactly_the_schema_choices():
    assert set(domains_step.IDP_LABELS) == {DOMAIN_IDP_SUPERDOMAIN, DOMAIN_IDP_OWN}
    assert "default" in domains_step.IDP_LABELS[DOMAIN_IDP_SUPERDOMAIN].lower()


def test_mesh_table_carries_the_sign_in_column():
    j = _at_mesh_domains()
    j.feed("a chat.example.org")
    headers, rows = domains_step.domain_table(j.cfg)
    assert headers[-1] == "sign-in"
    assert rows[0][-1] == "Superdomain Casdoor (default)"
    text = "\n".join(j.lines())
    assert "toggle its sign-in" in text


def test_cloud_table_hides_the_sign_in_column():
    # a client hosts no Casdoor and writes no manifest — the GUI hides the
    # column in cloud mode and so does the TUI table/command set.
    j = journey.Journey(".")
    j.cfg.mode = "cloud"
    j.cfg.domains = [Domain(name="chat.example.org")]
    headers, rows = domains_step.domain_table(j.cfg)
    assert "sign-in" not in headers
    j.goto("domains")
    text = "\n".join(j.lines())
    assert "toggle its sign-in" not in text
    # ... and the toggle command is refused rather than silently applied
    j.feed("s 1")
    assert "unrecognised" in j.status
    assert j.cfg.domains[0].idp == DOMAIN_IDP_SUPERDOMAIN


# ── an added row defaults to superdomain; untouched rows emit no manifest key ──────
def test_added_domain_defaults_to_superdomain_and_emits_no_idp_key():
    j = _at_mesh_domains()
    j.feed("a chat.example.org")
    d = j.cfg.domains[0]
    assert d.idp == DOMAIN_IDP_SUPERDOMAIN
    manifest = j.cfg.mesh_manifest()
    (row,) = [m for m in manifest["domains"]
              if m.get("name") == "chat.example.org"]
    assert "idp" not in row              # omit-when-default: pre-#47 bytes hold


def test_toggle_persists_own_into_config_and_manifest():
    j = _at_mesh_domains()
    j.feed("a chat.example.org")
    j.feed("s 1")
    assert j.cfg.domains[0].idp == DOMAIN_IDP_OWN
    assert j.cfg.own_idp_domains() == ("chat.example.org",)
    (row,) = [m for m in j.cfg.mesh_manifest()["domains"]
              if m.get("name") == "chat.example.org"]
    assert row["idp"] == DOMAIN_IDP_OWN
    assert "Own Casdoor" in j.status     # the toggle names what it did


def test_toggle_back_returns_to_the_default():
    j = _at_mesh_domains()
    j.feed("a chat.example.org")
    j.feed("s 1")
    j.feed("s 1")
    assert j.cfg.domains[0].idp == DOMAIN_IDP_SUPERDOMAIN
    assert j.cfg.own_idp_domains() == ()


def test_a_loaded_own_row_renders_own_in_the_table():
    j = journey.Journey(".")
    j.cfg.mode = "mesh"
    j.cfg.domains = [Domain(name="chat.example.org", idp=DOMAIN_IDP_OWN)]
    _headers, rows = domains_step.domain_table(j.cfg)
    assert rows[0][-1] == "Own Casdoor"


# ── row management basics ───────────────────────────────────────────────────────────
def test_add_validates_the_name_and_refuses_duplicates():
    j = _at_mesh_domains()
    j.feed("a NOT a domain")
    assert "not a domain name" in j.status and j.cfg.domains == []
    j.feed("a chat.example.org")
    j.feed("a chat.example.org")
    assert "already listed" in j.status and len(j.cfg.domains) == 1


def test_delete_removes_the_row():
    j = _at_mesh_domains()
    j.feed("a chat.example.org")
    j.feed("d 1")
    assert j.cfg.domains == []
    j.feed("d 5")
    assert "no such domain row" in j.status


def test_enter_continues_to_the_users_choice():
    j = _at_mesh_domains()
    j.feed("a chat.example.org")
    j.feed("")
    assert j.slug == "users_choice"
