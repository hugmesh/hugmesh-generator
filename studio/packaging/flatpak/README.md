# Studio Flatpak packaging

Everything that makes `org.hugmesh.ImageStudio` a Flatpak, and the one command that
builds it on a machine with **no sudo, no apt and no `flatpak-builder` package**.

| File | What it is |
|---|---|
| `org.hugmesh.ImageStudio.yml` | The manifest `flatpak-builder` builds. Its source is the whole of `studio/`, so it carries a skip list: without one a stale `build/lib` in a used checkout ships inside the Flatpak (measured). |
| `python-deps.json` | PySide6 6.8.3 and `tzdata` as pinned wheels (a sha256 each, x86_64 and aarch64). Generated, then committed. The manifest's first module: without it nothing builds. |
| `org.hugmesh.ImageStudio.desktop`, `.metainfo.xml` | The launcher and the AppStream data. |
| `../build-flatpak-local.sh` | Builds, exports, installs and smoke-tests the Flatpak locally. |
| `.gitignore` | Keeps the output of a by-hand build in this directory out of git. |

The release workflow (`.github/workflows/studio-release.yml`, job `flatpak`) builds the
same manifest on a GitHub runner. `tests/test_flatpak_packaging_files.py` keeps the two
and the files in this directory from drifting apart.

## Build it here, with no sudo and no apt

```bash
studio/packaging/build-flatpak-local.sh
```

All it needs from the host is the `flatpak` program and a desktop login's D-Bus session
(see "How it builds" for why). It does five things and stops at the first one that fails:

1. adds flathub to a **private** flatpak directory and installs `org.flatpak.Builder`
   (that is `flatpak-builder`, as a flatpak) plus the runtime and SDK the manifest names;
2. runs `desktop-file-validate` and `appstreamcli validate --no-net`, as the workflow does;
3. builds `org.hugmesh.ImageStudio` from the manifest;
4. exports `hugmesh-studio-<version>-<arch>.flatpak` and its `.sha256`, with the same
   `flatpak build-bundle` call as the workflow;
