"""The stub Casdoor (tests/scripts/casdoor_stub.py) as a pytest fixture: a real HTTP
server on loopback with real state, for the Studio's Casdoor admin-API client
(core/mesh_accounts.py) and the paths that use it."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
STUB = os.path.join(ROOT, "tests", "scripts", "casdoor_stub.py")


@pytest.fixture
def stub(tmp_path):
    """start(mode, admin_pw, seed, **env) -> (url, journal path); all are stopped."""
    procs = []

    def start(mode="ok", admin_pw="123", seed=None, **extra):
        n = len(procs)
        port_file = tmp_path / f"stub-port-{n}"
        journal = tmp_path / f"stub-journal-{n}"
        env = dict(os.environ, STUB_MODE=mode, STUB_ADMIN_PASSWORD=admin_pw,
                   STUB_PORT_FILE=str(port_file), STUB_JOURNAL=str(journal), **extra)
        if seed is not None:
            seed_file = tmp_path / f"stub-seed-{n}.json"
            seed_file.write_text(json.dumps(seed))
            env["STUB_SEED"] = str(seed_file)
        p = subprocess.Popen([sys.executable, STUB], env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        procs.append(p)
        for _ in range(200):
            if port_file.exists() and port_file.read_text().strip():
                break
            time.sleep(0.05)
        return f"http://127.0.0.1:{port_file.read_text().strip()}", journal

    yield start
    for p in procs:
        p.terminate()
        p.wait(5)
