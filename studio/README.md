# Snapdragon Image Studio

A cross-platform desktop app (Linux **and Windows**) that builds Snapdragon images with a
Calamares-style wizard — no need to remember `build-x86-host-stage4.sh` flags. It also runs
a **local mesh node** from the system tray.

## What it does

- **Three modes**: a hardened **standalone desktop** (LUKS + SELinux), a **branded cloud
  image** (tailnet client + SSO, with an admin **key-zip** drop-in), or a **superadmin mesh**
  (define domains + attach users, then build node images).
- **Every generator flag** is on a wizard page: hardware/GPU, branding (boot screen / login /
  wallpaper / accent), Wi-Fi/BT, **kernel built-in vs modules**, egress VPN, home mode +
  eCryptfs, installer front-ends, cached/uncached.
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

Headless preview of the exact build command for a saved config:

```sh
python -m snapdragon_studio --print-command --config my-image.json
```

Tray-only (mesh-node controller):

```sh
python -m snapdragon_studio --tray
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
```

The `core/` package has **no Qt dependency**, so the build logic can be scripted or tested
without a display.
