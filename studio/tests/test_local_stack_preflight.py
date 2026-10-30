"""Both-ways coverage for the cold-build fail-fast preflight
(LocalStackNode.preflight + LocalMeshBootstrap.preflight/up wiring).

Motivating failure (live, 2026-07): a docker data-root migration purged every
image, so `make stack-up` had to COLD-BUILD all services — and died half an
hour in on prerequisites (BuildKit/buildx visibility, the org-private maven
artifacts) that nothing had checked up front. The operator got the truncated
tail of an 1800s `make` capture instead of "run `make stack-m2-bootstrap`
first". The preflight turns each of those into a SHORT actionable line
BEFORE any credential is minted or container started.

Every probe is mocked BOTH ways here — no test talks to a real docker daemon,
and nothing asserts readiness the host doesn't have (probes default-fail).
"""
import os
import re
import shutil
import subprocess

from hugmesh_studio.core import local_stack_node as lsn
from hugmesh_studio.core.local_stack_node import (
    M2_BOOTSTRAP_HINT, M2_REGISTRY_CONTAINER, PREFLIGHT_MIN_FREE_GIB,
    PRIVATE_ARTIFACT_SERVICES, LocalStackNode,
)
from hugmesh_studio.core.local_mesh_bootstrap import (
    LocalMeshBootstrap, LocalMeshBootstrapConfig,
)

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(GENERATOR_DIR)  # studio/tests -> studio -> repo root


def _node(**kw):
    return LocalStackNode(GENERATOR_DIR, **kw)


def _green(monkeypatch, node_cls=LocalStackNode, images_present=True):
    """Mock every host probe GREEN; individual tests then flip ONE check red."""
    monkeypatch.setattr(node_cls, "available", lambda self: (True, ""), raising=True)
    monkeypatch.setattr(node_cls, "_docker_ready",
                        lambda self: (True, "29.5.2"), raising=True)
    monkeypatch.setattr(node_cls, "_buildx_visible", lambda self: True, raising=True)
    monkeypatch.setattr(node_cls, "_docker_root_free_gib",
                        lambda self: PREFLIGHT_MIN_FREE_GIB * 10.0, raising=True)
    monkeypatch.setattr(node_cls, "_image_present",
                        lambda self, image: images_present, raising=True)
    monkeypatch.setattr(node_cls, "m2_registry_ready",
                        lambda self: (True, ""), raising=True)


# ── all green ────────────────────────────────────────────────────────────────────

def test_preflight_all_green_is_empty(monkeypatch):
    monkeypatch.delenv("DOCKER_BUILDKIT", raising=False)
    _green(monkeypatch)
    assert _node().preflight() == []


def test_preflight_green_even_without_m2_when_images_present(monkeypatch):
    # images already built -> no cold build -> the m2 registry is NOT required
    monkeypatch.delenv("DOCKER_BUILDKIT", raising=False)
    _green(monkeypatch, images_present=True)
    monkeypatch.setattr(LocalStackNode, "m2_registry_ready",
                        lambda self: (False, "should never be consulted"),
                        raising=True)
    assert _node().preflight() == []


# ── each check red, one at a time ────────────────────────────────────────────────

def test_preflight_available_failure_short_circuits(monkeypatch):
    _green(monkeypatch)
    monkeypatch.setattr(LocalStackNode, "available",
                        lambda self: (False, "make is required"), raising=True)

    def _boom(self):  # pragma: no cover - the assertion IS the test
        raise AssertionError("docker probes must not run when available() fails")
    monkeypatch.setattr(LocalStackNode, "_docker_ready", _boom, raising=True)
    assert _node().preflight() == ["make is required"]


def test_preflight_docker_daemon_down_is_single_actionable_line(monkeypatch):
    monkeypatch.delenv("DOCKER_BUILDKIT", raising=False)
    _green(monkeypatch)
    monkeypatch.setattr(LocalStackNode, "_docker_ready",
                        lambda self: (False, "Cannot connect to the Docker daemon"),
                        raising=True)
    problems = _node().preflight()
    assert len(problems) == 1
    assert "docker daemon" in problems[0]
    assert "Cannot connect" in problems[0]


