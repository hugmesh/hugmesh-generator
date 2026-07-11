#!/usr/bin/env bash
# gen-provision-keys.sh — populate a KEYS provisioning directory with real
# secrets (SSH keypair + SHA-512 password hashes) by editing copies of the
# templates. Output is a ready-to-write directory you hand to make-keys-usb.sh.
#
# In-UI SSH-terminal key model (default ON; GEN_DEVICE_SSH=false to skip), it ALSO
# mints, per device, the two keypairs the BFF-dialed in-UI SSH terminal needs:
#   keys-out/ssh/host/ssh_host_ed25519_key{,.pub}  device sshd HOST keypair, BAKED
#       into the image by provision_ssh_host_keys() (stable host id the BFF PINS).
#   keys-out/ssh/<dial_user>.authorized_keys       BFF DIAL PUBLIC key (baked into
#       the dial user's authorized_keys so the BFF can auth) — PUBLIC only.
#   keys-out/vault-seed/device/<id>/ssh/dial_private_key   BFF DIAL PRIVATE key —
#       ⇒ VAULT ONLY. NEVER baked into an image, NEVER bundled onto the KEYS stick
#       (make-keys-usb.sh strips vault-seed/), NEVER logged. The per-device
#       ExternalSecret (specs/cluster/.../device-ssh-externalsecret.tpl.yaml)
#       mounts it into the BFF.
#   keys-out/vault-seed/device/<id>/ingest.json    NON-secret metadata (host_key_fp,
#       dial_pub_fp, dial_user, public keys) the image-gen Job POSTs to the BFF.
#
# No root required. Requires: jq, openssl, ssh-keygen, python3.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# brand.conf / brands/<BRAND>.conf may set CA_CERT/CA_KEY/CA_KEY_PASS (and BRAND).
# Source them so the pki-role kubeadm-CA seeding decision below sees a CA set via
# a profile; env + CLI flags (parsed later) still take precedence.
# A MISSING brand.conf is fine (it is optional); a PRESENT one that fails to
# source is FATAL — silently continuing would bake the wrong brand/CA.
if [ -f "${REPO_DIR}/brand.conf" ]; then
  # shellcheck disable=SC1091
  . "${REPO_DIR}/brand.conf" \
    || { echo "ERROR: failed to source ${REPO_DIR}/brand.conf — fix or remove it (refusing to bake the wrong brand/CA)" >&2; exit 1; }
fi
if [ -n "${BRAND:-}" ] && [ -f "${REPO_DIR}/brands/${BRAND}.conf" ]; then
  # shellcheck disable=SC1090
  . "${REPO_DIR}/brands/${BRAND}.conf" \
    || { echo "ERROR: failed to source ${REPO_DIR}/brands/${BRAND}.conf" >&2; exit 1; }
fi

OUT_DIR="${REPO_DIR}/keys-out"
TEMPLATE="${REPO_DIR}/keys-template"
ADMIN="admin"
ROLE="pki"
RANDOM_PW=false

# ── Root password (OPTIONAL, default OFF — hardened posture) ────────
# By DEFAULT no root password is generated: root login is LOCKED on the image
# (the pki users.json carries .root.locked=true -> provision.sh runs `passwd -l
# root`, no hash) and the worker break-glass key is the only path in. Only when
# GEN_ROOT_PASSWORD=true (env / brand.conf) or --root-password is passed do we
# generate a root password and store it SALTED+HASHED in users.json — NEVER
# echoed in plaintext. Precedence: built-in (false) < brand.conf < CLI flag.
GEN_ROOT_PASSWORD="${GEN_ROOT_PASSWORD:-false}"

# ── Superadmin sudo (ALWAYS on for the privileged user; password-gated) ─────
# The privileged login/SSH user on the PRIMARY images is the SUPERADMIN, and
# with root login LOCKED by default sudo is its ONLY escalation path — so the
# generated users.json ALWAYS grants that user sudo (provision.sh writes
# /etc/sudoers.d/10-<user>). By DEFAULT sudo is PASSWORD-GATED (the device/
# superadmin password), NOT NOPASSWD. Set SUDO_NOPASSWD=true (env/brand.conf) or
# pass --sudo-nopasswd to opt into NOPASSWD. Precedence: built-in (false) <
# brand.conf < CLI flag.
# TODO(admin-mesh-extension): when the image_builder admin mesh-extension build
# path lands, that flow likewise grants the building ADMIN host-scoped sudo
# (same users.json .sudo=true mechanism, scoped to the admin's domain).
SUDO_NOPASSWD="${SUDO_NOPASSWD:-false}"

# ── Optional mail + OAuth creds (ABSENT BY DEFAULT) ─────────────────
# Source, in order: an existing keys USB (KEYS/secrets/mail.json + an optional
# KEYS/secrets/dkim-private.key) pointed at by KEYS_SRC; else an interactive
# prompt (the same 10s `read -t 10` pattern as the password hashes); else EMPTY
# (mail/providers disabled). Set NONINTERACTIVE=1 (or pass --random) to skip the
# prompt and leave them empty. The brand's MAIL_PROVIDER (brand.conf) supplies
# the default provider name. These end up in keys-out/secrets/{mail.json,
# dkim-private.key} + a combined cluster-creds.json that gen-cluster-secrets.sh
# reads (KEYS_FILE) — so the keys USB can CARRY the mail/OAuth creds.
KEYS_SRC="${KEYS_SRC:-}"            # path to an existing KEYS tree to copy creds FROM
NONINTERACTIVE="${NONINTERACTIVE:-}"
MAIL_PROVIDER="${MAIL_PROVIDER:-protonmail}"

# Optional egress-VPN provider configs to stage onto KEYS/vpn/<domain>/. Secrets
# (a WireGuard .conf / OpenVPN .ovpn carries the private key) — NEVER generated,
# only COPIED from an out-of-band source dir. VPN_SRC may hold the configs flat
# (copied under the node's own domain) or already laid out as <domain>/<file>.
# VPN_DOMAIN is the node's own brand domain (else CLUSTER_DOMAIN / brand.conf).
VPN_SRC="${VPN_SRC:-}"              # dir of provider .conf/.ovpn to stage (own domain)
VPN_DOMAIN="${VPN_DOMAIN:-${CLUSTER_DOMAIN:-}}"

# ── Orchestration superdomain (permanently INTERNAL; distinct from CLUSTER_DOMAIN) ──
# The MagicDNS base_domain every mesh node joins. Written into the GENERATED
# provision.json's .mesh.magic_dns_domain (+ derived .mesh.cp_dns_name); provision.sh
# (specs/etc/keys-provision/provision.sh) consumes it as headscale dns.base_domain and
# the kubeadm controlPlaneEndpoint — so ALL mesh nodes really join it, with ZERO
# image-side / builder-flag changes (the KEYS channel, design §2.7).
# PERMANENTLY INTERNAL (invariant I7): unlike CLUSTER_DOMAIN (the PUBLIC apex the
# go-live wizard flips to a real domain), the superdomain is NEVER go-live-flipped and
# never public. Default: <BRAND>.internal (matches the Studio's effective_superdomain()
# = superdomain or f"{brand}.internal"; brand default 'snapdragon' => snapdragon.internal).
# Override with SUPERDOMAIN (env/brand.conf) or --superdomain to pin an explicit
# internal zone. Precedence: built-in (<brand>.internal) < env/brand.conf < CLI flag.
SUPERDOMAIN="${SUPERDOMAIN:-}"

