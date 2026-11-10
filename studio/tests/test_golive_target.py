"""core.golive_target — go-live against an EMULATED device, ssh only (no Qt, no ssh run).

Every ssh argv is pinned. The laws these tests hold:
  * a token VALUE is never on any argv (host or guest) — it travels on ssh stdin;
  * no -y/--yes anywhere: commit/rollback run the guest driver's confirm on the ssh pty;
  * the guest token file is deleted on the error path too;
  * each refusal says why, in a sentence;
  * a journal from an earlier boot of the device reads "reset by a restart";
  * the WSL and native-Windows terminal shapes.
Nothing here starts ssh: subprocess.run / Popen are fakes that record argv and stdin.
"""
import io
import json
import os
import shlex
import shutil
import subprocess
import threading

import pytest

from hugmesh_studio.core import golive_target as gt
from hugmesh_studio.core.golive_driver import GoLiveDriver, GoLiveOptions
from hugmesh_studio.core.golive_domains import plan_rows

SECRET = "tok-SUPER-secret-value-123"


@pytest.fixture(autouse=True)
def _host_is_posix(monkeypatch):
    """The docker lane is refused on native Windows (its own test passes osname="nt");
    every other test exercises the shared logic, so it runs alike on the Windows job."""
    monkeypatch.setattr(gt, "_host_os", lambda: "posix")
ONION = "a" * 56 + ".onion"
ONION2 = "b" * 56 + ".onion"


def _record(**over):
    rec = {"label": "rpi5/pki", "platform": "rpi5", "role": "pki", "state": "running",
           "ssh_host_port": 2201, "ssh_user": "hugmesh", "ssh_key": "/k/id_ed25519",
           "started_at": "2026-11-09T10:00:00Z", "container": "c1"}
    rec.update(over)
    return rec


def _work(tmp_path, *recs):
    d = tmp_path / "work" / "devices"
    d.mkdir(parents=True)
    for i, r in enumerate(recs):
        (d / f"r{i}.json").write_text(json.dumps(r))
    return str(tmp_path / "work")


def _target(tmp_path=None, **over):
    from hugmesh_studio.core.qemu_devices import device_from_record
    return gt.target_from_device(device_from_record(_record(**over)),
                                 str(tmp_path) if tmp_path else "")


BASE = ["ssh", "-i", "/k/id_ed25519", "-p", "2201", "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null"]
BATCH = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "LogLevel=ERROR"]
DEST = "hugmesh@127.0.0.1"


class FakeRun:
    """subprocess.run stand-in: records (argv, input) and answers by verb."""

    def __init__(self, probe_text="", stage_path="/run/hugmesh-golive-tok.Ab12Cd",
                 listing="dns-records.txt\ninstructions.txt\n", fail_rm=False):
        self.calls = []
        self.probe_text = probe_text
        self.stage_path = stage_path
        self.listing = listing
        self.fail_rm = fail_rm

    def __call__(self, argv, **kw):
        self.calls.append((list(argv), kw.get("input")))
        self.kws = getattr(self, "kws", []) + [kw]
        remote = argv[-1]
        out, rc = "", 0
        if "mktemp" in remote:
            out = self.stage_path + "\n"
        elif " rm -f " in f" {remote} ":
            rc = 1 if self.fail_rm else 0
        elif "printf" in remote:
            out = self.listing
        elif " cat -- " in f" {remote} ":
            out = b"artifact body\n"
        elif "::driver" in remote:
            out = self.probe_text
        elif remote.endswith("list"):
            out = ("ID  MECHANISM  STATE  DESCRIPTION\n"
                   "byo-domain  files  full  Bring your own domain\n"
                   "tor-onion  onion  full  Tor onion\n")
        elif remote.endswith("status"):
            out = "effective posture:   internal\n"
        return subprocess.CompletedProcess(argv, rc, out, "")


class FakePopen:
    def __init__(self, lines=("==> Rendering provider artifacts", "==> Plan summary ready"),
                 rc=0, raise_on_start=None, record=None):
        self.lines, self.rc, self.raise_on_start = lines, rc, raise_on_start
        self.record = record if record is not None else []

    def __call__(self, argv, **kw):
        self.record.append(list(argv))
        if self.raise_on_start:
            raise self.raise_on_start
        outer = self

        class P:
            stdout = io.StringIO("".join(f"{x}\n" for x in outer.lines))

            def wait(self):
                return outer.rc

            def terminate(self):
                pass

            def poll(self):
                return outer.rc
        return P()


