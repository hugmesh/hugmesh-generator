# Studio installers — Windows MSI, Linux Flatpak, Linux tarball and macOS .dmg

The usual way to get the HugMesh Image Studio is a package from the
[Downloads page](https://hugmesh.net/downloads) or the GitHub releases. There are six: a
Windows MSI, a Flatpak bundle for x86_64 Linux, one for aarch64 Linux, an x86_64 Linux
tarball, and a macOS disk image each for Apple silicon and Intel Macs
(`hugmesh-studio-<version>-macos-arm64.dmg` and `hugmesh-studio-<version>-macos-x86_64.dmg`;
see [macOS](#macos)). A checkout is for developers. It is also the way to do what the
Flatpak refuses (native sudo builds and writing images to devices), and to run the Studio
on BSD, which has no package yet. See
["Developer: run the Studio from a checkout"](#developer-run-the-studio-from-a-checkout).

Every package holds **the same application code**. The Flatpaks also carry the
hugmesh-generator build scripts of their own release. The MSI, the tarball and the `.dmg`
files do not include them yet. ["What a package gives you"](#what-a-package-gives-you) says what that means on
first start.

Maintainers cut a release with `scripts/release-studio.sh <version>`; see
["Cutting a release"](#cutting-a-release).

| Artifact | Platform | Built by |
|---|---|---|
| `hugmesh-studio-<version>-x64.msi` | Windows 10/11 x64 | PyInstaller → WiX v6 |
| `hugmesh-studio-<version>-x86_64.flatpak` | x86_64 Linux with Flatpak | flatpak-builder, `org.kde.Platform` 6.11 (the bundle names Flathub as its source) |
| `hugmesh-studio-<version>-aarch64.flatpak` | aarch64 (ARM64) Linux with Flatpak: Raspberry Pi 4/5 desktops, Apple-silicon VMs, Ampere machines | the same manifest on GitHub's hosted `ubuntu-24.04-arm` runner (job `flatpak-aarch64`) |
| `hugmesh-studio-<version>-linux-x86_64.tar.gz` | x86_64 Linux, glibc 2.39+ | PyInstaller (same spec as the MSI) |
| `hugmesh-studio-<version>-macos-arm64.dmg` | macOS 13+ on Apple silicon (signed ad hoc, not notarized; image builds EXPERIMENTAL) | PyInstaller (same spec) → `hdiutil`, by `studio/packaging/build-macos-app.sh` on GitHub's hosted `macos-15` runner (job `macos`) |
| `hugmesh-studio-<version>-macos-x86_64.dmg` | macOS 13+ on Intel (the same) | the same script on GitHub's hosted `macos-15-intel` runner (job `macos-intel`) |

[`.github/workflows/studio-release.yml`](../.github/workflows/studio-release.yml)
builds all six **on GitHub-hosted runners only**, signs them there, and attaches
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

## What a package gives you

The Studio is a **front end over host tooling**. It shells out to `docker`, `make`,
`bash`, `qemu`, `kubectl`, `lsblk` and `ssh`. It runs the build scripts and reads the
cluster specs of a `hugmesh-generator` tree. A package can carry that tree, but not the
host tools.

| Package | The hugmesh-generator build scripts | On first start |
|---|---|---|
| Flatpak, x86_64 and aarch64 (0.4.4-beta.1 and later) | **Included.** The bundle carries the tree of its own release (`share/hugmesh-studio/generator-seed.tar.gz`). | Studio places that copy in `~/.local/share/hugmesh-studio/generator` and uses it. There is nothing to clone. |
| Windows MSI, Linux tarball, macOS .dmg | **Not included yet** ([#977](https://github.com/hugmesh/hugmesh-generator/issues/977)). | Studio shows *Choose your hugmesh-generator folder*. Clone `hugmesh-generator` (`git clone https://github.com/hugmesh/hugmesh-generator`), pick that folder, and Studio remembers it. |

How the copy works and what overrides it:

- **Upgrades.** Each Flatpak upgrade refreshes the placed copy to the new release. It
  keeps your `out/`, `keys-out/` and `tests/stack/.env`.
- **What takes precedence.** The Studio uses the first of these that is a real checkout:
  `--generator-dir <path>`, `$HUGMESH_GENERATOR_DIR`, the checkout it is running from,
  the working directory, a folder you picked in an earlier start, and only then the copy a
  package carries. So a clone you name or pick still wins over the package's copy.
- **Checking it.** `flatpak run org.hugmesh.ImageStudio --self-check` says which tree it
  resolved and whether every script the Studio runs is there.
- **The release data.** `releases.json` records per file whether that file carries the tree
  (`"generatorSeed"`). The release job sets it only for a file whose own
  `--self-check` placed and checked the bundled tree, and the
  [Downloads page](https://hugmesh.net/downloads) drops its clone step for that file.

After installing any package:

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

It does not include the hugmesh-generator build scripts yet
([#977](https://github.com/hugmesh/hugmesh-generator/issues/977)). So on first start the
Studio shows *Choose your hugmesh-generator folder*. Clone the repository
(`git clone https://github.com/hugmesh/hugmesh-generator`), pick that folder, and the
Studio remembers it for later starts. The Start Menu shortcut passes no arguments, so this
chooser is the way to set the folder there.

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

**The Flatpak.** Install the bundle for your machine's architecture, then start it:

```bash
flatpak install --user ./hugmesh-studio-<version>-x86_64.flatpak
flatpak run org.hugmesh.ImageStudio
```

The Flatpak carries the hugmesh-generator tree of its own release, so there is nothing
to clone. On first start it places that copy in `~/.local/share/hugmesh-studio/generator`
and uses it. An upgrade keeps your `out/`, `keys-out/` and `tests/stack/.env` there. A
clone you name with `--generator-dir`, or picked in an earlier start, still wins. It
builds with the host's Docker, which it reaches through `flatpak-spawn --host`. Native
(sudo) builds and writing images to devices need the Studio run from a checkout.
`flatpak run org.hugmesh.ImageStudio --self-check` says whether all of that works here.

**The tarball** (x86_64 only; needs glibc 2.39 or newer: Ubuntu 24.04, Debian 13,
Fedora 40 or later) has no install step:

```bash
tar -xzf hugmesh-studio-<version>-linux-x86_64.tar.gz
./hugmesh-studio-<version>-linux-x86_64/hugmesh-studio
```

It does not include the hugmesh-generator build scripts yet
([#977](https://github.com/hugmesh/hugmesh-generator/issues/977)). On first start it asks
for the folder you cloned `hugmesh-generator` into, and remembers your pick.

The Flatpak bundle needs the `org.kde.Platform` 6.11 runtime. The app is Qt, and the KDE
runtime already ships Qt; building against GNOME would mean bundling all of Qt. The
bundle also says where that runtime comes from (`flatpak build-bundle
--runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo`). When the installation
has no remote with that URL, `flatpak install` asks to add it as `flathub`, then fetches
the runtime before the app. So the install above works even on a machine with **no
Flatpak remotes at all**.

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
Those grants are broad. They let the app use a generator tree under your home and run
host `docker`/`qemu` through `flatpak-spawn --host`. If you would rather not grant them, run the Studio from a checkout; it
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

## Developer: run the Studio from a checkout

A packaged Studio needs none of this. Run it from a checkout when you:

- change the Studio or the build scripts;
- need a native (sudo) Gentoo build or want to write images to devices, which the
  Flatpak refuses;
- are on macOS or BSD, which have no package yet.

```bash
git clone https://github.com/hugmesh/hugmesh-generator
cd hugmesh-generator/studio
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
./hugmesh-studio            # Windows: hugmesh-studio.bat
```

A Studio run from a checkout drives that same checkout, with no flag.
`python -m hugmesh_studio` from `studio/` does the same thing. On Linux,
`scripts/studio-launch.sh` is a guided launcher that offers to create the venv for you.

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
when the secret `SITE_DISPATCH_TOKEN` exists (a fine-grained token with resource owner
`hugmesh`, only `hugmesh/hugmesh.github.io`, Contents: read and write; approved, if the
organization requires approval for fine-grained tokens). It is an organization secret
since 2026-11-10. Without it the step prints a notice. **The step is never fatal**: it
runs after the release is published, so any answer but `204` (a refused or unapproved
token, a GitHub error, no connection) is a `::warning::` that quotes GitHub's message,
and the run stays green. The first Studio release with the secret set
(`studio-v0.4.4-beta.1`, run 42882326209) went red on a 403 from `curl -fsS` before this
was changed. To re-send the notice, run `gh workflow run pages.yml --repo
hugmesh/hugmesh.github.io`; never re-run the release for it (a re-run is a republish).

### Where the guard lives

Every job runs on a GitHub-hosted runner (`ubuntu-latest`, `ubuntu-24.04`,
`ubuntu-24.04-arm`, `windows-latest`, `macos-15`, `macos-15-intel`); no variable can move
one onto the self-hosted runner. Only the
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

## macOS

The Studio runs on macOS 13 or newer, on Apple silicon (arm64) and Intel (x86_64).
`studio/packaging/build-macos-app.sh` builds **`HugMesh Image Studio.app`** and packs it
into `hugmesh-studio-<version>-macos-<arch>.dmg`. It uses the same PyInstaller spec as the
MSI and the tarball; the spec's darwin-only `BUNDLE` step makes the `.app`.

**On every release.** The `macos` and `macos-intel` jobs of `.github/workflows/studio-release.yml`
build `hugmesh-studio-<version>-macos-arm64.dmg` and `hugmesh-studio-<version>-macos-x86_64.dmg`
on GitHub's `macos-15` (Apple silicon) and `macos-15-intel` runners. They run the same
script, with the same arguments, as the `macos` job of `.github/workflows/studio-tests.yml`,
which builds and checks both `.dmg` files on every Studio pull request (kept for 7 days as
the run artifacts `macos-dmg-arm64` and `macos-dmg-x86_64`). The publish job lists both
files in `SHA256SUMS` (signed with cosign), attests them like every other file, and lists
them in `releases.json` as `"platform": "macos"`, `"kind": "dmg"` with an `"arch"` of `arm64`
or `x86_64`. Verify a `.dmg` as in [Verifying a download](#verifying-a-download); on a Mac,
`shasum -a 256 <file>` prints the line to compare with `SHA256SUMS`. The app is signed ad
hoc and not notarized (see the next section), and image builds on a Mac are EXPERIMENTAL:
no hosted macOS runner has Docker, so no image build on a Mac has been proven yet. The
release notes say both.

### First start: Gatekeeper

The app is signed ad hoc, not with a Developer ID, and it is not notarized. So a copy
downloaded with a browser is refused the first time you open it. On macOS 15 (Sequoia),
Control-click → Open no longer gets past this:

1. Open the app once and dismiss the warning.
2. Go to System Settings → Privacy & Security, scroll to Security, click **Open Anyway**
   next to "HugMesh Image Studio", and confirm with your password.

On macOS 13 and 14, Control-click the app → **Open** → **Open** does the same. To clear
the download flag from Terminal instead:

```sh
xattr -dr com.apple.quarantine "/Applications/HugMesh Image Studio.app"
```

The executable inside the bundle is also the command-line tool:

```sh
"/Applications/HugMesh Image Studio.app/Contents/MacOS/hugmesh-studio" --self-check
```

### What a Mac needs

- **The GNU tools.** The generator's scripts are written for bash 4+ and GNU sed, find,
  grep, stat and make. macOS ships bash 3.2 and the BSD tools. Install them with
  [Homebrew](https://brew.sh):

  ```sh
  brew install bash coreutils gnu-sed findutils grep make
  ```

  You do not need to change your shell or PATH. When the Studio starts (the window,
  the text UI `python -m hugmesh_studio.tui`, or any `python -m hugmesh_studio.core.…`
  command line), it puts
  Homebrew's `gnubin` folders and `bin` first in its own PATH. It also adds Docker
  Desktop's, colima's and OrbStack's CLI folders, so an app opened from Finder finds them
  (Finder gives an app only `/usr/bin:/bin:/usr/sbin:/sbin`). Without the tools, every
  verb that runs the generator's scripts refuses with that `brew install` line, and so
  does `--self-check`.
- **A Docker runtime** for building images: Docker Desktop for Mac, colima
  (`brew install colima docker`) or OrbStack. Builds run in that runtime's Linux VM, so
  size the VM, not the Mac: at least 16 GB of memory and a 200 GB disk. In Docker Desktop
  that is Settings → Resources. With colima:

  ```sh
  colima start --vm-type vz --vz-rosetta --cpu 8 --memory 16 --disk 200
  ```

  On Intel, use `--arch x86_64` instead of `--vz-rosetta`:

  ```sh
  colima start --vm-type vz --cpu 8 --memory 16 --disk 200 --arch x86_64
  ```

  On Apple silicon, also turn on
  Docker Desktop's "Use Rosetta for x86_64/amd64 emulation on Apple Silicon" (colima:
  `--vz-rosetta`). The builder image is x86_64, so the Studio runs it with
  `--platform linux/amd64` there.

  A build gets at most the VM's CPUs. Docker refuses to start a container that asks for
  more CPUs than its VM has ("range of CPUs is from 0.01 to 8.00"), and the Studio's
  default CPU limit is every core of the Mac but one. So the Studio reads the VM's CPU
  count when it starts and lowers the limit to it, for a build's `--cpus` and for the
  local stack's compose limits, and the build preflight says when it did. To build
  faster, give the VM more CPUs and restart the Studio. To leave more of the VM free,
  set `HUGMESH_CPUS` (for example `HUGMESH_CPUS=4`) or use the Studio's resource limits.
  The VM's memory needs no such step: Docker accepts a memory limit above what the VM
  has.
- **A case-sensitive folder for the build output.** A build writes a Linux kernel tree
  and a Gentoo root into its output directory, and APFS ignores case by default. The
  build preflight checks the folder itself and refuses one that ignores case. The fix
  takes free space from the Mac's disk, repartitions nothing and needs no sudo (the new
  volume is writable by you):

  ```sh
  diskutil apfs addVolume "$(diskutil info -plist / | plutil -extract APFSContainerReference raw -)" 'Case-sensitive APFS' HugMeshBuild
  ```

  Then use `/Volumes/HugMeshBuild/out` as the output directory. Docker Desktop and
  OrbStack share `/Volumes` with their VM already. colima shares only your home folder
  (its FAQ), so add the volume to `mounts:` in `~/.colima/default/colima.yaml` and run
  `colima restart`.

### What works on a Mac, and how far it is proven

| | Status |
|---|---|
| The `.app`: freeze, Info.plist, Mach-O architecture, Qt cocoa plugin, package data, ad-hoc signature, `.dmg` contents | **Proven on real Macs**, arm64 and x86_64, on every Studio pull request |
| A real window starts on the cocoa plugin and is still running 20 s later | **Proven** (`--gui-smoke`; the screenshot is in the artifact) |
| Started with Finder's PATH, the app finds Homebrew's GNU tools through its own PATH hook | **Proven** (the frozen app's `--self-check --json`) |
| A stock Mac (no Homebrew tools) is refused with the `brew install` line | **Proven** |
| `--self-check` from a checkout parses every generator script with bash 5 | **Proven** |
| A case-insensitive output folder is refused. The remedy, run as written, adds a case-sensitive volume without sudo, and a folder on it clears the refusal. | **Proven** (the volume is added, checked and deleted on both runners) |
| A command opened in Terminal.app runs and its `.command` file deletes itself | **Proven** (`open -a Terminal` on the runner) |
| `sysctl` architecture and Hypervisor.framework probes | **Proven** against both runners' real output |
| An image **build** through Docker Desktop, colima or OrbStack | **Not proven, and labelled EXPERIMENTAL in the preflight.** GitHub's macOS runners have no nested virtualisation, so no Docker. The output folder is bind-mounted from macOS into the VM, and device nodes and extended attributes over that mount are untested. The follow-up is a Docker named volume as the work directory, with an export step. |
| Emulated devices (the QEMU lane) | Through the Docker lane only, under full emulation (TCG). The KVM note says so. Driving Homebrew's QEMU with `-accel hvf` natively is a follow-up. |
| Writing an image to an SD card or USB stick | **Not offered.** The Studio's writer uses Linux block devices. The flash step shows the `diskutil list external physical` / `diskutil unmountDisk` / `dd of=/dev/rdiskN` / `diskutil eject` commands to run by hand. A `diskutil` writer with the same safety checks is a follow-up. |

### Choices, and why

- **Terminal windows** (go-live, cloud deploy, phone wizard, device login, the local AI
  agent) open Terminal.app, or iTerm2 when it is installed, on a 0700 `.command` file
  that deletes itself as it starts. Not `osascript … tell application "Terminal"`:
  scripting Terminal needs an Automation consent per app signature, and an ad-hoc
  signature changes with every build, so every upgrade would ask again. Terminal.app
  does not inherit the Studio's environment, so the file exports what the command needs
  (an allowlist, never a token).
- **The state folder stays `~/.hugmesh/studio`**, as on Linux, WSL and Windows. It is not
  `~/Library/Application Support/HugMesh Image Studio`, for two reasons. The single-instance
  socket in that folder would exceed macOS's 104-byte socket path limit once a user name
  reaches 17 characters. And the space in "Application Support" would flow into the
  `docker run -v` arguments and bash scripts the Studio hands paths to.
- **No Keychain.** Secrets stay in the 0600 files and the in-memory vault every other
  POSIX platform uses. The Keychain needs a stable signing identity, prompts on each
  access for an ad-hoc app, and would be a third secrets contract to test.

### Building it locally

```sh
python3 -m venv .venv-mac
.venv-mac/bin/pip install --only-binary=:all: -r studio/packaging/macos-build-requirements.txt
studio/packaging/build-macos-app.sh --python .venv-mac/bin/python      # --gui-smoke opens a window
```

The script refuses to run anywhere but macOS. `--help` lists its phases and options. It
runs under macOS's own `/bin/bash` 3.2.

### Signing and notarizing (an operator step; not yet run)

These commands are the standard Developer ID route. **They have not been run against
this app.** They need an Apple Developer account, a "Developer ID Application"
certificate in the login keychain, and an app-specific password. `<TEAMID>`, the
certificate name and the Apple ID are yours.

```sh
APP="studio/dist/HugMesh Image Studio.app"
ID="Developer ID Application: <Name> (<TEAMID>)"
# A PyInstaller app under the hardened runtime usually needs these two entitlements:
cat > entitlements.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
PLIST
# 1. sign every library and executable inside, innermost first, then the bundle
find "$APP/Contents" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -u+x \) -print0 |
  xargs -0 codesign --force --timestamp --options runtime --entitlements entitlements.plist --sign "$ID"
codesign --force --timestamp --options runtime --entitlements entitlements.plist --sign "$ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
# 2. notarize the app and staple the ticket to it
xcrun notarytool store-credentials hugmesh-notary --apple-id <apple-id> --team-id <TEAMID>
ditto -c -k --keepParent "$APP" app.zip
xcrun notarytool submit app.zip --keychain-profile hugmesh-notary --wait
xcrun stapler staple "$APP"
# 3. re-pack the .dmg from the stapled app (build-macos-app.sh's dmg phase), then sign,
#    notarize and staple the .dmg itself
codesign --force --timestamp --sign "$ID" hugmesh-studio-<version>-macos-arm64.dmg
xcrun notarytool submit hugmesh-studio-<version>-macos-arm64.dmg --keychain-profile hugmesh-notary --wait
xcrun stapler staple hugmesh-studio-<version>-macos-arm64.dmg
spctl --assess --type open --context context:primary-signature -v hugmesh-studio-<version>-macos-arm64.dmg
```

When a certificate exists, these steps belong in the release workflow's `macos` jobs,
gated on a secret the way Authenticode is in the `msi` job.
