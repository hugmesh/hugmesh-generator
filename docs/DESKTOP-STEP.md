# The Desktop step: how a Studio choice reaches a desktop image

Operator ask (2026-11-11): "allow for a step to configure each desktop, login, window
managers on board, compositers, per build being made, users, roles, installed apps and if
they're native or flatpak, video drivers, and the ai assistant will help it run emerge
pretend and resolve any build flag or package useflag issues. It can also configure python."

What the operator sees is described in [STUDIO-WALKTHROUGH.md](STUDIO-WALKTHROUGH.md#desktop).
This page covers the plumbing behind it: the model, the flags, what each builder does with
them, and the `emerge --pretend` check.

## The model

`studio/hugmesh_studio/core/desktop_spec.py` holds `DesktopSpec`. It is stored as
`ImageConfig.desktop_spec`, and in a mesh as `WorklistEntry.desktop_spec`, one per desktop
row; `materialize()` stamps each row's spec onto that row's image. The spec is left out of
the saved JSON while it is empty. All three faces read and write it: the GUI page
(`gui/pages/desktop.py`), the text UI screen (`tui/desktop_step.py`) and the CLI
(`--desktop-options`, `--desktop-pretend`, in `core/desktop_cli.py`).

Emission happens in `cli_args()` and `effective_packages_add()`. Both emit nothing unless
the image really produces a desktop (`applies()`, which mirrors the x86 builder's
`ROLE_CLIENT`; frite counts only with `--desktop light`). A stale spec on a node
therefore never reaches a builder that would refuse the flags. Native apps are folded into
the single `--packages-add`, because every builder reads that flag last-wins.
`cfg.packages_add` itself is never rewritten.

The extra accounts' first-login passwords are kept in `ImageConfig.extra_local_passes`, a
`SECRET_FIELDS` entry that is never saved. At dispatch, `core/build_driver.py`
(`_stage_extra_pass`) writes them to a 0600 file for that one run. The file is mounted
read-only under docker, and the path replaces the placeholder that the argv preview shows.

## The flags and the builders

`scripts/_desktop-config-lib.sh` is the one place every desktop builder turns these flags
into image content. The builders are build-x86-host-stage4.sh, build-rpi5-stage4.sh,
build-jetson-stage4.sh, build-frite-stage4.sh, build-orangepi5-stage4.sh and
build-orangepi4-lts-stage4.sh. Each flag takes one value: a space-separated list, or
`;`-separated lines for the overlay.

| Flag | Builders | Effect |
|---|---|---|
| `--desktop-sessions "i3 picom sway"` | x86 | atoms folded into `--packages-add` (`dc_session_map`); a Wayland one adds `wayland` to the client USE |
| `--default-session NAME` | all six | rewrites `user-session=` in `/etc/lightdm/lightdm.conf` |
| `--video-cards "intel virgl"` | x86 | replaces the `--gpu-driver` list (radeonsi adds radeon and amdgpu); the make.conf render and `assert_spec_video_cards` read this effective list |
| `--extra-local-users "ann bob:admin"` + `--extra-local-pass-file FILE` | all six | hashed at build time into `/etc/hugmesh/extra-local-users` (0600). `scripts/desktop-config/02-extra-local-users.start` creates the accounts at first boot. An account gets `wheel` only with `:admin`, and never on a desktop-governance or KEYS-provisioned image. The first login must change the password. |
| `--flatpak-apps "flathub:org.x.Y"` + `--flatpak-remotes "name=https://…"` | all six | `/etc/hugmesh/flatpak-apps.list` and `flatpak-remotes.list`. `scripts/desktop-config/hugmesh-flatpak-apps.initd` installs them system-wide once the machine is online, retries each boot, then removes itself from the runlevel. `sys-apps/flatpak` is folded in. |
| `--python-extra-targets` / `--python-single-target` | all six | `scripts/_python-targets-lib.sh` takes the UNION with the seed's set and never narrows it ([PYTHON-TARGETS-SEED-DRIFT.md](PYTHON-TARGETS-SEED-DRIFT.md)) |
| `--package-use "ATOM FLAGS;…"` / `--accept-keywords "ATOM [~arch];…"` | all six | `package.use/zz-hugmesh-studio` and `package.accept_keywords/zz-hugmesh-studio`, written by `dc_apply_portage_overlay` AFTER the builder's last `pcs_sync_dir` (that sync prunes files the specs lack) and before `pt_apply_seed_targets` |
| `--pretend-only` | x86 | see below |

`dc_validate` runs at argv time, before anything is downloaded. It refuses all of these flags
on a node role. It also refuses an unknown session or card, picom with Plasma alone, a
Wayland compositor with no Mesa card or with proprietary NVIDIA, a default session the
image does not install, and root, the primary account or a duplicate as an extra account.
On the overlay it refuses wildcards, `video_cards_*` and Python flags, version atoms
without an operator, and any keyword but the image's own `~arch`. With no flag given,
nothing here writes a file.

### App deliveries that do not exist on an arch

The app catalog (`studio/hugmesh_studio/core/desktop_apps.json`) records, per delivery, only
the STRUCTURAL limit: `native_arches` / `flatpak_arches` plus `*_why`. The delivery does not
exist for any other arch, so no keyword or USE line can fix it. Measured 2026-11-12 against
the Gentoo tree and Flathub's summary API:

| App | Native | Flatpak |
|---|---|---|
| Thunderbird | amd64 only (`thunderbird-bin` has no arm64 build) | x86_64 only on Flathub |
| LibreOffice | amd64 only (`libreoffice-bin`) | every arch |
| Blender | every arch | x86_64 only on Flathub |
| OBS Studio | every arch | x86_64 only on Flathub |

On an ARM board the GUI greys that choice in the row's combo and says why in the row. The
TUI refuses `app ID HOW` with the reason and lists it under "Not on arm64". `--desktop-options`
prints it. `desktop_spec.problems()` refuses it in a loaded config or a free entry that names
the same package. Keyword stability is not recorded, because it drifts. The ARM boards accept
`~arm64`, and x86 has the emerge --pretend check. A free-entry Flatpak id is not checked
against Flathub's arches. That needs the network, so a free entry that Flathub does not build
for the board fails at first boot, in the `hugmesh-flatpak-apps` service log.

## emerge --pretend

`build-x86-host-stage4.sh --pretend-only` runs everything a real build runs up to the
payload emerge: seed, specs, the overlay, make.conf and the seed's Python targets. It then
sources `scripts/_pretend-lib.sh` inside the chroot and asks one question:

    emerge --pretend --verbose --update --deep --newuse --autounmask=y --autounmask-write=n
           --autounmask-backtrack=y --exclude sys-apps/portage <toolchain excludes> @world <payload>

The output follows a pinned contract, which `core/desktop_pretend.py` parses:

    ==> Pretend result: status=clean|needs|error rc=N seed_python=a,b video_cards=x,y
    ==> Pretend needs: package.use <line>
    ==> Pretend needs: accept_keywords <line>
    ===== PRETEND RESOLVER OUTPUT ===== ... ===== END PRETEND RESOLVER OUTPUT =====

Portage names a needed change in one of two forms, and the parser reads both:

- the autounmask lists, "The following USE / keyword changes are necessary to
  proceed:" followed by the lines it would write;
- a hint under an unsatisfied dependency, which is how the real OBS run's ffmpeg wall
  came out (the keyword change for obs-studio was listed, the USE change was not):

      emerge: there are no ebuilds built with USE flags to satisfy ">=media-video/ffmpeg-6.1:=[nvenc?,opus,x264]".
      !!! One of the following packages is required to complete your request:
      - media-video/ffmpeg-8.1.2::gentoo (Change USE: +opus +x264)

  The first alternative is the change to the dependency itself (a second one, when
  portage prints it, changes the parent's USE instead), and it becomes
  `package.use >=media-video/ffmpeg-8.1.2 opus x264`. A hint that carries anything
  besides the USE change (", this change violates use flag constraints ...", "Missing
  IUSE") is not named, so that result is an error for the operator to read.

The exit status is 0 for clean, 3 for needs and 1 for error. The check fails closed:
`clean` needs exit 0, the `Total: N packages` plan line (which portage prints only with
`--verbose`) and no named change. Nothing is merged. The run uses its own
`--build-subdir pretend-<hash>` and removes that tree when it finishes, but only after
`umount_chroot`, only when nothing is left mounted, and only for a `pretend-*` subdir.

The Studio always runs it in the builder container, never as a native sudo build, and one
at a time machine-wide: `desktop_pretend.gate` waits on any running build, QEMU or builder
container, on free memory below 8 GiB and on free disk below 60 GiB. Each run's log and
parsed result are kept under `<out>/pretend/<key>/`, and a summary in
`desktop_spec.last_pretend`.

Honesty: the check resolves the seed, @world and the payload in ONE pass. The real build
merges @world first and its own fail-fast gate (`hugmesh_payload_plan_gate`) checks the
payload again after that. A `clean` result therefore means no wall is visible from the
seed. It does not mean the build will succeed.

Applying a fix:

- The Desktop page's **Apply portage's changes**, the text UI's `a` and the CLI's
  `--apply-portage-fixes` add exactly the lines portage named, recorded in
  `desktop_spec.history` with source `autounmask`.
- The local assistant reads the same result (`core/assistant_portage.py pretend_block`,
  redacted, about 1500 tokens). It can propose lines in a fenced `portage` block, which
  becomes a card: diff, Apply/Undo, Re-check. A line portage did not name is labelled.
  Applying it records the source as `assistant`.
- Operator edits to the overlay are recorded as `operator`.
- Mask and licence changes are never applied from here.

ARM boards have no pretend mode yet: they cross-compile from the host, and the check says
so on those boards.
