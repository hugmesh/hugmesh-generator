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

from ca_fixtures import (CA_ALT, CA_FRAMED_NOT_DER, CA_ROOT,
                         HAVE_CRYPTOGRAPHY)
from hugmesh_studio import app
from hugmesh_studio.core.config import (
    PLATFORM_FIELD_SUPPORT, VAULT_FIELDS, ImageConfig, base_ca_certs_error,
    ca_cert_error, vault_field_error)
from hugmesh_studio.core.validate import IdentityValidationError

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
BUILDERS = ("build-x86-host-stage4.sh", "build-rpi5-stage4.sh")
PROVISION = os.path.join(GENERATOR_DIR, "specs", "etc", "keys-provision", "provision.sh")

ADDR = "https://vault.acme.example:8200"          # INTERNAL — the pre-#335 field
EXT = "https://vault.acme.example.com:8200"      # EXTERNAL (#335) — must differ


def _mesh(platform="x86", **kw):
    role = {"x86": "omnibus", "rpi5": "backend", "jetson": "edge-ai"}[platform]
    return ImageConfig(mode="mesh", role=role, platform=platform, tailscale=True,
                       brand="acme", **kw)


def pairs(args):
    return list(zip(args, args[1:]))


# ── the trio + the rule ──────────────────────────────────────────────────────────────
def test_the_quartet_is_the_capability_table_entry_on_the_two_node_builders():
    assert VAULT_FIELDS == ("vault_addr", "vault_external_addr", "vault_kv_mount",
                            "vault_base_path")
    for f in VAULT_FIELDS:
        assert set(PLATFORM_FIELD_SUPPORT[f]) == {"x86", "rpi5"}, f


def test_the_ca_fields_declare_no_builder_surface():
    """base_ca_certs / domain_ca (#335) are RECORDED ONLY. A capability-table entry
    would claim a builder flag that does not exist, and flag-coverage's REVERSE check
    would then demand a parser arm for it — the "knob that silently does nothing"
    failure mode caught one layer down. Absence here is the honest declaration."""
    assert "base_ca_certs" not in PLATFORM_FIELD_SUPPORT
    assert "domain_ca" not in PLATFORM_FIELD_SUPPORT


def test_empty_address_is_the_byte_identical_default():
    for platform in ("x86", "rpi5"):
        assert _mesh(platform).to_cli_args() == _mesh(platform, vault_addr="").to_cli_args()
        assert not any(a.startswith("--vault") for a in _mesh(platform).to_cli_args())


