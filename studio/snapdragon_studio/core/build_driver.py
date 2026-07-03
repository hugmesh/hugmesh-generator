"""BuildDriver — assemble + run a build from an ImageConfig, native or dockerized.

The GUI calls ``command(...)`` to preview the exact invocation and ``run(...)`` to
stream it line-by-line into the progress page. Identical config -> identical command on
Linux and Windows; the only difference is the backend wrapper.
"""
from __future__ import annotations

import os
import shlex
import subprocess
import threading
from collections.abc import Callable, Iterator

from .config import ImageConfig
from .platform_info import HostInfo, detect


class BuildDriver:
    def __init__(self, generator_dir: str, host: HostInfo | None = None):
        self.generator_dir = os.path.abspath(generator_dir)
        self.host = host or detect()
        self._proc: subprocess.Popen | None = None
        self._cancel = threading.Event()

    # ---- command assembly --------------------------------------------------
    def command(self, cfg: ImageConfig, backend: str | None = None) -> list[str]:
        backend = backend or self.host.default_backend
        out = cfg.output_dir or os.path.join(self.generator_dir, "out")
        # cfg.platform picks the builder (x86/rpi5/frite/jetson); all four scripts sit
        # at the generator-repo root, so ./<script> works both natively (cwd =
        # generator_dir) and in the container (the repo is mounted at /src).
        script = f"./{cfg.builder_script}"
        inner = [script, "-w", "/out" if backend == "docker" else out,
                 "-j", str(cfg.jobs), *cfg.to_cli_args()]
        if backend == "native":
            # run in the generator dir; needs root for the chroot/loop ops
            return (["sudo"] if not self.host.is_root else []) + ["bash", *inner]
        if backend == "docker":
            # Asset paths outside the generator dir (wallpaper, branding dir, egress conf)
            # are not visible in the container — mount each and rewrite its flag value.
            asset_mounts, dcfg = self._remap_assets_for_docker(cfg)
            dinner = [script, "-w", "/out", "-j", str(cfg.jobs), *dcfg.to_cli_args()]
            return [
                "docker", "run", "--rm", "--privileged",
                "-v", f"{self.generator_dir}:/src",
                "-v", f"{out}:/out",
                *asset_mounts,
                "-w", "/src", self.host.builder_image,
                "bash", "-c", shlex.join(dinner),
            ]
        raise RuntimeError("no usable build backend (need Gentoo native or Docker)")

    def _remap_assets_for_docker(self, cfg: ImageConfig) -> tuple[list[str], ImageConfig]:
        """Mount external asset paths into the container and return (mount-args, a config
        whose asset flags point at the in-container paths)."""
        import copy
        dcfg = copy.deepcopy(cfg)
        mounts: list[str] = []
        gen = self.generator_dir + os.sep
        for i, field in enumerate(("wallpaper", "grub_background", "login_background",
                                   "brand_logo", "color_scheme", "branding_dir", "egress_vpn")):
            p = getattr(dcfg, field, "")
            if not p:
                continue
            ap = os.path.abspath(p)
            if ap.startswith(gen):
                continue  # already under /src, reachable in-container
            cpath = f"/assets/{i}/{os.path.basename(ap.rstrip(os.sep))}"
            mounts += ["-v", f"{ap}:{cpath}:ro"]
            setattr(dcfg, field, cpath)
        return mounts, dcfg

    def command_string(self, cfg: ImageConfig, backend: str | None = None) -> str:
        return " ".join(shlex.quote(x) for x in self.command(cfg, backend))

    # ---- execution ---------------------------------------------------------
    def _stream(self, cmd: list[str], on_line: Callable[[str], None] | None) -> int:
        """Popen cmd (cwd=generator_dir), call on_line per output line, return the exit
        code. Shared by run() and build_builder_image() so both stream identically and
        both respect cancel()."""
        self._cancel.clear()
        self._proc = subprocess.Popen(
            cmd, cwd=self.generator_dir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1)
        assert self._proc.stdout is not None
        for line in self._proc.stdout:
            if on_line:
                on_line(line.rstrip("\n"))
            if self._cancel.is_set():
                self._proc.terminate()
                break
        return self._proc.wait()

    def run(self, cfg: ImageConfig, backend: str | None = None,
            on_line: Callable[[str], None] | None = None) -> int:
        """Run the build, calling on_line for each output line. Returns the exit code.
        Blocking — callers run it on a worker thread (the GUI uses a QThread)."""
        out = cfg.output_dir or os.path.join(self.generator_dir, "out")
        os.makedirs(out, exist_ok=True)
        return self._stream(self.command(cfg, backend), on_line)

    def build_builder_image(self, on_line: Callable[[str], None] | None = None) -> int:
        """Build the Docker builder image (see HostInfo.builder_image) from
        Dockerfile.build at the generator repo root — the same command as `make
        docker-image`. Streams output the same way run() does; blocking, so callers run
        it on a worker thread (the GUI uses a QThread)."""
        return self._stream(self.builder_image_build_command(), on_line)

    def iter_run(self, cfg: ImageConfig, backend: str | None = None) -> Iterator[str]:
        out = cfg.output_dir or os.path.join(self.generator_dir, "out")
        os.makedirs(out, exist_ok=True)
        self._proc = subprocess.Popen(
            self.command(cfg, backend), cwd=self.generator_dir,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        assert self._proc.stdout is not None
        yield from (line.rstrip("\n") for line in self._proc.stdout)
        self._proc.wait()

    def cancel(self) -> None:
        self._cancel.set()
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()

    # ---- preflight ---------------------------------------------------------
    def _image_present(self) -> bool:
        """Is self.host.builder_image already built? (`docker image inspect` — same
        daemon-reachability caveats as platform_info._docker_ok.)"""
        try:
            r = subprocess.run(["docker", "image", "inspect", self.host.builder_image],
                               capture_output=True, timeout=8)
            return r.returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False

    def builder_image_build_command(self) -> list[str]:
        """The exact command build_builder_image() runs — also shown in preflight
        messages and by the GUI's "Build builder image now" button."""
        return ["docker", "build", "-f", "Dockerfile.build", "-t", self.host.builder_image, "."]

    def builder_image_missing(self, backend: str | None = None) -> bool:
        """True iff backend is docker, the daemon is reachable, but the builder image has
        not been built yet — exactly the condition the GUI should offer to fix."""
        backend = backend or self.host.default_backend
        return backend == "docker" and self.host.has_docker and not self._image_present()

    def preflight(self, cfg: ImageConfig, backend: str | None = None) -> list[str]:
        """Return a list of human-readable problems that would stop a build (empty = OK)."""
        backend = backend or self.host.default_backend
        problems: list[str] = []
        if backend == "none":
            problems.append("No build backend: install Docker (any OS) or run on a Gentoo host.")
        if not os.path.exists(os.path.join(self.generator_dir, cfg.builder_script)):
            problems.append(f"builder script {cfg.builder_script} not found in {self.generator_dir}"
                            + (" (Jetson support is EXPERIMENTAL — hardware validation pending)"
                               if cfg.platform == "jetson" else ""))
        if backend == "docker" and not self.host.has_docker:
            problems.append("Docker selected but the Docker daemon is not reachable.")
        elif backend == "docker" and not self._image_present():
            problems.append(
                f"Docker builder image '{self.host.builder_image}' not found — build it "
                f"first: {' '.join(self.builder_image_build_command())}")
        if backend == "native" and not self.host.is_root:
            problems.append("Native build needs root (the Studio will prepend sudo).")
        for label, path in (("wallpaper", cfg.wallpaper), ("branding-dir", cfg.branding_dir),
                            ("egress-vpn", cfg.egress_vpn), ("key-zip", cfg.keyzip)):
            if path and not os.path.exists(path):
                problems.append(f"{label} path does not exist: {path}")
        return problems
