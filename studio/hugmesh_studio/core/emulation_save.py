"""Whole-mesh save — every live emulated device's disk PLUS its KEYS stick, one set.

Issue #50 item 10: "save everything done in the running emulated mesh back to the
devices' images/USBs — including the installer device images — so they can be
written to real hardware." This module is the Qt-free orchestrator for that: given
the running mesh's device list it drives one single-device save per device into ONE
clearly-named save-set directory, copies each device's provisioning USB payload
(the KEYS stick) in beside its disk, and writes a manifest that says what the set
holds and how consistent it is. The GUI and the ncurses menu are thin faces over
this module; ``make qemu-save-mesh`` is the CLI face.

NO NEW COPY MECHANISM — the landed single-device save is the only one
---------------------------------------------------------------------
Each disk goes through ``run-qemu-docker.sh --save-device`` via
``qemu_devices.device_save_argv`` — the primitive whose target rules are already
tested — because the two obvious "simpler" designs are known-broken (measured, see
the PAUSE AND SAVE header in tests/qemu/run-qemu-docker.sh):

* an external ``qemu-img`` CANNOT read a running device's disk at all — QEMU holds
  a write lock on the overlay AND the golden behind it, so it fails outright on the
  image lock, 100% of the time;
* ``block-commit`` silently MUTATES the golden build artifact and drops the overlay
  from the chain, poisoning every later run of that image. There is deliberately no
  code path for it here either.

So every save is what the landed mechanism produces: a STANDALONE qcow2 (no backing
file) holding the run overlay's delta merged over the golden's data —
crash-consistent, golden untouched.

WHAT "SAVING" MEANS FOR THE KEYS STICKS: COPY-BACK, NOT REGENERATE
------------------------------------------------------------------
The installer/USB-key image of an emulated device is the synthetic FAT32 KEYS disk
the harness fabricates per run (docker-entrypoint.sh golden mode: a throwaway login
keypair + users.json + provision.json packed by tests/qemu/make-test-keys.sh into
``<work>/runs/<label>/keys.img``). Saving one is a plain host-side COPY of the
run's exact payload, for two reasons that make "regenerate" the wrong verb:

* the KEYS disk is attached READ-ONLY (launch-pi.sh:264 ``readonly=on``), so the
  guest cannot have written anything to it — there is no in-guest delta to extract,
  and reading the file from the host collides with no lock;
* regenerating would mint a FRESH throwaway login key and users.json, but the
  accounts inside the saved disk were created at first boot against the ORIGINAL
  payload — a regenerated stick pairs a saved system with a private key that does
  not open it.

The saved disk, its KEYS payload and its login keypair are one consistent set, so
all three are copied side by side: ``<label>.keys/`` (the source dir a real stick
is written from — ``scripts/make-keys-usb.sh /dev/sdX <label>.keys``),
``<label>.keys.img`` (the packed FAT32 image QEMU attached), and
``<label>.id_ed25519``/``.pub`` (the key that logs into the saved system). A device
whose payload is gone (a cleaned run dir) keeps its DISK save and gets a keys
warning, never the other way round.

DUCK-TYPED INPUT — merges cleanly with the mesh-emulation planner
-----------------------------------------------------------------
``items`` may contain bare label strings, registry-shaped dicts, or any object with
a ``.label`` attribute (a planner row). Liveness fields (state/container/qmp) are
taken from the LIVE registry record when one exists — the registry is the runner's
own truth and a planner row may be stale — and from the item itself only when the
registry has no record. ``items=None`` means "every live device in the registry".

DISK-SPACE PREFLIGHT — refuse before the first device is paused
---------------------------------------------------------------
A save budgets the disk's FULL virtual size, not the delta: the copy is
``blockdev-backup sync=full`` and the goldens are allocated in full, so real saves
weigh 9.5–20.5 GB EACH. The runner preflights one device right before its copy; a
mesh save multiplies that by the fleet, so the SUM is checked against the target
filesystem here, before anything is paused or created, and the refusal names the
shortfall. Budgets mirror the launchers' overlay sizes: 16G (launch-pi.sh:49,
launch-arm.sh:48) and 32G for x86 (launch-x86.sh:44).
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass, field

from hugmesh_studio.core import qemu_devices as qd

GIB = 1024 ** 3

#: Per-device save budget = the overlay's FULL virtual size (sync=full copies every
#: allocated cluster and the goldens are allocated in full). The launchers own these
#: numbers: launch-pi.sh:49 / launch-arm.sh:48 OVERLAY_SIZE=16G, launch-x86.sh:44 32G.
ARM_BUDGET_BYTES = 16 * GIB
X86_BUDGET_BYTES = 32 * GIB

#: A mesh save-set directory is ``<work>/saves/<SESSION_PREFIX>-<stamp>/`` — inside
#: the same saves/ tree the single-device saves use (the only writable place the
#: runner accepts a target, and already on the operator's big filesystem), but one
#: directory per mesh save so the set reads as a unit and never interleaves with
#: single-device saves or an earlier set.
SESSION_PREFIX = "mesh"

#: The set's manifest — what was saved, from where, how consistent it is.
MANIFEST_NAME = "mesh-save.json"

#: Suffixes for the KEYS copy-back pieces, beside ``<label>.qcow2``.
KEYS_DIR_SUFFIX = ".keys"
KEYS_IMAGE_SUFFIX = ".keys.img"
LOGIN_KEY_SUFFIX = ".id_ed25519"

#: Recorded in the manifest so nobody has to re-derive it later (see the module
#: docstring for why regenerate is wrong).
KEYS_METHOD = "copy-back"

#: The injectable free-space probe (tests swap it; ``shutil.disk_usage`` in life).
_disk_usage = shutil.disk_usage


class MeshSaveError(RuntimeError):
    """A whole-mesh save refusal — raised BEFORE anything is paused or written."""


@dataclass
class DeviceSaveResult:
    """One device's outcome inside a mesh save-set."""
    label: str
    platform: str = ""
    role: str = ""
    target: str = ""                                  # the .qcow2 this device got
    argv: list[str] = field(default_factory=list)     # what was (or would be) run
    ok: bool = False
    error: str = ""                                   # blocker / runner failure
    keys_copied: list[str] = field(default_factory=list)
    keys_error: str = ""                              # warning; never flips ok