# ── In-UI SSH-terminal key model: per-device sshd HOST + BFF DIAL keypairs ──────
# The in-UI SSH terminal lets the BFF dial a device over the tailnet to drive an
# operator console. That needs TWO per-device keypairs minted here, off-image-build:
#   * a device sshd HOST keypair — baked into the image (the protected
#     provision_ssh_host_keys() installs it at /etc/ssh/), so the device presents a
#     STABLE host identity the BFF can PIN (closing TOFU).
#   * a BFF DIAL keypair — its PUBLIC half goes into the device's authorized_keys
#     (so the BFF can auth as the dial user); its PRIVATE half goes to Vault ONLY,
#     mounted into the BFF per device. The private half is NEVER baked into an image
#     and NEVER bundled onto a downloadable key-USB image leg.
# Default ON for every role (each image is one device). Set GEN_DEVICE_SSH=false to
# skip (e.g. a non-device keys bundle). DEVICE_ID names the Vault-seed/ingest path
# (default: a random short id). DIAL_USER is the unprivileged login the BFF dials as.
# Precedence: built-in < env/brand.conf < CLI flag.
GEN_DEVICE_SSH="${GEN_DEVICE_SSH:-true}"
DEVICE_ID="${DEVICE_ID:-}"          # stable per-device id (Vault path segment); auto if empty
DIAL_USER="${DIAL_USER:-bff-dial}"  # unprivileged login the BFF dials in AS

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
  -r, --role ROLE     pki | backend | frontend | host | control-plane-additional |
                      mesh-extension. Default: pki
                      (control-plane-additional = a 2nd/3rd HA control-plane that
                       kubeadm join --control-plane's the existing cluster)
                      (mesh-extension = an ADMIN-owned Layer-B registry-ENFORCED
                       node — the ONLY role that emits KEYS/device-registry/ and
                       selects owner_type=ADMIN sshd enforcement)
                      pki = FULL config + default user accounts; workers = KEYS ONLY (no users.json).
      --registry-pub FILE  Layer-B (mesh-extension role): the BAKED public verifying
                      half of the BFF device-registry signing key (PEM or base64
                      X.509 SPKI DER). NEVER a private key. Absent => a PLACEHOLDER
                      is written that fails CLOSED until replaced on the key-USB.
                      (env: REGISTRY_PUB / REGISTRY_PUB_FILE)
      --random        Generate random passwords instead of prompting (hashes are
                      written to the key-USB config; NOT echoed in plaintext).
      --root-password Generate a ROOT password too (default: NO root password —
                      root login is LOCKED on the image). When set, the root
                      password is stored SALTED+HASHED in users.json (key-USB),
                      never printed. (env/brand.conf: GEN_ROOT_PASSWORD=true)
      --sudo-nopasswd The privileged (superadmin/admin) user ALWAYS gets sudo —
                      with root login locked, sudo is its escalation path. By
                      default sudo is PASSWORD-GATED; this flag makes it NOPASSWD.
                      (env/brand.conf: SUDO_NOPASSWD=true)
      --ca-cert FILE  Use an EXISTING CA cert (PEM) as the issuer for the mTLS
                      certs (forwarded to gen-keystores.sh). Default: self-signed.
      --ca-key FILE   Private key for --ca-cert (PEM; may be encrypted).
      --ca-key-pass V Passphrase for --ca-key (prefer CA_KEY_PASS env over this).
      --keys-src DIR  Existing KEYS tree to copy OPTIONAL mail/OAuth creds FROM
                      (DIR/secrets/mail.json + DIR/secrets/dkim-private.key). If
                      absent, the pki role PROMPTS for mail creds (10s timeout);
                      decline/empty => mail stays disabled. (env: KEYS_SRC)
      --vpn-src DIR   Egress-VPN: stage provider .conf/.ovpn configs onto
                      KEYS/vpn/<domain>/ (own domain ONLY). The configs are
                      SECRETS (private VPN key) — COPIED verbatim 0600, NEVER
                      generated. DIR may hold the files flat or under a <domain>/
                      subdir. (env: VPN_SRC)
      --vpn-domain D  Egress-VPN: the node's OWN brand domain for --vpn-src
                      (else CLUSTER_DOMAIN). (env: VPN_DOMAIN)
      --superdomain D Orchestration superdomain: the mesh MagicDNS base_domain every
                      node joins, written into provision.json .mesh.magic_dns_domain
                      (+ derived .mesh.cp_dns_name). PERMANENTLY INTERNAL — never
                      go-live-flipped, distinct from CLUSTER_DOMAIN (the public apex).
                      Default: <BRAND>.internal. (env/brand.conf: SUPERDOMAIN)
      --device-id ID  In-UI SSH terminal: stable per-device id used as the Vault
                      path / ingest-metadata segment for this device's host + dial
                      key material. Default: a random short id. (env: DEVICE_ID)
      --dial-user U   In-UI SSH terminal: the unprivileged login the BFF dials in
                      AS (its authorized_keys gets the dial PUBLIC key). Default:
                      bff-dial. (env: DIAL_USER)
      --no-device-ssh In-UI SSH terminal: skip generating the per-device sshd HOST
                      keypair + BFF DIAL keypair + ingest metadata (default: ON —
                      each image is one device). (env: GEN_DEVICE_SSH=false)
  -h, --help          Show this help.

  Mail/OAuth creds are OPTIONAL and ABSENT BY DEFAULT. NONINTERACTIVE=1 (or
  --random) skips the prompt and leaves them empty (no SMTP / providers wired).

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
        --root-password) GEN_ROOT_PASSWORD=true; shift ;;
        --sudo-nopasswd) SUDO_NOPASSWD=true; shift ;;
        --ca-cert)     CA_CERT="$2"; shift 2 ;;
        --ca-key)      CA_KEY="$2"; shift 2 ;;
        --ca-key-pass) CA_KEY_PASS="$2"; shift 2 ;;
        --keys-src)    KEYS_SRC="$2"; shift 2 ;;
        --registry-pub) REGISTRY_PUB_FILE="$2"; shift 2 ;;   # Layer-B: baked verifying key (mesh-extension role)
        --vpn-src)     VPN_SRC="$2"; shift 2 ;;               # egress-VPN: provider .conf/.ovpn to stage (own domain)
        --vpn-domain)  VPN_DOMAIN="$2"; shift 2 ;;            # egress-VPN: the node's own brand domain
        --superdomain) SUPERDOMAIN="$2"; shift 2 ;;          # mesh MagicDNS base_domain (permanently internal); default <BRAND>.internal
        --device-id)   DEVICE_ID="$2"; shift 2 ;;            # in-UI SSH terminal: per-device Vault-seed path segment
        --dial-user)   DIAL_USER="$2"; shift 2 ;;            # in-UI SSH terminal: unprivileged login the BFF dials as
        --no-device-ssh) GEN_DEVICE_SSH=false; shift ;;      # in-UI SSH terminal: skip host+dial keypair generation
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

