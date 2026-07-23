# HugMesh Mesh firmware — a thin fork overlay on Meshtastic

**"Meshtastic" is a registered trademark of Meshtastic LLC.** Nothing here is
produced by, endorsed by, or affiliated with the Meshtastic project. Firmware
built by this pipeline is branded **"HugMesh Mesh firmware
(Meshtastic-based)"** in every user-facing surface (device NODEINFO owner
long-name prefix, release manifest, artifact filenames, this doc) — we never
call our fork "Meshtastic" on its own. The upstream name is used here only in
the nominative sense, to say honestly what our fork is built from.

## What this is (and is not)

This is **not** a fork of the Meshtastic firmware source tree living in this
repo. It is a thin **overlay**: a pinned upstream tag, a small set of
generated/patched files layered on top of a fresh clone of that tag, and an
in-cluster build job that does the clone + overlay + compile + package. The
overlay is designed to be the smallest change that gets HugMesh three
things:

1. **Baked-in per-domain defaults** — `userPrefs.jsonc`, rendered from a
   Handlebars template at build time (channel name/PSK, LoRa region, MQTT
   broker, admin key, owner name), so a flashed radio joins the right mesh
   with the right identity out of the box instead of needing a manual
   first-run wizard on the device itself.
2. **One custom module** — `HugMeshPresenceModule`, a compact, inert-by-
   default presence beacon, added as source + a small unified-diff patch
   against upstream's own module-registration site (never a hand-edited copy
   of the whole file).
3. **An in-cluster build type** — a new `IMAGE_TYPE=mesh-radio-firmware`
   image-gen build (see `docs/MESH-FIRMWARE.md`) that clones the pinned tag,
   applies this overlay, and runs the upstream build scripts unmodified,
   producing the same flashable artifact shapes upstream itself ships
   (`.uf2` / `.factory.bin` / `.bin`).

Everything upstream — the RF stack, the mesh protocol, the crypto, the vast
majority of `src/` — is untouched. We do not maintain a full source fork; we
maintain an *overlay* that a plain `git clone` + `git apply` + template
render reconstructs deterministically from the pinned tag every time.

## Pinned upstream

```
repo: https://github.com/meshtastic/firmware
tag:  v2.7.26.54e0d8d
```

The tag is pinned in exactly one place operationally significant: the
`UPSTREAM_REF` default in `docker/build-firmware.sh` (overridable by the
`IMAGE_SPEC_JSON` channel the same way the existing image-gen pipeline's
`HARDWARE_CLASS`/board selection works — see that doc). Bumping the pin is a
deliberate, reviewed change: a new upstream tag can rename variants, move the
module-registration marker, or change `userPrefs.jsonc` key names, any of
which would silently break the overlay. `overlay/apply-overlay.sh` fails
loudly (see "Drift detection" below) rather than degrading quietly when that
happens.

## Overlay approach

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

`apply-overlay.sh UPSTREAM_DIR` (POSIX `sh`, no bashisms — matches
`docker/build-image.sh`'s own portability constraint, since it runs inside
the same class of minimal builder image) does, in order:

