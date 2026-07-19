# Cloud image packaging — `scripts/cloud-package.sh`

Converts a **built x86 raw `.img`** into the disk format a cloud importer
actually accepts. It is a standalone **post-build operator step**, deliberately
**not** wired into the builders' hot path, and it is **not a build channel, not
a matrix axis, and not a matrix row** ([`BUILD-MATRIX.md`](BUILD-MATRIX.md)):
the artifact a builder emits is unchanged; this tool only re-packages one you
already have. The **deploy** half (upload/import/register against a provider)
is the separate `snapdragon-cloud-deploy` driver, which consumes these
artifacts — this document covers packaging only.

## Usage

```sh
scripts/cloud-package.sh --img work-x86/acme-x86-amd64-pki-prod-<stamp>.img \
    --format qcow2|vhd-fixed|raw --out-dir cloud-out/
```

One artifact per run, plus one appended manifest line (the parseable API) in
`<out-dir>/cloud-package.manifest`, also echoed to stdout:

```
FORMAT <fmt> FILE <path> BYTES <n> SHA256 <hex>
```

| `--format` | Emits | For |
|---|---|---|
| `qcow2` | `<base>.qcow2` via `qemu-img convert -O qcow2` | KubeVirt/CNV (CDI DataVolume), libvirt/RHEL `virt-install`, OpenStack |
| `vhd-fixed` | `<base>.vhd` via `qemu-img convert -O vpc -o subformat=fixed,force_size`, virtual size **rounded UP to a whole MiB first** | Azure (Gen2 only — the `.img` is pure-UEFI, so Gen1/BIOS is impossible by design) |
| `raw` | `<base>.img` byte-identical copy + checksum | AWS `ec2 import-snapshot` (ingests RAW as-is; you mainly want the manifest line for the upload) |

The MiB round-up is an **Azure hard requirement** for fixed VHDs. The compact
x86 image is `1 + 512 + ROOT + 1` MiB (gap + ESP + root + slack), already a
whole-MiB multiple, so the round-up is normally a no-op; when an input is not
(e.g. a hand-trimmed image), padding happens on a **working copy** — the input
`.img` is never mutated — and rounding is always UP (down would truncate the
root partition). `qemu-img` is only needed for the two real conversions
(Gentoo: `app-emulation/qemu`; Debian: `qemu-utils`); `raw` is tool-free.
`SNAP_QEMU_IMG` overrides the binary (the test seam).

## x86 only — refused otherwise

Non-x86 artifacts are refused **by filename shape** (the builders stamp
platform+arch into every artifact name): anything `-arm64-`, anything without
the `-x86-amd64-` marker, `.iso` media, compressed `.xz`, and qcow2 bytes
hiding behind a `.img` name (magic check). The ARM images (rpi/jetson/frite/
orangepi) boot via u-boot / L4T + board-specific firmware rather than the
generic UEFI path clouds emulate — converting one produces a disk that cannot
boot, so the refusal is fail-closed, not cosmetic. Only the x86 raw `.img`
(pure-UEFI GPT, PARTUUID fstab, `growroot`) is cloud-viable today.

## What packaging does NOT solve (honest limits)

- **First-boot provisioning**: no cloud-init / waagent / ignition is baked into
  any image. Provisioning still reads a FAT32 volume labelled `KEYS`
  (`keys-provision`) — in a cloud that means attaching a small labelled data
  disk/volume, or a pre-mounted `/run/keys` + `KEYS_PREMOUNTED=1`. Azure/AWS
  agent-based provisioning (hostname, SSH key injection) will simply not run.
- **Cloud NIC/disk drivers**: the qemu boot tests prove virtio only. AWS ENA
  (`CONFIG_ENA_ETHERNET`) and Hyper-V (`hv_storvsc`/`hv_netvsc`) support is a
  kernel-config concern the format conversion cannot fix — verify before
  importing.
- **Disk growth** is the one thing that already works everywhere: the root
  partition is last and `growroot` expands it to the real disk on first boot.

## Test

Hermetic (tiny truncate-made sparse inputs + a recording `qemu-img` stub on the
`SNAP_QEMU_IMG` seam; no qemu, root or network):

```sh
bash tests/scripts/test-cloud-package.sh
```

It proves the rounding math (including the whole-MiB `1+512+ROOT+1` no-op case
and an odd-size round-UP), the exact `qemu-img` argv per format, input
immutability, every refusal path, manifest shape/append, and that the manifest
`BYTES`/`SHA256` describe the real produced artifact.
