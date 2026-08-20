#!/usr/bin/env bash
# mesh-cluster_test.sh — STATIC gate + HERMETIC tests for the 3-node QEMU
# mesh-cluster lane (issue #48, PR B). NOTHING boots here: no QEMU, no root,
# no images — qemu-system-x86_64/qemu-img are PATH stubs that record their
# argv, and the orchestrator runs behind its MESH_LAUNCH_CMD / MESH_SSH_CMD /
# MESH_KEYS_CMD seams (the same seam pattern as avc-workout_test.sh). The real
# boot campaign is post-build and opt-in (HUGMESH_QEMU_MESH=1).
#
# What is pinned/proved:
#   [launch]   launch-x86.sh --mesh-net/--mesh-mac/--mesh-id: the shared-L2 NIC
#              lands on the QEMU argv (socket mcast netdev + derived MAC), the
#              flags are DEFAULT-OFF (no flags -> argv carries no mesh NIC at
#              all), and the argument validation fails closed.
#   [driver]   mesh-cluster.sh end-to-end via stubs: CP first, joiners after,
#              cross-file consistency of the OFFLINE-minted join material
#              (pinned token + ca-cert hash in the workers' KEYS == the CP's
#              kubeadm-config/CA), per-node MAC/IP/port disjointness, PASS/FAIL
#              verdicts, and the SKIP/--dry-run gating (dry-run writes NOTHING).
#   [golden]   neither the launcher nor the driver ever runs `qemu-img commit`
#              on a live line — committing an overlay back silently rewrites
#              the GOLDEN artifact (the qemu-device-save lesson).
#   [wiring]   make qemu-mesh / qemu-mesh-enumerate exist and call the driver;
#              CI carries lint:qemu-mesh-cluster; check.sh runs this file.
#
# NEGATIVE CONTROLS (a guard that cannot be shown failing is not a guard):
# staged sed regressions on COPIES — mesh flag parsing dropped, the mesh netdev
# construction dropped, the default-off guard inverted, the opt-in SKIP gate
# removed, a qemu-img commit planted — must each turn the relevant leg red.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT

echo "== [syntax] both lane scripts parse =="
bash -n "${HERE}/launch-x86.sh"    && ok "bash -n launch-x86.sh"    || bad "bash -n launch-x86.sh"
bash -n "${HERE}/mesh-cluster.sh"  && ok "bash -n mesh-cluster.sh"  || bad "bash -n mesh-cluster.sh"

echo "== [launch] static pins on live lines =="
grep -qE '^\s*--mesh-net\)'  "${HERE}/launch-x86.sh" && ok "launch: --mesh-net parse case"  || bad "launch: --mesh-net parse case missing"
grep -qE '^\s*--mesh-mac\)'  "${HERE}/launch-x86.sh" && ok "launch: --mesh-mac parse case"  || bad "launch: --mesh-mac parse case missing"
grep -qE '^\s*--mesh-id\)'   "${HERE}/launch-x86.sh" && ok "launch: --mesh-id parse case"   || bad "launch: --mesh-id parse case missing"
grep -q  'socket,id=mesh0'   "${HERE}/launch-x86.sh" && ok "launch: socket netdev construction present" || bad "launch: socket netdev construction missing"
grep -q  '52:54:00:6d:65:%02x' "${HERE}/launch-x86.sh" && ok "launch: --mesh-id MAC derivation present" || bad "launch: MAC derivation missing"

echo "== [golden] no live qemu-img commit in the lane (overlay -> golden rewrite trap) =="
no_commit() { ! grep -qE '^[^#]*qemu-img[[:space:]]+commit' "$1"; }
no_commit "${HERE}/launch-x86.sh"   && ok "launch: no qemu-img commit"  || bad "launch: qemu-img commit on a live line"
no_commit "${HERE}/mesh-cluster.sh" && ok "driver: no qemu-img commit"  || bad "driver: qemu-img commit on a live line"

