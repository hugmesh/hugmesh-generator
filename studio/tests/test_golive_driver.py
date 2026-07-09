"""GoLiveDriver command assembly, catalog display parse, streaming and secret
staging — no Qt, no engine runs (subprocess is faked wherever it would execute).

The driver must stay a pure flag-speller for scripts/go-live.sh (the engine) —
these tests pin the argv it assembles, that secrets never enter that argv, and
that the display-only catalog parse agrees with the REAL repo catalog.
"""
import os
import shlex
import stat
import subprocess

import pytest

from snapdragon_studio.core.golive_driver import (
    GoLiveDriver, GoLiveOptions, CATALOG_REL, ENGINE_REL,
)

# studio/tests/ -> studio/ -> the generator repo root (the real engine + catalog)
GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def full_opts(tmp_path):
    tok = tmp_path / "tok"
    tok.write_text("secret\n")
    return GoLiveOptions(provider="ddns", domain="example.org", record_ip="203.0.113.7",
                         tunnel_id="uuid-1", ddns_service="duckdns", ddns_subdomain="home",
                         out_dir=str(tmp_path / "out"), keys_dir=str(tmp_path / "keys"),
                         token_file=str(tok))


# ---- command assembly ---------------------------------------------------------

def test_command_assembly_and_flag_order(tmp_path):
    d = GoLiveDriver(str(tmp_path), is_root=False)
    opts = full_opts(tmp_path)
    cmd = d.command(opts, ["--emit"])
    assert cmd[:2] == ["bash", f"./{ENGINE_REL}"]
    # same flag order as the console menu's base_flags() — previews read identically
    assert cmd[2:] == ["--provider", "ddns", "--domain", "example.org",
                       "--record-ip", "203.0.113.7", "--tunnel-id", "uuid-1",
                       "--ddns-service", "duckdns", "--ddns-subdomain", "home",
                       "--out", str(tmp_path / "out"), "--keys-dir", str(tmp_path / "keys"),
                       "--token-file", str(tmp_path / "tok"), "--emit"]


def test_command_carries_token_paths_never_values(tmp_path):
    """Secrets reach the engine as FILE PATHS only (--token-file) — the secret
    value has no field on GoLiveOptions at all, so no argv can ever contain it."""
    d = GoLiveDriver(str(tmp_path), is_root=False)
    opts = full_opts(tmp_path)
    assert "secret" not in " ".join(d.command(opts, ["--emit"]))
    assert not hasattr(opts, "token")
    # token files are droppable for actions that never need them (verify/flip)
    cmd = d.command(opts, ["--verify"], include_token_files=False)
    assert "--token-file" not in cmd and "--cf-api-token-file" not in cmd


def test_empty_options_emit_only_the_ddns_service_default(tmp_path):
    # mirrors the menu: ddns-service always has a value (duckdns default), all
    # other unset options stay off the argv so the engine's own defaults apply
    cmd = GoLiveDriver(str(tmp_path)).command(GoLiveOptions(), ["--status"])
    assert cmd == ["bash", f"./{ENGINE_REL}", "--ddns-service", "duckdns", "--status"]


def test_command_string_is_shell_quoted(tmp_path):
    d = GoLiveDriver(str(tmp_path), is_root=False)
    opts = GoLiveOptions(provider="ddns", domain="example.org",
                         out_dir=str(tmp_path / "my out"))
    s = d.command_string(opts, ["--emit"])
    assert f"./{ENGINE_REL}" in s
    assert f"'{tmp_path}/my out'" in s


# ---- catalog display parse (against the REAL repo catalog) ---------------------

def test_catalog_parse_matches_the_real_repo_catalog():
    d = GoLiveDriver(GENERATOR_DIR)
    assert os.path.exists(os.path.join(GENERATOR_DIR, *CATALOG_REL.split("/")))
    ids = [p.id for p in d.providers()]
    assert ids == ["cloudflare-tunnel", "registrar-manual", "ddns",
                   "tailscale-funnel", "router-manual"]
    cf = d.provider("cloudflare-tunnel")
    assert cf.model == "tunnel"
    assert cf.inputs == ["token"]
    assert cf.optional == ["cf-api-token", "tunnel-id"]
    assert cf.token_dest == "cloudflared/tunnel-token"
    assert cf.emits == ["checklist", "records-csv"]
    assert cf.verify == ["dns", "http", "tunnel"]
    assert len(cf.links) == 3 and all(u.startswith("http") for u, _ in cf.links)
    assert any("ENV=prod" in n for n in cf.notes)
    # empty token_dest rows (registrar-manual) parse to "" — not a stray "="
    assert d.provider("registrar-manual").token_dest == ""
    assert d.provider("tailscale-funnel").inputs == []


def test_models_are_unique_and_in_catalog_order():
    d = GoLiveDriver(GENERATOR_DIR)
    assert d.models() == ["tunnel", "public-dns", "ddns", "funnel", "router"]


def test_provider_needs_and_offers():
    d = GoLiveDriver(GENERATOR_DIR)
    ddns = d.provider("ddns")
    assert ddns.needs("token") and ddns.needs("subdomain")
    assert not ddns.needs("record-ip") and ddns.offers("record-ip")
    assert d.provider("nope") is None


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

