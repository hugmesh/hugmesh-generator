"""core/kernel_reconfig.py — the Qt-free half of the Build page's "Kernel config…".

Pinned here, without Qt, root, docker or a terminal window (every seam injected):

* the contract reader is strict (format 1, known keys only, never evaluated);
* the config diff, and that it answers EXACTLY like the script's own krc_config_diff;
* every refusal sentence ``locate`` / ``apply_refusal`` can give, and the happy target;
* the argv for each backend: docker run (after the build), docker exec into the LIVE
  build container (mid-build), native ``sudo`` for the interactive edit and the build
  driver's own elevation prefix for the streamed apply;
* the terminal hand-off on Linux, WSL, native Windows and macOS (Terminal.app on the
  Studio's shared self-deleting ``.command`` file, core/macos_host — the exact edit
  argv inside the file, never re-quoted through AppleScript), and the copyable command
  when no window can be opened — the spawner is a fake, nothing is ever opened on a
  real desktop;
* the one-build-at-a-time gate matches programs, not shells that mention them;
* apply's result is read from the path the CONTAINER printed, recorded append-only on
  the session, shown by --show-session, and omitted from records that have none;
* the headless CLI's exit codes and refusals.
"""
import json
import os
import shlex
import subprocess

import pytest

from hugmesh_studio.core import build_sessions
from hugmesh_studio.core import golive_target
from hugmesh_studio.core import kernel_reconfig as kr

from _kernel_reconfig_fixture import AFTER, BEFORE, KV, make_session, result_json

GENERATOR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(GENERATOR, "scripts", "kernel-reconfig-x86.sh")


# ── the contract reader ─────────────────────────────────────────────────────────────
def test_read_env_is_strict_and_never_evaluates(tmp_path):
    p = tmp_path / "kernel-reconfig.env"
    p.write_text("KR_FORMAT=1\nBRAND=$(touch PWNED)\nEVIL=1\nBRAND_TITLE=Hug = Mesh\nnoequals\n")
    env = kr.read_env(str(p))
    assert env["BRAND"] == "$(touch PWNED)"          # literal, never run
    assert env["BRAND_TITLE"] == "Hug = Mesh"         # everything after the FIRST '='
    assert "EVIL" not in env
    p.write_text("KR_FORMAT=2\nBRAND=x\n")
    assert kr.read_env(str(p)) == {}                  # a format this reader does not know
    assert kr.read_env(str(tmp_path / "missing")) == {}


def test_the_reader_knows_exactly_the_keys_the_script_reads():
    out = subprocess.run(["bash", "-c", 'KRC_LIB_ONLY=1 source "$1"; printf "%s\\n" ${KRC_ENV_KEYS}',
                          "_", SCRIPT], capture_output=True, text=True, check=True).stdout.split()
    assert sorted(out) == sorted(kr.ENV_KEYS)


# ── the diff ───────────────────────────────────────────────────────────────────────
def test_diff_configs_names_every_change(tmp_path):
    (tmp_path / "b").write_text(BEFORE + "CONFIG_GONE=y\n")
    (tmp_path / "a").write_text(AFTER + "CONFIG_NEW=m\n")
    ch = kr.diff_configs(kr.parse_config(str(tmp_path / "b")), kr.parse_config(str(tmp_path / "a")))
    assert [c.render() for c in ch] == [
        "CONFIG_GONE: y -> (unset)",
        'CONFIG_LOCALVERSION: "" -> "-hmtest"',
        "CONFIG_NEW: (unset) -> m",
        "CONFIG_USB_NET_CDC_NCM: m -> n (not set)",
    ]
    assert kr.format_diff([]) == "(no change)"


def test_python_diff_and_the_scripts_diff_agree(tmp_path):
    (tmp_path / "b").write_text(BEFORE + "CONFIG_GONE=y\n# CONFIG_C is not set\n")
    (tmp_path / "a").write_text(AFTER + "CONFIG_NEW=m\nCONFIG_C=y\n")
    sh = subprocess.run(["bash", "-c", 'KRC_LIB_ONLY=1 source "$1"; krc_config_diff "$2" "$3"',
                         "_", SCRIPT, str(tmp_path / "b"), str(tmp_path / "a")],
                        capture_output=True, text=True, check=True).stdout.splitlines()
    py = kr.format_diff(kr.diff_configs(kr.parse_config(str(tmp_path / "b")),
                                        kr.parse_config(str(tmp_path / "a")))).splitlines()
    assert py == sh


