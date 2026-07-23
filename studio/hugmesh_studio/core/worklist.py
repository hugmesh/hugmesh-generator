"""Worklist envelope — the mesh (and, always, the single-image) build model.

A worklist is an ENVELOPE around one base :class:`~.config.ImageConfig` plus a list
of :class:`WorklistEntry` rows, one per role x platform combination the mesh needs.
The shared identity plane (domains / users / network / system / disk-encryption
default) lives IN the base config, exactly as today; each entry only carries the
axes that make it a distinct image (role, platform, board/flavor/desktop, its
encrypt-root override, and its per-image package deltas).

``materialize()`` projects the envelope back down into a list of plain, fully-valid
single-image :class:`ImageConfig` objects — so every downstream mechanism
(``to_cli_args()``, preflight, the build driver, ``--print-command``, the web job
channel) is reused untouched. This is what keeps both UIs thin projections and the
whole redesign headless-testable.

Discriminator: the on-disk envelope carries an explicit top-level ``"schema"`` key
(``hugmesh-worklist/v1``). :meth:`ImageConfig.load` fails LOUDLY on that key so an
envelope can never silently degrade to a default config; :func:`load_any` is the
single loader that accepts BOTH shapes (envelope -> WorklistConfig, anything else ->
flat ImageConfig), so the 118 matrix flat configs and all user saves keep loading
byte-identically.

Qt-free by construction (model only) — imported by the headless ``--print-commands``
path and the pure-core test suite with no GUI toolkit installed.
"""
from __future__ import annotations

import copy
import json
import sys
from dataclasses import dataclass, field
from typing import Any

from .config import (
    INFRA_SERVICES_CHOICES,
    OPTIONAL_SERVICES_BY_PLATFORM,
    ImageConfig,
    SECRET_FIELDS,
    clear_role_class_fields,
    resolve_installer_ui_default,
    resolve_platform_defaults,
    strip_platform_unsupported,
)

WORKLIST_SCHEMA = "hugmesh-worklist/v1"

# encrypt_root override sentinels on a worklist entry.
ENCRYPT_ROOT_CHOICES = ("default", "on", "off")

# Per-node INFRA (scope:node) services a mesh worklist entry may opt into,
# independently per node — the Tor v3 onion (docs/TOR-HIDDEN-SERVICE.md) and the
# node egress-VPN (docs/EGRESS-VPN.md). A subset of config.INFRA_SERVICES_CHOICES:
# only the two that are genuine per-NODE image services (workloadConsole/anubis are
# cluster-plane, not a per-node image axis). ADDITIVE to the mesh-wide default the
# Network page sets — so "the mesh has no onion, but node X exposes one" is now
# expressible, which a single mesh-wide flag could not say.
WORKLIST_INFRA_SERVICES = ("tor", "egress-vpn")

# The ONLY platform whose builder takes the Tor onion as the dedicated --with-tor
# flag (tor_onion_service is an x86-only field). On rpi5, tor is a --optional-services
# node slug instead; every other platform expresses neither, so the selection is
# dropped there rather than emitted as a flag the builder would ignore.
_TOR_WITH_FLAG_PLATFORMS = ("x86",)


def entry_id(role: str, platform: str) -> str:
    """The STABLE worklist entry id — ``f"{role}.{platform}"``. One id per role x
    platform combo; board/flavor are row ATTRIBUTES, so an id never dangles when a
    board is edited (that was the D1 weakness the synthesis fixed)."""
    return f"{role}.{platform}"


