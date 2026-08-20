#!/usr/bin/env bash
# mesh-identities.sh — THE reader of the planner's mesh identity file.
#
# SOURCED, never executed. Both host-side mesh lanes read the same file and must
# read it the same way, or "one identity source" would be one file with two
# meanings:
#
#   tests/qemu/mesh-cluster.sh    --identities FILE   (the 3-node driver)
#   tests/qemu/run-qemu-docker.sh --identities FILE   (the containerized fleet)
#
# The file is minted by the planner, which is where identities are DERIVED —
# nothing here or in its callers invents a MAC:
#
#   PYTHONPATH=studio python3 -m hugmesh_studio.core.mesh_emulation \
#       identities --out FILE
#
# Shape (studio/hugmesh_studio/core/mesh_emulation.py identities):
#   [{"label", "mac", "ip", "prefix_len", "subnet", "mesh_net"}, ...]
# The facade's `python -m hugmesh_studio.core.emulation plan --json` object is
# accepted too: its "devices" rows carry the same label/mac/ip, so an operator
# can pass whichever file they already have in hand.
#
# What this file does NOT do: decide policy. How many rows a lane needs, whether
# a missing row is fatal, which flag wins over the file — that is each lane's
# business and stays in each lane's script. This is the parse and the per-row
# sanity check, once.

# mesh_identity_lines FILE
#   -> one "label|mac|ip|prefix_len|mesh_net" line per device on stdout
#   -> non-zero, with the reason on stderr, for a file it cannot vouch for
#
# The pipe separator is safe by construction: every field is a label, a MAC, an
# IPv4 address, a small integer or an ADDR:PORT, none of which may contain '|'.
mesh_identity_lines() {
    local file="$1"
    if [ ! -f "${file}" ]; then
        echo "identities: no such file: ${file}" >&2
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "identities: python3 is needed to read ${file} (the file is JSON)" >&2
        return 1
    fi
    python3 - "${file}" <<'PYIDENT'
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
except (OSError, ValueError) as exc:
    sys.stderr.write("identities: cannot read %s: %s\n" % (path, exc))
    sys.exit(1)
# Either the bare identities array, or the facade's plan --json object around one.
rows = doc.get("devices") if isinstance(doc, dict) else doc
if not isinstance(rows, list) or not rows:
    sys.stderr.write("identities: %s holds no device rows\n" % path)
    sys.exit(1)
for idx, row in enumerate(rows, 1):
    if not isinstance(row, dict):
        sys.stderr.write("identities: row %d of %s is not an object\n" % (idx, path))
        sys.exit(1)
    mac, ip = str(row.get("mac") or ""), str(row.get("ip") or "")
    # A row with no identity is not a row a device can claim: emitting it with
    # blanks would push the failure down into whichever lane read it, and one of
    # those lanes would then boot a guest with no address on a shared wire.
    if not mac or not ip:
        sys.stderr.write("identities: row %d (%s) of %s carries no mac/ip\n"
                         % (idx, row.get("label") or "?", path))
        sys.exit(1)
    print("|".join([str(row.get("label") or ""), mac, ip,
                    str(row.get("prefix_len") or 24),
                    str(row.get("mesh_net") or "")]))
PYIDENT
}

# mesh_identity_check_row LABEL MAC IP PREFIX_LEN
#   -> 0 when the row can safely be given to a guest
#   -> 1, with the reason on STDOUT, otherwise (the caller supplies its own die)
#
# Every check here is about a failure that is SILENT on the wire: a multicast MAC
# is not a NIC address at all, two devices behind one MAC black-hole each other's
# frames, and an address outside the plan's mask cannot answer its peers. None of
# those announce themselves — the guest boots, ssh works over its loopback
# forward, and only the cluster it was supposed to join is missing a node.
mesh_identity_check_row() {
    local label="$1" mac="$2" ip="$3" plen="$4"
    if [ -z "${label}" ]; then
        echo "a row carries no label, so no device can claim it"; return 1
    fi
    if ! [[ "${mac}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        echo "${label}: '${mac}' is not a MAC address"; return 1
    fi
    if [ $(( 0x${mac%%:*} & 1 )) -ne 0 ]; then
        echo "${label}: ${mac} is a multicast MAC (first octet must be even)"; return 1
    fi
    if ! [[ "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "${label}: '${ip}' is not an IPv4 address"; return 1
    fi
    if ! [[ "${plen}" =~ ^[0-9]+$ ]] || [ "${plen}" -lt 8 ] || [ "${plen}" -gt 30 ]; then
        echo "${label}: prefix_len '${plen}' is not 8..30"; return 1
    fi
    return 0
}
