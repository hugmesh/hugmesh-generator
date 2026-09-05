"""Mesh secrets store (issue #224) — the Qt-free half: config fields, the fail-closed
rule, argv emission on exactly the two node builders, the headless CLI round-trip,
and the BUILDER HAND-OFF.

The last one is the point of the feature: a control that does not change the built
artefact is not the feature. So the hand-off tests do not stop at "the flag is on
the argv" — they feed the Studio's OWN emitted argv through the REAL builder's
``--vault-*`` parser arms and ``bake_vault_conf`` (extracted verbatim from
build-x86-host-stage4.sh / build-rpi5-stage4.sh, the test-idp-builder-functions.sh
idiom) into a fixture sysroot and read the configured address back out of the baked
/etc/hugmesh/vault.conf. Then the same file is handed to the REAL keys-provision
resolver (``resolve_vault_source`` from provision.sh) to prove first boot reads it
— and that a manifest ``.vault`` block still wins. No real build, no root, no
network; bash (and jq for the provisioner half) are the only host tools used.
"""
import json
import os
import shutil
import subprocess

import pytest

from hugmesh_studio import app
from hugmesh_studio.core.config import (
    PLATFORM_FIELD_SUPPORT, VAULT_FIELDS, ImageConfig, vault_field_error)
from hugmesh_studio.core.validate import IdentityValidationError

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
BUILDERS = ("build-x86-host-stage4.sh", "build-rpi5-stage4.sh")
PROVISION = os.path.join(GENERATOR_DIR, "specs", "etc", "keys-provision", "provision.sh")

ADDR = "https://vault.acme.example:8200"


def _mesh(platform="x86", **kw):
    role = {"x86": "omnibus", "rpi5": "backend", "jetson": "edge-ai"}[platform]
    return ImageConfig(mode="mesh", role=role, platform=platform, tailscale=True,
                       brand="acme", **kw)


def pairs(args):
    return list(zip(args, args[1:]))


# ── the trio + the rule ──────────────────────────────────────────────────────────────
def test_the_trio_is_the_capability_table_entry_on_the_two_node_builders():
    assert VAULT_FIELDS == ("vault_addr", "vault_kv_mount", "vault_base_path")
    for f in VAULT_FIELDS:
        assert set(PLATFORM_FIELD_SUPPORT[f]) == {"x86", "rpi5"}, f


def test_empty_address_is_the_byte_identical_default():
    for platform in ("x86", "rpi5"):
        assert _mesh(platform).to_cli_args() == _mesh(platform, vault_addr="").to_cli_args()
        assert not any(a.startswith("--vault") for a in _mesh(platform).to_cli_args())


@pytest.mark.parametrize("bad, fragment", [
    (dict(vault_addr="http://vault.acme.example"), "https://"),
    (dict(vault_addr="https://vault.acme.example;rm -rf /"), "https://"),
    (dict(vault_kv_mount="kv"), "no Vault address"),
    (dict(vault_base_path="acme"), "no Vault address"),
    (dict(vault_addr=ADDR, vault_kv_mount="a b"), "KV mount"),
    (dict(vault_addr=ADDR, vault_kv_mount="$(x)"), "KV mount"),
    (dict(vault_addr=ADDR, vault_base_path="/leading"), "base path"),
    (dict(vault_addr=ADDR, vault_base_path="x" * 129), "base path"),
])
def test_fail_closed_before_emission(bad, fragment):
    assert fragment in vault_field_error(bad.get("vault_addr", ""),
                                         bad.get("vault_kv_mount", ""),
                                         bad.get("vault_base_path", ""))
    with pytest.raises(IdentityValidationError, match="vault:"):
        _mesh(**bad).to_cli_args()


def test_valid_shapes_pass():
    for kw in (dict(vault_addr=ADDR),
               dict(vault_addr=ADDR, vault_kv_mount="kv-v2", vault_base_path="acme/prod"),
               dict(vault_addr="https://vault.vault.svc.cluster.local:8200")):
        assert vault_field_error(kw["vault_addr"], kw.get("vault_kv_mount", ""),
                                 kw.get("vault_base_path", "")) == ""
        _mesh(**kw).to_cli_args()


