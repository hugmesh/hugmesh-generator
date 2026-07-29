"""GoLiveDriver command assembly, provider load (via the driver's `list`),
streaming, secret staging and the commit/rollback terminal path — no Qt.

After the go-live consolidation the Studio front-end is a THIN caller of the
CANONICAL driver specs/usr/sbin/hugmesh-go-live (subcommands
status|list|plan|commit|rollback), NOT the removed #286 engine scripts/go-live.sh.
These tests pin the argv it assembles (subcommand + flags), that secrets never
enter that argv, that the commit/rollback path adds NO -y/--yes bypass, and that
the provider load agrees with the REAL in-repo driver + registry.

Some tests shell out to the real driver via bash (no Qt, no posture mutation —
`list`/`status` are read-only); they are skipped if bash is unavailable.
"""
import os
import shlex
import shutil
import stat
import subprocess

import pytest

from hugmesh_studio.core.golive_driver import (
    GoLiveDriver, GoLiveOptions, DRIVER_REL, REGISTRY_REL,
)

# studio/tests/ -> studio/ -> the generator repo root (the real driver + registry)
GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

requires_bash = pytest.mark.skipif(shutil.which("bash") is None, reason="bash not available")


def full_opts(tmp_path):
    tok = tmp_path / "tok"
    tok.write_text("secret\n")
    return GoLiveOptions(provider="duckdns", domain="example.org", ingress_ip="203.0.113.7",
                         tunnel_cname="uuid-1.cfargotunnel.com", ddns_service="duckdns",
                         ddns_subdomain="home", out_dir=str(tmp_path / "out"),
                         keys_dir=str(tmp_path / "keys"), token_file=str(tok))


# ---- command assembly ---------------------------------------------------------

def test_command_is_subcommand_first_then_flags(tmp_path):
    d = GoLiveDriver(str(tmp_path), is_root=False)
    opts = full_opts(tmp_path)
    cmd = d.command("plan", opts)
    # subcommand comes FIRST (driver contract), after `bash ./<driver>`
    assert cmd[:3] == ["bash", f"./{DRIVER_REL}", "plan"]
    assert cmd[3:] == ["--provider", "duckdns", "--domain", "example.org",
                       "--ingress-ip", "203.0.113.7",
                       "--tunnel-cname", "uuid-1.cfargotunnel.com",
                       "--ddns-service", "duckdns", "--ddns-subdomain", "home",
                       "--out-dir", str(tmp_path / "out"),
                       "--keys-dir", str(tmp_path / "keys"),
                       "--token-file", str(tmp_path / "tok")]


def test_command_carries_token_paths_never_values(tmp_path):
    """Secrets reach the driver as FILE PATHS only (--token-file) — the secret
    value has no field on GoLiveOptions at all, so no argv can ever contain it."""
    d = GoLiveDriver(str(tmp_path), is_root=False)
    opts = full_opts(tmp_path)
    assert "secret" not in " ".join(d.command("plan", opts))
    assert not hasattr(opts, "token")
    # token files are droppable for actions that never need them
    cmd = d.command("plan", opts, include_token_file=False)
    assert "--token-file" not in cmd


def test_empty_options_emit_only_the_ddns_service_default(tmp_path):
    # ddns-service always has a value (duckdns default); every other unset option
    # stays off the argv so the driver's own defaults apply
    cmd = GoLiveDriver(str(tmp_path)).command("plan", GoLiveOptions())
    assert cmd == ["bash", f"./{DRIVER_REL}", "plan", "--ddns-service", "duckdns"]


def test_command_string_is_shell_quoted(tmp_path):
    d = GoLiveDriver(str(tmp_path), is_root=False)
    opts = GoLiveOptions(provider="byo-domain", domain="example.org",
                         out_dir=str(tmp_path / "my out"))
    s = d.command_string("plan", opts)
    assert f"./{DRIVER_REL}" in s and " plan " in s
    assert f"'{tmp_path}/my out'" in s


# ---- provider load (against the REAL in-repo driver + registry) -----------------

@requires_bash
def test_providers_come_from_the_real_driver_list():
    d = GoLiveDriver(GENERATOR_DIR)
    assert os.path.exists(os.path.join(GENERATOR_DIR, *DRIVER_REL.split("/")))
    assert os.path.exists(os.path.join(GENERATOR_DIR, *REGISTRY_REL.split("/")))
    ids = [p.id for p in d.providers()]
    assert ids == ["cloudflare-tunnel", "byo-domain", "duckdns",
                   "tailscale-funnel", "router-portforward", "tor-onion"]
    cf = d.provider("cloudflare-tunnel")
    assert cf.mechanism == "deeplink" and cf.model == "tunnel" and cf.status == "full"
    assert cf.needs("token") and cf.offers("tunnel-cname") and not cf.offers("ingress-ip")
    byo = d.provider("byo-domain")
    assert byo.mechanism == "files" and byo.model == "public-dns"
    assert byo.offers("ingress-ip") and byo.offers("tunnel-cname") and not byo.needs("token")
    assert d.provider("tailscale-funnel").inputs == []
    # tor-onion: its own mechanism/model, takes NO inputs (not even a domain).
    tor = d.provider("tor-onion")
    assert tor.mechanism == "onion" and tor.model == "onion" and tor.status == "full"
    assert tor.inputs == [] and tor.optional == []
    assert d.provider("nope") is None


