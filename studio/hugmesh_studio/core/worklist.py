"""Worklist envelope — the mesh (and, always, the single-image) build model.

A worklist is an ENVELOPE around one base :class:`~.config.ImageConfig` plus a list
of :class:`WorklistEntry` rows, one per role x platform combination the mesh needs.
The shared identity plane (domains / users / network / system / disk-encryption
default) lives IN the base config, exactly as today; each entry only carries the
axes that make it a distinct image (role, platform, board/flavor/desktop, its
encrypt-root override, its per-image package deltas, and — issue #229 — its own
hostname: the one system-identity value that cannot be mesh-wide, because a
hostname shared by every node is a collision, not a setting).

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
from types import SimpleNamespace
from typing import Any

from . import json_files, roles

from .config import (
    BUILTIN_DEFAULT_SERVICES,
    INFRA_SERVICES_CHOICES,
    OPTIONAL_SERVICES_BY_PLATFORM,
    PERSON_ROLE_CHOICES,
    SERVICES_ALL,
    SERVICES_NONE,
    USER_LEVEL_SERVICES,
    ImageConfig,
    SECRET_FIELDS,
    User,
    clear_role_class_fields,
    derive_hostname,
    emit_note_once,
    image_class,
    normalize_user_roles,
    person_tier,
    resolve_installer_ui_default,
    resolve_platform_defaults,
    strip_platform_unsupported,
    with_service_slug,
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

# Managed backing services (I8/M2) are deliberately NOT a per-node worklist axis. A
# "managed" backing service repoints the WHOLE mesh's shared datastore/infra at ONE
# hosted cloud endpoint — every node talks to the same logical service, so the choice is
# mesh-wide by nature (exactly like optional_services: WorklistEntry carries no
# managed_services field). It is threaded as the single-image ImageConfig.managed_services
# on the shared base, which _materialize_one deepcopies onto every entry; step 5's
# strip_platform_unsupported then clears it on any non-x86/rpi5 node (it is _X86_RPI5-
# scoped, the two cluster-tree builders). So there is no inexpressible-per-node case to
# DROP here — the mesh-wide field simply rides the base, and no dead --managed-service is
# ever emitted for a platform that cannot express it.

# The ONLY platform whose builder takes the Tor onion as the dedicated --with-tor
# flag (tor_onion_service is an x86-only field). On rpi5, tor is a --optional-services
# node slug instead; every other platform expresses neither, so the selection is
# dropped there rather than emitted as a flag the builder would ignore.
_TOR_WITH_FLAG_PLATFORMS = ("x86",)


def resolve_encrypt_root(entry: "WorklistEntry", base_encrypt_root: bool) -> bool:
    """Resolve one entry's tri-state ``encrypt_root`` override against the worklist-wide
    default. Jetson is forced OFF (its builder hard-blocks ``--encrypt-root`` and
    ``to_cli_args`` raises); "on"/"off" force; "default" inherits.

    Module-level and pure so the GUI can ask what a row WILL resolve to before anything
    is materialized (the ask-21 ARM cross-dracut note) without re-implementing — and
    therefore drifting from — ``WorklistConfig._resolve_encrypt_root``, which is now a
    one-line delegate to this.
    """
    if entry.platform == "jetson":
        return False
    if entry.encrypt_root == "on":
        return True
    if entry.encrypt_root == "off":
        return False
    return bool(base_encrypt_root)


def resolve_hostname(entry: "WorklistEntry", base_hostname: str) -> str:
    """The explicit ``-H/--hostname`` one entry will bake, or "" when the builder is
    left to derive its role name: the entry's own ``hostname`` wins, a blank one
    inherits the base. Module-level and pure (like :func:`resolve_encrypt_root`) so
    both UIs can show what a row WILL bake without re-implementing — and therefore
    drifting from — what ``_materialize_one`` does."""
    return (entry.hostname or "").strip() or (base_hostname or "").strip()


def derived_hostname(entry: "WorklistEntry", brand: str = "") -> str:
    """The role-derived hostname this entry bakes when its own ``hostname`` is blank —
    what the builder's role switch assigns with no ``-H``.

    Probed with the ENTRY's own role/platform/board, never the base's: the worklist
    pins the base role to the first checked row and forces the base platform to
    "x86", so deriving off the base would report one node's name for all of them.
    Module-level and pure so the model, the GUI editors' placeholders and the TUI
    table all read ONE implementation and cannot drift apart."""
    return derive_hostname(SimpleNamespace(
        brand=brand, role=entry.role, platform=entry.platform,
        board=entry.board, unaffiliated=False))


def duplicate_hostnames(entries: list["WorklistEntry"],
                        base_hostname: str,
                        brand: str = "") -> dict[str, list[str]]:
    """``{hostname: [entry ids]}`` for every hostname two or more entries would bake
    (issue #229's failure mode: several images, one name). Empty when clean.

    TWO halves, because a built image does not care which half produced its name:

    * explicit vs explicit — two rows carry (or inherit from the base) the same
      typed name;
    * explicit vs DERIVED — one row types a name that is exactly what a BLANK
      sibling's role switch assigns. That row emits ``--hostname X`` and the blank
      one emits nothing, so the argv looks clean and the two nodes still boot as X.
      This is the shape the GUI used to catch alone, which meant the guard's strength
      depended on which of the three channels you drove; it is checked HERE now, so
      ``--config`` on the CLI refuses it too.

    Blank vs blank is deliberately NOT a collision: two blanks only share a name when
    the builder's own role tables assign one, which is the builder's business and has
    always been the shipped behaviour — the UIs say it out loud (a note, not a
    refusal) rather than blocking a build that was never broken."""
    seen: dict[str, list[str]] = {}
    blank_derived: dict[str, list[str]] = {}
    for e in entries:
        hn = resolve_hostname(e, base_hostname)
        if hn:
            seen.setdefault(hn, []).append(e.id)
        else:
            blank_derived.setdefault(derived_hostname(e, brand), []).append(e.id)
    dups = {hn: list(ids) for hn, ids in seen.items() if len(ids) > 1}
    for hn, ids in seen.items():
        blanks = blank_derived.get(hn)
        if blanks:
            dups[hn] = list(dict.fromkeys([*ids, *blanks]))
    return dups


# The platforms whose NODE entries take the board's RAM (--ram-gb): the Raspberry Pi and
# the two Orange Pi node boards. x86 / jetson builders do not take it. Shared by the GUI
# WorklistPage (RAM column) and the TUI WorklistScreen (`ram N GB`).
RAM_PLATFORMS = ("rpi5", "orangepi5", "orangepi4-lts")
RAM_PLATFORM_NAMES = {"rpi5": "Raspberry Pi", "orangepi5": "Orange Pi 5 / 5 Plus",
                      "orangepi4-lts": "Orange Pi 4 LTS"}


def takes_ram(role: str, platform: str) -> bool:
    """Does a (role, platform) worklist row carry a board RAM (--ram-gb)? Node roles
    with a RAM floor (scripts/_roles-lib.sh HUGMESH_ROLE_MIN_RAM_GB) on RAM_PLATFORMS."""
    return platform in RAM_PLATFORMS and roles.min_ram_gb(role) is not None


def ram_problem(role: str, platform: str, ram_gb: str, board: str = "") -> str:
    """Why ``ram_gb`` cannot be this row's board RAM ("" = fine). The builders' own
    gate (hugmesh_role_ram_check): a whole number of GB, at or above the role's floor;
    "" is fine except for a role that REQUIRES it (omnibus); and a ``board`` that is
    never sold with the floor (a Pi 4 omnibus) is refused whatever the RAM says."""
    ram = str(ram_gb or "").strip()
    if not takes_ram(role, platform):
        return "" if not ram else f"{role}.{platform} takes no board RAM"
    floor = roles.min_ram_gb(role) or 0
    if board and not roles.board_fits_role(role, board):
        return (f"{role} needs at least {floor} GB of RAM, and {board} is sold with at "
                f"most {max(roles.board_ram_gb(board))} GB")
    if not ram:
        if roles.ram_required(role):
            return (f"{role} on the {RAM_PLATFORM_NAMES.get(platform, platform)} needs its "
                    f"board's RAM ({floor} GB or more): one image serves every RAM size")
        return ""
    if not ram.isdigit() or ram.startswith("0"):
        return f"the RAM must be a whole number of GB, e.g. 8 (got {ram!r})"
    if int(ram) < floor:
        return f"{role} needs at least {floor} GB of RAM (got {ram})"
    return ""


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
    flavor: str = ""                 # frite / orangepi5 / orangepizero2[w] / orangepizero3 / orangepi3-lts live|installer axis
    desktop: str = ""                # frite / orangepi5 (and x86 thin|full) desktop axis
    encrypt_root: str = "default"    # "default" | "on" | "off"; jetson rows forced "off"
    packages_add: str = ""           # per-image Portage atoms to add (space-separated)
    packages_drop: str = ""          # per-image Portage atoms to drop (space-separated)
    # Per-node scope:node infra services (WORKLIST_INFRA_SERVICES). ADDITIVE to the
    # mesh-wide Network-page default; emitted via each platform's real mechanism in
    # materialize (x86 tor -> --with-tor; rpi5 tor/egress-vpn -> --optional-services).
    infra_services: tuple[str, ...] = ()
    # The PERSON on a desktop-class entry (operator ask 2026-08-14): checking a
    # desktop row on the mesh WorklistPage collects its user's name + roles via a
    # popup. materialize() stamps the TIER as --person-role on the entry's own
    # image and derives a manifest User on the internal Tailscale root domain
    # (the account can later be added to other domains via the Users table).
    # Node entries always leave these blank.
    desktop_user: str = ""
    # The person's TIER (PERSON_ROLE_CHOICES: user|mod|admin|superadmin) — the one
    # value --person-role takes. "" (the dataclass default) = derive from
    # ``desktop_user_roles``; ``user`` when neither says anything. DERIVED in
    # __post_init__ (person_tier) so it can never disagree with the set; build
    # entries through the constructor, do not assign it afterwards (issue #228).
    desktop_user_role: str = ""
    # ALL the roles the person's ACCOUNT holds (issue #228 — the desktop-person leg
    # of multi-role): the tier plus any grants (config.USER_GRANT_CHOICES: games /
    # games-services), normalize_user_roles order. The tier is always IN the set —
    # the image bakes that identity in, so the account holds it too — which is what
    # makes to_dict/from_dict a fixed point. Serialized OMIT-WHEN-SINGLE (absent ==
    # [desktop_user_role]) so a one-tier entry keeps its pre-#228 bytes on the wire;
    # desktop_users() hands the whole set to the derived manifest User (User.roles),
    # the image itself takes only the tier.
    desktop_user_roles: list[str] = field(default_factory=list)
    # PER-IMAGE host identity (issue #229). The base ImageConfig carries ONE
    # ``hostname`` and every materialized image used to inherit it byte-identical, so
    # a hostname typed once named every node in the mesh the same thing. This is the
    # per-entry override: "" = inherit (the base value, else the builder's own
    # role-derived name); non-"" = THIS image's -H/--hostname. Timezone and the
    # default account stay mesh-wide on the base — the issue accepts that for both.
    hostname: str = ""
    # GB of RAM on the Raspberry Pi / Orange Pi board this NODE entry is for
    # (ImageConfig.ram_gb -> --ram-gb). "" = not stated; REQUIRED for an omnibus
    # entry on rpi5/orangepi5 (16 GB+). Serialized OMIT-WHEN-EMPTY, so every entry
    # saved before the field existed keeps its bytes.
    ram_gb: str = ""

    def __post_init__(self) -> None:
        if not self.id:
            self.id = entry_id(self.role, self.platform)
        # Tolerate a list from JSON (from_dict) — the field is a tuple by contract.
        if not isinstance(self.infra_services, tuple):
            self.infra_services = tuple(self.infra_services or ())
        # The person's roles: union of the set and the tier as constructed (either
        # spelling alone loads — a pre-#228 record carries only the tier), a bare
        # string taken as one role, floored to the ``user`` tier when the set names
        # no tier at all (grants-only), and the tier re-derived from the result.
        given = ([self.desktop_user_roles] if isinstance(self.desktop_user_roles, str)
                 else list(self.desktop_user_roles or []))
        roles = normalize_user_roles([*given, self.desktop_user_role])
        if not any(r in PERSON_ROLE_CHOICES for r in roles):
            roles = normalize_user_roles([*roles, "user"])
        self.desktop_user_roles = roles
        self.desktop_user_role = person_tier(roles)

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
            "desktop_user": self.desktop_user,
            "desktop_user_role": self.desktop_user_role,
            # issue #228: the full set only when it is more than the tier, so a
            # one-tier entry is byte-identical to before the key existed (the same
            # OMIT-WHEN-SINGLE rule as User.to_dict / the per-domain idp key).
            **({"desktop_user_roles": list(self.desktop_user_roles)}
               if self.desktop_user_roles != [self.desktop_user_role] else {}),
            "hostname": self.hostname,
            **({"ram_gb": str(self.ram_gb)} if self.ram_gb else {}),
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "WorklistEntry":
        """Load one entry, folding a pre-convergence role spelling to its canonical
        token (scripts/_roles-lib.sh).

        The record is NEVER rewritten and the entry ``id`` is left exactly as saved:
        the id is what names this entry's build tree (``wl-be.x86``), its per-node
        KEYS folder (``keys-be.x86`` — which holds that node's actual credentials and
        which an operator navigates to by name) and its log. Those are
        already-emitted artifacts. Folding the ROLE makes an old worklist replay
        correctly; renaming the DIRECTORIES would move an operator's keys out from
        under them.
        """
        known = set(cls.__dataclass_fields__)  # type: ignore[attr-defined]
        vals = {k: v for k, v in d.items() if k in known}
        if isinstance(vals.get("role"), str) and vals["role"]:
            vals["role"] = roles.canonicalize(vals["role"])
        # issue #228: a null / non-list desktop_user_roles is ABSENT, never a crash
        # (__post_init__ takes a bare string as one role and unions the tier).
        if not isinstance(vals.get("desktop_user_roles", []), (str, list, tuple)):
            vals.pop("desktop_user_roles")
        if not isinstance(vals.get("desktop_user_role", ""), str):
            vals.pop("desktop_user_role")
        return cls(**vals)


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

    def _assert_unique_hostnames(self) -> None:
        """Two images in one worklist must not bake the same hostname (issue #229).
        Before per-entry hostnames existed the base's single value rode onto every
        image silently; now that the collision is expressible per row it is also
        detectable, and a mesh whose nodes share a name is not a mesh that works, so
        fail loudly at the same chokepoint the id collision uses.

        Both halves are checked (see :func:`duplicate_hostnames`): two typed names
        that match, AND a typed name that matches what a blank sibling's role switch
        derives — the second is the one that reads clean in the argv and still boots
        two nodes as one name, so the CLI's ``--config`` channel must refuse it too
        and not lean on the GUI having caught it. The message names the fix."""
        dups = duplicate_hostnames(self.entries, self.base.hostname, self.base.brand)
        if dups:
            detail = "; ".join(f"{hn!r} on {', '.join(ids)}" for hn, ids in dups.items())
            raise ValueError(
                f"worklist entries would bake the same hostname: {detail}. Set a "
                "distinct hostname per image (entries[].hostname / the System step); "
                "a blank row is not free of this — it bakes its role-derived name, "
                "which is what a typed name can collide with.")

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
    def desktop_users(self, skip: set[tuple[str, str]] = frozenset()) -> list[User]:
        """The manifest Users derived from desktop entries' named people (operator ask
        2026-08-14): one per desktop-class entry with a ``desktop_user``, attached to
        the internal Tailscale root domain — the same domain the Users table locks
        superadmins to. ``skip`` drops (username, domain) pairs the caller already
        carries so a Users-table row (richer: email/registration) always wins. The
        account can later be added to other/additional domains via that table.
        The User carries the person's FULL role set (issue #228 — tier + grants);
        the image itself takes only the tier (_materialize_one 3b)."""
        domain = self.base.effective_superdomain()
        out: list[User] = []
        seen = set(skip)
        for e in self.entries:
            name = (e.desktop_user or "").strip()
            if not name or image_class(self.base.mode, e.role) != "desktop":
                continue
            if (name, domain) in seen:
                continue
            seen.add((name, domain))
            out.append(User(username=name, domain=domain,
                            roles=list(e.desktop_user_roles)))
        return out

    def materialize(self) -> list[tuple[WorklistEntry, ImageConfig]]:
        """Project the envelope into a list of (entry, plain ImageConfig) — the
        deterministic, unit-pinned pipeline (design 2.4). Each output config is a fully
        valid single-image config that every existing single-image mechanism reuses
        untouched. Order mirrors ``self.entries``."""
        # Universal chokepoint: guard even a programmatically-built worklist (the GUI
        # never routes through from_dict) so a duplicate id can never reach the driver
        # and clobber a build tree / node-keys dir.
        self._assert_unique_entry_ids()
        self._assert_unique_hostnames()
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
        cfg.ram_gb = str(entry.ram_gb or "")

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

        # 3. Users are manifest-only and never per-image filtered — carry them whole,
        #    PLUS the desktop-entry people (operator ask 2026-08-14): every desktop
        #    entry's named user becomes a manifest User on the internal Tailscale
        #    root domain, so cluster provisioning creates the account exactly like a
        #    Users-table row. Deduped against the table (a superadmin who already
        #    named the person keeps their richer row — email/registration survive).
        cfg.users = [copy.deepcopy(u) for u in self.base.users]
        cfg.users += self.desktop_users(
            skip={(u.username, u.domain) for u in cfg.users})

        # 3b. The FD-08 person identity for THIS image — MESH worklists only (a
        #    cloud/standalone flat config wrapped by from_flat keeps the RolePage's
        #    own person_role byte-identical). A desktop entry with a named person
        #    carries their TIER as --person-role (x86 clients emit it; ARM desktops
        #    drop it via strip_platform_unsupported below — their builders parse no
        #    such flag); the grants (issue #228) ride the manifest User only — the
        #    builder accepts exactly the four tiers. Every other mesh entry resets
        #    it, so a desktop pick can never leak onto a node's argv (the builder
        #    would warn+ignore it anyway).
        if cfg.mode == "mesh":
            if image_class(cfg.mode, entry.role) == "desktop" and entry.desktop_user:
                cfg.person_role = entry.desktop_user_role
            else:
                cfg.person_role = ""

        # 4. Per-image package deltas (kept SEPARATE from the frozen extra_packages —
        #    no merging) + the encrypt_root resolution + the collision-guard subdir.
        cfg.packages_add = entry.packages_add
        cfg.packages_drop = entry.packages_drop
        cfg.encrypt_root = self._resolve_encrypt_root(entry)
        cfg.build_subdir = entry.build_subdir

        # 4a. Per-image hostname (issue #229): the entry's own name wins; blank inherits
        #     the base (the single-image shape synthesize() wraps), and a blank base lets
        #     the builder derive its role name. Step 6's validate_identity runs
        #     validate_domain_name on whatever lands here, so a bad per-row name fails
        #     closed exactly like a bad base one.
        cfg.hostname = resolve_hostname(entry, self.base.hostname)

        # 4b. Per-node infra (scope:node) services — the Tor onion + node egress-VPN
        #     (docs/TOR-HIDDEN-SERVICE.md / EGRESS-VPN.md), ADDITIVE to the mesh-wide
        #     Network-page default already on the base. Emitted via the mechanism THIS
        #     platform's builder actually accepts, so a per-node selection is a REAL
        #     flag, never a silent no-op (the silently-does-nothing default this file guards against):
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
        #    emit_note_once, not a bare print: the Studio re-materializes on every
        #    preview refresh, so the identical note printed once per entry per refresh
        #    (76 copies in one operator session). Advice about a configuration is worth
        #    saying once.
        emit_note_once(resolve_installer_ui_default(cfg))
        if cfg.mode == "mesh":
            cfg.tailscale = True
            cfg.sso = True

        # 6. Fail closed — includes superdomain + the package-atom regex.
        cfg.validate_identity()
        return cfg

    def _apply_infra_services(self, cfg: ImageConfig, entry: WorklistEntry) -> None:
        """Fold the entry's per-node infra services onto ``cfg`` via each platform's
        real builder mechanism (see step 4b). Unknown / platform-inexpressible slugs
        are dropped — a per-node toggle never becomes a flag the builder ignores.

        The MESH-WIDE Tor default (``base.tor_onion_service``, the Network page's
        x86 flag — and what LocalCloudNodesPage imports from a saved mesh that ran
        TOR=1, #579) is folded here too, for the platforms that carry tor as a SLUG
        rather than a flag. Without it an rpi5 node lost the mesh-wide onion
        silently: the base platform is forced x86, so the flag rode the deepcopy and
        step 5's ``strip_platform_unsupported`` then cleared the x86-only field on
        the rpi5 entry, emitting nothing.

        The fold reaches NODE-class rows only. The onion is a cluster-node service:
        both stage4 builders drop a tor selection on a CLIENT role
        (``_tor_node_selected`` — #583), so folding the mesh-wide default into an
        rpi5-desktop row would emit ``--optional-services ... tor`` for an image that
        bakes nothing, and before #599 it baked net-vpn/tor + a linked reconcile agent
        into a person's desktop. A per-node selection the operator made on the row
        itself is left as it was (main's behaviour); only the IMPLICIT fold is gated."""
        plat_optional = OPTIONAL_SERVICES_BY_PLATFORM.get(entry.platform, ())
        wanted = list(entry.infra_services)
        if (ImageConfig._tri(cfg.tor_onion_service) == "on"
                and entry.platform not in _TOR_WITH_FLAG_PLATFORMS
                and image_class(cfg.mode, entry.role) == "node"
                and "tor" not in wanted):
            wanted.append("tor")                           # mesh-wide onion -> slug nodes
        for svc in wanted:
            if svc not in WORKLIST_INFRA_SERVICES:
                continue                                   # not a per-node infra slug
            if svc == "tor" and entry.platform in _TOR_WITH_FLAG_PLATFORMS:
                cfg.tor_onion_service = True               # x86: the dedicated --with-tor
            elif svc in INFRA_SERVICES_CHOICES and svc in plat_optional:
                # rpi5 (and x86 egress-vpn): a real --optional-services node service.
                cfg.optional_services = with_service_slug(cfg.optional_services, svc)
            # else: this platform's builder expresses neither -> drop (no dead flag).

    def _resolve_encrypt_root(self, entry: WorklistEntry) -> bool:
        """Resolve the entry's tri-state override to a concrete bool, against the
        worklist-wide default captured on the Home page (``base.encrypt_root``)."""
        return resolve_encrypt_root(entry, self.base.encrypt_root)


def load_any(path: str) -> tuple[ImageConfig, "WorklistConfig | None"]:
    """Load either shape from ``path``:

    * a worklist ENVELOPE (explicit top-level ``"schema"``) -> ``(base, WorklistConfig)``
    * anything else (a flat single-image config) -> ``(ImageConfig.from_dict(...), None)``

    The single loader both UIs and the headless ``--print-commands`` path share, so the
    118 matrix flat configs and all user saves keep loading unchanged while an envelope
    is never silently degraded (ImageConfig.load raises on the same discriminator)."""
    data = json_files.load(path)          # Notepad/PowerShell saves (BOM, UTF-16) too
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
