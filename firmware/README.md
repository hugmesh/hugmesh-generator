# HugMesh Mesh firmware — a thin fork overlay on Meshtastic

> **Status: design only. Nothing described below exists in this repository yet.**
> `firmware/` holds this file and nothing else. There is no `firmware/overlay/`
> tree, no `docker/build-firmware.sh`, no `docker/Dockerfile.firmware-gen`, no
> `IMAGE_TYPE=mesh-radio-firmware` build type and no `docs/MESH-FIRMWARE.md`.
> No firmware has been built or flashed. Read every present-tense sentence
> below as a plan. The upstream facts (the pinned tag, board environments,
> `userPrefs.jsonc` keys, the build mechanism) were checked against the
> upstream tag.

**"Meshtastic" is a registered trademark of Meshtastic LLC.** Nothing here is
produced by, endorsed by, or affiliated with the Meshtastic project. Firmware
built by this pipeline is branded **"HugMesh Mesh firmware
(Meshtastic-based)"** in every user-facing surface (device NODEINFO owner
long-name prefix, release manifest, artifact filenames, this doc). We never
call our fork "Meshtastic" on its own. The upstream name appears here only to
say, truthfully, what the fork is built from.

## What this is (and is not)

The plan is **not** a fork of the Meshtastic firmware source tree. It is a thin
**overlay**: a pinned upstream tag, a few generated or patched files laid over
a fresh clone of that tag, and an in-cluster build job that clones, overlays,
compiles and packages. The overlay is the smallest change that gets HugMesh
three things:

1. **Baked-in per-domain defaults.** `userPrefs.jsonc` is rendered from a
   Handlebars template at build time (channel name and PSK, LoRa region, MQTT
   broker, admin key, owner name). A flashed radio joins the right mesh with
   the right identity out of the box, with no first-run wizard on the device.
2. **One custom module.** `HugMeshPresenceModule` is a compact presence beacon,
   inert by default. It arrives as source plus a small unified-diff patch
   against upstream's own module-registration site, never as a hand-edited copy
   of the whole file.
3. **An in-cluster build type.** A planned `IMAGE_TYPE=mesh-radio-firmware`
   image-gen build (its design doc, `docs/MESH-FIRMWARE.md`, does not exist
   yet) clones the pinned tag, applies this overlay and runs the upstream build
   scripts unmodified. It produces the same flashable artifact shapes upstream
   ships (`.uf2` / `.factory.bin` / `.bin`).

Everything else is upstream and untouched: the RF stack, the mesh protocol, the
crypto, nearly all of `src/`. We keep no full source fork. We keep an *overlay*
that `git clone`, `git apply` and a template render turn into the same tree from
the pinned tag every time.

## Pinned upstream

```
repo: https://github.com/meshtastic/firmware
tag:  v2.7.26.54e0d8d
```

The plan pins the tag in one place: the `UPSTREAM_REF` default in
`docker/build-firmware.sh` (a script that does not exist yet). The
`IMAGE_SPEC_JSON` channel could override it, the way it already overrides board
selection in the existing image-gen pipeline (`docker/build-image.sh` reads
`IMAGE_SPEC_JSON` and `HARDWARE_CLASS`). Bumping the pin is a deliberate,
reviewed change. A new upstream tag can rename variants, move the
module-registration marker or change `userPrefs.jsonc` key names, and any of
those would break the overlay. `overlay/apply-overlay.sh` is meant to fail
loudly in that case (see "Drift detection" below) and never degrade quietly.

## Overlay approach

Planned layout. None of these files exist yet.

```
firmware/overlay/
├── userprefs/
│   └── hugmesh-default.jsonc.hbs   templated userPrefs.jsonc
├── modules/
│   ├── HugMeshPresenceModule.h     new module, upstream-shaped
│   └── HugMeshPresenceModule.cpp
├── patches/
│   └── 0001-register-hugmesh-presence-module.patch
│       unified diff: 2 lines added to src/modules/Modules.cpp
├── variants/
│   └── esp32s3/diy/hugmesh_esp32s3_sx1262/
│       platformio.ini + variant.h     a new DIY-shaped board variant
└── apply-overlay.sh                   the one script that reconstructs a
                                        buildable tree from (upstream tag +
                                        this overlay)
```

