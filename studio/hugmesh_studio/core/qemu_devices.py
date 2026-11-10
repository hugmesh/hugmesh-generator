"""Live emulated devices — reading the keep-alive registry and building the argv that
puts an operator on a shell inside a running QEMU guest (Qt-free).

Sibling of core/qemu_tests.py, and deliberately the OTHER half of it. That module
drives a matrix run to COMPLETION: docker-entrypoint.sh boots a row, asserts, powers
the guest off and the container exits. That shape can never offer a terminal button —
by the time a result JSON exists there is no guest left to log into. The runner's
``--keep-alive`` mode is what makes this module possible: the guest stays up, its ssh
port is published, and the entrypoint writes one record per LIVE device under
``<work>/devices/``.

WHAT THIS MODULE OWNS vs WHAT THE SHELL OWNS
--------------------------------------------
The shell keeps owning every lifecycle action, exactly as in qemu_tests.py: booting,
publishing a port, stopping a container and talking QMP all happen in
tests/qemu/run-qemu-docker.sh. This module only READS the registry the entrypoint
writes and BUILDS argv for the GUI to spawn. Nothing here shells out, opens a socket
or touches docker, so every rule below is unit-testable hermetically (see
tests/test_qemu_devices.py) — no docker, no qemu, no ssh.

WHY THE REGISTRY CARRIES HOST PATHS
-----------------------------------
The key and the QMP socket are written by a process living inside the container,
where the bind mount is ``/work``. The Studio runs on the HOST, where the same bytes
are at e.g. ``<generator>/out/qemu-runs``. A container path handed to the host's
``ssh -i`` simply does not exist, so the entrypoint resolves both through HOST_WORK
before writing them and this module uses them verbatim — it must not "helpfully"
rewrite paths, because it cannot know the mount mapping of a run it did not start.

WHY THERE IS NO "log in as root" PATH
-------------------------------------
The guest's sshd sets ``PermitRootLogin no`` and tests/qemu/assertions.sh asserts
that. Handing the operator a root ssh would mean weakening the very thing the harness
tests. "Superuser" is therefore a wheel login plus ``sudo -i`` — which is also what
the operator would do on real hardware, so the button teaches the right habit.

PAUSE-AND-SAVE: WHICH SAVE IS EVEN EXPRESSIBLE
----------------------------------------------
A live device's disk is a per-run qcow2 overlay whose backing file is the golden
build image (tests/qemu/launch-pi.sh:193 ``OVERLAY="${RUN_DIR}/run.qcow2"``, resized
to ``OVERLAY_SIZE`` = 16G at launch-pi.sh:49). That shape rules out most of the
obvious designs, so the save rules below are narrow ON PURPOSE:

* A host-side image tool cannot copy a live device AT ALL: QEMU holds the overlay,
  and an attempt to read or rewrite it fails on the image lock (measured on qemu
  10.2.3 — ``Failed to get "write" lock`` / ``Failed to get shared "write" lock``).
  The golden backing file is write-locked too for as long as a guest device is
  attached to the chain. So "pause the guest, then run a tool over its disk" is not
  a design that exists; every save goes through the RUNNING QEMU — pause, block job,
  restore the prior run state — which is why this module never names an image tool
  in an argv and only asks the runner, which owns the QMP socket, to do it.
* Committing the overlay DOWN into its backing file would rewrite the golden build
  artifact that every other run and every other session boots from, and drop the
  overlay out of the chain so later guest writes land on that artifact directly.
  There is deliberately no function here that can express it, and ``QMP_COMMANDS``
  (the tuple the GUI builds its buttons from) contains no commit verb.
* So a save is a COPY: a standalone qcow2 holding the overlay's delta merged over
  the golden's data. "Another copy" is a fresh path (``new_save_target``);
  "overwrite the existing copy" is the stable per-device path
  (``default_save_target``) written again — the previously SAVED copy is what gets
  replaced, never the golden image, which ``save_target_refusal`` refuses outright.

``new_save_target`` and ``save_would_overwrite`` stat the filesystem, exactly as
``discover_devices`` reads it; that is still hermetic in the sense this module cares
about (no docker, no qemu, no sockets, no subprocess) and it is what makes "without
clobbering" a guarantee rather than a hope.
"""
from __future__ import annotations

import datetime
import json
import os
import shlex
import shutil
import tempfile
from dataclasses import dataclass, field

# ONE terminal list for the whole app. cloud_deploy.py already picked this order
# (most-specific first) and pairs each binary with its exec-style flag, because
# gnome-terminal/kitty want "--", xfce4-terminal wants "-x" and foot wants neither.
# A second copy would drift the day someone adds a terminal to only one of them.
from hugmesh_studio.core.cloud_deploy import TERMINALS
# The runner path lives in qemu_tests so the two device-facing modules can never
# disagree about which script they drive. SESSIONS_SUBDIR comes from the same place
# for the same reason: the save refusal below has to know where golden build images
# live, and a second spelling of "out/sessions" would go stale the day the builders move.
from hugmesh_studio.core.qemu_tests import (DEFAULT_WORK_SUBDIR, RUNNER_SCRIPT,
                                            SESSIONS_SUBDIR)

#: The SPICE viewers ``display_argv`` can open, most-preferred first — kept here,
#: beside the TERMINALS import, for the same reason that list is imported rather
#: than copied: ONE place decides the order. (cloud_deploy.py is where TERMINALS
#: lives, but it has no display to open, so the list stays with the module that
#: builds the argv.) Each entry is ``(binary, auto_pick)``:
#:
#: * ``remote-viewer`` (virt-viewer) takes a ``.vv`` connection file — the password
#:   rides a 0600 file that deletes itself, never argv — and sends a monitors-config
#:   when its window is resized, so a guest that can follow it re-lays out.
#: * ``spicy`` (spice-gtk's demo client) resizes the same way but takes the password
#:   on argv (``-w``) or prompts for it. It is never auto-picked: a secret on argv is
#:   a secret in ``ps``. Asked for explicitly it is spelled WITHOUT ``-w`` and prompts.
VIEWERS = (
    ("remote-viewer", True),
    ("spicy", False),
)

#: How a browser gets opened on the noVNC fallback, first match wins. ``xdg-open``
#: is the Linux desktop's; ``open`` is macOS; ``cmd /c start`` is a native Windows
#: Studio. Each entry is the whole argv prefix the URL is appended to.
BROWSER_OPENERS = (
    ("xdg-open",),
    ("open",),
    ("cmd", "/c", "start", ""),
)

#: Where docker-entrypoint.sh writes one JSON record per live device, under the
#: runner's ``--work`` dir (the same dir that already holds runs/ and results/).
DEVICES_SUBDIR = "devices"

