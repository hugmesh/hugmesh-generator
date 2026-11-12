"""A fake emulated go-live device for the GUI, TUI and CLI face tests (Qt-free).

``ssh`` is the ONLY process an emulated go-live target makes this host run, so the
faces are tested against a fake ``ssh`` put first on PATH: it plays the guest. The
remote command arrives as ssh's last argument (golive_target.remote_argv shlex-joins
it into ONE element), and the shim answers each shape the core sends — the probe, the
driver's ``list`` / ``status`` / ``plan``, the token staging over stdin, the artifact
listing and ``cat``, the token ``rm``. ``list`` is the CHECKOUT's real driver ``list``,
so the provider rows are the real registry's. Every argv is appended to
``calls.jsonl``, so a test can assert what was (and what was never) on an argv.

No network, no docker, no qemu: the "guest filesystem" is ``<root>/fs``.
"""
from __future__ import annotations

import dataclasses
import json
import os
import stat
import sys

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

#: the shim; {python} and {gen} are filled in when it is written
_SHIM = r'''#!{python}
import json, os, shlex, subprocess, sys
root = os.environ["FAKE_GUEST_ROOT"]
argv = sys.argv[1:]
with open(os.path.join(root, "calls.jsonl"), "a", encoding="utf-8") as fh:
    fh.write(json.dumps(argv) + "\n")
if os.environ.get("FAKE_GUEST_DOWN"):
    sys.stderr.write("ssh: connect to host 127.0.0.1 port 22401: Connection refused\n")
    sys.exit(255)
cmd = argv[-1] if argv else ""
try:
    words = shlex.split(cmd)
except ValueError:
    words = []
fs = os.path.join(root, "fs")
def g(p):
    return os.path.join(fs, p.lstrip("/"))
if "::driver" in cmd:
    drv = os.environ.get("FAKE_GUEST_DRIVER", "/usr/sbin/hugmesh-go-live")
    print("::driver")
    if drv:
        print(drv)
    print("::cluster-domain"); print(os.environ.get("FAKE_GUEST_DOMAIN", "mesh.example"))
    print("::domains"); print(os.environ.get("FAKE_GUEST_DOMAINS", ""))
    print("::release-state"); print("internal")
    print("::end")
    sys.exit(0)
if "mktemp" in cmd:
    data = sys.stdin.read()
    path = "/run/hugmesh-golive-tok.AbC123"
    os.makedirs(os.path.dirname(g(path)), exist_ok=True)
    with open(g(path), "w", encoding="utf-8") as fh:
        fh.write(data)
    print(path)
    sys.exit(0)
for lead in (["sudo", "-n", "hugmesh-go-live"], ["sudo", "hugmesh-go-live"]):
    if words[:len(lead)] == lead:
        rest = words[len(lead):]
        verb = rest[0] if rest else ""
        if verb == "list":
            env = dict(os.environ, GL_PROVIDERS_LIB=os.path.join(
                {gen!r}, "specs", "usr", "lib", "hugmesh", "go-live-providers.sh"))
            r = subprocess.run(["bash", "./specs/usr/sbin/hugmesh-go-live", "list"],
                               cwd={gen!r}, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True)
            sys.stdout.write(r.stdout)
            sys.exit(r.returncode)
        if verb == "status":
            print("Go-live status (fake guest)")
            print("  posture: INTERNAL")
            sys.exit(0)
        if verb == "plan":
            out = rest[rest.index("--out-dir") + 1]
            dom = rest[rest.index("--domain") + 1] if "--domain" in rest else ""
            os.makedirs(g(out), exist_ok=True)
            print("==> Rendering provider artifacts", flush=True)
            with open(os.path.join(g(out), "records.txt"), "w", encoding="utf-8") as fh:
                fh.write(f"@ A 203.0.113.10 ; {{dom}}\n")
            with open(os.path.join(g(out), "zone.db"), "w", encoding="utf-8") as fh:
                fh.write(f"$ORIGIN {{dom}}.\n")
            if "--token-file" in rest:
                tok = rest[rest.index("--token-file") + 1]
                with open(os.path.join(root, "token-seen"), "w", encoding="utf-8") as fh:
                    fh.write(open(g(tok), encoding="utf-8").read())
            print("==> Plan summary ready", flush=True)
            sys.exit(int(os.environ.get("FAKE_GUEST_PLAN_RC", "0")))
        print(f"fake guest: {{verb}}")
        sys.exit(0)
if words[:3] == ["sudo", "-n", "sh"] and "for f in" in cmd:
    d = g(words[-1])
    for n in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if os.path.isfile(os.path.join(d, n)):
            print(n)
    sys.exit(0)
if words[:3] == ["sudo", "-n", "cat"]:
    sys.stdout.write(open(g(words[-1]), encoding="utf-8").read())
    sys.exit(0)
if words[:4] == ["sudo", "-n", "rm", "-f"]:
    p = g(words[-1])
    if os.path.exists(p):
        os.remove(p)
    with open(os.path.join(root, "removed"), "a", encoding="utf-8") as fh:
        fh.write(words[-1] + "\n")
    sys.exit(0)
sys.stderr.write("fake guest: unexpected " + cmd + "\n")
sys.exit(97)
'''


