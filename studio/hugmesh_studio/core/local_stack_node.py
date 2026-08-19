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

import collections
import json
import os
import select
import shutil
import signal
import subprocess
import time
import urllib.request
from dataclasses import dataclass

from . import devops_tools, proc_text
from .local_services import federation_env

_COMPOSE_FILE = os.path.join("tests", "stack", "compose.local.yaml")

# Where the OPT-IN hugmesh-tor service copies the minted v3 .onion hostname
# (PUBLIC — never the key) for the host/GUI to read. Bind-mounted from ./tor-onion
# in the compose file; written ~30s after `make stack-up TOR=1`.
_TOR_ONION_HOSTNAME_FILE = os.path.join("tests", "stack", "tor-onion", "hostname")

# ── cold-build preflight wiring (mirrors the Makefile's m2 knobs) ──────────────
# `make stack-m2-bootstrap` (tests/stack/m2-bootstrap.sh) builds the org-private
# maven artifacts from source, serves them from a registry container, and writes
# this (gitignored) env file; the Makefile auto-includes the m2 compose override
# whenever the file exists.
_M2_ENV_FILE = os.path.join("tests", "stack", ".m2-registry.env")
M2_REGISTRY_CONTAINER = "hugmesh-m2-registry"
M2_BOOTSTRAP_HINT = "run `make stack-m2-bootstrap` first"
# The registry-readiness probe fetches a REAL artifact through the exact URL
# shape the services' settings.xml (and the compose build args) will use — the
# same artifact m2-bootstrap.sh self-checks after standing the registry up.
_M2_CHECK_ARTIFACT = ("systems/hugmesh/hugmesh-parent/2.8.0/"
                      "hugmesh-parent-2.8.0.pom")
_M2_PROBE_TIMEOUT_S = 3.0
# compose.local.yaml sets `name: hugmesh-local`, so built images are named
# <project>-<service>. These four services resolve PRIVATE maven artifacts at
# image-build time — a cold build of any of them needs the m2 registry.
_COMPOSE_PROJECT = "hugmesh-local"
PRIVATE_ARTIFACT_SERVICES = (
    "hugmesh-admin-bff-api",
    "hugmesh-user-bff-api",
    "hugmesh-mod-bff-api",
    "hugmesh-federation-api",
)
# A full cold build (~28 service images, a dozen of them fat Maven builds)
# comfortably exceeds 10 GiB of layers + build cache; demand sane headroom up
# front instead of failing 40 minutes into `docker compose build`.
PREFLIGHT_MIN_FREE_GIB = 20