def test_preflight_flags_invisible_buildx(monkeypatch):
    monkeypatch.delenv("DOCKER_BUILDKIT", raising=False)
    _green(monkeypatch)
    monkeypatch.setattr(LocalStackNode, "_buildx_visible",
                        lambda self: False, raising=True)
    problems = _node().preflight()
    assert len(problems) == 1
    # actionable: names the plugin, its per-user location, and the consequence
    assert "buildx" in problems[0]
    assert "cli-plugins" in problems[0]


def test_preflight_flags_buildkit_disabled_via_env(monkeypatch):
    _green(monkeypatch)
    monkeypatch.setenv("DOCKER_BUILDKIT", "0")
    problems = _node().preflight()
    assert any("DOCKER_BUILDKIT=0" in p for p in problems)


def test_preflight_flags_low_disk(monkeypatch):
    monkeypatch.delenv("DOCKER_BUILDKIT", raising=False)
    _green(monkeypatch)
    monkeypatch.setattr(LocalStackNode, "_docker_root_free_gib",
                        lambda self: 3.0, raising=True)
    problems = _node().preflight()
    assert len(problems) == 1
    assert "3 GiB" in problems[0] and str(PREFLIGHT_MIN_FREE_GIB) in problems[0]


def test_preflight_cold_build_without_m2_names_the_bootstrap(monkeypatch):
    monkeypatch.delenv("DOCKER_BUILDKIT", raising=False)
    _green(monkeypatch, images_present=False)
    monkeypatch.setattr(LocalStackNode, "m2_registry_ready",
                        lambda self: (False, ".m2-registry.env missing"), raising=True)
    problems = _node().preflight()
    assert len(problems) == 1
    # THE actionable plan: the exact make target to run + why
    assert M2_BOOTSTRAP_HINT in problems[0]
    assert ".m2-registry.env missing" in problems[0]
    # names at least the first missing private-artifact service
    assert PRIVATE_ARTIFACT_SERVICES[0] in problems[0]


def test_preflight_cold_build_with_m2_ready_is_green(monkeypatch):
    monkeypatch.delenv("DOCKER_BUILDKIT", raising=False)
    _green(monkeypatch, images_present=False)  # cold build needed, registry ready
    assert _node().preflight() == []


def test_preflight_never_fabricates_readiness_when_probes_error(monkeypatch):
    # a probe that cannot run (subprocess error path -> rc!=0) reports NOT ready:
    # only available() is mocked green — every real probe hits the failing _probe
    monkeypatch.delenv("DOCKER_BUILDKIT", raising=False)
    monkeypatch.setattr(LocalStackNode, "available",
                        lambda self: (True, ""), raising=True)
    monkeypatch.setattr(LocalStackNode, "_probe",
                        lambda self, cmd, timeout=15: (1, "exec format error"),
                        raising=True)
    problems = _node().preflight()
    assert problems and "docker daemon" in problems[0]


# ── the probes run in the SAME env `make stack-up` will use ─────────────────────

def test_probe_env_is_the_make_env(monkeypatch):
    seen = {}

    def _fake_run(cmd, env=None, capture_output=None, text=None, timeout=None, **_kw):
        seen["cmd"], seen["env"] = cmd, env

        class _R:
            returncode = 0
            stdout = "ok"
            stderr = ""
        return _R()

    monkeypatch.setattr(lsn.subprocess, "run", _fake_run)
    node = _node(env="prod", social=True, public_host_port=9999, domain="corp.example")
    assert node._buildx_visible() is True
    assert seen["cmd"] == ["docker", "buildx", "version"]
    # the EXACT env _make() exports — a buildx check in any other env would
    # fabricate readiness (the plugin is per-user in ~/.docker/cli-plugins)
    assert seen["env"]["ENV"] == "prod"
    assert seen["env"]["SOCIAL"] == "1"
    assert seen["env"]["PUBLIC_HOST_PORT"] == "9999"
    assert seen["env"]["DOMAIN"] == "corp.example"


# ── m2_registry_ready(): real logic against a temp generator dir ────────────────
# The readiness check must GET a real artifact THROUGH the env-file URL — an
# env-file-exists + container-running check fabricates readiness when a docker
# restart hands the registry a new bridge IP while the env file stays frozen
# (proven live: preflight said green while curl of the frozen URL failed rc=7).

