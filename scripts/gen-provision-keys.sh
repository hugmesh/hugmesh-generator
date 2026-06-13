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
    REGISTRY_PUB_FILE="${REGISTRY_PUB_FILE:-}"
    if [ -n "${REGISTRY_PUB_FILE}" ] && [ -f "${REGISTRY_PUB_FILE}" ]; then
        # Accept either a PEM (-----BEGIN PUBLIC KEY-----) or raw base64 SPKI DER;
        # normalise to the base64-SPKI-DER one-liner the node verifies with.
        if grep -q 'BEGIN PUBLIC KEY' "${REGISTRY_PUB_FILE}" 2>/dev/null; then
            openssl pkey -pubin -in "${REGISTRY_PUB_FILE}" -outform DER 2>/dev/null \
                | base64 -w0 > "${DR_DIR}/registry-pub.ed25519"
        else
            tr -d '[:space:]' < "${REGISTRY_PUB_FILE}" > "${DR_DIR}/registry-pub.ed25519"
        fi
        echo "  ${DR_DIR}/registry-pub.ed25519  (BAKED registry verifying key from ${REGISTRY_PUB_FILE})"
    elif [ -n "${REGISTRY_PUB:-}" ]; then
        printf '%s' "${REGISTRY_PUB}" | tr -d '[:space:]' > "${DR_DIR}/registry-pub.ed25519"
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

mkdir -p "${OUT_DIR}/ssh"
KEYFILE="${OUT_DIR}/ssh/${ADMIN}_ed25519"
[ -f "${KEYFILE}" ] || { echo "==> Generating ed25519 keypair for ${ADMIN}"; ssh-keygen -t ed25519 -N '' -C "${ADMIN}@snapdragon" -f "${KEYFILE}" >/dev/null; }
PUBKEY="$(cat "${KEYFILE}.pub")"

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
