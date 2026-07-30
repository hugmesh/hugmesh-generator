# SELinux node-policy module loading — fleet build-script wiring spec

**Status: IMPLEMENTED.** Steps (a)-(d) below are wired, as
`scripts/_selinux-policy-lib.sh`, into all ten `build-*-stage4.sh` (one source
line + one call site each, immediately before `banner "Packaging stage4
tarball"`). The gate is `tests/scripts/test-selinux-policy-install.sh`, run as
the GATING `SLX` bucket of `tests/build-matrix/check.sh`.

**Images still boot PERMISSIVE.** The modules are compiled, installed and loaded;
nothing flips a node to enforcing. `specs/etc/init.d/selinux-enforce-gate` now
ships into every image but is INERT — it is in no runlevel and
`/etc/conf.d/selinux-enforce-gate` says `SELINUX_ENFORCE_GATE="no"` — unless the
operator sets `HUGMESH_SELINUX_ENFORCE_GATE=1` at build time. That is deliberate:
the `.te` files still carry rules tagged `# INFERRED-WIDE: narrow after QEMU
enforcing AVC pass`, which can only be narrowed against real AVC denials from a
real protected build + boot. Going enforcing on unnarrowed rules risks images
that boot into a broken state. Permissive + loaded modules + logged AVCs is the
honest increment; enforcing is the follow-up.

Line numbers below were re-located against `main` at implementation time
(2026-07-30). The ORIGINAL version of this document cited
`provision.sh:2214-2245` and `build-rpi5-stage4.sh:1304-1379/1531-1641`, all of
which had drifted — re-locate rather than trust any number here.

## Two corrections this document needed before it could be executed

**(A) The devel headers are not on the build host.** Step (b) below says to use
`/usr/share/selinux/devel/Makefile` "installed by `sec-policy/selinux-base` on
the BUILD host". `sec-policy/*` appears nowhere in `Dockerfile.build`, which
emerges only checkpolicy, semodule-utils, m4, libselinux and policycoreutils — so
the refpolicy devel tree is NOT on the build host. It IS merged into the target
sysroot by `sec-policy/selinux-base`, and it is arch-independent m4/make text.
The lib therefore compiles with the **SYSROOT's headers and the HOST's binaries**
(`PREFIX`/`BINDIR` pinned to `/usr`, `HEADERDIR` pointed into the sysroot), which
also means each module is compiled against the refpolicy version the image will
actually load it into. Nothing is ever compiled on the target.

**(B) The two k8s exemplars cannot compile on every image.**
`localpath_provisioner` and `otel_collector` call `container_domain_template` /
`kubernetes_container` / `container_list_log_dirs` / `container_search_logs`,
which come from `sec-policy/selinux-container` — only cluster-node images pull
that in. The other seven modules call base-refpolicy interfaces only. So the lib
splits them: the seven are MANDATORY (a compile failure fails the build) and the
two exemplars are CONDITIONAL (built where the container headers exist, recorded
as skipped-WITH-REASON where they do not). Every image writes
`/usr/share/hugmesh/selinux-modules.list` naming exactly what it installed, and
the enforce-gate's `check_modules()` reads that manifest instead of the old
hardcoded `base container otel_collector localpath_provisioner` list — which,
before this change, no image could ever have satisfied.

**Label-only `.fc` files.** `hugmesh_breakglass.fc` and `hugmesh_oidc_token.fc`
had no `.te`, so the devel Makefile had nothing to compile them into. Per option
(1) in step (b)'s note they were folded into `hugmesh_authkeys.fc` (the
login-credential module) and removed; no stub `.te` was invented. The lib now
FAILS on any `.fc` without a sibling `.te`, so this cannot silently recur.

## What exists today (the seams to build against)

