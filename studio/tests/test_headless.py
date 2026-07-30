"""Headless --print-command: must work with no display and no Qt installed.

The matrix harness drives `python -m hugmesh_studio --print-command --config X.json`
for every role x platform x env — so the path must never import a Qt binding.
"""
import json
import os
import subprocess
import sys

import pytest

from hugmesh_studio.core.config import ImageConfig

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

MATRIX = [
    ("x86", "standalone", "standalone-thin", "test"),
    ("x86", "standalone", "standalone-thick", "prod"),
    ("x86", "standalone", "standalone-unaffiliated", "prod"),
    ("x86", "cloud", "laptop", "test"),
    ("x86", "mesh", "omnibus", "prod"),
    ("rpi5", "standalone", "generic", "test"),
    ("rpi5", "mesh", "be", "prod"),
    ("frite", "cloud", "frite", "test"),
    ("jetson", "mesh", "edge_ai", "prod"),
]


def _write_cfg(tmp_path, platform, mode, role, env):
    # the unaffiliated role hard-conflicts with the tailnet AND with bundling the
    # generator source (its role arm presets both off) — every other row keeps the
    # historical tailscale=True shape
    unaffiliated = role == "standalone-unaffiliated"
    cfg = ImageConfig(mode=mode, role=role, platform=platform, env=env,
                      tailscale=not unaffiliated, bundle_source=not unaffiliated)
    p = tmp_path / f"{platform}-{role}-{env}.json"
    cfg.save(str(p))
    return cfg, str(p)


def test_print_command_in_process_never_imports_qt(tmp_path, capsys):
    from hugmesh_studio import app
    before = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    for platform, mode, role, env in MATRIX:
        cfg, path = _write_cfg(tmp_path, platform, mode, role, env)
        rc = app.main(["--print-command", "--config", path,
                       "--generator-dir", GENERATOR_DIR, "--backend", "native"])
        assert rc == 0
        out = capsys.readouterr().out
        assert cfg.builder_script in out
        assert f"--env {env}" in out
    after = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    assert after == before  # the headless path lazy-imports Qt on GUI paths only


@pytest.mark.parametrize("platform,mode,role,env", MATRIX)
def test_print_command_subprocess_smoke(tmp_path, platform, mode, role, env):
    cfg, path = _write_cfg(tmp_path, platform, mode, role, env)
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    env_vars.pop("DISPLAY", None)          # prove no display is needed
    env_vars.pop("WAYLAND_DISPLAY", None)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", path,
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert cfg.builder_script in r.stdout
    assert ("--role" in r.stdout) == (platform != "frite")


def test_print_command_config_round_trips_cli_args(tmp_path):
    """The printed command must embed exactly to_cli_args() for the loaded config."""
    cfg, path = _write_cfg(tmp_path, "rpi5", "mesh", "fe", "prod")
    reloaded = ImageConfig.load(path)
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", path,
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert " ".join(reloaded.to_cli_args()) in r.stdout
    assert "--role frontend" in r.stdout   # rpi5 spells be/fe out


def test_print_command_new_iso_knobs_flow_through(tmp_path):
    """The BuildPage's img-size / cached / live-toram knobs and the tri-state proxy
    stack ride a saved config through the headless path: explicit values emit their
    flags; proxy_stack=auto (the builder's own default) emits neither flag."""
    explicit = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                           img_size=4096, cached=True, live_toram=False, proxy_stack="off")
    p = tmp_path / "iso-knobs.json"
    explicit.save(str(p))
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert "--img-size 4096" in r.stdout
    assert "--cached" in r.stdout and "--no-live-toram" in r.stdout
    assert "--no-proxy-stack" in r.stdout
    auto = ImageConfig(mode="standalone", role="standalone-thick", platform="x86")
    p2 = tmp_path / "iso-knobs-auto.json"
    auto.save(str(p2))
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p2),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert "--proxy-stack" not in r.stdout and "--img-size" not in r.stdout