# DERIVED, at both ends — never a hardcoded copy. A duplicated literal here is
# exactly why the coordinate drifts went unnoticed: the test asserted the stale
# value it had copied, so it stayed green while the real probe 404'd. That bit
# twice — 2.7.0 -> 2.8.0, then `systems/hugmesh` -> `net/hugmesh` — so BOTH sides
# now read the coordinate out of m2-bootstrap.sh's PINS, and
# test_check_artifact_matches_the_m2_bootstrap_script runs the two derivations
# against each other.
_M2_SCRIPT = os.path.join(GENERATOR_DIR, "tests", "stack", "m2-bootstrap.sh")
_CHECK_ARTIFACT, _CHECK_WHY = LocalStackNode(GENERATOR_DIR)._m2_check_artifact()
_CHECK_TAIL = f"/groups/7/-/packages/maven/{_CHECK_ARTIFACT}"


def _shell_check_path(group_id="7"):
    """m2-bootstrap.sh's OWN self-check path, produced by running the script's
    real `_check_path_from_pins` over its real PINS — lifted out and run in bash
    rather than re-implemented here (a re-implementation is just a third copy to
    drift). The script itself cannot be sourced: its top level clones, builds and
    talks to docker."""
    src = open(_M2_SCRIPT, encoding="utf-8").read()
    pins = re.search(r"^PINS=\((.*?)^\)", src, re.S | re.M)
    fn = re.search(r"^_check_path_from_pins\(\)\s*\{.*?^\}", src, re.S | re.M)
    assert pins, "PINS array not found in m2-bootstrap.sh (shape drift?)"
    assert fn, "_check_path_from_pins() not found in m2-bootstrap.sh (shape drift?)"
    prog = "\n".join(["set -eu", f"GITLAB_GROUP_ID={group_id}",
                      f"PINS=({pins.group(1)})", fn.group(0), "_check_path_from_pins"])
    out = subprocess.run(["bash", "-c", prog], capture_output=True, text=True)
    assert out.returncode == 0, f"m2-bootstrap.sh self-check derivation failed: {out.stderr}"
    return out.stdout.strip()


def test_check_artifact_matches_the_m2_bootstrap_script():
    """DRIFT GUARD: the preflight's check artifact and tests/stack/m2-bootstrap.sh's
    own self-check must resolve to the SAME hugmesh-parent coordinate.

    Both sides derive it from the one PINS array, but they derive it in two
    languages, so the SHAPE can still drift (a moved path segment, a renamed
    field). This runs both derivations for real and compares the full URL tails —
    red in either direction: a Python side that stops following the pin (how
    `systems/hugmesh` survived the rename to `net/hugmesh`, probing a path nothing
    publishes against a perfectly healthy registry), or a shell side that moves
    the served path without the preflight. Nothing else compares them."""
    assert _CHECK_ARTIFACT, _CHECK_WHY
    assert _shell_check_path() == _CHECK_TAIL.lstrip("/"), (
        f"preflight probes /{_CHECK_TAIL.lstrip('/')} but m2-bootstrap.sh "
        f"serves/self-checks /{_shell_check_path()} — they must name the same artifact")


def test_check_artifact_follows_a_renamed_pin(tmp_path):
    """...and the Python side really is DERIVED, not restated: rewrite the pin's
    group path + version in a throwaway checkout and the probe must move with it.
    A re-hardcoded constant passes the test above (until the next rename) but
    fails here immediately."""
    script = tmp_path / "tests" / "stack" / "m2-bootstrap.sh"
    script.parent.mkdir(parents=True)
    sha = "0" * 40
    script.write_text(
        "PINS=(\n"
        f'  "hugmesh-build-config|{sha}|hugmesh-build-config|0.5.0|jar|net/hugmesh"\n'
        "  # a comment line, as in the real script\n"
        f'  "hugmesh-parent|{sha}|hugmesh-parent|9.9.9|pom|org/example"\n'
        ")\n")
    assert LocalStackNode(str(tmp_path))._m2_check_artifact() == (
        "org/example/hugmesh-parent/9.9.9/hugmesh-parent-9.9.9.pom", "")