@pytest.mark.parametrize("bad, fragment", [
    (dict(vault_external_addr=EXT), "no Vault address"),
    (dict(vault_addr=ADDR, vault_external_addr="http://ext.acme.example"), "https://"),
    (dict(vault_addr=ADDR, vault_external_addr=ADDR), "same as the internal"),
    (dict(vault_addr=ADDR, vault_external_addr="https://ext.acme.example;rm -rf /"),
     "https://"),
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
                                         bad.get("vault_base_path", ""),
                                         bad.get("vault_external_addr", ""))
    with pytest.raises(IdentityValidationError, match="vault:"):
        _mesh(**bad).to_cli_args()


def test_valid_shapes_pass():
    for kw in (dict(vault_addr=ADDR),
               dict(vault_addr=ADDR, vault_kv_mount="kv-v2", vault_base_path="acme/prod"),
               dict(vault_addr=ADDR, vault_external_addr=EXT),
               dict(vault_addr="https://vault.vault.svc.cluster.local:8200",
                    vault_external_addr=EXT, vault_kv_mount="kv"),
               dict(vault_addr="https://vault.vault.svc.cluster.local:8200")):
        assert vault_field_error(kw["vault_addr"], kw.get("vault_kv_mount", ""),
                                 kw.get("vault_base_path", ""),
                                 kw.get("vault_external_addr", "")) == ""
        _mesh(**kw).to_cli_args()


def test_the_external_address_keeps_the_pre_335_three_argument_signature():
    """Every caller written before #335 passes three positionals — the builders'
    mirrored _validate_vault included. The fourth is keyword-last with an empty
    default, so the pre-#335 rule is exactly the post-#335 rule with no external
    address, and no caller had to be found and changed."""
    assert vault_field_error(ADDR, "kv", "acme/prod") == ""
    assert vault_field_error("", "kv", "") == vault_field_error("", "kv", "", "")


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


def test_the_external_address_is_omit_when_empty_on_the_argv():
    """#335's byte-identity half: adding the field changed no existing argv. A config
    with only the internal address emits exactly what it emitted before the field
    existed, and the external flag appears only when the operator set one."""
    for platform in ("x86", "rpi5"):
        only_internal = _mesh(platform, vault_addr=ADDR).to_cli_args()
        assert "--vault-external-addr" not in only_internal, platform
        both = _mesh(platform, vault_addr=ADDR, vault_external_addr=EXT).to_cli_args()
        assert ("--vault-external-addr", EXT) in pairs(both), platform
        # ...and it rides directly behind the internal one, so a reader of the printed
        # command line sees the pair together
        assert both.index("--vault-external-addr") == both.index("--vault-addr") + 2


def test_the_ca_list_and_the_per_domain_choice_emit_nothing_anywhere():
    """The honest half of #335: no builder parses a CA flag, so the Studio emits
    none. A config carrying a full certificate list and a per-domain choice produces
    the SAME argv as one carrying neither — and both faces' copy says so instead of
    implying an image change."""
    for platform in ("x86", "rpi5"):
        plain = _mesh(platform, vault_addr=ADDR).to_cli_args()
        loaded = _mesh(platform, vault_addr=ADDR, base_ca_certs=[CA_ROOT],
                       domain_ca={"acme.example": CA_ROOT}).to_cli_args()
        assert loaded == plain, platform
        assert not any("ca" == a.strip("-") or a.startswith("--base-ca")
                       or a.startswith("--domain-ca") for a in loaded)


def test_a_builder_that_parses_no_vault_flag_gets_none():
    args = _mesh("jetson", vault_addr=ADDR).to_cli_args()
    assert not any(a.startswith("--vault") for a in args)


# ── persistence + the headless CLI round-trip ────────────────────────────────────────
def test_save_load_round_trip(tmp_path):
    c = _mesh(vault_addr=ADDR, vault_external_addr=EXT, vault_kv_mount="kv",
              vault_base_path="acme/prod", base_ca_certs=[CA_ROOT],
              domain_ca={"acme.example": CA_ROOT})
    path = str(tmp_path / "cfg.json")
    c.save(path)
    d = json.load(open(path, encoding="utf-8"))
    assert {f: d[f] for f in VAULT_FIELDS} == {
        "vault_addr": ADDR, "vault_external_addr": EXT, "vault_kv_mount": "kv",
        "vault_base_path": "acme/prod"}
    # the CA surface is RECORDED — it must survive the save even though it emits nothing
    assert d["base_ca_certs"] == [CA_ROOT]
    assert d["domain_ca"] == {"acme.example": CA_ROOT}
    back = ImageConfig.load(path)
    assert (back.vault_addr, back.vault_external_addr, back.vault_kv_mount,
            back.vault_base_path) == (ADDR, EXT, "kv", "acme/prod")
    assert back.base_ca_certs == [CA_ROOT] and back.domain_ca == {"acme.example": CA_ROOT}
    assert back.to_cli_args() == c.to_cli_args()


def test_a_pre_224_config_loads_with_the_offline_default(tmp_path):
    d = _mesh().to_dict()
    for f in (*VAULT_FIELDS, "base_ca_certs", "domain_ca"):
        d.pop(f)
    c = ImageConfig.from_dict(d)
    assert (c.vault_addr, c.vault_external_addr, c.vault_kv_mount,
            c.vault_base_path) == ("", "", "", "")
    assert c.base_ca_certs == [] and c.domain_ca == {}
    assert c.to_cli_args() == _mesh().to_cli_args()


@pytest.mark.parametrize("junk", [None, "one.pem", 7])
def test_a_hand_edited_ca_list_loads_as_absent_not_as_a_string(junk):
    """The "domains": null tolerance, applied to #335's two containers: a null or a
    hand-typed scalar loads as the native empty default rather than constructing a
    config whose list field holds a string (which would then iterate per CHARACTER)."""
    d = _mesh().to_dict()
    d["base_ca_certs"] = junk
    d["domain_ca"] = junk
    c = ImageConfig.from_dict(d)
    assert c.base_ca_certs == [] and c.domain_ca == {}
    assert c.to_cli_args() == _mesh().to_cli_args()


def test_a_domain_naming_a_dropped_certificate_fails_closed():
    """The half-configured-trust rule, the vault_kv_mount-without-an-address twin: a
    domain may not point at a CA the config no longer carries."""
    with pytest.raises(IdentityValidationError, match="base CA"):
        _mesh(domain_ca={"acme.example": CA_ROOT}).to_cli_args()
    # ...and with the certificate present it validates
    _mesh(base_ca_certs=[CA_ROOT], domain_ca={"acme.example": CA_ROOT}).to_cli_args()
    # an explicit empty choice is the same as no choice
    _mesh(domain_ca={"acme.example": ""}).to_cli_args()


def test_a_certificate_that_is_not_one_is_refused_by_the_faces_predicate(tmp_path):
    """ca_cert_error is what the GUI picker and the TUI 'c' command call before a file
    can enter the list, so THAT is where a non-certificate is stopped."""
    bogus = tmp_path / "notacert.pem"
    bogus.write_text("hello, this is not a certificate\n", encoding="utf-8")
    assert "BEGIN CERTIFICATE" in ca_cert_error(str(bogus))
    assert "not a readable file" in ca_cert_error(str(tmp_path / "gone.pem"))
    assert ca_cert_error(CA_ROOT) == ""


@pytest.mark.skipif(not HAVE_CRYPTOGRAPHY,
                    reason="python-cryptography is optional; without it ca_cert_error "
                           "degrades to the framing-only check on purpose")
def test_pem_framing_alone_is_not_enough_to_be_a_certificate():
    """The gap the skeptic found: BEGIN CERTIFICATE over a body that is valid base64
    but is NOT DER ("hello world") used to be ACCEPTED, and the row then read "could
    not read its fields". With python-cryptography importable we parse for real and
    refuse it at the door, naming what actually went wrong."""
    err = ca_cert_error(CA_FRAMED_NOT_DER)
    assert err, "a framed non-certificate must be refused when we can tell"
    assert "not an X.509 certificate" in err
    assert "framed-not-der.pem" in err


def test_a_recorded_only_ca_path_can_never_block_a_build(tmp_path):
    """base_ca_certs reaches NO argv, no image and no manifest. So an unreadable path
    — a config written on another laptop, a volume not mounted this morning — must NOT
    raise at emission: it would stop a build that never depended on the file, and a
    headless/--print-command operator has no repair UI. Readability is checked by the
    two FACES, which can actually say something about it."""
    gone = str(tmp_path / "moved-away.pem")
    cfg = _mesh(base_ca_certs=[CA_ROOT, gone],
                domain_ca={"acme.example": gone})
    before = _mesh().to_cli_args()
    assert cfg.to_cli_args() == before          # validates, and emits nothing new
    cfg.validate_identity()
    # the face still refuses it, which is where the operator can act
    assert ca_cert_error(gone)


def test_the_structural_ca_rules_are_still_fail_closed():
    """What DOES still raise: facts that are wrong on every machine at every hour —
    a duplicate entry, a non-string entry, and a domain naming a certificate the
    config does not carry (that last one is its own test above)."""
    with pytest.raises(IdentityValidationError, match="listed twice"):
        _mesh(base_ca_certs=[CA_ROOT, CA_ROOT]).to_cli_args()
    with pytest.raises(IdentityValidationError, match="not a path"):
        _mesh(base_ca_certs=[CA_ROOT, 7]).to_cli_args()
    _mesh(base_ca_certs=[CA_ROOT, CA_ALT]).to_cli_args()      # the valid shape


def test_check_readable_is_the_only_difference_between_the_two_callers(tmp_path):
    """ONE predicate, one knob — never two rules that can drift. The faces get the
    readability check; validate_identity does not."""
    gone = str(tmp_path / "moved-away.pem")
    assert base_ca_certs_error([gone])                       # the faces refuse it
    assert base_ca_certs_error([gone], check_readable=False) == ""
    # the structural rules are on BOTH sides of the knob
    for kw in ({}, {"check_readable": False}):
        assert "listed twice" in base_ca_certs_error([CA_ROOT, CA_ROOT], **kw)
        assert "not a path" in base_ca_certs_error([None], **kw)
    assert base_ca_certs_error([]) == ""                      # the native default


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
    assert "--vault-external-addr" not in out


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
eval "$(grep -E '^(VAULT_ADDR|VAULT_EXTERNAL_ADDR|VAULT_KV_MOUNT|VAULT_BASE_PATH)="\$\{VAULT_|^(_IDP_URL_RE|_VAULT_PATH_RE)=' "${BUILDER}")"
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
    for k in ("VAULT_ADDR", "VAULT_EXTERNAL_ADDR", "VAULT_KV_MOUNT", "VAULT_BASE_PATH"):
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
def test_builder_bakes_the_external_address_beside_the_internal_one(builder, tmp_path):
    """#335's END-TO-END half: --vault-external-addr is not a recorded-in-cfg field,
    it reaches the ARTEFACT. The Studio's own argv goes through the builder's own
    parser arm and bake, and VAULT_EXTERNAL_ADDR comes back out of the baked
    /etc/hugmesh/vault.conf next to the internal address it belongs to."""
    platform = "x86" if builder.startswith("build-x86") else "rpi5"
    cfg = _mesh(platform, vault_addr=ADDR, vault_external_addr=EXT)
    r = _bake(builder, tmp_path, cfg.to_cli_args(), role="pki", brand="acme")
    assert r.returncode == 0, r.stderr + r.stdout
    conf = _conf(r.stdout)
    assert conf["VAULT_ADDR"] == ADDR
    assert conf["VAULT_EXTERNAL_ADDR"] == EXT
    assert conf["VAULT_KV_MOUNT"] == "secret" and conf["VAULT_BASE_PATH"] == "acme"
    assert "MODE: 644" in r.stdout


@pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")
@pytest.mark.parametrize("builder", BUILDERS)
def test_the_baked_file_is_byte_identical_without_an_external_address(builder, tmp_path):
    """The other half of OMIT-WHEN-EMPTY: a build that never named an external
    address writes the SAME vault.conf it wrote before #335 existed — not the same
    file with an empty VAULT_EXTERNAL_ADDR= line in it. Compared as the whole file,
    because an empty-valued line is exactly the regression this rules out."""
    platform = "x86" if builder.startswith("build-x86") else "rpi5"
    r = _bake(builder, tmp_path, _mesh(platform, vault_addr=ADDR).to_cli_args(),
              role="pki", brand="acme")
    assert r.returncode == 0, r.stderr + r.stdout
    assert "VAULT_EXTERNAL_ADDR" not in r.stdout
    assert _conf(r.stdout) == {"VAULT_ADDR": ADDR, "VAULT_KV_MOUNT": "secret",
                               "VAULT_BASE_PATH": "acme"}


@pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")
@pytest.mark.parametrize("builder", BUILDERS)
def test_builder_refuses_the_external_addresses_the_studio_refuses(builder, tmp_path):
    """_validate_vault's new arm mirrors vault_field_error's: same two refusals, at
    the builder too, so a hand-typed command line cannot get past what the GUI
    would have stopped."""
    for argv, why in (
            (["--vault-addr", ADDR, "--vault-external-addr", "http://ext.example"],
             "https"),
            (["--vault-addr", ADDR, "--vault-external-addr", ADDR], "same as")):
        r = _bake(builder, tmp_path, argv, role="pki")
        assert r.returncode != 0, argv
        assert "ERR:" in r.stderr and why in r.stderr, (argv, r.stderr)
        assert not (tmp_path / "etc" / "hugmesh" / "vault.conf").exists()


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
@pytest.mark.parametrize("builder", BUILDERS)
def test_first_boot_is_unchanged_by_the_external_address(builder, tmp_path):
    """The honest limit of the external address, PROVEN rather than asserted in a
    tooltip: keys-provision has no reader for VAULT_EXTERNAL_ADDR, so a node built
    with one resolves EXACTLY the same first-boot Vault source as one built without.
    If a future change gives it a reader, this test is what will fail and say so."""
    platform = "x86" if builder.startswith("build-x86") else "rpi5"
    got = []
    for kw in ({}, {"vault_external_addr": EXT}):
        sysroot = tmp_path / ("ext" if kw else "plain")
        r = _bake(builder, sysroot,
                  _mesh(platform, vault_addr=ADDR, vault_kv_mount="kv").to_cli_args()
                  if not kw else
                  _mesh(platform, vault_addr=ADDR, vault_kv_mount="kv", **kw).to_cli_args(),
                  role="pki", brand="acme")
        assert r.returncode == 0, r.stderr + r.stdout
        manifest = tmp_path / "provision.json"
        manifest.write_text(json.dumps({"hostname": "pki-1"}), encoding="utf-8")
        got.append(_resolve(manifest, sysroot / "etc" / "hugmesh" / "vault.conf"))
    assert got[0] == got[1]
    assert got[0]["ADDR"] == ADDR and got[0]["ENABLED"] == "true"


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
