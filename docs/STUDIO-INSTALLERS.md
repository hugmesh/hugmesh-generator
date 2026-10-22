# Studio installers — Windows MSI and Linux Flatpak

The HugMesh Image Studio runs from a checkout (`studio/hugmesh-studio`, or
`python -m hugmesh_studio`). That is still the main way to use it. The installers
exist for people who do not want to set up a Python environment first.

They package **the same code**. Nothing is added or removed for a packaged build.

**No installer has been released yet.** The workflow exists, but no `studio-v*` tag
exists, and the site's Downloads page says so. Until one ships, run the Studio from a
checkout.

| Artifact | Platform | Built by |
|---|---|---|
| `hugmesh-studio-<version>-x64.msi` | Windows 10/11 x64 | PyInstaller → WiX v6 |
| `hugmesh-studio-<version>-x86_64.flatpak` | x86_64 Linux with Flatpak | flatpak-builder, `org.kde.Platform` 6.8 |

[`.github/workflows/studio-release.yml`](../.github/workflows/studio-release.yml)
builds both and attaches them to a GitHub Release, with `SHA256SUMS` and a
`releases.json` that feeds the Downloads page on the documentation site.

## What an installer does and does not give you

The Studio is a **front end over host tooling**. It shells out to `docker`, `make`,
`bash`, `qemu`, `kubectl`, `lsblk` and `ssh`, and it reads the build scripts and
cluster specs out of a `hugmesh-generator` checkout. An installer packages the app.
It cannot package the things the app drives.

So, after installing:

- **You still need a `hugmesh-generator` checkout.** Start the Studio with
  `--generator-dir <path>`. Without that flag it uses the current directory. No GUI
  dialog sets it, and the Start Menu shortcut passes no arguments and starts in the
  install folder, so the shortcut finds no checkout. Without a checkout there are no
  build scripts to run and no cluster specs to read.
- **Building images still needs Docker** (any OS), or a Gentoo host for a native
  build. The Studio's own preflight says so when a build is dispatched.
- **Flashing a device and running an emulated mesh** need host access to block
  devices and QEMU.

The app opens, scans your hardware, edits configuration and previews the exact build
command without any of that. So the MSI carries no launch condition. An installer that
refuses a machine the app runs on only teaches people to switch checks off.

## Windows

The MSI installs **per-user**, under `%LOCALAPPDATA%\HugMesh\Image Studio`. It needs
no administrator rights and shows no UAC prompt.

It is **not code-signed**; no certificate is configured. SmartScreen will warn you the
first time you run it. Check the SHA-256 from the release against your download
before you run it:

```powershell
Get-FileHash .\hugmesh-studio-0.3.0-beta.1-x64.msi -Algorithm SHA256
```

> **Windows and WSL.** `core/platform_info.py` records a decision (2026-08-14) that
> **WSL2 is the recommended way to run the Studio on Windows**. WSL2 is a real Linux
> kernel, so `bash`, `make`, `docker` and process-group signalling work unchanged. That
> still stands. The native MSI sits beside it, for configuring, previewing and
> monitoring from the Windows desktop, and it drives builds through Docker Desktop.
> For heavy build work, WSL2 is still the better place. A WSL2 VM also sees no USB
> devices unless they are attached with `usbipd-win`, so device flashing needs that
> either way.

## Linux

```bash
flatpak install --user ./hugmesh-studio-0.3.0-beta.1-x86_64.flatpak
flatpak run org.hugmesh.ImageStudio --generator-dir ~/Github/hugmesh-generator
```

The bundle needs the `org.kde.Platform` 6.8 runtime. The app is Qt, and the KDE
runtime already ships Qt; building against GNOME would mean bundling all of Qt.

The manifest requests `--filesystem=host` and `--talk-name=org.freedesktop.Flatpak`.
Those grants are broad. They let the app read your checkout and run host
`docker`/`qemu`. If you would rather not grant them, run the Studio from a checkout; it
needs no installer.

The release is a **bundle**, not a Flathub app. HugMesh's own governed desktops remove
the Flathub remote (`keys-template/desktop-governance/flatpak/flathub-disable.conf`),
so Flathub would not reach the machines most likely to want this.

## Versions

