"""#588 — keys-provision imports the KEYS stick's ``certs/`` folder for EVERY manifest.

The Studio's cloud Domains step tells the operator (``CLIENT_CA_INHERITANCE_NOTE``,
core/config.py) that at first boot keys-provision imports every certificate in the
stick's ``certs/`` folder into the system trust store, so a client trusts exactly the
certificate authorities on the stick it was provisioned with. Until this branch that
was untrue for every CLIENT stick: the only import sat at the tail of
``provision_files()``, below that function's ``jqe '.files' || return 0`` — and the
client manifests (KEYS profile ``host``: desktop, laptop, chromebook —
keys-template/examples/provision.host.json) and the frontend profile carry no ``files``
key, so a desktop provisioned from such a stick never trusted the mesh CA on it. The
text pin in test_client_ca_inheritance.py stayed green the whole time: it looked for
the ``cp`` lines anywhere in the script.

So this file EXECUTES the import: the real ``provision_files()`` and ``provision_certs()``
are cut out of specs/etc/keys-provision/provision.sh and run in main()'s order, with
every side-effecting command replaced by a logger, against the example manifests —
the client ones (no ``files`` list) must import, the backend one (a ``files`` list)
must import exactly as before — and main()'s call order is pinned so no manifest
class skips the step. tests/boot/emulate-firstboot.sh runs the unstubbed engine in a
container for the same contract, and tests/qemu/verify-client.sh asserts it on a real
client image over its console and SSH.
"""
import json
import os
import re
import shutil
import subprocess

import pytest

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
PROVISION = os.path.join(GENERATOR_DIR, "specs", "etc", "keys-provision", "provision.sh")
EXAMPLES = os.path.join(GENERATOR_DIR, "keys-template", "examples")


def _read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def _function_body(src, name):
    m = re.search(r"^%s\(\) \{\n(.*?)^\}\n" % re.escape(name), src, re.S | re.M)
    assert m, f"{name}() not found — the script moved it; re-derive this pin"
    return m.group(1)


# ── the step exists, on its own, and provision_files no longer carries it ────────────
def test_the_import_is_its_own_step_and_not_inside_provision_files():
    """The import lives in ``provision_certs`` and nowhere else: not in
    ``provision_files``, whose ``.files`` early return used to hide it from every
    manifest without a files list."""
    src = _read(PROVISION)
    certs = _function_body(src, "provision_certs")
    for needle in ('cp -f "${BASE}/certs/"*.crt /usr/local/share/ca-certificates/',
                   'cp -f "${BASE}/certs/"*.pem /usr/local/share/ca-certificates/',
                   'cp -f "${BASE}/certs/"*.key /etc/ssl/keys/',
                   "if jqe '.files'; then",
                   "update-ca-certificates"):
        assert needle in certs, (
            f"keys-provision no longer does {needle!r} in provision_certs — the client "
            "trust path the cloud Domains step describes (CLIENT_CA_INHERITANCE_NOTE) "
            "has changed")
    assert 'cp -f "${BASE}/certs/"' not in _function_body(src, "provision_files")


# ── the import, EXECUTED ─────────────────────────────────────────────────────────────
# Run the REAL provision_files() and provision_certs() out of provision.sh, in main()'s
# order, with every side-effecting command replaced by a logger, against the stick
# layouts and example manifests below.
_HARNESS = r"""
set -u
log(){ echo "LOG  $*"; }; warn(){ echo "WARN $*"; }
have(){ return 0; }
mkdir(){ echo "CALL mkdir $*"; }
cp(){ echo "CALL cp $*"; }
chmod(){ echo "CALL chmod $*"; }
chown(){ echo "CALL chown $*"; }
update-ca-certificates(){ echo "CALL update-ca-certificates"; }
"""