echo "== [launch] EFFECT: QEMU argv via PATH stubs (no real qemu anywhere) =="
stub="${work}/stub"; mkdir -p "${stub}"
cat > "${stub}/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${STUB_ARGV_OUT:?}"
exit 0
EOF
cat > "${stub}/qemu-img" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = create ]; then for last in "$@"; do :; done; : > "${last}"; fi
exit 0
EOF
chmod +x "${stub}/qemu-system-x86_64" "${stub}/qemu-img"
: > "${work}/fixture.img"; : > "${work}/OVMF_CODE.fd"; : > "${work}/OVMF_VARS.fd"

run_launch() { # <script> <argv-out> [extra flags...]
    local script="$1" out="$2"; shift 2
    PATH="${stub}:${PATH}" STUB_ARGV_OUT="${out}" \
    bash "${script}" --img "${work}/fixture.img" \
        --ovmf-code "${work}/OVMF_CODE.fd" --ovmf-vars "${work}/OVMF_VARS.fd" \
        --run-dir "${work}/launch-run" --keep "$@" >/dev/null 2>&1
}

run_launch "${HERE}/launch-x86.sh" "${work}/argv-mesh.txt" \
    --mesh-net 239.118.72.9:47391 --mesh-id 2 \
    && ok "launch: --mesh-net + --mesh-id exits 0" || bad "launch: --mesh-net + --mesh-id failed"
grep -q '^socket,id=mesh0,mcast=239.118.72.9:47391$' "${work}/argv-mesh.txt" \
    && ok "launch: bare ADDR:PORT becomes an mcast socket netdev" || bad "launch: mcast netdev missing from argv"
grep -q '^virtio-net-pci,netdev=mesh0,mac=52:54:00:6d:65:02$' "${work}/argv-mesh.txt" \
    && ok "launch: mesh NIC device with the --mesh-id-derived MAC" || bad "launch: mesh NIC/derived MAC missing from argv"
grep -q 'hostfwd=tcp' "${work}/argv-mesh.txt" \
    && ok "launch: slirp user NIC + hostfwds kept alongside the mesh NIC" || bad "launch: user NIC hostfwds lost"

run_launch "${HERE}/launch-x86.sh" "${work}/argv-listen.txt" \
    --mesh-net listen=127.0.0.1:47392 \
    && ok "launch: listen= point-to-point spelling accepted" || bad "launch: listen= spelling rejected"
grep -q '^socket,id=mesh0,listen=127.0.0.1:47392$' "${work}/argv-listen.txt" \
    && ok "launch: listen= passes through verbatim" || bad "launch: listen= not passed through"

run_launch "${HERE}/launch-x86.sh" "${work}/argv-mac.txt" \
    --mesh-net 239.118.72.9:47391 --mesh-mac 52:54:00:aa:bb:cc \
    && ok "launch: explicit --mesh-mac accepted" || bad "launch: explicit --mesh-mac failed"
grep -q 'mac=52:54:00:aa:bb:cc' "${work}/argv-mac.txt" \
    && ok "launch: explicit --mesh-mac lands on the argv" || bad "launch: explicit MAC not honoured"

run_launch "${HERE}/launch-x86.sh" "${work}/argv-off.txt" \
    && ok "launch: no mesh flags exits 0" || bad "launch: flagless run failed"
[ -f "${work}/argv-off.txt" ] && ! grep -q 'mesh0' "${work}/argv-off.txt" \
    && ok "launch: DEFAULT-OFF — flagless argv carries no mesh NIC" || bad "launch: mesh NIC leaked into the flagless argv"

echo "== [launch] validation fails closed =="
run_launch "${HERE}/launch-x86.sh" "${work}/argv-x1.txt" --mesh-mac 52:54:00:aa:bb:cc \
    && bad "launch: --mesh-mac without --mesh-net was accepted" || ok "launch: --mesh-mac without --mesh-net dies"
run_launch "${HERE}/launch-x86.sh" "${work}/argv-x2.txt" --mesh-net not-a-spec \
    && bad "launch: colon-less --mesh-net was accepted" || ok "launch: colon-less --mesh-net dies"
run_launch "${HERE}/launch-x86.sh" "${work}/argv-x3.txt" --mesh-net 239.1.1.1:1 --mesh-id 0 \
    && bad "launch: --mesh-id 0 was accepted" || ok "launch: --mesh-id 0 dies"
