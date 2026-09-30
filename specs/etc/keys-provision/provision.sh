#!/bin/bash
# keys-provision — first-boot provisioning from a USB "KEYS" partition.
#
# Installed to /usr/sbin/keys-provision and driven by the OpenRC
# "keys-provision" service. Runs on every boot but only does real work
# once (guarded by a state marker) unless the KEYS media carries a
# ".provision-force" file or KEYS_FORCE=1 is set in the environment.
#
# It looks for a removable device with a FAT32 filesystem labelled
# "KEYS" (override with KEYS_LABEL) and reads configuration, keys,
# passwords and certificates from it as plain files and JSON, then:
#
#   * generates SSH host keys (always, even with no KEYS media)
#   * creates users + sets passwords + installs authorized_keys
#   * sets hostname / timezone
#   * configures Wi-Fi / NetworkManager connections
#   * installs arbitrary certificates and files at given paths
#   * stages + optionally bootstraps headscale (control server)
#   * brings up the tailscale client against a login server
#   * stages Kubernetes PKI/config and optionally runs kubeadm
#   * runs any user-supplied post-provision scripts
#
# Expected layout on the KEYS partition (all parts optional):
#
#   KEYS/
#   ├── provision.json          top-level manifest (see keys-template/)
#   ├── users.json              user + root account definitions
#   ├── ssh/<user>.authorized_keys
#   ├── ssh/host/ssh_host_*_key[.pub]
#   ├── network/*.nmconnection
#   ├── headscale/config.yaml, *.key, acls.*, derp.yaml
#   ├── tailscale/authkey
#   ├── kubernetes/kubeadm-config.yaml, pki/*, join.json
#   ├── certs/*                 certificates referenced by files[]
#   └── secrets/*               anything referenced by files[] / run[]
#
# Nothing here is RPi-specific; the same engine runs under QEMU.

set -uo pipefail   # NOT -e: a failed step must not abort the whole run

# ── Configuration ──────────────────────────────────────────────────
LABEL="${KEYS_LABEL:-KEYS}"
MOUNT="${KEYS_MOUNT:-/run/keys}"
STATE_DIR="/var/lib/keys-provision"
LOG="/var/log/keys-provision.log"
DONE_MARKER="${STATE_DIR}/done"
USERS_MARKER="${STATE_DIR}/users.created"
FIND_RETRIES="${KEYS_FIND_RETRIES:-15}"   # USB enumeration can be slow

mkdir -p "${STATE_DIR}"
exec > >(tee -a "${LOG}") 2>&1

log()  { echo "[keys-provision $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
warn() { log "WARNING: $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── Local-first mesh endpoint resolution ───────────────────────────
# A node provisioned before any public DNS exists must still be reachable by
# its LAN peers. So the mesh endpoint defaults to this node's primary LAN
# IPv4 and is only overridden by explicit config. Precedence (highest first):
#   1. provision.json .headscale.server_url
#   2. provision.json .mesh.endpoint
#   3. the baked brand var HEADSCALE_URL (written to /etc/hugmesh/headscale-url
#      at build time — env does not survive to first boot)
#   4. DEFAULT: http://<primary-LAN-IPv4>:8080
# Because peers also get MagicDNS (.mesh.magic_dns_domain) + the control node's
# stable hostname, a LAN-IP endpoint keeps working after a public domain is
# later published: the MagicDNS control-plane name is stable across the
# IP->domain transition; clients only re-pin if login_server itself changes.

# Primary outbound LAN IPv4 (RFC1918 only). Empty if none can be determined.
resolve_lan_ip() {
    local ip=""
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
    [ -n "${ip}" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    case "${ip}" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) echo "${ip}" ;;
        *) [ -n "${ip}" ] && echo "${ip}" || true ;;  # last resort: any resolved IP
    esac
}

# Resolve the mesh control-server endpoint (full URL, e.g. http://1.2.3.4:8080).
resolve_endpoint() {
    local ep=""
    ep="$(jqm '.headscale.server_url // ""')"
    if [ -z "${ep}" ] || [ "${ep}" = "null" ]; then ep="$(jqm '.mesh.endpoint // ""')"; fi
    if [ -z "${ep}" ] || [ "${ep}" = "null" ]; then
        [ -r /etc/hugmesh/headscale-url ] && ep="$(tr -d '[:space:]' < /etc/hugmesh/headscale-url 2>/dev/null)"
    fi
    if [ -z "${ep}" ] || [ "${ep}" = "null" ]; then
        local lan; lan="$(resolve_lan_ip)"
        [ -n "${lan}" ] && ep="http://${lan}:8080"
    fi
    [ "${ep}" = "null" ] && ep=""
    echo "${ep}"
}

# Control-node (pki) headscale endpoint as seen by a WORKER / additional CP.
# A non-control node has no local headscale, so its mesh login_server must point
# at the pki node, not at itself. Precedence: explicit override (server_url /
# mesh.endpoint) else the baked brand HEADSCALE_URL else the pki node's LAN IP
# from .nodes[] (the same inventory provision_hosts uses, so a pre-domain worker
# still reaches the control server). Empty if none of these are known.
resolve_control_endpoint() {
    local ep=""
    ep="$(jqm '.headscale.server_url // ""')"
    if [ -z "${ep}" ] || [ "${ep}" = "null" ]; then ep="$(jqm '.mesh.endpoint // ""')"; fi
    if [ -z "${ep}" ] || [ "${ep}" = "null" ]; then
        [ -r /etc/hugmesh/headscale-url ] && ep="$(tr -d '[:space:]' < /etc/hugmesh/headscale-url 2>/dev/null)"
    fi
    if [ -z "${ep}" ] || [ "${ep}" = "null" ]; then
        local pki_ip n i
        n="$(jqm '.nodes // [] | length')"
        for ((i = 0; i < n; i++)); do
            if [ "$(jqm ".nodes[$i].role")" = "pki" ]; then
                pki_ip="$(jqm ".nodes[$i].ip")"; break
            fi
        done
        [ -n "${pki_ip:-}" ] && [ "${pki_ip}" != "null" ] && ep="http://${pki_ip}:8080"
    fi
    [ "${ep}" = "null" ] && ep=""
    echo "${ep}"
}

# Privileged Tailscale-SSH user. HARDENED DEFAULT: only ONE local user may open a
# Tailscale-SSH session into the node (root + others denied). For the PRIMARY
# core/cluster-node images that user is the SUPERADMIN; the admin-created
# mesh-extension flow (when built) provisions the building ADMIN instead — both
# arrive here as .tailscale.ssh_user. Precedence: explicit .tailscale.ssh_user
# else the first sudo user in users.json (the provisioned admin/superadmin) else
# "admin". Used to (a) scope the headscale SSH ACL (@@TS_SSH_USER@@) and (b) is
# implied by `tailscale up --ssh`.
# TODO(admin-mesh-extension): when the image_builder admin mesh-extension build
# path lands, set .tailscale.ssh_user to the building admin (domain-scoped) at
# that pipeline's gen-keys step; this resolver already honours it.
resolve_ssh_user() {
    local u f
    u="$(jqm '.tailscale.ssh_user // ""')"
    if [ -z "${u}" ] || [ "${u}" = "null" ]; then
        f="${BASE}/users.json"; [ -f "${f}" ] || f="${MANIFEST}"
        u="$(jq -r 'first((.users // [])[] | select(.sudo==true) | .name) // ""' "${f}" 2>/dev/null)"
    fi
    { [ -z "${u}" ] || [ "${u}" = "null" ]; } && u="admin"
    echo "${u}"
}

# MagicDNS base domain (overridable by .mesh.magic_dns_domain).
resolve_magic_dns_domain() {
    local d; d="$(jqm '.mesh.magic_dns_domain // ""')"
    { [ -z "${d}" ] || [ "${d}" = "null" ]; } && d="headnet.internal"
    echo "${d}"
}

# Stable, role-independent MagicDNS name for the k8s control plane
# (overridable by .mesh.cp_dns_name). Defaults to kube-api.<magic_dns_domain>.
resolve_cp_dns_name() {
    local n; n="$(jqm '.mesh.cp_dns_name // ""')"
    { [ -z "${n}" ] || [ "${n}" = "null" ]; } && n="kube-api.$(resolve_magic_dns_domain)"
    # Fail-closed: cp_dns_name is interpolated UNQUOTED-in-effect into headscale config.yaml
    # (dns.extra_records), /etc/hosts, and the kubeadm join API endpoint. Reject anything that
    # is not a plain dotted DNS name — this blocks embedded newlines / quotes / YAML-and-hosts
    # breakers that would inject an attacker A-record or host entry (mesh DNS poisoning /
    # control-plane MITM). Mirrors the magic_dns_domain (^[a-z0-9.-]+$) and ssh_user fail-closed
    # gates; on a malformed value fall back to the derived kube-api.<magic_dns_domain> default
    # (and the ultimate baked default if that too is malformed). warn -> stderr so it never
    # pollutes this resolver's command-substituted stdout.
    if [[ ! "${n}" =~ ^[a-z0-9.-]+$ ]]; then
        warn "cp_dns_name is not a valid dotted DNS name ([a-z0-9.-]) — using the derived default" >&2
        n="kube-api.$(resolve_magic_dns_domain)"
        [[ "${n}" =~ ^[a-z0-9.-]+$ ]] || n="kube-api.headnet.internal"
    fi
    echo "${n}"
}

# ── Always: ensure an Ed25519-ONLY SSH host key exists so sshd can start ───────
# FIPS 186-5 approved (Ed25519); NIST 800-53 IA-5/SC-13, DISA SSH STIG. We do NOT
# use `ssh-keygen -A` (which also mints RSA/ECDSA/DSA host keys). hardened.conf
# pins `HostKeyAlgorithms ssh-ed25519` + `HostKey ssh_host_ed25519_key`, so any
# legacy RSA/ECDSA/DSA host key is unused AND removed here so it cannot be
# negotiated. provision_ssh_host_keys() may still install a pre-generated
# Ed25519 host key from the KEYS partition; this is the no-USB-keys fallback.
ensure_host_keys() {
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        log "Generating Ed25519-only SSH host key"
        ssh-keygen -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key </dev/null
    fi
    # Defence-in-depth: strip any non-Ed25519 host keys (e.g. from a prior
    # ssh-keygen -A) so a stale RSA/ECDSA/DSA key can never be offered.
    for legacy in rsa ecdsa dsa; do
        rm -f "/etc/ssh/ssh_host_${legacy}_key" "/etc/ssh/ssh_host_${legacy}_key.pub" 2>/dev/null || true
    done
}

# ── Locate + mount the KEYS partition ──────────────────────────────
BASE=""
find_and_mount() {
    # Testability / pre-mounted hook: if KEYS_PREMOUNTED=1 and the mount
    # already contains a manifest, use it directly (no block-device discovery).
    if [ "${KEYS_PREMOUNTED:-0}" = "1" ]; then
        if [ -f "${MOUNT}/provision.json" ] || [ -f "${MOUNT}/users.json" ]; then
            BASE="${MOUNT}"; log "Using pre-mounted KEYS data at ${BASE}"; return 0
        fi
        warn "KEYS_PREMOUNTED=1 but no manifest under ${MOUNT}"; return 1
    fi

    local dev="" tries=0
    while [ "${tries}" -lt "${FIND_RETRIES}" ]; do
        dev="$(blkid -L "${LABEL}" 2>/dev/null || true)"
        [ -n "${dev}" ] && break
        # Fallback: any vfat/exfat volume whose label matches
        dev="$(blkid -o device 2>/dev/null | while read -r d; do
                   lbl="$(blkid -s LABEL -o value "${d}" 2>/dev/null || true)"
                   [ "${lbl}" = "${LABEL}" ] && { echo "${d}"; break; }
               done)"
        [ -n "${dev}" ] && break
        tries=$((tries + 1))
        sleep 1
    done

    if [ -z "${dev}" ]; then
        warn "No partition labelled '${LABEL}' found after ${FIND_RETRIES}s."
        warn "Continuing without external provisioning data."
        return 1
    fi

    log "Found KEYS media: ${dev}"
    mkdir -p "${MOUNT}"
    modprobe vfat 2>/dev/null || true
    if ! mount -o ro,nosuid,nodev,noexec "${dev}" "${MOUNT}" 2>/dev/null; then
        # exFAT or a quirky FS — let the kernel autodetect
        mount -o ro "${dev}" "${MOUNT}" || { warn "Failed to mount ${dev}"; return 1; }
    fi

    # Support both KEYS/ at the root and a nested KEYS/keys/ directory
    if   [ -f "${MOUNT}/provision.json" ] || [ -f "${MOUNT}/users.json" ]; then
        BASE="${MOUNT}"
    elif [ -f "${MOUNT}/keys/provision.json" ] || [ -f "${MOUNT}/keys/users.json" ]; then
        BASE="${MOUNT}/keys"
    else
        BASE="${MOUNT}"
    fi
    log "Provisioning data root: ${BASE}"
    return 0
}

cleanup() { umount "${MOUNT}" 2>/dev/null || true; }

# ── JSON helpers (jq required; present in the image) ───────────────
MANIFEST=""
jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }            # query manifest
jqe()  { jq -e "$1" "${MANIFEST}" >/dev/null 2>&1; }         # test existence
kf()   { printf '%s/%s\n' "${BASE}" "$1"; }                  # resolve KEYS path

# ── Users + root ───────────────────────────────────────────────────
# ── Desktop-governance detection (shared signal) ────────────────────────────
# Returns 0 (true) iff THIS image is desktop-governance-GOVERNED, i.e. it carries
# the desktop-governance config templates either baked into the image
# (/etc/hugmesh/desktop-governance) or supplied on the KEYS USB
# (KEYS/desktop-governance/). This is the SAME signal provision_desktop_governance()
# keys off to decide whether to render the SSO-claim sudo gate, so the two stay in
# lockstep. On a governed image, sudo MUST flow ONLY through the `desktop-sudo`
# group/polkit claim (revocable at the IdP) — so provision_users() suppresses the
# per-user static sudoers.d grant + the standing wheel-group sudo conferral, and
# provision_desktop_governance() installs the polkit gate. Non-governed images
# keep their existing behavior unchanged.
desktop_governance_governed() {
    [ -d /etc/hugmesh/desktop-governance ] && return 0
    [ -d "${BASE}/desktop-governance" ] && return 0
    return 1
}

provision_users() {
    local f="${BASE}/users.json"
    [ -f "${f}" ] || f="${MANIFEST}"          # users may live in provision.json
    [ -f "${f}" ] || { log "No users.json — skipping user creation"; return 0; }
    jq -e '.users' "${f}" >/dev/null 2>&1 || jq -e '.root' "${f}" >/dev/null 2>&1 || {
        log "No .users/.root in ${f}"; return 0; }

    local n i
    n="$(jq '(.users // []) | length' "${f}" 2>/dev/null || echo 0)"
    log "Creating ${n} user(s) from ${f}"

    for ((i = 0; i < n; i++)); do
        local name comment shell uid groups sudo nopw phash plain
        name="$(jq -r ".users[$i].name" "${f}")"
        [ -n "${name}" ] && [ "${name}" != "null" ] || { warn "user[$i] has no name"; continue; }
        comment="$(jq -r ".users[$i].comment // \"\"" "${f}")"
        shell="$(jq -r ".users[$i].shell // \"/bin/bash\"" "${f}")"
        uid="$(jq -r ".users[$i].uid // \"\"" "${f}")"
        groups="$(jq -r ".users[$i].groups // [\"wheel\",\"audio\",\"video\",\"usb\"] | join(\",\")" "${f}")"
        sudo="$(jq -r ".users[$i].sudo // false" "${f}")"
        nopw="$(jq -r ".users[$i].sudo_nopasswd // false" "${f}")"

        # On a desktop-governance-GOVERNED image, sudo is the SSO `desktop-sudo`
        # claim's job ONLY (revocable at the IdP). Strip the sudo-conferring
        # `wheel` group from this user's supplementary groups so no KEYS user
        # ever gets STANDING root via the base image's `%wheel ALL=(ALL) ALL`
        # line. Non-wheel groups (audio/video/usb/...) are preserved. polkit's
        # 49-hugmesh-desktop-sudo.rules is the sole escalation route.
        if desktop_governance_governed; then
            local _kept _gg; _kept=""
            IFS=',' read -ra _gg <<< "${groups}"
            for _g in "${_gg[@]}"; do
                [ -z "${_g}" ] && continue
                [ "${_g}" = "wheel" ] && continue
                _kept="${_kept:+${_kept},}${_g}"
            done
            [ "${groups}" != "${_kept}" ] && \
                log "desktop-governance: governed image — dropping sudo-conferring 'wheel' from ${name}'s groups (sudo via desktop-sudo SSO claim only)"
            groups="${_kept}"
        fi
        phash="$(jq -r ".users[$i].password_hash // \"\"" "${f}")"
        plain="$(jq -r ".users[$i].password // \"\"" "${f}")"

        # Ensure the requested supplementary groups exist before useradd.
        local _g; IFS=',' read -ra _grps <<< "${groups}"
        for _g in "${_grps[@]}"; do
            [ -z "${_g}" ] && continue
            getent group "${_g}" >/dev/null 2>&1 || groupadd "${_g}" 2>/dev/null || true
        done

        if id "${name}" >/dev/null 2>&1; then
            log "User ${name} already exists — updating"
        else
            local args=(-m -s "${shell}" -c "${comment}" -G "${groups}")
            [ -n "${uid}" ] && args+=(-u "${uid}")
            useradd "${args[@]}" "${name}" && log "Created user ${name}" \
                || warn "useradd ${name} failed"
        fi

        if [ -n "${phash}" ]; then
            printf '%s:%s\n' "${name}" "${phash}" | chpasswd -e \
                && log "Set password hash for ${name}"
        elif [ -n "${plain}" ]; then
            printf '%s:%s\n' "${name}" "${plain}" | chpasswd \
                && log "Set (plaintext-sourced) password for ${name}"
        fi

        install_authorized_keys "${name}" "${f}" "${i}"

        if [ "${sudo}" = "true" ]; then
            if desktop_governance_governed; then
                # GOVERNED image: do NOT write a static /etc/sudoers.d grant. A
                # static grant would confer STANDING root independent of the OIDC
                # claim/mapper/polkit and could never be revoked at the IdP. On these
                # images sudo flows SOLELY through the `desktop-sudo` group/polkit
                # claim (provision_desktop_governance installs the gate). The
                # KEYS `sudo:true` is honored as IdP-claim eligibility, not as a
                # device-local sudoers entry.
                log "desktop-governance: governed image — SUPPRESSING static /etc/sudoers.d grant for ${name} (sudo via desktop-sudo SSO claim only)"
            else
                mkdir -p /etc/sudoers.d
                if [ "${nopw}" = "true" ]; then
                    echo "${name} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/10-${name}"
                else
                    echo "${name} ALL=(ALL) ALL" > "/etc/sudoers.d/10-${name}"
                fi
                chmod 0440 "/etc/sudoers.d/10-${name}"
                log "Granted sudo to ${name} (nopasswd=${nopw})"
            fi
        fi
        touch "${USERS_MARKER}"
    done

    # root account
    if jq -e '.root' "${f}" >/dev/null 2>&1; then
        local rhash rlocked
        rhash="$(jq -r '.root.password_hash // ""' "${f}")"
        rlocked="$(jq -r '.root.locked // false' "${f}")"
        # HARDENED DEFAULT: with .root.locked=true (or no hash supplied) root login
        # is DISABLED — `passwd -l root` locks the password field and PermitRootLogin
        # prohibit-password (sshd hardened.conf) already blocks root password SSH.
        # Only an explicit non-empty .root.password_hash with locked!=true enables it.
        if [ "${rlocked}" = "true" ] || [ -z "${rhash}" ]; then
            passwd -l root >/dev/null 2>&1 && log "root login LOCKED (passwd -l root — no root password)" \
                || warn "failed to lock root account"
        else
            printf 'root:%s\n' "${rhash}" | chpasswd -e && log "Set root password hash"
        fi
        install_root_keys "${f}"
        touch "${USERS_MARKER}"
    fi
}

# ── superadmin DEVICE password (FD-04 / FD-06 superadmin client variant) ────────
# A superadmin CLIENT device (built with `--person-role superadmin`) bakes the marker
# /etc/hugmesh/device-password-required. Here we set that device's interactive
# login password from a SALTED+HASHED value supplied on the KEYS USB — the plaintext
# NEVER touches git or the image (same custody model as the Casdoor superadmin-seed).
# Precedence: manifest `.client.device_password_hash`, else KEYS `secrets/device-
# password.hash`. The value must be a crypt(3) hash (e.g. `mkpasswd -m sha512crypt`
# or `-m yescrypt`). FD-07 LUKS keyslot enrollment from this password is a separate
# increment; here it sets the local account password only. See docs/CLIENT-IMAGES.md.
DEVPW_MARKER="/etc/hugmesh/device-password-required"
provision_device_password() {
    [ -f "${DEVPW_MARKER}" ] || return 0
    local user hash
    user="$(resolve_ssh_user)"          # the superadmin account on this device
    hash="$(jqm '.client.device_password_hash // ""')"
    if { [ -z "${hash}" ] || [ "${hash}" = "null" ]; } && [ -f "${BASE}/secrets/device-password.hash" ]; then
        hash="$(tr -d ' \n' < "${BASE}/secrets/device-password.hash")"
    fi
    if [ -z "${hash}" ] || [ "${hash}" = "null" ]; then
        warn "superadmin device requires a device password but none supplied (.client.device_password_hash or KEYS secrets/device-password.hash) — leaving login unset"
        return 0
    fi
    # crypt(3) hashes begin with $<id>$ ($6$=sha512crypt, $y$=yescrypt, $2b$=bcrypt).
    # Refuse to apply a bare plaintext value (would be set verbatim by chpasswd -e).
    case "${hash}" in
        \$*\$*) ;;
        *) warn "device_password_hash is not a crypt(3) hash ('\$id\$...') — refusing to apply"; return 0 ;;
    esac
    id "${user}" >/dev/null 2>&1 || { warn "device-password: target user '${user}' does not exist yet — skipping"; return 0; }
    printf '%s:%s\n' "${user}" "${hash}" | chpasswd -e \
        && log "Set superadmin DEVICE password for ${user} (from KEYS hash; plaintext never stored)" \
        || warn "failed to set device password for ${user}"
}

install_authorized_keys() {
    local name="$1" f="$2" i="$3"
    local home ssh_dir tmp
    home="$(getent passwd "${name}" | cut -d: -f6)"
    [ -n "${home}" ] || return 0
    ssh_dir="${home}/.ssh"; tmp="$(mktemp)"

    jq -r ".users[$i].ssh_authorized_keys // [] | .[]" "${f}" 2>/dev/null >> "${tmp}"
    local akf
    akf="$(jq -r ".users[$i].ssh_authorized_keys_file // \"\"" "${f}" 2>/dev/null)"
    [ -n "${akf}" ] && [ -f "${BASE}/${akf}" ] && cat "${BASE}/${akf}" >> "${tmp}"
    # Convention: ssh/<name>.authorized_keys
    [ -f "${BASE}/ssh/${name}.authorized_keys" ] && cat "${BASE}/ssh/${name}.authorized_keys" >> "${tmp}"

    if [ -s "${tmp}" ]; then
        mkdir -p "${ssh_dir}"
        sort -u "${tmp}" > "${ssh_dir}/authorized_keys"
        chmod 0700 "${ssh_dir}"; chmod 0600 "${ssh_dir}/authorized_keys"
        chown -R "${name}:" "${ssh_dir}"
        log "Installed $(wc -l < "${ssh_dir}/authorized_keys") authorized key(s) for ${name}"
    fi
    rm -f "${tmp}"
}

install_root_keys() {
    local f="$1" tmp; tmp="$(mktemp)"
    jq -r '.root.ssh_authorized_keys // [] | .[]' "${f}" 2>/dev/null >> "${tmp}"
    [ -f "${BASE}/ssh/root.authorized_keys" ] && cat "${BASE}/ssh/root.authorized_keys" >> "${tmp}"
    if [ -s "${tmp}" ]; then
        mkdir -p /root/.ssh
        sort -u "${tmp}" > /root/.ssh/authorized_keys
        chmod 0700 /root/.ssh; chmod 0600 /root/.ssh/authorized_keys
        log "Installed root authorized key(s)"
    fi
    rm -f "${tmp}"
}

