"""#579 item 3 — the Fleet channel can build Tor into node images.

``FleetConfig.with_tor`` rides the ``WITH_TOR=1`` env knob (never ``extra_flags``: a
pass-through ``--with-tor`` reaches builders that have no such flag), and
``scripts/build-all-roles.sh`` turns it into each builder's REAL channel. The script
half is pinned by RUNNING the real script against STUB builders in a scratch tree
(the stubs print their argv; nothing is built, nothing needs root) — the actual image
build is out of scope here and is a live check.
"""
from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess

import pytest

from hugmesh_studio.core.fleet import FleetConfig, FleetDriver
from hugmesh_studio.core.platform_info import HostInfo

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")


# ── FleetConfig -> env ──────────────────────────────────────────────────────────────
def test_with_tor_is_an_env_knob_never_a_pass_through_flag():
    cfg = FleetConfig(with_tor=True)
    assert cfg.to_env()["WITH_TOR"] == "1"
    assert "--with-tor" not in cfg.to_cli_args()
    assert "WITH_TOR" not in FleetConfig().to_env()        # default: byte-identical


def test_optional_services_rides_the_env_normalised():
    assert FleetConfig(optional_services=" akkoma   tuwunel ").to_env()[
        "OPTIONAL_SERVICES"] == "akkoma tuwunel"
    assert "OPTIONAL_SERVICES" not in FleetConfig().to_env()
    # commas are separators, as both node builders read them — not a rejected token
    assert FleetConfig(optional_services="akkoma,tuwunel").to_env()[
        "OPTIONAL_SERVICES"] == "akkoma tuwunel"


def test_optional_services_tokens_are_allowlisted():
    from hugmesh_studio.core.config import IdentityValidationError
    with pytest.raises(IdentityValidationError):
        FleetConfig(optional_services="akkoma; rm -rf /").validate()


def test_driver_carries_with_tor_on_both_backends():
    drv = FleetDriver(GENERATOR_DIR, HOST)
    native = drv.command(FleetConfig(with_tor=True), backend="native")
    assert "WITH_TOR=1" in native and native.index("WITH_TOR=1") < native.index("bash")
    docker = drv.command(FleetConfig(with_tor=True), backend="docker")
    assert "WITH_TOR=1" in docker and docker[docker.index("WITH_TOR=1") - 1] == "-e"


def test_from_dict_round_trips_the_new_fields():
    cfg = FleetConfig(with_tor=True, optional_services="akkoma tor")
    assert FleetConfig.from_dict(cfg.to_dict()) == cfg


# ── build-all-roles.sh against stub builders ─────────────────────────────────────────
_BUILDERS = ("build-rpi5-stage4.sh", "build-x86-host-stage4.sh", "build-frite-stage4.sh",
             "build-jetson-stage4.sh", "build-orangepi5-stage4.sh",
             "build-orangepi-zero2-stage4.sh", "build-orangepi-zero2w-stage4.sh",
             "build-orangepi-zero3-stage4.sh", "build-orangepi3-lts-stage4.sh",
             "build-orangepi4-lts-stage4.sh")
_DEFAULT_RE = re.compile(r'^OPTIONAL_SERVICES="\$\{OPTIONAL_SERVICES:-(.*)\}"$', re.M)


def _real_rpi5_default() -> str:
    with open(os.path.join(GENERATOR_DIR, "build-rpi5-stage4.sh"), encoding="utf-8") as fh:
        m = _DEFAULT_RE.search(fh.read())
    assert m, "the rpi5 builder no longer declares its OPTIONAL_SERVICES default"
    return m.group(1)


@pytest.fixture
def tree(tmp_path):
    """A scratch repo: the REAL script + roles lib, stub builders that print argv."""
    root = tmp_path / "repo"
    (root / "scripts").mkdir(parents=True)
    for name in ("build-all-roles.sh", "_roles-lib.sh"):
        shutil.copy2(os.path.join(GENERATOR_DIR, "scripts", name), root / "scripts" / name)
    for b in _BUILDERS:
        stub = root / b
        # the rpi5 stub carries the REAL default line: the script must READ it there
        default = (f'OPTIONAL_SERVICES="${{OPTIONAL_SERVICES:-{_real_rpi5_default()}}}"\n'
                   if b == "build-rpi5-stage4.sh" else "")
        stub.write_text("#!/usr/bin/env bash\n" + default
                        + f'printf "__ARGV__ %s\\n" "{b}"\n'
                        + 'for a in "$@"; do printf "  [%s]\\n" "$a"; done\n'
                        + 'printf "__END__\\n"\n')
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    return root


def _run(tree, env_extra, *args, cwd=None):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("X86_", "RPI_", "FRITE", "JETSON", "ORANGEPI", "SKIP_",
                                "PENTEST", "WITH_TOR", "OPTIONAL_SERVICES"))}
    env.update({"SKIP_KEYS": "1", **env_extra})
    return subprocess.run(
        ["bash", str(tree / "scripts" / "build-all-roles.sh"), "-w", str(tree / "out"),
         *args], env=env, cwd=str(cwd or tree), capture_output=True, text=True,
        timeout=60)


