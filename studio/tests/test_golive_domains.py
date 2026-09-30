"""#587 (Go-Live part) — Go-Live reads the domains baked on the device and offers the
exposure per domain; the single Public domain field stays the default. GUI + TUI
(operator decision 71 = A), one Qt-free source (``core.golive_domains``).

Pinned here:

* what "baked" means is measured on the builder: /etc/hugmesh/domains is written only
  on a CLIENT role, so on a node the list is the cluster domain alone and the page
  says so rather than inventing domains;
* the picker offers the baked list, cluster domain first, junk lines never reach
  ``--domain``; picking fills the field, the field stays editable and the default;
* the plan names EVERY domain's exposure — this run's, the ones that need a run of
  their own, the onion case (no clearnet domain at all) — plus the node's onions,
  per-domain slugs included, and refuses malformed onion files;
* the GUI's Generate step and the TUI's plan render the SAME lines.
"""
import io
import os
import re

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core.golive_domains import (                        # noqa: E402
    NO_EXTRA_DOMAINS_NOTE, baked_domains, exposure_lines, exposure_rows, onion_exports,
    plan_rows)
from hugmesh_studio.core.golive_driver import GoLiveDriver, GoLiveOptions  # noqa: E402
from hugmesh_studio.tui import app as tui_app                           # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

ONION_A = "a" * 56 + ".onion"
ONION_B = "b" * 56 + ".onion"


@pytest.fixture
def device(tmp_path, monkeypatch):
    """A fake device: a baked cluster domain, a baked domain list with junk in it, the
    node's primary onion, one per-domain onion, and one malformed export."""
    (tmp_path / "cluster-domain").write_text("mesh.example\n")
    (tmp_path / "domains").write_text(
        "mesh.example\nshop.example\n# a comment\n\nBad Name\nevil;rm\nSHOP.example\n")
    tor = tmp_path / "tor"
    tor.mkdir()
    (tor / "hostname").write_text(ONION_A + "\n")
    (tor / "games.hostname").write_text(ONION_B + "\n")
    (tor / "Bad_Slug.hostname").write_text(ONION_B + "\n")
    (tor / "half.hostname").write_text("not-an-onion\n")
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(tmp_path / "cluster-domain"))
    monkeypatch.setenv("GOLIVE_DOMAINS_FILE", str(tmp_path / "domains"))
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(tor))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    return tmp_path


@pytest.fixture
def bare_node(tmp_path, monkeypatch):
    """A node as the builders really bake it: cluster domain only, no onion."""
    (tmp_path / "cluster-domain").write_text("mesh.example\n")
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(tmp_path / "cluster-domain"))
    monkeypatch.setenv("GOLIVE_DOMAINS_FILE", str(tmp_path / "absent"))
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(tmp_path / "absent-tor"))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    return tmp_path


# ── what is baked, measured on the builder ───────────────────────────────────────────
def test_the_domain_list_is_baked_only_on_a_client_role():
    with open(os.path.join(GENERATOR_DIR, "build-x86-host-stage4.sh"),
              encoding="utf-8", errors="replace") as fh:
        src = fh.read()
    write = src.index('> "${SYSROOT}/etc/hugmesh/domains"')
    assert src.count('> "${SYSROOT}/etc/hugmesh/domains"') == 1
    arm = src.rfind("\nelif ${ROLE_CLIENT}; then", 0, write)
    body = src[src.index("\n", arm + 1) + 1:write]      # after the arm's own line
    assert arm != -1 and not re.search(r"^(fi|elif|else)\b", body, re.M), (
        "/etc/hugmesh/domains is no longer written only inside the CLIENT arm — a node "
        "may now carry it, and NO_EXTRA_DOMAINS_NOTE's 'baked only into client images' "
        "must be re-said")
    assert "baked only into client images" in NO_EXTRA_DOMAINS_NOTE


# ── core ─────────────────────────────────────────────────────────────────────────────
def test_baked_domains_cluster_first_deduped_junk_skipped(device):
    assert baked_domains("mesh.example") == ["mesh.example", "shop.example"]


def test_a_bare_node_offers_the_cluster_domain_alone(bare_node):
    assert baked_domains("mesh.example") == ["mesh.example"]


def test_onion_exports_keep_only_well_formed_addresses_and_slugs(device):
    primary, per = onion_exports()
    assert primary == ONION_A
    assert per == [("games", ONION_B)]