@requires_bash
def test_models_are_unique_and_in_registry_order():
    d = GoLiveDriver(GENERATOR_DIR)
    assert d.models() == ["tunnel", "public-dns", "ddns", "funnel", "router", "onion"]


@requires_bash
def test_ddns_provider_needs_token_and_subdomain():
    ddns = GoLiveDriver(GENERATOR_DIR).provider("duckdns")
    assert ddns.mechanism == "ddns"
    assert ddns.needs("token") and ddns.needs("subdomain")
    assert ddns.offers("ddns-service") and not ddns.needs("ingress-ip")


# ---- CLUSTER_DOMAIN autofill -----------------------------------------------------

def test_autofill_domain_reads_the_baked_file(monkeypatch, tmp_path):
    bake = tmp_path / "cluster-domain"
    bake.write_text(" example.org \n")
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(bake))
    assert GoLiveDriver(str(tmp_path)).autofill_domain() == "example.org"


def test_autofill_domain_empty_when_no_bake(monkeypatch, tmp_path):
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(tmp_path / "missing"))
    assert GoLiveDriver(str(tmp_path)).autofill_domain() == ""


# ---- streaming (Popen faked — mirrors test_build_driver's pattern) ---------------

def test_run_streams_lines_from_the_driver(monkeypatch, tmp_path):
    d = GoLiveDriver(str(tmp_path), is_root=False)
    seen = {}

    class FakeProc:
        stdout = iter(["[go-live] record set -> out/records.csv", "[go-live] plan done"])

        def wait(self):
            return 0

        def poll(self):
            return 0

    def fake_popen(cmd, **kwargs):
        seen["cmd"] = cmd
        seen["cwd"] = kwargs.get("cwd")
        return FakeProc()

    monkeypatch.setattr("hugmesh_studio.core.golive_driver.subprocess.Popen", fake_popen)
    lines = []
    code = d.run("plan", GoLiveOptions(provider="byo-domain", domain="example.org",
                                       ingress_ip="203.0.113.7"), on_line=lines.append)
    assert code == 0
    assert seen["cmd"][:3] == ["bash", f"./{DRIVER_REL}", "plan"]
    assert seen["cwd"] == d.generator_dir
    assert lines == ["[go-live] record set -> out/records.csv", "[go-live] plan done"]


@requires_bash
def test_tor_onion_plan_emits_the_onion_and_needs_no_domain(tmp_path, monkeypatch):
    """The tor-onion provider (mechanism `onion`) runs through the REAL driver: it
    reads GL_ONION_HOSTNAME, writes onion.txt with that address, and — unlike every
    other provider — passes preflight with NO domain (the .onion IS the endpoint)."""
    d = GoLiveDriver(GENERATOR_DIR)
    onion = "txljwl7mdg7t3wmqdci77ttof5ikxeqg2epmfadzfxlzxvjgtx5k4fad.onion"
    monkeypatch.setenv("GL_ONION_HOSTNAME", onion)
    # no cluster-domain bake to autofill from, and no --domain supplied
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(tmp_path / "missing"))
    out = tmp_path / "out"
    opts = GoLiveOptions(provider="tor-onion", out_dir=str(out))
    assert d.preflight(opts) == []                     # domain NOT required for onion
    code = d.run("plan", opts)
    assert code == 0
    assert (out / "onion.txt").read_text().strip() == onion
    instructions = (out / "instructions.txt").read_text()
    assert "NO public" in instructions and "--with-tor" in instructions
    # a real domain-bearing provider still fails preflight with no domain
    assert d.preflight(GoLiveOptions(provider="byo-domain",
                                     out_dir=str(out))) != []


def test_status_text_strips_ansi(monkeypatch, tmp_path):
    def fake_run(cmd, **kwargs):
        assert cmd == ["bash", f"./{DRIVER_REL}", "status"]
        return subprocess.CompletedProcess(cmd, 0, stdout="\x1b[1mGo-live status\x1b[0m\n  posture: INTERNAL\n")

    monkeypatch.setattr("hugmesh_studio.core.golive_driver.subprocess.run", fake_run)
    assert GoLiveDriver(str(tmp_path)).status_text() == "Go-live status\n  posture: INTERNAL"


# ---- secret staging ---------------------------------------------------------------

def test_stage_token_writes_0600_and_the_exact_value(tmp_path, monkeypatch):
    monkeypatch.setenv("TMPDIR", str(tmp_path))
    path = GoLiveDriver.stage_token("s3cr3t-value")
    try:
        assert open(path).read() == "s3cr3t-value\n"
        assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    finally:
        os.unlink(path)


# ---- commit / rollback (terminal path — NO -y/--yes bypass) ------------------------