def _run_import(src, base, manifest):
    """stdout of provision_files() then provision_certs() (main()'s order) from the
    given provision.sh text, with the stubs above, on stick ``base`` + ``manifest``."""
    assert shutil.which("jq"), "jq is required: provision.sh's own hard dependency"
    parts = [_HARNESS]
    for name in ("jqm", "jqe"):
        m = re.search(r"^%s\(\)\s*\{.*$" % name, src, re.M)
        assert m, f"{name}() not found in provision.sh"
        parts.append(m.group(0))
    for fn in ("provision_files", "provision_certs"):
        parts.append(fn + "() {\n" + _function_body(src, fn) + "}")
    parts += ["declare -F provision_files provision_certs jqm jqe >/dev/null || exit 9",
              'provision_files; echo "provision_files rc=$?"',
              'provision_certs; echo "provision_certs rc=$?"']
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "BASE": base,
           "MANIFEST": manifest}
    p = subprocess.run(["bash", "-c", "\n".join(parts)], capture_output=True,
                       text=True, env=env, timeout=60)
    assert p.returncode == 0, p.stdout + p.stderr
    return p.stdout


def _stick(tmp_path, with_certs=True, names=("cluster-ca.crt", "extra.pem")):
    base = tmp_path / "stick"
    (base / "certs").mkdir(parents=True)
    if with_certs:
        for name in names:
            (base / "certs" / name).write_text(
                "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n")
    return str(base)


def _manifest(example):
    path = os.path.join(EXAMPLES, example)
    with open(path, encoding="utf-8") as fh:
        return path, json.load(fh)


@pytest.mark.parametrize("example", ["provision.host.json", "provision.frontend.json"])
def test_a_stick_without_a_files_list_still_gets_its_certificates_imported(tmp_path,
                                                                          example):
    """The client stick (KEYS profile `host`: desktop, laptop, chromebook) and the
    frontend profile carry no `files` key. Before this branch the only importer
    returned before the import on exactly these manifests: zero copies."""
    path, manifest = _manifest(example)
    assert "files" not in manifest, example
    base = _stick(tmp_path)
    out = _run_import(_read(PROVISION), base, path)
    assert f"CALL cp -f {base}/certs/cluster-ca.crt /usr/local/share/ca-certificates/" in out
    assert f"CALL cp -f {base}/certs/extra.pem /usr/local/share/ca-certificates/" in out
    assert "CALL update-ca-certificates" in out
    assert "LOG  Imported certificates from KEYS/certs" in out
    assert "provision_files rc=0" in out and "provision_certs rc=0" in out


def test_a_manifest_with_a_files_list_imports_exactly_as_before(tmp_path):
    """The backend example carries a files list: its bulk import is unchanged (the
    same copies, after the listed files, then update-ca-certificates)."""
    path, manifest = _manifest("provision.backend.json")
    assert manifest.get("files"), "the backend example lost its files list"
    base = _stick(tmp_path)
    out = _run_import(_read(PROVISION), base, path)
    lines = out.splitlines()
    files_done = lines.index("provision_files rc=0")
    crt = next(i for i, ln in enumerate(lines)
               if ln == f"CALL cp -f {base}/certs/cluster-ca.crt /usr/local/share/ca-certificates/")
    assert files_done < crt < lines.index("CALL update-ca-certificates")


def test_a_stick_without_certificates_imports_nothing(tmp_path):
    path, _manifest_ = _manifest("provision.host.json")
    out = _run_import(_read(PROVISION), _stick(tmp_path, with_certs=False), path)
    assert "CALL cp" not in out and "update-ca-certificates" not in out
    assert "provision_certs rc=0" in out


def test_a_stick_whose_only_certificate_is_a_pem_still_imports_it(tmp_path):
    """The note promises ``*.crt and *.pem``; the step's guard must see a stick that
    carries only a .pem (a guard on ``*.crt`` alone would skip it)."""
    path, _manifest_ = _manifest("provision.host.json")
    base = _stick(tmp_path, names=("only.pem",))
    out = _run_import(_read(PROVISION), base, path)
    assert f"CALL cp -f {base}/certs/only.pem /usr/local/share/ca-certificates/" in out
    assert "CALL update-ca-certificates" in out
    assert "LOG  Imported certificates from KEYS/certs" in out


