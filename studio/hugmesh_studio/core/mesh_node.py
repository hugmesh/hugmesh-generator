"""Local mesh-node runner — start/stop a dockerized HugMesh mesh node on the host
OS (Linux or Windows via Docker Desktop), controlled from the Studio's system tray.

Reuses the compose templates the image already ships (specs/usr/share/hugmesh/stack/
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
            self.generator_dir, "specs", "usr", "share", "hugmesh", "stack",
            "docker-compose.mesh.yml")
        self.workdir = workdir or os.path.join(
            os.path.expanduser("~"), ".hugmesh", "mesh-node")
        self.project = "hugmesh-mesh"

    def available(self) -> tuple[bool, str]:
        if not _compose_base():
            return False, "Docker (with compose) is required to run a local mesh node."
        if not os.path.exists(self.compose_src):
            return False, f"mesh compose template missing: {self.compose_src}"
        return True, ""

    def _compose(self, *args: str) -> list[str]:
        # `--profile mesh` is REQUIRED: the template's only service (tailscale) is gated
        # behind profiles:["mesh"] (matching the shipped `hugmesh-stack mesh-up`, which
        # runs `--profile infra --profile mesh`). Without it `up`/`ps` select ZERO services,
        # so start() would report "Started." while launching nothing.
        return [*_compose_base(), "--profile", "mesh", "-p", self.project, "-f",
                os.path.join(self.workdir, "docker-compose.mesh.yml"), *args]

    def _authkey(self) -> str:
        """The EFFECTIVE tailnet/headscale auth key — the one thing start() must have and
        the value staged into the subprocess env. The base tray path reads it from the
        environment (`TS_AUTHKEY`); :class:`~.local_mesh.LocalMeshNode` overrides this to
        also consult the operator-provided ``cfg.auth_key`` typed into the launcher dialog,
        so the documented "type the key into the field" UX actually reaches `compose up`
        instead of dead-ending on an env-only gate."""
        return os.environ.get("TS_AUTHKEY", "")

    def _env(self) -> dict:
        """Subprocess env with TS_AUTHKEY guaranteed present. The compose template requires
        `${TS_AUTHKEY:?...}` even to PARSE, so stop()/status()/logs() would die on the
        required-var when no real key is set — inject a harmless placeholder for those
        read/teardown paths. When an effective key exists (env, or a subclass's cfg key) it
        wins, so `up` joins with the REAL key rather than the shadowing placeholder."""
        env = os.environ.copy()
        env["TS_AUTHKEY"] = self._authkey() or "unused-teardown-placeholder"
        return env

    def _stage(self) -> None:
        os.makedirs(self.workdir, exist_ok=True)
        shutil.copy2(self.compose_src, os.path.join(self.workdir, "docker-compose.mesh.yml"))
        # bring the rest of the stack assets along if present (env, helper scripts)
        stack_dir = os.path.dirname(self.compose_src)
        for extra in ("docker-compose.yml", ".env", "fetch-repos.sh", "hugmesh-stack"):
            src = os.path.join(stack_dir, extra)
            if os.path.exists(src):
                shutil.copy2(src, os.path.join(self.workdir, extra))

    def start(self) -> tuple[bool, str]:
        ok, why = self.available()
        if not ok:
            return False, why
        # The template requires a real tailnet/headscale auth key (`${TS_AUTHKEY:?...}`).
        # Surface that as a CLEAR actionable message instead of a raw compose interpolation
        # error, and don't stage/launch anything without it. Consult the EFFECTIVE key
        # (env for the tray; cfg.auth_key for the local-mesh launcher) via the _authkey()
        # hook — a subclass with a field-provided key must reach `up` here, not dead-end.
        if not self._authkey():
            return False, ("Set TS_AUTHKEY (a tailnet/headscale auth key) in the "
                           "environment before starting a mesh node.")
        self._stage()
        try:
            r = subprocess.run(self._compose("up", "-d"), cwd=self.workdir, env=self._env(),
                               capture_output=True, text=True, timeout=600)
            return (r.returncode == 0), (r.stderr or r.stdout).strip()
        except (OSError, subprocess.SubprocessError) as e:
            return False, str(e)

    def stop(self) -> tuple[bool, str]:
        try:
            r = subprocess.run(self._compose("down"), cwd=self.workdir, env=self._env(),
                               capture_output=True, text=True, timeout=300)
            return (r.returncode == 0), (r.stderr or r.stdout).strip()
        except (OSError, subprocess.SubprocessError) as e:
            return False, str(e)

    def status(self) -> MeshStatus:
        base = _compose_base()
        if not base or not os.path.exists(os.path.join(self.workdir, "docker-compose.mesh.yml")):
            return MeshStatus(running=False, detail="not started")
        try:
            r = subprocess.run(self._compose("ps", "-q"), cwd=self.workdir, env=self._env(),
                               capture_output=True, text=True, timeout=30)
            ids = [x for x in r.stdout.splitlines() if x.strip()]
            return MeshStatus(running=bool(ids), detail=f"{len(ids)} container(s)")
        except (OSError, subprocess.SubprocessError) as e:
            return MeshStatus(running=False, detail=str(e))

    def logs(self, tail: int = 200) -> str:
        try:
            r = subprocess.run(self._compose("logs", "--tail", str(tail)),
                               cwd=self.workdir, env=self._env(),
                               capture_output=True, text=True, timeout=30)
            return r.stdout
        except (OSError, subprocess.SubprocessError) as e:
            return str(e)