# ── emission: the two node builders, nothing else ────────────────────────────────────
def test_emission_shape_on_x86_and_rpi5():
    for platform in ("x86", "rpi5"):
        args = _mesh(platform, vault_addr=ADDR).to_cli_args()
        assert ("--vault-addr", ADDR) in pairs(args), platform
        assert "--vault-kv-mount" not in args and "--vault-base-path" not in args
        full = _mesh(platform, vault_addr=ADDR, vault_kv_mount="kv",
                     vault_base_path="acme/prod").to_cli_args()
        assert ("--vault-kv-mount", "kv") in pairs(full), platform
        assert ("--vault-base-path", "acme/prod") in pairs(full), platform


def test_a_builder_that_parses_no_vault_flag_gets_none():
    args = _mesh("jetson", vault_addr=ADDR).to_cli_args()
    assert not any(a.startswith("--vault") for a in args)


# ── persistence + the headless CLI round-trip ────────────────────────────────────────
def test_save_load_round_trip(tmp_path):
    c = _mesh(vault_addr=ADDR, vault_kv_mount="kv", vault_base_path="acme/prod")
    path = str(tmp_path / "cfg.json")
    c.save(path)
    d = json.load(open(path, encoding="utf-8"))
    assert {f: d[f] for f in VAULT_FIELDS} == {
        "vault_addr": ADDR, "vault_kv_mount": "kv", "vault_base_path": "acme/prod"}
    back = ImageConfig.load(path)
    assert (back.vault_addr, back.vault_kv_mount, back.vault_base_path) == \
        (ADDR, "kv", "acme/prod")
    assert back.to_cli_args() == c.to_cli_args()


def test_a_pre_224_config_loads_with_the_offline_default(tmp_path):
    d = _mesh().to_dict()
    for f in VAULT_FIELDS:
        d.pop(f)
    c = ImageConfig.from_dict(d)
    assert (c.vault_addr, c.vault_kv_mount, c.vault_base_path) == ("", "", "")
    assert c.to_cli_args() == _mesh().to_cli_args()


def test_print_command_carries_the_vault_flags(tmp_path, capsys):
    """The CLI face: a config JSON with the trio set prints a builder command line
    carrying exactly the flags the GUI would emit — one emitter, three faces."""
    path = str(tmp_path / "cfg.json")
    _mesh(vault_addr=ADDR, vault_kv_mount="kv").save(path)
    assert app.main(["--print-command", "--config", path, "--backend", "native"]) == 0
    out = capsys.readouterr().out
    assert f"--vault-addr {ADDR}" in out
    assert "--vault-kv-mount kv" in out
    assert "--vault-base-path" not in out


def test_print_command_refuses_a_half_configured_store(tmp_path, capsys):
    path = str(tmp_path / "cfg.json")
    d = _mesh().to_dict()
    d["vault_kv_mount"] = "kv"                     # a mount with nowhere to point
    json.dump(d, open(path, "w", encoding="utf-8"))
    rc = app.main(["--print-command", "--config", path, "--backend", "native"])
    assert rc != 0
    assert "no Vault address" in capsys.readouterr().err


