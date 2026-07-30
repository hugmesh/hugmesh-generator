"""Secret-file vault (core/secret_files.py) — pure-core, no Qt, no real builds.

The 2026-07-29 operator ask, pinned end-to-end at the core layer:
"instead of just browsing for keys usb or signing key or cert, once the file is
selected its held in memory until the build is completed, if the build is restarted,
a prompt appears to reenter when it is needed".

Covers: hold/drop/replace semantics; the keys-USB member model (exactly what
build-x86-host-stage4.sh:1429-1430 reads); just-in-time materialization (0700 dir /
0600 files, cleaned after); BuildDriver consumption via a REAL run() against a stub
builder script — proving the build reads the HELD copy even after the origin file is
deleted (the USB-unplug case), and that no tmp copy outlives the run; the preflight
held-skip; and the persistence scan — held CONTENT never lands in a session record or
a saved config, while the PATH contract stays untouched.
"""
import hashlib
import json
import os
import stat

import pytest

from hugmesh_studio.core import build_sessions, secret_files
from hugmesh_studio.core.build_driver import BuildDriver
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry, synthesize

# Distinctive markers so the persistence scan cannot false-negative on generic bytes.
KEY_PEM = b"-----BEGIN PRIVATE KEY-----\nVAULT-SENTINEL-0xC0FFEE-DO-NOT-PERSIST\n-----END PRIVATE KEY-----\n"
DER_BYTES = b"\x30\x82VAULT-DER-SENTINEL\x01\x02"


@pytest.fixture(autouse=True)
def _fresh_vault(monkeypatch):
    """Isolate the PROCESS vault per test — the pages/driver all consume the module
    singleton, so leakage between tests would fake retention."""
    monkeypatch.setattr(secret_files, "_VAULT", secret_files.SecretFileVault())


def host(is_root=True):
    return HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                    has_kvm=False, is_root=is_root, builder_image="hugmesh-builder")


def _key_file(tmp_path, name="kernel_key.pem", data=KEY_PEM):
    p = tmp_path / name
    p.write_bytes(data)
    return str(p)


def _keys_usb_dir(tmp_path, pem=True, der=True):
    d = tmp_path / "KEYS"
    (d / "Keys").mkdir(parents=True)
    if pem:
        (d / "Keys" / "kernel_key.pem").write_bytes(KEY_PEM)
    if der:
        (d / "Keys" / "kernel_key.der").write_bytes(DER_BYTES)
    return str(d)


# ── hold semantics ─────────────────────────────────────────────────────────────────
def test_hold_single_file_is_sha256sum_verifiable(tmp_path):
    """A single-file entry's sha256 equals `sha256sum <file>` ON PURPOSE, so the
    operator can verify the held copy against their own tooling."""
    p = _key_file(tmp_path)
    e = secret_files.vault().hold("secureboot_key", p)
    assert e.name == "kernel_key.pem"
    assert e.origin == os.path.abspath(p)
    assert e.members == (("kernel_key.pem", KEY_PEM),)
    assert e.sha256 == hashlib.sha256(KEY_PEM).hexdigest()
    assert e.fingerprint == e.sha256[:12] and len(e.fingerprint) == 12
    assert secret_files.vault().has("secureboot_key")
    # the GUI row phrase (the operator-facing retention promise) rides summary()
    assert "held in memory for this session" in e.summary()
    assert e.name in e.summary() and e.fingerprint in e.summary()


def test_rehold_replaces_and_drop_forgets(tmp_path):
    v = secret_files.vault()
    v.hold("secureboot_key", _key_file(tmp_path, "a.pem", b"AAAA"))
    e2 = v.hold("secureboot_key", _key_file(tmp_path, "b.pem", b"BBBB"))
    assert v.get("secureboot_key").sha256 == e2.sha256 == hashlib.sha256(b"BBBB").hexdigest()
    assert v.drop("secureboot_key") is True
    assert not v.has("secureboot_key")
    assert v.drop("secureboot_key") is False          # idempotent, honest return


