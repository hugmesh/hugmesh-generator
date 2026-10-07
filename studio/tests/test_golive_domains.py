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
* the GUI's Generate step and the TUI's plan render the SAME lines;
* (the post-merge review of #645) an export directory this user CANNOT READ is told
  apart from an absent one — the plan says so instead of "not minted" — and
  GL_ONION_HOSTNAME overrides the exported address as the driver's own card does;
  a set-but-MALFORMED override is a row of its own (the card would write it to
  onion.txt as-is; the table must not call that "not minted");
* (round 2 of that review) a refused LISTING of the export is a row of its own, beside
  a known primary too: the per-domain onions are found only by listing, and a 0700
  export with GL_ONION_HOSTNAME set — what the unreadable row's remedy tells the
  operator to do — used to show the primary and drop the per-domain onions in silence;
* the Generate pane fits its rows (no row behind a scrollbar at the wizard's default
  size) and grows with the window.
"""
import io
import os
import re

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core.golive_domains import (                        # noqa: E402
    NO_EXTRA_DOMAINS_NOTE, ONION_LIST_UNREADABLE_HOW, ONION_OVERRIDE_PROBLEM_HOW,
    ONION_UNREADABLE_HOW, baked_domains, exposure_lines, exposure_rows,
    onion_export_state, onion_exports, onion_override_problem, plan_rows)
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


# ── unreadable is not absent (the post-merge review of #645) ──────────────────────────
class _Deny:
    """Make ``paths`` refuse this process the way a 0700 root-only export refuses a
    user: with the REAL mode bits when the runner is not root, and with a
    PermissionError raised from ``open``/``os.listdir`` for exactly those paths when
    it is (root reads a mode-0 directory, so the bits alone would prove nothing
    there — the pin must not quietly shrink under a root runner)."""

    def __init__(self, *paths):
        self.paths = {str(p) for p in paths}
        self.restore = []
        self.patched = None
        if os.geteuid() != 0:
            for p in paths:
                self.restore.append((p, p.stat().st_mode & 0o777))
                p.chmod(0)
            return
        import builtins
        real_open, real_listdir = builtins.open, os.listdir
        hit = self.paths

        def _blocked(path):
            path = str(path)
            return path in hit or any(path.startswith(h + os.sep) for h in hit)

        def fake_open(file, *a, **k):
            if _blocked(file):
                raise PermissionError(13, "Permission denied", str(file))
            return real_open(file, *a, **k)

        def fake_listdir(path="."):
            if _blocked(path):
                raise PermissionError(13, "Permission denied", str(path))
            return real_listdir(path)
        builtins.open, os.listdir = fake_open, fake_listdir
        self.patched = (builtins, real_open, real_listdir)

    def undo(self):
        for p, mode in self.restore:
            p.chmod(mode)
        if self.patched:
            builtins, real_open, real_listdir = self.patched
            builtins.open, os.listdir = real_open, real_listdir
            self.patched = None


def test_an_unreadable_export_directory_is_told_apart_from_an_absent_one(device):
    """hugmesh-tor-reconcile keeps /var/lib/hugmesh/tor root-only (chmod 0700), so a
    Studio run as a user on a Tor node cannot read it — the NORMAL state there. It used
    to collapse into ("", []) and the plan then said "not minted on this host" about a
    node that had minted it. Three shapes: a mode-0 directory, a readable directory
    with a root-only hostname file, and an export path that is a file."""
    tor = device / "tor"
    assert onion_export_state(str(tor)) == (ONION_A, [("games", ONION_B)], "", "")
    assert onion_export_state(str(device / "absent-tor")) == ("", [], "", "")
    deny = _Deny(tor)
    try:
        primary, per, why, unlistable = onion_export_state(str(tor))
        old_shape = onion_exports(str(tor))               # the old shape, still blind
    finally:
        deny.undo()
    assert (primary, per) == ("", []) and old_shape == ("", [])
    # the hostname read AND the listing are refused: two reasons, each its own path
    assert why == f"{tor / 'hostname'}: Permission denied", why
    assert unlistable == f"{tor}: Permission denied", unlistable
    deny = _Deny(tor / "hostname")                        # a readable dir, root-only file
    try:
        primary, per, why, unlistable = onion_export_state(str(tor))
    finally:
        deny.undo()
    assert primary == "" and per == [("games", ONION_B)]
    assert why.startswith(str(tor / "hostname")) and "Permission denied" in why
    assert unlistable == ""                               # the listing WORKED
    assert onion_export_state(str(tor)) == (ONION_A, [("games", ONION_B)], "", "")  # undone
    primary, per, why, unlistable = onion_export_state(str(device / "cluster-domain"))
    assert (primary, per) == ("", []) and why.startswith(str(device / "cluster-domain"))
    assert "Not a directory" in why and "Not a directory" in unlistable


def _refuse_listing(monkeypatch, tor):
    """``os.listdir`` refuses ``tor`` alone — the x-but-no-r directory (the mode bits
    cannot say it under a root runner, so it is said by the call itself)."""
    real_listdir = os.listdir

    def refuse(path="."):
        if str(path) == str(tor):
            raise PermissionError(13, "Permission denied", str(path))
        return real_listdir(path)
    monkeypatch.setattr(os, "listdir", refuse)


def test_a_directory_that_cannot_be_listed_is_a_row_beside_a_known_primary(device,
                                                                          monkeypatch):
    """A directory with x-but-no-r bits lets ``hostname`` be opened by name and refuses
    ``os.listdir``: the primary is read, the per-domain onions are NOT. The refused
    listing is its OWN reason (the fourth item: the third is about hostname files),
    and its own ROW — the round-2 review of this fix measured that one reason, spent
    on the primary's row, was never said once a primary was known: the plan showed
    the onion and dropped the per-domain onions in silence."""
    tor = device / "tor"
    _refuse_listing(monkeypatch, tor)
    primary, per, why, unlistable = onion_export_state(str(tor))
    assert primary == ONION_A and per == [] and why == ""
    assert unlistable == f"{tor}: Permission denied", unlistable
    rows = dict(exposure_rows(["mesh.example"], "mesh.example", "tor-onion", "onion",
                              "onion (onion)", primary, per, why, "",
                              listing_unreadable=unlistable))
    assert rows["Tor: this node's onion"].startswith(f"https://{ONION_A}/")
    assert rows["Tor: per-domain onions"] == ONION_LIST_UNREADABLE_HOW.format(why=unlistable)
    assert rows["Tor: per-domain onions"].startswith(
        "cannot be listed by this user (" + unlistable + ")")
    assert "<slug>.hostname" in rows["Tor: per-domain onions"]
    assert not any(k.startswith("Tor: domain slug") for k in rows)
    # the row comes AFTER the primary's and BEFORE any slug row would
    keys = [k for k, _ in exposure_rows(["mesh.example"], "mesh.example", "tor-onion",
                                        "onion", "onion (onion)", primary, per, why, "",
                                        listing_unreadable=unlistable)]
    assert keys.index("Tor: this node's onion") < keys.index("Tor: per-domain onions")
    # through plan_rows (both faces), under the onion AND a clearnet mechanism
    d = GoLiveDriver(GENERATOR_DIR)
    for provider in ("tor-onion", "cloudflare-tunnel"):
        rows = dict(plan_rows(d, GoLiveOptions(provider=provider, domain="mesh.example")))
        assert rows["Tor: this node's onion"].startswith(f"https://{ONION_A}/")
        assert rows["Tor: per-domain onions"].startswith("cannot be listed by this user (")
        assert str(tor) in rows["Tor: per-domain onions"]


def test_following_the_unreadable_rows_remedy_keeps_the_per_domain_onions_named(
        device, monkeypatch):
    """The realistic shape on a Tor node run as a user: the 0700 export directory AND
    GL_ONION_HOSTNAME set — exactly what the unreadable row's own remedy says to do.
    The primary is then known (the override), the listing is still refused, and the
    plan must still say the per-domain onions could not be listed, not fall silent
    (the round-2 review: following the remedy turned the warning into silence)."""
    tor = device / "tor"
    monkeypatch.setenv("GL_ONION_HOSTNAME", ONION_A)
    deny = _Deny(tor)
    try:
        state = onion_export_state(str(tor))
        d = GoLiveDriver(GENERATOR_DIR)
        plans = {p: plan_rows(d, GoLiveOptions(provider=p, domain="mesh.example"))
                 for p in ("tor-onion", "cloudflare-tunnel")}
    finally:
        deny.undo()
    assert state == (ONION_A, [], "", f"{tor}: Permission denied"), state
    for provider, plan in plans.items():
        rows = dict(plan)
        assert rows["Tor: this node's onion"].startswith(f"https://{ONION_A}/"), provider
        assert "cannot be read" not in rows["Tor: this node's onion"]
        assert rows["Tor: per-domain onions"] == ONION_LIST_UNREADABLE_HOW.format(
            why=f"{tor}: Permission denied"), provider
        assert not any(k.startswith("Tor: domain slug") for k in rows)
        assert any("cannot be listed by this user (" in ln for ln in exposure_lines(plan))
    # and the row is about the LISTING only: a readable directory whose hostname file
    # is root-only, with the override set, lists its per-domain onions and must NOT
    # claim they could not be listed
    deny = _Deny(tor / "hostname")
    try:
        state = onion_export_state(str(tor))
        rows = dict(plan_rows(GoLiveDriver(GENERATOR_DIR),
                              GoLiveOptions(provider="tor-onion", domain="mesh.example")))
    finally:
        deny.undo()
    assert state == (ONION_A, [("games", ONION_B)], "", "")
    assert "Tor: per-domain onions" not in rows
    assert rows["Tor: domain slug 'games'"].startswith(f"https://{ONION_B}/")


def test_the_plan_says_the_onion_cannot_be_read_rather_than_not_minted():
    why = "/var/lib/hugmesh/tor: Permission denied"
    for mechanism, label, provider in (("onion", "onion (onion)", "tor-onion"),
                                       ("files", "public-dns (files)", "byo-domain")):
        rows = dict(exposure_rows(["mesh.example"], "mesh.example", provider, mechanism,
                                  label, "", [], why))
        how = rows["Tor: this node's onion"]
        assert how == ONION_UNREADABLE_HOW.format(why=why)
        assert how.startswith("cannot be read by this user (" + why + ")")
        assert "not minted" not in how and "GL_ONION_HOSTNAME" in how
    # a readable address wins over the reason; an absent export under a clearnet
    # mechanism says nothing (no Tor on this host)
    rows = dict(exposure_rows(["mesh.example"], "mesh.example", "tor-onion", "onion",
                              "onion (onion)", ONION_A, [], why))
    assert rows["Tor: this node's onion"].startswith(f"https://{ONION_A}/")
    rows = dict(exposure_rows(["mesh.example"], "mesh.example", "byo-domain", "files",
                              "public-dns (files)"))
    assert "Tor: this node's onion" not in rows


def test_plan_rows_carry_the_unreadable_reason_to_both_faces(device, monkeypatch):
    """The ONE call both faces make: an export path that cannot be read reaches the
    rendered lines as the reason, under the onion AND a clearnet mechanism."""
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(device / "cluster-domain"))
    d = GoLiveDriver(GENERATOR_DIR)
    for provider in ("tor-onion", "cloudflare-tunnel"):
        rows = dict(plan_rows(d, GoLiveOptions(provider=provider, domain="mesh.example")))
        how = rows["Tor: this node's onion"]
        assert how.startswith("cannot be read by this user (")
        assert str(device / "cluster-domain") in how and "Not a directory" in how
        assert "not minted" not in how
    lines = exposure_lines(plan_rows(d, GoLiveOptions(provider="tor-onion")))
    assert any("cannot be read by this user" in ln for ln in lines)


def test_gl_onion_hostname_overrides_the_export_as_the_drivers_card_does(bare_node,
                                                                        monkeypatch):
    """specs/usr/lib/hugmesh/go-live-providers.sh ``_glp_onion_hostname`` prints
    GL_ONION_HOSTNAME before reading any file; the table reads the same override, so
    for a well-formed address the two name the same one. Only a well-formed v3 address
    counts as an address — a half-typed one must not reach a page as one to share."""
    monkeypatch.setenv("GL_ONION_HOSTNAME", ONION_A)
    assert onion_export_state() == (ONION_A, [], "", "")
    assert onion_exports() == (ONION_A, [])
    assert onion_override_problem() == ""
    d = GoLiveDriver(GENERATOR_DIR)
    rows = dict(plan_rows(d, GoLiveOptions(provider="tor-onion")))
    assert rows["Tor: this node's onion"].startswith(f"https://{ONION_A}/")
    assert "Tor: GL_ONION_HOSTNAME" not in rows
    monkeypatch.delenv("GL_ONION_HOSTNAME")
    assert onion_override_problem() == ""
    # the override is the PRIMARY only: per-domain onions still come from the export
    monkeypatch.setenv("GL_ONION_HOSTNAME", ONION_A)
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(bare_node))
    (bare_node / "games.hostname").write_text(ONION_B + "\n")
    assert onion_export_state() == (ONION_A, [("games", ONION_B)], "", "")


def test_a_malformed_gl_onion_hostname_is_a_row_not_silence(bare_node, device,
                                                            monkeypatch):
    """The driver's card prints GL_ONION_HOSTNAME unvalidated — a malformed value goes
    into onion.txt as the address — while the table drops it. Dropping it in SILENCE
    told the operator "not minted ... pass GL_ONION_HOSTNAME=<addr>" about a variable
    they had already set (the skeptic's finding on the first fix). Now the value is
    named as a problem, under every mechanism, and stands in for "not minted"; a
    readable export's address is still shown beside it, so the operator sees that
    the table and the card differ."""
    monkeypatch.setenv("GL_ONION_HOSTNAME", "not-an-onion")
    assert onion_export_state(str(bare_node / "absent-tor")) == ("", [], "", "")
    why = onion_override_problem()
    assert why == ONION_OVERRIDE_PROBLEM_HOW.format(value="not-an-onion")
    assert "'not-an-onion'" in why and "onion.txt" in why and "56 characters" in why
    d = GoLiveDriver(GENERATOR_DIR)
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(bare_node / "absent-tor"))
    for provider in ("tor-onion", "cloudflare-tunnel"):
        rows = dict(plan_rows(d, GoLiveOptions(provider=provider)))
        assert rows["Tor: GL_ONION_HOSTNAME"] == why, rows
        assert "Tor: this node's onion" not in rows        # unknown, not "not minted"
    # a readable export: its address AND the problem, so the difference is visible
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(device / "tor"))
    rows = dict(plan_rows(d, GoLiveOptions(provider="tor-onion")))
    assert rows["Tor: this node's onion"].startswith(f"https://{ONION_A}/")
    assert rows["Tor: GL_ONION_HOSTNAME"] == why
    # exposure_rows' own contract: the problem row replaces "not minted", never the
    # unreadable row (both can be true at once and both are said)
    unread = "/var/lib/hugmesh/tor: Permission denied"
    rows = dict(exposure_rows(["mesh.example"], "mesh.example", "tor-onion", "onion",
                              "onion (onion)", "", [], unread, why))
    assert rows["Tor: this node's onion"].startswith("cannot be read by this user (")
    assert rows["Tor: GL_ONION_HOSTNAME"] == why
    rows = dict(exposure_rows(["mesh.example"], "mesh.example", "tor-onion", "onion",
                              "onion (onion)", "", [], "", ""))
    assert rows["Tor: this node's onion"].startswith("not minted on this host")


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


def test_the_tui_enter_without_a_pick_takes_the_cluster_domain(device):
    """Enter on the domain stage with nothing picked is the cluster domain (the stage
    says so: "Enter=continue (default: the cluster domain)") — the plan's command then
    carries ``--domain mesh.example``, not an empty pick left for the driver to fill
    (the post-merge review of #645: this default had no pin)."""
    d = GoLiveDriver(GENERATOR_DIR)
    n = [p.id for p in d.providers()].index("cloudflare-tunnel") + 1
    text = _tui_plan(n, [])
    assert "--domain mesh.example" in text
    want = exposure_lines(plan_rows(d, GoLiveOptions(provider="cloudflare-tunnel",
                                                     domain="mesh.example")))
    for line in want:
        assert "  " + line in text


def test_the_tui_plan_says_the_onion_cannot_be_read(device, monkeypatch):
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(device / "cluster-domain"))
    d = GoLiveDriver(GENERATOR_DIR)
    n = [p.id for p in d.providers()].index("tor-onion") + 1
    text = _tui_plan(n, [])
    assert "cannot be read by this user (" in text and "not minted" not in text


def test_the_tui_plan_names_a_malformed_gl_onion_hostname(bare_node, monkeypatch):
    """The same row reaches the text-mode plan through the one ``plan_rows`` call."""
    monkeypatch.setenv("GL_ONION_HOSTNAME", "not-an-onion")
    d = GoLiveDriver(GENERATOR_DIR)
    n = [p.id for p in d.providers()].index("tor-onion") + 1
    text = _tui_plan(n, [])
    assert "Tor: GL_ONION_HOSTNAME" in text and "'not-an-onion'" in text
    assert "not minted" not in text


def test_the_tui_plan_says_the_per_domain_onions_cannot_be_listed(device, monkeypatch):
    """The listing row reaches the text-mode plan too (one ``plan_rows`` call): the
    0700 export with the override set — the remedy followed — in the TUI."""
    tor = device / "tor"
    monkeypatch.setenv("GL_ONION_HOSTNAME", ONION_A)
    d = GoLiveDriver(GENERATOR_DIR)
    n = [p.id for p in d.providers()].index("tor-onion") + 1
    deny = _Deny(tor)
    try:
        text = _tui_plan(n, [])
    finally:
        deny.undo()
    assert f"https://{ONION_A}/" in text
    assert "Tor: per-domain onions" in text
    assert f"cannot be listed by this user ({tor}: Permission denied)" in text
    assert "domain slug" not in text and "not minted" not in text


pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.gui.pages import golive as golive_mod                # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets                      # noqa: E402


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


def test_picking_the_entry_the_combo_already_shows_refills_the_field(wiz, device):
    """After typing another domain, picking the entry the combo ALREADY shows changes
    no index, so ``currentIndexChanged`` never fires (the post-merge review of #645,
    N7): the picker listens to ``activated`` — what Qt emits on a user's pick — too."""
    page = _to_inputs(wiz)
    assert page.domain_pick.currentIndex() == 0
    page.domain.setText("typed.example")
    page.domain_pick.activated.emit(0)
    assert page.domain.text() == "mesh.example"
    assert page.domain_hint.text() == "picked from the domains baked on this device"


def test_re_entering_the_inputs_page_keeps_a_typed_domain(wiz, device):
    """A Back-and-Next re-entry refills the picker; the refill must not fire the pick
    handler and overwrite what the operator typed (the picker's signals are blocked
    while it is rebuilt)."""
    page = _to_inputs(wiz)
    page.domain.setText("typed.example")
    page.initializePage()
    assert page.domain.text() == "typed.example"
    assert page.domain_pick.currentIndex() == 0       # no baked entry matches it


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


def test_the_generate_exposure_pane_wraps_so_a_rows_remedy_is_read_whole(wiz, device,
                                                                        monkeypatch):
    """The unreadable-export row carries its remedy at the end of a long sentence; the
    pane wraps at its width (no sideways scrolling) and the wizard's default size shows
    the whole box — measured, not assumed (hugmesh-generator#647 / #656)."""
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(device / "cluster-domain"))
    page = _to_inputs(wiz, provider="tor-onion")
    assert page.validatePage()
    gen = wiz.page(wiz._page_ids["generate"])
    wiz.setStartId(wiz._page_ids["generate"])
    wiz.restart()
    wiz.show()
    QtWidgets.QApplication.processEvents()
    assert wiz.currentPage() is gen
    box = gen.exposure
    assert box.lineWrapMode() == QtWidgets.QPlainTextEdit.LineWrapMode.WidgetWidth
    assert box.horizontalScrollBar().maximum() == 0
    text = box.toPlainText()
    assert "cannot be read by this user (" in text and "GL_ONION_HOSTNAME" in text
    assert box.isVisible() and box.width() >= 400 and box.height() >= 100, (
        box.width(), box.height())
    # every row is in view: the box fits its wrapped rows (no row behind a scrollbar)
    assert box.verticalScrollBar().maximum() == 0, (box.height(), box.content_height())
    assert box.height() >= box.content_height()
    # the box lies inside the wizard's window at its default size
    r = QtCore.QRect(box.mapTo(wiz, QtCore.QPoint(0, 0)), box.size())
    assert wiz.rect().contains(r), (r, wiz.size())
    wiz.close()


def test_the_generate_exposure_pane_fits_six_rows_and_grows_with_the_window(wiz, device,
                                                                           monkeypatch):
    """Six rows at the wizard's default size — three baked domains, the node's onion,
    a malformed GL_ONION_HOSTNAME and a per-domain onion — are ALL in view (the first
    post-merge fix's fixed 180 px box cut the sixth behind a scrollbar at 9 pt; the
    round-2 review's shots-override-default/04), and a taller window makes the box
    taller instead of stopping at a fixed maximum."""
    with open(device / "domains", "a", encoding="utf-8") as fh:
        fh.write("blog.example\n")
    monkeypatch.setenv("GL_ONION_HOSTNAME", "not-an-onion")
    page = _to_inputs(wiz, provider="tor-onion")
    assert page.validatePage()
    gen = wiz.page(wiz._page_ids["generate"])
    wiz.setStartId(wiz._page_ids["generate"])
    wiz.restart()
    wiz.resize(820, 640)                      # GoLiveWizard.__init__'s own default
    wiz.show()
    QtWidgets.QApplication.processEvents()
    assert wiz.currentPage() is gen
    box = gen.exposure
    rows = box.toPlainText().splitlines()
    assert len(rows) == 6, rows
    assert rows[-1].startswith("Tor: domain slug 'games'")
    assert box.verticalScrollBar().maximum() == 0, (box.height(), box.content_height())
    assert box.horizontalScrollBar().maximum() == 0
    assert box.height() >= box.content_height() >= 6 * box.fontMetrics().lineSpacing()
    assert box.minimumHeight() == min(box.content_height(), golive_mod.EXPOSURE_PANE_MAX_PX)
    r = QtCore.QRect(box.mapTo(wiz, QtCore.QPoint(0, 0)), box.size())
    assert wiz.rect().contains(r), (r, wiz.size())
    # a taller window: the box grows (it is not capped at a fixed maximum height)
    h0 = box.height()
    wiz.resize(wiz.width(), wiz.height() + 400)
    QtWidgets.QApplication.processEvents()
    QtWidgets.QApplication.processEvents()
    assert box.height() > h0 + 100, (h0, box.height())
    assert box.verticalScrollBar().maximum() == 0
    # a narrower window wraps more: the box gets taller again and still scrolls nothing
    wiz.resize(wiz.width() - 200, 640)
    QtWidgets.QApplication.processEvents()
    QtWidgets.QApplication.processEvents()
    assert box.verticalScrollBar().maximum() == 0, (box.height(), box.content_height())
    assert box.minimumHeight() >= box.content_height() or (
        box.minimumHeight() == golive_mod.EXPOSURE_PANE_MAX_PX)
    wiz.close()
