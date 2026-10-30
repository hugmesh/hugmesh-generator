# Studio installers — Windows MSI, Linux Flatpak and Linux tarball

The HugMesh Image Studio runs from a checkout (`studio/hugmesh-studio`, or
`python -m hugmesh_studio`). That is still the main way to use it. The installers
exist for people who do not want to set up a Python environment first.

They package **the same code**. Nothing is added or removed for a packaged build.

**To release one:** `scripts/release-studio.sh <version>`. That is the whole procedure;
["Cutting a release"](#cutting-a-release) below explains what it does and the one
other way (a button in Actions). The first beta, `0.3.0-beta.1`, shipped on
2026-10-22.
A whole-org beta release (every library and image, then the Studio, then the site) calls
this same script from `scripts/release-beta.sh --studio <version>`; see
[`RELEASING.md`](RELEASING.md).

| Artifact | Platform | Built by |
|---|---|---|
| `hugmesh-studio-<version>-x64.msi` | Windows 10/11 x64 | PyInstaller → WiX v6 |
| `hugmesh-studio-<version>-x86_64.flatpak` | x86_64 Linux with Flatpak | flatpak-builder, `org.kde.Platform` 6.11 (the bundle names Flathub as its source) |
| `hugmesh-studio-<version>-aarch64.flatpak` | aarch64 (ARM64) Linux with Flatpak: Raspberry Pi 4/5 desktops, Apple-silicon VMs, Ampere machines | the same manifest on GitHub's hosted `ubuntu-24.04-arm` runner (job `flatpak-aarch64`) |
| `hugmesh-studio-<version>-linux-x86_64.tar.gz` | x86_64 Linux, glibc 2.39+ | PyInstaller (same spec as the MSI) |

[`.github/workflows/studio-release.yml`](../.github/workflows/studio-release.yml)
builds all four **on GitHub-hosted runners only**, signs them there, and attaches
them to a GitHub Release with `SHA256SUMS`, its cosign signature bundle
`SHA256SUMS.sigstore.json`, SPDX SBOMs and a `releases.json` that feeds the Downloads
page on the documentation site. Nothing built on a developer machine is ever published;
the local scripts below are dry runs.

## Verifying a download

Every published file has a GitHub build-provenance attestation, and `SHA256SUMS` is
signed keyless with cosign by the release workflow at the release tag. For a release
`<V>` (tag `studio-v<V>`), substituting `0.3.0-beta.2` here:

```bash
gh attestation verify hugmesh-studio-0.3.0-beta.2-x64.msi \
  --repo hugmesh/hugmesh-generator \
  --signer-workflow hugmesh/hugmesh-generator/.github/workflows/studio-release.yml \
  --source-ref refs/tags/studio-v0.3.0-beta.2 \
  --deny-self-hosted-runners

cosign verify-blob --bundle SHA256SUMS.sigstore.json \
  --certificate-identity https://github.com/hugmesh/hugmesh-generator/.github/workflows/studio-release.yml@refs/tags/studio-v0.3.0-beta.2 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
```

The release notes print the same commands for each release, including the identity as
an anchored regular expression for `--certificate-identity-regexp`.

> **`0.3.0-beta.1` does not verify with its own printed commands.** Its files were
> replaced on 2026-10-23 by a run on a since-deleted tag `studio-v0.3.1-beta.1` (the
> tag-must-match gate had been removed by hand), so the certificate in its
> `SHA256SUMS.sigstore.json` names
> `...studio-release.yml@refs/tags/studio-v0.3.1-beta.1` and its attestations carry
> that source ref, while the notes and `releases.json` say `studio-v0.3.0-beta.1`.
> Anyone who downloaded on 10-22 holds different bytes again. Verify that release
> with `--certificate-identity ...@refs/tags/studio-v0.3.1-beta.1` and
> `--source-ref refs/tags/studio-v0.3.1-beta.1`, or install `0.3.0-beta.2` or later,
> which this page's procedure cuts correctly. A third set of bytes under the
> `0.3.0-beta.1` name is not recommended; see "Releases cut before the republish
> input" below.

Artifact attestations need the repository to be **public** on this org's plan. On a
private repository the attest step fails and the workflow creates no release, so the
first release must be tagged after the repository is public.

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

It is **not Authenticode-signed** yet; no certificate is configured. SmartScreen will
warn you the first time you run it. Verify it as in "Verifying a download" above, or at
least check its SHA-256 against `SHA256SUMS`:

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

The bundle needs the `org.kde.Platform` 6.11 runtime (the app is Qt, and the KDE
runtime already ships Qt; building against GNOME would mean bundling all of Qt). Since
this change the bundle also says where that runtime comes from (`flatpak build-bundle
--runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo`): when the installation
has no remote with that URL, `flatpak install` asks to add it as `flathub`, then fetches
the runtime before the app. On a machine with **no Flatpak remotes at all**:

```bash
flatpak install --user ./hugmesh-studio-<version>-x86_64.flatpak
flatpak run org.hugmesh.ImageStudio --generator-dir ~/Github/hugmesh-generator
```

On an ARM64 machine the file is `hugmesh-studio-<version>-aarch64.flatpak` and the
commands are the same. Each bundle carries its architecture in its name, and `flatpak
install` refuses a bundle built for another one (`flatpak --default-arch` prints the
one you need). There is no aarch64 tarball: the PyInstaller job runs on x86_64 only.
The aarch64 bundle is built by `flatpak-aarch64`, a twin of the `flatpak` job on
GitHub's hosted `ubuntu-24.04-arm` runner, from the same manifest (`python-deps.json`
pins the aarch64 PySide6 wheels beside the x86_64 ones); it is checksummed in
`SHA256SUMS`, covered by the cosign signature and attested like every other file. The
job also starts Qt offscreen inside the installed bundle, because `--print-specs` is the
Qt-free path and would pass with the wrong architecture's wheels inside.

