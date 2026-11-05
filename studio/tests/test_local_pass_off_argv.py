"""The Login Password never rides the build's process argv (PR #860 round-1 note).

Before: a Studio build ran ``sudo env … bash ./build-*.sh … --local-pass PASS`` (native)
or ``docker run … bash -c '… --local-pass PASS'`` (docker), so the plaintext sat in
/proc/<pid>/cmdline — world-readable — for the whole multi-hour build, and in
``docker inspect`` for the container's lifetime. Now BuildDriver.run()/iter_run() stage
it to a private 0600 file and pass ``--local-pass-file PATH``; the builders read it with
scripts/_passhash-lib.sh ph_read_pass_file.

The native test spawns a REAL process (a stand-in builder script in a throwaway
generator dir, no elevation: the host is root-shaped so no sudo prefix) and reads that
process's own /proc cmdline. No assertion message ever includes the password.
"""
from __future__ import annotations

import os
import stat
import sys

import pytest

from hugmesh_studio.core import build_driver as bd
from hugmesh_studio.core.build_driver import BuildDriver
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.platform_info import HostInfo

THROWAWAY = "throwaway-argv-pw-7Q"
ROOT_HOST = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                     has_kvm=False, is_root=True, builder_image="hugmesh-builder")

pytestmark = pytest.mark.skipif(not sys.platform.startswith("linux"),
                                reason="reads /proc/<pid>/cmdline")

# Stand-in builder: records its own argv (from /proc, i.e. what `ps` shows), the
# password file's mode and a copy of its content into $PROBE_DIR, then exits 0.
FAKE_BUILDER = r"""#!/usr/bin/env bash
out="${PROBE_DIR:?}"
cp /proc/$$/cmdline "${out}/cmdline"
cp /proc/${PPID}/cmdline "${out}/parent-cmdline" 2>/dev/null || true
cat /proc/$$/environ > "${out}/environ" 2>/dev/null || true
f=""
while [ $# -gt 0 ]; do
    case "$1" in --local-pass-file) f="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${f}" ] || { echo "no --local-pass-file" > "${out}/err"; exit 3; }
stat -c '%a' "${f}" > "${out}/mode"
stat -c '%a' "$(dirname "${f}")" > "${out}/dirmode"
cp "${f}" "${out}/content"
echo "${f}" > "${out}/path"
echo "fake build done"
"""


def _gen_dir(tmp_path, cfg: ImageConfig) -> str:
    gen = tmp_path / "gen"
    gen.mkdir()
    script = gen / cfg.builder_script
    script.write_text(FAKE_BUILDER)
    script.chmod(0o755)
    return str(gen)


@pytest.mark.parametrize("cfg_kw", [
    dict(mode="standalone", role="standalone-thick", platform="x86"),
    dict(mode="mesh", role="laptop", platform="x86"),
    dict(mode="cloud", role="rpi5-desktop", platform="rpi5"),
])
def test_native_build_argv_never_carries_the_password(tmp_path, monkeypatch, cfg_kw):
    cfg = ImageConfig(**cfg_kw, local_user="magus", local_pass=THROWAWAY)
    assert ("--local-pass", THROWAWAY) in zip(cfg.to_cli_args(), cfg.to_cli_args()[1:])
    probe = tmp_path / "probe"
    probe.mkdir()
    monkeypatch.setenv("PROBE_DIR", str(probe))
    monkeypatch.setenv("TMPDIR", str(tmp_path / "t"))
    (tmp_path / "t").mkdir()
    drv = BuildDriver(_gen_dir(tmp_path, cfg), ROOT_HOST, workdir=str(tmp_path / "out"))
    spawned: list[list[str]] = []
    real_spawn = drv._spawn

    def spy(cmd, backend):
        spawned.append(list(cmd))
        return real_spawn(cmd, backend)
    monkeypatch.setattr(drv, "_spawn", spy)
    lines: list[str] = []
    rc = drv.run(cfg, backend="native", on_line=lines.append)
    assert rc == 0, "stand-in builder failed: " + (probe / "err").read_text() \
        if (probe / "err").exists() else f"rc={rc}"
    secret = THROWAWAY.encode()
    # what Popen was handed, and what the kernel shows for the process and its parent
    assert spawned and not any(THROWAWAY in a for a in spawned[0]), \
        "the spawned argv carries the Login Password"
    assert "--local-pass-file" in spawned[0] and "--local-pass" not in spawned[0]
    assert secret not in (probe / "cmdline").read_bytes(), "/proc/<pid>/cmdline carries it"
    assert secret not in (probe / "parent-cmdline").read_bytes()
    assert secret not in (probe / "environ").read_bytes(), "/proc/<pid>/environ carries it"
    assert not any(THROWAWAY in ln for ln in lines), "the build log carries it"
    # the builder got it, through a private file that is gone after the run
    assert (probe / "content").read_bytes() == secret, "builder read a different password"
    assert (probe / "mode").read_text().strip() == "600"
    assert (probe / "dirmode").read_text().strip() == "700"
    staged = (probe / "path").read_text().strip()
    assert not os.path.exists(staged) and not os.path.exists(os.path.dirname(staged)), \
        "the staged password file outlived the run"
    assert not str(staged).startswith(str(tmp_path / "out")), "staged under the build workdir"


def test_failed_build_still_removes_the_password_file(tmp_path, monkeypatch):
    cfg = ImageConfig(mode="mesh", role="laptop", platform="x86",
                      local_user="magus", local_pass=THROWAWAY)
    gen = tmp_path / "gen"
    gen.mkdir()
    script = gen / cfg.builder_script
    script.write_text('#!/usr/bin/env bash\nwhile [ $# -gt 0 ]; do [ "$1" = --local-pass-file ] '
                      '&& echo "$2" > "$PROBE_DIR/path"; shift; done\nexit 7\n')
    script.chmod(0o755)
    probe = tmp_path / "probe"
    probe.mkdir()
    monkeypatch.setenv("PROBE_DIR", str(probe))
    drv = BuildDriver(str(gen), ROOT_HOST, workdir=str(tmp_path / "out"))
    assert drv.run(cfg, backend="native") == 7
    staged = (probe / "path").read_text().strip()
    assert staged and not os.path.exists(staged)


def test_docker_argv_mounts_the_file_and_never_carries_the_password(tmp_path):
    cfg = ImageConfig(mode="cloud", role="desktop", platform="x86",
                      local_user="magus", local_pass=THROWAWAY)
    pw_file = tmp_path / "local-pass"
    pw_file.write_text(THROWAWAY)
    pw_file.chmod(0o600)
    drv = BuildDriver(str(tmp_path), ROOT_HOST, workdir=str(tmp_path / "out"))
    cmd = drv.command(cfg, "docker", local_pass_file=str(pw_file))
    assert not any(THROWAWAY in a for a in cmd), "docker run argv (docker inspect) carries it"
    assert f"{pw_file}:{bd.DOCKER_LOCAL_PASS_PATH}:ro" in cmd
    inner = cmd[-1]
    assert f"--local-pass-file {bd.DOCKER_LOCAL_PASS_PATH}" in inner
    assert stat.S_IMODE(os.stat(pw_file).st_mode) == 0o600


def test_swap_only_touches_the_structured_pair():
    argv = ["--role", "laptop", "--local-pass", THROWAWAY, "--x", THROWAWAY]
    out = bd._swap_local_pass(argv, THROWAWAY, "/p")
    assert out == ["--role", "laptop", "--local-pass-file", "/p", "--x", THROWAWAY]
    assert bd._swap_local_pass(["--a"], THROWAWAY, "/p") == ["--a"]