case "${ROLE}" in
    pki) : ;;  # provision.json is already the pki example (full config + users)
    backend|frontend|host)
        cp "${OUT_DIR}/examples/provision.${ROLE}.json" "${OUT_DIR}/provision.json" ;;
    control-plane-additional)
        # Additional HA control-plane: kubeadm join --control-plane (needs the
        # first CP's token + ca_cert_hash + certificate_key + shared kubernetes/pki).
        cp "${OUT_DIR}/examples/provision.control-plane-additional.json" "${OUT_DIR}/provision.json" ;;
    mesh-extension)
        # ADMIN-owned mesh-extension node (Layer-B registry-ENFORCED). Today the
        # admin image_builder path is the documented TODO, so we reuse the `host`
        # worker manifest as the base (KEYS-only, joins the mesh) and stamp the
        # device_registry block below so provision_device_registry() selects
        # owner_type=ADMIN. This is the ONLY role that emits KEYS/device-registry/.
        cp "${OUT_DIR}/examples/provision.host.json" "${OUT_DIR}/provision.json" ;;
    *) echo "ERROR: --role must be pki|backend|frontend|host|control-plane-additional|mesh-extension" >&2; exit 1 ;;
esac
rm -rf "${OUT_DIR}/examples"

# The keys-template ships a device-registry/ doc dir (its README is deleted with
# the others above). Remove the now-empty dir for EVERY role except the ADMIN
# mesh-extension role (which repopulates it below) so SUPERADMIN/primary keys-out
# carry NO device-registry material at all.
[ "${ROLE}" = "mesh-extension" ] || rm -rf "${OUT_DIR}/device-registry"

# ── Orchestration superdomain -> generated KEYS bundle (KEYS channel, design §2.7) ──
# EVERY role's node joins the SAME orchestration superdomain, so stamp the effective
# value into the GENERATED bundle here (the template's fixed default is replaced):
#   * provision.json .mesh.magic_dns_domain  — authoritative; provision.sh's
#     resolve_magic_dns_domain() sed-rewrites headscale dns.base_domain from it.
#   * provision.json .mesh.cp_dns_name        — re-derived kube-api.<superdomain> only
#     when it still tracked the old domain, so an operator override is preserved;
#     provision.sh's resolve_cp_dns_name() feeds it to workers/additional CPs as the
#     kubeadm join target.
#   * kubernetes/kubeadm-config.yaml controlPlaneEndpoint + certSANs — the FIRST
#     control-plane runs `kubeadm init --config` on this file VERBATIM (it is NOT
#     re-derived at boot), so its base_domain MUST track the superdomain or the CP's
#     apiserver cert SANs won't match kube-api.<superdomain> and TLS joins fail. This
#     file's own header demands "keep in sync with .mesh.cp_dns_name/.magic_dns_domain";
#     we honour that on the generated copy. (The static keys-template default + the
#     image-baked specs/etc/{kubernetes/kubeadm-config,headscale/config}.yaml fallbacks
#     are only used when KEYS lacks these files — flagged for follow-up alignment.)
# PERMANENTLY INTERNAL (invariant I7): distinct from .snapdragon.cluster_domain (the
# PUBLIC apex the go-live wizard flips), NEVER go-live-flipped. ZERO builder flags.
EFFECTIVE_SUPERDOMAIN="${SUPERDOMAIN:-${BRAND:-snapdragon}.internal}"
PROV="${OUT_DIR}/provision.json"
if [ -f "${PROV}" ]; then
    SD="${EFFECTIVE_SUPERDOMAIN}" python3 - "${PROV}" "${OUT_DIR}/kubernetes/kubeadm-config.yaml" <<'PY'
import json, os, re, sys
prov, kubeadm = sys.argv[1], sys.argv[2]
sd = os.environ["SD"]

# provision.json .mesh — authoritative magic_dns_domain + derived cp_dns_name.
d = json.load(open(prov))
mesh = d.setdefault("mesh", {})
old = mesh.get("magic_dns_domain") or "headnet.internal"
mesh["magic_dns_domain"] = sd
cp = mesh.get("cp_dns_name") or ""
if not cp or cp == "kube-api.%s" % old:      # preserve an explicit operator override
    mesh["cp_dns_name"] = "kube-api.%s" % sd
json.dump(d, open(prov, "w"), indent=2)
open(prov, "a").write("\n")

# kubeadm-config.yaml — rewrite its OWN base_domain (read from controlPlaneEndpoint,
# NOT assumed equal to provision.json's) to the superdomain, everywhere it appears
# (controlPlaneEndpoint + every certSAN suffix). No-op when absent / already custom.
if os.path.isfile(kubeadm):
    txt = open(kubeadm).read()
    m = re.search(r'controlPlaneEndpoint:\s*"?kube-api\.([A-Za-z0-9.-]+?):6443"?', txt)
    if m and m.group(1) != sd:
        open(kubeadm, "w").write(txt.replace(m.group(1), sd))
PY
    echo "==> Orchestration superdomain: ${EFFECTIVE_SUPERDOMAIN}"
    echo "    -> ${PROV} (.mesh.magic_dns_domain + .mesh.cp_dns_name)"
    echo "    -> ${OUT_DIR}/kubernetes/kubeadm-config.yaml (controlPlaneEndpoint + certSANs)"
    echo "    permanently internal — never go-live-flipped (distinct from cluster_domain)"
fi

# ── Layer-B device-license registry: per-node identity + verifying key ─────────
# ONLY the ADMIN-owned `mesh-extension` role emits this. SUPERADMIN/primary roles
# (pki|backend|frontend|host|control-plane-additional) emit NOTHING new — they keep
# the #66 owner-key sshd path; provision_device_registry() no-ops on them.
#
# Emitted under KEYS/device-registry/ (consumed by provision_device_registry):
#   * registry-pub.ed25519  — the BAKED public verifying half of the BFF signing
#       key (base64 X.509 SPKI DER == RegistrySigner.publicKeyBase64()). Sourced
#       OUT-OF-BAND: --registry-pub FILE, else REGISTRY_PUB env/brand.conf, else a
#       PLACEHOLDER is written (the operator MUST replace it on the key-USB — a
#       placeholder fails CLOSED, never authorises). NEVER a real signing PRIVATE
#       key, NEVER committed to git.
#   * machine_key_fp        — the node's headscale machine-key fp; if minted only
#       at `tailscale up`, left EMPTY here and pinned POST-join by provision.
#   * mesh_id               — the node's mesh id (also stamped into provision.json
#       .device_registry.mesh_id).
if [ "${ROLE}" = "mesh-extension" ]; then
    DR_DIR="${OUT_DIR}/device-registry"
    mkdir -p "${DR_DIR}"

    # Stamp the manifest so provision_device_registry() selects owner_type=ADMIN.
    PROV="${OUT_DIR}/provision.json"
    DR_MESH_ID="${REGISTRY_MESH_ID:-${MESH_ID:-}}"
    [ -f "${PROV}" ] && DR_MESH_ID="${DR_MESH_ID}" python3 - "${PROV}" <<'PY'