#: Guest ssh is published to LOOPBACK ONLY by the runner, so the whole GUI talks to
#: 127.0.0.1 and an emulated device is never reachable off the workstation.
SSH_HOST = "127.0.0.1"

#: Host-key checking is off on purpose: a device's key is regenerated on every fresh
#: boot of the same disposable overlay, so a persisted known_hosts entry would turn
#: into a MITM warning that blocks login. /dev/null keeps the operator's real
#: ~/.ssh/known_hosts untouched — these are throwaway guests on loopback.
SSH_OPTIONS = ("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null")

#: Root shell via wheel + sudo (see the module docstring: root ssh stays disabled).
SUPERUSER_COMMAND = "sudo -i"

#: The display door is published to LOOPBACK ONLY, like ssh (the runner's
#: ``docker -p 127.0.0.1:P:5930``). An IP LITERAL on purpose, never ``localhost``:
#: the gateway pins HSTS on ``localhost`` and a self-signed cert turns that into a
#: non-bypassable Chrome block, while HSTS cannot apply to an IP literal — so the
#: noVNC fallback URL below can never be caught by that pin.
DISPLAY_HOST = "127.0.0.1"

#: The only display protocol this module can open. A record saying anything else
#: (or nothing) has no door this module knows how to reach.
DISPLAY_PROTOCOL_SPICE = "spice"

#: ``Device.display_resize`` values: what the GUEST is known to do when the viewer
#: window changes size. "guest" = the desktop re-lays out at the new resolution;
#: "scale" (and "", the conservative default) = the viewer scales the bitmap to fit.
DISPLAY_RESIZE_GUEST = "guest"
DISPLAY_RESIZE_SCALE = "scale"

#: ``display_argv``'s ``viewer`` spellings. "auto" tries ``VIEWERS`` in order (the
#: auto-pickable ones), then the browser fallback, then gives up with a hint.
DISPLAY_VIEWERS = ("auto", "remote-viewer", "spicy", "browser")

#: What to install when no viewer exists at all. Named per platform because the
#: Studio runs on Gentoo, Debian-family desktops and inside WSL2 (where the Windows
#: build of virt-viewer can open the same ``.vv`` file through the localhost forward).
VIEWER_INSTALL_HINT = ("Install a SPICE viewer: Gentoo `emerge net-misc/virt-viewer`, "
                       "Debian/Ubuntu `apt install virt-viewer`, Windows: the virt-viewer "
                       "MSI (remote-viewer.exe) from virt-manager.org.")

#: QMP verbs the runner accepts for ``--qmp LABEL CMD``. The GUI should build its
#: buttons FROM this tuple rather than hardcoding strings, so adding a verb is a
#: one-line change in one place.
QMP_COMMANDS = ("pause", "resume", "reset", "powerdown", "status")

#: Lifecycle actions ``device_control_argv`` can express. "start" was REMOVED (T2):
#: a per-device start must pin --artifacts and --work and address its row with
#: --only-exact, and the single author of that argv is core.emulation.
#: start_device_argv — the old spelling here booted whatever session the runner
#: guessed newest, filtered by substring.
DEVICE_ACTIONS = ("stop",)

#: A record whose state is one of these describes a device that is no longer there.
#: "" is included because a truncated/never-updated record must not be offered as a
#: live login target.
_DEAD_STATES = ("stopped", "")

#: Where a saved copy of a device's disk lands, under the runner's ``--work`` dir —
#: i.e. beside runs/, results/ and devices/, in the tree the harness already fills
#: with multi-GB images. That tree is on the operator's big filesystem by
#: construction (qemu_tests.DEFAULT_WORK_SUBDIR = ``out/qemu-runs`` inside the
#: generator checkout); the root filesystem on this workstation has hit 100% before,
#: and a 16G-virtual-disk save is not the thing to point at it.
SAVES_SUBDIR = "saves"

#: The live per-device run dir, i.e. the qcow2 overlay QEMU currently has OPEN
#: (docker-entrypoint.sh:187 ``RUN_DIR="${WORK}/runs/<safe label>"``). Named here for
#: exactly one purpose: refusing a save target that points into it.
RUNS_SUBDIR = "runs"

#: A save is always qcow2, never raw. A qcow2 costs what the guest actually
#: allocated and keeps costing that through any later copy of the file. A raw save of
#: the same disk IS the full virtual size — 16G per device (launch-pi.sh:49) — in
#: every listing, and stays smaller than that only for as long as the filesystem
#: holds it sparse and no tool that touches it forgets to.
SAVE_SUFFIX = ".qcow2"

#: ``YYYYmmddTHHMMSSZ`` — the same stamp shape build artifacts carry
#: (qemu_tests.artifact_stamp), so a saves/ listing reads like the sessions listing
#: next to it. run-qemu-docker.sh's own default save name uses this same spelling;
#: they were allowed to diverge once ('-' sorts before 'T', so a directory holding
#: both orders wrongly by name) and ``saved_copies`` now orders by mtime so that a
#: directory left over from that period still reads correctly.
SAVE_STAMP_FORMAT = "%Y%m%dT%H%M%SZ"

#: The two things the operator asked for, and the only two spellings ``save_argv``
#: accepts. "copy" is always safe; "overwrite" always replaces an existing save.
SAVE_MODES = ("copy", "overwrite")


@dataclass
class Device:
    """One LIVE emulated device, as recorded by docker-entrypoint.sh --keep-alive.

    Field-for-field the registry JSON (the cross-layer data contract). Every path is
    a HOST path; ``ssh_host_port`` is 0 when the container published no port, which
    means "no login possible", never "use the default port" — see ``ssh_argv``.
    """
    label: str = ""                                  # "rpi5/pki"
    platform: str = ""
    role: str = ""
    board: str = ""
    container: str = ""                              # docker container name
    ssh_host_port: int = 0                           # host-side port; 0 = unpublished
    ssh_user: str = ""                               # the always-present wheel user
    ssh_key: str = ""                                # HOST path to the private key
    users: list[str] = field(default_factory=list)   # logins that EXIST on the guest
    qmp: str = ""                                    # HOST path to the QMP socket
    state: str = ""                                  # booting|running|assertions|stopped
    started_at: str = ""                             # UTC ISO-8601, "…Z"
    #: The per-device START contract (records written since 2026-08-19): together
    #: with ``label`` these are everything a restarter needs —
    #: ``run-qemu-docker.sh --artifacts <artifacts> --only-exact <label>``.
    #: Both read TOLERANTLY: an older record simply has neither, and a restart
    #: from it must then be given a session explicitly (emulation.start_device_argv
    #: refuses to fall back to the runner's newest-session guess).
    artifacts: str = ""                              # HOST path to the artifacts dir
    image: str = ""                                  # basename of the booted image
    #: The graphical DISPLAY door (records written by a display-mode keep-alive run):
    #: SPICE on host loopback, protected by a per-run secret. All TOLERANT — a record
    #: from a serial-only run (or an older writer) has none of them, and the display
    #: button is then simply disabled with a reason (``display_blocker``).
    display_protocol: str = ""                       # "spice" or ""
    display_port: int = 0                            # host port on 127.0.0.1; 0 = no door
    display_web_port: int = 0                        # noVNC host port on 127.0.0.1; 0 = none
    display_password_file: str = ""                  # HOST path to the secret, NEVER the value
    display_resize: str = ""                         # "guest" | "scale" — what this image does
    #: BOOT FROM A SAVE (records written since 2026-11-09): the HOST path of the
    #: standalone save this device was booted from (run-qemu-docker.sh --boot-save),
    #: "" for a device booted from its golden image. TOLERANT like the fields above —
    #: an older record has none and reads as a golden boot, which is what it was.
    #: The save itself is never written (the run overlay sits over it), so this path
    #: still holds exactly what was saved, whatever the device has done since.
    boot_save: str = ""

    @property
    def is_running(self) -> bool:
        return self.state not in _DEAD_STATES

    @property
    def resumed_from_save(self) -> bool:
        """True when this device booted from a save rather than its golden image —
        so whatever posture the save carried (a go-live flip, a provisioned cluster)
        is on the disk again, instead of the golden's first-boot INTERNAL state."""
        return bool(self.boot_save)