def test_print_command_unaffiliated_bundle_default_normalized(tmp_path):
    """The wizard's standalone bundle_source default left on the unaffiliated role is
    NOT a conflict — the headless path normalizes it exactly like the wizard's role
    hook: --print-command succeeds and the argv carries neither --bundle-source nor
    --no-bundle-source (the builder only errors on an EXPLICIT --bundle-source)."""
    cfg = ImageConfig(mode="standalone", role="standalone-unaffiliated", platform="x86",
                      bundle_source=True)
    p = tmp_path / "default-poisoned.json"
    cfg.save(str(p))
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert "--bundle-source" not in r.stdout
    assert "--no-bundle-source" not in r.stdout


def test_print_command_unaffiliated_conflict_fails_loudly(tmp_path):
    """A genuinely poisoned config (a branding theme on the unaffiliated role) must
    make --print-command exit non-zero with the conflict named — mirroring the
    builder's own hard error, never a silently wrong argv."""
    cfg = ImageConfig(mode="standalone", role="standalone-unaffiliated", platform="x86",
                      bundle_source=False, theme="boogiepop")
    p = tmp_path / "poisoned.json"
    cfg.save(str(p))
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode != 0
    assert "unaffiliated" in r.stderr
    assert "theme" in r.stderr


@pytest.mark.parametrize("flag", ["--print-command", "--print-commands", "--print-specs"])
def test_headless_bad_input_exits_2_not_traceback(tmp_path, flag, capsys):
    """Bad INPUT to any --print-* handler must exit 2 with a clean 'error: ...' line,
    never let a TypeError (non-dict JSON) or FileNotFoundError (missing --config) escape
    as a traceback + exit 1 — so a caller/bridge can distinguish bad-input (2) from an
    unexpected crash. (json.JSONDecodeError already exits 2; these two paths did not.)"""
    from hugmesh_studio import app
    # (a) top-level JSON array -> from_dict TypeError normalized to ValueError -> exit 2
    arr = tmp_path / "arr.json"
    arr.write_text("[1, 2, 3]", encoding="utf-8")
    rc = app.main([flag, "--config", str(arr), "--generator-dir", GENERATOR_DIR,
                   "--backend", "native"])
    assert rc == 2
    assert "error:" in capsys.readouterr().err
    # (b) missing --config path -> OSError -> exit 2
    rc = app.main([flag, "--config", str(tmp_path / "does-not-exist.json"),
                   "--generator-dir", GENERATOR_DIR, "--backend", "native"])
    assert rc == 2
    assert "error:" in capsys.readouterr().err


def test_saved_matrix_configs_hold_no_secrets(tmp_path):
    # includes the NEW node-fallback credentials (G27) — SECRET_FIELDS, never saved
    cfg = ImageConfig(local_pass="pw", luks_pass="pw2",
                      user_password="pw3", root_password="pw4")
    p = tmp_path / "s.json"
    cfg.save(str(p))
    data = json.loads(p.read_text(encoding="utf-8"))
    for k in ("local_pass", "luks_pass", "user_password", "root_password"):
        assert data[k] == ""


def test_print_command_headscale_url_env_passthrough(tmp_path):
    """headscale_url is env-only by design (G2): the printed native command must
    carry `env HEADSCALE_URL=…` (inside the sudo boundary when present) and NO
    --headscale-url flag may exist — no builder parses one."""
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86",
                      headscale_url="https://hs.acme.example")
    p = tmp_path / "hs.json"
    cfg.save(str(p))
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert "env HEADSCALE_URL=https://hs.acme.example bash" in r.stdout
    assert "--headscale-url" not in r.stdout


