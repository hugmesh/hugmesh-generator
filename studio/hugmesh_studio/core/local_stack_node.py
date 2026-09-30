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
import re
import select
import shutil
import signal
import subprocess
import time
import urllib.parse
import urllib.request
from collections.abc import Sequence
from dataclasses import dataclass

from . import devops_tools, e2e_catalogue, own_casdoor, proc_group, proc_text
from . import resource_limits, stack_limits
from .local_services import (KIND_ADDONS_ENV, KIND_ADDONS_NONE, federation_env,
                             kind_addon_default_selection, kind_addon_env,
                             validate_kind_addons)

_COMPOSE_FILE = os.path.join("tests", "stack", "compose.local.yaml")

# Where the OPT-IN hugmesh-tor service copies the minted v3 .onion hostname
# (PUBLIC — never the key) for the host/GUI to read. Bind-mounted from ./tor-onion
# in the compose file; written ~30s after `make stack-up TOR=1`.
_TOR_ONION_HOSTNAME_FILE = os.path.join("tests", "stack", "tor-onion", "hostname")
#: The compose overlay a TOR=1 stack with Tor domains is brought up with (#582; the
#: Makefile's STACK_TOR_DOMAINS_COMPOSE — a test pins the two spellings together).
_TOR_DOMAINS_COMPOSE_FILE = os.path.join("tests", "stack", "compose.tor-domains.yaml")
#: The compose service that mints and publishes the onion (compose.local.yaml).
_TOR_SERVICE = "hugmesh-tor"
#: How far a hostname copy may PRE-date the container's recorded StartedAt and still
#: count as this container's. The entrypoint's `cp` runs a few ms after its process
#: starts, and docker records StartedAt once runc returns — so on a restart with the
#: key already in the volume the copy can land fractionally BEFORE the stamp. Two
#: seconds covers that race; a copy from a PREVIOUS container is older by at least a
#: whole `stack-down`/`stack-up` (tens of seconds), which is what the check exists
#: to refuse (#581).
_ONION_START_SKEW_S = 2.0
#: The node contract's per-domain slug (#599; core.domain_services.TOR_SLUG_RE) and a
#: v3 onion hostname (56 base32 characters). A per-domain readout is read out of a
#: root-owned shared directory, so both are checked before anything hands it out.
_TOR_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
_ONION_V3_RE = re.compile(r"^[a-z2-7]{56}\.onion$")
_DOCKER_TIME_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$")


def _parse_docker_time(value: str) -> float | None:
    """docker's RFC 3339 ``State.StartedAt`` (nanoseconds, ``Z`` or an offset) as
    epoch seconds, or None. Parsed by hand because the fraction carries NINE digits,
    which ``datetime.fromisoformat`` does not accept on every Python this runs on;
    docker's zero value (``0001-01-01T00:00:00Z``, never started) is None too."""
    from datetime import datetime
    m = _DOCKER_TIME_RE.match((value or "").strip())
    if not m:
        return None
    base, frac, tz = m.groups()
    tz = "+00:00" if tz == "Z" else tz
    try:
        ts = datetime.fromisoformat(base + tz).timestamp()
    except ValueError:
        return None
    if ts <= 0:
        return None
    return ts + (float("0." + frac) if frac else 0.0)

# ── cold-build preflight wiring (mirrors the Makefile's m2 knobs) ──────────────
# `make stack-m2-bootstrap` (tests/stack/m2-bootstrap.sh) builds the org-private
# maven artifacts from source, serves them from a registry container, and writes
# this (gitignored) env file; the Makefile auto-includes the m2 compose override
# whenever the file exists.
_M2_ENV_FILE = os.path.join("tests", "stack", ".m2-registry.env")
_M2_BOOTSTRAP_SCRIPT = os.path.join("tests", "stack", "m2-bootstrap.sh")
M2_REGISTRY_CONTAINER = "hugmesh-m2-registry"
M2_BOOTSTRAP_HINT = "run `make stack-m2-bootstrap` first"
# The registry-readiness probe fetches a REAL artifact through the exact URL
# shape the services' settings.xml (and the compose build args) will use — the
# same artifact m2-bootstrap.sh self-checks after standing the registry up.
# Its coordinate is DERIVED FROM THAT SCRIPT'S PINS, never restated here. It
# WAS restated, and still said `systems/hugmesh` after the Maven groupIds moved
# to `net/hugmesh` (the groupIds lagged the Java package move) — so this half of
# the probe asked a healthy registry for a path nothing publishes. It only ever
# passed on hosts whose m2 cache still held a pre-rename tree. m2-bootstrap.sh
# derives its own self-check path from the same PIN for the same reason; reading
# the coordinate out of PINS means a future rename moves BOTH probes with it.
_M2_PARENT_ARTIFACT = "hugmesh-parent"
# PINS entries are `repo|sha|artifactId|version|kind|groupPath`, one quoted
# string per line inside a `PINS=( ... )` array (interleaved with comments).
_M2_PINS_BLOCK_RE = re.compile(r"^PINS=\((.*?)^\)", re.S | re.M)
_M2_PIN_ENTRY_RE = re.compile(r'^"([^"]+)"')
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
# Where bootstrap-kind.sh mounts the checkout (read-only) into the kind node
# at CLUSTER CREATE time, for the tokenless local sync path — an in-cluster
# read-only git daemon serves it to ArgoCD so a local mesh needs no GitHub
# credential (issue #48). An EXISTING cluster created before that path can
# never gain the mount; the preflight below detects exactly that.
KIND_REPO_MOUNT = "/hugmesh/hugmesh-generator"
# Namespace ArgoCD lives in, and the GitOps repo its Applications name — both
# are bootstrap-kind.sh's own defaults (ARGOCD_NS, GITOPS_REPO_DEFAULT). Kept
# here so the repo-access preflight asks about exactly the objects the
# bootstrap creates.
ARGOCD_NS = "devops"
GITOPS_REPO_URL = "https://github.com/hugmesh/hugmesh-generator.git"
#: The kind cluster bootstrap-kind.sh creates, and the name every probe below asks
#: about. ONE reader of the override so a probe can never disagree with the verb.
KIND_CLUSTER_DEFAULT = "hugmesh-local"
# Read-only seeded-stack probe (verified live 2026-08-14): seed-e2e.sh leg 1
# creates org 'hugmesh' + persona e2e-admin, and Casdoor answers this GET
# WITHOUT auth — data.name == "<user>" when seeded, data: null when not.
# (CASDOOR_ORG is seed-e2e.sh's default; an operator override would defeat
# this probe, which then honestly reports 'not seeded' and blocks the run.)
# Templated on the persona so the SAME probe can ask about mesh-operator — the
# account only the SEED_COMPLETE_REGISTRATION=1 path creates — instead of the
# credentials dialog guessing that it exists. Compose lane only: the kind
# Casdoor is ClusterIP with no host port.
_SEED_PROBE_TEMPLATE = "http://localhost:8000/api/get-user?id=hugmesh/{user}"
E2E_SEED_PROBE_URL = _SEED_PROBE_TEMPLATE.format(user="e2e-admin")