import json, os, sys
f = sys.argv[1]
d = json.load(open(f))
dr = d.setdefault("device_registry", {})
dr["owner_type"] = "ADMIN"
dr["image_type"] = "mesh-extension"
mesh = os.environ.get("DR_MESH_ID", "")
if mesh:
    dr["mesh_id"] = mesh
# BFF /export transport (the SUPERADMIN-equivalent in-cluster mTLS identity). Left
# as overridable placeholders; a missing URL/cert makes the sync agent a verified
# no-op (bootstrap/offline) — the node fail-closes to break-glass + the baked key.
dr.setdefault("bff_export_url", os.environ.get("REGISTRY_BFF_URL", ""))
dr.setdefault("bff_client_cert", os.environ.get("REGISTRY_BFF_CLIENT_CERT", ""))
dr.setdefault("bff_client_key", os.environ.get("REGISTRY_BFF_CLIENT_KEY", ""))
json.dump(d, open(f, "w"), indent=2)
PY

    # mesh_id file (provision also reads .device_registry.mesh_id / .mesh.id).
    printf '%s\n' "${DR_MESH_ID}" > "${DR_DIR}/mesh_id"

    # machine_key_fp: baked if known up-front (REGISTRY_MACHINE_KEY_FP), else EMPTY
    # so provision pins it POST-`tailscale up` (write-once). It MUST equal the fp
    # the admin-bff stored in device_registry.machine_key_fp — alignment is the
    # highest-risk integration point (see device-registry README).
    printf '%s\n' "${REGISTRY_MACHINE_KEY_FP:-}" > "${DR_DIR}/machine_key_fp"

    # registry-pub.ed25519: the BAKED public verifying half. NEVER a private key.
    # validate_registry_pub FILE SRC — the written one-liner MUST round-trip as
    # an Ed25519 PUBLIC key (base64 X.509 SPKI DER == RegistrySigner.
    # publicKeyBase64()). openssl -pubin also REJECTS private-key input, so a
    # mistakenly-supplied signing key can never be baked. Anything else (raw
    # garbage, wrong algorithm, truncated base64) is a hard error: baking
    # unverifiable bytes as the Layer-B verifying key would brick (or worse,
    # corrupt) the node's registry verification while announcing success.
    validate_registry_pub() {
        local f="$1" src="$2"
        if ! base64 -d "${f}" 2>/dev/null \
                | openssl pkey -pubin -inform DER -noout -text 2>/dev/null \
                | grep -qi 'ED25519'; then
            echo "ERROR: ${src} does not parse as an Ed25519 PUBLIC key" >&2
            echo "       (expected PEM 'BEGIN PUBLIC KEY' or base64 X.509 SPKI DER; NEVER a private key)" >&2
            rm -f "${f}"
            exit 1
        fi
    }
    REGISTRY_PUB_FILE="${REGISTRY_PUB_FILE:-}"
    if [ -n "${REGISTRY_PUB_FILE}" ] && [ -f "${REGISTRY_PUB_FILE}" ]; then
        # Accept either a PEM (-----BEGIN PUBLIC KEY-----) or raw base64 SPKI DER;
        # normalise to the base64-SPKI-DER one-liner the node verifies with.
        if grep -q 'BEGIN PUBLIC KEY' "${REGISTRY_PUB_FILE}" 2>/dev/null; then
            openssl pkey -pubin -in "${REGISTRY_PUB_FILE}" -outform DER \
                | base64 -w0 > "${DR_DIR}/registry-pub.ed25519"
        else
            tr -d '[:space:]' < "${REGISTRY_PUB_FILE}" > "${DR_DIR}/registry-pub.ed25519"
        fi
        validate_registry_pub "${DR_DIR}/registry-pub.ed25519" "--registry-pub ${REGISTRY_PUB_FILE}"
        echo "  ${DR_DIR}/registry-pub.ed25519  (BAKED registry verifying key from ${REGISTRY_PUB_FILE})"
    elif [ -n "${REGISTRY_PUB:-}" ]; then
        printf '%s' "${REGISTRY_PUB}" | tr -d '[:space:]' > "${DR_DIR}/registry-pub.ed25519"
        validate_registry_pub "${DR_DIR}/registry-pub.ed25519" "REGISTRY_PUB env"
        echo "  ${DR_DIR}/registry-pub.ed25519  (BAKED registry verifying key from REGISTRY_PUB env)"
    else
        # PLACEHOLDER — fails CLOSED. The operator MUST replace this on the key-USB
        # with the brand's real public half before the node can verify any export.
        cat > "${DR_DIR}/registry-pub.ed25519" <<'PLACEHOLDER'
# PLACEHOLDER — NOT A REAL KEY. Replace with the base64 X.509 SPKI DER of the
# brand's device-registry signing public half (RegistrySigner.publicKeyBase64()).
# Until replaced, Layer-B fail-closes: the node denies ALL ssh except the
# console break-glass. NEVER place a PRIVATE key here.
PLACEHOLDER
        echo "  ${DR_DIR}/registry-pub.ed25519  (PLACEHOLDER — replace on the key-USB with the real public half; fails CLOSED until then)"
        echo "    -> set --registry-pub FILE / REGISTRY_PUB env, or drop the real key onto the USB."
    fi
    chmod 0644 "${DR_DIR}/"* 2>/dev/null || true
    echo "  ${DR_DIR}/  (Layer-B ADMIN mesh-extension node identity + verifying key)"
fi

