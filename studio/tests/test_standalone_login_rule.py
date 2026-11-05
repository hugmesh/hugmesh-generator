"""The Qt-free half of the standalone login rule (see test_home_login_password.py for
the page): which images have no login but the build-time local password, and the
build preflight refusing such an image when that password is missing.

Operator report (2026-10-30): the password typed in the GUI did not log in to a
standalone image. Root is locked there and there is no KEYS stick or SSO, so building
one with no password produces an image nobody can log in to; a config reloaded from
disk always has an empty password (SECRET_FIELDS are blanked on save), so the Review
page's preflight is where that is caught.
"""
import os

import pytest

from hugmesh_studio.core.build_driver import BuildDriver
from hugmesh_studio.core.config import (
    UNAFFILIATED_ROLE, ImageConfig, standalone_login_problem, standalone_login_required,
)
from hugmesh_studio.core.platform_info import HostInfo

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")
PW = "correct horse battery"


@pytest.mark.parametrize("cfg_kw,required", [
    (dict(mode="standalone", role="standalone-thick", platform="x86"), True),
    (dict(mode="standalone", role="standalone-thin", platform="x86"), True),
    (dict(mode="standalone", role=UNAFFILIATED_ROLE, platform="x86"), True),
    (dict(mode="standalone", role="rpi5-desktop", platform="rpi5", standalone=True), True),
    # headless appliance: its serial console shows the one-time password, a usable login
    (dict(mode="standalone", role="orangepizero2", platform="orangepizero2",
          standalone=True), False),
    (dict(mode="cloud", role="client", platform="x86"), False),
    (dict(mode="mesh", role="pki", platform="x86"), False),
])
def test_standalone_login_required_matches_the_builder_posture(cfg_kw, required):
    assert standalone_login_required(ImageConfig(**cfg_kw)) is required


def test_problem_text_names_the_missing_piece():
    c = ImageConfig(mode="standalone", role=UNAFFILIATED_ROLE, platform="x86",
                    local_user="magus", local_pass="")
    assert "Login Password" in standalone_login_problem(c)
    c.local_pass = PW
    assert standalone_login_problem(c) == ""
    c.local_user = "  "
    assert "Local User" in standalone_login_problem(c)
    assert standalone_login_problem(ImageConfig(mode="cloud", role="client",
                                                platform="x86")) == ""


def test_build_preflight_refuses_a_standalone_image_with_no_password():
    drv = BuildDriver(GENERATOR_DIR, HOST)
    c = ImageConfig(mode="standalone", role=UNAFFILIATED_ROLE, platform="x86",
                    local_user="magus", local_pass="")
    msg = standalone_login_problem(c)
    assert msg and msg in drv.preflight(c, backend="native")
    c.local_pass = PW
    assert msg not in drv.preflight(c, backend="native")
    assert not any("Login Password" in p for p in drv.preflight(c, backend="native"))