def _all_argv_tokens(calls):
    """Every token of every argv, with the remote-command string split as the guest's
    shell will split it — so a secret or a -y hidden INSIDE it is still found."""
    toks = []
    for argv in calls:
        argv = argv[0] if isinstance(argv, tuple) else argv
        toks += list(argv)
        try:
            toks += shlex.split(argv[-1])
        except ValueError:
            pass
    return toks


PROBE_OK = ("::driver\n/usr/sbin/hugmesh-go-live\n::cluster-domain\nexample.org\n"
            "::domains\n\n::release-state\ninternal\n"
            f"::tor hostname\n{ONION}\n::tor shop.hostname\n{ONION2}\n::end\n")


# ── targets + refusals ───────────────────────────────────────────────────────────────
def test_targets_list_local_then_docker_then_whpx(tmp_path):
    work = _work(tmp_path, _record(), _record(label="x86/backend", platform="x86",
                                              role="backend",
                                              started_at="2026-11-09T09:00:00Z"))
    whpx = [{"label": "x86/frontend", "ssh_port": 2222, "started_at": "t", "pid": 1}]
    rows = gt.targets(work, whpx_running=lambda w: whpx)
    assert [(t.kind, t.label) for t in rows] == [
        (gt.KIND_LOCAL, gt.LOCAL_LABEL), (gt.KIND_DOCKER, "rpi5/pki"),
        (gt.KIND_DOCKER, "x86/backend"), (gt.KIND_WHPX, "x86/frontend")]
    assert rows[1].ssh_base_argv == tuple(BASE + [DEST])
    assert gt.find_target(rows, "x86/backend") is rows[2]
    assert gt.find_target(rows, "") is rows[0]


@pytest.mark.parametrize("over, words", [
    ({"state": "stopped"}, "is not running — there is no channel to a stopped device"),
    ({"ssh_host_port": 0}, "published no ssh port — there is no channel to the device"),
    ({"ssh_key": ""}, "names no ssh key or user — there is no channel to the device"),
    ({"ssh_user": ""}, "names no ssh key or user — there is no channel to the device"),
    ({"role": "desktop"}, "is a desktop client — client images bake no go-live driver"),
    ({"role": "standalone-thin"}, "client images bake no go-live driver"),
    ({"platform": "frite", "role": "backend"}, "whose images bake no go-live driver"),
    ({"platform": "jetson", "role": "omnibus"}, "whose images bake no go-live driver"),
    ({"platform": "orangepi5", "role": "pki"}, "whose images bake no go-live driver"),
])
def test_refusal_sentences(over, words):
    assert words in gt.refusal(_target(**over))


def test_a_running_server_row_is_not_refused():
    assert gt.refusal(_target(), osname="posix") == ""
    assert gt.refusal(gt.local_target()) == ""
    assert gt.refusal(gt.local_target(), osname="nt") == ""


def test_the_docker_lane_stays_refused_on_native_windows():
    why = gt.refusal(_target(), osname="nt")
    assert "docker-lane device" in why and "WSL2" in why
    whpx = gt.target_from_whpx({"label": "x86/pki", "ssh_port": 2222, "ssh_key": "C:/k",
                                "ssh_user": "hugmesh"})
    assert gt.refusal(whpx, osname="nt") == ""


def test_whpx_without_ssh_key_is_refused_with_the_windows_ask():
    t = gt.target_from_whpx({"label": "x86/pki", "ssh_port": 2222, "pid": 1})
    why = gt.refusal(t)
    assert "QEMU for Windows" in why and "ssh_key and ssh_user" in why
    t2 = gt.target_from_whpx({"label": "x86/pki", "ssh_port": 2222, "ssh_key": "C:/k",
                              "ssh_user": "hugmesh"})
    assert gt.refusal(t2) == ""
    assert t2.ssh_base_argv[:5] == ("ssh", "-i", "C:/k", "-p", "2222")