run_launch "${HERE}/launch-x86.sh" "${work}/argv-x4.txt" --mesh-net 239.1.1.1:1 --mesh-id 1 --mesh-mac 52:54:00:aa:bb:cc \
    && bad "launch: --mesh-id + --mesh-mac together were accepted" || ok "launch: --mesh-id + --mesh-mac together die"
run_launch "${HERE}/launch-x86.sh" "${work}/argv-x5.txt" --mesh-net 239.1.1.1:1 --mesh-mac 53:54:00:aa:bb:cc \
    && bad "launch: multicast (odd first octet) MAC was accepted" || ok "launch: multicast MAC dies"

echo "== [launch] NEGATIVE CONTROLS: staged regressions must go red =="
launch_mutant() { # <name> <sed-expr>  -> path on stdout, empty if sed matched nothing
    local m="${work}/mut-launch-$1.sh"
    sed -e "$2" "${HERE}/launch-x86.sh" > "${m}"
    cmp -s "${m}" "${HERE}/launch-x86.sh" && { echo ""; return; }
    echo "${m}"
}
m="$(launch_mutant drop-parse '/--mesh-net)/d')"
if [ -n "${m}" ]; then
    run_launch "${m}" "${work}/argv-m1.txt" --mesh-net 239.118.72.9:47391 --mesh-id 2 \
        && bad "control[drop-parse]: mutant still accepted --mesh-net" \
        || ok "control[drop-parse]: dropping the parse case goes red"
else bad "control[drop-parse]: sed matched nothing"; fi
m="$(launch_mutant drop-netdev '/socket,id=mesh0/d')"
if [ -n "${m}" ]; then
    if run_launch "${m}" "${work}/argv-m2.txt" --mesh-net 239.118.72.9:47391 --mesh-id 2 \
            && grep -q 'socket,id=mesh0' "${work}/argv-m2.txt" 2>/dev/null; then
        bad "control[drop-netdev]: mutant still emitted the mesh netdev"
    else
        ok "control[drop-netdev]: dropping the netdev construction goes red"
    fi
else bad "control[drop-netdev]: sed matched nothing"; fi
m="$(launch_mutant always-on 's|if \[ -z "${MESH_NET}" \]; then|if false; then|')"
if [ -n "${m}" ]; then
    if run_launch "${m}" "${work}/argv-m3.txt" \
            && [ -f "${work}/argv-m3.txt" ] && ! grep -q 'mesh0' "${work}/argv-m3.txt"; then
        bad "control[always-on]: default-off leg stayed green on the inverted guard"
    else
        ok "control[always-on]: inverting the default-off guard goes red"
    fi
else bad "control[always-on]: sed matched nothing"; fi

echo "== [driver] gating: SKIP-clean + --dry-run boots nothing =="
grep -q 'HUGMESH_QEMU_MESH' "${HERE}/mesh-cluster.sh" \
    && ok "driver: opt-in gate reads HUGMESH_QEMU_MESH" || bad "driver: opt-in env gate missing"
grep -q 'command -v qemu-system-x86_64' "${HERE}/mesh-cluster.sh" \
    && ok "driver: qemu presence gate exists" || bad "driver: qemu presence gate missing"
out="$(HUGMESH_QEMU_MESH= bash "${HERE}/mesh-cluster.sh" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "driver: no-env run exits 0" || bad "driver: no-env run exited ${rc}"
echo "${out}" | grep -q 'SKIP' && ok "driver: no-env run says SKIP" || bad "driver: no-env run did not SKIP"
out="$(bash "${HERE}/mesh-cluster.sh" --dry-run --run-dir "${work}/dryrun-dir" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "driver: --dry-run exits 0" || bad "driver: --dry-run exited ${rc}"
[ "$(echo "${out}" | grep -c '^NODE ')" -eq 3 ] && ok "driver: --dry-run plans exactly 3 nodes" || bad "driver: --dry-run node rows != 3"
echo "${out}" | grep -q 'nothing booted' && ok "driver: --dry-run says nothing booted" || bad "driver: --dry-run verdict line missing"
for mac in 52:54:00:6d:65:01 52:54:00:6d:65:02 52:54:00:6d:65:03; do
    echo "${out}" | grep -q "${mac}" && ok "driver: --dry-run plans MAC ${mac}" || bad "driver: MAC ${mac} missing from the plan"
