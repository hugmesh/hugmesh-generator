"""Local mesh-node runner — start/stop a dockerized Snapdragon mesh node on the host
OS (Linux or Windows via Docker Desktop), controlled from the Studio's system tray.

Reuses the compose templates the image already ships (specs/usr/share/snapdragon/stack/
docker-compose.mesh.yml) so a "run a node on my own machine" experience matches what an
installed desktop's --home-seed-code mesh does.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass


def _compose_base() -> list[str]:
    """`docker compose` (v2) if the plugin actually works, else legacy `docker-compose`."""
    if shutil.which("docker"):
        try:
            r = subprocess.run(["docker", "compose", "version"], capture_output=True, timeout=8)
            if r.returncode == 0:
                return ["docker", "compose"]
        except (OSError, subprocess.SubprocessError):
            pass
    if shutil.which("docker-compose"):
        return ["docker-compose"]
    return []


@dataclass
class MeshStatus:
    running: bool
    detail: str = ""


class MeshNode:
    def __init__(self, generator_dir: str, workdir: str | None = None):
        self.generator_dir = os.path.abspath(generator_dir)
        # the mesh compose template inside the generator repo
        self.compose_src = os.path.join(
            self.generator_dir, "specs", "usr", "share", "snapdragon", "stack",
            "docker-compose.mesh.yml")
        self.workdir = workdir or os.path.join(
            os.path.expanduser("~"), ".snapdragon", "mesh-node")
        self.project = "snapdragon-mesh"

    def available(self) -> tuple[bool, str]:
        if not _compose_base():
            return False, "Docker (with compose) is required to run a local mesh node."
        if not os.path.exists(self.compose_src):
            return False, f"mesh compose template missing: {self.compose_src}"
        return True, ""

    def _compose(self, *args: str) -> list[str]:
        return [*_compose_base(), "-p", self.project, "-f",
                os.path.join(self.workdir, "docker-compose.mesh.yml"), *args]

    def _stage(self) -> None:
        os.makedirs(self.workdir, exist_ok=True)
        shutil.copy2(self.compose_src, os.path.join(self.workdir, "docker-compose.mesh.yml"))
        # bring the rest of the stack assets along if present (env, helper scripts)
        stack_dir = os.path.dirname(self.compose_src)
        for extra in ("docker-compose.yml", ".env", "fetch-repos.sh", "snapdragon-stack"):
            src = os.path.join(stack_dir, extra)
            if os.path.exists(src):
                shutil.copy2(src, os.path.join(self.workdir, extra))

    def start(self) -> tuple[bool, str]:
        ok, why = self.available()
        if not ok:
            return False, why
        self._stage()
        try:
            r = subprocess.run(self._compose("up", "-d"), cwd=self.workdir,
                               capture_output=True, text=True, timeout=600)
            return (r.returncode == 0), (r.stderr or r.stdout).strip()
        except (OSError, subprocess.SubprocessError) as e:
            return False, str(e)

    def stop(self) -> tuple[bool, str]:
        try:
            r = subprocess.run(self._compose("down"), cwd=self.workdir,
                               capture_output=True, text=True, timeout=300)
            return (r.returncode == 0), (r.stderr or r.stdout).strip()
        except (OSError, subprocess.SubprocessError) as e:
            return False, str(e)

    def status(self) -> MeshStatus:
        base = _compose_base()
        if not base or not os.path.exists(os.path.join(self.workdir, "docker-compose.mesh.yml")):
            return MeshStatus(running=False, detail="not started")
        try:
            r = subprocess.run(self._compose("ps", "-q"), cwd=self.workdir,
                               capture_output=True, text=True, timeout=30)
            ids = [x for x in r.stdout.splitlines() if x.strip()]
            return MeshStatus(running=bool(ids), detail=f"{len(ids)} container(s)")
        except (OSError, subprocess.SubprocessError) as e:
            return MeshStatus(running=False, detail=str(e))

    def logs(self, tail: int = 200) -> str:
        try:
            r = subprocess.run(self._compose("logs", "--tail", str(tail)),
                               cwd=self.workdir, capture_output=True, text=True, timeout=30)
            return r.stdout
        except (OSError, subprocess.SubprocessError) as e:
            return str(e)