def test_local_node_refusal_b1(tmp_path):
    why = gt.local_node_refusal(str(tmp_path), which=lambda n: None)
    assert why.startswith("this host is not a HugMesh node — pick a device")
    assert "release-state does not exist" in why and "not installed" in why
    (tmp_path / "release-state").write_text("internal\n")
    assert "not installed" in gt.local_node_refusal(str(tmp_path), which=lambda n: None)
    assert gt.local_node_refusal(str(tmp_path), which=lambda n: "/usr/sbin/" + n) == ""
    (tmp_path / "release-state").unlink()
    assert "release-state does not exist" in gt.local_node_refusal(
        str(tmp_path), which=lambda n: "/usr/sbin/" + n)


@pytest.mark.parametrize("ip, refused", [
    ("10.0.2.15", True), ("10.0.2.2", True), ("10.77.0.3", True),
    ("203.0.113.10", False), ("10.0.3.1", False), ("10.78.0.1", False),
    ("", False), ("not-an-ip", False)])
def test_refuse_private_ingress(ip, refused):
    why = gt.refuse_private_ingress(ip)
    assert bool(why) is refused
    if refused:
        assert "no registrar record can point at it" in why


def test_mechanism_reachability_is_honest_per_mechanism():
    t, local = _target(), gt.local_target()
    assert gt.mechanism_reachability("onion", t) == "can be really reachable (outbound only)"
    assert gt.mechanism_reachability("deeplink", t).startswith("can be really reachable")
    cf = gt.mechanism_reachability("deeplink", t, "cloudflare-tunnel")
    assert "PROD ExternalSecret" in cf and "tunnel will not start" in cf
    for m in ("files", "ddns", "instructions"):
        assert gt.mechanism_reachability(m, t).startswith("REHEARSAL — the posture flips")
    assert gt.mechanism_reachability("funnel", t) == "not on headscale"
    assert gt.mechanism_reachability("onion", local) == ""


# ── argv ─────────────────────────────────────────────────────────────────────────────
def test_remote_verb_argv_is_pinned():
    opts = GoLiveOptions(provider="byo-domain", domain="example.invalid",
                         ingress_ip="203.0.113.10", ddns_service="")
    assert gt.remote_verb_argv(_target(), "plan", opts) == BASE + BATCH + [
        DEST, "sudo -n hugmesh-go-live plan --provider byo-domain --domain "
              "example.invalid --ingress-ip 203.0.113.10"]
    assert gt.remote_verb_argv(_target(), "status") == BASE + BATCH + [
        DEST, "sudo -n hugmesh-go-live status"]


def test_remote_verb_argv_refuses_commit_and_rollback():
    for verb in ("commit", "rollback"):
        with pytest.raises(ValueError):
            gt.remote_verb_argv(_target(), verb)


def test_commit_and_rollback_are_ssh_t_and_never_yes():
    c = gt.commit_argv(_target(), "byo-domain", "example.invalid", persist_public=True)
    assert c == BASE + ["-t", DEST, "sudo hugmesh-go-live commit --provider byo-domain "
                                    "--domain example.invalid --persist-public"]
    r = gt.rollback_argv(_target(), revert_release_state=True)
    assert r == BASE + ["-t", DEST, "sudo hugmesh-go-live rollback --revert-release-state"]
    for argv in (c, r, gt.rollback_argv(_target())):
        toks = _all_argv_tokens([argv])
        assert "-y" not in toks and "--yes" not in toks
        assert "BatchMode=yes" not in toks            # the confirm needs the pty
        assert "GL_ASSUME_YES" not in " ".join(toks)


def test_commit_argv_refuses_shapes_that_would_reach_the_guest_shell():
    with pytest.raises(ValueError):
        gt.commit_argv(_target(), "byo-domain; reboot")
    with pytest.raises(ValueError):
        gt.commit_argv(_target(), "byo-domain", "example.org;id")


def test_probe_argv_is_one_posix_sh_round_trip():
    argv = gt.probe_argv(_target())
    assert argv[:-1] == BASE + BATCH + [DEST]
    assert shlex.split(argv[-1])[:4] == ["sudo", "-n", "sh", "-c"]
    script = shlex.split(argv[-1])[4]
    assert "[[" not in script and "$(<" not in script     # no bashisms
    # It really is valid POSIX sh: run it here. This host is no node, so every
    # section is empty, yet the answer is complete.
    sh = shutil.which("sh")
    if sh:
        out = subprocess.run([sh, "-c", script], capture_output=True, text=True).stdout
        assert gt.parse_probe(out).ok