# stack-up ceilings. The old flat 1800 s KILLED every healthy cold bring-up: a
# from-scratch `make stack-up` compiles ~28 service images (a dozen fat Maven
# builds among them) and routinely runs well past 30 minutes — the GUI then reported
# FAILED (TimeoutExpired) while docker was building fine. Warm restarts (images
# present) keep the tight ceiling; cold builds get a generous one and rely on the
# streamed output + operator Cancel instead of a guess-the-duration timeout.
WARM_STACK_UP_TIMEOUT_S = 1800
COLD_STACK_UP_TIMEOUT_S = 6 * 3600
M2_BOOTSTRAP_TIMEOUT_S = 3 * 3600
# Full-suite Playwright ceiling: 32 spec files x 90 s test timeout, workers=1,
# retries=1 — a healthy run is well under an hour; past that rely on the
# streamed output + operator Cancel, like the stack-up ceilings above.
E2E_TIMEOUT_S = 2 * 3600
# The DevOps (kind) lane: cluster create + image pulls + rollouts. Same
# order as a cold compose bring-up, so it gets the same generous ceiling.
DEVOPS_UP_TIMEOUT_S = 3600
# Read-only seeded-stack probe (verified live 2026-08-14): seed-e2e.sh leg 1
# creates org 'hugmesh' + persona e2e-admin, and Casdoor answers this GET
# WITHOUT auth — data.name == "e2e-admin" when seeded, data: null when not.
# (CASDOOR_ORG is seed-e2e.sh's default; an operator override would defeat
# this probe, which then honestly reports 'not seeded' and blocks the run.)
E2E_SEED_PROBE_URL = "http://localhost:8000/api/get-user?id=hugmesh/e2e-admin"


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
                 public_host_port: int = 8088, public_https_port: int = 8488,
                 domain: str = "",
                 source_mode: str = "clone", source_dir: str = "",
                 web_locales: tuple[str, ...] = (), login_theme_css: str = "",
                 with_tor: bool = False, with_phpbb: bool = False,
                 with_akkoma: bool = False, with_anubis: bool = False,
                 with_games: bool = False, with_tts: bool = False,
                 with_poisoner: bool = False,
                 with_egress_vpn: bool = False, egress_vpn_conf: str = "",
                 idp: str = "casdoor",
                 idp_issuer: str = "", idp_client_id: str = "", idp_jwks: str = "",
                 services=None):
        self.generator_dir = os.path.abspath(generator_dir)
        self.compose_file = os.path.join(self.generator_dir, _COMPOSE_FILE)
        self.env = env
        self.social = social
        # Opt-in Tor v3 onion for the local mesh: threads TOR=1 into `make stack-*`
        # so the Makefile adds `--profile tor` and the hugmesh-tor service comes
        # up, publishing the fe-gateway as a .onion. DEFAULT off — the unprofiled
        # stack is byte-identical to before (mirrors the `social` opt-in).
        self.with_tor = with_tor
        # PHPBB=1 / AKKOMA=1 -> the Makefile's STACK_ALT_PROFILE adds
        # `--profile phpbb` / `--profile akkoma`. DEFAULT off, same opt-in
        # shape as social/with_tor, so an unselected stack is unchanged.
        self.with_phpbb = with_phpbb
        self.with_akkoma = with_akkoma
        # GAMES=1 -> the Makefile's STACK_GAMES_PROFILE adds `--profile games`
        # (the wasm-fragment asset tier, compose.games.yaml). DEFAULT off, same
        # opt-in shape as phpbb/akkoma.
        self.with_games = with_games
        self.with_anubis = with_anubis
        # TTS=1 -> the Makefile adds `--profile edge-ai-tts` (built from source,
        # specs/cluster/manifests/edge-ai-tts/image). Was a dead toggle until
        # 2026-08-14: the row existed but nothing exported the env.
        self.with_tts = with_tts
        # POISONER=1 -> `--profile media-poisoner` AND the user-bff's four
        # media.poisoning.* env knobs (Makefile STACK_POISONER_ENV). The BFF
        # ships the cloak DARK, so BOTH halves are required — with only the
        # worker, the 'AI media cloak' control still renders unavailable.
        self.with_poisoner = with_poisoner
        # EGRESS_VPN=1 + EGRESS_VPN_CONF -> STACK_EGRESS_FLAGS adds the
        # compose.egress-vpn.yaml overlay + profile. Deliberately NO raise here on
        # a missing conf: the plan preview constructs this node mid-selection (a
        # ctor raise would escape a Qt slot and qFatal the Studio — see
        # feedback memory "no-modals-in-page-logic" for the class). Fail-closed is
        # layered elsewhere: bootstrap.validate() blocks the verbs, the page's
        # exit gate unchecks, and a conf-less container refuses to start.
        self.with_egress_vpn = with_egress_vpn
        self.egress_vpn_conf = (egress_vpn_conf or "").strip()
        self.public_host_port = public_host_port
        # The TLS front door (Makefile PUBLIC_HTTPS_PORT ?= 8488). web_url hands this
        # out rather than the plaintext port, so every operator-facing surface teaches
        # an https:// habit for a platform whose point is a private encrypted mesh.
        self.public_https_port = public_https_port
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
        # Translation catalogs the login-ui image is BUILT with (comma-joined into
        # SNAP_WEB_LOCALES for `make stack-up` -> compose build arg -> the login-ui
        # Dockerfile). EMPTY (the default) = English-only: the image ships zero
        # catalog files and the browser issues zero catalog requests. English is the
        # login-ui's SOURCE language — compiled into the bundle — so it needs no
        # catalog, which is why the default is genuinely the smallest artifact and
        # not a special case.
        #
        # BUILD-time on purpose: which catalogs SHIP has to be decided when the image
        # is built. An `environment:` var picking among catalogs already baked into
        # every image would leave every image byte-identical — a knob that changes no
        # bytes. (Which catalog a given browser LOADS is a separate, runtime question
        # the app answers by locale detection.)
        self.web_locales = tuple(web_locales)
        # ALREADY-DERIVED snap-theme.css text (studio core/theme.py css_root() is the
        # single derivation; this class only carries the text). RUNTIME on purpose —
        # the mirror image of web_locales' build-time reasoning above: the login-ui
        # entrypoint writes it to snap-theme.css at container START, so a rebrand is
        # `compose up` with a new value and NO image rebuild. EMPTY (the default) =
        # no injection: the image's compiled :root fallback renders the shipped brand.
        self.login_theme_css = login_theme_css
        # ── identity provider (I6.6) — env-var threading ONLY. idp="casdoor" (the
        # default) sets NOTHING: the stack env stays byte-identical to before these
        # params existed. An EXTERNAL provider exports the provider-neutral
        # OIDC_ISSUER / OIDC_CLIENT_ID / OIDC_JWKS_URI vars for `make stack-*`,
        # and the Makefile CONSUMES all three (the Lane-B seam, landed): they map
        # onto CASDOOR_ISSUER_URI / CASDOOR_APP_CLIENT_ID / CASDOOR_JWKS_URI, so
        # gateway + BFF token VALIDATION runs against the external issuer/JWKS.
        # The coupled legs (native login, MFA step-up, role claims) stay
        # Casdoor-only, so an external IdP in the TEST env still has no full
        # login round-trip (docs/IDENTITY-PROVIDERS.md "Honest limits").
        # The operator's full local-services selection (core/local_services.py slugs),
        # or None when no picker was used. Only its FEDERATION half is consumed here:
        # those services' containers are unconditional in compose.local.yaml, so what
        # decides whether the operator can reach them is their federation_modules
        # `enabled` row — a DB flip `make stack-seed` performs, NOT a profile flag.
        # The compose half of the same selection has already been resolved into the
        # social/with_tor booleans above by the caller, so there is exactly one place
        # each mechanism is applied. None (and a selection equal to what the registry
        # ships) exports NOTHING — see local_services.federation_env.
        self.services = tuple(services) if services is not None else None
        self.idp = idp
        self.idp_issuer = idp_issuer
        self.idp_client_id = idp_client_id
        self.idp_jwks = idp_jwks

    @property
    def web_url(self) -> str:
        """The address to HAND THE OPERATOR — TLS by default.

        The stack serves the same front door twice: plaintext on PUBLIC_HOST_PORT and
        TLS on PUBLIC_HTTPS_PORT (Makefile: 8088 / 8488). This used to return the
        plaintext one, so every surface that shows "where is my mesh" — the Open web UI
        button, the credentials dialog — taught the operator an http:// habit for a
        platform whose whole point is a private encrypted mesh, and one they would then
        have to unlearn against a real deployment.
        The cert is the per-machine CA minted into tests/stack/.tls-front/ca.crt, so a
        browser warns until that CA is imported. That is a one-time, explainable prompt;
        silently defaulting to plaintext to dodge it is the worse trade."""
        return f"https://localhost:{self.public_https_port}"

    @property
    def plain_web_url(self) -> str:
        """The plaintext front door. Kept for callers that must not hit a cert prompt —
        health probes and anything scripted — not for anything shown to the operator."""
        return f"http://localhost:{self.public_host_port}"

    def onion_hostname(self) -> str:
        """The local mesh's minted v3 .onion address, or "" if not published yet.
        Reads the PUBLIC hostname the hugmesh-tor service copies to
        ./tor-onion/hostname (bind-mount) ~30s after a `TOR=1` bring-up. Never
        raises — an absent/unreadable file (tor off, or not yet minted) is "".
        The private key never leaves the tor-onion-keys volume, so it is not here."""
        try:
            with open(os.path.join(self.generator_dir, _TOR_ONION_HOSTNAME_FILE),
                      encoding="utf-8") as f:
                return "".join(f.read().split())
        except OSError:
            return ""

    def onion_url(self) -> str:
        """``http://<onion>/`` for the published onion, or "" when none yet."""
        h = self.onion_hostname()
        return f"http://{h}/" if h else ""

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
        if rc == 0 and root:
            # NOT os.path.exists(): the data-root is root-owned 0700, so an
            # unprivileged Studio gets PermissionError walking to it and exists()
            # answers False — indistinguishable from "not visible". That silently
            # fell through to the generator checkout, which on this machine is a
            # DIFFERENT filesystem: /home had 668 GiB free while docker's own
            # partition had 331. Benign there, but on a box with a roomy /home and
            # a nearly-full docker partition it greenlights a cold build that then
            # fills the docker disk and dies — the exact failure that crashed this
            # operator's 56-container mesh on 2026-08-14.
            #
            # Ask the filesystem instead of guessing, and on EACCES walk up to the
            # nearest ancestor we can stat: /var/lib/containerd is still the right
            # filesystem even when /var/lib/containerd/docker is unreadable.
            probe = root
            while probe:
                try:
                    return shutil.disk_usage(probe).free / (1024 ** 3)
                except OSError:
                    parent = os.path.dirname(probe)
                    if parent == probe:      # reached / and still nothing
                        break
                    probe = parent
        # Last resort only: no data-root reported (a remote daemon), so the local
        # checkout's filesystem is the best available proxy.
        try:
            return shutil.disk_usage(self.generator_dir).free / (1024 ** 3)
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
        # User-local CLIs first (out/tools/bin — the DevOps lane's kind/kubectl
        # when the operator installed them from the Studio). PREPENDED so a lane
        # started right after that install works with no shell restart; harmless
        # and byte-neutral for every other verb when the dir does not exist.
        tools = devops_tools.tools_dir(self.generator_dir)
        if os.path.isdir(tools):
            env["PATH"] = tools + os.pathsep + env.get("PATH", "")
        env["ENV"] = self.env
        env["SOCIAL"] = "1" if self.social else ""
        # TOR=1 -> the Makefile's STACK_TOR_PROFILE adds `--profile tor` and the
        # hugmesh-tor service comes up. Set explicitly (""=off) so an inherited
        # TOR=1 in the operator's shell can't silently flip it, exactly like SOCIAL —
        # and `$(strip $(TOR))` empty leaves the unprofiled env byte-identical.
        env["TOR"] = "1" if self.with_tor else ""
        # Set explicitly ("" = off) for the same reason as SOCIAL/TOR: an
        # inherited PHPBB=1/AKKOMA=1 in the operator's shell must not silently
        # flip a stack the picker said nothing about.
        env["PHPBB"] = "1" if self.with_phpbb else ""
        env["AKKOMA"] = "1" if self.with_akkoma else ""
        env["GAMES"] = "1" if self.with_games else ""
        env["ANUBIS"] = "1" if self.with_anubis else ""
        env["TTS"] = "1" if self.with_tts else ""
        env["POISONER"] = "1" if self.with_poisoner else ""
        env["EGRESS_VPN"] = "1" if self.with_egress_vpn else ""
        if self.with_egress_vpn and self.egress_vpn_conf:
            # abspath: the Makefile $(abspath) would resolve a relative path
            # against ITS cwd, not the operator's picker — hand it absolute.
            # (conf-less stays unexported: compose mounts /dev/null and the
            # container refuses — the terminal fail-closed layer.)
            env["EGRESS_VPN_CONF"] = os.path.abspath(self.egress_vpn_conf)
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
        # Only export when non-empty so the default path stays byte-identical to
        # every existing caller (and to a plain `make stack-up`), exactly like DOMAIN.
        # The Makefile's own SNAP_WEB_LOCALES default is empty, so an unset value and
        # an empty value mean the same thing: English-only.
        if self.web_locales:
            env["SNAP_WEB_LOCALES"] = ",".join(self.web_locales)
        # Same only-when-set discipline: compose's ${SNAP_THEME_CSS:-} defaults empty,
        # so unset and empty both mean "shipped default brand" and the unthemed env
        # stays byte-identical to every existing caller.
        if self.login_theme_css.strip():
            env["SNAP_THEME_CSS"] = self.login_theme_css
            # ALSO persist it (tests/stack/.theme.css, gitignored): the env var only
            # covers THIS invocation, so before this write a terminal `make stack-up`
            # (a restore, a rebuild, a peer's bring-up) silently reverted the login
            # page to the shipped brand — the operator's "my theme isn't applied".
            # The Makefile threads the file's text back as SNAP_THEME_CSS whenever it
            # exists (STACK_THEME_ENV). Best-effort on purpose: an unwritable file
            # must never block a bring-up, and the env var above still applies now.
            try:
                theme_file = os.path.join(
                    self.generator_dir, "tests", "stack", ".theme.css")
                with open(theme_file, "w", encoding="utf-8") as fh:
                    fh.write(self.login_theme_css)
            except OSError:
                pass
        # External IdP (I6.6): exported ONLY for an external provider WITH an issuer,
        # so the casdoor default (and a half-configured external) leaves the env
        # byte-identical. Consumed by the Makefile's OIDC seam (landed): the vars
        # map onto CASDOOR_ISSUER_URI / CASDOOR_APP_CLIENT_ID / CASDOOR_JWKS_URI
        # for gateway + BFF token validation (documented in __init__). Values are
        # public endpoints/identifiers — never secrets.
        if self.idp != "casdoor" and self.idp_issuer.strip():
            env["OIDC_ISSUER"] = self.idp_issuer.strip()
            if self.idp_client_id.strip():
                env["OIDC_CLIENT_ID"] = self.idp_client_id.strip()
            if self.idp_jwks.strip():
                env["OIDC_JWKS_URI"] = self.idp_jwks.strip()
        # FEDERATION services: the enable/disable slug pair `make stack-seed` needs to
        # flip federation_modules.enabled. Rides the SAME env channel as every other
        # stack knob (never a new file format), and federation_env() returns {} both
        # when no selection was made and when the selection already matches what the
        # registry ships — so the untouched bring-up's env is byte-identical, which is
        # what tests/test_local_mesh_tor.py's env-equality guard rests on.
        env.update(federation_env(self.services))
        # extra_env carries per-target overrides (e.g. the bridged
        # E2E_SUPERADMIN_PASSWORD for `stack-seed`). Values ride the subprocess env
        # only — never argv — mirroring the golive/token-file secret discipline.
        if extra_env:
            env.update(extra_env)
        return env

    def _make(self, target: str, timeout: int,
              extra_env: dict[str, str] | None = None,
              on_line=None, cancel=None) -> tuple[bool, str]:
        """Run ``make <target>``. Without ``on_line``/``cancel`` this is the original
        buffered contract (subprocess.run, full output at the end). WITH them it
        STREAMS: merged stdout+stderr line-by-line into ``on_line`` as the build
        runs (what makes an hour-long cold compose build watchable in the GUI), and
        ``cancel`` (a threading.Event-like with .is_set()) terminates the whole
        process GROUP — make's compose/docker children included, which is why the
        child starts in its own session. The returned message is the output TAIL
        (last 400 lines), which is what error reporting actually needs."""
        env = self._build_env(extra_env)
        if on_line is None and cancel is None:
            try:
                r = subprocess.run(["make", target], cwd=self.generator_dir, env=env,
                                   capture_output=True, text=True, timeout=timeout)
                return (r.returncode == 0), (r.stderr or r.stdout).strip()
            except (OSError, subprocess.SubprocessError) as e:
                return False, str(e)
        try:
            proc = subprocess.Popen(
                ["make", target], cwd=self.generator_dir, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                # Had errors="replace" but no encoding, so it could not CRASH — it just
                # decoded with the launcher's locale and mojibaked under C/POSIX. Pinning
                # utf-8 is the other half of the same fix. See core/proc_text.
                start_new_session=(os.name == "posix"), **proc_text.TEXT_IO)
        except OSError as e:
            return False, str(e)
        tail: collections.deque[str] = collections.deque(maxlen=400)
        deadline = time.monotonic() + timeout
        cancelled = timed_out = False

        def _kill() -> None:
            try:
                if os.name == "posix":
                    os.killpg(proc.pid, signal.SIGTERM)
                else:
                    proc.terminate()
            except OSError:
                pass

        while True:
            if cancel is not None and cancel.is_set() and not cancelled:
                cancelled = True
                _kill()
            if time.monotonic() > deadline and not (cancelled or timed_out):
                timed_out = True
                _kill()
            # 1 s select keeps cancel/timeout responsive while the build is quiet;
            # non-POSIX pipes can't select — there the loop blocks per line (cancel
            # still lands on the next line, and the local stack is a Linux surface).
            if os.name == "posix":
                ready, _, _ = select.select([proc.stdout], [], [], 1.0)
                if not ready:
                    if proc.poll() is not None:
                        break
                    continue
            line = proc.stdout.readline()
            if line == "":
                break
            line = line.rstrip("\n")
            tail.append(line)
            if on_line is not None:
                on_line(line)
        try:
            rc = proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            try:
                if os.name == "posix":
                    os.killpg(proc.pid, signal.SIGKILL)
                else:
                    proc.kill()
            except OSError:
                pass
            rc = proc.wait()
        text = "\n".join(tail).strip()
        if cancelled:
            return False, f"cancelled by operator.\n{text}"[:8000]
        if timed_out:
            return False, (f"timed out after {timeout} s (process group terminated)."
                           f"\n{text}")[:8000]
        return rc == 0, text

    def cold_build_expected(self) -> bool:
        """True when any private-maven service image is absent — the first stack-up
        will COMPILE the fleet (hours-scale) instead of restarting it (minutes)."""
        return any(not self._image_present(f"{_COMPOSE_PROJECT}-{s}")
                   for s in PRIVATE_ARTIFACT_SERVICES)

    def start(self, on_line=None, cancel=None) -> tuple[bool, str]:
        # Fail-fast for EVERY caller — the tray's "start" invokes start() directly
        # (not via LocalMeshBootstrap.up()), and without this gate a cold box gets
        # the doomed 30-minute build + a truncated compose tail. preflight()
        # subsumes available(), so problems arrive as short actionable lines.
        problems = self.preflight()
        if problems:
            return False, "\n".join(problems)
        # stack-clone + build + up -d. COLD (service images absent) compiles ~24
        # images and needs the generous ceiling — the flat 1800 s here used to kill
        # every healthy first bring-up at minute 30 and report it FAILED.
        cold = self.cold_build_expected()
        if cold and on_line is not None:
            on_line("[stack-up] COLD BUILD: service images are absent, so this first "
                    "run compiles the whole stack (~28 images, a dozen of them fat "
                    "Maven builds) — well over an hour on most machines. Output "
                    "streams below; Cancel stays available.")
        return self._make("stack-up",
                          timeout=(COLD_STACK_UP_TIMEOUT_S if cold
                                   else WARM_STACK_UP_TIMEOUT_S),
                          on_line=on_line, cancel=cancel)

    def seed(self, extra_env: dict[str, str] | None = None,
             timeout: int = 600, on_line=None, cancel=None) -> tuple[bool, str]:
        """`make stack-seed` — provision Casdoor identity (org+roles+personas) into
        the already-running stack. ``extra_env`` bridges secret values (the minted
        E2E_SUPERADMIN_PASSWORD) through the subprocess env, never argv.

        Also opts INTO registration stage 2 (seed-e2e.sh leg 1c). Seeding a Casdoor
        identity alone leaves `registrationComplete=false`, and the gateway then
        grants that identity a bare ROLE_USER whatever roles Casdoor holds — so
        every service remote 403s and the shell greys its tiles with "Complete your
        registration to use this." A mesh you can sign into but not navigate reads
        as broken, and THIS path's product is a clickable mesh. The seeder keeps the
        flag off by default because the e2e suite needs personas that are still
        gated (spec 17 drives the pending-registration UI); an explicit caller
        override in ``extra_env`` still wins."""
        env = {"SEED_COMPLETE_REGISTRATION": "1"}
        env.update(extra_env or {})
        return self._make("stack-seed", timeout=timeout, extra_env=env,
                          on_line=on_line, cancel=cancel)

    def m2_bootstrap(self, on_line=None, cancel=None) -> tuple[bool, str]:
        """`make stack-m2-bootstrap` — the COLD-BUILD prerequisite: build the
        org-private maven artifacts FROM SOURCE and serve them from the local
        registry container. This is the action preflight's "run `make
        stack-m2-bootstrap` first" hint names — callable from the GUI so a
        from-scratch bring-up never needs a terminal."""
        return self._make("stack-m2-bootstrap", timeout=M2_BOOTSTRAP_TIMEOUT_S,
                          on_line=on_line, cancel=cancel)

    # ---- e2e suite against the RUNNING stack -------------------------------------

    def running_env(self) -> str:
        """The ENV the RUNNING stack was started with — "test", "prod", or ""
        when unreadable (stack down, docker absent). Nothing records ENV on
        disk: the Makefile resolves it to CASDOOR_ISSUER and threads it into
        every service as CASDOOR_ISSUER_URI (STACK_ENV), so the one honest
        source is the running fe-gateway container's env — an http://localhost
        issuer is test, https://… is prod. ``self.env`` is only what the FORM
        currently says, which is exactly why it is not consulted here."""
        base = _compose_base()
        if not base or not os.path.exists(self.compose_file):
            return ""
        try:
            r = subprocess.run([*base, "-f", self.compose_file, "ps", "-q",
                                "hugmesh-fe-gateway"],
                               cwd=self.generator_dir, capture_output=True,
                               text=True, timeout=30)
            cid = r.stdout.strip().splitlines()[0].strip() if r.stdout.strip() else ""
            if not cid:
                return ""
            r = subprocess.run(
                ["docker", "inspect", "-f",
                 "{{range .Config.Env}}{{println .}}{{end}}", cid],
                capture_output=True, text=True, timeout=30)
            for ln in r.stdout.splitlines():
                if ln.startswith("CASDOOR_ISSUER_URI="):
                    issuer = ln.partition("=")[2]
                    if issuer.startswith("https://"):
                        return "prod"
                    if issuer.startswith("http://"):
                        return "test"
        except (OSError, subprocess.SubprocessError):
            pass
        return ""

    def e2e_seeded(self) -> tuple[bool, str]:
        """Has `make stack-seed` actually provisioned the e2e personas? A
        READ-ONLY probe of the running Casdoor (no token minted, nothing
        written): see E2E_SEED_PROBE_URL. Any error — Casdoor down, port not
        published — reports why instead of raising."""
        try:
            with urllib.request.urlopen(E2E_SEED_PROBE_URL, timeout=5) as r:  # noqa: S310 - fixed localhost URL
                data = json.load(r)
        except (OSError, ValueError) as e:
            return False, f"Casdoor not answering on localhost:8000 ({e})"
        user = data.get("data") if isinstance(data, dict) else None
        if isinstance(user, dict) and user.get("name") == "e2e-admin":
            return True, ""
        return False, ("persona 'e2e-admin' not in Casdoor — the stack is up "
                       "but unseeded; run `make stack-seed` (the bootstrap's "
                       "bring-up seeds automatically)")

    def e2e_ready(self) -> list[str]:
        """Every reason the e2e suite cannot run RIGHT NOW (empty = ready) —
        read-only probes only, cheapest first. This one list is BOTH the GUI
        button's enablement and run_e2e()'s fail-fast gate, so they can never
        disagree."""
        problems: list[str] = []
        e2e_dir = os.path.join(self.generator_dir, "tests", "e2e")
        if not os.path.isdir(e2e_dir):
            problems.append("tests/e2e not found in this checkout.")
        elif not os.path.isdir(os.path.join(e2e_dir, "node_modules")):
            problems.append("tests/e2e/node_modules missing — run `make "
                            "playwright-deps` once (npm ci + chromium).")
        if not self.status().running:
            problems.append("the local stack is not running — bring it up first.")
            return problems
        env = self.running_env()
        if env != "test":
            problems.append(
                f"the RUNNING stack's env is '{env or 'unreadable'}', not "
                f"'test' — the suite drives throwaway e2e personas against "
                f"the localhost issuer and must never run against a prod mesh.")
            return problems
        ok, why = self.e2e_seeded()
        if not ok:
            problems.append(f"e2e personas not seeded: {why}")
        return problems

    def run_e2e(self, extra_env: dict[str, str] | None = None,
                on_line=None, cancel=None) -> tuple[bool, str]:
        """`make stack-e2e` — the Playwright suite (tests/e2e) against the
        RUNNING local stack's TLS front door (SNAP_BASE_URL=web_url's port).
        Streams like the other long verbs; Cancel kills the whole process
        group (make + npx + browsers). Afterwards the run's summary.json (the
        hugmesh reporter's DURABLE artifact: passed/failed/skipped) is read
        back and reported as ONE honest counts line — never scraped from the
        scrolling list output; a missing summary is reported as exactly that."""
        problems = self.e2e_ready()
        if problems:
            return False, "\n".join(problems)
        report_rel = os.path.join(
            "test-results", time.strftime("studio-%Y%m%d-%H%M%S"))
        # extra_env bridges the mesh's real superadmin identity
        # (CASDOOR_SUPERADMIN_USERNAME + the minted E2E_SUPERADMIN_PASSWORD)
        # into the suite — without it every superadmin login 401s on a
        # studio-bootstrapped mesh (spec-28 failure, 2026-08-14). Values ride
        # the subprocess env, never argv.
        env = {"SNAP_REPORT_DIR": report_rel}
        env.update(extra_env or {})
        ok, msg = self._make("stack-e2e", timeout=E2E_TIMEOUT_S,
                             extra_env=env,
                             on_line=on_line, cancel=cancel)
        summary_path = os.path.join(self.generator_dir, "tests", "e2e",
                                    report_rel, "summary.json")
        try:
            with open(summary_path, encoding="utf-8") as fh:
                s = json.load(fh)
            line = (f"[e2e] {s.get('passed', 0)} passed, "
                    f"{s.get('failed', 0)} failed, "
                    f"{s.get('skipped', 0)} skipped — summary: {summary_path}")
        except (OSError, ValueError):
            line = ("[e2e] no summary.json written (the run ended before the "
                    "reporter finished) — see the log above.")
        if on_line is not None:
            on_line(line)
        return ok, f"{line}\n{msg}"

    # ── the DEVOPS lane (Kubernetes) ─────────────────────────────────────────
    # ArgoCD and the workload console are Kubernetes CONTROLLERS: they reconcile
    # / inspect cluster objects, so no compose profile could ever make them real
    # (core/local_services.MECH_KIND). The repo already ships a real local
    # Kubernetes lane — specs/cluster/bootstrap/kind-local/bootstrap-kind.sh,
    # driven by `make kind-up`, which installs UPSTREAM ArgoCD and applies this
    # mesh's app tree. These verbs expose that lane instead of pretending the
    # docker lane can host it (operator ask 2026-08-14).
    def devops_available(self) -> list[str]:
        """Why the DevOps lane cannot start right now (empty = it can). Checked
        BEFORE the long verb so the operator is told up front, in the same
        register as e2e_ready().

        Tools count as present when they are on PATH **or** in this repo's
        user-local tools dir (out/tools/bin), which the Install prerequisites
        verb fills and _build_env() prepends to PATH — so a lane started right
        after that install works without a shell restart."""
        problems: list[str] = []
        for tool, why in (("kind", "create the local Kubernetes cluster"),
                          ("kubectl", "apply the cluster's app tree")):
            if devops_tools.which(tool, self.generator_dir) is None:
                problems.append(f"`{tool}` is not installed — the DevOps lane "
                                f"needs it to {why}. Use \"Install DevOps "
                                f"prerequisites\" to fetch it (user-local, "
                                f"checksum-verified, no sudo).")
        return problems

    def devops_install_tools(self, on_line=None) -> tuple[bool, str]:
        """Fetch the lane's missing CLIs into out/tools/bin (see
        core/devops_tools: pinned versions, SHA-256 verified, no sudo, nothing
        outside the repo's gitignored out/)."""
        return devops_tools.install(self.generator_dir, on_line=on_line)

    def devops_up(self, on_line=None, cancel=None) -> tuple[bool, str]:
        """`make kind-up` — create the local Kubernetes cluster and bootstrap the
        SSO slice: real upstream ArgoCD, the app tree, Vault KV and the identity
        seed. LONG (image pulls + rollouts) and streamed like stack-up; Cancel
        terminates the whole process group.

        Deliberately SEPARATE from the docker lane rather than folded into it:
        the two are different backends for the same mesh, and starting one must
        never silently reconfigure the other."""
        problems = self.devops_available()
        if problems:
            return False, "\n".join(problems)
        return self._make("kind-up", timeout=DEVOPS_UP_TIMEOUT_S,
                          on_line=on_line, cancel=cancel)

    def devops_down(self, on_line=None, cancel=None) -> tuple[bool, str]:
        """`make kind-down` — delete the local Kubernetes cluster. Destructive for
        the DevOps lane ONLY: the docker mesh and its volumes are untouched."""
        return self._make("kind-down", timeout=600,
                          on_line=on_line, cancel=cancel)

    def stop(self) -> tuple[bool, str]:
        """`make stack-halt` — stop the mesh and KEEP its data.

        Deliberately NOT `stack-down`, which passes `down -v` and drops every named
        volume: Casdoor identity, Matrix rooms, Mastodon accounts, the phpBB board
        and all the BFF databases. This method backs the operator-facing Stop
        button, where "stop my mesh" must not mean "destroy my mesh" — pressing it
        used to leave the operator unable to log in, post or open the forum after a
        restart, because their whole identity tier had been wiped and never
        re-seeded. `clean()` below remains the destructive one, and says so."""
        return self._make("stack-halt", timeout=300)

    def clean(self, on_line=None, cancel=None) -> tuple[bool, str]:
        """`make stack-clean` — stop the stack AND reclaim its disk: the ~28 images
        this stack BUILT, its volumes, orphaned containers, and the private-maven
        registry container + cache. Scoped to this compose project: pulled base
        images (postgres/cassandra/mastodon/…) that other projects may share are
        KEPT, and no `docker system prune` is ever issued. Streams like the other
        long actions — removing ~28 images is not instant."""
        return self._make("stack-clean", timeout=900, on_line=on_line, cancel=cancel)

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
