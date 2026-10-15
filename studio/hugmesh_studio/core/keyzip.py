"""Admin key-zip drop-in.

A domain admin with rights to a user's domain generates a zip for that user containing
the bits the user should NOT have to author: the org CA / Secure-Boot certs, the domain
config, an egress-VPN conf, and optional branding. The user drops it into the Studio;
this module validates it (no path traversal, sane size), extracts it to a staging dir,
and reports what it found so the wizard can wire it into the ImageConfig.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import zipfile
from dataclasses import dataclass, field

from . import local_login_agent
from .config import field_in_scope, image_class
from .validate import (
    IdentityValidationError,
    validate_brand,
    validate_brand_title,
    validate_domain_name,
    validate_org,
)

MAX_TOTAL = 512 * 1024 * 1024   # 512 MiB extracted ceiling
MAX_FILES = 5000

#: The one environment override the whole Studio state family honours
#: (``core.instance.state_dir``, ``core.build_sessions``, ``core.crashlog``). The
#: key-zip host dirs were the ONE member of that family with no override point at all: they
#: were hard-coded to ``os.path.expanduser("~")``, so nothing — no test, no second
#: profile, no sandbox — could point them anywhere else. Since :func:`extract`
#: *recursively deletes* its staging dir before unpacking, "no override point" meant the
#: studio test suite wiped the operator's real ``~/.hugmesh/keyzip`` (staged
#: Secure-Boot signing material and the offline vault bundle) on every run, green.
STATE_DIR_ENV = "HUGMESH_STUDIO_STATE_DIR"

#: Written into a staging dir the moment :func:`extract` claims it. Its only job is
#: to answer "did THIS module create this directory?" before anything is deleted.
STAGING_MARKER = ".hugmesh-keyzip-staging"


def _hugmesh_home() -> str:
    """Base dir for the key-zip host-side scratch dirs.

    ``$HUGMESH_STUDIO_STATE_DIR`` wins when set — the same override the rest of the
    state family reads — so an isolated state dir isolates key-zip staging too.
    """
    return os.environ.get(STATE_DIR_ENV) or os.path.join(
        os.path.expanduser("~"), ".hugmesh")


def staging_dir() -> str:
    """Where an imported key-zip is unpacked. NOTE: :func:`extract` clears this dir,
    so it must never be a path holding anything but a previous extraction."""
    return os.path.join(_hugmesh_home(), "keyzip")


def fetch_zip_path() -> str:
    """Where a key-zip fetched from a remote-config link is written before import."""
    return os.path.join(_hugmesh_home(), "keyzip-fetch", "admin-config.zip")


@dataclass
class KeyZipContents:
    staging_dir: str
    has_keys: bool = False
    has_branding: bool = False
    egress_conf: str = ""
    domain_conf: str = ""
    # Secure-Boot signing chain (G5). keys_usb_dir is a directory laid out like the
    # KEYS USB the builder expects (--keys-usb DIR reads DIR/Keys/kernel_key.{pem,der},
    # build-x86-host-stage4.sh:1183-1189); secureboot_key/_cert are LOOSE key files
    # found outside that layout, threaded via --secureboot-key/--secureboot-cert.
    keys_usb_dir: str = ""
    secureboot_key: str = ""
    secureboot_cert: str = ""
    files: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def summary(self) -> str:
        bits = []
        if self.has_keys:
            bits.append("keys/certs")
        if self.keys_usb_dir or self.secureboot_key or self.secureboot_cert:
            bits.append("Secure-Boot signing key")
        if self.has_branding:
            bits.append("branding")
        if self.egress_conf:
            bits.append("egress-VPN")
        if self.domain_conf:
            bits.append("domain config")
        return ", ".join(bits) or "(nothing recognized)"

    def apply_to(self, cfg) -> None:
        """Wire recognized payloads into an ImageConfig.

        SCOPE-GATED (finding 6). Every assignment here is an INJECTION: the payload comes
        from the admin's zip, not from anything the operator ticked, and KeyZipPage is
        visited in mesh mode. So an admin zip carrying an egress conf silently set
        cfg.egress_vpn on EVERY mesh node — with no operator action anywhere and no widget
        to see it on. The x86 builder then warns "egress VPN is a desktop/tailnet-node
        feature — ignoring", and IT MEANS ONLY THE STAGING: the package leg (net-vpn/
        wireguard-tools, or networkmanager-openvpn + openvpn for a .ovpn) and the
        CONFIG_WIREGUARD kernel fragment are NOT role-gated, so the VPN userspace was
        emerged into headless nodes that will never use it.

        Skipping an out-of-scope injection is NOT the "silently corrected an explicit
        value" anti-pattern the WARN tier exists to prevent — nobody chose this value for
        this image. It IS recorded in ``warnings`` (the channel the wizard already shows),
        so the operator is told the payload was recognized and deliberately not applied.
        """
        def _inject(fld: str, value: str, what: str) -> None:
            if field_in_scope(fld, cfg):
                setattr(cfg, fld, value)
            else:
                self.warnings.append(
                    f"{what} found in the key-zip but NOT applied: it is out of scope for "
                    f"this {image_class(cfg.mode, cfg.role)}-class image "
                    f"(--role {cfg.role}{f', {cfg.mode} mode' if cfg.mode else ''}). "
                    f"The builder would ignore it while still baking its cost into the image.")

        if self.has_branding:
            _inject("branding_dir", os.path.join(self.staging_dir, "branding"), "Branding")
        if self.egress_conf:
            _inject("egress_vpn", self.egress_conf, "Egress-VPN conf")
        if self.domain_conf:
            _apply_domain_conf(self.domain_conf, cfg, self.warnings)
        # Secure-Boot signing chain (G5): the admin zip already ships the fleet SB
        # key/cert — thread them into the build so the image signs with the key
        # ALREADY ENROLLED in the fleet's firmware instead of a per-build throwaway
        # org key. Prefer the whole KEYS-USB layout (one --keys-usb flag covers key +
        # cert + the provisioning payload); fall back to explicit loose-file paths.
        if self.keys_usb_dir:
            cfg.keys_usb = self.keys_usb_dir
        else:
            if self.secureboot_key:
                cfg.secureboot_key = self.secureboot_key
            if self.secureboot_cert:
                cfg.secureboot_cert = self.secureboot_cert


def _safe_member(name: str) -> bool:
    # reject absolute paths, parent-traversal, Windows drive-letters and UNC paths
    n = name.replace("\\", "/")
    if name.startswith(("/", "\\")) or n.startswith(("/", "//")):
        return False
    if ".." in n.split("/"):
        return False
    if re.match(r"^[A-Za-z]:", name):     # C:\... drive-letter
        return False
    return True


def _looks_wireguard(path: str) -> bool:
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            head = fh.read(4096)
        return "[Interface]" in head or "[Peer]" in head
    except OSError:
        return False


def _claim_staging(path: str) -> None:
    """Leave ``path`` existing and EMPTY, deleting only a directory this module owns.

    :func:`extract` has to start clean, or a previous zip's files get mis-classified
    into this result. "Start clean" used to be an unconditional
    ``shutil.rmtree(staging_dir, ignore_errors=True)`` on whatever path the caller
    handed in, which made a wrong path a silent recursive delete of real data.

    A directory is only ever deleted when it is empty, carries this module's
    :data:`STAGING_MARKER`, or IS the app's own :func:`staging_dir` (adopted once, so
    installs that staged a key-zip before the marker existed keep working). Anything
    else raises ``ValueError`` before a single file is removed. So does a path that
    exists but is not a directory (a regular file, a dangling symlink): the old
    ``rmtree(ignore_errors=True)`` skipped it silently and ``makedirs`` then died with
    a bare ``FileExistsError``.
    """
    if not path or not path.strip():
        raise ValueError("key-zip staging dir must be a real path, not empty")
    if os.path.lexists(path) and not os.path.isdir(path):
        raise ValueError(f"key-zip staging path is not a directory: {path}")
    if os.path.isdir(path) and os.listdir(path):
        owned = os.path.exists(os.path.join(path, STAGING_MARKER))
        canonical = os.path.abspath(path) == os.path.abspath(staging_dir())
        if not owned and not canonical:
            raise ValueError(
                f"refusing to clear {path}: it is not a key-zip staging dir (no "
                f"{STAGING_MARKER} marker) and it is not empty. Extracting here "
                f"would have recursively deleted its contents.")
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, STAGING_MARKER), "w", encoding="utf-8") as fh:
        fh.write("hugmesh-studio key-zip staging — recreated on every import.\n")


def extract(zip_path: str, staging_dir: str) -> KeyZipContents:
    # start clean so a previous zip's files can't be mis-classified into this result
    _claim_staging(staging_dir)
    c = KeyZipContents(staging_dir=staging_dir)
    with zipfile.ZipFile(zip_path) as zf:
        infos = zf.infolist()
        if len(infos) > MAX_FILES:
            raise ValueError(f"key-zip has too many entries ({len(infos)} > {MAX_FILES})")
        total = sum(i.file_size for i in infos)
        if total > MAX_TOTAL:
            raise ValueError(f"key-zip too large when extracted ({total} bytes)")
        for info in infos:
            if not _safe_member(info.filename):
                c.warnings.append(f"skipped unsafe path: {info.filename}")
                continue
            zf.extract(info, staging_dir)
            c.files.append(info.filename)

    # classify what landed
    for root, _dirs, files in os.walk(staging_dir):
        rel = os.path.relpath(root, staging_dir)
        low = rel.lower()
        if low.startswith("keys") or low.startswith("keys-out") or low == "secureboot":
            c.has_keys = c.has_keys or bool(files)
        if low.startswith("branding"):
            c.has_branding = True
        # Secure-Boot signing material (G5). A dir named exactly "Keys" holding
        # kernel_key.{pem,der} means the zip carries the builder's KEYS-USB layout —
        # its PARENT is what --keys-usb DIR expects (the builder resolves
        # DIR/Keys/kernel_key.* itself, and tolerates either file alone).
        if (os.path.basename(root) == "Keys" and not c.keys_usb_dir
                and ("kernel_key.pem" in files or "kernel_key.der" in files)):
            c.keys_usb_dir = os.path.dirname(root)
        for f in files:
            fl = f.lower()
            full = os.path.join(root, f)
            # loose kernel_key.{pem,der} outside a Keys/ layout: thread the explicit
            # --secureboot-key/--secureboot-cert paths instead (apply_to prefers the
            # KEYS-USB layout when both shapes are present).
            if os.path.basename(root) != "Keys":
                if not c.secureboot_key and fl == "kernel_key.pem":
                    c.secureboot_key = full
                if not c.secureboot_cert and fl == "kernel_key.der":
                    c.secureboot_cert = full
            if not c.egress_conf:
                is_egress = fl.endswith((".ovpn", ".nmconnection"))
                if not is_egress and fl.endswith(".conf"):
                    # a .conf is a WireGuard egress conf only if named like one or its
                    # contents look like wg-quick (avoid grabbing unrelated .conf files)
                    is_egress = fl.startswith(("wg", "wireguard")) or _looks_wireguard(full)
                if is_egress:
                    c.egress_conf = full
            if not c.domain_conf and fl in ("domain.conf", "domain.json"):
                c.domain_conf = full
    return c


def _apply_domain_conf(path: str, cfg, warnings: list | None = None) -> None:
    """Read a simple KEY=VALUE (or JSON) domain config and set brand/domain fields.

    The domain.conf comes from a (possibly compromised) domain admin's key-zip, so
    each value is allowlisted BEFORE it is set on the ImageConfig — these fields are
    later written into a root-sourced brand.conf and into sed replacements by the
    generator, where an injection value (quote / ``$()`` / ``;`` / ``|`` / newline)
    would run as root. Reject (skip + warn), never silently set, a bad value.
    """
    warn = warnings if warnings is not None else []
    try:
        if path.endswith(".json"):
            import json
            with open(path, encoding="utf-8") as fh:
                d = json.load(fh)
            if not isinstance(d, dict):   # a JSON array/scalar is not a domain config
                return
        else:
            d = {}
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        d[k.strip()] = v.strip().strip('"')
    except (OSError, ValueError):
        return
    # (key, attr, validator) — validator rejects anything not known-safe.
    mapping = (
        ("BRAND", "brand", validate_brand),
        ("BRAND_TITLE", "brand_title", validate_brand_title),
        ("ORG", "org", validate_org),
        ("CLUSTER_DOMAIN", "cluster_domain", validate_domain_name),
        ("DOMAIN", "cluster_domain", validate_domain_name),
    )
    for key, attr, validator in mapping:
        value = d.get(key)
        if not value:
            continue
        value = str(value)
        try:
            validator(value)
        except IdentityValidationError:
            warn.append(f"rejected unsafe {key} in domain config: {value!r}")
            continue
        setattr(cfg, attr, value)


# ── OPT-IN: mirror human-loginable KEYS credentials into the local-login manifest ──
#
# USER-APPROVED MECHANISM (verbatim, implemented exactly): "when a KEYS USB is
# extracted in Studio, write human-loginable role credentials (superadmin, admin —
# never DB passwords, mTLS keys, or other machine secrets) into the local roles.json
# manifest, gated behind an explicit opt-in flag (default OFF) so it never happens
# silently."
#
# The only KEYS payload this reads is the offline cluster-secrets bundle
# (``vault/secrets.json``, produced by scripts/gen-cluster-secrets.sh — see
# keys-template/vault/README.md for the full shape). Everything below is a
# deliberate, conservative classification of that file's contents:
#
# INCLUDED (human-loginable — a person types this into Casdoor):
#   * ``<brand>-pki`` -> ``casdoor-superadmin`` -> {username, password}
#     The platform SUPERADMIN bootstrap login. Unambiguous: it exists for a human
#     operator to log into Casdoor with.
#
# EXCLUDED, even though present in the very same file (when in doubt, exclude):
#   * ``<brand>-pki`` -> ``casdoor-admin`` -> {username, password} — Casdoor's
#     built-in "admin" superuser. Plaintext and technically loginable, BUT
#     gen-cluster-secrets.sh's own comment ties its purpose to "the casdoor-init
#     Job's API login" — a machine-driven bootstrap step, not a routine human
#     login. Ambiguous == excluded.
#   * ``<brand>-games`` -> ``casdoor-games-admin`` (CASDOOR_GAMES_ADMIN_PLAIN) —
#     same pattern as casdoor-admin (games-realm twin); excluded for the same
#     reason.
#   * every other secrets.json entry: DB owner/app passwords (casdoor-db,
#     clickhouse-auth, federation/admin-bff/mod-bff/user-bff/forum/wiki/phpbb/
#     akkoma-db, route-access-db-roles, uptrace-auth), OAuth client secrets
#     (casdoor-google/-github/-discord, casdoor-app-secrets), MFA/custody/HS-token
#     encryption keys, the BFF internal token, mail creds — all machine/service
#     credentials, never human-loginable, never included.
#   * ``users.json`` (password_hash / ssh_authorized_keys) and ``provision.json``
#     (wifi PSK, tailscale/headscale keys, LUKS keyfile, Vault token/unseal-key,
#     etc.) are NOT read by this function at all: password_hash is a one-way hash
#     (Studio never sees plaintext) authenticating a different login surface
#     (local OS/SSH, not Casdoor), and provision.json is entirely machine/service
#     secrets.
#
# (role-id, label, vault top-level-key suffix, secret name within that section)
_HUMAN_LOGINABLE_VAULT_ROLES = (
    ("superadmin", "Platform Superadmin", "pki", "casdoor-superadmin"),
)


def emit_passwordless_login_roles(contents: KeyZipContents, enabled: bool,
                                   manifest_path: str | None = None) -> list[str]:
    """ADDITIVE, OPT-IN step: after a KEYS bundle has been extracted, mirror ONLY
    the human-loginable role credentials it carries (see the module-level comment
    above for the exact include/exclude list) into the local-login roles manifest
    (:mod:`core.local_login_agent`), so they appear in the passwordless-login
    role picker.

    A strict no-op unless ``enabled`` is True — the Studio-local opt-in flag,
    default OFF (see ``--remember-roles-for-passwordless-login`` / the
    ``HUGMESH_REMEMBER_ROLES_FOR_PASSWORDLESS_LOGIN`` env var in app.py). Does
    NOT change anything about ``extract()`` / ``KeyZipContents.apply_to()`` — this
    is a separate, additional step the caller opts into after extraction.

    Returns the list of role ids written (empty if disabled, the bundle carried no
    ``vault/secrets.json``, or none of the recognized human-loginable secrets were
    present in it).
    """
    if not enabled:
        return []
    secrets_path = os.path.join(contents.staging_dir, "vault", "secrets.json")
    if not os.path.isfile(secrets_path):
        return []
    try:
        with open(secrets_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    if not isinstance(data, dict):
        return []

    roles = []
    for role_id, label, suffix, secret_name in _HUMAN_LOGINABLE_VAULT_ROLES:
        needle = f"-{suffix}"
        for top_key, section in data.items():
            if not isinstance(top_key, str) or not top_key.endswith(needle):
                continue
            if not isinstance(section, dict):
                continue
            entry = section.get(secret_name)
            if not isinstance(entry, dict):
                continue
            username, secret = entry.get("username"), entry.get("password")
            if not (isinstance(username, str) and username
                    and isinstance(secret, str) and secret):
                continue
            brand = top_key[: -len(needle)] or "hugmesh"
            roles.append(local_login_agent.Role(
                id=role_id, label=label, brand=brand,
                username=username, secret=secret,
            ))

    if not roles:
        return []
    path = manifest_path or local_login_agent.default_manifest_path()
    # Merge (by role id) with whatever is already on disk rather than clobbering
    # it, so re-importing the same key-zip (or a second domain's key-zip) updates/
    # adds roles without dropping roles an earlier opt-in import already wrote.
    existing = local_login_agent.load_manifest(path)
    merged = {r.id: r for r in existing.roles}
    for r in roles:
        merged[r.id] = r
    local_login_agent.RolesManifest(
        roles=list(merged.values()), origins=existing.origins,
    ).write(path)
    return [r.id for r in roles]