def test_parse_probe_sections():
    text = ("::driver\n/usr/sbin/hugmesh-go-live\n::cluster-domain\nexample.org"
            "\n::domains\nexample.org\nshop.example.org\n::release-state\ninternal\n"
            f"::tor hostname\n{ONION}\n\n::tor shop.hostname\n{ONION2}\n::end\n")
    p = gt.parse_probe(text)
    assert p.ok and p.has_driver and p.cluster_domain == "example.org"
    assert p.domains_text.splitlines() == ["example.org", "shop.example.org"]
    assert p.onion_files == {"hostname": ONION, "shop.hostname": ONION2}
    assert p.release_state == "internal"


def test_parse_probe_without_driver_is_b8():
    p = gt.parse_probe("::driver\n::cluster-domain\n\n::end\n")
    assert p.ok and not p.has_driver
    assert "has no go-live driver" in gt.probe_refusal(_target(), p)
    assert "not a go-live server node" in gt.probe_refusal(_target(), p)
    cut = gt.parse_probe("::driver\n/usr/sbin/hugmesh-go-live\n")
    assert not cut.ok and gt.probe_refusal(_target(), cut)


# ── secret staging ───────────────────────────────────────────────────────────────────
def test_stage_token_goes_over_stdin_never_argv():
    run = FakeRun()
    path = gt.stage_token_remote(_target(), SECRET, run=run)
    assert path == "/run/hugmesh-golive-tok.Ab12Cd"
    argv, stdin = run.calls[0]
    assert SECRET not in " ".join(_all_argv_tokens([argv]))
    assert stdin == SECRET + "\n"
    script = shlex.split(argv[-1])[4]
    assert script.startswith("umask 077;") and "mktemp /run/hugmesh-golive-tok." in script


@pytest.mark.parametrize("bad", ["", "/tmp/x", "/run/hugmesh-golive-tok.ab; rm -rf /",
                                 "/run/hugmesh-golive-tok.", "/run/hugmesh-golive-tok.a/../b"])
def test_stage_token_refuses_an_unexpected_guest_path(bad):
    with pytest.raises(RuntimeError):
        gt.stage_token_remote(_target(), SECRET, run=FakeRun(stage_path=bad))


def _token_file(tmp_path):
    f = tmp_path / "tok"
    f.write_text(SECRET + "\n")
    return str(f)


def test_run_plan_stages_streams_removes_and_fetches(tmp_path):
    run, popen, lines = FakeRun(), FakePopen(), []
    opts = GoLiveOptions(provider="duckdns", domain="example.invalid", ddns_subdomain="home",
                         token_file=_token_file(tmp_path), keys_dir="/host/keys",
                         out_dir="/host/out")
    rc = gt.run_plan(_target(), opts, on_line=lines.append, work_dir=str(tmp_path),
                     popen=popen, run=run, stamp="20261109T000000Z")
    assert rc == 0
    plan = popen.record[0]
    assert plan[-1] == ("sudo -n hugmesh-go-live plan --provider duckdns --domain "
                        "example.invalid --ddns-service duckdns --ddns-subdomain home "
                        "--out-dir /var/lib/hugmesh/go-live/out/studio-20261109T000000Z "
                        "--token-file /run/hugmesh-golive-tok.Ab12Cd")
    assert "/host/keys" not in plan[-1] and str(tmp_path) not in plan[-1]
    every = [c[0] for c in run.calls] + popen.record
    assert SECRET not in " ".join(_all_argv_tokens(every))
    order = [c[0][-1] for c in run.calls]
    rm_at = next(i for i, r in enumerate(order) if " rm -f " in f" {r} ")
    assert "/run/hugmesh-golive-tok.Ab12Cd" in order[rm_at]
    assert "==> Rendering provider artifacts" in lines and "==> Plan summary ready" in lines
    local = tmp_path / "golive" / "rpi5_pki"
    assert sorted(os.listdir(local)) == ["dns-records.txt", "instructions.txt"]