done
[ ! -e "${work}/dryrun-dir" ] && ok "driver: --dry-run wrote NOTHING (no run dir, no keys)" || bad "driver: --dry-run created files"

echo "== [driver] hermetic end-to-end via the MESH_*_CMD seams =="
cat > "${work}/launch-stub.sh" <<'EOF'
#!/usr/bin/env bash
# Record the call, then emit the canned console a real boot would produce.
printf '%s\n' "$*" >> "${STUB_CALLS:?}"
rundir=""; prev=""
for a in "$@"; do [ "${prev}" = "--run-dir" ] && rundir="${a}"; prev="${a}"; done
mkdir -p "${rundir}"
case "${rundir}" in
    *node1-*)
        { echo "Running kubeadm init (first control-plane) --upload-certs"
          echo "First control plane initialised; join material in /etc/hugmesh/kubeadm-join.cmd"
          echo "=== keys-provision complete ==="; } > "${rundir}/console.log" ;;
    *node3-*)
        if [ "${STUB_JOIN_FAIL:-0}" = "1" ]; then
            echo "kubeadm join failed against 10.87.72.11:6443" > "${rundir}/console.log"
        else
            { echo "Joined cluster (10.87.72.11:6443)"
              echo "=== keys-provision complete ==="; } > "${rundir}/console.log"
        fi ;;
    *)
        { echo "Joined cluster (10.87.72.11:6443)"
          echo "=== keys-provision complete ==="; } > "${rundir}/console.log" ;;
esac
exit 0
EOF
cat > "${work}/keys-stub.sh" <<'EOF'
#!/usr/bin/env bash
: > "$2"
EOF
cat > "${work}/ssh-stub.sh" <<'EOF'
#!/usr/bin/env bash
argv="$*"
case "${argv}" in
    *"kubectl get nodes"*)
        n="${STUB_NODES:-3}"
        echo "hugmesh-mesh-cp   Ready      control-plane   2m    v1.30.0"
        [ "${n}" -ge 2 ] && echo "hugmesh-mesh-w2   NotReady   <none>          20s   v1.30.0"
        [ "${n}" -ge 3 ] && echo "hugmesh-mesh-w3   NotReady   <none>          10s   v1.30.0"
        exit 0 ;;
    *poweroff*) exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "${work}/launch-stub.sh" "${work}/keys-stub.sh" "${work}/ssh-stub.sh"

run_driver() { # <run-subdir> [env overrides via caller export]
    HUGMESH_QEMU_MESH=1 \
    MESH_LAUNCH_CMD="bash ${work}/launch-stub.sh" \
    MESH_SSH_CMD="bash ${work}/ssh-stub.sh" \
    MESH_KEYS_CMD="bash ${work}/keys-stub.sh" \
    MESH_POLL_INTERVAL=1 MESH_VERIFY_INTERVAL=1 \
    STUB_CALLS="${work}/$1.calls" \
        bash "${HERE}/mesh-cluster.sh" --run-dir "${work}/$1" \
            -t 20 --join-timeout 5 2>&1
}

: > "${work}/run-pass.calls"
out="$(run_driver run-pass)"; rc=$?
[ "${rc}" -eq 0 ] && ok "driver: PASS leg exits 0" || { bad "driver: PASS leg exited ${rc}"; echo "${out}" | tail -20 | sed 's/^/    | /' >&2; }
echo "${out}" | grep -q 'MESH-CLUSTER RESULT: PASS' && ok "driver: reports PASS" || bad "driver: PASS verdict missing"
[ "$(grep -c . "${work}/run-pass.calls")" -eq 3 ] && ok "driver: exactly 3 launcher calls" || bad "driver: launcher call count != 3"
[ "$(grep -c -- '--mesh-net 239.118.72.1:47301' "${work}/run-pass.calls")" -eq 3 ] \
    && ok "driver: every node joins the SAME shared L2" || bad "driver: nodes not on one L2 spec"
[ "$(grep -o -- '--mesh-mac [^ ]*' "${work}/run-pass.calls" | sort -u | wc -l)" -eq 3 ] \
    && ok "driver: 3 DISTINCT mesh MACs" || bad "driver: mesh MACs collide"
