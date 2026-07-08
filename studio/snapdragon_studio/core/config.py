"""ImageConfig — the single source of truth for a Snapdragon image build.

Every field maps to a builder flag; ``to_cli_args()`` is the exact translation the
GUI and the build driver share, so the Studio UI can surface the WHOLE flag surface
without drifting from the scripts. The ``platform`` axis picks the builder:
x86 -> build-x86-host-stage4.sh, rpi5 -> build-rpi5-stage4.sh,
frite -> build-frite-stage4.sh, jetson -> build-jetson-stage4.sh (EXPERIMENTAL —
hardware validation pending; frite flag conventions + --role).
"""
from __future__ import annotations

import json
import shlex
from dataclasses import dataclass, field, asdict
from typing import Any

from .validate import (
    validate_accent_color,
    validate_brand,
    validate_brand_title,
    validate_domain_name,
    validate_home_backup,
    validate_home_device,
    validate_org,
    validate_username,
)


# Studio "mode" -> sensible default role. The wizard lets the user override role.
MODE_DEFAULT_ROLE = {
    "standalone": "standalone-thick",  # hardened personal desktop, no mesh/SSO
    "cloud": "desktop",                # branded tailnet client (mesh + SSO + admin keys)
    "mesh": "omnibus",                 # superadmin: a mesh node serving domains
}

# platform id -> builder script at the generator-repo root. All four are reachable
# in the docker path too (the whole generator dir is mounted at /src).
BUILDER_SCRIPTS = {
    "x86": "build-x86-host-stage4.sh",
    "rpi5": "build-rpi5-stage4.sh",
    "frite": "build-frite-stage4.sh",
    "jetson": "build-jetson-stage4.sh",
}

# GUI-facing platform labels (Jetson is scaffold-stage — see specs-jetson/README.md).
PLATFORM_LABELS = {
    "x86": "x86_64 host",
    "rpi5": "Raspberry Pi 5 (arm64)",
    "frite": "Libre AML-S805X La Frite family (arm64)",
    "jetson": "NVIDIA Jetson Orin (arm64) — EXPERIMENTAL: hardware validation pending",
}

# The full role catalog, grouped by Studio mode: (role id, supported platforms, label).
# THE all-options-in-all-menus source of truth for the Studio (specs-jetson/README.md).
ROLE_CHOICES = {
    "standalone": [
        ("standalone-thin", ("x86",), "Standalone thin — hardened LXDE desktop, no mesh/SSO"),
        ("standalone-thick", ("x86",), "Standalone thick — hardened full desktop, no mesh/SSO"),
        ("standalone-unaffiliated", ("x86",),
         "Unaffiliated desktop — plain Gentoo, no Snapdragon (zero branding/tooling baked)"),
        ("generic", ("rpi5",),
         "Generic arm64 server — plain Gentoo Raspberry Pi 5, unbranded (builder default role)"),
    ],
    "cloud": [
        ("laptop", ("x86",), "Laptop client — tailnet + SSO"),
        ("chromebook", ("x86",), "Chromebook client — tailnet + SSO"),
        ("desktop", ("x86",), "Desktop client — tailnet + SSO"),
        ("frite", ("frite",), "La Frite family arm64 client (board + live/installer flavor)"),
    ],
    "mesh": [
        ("pki", ("x86", "rpi5"), "PKI node — cluster certificate authority"),
        ("be", ("x86", "rpi5"), "Backend node"),
        ("fe", ("x86", "rpi5"), "Frontend node"),
        ("be+gpu", ("x86",), "Backend + GPU node"),
        ("omnibus", ("x86",), "Omnibus — every cluster role on one node"),
        ("edge_ai", ("x86", "jetson"), "Edge-AI node — GPU + OpenAI-compatible model API"),
        ("full", ("jetson",), "Jetson full-stack node — EXPERIMENTAL, hardware validation pending"),
        ("gpu-host", ("jetson",), "Jetson GPU host — EXPERIMENTAL, hardware validation pending"),
        ("jetson-desktop", ("jetson",), "Jetson desktop — EXPERIMENTAL, hardware validation pending"),
    ],
}

