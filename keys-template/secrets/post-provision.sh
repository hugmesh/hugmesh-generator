#!/bin/bash
# Example post-provision hook. Referenced from provision.json "run": [ ... ].
#
# Runs at the very end of first-boot provisioning, as root, after users,
# network, certs, headscale, tailscale and Kubernetes have been processed.
#
# The KEYS mount is available read-only at the path in $KEYS_BASE so you
# can read additional secrets from the stick here.
set -euo pipefail

echo "[post-provision] hook running; KEYS at ${KEYS_BASE:-<none>}"

# Example: label this node for the snapdragon backend namespace once the
# kubeconfig exists (control-plane only).
if [ -f /etc/kubernetes/admin.conf ]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl label node "$(hostname)" snapdragon.systems/role=backend --overwrite || true
fi
