"""Tor v3 onion for the LOCAL docker mesh (the 2026-07-18 operator ask
"make sure starting the local docker mesh with tor is possible", "native and with
docker cross-platform").

Pins the wiring end-to-end WITHOUT bringing up docker (nobuild):
  1. TOR gate: with_tor -> TOR=1 in the make-env (the Makefile's STACK_TOR_PROFILE
     adds `--profile tor`); OFF is byte-identical to before (no way to turn Tor on by accident).
  2. onion readout: LocalStackNode reads the PUBLIC hostname the hugmesh-tor
     service copies to tests/stack/tor-onion/hostname; absent => "" (never raises).
  3. config -> stack threading + the plan text + up() reporting the address.
  4. TEXTUAL pins on the real Makefile / compose / build context so a refactor
     cannot silently drop the profile, the service, or its multi-arch build.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core.local_mesh_bootstrap import (   # noqa: E402
    LocalMeshBootstrap, LocalMeshBootstrapConfig)
from hugmesh_studio.core.local_stack_node import LocalStackNode  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


# ── 1. the TOR make-env gate ─────────────────────────────────────────────────────
def test_with_tor_sets_the_make_profile_env_and_off_is_byte_identical():
    on = LocalStackNode(GENERATOR_DIR, with_tor=True)._build_env()
    off = LocalStackNode(GENERATOR_DIR, with_tor=False)._build_env()
    plain = LocalStackNode(GENERATOR_DIR)._build_env()
    assert on["TOR"] == "1"
    assert off["TOR"] == ""            # explicit off — neutralises an inherited TOR=1
    assert off == plain                # default is byte-identical to not passing it


# ── 2. the onion hostname readout ────────────────────────────────────────────────
def test_onion_hostname_reads_the_published_file(tmp_path, monkeypatch):
    node = LocalStackNode(str(tmp_path))
    assert node.onion_hostname() == ""          # nothing published yet
    assert node.onion_url() == ""
    hostfile = tmp_path / "tests" / "stack" / "tor-onion" / "hostname"
    hostfile.parent.mkdir(parents=True)
    hostfile.write_text("txljwl7mdg7t3wmqdci77ttof5ikxeqg2epmfadzfxlzxvjgtx5k4fad.onion\n")
    assert node.onion_hostname() == \
        "txljwl7mdg7t3wmqdci77ttof5ikxeqg2epmfadzfxlzxvjgtx5k4fad.onion"
    # the URL is handed out only for a copy written by a RUNNING tor container (#581)
    monkeypatch.setattr(LocalStackNode, "_tor_started_at",
                        lambda self: os.stat(hostfile).st_mtime - 5.0)
    assert node.onion_url() == \
        "https://txljwl7mdg7t3wmqdci77ttof5ikxeqg2epmfadzfxlzxvjgtx5k4fad.onion/"


# ── 2b. #581: the hostname file outlives the key it names ────────────────────────
# `make stack-down` / `stack-clean` run `down -v` (the tor-onion-keys volume goes, the
# next TOR=1 up mints a NEW onion) but never remove the root-owned bind copy. The URL
# must therefore come from THIS running container, never from whatever file is there.
_OLD = "mcpw4coldoldoldoldoldoldoldoldoldoldoldoldoldoldoldoldold.onion"
_NEW = "txljwl7mdg7t3wmqdci77ttof5ikxeqg2epmfadzfxlzxvjgtx5k4fad.onion"


def _hostfile(root, onion, mtime):
    f = root / "tests" / "stack" / "tor-onion" / "hostname"
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(onion + "\n")
    os.utime(f, (mtime, mtime))
    return f


def test_a_hostname_file_with_no_running_tor_container_is_no_onion(tmp_path, monkeypatch):
    _hostfile(tmp_path, _OLD, 1_000_000.0)
    monkeypatch.setattr(LocalStackNode, "_tor_started_at", lambda self: None)
    node = LocalStackNode(str(tmp_path))
    assert node.onion_hostname() == _OLD          # the raw read still sees the file
    assert node.onion_url() == ""                 # ...but nothing is serving it


def test_a_copy_older_than_the_running_container_is_stale(tmp_path, monkeypatch):
    _hostfile(tmp_path, _OLD, 1_000_000.0)
    monkeypatch.setattr(LocalStackNode, "_tor_started_at", lambda self: 1_000_600.0)
    assert LocalStackNode(str(tmp_path)).onion_url() == ""


def test_a_copy_written_by_the_running_container_is_the_onion(tmp_path, monkeypatch):
    # written a fraction BEFORE the recorded StartedAt still counts (the entrypoint's
    # cp races docker's stamp on a warm restart) — within _ONION_START_SKEW_S.
    _hostfile(tmp_path, _NEW, 1_000_599.5)
    monkeypatch.setattr(LocalStackNode, "_tor_started_at", lambda self: 1_000_600.0)
    assert LocalStackNode(str(tmp_path)).onion_url() == f"https://{_NEW}/"


def test_await_onion_waits_past_a_stale_copy_for_the_new_one(tmp_path, monkeypatch):
    """down -v + up: the previous mesh's copy is on disk when the new container
    starts; `_await_onion` used to return it on the FIRST poll. It must wait for the
    copy the running container writes and announce THAT address."""
    from hugmesh_studio.core import local_mesh_bootstrap as lmb
    started = 1_000_600.0
    _hostfile(tmp_path, _OLD, 1_000_000.0)       # the previous mesh's copy
    monkeypatch.setattr(LocalStackNode, "_tor_started_at", lambda self: started)
    polls = []

    def fake_sleep(_s):
        polls.append(_s)
        if len(polls) == 2:                       # the container's cp lands, later
            _hostfile(tmp_path, _NEW, started + 3.0)
    monkeypatch.setattr(lmb.time, "sleep", fake_sleep)
    boot = LocalMeshBootstrap(str(tmp_path), LocalMeshBootstrapConfig(with_tor=True))
    notes = []
    url = boot._await_onion(LocalStackNode(str(tmp_path)), notes.append, None,
                            timeout_s=30)
    assert url == f"https://{_NEW}/"
    assert len(polls) >= 2                         # it did NOT take the stale first read


def test_tor_started_at_is_none_without_docker(monkeypatch, tmp_path):
    from hugmesh_studio.core import local_stack_node as lsn
    monkeypatch.setattr(lsn.shutil, "which", lambda _n: None)
    assert LocalStackNode(str(tmp_path))._tor_started_at() is None


def test_tor_started_at_reads_the_running_containers_stamp_by_label(monkeypatch, tmp_path):
    from hugmesh_studio.core import local_stack_node as lsn
    calls = []

    class _R:
        def __init__(self, out, rc=0):
            self.stdout, self.returncode = out, rc

    def fake_run(argv, **_kw):
        calls.append(argv)
        if argv[:2] == ["docker", "ps"]:
            return _R("abc123\n")
        return _R("true 2026-09-20T11:59:02.123456789Z\n")
    monkeypatch.setattr(lsn.shutil, "which", lambda _n: "/usr/bin/docker")
    monkeypatch.setattr(lsn.subprocess, "run", fake_run)
    got = LocalStackNode(str(tmp_path))._tor_started_at()
    assert got is not None and abs(got - 1789905542.123457) < 1e-3
    ps = calls[0]
    assert "label=com.docker.compose.project=hugmesh-local" in ps
    assert "label=com.docker.compose.service=hugmesh-tor" in ps
    assert "status=running" in ps


def test_parse_docker_time_rejects_the_zero_value_and_junk():
    from hugmesh_studio.core.local_stack_node import _parse_docker_time
    assert _parse_docker_time("0001-01-01T00:00:00Z") is None
    assert _parse_docker_time("") is None and _parse_docker_time("soon") is None
    assert _parse_docker_time("2026-09-20T04:59:02-07:00") == \
        _parse_docker_time("2026-09-20T11:59:02Z")


# ── 3. config -> stack threading, plan text, up() reporting ───────────────────────
def test_bootstrap_threads_with_tor_into_the_stack_node():
    boot = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(with_tor=True))
    stack = boot._stack_node()
    assert stack.with_tor is True
    assert stack._build_env()["TOR"] == "1"


def test_plan_serve_section_follows_the_services_row_not_the_raw_flag():
    """#586 residue: step (4) used to read raw `with_tor` while step (3) read
    effective_with_tor(), so services=("tor",) with with_tor=False said BOTH "also
    starts hugmesh-tor" and "Public exposure is a SEPARATE, opt-in step"."""
    on = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(
        with_tor=False, services=("tor",))).plan()
    assert "also starts hugmesh-tor" in on
    assert "already ON — the Tor v3 .onion above" in on
    assert "Public exposure is a SEPARATE" not in on
    off = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(
        with_tor=True, services=("tuwunel",))).plan()
    assert "also starts hugmesh-tor" not in off
    assert "already ON — the Tor v3 .onion above" not in off
    assert "Public exposure is a SEPARATE" in off