# ── Egress VPN: stage provider configs onto KEYS/vpn/<domain>/ (secrets) ───────
# The keys-template ships a vpn/ doc dir (README deleted above) + a placeholder
# vpn/example.com/.gitkeep tree. Strip the placeholder from keys-out so a real
# stick carries ONLY the node's own-domain configs. If --vpn-src DIR is given,
# copy its .conf/.ovpn under vpn/<VPN_DOMAIN>/ (own domain only); the configs are
# secrets (private VPN key) — copied verbatim 0600, NEVER generated. With no
# --vpn-src the dir stays empty and provision_vpn() no-ops (service default-off).
rm -rf "${OUT_DIR}/vpn/example.com"
if [ -n "${VPN_SRC}" ]; then
    if [ ! -d "${VPN_SRC}" ]; then
        echo "ERROR: --vpn-src given (${VPN_SRC}) but it is not a directory" >&2
        exit 1
    fi
    if [ -z "${VPN_DOMAIN}" ]; then
        echo "ERROR: --vpn-src given but no --vpn-domain / CLUSTER_DOMAIN — refusing to stage VPN configs without a target domain" >&2
        echo "       (provision_vpn() installs ONLY the node's OWN domain's configs; the staging dir MUST be domain-scoped)" >&2
        exit 1
    fi
    VPN_DIR="${OUT_DIR}/vpn/${VPN_DOMAIN}"
    mkdir -p "${VPN_DIR}"
    vpn_staged=0
    # Accept either flat (DIR/*.conf|*.ovpn) or already domain-laid-out
    # (DIR/<VPN_DOMAIN>/*). Prefer the domain subdir if it exists.
    vpn_from="${VPN_SRC}"
    [ -d "${VPN_SRC}/${VPN_DOMAIN}" ] && vpn_from="${VPN_SRC}/${VPN_DOMAIN}"
    for ext in conf ovpn; do
        for vf in "${vpn_from}/"*."${ext}"; do
            [ -f "${vf}" ] || continue
            cp -f "${vf}" "${VPN_DIR}/"
            chmod 0600 "${VPN_DIR}/$(basename "${vf}")" 2>/dev/null || true
            vpn_staged=$((vpn_staged + 1))
        done
    done
    if [ "${vpn_staged}" -eq 0 ]; then
        echo "WARNING: --vpn-src ${vpn_from} carried no *.conf / *.ovpn — KEYS/vpn/${VPN_DOMAIN}/ staged empty (service stays off)" >&2
    else
        echo "  ${VPN_DIR}/  (${vpn_staged} egress-VPN config(s) for domain ${VPN_DOMAIN}, mode 0600 — SECRET)"
    fi
fi

mkdir -p "${OUT_DIR}/ssh"
KEYFILE="${OUT_DIR}/ssh/${ADMIN}_ed25519"
[ -f "${KEYFILE}" ] || { echo "==> Generating ed25519 keypair for ${ADMIN}"; ssh-keygen -t ed25519 -N '' -C "${ADMIN}@snapdragon" -f "${KEYFILE}" >/dev/null; }
PUBKEY="$(cat "${KEYFILE}.pub")"

# ── In-UI SSH-terminal key model: per-device HOST + BFF DIAL keypairs ───────────
# Mints, into ${OUT_DIR} (the key-USB tree), the two keypairs the in-UI SSH
# terminal needs and emits non-secret ingest metadata. The split below is the
# whole point — three DISTINCT destinations, only one of which is ever baked:
#
#   keys-out/ssh/host/ssh_host_ed25519_key{,.pub}   -> BAKED into the image by the
#       protected provision_ssh_host_keys() (installs to /etc/ssh/). Gives the
#       device a STABLE host identity; host_key_fp is what the BFF PINS (closes
#       TOFU). The PRIVATE host key is baked (it is the device's own identity) —
#       this is the established host-key path, unchanged here.
#
#   keys-out/ssh/${DIAL_USER}.authorized_keys       -> the DIAL PUBLIC key, in the
#       existing `ssh/<user>.authorized_keys` convention. The client-image session
#       bakes it into the dial user's authorized_keys so the BFF can auth. PUBLIC
#       key only — safe to bake/bundle.
#
#   keys-out/vault-seed/device/<id>/ssh/dial_private_key  -> the DIAL PRIVATE key.
#       ⇒ VAULT ONLY. NEVER bake into an image. NEVER bundle into a downloadable
#       artifact. NEVER log. It lives under vault-seed/ (a sibling of, NOT inside,
#       the image-baked ssh/ tree) precisely so make-keys-usb.sh / the build never
#       picks it up. It is pushed to Vault (secret/<brand>/device/<id>/ssh) and the
#       per-device ExternalSecret mounts it into the BFF.
#
#   keys-out/vault-seed/device/<id>/ingest.json     -> NON-secret metadata
#       (host_key_fp, dial_pub_fp, dial_user, dial_pub) the image-gen Job POSTs
#       back to the BFF ingest so the BFF can register + PIN the device.
#
# Idempotent (regenerates nothing already present); guarded by GEN_DEVICE_SSH.
if [ "${GEN_DEVICE_SSH}" = true ]; then
    # Resolve a stable device id (Vault path / ingest segment). Default: a short
    # random hex id; an operator-supplied --device-id / DEVICE_ID is sanitised to
    # the [a-z0-9-] charset a k8s object name / Vault path segment allows.
    if [ -z "${DEVICE_ID}" ]; then
        DEVICE_ID="dev-$(openssl rand -hex 4)"
    else
        DEVICE_ID="$(printf '%s' "${DEVICE_ID}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | tr -s '-' | sed -e 's/^-*//' -e 's/-*$//')"
        [ -n "${DEVICE_ID}" ] || { echo "ERROR: --device-id / DEVICE_ID reduced to empty after sanitising (use [a-z0-9-])" >&2; exit 1; }
    fi

    echo "==> In-UI SSH terminal: per-device key material (device_id=${DEVICE_ID}, dial_user=${DIAL_USER})"

    # (1) Device sshd HOST keypair -> keys-out/ssh/host/ (BAKED at provision time).
    HOST_DIR="${OUT_DIR}/ssh/host"
    mkdir -p "${HOST_DIR}"
    HOST_KEY="${HOST_DIR}/ssh_host_ed25519_key"
    if [ ! -f "${HOST_KEY}" ]; then
        ssh-keygen -t ed25519 -N '' -C "host@${DEVICE_ID}" -f "${HOST_KEY}" >/dev/null
    fi
    chmod 0600 "${HOST_KEY}" 2>/dev/null || true
    chmod 0644 "${HOST_KEY}.pub" 2>/dev/null || true
    # SHA256 host-key fingerprint the BFF pins (matches `ssh-keygen -lf`, base64 form).
    HOST_KEY_FP="$(ssh-keygen -lf "${HOST_KEY}.pub" | awk '{print $2}')"

    # (2) BFF DIAL keypair. The PRIVATE half is written DIRECTLY under vault-seed/
    # (NEVER under the baked ssh/ tree); the PUBLIC half is copied into the
    # ssh/<dial_user>.authorized_keys baked-key convention.
    VSEED_DIR="${OUT_DIR}/vault-seed/device/${DEVICE_ID}/ssh"
    mkdir -p "${VSEED_DIR}"
    DIAL_KEY="${VSEED_DIR}/dial_private_key"   # ⇒ Vault only — NEVER baked/bundled/logged
    if [ ! -f "${DIAL_KEY}" ]; then
        # -C carries the dial user so the authorized_keys entry is self-describing.
        ssh-keygen -t ed25519 -N '' -C "${DIAL_USER}@${DEVICE_ID}" -f "${DIAL_KEY}" >/dev/null
    fi
    chmod 0600 "${DIAL_KEY}" 2>/dev/null || true
    DIAL_PUB_FP="$(ssh-keygen -lf "${DIAL_KEY}.pub" | awk '{print $2}')"
    DIAL_PUB="$(cat "${DIAL_KEY}.pub")"
    # Stage the dial PUBLIC key for the BFF dial user via the existing
    # install_authorized_keys ssh/<name>.authorized_keys convention. PUBLIC only.
    printf '%s\n' "${DIAL_PUB}" > "${OUT_DIR}/ssh/${DIAL_USER}.authorized_keys"
    chmod 0644 "${OUT_DIR}/ssh/${DIAL_USER}.authorized_keys" 2>/dev/null || true
    # The dial PUBLIC key never belongs in the Vault-seed dir's pub sibling being
    # mistaken for the image-baked one; keep the .pub next to the private key for
    # the ingest step but DO NOT leave it where the image bake globs ssh/host/.

    # (3) Non-secret ingest metadata the image-gen Job POSTs to the BFF. Contains
    # ONLY fingerprints + dial_user + dial PUBLIC key — NO private material.
    INGEST="${OUT_DIR}/vault-seed/device/${DEVICE_ID}/ingest.json"
    DEVICE_ID="${DEVICE_ID}" DIAL_USER="${DIAL_USER}" \
    HOST_KEY_FP="${HOST_KEY_FP}" DIAL_PUB_FP="${DIAL_PUB_FP}" \
    HOST_KEY_PUB="$(cat "${HOST_KEY}.pub")" DIAL_PUB="${DIAL_PUB}" \
    python3 - "${INGEST}" <<'PY'
