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
  -r, --role ROLE     pki | backend | frontend (selects example manifest). Default: pki
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

for t in jq openssl ssh-keygen; do
    command -v "$t" >/dev/null || { echo "ERROR: missing tool: $t" >&2; exit 1; }
done
[ -d "${TEMPLATE}" ] || { echo "ERROR: template not found: ${TEMPLATE}" >&2; exit 1; }

echo "==> Building ${OUT_DIR} from ${TEMPLATE} (role=${ROLE})"
rm -rf "${OUT_DIR}"
cp -r "${TEMPLATE}" "${OUT_DIR}"
find "${OUT_DIR}" -name 'README.md' -delete 2>/dev/null || true

# Select the role-specific manifest
case "${ROLE}" in
    pki) : ;;  # provision.json is already the pki example
    backend|frontend)
        cp "${OUT_DIR}/examples/provision.${ROLE}.json" "${OUT_DIR}/provision.json" ;;
    *) echo "ERROR: --role must be pki|backend|frontend" >&2; exit 1 ;;
esac
rm -rf "${OUT_DIR}/examples"

# ── SSH keypair ────────────────────────────────────────────────────
KEYFILE="${OUT_DIR}/ssh/${ADMIN}_ed25519"
mkdir -p "${OUT_DIR}/ssh"
if [ ! -f "${KEYFILE}" ]; then
    echo "==> Generating ed25519 keypair for ${ADMIN}"
    ssh-keygen -t ed25519 -N '' -C "${ADMIN}@snapdragon" -f "${KEYFILE}" >/dev/null
fi
PUBKEY="$(cat "${KEYFILE}.pub")"
cp "${KEYFILE}.pub" "${OUT_DIR}/ssh/${ADMIN}.authorized_keys"

# ── Passwords ──────────────────────────────────────────────────────
gen_hash() {
    local who="$1" pw
    if ${RANDOM_PW}; then
        pw="$(openssl rand -base64 18)"
        echo "  ${who} password: ${pw}" >&2
    else
        read -rsp "Password for ${who}: " pw; echo >&2
    fi
    openssl passwd -6 "${pw}"
}
echo "==> Setting password hashes"
ADMIN_HASH="$(gen_hash "${ADMIN}")"
ROOT_HASH="$(gen_hash root)"

# ── Inject into users.json ─────────────────────────────────────────
USERS="${OUT_DIR}/users.json"
tmp="$(mktemp)"
jq --arg name "${ADMIN}" --arg hash "${ADMIN_HASH}" --arg key "${PUBKEY}" --arg rhash "${ROOT_HASH}" '
  .users[0].name = $name
  | .users[0].password_hash = $hash
  | .users[0].ssh_authorized_keys = [$key]
  | .root.password_hash = $rhash
' "${USERS}" > "${tmp}" && mv "${tmp}" "${USERS}"

echo
echo "Done. Generated:"
echo "  ${OUT_DIR}/users.json            (admin '${ADMIN}' + root, hashed)"
echo "  ${OUT_DIR}/ssh/${ADMIN}_ed25519       (PRIVATE key — keep safe, ssh in with this)"
echo "  ${OUT_DIR}/ssh/${ADMIN}.authorized_keys"
echo
echo "Next:"
echo "  1. Review ${OUT_DIR}/provision.json (hostname, domain, headscale/k8s)"
echo "  2. sudo ./scripts/make-keys-usb.sh /dev/sdX ${OUT_DIR}"
echo "  3. ssh -i ${OUT_DIR}/ssh/${ADMIN}_ed25519 ${ADMIN}@<pi-address>"
