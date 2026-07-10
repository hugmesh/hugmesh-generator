"""Hardware-profile catalog loader. Reads specs-x86/hwprofiles/profiles.json (curated
Framework + best-seller machines) so the Studio can present a machine menu that pre-fills
the build config."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass


@dataclass
class Profile:
    id: str
    label: str
    category: str = ""
    gpu_driver: str = "auto"
    enable_wifi: bool = False
    enable_bluetooth: bool = False
    notes: str = ""

    def apply_to(self, cfg) -> None:
        # A profile is a PRESET, not a build axis: it pre-fills the gpu/wifi/bt fields
        # (which DO emit) and records its id in cfg.hw_profile for round-tripping the
        # chosen machine. hw_profile ITSELF is never emitted — no builder has a profile
        # flag — so it is deliberately absent from config.PLATFORM_FIELD_SUPPORT and
        # listed in config.NON_ARGV_FIELDS (decided document-as-preset, G41).
        if self.gpu_driver and self.gpu_driver != "auto":
            cfg.gpu_driver = self.gpu_driver
        cfg.enable_wifi = self.enable_wifi
        cfg.enable_bluetooth = self.enable_bluetooth
        cfg.hw_profile = self.id


def _profiles_path(generator_dir: str) -> str:
    return os.path.join(generator_dir, "specs-x86", "hwprofiles", "profiles.json")


def load(generator_dir: str) -> list[Profile]:
    path = _profiles_path(generator_dir)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    out = []
    for p in data.get("profiles", []):
        out.append(Profile(
            id=p.get("id", ""), label=p.get("label", p.get("id", "")),
            category=p.get("category", ""), gpu_driver=p.get("gpu_driver", "auto"),
            enable_wifi=bool(p.get("enable_wifi", False)),
            enable_bluetooth=bool(p.get("enable_bluetooth", False)),
            notes=p.get("notes", "")))
    return out


def by_id(generator_dir: str, pid: str) -> Profile | None:
    for p in load(generator_dir):
        if p.id == pid:
            return p
    return None
