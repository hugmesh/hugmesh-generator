# SELinux node-policy module loading — fleet build-script wiring spec

**Status: IMPLEMENTED.** The nine modules in `specs/selinux/` are compiled at build
time, installed into every image's policy store, and loaded at first boot. The
code is `scripts/_selinux-policy-lib.sh`, sourced by all ten `build-*-stage4.sh`
(one source line and one call site each, immediately before
`banner "Packaging stage4 tarball"`). The gate is
`tests/scripts/test-selinux-policy-install.sh`, run as the GATING `SLX` bucket of
`tests/build-matrix/check.sh`.

**Images still boot PERMISSIVE.** The modules are compiled, installed and loaded.
Nothing flips a node to enforcing.
`specs/etc/init.d/selinux-enforce-gate` ships into every image but is INERT: it is
in no runlevel, and `/etc/conf.d/selinux-enforce-gate` says
`SELINUX_ENFORCE_GATE="no"`, unless the operator sets
`HUGMESH_SELINUX_ENFORCE_GATE=1` at build time. That is deliberate. The `.te` files
still carry 59 rules tagged `# INFERRED-WIDE: narrow after QEMU enforcing AVC pass`,
and these can only be narrowed against a real protected build and boot. Going
enforcing on unnarrowed rules risks images that boot into a broken state.
Permissive, with loaded modules and logged AVCs, is the safe increment. Enforcing
is the follow-up (see "What is left").

Line numbers drift. This page names functions and files instead. The first
version of this document cited `provision.sh` and `build-rpi5-stage4.sh` line
numbers that had all moved by the time it was implemented.

## Two corrections this document needed before it could be executed

**(A) The devel headers are not on the build host.** The first design said to use
`/usr/share/selinux/devel/Makefile` "installed by `sec-policy/selinux-base` on the
BUILD host". Neither half is true (see step 3 in (b)). `sec-policy/*` appears
nowhere in `Dockerfile.build`, and Gentoo does not use the Fedora `devel` layout.

**(B) The module-load gate looked at the wrong thing (fixed 2026-08-22).**
`localpath_provisioner` and `otel_collector` call `container_domain_template`,
`kubernetes_container`, `container_list_log_dirs` and `container_search_logs`.
`kubernetes_container()` is defined in `services/kubernetes.if` and expands to the
attribute `kubernetes_container_domain`, which only **`kubernetes.pp`
(`sec-policy/selinux-kubernetes`)** defines. `hugmesh_tor` requires `tor_t`,
`tor_var_lib_t` and `tor_etc_t` from **`tor.pp` (`sec-policy/selinux-tor`)**.

The old gate asked whether an *interface* was present in the refpolicy headers.
`sec-policy/selinux-base` installs the **whole** include tree, so every
`services/*.if` is on disk whichever `.pp` modules were merged. These three
therefore compiled and then failed to load on a real node:

```
FAIL hugmesh_tor            :: Failed to resolve typeattributeset ... cil:11
FAIL localpath_provisioner  :: Failed to resolve typeattributeset ... cil:20
FAIL otel_collector         :: Failed to resolve typeattributeset ... cil:20
```

