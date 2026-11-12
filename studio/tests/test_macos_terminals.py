"""Every "open a terminal" path in the Studio has a macOS route, and it is ONE route.

Five places open a window for the operator: go-live's commit (golive_target.
terminal_spec), cloud deploy's apply/destroy (CloudDeploy.terminal_command), the phone
wizard's flash/enroll (PhoneWizard.terminal_command), a device login
(qemu_devices.terminal_argv) and the local AI agent (local_agent.launch, tested in
test_local_agent.py). On a Mac none of their Linux emulators exist, so each said "No
terminal emulator found" and handed back a command to paste. Each now asks
core/macos_host.wrap_in_terminal first: Terminal.app (or iTerm2) on a self-deleting
``.command`` file. Secrets that rode a 0600 file before still do: the wrapper's
shred/rm line is inside the script the file runs, never on an argv.
"""
from __future__ import annotations

import os
import types

import pytest

from hugmesh_studio.core import golive_target, macos_host, qemu_devices
from hugmesh_studio.core.cloud_deploy import CloudDeploy, CloudDeployOptions
from hugmesh_studio.core.phone_wizard import PhoneWizard


@pytest.fixture
def as_a_mac(monkeypatch, tmp_path):
    monkeypatch.setattr(macos_host, "sys", types.SimpleNamespace(platform="darwin"))
    state = tmp_path / "state"
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(state))
    return state


def _script(argv):
    # iTerm2 only where it is installed: never on Linux or on a hosted runner
    assert argv[:2] == ["open", "-a"] and argv[2] in ("Terminal", "iTerm"), argv
    assert argv[3].endswith(".command") and os.path.isfile(argv[3])
    return open(argv[3], encoding="utf-8").read()


def test_go_live_opens_terminal_app_holding_the_window(tmp_path):
    spec = golive_target.terminal_spec(["ssh", "-t", "root@10.0.0.5", "hugmesh-go-live"],
                                       osname="posix", sysplatform="darwin",
                                       state_dir=str(tmp_path), isdir=lambda d: False,
                                       which=lambda n: None)
    assert spec.how == "darwin" and spec.creationflags == 0
    text = _script(spec.argv)
    assert "ssh -t root@10.0.0.5 hugmesh-go-live" in text
    assert "press Enter to close" in text


def test_go_live_on_linux_is_unchanged(tmp_path):
    spec = golive_target.terminal_spec(["ssh", "x"], osname="posix", sysplatform="linux",
                                       which=lambda n: "/usr/bin/xterm" if n == "xterm" else None,
                                       terminals=(("xterm", ("-e",)),))
    assert spec.how == "linux" and spec.argv[:3] == ["xterm", "-e", "bash"]
    assert not (tmp_path / "term").exists()


def test_cloud_deploy_keeps_its_creds_shred_inside_the_script(as_a_mac):
    cd = CloudDeploy("/gen", CloudDeployOptions())
    argv = cd.terminal_command(["/gen/specs/usr/sbin/hugmesh-cloud-deploy", "apply"],
                               credsfile="/tmp/creds-abc")
    text = _script(argv)
    assert "hugmesh-cloud-deploy apply" in text
    assert "shred -u /tmp/creds-abc" in text and "rm -f /tmp/creds-abc" in text
    assert "/tmp/creds-abc" not in " ".join(argv)        # never on the window's argv
    assert os.path.dirname(argv[3]) == str(as_a_mac / "term")


def test_the_phone_wizard_keeps_its_authkey_shred_inside_the_script(as_a_mac):
    argv = PhoneWizard("/gen").terminal_command(["/gen/x", "enroll"], keyfile="/tmp/k1")
    text = _script(argv)
    assert "shred -u /tmp/k1" in text and "/tmp/k1" not in " ".join(argv)


def test_a_device_login_is_not_held_open(as_a_mac):
    argv = qemu_devices.terminal_argv(["ssh", "-t", "-p", "2222", "hugmesh@127.0.0.1"])
    text = _script(argv)
    assert "ssh -t -p 2222 hugmesh@127.0.0.1" in text
    assert "press Enter" not in text      # the window closes when the session does


def test_off_a_mac_the_linux_lists_still_answer(monkeypatch, tmp_path):
    monkeypatch.setattr(macos_host, "sys", types.SimpleNamespace(platform="linux"))
    monkeypatch.setattr("shutil.which", lambda n: "/usr/bin/xterm" if n == "xterm" else None)
    assert qemu_devices.terminal_argv(["ssh", "x"]) == ["xterm", "-e", "ssh", "x"]
    assert CloudDeploy("/gen").terminal_command(["d"])[:3] == ["xterm", "-e", "bash"]
