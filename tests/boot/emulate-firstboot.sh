#!/usr/bin/env bash
# emulate-firstboot.sh — emulate the RPi/x86 image first-boot provisioning for
# "one of each kind" of node, by running the REAL keys-provision engine
# (specs/etc/keys-provision/provision.sh) inside a throwaway container against a
# generated KEYS directory (KEYS_PREMOUNTED=1, no block device needed).
#
# This exercises the actual boot-time logic — user creation from users.json,
# SSH key install, host-key generation, hostname/timezone, Kubernetes module +
# sysctl staging — for roles: pki, backend, frontend, host. Rootless (uses the
# local Docker). It does NOT boot the kernel (no aarch64 stage4 is built here);
# it validates the provisioning the image runs at first boot.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="${REPO}/specs/etc/keys-provision/provision.sh"
BASE_IMAGE="${BOOT_BASE_IMAGE:-cassandra:5}"   # local debian-based image w/ apt
ROLES=("${@:-pki backend frontend host}")
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A throwaway SSH public key to install for the emulated admin user.
ssh-keygen -t ed25519 -N '' -C boot-emu -f "${WORK}/key" >/dev/null
PUBKEY="$(cat "${WORK}/key.pub")"
# A SHA-512 crypt password hash (deterministic test value).
HASH="$(openssl passwd -6 'boot-emu-pass')"

emulate_role() {
  local role="$1" krole keys="${WORK}/keys-${role}"
  case "${role}" in
    pki) krole="control-plane" ;;
    *)   krole="worker" ;;
  esac
  mkdir -p "${keys}/ssh"
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
  "hugmesh": { "role": "${role}", "cluster_domain": "hugmesh.systems",
                  "node_labels": { "hugmesh.systems/role": "${role}" } } }
EOF

  echo "================ first-boot emulation: role=${role} (k8s=${krole}) ================"
  docker run --rm \
    -v "${ENGINE}:/usr/sbin/keys-provision:ro" \
    -v "${keys}:/keys:ro" \
    -e KEYS_PREMOUNTED=1 -e KEYS_MOUNT=/keys \
    "${BASE_IMAGE}" bash -c '
      set -u
      export DEBIAN_FRONTEND=noninteractive
      (apt-get update -qq && apt-get install -y -qq jq passwd openssh-client procps iproute2 >/dev/null 2>&1) \
        || echo "[warn] apt unavailable; some assertions may fail"
      bash /usr/sbin/keys-provision || true
      echo "----- assertions (role $(cat /etc/hugmesh/role 2>/dev/null || echo n/a)) -----"
      P=0; F=0; ok(){ echo "  PASS $*"; P=$((P+1)); }; bad(){ echo "  FAIL $*"; F=$((F+1)); }
      id opsadmin >/dev/null 2>&1 && ok "user opsadmin created from users.json" || bad "user opsadmin"
      id -nG opsadmin 2>/dev/null | grep -qw wheel && ok "group wheel auto-created + assigned" || bad "wheel group"
      [ -s /home/opsadmin/.ssh/authorized_keys ] && ok "SSH authorized_keys installed" || bad "authorized_keys"
      [ -f /etc/sudoers.d/10-opsadmin ] && ok "sudoers entry written" || bad "sudoers"
      [ -f /var/lib/keys-provision/users.created ] && ok "users.created marker" || bad "users.created marker"
      [ -f /var/lib/keys-provision/done ] && ok "done marker" || bad "done marker"
      [ "$(cat /etc/hostname)" = "hugmesh-'"${role}"'" ] && ok "hostname applied" || bad "hostname ($(cat /etc/hostname))"
      ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 && ok "SSH host keys generated" || bad "host keys"
      echo "  RESULT role: ${P} passed, ${F} failed"; [ "${F}" -eq 0 ]
    '
}

rc=0
for role in ${ROLES[*]}; do emulate_role "${role}" || rc=1; done
echo; [ "${rc}" -eq 0 ] && echo "ALL ROLE EMULATIONS PASSED" || echo "SOME ROLE EMULATIONS FAILED"
exit "${rc}"
