"""Local dev-stack runner — start/stop the generator's OWN docker-compose stack
(`make stack-up`, tests/stack/compose.local.yaml), controlled from the Studio's
system tray.

Unlike MeshNode (a single mesh-node container, staged into a per-user workdir),
this drives the Makefile targets directly rather than re-implementing the
compose/env wiring in Python — stack-up's behavior (repo cloning, the SOCIAL
mastodon-env prep, ENV=test|prod Casdoor issuer selection) lives in the
Makefile and would drift if duplicated here. Status/logs go straight through
docker compose (read-only, cheap) since they don't need any of that setup.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass

_COMPOSE_FILE = os.path.join("tests", "stack", "compose.local.yaml")


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
class StackStatus:
    running: bool
    detail: str = ""


class LocalStackNode:
    def __init__(self, generator_dir: str, env: str = "test", social: bool = False,
                 public_host_port: int = 8088, domain: str = ""):
        self.generator_dir = os.path.abspath(generator_dir)
        self.compose_file = os.path.join(self.generator_dir, _COMPOSE_FILE)
        self.env = env
        self.social = social
        self.public_host_port = public_host_port
        # Public apex threaded into `make stack-up` as DOMAIN. In prod the Makefile
        # derives CASDOOR_ISSUER = https://id.$(DOMAIN); left empty (the default, and
        # for ENV=test) the Makefile keeps its own default and the issuer stays
        # localhost. Threading it here is what keeps a from-scratch bootstrap's
        # running issuer aligned with the domain its secrets were minted for.
        self.domain = domain

    @property
    def web_url(self) -> str:
        return f"http://localhost:{self.public_host_port}"

    def available(self) -> tuple[bool, str]:
        if not shutil.which("make"):
            return False, "make is required to run the local stack (make stack-up)."
        if not _compose_base():
            return False, "Docker (with compose) is required to run the local stack."
        if not os.path.exists(self.compose_file):
            return False, f"stack compose file missing: {self.compose_file}"
        return True, ""

    def _make(self, target: str, timeout: int,
              extra_env: dict[str, str] | None = None) -> tuple[bool, str]:
        env = os.environ.copy()
        env["ENV"] = self.env
        env["SOCIAL"] = "1" if self.social else ""
        env["PUBLIC_HOST_PORT"] = str(self.public_host_port)
        # Only export DOMAIN when set, so existing callers (and ENV=test) keep the
        # Makefile's own default. In prod this pins the Casdoor issuer to the same
        # apex the minted secrets use (Makefile: CASDOOR_ISSUER = https://id.$(DOMAIN)).
        if self.domain:
            env["DOMAIN"] = self.domain
        # extra_env carries per-target overrides (e.g. the bridged
        # E2E_SUPERADMIN_PASSWORD for `stack-seed`). Values ride the subprocess env
        # only — never argv — mirroring the golive/token-file secret discipline.
        if extra_env:
            env.update(extra_env)
        try:
            r = subprocess.run(["make", target], cwd=self.generator_dir, env=env,
                               capture_output=True, text=True, timeout=timeout)
            return (r.returncode == 0), (r.stderr or r.stdout).strip()
        except (OSError, subprocess.SubprocessError) as e:
            return False, str(e)

    def start(self) -> tuple[bool, str]:
        ok, why = self.available()
        if not ok:
            return False, why
        # stack-clone + build + up -d — can take a while on first run (image pulls/builds).
        return self._make("stack-up", timeout=1800)

    def seed(self, extra_env: dict[str, str] | None = None,
             timeout: int = 600) -> tuple[bool, str]:
        """`make stack-seed` — provision Casdoor identity (org+roles+personas) into
        the already-running stack. ``extra_env`` bridges secret values (the minted
        E2E_SUPERADMIN_PASSWORD) through the subprocess env, never argv."""
        return self._make("stack-seed", timeout=timeout, extra_env=extra_env)

    def stop(self) -> tuple[bool, str]:
        return self._make("stack-down", timeout=300)

    def status(self) -> StackStatus:
        base = _compose_base()
        if not base or not os.path.exists(self.compose_file):
            return StackStatus(running=False, detail="not started")
        try:
            r = subprocess.run([*base, "-f", self.compose_file, "ps", "-q"],
                               cwd=self.generator_dir, capture_output=True, text=True, timeout=30)
            ids = [x for x in r.stdout.splitlines() if x.strip()]
            return StackStatus(running=bool(ids), detail=f"{len(ids)} container(s)")
        except (OSError, subprocess.SubprocessError) as e:
            return StackStatus(running=False, detail=str(e))

    def logs(self, tail: int = 200) -> str:
        base = _compose_base()
        if not base:
            return "docker compose not available"
        try:
            r = subprocess.run([*base, "-f", self.compose_file, "logs", "--tail", str(tail)],
                               cwd=self.generator_dir, capture_output=True, text=True, timeout=30)
            return r.stdout
        except (OSError, subprocess.SubprocessError) as e:
            return str(e)
