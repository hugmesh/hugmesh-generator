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
import urllib.request
from dataclasses import dataclass

_COMPOSE_FILE = os.path.join("tests", "stack", "compose.local.yaml")

# ── cold-build preflight wiring (mirrors the Makefile's m2 knobs) ──────────────
# `make stack-m2-bootstrap` (tests/stack/m2-bootstrap.sh) builds the org-private
# maven artifacts from source, serves them from a registry container, and writes
# this (gitignored) env file; the Makefile auto-includes the m2 compose override
# whenever the file exists.
_M2_ENV_FILE = os.path.join("tests", "stack", ".m2-registry.env")
M2_REGISTRY_CONTAINER = "snapdragon-m2-registry"
M2_BOOTSTRAP_HINT = "run `make stack-m2-bootstrap` first"
# The registry-readiness probe fetches a REAL artifact through the exact URL
# shape the services' settings.xml (and the compose build args) will use — the
# same artifact m2-bootstrap.sh self-checks after standing the registry up.
_M2_CHECK_ARTIFACT = ("systems/snapdragon/snapdragon-parent/2.7.0/"
                      "snapdragon-parent-2.7.0.pom")
_M2_PROBE_TIMEOUT_S = 3.0
# compose.local.yaml sets `name: snapdragon-local`, so built images are named
# <project>-<service>. These four services resolve PRIVATE maven artifacts at
# image-build time — a cold build of any of them needs the m2 registry.
_COMPOSE_PROJECT = "snapdragon-local"
PRIVATE_ARTIFACT_SERVICES = (
    "snapdragon-admin-bff-api",
    "snapdragon-user-bff-api",
    "snapdragon-mod-bff-api",
    "snapdragon-federation-api",
)
# A full cold build (17 service images incl. four fat Spring builds) comfortably
# exceeds 10 GiB of layers + build cache; demand sane headroom up front instead
# of failing 40 minutes into `docker compose build`.
PREFLIGHT_MIN_FREE_GIB = 20


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
                 public_host_port: int = 8088, domain: str = "",
                 source_mode: str = "clone", source_dir: str = ""):
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
        # WHERE compose finds the buildable repo source. "clone" (the default) sets
        # NOTHING: STACK_SRC stays unset, the Makefile's `STACK_SRC ?= .stack-src`
        # resolves as it always has and `stack-clone` populates it — byte-identical
        # env to before this field existed. "existing" points STACK_SRC at a tree the
        # operator already has AND sets STACK_NO_CLONE=1, because `stack-up` depends
        # unconditionally on `stack-clone`, whose update path `git reset --hard`s any
        # checkout already present under STACK_SRC (clone-all-repos.sh:88-99) — run
        # against the operator's own working tree that silently DESTROYS uncommitted
        # work. The skip gate is a safety interlock, not a convenience.
        self.source_mode = source_mode
        self.source_dir = source_dir

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

    # ---- cold-build preflight ----------------------------------------------------
    # Each probe is a tiny method so tests can mock it both ways; every docker call
    # runs in self._build_env() — the SAME env `make stack-up` will use — and NOTHING
    # here fabricates readiness: a probe that cannot run reports a problem.

    def _probe(self, cmd: list[str], timeout: int = 15) -> tuple[int, str]:
        try:
            r = subprocess.run(cmd, env=self._build_env(), capture_output=True,
                               text=True, timeout=timeout)
            return r.returncode, (r.stdout or r.stderr).strip()
        except (OSError, subprocess.SubprocessError) as e:
            return 1, str(e)

    def _docker_ready(self) -> tuple[bool, str]:
        rc, out = self._probe(["docker", "info", "--format", "{{.ServerVersion}}"])
        return (rc == 0 and bool(out)), out

    def _buildx_visible(self) -> bool:
        """True when the buildx CLI plugin resolves in the env compose will run
        with. It is installed PER-USER (~/.docker/cli-plugins), so a root/systemd/
        other-HOME invocation can silently fall back to the legacy builder — which
        cannot parse the services' `# syntax=`/secret-mount Dockerfiles."""
        rc, _ = self._probe(["docker", "buildx", "version"])
        return rc == 0

    def _docker_root_free_gib(self) -> float:
        """Free GiB under the docker data-root (where every layer/build lands);
        falls back to the generator checkout's filesystem when the data-root is
        not visible (e.g. a remote daemon)."""
        rc, root = self._probe(["docker", "info", "--format", "{{.DockerRootDir}}"])
        path = root if rc == 0 and root and os.path.exists(root) else self.generator_dir
        try:
            return shutil.disk_usage(path).free / (1024 ** 3)
        except OSError:
            return 0.0

    def _image_present(self, image: str) -> bool:
        rc, out = self._probe(["docker", "images", "-q", image])
        return rc == 0 and bool(out.strip())

    @staticmethod
    def _m2_env_values(env_file: str) -> dict[str, str]:
        """KEY=VALUE pairs from the bootstrap's env file (comments/blanks skipped)."""
        vals: dict[str, str] = {}
        try:
            with open(env_file, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    key, _, value = line.partition("=")
                    vals[key.strip()] = value.strip()
        except OSError:
            pass
        return vals

    def _url_ok(self, url: str, timeout: float = _M2_PROBE_TIMEOUT_S) -> tuple[bool, str]:
        """GET ``url``; (True, "") only on a 2xx. Default-fail: any error —
        unreachable IP, connection refused, 404, timeout, garbage URL — reports
        why instead of raising."""
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:  # noqa: S310 - fixed path over the env-file URL
                status = getattr(r, "status", 0)
                if 200 <= status < 300:
                    return True, ""
                return False, f"HTTP {status}"
        except (OSError, ValueError) as e:  # URLError/HTTPError/timeout are OSError
            return False, str(e)

    def m2_registry_ready(self) -> tuple[bool, str]:
        """Are the private-maven cold-build prerequisites in place — really?
        `make stack-m2-bootstrap` writes the (gitignored) env file and starts the
        registry container, but neither existing-file nor container-running checks
        are honest on their own: a docker/host restart can hand the restarted
        container a DIFFERENT bridge IP while the env file stays frozen, and the
        build would then die deep inside `docker compose build` on maven
        connection-refused noise. So probe a known artifact THROUGH the exact URL
        the build args will use — one GET subsumes env-file presence, container
        liveness, IP freshness, and a non-emptied m2 cache."""
        env_file = os.path.join(self.generator_dir, _M2_ENV_FILE)
        if not os.path.exists(env_file):
            return False, f"{_M2_ENV_FILE} missing"
        vals = self._m2_env_values(env_file)
        base = vals.get("CI_API_V4_URL", "").rstrip("/")
        if not base:
            return False, f"{_M2_ENV_FILE} has no CI_API_V4_URL"
        group = vals.get("GITLAB_GROUP_ID", "1")
        url = f"{base}/groups/{group}/-/packages/maven/{_M2_CHECK_ARTIFACT}"
        ok, why = self._url_ok(url)
        if not ok:
            return False, (f"registry {M2_REGISTRY_CONTAINER} did not serve the "
                           f"check artifact via {base} ({why}); a docker restart "
                           f"can change its bridge IP while {_M2_ENV_FILE} stays "
                           f"stale")
        return True, ""

    def preflight(self) -> list[str]:
        """Fail-fast COLD-BUILD readiness check for `make stack-up`. Returns SHORT,
        actionable problem lines (empty list = ready) instead of letting the
        operator find out via the truncated tail of a 30-minute compose build.
        Covers: docker daemon, BuildKit/buildx visibility IN THE ENV the build
        will use, disk headroom, and — when the private-artifact services' images
        are absent and must cold-build — the m2 registry prerequisites."""
        ok, why = self.available()
        if not ok:
            return [why]
        ok, why = self._docker_ready()
        if not ok:
            return [f"docker daemon not reachable: {why or 'docker info failed'} — "
                    f"start docker, then retry."]
        problems: list[str] = []
        env = self._build_env()
        if env.get("DOCKER_BUILDKIT") == "0":
            problems.append("DOCKER_BUILDKIT=0 is set in this environment — the stack "
                            "Dockerfiles need BuildKit (secret mounts); unset it.")
        if not self._buildx_visible():
            problems.append("docker buildx is not visible in THIS environment — the "
                            "plugin is per-user (~/.docker/cli-plugins), so run as the "
                            "user that installed it (not via sudo/systemd) or install "
                            "buildx system-wide; without it the legacy builder cannot "
                            "parse the services' BuildKit Dockerfiles.")
        free = self._docker_root_free_gib()
        if free < PREFLIGHT_MIN_FREE_GIB:
            problems.append(f"only {free:.0f} GiB free under the docker data-root — a "
                            f"cold stack build needs ~{PREFLIGHT_MIN_FREE_GIB} GiB; free "
                            f"space (e.g. `docker system prune`) and retry.")
        missing = [s for s in PRIVATE_ARTIFACT_SERVICES
                   if not self._image_present(f"{_COMPOSE_PROJECT}-{s}")]
        if missing:
            ready, why = self.m2_registry_ready()
            if not ready:
                problems.append(
                    f"cold build required ({len(missing)} private-maven service "
                    f"image(s) missing: {', '.join(missing)}) but the local maven "
                    f"registry is not up ({why}) — {M2_BOOTSTRAP_HINT}; it builds the "
                    f"org-private artifacts from source and serves them to the build.")
        return problems

    def _build_env(self, extra_env: dict[str, str] | None = None) -> dict[str, str]:
        """The EXACT env every `make stack-*` subprocess runs with. The preflight
        checks run against this same dict — a BuildKit/buildx probe in any other
        env (sudo, systemd, a different HOME) would fabricate readiness, because
        the buildx CLI plugin is per-user (~/.docker/cli-plugins)."""
        env = os.environ.copy()
        env["ENV"] = self.env
        env["SOCIAL"] = "1" if self.social else ""
        env["PUBLIC_HOST_PORT"] = str(self.public_host_port)
        # Only export DOMAIN when set, so existing callers (and ENV=test) keep the
        # Makefile's own default. In prod this pins the Casdoor issuer to the same
        # apex the minted secrets use (Makefile: CASDOOR_ISSUER = https://id.$(DOMAIN)).
        if self.domain:
            env["DOMAIN"] = self.domain
        # "existing" source mode: build from the operator's tree, and NEVER let
        # stack-clone touch it (see __init__ — its update path git-reset --hard's
        # every checkout under STACK_SRC). Set as a pair or not at all; "clone"
        # mode must stay byte-identical to the pre-field env.
        if self.source_mode == "existing" and self.source_dir.strip():
            env["STACK_SRC"] = os.path.abspath(self.source_dir.strip())
            env["STACK_NO_CLONE"] = "1"
        # extra_env carries per-target overrides (e.g. the bridged
        # E2E_SUPERADMIN_PASSWORD for `stack-seed`). Values ride the subprocess env
        # only — never argv — mirroring the golive/token-file secret discipline.
        if extra_env:
            env.update(extra_env)
        return env

    def _make(self, target: str, timeout: int,
              extra_env: dict[str, str] | None = None) -> tuple[bool, str]:
        env = self._build_env(extra_env)
        try:
            r = subprocess.run(["make", target], cwd=self.generator_dir, env=env,
                               capture_output=True, text=True, timeout=timeout)
            return (r.returncode == 0), (r.stderr or r.stdout).strip()
        except (OSError, subprocess.SubprocessError) as e:
            return False, str(e)

    def start(self) -> tuple[bool, str]:
        # Fail-fast for EVERY caller — the tray's "start" invokes start() directly
        # (not via LocalMeshBootstrap.up()), and without this gate a cold box gets
        # the doomed 30-minute build + a truncated compose tail. preflight()
        # subsumes available(), so problems arrive as short actionable lines.
        problems = self.preflight()
        if problems:
            return False, "\n".join(problems)
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