@dataclass
class WorklistEntry:
    """One image the worklist builds: a role x platform pair plus its per-image axes.

    ``id`` is derived from ``role``/``platform`` when omitted (the stable identity used
    for domain attachment and the per-entry build_subdir); an explicit id is honored on
    load so a round-trip is exact. ``build_subdir`` is DERIVED (``wl-<id>``), never
    stored — it is the same-arch build-tree collision guard applied in materialize()."""
    role: str = ""
    platform: str = "x86"
    id: str = ""                     # STABLE f"{role}.{platform}"; derived if blank
    board: str = ""                  # rpi5 / jetson / frite / orangepi5 board axis
    flavor: str = ""                 # frite / orangepi5 / orangepizero2 live|installer axis
    desktop: str = ""                # frite / orangepi5 (and x86 thin|full) desktop axis
    encrypt_root: str = "default"    # "default" | "on" | "off"; jetson rows forced "off"
    packages_add: str = ""           # per-image Portage atoms to add (space-separated)
    packages_drop: str = ""          # per-image Portage atoms to drop (space-separated)
    # Per-node scope:node infra services (WORKLIST_INFRA_SERVICES). ADDITIVE to the
    # mesh-wide Network-page default; emitted via each platform's real mechanism in
    # materialize (x86 tor -> --with-tor; rpi5 tor/egress-vpn -> --optional-services).
    infra_services: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not self.id:
            self.id = entry_id(self.role, self.platform)
        # Tolerate a list from JSON (from_dict) — the field is a tuple by contract.
        if not isinstance(self.infra_services, tuple):
            self.infra_services = tuple(self.infra_services or ())

    @property
    def build_subdir(self) -> str:
        """Same-arch build trees must not collide — each entry builds under wl-<id>."""
        return f"wl-{self.id}"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id, "role": self.role, "platform": self.platform,
            "board": self.board, "flavor": self.flavor, "desktop": self.desktop,
            "encrypt_root": self.encrypt_root,
            "packages_add": self.packages_add, "packages_drop": self.packages_drop,
            # a JSON list on disk; __post_init__ re-tuples it on load
            "infra_services": list(self.infra_services),
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "WorklistEntry":
        known = set(cls.__dataclass_fields__)  # type: ignore[attr-defined]
        return cls(**{k: v for k, v in d.items() if k in known})