def devices_dir(work_dir: str) -> str:
    """The registry directory inside a runner ``--work`` dir."""
    return os.path.join(work_dir, DEVICES_SUBDIR)


def _device_from_record(raw: object) -> Device | None:
    """One parsed JSON record -> Device, or None if it cannot be addressed.

    A record with no label is dropped rather than shown: every action this module
    can build (``--stop-device LABEL``, ``--qmp LABEL CMD``, ``--only LABEL``)
    addresses a device BY LABEL, so a nameless row is a button that cannot do
    anything. Everything else is best-effort — an older or newer writer that adds
    keys, or omits an optional one, still yields a usable row.
    """
    if not isinstance(raw, dict):
        return None
    label = str(raw.get("label") or "").strip()
    if not label:
        return None
    users = [str(u) for u in raw.get("users") or [] if str(u).strip()]
    try:
        port = int(raw.get("ssh_host_port") or 0)
    except (TypeError, ValueError):
        port = 0
    try:
        display_port = int(raw.get("display_port") or 0)
    except (TypeError, ValueError):
        display_port = 0
    try:
        display_web_port = int(raw.get("display_web_port") or 0)
    except (TypeError, ValueError):
        display_web_port = 0
    return Device(
        label=label,
        platform=str(raw.get("platform") or ""),
        role=str(raw.get("role") or ""),
        board=str(raw.get("board") or ""),
        container=str(raw.get("container") or ""),
        ssh_host_port=port,
        ssh_user=str(raw.get("ssh_user") or ""),
        ssh_key=str(raw.get("ssh_key") or ""),
        users=users,
        qmp=str(raw.get("qmp") or ""),
        state=str(raw.get("state") or ""),
        started_at=str(raw.get("started_at") or ""),
        artifacts=str(raw.get("artifacts") or ""),
        image=str(raw.get("image") or ""),
        display_protocol=str(raw.get("display_protocol") or ""),
        display_port=display_port,
        display_web_port=display_web_port,
        display_password_file=str(raw.get("display_password_file") or ""),
        display_resize=str(raw.get("display_resize") or ""),
        boot_save=str(raw.get("boot_save") or ""),
    )


def device_from_record(raw: object) -> Device | None:
    """Public spelling of the record->Device rule, for readers that obtained the
    JSON some other way — core.emulation feeds it the runner's ``--devices``
    output, which is these same records reconciled against docker ps. One parsing
    rule, whoever fetched the bytes."""
    return _device_from_record(raw)


def discover_devices(work_dir: str) -> list[Device]:
    """Every device in ``<work_dir>/devices/``, newest first.

    Corrupt files are SKIPPED, not raised on, and that is a live-data requirement
    rather than defensiveness: the entrypoint writes a record as soon as the guest
    answers ssh and REWRITES it as the state advances (booting -> running ->
    assertions -> stopped), so a GUI polling this directory will sooner or later
    read a file mid-write. One half-written record must cost one row, never the
    whole device list.

    Newest first is by ``started_at`` (UTC ``YYYY-mm-ddTHH:MM:SSZ``, so a plain
    string compare is chronological — the same property qemu_tests relies on for
    artifact stamps), with the file mtime as the tie-break for records written in
    the same second, and label order under that so the list never reshuffles
    between two polls of an unchanged directory.
    """
    root = devices_dir(work_dir)
    if not os.path.isdir(root):
        return []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return []

    found: list[tuple[float, Device]] = []
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(root, name)
        try:
            with open(path, encoding="utf-8") as fh:
                raw = json.load(fh)
        except (OSError, ValueError):
            continue
        dev = _device_from_record(raw)
        if dev is None:
            continue
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            mtime = 0.0
        found.append((mtime, dev))

    found.sort(key=lambda pair: pair[1].label)                 # stable base order
    found.sort(key=lambda pair: (pair[1].started_at, pair[0]), reverse=True)
    return [dev for _mtime, dev in found]


def device_by_label(devices: list[Device], label: str) -> Device | None:
    """The device with this label, or None — the GUI's dropdown-selection lookup."""
    for dev in devices:
        if dev.label == label:
            return dev
    return None


def ssh_argv(dev: Device, user: str, *, superuser: bool = False) -> list[str]:
    """argv for a shell on ``dev`` as ``user``; with ``superuser`` it becomes root.

    ``-t`` forces a pty because ``sudo -i`` needs one (without it sudo cannot prompt
    and the login shell has no terminal). Both trailing arguments come AFTER the
    destination, which OpenSSH on Linux parses fine — glibc's getopt permutes, so
    ``-t`` is still read as an option and the single ``"sudo -i"`` element is the
    remote command.

    The port is emitted VERBATIM, including 0. There is deliberately no fallback to
    22: on this host 127.0.0.1:22 is the operator's OWN workstation sshd, so a
    "sensible default" would quietly point a device button at the operator's machine.
    A device with ssh_host_port 0 published nothing and its login button belongs
    disabled; ssh itself also refuses port 0 outright.
    """
    argv = ["ssh", "-i", dev.ssh_key, "-p", str(dev.ssh_host_port),
            *SSH_OPTIONS, f"{user}@{SSH_HOST}"]
    if superuser:
        argv += ["-t", SUPERUSER_COMMAND]
    return argv


