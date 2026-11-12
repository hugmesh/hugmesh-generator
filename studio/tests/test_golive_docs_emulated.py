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
  and its link lands on a real heading;
* what the GUEST keeps is what the guest's driver really does: `plan` (a dry run for
  the posture) stores a given token in the keys layout under /etc/hugmesh/keys, out of
  reach of Studio's `rm` of the staged file, and never in an artifact Studio copies
  back. The doc must say so, say that a Save copies it, and advise a dummy token. That
  is checked by RUNNING the driver offline in a sandbox, not by reading it;
* what a Save copies (the disk through blockdev-backup, no guest RAM) is what the Save
  path and its buttons say;
* every string and shape the section quotes from core.golive_target (FG1: token
  staging, the guest out-dir, the commit argv, the Funnel refusal, the reachability
  labels, the journal wording, the probe's reads) is checked against it, and the
  status callout says which parts have landed.

Qt-free: it reads files, imports core modules and runs the driver with bash only.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import types

import pytest

from hugmesh_studio.core import golive_driver, mesh_emulation

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DOC = os.path.join(REPO, "docs", "GO-LIVE-WIZARD.md")
HEADING = "## Go live from an emulated mesh"

#: The design's verdict per registry mechanism (what an emulated node can really reach:
#: only what dials OUT; the harness publishes loopback ssh only). The onion is the one
#: real path, and it is up from boot. The tunnel would dial out but never starts on an
#: emulated mesh (inert). Funnel needs Tailscale's hosted control plane, so core refuses
#: it on an emulated target.
EXPECTED_REACH = {
    "deeplink": "inert",
    "onion": "real",
    "files": "rehearsal",
    "ddns": "rehearsal",
    "instructions": "rehearsal",
    "funnel": "refused",
}

EPHEMERAL = ("this posture lasts until the device stops; a restart boots the golden "
             "image INTERNAL again — Save the device to keep a copy")
REHEARSAL = ("REHEARSAL — the posture flips inside the emulated node, but nothing "
             "outside this workstation can reach it; the harness publishes loopback ssh only")
TUNNEL_LABEL = ("can be really reachable (outbound only); but the tunnel token is consumed "
                "only by the PROD ExternalSecret, so on an emulated mesh the tunnel will "
                "not start")
#: The staging command, verbatim as the section shows it.
STAGE_SCRIPT = 'umask 077; t=$(mktemp /run/hugmesh-golive-tok.XXXXXX) && cat >"$t" && echo "$t"'
GUEST_OUT = "/var/lib/hugmesh/go-live/out/studio-<UTC stamp>"
DRIVER = os.path.join(REPO, "specs", "usr", "sbin", "hugmesh-go-live")
PROVIDERS_LIB = os.path.join(REPO, "specs", "usr", "lib", "hugmesh", "go-live-providers.sh")
requires_bash = pytest.mark.skipif(shutil.which("bash") is None, reason="bash not available")


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
    assert f"*{TUNNEL_LABEL}*" in section
    assert "*not on headscale*" in section


def test_intro_does_not_promise_reachability(section: str):
    # Round 1 said "Two mechanisms can make the emulated node really reachable" while
    # the same section said the tunnel never starts and tor-onion commit is refused.
    flat = _flat(section)
    assert "Two mechanisms can make" not in flat
    assert "no go-live commit makes an emulated node reachable" in flat
    rows = _reach_rows(section)
    assert [p for p, (_m, v) in rows.items() if v == "real"] == ["tor-onion"]


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
    assert ("ssh -i KEY -p PORT <host-key options> -t -o LogLevel=ERROR user@127.0.0.1 "
            "'sudo hugmesh-go-live commit --provider P") in section


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


def test_fail_safe_bullet_no_longer_says_plan_never_writes_etc(doc: str):
    flat = _flat(doc)
    assert "it never reads or writes `/etc/hugmesh`" not in flat
    assert "Its one write outside the output dir is a token" in flat
    assert "`<keys-dir>/cloudflared/tunnel-token` or `<keys-dir>/ddns/token`" in flat
    assert "`--keys-dir` defaults to `/etc/hugmesh/keys`" in flat
    # Secret hygiene used to name keys-template/ as where tokens land; the driver
    # writes to its --keys-dir.
    hyg = doc[doc.index("\n## Secret hygiene\n"):]
    hyg = _flat(hyg[:hyg.index("\n## ", 5)])
    assert "keys-template/ddns/token" not in hyg
    assert "[What the guest keeps](#what-the-guest-keeps)" in hyg


# ── what the guest keeps: RUN the driver, then hold the doc to what it did ─────────
def _plan_in_sandbox(tmp_path, provider: str, token: str) -> dict:
    """``plan`` with a token file, exactly as a guest runs it (no --keys-dir), with
    /etc/hugmesh redirected into a sandbox. Returns what it wrote, and where."""
    etc = tmp_path / "etc"
    etc.mkdir()
    (etc / "cluster-domain").write_text("example.invalid\n")
    (etc / "release-state").write_text("internal\n")
    tok = tmp_path / "staged-token"
    tok.write_text(token + "\n")
    out = tmp_path / "out"
    env = dict(os.environ, GL_ETC_HUGMESH=str(etc), GL_PROVIDERS_LIB=PROVIDERS_LIB)
    env.pop("GL_KEYS_DIR", None)
    env.pop("GL_ASSUME_YES", None)
    r = subprocess.run(
        ["bash", DRIVER, "plan", "--provider", provider, "--domain", "example.invalid",
         "--ddns-subdomain", "demo", "--token-file", str(tok), "--out-dir", str(out)],
        env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr
    stored = {}
    for root, _dirs, files in os.walk(etc):
        for name in files:
            path = os.path.join(root, name)
            with open(path, encoding="utf-8", errors="replace") as fh:
                if token in fh.read():
                    stored[os.path.relpath(path, etc)] = os.stat(path).st_mode & 0o777
    leaked = []
    for root, _dirs, files in os.walk(out):
        for name in files:
            with open(os.path.join(root, name), encoding="utf-8", errors="replace") as fh:
                if token in fh.read():
                    leaked.append(name)
    return {"stored": stored, "leaked": leaked, "log": r.stdout + r.stderr,
            "marker": (etc / "go-live").exists(),
            "state": (etc / "release-state").read_text().strip()}


@requires_bash
@pytest.mark.parametrize("provider,rel", [
    ("cloudflare-tunnel", "keys/cloudflared/tunnel-token"),
    ("duckdns", "keys/ddns/token"),
])
def test_plan_stores_the_token_in_the_guest_and_the_doc_says_so(tmp_path, section,
                                                                provider, rel):
    token = "dummy-token-not-a-real-secret-0123456789"
    got = _plan_in_sandbox(tmp_path, provider, token)
    # What the guest's driver really does with a staged token during a DRY RUN:
    assert got["stored"] == {rel: 0o600}, got["stored"]
    assert "token stored -> " in got["log"]
    assert not got["leaked"], f"the token is in plan artifacts Studio copies back: {got}"
    assert not got["marker"] and got["state"] == "internal", "plan touched the posture"
    # ...and the section says exactly that, at the guest's real path.
    flat = _flat(section)
    assert f"`/etc/hugmesh/{rel}`" in flat
    assert "Studio's `rm -f` removes only the staged `/run/hugmesh-golive-tok.*` file" in flat
    assert "nothing ever deletes it" in flat
    assert "**any token a plan stored under `/etc/hugmesh/keys/`**" in flat
    assert "**On an emulated mesh, use a dummy token.**" in flat
    assert "a Save copies it onto your host" in flat
    assert "never hold its value" in flat


def test_guest_keeps_artifacts_and_posture(section: str):
    flat = _flat(section)
    assert "#### What the guest keeps" in section
    assert f"--out-dir {GUEST_OUT}`" in flat
    assert "each run in its own `/var/lib/hugmesh/go-live/out/studio-<UTC stamp>/`" in flat
    assert "never deletes them in the guest" in flat
    assert "`/etc/hugmesh/go-live` after a `commit`" in flat
    assert "`release-state=public` after `commit --persist-public`" in flat
    # The section once claimed "What persists is host-side only".
    assert "What persists is host-side only" not in flat
    # The driver's default out root is the one quoted.
    assert 'DEFAULT_OUT_DIR="${GL_OUT_DIR:-/var/lib/hugmesh/go-live/out}"' in _read(
        "specs", "usr", "sbin", "hugmesh-go-live")


def test_what_a_save_copies_matches_the_save_path(section: str):
    flat = _flat(section)
    assert "#### What a Save copies" in section
    assert "(`blockdev-backup sync=full`)" in flat
    assert "guest RAM is not in it" in flat
    page = _read("studio", "hugmesh_studio", "gui", "pages", "mesh_emulation.py")
    for button in ("Save copy", "Overwrite save", "Save mesh"):
        assert f'"{button}"' in page, f"the mesh-emulation page has no {button!r} button"
        assert f"**{button}**" in flat
    assert "guest RAM is not in it" in page, "the Save tooltip no longer says RAM is excluded"
    runner = _read("tests", "qemu", "run-qemu-docker.sh")
    assert re.search(r'blockdev-backup .*\\"sync\\":\\"full\\"', runner), (
        "the device save no longer copies the disk with blockdev-backup sync=full")
    assert "KEYS stick payload and its login keypair" in flat
    assert "<label>.id_ed25519" in _read("studio", "hugmesh_studio", "core",
                                         "emulation_save.py")


# ── what the flow quotes from core.golive_target ───────────────────────────────────
#: The doc side; test_section_matches_the_golive_target_core holds the code side.
JOURNAL_WORDS = ("*commit launched from this host*", "*last commit from this host*",
                 "under `refused`", "*did NOT go through*")
PROBE_READS = ("command -v hugmesh-go-live", "/etc/hugmesh/cluster-domain",
               "/etc/hugmesh/domains", "/etc/hugmesh/release-state", "/var/lib/hugmesh/tor/")
REACH_LINE = "[reachability] <provider> (<mechanism>) from <label>: <verdict>"


def test_flow_quotes_the_core_wording(section: str):
    flat = _flat(section)
    assert f"`{STAGE_SCRIPT}`" in flat
    assert "never passes `--keys-dir`" in flat and "`sudo -n rm -f -- $t`" in flat
    for said in JOURNAL_WORDS:
        assert said in flat, said
    for path in PROBE_READS:
        assert path in flat, path
    assert REACH_LINE in flat


# ── the section against what has landed (FG1 #927, FG2, FG5 #932, FG3 #926) ────────
def test_status_callout_says_what_has_landed(section: str):
    flat = _flat(section)
    assert "**Status: specification." not in flat, "FG1 is in the tree; the callout is stale"
    assert ("The target model, the ssh path and the CLI "
            "(`hugmesh_studio.core.golive_target`, group FG1) are in the tree.") in flat
    # FG2 (the faces) is in the tree: the wizard has its target picker, the TUI its
    # target list. The callout says so, and no longer says the wizard drives only
    # this host.
    page = _read("studio", "hugmesh_studio", "gui", "pages", "golive.py")
    tui = _read("studio", "hugmesh_studio", "tui", "golive.py")
    assert "target_pick" in page and "def _lines_target" in tui
    assert "faces (group FG2) and the proof lane (group FG3) are not yet" not in flat, (
        "FG2's target picker is in the tree: update the status callout")
    assert "The GUI and TUI faces (group FG2) are in the tree too" in flat
    assert "Studio's wizard drives only **This host**" not in flat
    # FG5 (boot from a save) is in the tree as a CLI/Makefile lane, with no GUI button:
    # the callout and the Persistence part say exactly that, and the wizard still
    # calls the posture ephemeral.
    makefile = _read("Makefile")
    assert "--from-save" in makefile and "FROM_SAVE" in makefile
    assert "from_save" not in page.lower(), (
        "a GUI boot-from-save entry exists: update the callout and Persistence")
    assert "(group FG5) is in the tree as a CLI and Makefile lane only" in flat
    assert "`make mesh-emu-up FROM_SAVE=mesh-<stamp>`" in flat
    assert "is a later follow-up (group FG5)" not in flat
    # FG3 (the harness proof lane) landed in #926. The callout names the script, and
    # the "has not merged" wording must not come back while the lane is in the tree.
    lane = [f for f in os.listdir(os.path.join(REPO, "tests", "qemu"))
            if "golive" in f or "go-live" in f]
    if not lane:
        assert "The harness proof lane (group FG3) has not merged" in flat
    else:
        assert "The harness proof lane (group FG3) has not merged" not in flat, (
            f"FG3's proof lane is in the tree ({lane}): update the status callout")
        assert "`tests/qemu/golive-emulated.sh`" in flat, (
            "the status callout no longer names the FG3 proof-lane script")
        assert "golive-emulated.sh" in lane


def _fake_target(gt, tmp_path):
    return gt.GoLiveTarget(
        kind=gt.KIND_DOCKER, label="rpi5_pki",
        ssh_base_argv=("ssh", "-i", "/k", "-p", "22302", "-o", "StrictHostKeyChecking=no",
                       "wheel@127.0.0.1"),
        running=True, platform="rpi5", role="pki", started_at="2026-11-10T00:00:00Z",
        ssh_port=22302, ssh_key="/k", ssh_user="wheel", work_dir=str(tmp_path))


def test_section_matches_the_golive_target_core(tmp_path, section: str):
    from hugmesh_studio.core import golive_target as gt
    t = _fake_target(gt, tmp_path)

    # token staging, the guest out dir, and --keys-dir never passed
    assert gt._STAGE_SCRIPT == STAGE_SCRIPT
    assert gt.guest_out_dir("X") == GUEST_OUT.replace("<UTC stamp>", "X")
    calls = []

    def run(argv, **kw):
        calls.append(argv)
        out = "/run/hugmesh-golive-tok.AbC123\n" if "umask 077" in argv[-1] else ""
        return types.SimpleNamespace(returncode=0, stdout=out, stderr="")

    class Proc:
        stdout = iter(())

        def wait(self):
            return 0

    def popen(argv, **kw):
        calls.append(argv)
        return Proc()

    from hugmesh_studio.core.golive_driver import GoLiveOptions
    tok = tmp_path / "host-token"
    tok.write_text("dummy\n")
    rc = gt.run_plan(t, GoLiveOptions(provider="cloudflare-tunnel", domain="example.invalid",
                                      token_file=str(tok), keys_dir="/elsewhere"),
                     run=run, popen=popen)
    assert rc == 0
    plan = next(a for a in calls if " plan " in a[-1])
    assert "--keys-dir" not in plan[-1], plan
    assert "--out-dir /var/lib/hugmesh/go-live/out/studio-" in plan[-1]
    assert "--token-file /run/hugmesh-golive-tok.AbC123" in plan[-1]
    assert any(a[-1] == "sudo -n rm -f -- /run/hugmesh-golive-tok.AbC123" for a in calls)

    # the commit argv: -t, LogLevel=ERROR, the remote command as one element, no -y
    argv = gt.commit_argv(t, "byo-domain", "example.invalid")
    i = argv.index("-t")
    assert argv[i:i + 4] == ["-t", "-o", "LogLevel=ERROR", "wheel@127.0.0.1"]
    assert argv[-1].startswith("sudo hugmesh-go-live commit --provider byo-domain")
    assert "-y" not in argv[-1].split() and "--yes" not in argv[-1].split()

    # Funnel: refused on an emulated target, not on this host; nothing else refused
    assert gt.headscale_refusal(t, "tailscale-funnel")
    assert not gt.headscale_refusal(gt.local_target(), "tailscale-funnel")
    for pid in ("byo-domain", "cloudflare-tunnel", "duckdns", "router-portforward",
                "tor-onion"):
        assert not gt.headscale_refusal(t, pid), pid
    with pytest.raises(ValueError):
        gt.commit_argv(t, "tailscale-funnel")

    # the reachability labels the table quotes are the core's own
    assert gt.EPHEMERAL_NOTE == EPHEMERAL and gt._REHEARSAL == REHEARSAL
    rows = {ln.split("|")[1].strip(): ln for ln in section.splitlines()
            if re.match(r"^\| `[a-z0-9-]+` \| `", ln)}
    for pid, row in rows.items():
        mech = row.split("|")[2].strip().strip("`")
        label = gt.mechanism_reachability(mech, t, pid.strip("`"))
        assert label, pid
        if label == REHEARSAL:
            assert "REHEARSAL" in row, pid
        else:
            assert f"*{label}*" in row, (pid, label)

    # the journal wording the flow quotes
    gt.write_journal(t, "commit", "byo-domain", "example.invalid")
    assert "commit launched from this host" in gt.journal_status(str(tmp_path), t)
    gt.write_journal(t, "commit", "byo-domain", "example.invalid", rc=0)
    assert "last commit from this host" in gt.journal_status(str(tmp_path), t)
    gt.write_journal(t, "commit", "tor-onion", "", rc=1)
    js = gt.journal_status(str(tmp_path), t)
    assert "did NOT go through" in js and "last commit from this host" in js
    assert gt.read_journal(str(tmp_path), t.label)["refused"]["rc"] == 1

    # the probe reads what the flow says it reads
    for path in PROBE_READS:
        assert path in gt._PROBE_SCRIPT, path

    # the CLI prints the verdict before a plan, in the quoted shape
    assert 'f"[reachability] {args.provider} ({mech}) from {t.label}: {reach}"' in _read(
        "studio", "hugmesh_studio", "core", "golive_target.py")


def test_relative_file_links_resolve(section: str):
    links = re.findall(r"\]\((\.\./[^)#]+)\)", section)
    assert links
    for rel in links:
        path = os.path.normpath(os.path.join(REPO, "docs", rel))
        assert os.path.exists(path), rel
