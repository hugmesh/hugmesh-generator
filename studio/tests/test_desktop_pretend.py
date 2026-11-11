"""The Desktop step's emerge --pretend check and the assistant's portage tool (Qt-free).

core/desktop_pretend.py parses the wire contract scripts/_pretend-lib.sh prints (the same
fixtures the builder-side test feeds a stub emerge), fails CLOSED, gates on the machine
being free, and runs the image's own builder with --pretend-only in its own build subdir.
core/assistant_portage.py turns a ```portage block into checked, labelled overlay lines.
core/desktop_cli.py is the third face (--desktop-options / --desktop-pretend).
core/build_driver.py stages the extra accounts' passwords for one run, never on argv.
"""
from __future__ import annotations

import json
import os

import pytest

from hugmesh_studio.core import assistant_portage as aport
from hugmesh_studio.core import assistant_prompt as aprompt
from hugmesh_studio.core import desktop_cli
from hugmesh_studio.core import desktop_pretend as dp
from hugmesh_studio.core import desktop_spec as ds
from hugmesh_studio.core.assistant_context import Where
from hugmesh_studio.core.build_driver import DOCKER_EXTRA_PASS_PATH, BuildDriver
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.platform_info import HostInfo

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.dirname(STUDIO_ROOT)
FIX = os.path.join(GEN, "tests", "scripts", "fixtures", "desktop-pretend")
HOST = HostInfo(os="linux", is_gentoo=False, has_docker=True, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

NEEDS = ["==> Pretend result: status=needs rc=1 seed_python=python3_13,python3_14 video_cards=intel",
         "==> Pretend needs: accept_keywords =media-video/obs-studio-32.2.2 ~amd64",
         "==> Pretend needs: package.use >=media-video/ffmpeg-7.1.5 opus x264",
         "==> Pretend needs: mask =media-libs/x-1.0",
         dp.EXCERPT_BEGIN, "The following USE changes are necessary to proceed:", dp.EXCERPT_END]
CLEAN = ["==> Pretend result: status=clean rc=0 seed_python=python3_13 video_cards=intel",
         dp.EXCERPT_BEGIN, "Total: 3 packages", dp.EXCERPT_END]


def _laptop(**kw):
    return ImageConfig(**{"mode": "standalone", "role": "chromebook", "platform": "x86", **kw})


# ── parse: the wire contract, fail-closed ────────────────────────────────────────────

def test_parse_a_needs_result():
    r = dp.parse(NEEDS, 3)
    assert r.status == "needs" and r.seed_python == ["python3_13", "python3_14"]
    assert r.needs == [("accept_keywords", "=media-video/obs-studio-32.2.2 ~amd64"),
                       ("package.use", ">=media-video/ffmpeg-7.1.5 opus x264"),
                       ("mask", "=media-libs/x-1.0")]
    assert [c.kind for c in r.applicable_needs()] == ["accept_keywords", "package.use"]
    assert r.operator_needs() == [("mask", "=media-libs/x-1.0")]
    assert r.excerpt == ["The following USE changes are necessary to proceed:"]


def test_parse_clean():
    r = dp.parse(CLEAN, 0)
    assert r.status == "clean" and r.needs == [] and r.excerpt == ["Total: 3 packages"]


@pytest.mark.parametrize("lines,rc,why", [
    ([], 0, "printed no pretend result"),                                    # nothing ran
    (CLEAN, 1, "contradicts"),                                               # exit vs status
    (NEEDS, 0, "contradicts"),
    (["==> Pretend result: status=needs rc=1 seed_python= video_cards="], 3, "named no change"),
    (["==> Pretend result: status=bogus rc=0 seed_python= video_cards="], 0, ""),
    (CLEAN[:1] + ["==> Pretend needs: package.use a/b c"], 0, "also named changes"),
])
def test_parse_fails_closed(lines, rc, why):
    r = dp.parse(lines, rc)
    assert r.status == "error"
    assert why in r.reason


def test_parse_strips_colour_codes():
    r = dp.parse(["\x1b[1m==> Pretend result: status=clean rc=0 seed_python=p video_cards=\x1b[0m"], 0)
    assert r.status == "clean"


def test_a_real_clean_run_parses_clean():
    """clean-real.txt is the REAL --verbose resolver output of the 2026-11-11 baseline run
    (portage prints "Total: N packages" only with --verbose — the positive evidence)."""
    import subprocess
    script = (f'. "{GEN}/scripts/_pretend-lib.sh"; '
              '_hugmesh_pretend_conf_list() { printf "python3_14"; }; '
              f'hugmesh_pretend_report "{FIX}/clean-real.txt" 0')
    p = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    r = dp.parse(p.stdout.splitlines(), p.returncode)
    assert (p.returncode, r.status, r.needs) == (0, "clean", [])
    assert r.excerpt[-1].startswith("Total: 687 packages")


def test_the_builders_own_output_parses(tmp_path):
    """The shell side prints what this side parses: run scripts/_pretend-lib.sh's report on
    the shared fixture and feed its stdout to parse()."""
    import subprocess
    script = (f'. "{GEN}/scripts/_pretend-lib.sh"; '
              '_hugmesh_pretend_conf_list() { printf "python3_13"; }; '
              f'hugmesh_pretend_report "{FIX}/needs.txt" 1')
    p = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert p.returncode == 3
    r = dp.parse(p.stdout.splitlines(), p.returncode)
    assert r.status == "needs"
    assert ("package.use", ">=media-video/ffmpeg-7.1.5 opus x264") in r.needs
    assert r.excerpt and r.excerpt[-1].startswith("experimental or unstable")


# ── what runs ────────────────────────────────────────────────────────────────────────

def test_the_command_is_the_images_own_builder_with_pretend_only(tmp_path):
    cfg = _laptop()
    ds.store(cfg, ds.DesktopSpec(extra_users=[ds.ExtraUser("ann")], sessions=["i3"]))
    cfg.local_pass = "login-pw"
    drv = BuildDriver(GEN, HOST, workdir=str(tmp_path))
    argv = dp.command(cfg, drv, "docker")
    inner = argv[-1]
    assert argv[:2] == ["docker", "run"] and "build-x86-host-stage4.sh" in inner
    assert "--pretend-only" in inner and "--desktop-sessions i3" in inner
    assert f"--build-subdir pretend-{dp.config_key(cfg)}" in inner
    assert "--extra-local-users" not in inner and "login-pw" not in inner and "--resume" not in inner
    # the user's own config is untouched
    assert ds.spec_of(cfg).extra_users and cfg.local_pass == "login-pw"


def test_the_key_follows_the_desktop_relevant_config_only():
    a, b = _laptop(), _laptop(hostname="other")
    assert dp.config_key(a) == dp.config_key(b)
    ds.store(b, ds.DesktopSpec(use_lines=["media-libs/mesa vulkan"]))
    assert dp.config_key(a) != dp.config_key(b)
    c = _laptop()
    ds.store(c, ds.DesktopSpec(history=[{"op": "add"}], last_pretend={"status": "clean"}))
    assert dp.config_key(a) == dp.config_key(c)


def test_supported_only_on_x86_desktops():
    assert dp.supported(_laptop()) == ""
    assert "x86 images for now" in dp.supported(ImageConfig(mode="cloud", role="orangepi5", platform="orangepi5"))
    assert "no desktop" in dp.supported(ImageConfig(mode="mesh", role="backend", platform="x86"))


@pytest.mark.parametrize("kw,needle", [
    (dict(sessions_active=True), "A build is running"),
    (dict(procs=["/usr/bin/qemu-system-x86_64 -name x"]), "qemu-system"),
    (dict(procs=["bash ./build-frite-stage4.sh -w /out"]), "build-frite-stage4.sh"),
    (dict(images=["hugmesh-builder:latest"]), "builder container"),
    (dict(mem_gib=4.0), "memory"),
    (dict(free_gib=10.0), "needs 60 GiB"),
])
def test_the_gate_waits_its_turn(tmp_path, kw, needle):
    base = dict(procs=[], images=[], mem_gib=32.0, free_gib=500.0)
    base.update(kw)
    assert needle in dp.gate(str(tmp_path), **base)


def test_the_gate_opens_on_a_quiet_machine(tmp_path):
    assert dp.gate(str(tmp_path), procs=["bash", "python3 -m hugmesh_studio"], images=["postgres:16"],
                   mem_gib=32.0, free_gib=500.0) == ""


def test_a_shell_that_only_mentions_a_build_does_not_hold_the_gate(tmp_path):
    """pgrep -f's self-match trap: a grep or a shell snippet naming the builder is not a
    build. Only the PROGRAM counts (argv[0], or argv[1] after an interpreter)."""
    quiet = [["grep", "-E", "qemu-system|build-x86-host-stage4.sh"],
             ["/bin/bash", "-c", "pgrep -af 'build-frite-stage4.sh'"],
             ["less", "build-x86-host-stage4.sh"]]
    assert dp.gate(str(tmp_path), procs=quiet, images=[], mem_gib=32.0, free_gib=500.0) == ""
    busy = [["/usr/bin/sudo", "env", "X=1", "bash", "./build-x86-host-stage4.sh"],
            ["bash", "./build-x86-host-stage4.sh", "-w", "/out"]]
    assert "build-x86-host-stage4.sh" in dp.gate(str(tmp_path), procs=busy[1:], images=[],
                                                 mem_gib=32.0, free_gib=500.0)


class _FakeDriver:
    def __init__(self, lines, rc):
        self.lines, self.rc = lines, rc
        self.host = HOST
        self.argv = None

    def command(self, cfg, backend=None):
        self.argv = cfg.to_cli_args()
        return ["fake-builder", *self.argv]

    def _stream(self, argv, on_line, backend):
        for ln in self.lines:
            on_line(ln)
        return self.rc


def test_run_records_the_log_and_result(tmp_path):
    cfg = _laptop()
    res = dp.run(cfg, _FakeDriver(NEEDS, 3), out_dir=str(tmp_path))
    assert res.status == "needs" and os.path.isfile(res.log_path)
    rdir = dp.record_dir(str(tmp_path), cfg)
    assert os.path.dirname(res.log_path) == rdir
    saved = json.load(open(os.path.join(rdir, f"{res.run_id}.json"), encoding="utf-8"))
    assert saved["status"] == "needs"
    dp.record(cfg, res)
    assert ds.spec_of(cfg).last_pretend["status"] == "needs"
    assert ds.cli_args(cfg) == []                     # a record never reaches the builder


# ── the CLI face ─────────────────────────────────────────────────────────────────────

def test_cli_pretend_then_apply_then_clean(tmp_path, capsys):
    path = str(tmp_path / "c.json")
    cfg = _laptop(output_dir=str(tmp_path / "out"))
    ds.store(cfg, ds.DesktopSpec(apps=[ds.DesktopApp("obs-studio", "OBS", "native",
                                                     atom="media-video/obs-studio")]))
    cfg.save(path)
    rc = desktop_cli.pretend(path, generator_dir=GEN, driver=_FakeDriver(NEEDS, 3))
    assert rc == 3
    assert ds.spec_of(ImageConfig.load(path)).use_lines == []          # not without the flag
    rc = desktop_cli.pretend(path, generator_dir=GEN, apply_fixes=True, driver=_FakeDriver(NEEDS, 3))
    spec = ds.spec_of(ImageConfig.load(path))
    assert spec.use_lines == [">=media-video/ffmpeg-7.1.5 opus x264"]
    assert spec.keyword_lines == ["=media-video/obs-studio-32.2.2 ~amd64"]
    assert {h["source"] for h in spec.history} == {"autounmask"}
    capsys.readouterr()
    drv = _FakeDriver(CLEAN, 0)
    assert desktop_cli.pretend(path, generator_dir=GEN, driver=drv, as_json=True) == 0
    assert "--package-use" in drv.argv and "--pretend-only" in drv.argv
    assert json.loads(capsys.readouterr().out)["status"] == "clean"


def test_cli_refuses_an_arm_config(tmp_path, capsys):
    path = str(tmp_path / "c.json")
    ImageConfig(mode="cloud", role="orangepi5", platform="orangepi5").save(path)
    assert desktop_cli.pretend(path, generator_dir=GEN, driver=_FakeDriver(CLEAN, 0)) == 2
    assert "x86 images for now" in capsys.readouterr().err


def test_cli_options_json(capsys):
    assert desktop_cli.options(as_json=True) == 0
    d = json.loads(capsys.readouterr().out)
    assert [s["name"] for s in d["sessions"]] == [s.name for s in ds.SESSION_CATALOG]
    assert {a["id"] for a in d["apps"]} == {a["id"] for a in ds.app_catalog()}


# ── the assistant's portage tool ─────────────────────────────────────────────────────

def test_a_portage_block_is_parsed_checked_and_labelled():
    cfg = _laptop()
    answer = ("Portage wants these.\n```portage\n"
              "package.use >=media-video/ffmpeg-7.1.5 opus x264\n"
              "use: media-libs/mesa vulkan\n"
              "accept_keywords =media-video/obs-studio-32.2.2 ~amd64\n"
              "accept_keywords gui-wm/labwc **\n"
              "mask =media-libs/x-1.0\n"
              "rm -rf /\n```")
    needs = dp.parse(NEEDS, 3).needs
    p = aport.parse(answer, cfg, needs)
    assert p.sentence == "Portage wants these."
    kinds = [(x.kind, bool(x.problem), x.note) for x in p.lines]
    assert kinds == [("package.use", False, ""), ("package.use", False, aport.NOT_PORTAGES_OWN),
                     ("accept_keywords", False, ""), ("accept_keywords", True, ""),
                     ("mask", True, ""), ("?", True, "")]
    assert len(p.applicable()) == 3
    applied = aport.apply(cfg, p, pretend_run="r1")
    assert {h["source"] for h in ds.spec_of(cfg).history} == {"assistant"}
    aport.undo(cfg, applied)
    assert ds.spec_of(cfg).use_lines == []


def test_no_block_no_proposal():
    assert aport.parse("Just words.", _laptop()) is None


def test_the_prompt_carries_the_pretend_facts_and_format_on_the_desktop_step_only(tmp_path):
    cfg = _laptop()
    block = aport.pretend_block(cfg, dp.parse(NEEDS, 3))
    assert "needs: package.use >=media-video/ffmpeg-7.1.5 opus x264" in block
    env = {"HOME": str(tmp_path), "HUGMESH_LOCAL_AI_DIR": str(tmp_path / "ai")}
    p = aprompt.build("fix it", Where(face="gui", slug="desktop"), env=env,
                      generator_dir=GEN, snippets=[], pretend_block=block, ctx_tokens=16000)
    assert "# emerge --pretend" in p.system and "tagged portage" in p.system
    p = aprompt.build("fix it", Where(face="gui", slug="home"), env=env,
                      generator_dir=GEN, snippets=[], pretend_block=block, ctx_tokens=16000)
    assert "# emerge --pretend" not in p.system and "tagged portage" not in p.system


def test_the_pretend_facts_are_capped():
    res = dp.parse(NEEDS, 3)
    res.excerpt = [f"line {i} " + "x" * 200 for i in range(400)]
    block = aport.pretend_block(_laptop(), res)
    from hugmesh_studio.core.assistant_context import tokens
    assert tokens(block) <= aport.PRETEND_TOKEN_CAP + 20


# ── the extra accounts' passwords: a 0600 file for one run, never argv ──────────────

def test_the_password_file_is_staged_and_swapped_in(tmp_path):
    cfg = _laptop()
    ds.store(cfg, ds.DesktopSpec(extra_users=[ds.ExtraUser("ann")]))
    cfg.extra_local_passes = "ann:pw-ann\n"
    drv = BuildDriver(GEN, HOST, workdir=str(tmp_path))
    preview = drv.command(cfg, "docker")
    assert ds.EXTRA_PASS_PLACEHOLDER in preview[-1] and "pw-ann" not in " ".join(preview)
    cleanup = drv._stage_extra_pass(cfg)
    try:
        path = drv._extra_pass_file
        assert oct(os.stat(path).st_mode & 0o777) == "0o600"
        assert open(path, encoding="utf-8").read() == "ann:pw-ann\n"
        argv = drv.command(cfg, "docker")
        assert f"{path}:{DOCKER_EXTRA_PASS_PATH}:ro" in argv
        assert f"--extra-local-pass-file {DOCKER_EXTRA_PASS_PATH}" in argv[-1]
        native = drv.command(cfg, "native")
        assert path in native and "pw-ann" not in " ".join(native)
    finally:
        cleanup()
    assert not os.path.exists(path) and drv._extra_pass_file is None


def test_preflight_asks_for_a_missing_password(tmp_path):
    cfg = _laptop()
    ds.store(cfg, ds.DesktopSpec(extra_users=[ds.ExtraUser("ann")]))
    drv = BuildDriver(GEN, HOST, workdir=str(tmp_path))
    assert any("first-login password" in p for p in drv.preflight(cfg, "docker"))
    cfg.extra_local_passes = "ann:pw\n"
    assert not any("first-login password" in p for p in drv.preflight(cfg, "docker"))


def test_the_check_runs_in_the_container_even_on_a_native_default_host(tmp_path):
    """A Gentoo host defaults to the NATIVE backend (a root build behind sudo); the check
    must still run in the builder container."""
    gentoo = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                      has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    assert gentoo.default_backend == "native"
    drv = BuildDriver(GEN, gentoo, workdir=str(tmp_path))
    assert dp.command(_laptop(), drv)[:2] == ["docker", "run"]
    no_docker = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                         has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    res = dp.run(_laptop(), BuildDriver(GEN, no_docker, workdir=str(tmp_path)), out_dir=str(tmp_path))
    assert res.status == "error" and "Docker is not available" in res.reason
