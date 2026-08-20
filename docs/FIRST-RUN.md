# First-run bootstrap (issue #49)

The FIRST run of the Studio or any CLI entry performs one idempotent,
per-user, **advisory-only** bootstrap. It is implemented as a pair:

| half | file | job |
| --- | --- | --- |
| shell (POSIX sh) | `scripts/_first-run-lib.sh` | the gate: one `cat` when already stamped, otherwise invoke the python half |
| python (stdlib, Qt-free) | `studio/hugmesh_studio/core/first_run.py` | the work: symlinks + properties + doctor |

Wired into every entry point:

- `scripts/studio-launch.sh` — guided and `--menu` paths. The **headless
  automation channel** (`--print-command`, `--login-agent`, …) is deliberately
  excluded: its documented contract is "no prompts, no installs", and a PATH
  symlink is an install. `--detect` stays a pure report.
- `scripts/build-menu.sh` — direct runs (`make menu`, `./scripts/build-menu.sh`).
- `scripts/hugmesh-mesh-node` — the local-mesh CLI face.

## What it does

1. **Symlinks** — per-user command names in `~/.local/bin` (the XDG
   user-executables dir; `$HUGMESH_BIN_DIR` overrides it). **No sudo, ever.**

   | link | target |
   | --- | --- |
   | `hugmesh-studio` | `scripts/studio-launch.sh` |
   | `hugmesh-build-menu` | `scripts/build-menu.sh` |

   A foreign file or foreign symlink under one of these names is **never
   clobbered** — it is reported and left alone. A symlink that points at
   another (moved) hugmesh checkout's copy of the same script is retargeted so
   the command keeps working after a repo move. The name `hugmesh-mesh-node`
   is **reserved** and never created: it belongs to the end-user joiner
   appliance (`clients/docker-mesh-node/install.sh`), a different product
   surface — see the name-collision note in `scripts/hugmesh-mesh-node`.

2. **Properties** — a versioned `properties.json` in the existing Studio state
   dir (`~/.hugmesh/studio`, overridable via `$HUGMESH_STUDIO_STATE_DIR` like
   all other Studio state) recording the resolved paths so scripts stop
   re-deriving them: `generator_dir`, `python`, `venv`
   (`studio/.venv-studio` when present), `builder_image` (`$IMAGE`, default
   `hugmesh-builder` — the Makefile/build-menu convention), `bin_dir`, and the
   `links` written above. Shell scripts read single keys back with
   `first_run_property KEY`.

3. **Doctor** — fast self-tests, each one machine-greppable `DOCTOR` line plus
   a one-line hint. **Every failure is advisory; nothing here can block a
   launch:**

   - `venv` — importable / absent (the launcher offers one) / broken,
   - `git` — present or an install hint,
   - `builder_image` — present, or the one-liner `make docker-image`; with no
     docker CLI at all, a note that only `NATIVE=1` builds are possible,
   - `kvm` — available, or a degraded-mode note (QEMU boot tests fall back to
     slow TCG).

## Idempotence and forcing

A version stamp (`first-run.stamp` in the state dir) makes every rerun a
no-op costing one `cat` — python is never started again. Rerun it on demand:

```sh
./scripts/studio-launch.sh --redo-first-run     # any wired entry accepts it
HUGMESH_REDO_FIRST_RUN=1 make menu              # env form, for make targets
```

Bumping `FIRST_RUN_VERSION` (python) re-triggers the bootstrap for existing
installs on their next launch; `FIRST_RUN_LIB_VERSION` (shell) must match it.

## Direct invocation

The python half is a documented command of its own:

```sh
PYTHONPATH=studio python3 -m hugmesh_studio.core.first_run            # bootstrap
PYTHONPATH=studio python3 -m hugmesh_studio.core.first_run --doctor   # checks only, writes nothing
PYTHONPATH=studio python3 -m hugmesh_studio.core.first_run --print-properties
PYTHONPATH=studio python3 -m hugmesh_studio.core.first_run --redo-first-run
```

All human/advisory output rides **stderr** — stdout stays clean for the
automation channels.

## Tests

```sh
bash tests/scripts/test-first-run-lib.sh          # the shell half (hermetic; fake docker, tmp $HOME dirs)
PYTHONPATH=studio python3 -m pytest studio/tests/test_first_run.py    # the python half
```