def test_plan_mentions_tor_only_when_enabled():
    off = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig()).plan()
    on = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(with_tor=True)).plan()
    assert "TOR=off" in off and "TOR=on" in on
    assert ".onion" in on and ".onion" not in off


def _happy_tor_boot(monkeypatch):
    boot = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(with_tor=True))
    monkeypatch.setattr(boot, "guard_host_local", lambda: (True, ""))
    monkeypatch.setattr(boot, "validate", lambda: [])
    monkeypatch.setattr(boot, "preflight", lambda: [])
    monkeypatch.setattr(boot, "generate_creds", lambda: (True, "minted"))
    monkeypatch.setattr(boot, "read_superadmin",
                        lambda: {"username": "sa", "password": "x"})
    monkeypatch.setattr(LocalStackNode, "start",
                        lambda self, on_line=None, cancel=None: (True, "up"))
    monkeypatch.setattr(LocalStackNode, "seed",
                        lambda self, extra_env=None, timeout=600, on_line=None,
                        cancel=None: (True, "seeded"))
    return boot


def test_up_reports_the_published_onion(monkeypatch):
    boot = _happy_tor_boot(monkeypatch)
    onion = "https://txljwl7mdg7t3wmqdci77ttof5ikxeqg2epmfadzfxlzxvjgtx5k4fad.onion/"
    monkeypatch.setattr(LocalStackNode, "onion_url", lambda self: onion)
    streamed = []
    ok, _log = boot.up(on_line=streamed.append)
    assert ok
    assert any("onion published" in l and onion in l for l in streamed)


