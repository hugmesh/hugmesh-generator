"""Hardware scanner — probe the machine the Studio is running on (Linux OR Windows)
and recommend build settings: GPU driver, whether Wi-Fi/Bluetooth firmware is needed,
and a best-guess hardware profile. Lets a user generate an image tuned to the exact
desktop/laptop they are sitting at.
"""
from __future__ import annotations

import platform
import re
import subprocess
from dataclasses import dataclass, field


@dataclass
class Gpu:
    vendor: str   # nvidia | amd | intel | other
    name: str
    pci_id: str = ""


@dataclass
class HwScan:
    os: str
    cpu: str = ""
    cpu_vendor: str = ""           # intel | amd | other
    gpus: list[Gpu] = field(default_factory=list)
    wifi: str = ""                 # chipset string if present
    bluetooth: str = ""
    recommended_gpu_driver: str = "auto"
    recommend_wifi: bool = False
    recommend_bluetooth: bool = False
    hw_profile_guess: str = ""
    notes: list[str] = field(default_factory=list)

    def apply_to(self, cfg) -> None:
        """Pre-fill an ImageConfig from the scan."""
        if self.recommended_gpu_driver != "auto":
            cfg.gpu_driver = self.recommended_gpu_driver
        if self.recommend_wifi:
            cfg.enable_wifi = True
        if self.recommend_bluetooth:
            cfg.enable_bluetooth = True
        if self.hw_profile_guess:
            cfg.hw_profile = self.hw_profile_guess


def _run(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _vendor_of(text: str) -> str:
    t = text.lower()
    if "nvidia" in t:
        return "nvidia"
    if any(k in t for k in ("amd", "radeon", "advanced micro devices", "ati ")):
        return "amd"
    if "intel" in t:
        return "intel"
    return "other"


def _gpu_driver_for(gpus: list[Gpu]) -> str:
    vendors = {g.vendor for g in gpus}
    if "nvidia" in vendors:
        return "nvidia"           # proprietary default for NVIDIA (free 'nouveau' is an option)
    if "amd" in vendors:
        return "amd-free"         # free amdgpu/mesa default
    if "intel" in vendors:
        return "intel-free"       # canonical id ("intel" is a builder alias for it)
    return "auto"


# ── Linux probes ────────────────────────────────────────────────────────────
def _scan_linux() -> HwScan:
    s = HwScan(os="linux")
    cpuinfo = ""
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as fh:
            cpuinfo = fh.read()
    except OSError:
        pass
    m = re.search(r"model name\s*:\s*(.+)", cpuinfo)
    if m:
        s.cpu = m.group(1).strip()
    s.cpu_vendor = "amd" if "AuthenticAMD" in cpuinfo else ("intel" if "GenuineIntel" in cpuinfo else "other")

    lspci = _run(["lspci", "-nn"]) or _run(["lspci"])
    for line in lspci.splitlines():
        low = line.lower()
        if any(k in low for k in (" vga ", "vga compatible", "3d controller", "display controller")):
            name = line.split(":", 2)[-1].strip()
            # drop the trailing ' [1234:5678]' PCI-id and ' (rev xx)' so the name is clean
            name = re.sub(r"\s*\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]", "", name)
            name = re.sub(r"\s*\(rev [^)]*\)", "", name).strip()
            pci = ""
            mm = re.search(r"\[([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\]", line)
            if mm:
                pci = mm.group(1)
            s.gpus.append(Gpu(vendor=_vendor_of(line), name=name, pci_id=pci))
        if "network controller" in low or "wireless" in low or "wi-fi" in low:
            s.wifi = line.split(":", 2)[-1].strip()
        if "bluetooth" in low:
            s.bluetooth = line.split(":", 2)[-1].strip()
    return _finalize(s)


# ── Windows probes (PowerShell / CIM) ────────────────────────────────────────
def _ps(query: str) -> str:
    return _run(["powershell", "-NoProfile", "-Command", query])


def _scan_windows() -> HwScan:
    s = HwScan(os="windows")
    s.cpu = _ps("(Get-CimInstance Win32_Processor).Name").strip()
    s.cpu_vendor = _vendor_of(s.cpu)
    vids = _ps("Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }")
    for line in (l.strip() for l in vids.splitlines() if l.strip()):
        s.gpus.append(Gpu(vendor=_vendor_of(line), name=line))
    net = _ps("Get-CimInstance Win32_NetworkAdapter -Filter \"PhysicalAdapter=True\" | "
              "ForEach-Object { $_.Name }")
    for line in (l.strip() for l in net.splitlines() if l.strip()):
        if any(k in line.lower() for k in ("wi-fi", "wireless", "802.11")):
            s.wifi = line
        if "bluetooth" in line.lower():
            s.bluetooth = line
    return _finalize(s)


def _finalize(s: HwScan) -> HwScan:
    s.recommended_gpu_driver = _gpu_driver_for(s.gpus)
    s.recommend_wifi = bool(s.wifi)
    s.recommend_bluetooth = bool(s.bluetooth)
    # crude profile guess from CPU/GPU strings; the profile menu refines it.
    blob = " ".join([s.cpu] + [g.name for g in s.gpus]).lower()
    if "framework" in blob:
        s.hw_profile_guess = "framework-13-amd" if s.cpu_vendor == "amd" else "framework-13-intel"
    elif "vivobook" in blob or "ryzen 7 3700u" in blob:
        s.hw_profile_guess = "asus-vivobook-f512da"
    if not s.gpus:
        s.notes.append("No GPU detected by the scan — verify the --gpu-driver choice manually.")
    return s


def scan() -> HwScan:
    sysname = platform.system().lower()
    if sysname.startswith("win"):
        return _scan_windows()
    return _scan_linux()
