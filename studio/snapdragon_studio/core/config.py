"""ImageConfig — the single source of truth for a Snapdragon image build.

Every field maps to a build-x86-host-stage4.sh flag; ``to_cli_args()`` is the exact
translation the GUI and the build driver share, so the Studio UI can surface the WHOLE
flag surface without drifting from the script.
"""
from __future__ import annotations

import json
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
    env: str = "test"
    brand: str = "snapdragon"
    brand_title: str = "Snapdragon Systems"
    org: str = "Snapdragon-Systems"
    cluster_domain: str = "snapdragon.systems"
    local_user: str = "magus"
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

    # ---- (de)serialization -------------------------------------------------
    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

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

    def save(self, path: str) -> None:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(self.to_dict(), fh, indent=2)

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
    def to_cli_args(self) -> list[str]:
        """Build the build-x86-host-stage4.sh argument list. Only emits flags that
        differ from the script's own defaults, so the command stays readable."""
        # Reject injection-shaped identity values at the earliest boundary, before
        # they can reach the root-sourced brand.conf/home.conf or a sed replacement.
        self.validate_identity()
        a: list[str] = ["--role", self.role, "--env", self.env, "--local-user", self.local_user]
        if self.brand != "snapdragon":
            a += ["--brand", self.brand]
        if self.brand_title != "Snapdragon Systems":
            a += ["--brand-title", self.brand_title]
        if self.org != "Snapdragon-Systems":
            a += ["--org", self.org]

        # network / identity — emit explicit with/no so intent is unambiguous
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
        a += ["--bundle-source"] if self.bundle_source else ["--no-bundle-source"]
        if self.img_size:
            a += ["--img-size", str(self.img_size)]

        return a

    def to_command_string(self) -> str:
        import shlex
        return "./build-x86-host-stage4.sh -w OUT -j %d %s" % (
            self.jobs, " ".join(shlex.quote(x) for x in self.to_cli_args()))

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