def terminal_argv(cmd_argv: list[str]) -> list[str] | None:
    """Wrap ``cmd_argv`` in the first available desktop terminal, or None if none is.

    Same list, order and exec-arg convention as cloud_deploy (the tuple is imported,
    not copied). No ``bash -c`` wrapper here on purpose: cloud_deploy needs one to
    shred a staged credentials file and hold the window open for a driver's output,
    whereas this argv IS an interactive session — the window must close when the
    operator types ``exit``, and an extra shell would swallow the pty ssh -t asked
    for.
    """
    for binary, exec_args in TERMINALS:
        if shutil.which(binary):
            return [binary, *exec_args, *cmd_argv]
    return None


# ── The display door ─────────────────────────────────────────────────────────────
#
# ONE door: SPICE over TCP on host loopback, protected by a per-run secret, opened by
# a native viewer that resizes the guest. The record names the door (port) and the
# secret's PATH; this module reads the secret only to write it into a 0600 viewer
# file that deletes itself, and never puts it on argv, in a URL, in a hint or in a
# log line — every string this section returns to a caller is safe to print.

def display_blocker(dev: Device) -> str:
    """Why ``dev``'s display cannot be opened right now, or "" when it can.

    A reason STRING, like ``save_blocker``, because the GUI has to say why the
    button is grey. Three conditions, in the order an operator can act on them:

    * the device is RUNNING — SPICE is served by the device's own QEMU, so a
      stopped row has nothing listening (a PAUSED one does: the frame freezes but
      the door is up, so pausing is deliberately NOT a blocker);
    * the record names a DISPLAY PORT — 0 means the run published no door. Today
      that is every board whose kernel lacks virtio-gpu (all ARM boards), and the
      wording says so rather than "scale": there is no picture to scale;
    * the record names the SECRET FILE — the door REQUIRES the per-run password
      (inside the container it listens on the mesh docker network, where other
      containers can reach it), so a record without one is a door this module
      refuses to open unauthenticated rather than one it opens open.
    """
    if not dev.is_running:
        return (f"{dev.label} is not running (state {dev.state or 'unknown'}); "
                "start it again with --keep-alive before opening its display")
    if dev.display_port <= 0:
        return (f"serial only: {dev.label} published no display (the record says "
                "display_port 0 — a desktop image gets one in keep-alive mode; a "
                "board whose kernel lacks virtio-gpu never does)")
    if dev.display_protocol and dev.display_protocol != DISPLAY_PROTOCOL_SPICE:
        return (f"{dev.label} publishes a {dev.display_protocol!r} display, which "
                "this Studio cannot open (only spice)")
    if not dev.display_password_file:
        return (f"{dev.label}'s record names no display secret file, so the door "
                "cannot be opened: it requires the per-run password")
    return ""


def can_display(dev: Device) -> bool:
    """Is the display door openable for this device at all? The GUI's predicate."""
    return not display_blocker(dev)


def display_resize_text(dev: Device) -> str:
    """The tooltip's honest half-sentence: what the window does to the guest."""
    if dev.display_resize == DISPLAY_RESIZE_GUEST:
        return "resizes with the window (the guest re-lays out at the new resolution)"
    return "scales to the window (the picture is fitted; the guest keeps its resolution)"


def _read_secret(path: str) -> str:
    """The secret's VALUE, for the one caller allowed to use it (``write_vv_file``).

    Stripped of whitespace only: the writer emits 48 hex chars and a trailing
    newline would otherwise become part of the password. Raises OSError for an
    unreadable file and ValueError for an empty one — both are the caller's to
    show inline, with the PATH, never the content.
    """
    with open(path, encoding="utf-8") as fh:
        secret = fh.read().strip()
    if not secret:
        raise ValueError(f"the display secret file {path} is empty")
    return secret


def vv_basename(label: str) -> str:
    """``hugmesh-<safe label>.vv`` — the viewer file's name prefix in the runtime dir."""
    return f"hugmesh-{safe_label(label)}"


def write_vv_file(dev: Device, runtime_dir: str) -> str:
    """Write the virt-viewer connection file for ``dev`` and return its path.

    The file is the ONLY place the secret's value goes: ``remote-viewer FILE`` reads
    the password from it, so argv carries a path and ``ps`` shows a path.
    ``mkstemp`` creates it 0600 and O_EXCL (a shared tmp cannot be pre-seeded with a
    symlink), ``delete-this-file=1`` makes remote-viewer unlink it once read, and
    ``runtime_dir`` is meant to be ``$XDG_RUNTIME_DIR`` (per-user, tmpfs, 0700) so a
    file the viewer never opened does not outlive the login either.

    ``host`` is the loopback literal, never the record's idea of a host: the record
    names a PORT the runner published on 127.0.0.1, and nothing else is reachable.
    """
    blocker = display_blocker(dev)
    if blocker:
        raise ValueError(blocker)
    secret = _read_secret(dev.display_password_file)
    os.makedirs(runtime_dir, mode=0o700, exist_ok=True)
    fd, path = tempfile.mkstemp(dir=runtime_dir, prefix=vv_basename(dev.label) + "-",
                                suffix=".vv")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("[virt-viewer]\n"
                     "type=spice\n"
                     f"host={DISPLAY_HOST}\n"
                     f"port={dev.display_port}\n"
                     f"password={secret}\n"
                     "delete-this-file=1\n"
                     f"title=hugmesh {dev.label}\n")
    except BaseException:
        try:
            os.unlink(path)
        except OSError:
            pass
        raise
    os.chmod(path, 0o600)
    return path


def display_url(dev: Device) -> str:
    """The noVNC fallback URL, or "" when the run published no web port.

    An IP literal (see DISPLAY_HOST) and NO password in it: noVNC prompts, and a
    URL is logged by browsers, proxies and shell histories. ``resize=scale`` is
    stated rather than ``remote`` because whether QEMU's VNC server honours a
    client SetDesktopSize is unverified; the browser path is scale-to-fit only.
    """
    if dev.display_web_port <= 0:
        return ""
    port = dev.display_web_port
    return (f"http://{DISPLAY_HOST}:{port}/vnc.html?host={DISPLAY_HOST}&port={port}"
            "&resize=scale&autoconnect=1")


def _viewer_binary(name: str) -> str | None:
    """``shutil.which`` behind one seam, so tests can decide what is installed."""
    return shutil.which(name)


def _browser_argv(url: str) -> list[str] | None:
    for opener in BROWSER_OPENERS:
        if _viewer_binary(opener[0]):
            return [*opener, url]
    return None