def test_print_command_new_option_fields_flow_through(tmp_path):
    """A representative slice of the newly fielded options (G1/G4/G5/G23/G25/G26)
    rides a saved config through the headless path onto the printed command."""
    cfg = ImageConfig(mode="mesh", role="be", platform="x86",
                      cluster_domain="acme.example", release_state="public",
                      secure_boot="off", grow="16G", hostname="myhost",
                      build_img="off", installer_iso=True)
    p = tmp_path / "new-fields.json"
    cfg.save(str(p))
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    for token in ("--cluster-domain acme.example", "--release-state public",
                  "--no-secure-boot", "--grow 16G", "--hostname myhost",
                  "--no-img", "--installer-iso"):
        assert token in r.stdout


def test_print_command_rejects_worklist_envelope(tmp_path):
    """The load guard: a worklist envelope (explicit `schema` key) must make
    --print-command fail LOUDLY — never silently degrade to a default config. Callers
    route envelopes through worklist.load_any / --print-commands instead."""
    p = tmp_path / "envelope.json"
    p.write_text(json.dumps({"schema": "hugmesh-worklist/v1",
                             "base": ImageConfig().to_dict(), "entries": []}),
                 encoding="utf-8")
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode != 0
    assert "worklist envelope" in r.stderr


def test_print_command_mesh_config_omitting_tailscale_sso_keeps_its_mesh(tmp_path):
    """The PR #304 verify-pass defect, end-to-end: a hand-written mesh config that
    simply OMITS tailscale/sso used to print --no-tailscale --no-sso — a headless
    caller got a non-mesh mesh image. It must now resolve the MODE default ON
    (exactly what NetworkPage seeds), and the printed argv must be accepted by
    the REAL builder's --print-plan with the mesh and SSO planes live."""
    p = tmp_path / "mesh-omnibus.json"
    p.write_text('{"platform": "x86", "mode": "mesh", "role": "omnibus", "env": "test"}\n',
                 encoding="utf-8")
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert "--with-tailscale" in r.stdout and "--with-sso" in r.stdout
    assert "--no-tailscale" not in r.stdout and "--no-sso" not in r.stdout
    # prove the argv against the real builder (its --print-plan runs before the
    # run-as-root gate: no root, no writes — the build-matrix GUITHR pattern)
    cmdline = r.stdout.strip().splitlines()[0]
    cmdline = cmdline.removeprefix("sudo ")
    plan = subprocess.run(["bash", "-c", f"{cmdline} --print-plan"],
                          capture_output=True, text=True, timeout=120, cwd=GENERATOR_DIR)
    assert plan.returncode == 0, plan.stdout + plan.stderr
    assert "PLAN_MESH=headscale=" in plan.stdout      # mesh plane ON, not "skip"
    assert "PLAN_MESH=skip" not in plan.stdout
    assert "PLAN_SSO=casdoor-oidc" in plan.stdout     # SSO plane ON, not "off"


def test_print_command_new_emitted_fields_ride_config_and_reach_argv(tmp_path):
    """superdomain, packages_add and packages_drop all round-trip through a saved config
    AND reach the printed command: superdomain -> --superdomain on a MESH build
    (WS-SUPER-B), packages_add/drop -> --packages-add/--packages-drop (WS-BUILDER). All
    six builders parse each of them."""
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                      superdomain="core.acme.internal",
                      packages_add="app-editors/vim app-misc/tmux",
                      packages_drop="games-util/steam")
    p = tmp_path / "emitted.json"
    cfg.save(str(p))
    reloaded = ImageConfig.load(str(p))
    assert reloaded.superdomain == "core.acme.internal"
    assert reloaded.packages_add == "app-editors/vim app-misc/tmux"
    assert reloaded.packages_drop == "games-util/steam"
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    # superdomain reaches argv on a mesh build (WS-SUPER-B emission flip)
    for token in ("--superdomain", "core.acme.internal"):
        assert token in r.stdout
    # packages_add/packages_drop DO reach argv now (WS-BUILDER emission flip)
    for token in ("--packages-add", "--packages-drop",
                  "app-editors/vim app-misc/tmux", "games-util/steam"):
        assert token in r.stdout


