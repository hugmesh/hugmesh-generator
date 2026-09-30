"""FleetConfig + FleetDriver — the multi-role fan-out channel (G39), Qt-free.

Fronts ``scripts/build-all-roles.sh`` — the menu's build-all / build-everything /
rpi / x86 fleet targets — whose whole option surface is ENV KNOBS (X86_OMNIBUS=1,
RPI_ROLES="…", FRITE=1, PENTEST=1, …) plus a small pass-through argv tail the
script forwards to every per-role builder (-w/-j/--env/--config/--cluster-domain).

Same contracts as BuildDriver: identical config -> identical command on every
host; env passthrough rides an ``env K=V`` wrapper INSIDE the sudo boundary on
the native leg and ``docker -e`` on the docker leg (the G2 HEADSCALE_URL channel,
generalized); ``run()``/``cancel()``/streaming are inherited from BuildDriver.
Per-role KEYS folder generation (gen-provision-keys.sh) is the script's own
default behaviour — SKIP_KEYS=1 is the opt-out knob, fielded below.

DOMAINS (#587). A fleet builds a mesh's node images, and the operator's rule is "a
service page per domain you make, that you have to go through before building" — so a
fleet run now carries the SAME domain rows and the SAME per-domain services gate as
every other build route (``core.domain_services.gate_reason``, called from
:meth:`FleetDriver.preflight`, so both the GUI's "Build fleet now" and a RESTART from
the previous-builds manager refuse before ``build-all-roles.sh`` is ever spawned, and
name every domain that was never walked). Row 0 is the fleet's OWN domain — the
``--cluster-domain`` it passes, or the builders' default — and has a services page
too (operator decision 69 = A).

What the rows DO NOT do, measured on the builders rather than assumed: they reach no
builder. ``FleetConfig.to_env`` / ``to_cli_args`` emit nothing for them, on purpose —
the pass-through tail goes to EVERY builder of the run, node roles ignore
``--domains`` (build-x86-host-stage4.sh warns "--person-role/--domains are ignored for
non-client role"), and the unaffiliated desktop that ``X86_STANDALONE=1`` adds REFUSES
it outright (``--unaffiliated conflicts with --person-role/--domains``, exit 1). And
``build-all-roles.sh`` writes no mesh manifest, so cluster provisioning does not see a
fleet's rows either. They are RECORDED with the fleet's session record
(``to_dict``), gated, and said to be exactly that on both faces
(:data:`FLEET_LANE_NOTE`).
"""
from __future__ import annotations

import os
import re
import shlex
from dataclasses import asdict, dataclass, field, fields
from typing import Any, ClassVar

from . import build_driver
from .build_driver import BuildDriver
from .config import Domain, IdentityValidationError, ImageConfig, validate_domain_name
from .domain_services import gate_reason
from .local_mesh_domains import LocalMeshDomains

FLEET_SCRIPT = "scripts/build-all-roles.sh"

# role-set tokens ride env vars that build-all-roles.sh word-splits into builder
# argv — allow only slug-shaped tokens (matches every real role id incl. be+gpu),
# fail-closed like ImageConfig.validate_identity().
_ROLE_TOKEN_RE = re.compile(r"[A-Za-z0-9_+.-]+\Z")

#: The builders' own cluster domain when no ``--cluster-domain`` is passed (x86 and
#: rpi5 ``CLUSTER_DOMAIN=`` default; ImageConfig carries the same literal). A fleet
#: whose Cluster domain field is empty builds for THIS domain, so it is row 0.
#: studio/tests/test_fleet_domains.py pins it against both builders.
FLEET_DEFAULT_DOMAIN: str = ImageConfig.__dataclass_fields__["cluster_domain"].default

#: What the fleet's gate refusal says was refused (``gate_reason``'s ``action``).
ACTION_FLEET_BUILD = "build this fleet"

#: The fleet's remedy: this route has its OWN Domains / Domain services steps, so the
#: image flow's sentence ("walk to the Domain services step of the image flow") would
#: send the operator to a screen this window does not have.
FLEET_REMEDY = (
    "Go back to this fleet's ‘Domains’ and ‘Domain services’ steps — every domain "
    "there has its own service page, and opening it is what records it — or remove "
    "the domain from the Domains table.")