def display_hint(dev: Device, vv_path: str = "") -> str:
    """The copy-ready, SECRET-FREE line an operator can act on without the Studio:
    what to run, and where the password is. Every branch of ``display_argv``
    returns one, so the inline note always says how to open the display by hand."""
    parts = []
    if vv_path:
        parts.append(f"remote-viewer {shlex.quote(vv_path)}")
    else:
        parts.append(f"spice {DISPLAY_HOST}:{dev.display_port} "
                     f"(password in {dev.display_password_file})")
    url = display_url(dev)
    if url:
        parts.append(f"browser (scale-to-fit only): {url}")
    return " — ".join(parts)


def display_argv(dev: Device, viewer: str = "auto", runtime_dir: str = "",
                 ) -> tuple[list[str] | None, str]:
    """``(argv, hint)`` for opening ``dev``'s display — argv None when nothing here
    can open it, and ``hint`` ALWAYS a copy-ready, secret-free line.

    ``viewer``:

    * ``auto`` — the first auto-pickable entry of ``VIEWERS`` (remote-viewer), else
      the browser on the noVNC URL when the run published one, else None with the
      install hint. The order is the resize order: remote-viewer can resize the
      guest, the browser only scales.
    * ``remote-viewer`` — that viewer or None. Writes the ``.vv`` file into
      ``runtime_dir`` (the secret's only destination; see ``write_vv_file``).
    * ``spicy`` — explicit opt-in only. Spelled WITHOUT ``-w``: spicy prompts for
      the password, and the hint names the secret file's path to paste from. A
      ``-w SECRET`` would be a secret in the process table.
    * ``browser`` — the noVNC URL through ``BROWSER_OPENERS``, or None when the run
      published no web port or no opener exists.

    Raises ValueError for an unknown ``viewer`` or a blocked device (the GUI's
    button is grey then; this is the belt to those braces), and lets the secret
    file's OSError/ValueError through for the caller to show inline — with the
    path, never the content.
    """
    choice = (viewer or "auto").strip().lower()
    if choice not in DISPLAY_VIEWERS:
        raise ValueError(f"unknown display viewer {viewer!r}; expected one of "
                         + "|".join(DISPLAY_VIEWERS))
    blocker = display_blocker(dev)
    if blocker:
        raise ValueError(blocker)
    runtime_dir = runtime_dir or default_runtime_dir()

    if choice in ("auto", "remote-viewer"):
        for binary, auto_pick in VIEWERS:
            if choice == "auto" and not auto_pick:
                continue
            if choice == "remote-viewer" and binary != "remote-viewer":
                continue
            if _viewer_binary(binary):
                vv = write_vv_file(dev, runtime_dir)
                return [binary, vv], display_hint(dev, vv)
        if choice == "remote-viewer":
            return None, f"{VIEWER_INSTALL_HINT} Then: {display_hint(dev)}"

    if choice == "spicy":
        if _viewer_binary("spicy"):
            return (["spicy", "-h", DISPLAY_HOST, "-p", str(dev.display_port)],
                    f"spicy prompts for the password: it is in "
                    f"{dev.display_password_file}")
        return None, f"{VIEWER_INSTALL_HINT} Then: {display_hint(dev)}"

    # auto (no native viewer) or browser
    url = display_url(dev)
    if url:
        argv = _browser_argv(url)
        if argv is not None:
            return argv, display_hint(dev)
        return None, f"Open this in a browser (noVNC prompts for the password): {url}"
    if choice == "browser":
        return None, (f"{dev.label} published no noVNC web port (the run was not "
                      f"started with --display-web). {display_hint(dev)}")
    return None, f"{VIEWER_INSTALL_HINT} Then: {display_hint(dev)}"


def default_runtime_dir() -> str:
    """Where the ``.vv`` file goes: ``$XDG_RUNTIME_DIR`` (per-user tmpfs, 0700,
    gone at logout) when the session set one, else a private dir under the temp
    root. The file is 0600 either way; the runtime dir only adds "gone at logout"."""
    xdg = os.environ.get("XDG_RUNTIME_DIR", "").strip()
    if xdg and os.path.isdir(xdg):
        return xdg
    who = os.getuid() if hasattr(os, "getuid") else os.environ.get("USERNAME", "user")
    return os.path.join(tempfile.gettempdir(), f"hugmesh-display-{who}")


def wsl_display_hint(is_wsl: bool, wsl_version: int = 0) -> str:
    """How the display opens from Windows when the Studio runs inside WSL2: Docker
    (in WSL2) publishes 127.0.0.1:P, WSL forwards localhost to Windows, and the
    Linux viewer opens through WSLg — without WSLg the same ``.vv`` file opens in
    the Windows virt-viewer, and the browser URL opens in a Windows browser. "" off
    WSL (a native Windows Studio follows platform_info's existing WSL route)."""
    if not is_wsl:
        return ""
    if wsl_version == 1:
        return ("This is WSL1: no WSLg and no Docker daemon, so there is no display "
                "to open from here.")
    return ("Under WSL2 the viewer opens through WSLg. Without WSLg, open the .vv "
            "file with the Windows virt-viewer (remote-viewer.exe), or the browser "
            "URL in a Windows browser — Docker publishes 127.0.0.1:PORT in WSL2 and "
            "Windows reaches it through the localhost forward.")


def _runner(generator_dir: str) -> str:
    return os.path.join(generator_dir, RUNNER_SCRIPT)


def qmp_argv(generator_dir: str, dev: Device, command: str) -> list[str]:
    """argv for ``run-qemu-docker.sh --qmp LABEL CMD``.

    The Studio never speaks QMP itself. The socket is a HOST path in the registry,
    but the runner already owns talking to it (and owns the error text when a device
    has no socket because it was started without ``--qmp``), so keeping one client
    means one place to fix a protocol detail.

    Raises ValueError for a verb the runner does not accept — the GUI is expected to
    build its buttons from ``QMP_COMMANDS``, so an unknown verb is a coding error
    that should surface here rather than as an opaque shell failure.
    """
    cmd = (command or "").strip().lower()
    if cmd not in QMP_COMMANDS:
        raise ValueError(f"unknown QMP command {command!r}; expected one of "
                         + "|".join(QMP_COMMANDS))
    return [_runner(generator_dir), "--qmp", dev.label, cmd]


def device_control_argv(generator_dir: str, dev: Device, action: str) -> list[str]:
    """argv to stop ONE device — the runner's own ``--stop-device LABEL`` (it knows
    the container name; the registry's ``container`` field is for display, not for
    the GUI to issue docker commands of its own).

    ``start`` is GONE from this module (T2), and the branch below is a deliberate
    shim: the old spelling (``--keep-alive --only LABEL``) let the runner guess its
    newest session for the artifacts and matched the label by SUBSTRING — so a
    restart of ``x86/be`` could boot a different build than the device came from,
    and drag be+gpu/be-ha along with it. The single author of a per-device start is
    now ``hugmesh_studio.core.emulation.start_device_argv``, which pins
    ``--artifacts``/``--work`` (from the plan or the record's ``artifacts`` field)
    and addresses the row with ``--only-exact``. The shim goes away with its last
    caller (gui/pages/qemu.py's console) in T3.
    """
    act = (action or "").strip().lower()
    if act == "start":
        raise ValueError(
            "device_control_argv no longer authors 'start': a per-device start must "
            "pin --artifacts/--work and address its row with --only-exact — use "
            "hugmesh_studio.core.emulation.start_device_argv instead")
    if act not in DEVICE_ACTIONS:
        raise ValueError(f"unknown device action {action!r}; expected one of "
                         + "|".join(DEVICE_ACTIONS))
    return [_runner(generator_dir), "--stop-device", dev.label]