@pytest.mark.parametrize("platform,builder", [
    ("frite", "build-frite-stage4.sh"),
    ("orangepi5", "build-orangepi5-stage4.sh"),
    ("orangepizero2", "build-orangepi-zero2-stage4.sh"),
    ("orangepizero2w", "build-orangepi-zero2w-stage4.sh"),
    ("orangepizero3", "build-orangepi-zero3-stage4.sh"),
    ("orangepi3-lts", "build-orangepi3-lts-stage4.sh"),
])
def test_print_command_iso_unset_flavor_resolves_to_single(tmp_path, platform, builder):
    """G2 source fix on the FLAT single-build channel: an unset flavor on the ARM ISO
    platforms must print `--flavor installer` (one artifact), never to_cli_args's
    `--flavor both` — a two-ISO build the worker dies on after a multi-hour build. The
    flat --print-command path applies the SAME #337 resolver the materialize path does
    (config.resolve_platform_defaults), so the headless single-image command matches the
    real GUI build's single-artifact result."""
    cfg = ImageConfig(mode="cloud", role=platform, platform=platform)  # flavor left unset
    assert cfg.flavor == ""
    p = tmp_path / f"{platform}-unset-flavor.json"
    cfg.save(str(p))
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert builder in r.stdout
    assert "--flavor installer" in r.stdout
    assert "--flavor both" not in r.stdout
    # a plain `sudo ` prefix (graphical stays False on the headless channel) so the
    # build-matrix / test_headless sudo-strippers keep matching — never `sudo -A`/pkexec.
    assert r.stdout.lstrip().startswith("sudo bash ") or r.stdout.lstrip().startswith("bash ")
    assert " -A " not in r.stdout and "pkexec" not in r.stdout


def test_print_command_arm_standalone_real_semantics(tmp_path):
    """The parity harness's standalone-posture configs (rpi5 role=desktop +
    standalone=true — NOT the JOB-grammar 'standalone-desktop' token) must print
    the real builder vocabulary: --role desktop --standalone --local-user."""
    cfg = ImageConfig(mode="standalone", role="desktop", platform="rpi5",
                      board="rpi4", standalone=True)
    p = tmp_path / "rpi5-standalone.json"
    cfg.save(str(p))
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert "--role desktop" in r.stdout and "--standalone" in r.stdout
    assert "--board rpi4" in r.stdout and "--local-user" in r.stdout
    assert "standalone-desktop" not in r.stdout   # the JOB token is not builder vocabulary


def test_print_specs_emits_materialized_flat_specs(tmp_path):
    """The materialization BRIDGE: --print-specs expands a worklist envelope into one flat,
    fully-resolved ImageConfig JSON per materialized image (the spec the web IMAGE_SPEC_JSON /
    build-image.sh channel consumes). SECRET fields are blanked; --image selects one."""
    from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry
    wl = WorklistConfig(
        base=ImageConfig(mode="mesh", brand="acme", local_pass="s3cret"),
        entries=[WorklistEntry(id="omnibus.x86", role="omnibus", platform="x86"),
                 WorklistEntry(id="be.rpi5", role="be", platform="rpi5")])
    p = tmp_path / "wl.json"
    p.write_text(json.dumps(wl.to_dict()), encoding="utf-8")
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)

    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-specs", "--config", str(p),
         "--generator-dir", GENERATOR_DIR],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    specs = [json.loads(line) for line in r.stdout.splitlines() if line.strip()]
    assert len(specs) == 2
    assert [(s["role"], s["platform"]) for s in specs] == [("omnibus", "x86"), ("be", "rpi5")]
    # each spec is a real flat ImageConfig that --print-command accepts, with secrets blanked
    for s in specs:
        assert s.get("local_pass", "") == ""
        cfg = ImageConfig.from_dict(s)   # round-trips as a flat config (no envelope)
        assert cfg.role == s["role"]

    # --image selects exactly one
    r1 = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-specs", "--config", str(p),
         "--image", "1", "--generator-dir", GENERATOR_DIR],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r1.returncode == 0, r1.stderr
    one = [json.loads(line) for line in r1.stdout.splitlines() if line.strip()]
    assert len(one) == 1 and one[0]["platform"] == "rpi5"

    # out-of-range fails loudly
    r2 = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-specs", "--config", str(p),
         "--image", "9", "--generator-dir", GENERATOR_DIR],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r2.returncode == 2 and "out of range" in r2.stderr