#: The one sentence the fleet's services step adds (both faces; parity-pinned): what
#: this route does with the selection, which is less than the image flow does.
FLEET_LANE_NOTE = (
    "ON A FLEET BUILD: the domains and their per-domain services are recorded with "
    "this fleet's session and required before it builds — they reach NO builder "
    "(node images take no --domains, the unaffiliated desktop refuses it, and "
    "build-all-roles.sh writes no mesh manifest). The node services a fleet DOES bake "
    "— the Tor onion (WITH_TOR) and the optional-service list — are set on the "
    "‘Shared options’ step.")


def fleet_own_domain(cluster_domain: str) -> str:
    """Row 0's name: the ``--cluster-domain`` the fleet passes, else the builders'
    default (what the images are really built for)."""
    return (cluster_domain or "").strip() or FLEET_DEFAULT_DOMAIN


class FleetDomains(LocalMeshDomains):
    """The fleet's domain rows + the gate's bookkeeping, while the steps edit them —
    the local-mesh route's state object, re-used as is (``mode`` = "mesh" so
    ``domain_services.gate_applies`` bites; row 0 is a REAL row named ``own_name``).
    A distinct name only so a reader of either route knows which one it is."""


def seed_fleet_domains(state: FleetDomains, cluster_domain: str) -> None:
    """Enter the Domains step: row 0 becomes the fleet's own domain. First visit seeds
    it; a later visit after the Cluster domain changed RENAMES row 0 (keeping every
    added row) and prunes the stale reviewed marker — a renamed domain is one nobody
    has walked under that name. Both faces call this."""
    from .domain_services import record_reviewed
    own = fleet_own_domain(cluster_domain)
    if not state.domains:
        state.domains = [Domain(name=own, title="")]
    elif state.own_name != own:
        row = state.by_name(state.own_name)
        if row is not None and row is state.domains[0]:
            row.name = own
        else:
            state.domains.insert(0, Domain(name=own, title=""))
    state.own_name = own
    record_reviewed(state, state.domain_services_reviewed)


def commit_fleet_domains(state: FleetDomains, added) -> list[str]:
    """Leave the Domains step: ``added`` (the table's ADDED rows, row 0 excluded)
    become the state's rows after the own row, which keeps its recorded services;
    reviewed markers are pruned to rows that still exist. Returns why the added rows
    cannot be recorded ([] when they can) — the local-mesh route's words
    (``added_row_problems``: not a domain name / the own domain again / a duplicate).
    The rows are recorded EITHER WAY, so a Back keeps what was typed; the refusal is
    the caller's (on Next, inline). Both faces call this."""
    from .domain_services import record_reviewed
    from .local_mesh_domains import added_row_problems
    own = state.own_name
    prev = state.by_name(own) if own else None
    own_row = Domain(name=own, title="",
                     optional_services=list(prev.optional_services) if prev else [])
    added = [d for d in added if (d.name or "").strip()]
    state.domains = [own_row] + added
    record_reviewed(state, state.domain_services_reviewed)
    return added_row_problems([d.name for d in added], own)


def fleet_domain_fields(state: FleetDomains) -> dict[str, Any]:
    """The FleetConfig fields the steps' state becomes — COPIES (the config is recorded
    with the session while the state keeps being edited after a Back). Both faces
    build their FleetConfig through this, so they record identical rows."""
    return {
        "domains": [Domain(**asdict(d)) for d in state.domains],
        "domain_services_reviewed": list(state.domain_services_reviewed),
    }


def fleet_gate_reason(cfg: "FleetConfig") -> str:
    """The per-domain services gate for a fleet ("" = may build): the shared seam
    with this route's action and remedy. ``FleetDriver.preflight`` and the TUI's
    review both call exactly this."""
    return gate_reason(cfg, ACTION_FLEET_BUILD, remedy=FLEET_REMEDY)


