"""Live Tor onion reachability e2e (OPT-IN).

Runs tests/stack/tor-onion-e2e.sh: it mints a real v3 .onion for a local HTTP
backend and fetches it back over the LIVE Tor network via tor's SOCKS proxy — the
exact path Tor Browser uses. This is the MECHANISM proof behind all three tor
surfaces: the local-mesh `snapdragon-tor` service, the node `tor` optional service,
and the `tor-onion` go-live provider (docs/TOR-HIDDEN-SERVICE.md).

SKIPPED by default: it needs the host tor daemon AND live Tor network access, and
takes ~60s. Enable with SNAPDRAGON_TOR_E2E=1 (and `tor` installed). Proven live on
2026-07-18: onion minted in ~1s, tor bootstrapped in ~46s, marker fetched over Tor
in ~60s (tor 0.4.9.11).
"""
import os
import shutil
import subprocess

import pytest

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HARNESS = os.path.join(GENERATOR_DIR, "tests", "stack", "tor-onion-e2e.sh")

_tor = shutil.which("tor") or ("/usr/bin/tor" if os.path.exists("/usr/bin/tor") else None)

pytestmark = pytest.mark.skipif(
    os.environ.get("SNAPDRAGON_TOR_E2E") != "1" or _tor is None,
    reason="live Tor onion e2e is opt-in — set SNAPDRAGON_TOR_E2E=1 with tor installed")


def test_the_harness_exists_and_is_executable():
    assert os.path.exists(HARNESS)
    assert os.access(HARNESS, os.X_OK)


def test_onion_is_reachable_over_tor(tmp_path):
    """Mint a v3 .onion and fetch its marker back over the real Tor network."""
    env = {**os.environ, "WORKDIR": str(tmp_path / "run"), "KEEP_WORKDIR": "0"}
    r = subprocess.run(["bash", HARNESS], env=env, capture_output=True,
                       text=True, timeout=300)
    combined = (r.stdout or "") + "\n" + (r.stderr or "")
    assert r.returncode == 0, f"tor onion e2e failed:\n{combined}"
    assert "SUCCESS (marker returned over Tor)" in r.stdout
    assert ".onion" in r.stdout
