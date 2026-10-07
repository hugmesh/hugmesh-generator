# Resource limits — how much of the machine HugMesh may use

The Studio can cap the CPU, memory and GPU that HugMesh work is allowed to consume.
It applies to **building** images and to **running** a mesh, which matters because the
Studio lives in the system tray on a machine somebody is also using for something
else.

Set it from the tray: **Resource limits…** (the menu entry states the current setting,
so you can read it without opening anything).

## The incident this exists for

On 2026-07-15 a dockerized fleet build compiled llvm's 32-bit multilib pass at `-j8`
inside an **unbounded** container, on a 31 GiB desktop that was also running a browser
and an IDE, whose 4 GiB of swap was already full. The host froze and rebooted.

The first response capped **memory** on single-image builds, so a runaway compile OOMs
the container — an honest build failure — instead of freezing the host. Two gaps
remained, and this feature closes them:

- **CPU was never capped anywhere.**
- **The fleet lane had no cap at all** — which is the lane the incident actually was.

## What the setting does, per lane

One number, five lanes, because each lane expresses limits differently. Three
deliver the limit today. Two are designed but not wired:

| Lane | How the limit is delivered | Wired |
|---|---|---|
| Single-image build | `docker run --cpus/--memory/--gpus` (`core/build_driver.py`) | yes |
| Fleet build | the same flags (`core/fleet.py`) | yes |
| Local compose stack | a generated `tests/stack/.compose.limits.yaml` overlay | yes |
| QEMU emulation | `-smp` on the guest | **no** |
| kind / Kubernetes | `docker update` on the node container | **no** |

QEMU: `qemu_smp()` exists and the dialog prints its result, but
`core/emulation.py` never reads it and keeps its own `--smp` default. kind:
`docker update` appears only in a docstring; no code runs it. Until both are
wired, the dialog's line for emulated devices states a setting the emulated guests
do not receive.

The dialog states the **transformed** value for each lane rather than repeating your
input back, because two of them change it:

- **Compose** divides. A memory limit is a hard per-service ceiling and memory is
  additive, so writing a 16 GiB budget onto each of 41 services would authorise 41×
  the machine's RAM and protect nothing. It is divided, with a floor of 384 MiB per
  service — and if the
  share would be too small to start a service, **no memory limit is written at all**,
  because a limit every service breaches at startup is worse than none.
- **QEMU** (once wired) rounds **down**. `-smp` is a whole number of vCPUs and the setting is a
  ceiling, so 1.5 becomes 1. Rounding up would hand the guest more of the host than
  you allowed.

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

- **CPU**: every core but one, floored at 1. Deliberately not a percentage — what
  makes a desktop feel broken under load is having no core left for the compositor,
  and that is an absolute shortfall, not a proportional one. Reserving 25% leaves a
  16-core box four spare cores it does not need and a 2-core box half a core it cannot
  use.
- **Memory**: unchanged from the existing guard —
  `max(2 GiB, min(total - 4 GiB, total * 3/4))`. On a host whose `/proc/meminfo`
  cannot be read (Windows, macOS) it caps nothing rather than guessing; CPU is still
  capped, because core counts are available everywhere.
- **GPU**: none. A mesh running in the background must not silently take the GPU away
  from what you are actually doing, so GPU access is opt-in.

## GPU is an allocation, not a throttle

There is no "50% of a GPU" to set: container runtimes expose GPUs as devices. The GPU
field therefore selects **which** devices a lane may see (`all`, `device=0`), and
asking for one on a host with no GPU container runtime produces a warning rather than
a silent no-op. The warning is advisory — you may be configuring on one machine for
another.

## Turning it off

Set every field empty (or `off`). The compose overlay is **deleted**, not emptied, so
the Makefile's `$(wildcard)` include contributes no `-f` flag and the stack comes up
exactly as it did before. Every build command returns to its pre-limit argv, byte for
byte — which is what makes this safe to have added.

Implementation: `studio/hugmesh_studio/core/resource_limits.py` (the decisions) and
`core/stack_limits.py` (the compose overlay). Both are Qt-free and directly tested in
`studio/tests/test_resource_limits.py`.