def _kind_cluster_name() -> str:
    """The kind cluster this repo's lane drives — bootstrap-kind.sh reads the same
    KIND_CLUSTER_NAME override, so the probes and the verb always mean one cluster."""
    return os.environ.get("KIND_CLUSTER_NAME", "") or KIND_CLUSTER_DEFAULT


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
                 services=None,
                 own_idp_domains: tuple[str, ...] = (),
                 kind_addons=None,
                 tor_domains=()):
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
        # HUG_WEB_LOCALES for `make stack-up` -> compose build arg -> the login-ui
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
        # and the Makefile CONSUMES all three (the Lane-B env-var contract, landed): they map
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
        # The DEVOPS lane's own service selection (core/local_services.KIND_ADDONS
        # slugs), or None when no picker was used. A SEPARATE axis from `services`
        # on purpose: these are Kubernetes Applications the kind bootstrap adds to
        # its curated set, they have no compose profile and no federation row, and
        # folding them into the docker lane's list is the lane confusion
        # local_services exists to prevent.
        #
        # None — and a selection equal to what the lane already ships — exports
        # NOTHING, so `make kind-up` runs with the same env, byte for byte, as
        # before this axis existed (the same invariant `services`/federation_env
        # holds). See local_services.kind_addon_env.
        self.kind_addons = tuple(kind_addons) if kind_addons is not None else None
        self.idp = idp
        self.idp_issuer = idp_issuer
        self.idp_client_id = idp_client_id
        self.idp_jwks = idp_jwks
        # Domains whose sign-in says 'own' (config.Domain.idp, issue #47), in
        # Domains-table order. EMPTY (the default) threads NOTHING new and the
        # stack env stays byte-identical — the same opt-in shape as every knob
        # above. Non-empty: _build_env writes the per-domain Casdoor compose
        # overlay (core/own_casdoor.py — the compose.brand-b.yaml wiring, host
        # ports 8001+), flips OWN_CASDOOR=1 (the Makefile's `own-casdoor`
        # profile) and exports the multi-issuer APP_TENANCY_* registry.
        self.own_idp_domains = tuple(own_idp_domains or ())
        # The domains with their OWN Tor front door (#582, decision 68 = A):
        # ``((name, slug, tenant), ...)`` from core.domain_services.tor_domain_entries.
        # Passed to `make stack-up` as TOR_ONION_DOMAINS="<slug>=<tenant> ..." ONLY on
        # a TOR=1 stack — the tor entrypoint mints one onion per slug and registers
        # each in the gateway's host map (hugmesh-gateway#38). Empty (the default, and
        # every caller from before this existed) passes nothing new.
        self.tor_domains = tuple(tuple(e) for e in (tor_domains or ()))

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

    def _tor_started_at(self) -> float | None:
        """Epoch seconds the RUNNING ``hugmesh-tor`` container of this compose project
        started, or None — not running, docker absent/unreachable, or unparseable.

        By compose LABEL (project + service), never by container name: the name is
        compose's to choose, the labels are the contract (mesh_monitor and
        saved_meshes filter the same way). Blocking — two docker calls, 5 s each at
        most — so an off-GUI-thread caller is the norm (the monitor, capture,
        ``_await_onion``); the one GUI-thread caller is the Copy .onion button."""
        if not shutil.which("docker"):
            return None
        try:
            r = subprocess.run(
                ["docker", "ps", "-q", "--no-trunc",
                 "--filter", f"label=com.docker.compose.project={_COMPOSE_PROJECT}",
                 "--filter", f"label=com.docker.compose.service={_TOR_SERVICE}",
                 "--filter", "status=running"],
                capture_output=True, text=True, timeout=5)
            ids = r.stdout.split() if r.returncode == 0 else []
            if not ids:
                return None
            r = subprocess.run(
                ["docker", "inspect", "-f", "{{.State.Running}} {{.State.StartedAt}}",
                 ids[0]], capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            return None
        running, _, started = r.stdout.strip().partition(" ")
        if r.returncode != 0 or running != "true":
            return None
        return _parse_docker_time(started)

    @property
    def tor_domains_overlay(self) -> str:
        """The compose overlay this node's stack is brought up with when it is a TOR=1
        stack with Tor domains (the Makefile's STACK_TOR_DOMAINS_FLAGS), else "". A
        command that creates containers for this stack outside `make stack-up` (the
        monitor's scale) must load it too, or a new fe-gateway replica would come up
        without the onion host map and serve every onion as the default brand."""
        if self.with_tor and self.tor_domains:
            return os.path.join(self.generator_dir, _TOR_DOMAINS_COMPOSE_FILE)
        return ""

    def onion_url(self, domain: str = "") -> str:
        """``https://<onion>/`` for the onion the RUNNING tor container published, or
        "" when there is none to hand out. With ``domain`` — a Tor domain's name
        ("shop.example") or its key directory name ("shop-example") — that DOMAIN's
        own onion instead (#582 — :meth:`onion_urls`, same freshness rule); without,
        the mesh's primary onion, which serves the mesh's own domain.

        HTTPS, like ``make stack-onion``: the compose onion publishes ``:443`` to the
        TLS front (tests/stack/tor/entrypoint.sh, #598) — a secure context, a Secure
        session cookie on a production-configured mesh, and the node agent's own port
        (docs/TOR-HIDDEN-SERVICE.md "Why :443"; the older "an http page cannot boot the
        app" reason was false, #628). The monitor's door, the Copy .onion
        button and a saved record's ``doors.onion`` all hand out this one string.

        The hostname file is a bind-mount copy that OUTLIVES the key it names (#581):
        ``make stack-down``/``stack-clean`` run ``down -v``, which drops the
        ``tor-onion-keys`` volume — the next TOR=1 up mints a NEW onion — but never
        touches ``tests/stack/tor-onion/hostname`` (root-owned, gitignored). Read
        bare, it announced a dead address to the monitor, the Copy button, a saved
        record's ``doors.onion`` and ``_await_onion`` (which returned the PREVIOUS
        mesh's onion on its first poll after a re-create). So the file counts only
        when a ``hugmesh-tor`` container is running AND the copy was written by it:
        mtime no older than that container's StartedAt (minus
        :data:`_ONION_START_SKEW_S`). The entrypoint copies without ``-p`` on every
        start, so a live container always refreshes the mtime.
        ``onion_hostname()`` stays the raw, probe-free file read."""
        if domain:
            return self.onion_url_for(domain)
        h = self.onion_hostname()
        if not h:
            return ""
        started = self._tor_started_at()
        if started is None:
            return ""                     # nothing running can be serving that key
        try:
            written = os.stat(os.path.join(self.generator_dir,
                                           _TOR_ONION_HOSTNAME_FILE)).st_mtime
        except OSError:
            return ""
        if written + _ONION_START_SKEW_S < started:
            return ""                     # a previous container's copy — stale
        return f"https://{h}/"

    def onion_urls(self) -> dict[str, str]:
        """``{slug: "https://<onion>/"}`` for every PER-DOMAIN onion (#582) the RUNNING
        tor container published — ``tests/stack/tor-onion/<slug>.hostname``, one per
        ``TOR_ONION_DOMAINS`` entry — or ``{}``.

        The SAME freshness rule as :meth:`onion_url` (#581, per-domain half): a file
        counts only when a ``hugmesh-tor`` container is running AND the copy is no
        older than that container's StartedAt. ONE container probe for all of them. A
        file whose slug the node contract would refuse, or whose content is not a v3
        onion, is not an onion and is skipped — the directory is root-owned and
        shared, so it is read as data, never trusted."""
        out_dir = os.path.dirname(os.path.join(self.generator_dir,
                                               _TOR_ONION_HOSTNAME_FILE))
        try:
            names = sorted(os.listdir(out_dir))
        except OSError:
            return {}
        candidates: dict[str, str] = {}
        for fn in names:
            if not fn.endswith(".hostname"):
                continue
            slug = fn[:-len(".hostname")]
            if not _TOR_SLUG_RE.match(slug):
                continue
            candidates[slug] = os.path.join(out_dir, fn)
        if not candidates:
            return {}
        started = self._tor_started_at()
        if started is None:
            return {}                     # nothing running can be serving those keys
        out: dict[str, str] = {}
        for slug, path in candidates.items():
            try:
                with open(path, encoding="utf-8") as f:
                    h = "".join(f.read().split())
                written = os.stat(path).st_mtime
            except OSError:
                continue
            if not _ONION_V3_RE.match(h) or written + _ONION_START_SKEW_S < started:
                continue                  # not an onion, or a previous container's copy
            out[slug] = f"https://{h}/"
        return out

    def onion_url_for(self, domain: str) -> str:
        """One Tor domain's own onion, or "" — the per-domain twin of
        :meth:`onion_url`, whose primary onion serves the mesh's own domain.
        ``domain`` is the domain's name or its key directory name: the readouts are
        keyed by the key directory name, ``core.domain_services.onion_slug`` of the
        name (which leaves a key directory name as it is)."""
        key = (domain or "").strip()
        if not key:
            return ""
        from .domain_services import onion_slug
        urls = self.onion_urls()
        return urls.get(key) or urls.get(onion_slug(key), "")

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
    # here fabricates readiness: a probe that cannot run reports a problem. The env
    # is built with write_overlays=False: identical dict, no write into the
    # generator checkout (the monitor probes on a 10s timer).

    def _probe(self, cmd: list[str], timeout: int = 15) -> tuple[int, str]:
        try:
            r = subprocess.run(cmd, env=self._build_env(write_overlays=False),
                               capture_output=True, text=True, timeout=timeout)
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

    def _m2_check_artifact(self) -> tuple[str, str]:
        """The parent-POM repository path the readiness probe GETs, read out of
        m2-bootstrap.sh's PINS — the ONE place that coordinate is declared.
        Returns ("", why) when the script cannot be read or carries no
        hugmesh-parent pin; the caller default-fails on that, like every other
        probe here, rather than guessing a coordinate.

        The parent POM is the right subject: it is what every service resolves
        first, and it is what the script's own self-check serves."""
        script = os.path.join(self.generator_dir, _M2_BOOTSTRAP_SCRIPT)
        try:
            with open(script, encoding="utf-8") as f:
                src = f.read()
        except OSError as e:
            return "", f"cannot read {_M2_BOOTSTRAP_SCRIPT} ({e})"
        block = _M2_PINS_BLOCK_RE.search(src)
        if not block:
            return "", f"no PINS array in {_M2_BOOTSTRAP_SCRIPT} (shape drift?)"
        for line in block.group(1).splitlines():
            entry = _M2_PIN_ENTRY_RE.match(line.strip())
            if not entry:                      # comments and blank lines
                continue
            fields = entry.group(1).split("|")
            if len(fields) < 6 or fields[2] != _M2_PARENT_ARTIFACT:
                continue
            aid, ver, group = fields[2], fields[3], fields[5]
            return f"{group}/{aid}/{ver}/{aid}-{ver}.pom", ""
        return "", (f"no {_M2_PARENT_ARTIFACT} entry in {_M2_BOOTSTRAP_SCRIPT}'s "
                    f"PINS — cannot build the check-artifact URL")

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
        artifact, why = self._m2_check_artifact()
        if not artifact:
            return False, why
        url = f"{base}/groups/{group}/-/packages/maven/{artifact}"
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
        env = self._build_env(write_overlays=False)   # a preflight READS
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

    def _central_issuer(self) -> str:
        """The CENTRAL Casdoor issuer, mirrored from the Makefile's ENV->issuer
        derivation (prod: https://id.<DOMAIN or hugmesh.net>; test: localhost:8000)
        — the `default` tenant of the multi-issuer registry own_casdoor.tenancy_env
        builds. Mirror-only, like LocalMeshBootstrapConfig.issuer(): the Makefile
        remains the authority for what the stack actually runs with."""
        if self.env == "prod":
            return f"https://id.{self.domain or 'hugmesh.net'}"
        return "http://localhost:8000"

    def _build_env(self, extra_env: dict[str, str] | None = None, *,
                   write_overlays: bool = True) -> dict[str, str]:
        """The EXACT env every `make stack-*` subprocess runs with. The preflight
        checks run against this same dict — a BuildKit/buildx probe in any other
        env (sudo, systemd, a different HOME) would fabricate readiness, because
        the buildx CLI plugin is per-user (~/.docker/cli-plugins).

        ``write_overlays=False`` returns the SAME dict without the three
        generated-overlay writes below (.theme.css, .compose.limits.yaml, the
        own-domains overlay). None of them feeds the dict — the Makefile picks the
        files up by `$(wildcard)` at bring-up time — so the env is byte-identical
        either way; only the side effect on the generator checkout is dropped.

        READ paths must pass it. Before this flag, every ``_probe()`` rewrote the
        limits overlay: with the mesh monitor open that is a write to the
        operator's checkout every 10s, and it writes the FORM's current limits
        under a mesh that may have been started with others. A surface that only
        reads must not edit the tree it is reading."""
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
        # The per-domain onions (#582): passed only for a TOR=1 stack that HAS Tor
        # domains. In every other case the variable is REMOVED rather than set empty:
        # an inherited TOR_ONION_DOMAINS must not mint onions this mesh never chose
        # (the SOCIAL/TOR rule), and a mesh with no Tor domain — TOR=1 or not — keeps
        # exactly the env it had before this existed.
        tor_doms = ""
        if self.with_tor and self.tor_domains:
            from .domain_services import tor_onion_domains_env
            tor_doms = tor_onion_domains_env(self.tor_domains)
        if tor_doms:
            env["TOR_ONION_DOMAINS"] = tor_doms
        else:
            env.pop("TOR_ONION_DOMAINS", None)
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
        # The Makefile's own web-locales default is empty, so an unset value and an
        # empty value mean the same thing: English-only.
        #
        # RENAME PHASE 3c — DUAL WRITE. HUG_WEB_LOCALES is the live name; the retired
        # SNAP_WEB_LOCALES is written alongside it with the SAME value. This Studio is
        # installed separately from the generator tree it drives (generator_dir is a
        # constructor argument, not this package's own root), so the Makefile on the
        # far end of `make stack-up` can be OLDER than this code and read only the old
        # name. Writing just the new one would leave that Makefile seeing "unset",
        # building an English-only image, and exiting 0 with nothing printed — the
        # operator's chosen locales silently dropped. Both names cost two bytes of env
        # and remove that entire direction of skew; phase 4 deletes the mirror once no
        # Makefile in the field reads it.
        if self.web_locales:
            _web_locales = ",".join(self.web_locales)
            env["HUG_WEB_LOCALES"] = _web_locales
            env["SNAP_WEB_LOCALES"] = _web_locales
        # Same only-when-set discipline: compose's ${SNAP_THEME_CSS:-} defaults empty,
        # so unset and empty both mean "shipped default brand" and the unthemed env
        # stays byte-identical to every existing caller.
        if self.login_theme_css.strip():
            # BOTH spellings, and this is the ONE producer where that is worth its
            # keep. HUG_THEME_CSS is the live name (compose declares it; the fleet's
            # 50-snap-theme.sh prefers it). SNAP_THEME_CSS rides along because the
            # Studio is the only theme producer that can VERSION-SKEW from the tree
            # it drives: it ships as an installed application (MSI / Flatpak) and is
            # pointed at a generator checkout by path, so a newer Studio can be asked
            # to bring up an OLDER checkout whose compose still declares only
            # SNAP_THEME_CSS. Without this line that pairing loses the theme silently
            # — the file-persistence path below is best-effort and would be the only
            # thing left carrying it. Same string, already in memory, passed through
            # the process env rather than argv: the cost is one dict entry.
            # (The Makefile does NOT do this — see STACK_THEME_ENV's comment: it
            # cannot skew from its own compose file, so there it would be dead weight.)
            env["HUG_THEME_CSS"] = self.login_theme_css
            env["SNAP_THEME_CSS"] = self.login_theme_css
            # ALSO persist it (tests/stack/.theme.css, gitignored): the env var only
            # covers THIS invocation, so before this write a terminal `make stack-up`
            # (a restore, a rebuild, a peer's bring-up) silently reverted the login
            # page to the shipped brand — the operator's "my theme isn't applied".
            # The Makefile threads the file's text back as HUG_THEME_CSS whenever it
            # exists (STACK_THEME_ENV). Best-effort on purpose: an unwritable file
            # must never block a bring-up, and the env vars above still apply now.
            try:
                theme_file = os.path.join(
                    self.generator_dir, "tests", "stack", ".theme.css")
                if write_overlays:
                    with open(theme_file, "w", encoding="utf-8") as fh:
                        fh.write(self.login_theme_css)
            except OSError:
                pass
        # RESOURCE LIMITS (CPU / memory). Delivered as a generated compose overlay
        # rather than as a flag, because compose expresses limits per service inside
        # the file and there is no `docker compose --cpus`. Written on EVERY
        # bring-up, and REMOVED when limits are off — a stale overlay from a previous
        # run would silently keep throttling a stack the operator has since
        # un-limited. Same mechanism, same gitignored dot-file convention and the
        # same Makefile $(wildcard) include as the own-casdoor overlay above, so a
        # terminal `make stack-up` honours it too.
        #
        # Best-effort: an unwritable overlay must never block a bring-up. The stack
        # then runs unbounded, which is exactly what it did before this feature.
        try:
            if write_overlays:
                limits = resource_limits.effective()
                services = stack_limits.compose_services(
                    os.path.join(self.generator_dir, _COMPOSE_FILE))
                stack_limits.write_overlay(self.generator_dir, limits, services)
        except OSError:
            pass

        # External IdP (I6.6): exported ONLY for an external provider WITH an issuer,
        # so the casdoor default (and a half-configured external) leaves the env
        # byte-identical. Consumed by the Makefile's OIDC env-var contract (landed): the vars
        # map onto CASDOOR_ISSUER_URI / CASDOOR_APP_CLIENT_ID / CASDOOR_JWKS_URI
        # for gateway + BFF token validation (documented in __init__). Values are
        # public endpoints/identifiers — never secrets.
        if self.idp != "casdoor" and self.idp_issuer.strip():
            env["OIDC_ISSUER"] = self.idp_issuer.strip()
            if self.idp_client_id.strip():
                env["OIDC_CLIENT_ID"] = self.idp_client_id.strip()
            if self.idp_jwks.strip():
                env["OIDC_JWKS_URI"] = self.idp_jwks.strip()
        # ── per-domain OWN Casdoor (issue #47) — the local translation of a
        # Domains-table row whose sign-in says 'own'. OWN_CASDOOR is set
        # EXPLICITLY (""=off) like SOCIAL/TOR, so an inherited OWN_CASDOOR=1 in
        # the operator's shell cannot flip a stack the config said nothing
        # about; empty leaves the Makefile's `$(strip …)` profile arm off and
        # everything else untouched (byte-identical default,
        # test_domain_idp_schema.py pins it). Non-empty: export the gateways'
        # multi-issuer registry (the BRAND_B=1 env-var contract, scaled per domain — the
        # central issuer stays tenant `default`) and write the compose overlay
        # the Makefile wildcard-includes. The write is best-effort like
        # .theme.css (never block a bring-up from here); a failed write leaves
        # the wildcard -f empty and the stack comes up single-Casdoor, honest
        # in `docker compose ps` rather than half-wired.
        env["OWN_CASDOOR"] = "1" if self.own_idp_domains else ""
        if self.own_idp_domains:
            env.update(own_casdoor.tenancy_env(
                self.own_idp_domains, self._central_issuer()))
            try:
                if write_overlays:
                    path = own_casdoor.overlay_path(self.generator_dir)
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    with open(path, "w", encoding="utf-8") as fh:
                        fh.write(own_casdoor.compose_overlay(self.own_idp_domains))
            except OSError:
                pass
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
              on_line=None, cancel=None,
              args: Sequence[str] | None = None) -> tuple[bool, str]:
        """Run ``make <target> [args...]``.

        ``args`` is appended to ARGV (never to a shell string) — it exists so a caller
        can pass make VARIABLE ASSIGNMENTS such as ``E2E_SPECS=specs/01-x.spec.ts``.
        A make variable set on the command line overrides the makefile's own default,
        which is the only way to narrow a target without the recipe growing a second
        spelling. It is argv rather than env on purpose: env would work for make, but
        then nothing about the selection would be visible in the process the operator
        (or a test) can actually see. Without ``on_line``/``cancel`` this is the original
        buffered contract (subprocess.run, full output at the end). WITH them it
        STREAMS: merged stdout+stderr line-by-line into ``on_line`` as the build
        runs (what makes an hour-long cold compose build watchable in the GUI), and
        ``cancel`` (a threading.Event-like with .is_set()) terminates the whole
        process GROUP — make's compose/docker children included, which is why the
        child starts in its own session. The returned message is the output TAIL
        (last 400 lines), which is what error reporting actually needs.

        WHY THE THREE `on_line` CALLS BELOW EXIST. The GUI's streaming worker
        deliberately DISCARDS the returned message (it already streamed —
        re-dumping it doubled every milestone in the log). That is right for the
        tail, and wrong for the three sentences this function INVENTS and never
        streams: "make could not be started", "timed out", "cancelled". Without
        them a `make kind-up` that hit DEVOPS_UP_TIMEOUT_S showed a log that
        simply STOPPED and a status bar reading "FAILED (see log)" — with the
        reason nowhere in the log it points at. They are new sentences, not
        replays, so streaming them cannot double anything."""
        env = self._build_env(extra_env)
        argv = ["make", target, *[str(a) for a in (args or ())]]
        if on_line is None and cancel is None:
            try:
                r = subprocess.run(argv, cwd=self.generator_dir, env=env,
                                   capture_output=True, text=True, timeout=timeout)
                return (r.returncode == 0), (r.stderr or r.stdout).strip()
            except (OSError, subprocess.SubprocessError) as e:
                return False, str(e)
        try:
            proc = subprocess.Popen(
                argv, cwd=self.generator_dir, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                # Had errors="replace" but no encoding, so it could not CRASH — it just
                # decoded with the launcher's locale and mojibaked under C/POSIX. Pinning
                # utf-8 is the other half of the same fix. See core/proc_text.
                start_new_session=(os.name == "posix"), **proc_text.TEXT_IO)
        except OSError as e:
            why = f"could not start `make {target}`: {e}"
            if on_line is not None:
                on_line(why)
            return False, why
        tail: collections.deque[str] = collections.deque(maxlen=400)
        deadline = time.monotonic() + timeout
        cancelled = timed_out = False

        def _kill() -> None:
            proc_group.terminate_group(proc)

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
            proc_group.kill_group(proc)
            rc = proc.wait()
        text = "\n".join(tail).strip()
        if cancelled:
            note = "cancelled by operator."
            if on_line is not None:
                on_line(note)
            return False, f"{note}\n{text}"[:8000]
        if timed_out:
            note = (f"timed out after {timeout} s (process group terminated) — "
                    f"`make {target}` was still running.")
            if on_line is not None:
                on_line(note)
            return False, f"{note}\n{text}"[:8000]
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

    def seeded_user(self, username: str) -> tuple[bool | None, str]:
        """Does the running Casdoor hold persona ``username``? A READ-ONLY probe
        (no token minted, nothing written): see _SEED_PROBE_TEMPLATE.

        TRI-STATE on purpose: ``(True, "")`` when Casdoor answered and holds it,
        ``(False, why)`` when Casdoor answered and does NOT, ``(None, why)`` when
        Casdoor did not answer at all (down, port not published). The last is not
        "not seeded" — a caller that rendered it as absent would be asserting
        something about the mesh that nothing established."""
        url = _SEED_PROBE_TEMPLATE.format(
            user=urllib.parse.quote(username, safe="@.-_"))
        try:
            with urllib.request.urlopen(url, timeout=5) as r:  # noqa: S310 - fixed localhost URL
                data = json.load(r)
        except (OSError, ValueError) as e:
            return None, f"Casdoor not answering on localhost:8000 ({e})"
        user = data.get("data") if isinstance(data, dict) else None
        if isinstance(user, dict) and user.get("name") == username:
            return True, ""
        return False, (f"persona '{username}' not in Casdoor — the stack is up "
                       "but unseeded; run `make stack-seed` (the bootstrap's "
                       "bring-up seeds automatically)")

    def e2e_seeded(self) -> tuple[bool, str]:
        """Has `make stack-seed` actually provisioned the e2e personas? The e2e
        gate's yes/no view of :meth:`seeded_user` — "Casdoor did not answer" is
        a blocker for the suite, so it folds to False here (with its reason)."""
        ok, why = self.seeded_user("e2e-admin")
        return bool(ok), why

    def e2e_ready(self, environment: str = "docker") -> list[str]:
        """Every reason the e2e suite cannot run RIGHT NOW (empty = ready) —
        read-only probes only, cheapest first. This one list is BOTH the GUI
        button's enablement and run_e2e()'s fail-fast gate, so they can never
        disagree.

        SCOPED BY ENVIRONMENT (2026-08-26). Everything below the node_modules
        check is a probe of the LOCAL DOCKER MESH: is this compose project up,
        was it started with ENV=test, are its personas seeded. Those questions
        are meaningless for the kind cluster and for an emulated device, and
        answering them anyway would grey the Run button for a mesh the operator
        never selected — the exact dishonesty the tri-state gate exists to
        avoid. For a non-docker environment this returns only the checks that
        still apply, and readiness of the mesh ITSELF is left to the harness,
        which already skips per scenario with a reason naming what to start
        (tests/e2e/steps/world.ts). Two components answering the same question
        is how they come to disagree."""
        from . import e2e_environments as _e2e_env
        env_def = _e2e_env.environment(environment)   # raises on an unknown id
        problems: list[str] = []
        e2e_dir = os.path.join(self.generator_dir, "tests", "e2e")
        if not os.path.isdir(e2e_dir):
            problems.append("tests/e2e not found in this checkout.")
        elif not os.path.isdir(os.path.join(e2e_dir, "node_modules")):
            problems.append("tests/e2e/node_modules missing — run `make "
                            "playwright-deps` once (npm ci + chromium).")
        if env_def.id != "docker":
            # Nothing else here describes this mesh. Say so rather than
            # silently returning a short list that reads like a full check.
            return problems
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
                on_line=None, cancel=None,
                environment: str = "docker",
                specs: Sequence[str] | None = None) -> tuple[bool, str]:
        """`make stack-e2e` — the Playwright suite (tests/e2e) against the
        RUNNING local stack's TLS front door (SNAP_BASE_URL=web_url's port).
        Streams like the other long verbs; Cancel kills the whole process
        group (make + npx + browsers). Afterwards the run's summary.json (the
        hugmesh reporter's DURABLE artifact: passed/failed/skipped) is read
        back and reported as ONE honest counts line — never scraped from the
        scrolling list output; a missing summary is reported as exactly that."""
        from . import e2e_environments as _e2e_env
        # THE ENVIRONMENT CHANNEL. One contract with the terminal: the chosen
        # environment rides as SNAP_ENV on the child's environment, which is
        # exactly what `SNAP_ENV=kind make stack-e2e-bdd-env` sets and what
        # tests/e2e/steps/world.ts reads. Nothing about the choice is encoded in
        # the target or in a config file, so there is no second spelling to
        # drift. plan() also carries the per-environment pins (kind needs the
        # chromium host-resolver rules; qemu's base URL follows the forwarded
        # UI port) — restating those here would be that second spelling.
        try:
            plan = _e2e_env.plan(environment)
        except ValueError as exc:
            return False, str(exc)
        if not plan.runnable:
            return False, "\n".join(plan.refusals)
        problems = self.e2e_ready(environment)
        if problems:
            return False, "\n".join(problems)
        report_rel = os.path.join(
            "test-results", time.strftime("studio-%Y%m%d-%H%M%S"))
        # extra_env bridges the mesh's real superadmin identity
        # (CASDOOR_SUPERADMIN_USERNAME + the minted E2E_SUPERADMIN_PASSWORD)
        # into the suite — without it every superadmin login 401s on a
        # studio-bootstrapped mesh (spec-28 failure, 2026-08-14). Values ride
        # the subprocess env, never argv.
        # plan.env FIRST, then the report dir and the identity bridge. run_env()
        # already refuses to let a bridge dict re-point SNAP_ENV, so a caller
        # cannot make the label say kind while the run drives docker.
        env = dict(plan.env)
        env["SNAP_REPORT_DIR"] = report_rel
        env.update(extra_env or {})
        # THE SELECTION, on its way to argv. `specs` are Playwright positional
        # filters (``specs/NN-x.spec.ts``, cwd tests/e2e) chosen in the feature tree;
        # they ride `make stack-e2e E2E_SPECS=...` so the narrowing is visible in the
        # spawned command rather than hidden in an environment nobody can see.
        # EMPTY MEANS EVERYTHING, and only because no selection was made at all —
        # never as a fallback for a selection that failed to compile: the caller
        # refuses that case before it reaches here.
        accepted, rejected = e2e_catalogue.safe_spec_args(specs or ())
        if rejected:
            return False, ("refusing to run: these selected paths are "
                           + e2e_catalogue.SPEC_ARG_REJECT_REASON + " "
                           + ", ".join(rejected))
        args = [f"E2E_SPECS={' '.join(accepted)}"] if accepted else []
        if accepted and on_line is not None:
            on_line(f"[e2e] running {len(accepted)} selected spec file(s): "
                    + ", ".join(accepted))
        ok, msg = self._make(plan.make_target, timeout=E2E_TIMEOUT_S,
                             extra_env=env, args=args,
                             on_line=on_line, cancel=cancel)
        summary_path = os.path.join(self.generator_dir, "tests", "e2e",
                                    report_rel, "summary.json")
        try:
            with open(summary_path, encoding="utf-8") as fh:
                s = json.load(fh)
            line = (f"[e2e/{plan.environment}] {s.get('passed', 0)} passed, "
                    f"{s.get('failed', 0)} failed, "
                    f"{s.get('skipped', 0)} skipped — summary: {summary_path}")
        except (OSError, ValueError):
            # The environment tag is on THIS line too, not only the happy one:
            # a log whose only result line is "no summary" still has to say
            # which of three meshes the run was pointed at.
            line = (f"[e2e/{plan.environment}] no summary.json written (the run "
                    "ended before the reporter finished) — see the log above.")
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

    def devops_repo_access(self) -> list[str]:
        """Preflight ArgoCD's repo-access condition (issue #48), in the same
        register as devops_available()/e2e_ready(): SHORT actionable lines,
        empty = ready. Surfaced BEFORE `make kind-up` so the operator reads the
        one-line remedy now, not after the bootstrap's 8-minute vault-0 wait —
        the shipped #48 shape was every git-path Application in
        'ComparisonError: authentication required' behind a silent 8 minutes.

        Mirrors bootstrap-kind.sh's ensure_repo_access(): ARGOCD_REPO_TOKEN
        always works; otherwise the DEFAULT tokenless local sync needs (a) this
        checkout to be a full clone (.git directory — a linked worktree's .git
        is a file pointing at an object store the kind mount can't carry) and
        (b) any EXISTING kind cluster to actually SERVE the read-only repo
        mount. A fresh cluster needs nothing — bootstrap-kind.sh mounts and
        serves the checkout automatically.

        "Not serving" has THREE causes with three different remedies, and this
        used to collapse all of them into "delete your cluster":

        * the node DECLARES no bind at KIND_REPO_MOUNT — a cluster from before
          the local-sync path. A bind can only be ADDED at create time, so this
          one really does need the recreate.
        * the node declares a bind, but from a DIFFERENT checkout than the one
          the Studio is driving. Also a recreate, and the message has to name
          the other path or the operator recreates into the same mismatch.
        * the node declares the bind FROM THIS CHECKOUT and still cannot see
          .git — the bind went STALE. Docker resolves a bind's source path when
          the container STARTS, not when it is created (verified 2026-08-21 by
          repointing a symlinked source and restarting: the container picked up
          the new target). So a node that restarted while $HOME was not yet
          mounted — an eCryptfs/LUKS home, an unlocked-on-login home, a
          suspend/resume, a dockerd restart before the user session — is serving
          the empty directory that $HOME shadows, forever, while `docker
          inspect` still shows the right Source. That is a `docker restart
          <node>` away from fixed, and deleting the cluster to fix it is 40
          minutes of rebuild for a 20-second remedy.

        Live shape (2026-08-21): an eCryptfs $HOME, the kind node restarted
        while it was unmounted, and its bind resolved to the btrfs directory the
        eCryptfs mount shadows — 1 entry instead of 44, no .git. `docker
        inspect` still reported the right Source; only the node's view had gone
        wrong. The in-cluster git daemon answered every ArgoCD fetch with "no
        such repository: /hugmesh-generator", so every git-path Application sat
        OutOfSync and nothing about it named a mount."""
        if os.environ.get("ARGOCD_REPO_TOKEN"):
            return []
        proven = self._argocd_repo_fetch_proven()
        if proven:
            # Nothing below applies: this cluster is already fetching the repo
            # with a credential it holds, so the tokenless local sync — and the
            # mount that serves it — are not in the picture at all.
            return []
        git_path = os.path.join(self.generator_dir, ".git")
        if not os.path.isdir(git_path):
            return [f"tokenless local sync unavailable: {git_path} is not a "
                    f"directory (a linked git worktree, or not a clone), so the "
                    f"kind mount would carry no git object store for ArgoCD to "
                    f"fetch — run the Studio against a full clone, or export "
                    f"ARGOCD_REPO_TOKEN=<token with read access to "
                    f"hugmesh-generator> and retry."]
        cluster = _kind_cluster_name()
        kind = devops_tools.which("kind", self.generator_dir)
        if not kind:
            return []  # devops_available() already reports the missing tool
        rc, out = self._probe([kind, "get", "clusters"])
        if rc != 0 or cluster not in out.split():
            return []  # no existing cluster: a fresh one gets the mount automatically
        node = f"{cluster}-control-plane"
        rc, _ = self._probe(["docker", "exec", node,
                             "test", "-d", f"{KIND_REPO_MOUNT}/.git"])
        if rc == 0:
            return []
        token_hint = ("or export ARGOCD_REPO_TOKEN=<token with read access to "
                      "hugmesh-generator>")
        declared = self._kind_repo_bind_source(node)
        if declared and os.path.abspath(declared) == os.path.abspath(self.generator_dir):
            # STALE BIND: declared correctly, serving something else. Restart
            # re-resolves the source; recreating the cluster would too, but it
            # is two orders of magnitude more expensive for the same result.
            return [f"kind cluster '{cluster}' mounts this checkout at "
                    f"{KIND_REPO_MOUNT} but the node cannot see its .git — the "
                    f"bind went STALE. Docker resolves a bind's source when the "
                    f"container STARTS, so a node that restarted before "
                    f"{self.generator_dir} was mounted (encrypted or "
                    f"late-mounted home, suspend/resume, a dockerd restart) is "
                    f"serving the empty directory underneath it. Fix without "
                    f"losing the cluster: `docker restart {node}` (check first "
                    f"that the path is mounted now), then start this lane "
                    f"again — {token_hint}."]
        if declared:
            return [f"kind cluster '{cluster}' mounts a DIFFERENT checkout at "
                    f"{KIND_REPO_MOUNT} ({declared}, not {self.generator_dir}), "
                    f"so ArgoCD would sync someone else's tree. A bind can only "
                    f"be set at CREATE time — `kind delete cluster --name "
                    f"{cluster}` and start this lane again from this checkout, "
                    f"{token_hint}."]
        return [f"existing kind cluster '{cluster}' lacks the read-only repo "
                f"mount ({KIND_REPO_MOUNT}) that the tokenless local sync "
                f"serves ArgoCD from, and the mount can only be added at "
                f"CREATE time — `kind delete cluster --name {cluster}` and "
                f"start this lane again (a fresh cluster mounts it "
                f"automatically), {token_hint}."]

    def _argocd_repo_fetch_proven(self) -> str:
        """The commit ArgoCD has DEMONSTRABLY fetched for the GitOps repo, or "".

        Why this exists (live 2026-08-22). This preflight only ever asked two
        questions — "is ARGOCD_REPO_TOKEN in *this* process's environment?" and
        "is the read-only mount serving?" — and neither is the question that
        matters, which is whether ArgoCD can fetch. A cluster bootstrapped once
        WITH a token keeps a working repository Secret; start the Studio from a
        shell that no longer exports the token and the preflight fell straight
        through to the tokenless branch, found the node's bind had gone stale,
        and BLOCKED the lane while every git-path Application was in fact synced
        to main's HEAD. The remedy it printed (`docker restart` the node) would
        have bounced a healthy 22-hour-old control plane to repair a mount
        nothing in that cluster reads.

        Proven by EVIDENCE, never by the Secret's existence — a stored token
        expires, and reporting "credentialed" over a dead credential would put
        back the exact issue-#48 shape this preflight exists to prevent. Two
        signals, both required: an Application on this repo whose status records
        a RESOLVED commit (what the repo-server actually returned, as opposed to
        the `targetRevision` the spec merely asked for), and no Application
        carrying #48's authentication ComparisonError. Evidence also gets right
        the case a credential check inverts: an anonymously readable repo
        fetches with no Secret at all.

        A cluster with no Applications yields no evidence and returns "" — so a
        FIRST bootstrap still takes the tokenless path exactly as before. This
        can only relax a re-run, never weaken a bring-up. Mirrors
        bootstrap-kind.sh's argocd_repo_fetch_proven()."""
        kubectl = devops_tools.which("kubectl", self.generator_dir)
        if not kubectl:
            return ""  # devops_available() already reports the missing tool
        ctx = ["--context", f"kind-{_kind_cluster_name()}", "-n", ARGOCD_NS]
        rc, out = self._probe([kubectl] + ctx + [
            "get", "applications", "--no-headers", "-o",
            "custom-columns=REPO:.spec.source.repoURL,REV:.status.sync.revision"])
        if rc != 0 or not out:
            return ""
        rev = ""
        for line in out.split("\n"):
            parts = line.split()
            if len(parts) != 2 or parts[0] != GITOPS_REPO_URL:
                continue
            # A resolved commit: hex and long enough to be one. kubectl's
            # empty-field marker "<none>" and a branch name both fail this.
            cand = parts[1]
            if len(cand) >= 7 and all(c in "0123456789abcdef" for c in cand):
                rev = cand
                break
        if not rev:
            return ""
        rc, msgs = self._probe([kubectl] + ctx + [
            "get", "applications", "--no-headers", "-o",
            "custom-columns=MSG:.status.conditions[*].message"])
        if rc == 0 and "authentication required" in msgs.lower():
            return ""
        return rev

    def _kind_repo_bind_source(self, node: str) -> str:
        """The HOST path the kind node declares as its repo bind, or "" when it
        declares none (or cannot be inspected).

        Read from `docker inspect`, deliberately NOT from inside the container:
        the whole point is to tell "no bind was ever configured" apart from "the
        bind is configured and resolving to the wrong tree", and only the host
        side of the mount table can answer the first question."""
        fmt = ('{{range .Mounts}}{{if eq .Destination "' + KIND_REPO_MOUNT +
               '"}}{{.Source}}{{end}}{{end}}')
        rc, out = self._probe(["docker", "inspect", node, "--format", fmt])
        return out.strip() if rc == 0 else ""

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
            # Streamed for the same reason the repo-access block below is: the
            # GUI worker drops a streaming verb's return value, so a reason that
            # is only returned is a reason the operator never sees.
            if on_line:
                for p in problems:
                    on_line(f"[devops] {p}")
            return False, "\n".join(problems)
        # Repo-access preflight (issue #48) BEFORE the long verb: bootstrap-kind.sh
        # itself now fails closed on this condition, but only after cluster-create
        # + the ArgoCD install; the operator deserves the one-line remedy up front
        # instead of at the far end of an 8-minute wait.
        repo_problems = self.devops_repo_access()
        if repo_problems:
            if on_line:
                for p in repo_problems:
                    on_line(f"[devops] {p}")
            return False, "\n".join(repo_problems)
        if on_line:
            # Name WHICH of the three modes this run is in. Printing "tokenless
            # local sync" for a cluster fetching from GitHub is how the log came
            # to describe a daemon that was not in the picture.
            if os.environ.get("ARGOCD_REPO_TOKEN"):
                mode = "ARGOCD_REPO_TOKEN is set — ArgoCD will sync from GitHub."
            else:
                proven = self._argocd_repo_fetch_proven()
                mode = (f"this cluster already fetches {GITOPS_REPO_URL} with the "
                        f"credential it holds (an Application is synced at "
                        f"{proven[:10]}) — nothing to register." if proven else
                        "tokenless local sync — ArgoCD will sync this checkout's "
                        "last commit (committed objects only; a dirty tree serves "
                        "stale-but-consistent HEAD).")
            on_line("[devops] repo access preflight OK: " + mode)
        # The add-on selection is validated BEFORE the long verb, and streamed,
        # for the same reason the two preflights above are: the GUI's streaming
        # worker drops a returned message, so a reason that is only returned is a
        # reason the operator never sees. bootstrap-kind.sh refuses an unknown slug
        # too — but only after cluster-create and the ArgoCD install.
        addon_problems = validate_kind_addons(self.kind_addons)
        if addon_problems:
            if on_line:
                for p in addon_problems:
                    on_line(f"[devops] {p}")
            return False, "\n".join(addon_problems)
        addon_env = kind_addon_env(self.kind_addons)
        if on_line:
            # Say WHICH infra add-ons this run applies, and say it from the value
            # actually being exported rather than from the picker — a log that
            # describes the selection instead of the env is how a threading bug
            # stays invisible. Empty env = the lane's shipped default.
            on_line("[devops] infra add-ons: "
                    + (addon_env[KIND_ADDONS_ENV]
                       if KIND_ADDONS_ENV in addon_env else
                       "%s (lane default)" % (",".join(kind_addon_default_selection())
                                              or KIND_ADDONS_NONE)))
        # extra_env is the wire that was missing: _make has always ACCEPTED it and
        # this call has always passed None, so nothing the Studio knew about a kind
        # bring-up could reach bootstrap-kind.sh.
        return self._make("kind-up", timeout=DEVOPS_UP_TIMEOUT_S,
                          extra_env=addon_env,
                          on_line=on_line, cancel=cancel)

    def devops_running(self) -> bool:
        """Does this mesh's kind cluster exist RIGHT NOW? Read-only (`kind get
        clusters`, the same question devops_repo_access() already asks) so a caller
        can tell "the lane is already down" from "it has to come down first" without
        firing the destructive verb without checking first.

        False whenever the answer cannot be established — kind not installed, the
        probe failing — because a cluster this lane created cannot exist without the
        binary that creates it, and an unestablished reason must never be reported as
        a running cluster (the same tri-state rule the e2e gate follows: unknown is
        rendered as unknown, never as a blocker)."""
        kind = devops_tools.which("kind", self.generator_dir)
        if not kind:
            return False
        rc, out = self._probe([kind, "get", "clusters"])
        return rc == 0 and _kind_cluster_name() in out.split()

    def devops_down(self, on_line=None, cancel=None) -> tuple[bool, str]:
        """`make kind-down` — delete the local Kubernetes cluster. Destructive for
        the DevOps lane ONLY: the docker mesh and its volumes are untouched."""
        return self._make("kind-down", timeout=600,
                          on_line=on_line, cancel=cancel)

    def devops_halt(self, on_line=None, cancel=None) -> tuple[bool, str]:
        """`make kind-halt` — STOP the DevOps lane without destroying it.

        Deliberately NOT `kind-down`, exactly as ``stop()`` below is deliberately not
        ``clean()``: "stop my lane" must not mean "destroy my lane". The kind lane had
        only the destructive half until #356, and `kind` itself has no pause verb — so
        the halt scales the mesh's Deployments and StatefulSets to 0 AND suspends
        ArgoCD auto-sync. Both, because either alone is dishonest: 98 of 98 files in
        specs/cluster/apps carry ``syncPolicy.automated {prune, selfHeal}``, so a
        scale-only halt is undone by selfHeal within a reconcile, and a suspend with no
        resume leaves the cluster silently no longer tracking git.

        The cluster, its PVCs, its Vault KV and its Casdoor identities are all KEPT.
        Streams, because it names every Application it suspends and the sync/health
        state each was in when it froze — that list is the output's whole point."""
        return self._make("kind-halt", timeout=900,
                          on_line=on_line, cancel=cancel)

    def devops_resume(self, on_line=None, cancel=None) -> tuple[bool, str]:
        """`make kind-resume` — undo ``devops_halt``, restoring EXACTLY what it
        recorded: the replica counts it zeroed and the auto-sync it suspended. Never
        "everything" — an Application suspended before the halt (someone debugging it)
        was never the halt's to touch and stays suspended. The record lives in a
        ConfigMap inside the cluster, so this works whether or not the Studio that
        pressed Halt is still running."""
        return self._make("kind-resume", timeout=900,
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
