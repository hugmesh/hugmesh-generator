"""A new onion address for ONE Tor domain on the local Docker mesh (hugmesh-generator#652).

tests/stack/tor/entrypoint.sh is EXECUTED: first as the container start (against a stub
tor that mints a key for every HiddenServiceDir, and on SIGHUP for every one left
without a key, which is what real tor does on a reload), then as
``entrypoint.sh rotate <slug>`` (the image's ``hugmesh-tor-rotate``), the way
``docker exec`` runs it in the running container.

Pinned here: a rotation changes only that domain's key, readout and map line; the
mesh's own (primary) address and every other domain stay byte-for-byte; the old key is
kept aside; a failed mint puts the old address back; a second rotation while one runs,
a name that is not a Tor domain and a container without a running tor are refused with
nothing changed; key folders past the retention window are pruned.
"""
import os
import shutil
import signal
import stat
import subprocess
import time

import pytest

GENERATOR_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ENTRY = os.path.join(GENERATOR_DIR, "tests", "stack", "tor", "entrypoint.sh")

pytestmark = pytest.mark.skipif(os.name == "nt", reason="POSIX shell harness")

# A v3 name is 56 base32 characters; the letter says which key minted it.
_LETTERS = {"hugmesh-onion": "p", "brandb": "b"}

_STUB_TOR = r'''#!/bin/sh
[ "$1" = "-f" ] || { echo "stub tor: expected -f <torrc>" >&2; exit 64; }
torrc="$2"
umask 077
gen=0
mint() {
  sed -n 's/^HiddenServiceDir //p' "$torrc" | while read -r hs; do
    [ -d "$hs" ] || continue
    [ -s "$hs/hostname" ] && continue
    if [ "$gen" -gt 0 ] && [ "${STUB_NO_REMINT:-}" = "1" ]; then continue; fi
    base="$(basename "$hs")"
    case "$base" in
      hugmesh-onion) c=p ;;
      brandb) c=b ;;
      *) c="$(printf 'acdefghijk' | cut -c$((gen + 1)))" ;;
    esac
    printf '%s.onion\n' "$(printf "%056d" 0 | tr 0 "$c")" > "$hs/hostname"
    : > "$hs/hs_ed25519_secret_key"
  done
}
mint
log="$(sed -n 's/^Log notice file //p' "$torrc")"
[ -n "$log" ] && echo "[notice] Bootstrapped 100% (done): Done" >> "$log"
trap 'gen=$((gen + 1)); mint' HUP
trap 'exit 0' TERM INT
while :; do sleep 0.1; done
'''


def _onion(c):
    return c * 56 + ".onion"


def _exe(path, body):
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