def fleet_domains_from_config(cfg: "FleetConfig") -> FleetDomains:
    """The step state a recorded FleetConfig carries (RESTART / REDO): its rows, row 0
    first, and its reviewed markers as recorded — never "every row", so a record whose
    walk was incomplete is still refused."""
    rows = [Domain(**asdict(d)) for d in cfg.domains]
    own = (rows[0].name or "").strip() if rows else ""
    return FleetDomains(domains=rows,
                        domain_services_reviewed=list(cfg.domain_services_reviewed),
                        own_name=own)


@dataclass
class FleetConfig:
    """One fleet run = which role sets to build + the shared pass-through args.

    Field -> env-var mapping is 1:1 with scripts/build-all-roles.sh's documented
    knob surface (its header comment); "" / False = leave the script's default.
    """
    # ── x86 role set ──
    skip_x86: bool = False             # SKIP_X86=1 (Pi/ARM-only run)
    x86_omnibus: bool = False          # X86_OMNIBUS=1 append the all-in-one role
    x86_all: bool = False              # X86_ALL=1 every x86 role incl. omnibus
    x86_roles: str = ""                # X86_ROLES="pki omnibus" explicit subset
    x86_standalone: bool = False       # X86_STANDALONE=1 append the standalone desktops
    x86_standalone_only: bool = False  # X86_STANDALONE_ONLY=1 only the standalone desktops
    # ── rpi5 role set ──
    skip_rpi: bool = False             # SKIP_RPI=1 (x86/ARM-client-only run)
    rpi_roles: str = ""                # RPI_ROLES="pki backend frontend desktop"
    rpi_board: str = ""                # RPI_BOARD=rpi5|rpi4|rpi3 ("" = rpi5)
    # ── opt-in ARM client/edge platforms (each mirrors the FRITE knob family) ──
    frite: bool = False                # FRITE=1
    frite_only: bool = False           # FRITE_ONLY=1
    frite_board: str = ""              # FRITE_BOARD
    frite_flavor: str = ""             # FRITE_FLAVOR
    frite_desktop: str = ""            # FRITE_DESKTOP light|none
    jetson: bool = False               # JETSON=1
    jetson_only: bool = False          # JETSON_ONLY=1
    jetson_roles: str = ""             # JETSON_ROLES="edge_ai desktop"
    jetson_board: str = ""             # JETSON_BOARD
    jetson_kernel_flavor: str = ""     # JETSON_KERNEL_FLAVOR mainline|l4t
    orangepi5: bool = False            # ORANGEPI5=1
    orangepi5_only: bool = False       # ORANGEPI5_ONLY=1
    orangepi5_board: str = ""          # ORANGEPI5_BOARD
    orangepi5_flavor: str = ""         # ORANGEPI5_FLAVOR
    orangepizero2: bool = False        # ORANGEPIZERO2=1
    orangepizero2_only: bool = False   # ORANGEPIZERO2_ONLY=1
    orangepizero2_flavor: str = ""     # ORANGEPIZERO2_FLAVOR
    orangepizero2w: bool = False       # ORANGEPIZERO2W=1
    orangepizero2w_only: bool = False  # ORANGEPIZERO2W_ONLY=1
    orangepizero2w_flavor: str = ""    # ORANGEPIZERO2W_FLAVOR
    orangepizero3: bool = False       # ORANGEPIZERO3=1
    orangepizero3_only: bool = False  # ORANGEPIZERO3_ONLY=1
    orangepizero3_flavor: str = ""    # ORANGEPIZERO3_FLAVOR
    orangepi3lts: bool = False        # ORANGEPI3LTS=1
    orangepi3lts_only: bool = False   # ORANGEPI3LTS_ONLY=1
    orangepi3lts_flavor: str = ""     # ORANGEPI3LTS_FLAVOR
    orangepi4lts: bool = False        # ORANGEPI4LTS=1
    orangepi4lts_only: bool = False   # ORANGEPI4LTS_ONLY=1
    orangepi4lts_flavor: str = ""     # ORANGEPI4LTS_FLAVOR
    # ── per-role KEYS folders + pen-test harness ──
    skip_keys: bool = False            # SKIP_KEYS=1 (keys folders are the default)
    pentest: bool = False              # PENTEST=1 run the OWASP harness after the build
    pentest_only: bool = False         # PENTEST_ONLY=1 pen-test only, no image builds
    pentest_env: str = ""              # PENTEST_ENV compose|local|cluster
    pentest_scan: str = ""             # PENTEST_SCAN baseline|full
    pentest_pipeline: str = ""         # PENTEST_PIPELINE main|games
    # ── node services (#579) ──
    # WITH_TOR=1: every CLUSTER-NODE image of the run carries the Tor v3 onion
    # (net-vpn/tor + hugmesh-tor-reconcile). The script emits it per builder through
    # the channel that builder parses — x86 --with-tor, rpi5 'tor' folded into its
    # --optional-services — and nowhere a builder cannot bake it; it REFUSES (exit 2,
    # before any build) where it cannot be honoured exactly. Not an extra_flags
    # string: a pass-through --with-tor would reach builders that have no such flag.
    with_tor: bool = False             # WITH_TOR=1
    optional_services: str = ""        # OPTIONAL_SERVICES="akkoma tuwunel ..." (both node
                                       # builders' env knob; the rpi5 tor fold's base)
    # ── domains (#587) — RECORDED + GATED, never emitted (see the module doc) ──
    # Row 0 is the fleet's own domain; ``domain_services_reviewed`` is the gate's
    # bookkeeping (the names whose services page was walked). ``mode`` is a CLASS
    # constant, not a field: ``domain_services.gate_applies`` reads it, and "mesh" is
    # the honest answer — a fleet builds a mesh's nodes.
    domains: list[Domain] = field(default_factory=list)
    domain_services_reviewed: list[str] = field(default_factory=list)
    mode: ClassVar[str] = "mesh"
    # ── brand mesh (the same env channel BuildDriver forwards for G2) ──
    headscale_url: str = ""            # HEADSCALE_URL baked by the x86/rpi5/frite builders
    # ── pass-through builder args (forwarded to EVERY per-role builder) ──
    env: str = ""                      # --env test|prod ("" = the builders' default test)
    brand_profile: str = ""            # --config brands/*.conf
    cluster_domain: str = ""           # --cluster-domain
    output_dir: str = ""               # -w ("" = <generator>/out)
    jobs: int = 8                      # -j
    extra_flags: str = ""              # escape hatch — shlex-split, appended verbatim

    # ---- (de)serialization (no SECRET fields in a fleet config) --------------
    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "FleetConfig":
        # fields(), not __dataclass_fields__: the latter also lists the ``mode``
        # ClassVar, which is not an __init__ argument.
        known = {f.name for f in fields(cls)}
        kw = {k: v for k, v in d.items() if k in known}
        # REHYDRATE the rows. asdict() -> JSON -> back yields plain dicts, and the
        # gate reads ``getattr(d, "name", "")`` — "" on a dict — so an un-rehydrated
        # record would pass the gate on every RESTART/REDO however unwalked it was.
        kw["domains"] = [ImageConfig._domain_from_dict(x) if isinstance(x, dict) else x
                         for x in (kw.get("domains") or [])]
        kw["domain_services_reviewed"] = [
            str(n) for n in (kw.get("domain_services_reviewed") or [])]
        return cls(**kw)

    def _services_words(self) -> str:
        """``optional_services`` as the builders read it: commas tolerated as
        separators (both node builders normalise ``,`` to a space), whitespace
        collapsed."""
        return " ".join(self.optional_services.replace(",", " ").split())

    # ---- validation (fail-closed, mirrors ImageConfig.validate_identity) -----
    def validate(self) -> None:
        if self.cluster_domain:
            validate_domain_name(self.cluster_domain)
        for d in self.domains:
            if (d.name or "").strip():
                validate_domain_name(d.name.strip())
        for name, roleset in (("x86_roles", self.x86_roles),
                              ("rpi_roles", self.rpi_roles),
                              ("jetson_roles", self.jetson_roles),
                              ("optional_services", self._services_words())):
            for tok in roleset.split():
                if not _ROLE_TOKEN_RE.match(tok):
                    raise IdentityValidationError(
                        f"invalid {name} token: {tok!r} — rejected by the fleet allowlist")

    # ---- the canonical env-knob + argv translation ---------------------------
    def to_env(self) -> dict[str, str]:
        """The X*=1 / *_ROLES / board/flavor env knobs, only where they differ
        from the script's own defaults (same only-non-defaults rule as
        ImageConfig.to_cli_args, so the command stays readable)."""
        self.validate()
        env: dict[str, str] = {}
        for var, val in (
            ("SKIP_X86", self.skip_x86), ("X86_OMNIBUS", self.x86_omnibus),
            ("X86_ALL", self.x86_all), ("X86_STANDALONE", self.x86_standalone),
            ("X86_STANDALONE_ONLY", self.x86_standalone_only),
            ("SKIP_RPI", self.skip_rpi),
            ("FRITE", self.frite), ("FRITE_ONLY", self.frite_only),
            ("JETSON", self.jetson), ("JETSON_ONLY", self.jetson_only),
            ("ORANGEPI5", self.orangepi5), ("ORANGEPI5_ONLY", self.orangepi5_only),
            ("ORANGEPIZERO2", self.orangepizero2),
            ("ORANGEPIZERO2_ONLY", self.orangepizero2_only),
            ("ORANGEPIZERO2W", self.orangepizero2w),
            ("ORANGEPIZERO2W_ONLY", self.orangepizero2w_only),
            ("ORANGEPIZERO3", self.orangepizero3),
            ("ORANGEPIZERO3_ONLY", self.orangepizero3_only),
            ("ORANGEPI3LTS", self.orangepi3lts),
            ("ORANGEPI3LTS_ONLY", self.orangepi3lts_only),
            ("ORANGEPI4LTS", self.orangepi4lts),
            ("ORANGEPI4LTS_ONLY", self.orangepi4lts_only),
            ("SKIP_KEYS", self.skip_keys),
            ("PENTEST", self.pentest), ("PENTEST_ONLY", self.pentest_only),
            ("WITH_TOR", self.with_tor),
        ):
            if val:
                env[var] = "1"
        for var, val in (
            ("X86_ROLES", self.x86_roles), ("RPI_ROLES", self.rpi_roles),
            ("RPI_BOARD", self.rpi_board),
            ("FRITE_BOARD", self.frite_board), ("FRITE_FLAVOR", self.frite_flavor),
            ("FRITE_DESKTOP", self.frite_desktop),
            ("JETSON_ROLES", self.jetson_roles), ("JETSON_BOARD", self.jetson_board),
            ("JETSON_KERNEL_FLAVOR", self.jetson_kernel_flavor),
            ("ORANGEPI5_BOARD", self.orangepi5_board),
            ("ORANGEPI5_FLAVOR", self.orangepi5_flavor),
            ("ORANGEPIZERO2_FLAVOR", self.orangepizero2_flavor),
            ("ORANGEPIZERO2W_FLAVOR", self.orangepizero2w_flavor),
            ("ORANGEPIZERO3_FLAVOR", self.orangepizero3_flavor),
            ("ORANGEPI3LTS_FLAVOR", self.orangepi3lts_flavor),
            ("ORANGEPI4LTS_FLAVOR", self.orangepi4lts_flavor),
            ("PENTEST_ENV", self.pentest_env), ("PENTEST_SCAN", self.pentest_scan),
            ("PENTEST_PIPELINE", self.pentest_pipeline),
            ("HEADSCALE_URL", self.headscale_url),
            ("OPTIONAL_SERVICES", self._services_words()),
        ):
            if val:
                env[var] = val
        return env

    def to_cli_args(self) -> list[str]:
        """The pass-through tail build-all-roles.sh forwards to every builder."""
        self.validate()
        a: list[str] = []
        if self.env:
            a += ["--env", self.env]
        if self.brand_profile:
            a += ["--config", self.brand_profile]
        if self.cluster_domain:
            a += ["--cluster-domain", self.cluster_domain]
        if self.extra_flags:
            a += shlex.split(self.extra_flags)
        return a


