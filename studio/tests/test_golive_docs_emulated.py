"""docs/GO-LIVE-WIZARD.md's "Go live from an emulated mesh" section matches the tree.

The section is the contract for going live from a QEMU-emulated mesh. These guards
tie its load-bearing claims to code that exists, so the page cannot quietly drift:

* the reachability table covers EVERY mechanism the registry publishes, with the
  provider ids and mechanisms the registry actually pairs, and the real / rehearsal /
  none verdict the design fixes per mechanism (a new mechanism fails here until it is
  documented);
* the refused emulation ranges are the ones the code uses (slirp, and the mesh L2
  that core.mesh_emulation.MESH_SUBNET names);
* the cloudflare-tunnel claim ("consumed only by the PROD ExternalSecret") is true of
  specs/: exactly one manifest reads the tunnel token;
* no go-live commit or rollback line in the section carries -y/--yes;
* the native-Windows prerequisite (the WHPX record has no ssh_key/ssh_user) is still
  true of qemu_windows's record writer, and the shell it cites still opens with
  CREATE_NEW_CONSOLE;
* the architecture table's Studio GUI row no longer implies the wizard drives a device,
  and its link lands on a real heading.

Qt-free: it reads files and imports core modules only.
"""
from __future__ import annotations

import os
import re

import pytest

from hugmesh_studio.core import golive_driver, mesh_emulation

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DOC = os.path.join(REPO, "docs", "GO-LIVE-WIZARD.md")
HEADING = "## Go live from an emulated mesh"

#: The design's verdict per registry mechanism (what an emulated node can really reach:
#: only what dials OUT; the harness publishes loopback ssh only; funnel needs Tailscale).
EXPECTED_REACH = {
    "deeplink": "real",
    "onion": "real",
    "files": "rehearsal",
    "ddns": "rehearsal",
    "instructions": "rehearsal",
    "funnel": "none",
}

EPHEMERAL = ("this posture lasts until the device stops; a restart boots the golden "
             "image INTERNAL again — Save the device to keep a copy")
REHEARSAL = ("REHEARSAL — the posture flips inside the emulated node, but nothing "
             "outside this workstation can reach it; the harness publishes loopback ssh only")


def _read(*parts: str) -> str:
    with open(os.path.join(REPO, *parts), encoding="utf-8") as fh:
        return fh.read()


@pytest.fixture(scope="module")
def doc() -> str:
    with open(DOC, encoding="utf-8") as fh:
        return fh.read()


@pytest.fixture(scope="module")
def section(doc: str) -> str:
    start = doc.find("\n" + HEADING + "\n")
    assert start >= 0, f"{HEADING!r} is missing from docs/GO-LIVE-WIZARD.md"
    end = doc.find("\n## ", start + 1)
    return doc[start:end if end >= 0 else len(doc)]


def _flat(text: str) -> str:
    """Prose with its line wrapping (and blockquote markers) collapsed to single spaces."""
    return re.sub(r"\s+", " ", re.sub(r"\n> ?", "\n", text))


def _slug(heading: str) -> str:
    """GitHub's heading anchor: lowercase, drop punctuation except - and _, spaces -> -."""
    text = heading.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def _anchors(doc: str) -> set[str]:
    return {_slug(m.group(1)) for m in re.finditer(r"^#{1,6} (.+)$", doc, re.M)}


def _reach_rows(section: str) -> dict[str, tuple[str, str]]:
    """provider id -> (mechanism, verdict) from the reachability table."""
    rows: dict[str, tuple[str, str]] = {}
    for line in section.splitlines():
        m = re.match(r"^\| `([a-z0-9-]+)` \| `([a-z]+)` \| \*\*([a-z]+)\*\*", line)
        if m:
            rows[m.group(1)] = (m.group(2), m.group(3))
    return rows


# ── the reachability table ───────────────────────────────────────────────────────
def test_expected_reach_covers_every_mechanism_the_code_knows():
    # A new mechanism in the driver's taxonomy must get a verdict here AND in the doc.
    assert set(EXPECTED_REACH) == set(golive_driver._MECH_MODEL)


def test_every_registry_provider_has_a_row_with_its_real_mechanism(section: str):
    providers = golive_driver.GoLiveDriver(REPO)._registry_providers()
    assert len(providers) >= 6, "the registry reader found too few providers"
    rows = _reach_rows(section)
    for p in providers:
        assert p.id in rows, f"provider {p.id} has no row in the reachability table"
        mech, verdict = rows[p.id]
        assert mech == p.mechanism, (
            f"{p.id}: doc says mechanism {mech}, registry says {p.mechanism}")
        assert verdict == EXPECTED_REACH[p.mechanism], (
            f"{p.id} ({p.mechanism}): doc says {verdict}, design says "
            f"{EXPECTED_REACH[p.mechanism]}")
    assert set(rows) == {p.id for p in providers}, "the table lists a provider the registry lacks"


def test_rehearsal_and_tunnel_labels_are_the_designed_sentences(section: str):
    assert REHEARSAL in section
    assert "*can be really reachable (outbound only)*" in section
    assert "*not on headscale*" in section