def stop_all_argv(generator_dir: str) -> list[str]:
    """argv for the fleet-wide stop button."""
    return [_runner(generator_dir), "--stop-all-devices"]


# ── Pause and save ───────────────────────────────────────────────────────────────

def safe_label(label: str) -> str:
    """``rpi5/pki`` -> ``rpi5_pki``: a label as it is spelled on disk.

    One rule, three implementations that must agree: ``safe_label()`` in
    tests/qemu/run-qemu-docker.sh:224, the ``tr '/+' '__'`` that names the registry
    record in tests/qemu/docker-entrypoint.sh:193, and ``result_filename()`` in
    core/qemu_tests.py:329. A save file named by a fourth rule would still work, but
    an operator (and a `ls`) could no longer pair a save with the device, the run dir
    and the result row it belongs to — so the rule is mirrored, and
    test_qemu_devices.py asserts it against qemu_tests's copy.
    """
    return label.replace("/", "_").replace("+", "_")


def default_work_dir(generator_dir: str) -> str:
    """The ``--work`` dir the runner uses when none is passed.

    Spelled from qemu_tests.DEFAULT_WORK_SUBDIR rather than repeated, because this
    has to be the same directory ``runner_command`` puts after ``--work`` — a second
    copy of "out/qemu-runs" here would send saves somewhere the runner never looks
    the day that default moves.
    """
    return os.path.join(generator_dir, DEFAULT_WORK_SUBDIR)


def saves_dir(work_dir: str) -> str:
    """The save directory inside a runner ``--work`` dir."""
    return os.path.join(work_dir, SAVES_SUBDIR)


def save_basename(label: str) -> str:
    """``rpi5/pki`` -> ``rpi5_pki.qcow2`` — the stable, timestamp-free save name."""
    return safe_label(label) + SAVE_SUFFIX


def default_save_target(work_dir: str, dev: Device) -> str:
    """The timestamp-free ``<work>/saves/<label>.qcow2`` for this device.

    This is a NAME rule, not the answer to "which file does Overwrite replace" — see
    ``saved_copies`` and ``save_argv`` for that. It stayed timestamp-free so a caller
    that wants one canonical save per device (``--save-to <label>.qcow2`` from a
    shell script, say) has a spelling for it, and so the runner's own listing —
    which globs BOTH ``<label>-*.qcow2`` and ``<label>.qcow2`` — has something to
    find under the second pattern.

    ``work_dir`` is the same ``--work`` the caller discovered the device from, so a
    caller that overrode the default work dir gets its saves in ITS tree.
    """
    return os.path.join(saves_dir(work_dir), save_basename(dev.label))


def saved_copies(work_dir: str, dev: Device) -> list[str]:
    """Every existing save for ``dev``, NEWEST FIRST.

    This function is the single definition of "the existing copy", because three
    different ones is what the first attempt shipped: the runner overwrote the newest
    save, the GUI armed against the newest save, and the core handed back a fixed
    timestamp-free name that nothing else ever wrote. After a few "Save a copy"
    presses, "Overwrite the existing copy" therefore overwrote NONE of them — it
    quietly maintained a private file of its own — and a save made from the shell
    could never be overwritten from the GUI.

    So the rule is the runner's rule, spelled once: the same two patterns
    ``run-qemu-docker.sh``'s ``newest_save_for()`` globs, ordered the way its
    ``ls -1t`` orders them.

    Ordered by MTIME rather than by name on purpose. A name sort would be a second,
    subtly different rule the moment a directory holds two stamp spellings (and it
    did: '-' sorts before 'T', so every older-format name would sort ahead of every
    newer one regardless of date). Modification time is what "newest" means to the
    operator who just pressed Save.

    Missing or unreadable directories are "no saves", not an error: this is read on
    every refresh of the device table, and an unplugged disk must cost a greyed
    button rather than a traceback out of a Qt slot.
    """
    root = saves_dir(work_dir)
    base = safe_label(dev.label)
    try:
        names = os.listdir(root)
    except OSError:
        return []

    def _owns(name: str) -> bool:
        """Is this save this device's?

        The SIDECAR decides, because the runner writes one beside every save and
        ``--list-saves`` filters by it. A name rule alone cannot see a save made with
        ``--save-to before-upgrade.qcow2``: it belongs to the device, it is listed for
        the device, and it must therefore be overwritable as the device's — otherwise
        the GUI and the CLI disagree about which file "the existing copy" is, which
        is exactly how a repeat-overwrite ends up destroying a copy the operator was
        never shown.

        The name is only the fallback, for saves written before sidecars existed. It
        is anchored on a digit so device ``x/y`` cannot claim ``x/y-z``'s files.
        """
        meta = os.path.join(root, name + ".json")
        try:
            with open(meta, encoding="utf-8") as fh:
                return json.load(fh).get("label") == dev.label
        except (OSError, ValueError):
            pass
        if name == base + SAVE_SUFFIX:
            return True
        rest = name[len(base) + 1:] if name.startswith(base + "-") else ""
        return bool(rest) and rest[0].isdigit()

    hits = [os.path.join(root, n) for n in names
            if n.endswith(SAVE_SUFFIX) and _owns(n)]

    def _mtime(p: str) -> float:
        try:
            return os.path.getmtime(p)
        except OSError:      # vanished between listdir and stat
            return 0.0

    # Tie-broken by name so equal mtimes (a fast test, a copied tree) still give a
    # stable order rather than whatever the filesystem happened to return.
    return sorted(hits, key=lambda p: (-_mtime(p), os.path.basename(p)))


def _utc_stamp() -> str:
    # datetime.timezone.utc, NOT datetime.UTC: the latter is 3.11+, and the Studio
    # supports 3.10 (hugmesh-studio.bat pins PYTHON_MIN=3.10 and the README documents
    # 3.10+). Every other tz-aware call in the tree spells it this way for the same
    # reason. On 3.10 the short spelling raises AttributeError at save time — i.e. the
    # default "Save a copy" path would die on a supported interpreter.
    return datetime.datetime.now(datetime.timezone.utc).strftime(SAVE_STAMP_FORMAT)


