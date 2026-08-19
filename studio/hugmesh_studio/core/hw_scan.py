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


# ── presentation (shared by the headless CLI, the GUI pages and the TUI) ──────
# Explicit key list (not dataclasses.asdict) so the --json schema is a stated
# contract: adding a dataclass field later is a deliberate schema change here,
# never a silent one. test_cli_parity pins the exact key set.
def to_dict(s: HwScan) -> dict:
    """The STABLE machine-readable scan (the ``--scan-hardware --json`` schema)."""
    return {
        "os": s.os,
        "cpu": s.cpu,
        "cpu_vendor": s.cpu_vendor,
        "gpus": [{"vendor": g.vendor, "name": g.name, "pci_id": g.pci_id}
                 for g in s.gpus],
        "wifi": s.wifi,
        "bluetooth": s.bluetooth,
        "recommended_gpu_driver": s.recommended_gpu_driver,
        "recommend_wifi": s.recommend_wifi,
        "recommend_bluetooth": s.recommend_bluetooth,
        "hw_profile_guess": s.hw_profile_guess,
        "notes": list(s.notes),
    }


def format_table(s: HwScan) -> str:
    """A human two-column table of the scan + the recommendations it derives —
    the same facts the wizard's HardwarePage renders, for the terminal."""
    rows: list[tuple[str, str]] = [
        ("os", s.os),
        ("cpu", s.cpu or "(not detected)"),
        ("cpu vendor", s.cpu_vendor or "(not detected)"),
    ]
    if s.gpus:
        for i, g in enumerate(s.gpus):
            label = "gpu" if len(s.gpus) == 1 else f"gpu {i + 1}"
            pci = f" [{g.pci_id}]" if g.pci_id else ""
            rows.append((label, f"{g.name} ({g.vendor}){pci}"))
    else:
        rows.append(("gpu", "(none detected)"))
    rows += [
        ("wifi", s.wifi or "(none detected)"),
        ("bluetooth", s.bluetooth or "(none detected)"),
        ("recommended --gpu-driver", s.recommended_gpu_driver),
        ("recommend --enable-wifi", "yes" if s.recommend_wifi else "no"),
        ("recommend --enable-bluetooth", "yes" if s.recommend_bluetooth else "no"),
        ("hw profile guess", s.hw_profile_guess or "(none)"),
    ]
    width = max(len(k) for k, _v in rows)
    lines = [f"{k.ljust(width)}  {v}" for k, v in rows]
    lines += [f"note: {n}" for n in s.notes]
    return "\n".join(lines)
