# Windows MSI packaging

The MSI is built in two stages, by `.github/workflows/studio-release.yml`:

1. **PyInstaller** freezes the app into a `onedir` tree
   (`packaging/hugmesh-studio.spec`).
2. **WiX v6** wraps that tree in an installer (`Package.wxs` + a harvested
   `Files.wxs`).

## Why the file list is harvested

A PyInstaller onedir output is roughly two thousand files. Hand-maintaining a WiX
component per file would be stale at the next PySide6 bump, and the failure mode is
silent — a missing DLL only shows up when a user launches the app. The workflow runs
`wix harvest` over the built tree instead, so the component list is a fact about the
build rather than a list somebody remembered to update.

## Per-user install

`Scope="perUser"` under `LocalAppDataFolder` means no administrator rights and no UAC
prompt. This is a developer tool; requiring machine-admin to evaluate it would be a
barrier with nothing behind it, since the app writes only to the user's own profile.

## The UpgradeCode is permanent

`7a3b6f18-2c94-4f0d-9a51-6d8e2b4c7f31` identifies the product across all versions.
`MajorUpgrade` uses it to replace an older install in place. **Never change it** —
every already-installed copy would stop being recognised as the same product and
would be left behind in Add/Remove Programs.

## Signing

The MSI is **not** code-signed: no certificate is configured. Windows SmartScreen
will warn on first run, and the Downloads page says so in the installer's `notes`
field. To sign, add a `signtool` step after `wix build` with a certificate supplied
through repository secrets — and update the note on the site at the same time, or it
will keep telling people about a warning they no longer see.

## Verifying a build locally

```powershell
dotnet tool install --global wix
wix build -arch x64 `
  -define Version=1.0.0 `
  -define SourceDir=dist\hugmesh-studio `
  -define IconFile=build\icons\hugmesh-studio.ico `
  -define LicenseFile=packaging\wix\License.rtf `
  -out hugmesh-studio-1.0.0-x64.msi `
  packaging\wix\Package.wxs packaging\wix\Files.wxs
```