# ---- installer-UI role-class resolution on the headless path ---------------------
# app.py's --print-command branch bypasses worklist._materialize_one, so it needs its OWN
# resolve_installer_ui_default() call; without it a headless x86 node prints
# `--installer-ui all` and pulls an UNSATISFIABLE app-admin/calamares (the desktop USE
# closure is ROLE_CLIENT-gated, build-x86-host-stage4.sh:2496). See the real 5x failure in
# session 20260716-235722-54d2f7.

def _flag_value(command_line, flag):
    """The VALUE of `flag` in a printed command line, via a REAL argv parser (shlex) —
    never a substring grep, which would happily match a comment, a longer flag, or the
    wrong occurrence. Returns None when the flag is absent."""
    import shlex
    argv = shlex.split(command_line)
    return argv[argv.index(flag) + 1] if flag in argv else None


@pytest.mark.parametrize("role", ["pki", "be", "fe", "be+gpu", "omnibus", "edge_ai"])
@pytest.mark.parametrize("bad", ["all", "calamares"])
def test_print_command_node_never_emits_a_calamares_installer_ui(tmp_path, role, bad):
    """Every x86 mesh node, fed each WANT_CALAMARES-triggering value, must print
    `--installer-ui cli` — so the builder's WANT_CALAMARES (:1246) stays false."""
    cfg = ImageConfig(mode="mesh", role=role, platform="x86", installer_ui=bad)
    p = tmp_path / f"node-{role}-{bad}.json"
    cfg.save(str(p))
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert _flag_value(r.stdout, "--installer-ui") == "cli"
    # the note is a WARNING: it must ride stderr and NEVER pollute the argv channel
    assert "warning:" in r.stderr and "warning:" not in r.stdout


@pytest.mark.parametrize("mode,role", [("cloud", "laptop"), ("standalone", "standalone-thick")])
def test_print_command_desktop_installer_ui_unchanged(tmp_path, mode, role):
    """No-regression fence: a client/standalone keeps emitting its chosen value, and the
    resolver stays silent (no stderr note)."""
    cfg = ImageConfig(mode=mode, role=role, platform="x86", installer_ui="all")
    p = tmp_path / f"desktop-{role}.json"
    cfg.save(str(p))
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert _flag_value(r.stdout, "--installer-ui") == "all"
    assert "installer_ui" not in r.stderr


def test_print_command_agrees_with_materialize_for_a_node(tmp_path):
    """PARITY: both call sites (app.py's flat path and worklist._materialize_one) must
    resolve identically — a node's printed argv must match its materialized argv. Drop
    either call site and this leg fails."""
    from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry
    base = ImageConfig(mode="mesh", installer_ui="all")
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="pki", platform="x86")])
    _e, materialized = wl.materialize()[0]

    cfg = ImageConfig(mode="mesh", role="pki", platform="x86", installer_ui="all")
    p = tmp_path / "parity.json"
    cfg.save(str(p))
    env_vars = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--print-command", "--config", str(p),
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=60, env=env_vars, cwd=STUDIO_ROOT)
    assert r.returncode == 0, r.stderr
    assert _flag_value(r.stdout, "--installer-ui") == "cli"
    assert materialized.installer_ui == "cli"
