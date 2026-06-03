#!/usr/bin/env bash
# gen-provision-keys.sh — populate a KEYS provisioning directory with real
# secrets (SSH keypair + SHA-512 password hashes) by editing copies of the
# templates. Output is a ready-to-write directory you hand to make-keys-usb.sh.
#
# No root required. Requires: jq, openssl, ssh-keygen.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUT_DIR="${REPO_DIR}/keys-out"
TEMPLATE="${REPO_DIR}/keys-template"
ADMIN="admin"
ROLE="pki"
RANDOM_PW=false

usage() {
cat <<EOF
Usage: $0 [OPTIONS]

  Builds a filled-in KEYS directory (default: ${OUT_DIR}) from the template,
  generating an SSH keypair and SHA-512 password hashes.

Options:
  -o, --out DIR       Output directory. Default: ${OUT_DIR}
  -t, --template DIR  Template to copy. Default: ${TEMPLATE}
  -u, --admin NAME    Admin username. Default: admin
  -r, --role ROLE     pki | backend | frontend | host. Default: pki
                      pki = FULL config + default user accounts; workers = KEYS ONLY (no users.json).
      --random        Generate random passwords (printed once) instead of prompting.
  -h, --help          Show this help.

Then write the stick:  sudo ./scripts/make-keys-usb.sh /dev/sdX ${OUT_DIR}
EOF
exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--out)      OUT_DIR="$2"; shift 2 ;;
        -t|--template) TEMPLATE="$2"; shift 2 ;;
        -u|--admin)    ADMIN="$2"; shift 2 ;;
        -r|--role)     ROLE="$2"; shift 2 ;;
        --random)      RANDOM_PW=true; shift ;;
        -h|--help)     usage 0 ;;
        *)             echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

for t in openssl ssh-keygen python3; do
    command -v "$t" >/dev/null || { echo "ERROR: missing tool: $t" >&2; exit 1; }
done
[ -d "${TEMPLATE}" ] || { echo "ERROR: template not found: ${TEMPLATE}" >&2; exit 1; }

echo "==> Building ${OUT_DIR} from ${TEMPLATE} (role=${ROLE})"
rm -rf "${OUT_DIR}"
cp -r "${TEMPLATE}" "${OUT_DIR}"
find "${OUT_DIR}" -name 'README.md' -delete 2>/dev/null || true

# Select the role-specific manifest
case "${ROLE}" in
    pki) : ;;  # provision.json is already the pki example (full config + users)
    backend|frontend|host)
        cp "${OUT_DIR}/examples/provision.${ROLE}.json" "${OUT_DIR}/provision.json" ;;
    *) echo "ERROR: --role must be pki|backend|frontend|host" >&2; exit 1 ;;
esac
rm -rf "${OUT_DIR}/examples"

# ── SSH keypair (break-glass) ──────────────────────────────────────
mkdir -p "${OUT_DIR}/ssh"
KEYFILE="${OUT_DIR}/ssh/${ADMIN}_ed25519"
[ -f "${KEYFILE}" ] || { echo "==> Generating ed25519 keypair for ${ADMIN}"; ssh-keygen -t ed25519 -N '' -C "${ADMIN}@snapdragon" -f "${KEYFILE}" >/dev/null; }
PUBKEY="$(cat "${KEYFILE}.pub")"

if [ "${ROLE}" = "pki" ]; then
    # ── pki node: FULL config — default user accounts + hashed passwords ──
    cp "${KEYFILE}.pub" "${OUT_DIR}/ssh/${ADMIN}.authorized_keys"
    gen_hash() {
        local who="$1" pw
        if ${RANDOM_PW}; then pw="$(openssl rand -base64 18)"; echo "  ${who} password: ${pw}" >&2
        else read -rsp "Password for ${who}: " pw; echo >&2; fi
        openssl passwd -6 "${pw}"
    }
    echo "==> Setting password hashes (pki node)"
    ADMIN_HASH="$(gen_hash "${ADMIN}")"; ROOT_HASH="$(gen_hash root)"
    USERS="${OUT_DIR}/users.json"
    python3 - "${USERS}" "${ADMIN}" "${ADMIN_HASH}" "${PUBKEY}" "${ROOT_HASH}" <<'PY'
import json, sys
f, name, h, key, rh = sys.argv[1:6]
d = json.load(open(f))
d.setdefault("users", [{}])
d["users"][0].update({"name": name, "password_hash": h, "ssh_authorized_keys": [key]})
d.setdefault("root", {})["password_hash"] = rh
json.dump(d, open(f, "w"), indent=2)
PY
    echo; echo "Done (pki — config node). Generated:"
    echo "  ${OUT_DIR}/users.json            (default accounts: admin '${ADMIN}' + root, hashed)"
    echo "  ${OUT_DIR}/provision.json        (all-services config for the cluster)"
    echo "  ${OUT_DIR}/ssh/${ADMIN}_ed25519       (PRIVATE key — keep safe)"
else
    # ── worker node: KEYS ONLY — no default users; break-glass root key only ──
    # Default user accounts live ONLY on the pki node's USB. A worker carries
    # keys (cluster join + CA + mesh authkey + break-glass SSH), joins the pki
    # control-plane, and receives all config + secrets from there.
    rm -f "${OUT_DIR}/users.json"
    cp "${KEYFILE}.pub" "${OUT_DIR}/ssh/root.authorized_keys"
    echo; echo "Done (worker '${ROLE}' — keys only, no users.json). Generated:"
    echo "  ${OUT_DIR}/provision.json        (join/mesh/CA keys only — fill in the join token + CA hash)"
    echo "  ${OUT_DIR}/ssh/root.authorized_keys   (break-glass SSH; ${ADMIN}_ed25519 is the private key)"
    echo "  Add: kubernetes/pki/ca.crt, kubernetes join token, tailscale/authkey, certs/cluster-ca.crt"
fi

# ── Per-API JKS keystores + cluster truststore ─────────────────────
# The cluster CA + per-service mTLS keystores + the Java truststore are
# generated on the pki/config node. Workers receive only the CA cert +
# truststore (copy keystores/truststore.* and certs/cluster-ca.crt from the
# pki node's output); the per-service keystores are pushed to Vault by
# scripts/gen-cluster-secrets.sh and synced into the namespaces.
if [ "${ROLE}" = "pki" ]; then
    echo; echo "==> Generating per-API JKS keystores + truststore (cluster CA)"
    bash "${SCRIPT_DIR}/gen-keystores.sh" "${OUT_DIR}"
    echo "  keystores in ${OUT_DIR}/keystores (push to Vault: ./scripts/gen-cluster-secrets.sh)"
else
    echo "  (worker) copy the cluster CA + truststore from the pki node:"
    echo "    pki:${OUT_DIR}/certs/cluster-ca.crt        -> certs/cluster-ca.crt"
    echo "    pki:${OUT_DIR}/keystores/truststore.jks    -> keystores/truststore.jks"
fi

echo
echo "Next:"
echo "  1. Review ${OUT_DIR}/provision.json"
echo "  2. sudo ./scripts/make-keys-usb.sh /dev/sdX ${OUT_DIR}"
echo "  3. ssh -i ${OUT_DIR}/ssh/${ADMIN}_ed25519 <user>@<node-address>"