def new_save_target(work_dir: str, dev: Device, *, stamp: str = "") -> str:
    """A save path for "another copy" — one that does not exist yet.

    The stamp makes the name meaningful; the EXISTENCE CHECK is what makes the
    promise. A timestamp alone is not a no-clobber guarantee: two saves inside the
    same second, a re-run with an explicit ``stamp``, or a clock that stepped
    backwards would all silently overwrite a copy the operator asked to keep. So a
    taken name grows a ``-2``, ``-3`` … discriminator instead.

    ``stamp`` is injectable so callers (and tests) can name a copy deterministically;
    empty means "now", in UTC, matching the artifact stamps.
    """
    base = safe_label(dev.label)
    root = saves_dir(work_dir)
    stamp = (stamp or "").strip() or _utc_stamp()
    candidate = os.path.join(root, f"{base}-{stamp}{SAVE_SUFFIX}")
    if not os.path.exists(candidate):
        return candidate
    for n in range(2, 1000):
        candidate = os.path.join(root, f"{base}-{stamp}-{n}{SAVE_SUFFIX}")
        if not os.path.exists(candidate):
            return candidate
    # Unreachable in practice, and a loud failure is the only safe end: returning the
    # 999th name anyway would be handing back a path we KNOW is someone else's save.
    raise ValueError(f"no free save name for {dev.label!r} under {root} at {stamp}")


def save_would_overwrite(target: str) -> bool:
    """Is there already a file at ``target``?

    The GUI's arming condition: a save that replaces an existing copy is destructive
    and has to be confirmed inline, while the first save of a device is not.
    """
    return bool(target) and os.path.exists(target)


def save_blocker(dev: Device) -> str:
    """Why ``dev`` cannot be saved right now, or "" when it can.

    Three conditions, because a save is "pause it, copy its disk through its own
    QEMU, put it back the way it was" and each of them is a hard prerequisite:

    * the device is RUNNING — a stopped device has no QEMU to pause and no live
      overlay to copy (its disk is whatever the last run left behind);
    * the record names a CONTAINER — that is where the runner's QMP client runs
      (the socket is root-owned inside the container, so the host never opens it);
    * the record names a QMP SOCKET — a device started without ``--qmp`` has no
      control channel at all, so it can be logged into but not paused.

    Notably NOT required: a published ssh port or a key. Flushing the guest's page
    cache over ssh before the pause makes a saved copy cleaner, but its absence only
    costs cleanliness — the copy is crash-consistent either way — and a device that
    published no port must not lose its save button over it.

    A reason STRING rather than a bool because the GUI has to say why a button is
    disabled; ``can_save`` is the bool wrapper.
    """
    if not dev.is_running:
        return (f"{dev.label} is not running (state {dev.state or 'unknown'}); "
                "start it again with --keep-alive before saving")
    if not dev.container:
        return f"the record for {dev.label} names no container to run the save in"
    if not dev.qmp:
        return (f"{dev.label} has no QMP socket recorded (started without --qmp), "
                "so it cannot be paused or copied")
    return ""


def can_save(dev: Device) -> bool:
    """Is a save expressible for this device at all? The GUI's button predicate."""
    return not save_blocker(dev)


def _within(path: str, root: str) -> bool:
    """Is ``path`` inside ``root`` (or ``root`` itself)?

    ``realpath`` both sides first: a target reached through ``..`` or a symlinked
    work dir is the same file as the one spelled directly, and a refusal that a
    ``../..`` walks around is not a refusal. ``commonpath`` rather than
    ``startswith``, because ``out/sessions-archive`` is not inside ``out/sessions``
    and a string prefix cannot tell the difference.
    """
    if not path or not root:
        return False
    p = os.path.realpath(path)
    r = os.path.realpath(root)
    if p == r:
        return True
    try:
        return os.path.commonpath([p, r]) == r
    except ValueError:      # different roots entirely (no common path at all)
        return False


def save_target_refusal(target: str, *, generator_dir: str = "",
                        artifacts_dir: str = "", work_dir: str = "") -> str:
    """Why ``target`` must not be written to, or "" when it is an acceptable save.

    The rule this exists for is the last one: a save must never land in the artifacts
    tree. The golden ``.img`` files there are the shared build output that every run,
    every session and every other checkout boots from, and the overlay chain exists
    precisely so a running guest cannot touch them. A save written into that directory
    would put a multi-GB file among them under a name no build produced, in the one
    tree whose contents are supposed to be reproducible from a build.

    Note what this is NOT protecting against, so nobody strengthens the wrong thing:
    a stray save cannot be picked up as a bootable row. ``qemu_tests`` discovers only
    ``.img``/``.img.xz`` and ``SAVE_SUFFIX`` forces ``.qcow2`` — dropping .qcow2 files
    into an artifacts dir leaves ``discover_rows`` returning only the real image. This
    is defence in depth around a shared directory, not a fix for a live path.

    Two directories are checked because there are two ways to name that tree: the
    ``out/sessions`` root, which is where the builders always write, and an explicit
    ``--artifacts DIR`` the run may have been started with, which can be anywhere.
    Pass whichever the caller knows; both are optional and independent.

    ``work_dir`` adds the other direction: ``<work>/runs/`` holds the overlay QEMU has
    OPEN right now, and QEMU holds a write lock on it for the life of the guest, so a
    target in there is a save that cannot even be created — better refused by name,
    here, than reported as an opaque image-lock error later.

    Returned as text, not a bool, so the GUI can show the reason and the tests can
    assert on which rule fired.
    """
    if not target:
        return "no save target given"
    if not os.path.isabs(target):
        return (f"save target must be an absolute path, got {target!r} "
                "(the runner resolves it in its own working directory, not yours)")
    if not target.endswith(SAVE_SUFFIX):
        return (f"save target must be a {SAVE_SUFFIX} file, got {target!r}: a raw "
                "save is the device's whole virtual size, not the data in it")
    if os.path.isdir(target):
        return f"save target {target} is a directory"
    if artifacts_dir and _within(target, artifacts_dir):
        return (f"refusing to save into the artifacts directory {artifacts_dir}: it "
                "holds the golden images every run and every session boots from")
    if generator_dir:
        sessions_root = os.path.join(generator_dir, SESSIONS_SUBDIR)
        if _within(target, sessions_root):
            return (f"refusing to save into {sessions_root}: it holds the golden "
                    "images every run and every session boots from")
    if work_dir:
        # PARITY WITH THE RUNNER. run-qemu-docker.sh's save_check_target refuses all
        # of these, and this module is what the GUI checks BEFORE spawning it — so
        # anything missing here is a target the Studio offers and the runner then
        # rejects, which reads to the operator as the feature being broken. Where the
        # two lists ever differ, the stricter one is the correct one.
        for sub, why in (
            # The DECOMPRESSED goldens. /artifacts is mounted read-only so the obvious
            # spelling is already impossible, but these are the same images on a
            # writable mount, so the directory is named rather than trusted to a flag.
            ("images", "holds the decompressed GOLDEN images, which every run and "
                       "every session boots from"),
            (RUNS_SUBDIR, "is the live overlay QEMU has open, which it holds a write "
                          "lock on"),
            # Not catastrophic, but a save landing here would be read back as harness
            # state by something that has no idea it is looking at a disk image.
            ("devices", "is the device registry the Studio reads"),
            ("results", "holds the run verdicts"),
        ):
            root = os.path.join(work_dir, sub)
            if _within(target, root):
                return f"refusing to save into {root}: that directory {why}"
        # The container can only write to its /work bind mount, so a target outside it
        # cannot be created at all — and would fail as an opaque permission error deep
        # inside a save that has already paused the operator's device.
        if not _within(target, work_dir):
            return (f"save target must be under the work dir {work_dir}: the device "
                    "container can only write there")
    return ""


