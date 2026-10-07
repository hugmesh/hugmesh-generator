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
| `HUGMESH_STUDIO_FLATPAK_OUT` | `~/.hugmesh-wt-local/dist-studio` | the bundle, its `.sha256`, and `flatpak-work/` (the Builder's state in `.flatpak-builder/`, the repository, the log; about 2 GiB). May not be inside the private directory. |
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

Measured on 2026-09-30 (Gentoo, flatpak 1.18.1, no sudo, a fast connection), with the
script as it then was (the Builder ran with `--state-dir`; see the next section for
what that changed): from an empty private directory it took 359 s end to end: about two
minutes downloading the toolchain, under a minute building, three minutes compressing
the bundle (one CPU), and a few seconds installing and checking. A re-run with the
toolchain installed and the build cache warm took 215 s, almost all of it the
compression. Both runs were made with fake `sudo`, `apt-get`, `dnf` and `pacman` first
on `PATH` that record any call, and none was made (that covers the script and what it
starts; the commands the Builder runs through the host's session helper start from the
host's own environment). Both finished with all three smoke tests passing. Measured
again on 2026-10-07 with flatpak 1.18.4, the same script bytes and the toolchain already
installed: 235 s, all three smoke tests passing, and fakes for `sudo`, `doas`, `pkexec`,
`su`, `run0` and ten package managers first on `PATH` recorded no call. The script as
committed (no `--state-dir`, `--cwd`) was measured the same day from an empty private
directory and a long checkout path: 533 s with three other builds sharing the machine;
see the next section. Two things those runs saw are worth knowing: `flatpak install
--bundle` also fetches updates for the runtime's related extensions (the GL drivers)
from flathub into the private directory, so a re-run is not offline; and two runs
produce bundles with different checksums from the same source (an OSTree commit carries
its timestamp), so a checksum identifies one build, not the source it came from.

`../../tests/test_flatpak_packaging_files.py` runs the script against a scripted fake
`flatpak` as well, through all three smoke tests, and holds it to what this page says:
every call goes to the private directory and none to `--system`, the Builder is granted
that directory and runs with `flatpak-work/` as its working directory and no
`--state-dir` (see below), the build uses the release workflow's flags, both validators
run, the build output may not live inside the private directory, a second run against
the same output directory is refused, and each smoke test refuses what it must: a
`--print-specs` that prints nothing, blank lines or anything but JSON objects; a Qt check
that does not report `qt-ok` with PySide6; an install with any of the five files missing
or with no launcher exported. The test that the script never runs `sudo` or a package
manager is a static reading of the script, and it reads exactly the forms its own test
pins: a command behind an environment assignment, a redirection, a prefix such as
`env`, `timeout`, `coproc`, `busybox` or `unshare` (past the prefix options that take a
separate value, such as `exec -a NAME` or `env -u VAR`), past the lock operand of
`flock` and the root of `chroot`, a shell's `-c` string (`flock`'s too), `eval`, the
action string of `trap`, a here-string fed to a shell or python, `find -exec`,
`flatpak-spawn --host`, a `--command=` option and the app id after it (the two forms
the script itself uses), a `function` definition, a `$( )`, `<( )` or `>( )`
substitution (in an unquoted heredoc too), `$'...'` quoting, and embedded Python read
whole for process calls. What it cannot read (a sourced file, a shell or python fed by a
pipe, a file or a process substitution) it reports instead of passing. Anything else is
outside it: a program named through a variable, an alias, a program in another language
(`awk`, `perl`), a command run on another machine (`ssh`), a wrapper it does not know
(`taskset`, `script`, ...). The test pins a sample of those as outside, expecting no
hit, so that the scanner's reach is written down rather than assumed. (Three mutation
batteries drove this: the first showed each file-reading check could be lost with the
suite still green; the second put `sudo` into the script's own two spellings and the
scanner of the time, which took the app id for a script file, saw neither; the third
put it behind a process substitution and the suite stayed green, while a probe of
forty-two spellings found fifteen more it was silent on.)

### Where the Builder keeps its state, and why

The Builder runs with `flatpak-work/` as its working directory and **no `--state-dir`**,
so its state is `flatpak-work/.flatpak-builder/` (as in the release workflow's in-tree
build) and its cache branch is `x86_64-org.hugmesh.ImageStudio.yml`. With `--state-dir`
it names that branch after the manifest's **absolute path** instead, with `/` spelled
`_2F`, and keeps it as one file under `refs/heads/`. On an encrypted home (eCryptfs
allows 143 bytes per file name) that name is too long for any checkout path over 77
bytes, and the build then stopped with a bare `File name too long` after the whole
toolchain had been installed and the validators had run (measured: a checkout path 38
characters longer than `~/Github/hugmesh-generator` gave a 147-byte name, where that
checkout's own is 109). The scripted test pins the `--cwd` and the absence of
`--state-dir`. Measured end to end twice on 2026-10-07, with the script as committed,
from checkouts whose old-style names would be 158 and 147 bytes, each from an empty
private directory, with fakes for `sudo`, `doas`, `pkexec`, `su`, `run0`, eleven
package managers and `flatpak-builder` first on `PATH`: exit 0 in 533 s and 631 s
(other builds were sharing the machine both times), all three smoke tests passing, the
bundle's `sha256sum -c` OK, no fake called, the Builder's state under
`flatpak-work/.flatpak-builder/` with the one cache ref
`x86_64-org.hugmesh.ImageStudio.yml`, nothing written into the checkout, and the user's
own flatpak directories unchanged before and after. The previous script, run from the
same checkouts against the same private directories, failed in 5 s and 7 s with `File
name too long`.

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
| Validators, runtime, `flatpak build-bundle`, bundle name, checksum | as listed in the workflow | the same calls and names, except that the bundle is first written as `<name>.partial` and renamed when whole. `tests/test_flatpak_packaging_files.py` reads the workflow and compares them. |
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