def test_commit_command_sudo_no_yes_no_secrets(tmp_path):
    opts = full_opts(tmp_path)
    cmd = GoLiveDriver(str(tmp_path), is_root=False).commit_command(opts, persist=True)
    assert cmd[:4] == ["sudo", "bash", f"./{DRIVER_REL}", "commit"]
    assert cmd[-1:] == ["--persist-public"]
    assert ("--provider", "duckdns") in zip(cmd, cmd[1:])
    assert ("--domain", "example.org") in zip(cmd, cmd[1:])
    # the commit gate must run on the TTY — the front-end adds NO bypass
    assert "-y" not in cmd and "--yes" not in cmd
    assert "--token-file" not in cmd            # commit never needs a secret
    root_cmd = GoLiveDriver(str(tmp_path), is_root=True).commit_command(opts)
    assert root_cmd[:3] == ["bash", f"./{DRIVER_REL}", "commit"]
    assert "--provider" in root_cmd
    assert "--persist-public" not in root_cmd   # persist defaults off


def test_rollback_command_is_minimal_and_no_yes(tmp_path):
    cmd = GoLiveDriver(str(tmp_path), is_root=False).rollback_command(revert_release_state=True)
    assert cmd == ["sudo", "bash", f"./{DRIVER_REL}", "rollback", "--revert-release-state"]
    plain = GoLiveDriver(str(tmp_path), is_root=True).rollback_command()
    assert plain == ["bash", f"./{DRIVER_REL}", "rollback"]
    assert "-y" not in cmd and "--yes" not in cmd


def test_terminal_command_picks_the_first_available(monkeypatch, tmp_path):
    d = GoLiveDriver(str(tmp_path), is_root=True)
    monkeypatch.setattr("hugmesh_studio.core.golive_driver.shutil.which",
                        lambda b: "/usr/bin/konsole" if b == "konsole" else None)
    inner = ["bash", f"./{DRIVER_REL}", "commit", "--provider", "byo-domain"]
    cmd = d.terminal_command(inner)
    assert cmd[:2] == ["konsole", "-e"]
    assert cmd[2:4] == ["bash", "-c"]
    assert shlex.join(inner) in cmd[4]


def test_run_commit_without_a_terminal_reports_the_manual_command(monkeypatch, tmp_path):
    d = GoLiveDriver(str(tmp_path), is_root=True)
    monkeypatch.setattr("hugmesh_studio.core.golive_driver.shutil.which", lambda b: None)
    ok, msg = d.run_commit_in_terminal(GoLiveOptions(provider="byo-domain", domain="example.org"))
    assert not ok
    assert "yourself: " in msg and "commit" in msg and "example.org" in msg


# ---- preflight ---------------------------------------------------------------------

def test_preflight_flags_a_missing_driver(monkeypatch, tmp_path):
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(tmp_path / "missing"))
    problems = GoLiveDriver(str(tmp_path)).preflight(GoLiveOptions(provider="duckdns"))
    assert any("driver not found" in p for p in problems)
    assert any("registry not found" in p for p in problems)
    assert any("Domain is required" in p for p in problems)


@requires_bash
def test_preflight_reads_requirements_from_the_registry(monkeypatch):
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", "/nonexistent")
    d = GoLiveDriver(GENERATOR_DIR)
    opts = GoLiveOptions(provider="duckdns", domain="example.org")
    problems = d.preflight(opts)
    assert any("needs a token" in p for p in problems)
    assert any("DDNS subdomain" in p for p in problems)
    # a masked-field secret (staged at run time) + a valid label satisfy the reqs
    opts.ddns_subdomain = "home"
    assert d.preflight(opts, has_secret=True) == []


@requires_bash
def test_preflight_rejects_a_bad_ddns_label(monkeypatch):
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", "/nonexistent")
    d = GoLiveDriver(GENERATOR_DIR)
    opts = GoLiveOptions(provider="duckdns", domain="example.org",
                         ddns_subdomain="bad.label")   # dot -> driver rejects
    assert any("single lowercase DNS label" in p for p in d.preflight(opts, has_secret=True))


@requires_bash
def test_preflight_files_warns_without_a_target(monkeypatch):
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", "/nonexistent")
    d = GoLiveDriver(GENERATOR_DIR)
    opts = GoLiveOptions(provider="byo-domain", domain="example.org")
    assert any("PLACEHOLDERS" in p for p in d.preflight(opts))
    opts.ingress_ip = "203.0.113.7"
    assert d.preflight(opts) == []


@requires_bash
def test_preflight_rejects_a_bad_ingress_ip(monkeypatch):
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", "/nonexistent")
    d = GoLiveDriver(GENERATOR_DIR)
    opts = GoLiveOptions(provider="byo-domain", domain="example.org", ingress_ip="not-an-ip")
    assert any("valid IPv4" in p for p in d.preflight(opts))


def test_preflight_flags_dangling_token_files(monkeypatch, tmp_path):
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", "/nonexistent")
    # driver/registry existence is checked against the real repo so only the token
    # file problem is asserted here
    d = GoLiveDriver(GENERATOR_DIR)
    opts = GoLiveOptions(provider="duckdns", domain="example.org", ddns_subdomain="home",
                         token_file=str(tmp_path / "gone"))
    assert any("does not exist" in p for p in d.preflight(opts))