[ "$(grep -o -- '--ssh-port [^ ]*' "${work}/run-pass.calls" | sort -u | wc -l)" -eq 3 ] \
    && ok "driver: 3 DISTINCT ssh forwards" || bad "driver: ssh forwards collide"
head -1 "${work}/run-pass.calls" | grep -q -- 'node1-cp' \
    && ok "driver: control plane boots FIRST" || bad "driver: CP was not the first launch"

echo "== [driver] offline join material is CONSISTENT across the three KEYS payloads =="
cpj="${work}/run-pass/node1-cp/keys/provision.json"
w2j="${work}/run-pass/node2-worker/keys/provision.json"
w3j="${work}/run-pass/node3-worker/keys/provision.json"
cfg="${work}/run-pass/node1-cp/keys/kubernetes/kubeadm-config.yaml"
cacrt="${work}/run-pass/node1-cp/keys/kubernetes/pki/ca.crt"
grep -q '"first": true' "${cpj}" && ok "CP payload: kubernetes.first=true (init, never split-brain)" || bad "CP payload: first:true missing"
grep -q '"pki_dir": "kubernetes/pki"' "${cpj}" && ok "CP payload: shared-CA pki_dir staged" || bad "CP payload: pki_dir missing"
grep -q 'controlPlaneEndpoint: "10.87.72.11:6443"' "${cfg}" && ok "CP kubeadm-config: controlPlaneEndpoint = mesh IP" || bad "CP kubeadm-config: endpoint not the mesh IP"
grep -q 'advertiseAddress: 10.87.72.11' "${cfg}" && ok "CP kubeadm-config: advertises the mesh NIC (not slirp)" || bad "CP kubeadm-config: advertiseAddress missing"
grep -qE '^\s+- 10\.87\.72\.11$' "${cfg}" && ok "CP kubeadm-config: mesh IP in certSANs (joiners dial it)" || bad "CP kubeadm-config: mesh IP not a certSAN"
tok="$(sed -n 's/.*"token": "\([a-z0-9.]*\)".*/\1/p' "${w2j}" | head -1)"
[[ "${tok}" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]] && ok "worker payload: kubeadm-format pinned token" || bad "worker payload: token malformed: '${tok}'"
grep -q "token: \"${tok}\"" "${cfg}" && ok "pinned token: worker join == CP bootstrapTokens" || bad "pinned token: worker/CP token mismatch"
grep -q '"api_server": "10.87.72.11:6443"' "${w2j}" && grep -q '"api_server": "10.87.72.11:6443"' "${w3j}" \
    && ok "worker payloads: join api_server pinned to the CP mesh IP" || bad "worker payloads: api_server not pinned"
want_hash="sha256:$(openssl x509 -pubkey -noout -in "${cacrt}" 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
grep -q "\"ca_cert_hash\": \"${want_hash}\"" "${w2j}" \
    && ok "worker payload: ca_cert_hash == hash of the STAGED CA (recomputed here)" || bad "worker payload: ca_cert_hash does not match the staged CA"
grep -q 'mac-address=52:54:00:6d:65:02' "${work}/run-pass/node2-worker/keys/network/mesh0.nmconnection" \
    && grep -q 'address1=10.87.72.12/24' "${work}/run-pass/node2-worker/keys/network/mesh0.nmconnection" \
    && ok "worker payload: static mesh IP bound to the node's mesh MAC" || bad "worker payload: nmconnection MAC/IP wrong"
grep -q 'never-default=true' "${work}/run-pass/node2-worker/keys/network/mesh0.nmconnection" \
    && ok "worker payload: mesh NIC never steals the default route" || bad "worker payload: never-default missing"
grep -q '"enabled": false' "${w2j}" && ok "worker payload: headscale/tailscale off (phase-2 LAN cluster)" || bad "worker payload: mesh services unexpectedly on"

echo "== [driver] MUTATIONS: each gate must be able to FAIL the run =="
: > "${work}/run-joinfail.calls"
out="$(STUB_JOIN_FAIL=1 run_driver run-joinfail)"; rc=$?
[ "${rc}" -ne 0 ] && ok "driver: a failed join fails the run" || bad "MUTATION missed: join failure did not fail the driver"
echo "${out}" | grep -q 'node3-join' && ok "driver: NAMES the failed joiner" || bad "driver: failed joiner not named"