This was measured by booting `hugmesh-x86-amd64-pki-test-20260814T112817Z`
(issue #45). Because `check_modules()` requires **every** manifest module to be
loaded, three unloadable modules meant the enforce-gate could never flip.
`SELINUX_ENFORCE_GATE` would have refused on every boot, silently, even when
switched on. The lib now gates on the **policy store** (`<store>/<dep>.pp`), not on
headers.

## What exists today (the seams to build against)

| Module | Kind |
|---|---|
| `hugmesh_authkeys`, `hugmesh_device_registry_sync`, `hugmesh_domain_reconcile`, `hugmesh_node_storage`, `hugmesh_policy_sync`, `hugmesh_vpn` | **mandatory**: they call base-refpolicy interfaces only. A compile failure fails the build. |
| `localpath_provisioner`, `otel_collector` | **conditional**: need the upstream `container` and `kubernetes` policy modules in the policy store. |
| `hugmesh_tor` | **conditional**: needs the upstream `tor` policy module in the policy store. |

The map is `_SLX_MODULE_DEPS` in the lib. It is explicit, not derived from the
`.te`, so a reviewer sees the whole conditional surface at once and a wrong entry
fails at build time instead of at first boot. A conditional module whose
dependency is absent is skipped, with the Gentoo package that would fix it
(`sec-policy/selinux-kubernetes`, `sec-policy/selinux-tor`). It never enters the
manifest. Merge the package into an image and the module builds, installs and is
required automatically.

(The header comment of `_selinux-policy-lib.sh` and `README.md` still say "seven
mandatory, two conditional". The lib's own map and the gate's `MANDATORY` array
say six and three.)

**First boot.** `provision_selinux()` lives in the protected
`specs/etc/keys-provision/provision.sh`. It is the LAST provisioning step, because
it relabels the fully provisioned filesystem. It:

- writes `/etc/selinux/config` from the KEYS manifest (`selinux.type` default
  `mcs`, `selinux.mode` default `permissive`);
- if the policy store is not built, loads the base policy (`semodule -s <type> -B`,
  falling back to `semodule -i /usr/share/selinux/<type>/*.pp`);
- runs the block delimited `BEGIN/END hugmesh node-policy load`. It installs
  exactly the modules listed in `/usr/share/hugmesh/selinux-modules.list`, batched
  first and then one by one if the batch fails. Then it reads the verdict back
  from the store (`semodule -l`) into `/var/lib/keys-provision/selinux-modules.status`
  (one `<module> loaded|failed|missing-pp` line each). Any module that is not
  loaded records the `selinux-load-failed` marker, and the enforce-gate then
  refuses to flip. The extra block is needed because the base-policy load above it
  runs only when the store is unbuilt, and `semodule -B` rebuilds from the module
  store, which does not contain the build-installed `.pp` packages until
  `semodule -i` runs;
- relabels with `restorecon -RF /`. It does not use `setfiles` first: on a measured
  image `setfiles` wrote the literal context `kernel` for every path and exited 0.
  `/.autorelabel` carries the standard request-flag semantics. Nothing on these
  OpenRC images consumes it at boot, so `provision_selinux()` clears it after a
  successful relabel and leaves it raised only when the relabel failed. The
  gate's `check_relabel_clean()` then refuses on it.

The enforce-gate flips a node to enforcing only if
`check_mode_sane && check_provision_ok && check_modules && check_relabel_clean &&
check_avc_clean` all pass, and only on a later boot.

## What the builders now do (steps (a)-(d), as implemented)

All of it is in `scripts/_selinux-policy-lib.sh`, entry point
`slx_stage_node_policy <sysroot> <shared_specs>`. It runs after the payload emerge,
the kernel and bootloader stage, and both arms of the sysroot clean, and before
anything is packaged. It runs on the x86 **build host**.

### (a) Copy `SHARED_SPECS/selinux` into the build

The lib copies `<shared_specs>/selinux/*.te` and `*.fc` into a scratch directory
(`mktemp -d`) and builds there. The modules are arch-agnostic, so every builder
stages the same files. Before the lib existed, nothing copied `specs/selinux` at all.

1. **Skip switch.** `HUGMESH_SELINUX_MODULES=0` skips the step, loudly. The node
   then boots permissive with only the distro base policy.

2. **Check the sources.** Every `.fc` must have a sibling `.te`. A label-only `.fc`
   cannot be compiled by the module Makefile and would be silently dropped, so
   the lib fails on one. (`hugmesh_breakglass.fc` and `hugmesh_oidc_token.fc` were
   folded into `hugmesh_authkeys.fc`, and no stub `.te` was invented.)

### (b) Compile each module to a `.pp` over `specs/selinux` on the BUILD host

3. **Find the header tree.** The lib uses the **sysroot's** refpolicy headers and
   the **host's** binaries (`PREFIX`/`BINDIR` pinned to the host `/usr`,
   `HEADERDIR` pointed into the sysroot). Each module is therefore compiled against
   the refpolicy version the image will load it into. On Gentoo,
   `sec-policy/selinux-base` installs the headers per policy type at
   `<sysroot>/usr/share/selinux/<type>/include` (with `Makefile`, `build.conf` and
   `support/`). `/usr/share/selinux/devel` is the Fedora layout; on Gentoo it holds
   only `doc/policy.xml`. The refpolicy devel tree is **not** on the build host:
   `Dockerfile.build` emerges only checkpolicy, semodule-utils, m4, libselinux and
   policycoreutils.

4. **Check the host tools** (`m4`, `checkmodule`, `semodule_package`). The builders'
   `HOST_POLICY_TOOLS` gate already provisions them, and the lib re-asserts them at
   the point of use.

5. **Skip modules with a missing dependency**, as in the module table.

6. **Compile each module** to a `.pp`. The lib refuses to install anything if any
   buildable module fails to compile.

### (c) Install the `.pp` into the sysroot store so `provision_selinux()` finds them

7. **Install all-or-nothing** into `<sysroot>/usr/share/selinux/<type>/`. It first
   prunes `.pp` files the previous manifest named whose `.te` has since been
   withdrawn. The prune goes strictly by the previous manifest, never by glob, so
   the distro's `base.pp` and other `sec-policy/*` modules are untouched.