@dataclass
class MeshSaveReport:
    """What ``save_mesh`` did: the set's location and every device's outcome."""
    session: str
    session_dir: str
    work_dir: str
    results: list[DeviceSaveResult] = field(default_factory=list)
    manifest_path: str = ""

    @property
    def ok(self) -> bool:
        """True only when every requested device's DISK made it into the set."""
        return bool(self.results) and all(r.ok for r in self.results)

    @property
    def saved(self) -> list[DeviceSaveResult]:
        return [r for r in self.results if r.ok]

    @property
    def failed(self) -> list[DeviceSaveResult]:
        return [r for r in self.results if not r.ok]


def _utc_stamp() -> str:
    # timezone.utc, not datetime.UTC — the Studio supports 3.10 (same note as
    # qemu_devices._utc_stamp, which stays private to that module).
    return datetime.datetime.now(datetime.timezone.utc).strftime(qd.SAVE_STAMP_FORMAT)


def session_name(stamp: str = "") -> str:
    """``mesh-<stamp>`` — the save-set's name. ``stamp`` is injectable for tests
    and for a caller that wants a deterministic re-run; empty means "now"."""
    return f"{SESSION_PREFIX}-{(stamp or '').strip() or _utc_stamp()}"


def mesh_save_dir(work_dir: str, session: str) -> str:
    """The set's directory: ``<work>/saves/<session>/``."""
    return os.path.join(qd.saves_dir(work_dir), session)


def device_budget_bytes(dev: qd.Device) -> int:
    """The FULL virtual size this device's save is budgeted at (see module doc)."""
    if (dev.platform or "").strip().lower().startswith("x86"):
        return X86_BUDGET_BYTES
    return ARM_BUDGET_BYTES