# ── SSH host keys supplied on KEYS ─────────────────────────────────
provision_ssh_host_keys() {
    [ -d "${BASE}/ssh/host" ] || return 0
    log "Installing pre-generated SSH host keys"
    cp -f "${BASE}/ssh/host/"ssh_host_*_key      /etc/ssh/ 2>/dev/null || true
    cp -f "${BASE}/ssh/host/"ssh_host_*_key.pub  /etc/ssh/ 2>/dev/null || true
    chmod 0600 /etc/ssh/ssh_host_*_key      2>/dev/null || true
    chmod 0644 /etc/ssh/ssh_host_*_key.pub  2>/dev/null || true
}

# ── Hostname / timezone ────────────────────────────────────────────
provision_identity() {
    local hn tz
    hn="$(jqm '.hostname // ""')"
    if [ -n "${hn}" ] && [ "${hn}" != "null" ]; then
        # hn (.hostname) is written into the root-dot-sourced KEY="VALUE" file
        # /etc/conf.d/hostname (an OpenRC conf.d file sourced as root), passed to
        # `hostname`, and used as /etc/hostname. Validate fail-closed as an RFC-1123
        # hostname/FQDN (labels of [A-Za-z0-9] + internal hyphens, dot-separated, each
        # label <=63 and total <=253) — this rejects the '"' / '$' / '`' / ';' /
        # newline that would break out of the dot-sourced conf.d line. Skip on invalid.
        if [ "${#hn}" -le 253 ] && \
           [[ "${hn}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]; then
            echo "${hn}" > /etc/hostname
            mkdir -p /etc/conf.d
            echo "hostname=\"${hn}\"" > /etc/conf.d/hostname
            hostname "${hn}" 2>/dev/null || true
            log "Hostname set to ${hn}"
        else
            warn "hostname '${hn}' is not a valid RFC-1123 hostname/FQDN — skipping (leaving default)"
        fi
    fi
    tz="$(jqm '.timezone // ""')"
    if [ -n "${tz}" ] && [ "${tz}" != "null" ] && [ -f "/usr/share/zoneinfo/${tz}" ]; then
        echo "${tz}" > /etc/timezone
        ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
        log "Timezone set to ${tz}"
    fi
}

# ── Networking (Wi-Fi + NetworkManager keyfiles) ───────────────────
provision_network() {
    local nm_dir="/etc/NetworkManager/system-connections"
    mkdir -p "${nm_dir}"

    # Copy any *.nmconnection profiles verbatim
    if ls "${BASE}/network/"*.nmconnection >/dev/null 2>&1; then
        cp -f "${BASE}/network/"*.nmconnection "${nm_dir}/"
        chmod 0600 "${nm_dir}/"*.nmconnection
        log "Installed NetworkManager connection profile(s)"
    fi

    # Convenience: synthesise a Wi-Fi profile from JSON
    local ssid psk country
    ssid="$(jqm '.network.wifi.ssid // ""')"
    psk="$(jqm '.network.wifi.psk // ""')"
    country="$(jqm '.network.wifi.country // "US"')"
    if [ -n "${ssid}" ] && [ "${ssid}" != "null" ]; then
        # ssid (.network.wifi.ssid) is used as a FILENAME ("${ssid}.nmconnection")
        # and as NetworkManager keyfile INI keys (id=/ssid=). Reject path traversal
        # ('/', '..'), newlines and control chars, and bound the length (IEEE-802.11
        # SSIDs are <=32 octets) fail-closed so a manifest value cannot escape the
        # connections dir or inject extra INI lines/sections. Skip the whole profile
        # (and the wpa_supplicant country write below) on a malformed SSID.
        if [ "${#ssid}" -gt 32 ] || [[ "${ssid}" == *".."* ]] \
           || [[ ! "${ssid}" =~ ^[[:print:]]+$ ]] || [[ "${ssid}" == *"/"* ]]; then
            warn "Wi-Fi SSID '${ssid}' contains a path separator/control char or is too long — skipping Wi-Fi profile"
            return 0
        fi
        # psk (.network.wifi.psk) is written verbatim as `psk=${psk}` in the keyfile INI below.
        # A newline/control char would inject arbitrary INI directives/sections into the root
        # 0600 profile (the SSID above is already fenced for exactly this INI-injection class).
        # Require a valid WPA secret — 8-63 printable chars (passphrase) OR 64 hex (raw PSK) —
        # fail-closed; skip the whole profile on a malformed psk, mirroring the SSID guard.
        if [ -n "${psk}" ] && [ "${psk}" != "null" ] \
           && ! { [ "${#psk}" -ge 8 ] && [ "${#psk}" -le 63 ] && [[ "${psk}" =~ ^[[:print:]]+$ ]]; } \
           && [[ ! "${psk}" =~ ^[0-9A-Fa-f]{64}$ ]]; then
            warn "Wi-Fi psk is not a valid WPA passphrase (8-63 printable chars) or 64-hex PSK — skipping Wi-Fi profile"
            return 0
        fi
        cat > "${nm_dir}/${ssid}.nmconnection" <<EOF
[connection]
id=${ssid}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${ssid}

[wifi-security]
key-mgmt=wpa-psk
psk=${psk}

[ipv4]
method=auto

[ipv6]
method=auto
EOF
        chmod 0600 "${nm_dir}/${ssid}.nmconnection"
        # country (.network.wifi.country) is written as an unquoted KEY=VALUE into the
        # root-dot-sourced /etc/conf.d/wpa_supplicant (an OpenRC conf.d file sourced as
        # root). Validate fail-closed as an ISO-3166-1 alpha-2 code (exactly two ASCII
        # letters) — this rejects the whitespace / ';' / '$(...)' / '`...`' / newline
        # that would break out of the sourced KEY=VALUE line. Skip on invalid.
        if [[ "${country}" =~ ^[A-Za-z]{2}$ ]]; then
            echo "country=${country}" > /etc/conf.d/wpa_supplicant 2>/dev/null || true
        else
            warn "Wi-Fi country '${country}' is not an ISO-3166 alpha-2 code — skipping wpa_supplicant country write"
        fi
        log "Configured Wi-Fi for SSID ${ssid}"
    fi
}

# ── Arbitrary certificates / files ─────────────────────────────────
provision_files() {
    jqe '.files' || return 0
    local n i
    n="$(jqm '.files | length')"
    for ((i = 0; i < n; i++)); do
        local src dst mode owner
        src="$(jqm ".files[$i].src")"
        dst="$(jqm ".files[$i].dest")"
        mode="$(jqm ".files[$i].mode // \"0644\"")"
        owner="$(jqm ".files[$i].owner // \"root:root\"")"
        [ -n "${src}" ] && [ -n "${dst}" ] || continue
        [ -f "${BASE}/${src}" ] || { warn "file src missing: ${src}"; continue; }
        mkdir -p "$(dirname "${dst}")"
        cp -f "${BASE}/${src}" "${dst}"
        chmod "${mode}" "${dst}"; chown "${owner}" "${dst}" 2>/dev/null || true
        log "Installed ${dst} (mode ${mode}, owner ${owner})"
    done
}

# ── KEYS/certs -> the system trust store ───────────────────────────
# Its OWN step, called from main() right after provision_files, for EVERY manifest —
# standalone images included (a CA the operator put on the stick is meant to be
# trusted; nothing about a trust anchor is mesh-specific), so it sits above the
# `if ! ${STANDALONE_IMG}` block on purpose.
# It used to be the tail of provision_files(), below that function's
# `jqe '.files' || return 0` — so it only ever ran for a manifest that carried a
# `files` list (the backend / control-plane examples). Every CLIENT manifest
# (KEYS profile `host`: desktop, laptop, chromebook — keys-template/examples/
# provision.host.json) and the frontend profile have no `files` key, and a desktop
# provisioned from such a stick never trusted the mesh CA on it, while the Studio's
# cloud Domains step (CLIENT_CA_INHERITANCE_NOTE) said it did. Now the stick's
# certs/ folder is imported whether or not the manifest lists files — which is what
# "the client trusts exactly the certificate authorities on the stick" means. For a
# manifest WITH a files list nothing changes: the same copies, in the same order.
# studio/tests/test_client_ca_inheritance.py EXECUTES this against the host-profile
# manifest and pins main()'s call order, so moving it back under a `.files` gate, or
# dropping the call from main(), makes that file red.
provision_certs() {
    # Bulk: drop everything in KEYS/certs into the system trust anchors
    if ls "${BASE}/certs/"* >/dev/null 2>&1; then
        mkdir -p /usr/local/share/ca-certificates /etc/ssl/keys
        cp -f "${BASE}/certs/"*.crt /usr/local/share/ca-certificates/ 2>/dev/null || true
        cp -f "${BASE}/certs/"*.pem /usr/local/share/ca-certificates/ 2>/dev/null || true
        cp -f "${BASE}/certs/"*.key /etc/ssl/keys/ 2>/dev/null && chmod 0600 /etc/ssl/keys/* || true
        have update-ca-certificates && update-ca-certificates 2>/dev/null || true
        log "Imported certificates from KEYS/certs"
    fi
}

# ── Headscale (self-hosted Tailscale control server) ───────────────
provision_headscale() {
    have headscale || { log "headscale not installed — skipping"; return 0; }
    local enabled
    enabled="$(jqm '.headscale.enabled // false')"
    if [ "${enabled}" != "true" ]; then
        log "headscale disabled in manifest — removing from runlevel"
        rc-update del headscale default 2>/dev/null || true
        rc-service headscale stop 2>/dev/null || true
        return 0
    fi

    getent group  headscale >/dev/null || groupadd -r headscale
    getent passwd headscale >/dev/null || \
        useradd -r -g headscale -d /var/lib/headscale -s /sbin/nologin headscale
    mkdir -p /etc/headscale /var/lib/headscale /run/headscale

    # Config + key material
    local cfg
    cfg="$(jqm '.headscale.config_file // "headscale/config.yaml"')"
    [ -f "${BASE}/${cfg}" ] && cp -f "${BASE}/${cfg}" /etc/headscale/config.yaml \
        && log "Installed headscale config from ${cfg}"
    if [ -d "${BASE}/headscale" ]; then
        cp -f "${BASE}/headscale/"*.key       /var/lib/headscale/ 2>/dev/null || true
        cp -f "${BASE}/headscale/"acl*        /etc/headscale/     2>/dev/null || true
        cp -f "${BASE}/headscale/"*.hujson    /etc/headscale/     2>/dev/null || true
        cp -f "${BASE}/headscale/"derp*.yaml  /etc/headscale/     2>/dev/null || true
        # OIDC app client-secret — EXPLICIT copy, not folded into the *.key glob
        # above: config.yaml's client_secret_path is literally
        # /var/lib/headscale/oidc_client_secret (no .key suffix), staged by
        # gen-provision-keys.sh's provision_headscale_oidc_secret(). Flagged
        # 2026-07-09 (PR #292), fixed 2026-07-10: the *.key glob would only ever
        # have matched a file already named to include ".key", which still
        # wouldn't byte-match this path — an explicit copy sidesteps the
        # glob/path mismatch entirely rather than relying on a naming trick.
        [ -f "${BASE}/headscale/oidc_client_secret" ] && \
            cp -f "${BASE}/headscale/oidc_client_secret" /var/lib/headscale/oidc_client_secret \
            && chmod 600 /var/lib/headscale/oidc_client_secret \
            && log "Installed headscale OIDC client-secret"
    fi
    # ── Layer-A BOOTSTRAP policy (device-license registry) ────────────────────
    # During the bootstrap window — BEFORE the BFF /export exists / is reachable —
    # apply the MINIMAL baked bootstrap policy (tagOwners + autoApprovers + the
    # KEPT 10.244/10.96 data-plane rule + a single conservative @@TS_SSH_USER@@
    # ssh rule, and NO any-to-any tag:hugmesh->tag:hugmesh:* hole). The
    # FIRST verified Layer-A sync (gen-headscale-policy.sh, enabled by
    # provision_headscale_policy_sync) WHOLESALE re-renders /etc/headscale/
    # policy.hujson and re-applies it, replacing this bootstrap policy with the
    # generated default-deny per-edge ssh block. A USB-supplied policy.hujson
    # override still wins (operator escape hatch). If neither the bootstrap file
    # nor a USB/baked policy.hujson exists, fall back to whatever is present.
    if [ ! -f "${BASE}/headscale/policy.hujson" ] && [ -f /etc/headscale/policy.bootstrap.hujson ]; then
        cp -f /etc/headscale/policy.bootstrap.hujson /etc/headscale/policy.hujson \
            && log "headscale: staged Layer-A BOOTSTRAP policy (no any-to-any :22 rule; replaced by first verified Layer-A sync)" \
            || warn "headscale: failed to stage bootstrap policy — using whatever policy.hujson is present"
    fi
    # Fleet ACL source: prefer a USB-supplied policy.hujson, else the baked-in
    # /etc/headscale/policy.hujson (now the bootstrap policy on a clean image).
    local policy_file=""
    if   [ -f "${BASE}/headscale/policy.hujson" ]; then policy_file=/etc/headscale/policy.hujson
    elif [ -f /etc/headscale/policy.hujson ];      then policy_file=/etc/headscale/policy.hujson
    fi
    # ── Local-first endpoint: rewrite server_url BEFORE starting the server ──
    # The baked config.yaml ships server_url=http://127.0.0.1:8080 (a placeholder
    # that loopback-only peers cannot reach). Resolve the real endpoint
    # (configured override else this node's LAN IP) and rewrite the single
    # server_url line idempotently so LAN peers can register at first boot.
    if [ -f /etc/headscale/config.yaml ]; then
        local endpoint dnsdom
        endpoint="$(resolve_endpoint)"
        if [ -n "${endpoint}" ]; then
            # Escape sed replacement metacharacters in the URL.
            local esc; esc="$(printf '%s' "${endpoint}" | sed -e 's/[&|\\/]/\\&/g')"
            sed -i "s|^server_url:.*|server_url: ${esc}|" /etc/headscale/config.yaml
            log "headscale server_url set to ${endpoint}"
        else
            warn "Could not resolve a mesh endpoint (no config + no LAN IP) — keeping baked server_url"
        fi
        # Overridable MagicDNS base domain.
        dnsdom="$(resolve_magic_dns_domain)"
        if [ -n "${dnsdom}" ]; then
            # dnsdom (.mesh.magic_dns_domain) is interpolated into a '|'-delimited sed
            # writing MagicDNS base_domain. Validate fail-closed as a hostname (rejects
            # the sed metachars '| & \' and newlines) then escape, so a malformed manifest
            # value cannot corrupt or inject config.yaml.
            if [[ "${dnsdom}" =~ ^[a-z0-9.-]+$ ]]; then
                local dnsdom_esc; dnsdom_esc="$(printf '%s' "${dnsdom}" | sed -e 's/[&|\\/]/\\&/g')"
                sed -i "s|^\(\s*\)base_domain:.*|\1base_domain: ${dnsdom_esc}|" /etc/headscale/config.yaml
                log "headscale MagicDNS base_domain set to ${dnsdom}"
            else
                warn "headscale MagicDNS base_domain '${dnsdom}' is not a valid hostname ([a-z0-9.-]) — leaving baked default"
            fi
        fi
    fi

    chown -R headscale:headscale /etc/headscale /var/lib/headscale /run/headscale
    chmod 0600 /var/lib/headscale/*.key 2>/dev/null || true

    rc-update add headscale default 2>/dev/null || true
    rc-service headscale start 2>/dev/null || warn "headscale failed to start"
    # Root-owned logfiles left by this inline start would EPERM headscale's unprivileged ordered restart — chown to the daemon user.
    chown headscale:headscale /var/log/headscale.log /var/log/headscale.err 2>/dev/null || true

    # Wait for the control server to come up, then create users + preauth keys
    local t=0
    while [ "${t}" -lt 15 ] && ! headscale users list >/dev/null 2>&1; do
        sleep 1; t=$((t + 1))
    done

    local nu j
    nu="$(jqm '.headscale.users // [] | length')"
    for ((j = 0; j < nu; j++)); do
        local u; u="$(jqm ".headscale.users[$j]")"
        headscale users create "${u}" 2>/dev/null \
            && log "Created headscale user ${u}" || true
    done

    local nk
    nk="$(jqm '.headscale.preauthkeys // [] | length')"
    mkdir -p /var/lib/headscale/preauthkeys
    for ((j = 0; j < nk; j++)); do
        local pu reuse ephem args key
        pu="$(jqm ".headscale.preauthkeys[$j].user")"
        reuse="$(jqm ".headscale.preauthkeys[$j].reusable // false")"
        ephem="$(jqm ".headscale.preauthkeys[$j].ephemeral // false")"
        args=(preauthkeys create --user "${pu}" --expiration 24h)
        [ "${reuse}" = "true" ] && args+=(--reusable)
        [ "${ephem}" = "true" ] && args+=(--ephemeral)
        key="$(headscale "${args[@]}" 2>/dev/null | tail -1)"
        if [ -n "${key}" ]; then
            echo "${key}" > "/var/lib/headscale/preauthkeys/${pu}.key"
            chmod 0600 "/var/lib/headscale/preauthkeys/${pu}.key"
            log "Created headscale preauth key for ${pu}"
        fi
    done

    # ── Fleet full-mesh ACL + subnet-route auto-approval + SSH ACL ────────
    # Load the fleet policy (tagOwners + autoApprovers + intra-fleet accepts +
    # the privileged-user-only Tailscale-SSH rule) so nodes can self-tag
    # (tag:hugmesh/+role), their advertised pod + service routes are
    # auto-approved, and ONLY the privileged user may open a Tailscale-SSH
    # session. Idempotent: re-running just re-applies.
    if [ -n "${policy_file}" ] && [ -f "${policy_file}" ]; then
        # Scope the SSH ACL to the provisioned privileged user (superadmin for
        # primary images / the building admin for mesh-extension images). The
        # @@TS_SSH_USER@@ placeholder is rewritten in place; root + others stay
        # denied an SSH session. Skipped cleanly if the file carries no SSH rule.
        if grep -q '@@TS_SSH_USER@@' "${policy_file}" 2>/dev/null; then
            local ssh_user; ssh_user="$(resolve_ssh_user)"
            # ssh_user is interpolated into a '/'-delimited sed rewriting the SSH ACL
            # (hujson). Validate fail-closed as a POSIX username (rejects '/ & \' and
            # newlines) then escape; on a malformed value leave the placeholder in place
            # so headscale grants SSH to nobody (fail-safe) rather than inject the ACL.
            if [[ "${ssh_user}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                local ssh_user_esc; ssh_user_esc="$(printf '%s' "${ssh_user}" | sed -e 's/[&/\\]/\\&/g')"
                sed -i "s/@@TS_SSH_USER@@/${ssh_user_esc}/g" "${policy_file}"
                log "headscale SSH ACL scoped to privileged user '${ssh_user}' (root + others denied)"
            else
                warn "SSH ACL user '${ssh_user}' is not a valid username ([a-z_][a-z0-9_-]*) — leaving placeholder (no SSH granted)"
            fi
        fi
        # stderr was previously sent to /dev/null, which is exactly why this failure has
        # never been diagnosable: the warning guessed at two possible causes and printed
        # neither the real one. Capture it and say what actually went wrong.
        local policy_err policy_rc=0
        policy_err="$(headscale policy set -f "${policy_file}" 2>&1)" || policy_rc=$?
        if [ "${policy_rc}" -eq 0 ]; then
            log "Loaded headscale ACL policy from ${policy_file}"
        else
            warn "headscale policy set failed for ${policy_file}: ${policy_err:-<no output>}"
            # config.yaml ships policy.mode=file (specs/etc/headscale/config.yaml:42-44),
            # where the policy is read at STARTUP and `policy set` is not the reload path.
            # The @@TS_SSH_USER@@ substitution above runs AFTER `rc-service headscale
            # start` (earlier in this function), so with no reload the RUNNING server keeps
            # serving the PRE-substitution policy — i.e. the "SSH ACL scoped to privileged
            # user" line logged just above is not true of the live tailnet. (It fails
            # CLOSED: the unsubstituted literal placeholder matches no user, so nobody is
            # granted tailnet SSH. Misleading rather than dangerous — but the intended ACL
            # is not in force.) Restart so the rewritten file is actually loaded.
            #
            # NB this restart is the one that used to die on a root-owned
            # /var/log/headscale.log; see the checkpath in specs/etc/init.d/headscale.
            if rc-service headscale restart >/dev/null 2>&1; then
                log "headscale restarted to load ${policy_file} (policy.mode=file reloads at startup)"
            else
                warn "headscale restart FAILED — the running server is still using the policy it read at startup"
            fi
        fi
    else
        warn "No headscale policy.hujson found — tailnet runs allow-all (no tags/route approval)"
    fi

    # Defensive backfill: approve the pod + service routes for any fleet node
    # that registered before the policy was loaded. autoApprovers makes this a
    # no-op for nodes that join afterwards. Routes/CIDRs mirror
    # kubernetes/kubeadm-config.yaml (podSubnet/serviceSubnet).
    local mesh_routes id
    mesh_routes="$(jqm '.tailscale.mesh_routes // "10.244.0.0/16,10.96.0.0/12"')"
    [ -n "${mesh_routes}" ] && [ "${mesh_routes}" != "null" ] || mesh_routes="10.244.0.0/16,10.96.0.0/12"
    if headscale nodes list -o json >/dev/null 2>&1; then
        for id in $(headscale nodes list -o json 2>/dev/null | jq -r '.[].id' 2>/dev/null); do
            [ -n "${id}" ] && [ "${id}" != "null" ] || continue
            headscale nodes approve-routes -i "${id}" -r "${mesh_routes}" 2>/dev/null \
                && log "Approved routes ${mesh_routes} for headscale node ${id}" || true
        done
    fi
}

# ── Stable MagicDNS control-plane record (autodiscovery anchor) ────
# Give the k8s control plane a fixed, role-independent name resolvable over the
# tailnet so additional control-plane nodes + workers + freshly-joined mesh
# nodes can target it WITHOUT a baked-in CP IP. We map .mesh.cp_dns_name
# (default kube-api.<base_domain>) -> the control node's TAILNET IP via
# headscale dns.extra_records, then reload headscale so MagicDNS serves it.
# Idempotent: re-running replaces the managed block. Only meaningful on the
# control (headscale) node, after it has joined its own tailnet.
publish_cp_dns_record() {
    have headscale || return 0
    [ -f /etc/headscale/config.yaml ] || return 0
    local cpname tip
    cpname="$(resolve_cp_dns_name)"
    [ -n "${cpname}" ] || return 0
    # This node's tailnet IP (it is the control plane / first CP). Prefer the
    # local client; fall back to whatever headscale recorded for this node.
    tip="$(tailscale ip -4 2>/dev/null | head -1)"
    if [ -z "${tip}" ] && have headscale; then
        tip="$(headscale nodes list -o json 2>/dev/null \
                | jq -r --arg h "$(hostname)" '.[] | select(.given_name==$h or .name==$h) | .ip_addresses[]?' 2>/dev/null \
                | grep -E '^100\.' | head -1)"
    fi
    [ -n "${tip}" ] || { warn "No tailnet IP yet for CP DNS record ${cpname} — skipping"; return 0; }

    # Build a managed extra_records block and splice it into config.yaml,
    # replacing any previous managed block. headscale 0.23.x accepts an inline
    # dns.extra_records list of {name,type,value}.
    python3 - "$cpname" "$tip" <<'PY' 2>/dev/null || { warn "Failed to write CP DNS record"; return 0; }
import sys, re, io
cpname, tip = sys.argv[1], sys.argv[2]
p = "/etc/headscale/config.yaml"
txt = open(p).read()
block = ("  # >>> hugmesh cp dns (managed)\n"
         "  extra_records:\n"
         f"    - name: \"{cpname}\"\n"
         "      type: \"A\"\n"
         f"      value: \"{tip}\"\n"
         "  # <<< hugmesh cp dns (managed)\n")
# Drop any prior managed block.
txt = re.sub(r"  # >>> hugmesh cp dns \(managed\).*?  # <<< hugmesh cp dns \(managed\)\n",
             "", txt, flags=re.S)
# Insert under the top-level dns: mapping (after its first line).
lines = txt.splitlines(keepends=True)
out, inserted = [], False
for i, ln in enumerate(lines):
    out.append(ln)
    if not inserted and re.match(r"^dns:\s*$", ln):
        out.append(block); inserted = True
if not inserted:
    out.append("\ndns:\n  magic_dns: true\n"); out.append(block)
open(p, "w").write("".join(out))
PY
    chown headscale:headscale /etc/headscale/config.yaml 2>/dev/null || true
    log "Published MagicDNS CP record ${cpname} -> ${tip}"
    rc-service headscale restart 2>/dev/null || warn "headscale reload after CP DNS record failed"
}

# ── Tailscale client ───────────────────────────────────────────────
provision_tailscale() {
    have tailscaled || { log "tailscaled not installed — skipping"; return 0; }
    local enabled
    enabled="$(jqm '.tailscale.enabled // false')"
    if [ "${enabled}" != "true" ]; then
        log "tailscale disabled in manifest — removing from runlevel"
        rc-update del tailscaled default 2>/dev/null || true
        rc-service tailscaled stop 2>/dev/null || true
        return 0
    fi

    mkdir -p /var/lib/tailscale /run/tailscale
    rc-update add tailscaled default 2>/dev/null || true
    rc-service tailscaled start 2>/dev/null || warn "tailscaled failed to start"
    sleep 2

    local akf authkey login up_args
    akf="$(jqm '.tailscale.authkey_file // "tailscale/authkey"')"
    [ -f "${BASE}/${akf}" ] && authkey="$(tr -d '[:space:]' < "${BASE}/${akf}")" || authkey=""
    # Control-node self-join: on the headscale node the KEYS stick carries no
    # tailscale/authkey (it MINTS keys). Fall back to the preauth key headscale
    # just minted for the fleet user so the control node also joins its own mesh
    # (advertises tag:hugmesh + pod/service routes, --accept-routes). Without
    # this the pki node stays off the tailnet and its pki-tier pods/ClusterIPs
    # (Vault, Casdoor, headscale, control-plane) are unreachable cross-node.
    if [ -z "${authkey}" ]; then
        local mintkey
        mintkey="$(ls -1 /var/lib/headscale/preauthkeys/*.key 2>/dev/null | head -1)"
        [ -n "${mintkey}" ] && [ -f "${mintkey}" ] && {
            authkey="$(tr -d '[:space:]' < "${mintkey}")"
            [ -n "${authkey}" ] && log "Using locally-minted headscale preauth key for control-node self-join"
        }
    fi
    login="$(jqm '.tailscale.login_server // ""')"
    # Local-first: if no explicit login_server, derive the control server URL.
    # On the CONTROL node (headscale enabled) that is its own resolve_endpoint
    # (configured override else its own LAN IP). On a WORKER / additional CP it
    # is resolve_control_endpoint -> the PKI node (override / brand HEADSCALE_URL
    # / the pki node's LAN IP from .nodes[]), never the worker's own LAN IP. So a
    # pre-public-domain worker still reaches the control server over the LAN.
    if [ -z "${login}" ] || [ "${login}" = "null" ]; then
        if [ "$(jqm '.headscale.enabled // false')" = "true" ]; then
            login="$(resolve_endpoint)"
        else
            login="$(resolve_control_endpoint)"
        fi
        [ -n "${login}" ] && log "tailscale login_server defaulted to ${login}"
    fi
    up_args="$(jqm '.tailscale.up_args // ""')"
    if [ -n "${authkey}" ]; then
        local cmd=(tailscale up --authkey "${authkey}")
        [ -n "${login}" ] && [ "${login}" != "null" ] && cmd+=(--login-server "${login}")
        # shellcheck disable=SC2206
        [ -n "${up_args}" ] && [ "${up_args}" != "null" ] && cmd+=(${up_args})
        # HARDENED DEFAULT: expose Tailscale SSH (--ssh) so the operator can reach
        # the node over the tailnet — but ONLY as the privileged user, enforced by
        # the headscale SSH ACL (provision_headscale, scoped to resolve_ssh_user;
        # root + others denied). Opt out per-node with .tailscale.ssh=false; or if
        # up_args already carries --ssh we don't duplicate it. SSH stays tailnet-
        # only (Tailscale SSH binds the tailnet, not the public interface).
        local ts_ssh; ts_ssh="$(jqm '.tailscale.ssh // true')"
        if [ "${ts_ssh}" != "false" ] && [[ " ${up_args} " != *" --ssh "* ]]; then
            cmd+=(--ssh)
        fi
        if "${cmd[@]}" 2>/dev/null; then
            log "tailscale up succeeded"
        else
            warn "tailscale up failed"
        fi
    fi

    # On the control (headscale) node, now that we are on the tailnet, publish
    # the stable MagicDNS control-plane record so additional CPs / workers /
    # autodiscovering nodes can resolve the API endpoint over the mesh.
    if [ "$(jqm '.headscale.enabled // false')" = "true" ] && have headscale; then
        publish_cp_dns_record
        # Layer-A: wire the headscale-policy renderer + server-forced-tag pass +
        # boot/cron sync (CENTRALIZED on the control node ONLY). The socket + mesh
        # are up now, so the first best-effort render can apply immediately if the
        # BFF /export is already reachable; otherwise the baked bootstrap policy
        # holds (no mesh outage). gated internally on headscale.enabled.
        provision_headscale_policy_sync
    fi
}

# ── Device-license registry (Layer-B per-node sshd enforcement) ────
# Wire the signed-export-driven sshd key source on the CORRECT node class. This is
# the load-bearing host boundary (Layer-A headscale is advisory until the OIDC
# join lands), shipped FIRST and INDEPENDENT of policy.hujson.
#
# HOST-KEY MODEL (Option (A), the only defensible choice — see
# hugmesh-device-license-registry memory):
#   * owner_type==ADMIN (mesh-extension nodes): the registry IS the key source.
#     We stage device-registry.conf (AuthorizedKeysFile none + AuthorizedKeysCommand
#     + AuthorizedKeysCommandUser nobody), install break-glass.conf, bake node.env
#     (MACHINE_KEY_FP + MESH_ID + the BFF transport config), copy the BAKED
#     registry public verifying key, prime the (empty => fail-closed) cache, and
#     enable the sync service + 60s cron. The enforcement drop-in is NOT placed in
#     sshd_config.d yet — the sync agent flips it on the FIRST verified sync
#     (Option (i) bootstrap gate, mirroring selinux-enforce-gate) so the #66-baked
#     admin key remains the bootstrap key until a real signed export exists (no
#     first-boot brick).
#   * owner_type==SUPERADMIN (primary / core nodes, the DEFAULT): DO NOTHING to
#     sshd. The #66 install_authorized_keys path stays the SOLE key source for the
#     superadmin owner; we never install the command/conf. A core node's export
#     entry does not exist by design (the BFF SKIPS superadmin-owned nodes), so an
#     AuthorizedKeysCommand here would lock the owner out — the structural reason
#     a core node is simply NOT a registry-enforced node. Reachability for the
#     superadmin is the Layer-A headscale concern.
#
# NO client (laptop/Chromebook) Layer-B: client images are decrypt-to-desktop
# end-user devices, not SSH-serving cluster nodes; they neither run the command
# nor the sync agent (image_type=client is an inventory record, not an sshd host).
provision_device_registry() {
    local reg_dir=/etc/hugmesh/registry
    local cache_dir=/var/lib/hugmesh/device-registry

    # (a) Resolve the OWNER TYPE / image class. Today only PRIMARY images exist
    # (the admin mesh-extension build path is the documented TODO), so the SAFE
    # default is SUPERADMIN; ADMIN is selected explicitly via the manifest. Honour
    # (in precedence) .device_registry.owner_type, else an ADMIN image_type, else
    # SUPERADMIN. .device_registry.image_type∈{primary,mesh-extension,client}.
    local owner_type image_type
    owner_type="$(jqm '.device_registry.owner_type // ""')"
    image_type="$(jqm '.device_registry.image_type // ""')"
    if [ -z "${owner_type}" ] || [ "${owner_type}" = "null" ]; then
        case "${image_type}" in
            mesh-extension) owner_type="ADMIN" ;;
            *)              owner_type="SUPERADMIN" ;;   # primary/client/unknown
        esac
    fi

    if [ "${owner_type}" != "ADMIN" ]; then
        # (c) SUPERADMIN / core / client: registry-enforced sshd is NOT installed.
        log "device-registry: owner_type=${owner_type} (image_type=${image_type:-primary}) — KEEPING #66 owner-key sshd; NOT installing registry enforcement (correct for core/client nodes)"
        return 0
    fi

    # ── owner_type==ADMIN: install Layer-B enforcement (gated, fail-closed) ─────
    log "device-registry: owner_type=ADMIN (mesh-extension) — installing Layer-B sshd enforcement (gated on first verified sync)"
    mkdir -p "${reg_dir}" "${cache_dir}"
    # The cache + baked pub + node.env must be readable by AuthorizedKeysCommandUser
    # =nobody. They carry NO private material (fingerprints + a public key only).
    chmod 0755 "${cache_dir}" "${reg_dir}" 2>/dev/null || true

    # The lookup + sync + verify helper are BAKED into the image rootfs by the
    # builders. Sanity-check they are present + executable (additive: a stale image
    # without them just stays in bootstrap, never bricks).
    [ -x /usr/sbin/hugmesh-authorized-keys-lookup ] \
        || warn "device-registry: /usr/sbin/hugmesh-authorized-keys-lookup missing from image (Layer-B will fail-closed deny until baked)"
    [ -x /usr/sbin/hugmesh-device-registry-sync ] \
        || warn "device-registry: /usr/sbin/hugmesh-device-registry-sync missing from image (no sync; cache stays empty)"
    [ -r /usr/lib/hugmesh/registry-verify.sh ] \
        || warn "device-registry: /usr/lib/hugmesh/registry-verify.sh missing from image (verify unavailable)"

    # Install the break-glass drop-in (console/loopback-only, default-OFF — the
    # referenced /etc/ssh/break-glass.keys is absent, so it yields NO bypass until
    # an operator physically drops a key). The staged copy lives at
    # ${reg_dir}/break-glass.conf (baked); place it into sshd_config.d now so the
    # console recovery path exists even before the enforcement gate flips.
    if [ -f "${reg_dir}/break-glass.conf" ]; then
        cp -f "${reg_dir}/break-glass.conf" /etc/ssh/sshd_config.d/break-glass.conf
        chmod 0644 /etc/ssh/sshd_config.d/break-glass.conf
        log "device-registry: installed console-only break-glass drop-in (default-OFF)"
    else
        warn "device-registry: break-glass.conf not baked at ${reg_dir} — console break-glass unavailable"
    fi
    # The enforcement drop-in (device-registry.conf) is STAGED at ${reg_dir} and
    # left OUT of sshd_config.d — the sync agent installs it on the FIRST verified
    # sync (Option (i) gate). It is baked to ${reg_dir}/device-registry.conf by the
    # builders. If absent, warn (the node stays bootstrap forever, never enforced).
    [ -f "${reg_dir}/device-registry.conf" ] \
        || warn "device-registry: device-registry.conf not staged at ${reg_dir} — enforcement gate can never flip (staying bootstrap)"

    # ── Baked node identity (NEVER self-claimed at SSH time) ───────────────────
    # MACHINE_KEY_FP: the node's headscale machine-key fingerprint. Preferred
    # source = KEYS/device-registry/machine_key_fp (baked by gen-provision-keys).
    # If empty (the fp is minted only at `tailscale up`), populate it POST-join
    # from local tailscale state and PIN it write-once. MESH_ID: KEYS file else
    # .mesh / .device_registry.mesh_id.
    local mkey mesh_id
    mkey=""
    [ -f "${BASE}/device-registry/machine_key_fp" ] && mkey="$(tr -d '[:space:]' < "${BASE}/device-registry/machine_key_fp" 2>/dev/null)"
    if [ -z "${mkey}" ]; then
        # POST-join self-read (write-once below). The headscale machine-key fp this
        # node reports locally MUST equal what the admin-bff stored in
        # device_registry.machine_key_fp — an fp-format mismatch fails closed
        # (everyone denied). This alignment is the highest-risk integration point;
        # see the PR body / device-registry README.
        mkey="$(tailscale status --json 2>/dev/null | jq -r '.Self.PublicKey // empty' 2>/dev/null)"
        [ -n "${mkey}" ] && log "device-registry: read MACHINE_KEY_FP from local tailscale state (post-join, write-once)"
    fi
    mesh_id="$(jqm '.device_registry.mesh_id // ""')"
    { [ -z "${mesh_id}" ] || [ "${mesh_id}" = "null" ]; } && mesh_id="$(jqm '.mesh.id // ""')"
    { [ -z "${mesh_id}" ] || [ "${mesh_id}" = "null" ]; } && [ -f "${BASE}/device-registry/mesh_id" ] \
        && mesh_id="$(tr -d '[:space:]' < "${BASE}/device-registry/mesh_id" 2>/dev/null)"

    # BFF /export transport config (the SUPERADMIN-equivalent in-cluster mTLS
    # identity). All optional: a missing URL/cert leaves the sync agent a verified
    # no-op (bootstrap/offline) and the node fail-closes to break-glass + the #66
    # baked key until a cert + reachable BFF land (EXPORT-TRANSPORT open issue).
    local bff_url bff_cert bff_key bff_ca
    bff_url="$(jqm '.device_registry.bff_export_url // ""')"
    bff_cert="$(jqm '.device_registry.bff_client_cert // ""')"
    bff_key="$(jqm '.device_registry.bff_client_key // ""')"
    bff_ca="$(jqm '.device_registry.bff_ca // "/etc/hugmesh/pki/ca-chain.crt"')"

    # Write node.env WRITE-ONCE for the identity fields (never a mutable self-claim
    # thereafter). If node.env already pins MACHINE_KEY_FP we keep it; we always
    # refresh the (non-identity) transport config.
    local existing_mkey=""
    [ -f "${reg_dir}/node.env" ] && existing_mkey="$(grep -E '^MACHINE_KEY_FP=' "${reg_dir}/node.env" 2>/dev/null | head -1 | cut -d= -f2-)"
    [ -n "${existing_mkey}" ] && mkey="${existing_mkey}"
    {
        echo "# device-registry node identity + BFF transport (Layer-B). MACHINE_KEY_FP"
        echo "# and MESH_ID are BAKED self-identity, NOT self-claimed at SSH time."
        echo "MACHINE_KEY_FP=${mkey}"
        echo "MESH_ID=${mesh_id}"
        echo "BFF_EXPORT_URL=${bff_url}"
        echo "BFF_CLIENT_CERT=${bff_cert}"
        echo "BFF_CLIENT_KEY=${bff_key}"
        echo "BFF_CA=${bff_ca}"
    } > "${reg_dir}/node.env"
    chmod 0644 "${reg_dir}/node.env"
    [ -n "${mkey}" ] || warn "device-registry: MACHINE_KEY_FP still EMPTY (not baked, no tailscale fp) — lookup will fail-closed deny until pinned"
    [ -n "${mesh_id}" ] || warn "device-registry: MESH_ID empty — sync + mesh guard will fail-closed"
    log "device-registry: wrote node.env (machine_key_fp=${mkey:-<unset>} mesh=${mesh_id:-<unset>})"

    # ── BAKED registry public verifying key (key-USB custody) ──────────────────
    # Copy the public half the node verifies the signed export against. NEVER the
    # advertised publicKey field. Source = KEYS/device-registry/registry-pub.ed25519.
    # Absent => the node fail-closes (denies all but break-glass) until baked.
    if [ -f "${BASE}/device-registry/registry-pub.ed25519" ] \
            && [ -s "${BASE}/device-registry/registry-pub.ed25519" ]; then
        cp -f "${BASE}/device-registry/registry-pub.ed25519" "${reg_dir}/registry-pub.ed25519"
        chmod 0644 "${reg_dir}/registry-pub.ed25519"
        log "device-registry: installed BAKED registry public key (export verified against THIS key)"
    else
        warn "device-registry: KEYS/device-registry/registry-pub.ed25519 ABSENT/empty — Layer-B fail-closes (deny all but break-glass) until the public half is baked onto the key-USB"
    fi

    # ── Prime the cache (empty => fail-closed until first verified sync) ────────
    # We do NOT seed any export here: an empty cache means the lookup denies (the
    # bootstrap path is the #66-baked admin key, valid until the gate flips). The
    # last-good-generation starts unset (first sync of any gen>=0 is accepted).
    [ -f "${cache_dir}/last-good-generation" ] || : > /dev/null

    # ── Enable the sync service (boot oneshot) + 60s cron (convergence floor) ──
    if [ -f /etc/init.d/hugmesh-device-registry-sync ]; then
        rc-update add hugmesh-device-registry-sync default 2>/dev/null \
            && log "device-registry: enabled hugmesh-device-registry-sync (boot sync)" \
            || warn "device-registry: rc-update add hugmesh-device-registry-sync failed"
    else
        warn "device-registry: init.d/hugmesh-device-registry-sync not baked — no boot sync"
    fi
    if [ -f "${reg_dir}/cron-device-registry-sync" ]; then
        cp -f "${reg_dir}/cron-device-registry-sync" /etc/cron.d/hugmesh-device-registry-sync
        chmod 0644 /etc/cron.d/hugmesh-device-registry-sync
        log "device-registry: installed 60s sync cron (convergence floor)"
    else
        warn "device-registry: cron drop-in not baked at ${reg_dir} — no 60s convergence poll"
    fi

    # Kick a first sync NOW (best-effort): if the BFF is already reachable this
    # immediately verifies + flips the enforcement gate; otherwise it keeps the
    # (empty) cache and the node stays in bootstrap (no brick).
    if [ -x /usr/sbin/hugmesh-device-registry-sync ]; then
        /usr/sbin/hugmesh-device-registry-sync 2>/dev/null || true
    fi

    # ── One-shot LIVENESS self-report (machine_key_fp AUTO-CAPTURE, reconciliation) ─
    # Announce this node's baked MACHINE_KEY_FP + hostname/mesh to the BFF's
    # mTLS-gated /bff/internal/device-enrollment/self-report (NO JWT, NO authorizing
    # data) so a superadmin can cross-check the node's self-claim against headscale
    # when picking from the PENDING list. RECONCILIATION TELEMETRY ONLY — it confers
    # no access (the trust gate is headscale + the superadmin assignment) and is
    # fail-soft: an unreachable BFF / missing cert is a no-op (NEVER blocks boot,
    # NEVER affects Layer-B SSH enforcement). admin-bff #68 (ships dark / advisory).
    if [ -x /usr/sbin/hugmesh-device-enrollment-report ]; then
        /usr/sbin/hugmesh-device-enrollment-report 2>/dev/null || true
    else
        warn "device-registry: /usr/sbin/hugmesh-device-enrollment-report missing from image (no liveness self-report; pending pick-list relies on headscale only)"
    fi
}

# ── Device-license registry — LAYER A (headscale tailnet ACL) ──────
# CENTRALIZED: wire the signed-export-driven headscale policy renderer + the
# server-forced-tag pass + the boot/cron sync ONLY on the headscale CONTROL (pki)
# node — the one node that holds the headscale socket + binary + DB. This is the
# SECOND enforcement layer off the SAME signed export Layer-B consumes (Layer-A is
# ADVISORY on the SSH source until OIDC users land; Layer-B is the load-bearing
# host boundary). The mesh-join flow (preauth key, self-applied tag:hugmesh) is
# UNTOUCHED; only the ACL/SSH plane headscale enforces is re-architected.
#
# Called from provision_tailscale's control-node branch (AFTER the control node
# has joined its own tailnet, so the socket + mesh are up), gated on
# `have headscale` && .headscale.enabled==true.
#
# It (a) stages /etc/hugmesh/registry/node.env transport reuse — the SAME file
# layout Layer-B reads (BFF_EXPORT_URL/CERT/KEY/CA + MESH_ID) PLUS a Layer-A-only
# TS_SSH_USER (the node-local privileged ssh account the generated ssh `users`
# list opens AS); (b) copies the BAKED registry-pub.ed25519 (REUSE Layer-B's
# baked key — never re-bake); (c) enables hugmesh-policy-sync + installs the
# 60s cron; (d) kicks one best-effort gen-headscale-policy.sh. FAIL-SOFT: a
# missing piece leaves the node on the baked bootstrap policy (no mesh outage).
provision_headscale_policy_sync() {
    have headscale || return 0
    [ "$(jqm '.headscale.enabled // false')" = "true" ] || return 0

    local reg_dir=/etc/hugmesh/registry
    local cache_dir=/var/lib/hugmesh/headscale-policy
    mkdir -p "${reg_dir}" "${cache_dir}"
    chmod 0700 "${cache_dir}" 2>/dev/null || true   # control-node-only; root reads

    # ── node.env (SHARED layout with Layer-B; Layer-A adds TS_SSH_USER) ─────────
    # On a SUPERADMIN/core control node, provision_device_registry returns early
    # and does NOT write node.env, so Layer-A writes it here. If Layer-B already
    # wrote one (an ADMIN control node — atypical), we PRESERVE its identity
    # fields and only ensure MESH_ID / TS_SSH_USER / the BFF transport are set.
    local mesh_id bff_url bff_cert bff_key bff_ca ssh_user
    mesh_id="$(jqm '.device_registry.mesh_id // ""')"
    { [ -z "${mesh_id}" ] || [ "${mesh_id}" = "null" ]; } && mesh_id="$(jqm '.mesh.id // ""')"
    { [ -z "${mesh_id}" ] || [ "${mesh_id}" = "null" ]; } && [ -f "${BASE}/device-registry/mesh_id" ] \
        && mesh_id="$(tr -d '[:space:]' < "${BASE}/device-registry/mesh_id" 2>/dev/null)"
    bff_url="$(jqm '.device_registry.bff_export_url // ""')"
    bff_cert="$(jqm '.device_registry.bff_client_cert // ""')"
    bff_key="$(jqm '.device_registry.bff_client_key // ""')"
    bff_ca="$(jqm '.device_registry.bff_ca // "/etc/hugmesh/pki/ca-chain.crt"')"
    ssh_user="$(resolve_ssh_user)"   # the LOCAL privileged unix account (NOT the operator)

    # Preserve an existing MACHINE_KEY_FP line if Layer-B already wrote node.env.
    local existing_mkey="" existing_line=""
    if [ -f "${reg_dir}/node.env" ]; then
        existing_line="$(grep -E '^MACHINE_KEY_FP=' "${reg_dir}/node.env" 2>/dev/null | head -1)"
        existing_mkey="${existing_line#MACHINE_KEY_FP=}"
    fi
    {
        echo "# device-registry node identity + BFF transport. Shared layout with"
        echo "# Layer-B (hugmesh-device-registry-sync) + Layer-A (gen-headscale-policy.sh)."
        echo "# MACHINE_KEY_FP / MESH_ID are BAKED self-identity, never self-claimed."
        echo "MACHINE_KEY_FP=${existing_mkey}"
        echo "MESH_ID=${mesh_id}"
        echo "BFF_EXPORT_URL=${bff_url}"
        echo "BFF_CLIENT_CERT=${bff_cert}"
        echo "BFF_CLIENT_KEY=${bff_key}"
        echo "BFF_CA=${bff_ca}"
        echo "# TS_SSH_USER (Layer-A): the node-local privileged unix account the"
        echo "# generated headscale ssh 'users' list opens a session AS (NOT the operator)."
        echo "TS_SSH_USER=${ssh_user}"
    } > "${reg_dir}/node.env"
    chmod 0644 "${reg_dir}/node.env"
    [ -n "${mesh_id}" ] || warn "policy-sync: MESH_ID empty — Layer-A sync + mesh guard will fail-closed (keep bootstrap policy)"
    log "policy-sync: wrote node.env (mesh=${mesh_id:-<unset>} ssh_user=${ssh_user})"

    # ── BAKED registry public verifying key (REUSE Layer-B's key-USB custody) ───
    if [ ! -s "${reg_dir}/registry-pub.ed25519" ] \
            && [ -f "${BASE}/device-registry/registry-pub.ed25519" ] \
            && [ -s "${BASE}/device-registry/registry-pub.ed25519" ]; then
        cp -f "${BASE}/device-registry/registry-pub.ed25519" "${reg_dir}/registry-pub.ed25519"
        chmod 0644 "${reg_dir}/registry-pub.ed25519"
        log "policy-sync: installed BAKED registry public key (Layer-A verifies the export against THIS key)"
    elif [ ! -s "${reg_dir}/registry-pub.ed25519" ]; then
        warn "policy-sync: registry-pub.ed25519 ABSENT — Layer-A fail-closes (keeps bootstrap policy) until the public half is baked onto the key-USB"
    fi

    # Sanity: the renderer + forcetags + template must be baked into the image.
    [ -x /usr/sbin/gen-headscale-policy.sh ] \
        || warn "policy-sync: /usr/sbin/gen-headscale-policy.sh missing from image (no Layer-A render; staying on bootstrap policy)"
    [ -x /usr/sbin/hugmesh-headscale-forcetags ] \
        || warn "policy-sync: /usr/sbin/hugmesh-headscale-forcetags missing (server-forced dst tags NOT applied; generated edges won't match)"
    [ -r /etc/headscale/policy.hujson.tmpl ] \
        || warn "policy-sync: /etc/headscale/policy.hujson.tmpl missing (renderer has no template; staying on bootstrap policy)"

    # ── Enable the boot sync service + 60s cron (convergence floor) ─────────────
    if [ -f /etc/init.d/hugmesh-policy-sync ]; then
        rc-update add hugmesh-policy-sync default 2>/dev/null \
            && log "policy-sync: enabled hugmesh-policy-sync (boot render+apply)" \
            || warn "policy-sync: rc-update add hugmesh-policy-sync failed"
    else
        warn "policy-sync: init.d/hugmesh-policy-sync not baked — no boot sync"
    fi
    if [ -f "${reg_dir}/cron-policy-sync" ]; then
        cp -f "${reg_dir}/cron-policy-sync" /etc/cron.d/hugmesh-policy-sync
        chmod 0644 /etc/cron.d/hugmesh-policy-sync
        log "policy-sync: installed 60s render cron (convergence floor)"
    else
        warn "policy-sync: cron drop-in not baked at ${reg_dir} — no 60s convergence poll"
    fi

    # Kick a first render NOW (best-effort): if the BFF is already reachable this
    # renders + applies the generated default-deny policy + forces server tags;
    # otherwise it KEEPS the baked bootstrap policy (no mesh outage, fail-closed).
    if [ -x /usr/sbin/gen-headscale-policy.sh ]; then
        /usr/sbin/gen-headscale-policy.sh 2>/dev/null || true
    fi
}

# ── Kubernetes ─────────────────────────────────────────────────────
# Shared kubeadm join helper. Workers omit the extra args; additional
# control-plane nodes pass `--control-plane --certificate-key <ck>`.
# Idempotent: a node that already has a kubelet.conf is treated as joined.
_kubeadm_join() {
    local api="$1" token="$2" hash="$3"; shift 3
    local extra=("$@")
    if [ -f /etc/kubernetes/kubelet.conf ]; then
        log "kubelet.conf present — node already joined, skipping kubeadm join"
        return 0
    fi
    if [ -z "${api}" ] || [ -z "${token}" ] || [ -z "${hash}" ]; then
        warn "Incomplete kubernetes.join block (api/token/ca_cert_hash) — cannot join"
        return 1
    fi
    log "Running kubeadm join against ${api}${extra:+ (${extra[*]})}"
    if kubeadm join "${api}" --token "${token}" \
            --discovery-token-ca-cert-hash "${hash}" "${extra[@]}"; then
        log "Joined cluster (${api})"
        return 0
    fi
    warn "kubeadm join failed against ${api}"
    return 1
}

# Distribute /etc/kubernetes/admin.conf to root + sudo users (control-plane).
_distribute_kubeconfig() {
    mkdir -p /root/.kube
    cp -f /etc/kubernetes/admin.conf /root/.kube/config 2>/dev/null || return 0
    local f="${BASE}/users.json"; [ -f "${f}" ] || f="${MANIFEST}"
    local n i nm home
    n="$(jq '(.users // []) | length' "${f}" 2>/dev/null || echo 0)"
    for ((i = 0; i < n; i++)); do
        [ "$(jq -r ".users[$i].sudo // false" "${f}")" = "true" ] || continue
        nm="$(jq -r ".users[$i].name" "${f}")"
        home="$(getent passwd "${nm}" | cut -d: -f6)"
        [ -n "${home}" ] || continue
        mkdir -p "${home}/.kube"
        cp -f /etc/kubernetes/admin.conf "${home}/.kube/config"
        chown -R "${nm}:" "${home}/.kube"
    done
}

# Label this control-plane node role=pki and remove the control-plane taint so
# the pki-tier workloads (Vault, Casdoor, Cassandra, headscale) schedule here.
_label_control_plane() {
    local sr; sr="$(jqm '.hugmesh.role // "pki"')"
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node "$(hostname)" "hugmesh.net/role=${sr}" --overwrite 2>/dev/null || true
    # NODE-STORAGE: the control-plane (x86 host) holds the cluster disks (/mnt/data,
    # /mnt/usb), so it ALWAYS carries hugmesh.net/local-path=true — the label
    # the local-path-provisioner DaemonSet schedules on. This is FULL BACK-COMPAT: the
    # provisioner runs here exactly as the old Deployment did (it kept its DEFAULT_PATH
    # nodePathMap). A node-storage node ALSO gets this label when its first pool is
    # provisioned (node-agent reconcile, PR6), which is what lets a pool on another node
    # get its own provisioner instance + nodePathMap entry.
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node "$(hostname)" "hugmesh.net/local-path=true" --overwrite 2>/dev/null || true
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl taint nodes "$(hostname)" node-role.kubernetes.io/control-plane- 2>/dev/null || true
    log "Control-plane node labelled role=${sr} + local-path=true, control-plane taint removed"
}

# Decide whether THIS control-plane node is the FIRST (bootstrap) CP or an
# ADDITIONAL one joining an existing HA control plane. Robust default: probe the
# stable control-plane endpoint's apiserver healthz over the mesh; if it answers
# the cluster already exists -> additional. Fall back to .kubernetes.bootstrap
# (true => first) when no probe target / curl is available.
_is_first_control_plane() {
    local cpep; cpep="$(resolve_cp_dns_name)"
    if [ -n "${cpep}" ] && have curl; then
        if curl -ksS -m 4 "https://${cpep}:6443/healthz" >/dev/null 2>&1; then
            log "Control-plane endpoint ${cpep}:6443 already healthy — joining as ADDITIONAL control-plane"
            return 1   # not first
        fi
    fi
    # No reachable endpoint: trust the explicit flag.
    # NOTE: read `first` WITHOUT jq's `//` alternative — `//` collapses the
    # boolean literal false to the default, so `.kubernetes.first // "x"` reads
    # first:false as "x". Use an explicit null test instead ("unset" only when
    # the key is truly absent).
    local first; first="$(jqm '.kubernetes.first | if .==null then "unset" else tostring end')"
    # An explicit first=false ALWAYS means "additional CP" — even when the
    # healthz probe failed (MagicDNS not yet converged / first CP briefly
    # unreachable at boot). Honouring it here is critical: falling through to
    # "first" would run `kubeadm init` and start a SECOND split-brain cluster.
    if [ "${first}" = "false" ]; then
        warn "first=false but control-plane endpoint not reachable yet — treating as ADDITIONAL (kubeadm join will retry the endpoint)"
        return 1       # additional
    fi
    [ "${first}" = "true" ] && return 0     # explicit first control plane
    # first unset: bootstrap=true (or anything else with no endpoint up) => first.
    return 0
}

# ── etcd Secret encryption-at-rest config (control-plane) ──────────
# Writes /etc/kubernetes/encryption-config.yaml so the apiserver encrypts Secret
# objects before persisting them to etcd. The kubeadm-config.yaml apiServer
# extraArgs point at this path; it MUST exist before `kubeadm init`/`join` so the
# static apiserver pod can mount it. Key custody (never in git):
#   1. KEYS/kubernetes/encryption-key on the USB stick (shared across control
#      planes so every apiserver decrypts the same etcd) — preferred.
#   2. else mint a fresh 32-byte key here (single-CP / dev) and persist it under
#      /etc/hugmesh so an operator can copy it to additional CPs.
# Provider: aescbc (AES-256-CBC, kube-native, no external KMS). A documented KMS
# path (Vault Transit) is in docs/ENCRYPTION-AT-REST.md. Idempotent: never
# rewrites an existing config (rotating the key would orphan existing Secrets).
ensure_encryption_config() {
    local cfg=/etc/kubernetes/encryption-config.yaml
    [ -f "${cfg}" ] && { log "encryption-config.yaml already present — keeping existing key"; return 0; }
    local key="" ksrc="${BASE}/kubernetes/encryption-key"
    if [ -f "${ksrc}" ]; then
        key="$(tr -d '[:space:]' < "${ksrc}" 2>/dev/null)"
        [ -n "${key}" ] && log "etcd encryption key loaded from KEYS (${ksrc#${BASE}/})"
    fi
    if [ -z "${key}" ] && [ -f /etc/hugmesh/etcd-encryption.key ]; then
        key="$(tr -d '[:space:]' < /etc/hugmesh/etcd-encryption.key 2>/dev/null)"
    fi
    if [ -z "${key}" ]; then
        key="$(head -c 32 /dev/urandom | base64 -w0 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -d '\n')"
        mkdir -p /etc/hugmesh
        printf '%s\n' "${key}" > /etc/hugmesh/etcd-encryption.key
        chmod 0600 /etc/hugmesh/etcd-encryption.key
        warn "minted a fresh etcd Secret-encryption key at /etc/hugmesh/etcd-encryption.key — COPY it to KEYS/kubernetes/encryption-key + every other control plane (or their etcd won't decrypt these Secrets)"
    fi
    mkdir -p /etc/kubernetes
    umask 077
    cat > "${cfg}" <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${key}
      # identity LAST so already-written plaintext Secrets are still readable
      # during the migration, then re-encrypted on next write.
      - identity: {}
EOF
    chmod 0600 "${cfg}"
    log "Wrote ${cfg} (aescbc) — apiserver will encrypt etcd Secrets at rest"
}

provision_kubernetes() {
    local role bootstrap cfg
    role="$(jqm '.kubernetes.role // "none"')"
    bootstrap="$(jqm '.kubernetes.bootstrap // false')"
    [ "${role}" = "none" ] || [ -z "${role}" ] && { log "No Kubernetes role set"; return 0; }
    log "Kubernetes role: ${role} (bootstrap=${bootstrap})"

    # Optional kubeadm config override
    cfg="$(jqm '.kubernetes.config_file // ""')"
    [ -n "${cfg}" ] && [ -f "${BASE}/${cfg}" ] \
        && cp -f "${BASE}/${cfg}" /etc/kubernetes/kubeadm-config.yaml \
        && log "Installed kubeadm config from ${cfg}"

    # Pre-generated PKI (shared CA across control-plane nodes)
    local pki
    pki="$(jqm '.kubernetes.pki_dir // ""')"
    if [ -n "${pki}" ] && [ -d "${BASE}/${pki}" ]; then
        mkdir -p /etc/kubernetes/pki
        cp -a "${BASE}/${pki}/." /etc/kubernetes/pki/
        chmod -R go-rwx /etc/kubernetes/pki
        log "Installed Kubernetes PKI from ${pki}"
    fi

    # Modules + sysctl needed regardless of bootstrap
    for m in overlay br_netfilter ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack vxlan; do
        modprobe "${m}" 2>/dev/null || true
    done
    sysctl --system >/dev/null 2>&1 || true

    [ "${bootstrap}" = "true" ] || {
        log "K8s config staged; skipping live bootstrap (set kubernetes.bootstrap=true to run kubeadm)"
        return 0
    }
    have kubeadm || { warn "kubeadm not installed"; return 0; }
    rc-service containerd start 2>/dev/null || true

    case "${role}" in
        control-plane|master|server)
            # etcd Secret encryption-at-rest config MUST exist before the
            # apiserver static pod starts (kubeadm-config apiServer.extraArgs
            # references it). Runs for first AND additional control planes.
            ensure_encryption_config
            # ── HA control plane: FIRST node inits, ADDITIONAL nodes join ──
            if [ -f /etc/kubernetes/admin.conf ]; then
                log "admin.conf present — control-plane already initialised, skipping"
                _distribute_kubeconfig
                _label_control_plane
            elif _is_first_control_plane; then
                # FIRST control plane: init with --upload-certs so additional
                # control-plane nodes can pull the shared certs by cert-key. The
                # kubeadm-config.yaml controlPlaneEndpoint is the stable MagicDNS
                # name (kube-api.<base_domain>) so every later join targets it.
                log "Running kubeadm init (first control-plane) --upload-certs"
                if kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs; then
                    _distribute_kubeconfig
                    _label_control_plane
                    # Persist fresh join material for additional CPs / workers so
                    # an operator can read it off this node (token + ca hash +
                    # certificate-key) without re-deriving by hand.
                    mkdir -p /etc/hugmesh
                    { kubeadm token create --print-join-command 2>/dev/null; } > /etc/hugmesh/kubeadm-join.cmd
                    local ck
                    ck="$(kubeadm init phase upload-certs --upload-certs 2>/dev/null \
                            | grep -Eo '[0-9a-f]{64}' | tail -1)"
                    [ -n "${ck}" ] && { echo "${ck}" > /etc/hugmesh/kubeadm-certificate-key; chmod 0600 /etc/hugmesh/kubeadm-certificate-key; }
                    chmod 0600 /etc/hugmesh/kubeadm-join.cmd 2>/dev/null || true
                    log "First control plane initialised; join material in /etc/hugmesh/kubeadm-join.cmd"
                else
                    warn "kubeadm init failed — inspect ${LOG}"
                fi
            else
                # ADDITIONAL control plane: join the existing HA control plane.
                local api token hash certkey
                api="$(jqm '.kubernetes.join.api_server // ""')"
                token="$(jqm '.kubernetes.join.token // ""')"
                hash="$(jqm '.kubernetes.join.ca_cert_hash // ""')"
                certkey="$(jqm '.kubernetes.join.certificate_key // ""')"
                # Default the join target to the stable MagicDNS CP endpoint.
                { [ -z "${api}" ] || [ "${api}" = "null" ]; } && api="$(resolve_cp_dns_name):6443"
                if [ -z "${certkey}" ] || [ "${certkey}" = "null" ]; then
                    warn "Additional control-plane requires .kubernetes.join.certificate_key — cannot join"
                else
                    if _kubeadm_join "${api}" "${token}" "${hash}" --control-plane --certificate-key "${certkey}"; then
                        _distribute_kubeconfig
                        _label_control_plane
                    fi
                fi
            fi
            ;;
        worker|node|agent)
            local api token hash
            api="$(jqm '.kubernetes.join.api_server // ""')"
            token="$(jqm '.kubernetes.join.token // ""')"
            hash="$(jqm '.kubernetes.join.ca_cert_hash // ""')"
            # Default the join target to the stable MagicDNS CP endpoint so
            # workers autodiscover the API over the mesh (no baked CP IP needed).
            { [ -z "${api}" ] || [ "${api}" = "null" ]; } && api="$(resolve_cp_dns_name):6443"
            _kubeadm_join "${api}" "${token}" "${hash}"
            ;;
        *)
            warn "Unknown kubernetes.role: ${role}"
            ;;
    esac
}

# ── Attached storage (M.2 / NVMe / USB) ────────────────────────────
# Resolve a storage device from a match token: "nvme" | "usb" | /dev/path |
# LABEL=x | UUID=x. For "usb" we skip the KEYS stick itself.
resolve_storage_dev() {
    local m="$1"
    case "${m}" in
        nvme) ls /dev/nvme[0-9]n[0-9] 2>/dev/null | head -1 ;;
        usb)
            local keysdev; keysdev="$(findmnt -no SOURCE "${MOUNT}" 2>/dev/null | sed 's/[0-9]*$//')"
            lsblk -dnp -o NAME,TRAN,TYPE 2>/dev/null | awk '$2=="usb" && $3=="disk"{print $1}' \
                | grep -v "^${keysdev}$" | head -1 ;;
        LABEL=*) blkid -L "${m#LABEL=}" 2>/dev/null ;;
        UUID=*)  blkid -U "${m#UUID=}" 2>/dev/null ;;
        /dev/*)  echo "${m}" ;;
        *)       blkid -L "${m}" 2>/dev/null ;;
    esac
}

# ── LUKS2 encryption-at-rest for attached data partitions ─────────
# Resolve the LUKS passphrase/keyfile (key custody, never in git). Precedence:
#   1. KEYS/secrets/luks.key on the offline USB stick (same custody model as the
#      cluster CA + Vault seal keys) — the Pi5-without-TPM default.
#   2. provision.json .storage.luks_keyfile (a path on the KEYS media).
# Prints the resolved keyfile path to stdout, empty if none found. TPM2 auto-
# unlock is enrolled SEPARATELY (luks_try_tpm2_enroll) so the volume can later
# open with NO keyfile present; the USB keyfile stays the recovery slot.
luks_keyfile() {
    local kf
    kf="$(jqm '.storage.luks_keyfile // ""')"
    { [ -z "${kf}" ] || [ "${kf}" = "null" ]; } && kf="secrets/luks.key"
    [ -f "${BASE}/${kf}" ] && { printf '%s\n' "${BASE}/${kf}"; return 0; }
    [ -f "${BASE}/secrets/luks.key" ] && { printf '%s\n' "${BASE}/secrets/luks.key"; return 0; }
    printf ''
}

# Best-effort TPM2 auto-unlock enrolment so the node unlocks at boot WITHOUT the
# USB key present (x86 + Pi-with-TPM). Tries systemd-cryptenroll first, then
# clevis (tang/tpm2). No-op (and harmless) where no TPM / tool exists — the USB
# keyfile slot remains the unlock path. Idempotent: skips if a token is enrolled.
# Best-effort TPM2 auto-unlock enrolment so the node unlocks at boot WITHOUT the
# USB key present (x86 + Pi-with-TPM). Tries systemd-cryptenroll first, then
# clevis (tang/tpm2). No-op (and harmless) where no TPM / tool exists — the USB
# keyfile slot remains the unlock path. Idempotent: skips if a token is enrolled.
# ALL output is diagnostic (no stdout contract) — callers in a command-subst
# context redirect this to stderr.
luks_try_tpm2_enroll() {
    local part="$1" keyfile="$2"
    [ "$(jqm '.storage.luks_tpm2 // true')" = "true" ] || { log "TPM2 auto-unlock disabled in manifest"; return 0; }
    [ -e /dev/tpmrm0 ] || [ -e /dev/tpm0 ] || { log "No TPM device — keeping USB-keyfile unlock for ${part}"; return 0; }
    if have systemd-cryptenroll; then
        if cryptsetup luksDump "${part}" 2>/dev/null | grep -qi 'systemd-tpm2'; then
            log "TPM2 already enrolled on ${part}"; return 0
        fi
        if PASSWORD="$(cat "${keyfile}")" systemd-cryptenroll --tpm2-device=auto \
                --tpm2-pcrs=7 "${part}" 2>/dev/null; then
            log "Enrolled TPM2 auto-unlock on ${part} (systemd-cryptenroll, PCR7)"; return 0
        fi
        warn "systemd-cryptenroll TPM2 enrolment failed on ${part} — USB keyfile remains the unlock path"
    elif have clevis; then
        if clevis luks bind -d "${part}" tpm2 '{"pcr_ids":"7"}' -k "${keyfile}" 2>/dev/null; then
            log "Bound TPM2 auto-unlock on ${part} (clevis)"; return 0
        fi
        warn "clevis TPM2 bind failed on ${part} — USB keyfile remains the unlock path"
    else
        log "Neither systemd-cryptenroll nor clevis present — USB-keyfile unlock only for ${part}"
    fi
}

# Wrap a raw partition in LUKS2 and open it. STDOUT CONTRACT: emits exactly the
# device the caller should mkfs+mount — the unlocked mapper (/dev/mapper/<name>)
# on success, or the raw partition unchanged on any fallback. ALL diagnostics go
# to STDERR so `dev=$(luks_open_or_format …)` captures only the device path.
# aes-xts-plain64, 512-bit key, sha512/argon2id PBKDF — strong + interoperable.
# Idempotent: an already-LUKS partition is just opened, never re-formatted (so
# re-provisioning never destroys encrypted data). Returns non-zero on fallback.
luks_open_or_format() {
    # $5 (optional) = EXTRA crypttab options appended after the base `luks,
    # tpm2-device=auto` — node-storage passes `nofail` so a removed pool disk
    # DEGRADES the pool rather than blocking the boot. Unset = system-disk
    # behaviour unchanged (no nofail; a missing system disk SHOULD halt the boot).
    local part="$1" name="$2" do_format="$3" keyfile="$4" extra_opts="${5:-}"
    have cryptsetup || { warn "cryptsetup not installed — cannot encrypt ${part}; falling back to PLAINTEXT" >&2; printf '%s\n' "${part}"; return 1; }
    [ -n "${keyfile}" ] || { warn "no LUKS keyfile (KEYS/secrets/luks.key) — cannot encrypt ${part}; falling back to PLAINTEXT" >&2; printf '%s\n' "${part}"; return 1; }
    local mapper="/dev/mapper/${name}"
    if cryptsetup isLuks "${part}" 2>/dev/null; then
        log "${part} is already LUKS — opening as ${name}" >&2
    else
        if [ "${do_format}" != "true" ]; then
            warn "${part} is not LUKS and format=false — refusing to encrypt in place; PLAINTEXT" >&2
            printf '%s\n' "${part}"; return 1
        fi
        log "luksFormat ${part} (LUKS2 aes-xts-plain64, 512-bit, argon2id) — destroying existing data" >&2
        cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 \
            --hash sha512 --pbkdf argon2id --batch-mode "${part}" "${keyfile}" \
            || { warn "luksFormat ${part} failed — PLAINTEXT fallback" >&2; printf '%s\n' "${part}"; return 1; }
    fi
    if [ ! -b "${mapper}" ]; then
        cryptsetup open --key-file "${keyfile}" "${part}" "${name}" \
            || { warn "cryptsetup open ${part} failed — PLAINTEXT fallback" >&2; printf '%s\n' "${part}"; return 1; }
    fi
    # Persist a crypttab entry so the volume re-opens on every boot. Key source is
    # the USB keyfile path; TPM2 (if enrolled) unlocks without it. tpm2-device=
    # auto lets systemd try the TPM token first, falling back to the keyfile.
    local puuid; puuid="$(blkid -s UUID -o value "${part}" 2>/dev/null)"
    if [ -n "${puuid}" ] && { [ ! -f /etc/crypttab ] || ! grep -q "${name}" /etc/crypttab; }; then
        # Base options + any caller extras (node-storage appends `nofail`).
        local cryptopts="luks,tpm2-device=auto"
        [ -n "${extra_opts}" ] && cryptopts="${cryptopts},${extra_opts}"
        printf '%s UUID=%s /etc/hugmesh/luks/%s.key %s\n' \
            "${name}" "${puuid}" "${name}" "${cryptopts}" >> /etc/crypttab
        # Install the recovery keyfile off the read-only USB into a 0600 root path
        # so crypttab can read it at boot (TPM2 unlock makes it a fallback only).
        install -Dm0600 "${keyfile}" "/etc/hugmesh/luks/${name}.key" 2>/dev/null || true
        log "Added ${name} to /etc/crypttab (UUID=${puuid}, TPM2-or-keyfile unlock)" >&2
    fi
    luks_try_tpm2_enroll "${part}" "${keyfile}" >&2
    printf '%s\n' "${mapper}"
}

provision_storage() {
    # ── NODE-STORAGE pool mode ──────────────────────────────────────────────
    # `provision_storage --pool` (re-run by the node-agent reconcile, PR6)
    # provisions ONLY the device(s) carrying a `pool:{}` marker — the ADDITIONAL
    # storage an operator attached + registered — and SKIPS the cluster/system
    # disks. Calling it with no argument is the FIRST-BOOT path: it provisions
    # ALL .storage.devices[] exactly as before (system disks AND any pool disks
    # baked into the manifest). The function is otherwise VERBATIM — a registered
    # pool disk is just a new .storage.devices[] element with `pool:{}` set; the
    # ONLY behavioural change is `,nofail` on a pool's crypttab/fstab so a removed
    # pool disk DEGRADES the pool, never blocks the boot.
    local only_pool=false
    [ "${1:-}" = "--pool" ] && only_pool=true

    jqe '.storage.devices' || return 0
    local n i
    n="$(jqm '.storage.devices | length')"
    if [ "${only_pool}" = "true" ]; then
        log "Reconciling node-storage pool device(s) only (--pool)"
    else
        log "Configuring ${n} attached storage device(s)"
    fi
    for ((i = 0; i < n; i++)); do
        local match fs fmt mp opts label dev part uuid usefor encrypt luksname blkdev is_pool
        match="$(jqm ".storage.devices[$i].match")"
        fs="$(jqm ".storage.devices[$i].filesystem // \"ext4\"")"
        fmt="$(jqm ".storage.devices[$i].format // false")"
        mp="$(jqm ".storage.devices[$i].mountpoint")"
        opts="$(jqm ".storage.devices[$i].options // \"defaults,noatime\"")"
        label="$(jqm ".storage.devices[$i].label // \"\"")"
        # FAIL-CLOSED validation of manifest-sourced fields that reach root sinks:
        #  - fs selects the `mkfs.<fs>` binary and the `parted mkpart` fs-type -> restrict
        #    to a filesystem-name charset so it cannot name an unexpected binary.
        #  - mp (mountpoint) + opts (mount options) are written whitespace-delimited into
        #    /etc/fstab and passed to `mount`; a space/newline would shift columns or
        #    inject an extra fstab line. Skip (do not format/mount) a malformed device.
        if [[ ! "${fs}" =~ ^[a-z0-9]+$ ]]; then
            warn "storage[$i]: filesystem '${fs}' is not a valid fs name ([a-z0-9]) — skipping device"; continue
        fi
        if [ -n "${mp}" ] && [[ ! "${mp}" =~ ^/[A-Za-z0-9._/-]*$ ]]; then
            warn "storage[$i]: mountpoint '${mp}' is not a safe absolute path — skipping device"; continue
        fi
        if [[ ! "${opts}" =~ ^[A-Za-z0-9=,.:_@/+-]+$ ]]; then
            warn "storage[$i]: mount options '${opts}' contain unsafe characters — skipping device"; continue
        fi
        usefor="$(jqm ".storage.devices[$i].use_for // [] | join(\" \")")"
        # NODE-STORAGE: a device with a `pool` object is an attached, registered
        # storage pool (node-pinned local-path space) — NOT a system/cluster disk.
        is_pool=false
        jqe ".storage.devices[$i].pool" && is_pool=true
        # In --pool mode skip non-pool (system) disks; on first boot do everything.
        if [ "${only_pool}" = "true" ] && [ "${is_pool}" != "true" ]; then continue; fi
        # Encryption-at-rest (LUKS2). Default ON: cluster data partitions (the
        # disks that back PVCs + relocated containerd/kubelet/Vault state) are
        # encrypted unless a device explicitly opts out with encrypt:false.
        encrypt="$(jqm ".storage.devices[$i].encrypt // true")"
        luksname="$(jqm ".storage.devices[$i].luks_name // \"\"")"
        { [ -z "${luksname}" ] || [ "${luksname}" = "null" ]; } && luksname="cryptdata${i}"

        dev="$(resolve_storage_dev "${match}")"
        [ -n "${dev}" ] && [ -b "${dev}" ] || { warn "storage[$i]: no device for match '${match}'"; continue; }
        [ -n "${mp}" ] || { warn "storage[$i]: no mountpoint"; continue; }
        log "storage[$i]: ${match} -> ${dev}  mount ${mp} (${fs}, format=${fmt}, encrypt=${encrypt})"

        if [ "${fmt}" = "true" ]; then
            warn "Formatting ${dev} as ${fs} (single GPT partition) — destroying existing data"
            wipefs -a "${dev}" 2>/dev/null || true
            parted -s "${dev}" mklabel gpt
            parted -s "${dev}" mkpart primary "${fs}" 1MiB 100%
            sleep 1; partprobe "${dev}" 2>/dev/null || true; sleep 1
        fi
        if [[ "${dev}" =~ [0-9]$ ]]; then part="${dev}p1"; else part="${dev}1"; fi
        [ -b "${part}" ] || part="${dev}"   # whole-disk fs fallback

        # ── Encryption-at-rest: wrap the partition in LUKS2 before mkfs ──
        # blkdev becomes the device we mkfs + mount (the /dev/mapper/<name> when
        # encrypted, else the raw partition). On any failure luks_open_or_format
        # echoes the raw partition and returns non-zero -> documented plaintext
        # fallback so the node still boots (logged as a WARNING).
        blkdev="${part}"
        if [ "${encrypt}" = "true" ]; then
            local kf; kf="$(luks_keyfile)"
            # NODE-STORAGE: a pool disk gets `nofail` in crypttab so a removed pool
            # disk DEGRADES the pool, never blocks the boot.
            local crypt_extra=""
            [ "${is_pool}" = "true" ] && crypt_extra="nofail"
            blkdev="$(luks_open_or_format "${part}" "${luksname}" "${fmt}" "${kf}" "${crypt_extra}")" || \
                warn "storage[$i]: encryption unavailable — ${part} mounted PLAINTEXT (see docs/ENCRYPTION-AT-REST.md)"
        fi

        if [ "${fmt}" = "true" ]; then
            "mkfs.${fs}" ${label:+-L "${label}"} -F "${blkdev}" 2>/dev/null || "mkfs.${fs}" "${blkdev}"
        fi

        mkdir -p "${mp}"
        mount -o "${opts}" "${blkdev}" "${mp}" || { warn "mount ${blkdev} failed"; continue; }
        # fstab references the unlocked mapper by its UUID for encrypted volumes
        # (crypttab opens it first), or the raw partition UUID for plaintext.
        # NODE-STORAGE: append `,nofail` to a pool's fstab options so a removed pool
        # disk DEGRADES the pool rather than dropping the node to an emergency shell.
        local fstab_opts="${opts}"
        if [ "${is_pool}" = "true" ] && [[ ",${fstab_opts}," != *",nofail,"* ]]; then
            fstab_opts="${fstab_opts},nofail"
        fi
        uuid="$(blkid -s UUID -o value "${blkdev}" 2>/dev/null)"
        if [ -n "${uuid}" ] && ! grep -q "${uuid}" /etc/fstab; then
            printf 'UUID=%s  %s  %s  %s  0 2\n' "${uuid}" "${mp}" "${fs}" "${fstab_opts}" >> /etc/fstab
            if [ "${is_pool}" = "true" ]; then
                log "Added node-storage pool ${mp} to /etc/fstab (UUID=${uuid}, nofail)"
            else
                log "Added ${mp} to /etc/fstab (UUID=${uuid})"
            fi
        fi

        # Relocate service data directories onto the attached storage.
        for svc in ${usefor}; do
            local src
            case "${svc}" in
                containerd) src=/var/lib/containerd ;;
                kubelet)    src=/var/lib/kubelet ;;
                rancher|k3s) src=/var/lib/rancher ;;
                *) warn "use_for '${svc}' unknown"; continue ;;
            esac
            rc-service "${svc}" stop 2>/dev/null || true
            mkdir -p "${mp}/${svc}"
            if [ -d "${src}" ] && [ ! -L "${src}" ]; then
                cp -a "${src}/." "${mp}/${svc}/" 2>/dev/null || true
                rm -rf "${src}"
            fi
            ln -sfn "${mp}/${svc}" "${src}"
            log "Relocated ${src} -> ${mp}/${svc}"
        done
    done
}

# ── NODE-STORAGE reconcile — enable the pull agent (boot oneshot + 60s cron) ──
# The pull-half twin of the device-registry sync (hugmesh-device-registry-sync):
# ANY mesh node may host an attached + registered storage pool (SUPERADMIN- and
# ADMIN-owned alike — see docs/NODE-STORAGE.md's ownership matrix), so the agent
# is enabled on EVERY mesh node and is INERT by CONTENT, not by absence: without
# node.env it exits 0 keeping cache, and an unknown node fp gets the EMPTY signed
# body and provisions NOTHING. Mirrors provision_device_registry's enable idiom
# (rc-update boot oneshot + the builder-staged cron placed into /etc/cron.d) and
# its missing-binary warn pattern (additive: a stale image without the baked
# agent just never reconciles pools — it never bricks the boot).
provision_node_storage() {
    local reg_dir=/etc/hugmesh/registry
    local cache_dir=/var/lib/hugmesh/node-storage
    mkdir -p "${cache_dir}"

    # The agent + its verify lib are BAKED into the image rootfs by the builders.
    [ -x /usr/sbin/hugmesh-node-storage-reconcile ] \
        || warn "node-storage: /usr/sbin/hugmesh-node-storage-reconcile missing from image (pools never reconcile until baked)"
    [ -r /usr/lib/hugmesh/storage-verify.sh ] \
        || warn "node-storage: /usr/lib/hugmesh/storage-verify.sh missing from image (verify unavailable — agent keeps last-good cache)"

    # ── Enable the reconcile service (boot oneshot) + 60s cron (convergence floor) ──
    if [ -f /etc/init.d/hugmesh-node-storage-reconcile ]; then
        rc-update add hugmesh-node-storage-reconcile default 2>/dev/null \
            && log "node-storage: enabled hugmesh-node-storage-reconcile (boot reconcile)" \
            || warn "node-storage: rc-update add hugmesh-node-storage-reconcile failed"
    else
        warn "node-storage: init.d/hugmesh-node-storage-reconcile not baked — no boot reconcile"
    fi
    if [ -f "${reg_dir}/cron-node-storage-reconcile" ]; then
        cp -f "${reg_dir}/cron-node-storage-reconcile" /etc/cron.d/hugmesh-node-storage-reconcile
        chmod 0644 /etc/cron.d/hugmesh-node-storage-reconcile
        log "node-storage: installed 60s reconcile cron (convergence floor)"
    else
        warn "node-storage: cron drop-in not baked at ${reg_dir} — no 60s convergence poll"
    fi
}

# ── NODE-STORAGE pool reconcile — the `--pool` ENTRY POINT ────────────────────
# main() dispatches here on `keys-provision --pool`, which is what the reconcile
# agent (/usr/sbin/hugmesh-node-storage-reconcile, step 5b) actually runs on every
# 60s convergence tick.
#
# IT USED TO REACH NOTHING. The agent ran `bash provision.sh --pool`, main() ignored
# its argv entirely, and on a running node — where the DONE marker exists and the
# KEYS USB is long gone — main() logged "Already provisioned. Skipping.", failed
# find_and_mount and `return 0`ed before a single line of storage work. Every string
# a grep could look for (--pool, provision_storage, the pool marker) was present and
# correct; a registered pool was simply never provisioned on any node, ever. The one
# case where it did NOT return early was worse: with a KEYS stick still inserted it
# would have run the WHOLE first-boot flow (users, network, kubeadm, …) and then
# called provision_storage with NO argument, i.e. against the USB's manifest and
# across the SYSTEM disks — the opposite of a pool-only reconcile.
#
# So the pool path is its own entry point, and it does exactly and only pool work:
#   * NO KEYS media, NO DONE marker, NO first-boot steps, NO cleanup/umount;
#   * the manifest is the agent's pool-manifest (HUGMESH_PROVISION_MANIFEST, the
#     variable the agent already exports), never the USB's provision.json;
#   * provision_storage --pool then skips every device without a `pool:{}` marker,
#     so a system disk can never be touched from here.
# Absent/unreadable manifest = clean no-op 0 (the agent runs this every 60s on nodes
# that have no pool at all).
NODE_STORAGE_POOL_MANIFEST_DEFAULT="/var/lib/hugmesh/node-storage/pool-manifest.json"
provision_storage_pool() {
    local pm="${HUGMESH_PROVISION_MANIFEST:-${NODE_STORAGE_POOL_MANIFEST_DEFAULT}}"
    log "=== keys-provision --pool (node-storage reconcile) ==="
    if [ ! -r "${pm}" ]; then
        log "node-storage: no pool manifest at ${pm} — nothing to reconcile"
        return 0
    fi
    # The manifest path is the only thing the caller controls; it must be an absolute
    # path to a regular file (the agent writes one under its own cache dir). A
    # relative/exotic value is a bug in the caller, not something to guess at.
    case "${pm}" in
        /*) : ;;
        *)  warn "node-storage: pool manifest '${pm}' is not an absolute path — refusing"; return 1 ;;
    esac
    [ -f "${pm}" ] || { warn "node-storage: pool manifest '${pm}' is not a regular file — refusing"; return 1; }
    MANIFEST="${pm}"
    log "node-storage: reconciling pools from ${MANIFEST}"
    provision_storage --pool
    log "=== keys-provision --pool complete ==="
    return 0
}

# ── Egress VPN — provider configs (per-domain, own-domain-only, 0600) ──
# Installs the provider-downloaded VPN configs (ProtonVPN WireGuard `.conf`
# FIRST-CLASS; OpenVPN `.ovpn` fallback) the egress-VPN OpenRC service
# (hugmesh-egress-vpn, a DEFAULT-OFF optional service) uses for OUTGOING /
# egress traffic on PUBLIC-facing flows (coturn UDP, made-public services, and —
# only on explicit assignment — akkoma/matrix federation). The tailnet control
# plane + cluster-internal traffic stay DIRECT (split-tunnel; see PR2 runner).
#
# SECRETS OFF-GIT, PER-DOMAIN, OWN-DOMAIN-ONLY (defence-in-depth, mirrors the
# device-registry tenant scoping): the configs ride the key-USB under
# KEYS/vpn/<domain>/ and this reads ONLY the node's OWN domain's directory — a
# config staged under another tenant's domain is NEVER installed here. The node's
# own domain is .egress_vpn.domain else .hugmesh.cluster_domain (the brand
# residency provision_hosts already uses). With no own-domain dir (or an empty
# one) NOTHING is installed and the service stays stopped (fail-closed: public
# flows fall back to the Squid egress-proxy / direct, never leak — see PR2).
#
# This function does NOT start the service (default-off optional service; the
# OpenRC service + split-tunnel runner ship in PR2, the signed-reconcile flip in
# PR5). It only stages the own-domain configs 0600 root-owned into
# /etc/hugmesh/vpn/ and points active.conf at the first config so a manually-
# started service has something to bring up. The runtime UI path delivers a
# config via a K8s Secret (ESO) instead; this is the key-USB delivery path.
provision_vpn() {
    local vpn_etc=/etc/hugmesh/vpn
    # Resolve the node's OWN domain (residency). Precedence: explicit
    # .egress_vpn.domain, else the brand .hugmesh.cluster_domain.
    local dom
    dom="$(jqm '.egress_vpn.domain // ""')"
    { [ -z "${dom}" ] || [ "${dom}" = "null" ]; } && dom="$(jqm '.hugmesh.cluster_domain // ""')"
    if [ -z "${dom}" ] || [ "${dom}" = "null" ]; then
        log "egress-vpn: no node domain (.egress_vpn.domain / .hugmesh.cluster_domain) — skipping (service stays off)"
        return 0
    fi

    # OWN-DOMAIN-ONLY: read strictly KEYS/vpn/<own-domain>/. A config under any
    # other tenant's directory is invisible to this node (per-domain isolation).
    local src="${BASE}/vpn/${dom}"
    if [ ! -d "${src}" ]; then
        log "egress-vpn: no KEYS/vpn/${dom}/ on the key-USB — skipping (service stays off; public egress falls back to the Squid proxy / direct)"
        return 0
    fi

    mkdir -p "${vpn_etc}"
    # 0700 dir, root-only: the .conf/.ovpn carry the private VPN key (secret).
    chmod 0700 "${vpn_etc}" 2>/dev/null || true

    local installed=0 first=""
    local f base
    # WireGuard .conf FIRST (first-class), then OpenVPN .ovpn (fallback). The first
    # WireGuard config installed becomes active.conf; only if none exists does the
    # first .ovpn become active.conf.
    for f in "${src}/"*.conf; do
        [ -f "${f}" ] || continue
        base="$(basename "${f}")"
        cp -f "${f}" "${vpn_etc}/${base}"
        chmod 0600 "${vpn_etc}/${base}"; chown root:root "${vpn_etc}/${base}" 2>/dev/null || true
        installed=$((installed + 1))
        [ -z "${first}" ] && first="${base}"
        log "egress-vpn: installed ${vpn_etc}/${base} (WireGuard, domain ${dom}, mode 0600)"
    done
    for f in "${src}/"*.ovpn; do
        [ -f "${f}" ] || continue
        base="$(basename "${f}")"
        cp -f "${f}" "${vpn_etc}/${base}"
        chmod 0600 "${vpn_etc}/${base}"; chown root:root "${vpn_etc}/${base}" 2>/dev/null || true
        installed=$((installed + 1))
        [ -z "${first}" ] && first="${base}"
        log "egress-vpn: installed ${vpn_etc}/${base} (OpenVPN, domain ${dom}, mode 0600)"
    done

    if [ "${installed}" -eq 0 ]; then
        log "egress-vpn: KEYS/vpn/${dom}/ present but carries no *.conf / *.ovpn — skipping (service stays off)"
        return 0
    fi

    # Point active.conf at the first config (a WireGuard .conf wins over an .ovpn)
    # so a manually-started service / first-boot has something to bring up. The
    # signed reconcile (PR5) or the runtime UI path re-points active.conf later.
    if [ -n "${first}" ] && [ ! -e "${vpn_etc}/active.conf" ]; then
        ln -sfn "${vpn_etc}/${first}" "${vpn_etc}/active.conf"
        log "egress-vpn: active.conf -> ${first}"
    fi

    # DEFAULT-OFF optional service: we do NOT rc-update add / start it here. The
    # operator (or the optional-services gate, PR6) enables it; PR5's reconcile
    # flips it on per assignment.
    log "egress-vpn: staged ${installed} config(s) for domain ${dom} (service NOT started — default-off optional service)"
}

# ── Domain-registry -> brand-repo bridge (#4): enable the signed-export reconcile ──
# The bridge ingests the signed #118 cross-domain domain-registry export and emits a
# per-domain CA + per-brand GitOps repo into a node-local staging dir. It is a
# DEFAULT-OFF optional service, gated THREE ways (all must hold to act):
#   (1) it is only ENABLED here when .domain_registry.enabled == true in the manifest
#       (the provision-time equivalent of the `domain-registry-bridge` optional-service
#       selector); absent/false => the baked agent stays un-linked + un-cr-on'd (INERT);
#   (2) it verifies the export against the BAKED registry-pub.ed25519 (Layer-B's key,
#       REUSED — never re-baked here); a placeholder/absent key fail-closes (no emit);
#   (3) absent BFF transport (URL/mTLS certs in node.env) it keeps cache + emits nothing.
# This hook NEVER generates or copies a signing key — it asserts the existing
# registry-pub.ed25519 (staged by provision_device_registry / the builders) is present
# and wires the boot oneshot + 60s cron. It writes node.env's BFF transport if the
# manifest carries it (mirroring provision_device_registry), reusing the SAME keys.
provision_domain_registry() {
    local reg_dir=/etc/hugmesh/registry
    local cache_dir=/var/lib/hugmesh/domain-registry

    # (1) Optional-service gate: only enable on an explicit manifest opt-in.
    local enabled; enabled="$(jqm '.domain_registry.enabled // false')"
    if [ "${enabled}" != "true" ]; then
        log "domain-registry: .domain_registry.enabled != true — NOT enabling the bridge (baked agent stays inert; default-off optional service)"
        return 0
    fi

    log "domain-registry: .domain_registry.enabled=true — enabling the signed-export bridge (fail-closed; emits NOTHING without a real key + transport)"
    mkdir -p "${reg_dir}" "${cache_dir}" 2>/dev/null || true

    # The agent + verify lib are BAKED by the builders (gated on the optional service).
    # Sanity-check (additive: a stale image without them just stays inert, never bricks).
    [ -x /usr/sbin/hugmesh-domain-reconcile ] \
        || warn "domain-registry: /usr/sbin/hugmesh-domain-reconcile missing from image (no bridge; nothing emitted)"
    [ -r /usr/lib/hugmesh/domain-verify.sh ] \
        || warn "domain-registry: /usr/lib/hugmesh/domain-verify.sh missing from image (verify unavailable)"

    # (2) Assert the BAKED registry public verifying key is present (REUSED from Layer-B
    # — provision_device_registry / the builders stage it). NEVER generate or copy a new
    # key here. Absent/placeholder => the bridge fail-closes (emits nothing) until the
    # real public half is on the key-USB.
    if [ ! -s "${reg_dir}/registry-pub.ed25519" ]; then
        if [ -f "${BASE}/device-registry/registry-pub.ed25519" ] \
                && [ -s "${BASE}/device-registry/registry-pub.ed25519" ]; then
            cp -f "${BASE}/device-registry/registry-pub.ed25519" "${reg_dir}/registry-pub.ed25519"
            chmod 0644 "${reg_dir}/registry-pub.ed25519"
            log "domain-registry: staged the REUSED registry-pub.ed25519 (Layer-B key; export verified against THIS key)"
        else
            warn "domain-registry: registry-pub.ed25519 ABSENT/placeholder — bridge fail-closes (emits nothing) until the public half is baked onto the key-USB"
        fi
    fi

    # (3) BFF /export transport (the SUPERADMIN-equivalent in-cluster mTLS identity).
    # Reuse the SAME node.env the device-registry bridge uses; if it already exists
    # (provision_device_registry ran), we leave its transport fields intact. Only seed
    # node.env here if it is absent AND the manifest carries domain-registry transport.
    if [ ! -f "${reg_dir}/node.env" ]; then
        local mkey bff_url bff_cert bff_key bff_ca
        mkey="$(jqm '.domain_registry.machine_key_fp // ""')"
        { [ -z "${mkey}" ] || [ "${mkey}" = "null" ]; } && [ -f "${BASE}/device-registry/machine_key_fp" ] \
            && mkey="$(tr -d '[:space:]' < "${BASE}/device-registry/machine_key_fp" 2>/dev/null)"
        bff_url="$(jqm '.domain_registry.bff_export_url // ""')"
        bff_cert="$(jqm '.domain_registry.bff_client_cert // ""')"
        bff_key="$(jqm '.domain_registry.bff_client_key // ""')"
        bff_ca="$(jqm '.domain_registry.bff_ca // "/etc/hugmesh/pki/ca-chain.crt"')"
        {
            echo "# domain-registry bridge node identity + BFF transport (#4). MACHINE_KEY_FP is"
            echo "# the ?node= PROVENANCE param only; the export body is the full cross-domain set."
            echo "MACHINE_KEY_FP=${mkey}"
            echo "BFF_EXPORT_URL=${bff_url}"
            echo "BFF_CLIENT_CERT=${bff_cert}"
            echo "BFF_CLIENT_KEY=${bff_key}"
            echo "BFF_CA=${bff_ca}"
        } > "${reg_dir}/node.env"
        chmod 0644 "${reg_dir}/node.env"
        log "domain-registry: wrote node.env (machine_key_fp=${mkey:-<unset>})"
    fi

    # Enable the boot oneshot + 60s cron (convergence floor). The builders' optional-
    # service gate already linked the runlevel symlink + cron when selected; this is
    # belt-and-suspenders for a manifest-driven enable on a selected image.
    if [ -f /etc/init.d/hugmesh-domain-reconcile ]; then
        rc-update add hugmesh-domain-reconcile default 2>/dev/null \
            && log "domain-registry: enabled hugmesh-domain-reconcile (boot reconcile)" \
            || warn "domain-registry: rc-update add hugmesh-domain-reconcile failed"
    else
        warn "domain-registry: init.d/hugmesh-domain-reconcile not baked — no boot reconcile (was domain-registry-bridge selected at build?)"
    fi
    if [ -f "${reg_dir}/cron-domain-reconcile" ]; then
        cp -f "${reg_dir}/cron-domain-reconcile" /etc/cron.d/hugmesh-domain-reconcile
        chmod 0644 /etc/cron.d/hugmesh-domain-reconcile
        log "domain-registry: installed 60s reconcile cron (convergence floor)"
    fi
}

# ── Desktop app governance (client desktops: laptop / chromebook / desktop) ──
# Renders the baked desktop-governance config TEMPLATES into their live system
# locations at first boot, parameterized on the node's OWN domain. Three legs,
# all DEFAULT-DENY / ships-dark:
#   1. Plasma Discover / Flatpak -> the admin-bff registry remote at
#      https://api.<domain>/bff/desktop/registry/ ; Flathub + every other default
#      backend removed; EMPTY until a domain admin curates apps (discover role).
#   2. polkit sudo gate: NO static sudoers; sudo (admin polkit actions) ONLY for
#      the `desktop-sudo` group, which the desktop-sudo mapper populates from the
#      JWKS-VERIFIED `desktop-sudo` OIDC claim/role for this domain (admin-bff
#      sudo-grant drives the claim; IdP revocation drops sudo at the deposited
#      token's expiry, logout drops it within the 60s cron floor).
#   3. SSO bearer forwarded to the registry host so Discover authenticates as the
#      logged-in user (BFF enforces discover-role + domain-lock + enabled-only).
# No admin config => empty store, no user has sudo. This is a no-op on non-client
# (k8s) nodes and a no-op when the templates were not baked.
provision_desktop_governance() {
    local tpl=/etc/hugmesh/desktop-governance
    # Only client desktops carry the baked templates. Absent => not a governed
    # client image (or a cluster node). When NOT baked into the image, fall back
    # to the KEYS-USB copy at KEYS/desktop-governance/ (same delivery idiom as
    # egress-VPN configs / certs / files[]). This keeps the whole feature
    # functional WITHOUT editing the per-arch image builders: an admin drops the
    # desktop-governance templates on the KEYS USB and provisioning renders them.
    if [ ! -d "${tpl}" ]; then
        if [ -d "${BASE}/desktop-governance" ]; then
            tpl="${BASE}/desktop-governance"
            log "desktop-governance: using KEYS-USB templates at ${tpl} (not baked into the image)"
        else
            log "desktop-governance: no templates baked (/etc/hugmesh/desktop-governance) and none on KEYS (desktop-governance/) — skipping (not a governed client desktop)"
            return 0
        fi
    fi

    # Resolve this node's OWN domain. Precedence: manifest .client.primary_domain,
    # else the first line of the baked /etc/hugmesh/domains, else
    # .hugmesh.cluster_domain. This is the domain the registry host + OIDC
    # issuer are parameterized on.
    local dom
    dom="$(jqm '.client.primary_domain // ""')"
    if [ -z "${dom}" ] || [ "${dom}" = "null" ]; then
        [ -r /etc/hugmesh/domains ] && dom="$(grep -m1 -v '^[[:space:]]*$' /etc/hugmesh/domains 2>/dev/null | tr -d '[:space:]')"
    fi
    if [ -z "${dom}" ] || [ "${dom}" = "null" ]; then
        dom="$(jqm '.hugmesh.cluster_domain // ""')"
    fi
    if [ -z "${dom}" ] || [ "${dom}" = "null" ]; then
        warn "desktop-governance: no node domain (.client.primary_domain / /etc/hugmesh/domains / .hugmesh.cluster_domain) — skipping (store stays empty, no sudo granted)"
        return 0
    fi
    # FAIL-CLOSED domain validation. `dom` is interpolated into a sed replacement
    # (and into a URL/issuer); a value containing sed metacharacters (/ & \) or a
    # newline would break or INJECT into the rendered config. A legitimate
    # cluster domain is a hostname: lowercase letters, digits, dot, hyphen only.
    # Anything else => render NOTHING (return 0, ships-dark) rather than emit a
    # corrupted/injected config or grant sudo off a malformed domain. NOTE: a
    # bash `[[ =~ ]]` match anchors the WHOLE string, so an embedded newline (a
    # multi-line injection payload) is rejected here — unlike a `grep` pipe, which
    # would match line-by-line and accept the first valid-looking line.
    if [[ ! "${dom}" =~ ^[a-z0-9.-]+$ ]]; then
        warn "desktop-governance: node domain is not a valid hostname ([a-z0-9.-]) — refusing to render (no config, no sudo granted)"
        return 0
    fi
    log "desktop-governance: provisioning for domain ${dom}"
    # Defense-in-depth: escape sed replacement metacharacters in the (already
    # hostname-validated) domain before interpolation — mirrors the headscale
    # server_url escaping. With the strict regex above this can only ever escape
    # the harmless `.`/`-`, but keeps render_gov injection-proof if the validator
    # is ever loosened.
    local dom_esc; dom_esc="$(printf '%s' "${dom}" | sed 's/[&/\]/\\&/g')"

    # Render a @@CLUSTER_DOMAIN@@ template into a destination, dropping the
    # template's leading comment block is NOT needed (Flatpak/cron/python tolerate #).
    render_gov() {  # $1=src-tmpl  $2=dst  $3=mode
        local src="$1" dst="$2" mode="$3"
        [ -f "${src}" ] || { warn "desktop-governance: template missing: ${src}"; return 1; }
        mkdir -p "$(dirname "${dst}")"
        sed "s/@@CLUSTER_DOMAIN@@/${dom_esc}/g" "${src}" > "${dst}"
        chmod "${mode}" "${dst}" 2>/dev/null || true
        chown root:root "${dst}" 2>/dev/null || true
        log "desktop-governance: rendered ${dst} (mode ${mode})"
    }

    # ── 1. Discover/Flatpak -> BFF registry remote (Flathub OFF) ──────────────
    # Install our remote definition.
    render_gov "${tpl}/flatpak/hugmesh-discover.flatpakrepo.tmpl" \
               /etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo 0644
    # Add/refresh the remote in the system flatpak install (idempotent). Safe if
    # flatpak is not yet installed — we just skip the live add; the .flatpakrepo
    # preset is honored when flatpak/Discover land.
    if have flatpak; then
        flatpak remote-add --system --if-not-exists --no-gpg-verify \
            hugmesh-discover "/etc/flatpak/remotes.d/hugmesh-discover.flatpakrepo" 2>/dev/null \
            && log "desktop-governance: flatpak remote 'hugmesh-discover' added (system)" \
            || warn "desktop-governance: flatpak remote-add returned non-zero (will be honored from the preset)"
        # Flathub + every other default backend OFF — sole source is our registry.
        local rm_name
        if [ -r "${tpl}/flatpak/flathub-disable.conf" ]; then
            while IFS= read -r rm_name; do
                case "${rm_name}" in ''|\#*) continue ;; esac
                flatpak remote-delete --system --force "${rm_name}" 2>/dev/null \
                    && log "desktop-governance: disabled default remote '${rm_name}'" || true
            done < "${tpl}/flatpak/flathub-disable.conf"
        fi
    else
        log "desktop-governance: flatpak not installed — remote preset staged; Flathub-off enforced when flatpak lands"
    fi
    # Also remove any baked/preset Flathub .flatpakrepo files so a fresh flatpak
    # never auto-adds them (covers the preset-file delivery path).
    local rm_name
    if [ -r "${tpl}/flatpak/flathub-disable.conf" ]; then
        while IFS= read -r rm_name; do
            case "${rm_name}" in ''|\#*) continue ;; esac
            rm -f "/etc/flatpak/remotes.d/${rm_name}.flatpakrepo" 2>/dev/null || true
        done < "${tpl}/flatpak/flathub-disable.conf"
    fi

    # ── 2. polkit SSO-claim sudo gate (no static sudoers) ─────────────────────
    render_gov "${tpl}/polkit/49-hugmesh-desktop-sudo.rules" \
               /etc/polkit-1/rules.d/49-hugmesh-desktop-sudo.rules 0644
    # Defense-in-depth: ensure NO static sudo is granted. We do not write a
    # sudoers entry; we also strip a stock `%wheel ALL=(ALL) ALL` if a base image
    # shipped one, so the polkit/SSO path is the only escalation route.
    if [ -f /etc/sudoers ]; then
        sed -i 's/^\(%wheel[[:space:]].*\)$/# \1  # hugmesh: sudo is SSO-claim gated via polkit (desktop-sudo)/' \
            /etc/sudoers 2>/dev/null || true
    fi
    # Belt-and-suspenders: provision_users() already suppresses the per-user
    # static grant on governed images, but strip any pre-existing standing
    # /etc/sudoers.d grant (e.g. left by a base image, a prior un-governed
    # provision run, or hand edits) so the SSO `desktop-sudo` claim is provably
    # the SOLE sudo path. We remove our own 10-<name> grants and disable any
    # other file that hands a non-system account blanket sudo, but leave
    # package-owned drop-ins (e.g. NOPASSWD for service automation) alone unless
    # they grant `ALL=(ALL)`-class root to a login user.
    if [ -d /etc/sudoers.d ]; then
        local sdf base
        for sdf in /etc/sudoers.d/*; do
            [ -f "${sdf}" ] || continue
            base="$(basename "${sdf}")"
            case "${base}" in
                10-*)
                    rm -f "${sdf}" 2>/dev/null \
                        && log "desktop-governance: stripped standing sudoers.d grant ${sdf} (sudo via desktop-sudo SSO claim only)" || true
                    ;;
                README|*.rpmsave|*.rpmnew) : ;;
                *)
                    # Any drop-in that confers `ALL=(ALL[:ALL]) ... ALL` to a
                    # named (non-%group) login user is a standing root grant —
                    # neutralize it (comment out the offending lines).
                    if grep -Eq '^[^#%[:space:]][^[:space:]]*[[:space:]]+ALL=\(ALL(:ALL)?\)' "${sdf}" 2>/dev/null; then
                        sed -i -E 's/^([^#%[:space:]][^[:space:]]*[[:space:]]+ALL=\(ALL(:ALL)?\).*)$/# \1  # hugmesh: sudo is SSO-claim gated (desktop-sudo)/' \
                            "${sdf}" 2>/dev/null \
                            && log "desktop-governance: neutralized standing sudoers.d grant in ${sdf}" || true
                    fi
                    ;;
            esac
        done
    fi

    # ── 3. SSO claim -> desktop-sudo group mapper + bearer forwarder ──────────
    # NOT SSSD: released SSSD's OAuth2 support (`id_provider = idp`, 2.11.0+)
    # speaks only the Keycloak/Entra ID REST APIs via the RFC-8628 device-auth
    # grant and has no token-claim->local-group mapping — it cannot consume the
    # per-domain Casdoor's deposited tokens. The mapper is the honest equivalent:
    # a root cron (60s convergence floor, the hugmesh-domain-reconcile idiom)
    # that VERIFIES each session's deposited token against the issuer JWKS
    # (signature/iss/aud/exp + local-identity binding) and converges local
    # `desktop-sudo` membership to the verified claim set. Default-deny both
    # ways: no valid claim => not in the group (removed if present).
    render_gov "${tpl}/sudo/desktop-sudo-mapper.py.tmpl" \
               /etc/hugmesh/desktop-governance/desktop-sudo-mapper 0700
    render_gov "${tpl}/sudo/cron-desktop-sudo-mapper" \
               /etc/cron.d/hugmesh-desktop-sudo-mapper 0644
    # The local group the mapper converges and polkit gates on. Created empty —
    # membership only ever comes from the mapper's verified claims.
    getent group desktop-sudo >/dev/null 2>&1 || groupadd desktop-sudo 2>/dev/null \
        || warn "desktop-governance: could not create the desktop-sudo group (mapper will retry)"
    # Retire the pre-mapper SSSD conf an earlier provision run may have rendered:
    # its option syntax (`id_provider = oidc`, `oidc_groups_allowlist`) does not
    # exist in any released SSSD, and a leftover conf.d drop-in would break sssd
    # startup if sssd ever landed on the image.
    rm -f /etc/sssd/conf.d/hugmesh-oidc.conf 2>/dev/null || true
    render_gov "${tpl}/discover/bearer-forward.sh.tmpl" \
               "${tpl}/bearer-forward.sh" 0755

    log "desktop-governance: done (domain ${dom}; store empty until admin curates; sudo only for the verified desktop-sudo SSO claim)"
}

# ── Backups (etcd + PostgreSQL) to attached storage and/or network share ──
provision_backup() {
    jqe '.backup' || return 0
    [ "$(jqm '.backup.enabled // false')" = "true" ] || return 0
    log "Configuring backups"
    mkdir -p /etc/hugmesh

    # Mount any configured network shares (by file → fstab) so the backup
    # script can write to them. NFS and CIFS supported.
    local nfs_srv nfs_exp nfs_mp cifs_unc cifs_mp cifs_cred
    nfs_srv="$(jqm '.backup.nfs.server // ""')"; nfs_exp="$(jqm '.backup.nfs.export // ""')"
    nfs_mp="$(jqm '.backup.nfs.mountpoint // "/mnt/backup-nfs"')"
    if [ -n "${nfs_srv}" ] && [ "${nfs_srv}" != "null" ]; then
        # FAIL-CLOSED: nfs_srv/nfs_exp/mountpoint/options are written whitespace-delimited
        # into an /etc/fstab line; a space or newline would shift columns or inject a
        # rogue mount. Validate each; skip the share (no fstab write) on anything invalid.
        local nfs_opts; nfs_opts="$(jqm '.backup.nfs.options // "rw,soft,_netdev,noatime"')"
        if [[ "${nfs_srv}" =~ ^[A-Za-z0-9._:-]+$ ]] && [[ "${nfs_exp}" =~ ^/[A-Za-z0-9._/-]*$ ]] \
           && [[ "${nfs_mp}" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "${nfs_opts}" =~ ^[A-Za-z0-9=,.:_@/+-]+$ ]]; then
            mkdir -p "${nfs_mp}"
            if ! grep -q "${nfs_mp}" /etc/fstab; then
                printf '%s:%s  %s  nfs  %s  0 0\n' "${nfs_srv}" "${nfs_exp}" "${nfs_mp}" "${nfs_opts}" >> /etc/fstab
            fi
            mount "${nfs_mp}" 2>/dev/null || warn "NFS mount ${nfs_mp} deferred to boot"
            log "Configured NFS backup share ${nfs_srv}:${nfs_exp} -> ${nfs_mp}"
        else
            warn "NFS backup share has an invalid server/export/mountpoint/options — skipping (not writing fstab)"
        fi
    fi
    cifs_unc="$(jqm '.backup.cifs.unc // ""')"; cifs_mp="$(jqm '.backup.cifs.mountpoint // "/mnt/backup-cifs"')"
    if [ -n "${cifs_unc}" ] && [ "${cifs_unc}" != "null" ]; then
        cifs_cred="$(jqm '.backup.cifs.credentials_file // ""')"
        [ -n "${cifs_cred}" ] && [ -f "${BASE}/${cifs_cred}" ] && \
            { install -Dm0600 "${BASE}/${cifs_cred}" /etc/hugmesh/cifs.cred; cifs_cred=/etc/hugmesh/cifs.cred; }
        # FAIL-CLOSED: cifs_unc + mountpoint are written whitespace-delimited into an
        # /etc/fstab line; a space or newline would inject a rogue mount. Validate both;
        # skip the share (no fstab write) on anything invalid.
        if [[ "${cifs_unc}" =~ ^//[A-Za-z0-9._$/-]+$ ]] && [[ "${cifs_mp}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
            mkdir -p "${cifs_mp}"
            if ! grep -q "${cifs_mp}" /etc/fstab; then
                printf '%s  %s  cifs  credentials=%s,_netdev,uid=0,gid=0,file_mode=0600,dir_mode=0700  0 0\n' \
                    "${cifs_unc}" "${cifs_mp}" "${cifs_cred:-/etc/hugmesh/cifs.cred}" >> /etc/fstab
            fi
            mount "${cifs_mp}" 2>/dev/null || warn "CIFS mount ${cifs_mp} deferred to boot"
            log "Configured CIFS backup share ${cifs_unc} -> ${cifs_mp}"
        else
            warn "CIFS backup share UNC '${cifs_unc}' or mountpoint failed validation — skipping (not writing fstab)"
        fi
    fi

    # Write the backup config the hugmesh-backup script reads, straight
    # from the manifest (file-based config).
    jq '.backup' "${MANIFEST}" > /etc/hugmesh/backup.json 2>/dev/null || true

    # Schedule it via cron (cronie reads /etc/cron.d).
    local sched; sched="$(jqm '.backup.schedule // "0 3 * * *"')"
    if [ -x /usr/local/sbin/hugmesh-backup ]; then
        printf '%s root /usr/local/sbin/hugmesh-backup >> /var/log/hugmesh-backup.log 2>&1\n' "${sched}" \
            > /etc/cron.d/hugmesh-backup
        log "Scheduled backups: ${sched}"
    else
        warn "hugmesh-backup not installed in image"
    fi
}

# ── OPT-IN (default-off) host-binary auto-update (binpkg deltas from the binhost) ──
# Bakes the hugmesh-update cron drop-in as ACTIVE PLUMBING on EVERY node + client
# image, but the poller is DEFAULT-OFF: the ABSENCE of any policy means auto-update is
# OFF (fail-safe to off, not to a pull). A superadmin OPTS IN by setting enabled:true
# in the live hugmesh-update-policy ConfigMap (or the manifest's OPTIONAL ".update"
# block, which can also ADJUST cadence/window/reboot/per-target+role staging). Cloned
# from provision_backup()'s by-file + cron.d idiom; cronie reads /etc/cron.d (OpenRC,
# not systemd).
#
# Self-sufficient: the poller is baked at /usr/local/sbin/hugmesh-update by the
# image builders, but if a target's builder did NOT bake it (e.g. a protected
# builder we may not edit), this STAGES the cron drop-in pointing at the SAME path so
# the plumbing is defined for a follow-up bake — provisioning never silently drops it.
# The poller (not provisioning) is the runtime gate, so a node opted in later via the
# ConfigMap still needs this baked cron to fire.
provision_update() {
    local enabled cadence window reboot role board staged
    mkdir -p /etc/hugmesh

    # OPT-IN (default-off): the cron + poller are baked as PLUMBING on every node, but
    # the poller pulls only when the effective policy says enabled:true. enabled
    # defaults to FALSE; the local update.json (tier 2) and the live ConfigMap (tier 3)
    # both default off, so a node does NOTHING until a superadmin opts in.
    # NOTE: do NOT use `// false` here — jq's `//` treats a literal `false` as empty
    # (false // false == false is fine, but true // false == true would mask a raw
    # read); read it raw and default ONLY a null/missing value to false.
    enabled="$(jqm '.update.enabled')"
    [ "${enabled}" = "true" ] || enabled="false"
    cadence="$(jqm '.update.cadence // "0 4 * * *"')"
    window="$(jqm '.update.window // ""')"; [ "${window}" = "null" ] && window=""
    reboot="$(jqm '.update.reboot // "if-needed"')"

    # Per-target / per-role staging override: a maintenance-wave cadence keyed by the
    # node's role (/etc/hugmesh/role) or board tag (frite:<board>) or "client".
    # Mirrors the ConfigMap's .staging map; the most specific match wins.
    role="$(cat /etc/hugmesh/role 2>/dev/null || echo '')"
    board="$(cat /etc/hugmesh/board 2>/dev/null || echo '')"
    if jqe '.update.staging' && [ "$(jqm '.update.staging | length')" != "0" ]; then
        local k
        for k in "${board}" "${role}" client; do
            [ -n "${k}" ] || continue
            staged="$(jqm ".update.staging.\"${k}\" // \"\"")"
            if [ -n "${staged}" ] && [ "${staged}" != "null" ]; then
                cadence="${staged}"; log "update: staging cadence for '${k}' => ${cadence}"; break
            fi
        done
    fi

    # Persist the effective policy as the by-file local config the poller reads
    # (tier 2). The live ConfigMap (tier 3) still wins on a reachable control node.
    if jqe '.update'; then
        jq '.update' "${MANIFEST}" > /etc/hugmesh/update.json 2>/dev/null || true
    else
        # No .update block => write the explicit default-OFF policy so the posture is
        # self-documenting on the node (absence of the block still means OFF / opt-in).
        printf '{"enabled":false,"cadence":"%s","window":"%s","reboot":"%s","staging":{}}\n' \
            "${cadence}" "${window}" "${reboot}" > /etc/hugmesh/update.json
    fi

    # OPT-IN: always bake the cron drop-in as PLUMBING (so a later ConfigMap/local
    # enabled:true actually fires) — the POLLER is the runtime gate and skips unless the
    # effective policy is enabled:true. There is NO provision-time "disable" branch:
    # default-off is enforced by the poller, never by withholding the cron (withholding
    # it would also make runtime opt-in via the ConfigMap impossible).
    if [ -x /usr/local/sbin/hugmesh-update ]; then
        mkdir -p /etc/cron.d
        printf '%s root /usr/local/sbin/hugmesh-update >> /var/log/hugmesh-update.log 2>&1\n' \
            "${cadence}" > /etc/cron.d/hugmesh-update
        chmod 0644 /etc/cron.d/hugmesh-update
        log "auto-update plumbing baked: cadence='${cadence}' window='${window:-any}' reboot=${reboot}; poller is DEFAULT-OFF (opt in via enabled:true). provisioned enabled=${enabled}"
    else
        # Poller not baked into this image (e.g. a builder we could not edit). Stage the
        # cron plumbing so it is defined; the OpenRC oneshot + a follow-up bake install
        # it. The poller still gates default-off at runtime regardless.
        mkdir -p /etc/hugmesh
        printf '%s root /usr/local/sbin/hugmesh-update >> /var/log/hugmesh-update.log 2>&1\n' \
            "${cadence}" > /etc/hugmesh/cron-update.staged
        warn "hugmesh-update poller not baked in this image — staged the cron plumbing at /etc/hugmesh/cron-update.staged (needs a builder bake of /usr/local/sbin/hugmesh-update); poller remains default-off until opted in"
    fi
}

# ── HugMesh GitOps (ArgoCD app-of-apps) — control-plane only ────
provision_hugmesh() {
    local role label
    # Node label hint (hugmesh.net/role / compute) for scheduling.
    label="$(jqm '.hugmesh.node_labels // {} | to_entries | map("\(.key)=\(.value)") | join(",")')"
    if [ -n "${label}" ] && [ "${label}" != "null" ] && [ -f /etc/kubernetes/admin.conf ]; then
        KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node "$(hostname)" ${label//,/ } --overwrite 2>/dev/null || true
        log "Applied node labels: ${label}"
    fi

    [ "$(jqm '.hugmesh.gitops.enabled // false')" = "true" ] || { log "HugMesh GitOps disabled"; return 0; }
    role="$(jqm '.kubernetes.role // "none"')"
    case "${role}" in control-plane|master|server) ;; *) log "Not a control-plane — skipping GitOps bootstrap"; return 0 ;; esac
    [ -f /etc/kubernetes/admin.conf ] || { warn "No kubeconfig yet — run cluster bootstrap after kubeadm init"; return 0; }
    local bs=/var/lib/hugmesh/cluster/bootstrap/bootstrap.sh
    [ -f "${bs}" ] || { warn "GitOps payload not baked into image"; return 0; }

    # ── ArgoCD repository credential token (out-of-band, offline KEYS USB) ──
    # bootstrap.sh registers a k8s Secret (labeled argocd.argoproj.io/
    # secret-type=repository) so ArgoCD can clone the PRIVATE hugmesh-generator
    # GitOps repo; without it every git-path Application fails to sync with
    # "authentication required: Repository not found". The token comes ONLY from
    # the offline KEYS USB (gitops/repo-token, override via
    # .hugmesh.gitops.repo_token_file) — SAME custody as vault/token +
    # certs/cluster-ca.key + luks.key, NEVER git. Read it into a LOCAL (NOT
    # exported into the provisioning environment) and hand it to bootstrap.sh
    # scoped to that ONE invocation as $ARGOCD_REPO_TOKEN — exactly how the far
    # more sensitive Vault root token is kept in a `local` and passed only as a
    # single kubectl arg, so the PAT never leaks into the env of the later
    # provisioning steps (provision_vault/secureboot/run_hooks) or the operator
    # hook scripts they exec. The material is never printed. Absent =>
    # bootstrap.sh fails closed for the private repo (it exits non-zero, which
    # here only warns via the `|| warn` below — it does not abort provisioning).
    local repo_token_file rt argocd_repo_token=""
    repo_token_file="$(jqm '.hugmesh.gitops.repo_token_file // "gitops/repo-token"')"
    rt="${BASE}/${repo_token_file}"
    if [ -f "${rt}" ]; then
        argocd_repo_token="$(tr -d '[:space:]' < "${rt}" 2>/dev/null)"
        if [ -n "${argocd_repo_token}" ]; then
            log "Loaded ArgoCD repo token from KEYS (${rt}), never printed"
        else
            warn "ArgoCD repo token file ${rt} is empty — bootstrap.sh will fail closed for the private GitOps repo"
        fi
    else
        warn "No ArgoCD repo token on KEYS (${repo_token_file}) — bootstrap.sh will fail closed for the private GitOps repo (write a read-only PAT there, same custody as vault/token)"
    fi

    log "Bootstrapping ArgoCD + HugMesh app-of-apps"
    ARGOCD_REPO_TOKEN="${argocd_repo_token}" KUBECONFIG=/etc/kubernetes/admin.conf bash "${bs}" || warn "GitOps bootstrap returned non-zero"
}

# ── Image-baked Vault connection facts (--vault-addr at build time; issue #224) ──
# /etc/hugmesh/vault.conf is written by the x86/rpi5 node builders (bake_vault_conf):
# KEY=VALUE, root-owned 0644, address + KV mount + base path and nothing else. It is
# the FALLBACK source for provision_vault() when the KEYS manifest carries no .vault
# block, so a Studio-built node seeds ESO without a hand-authored manifest; a
# manifest block still wins (it is the per-stick override). Read with a strict key
# lookup — never sourced — so a stray line can execute nothing. A plain read loop
# on purpose: no pipe (no SIGPIPE under pipefail) and no sed `{…}` program, which
# tests/scripts/test-eso-provider-refs.sh's brace-reachability model would count
# as shell braces. VAULT_IMAGE_CONF is overridable so tests can point the resolver
# at a fixture.
VAULT_IMAGE_CONF="${VAULT_IMAGE_CONF:-/etc/hugmesh/vault.conf}"
vault_conf_get() {
    # KEY -> VALUE ("" when absent); surrounding double quotes dropped and the ends
    # TRIMMED (the interior is left alone — see below).
    # The case arm already pinned the KEY= prefix, so a plain first-'=' strip is the
    # same value without the nested-quote spelling the ESO brace model misreads.
    local key="$1"
    local line
    local v=""
    local dq='"'
    while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
            "${key}="*) v="${line#*=}"; break ;;
        esac
    done < "${VAULT_IMAGE_CONF}"
    # TRIM the ends; do NOT strip the interior. `${v//[[:space:]]/}` deleted every
    # space ANYWHERE in the value, so a `VAULT_BASE_PATH=acme corp` line silently
    # became `acmecorp` — a wrong value that reads as a working one — instead of
    # being carried through verbatim and refused by the allowlist upstream. Trim,
    # unquote, trim: a quoted value keeps its own spelling minus the quotes.
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    v="${v#"${dq}"}"; v="${v%"${dq}"}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "${v}"
}

# Resolve WHERE the Vault seeding facts come from. Sets VAULT_SRC to "manifest",
# "image" or "" (nothing to seed from) and the vault_* globals from that source:
#   manifest : the .vault block (operator-authored, per stick) — every field, as before;
#   image    : the baked vault.conf — address/mount/base path; the token file is the
#              stick's standard vault/token and enabled follows the address.
resolve_vault_source() {
    VAULT_SRC=""
    vault_address=""; vault_kv_mount="secret"; vault_base_path="hugmesh"
    vault_token_file="vault/token"; vault_install_eso="false"; vault_enabled="false"
    if jqe '.vault'; then
        VAULT_SRC="manifest"
        vault_enabled="$(jqm '.vault.enabled // false')"
        vault_address="$(jqm '.vault.address // ""')"
        vault_kv_mount="$(jqm '.vault.kv_mount // "secret"')"
        vault_base_path="$(jqm '.vault.base_path // "hugmesh"')"
        vault_token_file="$(jqm '.vault.token_file // "vault/token"')"
        vault_install_eso="$(jqm '.vault.install_eso // false')"
        [ "${vault_address}" = "null" ] && vault_address=""
    elif [ -r "${VAULT_IMAGE_CONF}" ]; then
        VAULT_SRC="image"
        vault_address="$(vault_conf_get VAULT_ADDR)"
        vault_kv_mount="$(vault_conf_get VAULT_KV_MOUNT)"
        [ -n "${vault_kv_mount}" ] || vault_kv_mount="secret"
        vault_base_path="$(vault_conf_get VAULT_BASE_PATH)"
        [ -n "${vault_base_path}" ] || vault_base_path="hugmesh"
        [ -n "${vault_address}" ] && vault_enabled="true"
    fi
    return 0
}

# ── Vault / External Secrets (k8s Secrets, online + USB fallback) ──
# Vault is the source of truth; ESO + the ClusterSecretStore/ExternalSecrets
# are deployed by ArgoCD. Here we only seed the bits a fresh cluster needs:
#   * online : the "vault-token" Secret so ESO's ClusterSecretStore can auth.
#   * offline: materialize the workload Secrets directly from KEYS/vault/
#              secrets.json so they exist even with no reachable Vault.
# The connection facts come from the manifest's .vault block or, when the stick
# carries none, from the image-baked vault.conf (resolve_vault_source, #224).
provision_vault() {
    resolve_vault_source
    case "${VAULT_SRC}" in
        "")    log "No .vault block and no image-baked ${VAULT_IMAGE_CONF} — skipping Vault/ESO seeding"; return 0 ;;
        image) log "No .vault block in the manifest — using the image-baked ${VAULT_IMAGE_CONF} (--vault-addr at build time)" ;;
    esac
    [ "${vault_enabled}" = "true" ] || { log "Vault disabled (${VAULT_SRC})"; return 0; }

    [ -f /etc/kubernetes/admin.conf ] || { warn "No kubeconfig yet — skipping Vault/ESO seeding"; return 0; }
    have kubectl || { warn "kubectl not installed — skipping Vault/ESO seeding"; return 0; }
    local kc=/etc/kubernetes/admin.conf

    local address kv_mount base_path token_file install_eso
    address="${vault_address}"
    kv_mount="${vault_kv_mount}"
    base_path="${vault_base_path}"
    token_file="${vault_token_file}"
    install_eso="${vault_install_eso}"
    log "Vault seeding (${VAULT_SRC}): address='${address}' kv_mount=${kv_mount} base_path=${base_path} install_eso=${install_eso}"

    # ── ONLINE: hand ESO a Vault token so its ClusterSecretStore can auth ──
    local tok_path="${BASE}/${token_file}"
    if [ -n "${address}" ] && [ -f "${tok_path}" ]; then
        local token
        token="$(tr -d '[:space:]' < "${tok_path}" 2>/dev/null)"
        if [ -n "${token}" ]; then
            KUBECONFIG="${kc}" kubectl create namespace external-secrets \
                --dry-run=client -o yaml 2>/dev/null | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null \
                || warn "could not ensure namespace external-secrets"
            if KUBECONFIG="${kc}" kubectl create secret generic vault-token \
                    -n external-secrets --from-literal=token="${token}" \
                    --dry-run=client -o yaml 2>/dev/null \
                    | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null; then
                log "Created k8s Secret external-secrets/vault-token for ESO ClusterSecretStore 'hugmesh-vault'"
            else
                warn "failed to create external-secrets/vault-token"
            fi
            # The per-service mTLS generators (manifests/external-secrets/
            # pki-externalsecrets.yaml) run a VaultDynamicSecret IN EACH workload
            # namespace and auth with a 'vault-token' Secret in THAT namespace. Seed
            # it everywhere a generator lives — not just external-secrets — or the
            # <svc>-mtls TLS Secrets never materialize and keystore-enabled gateways
            # cannot start. Namespaces are also created by ArgoCD (CreateNamespace);
            # ensuring them here is idempotent.
            local gen_ns
            for gen_ns in hugmesh-pki hugmesh-backend hugmesh-frontend; do
                KUBECONFIG="${kc}" kubectl create namespace "${gen_ns}" \
                    --dry-run=client -o yaml 2>/dev/null | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null \
                    || warn "could not ensure namespace ${gen_ns}"
                # eso-provider-refs: conditional-ok this is the USB path and the token is custody material that only exists on the KEYS stick (vault/token) for an ONLINE Vault address; with no stick and no address there is nothing to seed from, so the guards above are the contract, not an oversight. The offline branch below materializes the workload Secrets directly instead.
                if KUBECONFIG="${kc}" kubectl create secret generic vault-token \
                        -n "${gen_ns}" --from-literal=token="${token}" \
                        --dry-run=client -o yaml 2>/dev/null \
                        | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null; then
                    log "Created k8s Secret ${gen_ns}/vault-token for the per-service mTLS ESO generators"
                else
                    warn "failed to create ${gen_ns}/vault-token"
                fi
            done
        else
            warn "Vault token file ${tok_path} is empty"
        fi
    else
        if [ -z "${address}" ]; then
            log "No Vault address — relying on USB offline secrets bundle"
        else
            log "No Vault token at ${tok_path} — relying on USB offline secrets bundle"
        fi
    fi

    # ── Vault PKI trust anchor: import the cluster CA (cert+key) ──────
    # manifests/vault-pki's init Job mounts a 'cluster-ca' Secret (tls.crt/tls.key)
    # in the vault ns and imports it as pki_int's signing CA, so Vault-issued leaf
    # certs chain to the SAME anchor as the offline gen-keystores.sh truststore.
    # Absent => Vault self-generates a DEV root and cross-service mTLS trust breaks.
    # The CA key comes ONLY from the pki KEYS stick (never git); kubectl reads the
    # files, no key material is printed. Runs regardless of online/offline.
    local ca_crt="${BASE}/certs/cluster-ca.crt" ca_key="${BASE}/certs/cluster-ca.key"
    if [ -f "${ca_crt}" ] && [ -f "${ca_key}" ]; then
        KUBECONFIG="${kc}" kubectl create namespace vault \
            --dry-run=client -o yaml 2>/dev/null | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null \
            || warn "could not ensure namespace vault"
        # eso-provider-refs: conditional-ok the cluster CA cert+key are USB custody material (certs/cluster-ca.{crt,key}) and are never in git; a KEYS stick that does not carry them cannot seed them, and the else branch below says so explicitly rather than pretending the anchor exists.
        if KUBECONFIG="${kc}" kubectl create secret tls cluster-ca \
                -n vault --cert="${ca_crt}" --key="${ca_key}" \
                --dry-run=client -o yaml 2>/dev/null \
                | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null; then
            log "Created k8s Secret vault/cluster-ca (Vault pki_int imports the cluster CA → leaf certs chain to the truststore)"
        else
            warn "failed to create vault/cluster-ca"
        fi
        # ── vault-ca: the PUBLIC cluster CA CERT in every generator namespace ──
        # The persistent Vault serves HTTPS with a cluster-CA-signed listener cert.
        # ESO's per-service VaultDynamicSecret generators (pki-externalsecrets.yaml)
        # + the ClusterSecretStore validate it via caProvider -> a 'vault-ca' Secret
        # (key ca.crt) in their namespace. Only the CERT is published (no CA key) —
        # the cert is public trust material. Seed it alongside the vault-token.
        local ca_ns
        for ca_ns in vault hugmesh-pki hugmesh-backend hugmesh-frontend; do
            KUBECONFIG="${kc}" kubectl create namespace "${ca_ns}" \
                --dry-run=client -o yaml 2>/dev/null | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null \
                || warn "could not ensure namespace ${ca_ns}"
            # eso-provider-refs: conditional-ok same custody argument as cluster-ca directly above — this republishes the very cert file that came off the KEYS stick, so it is guarded by the same `[ -f certs/cluster-ca.crt ]` test and cannot be made unconditional without inventing a CA.
            if KUBECONFIG="${kc}" kubectl create secret generic vault-ca \
                    -n "${ca_ns}" --from-file=ca.crt="${ca_crt}" \
                    --dry-run=client -o yaml 2>/dev/null \
                    | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null; then
                log "Created k8s Secret ${ca_ns}/vault-ca (CA cert for Vault HTTPS trust)"
            else
                warn "failed to create ${ca_ns}/vault-ca"
            fi
        done
    else
        log "No cluster CA cert+key on KEYS (certs/cluster-ca.{crt,key}) — Vault pki_int will self-generate a DEV root + a self-signed TLS listener cert"
    fi

    # ── Persistent Vault: auto-unseal key + bootstrap token (offline custody) ──
    # The persistent Vault (manifests/vault, Raft + Shamir seal) auto-unseals on
    # every restart from the `vault-unseal` Secret (key unseal-key); the vault-pki
    # init Job authenticates with the `vault-bootstrap` Secret (key token). BOTH
    # come ONLY from the offline USB KEYS bundle (vault/unseal-key + vault/token) —
    # same custody as the cluster CA + luks.key, NEVER git. kubectl reads the files;
    # no key material is printed. Absent => the operator must run the one-time
    # `vault operator init` and seed these by hand (see keys-template/vault/README).
    local unseal_file="${BASE}/vault/unseal-key" tok_file="${BASE}/${token_file}"
    if [ -f "${unseal_file}" ] || [ -f "${tok_file}" ]; then
        KUBECONFIG="${kc}" kubectl create namespace vault \
            --dry-run=client -o yaml 2>/dev/null | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null \
            || warn "could not ensure namespace vault"
    fi
    if [ -f "${unseal_file}" ]; then
        local unseal_key; unseal_key="$(tr -d '[:space:]' < "${unseal_file}" 2>/dev/null)"
        if [ -n "${unseal_key}" ] && KUBECONFIG="${kc}" kubectl create secret generic vault-unseal \
                -n vault --from-literal=unseal-key="${unseal_key}" \
                --dry-run=client -o yaml 2>/dev/null \
                | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null; then
            log "Created k8s Secret vault/vault-unseal (auto-unseal sidecar unseals Vault on restart)"
        else
            warn "failed to create vault/vault-unseal (empty key or apply error)"
        fi
    else
        log "No Vault unseal key on KEYS (vault/unseal-key) — run the one-time 'vault operator init' and seed vault/vault-unseal by hand"
    fi
    if [ -f "${tok_file}" ]; then
        local boot_tok; boot_tok="$(tr -d '[:space:]' < "${tok_file}" 2>/dev/null)"
        if [ -n "${boot_tok}" ] && KUBECONFIG="${kc}" kubectl create secret generic vault-bootstrap \
                -n vault --from-literal=token="${boot_tok}" \
                --dry-run=client -o yaml 2>/dev/null \
                | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null; then
            log "Created k8s Secret vault/vault-bootstrap (vault-pki-init authenticates with this token)"
        else
            warn "failed to create vault/vault-bootstrap"
        fi
    fi

    # ── OFFLINE / USB FALLBACK: materialize the workload Secrets directly ──
    # Always attempt this if the bundle exists so the *-auth / casdoor-google
    # Secrets are present even with no reachable Vault.
    local bundle="${BASE}/vault/secrets.json"
    if [ ! -f "${bundle}" ]; then
        log "No offline secrets bundle at ${bundle} — Vault must materialize Secrets via ESO"
        return 0
    fi
    if ! jq -e . "${bundle}" >/dev/null 2>&1; then
        warn "Offline secrets bundle ${bundle} is not valid JSON — skipping"
        return 0
    fi
    log "Materializing k8s Secrets from offline bundle ${bundle} (USB fallback)"

    local ns name
    while IFS= read -r ns; do
        [ -n "${ns}" ] || continue
        KUBECONFIG="${kc}" kubectl create namespace "${ns}" \
            --dry-run=client -o yaml 2>/dev/null | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null \
            || warn "could not ensure namespace ${ns}"

        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            # Build the --from-literal=<k8sKey>=<value> args from the JSON object.
            local args=() k v
            while IFS= read -r k; do
                [ -n "${k}" ] || continue
                v="$(jq -r --arg ns "${ns}" --arg s "${name}" --arg k "${k}" \
                        '.[$ns][$s][$k] // ""' "${bundle}" 2>/dev/null)"
                args+=(--from-literal="${k}=${v}")
            done < <(jq -r --arg ns "${ns}" --arg s "${name}" \
                        '.[$ns][$s] | keys[]' "${bundle}" 2>/dev/null)

            if [ "${#args[@]}" -eq 0 ]; then
                warn "secret ${ns}/${name} has no keys in bundle — skipping"
                continue
            fi
            if KUBECONFIG="${kc}" kubectl create secret generic "${name}" -n "${ns}" \
                    "${args[@]}" --dry-run=client -o yaml 2>/dev/null \
                    | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null; then
                log "Applied Secret ${ns}/${name} (${#args[@]} key(s)) from USB"
            else
                warn "failed to apply Secret ${ns}/${name} from USB"
            fi
        done < <(jq -r --arg ns "${ns}" '.[$ns] | keys[]' "${bundle}" 2>/dev/null)
    done < <(jq -r 'keys[]' "${bundle}" 2>/dev/null)
}

# ── User-supplied hooks ────────────────────────────────────────────
provision_run_hooks() {
    jqe '.run' || return 0
    local n i
    n="$(jqm '.run | length')"
    for ((i = 0; i < n; i++)); do
        local s; s="$(jqm ".run[$i]")"
        [ -f "${BASE}/${s}" ] || { warn "run hook missing: ${s}"; continue; }
        log "Running hook ${s}"
        # Copy out of the read-only mount so it is executable
        local tmp; tmp="$(mktemp)"; cp "${BASE}/${s}" "${tmp}"; chmod +x "${tmp}"
        KEYS_BASE="${BASE}" "${tmp}" || warn "hook ${s} exited non-zero"
        rm -f "${tmp}"
    done
}

# ── Java truststore + keystores from the USB cert chain ───────────
# Builds a PKCS12 truststore (no Java needed) from the cluster CA / cert chain
# on the KEYS stick, installs the per-service JKS keystores, and (on the
# control-plane) publishes them as k8s Secrets the Java containers mount into
# their JRE. Java IO then trusts the cluster CA: the gateways/Spring services
# run with -Djavax.net.ssl.trustStore pointing at this store.
provision_truststore() {
    local pki=/etc/hugmesh/pki
    local cas=()
    [ -f "${BASE}/certs/cluster-ca.crt" ] && cas+=("${BASE}/certs/cluster-ca.crt")
    for c in "${BASE}/certs/"*.crt; do [ -f "${c}" ] && cas+=("${c}"); done
    [ "${#cas[@]}" -gt 0 ] || { log "No KEYS certs — skipping truststore"; return 0; }
    mkdir -p "${pki}"
    cat "${cas[@]}" > "${pki}/ca-chain.crt"
    # PKCS12 truststore (Java reads it natively: trustStoreType=PKCS12).
    local tspass; tspass="$(openssl rand -hex 16)"
    openssl pkcs12 -export -nokeys -in "${pki}/ca-chain.crt" \
        -out "${pki}/truststore.p12" -passout "pass:${tspass}" -name cluster-ca 2>/dev/null \
        && { echo "${tspass}" > "${pki}/truststore.pass"; chmod 0600 "${pki}/truststore.pass"; \
             log "Built Java truststore ${pki}/truststore.p12 from KEYS cert chain"; }
    # Ship pre-generated JKS truststore + per-service keystores if present.
    [ -d "${BASE}/keystores" ] && { cp -f "${BASE}/keystores/"*.jks "${pki}/" 2>/dev/null || true; \
        log "Installed JKS keystores from KEYS/keystores"; }
    chmod -R go-rwx "${pki}" 2>/dev/null || true

    # Publish to the cluster so Java pods mount it (control-plane only).
    if [ -f /etc/kubernetes/admin.conf ] && have kubectl; then
        KUBECONFIG=/etc/kubernetes/admin.conf kubectl create secret generic hugmesh-truststore \
            -n kube-system --from-file="${pki}/truststore.p12" \
            --dry-run=client -o yaml 2>/dev/null | KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f - 2>/dev/null \
            && log "Published truststore as Secret kube-system/hugmesh-truststore" || true
    fi
}

# ── SELinux first-boot setup (load policy on the Pi; relabel; set mode) ──
#
# FAIL-OPEN ONLY FOR IMAGES THAT WERE NEVER BUILT SELINUX-AWARE. An image that
# WAS built selinux-aware — /usr/share/hugmesh/selinux-built, written at build
# time by scripts/_selinux-policy-lib.sh (a base.pp in /usr/share/selinux/* is
# the fallback for images predating that marker) — must end this function with
# a policy actually LOADED in the kernel. When it does not, the failure is
# made VISIBLE instead of "normal": selinux_provision_failed() records the
# reason in ${SELINUX_FAIL_MARKER} and /etc/init.d/selinux-enforce-gate
# refuses to flip the node enforcing while that marker stands. First boot
# itself must still NEVER brick the node, so every path out of
# provision_selinux() returns 0 — degrade loudly, not fatally.
SELINUX_FAIL_MARKER="${STATE_DIR}/selinux-load-failed"

selinux_image_aware() {
    [ -f /usr/share/hugmesh/selinux-built ] && return 0
    ls /usr/share/selinux/*/base.pp >/dev/null 2>&1
}

# The postcondition: is a policy actually loaded in the KERNEL? True when
# selinuxfs exposes a readable policy blob, or getenforce reports a real mode.
# ("Disabled", an unmounted selinuxfs, or no getenforce at all = nothing loaded.)
selinux_policy_loaded() {
    [ -r /sys/fs/selinux/policy ] && return 0
    case "$(getenforce 2>/dev/null)" in
        Enforcing|Permissive) return 0 ;;
    esac
    return 1
}

# selinux_provision_failed <reason> — the only failure exit on an aware image:
# warn loudly + persist the reason where the enforce-gate looks for it.
selinux_provision_failed() {
    warn "SELinux: $*"
    warn "SELinux: this image was BUILT selinux-aware but first boot ends WITHOUT a working policy load."
    warn "SELinux: recording ${SELINUX_FAIL_MARKER}; /etc/init.d/selinux-enforce-gate refuses to flip while it exists."
    warn "SELinux: fix the load, then re-provision (KEYS_FORCE=1 or .provision-force) to clear it."
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "${SELINUX_FAIL_MARKER}"
}

provision_selinux() {
    local aware=0
    selinux_image_aware && aware=1
    # A re-provision starts from a clean slate; every failure below re-records.
    rm -f "${SELINUX_FAIL_MARKER}"
    if [ ! -d /etc/selinux ]; then
        if [ "${aware}" = 1 ]; then
            selinux_provision_failed "/etc/selinux missing on a selinux-aware image (policycoreutils/selinux-base broken?)"
        else
            log "SELinux not installed — skipping"
        fi
        return 0
    fi
    if ! have semodule; then
        if [ "${aware}" = 1 ]; then
            selinux_provision_failed "semodule absent on a selinux-aware image — no policy can be loaded"
        else
            log "semodule absent — skipping SELinux setup"
        fi
        return 0
    fi
    local type mode
    type="$(jqm '.selinux.type // "mcs"')";  [ -n "${type}" ] && [ "${type}" != "null" ] || type=mcs
    mode="$(jqm '.selinux.mode // "permissive"')"; [ -n "${mode}" ] && [ "${mode}" != "null" ] || mode=permissive
    log "SELinux: type=${type} mode=${mode}"

    # Config (start permissive by default so a mislabel never bricks the node).
    cat > /etc/selinux/config <<EOF
SELINUX=${mode}
SELINUXTYPE=${type}
EOF
    # On the cross-built Pi image the policy modules were installed but not
    # loaded (postinst can't run the target semodule). Build/load the store now,
    # natively, then relabel the filesystem.
    if ! ls /etc/selinux/"${type}"/policy/policy.* >/dev/null 2>&1; then
        log "Loading SELinux base policy (${type})"
        semodule -s "${type}" -B 2>/dev/null \
            || semodule -s "${type}" -i /usr/share/selinux/"${type}"/*.pp 2>/dev/null \
            || warn "semodule load failed; node will boot without loaded policy"
    fi
    # ── BEGIN hugmesh node-policy load (pairs with scripts/_selinux-policy-lib.sh) ──
    # The block ABOVE is not enough for the hugmesh modules, and pretending it was
    # is how they nearly shipped unloaded. Two reasons:
    #   1. it only runs when the policy store has NOT been built yet — a native
    #      x86 merge, or a cross merge whose sec-policy postinst ran the host
    #      semodule with `-p ${SYSROOT} -n`, leaves policy.* already present and
    #      the whole block is skipped;
    #   2. inside it, `semodule -B` is tried FIRST. `-B` rebuilds the policy from
    #      the module STORE; the .pp that the build installed into
    #      /usr/share/selinux/<type>/ are PACKAGE files that are not in the store
    #      until `semodule -i` runs, so a successful -B loads none of them.
    # So load exactly the modules THIS image recorded at build time, explicitly,
    # and before the relabel (semodule -i regenerates file_contexts, which
    # setfiles then applies). Manifest-driven, never a blind glob: a stale .pp
    # left in the store by an older build must not be resurrected here.
    # Idempotent — `semodule -i` re-installs an already-installed module.
    #
    # PER-MODULE VISIBILITY (#45). The original form was ONE batched
    # `semodule -i a.pp b.pp ... 2>/dev/null || warn`, so a module that failed
    # to load VANISHED three times over: semodule's own reason went to
    # /dev/null, no per-module verdict existed anywhere, and the boot still
    # scored green (all four 2026-08-14 QEMU runs shipped base-policy-only
    # nodes behind exactly this warn — the README's acknowledged defect).
    # Now:
    #   * the batch is tried first (a semodule transaction is all-or-nothing,
    #     and ONE policy rebuild instead of N is what a TCG first boot can
    #     afford) with stderr CAPTURED into this log;
    #   * on batch failure, each module is retried ALONE, stderr captured per
    #     module, so the exact offender and semodule's own words land here;
    #   * either way the per-module POSTCONDITION is read back from the STORE
    #     (`semodule -l`), not from exit codes, and recorded machine-readably
    #     in ${STATE_DIR}/selinux-modules.status — one "<module> <verdict>"
    #     line each, verdict in: loaded | failed | missing-pp. That file is
    #     the contract tests/qemu/assertions.sh asserts on;
    #   * any non-loaded manifest module records the selinux-load-failed
    #     marker via selinux_provision_failed(), so the enforce-gate refuses
    #     to flip on a node whose policy set is not the one it was built with
    #     (the per-module layer under PR #53's whole-policy postcondition).
    if [ -f /usr/share/hugmesh/selinux-modules.list ]; then
        local hm_mods="" hm_m hm_pp hm_err hm_loaded hm_failed=""
        while read -r hm_m; do
            case "${hm_m}" in ''|'#'*) continue ;; esac
            hm_pp="/usr/share/selinux/${type}/${hm_m}.pp"
            [ -f "${hm_pp}" ] && hm_mods="${hm_mods} ${hm_pp}"
        done < /usr/share/hugmesh/selinux-modules.list
        hm_err="${STATE_DIR}/.semodule.stderr"
        if [ -n "${hm_mods}" ]; then
            log "Loading hugmesh SELinux node-policy modules:${hm_mods}"
            # shellcheck disable=SC2086
            if ! semodule -s "${type}" -i ${hm_mods} 2>"${hm_err}"; then
                warn "batched hugmesh node-policy load failed: $(tr '\n' ' ' < "${hm_err}")"
                warn "retrying per module to isolate the offender(s)"
                for hm_pp in ${hm_mods}; do
                    hm_m="${hm_pp##*/}"; hm_m="${hm_m%.pp}"
                    if semodule -s "${type}" -i "${hm_pp}" 2>"${hm_err}"; then
                        log "  ${hm_m}: loaded"
                    else
                        warn "  ${hm_m}: FAILED to load: $(tr '\n' ' ' < "${hm_err}")"
                    fi
                done
            fi
        else
            warn "selinux-modules.list present but none of its .pp are in /usr/share/selinux/${type} — no hugmesh policy loaded"
        fi
        rm -f "${hm_err}"
        # Per-module postcondition, from the store — the machine-readable
        # marker the QEMU assertions consume. Written on EVERY provision run
        # (a re-provision overwrites), success included: "loaded" lines are
        # what lets an assertion distinguish "all good" from "file predates
        # this layer".
        hm_loaded="$(semodule -s "${type}" -l 2>/dev/null || true)"
        {
            echo "# hugmesh SELinux node-policy per-module load status."
            echo "# Written by provision_selinux() (keys-provision) at every provision run,"
            echo "# derived from 'semodule -s ${type} -l' AFTER the manifest-driven load."
            echo "# Read by tests/qemu/assertions.sh. One '<module> <verdict>' line per"
            echo "# manifest module; verdict: loaded | failed | missing-pp."
            while read -r hm_m; do
                case "${hm_m}" in ''|'#'*) continue ;; esac
                if [ ! -f "/usr/share/selinux/${type}/${hm_m}.pp" ]; then
                    echo "${hm_m} missing-pp"; hm_failed="${hm_failed} ${hm_m}(missing-pp)"
                elif printf '%s\n' "${hm_loaded}" | grep -q "^${hm_m}\b"; then
                    echo "${hm_m} loaded"
                else
                    echo "${hm_m} failed"; hm_failed="${hm_failed} ${hm_m}"
                fi
            done < /usr/share/hugmesh/selinux-modules.list
        } > "${STATE_DIR}/selinux-modules.status"
        if [ -n "${hm_failed}" ]; then
            selinux_provision_failed "hugmesh node-policy module(s) not in the ${type} store after the manifest load:${hm_failed} — see ${STATE_DIR}/selinux-modules.status and the semodule stderr above"
        fi
        # The modules ship with rules still tagged '# INFERRED-WIDE' in
        # specs/selinux/*.te; they are meant to run PERMISSIVE until a real
        # protected build+boot has produced an AVC pass to narrow them against.
        # An operator who set .selinux.mode=enforcing in provision.json gets them
        # enforced from this boot on — say so loudly rather than silently.
        [ "${mode}" = "enforcing" ] && \
            warn "SELinux mode=enforcing AND hugmesh node policy loaded: those modules' INFERRED-WIDE rules have not been narrowed against a real AVC pass. Prefer permissive + /etc/init.d/selinux-enforce-gate."
    fi
    # ── END hugmesh node-policy load ──
    log "Relabelling filesystem (this can take a while)"
    local relabel_ok=1
    # restorecon IS THE RELABELER. setfiles used to be tried first with restorecon
    # as an `||` fallback, and that combination is what left the fleet kernel_t.
    #
    # Measured on hugmesh-x86-amd64-pki-test-20260814T112817Z, same loaded policy,
    # and a perfectly valid file_contexts (/usr/bin(/.*)? -> ...:bin_t:s0):
    #
    #   setfiles -v -F <file_contexts> /usr/bin
    #     Relabeled /usr/bin      from <no context> to kernel
    #     Relabeled /usr/bin/dcb  from <no context> to kernel        rc=0
    #   restorecon -RF /usr/bin
    #     /usr/bin    -> system_u:object_r:bin_t:s0                  rc=0
    #     /usr/bin/sh -> system_u:object_r:shell_exec_t:s0
    #
    # setfiles writes the literal string "kernel" as EVERY label. That is not a
    # valid file context, and it is exactly why every process on the node ends up
    # kernel_t and no domain transition can occur. Worse it EXITS 0, so the `||`
    # never fired and the relabeler that works was never reached.
    #
    # restorecon reads the same policy and the same file_contexts and produces
    # correct labels — including repairing paths setfiles had already corrupted.
    # So: restorecon first, always. setfiles remains only for an image with no
    # restorecon at all, and the postcondition below catches it when it lies.
    if have restorecon; then
        restorecon -RF / 2>/dev/null || { relabel_ok=0; warn "restorecon -RF / failed"; }
    elif have setfiles && [ -f "/etc/selinux/${type}/contexts/files/file_contexts" ]; then
        warn "no restorecon on this image — falling back to setfiles, which has been"
        warn "  observed writing the literal context 'kernel' for every path; the"
        warn "  postcondition below is the only thing between that and a node that"
        warn "  believes it is labelled."
        setfiles -F "/etc/selinux/${type}/contexts/files/file_contexts" / 2>/dev/null || \
            { relabel_ok=0; warn "relabel incomplete"; }
    else
        relabel_ok=0; warn "no relabeler available (neither restorecon nor setfiles)"
    fi
    # /.autorelabel carries the STANDARD semantics: it REQUESTS a relabel and is
    # removed by whatever completes one. On these images provision_selinux() IS
    # the relabeler — no rc script ever consumes the flag — so a successful
    # relabel must CONSUME it. (It used to be touched unconditionally right
    # here, AFTER the relabel, which meant selinux-enforce-gate's
    # check_relabel_clean() could never pass on any provisioned node.) After a
    # FAILED relabel, raise it instead: the labels on disk cannot be trusted,
    # and the still-present flag is exactly the "a relabel is still owed"
    # signal the enforce-gate refuses on.
    # POSTCONDITION: a relabel that changed nothing is a relabel that did not run.
    # setfiles/restorecon exit 0 when they no-op, so "it returned success" is not
    # evidence that anything was labelled — and both invocations above are
    # `2>/dev/null`, so whatever they complained about is gone.
    #
    # Measured on hugmesh-x86-amd64-pki-test-20260814T112817Z: this block logged
    # "Relabelling filesystem (this can take a while)" and the "SELinux configured"
    # line that follows it in the SAME SECOND on a 15 GB rootfs, consumed
    # /.autorelabel, and left every file unlabeled_t with all 116 processes still
    # running as kernel_t. The enforce-gate's check_relabel_clean() then had
    # nothing to object to, because the flag it keys on had been removed.
    #
    # So ask the question check_relabel_clean() asks, on a few cheap probes
    # instead of a second full-tree walk: if restorecon STILL wants to change
    # these, no relabel happened, whatever the exit status said.
    if [ "${relabel_ok}" = 1 ] && have restorecon; then
        _relabel_pending=""
        for _relabel_probe in /bin/sh /etc/passwd /usr/bin; do
            [ -e "${_relabel_probe}" ] || continue
            if [ -n "$(restorecon -nv "${_relabel_probe}" 2>/dev/null)" ]; then
                _relabel_pending="${_relabel_pending} ${_relabel_probe}"
            fi
        done
        if [ -n "${_relabel_pending}" ]; then
            relabel_ok=0
            warn "relabel reported success but restorecon still wants to relabel:${_relabel_pending}"
            warn "  -> the filesystem was NOT labelled. Every domain transition depends on"
            warn "     file labels, so SELinux confinement would be inert on this node."
        fi
    fi
    if [ "${relabel_ok}" = 1 ]; then
        rm -f /.autorelabel
    else
        touch /.autorelabel
        warn "leaving /.autorelabel set — the enforce-gate refuses to flip until a relabel completes"
    fi
    # ── HARD POSTCONDITION (selinux-aware images only) ──
    # Every load path above degrades softly (`2>/dev/null || warn`) so a broken
    # SELinux userland can never brick first boot — but on an image BUILT
    # selinux-aware a soft-failed load must not provision "normally" either.
    if [ "${aware}" = 1 ] && ! selinux_policy_loaded; then
        selinux_provision_failed "no policy loaded after provisioning (selinuxfs exposes no readable policy and getenforce does not report Enforcing/Permissive)"
        return 0
    fi
    log "SELinux configured (${mode}). Switch to enforcing after verifying: setenforce 1 + SELINUX=enforcing"
}

