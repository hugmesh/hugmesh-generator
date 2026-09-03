"""core/view_doors — the Studio's reader of the `make view` door catalog.

The catalog (scripts/hugmesh-view.tsv) is POLICY: which host header, which upstream,
which 127.0.0.1 port. The Studio re-spells the script's 40-line parser rather than
importing a 1500-line tool that drags http.server + ssl into every GUI import — and the
price of a second parser is the DRIFT TEST here, which loads the script BY PATH at
test time and asserts the two agree row-for-row on the shipped file.

No Qt, no docker, no sockets that reach anything: the liveness half is seamed.
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys

import pytest

from hugmesh_studio.core import view_doors

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
SCRIPT = os.path.join(GENERATOR_DIR, "scripts", "hugmesh-view.py")

#: A fixed env so `${KIND_HTTPS_PORT:-8443}` and friends expand the same way in both
#: parsers regardless of what the test host exports.
_ENV: dict[str, str] = {}


def test_shipped_catalog_parses_every_row():
    doors = view_doors.load(GENERATOR_DIR, _ENV)
    by = {d.name: d for d in doors}
    for name in ("app", "registry", "argocd", "casdoor", "vault", "harbor-portal",
                 "compose-app", "compose-tls", "device-app"):
        assert name in by, f"the shipped catalog lost its '{name}' row"
    assert by["app"].host == "hugmesh.net" and by["app"].port == 9080
    assert by["app"].url == "https://127.0.0.1:9080/"
    assert by["vault"].path == "/ui/" and by["vault"].url.endswith(":9084/ui/")
    assert by["casdoor"].k8s_target == ("http", "hugmesh-pki", "casdoor", 8000)
    assert by["argocd"].k8s_target == ("https", "devops", "argocd-server", 443)
    assert by["registry"].host == "registry.hugmesh.net"
    # a '-' host is "does not route by name", never the literal dash
    assert by["argocd"].host == ""


def test_five_column_row_fails_closed():
    with pytest.raises(view_doors.ViewDoorError):
        view_doors.parse("app\tkind\thugmesh.net\thttps://127.0.0.1:8443\t9080\n", _ENV)
    # and a seven-column row is just as wrong
    with pytest.raises(view_doors.ViewDoorError):
        view_doors.parse("app\tkind\thugmesh.net\thttps://127.0.0.1:8443\t9080\t/\tx\n",
                         _ENV)


def test_kind_https_port_default_expands():
    doors = view_doors.parse(
        "app\tkind\thugmesh.net\thttps://127.0.0.1:${KIND_HTTPS_PORT:-8443}\t9080\t-\n",
        _ENV)
    assert doors[0].upstream == "https://127.0.0.1:8443"
    assert doors[0].direct_target == ("https", "127.0.0.1", 8443)
    assert doors[0].path == "/"
    # and the override wins when set
    doors = view_doors.parse(
        "app\tkind\thugmesh.net\thttps://127.0.0.1:${KIND_HTTPS_PORT:-8443}\t9080\t-\n",
        {"KIND_HTTPS_PORT": "18443"})
    assert doors[0].upstream == "https://127.0.0.1:18443"


def test_unset_var_without_default_fails_closed():
    with pytest.raises(view_doors.ViewDoorError):
        view_doors.parse("app\tkind\t-\thttps://127.0.0.1:${NOPE}\t9080\t-\n", _ENV)


def test_port_override_env_wins():
    doors = view_doors.parse("app\tkind\t-\thttp://127.0.0.1:1\t9080\t-\n",
                             {"HUGMESH_VIEW_PORT_APP": "9190"})
    assert doors[0].port == 9190 and doors[0].url == "https://127.0.0.1:9190/"
    assert view_doors.env_var_for("harbor-portal") == "HUGMESH_VIEW_PORT_HARBOR_PORTAL"


def test_duplicate_row_names_are_refused():
    with pytest.raises(view_doors.ViewDoorError):
        view_doors.parse("a\tkind\t-\thttp://x:1\t9000\t-\na\tkind\t-\thttp://x:2\t9001\t-\n",
                         _ENV)


def _session(tmp_path, pid: int, doors):
    state = tmp_path / "out" / "hugmesh-view"
    state.mkdir(parents=True)
    (state / "session.json").write_text(json.dumps({
        "pid": pid, "marker": "hugmesh-view", "lane": "kind",
        "doors": [{"name": n, "port": p, "url": f"https://127.0.0.1:{p}/"}
                  for n, p in doors]}))
    return str(tmp_path)


def test_dead_session_pid_yields_no_live_doors(tmp_path):
    gd = _session(tmp_path, pid=1, doors=[("app", 9080)])
    assert view_doors.live_session(gd, _ENV)["pid"] == 1
    # a dead owner: no door is live, however many the record lists
    assert view_doors.live_doors(gd, _ENV, alive=lambda pid, marker: False,
                                 connect=lambda port: True) == {}
    assert view_doors.stale_session(gd, _ENV, alive=lambda pid, marker: False)


def test_live_owner_but_dead_port_is_not_a_live_door(tmp_path):
    gd = _session(tmp_path, pid=os.getpid(), doors=[("app", 9080), ("argocd", 9082)])
    got = view_doors.live_doors(gd, _ENV, alive=lambda pid, marker: True,
                                connect=lambda port: port == 9080)
    assert got == {"app": "https://127.0.0.1:9080/"}
    assert not view_doors.stale_session(gd, _ENV, alive=lambda pid, marker: True)


def test_absent_session_is_empty_not_an_error(tmp_path):
    assert view_doors.live_session(str(tmp_path), _ENV) == {}
    assert view_doors.live_doors(str(tmp_path), _ENV) == {}
    assert not view_doors.stale_session(str(tmp_path), _ENV)


def test_pid_alive_refuses_a_reused_pid_by_marker():
    # our own pid is alive, but its cmdline does not carry the marker
    assert view_doors.pid_alive(os.getpid(), marker="hugmesh-view") is False
    assert view_doors.pid_alive(0) is False


def test_core_parser_agrees_with_the_script():
    """THE DRIFT TEST: the script is the authority; this module must match it row for
    row on the shipped catalog. Loaded by path, at test time only."""
    spec = importlib.util.spec_from_file_location("hugmesh_view_script", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod            # dataclasses resolve the module by name
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.modules.pop(spec.name, None)
    theirs = mod.load_catalog(os.path.join(GENERATOR_DIR, "scripts", "hugmesh-view.tsv"),
                              _ENV)
    ours = view_doors.load(GENERATOR_DIR, _ENV)
    key = lambda e: (e.name, e.lane, e.host, e.upstream, e.port, e.path)  # noqa: E731
    assert [key(e) for e in ours] == [key(e) for e in theirs]
    assert [e.url for e in ours] == [e.url for e in theirs]


def test_module_is_qt_free():
    probe = (
        "import hugmesh_studio.core.view_doors as m, sys;"
        "assert callable(m.load) and callable(m.live_doors);"
        "bad=[x for x in sys.modules if x.startswith(('PySide6','PyQt6','PyQt5'))];"
        "assert not bad, bad"
    )
    env = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run([sys.executable, "-c", probe], env=env,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