def _label_of(item: object) -> str:
    if isinstance(item, str):
        return item.strip()
    if isinstance(item, dict):
        return str(item.get("label") or "").strip()
    return str(getattr(item, "label", "") or "").strip()


def _field_of(item: object, name: str) -> str:
    if isinstance(item, dict):
        return str(item.get(name) or "")
    return str(getattr(item, name, "") or "")


def _own_device(item: object, label: str) -> qd.Device | None:
    """A Device built from the item's OWN fields — the fallback when the registry
    has no record. All three liveness fields are required, because ``save_blocker``
    needs them and inventing any one of them would fabricate a saveable device out
    of a planner row that never claimed to be live."""
    state = _field_of(item, "state")
    container = _field_of(item, "container")
    qmp = _field_of(item, "qmp")
    if not (state and container and qmp):
        return None
    return qd.Device(label=label,
                     platform=_field_of(item, "platform"),
                     role=_field_of(item, "role"),
                     container=container,
                     ssh_key=_field_of(item, "ssh_key"),
                     qmp=qmp,
                     state=state)


def resolve_devices(work_dir: str, items=None) -> tuple[list[qd.Device],
                                                        list[DeviceSaveResult]]:
    """Coerce the duck-typed input into live Devices, in the caller's order.

    Returns ``(devices, unresolved)``: ``devices`` are addressable Devices (they may
    still be blocked — ``save_blocker`` is the next gate); ``unresolved`` are result
    rows for items no save could ever address, so they surface in the report instead
    of silently shrinking the fleet. Duplicate labels are folded to the first
    occurrence — one device, one save.

    The registry record WINS over the item's own fields when both exist: the
    registry is rewritten by the runner as state advances, so it is the truth about
    liveness, and a stale planner row must not talk this module into pausing a
    device that is no longer there (or skipping one that is).
    """
    registry = qd.discover_devices(work_dir)
    if items is None:
        return list(registry), []
    by_label = {d.label: d for d in registry}
    devices: list[qd.Device] = []
    unresolved: list[DeviceSaveResult] = []
    seen: set[str] = set()
    for item in items:
        label = _label_of(item)
        if not label:
            unresolved.append(DeviceSaveResult(
                label=repr(item),
                error="item carries no device label, so no save can address it"))
            continue
        if label in seen:
            continue
        seen.add(label)
        dev = by_label.get(label) or _own_device(item, label)
        if dev is None:
            unresolved.append(DeviceSaveResult(
                label=label,
                error=(f"{label} has no record in the live device registry under "
                       f"{qd.devices_dir(work_dir)} and the row itself carries no "
                       "liveness fields (state/container/qmp) — is the mesh "
                       "running with --keep-alive?")))
            continue
        devices.append(dev)
    return devices, unresolved


def free_bytes_for(path: str, disk_usage=None) -> int:
    """Free bytes on the filesystem that will hold ``path``; -1 when unknowable.

    Walks up to the nearest EXISTING ancestor because the save-set dir does not
    exist yet at preflight time — that is the point of the preflight. -1 (an
    unreadable filesystem) deliberately does not refuse: the runner re-checks each
    device right before its copy, so an unknowable answer here degrades to the
    landed per-device check rather than blocking a save that would have fit.
    """
    probe = path
    while probe and not os.path.exists(probe):
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    try:
        return int((disk_usage or _disk_usage)(probe).free)
    except OSError:
        return -1