# ── the BUILDER HAND-OFF: Studio argv -> real parser arms -> real bake -> artefact ───
_HARNESS = r'''
set -uo pipefail
BUILDER="$1"; SYSROOT="$2"; shift 2
extract_fn() { awk "/^$1\\(\\) \\{/{p=1} p{print} /^\\}/{if(p){exit}}" "$2"; }
info() { echo "INFO: $*"; }
warn() { echo "WARN: $*"; }
err()  { echo "ERR: $*" >&2; }
# the builder's OWN defaults + regexes, the two functions, verbatim
# (the DEFINITION lines only — `VAULT_*="${VAULT_*:-…}"` — never the column-0
# `VAULT_*=${_mount}` lines inside bake_vault_conf's own heredoc)
eval "$(grep -E '^(VAULT_ADDR|VAULT_KV_MOUNT|VAULT_BASE_PATH)="\$\{VAULT_|^(_IDP_URL_RE|_VAULT_PATH_RE)=' "${BUILDER}")"
eval "$(extract_fn _validate_vault "${BUILDER}")"
eval "$(extract_fn bake_vault_conf "${BUILDER}")"
# the builder's OWN --vault-* parser arms, wrapped in a loop of our own
arms="$(awk '/^while \[\[? *"?\$#"? /{p=1} p{print} p&&/^done/{exit}' "${BUILDER}" \
        | grep -E '^[[:space:]]*--vault-[a-z-]+\)')"
[ -n "${arms}" ] || { echo "ERR: no --vault-* parser arms in ${BUILDER}" >&2; exit 3; }
eval "parse_vault_args() { while [[ \$# -gt 0 ]]; do case \"\$1\" in
${arms}
*) shift ;;
esac; done; }"
parse_vault_args "$@"
_validate_vault
bake_vault_conf
if [ -f "${SYSROOT}/etc/hugmesh/vault.conf" ]; then
    echo "MODE: $(stat -c %a "${SYSROOT}/etc/hugmesh/vault.conf")"
    cat "${SYSROOT}/etc/hugmesh/vault.conf"
else
    echo "NOFILE"
fi
'''


def _bake(builder, sysroot, argv, *, role="pki", client=False, brand="acme", env_extra=None):
    env = dict(os.environ, ROLE=role, ROLE_CLIENT="true" if client else "false",
               BRAND=brand)
    # the Studio's own build env can carry the vault CLI's VAULT_* (the Vaults dialog
    # reads them) — pin each case explicitly rather than inherit the test runner's
    for k in ("VAULT_ADDR", "VAULT_KV_MOUNT", "VAULT_BASE_PATH"):
        env.pop(k, None)
    env.update(env_extra or {})
    return subprocess.run(
        ["bash", "-c", _HARNESS, "harness", os.path.join(GENERATOR_DIR, builder),
         str(sysroot), *argv],
        capture_output=True, text=True, env=env, timeout=60)


def _conf(stdout):
    return dict(ln.split("=", 1) for ln in stdout.splitlines()
                if "=" in ln and not ln.startswith("#") and ln[0].isupper()
                and not ln.startswith(("MODE:", "INFO:", "WARN:")))


@pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")
@pytest.mark.parametrize("builder", BUILDERS)
def test_builder_bakes_the_studio_configured_address(builder, tmp_path):
    """END TO END without a build: the Studio's emitted argv, the builder's own
    parser arms, the builder's own bake — and the configured value comes back out
    of the artefact's /etc/hugmesh/vault.conf."""
    platform = "x86" if builder.startswith("build-x86") else "rpi5"
    cfg = _mesh(platform, vault_addr=ADDR, vault_kv_mount="kv", vault_base_path="acme/prod")
    argv = [a for a in cfg.to_cli_args()]
    r = _bake(builder, tmp_path, argv, role="pki")
    assert r.returncode == 0, r.stderr + r.stdout
    conf = _conf(r.stdout)
    assert conf["VAULT_ADDR"] == cfg.vault_addr
    assert conf["VAULT_KV_MOUNT"] == "kv"
    assert conf["VAULT_BASE_PATH"] == "acme/prod"
    assert "MODE: 644" in r.stdout
    assert "token" not in "\n".join(ln for ln in r.stdout.splitlines()
                                    if ln[0:1].isupper() and "=" in ln)


@pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")
@pytest.mark.parametrize("builder", BUILDERS)
def test_builder_fills_its_own_defaults_for_the_two_paths(builder, tmp_path):
    """Address only (the common case): the builder supplies mount 'secret' and the
    brand slug as base path — the layout scripts/gen-cluster-secrets.sh writes."""
    platform = "x86" if builder.startswith("build-x86") else "rpi5"
    r = _bake(builder, tmp_path, _mesh(platform, vault_addr=ADDR).to_cli_args(),
              role="backend", brand="acme")
    assert r.returncode == 0, r.stderr + r.stdout
    conf = _conf(r.stdout)
    assert conf == {"VAULT_ADDR": ADDR, "VAULT_KV_MOUNT": "secret", "VAULT_BASE_PATH": "acme"}


@pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")
@pytest.mark.parametrize("builder", BUILDERS)
def test_builder_default_bakes_nothing(builder, tmp_path):
    platform = "x86" if builder.startswith("build-x86") else "rpi5"
    r = _bake(builder, tmp_path, _mesh(platform).to_cli_args(), role="pki")
    assert r.returncode == 0, r.stderr
    assert "NOFILE" in r.stdout


@pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")
@pytest.mark.parametrize("builder", BUILDERS)
def test_builder_falls_back_to_the_profile_when_no_flag_is_emitted(builder, tmp_path):
    """The builder-side convention every knob follows (built-in < env < brand.conf <
    CLI): with NO --vault-addr on the argv (the wizard's empty page), a brand
    profile's VAULT_ADDR still bakes, the CLI still wins over it, and the wizard copy
    says exactly that instead of promising "nothing is baked" unconditionally."""
    platform = "x86" if builder.startswith("build-x86") else "rpi5"
    profile = {"VAULT_ADDR": "https://profile.example:8200", "VAULT_KV_MOUNT": "brandkv"}
    r = _bake(builder, tmp_path / "a", _mesh(platform).to_cli_args(), role="pki",
              env_extra=profile)
    assert r.returncode == 0, r.stderr
    assert _conf(r.stdout) == {"VAULT_ADDR": "https://profile.example:8200",
                               "VAULT_KV_MOUNT": "brandkv", "VAULT_BASE_PATH": "acme"}
    r = _bake(builder, tmp_path / "b", _mesh(platform, vault_addr=ADDR).to_cli_args(),
              role="pki", env_extra=profile)
    assert r.returncode == 0, r.stderr
    assert _conf(r.stdout)["VAULT_ADDR"] == ADDR                  # CLI wins
    assert _conf(r.stdout)["VAULT_KV_MOUNT"] == "brandkv"         # untouched knob keeps the profile


@pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")
@pytest.mark.parametrize("builder", BUILDERS)
def test_builder_warn_drops_the_flag_on_a_client_role(builder, tmp_path):
    platform = "x86" if builder.startswith("build-x86") else "rpi5"
    r = _bake(builder, tmp_path, _mesh(platform, vault_addr=ADDR).to_cli_args(),
              role="desktop", client=True)
    assert r.returncode == 0, r.stderr
    assert "NOFILE" in r.stdout
    assert "WARN:" in r.stdout and "client role" in r.stdout


@pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")
@pytest.mark.parametrize("builder", BUILDERS)
def test_builder_refuses_what_the_studio_refuses(builder, tmp_path):
    """The builder's _validate_vault is the same rule as vault_field_error — a value
    the Studio would never emit dies at the builder too (defence in depth)."""
    for argv in (["--vault-addr", "http://vault.acme.example"],
                 ["--vault-addr", ADDR, "--vault-kv-mount", "a b"],
                 ["--vault-addr", ADDR, "--vault-base-path", "$(x)"]):
        r = _bake(builder, tmp_path, argv, role="pki")
        assert r.returncode != 0, argv
        assert "ERR:" in r.stderr, argv
        assert not (tmp_path / "etc" / "hugmesh" / "vault.conf").exists()


# ── the FIRST-BOOT HAND-OFF: the baked file reaches keys-provision ───────────────────
_PROVISION_HARNESS = r'''
set -uo pipefail
PROV="$1"; MANIFEST="$2"; export VAULT_IMAGE_CONF="$3"
extract_fn() { awk "/^$1\\(\\) \\{/{p=1} p{print} /^\\}/{if(p){exit}}" "$2"; }
log() { echo "LOG: $*"; }
warn() { echo "WARN: $*"; }
jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }
jqe()  { jq -e "$1" "${MANIFEST}" >/dev/null 2>&1; }
eval "$(extract_fn vault_conf_get "${PROV}")"
eval "$(extract_fn resolve_vault_source "${PROV}")"
resolve_vault_source
echo "SRC=${VAULT_SRC}"
echo "ADDR=${vault_address}"
echo "MOUNT=${vault_kv_mount}"
echo "BASE=${vault_base_path}"
echo "TOKEN=${vault_token_file}"
echo "ENABLED=${vault_enabled}"
'''