def test_check_artifact_default_fails_without_a_parent_pin(tmp_path):
    """No script / no parent pin -> no probe URL to guess. Default-fail with a
    reason, like every other probe here."""
    node = LocalStackNode(str(tmp_path))
    path, why = node._m2_check_artifact()
    assert path == "" and "m2-bootstrap.sh" in why
    script = tmp_path / "tests" / "stack" / "m2-bootstrap.sh"
    script.parent.mkdir(parents=True)
    script.write_text('PINS=(\n  "hugmesh-commons|x|hugmesh-commons|2.1.0|jar|net/hugmesh"\n)\n')
    path, why = node._m2_check_artifact()
    assert path == "" and "hugmesh-parent" in why


def _write_env(tmp_path, body):
    """Env file + the m2-bootstrap.sh the check-artifact path is derived from
    (the REAL one — a stub would let a wrong coordinate pass these tests)."""
    envf = tmp_path / "tests" / "stack" / ".m2-registry.env"
    envf.parent.mkdir(parents=True, exist_ok=True)
    envf.write_text(body)
    shutil.copy(_M2_SCRIPT, envf.parent / "m2-bootstrap.sh")
    return envf


def test_m2_registry_ready_requires_env_file(tmp_path, monkeypatch):
    def _boom(self, url, timeout=3.0):  # pragma: no cover - the assertion IS the test
        raise AssertionError("no HTTP probe without an env file")
    monkeypatch.setattr(LocalStackNode, "_url_ok", _boom, raising=True)
    ok, why = LocalStackNode(str(tmp_path)).m2_registry_ready()
    assert ok is False and ".m2-registry.env" in why


def test_m2_registry_ready_requires_ci_api_v4_url(tmp_path, monkeypatch):
    _write_env(tmp_path, "# stale header only\nGITLAB_GROUP_ID=1\n")

    def _boom(self, url, timeout=3.0):  # pragma: no cover
        raise AssertionError("no HTTP probe without a URL to probe")
    monkeypatch.setattr(LocalStackNode, "_url_ok", _boom, raising=True)
    ok, why = LocalStackNode(str(tmp_path)).m2_registry_ready()
    assert ok is False and "CI_API_V4_URL" in why


def test_m2_registry_ready_probes_the_exact_gitlab_shaped_artifact_url(tmp_path, monkeypatch):
    _write_env(tmp_path, "# header\nCI_API_V4_URL=http://172.17.0.9:8080/\n"
                         "GITLAB_GROUP_ID=7\n")
    seen = {}

    def _ok(self, url, timeout=3.0):
        seen["url"] = url
        return True, ""
    monkeypatch.setattr(LocalStackNode, "_url_ok", _ok, raising=True)
    assert LocalStackNode(str(tmp_path)).m2_registry_ready() == (True, "")
    # the SAME url shape settings.xml + m2-bootstrap.sh's self-check use
    assert seen["url"] == "http://172.17.0.9:8080" + _CHECK_TAIL


def test_m2_registry_ready_fails_when_probe_fails(tmp_path, monkeypatch):
    _write_env(tmp_path, "CI_API_V4_URL=http://172.17.0.250:8080\nGITLAB_GROUP_ID=7\n")
    monkeypatch.setattr(LocalStackNode, "_url_ok",
                        lambda self, url, timeout=3.0: (False, "Connection refused"),
                        raising=True)
    ok, why = LocalStackNode(str(tmp_path)).m2_registry_ready()
    assert ok is False
    assert M2_REGISTRY_CONTAINER in why and "Connection refused" in why
    # names the failure class the probe exists to catch
    assert "bridge IP" in why


def test_m2_registry_ready_stale_env_file_real_probe(tmp_path):
    # THE live-proven fabricated-readiness scenario, un-mocked: env file points at
    # a port nothing listens on -> connection refused -> NOT ready (default-fail).
    import socket
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    dead_port = s.getsockname()[1]
    s.close()  # freed -> connect will be refused
    _write_env(tmp_path, f"CI_API_V4_URL=http://127.0.0.1:{dead_port}\nGITLAB_GROUP_ID=1\n")
    ok, why = LocalStackNode(str(tmp_path)).m2_registry_ready()
    assert ok is False and M2_REGISTRY_CONTAINER in why