8. **Write the manifest** `/usr/share/hugmesh/selinux-modules.list`, naming exactly
   what this image installed. The enforce-gate's `check_modules()` reads this
   manifest. Before the lib existed it used a hardcoded
   `base container otel_collector localpath_provisioner` list that no image could
   ever have satisfied.

9. **Mark the image SELinux-built** and **ship the enforce-gate** service file and
   conf.d switch (inert by default, as above).

### (d) Cross-built Pi caveat — build the `.pp` on the BUILD host, not first-boot

Nothing is compiled on the target. `checkmodule`, `semodule_package` and `m4` are
x86 host binaries, and a cross-built Pi cannot run them. The aarch64 target also
need not carry the refpolicy headers. So steps (b) and (c) run on the x86 build
host and ship the compiled `.pp` files into the image. First boot only loads them
with `semodule`. This is also why `sec-policy/selinux-base` builds `base.pp` on the
build host and defers only the *load* to first boot. Do not run the module Makefile
on the target. `build-x86-host-stage4.sh` could compile at first boot, but
compile-at-build is the one path all ten builders share.

## Verification the fleet should add

- `tests/scripts/test-selinux-policy-install.sh` (the `SLX` bucket) checks that
  the six mandatory `.pp` land in the store and that the manifest matches.
- `tests/qemu/avc-workload.sh` and `tests/qemu/avc-workout.sh` drive the modules'
  domains in a booted guest. They cover `hugmesh_authkeys` (ssh logins, a direct
  `hugmesh-authorized-keys-lookup`, `sshd -T`) and a `svc_probe` for each
  reconcile agent, plus `containerd`, `kubelet` and `kubeadm init --dry-run` for the
  `localpath_provisioner` and `otel_collector` lane.
- `tests/qemu/assertions.sh` asserts on `selinux-modules.status`.
- The security-load-bearing path is an SSH login on a registry-enforced node. After
  `setenforce 1` it must produce no `hugmesh_authkeys_t` or
  `hugmesh_device_registry_sync_t` AVC denials.

## What is left (the follow-up this change deliberately does NOT do)

1. **Narrow the `# INFERRED-WIDE` rules, but NOT from AVC denials.** An earlier
   version of this step said to collect the permissive-pass AVCs and narrow every
   rule so tagged. That cannot work:
   - an AVC **denial** is raised for something the policy does **not** allow, so it
     tells you what to **ADD**;
   - narrowing an over-broad `allow` needs what was actually **exercised**, which
     is an **`auditallow`** record (`type=AVC ... granted=`).

   Measured: with six modules loaded and the full workload driven in permissive
   mode, the run produced **zero denials**, correctly, because a deliberately wide
   rule denies nothing. Denial collection can never narrow it.

   The instrument is `scripts/selinux-make-auditallow.sh`. It converts each
   compiled `.pp` back to CIL, which is **post-expansion**. It therefore captures
   the 28 tagged lines that are interface calls (`corenet_tcp_connect_all_ports(...)`)
   and not only the 12 that are raw `allow` statements. It rewrites every
   `(allow <hugmesh_*> ...)` into `(auditallow ...)`. `hugmesh_vpn` alone expands
   from 19 tagged lines to 224 rules (the figure in the script header; this page
   used to say 217). The emitted module grants nothing and changes no decision; it
   makes granted accesses visible:

   ```
   scripts/selinux-make-auditallow.sh --pp-tool <sysroot>/usr/libexec/selinux/hll/pp \
       /usr/share/selinux/mcs/hugmesh_*.pp > narrow.cil
   semodule -s mcs -i narrow.cil     # verified: loads clean on a real node
   ... drive tests/qemu/avc-workload.sh ...
   ausearch -m AVC | grep granted=   # exactly what each wide rule really used
   ```

   Two traps each produce a clean-looking result by accident:
   - AVCs land in **`/var/log/audit/audit.log`** (auditd runs), **not dmesg**.
   - **`runcon` is not installed** on these images, so the obvious "force a denial
     to prove audit works" probe does nothing and reads as success.
2. **Then, and only then, enable the gate.** `HUGMESH_SELINUX_ENFORCE_GATE=1`
   builds an image whose gate may flip to enforcing, on a later boot, after the
   the five checks listed under "What exists today" all pass.
3. **QEMU enforcing verification** (`tests/qemu/`): after `setenforce 1`, drive an
   SSH login on a registry-enforced node and confirm no `hugmesh_authkeys_t` or
   `hugmesh_device_registry_sync_t` AVC denials.