def preflight_refusal(devices: list[qd.Device], target_dir: str, *,
                      budget_bytes: int = 0, disk_usage=None) -> str:
    """Why this fleet cannot be saved under ``target_dir``, or "" when it fits.

    Checked BEFORE the first device is paused, because running out mid-fleet is the
    worst shape of failure: earlier devices' multi-GB saves already landed, the
    current one leaves a giant ``.partial``, and on this workstation a full
    filesystem has taken the live mesh's own volumes down with it. Text, not bool,
    so the CLI/GUI can show the shortfall by name.
    """
    if not devices:
        return ""
    budgets = [budget_bytes if budget_bytes > 0 else device_budget_bytes(d)
               for d in devices]
    needed = sum(budgets)
    free = free_bytes_for(target_dir, disk_usage)
    if free < 0 or free >= needed:
        return ""
    short = needed - free
    return (f"not enough space under {target_dir} for this mesh save: "
            f"{len(devices)} device disk(s) budget {needed} bytes "
            f"({needed / GIB:.1f} GiB — a save is each disk's FULL virtual size, "
            f"not what the guest wrote), but only {free} bytes "
            f"({free / GIB:.1f} GiB) are free — {short} bytes "
            f"({short / GIB:.1f} GiB) short. Free space, save fewer devices "
            "(--only), or point --work at a bigger filesystem.")


def _keys_pairs(work_dir: str, dev: qd.Device) -> list[tuple[str, str, str]]:
    """``(source, dest_basename, kind)`` for every piece of this device's KEYS set.

    Sources live in the run dir the entrypoint fabricated them in
    (``<work>/runs/<safe>/``); the login key prefers the registry's ``ssh_key``
    because that field is the HOST path the entrypoint already resolved.
    """
    safe = qd.safe_label(dev.label)
    run_dir = os.path.join(work_dir, qd.RUNS_SUBDIR, safe)
    ssh_key = dev.ssh_key or os.path.join(run_dir, "id_ed25519")
    return [
        (os.path.join(run_dir, "keys"), safe + KEYS_DIR_SUFFIX, "dir"),
        (os.path.join(run_dir, "keys.img"), safe + KEYS_IMAGE_SUFFIX, "file"),
        (ssh_key, safe + LOGIN_KEY_SUFFIX, "key"),
        (ssh_key + ".pub", safe + LOGIN_KEY_SUFFIX + ".pub", "file"),
    ]


def _copy_keys(work_dir: str, dev: qd.Device, dest_dir: str) -> tuple[list[str], str]:
    """Copy-back of one device's KEYS set. Returns ``(copied_paths, warning)``.

    A missing piece is a WARNING, never a failure of the disk save it rides along
    with — the disk is the expensive, unrepeatable part. The private key copy is
    chmodded 0600 so ssh will actually accept it later.
    """
    copied: list[str] = []
    missing: list[str] = []
    for src, dest_name, kind in _keys_pairs(work_dir, dev):
        dest = os.path.join(dest_dir, dest_name)
        try:
            if kind == "dir":
                if not os.path.isdir(src):
                    missing.append(src)
                    continue
                shutil.copytree(src, dest, dirs_exist_ok=True)
            else:
                if not os.path.isfile(src):
                    missing.append(src)
                    continue
                shutil.copy2(src, dest)
                if kind == "key":
                    os.chmod(dest, 0o600)
            copied.append(dest)
        except OSError as exc:
            return copied, f"could not copy {src} -> {dest}: {exc}"
    if not copied:
        return copied, (f"no KEYS payload found for {dev.label} under "
                        f"{os.path.join(work_dir, qd.RUNS_SUBDIR, qd.safe_label(dev.label))}"
                        " — the disk save stands, but there is no stick to write "
                        "for it")
    if missing:
        return copied, "KEYS pieces missing (the rest were copied): " + ", ".join(missing)
    return copied, ""


def _save_argv(generator_dir: str, work_dir: str, dev: qd.Device, target: str,
               overwrite: bool) -> list[str]:
    """The landed primitive's argv, plus ``--work`` when the caller overrode it.

    ``device_save_argv`` deliberately never emits ``--work`` (the GUI always uses
    the default work dir), but the runner resolves BOTH the device registry and the
    "target must be under the work dir" rule against ITS work dir — so a mesh save
    into a custom ``--work`` must say so or the runner refuses its own target.
    """
    argv = qd.device_save_argv(generator_dir, dev, target,
                               overwrite=overwrite, work_dir=work_dir)
    if os.path.realpath(work_dir) != os.path.realpath(qd.default_work_dir(generator_dir)):
        argv[1:1] = ["--work", work_dir]
    return argv


