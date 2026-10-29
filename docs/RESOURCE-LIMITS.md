# Resource limits — how much of the machine HugMesh may use

The Studio can cap the CPU, memory and GPU that HugMesh work may use. The caps apply
to **building** images and to **running** a mesh. That matters because the Studio
sits in the system tray of a machine someone is also using for other work.

Set the caps from the tray: **Resource limits…**. The menu entry shows the current
setting, so you can read it without opening anything.

## The incident this exists for

On 2026-07-15 a dockerized fleet build compiled llvm's 32-bit multilib pass at `-j8`
inside an **unbounded** container. The 31 GiB desktop was also running a browser and
an IDE, and its 4 GiB of swap was already full. The host froze and rebooted.

The first fix capped **memory** on single-image builds. A runaway compile now OOMs the
container, which is an honest build failure, instead of freezing the host. Two gaps
remained. This feature closes them:

- **CPU was never capped anywhere.**
- **The fleet lane had no cap at all** — which is the lane the incident actually was.

## What the setting does, per lane

One number, six lanes, because each lane expresses limits differently. Four
deliver the limit today. Two are designed but not wired:

| Lane | How the limit is delivered | Wired |
|---|---|---|
| Single-image build | `docker run --cpus/--memory/--gpus` (`core/build_driver.py`) | yes |
| Fleet build | the same flags (`core/fleet.py`) | yes |
| Local compose stack | a generated `tests/stack/.compose.limits.yaml` overlay | yes |
| Mesh node (tray **Start mesh node**, `make mesh-node-up`) | a generated `docker-compose.limits.yml` overlay next to the staged node (`core/mesh_node.py`) | yes |
| QEMU emulation | `-smp` on the guest | **no** |
| kind / Kubernetes | `docker update` on the node container | **no** |

QEMU: `qemu_smp()` exists, but `core/emulation.py` never reads it and the
emulation page always asks for 2 vCPUs per device. kind: `docker update` appears
only in a docstring; no code runs it. The dialog and the tray say so ("Not limited
by this setting yet: emulated devices (QEMU) and Kubernetes (kind) nodes"), and
`studio/tests/test_limits_reach_lanes.py` fails if either text claims one of these
lanes again before code reads the setting for it.

The mesh node is a single container, so it gets the **whole** budget, not a share.
Memory swap is pinned to the memory limit (no swap), as for builds. It is never given
a GPU: it only carries tailnet traffic. Measured 2026-10-21: with a 2-CPU, 1g limit
saved in the dialog, the tray-started node's container ran with `NanoCpus=2000000000`,
`Memory=1073741824`, cgroup `cpu.max = 200000 100000`, and still joined headscale.
Before this change the same node ran with `NanoCpus=0` (no cap).

The dialog shows the **transformed** value for each lane, not your input, because two
lanes change it:

- **Compose** divides. A memory limit is a hard per-service ceiling, and memory adds
  up. A 16 GiB budget written onto each of the 43 services in
  `tests/stack/compose.local.yaml` would allow 43× the machine's RAM and protect
  nothing. So the budget is divided, with a floor of 384 MiB per service. If the share
  is too small to start a service, **no memory limit is written at all**. A limit every
  service breaches at startup is worse than none.
- **QEMU** (once wired) rounds **down**. `-smp` is a whole number of vCPUs and the
  setting is a ceiling, so 1.5 becomes 1. Rounding up would give the guest more of the
  host than you allowed.

## The knobs

Each field follows the same three-way contract as the original memory guard:

| Value | Meaning |
|---|---|
| unset / empty | the automatic formula for this host |
| `0`, `off`, `none` | no limit — and the command is **byte-identical** to what it was before this feature existed |
| anything else | passed through verbatim; Docker validates it |

```bash
HUGMESH_CPUS=6           # six cores' worth of CPU time
HUGMESH_BUILD_MEMORY=16g # the pre-existing memory knob, unchanged
HUGMESH_GPUS=all         # or device=0 — default is NO GPU
```

Precedence: **environment → saved GUI setting → automatic**. An environment variable
wins so a scripted run can bound itself without mutating your saved preferences.

## The automatic formula

- **CPU**: every core but one, floored at 1. It is deliberately not a percentage. A
  desktop feels broken under load when no core is left for the compositor, and that is
  an absolute shortfall, not a proportional one. Reserving 25% would leave a 16-core
  box four spare cores it does not need and a 2-core box half a core it cannot use.
- **Memory**: unchanged from the existing guard,
  `max(2 GiB, min(total - 4 GiB, total * 3/4))`. If `/proc/meminfo` cannot be read
  (Windows, macOS), it caps nothing instead of guessing. CPU is still capped, because
  core counts are available everywhere.
- **GPU**: none. A mesh in the background must not take the GPU from what you are
  doing, so GPU access is opt-in.

## GPU is an allocation, not a throttle

You cannot set "50% of a GPU": container runtimes expose GPUs as devices. The GPU
field selects **which** devices a lane may see (`all`, `device=0`). Asking for one on
a host with no GPU container runtime gives a warning, not a silent no-op. The warning
is advisory, because you may be configuring one machine for another.

## Turning it off

Set every field empty (or `off`). The compose overlay is **deleted**, not emptied, so
the Makefile's `$(wildcard)` include adds no `-f` flag and the stack comes up as it did
before. Every build command returns to its pre-limit argv, byte for byte. That is what
makes the feature safe to add.

Implementation: `studio/hugmesh_studio/core/resource_limits.py` (the decisions) and
`core/stack_limits.py` (the compose overlay). Both are Qt-free and directly tested in
`studio/tests/test_resource_limits.py`.
