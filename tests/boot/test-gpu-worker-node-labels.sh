#!/usr/bin/env bash
# test-gpu-worker-node-labels.sh — a WORKER provisioned from a KEYS stick must
# register with the stick's .hugmesh.node_labels (above all hugmesh.net/compute=gpu).
#
# WHY THIS EXISTS. The only code that applied .hugmesh.node_labels was the
# `kubectl label` in provision_hugmesh(), gated on /etc/kubernetes/admin.conf. Only a
# control plane has that file. Every worker (backend, frontend, backend-gpu, edge-ai)
# joined with `kubeadm join <api> --token .. --discovery-token-ca-cert-hash ..` and no
# labels at all, so nothing pinned to hugmesh.net/compute=gpu (nvidia-device-plugin,
# edge-ai, owncast, tube, games, media-poisoner) could ever schedule onto a GPU worker.
#
# WHAT RUNS. The REAL keys-provision engine (specs/etc/keys-provision/provision.sh)
# inside a kindest/node container (it carries bash, jq and a real kubelet binary),
# with no network and no privileges. kubeadm, kubectl and rc-service are replaced by
# stubs that record their argv; the kubeadm stub also records what the kubelet would
# see at the moment `kubeadm join` restarts it. After provisioning, the image's own
# /etc/init.d/kubelet is evaluated the way openrc-run does it (conf.d first, in sh),
# and the REAL kubelet binary is started with that command line: its startup flag
# dump (FLAG: --node-labels=...) and its flag validation are the evidence.
#
# Cases: edge-ai worker (labels must reach the kubelet before join), a worker stick
# carrying a kubernetes.io label and a malformed value (filtered, kubelet still
# starts), a control plane (existing kubectl path still runs), and a stick with no
# labels (kubelet command line unchanged).
#
# Needs docker and the kindest/node image (override with BOOT_K8S_IMAGE). Exit 2 when
# it cannot run at all — never a silent pass.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="${REPO}/specs/etc/keys-provision/provision.sh"
KUBELET_INIT="${REPO}/specs/etc/init.d/kubelet"
IMAGE="${BOOT_K8S_IMAGE:-kindest/node:v1.30.0@sha256:047357ac0cfea04663786a612ba1eaba9702bef25227a794b52890dd8bcd692e}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

command -v docker >/dev/null 2>&1 || { echo "CANNOT RUN: docker not found"; exit 2; }
docker image inspect "${IMAGE}" >/dev/null 2>&1 || docker pull -q "${IMAGE}" >/dev/null 2>&1 \
  || { echo "CANNOT RUN: image ${IMAGE} not available"; exit 2; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# The kubelet configuration a JOINED node actually runs with: kubeadm overwrites
# /var/lib/kubelet/config.yaml with the cluster's kubelet-config ConfigMap, i.e. the
# KubeletConfiguration in specs/etc/kubernetes/kubeadm-config.yaml.
sed -n '/^kind: KubeletConfiguration/,$p' "${REPO}/specs/etc/kubernetes/kubeadm-config.yaml" \
  | { echo 'apiVersion: kubelet.config.k8s.io/v1beta1'; cat; } > "${WORK}/kubelet-config.yaml"

# Stubs, mounted read-only at /stub and put first on PATH.
mkdir -p "${WORK}/stub"
cat > "${WORK}/stub/kubeadm" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> /out/kubeadm.argv
case "$1" in
  join|init)
    # What the kubelet would read when kubeadm restarts it during join/init.
    cp /etc/conf.d/kubelet /out/confd-at-kubeadm 2>/dev/null || : > /out/confd-at-kubeadm
    mkdir -p /etc/kubernetes /var/lib/kubelet
    echo 'stub' > /etc/kubernetes/kubelet.conf
    [ "$1" = init ] && echo 'stub' > /etc/kubernetes/admin.conf
    # kubeadm writes this on every join/init (no node-labels: CLI joins cannot set any)
    printf 'KUBELET_KUBEADM_ARGS="--container-runtime-endpoint=unix:///run/containerd/containerd.sock --pod-infra-container-image=registry.k8s.io/pause:3.10"\n' \
      > /var/lib/kubelet/kubeadm-flags.env ;;
  token) echo "kubeadm join stub:6443 --token abcdef.0123456789abcdef --discovery-token-ca-cert-hash sha256:00" ;;