`apply-overlay.sh UPSTREAM_DIR` (planned; POSIX `sh`, no bashisms, to match
`docker/build-image.sh` and the minimal builder image it runs in) does this, in
order:

1. Render `userprefs/hugmesh-default.jsonc.hbs` with the caller's token values
   and copy the result to `UPSTREAM_DIR/userPrefs.jsonc`, upstream's own
   root-level default-prefs file (see "Defaults" below).
2. Copy `modules/HugMeshPresenceModule.{h,cpp}` into
   `UPSTREAM_DIR/src/modules/`.
3. Copy `variants/esp32s3/diy/hugmesh_esp32s3_sx1262/` into
   `UPSTREAM_DIR/variants/esp32s3/diy/`. Upstream's root `platformio.ini` globs
   `variants/*/diy/*/platformio.ini`, so no further wiring is needed.
4. Run `git apply --check` on the module-registration patch against
   `UPSTREAM_DIR/src/modules/Modules.cpp` **before** changing anything, and
   abort loudly if it fails (upstream moved the anchor line, the patch is
   already applied, and so on; see "Drift detection").
5. Run `git apply` for real.

The one reviewed patch is the only change to an upstream file. The module and
variant are new files, and new files cannot conflict.

### Why an overlay instead of a full fork

- **A small, honest diff.** Reviewers and GPLv3 source-offer recipients need to
  see the actual change from upstream. A full copied tree hides it.
  `git apply --check` on one small patch shows it in seconds.
- **Drift is caught, not absorbed.** In a full fork, whoever merges "resolves"
  conflicts, and intent can be lost. An overlay's `git apply --check` either
  succeeds byte for byte or fails loudly.
- **Reproducible builds.** The build job clones the pinned tag fresh every
  time (or from a vendored mirror, per `docker/build-firmware.sh`). There is no
  long-lived fork branch to keep in step with upstream's branch protections,
  CI or LFS-tracked binaries.

### Drift detection

The plan has `apply-overlay.sh` run `git apply --check` before it changes
anything. The same check would run offline against a synthesized fixture
(`overlay/patches/testdata/`, with a `run-tests.sh` beside it), so CI catches a
broken patch **without ever cloning upstream**. A real in-cluster build would
run the check again against the freshly cloned upstream tree. The fixture can
prove only that the patch is well formed against a mocked-up anchor, not that
upstream has not moved the real one. None of this is written yet.

## GPL-3.0 compliance

The upstream Meshtastic firmware is licensed GPL-3.0 (see upstream's own
`LICENSE`). Everything planned for `firmware/overlay/modules/` and
`firmware/overlay/patches/` is a derivative work compiled into the same binary.
It will carry the same license:

- `HugMeshPresenceModule.h` / `.cpp` are to open with a full GPL-3.0 header. It
  names HugMesh as copyright holder of the new material, and upstream
  Meshtastic LLC and contributors for the base `SinglePortModule` /
  `MeshModule` classes the module derives from.
- The patch file is to carry a one-line GPL-3.0 notice in its preamble.
- Every artifact `docker/build-firmware.sh` will emit is to come with a
  **`SOURCE-OFFER.txt`** in the same `ARTIFACT_DIR`, to satisfy GPLv3 §6
  ("Conveying Non-Source Forms"). It names the exact fork repository URL, the
  pinned upstream tag, the overlay commit or ref the build ran from, and where
  to get the complete corresponding source (upstream tag plus this `firmware/`
  overlay, which together rebuild the tree). The script's planned
  `write_source_offer()` will fix the exact fields. The fork repo URL is
  expected to live as a generator-repo config value, not hardcoded in the
  worker script.
- We do not claim GPL-3.0 covers less than it does. `userPrefs.jsonc` (baked
  per-domain configuration compiled into the binary via `-D` flags; see
  "Defaults" below) is part of the corresponding source and is covered by what
  `SOURCE-OFFER.txt` points at. The rendered file would NOT be committed
  anywhere, because it carries the Vault-injected PSK and admin key. The
  *template* and the render inputs that reproduce it are covered by the same
  overlay tree.