def test_run_plan_removes_the_token_on_the_error_path(tmp_path):
    run, lines = FakeRun(), []
    popen = FakePopen(raise_on_start=OSError("ssh vanished"))
    rc = gt.run_plan(_target(), GoLiveOptions(provider="duckdns", ddns_subdomain="h",
                                              token_file=_token_file(tmp_path)),
                     on_line=lines.append, work_dir=str(tmp_path), popen=popen, run=run)
    assert rc != 0
    assert any(" rm -f -- /run/hugmesh-golive-tok.Ab12Cd" in f" {c[0][-1]}"
               for c in run.calls)
    assert any("ssh vanished" in ln for ln in lines)
    assert not (tmp_path / "golive").exists()             # nothing fetched after a failure


def test_run_plan_removes_the_token_when_the_plan_fails_and_says_when_rm_fails(tmp_path):
    run, lines = FakeRun(fail_rm=True), []
    rc = gt.run_plan(_target(), GoLiveOptions(provider="duckdns", ddns_subdomain="h",
                                              token_file=_token_file(tmp_path)),
                     on_line=lines.append, popen=FakePopen(rc=3), run=run)
    assert rc == 3
    assert any("could not delete the staged token" in ln for ln in lines)


def test_run_plan_refuses_before_anything_runs(tmp_path):
    run, popen, lines = FakeRun(), FakePopen(), []
    rc = gt.run_plan(_target(), GoLiveOptions(provider="byo-domain", ingress_ip="10.0.2.15"),
                     on_line=lines.append, popen=popen, run=run)
    assert rc == 2 and not run.calls and not popen.record
    assert "no registrar record" in lines[0]
    rc = gt.run_plan(_target(state="stopped"), GoLiveOptions(provider="byo-domain"),
                     on_line=lines.append, popen=popen, run=run)
    assert rc == 2 and not run.calls and not popen.record


def test_fetch_artifacts_skips_names_that_could_escape(tmp_path):
    run = FakeRun(listing="ok.txt\n../evil\n.hidden\nsub/dir\nalso-ok.json\n")
    local = tmp_path / "out"
    local.mkdir()
    (local / "stale.txt").write_text("old")
    got = gt.fetch_artifacts(_target(), gt.guest_out_dir("s"), str(local), run=run)
    assert sorted(os.path.basename(g) for g in got) == ["also-ok.json", "ok.txt"]
    assert sorted(os.listdir(local)) == ["also-ok.json", "ok.txt"]
    assert not (tmp_path / "evil").exists()
    with pytest.raises(ValueError):
        gt.fetch_artifacts(_target(), "/etc", str(local), run=run)


# ── terminals ────────────────────────────────────────────────────────────────────────
CMD = BASE + ["-t", DEST, "sudo hugmesh-go-live commit --provider byo-domain"]


def test_terminal_linux_uses_the_shared_list_and_holds_open():
    spec = gt.terminal_spec(CMD, osname="posix", which=lambda b: b == "konsole")
    assert spec.how == "linux" and spec.argv[:4] == ["konsole", "-e", "bash", "-c"]
    assert spec.argv[4].startswith(shlex.join(CMD) + "; rc=$?")


def test_terminal_ptyxis_and_kgx_are_in_the_shared_list():
    from hugmesh_studio.core.cloud_deploy import TERMINALS
    names = [b for b, _ in TERMINALS]
    assert names.index("gnome-terminal") < names.index("ptyxis") < names.index("kgx")
    assert dict(TERMINALS)["ptyxis"] == ("--",) and dict(TERMINALS)["kgx"] == ("--",)
    spec = gt.terminal_spec(CMD, osname="posix", which=lambda b: b == "kgx")
    assert spec.argv[:4] == ["kgx", "--", "bash", "-c"]


def test_terminal_wsl_windows_terminal_shape():
    have = {"cmd.exe", "wt.exe"}
    spec = gt.terminal_spec(CMD + ["; x"], osname="posix", is_wsl=True,
                            wsl_distro="Ubuntu", has_interop=True,
                            which=lambda b: b in have)
    assert spec.how == "wsl-wt"
    assert spec.argv[:9] == ["cmd.exe", "/c", "start", "", "wt.exe", "wsl.exe", "-d",
                             "Ubuntu", "--"]
    assert spec.argv[9:-1] == CMD and spec.argv[-1] == "\\; x"   # wt's ; escaped


