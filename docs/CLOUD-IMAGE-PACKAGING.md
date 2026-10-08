# Cloud image packaging — `scripts/cloud-package.sh`

This script turns a **built x86 raw `.img`** into the disk format a cloud importer
accepts. It is a standalone **post-build operator step**. The builders do not call
it. It is **not a build channel, not a matrix axis, and not a matrix row**
([`BUILD-MATRIX.md`](BUILD-MATRIX.md)). The builder's artifact is unchanged. The tool
only re-packages an image you already have. The **deploy** half (upload, import and
register against a provider) is the separate `hugmesh-cloud-deploy` driver, which
consumes these artifacts. This page covers packaging only.

## Usage

```sh
scripts/cloud-package.sh --img work-x86/acme-x86-amd64-pki-prod-<stamp>.img \
    --format qcow2|vhd-fixed|raw --out-dir cloud-out/
```

Each run makes one artifact and appends one manifest line (the parseable API) to
`<out-dir>/cloud-package.manifest`. It also prints that line to stdout:

```
FORMAT <fmt> FILE <path> BYTES <n> SHA256 <hex>
```

| `--format` | Emits | For |
|---|---|---|
| `qcow2` | `<base>.qcow2` via `qemu-img convert -O qcow2` | KubeVirt/CNV (CDI DataVolume), libvirt/RHEL `virt-install`, OpenStack |
| `vhd-fixed` | `<base>.vhd` via `qemu-img convert -O vpc -o subformat=fixed,force_size`, virtual size **rounded UP to a whole MiB first** | Azure (Gen2 only — the `.img` is pure-UEFI, so Gen1/BIOS is impossible by design) |
| `raw` | `<base>.img` byte-identical copy + checksum | AWS `ec2 import-snapshot` (ingests RAW as-is; you mainly want the manifest line for the upload) |

Azure requires the MiB round-up for fixed VHDs. The compact x86 image is
`1 + 512 + ROOT + 1` MiB (gap + ESP + root + slack), already a whole number of MiB,
so the round-up is normally a no-op. When an input is not (a hand-trimmed image, say),
the script pads a **working copy**. It never changes the input `.img`. It always
rounds UP, because rounding down would cut into the root partition.

`qemu-img` is needed only for the two real conversions (Gentoo:
`app-emulation/qemu`; Debian: `qemu-utils`). `raw` needs no tool. `SNAP_QEMU_IMG`
overrides the binary (the test seam).

## x86 only — refused otherwise

The script refuses non-x86 artifacts **by filename**, because the builders stamp
platform and arch into every artifact name. It refuses:

- anything `-arm64-`;
- anything without the `-x86-amd64-` marker;
- `.iso` media;
- compressed `.xz`;
- qcow2 bytes behind a `.img` name (magic check).

The ARM images (rpi/jetson/frite/orangepi) boot through u-boot or L4T plus
board-specific firmware, not the generic UEFI path clouds emulate. A converted one
cannot boot. So the refusal is fail-closed, not cosmetic. Today only the x86 raw
`.img` (pure-UEFI GPT, PARTUUID fstab, `growroot`) is cloud-viable.

## What packaging does NOT solve (honest limits)

- **First-boot provisioning.** No cloud-init, waagent or ignition is baked into any
  image. Provisioning still reads a FAT32 volume labelled `KEYS` (`keys-provision`).
  In a cloud that means attaching a small labelled data disk, or a pre-mounted
  `/run/keys` plus `KEYS_PREMOUNTED=1`. Azure and AWS agent-based provisioning
  (hostname, SSH key injection) will not run.
- **Cloud NIC and disk drivers.** The qemu boot tests prove virtio only. AWS ENA
  (`CONFIG_ENA_ETHERNET`) and Hyper-V (`hv_storvsc`/`hv_netvsc`) support is a
  kernel-config matter that format conversion cannot fix. Check it before importing.
- **Disk growth** already works everywhere. The root partition is last, and
  `growroot` expands it to the real disk on first boot.

## Test

The test is hermetic. It uses tiny truncate-made sparse inputs and a recording
`qemu-img` stub on the `SNAP_QEMU_IMG` seam. It needs no qemu, root or network:

```sh
bash tests/scripts/test-cloud-package.sh
```

It proves the rounding math (the whole-MiB `1+512+ROOT+1` no-op and an odd-size
round-UP), the exact `qemu-img` argv per format, that the input is never changed,
every refusal path, the manifest shape and append, and that the manifest `BYTES` and
`SHA256` describe the artifact really produced.