import json, os, sys
meta = {
    "device_id":   os.environ["DEVICE_ID"],
    "dial_user":   os.environ["DIAL_USER"],
    "host_key_fp": os.environ["HOST_KEY_FP"],   # SHA256:... — the BFF PINS this
    "host_key_pub": os.environ["HOST_KEY_PUB"], # device sshd HOST public key (non-secret)
    "dial_pub_fp": os.environ["DIAL_PUB_FP"],   # SHA256:... of the dial PUBLIC key
    "dial_pub":    os.environ["DIAL_PUB"],      # dial PUBLIC key (non-secret)
}
with open(sys.argv[1], "w") as fh:
    json.dump(meta, fh, indent=2)
    fh.write("\n")
PY
    chmod 0644 "${INGEST}" 2>/dev/null || true

    echo "  ${HOST_KEY}{,.pub}        (device sshd HOST keypair -> BAKED to /etc/ssh by provision_ssh_host_keys; fp ${HOST_KEY_FP})"
    echo "  ${OUT_DIR}/ssh/${DIAL_USER}.authorized_keys   (dial PUBLIC key -> baked into ${DIAL_USER} authorized_keys; PUBLIC only)"
    echo "  ${DIAL_KEY}   (dial PRIVATE key -> VAULT ONLY: never baked, never bundled, never logged)"
    echo "  ${INGEST}     (non-secret ingest metadata the image-gen Job POSTs to the BFF: fingerprints + dial_user + public keys)"
fi