esac
exit 0
EOF
cat > "${WORK}/stub/kubectl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> /out/kubectl.argv
exit 0
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> /out/rc-service.argv\nexit 0\n' > "${WORK}/stub/rc-service"
chmod +x "${WORK}/stub/"*

# run_case NAME K8S_ROLE NODE_LABELS_JSON — provision, then evaluate the kubelet.
run_case() {
  local name="$1" krole="$2" labels="$3"
  local keys="${WORK}/keys-${name}" out="${WORK}/out-${name}"
  mkdir -p "${keys}" "${out}"
  cat > "${keys}/provision.json" <<EOF
{ "version": 1, "hostname": "hugmesh-${name}", "timezone": "UTC",
  "headscale": { "enabled": false }, "tailscale": { "enabled": false },
  "kubernetes": { "role": "${krole}", "bootstrap": true,
    "join": { "api_server": "192.0.2.10:6443", "token": "abcdef.0123456789abcdef",
              "ca_cert_hash": "sha256:0000000000000000000000000000000000000000000000000000000000000000" } },
  "hugmesh": { "role": "${name}", "cluster_domain": "hugmesh.net", "node_labels": ${labels} } }
EOF
  timeout 300 docker run --rm --network none --name "r1021-cs-g12-labels-${name}-$$" \
    -v "${ENGINE}:/usr/sbin/keys-provision:ro" \
    -v "${KUBELET_INIT}:/etc/init.d/kubelet:ro" \
    -v "${WORK}/kubelet-config.yaml:/var/lib/kubelet/config.yaml:ro" \
    -v "${WORK}/stub:/stub:ro" -v "${keys}:/keys:ro" -v "${out}:/out" \
    -e KEYS_PREMOUNTED=1 -e KEYS_MOUNT=/keys \
    --entrypoint bash "${IMAGE}" -c '
      export PATH=/stub:$PATH
      bash /usr/sbin/keys-provision > /out/provision.out 2>&1 || true
      cp /var/log/keys-provision.log /out/ 2>/dev/null || true
      cp /etc/conf.d/kubelet /out/confd-final 2>/dev/null || true
      # openrc-run: conf.d/<svc> is sourced, then the init script, in sh.
      sh -c "RC_SVCNAME=kubelet; [ -f /etc/conf.d/kubelet ] && . /etc/conf.d/kubelet; . /etc/init.d/kubelet; printf %s \"\$command_args\"" > /out/cmdline
      # The REAL kubelet with that command line (no bootstrap creds: it stops after
      # flag parsing + validation, which is what is under test).
      timeout 10 sh -c "/usr/bin/kubelet $(cat /out/cmdline)" > /out/kubelet.out 2>&1 || true
      chmod -R a+rwX /out
    ' >/dev/null 2>&1
  docker rm -f "r1021-cs-g12-labels-${name}-$$" >/dev/null 2>&1 || true
  echo "${out}"
}

echo "== case edge-ai worker: compute=gpu must reach the kubelet before kubeadm join =="
o="$(run_case edge-ai worker '{ "hugmesh.net/backend": "true", "hugmesh.net/compute": "gpu", "hugmesh.net/edge-ai": true }')"
grep -a '^join 192.0.2.10:6443 --token abcdef.0123456789abcdef' "${o}/kubeadm.argv" >/dev/null 2>&1 \
  && ok "real engine ran kubeadm join against the stick's api_server" \
  || bad "kubeadm join never ran (argv: $(tr '\n' '|' < "${o}/kubeadm.argv" 2>/dev/null))"
grep -a 'node-labels=' "${o}/confd-at-kubeadm" 2>/dev/null | grep -aF 'hugmesh.net/compute=gpu' >/dev/null \
  && ok "labels were staged in /etc/conf.d/kubelet BEFORE kubeadm join restarted the kubelet" \
  || bad "when kubeadm join ran, /etc/conf.d/kubelet carried no compute=gpu label (got: $(tr '\n' ' ' < "${o}/confd-at-kubeadm" 2>/dev/null))"