The first command asks before it adds the remote (`-y` or `--noninteractive` answers
yes for you). Measured on flatpak 1.18.4 (2026-10-29): the question is asked whenever
no remote with that URL exists, even when the runtime is already installed, and
answering no fails the install with `Remote "flathub" not found`. So installing this
bundle means having Flathub as a remote in that installation. To add it yourself first,
which is the same thing one step earlier:

```bash
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user ./hugmesh-studio-<version>-x86_64.flatpak
```

**The published `0.3.0-beta.1` bundle** was exported before this change: it carries no
runtime hint and was built on `org.kde.Platform` 6.8, a branch Flathub now flags
end-of-life (it still installs). On a machine without that runtime it stops with
`requires the runtime org.kde.Platform/x86_64/6.8 which was not found` (reproduced
2026-10-29). Install the runtime by hand first, then the bundle:

```bash
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub org.kde.Platform//6.8
flatpak install --user ./hugmesh-studio-0.3.0-beta.1-x86_64.flatpak
```

The manifest requests `--filesystem=host` and `--talk-name=org.freedesktop.Flatpak`.
Those grants are broad. They let the app read your checkout and run host
`docker`/`qemu`. If you would rather not grant them, run the Studio from a checkout; it
needs no installer.

### Governed HugMesh desktops

The release is a **bundle**, not a Flathub app, because HugMesh's own governed desktops
remove the Flathub remote (`keys-template/desktop-governance/flatpak/flathub-disable.conf`)
so that the domain's registry is the only software source. What that policy does, read
from `provision_desktop_governance` in `specs/etc/keys-provision/provision.sh`: it
deletes `flathub` and the other listed names from the **system** installation
(`flatpak remote-delete --system`) and removes their preset files under
`/etc/flatpak/remotes.d`. It does nothing to **user** installations
(`~/.local/share/flatpak`): flatpak has no setting that forbids `flatpak remote-add
--user`, and provisioning does not try to.

So on a governed desktop the runtime hint in this bundle does what it does anywhere
else: `flatpak install --user <bundle>` asks to add a per-user `flathub` remote (and
adds it unasked with `-y`), pulls `org.kde.Platform` from it, and that remote is then
visible to Discover for that user, with everything on Flathub behind it. Saying no
leaves the bundle uninstalled, runtime present or not (measured above). There is no
way to install this bundle without a Flathub remote in the target installation, and
provisioning does nothing to stop a user adding one. This change does not weaken the
policy and does not route around it; it makes the bundle installable on every other
machine and says plainly that on a governed desktop a per-user install of it is a
per-user Flathub. If a governed desktop must not have Flathub even per user, that is
for provisioning to close, not for this bundle to pretend; the Studio for such a desktop
is the tarball or a checkout, neither of which touches Flatpak, or a build of the
bundle whose `--runtime-repo` names the domain registry once that carries the KDE
runtime.

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

**The one way:**

```bash
scripts/release-studio.sh 0.3.0-beta.2
```

With no argument it proposes the next beta of the current base and asks. It preflights
read-only (login, repository public, version valid and later than every existing
`studio-v*` tag, no release yet, nothing in progress, `main`'s `__version__` not past
it), prints the plan, asks `Proceed? [y/N]`, and starts **one** GitHub Actions run,
[**Cut a Studio release**](../.github/workflows/studio-release-cut.yml). That run:

1. commits the bump of `__version__` (and the matching `<release>` in the Flatpak
   metainfo) to `main`, through `studio/packaging/release_version.py bump`;
2. creates the tag `studio-v<version>` **on GitHub** at that commit (never on your
   machine);
3. dispatches [`studio-release.yml`](../.github/workflows/studio-release.yml) **on
   that tag** with `publish=true`. That run builds the MSI, the Flatpak and the
   tarball on GitHub-hosted runners, writes `SHA256SUMS`, signs it with cosign,
   attests every file, and only then creates the GitHub Release, marked
   **pre-release** and never "latest" for a beta.

The script streams both runs and ends with the release URL, the checksums and the
verify commands. Nothing else to do.

**The same thing from the browser:** Actions > **Cut a Studio release** > Run
workflow > `version` = `0.3.0-beta.2`, everything else left alone > Run. The cut
run's summary links the release run; that run's summary has the release URL.

