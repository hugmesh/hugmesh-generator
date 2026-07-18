"""Tor v3 onion for the LOCAL docker mesh (the 2026-07-18 operator ask
"make sure starting the local docker mesh with tor is possible", "native and with
docker cross-platform").

Pins the wiring end-to-end WITHOUT bringing up docker (nobuild):
  1. TOR gate: with_tor -> TOR=1 in the make-env (the Makefile's STACK_TOR_PROFILE
     adds `--profile tor`); OFF is byte-identical to before (no TOR footgun).
  2. onion readout: LocalStackNode reads the PUBLIC hostname the snapdragon-tor
     service copies to tests/stack/tor-onion/hostname; absent => "" (never raises).
  3. config -> stack threading + the plan text + up() reporting the address.
  4. TEXTUAL pins on the real Makefile / compose / build context so a refactor
     cannot silently drop the profile, the service, or its multi-arch build.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from snapdragon_studio.core.local_mesh_bootstrap import (   # noqa: E402
    LocalMeshBootstrap, LocalMeshBootstrapConfig)
from snapdragon_studio.core.local_stack_node import LocalStackNode  # noqa: E402

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
def test_onion_hostname_reads_the_published_file(tmp_path):
    node = LocalStackNode(str(tmp_path))
    assert node.onion_hostname() == ""          # nothing published yet
    assert node.onion_url() == ""
    hostfile = tmp_path / "tests" / "stack" / "tor-onion" / "hostname"
    hostfile.parent.mkdir(parents=True)
    hostfile.write_text("txljwl7mdg7t3wmqdci77ttof5ikxeqg2epmfadzfxlzxvjgtx5k4fad.onion\n")
    assert node.onion_hostname() == \
        "txljwl7mdg7t3wmqdci77ttof5ikxeqg2epmfadzfxlzxvjgtx5k4fad.onion"
    assert node.onion_url() == \
        "http://txljwl7mdg7t3wmqdci77ttof5ikxeqg2epmfadzfxlzxvjgtx5k4fad.onion/"


# ── 3. config -> stack threading, plan text, up() reporting ───────────────────────
def test_bootstrap_threads_with_tor_into_the_stack_node():
    boot = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(with_tor=True))
    stack = boot._stack_node()
    assert stack.with_tor is True
    assert stack._build_env()["TOR"] == "1"


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
    onion = "http://txljwl7mdg7t3wmqdci77ttof5ikxeqg2epmfadzfxlzxvjgtx5k4fad.onion/"
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
    assert "snapdragon-tor:" in compose
    tor = compose.split("snapdragon-tor:", 1)[1]
    assert 'profiles: ["tor"]' in tor              # OPT-IN, never in a default stack
    assert "TOR_ONION_UPSTREAM" in tor and "snapdragon-fe-gateway:8080" in tor
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
