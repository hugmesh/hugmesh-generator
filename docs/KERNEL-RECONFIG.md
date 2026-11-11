# Kernel config… — menuconfig a built x86 image, then rebuild, re-sign and repackage

On the Studio's Build page, once an image's **Build kernel** step has finished, its
stage row carries a **Kernel config…** button. It opens `make menuconfig` for that
image's own kernel in a separate terminal window. When you save there, the Studio shows
the change symbol by symbol. **Rebuild kernel + re-sign + repackage** then rebuilds only
the kernel and its modules, re-signs the Secure Boot UKI with the key the build used, and
repackages the stage4 tar, the `.img`, the `.fs.tar` and both ISOs. It does not run a
full rebuild.

The same action is on a finished session in **Previous builds** (and in its per-build
window), in the TUI sessions review (`k NUMBER`), and on the command line.

This is **x86 only** for now. The ARM builders delete their kernel source at the clean
step, so on an ARM image the button stays greyed with that sentence as its reason.

## What happens, step by step

The worker is `scripts/kernel-reconfig-x86.sh`. It runs as root, either natively
(`sudo`) or in the builder container (the Studio mounts the generator at `/src` and the
session at `/out`, exactly as for the build).

1. **edit** (the button, or `--kernel-config`) runs `make menuconfig` inside the build
   system (a chroot), on a **copy** of the build's final `.config`. The build's own
   `.config` is never touched, so you can open it while the image is still being packed.
   In that case it mounts nothing inside the build system: the builder refuses to label
   or clean a build system that has something mounted in it. Saving writes
   `<build-root>/kernel-reconfig/pending/config.after`.
2. The Studio diffs `config.before` against `config.after` and shows the result
   (`CONFIG_LOCALVERSION: "" -> "-hmtest"`).
3. **apply** (the rebuild button, or `--kernel-config-apply`):
   - runs `make olddefconfig`, then the builder's **own** hardening asserts
     (`scripts/_x86-kernel-asserts.sh`: KSPP, SELinux, SQUASHFS_XATTR, the k8s and
     host-firewall netfilter sets, the `CONFIG_LSM` string and every name in it, BTF).
     An edit that drops one is refused, naming the symbol, and the tree's `.config` is
     put back;
   - compiles and installs with the builder's **own** recipe
     (`scripts/_x86-kernel-install.sh`). Modules are stripped before they are signed. If
     the kernel release changed, the old module tree and initramfs are removed. The live
     initramfs is rebuilt when the build has a live ISO;
   - signs the UKI with `<session>/secureboot/sb.key` and checks it with
     `sbverify --cert sb.crt`. Unlike the build, it never mints a new key, and a failed
     sign or verify stops it. An image that was built unsigned stays unsigned, and the
     Studio says so;
   - relabels the build system (SELinux) and runs the label gate;
   - **patches** the artifacts this build produced rather than re-running the image
     steps. PARTUUIDs, `grub.cfg`, the installer's LUKS keyfile and passphrase marker,
     and the home archive all stay as built, and no secret is needed:
     - **stage4**: re-tarred with the builder's exclude set, then label-gated;
     - **`.img`**: patched through `build_img`'s own offset-loop recipe. A release
       change rewrites the `initrd` lines in `grub.cfg` (the default and rescue
       entries), and the ESP copy of the UKI is checked with `sbverify`;
     - **`.fs.tar`**: regenerated from that `.img`;
     - **live ISO**: the squashfs is unpacked, patched, repacked, and passed through the
       builder's live-root and label gates;
     - **both ISOs**: rewritten with `xorriso`'s boot-image replay;
   - gives the new artifacts a new UTC timestamp in the **same** name pattern, writes
     `<artifact>.sha256` beside each one (the Flash panel verifies these), and moves the
     originals to `<session>/superseded/<old-timestamp>/`;
   - records the result in `<build-root>/kernel-reconfig/<stamp>/result.json` and on
     the session record (`kernel_reconfigs`, shown by `--show-session`).

The rebuild never stores into the signed-kernel cache: an edited kernel is never served
to another image.

## When it refuses (one sentence each)