def test_cloudflare_token_claim_matches_specs(section: str):
    flat = _flat(section)
    assert "PROD-only `cloudflared-tunnel-token` ExternalSecret" in flat
    assert "on an emulated mesh the tunnel does not start" in flat
    readers = []
    for root, _dirs, files in os.walk(os.path.join(REPO, "specs")):
        for name in files:
            if not name.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8", errors="replace") as fh:
                if re.search(r"^\s*property:\s*tunnel_token\s*$", fh.read(), re.M):
                    readers.append(os.path.relpath(path, REPO))
    assert readers == ["specs/cluster/manifests/cloudflared/externalsecret.yaml"], readers
    assert "PROD only" in _read("specs", "cluster", "manifests", "cloudflared",
                                "externalsecret.yaml").splitlines()[0]


# ── persistence ──────────────────────────────────────────────────────────────────
def test_ephemeral_banner_and_restart_reset(section: str):
    flat = _flat(section)
    assert EPHEMERAL in flat
    assert "*reset by a restart*" in flat
    assert "`<work>/golive/<label>.json`" in flat
    assert "It holds no secrets" in flat


# ── refusals ─────────────────────────────────────────────────────────────────────
def test_refused_ranges_are_the_emulation_ranges(section: str):
    assert f"`{mesh_emulation.MESH_SUBNET}.0/24`" in section, (
        "the mesh L2 range in the refusal table is not core.mesh_emulation.MESH_SUBNET")
    assert "`10.0.2.0/24` (QEMU slirp)" in section


def test_no_commit_or_rollback_line_carries_yes(section: str):
    lines = [ln for ln in section.splitlines()
             if re.search(r"hugmesh-go-live (commit|rollback)|^\$ .*golive_target (commit|rollback)", ln)]
    assert lines, "the section shows no commit/rollback command"
    for ln in lines:
        assert not re.search(r"(^|\s)(-y|--yes)(\s|$|`)", ln), ln
    assert "There is **no `-y`**" in section
    assert "ssh -t -i KEY -p PORT user@127.0.0.1 sudo hugmesh-go-live commit" in section


def test_no_inbound_relay_is_stated(section: str):
    flat = _flat(section)
    assert "Deliberately not built: an inbound relay on the Studio host" in flat
    assert "`0.0.0.0:80` and `0.0.0.0:443`" in flat


# ── per OS / CLI ─────────────────────────────────────────────────────────────────
def test_cli_spelling(section: str):
    for verb in ("targets", "probe", "status", "list", "plan", "commit", "rollback"):
        assert re.search(rf"python -m hugmesh_studio\.core\.golive_target {verb}\b", section), verb
    assert "hugmesh-studio-cli --go-live-target" in section


def test_windows_prerequisite_is_still_true_of_the_whpx_record(section: str):
    src = _read("studio", "hugmesh_studio", "core", "qemu_windows.py")
    m = re.search(r"^\s*rec = \{(.*?)\}\n", src, re.M | re.S)
    assert m, "qemu_windows no longer writes its record as `rec = {...}`; re-check the doc"
    record_keys = set(re.findall(r'"([a-z_]+)":', m.group(1)))
    assert "ssh_port" in record_keys and "started_at" in record_keys
    stale = {"ssh_key", "ssh_user"} & record_keys
    assert not stale, (
        f"the WHPX record now carries {sorted(stale)}: update the doc's native-Windows "
        "prerequisite (and this guard)")
    assert "no `ssh_key` and no `ssh_user`" in _flat(section)


def test_cited_windows_shell_opens_a_new_console(section: str):
    assert "`_open_native_shell`" in section
    src = _read("studio", "hugmesh_studio", "gui", "pages", "mesh_emulation.py")
    m = re.search(r"\n    def _open_native_shell\(.*?(?=\n    def |\Z)", src, re.S)
    assert m, "mesh_emulation.py no longer has _open_native_shell"
    assert "CREATE_NEW_CONSOLE" in m.group(0)


def test_linux_terminal_row_names_the_gnome_wayland_terminals(section: str):
    row = next(ln for ln in section.splitlines() if ln.startswith("| **Linux, X11 or Wayland**"))
    assert "`ptyxis`" in row and "`kgx`" in row


# ── architecture row + links ─────────────────────────────────────────────────────
def test_studio_gui_row_does_not_imply_it_drives_a_device(doc: str):
    row = next(ln for ln in doc.splitlines() if ln.startswith("| Studio GUI |"))
    assert "shells out to the same driver subcommands" not in row
    assert "**Studio host's own** `/etc/hugmesh`" in row
    assert "does **not** reach a device" in row
    assert "(#go-live-from-an-emulated-mesh)" in row


def test_in_page_anchors_resolve(doc: str, section: str):
    anchors = _anchors(doc)
    assert "go-live-from-an-emulated-mesh" in anchors
    targets = set(re.findall(r"\]\(#([^)]+)\)", section))
    targets |= set(re.findall(r"\]\(#([^)]+)\)",
                              next(ln for ln in doc.splitlines() if ln.startswith("| Studio GUI |"))))
    assert targets, "expected in-page links"
    missing = sorted(t for t in targets if t not in anchors)
    assert not missing, f"links to headings that do not exist: {missing}"


def test_relative_file_links_resolve(section: str):
    links = re.findall(r"\]\((\.\./[^)#]+)\)", section)
    assert links
    for rel in links:
        path = os.path.normpath(os.path.join(REPO, "docs", rel))
        assert os.path.exists(path), rel
