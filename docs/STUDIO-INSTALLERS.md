# Studio installers — Windows MSI and Linux Flatpak

The HugMesh Image Studio has always been run from a checkout
(`studio/hugmesh-studio`, or `python -m hugmesh_studio`), and that remains the
primary way to use it. These installers exist so the same application is available
to people who do not want to set up a Python environment first.

They package **the same code**. Nothing is added or removed for a packaged build.

| Artifact | Platform | Built by |
|---|---|---|
| `hugmesh-studio-<version>-x64.msi` | Windows 10/11 x64 | PyInstaller → WiX v6 |
| `hugmesh-studio-<version>-x86_64.flatpak` | Any Linux with Flatpak | flatpak-builder, `org.kde.Platform` 6.8 |

Both are produced by [`.github/workflows/studio-release.yml`](../.github/workflows/studio-release.yml)
and attached to a GitHub Release, together with `SHA256SUMS` and a `releases.json`
that feeds the Downloads page on the documentation site.

## What an installer does and does not give you

The Studio is a **front end over host tooling**. It shells out to `docker`, `make`,
`bash`, `qemu`, `kubectl`, `lsblk` and `ssh`, and it reads the build scripts and
cluster specs out of a `hugmesh-generator` checkout. An installer packages the app;
it cannot package the things the app drives.

So, after installing:

- **You still need a `hugmesh-generator` checkout.** Point the Studio at one on first
  run. Without it there are no build scripts to run and no cluster specs to read.
- **Building images still needs Docker** (any OS), or a Gentoo host for a native
  build. The Studio's own preflight says so when a build is dispatched.
- **Flashing a device and running an emulated mesh** need host access to block
  devices and QEMU.

The app opens, scans your hardware, edits configuration and previews the exact build
command without any of that — which is why the MSI carries no launch condition. An
installer that refuses to install on a machine the app runs fine on just teaches
people to disable checks.

## Windows

The MSI installs **per-user**, under `%LOCALAPPDATA%\HugMesh\Image Studio`. No
administrator rights, no UAC prompt.

It is **not code-signed** — no certificate is configured — so SmartScreen will warn
the first time you run it. Verify the SHA-256 from the release against your download
before running it:

```powershell
Get-FileHash .\hugmesh-studio-1.0.0-x64.msi -Algorithm SHA256
```

> **A note on Windows and WSL.** `core/platform_info.py` records a decision (2026-08-14)
> that **WSL2 is the recommended way to run the Studio on Windows**, because WSL2 is a
> real Linux kernel and `bash`, `make`, `docker` and process-group signalling all keep
> working unchanged. That recommendation still stands. The native MSI exists alongside
> it, for configuring, previewing and monitoring from the Windows desktop, and it
> drives builds through Docker Desktop. If you are doing heavy build work, WSL2 is
> still the better place to do it — and note that a WSL2 VM sees no USB devices unless
> they are attached with `usbipd-win`, so device flashing needs that either way.

## Linux

```bash
flatpak install --user ./hugmesh-studio-1.0.0-x86_64.flatpak
flatpak run org.hugmesh.ImageStudio
```

The bundle needs the `org.kde.Platform` 6.8 runtime (KDE rather than GNOME because
the app is Qt, and the KDE runtime already ships Qt — building against GNOME would
mean bundling all of Qt).

The manifest requests `--filesystem=host` and `--talk-name=org.freedesktop.Flatpak`.
Those are broad, and they are what makes the app able to read your checkout and run
host `docker`/`qemu`. If you would rather not grant them, run the Studio from a
checkout instead; it needs no installer.

A **bundle**, not Flathub: HugMesh's own governed desktops remove the Flathub remote
(`keys-template/desktop-governance/flatpak/flathub-disable.conf`), so Flathub is not a
delivery path for the machines most likely to want this.

## Cutting a release

1. Bump `__version__` in `studio/hugmesh_studio/__init__.py`. That is the **only**
   place a version is written — the installer filenames, the About box and the release
   tag all derive from it.
2. Tag: `git tag studio-v1.2.3 && git push origin studio-v1.2.3`.
   (Or run the workflow manually with **publish** ticked.)
3. The workflow refuses to continue if the tag and `__version__` disagree.
4. Copy the `releases.json` from the job summary into `hugmesh.github.io` at
   `src/assets/releases.json` — that is what updates the site's Downloads page.

Step 4 is manual on purpose: `GITHUB_TOKEN` cannot reach another repository, and
adding a cross-repo PAT for a once-per-release file would be the first PAT anywhere in
this org. It is also the natural moment to write the release notes.

## Building locally

```bash
cd studio
python -m pip install -e '.[win]' pyinstaller pillow   # drop [win] off Windows
python packaging/gen_icons.py --out build/icons
pyinstaller --noconfirm --clean packaging/hugmesh-studio.spec
QT_QPA_PLATFORM=offscreen dist/hugmesh-studio/hugmesh-studio --print-specs
```

That last line is the smoke test the workflow runs. `--print-specs` is the app's
Qt-free path, so it proves the frozen bundle's Python side is complete without needing
a display — and a bundle missing `core/progress-tables.json` fails right there, at
import time, rather than on a user's desktop.

See [`studio/packaging/wix/README.md`](../studio/packaging/wix/README.md) for the MSI
specifics.