class FleetDriver(BuildDriver):
    """BuildDriver for a FleetConfig: same backends, same streaming/cancel, but
    the target is scripts/build-all-roles.sh and the options ride env knobs."""

    def command(self, cfg: FleetConfig, backend: str | None = None) -> list[str]:  # type: ignore[override]
        backend = backend or self.host.default_backend
        # self.workdir: the same runtime per-session override BuildDriver.command
        # honours (#357) — set by the GUI at dispatch, NEVER written into the
        # FleetConfig, default None, so command(cfg) without an override stays
        # byte-identical. run()/command_string() both call command(), so the
        # override flows through dispatch, preview and preflight for free.
        out = self.workdir or cfg.output_dir or os.path.join(self.generator_dir, "out")
        penv = cfg.to_env()
        inner = [f"./{FLEET_SCRIPT}", "-w", "/out" if backend == "docker" else out,
                 "-j", str(cfg.jobs), *cfg.to_cli_args()]
        if backend == "native":
            # env wrapper INSIDE the sudo boundary (sudo env_reset), same as G2
            env_wrap = ["env", *(f"{k}={v}" for k, v in penv.items())] if penv else []
            return ((["sudo"] if not self.host.is_root else [])
                    + env_wrap + ["bash", *inner])
        if backend == "docker":
            env_args: list[str] = []
            for k, v in penv.items():
                env_args += ["-e", f"{k}={v}"]
            return [
                "docker", "run", "--rm", "--privileged",
                # THE lane the 2026-07-15 host freeze came from — a fleet build, in an
                # unbounded container, on a desktop that was also being used. It was
                # also the only lane with no cap at all: BuildDriver capped memory for
                # single images and this one inherited nothing. Same wrapper, same
                # knobs, same byte-identical argv when limits are off.
                *build_driver.docker_limit_args(),
                "-v", f"{self.generator_dir}:/src",
                "-v", f"{out}:/out",
                *env_args,
                "-w", "/src", self.host.builder_image,
                "bash", "-c", shlex.join(inner),
            ]
        raise RuntimeError("no usable build backend (need Gentoo native or Docker)")

    def preflight(self, cfg: FleetConfig, backend: str | None = None) -> list[str]:  # type: ignore[override]
        backend = backend or self.host.default_backend
        problems: list[str] = []
        if backend == "none":
            problems.append("No build backend: install Docker (any OS) or run on a Gentoo host.")
        if not os.path.exists(os.path.join(self.generator_dir, FLEET_SCRIPT)):
            problems.append(f"fleet script {FLEET_SCRIPT} not found in {self.generator_dir}")
        if backend == "docker" and not self.host.has_docker:
            problems.append("Docker selected but the Docker daemon is not reachable.")
        elif backend == "docker" and not self._image_present():
            problems.append(
                f"Docker builder image '{self.host.builder_image}' not found — build it "
                f"first: {' '.join(self.builder_image_build_command())}")
        if backend == "native" and not self.host.is_root:
            problems.append("Native build needs root (the Studio will prepend sudo).")
        if cfg.brand_profile and not os.path.exists(
                os.path.join(self.generator_dir, cfg.brand_profile)
                if not os.path.isabs(cfg.brand_profile) else cfg.brand_profile):
            problems.append(f"brand-profile path does not exist: {cfg.brand_profile}")
        try:
            cfg.validate()
        except IdentityValidationError as e:
            problems.append(str(e))
        # THE PER-DOMAIN SERVICES GATE (#587) — the same seam every other build route
        # calls. Here, so "Build fleet now" (FleetPage._start refuses on any preflight
        # problem, inline) and a previous-builds RESTART both refuse BEFORE
        # build-all-roles.sh is spawned, naming each unwalked domain.
        reason = fleet_gate_reason(cfg)
        if reason:
            problems.append(reason)
        return problems