def test_hold_unknown_field_refused(tmp_path):
    with pytest.raises(ValueError, match="not a held-in-memory"):
        secret_files.vault().hold("secureboot_cert", _key_file(tmp_path))


def test_hold_keys_usb_reads_exactly_the_builder_members(tmp_path):
    """--keys-usb holds the two files the builder resolves (x86:1429-1430), nothing
    else from the dir — extra payload files must never be slurped into memory."""
    d = _keys_usb_dir(tmp_path)
    (tmp_path / "KEYS" / "provision.json").write_bytes(b"NOT-KEY-MATERIAL")
    e = secret_files.vault().hold("keys_usb", d)
    assert e.name == "KEYS"
    assert [rel for rel, _ in e.members] == ["Keys/kernel_key.pem", "Keys/kernel_key.der"]
    assert dict(e.members)["Keys/kernel_key.pem"] == KEY_PEM
    assert b"NOT-KEY-MATERIAL" not in b"".join(data for _r, data in e.members)


def test_hold_keys_usb_tolerates_either_member_alone(tmp_path):
    d = _keys_usb_dir(tmp_path, pem=False, der=True)
    e = secret_files.vault().hold("keys_usb", d)
    assert [rel for rel, _ in e.members] == ["Keys/kernel_key.der"]


def test_hold_keys_usb_without_key_material_refused(tmp_path):
    d = tmp_path / "EMPTYUSB"
    (d / "Keys").mkdir(parents=True)
    with pytest.raises(ValueError, match="nothing to hold in memory"):
        secret_files.vault().hold("keys_usb", str(d))
    assert not secret_files.vault().has("keys_usb")   # nothing partially held


def test_hold_oversized_file_refused(tmp_path, monkeypatch):
    """A mis-click on an image file must fail loudly at browse time, not OOM later."""
    monkeypatch.setattr(secret_files, "MAX_HELD_BYTES", 16)
    with pytest.raises(ValueError, match="ceiling"):
        secret_files.vault().hold("secureboot_key",
                                  _key_file(tmp_path, "big.pem", b"x" * 17))


# ── materialization: private 0600 tmp copies, cleaned after ────────────────────────
def test_materialize_0600_files_0700_dirs_and_cleanup(tmp_path):
    v = secret_files.vault()
    ek = v.hold("secureboot_key", _key_file(tmp_path))
    eu = v.hold("keys_usb", _keys_usb_dir(tmp_path))
    mat = secret_files.materialize([ek, eu])
    key_path = mat.paths["secureboot_key"]
    usb_path = mat.paths["keys_usb"]
    assert os.path.isfile(key_path)
    with open(key_path, "rb") as fh:
        assert fh.read() == KEY_PEM
    # keys_usb materializes as a DIRECTORY carrying the builder's expected layout
    assert os.path.isdir(usb_path)
    assert os.path.isfile(os.path.join(usb_path, "Keys", "kernel_key.pem"))
    # permission discipline: 0600 files under 0700 dirs, root dir included
    assert stat.S_IMODE(os.stat(key_path).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(os.path.join(usb_path, "Keys", "kernel_key.pem")).st_mode) == 0o600
    root = os.path.dirname(os.path.dirname(key_path))
    assert stat.S_IMODE(os.stat(root).st_mode) == 0o700
    mat.cleanup()
    assert not os.path.exists(root)                   # nothing outlives the run


# ── BuildDriver consumption — a REAL run() against a stub builder ──────────────────
ECHO_BUILDER = """#!/usr/bin/env bash
# Stub build-x86-host-stage4.sh: records the --secureboot-key value it received,
# that file's content and mode, then exits 0. NOT a build.
out=""
key=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w) out="$2"; shift 2 ;;
    --secureboot-key) key="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$out"
printf '%s' "$key" > "$out/received-key-path"
if [ -n "$key" ] && [ -f "$key" ]; then
  cat "$key" > "$out/received-key-content"
  stat -c %a "$key" > "$out/received-key-mode"
fi
exit 0
"""