# The x86 role that builds a PLAIN, unaffiliated Gentoo desktop. The builder's role
# arm PRESETS everything (neutral gentoo identity, no bundled source, no mesh/SSO)
# and HARD-ERRORS on any brand/branding/bundle/seed/mesh/SSO/person flag — so the
# Studio raises the same conflicts instead of emitting them (fail loudly, like the
# builder), and emits the bare role + generic options only.
UNAFFILIATED_ROLE = "standalone-unaffiliated"

# build-rpi5-stage4.sh spells the node roles out (pki | backend | frontend).
RPI5_ROLE_MAP = {"be": "backend", "fe": "frontend"}
# The Studio disambiguates the jetson desktop role id; the builder takes --role desktop.
JETSON_ROLE_MAP = {"jetson-desktop": "desktop"}

FRITE_BOARDS = ("la-frite", "le-potato", "sweet-potato")
FRITE_FLAVORS = ("live", "installer", "both")
FRITE_DESKTOPS = ("light", "none")

# build-jetson-stage4.sh --board (Tegra234 Orin modules on the devkit carrier).
JETSON_BOARDS = ("orin-nano", "orin-nano-4gb", "orin-nx-8gb", "orin-nx-16gb")

# --env: what gets baked into the image's stack config (test | prod).
ENV_CHOICES = ("test", "prod")

# build-x86-host-stage4.sh's full documented --gpu-driver matrix (canonical names).
# "auto" is a Studio value, not a builder flag: to_cli_args() omits --gpu-driver so
# the builder resolves its own default (all-free on GPU roles, nvidia on edge_ai).
GPU_DRIVER_CHOICES = ("auto", "all-free", "nvidia-free", "nvidia",
                      "amd-free", "amd-pro", "intel-free", "intel-pro", "none")
# Vendor aliases the builder folds into canonical ids — mirrored so hwprofile /
# scanner values (e.g. "intel") select the right canonical GUI combo entry.
GPU_DRIVER_ALIASES = {"amd": "amd-free", "ati": "amd-free", "ati-free": "amd-free",
                      "ati-pro": "amd-pro", "intel": "intel-free"}

# The full cluster optional-service set (--optional-services slugs).
OPTIONAL_SERVICES_CHOICES = ("akkoma", "tuwunel", "phpbb", "games", "owncast", "tube",
                             "character-studio")

# Plaintext secrets that are NEVER persisted to a saved JSON config — they exist only
# for the live command line (the builder hashes them at build time).
SECRET_FIELDS = ("local_pass", "luks_pass")


@dataclass
class Domain:
    name: str = ""
    title: str = ""
    games: bool = False                # games.<domain> optional service
    optional_services: list[str] = field(default_factory=list)  # akkoma/tuwunel/phpbb/owncast/tor...


@dataclass
class User:
    username: str = ""
    domain: str = ""
    role: str = "user"                 # superadmin|admin|mod|user (+games roles)
    email: str = ""


