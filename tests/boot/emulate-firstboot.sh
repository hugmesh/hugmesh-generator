#!/usr/bin/env bash
# emulate-firstboot.sh — emulate the RPi/x86 image first-boot provisioning for
# "one of each kind" of node, by running the REAL keys-provision engine
# (specs/etc/keys-provision/provision.sh) inside a throwaway container against a
# generated KEYS directory (KEYS_PREMOUNTED=1, no block device needed).
#
# This exercises the actual boot-time logic — user creation from users.json,
# SSH key install, host-key generation, hostname/timezone, Kubernetes module +
# sysctl staging, and the KEYS/certs -> system trust store import — for roles:
# pki, backend, frontend, host. Rootless (uses the local Docker). It does NOT boot
# the kernel (no aarch64 stage4 is built here); it validates the provisioning the
# image runs at first boot.
#
# THE CERTIFICATE IMPORT IS ASSERTED FOR EVERY ROLE, ON PURPOSE. The manifests
# rendered below carry no `files` list — like every client stick (KEYS profile
# `host`: keys-template/examples/provision.host.json) and the frontend profile. Until
# the post-merge review of hugmesh-generator#645 (issue #588) the only import of
# KEYS/certs sat inside provision_files() below its `jqe '.files' || return 0`, so a
# stick like these imported NOTHING and a desktop provisioned from it never trusted
# the mesh CA, while the Studio's cloud Domains step said it did. The real engine runs
# here, unstubbed, on a real filesystem: a self-signed CA is placed in certs/ and the
# container must end with it under /usr/local/share/ca-certificates, rebuilt into
# /etc/ssl/certs by update-ca-certificates (the ca-certificates package is installed
# for that), and the log line that says so. On the pre-fix engine every role fails
# these three assertions.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="${REPO}/specs/etc/keys-provision/provision.sh"
BASE_IMAGE="${BOOT_BASE_IMAGE:-cassandra:5}"   # local debian-based image w/ apt
# One vocabulary (scripts/_roles-lib.sh): `host` was always the backend-gpu role.
ROLES=("${@:-pki backend frontend backend-gpu}")
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A throwaway SSH public key to install for the emulated admin user.
ssh-keygen -t ed25519 -N '' -C boot-emu -f "${WORK}/key" >/dev/null
PUBKEY="$(cat "${WORK}/key.pub")"
# A SHA-512 crypt password hash (deterministic test value).
HASH="$(openssl passwd -6 'boot-emu-pass')"
# A throwaway CA for the KEYS/certs import (what gen-provision-keys.sh tells the
# operator to copy onto the stick as certs/cluster-ca.crt), plus a .pem sibling: the
# import promises both suffixes.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
  -subj '/CN=boot-emu cluster CA' -keyout "${WORK}/ca.key" -out "${WORK}/ca.crt" >/dev/null 2>&1
CA_FP="$(openssl x509 -in "${WORK}/ca.crt" -noout -fingerprint -sha256 | cut -d= -f2)"

emulate_role() {
  # NB: `keys` is assigned in a SEPARATE statement from `role`. bash 5.3 localises
  # every name in a `local` list BEFORE running any of its assignments, so the
  # one-liner this replaced ("local role=\"$1\" krole keys=\"${WORK}/keys-${role}\"")
  # died on the very first role under this file's `set -u`:
  #     emulate-firstboot.sh: line 28: role: unbound variable
  # i.e. the whole first-boot emulation could not run at all on bash >= 5.3.
  local role="$1" krole
  local keys="${WORK}/keys-${role}"
  case "${role}" in
    pki) krole="control-plane" ;;
    *)   krole="worker" ;;
  esac
  mkdir -p "${keys}/ssh" "${keys}/certs"
  cp "${WORK}/ca.crt" "${keys}/certs/cluster-ca.crt"
  cp "${WORK}/ca.crt" "${keys}/certs/extra.pem"
  cat > "${keys}/users.json" <<EOF
{ "users": [ { "name": "opsadmin", "comment": "boot-emu", "groups": ["wheel","sudo"],
  "shell": "/bin/bash", "uid": 1100, "sudo": true, "sudo_nopasswd": true,
  "password_hash": "${HASH}", "ssh_authorized_keys": ["${PUBKEY}"] } ],
  "root": { "password_hash": "${HASH}" } }