1. **`SHARED_SPECS`** is defined at `build-rpi5-stage4.sh:43`
   (`SHARED_SPECS="${SCRIPT_DIR}/specs"`) and validated to exist at
   the `[ -d "${SHARED_SPECS}" ]` prereq check. The editable `specs/selinux/`
   directory lives directly under it as `${SHARED_SPECS}/selinux`. It used to be
   copied by NOTHING (`git grep 'specs/selinux' -- 'build-*.sh'` returned no
   hits); `slx_stage_node_policy "${SYSROOT}" "${SHARED_SPECS}"` now stages it.

2. **Host SELinux policy build tools are already gated** at
   `build-rpi5-stage4.sh:3013-3045`: the block ensures `checkpolicy`,
   `checkmodule`, `semodule_package` (sys-apps/semodule-utils), and `m4` are
   present on the x86 **BUILD host** (emerged natively, NOT into the aarch64
   sysroot), exiting non-zero if they cannot be provided
   (the `HOST_POLICY_TOOLS` block). These are exactly the tools the refpolicy
   module-build Makefile needs — so the per-module `.pp` compile below has its
   prerequisites **already guaranteed at that point in the script.**

3. **The node binaries the modules label are copied in** the arch-agnostic
   `${SHARED_SPECS}` block ("shared with the x86 build -> SHARED_SPECS"):
   `hugmesh-authorized-keys-lookup`, `hugmesh-device-registry-sync`,
   `hugmesh-vpn-runner` and friends. The modules' `.fc` files label these same
   paths, and the `.pp` install (step c) lands well before the first-boot
   relabel, so the labels and the modules that declare their types ship
   together.

4. **`provision_selinux()`** lives in the PROTECTED
   `specs/etc/keys-provision/provision.sh:2544-2575`. At first boot it:
   - writes `/etc/selinux/config` (`SELINUXTYPE=mcs`, default permissive);
   - if the policy store is unbuilt, runs
     `semodule -s "${type}" -B` **or** falls back to
     `semodule -s "${type}" -i /usr/share/selinux/"${type}"/*.pp`
     (**`provision.sh:2562-2564`**) — i.e. it loads **every `*.pp` already
     present under `${SYSROOT}/usr/share/selinux/${type}/`**;
   - relabels the filesystem (`setfiles` / `restorecon -RF /`,
     `provision.sh:2566-2572`) which applies all `.fc` file contexts;
   - is the LAST provisioning step (`provision.sh:2791`).

   **The implication: if the fleet installs the compiled `.pp` files into
   `${SYSROOT}/usr/share/selinux/${type}/` at build time, `provision_selinux()`
   already loads them with the EXISTING `semodule -i .../*.pp` line — no change
   to provision.sh is needed.** The wiring is entirely in the build script.

## What the builders now do (steps (a)-(d), as implemented)

All of it lives in `scripts/_selinux-policy-lib.sh`; each builder carries one
sentinelled source line and one sentinelled call site. The call site sits
immediately before `banner "Packaging stage4 tarball"` — the one late-stage
banner all ten builders share — which is AFTER the host-policy-tools gate
(`build-rpi5-stage4.sh:3045`, "Host SELinux policy build tools present …"), AFTER
the payload emerge, AFTER the kernel/bootloader stage and AFTER both arms of the
sysroot-clean if/else, and BEFORE anything is packaged or imaged. The steps below
are the original spec text; where the implementation had to diverge, see the two
corrections at the top of this document.

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
are the SAME ones already gated at `build-rpi5-stage4.sh:3016-3021` — so this
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
  (`hugmesh_breakglass`, `hugmesh_oidc_token`) have nothing for the devel
  Makefile to compile into a standalone `.pp`. The fleet has two clean options:
  (1) fold their `.fc` lines into a sibling module's `.fc` that DOES have a `.te`
  (e.g. add the break-glass line to `hugmesh_authkeys.fc`, the oidc-token
  line to the future desktop-session module), OR (2) add a one-line stub `.te`
  (`policy_module(<name>, 1.0.0)` + a `require {}` of the referenced base type:
  `ssh_home_t` / `user_runtime_t`) so the Makefile emits a `.pp` that carries the
  file-context. Option (1) matches how `hugmesh_breakglass.fc` already
  documents "no `.te` domain"; pick it unless a standalone module is wanted.
