# SELinux node-policy module loading — fleet build-script wiring spec

**Status: SPECIFICATION ONLY. This document changes nothing.** The
`specs/selinux/*.te` / `*.fc` node-policy modules are authored in refpolicy
style but are **inert** — no build step compiles or installs them today. This
doc precisely specifies what the **fleet** must add to the **PROTECTED**
`build-*-stage4.sh` scripts to make them load. Those scripts are OFF-LIMITS to
this PR; the changes below are described, not applied. Line numbers reference
`main` at the time of writing (`build-rpi5-stage4.sh`, the cross-built Pi
exemplar — `build-x86-host-stage4.sh` / `build-frite-stage4.sh` follow the same
shape with their own arch offsets).

This is **fleet/protected work, not applied in this PR.**

## What exists today (the seams to build against)

1. **`SHARED_SPECS`** is defined at `build-rpi5-stage4.sh:16`
   (`SHARED_SPECS="${SCRIPT_DIR}/specs"`) and validated to exist at
   `build-rpi5-stage4.sh:1304-1310`. The editable `specs/selinux/` directory
   lives directly under it as `${SHARED_SPECS}/selinux`. **It is NOT copied
   anywhere by any build script today** (verified: no `specs/selinux` reference
   in any `build-*.sh`).

2. **Host SELinux policy build tools are already gated** at
   `build-rpi5-stage4.sh:1320-1379`: the block ensures `checkpolicy`,
   `checkmodule`, `semodule_package` (sys-apps/semodule-utils), and `m4` are
   present on the x86 **BUILD host** (emerged natively, NOT into the aarch64
   sysroot), exiting non-zero if they cannot be provided
   (`build-rpi5-stage4.sh:1359-1379`). These are exactly the tools the refpolicy
   module-build Makefile needs — so the per-module `.pp` compile below has its
   prerequisites **already guaranteed at that point in the script.**

