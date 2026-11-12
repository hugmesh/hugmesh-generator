"""GUI-20, the Qt-free half: what the wizard pages' inline refusals are built from.

The Network, Home and System steps used to accept a malformed apex domain, Tailscale
root domain, games domain, egress profile path, Local User or Default user on Next. The
build refused them pages later, at Review, as "Cannot assemble this build: invalid
local_user: 'Root User'". That message named the HOME step's config field for a value
typed on the SYSTEM step. The page-level refusals are pinned in
test_identity_inline_refusal_pages.py. This file pins the pieces they share, and it runs
in the Qt-free CI job:

* ``username_problem`` / ``domain_name_problem`` apply exactly the allowlists
  validate_identity applies, and name the CAPTION they are given;
* ``validate_identity`` names ``user`` (not ``local_user``) for -u, while every existing
  ``local_user`` message stays byte-identical;
* ``BuildDriver.missing_host_path`` is preflight's own existence test (relative =
  relative to the generator checkout, never the process cwd).
"""
import os

import pytest

from hugmesh_studio.core.build_driver import BuildDriver
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core.validate import (
    IdentityValidationError, domain_name_problem, username_problem,
    validate_domain_name, validate_username,
)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.mark.parametrize("value", ["Root User", "Bad User", "1abc", "", "a" * 33,
                                   "user;rm", "Magus"])
def test_username_problem_refuses_what_validate_username_refuses(value):
    with pytest.raises(IdentityValidationError):
        validate_username(value)
    msg = username_problem("Default user", value)
    assert msg.startswith("Default user: ")
    assert repr(value) in msg
    assert "local_user" not in msg


@pytest.mark.parametrize("value", ["rootuser", "_svc", "a" * 32, "pi", "walk-user_2"])
def test_username_problem_passes_what_validate_username_passes(value):
    validate_username(value)
    assert username_problem("Local User", value) == ""


@pytest.mark.parametrize("value", ["not a domain!", "Bad Root!", "games!", "UPPER.org",
                                   "-lead.org", "trail-.org", "a..b", "x,y.org", ""])
def test_domain_name_problem_refuses_what_validate_domain_name_refuses(value):
    with pytest.raises(IdentityValidationError):
        validate_domain_name(value)
    msg = domain_name_problem("Public Apex Domain", value)
    assert msg.startswith("Public Apex Domain: ")
    assert repr(value) in msg
    assert "invalid domain" not in msg      # the CLI wording stays the CLI's


@pytest.mark.parametrize("value", ["hugmesh.net", "example.org", "hugmesh.internal",
                                   "games.example.org", "a-b.c-d.e"])
def test_domain_name_problem_passes_what_validate_domain_name_passes(value):
    validate_domain_name(value)
    assert domain_name_problem("Tailscale Root Domain", value) == ""


def test_validate_identity_names_the_default_user_field_not_local_user():
    """THE Review-page half of the report: System 'Default user' = 'Root User' was
    refused as "invalid local_user: 'Root User'", naming the Home step's field."""
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      local_user="walker", user="Root User")
    with pytest.raises(IdentityValidationError) as exc:
        cfg.validate_identity()
    assert "invalid user: 'Root User'" in str(exc.value)
    assert "local_user" not in str(exc.value)


def test_local_user_messages_are_byte_identical():
    """The default stays: every existing --local-user refusal keeps its exact text."""
    with pytest.raises(IdentityValidationError) as exc:
        validate_username("Bad User")
    assert str(exc.value).startswith("invalid local_user: 'Bad User' — rejected by the "
                                     "identity allowlist")
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      local_user="Bad User")
    with pytest.raises(IdentityValidationError) as exc:
        cfg.validate_identity()
    assert "invalid local_user: 'Bad User'" in str(exc.value)


def test_missing_host_path_is_preflights_test(tmp_path, monkeypatch):
    """Relative means relative to the GENERATOR CHECKOUT (the build's cwd), never the
    Studio process's cwd; absolute is taken as is; '' means present."""
    drv = BuildDriver(GENERATOR_DIR, HOST)
    monkeypatch.chdir(tmp_path)             # a cwd where the relative name does NOT exist
    assert not os.path.exists("brand.conf.example")
    assert drv.missing_host_path("brand.conf.example") == ""
    gone = drv.missing_host_path("garbage endpoint")
    assert gone == os.path.join(GENERATOR_DIR, "garbage endpoint")
    real = tmp_path / "wg0.conf"
    real.write_text("[Interface]\n")
    assert drv.missing_host_path(str(real)) == ""
    assert drv.missing_host_path(str(tmp_path / "nope.conf")) == str(tmp_path / "nope.conf")


def test_missing_host_path_agrees_with_preflight(tmp_path):
    """The page's test and preflight's must answer the same for the egress field."""
    drv = BuildDriver(GENERATOR_DIR, HOST)
    for value, missing in (("garbage endpoint", True), ("brand.conf.example", False)):
        cfg = ImageConfig(mode="cloud", role="desktop", platform="x86", egress_vpn=value)
        said = [p for p in drv.preflight(cfg, backend="native")
                if p.startswith("egress-vpn path does not exist")]
        assert bool(said) is missing, (value, said)
        assert bool(drv.missing_host_path(value)) is missing