def device_save_argv(generator_dir: str, dev: Device, target: str,
                     overwrite: bool = False, *, artifacts_dir: str = "",
                     work_dir: str = "") -> list[str]:
    """argv for ``run-qemu-docker.sh --save-device LABEL --save-to PATH [--overwrite]``.

    The Studio never copies a disk itself, for the same reason it never speaks QMP
    itself (see ``qmp_argv``): the socket is root-owned inside the container and the
    runner already owns talking to it. Here that split is not just tidiness — the
    save has to pause the guest, run a block job to completion and put the run state
    back, and doing that from two places would eventually mean two different answers
    to "did it finish?".

    ``--overwrite`` is emitted ONLY when asked for, like every other non-default knob
    in ``qemu_tests.runner_command``. It is what turns a save into a destructive
    action — the previously saved copy at ``target`` is replaced — so it must arrive
    from an explicitly armed control, never from a default.

    No ``--work`` is passed, matching ``device_control_argv`` and ``qmp_argv``: the
    runner finds the device record in its own default work dir, and hardcoding a path
    here would fight a caller who overrode it. ``work_dir``/``artifacts_dir`` are used
    only to CHECK the target, and only when the caller knows them.

    Raises ValueError rather than emitting a doomed command, in the three cases the
    GUI can and should have prevented: a device that cannot be saved at all, a
    refused target, and an existing target with ``overwrite`` off. The last one is
    advisory — the runner is the authority on a path it is about to write, and it
    re-checks — but catching it here is what lets the GUI arm a confirmation instead
    of surfacing a shell error after the fact.
    """
    blocker = save_blocker(dev)
    if blocker:
        raise ValueError(blocker)
    refusal = save_target_refusal(target, generator_dir=generator_dir,
                                  artifacts_dir=artifacts_dir, work_dir=work_dir)
    if refusal:
        raise ValueError(refusal)
    if not overwrite and save_would_overwrite(target):
        raise ValueError(f"{target} already holds a saved copy; saving there means "
                         "overwriting it, which has to be asked for explicitly")
    argv = [_runner(generator_dir), "--save-device", dev.label, "--save-to", target]
    if overwrite:
        argv.append("--overwrite")
    return argv


def save_argv(generator_dir: str, dev: Device, mode: str, *,
              work_dir: str = "", artifacts_dir: str = "") -> list[str]:
    """argv for one of the operator's two save options, by MODE.

    ``device_save_argv`` above stays the primitive — it takes an explicit path and is
    the one the target rules are tested through. This is the caller-facing spelling,
    and it exists so that WHICH FILE a mode resolves to is decided here rather than in
    the GUI. That is not a style preference: the first attempt let the GUI pick the
    path, the runner pick a different one, and the core offer a third, so "overwrite
    the existing copy" overwrote a file nothing else had ever written.

      "copy"      -> a new timestamped file that does not exist yet. Never destructive.
      "overwrite" -> the NEWEST existing save for this device (``saved_copies[0]``),
                     whoever made it — the Studio in an earlier session, or the runner
                     straight from a shell.

    With no existing save, "overwrite" RAISES instead of inventing a name. Silently
    creating a first copy would be "Save a copy" wearing a destructive label, and the
    operator armed a control that promised to replace something.

    ``work_dir`` defaults to the runner's own default work dir under
    ``generator_dir``, which is where ``discover_devices`` reads the registry from, so
    the common call needs only three arguments. A caller that ran with ``--work``
    elsewhere passes it and gets its saves in ITS tree.
    """
    m = (mode or "").strip().lower()
    if m not in SAVE_MODES:
        raise ValueError(f"unknown save mode {mode!r}; expected one of "
                         + "|".join(SAVE_MODES))
    work = work_dir or default_work_dir(generator_dir)
    if m == "copy":
        return device_save_argv(generator_dir, dev, new_save_target(work, dev),
                                overwrite=False, artifacts_dir=artifacts_dir,
                                work_dir=work)
    existing = saved_copies(work, dev)
    if not existing:
        raise ValueError(
            f"{dev.label} has no saved copy yet, so there is nothing to overwrite — "
            "take a copy first")
    return device_save_argv(generator_dir, dev, existing[0], overwrite=True,
                            artifacts_dir=artifacts_dir, work_dir=work)


def available_logins(dev: Device, cfg_users: list) -> list[tuple[str, str]]:
    """``[(login, display)]`` for a device's user dropdown.

    Two different populations meet here and only their INTERSECTION is offerable:

    * the guest's real logins (``dev.users``) — the payload's ``tester`` plus any
      ``--extra-user`` accounts the run was started with;
    * the wizard's configured people (``cfg_users``: anything with ``.username`` and
      ``.domain``), which are MESH identities. Most of them were never created as
      unix accounts on this image at all.

    So a configured user is only labelled, never added: offering "alice @ example.org"
    on a device that has no alice produces an ssh that fails with Permission denied
    and no explanation. Conversely a device login with no matching wizard entry is
    still shown, unlabelled — it exists, so it can be logged into.

    ``ssh_user`` leads the list because it is the one account the payload always
    creates, so the dropdown's default selection is always a login that works.
    """
    domains: dict[str, str] = {}
    for user in cfg_users or ():
        name = str(getattr(user, "username", "") or "").strip()
        if not name or name in domains:
            continue
        domains[name] = str(getattr(user, "domain", "") or "").strip()

    logins: list[str] = []
    for login in [dev.ssh_user, *dev.users]:
        login = str(login or "").strip()
        if login and login not in logins:
            logins.append(login)

    out: list[tuple[str, str]] = []
    for login in logins:
        domain = domains.get(login, "")
        out.append((login, f"{login} @ {domain}" if domain else login))
    return out