def _invocations(out: str) -> list[tuple[str, list[str]]]:
    calls, cur, name = [], None, ""
    for line in out.splitlines():
        if line.startswith("__ARGV__ "):
            name, cur = line.split(" ", 1)[1], []
        elif line == "__END__" and cur is not None:
            calls.append((name, cur))
            cur = None
        elif cur is not None and line.startswith("  [") and line.endswith("]"):
            cur.append(line[3:-1])
    return calls


def _by_role(calls, builder):
    out = {}
    for name, argv in calls:
        if name == builder:
            out[argv[argv.index("--role") + 1] if "--role" in argv else name] = argv
    return out


def _mixed_env(**extra):
    return {"X86_ROLES": "backend standalone-thin", "RPI_ROLES": "backend desktop",
            "FRITE": "1", "JETSON": "1", **extra}


def test_with_tor_emits_each_builders_real_channel_on_node_roles_only(tree):
    r = _run(tree, _mixed_env(WITH_TOR="1"))
    assert r.returncode == 0, r.stdout + r.stderr
    calls = _invocations(r.stdout)
    x86 = _by_role(calls, "build-x86-host-stage4.sh")
    rpi = _by_role(calls, "build-rpi5-stage4.sh")
    assert "--with-tor" in x86["backend"]
    assert "--with-tor" not in x86["standalone-thin"]          # client: never
    want = f"{_real_rpi5_default()} tor"
    assert rpi["backend"][rpi["backend"].index("--optional-services") + 1] == want
    assert "--optional-services" not in rpi["desktop"]          # client: never
    assert "--with-tor" not in rpi["backend"]                   # rpi5 has no such flag
    for name, argv in calls:                                    # frite/jetson: nothing
        if name in ("build-frite-stage4.sh", "build-jetson-stage4.sh"):
            assert "--with-tor" not in argv and "--optional-services" not in argv, name
    assert "Tor onion:   ON" in r.stdout


def test_without_with_tor_no_builder_hears_about_tor(tree):
    r = _run(tree, _mixed_env())
    assert r.returncode == 0, r.stdout + r.stderr
    for name, argv in _invocations(r.stdout):
        assert "--with-tor" not in argv and "--optional-services" not in argv, name
    assert "Tor onion:   (off" in r.stdout


def test_with_tor_folds_into_an_operator_optional_services(tree):
    r = _run(tree, {"WITH_TOR": "1", "RPI_ROLES": "backend", "SKIP_X86": "1",
                    "OPTIONAL_SERVICES": "akkoma,owncast"})
    assert r.returncode == 0, r.stdout + r.stderr
    rpi = _by_role(_invocations(r.stdout), "build-rpi5-stage4.sh")["backend"]
    assert rpi[rpi.index("--optional-services") + 1] == "akkoma owncast tor"
    r = _run(tree, {"WITH_TOR": "1", "RPI_ROLES": "backend", "SKIP_X86": "1",
                    "OPTIONAL_SERVICES": "akkoma tor"})
    rpi = _by_role(_invocations(r.stdout), "build-rpi5-stage4.sh")["backend"]
    assert rpi[rpi.index("--optional-services") + 1] == "akkoma tor"   # no duplicate


@pytest.mark.parametrize("env_extra,args,why", [
    ({"OPTIONAL_SERVICES": "all"}, (), "containing 'all'"),
    ({}, ("--optional-services", "akkoma"), "pass-through --optional-services"),
    ({}, ("--all-services",), "pass-through --all-services"),
])
def test_with_tor_refuses_what_it_cannot_honour_exactly(tree, env_extra, args, why):
    r = _run(tree, {"WITH_TOR": "1", "RPI_ROLES": "backend", **env_extra}, *args)
    assert r.returncode == 2, r.stdout + r.stderr
    assert why in r.stderr
    assert "__ARGV__" not in r.stdout                           # refused BEFORE any build


def test_with_tor_refuses_to_override_a_brand_profiles_service_list(tree):
    conf = tree / "brands-acme.conf"
    conf.write_text('BRAND="acme"\nOPTIONAL_SERVICES="akkoma"\n')
    r = _run(tree, {"WITH_TOR": "1", "RPI_ROLES": "backend"}, "--config", str(conf))
    assert r.returncode == 2 and "sets OPTIONAL_SERVICES" in r.stderr
    # ...unless the operator states the list; then tor is added to it
    r = _run(tree, {"WITH_TOR": "1", "RPI_ROLES": "backend", "SKIP_X86": "1",
                    "OPTIONAL_SERVICES": "akkoma"}, "--config", str(conf))
    assert r.returncode == 0, r.stdout + r.stderr
    rpi = _by_role(_invocations(r.stdout), "build-rpi5-stage4.sh")["backend"]
    assert rpi[rpi.index("--optional-services") + 1] == "akkoma tor"


def test_rpi5_refusals_do_not_block_an_x86_only_tor_run(tree):
    conf = tree / "brands-acme.conf"
    conf.write_text('OPTIONAL_SERVICES="akkoma"\n')
    r = _run(tree, {"WITH_TOR": "1", "SKIP_RPI": "1", "X86_ROLES": "backend"},
             "--config", str(conf))
    assert r.returncode == 0, r.stdout + r.stderr
    x86 = _by_role(_invocations(r.stdout), "build-x86-host-stage4.sh")["backend"]
    assert "--with-tor" in x86