# ── Optional mail + OAuth creds (ABSENT BY DEFAULT) ─────────────────
# Populates ${OUT_DIR}/secrets/{mail.json,dkim-private.key} + a combined
# cluster-creds.json (what gen-cluster-secrets.sh reads via KEYS_FILE) so the
# keys USB can carry the SMTP + GitHub/Discord OAuth creds. Source order:
#   1. an existing keys USB (--keys-src DIR): copy DIR/secrets/mail.json +
#      DIR/secrets/dkim-private.key verbatim if present;
#   2. else interactive prompt (10s `read -t 10`, like the password hashes);
#   3. else leave EMPTY — mail + providers stay disabled.
# Empty/declined inputs are written as "" so the generator/manifests fall through
# to native login + admin-approval (no SMTP, no federation providers wired).
provision_mail_oauth() {
    local sdir="${OUT_DIR}/secrets"
    mkdir -p "${sdir}"
    local mail_json="${sdir}/mail.json"
    local dkim_out="${sdir}/dkim-private.key"
    local creds_out="${sdir}/cluster-creds.json"

    # 1) Copy from an existing KEYS tree if asked and present.
    # If --keys-src was EXPLICITLY given it MUST carry secrets/mail.json — a wrong
    # or unmounted path silently falling through to empty creds would ship a prod
    # keys USB with SMTP + OAuth quietly absent. Hard-error instead of degrading.
    if [ -n "${KEYS_SRC}" ] && [ ! -f "${KEYS_SRC}/secrets/mail.json" ]; then
        echo "ERROR: --keys-src given (${KEYS_SRC}) but ${KEYS_SRC}/secrets/mail.json not found" >&2
        echo "       (wrong path, USB not mounted, or no carried creds — refusing to fall through to empty mail/OAuth)" >&2
        exit 1
    fi
    if [ -n "${KEYS_SRC}" ] && [ -f "${KEYS_SRC}/secrets/mail.json" ]; then
        echo "==> Mail/OAuth: copying creds from ${KEYS_SRC}/secrets/"
        cp "${KEYS_SRC}/secrets/mail.json" "${mail_json}"
        [ -f "${KEYS_SRC}/secrets/dkim-private.key" ] && cp "${KEYS_SRC}/secrets/dkim-private.key" "${dkim_out}"
        [ -f "${KEYS_SRC}/secrets/cluster-creds.json" ] && cp "${KEYS_SRC}/secrets/cluster-creds.json" "${creds_out}"
        chmod 600 "${mail_json}" "${dkim_out}" "${creds_out}" 2>/dev/null || true
        return 0
    fi

    # Resolve fields: env wins; else prompt (unless non-interactive); else empty.
    local m_provider="${MAIL_PROVIDER}"
    local m_host="${MAIL_HOST:-}" m_port="${MAIL_PORT:-}" m_tls="${MAIL_TLS:-}"
    local m_user="${MAIL_USER:-}" m_pass="${MAIL_PASSWORD:-}" m_from="${MAIL_FROM:-}"
    local m_dkim="${MAIL_DKIM_KEY:-}"
    local gh_id="${GITHUB_CLIENT_ID:-}"  gh_sec="${GITHUB_CLIENT_SECRET:-}"
    local dc_id="${DISCORD_CLIENT_ID:-}" dc_sec="${DISCORD_CLIENT_SECRET:-}"

    # ask VAR "Prompt" [silent] — fills VAR via env, else 10s prompt, else "".
    ask() {
        local __var="$1" __prompt="$2" __silent="${3:-}" __cur="${!1:-}" __v=""
        [ -n "${__cur}" ] && { printf -v "${__var}" '%s' "${__cur}"; return 0; }
        if [ "${RANDOM_PW}" = true ] || [ -n "${NONINTERACTIVE}" ] || [ ! -t 0 ]; then
            printf -v "${__var}" '%s' ""; return 0
        fi
        if [ -n "${__silent}" ]; then
            read -t 10 -rsp "${__prompt} (10s, blank=skip): " __v || __v=""; echo >&2
        else
            read -t 10 -rp  "${__prompt} (10s, blank=skip): " __v || __v=""
        fi
        printf -v "${__var}" '%s' "${__v}"
    }

    if [ "${RANDOM_PW}" = true ] || [ -n "${NONINTERACTIVE}" ] || [ ! -t 0 ]; then
        echo "==> Mail/OAuth: non-interactive — leaving creds empty unless set via env (mail/providers disabled)"
    else
        echo "==> Mail/OAuth (OPTIONAL — press Enter / wait 10s at any prompt to skip)"
        echo "    Provider presets: gmail/outlook/protonmail set host/port/tls automatically."
    fi
    # Only prompt for the SMTP login; host/port/tls come from the provider preset
    # in gen-cluster-secrets.sh (so a user need only supply user+password+from).
    ask m_user "SMTP username (mail user)"
    ask m_pass "SMTP password / app-password" silent
    ask m_from "From: address (blank=noreply@<domain>)"
    ask gh_id  "GitHub OAuth client id"
    ask gh_sec "GitHub OAuth client secret" silent
    ask dc_id  "Discord OAuth client id"
    ask dc_sec "Discord OAuth client secret" silent

    # Optional DKIM private key: accept a PATH, copy it out if it exists.
    if [ -n "${m_dkim}" ] && [ -f "${m_dkim}" ]; then
        cp "${m_dkim}" "${dkim_out}"; chmod 600 "${dkim_out}" 2>/dev/null || true
        echo "    copied DKIM private key -> ${dkim_out}"
    fi

    # Write secrets/mail.json (always — empty user/password = disabled) and the
    # combined cluster-creds.json gen-cluster-secrets.sh consumes via KEYS_FILE.
    M_PROVIDER="${m_provider}" M_HOST="${m_host}" M_PORT="${m_port}" M_TLS="${m_tls}" \
    M_USER="${m_user}" M_PASS="${m_pass}" M_FROM="${m_from}" \
    M_DKIM_PATH="$([ -f "${dkim_out}" ] && echo "secrets/dkim-private.key" || echo "")" \
    GH_ID="${gh_id}" GH_SEC="${gh_sec}" DC_ID="${dc_id}" DC_SEC="${dc_sec}" \
    python3 - "${mail_json}" "${creds_out}" <<'PY'
import json, os, sys
mail = {
    "provider": os.environ.get("M_PROVIDER", ""),
    "host":     os.environ.get("M_HOST", ""),
    "port":     os.environ.get("M_PORT", ""),
    "tls":      os.environ.get("M_TLS", ""),
    "user":     os.environ.get("M_USER", ""),
    "password": os.environ.get("M_PASS", ""),
    "from":     os.environ.get("M_FROM", ""),
    "dkim_key": os.environ.get("M_DKIM_PATH", ""),
}
json.dump(mail, open(sys.argv[1], "w"), indent=2)
open(sys.argv[1], "a").write("\n")
creds = {
    "github":  {"client_id": os.environ.get("GH_ID", ""), "client_secret": os.environ.get("GH_SEC", "")},
    "discord": {"client_id": os.environ.get("DC_ID", ""), "client_secret": os.environ.get("DC_SEC", "")},
    "mail":    mail,
}
json.dump(creds, open(sys.argv[2], "w"), indent=2)
open(sys.argv[2], "a").write("\n")
PY
    chmod 600 "${mail_json}" "${creds_out}" 2>/dev/null || true
    if [ -n "${m_user}" ] && [ -n "${m_pass}" ]; then
        echo "    mail ENABLED (provider=${m_provider}, user=${m_user}) -> ${mail_json}"
    else
        echo "    mail DISABLED (no user/password) -> ${mail_json} (empty; native login + admin-approval)"
    fi
}

# Stage headscale's Casdoor OIDC application client-secret onto the pki node's
# KEYS bundle, at the exact path keys-template/headscale/config.yaml's
# client_secret_path expects (/var/lib/headscale/oidc_client_secret once copied
# by provision_headscale() in specs/etc/keys-provision/provision.sh).
#
# WHY THIS IS SEPARATE FROM provision_mail_oauth's pattern: mail/OAuth creds are
# OPERATOR-SUPPLIED (prompted interactively, no canonical source elsewhere).
# headscale's OIDC secret is NOT operator-supplied — it is DETERMINISTICALLY
# MINTED by gen-cluster-secrets.sh's CASDOOR_APPS loop (the SAME value the
# casdoor-init Job registers as the Casdoor Application's clientSecret, so this
# script and that Job MUST agree byte-for-byte or the OIDC handshake fails).
# gen-cluster-secrets.sh ALWAYS writes it to keys-out/vault/secrets.json (its own
# header comment: "OFFLINE — ALWAYS write a USB bundle under <out>/vault") — this
# function's ONLY job is carrying that ALREADY-MINTED value forward into the
# per-role KEYS bundle gen-provision-keys.sh is building, matching the
# documented run order (docs/RUNNING.md: "gen-cluster-secrets - gen-provision-
# keys - make-keys-usb"). It never mints or prompts for a value itself.
#
# Soft-fails (warn, do not exit 1) when the vault bundle is absent: an operator
# may legitimately run gen-provision-keys.sh before gen-cluster-secrets.sh while
# iterating on non-headscale parts of a role's bundle. A pki bundle assembled
# without this file simply ships with headscale's OIDC app un-provisioned,
# exactly the pre-existing (now-explicit-instead-of-silent) failure mode.
provision_headscale_oidc_secret() {
    local vault_json="${REPO_DIR}/keys-out/vault/secrets.json"
    if [ ! -f "${vault_json}" ]; then
        echo "==> Headscale OIDC secret: SKIPPED — ${vault_json} not found (run gen-cluster-secrets.sh first; headscale's Casdoor app will be un-provisioned without this)" >&2
        return 0
    fi
    # gen-cluster-secrets.sh writes an IDENTICAL casdoor-app-secrets object into
    # TWO namespaces ("<brand>-pki" AND "<brand>-forum", both from the same
    # app_secrets dict) — this is not unique to pki. secrets.json is written
    # with sort_keys=True, so "<brand>-forum" actually sorts (and matches)
    # BEFORE "<brand>-pki" — "first match by shape" only works because both
    # namespaces are guaranteed identical today. Find it by shape (rather than
    # requiring this script to independently resolve BRAND) so it works
    # regardless of brand.conf; if pki/forum secrets ever diverge, this needs
    # to target "<brand>-pki" explicitly instead of "first match".
    local secret
    secret="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for ns in d.values():
    apps = ns.get("casdoor-app-secrets")
    if isinstance(apps, dict) and "headscale" in apps:
        sys.stdout.write(apps["headscale"])
        break
' "${vault_json}" 2>/dev/null)"
    if [ -z "${secret}" ]; then
        echo "==> Headscale OIDC secret: SKIPPED — ${vault_json} has no casdoor-app-secrets.headscale entry (stale bundle? re-run gen-cluster-secrets.sh)" >&2
        return 0
    fi
    local dest_dir="${OUT_DIR}/headscale"
    mkdir -p "${dest_dir}"
    local dest="${dest_dir}/oidc_client_secret"
    printf '%s' "${secret}" > "${dest}"
    chmod 600 "${dest}"
    echo "==> Headscale OIDC secret: staged -> ${dest} (from ${vault_json})"
}