def test_m2_registry_ready_end_to_end_against_a_real_http_registry(tmp_path):
    # real urllib probe against a real (loopback) static registry: serving the
    # artifact -> ready; an EMPTIED m2 tree (404) -> not ready.
    import functools
    import http.server
    import threading

    class _Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a):  # keep pytest output clean
            pass

    www = tmp_path / "www"
    pom = www / _CHECK_TAIL.lstrip("/")
    pom.parent.mkdir(parents=True)
    pom.write_text("<project/>")
    srv = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(_Quiet, directory=str(www)))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        url = f"http://127.0.0.1:{srv.server_address[1]}"
        _write_env(tmp_path, f"CI_API_V4_URL={url}\nGITLAB_GROUP_ID=7\n")
        assert LocalStackNode(str(tmp_path)).m2_registry_ready() == (True, "")
        # the emptied/unmounted-cache case: registry up but artifact gone -> 404
        pom.unlink()
        ok, why = LocalStackNode(str(tmp_path)).m2_registry_ready()
        assert ok is False and "404" in why
    finally:
        srv.shutdown()
        srv.server_close()


# ── start() gates on the preflight (covers the tray path, which calls it directly) ──

def test_start_fails_fast_on_preflight_problems(monkeypatch):
    monkeypatch.setattr(LocalStackNode, "preflight",
                        lambda self: ["problem-1", "problem-2"], raising=True)

    def _boom(self, target, timeout, extra_env=None):  # pragma: no cover
        raise AssertionError("make stack-up must not run when preflight fails")
    monkeypatch.setattr(LocalStackNode, "_make", _boom, raising=True)
    ok, why = _node().start()
    assert ok is False
    assert why == "problem-1\nproblem-2"  # SHORT plan, not 1800s of compose noise


def test_start_runs_stack_up_when_preflight_green(monkeypatch):
    monkeypatch.setattr(LocalStackNode, "preflight", lambda self: [], raising=True)
    seen = {}

    def _make(self, target, timeout, extra_env=None, on_line=None, cancel=None):
        seen["target"], seen["timeout"] = target, timeout
        return True, "up"
    monkeypatch.setattr(LocalStackNode, "_make", _make, raising=True)
    assert _node().start() == (True, "up")
    assert seen["target"] == "stack-up"


# ── bootstrap wiring: up() fails fast with the SHORT plan, before any mint ──────

_M2_PROBLEM = (f"cold build required but the local maven registry is not up "
               f"(.m2-registry.env missing) — {M2_BOOTSTRAP_HINT}")


def test_bootstrap_up_stops_on_preflight_with_short_plan(tmp_path, monkeypatch):
    monkeypatch.setattr(LocalMeshBootstrap, "guard_host_local",
                        lambda self: (True, ""), raising=True)
    monkeypatch.setattr(LocalMeshBootstrap, "preflight",
                        lambda self: [_M2_PROBLEM], raising=True)
    # up() first TRIES to build the registry itself (the self-heal below); stub it
    # failing so this test still exercises the refusal path — and so no test ever
    # shells out to a real `make stack-m2-bootstrap`.
    monkeypatch.setattr(LocalMeshBootstrap, "m2_bootstrap",
                        lambda self, on_line=None, cancel=None: (False, ["[m2] nope"]),
                        raising=True)

    def _boom(self):  # pragma: no cover - the assertion IS the test
        raise AssertionError("creds must NOT be minted when preflight fails")
    monkeypatch.setattr(LocalMeshBootstrap, "generate_creds", _boom, raising=True)

    b = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(out_dir=str(tmp_path)))
    ok, log = b.up()
    assert ok is False
    # SHORT: the attempt + its failure, no wall of compose noise, and never silent
    assert any("[m2-bootstrap] FAILED" in ln for ln in log)
    assert len(log) <= 4
    # nothing was generated
    assert not os.path.exists(b.secrets_json)