# ── locate: every refusal, then the target ──────────────────────────────────────────
def test_locate_finds_the_first_x86_image(tmp_path):
    s = make_session(str(tmp_path), pending=True)
    t = kr.locate(s)
    assert isinstance(t, kr.KernelTarget)
    assert t.image_id == "pki.x86" and t.kver == KV and t.signed
    assert t.build_root == os.path.join(s.workdir, "wl-pki.x86")
    assert [c.symbol for c in t.pending_changes()] == ["CONFIG_LOCALVERSION", "CONFIG_USB_NET_CDC_NCM"]
    assert "2 pending change(s)" in t.summary() and "Secure Boot signed" in t.summary()


@pytest.mark.parametrize("kw,expect", [
    ({"platform": "rpi5"}, kr.NOT_X86.format(board="rpi5")),
    ({"tree": False}, kr.NO_TREE),
    ({"config": False}, kr.NO_CONFIG.format(kver=KV)),
])
def test_locate_refusals(tmp_path, kw, expect):
    assert kr.locate(make_session(str(tmp_path), **kw)) == expect


def test_locate_refuses_gone_build_files(tmp_path):
    s = make_session(str(tmp_path))
    import shutil
    shutil.rmtree(os.path.join(s.workdir, "wl-pki.x86", "sysroot"))
    assert kr.locate(s).startswith("The build system for this image is gone")
    shutil.rmtree(s.workdir)
    assert kr.locate(s) == kr.NO_WORKDIR.format(workdir=s.workdir)


@pytest.mark.parametrize("kw,expect", [
    ({"env": False}, kr.NO_ENV),
    ({"image_status": "failed", "status": "failed"}, kr.NOT_OK.format(status="failed")),
])
def test_locate_for_apply_refusals(tmp_path, kw, expect):
    s = make_session(str(tmp_path), **kw)
    assert isinstance(kr.locate(s), kr.KernelTarget)        # editing is still allowed
    assert kr.locate(s, for_apply=True) == expect


def test_locate_for_apply_refuses_a_signed_image_without_its_key(tmp_path):
    s = make_session(str(tmp_path), key=False)
    want = kr.KEY_GONE.format(key=os.path.join(s.workdir, "secureboot", "sb.key"))
    assert kr.locate(s, for_apply=True) == want
    assert isinstance(kr.locate(make_session(str(tmp_path / "u"), signed=False, key=False),
                                for_apply=True), kr.KernelTarget)   # unsigned: no key needed


def test_still_building_refuses_apply_but_not_edit(tmp_path):
    s = make_session(str(tmp_path), status="running", image_status="running")
    s.pid = os.getpid()                       # a LIVE record (not stale)
    t = kr.locate(s)
    assert isinstance(t, kr.KernelTarget) and t.building
    assert kr.locate(s, for_apply=True) == kr.STILL_BUILDING
    assert kr.apply_refusal(t) == kr.STILL_BUILDING
    # the Progress page's own view wins over the record's
    assert not kr.locate(s, image_running=False).building


def test_apply_refusal_sentences(tmp_path):
    t = kr.locate(make_session(str(tmp_path / "a")))
    assert kr.apply_refusal(t) == kr.NO_EDIT
    t = kr.locate(make_session(str(tmp_path / "b"), pending=True, changed=False))
    assert kr.apply_refusal(t) == kr.NO_CHANGE
    t = kr.locate(make_session(str(tmp_path / "c"), pending=True))
    assert kr.apply_refusal(t) == ""


# ── argv ───────────────────────────────────────────────────────────────────────────
def _ctx(**kw):
    base = dict(backend="docker", generator_dir="/gen", builder_image="hugmesh-builder",
                run_container_name="sd-build-abc", elevation=["sudo", "-A"])
    base.update(kw)
    return kr.RunContext(**base)


def test_edit_argv_docker_after_the_build(tmp_path):
    t = kr.locate(make_session(str(tmp_path)))
    a = kr.edit_argv(t, _ctx())
    assert a[:3] == ["docker", "run", "-it"] and "--privileged" in a
    assert f"/gen:/src" in a and f"{t.workdir}:/out" in a
    assert a[-5:] == ["bash", "/src/scripts/kernel-reconfig-x86.sh", "edit", "--build-root",
                      "/out/wl-pki.x86"]
    assert a[a.index("-w") + 1] == "/src" and "hugmesh-builder" in a


def test_docker_mounts_the_shared_seed_read_only(tmp_path):
    """The clean step strips static libraries; the script overlays them from the stage3
    seed in the shared asset root, so the container must see it — read-only."""
    s = make_session(str(tmp_path))
    shared = os.path.join(str(tmp_path), "out", "shared")
    os.makedirs(os.path.join(shared, "seed", "amd64"))
    t = kr.locate(s)
    a = kr.edit_argv(t, _ctx())
    assert f"{shared}:/shared:ro" in a
    n = kr.apply_argv(t, _ctx(backend="native"))
    assert n[n.index("--seed-dir") + 1] == os.path.join(shared, "seed", "amd64")