- Build the devel Makefile, NOT `emake base` — the base policy is already built
  by `sec-policy/selinux-base` (see `build-rpi5-stage4.sh:2976-2985`). These are
  **add-on modules**, compiled with the SAME host toolchain.

### (c) Install the `.pp` into the sysroot store so `provision_selinux()` finds them

`provision_selinux()` loads `/usr/share/selinux/${type}/*.pp`
(`provision.sh:2563`). Install each compiled `.pp` into the SYSROOT under that
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
`provision.sh:2563` then loads them at first boot, and the `setfiles /
restorecon -RF /` at `provision.sh:2566-2572` applies the `.fc` contexts (and
the existing `touch /.autorelabel` at `provision.sh:2573` covers a runtime
relabel).

### (d) Cross-built Pi caveat — build the `.pp` on the BUILD host, not first-boot

On the cross-built Pi (`build-rpi5-stage4.sh`) the aarch64 **target** may not
carry the refpolicy **devel** headers (`/usr/share/selinux/devel/`) at all — and
even if it did, `checkmodule`/`semodule_package` are x86 build-host binaries that
cannot run on the Pi. This is the SAME reason `build-rpi5-stage4.sh:2976-2985`
builds `base.pp` on the BUILD host and defers only the *load* to first boot.

Therefore steps (b)+(c) MUST run on the x86 BUILD host and ship the compiled
`.pp` artifacts INTO the image; first boot only does `semodule -i` of the
already-built `.pp` (which needs only target `semodule`, already gated by
`provision_selinux()` at `provision.sh:2546`). Do **not** attempt
`make -f .../devel/Makefile` on the target. (`build-x86-host-stage4.sh` is the
native case where it could compile first-boot, but compile-at-build is the
uniform, correct path for all three images.)

## Verification the fleet should add

- After (b), assert each expected `.pp` exists
  (`hugmesh_authkeys.pp`, `hugmesh_device_registry_sync.pp`,
  `hugmesh_vpn.pp`, `hugmesh_node_storage.pp`, `hugmesh_policy_sync.pp`,
  plus whatever the label-only modules resolve to per the (b) note); fail the
  build if any is missing (mirrors the `base.pp` failure mode the existing block
  already guards).
- In the QEMU enforcing verification (`tests/qemu/`, PROTECTED), after
  `setenforce 1`, drive an SSH login on a registry-enforced node and confirm NO
  `hugmesh_authkeys_t` / `hugmesh_device_registry_sync_t` AVC denials —
  this is the security-load-bearing path. Collect the permissive-pass AVCs to
  narrow every rule tagged `# INFERRED-WIDE: narrow after QEMU enforcing AVC
  pass` in the `.te` files.

## What is left (the follow-up this change deliberately does NOT do)

1. **Narrow the `# INFERRED-WIDE` rules.** Run a real protected build, boot it,
   collect the permissive-pass AVCs, and narrow every rule so tagged in
   `specs/selinux/*.te`. Nothing in this wiring can produce those AVCs; guessing
   a narrowing without them would be a security claim with no evidence behind it.
2. **Then, and only then, enable the gate.** `HUGMESH_SELINUX_ENFORCE_GATE=1`
   builds an image whose gate may flip to enforcing — and only on a later boot,
   after `check_mode_sane && check_modules && check_relabel_clean &&
   check_avc_clean` all pass.
3. **QEMU enforcing verification** (`tests/qemu/`): after `setenforce 1`, drive an
   SSH login on a registry-enforced node and confirm no `hugmesh_authkeys_t` /
   `hugmesh_device_registry_sync_t` AVC denials — the security-load-bearing path.