grep -aF -- '--node-labels=hugmesh.net/backend=true,hugmesh.net/compute=gpu,hugmesh.net/edge-ai=true' "${o}/cmdline" >/dev/null \
  && ok "the image's init.d/kubelet command line carries --node-labels=...compute=gpu..." \
  || bad "init.d/kubelet command line has no compute=gpu node label: $(cat "${o}/cmdline")"
grep -aF 'FLAG: --node-labels="hugmesh.net/backend=true,hugmesh.net/compute=gpu,hugmesh.net/edge-ai=true"' "${o}/kubelet.out" >/dev/null \
  && ok "the REAL kubelet parsed it: FLAG: --node-labels=\"...compute=gpu...\"" \
  || bad "the real kubelet never saw the labels: $(grep -a 'FLAG: --node-labels' "${o}/kubelet.out" | head -1)"
grep -a 'failed to validate kubelet flags' "${o}/kubelet.out" >/dev/null \
  && bad "the real kubelet rejected its flags: $(grep -a -A1 'failed to validate' "${o}/kubelet.out" | tr '\n' ' ')" \
  || ok "the real kubelet accepted the flags (no 'failed to validate kubelet flags')"
grep -a '^label ' "${o}/kubectl.argv" >/dev/null 2>&1 \
  && bad "a worker ran kubectl label (it has no admin.conf; this path cannot work there)" \
  || ok "worker did not rely on kubectl label (no admin.conf on a worker)"

echo "== case filtered: kubernetes.io key + malformed value are dropped, kubelet still starts =="
o="$(run_case filtered worker '{ "hugmesh.net/compute": "gpu", "node-role.kubernetes.io/worker": "", "hugmesh.net/bad": "x\"; touch /tmp/pwned; \"" }')"
grep -aF -- '--node-labels=hugmesh.net/compute=gpu' "${o}/cmdline" >/dev/null \
  && ok "valid label kept: --node-labels=hugmesh.net/compute=gpu" \
  || bad "valid label lost: $(cat "${o}/cmdline")"
grep -aF 'kubernetes.io' "${o}/cmdline" >/dev/null \
  && bad "a kubernetes.io label reached the kubelet (it refuses to start on those)" \
  || ok "kubernetes.io-namespaced label kept off the kubelet command line"
grep -aF 'pwned' "${o}/confd-final" >/dev/null 2>&1 \
  && bad "malformed label value was written into the sourced conf.d file" \
  || ok "malformed label value never reached /etc/conf.d/kubelet"
grep -a 'failed to validate kubelet flags' "${o}/kubelet.out" >/dev/null \
  && bad "the real kubelet rejected its flags" \
  || ok "the real kubelet accepted the filtered flags"
grep -a 'NOT passed to the kubelet' "${o}/keys-provision.log" >/dev/null 2>&1 \
  && ok "log says the malformed label was not passed" || bad "no log line for the dropped malformed label"

echo "== case control plane: existing kubectl label path still runs =="
o="$(run_case pki control-plane '{ "hugmesh.net/pki": "true" }')"
grep -a '^init ' "${o}/kubeadm.argv" >/dev/null 2>&1 \
  && ok "control plane ran kubeadm init" || bad "control plane did not run kubeadm init"
grep -a '^label node .*hugmesh.net/pki=true --overwrite' "${o}/kubectl.argv" >/dev/null 2>&1 \
  && ok "control plane still labels itself via kubectl (admin.conf path)" \
  || bad "control-plane kubectl label path lost (kubectl argv: $(tr '\n' '|' < "${o}/kubectl.argv" 2>/dev/null))"
grep -aF -- '--node-labels=hugmesh.net/pki=true' "${o}/cmdline" >/dev/null \
  && ok "control plane also registers with its labels" || bad "control plane kubelet has no --node-labels"

echo "== case no labels: kubelet command line unchanged =="
o="$(run_case nolabels worker '{}')"
[ "$(cat "${o}/cmdline")" = "--config=/var/lib/kubelet/config.yaml --kubeconfig=/etc/kubernetes/kubelet.conf --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --v=2 --container-runtime-endpoint=unix:///run/containerd/containerd.sock --pod-infra-container-image=registry.k8s.io/pause:3.10" ] \
  && ok "no node_labels -> command line is exactly the pre-change one" \
  || bad "no node_labels -> command line changed: $(cat "${o}/cmdline")"

echo "== gpu worker node labels: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
