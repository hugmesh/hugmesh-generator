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
"""
from __future__ import annotations

import json
import os
import shutil
from dataclasses import dataclass, field

# ONE terminal list for the whole app. cloud_deploy.py already picked this order
# (most-specific first) and pairs each binary with its exec-style flag, because
# gnome-terminal/kitty want "--", xfce4-terminal wants "-x" and foot wants neither.
# A second copy would drift the day someone adds a terminal to only one of them.
from hugmesh_studio.core.cloud_deploy import TERMINALS
# The runner path lives in qemu_tests so the two device-facing modules can never
# disagree about which script they drive.
from hugmesh_studio.core.qemu_tests import RUNNER_SCRIPT

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

#: QMP verbs the runner accepts for ``--qmp LABEL CMD``. The GUI should build its
#: buttons FROM this tuple rather than hardcoding strings, so adding a verb is a
#: one-line change in one place.
QMP_COMMANDS = ("pause", "resume", "reset", "powerdown", "status")

#: Lifecycle actions ``device_control_argv`` can express — the same start/stop pair
#: the local-mesh page already offers, so the two device surfaces read alike.
DEVICE_ACTIONS = ("start", "stop")

#: A record whose state is one of these describes a device that is no longer there.
#: "" is included because a truncated/never-updated record must not be offered as a
#: live login target.
_DEAD_STATES = ("stopped", "")


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

    @property
    def is_running(self) -> bool:
        return self.state not in _DEAD_STATES


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
    )


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
    """argv to start or stop ONE device — the local-mesh start/stop pair, per device.

    ``stop`` is the runner's own ``--stop-device LABEL`` (it knows the container
    name; the registry's ``container`` field is for display, not for the GUI to
    issue docker commands of its own).

    ``start`` re-enters the normal boot path filtered to this one row
    (``--keep-alive --only LABEL``), because a stopped device has no container to
    resume — the image must be booted again. ``--only`` is a substring filter on
    ``<platform>/<role>``, which IS the label. No ``--work`` is passed: the runner's
    default work dir is the same ``out/qemu-runs`` the registry was read from, and
    hardcoding a path here would fight a caller who overrode it.
    """
    act = (action or "").strip().lower()
    if act not in DEVICE_ACTIONS:
        raise ValueError(f"unknown device action {action!r}; expected one of "
                         + "|".join(DEVICE_ACTIONS))
    if act == "stop":
        return [_runner(generator_dir), "--stop-device", dev.label]
    return [_runner(generator_dir), "--keep-alive", "--only", dev.label]


def stop_all_argv(generator_dir: str) -> list[str]:
    """argv for the fleet-wide stop button."""
    return [_runner(generator_dir), "--stop-all-devices"]


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
