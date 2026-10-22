"""Every ARM cross builder must put HOST gpep517 >= 23 in place before it cross-emerges.

THE FAILURE THIS PINS (rpi5 build, 2026-10-21): in a cross build portage's distutils-r1
eclass builds every python wheel with the BUILD CONTAINER's own gpep517, passing
``--sysroot ${SYSROOT}``. Under --sysroot, gpep517 before 23 replaces
``sysconfig.get_config_vars`` with a function that takes no arguments, and setuptools-84
calls ``get_config_vars(*names)`` while it sets up the C compiler::

    TypeError: patch_sysconfig.<locals>.patched_config_vars() takes 0 positional
    arguments but 9 were given

Portage shows that only as "Wheel build failed". The 2026-09-24 builder image has
gpep517-20 (the only amd64-stable version in its tree) next to a stable setuptools-84, so
sys-libs/libselinux (python USE is profile-forced on hardened/selinux) and dev-python/pypax
fail in @system, and everything that needs them is skipped. That is every ARM board and
every role. gpep517-22 still fails the same way, so the floor is 23, not 22.

x86 is deliberately NOT covered: its emerges run inside ``chroot ${SYSROOT}``, where
gpep517 is the sysroot's own copy, so the x86 builder must not call the helper.

The helper is exercised for real (bash, stubbed portageq/emerge/id on PATH), not grepped:
a call site that names a function nobody defines, or a function that never runs the
emerge, would pass a string test and still ship the broken build.
"""
import os
import re
import subprocess
import textwrap

import pytest

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
LIB = os.path.join(GENERATOR_DIR, "scripts", "_host-guard-lib.sh")

FLOOR = ">=dev-python/gpep517-23"
CALL = "hostguard_ensure_cross_gpep517 || exit 1"

#: Every builder that cross-emerges with SYSROOT set (and so builds wheels with the
#: HOST gpep517 under --sysroot). rpi4/rpi3 are build-rpi5-stage4.sh with --board.
ARM_BUILDERS = [
    "build-rpi5-stage4.sh", "build-frite-stage4.sh", "build-jetson-stage4.sh",
    "build-orangepi5-stage4.sh", "build-orangepi4-lts-stage4.sh",
    "build-orangepi3-lts-stage4.sh", "build-orangepi-zero2-stage4.sh",
    "build-orangepi-zero2w-stage4.sh", "build-orangepi-zero3-stage4.sh",
]


def _read(rel: str) -> str:
    with open(os.path.join(GENERATOR_DIR, rel), encoding="utf-8") as fh:
        return fh.read()


def _live_lines(src: str):
    """(index, line) pairs with comments stripped, so a commented-out call never counts."""
    for i, line in enumerate(src.split("\n")):
        code = line.split("#", 1)[0].rstrip()
        if code.strip():
            yield i, code


def test_arm_builder_list_matches_the_tree():
    """A new ARM builder must be added here, or it silently escapes this guard."""
    on_disk = sorted(
        f for f in os.listdir(GENERATOR_DIR)
        if re.fullmatch(r"build-.+-stage4\.sh", f) and f != "build-x86-host-stage4.sh"
    )
    assert on_disk == sorted(ARM_BUILDERS)


@pytest.mark.parametrize("builder", ARM_BUILDERS)
def test_builder_calls_the_floor_before_any_cross_emerge(builder):
    src = _read(builder)
    live = list(_live_lines(src))
    calls = [i for i, code in live if code.strip() == CALL]
    assert len(calls) == 1, (
        f"{builder} must call `{CALL}` exactly once at top level. Without it the host "
        f"gpep517-20 in the builder image breaks every cross-built python C extension "
        f"(libselinux, pypax) at @system and the whole ARM payload is skipped."
    )
    call = calls[0]
    # It must run after the host-seed/host-tool section (so the host make.conf and the
    # host-bdep pool are already wired) and before the first cross emerge.
    hpt_end = next(i for i, code in live if code.strip() == "HOST_POLICY_TOOLS=()")
    assert call > hpt_end, f"{builder}: floor runs before the host tool section"
    first_cross = min(
        i for i, code in live
        if "${CROSS_TARGET}-emerge" in code or re.match(r"\s*cross_emerge\s", code)
    )
    assert call < first_cross, f"{builder}: floor runs after the first cross emerge"
    # Top level, not hidden inside a conditional that a role or flag can skip.
    assert src.split("\n")[call].startswith(CALL), f"{builder}: call is indented / nested"
    assert "_host-guard-lib.sh" in src, f"{builder} no longer sources the library"


def test_x86_builder_does_not_call_it():
    """x86 builds in chroot with the sysroot's own gpep517; the host floor is not its fix."""
    src = _read("build-x86-host-stage4.sh")
    assert "hostguard_ensure_cross_gpep517" not in src


def test_dockerfile_bakes_the_floor():
    """The image half: the next `make docker-image` ships gpep517 >= 23 already."""
    src = _read("Dockerfile.build")
    m = re.search(
        r"printf '%s\\n' \\\n(?:\s+'[^'\n]*' \\\n)*?\s+'>=dev-python/gpep517-23 ~amd64' \\\n"
        r"\s+> /etc/portage/package\.accept_keywords/hugmesh-host-gpep517\n",
        src,
    )
    assert m, "Dockerfile.build lost the gpep517-23 keyword file"
    emerge = re.search(r"RUN emerge --verbose --noreplace \\\n((?:\s+\S+ \\\n)*\s+\S+)\n", src[m.end():])
    assert emerge and f"'{FLOOR}'" in emerge.group(1).split(), (
        "the final host emerge must install '>=dev-python/gpep517-23'"
    )