EOF
  cat > "${keys}/provision.json" <<EOF
{ "version": 1, "hostname": "hugmesh-${role}", "timezone": "UTC",
  "headscale": { "enabled": false }, "tailscale": { "enabled": false },
  "kubernetes": { "role": "${krole}", "bootstrap": false },
  "hugmesh": { "role": "${role}", "cluster_domain": "hugmesh.net",
                  "node_labels": { "hugmesh.net/role": "${role}" } } }
EOF

  echo "================ first-boot emulation: role=${role} (k8s=${krole}) ================"
  docker run --rm \
    -v "${ENGINE}:/usr/sbin/keys-provision:ro" \
    -v "${keys}:/keys:ro" \
    -e KEYS_PREMOUNTED=1 -e KEYS_MOUNT=/keys \
    "${BASE_IMAGE}" bash -c '
      set -u
      export DEBIAN_FRONTEND=noninteractive
      (apt-get update -qq && apt-get install -y -qq jq passwd openssh-client procps iproute2 ca-certificates >/dev/null 2>&1) \
        || echo "[warn] apt unavailable; some assertions may fail"
      bash /usr/sbin/keys-provision || true
      echo "----- assertions (role $(cat /etc/hugmesh/role 2>/dev/null || echo n/a)) -----"
      P=0; F=0; ok(){ echo "  PASS $*"; P=$((P+1)); }; bad(){ echo "  FAIL $*"; F=$((F+1)); }
      id opsadmin >/dev/null 2>&1 && ok "user opsadmin created from users.json" || bad "user opsadmin"
      id -nG opsadmin 2>/dev/null | grep -w wheel >/dev/null && ok "group wheel auto-created + assigned" || bad "wheel group"
      [ -s /home/opsadmin/.ssh/authorized_keys ] && ok "SSH authorized_keys installed" || bad "authorized_keys"
      [ -f /etc/sudoers.d/10-opsadmin ] && ok "sudoers entry written" || bad "sudoers"
      [ -f /var/lib/keys-provision/users.created ] && ok "users.created marker" || bad "users.created marker"
      [ -f /var/lib/keys-provision/done ] && ok "done marker" || bad "done marker"
      [ "$(cat /etc/hostname)" = "hugmesh-'"${role}"'" ] && ok "hostname applied" || bad "hostname ($(cat /etc/hostname))"
      ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 && ok "SSH host keys generated" || bad "host keys"
      # KEYS/certs -> trust store, for a manifest WITHOUT a files list (every client stick)
      fp_want="'"${CA_FP}"'"
      fp_crt="$(openssl x509 -in /usr/local/share/ca-certificates/cluster-ca.crt -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
      [ "${fp_crt}" = "${fp_want}" ] && ok "KEYS/certs/cluster-ca.crt imported into /usr/local/share/ca-certificates (same certificate)" \
        || bad "KEYS/certs/cluster-ca.crt NOT imported (got fingerprint '"'"'${fp_crt:-<no file>}'"'"', want ${fp_want})"
      [ -f /usr/local/share/ca-certificates/extra.pem ] && ok "KEYS/certs/extra.pem imported too" || bad "KEYS/certs/extra.pem not imported"
      # update-ca-certificates rebuilt the store: Debian links /usr/local/share/ca-certificates/X.crt as /etc/ssl/certs/X.pem
      [ -e /etc/ssl/certs/cluster-ca.pem ] && grep -qF -- "$(sed -n 2p /usr/local/share/ca-certificates/cluster-ca.crt)" /etc/ssl/certs/ca-certificates.crt \
        && ok "update-ca-certificates ran: /etc/ssl/certs/cluster-ca.pem linked and the CA is in ca-certificates.crt" \
        || bad "trust store not rebuilt (no /etc/ssl/certs/cluster-ca.pem, or the CA is not in ca-certificates.crt)"
      grep -q "Imported certificates from KEYS/certs" /var/log/keys-provision.log 2>/dev/null \
        && ok "log says: Imported certificates from KEYS/certs" || bad "log never said: Imported certificates from KEYS/certs"
      echo "  RESULT role: ${P} passed, ${F} failed"; [ "${F}" -eq 0 ]
    '
}

rc=0
for role in ${ROLES[*]}; do emulate_role "${role}" || rc=1; done
echo; [ "${rc}" -eq 0 ] && echo "ALL ROLE EMULATIONS PASSED" || echo "SOME ROLE EMULATIONS FAILED"
exit "${rc}"
