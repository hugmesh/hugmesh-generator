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
#   3. the baked brand var HEADSCALE_URL (written to /etc/snapdragon/headscale-url
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
        [ -r /etc/snapdragon/headscale-url ] && ep="$(tr -d '[:space:]' < /etc/snapdragon/headscale-url 2>/dev/null)"
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
        [ -r /etc/snapdragon/headscale-url ] && ep="$(tr -d '[:space:]' < /etc/snapdragon/headscale-url 2>/dev/null)"
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
    echo "${n}"
}

# ── Always: ensure SSH host keys exist so sshd can start ───────────
ensure_host_keys() {
    if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
        log "Generating SSH host keys"
        ssh-keygen -A
    fi
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
            mkdir -p /etc/sudoers.d
            if [ "${nopw}" = "true" ]; then
                echo "${name} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/10-${name}"
            else
                echo "${name} ALL=(ALL) ALL" > "/etc/sudoers.d/10-${name}"
            fi
            chmod 0440 "/etc/sudoers.d/10-${name}"
            log "Granted sudo to ${name} (nopasswd=${nopw})"
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
        echo "${hn}" > /etc/hostname
        mkdir -p /etc/conf.d
        echo "hostname=\"${hn}\"" > /etc/conf.d/hostname
        hostname "${hn}" 2>/dev/null || true
        log "Hostname set to ${hn}"
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
        echo "country=${country}" > /etc/conf.d/wpa_supplicant 2>/dev/null || true
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
    [ "${enabled}" = "true" ] || { log "headscale disabled in manifest"; return 0; }

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
    fi
    # Fleet full-mesh ACL: prefer a USB-supplied policy.hujson, else fall back
    # to the baked-in /etc/headscale/policy.hujson shipped in the image.
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
            sed -i "s|^\(\s*\)base_domain:.*|\1base_domain: ${dnsdom}|" /etc/headscale/config.yaml
            log "headscale MagicDNS base_domain set to ${dnsdom}"
        fi
    fi

    chown -R headscale:headscale /etc/headscale /var/lib/headscale /run/headscale
    chmod 0600 /var/lib/headscale/*.key 2>/dev/null || true

    rc-update add headscale default 2>/dev/null || true
    rc-service headscale start 2>/dev/null || warn "headscale failed to start"

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

    # ── Fleet full-mesh ACL + subnet-route auto-approval ──────────────────
    # Load the fleet policy (tagOwners + autoApprovers + intra-fleet accepts)
    # so nodes can self-tag (tag:snapdragon/+role) and their advertised pod +
    # service routes are auto-approved. Idempotent: re-running just re-applies.
    if [ -n "${policy_file}" ] && [ -f "${policy_file}" ]; then
        if headscale policy set -f "${policy_file}" 2>/dev/null; then
            log "Loaded headscale ACL policy from ${policy_file}"
        else
            warn "headscale policy set failed for ${policy_file} (check hujson syntax / mode: file)"
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
block = ("  # >>> snapdragon cp dns (managed)\n"
         "  extra_records:\n"
         f"    - name: \"{cpname}\"\n"
         "      type: \"A\"\n"
         f"      value: \"{tip}\"\n"
         "  # <<< snapdragon cp dns (managed)\n")
# Drop any prior managed block.
txt = re.sub(r"  # >>> snapdragon cp dns \(managed\).*?  # <<< snapdragon cp dns \(managed\)\n",
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
    [ "${enabled}" = "true" ] || { log "tailscale disabled in manifest"; return 0; }

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
    # (advertises tag:snapdragon + pod/service routes, --accept-routes). Without
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
    local sr; sr="$(jqm '.snapdragon.role // "pki"')"
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node "$(hostname)" "snapdragon.systems/role=${sr}" --overwrite 2>/dev/null || true
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl taint nodes "$(hostname)" node-role.kubernetes.io/control-plane- 2>/dev/null || true
    log "Control-plane node labelled role=${sr}, control-plane taint removed"
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
#      /etc/snapdragon so an operator can copy it to additional CPs.
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
    if [ -z "${key}" ] && [ -f /etc/snapdragon/etcd-encryption.key ]; then
        key="$(tr -d '[:space:]' < /etc/snapdragon/etcd-encryption.key 2>/dev/null)"
    fi
    if [ -z "${key}" ]; then
        key="$(head -c 32 /dev/urandom | base64 -w0 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -d '\n')"
        mkdir -p /etc/snapdragon
        printf '%s\n' "${key}" > /etc/snapdragon/etcd-encryption.key
        chmod 0600 /etc/snapdragon/etcd-encryption.key
        warn "minted a fresh etcd Secret-encryption key at /etc/snapdragon/etcd-encryption.key — COPY it to KEYS/kubernetes/encryption-key + every other control plane (or their etcd won't decrypt these Secrets)"
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
                    mkdir -p /etc/snapdragon
                    { kubeadm token create --print-join-command 2>/dev/null; } > /etc/snapdragon/kubeadm-join.cmd
                    local ck
                    ck="$(kubeadm init phase upload-certs --upload-certs 2>/dev/null \
                            | grep -Eo '[0-9a-f]{64}' | tail -1)"
                    [ -n "${ck}" ] && { echo "${ck}" > /etc/snapdragon/kubeadm-certificate-key; chmod 0600 /etc/snapdragon/kubeadm-certificate-key; }
                    chmod 0600 /etc/snapdragon/kubeadm-join.cmd 2>/dev/null || true
                    log "First control plane initialised; join material in /etc/snapdragon/kubeadm-join.cmd"
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
    local part="$1" name="$2" do_format="$3" keyfile="$4"
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
        printf '%s UUID=%s /etc/snapdragon/luks/%s.key luks,tpm2-device=auto\n' \
            "${name}" "${puuid}" "${name}" >> /etc/crypttab
        # Install the recovery keyfile off the read-only USB into a 0600 root path
        # so crypttab can read it at boot (TPM2 unlock makes it a fallback only).
        install -Dm0600 "${keyfile}" "/etc/snapdragon/luks/${name}.key" 2>/dev/null || true
        log "Added ${name} to /etc/crypttab (UUID=${puuid}, TPM2-or-keyfile unlock)" >&2
    fi
    luks_try_tpm2_enroll "${part}" "${keyfile}" >&2
    printf '%s\n' "${mapper}"
}

provision_storage() {
    jqe '.storage.devices' || return 0
    local n i
    n="$(jqm '.storage.devices | length')"
    log "Configuring ${n} attached storage device(s)"
    for ((i = 0; i < n; i++)); do
        local match fs fmt mp opts label dev part uuid usefor encrypt luksname blkdev
        match="$(jqm ".storage.devices[$i].match")"
        fs="$(jqm ".storage.devices[$i].filesystem // \"ext4\"")"
        fmt="$(jqm ".storage.devices[$i].format // false")"
        mp="$(jqm ".storage.devices[$i].mountpoint")"
        opts="$(jqm ".storage.devices[$i].options // \"defaults,noatime\"")"
        label="$(jqm ".storage.devices[$i].label // \"\"")"
        usefor="$(jqm ".storage.devices[$i].use_for // [] | join(\" \")")"
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
            blkdev="$(luks_open_or_format "${part}" "${luksname}" "${fmt}" "${kf}")" || \
                warn "storage[$i]: encryption unavailable — ${part} mounted PLAINTEXT (see docs/ENCRYPTION-AT-REST.md)"
        fi

        if [ "${fmt}" = "true" ]; then
            "mkfs.${fs}" ${label:+-L "${label}"} -F "${blkdev}" 2>/dev/null || "mkfs.${fs}" "${blkdev}"
        fi

        mkdir -p "${mp}"
        mount -o "${opts}" "${blkdev}" "${mp}" || { warn "mount ${blkdev} failed"; continue; }
        # fstab references the unlocked mapper by its UUID for encrypted volumes
        # (crypttab opens it first), or the raw partition UUID for plaintext.
        uuid="$(blkid -s UUID -o value "${blkdev}" 2>/dev/null)"
        if [ -n "${uuid}" ] && ! grep -q "${uuid}" /etc/fstab; then
            printf 'UUID=%s  %s  %s  %s  0 2\n' "${uuid}" "${mp}" "${fs}" "${opts}" >> /etc/fstab
            log "Added ${mp} to /etc/fstab (UUID=${uuid})"
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

# ── Backups (etcd + PostgreSQL) to attached storage and/or network share ──
provision_backup() {
    jqe '.backup' || return 0
    [ "$(jqm '.backup.enabled // false')" = "true" ] || return 0
    log "Configuring backups"
    mkdir -p /etc/snapdragon

    # Mount any configured network shares (by file → fstab) so the backup
    # script can write to them. NFS and CIFS supported.
    local nfs_srv nfs_exp nfs_mp cifs_unc cifs_mp cifs_cred
    nfs_srv="$(jqm '.backup.nfs.server // ""')"; nfs_exp="$(jqm '.backup.nfs.export // ""')"
    nfs_mp="$(jqm '.backup.nfs.mountpoint // "/mnt/backup-nfs"')"
    if [ -n "${nfs_srv}" ] && [ "${nfs_srv}" != "null" ]; then
        mkdir -p "${nfs_mp}"
        if ! grep -q "${nfs_mp}" /etc/fstab; then
            printf '%s:%s  %s  nfs  %s  0 0\n' "${nfs_srv}" "${nfs_exp}" "${nfs_mp}" \
                "$(jqm '.backup.nfs.options // "rw,soft,_netdev,noatime"')" >> /etc/fstab
        fi
        mount "${nfs_mp}" 2>/dev/null || warn "NFS mount ${nfs_mp} deferred to boot"
        log "Configured NFS backup share ${nfs_srv}:${nfs_exp} -> ${nfs_mp}"
    fi
    cifs_unc="$(jqm '.backup.cifs.unc // ""')"; cifs_mp="$(jqm '.backup.cifs.mountpoint // "/mnt/backup-cifs"')"
    if [ -n "${cifs_unc}" ] && [ "${cifs_unc}" != "null" ]; then
        cifs_cred="$(jqm '.backup.cifs.credentials_file // ""')"
        [ -n "${cifs_cred}" ] && [ -f "${BASE}/${cifs_cred}" ] && \
            { install -Dm0600 "${BASE}/${cifs_cred}" /etc/snapdragon/cifs.cred; cifs_cred=/etc/snapdragon/cifs.cred; }
        mkdir -p "${cifs_mp}"
        if ! grep -q "${cifs_mp}" /etc/fstab; then
            printf '%s  %s  cifs  credentials=%s,_netdev,uid=0,gid=0,file_mode=0600,dir_mode=0700  0 0\n' \
                "${cifs_unc}" "${cifs_mp}" "${cifs_cred:-/etc/snapdragon/cifs.cred}" >> /etc/fstab
        fi
        mount "${cifs_mp}" 2>/dev/null || warn "CIFS mount ${cifs_mp} deferred to boot"
        log "Configured CIFS backup share ${cifs_unc} -> ${cifs_mp}"
    fi

    # Write the backup config the snapdragon-backup script reads, straight
    # from the manifest (file-based config).
    jq '.backup' "${MANIFEST}" > /etc/snapdragon/backup.json 2>/dev/null || true

    # Schedule it via cron (cronie reads /etc/cron.d).
    local sched; sched="$(jqm '.backup.schedule // "0 3 * * *"')"
    if [ -x /usr/local/sbin/snapdragon-backup ]; then
        printf '%s root /usr/local/sbin/snapdragon-backup >> /var/log/snapdragon-backup.log 2>&1\n' "${sched}" \
            > /etc/cron.d/snapdragon-backup
        log "Scheduled backups: ${sched}"
    else
        warn "snapdragon-backup not installed in image"
    fi
}

# ── Snapdragon GitOps (ArgoCD app-of-apps) — control-plane only ────
provision_snapdragon() {
    local role label
    # Node label hint (snapdragon.systems/role / compute) for scheduling.
    label="$(jqm '.snapdragon.node_labels // {} | to_entries | map("\(.key)=\(.value)") | join(",")')"
    if [ -n "${label}" ] && [ "${label}" != "null" ] && [ -f /etc/kubernetes/admin.conf ]; then
        KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node "$(hostname)" ${label//,/ } --overwrite 2>/dev/null || true
        log "Applied node labels: ${label}"
    fi

    [ "$(jqm '.snapdragon.gitops.enabled // false')" = "true" ] || { log "Snapdragon GitOps disabled"; return 0; }
    role="$(jqm '.kubernetes.role // "none"')"
    case "${role}" in control-plane|master|server) ;; *) log "Not a control-plane — skipping GitOps bootstrap"; return 0 ;; esac
    [ -f /etc/kubernetes/admin.conf ] || { warn "No kubeconfig yet — run cluster bootstrap after kubeadm init"; return 0; }
    local bs=/var/lib/snapdragon/cluster/bootstrap/bootstrap.sh
    [ -f "${bs}" ] || { warn "GitOps payload not baked into image"; return 0; }
    log "Bootstrapping ArgoCD + Snapdragon app-of-apps"
    KUBECONFIG=/etc/kubernetes/admin.conf bash "${bs}" || warn "GitOps bootstrap returned non-zero"
}

# ── Vault / External Secrets (k8s Secrets, online + USB fallback) ──
# Vault is the source of truth; ESO + the ClusterSecretStore/ExternalSecrets
# are deployed by ArgoCD. Here we only seed the bits a fresh cluster needs:
#   * online : the "vault-token" Secret so ESO's ClusterSecretStore can auth.
#   * offline: materialize the workload Secrets directly from KEYS/vault/
#              secrets.json so they exist even with no reachable Vault.
provision_vault() {
    jqe '.vault' || { log "No .vault block — skipping Vault/ESO seeding"; return 0; }
    [ "$(jqm '.vault.enabled // false')" = "true" ] || { log "Vault disabled in manifest"; return 0; }

    [ -f /etc/kubernetes/admin.conf ] || { warn "No kubeconfig yet — skipping Vault/ESO seeding"; return 0; }
    have kubectl || { warn "kubectl not installed — skipping Vault/ESO seeding"; return 0; }
    local kc=/etc/kubernetes/admin.conf

    local address kv_mount base_path token_file install_eso
    address="$(jqm '.vault.address // ""')"
    kv_mount="$(jqm '.vault.kv_mount // "secret"')"
    base_path="$(jqm '.vault.base_path // "snapdragon"')"
    token_file="$(jqm '.vault.token_file // "vault/token"')"
    install_eso="$(jqm '.vault.install_eso // false')"
    [ "${address}" = "null" ] && address=""
    log "Vault seeding: address='${address}' kv_mount=${kv_mount} base_path=${base_path} install_eso=${install_eso}"

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
                log "Created k8s Secret external-secrets/vault-token for ESO ClusterSecretStore 'snapdragon-vault'"
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
            for gen_ns in snapdragon-pki snapdragon-backend snapdragon-frontend; do
                KUBECONFIG="${kc}" kubectl create namespace "${gen_ns}" \
                    --dry-run=client -o yaml 2>/dev/null | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null \
                    || warn "could not ensure namespace ${gen_ns}"
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
        for ca_ns in vault snapdragon-pki snapdragon-backend snapdragon-frontend; do
            KUBECONFIG="${kc}" kubectl create namespace "${ca_ns}" \
                --dry-run=client -o yaml 2>/dev/null | KUBECONFIG="${kc}" kubectl apply -f - 2>/dev/null \
                || warn "could not ensure namespace ${ca_ns}"
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
    local pki=/etc/snapdragon/pki
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
        KUBECONFIG=/etc/kubernetes/admin.conf kubectl create secret generic snapdragon-truststore \
            -n kube-system --from-file="${pki}/truststore.p12" \
            --dry-run=client -o yaml 2>/dev/null | KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f - 2>/dev/null \
            && log "Published truststore as Secret kube-system/snapdragon-truststore" || true
    fi
}

# ── SELinux first-boot setup (load policy on the Pi; relabel; set mode) ──
provision_selinux() {
    [ -d /etc/selinux ] || { log "SELinux not installed — skipping"; return 0; }
    have semodule || { log "semodule absent — skipping SELinux setup"; return 0; }
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
    log "Relabelling filesystem (this can take a while)"
    if have setfiles && [ -f "/etc/selinux/${type}/contexts/files/file_contexts" ]; then
        setfiles -F "/etc/selinux/${type}/contexts/files/file_contexts" / 2>/dev/null || \
        restorecon -RF / 2>/dev/null || warn "relabel incomplete"
    else
        restorecon -RF / 2>/dev/null || warn "restorecon unavailable"
    fi
    touch /.autorelabel
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
    dom="$(jqm '.snapdragon.cluster_domain // ""')"
    # Facade alias: internal nodes/laptops must resolve the public facade name to
    # the pki node's INTERNAL ip (the pki node DNATs :443 -> pki gateway), so
    # VPN/LAN traffic — especially reaching headscale via the pki gateway — never
    # loops back out to the router/external IP. Public DNS still points the same
    # name at the external IP. Override via .snapdragon.facade_host; defaults to
    # scale.<cluster_domain>.
    facade="$(jqm '.snapdragon.facade_host // ""')"
    if [ -z "${facade}" ] || [ "${facade}" = "null" ]; then
        { [ -n "${dom}" ] && [ "${dom}" != "null" ]; } && facade="scale.${dom}" || facade=""
    fi
    pki_ip=""
    for ((i = 0; i < n; i++)); do
        [ "$(jqm ".nodes[$i].role")" = "pki" ] && { pki_ip="$(jqm ".nodes[$i].ip")"; break; }
    done
    # Stable control-plane MagicDNS name for the first-boot window: until the
    # joining node's MagicDNS converges, resolve the CP endpoint to the pki
    # node's IP so `kubeadm join <cp_dns_name>:6443` works immediately. MagicDNS
    # then takes over (and survives a pki IP change).
    local cpname; cpname="$(resolve_cp_dns_name)"
    log "Writing /etc/hosts for ${n} cluster node(s)${facade:+ + facade ${facade}}${cpname:+ + cp ${cpname}}"
    sed -i '/# >>> snapdragon nodes/,/# <<< snapdragon nodes/d' /etc/hosts 2>/dev/null || true
    {
        echo "# >>> snapdragon nodes"
        for ((i = 0; i < n; i++)); do
            ip="$(jqm ".nodes[$i].ip")"; name="$(jqm ".nodes[$i].name")"
            [ -n "${ip}" ] && [ "${ip}" != "null" ] && [ -n "${name}" ] || continue
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
        echo "# <<< snapdragon nodes"
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
        printf '\n# snapdragon binhost (binary OS updates over the VPN)\nPORTAGE_BINHOST="%s"\nFEATURES="${FEATURES} getbinpkg"\n' \
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

# ── Main ───────────────────────────────────────────────────────────
main() {
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

    provision_ssh_host_keys
    provision_identity
    provision_hosts      # peers reachable by IP before mesh/k8s join
    provision_binhost    # binary OS updates over the VPN
    provision_users
    provision_network
    provision_files
    provision_truststore
    provision_storage
    provision_headscale
    provision_tailscale
    provision_kubernetes
    provision_backup
    provision_snapdragon
    provision_calico
    provision_vault
    provision_run_hooks
    provision_selinux   # last: relabel the fully-provisioned filesystem

    date -u '+%Y-%m-%dT%H:%M:%SZ' > "${DONE_MARKER}"
    log "=== keys-provision complete ==="
    cleanup
}

main "$@"