5. installs that bundle into the private directory and runs it: `--print-specs` has to
   print JSON (the workflow's own smoke test), then Qt has to start on its offscreen
   platform with PySide6 and the package data present, then the launcher, metadata and
   icons have to be installed.

Where things go (all of these can be overridden, `--help` lists them):

| Setting | Default | Holds |
|---|---|---|
| `HUGMESH_STUDIO_FLATPAK_USER_DIR` | `~/.hugmesh-wt-local/flatpak-studio` | the private flatpak directory: runtimes, the Builder, the installed app (about 10 GiB) |
| `HUGMESH_STUDIO_FLATPAK_OUT` | `~/.hugmesh-wt-local/dist-studio` | the bundle, its `.sha256`, and `flatpak-work/` (build state and log, about 2 GiB) |
| `HUGMESH_STUDIO_FLATPAK_MIN_FREE_GIB` | 14 on a first run, 4 after | refuse to start with less free space than this |

It refuses to run if the private directory is your own flatpak directory
(`~/.local/share/flatpak` or `$XDG_DATA_HOME/flatpak`), one inside it, one that contains
it, or `/var/lib/flatpak`. It never writes there. Running a Flatpak app does create
`~/.var/app/<app-id>` in your real home whatever `FLATPAK_USER_DIR` says; here that is
`org.flatpak.Builder` and `org.hugmesh.ImageStudio`, holding only those two apps' own data.

Run the installed app, and remove everything again:

```bash
FLATPAK_USER_DIR=~/.hugmesh-wt-local/flatpak-studio flatpak run --user org.hugmesh.ImageStudio
rm -rf ~/.hugmesh-wt-local/flatpak-studio ~/.hugmesh-wt-local/dist-studio/flatpak-work
```

Measured on 2026-09-30 (Gentoo, flatpak 1.18.1, no sudo, a fast connection): from an
empty private directory it took 359 s end to end: about two minutes downloading the
toolchain, under a minute building, three minutes compressing the bundle (one CPU), and
a few seconds installing and checking. A re-run with the toolchain installed and the
build cache warm took 215 s, almost all of it the compression. Both runs were made with
fake `sudo`, `apt-get`, `dnf` and `pacman` first on `PATH` that record any call, and none
was made (that covers the script and what it starts; the commands the Builder runs
through the host's session helper start from the host's own environment). Both finished
with all three smoke tests passing. Measured again on 2026-10-07 with flatpak 1.18.4 and
the toolchain already installed: 235 s, all three smoke tests passing, and fakes for
`sudo`, `doas`, `pkexec`, `su`, `run0` and ten package managers first on `PATH` recorded
no call. Two things that run saw are worth knowing: `flatpak install --bundle` also
fetches updates for the runtime's related extensions (the GL drivers) from flathub into
the private directory, so a re-run is not offline; and the two runs produced bundles
with different checksums from the same source (an OSTree commit carries its timestamp),
so a checksum identifies one build, not the source it came from.

`../../tests/test_flatpak_packaging_files.py` runs the script against a scripted fake
`flatpak` as well, and holds it to what this page says: every call goes to the private
directory and none to `--system`, the Builder is granted that directory, the build uses
the release workflow's flags, both validators run, and an empty `--print-specs` is a
failure. (A mutation battery showed each of those could be lost with the earlier,
file-reading checks still green; the script was right, its guard was thin.)

If it fails, it says which step, and a re-run is safe: the toolchain and the caches are
reused. Two failures have a specific cause worth knowing:

* `no D-Bus session bus`, or the Builder "could not run a command on the host": the
  flatpak session helper is not reachable. Run from a desktop login.
* `bwrap: Can't find source path /run/user/<uid>/.flatpak-helper/monitor`: the helper is
  running but its directory under `$XDG_RUNTIME_DIR` is gone, and then **every** flatpak
  sandbox on that login fails to start, whatever app it is. Seen once while this was
  written; the cause was not found. The script spots it and prints the helper's pid;
  `kill <pid>` and it restarts on demand.

## How it builds without `flatpak-builder` on the host

`org.flatpak.Builder` is a flatpak app, and a flatpak sandbox is not allowed to create
another sandbox (inside it even `unshare -U` is refused), so `flatpak-builder` cannot
run its build steps itself. It asks the **host** flatpak to, through
`flatpak-spawn --host`. That has four consequences, each measured here, and the script
handles each:

* **The Builder's own wrapper is unusable for this.** `flatpak run org.flatpak.Builder`
  starts `flatpak-builder-wrapper`, which sets `FLATPAK_USER_DIR=$HOME/.local/share/flatpak`
  unconditionally: your own flatpak directory. The script calls `flatpak-builder`
  directly instead.
* **Flatpak hides the active user-installation directory from every sandbox** unless it
  is granted by name. Without `--filesystem=<private dir>` the Builder sees an empty
  directory there and finds no runtime.
* **The host command does not inherit the Builder's environment.** It starts from the
  host session's, which has no `FLATPAK_USER_DIR`. `FLATPAK_BINARY` therefore points at a
  two-line script the build writes into `flatpak-work/bin/`, which pins the private
  directory and then runs the real `flatpak`.
* **The Builder is granted host command execution** (`org.freedesktop.Flatpak=talk` is
  in its own metadata). That is how the official Builder is designed to work; it is
  also why this needs a session where the flatpak session helper can start, i.e. a
  normal desktop login and not a bare ssh session.

The script proves that route with one cheap command before the long build depends on it.

## What the release workflow does differently

| | Release workflow | `build-flatpak-local.sh` |
|---|---|---|
| Tooling | `apt-get install flatpak-builder appstream desktop-file-utils` (needs root) | `org.flatpak.Builder` from flathub, into a private directory |
| Where it builds | inside the checkout, in `studio/packaging/flatpak` | outside it, under `HUGMESH_STUDIO_FLATPAK_OUT` |
| Validators, runtime, `flatpak build-bundle`, bundle name, checksum | as listed in the workflow | the same calls, the same names |
| Smoke test | `--print-specs` is not empty | `--print-specs` is JSON; Qt starts with PySide6; launcher and icons exist |
| Runs when | on a tag or by hand, on GitHub | whenever you run it |

The workflow job itself has **not** been run (GitHub Actions on this account dies in
seconds on a billing annotation), so "the script builds" is not "the workflow builds".
What was checked is its build step: the manifest was built in-tree, in a copy of the
tree, twice, with the workflow's own `flatpak-builder` flags and the same builder
version the script uses. Both passed (40 s, then 23 s). A fresh in-tree build does not
recurse into its own state directory, because flatpak-builder skips `.flatpak-builder`
and `build-dir` itself; it does not skip `repo/`, which is why the manifest's skip list
names it.

## What the packaged app can and cannot do

Measured on the installed 1.0.0 bundle on 2026-09-30, on a host that has Docker.

It works: the app starts; `--print-specs` prints its JSON; PySide6 6.8.3 loads and
runs Qt on the offscreen platform; the real wizard window builds and draws (its welcome
page rendered to an image); the xcb and Wayland platform plugins both load all their
libraries (they fail only at "no display", which is what a test with no display should
see).

It cannot build an image. Inside the sandbox `PATH` is `/app/bin:/usr/bin` and holds no
`docker`, `kubectl`, `git` or `qemu`, and nothing in the Studio's code calls
`flatpak-spawn --host`, so it detects no backend even though the host has Docker
(`default_backend = 'none'`, `has_docker = False`) and the welcome page says "This
machine can't build images yet ... Detected: OS=linux · x11 · no-docker". The permission
that would allow it is granted and works (`flatpak-spawn --host which docker` finds
`/usr/bin/docker` from inside); the application does not use it. Until the Studio wraps
its host tools with `flatpak-spawn --host`, the Flatpak is a way to configure and
preview a build, and a build still has to be run from a checkout.

It is large. The installed app is 675 MB, of which PySide6's wheels are 625 MB (real
bytes, symlinks not counted twice), and the Python side loads *their* Qt
(`PySide6/Qt/lib/libQt6Core.so.6`), not the runtime's. `PySide6_Addons` alone is 362 MB,
including a 186 MB Chromium engine and ffmpeg, and the Studio imports only `QtCore`,
`QtGui` and `QtWidgets`, all from `PySide6_Essentials` (262 MB). Installing only
Essentials would roughly halve the app and leave a browser engine out of a bundle that
has no update channel. That changes the dependency set, so it is a decision for the
maintainers and not part of this change.