if [ "${ROLE}" = "pki" ]; then
    # ── pki node: FULL config — default user accounts + hashed passwords ──
    cp "${KEYFILE}.pub" "${OUT_DIR}/ssh/${ADMIN}.authorized_keys"
    # gen_hash WHO — prompts (or --random mints) a password, prints only a
    # NON-SECRET note (never the cleartext), and emits the SHA-512 crypt hash on
    # stdout for storage in the key-USB users.json. The plaintext NEVER reaches
    # the console (was: `echo "${who} password: ${pw}"` — removed for hardening).
    gen_hash() {
        local who="$1" pw
        if ${RANDOM_PW}; then
            pw="$(openssl rand -base64 18)"
            echo "  ${who}: random password generated (stored salted+hashed in users.json — not printed)" >&2
        else
            if ! read -t 10 -rsp "Password for ${who} (10s, default=random): " pw || [ -z "${pw}" ]; then
                pw="$(openssl rand -base64 18)"
                echo >&2
                echo "  ${who}: timeout/empty -> random password generated (stored salted+hashed in users.json — not printed)" >&2
            else
                echo >&2
            fi
        fi
        openssl passwd -6 "${pw}"
    }
    echo "==> Setting password hashes (pki node)"
    ADMIN_HASH="$(gen_hash "${ADMIN}")"
    # ROOT password is OPTIONAL (default OFF). Without it root login is LOCKED on
    # the image (users.json .root.locked=true; no hash). With --root-password /
    # GEN_ROOT_PASSWORD=true we generate one and store ONLY its salted+hashed form.
    ROOT_HASH=""
    if [ "${GEN_ROOT_PASSWORD}" = true ]; then
        ROOT_HASH="$(gen_hash root)"
        echo "  root login: ENABLED (password salted+hashed in users.json — not printed)"
    else
        echo "  root login: LOCKED (no root password generated — default hardened posture; use --root-password to enable)"
    fi
    USERS="${OUT_DIR}/users.json"
    if [ "${SUDO_NOPASSWD}" = true ]; then
        echo "  sudo: GRANTED to '${ADMIN}' (NOPASSWD — escalates without re-entering the password)"
    else
        echo "  sudo: GRANTED to '${ADMIN}' (password-gated by the device/superadmin password; root login is locked)"
    fi
    SUDO_NOPASSWD="${SUDO_NOPASSWD}" python3 - "${USERS}" "${ADMIN}" "${ADMIN_HASH}" "${PUBKEY}" "${ROOT_HASH}" <<'PY'
import json, os, sys
f, name, h, key, rh = sys.argv[1:6]
d = json.load(open(f))
d.setdefault("users", [{}])
# The privileged user (the SUPERADMIN on primary images) ALWAYS gets sudo: with
# root login locked by default, sudo is its only escalation path. password-gated
# by default; NOPASSWD only when SUDO_NOPASSWD=true. Default groups include wheel.
nopw = os.environ.get("SUDO_NOPASSWD", "false") == "true"
d["users"][0].setdefault("groups", ["wheel", "audio", "video", "usb"])
d["users"][0].update({"name": name, "password_hash": h, "ssh_authorized_keys": [key],
                      "sudo": True, "sudo_nopasswd": nopw})
root = d.setdefault("root", {})
if rh:
    # Root login enabled: store ONLY the salted+hashed password, clear any lock.
    root["password_hash"] = rh
    root["locked"] = False
else:
    # Default hardened posture: no root password; provision.sh locks the account.
    root["password_hash"] = ""
    root["locked"] = True
json.dump(d, open(f, "w"), indent=2)
PY
    # Pin the privileged Tailscale-SSH user to this admin (the superadmin for the
    # primary core/cluster-node images). The headscale SSH ACL (policy.hujson)
    # then admits ONLY this user over the tailnet; root + others are denied.
    PROV="${OUT_DIR}/provision.json"
    [ -f "${PROV}" ] && python3 - "${PROV}" "${ADMIN}" <<'PY'
import json, sys
f, name = sys.argv[1:3]
d = json.load(open(f))
ts = d.setdefault("tailscale", {})
ts["ssh_user"] = name          # the operator/superadmin SSH login over the tailnet
ts.setdefault("ssh", True)     # expose Tailscale SSH (ACL-scoped to ssh_user)
ua = ts.get("up_args", "")
if "--ssh" not in ua.split():
    ts["up_args"] = (ua + " --ssh").strip()
json.dump(d, open(f, "w"), indent=2)
PY
    # Optional outbound-mail + GitHub/Discord OAuth creds for the cluster (pki
    # node carries the cluster config + secrets). Absent by default.
    provision_mail_oauth
    # headscale's OIDC app client-secret (deterministically minted by
    # gen-cluster-secrets.sh, carried forward here — never re-generated).
    provision_headscale_oidc_secret
    echo; echo "Done (pki — config node). Generated:"
    if [ "${GEN_ROOT_PASSWORD}" = true ]; then
        echo "  ${OUT_DIR}/users.json            (default accounts: admin '${ADMIN}' hashed + root login ENABLED, hashed)"
    else
        echo "  ${OUT_DIR}/users.json            (default account: admin '${ADMIN}' hashed; root login LOCKED — no password)"
    fi
    echo "  ${OUT_DIR}/provision.json        (all-services config for the cluster)"
    echo "  ${OUT_DIR}/secrets/mail.json     (OPTIONAL SMTP creds; empty = mail disabled)"
    echo "  ${OUT_DIR}/secrets/cluster-creds.json  (OPTIONAL mail+OAuth; read by gen-cluster-secrets.sh)"
    echo "  ${OUT_DIR}/ssh/${ADMIN}.authorized_keys  (operator PUBLIC key -> baked into '${ADMIN}' authorized_keys)"
    echo "  ${OUT_DIR}/ssh/${ADMIN}_ed25519       (operator PRIVATE SSH key — stays on the key-USB, off-image;"
    echo "                                          SSH into the node AS '${ADMIN}' over Tailscale: ssh -i ssh/${ADMIN}_ed25519 ${ADMIN}@<tailnet-ip>)"
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