# ── behaviour of the helper itself ────────────────────────────────────────────

def _run(tmp_path, *, installed: str, allowed: bool, uid: str = "0", emerge_rc: int = 0,
         emerge_installs: bool = True, have_portageq: bool = True):
    """Run hostguard_ensure_cross_gpep517 with stubbed portageq/emerge/id.

    ``installed`` is the host gpep517 version the stub portageq reports. The stub
    emerge records its argv and, when ``emerge_installs``, "installs" 23.
    """
    bindir = tmp_path / "bin"
    bindir.mkdir()
    state = tmp_path / "state"
    state.write_text(installed)
    log = tmp_path / "emerge.argv"
    qlog = tmp_path / "portageq.argv"
    if have_portageq:
        (bindir / "portageq").write_text(textwrap.dedent(f"""\
            #!/bin/bash
            printf '%s\\n' "$*" >> '{qlog}'
            [ "$1" = has_version ] && [ "$2" = / ] || exit 2
            have=$(cat '{state}')
            case "$3" in
              '>=dev-python/gpep517-23') [ "$have" -ge 23 ] ;;
              '>=dev-python/gpep517-22') [ "$have" -ge 22 ] ;;
              *) exit 2 ;;
            esac
            """))
    (bindir / "emerge").write_text(textwrap.dedent(f"""\
        #!/bin/bash
        printf '%s\\n' "$*" >> '{log}'
        {"echo 23 > '" + str(state) + "'" if emerge_installs else ":"}
        exit {emerge_rc}
        """))
    (bindir / "id").write_text(f"#!/bin/bash\necho {uid}\n")
    for f in bindir.iterdir():
        f.chmod(0o755)
    etc = tmp_path / "etc-portage"
    script = textwrap.dedent(f"""\
        set -euo pipefail
        source '{LIB}'
        hostguard_mutation_allowed() {{ return {0 if allowed else 1}; }}
        hostguard_ensure_cross_gpep517 '{etc}'
        """)
    env = dict(os.environ)
    path = str(bindir) + ":/usr/bin:/bin"
    if not have_portageq:
        path = str(bindir)  # nothing else on PATH may provide portageq
    env["PATH"] = path
    proc = subprocess.run(["/bin/bash", "-c", script], env=env, capture_output=True, text=True)
    kw = etc / "package.accept_keywords" / "hugmesh-host-gpep517"
    return {
        "rc": proc.returncode,
        "err": proc.stderr,
        "emerge": log.read_text().splitlines() if log.exists() else [],
        "portageq": qlog.read_text().splitlines() if qlog.exists() else [],
        "kw": kw.read_text() if kw.exists() else None,
    }


def test_container_with_gpep517_20_installs_23(tmp_path):
    r = _run(tmp_path, installed="20", allowed=True)
    assert r["rc"] == 0, r["err"]
    assert len(r["emerge"]) == 1
    argv = r["emerge"][0].split()
    assert FLOOR in argv and "--oneshot" in argv
    assert r["kw"] is not None and f"{FLOOR} ~amd64" in r["kw"].splitlines()
    # The floor is checked against the BUILD HOST root, and is 23, not 22.
    assert r["portageq"][0] == f"has_version / {FLOOR}"


def test_gpep517_22_is_not_enough(tmp_path):
    """gpep517-22 still has the zero-argument patch (replayed against the failed sysroot)."""
    r = _run(tmp_path, installed="22", allowed=True)
    assert r["rc"] == 0, r["err"]
    assert len(r["emerge"]) == 1, "22 was accepted as good enough; it is not"


def test_already_23_changes_nothing(tmp_path):
    r = _run(tmp_path, installed="23", allowed=True)
    assert r["rc"] == 0, r["err"]
    assert r["emerge"] == [] and r["kw"] is None


def test_real_host_is_never_modified(tmp_path):
    r = _run(tmp_path, installed="20", allowed=False)
    assert r["rc"] != 0
    assert r["emerge"] == [] and r["kw"] is None
    assert f"sudo emerge --oneshot '{FLOOR}'" in r["err"]


def test_not_root_is_never_modified(tmp_path):
    r = _run(tmp_path, installed="20", allowed=True, uid="1000")
    assert r["rc"] != 0
    assert r["emerge"] == [] and r["kw"] is None
    assert "older than 23" in r["err"]


def test_failed_emerge_fails_the_build(tmp_path):
    r = _run(tmp_path, installed="20", allowed=True, emerge_rc=1, emerge_installs=False)
    assert r["rc"] != 0
    assert "Wheel build failed" in r["err"]


def test_emerge_that_leaves_old_version_fails_the_build(tmp_path):
    """A 'successful' emerge that did not actually move the version must not pass."""
    r = _run(tmp_path, installed="20", allowed=True, emerge_installs=False)
    assert r["rc"] != 0
    assert "still older than 23" in r["err"]


def test_missing_portageq_fails_closed(tmp_path):
    r = _run(tmp_path, installed="20", allowed=True, have_portageq=False)
    assert r["rc"] != 0
    assert r["emerge"] == []
    assert "portageq not found" in r["err"]