def test_terminal_wsl_plain_console_without_wt():
    spec = gt.terminal_spec(CMD, osname="posix", is_wsl=True, wsl_distro="Ubuntu",
                            has_interop=True, which=lambda b: b == "cmd.exe")
    assert spec.how == "wsl-start"
    assert spec.argv == ["cmd.exe", "/c", "start", "", "wsl.exe", "-d", "Ubuntu", "--",
                         *CMD]


def test_terminal_wsl_without_interop_and_plain_linux_without_terminal_is_none():
    assert gt.terminal_spec(CMD, osname="posix", is_wsl=True, wsl_distro="U",
                            has_interop=False, which=lambda b: "x") is not None  # konsole..
    assert gt.terminal_spec(CMD, osname="posix", is_wsl=True, wsl_distro="U",
                            has_interop=False, which=lambda b: None) is None
    assert gt.terminal_spec(CMD, osname="posix", is_wsl=False,
                            which=lambda b: None) is None


def test_terminal_native_windows_is_a_new_console():
    spec = gt.terminal_spec(CMD, osname="nt", which=lambda b: None)
    assert spec.how == "nt" and spec.argv == CMD
    assert spec.creationflags == getattr(subprocess, "CREATE_NEW_CONSOLE", 0x10)


# ── journal ──────────────────────────────────────────────────────────────────────────
def test_journal_round_trip_has_no_secret_and_detects_a_restart(tmp_path):
    t = _target(tmp_path)
    path = gt.write_journal(t, "commit", "byo-domain", "example.invalid",
                            confirmed=True, now="2026-11-09T11:00:00Z")
    assert path == str(tmp_path / "golive" / "rpi5_pki.json")
    j = gt.read_journal(str(tmp_path), t.label)
    assert set(j) == {"label", "kind", "action", "provider", "domain", "started_at",
                      "at", "confirmed"}
    assert j["started_at"] == t.started_at
    assert not gt.reset_by_restart(j, t)
    assert "reset by a restart" not in gt.journal_status(str(tmp_path), t)
    rebooted = _target(tmp_path, started_at="2026-11-09T12:00:00Z")
    assert gt.reset_by_restart(j, rebooted)
    assert "reset by a restart" in gt.journal_status(str(tmp_path), rebooted)
    assert not gt.reset_by_restart(None, rebooted)
    assert not gt.reset_by_restart(j, gt.local_target())


# ── the driver, routed through a target ──────────────────────────────────────────────
@pytest.fixture
def remote_driver(tmp_path, monkeypatch):
    run = FakeRun(probe_text=PROBE_OK)
    monkeypatch.setattr("hugmesh_studio.core.golive_target.subprocess.run", run)
    monkeypatch.setattr("hugmesh_studio.core.golive_driver.subprocess.run", run)
    # this host's files must never be read for a remote target
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(tmp_path / "host-cd"))
    (tmp_path / "host-cd").write_text("host.example\n")
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(tmp_path / "no-tor"))
    monkeypatch.setenv("GL_ONION_HOSTNAME", "not-an-onion")
    d = GoLiveDriver(str(tmp_path), is_root=False, target=_target(tmp_path))
    return d, run


def test_remote_driver_reads_the_device_not_this_host(remote_driver):
    d, run = remote_driver
    assert d.remote and d.blocker() == ""
    assert d.autofill_domain() == "example.org"
    assert d.tor_domain_onions() == {"shop": ONION2}
    assert d.baked_domains() == ["example.org"]
    assert [p.id for p in d.providers()] == ["byo-domain", "tor-onion"]
    assert d.status_text() == "effective posture:   internal"
    rows = plan_rows(d, GoLiveOptions(provider="tor-onion"))
    text = "\n".join(f"{a} {b}" for a, b in rows)
    assert ONION in text and ONION2 in text
    assert "host.example" not in text and "GL_ONION_HOSTNAME" not in text
    probes = [c for c in run.calls if "::driver" in c[0][-1]]
    assert len(probes) == 1                                       # cached
    # every non-interactive ssh has its stdin closed: it must never read the GUI's
    for (argv, stdin), kw in zip(run.calls, run.kws):
        assert stdin is None and kw.get("stdin") is subprocess.DEVNULL, argv[-1]