def test_bootstrap_up_builds_the_maven_prereq_itself_then_continues(tmp_path, monkeypatch):
    """The "clean, then start a new mesh" cliff: after Stop & clean the only blocker
    is the private-maven registry, and pressing Start used to just refuse with a hint
    naming a DIFFERENT button. up() now runs that prerequisite itself and carries on."""
    monkeypatch.setattr(LocalMeshBootstrap, "guard_host_local",
                        lambda self: (True, ""), raising=True)
    calls = {"preflight": 0, "m2": 0}

    def _preflight(self):
        calls["preflight"] += 1
        return [_M2_PROBLEM] if calls["preflight"] == 1 else []   # cleared by the build

    def _m2(self, on_line=None, cancel=None):
        calls["m2"] += 1
        return True, ["[m2-bootstrap] ok"]

    monkeypatch.setattr(LocalMeshBootstrap, "preflight", _preflight, raising=True)
    monkeypatch.setattr(LocalMeshBootstrap, "m2_bootstrap", _m2, raising=True)
    monkeypatch.setattr(LocalMeshBootstrap, "generate_creds",
                        lambda self: (False, "stop here — past the gate is enough"),
                        raising=True)

    b = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(out_dir=str(tmp_path)))
    ok, log = b.up()
    assert calls["m2"] == 1, "the maven prerequisite was not built"
    assert calls["preflight"] == 2, "preflight was not re-checked after the build"
    assert not any("preflight failed" in ln for ln in log), \
        "it refused even though the build cleared the only problem"
    assert any("[creds]" in ln for ln in log), "never reached the next step"


def test_bootstrap_up_does_not_self_heal_problems_it_cannot_fix(tmp_path, monkeypatch):
    """Only the maven prerequisite is ours to fix. A dead docker daemon (or any other
    problem alongside it) must still refuse — building maven artifacts would not help
    and would waste minutes before the same failure."""
    monkeypatch.setattr(LocalMeshBootstrap, "guard_host_local",
                        lambda self: (True, ""), raising=True)
    monkeypatch.setattr(LocalMeshBootstrap, "preflight",
                        lambda self: [_M2_PROBLEM, "docker daemon is not reachable"],
                        raising=True)

    def _boom(self, on_line=None, cancel=None):  # pragma: no cover
        raise AssertionError("must not build maven prereqs for an unrelated problem")
    monkeypatch.setattr(LocalMeshBootstrap, "m2_bootstrap", _boom, raising=True)
    monkeypatch.setattr(LocalMeshBootstrap, "generate_creds",
                        lambda self: (_ for _ in ()).throw(AssertionError("no mint")),
                        raising=True)

    b = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(out_dir=str(tmp_path)))
    ok, log = b.up()
    assert ok is False
    assert any("preflight failed" in ln for ln in log)


def test_bootstrap_preflight_delegates_to_stack_node(tmp_path, monkeypatch):
    sentinel = ["problem-x"]
    monkeypatch.setattr(LocalStackNode, "preflight",
                        lambda self: list(sentinel), raising=True)
    b = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(out_dir=str(tmp_path)))
    assert b.preflight() == sentinel


def test_m2_registry_container_carries_the_empty_bind_boot_guard():
    """A reboot reproduces this deterministically: dockerd honours the registry's
    restart policy within seconds of boot, BEFORE a late-mounting /home (its own
    filesystem) is up, so the bind grabs the EMPTY underlay dir and every artifact
    404s until someone recreates the container by hand. The container command must
    refuse to serve an empty bind — exit, so each restart-policy retry re-resolves
    the bind and the first one after /home lands serves for real. (Waiting inside
    instead would wait forever: the bind is resolved at container start.)"""
    path = os.path.join(GENERATOR_DIR, "tests", "stack", "m2-bootstrap.sh")
    with open(path, encoding="utf-8") as fh:
        sh = fh.read()
    start = sh[sh.index("_start_registry()"):]
    body = start[:start.index("\n}")]
    assert "ls -A /www/groups" in body and "exit 1" in body, \
        "the empty-bind guard is gone — a reboot will serve 404s again"
    assert "exec httpd" in body, "the guard must exec httpd only after the check"
    assert body.index("exit 1") < body.index("exec httpd"), \
        "the guard must run BEFORE the server starts"