def _run_argv(argv: list[str]) -> int:
    """Execute one runner invocation, streaming its output. The injectable seam:
    tests swap this for a spy, exactly like the GUI swaps in its process runner."""
    try:
        return subprocess.call(argv)
    except OSError as exc:
        print(f"could not run {argv[0]}: {exc}", file=sys.stderr)
        return 127


def plan_mesh_save(generator_dir: str, items=None, *, work_dir: str = "",
                   session: str = "", stamp: str = "", overwrite: bool = False,
                   budget_bytes: int = 0, disk_usage=None) -> dict:
    """The confirm-before-run manifest: what a mesh save WOULD do. Pure — nothing
    is created, paused or copied (same contract as local_mesh_bootstrap's plan)."""
    work = work_dir or qd.default_work_dir(generator_dir)
    name = session or session_name(stamp)
    sdir = mesh_save_dir(work, name)
    devices, unresolved = resolve_devices(work, items)
    rows = []
    savable: list[qd.Device] = []
    for dev in devices:
        blocker = qd.save_blocker(dev)
        target = os.path.join(sdir, qd.save_basename(dev.label))
        row = {
            "label": dev.label,
            "platform": dev.platform,
            "role": dev.role,
            "state": dev.state,
            "target": target,
            "blocker": blocker,
            "budget_bytes": (budget_bytes if budget_bytes > 0
                             else device_budget_bytes(dev)),
            "keys": [{"source": src, "dest": os.path.join(sdir, dest),
                      "exists": (os.path.isdir(src) if kind == "dir"
                                 else os.path.isfile(src))}
                     for src, dest, kind in _keys_pairs(work, dev)],
        }
        if not blocker:
            savable.append(dev)
            row["argv"] = _save_argv(generator_dir, work, dev, target, overwrite)
        rows.append(row)
    needed = sum(r["budget_bytes"] for r in rows if not r["blocker"])
    return {
        "session": name,
        "session_dir": sdir,
        "work_dir": work,
        "devices": rows,
        "unresolved": [{"label": r.label, "error": r.error} for r in unresolved],
        "needed_bytes": needed,
        "free_bytes": free_bytes_for(sdir, disk_usage),
        "refusal": preflight_refusal(savable, sdir, budget_bytes=budget_bytes,
                                     disk_usage=disk_usage),
    }


def save_mesh(generator_dir: str, items=None, *, work_dir: str = "",
              session: str = "", stamp: str = "", overwrite: bool = False,
              budget_bytes: int = 0, run=None, disk_usage=None) -> MeshSaveReport:
    """Save every requested device's disk + KEYS set into ONE save-set directory.

    Orchestration rules, each of which a test pins:

    * devices are saved in the CALLER'S order (the planner's order is the mesh's
      bring-up order, and pki-before-workers is meaningful);
    * the preflight refusal (``MeshSaveError``) fires before anything is paused,
      created or copied;
    * one device's failure never touches another's save: the runner already
      quarantines its own partial as ``<target>.partial``, and this loop records
      the failure and CARRIES ON, so a mesh save degrades to "all but the broken
      one" rather than to nothing;
    * a blocked or unresolved device costs a report row, never an exception —
      "save everything" must save everything that exists to be saved.

    ``run`` is the process seam (argv -> returncode); default runs the runner
    for real. The report's ``ok`` is strict: True only when EVERY requested
    device's disk landed.
    """
    work = work_dir or qd.default_work_dir(generator_dir)
    name = session or session_name(stamp)
    sdir = mesh_save_dir(work, name)
    devices, unresolved = resolve_devices(work, items)
    results: list[DeviceSaveResult] = []

    savable = [d for d in devices if not qd.save_blocker(d)]
    refusal = preflight_refusal(savable, sdir, budget_bytes=budget_bytes,
                                disk_usage=disk_usage)
    if refusal:
        raise MeshSaveError(refusal)

    if savable:
        # Host-side, BEFORE root writes into it — the same ordering the runner
        # uses for ${SAVES_DIR} itself, and the runner's qemu-img create does not
        # make parents.
        os.makedirs(sdir, exist_ok=True)

    executor = run or _run_argv
    for dev in devices:
        res = DeviceSaveResult(label=dev.label, platform=dev.platform,
                               role=dev.role)
        results.append(res)
        blocker = qd.save_blocker(dev)
        if blocker:
            res.error = blocker
            continue
        res.target = os.path.join(sdir, qd.save_basename(dev.label))
        try:
            res.argv = _save_argv(generator_dir, work, dev, res.target, overwrite)
        except ValueError as exc:            # refused target / unarmed overwrite
            res.error = str(exc)
            continue
        rc = executor(res.argv)
        if rc != 0:
            res.error = (f"run-qemu-docker.sh exited {rc} saving {dev.label}; any "
                         f"partial copy was quarantined by the runner as "
                         f"{res.target}.partial and must not be trusted")
            continue
        res.ok = True
        res.keys_copied, res.keys_error = _copy_keys(work, dev, sdir)

    results.extend(unresolved)
    report = MeshSaveReport(session=name, session_dir=sdir, work_dir=work,
                            results=results)
    if savable:
        report.manifest_path = _write_manifest(generator_dir, report)
    return report