def _stub_generator(tmp_path):
    gen = tmp_path / "gen"
    gen.mkdir()
    script = gen / "build-x86-host-stage4.sh"
    script.write_text(ECHO_BUILDER)
    script.chmod(0o755)
    return str(gen)


def _x86_cfg(tmp_path, gen, **kw):
    return ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                       output_dir=str(tmp_path / "out"), jobs=1, **kw)


def test_run_consumes_held_copy_even_after_origin_deleted(tmp_path):
    """THE ask, end to end: browse (hold), unplug (delete the origin), build — the
    builder receives a private 0600 tmp copy of the HELD bytes, and that copy is
    gone once the run ends."""
    gen = _stub_generator(tmp_path)
    origin = _key_file(tmp_path)
    secret_files.vault().hold("secureboot_key", origin)
    os.remove(origin)                                  # the USB walked away
    cfg = _x86_cfg(tmp_path, gen, secureboot_key=origin)
    lines = []
    code = BuildDriver(gen, host()).run(cfg, "native", on_line=lines.append)
    assert code == 0
    out = tmp_path / "out"
    received = (out / "received-key-path").read_text()
    assert received and received != origin             # a tmp copy, not the dead path
    assert (out / "received-key-content").read_bytes() == KEY_PEM
    assert (out / "received-key-mode").read_text().strip() == "600"
    assert not os.path.exists(received)                # cleaned in the finally
    # the log says WHAT happened (the honesty line run() emits)
    assert any("held-in-memory" in ln and "--secureboot-key" in ln for ln in lines)
    # ...and the config object handed in was never mutated (deepcopy discipline)
    assert cfg.secureboot_key == origin


def test_run_ignores_vault_on_origin_mismatch_and_on_empty_field(tmp_path):
    """The origin pin: a held copy is consumed ONLY for the exact selection it was
    read from. A different configured path passes through verbatim (plain-path
    semantics); an empty field emits no flag — the vault never INJECTS one."""
    gen = _stub_generator(tmp_path)
    secret_files.vault().hold("secureboot_key", _key_file(tmp_path, "held.pem"))
    other = _key_file(tmp_path, "other.pem", b"OTHER")
    cfg = _x86_cfg(tmp_path, gen, secureboot_key=other)
    assert BuildDriver(gen, host()).run(cfg, "native") == 0
    assert (tmp_path / "out" / "received-key-path").read_text() == other  # verbatim
    # empty field: no flag, no injection
    cfg2 = _x86_cfg(tmp_path, gen)
    assert BuildDriver(gen, host()).run(cfg2, "native") == 0
    assert (tmp_path / "out" / "received-key-path").read_text() == ""


def test_headless_process_with_empty_vault_is_byte_identical(tmp_path):
    """The CLI/golden channel guarantee: no vault entries -> command() and run()
    behave exactly as before (the swap layer is inert)."""
    gen = _stub_generator(tmp_path)
    p = _key_file(tmp_path)
    cfg = _x86_cfg(tmp_path, gen, secureboot_key=p)
    d = BuildDriver(gen, host())
    assert ("--secureboot-key", p) in list(
        zip(d.command(cfg, "native"), d.command(cfg, "native")[1:]))
    assert d.run(cfg, "native") == 0
    assert (tmp_path / "out" / "received-key-path").read_text() == p


# ── preflight: a held selection satisfies the exists-check ─────────────────────────
def test_preflight_skips_missing_path_when_held(tmp_path):
    gen = _stub_generator(tmp_path)
    origin = _key_file(tmp_path)
    cfg = _x86_cfg(tmp_path, gen, secureboot_key=origin)
    d = BuildDriver(gen, host())
    secret_files.vault().hold("secureboot_key", origin)
    os.remove(origin)
    assert not any("secureboot-key" in p for p in d.preflight(cfg, "native"))
    # ...but only for the SAME origin: a different configured path still blocks
    cfg.secureboot_key = str(tmp_path / "nowhere.pem")
    assert any("secureboot-key path does not exist" in p
               for p in d.preflight(cfg, "native"))
    # ...and with no vault entry at all, the pre-existing block is untouched
    secret_files.vault().clear()
    cfg.secureboot_key = origin
    assert any("secureboot-key path does not exist" in p
               for p in d.preflight(cfg, "native"))


