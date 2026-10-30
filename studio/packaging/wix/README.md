# Windows MSI packaging

The MSI is built in two stages:

1. **PyInstaller** freezes the app into a `onedir` tree
   (`packaging/hugmesh-studio.spec`, entry `packaging/run_studio.py`).
2. **WiX 6** wraps that tree in an installer (`Package.wxs` + `Files.wxs`).

Both are repeated, with no Windows machine, by one script:

```sh
studio/packaging/build-msi-wine.sh        # needs Wine, Docker, Xvfb, curl, python3; no sudo
```

It writes `hugmesh-studio-<version>-x64.msi` and `.msi.sha256` to
`$HUGMESH_DIST_DIR` (default `~/.cache/hugmesh-studio-msi/dist`). Run it with `--help`
for the phases, which can be run one at a time, and the environment variables.

## What the script does, and what that proves

| Phase | What happens | What it proves |
|-------|--------------|----------------|
| `fetch` | Python 3.12.10, the Windows .NET 8 runtime, WiX 6.0.2 and its UI extension are downloaded and checked against hashes written in the script, on every run | the inputs are the ones we pinned |
| `prefix` | a **private** Wine prefix (never `~/.wine`) gets Python, the hash-locked packages in `windows-build-requirements.txt`, WiX and a Windows .NET runtime | the build environment is the pinned one, not whatever is current |
| `freeze` | PyInstaller runs the committed spec; the result is smoke-tested | see below |
| `msi` | `wix build` of `Package.wxs` + `Files.wxs` under Wine, then a `.sha256` | an MSI exists |
| `verify` | msitools (a separate, Linux MSI reader) in a throwaway container compares the MSI with the frozen tree | the file list, every file's bytes, `ProductVersion`, `UpgradeCode`, the shortcut, the icon and the licence page are what they should be |
| `install-test` | Wine's own `msiexec` installs the MSI, the installed exe runs, then it is uninstalled | the tables are consistent enough for an installer engine; the per-user install and removal work |
| `selftest` | breaks the bundle and the MSI on purpose | each check above turns red when its subject is broken |

The smoke tests of the frozen app, run from a copy of the tree in a directory with no
checkout nearby and `HUGMESH_*` variables removed:

* every `[tool.setuptools.package-data]` file, tzdata, the Qt `windows` platform plugin
  and the C++ runtime are in the tree, and the Wine-only ICU forwarder and PyQt are not;
* `hugmesh-studio.exe --print-specs`, stdout redirected to a file as the workflow does,
  prints non-empty JSON **identical** to what `python -m hugmesh_studio --print-specs`
  prints from source under the same Python;
* the GUI starts on a virtual display and shows its window (a screenshot is saved).

### What it does NOT prove

* The MSI was written by WiX running under **Wine**: Wine's `msi.dll` wrote the database
  and Wine's `cabinet.dll` the cabinet (MSZIP; it cannot do LZX, WiX's default, so this MSI
  is somewhat larger than a Windows-built one). No real Windows Installer has opened it.
* **ICE validation did not run.** `wix build` has no validation switch and printed no ICE
  results; `wix msi validate`, the way to run them, fails under Wine (`WIX0216`, 0x65B).
  Per-user components keyed on files will probably raise ICE38/ICE64 messages on Windows;
  those are author lint and do not stop an install.
* The frozen GUI was shown under Wine on an Xvfb display, never on a Windows desktop.
* The MSI is **not code-signed**; SmartScreen will warn.
* GitHub Actions (billing) and hosted Windows runners were not used: the workflow itself
  has not run.

## Why the script does not copy the workflow's steps

Measured on 2026-09-30. The workflow cannot get past these wherever it runs:

1. **`wix harvest files ...`** does not exist: no release of the `wix` tool has a
   `harvest` command (4.0.0, 4.0.6, 5.0.0, 5.0.2, 6.0.0, 6.0.2, 7.0.0 checked). `Files.wxs`
   uses WiX's own `<Files>` element instead, which expands at build time.
2. **`dotnet tool install --global wix`** installs WiX 7, which refuses to run until the
   Open Source Maintenance Fee EULA is accepted (`WIX7015`). That is a licence decision for
   the project owner, so the script pins **6.0.2**, the last release before it.
3. The workflow installs `WixToolset.Util.wixext` (nothing uses it, and unpinned it pulled
   7.0.0 into a 6.x tool) but builds with `-ext WixToolset.UI.wixext`, which it never
   installs (`WIX0144`). The UI extension must be installed at the same version as the tool.