3. **The node binaries the modules label are copied in** the arch-agnostic
   block (`build-rpi5-stage4.sh:1531` onward, "shared with the x86 build ->
   SHARED_SPECS"): e.g. `snapdragon-authorized-keys-lookup` +
   `snapdragon-device-registry-sync` at `build-rpi5-stage4.sh:1607-1610`, and
   `snapdragon-vpn-runner` at `build-rpi5-stage4.sh:1640-1641`. The new modules'
   `.fc` files label these same paths; the `.pp` install (step c) must land
   **before** the first-boot relabel runs.

4. **`provision_selinux()`** lives in the PROTECTED
   `specs/etc/keys-provision/provision.sh:2214-2245`. At first boot it:
   - writes `/etc/selinux/config` (`SELINUXTYPE=mcs`, default permissive);
   - if the policy store is unbuilt, runs
     `semodule -s "${type}" -B` **or** falls back to
     `semodule -s "${type}" -i /usr/share/selinux/"${type}"/*.pp`
     (**`provision.sh:2232-2234`**) — i.e. it loads **every `*.pp` already
     present under `${SYSROOT}/usr/share/selinux/${type}/`**;
   - relabels the filesystem (`setfiles` / `restorecon -RF /`,
     `provision.sh:2236-2242`) which applies all `.fc` file contexts;
   - is the LAST provisioning step (`provision.sh:2389`).

   **The implication: if the fleet installs the compiled `.pp` files into
   `${SYSROOT}/usr/share/selinux/${type}/` at build time, `provision_selinux()`
   already loads them with the EXISTING `semodule -i .../*.pp` line — no change
   to provision.sh is needed.** The wiring is entirely in the build script.

## What the fleet must add to the PROTECTED `build-*-stage4.sh`

Insert the following AFTER the host-policy-tools gate
(`build-rpi5-stage4.sh:1379`, "Host SELinux policy build tools present …") and
AFTER `SELINUXTYPE` is known (it is `mcs` per `provision.json` /
`provision_selinux`), and BEFORE the image is sealed / the first-boot relabel.
A natural spot is alongside the node-binary copies in the arch-agnostic block
(after `build-rpi5-stage4.sh:1610`) so the `.fc`-labelled binaries and their
modules ship together.

### (a) Copy `SHARED_SPECS/selinux` into the build

The modules are arch-agnostic (host-process policy), so copy them once, like the
other `${SHARED_SPECS}` assets:

```sh
# Stage the editable node-policy modules into a build scratch dir.
SELINUX_SRC="${SHARED_SPECS}/selinux"
SELINUX_BUILD="$(mktemp -d)"
cp "${SELINUX_SRC}"/*.te "${SELINUX_SRC}"/*.fc "${SELINUX_BUILD}/"
```

### (b) Compile each module to a `.pp` over `specs/selinux` on the BUILD host

Use the refpolicy devel Makefile, which is installed by `sec-policy/selinux-base`
on the BUILD host. The tools it invokes (`checkmodule`, `semodule_package`, `m4`)
are the SAME ones already gated at `build-rpi5-stage4.sh:1359-1362` — so this
step's prerequisites are guaranteed by the existing checks. One `make` per
module name (the Makefile derives `<name>.pp` from `<name>.te`/`<name>.fc`):

```sh
SELINUX_DEVEL_MK=/usr/share/selinux/devel/Makefile   # shipped by selinux-base on the build host
for te in "${SELINUX_BUILD}"/*.te; do
    name="$(basename "${te}" .te)"
    make -C "${SELINUX_BUILD}" -f "${SELINUX_DEVEL_MK}" "${name}.pp" \
        || { err "SELinux module ${name}.pp failed to compile"; exit 1; }
done
```

Notes:
- The label-only modules that ship **`.fc` with no `.te`**
  (`snapdragon_breakglass`, `snapdragon_oidc_token`) have nothing for the devel
  Makefile to compile into a standalone `.pp`. The fleet has two clean options:
  (1) fold their `.fc` lines into a sibling module's `.fc` that DOES have a `.te`
  (e.g. add the break-glass line to `snapdragon_authkeys.fc`, the oidc-token
  line to the future desktop-session module), OR (2) add a one-line stub `.te`
  (`policy_module(<name>, 1.0.0)` + a `require {}` of the referenced base type:
  `ssh_home_t` / `user_runtime_t`) so the Makefile emits a `.pp` that carries the
  file-context. Option (1) matches how `snapdragon_breakglass.fc` already
  documents "no `.te` domain"; pick it unless a standalone module is wanted.
- Build the devel Makefile, NOT `emake base` — the base policy is already built
  by `sec-policy/selinux-base` (see `build-rpi5-stage4.sh:1321-1332`). These are
  **add-on modules**, compiled with the SAME host toolchain.

### (c) Install the `.pp` into the sysroot store so `provision_selinux()` finds them

`provision_selinux()` loads `/usr/share/selinux/${type}/*.pp`
(`provision.sh:2233`). Install each compiled `.pp` into the SYSROOT under that
exact path (`${type}` is `mcs`):

```sh
SELINUX_TYPE=mcs
install -d "${SYSROOT}/usr/share/selinux/${SELINUX_TYPE}"
install -m 0644 "${SELINUX_BUILD}"/*.pp \
    "${SYSROOT}/usr/share/selinux/${SELINUX_TYPE}/"
rm -rf "${SELINUX_BUILD}"
```

No change to `provision.sh` is required — the existing
`semodule -s "${type}" -i /usr/share/selinux/"${type}"/*.pp` at
`provision.sh:2233` then loads them at first boot, and the `setfiles /
restorecon -RF /` at `provision.sh:2236-2242` applies the `.fc` contexts (and
the existing `touch /.autorelabel` at `provision.sh:2243` covers a runtime
relabel).

### (d) Cross-built Pi caveat — build the `.pp` on the BUILD host, not first-boot

On the cross-built Pi (`build-rpi5-stage4.sh`) the aarch64 **target** may not
carry the refpolicy **devel** headers (`/usr/share/selinux/devel/`) at all — and
even if it did, `checkmodule`/`semodule_package` are x86 build-host binaries that
cannot run on the Pi. This is the SAME reason `build-rpi5-stage4.sh:1320-1332`
builds `base.pp` on the BUILD host and defers only the *load* to first boot.

Therefore steps (b)+(c) MUST run on the x86 BUILD host and ship the compiled
`.pp` artifacts INTO the image; first boot only does `semodule -i` of the
already-built `.pp` (which needs only target `semodule`, already gated by
`provision_selinux()` at `provision.sh:2216`). Do **not** attempt
`make -f .../devel/Makefile` on the target. (`build-x86-host-stage4.sh` is the
native case where it could compile first-boot, but compile-at-build is the
uniform, correct path for all three images.)

## Verification the fleet should add

- After (b), assert each expected `.pp` exists
  (`snapdragon_authkeys.pp`, `snapdragon_device_registry_sync.pp`,
  `snapdragon_vpn.pp`, `snapdragon_node_storage.pp`, `snapdragon_policy_sync.pp`,
  plus whatever the label-only modules resolve to per the (b) note); fail the
  build if any is missing (mirrors the `base.pp` failure mode the existing block
  already guards).
- In the QEMU enforcing verification (`tests/qemu/`, PROTECTED), after
  `setenforce 1`, drive an SSH login on a registry-enforced node and confirm NO
  `snapdragon_authkeys_t` / `snapdragon_device_registry_sync_t` AVC denials —
  this is the security-load-bearing path. Collect the permissive-pass AVCs to
  narrow every rule tagged `# INFERRED-WIDE: narrow after QEMU enforcing AVC
  pass` in the `.te` files.

## Why this is deferred / inert in this PR

The `.te`/`.fc` files are authored and matrix-documented, but until the fleet
adds (a)-(d) to the PROTECTED `build-*-stage4.sh`, no `.pp` is built and
`provision_selinux()` has nothing extra to load — the modules are **inert and
harmless** (identical posture to the merged `localpath_provisioner` /
`otel_collector` exemplars). Authoring them now lets the fleet wire the loader
in one protected change with the policy already reviewed.