def _resolve(manifest, conf):
    r = subprocess.run(["bash", "-c", _PROVISION_HARNESS, "harness", PROVISION,
                        str(manifest), str(conf)],
                       capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr + r.stdout
    return dict(ln.split("=", 1) for ln in r.stdout.splitlines() if "=" in ln)


needs_jq = pytest.mark.skipif(shutil.which("jq") is None or shutil.which("bash") is None,
                              reason="needs bash + jq (the provisioner's own tools)")


@needs_jq
@pytest.mark.parametrize("builder", BUILDERS)
def test_first_boot_reads_the_baked_file_when_the_manifest_has_no_vault_block(
        builder, tmp_path):
    """The whole chain: Studio argv -> builder bake -> the REAL provision.sh resolver
    picks the image-baked facts up on a stick whose provision.json says nothing
    about Vault (the shape of all three shipped per-role example manifests)."""
    platform = "x86" if builder.startswith("build-x86") else "rpi5"
    sysroot = tmp_path / "sysroot"
    r = _bake(builder, sysroot, _mesh(platform, vault_addr=ADDR, vault_kv_mount="kv").to_cli_args(),
              role="pki", brand="acme")
    assert r.returncode == 0, r.stderr
    manifest = tmp_path / "provision.json"
    manifest.write_text(json.dumps({"hostname": "pki-1"}), encoding="utf-8")
    got = _resolve(manifest, sysroot / "etc" / "hugmesh" / "vault.conf")
    assert got == {"SRC": "image", "ADDR": ADDR, "MOUNT": "kv", "BASE": "acme",
                   "TOKEN": "vault/token", "ENABLED": "true"}


@needs_jq
def test_a_manifest_vault_block_still_wins_over_the_baked_file(tmp_path):
    conf = tmp_path / "vault.conf"
    conf.write_text(f"VAULT_ADDR={ADDR}\nVAULT_KV_MOUNT=kv\nVAULT_BASE_PATH=acme\n",
                    encoding="utf-8")
    manifest = tmp_path / "provision.json"
    manifest.write_text(json.dumps({"vault": {
        "enabled": True, "address": "https://stick.example:8200", "kv_mount": "m",
        "base_path": "b", "token_file": "vault/other-token"}}), encoding="utf-8")
    got = _resolve(manifest, conf)
    assert got == {"SRC": "manifest", "ADDR": "https://stick.example:8200", "MOUNT": "m",
                   "BASE": "b", "TOKEN": "vault/other-token", "ENABLED": "true"}


@needs_jq
def test_no_manifest_block_and_no_baked_file_is_the_historical_skip(tmp_path):
    manifest = tmp_path / "provision.json"
    manifest.write_text(json.dumps({"hostname": "n"}), encoding="utf-8")
    got = _resolve(manifest, tmp_path / "absent.conf")
    assert got["SRC"] == "" and got["ENABLED"] == "false"


@needs_jq
def test_the_baked_file_is_read_not_sourced(tmp_path):
    """A stray line in the conf can execute nothing: the reader is a keyed lookup."""
    conf = tmp_path / "vault.conf"
    marker = tmp_path / "executed"
    conf.write_text(f"touch {marker}\nVAULT_ADDR=\"{ADDR}\"\n$(touch {marker})\n",
                    encoding="utf-8")
    manifest = tmp_path / "provision.json"
    manifest.write_text("{}", encoding="utf-8")
    got = _resolve(manifest, conf)
    assert got["SRC"] == "image" and got["ADDR"] == ADDR
    assert got["MOUNT"] == "secret" and got["BASE"] == "hugmesh"   # the provisioner's own defaults
    assert not marker.exists()