@pytest.fixture
def mesh(tmp_path):
    """A started 'container': the entrypoint running with a stub tor, two Tor domains,
    every name published. Yields (env, paths); stops it afterwards."""
    for sub in ("bin", "data", "out", "map"):
        (tmp_path / sub).mkdir()
    _exe(tmp_path / "bin" / "tor", _STUB_TOR)
    # chown is a stub: the test user is not root and there is no `tor` user here
    _exe(tmp_path / "bin" / "chown", "#!/bin/sh\nexit 0\n")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("TOR_", "HUGMESH_TOR_"))}
    env.update({
        "PATH": str(tmp_path / "bin") + os.pathsep + env.get("PATH", ""),
        "HUGMESH_TOR_DATA_DIR": str(tmp_path / "data"),
        "HUGMESH_TOR_OUT_DIR": str(tmp_path / "out"),
        "HUGMESH_TOR_TORRC": str(tmp_path / "torrc"),
        "HUGMESH_TOR_BIN": str(tmp_path / "bin" / "tor"),
        "HUGMESH_TOR_MAP_DIR": str(tmp_path / "map"),
        "HUGMESH_TOR_ROTATE_WAIT_S": "5",
        "TOR_ONION_DOMAINS": "acme-example=acme brandb=brandb",
    })
    proc = subprocess.Popen(["sh", ENTRY], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    out = tmp_path / "out"
    deadline = time.time() + 15
    while not (out / "hostname").exists():
        assert proc.poll() is None, proc.stdout.read()
        assert time.time() < deadline, "the start never published the primary name"
        time.sleep(0.1)
    try:
        yield env, tmp_path
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


def _rotate(env, slug, **extra):
    return subprocess.run(["sh", ENTRY, "rotate", slug], env={**env, **extra},
                          capture_output=True, text=True, timeout=30)


def _read(p):
    return p.read_text() if p.exists() else None


def _map(tmp_path):
    return dict(line.split("=", 1) for line in (tmp_path / "map" / "onion-hosts.map")
                .read_text().splitlines() if line and not line.startswith("#"))


def test_a_rotation_changes_only_that_domain(mesh):
    env, t = mesh
    keys = t / "data" / "hugmesh-onion.d"
    before = {
        "primary": _read(t / "out" / "hostname"),
        "brandb": _read(t / "out" / "brandb.hostname"),
        "brandb_key": _read(keys / "brandb" / "hostname"),
        "primary_key": _read(t / "data" / "hugmesh-onion" / "hostname"),
        "notice": _read(t / "data" / "notice.log"),
    }
    old = _onion("a")
    assert _read(t / "out" / "acme-example.hostname").strip() == old
    assert _map(t)[old] == "acme"

    r = _rotate(env, "acme-example")
    assert r.returncode == 0, r.stdout + r.stderr
    new = _onion("c")
    assert f"ROTATED acme-example {old} -> {new}" in r.stdout
    # the new name is published: readout and gateway map; the old one is gone from both
    assert _read(t / "out" / "acme-example.hostname").strip() == new
    m = _map(t)
    assert m[new] == "acme" and old not in m
    # nothing else moved
    assert _read(t / "out" / "hostname") == before["primary"]
    assert _read(t / "out" / "brandb.hostname") == before["brandb"]
    assert _read(keys / "brandb" / "hostname") == before["brandb_key"]
    assert _read(t / "data" / "hugmesh-onion" / "hostname") == before["primary_key"]
    assert m[before["primary"].strip()] == "default" and m[_onion("b")] == "brandb"
    # the healthcheck's notice log is not truncated by a rotation
    assert _read(t / "data" / "notice.log") == before["notice"]
    # the old key is kept aside, not deleted, and the lock is released
    retired = list((keys / ".retired").iterdir())
    assert len(retired) == 1 and retired[0].name.startswith("acme-example-")
    assert (retired[0] / "hostname").read_text().strip() == old
    assert not (t / "data" / ".rotate.lock").exists()


def test_a_second_rotation_mints_yet_another_address(mesh):
    env, t = mesh
    assert _rotate(env, "acme-example").returncode == 0
    time.sleep(1.1)            # a distinct retired folder name (second resolution)
    r = _rotate(env, "acme-example")
    assert r.returncode == 0, r.stdout + r.stderr
    assert f"ROTATED acme-example {_onion('c')} -> {_onion('d')}" in r.stdout
    assert len(list((t / "data" / "hugmesh-onion.d" / ".retired").iterdir())) == 2


@pytest.mark.parametrize("slug", ["hugmesh-onion", "shop-example", "Bad_Slug", "", "../x"])
def test_a_name_that_is_not_one_of_the_tor_domains_is_refused(mesh, slug):
    env, t = mesh
    snapshot = sorted(p.read_bytes() for p in (t / "out").iterdir())
    r = _rotate(env, slug)
    assert r.returncode == 2, r.stdout + r.stderr
    assert "REFUSED" in r.stderr
    assert sorted(p.read_bytes() for p in (t / "out").iterdir()) == snapshot
    assert not (t / "data" / "hugmesh-onion.d" / ".retired").exists()


def test_a_reload_that_mints_nothing_restores_the_old_key(tmp_path):
    # A start whose tor never re-mints (STUB_NO_REMINT set at START, so the running
    # stub has it): the rotation must time out, put the old key back and republish it.
    for sub in ("bin", "data", "out", "map"):
        (tmp_path / sub).mkdir()
    _exe(tmp_path / "bin" / "tor", _STUB_TOR)
    _exe(tmp_path / "bin" / "chown", "#!/bin/sh\nexit 0\n")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("TOR_", "HUGMESH_TOR_"))}
    env.update({
        "PATH": str(tmp_path / "bin") + os.pathsep + env.get("PATH", ""),
        "HUGMESH_TOR_DATA_DIR": str(tmp_path / "data"),
        "HUGMESH_TOR_OUT_DIR": str(tmp_path / "out"),
        "HUGMESH_TOR_TORRC": str(tmp_path / "torrc"),
        "HUGMESH_TOR_BIN": str(tmp_path / "bin" / "tor"),
        "HUGMESH_TOR_MAP_DIR": str(tmp_path / "map"),
        "HUGMESH_TOR_ROTATE_WAIT_S": "2",
        "TOR_ONION_DOMAINS": "acme-example=acme",
        "STUB_NO_REMINT": "1",
    })
    proc = subprocess.Popen(["sh", ENTRY], env=env, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    try:
        deadline = time.time() + 15
        while not (tmp_path / "out" / "hostname").exists():
            assert time.time() < deadline
            time.sleep(0.1)
        old = _onion("a")
        rot = subprocess.Popen(["sh", ENTRY, "rotate", "acme-example"], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        # WHILE tor is (not) minting, the old name is already withdrawn: the edge must
        # stop admitting it before anything else happens (design D31's order)
        time.sleep(1.0)
        assert rot.poll() is None, "the rotation ended before its wait"
        assert old not in _map(tmp_path), "the old name was still in the gateway map mid-rotation"
        assert not (tmp_path / "out" / "acme-example.hostname").exists()
        stdout, stderr = rot.communicate(timeout=30)
        r = subprocess.CompletedProcess(rot.args, rot.returncode, stdout, stderr)
        assert r.returncode == 5, r.stdout + r.stderr
        assert "the old address is served again" in r.stderr
        key = tmp_path / "data" / "hugmesh-onion.d" / "acme-example"
        assert (key / "hostname").read_text().strip() == old
        assert (key / "hs_ed25519_secret_key").exists()
        assert (tmp_path / "out" / "acme-example.hostname").read_text().strip() == old
        assert _map(tmp_path)[old] == "acme"
        assert not list((tmp_path / "data" / "hugmesh-onion.d" / ".retired").iterdir())
    finally:
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=10)


def test_a_second_rotation_while_one_runs_is_refused(mesh):
    env, t = mesh
    (t / "data" / ".rotate.lock").mkdir()
    snapshot = _read(t / "out" / "acme-example.hostname")
    r = _rotate(env, "acme-example")
    assert r.returncode == 3 and "BUSY" in r.stderr
    assert _read(t / "out" / "acme-example.hostname") == snapshot
    # the refused call did not take the other rotation's lock away
    assert (t / "data" / ".rotate.lock").is_dir()


def test_without_a_running_tor_nothing_is_changed(mesh):
    env, t = mesh
    (t / "data" / "hugmesh-tor.pid").write_text("999999\n")
    snapshot = _read(t / "out" / "acme-example.hostname")
    r = _rotate(env, "acme-example")
    assert r.returncode == 5 and "not running" in r.stderr
    assert _read(t / "out" / "acme-example.hostname") == snapshot
    assert (t / "data" / "hugmesh-onion.d" / "acme-example" / "hostname").exists()


def test_key_folders_past_the_retention_window_are_pruned(mesh):
    env, t = mesh
    retired = t / "data" / "hugmesh-onion.d" / ".retired"
    retired.mkdir(mode=0o700)
    stale, fresh = retired / "acme-example-20200101T000000Z", retired / "brandb-recent"
    stale.mkdir()
    fresh.mkdir()
    old = time.time() - 30 * 86400
    os.utime(stale, (old, old))
    assert _rotate(env, "acme-example", HUGMESH_TOR_ROTATE_RETAIN_DAYS="7").returncode == 0
    names = {p.name for p in retired.iterdir()}
    assert stale.name not in names and fresh.name in names
    assert any(n.startswith("acme-example-2") and n != stale.name for n in names)


def test_an_unknown_command_is_refused_and_the_start_is_untouched(tmp_path):
    r = subprocess.run(["sh", ENTRY, "renew", "x"], capture_output=True, text=True,
                       env={**os.environ, "HUGMESH_TOR_DATA_DIR": str(tmp_path)},
                       timeout=10)
    assert r.returncode == 2 and "unknown command" in r.stderr
    assert not (tmp_path / "notice.log").exists() or (tmp_path / "notice.log").read_text() == ""


def test_the_image_installs_the_rotate_command():
    df = open(os.path.join(GENERATOR_DIR, "tests", "stack", "tor", "Dockerfile")).read()
    assert "/usr/local/bin/hugmesh-tor-rotate" in df
    assert 'hugmesh-tor-entrypoint rotate "$@"' in df
    assert shutil.which("sh")
