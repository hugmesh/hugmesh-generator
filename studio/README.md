# Snapdragon Image Studio

A cross-platform desktop app (Linux **and Windows**) that builds Snapdragon images with a
Calamares-style wizard — no need to remember `build-x86-host-stage4.sh` flags. It also runs
a **local mesh node** from the system tray.

## What it does

- **Three modes**: a hardened **standalone desktop** (LUKS + SELinux), a **branded cloud
  image** (tailnet client + SSO, with an admin **key-zip** drop-in), or a **superadmin mesh**
  (define domains + attach users, then build node images).
- **Role & platform picker** — EVERY documented image role, grouped by mode (the
  all-options-in-all-menus rule, [docs/BUILD-MATRIX.md](../docs/BUILD-MATRIX.md)): both
  standalone variants **plus the two plain-Gentoo arms** — `standalone-unaffiliated`
  (an x86 desktop with ZERO Snapdragon branding/tooling baked; branding pages disable
  themselves and any conflicting setting fails the command loudly, exactly like the
  builder) and the rpi5 `generic` unbranded arm64 server; the laptop/chromebook/desktop
  clients **and the arm64 La Frite family** (board + live/installer flavor +
  light/headless desktop); every cluster role on **x86 or Raspberry Pi 5**, plus the
  **NVIDIA Jetson Orin** roles (`edge_ai`, `gpu-host`, `full`, `jetson-desktop`) —
  Jetson is **EXPERIMENTAL, hardware validation pending**. The platform axis picks the
  builder script (`build-{x86-host,rpi5,frite,jetson}-stage4.sh`).
- **Every generator flag** is on a wizard page: hardware/GPU (the builder's **full
  `--gpu-driver` matrix**: all-free / nvidia-free / nvidia / amd-free / amd-pro /
  intel-free / intel-pro / none, or auto), the **test|prod `--env` picker** on the Build
  page, branding (boot screen / login /
  wallpaper / accent), Wi-Fi/BT, **kernel built-in vs modules**, egress VPN, home mode +
  eCryptfs, installer front-ends, cached/uncached — plus the **cluster optional-services
  catalog** (+ games), client **desktop weight + Steam delivery**, **LUKS root encryption**
  (`--encrypt-root` + keyfile/YubiKey unlock factors), `--compress`/`--resume`, and an
  **extra-flags escape hatch** so any unfielded CLI flag stays expressible.
- **Secrets are never saved**: `--local-pass` / `--luks-pass` live only in the live command —
  a saved config JSON always carries them blanked, and saving warns you to re-enter them.
- **Hardware scanner**: detect the GPU / Wi-Fi / Bluetooth on the machine you're running on
  (Linux **and** Windows) and pre-fill the build. A **machine menu** ships Framework laptops,
  the ASUS VivoBook, and popular Amazon/Best Buy/Costco/Walmart laptops & gaming desktops.
- **Build backend**: native on Gentoo, otherwise **Docker** (Windows uses Docker Desktop).
  Same config → same command on every OS.
- **Local mesh node**: start/stop/inspect a dockerized node from the **system tray**.

## Run

```sh
# Linux (Gentoo can build natively; others need Docker)
pip install -r requirements.txt        # PySide6 (or use an existing PyQt6)
./snapdragon-studio

# Windows (Docker Desktop required for builds)
pip install -r requirements.txt
snapdragon-studio.bat
```

Headless preview of the exact build command for a saved config — **Qt-free** (only
`core/` is imported, so it runs with no display and no PySide6/PyQt6 installed):

```sh
python -m snapdragon_studio --print-command --config my-image.json
python -m snapdragon_studio --print-command --config my-image.json --backend docker
# --backend auto|native|docker (auto = the host default; a host with no build
# backend still prints a deterministic native command)
```

The config's `platform` field (`x86` | `rpi5` | `frite` | `jetson` |
`orangepi5` | `orangepizero2`) selects the builder script the command targets.
This headless path is what the build-matrix harness (`make matrix-check` at
the repo root) drives to prove the GUI channel agrees with the
CLI/make/menu/job channels on every matrix cell.

Tray-only (mesh-node controller):

```sh
python -m snapdragon_studio --tray
```

Fleet builds (every role for the selected platforms in one run — the GUI
front-end to `scripts/build-all-roles.sh`; also reachable from the wizard's
welcome page):

```sh
python -m snapdragon_studio --fleet
```

## Package a Windows .exe

```sh
pip install pyinstaller PySide6
pyinstaller --noconfirm --windowed --name SnapdragonImageStudio \
  --collect-all PySide6 -p . snapdragon_studio/__main__.py
```

## Layout

```
snapdragon_studio/
  core/        config (flag mapping) · build_driver (native/docker) · hw_scan ·
               profiles · keyzip · mesh_node · platform_info     <- headless, unit-testable
  gui/         qt shim (PySide6|PyQt6) · wizard (pages) · tray
  app.py       entry point
tests/         pytest suite (headless, Qt-free)
pytest.ini
```

The `core/` package has **no Qt dependency**, so the build logic can be scripted or tested
without a display.

## Tests

```sh
cd studio && python -m pytest -q     # needs pytest; no Qt, no display, no root
```

The suite covers the `ImageConfig` → CLI-args translation for all four platforms
(including the rpi5/jetson role-name maps and the frite axes), the secret-blanking
save/load round-trip, the `BuildDriver` native/docker command assembly, and the
headless `--print-command` CLI path. The repo-level build-matrix harness
(`tests/build-matrix/check.sh`) additionally exercises the Studio as the GUI
channel for every canonical matrix cell.