@dataclasses.dataclass
class FakeGuest:
    root: str
    work_dir: str
    key: str

    def calls(self) -> list[list[str]]:
        path = os.path.join(self.root, "calls.jsonl")
        if not os.path.exists(path):
            return []
        with open(path, encoding="utf-8") as fh:
            return [json.loads(ln) for ln in fh if ln.strip()]

    def remote_commands(self) -> list[str]:
        return [c[-1] for c in self.calls() if c]

    def removed(self) -> list[str]:
        path = os.path.join(self.root, "removed")
        return open(path, encoding="utf-8").read().split() if os.path.exists(path) else []

    def token_seen(self) -> str:
        path = os.path.join(self.root, "token-seen")
        return open(path, encoding="utf-8").read() if os.path.exists(path) else ""


def install(tmp_path, monkeypatch) -> FakeGuest:
    """Put the fake ``ssh`` first on PATH and return the guest's handles."""
    root = tmp_path / "guest"
    (root / "fs").mkdir(parents=True)
    bindir = tmp_path / "bin"
    bindir.mkdir()
    shim = bindir / "ssh"
    shim.write_text(_SHIM.replace("{python}", sys.executable)
                    .replace("{gen!r}", repr(GENERATOR_DIR))
                    .replace("{{", "{").replace("}}", "}"))
    shim.chmod(shim.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    monkeypatch.setenv("PATH", f"{bindir}{os.pathsep}{os.environ.get('PATH', '')}")
    monkeypatch.setenv("FAKE_GUEST_ROOT", str(root))
    key = tmp_path / "id_ed25519"
    key.write_text("not a real key\n")
    work = tmp_path / "work"
    (work / "devices").mkdir(parents=True)
    return FakeGuest(str(root), str(work), str(key))


def register(guest: FakeGuest, label="rpi5/pki", platform="rpi5", role="pki",
             port=22401, state="running", started_at="2026-11-09T20:00:00Z",
             user="hugmesh", key=None):
    """Write a keep-alive device record (the entrypoint's own JSON) into the work dir,
    where golive_target.targets finds it. Returns the Device."""
    from hugmesh_studio.core import qemu_devices
    dev = qemu_devices.Device(label=label, platform=platform, role=role,
                              container=f"hugmesh-qemu-{label.replace('/', '-')}",
                              ssh_host_port=port, ssh_user=user,
                              ssh_key=guest.key if key is None else key,
                              state=state, started_at=started_at)
    safe = label.replace("/", "_").replace("+", "_")
    with open(os.path.join(guest.work_dir, "devices", f"{safe}.json"), "w",
              encoding="utf-8") as fh:
        json.dump(dataclasses.asdict(dev), fh)
    return dev
