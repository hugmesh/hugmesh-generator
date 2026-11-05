"""Hardware scanner — probe the machine the Studio is running on (Linux OR Windows)
and recommend build settings: GPU driver, whether Wi-Fi/Bluetooth firmware is needed,
and a best-guess hardware profile. Lets a user generate an image tuned to the exact
desktop/laptop they are sitting at.
"""
from __future__ import annotations

import base64
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
    # probe ("cpu" | "gpu" | "network") -> why it did not run ("timed out after 45 s").
    # An empty gpus/wifi only means "none" when its probe is NOT in here. Kept out of
    # to_dict (the --json schema is pinned); the reason reaches JSON through notes.
    probe_errors: dict[str, str] = field(default_factory=dict)

    def scanned(self, probe: str) -> bool:
        """True when ``probe`` actually ran, so an empty result really means absent."""
        return probe not in self.probe_errors

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
# ONE PowerShell for all three CIM queries: each powershell.exe cold start costs
# seconds on a typical laptop (6-19 s per probe measured), and three in a row froze the
# wizard and ran into the per-probe timeout. Every name is sent as base64 of its UTF-8
# bytes, so the pipe carries ASCII only: PowerShell writes in the console's OEM code
# page (437/850) while text=True decodes as ANSI (cp1252), which mangled 'Gerät' and
# raised on 'für' (0x81). Each query has its own try, and its OK/ERR marker tells
# "ran and found nothing" apart from "did not run".
_WIN_PROBES = (("CPU", "cpu", "Win32_Processor", ""),
               ("GPU", "gpu", "Win32_VideoController", ""),
               ("NET", "network", "Win32_NetworkAdapter", " -Filter 'PhysicalAdapter=True'"))
_WIN_SCRIPT = "\n".join(
    ["function E($t, $s) { if ($null -ne $s -and \"$s\" -ne '') { \"$t \" + "
     "[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$s)) } }"]
    + [f"try {{ Get-CimInstance {cls}{flt} -ErrorAction Stop | "
       f"ForEach-Object {{ E {tag} $_.Name }}; 'OK {tag}' }} catch {{ 'ERR {tag}' }}"
       for tag, _probe, cls, flt in _WIN_PROBES])
_WIN_TIMEOUT = 45   # the old worst case (3 x 15 s), now for the one shared start


def _ps_scan(run=None, timeout: int = _WIN_TIMEOUT
             ) -> tuple[dict[str, list[str]], dict[str, str]]:
    """Run the CIM queries; ({tag: [names]}, {probe: why it did not run}).
    ``run`` stands in for ``subprocess.run`` in tests. Never raises."""
    run = run or subprocess.run
    cmd = ["powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand",
           base64.b64encode(_WIN_SCRIPT.encode("utf-16-le")).decode("ascii")]
    found: dict[str, list[str]] = {tag: [] for tag, *_ in _WIN_PROBES}
    done: dict[str, bool] = {}
    out, fail = b"", ""
    try:
        out = run(cmd, capture_output=True, timeout=timeout).stdout or b""
    except subprocess.TimeoutExpired as exc:
        # a query that finished before the limit still counts; the rest timed out
        out, fail = exc.stdout or b"", f"timed out after {timeout} s"
    except (OSError, subprocess.SubprocessError) as exc:
        fail = f"failed: PowerShell could not start ({exc})"
    for raw in out.decode("ascii", "replace").splitlines():
        tag, _sp, val = raw.strip().partition(" ")
        if tag in ("OK", "ERR"):
            done[val] = tag == "OK"
        elif tag in found:
            try:
                name = base64.b64decode(val, validate=True).decode("utf-8", "replace")
            except ValueError:
                continue    # a garbled line drops one name, never the scan
            if name.strip():
                found[tag].append(name.strip())
    errors: dict[str, str] = {}
    for tag, probe, cls, _flt in _WIN_PROBES:
        if tag not in done:
            errors[probe] = fail or "did not finish"
        elif not done[tag]:
            errors[probe] = f"failed ({cls} query error)"
    return found, errors


def _scan_windows(run=None) -> HwScan:
    s = HwScan(os="windows")
    found, s.probe_errors = _ps_scan(run)
    s.cpu = found["CPU"][0] if found["CPU"] else ""
    s.cpu_vendor = _vendor_of(s.cpu) if s.cpu else ""
    for line in found["GPU"]:
        s.gpus.append(Gpu(vendor=_vendor_of(line), name=line))
    for line in found["NET"]:
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
    if not s.scanned("cpu"):
        s.notes.append(f"CPU scan {s.probe_errors['cpu']}: the CPU was not checked.")
    if not s.scanned("gpu"):
        s.notes.append(f"GPU scan {s.probe_errors['gpu']}: the GPU was not checked — "
                       "choose --gpu-driver yourself, or scan again.")
    elif not s.gpus:
        s.notes.append("No GPU detected by the scan — verify the --gpu-driver choice manually.")
    if not s.scanned("network"):
        s.notes.append(f"Network adapter scan {s.probe_errors['network']}: Wi-Fi and "
                       "Bluetooth were not checked — set --enable-wifi / "
                       "--enable-bluetooth yourself, or scan again.")
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
    def absent(probe: str, none: str) -> str:
        # "(none detected)" only for a probe that ran; a failed one says it did not
        return none if s.scanned(probe) else f"(scan {s.probe_errors[probe]})"

    net_ok = s.scanned("network")
    rows: list[tuple[str, str]] = [
        ("os", s.os),
        ("cpu", s.cpu or absent("cpu", "(not detected)")),
        ("cpu vendor", s.cpu_vendor or absent("cpu", "(not detected)")),
    ]
    if s.gpus:
        for i, g in enumerate(s.gpus):
            label = "gpu" if len(s.gpus) == 1 else f"gpu {i + 1}"
            pci = f" [{g.pci_id}]" if g.pci_id else ""
            rows.append((label, f"{g.name} ({g.vendor}){pci}"))
    else:
        rows.append(("gpu", absent("gpu", "(none detected)")))
    rows += [
        ("wifi", s.wifi or absent("network", "(none detected)")),
        ("bluetooth", s.bluetooth or absent("network", "(none detected)")),
        ("recommended --gpu-driver", s.recommended_gpu_driver
         if s.scanned("gpu") or s.gpus else "(no recommendation: GPU not scanned)"),
        ("recommend --enable-wifi", "yes" if s.recommend_wifi else
         ("no" if net_ok else "(no recommendation: not scanned)")),
        ("recommend --enable-bluetooth", "yes" if s.recommend_bluetooth else
         ("no" if net_ok else "(no recommendation: not scanned)")),
        ("hw profile guess", s.hw_profile_guess or "(none)"),
    ]
    width = max(len(k) for k, _v in rows)
    lines = [f"{k.ljust(width)}  {v}" for k, v in rows]
    lines += [f"note: {n}" for n in s.notes]
    return "\n".join(lines)