def test_edit_argv_docker_mid_build_goes_into_the_live_container(tmp_path):
    t = kr.locate(make_session(str(tmp_path)))
    a = kr.edit_argv(t, _ctx(container="sd-build-live"))
    assert a[:3] == ["docker", "exec", "-it"] and "sd-build-live" in a
    assert "run" not in a and "-v" not in a


def test_edit_argv_native_uses_a_plain_sudo_prompt_in_that_terminal(tmp_path):
    t = kr.locate(make_session(str(tmp_path)))
    a = kr.edit_argv(t, _ctx(backend="native"))
    assert a == ["sudo", "bash", "/gen/scripts/kernel-reconfig-x86.sh", "edit",
                 "--build-root", t.build_root]


def test_apply_argv_uses_the_drivers_plumbing(tmp_path):
    t = kr.locate(make_session(str(tmp_path)))
    d = kr.apply_argv(t, _ctx())
    assert "-it" not in d and d[d.index("--name") + 1] == "sd-build-abc"    # cancel reaches it
    n = kr.apply_argv(t, _ctx(backend="native"))
    assert n[:2] == ["sudo", "-A"] and n[-3:] == ["apply", "--build-root", t.build_root]


# ── the terminal window ────────────────────────────────────────────────────────────
class _Spawn:
    def __init__(self):
        self.calls = []

    def __call__(self, argv, **kw):
        self.calls.append((argv, kw))


@pytest.mark.parametrize("osname,platform,which,is_wsl,how,head", [
    ("posix", "linux", {"konsole"}, False, "linux", "konsole"),
    ("posix", "linux", {"cmd.exe", "wt.exe"}, True, "wsl-wt", "cmd.exe"),
    ("nt", "win32", set(), False, "nt", "docker"),
    ("posix", "darwin", set(), False, "darwin", "open"),
])
def test_open_editor_per_os(tmp_path, monkeypatch, osname, platform, which, is_wsl, how, head):
    monkeypatch.setenv("WSL_INTEROP", "/run/WSL/1_interop")
    t = kr.locate(make_session(str(tmp_path)))
    sp = _Spawn()
    ok, said = kr.open_editor(t, _ctx(), spawner=sp, which=lambda b: b if b in which else None,
                              osname=osname, sysplatform=platform, is_wsl=is_wsl,
                              state_dir=str(tmp_path / "state"))
    assert ok and said == how
    assert sp.calls and sp.calls[0][0][0] == head
    assert sp.calls[0][1]["stdin"] == subprocess.DEVNULL


def test_open_editor_without_any_terminal_gives_the_command_to_copy(tmp_path):
    t = kr.locate(make_session(str(tmp_path)))
    sp = _Spawn()
    ok, said = kr.open_editor(t, _ctx(), spawner=sp, which=lambda b: None, osname="posix",
                              sysplatform="linux", is_wsl=False)
    assert not ok and not sp.calls
    assert said == kr.NO_TERMINAL.format(cmd=shlex.join(kr.edit_argv(t, _ctx())))


def test_darwin_menuconfig_runs_the_exact_edit_argv_from_a_command_file(tmp_path):
    # A Mac has no Linux emulator: menuconfig opens through the Studio's ONE macOS route
    # (core/macos_host), a self-deleting .command file Terminal.app runs. The edit argv
    # must reach it shell-quoted exactly once, whatever the build root's path holds.
    t = kr.locate(make_session(str(tmp_path)))
    sp = _Spawn()
    state = tmp_path / "state"
    ok, said = kr.open_editor(t, _ctx(), spawner=sp, which=lambda b: None, osname="posix",
                              sysplatform="darwin", is_wsl=False, state_dir=str(state),
                              terminals=(("xterm", ("-e",)),))
    assert ok and said == "darwin"
    argv = sp.calls[0][0]
    assert argv[:2] == ["open", "-a"] and argv[2] in ("Terminal", "iTerm")
    path = argv[3]
    assert path.endswith(".command") and os.path.dirname(path) == str(state / "term")
    text = open(path, encoding="utf-8").read()
    assert shlex.join(kr.edit_argv(t, _ctx())) in text