def _write_manifest(generator_dir: str, report: MeshSaveReport) -> str:
    """``mesh-save.json`` in the set dir — written atomically (a lister may be
    reading), and written even when some devices failed, because a half-successful
    set is exactly the one whose contents need saying out loud."""
    path = os.path.join(report.session_dir, MANIFEST_NAME)
    rec = {
        "session": report.session,
        "session_dir": report.session_dir,
        "generator_dir": generator_dir,
        "work_dir": report.work_dir,
        "created_at": datetime.datetime.now(datetime.timezone.utc)
                              .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ok": report.ok,
        "consistency": "crash-consistent",     # QMP stop == pulled plug; the
                                               # per-save sidecars say the same
        "keys_method": KEYS_METHOD,
        "keys_method_reason": ("the KEYS disk is attached read-only, so the run's "
                               "exact payload is copied back; regenerating would "
                               "mint a login key the saved disks were never "
                               "provisioned with"),
        "write_to_hardware": {
            "disk": ("qemu-img convert -O raw <label>.qcow2 <label>.img, then "
                     "write the .img like any built image (scripts/flash-disk.sh "
                     "or dd)"),
            "keys": ("sudo scripts/make-keys-usb.sh /dev/sdX <label>.keys "
                     "(the .keys.img is the same payload already packed as FAT32)"),
        },
        "devices": [{
            "label": r.label,
            "platform": r.platform,
            "role": r.role,
            "target": r.target,
            "ok": r.ok,
            "error": r.error,
            "keys_copied": r.keys_copied,
            "keys_error": r.keys_error,
        } for r in report.results],
    }
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
    return path


# ── CLI ──────────────────────────────────────────────────────────────────────────
# The same subcommand shape as core/local_mesh_bootstrap and core/cloud_deploy:
# `plan` previews (pure), `save` acts. The Makefile face is qemu-save-mesh[-plan].

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))


def _filtered_items(work: str, only: list[str]):
    """None (= the whole registry) without filters; else the matching labels.
    Substring match on ``<platform>/<role>``, the same rule as the runner's
    ``--only``, so the two spell filters identically."""
    if not only:
        return None
    labels = [d.label for d in qd.discover_devices(work)]
    return [lb for lb in labels if any(f in lb for f in only)]