def test_remote_driver_ignores_the_native_windows_blocker(remote_driver, monkeypatch):
    d, _run = remote_driver
    monkeypatch.setattr("hugmesh_studio.core.golive_driver.platform_info."
                        "native_windows_blocker", lambda *a, **k: "WINDOWS")
    assert d.blocker() == ""
    assert GoLiveDriver(d.generator_dir).blocker() == "WINDOWS"


def test_remote_driver_b8_when_the_guest_has_no_driver(tmp_path, monkeypatch):
    run = FakeRun(probe_text="::driver\n::cluster-domain\nexample.org\n::end\n")
    monkeypatch.setattr("hugmesh_studio.core.golive_target.subprocess.run", run)
    d = GoLiveDriver(str(tmp_path), target=_target(tmp_path))
    assert "has no go-live driver" in d.blocker()
    lines = []
    assert d.run("plan", GoLiveOptions(provider="byo-domain"), on_line=lines.append) == 2
    assert "has no go-live driver" in lines[0]


def test_remote_driver_command_and_commit_route_through_ssh(remote_driver):
    d, _run = remote_driver
    opts = GoLiveOptions(provider="byo-domain", domain="example.invalid", ddns_service="")
    assert d.command("status", GoLiveOptions(ddns_service="")) == BASE + BATCH + [
        DEST, "sudo -n hugmesh-go-live status"]
    assert d.commit_command(opts) == BASE + ["-t", DEST, "sudo hugmesh-go-live commit "
                                             "--provider byo-domain --domain example.invalid"]
    assert d.rollback_command() == BASE + ["-t", DEST, "sudo hugmesh-go-live rollback"]
    lines = []
    assert d.run("commit", opts, on_line=lines.append) == 2
    assert "needs a terminal" in lines[0]


def test_remote_commit_in_terminal_launches_ssh_t_and_journals(remote_driver, monkeypatch,
                                                               tmp_path):
    d, _run = remote_driver
    launched = []
    monkeypatch.setattr("hugmesh_studio.core.golive_target.shutil.which",
                        lambda b: "/usr/bin/konsole" if b == "konsole" else None)
    monkeypatch.setattr("hugmesh_studio.core.golive_driver.subprocess.Popen",
                        lambda argv, **kw: launched.append((argv, kw)))
    ok, msg = d.run_commit_in_terminal(GoLiveOptions(provider="byo-domain",
                                                     domain="example.invalid"))
    assert ok and "CONFIRM" in msg
    argv, _kw = launched[0]
    assert argv[:4] == ["konsole", "-e", "bash", "-c"]
    assert " -t hugmesh@127.0.0.1 " in argv[4]
    assert "-y" not in shlex.split(argv[4]) and "--yes" not in argv[4]
    j = gt.read_journal(str(tmp_path), "rpi5/pki")
    assert j["action"] == "commit" and j["provider"] == "byo-domain"


def test_local_commit_off_node_is_refused_b1(tmp_path, monkeypatch):
    monkeypatch.setattr("hugmesh_studio.core.golive_driver.platform_info."
                        "native_windows_blocker", lambda *a, **k: "")
    monkeypatch.setenv("GL_ETC_HUGMESH", str(tmp_path / "no-etc"))
    monkeypatch.setattr("hugmesh_studio.core.golive_target._which_sbin", lambda n: None)
    launched = []
    monkeypatch.setattr("hugmesh_studio.core.golive_driver.subprocess.Popen",
                        lambda *a, **k: launched.append(a))
    ok, msg = GoLiveDriver(str(tmp_path)).run_commit_in_terminal(
        GoLiveOptions(provider="byo-domain", domain="example.org"))
    assert not ok and not launched
    assert msg.startswith("this host is not a HugMesh node — pick a device")


def test_preflight_flags_a_private_ingress_ip(tmp_path):
    problems = GoLiveDriver(str(tmp_path)).preflight(
        GoLiveOptions(provider="byo-domain", domain="example.org", ingress_ip="10.77.0.4"))
    assert any("no registrar record can point at it" in p for p in problems)


# ── CLI ──────────────────────────────────────────────────────────────────────────────
def _cli(argv, **kw):
    out = io.StringIO()
    args = gt._parser("t").parse_args(argv)
    return gt.run_cli(args, out=out, **kw), out.getvalue()