def test_run_streams_lines_from_the_engine(monkeypatch, tmp_path):
    d = GoLiveDriver(str(tmp_path), is_root=False)
    seen = {}

    class FakeProc:
        stdout = iter(["[go-live] record set -> out/records.csv", "[go-live] emit done"])

        def wait(self):
            return 0

        def poll(self):
            return 0

    def fake_popen(cmd, **kwargs):
        seen["cmd"] = cmd
        seen["cwd"] = kwargs.get("cwd")
        return FakeProc()

    monkeypatch.setattr("snapdragon_studio.core.golive_driver.subprocess.Popen", fake_popen)
    lines = []
    code = d.run(GoLiveOptions(provider="registrar-manual", domain="example.org",
                               record_ip="203.0.113.7"), ["--emit"], on_line=lines.append)
    assert code == 0
    assert seen["cmd"][:2] == ["bash", f"./{ENGINE_REL}"]
    assert "--emit" in seen["cmd"]
    assert seen["cwd"] == d.generator_dir
    assert lines == ["[go-live] record set -> out/records.csv", "[go-live] emit done"]


def test_status_text_strips_ansi(monkeypatch, tmp_path):
    def fake_run(cmd, **kwargs):
        assert cmd[:2] == ["bash", f"./{ENGINE_REL}"] and "--status" in cmd
        return subprocess.CompletedProcess(cmd, 0, stdout="\x1b[1mGo-live status\x1b[0m\n  posture: INTERNAL\n")

    monkeypatch.setattr("snapdragon_studio.core.golive_driver.subprocess.run", fake_run)
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


# ---- flip / rollback (terminal path) ----------------------------------------------

def test_flip_command_sudo_flags_and_no_secrets(tmp_path):
    opts = full_opts(tmp_path)
    cmd = GoLiveDriver(str(tmp_path), is_root=False).flip_command(opts, persist=True)
    assert cmd[:3] == ["sudo", "bash", f"./{ENGINE_REL}"]
    assert cmd[-2:] == ["--flip", "--persist"]
    assert "--token-file" not in cmd            # the flip never needs a secret
    assert ("--domain", "example.org") in zip(cmd, cmd[1:])
    root_cmd = GoLiveDriver(str(tmp_path), is_root=True).flip_command(opts)
    assert root_cmd[0] == "bash" and root_cmd[-1] == "--flip"


def test_rollback_command_is_minimal(tmp_path):
    cmd = GoLiveDriver(str(tmp_path), is_root=False).rollback_command(persist=True)
    assert cmd == ["sudo", "bash", f"./{ENGINE_REL}", "--rollback", "--persist"]


def test_terminal_command_picks_the_first_available(monkeypatch, tmp_path):
    d = GoLiveDriver(str(tmp_path), is_root=True)
    monkeypatch.setattr("snapdragon_studio.core.golive_driver.shutil.which",
                        lambda b: "/usr/bin/konsole" if b == "konsole" else None)
    cmd = d.terminal_command(["bash", "./scripts/go-live.sh", "--flip"])
    assert cmd[:2] == ["konsole", "-e"]
    assert cmd[2:4] == ["bash", "-c"]
    assert shlex.join(["bash", "./scripts/go-live.sh", "--flip"]) in cmd[4]


def test_run_flip_without_a_terminal_reports_the_manual_command(monkeypatch, tmp_path):
    d = GoLiveDriver(str(tmp_path), is_root=True)
    monkeypatch.setattr("snapdragon_studio.core.golive_driver.shutil.which", lambda b: None)
    ok, msg = d.run_flip_in_terminal(GoLiveOptions(domain="example.org"))
    assert not ok
    assert "yourself: " in msg and "--flip" in msg and "example.org" in msg


# ---- preflight ---------------------------------------------------------------------

def test_preflight_flags_a_missing_engine(monkeypatch, tmp_path):
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(tmp_path / "missing"))
    problems = GoLiveDriver(str(tmp_path)).preflight(
        GoLiveOptions(provider="ddns"), ["--emit"])
    assert any("engine not found" in p for p in problems)
    assert any("catalog not found" in p for p in problems)
    assert any("Domain is required" in p for p in problems)


def test_preflight_reads_requirements_from_the_catalog(monkeypatch):
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", "/nonexistent")
    d = GoLiveDriver(GENERATOR_DIR)
    opts = GoLiveOptions(provider="ddns", domain="example.org")
    problems = d.preflight(opts, ["--emit"])
    assert any("needs a token" in p for p in problems)
    assert any("DDNS subdomain" in p for p in problems)
    # a masked-field secret (staged at run time) satisfies the token requirement
    opts.ddns_subdomain = "home"
    assert d.preflight(opts, ["--emit"], has_secret=True) == []


def test_preflight_registrar_needs_ip_or_tunnel(monkeypatch):
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", "/nonexistent")
    d = GoLiveDriver(GENERATOR_DIR)
    opts = GoLiveOptions(provider="registrar-manual", domain="example.org")
    assert any("record IP" in p for p in d.preflight(opts, ["--emit"]))
    opts.tunnel_id = "uuid-1"
    assert d.preflight(opts, ["--emit"]) == []


def test_preflight_create_dns_requirements(monkeypatch):
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", "/nonexistent")
    d = GoLiveDriver(GENERATOR_DIR)
    opts = GoLiveOptions(provider="cloudflare-tunnel", domain="example.org")
    problems = d.preflight(opts, ["--emit", "--create-dns"], has_secret=True)
    assert any("tunnel UUID" in p for p in problems)
    assert any("Cloudflare API token" in p for p in problems)
    opts.tunnel_id = "uuid-1"
    assert d.preflight(opts, ["--emit", "--create-dns"],
                       has_secret=True, has_cf_secret=True) == []


def test_preflight_flags_dangling_token_files(monkeypatch, tmp_path):
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", "/nonexistent")
    d = GoLiveDriver(GENERATOR_DIR)
    opts = GoLiveOptions(provider="ddns", domain="example.org", ddns_subdomain="home",
                         token_file=str(tmp_path / "gone"))
    assert any("does not exist" in p for p in d.preflight(opts, ["--emit"]))