And **WiX does not run natively on Linux** (4.0.6, 5.0.2, 6.0.0 and 6.0.2 were tried on the
.NET 8 SDK container; 7.x refuses to start without its EULA): it checks every
`Directory/@Name` with a Windows-only path trick (`Path.GetFullPath("C:\\" + name)` must
start with `C:\`), so every package with a folder fails with `WIX0389`, and its cabinet
and MSI writers call Windows DLLs. The script therefore runs the Windows build of WiX under
Wine, on Microsoft's Windows .NET runtime with `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` and
`DOTNET_SYSTEM_GLOBALIZATION_PREDEFINED_CULTURES_ONLY=false` (Wine has no usable ICU for
.NET, and WiX asks for the `en-US` culture by name).

## Wine details worth knowing

* **`icuuc.dll`.** PySide6's `Qt6Core.dll` imports Windows 10's `icuuc.dll`; Wine only has
  `icu.dll`, so `import PySide6.QtCore` fails with "DLL load failed". `wine_icu_shim.py`
  writes a code-free forwarder DLL (every export forwards to `icu.dll`) into the prefix's
  `system32`. It is a build-machine workaround and **must not ship**: `system32` is where
  PyInstaller leaves it out, and the freeze phase fails if it appears in the bundle.
* **The icon's letter.** `gen_icons.py` forces Qt's `offscreen` platform, which has no fonts,
  so the mark's "S" is drawn as an empty box (measured under Wine; the same plugin is used
  on Windows, unverified there). `render_icon_wine.py` runs `gen_icons.py` unchanged but with
  Qt's `windows` platform and Wine's own Tahoma loaded straight from its font files and set as
  the application font. Without that the letter is a thin serif (a fresh prefix has no Tahoma
  registered; registering it in the Wine registry was tried and did not survive a first run
  reliably). The freeze phase counts the letter's pixels and refuses to build an installer with
  an empty-box or thin icon.
* **Output redirected straight to a file is lost under Wine** (measured with `python.exe`,
  `pythonw.exe` and the frozen exe); a pipe, or a redirect done by `cmd` inside Wine (what
  the script does, and what the workflow's PowerShell effectively does), works.
* A frozen bundle that cannot import **hangs rather than exiting** (measured: with
  `_roles-lib.sh` removed, `--print-specs` was still running when `timeout` killed it at 120 s;
  presumably PyInstaller's error dialog waiting for a click). Every smoke step runs under
  `timeout`, and a hang counts as a failure.
* `winemenubuilder` is disabled: with it on, installing an MSI that has a Start Menu
  shortcut made Wine create folders under your real `~/.local/share/applications`
  (measured), outside the private prefix.

## What a frozen Studio can and cannot do

The Studio is a front end over scripts in a `hugmesh-generator` checkout (`build-*.sh`,
`scripts/`, `specs/`, `tests/`). The MSI bundles none of them. Each claim below is marked
**measured** (run in the frozen exe under Wine, from a directory with no checkout near it) or
**from the code** (read, not run frozen).

* **Measured:** `hugmesh-studio.exe --print-specs` prints exactly what the source prints, and
  the GUI opens and shows its Welcome page (screenshot saved by the `freeze` phase). That page
  itself says "This machine can't build images yet" when Docker is absent.
* **Measured:** `--print-command`, `--print-commands`, `--scan-hardware --json`,
  `--list-sessions`, `--e2e-environments` and `--e2e-plan --e2e-env docker` all exit 0 from a
  directory with no checkout, and a bad `--config` exits 2 with a message. `--print-command`
  prints `sudo bash ./build-x86-host-stage4.sh ...`: it formats the command, and running that
  needs the checkout.
* **From the code:** saving and loading configuration, the role vocabulary (the packaged
  `core/_roles-lib.sh`), the device catalogue and progress tables read only package data, which
  the freeze phase checks is in the bundle (the GUI starting proves `progress-tables.json`; the
  Qt-free commands never import it, so `--print-specs` alone does not). The timezone list needs
  the bundled tzdata (checked present, not exercised).
* **From the code:** building an image, cluster and go-live actions and e2e runs need a
  checkout. The Start Menu shortcut starts in the install folder, which has no scripts, and
  passes no arguments.
* **Choosing the checkout (#827):** `--generator-dir` wins, then `$HUGMESH_GENERATOR_DIR`, then
  the working directory, then the folder last picked in the GUI (saved as `generator-dir.txt`
  in the Studio state dir, `%USERPROFILE%\.hugmesh\studio`); the variable, the working
  directory and the saved folder count only when they are a checkout. When none is, the GUI
  says so on start and opens a folder picker; a cancel keeps the install folder, and the pages
  then say what is missing. Only a folder picked there is saved. The default launch asks after
  the already-running check, so a second default launch never asks; `--go-live` and `--fleet`
  skip that check and do ask, and `--tray`/`--stack-tray` do not ask when a system tray
  exists; with none, the wizard opens instead and they ask first. The same picker appears
  on Linux for a pip, Flatpak or release-tarball install started outside a checkout, and for
  a source run given a `--generator-dir` that is no checkout; there it says the Studio itself
  does not include the scripts. See `core/generator_dir.py`.
* **From the code:** `core/build_driver.py` writes a `sudo` askpass helper that runs
  `sys.executable -m hugmesh_studio --askpass-gui`, which cannot work in a frozen exe. It only
  serves native `sudo` builds on Linux, which Windows never does; noted, not a Windows defect.
* **Measured (warn file):** `cryptography` is not bundled (it is not a dependency), so a base
  CA certificate file is accepted on its PEM framing alone, without an X.509 parse.
* Building images on Windows needs Docker Desktop.
* **Measured on Windows 11 (2026-10-29):** `hugmesh-studio.exe` is a windowed program, so
  started from cmd or PowerShell it has no stdout: every command-line flag printed nothing
  and the shell did not wait for its exit code. The MSI therefore also installs
  `hugmesh-studio-cli.exe`, the same app frozen as a console program, for the flags
  (`hugmesh-studio-cli.exe --print-specs`, `--list-sessions`, `--help`, ...). The Start
  Menu shortcut still opens the windowed one.
* **Measured on Windows 11 (2026-10-29):** the local-mesh and DevOps lanes (`make` targets
  whose recipes are bash) cannot run natively. They now refuse with one sentence that
  names WSL2, the supported way to run the Studio on Windows, instead of "make is
  required" (`core/platform_info.native_windows_blocker`).
* Building the MSI by hand on Windows from a deep folder fails inside WiX's cabinet
  helper ("The pipe has been ended"): the deepest PySide6 file passes 260 characters and
  `wixnative.exe` is not long-path aware. Build from a short path; the hosted runner's
  `D:\a\...` checkout is short enough.

## Per-user install

`Scope="perUser"` under `LocalAppDataFolder` means no administrator rights and no UAC
prompt. This is a developer tool; requiring machine-admin to evaluate it would be a barrier
with nothing behind it, since the app writes only to the user's own profile. The `install-test`
phase asserts that an uninstall removes the install folder, the Start Menu entry and the
registry value. It also reports, without failing, that an empty `%LOCALAPPDATA%\HugMesh` folder
stays behind: the package has no component for the company folder. A `RemoveFolder` row for it
was tried and changed nothing under Wine's installer (which deletes folders before the files),
so the package was left as it was; whether Windows Installer removes it is unverified.

## The UpgradeCode is permanent

`7a3b6f18-2c94-4f0d-9a51-6d8e2b4c7f31` identifies the product across all versions.
`MajorUpgrade` uses it to replace an older install in place. **Never change it**: every
already-installed copy would stop being recognised as the same product and would be left
behind in Add/Remove Programs. `tests/test_windows_packaging_files.py` fails if it changes.

## Signing

The MSI is **not** code-signed: no certificate is configured. Windows SmartScreen will warn
on first run, and the Downloads page says so in the installer's `notes` field. To sign, add a
`signtool` step after `wix build` with a certificate supplied through repository secrets, and
update the note on the site at the same time.

## Refreshing the pins

* **Python packages:** install the new top-level versions in a scratch prefix, then
  `wine python -m pip freeze > freeze.txt` and
  `python3 lock_windows_build.py freeze.txt > windows-build-requirements.txt`. Audit any lock
  against PyPI with `python3 lock_windows_build.py --check windows-build-requirements.txt`.
* **Python itself:** python.org publishes only an MD5 for the installer (plus a GPG
  signature and a Sigstore bundle), no SHA-256. The pinned SHA-256 was computed after the MD5
  matched and the signature verified against Steve Dower's key, fingerprint
  `7ED10B6531D7C8E1BC296021FC624643487034E5`, the one python.org's OpenPGP page lists.
  3.12.11 and later are source-only; there is no newer 3.12 installer to move to.
* **.NET runtime:** the SHA-512 is in Microsoft's release metadata
  (`builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json`).
* **WiX and its extension:** the SHA-512 is NuGet's own `packageHash` for that version.
  Moving to WiX 7 means accepting its EULA, which is a decision for the project owner.

## What the workflow does now

`.github/workflows/studio-release.yml` (`msi` job, `windows-latest`) follows the same recipe as
`build-msi-wine.sh`, with the three defects measured on 2026-09-30 removed:

* WiX is installed **pinned**: `dotnet tool install --global wix --version 6.0.2`, then
  `wix extension add -g WixToolset.UI.wixext/6.0.2` (the extension at the same version as the
  tool). WiX 7 would need the Open Source Maintenance Fee EULA accepted (`WIX7015`), which is
  the project owner's licence decision.
* There is no harvest step: `Files.wxs` is committed and expands the frozen tree at build time.
  The build passes `AppDir` as an absolute path.
* The icon is rendered with `QT_QPA_PLATFORM=windows` (the `offscreen` default draws an empty
  box where the "S" goes) and `check_icon.py` fails the job if the letter is missing.

What no machine has shown yet: that a real Windows Installer installs the MSI and that the
Start Menu entry launches the app. A person has to do that on Windows 10/11 before the
installer is called working.