# ── session records + saved configs: content never persists ────────────────────────
def _held_worklist(tmp_path):
    origin = _key_file(tmp_path)
    secret_files.vault().hold("secureboot_key", origin)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      output_dir=str(tmp_path / "out"), secureboot_key=origin)
    return synthesize(cfg), origin


def test_session_record_names_held_files_but_never_their_content(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    wl, origin = _held_worklist(tmp_path)
    s = build_sessions.new_session(wl, str(tmp_path / "gen"))
    held = secret_files.vault().get("secureboot_key")
    assert s.held_secret_files == [
        {"field": "secureboot_key", "name": "kernel_key.pem", "sha256": held.sha256}]
    build_sessions.start(s)
    raw = open(s.path(), "rb").read()
    # the scan the feature promises: NO material in the persisted record — not the
    # PEM body, not any sentinel byte run; the one-way fingerprint IS there
    assert b"VAULT-SENTINEL" not in raw and KEY_PEM not in raw
    assert held.sha256.encode() in raw
    # the PATH contract is deliberately unchanged: the snapshot still carries it
    assert build_sessions.load(s.path()).worklist().base.secureboot_key == origin


def test_saved_config_carries_the_path_never_the_content(tmp_path):
    wl, origin = _held_worklist(tmp_path)
    cfg_path = tmp_path / "cfg.json"
    warnings = wl.save(str(cfg_path))
    assert warnings == []                       # held files add no password warning
    raw = cfg_path.read_bytes()
    assert b"VAULT-SENTINEL" not in raw and KEY_PEM not in raw
    assert json.loads(raw)["base"]["secureboot_key"] == origin


def test_held_records_gate_on_platform_emission(tmp_path, monkeypatch):
    """A pure-ARM worklist emits no x86-only signing flag, so its record must not
    demand a re-select on restart (that would be a false demand)."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    origin = _key_file(tmp_path)
    secret_files.vault().hold("secureboot_key", origin)
    base = ImageConfig(mode="standalone", role="generic", platform="rpi5",
                       output_dir=str(tmp_path / "out"), secureboot_key=origin)
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="generic", platform="rpi5")])
    s = build_sessions.new_session(wl, str(tmp_path / "gen"))
    assert s.held_secret_files == []


def test_fleet_session_has_no_held_files(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    from hugmesh_studio.core.fleet import FleetConfig
    s = build_sessions.new_fleet_session(FleetConfig(), str(tmp_path / "gen"))
    assert s.held_secret_files == []


def test_old_records_load_with_empty_held_list(tmp_path, monkeypatch):
    """Pre-feature records carry no held_secret_files key — from_dict tolerates."""
    s = build_sessions.BuildSession.from_dict({"id": "x", "status": "complete"})
    assert s.held_secret_files == []


# ── restart support ─────────────────────────────────────────────────────────────────
def test_missing_for_restart_is_exactly_the_unheld_subset(tmp_path):
    v = secret_files.vault()
    v.hold("secureboot_key", _key_file(tmp_path))
    records = [
        {"field": "secureboot_key", "name": "kernel_key.pem", "sha256": "aa"},
        {"field": "keys_usb", "name": "KEYS", "sha256": "bb"},
        {"field": "not_a_vault_field", "name": "x", "sha256": "cc"},   # hand-edited row
        "garbage",                                                      # tolerated
    ]
    missing = secret_files.missing_for_restart(records)
    assert missing == [{"field": "keys_usb", "name": "KEYS", "sha256": "bb"}]
    v.clear()
    assert [m["field"] for m in secret_files.missing_for_restart(records)] == [
        "secureboot_key", "keys_usb"]
    assert secret_files.missing_for_restart([]) == []
    assert secret_files.missing_for_restart(None) == []
