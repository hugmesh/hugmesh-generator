#!/usr/bin/env bash
# gen-provision-keys.sh — populate a KEYS provisioning directory with real
# secrets (SSH keypair + SHA-512 password hashes) by editing copies of the
# templates. Output is a ready-to-write directory you hand to make-keys-usb.sh.
#
# No root required. Requires: jq, openssl, ssh-keygen.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# brand.conf / brands/<BRAND>.conf may set CA_CERT/CA_KEY/CA_KEY_PASS (and BRAND).
# Source them so the pki-role kubeadm-CA seeding decision below sees a CA set via
# a profile; env + CLI flags (parsed later) still take precedence.
[ -f "${REPO_DIR}/brand.conf" ] && . "${REPO_DIR}/brand.conf" || true
if [ -n "${BRAND:-}" ] && [ -f "${REPO_DIR}/brands/${BRAND}.conf" ]; then
  # shellcheck disable=SC1090
  . "${REPO_DIR}/brands/${BRAND}.conf"
fi

OUT_DIR="${REPO_DIR}/keys-out"
TEMPLATE="${REPO_DIR}/keys-template"
ADMIN="admin"
ROLE="pki"
RANDOM_PW=false

# Optional EXISTING CA to use as the issuer for the generated mTLS certs (passed
# through to gen-keystores.sh). May also be set via env or brand.conf / brands/.
CA_CERT="${CA_CERT:-}"
CA_KEY="${CA_KEY:-}"
CA_KEY_PASS="${CA_KEY_PASS:-}"

usage() {
cat <<EOF
Usage: $0 [OPTIONS]

  Builds a filled-in KEYS directory (default: ${OUT_DIR}) from the template,
  generating an SSH keypair and SHA-512 password hashes.

Options:
  -o, --out DIR       Output directory. Default: ${OUT_DIR}
  -t, --template DIR  Template to copy. Default: ${TEMPLATE}
  -u, --admin NAME    Admin username. Default: admin
  -r, --role ROLE     pki | backend | frontend | host | control-plane-additional. Default: pki
                      (control-plane-additional = a 2nd/3rd HA control-plane that
                       kubeadm join --control-plane's the existing cluster)
                      pki = FULL config + default user accounts; workers = KEYS ONLY (no users.json).
      --random        Generate random passwords (printed once) instead of prompting.
      --ca-cert FILE  Use an EXISTING CA cert (PEM) as the issuer for the mTLS
                      certs (forwarded to gen-keystores.sh). Default: self-signed.
      --ca-key FILE   Private key for --ca-cert (PEM; may be encrypted).
      --ca-key-pass V Passphrase for --ca-key (prefer CA_KEY_PASS env over this).
  -h, --help          Show this help.

  CA_CERT / CA_KEY / CA_KEY_PASS may also come from the env or brand.conf /
  brands/<BRAND>.conf. When a CA is provided, the pki role also seeds it as the
  kubeadm CA (kubernetes/pki/ca.{crt,key}) so the control plane shares it.

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
        --ca-cert)     CA_CERT="$2"; shift 2 ;;
        --ca-key)      CA_KEY="$2"; shift 2 ;;
        --ca-key-pass) CA_KEY_PASS="$2"; shift 2 ;;
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
    control-plane-additional)
        # Additional HA control-plane: kubeadm join --control-plane (needs the
        # first CP's token + ca_cert_hash + certificate_key + shared kubernetes/pki).
        cp "${OUT_DIR}/examples/provision.control-plane-additional.json" "${OUT_DIR}/provision.json" ;;
    *) echo "ERROR: --role must be pki|backend|frontend|host|control-plane-additional" >&2; exit 1 ;;
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
        else
            if ! read -t 10 -rsp "Password for ${who} (10s, default=random): " pw || [ -z "${pw}" ]; then
                pw="$(openssl rand -base64 18)"
                echo "  (timeout/empty -> random ${who} password: ${pw})" >&2
            fi
            echo >&2
        fi
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
    # Forward an EXISTING CA, if one was provided, so every minted mTLS leaf is
    # signed by it (and the truststore bundles it). Passed as flags; CA_KEY_PASS
    # is exported (read via `-passin env:` downstream) so it never hits argv.
    KS_CA_ARGS=()
    if [ -n "${CA_CERT}" ] || [ -n "${CA_KEY}" ]; then
        KS_CA_ARGS=(--ca-cert "${CA_CERT}" --ca-key "${CA_KEY}")
        [ -n "${CA_KEY_PASS}" ] && export CA_KEY_PASS
    fi
    bash "${SCRIPT_DIR}/gen-keystores.sh" "${OUT_DIR}" "${KS_CA_ARGS[@]}"
    echo "  keystores in ${OUT_DIR}/keystores (push to Vault: ./scripts/gen-cluster-secrets.sh)"

    # Optional: feed the SAME external CA to kubeadm so the k8s control-plane CA
    # equals the cluster mTLS CA. kubeadm uses an external CA when ca.crt+ca.key
    # are present in /etc/kubernetes/pki BEFORE `kubeadm init`; keys-provision
    # copies kubernetes/pki/* there at first boot. Guarded behind CA-provided;
    # without it the operator-generated kubeadm certs path is unchanged.
    if [ -n "${CA_CERT}" ] && [ -n "${CA_KEY}" ]; then
        echo "==> Seeding the provided CA as the kubeadm control-plane CA (kubernetes/pki/ca.{crt,key})"
        mkdir -p "${OUT_DIR}/kubernetes/pki"
        cat "${CA_CERT}" > "${OUT_DIR}/kubernetes/pki/ca.crt"
        if [ -n "${CA_KEY_PASS}" ]; then
            # Decrypt to the unencrypted ca.key kubeadm needs; the key never
            # appears on argv (env: passin) and is locked to 0600.
            openssl pkey -in "${CA_KEY}" -passin env:CA_KEY_PASS \
                -out "${OUT_DIR}/kubernetes/pki/ca.key" 2>/dev/null \
                || { echo "ERROR: failed to decrypt CA key for kubeadm seeding" >&2; exit 1; }
        else
            cat "${CA_KEY}" > "${OUT_DIR}/kubernetes/pki/ca.key"
        fi
        chmod 0600 "${OUT_DIR}/kubernetes/pki/ca.key" 2>/dev/null || true
        echo "    kubeadm will sign control-plane certs off this CA (external-CA mode)."
    fi
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
