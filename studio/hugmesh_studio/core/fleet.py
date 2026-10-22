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
from dataclasses import MISSING, asdict, dataclass, field, fields
from typing import Any, ClassVar

from . import build_driver
from .build_driver import BuildDriver
from .config import (Domain, IdentityValidationError, ImageConfig,
                     domain_rows_to_dict, validate_domain_name)
from .domain_services import gate_reason
from .local_mesh_domains import LocalMeshDomains

FLEET_SCRIPT = "scripts/build-all-roles.sh"

# role-set tokens ride env vars that build-all-roles.sh word-splits into builder
# argv — allow only slug-shaped tokens (matches every real role id incl. be+gpu),
# fail-closed like ImageConfig.validate_identity().
_ROLE_TOKEN_RE = re.compile(r"[A-Za-z0-9_+.-]+\Z")

#: ``-j`` on both faces: the GUI's spin box range and what ``validate`` accepts from
#: the TUI's ``set jobs N`` (which used to take 0 and -5 straight into the command).
JOBS_RANGE: tuple[int, int] = (1, 128)

#: What WITH_TOR does per builder — the note under the GUI's Tor checkbox and the
#: line the TUI's options screen prints for the ``with_tor`` knob (both faces, one
#: string; parity-pinned). It is NOT on the checkbox itself: a QCheckBox never
#: wraps, and this sentence on it made the fleet window 825 px wide at its 760 px
#: default (the post-merge review of #645).
WITH_TOR_NOTE = (
    "Sent per builder through the channel it parses — x86 --with-tor, rpi5 ‘tor’ "
    "folded into --optional-services. Client roles never carry it; build-all-roles.sh "
    "refuses (exit 2, before any build) where a builder cannot bake it exactly.")

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
    build their FleetConfig through this, so they record the same domains, in the same
    order, with the same services and reviewed markers. (One difference is left, and
    is the one the text-mode ``a NAME`` always had: the GUI's table fills an empty
    title with the domain's name, ``a NAME`` leaves it empty — as the local-mesh
    route's does. A fleet build reads names only, so nothing built changes.)"""
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
    # ORANGEPI5_ROLES ("" = the script default, desktop): may name the cluster node
    # roles pki/backend/frontend/omnibus (EXPERIMENTAL, installer flavor only).
    orangepi5_roles: str = ""
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
    # ORANGEPI4LTS_ROLES ("" = desktop): may name frontend, its only node role.
    orangepi4lts_roles: str = ""
    # RAM_GB: GB of RAM on the Raspberry Pi / Orange Pi boards this run's NODE images
    # are for (--ram-gb). REQUIRED (8 or more) when RPI_ROLES or ORANGEPI5_ROLES
    # names omnibus — one image serves every RAM size a board is sold with.
    ram_gb: str = ""
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
        d = asdict(self)
        # per-domain ``tor`` (#582) is OMIT-WHEN-FALSE, exactly as ImageConfig.to_dict
        # writes it: a fleet record with no Tor domain keeps the bytes it had before.
        d["domains"] = domain_rows_to_dict(self.domains)
        return d

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "FleetConfig":
        # fields(), not __dataclass_fields__: the latter also lists the ``mode``
        # ClassVar, which is not an __init__ argument.
        if not isinstance(d, dict):
            raise IdentityValidationError(
                f"fleet record must be a JSON object, not {type(d).__name__}")
        known = {f.name: f for f in fields(cls)}
        kw = {k: v for k, v in d.items() if k in known}
        # A DAMAGED record (hand-edited JSON) is refused HERE with the field named, as
        # IdentityValidationError — the exception the loaders already show inline. It
        # used to pass through and surface later, inside the RESTART slot, where PyQt6
        # aborts the Studio on an unhandled exception: a TypeError from a Qt setter
        # (``"jobs": "8"`` into QSpinBox.setValue, ``"cluster_domain": 5`` or
        # ``"x86_roles": ["pki"]`` into QLineEdit.setText), a TypeError from
        # dataclasses.asdict or an AttributeError in the gate (a row that is not a
        # domain), or a ValueError from the row builder (an ``idp`` typo).
        # Every SCALAR field is checked against the type of its declared default:
        # False -> a bool, "" -> text, 8 -> a whole number (not a bool, which is an
        # int to Python). A missing key keeps the default (a pre-#645 record has none
        # of the domains keys); null is a hand edit on a scalar and is refused.
        for name, value in kw.items():
            f = known[name]
            if f.default is MISSING:                 # the list fields, checked below
                continue
            want = type(f.default)
            ok = (isinstance(value, want) and not (want is int and isinstance(value, bool)))
            if not ok:
                kind = {bool: "true or false", str: "text",
                        int: "a whole number"}.get(want, want.__name__)
                raise IdentityValidationError(
                    f"fleet record: {name} must be {kind}, not {type(value).__name__}")
        # ``jobs`` is a whole number AND inside JOBS_RANGE, here as well as in
        # validate(): a saved 0, -1 or 999 used to be clamped by the GUI's spin box
        # without a word (the record said one -j, the RESTART built another, and the
        # Review pane said Preflight OK), and 2**31 or more made QSpinBox.setValue
        # raise OverflowError — an ArithmeticError, which no (ValueError, TypeError)
        # guard around the RESTART slot catches — and PyQt6 aborted the Studio.
        if "jobs" in kw and not JOBS_RANGE[0] <= kw["jobs"] <= JOBS_RANGE[1]:
            raise IdentityValidationError(
                f"fleet record: jobs must be a whole number from {JOBS_RANGE[0]} to "
                f"{JOBS_RANGE[1]}, not {kw['jobs']!r}")
        # REHYDRATE the rows. asdict() -> JSON -> back yields plain dicts, and the
        # gate reads ``getattr(d, "name", "")`` — "" on a dict — so an un-rehydrated
        # record would pass the gate on every RESTART/REDO however unwalked it was.
        # Only an ABSENT key or null is an empty list (what an old serialiser wrote);
        # "" or 0 in either place is a hand edit and is refused like any other text.
        raw_rows = kw.get("domains")
        raw_marks = kw.get("domain_services_reviewed")
        raw_rows = [] if raw_rows is None else raw_rows
        raw_marks = [] if raw_marks is None else raw_marks
        for label, value in (("domains", raw_rows),
                             ("domain_services_reviewed", raw_marks)):
            if not isinstance(value, list):
                raise IdentityValidationError(
                    f"fleet record: {label} must be a list, not {type(value).__name__}")
        rows = []
        for i, x in enumerate(raw_rows):
            if isinstance(x, dict):
                try:
                    x = ImageConfig._domain_from_dict(x)
                except (ValueError, TypeError) as e:
                    # the row builder's own refusal (an ``idp`` outside its choices,
                    # a nested field of the wrong shape): the same inline path, the
                    # row numbered so the operator finds it in the JSON
                    raise IdentityValidationError(
                        f"fleet record: domains[{i}] is not a valid domain row ({e})") from e
            if not isinstance(x, Domain):
                raise IdentityValidationError(
                    f"fleet record: domains[{i}] must be a domain row (an object), "
                    f"not {type(x).__name__}")
            for fld in ("name", "title"):
                if not isinstance(getattr(x, fld), str):
                    raise IdentityValidationError(
                        f"fleet record: domains[{i}].{fld} must be text, "
                        f"not {type(getattr(x, fld)).__name__}")
            # The row's two list fields are iterated by the Domain services step (its
            # ``load`` and the state line): an int there passed the row builder and
            # the name check, Review showed a preflight refusal, and ONE Back click
            # raised TypeError ("'int' object is not iterable") from inside the Back
            # button's slot; a plain string ("akkoma") was iterated as letters.
            for fld in ("images", "optional_services"):
                v = getattr(x, fld)
                if not isinstance(v, list) or not all(isinstance(s, str) for s in v):
                    bad = v if not isinstance(v, list) else next(
                        s for s in v if not isinstance(s, str))
                    raise IdentityValidationError(
                        f"fleet record: domains[{i}].{fld} must be a list of text, "
                        f"not {type(bad).__name__}")
            rows.append(x)
        kw["domains"] = rows
        for j, n in enumerate(raw_marks):
            # a marker is a domain name the step was walked for; a dict or a number
            # here is a hand edit, named like every other one (str() of it matched
            # no domain, so it was harmless, but silently so)
            if not isinstance(n, str):
                raise IdentityValidationError(
                    f"fleet record: domain_services_reviewed[{j}] must be text, "
                    f"not {type(n).__name__}")
        kw["domain_services_reviewed"] = list(raw_marks)
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
                              ("orangepi5_roles", self.orangepi5_roles),
                              ("orangepi4lts_roles", self.orangepi4lts_roles),
                              ("optional_services", self._services_words())):
            for tok in roleset.split():
                if not _ROLE_TOKEN_RE.match(tok):
                    raise IdentityValidationError(
                        f"invalid {name} token: {tok!r} — rejected by the fleet allowlist")
        self._validate_ram()
        # extra_flags is shlex-split into argv by to_cli_args: an unbalanced quote (a
        # plain apostrophe in a note, an unterminated "...) raised ValueError from
        # shlex there, which the TUI's review did not catch — the whole text-mode fleet
        # flow died on it. Refuse it HERE, at the one validation seam both faces call
        # (the TUI on every `set`, the GUI's preview and preflight), with the reason.
        if self.extra_flags:
            try:
                shlex.split(self.extra_flags)
            except ValueError as e:
                raise IdentityValidationError(
                    f"extra_flags cannot be split into arguments ({e}) — balance the "
                    "quotes, e.g. --note \"it's\"") from e
        # -j: the GUI's spin box already stops at JOBS_RANGE; the TUI's `set jobs N`
        # took any int (0, -5) straight into the command until this check.
        if (isinstance(self.jobs, bool) or not isinstance(self.jobs, int)
                or not JOBS_RANGE[0] <= self.jobs <= JOBS_RANGE[1]):
            raise IdentityValidationError(
                f"jobs must be a whole number from {JOBS_RANGE[0]} to {JOBS_RANGE[1]}, "
                f"not {self.jobs!r}")

    def _validate_ram(self) -> None:
        """The builders' RAM gate (scripts/_roles-lib.sh hugmesh_role_ram_check), up
        front: RAM_GB is a whole number of GB, and an omnibus in RPI_ROLES or
        ORANGEPI5_ROLES needs it at or above omnibus's floor. Refused here so neither
        face (GUI preview / TUI ``set``) starts a run the first omnibus build kills."""
        from . import roles as role_vocab
        ram = str(self.ram_gb or "").strip()
        if ram and (not ram.isdigit() or ram.startswith("0")):
            raise IdentityValidationError(
                f"ram_gb must be a whole number of GB, e.g. 8 (got {ram!r})")
        omnibus_in = [name for name, roleset in (("rpi_roles", self.rpi_roles),
                                                 ("orangepi5_roles", self.orangepi5_roles))
                      if any(role_vocab.canonicalize(t) == "omnibus"
                             for t in roleset.split())]
        if not omnibus_in:
            return
        floor = role_vocab.min_ram_gb("omnibus") or 0
        if not ram:
            raise IdentityValidationError(
                f"{' and '.join(omnibus_in)} names omnibus, which needs ram_gb (the GB of "
                f"RAM on the boards, {floor} or more): one image serves every RAM size a "
                "board is sold with, so the build cannot tell")
        if int(ram) < floor:
            raise IdentityValidationError(
                f"omnibus needs at least {floor} GB of RAM (got ram_gb {ram}); build "
                "pki/backend/frontend for a smaller board")

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
            ("ORANGEPI5_ROLES", " ".join(self.orangepi5_roles.split())),
            ("ORANGEPIZERO2_FLAVOR", self.orangepizero2_flavor),
            ("ORANGEPIZERO2W_FLAVOR", self.orangepizero2w_flavor),
            ("ORANGEPIZERO3_FLAVOR", self.orangepizero3_flavor),
            ("ORANGEPI3LTS_FLAVOR", self.orangepi3lts_flavor),
            ("ORANGEPI4LTS_FLAVOR", self.orangepi4lts_flavor),
            ("ORANGEPI4LTS_ROLES", " ".join(self.orangepi4lts_roles.split())),
            ("RAM_GB", str(self.ram_gb or "").strip()),
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
