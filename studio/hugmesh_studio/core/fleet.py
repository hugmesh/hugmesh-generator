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
"""
from __future__ import annotations

import os
import re
import shlex
from dataclasses import asdict, dataclass, field  # noqa: F401  (field: dataclass idiom parity)
from typing import Any

from . import build_driver
from .build_driver import BuildDriver
from .config import IdentityValidationError, validate_domain_name

FLEET_SCRIPT = "scripts/build-all-roles.sh"

# role-set tokens ride env vars that build-all-roles.sh word-splits into builder
# argv — allow only slug-shaped tokens (matches every real role id incl. be+gpu),
# fail-closed like ImageConfig.validate_identity().
_ROLE_TOKEN_RE = re.compile(r"[A-Za-z0-9_+.-]+\Z")


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
        known = set(cls.__dataclass_fields__)  # type: ignore[attr-defined]
        return cls(**{k: v for k, v in d.items() if k in known})

    def _services_words(self) -> str:
        """``optional_services`` as the builders read it: commas tolerated as
        separators (both node builders normalise ``,`` to a space), whitespace
        collapsed."""
        return " ".join(self.optional_services.replace(",", " ").split())

    # ---- validation (fail-closed, mirrors ImageConfig.validate_identity) -----
    def validate(self) -> None:
        if self.cluster_domain:
            validate_domain_name(self.cluster_domain)
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
        return problems