def test_up_without_tor_never_waits_for_an_onion(monkeypatch):
    boot = _happy_tor_boot(monkeypatch)
    boot.cfg.with_tor = False
    # If the (disabled) path ever polled, this would blow up rather than silently pass.
    monkeypatch.setattr(LocalStackNode, "onion_url",
                        lambda self: pytest.fail("onion polled with tor OFF"))
    ok, _log = boot.up(on_line=lambda _l: None)
    assert ok


# ── 4. textual pins on the REAL Makefile / compose / build context ────────────────
def _read(*parts):
    with open(os.path.join(GENERATOR_DIR, *parts), encoding="utf-8") as f:
        return f.read()


def test_makefile_threads_the_tor_profile_through_stack_targets():
    mk = _read("Makefile")
    assert "STACK_TOR_PROFILE := $(if $(strip $(TOR)),--profile tor,)" in mk
    # stack-up must carry it on BOTH the build and the up lines
    up = mk.split("stack-up:", 1)[1].split("\nstack-", 1)[0]
    assert up.count("$(STACK_TOR_PROFILE)") >= 2
    # down must remove the profiled service too (else `docker compose down` leaves it)
    down = mk.split("stack-down:", 1)[1].split("\nstack-", 1)[0]
    assert "--profile tor" in down


def test_compose_defines_the_optin_tor_service():
    compose = _read("tests", "stack", "compose.local.yaml")
    assert "hugmesh-tor:" in compose
    tor = compose.split("hugmesh-tor:", 1)[1]
    assert 'profiles: ["tor"]' in tor              # OPT-IN, never in a default stack
    assert "TOR_ONION_UPSTREAM" in tor and "hugmesh-fe-gateway:8080" in tor
    assert "tor-onion-keys:" in compose            # the persisted-key volume exists


def test_tor_build_context_is_multiarch_and_serves_the_onion():
    dockerfile = _read("tests", "stack", "tor", "Dockerfile")
    # multi-arch: no platform pin (unlike the amd64 first-party images) + alpine tor
    assert "alpine" in dockerfile and "tor" in dockerfile
    assert "platform:" not in dockerfile and "linux/amd64" not in dockerfile
    entry = _read("tests", "stack", "tor", "entrypoint.sh")
    assert "HiddenServiceVersion 3" in entry
    assert "HiddenServicePort 80" in entry
    assert "SocksPort 0" in entry                  # serve an onion, not a proxy/relay
