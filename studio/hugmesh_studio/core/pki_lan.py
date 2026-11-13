"""The pki node's LAN address: the one rule every face and every mesh route uses.

WHY THIS EXISTS. A worker's first boot happens before go-live, when no public name
answers. Its KEYS stick told it to dial the baked public HEADSCALE_URL first, so on a
LAN-first mesh with no public DNS, IP or port-forward the worker never reached the
control plane. keys-provision now dials the pki node on the LAN until go-live
(``resolve_control_endpoint``), but only at an address the operator CONFIRMED:
``provision.json .mesh.pki_lan_ip``, which ``scripts/gen-provision-keys.sh --pki-ip``
stamps on every stick. The template's pki row (10.0.0.10) is example data.

That address must not move, so the Studio requires it with a static IP or a DHCP
reservation behind it, and says why. No mDNS: a ``.local`` name resolves only where
multicast DNS works on that LAN, and a worker that cannot resolve it at first boot has
no other way to find the control plane.

Qt-free: the Network page, the Fleet page, the TUI and the build drivers all call
:func:`problem` / :func:`ip_error` and show the same words.
"""
from __future__ import annotations

import ipaddress

#: The field labels, the same on both faces.
LABEL_IP = "PKI LAN Address"
LABEL_FIXED = "This address is fixed (a static IP or a DHCP reservation on the router)"

#: Shown under the row on both faces and in every refusal.
WHY = ("Before go-live there is no public address, so every other node joins the "
       "mesh by dialling the PKI node on your local network. Give the PKI node a "
       "static IP, or reserve its address in your router's DHCP settings, and enter "
       "that address here. It is written onto every node's KEYS stick, so if it "
       "changes later the nodes can no longer find the control plane. A .local "
       "(mDNS) name is not accepted: it does not resolve on every network at first "
       "boot.")

_PRIVATE = (ipaddress.ip_network("10.0.0.0/8"),
            ipaddress.ip_network("172.16.0.0/12"),
            ipaddress.ip_network("192.168.0.0/16"))


def ip_error(value: str) -> str:
    """"" when ``value`` is a usable pki LAN address (a dotted-quad IPv4 in an RFC1918
    range); otherwise the reason, in the operator's words. Empty is not an error HERE
    (an unset field is :func:`problem`'s business, mesh-only)."""
    v = (value or "").strip()
    if not v:
        return ""
    if v.endswith(".local") or any(c.isalpha() for c in v):
        return (f"{v!r} is a name, not an address — enter the PKI node's IPv4 address "
                "(mDNS .local names are not used: they do not resolve on every "
                "network at first boot)")
    parts = v.split(".")
    if len(parts) != 4 or not all(p.isdigit() and len(p) <= 3 for p in parts):
        return f"{v!r} is not an IPv4 address (four numbers separated by dots)"
    try:
        ip = ipaddress.IPv4Address(".".join(str(int(p)) for p in parts))
    except ValueError:
        return f"{v!r} is not an IPv4 address (each number is 0-255)"
    if not any(ip in n for n in _PRIVATE):
        return (f"{v} is not a private LAN address — use the PKI node's address on "
                "your local network (10.x.x.x, 172.16-31.x.x or 192.168.x.x)")
    return ""


def canonical(value: str) -> str:
    """``value`` without surrounding space or leading zeros ("" stays "")."""
    v = (value or "").strip()
    if not v or ip_error(v):
        return v
    return ".".join(str(int(p)) for p in v.split("."))


def problem(cfg) -> str:
    """"" when ``cfg`` may make KEYS sticks; otherwise the refusal. Applies to a mesh
    only (``cfg.mode == "mesh"``): an image that joins no mesh has no pki to dial."""
    if getattr(cfg, "mode", "") != "mesh":
        return ""
    ip = (getattr(cfg, "pki_lan_ip", "") or "").strip()
    if not ip:
        return (f"{LABEL_IP} is required for a mesh. " + WHY)
    err = ip_error(ip)
    if err:
        return f"{LABEL_IP}: {err}."
    if not getattr(cfg, "pki_lan_ip_fixed", False):
        return (f"{LABEL_IP} {canonical(ip)}: confirm it is fixed — a static IP or a "
                "DHCP reservation. " + WHY)
    return ""


def genkeys_args(cfg) -> list[str]:
    """The ``gen-provision-keys.sh`` arguments for ``cfg`` (``--pki-ip ADDR`` on a mesh
    with a valid address, else nothing)."""
    if getattr(cfg, "mode", "") != "mesh":
        return []
    ip = (getattr(cfg, "pki_lan_ip", "") or "").strip()
    if not ip or ip_error(ip):
        return []
    return ["--pki-ip", canonical(ip)]
