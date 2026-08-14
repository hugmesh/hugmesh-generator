"""Install the DevOps lane's missing CLI prerequisites, user-locally (Qt-free).

The lane needs `kind` (and `kubectl`) on PATH; the bootstrap refuses without
them (bootstrap-kind.sh's prerequisite loop). Telling the operator "kind is not
installed" and stopping is honest but not useful — this module closes that gap
the way the rest of the Studio does long work: as a verb it can run itself.

DELIBERATE CONSTRAINTS, because this downloads and installs an executable:
  * USER-LOCAL ONLY — everything lands in the XDG data dir
    (~/.local/share/hugmesh-studio/tools/bin). No sudo, no /usr/local, nothing
    system-wide, so the install is trivially reversible (delete the directory).
    NOT the repo's out/: container builds leave root-owned subdirectories there,
    so creating out/tools fails with EACCES for the operator's own user.
  * CHECKSUM-VERIFIED — the upstream .sha256sum is fetched and compared before
    the binary is made executable. A mismatch deletes the download and fails
    loudly; an unverifiable artifact is never installed.
  * PINNED versions, not "latest": a floating install is not reproducible, and
    the cluster this drives is pinned too.
  * NEVER automatic. It runs only when the operator presses the button.
"""
from __future__ import annotations

import hashlib
import os
import platform
import shutil
import stat
import urllib.request

# Pinned upstream releases (both publish a per-artifact sha256 alongside).
KIND_VERSION = "v0.23.0"
KUBECTL_VERSION = "v1.30.2"

def tools_dir(generator_dir: str = "") -> str:
    """Where user-local tools live; also prepended to PATH for the lane.

    XDG data dir, NOT the repo's out/ — docker builds leave root-owned dirs
    under out/, so the operator's own user cannot create out/tools (EACCES,
    hit live 2026-08-14). ``generator_dir`` is accepted and ignored so callers
    keep one signature."""
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "hugmesh-studio", "tools", "bin")


def _arch() -> str | None:
    """kind/kubectl artifact arch, or None on an unsupported machine."""
    return {"x86_64": "amd64", "amd64": "amd64",
            "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine().lower())


def _urls(tool: str, arch: str) -> tuple[str, str, bool]:
    """(binary_url, checksum_url, checksum_file_is_bare_hash)."""
    if tool == "kind":
        base = (f"https://github.com/kubernetes-sigs/kind/releases/download/"
                f"{KIND_VERSION}/kind-linux-{arch}")
        return base, base + ".sha256sum", False
    base = f"https://dl.k8s.io/release/{KUBECTL_VERSION}/bin/linux/{arch}/kubectl"
    return base, base + ".sha256", True


def which(tool: str, generator_dir: str) -> str | None:
    """`tool` on PATH, or in this repo's user-local tools dir."""
    found = shutil.which(tool)
    if found:
        return found
    local = os.path.join(tools_dir(generator_dir), tool)
    return local if os.path.isfile(local) and os.access(local, os.X_OK) else None


def missing(generator_dir: str, tools: tuple[str, ...] = ("kind", "kubectl")) -> list[str]:
    return [t for t in tools if which(t, generator_dir) is None]


def install(generator_dir: str, tools: tuple[str, ...] | None = None,
            on_line=None) -> tuple[bool, str]:
    """Download + checksum-verify the missing tools into the user-local dir.

    Returns (ok, message). Never raises: this backs a GUI verb, and a network
    failure must read as a sentence, not a traceback."""
    def say(line: str) -> None:
        if on_line is not None:
            on_line(line)

    arch = _arch()
    if arch is None:
        return False, (f"Unsupported machine architecture "
                       f"'{platform.machine()}' — install kind/kubectl manually.")
    if platform.system().lower() != "linux":
        return False, ("Automatic install covers Linux only — install kind and "
                       "kubectl with your platform's package manager.")

    want = list(tools) if tools is not None else missing(generator_dir)
    if not want:
        return True, "Nothing to install — kind and kubectl are already available."

    dest = tools_dir(generator_dir)
    os.makedirs(dest, exist_ok=True)
    for tool in want:
        url, sum_url, bare = _urls(tool, arch)
        target = os.path.join(dest, tool)
        tmp = target + ".part"
        say(f"[devops-tools] downloading {tool} ({url}) …")
        try:
            with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as fh:
                shutil.copyfileobj(r, fh)
            with urllib.request.urlopen(sum_url, timeout=60) as r:
                published = r.read().decode("utf-8", "replace").split()[0].strip()
        except Exception as exc:                     # network/HTTP/DNS
            if os.path.exists(tmp):
                os.remove(tmp)
            return False, f"Could not download {tool}: {exc}"
        got = hashlib.sha256(open(tmp, "rb").read()).hexdigest()
        if got.lower() != published.lower():
            os.remove(tmp)
            return False, (f"{tool}: SHA-256 MISMATCH — refusing to install. "
                           f"published={published} downloaded={got}")
        os.replace(tmp, target)
        os.chmod(target, os.stat(target).st_mode | stat.S_IXUSR | stat.S_IXGRP)
        say(f"[devops-tools] {tool} installed + checksum-verified -> {target}")
    return True, (f"Installed {', '.join(want)} into {dest} (checksum-verified). "
                  "User-local, no sudo; delete that directory to undo.")