**Rehearsal:** `scripts/release-studio.sh 0.3.0-beta.2 --dry-run` does the read-only
preflight, prints the plan and stops before anything is dispatched. The button's
`dry_run` box does the same on GitHub: it runs the guard tests and actionlint against
the tree that would execute and writes the plan ("What a real run WOULD do") to the
run summary, creating nothing. A manual run of `studio-release.yml` on `main` with
`publish` unticked is still the build-only rehearsal: it builds all three packages as
workflow artifacts and publishes nothing (with `publish` ticked on `main` it fails in
seconds instead, because `main` never publishes).

**After a failed build:** run the same command again. The cut is idempotent: `main`
already at the version means no bump; a tag already at that commit is kept; a tag at
another commit with no release behind it is moved to the bump commit (it says so,
loudly: nothing published references it); no release means dispatch. Nothing is ever
deleted. If the release already exists but with files missing because the upload died
half-way, the same command stops **red** with "already exists": that recovery is a
republish, by design, because some users may already hold the files that did upload.

### Re-publishing a version

`scripts/release-studio.sh 0.3.0-beta.2 --republish`, or the button with
`republish` ticked **and** the version typed into `confirm`.

This replaces every file of the existing release `studio-v0.3.0-beta.2` with new
bytes built from the same tag. **Every checksum, signature and attestation changes,
and anyone who downloaded earlier can no longer verify what they have against the
new notes.** The script prints that and makes you type the version back (`--yes`
does not skip it). The release notes then carry "Files replaced on `<date>` from
`<sha>`; every checksum, signature and attestation changed", and the run summary is
titled "REPUBLISHED: all checksums changed". The tag is never moved: a published tag
is the coordinate users' verify commands name.

The rule: **a wrong build gets a new beta N, not a republish.** Republish exists for
the half-uploaded case above and for a deliberate rebuild of the same commit.

### Releases cut before the republish input

`studio-v0.3.0-beta.1` points at b7edc89c, whose copy of `studio-release.yml` has
only the `publish` input. It **cannot** be re-published through this path: both the
script and the cut refuse with "the workflow file at tag studio-v0.3.0-beta.1
predates the republish input". A bare `gh workflow run studio-release.yml --ref
studio-v0.3.0-beta.1 -f publish=true` would run that old file and replace its files
silently, with no warning and no note. Do not do that. Cut `0.3.0-beta.2` instead,
and edit the beta.1 release notes to say it is superseded (see "Verifying a
download" for why its signature material names another tag).

### The hand-tag fallback

`git tag -a studio-v0.3.0-beta.3 -m "Studio 0.3.0-beta.3" && git push origin
studio-v0.3.0-beta.3` still publishes through the `push` trigger, but only when
`__version__` at that commit **equals** the tag's version; otherwise the version job
refuses in seconds (that gate was missing on 2026-10-23, which is how a push of
`studio-v0.3.1-beta.1` published under the `0.3.0-beta.1` name). The version bump
then has to be merged to `main` by hand first, so this is more steps than the
script, not fewer.

### The Downloads page

`hugmesh.github.io` rebuilds its `src/assets/releases.json` from the GitHub Releases
API itself (its `pages.yml`: hourly cron, a `releases-updated` dispatch, or a manual
run). **Nobody copies `releases.json` by hand.** After a release the Downloads page
refreshes within the hour; `scripts/release-studio.sh ... --site` runs
`gh workflow run pages.yml --repo hugmesh/hugmesh.github.io` with your own token to
ask for it now. The publish job also sends the `releases-updated` dispatch itself
when the repository secret `SITE_DISPATCH_TOKEN` exists (a fine-grained token with
Contents: read and write on `hugmesh/hugmesh.github.io` only); **it does not exist
today**, and the job prints a notice and goes on.

### Where the guard lives

Every job runs on a GitHub-hosted runner (`ubuntu-latest`, `ubuntu-24.04`,
`windows-latest`); no variable can move one onto the self-hosted runner. Only the
publish job of `studio-release.yml` can sign (`id-token` and `attestations: write`);
the cut's `cut` job holds `contents` and `actions: write` and nothing else. The
tests under `studio/tests/test_studio_beta_version.py`,
`test_studio_release_signing.py`, `test_studio_release_cut.py` and
`test_release_studio_script.py` parse and execute the workflows' own `run:` blocks
with fake tools; the cut runs the first two itself before it commits anything, and
`studio-tests.yml` runs them on every push to `main` that touches the release files,
so a hand edit of the workflow goes red where it happened.

**Authenticode (optional).** Add the secrets `STUDIO_AUTHENTICODE_PFX_BASE64` (a
base64-encoded code-signing `.pfx`) and `STUDIO_AUTHENTICODE_PFX_PASSWORD`, and the MSI
job signs the exe and the MSI with `signtool` before checksumming them; the release
notes and `releases.json` then stop saying SmartScreen will warn. Since 2023, newly
issued public code-signing certificates live on hardware tokens and cannot be exported
as a `.pfx`, so in practice this means a signing service (SignPath for open source, or
Azure Trusted Signing); its action replaces the two `signtool` steps at the same two
places. Until then the MSI is unsigned and SmartScreen warns.

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