def test_a_private_key_on_a_files_manifest_stick_lands_in_etc_ssl_keys_mode_0600(tmp_path):
    """A manifest WITH a files list (backend / control plane) keeps what it always had:
    ``certs/*.key`` into /etc/ssl/keys at mode 0600."""
    path, manifest = _manifest("provision.backend.json")
    assert manifest.get("files"), "the backend example lost its files list"
    base = _stick(tmp_path, names=("cluster-ca.crt", "node.key"))
    out = _run_import(_read(PROVISION), base, path)
    assert f"CALL cp -f {base}/certs/node.key /etc/ssl/keys/" in out
    assert "CALL chmod 0600 /etc/ssl/keys/" in out
    assert "CALL mkdir -p /etc/ssl/keys" in out
    assert "CALL mkdir -p /usr/local/share/ca-certificates" in out


@pytest.mark.parametrize("example", ["provision.host.json", "provision.frontend.json"])
def test_a_client_or_frontend_stick_never_gets_a_private_key_copied(tmp_path, example):
    """The widened import is trust anchors only. A client stick that carries
    certs/cluster-ca.key (pki custody material) must NOT put that key under
    /etc/ssl/keys; its certificates are still imported."""
    path, manifest = _manifest(example)
    assert "files" not in manifest, example
    base = _stick(tmp_path, names=("cluster-ca.crt", "cluster-ca.key"))
    out = _run_import(_read(PROVISION), base, path)
    assert "/etc/ssl/keys" not in out, out
    assert ".key" not in out, out
    assert f"CALL cp -f {base}/certs/cluster-ca.crt /usr/local/share/ca-certificates/" in out
    assert "CALL update-ca-certificates" in out


def test_a_stick_with_no_provision_json_never_gets_a_private_key_copied(tmp_path):
    """Standalone images and bare sticks run with MANIFEST=/dev/null: the CA
    certificate is imported, no private key is copied."""
    base = _stick(tmp_path, names=("cluster-ca.crt", "cluster-ca.key"))
    out = _run_import(_read(PROVISION), base, "/dev/null")
    assert "/etc/ssl/keys" not in out and ".key" not in out, out
    assert f"CALL cp -f {base}/certs/cluster-ca.crt /usr/local/share/ca-certificates/" in out


def test_main_imports_the_certificates_for_every_manifest_right_after_the_files():
    """main() calls provision_certs once, at top level (not inside the
    `if ! ${STANDALONE_IMG}` block), right after provision_files and before
    provision_truststore — so no manifest class skips the import."""
    body = _function_body(_read(PROVISION), "main")
    calls = re.findall(r"^    (provision_[a-z_]+)\b", body, re.M)
    assert calls.count("provision_certs") == 1, calls
    assert (calls.index("provision_files") + 1 == calls.index("provision_certs")
            < calls.index("provision_truststore")), calls
    assert body.index("    provision_certs") < body.index("if ! ${STANDALONE_IMG}; then")


# ── the engine-level proofs name the same contract ──────────────────────────────────
def test_the_first_boot_emulation_and_the_client_image_check_assert_the_import():
    """tests/boot/emulate-firstboot.sh (the unstubbed engine in a container, every
    role, manifests WITHOUT a files list) and tests/qemu/verify-client.sh (a real
    client image: console log line, and the file + trust-store link over SSH) carry
    the certificate assertions — pinned so a later edit cannot quietly drop them."""
    emu = _read(os.path.join(GENERATOR_DIR, "tests", "boot", "emulate-firstboot.sh"))
    for needle in ("certs/cluster-ca.crt", "extra.pem",
                   "Imported certificates from KEYS/certs", "/etc/ssl/certs/cluster-ca.pem",
                   "ca-certificates"):
        assert needle in emu, needle
    vc = _read(os.path.join(GENERATOR_DIR, "tests", "qemu", "verify-client.sh"))
    for needle in ("KEYS certs imported|Imported certificates from KEYS/certs",
                   "KEYS cert file in trust store", "KEYS cert linked by update-ca-certificates",
                   "/usr/local/share/ca-certificates/cluster-ca.crt"):
        assert needle in vc, needle
