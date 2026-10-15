"""First-run bootstrap (issue #49): symlinks + properties + doctor, idempotent.

Before this module the "first run" machinery was partial and scattered:
``scripts/studio-launch.sh`` detected a bare box and offered a venv,
``clients/docker-mesh-node/install.sh`` wrote ``~/.local/bin`` entries for a
DIFFERENT product surface, and every script re-derived the generator dir, the
python to use and the builder-image name on every invocation. This module is
the single place the FIRST run of the Studio or any CLI entry lands to:

* **symlinks** — per-user ``~/.local/bin`` entries (XDG user-executables dir,
  NO sudo, ever) for the launcher CLI surfaces. Foreign files are NEVER
  clobbered, and the name ``hugmesh-mesh-node`` is RESERVED for the end-user
  joiner appliance (clients/docker-mesh-node/install.sh) — see the
  name-collision note in scripts/hugmesh-mesh-node.
* **properties** — a versioned ``~/.hugmesh/studio/properties.json`` (the
  existing Studio state dir; ``$HUGMESH_STUDIO_STATE_DIR`` overrides it, same
  as build_sessions/crashlog/instance) recording the resolved generator dir,
  python, venv and builder-image name so scripts can stop re-deriving them.
* **doctor** — a fast self-test pass (venv importable, git present, builder
  image present, KVM available). Every failure is an ADVISORY print, never a
  blocker: :func:`ensure` cannot make a launch fail.

A version stamp (``first-run.stamp``) makes reruns no-ops — the shell half
(scripts/_first-run-lib.sh) checks it with one ``cat`` and never even starts
python when it is current. ``--redo-first-run`` forces a rerun.

Qt-free, stdlib-only, runnable directly::

    PYTHONPATH=studio python3 -m hugmesh_studio.core.first_run [--repo DIR]
        [--redo-first-run] [--doctor] [--print-properties]

ALL human/advisory output goes to **stderr**: the launcher's headless
automation channel parses the python module's stdout, so nothing here may
pollute it.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time

from .instance import state_dir

__all__ = [
    "FIRST_RUN_VERSION", "bin_dir", "builder_image_name", "doctor", "ensure",
    "is_current", "link_map", "load_properties", "properties_path",
    "resolve_properties", "stamp_path",
]

# Bump when the bootstrap gains a step existing installs must re-run.
FIRST_RUN_VERSION = 1

_PROPERTIES = "properties.json"
_STAMP = "first-run.stamp"

# The CLI surfaces linked onto PATH: link name -> repo-relative target.
# `hugmesh-mesh-node` is deliberately ABSENT (reserved for the shipped joiner
# appliance's installer — a different product surface with the same name).
_LINKS = {
    "hugmesh-studio": os.path.join("scripts", "studio-launch.sh"),
    "hugmesh-build-menu": os.path.join("scripts", "build-menu.sh"),
}
_RESERVED_LINK_NAMES = frozenset({"hugmesh-mesh-node"})

_SUBPROCESS_TIMEOUT = 15  # seconds — the doctor is "fast" by contract


def _say(msg: str) -> None:
    print(msg, file=sys.stderr)


def bin_dir() -> str:
    """The per-user executables dir (XDG: ``~/.local/bin``); no sudo, ever.
    ``$HUGMESH_BIN_DIR`` overrides it — the test override point, same shape as
    ``$HUGMESH_STUDIO_STATE_DIR``."""
    return os.environ.get("HUGMESH_BIN_DIR") or os.path.join(
        os.path.expanduser("~"), ".local", "bin")


def properties_path() -> str:
    return os.path.join(state_dir(), _PROPERTIES)


def stamp_path() -> str:
    return os.path.join(state_dir(), _STAMP)


def is_current() -> bool:
    """True iff the stamp records exactly FIRST_RUN_VERSION (the no-op test)."""
    try:
        with open(stamp_path(), "r", encoding="utf-8") as fh:
            return fh.read().strip() == str(FIRST_RUN_VERSION)
    except OSError:
        return False


def load_properties() -> dict | None:
    """The recorded properties, or None when absent/unreadable (never raises)."""
    try:
        with open(properties_path(), "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def builder_image_name() -> str:
    """The Docker builder-image tag — ``$IMAGE`` (the Makefile/build-menu
    override) else the default, matching scripts/build-menu.sh."""
    return os.environ.get("IMAGE") or "hugmesh-builder"


def _repo_dir_default() -> str:
    # studio/hugmesh_studio/core/first_run.py -> the checkout root.
    here = os.path.abspath(__file__)
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(here))))


def _venv_python(repo_dir: str) -> str | None:
    """The launcher's project-local venv python, when it exists (the same
    studio/.venv-studio path scripts/studio-launch.sh and the .bat use)."""
    py = os.path.join(repo_dir, "studio", ".venv-studio", "bin", "python")
    return py if os.access(py, os.X_OK) else None


def link_map(repo_dir: str) -> dict[str, str]:
    """link name -> absolute target for this checkout."""
    return {name: os.path.join(repo_dir, rel) for name, rel in _LINKS.items()}


def resolve_properties(repo_dir: str) -> dict:
    """Resolve (do not write) the properties record for this checkout."""
    repo_dir = os.path.abspath(repo_dir)
    venv = _venv_python(repo_dir)
    return {
        "version": FIRST_RUN_VERSION,
        "first_run_version": FIRST_RUN_VERSION,
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "generator_dir": repo_dir,
        "studio_dir": os.path.join(repo_dir, "studio"),
        "python": venv or shutil.which("python3") or sys.executable,
        "venv": venv,
        "builder_image": builder_image_name(),
        "bin_dir": bin_dir(),
        "links": link_map(repo_dir),
    }


def _write_atomic(path: str, text: str) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def _is_hugmesh_link_target(existing_target: str, rel: str) -> bool:
    """Does an existing symlink point at (any checkout's) copy of ``rel``?
    Then retargeting to THIS checkout is safe and keeps the link fresh after
    a repo move; anything else is foreign and must never be touched."""
    norm = os.path.normpath(existing_target)
    return norm.endswith(os.sep + rel) or norm == rel


def _ensure_link(name: str, target: str, rel: str) -> str:
    """Create/refresh one symlink; returns a status token for the FIRSTRUN
    line. NEVER clobbers a foreign file, NEVER needs sudo."""
    if name in _RESERVED_LINK_NAMES:
        return "reserved"
    if not os.access(target, os.X_OK):
        return "target-missing"
    path = os.path.join(bin_dir(), name)
    if os.path.islink(path):
        existing = os.readlink(path)
        if os.path.realpath(path) == os.path.realpath(target):
            return "ok"
        if _is_hugmesh_link_target(existing, rel):
            os.remove(path)
            os.symlink(target, path)
            return "retargeted"
        return "skipped-foreign-link"
    if os.path.lexists(path):
        return "skipped-foreign-file"
    os.symlink(target, path)
    return "created"


def _path_has(directory: str) -> bool:
    parts = os.environ.get("PATH", "").split(os.pathsep)
    directory = os.path.normpath(directory)
    return any(os.path.normpath(p) == directory for p in parts if p)


def install_links(repo_dir: str, echo=_say) -> dict[str, str]:
    """(a) the symlinks. Returns {name: status}."""
    statuses: dict[str, str] = {}
    try:
        os.makedirs(bin_dir(), exist_ok=True)
    except OSError as exc:
        echo(f"FIRSTRUN links=skipped reason=bin-dir-unwritable ({exc})")
        return statuses
    for name, rel in _LINKS.items():
        target = os.path.join(os.path.abspath(repo_dir), rel)
        try:
            status = _ensure_link(name, target, rel)
        except OSError as exc:
            status = f"error:{exc.__class__.__name__}"
        statuses[name] = status
        echo(f"FIRSTRUN link={name} status={status} target={target}")
        if status.startswith("skipped-foreign"):
            echo(f"  note: {os.path.join(bin_dir(), name)} exists and is not "
                 "ours — left untouched.")
    if statuses and not _path_has(bin_dir()):
        echo(f"  note: {bin_dir()} is not on your PATH — add it to use the "
             "hugmesh-* commands by name.")
    return statuses


# ── the doctor: fast, advisory-only self-tests ─────────────────────────────────


def _check_git(echo) -> None:
    git = shutil.which("git")
    if git:
        echo(f"DOCTOR git=found path={git}")
    else:
        echo("DOCTOR git=missing")
        echo("  note: install git (build scripts and --dev features need it).")


def _check_venv(repo_dir: str, echo) -> None:
    venv = _venv_python(repo_dir)
    if venv is None:
        echo("DOCTOR venv=absent")
        echo("  note: optional — scripts/studio-launch.sh offers a "
             "project-local venv when the system python lacks PySide6.")
        return
    try:
        rc = subprocess.run(
            [venv, "-c", "import hugmesh_studio"],
            env={**os.environ,
                 "PYTHONPATH": os.path.join(repo_dir, "studio")},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=_SUBPROCESS_TIMEOUT, check=False).returncode
    except (OSError, subprocess.SubprocessError):
        rc = -1
    if rc == 0:
        echo(f"DOCTOR venv=ok python={venv}")
    else:
        echo(f"DOCTOR venv=broken python={venv}")
        echo("  note: the venv exists but cannot import hugmesh_studio — "
             "recreate it (rm -rf studio/.venv-studio; re-run the launcher).")


def _check_builder_image(echo) -> None:
    image = builder_image_name()
    docker = shutil.which("docker")
    if docker is None:
        echo("DOCTOR builder_image=unknown docker=missing")
        echo("  note: no docker CLI — only NATIVE=1 builds are possible on "
             "this host.")
        return
    try:
        rc = subprocess.run(
            [docker, "image", "inspect", image],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=_SUBPROCESS_TIMEOUT, check=False).returncode
    except (OSError, subprocess.SubprocessError):
        echo(f"DOCTOR builder_image=unknown name={image}")
        echo("  note: docker did not answer (daemon down?) — could not check "
             "for the builder image.")
        return
    if rc == 0:
        echo(f"DOCTOR builder_image=present name={image}")
    else:
        echo(f"DOCTOR builder_image=missing name={image}")
        echo("  note: build it once with `make docker-image` (LONG first run).")


def _check_kvm(echo, dev: str = "/dev/kvm") -> None:
    if os.access(dev, os.R_OK | os.W_OK):
        echo(f"DOCTOR kvm=available dev={dev}")
    else:
        echo(f"DOCTOR kvm=unavailable dev={dev}")
        echo("  note: QEMU boot tests fall back to slow TCG (degraded) mode; "
             "add your user to the kvm group for full speed.")


def doctor(repo_dir: str, echo=_say) -> None:
    """(c) the self-tests. Advisory by contract: prints DOCTOR lines and
    notes, raises nothing, blocks nothing."""
    for check in (lambda e: _check_git(e),
                  lambda e: _check_venv(repo_dir, e),
                  lambda e: _check_builder_image(e),
                  lambda e: _check_kvm(e)):
        try:
            check(echo)
        except Exception as exc:  # noqa: BLE001 — advisory means ADVISORY
            echo(f"DOCTOR check=error detail={exc.__class__.__name__}")


# ── the entry point ─────────────────────────────────────────────────────────────


def ensure(repo_dir: str | None = None, force: bool = False, echo=_say) -> dict:
    """The idempotent first-run bootstrap. No-op when the stamp is current
    (unless ``force``); otherwise writes properties, installs the symlinks,
    runs the doctor, and stamps LAST — so an interrupted bootstrap simply
    reruns next time. Returns the properties in effect."""
    repo_dir = os.path.abspath(repo_dir or _repo_dir_default())
    if is_current() and not force:
        return load_properties() or resolve_properties(repo_dir)

    echo(f"FIRSTRUN bootstrap=start version={FIRST_RUN_VERSION} "
         f"repo={repo_dir}")
    os.makedirs(state_dir(), exist_ok=True)

    props = resolve_properties(repo_dir)
    _write_atomic(properties_path(),
                  json.dumps(props, indent=2, sort_keys=True) + "\n")
    echo(f"FIRSTRUN properties=written path={properties_path()}")

    install_links(repo_dir, echo)
    doctor(repo_dir, echo)

    _write_atomic(stamp_path(), f"{FIRST_RUN_VERSION}\n")
    echo(f"FIRSTRUN bootstrap=done stamp={stamp_path()}")
    return props


def main(argv: list[str] | None = None) -> int:
    import argparse
    parser = argparse.ArgumentParser(
        prog="python3 -m hugmesh_studio.core.first_run",
        description="HugMesh first-run bootstrap: symlinks + properties + "
                    "doctor (idempotent; advisory-only).")
    parser.add_argument("--repo", default=None,
                        help="generator checkout (default: this module's)")
    parser.add_argument("--redo-first-run", action="store_true",
                        help="force the bootstrap even when the stamp is "
                             "current")
    parser.add_argument("--doctor", action="store_true",
                        help="run ONLY the advisory self-tests (writes "
                             "nothing)")
    parser.add_argument("--print-properties", action="store_true",
                        help="print the properties JSON (recorded if stamped, "
                             "else resolved) to stdout and exit")
    args = parser.parse_args(argv)
    repo = os.path.abspath(args.repo or _repo_dir_default())

    if args.print_properties:
        props = (load_properties() if is_current() else None) \
            or resolve_properties(repo)
        print(json.dumps(props, indent=2, sort_keys=True))
        return 0
    if args.doctor:
        doctor(repo)
        return 0
    ensure(repo, force=args.redo_first_run)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