@dataclass
class WorklistConfig:
    """The worklist envelope: a base ImageConfig + the per-image entries.

    (``base`` is declared first so the dataclass has no default-before-required field;
    the on-disk order is ``schema`` / ``base`` / ``entries`` — see :meth:`to_dict`.)"""
    base: ImageConfig
    schema: str = WORKLIST_SCHEMA
    entries: list[WorklistEntry] = field(default_factory=list)

    # ---- (de)serialization -------------------------------------------------
    def to_dict(self, include_secrets: bool = False) -> dict[str, Any]:
        """Serialize to the wire envelope. The base's plaintext secrets are BLANKED
        unless the caller opts in (delegates to ImageConfig.to_dict)."""
        return {
            "schema": self.schema,
            "base": self.base.to_dict(include_secrets=include_secrets),
            "entries": [e.to_dict() for e in self.entries],
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "WorklistConfig":
        base = ImageConfig.from_dict(d.get("base") or {})
        entries = [WorklistEntry.from_dict(x) for x in (d.get("entries") or [])
                   if isinstance(x, dict)]
        wl = cls(base=base, schema=d.get("schema", WORKLIST_SCHEMA), entries=entries)
        # Fail loudly on a foreign/hand-authored envelope with colliding ids BEFORE any
        # consumer (the GUI's by-id view, the driver, --print-specs) silently drops or
        # clobbers one image — see _assert_unique_entry_ids.
        wl._assert_unique_entry_ids()
        return wl

    def _assert_unique_entry_ids(self) -> None:
        """Each entry id (``role.platform``) must appear once. board/flavor/desktop are
        per-entry ATTRIBUTES, not separate rows (see :func:`entry_id`), so two entries
        that differ only in those axes share an id — and therefore the DERIVED
        ``build_subdir`` (``wl-<id>``) and the WorklistDriver ``keys-<id>`` dir. The
        second image would then build into the first's tree and clobber its node keys,
        and the GUI's by-id reload view would silently drop one. The entry model asserts
        this 'same-arch build trees must not collide' invariant (build_subdir docstring);
        enforce it here rather than leaving it aspirational."""
        seen: dict[str, int] = {}
        for i, entry in enumerate(self.entries):
            if entry.id in seen:
                raise ValueError(
                    f"worklist entries #{seen[entry.id]} and #{i} share id "
                    f"{entry.id!r}: each role×platform must appear once (board/flavor/"
                    f"desktop are per-entry attributes, not separate rows). Distinct "
                    f"images would collide on build tree wl-{entry.id} and its node-keys "
                    f"dir.")
            seen[entry.id] = i

    def save(self, path: str) -> list[str]:
        """Write the envelope JSON (base secrets blanked, matching ImageConfig.save).
        Returns the aggregated per-secret warning list so the UI can surface any secret
        that was set on the base but NOT persisted — the same message shape as
        ImageConfig.save, extended (not changed) to the envelope."""
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(self.to_dict(), fh, indent=2)
        return [f"{k.replace('_', '-')} was NOT saved (plaintext secret) — re-enter it "
                "before building from this config"
                for k in SECRET_FIELDS if getattr(self.base, k)]

    # ---- projection back to single-image configs ---------------------------
    def materialize(self) -> list[tuple[WorklistEntry, ImageConfig]]:
        """Project the envelope into a list of (entry, plain ImageConfig) — the
        deterministic, unit-pinned pipeline (design 2.4). Each output config is a fully
        valid single-image config that every existing single-image mechanism reuses
        untouched. Order mirrors ``self.entries``."""
        # Universal chokepoint: guard even a programmatically-built worklist (the GUI
        # never routes through from_dict) so a duplicate id can never reach the driver
        # and clobber a build tree / node-keys dir.
        self._assert_unique_entry_ids()
        out: list[tuple[WorklistEntry, ImageConfig]] = []
        for entry in self.entries:
            out.append((entry, self._materialize_one(entry)))
        return out

    def _materialize_one(self, entry: WorklistEntry) -> ImageConfig:
        # 1. deepcopy the base and stamp the entry's structural axes onto it. Role-id
        #    normalization (RPI5_ROLE_MAP / JETSON_ROLE_MAP) stays downstream in
        #    to_cli_args, exactly as for a hand-built single-image config.
        cfg = copy.deepcopy(self.base)
        cfg.role = entry.role
        cfg.platform = entry.platform
        cfg.board = entry.board
        cfg.flavor = entry.flavor
        cfg.desktop = entry.desktop

        # 1b. Platform-aware default resolution — BEFORE the role-class gating in step 5
        #    (clear_role_class_fields keys image_class() on cfg.role, so a leaked x86
        #    role on an ARM node entry must be corrected first) and before step 6's
        #    validate_identity. Only fires for an UNSET/x86-default role that is invalid
        #    for this platform (gap G3) and an unset flavor on the ARM ISO platforms
        #    (gap G2); an explicit valid role/flavor is left byte-identical, and the
        #    entry.id / build_subdir keep tracking the ORIGINAL entry.role (a leaked
        #    entry was malformed — its id is not expected to follow the resolved role).
        resolve_platform_defaults(cfg)

        # 2. Filter the shared domains to those this image is attached to (Domain.images
        #    empty == attach to every eligible image), IN TABLE ORDER so the first
        #    attached row stays the PRIMARY --domains element (ROLE_TAG/filename
        #    determinism). MUST run before step 5: strip_platform_unsupported blanks
        #    cfg.domains on ARM (WS-CORE ordering concern).
        cfg.domains = [copy.deepcopy(d) for d in self.base.domains
                       if not d.images or entry.id in d.images]

        # 3. Users are manifest-only and never per-image filtered — carry them whole.
        cfg.users = [copy.deepcopy(u) for u in self.base.users]

        # 4. Per-image package deltas (kept SEPARATE from the frozen extra_packages —
        #    no merging) + the encrypt_root resolution + the collision-guard subdir.
        cfg.packages_add = entry.packages_add
        cfg.packages_drop = entry.packages_drop
        cfg.encrypt_root = self._resolve_encrypt_root(entry)
        cfg.build_subdir = entry.build_subdir

        # 4b. Per-node infra (scope:node) services — the Tor onion + node egress-VPN
        #     (docs/TOR-HIDDEN-SERVICE.md / EGRESS-VPN.md), ADDITIVE to the mesh-wide
        #     Network-page default already on the base. Emitted via the mechanism THIS
        #     platform's builder actually accepts, so a per-node selection is a REAL
        #     flag, never a silent no-op (the dead-default class this file guards):
        #       - x86 tor  -> --with-tor            (tor_onion_service; the x86-only field)
        #       - rpi5 tor / rpi5 egress-vpn -> --optional-services <slug> (node services)
        #     BEFORE step 5 so strip_platform_unsupported is the safety net; a service the
        #     entry's platform cannot express (frite/jetson/opi5/opz2 parse neither) is
        #     dropped, never emitted.
        self._apply_infra_services(cfg, entry)

        # 5. Defensive re-application of the two gating axes (belt & braces I4), then the
        #    mesh tailnet forcing (matching builder reality: x86 mesh emits
        #    --with-tailscale/--with-sso; ARM joins mesh unless --skip-mesh).
        strip_platform_unsupported(cfg)
        clear_role_class_fields(cfg)
        # 5b. Role-class installer-UI resolution (#337's twin). AFTER strip_platform_
        #    unsupported, never before: strip resets installer_ui to the dataclass
        #    default "all" on non-x86, which would undo a "cli" set earlier and bake a
        #    misleading value into the materialized spec. Node-class x86 only — a client/
        #    standalone entry returns early, so desktop argv stays byte-identical.
        #    The note is a WARNING for stderr, never stdout (app.py's argv channel).
        note = resolve_installer_ui_default(cfg)
        if note:
            print(f"warning: {note}", file=sys.stderr)
        if cfg.mode == "mesh":
            cfg.tailscale = True
            cfg.sso = True

        # 6. Fail closed — includes superdomain + the package-atom regex.
        cfg.validate_identity()
        return cfg

    def _apply_infra_services(self, cfg: ImageConfig, entry: WorklistEntry) -> None:
        """Fold the entry's per-node infra services onto ``cfg`` via each platform's
        real builder mechanism (see step 4b). Unknown / platform-inexpressible slugs
        are dropped — a per-node toggle never becomes a flag the builder ignores."""
        plat_optional = OPTIONAL_SERVICES_BY_PLATFORM.get(entry.platform, ())
        for svc in entry.infra_services:
            if svc not in WORKLIST_INFRA_SERVICES:
                continue                                   # not a per-node infra slug
            if svc == "tor" and entry.platform in _TOR_WITH_FLAG_PLATFORMS:
                cfg.tor_onion_service = True               # x86: the dedicated --with-tor
            elif svc in INFRA_SERVICES_CHOICES and svc in plat_optional:
                # rpi5: a real --optional-services node service. Append (dedup); the
                # sentinel forms (none/all) are never per-node, so a plain slug is safe.
                if svc not in cfg.optional_services:
                    cfg.optional_services = [*cfg.optional_services, svc]
            # else: this platform's builder expresses neither -> drop (no dead flag).

    def _resolve_encrypt_root(self, entry: WorklistEntry) -> bool:
        """Resolve the entry's tri-state override to a concrete bool. Jetson is forced
        OFF (the jetson builder hard-blocks --encrypt-root); "default" inherits the
        worklist-wide default captured on the Home page (base.encrypt_root)."""
        if entry.platform == "jetson":
            return False
        if entry.encrypt_root == "on":
            return True
        if entry.encrypt_root == "off":
            return False
        return bool(self.base.encrypt_root)


def load_any(path: str) -> tuple[ImageConfig, "WorklistConfig | None"]:
    """Load either shape from ``path``:

    * a worklist ENVELOPE (explicit top-level ``"schema"``) -> ``(base, WorklistConfig)``
    * anything else (a flat single-image config) -> ``(ImageConfig.from_dict(...), None)``

    The single loader both UIs and the headless ``--print-commands`` path share, so the
    118 matrix flat configs and all user saves keep loading unchanged while an envelope
    is never silently degraded (ImageConfig.load raises on the same discriminator)."""
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, dict) and "schema" in data:
        wl = WorklistConfig.from_dict(data)
        return wl.base, wl
    return ImageConfig.from_dict(data), None


def synthesize(cfg: ImageConfig) -> WorklistConfig:
    """Wrap a single-image config as a 1-entry worklist (the standalone/cloud shape the
    wizard ALWAYS commits at Build time, so driver/progress/manifest have exactly one
    code path). The lone entry captures the config's structural axes and package deltas;
    the base carries everything else. materialize() reproduces the config faithfully."""
    entry = WorklistEntry(
        role=cfg.role, platform=cfg.platform or "x86",
        board=cfg.board, flavor=cfg.flavor, desktop=cfg.desktop,
        encrypt_root="on" if cfg.encrypt_root else "off",
        packages_add=cfg.packages_add, packages_drop=cfg.packages_drop,
    )
    return WorklistConfig(base=copy.deepcopy(cfg), entries=[entry])