: > "${work}/run-short.calls"
out="$(STUB_NODES=2 run_driver run-short)"; rc=$?
[ "${rc}" -ne 0 ] && ok "driver: a missing registration fails the run" || bad "MUTATION missed: 2/3 nodes did not fail the driver"
echo "${out}" | grep -q 'node-count:2' && ok "driver: NAMES the node-count shortfall" || bad "driver: node-count shortfall not named"

echo "== [driver] NEGATIVE CONTROLS: staged regressions must go red =="
m="${work}/mut-driver-nogate.sh"
sed -e 's|"${HUGMESH_QEMU_MESH:-}" != "1"|1 -eq 0|' "${HERE}/mesh-cluster.sh" > "${m}"
if cmp -s "${m}" "${HERE}/mesh-cluster.sh"; then
    bad "control[drop-skip-gate]: sed matched nothing"
else
    out="$(HUGMESH_QEMU_MESH= \
        MESH_LAUNCH_CMD="bash ${work}/launch-stub.sh" \
        MESH_SSH_CMD="bash ${work}/ssh-stub.sh" \
        MESH_KEYS_CMD="bash ${work}/keys-stub.sh" \
        MESH_POLL_INTERVAL=1 MESH_VERIFY_INTERVAL=1 \
        STUB_CALLS="${work}/mut-nogate.calls" \
        bash "${m}" --run-dir "${work}/mut-nogate" -t 20 --join-timeout 5 2>&1)"
    echo "${out}" | grep -q 'SKIP' \
        && bad "control[drop-skip-gate]: mutant still SKIPs without the opt-in env" \
        || ok "control[drop-skip-gate]: removing the opt-in gate goes red (no SKIP)"
fi
m="${work}/mut-driver-commit.sh"
{ cat "${HERE}/mesh-cluster.sh"; echo 'qemu-img commit "${RUN_DIR}/node1-cp/launch/run.qcow2"'; } > "${m}"
no_commit "${m}" \
    && bad "control[plant-commit]: the no-commit pin missed a live qemu-img commit" \
    || ok "control[plant-commit]: a planted qemu-img commit turns the pin red"

echo "== [wiring] make targets + CI + check.sh =="
grep -qE '^qemu-mesh:' "${REPO}/Makefile" && ok "Makefile: qemu-mesh target" || bad "Makefile: qemu-mesh target missing"
grep -qE '^qemu-mesh-enumerate:' "${REPO}/Makefile" && ok "Makefile: qemu-mesh-enumerate target" || bad "Makefile: qemu-mesh-enumerate target missing"
sed -n '/^qemu-mesh:/,/^$/p' "${REPO}/Makefile" | grep -q 'tests/qemu/mesh-cluster.sh' \
    && ok "Makefile: qemu-mesh drives tests/qemu/mesh-cluster.sh" || bad "Makefile: qemu-mesh recipe wrong"
sed -n '/^qemu-mesh-enumerate:/,/^$/p' "${REPO}/Makefile" | grep -q -- '--dry-run' \
    && ok "Makefile: qemu-mesh-enumerate is the --dry-run lane" || bad "Makefile: enumerate recipe lacks --dry-run"
grep -qE '^\s+.*\bqemu-mesh qemu-mesh-enumerate\b' "${REPO}/Makefile" \
    && ok "Makefile: both targets are .PHONY" || bad "Makefile: qemu-mesh targets not in the .PHONY list"
grep -qE '^lint:qemu-mesh-cluster:' "${REPO}/.gitlab-ci.yml" \
    && ok "CI: lint:qemu-mesh-cluster job exists" || bad "CI: lint:qemu-mesh-cluster job missing"
grep -q 'tests/qemu/mesh-cluster_test.sh' "${REPO}/.gitlab-ci.yml" \
    && ok "CI: the job runs this gate" || bad "CI: gate not wired into the job"
grep -q 'qemu-mesh-cluster:.*mesh-cluster_test.sh' "${REPO}/tests/build-matrix/check.sh" \
    && ok "check.sh: gate registered in the smoke walk" || bad "check.sh: gate not registered"

echo
echo "== mesh-cluster gate: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0