## Trademark note

"Meshtastic" and the Meshtastic logo are trademarks of Meshtastic LLC. This
fork:

- Never labels its own build output, packaging or UI surfaces "Meshtastic" on
  its own. It always says "HugMesh Mesh firmware (Meshtastic-based)" or "built
  from Meshtastic firmware v2.7.26.54e0d8d".
- Does not use the Meshtastic logo or any confusingly similar mark.
- Uses the name only to say truthfully what the fork is built from. That is the
  narrow use this document relies on. It claims no broader trademark license
  and no affiliation.

## Defaults: `userPrefs.jsonc`

Upstream's `bin/platformio-custom.py` reads `userPrefs.jsonc` (a JSONC file at
the repo root; comments allowed, hence the extension) and turns every key into
a `-D<KEY>=<value>` PlatformIO build flag. The keys already start with
`USERPREFS_`. The values are **compiled into the binary**, not read from a
config file on the device at run time. The overlay uses exactly this mechanism
to bake in HugMesh per-domain defaults.
`overlay/userprefs/hugmesh-default.jsonc.hbs` is a Handlebars template. It is
rendered by `apply-overlay.sh`, or in-cluster by `docker/build-firmware.sh` from
`IMAGE_SPEC_JSON` fields, and it covers:

| Token | Upstream key | Notes |
|---|---|---|
| `{{MESH_CHANNEL_NAME}}` | `USERPREFS_CHANNEL_0_NAME` | HugMesh domain's default mesh channel. |
| `{{MESH_CHANNEL_PSK_B64}}` | `USERPREFS_CHANNEL_0_PSK` | Planned: injected from Vault at build time, never committed. |
| `{{LORA_REGION}}` | `USERPREFS_CONFIG_LORA_REGION` | Region code (e.g. `US`, `EU_868`) — regulatory, must be correct for the shipping jurisdiction. |
| owner long-name prefix | `USERPREFS_CONFIG_OWNER_LONG_NAME` | `"HugMesh Mesh · "` prefix + per-build suffix, so a flashed radio self-identifies honestly on first boot (also satisfies the trademark note above at the device level). |
| `{{MQTT_ENABLED}}` / `{{MQTT_ADDRESS}}` | `USERPREFS_MQTT_ENABLED` / `USERPREFS_MQTT_ADDRESS` | Points at the domain's own MQTT broker (the same `mqtt` device-attachment shape `meshbridge` speaks — see "Relationship to meshbridge" below), not a public broker. |
| `{{ADMIN_KEY_B64}}` | `USERPREFS_USE_ADMIN_KEY_0` | Planned: injected from Vault at build time, never committed. The domain's admin public key, so the domain's admin console can remote-administer flashed radios over the mesh. |

The planned template, `overlay/userprefs/hugmesh-default.jsonc.hbs` (not yet
written), would also set `USERPREFS_CHANNELS_TO_WRITE`, the three
`_DOWNLINK_ENABLED` keys, `USERPREFS_LORACONFIG_MODEM_PRESET`,
`USERPREFS_CONFIG_DEVICE_ROLE` and `USERPREFS_OEM_TEXT`. All of these keys
exist in upstream's `userPrefs.jsonc` at the pinned tag.

## Custom module: `HugMeshPresenceModule`

One new module (planned: `overlay/modules/HugMeshPresenceModule.{h,cpp}`,
registered by `overlay/patches/0001-register-hugmesh-presence-module.patch`).
It sends a compact presence beacon (firmware variant tag, battery percentage,
uptime) on Meshtastic's private-application portnum range about every 15
minutes. The interval is jittered so a fleet of radios does not transmit in
lockstep. The module is a `SinglePortModule`, shaped like upstream's own
`ReplyModule`. It is **compiled in but inert** unless
`USERPREFS_HUGMESH_PRESENCE=1` is set, so a userPrefs render can turn it off per
domain without a different firmware build. The design rationale, buffer-safety
notes and portnum choice belong in the files' own header comments, which do not
exist yet.

