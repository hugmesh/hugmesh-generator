"""KeyZipContents.apply_to must not INJECT out-of-scope payloads (finding 6).

Every assignment in apply_to is an injection: the value comes from the admin's zip, not
from anything the operator ticked, and KeyZipPage IS visited in mesh mode. So an admin zip
carrying an egress-VPN conf silently set cfg.egress_vpn on EVERY mesh node — no operator
action anywhere, no widget to notice it on. This is the SECOND path to finding 6, and the
nastier one: the NetworkPage row can at least be hidden, but nothing draws this.

WHY SKIPPING IS CORRECT HERE, and is not the "silently corrected an explicit value"
anti-pattern the WARN tier exists to prevent: nobody chose this value FOR THIS IMAGE. The
zip is a bundle of things the admin has, not a set of instructions for one build. Applying
a desktop payload to a node is the bug; declining to, and SAYING SO in the warnings channel
the wizard already renders, is the fix.

The builder is complicit and it is worth being precise about why studio must gate rather
than defer to it: build-x86-host-stage4.sh:3061 warns "--egress-vpn given for a non-desktop
role (${ROLE}); ... — ignoring", but "ignoring" is only half true. The STAGING leg :3064 is
role-gated; the PACKAGE leg :3572 (net-vpn/wireguard-tools, or networkmanager-openvpn +
openvpn for a .ovpn) and the CONFIG_WIREGUARD kernel fragment :3849 are NOT. The node
emerged the VPN userspace it was just told it would not use.
"""
from __future__ import annotations

import os

from snapdragon_studio.core.config import ImageConfig
from snapdragon_studio.core.keyzip import KeyZipContents


def _node() -> ImageConfig:
    return ImageConfig(platform="x86", role="be", mode="mesh", env="test")


def _desktop() -> ImageConfig:
    return ImageConfig(platform="x86", role="desktop", mode="cloud", env="test")


def test_egress_conf_not_injected_onto_a_mesh_node(tmp_path):
    """THE REGRESSION. Before the fix this was an unconditional `cfg.egress_vpn = ...`."""
    z = KeyZipContents(staging_dir=str(tmp_path), egress_conf=str(tmp_path / "wg0.conf"))
    cfg = _node()
    z.apply_to(cfg)
    assert cfg.egress_vpn == "", "admin key-zip injected an egress VPN onto a cluster node"
    assert "--egress-vpn" not in cfg.to_cli_args()


def test_declined_injection_is_reported_not_silent(tmp_path):
    """Skipping silently would trade one silent-wrong-image for a silent-missing-feature.
    The operator must be told the payload was recognized and deliberately not applied."""
    z = KeyZipContents(staging_dir=str(tmp_path), egress_conf=str(tmp_path / "wg0.conf"))
    z.apply_to(_node())
    assert any("Egress-VPN" in w and "NOT applied" in w for w in z.warnings), z.warnings


def test_egress_conf_still_injected_onto_a_desktop(tmp_path):
    """The other direction — the gate must not break the flow the key-zip exists for."""
    conf = str(tmp_path / "wg0.conf")
    z = KeyZipContents(staging_dir=str(tmp_path), egress_conf=conf)
    cfg = _desktop()
    z.apply_to(cfg)
    assert cfg.egress_vpn == conf
    assert z.warnings == []
    assert "--egress-vpn" in cfg.to_cli_args()


def test_branding_not_injected_onto_a_mesh_node(tmp_path):
    """Same injection shape, same class of bug: branding is desktop-class and never in
    mesh, and apply_to set branding_dir unconditionally too. Fixed via the same helper
    rather than a second one-off."""
    z = KeyZipContents(staging_dir=str(tmp_path), has_branding=True)
    cfg = _node()
    z.apply_to(cfg)
    assert cfg.branding_dir == ""
    assert any("Branding" in w and "NOT applied" in w for w in z.warnings), z.warnings


def test_branding_still_injected_onto_a_desktop(tmp_path):
    z = KeyZipContents(staging_dir=str(tmp_path), has_branding=True)
    cfg = _desktop()
    z.apply_to(cfg)
    assert cfg.branding_dir == os.path.join(str(tmp_path), "branding")
    assert z.warnings == []


def test_secureboot_material_is_never_scope_gated(tmp_path):
    """Deliberate NON-change, pinned so nobody "tidies" it into the gate: the SB signing
    chain is x86-wide and applies to NODES just as much as desktops (a pki node must boot
    under the fleet's enrolled key). Only the desktop-class payloads are gated."""
    z = KeyZipContents(staging_dir=str(tmp_path), keys_usb_dir=str(tmp_path / "keys"))
    cfg = _node()
    z.apply_to(cfg)
    assert cfg.keys_usb == str(tmp_path / "keys")
