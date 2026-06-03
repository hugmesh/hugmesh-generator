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
        local rhash
        rhash="$(jq -r '.root.password_hash // ""' "${f}")"
        if [ -n "${rhash}" ]; then
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
    login="$(jqm '.tailscale.login_server // ""')"
    up_args="$(jqm '.tailscale.up_args // ""')"
    if [ -n "${authkey}" ]; then
        local cmd=(tailscale up --authkey "${authkey}")
        [ -n "${login}" ] && [ "${login}" != "null" ] && cmd+=(--login-server "${login}")
        # shellcheck disable=SC2206
        [ -n "${up_args}" ] && [ "${up_args}" != "null" ] && cmd+=(${up_args})
        "${cmd[@]}" 2>/dev/null && log "tailscale up succeeded" || warn "tailscale up failed"
    fi
}

# ── Kubernetes ─────────────────────────────────────────────────────
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
            log "Running kubeadm init"
            if kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs; then
                mkdir -p /root/.kube
                cp -f /etc/kubernetes/admin.conf /root/.kube/config
                # distribute kubeconfig to sudo users
                local f="${BASE}/users.json"; [ -f "${f}" ] || f="${MANIFEST}"
                local n i
                n="$(jq '(.users // []) | length' "${f}" 2>/dev/null || echo 0)"
                for ((i = 0; i < n; i++)); do
                    local nm home
                    [ "$(jq -r ".users[$i].sudo // false" "${f}")" = "true" ] || continue
                    nm="$(jq -r ".users[$i].name" "${f}")"
                    home="$(getent passwd "${nm}" | cut -d: -f6)"
                    [ -n "${home}" ] || continue
                    mkdir -p "${home}/.kube"
                    cp -f /etc/kubernetes/admin.conf "${home}/.kube/config"
                    chown -R "${nm}:" "${home}/.kube"
                done
                # Label this (pki) node with its snapdragon role and allow the
                # pki-tier workloads (Vault, Casdoor, Cassandra, headscale) to
                # schedule on the control-plane — they all nodeSelector role=pki.
                local sr; sr="$(jqm '.snapdragon.role // "pki"')"
                KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node "$(hostname)" "snapdragon.systems/role=${sr}" --overwrite 2>/dev/null || true
                KUBECONFIG=/etc/kubernetes/admin.conf kubectl taint nodes "$(hostname)" node-role.kubernetes.io/control-plane- 2>/dev/null || true
                log "Control plane initialised (node labelled role=${sr}, control-plane taint removed)"
            else
                warn "kubeadm init failed — inspect ${LOG}"
            fi
            ;;
        worker|node|agent)
            local api token hash
            api="$(jqm '.kubernetes.join.api_server // ""')"
            token="$(jqm '.kubernetes.join.token // ""')"
            hash="$(jqm '.kubernetes.join.ca_cert_hash // ""')"
            if [ -n "${api}" ] && [ -n "${token}" ] && [ -n "${hash}" ]; then
                log "Running kubeadm join against ${api}"
                kubeadm join "${api}" --token "${token}" \
                    --discovery-token-ca-cert-hash "${hash}" \
                    && log "Joined cluster" || warn "kubeadm join failed"
            else
                warn "Incomplete kubernetes.join block — cannot join"
            fi
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

provision_storage() {
    jqe '.storage.devices' || return 0
    local n i
    n="$(jqm '.storage.devices | length')"
    log "Configuring ${n} attached storage device(s)"
    for ((i = 0; i < n; i++)); do
        local match fs fmt mp opts label dev part uuid usefor
        match="$(jqm ".storage.devices[$i].match")"
        fs="$(jqm ".storage.devices[$i].filesystem // \"ext4\"")"
        fmt="$(jqm ".storage.devices[$i].format // false")"
        mp="$(jqm ".storage.devices[$i].mountpoint")"
        opts="$(jqm ".storage.devices[$i].options // \"defaults,noatime\"")"
        label="$(jqm ".storage.devices[$i].label // \"\"")"
        usefor="$(jqm ".storage.devices[$i].use_for // [] | join(\" \")")"

        dev="$(resolve_storage_dev "${match}")"
        [ -n "${dev}" ] && [ -b "${dev}" ] || { warn "storage[$i]: no device for match '${match}'"; continue; }
        [ -n "${mp}" ] || { warn "storage[$i]: no mountpoint"; continue; }
        log "storage[$i]: ${match} -> ${dev}  mount ${mp} (${fs}, format=${fmt})"

        if [ "${fmt}" = "true" ]; then
            warn "Formatting ${dev} as ${fs} (single GPT partition) — destroying existing data"
            wipefs -a "${dev}" 2>/dev/null || true
            parted -s "${dev}" mklabel gpt
            parted -s "${dev}" mkpart primary "${fs}" 1MiB 100%
            sleep 1; partprobe "${dev}" 2>/dev/null || true; sleep 1
        fi
        if [[ "${dev}" =~ [0-9]$ ]]; then part="${dev}p1"; else part="${dev}1"; fi
        [ -b "${part}" ] || part="${dev}"   # whole-disk fs fallback
        if [ "${fmt}" = "true" ]; then
            "mkfs.${fs}" ${label:+-L "${label}"} -F "${part}" 2>/dev/null || "mkfs.${fs}" "${part}"
        fi

        mkdir -p "${mp}"
        mount -o "${opts}" "${part}" "${mp}" || { warn "mount ${part} failed"; continue; }
        uuid="$(blkid -s UUID -o value "${part}" 2>/dev/null)"
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
    local n i ip name dom
    n="$(jqm '.nodes | length')"
    dom="$(jqm '.snapdragon.cluster_domain // ""')"
    log "Writing /etc/hosts for ${n} cluster node(s)"
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
    provision_vault
    provision_run_hooks
    provision_selinux   # last: relabel the fully-provisioned filesystem

    date -u '+%Y-%m-%dT%H:%M:%SZ' > "${DONE_MARKER}"
    log "=== keys-provision complete ==="
    cleanup
}

main "$@"