def test_cli_targets_lists_refusals(tmp_path):
    work = _work(tmp_path, _record(), _record(label="rpi5/desk", role="desktop"))
    rc, out = _cli(["targets", "--work", work, "--generator-dir", str(tmp_path)])
    assert rc == 0
    assert "rpi5/pki" in out and "client images bake no go-live driver" in out
    assert gt.LOCAL_LABEL in out


def test_cli_commit_needs_a_tty_and_never_says_yes(tmp_path, monkeypatch):
    work = _work(tmp_path, _record())
    run = FakeRun(probe_text=PROBE_OK)
    monkeypatch.setattr("hugmesh_studio.core.golive_target.subprocess.run", run)
    calls = []
    base = ["commit", "--target", "rpi5/pki", "--work", work, "--generator-dir",
            str(tmp_path), "--provider", "byo-domain", "--domain", "example.invalid"]
    rc, out = _cli(base, call=lambda a: calls.append(a) or 0, isatty=lambda: False)
    assert rc == 2 and not calls and "needs a terminal" in out
    rc, out = _cli(base, call=lambda a: calls.append(a) or 0, isatty=lambda: True)
    assert rc == 0
    assert calls[0] == BASE + ["-t", DEST, "sudo hugmesh-go-live commit --provider "
                                           "byo-domain --domain example.invalid"]
    j = gt.read_journal(work, "rpi5/pki")
    assert j["confirmed"] is True and j["domain"] == "example.invalid"


def test_cli_plan_keeps_the_token_off_argv(tmp_path, monkeypatch):
    work = _work(tmp_path, _record())
    run = FakeRun(probe_text=PROBE_OK)
    record = []
    monkeypatch.setattr("hugmesh_studio.core.golive_target.subprocess.run", run)
    monkeypatch.setattr("hugmesh_studio.core.golive_target.subprocess.Popen",
                        FakePopen(record=record))
    rc, out = _cli(["plan", "--target", "rpi5/pki", "--work", work, "--generator-dir",
                    str(tmp_path), "--provider", "duckdns", "--ddns-subdomain", "home",
                    "--token-file", _token_file(tmp_path)])
    assert rc == 0, out
    assert SECRET not in " ".join(_all_argv_tokens([c[0] for c in run.calls] + record))
    assert any(c[1] == SECRET + "\n" for c in run.calls)
    assert "==> Plan summary ready" in out


def test_studio_cli_hook_parses(tmp_path):
    import argparse
    ap = argparse.ArgumentParser()
    gt.add_cli_arguments(ap)
    ns = ap.parse_args(["--go-live-target", "targets", "--work", str(tmp_path)])
    assert ns.go_live_target == ["targets", "--work", str(tmp_path)]


def test_hugmesh_studio_cli_reaches_the_target_cli_without_qt(tmp_path, monkeypatch):
    """``hugmesh-studio --go-live-target …`` (the MSI's console twin) runs this module's
    own parser; options after the verb belong to it, never to the Studio's."""
    import sys
    from hugmesh_studio import app
    work = _work(tmp_path, _record())
    out = io.StringIO()
    monkeypatch.setattr(sys, "stdout", out)
    assert app.main(["--generator-dir", str(tmp_path), "--go-live-target", "targets",
                     "--work", work, "--json"]) == 0
    rows = json.loads(out.getvalue())
    assert [r["label"] for r in rows] == [gt.LOCAL_LABEL, "rpi5/pki"]


def test_the_target_cli_loads_no_qt_binding(tmp_path):
    """A fresh interpreter: the whole --go-live-target path imports no Qt binding."""
    import sys
    work = _work(tmp_path, _record())
    code = ("import sys; from hugmesh_studio import app; "
            f"rc = app.main(['--generator-dir', {str(tmp_path)!r}, '--go-live-target', "
            f"'targets', '--work', {work!r}]); "
            "qt = [m for m in sys.modules if m.split('.')[0] in "
            "('PyQt5', 'PyQt6', 'PySide2', 'PySide6')]; "
            "print('QT=' + ','.join(qt)); sys.exit(rc)")
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    r = subprocess.run([sys.executable, "-c", code], cwd=root, capture_output=True,
                       text=True, timeout=120)
    assert r.returncode == 0, r.stderr
    assert "QT=\n" in r.stdout and "rpi5/pki" in r.stdout