The Studio follows the org's beta scheme: `MAJOR.MINOR.PATCH-beta.N`, for example
`0.3.0-beta.1`. N starts at 1 and goes up by one for each published beta of the same
base. A fix during a beta raises N, not PATCH. There is no `+build` part and never a
`-SNAPSHOT`.

The version is written in one place, `__version__` in
`studio/hugmesh_studio/__init__.py`. Everything else is derived from it:

| Where | What it shows for `0.3.0-beta.1` |
|---|---|
| Installer file names, About box, release tag | `0.3.0-beta.1`, tag `studio-v0.3.0-beta.1` |
| MSI ProductVersion (Add/Remove Programs) | `0.3.1` |
| Python package metadata (PEP 440) | `0.3.0b1` |

**Why the MSI shows a different number.** An MSI version is numbers only, and
Windows Installer compares just the first three fields when it decides whether one
install replaces another. So the beta number goes into the third field:
`PATCH * 100 + N` for `-beta.N`, and `PATCH * 100 + 99` for the final release.
`0.3.0-beta.2` becomes `0.3.2`, the final `0.3.0` becomes `0.3.99`, and
`0.3.1-beta.1` becomes `0.3.101`. That always goes up, and allows 98 betas per PATCH.
[`studio/packaging/wix/msi_version.py`](../studio/packaging/wix/msi_version.py) does the
mapping for both the workflow and `build-msi-wine.sh`.

**If a 1.0.0 MSI is installed.** The Studio was numbered 1.0.0 before the beta scheme,
and no 1.0.0 was ever released. A local 1.0.0 MSI built with `build-msi-wine.sh`
counts as newer than `0.3.1`, so the beta installer refuses to replace it. Uninstall
the 1.0.0 build first.

## Cutting a release

1. Set `__version__` in `studio/hugmesh_studio/__init__.py` to the new beta, and add a
   matching `<release>` to
   `studio/packaging/flatpak/org.hugmesh.ImageStudio.metainfo.xml` (AppStream writes
   the pre-release with `~`: `0.3.0~beta.2`). Merge that to `main`.
2. Tag the merged commit on `main` and push the tag:
   `git tag -a studio-v0.3.0-beta.2 -m "Studio 0.3.0-beta.2" && git push origin studio-v0.3.0-beta.2`.
3. The workflow stops if the tag and `__version__` disagree. It builds both installers
   and creates the GitHub Release, marked **pre-release** and never "latest".
4. Copy the `releases.json` from the job summary into `hugmesh.github.io` at
   `src/assets/releases.json`. That updates the site's Downloads page.

To re-run a release, run the workflow manually **on the tag** with **publish** ticked:
`gh workflow run studio-release.yml --repo hugmesh/hugmesh-generator --ref studio-v0.3.0-beta.2 -f publish=true`.
If the release already exists, the run stops without changing it. A manual run on
`main` builds both installers as workflow artifacts and publishes nothing. A run on
any other branch is refused.

The version and publish jobs use the self-hosted runner only when the repository
variable `RUNS_ON_PUBLISH` is set, and only for `main` and `studio-v*` tags. Delete
the variable and they go back to GitHub's hosted runners. The MSI job always needs
`windows-latest`, and the Flatpak job always runs on `ubuntu-latest`.

Step 4 is manual on purpose. `GITHUB_TOKEN` cannot reach another repository, and a
cross-repo PAT for a once-per-release file would be the first PAT anywhere in this
org. It is also the natural moment to write the release notes.

## Building locally

```bash
cd studio
python -m pip install -e '.[win]' pyinstaller pillow   # drop [win] off Windows
python packaging/gen_icons.py --out build/icons
pyinstaller --noconfirm --clean packaging/hugmesh-studio.spec
QT_QPA_PLATFORM=offscreen dist/hugmesh-studio/hugmesh-studio --print-specs
```

The last line is the smoke test the workflow runs. `--print-specs` is the app's
Qt-free path, so it proves the frozen bundle's Python side is complete without a
display. A bundle missing `core/progress-tables.json` fails right there, at import
time, not on a user's desktop.

See [`studio/packaging/wix/README.md`](../studio/packaging/wix/README.md) for the MSI
specifics.

Two scripts repeat the release jobs on a Linux box with no sudo:
`studio/packaging/build-msi-wine.sh` builds the MSI under Wine, and
`studio/packaging/build-flatpak-local.sh` builds and smoke-tests the Flatpak. Neither
publishes anything.