# ── Cluster node inventory -> /etc/hosts (reach peers by IP) ──────
# So a joining node reaches the mesh (headscale/tailscale login_server) and the
# k8s control-plane (kubeadm api_server) by IP even before DNS exists: the
# hostname-based config resolves via these /etc/hosts entries.
provision_hosts() {
    jqe '.nodes' || return 0
    local n i ip name dom facade pki_ip
    n="$(jqm '.nodes | length')"
    dom="$(jqm '.hugmesh.cluster_domain // ""')"
    # Fail-closed: dom/facade/pki_ip and every node ip/name below are written VERBATIM into
    # /etc/hosts; a newline or whitespace in any of them injects arbitrary host lines (e.g.
    # mapping the control-plane name to an attacker IP = first-boot join MITM), the same class
    # the resolve_cp_dns_name() + magic_dns_domain gates fence off. Reject anything that is not a
    # bare DNS name / IP literal — blank a malformed OPTIONAL value here, skip a malformed node
    # in the loop. (These gates run BEFORE the `{ … } >> /etc/hosts` block, so warn is unredirected.)
    if [ -n "${dom}" ] && [ "${dom}" != "null" ] && [[ ! "${dom}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "cluster_domain is not a bare DNS name ([A-Za-z0-9._-]) — dropping the .<domain> host suffix"
        dom=""
    fi
    # Facade alias: internal nodes/laptops must resolve the public facade name to
    # the pki node's INTERNAL ip (the pki node DNATs :443 -> pki gateway), so
    # VPN/LAN traffic — especially reaching headscale via the pki gateway — never
    # loops back out to the router/external IP. Public DNS still points the same
    # name at the external IP. Override via .hugmesh.facade_host; defaults to
    # scale.<cluster_domain>.
    facade="$(jqm '.hugmesh.facade_host // ""')"
    if [ -z "${facade}" ] || [ "${facade}" = "null" ]; then
        { [ -n "${dom}" ] && [ "${dom}" != "null" ]; } && facade="scale.${dom}" || facade=""
    fi
    if [ -n "${facade}" ] && [ "${facade}" != "null" ] && [[ ! "${facade}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "facade_host is not a bare DNS name ([A-Za-z0-9._-]) — dropping the facade host entry"
        facade=""
    fi
    pki_ip=""
    for ((i = 0; i < n; i++)); do
        [ "$(jqm ".nodes[$i].role")" = "pki" ] && { pki_ip="$(jqm ".nodes[$i].ip")"; break; }
    done
    if [ -n "${pki_ip}" ] && [ "${pki_ip}" != "null" ] && [[ ! "${pki_ip}" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        warn "pki node ip is not an IP literal ([0-9A-Fa-f:.]) — dropping the facade/cp host entries"
        pki_ip=""
    fi
    # Stable control-plane MagicDNS name for the first-boot window: until the
    # joining node's MagicDNS converges, resolve the CP endpoint to the pki
    # node's IP so `kubeadm join <cp_dns_name>:6443` works immediately. MagicDNS
    # then takes over (and survives a pki IP change).
    local cpname; cpname="$(resolve_cp_dns_name)"
    log "Writing /etc/hosts for ${n} cluster node(s)${facade:+ + facade ${facade}}${cpname:+ + cp ${cpname}}"
    sed -i '/# >>> hugmesh nodes/,/# <<< hugmesh nodes/d' /etc/hosts 2>/dev/null || true
    {
        echo "# >>> hugmesh nodes"
        for ((i = 0; i < n; i++)); do
            ip="$(jqm ".nodes[$i].ip")"; name="$(jqm ".nodes[$i].name")"
            [ -n "${ip}" ] && [ "${ip}" != "null" ] && [ -n "${name}" ] || continue
            # >&2: this loop runs INSIDE the `{ … } >> /etc/hosts` block, so warn must NOT
            # land on stdout (which is the hosts file). Skip a node whose ip/name is not a
            # bare IP literal / hostname — a newline would inject standalone host lines.
            if [[ ! "${ip}" =~ ^[0-9A-Fa-f:.]+$ ]] || [[ ! "${name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
                warn "node[$i] ip/name malformed (IP literal + [A-Za-z0-9._-] hostname only) — skipping" >&2
                continue
            fi
            if [ -n "${dom}" ] && [ "${dom}" != "null" ]; then
                echo "${ip} ${name} ${name}.${dom}"
            else
                echo "${ip} ${name}"
            fi
        done
        # Public facade name -> pki node internal IP (internal/VPN path to the pki
        # gateway + headscale; bypasses the external IP for in-cluster nodes).
        [ -n "${facade}" ] && [ -n "${pki_ip}" ] && [ "${pki_ip}" != "null" ] && echo "${pki_ip} ${facade}"
        # Stable control-plane name -> pki IP (first-boot bridge before MagicDNS).
        [ -n "${cpname}" ] && [ -n "${pki_ip}" ] && [ "${pki_ip}" != "null" ] && echo "${pki_ip} ${cpname}"
        echo "# <<< hugmesh nodes"
    } >> /etc/hosts
}

# ── Gentoo binhost client (binary OS updates over the VPN) ────────
provision_binhost() {
    local url; url="$(jqm '.binhost.url // ""')"
    [ -n "${url}" ] && [ "${url}" != "null" ] || return 0
    # make.conf may be a file or a dir; append a drop-in either way.
    if [ -d /etc/portage/make.conf ]; then
        printf 'PORTAGE_BINHOST="%s"\nFEATURES="${FEATURES} getbinpkg"\n' "${url}" \
            > /etc/portage/make.conf/zz-binhost.conf
    elif ! grep -q 'PORTAGE_BINHOST' /etc/portage/make.conf 2>/dev/null; then
        printf '\n# hugmesh binhost (binary OS updates over the VPN)\nPORTAGE_BINHOST="%s"\nFEATURES="${FEATURES} getbinpkg"\n' \
            "${url}" >> /etc/portage/make.conf
    fi
    log "Configured Gentoo binhost: ${url}"
}

# ── Calico CNI config from KEYS (control-plane) ───────────────────
# Renders the Tigera Installation CR from provision.json .calico, so pod CIDR /
# encapsulation / NAT / block size are controlled by the USB config. The
# operator itself is installed by ArgoCD (apps/01-calico.yaml); this applies the
# Installation once a kubeconfig + the operator CRD exist.
provision_calico() {
    [ "$(jqm '.calico.enabled // false')" = "true" ] || { log "Calico config disabled"; return 0; }
    [ -f /etc/kubernetes/admin.conf ] || { log "Calico: no kubeconfig yet (apply after kubeadm init)"; return 0; }
    have kubectl || return 0
    local cidr enc nat block
    cidr="$(jqm '.calico.pod_cidr // "10.244.0.0/16"')"
    enc="$(jqm '.calico.encapsulation // "VXLAN"')"
    block="$(jqm '.calico.block_size // 26')"
    [ "$(jqm '.calico.nat_outgoing // true')" = "true" ] && nat=Enabled || nat=Disabled
    log "Applying Calico Installation from KEYS (cidr=${cidr} encap=${enc} nat=${nat})"
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f - <<EOF 2>/dev/null \
        || warn "Calico Installation apply failed (operator CRD not ready yet?)"
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        cidr: ${cidr}
        encapsulation: ${enc}
        natOutgoing: ${nat}
        blockSize: ${block}
EOF
}

# Enroll the org Secure Boot signing cert into MokList so the UEFI firmware
# (via shim) trusts our signed UKI and GRUB on subsequent boots. Does nothing if:
#  - not an EFI system (no /sys/firmware/efi)
#  - mokutil not available (Pi, or an image built without sbsigntools)
#  - cert already enrolled
# Enrollment is pending-reboot (MokManager confirms at next boot); the system
# continues to boot normally (shim falls through to unsigned-boot prompts until
# the cert is confirmed, after which no further action is needed).
provision_secureboot() {
    local cert_pem="/etc/hugmesh/secureboot/sb.crt"
    local cert_der="/etc/hugmesh/secureboot/sb.cer"
    local esp_cert="/boot/efi/EFI/hugmesh/sb.cer"
    # Skip on Pi / non-EFI systems (no EFI runtime services).
    [ -d /sys/firmware/efi ] || { log "secureboot: non-EFI system — skipping cert enrollment"; return 0; }
    # Prefer DER cert from ESP (guaranteed fresh after each build); fall back to rootfs copy.
    local import_cert="${cert_der}"
    [ -f "${import_cert}" ] || import_cert="${esp_cert}"
    [ -f "${import_cert}" ] || { log "secureboot: no org cert at ${cert_der} or ${esp_cert} — skipping"; return 0; }
    command -v mokutil >/dev/null || { log "secureboot: mokutil not installed — skipping cert enrollment"; return 0; }
    # Check if our cert is already in MokList or the UEFI db.
    local fp; fp="$(openssl x509 -noout -fingerprint -sha256 -in "${cert_pem}" 2>/dev/null | cut -d= -f2 | tr -d ':')"
    if [ -n "${fp}" ] && mokutil --list-enrolled 2>/dev/null | grep -qi "${fp}"; then
        log "secureboot: org cert already enrolled in MokList — nothing to do"
        return 0
    fi
    log "secureboot: scheduling org Secure Boot cert for MokList enrollment (will prompt at next reboot)"
    # --root-pw uses the root password (set by provision_users) for confirmation,
    # avoiding an interactive passphrase prompt in the headless provisioning flow.
    if mokutil --import "${import_cert}" --root-pw 2>/dev/null; then
        log "secureboot: org cert scheduled — confirm in MokManager on next reboot to activate Secure Boot chain"
    else
        log "secureboot: WARN mokutil import failed (check /var/log/keys-provision.log); Secure Boot may not verify images until cert is enrolled manually"
    fi
}

# ── Main ───────────────────────────────────────────────────────────
main() {
    # NODE-STORAGE pool reconcile: a SEPARATE entry point, dispatched before anything
    # else. It must run on an already-provisioned node with no KEYS media, so it has
    # to be reached before the DONE-marker/find_and_mount gates below — which is
    # precisely where `--pool` used to die. See provision_storage_pool().
    if [ "${1:-}" = "--pool" ]; then
        provision_storage_pool
        return $?
    fi

    log "=== keys-provision starting ==="
    ensure_host_keys

    if [ -f "${DONE_MARKER}" ] && [ "${KEYS_FORCE:-0}" != "1" ]; then
        log "Already provisioned ($(cat "${DONE_MARKER}")). Skipping."
        # still honour a force flag dropped on the media
        if find_and_mount; then
            if [ -f "${BASE}/.provision-force" ]; then
                log "Found .provision-force on media — re-provisioning"
            else
                cleanup; return 0
            fi
        else
            return 0
        fi
    else
        find_and_mount || { log "No KEYS media; nothing else to do."; return 0; }
    fi

    MANIFEST="${BASE}/provision.json"
    [ -f "${MANIFEST}" ] || MANIFEST="/dev/null"

    # STANDALONE desktop: a self-contained personal workstation. Even WITH a KEYS
    # USB present (for Secure Boot enrollment / a LUKS keyfile), it must NOT join
    # the mesh, run k8s, or wire Casdoor/OIDC SSO desktop governance. We still honour
    # ssh host keys, users, storage/LUKS, egress-VPN, secureboot, hooks and SELinux.
    local STANDALONE_IMG=false
    [ -f /etc/hugmesh/standalone ] && { STANDALONE_IMG=true; log "STANDALONE image — skipping mesh / k8s / SSO governance provisioning"; }

    provision_ssh_host_keys
    provision_identity
    provision_hosts      # peers reachable by IP before mesh/k8s join
    provision_binhost    # binary OS updates over the VPN
    provision_users
    provision_device_password   # superadmin client variant: set device password from KEYS hash
    provision_network
    provision_files
    provision_certs      # KEYS/certs -> system trust store, for EVERY manifest (no `files` gate)
    provision_truststore
    provision_storage
    provision_vpn        # egress-VPN provider configs (own-domain-only, 0600; service default-off)
    if ! ${STANDALONE_IMG}; then
        provision_desktop_governance   # client desktops: Discover->BFF registry remote, SSO-claim sudo gate (default-deny, empty store)
        provision_headscale
        provision_tailscale
        provision_device_registry   # Layer-B sshd enforcement (ADMIN nodes) — after mesh join, before k8s
        provision_domain_registry   # #4 domain-registry -> brand-repo bridge (default-off; reuses Layer-B key) — after device-registry stages the pubkey
        provision_node_storage      # NODE-STORAGE reconcile enable (pull twin of the registry sync; inert with no registered pool)
        provision_kubernetes
        provision_backup
        provision_update     # OPT-IN binpkg auto-update plumbing (default-off; superadmin enables via ConfigMap; absence => off)
        provision_hugmesh
        provision_calico
        provision_vault
    fi
    provision_secureboot   # schedule org SB cert MOK enrollment (EFI systems only)
    provision_run_hooks
    provision_selinux   # last: relabel the fully-provisioned filesystem

    date -u '+%Y-%m-%dT%H:%M:%SZ' > "${DONE_MARKER}"
    log "=== keys-provision complete ==="
    cleanup
}

main "$@"