def test_darwin_terminal_quotes_a_hostile_build_root_once(tmp_path):
    argv = ["sudo", "bash", "/x/k.sh", "edit", "--build-root", '/o/a "b" \\c $(id) ;x']
    spec = golive_target.terminal_spec(argv, osname="posix", sysplatform="darwin",
                                       state_dir=str(tmp_path), isdir=lambda d: False,
                                       which=lambda b: None)
    assert spec.how == "darwin" and spec.argv[0] == "open"
    text = open(spec.argv[3], encoding="utf-8").read()
    # the command line inside the file is the argv shell-quoted once: no word of it
    # (the $(id), the ;x) can run as its own command
    assert shlex.join(argv) in text


# ── the one-build-at-a-time gate ───────────────────────────────────────────────────
@pytest.mark.parametrize("cmdline,busy", [
    ("qemu-system-x86_64 -name prove -enable-kvm", True),
    ("/usr/bin/qemu-system-x86_64 -m 4096", True),
    ("bash ./build-x86-host-stage4.sh -w /out --role pki", True),
    ("bash /src/scripts/kernel-reconfig-x86.sh apply --build-root /out/wl-x", True),
    ("/bin/bash -c sleep 1500; ps | grep qemu-system-x86_64", False),   # a shell that MENTIONS it
    ("/bin/bash -c tail -f build-x86-host-stage4.sh.log", False),
    ("vim build-notes.txt", False),
])
def test_busy_reason_matches_programs_not_mentions(cmdline, busy):
    assert bool(kr.busy_reason(lambda: [cmdline])) is busy


# ── apply: stream, result, record ──────────────────────────────────────────────────
def _write_result(t, stamp="20261111T130000Z"):
    d = os.path.join(t.build_root, "kernel-reconfig", stamp)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "result.json"), "w") as fh:
        json.dump(result_json(stamp), fh)
    return f"/out/wl-{t.image_id}/kernel-reconfig/{stamp}/result.json"


def test_run_apply_reads_the_result_the_container_named(tmp_path):
    t = kr.locate(make_session(str(tmp_path), pending=True))
    reported = _write_result(t)
    seen, lines = [], []

    def stream(argv, cb):
        seen.append(argv)
        cb("==> Building hardened kernel (reconfigured: menuconfig)")
        cb(f"KRC_RESULT={reported}")
        return 0
    res = kr.run_apply(t, _ctx(), stream, lines.append)
    assert res.rc == 0 and res.result["new_kver"] == KV + "-hmtest"
    assert seen[0][-3:] == ["apply", "--build-root", "/out/wl-pki.x86"]
    assert len(lines) == 2


def test_run_apply_surfaces_the_scripts_refusal(tmp_path):
    t = kr.locate(make_session(str(tmp_path), pending=True))
    res = kr.run_apply(t, _ctx(), lambda a, cb: (cb("[kernel-reconfig] REFUSED: The edit drops SELinux."), 3)[1],
                       lambda s: None)
    assert res.rc == 3 and res.refusal == "The edit drops SELinux." and res.result == {}


def test_record_appends_and_the_detail_shows_it(tmp_path):
    s = make_session(str(tmp_path), pending=True)
    t = kr.locate(s)
    r1 = kr.record(s, t, result_json("20261111T130000Z"))
    r2 = kr.record(s, t, result_json("20261111T140000Z"))
    again = build_sessions.find(s.id)
    assert [r["stamp"] for r in again.kernel_reconfigs] == ["20261111T130000Z", "20261111T140000Z"]
    assert r1 != r2 and r1["changes"] == ["CONFIG_LOCALVERSION"]
    text = build_sessions.format_session_detail(again)
    assert f"kernel reconfigured: pki.x86: kernel {KV} -> {KV}-hmtest" in text
    assert "re-signed, sbverify ok" in text
    assert build_sessions.session_detail(again)["kernel_reconfigs"][0]["new_kver"] == KV + "-hmtest"


def test_a_record_without_reconfigurations_is_unchanged(tmp_path):
    s = make_session(str(tmp_path))
    assert "kernel_reconfigs" not in s.to_dict()            # older records stay byte-identical
    assert "kernel_reconfigs" not in build_sessions.session_row(s)


# ── the headless CLI ───────────────────────────────────────────────────────────────
class _Driver:
    """A BuildDriver stand-in: never sudo, never docker."""

    def __init__(self, on_stream=None):
        self.streams = []
        self._on = on_stream or (lambda argv, cb: 0)

    def reconfig_context(self, backend=None, live_container=""):
        return _ctx(backend=backend or "docker", container=live_container)

    def stream_command(self, argv, cb, backend):
        self.streams.append(argv)
        return self._on(argv, cb)