## Regenerating `python-deps.json`

Do this whenever the runtime branch changes (PySide6 is pinned to the same minor release
as the runtime's Qt; the test fails if they disagree) or PySide6 needs to move.

`flatpak-pip-generator` ships inside the Builder, but it has to run on the **host**: it
starts the SDK in a sandbox to ask it for the Python version, and a sandbox inside the
Builder's sandbox is the thing that does not work. It also refuses PySide6 unless
`FLATPAK_PIP_GENERATOR_ALLOW_RESTRICTED_MODULES=1` is set (its message is "please use the
baseapp", the right answer for Flathub and not for this bundle) and takes platform-only
wheels only when `--prefer-wheels` names them. After one run of `build-flatpak-local.sh`,
so that the Builder and the SDK are installed:

```bash
export FLATPAK_USER_DIR=~/.hugmesh-wt-local/flatpak-studio
work="$(mktemp -d)" && cd "$work"
python3 -m venv venv && venv/bin/pip install 'requirements-parser<1.0.0,>=0.11.0' packaging
generator="$FLATPAK_USER_DIR/app/org.flatpak.Builder/x86_64/stable/active/files/bin/flatpak-pip-generator"
FLATPAK_PIP_GENERATOR_ALLOW_RESTRICTED_MODULES=1 venv/bin/python "$generator" \
    --runtime=org.kde.Sdk//6.8 \
    --prefer-wheels=PySide6,PySide6-Addons,PySide6-Essentials,shiboken6 \
    --output python-deps 'PySide6==6.8.3' tzdata
cp python-deps.json /path/to/hugmesh-generator/studio/packaging/flatpak/
```

Set `TMPDIR` to somewhere with a few hundred MB free first: the generator downloads the
wheels to compute their hashes. Then run `build-flatpak-local.sh` again and read the
smoke tests.

## Runtime version

The manifest builds against `org.kde.Platform//6.8`. Flathub flags that branch
end-of-life (checked 2026-09-30: it still installs; `6.10` and `6.11` are current).
The release workflow installs the same branch by name, so moving the manifest alone
would make the job stop at a missing SDK. The test
`test_runtime_branch_matches_what_the_release_workflow_installs` holds the two together:
change the manifest, the workflow's install line and `python-deps.json` in one commit.

## Not verified

* No window was ever shown on a display: every check above runs on Qt's offscreen
  platform or stops at "no display". The tray and Wayland behaviour are untested.
* The release workflow's flatpak job has never run.
* aarch64: `python-deps.json` carries aarch64 wheel pins; nothing was built for it.
* One of the 16 builds made while this was written failed in `appstreamcli compose`
  (`icon-file-read-error`) with inputs identical to the build before it. It happened
  minutes before the session helper fault described above and did not repeat in six
  identical builds after that was cleared; its cause is not established.