| Situation | What you see |
|---|---|
| ARM image | Kernel reconfiguration is x86-only for now: … builds delete their kernel source at the clean step. |
| Build files deleted | The build system for this image is gone (…) — … Rebuild the image. |
| A build from before this feature | This build predates kernel reconfiguration — rebuild it once. |
| Kernel restored from an older cache entry | No kernel config was kept for … — rebuild the image once. |
| Image still building | This image is still building — wait for it to finish. |
| Another build or an emulated device is running | Builds run one at a time on this machine and … — the rebuild waits until it finishes. |
| Signed image, key gone | The Secure Boot key this image was signed with is gone: … |
| Edit drops a hardening option | The edited kernel config fails the build's hardening asserts: … — nothing was rebuilt. |
| Out-of-tree modules (e.g. NVIDIA) | This image carries out-of-tree kernel modules (…) built against its current kernel; … |
| Not enough disk | Repackaging needs about N GiB free under …; M GiB is available. |
| No terminal window can be opened | No terminal window could be opened on this desktop — run this in a terminal: `<the exact command>` |

## Where the window opens

| Host | Window |
|---|---|
| Linux | the first terminal found from the Studio's terminal list (konsole, gnome-terminal, ptyxis, kgx, xterm, …) |
| WSL2 | Windows Terminal (`wt.exe`), or a plain console |
| Windows | a new console |
| macOS | Terminal.app, through `osascript` |

With the docker backend, the window runs `docker run -it … hugmesh-builder` after the
build. While the build container is still running, it runs `docker exec -it` into that
container instead. With the native backend it runs `sudo bash scripts/kernel-reconfig-x86.sh edit`,
so the password prompt appears in that window.

## Command line

```
python -m hugmesh_studio --kernel-config SESSION[:IMAGE]          # menuconfig in THIS terminal, then the diff
python -m hugmesh_studio --kernel-config-set SESSION[:IMAGE] \
       --kernel-config-args="--set-str LOCALVERSION -hmtest"      # a scripted edit (scripts/config)
python -m hugmesh_studio --kernel-config-diff SESSION[:IMAGE]     # the pending change
python -m hugmesh_studio --kernel-config-apply SESSION[:IMAGE]    # rebuild + re-sign + repackage (streams)
python -m hugmesh_studio --kernel-config-discard SESSION[:IMAGE]  # drop the pending edit
```

`IMAGE` defaults to the session's first x86 image. Exit codes: `0` done, `2` bad input
or no such session, `3` refused (the sentence is on stderr).

## What the build keeps for this

`build-x86-host-stage4.sh` writes three things outside the image:

- `<build-root>/kernel/config-<kver>`: the final `.config`. On a kernel-cache hit it
  comes from the cache entry's `config` payload. An entry stored before this feature
  has no such payload, and the Studio refuses that image until it is rebuilt once.
- `<build-root>/kernel-reconfig.env`: a no-secret `KEY=VALUE` contract (names, labels,
  artifact basenames, whether the UKI verified against `sb.crt`). It is never sourced;
  the readers accept only the keys they know.
- `<build-root>/kernel/reconfigured`: written by apply. A later `--resume` of that
  build removes the edited kernel and recompiles from the fragments instead of
  restoring a cached kernel over it.

**A Restart or Redo of the session rebuilds the kernel from its fragments, so an applied
menuconfig edit is not carried over.** The session record keeps what the artifacts
carried at the time.

## The module-signing key no longer ships in the live ISO

Until this change the live ISO packed the whole build system, including
`/usr/src/linux-*/certs/signing_key.pem`, the kernel's **module-signing private key**.
Under `lockdown=integrity`, anyone holding that ISO could sign a module that the `.img`,
the stage4 and every installed kernel of that build would accept. This was found on a
real pki `live.iso`. The live pack now excludes `usr/src` in both of its arms, as the
stage4 tar always has, and `live_root_gate` lists the packed image and refuses one that
still carries the key. **Live ISOs built before this change carry it**, as does every
image that restored the same cached kernel. Rotating that key (invalidating the x86
kernel cache and rebuilding what shipped) is an operator decision.

## Tests

- `tests/scripts/test-kernel-reconfig-x86.sh` runs the script's real functions against
  fixture build roots. It covers the refusals, the asserts path, strict signing, the
  grub rewrite, the pins against the builder, the builder's marker, config and env
  contract.
- `tests/scripts/test-x86-live-root-pack.sh` checks the usr/src exclude and the
  key-leak gate.
- `studio/tests/test_kernel_reconfig.py` covers the Qt-free core and the CLI.
- `studio/tests/test_kernel_reconfig_gui.py` covers the button latch, the panel, the
  Previous builds action, and screenshots plus geometry at 1200x800 and 942x552.
- `studio/tests/test_tui_gui_parity.py` checks that the action and its refusal sentence
  match on every face.