1. Render `userprefs/hugmesh-default.jsonc.hbs` with the caller-supplied
   token values and copy the result to `UPSTREAM_DIR/userPrefs.jsonc`
   (upstream's own root-level default-prefs file — see "Defaults" below).
2. Copy `modules/HugMeshPresenceModule.{h,cpp}` into
   `UPSTREAM_DIR/src/modules/`.
3. Copy `variants/esp32s3/diy/hugmesh_esp32s3_sx1262/` into
   `UPSTREAM_DIR/variants/esp32s3/diy/` (upstream's root `platformio.ini`
   globs `variants/*/diy/*/platformio.ini`, so this is picked up with no
   further wiring).
4. `git apply --check` the module-registration patch against
   `UPSTREAM_DIR/src/modules/Modules.cpp` **before** applying anything for
   real, and abort loudly if the check fails (upstream moved the anchor
   line, the patch already applied, etc. — see "Drift detection").
5. `git apply` the patch for real.

Nothing here modifies upstream source files in place except via that one
reviewed patch; the module and variant additions are pure new files with no
patch machinery needed (new files can't "conflict").

### Why an overlay instead of a full fork

- **Honest maintenance surface.** Reviewers, and GPLv3 source-offer
  recipients, need to see the *actual* diff from upstream, not reconstruct it
  from a full copied tree. `git apply --check` on a single small patch is
  that diff, verifiable in seconds.
- **Upstream drift is caught, not absorbed.** A full fork's merge conflicts
  get silently "resolved" by whoever's doing the merge, potentially losing
  intent. An overlay's `git apply --check` either succeeds byte-for-byte or
  fails loudly — there is no silent middle ground.
- **CI/build reproducibility.** The build job clones the pinned tag fresh
  every time (or from a vendored mirror — see `docker/build-firmware.sh`),
  so there is no long-lived fork branch to keep in sync with upstream's own
  branch protections, CI, or LFS-tracked binaries.

### Drift detection

`apply-overlay.sh` runs `git apply --check` before doing anything
destructive, and the same check is exercised offline against a synthesized
fixture (`overlay/patches/testdata/`, see "Validation" in
`docs/MESH-FIRMWARE.md` and `overlay/patches/testdata/run-tests.sh`) so a CI
run catches a broken patch **without ever cloning upstream**. A real
in-cluster build additionally re-runs the same check against the real,
freshly cloned upstream tree — belt and suspenders, since the fixture can
only prove the patch is well-formed against a mocked-up anchor, not that
upstream hasn't actually moved it.

## GPL-3.0 compliance

The upstream Meshtastic firmware is licensed GPL-3.0 (see upstream's own
`LICENSE`). Everything in `firmware/overlay/modules/` and
`firmware/overlay/patches/` is a derivative work compiled into the same
binary and therefore carries the same license:

- `HugMeshPresenceModule.h` / `.cpp` open with a full GPL-3.0 header
  (see those files) naming HugMesh as the additional copyright holder
  for the new material, upstream Meshtastic LLC and contributors for the
  base `SinglePortModule`/`MeshModule` classes it derives from.
- The patch file itself carries a one-line GPL-3.0 notice in its preamble.
- Every artifact `docker/build-firmware.sh` emits is accompanied by a
  **`SOURCE-OFFER.txt`** in the same `ARTIFACT_DIR`, satisfying GPLv3 §6
  ("Conveying Non-Source Forms"): it names the exact fork repository URL,
  the pinned upstream tag, the overlay commit/ref the build ran from, and
  a durable statement of where the complete corresponding source (upstream
  tag + this `firmware/` overlay, which together fully reconstruct the
  built tree) can be obtained. See `docker/build-firmware.sh`'s
  `write_source_offer()` for the exact fields and
  `docs/MESH-FIRMWARE.md` for where the fork repo URL itself is expected to
  live operationally (a generator-repo config value, not hardcoded in the
  worker script — see that doc's follow-up seam list).
- We never claim GPL-3.0 covers less than it does: `userPrefs.jsonc` (baked
  per-domain configuration compiled directly into the binary via
  `-D` flags, see "Defaults" below) is also part of the corresponding
  source obligation and is included in what `SOURCE-OFFER.txt` points at
  (the rendered file itself is NOT committed anywhere — see "Secrets" — but
  the *template* + the render inputs needed to reproduce it are covered by
  the same overlay tree).

## Trademark note

"Meshtastic" and the Meshtastic logo are trademarks of Meshtastic LLC. This
fork:

- Never labels its own build output, packaging, or UI surfaces as
  "Meshtastic" standalone — always "HugMesh Mesh firmware
  (Meshtastic-based)" or "built from Meshtastic firmware v2.7.26.54e0d8d".
- Does not use the Meshtastic logo or any confusingly similar mark.
- Uses the name only nominatively (to truthfully identify what the fork is
  built from), which is the narrow use this doc relies on — this is not a
  claim of any broader trademark license or affiliation.

## Defaults: `userPrefs.jsonc`

Upstream's `bin/platformio-custom.py` reads `userPrefs.jsonc` (a JSONC file
at the repo root — comments allowed, hence the extension) and turns every key
into a `-DUSERPREFS_<KEY>=<value>` PlatformIO build flag, so these values are
**compiled into the binary**, not read at runtime from a config file on the
device. That is exactly the mechanism this overlay uses to bake HugMesh
per-domain defaults in: `overlay/userprefs/hugmesh-default.jsonc.hbs` is a
Handlebars template (rendered by `apply-overlay.sh`, or in-cluster by
`docker/build-firmware.sh` from `IMAGE_SPEC_JSON` fields — see
`docs/MESH-FIRMWARE.md`) covering:

| Token | Upstream key | Notes |
|---|---|---|
| `{{MESH_CHANNEL_NAME}}` | `USERPREFS_CHANNEL_0_NAME` | HugMesh domain's default mesh channel. |
| `{{MESH_CHANNEL_PSK_B64}}` | `USERPREFS_CHANNEL_0_PSK` | **Vault-injected at build time, never committed** — see "Secrets" below. |
| `{{LORA_REGION}}` | `USERPREFS_CONFIG_LORA_REGION` | Region code (e.g. `US`, `EU_868`) — regulatory, must be correct for the shipping jurisdiction. |
| owner long-name prefix | `USERPREFS_CONFIG_OWNER_LONG_NAME` | `"HugMesh Mesh · "` prefix + per-build suffix, so a flashed radio self-identifies honestly on first boot (also satisfies the trademark note above at the device level). |
| `{{MQTT_ENABLED}}` / `{{MQTT_ADDRESS}}` | `USERPREFS_MQTT_ENABLED` / `USERPREFS_MQTT_ADDRESS` | Points at the domain's own MQTT broker (the same `mqtt` device-attachment shape `meshbridge` speaks — see "Relationship to meshbridge" below), not a public broker. |
| `{{ADMIN_KEY_B64}}` | `USERPREFS_USE_ADMIN_KEY_0` | **Vault-injected at build time, never committed** — the domain's admin public key, so the domain's admin console can remote-administer flashed radios over the mesh. |

See `overlay/userprefs/hugmesh-default.jsonc.hbs` for the full template
(all upstream keys listed in the task recon, including
`USERPREFS_CHANNELS_TO_WRITE`, the 3-channel `_DOWNLINK_ENABLED` triad,
`USERPREFS_LORACONFIG_MODEM_PRESET`, `USERPREFS_CONFIG_DEVICE_ROLE`, and
`USERPREFS_OEM_TEXT`) with inline comments on every key.

## Custom module: `HugMeshPresenceModule`

A single new module (`overlay/modules/HugMeshPresenceModule.{h,cpp}`,
registered via `overlay/patches/0001-register-hugmesh-presence-module.patch`)
sending a compact presence beacon (firmware variant tag + battery percentage
+ uptime) on Meshtastic's private-application portnum range every ~15
minutes (jittered, to avoid a fleet of radios transmitting in lockstep).
It is a `SinglePortModule`, mirroring upstream's own `ReplyModule` shape, and
is **compiled in but inert** unless `USERPREFS_HUGMESH_PRESENCE=1` is set
(so a userPrefs render can turn it off per-domain without a different
firmware build). See the file's own header comment for the full design
rationale, buffer-safety notes, and portnum choice.

## Board table

| Device | Upstream env | Artifact | Notes |
|---|---|---|---|
| Heltec Mesh Node T114 V2 | `heltec-mesh-node-t114` | `.uf2` | nRF52840; drag-and-drop UF2 bootloader flashing. |
| ELECROW ThinkNode M1 | `thinknode_m1` | `.uf2` | nRF52840, e-ink display; drag-and-drop UF2. |
| Heltec V3 (generic ESP32-S3 + SX1262, e.g. "Meshnology ESP32 LoRa V4") | `heltec-v3` | `.factory.bin` / `.bin` | ESP32-S3; flash via `esptool.py` or the Meshtastic web flasher. |
| Same class of board, HugMesh DIY variant | `hugmesh-esp32s3-sx1262` (this overlay) | `.factory.bin` / `.bin` | Use when `heltec-v3`'s baked pinout doesn't match the actual board — see the variant's `variant.h` PINOUT TODOs; requires per-board pin confirmation before first flash. |

nRF52-family boards (T114, ThinkNode M1) produce a `.uf2` — copy it onto the
device's USB mass-storage bootloader volume, no special tooling needed.
ESP32-S3-family boards (`heltec-v3`, the HugMesh DIY variant) produce
`.factory.bin` (full-flash, offset 0x0, for `esptool.py write_flash` or the
official Meshtastic web flasher) and a plain `.bin` (application partition
only, for an already-provisioned device). Both are placed in `ARTIFACT_DIR`
by `docker/build-firmware.sh` alongside a `manifest.json` describing exactly
which is which (see `docs/MESH-FIRMWARE.md`).

## Not compiled in this workspace

**No firmware has been compiled by this change.** Embedded cross-compilation
(PlatformIO + the ESP32-S3 / nRF52 toolchains) is not available in this
session's sandbox, and even if it were, an honest first build belongs
in-cluster or in CI, against a live clone of the pinned upstream tag, not
against a hand-simulated tree here. What *has* been verified in this
workspace:

- `overlay/apply-overlay.sh` is POSIX-`sh`-valid (`sh -n`) and shellcheck-clean.
- `overlay/patches/0001-register-hugmesh-presence-module.patch` applies
  cleanly (`git apply --check`, then a real `git apply`) against a small
  synthesized fixture in `overlay/patches/testdata/` that reproduces the
  exact anchor line upstream's `src/modules/Modules.cpp` carries at
  v2.7.26.54e0d8d (per the task's recon — this fixture is NOT a copy of the
  real file, which is not present in this workspace).
- `overlay/patches/testdata/run-tests.sh` exercises `apply-overlay.sh`
  end-to-end against a small fake "upstream" directory tree (userPrefs
  render, module copy, variant copy, patch apply) and asserts every step's
  output.
- `docker/build-firmware.sh` and `docker/Dockerfile.firmware-gen` are
  reviewed for contract-shape parity with the existing
  `docker/build-image.sh` / `docker/Dockerfile.image-gen` pair, but neither
  has been run against a real PlatformIO build — the actual `platformio run
  -e <env>` step (and therefore the whole toolchain: PlatformIO package
  downloads, the ESP32/nRF52 platform packages, the C++ compile itself) is
  **entirely unverified** and must be proven in-cluster or in CI as a
  follow-up. See `docs/MESH-FIRMWARE.md`'s validation section for the exact
  scope of what is and isn't proven here.

## Relationship to `meshbridge`

Radios flashed by this pipeline are exactly the class of device that attaches
to the platform's `meshbridge` optional service (see
`docs/MESHTASTIC-BRIDGE.md`, `specs/cluster/manifests/meshbridge/`): a
flashed T114/ThinkNode M1 attaches over `serial` (USB), a flashed
Heltec-V3-class board attaches over `tcp` (Meshtastic TCP API, port 4403, if
it has WiFi) or `serial`, and any of them can participate over RF through a
`mqtt`-attached WAN gateway regardless of transport. The `{{MQTT_ADDRESS}}`
userPrefs token above deliberately points at the *domain's own* broker so a
freshly flashed radio is immediately reachable the same way meshbridge's own
`mqtt` device-attachment shape expects, without a manual per-device
reconfiguration step. This pipeline does not modify or depend on
`meshbridge` itself — the connection is purely "this is the kind of hardware
that shows up on the other end of that bridge."