def test_cli_unknown_session_is_exit_2(tmp_path, capsys):
    assert kr.cli("diff", "nope", GENERATOR, driver=_Driver()) == 2


def test_cli_refuses_an_arm_session_in_one_sentence(tmp_path, capsys):
    s = make_session(str(tmp_path), platform="rpi5")
    assert kr.cli("diff", s.id, GENERATOR, driver=_Driver()) == 3
    assert capsys.readouterr().err.strip() == "refused: " + kr.NOT_X86.format(board="rpi5")


def test_cli_diff_prints_the_pending_change(tmp_path, capsys):
    s = make_session(str(tmp_path), pending=True)
    assert kr.cli("diff", f"{s.id}:pki.x86", GENERATOR, driver=_Driver()) == 0
    out = capsys.readouterr().out
    assert 'CONFIG_LOCALVERSION: "" -> "-hmtest"' in out and "2 pending change(s)" in out


def test_cli_set_needs_arguments_and_streams_them(tmp_path, capsys):
    s = make_session(str(tmp_path))
    d = _Driver()
    assert kr.cli("set", s.id, GENERATOR, driver=d) == 2 and not d.streams
    assert kr.cli("set", s.id, GENERATOR, driver=d,
                  config_args="--set-str LOCALVERSION -hmtest") == 0
    assert d.streams[0][-7:] == ["set", "--build-root", "/out/wl-pki.x86", "--",
                                 "--set-str", "LOCALVERSION", "-hmtest"]


def test_cli_edit_runs_menuconfig_in_this_terminal(tmp_path, capsys):
    s = make_session(str(tmp_path))
    ran = []
    assert kr.cli("edit", s.id, GENERATOR, driver=_Driver(),
                  run_interactive=lambda a: ran.append(a) or 0) == 0
    assert ran and ran[0][-3:] == ["edit", "--build-root", "/out/wl-pki.x86"]


def test_cli_apply_waits_for_the_machine_and_for_an_edit(tmp_path, capsys):
    s = make_session(str(tmp_path))
    assert kr.cli("apply", s.id, GENERATOR, driver=_Driver(), busy=lambda: "") == 3
    assert kr.NO_EDIT in capsys.readouterr().err
    s2 = make_session(str(tmp_path / "b"), sid="20261111-120001-abcdef", pending=True)
    assert kr.cli("apply", s2.id, GENERATOR, driver=_Driver(), busy=lambda: "busy now") == 3
    assert "busy now" in capsys.readouterr().err


def test_cli_apply_records_on_success(tmp_path, capsys):
    s = make_session(str(tmp_path), pending=True)
    t = kr.locate(s)
    reported = _write_result(t)

    def stream(argv, cb):
        cb(f"KRC_RESULT={reported}")
        return 0
    assert kr.cli("apply", s.id, GENERATOR, driver=_Driver(stream), busy=lambda: "") == 0
    assert "recorded on session" in capsys.readouterr().out
    assert build_sessions.find(s.id).kernel_reconfigs[0]["new_build_ts"] == "20261111T130000Z"


def test_cli_apply_refusal_from_the_script_is_exit_3(tmp_path, capsys):
    s = make_session(str(tmp_path), pending=True)
    d = _Driver(lambda argv, cb: (cb("[kernel-reconfig] REFUSED: The Secure Boot key ... is gone."), 3)[1])
    assert kr.cli("apply", s.id, GENERATOR, driver=d, busy=lambda: "") == 3
    assert "refused: The Secure Boot key ... is gone." in capsys.readouterr().err
    assert not build_sessions.find(s.id).kernel_reconfigs


def test_app_wires_the_kernel_config_flags(tmp_path, capsys, monkeypatch):
    from hugmesh_studio import app
    called = {}
    monkeypatch.setattr(kr, "cli", lambda verb, target, gen, **kw: called.update(
        verb=verb, target=target, args=kw.get("config_args")) or 0)
    assert app.main(["--kernel-config-set", "S:pki.x86", "--generator-dir", GENERATOR,
                     "--kernel-config-args=--set-str LOCALVERSION -hmtest"]) == 0
    assert called == {"verb": "set", "target": "S:pki.x86", "args": "--set-str LOCALVERSION -hmtest"}
    for flag, verb in (("--kernel-config", "edit"), ("--kernel-config-diff", "diff"),
                       ("--kernel-config-apply", "apply"), ("--kernel-config-discard", "discard")):
        assert app.main([flag, "S", "--generator-dir", GENERATOR]) == 0 and called["verb"] == verb
    assert app.main(["--kernel-config", "S", "--kernel-config-diff", "S",
                     "--generator-dir", GENERATOR]) == 2
