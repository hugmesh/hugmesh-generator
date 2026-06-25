"""Admin key-zip drop-in.

A domain admin with rights to a user's domain generates a zip for that user containing
the bits the user should NOT have to author: the org CA / Secure-Boot certs, the domain
config, an egress-VPN conf, and optional branding. The user drops it into the Studio;
this module validates it (no path traversal, sane size), extracts it to a staging dir,
and reports what it found so the wizard can wire it into the ImageConfig.
"""
from __future__ import annotations

import os
import re
import shutil
import zipfile
from dataclasses import dataclass, field

MAX_TOTAL = 512 * 1024 * 1024   # 512 MiB extracted ceiling
MAX_FILES = 5000


@dataclass
class KeyZipContents:
    staging_dir: str
    has_keys: bool = False
    has_branding: bool = False
    egress_conf: str = ""
    domain_conf: str = ""
    files: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def summary(self) -> str:
        bits = []
        if self.has_keys:
            bits.append("keys/certs")
        if self.has_branding:
            bits.append("branding")
        if self.egress_conf:
            bits.append("egress-VPN")
        if self.domain_conf:
            bits.append("domain config")
        return ", ".join(bits) or "(nothing recognized)"

    def apply_to(self, cfg) -> None:
        """Wire recognized payloads into an ImageConfig."""
        if self.has_branding:
            cfg.branding_dir = os.path.join(self.staging_dir, "branding")
        if self.egress_conf:
            cfg.egress_vpn = self.egress_conf
        if self.domain_conf:
            _apply_domain_conf(self.domain_conf, cfg)


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


def extract(zip_path: str, staging_dir: str) -> KeyZipContents:
    # start clean so a previous zip's files can't be mis-classified into this result
    shutil.rmtree(staging_dir, ignore_errors=True)
    os.makedirs(staging_dir, exist_ok=True)
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
        for f in files:
            fl = f.lower()
            full = os.path.join(root, f)
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


def _apply_domain_conf(path: str, cfg) -> None:
    """Read a simple KEY=VALUE (or JSON) domain config and set brand/domain fields."""
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
    mapping = {"BRAND": "brand", "BRAND_TITLE": "brand_title", "ORG": "org",
               "CLUSTER_DOMAIN": "cluster_domain", "DOMAIN": "cluster_domain"}
    for key, attr in mapping.items():
        if d.get(key):
            setattr(cfg, attr, d[key])