## Board table

| Device | Upstream env | Artifact | Notes |
|---|---|---|---|
| Heltec Mesh Node T114 V2 | `heltec-mesh-node-t114` | `.uf2` | nRF52840; drag-and-drop UF2 bootloader flashing. |
| ELECROW ThinkNode M1 | `thinknode_m1` | `.uf2` | nRF52840, e-ink display; drag-and-drop UF2. |
| Heltec V3 (generic ESP32-S3 + SX1262, e.g. "Meshnology ESP32 LoRa V4") | `heltec-v3` | `.factory.bin` / `.bin` | ESP32-S3; flash via `esptool.py` or the Meshtastic web flasher. |
| Same class of board, HugMesh DIY variant | `hugmesh-esp32s3-sx1262` (planned in this overlay; does not exist yet) | `.factory.bin` / `.bin` | Use when `heltec-v3`'s baked pinout doesn't match the actual board — see the variant's `variant.h` PINOUT TODOs; requires per-board pin confirmation before first flash. |

nRF52 boards (T114, ThinkNode M1) produce a `.uf2`. Copy it onto the device's
USB mass-storage bootloader volume. No special tooling is needed. ESP32-S3
boards (`heltec-v3`, the HugMesh DIY variant) produce a `.factory.bin`
(full flash, offset 0x0, for `esptool.py write_flash` or the official
Meshtastic web flasher) and a plain `.bin` (application partition only, for an
already-provisioned device). `docker/build-firmware.sh` would place both in
`ARTIFACT_DIR` with a `manifest.json` that says which is which.

## Not compiled in this workspace

**No firmware has been compiled, and none of the overlay exists.** Commit
c8158b24 added this file as "design-only, no implementation yet". These
statements are therefore **not** true of this repository today, and an earlier
draft of this section wrongly claimed them:

- that `overlay/apply-overlay.sh` is `sh -n` valid and shellcheck-clean;
- that `overlay/patches/0001-register-hugmesh-presence-module.patch` applies
  against a fixture in `overlay/patches/testdata/`;
- that `overlay/patches/testdata/run-tests.sh` exercises the overlay;
- that `docker/build-firmware.sh` and `docker/Dockerfile.firmware-gen` were
  reviewed for parity with `docker/build-image.sh` / `docker/Dockerfile.image-gen`.

`docker/` has `build-image.sh` and `Dockerfile.image-gen`, and no firmware
counterpart. Nobody has run embedded cross-compilation (PlatformIO, the
ESP32-S3 and nRF52 toolchains) for this design. The first honest build belongs
in-cluster or in CI, against a live clone of the pinned upstream tag.

What *was* checked, against upstream tag `v2.7.26.54e0d8d` (commit `54e0d8d0`):
every `USERPREFS_*` key in the table above appears in upstream's
`userPrefs.jsonc`; `bin/platformio-custom.py` turns each key into a `-D` flag;
`platformio.ini` globs `variants/*/diy/*/platformio.ini`; the environments
`heltec-mesh-node-t114`, `thinknode_m1` and `heltec-v3` exist; and
`ReplyModule` is a `SinglePortModule`.

## Relationship to `meshbridge`

Radios flashed by this pipeline are the kind of device that attaches to the
platform's `meshbridge` optional service (see `docs/MESHTASTIC-BRIDGE.md` and
`specs/cluster/manifests/meshbridge/`). A flashed T114 or ThinkNode M1 attaches
over `serial` (USB). A Heltec-V3-class board attaches over `tcp` (Meshtastic TCP
API, port 4403, if it has WiFi) or `serial`. Any of them can take part over RF
through an `mqtt`-attached WAN gateway, whatever its own transport. The
`{{MQTT_ADDRESS}}` userPrefs token above points at the *domain's own* broker, so
a freshly flashed radio is reachable the way meshbridge's `mqtt`
device-attachment shape expects, with no per-device reconfiguration. This
pipeline neither modifies nor depends on `meshbridge`. A flashed radio is simply
the kind of hardware that shows up on the other end of that bridge.
