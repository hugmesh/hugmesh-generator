"""A finished x86 session on disk, shaped exactly as build-x86-host-stage4.sh +
scripts/kernel-reconfig-x86.sh leave it, for the kernel reconfiguration tests.

<out>/sessions/<id>/                 the session work dir
  secureboot/sb.key, sb.crt          only when signed=True and key=True
  wl-pki.x86/sysroot/usr/src/linux-<kv>/Makefile, linux -> linux-<kv>
  wl-pki.x86/sysroot/lib/modules/<kv>/
  wl-pki.x86/kernel/config-<kv>      the kept final .config
  wl-pki.x86/kernel-reconfig.env     the no-secret contract (env=True)
  wl-pki.x86/kernel-reconfig/pending/config.before|after   (pending=True / changed)
"""
from __future__ import annotations

import os

from hugmesh_studio.core import build_sessions

KV = "6.18.52-gentoo"
BEFORE = ('CONFIG_LOCALVERSION=""\nCONFIG_SECURITY_SELINUX=y\nCONFIG_USB_NET_CDC_NCM=m\n'
          '# CONFIG_EXT2_FS is not set\n')
AFTER = ('CONFIG_LOCALVERSION="-hmtest"\nCONFIG_SECURITY_SELINUX=y\n'
         '# CONFIG_USB_NET_CDC_NCM is not set\n# CONFIG_EXT2_FS is not set\n')


def _w(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def make_session(root: str, *, sid: str = "20261111-120000-abcdef", platform: str = "x86",
                 status: str = "complete", image_status: str = "ok", env: bool = True,
                 config: bool = True, tree: bool = True, signed: bool = True, key: bool = True,
                 pending: bool = False, changed: bool = True, save: bool = True,
                 image_id: str | None = None) -> build_sessions.BuildSession:
    image_id = image_id or f"pki.{platform}"
    wd = os.path.join(root, "out", "sessions", sid)
    br = os.path.join(wd, f"wl-{image_id}")
    s = os.path.join(br, "sysroot")
    os.makedirs(os.path.join(s, "lib", "modules", KV), exist_ok=True)
    os.makedirs(os.path.join(s, "usr", "src"), exist_ok=True)
    if tree:
        _w(os.path.join(s, "usr", "src", f"linux-{KV}", "Makefile"), "VERSION = 6\n")
        os.symlink(f"linux-{KV}", os.path.join(s, "usr", "src", "linux"))
    if config:
        _w(os.path.join(br, "kernel", f"config-{KV}"), BEFORE)
    if env:
        _w(os.path.join(br, "kernel-reconfig.env"),
           "KR_FORMAT=1\nBUILD_TS=20261111T083445Z\nBRAND=hugmesh\nROLE=pki\nROLE_TAG=pki\n"
           f"ENV=test\nUKI_NAME=hugmesh.efi\nUKI_SIGNED={'yes' if signed else 'no'}\n"
           f"KVER={KV}\nKERNEL_CONFIG=kernel/config-{KV}\n"
           "STAGE4=hugmesh-x86-amd64-pki-test-20261111T083445Z.stage4.tar.xz\n")
    if signed and key:
        _w(os.path.join(wd, "secureboot", "sb.key"), "not a real key\n")
        _w(os.path.join(wd, "secureboot", "sb.crt"), "not a real cert\n")
    if pending:
        _w(os.path.join(br, "kernel-reconfig", "pending", "config.before"), BEFORE)
        _w(os.path.join(br, "kernel-reconfig", "pending", "config.after"),
           AFTER if changed else BEFORE)
    sess = build_sessions.BuildSession(
        id=sid, created="2026-11-11T12:00:00", status=status, workdir=wd,
        label=f"pki ({platform})", backend="docker",
        images=[{"id": image_id, "role": "pki", "platform": platform,
                 "status": image_status, "exit_code": 0, "keys_ok": True}])
    if save:
        build_sessions.save(sess)
    return sess


def result_json(stamp: str = "20261111T130000Z") -> dict:
    return {"stamp": stamp, "old_kver": KV, "new_kver": KV + "-hmtest",
            "old_build_ts": "20261111T083445Z", "new_build_ts": stamp, "signed": True,
            "sbverify": {"sysroot": True, "esp": "true"},
            "changes": [{"symbol": "CONFIG_LOCALVERSION", "old": '""', "new": '"-hmtest"'}],
            "artifacts": {"hugmesh-x86-amd64-pki-test-%s.img.xz" % stamp: "ab" * 32},
            "superseded": "superseded/20261111T083445Z"}