def _print_plan(plan: dict) -> None:
    print(f"mesh save-set : {plan['session']}")
    print(f"  directory   : {plan['session_dir']}")
    print(f"  work dir    : {plan['work_dir']}")
    for row in plan["devices"]:
        state = row["blocker"] or f"save -> {row['target']}"
        print(f"  {row['label']:<24} [{row['state'] or 'unknown'}] {state}")
        if not row["blocker"]:
            print(f"    budget    : {row['budget_bytes'] / GIB:.1f} GiB (full "
                  "virtual size)")
            for piece in row["keys"]:
                mark = "ok" if piece["exists"] else "MISSING"
                print(f"    keys {mark:<7}: {piece['source']}")
            print(f"    argv      : {' '.join(shlex.quote(a) for a in row['argv'])}")
    for row in plan["unresolved"]:
        print(f"  {row['label']:<24} UNRESOLVED: {row['error']}")
    needed, free = plan["needed_bytes"], plan["free_bytes"]
    print(f"  needs       : {needed / GIB:.1f} GiB "
          f"(free: {'unknown' if free < 0 else f'{free / GIB:.1f} GiB'})")
    if plan["refusal"]:
        print(f"  REFUSAL     : {plan['refusal']}")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="python -m hugmesh_studio.core.emulation_save",
        description=("Save a running emulated mesh — every live device's disk plus "
                     "its KEYS stick payload — into one flashable save-set under "
                     "<work>/saves/. `plan` previews (nothing runs); `save` pauses "
                     "each device in turn through run-qemu-docker.sh --save-device "
                     "and copies its KEYS payload back beside the disk."))
    p.add_argument("subcommand", choices=("plan", "save"),
                   help="plan: preview the set + disk budget; save: do it")
    p.add_argument("--generator-dir", default=_REPO_ROOT,
                   help="the hugmesh-generator checkout (default: this one)")
    p.add_argument("--work", default="",
                   help="the runner --work dir the mesh is running in "
                        "(default: <generator>/out/qemu-runs)")
    p.add_argument("--session", default="",
                   help="save-set name (default: mesh-<UTC stamp>)")
    p.add_argument("--only", action="append", default=[], metavar="FILTER",
                   help="substring filter on <platform>/<role>; repeatable "
                        "(same rule as run-qemu-docker.sh --only)")
    p.add_argument("--overwrite", action="store_true",
                   help="allow replacing files an earlier run of the SAME "
                        "--session already wrote (never the golden images)")
    p.add_argument("--budget-gib", type=int, default=0, metavar="N",
                   help="override the per-device disk budget (default: the "
                        "overlay's virtual size — 16 GiB, 32 GiB for x86)")
    args = p.parse_args(argv)

    work = args.work or qd.default_work_dir(args.generator_dir)
    items = _filtered_items(work, args.only)
    if items is not None and not items:
        print(f"no live device label matches {args.only} under "
              f"{qd.devices_dir(work)} — nothing to save", file=sys.stderr)
        return 1
    budget = args.budget_gib * GIB

    if args.subcommand == "plan":
        plan = plan_mesh_save(args.generator_dir, items, work_dir=work,
                              session=args.session, overwrite=args.overwrite,
                              budget_bytes=budget)
        _print_plan(plan)
        if not any(not row["blocker"] for row in plan["devices"]):
            print("nothing is saveable: no live device in the registry "
                  "(--keep-alive mesh running?)", file=sys.stderr)
            return 1
        return 1 if plan["refusal"] else 0

    try:
        report = save_mesh(args.generator_dir, items, work_dir=work,
                           session=args.session, overwrite=args.overwrite,
                           budget_bytes=budget)
    except MeshSaveError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 1
    for res in report.results:
        if res.ok:
            print(f"  saved {res.label} -> {res.target}")
            if res.keys_error:
                print(f"    keys warning: {res.keys_error}")
            for piece in res.keys_copied:
                print(f"    keys: {piece}")
        else:
            print(f"  FAILED {res.label}: {res.error}", file=sys.stderr)
    if report.manifest_path:
        print(f"  manifest: {report.manifest_path}")
    if not report.results:
        print("no devices to save (registry empty and nothing requested)",
              file=sys.stderr)
        return 1
    return 0 if report.ok else 1


if __name__ == "__main__":
    sys.exit(main())