def test_the_plan_names_every_domains_exposure():
    rows = dict(exposure_rows(["mesh.example", "shop.example"], "shop.example",
                              "cloudflare-tunnel", "deeplink", "tunnel (deeplink)",
                              ONION_A, [("games", ONION_B)]))
    assert rows["shop.example"] == "tunnel (deeplink) via cloudflare-tunnel — THIS run"
    assert rows["mesh.example (cluster domain)"].startswith("not exposed by this run")
    assert rows["Tor: this node's onion"].startswith(f"https://{ONION_A}/")
    assert rows["Tor: domain slug 'games'"].startswith(f"https://{ONION_B}/")


def test_the_onion_mechanism_exposes_no_clearnet_domain():
    rows = exposure_rows(["mesh.example", "shop.example"], "mesh.example",
                         "tor-onion", "onion", "onion (onion)")
    assert all("no clearnet exposure" in how for w, how in rows if not w.startswith("Tor"))
    assert ("Tor: this node's onion", rows[-1][1]) == rows[-1]
    assert "not minted on this host" in rows[-1][1]


def test_a_typed_domain_that_is_not_baked_is_still_named():
    rows = dict(exposure_rows(["mesh.example"], "other.example", "byo-domain", "files",
                              "public-dns (files)"))
    assert rows["other.example (typed — not baked on this device)"].endswith("THIS run")


# ── the GUI face ─────────────────────────────────────────────────────────────────────
def _tui_plan(provider_no, domain_cmds):
    out = io.StringIO()
    tui_app.main(["--go-live", "--plain", "--generator-dir", GENERATOR_DIR],
                 inp=io.StringIO("\n".join([str(provider_no), *domain_cmds, "", "q"])
                                 + "\n"), out=out)
    return out.getvalue()


def test_the_tui_plan_prints_the_shared_lines(device):
    d = GoLiveDriver(GENERATOR_DIR)
    ids = [p.id for p in d.providers()]
    n = ids.index("cloudflare-tunnel") + 1
    text = _tui_plan(n, ["2"])
    want = exposure_lines(plan_rows(d, GoLiveOptions(provider="cloudflare-tunnel",
                                                     domain="shop.example")))
    for line in want:
        assert "  " + line in text
    assert "--domain shop.example" in text


def test_the_tui_says_a_bare_node_has_one_domain(bare_node):
    text = _tui_plan(1, [])
    assert NO_EXTRA_DOMAINS_NOTE in text


pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.gui.pages import golive as golive_mod                # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                              # noqa: E402


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-golive-domain-tests"]))


@pytest.fixture
def wiz(qapp):
    w = golive_mod.GoLiveWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _to_inputs(wiz, provider="cloudflare-tunnel"):
    wiz.model = wiz.driver.provider(provider).model
    wiz.opts.provider = provider
    page = wiz.page(wiz._page_ids["inputs"])
    page.initializePage()
    return page


def test_the_inputs_picker_offers_the_baked_domains_and_fills_the_field(wiz, device):
    page = _to_inputs(wiz)
    data = [page.domain_pick.itemData(i) for i in range(page.domain_pick.count())]
    assert data == ["mesh.example", "shop.example"]
    assert page.domain.text() == "mesh.example"               # the default, as before
    assert page.domain_pick.isEnabled() and page.domain_list_note.text() == ""
    page.domain_pick.setCurrentIndex(1)
    assert page.domain.text() == "shop.example"
    page.domain.setText("typed.example")                      # still editable
    assert page.validatePage() and wiz.opts.domain == "typed.example"


def test_a_bare_node_picker_is_the_cluster_domain_and_says_why(wiz, bare_node):
    page = _to_inputs(wiz)
    assert page.domain_pick.count() == 1
    assert not page.domain_pick.isEnabled()
    assert page.domain_list_note.text() == NO_EXTRA_DOMAINS_NOTE


def test_the_generate_step_shows_the_same_lines_as_the_tui(wiz, device):
    page = _to_inputs(wiz)
    page.domain_pick.setCurrentIndex(1)
    assert page.validatePage()
    gen = wiz.page(wiz._page_ids["generate"])
    gen.initializePage()
    want = exposure_lines(plan_rows(wiz.driver, wiz.opts))
    assert gen.exposure.toPlainText().splitlines() == want
    assert any("shop.example" in ln and "THIS run" in ln for ln in want)
    assert any("mesh.example" in ln and "not exposed by this run" in ln for ln in want)
