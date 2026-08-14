"""core.egress_conf — the Studio half of the egress-vpn fail-closed pact. Its
recognition rules must match tests/stack/wireguard/entrypoint.sh's sniff:
[Interface] => wg-quick, client/remote => OpenVPN, anything else refused."""
import os

from hugmesh_studio.core.egress_conf import validate_egress_conf

_WG = """[Interface]
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=
AllowedIPs = 0.0.0.0/0
Endpoint = 185.159.157.1:51820
"""

_OVPN = """client
dev tun
proto udp
remote nl.vpnprovider.example 1194
resolv-retry infinite
<ca>
-----BEGIN CERTIFICATE-----
-----END CERTIFICATE-----
</ca>
"""


def _write(tmp_path, name, text):
    p = tmp_path / name
    p.write_text(text)
    return str(p)


def test_wireguard_conf_recognized(tmp_path):
    assert validate_egress_conf(_write(tmp_path, "wg0.conf", _WG)) == ("wireguard", "")


def test_openvpn_conf_recognized(tmp_path):
    assert validate_egress_conf(_write(tmp_path, "nl.ovpn", _OVPN)) == ("openvpn", "")


def test_missing_empty_and_junk_are_refused_with_lay_sentences(tmp_path):
    for path, needle in (
        ("", "No file selected"),
        (str(tmp_path / "gone.conf"), "doesn't exist"),
        (_write(tmp_path, "empty.conf", "   \n"), "empty"),
        (_write(tmp_path, "junk.conf", "hello world\n"), "Not a VPN config"),
    ):
        kind, err = validate_egress_conf(path)
        assert kind == "" and needle in err, (path, err)


def test_truncated_wireguard_is_refused(tmp_path):
    # provider "config" downloads sometimes truncate — a [Interface] with no key
    # or peer would make the container start and then fail; refuse it up front.
    kind, err = validate_egress_conf(
        _write(tmp_path, "half.conf", "[Interface]\nAddress = 10.2.0.2/32\n"))
    assert kind == "" and "PrivateKey" in err
    kind, err = validate_egress_conf(
        _write(tmp_path, "nopeer.conf",
               "[Interface]\nPrivateKey = x=\nAddress = 10.2.0.2/32\n"))
    assert kind == "" and "[Peer]" in err


def test_entrypoint_sniff_rules_match_this_validator():
    """The container decides wg-vs-ovpn by grepping [Interface] then
    client/remote; pin those greps so the two ends cannot drift apart."""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ep = open(os.path.join(root, "tests", "stack", "wireguard", "entrypoint.sh")).read()
    assert "grep -q '^\\[Interface\\]'" in ep
    assert "client|remote" in ep