@dataclass
class ImageConfig:
    # ── identity / mode ──
    mode: str = "standalone"           # standalone | cloud | mesh
    role: str = "standalone-thick"
    platform: str = "x86"              # x86 | rpi5 | frite | jetson -> BUILDER_SCRIPTS
    board: str = ""                    # frite: FRITE_BOARDS | jetson: JETSON_BOARDS
    flavor: str = ""                   # frite: live | installer | both
    env: str = "test"
    brand: str = "snapdragon"
    brand_title: str = "Snapdragon Systems"
    org: str = "Snapdragon-Systems"
    cluster_domain: str = "snapdragon.systems"
    local_user: str = "magus"
    local_pass: str = ""               # --local-pass (SECRET — never saved; live cmd only)
    # ── network / identity plane ──
    tailscale: bool = False            # --with-tailscale / --no-tailscale
    sso: bool = False                  # --with-sso / --no-sso
    # ── hardware ──
    gpu_driver: str = "auto"           # auto|nvidia|amd-free|amd-pro|intel|none
    hw_profile: str = ""               # a hwprofiles/<id> preset (sets gpu/kernel/firmware)
    kernel_builtin: bool = False       # --kernel-builtin
    enable_wifi: bool = False          # --enable-wifi
    enable_bluetooth: bool = False     # --enable-bluetooth
    # ── branding ──
    theme: str = ""                    # --theme NAME
    branding_dir: str = ""             # --branding-dir DIR
    wallpaper: str = ""
    grub_background: str = ""
    login_background: str = ""
    brand_logo: str = ""
    accent_color: str = ""
    color_scheme: str = ""
    brand_locked: bool = False
    # ── egress VPN ──
    egress_vpn: str = ""               # --egress-vpn FILE
    egress_vpn_locked: bool = False
    # ── network/host security stack ──
    proxy_stack: str = "auto"          # auto|on|off — Squid+Privoxy+Firefox (desktops)
    snort: bool = True                 # Snort IDS (default-on, all images)
    aide: bool = False                 # AIDE file-integrity IDS (opt-in)
    root_login: str = "no"             # --permit-root-login: no (DEFAULT, hardened) | prohibit-password | yes
    # ── edge-AI inference (GPU cluster roles: be+gpu / omnibus / edge_ai) ──
    edge_ai_service: bool = False      # add the edge-ai model API to a GPU role (edge_ai role auto-has it)
    edge_ai_runtime: str = "ollama"    # ollama | vllm
    edge_ai_models: str = ""           # comma list of models to PRELOAD (empty = builder default)
    edge_ai_model_default: str = ""    # default model when an OpenAI request omits one
    edge_ai_analysis: bool = False     # also bake the edge-ai-analysis task API (image/log verdicts; separate image)
    # ── Tor v3 onion (hidden) service — node-scoped optional, default off ──
    tor_onion_service: bool = False    # --with-tor: expose the in-cluster fe-gateway as a v3 .onion
    # ── Character Studio (VN) frontend remote — OPTIONAL, default off (admin gate) ──
    character_studio: bool = False     # --with-character-studio: VN character-studio remote at /character-studio
    # ── cluster optional services + games (node-scoped) ──
    optional_services: list[str] = field(default_factory=list)  # --optional-services slugs
    enable_games: bool = False         # --enable-games (Game Studio + games.<domain>)
    # ── client desktop weight / gaming delivery (x86 client roles; frite: light|none) ──
    desktop: str = ""                  # --desktop: x86 thin|full; frite light|none ("" = default)
    steam: str = ""                    # --steam native|flatpak|none ("" = builder default)
    # ── root-disk encryption (installer LUKS2 FDE) ──
    encrypt_root: bool = False         # --encrypt-root
    luks_pass: str = ""                # --luks-pass (SECRET — never saved; live cmd only)
    unlock_keyfile: str = ""           # --unlock-keyfile boot|login ("" = off)
    unlock_yubikey: str = ""           # --unlock-yubikey boot|login ("" = off)
    # ── home provisioning ──
    home_mode: str = "create"          # create|adopt|archive|restore
    home_device: str = ""
    home_backup: str = ""
    home_encrypted: bool = False
    home_seed_code: str = "none"       # none|repos|stack|mesh
    # ── installer / ISO ──
    installer_ui: str = "all"          # cli|ncurses|calamares|all
    cached: bool = False               # --cached / --uncached
    live_toram: bool = True            # --live-toram / --no-live-toram
    bundle_source: bool = True         # --bundle-source / --no-bundle-source
    img_size: int = 0                  # --img-size MiB (0 = role default)
    # ── admin-supplied secrets (cloud/mesh) ──
    keyzip: str = ""                   # an admin key-zip (keys/certs/egress) for this user's domain
    # ── superadmin mesh ──
    domains: list[Domain] = field(default_factory=list)
    users: list[User] = field(default_factory=list)
    # ── build ──
    output_dir: str = ""
    jobs: int = 8
    compress: bool = False             # --compress: xz -9 the finished image(s)
    resume: bool = False               # --resume: reuse an existing sysroot
    extra_flags: str = ""              # escape hatch — shlex-split, appended verbatim

    # ---- (de)serialization -------------------------------------------------
    def to_dict(self, include_secrets: bool = False) -> dict[str, Any]:
        """Serialize; plaintext secrets (SECRET_FIELDS) are BLANKED unless the caller
        explicitly opts in — a saved JSON config must never carry a password."""
        d = asdict(self)
        if not include_secrets:
            for k in SECRET_FIELDS:
                d[k] = ""
        return d

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "ImageConfig":
        d = dict(d)
        dom_f = set(Domain.__dataclass_fields__)   # filter unknown nested keys (forward-compat)
        usr_f = set(User.__dataclass_fields__)
        # tolerate "domains": null / "users": null and unknown nested keys
        d["domains"] = [Domain(**{k: v for k, v in x.items() if k in dom_f}) if isinstance(x, dict) else x
                        for x in (d.get("domains") or [])]
        d["users"] = [User(**{k: v for k, v in x.items() if k in usr_f}) if isinstance(x, dict) else x
                      for x in (d.get("users") or [])]
        known = set(cls.__dataclass_fields__)  # type: ignore[attr-defined]
        return cls(**{k: v for k, v in d.items() if k in known})

    def save(self, path: str) -> list[str]:
        """Write the config JSON (secrets blanked). Returns human-readable warnings
        for any secret that was set but NOT persisted, so the UI can surface it."""
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(self.to_dict(), fh, indent=2)
        return [f"{k.replace('_', '-')} was NOT saved (plaintext secret) — re-enter it "
                "before building from this config" for k in SECRET_FIELDS if getattr(self, k)]

    @classmethod
    def load(cls, path: str) -> "ImageConfig":
        with open(path, encoding="utf-8") as fh:
            return cls.from_dict(json.load(fh))

    # ---- identity validation (fail-closed) ---------------------------------
    def validate_identity(self) -> None:
        """Allowlist every identity field that flows into a root-sourced KEY=VALUE
        file (brand.conf / home.conf) or a sed replacement in the generator.

        Fail-closed: raise IdentityValidationError on any value that is not a
        known-safe shape, BEFORE it can reach --brand/--org/--local-user/--home-*.
        Defense-in-depth that does not rely on the build script's own escaping.
        """
        # always emitted
        validate_username(self.local_user)
        # brand / org / brand_title flow into brand.conf (sourced as root)
        validate_brand(self.brand)
        validate_org(self.org)
        validate_brand_title(self.brand_title)
        validate_accent_color(self.accent_color)
        # cluster_domain + per-domain names flow into --domains / the mesh manifest
        validate_domain_name(self.cluster_domain)
        for d in self.domains:
            if getattr(d, "name", ""):
                validate_domain_name(d.name)
        # home provisioning fields flow into home.conf (sourced as root)
        if self.home_device:
            validate_home_device(self.home_device)
        if self.home_backup:
            validate_home_backup(self.home_backup)

    # ---- the canonical flag translation ------------------------------------
    @property
    def builder_script(self) -> str:
        try:
            return BUILDER_SCRIPTS[self.platform or "x86"]
        except KeyError:
            raise ValueError(f"unknown platform: {self.platform!r} "
                             f"(known: {', '.join(BUILDER_SCRIPTS)})") from None

    def to_cli_args(self) -> list[str]:
        """Build the argument list for this platform's builder script. Only emits
        flags that differ from the script's own defaults, so the command stays
        readable — and only flags THAT builder parses (each script has its own
        surface). The extra_flags escape hatch is appended verbatim (shlex-split)
        so every CLI option stays expressible even if unfielded."""
        # Reject injection-shaped identity values at the earliest boundary, before
        # they can reach the root-sourced brand.conf/home.conf or a sed replacement.
        self.validate_identity()
        plat = self.platform or "x86"
        if plat == "x86":
            a = self._x86_args()
        elif plat == "rpi5":
            a = self._rpi5_args()
        elif plat == "frite":
            a = self._frite_args()
        elif plat == "jetson":
            a = self._jetson_args()
        else:
            raise ValueError(f"unknown platform: {self.platform!r} "
                             f"(known: {', '.join(BUILDER_SCRIPTS)})")
        if self.extra_flags:
            a += shlex.split(self.extra_flags)
        return a

    def _brand_args(self) -> list[str]:
        """The brand-identity flags every builder parses identically."""
        a: list[str] = []
        if self.brand != "snapdragon":
            a += ["--brand", self.brand]
        if self.brand_title != "Snapdragon Systems":
            a += ["--brand-title", self.brand_title]
        if self.org != "Snapdragon-Systems":
            a += ["--org", self.org]
        return a

    def _arm_common_args(self) -> list[str]:
        """Flags shared by the arm64 builders (rpi5/frite/jetson) beyond the brand
        block: env baking, mesh opt-out, radios, root login, image sizing/finish."""
        a: list[str] = ["--env", self.env]
        a += self._brand_args()
        if self.cluster_domain != "snapdragon.systems":
            a += ["--cluster-domain", self.cluster_domain]
        # The arm builders have no --with/--no-tailscale pair; mesh is on unless skipped.
        if not self.tailscale:
            a += ["--skip-mesh"]
        if self.enable_wifi:
            a += ["--enable-wifi"]
        if self.enable_bluetooth:
            a += ["--enable-bluetooth"]
        if self.root_login and self.root_login != "no":
            a += ["--permit-root-login", self.root_login]
        if self.img_size:
            a += ["--img-size", str(self.img_size)]
        if self.compress:
            a += ["--compress"]
        if self.resume:
            a += ["--resume"]
        return a

    def _rpi5_args(self) -> list[str]:
        """build-rpi5-stage4.sh — arm64 SERVER node: pki | backend | frontend."""
        a = ["--role", RPI5_ROLE_MAP.get(self.role, self.role)]
        a += self._arm_common_args()
        if self.optional_services:
            # SPACE-separated: the builders word-split OPTIONAL_SERVICES on IFS
            # whitespace (it stays ONE argv element — shlex.quote on print).
            a += ["--optional-services", " ".join(self.optional_services)]
        if self.enable_games:
            a += ["--enable-games"]
        if self.character_studio:
            a += ["--with-character-studio"]
        return a

    def _frite_args(self) -> list[str]:
        """build-frite-stage4.sh — arm64 CLIENT: board + flavor, no --role."""
        a: list[str] = ["--board", self.board or "la-frite", "--flavor", self.flavor or "both"]
        if self.desktop:               # light | none (frite's lean LXDE toggle)
            a += ["--desktop", self.desktop]
        a += self._arm_common_args()
        return a

    def _jetson_args(self) -> list[str]:
        """build-jetson-stage4.sh — arm64 Tegra edge-AI node. EXPERIMENTAL (hardware
        validation pending): frite flag conventions + --role edge_ai|full|gpu-host|
        desktop and --board JETSON_BOARDS (specs-jetson/README.md). Anything beyond
        that goes via extra_flags."""
        a = ["--role", JETSON_ROLE_MAP.get(self.role, self.role)]
        if self.board:                 # Orin module/carrier ("" = builder default)
            a += ["--board", self.board]
        a += self._arm_common_args()
        return a

    def _check_unaffiliated_conflicts(self) -> None:
        """Mirror build-x86-host-stage4.sh's standalone-unaffiliated HARD CONFLICTS.

        The role presets a plain, brand-free Gentoo desktop; every field that would
        bake a brand identity, branding assets, the bundled Snapdragon source, the
        stack seed, or platform machinery (mesh/SSO/person-device identity) into the
        image raises ValueError HERE — so --print-command and the GUI preview fail
        loudly with the same contract the builder enforces (it exits non-zero on the
        equivalent flags; an explicit --brand gentoo errors too — the builder forces
        the neutral identity itself)."""
        conflicts: list[str] = []
        if (self.brand != "snapdragon" or self.brand_title != "Snapdragon Systems"
                or self.org != "Snapdragon-Systems"):
            conflicts.append("a brand identity (brand/brand_title/org — the builder "
                             "forces the neutral gentoo identity itself)")
        assets = [name for name, val in (
            ("theme", self.theme), ("branding_dir", self.branding_dir),
            ("wallpaper", self.wallpaper), ("grub_background", self.grub_background),
            ("login_background", self.login_background), ("brand_logo", self.brand_logo),
            ("accent_color", self.accent_color), ("color_scheme", self.color_scheme),
        ) if val] + (["brand_locked"] if self.brand_locked else [])
        if assets:
            conflicts.append("branding assets (" + ", ".join(assets) + " — nothing to theme against)")
        # bundle_source is NOT flagged here: its dataclass default is True (the
        # branded-standalone self-hosting default), so an untouched config would
        # false-conflict. The wizard clears it on role selection and _x86_args()
        # normalizes it to False for this role (never emitting the flag pair) —
        # mirroring the builder, which only errors on an EXPLICIT --bundle-source.
        if self.home_seed_code and self.home_seed_code != "none":
            conflicts.append("home_seed_code (seeds the Snapdragon stack into the home)")
        if self.tailscale:
            conflicts.append("tailscale (the tailnet is Snapdragon platform machinery)")
        if self.sso:
            conflicts.append("sso (Casdoor SSO is Snapdragon platform machinery)")
        if self.mode in ("cloud", "mesh"):
            conflicts.append(f"mode={self.mode!r} (emits --person-role/--domains — "
                             "person-device identity is platform machinery)")
        if conflicts:
            raise ValueError(
                "role standalone-unaffiliated builds a plain Gentoo desktop with ZERO "
                "Snapdragon affiliation, but this config sets " + "; ".join(conflicts)
                + ". Clear the conflicting field(s) — the builder hard-errors on the "
                "same flags.")

    def _x86_args(self) -> list[str]:
        unaffiliated = self.role == UNAFFILIATED_ROLE
        if unaffiliated:
            self._check_unaffiliated_conflicts()
        a: list[str] = ["--role", self.role, "--env", self.env, "--local-user", self.local_user]
        if self.local_pass:
            # plaintext ONLY on the live command line — never persisted (SECRET_FIELDS)
            a += ["--local-pass", self.local_pass]
        if not unaffiliated:
            a += self._brand_args()

            # network / identity — emit explicit with/no so intent is unambiguous.
            # (unaffiliated: the role PRESETS no-mesh/no-SSO/no-bundled-source; the
            # conflict check above already rejected any opt-in, so emit nothing.)
            a += ["--with-tailscale"] if self.tailscale else ["--no-tailscale"]
            a += ["--with-sso"] if self.sso else ["--no-sso"]

        # cloud/mesh: tie the client image to its domain + identity role (FD-08). The
        # cluster domain is carried in --domains/KEYS-USB; there is no --cluster-domain flag.
        if self.mode in ("cloud", "mesh"):
            domnames = [d.name for d in self.domains if getattr(d, "name", "")]
            if domnames:
                a += ["--domains", ",".join(domnames)]
            role = "superadmin" if self.mode == "mesh" else (self.users[0].role if self.users else "user")
            a += ["--person-role", role]

        # client desktop weight (thin|full) + Steam delivery (native|flatpak|none) —
        # "" = builder default, so only explicit choices are emitted
        if self.desktop:
            a += ["--desktop", self.desktop]
        if self.steam:
            a += ["--steam", self.steam]

        # hardware
        if self.gpu_driver and self.gpu_driver != "auto":
            a += ["--gpu-driver", self.gpu_driver]
        if self.kernel_builtin:
            a += ["--kernel-builtin"]
        if self.enable_wifi:
            a += ["--enable-wifi"]
        if self.enable_bluetooth:
            a += ["--enable-bluetooth"]

        # branding
        if self.theme:
            a += ["--theme", self.theme]
        if self.branding_dir:
            a += ["--branding-dir", self.branding_dir]
        for flag, val in (("--wallpaper", self.wallpaper), ("--grub-background", self.grub_background),
                          ("--login-background", self.login_background), ("--brand-logo", self.brand_logo),
                          ("--accent-color", self.accent_color), ("--color-scheme", self.color_scheme)):
            if val:
                a += [flag, val]
        if self.brand_locked:
            a += ["--brand-locked"]

        # egress VPN
        if self.egress_vpn:
            a += ["--egress-vpn", self.egress_vpn]
            if self.egress_vpn_locked:
                a += ["--egress-vpn-locked"]

        # network/host security stack
        if self.proxy_stack == "on":
            a += ["--proxy-stack"]
        elif self.proxy_stack == "off":
            a += ["--no-proxy-stack"]
        a += ["--snort"] if self.snort else ["--no-snort"]
        if self.aide:
            a += ["--with-aide"]
        # Root SSH login — hardened DEFAULT is "no" (locked); opt back in per build.
        if self.root_login and self.root_login != "no":
            a += ["--permit-root-login", self.root_login]

        # edge-AI inference service (GPU cluster roles). The edge_ai role auto-selects
        # the service; be+gpu/omnibus opt in with --with-edge-ai. Model-library knobs
        # (runtime/preload/default) are emitted whenever the service is in play, so the
        # mesh model catalog is image-configurable from the Studio wizard.
        if self.edge_ai_service and self.role != "edge_ai":
            a += ["--with-edge-ai"]
        if self.role == "edge_ai" or self.edge_ai_service:
            if self.edge_ai_runtime and self.edge_ai_runtime != "ollama":
                a += ["--edge-ai-runtime", self.edge_ai_runtime]
            if self.edge_ai_models:
                a += ["--edge-ai-models", self.edge_ai_models]
            if self.edge_ai_model_default:
                a += ["--edge-ai-model-default", self.edge_ai_model_default]
        # the analysis API (folds edge-ai too, its dependency)
        if self.edge_ai_analysis:
            a += ["--with-edge-ai-analysis"]

        # Tor v3 onion (hidden) service (node-scoped; any cloud/mesh cluster role).
        # No-op on a CLIENT/standalone role (the builder guards on !ROLE_CLIENT).
        if self.tor_onion_service:
            a += ["--with-tor"]

        # Character Studio (VN) frontend remote — OPTIONAL, DEFAULT-OFF (admin gate).
        # Folds 'character-studio' into OPTIONAL_SERVICES. Meaningful only for a
        # cloud/mesh cluster build (the builder guards on !ROLE_CLIENT / no-op on a
        # standalone desktop with no cluster tree).
        if self.character_studio:
            a += ["--with-character-studio"]

        # cluster optional services + the games stack (gate_optional_services() prunes
        # what stays unselected; --enable-games folds 'games' in + the Game Studio).
        # SPACE-separated: the builders word-split OPTIONAL_SERVICES on IFS
        # whitespace (it stays ONE argv element — shlex.quote on print).
        if self.optional_services:
            a += ["--optional-services", " ".join(self.optional_services)]
        if self.enable_games:
            a += ["--enable-games"]

        # root-disk encryption (installer LUKS2 FDE) + unlock factors
        if self.encrypt_root:
            a += ["--encrypt-root"]
        if self.luks_pass:
            # plaintext ONLY on the live command line — never persisted (SECRET_FIELDS)
            a += ["--luks-pass", self.luks_pass]
        if self.unlock_keyfile:
            a += ["--unlock-keyfile", self.unlock_keyfile]
        if self.unlock_yubikey:
            a += ["--unlock-yubikey", self.unlock_yubikey]

        # home
        if self.home_mode and self.home_mode != "create":
            a += ["--home-mode", self.home_mode]
        if self.home_device:
            a += ["--home-device", self.home_device]
        if self.home_backup:
            a += ["--home-backup", self.home_backup]
        if self.home_encrypted:
            a += ["--home-encrypted"]
        if self.home_seed_code and self.home_seed_code != "none":
            a += ["--home-seed-code", self.home_seed_code]

        # installer / ISO
        if self.installer_ui:
            a += ["--installer-ui", self.installer_ui]
        a += ["--cached"] if self.cached else ["--uncached"]
        a += ["--live-toram"] if self.live_toram else ["--no-live-toram"]
        if not unaffiliated:  # the unaffiliated role presets no-bundled-source itself
            a += ["--bundle-source"] if self.bundle_source else ["--no-bundle-source"]
        if self.img_size:
            a += ["--img-size", str(self.img_size)]
        if self.compress:
            a += ["--compress"]
        if self.resume:
            a += ["--resume"]

        return a

    def to_command_string(self) -> str:
        return "./%s -w OUT -j %d %s" % (
            self.builder_script, self.jobs, " ".join(shlex.quote(x) for x in self.to_cli_args()))

    # ---- superadmin mesh manifest -----------------------------------------
    def mesh_manifest(self) -> dict[str, Any]:
        """The domains + users a superadmin defined, as a portable manifest. Consumed by
        cluster provisioning (Casdoor seed + per-domain config) — separate from the image
        build, which is why it is emitted as its own artifact rather than CLI flags."""
        return {
            "brand": self.brand, "brand_title": self.brand_title, "org": self.org,
            "cluster_domain": self.cluster_domain,
            "domains": [asdict(d) for d in self.domains],
            "users": [asdict(u) for u in self.users],
        }

    def write_mesh_manifest(self, output_dir: str) -> str:
        import os
        os.makedirs(output_dir, exist_ok=True)
        path = os.path.join(output_dir, "snapdragon-mesh-manifest.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(self.mesh_manifest(), fh, indent=2)
        return path
