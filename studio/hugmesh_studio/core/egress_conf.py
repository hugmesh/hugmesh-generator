"""Egress-VPN conf validation (Qt-free) — the Studio half of the fail-closed pact.

The local stack's egress-vpn container refuses to start on a missing or
unrecognized conf (tests/stack/wireguard/entrypoint.sh) — but that refusal lands
minutes into a stack-up. This validator applies the SAME recognition rules
up-front so the localmesh page can refuse to leave the box checked without a
usable file (operator ask 2026-08-14), and the sniff logic cannot drift: both
ends accept exactly a wg-quick .conf ([Interface] section) or an OpenVPN .ovpn
(client/remote directive).
"""
from __future__ import annotations

import os
import re

_WG_SECTION = re.compile(r"^\[Interface\]", re.MULTILINE)
_WG_PEER = re.compile(r"^\[Peer\]", re.MULTILINE)
_WG_KEY = re.compile(r"^\s*PrivateKey\s*=", re.MULTILINE | re.IGNORECASE)
_OVPN_DIRECTIVE = re.compile(r"^\s*(client\s*$|remote\s+\S+)", re.MULTILINE | re.IGNORECASE)


def validate_egress_conf(path: str) -> tuple[str, str]:
    """``(kind, error)`` — kind is ``"wireguard"`` / ``"openvpn"`` when error is
    ``""``. Errors are LAY-USER sentences: they are shown verbatim on the page."""
    if not path:
        return "", "No file selected."
    if not os.path.isfile(path):
        return "", "That file doesn't exist any more — pick it again."
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read(1 << 20)
    except OSError:
        return "", "That file can't be read (permissions?)."
    if not text.strip():
        return "", "That file is empty."
    if _WG_SECTION.search(text):
        if not _WG_KEY.search(text):
            return "", ("That looks like a WireGuard file but has no PrivateKey — "
                        "download the full config from your VPN provider.")
        if not _WG_PEER.search(text):
            return "", ("That looks like a WireGuard file but has no [Peer] section — "
                        "download the full config from your VPN provider.")
        return "wireguard", ""
    if _OVPN_DIRECTIVE.search(text):
        return "openvpn", ""
    return "", ("Not a VPN config this mesh understands — pick the WireGuard "
                "(.conf) or OpenVPN (.ovpn) file from your VPN provider.")
